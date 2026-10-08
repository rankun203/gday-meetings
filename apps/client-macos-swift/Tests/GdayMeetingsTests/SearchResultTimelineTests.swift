import AppKit
import Foundation
import Testing

@testable import GdayMeetings

struct SearchResultTimelineTests {
    @Test func rangeUsesRecordingDurationAndClampsEnd() throws {
        let range = try #require(SearchResultTimeline(duration: 60, start: 15, end: 90))
        #expect(range.startFraction == 0.25)
        #expect(range.endFraction == 1)
        #expect(range.end == 60)
    }

    @Test func invalidRangesHaveNoTimeline() {
        #expect(SearchResultTimeline(duration: 0, start: 0, end: 1) == nil)
        #expect(SearchResultTimeline(duration: 60, start: 20, end: 10) == nil)
        #expect(SearchResultTimeline(duration: 60, start: 60, end: 61) == nil)
        #expect(SearchResultTimeline(duration: .infinity, start: 0, end: 1) == nil)
        #expect(SearchResultTimeline(duration: 60, start: .nan, end: 1) == nil)
    }

    @Test func titleMatchPlaysFromZeroAndCoversRecording() throws {
        let passage = LibrarySearchResult(
            id: 1, meetingID: UUID(), title: "Planning", createdAt: Date(),
            kind: .title, segmentID: nil, start: nil, excerpt: "Planning")
        let result = SearchDisplayResult(
            id: "1", meetingID: passage.meetingID, title: passage.title,
            excerpt: passage.excerpt, createdAt: passage.createdAt, passage: passage, audio: nil)
        #expect(result.playbackStart == 0)
        let range = try #require(result.timeline(duration: 60))
        #expect(range.startFraction == 0)
        #expect(range.endFraction == 1)
    }

    @Test func missingTranscriptEndDoesNotInventDuration() {
        let passage = LibrarySearchResult(
            id: 2, meetingID: UUID(), title: "Planning", createdAt: Date(),
            kind: .transcript, segmentID: UUID(), start: 12, excerpt: "A synthetic passage")
        let result = SearchDisplayResult(
            id: "2", meetingID: passage.meetingID, title: passage.title,
            excerpt: passage.excerpt, createdAt: passage.createdAt, passage: passage, audio: nil)
        #expect(result.timeline(duration: 60) == nil)
        #expect(result.playbackStart == 12)
    }
}

extension SearchResultTimelineTests {
    @Test func semanticWindowUsesFullEndpointInsteadOfFirstSegment() throws {
        let id = UUID()
        let passage = LibrarySearchResult(
            id: 3, meetingID: UUID(), title: "Planning", createdAt: Date(),
            kind: .transcript, segmentID: id, start: 10, excerpt: "Two synthetic passages", end: 35)
        let result = SearchDisplayResult(
            id: "3", meetingID: passage.meetingID, title: passage.title,
            excerpt: passage.excerpt, createdAt: passage.createdAt, passage: passage, audio: nil)
        let range = try #require(result.timeline(duration: 60))
        #expect(range.start == 10)
        #expect(range.end == 35)
    }

    @Test func audioMatchUsesProviderDuration() throws {
        let result = SearchDisplayResult(
            id: "4", meetingID: UUID(), title: "Planning", excerpt: "Synthetic audio",
            createdAt: nil, passage: nil, audio: .init(filename: "audio.wav", start: 20, duration: 8))
        let range = try #require(result.timeline(duration: 60))
        #expect(range.start == 20)
        #expect(range.end == 28)
    }
}

extension SearchResultTimelineTests {
    @Test func textMatchUsesSavedSegmentEndpoint() throws {
        let id = UUID()
        let passage = LibrarySearchResult(
            id: 5, meetingID: UUID(), title: "Planning", createdAt: Date(),
            kind: .transcript, segmentID: id, start: 12, excerpt: "A synthetic passage", end: 18)
        let result = SearchDisplayResult(
            id: "5", meetingID: passage.meetingID, title: passage.title,
            excerpt: passage.excerpt, createdAt: passage.createdAt, passage: passage, audio: nil)
        let range = try #require(result.timeline(duration: 60))
        #expect(range.start == 12)
        #expect(range.end == 18)
    }
}

@MainActor struct SearchTimelineRenderingTests {
    @Test func groupedMarkersKeepShortPassagesClickableWhenTitleIsSelected() throws {
        let meeting = UUID()
        let passage = LibrarySearchResult(
            id: 1, meetingID: meeting, title: "Planning", createdAt: Date(),
            kind: .title, segmentID: nil, start: nil, excerpt: "Planning")
        let title = SearchDisplayResult(
            id: "title", meetingID: meeting, title: "Planning", excerpt: "Planning",
            createdAt: nil, passage: passage, audio: nil)
        let short = SearchDisplayResult(
            id: "short", meetingID: meeting, title: "Planning", excerpt: "Confirm the next step.",
            createdAt: nil, passage: nil, audio: .init(filename: "audio.wav", start: 20, duration: 1))
        let untimed = SearchDisplayResult(
            id: "untimed", meetingID: meeting, title: "Planning", excerpt: "A note without timing.",
            createdAt: nil, passage: nil, audio: nil)
        let view = SearchTimelineView(frame: .init(x: 0, y: 0, width: 400, height: 28))
        let window = host(view)
        defer { window.close() }
        let matches = [title, short, untimed]
        let timelines = Dictionary(
            uniqueKeysWithValues: matches.compactMap { match in
                match.timeline(duration: 60).map { (match.id, $0) }
            })
        var chosen: String?
        view.selectMatch = { chosen = $0 }
        view.configure(matches: matches, selected: title, timelines: timelines)
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons.filter { $0.state == .on }.count == 1)
        try #require(buttons.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        let point = view.convert(NSPoint(x: 400 * 20.5 / 60, y: 22), to: view.superview)
        let hit = try #require(view.hitTest(point) as? NSButton)
        #expect(hit.state == .off)
        #expect(hit.toolTip?.contains("Confirm the next step.") == true)
        hit.performClick(nil)
        #expect(chosen == short.id)

        view.configure(matches: matches, selected: short, timelines: timelines)
        let refreshed = view.subviews.compactMap { $0 as? NSButton }
        #expect(refreshed.count == 2)
        #expect(refreshed.filter { $0.state == .on }.count == 1)
        #expect(refreshed.last?.state == .on)
    }

    @Test func overlappingMarkersRetainSeparateAccessibleActions() throws {
        let meeting = UUID()
        let matches = ["first", "second"].map { id in
            SearchDisplayResult(
                id: id, meetingID: meeting, title: "Planning", excerpt: "A matching passage.",
                createdAt: nil, passage: nil, audio: .init(filename: "audio.wav", start: 12, duration: 8))
        }
        let view = SearchTimelineView(frame: .init(x: 0, y: 0, width: 400, height: 28))
        let window = host(view)
        defer { window.close() }
        let timelines = Dictionary(
            uniqueKeysWithValues: matches.compactMap { match in
                match.timeline(duration: 60).map { (match.id, $0) }
            })
        var chosen: [String] = []
        view.selectMatch = { chosen.append($0) }
        view.configure(matches: matches, selected: matches[0], timelines: timelines)
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons = view.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons.last?.state == .on)
        for button in buttons {
            #expect(button.accessibilityLabel()?.contains("0:12") == true)
            button.performClick(nil)
        }
        #expect(Set(chosen) == Set(["first", "second"]))
    }

    private func host(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        return window
    }

    @Test func unchangedStaticRangeDoesNotInvalidateDrawing() throws {
        let view = InvalidationTrackingTimelineView(frame: .init(x: 0, y: 0, width: 400, height: 28))
        let range = try #require(SearchResultTimeline(duration: 60, start: 12, end: 18))
        view.configure(range, start: 12)
        view.invalidationRequests = 0
        for _ in 0..<100 {
            view.configure(range, start: 12)
            view.emphasized = false
        }
        #expect(view.invalidationRequests == 0)
        view.emphasized = true
        #expect(view.invalidationRequests > 0)
        view.invalidationRequests = 0
        view.emphasized = true
        #expect(view.invalidationRequests == 0)
        view.configure(SearchResultTimeline(duration: 60, start: 20, end: 25), start: 20)
        #expect(view.invalidationRequests > 0)
    }
}

/// Observe requests instead of AppKit's asynchronously managed dirty-region state.
@MainActor private final class InvalidationTrackingTimelineView: SearchTimelineView {
    var invalidationRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { invalidationRequests += 1 }
            super.needsDisplay = newValue
        }
    }
}
