import AppKit
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptScrollerTests {
    @Test func nativeScrollerAcceptsBothSystemStyles() throws {
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))
        scroll.tile()
        let scroller = try #require(scroll.verticalScroller)
        #expect(scroll.scrollerStyle == NSScroller.preferredScrollerStyle)
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            scroll.tile()
            #expect(scroll.scrollerStyle == style)
            #expect(scroller.scrollerStyle == style)
            #expect(scroll.hasVerticalScroller)
            #expect(scroller.bounds.contains(scroller.rect(for: .knob)))
        }
    }

    @Test func nativeScrollNotificationsPauseFollowingAndBracketTracking() {
        let scroll = TranscriptNativeScrollView()
        var events: [String] = []
        scroll.willScroll = { events.append("interaction") }
        scroll.trackingChanged = { events.append($0 ? "start" : "end") }
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        #expect(events == ["start", "interaction", "interaction", "interaction", "end"])
    }

    @Test func otherScrollViewsAndProgrammaticScrollingDoNotPauseFollowing() {
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 1_000))
        var interactions = 0
        scroll.willScroll = { interactions += 1 }
        scroll.trackingChanged = { _ in interactions += 1 }
        let other = NSScrollView()
        for name in [
            NSScrollView.willStartLiveScrollNotification, NSScrollView.didLiveScrollNotification,
            NSScrollView.didEndLiveScrollNotification,
        ] {
            NotificationCenter.default.post(name: name, object: other)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(interactions == 0)
    }
}
