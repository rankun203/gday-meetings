import Foundation
import Testing

@testable import GdayMeetings

struct TranscriptMeasurementViewportTests {
    @Test func visibleRowsPrecedeMarginsInEitherDirection() {
        let visible = NSRange(location: 10, length: 3)
        let nearby = NSRange(location: 7, length: 9)
        let forward = TranscriptMeasurementViewport.order(
            visible: visible, nearby: nearby, rowCount: 30, forward: true)
        let backward = TranscriptMeasurementViewport.order(
            visible: visible, nearby: nearby, rowCount: 30, forward: false)
        #expect(forward == [10, 11, 12, 13, 14, 15, 9, 8, 7])
        #expect(backward == [10, 11, 12, 9, 8, 7, 13, 14, 15])
    }

    @Test func queueLimitPreservesVisibleRowsAndNearestDirectionalRows() {
        let visible = NSRange(location: 100, length: 3)
        let nearby = NSRange(location: 0, length: 1_000)
        let forward = TranscriptMeasurementViewport.order(
            visible: visible, nearby: nearby, rowCount: 10_000, forward: true, limit: 5)
        let backward = TranscriptMeasurementViewport.order(
            visible: visible, nearby: nearby, rowCount: 10_000, forward: false, limit: 5)
        #expect(forward == [100, 101, 102, 103, 104])
        #expect(backward == [100, 101, 102, 99, 98])
        let bounded = TranscriptMeasurementViewport.order(
            visible: visible, nearby: nearby, rowCount: 10_000, forward: true)
        #expect(bounded.count == 128)
        #expect(Set(bounded).count == bounded.count)
    }

    @Test func transcriptEdgesDoNotProduceInvalidOrDuplicateRows() {
        let first = TranscriptMeasurementViewport.order(
            visible: NSRange(location: 0, length: 3), nearby: NSRange(location: 0, length: 8),
            rowCount: 5, forward: false)
        let last = TranscriptMeasurementViewport.order(
            visible: NSRange(location: 3, length: 5), nearby: NSRange(location: 0, length: 10),
            rowCount: 5, forward: true)
        #expect(first == [0, 1, 2, 3, 4])
        #expect(last == [3, 4, 2, 1, 0])
    }

    @Test func largeViewportStillHonorsWorkLimit() {
        let order = TranscriptMeasurementViewport.order(
            visible: NSRange(location: 200, length: 1_000), nearby: NSRange(location: 0, length: 5_000),
            rowCount: 10_000, forward: true)
        #expect(order == Array(200..<328))
    }

    @Test func emptyTranscriptHasNoMeasurementWork() {
        let order = TranscriptMeasurementViewport.order(
            visible: NSRange(location: NSNotFound, length: 0), nearby: NSRange(location: NSNotFound, length: 0),
            rowCount: 0, forward: true)
        #expect(order.isEmpty)
    }

    @Test func missingViewportOrZeroBudgetHasNoWorkAndMissingMarginKeepsVisibleRows() {
        let missing = NSRange(location: NSNotFound, length: 0)
        let visible = NSRange(location: 10, length: 3)
        #expect(
            TranscriptMeasurementViewport.order(
                visible: missing, nearby: visible, rowCount: 100, forward: true
            ).isEmpty)
        #expect(
            TranscriptMeasurementViewport.order(
                visible: visible, nearby: visible, rowCount: 100, forward: true, limit: 0
            ).isEmpty)
        #expect(
            TranscriptMeasurementViewport.order(
                visible: visible, nearby: missing, rowCount: 100, forward: true) == [10, 11, 12])
    }
}
