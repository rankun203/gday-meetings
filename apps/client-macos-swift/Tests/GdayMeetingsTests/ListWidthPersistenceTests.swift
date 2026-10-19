import AppKit
import Testing

@testable import GdayMeetings

@MainActor
struct ListWidthPersistenceTests {
    private final class InsetListPane: NSView {
        override var safeAreaInsets: NSEdgeInsets {
            NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 10)
        }
    }

    private let userDrag: [AnyHashable: Any] = [
        "NSSplitViewUserResizeKey": NSNumber(value: true),
        "NSSplitViewDividerIndex": NSNumber(value: 0),
    ]

    private func withPreferences(_ body: (ListWidthPreferences) throws -> Void) throws {
        let suite = "ListWidthPersistenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(ListWidthPreferences(defaults: defaults))
    }

    @Test func pagesAndSidebarStatesHaveIndependentPreferences() throws {
        try withPreferences { preferences in
            var keys = Set<String>()
            for (index, page) in ListWidthPage.allCases.enumerated() {
                for expanded in [false, true] {
                    let key = ListWidthPreferenceKey(page: page, sidebarExpanded: expanded)
                    #expect(keys.insert(key.defaultsKey).inserted)
                    let width = CGFloat(260 + index * 10 + (expanded ? 5 : 0))
                    preferences.record(width: width, for: key, userInfo: userDrag)
                }
            }
            for (index, page) in ListWidthPage.allCases.enumerated() {
                for expanded in [false, true] {
                    let key = ListWidthPreferenceKey(page: page, sidebarExpanded: expanded)
                    #expect(preferences.preferredWidth(for: key) == CGFloat(260 + index * 10 + (expanded ? 5 : 0)))
                }
            }
            let voiceSheet = ListWidthPreferenceKey(page: .voices)
            #expect(keys.insert(voiceSheet.defaultsKey).inserted)
            #expect(preferences.preferredWidth(for: voiceSheet) == 280)
        }
    }

    @Test func ordinaryLayoutAndOtherDividersDoNotSaveWidths() throws {
        try withPreferences { preferences in
            let key = ListWidthPreferenceKey(page: .meetings, sidebarExpanded: false)
            preferences.record(width: 320, for: key, userInfo: userDrag)
            let ignored: [[AnyHashable: Any]?] = [
                nil,
                ["NSSplitViewDividerIndex": NSNumber(value: 0)],
                ["NSSplitViewUserResizeKey": NSNumber(value: false), "NSSplitViewDividerIndex": NSNumber(value: 0)],
                ["NSSplitViewUserResizeKey": NSNumber(value: true), "NSSplitViewDividerIndex": NSNumber(value: 1)],
            ]
            for info in ignored { preferences.record(width: 250, for: key, userInfo: info) }
            #expect(preferences.preferredWidth(for: key) == 320)
        }
    }

    @Test func invalidWidthsUsePageDefaultsAndDoNotReplacePreferences() throws {
        try withPreferences { preferences in
            let key = ListWidthPreferenceKey(page: .tasks, sidebarExpanded: true)
            #expect(preferences.preferredWidth(for: key) == 340)
            preferences.record(width: 400, for: key, userInfo: userDrag)
            for width: CGFloat in [0, -1, .infinity, .nan] {
                preferences.record(width: width, for: key, userInfo: userDrag)
            }
            #expect(preferences.preferredWidth(for: key) == 400)
            preferences.defaults.set(-40, forKey: key.defaultsKey)
            #expect(preferences.preferredWidth(for: key) == 340)
        }
    }

    @Test func restorationClampsPositionAndRetainsPreferredWidth() throws {
        try withPreferences { preferences in
            let key = ListWidthPreferenceKey(page: .tags, sidebarExpanded: true)
            preferences.record(width: 350, for: key, userInfo: userDrag)
            let constrained = ListWidthPreferences.dividerPosition(
                preferredWidth: preferences.preferredWidth(for: key), paneOrigin: 0,
                leftInset: 200, rightInset: 10, minimum: 460, maximum: 500)
            #expect(constrained == 500)
            #expect(preferences.preferredWidth(for: key) == 350)
            let restored = ListWidthPreferences.dividerPosition(
                preferredWidth: preferences.preferredWidth(for: key), paneOrigin: 0,
                leftInset: 200, rightInset: 10, minimum: 460, maximum: 800)
            #expect(restored == 560)
            #expect(ListWidthPreferences.visibleWidth(hostWidth: restored, leftInset: 200, rightInset: 10) == 350)
        }
    }

    @Test func nativeSplitRestoresEachContextOnceWithoutSavingWindowResize() throws {
        try withPreferences { preferences in
            let closed = ListWidthPreferenceKey(page: .people, sidebarExpanded: false)
            let open = ListWidthPreferenceKey(page: .people, sidebarExpanded: true)
            preferences.record(width: 350, for: closed, userInfo: userDrag)
            preferences.record(width: 270, for: open, userInfo: userDrag)
            let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
            split.isVertical = true
            split.dividerStyle = .thin
            let list = InsetListPane(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
            let detail = NSView(frame: NSRect(x: 301, y: 0, width: 699, height: 600))
            split.addArrangedSubview(list)
            split.addArrangedSubview(detail)
            let marker = ListWidthPersistence.PersistenceView(key: closed, preferences: preferences)
            list.addSubview(marker)
            defer { marker.disconnect() }
            marker.layout()
            #expect(abs(list.frame.width - 380) < 1)

            split.setPosition(320, ofDividerAt: 0)
            marker.layout()
            #expect(abs(list.frame.width - 320) < 1)
            #expect(preferences.preferredWidth(for: closed) == 350)

            marker.configure(key: open, preferences: preferences)
            marker.layout()
            #expect(abs(list.frame.width - 300) < 1)
            split.setPosition(340, ofDividerAt: 0)
            NotificationCenter.default.post(
                name: NSSplitView.didResizeSubviewsNotification, object: split, userInfo: userDrag)
            #expect(abs(preferences.preferredWidth(for: open) - 310) < 1)
            #expect(preferences.preferredWidth(for: closed) == 350)
        }
    }
}
