import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @AppStorage("settingsTab") private var settingsTab = "general"
    @EnvironmentObject private var drafts: ProviderDraftCoordinator
    @ViewState private var selectedTab = "general"
    @ViewState private var committedTab = "general"

    private func selectTab(_ value: String) {
        guard value != committedTab else { return }
        if drafts.confirmLeaving(store: store) { committedTab = value }
        selectedTab = committedTab
        settingsTab = committedTab
    }

    /// Tabs that were folded into General. A saved selection of one of them
    /// would otherwise open Settings with no tab shown.
    static func currentTab(for saved: String) -> String {
        ["defaults", "recording", "transcription", "summaries"].contains(saved) ? "general" : saved
    }

    var body: some View {
        // HIG: a persistent tab selection groups settings by task in the standard
        // Settings scene; labeled native form controls support keyboard/VoiceOver.
        // https://developer.apple.com/design/human-interface-guidelines/settings
        TabView(selection: $selectedTab) {
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
        .formStyle(.grouped)
        .padding(AppTheme.contentSpacing)
        .frame(width: 960, height: 720)
        .onAppear {
            committedTab = Self.currentTab(for: settingsTab)
            selectedTab = committedTab
            settingsTab = selectedTab
        }
        .onChange(of: selectedTab) { _, value in selectTab(value) }
        .onChange(of: settingsTab) { _, value in selectedTab = Self.currentTab(for: value) }
    }
}
