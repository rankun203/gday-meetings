import AppKit
import SwiftUI

private struct DirectoryControlFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var directoryControlFocus: Bool? {
        get { self[DirectoryControlFocusKey.self] }
        set { self[DirectoryControlFocusKey.self] = newValue }
    }
}

/// Window-local transport shortcut. Editable controls must retain ordinary spaces.
struct PlaybackSpaceKey: NSViewRepresentable {
    let playback: MeetingPlayback
    @FocusedValue(\.directoryControlFocus) private var directoryControlFocus

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {
        view.playback = playback
        view.controlHasFocus = directoryControlFocus == true
    }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stopMonitoring() }

    final class KeyView: NSView {
        weak var playback: MeetingPlayback?
        var controlHasFocus = false
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                    event.window === window, window.isKeyWindow,
                    window.attachedSheet == nil,
                    !self.controlHasFocus,
                    event.charactersIgnoringModifiers == " ",
                    event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                    !Self.isEditingText(window.firstResponder),
                    let playback = self.playback, playback.hasSelection,
                    !playback.isLoading, !playback.isPlaybackBlocked
                else { return event }
                if !event.isARepeat { playback.togglePlayPause() }
                return nil
            }
        }

        static func isEditingText(_ responder: NSResponder?) -> Bool {
            if let text = responder as? NSTextView { return text.isEditable || text is MarkdownReadingTextView }
            if let field = responder as? NSTextField { return field.isEditable }
            return false
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
