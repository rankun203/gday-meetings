import CoreML
import FluidAudio
import Foundation

struct LocalSpeakerRange: Codable, Equatable, Sendable {
    var track: String
    var label: String
    var start: Double
    var end: Double
    var associationUncertain: Bool?
}

struct UnresolvedSpeakerRange: Codable, Equatable, Sendable {
    var track: String
    var start: Double
    var end: Double
}

/// Matching support belongs to one acoustic turn; the excerpt is bounded to ten seconds.
struct LocalSpeakerTurn: Codable, Equatable, Sendable {
    var track: String
    var label: String
    var start: Double
    var end: Double
    var sampleRange: VoiceSampleRange?
    var audioRevision: String?
    var voiceEmbedding: TypedVoiceEmbedding?
    var sampleQuality: VoiceSampleQuality?

    static func reviewRepresentative(_ turns: [Self]) -> Self? {
        turns.filter { $0.sampleQuality.map { $0.issue == nil } == true }.max {
            let left = $0.sampleRange?.speechDuration ?? 0
            let right = $1.sampleRange?.speechDuration ?? 0
            return left == right ? $0.start > $1.start : left < right
        }
    }
}

struct LocalDiarizationResult: Codable, Sendable {
    var version = 1
    var id = UUID()
    var generatedAt = Date()
    var modelRevision: String
    var ranges: [LocalSpeakerRange]
    var speakers: [MeetingSpeaker]
    var trackSources: [String: String] = [:]
    var detail: String?
    var providerName: String?
    var unresolvedRanges: [UnresolvedSpeakerRange]?
    var audioReferences: [AnalysisAudioReference]?
    var sampleQualities: [String: VoiceSampleQuality]?
    var turnSamples: [LocalSpeakerTurn]?
}

enum LocalDiarizationInputPolicy {
    static func revisions(for files: [URL]) throws -> [URL: String] {
        var revisions: [URL: String] = [:]
        for file in files {
            guard let revision = VoiceLibraryStore.revision(url: file) else {
                throw ServiceError("The source audio is unavailable. Restore it before diarizing speakers.")
            }
            revisions[file] = revision
        }
        return revisions
    }

    /// Recovery adds this reserved suffix only when the original stem would collide.
    /// Require a complete UUID so ordinary imported names keep their existing meaning.
    static func recordingStem(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        if let suffix = stem.range(of: "-compatible-", options: .backwards),
            UUID(uuidString: String(stem[suffix.upperBound...])) != nil
        {
            return String(stem[..<suffix.lowerBound])
        }
        return stem
    }

    static func sourceName(for file: URL) -> String {
        switch recordingStem(for: file).lowercased() {
        case "microphone", "mic": return "microphone"
        case "system", "system_mix": return "system"
        default: return "unknown"
        }
    }

    static func speechSamples(start: Double, end: Double, sampleCount: Int) -> Range<Int>? {
        guard sampleCount >= 32_000, start.isFinite, end.isFinite, start >= 0, end > start,
            end <= Double(sampleCount) / 16000 + 0.01,
            let offset = Int(exactly: (start * 16000).rounded(.down)), offset < sampleCount
        else { return nil }
        let seconds = min(10, end - start)
        let count = min(sampleCount - offset, Int((seconds * 16000).rounded(.down)))
        guard count >= 32_000 else { return nil }
        return offset..<(offset + count)
    }
}

/// File processing and optional voice extraction run away from the main actor.
actor CommunityDiarizationWorker {
    nonisolated static var discoveryConfiguration: OfflineDiarizerConfig { OfflineDiarizerConfig() }
    func run(
        files: [URL], lease: LocalModelLease, recognize: Bool,
        progress: (@Sendable (String) async -> Void)? = nil,
        taskProgress: (@Sendable (AudioTaskProgress) async -> Void)? = nil
    )
        async throws -> LocalDiarizationResult
    {
        try await ProcessingCoordinator.shared.withPermit(for: .communityInference, priority: .processing) {
            try await self.runSerial(
                files: files, lease: lease, recognize: recognize, progress: progress, taskProgress: taskProgress)
        }
    }

    private func runSerial(
        files: [URL], lease: LocalModelLease, recognize: Bool, progress: (@Sendable (String) async -> Void)?,
        taskProgress: (@Sendable (AudioTaskProgress) async -> Void)?
    ) async throws -> LocalDiarizationResult {
        guard let segmentation = lease.models["Segmentation"], let fbank = lease.models["FBank"],
            let embedding = lease.models["Embedding"], let plda = lease.models["PldaRho"]
        else { throw ServiceError("Download or verify the Community-1 model in Service Providers.") }
        let data = try Data(contentsOf: lease.directory.appendingPathComponent("plda-parameters.json"))
        let parameters = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tensors = parameters?["tensors"] as? [String: Any],
            let psi = tensors["psi"] as? [String: Any], let base64 = psi["data_base64"] as? String,
            let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count % 4 == 0
        else { throw ServiceError("The Community-1 model parameters are invalid. Verify the download.") }
        var values = [Float](repeating: 0, count: bytes.count / 4)
        _ = values.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        guard values.allSatisfy(\.isFinite) else { throw ServiceError("The Community-1 model parameters are invalid.") }
        let manager = OfflineDiarizerManager(config: Self.discoveryConfiguration)
        manager.initialize(
            models: OfflineDiarizerModels(
                segmentationModel: segmentation, fbankModel: fbank, embeddingModel: embedding,
                pldaRhoModel: plda, pldaPsi: values.map(Double.init), compilationDuration: 0))
        let extractor = recognize ? try CommunityVoiceEmbeddingExtractor(models: lease.models) : nil
        var output = LocalDiarizationResult(modelRevision: lease.revision, ranges: [], speakers: [])
        let durations = try AudioTaskProgress.durations(files)
        let total = durations.reduce(0, +)
        var completed = 0.0
        var inferenceSeconds = 0.0
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard let sourceRevision = VoiceLibraryStore.revision(url: file) else {
                throw ServiceError("The source audio is unavailable. Restore it before diarizing speakers.")
            }
            await progress?("Preparing audio \(index + 1) of \(files.count)…")
            await taskProgress?(.init(.init(phase: "Preparing audio \(index + 1) of \(files.count)")))
            let preparedAudio = try await AudioPlaybackPreparation.prepare(file)
            defer { if preparedAudio.temporary { try? FileManager.default.removeItem(at: preparedAudio.url) } }
            let (source, loadSeconds) = try AudioSourceFactory().makeDiskBackedSource(
                from: preparedAudio.url, targetSampleRate: 16000)
            defer { source.cleanup() }
            let result: DiarizationResult
            let started = Date()
            let clockStart = SuspendingClock.now
            let channel = AudioProgressChannel(report: taskProgress)
            do {
                await progress?("Diarizing audio \(index + 1) of \(files.count)…")
                await taskProgress?(
                    .init(
                        .init(
                            phase: "Diarizing audio \(index + 1) of \(files.count)", completed: completed,
                            total: total, unit: "audio seconds", startedAt: started)))
                let prepared = try await manager.prepare(
                    audioSource: source, audioLoadingSeconds: loadSeconds
                ) { done, count in
                    if done < count {
                        channel.continuation.yield(
                            .init(
                                phase: "Finding speech in audio \(index + 1) of \(files.count)",
                                completed: Double(done), total: Double(count), unit: "chunks", startedAt: started))
                    }
                    else {
                        // Segmentation can finish before the overlapping embedding worker.
                        channel.continuation.yield(.init(phase: "Analyzing voices", startedAt: started))
                    }
                }
                await channel.finish()
                await taskProgress?(.init(.init(phase: "Grouping speakers", startedAt: started)))
                result = try manager.cluster(prepared)
                inferenceSeconds += AudioTaskProgress.elapsed(since: clockStart)
                completed += durations[index]
            }
            catch OfflineDiarizationError.noSpeechDetected {
                await channel.finish()
                inferenceSeconds += AudioTaskProgress.elapsed(since: clockStart)
                completed += durations[index]
                continue
            }
            catch {
                await channel.finish()
                throw error
            }
            await taskProgress?(.init(.init(phase: "Analysing voice excerpts")))
            try Task.checkCancellation()
            let track = "track\(index)"
            let sourceName = LocalDiarizationInputPolicy.sourceName(for: file)
            output.trackSources[track] = sourceName
            if output.audioReferences == nil { output.audioReferences = [] }
            output.audioReferences?.append(.init(trackID: track, source: sourceName, revision: sourceRevision))
            let prefix = sourceName == "microphone" ? "mic_" : (sourceName == "system" ? "sys_" : "speaker_")
            let voicePreparationStart = SuspendingClock.now
            let labels = Array(Set(result.segments.map(\.speakerId))).sorted()
            var turns: [LocalSpeakerTurn] = []
            var processedTurns = 0
            var lastTurnProgress = SuspendingClock.now
            for (slot, modelLabel) in labels.enumerated() {
                let label = prefix + String(format: "%02d", slot + 1)
                var speaker = MeetingSpeaker(label: label, track: track, providerName: "Community-1")
                speaker.independentTurnAttribution = true
                for segment in result.segments.filter({ $0.speakerId == modelLabel }) {
                    try Task.checkCancellation()
                    processedTurns += 1
                    if AudioTaskProgress.elapsed(since: lastTurnProgress) >= 1 {
                        await taskProgress?(
                            .init(
                                .init(
                                    phase: "Analyzing Voices", completed: Double(processedTurns),
                                    total: Double(result.segments.count), unit: "turns")))
                        lastTurnProgress = SuspendingClock.now
                    }
                    let start = Double(segment.startTimeSeconds)
                    let end = min(Double(segment.endTimeSeconds), Double(source.sampleCount) / 16000)
                    guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
                    let overlaps = result.segments.contains { other in
                        other.speakerId != modelLabel && Double(other.startTimeSeconds) < end
                            && Double(other.endTimeSeconds) > start
                    }
                    let range =
                        overlaps
                        ? nil
                        : LocalDiarizationInputPolicy.speechSamples(
                            start: start, end: end, sampleCount: source.sampleCount)
                    output.ranges.append(
                        .init(
                            track: track, label: label, start: start, end: end,
                            associationUncertain: range == nil ? true : nil))
                    guard let range else { continue }
                    let selected = VoiceSampleRange(
                        audioFile: file.lastPathComponent, source: sourceName,
                        start: Double(range.lowerBound) / 16000, end: Double(range.upperBound) / 16000)
                    var samples = [Float](repeating: 0, count: range.count)
                    try samples.withUnsafeMutableBufferPointer { buffer in
                        try source.copySamples(into: buffer.baseAddress!, offset: range.lowerBound, count: range.count)
                    }
                    let quality = VoiceSampleQuality.assess(
                        range: selected, audioRevision: sourceRevision,
                        scanConfiguration: VoiceDiscoveryConfiguration.community.pipeline, samples: samples)
                    guard let quality else {
                        output.ranges[output.ranges.count - 1].associationUncertain = true
                        continue
                    }
                    var turn = LocalSpeakerTurn(
                        track: track, label: label, start: start, end: end, sampleRange: selected,
                        audioRevision: sourceRevision, sampleQuality: quality)
                    // Keep inference sequential under the shared Community permit.
                    // Cancellation is checked again before retaining any model output.
                    if let extractor, quality.issue == nil {
                        do {
                            let vector = try await extractor.extract(samples: samples)
                            try Task.checkCancellation()
                            turn.voiceEmbedding = TypedVoiceEmbedding.normalizing(
                                type: CommunityVoiceEmbeddingExtractor.embeddingType, values: vector,
                                provenance: "Community-1 independent turn")
                        }
                        catch is CancellationError { throw CancellationError() }
                        catch {
                            // A failed extraction leaves this turn unidentified.
                        }
                    }
                    try Task.checkCancellation()
                    turns.append(turn)
                }
                // Retain one playable excerpt for manual naming/reference selection,
                // without using it as the identity of every turn in the cluster.
                if let selected = LocalSpeakerTurn.reviewRepresentative(turns.filter { $0.label == label }) {
                    speaker.voiceSampleRange = selected.sampleRange
                    speaker.voiceSampleRevision = selected.audioRevision
                    if let quality = selected.sampleQuality {
                        if output.sampleQualities == nil { output.sampleQualities = [:] }
                        output.sampleQualities?[VoiceSampleQuality.speakerKey(track: track, label: label)] = quality
                    }
                }
                output.speakers.append(speaker)
            }
            if output.turnSamples == nil { output.turnSamples = [] }
            output.turnSamples?.append(contentsOf: turns)
            inferenceSeconds += AudioTaskProgress.elapsed(since: voicePreparationStart)
            guard VoiceLibraryStore.revision(url: file) == sourceRevision else {
                throw ServiceError("The source audio changed during analysis. Run speaker diarization again.")
            }
        }
        try Task.checkCancellation()
        await taskProgress?(
            .init(
                .init(phase: "Speaker analysis complete", completed: completed, total: total, unit: "audio seconds"),
                processedAudioSeconds: completed, processingSeconds: inferenceSeconds))
        return output
    }
}

enum LocalDiarizationAssignment {
    /// Keep exact text and explicit person assignments. Untimed words cannot be
    /// split safely, so only assign a clear majority of one source's activity.
    static func applying(_ result: LocalDiarizationResult, to meeting: Meeting, fileCount: Int) -> Meeting {
        if meeting.transcript.contains(where: { $0.timing?.isValid == true && $0.timing?.text == $0.text }) {
            return DiarizedTranscriptProjection.applying(result, to: meeting, fileCount: fileCount)
        }
        var updated = meeting
        if meeting.transcript.isEmpty {
            let assigned = meeting.speakers.filter { $0.personID != nil || $0.manuallyAssigned == true }
            var speakers = result.speakers.map { candidate in
                assigned.first { $0.id == candidate.id } ?? candidate
            }
            for speaker in assigned where !speakers.contains(where: { $0.id == speaker.id }) {
                speakers.append(speaker)
            }
            updated.replaceSpeakers(speakers)
            return updated
        }
        var speakers = meeting.speakers
        let oldByID = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        for index in updated.transcript.indices {
            let row = updated.transcript[index]
            updated.transcript[index] = assigningWholePassage(
                row, oldSpeaker: row.speakerID.flatMap { oldByID[$0] }, result: result, fileCount: fileCount)
        }
        for speaker in result.speakers where updated.transcript.contains(where: { $0.speakerID == speaker.id }) {
            if !speakers.contains(where: { $0.id == speaker.id }) { speakers.append(speaker) }
        }
        // A real acoustic cluster can have a clean review example even when no
        // whole transcript row has enough exclusive support to take its label.
        let reviewable = result.speakers.filter {
            ($0.resolvedVoiceEmbedding?.isValid == true || $0.independentTurnAttribution == true)
                && $0.voiceSampleRange?.isValid == true
        }
        for speaker in reviewable where !speakers.contains(where: { $0.id == speaker.id }) {
            speakers.append(speaker)
        }
        let used = Set(updated.transcript.compactMap(\.speakerID)).union(reviewable.map(\.id))
        updated.replaceSpeakers(speakers.filter { used.contains($0.id) })
        return updated
    }

    /// Preserve a passage's text and interval when no word alignment is available.
    /// Use the same conservative whole-passage evidence in mixed and legacy transcripts.
    static func assigningWholePassage(
        _ row: TranscriptSegment, oldSpeaker old: MeetingSpeaker?, result: LocalDiarizationResult, fileCount: Int
    ) -> TranscriptSegment {
        if old?.protectsManualAssignment(to: row) == true
            || (old?.personID != nil && old?.manualReviewThrough == nil && old?.voiceReviewOrigin == nil)
        {
            return row
        }
        let track: String?
        if let value = old?.track, value.hasPrefix("track") {
            track = value
        }
        else if fileCount == 1 {
            track = "track0"
        }
        else if let value = row.source?.rawValue ?? old?.track {
            let source = value == "mic" ? "microphone" : (value == "system_mix" ? "system" : value)
            let candidates = result.trackSources.filter { $0.value == source && source != "unknown" }
            track = candidates.count == 1 ? candidates.first?.key : nil
        }
        else {
            track = nil
        }
        guard let track, row.end > row.start else { return row }
        var overlaps: [String: Double] = [:]
        for interval in result.ranges where interval.track == track {
            overlaps[interval.label, default: 0] += max(
                0, min(row.end, interval.end) - max(row.start, interval.start))
        }
        let ranked = overlaps.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value / (row.end - row.start) >= 0.6,
            ranked.dropFirst().allSatisfy({ $0.value < best.value * 0.25 }),
            let speaker = result.speakers.first(where: { $0.track == track && $0.label == best.key })
        else { return row }
        var assigned = row
        assigned.speakerID = speaker.id
        assigned.speaker = speaker.label
        assigned.sourcePlaceholder = false
        assigned.personID = nil
        assigned.associationUncertain =
            result.ranges.contains {
                $0.track == track && $0.label == best.key && $0.associationUncertain == true
                    && $0.start < row.end && row.start < $0.end
            } ? true : nil
        return assigned
    }

}

extension MeetingStore {
    func scheduleAutomaticSpeakerLabeling(id: UUID) async {
        guard settings.labelRecordedSpeakers, recordingID != id,
            let meeting = meeting(id: id), !meeting.audioFiles.isEmpty
        else { return }
        // Always analyze the saved recording. A historical live evidence journal
        // must not substitute for a complete post-recording speaker timeline.
        _ = await queueSpeakerLabeling(id: id, automatically: true)
    }

    func diarizeLocally(id: UUID) async {
        guard let taskID = await queueSpeakerLabeling(id: id) else { return }
        await waitForManagedTask(taskID)
        if let task = managedTasks.first(where: { $0.id == taskID }), task.state == .failed {
            errorMessage = task.errorMessage
        }
    }

    func performLocalDiarization(id: UUID, providerID: UUID?) async throws {
        await voiceLibrary.awaitLoaded()
        guard libraryWritable, recordingID != id, let meeting = meeting(id: id),
            meeting.transcriptionAttempt == nil, !isJobRunning(.transcription, .meeting(id)),
            let provider = settings.serviceProviders.first(where: {
                $0.id == providerID
            }),
            provider.kind == .speakerLabeling, provider.supports(.diarization)
        else {
            throw ServiceError(
                "Choose the Speaker Diarization provider in Settings before diarizing a saved transcript.")
        }
        let files = audioURLs(for: meeting)
        guard !files.isEmpty else { throw ServiceError("This meeting has no local audio to label.") }
        guard files.count == meeting.audioFiles.count else {
            throw ServiceError("Some meeting audio is missing. Restore the audio files before diarizing speakers.")
        }
        let sourceRevisions = try LocalDiarizationInputPolicy.revisions(for: files)
        let pipeline = managedTasks.first { $0.kind == .diarization && $0.meetingID == id && $0.state == .running }?
            .pipelineID
        let recognize = pipeline == nil && settings.recognizeSpeakers
        setJobProgress(.diarization, .meeting(id), "Preparing the speaker model…")
        let manager = LocalModelManager.shared
        let lease = try await manager.acquire(.community1)
        defer { manager.release(lease) }
        let journalDirectory = self.directory(for: id)
        var event = MeetingDataEvent(
            action: .sent,
            dataFlow: .init(
                location: .local, targetID: provider.id, targetName: provider.name,
                startedAt: Date(),
                bodies: ["Saved audio", "Speaker activity", "Typed voice embeddings"],
                filePaths: meeting.audioFiles,
                purpose: recognize ? "Saved speaker diarization and association" : "Saved speaker labels"))
        try DataEventJournal.append(event, directory: journalDirectory)
        defer {
            event.dataFlow.endedAt = Date()
            do { try DataEventJournal.append(event, directory: journalDirectory) }
            catch { self.errorMessage = "Couldn’t save the speaker processing data event." }
        }
        setJobProgress(.diarization, .meeting(id), "Diarizing speakers…")
        let progressAttempt = jobProgressAttemptID(.diarization, .meeting(id))
        let performanceKey = TaskPerformanceKey(
            operation: "diarization", provider: provider.kind.rawValue, model: lease.revision)
        let measurement = AudioPerformanceMeasurement()
        let reportDetails: @Sendable (AudioTaskProgress) async -> Void = { [weak self] update in
            await measurement.include(update)
            await self?.reportAudioTaskProgress(
                update, kind: .diarization, meetingID: id, key: performanceKey, attemptID: progressAttempt)
        }
        let report: @Sendable (String) async -> Void = { [weak self] progress in
            await self?.setJobProgress(
                .diarization, .meeting(id), progress, details: .init(phase: progress), attemptID: progressAttempt)
        }
        let references = AudioAnalysisArtifacts.audio(files: files, revisions: sourceRevisions)
        let request = DiarizationAnalysisRequest(
            context: .init(requestID: UUID(), providerID: provider.id, model: lease.revision, audio: references),
            minimumSpeakers: nil, maximumSpeakers: nil)
        let result = try await ProcessingCoordinator.shared.withPermit(for: .inference, priority: .processing) {
            let analysis = try await CommunityRecordedAnalysisProvider(
                lease: lease, extractVoiceEmbeddings: true, taskProgress: reportDetails
            )
            .diarize(
                request: request,
                files: zip(files, references).map {
                    AnalysisAudioFile(reference: $0.1, url: $0.0)
                }, progress: report)
            return analysis.localResult()
        }
        try Task.checkCancellation()
        guard !result.ranges.isEmpty else {
            throw ServiceError("No speech was found for speaker diarization. The current transcript was kept.")
        }
        setJobProgress(
            .diarization, .meeting(id), "Saving speaker labels…", details: .init(phase: "Saving speaker labels"),
            attemptID: progressAttempt)
        let current = try await validatedMeetingForSpeakerLabeling(
            resultID: result.id, original: meeting, files: files, sourceRevisions: sourceRevisions)
        let saved = await enqueueCanonical { [self] in
            do {
                guard libraryWritable, !deletingMeetingIDs.contains(id),
                    let index = meetings.firstIndex(where: { $0.id == id }),
                    meetings[index].transcript == current.transcript,
                    meetings[index].transcriptSource == current.transcriptSource,
                    meetings[index].speakers == current.speakers,
                    meetings[index].audioFiles == current.audioFiles
                else { throw ServiceError("The transcript changed before speaker labels could be saved.") }
                let folder = directory(for: id)
                var input = meetings[index]
                let savedRevisions = try TranscriptRevisions.read(at: folder).revisions
                let normalized = TranscriptRevisions.snapshots(savedRevisions, current: input)
                    .first(where: { $0.id == TranscriptRevisions.current(input).id })
                input.transcriptSource =
                    normalized?.source
                    ?? input.transcriptSource
                    ?? .init(id: input.id, providerName: "Transcript", generatedAt: input.createdAt)
                let audio = AudioAnalysisArtifacts.audio(files: files, revisions: sourceRevisions)
                var artifacts: [CanonicalMeetingArtifact] = []
                if let source = try AudioAnalysisArtifacts.source(meeting: input, audio: audio, directory: folder) {
                    artifacts.append(source)
                }
                if let history = try AudioAnalysisArtifacts.history(meeting: input, directory: folder) {
                    artifacts.append(history)
                }
                artifacts.append(
                    try AudioAnalysisArtifacts.immutable(
                        result, name: "speaker-labels-\(result.id).json", meetingID: id, directory: folder))
                artifacts.append(
                    try AudioAnalysisArtifacts.immutable(
                        DiarizationProjectionArtifact(
                            sourceID: input.transcriptSource!.id, resultID: result.id, audio: audio),
                        name: "diarization-projection-\(result.id).json", meetingID: id, directory: folder))
                var updated = LocalDiarizationAssignment.applying(result, to: input, fileCount: files.count)
                updated.speakerLabelSource = .init(
                    resultID: result.id, providerName: provider.name, generatedAt: result.generatedAt)
                guard voiceLibrary.ingest(meeting: updated, directory: folder) else {
                    throw ServiceError(
                        voiceLibrary.errorMessage ?? "Couldn’t save the speaker examples for People review.")
                }
                guard
                    voiceLibrary.upsert(
                        VoiceLibraryPreparation.turnExamples(result: result, meetingID: id))
                else {
                    throw ServiceError(voiceLibrary.errorMessage ?? "Couldn’t save speaker turn examples.")
                }
                updated = voiceLibrary.applyingDecisions(to: updated)
                markManagedTaskCompletion(on: &updated, kind: .diarization)
                meetings[index] = updated
                invalidateExternalMeetingReloads(ids: [id])
                return await performCanonicalSave(
                    artifacts: artifacts,
                    validateInputs: {
                        guard try LocalDiarizationInputPolicy.revisions(for: files) == sourceRevisions else {
                            throw ServiceError("The source audio changed before speaker labels could be saved.")
                        }
                    })
            }
            catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        guard saved else { throw ServiceError(errorMessage ?? "Couldn’t save speaker labels.") }
        if recognize {
            let policy =
                settings.serviceProviders.first { $0.id == settings.diarizationProviderID }?.voiceMatchingPolicy
                ?? .default
            await self.voiceLibrary.suggestReviewedPeople(from: self.people, policy: policy)
        }
        await commitAudioPerformance(
            measurement, kind: .diarization, meetingID: id, key: performanceKey, attemptID: progressAttempt)
    }

    /// Binding is durable before applying the result. Read the current meeting
    /// after that suspension so unrelated edits are kept and changed inputs reject
    /// the stale labels before any transcript or voice-library mutation.
    func validatedMeetingForSpeakerLabeling(
        resultID: UUID, original: Meeting, files: [URL], sourceRevisions: [URL: String]
    ) async throws -> Meeting {
        try await bindSpeakerLabelingResult(resultID, meetingID: original.id)
        guard let current = meeting(id: original.id), libraryWritable,
            current.audioFiles == original.audioFiles, current.transcriptSource == original.transcriptSource,
            current.transcript == original.transcript, current.speakers == original.speakers,
            try LocalDiarizationInputPolicy.revisions(for: files) == sourceRevisions
        else {
            throw ServiceError(
                "The meeting changed while speaker diarization was running. Run it again for the current transcript.")
        }
        return current
    }

    func cancelLocalDiarization(id: UUID) async {
        if let task = managedTasks.first(where: { $0.kind == .diarization && $0.meetingID == id && $0.state.isActive })
        {
            await cancelManagedTask(id: task.id)
        }
    }
}
