import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @AppStorage("settingsTab") private var settingsTab = "general"

    /// Tabs that were folded into General. A saved selection of one of them
    /// would otherwise open Settings with no tab shown.
    static func currentTab(for saved: String) -> String {
        ["defaults", "recording", "transcription", "summaries"].contains(saved) ? "general" : saved
    }

    var body: some View {
        // HIG: a persistent tab selection groups settings by task in the standard
        // Settings scene; labeled native form controls support keyboard/VoiceOver.
        // https://developer.apple.com/design/human-interface-guidelines/settings
        TabView(selection: $settingsTab) {
            GeneralSettingsView().disabled(store.isChangingLibrary)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
                .tag("general")
            ServiceProvidersView().disabled(store.isChangingLibrary)
                .tabItem { Label("Service Providers", systemImage: "server.rack") }
                .tag("providers")
            DataSettingsView()
                .tabItem { Label("Data", systemImage: "externaldrive") }
                .tag("data")
            DataPrivacyView().disabled(store.isChangingLibrary)
                .tabItem { Label("Data Privacy", systemImage: "hand.raised") }
                .tag("privacy")
        }
        .formStyle(.grouped).padding(16).frame(width: 960, height: 720)
        .background(SettingsToolbarSpacing())
        .onAppear { settingsTab = Self.currentTab(for: settingsTab) }
    }
}

/// Keep the native settings tabs while separating them with standard toolbar spaces.
private struct SettingsToolbarSpacing: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsToolbarSpacingView { SettingsToolbarSpacingView() }
    func updateNSView(_ nsView: SettingsToolbarSpacingView, context: Context) { nsView.updateSpacing() }
    static func dismantleNSView(_ nsView: SettingsToolbarSpacingView, coordinator: ()) {
        NotificationCenter.default.removeObserver(nsView)
    }
}

private final class SettingsToolbarSpacingView: NSView {
    private var isUpdatingSpacing = false
    private let tabLabels = ["General", "Service Providers", "Data", "Data Privacy"]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateSpacing), name: NSWindow.didUpdateNotification, object: window)
        updateSpacing()
        // The Settings scene can attach its toolbar after the content view.
        DispatchQueue.main.async { [weak self] in self?.updateSpacing() }
    }

    @objc func updateSpacing() {
        guard !isUpdatingSpacing, let toolbar = window?.toolbar else { return }
        let labels = toolbar.items.map(\.label)
        guard tabLabels.allSatisfy({ labels.contains($0) }) else { return }
        isUpdatingSpacing = true
        defer { isUpdatingSpacing = false }
        // SwiftUI can rebuild the native toolbar when switching tabs. Inspect each
        // current boundary rather than assuming that an earlier insertion remains.
        for pair in zip(tabLabels, tabLabels.dropFirst()).reversed() {
            let items = toolbar.items
            guard let left = items.firstIndex(where: { $0.label == pair.0 }),
                let right = items.firstIndex(where: { $0.label == pair.1 }), right == left + 1
            else { continue }
            toolbar.insertItem(withItemIdentifier: .space, at: right)
        }
    }
}
