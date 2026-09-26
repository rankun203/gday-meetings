import Foundation
import Testing

@testable import GdayMeetings

struct DataPrivacyTests {
    private func row(_ rows: [PrivacyRow], _ type: PrivacyDataType) -> PrivacyRow {
        rows.first { $0.type == type }!
    }
    private func texts(_ rows: [PrivacyRow], _ type: PrivacyDataType) -> [String] {
        row(rows, type).destinations.map(\.text)
    }
    private func runpodAndFiledrop() -> (runpod: ServiceProvider, filedrop: ServiceProvider) {
        var filedrop = ServiceProvider(kind: .filedrop)
        filedrop.endpoint = "https://files.example.com"
        filedrop.apiKey = "synthetic"
        filedrop.enabledCapabilities = [.fileTransfer]
        var runpod = ServiceProvider(kind: .runpod)
        runpod.endpoint = "https://api.runpod.ai/v2/abc"
        runpod.apiKey = "synthetic"
        runpod.enabledCapabilities = [.transcription, .diarization]
        runpod.uploadProviderID = filedrop.id
        return (runpod, filedrop)
    }
    private func website() -> ServiceProvider {
        var website = ServiceProvider(kind: .gdayWebsite)
        website.name = "Office Website"
        website.endpoint = "https://meet.example.com"
        website.enabledCapabilities = [.transcription, .search]
        return website
    }

    @Test func everythingStaysOnThisMacWithoutProviders() {
        let rows = DataPrivacy.rows(PrivacyContext(settings: AppSettings()))
        #expect(rows.map(\.type) == PrivacyDataType.allCases)
        #expect(rows.allSatisfy { !$0.leavesMac && $0.note == nil })
    }

    @Test func runpodSendsAudioThroughFiledrop() {
        let (runpod, filedrop) = runpodAndFiledrop()
        var settings = AppSettings()
        settings.serviceProviders = [runpod, filedrop]
        settings.transcriptionProviderID = runpod.id
        var rows = DataPrivacy.rows(PrivacyContext(settings: settings))
        #expect(
            texts(rows, .audio) == [
                "Sent to Filedrop (files.example.com) when you transcribe a meeting",
                "Sent to RunPod (api.runpod.ai) when you transcribe a meeting",
            ])
        #expect(row(rows, .audio).note?.contains("Filedrop link") == true)
        #expect(texts(rows, .meetingDetails) == ["Sent to RunPod (api.runpod.ai) when you transcribe a meeting"])
        #expect(row(rows, .meetingDetails).note == "RunPod receives only the meeting language.")
        for type in [PrivacyDataType.notes, .transcripts, .summaries, .todos, .chat, .peopleAndTags, .settings, .logs] {
            #expect(!row(rows, type).leavesMac)
        }
        #expect(
            texts(rows, .credentials) == [
                // RunPod languages are built in, so Load Languages sends nothing to RunPod.
                "Sent to RunPod (api.runpod.ai) to authenticate when you transcribe a meeting or open the provider in Settings",
                "Sent to Filedrop (files.example.com) to authenticate when you transcribe a meeting or open the provider in Settings",
            ])

        settings.autoTranscribe = true
        rows = DataPrivacy.rows(PrivacyContext(settings: settings))
        #expect(
            texts(rows, .audio).last
                == "Sent to RunPod (api.runpod.ai) after recording when automatic transcription applies and when you transcribe a meeting"
        )
    }

    @Test func manualProvidersAreDisclosedButOnlyDefaultRunsAutomatically() {
        let (runpod, filedrop) = runpodAndFiledrop()
        var alternate = runpod
        alternate.id = UUID()
        alternate.name = "Other RunPod"
        var settings = AppSettings()
        settings.serviceProviders = [runpod, alternate, filedrop]
        settings.transcriptionProviderID = runpod.id
        settings.autoTranscribe = true
        let routes = DataPrivacy.routes(PrivacyContext(settings: settings))
        #expect(routes.contains { $0.trigger == .transcribe && $0.receivers.contains { $0.id == alternate.id } })
        #expect(!routes.contains { $0.trigger == .afterRecording && $0.receivers.contains { $0.id == alternate.id } })
        #expect(routes.contains { $0.trigger == .afterRecording && $0.receivers.contains { $0.id == runpod.id } })
        let audio = row(DataPrivacy.rows(PrivacyContext(settings: settings)), .audio)
        #expect(audio.destinations.filter { $0.id == filedrop.id }.count == 1)
    }

    @Test func runpodWithoutUsableUploadProviderSendsNoAudio() {
        var (runpod, filedrop) = runpodAndFiledrop()
        filedrop.isEnabled = false
        var settings = AppSettings()
        settings.serviceProviders = [runpod, filedrop]
        settings.transcriptionProviderID = runpod.id
        #expect(!row(DataPrivacy.rows(PrivacyContext(settings: settings)), .audio).leavesMac)
        runpod.uploadProviderID = nil
        filedrop.isEnabled = true
        settings.serviceProviders = [runpod, filedrop]
        #expect(!row(DataPrivacy.rows(PrivacyContext(settings: settings)), .audio).leavesMac)
    }

    @Test func pendingAttemptKeepsItsOriginalProvider() {
        let (runpod, filedrop) = runpodAndFiledrop()
        var settings = AppSettings()
        settings.serviceProviders = [runpod, filedrop]
        let context = PrivacyContext(
            settings: settings,
            pendingTranscriptions: [.init(providerID: runpod.id, uploadProviderID: filedrop.id)])
        #expect(row(DataPrivacy.rows(context), .audio).destinations.map(\.provider) == ["Filedrop", "RunPod"])
    }

    @Test func websiteNeedsSignInAndListsEachAction() {
        let website = website()
        var settings = AppSettings()
        settings.serviceProviders = [website]
        settings.transcriptionProviderID = website.id
        #expect(DataPrivacy.rows(PrivacyContext(settings: settings)).allSatisfy { !$0.leavesMac })

        let rows = DataPrivacy.rows(
            PrivacyContext(settings: settings, signedInWebsiteOrigin: "https://meet.example.com"))
        #expect(
            texts(rows, .audio) == [
                "Sent to Office Website (meet.example.com) when you transcribe a meeting or choose Archive to Server"
            ])
        #expect(texts(rows, .todos) == ["Sent to Office Website (meet.example.com) when you choose Archive to Server"])
        #expect(texts(rows, .peopleAndTags) == texts(rows, .todos))
        #expect(
            texts(rows, .credentials) == [
                "Sent to Office Website (meet.example.com) to authenticate when you transcribe a meeting, choose Archive to Server, open the provider in Settings, or choose Load Languages"
            ])
        #expect(!row(rows, .settings).leavesMac)
    }

    @Test func openAICompatibleSummariesSendMeetingTextButNotToDos() {
        var llm = ServiceProvider(kind: .openAICompatible)
        llm.name = "Team LLM"
        llm.endpoint = "http://localhost:11434/v1"
        llm.model = "local-model"
        llm.enabledCapabilities = [.summarization]
        var settings = AppSettings()
        settings.serviceProviders = [llm]
        settings.summaryProviderID = llm.id
        let rows = DataPrivacy.rows(PrivacyContext(settings: settings))
        let expected = "Sent to Team LLM (localhost:11434) when you generate a summary or send a chat message"
        for type in [PrivacyDataType.meetingDetails, .notes, .transcripts, .summaries, .chat, .settings] {
            #expect(texts(rows, type) == [expected])
        }
        #expect(row(rows, .settings).note == "Only Summary Instructions are sent.")
        for type in [PrivacyDataType.audio, .todos, .peopleAndTags, .credentials, .logs] {
            #expect(!row(rows, type).leavesMac)
        }

        settings.serviceProviders[0].model = ""
        #expect(!row(DataPrivacy.rows(PrivacyContext(settings: settings)), .notes).leavesMac)
    }

    @Test func serverArchiveDoesNotNeedACapability() {
        var website = website()
        website.enabledCapabilities = []
        var settings = AppSettings()
        settings.serviceProviders = [website]
        let context = PrivacyContext(settings: settings, signedInWebsiteOrigin: "https://meet.example.com")
        let rows = DataPrivacy.rows(context)
        let archive = "Sent to Office Website (meet.example.com) when you choose Archive to Server"
        for type in [
            PrivacyDataType.audio, .meetingDetails, .notes, .transcripts, .summaries, .todos, .chat, .peopleAndTags,
        ] {
            #expect(texts(rows, type) == [archive])
        }
        #expect(!row(rows, .settings).leavesMac)
        #expect(!row(rows, .logs).leavesMac)

        settings.serviceProviders[0].isEnabled = false
        let disabled = DataPrivacy.rows(
            PrivacyContext(settings: settings, signedInWebsiteOrigin: "https://meet.example.com"))
        #expect(!row(disabled, .notes).leavesMac)
    }

    @Test func disabledProvidersSendCredentialsOnlyWhileEditingModels() {
        var (runpod, filedrop) = runpodAndFiledrop()
        runpod.isEnabled = false
        filedrop.isEnabled = false
        var llm = ServiceProvider(kind: .openAICompatible)
        llm.name = "OpenRouter"
        llm.endpoint = "https://openrouter.ai/api/v1"
        llm.apiKey = "synthetic"
        llm.model = "openai/gpt-4o"
        llm.enabledCapabilities = [.summarization]
        var settings = AppSettings()
        settings.serviceProviders = [runpod, filedrop, llm]
        settings.summaryProviderID = llm.id
        #expect(
            texts(DataPrivacy.rows(PrivacyContext(settings: settings)), .credentials) == [
                "Sent to OpenRouter (openrouter.ai) to authenticate when you generate a summary or send a chat message, or open the provider in Settings"
            ])
        settings.serviceProviders[2].isEnabled = false
        #expect(
            texts(DataPrivacy.rows(PrivacyContext(settings: settings)), .credentials) == [
                "Sent to OpenRouter (openrouter.ai) to authenticate when you edit the provider in Settings"
            ])
    }

    @Test func pendingAttemptsExcludeSubmittedJobs() {
        let provider = ServiceProvider(kind: .runpod)
        var unsent = Meeting()
        unsent.transcriptionAttempt = ProviderTranscriptionAttempt(provider: provider, meeting: unsent)
        var submitted = Meeting()
        submitted.transcriptionAttempt = ProviderTranscriptionAttempt(provider: provider, meeting: submitted)
        submitted.transcriptionAttempt?.taskID = "job"
        #expect(PrivacyContext.pending(in: [unsent, submitted, Meeting()]).count == 1)
    }

    @Test func triggerPhrasesJoinActions() {
        #expect(PrivacyDestination.phrase([.transcribe]) == "when you transcribe a meeting")
        #expect(
            PrivacyDestination.phrase([.afterRecording, .transcribe, .summarizeOrChat, .archive])
                == "after recording when automatic transcription applies and when you transcribe a meeting, generate a summary or send a chat message, or choose Archive to Server"
        )
    }

    @Test func syntheticPreviewProvidersUseUnresolvableHosts() {
        let settings = UIPreview.syntheticProviderSettings(AppSettings())
        #expect(settings.serviceProviders.allSatisfy { DataPrivacy.host($0.endpoint).hasSuffix(".invalid") })
        let rows = DataPrivacy.rows(PrivacyContext(settings: settings))
        #expect(row(rows, .audio).destinations.count == 2)
        #expect(row(rows, .notes).leavesMac)
    }
}
