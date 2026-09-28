import AppKit
import Foundation

/// Listen on NSWorkspace's notification center; the default center does not emit wake events.
final class ManagedTaskWakeObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    @MainActor init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        onWake: @escaping @MainActor () -> Void
    ) {
        self.center = center
        token = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in onWake() }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
