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
