import Foundation
import Testing

@testable import GdayMeetings

struct VoiceReviewPresentationTests {
    private func sample(personID: UUID? = nil) -> VoiceExample {
        VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "synthetic", start: 1, end: 4, personID: personID)
    }

    @Test func preparationDependenciesIgnoreUnrelatedEvidenceAndModelUpdates() {
        let example = sample()
        let dependencies = VoiceReviewPresentationEvidence(examples: [example])
        var prepared = example
        prepared.embeddings = [.init(type: .unknownLegacy(dimension: 2), values: [1, 0])]
        var unrelated = sample()
        unrelated.excluded = true
        #expect(dependencies.matches([prepared, unrelated]))
        var changed = prepared
        changed.namedPersonID = UUID()
        #expect(!dependencies.matches([changed, unrelated]))
        changed = prepared
        changed.audioRevision = "replacement"
        #expect(!dependencies.matches([changed, unrelated]))
        #expect(!dependencies.matches([unrelated]))
    }

    @Test func preparationDependenciesIncludeNewExactAliasDecisions() {
        let example = sample()
        let dependencies = VoiceReviewPresentationEvidence(examples: [example])
        var alias = example
        alias.id = UUID()
        #expect(dependencies.matches([example, alias]))
        alias.manuallyCleared = true
        #expect(!dependencies.matches([example, alias]))
    }

    @Test func refreshedDisplayRetainsDecidedRowsAndExcludesTheirReferenceAliases() async {
        let person = UUID()
        var confirmed = sample()
        var session = VoiceMatchReviewSession(examples: [confirmed], personID: person)
        session.record(.confirmed(person), for: confirmed.id, undoID: UUID())
        confirmed.personID = person
        confirmed.review = .confirmed
        var alias = confirmed
        alias.id = UUID()
        session.refreshQueue([], currentEvidence: [confirmed, alias])
        let meeting = Meeting(id: confirmed.meetingID, title: "Sample Recording")
        let display = await VoiceReviewPresentation.prepare(
            .init(
                candidates: session.examples, referenceEvidence: [alias, confirmed], personID: person,
                meetings: [meeting.id: MeetingListEntry(meeting)], libraryDirectory: URL(fileURLWithPath: "/dev/null")))
        #expect(session.examples.map(\.id) == [confirmed.id])
        #expect(session.decidedCount == 1)
        #expect(display.references.isEmpty)
        #expect(display.rows[confirmed.id]?.title == "Sample Recording")
        #expect(display.rows[confirmed.id]?.metadata.isEmpty == false)
    }

    @Test func completedUnnamedQueueKeepsItsDisplayAfterRefreshingEmptyCandidates() async {
        let example = sample()
        var session = VoiceMatchReviewSession(examples: [example])
        session.record(.ignored, for: example.id, undoID: UUID())
        session.refreshQueue([], currentEvidence: [example])
        let display = await VoiceReviewPresentation.prepare(
            .init(
                candidates: session.examples, referenceEvidence: [], personID: nil,
                meetings: [:], libraryDirectory: URL(fileURLWithPath: "/dev/null")))
        #expect(session.examples.map(\.id) == [example.id])
        #expect(display.rows[example.id]?.metadata == "00:01–00:04 · 3s")
        #expect(session.decidedCount == 1)
    }

    @Test func preparationPreservesCandidateOrderAndRemovesExactReferences() async {
        let person = UUID()
        let first = sample()
        let second = sample()
        var alias = first
        alias.id = UUID()
        alias.personID = person
        alias.review = .confirmed
        var confirmed = sample(personID: person)
        confirmed.review = .confirmed
        let input = VoiceReviewPresentation.Input(
            candidates: [second, first], referenceEvidence: [alias, confirmed], personID: person,
            meetings: [:], libraryDirectory: URL(fileURLWithPath: "/dev/null"))
        let result = await VoiceReviewPresentation.prepare(input)
        #expect(input.candidates.map(\.id) == [second.id, first.id])
        #expect(result.references.map(\.id) == [confirmed.id])
        #expect(result.rows[first.id]?.title == "Saved Recording")
        #expect(result.rows[first.id]?.metadata == "00:01–00:04 · 3s")
        #expect(result.rows[confirmed.id]?.referenceStatus == "Confirmed")
        #expect(result.playableCandidateIDs.isEmpty)
        #expect(result.rows[confirmed.id]?.audioAvailable == false)
    }

    @Test func rapidSelectionAndReturningToSameSampleRejectStaleChecks() throws {
        let first = sample()
        let second = sample()
        let directory = URL(fileURLWithPath: "/dev/null")
        var selection = VoiceReviewAudioSelection()
        let earlierRequest = selection.select(first, libraryDirectory: directory)
        let earlier = try #require(earlierRequest)
        let middleRequest = selection.select(second, libraryDirectory: directory)
        let middle = try #require(middleRequest)
        let latestRequest = selection.select(first, libraryDirectory: directory)
        let latest = try #require(latestRequest)
        #expect(!selection.available)
        #expect(!selection.isVerified)
        let acceptedEarlier = selection.complete(earlier, available: true)
        #expect(!acceptedEarlier)
        let acceptedMiddle = selection.complete(middle, available: true)
        #expect(!acceptedMiddle)
        #expect(!selection.available)
        let acceptedLatest = selection.complete(latest, available: true)
        #expect(acceptedLatest)
        #expect(selection.available)
        #expect(selection.isVerified)
        _ = selection.select(nil, libraryDirectory: directory)
        let acceptedAfterClearing = selection.complete(latest, available: true)
        #expect(!acceptedAfterClearing)
        #expect(!selection.available)
        #expect(!selection.isVerified)
    }

    @Test func missingAudioVerificationKeepsSelectionUnavailable() async throws {
        var selection = VoiceReviewAudioSelection()
        let selected = selection.select(sample(), libraryDirectory: URL(fileURLWithPath: "/dev/null"))
        let request = try #require(selected)
        let available = await request.verify()
        #expect(!available)
        let accepted = selection.complete(request, available: available)
        #expect(accepted)
        #expect(!selection.available)
        #expect(selection.isVerified)
    }

    @Test func refreshAndSelectedVerificationDetectRemovedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var example = sample()
        let folder = try MeetingFolderLocation.newFolder(id: example.meetingID, date: Date(), directory: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("synthetic audio".utf8).write(to: audio)
        example.audioRevision = VoiceLibraryStore.revision(url: audio)
        let input = VoiceReviewPresentation.Input(
            candidates: [example], referenceEvidence: [], personID: nil, meetings: [:], libraryDirectory: directory)
        let cache = VoiceReviewPresentationCache()
        let first = await cache.prepare(input)
        #expect(first.playableCandidateIDs == [example.id])
        try FileManager.default.removeItem(at: audio)
        let reused = await cache.prepare(input)
        #expect(reused.playableCandidateIDs == [example.id])
        var selection = VoiceReviewAudioSelection()
        let selected = selection.select(example, libraryDirectory: directory)
        let request = try #require(selected)
        #expect(await request.verify() == false)
        let refreshed = await cache.prepare(input, forceRefresh: true)
        #expect(refreshed.playableCandidateIDs.isEmpty)
    }

    @Test func changedMeetingLabelsInvalidatePreparedRows() async {
        let example = sample()
        var meeting = Meeting(id: example.meetingID, title: "Sample Recording")
        meeting.createdAt = Date(timeIntervalSince1970: 1_000_000)
        let directory = URL(fileURLWithPath: "/dev/null")
        let cache = VoiceReviewPresentationCache()
        let first = await cache.prepare(
            .init(
                candidates: [example], referenceEvidence: [], personID: nil,
                meetings: [meeting.id: MeetingListEntry(meeting)], libraryDirectory: directory))
        meeting.title = "Renamed Recording"
        meeting.createdAt = Date(timeIntervalSince1970: 2_000_000)
        let updated = await cache.prepare(
            .init(
                candidates: [example], referenceEvidence: [], personID: nil,
                meetings: [meeting.id: MeetingListEntry(meeting)], libraryDirectory: directory))
        #expect(first.rows[example.id]?.title == "Sample Recording")
        #expect(updated.rows[example.id]?.title == "Renamed Recording")
        #expect(first.rows[example.id]?.help != updated.rows[example.id]?.help)
    }

    @Test func changedEvidenceInvalidatesPreparedRows() async {
        var example = sample()
        let person = UUID()
        example.namedPersonID = person
        let directory = URL(fileURLWithPath: "/dev/null")
        let cache = VoiceReviewPresentationCache()
        let first = await cache.prepare(
            .init(
                candidates: [], referenceEvidence: [example], personID: person, meetings: [:],
                libraryDirectory: directory))
        #expect(first.rows[example.id]?.referenceStatus == "Associated · Needs Review")
        example.personID = person
        example.review = .confirmed
        let updated = await cache.prepare(
            .init(
                candidates: [], referenceEvidence: [example], personID: person, meetings: [:],
                libraryDirectory: directory))
        #expect(updated.rows[example.id]?.referenceStatus == "Confirmed")
    }
}
