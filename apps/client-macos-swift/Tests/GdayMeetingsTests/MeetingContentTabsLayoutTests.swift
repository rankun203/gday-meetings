import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct MeetingContentTabsLayoutTests {
    @Test func tabsFitMinimumDetailWidth() throws {
        let host = NSHostingView(rootView: MeetingContentTabs(selection: .constant(0)))
        let size = host.fittingSize
        // A 360-point detail column leaves 320 points inside its content insets.
        #expect(size.width <= 360 - 2 * AppTheme.contentInset)
        #expect(size.height <= 40)
        #expect(size.width > 0 && size.height > 0)
        host.frame.size = size
        host.layoutSubtreeIfNeeded()
        guard let destination = ProcessInfo.processInfo.environment["GDAY_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let data = try #require(image.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("meeting-content-tabs-component.png"))
    }
}
