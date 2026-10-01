import AppKit

/// Restore a user-facing window at activation boundaries, never in response to closing one.
@MainActor
final class MainWindowLifecycle {
    var openMainWindow: (() -> Void)?
    var isTerminating = false
    private var restorationScheduled = false
    private var isRestoring = false
    private let windows: @MainActor () -> [NSWindow]
    private let isActive: @MainActor () -> Bool
    private let schedule: (@escaping @MainActor () -> Void) -> Void

    init(
        windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows },
        isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        schedule: @escaping (@escaping @MainActor () -> Void) -> Void = { action in
            DispatchQueue.main.async { action() }
        }
    ) {
        self.windows = windows
        self.isActive = isActive
        self.schedule = schedule
    }

    /// Return whether this policy owns the request, including requests already queued.
    @discardableResult
    func requestRestoration() -> Bool {
        guard !isTerminating, openMainWindow != nil else { return false }
        // Preserve AppKit's normal Dock ordering when usable UI is already present.
        guard !windows().contains(where: { Self.isUserFacing($0) && $0.isVisible && !$0.isMiniaturized }) else {
            return false
        }
        guard !restorationScheduled, !isRestoring else { return true }
        restorationScheduled = true
        // Let AppKit finish activation and SwiftUI present an already-requested scene first.
        schedule { [weak self] in
            guard let self else { return }
            self.restorationScheduled = false
            guard !self.isTerminating, self.isActive() else { return }
            self.restoreIfNeeded()
        }
        return true
    }

    static func isUserFacing(_ window: NSWindow) -> Bool {
        // MenuBarExtra, tooltips, and status windows must not keep the app windowless.
        // Standard Settings windows, sheets, and dialogs do count as usable UI.
        window.isSheet || window.isModalPanel
            || (window.level == .normal
                && (window.styleMask.contains(.titled) || window.canBecomeMain || window.canBecomeKey))
    }

    private func restoreIfNeeded() {
        let candidates = windows().filter(Self.isUserFacing)
        guard !candidates.contains(where: { $0.isVisible && !$0.isMiniaturized }) else { return }
        isRestoring = true
        defer { isRestoring = false }
        if let minimized = candidates.first(where: \.isMiniaturized) {
            minimized.deminiaturize(nil)
            minimized.makeKeyAndOrderFront(nil)
        }
        else {
            openMainWindow?()
        }
    }
}
