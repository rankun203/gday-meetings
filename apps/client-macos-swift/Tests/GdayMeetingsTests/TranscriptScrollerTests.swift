import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptScrollerTests {
    @Test func nativeScrollerAcceptsBothSystemStyles() {
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let scroller = TranscriptNativeScroller()
        scroll.verticalScroller = scroller
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))
        scroll.tile()
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            scroll.tile()
            #expect(scroll.scrollerStyle == style)
            #expect(scroller.scrollerStyle == style)
            #expect(scroll.hasVerticalScroller)
        }
    }

    @Test func nativeActionStillNotifiesPlaybackFollowingBeforeAndAfterScrolling() {
        _ = NSApplication.shared
        var events: [String] = []
        let target = TranscriptScrollerActionTarget { events.append("scroll") }
        let scroller = TranscriptNativeScroller()
        scroller.userScrolled = { events.append("interaction") }
        #expect(scroller.sendAction(#selector(TranscriptScrollerActionTarget.scroll(_:)), to: target))
        #expect(events == ["interaction", "scroll", "interaction"])
    }
}

@MainActor private final class TranscriptScrollerActionTarget: NSObject {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
    @objc func scroll(_ sender: Any?) { action() }
}
