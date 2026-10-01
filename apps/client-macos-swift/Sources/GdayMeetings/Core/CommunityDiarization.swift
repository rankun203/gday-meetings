import CoreML
import FluidAudio
import Foundation

struct LocalSpeakerRange: Codable, Equatable, Sendable {
    var track: String
    var label: String
    var start: Double
    var end: Double
}

struct LocalDiarizationResult: Codable {
    var version = 1
    var id = UUID()
    var generatedAt = Date()
    var modelRevision: String
    var ranges: [LocalSpeakerRange]
    var speakers: [MeetingSpeaker]
    var trackSources: [String: String] = [:]
}

enum LocalDiarizationInputPolicy {
    static func sourceName(for file: URL) -> String {
        switch file.deletingPathExtension().lastPathComponent.lowercased() {
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
    func run(files: [URL], lease: LocalModelLease, recognize: Bool) async throws -> LocalDiarizationResult {
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
        let manager = OfflineDiarizerManager()
        manager.initialize(
            models: OfflineDiarizerModels(
                segmentationModel: segmentation, fbankModel: fbank, embeddingModel: embedding,
                pldaRhoModel: plda, pldaPsi: values.map(Double.init), compilationDuration: 0))
        let extractor = recognize ? try CommunityVoiceEmbeddingExtractor(models: lease.models) : nil
        var output = LocalDiarizationResult(modelRevision: lease.revision, ranges: [], speakers: [])
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let preparedAudio = try await AudioPlaybackPreparation.prepare(file)
            defer { if preparedAudio.temporary { try? FileManager.default.removeItem(at: preparedAudio.url) } }
            let (source, loadSeconds) = try AudioSourceFactory().makeDiskBackedSource(
                from: preparedAudio.url, targetSampleRate: 16000)
            defer { source.cleanup() }
            let result: DiarizationResult
            do {
                result = try await manager.process(audioSource: source, audioLoadingSeconds: loadSeconds)
            }
            catch OfflineDiarizationError.noSpeechDetected { continue }
            try Task.checkCancellation()
            let track = "track\(index)"
            let sourceName = LocalDiarizationInputPolicy.sourceName(for: file)
            output.trackSources[track] = sourceName
            let prefix = sourceName == "microphone" ? "mic_" : (sourceName == "system" ? "sys_" : "speaker_")
            let labels = Array(Set(result.segments.map(\.speakerId))).sorted()
            for (slot, modelLabel) in labels.enumerated() {
                let label = prefix + String(format: "%02d", slot + 1)
                let segments = result.segments.filter { $0.speakerId == modelLabel }
                var speaker = MeetingSpeaker(label: label, track: track, providerName: "Community-1")
                for segment in segments {
                    let start = Double(segment.startTimeSeconds)
                    let end = min(Double(segment.endTimeSeconds), Double(source.sampleCount) / 16000)
                    guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
                    output.ranges.append(.init(track: track, label: label, start: start, end: end))
                }
                // Do not label FluidAudio's clustered/PLDA vectors as our live
                // extractor's type. Extract the same raw WeSpeaker representation.
                if let extractor,
                    let span = segments.filter({
                        LocalDiarizationInputPolicy.speechSamples(
                            start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
                            sampleCount: source.sampleCount) != nil
                    }).sorted(by: { $0.durationSeconds > $1.durationSeconds }).first(where: {
                        candidate in
                        candidate.durationSeconds >= 2
                            && !result.segments.contains { other in
                                other.speakerId != modelLabel && other.startTimeSeconds < candidate.endTimeSeconds
                                    && other.endTimeSeconds > candidate.startTimeSeconds
                            }
                    }),
                    let range = LocalDiarizationInputPolicy.speechSamples(
                        start: Double(span.startTimeSeconds), end: Double(span.endTimeSeconds),
                        sampleCount: source.sampleCount)
                {
                    let offset = range.lowerBound
                    let count = range.count
                    var samples = [Float](repeating: 0, count: count)
                    try samples.withUnsafeMutableBufferPointer { buffer in
                        try source.copySamples(into: buffer.baseAddress!, offset: offset, count: count)
                    }
                    if let vector = try? await extractor.extract(samples: samples) {
                        speaker.voiceEmbedding = TypedVoiceEmbedding.normalizing(
                            type: .community1, values: vector, provenance: "Community-1 selected speech")
                    }
                    try Task.checkCancellation()
                }
                output.speakers.append(speaker)
            }
        }
        return output
    }
}

enum LocalDiarizationAssignment {
    /// Keep exact text and explicit person assignments. Untimed words cannot be
    /// split safely, so only assign a clear majority of one source's activity.
    static func applying(_ result: LocalDiarizationResult, to meeting: Meeting, fileCount: Int) -> Meeting {
        var updated = meeting
        var speakers = meeting.speakers
        let oldByID = Dictionary(uniqueKeysWithValues: meeting.speakers.map { ($0.id, $0) })
        for index in updated.transcript.indices {
            let row = updated.transcript[index]
            let old = row.speakerID.flatMap { oldByID[$0] }
            if old?.personID != nil { continue }
            let track: String?
            if let value = old?.track, value.hasPrefix("track") {
                track = value
            }
            else if fileCount == 1 {
                track = "track0"
            }
            else if let value = old?.track {
                let source = value == "mic" ? "microphone" : (value == "system_mix" ? "system" : value)
                let candidates = result.trackSources.filter { $0.value == source && source != "unknown" }
                track = candidates.count == 1 ? candidates.first?.key : nil
            }
            else {
                track = nil
            }
            guard let track, row.end > row.start else { continue }
            var overlaps: [String: Double] = [:]
            for interval in result.ranges where interval.track == track {
                overlaps[interval.label, default: 0] += max(
                    0, min(row.end, interval.end) - max(row.start, interval.start))
            }
            let ranked = overlaps.sorted { $0.value > $1.value }
            guard let best = ranked.first, best.value / (row.end - row.start) >= 0.6,
                ranked.dropFirst().allSatisfy({ $0.value < best.value * 0.25 }),
                let speaker = result.speakers.first(where: { $0.track == track && $0.label == best.key })
            else { continue }
            if !speakers.contains(where: { $0.id == speaker.id }) { speakers.append(speaker) }
            updated.transcript[index].speakerID = speaker.id
            updated.transcript[index].speaker = speaker.label
        }
        let used = Set(updated.transcript.compactMap(\.speakerID))
        updated.replaceSpeakers(speakers.filter { used.contains($0.id) })
        return updated
    }
}

extension MeetingStore {
    func diarizeLocally(id: UUID) async {
        guard libraryWritable, recordingID != id, localDiarizationTasks[id] == nil,
            let meeting = meeting(id: id), !meeting.transcript.isEmpty,
            meeting.transcriptionAttempt == nil, !isJobRunning(.transcription, .meeting(id)),
            let providerID = settings.diarizationProviderID,
            let provider = settings.serviceProviders.first(where: { $0.id == providerID }),
            provider.kind == .community1, provider.supports(.diarization)
        else {
            errorMessage = "Choose Community-1 for Speaker Labels in Settings before labeling a saved transcript."
            return
        }
        let files = audioURLs(for: meeting)
        guard !files.isEmpty else {
            errorMessage = "This meeting has no local audio to label."
            return
        }
        guard files.count == meeting.audioFiles.count else {
            errorMessage = "Some meeting audio is missing. Restore the audio files before labeling speakers."
            return
        }
        guard beginJob(.diarization, .meeting(id), progress: "Labeling speakers…") else { return }
        let recognize =
            settings.recognizeSpeakers
            && settings.serviceProviders.contains {
                $0.id == settings.speakerRecognitionProviderID && $0.kind == .community1
                    && $0.supports(.speakerRecognition)
            }
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.localDiarizationTasks[id] = nil
                self.endJob(.diarization, .meeting(id))
            }
            do {
                let manager = LocalModelManager.shared
                let lease = try await manager.acquire(.community1)
                defer { manager.release(lease) }
                let journalDirectory = self.directory(for: id)
                var event = MeetingDataEvent(
                    action: .sent,
                    dataFlow: .init(
                        location: .local, targetID: provider.id, targetName: provider.name,
                        startedAt: Date(),
                        bodies: recognize
                            ? ["Saved audio", "Speaker activity", "Typed voice embeddings"]
                            : ["Saved audio", "Speaker activity"],
                        filePaths: meeting.audioFiles,
                        purpose: recognize ? "Saved speaker labels and recognition" : "Saved speaker labels"))
                try DataEventJournal.append(event, directory: journalDirectory)
                defer {
                    event.dataFlow.endedAt = Date()
                    do { try DataEventJournal.append(event, directory: journalDirectory) }
                    catch { self.errorMessage = "Couldn’t save the speaker processing data event." }
                }
                var result = try await CommunityDiarizationWorker().run(
                    files: files, lease: lease, recognize: recognize)
                try Task.checkCancellation()
                guard !result.ranges.isEmpty else {
                    throw ServiceError("No speech was found for speaker labeling. The current transcript was kept.")
                }
                guard let current = self.meeting(id: id), self.libraryWritable,
                    current.audioFiles == meeting.audioFiles, current.transcriptSource == meeting.transcriptSource
                else {
                    throw ServiceError(
                        "The meeting changed while speaker labeling was running. Run it again for the current transcript."
                    )
                }
                if recognize {
                    SpeakerRecognition.match(&result.speakers, people: self.people)
                }
                try PrivateTranscriptFile.write(
                    try JSONEncoder().encode(result), name: "speaker-labels-\(result.id).json",
                    at: self.directory(for: id))
                guard self.preserveTranscript(current) else { return }
                var updated = LocalDiarizationAssignment.applying(result, to: current, fileCount: files.count)
                updated.transcriptSource = .init(
                    id: result.id, providerName: "Community-1 Speaker Labels", generatedAt: result.generatedAt)
                _ = self.updateMeeting(updated)
            }
            catch is CancellationError {
                // The existing transcript remains active; a cancelled inference is never applied.
            }
            catch { self.errorMessage = error.localizedDescription }
        }
        localDiarizationTasks[id] = task
        await task.value
    }

    func cancelLocalDiarization(id: UUID) {
        localDiarizationTasks[id]?.cancel()
        setJobProgress(.diarization, .meeting(id), "Cancelling speaker labeling…")
    }
}
