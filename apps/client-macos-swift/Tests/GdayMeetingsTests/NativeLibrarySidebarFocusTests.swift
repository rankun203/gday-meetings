import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct NativeLibrarySidebarFocusTests {
    @Test func programmaticMountAndMismatchedRequestDoNotStealFocus() async {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: window.contentView!.bounds)
        window.contentView = container
        let field = NSTextField(frame: NSRect(x: 0, y: 260, width: 200, height: 24))
        container.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let responder = window.firstResponder
        let request = LibrarySidebarFocusRequest()
        func mount(_ destination: LibraryDestination) -> LibrarySidebarTable {
            let table = LibrarySidebarTable(frame: NSRect(x: 0, y: 0, width: 200, height: 240))
            table.destination = destination
            table.focusRequest = request
            container.addSubview(table)
            return table
        }
        let first = mount(.meetings)
        await drainFocusTransfer()
        #expect(window.firstResponder === responder)
        first.removeFromSuperview()
        request.request(.tasks, origin: first.instanceID)
        request.cancelIfDestinationChanged(to: .people)
        let unrelated = mount(.people)
        await drainFocusTransfer()
        #expect(window.firstResponder === responder)
        unrelated.removeFromSuperview()
        let later = mount(.tasks)
        await drainFocusTransfer()
        #expect(window.firstResponder === responder)
        later.removeFromSuperview()
    }

    private func drainFocusTransfer() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func matchingReplacementConsumesFocusOnlyOnce() {
        let request = LibrarySidebarFocusRequest()
        let origin = UUID()
        request.request(.tasks, origin: origin)
        request.cancelIfDestinationChanged(to: .meetings, instance: origin)
        #expect(request.matches(.tasks, instance: UUID()))
        #expect(!request.consume(for: .tasks, instance: origin))
        #expect(request.consume(for: .tasks, instance: UUID()))
        #expect(!request.consume(for: .tasks, instance: UUID()))
        request.request(.tasks, origin: origin)
        request.cancelIfDestinationChanged(to: .meetings)
        #expect(!request.consume(for: .tasks, instance: UUID()))
    }

    @Test func currentNavigationCancelsTransferBeforeLaterProgrammaticMount() {
        let request = LibrarySidebarFocusRequest()
        let origin = UUID()
        request.request(.tasks, origin: origin)
        // An outgoing column's stale value is not authoritative.
        request.cancelIfDestinationChanged(to: .meetings, instance: origin)
        #expect(request.matches(.tasks, instance: UUID()))
        // Current navigation changes before a replacement is mounted.
        request.cancelIfDestinationChanged(to: .people)
        #expect(!request.consume(for: .tasks, instance: UUID()))

        request.request(.tasks, origin: origin)
        request.cancelIfDestinationChanged(to: nil)  // Search clears sidebar selection.
        #expect(!request.consume(for: .tasks, instance: UUID()))
    }
}
