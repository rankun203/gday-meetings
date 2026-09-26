import Foundation

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
    case transcription, diarization, summarization, search, playback, fileTransfer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .transcription: return "Transcription"
        case .diarization: return "Speaker Labels"
        case .summarization: return "Summaries"
        case .search: return "Search"
        case .playback: return "Playback"
        case .fileTransfer: return "File Transfer"
        }
    }
}

enum ServiceProviderKind: String, Codable, CaseIterable, Identifiable {
    case runpod, openAICompatible, gdayWebsite, filedrop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .runpod: return "RunPod"
        case .filedrop: return "Filedrop"
        case .openAICompatible: return "OpenAI-Compatible LLM"
        case .gdayWebsite: return "Gday Meetings Website"
        }
    }
    var capabilities: Set<ProviderCapability> {
        switch self {
        case .runpod: return [.transcription, .diarization]
        case .filedrop: return [.fileTransfer]
        case .openAICompatible: return [.summarization]
        // Search and remote playback have no app adapters. Do not advertise them as available.
        case .gdayWebsite: return [.transcription, .diarization]
        }
    }
}

struct ServiceProvider: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ServiceProviderKind
    var name: String
    var endpoint = ""
    var apiKey = ""
    var model = ""
    var uploadProviderID: UUID?
    var isEnabled = true
    var enabledCapabilities: Set<ProviderCapability> = []
    init(kind: ServiceProviderKind) {
        self.kind = kind
        name = kind.title
    }
    enum CodingKeys: String, CodingKey {
        case id, kind, name, endpoint, model, isEnabled, enabledCapabilities, uploadProviderID
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
    func submit(tracks: [ProviderAudioTrack], language: String, diarize: Bool) async throws -> String
    func status(jobID: String) async throws -> ProviderTranscriptionStatus
    func cancel(jobID: String) async throws
}
/// Speaker labels can be requested in the same audio job as transcription.
protocol DiarizationProvider: TranscriptionProvider {}
protocol SummarizationProvider {
    func summarize(transcript: String, instructions: String) async throws -> String
}
struct ProviderSearchDocument: Codable {
    let meetingID: String
    let revision: String
    let title: String
    let transcript: String
    let summary: String
}
struct ProviderSearchResult: Identifiable {
    let meetingID: String
    let externalID: String
    let title: String
    let excerpt: String
    var id: String { meetingID }
}
protocol SearchProvider {
    func search(query: String) async throws -> [ProviderSearchResult]
}
protocol SearchIndexProvider: SearchProvider {
    func index(_ document: ProviderSearchDocument) async throws
    func remove(meetingID: String) async throws
}
struct ProviderPlaybackResource {
    let meetingID: String
    let duration: TimeInterval
    let request: URLRequest
}
protocol PlaybackProvider {
    func upload(file: URL, meetingID: String) async throws
    func playback(meetingID: String) async throws -> ProviderPlaybackResource
    func remove(meetingID: String) async throws
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
    func submit(tracks: [ProviderAudioTrack], language: String, diarize: Bool = false) async throws -> String {
        let request = try submissionRequest(tracks: tracks, language: language, diarize: diarize)
        let result = try await ServiceHTTP.json(
            request,
            trace: .init(
                provider: provider.name, data: "transcription job (\(tracks.count) audio links, language)"))
        guard let id = result["id"] as? String, !id.isEmpty else {
            throw ServiceError("RunPod returned no job ID. Check the endpoint's job history before submitting again.")
        }
        return id
    }
    func submissionRequest(tracks: [ProviderAudioTrack], language: String, diarize: Bool) throws -> URLRequest {
        guard provider.kind == .runpod, provider.supports(.transcription) else {
            throw ServiceError("Enable Transcription for this RunPod provider before submitting audio.")
        }
        guard !diarize || provider.supports(.diarization) else {
            throw ServiceError("Enable Speaker Labels for this provider before requesting them.")
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
    func status(jobID: String) async throws -> ProviderTranscriptionStatus {
        try Self.parseStatus(await ServiceHTTP.json(jobRequest("status", jobID: jobID), trace: jobTrace))
    }
    func status(jobID: String, expectedTracks: Set<String>) async throws -> ProviderTranscriptionStatus {
        try Self.parseStatus(
            await ServiceHTTP.json(jobRequest("status", jobID: jobID), trace: jobTrace), expectedTracks: expectedTracks)
    }
    func cancel(jobID: String) async throws {
        var request = try jobRequest("cancel", jobID: jobID)
        request.httpMethod = "POST"
        _ = try await ServiceHTTP.json(request, trace: .init(provider: provider.name, data: "job cancellation"))
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
                            embedding: embedding.flatMap { SpeakerRecognition.isValid($0) ? $0 : nil }))
                }
            }
            return .complete(segments.sorted { $0.start == $1.start ? $0.track < $1.track : $0.start < $1.start })
        default: throw ServiceError("RunPod returned an unsupported job status.")
        }
    }
}

struct OpenAISummaryProvider: SummarizationProvider {
    let provider: ServiceProvider
    func summarize(transcript: String, instructions: String) async throws -> String {
        try await complete(messages: [
            .init(role: "system", content: instructions), .init(role: "user", content: transcript),
        ])
    }
    func complete(messages: [LLMMessage]) async throws -> String {
        guard provider.kind == .openAICompatible, provider.supports(.summarization) else {
            throw ServiceError("Enable Summaries for this provider before sending meeting text.")
        }
        _ = try ProviderEndpoint.base(provider.endpoint)
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError("Enter a model name for \(provider.name).")
        }
        return try await LLMService.complete(
            baseURL: provider.endpoint, apiKey: provider.apiKey, model: provider.model, messages: messages,
            provider: provider.name)
    }
}

@MainActor enum ProviderConnectionChecker {
    static func check(_ provider: ServiceProvider, server suppliedServer: GdayServerService? = nil) async throws
        -> String
    {
        // Disabled providers are never contacted, even by an explicit check.
        guard provider.isEnabled else { throw ServiceError("Turn on Enable This Provider to check its connection.") }
        let server = suppliedServer ?? GdayServerService.shared
        let checkTrace = NetworkTrace(provider: provider.name, data: "connection check")
        switch provider.kind {
        case .filedrop:
            return try await FiledropProvider(provider: provider).checkConnection()
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
    func upload(file: URL) async throws -> FiledropUpload
}

struct FiledropProvider: FileTransferProvider {
    let provider: ServiceProvider

    func info() async throws -> FiledropInfo {
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

    func checkConnection() async throws -> String {
        let base = try ProviderEndpoint.base(provider.endpoint)
        let health = try await ServiceHTTP.json(
            URLRequest(url: base.appendingPathComponent("health")),
            trace: .init(provider: provider.name, data: "connection check"))
        guard let status = health["status"] as? String, ["available", "ok"].contains(status) else {
            throw ServiceError("Filedrop is not accepting uploads. Check its available storage.")
        }
        _ = try await info()
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

    func upload(file: URL) async throws -> FiledropUpload {
        guard provider.kind == .filedrop, provider.supports(.fileTransfer) else {
            throw ServiceError("Enable File Transfer for the selected Filedrop provider.")
        }
        guard !provider.apiKey.isEmpty else { throw ServiceError("Enter the Filedrop API key.") }
        let base = try ProviderEndpoint.base(provider.endpoint)
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw ServiceError("The audio file is empty.") }
        let limits = try await info()
        guard size <= limits.maxFileBytes else {
            throw ServiceError(
                "The audio file exceeds Filedrop's upload limit. Increase the server limit or use a smaller recording.")
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
