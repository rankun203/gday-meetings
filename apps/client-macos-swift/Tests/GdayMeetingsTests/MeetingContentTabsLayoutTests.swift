import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct MeetingContentTabsLayoutTests {
    @MainActor private final class Selection: ObservableObject {
        @Published var value = 0
    }

    private struct Harness: View {
        @ObservedObject var selection: Selection
        var body: some View {
            Text("Synthetic page \(selection.value + 1)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        MeetingContentTabs(selection: $selection.value)
                    }
                }
        }
    }

    @Test func nativeToolbarTabsFitAndUpdateSelection() async throws {
        _ = NSApplication.shared
        let selection = Selection()
        let controller = NSHostingController(rootView: Harness(selection: selection))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 900, height: 500))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }

        func segmentedControl(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl { return control }
            return view.subviews.lazy.compactMap { segmentedControl(in: $0) }.first
        }
        func toolbarControl() -> NSSegmentedControl? {
            window.toolbar?.items.compactMap(\.view).lazy.compactMap { segmentedControl(in: $0) }.first
        }
        let mounted = try await waitForMainActorTestCondition {
            controller.view.layoutSubtreeIfNeeded()
            return toolbarControl()?.segmentCount == 3
        }
        #expect(mounted)
        let control = try #require(toolbarControl())
        #expect((0..<3).map { control.label(forSegment: $0) } == ["Transcript", "Notes", "Summary"])
        #expect(control.frame.width >= control.fittingSize.width)
        #expect(control.frame.width <= window.contentLayoutRect.width)
        for index in 0..<3 {
            control.selectedSegment = index
            #expect(control.sendAction(control.action, to: control.target))
            let selected = try await waitForMainActorTestCondition { selection.value == index }
            #expect(selected)
        }
        selection.value = 1
        let restored = try await waitForMainActorTestCondition {
            controller.view.layoutSubtreeIfNeeded()
            return control.selectedSegment == 1
        }
        #expect(restored)
    }
}
