import Testing

@testable import GdayMeetings

/// Recording, Transcription, and Summaries were folded into Defaults; a saved
/// selection of any of them must still open a tab.
struct SettingsTabTests {
    @Test(arguments: ["recording", "transcription", "summaries"])
    func retiredTabsOpenDefaults(saved: String) {
        #expect(SettingsView.currentTab(for: saved) == "defaults")
    }

    @Test(arguments: ["defaults", "providers", "privacy"])
    func currentTabsAreKept(saved: String) {
        #expect(SettingsView.currentTab(for: saved) == saved)
    }
}
