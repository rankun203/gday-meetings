import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LiveTranscriptStreamDisplayCacheTests {
    @Test func frozenHistorySurvivesRepeatedHotUpdates() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let session = UUID()
        for index in 0..<3600 {
            stream.accept(
                .init(
                    session: session, source: .system, start: Double(index * 2),
                    end: Double(index * 2) + 1.8, text: "连续的示例文字"), final: true)
        }
        let cache = LiveTranscriptStreamDisplayCache()
        cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
        let first = cache.row(at: 0)
        let frozenCount = cache.frozenCount
        #expect(frozenCount > 200)
        #expect(first.text.utf16.count < 2000)
        for update in 0..<10 {
            stream.accept(
                .init(
                    session: session, source: .system, start: 7200,
                    end: 7201, text: "Current words \(update)"), final: false)
            cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
            #expect(cache.row(at: 0) == first)
            #expect(cache.frozenCount >= frozenCount)
            #expect(cache.rebuiltParagraphCount < 25)
            #expect(cache.count - cache.frozenCount < 25)
        }
    }

    @Test func streamResetReplacesHistoryAndNamesRefreshExplicitly() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let session = UUID()
        let phrase = LiveTranscriptPhrase(
            session: session, source: .system, start: 0, end: 1, text: "Sample words.")
        stream.accept(phrase, final: true)
        stream.finish()
        let cache = LiveTranscriptStreamDisplayCache()
        cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
        #expect(cache.count == 1)
        #expect(cache.phrase(id: phrase.id)?.text == phrase.text)
        let reset = cache.resetRevision
        stream.reset(labeling: false)
        cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
        #expect(cache.count == 0)
        #expect(cache.resetRevision > reset)
        #expect(cache.phrase(id: phrase.id) == nil)
    }

    @Test func suffixDiffUsesAbsoluteIndexes() {
        let id = UUID()
        let previous = [
            TranscriptDisplayRow(id: id, start: 1, end: 2, speaker: "sys_01", speakerID: nil, text: "First")
        ]
        let current = [
            TranscriptDisplayRow(id: id, start: 1, end: 2, speaker: "sys_01", speakerID: nil, text: "Updated")
        ]
        let update = TranscriptRowUpdate(previous: previous, current: current, offset: 10000)
        #expect(update.changed == IndexSet(integer: 10000))
        #expect(update.inserted.isEmpty)
        #expect(update.removed.isEmpty)
    }
}
