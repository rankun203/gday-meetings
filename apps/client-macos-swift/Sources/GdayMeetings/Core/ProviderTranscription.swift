import AVFoundation
import Foundation

struct ProviderTranscriptionAttempt: Codable, Equatable {
    let providerID: UUID
    let endpoint: String
    let kind: ServiceProviderKind
    let title: String
    var idempotencyKey = UUID().uuidString
    var inputs: [ServerTrackInput] = []
    var taskID: String?
    var originalTranscript: [TranscriptSegment] = []
    var result: [TranscriptSegment]?
    var resultSpeakers: [MeetingSpeaker]?
    var originalSpeakers: [MeetingSpeaker]?
    var submissionUncertain = false
    var diarize = false
    var uploadProviderID: UUID?
    var uploadEndpoint: String?
    var uploadsExpireAt: Date?
    var language = "en"
    /// The exact provider code is saved before upload and remains fixed on retry.
    var providerLanguage: String?
    var failure: String?
    var remoteJobExpired: Bool?
}

extension ProviderTranscriptionAttempt {
    init(provider: ServiceProvider, meeting: Meeting) {
        self.init(
            providerID: provider.id, endpoint: provider.endpoint, kind: provider.kind, title: meeting.title,
            originalTranscript: meeting.transcript, originalSpeakers: meeting.speakers,
            diarize: provider.enabledCapabilities.contains(.diarization),
            language: meeting.language)
    }
}

extension MeetingStore {
    func transcribeWithProvider(id: UUID, provider: ServiceProvider) async throws {
        guard await ensureMeetingLoaded(id: id) else { throw ServiceError("This meeting no longer exists.") }
        guard libraryWritable else {
            throw ServiceError("Restore the local library before transcribing. Job progress must be saved first.")
        }
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        var attempt =
            meeting.transcriptionAttempt
            ?? ProviderTranscriptionAttempt(provider: provider, meeting: meeting)
        if meeting.transcriptionAttempt == nil {
            attempt.diarize =
                provider.supports(.diarization) && settings.shouldLabelDuringTranscription(providerID: provider.id)
        }
        guard attempt.providerID == provider.id, attempt.kind == provider.kind, attempt.endpoint == provider.endpoint
        else {
            throw ServiceError("Resume the pending transcription with its original provider and address.")
        }
        try await bindManagedTranscriptionAttempt(attempt, meetingID: id)
        if attempt.remoteJobExpired == true { throw MissingTranscriptionJob() }
        if attempt.taskID == nil && attempt.result == nil {
            try TranscriptionLanguage.validate(attempt.language)
        }
        if let failure = attempt.failure {
            throw ServiceError(
                failure + " Choose Discard Pending Request in Meeting Actions before starting another transcription.")
        }
        if let result = attempt.result {
            try await saveTranscriptionResult(result, attempt: attempt, meetingID: id)
            return
        }
        if attempt.taskID == nil {
            attempt.providerLanguage =
                provider.kind == .appleSpeech
                ? attempt.language
                : try await resolvedTranscriptionLanguage(
                    attempt.providerLanguage ?? attempt.language, for: provider,
                    preservingRequestCode: meeting.transcriptionAttempt != nil)
        }
        switch provider.kind {
        case .appleSpeech:
            try await saveTranscriptionAttempt(attempt, meetingID: id)
            let files = audioURLs(for: meeting)
            guard !files.isEmpty else { throw ServiceError("This meeting has no audio to transcribe.") }
            let startedAt = Date()
            let draft = try await AppleRecordedTranscription.transcribe(
                files: files, meetingID: id, language: attempt.language
            ) { message in
                await self.setJobProgress(.transcription, .meeting(id), message)
            }
            try Task.checkCancellation()
            recordDataFlow(
                DataFlow(
                    location: .local, targetID: provider.id, targetName: provider.name,
                    startedAt: startedAt, bodies: files.map(\.lastPathComponent), purpose: "Transcription"),
                meetingID: id)
            attempt.result = draft.segments
            attempt.resultSpeakers = draft.speakers
            try await saveTranscriptionAttempt(attempt, meetingID: id)
            try await saveTranscriptionResult(draft.segments, attempt: attempt, meetingID: id)
        case .gdayWebsite:
            let server = GdayServerService.shared
            let origin = try ServiceHTTP.origin(provider.endpoint).absoluteString
            guard server.connected, server.origin == origin else {
                throw ServiceError("Sign in to \(provider.name) in Service Providers.")
            }
            try await saveTranscriptionAttempt(attempt, meetingID: id)
            if attempt.taskID == nil {
                try await server.ensureTranscriptionAvailable()
                let files = audioURLs(for: meeting)
                guard !files.isEmpty else { throw ServiceError("This meeting has no audio to transcribe.") }
                for (index, file) in files.enumerated() where index >= attempt.inputs.count {
                    setJobProgress(
                        .transcription, .meeting(id),
                        "Uploading audio \(index + 1) of \(files.count) to \(provider.name)…")
                    let prepared = try await prepareServerAudio(file)
                    defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }
                    let uploadResult = try await server.upload(file: prepared.url, provider: provider)
                    recordDataFlow(uploadResult.dataFlow.referencing(file: file, prepared: prepared.url), meetingID: id)
                    let url = uploadResult.value
                    let isMic = file.deletingPathExtension().lastPathComponent.lowercased().contains("mic")
                    attempt.inputs.append(
                        ServerTrackInput(
                            url: url, trackName: "track\(index)",
                            sourceType: isMic ? "mic" : "system", channels: prepared.channels))
                    try await saveTranscriptionAttempt(attempt, meetingID: id)
                }
                let submission = try await server.submit(
                    externalID: id.uuidString, title: attempt.title, inputs: attempt.inputs,
                    language: attempt.providerLanguage ?? attempt.language,
                    diarize: attempt.diarize, idempotencyKey: attempt.idempotencyKey, provider: provider)
                recordDataFlow(submission.dataFlow.referencingAudio(files), meetingID: id)
                attempt.taskID = submission.value
                try await saveTranscriptionAttempt(attempt, meetingID: id)
            }
            guard let taskID = attempt.taskID else { throw ServiceError("The provider returned no job ID.") }
            var pollFailures = 0
            while true {
                try Task.checkCancellation()
                setJobProgress(.transcription, .meeting(id), "Waiting for \(provider.name)…")
                let status: ProviderResult<ServerTaskResult>
                do { status = try await server.task(id: taskID, provider: provider) }
                catch let error as ServiceHTTPStatusError where error.statusCode == 404 {
                    attempt.remoteJobExpired = true
                    try await saveTranscriptionAttempt(attempt, meetingID: id)
                    throw MissingTranscriptionJob()
                }
                catch {
                    try Task.checkCancellation()
                    guard Self.isTransientTranscriptionError(error) else { throw error }
                    pollFailures += 1
                    setJobProgress(.transcription, .meeting(id), "Connection interrupted. Retrying \(provider.name)…")
                    try await Task.sleep(for: transcriptionRetryDelay(failures: pollFailures))
                    continue
                }
                pollFailures = 0
                switch status.value {
                case .pending: try await Task.sleep(for: transcriptionPollDelay)
                case .failed(let message):
                    attempt.failure = message
                    try await saveTranscriptionAttempt(attempt, meetingID: id)
                    throw ServiceError(message + " Discard the pending request before starting another transcription.")
                case .complete(let segments):
                    recordDataFlow(status.dataFlow, meetingID: id, action: .received)
                    try Task.checkCancellation()
                    let recognized = SpeakerRecognition.result(
                        segments, attempt: attempt, people: settings.recognizeSpeakers ? people : [])
                    let result = recognized.segments
                    attempt.resultSpeakers = recognized.speakers
                    attempt.result = result
                    try await saveTranscriptionAttempt(attempt, meetingID: id)
                    try await saveTranscriptionResult(result, attempt: attempt, meetingID: id)
                    return
                }
            }
        case .runpod:
            try await transcribeOnRunPod(id: id, provider: provider, meeting: meeting, attempt: &attempt)
        case .openAICompatible, .filedrop, .nemotron, .community1, .localSearch:
            throw ServiceError("This provider doesn’t support transcription.")
        }
    }

    private func transcribeOnRunPod(
        id: UUID, provider: ServiceProvider, meeting: Meeting,
        attempt: inout ProviderTranscriptionAttempt
    ) async throws {
        let runpod = RunPodProvider(provider: provider)
        if attempt.taskID == nil {
            guard !attempt.submissionUncertain else {
                throw ServiceError(
                    "RunPod may have accepted the previous request. Check its job history before starting another transcription."
                )
            }
            let upload = try uploadProvider(for: provider, attempt: attempt)
            let filedrop = FiledropProvider(provider: upload)
            do { _ = try await ProviderConnectionChecker.check(provider) }
            catch let error as ServiceHTTPStatusError where error.statusCode == 404 {
                throw ServiceError(
                    "The RunPod connection check returned HTTP 404. Check the address for \(provider.name) in Service Providers. No transcription job was submitted."
                )
            }
            let info: FiledropInfo
            do {
                _ = try await filedrop.checkConnection()
                info = try await filedrop.info().value
            }
            catch let error as ServiceHTTPStatusError where error.statusCode == 404 {
                throw ServiceError(
                    "The audio upload connection check returned HTTP 404. Check the address for \(upload.name) in Service Providers. No transcription job was submitted."
                )
            }
            guard let expiry = attempt.uploadsExpireAt, expiry > Date() else {
                attempt.inputs = []
                attempt.uploadsExpireAt = nil
                attempt.uploadProviderID = upload.id
                attempt.uploadEndpoint = upload.endpoint
                try await saveTranscriptionAttempt(attempt, meetingID: id)
                return try await uploadAndSubmitRunPod(
                    id: id, provider: provider, upload: upload,
                    filedrop: filedrop, info: info, meeting: meeting, attempt: &attempt)
            }
            return try await uploadAndSubmitRunPod(
                id: id, provider: provider, upload: upload,
                filedrop: filedrop, info: info, meeting: meeting, attempt: &attempt)
        }
        try await pollRunPod(id: id, runpod: runpod, attempt: &attempt)
    }

    func uploadProvider(for provider: ServiceProvider, attempt: ProviderTranscriptionAttempt? = nil) throws
        -> ServiceProvider
    {
        let id = attempt?.uploadProviderID ?? provider.uploadProviderID
        guard let upload = settings.serviceProviders.first(where: { $0.id == id }),
            upload.kind == .filedrop, upload.supports(.fileTransfer)
        else {
            throw ServiceError("Add and enable a Filedrop provider, then select it under RunPod → Audio Uploads.")
        }
        if let endpoint = attempt?.uploadEndpoint, endpoint != upload.endpoint {
            throw ServiceError("Restore the original Filedrop address to resume this transcription.")
        }
        return upload
    }

    private func uploadAndSubmitRunPod(
        id: UUID, provider: ServiceProvider, upload: ServiceProvider,
        filedrop: FiledropProvider, info: FiledropInfo, meeting: Meeting,
        attempt: inout ProviderTranscriptionAttempt
    ) async throws {
        let files = audioURLs(for: meeting)
        guard !files.isEmpty else { throw ServiceError("This meeting has no audio to transcribe.") }
        attempt.uploadProviderID = upload.id
        attempt.uploadEndpoint = upload.endpoint
        try await saveTranscriptionAttempt(attempt, meetingID: id)
        for (index, file) in files.enumerated() where index >= attempt.inputs.count {
            setJobProgress(
                .transcription, .meeting(id), "Uploading audio \(index + 1) of \(files.count) to \(upload.name)…")
            let prepared = try await prepareFiledropAudio(file, allowedExtensions: info.allowedExtensions)
            defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }
            let uploadResult = try await filedrop.upload(file: prepared.url)
            recordDataFlow(uploadResult.dataFlow.referencing(file: file, prepared: prepared.url), meetingID: id)
            let receipt = uploadResult.value
            let isMic = file.deletingPathExtension().lastPathComponent.lowercased().contains("mic")
            attempt.inputs.append(
                ServerTrackInput(
                    url: receipt.url, trackName: "track\(index)",
                    sourceType: isMic ? "mic" : "system_mix", channels: prepared.channels))
            attempt.uploadsExpireAt = min(attempt.uploadsExpireAt ?? receipt.expiresAt, receipt.expiresAt)
            try await saveTranscriptionAttempt(attempt, meetingID: id)
        }
        guard let expiry = attempt.uploadsExpireAt, expiry.timeIntervalSinceNow > 30 else {
            throw ServiceError(
                "The uploaded audio links expire too soon. Increase Filedrop's retention period, then retry.")
        }
        // RunPod offers no submit idempotency guarantee. Persist uncertainty before
        // sending so a lost response never causes an automatic duplicate paid job.
        let runpod = RunPodProvider(provider: provider)
        let tracks = attempt.inputs.map {
            ProviderAudioTrack(url: $0.url, trackName: $0.trackName, sourceType: $0.sourceType)
        }
        _ = try runpod.submissionRequest(
            tracks: tracks, language: attempt.providerLanguage ?? attempt.language, diarize: attempt.diarize)
        attempt.submissionUncertain = true
        try await saveTranscriptionAttempt(attempt, meetingID: id)
        let submission = try await runpod.submit(
            tracks: tracks, language: attempt.providerLanguage ?? attempt.language, diarize: attempt.diarize)
        recordDataFlow(submission.dataFlow.referencingAudio(files), meetingID: id)
        attempt.taskID = submission.value
        attempt.submissionUncertain = false
        try await saveTranscriptionAttempt(attempt, meetingID: id)
        try await pollRunPod(id: id, runpod: runpod, attempt: &attempt)
    }

    private func pollRunPod(
        id: UUID, runpod: RunPodProvider,
        attempt: inout ProviderTranscriptionAttempt
    ) async throws {
        guard let jobID = attempt.taskID else { throw ServiceError("The transcription has no RunPod job ID.") }
        var pollFailures = 0
        while true {
            try Task.checkCancellation()
            setJobProgress(.transcription, .meeting(id), "Waiting for \(runpod.provider.name)…")
            let status: ProviderResult<ProviderTranscriptionStatus>
            do { status = try await runpod.status(jobID: jobID, expectedTracks: Set(attempt.inputs.map(\.trackName))) }
            catch let error as ServiceHTTPStatusError where error.statusCode == 404 {
                attempt.remoteJobExpired = true
                try await saveTranscriptionAttempt(attempt, meetingID: id)
                throw MissingTranscriptionJob()
            }
            catch {
                try Task.checkCancellation()
                guard Self.isTransientTranscriptionError(error) else { throw error }
                pollFailures += 1
                setJobProgress(
                    .transcription, .meeting(id), "Connection interrupted. Retrying \(runpod.provider.name)…")
                try await Task.sleep(for: transcriptionRetryDelay(failures: pollFailures))
                continue
            }
            pollFailures = 0
            switch status.value {
            case .pending: try await Task.sleep(for: transcriptionPollDelay)
            case .failed(let message):
                attempt.failure = message
                try await saveTranscriptionAttempt(attempt, meetingID: id)
                throw ServiceError(message + " Discard the pending request before starting another transcription.")
            case .complete(let segments):
                recordDataFlow(status.dataFlow, meetingID: id, action: .received)
                try Task.checkCancellation()
                let expected = Set(attempt.inputs.map(\.trackName))
                guard segments.allSatisfy({ expected.contains($0.track) }) else {
                    throw ServiceError("RunPod returned a transcript for an unexpected audio track.")
                }
                let recognized = SpeakerRecognition.result(
                    segments, attempt: attempt, people: settings.recognizeSpeakers ? people : [])
                let result = recognized.segments
                attempt.resultSpeakers = recognized.speakers
                attempt.result = result
                try await saveTranscriptionAttempt(attempt, meetingID: id)
                try await saveTranscriptionResult(result, attempt: attempt, meetingID: id)
                return
            }
        }

    }

    private static func isTransientTranscriptionError(_ error: Error) -> Bool {
        if let error = error as? URLError { return error.code != .cancelled }
        if let error = error as? ServiceHTTPStatusError { return error.statusCode == 429 || error.statusCode >= 500 }
        return false
    }

    private func transcriptionRetryDelay(failures: Int) -> Duration {
        min(max(transcriptionPollDelay, .milliseconds(1)) * (1 << min(failures, 4)), .seconds(30))
    }

    func saveTranscriptionAttempt(_ attempt: ProviderTranscriptionAttempt, meetingID: UUID) async throws {
        guard var latest = meetings.first(where: { $0.id == meetingID }) else {
            throw ServiceError("This meeting was deleted.")
        }
        latest.transcriptionAttempt = attempt
        errorMessage = nil
        guard await updateMeeting(latest) else {
            throw ServiceError(errorMessage ?? "Couldn’t save transcription progress.")
        }
        try await bindManagedTranscriptionAttempt(attempt, meetingID: meetingID)
    }

    func clearTranscriptionAttempt(meetingID: UUID) async throws {
        guard !isJobRunning(.transcription, .meeting(meetingID)) else {
            throw ServiceError("Wait for this transcription to finish before discarding its request.")
        }
        guard var latest = meetings.first(where: { $0.id == meetingID }) else { return }
        latest.transcriptionAttempt = nil
        errorMessage = nil
        await updateMeeting(latest)
        if let errorMessage { throw ServiceError(errorMessage) }
    }

    private func transcriptSource(_ attempt: ProviderTranscriptionAttempt) -> TranscriptSource {
        TranscriptSource(
            id: UUID(uuidString: attempt.idempotencyKey) ?? UUID(),
            providerName: settings.serviceProviders.first(where: { $0.id == attempt.providerID })?.name
                ?? attempt.kind.title,
            generatedAt: Date())
    }

    func applySavedTranscriptionResult(meetingID: UUID) async {
        guard !isJobRunning(.transcription, .meeting(meetingID)),
            var latest = meetings.first(where: { $0.id == meetingID }),
            let result = latest.transcriptionAttempt?.result
        else { return }
        guard preserveTranscript(latest) else { return }
        latest.replaceSpeakers(latest.transcriptionAttempt?.resultSpeakers ?? [])
        latest.transcript = result
        latest.speakerLabelSource = nil
        if let attempt = latest.transcriptionAttempt {
            latest.transcriptSource = transcriptSource(attempt)
        }
        latest.restoreSpeakerIdentities()
        markManagedTaskCompletion(on: &latest, kind: .transcription)
        latest.transcriptionAttempt = nil
        if await updateMeeting(latest) {
            await reconcileManagedTaskCompletion(for: latest, kind: .transcription)
            await scheduleAutomaticSpeakerLabeling(id: meetingID)
            scheduleAutomaticSummary(id: meetingID)
        }
    }

    func saveTranscriptionResult(_ result: [TranscriptSegment], attempt: ProviderTranscriptionAttempt, meetingID: UUID)
        async throws
    {
        guard var latest = meetings.first(where: { $0.id == meetingID }) else { return }
        guard latest.transcript == attempt.originalTranscript,
            attempt.originalSpeakers == nil || latest.speakers == attempt.originalSpeakers
        else {
            throw ServiceError(
                "The transcript was edited during processing. The new result is saved. Choose Apply Saved Transcript to review the replacement."
            )
        }
        guard preserveTranscript(latest) else {
            throw ServiceError(errorMessage ?? "Couldn’t save the previous transcript.")
        }
        latest.replaceSpeakers(attempt.resultSpeakers ?? [])
        latest.transcript = result
        latest.speakerLabelSource = nil
        latest.transcriptSource = transcriptSource(attempt)
        latest.restoreSpeakerIdentities()
        markManagedTaskCompletion(on: &latest, kind: .transcription)
        latest.transcriptionAttempt = nil
        errorMessage = nil
        guard await updateMeeting(latest) else {
            throw ServiceError(errorMessage ?? "Couldn’t save the transcript.")
        }
        scheduleAutomaticSummary(id: meetingID)
    }
}

func prepareServerAudio(_ file: URL, compressPCM: Bool = true) async throws -> (
    url: URL, temporary: Bool, channels: Int
) {
    // Preserve the primary Ogg Opus recording; AVAsset cannot inspect Ogg.
    if ["opus", "ogg"].contains(file.pathExtension.lowercased()) {
        let channels = try AudioPlaybackPreparation.opusChannels(file)
        return (file, false, channels)
    }
    let allowed = ["wav", "flac", "mp3", "m4a", "ogg", "opus", "mp4", "webm", "aac"]
    var prepared = file
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let suffix = file.pathExtension.lowercased()
    let temporary =
        !allowed.contains(suffix) || size > 450_000_000
        || (compressPCM && ["wav", "aif", "aiff", "caf"].contains(suffix))
    if temporary {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            if try !encodeBoundedAAC(file: file, destination: destination) {
                // Apple's M4A preset is a format preset, not a fixed bitrate guarantee.
                // https://developer.apple.com/documentation/avfoundation/avassetexportpresetapplem4a
                guard
                    let exporter = AVAssetExportSession(
                        asset: AVURLAsset(url: file), presetName: AVAssetExportPresetAppleM4A),
                    exporter.supportedFileTypes.contains(.m4a)
                else { throw ServiceError("Could not convert this audio format for the server.") }
                try Task.checkCancellation()
                try await exporter.export(to: destination, as: .m4a)
            }
            try Task.checkCancellation()
            let outputSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard outputSize > 0, outputSize <= 500_000_000 else {
                throw ServiceError(
                    "The converted audio exceeds the server's 500 MB limit. Split this recording before uploading.")
            }
        }
        catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        prepared = destination
    }
    do {
        let audio = try AVAudioFile(forReading: prepared)
        return (prepared, temporary, Int(audio.processingFormat.channelCount))
    }
    catch {
        // AVAudioFile doesn't decode every server-supported container. AVAsset can inspect video audio tracks.
        let tracks = try await AVURLAsset(url: prepared).loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            if temporary { try? FileManager.default.removeItem(at: prepared) }
            throw ServiceError("The selected file contains no audio track.")
        }
        let formats = try await track.load(.formatDescriptions)
        let channels = formats.first.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
        }
        return (prepared, temporary, Int(channels ?? 1))
    }
}

/// Convert ordinary captured PCM in bounded buffers, retaining channel separation,
/// sample rate, and every frame. 64kbps mono/128kbps stereo keeps a one-hour recording
/// near 29/58 MB. The worker independently downmixes each source to 16kHz mono;
/// mic/system must remain separate tracks, not channels of one combined file.
/// Apple audio settings: https://developer.apple.com/documentation/avfoundation/audio-settings
private func encodeBoundedAAC(file: URL, destination: URL) throws -> Bool {
    guard let source = try? AVAudioFile(forReading: file, commonFormat: .pcmFormatFloat32, interleaved: false) else {
        return false
    }
    let format = source.processingFormat
    guard (1...2).contains(format.channelCount), [44100.0, 48000.0].contains(format.sampleRate) else { return false }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
        AVEncoderBitRateKey: Int(format.channelCount) * 64000,
    ]
    var output: AVAudioFile? = try AVAudioFile(
        forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
        throw ServiceError("Could not allocate the audio conversion buffer.")
    }
    while source.framePosition < source.length {
        try Task.checkCancellation()
        try source.read(into: buffer)
        guard buffer.frameLength > 0 else {
            throw ServiceError("Audio conversion ended before the recording was complete.")
        }
        try output?.write(from: buffer)
    }
    // Releasing AVAudioFile finalizes its AAC packet table before inspection/upload.
    output = nil
    return true
}

func prepareFiledropAudio(_ file: URL, allowedExtensions: [String]) async throws -> (
    url: URL, temporary: Bool, channels: Int
) {
    let suffix = file.pathExtension.lowercased()
    if allowedExtensions.contains(suffix) {
        if ["opus", "ogg"].contains(suffix) { return (file, false, try AudioPlaybackPreparation.opusChannels(file)) }
        return (file, false, Int(try AVAudioFile(forReading: file).processingFormat.channelCount))
    }
    guard allowedExtensions.contains("opus") else {
        throw ServiceError("Filedrop does not accept this audio format. Enable Opus uploads on the Filedrop service.")
    }
    let source = try await AudioPlaybackPreparation.prepare(file)
    defer { if source.temporary { try? FileManager.default.removeItem(at: source.url) } }
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
    do {
        try await RecordingEncoder.encode(source: source.url, destination: destination, format: .opus)
        return (destination, true, try AudioPlaybackPreparation.opusChannels(destination))
    }
    catch {
        try? FileManager.default.removeItem(at: destination)
        throw error
    }
}
