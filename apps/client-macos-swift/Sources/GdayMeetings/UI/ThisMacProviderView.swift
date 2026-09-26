import Speech
import SwiftUI

enum ThisMacProvider {
    static let id = UUID(uuidString: "5987605A-1329-46E3-906D-2EC2D08B4D16")!
    static let capabilities: Set<ProviderCapability> = [.liveTranscription]
}

struct ThisMacProviderView: View {
    @ViewState private var locales: [Locale] = []
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
                if locales.isEmpty { Text(message).foregroundStyle(.secondary) }
                ForEach(locales, id: \.identifier) { locale in
                    if #available(macOS 26.0, *) { SpeechModelRow(locale: locale) }
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
            locales = await SpeechTranscriber.supportedLocales.sorted { $0.identifier < $1.identifier }
            if locales.isEmpty { message = "No speech models are available on this Mac." }
        }
    }
}

@available(macOS 26.0, *)
private struct SpeechModelRow: View {
    let locale: Locale
    @ViewState private var readiness: AssetInventory.Status?
    @ViewState private var downloading = false
    @ViewState private var progress = 0.0
    @ViewState private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                Spacer()
                if downloading {
                    ProgressView(value: progress).frame(width: 85)
                        .accessibilityLabel("Speech model download")
                }
                else if readiness == .installed {
                    Text("Installed").foregroundStyle(.secondary)
                }
                else if readiness == .supported || readiness == .downloading {
                    Button("Download") { Task { await download() } }
                }
                else {
                    Text(readiness == nil ? "Checking…" : "Unavailable").foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
        }
        .task { await refresh() }
    }
    private func refresh() async {
        readiness = await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)])
    }
    private func download() async {
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
        await refresh()
    }
}
