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
                    !Self.preservesFocusedSpace(
                        window.firstResponder, accessibilityElement: NSApp.accessibilityFocusedUIElement),
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

        /// SwiftUI controls can share a hosting view as their AppKit responder.
        /// Consult the focused accessibility element as well as native controls,
        /// without taking Space away from tables and ordinary reading surfaces.
        static func preservesFocusedSpace(_ responder: NSResponder?, accessibilityElement: Any?) -> Bool {
            if isEditingText(responder) { return true }
            if responder is NSControl && !(responder is NSTableView) && !(responder is NSTextField) { return true }
            guard let element = accessibilityElement as? NSAccessibilityProtocol,
                let role = element.accessibilityRole()
            else { return false }
            return [
                NSAccessibility.Role.button, .checkBox, .radioButton, .popUpButton, .menuButton,
                .slider, .comboBox, .incrementor, .disclosureTriangle, .tabGroup, .link, .textField, .textArea,
            ].contains(role)
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
