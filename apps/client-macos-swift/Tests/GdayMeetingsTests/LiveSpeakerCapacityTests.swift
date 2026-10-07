import Foundation
import Testing

@testable import GdayMeetings

struct LiveSpeakerCapacityTests {
    private func establish(_ slots: Range<Int>, in capacity: inout LiveSpeakerCapacity, start: Double = 0) -> Double {
        var time = start
        for slot in slots {
            for _ in 0..<300 {
                var activity = [Bool](repeating: false, count: 8)
                activity[slot] = true
                capacity.accept(activity, time: time)
                time += 0.01
            }
        }
        return time
    }

    @Test func countsSustainedSpeechInsteadOfAllocatedIdentities() {
        var capacity = LiveSpeakerCapacity()
        capacity.accept([Bool](repeating: true, count: 8), time: 0)
        capacity.accept([Bool](repeating: false, count: 8), time: 0.01)
        #expect(capacity.established.isEmpty)
        let time = establish(0..<7, in: &capacity)
        #expect(capacity.established.count == 7)
        let rollover1 = capacity.shouldRollover(at: time + 100)
        #expect(!rollover1)
        let full = establish(7..<8, in: &capacity, start: time)
        #expect(capacity.established.count == 8)
        let rollover2 = capacity.shouldRollover(at: full)
        #expect(!rollover2)
        let rollover3 = capacity.shouldRollover(at: full + 5)
        #expect(rollover3)
    }

    @Test func silenceBoundaryAndIndependentSources() {
        var microphone = LiveSpeakerCapacity()
        var system = LiveSpeakerCapacity()
        let time = establish(0..<8, in: &microphone)
        _ = establish(0..<2, in: &system)
        for frame in 0..<30 {
            microphone.accept([Bool](repeating: false, count: 8), time: time + Double(frame) * 0.01)
        }
        let rollover4 = microphone.shouldRollover(at: time + 0.3)
        #expect(rollover4)
        let rollover5 = system.shouldRollover(at: time + 0.3)
        #expect(!rollover5)
        #expect(microphone.established.count == 8)
        microphone = LiveSpeakerCapacity()  // A source gap retires its namespace and evidence counter.
        #expect(microphone.established.isEmpty)
        #expect(system.established.count == 2)
    }

    @Test func saturatedReplayRequiresChangedRecentPopulation() {
        var capacity = LiveSpeakerCapacity()
        var time = establish(0..<8, in: &capacity)
        capacity.finishBootstrap(at: time)
        #expect(capacity.saturatedBootstrap)
        for _ in 0..<10 {
            time = establish(0..<8, in: &capacity, start: time)
            let rollover6 = capacity.shouldRollover(at: time)
            #expect(!rollover6)
        }
        // One channel leaves the recent horizon; a retry can now restore headroom.
        for _ in 0..<3 { time = establish(1..<8, in: &capacity, start: time) }
        _ = capacity.shouldRollover(at: time)
        let rollover7 = capacity.shouldRollover(at: time + 5)
        #expect(rollover7)
    }

    @Test func replayPublicationClipsCrossingSpeechAndDropsEarlierOutput() throws {
        let id = UUID()
        let generation = UUID()
        let event = LiveSpeakerEvent(
            source: .microphone, generation: generation, sequence: 1,
            speakers: [],
            intervals: [
                .init(speakerID: id, start: 1, end: 2),
                .init(speakerID: id, start: 3, end: 5),
                .init(speakerID: id, start: 6, end: 7),
            ], start: 1, end: 7)
        let clipped = try #require(LocalLiveDiarization.publication(event, from: 4))
        #expect(clipped.start == 4)
        #expect(clipped.end == 7)
        #expect(
            clipped.intervals == [
                .init(speakerID: id, start: 4, end: 5), .init(speakerID: id, start: 6, end: 7),
            ])
        #expect(LocalLiveDiarization.publication(event, from: 7) == nil)
    }

    @Test func fractionalSourceClockKeepsOneHandoffAcrossReplayedFrames() throws {
        let origin = 12.345_678
        let received = 987_654
        let handoff = origin + Double(received) / 16_000
        let retained = 45 * 16_000
        let replayOrigin = handoff - Double(retained) / 16_000
        let frameBefore = Int((handoff - replayOrigin) / 0.01) - 1
        let id = UUID()
        let crossing = LiveSpeakerEvent(
            source: .system, generation: UUID(), sequence: 1,
            speakers: [],
            intervals: [
                .init(
                    speakerID: id,
                    start: replayOrigin + Double(frameBefore) * 0.01,
                    end: replayOrigin + Double(frameBefore + 3) * 0.01)
            ],
            start: replayOrigin + Double(frameBefore) * 0.01,
            end: replayOrigin + Double(frameBefore + 3) * 0.01)
        let result = try #require(LocalLiveDiarization.publication(crossing, from: handoff))
        #expect(result.start == handoff)
        #expect(result.intervals.first?.start == handoff)
        #expect(result.end > handoff)
        #expect(abs(replayOrigin + Double(retained) / 16_000 - handoff) < 0.000_000_001)
    }

    @Test func handoffRetiresOldLabelsWithoutTransferringNames() {
        let generation = UUID()
        let next = UUID()
        let person = UUID()
        let old = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: generation, slot: 0,
            model: "synthetic", revision: "1", personID: person)
        let new = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: next, slot: 0,
            model: "synthetic", revision: "1")
        var timeline = LiveSpeakerTimeline()
        let accepted1 = timeline.accept(
            .init(
                source: .microphone, generation: generation, sequence: 0,
                speakers: [old], intervals: [], start: 0, end: 0))
        #expect(accepted1)
        let accepted2 = timeline.accept(
            .init(
                source: .microphone, generation: generation, sequence: 1,
                speakers: [old], intervals: [.init(speakerID: old.id, start: 0, end: 10)], start: 0, end: 10,
                final: true))
        #expect(accepted2)
        let accepted3 = timeline.accept(
            .init(
                source: .microphone, generation: next, sequence: 0,
                speakers: [new], intervals: [], start: 9, end: 9))
        #expect(!accepted3)
        let accepted4 = timeline.accept(
            .init(
                source: .microphone, generation: next, sequence: 0,
                speakers: [new], intervals: [], start: 10, end: 10))
        #expect(accepted4)
        let accepted5 = timeline.accept(
            .init(
                source: .microphone, generation: next, sequence: 1,
                speakers: [new], intervals: [.init(speakerID: new.id, start: 10, end: 12)], start: 10, end: 12))
        #expect(accepted5)
        #expect(timeline.speakers.first { $0.id == old.id }?.personID == person)
        #expect(timeline.speakers.first { $0.id == new.id }?.personID == nil)
        #expect(timeline.intervals.map(\.start) == [0, 10])
    }
    @Test func eighthEstablishedTimestampSurvivesBootstrapAndResetStartsFresh() {
        var capacity = LiveSpeakerCapacity()
        let end = establish(0..<8, in: &capacity)
        let first = capacity.firstReachedCapacityAt
        #expect(first != nil)
        #expect(abs((first ?? 0) - (end - 0.01)) < 1e-9)
        capacity.finishBootstrap(at: end)
        #expect(capacity.firstReachedCapacityAt == first)
        _ = establish(0..<8, in: &capacity, start: end)
        #expect(capacity.firstReachedCapacityAt == first)
        capacity = LiveSpeakerCapacity()
        #expect(capacity.firstReachedCapacityAt == nil)
    }

}
