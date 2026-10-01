import AppKit
import Testing

@testable import GdayMeetings

@MainActor @Suite(.serialized)
struct MainWindowLifecycleTests {
    @Test func classifiesStandardWindowsWithoutPrivateClassNames() {
        _ = NSApplication.shared
        let document = window([.titled, .closable])
        let settings = window([.titled])
        let status = window([.borderless])
        status.level = .statusBar
        let tooltip = window([.borderless])
        tooltip.level = .floating
        let dialog = NSPanel(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        #expect(MainWindowLifecycle.isUserFacing(document))
        #expect(MainWindowLifecycle.isUserFacing(settings))
        #expect(MainWindowLifecycle.isUserFacing(dialog))
        #expect(!MainWindowLifecycle.isUserFacing(status))
        #expect(!MainWindowLifecycle.isUserFacing(tooltip))
    }

    @Test func activationAndDockRequestsCoalesceAndIgnoreStatusWindows() {
        let harness = Harness()
        let status = window([.borderless])
        status.level = .statusBar
        status.simulatedVisible = true
        harness.windows = [status]
        #expect(harness.lifecycle.requestRestoration())
        #expect(harness.lifecycle.requestRestoration())
        #expect(harness.scheduled.count == 1)
        #expect(harness.opens == 0)
        harness.drain()
        #expect(harness.opens == 1)
    }

    @Test func startupWindowAppearingBeforeDeferredCheckPreventsAnotherOpen() {
        let harness = Harness()
        harness.lifecycle.requestRestoration()
        let main = window([.titled])
        main.simulatedVisible = true
        harness.windows = [main]
        harness.drain()
        #expect(harness.opens == 0)
    }

    @Test func visibleSettingsPreventsOpeningMainButClosedWindowsDoNot() {
        let harness = Harness()
        let settings = window([.titled])
        settings.simulatedVisible = true
        harness.windows = [settings]
        #expect(!harness.lifecycle.requestRestoration())
        #expect(harness.scheduled.isEmpty)
        harness.drain()
        #expect(harness.opens == 0)
        settings.simulatedVisible = false
        // Closing a window by itself must not queue any work.
        #expect(harness.scheduled.isEmpty)
        harness.lifecycle.requestRestoration()
        harness.drain()
        #expect(harness.opens == 1)
    }

    @Test func reusesMinimizedWindowWithoutCreatingAnother() {
        let harness = Harness()
        let main = window([.titled, .miniaturizable])
        main.simulatedMinimized = true
        harness.windows = [main]
        harness.lifecycle.requestRestoration()
        harness.drain()
        #expect(main.restored == 1)
        #expect(main.ordered == 1)
        #expect(harness.opens == 0)
    }

    @Test func losingActivationOrBeginningQuitCancelsQueuedRestoration() {
        let harness = Harness()
        harness.lifecycle.requestRestoration()
        harness.active = false
        harness.drain()
        #expect(harness.opens == 0)
        harness.active = true
        harness.lifecycle.requestRestoration()
        harness.lifecycle.isTerminating = true
        harness.drain()
        #expect(harness.opens == 0)
        #expect(!harness.lifecycle.requestRestoration())
        harness.lifecycle.isTerminating = false
        harness.lifecycle.requestRestoration()
        harness.drain()
        #expect(harness.opens == 1)
    }

    @Test func missingOpenerAndReentrantActivationDoNotQueueExtraWindows() {
        let harness = Harness()
        harness.lifecycle.openMainWindow = nil
        #expect(!harness.lifecycle.requestRestoration())
        #expect(harness.scheduled.isEmpty)
        harness.lifecycle.openMainWindow = {
            harness.opens += 1
            harness.lifecycle.requestRestoration()
        }
        harness.lifecycle.requestRestoration()
        harness.drain()
        #expect(harness.opens == 1)
        #expect(harness.scheduled.isEmpty)
    }

    private func window(_ style: NSWindow.StyleMask) -> LifecycleWindow {
        _ = NSApplication.shared
        let window = LifecycleWindow(
            contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}

/// Native window classification with presentation intercepted to avoid changing the test desktop.
@MainActor private final class LifecycleWindow: NSWindow {
    var simulatedVisible = false
    var simulatedMinimized = false
    var restored = 0
    var ordered = 0
    override var isVisible: Bool { simulatedVisible }
    override var isMiniaturized: Bool { simulatedMinimized }
    override func deminiaturize(_ sender: Any?) {
        restored += 1
        simulatedMinimized = false
    }
    override func makeKeyAndOrderFront(_ sender: Any?) { ordered += 1 }
}

@MainActor private final class Harness {
    var windows: [NSWindow] = []
    var active = true
    var opens = 0
    var scheduled: [@MainActor () -> Void] = []
    lazy var lifecycle: MainWindowLifecycle = {
        let lifecycle = MainWindowLifecycle(
            windows: { [unowned self] in windows },
            isActive: { [unowned self] in active },
            schedule: { [unowned self] action in scheduled.append(action) })
        lifecycle.openMainWindow = { [unowned self] in opens += 1 }
        return lifecycle
    }()

    func drain() {
        let work = scheduled
        scheduled.removeAll()
        for action in work { action() }
    }
}
