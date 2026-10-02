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
        .onAppear { settingsTab = Self.currentTab(for: settingsTab) }
    }
}
