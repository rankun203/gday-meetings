import AppKit
import SwiftUI

/// Native controls keep their existing hover, focus, and pressed appearance.
final class MarkdownActionButton: NSButton {
    private var cursorTracking: NSTrackingArea?
    override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled { window?.invalidateCursorRects(for: self) }
        }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        cursorTracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
        // Scrolling changes the clipped target even when its document frame
        // stays fixed. Register the newly visible part of the button.
        window?.invalidateCursorRects(for: self)
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    override func cursorUpdate(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
}

struct MarkdownControlCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder
    func body(content: Content) -> some View {
        // SwiftUI owns the region so native button and picker tracking preserve it.
        content.pointerStyle(enabled ? .link : .default)
    }
}
