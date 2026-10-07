import Foundation

enum ThisMacProvider {
    static let id = UUID(uuidString: "5987605A-1329-46E3-906D-2EC2D08B4D16")!
    static let capabilities: Set<ProviderCapability> = [.liveTranscription, .transcription]
    static func transcriptionProvider(settings: AppSettings) -> ServiceProvider {
        var provider = ServiceProvider(kind: .appleSpeech)
        provider.id = id
        provider.enabledCapabilities = settings.thisMacCapabilities
        return provider
    }
}

enum TranscriptionLanguage {
    static func isExplicit(_ language: String) -> Bool {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !value.isEmpty && value != "auto"
    }

    static func validate(_ language: String) throws {
        guard isExplicit(language) else {
            throw ServiceError("Choose a language for this meeting.")
        }
    }
}

/// App capability contracts are documented in docs/protocols/.
enum ProviderCapability: String, Codable, CaseIterable, Identifiable {
    case transcription, liveTranscription, liveDiarization, diarization, speakerRecognition, summarization, search,
        playback, fileTransfer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transcription: return "Transcription"
        case .liveTranscription: return "Live Transcription"
        case .liveDiarization: return "Live Speaker Labeling"
        case .speakerRecognition: return "Speaker Association"
        case .diarization: return "Speaker Labeling"
        case .summarization: return "Summarization"
        case .search: return "Search"
        case .playback: return "Playback"
        case .fileTransfer: return "File Transfer"
        }
    }
}

enum ServiceProviderKind: String, Codable, CaseIterable, Identifiable {
    case runpod, openAICompatible, gdayWebsite, filedrop, nemotron, community1, localSearch, appleSpeech
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleSpeech: return "This Mac"
        case .runpod: return "RunPod"
        case .filedrop: return "Filedrop"
        case .openAICompatible: return "OpenAI-Compatible LLM"
        case .gdayWebsite: return "Gday Meetings Website"
        case .nemotron: return "Live Speaker Labeling (Nemotron)"
        case .community1: return "Speaker Labeling (Community-1)"
        case .localSearch: return "Local Search"
        }
    }
    var systemImage: String {
        switch self {
        case .appleSpeech: "desktopcomputer"
        case .nemotron, .community1: "person.wave.2"
        case .localSearch: "text.magnifyingglass"
        case .gdayWebsite: "globe"
        case .runpod, .openAICompatible, .filedrop: "server.rack"
        }
    }
    var capabilities: Set<ProviderCapability> {
        switch self {
        case .appleSpeech: return ThisMacProvider.capabilities
        case .runpod: return [.transcription, .diarization]
        case .filedrop: return [.fileTransfer]
        case .openAICompatible: return [.summarization]
        // Search and remote playback have no app adapters. Do not advertise them as available.
        case .gdayWebsite: return [.transcription, .diarization]
        case .nemotron: return [.liveDiarization, .speakerRecognition]
        case .community1: return [.diarization, .speakerRecognition]
        case .localSearch: return [.search]
        }
    }
    var isLocalSpeaker: Bool { self == .nemotron || self == .community1 }
    var isLocal: Bool { isLocalSpeaker || self == .localSearch || self == .appleSpeech }
}

struct ServiceProvider: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ServiceProviderKind
    var name: String
    var endpoint = ""
    var apiKey = ""
    var model = ""
    var localSearch: LocalSearchConfiguration?
    // Scoped to the exact endpoint/model; switching either returns to automatic detection.
    var summaryImageOverride: SummaryImageOverride?
    var summarizationPrompt: String?
    var summaryPrompt: String {
        get { summarizationPrompt ?? SummaryPrompt.defaultInstructions }
        set { summarizationPrompt = newValue }
    }
    var uploadProviderID: UUID?
    var isEnabled = true
    var enabledCapabilities: Set<ProviderCapability> = []
    // Older Nemotron providers could not opt in or out of association.
    private var capabilityVersion = 2
    init(kind: ServiceProviderKind) {
        self.kind = kind
        name = kind.title
        enabledCapabilities = kind.capabilities
        if kind == .nemotron { model = "nemotronLow" }
        if kind == .community1 { model = "community1" }
        if kind == .localSearch { localSearch = LocalSearchConfiguration() }
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, name, endpoint, model, isEnabled, enabledCapabilities, uploadProviderID, summarizationPrompt
        case summaryImageOverride, capabilityVersion, localSearch
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(ServiceProviderKind.self, forKey: .kind)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        endpoint = try values.decode(String.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
        localSearch = try values.decodeIfPresent(LocalSearchConfiguration.self, forKey: .localSearch)
        if kind == .localSearch, ["Local Voice Search (CLSP)", "Local Voice Search"].contains(name) {
            name = "Local Search"
        }
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        // Retired worker configurations cannot silently activate semantic search.
        if kind == .localSearch {
            let legacy = try values.decodeIfPresent(RetiredSearchConfiguration.self, forKey: .localSearch)
            if localSearch?.semanticModel == nil,
                model.lowercased().contains("clsp") || legacy?.executableURL != nil || legacy?.modelCacheURL != nil
            {
                isEnabled = false
                model = ""
                localSearch = .init()
            }
            else if model.lowercased().contains("clsp") {
                model = ""
            }
        }
        enabledCapabilities = try values.decode(Set<ProviderCapability>.self, forKey: .enabledCapabilities)
        uploadProviderID = try values.decodeIfPresent(UUID.self, forKey: .uploadProviderID)
        summarizationPrompt = try values.decodeIfPresent(String.self, forKey: .summarizationPrompt)
        summaryImageOverride = try values.decodeIfPresent(SummaryImageOverride.self, forKey: .summaryImageOverride)
        if kind == .nemotron, (try values.decodeIfPresent(Int.self, forKey: .capabilityVersion) ?? 1) < 2 {
            enabledCapabilities.insert(.speakerRecognition)
        }
    }

    private struct RetiredSearchConfiguration: Decodable {
        let executableURL: URL?
        let modelCacheURL: URL?
    }

    func supports(_ capability: ProviderCapability) -> Bool {
        isEnabled && kind.capabilities.contains(capability) && enabledCapabilities.contains(capability)
    }
}

struct ProviderAudioTrack {
    let url: URL
    let trackName: String
    let sourceType: String
}
enum ProviderTranscriptionStatus {
    case pending
    case complete([ServerTranscriptSegment])
    case failed(String)
}
protocol TranscriptionProvider {
    func submit(tracks: [ProviderAudioTrack], language: String, diarize: Bool) async throws -> ProviderResult<String>
    func status(jobID: String) async throws -> ProviderResult<ProviderTranscriptionStatus>
    @discardableResult func cancel(jobID: String) async throws -> ProviderResult<Void>
}
/// Speaker labels can be requested in the same audio job as transcription.
protocol DiarizationProvider: TranscriptionProvider {}
protocol SummarizationProvider {
    func summarize(transcript: String, instructions: String) async throws -> ProviderResult<String>
}
struct ProviderSearchDocument: Codable {
    let meetingID: String
    let revision: String
    let title: String
    let transcript: String
    let summary: String
}
struct ProviderPlaybackResource {
    let meetingID: String
    let duration: TimeInterval
    let request: URLRequest
}
protocol PlaybackProvider {
    func upload(file: URL, meetingID: String) async throws -> ProviderResult<Void>
    func playback(meetingID: String) async throws -> ProviderResult<ProviderPlaybackResource>
    func remove(meetingID: String) async throws -> ProviderResult<Void>
}

enum ProviderEndpoint {
    static func base(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil,
            url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
        else { throw ServiceError("Enter an HTTPS endpoint URL. HTTP is supported on localhost.") }
        return url
    }
    static func runpod(_ text: String) throws -> URL {
        let url = try base(text)
        guard !["run", "runsync", "health", "status", "cancel"].contains(url.lastPathComponent) else {
            throw ServiceError("Enter the RunPod endpoint URL without /run, /runsync, /health, /status, or /cancel.")
        }
        return url
    }
    static func authorized(_ url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

struct RunPodProvider: TranscriptionProvider, DiarizationProvider {
    let provider: ServiceProvider
    static let maximumRequestBytes = 10_000_000
    func submit(tracks: [ProviderAudioTrack], language: String, diarize: Bool = false) async throws -> ProviderResult<
        String
    > {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint,
            bodies: tracks.map { $0.trackName + " audio link" } + ["language"], purpose: "Transcription submission"
        ) {

            let request = try submissionRequest(tracks: tracks, language: language, diarize: diarize)
            let result = try await ServiceHTTP.json(
                request,
                trace: .init(
                    provider: provider.name, data: "transcription job (\(tracks.count) audio links, language)"))
            guard let id = result["id"] as? String, !id.isEmpty else {
                throw ServiceError(
                    "RunPod returned no job ID. Check the endpoint's job history before submitting again.")
            }
            return id

        }
    }
    func submissionRequest(tracks: [ProviderAudioTrack], language: String, diarize: Bool) throws -> URLRequest {
        guard provider.kind == .runpod, provider.supports(.transcription) else {
            throw ServiceError("Enable Transcription for this RunPod provider before submitting audio.")
        }
        guard !diarize || provider.supports(.diarization) else {
            throw ServiceError("Enable Speaker Labeling for this provider before requesting them.")
        }
        guard !provider.apiKey.isEmpty else { throw ServiceError("Enter the RunPod API key.") }
        guard !tracks.isEmpty else { throw ServiceError("Add an audio recording before transcribing.") }
        try TranscriptionLanguage.validate(language)
        var names = Set<String>()
        let payload: [[String: Any]] = try tracks.map { track in
            guard !track.trackName.isEmpty, names.insert(track.trackName).inserted else {
                throw ServiceError("Each audio track must have a different name.")
            }
            guard track.url.scheme == "https", track.url.host != nil,
                track.url.user == nil, track.url.password == nil, track.url.fragment == nil
            else {
                throw ServiceError("RunPod requires an HTTPS audio URL that the worker can download.")
            }
            return [
                "audio_url": track.url.absoluteString,
                "track_name": track.trackName, "source_type": track.sourceType,
            ]
        }
        var request = try ServiceHTTP.request(
            ProviderEndpoint.runpod(provider.endpoint).appendingPathComponent("run"),
            json: ["input": ["tracks": payload, "language": language, "diarize": diarize]])
        guard (request.httpBody?.count ?? 0) <= Self.maximumRequestBytes else {
            throw ServiceError("The RunPod request exceeds 10 MB. Reduce the number of audio tracks.")
        }
        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
    func status(jobID: String) async throws -> ProviderResult<ProviderTranscriptionStatus> {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: ["transcript"],
            purpose: "Transcription result"
        ) {

            try Self.parseStatus(await ServiceHTTP.json(jobRequest("status", jobID: jobID), trace: jobTrace))

        }
    }
    func status(jobID: String, expectedTracks: Set<String>) async throws -> ProviderResult<ProviderTranscriptionStatus>
    {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: ["transcript"],
            purpose: "Transcription result"
        ) {

            try Self.parseStatus(
                await ServiceHTTP.json(jobRequest("status", jobID: jobID), trace: jobTrace),
                expectedTracks: expectedTracks)

        }
    }
    @discardableResult func cancel(jobID: String) async throws -> ProviderResult<Void> {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: ["job identifier"],
            purpose: "Cancel transcription"
        ) {

            var request = try jobRequest("cancel", jobID: jobID)
            request.httpMethod = "POST"
            _ = try await ServiceHTTP.json(request, trace: .init(provider: provider.name, data: "job cancellation"))

        }
    }
    private var jobTrace: NetworkTrace { .init(provider: provider.name, data: "job status request") }
    private func jobRequest(_ operation: String, jobID: String) throws -> URLRequest {
        guard !jobID.isEmpty, !jobID.contains("/"), !provider.apiKey.isEmpty else {
            throw ServiceError("The RunPod job ID or API key is missing.")
        }
        return ProviderEndpoint.authorized(
            try ProviderEndpoint.runpod(provider.endpoint)
                .appendingPathComponent(operation).appendingPathComponent(jobID), key: provider.apiKey)
    }
    static func parseStatus(_ result: [String: Any], expectedTracks: Set<String>? = nil) throws
        -> ProviderTranscriptionStatus
    {
        guard let status = result["status"] as? String else { throw ServiceError("RunPod returned no job status.") }
        switch status {
        case "IN_QUEUE", "IN_PROGRESS": return .pending
        case "FAILED", "CANCELLED", "TIMED_OUT":
            return .failed("RunPod transcription \(status.lowercased().replacingOccurrences(of: "_", with: " ")).")
        case "COMPLETED":
            guard let output = result["output"] as? [String: Any],
                let tracks = output["tracks"] as? [String: [String: Any]], !tracks.isEmpty
            else {
                throw ServiceError("RunPod returned no transcript. Check that the endpoint uses the Gday audio worker.")
            }
            if let expectedTracks, Set(tracks.keys) != expectedTracks {
                throw ServiceError(
                    "RunPod returned different audio tracks from those submitted. The transcript was not applied.")
            }
            var segments: [ServerTranscriptSegment] = []
            for (track, body) in tracks {
                guard let entries = body["segments"] as? [[String: Any]] else {
                    throw ServiceError("The transcript is missing an audio track's segments.")
                }
                let embeddings = body["speaker_embeddings"] as? [String: Any] ?? [:]
                let declaredType = body["speaker_embedding_type"]
                let embeddingType = declaredType.flatMap { value -> Data? in
                    guard JSONSerialization.isValidJSONObject(value) else { return nil }
                    return try? JSONSerialization.data(withJSONObject: value)
                }
                .flatMap { try? JSONDecoder().decode(EmbeddingType.self, from: $0) }

                for entry in entries {
                    guard let start = entry["start"] as? Double, let end = entry["end"] as? Double,
                        let text = entry["text"] as? String, start.isFinite, end.isFinite, start >= 0, end >= start
                    else {
                        throw ServiceError("The transcript contains an invalid timestamp or text.")
                    }
                    let label = entry["speaker"] as? String
                    let embedding = label.flatMap { embeddings[$0] as? [Double] }
                    // Invalid optional voice data must not discard usable text.
                    segments.append(
                        .init(
                            start: start, end: end, text: text, speaker: label, track: track,
                            embedding: declaredType == nil
                                ? embedding.flatMap { SpeakerRecognition.isValid($0) ? $0 : nil } : nil,
                            voiceEmbedding: embeddingType.flatMap { type in
                                embedding.flatMap {
                                    TypedVoiceEmbedding.normalizing(
                                        type: type, values: $0,
                                        provenance: body["speaker_embedding_provenance"] as? String)
                                }
                            }))
                }
            }
            return .complete(segments.sorted { $0.start == $1.start ? $0.track < $1.track : $0.start < $1.start })
        default: throw ServiceError("RunPod returned an unsupported job status.")
        }
    }
}

struct OpenAISummaryProvider: SummarizationProvider {
    let provider: ServiceProvider
    func summarize(transcript: String, instructions: String) async throws -> ProviderResult<String> {
        try await complete(messages: [
            .init(role: "system", content: instructions), .init(role: "user", content: transcript),
        ])
    }
    func complete(
        messages: [LLMMessage], bodies: [String] = ["transcript", "instructions"], filePaths: [String] = [],
        purpose: String = "Summary",
        onPartial: (@MainActor (String) -> Void)? = nil
    ) async throws -> ProviderResult<String> {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: bodies,
            filePaths: filePaths, purpose: purpose
        ) {

            guard provider.kind == .openAICompatible, provider.supports(.summarization) else {
                throw ServiceError("Enable Summarization for this provider before sending meeting text.")
            }
            _ = try ProviderEndpoint.base(provider.endpoint)
            guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError("Enter a model name for \(provider.name).")
            }
            if let onPartial {
                return try await LLMService.stream(
                    baseURL: provider.endpoint, apiKey: provider.apiKey, model: provider.model,
                    messages: messages, provider: provider.name, onPartial: onPartial)
            }
            return try await LLMService.complete(
                baseURL: provider.endpoint, apiKey: provider.apiKey, model: provider.model, messages: messages,
                provider: provider.name)

        }
    }
}

@MainActor enum ProviderConnectionChecker {
    static func check(_ provider: ServiceProvider, server suppliedServer: GdayServerService? = nil) async throws
        -> ProviderResult<String>
    {
        guard provider.isEnabled else { throw ServiceError("Turn on Enable This Provider to check its connection.") }
        guard !provider.kind.isLocal else {
            throw ServiceError("Manage local model readiness in Service Providers.")
        }
        if provider.kind == .filedrop { return try await FiledropProvider(provider: provider).checkConnection() }
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: ["connection metadata"],
            purpose: "Connection check"
        ) {

            // Disabled providers are never contacted, even by an explicit check.
            guard provider.isEnabled else {
                throw ServiceError("Turn on Enable This Provider to check its connection.")
            }
            let server = suppliedServer ?? GdayServerService.shared
            let checkTrace = NetworkTrace(provider: provider.name, data: "connection check")
            switch provider.kind {
            case .nemotron, .community1, .localSearch, .appleSpeech:
                throw ServiceError("Manage local model readiness in Service Providers.")
            case .filedrop:
                return try await FiledropProvider(provider: provider).checkConnection().value
            case .runpod:
                guard !provider.apiKey.isEmpty else { throw ServiceError("Enter the RunPod API key.") }
                let url = try ProviderEndpoint.runpod(provider.endpoint).appendingPathComponent("health")
                let response = try await ServiceHTTP.json(
                    ProviderEndpoint.authorized(url, key: provider.apiKey), trace: checkTrace)
                guard response["jobs"] is [String: Any], response["workers"] is [String: Any] else {
                    throw ServiceError("This endpoint did not return RunPod health information.")
                }
                return "Healthy"
            case .openAICompatible:
                let models = try ProviderModelList.parse(
                    await ServiceHTTP.json(ProviderModelList.request(provider), trace: checkTrace))
                guard !provider.model.isEmpty else { throw ServiceError("Enter a model name.") }
                guard models.contains(where: { $0.id == provider.model }) else {
                    throw ServiceError("The model is not in this provider's model list. Check the model name.")
                }
                return "Healthy"
            case .gdayWebsite:
                let origin = try ServiceHTTP.origin(provider.endpoint)
                guard server.connected,
                    server.origin.flatMap(URL.init(string:)).map({ ServiceHTTP.sameOrigin($0, origin) }) == true
                else {
                    throw ServiceError("Sign in to this Gday Meetings website.")
                }
                let response = try await ServiceHTTP.json(
                    server.authorizedRequest("api/platform/capabilities"), trace: checkTrace)
                guard response["durableTasks"] is Bool else {
                    throw ServiceError("This website did not return its capabilities.")
                }
                if provider.enabledCapabilities.contains(.transcription), response["transcription"] as? Bool != true {
                    throw ServiceError("This website has no transcription worker configured.")
                }
                return "Healthy"
            }

        }
    }
}

struct FiledropInfo {
    let allowedExtensions: [String]
    let maxFileBytes: Int
    let expirySeconds: TimeInterval
}
struct FiledropUpload {
    let url: URL
    let expiresAt: Date
}
protocol FileTransferProvider {
    func upload(file: URL) async throws -> ProviderResult<FiledropUpload>
}

struct FiledropProvider: FileTransferProvider {
    let provider: ServiceProvider

    func info() async throws -> ProviderResult<FiledropInfo> {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: ["upload limits"],
            purpose: "Provider information"
        ) {

            let base = try ProviderEndpoint.base(provider.endpoint)
            let result = try await ServiceHTTP.json(
                URLRequest(url: base.appendingPathComponent("info")),
                trace: .init(provider: provider.name, data: "upload limits request"))
            guard let extensions = result["allowed_extensions"] as? [String], !extensions.isEmpty,
                let maximum = result["max_file_size_bytes"] as? Int, maximum > 0,
                let expiry = result["expiry_secs"] as? Double, expiry.isFinite, expiry > 0
            else {
                throw ServiceError("Filedrop returned invalid upload limits.")
            }
            return FiledropInfo(
                allowedExtensions: extensions.map { $0.lowercased() }, maxFileBytes: maximum, expirySeconds: expiry)

        }
    }

    func checkConnection() async throws -> ProviderResult<String> {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: ["connection metadata"],
            purpose: "Connection check"
        ) {

            let base = try ProviderEndpoint.base(provider.endpoint)
            let health = try await ServiceHTTP.json(
                URLRequest(url: base.appendingPathComponent("health")),
                trace: .init(provider: provider.name, data: "connection check"))
            guard let status = health["status"] as? String, ["available", "ok"].contains(status) else {
                throw ServiceError("Filedrop is not accepting uploads. Check its available storage.")
            }
            let information = try await info()
            ProviderDataOperation.metrics?.record(
                sent: information.dataFlow.requestBytes ?? 0, received: information.dataFlow.responseBytes)
            guard !provider.apiKey.isEmpty else { throw ServiceError("Enter the Filedrop API key.") }
            // Authentication precedes filename validation. Omitting a filename checks
            // credentials without creating a file or sending meeting content.
            var request = ProviderEndpoint.authorized(base.appendingPathComponent("upload"), key: provider.apiKey)
            request.httpMethod = "POST"
            request.httpBody = Data()
            let (data, response) = try await ServiceHTTP.data(
                for: request, trace: .init(provider: provider.name, data: "API key check (no file)"))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw ServiceError("Filedrop rejected the API key. Enter a valid key.") }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard code == 400,
                (json?["error"] as? String) == "filename required (?filename=name.opus or Content-Disposition header)"
            else {
                throw ServiceError("Filedrop did not confirm the upload API. Check the endpoint URL.")
            }
            return "Healthy"

        }
    }

    func upload(file: URL) async throws -> ProviderResult<FiledropUpload> {
        return try await ProviderDataOperation.perform(
            targetID: provider.id, target: provider.name, endpoint: provider.endpoint, bodies: [file.lastPathComponent],
            purpose: "Audio upload"
        ) {

            guard provider.kind == .filedrop, provider.supports(.fileTransfer) else {
                throw ServiceError("Enable File Transfer for the selected Filedrop provider.")
            }
            guard !provider.apiKey.isEmpty else { throw ServiceError("Enter the Filedrop API key.") }
            let base = try ProviderEndpoint.base(provider.endpoint)
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw ServiceError("The audio file is empty.") }
            let limits = try await info().value
            guard size <= limits.maxFileBytes else {
                throw ServiceError(
                    "The audio file exceeds Filedrop's upload limit. Increase the server limit or use a smaller recording."
                )
            }
            guard limits.allowedExtensions.contains(file.pathExtension.lowercased()) else {
                throw ServiceError("Filedrop does not accept this audio format. Check its allowed file extensions.")
            }
            var components = URLComponents(url: base.appendingPathComponent("upload"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "filename", value: file.lastPathComponent)]
            var request = ProviderEndpoint.authorized(components.url!, key: provider.apiKey)
            request.httpMethod = "POST"
            request.timeoutInterval = 900
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await ServiceHTTP.upload(
                for: request, fromFile: file, trace: .init(provider: provider.name, data: "recorded audio"))
            let result = try ServiceHTTP.decode(data, response)
            guard let uploadedSize = result["size"] as? Int, uploadedSize == size else {
                throw ServiceError("Filedrop did not confirm the complete audio upload. Try uploading again.")
            }
            guard let text = result["url"] as? String,
                let url = URL(string: text, relativeTo: base.appendingPathComponent(""))?.absoluteURL,
                ServiceHTTP.sameOrigin(url, base), url.user == nil, url.password == nil,
                url.fragment == nil, !url.pathExtension.isEmpty
            else {
                throw ServiceError("Filedrop returned an invalid audio URL.")
            }
            guard let expiry = result["expires_in_secs"] as? Double, expiry.isFinite, expiry > 0 else {
                throw ServiceError("Filedrop returned no valid file expiry.")
            }
            return FiledropUpload(url: url, expiresAt: Date().addingTimeInterval(expiry))

        }
    }
}
