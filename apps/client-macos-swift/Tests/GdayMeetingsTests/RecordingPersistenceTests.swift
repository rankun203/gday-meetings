import Foundation
import Testing

@testable import GdayMeetings

struct RecordingPersistenceTests {
    @Test func finalizationPreservesIndependentDiskChanges() throws {
        let base = Meeting(title: "Synthetic recording")
        var proposed = base
        proposed.duration = 120
        var disk = base
        disk.title = "Updated title"
        disk.tagIDs = [UUID()]
        disk.summary = "Saved summary"
        let merged = try RecordingMeetingMerge.merge(baseline: base, proposed: proposed, disk: disk)
        #expect(merged.duration == 120)
        #expect(merged.title == disk.title)
        #expect(merged.tagIDs == disk.tagIDs)
        #expect(merged.summary == disk.summary)
    }

    @Test func conflictingCaptureChangesAreNotOverwritten() throws {
        let base = Meeting(title: "Synthetic recording")
        var proposed = base
        proposed.duration = 120
        var disk = base
        disk.duration = 90
        #expect(throws: (any Error).self) {
            try RecordingMeetingMerge.merge(baseline: base, proposed: proposed, disk: disk)
        }
    }

    @Test func laterLocalEditKeepsOtherCommittedFields() throws {
        let captured = Meeting(title: "Captured")
        var current = captured
        current.title = "Later local edit"
        var committed = captured
        committed.title = "Disk edit"
        committed.tagIDs = [UUID()]
        let updated = try RecordingMeetingMerge.merge(
            baseline: captured, proposed: current, disk: committed, preferProposedOnConflict: true)
        #expect(updated.title == current.title)
        #expect(updated.tagIDs == committed.tagIDs)
    }

    @Test func laterLocalChangesKeepRelatedFieldsTogether() throws {
        let base = Meeting(title: "Synthetic recording")
        var local = base
        local.transcript = [.init(start: 0, end: 1, speaker: "System", text: "Local words")]
        local.audioFiles = ["local.wav"]
        local.completedTaskIDs["summary"] = UUID()
        var committed = base
        committed.transcriptSource = .init(id: UUID(), providerName: "Synthetic provider", generatedAt: Date())
        committed.audioFiles = ["other.wav"]
        committed.completedTaskIDs["summary"] = UUID()
        committed.tagIDs = [UUID()]
        let merged = try RecordingMeetingMerge.merge(
            baseline: base, proposed: local, disk: committed, preferProposedOnConflict: true)
        #expect(merged.transcript == local.transcript)
        #expect(merged.transcriptSource == local.transcriptSource)
        #expect(merged.audioFiles == local.audioFiles)
        #expect(merged.recordingProfile == local.recordingProfile)
        #expect(merged.completedTaskIDs["summary"] == local.completedTaskIDs["summary"])
        #expect(merged.tagIDs == committed.tagIDs)
    }

    @Test func newRecordingDoesNotReplaceExistingFolderMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = Meeting(title: "Existing meeting")
        try MeetingFolderStorage.write(existing, directory: root)
        var proposed = existing
        proposed.title = "New recording"
        let result = CanonicalLibraryWriter.write(
            .init(
                current: .init(meetings: [proposed]), previous: .init(), directory: root,
                indexIsBuilding: false, reconcileMeetingID: proposed.id))
        #expect(!result.committed)
        #expect(try MeetingFolderStorage.read(id: existing.id, directory: root).title == existing.title)
    }

    @Test func derivedPersonIDsDoNotCauseFalseConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var baseline = Meeting(title: "Synthetic recording")
        baseline.speakers = [.init(label: "Speaker", track: "system", providerName: "Synthetic", personID: UUID())]
        try MeetingFolderStorage.write(baseline, directory: root)
        var proposed = baseline
        proposed.duration = 20
        var external = baseline
        external.title = "External title"
        try MeetingFolderStorage.write(external, directory: root)
        let result = CanonicalLibraryWriter.write(
            .init(
                current: .init(meetings: [proposed]), previous: .init(meetings: [baseline]), directory: root,
                recordingID: baseline.id, indexIsBuilding: false, reconcileMeetingID: baseline.id))
        #expect(result.committed, Comment(rawValue: result.error ?? ""))
        #expect(try MeetingFolderStorage.read(id: baseline.id, directory: root).duration == 20)
    }

    @Test func writerPreservesLiveRowsAndExternalNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let base = Meeting(title: "Synthetic recording")
        try MeetingFolderStorage.write(base, directory: root)
        let folder = MeetingFolderStorage.folder(id: base.id, directory: root)
        let rows = [TranscriptSegment(start: 0, end: 1, speaker: "System", text: "Synthetic speech")]
        try TranscriptStorage.write(rows, at: folder)
        let notes = "Timed note <!-- gday:t=12:34:56 -->"
        try Data(notes.utf8).write(to: folder.appendingPathComponent("notes.md"))
        var disk = base
        disk.title = "Updated title"
        try MeetingFolderStorage.write(disk, directory: root, writeTranscript: false)
        var proposed = base
        proposed.duration = 60
        let result = CanonicalLibraryWriter.write(
            .init(
                current: .init(meetings: [proposed]), previous: .init(meetings: [base]), directory: root,
                recordingID: base.id, indexIsBuilding: false, reconcileMeetingID: base.id))
        #expect(result.committed, Comment(rawValue: result.error ?? ""))
        let saved = try MeetingFolderStorage.read(id: base.id, directory: root)
        #expect(saved.title == disk.title)
        #expect(saved.duration == 60)
        #expect(saved.transcript == rows)
        #expect(saved.notes == notes)
        #expect(result.meetings.first?.title == disk.title)
    }
}

@MainActor struct RecordingScopedPersistenceTests {
    @Test func unrelatedConflictDoesNotBlockRecordingSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let unrelatedID = await store.createMeeting(title: "Other meeting")
        let recordingID = await store.createMeeting(title: "Synthetic recording")
        let unrelated = try #require(store.meeting(id: unrelatedID))
        var external = unrelated
        external.title = "External title"
        try MeetingFolderStorage.write(external, directory: root)
        let unrelatedIndex = try #require(store.meetings.firstIndex { $0.id == unrelatedID })
        store.meetings[unrelatedIndex].title = "Local title"
        let recordingIndex = try #require(store.meetings.firstIndex { $0.id == recordingID })
        store.meetings[recordingIndex].duration = 80
        #expect(await store.enqueueCanonical { await store.performCanonicalSave(meetingID: recordingID) })
        #expect(try MeetingFolderStorage.read(id: recordingID, directory: root).duration == 80)
        #expect(try MeetingFolderStorage.read(id: unrelatedID, directory: root).title == "External title")
        #expect(store.meeting(id: unrelatedID)?.title == "Local title")
    }

    @Test func scopedSaveAdoptsDiskFieldsWithoutLosingEditsWhileWaiting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Synthetic recording")
        var external = try #require(store.meeting(id: id))
        external.title = "External title"
        external.tagIDs = [UUID()]
        try MeetingFolderStorage.write(external, directory: root)
        let index = try #require(store.meetings.firstIndex { $0.id == id })
        store.meetings[index].duration = 50
        let gate = RecordingSaveGate()
        defer { gate.release() }
        store.canonicalWriteHook = { gate.enter() }
        let save = Task { await store.enqueueCanonical { await store.performCanonicalSave(meetingID: id) } }
        try #require(try await waitForMainActorTestCondition(timeout: .seconds(3)) { gate.started })
        store.meetings[index].title = "Later local title"
        gate.release()
        #expect(await save.value)
        store.canonicalWriteHook = nil
        #expect(store.meeting(id: id)?.title == "Later local title")
        #expect(store.meeting(id: id)?.tagIDs == external.tagIDs)
        #expect(await store.enqueueCanonical { await store.performCanonicalSave(meetingID: id) })
        let saved = try MeetingFolderStorage.read(id: id, directory: root)
        #expect(saved.title == "Later local title")
        #expect(saved.tagIDs == external.tagIDs)
    }

    @Test func recoveryDoesNotWriteWhenLibraryIsReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root.appendingPathComponent("current"))
        let id = await store.createMeeting(title: "Synthetic recording")
        let base = try #require(store.meeting(id: id))
        var proposed = base
        proposed.duration = 60
        let folder = store.directory(for: id)
        try RecordingFinalizationRecovery(baseline: base, proposed: proposed).write(at: folder)
        let target = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(
            at: target.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        await store.changeLibraryFolder(to: target, copyCurrent: false)
        try #require(!store.libraryWritable)
        #expect(!(await store.recoverRecordingFinalization(id: id)))
        #expect(try RecordingFinalizationRecovery.read(at: folder) != nil)
        #expect(try MeetingFolderStorage.read(id: id, directory: root.appendingPathComponent("current")).duration == 0)
        store.cancelLibraryFolderChange()
    }

    @Test func savedNotesDoNotBlockMetadataReload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic recording")
        store.editNotes(id: id, text: "Updated note")
        #expect(await store.flushNotes())
        var disk = try MeetingFolderStorage.read(id: id, directory: root)
        disk.title = "External title"
        try MeetingFolderStorage.write(disk, directory: root)
        #expect(await store.reloadExternalLibraryDocuments())
        #expect(store.meeting(id: id)?.title == disk.title)
        #expect(store.meeting(id: id)?.notes == "Updated note")
    }

    @Test func failedFinalizationRetainsRecoverableMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let id = await store.createMeeting(title: "Synthetic recording")
        let baseline = try #require(store.meeting(id: id))
        var external = baseline
        external.duration = 45
        try MeetingFolderStorage.write(external, directory: root)
        let index = try #require(store.meetings.firstIndex { $0.id == id })
        store.meetings[index].duration = 60
        #expect(!(await store.saveRecordingFinalization(id: id)))
        let folder = store.directory(for: id)
        #expect(try RecordingFinalizationRecovery.read(at: folder)?.proposed.duration == 60)
        #expect(store.meeting(id: id)?.duration == 60)
        #expect(try MeetingFolderStorage.read(id: id, directory: root).duration == 45)
        // Once the conflicting edit is resolved, the persisted proposal can be retried.
        try MeetingFolderStorage.write(baseline, directory: root)
        store.meetings[index] = baseline
        #expect(await store.recoverRecordingFinalization(id: id))
        #expect(try MeetingFolderStorage.read(id: id, directory: root).duration == 60)
        #expect(try RecordingFinalizationRecovery.read(at: folder) == nil)
    }
}

private final class RecordingSaveGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var started: Bool { lock.withLock { entered } }
    func enter() {
        lock.withLock { entered = true }
        semaphore.wait()
    }
    func release() { semaphore.signal() }
}
