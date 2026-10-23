import Combine
import Foundation
import Testing

@testable import GdayMeetings

struct VoiceReviewLauncherPresentationTests {
    @Test func qualityIndicationDescribesOnlyTheOpeningSample() async {
        let person = Person(name: "Sample Person")
        let normal = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "synthetic-v1", start: 0, end: 2)
        var silent = normal
        silent.id = UUID()
        silent.sampleQuality = VoiceSampleQuality.assess(
            range: silent.range!, audioRevision: silent.audioRevision!, scanConfiguration: "synthetic-v1",
            samples: [Float](repeating: 0, count: 32000))
        let group = VoiceIdentificationGroup(
            id: UUID(), examples: [normal, silent], representativeID: silent.id)
        let catalog = await VoiceReviewLauncherPresentation.prepare(
            snapshot: .init(revision: 1, candidates: [person.id: [normal, silent]], unnamedGroups: [group]),
            people: [person], titles: [:], dates: [:])
        #expect(catalog.people.first?.qualityIssue == nil)
        #expect(catalog.groups.first?.qualityIssue == "Nearly Silent Audio")
        #expect(catalog.groups.first?.qualityHelp?.hasPrefix("Representative sample: Nearly Silent Audio.") == true)
        var stale = silent
        stale.audioRevision = "synthetic-v2"
        let staleGroup = VoiceIdentificationGroup(id: UUID(), examples: [stale], representativeID: stale.id)
        let refreshed = await VoiceReviewLauncherPresentation.prepare(
            snapshot: .init(revision: 2, candidates: [:], unnamedGroups: [staleGroup]),
            people: [], titles: [:], dates: [:])
        #expect(refreshed.groups.first?.qualityIssue == nil)
    }

    @Test func repeatedQueriesFilterCapturedCatalogAndPreserveRecordingContext() async {
        let person = Person(name: "Sample Person")
        let example = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        let group = VoiceIdentificationGroup(id: UUID(), examples: [example], representativeID: example.id)
        let catalog = await VoiceReviewLauncherPresentation.prepare(
            snapshot: .init(revision: 1, candidates: [person.id: [example]], unnamedGroups: [group]),
            people: [person], titles: [example.meetingID: "Sample Recording"], dates: [:])
        let byName = await catalog.filtered(query: "Person")
        let byRecording = await catalog.filtered(query: "Recording")
        let missing = await catalog.filtered(query: "Other")
        let restored = await catalog.filtered(query: "")
        #expect(byName.people.map(\.id) == [person.id])
        #expect(byRecording.people.map(\.id) == [person.id])
        #expect(byRecording.groups.map(\.id) == [group.id])
        #expect(byRecording.people.first?.recordingTitle == "Sample Recording")
        #expect(byRecording.people.first?.recordingID == example.meetingID)
        #expect(missing.people.isEmpty && missing.groups.isEmpty)
        #expect(restored.people.map(\.id) == catalog.people.map(\.id))
        #expect(restored.groups.map(\.id) == catalog.groups.map(\.id))
        #expect(restored.people.first?.count == 1)
        #expect(restored.people.first?.meetingCount == 1)
    }

    @Test func rowsKeepCountsContextAndRecordingSearchTogether() async {
        let person = Person(name: "Sample Person")
        let older = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        let newer = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        let group = VoiceIdentificationGroup(id: UUID(), examples: [older], representativeID: older.id)
        let snapshot = VoiceReviewSnapshot(
            revision: 1, candidates: [person.id: [older, newer]], unnamedGroups: [group])
        let titles = [older.meetingID: "First Recording", newer.meetingID: "Second Recording"]
        let dates = [older.meetingID: Date(timeIntervalSince1970: 1), newer.meetingID: Date(timeIntervalSince1970: 2)]
        let all = await VoiceReviewLauncherPresentation.prepare(
            snapshot: snapshot, people: [person], titles: titles, dates: dates, query: "")
        #expect(all.people.map(\.id) == [person.id])
        #expect(all.people.first?.count == 2)
        #expect(all.people.first?.meetingCount == 2)
        #expect(all.people.first?.recordingTitle == "Second Recording")
        #expect(all.people.first?.recordingID == newer.meetingID)
        #expect(all.groups.first?.recordingID == older.meetingID)
        #expect(all.groups.first?.id == group.id)
        #expect(all.groups.first?.group?.evidenceExamples == group.evidenceExamples)
        let filtered = await VoiceReviewLauncherPresentation.prepare(
            snapshot: snapshot, people: [person], titles: titles, dates: dates, query: "Second")
        #expect(filtered.people.map(\.id) == [person.id])
        #expect(filtered.groups.isEmpty)
    }

    @Test func thousandCandidateCatalogRetainsIdentityAndSupportsRepeatedFiltering() async {
        let meetingID = UUID()
        let examples = (0..<1000).map { index in
            VoiceExample(
                meetingID: meetingID, speakerID: UUID(), source: "system", audioFile: "system.wav",
                start: Double(index), end: Double(index + 2))
        }
        let groups = examples.map { VoiceIdentificationGroup(id: $0.groupID, examples: [$0], representativeID: $0.id) }
        let catalog = await VoiceReviewLauncherPresentation.prepare(
            snapshot: .init(revision: 1, candidates: [:], unnamedGroups: groups), people: [],
            titles: [meetingID: "Synthetic Recording"], dates: [:])
        #expect(catalog.groups.count == 1000)
        #expect(Set(catalog.groups.map(\.id)).count == 1000)
        let matching = await catalog.filtered(query: "Recording")
        let missing = await catalog.filtered(query: "Absent")
        #expect(matching.groups.map(\.id) == catalog.groups.map(\.id))
        #expect(missing.groups.isEmpty)
        #expect(catalog.groups.allSatisfy { $0.count == 1 && $0.meetingCount == 1 })
    }

    @MainActor
    @Test func coveredChooserDefersChangesAndRejectsWorkStartedBeforeCovering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let observation = VoiceReviewLauncherObservation(store: store, library: store.voiceLibrary)
        let initial = observation.snapshot
        let first = observation.beginRequest()
        let request = try #require(first)
        #expect(observation.accepts(request))
        var publications = 0
        let subscription = observation.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }
        // Also exercise a queued will-change callback that crosses covering.
        store.people = [Person(name: "First Person")]
        observation.cover()
        store.people = [Person(name: "Latest Person")]
        store.directoryRevision = UUID()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(observation.snapshot == initial)
        #expect(publications == 0)
        #expect(!observation.accepts(request))
        #expect(observation.beginRequest() == nil)
        let changed = observation.reveal()
        #expect(changed)
        #expect(observation.snapshot.people == store.people)
        #expect(observation.snapshot.directoryRevision == store.directoryRevision)
        #expect(publications == 1)
        #expect(!observation.accepts(request))
        let latest = observation.beginRequest()
        let latestRequest = try #require(latest)
        #expect(observation.accepts(latestRequest))
        let another = observation.beginRequest()
        #expect(another != nil)
        #expect(!observation.accepts(latestRequest))
    }
}
