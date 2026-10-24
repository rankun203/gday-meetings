import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor private struct DockProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor private struct DockHarness: View {
    let showsStatus: Bool
    let statusHeight: CGFloat
    let hasTransport: Bool
    let status: NSView
    let transport: NSView

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(maxHeight: .infinity)
            LibraryBottomDock(showsStatus: showsStatus) {
                DockProbe(view: status).frame(height: statusHeight)
            } transport: {
                if hasTransport { DockProbe(view: transport).frame(height: 80) }
            }
        }
        .transaction { $0.disablesAnimations = true }
    }
}

@MainActor struct LibraryBottomDockTests {
    @Test func statusChangesLeaveTransportAtTheBottom() async throws {
        _ = NSApplication.shared
        let status = NSView()
        let transport = NSView()
        func root(_ visible: Bool, height: CGFloat = 36, hasTransport: Bool = true) -> DockHarness {
            DockHarness(
                showsStatus: visible, statusHeight: height, hasTransport: hasTransport,
                status: status, transport: transport)
        }
        let host = NSHostingView(rootView: root(false))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() async throws {
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(20))
                host.layoutSubtreeIfNeeded()
            }
        }
        func top(_ view: NSView) -> CGFloat {
            let frame = view.convert(view.bounds, to: host)
            return host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
        }
        try await settle()
        let transportTop = top(transport)
        #expect(abs(transportTop - (host.bounds.height - 80)) < 1)
        // Exercise insertion, a taller attention state, and dismissal in one host.
        // The transport must retain its position rather than follow the task row.
        for (visible, height) in [(true, CGFloat(36)), (true, CGFloat(44)), (false, CGFloat(36))] {
            host.rootView = root(visible, height: height)
            try await settle()
            #expect(abs(top(transport) - transportTop) < 1)
            if visible { #expect(abs(top(status) + height - top(transport)) < 1) }
        }
        // Without a player/recording strip, tasks still occupy the bottom edge.
        host.rootView = root(true, hasTransport: false)
        try await settle()
        #expect(abs(top(status) + 36 - host.bounds.height) < 1)
    }
}
