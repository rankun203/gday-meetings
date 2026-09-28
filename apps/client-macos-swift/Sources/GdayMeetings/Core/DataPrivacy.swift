import Foundation

/// Data types the app manages, in Settings → Data Privacy order.
enum PrivacyDataType: String, CaseIterable, Identifiable {
    case audio, meetingDetails, notes, transcripts, summaries, todos, chat, peopleAndTags, voiceSamples,
        credentials, settings, logs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: "Recorded Audio"
        case .meetingDetails: "Meeting Details"
        case .notes: "Notes"
        case .transcripts: "Transcripts"
        case .summaries: "Summaries"
        case .todos: "To-Dos"
        case .chat: "Chat Messages"
        case .peopleAndTags: "People and Tags"
        case .voiceSamples: "Voice Recognition Data"
        case .credentials: "Credentials"
        case .settings: "Settings"
        case .logs: "Logs"
        }
    }
    /// Clarifies types whose title alone does not say what they contain.
    var contents: String? {
        switch self {
        case .audio: "Microphone and system audio tracks. Live transcription audio is processed on this Mac."
        case .meetingDetails: "Title, date, duration, language, and recording devices"
        case .notes:
            "Notes text and referenced images. Summary providers receive images when Image Input supports them; chat sends text only."
        case .peopleAndTags: "Names, email addresses, notes, and speaker assignments"
        case .voiceSamples:
            "Voice patterns from transcription results and speaker assignments. Recognition runs on this Mac."
        case .credentials: "Provider API keys and website sign-in, stored in Keychain"
        default: nil
        }
    }
    var systemImage: String {
        switch self {
        case .audio: "waveform"
        case .meetingDetails: "calendar"
        case .notes: "note.text"
        case .transcripts: "text.quote"
        case .summaries: "sparkles"
        case .todos: "checklist"
        case .chat: "bubble.left.and.bubble.right"
        case .peopleAndTags: "person.2"
        case .voiceSamples: "waveform.badge.person.crop"
        case .credentials: "key"
        case .settings: "gearshape"
        case .logs: "doc.text"
        }
    }
}

/// What sends data. Cases are in sentence order: automatic first, then actions.
enum PrivacyTrigger: Int, Comparable {
    case afterRecording, afterTranscription, transcribe, summarizeOrChat, archive
    /// Opening an enabled provider's panel checks it and lists its models; saving and
    /// Check Connection happen in that panel.
    case openProvider
    /// A disabled provider is contacted only to list models while its endpoint or key is edited.
    case editProvider
    /// Load Languages, which only website providers offer. RunPod's list is built in.
    case loadLanguages
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    /// Completes "when you …". Automatic triggers are not user actions.
    fileprivate var action: String? {
        switch self {
        case .transcribe: "transcribe a meeting"
        case .summarizeOrChat: "generate a summary or send a chat message"
        case .archive: "choose Archive to Server"
        case .openProvider: "open the provider in Settings"
        case .editProvider: "edit the provider in Settings"
        case .loadLanguages: "choose Load Languages"
        case .afterRecording, .afterTranscription: nil
        }
    }
}

/// A path data can take off this Mac. Capabilities add routes declaratively; a
/// capability that processes data on this Mac (for example, on-device
/// Live Transcription) adds a route with no receivers, so it does not send data to a provider.
struct PrivacyRoute {
    let data: Set<PrivacyDataType>
    let trigger: PrivacyTrigger
    let receivers: [ServiceProvider]
}

struct PrivacyDestination: Identifiable, Equatable {
    let id: UUID
    let provider: String
    let host: String
    let triggers: [PrivacyTrigger]
    /// Credentials accompany requests rather than being the content sent.
    var authenticates = false
    var text: String {
        "Sent to \(provider) (\(host)) \(authenticates ? "to authenticate " : "")\(Self.phrase(triggers))"
    }

    static func phrase(_ triggers: [PrivacyTrigger]) -> String {
        var parts: [String] = []
        if triggers.contains(.afterRecording) { parts.append("after recording when automatic transcription applies") }
        if triggers.contains(.afterTranscription) {
            parts.append("after a transcript is saved when Automatically Summarize is on")
        }
        let actions = triggers.compactMap(\.action)
        if !actions.isEmpty { parts.append("when you " + join(actions)) }
        return parts.joined(separator: " and ")
    }
    private static func join(_ items: [String]) -> String {
        // A comma keeps an action that contains "or" readable as one item.
        guard items.count > 2 || items.dropLast().contains(where: { $0.contains(" or ") }) else {
            return items.joined(separator: " or ")
        }
        return items.dropLast().joined(separator: ", ") + ", or " + items.last!
    }
}

struct PrivacyRow: Identifiable, Equatable {
    let type: PrivacyDataType
    let destinations: [PrivacyDestination]
    let note: String?
    var id: PrivacyDataType { type }
    var sendsToProvider: Bool { !destinations.isEmpty }
    var storageStatus: String {
        switch type {
        case .credentials: "Stored in Keychain on This Mac"
        case .logs: "Saved on This Mac"
        default: "Saved in Data Folder"
        }
    }
    var storageSymbol: String {
        switch type {
        case .credentials: "key"
        case .logs: "laptopcomputer"
        default: "folder"
        }
    }
}

/// Inputs that decide where data can go. Keep this free of services so the
/// panel can be derived and tested without Keychain or network access.
struct PrivacyContext {
    struct PendingTranscription: Equatable {
        let providerID: UUID
        let uploadProviderID: UUID?
    }
    var settings: AppSettings
    /// The origin of the signed-in Gday Meetings website, if any. Website requests need it.
    var signedInWebsiteOrigin: String?
    /// Unsent transcription attempts resume with their original providers.
    var pendingTranscriptions: [PendingTranscription] = []

    /// Attempts that will upload audio when resumed. Submitted jobs only poll for status.
    static func pending(in meetings: [Meeting]) -> [PendingTranscription] {
        meetings.compactMap(\.transcriptionAttempt)
            .filter { $0.taskID == nil && $0.result == nil && $0.failure == nil && !$0.submissionUncertain }
            .map { PendingTranscription(providerID: $0.providerID, uploadProviderID: $0.uploadProviderID) }
    }
}

/// Derives Settings → Data Privacy from provider settings. Each rule mirrors the
/// guard that allows the matching request: MeetingIntelligence (summaries, chat),
/// ProviderTranscription (transcription), ServerArchive (archive),
/// ServiceProvidersView and ProviderModelListPolicy (checks and model
/// lists), and ProviderLanguageSelection (explicit language discovery).
enum DataPrivacy {
    static func routes(_ context: PrivacyContext) -> [PrivacyRoute] {
        let settings = context.settings
        let providers = settings.serviceProviders
        func provider(_ id: UUID?) -> ServiceProvider? { providers.first { $0.id == id } }
        func signedIn(_ website: ServiceProvider) -> Bool {
            guard let origin = context.signedInWebsiteOrigin else { return false }
            return (try? ServiceHTTP.origin(website.endpoint).absoluteString) == origin
        }
        var routes: [PrivacyRoute] = []

        // Manual transcription can choose any configured provider. Only the
        // default provider can run automatically; pending attempts retain theirs.
        var transcriptions: [(UUID?, UUID?, Bool)] = providers.map {
            ($0.id, nil, settings.autoTranscribe && $0.id == settings.transcriptionProviderID)
        }
        transcriptions += context.pendingTranscriptions.map { ($0.providerID, $0.uploadProviderID, false) }
        for (id, uploadID, automatic) in transcriptions {
            guard let transcriber = provider(id), transcriber.supports(.transcription) else { continue }
            let triggers: [PrivacyTrigger] = automatic ? [.afterRecording, .transcribe] : [.transcribe]
            switch transcriber.kind {
            case .runpod:
                // RunPod downloads the audio from Filedrop through a temporary link.
                guard (try? ProviderEndpoint.runpod(transcriber.endpoint)) != nil, hasText(transcriber.apiKey),
                    let upload = provider(uploadID ?? transcriber.uploadProviderID), upload.kind == .filedrop,
                    upload.supports(.fileTransfer), hasText(upload.apiKey),
                    (try? ProviderEndpoint.base(upload.endpoint)) != nil
                else { continue }
                for trigger in triggers {
                    routes.append(.init(data: [.audio], trigger: trigger, receivers: [upload, transcriber]))
                    // RunPod receives the meeting language, not its title.
                    routes.append(.init(data: [.meetingDetails], trigger: trigger, receivers: [transcriber]))
                }
            case .gdayWebsite:
                guard signedIn(transcriber) else { continue }
                for trigger in triggers {
                    routes.append(.init(data: [.audio, .meetingDetails], trigger: trigger, receivers: [transcriber]))
                }
            case .openAICompatible, .filedrop:
                continue
            }
        }

        // Summaries and chat send meeting context and Summary Prompt; to-dos are not included.
        if let summarizer = provider(settings.summaryProviderID), summarizer.kind == .openAICompatible,
            summarizer.supports(.summarization), hasText(summarizer.model),
            (try? ProviderEndpoint.base(summarizer.endpoint)) != nil
        {
            routes.append(
                .init(
                    data: [.meetingDetails, .notes, .transcripts, .summaries, .chat, .peopleAndTags, .settings],
                    trigger: .summarizeOrChat, receivers: [summarizer]))
            if settings.autoSummarize {
                routes.append(
                    .init(
                        data: [.meetingDetails, .notes, .transcripts, .peopleAndTags, .settings],
                        trigger: .afterTranscription, receivers: [summarizer]))
            }
        }

        for website in providers where website.kind == .gdayWebsite && signedIn(website) {
            // Archive to Server needs only an enabled, signed-in website; no capability gates it.
            if website.isEnabled {
                routes.append(
                    .init(
                        data: [
                            .audio, .meetingDetails, .notes, .transcripts, .summaries, .todos, .chat, .peopleAndTags,
                        ],
                        trigger: .archive, receivers: [website]))
            }
        }

        // Credentials go with every request above, and with free checks and model lists
        // when an enabled provider's panel opens. Disabled providers are contacted only
        // to list models while their endpoint or key is edited.
        var credentialRoutes: [PrivacyRoute] = []
        for provider in providers {
            guard (try? ProviderEndpoint.base(provider.endpoint)) != nil,
                provider.kind == .gdayWebsite ? signedIn(provider) : hasText(provider.apiKey)
            else { continue }
            var triggers = Set(routes.filter { $0.receivers.contains { $0.id == provider.id } }.map(\.trigger))
            if provider.isEnabled {
                triggers.insert(.openProvider)
                if provider.supports(.transcription), ProviderLanguageService.builtInCatalog(for: provider) == nil {
                    triggers.insert(.loadLanguages)
                }
            }
            else if provider.kind == .openAICompatible {
                triggers.insert(.editProvider)
            }
            credentialRoutes += triggers.sorted().map {
                .init(data: [.credentials], trigger: $0, receivers: [provider])
            }
        }
        return routes + credentialRoutes
    }

    static func rows(_ context: PrivacyContext) -> [PrivacyRow] {
        let routes = routes(context)
        return PrivacyDataType.allCases.map { type in
            var order: [UUID] = []
            var receivers: [UUID: (provider: ServiceProvider, triggers: Set<PrivacyTrigger>)] = [:]
            for route in routes where route.data.contains(type) {
                for receiver in route.receivers {
                    if receivers[receiver.id] == nil {
                        order.append(receiver.id)
                        receivers[receiver.id] = (receiver, [])
                    }
                    receivers[receiver.id]?.triggers.insert(route.trigger)
                }
            }
            let destinations = order.compactMap { id -> PrivacyDestination? in
                guard let entry = receivers[id] else { return nil }
                return PrivacyDestination(
                    id: id, provider: entry.provider.name, host: host(entry.provider.endpoint),
                    triggers: entry.triggers.sorted(), authenticates: type == .credentials)
            }
            return PrivacyRow(type: type, destinations: destinations, note: note(type, destinations, context))
        }
    }

    private static func note(_ type: PrivacyDataType, _ destinations: [PrivacyDestination], _ context: PrivacyContext)
        -> String?
    {
        let kinds = Set(
            destinations.compactMap { destination in
                context.settings.serviceProviders.first { $0.id == destination.id }?.kind
            })
        switch type {
        case .audio where kinds.contains(.filedrop):
            return "Anyone with the Filedrop link can download the audio until the link expires."
        case .meetingDetails where kinds.contains(.runpod):
            return "RunPod receives only the meeting language."
        case .settings where !destinations.isEmpty:
            return "Only the Summary Prompt is sent."
        default:
            return nil
        }
    }

    /// Host and nondefault port, without path, query, or credentials.
    static func host(_ endpoint: String) -> String {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host
        else { return "no address" }
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
