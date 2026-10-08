import Combine
import Foundation
import Speech

enum ProviderHealth: Equatable, Sendable {
    case checking, ready
    case notReady(String)
    case unknown(String)
    var isReady: Bool { self == .ready }
    var title: String {
        switch self {
        case .checking: "Checking…"
        case .ready: "Ready"
        case .notReady: "Not Ready"
        case .unknown: "Couldn’t Check"
        }
    }
    var reason: String? {
        switch self {
        case .notReady(let reason), .unknown(let reason): reason
        default: nil
        }
    }
}

extension ServiceProvider {
    /// A readiness estimate; never opens a model or starts billable work.
    @MainActor func health(for capability: ProviderCapability, settings: AppSettings, models: LocalModelManager? = nil)
        async -> ProviderHealth
    {
        guard kind.capabilities.contains(capability) else { return .notReady("Capability unavailable.") }
        guard isEnabled else { return .notReady("Provider is turned off.") }
        guard enabledCapabilities.contains(capability) else { return .notReady("Capability is turned off.") }
        if kind == .localSearch {
            return await (models ?? .shared).health(for: (localSearch ?? .init()).selectedModel.localID)
        }
        if kind.isLocalSpeaker {
            for id in localModelIDs(for: capability) {
                let result = await (models ?? .shared).health(for: id)
                if !result.isReady {
                    return .notReady("\(LocalModelRegistry.descriptor(id).title): \(result.reason ?? result.title)")
                }
            }
            return .ready
        }
        do {
            // Check the requested capability independently of other enabled capabilities.
            var scoped = self
            scoped.enabledCapabilities = [capability]
            _ = try await ProviderConnectionChecker.check(scoped)
            if kind == .runpod {
                guard let upload = settings.serviceProviders.first(where: { $0.id == uploadProviderID }),
                    upload.kind == .filedrop, upload.supports(.fileTransfer)
                else { return .notReady("Choose an audio upload provider.") }
                let result = await ProviderHealthStore.shared.checkDependency(
                    providerID: upload.id, capability: .fileTransfer, settings: settings)
                guard result.isReady else {
                    return .notReady("Audio upload provider: \(result.reason ?? result.title)")
                }
            }
            return .ready
        }
        catch is CancellationError { return .unknown("Check cancelled.") }
        catch let error as URLError { return .unknown(error.localizedDescription) }
        catch { return .notReady(error.localizedDescription) }
    }
}

extension ThisMacProvider {
    @MainActor static func health(for capability: ProviderCapability, settings: AppSettings) async -> ProviderHealth {
        guard ThisMacProvider.capabilities.contains(capability) else { return .notReady("Capability unavailable.") }
        guard settings.thisMacCapabilities.contains(capability) else { return .notReady("Capability is turned off.") }
        guard SpeechTranscriber.isAvailable else { return .notReady("Transcription is unavailable on this Mac.") }
        let locales = await SpeechTranscriber.supportedLocales
        guard let locale = AppleSpeechLanguageMapping.locale(for: settings.defaultLanguage, supported: locales) else {
            return .notReady("Choose a supported transcription language.")
        }
        let status = await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)]
        )
        switch status {
        case .installed: return .ready
        case .downloading: return .notReady("Speech model is downloading.")
        case .supported: return .notReady("Download the speech model in provider settings.")
        default: return .notReady("Speech model is unavailable.")
        }
    }
}

@MainActor final class ProviderHealthStore: ObservableObject {
    static let shared = ProviderHealthStore()
    struct Key: Hashable {
        let providerID: UUID
        let capability: ProviderCapability
    }
    @Published private(set) var results: [Key: ProviderHealth] = [:]
    @Published private(set) var validationResults: [Key: ProviderHealth] = [:]
    private var providerValidations: [UUID: Task<[ProviderCapability: ProviderHealth], Never>] = [:]
    private var validationRequests: [UUID: UUID] = [:]
    func validationState(providerID: UUID, capability: ProviderCapability) -> ProviderHealth {
        let key = Key(providerID: providerID, capability: capability)
        return seeded.contains(key) ? (results[key] ?? .checking) : (validationResults[key] ?? .checking)
    }
    @Published var settingsProviderID: UUID?
    private var seeded: Set<Key> = []
    func seed(providerID: UUID, capability: ProviderCapability, health: ProviderHealth) {
        let key = Key(providerID: providerID, capability: capability)
        seeded.insert(key)
        results[key] = health
    }
    struct Configuration: Equatable {
        let providers: [ServiceProvider]
        let language: String
        let localCapabilities: Set<ProviderCapability>
        init(_ settings: AppSettings) {
            providers = settings.serviceProviders
            language = settings.defaultLanguage
            localCapabilities = settings.thisMacCapabilities
        }
    }
    typealias Checker = @MainActor (UUID, ProviderCapability, AppSettings) async -> ProviderHealth
    private let checker: Checker?
    init(checker: Checker? = nil) { self.checker = checker }
    private var configuration: Configuration?
    private var fingerprints: [Key: Configuration] = [:]
    func invalidateChangedConfiguration(settings: AppSettings) {
        let next = Configuration(settings)
        guard configuration != next else { return }
        configuration = next
        requests.removeAll()
        for task in inFlight.values { task.cancel() }
        for task in providerValidations.values { task.cancel() }
        providerValidations.removeAll()
        validationRequests.removeAll()
        validationResults.removeAll()
        inFlight.removeAll()
        fingerprints.removeAll()
        results = results.filter { seeded.contains($0.key) }
    }
    private var requests: [Key: UUID] = [:]
    private var inFlight: [Key: Task<ProviderHealth, Never>] = [:]

    func state(providerID: UUID, capability: ProviderCapability) -> ProviderHealth {
        results[Key(providerID: providerID, capability: capability)] ?? .checking
    }

    @discardableResult func check(
        providerID: UUID, capability: ProviderCapability, settings: AppSettings, force: Bool = false
    ) async -> ProviderHealth {
        let key = Key(providerID: providerID, capability: capability)
        if seeded.contains(key), let result = results[key] { return result }
        let provider = settings.serviceProviders.first { $0.id == providerID }
        invalidateChangedConfiguration(settings: settings)
        let fingerprint = Configuration(settings)
        if !force, fingerprints[key] == fingerprint, let result = results[key], result != .checking { return result }
        if fingerprints[key] == fingerprint, let task = inFlight[key] { return await task.value }
        let request = UUID()
        requests[key] = request
        fingerprints[key] = fingerprint
        results[key] = .checking
        let task = Task { @MainActor in
            if let checker = self.checker { return await checker(providerID, capability, settings) }
            if providerID == ThisMacProvider.id {
                return await ThisMacProvider.health(for: capability, settings: settings)
            }
            if let provider { return await provider.health(for: capability, settings: settings) }
            return ProviderHealth.notReady("Provider is unavailable.")
        }
        inFlight[key] = task
        let result = await task.value
        guard requests[key] == request else { return result }
        inFlight[key] = nil
        results[key] = result
        return result
    }

    /// A suspended provider check cannot restore an earlier configuration when
    /// it proceeds to check an upload dependency after settings have changed.
    func checkDependency(
        providerID: UUID, capability: ProviderCapability, settings: AppSettings
    ) async -> ProviderHealth {
        guard configuration == Configuration(settings) else {
            return .unknown("Provider settings changed. Check again.")
        }
        return await check(providerID: providerID, capability: capability, settings: settings, force: true)
    }

    func checkEligible(capability: ProviderCapability, settings: AppSettings) async {
        var ids = settings.serviceProviders.filter { $0.kind.capabilities.contains(capability) }.map(\.id)
        if ThisMacProvider.capabilities.contains(capability) { ids.insert(ThisMacProvider.id, at: 0) }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    _ = await self.check(providerID: id, capability: capability, settings: settings, force: true)
                }
            }
        }
    }

    func checkSelected(settings: AppSettings) async {
        let pairs: [(ProviderCapability, UUID?)] = [
            (.liveTranscription, settings.liveTranscriptionProviderID),
            (.transcription, settings.transcriptionProviderID),
            (.diarization, settings.diarizationProviderID),
            (.summarization, settings.summaryProviderID),
        ]
        await withTaskGroup(of: Void.self) { group in
            for (capability, id) in pairs {
                guard let id else { continue }
                group.addTask {
                    _ = await self.check(providerID: id, capability: capability, settings: settings, force: true)
                }
            }
        }
    }

    func checkProvider(providerID: UUID, settings: AppSettings) async -> [ProviderCapability: ProviderHealth] {
        invalidateChangedConfiguration(settings: settings)
        if let task = providerValidations[providerID] { return await task.value }
        let capabilities =
            providerID == ThisMacProvider.id
            ? ThisMacProvider.capabilities
            : settings.serviceProviders.first(where: { $0.id == providerID })?.kind.capabilities ?? []
        let request = UUID()
        validationRequests[providerID] = request
        var checking = validationResults
        for capability in capabilities { checking[.init(providerID: providerID, capability: capability)] = .checking }
        validationResults = checking
        let provider = settings.serviceProviders.first { $0.id == providerID }
        let task = Task { @MainActor in
            var completed: [ProviderCapability: ProviderHealth] = [:]
            for capability in capabilities {
                guard !Task.isCancelled else { return completed }
                let key = Key(providerID: providerID, capability: capability)
                if seeded.contains(key), let value = results[key] {
                    completed[capability] = value
                    continue
                }
                if let checker {
                    completed[capability] = await checker(providerID, capability, settings)
                }
                else if providerID == ThisMacProvider.id {
                    completed[capability] = await ThisMacProvider.health(for: capability, settings: settings)
                }
                else if let provider {
                    let estimate = await provider.health(for: capability, settings: settings)
                    if estimate.isReady {
                        completed[capability] = .ready
                        for id in provider.localModelIDs(for: capability) {
                            let result = await LocalModelManager.shared.validate(id)
                            if !result.isReady {
                                completed[capability] = result
                                break
                            }
                        }
                    }
                    else {
                        completed[capability] = estimate
                    }
                }
                else {
                    completed[capability] = .notReady("Provider is unavailable.")
                }
            }
            return completed
        }
        providerValidations[providerID] = task
        let completed = await task.value
        guard validationRequests[providerID] == request else { return completed }
        providerValidations[providerID] = nil
        var published = validationResults
        for (capability, value) in completed {
            published[.init(providerID: providerID, capability: capability)] = value
        }
        validationResults = published
        return completed
    }

}

extension MeetingStore {
    /// Model changes affect selected local capabilities and capabilities that have
    /// never had a selection. Explicit None and unrelated remote providers stay untouched.
    @MainActor func refreshLocalProviderHealth(health suppliedHealth: ProviderHealthStore? = nil) async {
        let health = suppliedHealth ?? .shared
        let snapshot = settings
        let configuration = ProviderHealthStore.Configuration(snapshot)
        for capability in ProviderCapability.allCases {
            let selected = settings.selectedProvider(for: capability)
            let candidates: [ServiceProvider]
            if let selected {
                candidates = snapshot.serviceProviders.filter { $0.id == selected && $0.kind.isLocal }
            }
            else if !settings.initializedProviderCapabilities.contains(capability) {
                candidates = snapshot.serviceProviders.filter { $0.kind.isLocal && $0.supports(capability) }
            }
            else {
                continue
            }
            for provider in candidates where provider.kind.capabilities.contains(capability) {
                let result = await health.check(
                    providerID: provider.id, capability: capability, settings: snapshot, force: true)
                guard ProviderHealthStore.Configuration(settings) == configuration else { return }
                if result.isReady {
                    if settings.assignInitiallyHealthyProvider(provider.id, capabilities: [capability]) {
                        saveSettings()
                    }
                    break
                }
            }
        }
    }

    @MainActor func refreshProviderHealth(providerID: UUID) async {
        let snapshot = settings
        let results = await ProviderHealthStore.shared.checkProvider(providerID: providerID, settings: snapshot)
        guard settings.serviceProviders == snapshot.serviceProviders,
            settings.thisMacCapabilities == snapshot.thisMacCapabilities,
            settings.defaultLanguage == snapshot.defaultLanguage
        else { return }
        let ready = Set(results.filter { $0.value.isReady }.map(\.key))
        if settings.assignInitiallyHealthyProvider(providerID, capabilities: ready) { saveSettings() }
    }
}

extension ServiceProvider {
    func localModelIDs(for capability: ProviderCapability) -> [LocalModelID] {
        if kind == .localSearch, capability == .search { return [(localSearch ?? .init()).selectedModel.localID] }
        guard kind.isLocalSpeaker else { return [] }
        if capability == .diarization { return [.community1] }
        return []
    }
}
