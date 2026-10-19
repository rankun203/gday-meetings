import AppKit
import SwiftUI

enum ListWidthPage: String, CaseIterable {
    case meetings, people, tags, tasks, voices

    var defaultWidth: CGFloat {
        switch self {
        case .tasks: return 340
        case .voices: return 280
        default: return 300
        }
    }
}

struct ListWidthPreferenceKey: Equatable {
    let page: ListWidthPage
    var sidebarExpanded: Bool? = nil

    var defaultsKey: String {
        let context = sidebarExpanded.map { $0 ? "sidebarOpen" : "sidebarClosed" } ?? "standalone"
        return "library.listWidth.\(page.rawValue).\(context)"
    }
}

struct ListWidthPreferences {
    var defaults: UserDefaults = .standard

    func preferredWidth(for key: ListWidthPreferenceKey) -> CGFloat {
        guard let number = defaults.object(forKey: key.defaultsKey) as? NSNumber else { return key.page.defaultWidth }
        let width = CGFloat(number.doubleValue)
        return width.isFinite && width > 0 ? width : key.page.defaultWidth
    }

    func record(width: CGFloat, for key: ListWidthPreferenceKey, userInfo: [AnyHashable: Any]?) {
        guard Self.isUserDividerResize(userInfo), width.isFinite, width > 0 else { return }
        defaults.set(Double(width), forKey: key.defaultsKey)
    }

    // These keys are documented by AppKit for didResizeSubviewsNotification.
    // A divider index alone also appears during ordinary layout on macOS 12+.
    static func isUserDividerResize(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?["NSSplitViewUserResizeKey"] as? NSNumber)?.boolValue == true
            && (userInfo?["NSSplitViewDividerIndex"] as? NSNumber)?.intValue == 0
    }

    static func visibleWidth(hostWidth: CGFloat, leftInset: CGFloat, rightInset: CGFloat) -> CGFloat {
        max(0, hostWidth - leftInset - rightInset)
    }

    static func dividerPosition(
        preferredWidth: CGFloat, paneOrigin: CGFloat, leftInset: CGFloat, rightInset: CGFloat,
        minimum: CGFloat, maximum: CGFloat
    ) -> CGFloat {
        min(maximum, max(minimum, paneOrigin + preferredWidth + leftInset + rightInset))
    }
}

/// Attach to the list pane of an existing HSplitView. Native layout still owns
/// resizing; preferences are restored once when the page or sidebar context changes.
struct ListWidthPersistence: NSViewRepresentable {
    let key: ListWidthPreferenceKey
    var preferences = ListWidthPreferences()

    func makeNSView(context: Context) -> PersistenceView {
        PersistenceView(key: key, preferences: preferences)
    }

    func updateNSView(_ view: PersistenceView, context: Context) {
        view.configure(key: key, preferences: preferences)
    }

    static func dismantleNSView(_ view: PersistenceView, coordinator: ()) {
        view.disconnect()
    }

    final class PersistenceView: NSView {
        private var key: ListWidthPreferenceKey
        private var preferences: ListWidthPreferences
        private weak var split: NSSplitView?
        private var restorePending = true
        private var restoring = false

        init(key: ListWidthPreferenceKey, preferences: ListWidthPreferences) {
            self.key = key
            self.preferences = preferences
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func configure(key: ListWidthPreferenceKey, preferences: ListWidthPreferences) {
            self.preferences = preferences
            if self.key != key {
                self.key = key
                restorePending = true
                needsLayout = true
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                disconnect()
            }
            else {
                connect()
                needsLayout = true
            }
        }

        override func layout() {
            super.layout()
            if split == nil { connect() }
            guard restorePending, let split, split.isVertical, split.arrangedSubviews.count == 2,
                split.bounds.width > 0, let pane = split.arrangedSubviews.first, pane.bounds.width > 0
            else { return }
            let minimum = split.minPossiblePositionOfDivider(at: 0)
            let maximum = split.maxPossiblePositionOfDivider(at: 0)
            guard minimum.isFinite, maximum.isFinite, minimum <= maximum else { return }
            restorePending = false
            let position = ListWidthPreferences.dividerPosition(
                preferredWidth: preferences.preferredWidth(for: key), paneOrigin: pane.frame.minX,
                leftInset: pane.safeAreaInsets.left, rightInset: pane.safeAreaInsets.right,
                minimum: minimum, maximum: maximum)
            restoring = true
            // setPosition also applies the existing native delegate's width constraints.
            split.setPosition(position, ofDividerAt: 0)
            restoring = false
        }

        private func connect() {
            var ancestor = superview
            while let view = ancestor {
                if let candidate = view as? NSSplitView {
                    guard candidate !== split else { return }
                    disconnect()
                    split = candidate
                    restorePending = true
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(dividerResized(_:)),
                        name: NSSplitView.didResizeSubviewsNotification, object: candidate)
                    return
                }
                ancestor = view.superview
            }
        }

        func disconnect() {
            NotificationCenter.default.removeObserver(
                self, name: NSSplitView.didResizeSubviewsNotification, object: split)
            split = nil
        }

        @objc private func dividerResized(_ notification: Notification) {
            guard !restoring, !restorePending, let split, let pane = split.arrangedSubviews.first else { return }
            let width = ListWidthPreferences.visibleWidth(
                hostWidth: pane.bounds.width, leftInset: pane.safeAreaInsets.left, rightInset: pane.safeAreaInsets.right
            )
            preferences.record(width: width, for: key, userInfo: notification.userInfo)
        }
    }
}
