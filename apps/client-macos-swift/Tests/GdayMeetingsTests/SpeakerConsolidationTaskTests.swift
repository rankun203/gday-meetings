import Foundation
import Testing

@testable import GdayMeetings

private final class ConsolidationValidationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func validate() throws {
        lock.lock()
        calls += 1
        let fail = calls == 2
        lock.unlock()
        if fail { throw ServiceError("Synthetic input change before transaction commit.") }
    }
}

private final class ConsolidationCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }
    func wait() {
        lock.lock()
        entered = true
        lock.unlock()
        semaphore.wait()
    }
    func release() { semaphore.signal() }
}

@MainActor struct SpeakerConsolidationTaskTests {
    private func fixture(root: URL) async throws -> (MeetingStore, Meeting, URL) {
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        store.settings.recognizeSpeakers = false
        var meeting = Meeting(title: "Synthetic retained voice evidence")
        meeting.audioFiles = ["microphone.wav"]
        let embedding = TypedVoiceEmbedding(
            type: .community1SpeechSpan, values: [1] + [Double](repeating: 0, count: 255))
        let first = MeetingSpeaker(
            label: "mic_01", track: "microphone", providerName: "Synthetic", voiceEmbedding: embedding)
        let second = MeetingSpeaker(
            label: "mic_02", track: "microphone", providerName: "Synthetic", voiceEmbedding: embedding)
        meeting.replaceSpeakers([first, second])
        meeting.transcript = [
            .init(
                start: 0, end: 3, speaker: first.label, text: "First synthetic passage.", speakerID: first.id,
                source: .microphone),
            .init(
                start: 5, end: 8, speaker: second.label, text: "Second synthetic passage.", speakerID: second.id,
                source: .microphone),
        ]
        let folder = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("microphone.wav")
        // Consolidation reads the retained vectors, not PCM. These bytes test source binding only.
        try Data([0, 1, 2, 3]).write(to: audio)
        try await store.insertImportedMeeting(meeting)
        let journal = SpeakerEvidenceStore(directory: folder)
        for row in meeting.transcript {
            try await journal.append(
                SpeakerEvidenceSample(
                    id: row.id.uuidString, source: "microphone", localSpeakerID: row.speakerID!.uuidString,
                    start: row.start, end: row.end, embedding: embedding))
        }
        try await journal.append(
            meeting.transcript.map {
                .init(source: "microphone", localSpeakerID: $0.speakerID!.uuidString, start: $0.start, end: $0.end)
            },
            window: .init(
                generation: "window-a", source: "microphone",
                localSpeakerIDs: meeting.speakers.map { $0.id.uuidString }, publicationStart: 0, observedEnd: 8,
                policyRevision: SpeakerEvidenceWindow.protectedPolicy))
        try await journal.finish()
        try SpeakerEvidenceInputReceipt.seal(directory: folder, files: [audio])
        return (store, meeting, audio)
    }

    @Test func taskPublishesLabelsReviewSamplesAndRepeatableAssignments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await fixture(root: root)
        try await store.performSpeakerConsolidation(id: original.id)
        let updated = try #require(store.meeting(id: original.id))
        #expect(updated.speakers.count == 1)
        #expect(updated.transcript[0].speakerID == updated.transcript[1].speakerID)
        #expect(updated.transcript.map(\.text) == original.transcript.map(\.text))
        let resultID = try #require(updated.speakerLabelSource?.resultID)
        let folder = store.directory(for: updated.id)
        #expect(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("speaker-labels-\(resultID).json").path))
        #expect(
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("speaker-consolidation-\(resultID).json").path))
        let examples = store.voiceLibrary.examples.filter {
            $0.meetingID == original.id && $0.speakerID == updated.speakers[0].id
        }
        #expect(examples.count >= 1 && examples.count <= 3)
        #expect(examples.allSatisfy { $0.personID == nil })
        try await store.performSpeakerConsolidation(id: original.id)
        let repeated = try #require(store.meeting(id: original.id))
        #expect(repeated.transcript == updated.transcript)
        #expect(repeated.speakers == updated.speakers)
    }

    @Test func cancellationDuringCanonicalPublicationReportsCommittedResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await fixture(root: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let gate = ConsolidationCommitGate()
        defer { gate.release() }
        store.canonicalWriteHook = { gate.wait() }
        let id = try #require(await store.queueSpeakerConsolidation(id: original.id))
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(5)) { gate.started })
        let operation = try #require(store.managedTaskOperations[id])
        // An admitted canonical transaction finishes atomically despite cancellation.
        operation.cancel()
        gate.release()
        await operation.value
        let task = try #require(store.managedTask(id: id))
        #expect(task.state == .completed)
        #expect(task.errorMessage == nil)
        #expect(store.hasCommittedTaskReceipt(task))
        let disk = try MeetingFolderStorage.read(id: original.id, directory: root)
        #expect(disk.completedTaskIDs[BackgroundJob.Kind.diarization.rawValue] == id)
        #expect(disk.speakerLabelSource != nil)
        #expect(!store.voiceLibrary.examples.filter { $0.meetingID == original.id }.isEmpty)
    }

    @Test func publicationProjectsReviewDecisionsMadeAfterResultPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, audio) = try await fixture(root: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Alex")
        let expected = try #require(store.meeting(id: original.id))
        var prepared = expected
        prepared.speakerLabelSource = .init(resultID: UUID(), providerName: "Synthetic", generatedAt: Date())
        // The prepared result predates this exact-audio review. Metadata upsert does
        // not project it into the meeting, as a separate queued review could arrive.
        let example = VoiceExample(
            meetingID: original.id, speakerID: original.speakers[0].id,
            source: "microphone", audioFile: "microphone.wav", audioRevision: VoiceLibraryStore.revision(url: audio),
            start: 0, end: 3, personID: person, review: .confirmed)
        #expect(store.voiceLibrary.upsert([example]))
        let saved = await store.commitSpeakerConsolidation(
            expected: expected, updated: prepared,
            examples: [], artifacts: [], validateInputs: {})
        #expect(saved)
        let published = try #require(store.meeting(id: original.id))
        let projectedID = try #require(published.transcript[0].speakerID)
        let projected = try #require(published.speakers.first { $0.id == projectedID })
        #expect(projected.personID == person)
        #expect(projected.voiceReviewExampleID == example.id)
        #expect(projected.id != original.speakers[0].id)
        let disk = try MeetingFolderStorage.read(id: original.id, directory: root)
        #expect(disk.transcript[0].speakerID == projectedID)
        #expect(disk.speakers.first { $0.id == projectedID }?.personID == person)
        #expect(store.voiceLibrary.examples.first { $0.id == example.id }?.review == .confirmed)
    }

    @Test func unchangedStagedExamplesReserveVoiceWritesUntilPublicationFinishes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(loading: .immediate, directory: root)
        let example = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "microphone")
        let unrelated = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        #expect(library.upsert([example]))
        #expect(library.upsert([example], staged: true))
        #expect(!library.upsert([unrelated]))
        let commit = try #require(try library.beginCanonicalCommit())
        #expect(!library.upsert([unrelated]))
        library.finishCanonicalCommit(commit, state: nil, committed: false)
        #expect(library.upsert([unrelated]))
        #expect(library.examples.contains { $0.id == example.id })
        #expect(library.examples.contains { $0.id == unrelated.id })
    }

    @Test func failedCanonicalSaveLeavesNoReviewExamplesOrReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await fixture(root: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        store.canonicalWriteHook = { throw ServiceError("Synthetic save failure.") }
        await #expect(throws: (any Error).self) { try await store.performSpeakerConsolidation(id: original.id) }
        #expect(store.meeting(id: original.id)?.transcript == original.transcript)
        #expect(store.meeting(id: original.id)?.speakerLabelSource == nil)
        #expect(store.voiceLibrary.examples.filter { $0.meetingID == original.id }.isEmpty)
        let folder = store.directory(for: original.id)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!files.contains { $0.hasPrefix("speaker-consolidation-") || $0.hasPrefix("speaker-labels-") })
        #expect(!files.contains("transcript-revisions.json"))
        let reopened = VoiceLibraryStore(loading: .immediate, directory: root)
        #expect(reopened.examples.filter { $0.meetingID == original.id }.isEmpty)
        store.canonicalWriteHook = nil
        try await store.performSpeakerConsolidation(id: original.id)
        #expect(store.meeting(id: original.id)?.speakerLabelSource != nil)
    }

    @Test func inputChangeBeforeCommitRollsBackWrittenVoiceMeetingAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await fixture(root: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let folder = store.directory(for: original.id)
        let resultID = UUID()
        let taskID = UUID()
        let baseline = try #require(store.meeting(id: original.id))
        var updated = baseline
        updated.speakerLabelSource = .init(resultID: resultID, providerName: "Synthetic", generatedAt: Date())
        updated.completedTaskIDs[BackgroundJob.Kind.diarization.rawValue] = taskID
        updated.transcript[0].speaker = "Consolidated synthetic speaker"
        let example = VoiceExample(
            meetingID: original.id, speakerID: original.speakers[0].id,
            source: "microphone", audioFile: "microphone.wav", start: 0, end: 3,
            embeddings: [original.speakers[0].voiceEmbedding!])
        let oldHistory = Data("synthetic original history".utf8)
        let history = folder.appendingPathComponent("synthetic-history.json")
        try oldHistory.write(to: history)
        let artifact = CanonicalMeetingArtifact(
            meetingID: original.id, name: "synthetic-history.json",
            data: Data("synthetic replacement history".utf8), previous: oldHistory)
        let failure = ConsolidationValidationFailure()
        let saved = await store.commitSpeakerConsolidation(
            expected: baseline, updated: updated,
            examples: [example], artifacts: [artifact], validateInputs: { try failure.validate() })
        #expect(!saved)
        #expect(try Data(contentsOf: history) == oldHistory)
        let restored = try MeetingFolderStorage.read(id: original.id, directory: root)
        #expect(restored.transcript == baseline.transcript)
        #expect(restored.speakerLabelSource == nil)
        #expect(restored.completedTaskIDs[BackgroundJob.Kind.diarization.rawValue] == nil)
        #expect(store.voiceLibrary.examples.filter { $0.meetingID == original.id }.isEmpty)
        #expect(
            VoiceLibraryStore(loading: .immediate, directory: root).examples.filter { $0.meetingID == original.id }
                .isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".document-transaction").path))
    }

    @Test func interruptedSupplementalArtifactPublicationUsesExistingRecoveryJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = root.appendingPathComponent("transcript-revisions.json")
        let receipt = root.appendingPathComponent("speaker-consolidation-synthetic.json")
        let original = Data("synthetic previous history".utf8)
        try original.write(to: history)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
        var transaction = LibraryFileTransaction(root: root)
        try transaction.remember(history)
        try transaction.remember(receipt)
        try PrivateTranscriptFile.write(
            Data("synthetic next history".utf8), name: history.lastPathComponent,
            at: root, recordEvent: false)
        try PrivateTranscriptFile.write(
            Data("synthetic result".utf8), name: receipt.lastPathComponent,
            at: root, recordEvent: false)
        // Recovery after process exit restores overwritten history and removes new receipts.
        try LibraryFileTransaction.recover(root: root)
        #expect(try Data(contentsOf: history) == original)
        let permissions = try FileManager.default.attributesOfItem(atPath: history.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(!FileManager.default.fileExists(atPath: receipt.path))
    }

    @Test func resealedReplacementCannotPublishAnalysisOfEarlierEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, audio) = try await fixture(root: root)
        let folder = store.directory(for: original.id)
        let expected = try SpeakerEvidenceInputReceipt.validate(directory: folder, files: [audio])
        try Data([1, 2, 3, 4, 5]).write(to: audio, options: .atomic)
        try SpeakerEvidenceInputReceipt.seal(directory: folder, files: [audio])
        // The replacement is valid on its own but cannot validate an earlier analysis.
        try SpeakerEvidenceInputReceipt.validate(directory: folder, files: [audio])
        #expect(throws: (any Error).self) {
            try SpeakerEvidenceInputReceipt.validate(directory: folder, files: [audio], expected: expected)
        }
    }

    @Test func replacedAudioRejectsTaskWithoutChangingTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, audio) = try await fixture(root: root)
        try Data([0, 1, 2, 3, 4]).write(to: audio, options: .atomic)
        await #expect(throws: (any Error).self) { try await store.performSpeakerConsolidation(id: original.id) }
        let current = try #require(store.meeting(id: original.id))
        #expect(current.transcript == original.transcript)
        #expect(current.speakerLabelSource == nil)
        #expect(store.voiceLibrary.examples.filter { $0.meetingID == original.id }.isEmpty)
    }
    @Test func freshGroupsSuggestReviewedPeopleWithoutAutomaticallyEnrollingSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, _) = try await fixture(root: root)
        store.settings.recognizeSpeakers = true
        let personID = await store.addPerson(name: "Alex")
        let embedding = try #require(original.speakers.first?.voiceEmbedding)
        let profile = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "microphone", personID: personID,
            review: .confirmed, embeddings: [embedding])
        #expect(store.voiceLibrary.upsert([profile]))
        try await store.performSpeakerConsolidation(id: original.id)
        let updated = try #require(store.meeting(id: original.id))
        #expect(updated.speakers.allSatisfy { $0.personID == nil })
        let examples = store.voiceLibrary.examples.filter { $0.meetingID == original.id }
        #expect(!examples.isEmpty)
        #expect(
            examples.allSatisfy { $0.review == .suggested && $0.suggestedPersonID == personID && $0.personID == nil })
        let profiles = (try await store.voiceLibrary.matchingPeople(from: store.people))
        #expect(profiles.first { $0.id == personID }?.voiceSamples.count == 1)
    }

    @Test func confirmedAudioDecisionSurvivesRegeneratedSpeakerIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, audio) = try await fixture(root: root)
        let personID = await store.addPerson(name: "Alex")
        let originalSpeaker = try #require(original.speakers.first)
        let reviewed = VoiceExample(
            meetingID: original.id, speakerID: originalSpeaker.id, source: "microphone",
            audioFile: "microphone.wav", audioRevision: VoiceLibraryStore.revision(url: audio),
            start: 0, end: 3, personID: personID, review: .confirmed,
            embeddings: [try #require(originalSpeaker.voiceEmbedding)])
        #expect(store.voiceLibrary.upsert([reviewed]))
        try await store.performSpeakerConsolidation(id: original.id)
        let updated = try #require(store.meeting(id: original.id))
        let projected = try #require(updated.speakers.first { $0.id == updated.transcript[0].speakerID })
        #expect(projected.personID == personID)
        #expect(projected.manuallyAssigned == true)
        #expect(projected.voiceReviewExampleID == reviewed.id)
        #expect(updated.transcript[1].speakerID != projected.id)
        #expect(store.voiceLibrary.examples.first { $0.id == reviewed.id }?.review == .confirmed)
    }

    @Test func observationTaskPersistsActualMethodAndPreservesOnlyReviewedPassage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, original, audio) = try await fixture(root: root)
        let personID = await store.addPerson(name: "Alex")
        let speaker = try #require(original.speakers.first)
        let reviewed = VoiceExample(
            meetingID: original.id, speakerID: speaker.id, source: "microphone",
            audioFile: "microphone.wav", audioRevision: VoiceLibraryStore.revision(url: audio),
            start: 0, end: 3, personID: personID, review: .confirmed,
            embeddings: [try #require(speaker.voiceEmbedding)])
        #expect(store.voiceLibrary.upsert([reviewed]))
        var configuration = SpeakerConsolidation.Configuration()
        configuration.observationPolicy = .init()
        try await store.performSpeakerConsolidation(id: original.id, configuration: configuration)
        let updated = try #require(store.meeting(id: original.id))
        let resultID = try #require(updated.speakerLabelSource?.resultID)
        let folder = store.directory(for: original.id)
        let labels = try JSONDecoder().decode(
            LocalDiarizationResult.self,
            from: Data(contentsOf: folder.appendingPathComponent("speaker-labels-\(resultID).json")))
        #expect(labels.modelRevision != SpeakerConsolidation.revision)
        #expect(labels.speakers.allSatisfy { !original.speakers.map(\.id).contains($0.id) && $0.personID == nil })
        let receipt = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: folder.appendingPathComponent("speaker-consolidation-\(resultID).json")))
                as? [String: Any])
        let savedConfiguration = try #require(receipt["configuration"] as? [String: Any])
        #expect(savedConfiguration["observationPolicy"] as? [String: Any] != nil)
        let analysis = try #require(receipt["analysis"] as? [String: Any])
        let audit = try #require(analysis["audit"] as? [String: Any])
        #expect(audit["method"] as? String == labels.modelRevision)
        let first = try #require(updated.speakers.first { $0.id == updated.transcript[0].speakerID })
        let second = try #require(updated.speakers.first { $0.id == updated.transcript[1].speakerID })
        #expect(first.personID == personID && first.manuallyAssigned == true)
        #expect(first.voiceReviewExampleID == reviewed.id)
        #expect(second.personID == nil)
        let disk = try MeetingFolderStorage.read(id: original.id, directory: root)
        #expect(disk.transcript == updated.transcript)
    }

}
