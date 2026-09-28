import AppKit
import SwiftUI

/// Window-local transport shortcut. Editable controls must retain ordinary spaces.
struct PlaybackSpaceKey: NSViewRepresentable {
    let playback: MeetingPlayback

    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.playback = playback }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stopMonitoring() }

    final class KeyView: NSView {
        weak var playback: MeetingPlayback?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window,
                    event.window === window, window.isKeyWindow,
                    window.attachedSheet == nil,
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
