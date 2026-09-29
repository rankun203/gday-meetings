import AppKit
import SwiftUI

struct ServiceProvidersView: View {
    @EnvironmentObject private var store: MeetingStore
    @ViewState private var selection: UUID?
    @ViewState private var confirmsRemoval = false
    @ViewState private var saveError: String?
    @ViewState private var isRemoving = false
    @ViewState private var signInTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("This Mac", systemImage: "desktopcomputer")
                        Text("Live Transcription").font(.caption).foregroundStyle(.secondary)
                    }.tag(ThisMacProvider.id).padding(.vertical, 4)
                    ForEach(store.settings.serviceProviders) { provider in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(provider.name, systemImage: provider.kind == .gdayWebsite ? "globe" : "server.rack")
                            Text(provider.isEnabled ? provider.kind.title : "Disabled")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(provider.id)
                        .padding(.vertical, 4)
                    }
                }
                Divider()
                HStack {
                    Menu {
                        ForEach(ServiceProviderKind.allCases, id: \.self) { kind in
                            Button(kind.title) { add(kind) }
                                .disabled(
                                    kind == .gdayWebsite
                                        && store.settings.serviceProviders.contains { $0.kind == .gdayWebsite })
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Add Provider").help("Add Provider")
                    Button {
                        confirmsRemoval = true
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless).disabled(selection == nil || selection == ThisMacProvider.id)
                    .accessibilityLabel("Remove Provider").help("Remove Provider")
                    Spacer()
                }.padding(12)
            }.frame(width: 205)
            Divider()
            if selection == ThisMacProvider.id {
                ThisMacProviderView()
            }
            else if let provider = store.settings.serviceProviders.first(where: { $0.id == selection }) {
                ServiceProviderPanel(provider: provider, addProvider: add, signInTask: $signInTask).id(provider.id)
            }
            else {
                ContentUnavailableView {
                    Label("Service Providers", systemImage: "server.rack")
                } description: {
                    Text("Add a provider to transcribe recordings or create summaries.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(isRemoving)
        .overlay(alignment: .bottom) {
            if isRemoving {
                ProgressView("Removing Provider…").padding()
            }
        }
        .onAppear { if selection == nil { selection = ThisMacProvider.id } }
        .alert(
            "Couldn’t Update Providers",
            isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .confirmationDialog("Remove Provider?", isPresented: $confirmsRemoval) {
            Button("Remove Provider", role: .destructive) { removeSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes the connection and saved credentials from this Mac. Meetings and files stored by the provider are kept."
            )
        }
    }

    private func add(_ kind: ServiceProviderKind) {
        let provider = ServiceProvider(kind: kind)
        let previous = store.settings
        store.settings.serviceProviders.append(provider)
        guard store.saveSettings() else {
            store.settings = previous
            saveError = store.errorMessage
            return
        }
        selection = provider.id
    }

    private func removeSelected() {
        guard !isRemoving, let selection,
            let provider = store.settings.serviceProviders.first(where: { $0.id == selection })
        else { return }
        isRemoving = true
        signInTask?.cancel()
        Task {
            defer { isRemoving = false }
            if provider.kind == .gdayWebsite {
                do { try await GdayServerService.shared.signOut() }
                catch {
                    saveError = error.localizedDescription
                    return
                }
            }
            let previous = store.settings
            store.settings.serviceProviders.removeAll { $0.id == selection }
            if store.settings.transcriptionProviderID == selection { store.settings.transcriptionProviderID = nil }
            if store.settings.summaryProviderID == selection { store.settings.summaryProviderID = nil }
            guard store.saveSettings() else {
                store.settings = previous
                saveError = store.errorMessage
                return
            }
            self.selection = store.settings.serviceProviders.first?.id
        }
    }
}

private struct ServiceProviderPanel: View {
    let addProvider: (ServiceProviderKind) -> Void
    @Binding var signInTask: Task<Void, Never>?
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject private var server = GdayServerService.shared
    @ViewState private var draft: ServiceProvider
    @ViewState private var status = "Not Checked"
    @ViewState private var statusIcon = "circle.dashed"
    @ViewState private var statusColor: Color = .secondary
    @ViewState private var isChecking = false
    @ViewState private var signingIn = false
    @ViewState private var checkID = UUID()
    @ViewState private var checkTask: Task<Void, Never>?
    @ViewState private var saveError: String?
    @ViewState private var uploadStatus = "Not Checked"
    @ViewState private var showsConnectionInfo = false
    @ViewState private var uploadStatusIcon = "circle.dashed"
    @ViewState private var uploadStatusColor: Color = .secondary
    @ViewState private var models: [ProviderModel] = []
    @ViewState private var modelListState = ModelListState.idle

    init(
        provider: ServiceProvider, addProvider: @escaping (ServiceProviderKind) -> Void,
        signInTask: Binding<Task<Void, Never>?>
    ) {
        _draft = ViewState(initialValue: provider)
        self.addProvider = addProvider
        _signInTask = signInTask
    }

    private var saved: ServiceProvider? { store.settings.serviceProviders.first { $0.id == draft.id } }
    private var hasChanges: Bool { saved != draft }

    var body: some View {
        Form {
            Section {
                Text(draft.kind.title).font(.title2.weight(.semibold))
                TextField("Name", text: $draft.name)
                Toggle("Enable This Provider", isOn: $draft.isEnabled)
            }
            Section("Connection") {
                TextField(draft.kind == .gdayWebsite ? "Website URL" : "Endpoint URL", text: $draft.endpoint)
                    .textContentType(.URL)
                    .help(endpointHelp)
                if draft.kind != .gdayWebsite {
                    SecureField("API Key", text: $draft.apiKey)
                        .help("Create an API key in the provider’s account settings.")
                    if draft.kind == .openAICompatible {
                        LabeledContent("Model") {
                            ModelComboBox(text: $draft.model, models: models)
                        }
                        modelStatus
                        Picker("Image Input", selection: imageInputBinding) {
                            Text("Automatic").tag(0)
                            Text("Supports Images").tag(1)
                            Text("Text Only").tag(2)
                        }
                        Text(imageInputDescription).font(.caption).foregroundStyle(.secondary)
                    }
                }
                else {
                    if server.connected {
                        LabeledContent("Account", value: server.email ?? "Signed In")
                        Button("Sign Out") {
                            Task {
                                do {
                                    try await server.signOut()
                                    startCheck()
                                }
                                catch { showError(error) }
                            }
                        }
                    }
                    Button(signingIn ? "Signing In…" : "Sign In with Browser…") { signIn() }
                        .disabled(signingIn || draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(alignment: .top) {
                    if isChecking { ProgressView().controlSize(.small).accessibilityLabel("Checking Connection") }
                    Label(
                        hasChanges ? "Save to check changes." : status,
                        systemImage: hasChanges ? "pencil.circle" : statusIcon
                    )
                    .foregroundStyle(hasChanges ? .secondary : statusColor)
                    .font(.callout)
                    .textSelection(.enabled)
                    Spacer()
                    Button {
                        showsConnectionInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("About Connection Checks")
                    .help("About connection checks")
                    .popover(isPresented: $showsConnectionInfo) {
                        Text(
                            "Enabled providers are checked when this panel opens, when you save, and when you choose Check Connection. Checks send credentials, not recordings or meeting text."
                        )
                        .font(.callout)
                        .padding()
                        .frame(width: 280)
                    }
                }
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if draft.kind == .runpod {
                Section("Audio Uploads") {
                    Picker("Upload Provider", selection: $draft.uploadProviderID) {
                        Text("None").tag(nil as UUID?)
                        ForEach(store.settings.serviceProviders.filter { $0.kind == .filedrop }) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }
                    Label(
                        hasChanges ? "Save to check the upload provider." : uploadStatus,
                        systemImage: hasChanges ? "pencil.circle" : uploadStatusIcon
                    )
                    .foregroundStyle(hasChanges ? .secondary : uploadStatusColor)
                    Text(
                        "Audio is uploaded to the selected Filedrop provider for RunPod to download. RunPod charges apply."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Button("Add Filedrop Provider…") { addProvider(.filedrop) }
                        .disabled(hasChanges)
                }
            }
            if draft.kind == .openAICompatible {
                Section("Summary Prompt") {
                    TextEditor(text: $draft.summaryPrompt)
                        .font(.body)
                        .frame(height: 180)
                        .accessibilityLabel("Summary Prompt")
                    Text(
                        "Used when generating summaries with this provider. Language and current time are added for each meeting."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Button("Restore Default") { draft.summaryPrompt = SummaryPrompt.defaultInstructions }
                        .disabled(draft.summaryPrompt == SummaryPrompt.defaultInstructions)
                }
            }
            Section("Capabilities") {
                ForEach(ProviderCapability.allCases.filter { draft.kind.capabilities.contains($0) }, id: \.self) {
                    capability in
                    Toggle(capability.title, isOn: capabilityBinding(capability))
                    Text(disclosure(capability)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if draft.kind.capabilities.contains(.transcription) {
                languagesSection
            }
            Section {
                HStack {
                    Button("Save") { saveAndCheck() }
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || signingIn)
                    Button("Check Connection") { startCheck() }
                        .disabled(hasChanges || isChecking || signingIn || saved?.isEnabled != true)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        // Checks send only credentials and start no billable work, so they may run
        // when the panel opens. startCheck never contacts a disabled provider.
        .task { startCheck() }
        .background(ProviderPanelWindowObserver { if !signingIn { startCheck() } })
        .task(id: modelListKey) { await refreshModels() }
        .onDisappear {
            checkID = UUID()
            checkTask?.cancel()
            signInTask?.cancel()
        }
    }

    private var imageInputBinding: Binding<Int> {
        Binding(
            get: {
                guard let value = draft.summaryImageOverride, value.matches(draft) else { return 0 }
                return value.supported ? 1 : 2
            },
            set: { value in
                draft.summaryImageOverride =
                    value == 0 ? nil : .init(endpoint: draft.endpoint, model: draft.model, supported: value == 1)
            })
    }
    private var imageInputDescription: String {
        switch SummaryImageSupport.resolve(draft, models: models) {
        case true:
            "Summaries include images from Notes, resized to at most 2,400 pixels. Up to 20 images, totaling 20 MB before encoding, are sent to this provider."
        case false:
            "Summaries include Notes text only. Images aren’t sent to this model."
        case nil:
            "Image support is unknown. For notes with images, choose Supports Images if the model accepts them, or Text Only to omit them."
        }
    }

    private enum ModelListState: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    /// Changes to these fields restart the model list task.
    private var modelListKey: String? {
        draft.kind == .openAICompatible
            ? [draft.endpoint, draft.apiKey, String(draft.isEnabled)].joined(separator: "\n") : nil
    }

    @ViewBuilder private var modelStatus: some View {
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch modelListState {
        case .loading:
            Text("Loading Models…").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(
                "Couldn’t load the model list. \(message) Type a model name instead.",
                systemImage: "exclamationmark.circle"
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .idle, .loaded:
            if !model.isEmpty, !models.isEmpty, !models.contains(where: { $0.id == model }) {
                Label("\(model) (not listed)", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("This provider’s model list does not include this model. It is used as entered.")
            }
            else if models.isEmpty,
                draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text("Enter the endpoint URL and API key to choose from the provider’s models.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Shows the saved list at once, then refreshes it when policy allows. Typing
    /// restarts this task, which cancels the pending request and debounce.
    private func refreshModels() async {
        guard draft.kind == .openAICompatible else { return }
        let target = draft
        let fingerprint = ProviderModelList.fingerprint(target)
        if let cached = store.providerModelCache.entry(providerID: target.id, fingerprint: fingerprint) {
            models = cached.value
            modelListState = .loaded
        }
        else {
            models = []
            modelListState = .idle
        }
        switch ProviderModelListPolicy.plan(draft: target, saved: saved) {
        case .none: return
        case .immediate: break
        case .debounced:
            do { try await Task.sleep(for: ProviderModelListPolicy.debounce) }
            catch { return }
        }
        modelListState = .loading
        do {
            let fetched = try await ProviderModelList.fetch(target)
            guard !Task.isCancelled else { return }
            models = fetched.value
            modelListState = .loaded
            store.providerModelCache.store(
                .init(providerID: target.id, fingerprint: fingerprint, value: fetched.value, fetchedAt: Date()),
                keeping: Set(store.settings.serviceProviders.map(\.id)))
        }
        catch {
            guard !Task.isCancelled else { return }
            modelListState = .failed(error.localizedDescription)
        }
    }

    private var languageState: ProviderLanguageState { store.languageState(for: draft.id) }

    /// Website lists load only from this button or the language picker; saving never
    /// loads them. RunPod's list is built in, so it has no Load Languages action.
    private var languagesSection: some View {
        Section("Transcription Languages") {
            // The draft decides, so an unsaved RunPod provider also shows its list.
            if let catalog = ProviderLanguageService.builtInCatalog(for: draft) {
                Label("\(catalog.languages.count) languages · Built in", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            else {
                HStack(alignment: .firstTextBaseline) {
                    Label(languageStatus.text, systemImage: languageStatus.icon)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Load Languages") {
                        Task { await store.refreshProviderLanguages(providerID: draft.id) }
                    }
                    .disabled(hasChanges || saved?.supports(.transcription) != true || languageState == .loading)
                }
            }
        }
    }

    private var languageStatus: (text: String, icon: String) {
        if hasChanges { return ("Save to load languages.", "pencil.circle") }
        guard let saved, saved.isEnabled else {
            return ("Turn on Enable This Provider to load languages.", "circle.slash")
        }
        guard saved.supports(.transcription) else {
            return ("Turn on Transcription to load languages.", "circle.slash")
        }
        switch languageState {
        case .idle, .builtIn: return ("Not Loaded", "circle.dashed")
        case .loading: return ("Loading Languages…", "clock")
        case .failed(let message): return (message, "exclamationmark.circle.fill")
        case .loaded(let catalog, let fetchedAt):
            let count = catalog.languages.count
            return (
                "\(count) \(count == 1 ? "language" : "languages") · Updated \(fetchedAt.formatted(date: .abbreviated, time: .shortened))",
                "checkmark.circle"
            )
        }
    }

    private var endpointHelp: String {
        switch draft.kind {
        case .runpod:
            "In the RunPod console, open Serverless, select the endpoint, then copy its base URL from the API tab."
        case .openAICompatible:
            "Copy the API base URL from the provider’s documentation, including the API version path."
        case .gdayWebsite:
            "Enter the address of the Gday Meetings website that hosts this account."
        case .filedrop:
            "Enter the Filedrop service base URL supplied by the service administrator."
        }
    }

    private func capabilityBinding(_ capability: ProviderCapability) -> Binding<Bool> {
        Binding(
            get: { draft.enabledCapabilities.contains(capability) },
            set: { enabled in
                if enabled {
                    draft.enabledCapabilities.insert(capability)
                }
                else {
                    draft.enabledCapabilities.remove(capability)
                }
            })
    }

    private func disclosure(_ capability: ProviderCapability) -> String {
        switch capability {
        case .liveTranscription: "Transcribes audio during recording."
        case .transcription: "Transcription sends recording audio to this provider."
        case .diarization: "Speaker labels use recording audio to identify when each speaker talks."
        case .summarization:
            "Summaries send the selected transcript and notes to this provider, including images when Image Input supports them."
        case .search: "No search provider is available."
        case .playback: "Remote playback requires uploading original audio."
        case .fileTransfer: "Temporary audio links expire automatically."
        }
    }

    @discardableResult private func saveAndCheck() -> Bool {
        guard let index = store.settings.serviceProviders.firstIndex(where: { $0.id == draft.id }) else { return false }
        let previous = store.settings
        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.endpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        store.settings.serviceProviders[index] = draft
        guard store.saveSettings() else {
            store.settings = previous
            saveError = store.errorMessage ?? "Couldn’t save provider settings. Try again."
            return false
        }
        saveError = nil
        startCheck()
        return true
    }

    private func startCheck() {
        checkTask?.cancel()
        let token = UUID()
        checkID = token
        guard let provider = saved else { return }
        guard provider.isEnabled else {
            // Disabled providers are never contacted.
            isChecking = false
            status = "Not checked. This provider is disabled."
            statusIcon = "circle.slash"
            statusColor = .secondary
            return
        }
        status = "Checking Connection…"
        if provider.kind == .runpod {
            uploadStatus = "Checking Upload Provider…"
            uploadStatusIcon = "clock"
            uploadStatusColor = .secondary
        }
        isChecking = true
        checkTask = Task {
            do {
                let detail = try await ProviderConnectionChecker.check(provider, server: server).value
                guard !Task.isCancelled, checkID == token else { return }
                status = detail
                statusIcon = "checkmark.circle.fill"
                statusColor = .green
            }
            catch {
                guard !Task.isCancelled, checkID == token else { return }
                status = error.localizedDescription
                statusIcon = "exclamationmark.circle.fill"
                statusColor = .orange
            }
            if provider.kind == .runpod {
                await checkUploadProvider(for: provider, token: token)
            }
            guard !Task.isCancelled, checkID == token else { return }
            isChecking = false
        }
    }

    private func checkUploadProvider(for provider: ServiceProvider, token: UUID) async {
        guard let upload = store.settings.serviceProviders.first(where: { $0.id == provider.uploadProviderID }),
            upload.kind == .filedrop, upload.supports(.fileTransfer)
        else {
            guard !Task.isCancelled, checkID == token else { return }
            uploadStatus = "Choose a Filedrop provider with File Transfer enabled."
            uploadStatusIcon = "exclamationmark.circle.fill"
            uploadStatusColor = .orange
            return
        }
        do {
            let detail = try await ProviderConnectionChecker.check(upload, server: server).value
            guard !Task.isCancelled, checkID == token else { return }
            uploadStatus = detail
            uploadStatusIcon = "checkmark.circle.fill"
            uploadStatusColor = .green
        }
        catch {
            guard !Task.isCancelled, checkID == token else { return }
            uploadStatus = "\(upload.name): \(error.localizedDescription)"
            uploadStatusIcon = "exclamationmark.circle.fill"
            uploadStatusColor = .orange
        }
    }

    private func signIn() {
        guard saveAndCheck() else { return }
        signingIn = true
        signInTask = Task {
            defer { signingIn = false }
            do {
                try await server.signIn(origin: draft.endpoint)
                try Task.checkCancellation()
                startCheck()
            }
            catch {
                guard !Task.isCancelled else { return }
                showError(error)
            }
        }
    }

    private func showError(_ error: Error) {
        checkTask?.cancel()
        checkID = UUID()
        isChecking = false
        status = error.localizedDescription
        statusIcon = "exclamationmark.circle.fill"
        statusColor = .orange
    }
}

/// Settings windows can keep their SwiftUI view alive while closed. Observe the
/// containing window so reopening it also refreshes the selected provider.
private struct ProviderPanelWindowObserver: NSViewRepresentable {
    let onBecomeKey: () -> Void

    func makeNSView(context: Context) -> ProviderPanelWindowView {
        let view = ProviderPanelWindowView()
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ nsView: ProviderPanelWindowView, context: Context) {
        nsView.onBecomeKey = onBecomeKey
    }

    static func dismantleNSView(_ nsView: ProviderPanelWindowView, coordinator: ()) {
        NotificationCenter.default.removeObserver(nsView)
        nsView.onBecomeKey = nil
    }
}

private final class ProviderPanelWindowView: NSView {
    var onBecomeKey: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        }
    }

    @objc private func windowBecameKey() {
        guard !isHiddenOrHasHiddenAncestor else { return }
        onBecomeKey?()
    }
}
