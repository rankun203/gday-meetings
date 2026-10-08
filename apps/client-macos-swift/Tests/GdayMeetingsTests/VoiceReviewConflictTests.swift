import Foundation
import Testing

@testable import GdayMeetings

struct VoiceReviewConflictTests {
    private func originalConflicts(_ examples: [VoiceExample]) -> Set<UUID> {
        Set(
            examples.compactMap { example in
                guard example.review == .confirmed, !example.excluded, let range = example.range else { return nil }
                return examples.contains { other in
                    guard other.id != example.id, other.meetingID == example.meetingID,
                        other.audioRevision == example.audioRevision, other.review == .confirmed,
                        other.personID != example.personID, !other.excluded, let otherRange = other.range
                    else { return false }
                    return otherRange.audioFile == range.audioFile && otherRange.start < range.end
                        && otherRange.end > range.start
                } ? example.id : nil
            })
    }

    private func example(
        meeting: UUID, person: UUID?, start: Double, end: Double, revision: String? = "one"
    ) -> VoiceExample {
        .init(
            meetingID: meeting, speakerID: UUID(), source: "microphone", audioFile: "microphone.wav",
            audioRevision: revision, start: start, end: end, personID: person, review: .confirmed)
    }

    @Test func conflictsKeepNilDecisionsAndExactRecordingBoundaries() {
        let meeting = UUID()
        let person = UUID()
        let long = example(meeting: meeting, person: person, start: 0, end: 10, revision: nil)
        let overlap = example(meeting: meeting, person: nil, start: 1, end: 2, revision: nil)
        let samePerson = example(meeting: meeting, person: person, start: 2, end: 4, revision: nil)
        let touching = example(meeting: meeting, person: UUID(), start: 10, end: 12, revision: nil)
        let otherRevision = example(meeting: meeting, person: UUID(), start: 0, end: 10)
        let otherMeeting = example(meeting: UUID(), person: UUID(), start: 0, end: 10, revision: nil)
        var otherFile = example(meeting: meeting, person: UUID(), start: 0, end: 10, revision: nil)
        otherFile.audioFile = "system.wav"
        var excluded = example(meeting: meeting, person: UUID(), start: 0, end: 10, revision: nil)
        excluded.excluded = true
        var unconfirmed = example(meeting: meeting, person: UUID(), start: 0, end: 10, revision: nil)
        unconfirmed.review = .suggested
        var invalidRange = example(meeting: meeting, person: UUID(), start: 0, end: 10, revision: nil)
        invalidRange.audioFile = "../invalid.wav"
        let values = [
            long, overlap, samePerson, touching, otherRevision, otherMeeting, otherFile, excluded,
            unconfirmed, invalidRange,
        ]
        #expect(VoiceReviewConflicts.confirmedExampleIDs(in: values) == [long.id, overlap.id])
        #expect(VoiceReviewConflicts.confirmedExampleIDs(in: values.reversed()) == originalConflicts(values))
        var sourceMetadataChanged = overlap
        sourceMetadataChanged.source = "system"
        #expect(VoiceReviewConflicts.confirmedExampleIDs(in: [long, sourceMetadataChanged]) == [long.id, overlap.id])
    }

    @Test func sweepsMatchOriginalRuleAcrossNestedAndEqualStartRanges() {
        let meetings = (0..<3).map { _ in UUID() }
        let people: [UUID?] = [UUID(), UUID(), UUID(), nil]
        var values: [VoiceExample] = []
        for index in 0..<480 {
            let start = Double((index * 37) % 50)
            var value = example(
                meeting: meetings[index % meetings.count], person: people[(index / 3) % people.count],
                start: start, end: start + Double(1 + (index * 17) % 29),
                revision: index.isMultiple(of: 5) ? nil : "revision-\(index % 2)")
            if index.isMultiple(of: 7) { value.excluded = true }
            if index.isMultiple(of: 11) { value.review = .rejected }
            if index.isMultiple(of: 13) { value.audioFile = nil }
            if index.isMultiple(of: 17) { value.audioFile = "system.wav" }
            values.append(value)
        }
        #expect(VoiceReviewConflicts.confirmedExampleIDs(in: values) == originalConflicts(values))
        #expect(VoiceReviewConflicts.confirmedExampleIDs(in: values.reversed()) == originalConflicts(values))
    }

    @Test @MainActor func matchingUsesConfirmedPersonIndexAndUpdatesAfterReviews() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = VoiceLibraryStore(loading: .immediate, directory: directory)
        let person = Person(name: "Alex")
        let other = Person(name: "Sam")
        let meeting = UUID()
        var first = example(meeting: meeting, person: person.id, start: 0, end: 3)
        first.embeddings = [.init(type: .community1SpeechSpan, values: [1] + Array(repeating: 0, count: 255))]
        var second = example(meeting: meeting, person: other.id, start: 0, end: 3)
        second.embeddings = first.embeddings
        var suggested = example(meeting: meeting, person: nil, start: 4, end: 7)
        suggested.embeddings = first.embeddings
        suggested.suggestedPersonID = person.id
        suggested.review = .suggested
        #expect(library.upsert([first, second, suggested]))
        #expect((try await library.matchingPeople(from: [person, other])).allSatisfy { $0.voiceSamples.isEmpty })
        #expect(library.confirm(ids: [second.id], personID: person.id))
        let matched = (try await library.matchingPeople(from: [person, other]))
        #expect(Set(matched[0].voiceSamples.map(\.speakerID)) == [first.id, second.id])
        #expect(matched[1].voiceSamples.isEmpty)
        #expect(library.clear(ids: [first.id]))
        #expect((try await library.matchingPeople(from: [person]))[0].voiceSamples.map(\.speakerID) == [second.id])
    }
}
