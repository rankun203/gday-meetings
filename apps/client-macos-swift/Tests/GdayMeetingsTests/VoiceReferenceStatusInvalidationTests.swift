import Foundation
import Testing

@testable import GdayMeetings

@MainActor
struct VoiceReferenceStatusInvalidationTests {
    private let type = EmbeddingType(
        modelID: "synthetic", revision: "v1", compatibilityVersion: "v1", dimension: 2, normalization: "unitL2")

    private struct Fixture {
        var root: URL
        var library: VoiceLibraryStore
        var people: [Person]
        var samples: [VoiceExample]
        var result: VoiceReferenceSelectionResult
        var decision: VoiceSpeakerDecision
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meetingID = UUID()
        let folder = try MeetingFolderLocation.newFolder(id: meetingID, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic recording revision".utf8).write(to: folder.appendingPathComponent("system.wav"))
        let revision = try #require(VoiceLibraryStore.revision(url: folder.appendingPathComponent("system.wav")))
        let people = [Person(name: "Person A"), Person(name: "Person B"), Person(name: "Person C")]
        let samples = people.enumerated().map { index, person -> VoiceExample in
            let start = Double(index * 10)
            let range = VoiceSampleRange(audioFile: "system.wav", source: "system", start: start, end: start + 4)
            var example = VoiceExample(
                meetingID: meetingID, speakerID: UUID(), source: "system", audioFile: range.audioFile,
                audioRevision: revision, start: range.start, end: range.end, personID: person.id,
                review: .confirmed, embeddings: [.init(type: type, values: [1, 0])])
            example.sampleQuality = VoiceSampleQuality.assess(
                range: range, audioRevision: revision, scanConfiguration: "synthetic",
                samples: .init(repeating: 0.1, count: 64000))
            return example
        }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(library.upsert(samples))
        let first = samples[0]
        #expect(
            library.assign(
                meetingID: meetingID, speakerID: first.speakerID, personID: people[0].id, updateReferenceEvidence: false
            ))
        let result = VoiceReferenceSelectionResult(outcome: .sampleAdded, sampleID: first.id, audioRevision: revision)
        #expect(
            library.finishReferenceSelection(
                meetingID: meetingID, speakerID: first.speakerID, personID: people[0].id, result: result))
        let decision = try #require(
            library.referenceDecision(meetingID: meetingID, speakerID: first.speakerID, personID: people[0].id))
        return .init(root: root, library: library, people: people, samples: samples, result: result, decision: decision)
    }

    private func validation(_ fixture: Fixture) -> SpeakerReferenceValidation {
        .init(
            decision: fixture.decision,
            dependency: fixture.library.referenceFeedbackDependency(
                personID: fixture.people[0].id, result: fixture.result),
            personExists: true)
    }

    @Test func unrelatedAssignmentsAndUnconfirmedEvidenceDoNotRestartAnExistingRow() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let before = validation(value)
        var state = SpeakerReferenceValidationState()
        state.begin(before)
        state.complete(.available, for: before)
        #expect(
            value.library.assign(
                meetingID: UUID(), speakerID: UUID(), personID: value.people[1].id, updateReferenceEvidence: false))
        let candidate = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        #expect(value.library.upsert([candidate]))
        let after = validation(value)
        #expect(after == before)
        #expect(state.usage(for: after) == .available)
        #expect(!state.failed(for: after))
    }

    @Test func representationChangesInvalidateOnlyTheAffectedPersonAndSample() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let before = validation(value)
        let otherBefore = value.library.referenceFeedbackDependency(personID: value.people[1].id, result: nil)
        let nextType = EmbeddingType(
            modelID: "synthetic", revision: "v2", compatibilityVersion: "v2", dimension: 2, normalization: "unitL2")
        #expect(
            value.library.addRepresentation(
                exampleID: value.samples[1].id, embedding: .init(type: nextType, values: [0, 1])))
        #expect(validation(value) == before)
        #expect(value.library.referenceFeedbackDependency(personID: value.people[1].id, result: nil) != otherBefore)
        var state = SpeakerReferenceValidationState()
        state.begin(before)
        state.complete(.available, for: before)
        #expect(
            value.library.addRepresentation(
                exampleID: value.samples[0].id, embedding: .init(type: nextType, values: [0, 1])))
        let changed = validation(value)
        #expect(changed != before)
        #expect(state.usage(for: changed) == nil)
        state.begin(changed)
        state.complete(.available, for: before)
        #expect(state.usage(for: changed) == nil)
    }

    @Test func crossPersonOverlapInvalidatesOnlyProfilesWhoseEffectiveEvidenceChanged() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let before = validation(value)
        let unaffected = value.library.referenceFeedbackDependency(personID: value.people[2].id, result: nil)
        var conflicting = value.samples[0]
        conflicting.id = UUID()
        conflicting.speakerID = UUID()
        conflicting.personID = value.people[1].id
        #expect(value.library.upsert([conflicting]))
        let after = validation(value)
        #expect(after != before)
        #expect(!after.dependency.profileEligible)
        #expect(value.library.referenceFeedbackDependency(personID: value.people[2].id, result: nil) == unaffected)
        var state = SpeakerReferenceValidationState()
        state.begin(before)
        state.complete(.available, for: before)
        #expect(state.usage(for: after) == .stored)
    }

    @Test func sameSampleRefreshKeepsVerifiedUsageAndIgnoresStaleCompletionOrFailure() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let before = validation(value)
        var state = SpeakerReferenceValidationState()
        state.begin(before)
        state.complete(.available, for: before)
        var additional = value.samples[0]
        additional.id = UUID()
        additional.start = 40
        additional.end = 44
        #expect(value.library.upsert([additional]))
        let refresh = validation(value)
        #expect(refresh != before)
        #expect(refresh.hasSameSample(as: before))
        #expect(state.usage(for: refresh) == .available)
        state.begin(refresh)
        #expect(state.usage(for: refresh) == .available)
        state.complete(.stored, for: before)
        state.fail(before)
        #expect(state.usage(for: refresh) == .available)
        #expect(!state.failed(for: refresh))
        state.fail(refresh)
        #expect(state.usage(for: refresh) == .available)
        #expect(!state.failed(for: refresh))
        #expect(state.refreshFailed(for: refresh))
        state.complete(.stored, for: refresh)
        #expect(state.usage(for: refresh) == .stored)
        #expect(!state.refreshFailed(for: refresh))
    }

    @Test func removalReassignmentAndPersonDeletionInvalidateBeforeAsyncValidationRuns() throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        let before = validation(value)
        var state = SpeakerReferenceValidationState()
        state.begin(before)
        state.complete(.available, for: before)
        #expect(value.library.clear(ids: [value.samples[0].id]))
        #expect(state.usage(for: validation(value)) == .unavailable)
        var missingPerson = before
        missingPerson.personExists = false
        #expect(state.usage(for: missingPerson) == .unavailable)
        var differentPerson = before
        differentPerson.decision?.personID = value.people[1].id
        #expect(state.usage(for: differentPerson) == .unavailable)
    }

    @Test func repeatedSharedSnapshotCancellationEndsWithAnExplicitFailure() async throws {
        let value = try fixture()
        defer { try? FileManager.default.removeItem(at: value.root) }
        value.library.beforeMatchingRead = { throw CancellationError() }
        do {
            _ = try await value.library.referenceSampleUsage(
                result: value.result, personID: value.people[0].id, people: value.people)
            Issue.record("Expected bounded verification failure")
        }
        catch is CancellationError {
            Issue.record("Shared snapshot cancellation must not leave initial verification waiting forever")
        }
        catch { #expect(error.localizedDescription.contains("Voice recognition is changing")) }
    }
}
