import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @AppStorage("settingsTab") private var settingsTab = "defaults"

    /// Tabs that were folded into Defaults. A saved selection of one of them
    /// would otherwise open Settings with no tab shown.
    static func currentTab(for saved: String) -> String {
        ["recording", "transcription", "summaries"].contains(saved) ? "defaults" : saved
    }

    var body: some View {
        // HIG: a persistent tab selection groups settings by task in the standard
        // Settings scene; labeled native form controls support keyboard/VoiceOver.
        // https://developer.apple.com/design/human-interface-guidelines/settings
        TabView(selection: $settingsTab) {
            DefaultsSettingsView().disabled(store.isChangingLibrary)
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
                .tag("defaults")
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
        .formStyle(.grouped).padding(16).frame(width: 780, height: 650)
        .onAppear { settingsTab = Self.currentTab(for: settingsTab) }
    }
}
