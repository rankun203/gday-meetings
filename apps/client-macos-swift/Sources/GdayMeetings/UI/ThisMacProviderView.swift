import Speech
import SwiftUI

enum ThisMacProvider {
    static let id = UUID(uuidString: "5987605A-1329-46E3-906D-2EC2D08B4D16")!
    static let capabilities: Set<ProviderCapability> = [.liveTranscription]
}

struct ThisMacProviderView: View {
    @ViewState private var models: [SpeechModelOption] = []
    @ViewState private var message = "Checking speech models…"
    var body: some View {
        Form {
            Section {
                Label("This Mac", systemImage: "desktopcomputer").font(.title2.weight(.semibold))
                Text("Live transcription audio stays on this Mac.")
                Text(
                    "Speech models are downloaded from Apple when needed. Recording continues while a model downloads."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Live Transcription") {
                Text(
                    "Choose a language when you record. The model used for each language is shown below. English uses English (United States)."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Installed models appear first. Download only the languages you use."
                )
                .font(.caption).foregroundStyle(.secondary)
                if models.isEmpty { Text(message).foregroundStyle(.secondary) }
                ForEach(models) { model in
                    if #available(macOS 26.0, *) {
                        SpeechModelRow(model: model) {
                            await refreshModels()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            guard #available(macOS 26.0, *) else {
                message = "Live transcript requires macOS 26 or later."
                return
            }
            guard SpeechTranscriber.isAvailable else {
                message = "Live transcript isn’t available on this Mac."
                return
            }
            await refreshModels()
            if models.isEmpty { message = "No speech models are available on this Mac." }
        }
    }

    @MainActor @available(macOS 26.0, *)
    private func refreshModels() async {
        let supported = await SpeechTranscriber.supportedLocales
        var snapshot: [SpeechModelOption] = []
        for language in AppLanguages.all {
            guard let locale = AppleSpeechLanguageMapping.locale(for: language.code, supported: supported) else {
                snapshot.append(.init(language: language, locale: nil, readiness: .unavailable))
                continue
            }
            let status = await AssetInventory.status(forModules: [
                SpeechTranscriber(locale: locale, preset: .transcription)
            ])
            let readiness: SpeechModelReadiness
            switch status {
            case .installed: readiness = .installed
            case .supported, .downloading: readiness = .available
            default: readiness = .unavailable
            }
            snapshot.append(.init(language: language, locale: locale, readiness: readiness))
        }
        guard !Task.isCancelled else { return }
        models = SpeechModelOrdering.sorted(snapshot)
    }
}

enum SpeechModelReadiness { case installed, available, unavailable }
struct SpeechModelOption: Identifiable {
    let language: ProviderLanguage
    let locale: Locale?
    let readiness: SpeechModelReadiness
    var id: String { language.code }
}

enum SpeechModelOrdering {
    static func sorted(_ models: [SpeechModelOption], displayLocale: Locale = .current) -> [SpeechModelOption] {
        models.sorted { lhs, rhs in
            let leftInstalled = lhs.readiness == .installed
            let rightInstalled = rhs.readiness == .installed
            if leftInstalled != rightInstalled { return leftInstalled }
            let comparison = lhs.language.name.compare(
                rhs.language.name,
                options: [.caseInsensitive, .diacriticInsensitive], locale: displayLocale)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
}

@available(macOS 26.0, *)
private struct SpeechModelRow: View {
    let model: SpeechModelOption
    let refreshAllModels: () async -> Void
    @ViewState private var downloading = false
    @ViewState private var progress = 0.0
    @ViewState private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.language.name)
                    if let locale = model.locale {
                        Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if downloading {
                    ProgressView(value: progress).frame(width: 85)
                        .accessibilityLabel("Speech model download")
                }
                else if model.readiness == .installed {
                    Text("Installed").foregroundStyle(.secondary)
                }
                else if model.readiness == .available {
                    Button("Download") { Task { await download() } }
                }
                else {
                    Text("Unavailable on this Mac").foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func download() async {
        guard let locale = model.locale else { return }
        downloading = true
        failure = nil
        defer { downloading = false }
        AppleLiveTranscription.log.notice(
            "Speech model installation requested: locale \(locale.identifier, privacy: .public)")
        do {
            try await AppleSpeechAssets.shared.reserve(locale)
            let module = SpeechTranscriber(locale: locale, preset: .transcription)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                let watch = Task { @MainActor in
                    while !Task.isCancelled {
                        progress = request.progress.fractionCompleted
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { watch.cancel() }
                try await request.downloadAndInstall()
            }
            AppleLiveTranscription.log.notice(
                "Speech model installation completed: locale \(locale.identifier, privacy: .public)")
        }
        catch {
            failure = "Couldn’t download this speech model. Check your internet connection and available storage."
            AppleLiveTranscription.log.error(
                "Speech model installation failed: locale \(locale.identifier, privacy: .public)")
        }
        // Apple may share installed assets across regional locales. Refresh the
        // whole list and its ordering, not just the row that started the download.
        await refreshAllModels()
    }
}
