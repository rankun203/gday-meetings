import Testing

@testable import GdayMeetings

/// Recording, Transcription, and Summaries were folded into General; a saved
/// selection of any of them must still open a tab.
struct SettingsTabTests {
    @Test(arguments: ["defaults", "recording", "transcription", "summaries"])
    func retiredTabsOpenGeneral(saved: String) {
        #expect(SettingsView.currentTab(for: saved) == "general")
    }

    @Test(arguments: ["general", "providers", "data", "privacy"])
    func currentTabsAreKept(saved: String) {
        #expect(SettingsView.currentTab(for: saved) == saved)
    }
}
