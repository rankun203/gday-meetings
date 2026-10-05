import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct PlaybackSpaceRoutingTests {
    @Test func focusedNativeControlsKeepTheirActivationKey() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = NSButton(title: "Run Task", target: nil, action: nil)
        window.contentView = button
        #expect(window.makeFirstResponder(button))
        #expect(PlaybackSpaceKey.KeyView.preservesFocusedSpace(window.firstResponder, accessibilityElement: button))
        let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
        #expect(PlaybackSpaceKey.KeyView.preservesFocusedSpace(slider, accessibilityElement: slider))
        let menu = NSPopUpButton(frame: .zero, pullsDown: false)
        menu.addItem(withTitle: "Provider")
        #expect(PlaybackSpaceKey.KeyView.preservesFocusedSpace(menu, accessibilityElement: menu))
    }

    @Test func hostedAccessibilityControlsKeepSpaceWhileReadingSurfacesAllowPlayback() {
        let hostingResponder = NSView()
        for role in [NSAccessibility.Role.button, .checkBox, .popUpButton, .slider, .radioButton] {
            let focused = NSAccessibilityElement()
            focused.setAccessibilityRole(role)
            #expect(PlaybackSpaceKey.KeyView.preservesFocusedSpace(hostingResponder, accessibilityElement: focused))
        }
        let table = NSTableView()
        #expect(!PlaybackSpaceKey.KeyView.preservesFocusedSpace(table, accessibilityElement: table))
        let readingSurface = NSView()
        readingSurface.setAccessibilityRole(.group)
        #expect(!PlaybackSpaceKey.KeyView.preservesFocusedSpace(readingSurface, accessibilityElement: readingSurface))
        let editor = NSTextView()
        editor.isEditable = true
        #expect(PlaybackSpaceKey.KeyView.preservesFocusedSpace(editor, accessibilityElement: editor))
    }
}
