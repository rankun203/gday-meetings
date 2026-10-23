import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct VoiceSelectedReferenceTests {
    private let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2, normalization: "unitL2")

    private func fixture() throws -> (URL, VoiceLibraryStore, VoiceExample) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let meetingID = UUID()
        let directory = try MeetingFolderLocation.newFolder(id: meetingID, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("system.wav")
        try Data("synthetic source revision".utf8).write(to: file)
        let range = VoiceSampleRange(audioFile: "system.wav", source: "system", start: 0, end: 4)
        let revision = VoiceLibraryStore.revision(url: file)!
        var example = VoiceExample(
            meetingID: meetingID, speakerID: UUID(), source: "system", audioFile: range.audioFile,
            audioRevision: revision, start: range.start, end: range.end,
            embeddings: [.init(type: type, values: [1, 0])])
        example.sampleQuality = VoiceSampleQuality.assess(
            range: range, audioRevision: revision, scanConfiguration: "synthetic",
            samples: .init(repeating: 0.1, count: 64000))
        return (root, VoiceLibraryStore(loading: .immediate, directory: root), example)
    }

    @Test func correctionRevokesDerivedEvidenceAndRejectsStaleWorker() async throws {
        let (root, library, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Person(name: "Alex")
        let second = Person(name: "Sam")
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: first.id,
                updateReferenceEvidence: false))
        #expect(library.acceptSelectedReference(sample, personID: first.id, speakerID: sample.speakerID))
        #expect(library.decisions.first?.referenceSelectionPending == false)
        #expect((try await library.matchingPeople(from: [first]))[0].voiceSamples.count == 1)
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: second.id,
                updateReferenceEvidence: false))
        #expect(!library.acceptSelectedReference(sample, personID: first.id, speakerID: sample.speakerID))
        #expect((try await library.matchingPeople(from: [first]))[0].voiceSamples.isEmpty)
        #expect(library.acceptSelectedReference(sample, personID: second.id, speakerID: sample.speakerID))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect((try await reopened.matchingPeople(from: [second]))[0].voiceSamples.count == 1)
        #expect(reopened.examples.first?.selectedReference?.personID == second.id)
    }

    @Test func backgroundAcceptanceWaitsForCanonicalWriteWithoutPresentingAnError() throws {
        let (root, library, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID,
                personID: person, updateReferenceEvidence: false))
        #expect(library.assign(meetingID: UUID(), speakerID: UUID(), personID: UUID(), staged: true))
        let transaction = try library.beginCanonicalCommit()
        #expect(!library.acceptSelectedReference(sample, personID: person, speakerID: sample.speakerID))
        #expect(library.errorMessage == nil)
        library.finishCanonicalCommit(transaction, state: nil, committed: false)
        #expect(library.acceptSelectedReference(sample, personID: person, speakerID: sample.speakerID))
        #expect(
            library.finishReferenceSelection(meetingID: sample.meetingID, speakerID: sample.speakerID, personID: person)
        )
        #expect(library.decisions.first?.referenceSelectionPending == false)
    }

    @Test func explicitConfirmationSurvivesLaterTranscriptCorrection() throws {
        let (root, library, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID()
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: first,
                updateReferenceEvidence: false))
        #expect(library.acceptSelectedReference(sample, personID: first, speakerID: sample.speakerID))
        #expect(library.confirm(ids: [sample.id], personID: first))
        #expect(library.examples.first?.selectedReference == nil)
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: UUID(),
                updateReferenceEvidence: false))
        #expect(library.examples.first?.personID == first)
        #expect(library.examples.first?.review == .confirmed)
    }

    @Test func undoAssignmentWithdrawsLaterBackgroundEvidence() throws {
        let (root, library, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: person,
                updateReferenceEvidence: false))
        #expect(library.acceptSelectedReference(sample, personID: person, speakerID: sample.speakerID))
        #expect(library.undo())
        #expect(library.examples.first?.personID == nil)
        #expect(library.examples.first?.review == .unassigned)
    }

    @Test func missingOrBadPCMAndChangedAudioCannotEnroll() throws {
        let (root, library, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: person,
                updateReferenceEvidence: false))
        var bad = sample
        bad.sampleQuality = nil
        #expect(!library.acceptSelectedReference(bad, personID: person, speakerID: sample.speakerID))
        bad.sampleQuality = sample.sampleQuality
        bad.sampleQuality?.nearSilentFraction = 1
        #expect(!library.acceptSelectedReference(bad, personID: person, speakerID: sample.speakerID))
        bad = sample
        bad.audioRevision = "stale"
        #expect(!library.acceptSelectedReference(bad, personID: person, speakerID: sample.speakerID))
        #expect(library.examples.isEmpty)
    }

    @Test func mergeKeepsSelectionDependencyAndDeletionWithdrawsIt() throws {
        let (root, library, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        let target = UUID()
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: person,
                updateReferenceEvidence: false))
        #expect(library.acceptSelectedReference(sample, personID: person, speakerID: sample.speakerID))
        #expect(library.mergePeople(ids: [person], into: target))
        #expect(library.examples.first?.selectedReference?.personID == target)
        #expect(library.examples.first?.personID == target)
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID, personID: nil, updateReferenceEvidence: false)
        )
        #expect(library.examples.first?.personID == nil)
    }

    @Test func selectedReferenceSuppressesRedundantQuestionsWithoutConfirmingThem() throws {
        let (root, _, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var reference = sample
        let person = UUID()
        reference.personID = person
        reference.review = .confirmed
        reference.selectedReference = .init(meetingID: sample.meetingID, speakerID: sample.speakerID, personID: person)
        var original = sample
        original.id = UUID()
        original.start = 5
        original.end = 9
        original.suggestedPersonID = person
        var otherSpeaker = original
        otherSpeaker.id = UUID()
        otherSpeaker.speakerID = UUID()
        let snapshot = VoiceReviewSnapshot.make(
            hydrated: [reference, original, otherSpeaker], metadata: [reference, original, otherSpeaker],
            playableIDs: [reference.id, original.id, otherSpeaker.id], personIDs: [person], revision: 1)
        #expect(snapshot.candidates[person]?.contains(where: { $0.id == original.id }) == false)
        #expect(snapshot.candidates[person]?.contains(where: { $0.id == otherSpeaker.id }) == true)
        #expect(original.review == .unassigned && original.personID == nil)
        var unnamed = original
        unnamed.suggestedPersonID = nil
        let precomputed = VoiceIdentificationGroup(
            id: unnamed.groupID, examples: [unnamed], representativeID: unnamed.id)
        let prepared = VoiceReviewSnapshot.make(
            hydrated: [reference, unnamed], metadata: [reference, unnamed],
            playableIDs: [reference.id, unnamed.id], personIDs: [person], revision: 2,
            preparedGroups: [precomputed])
        #expect(prepared.unnamedGroups.isEmpty)
        reference.personID = nil
        reference.review = .unassigned
        #expect(VoiceReviewSnapshot.selectiveEvidence([reference, original]).contains { $0.id == original.id })
    }

    @Test func referenceRangeMustAgreeWithCurrentTranscriptIdentity() {
        let range = VoiceSampleRange(audioFile: "system.wav", source: "system", start: 2, end: 6)
        let speaker = MeetingSpeaker(label: "voice_a", track: "system", providerName: "Synthetic")
        var meeting = Meeting()
        meeting.speakers = [speaker]
        meeting.transcript = [.init(start: 0, end: 8, speaker: speaker.label, text: "Speech", speakerID: speaker.id)]
        #expect(VoiceReferenceSelection.isSupported(range: range, meeting: meeting, speakerID: speaker.id))
        var uncertain = meeting
        uncertain.transcript[0].associationUncertain = true
        #expect(!VoiceReferenceSelection.isSupported(range: range, meeting: uncertain, speakerID: speaker.id))
        var changed = meeting
        changed.transcript[0].speakerID = UUID()
        #expect(!VoiceReferenceSelection.isSupported(range: range, meeting: changed, speakerID: speaker.id))
        var overlap = meeting
        let other = MeetingSpeaker(label: "voice_b", track: "system", providerName: "Synthetic")
        overlap.speakers.append(other)
        overlap.transcript.append(
            .init(start: 4, end: 5, speaker: other.label, text: "Other speech", speakerID: other.id))
        #expect(!VoiceReferenceSelection.isSupported(range: range, meeting: overlap, speakerID: speaker.id))
        var gap = meeting
        gap.transcript = [
            .init(start: 0, end: 3, speaker: speaker.label, text: "First", speakerID: speaker.id),
            .init(start: 4, end: 8, speaker: speaker.label, text: "Second", speakerID: speaker.id),
        ]
        #expect(!VoiceReferenceSelection.isSupported(range: range, meeting: gap, speakerID: speaker.id))
    }

    @Test func supportedRangeClipsGapsAndOtherIdentities() throws {
        let speaker = MeetingSpeaker(label: "voice_a", track: "system", providerName: "Synthetic")
        let other = MeetingSpeaker(label: "voice_b", track: "system", providerName: "Synthetic")
        var meeting = Meeting()
        meeting.speakers = [speaker, other]
        meeting.transcript = [
            .init(start: 0.003, end: 3, speaker: speaker.label, text: "First", speakerID: speaker.id),
            .init(start: 4, end: 8, speaker: speaker.label, text: "Second", speakerID: speaker.id),
            .init(start: 5, end: 6, speaker: other.label, text: "Other", speakerID: other.id),
        ]
        let range = VoiceSampleRange(audioFile: "system.wav", source: "system", start: 0, end: 10)
        let clipped = try #require(
            VoiceReferenceSelection.supportedRange(range: range, meeting: meeting, speakerID: speaker.id))
        #expect(clipped.supportSpans.count == 3)
        #expect(
            clipped.supportSpans.allSatisfy {
                !$0.overlaps(.init(start: 3, end: 4)) && !$0.overlaps(.init(start: 5, end: 6))
            })
        #expect(VoiceReferenceSelection.isSupported(range: clipped, meeting: meeting, speakerID: speaker.id))
        meeting.transcript = [.init(start: 1, end: 2, speaker: speaker.label, text: "Short", speakerID: speaker.id)]
        #expect(VoiceReferenceSelection.supportedRange(range: range, meeting: meeting, speakerID: speaker.id) == nil)
    }

    @Test func withdrawnReferenceDoesNotBecomeAnotherQuestion() {
        let person = UUID()
        var withdrawn = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        withdrawn.selectedReference = .init(
            meetingID: withdrawn.meetingID, speakerID: withdrawn.speakerID, personID: person)
        #expect(!withdrawn.acceptsSuggestions)
        #expect(!withdrawn.needsReview)
    }

    @Test func anotherSpeakerInSameAnalysisClusterRemainsReviewable() {
        let person = UUID()
        let analysis = UUID()
        var selected = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system", audioRevision: "revision")
        selected.personID = person
        selected.review = .confirmed
        selected.selectedReference = .init(
            meetingID: selected.meetingID, speakerID: selected.speakerID, personID: person)
        selected.detectedSpeakerID = "local_voice_01"
        selected.detectedSpeakerResultID = analysis
        var other = selected
        other.id = UUID()
        other.speakerID = UUID()
        other.personID = nil
        other.review = .unassigned
        other.selectedReference = nil
        #expect(VoiceReviewSnapshot.selectiveEvidence([selected, other]).contains { $0.id == other.id })
    }

    @Test func ignoreAndRestorePreserveDependentReferenceProvenance() throws {
        let (root, library, sample) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let person = UUID()
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID,
                personID: person, updateReferenceEvidence: false))
        #expect(library.acceptSelectedReference(sample, personID: person, speakerID: sample.speakerID))
        #expect(library.exclude(ids: [sample.id]))
        #expect(library.examples.first?.selectedReference?.personID == person)
        #expect(library.exclude(ids: [sample.id], excluded: false))
        #expect(library.examples.first?.selectedReference?.personID == person)
        #expect(
            library.assign(
                meetingID: sample.meetingID, speakerID: sample.speakerID,
                personID: UUID(), updateReferenceEvidence: false))
        #expect(library.examples.first?.personID == nil)
        #expect(library.examples.first?.review == .unassigned)
    }

    @Test func referenceSelectionRejectsRedundancyAndContradiction() {
        let embedding = TypedVoiceEmbedding(type: type, values: [1, 0])
        let id = UUID()
        #expect(VoiceReferenceSelection.permits(embedding: embedding, personID: id, profiles: []))
        let same = Person(
            name: "Alex", voiceSamples: [.init(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: embedding)])
        #expect(!VoiceReferenceSelection.permits(embedding: embedding, personID: same.id, profiles: [same]))
        #expect(!VoiceReferenceSelection.permits(embedding: embedding, personID: id, profiles: [same]))
        var different = same
        different.voiceSamples = [
            .init(meetingID: UUID(), speakerID: UUID(), voiceEmbedding: .init(type: type, values: [0, 1]))
        ]
        #expect(!VoiceReferenceSelection.permits(embedding: embedding, personID: different.id, profiles: [different]))
    }
}
