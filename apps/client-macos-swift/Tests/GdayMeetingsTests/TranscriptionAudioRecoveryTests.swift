import Foundation
import Synchronization
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptionAudioRecoveryTests {
    @Test func replacementPersistsOnceAndPreservesEditsAndPriorAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Synthetic recording")
        let folder = store.directory(for: id)
        let original = folder.appendingPathComponent("microphone.wav")
        try Data([1, 2, 3]).write(to: original)
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = [original.lastPathComponent]
        let provider = ServiceProvider(kind: .appleSpeech)
        var attempt = ProviderTranscriptionAttempt(provider: provider, meeting: meeting)
        try attempt.admit(
            provider: provider,
            audio: AudioAnalysisArtifacts.audio(
                files: [original], revisions: try LocalDiarizationInputPolicy.revisions(for: [original])),
            diarize: false)
        let oldRequest = attempt.analysisRequest
        meeting.transcriptionAttempt = attempt
        #expect(await store.updateMeeting(meeting))
        let staged = root.appendingPathComponent("synthetic.opus")
        try Data([4, 5, 6]).write(to: staged)
        try await store.prepareAppleTranscriptionAudio(id: id) { _ in
            var disk = try MeetingFolderStorage.read(id: id, directory: root)
            disk.summary = "External summary edit"
            try MeetingFolderStorage.write(disk, directory: root)
            // This edit happens while conversion is suspended, before publication.
            await MainActor.run {
                let index = store.meetings.firstIndex { $0.id == id }!
                store.meetings[index].title = "Edited during conversion"
                store.meetings[index].transcript = [.init(start: 0, end: 1, speaker: "System", text: "Edited words")]
            }
            return .init(url: staged, temporary: true)
        }
        let saved = try MeetingFolderStorage.read(id: id, directory: root)
        #expect(saved.audioFiles == ["microphone.opus"])
        #expect(saved.title == "Edited during conversion")
        #expect(saved.transcript.first?.text == "Edited words")
        #expect(saved.summary == "External summary edit")
        #expect(saved.transcriptionAttempt?.supersededAnalysisRequests == [oldRequest!])
        #expect(saved.transcriptionAttempt?.requiresAudioAdmission == true)
        #expect(saved.transcriptionAttempt?.analysisRequest == nil)
        #expect(saved.transcriptionAttempt?.idempotencyKey != attempt.idempotencyKey)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        try await store.prepareAppleTranscriptionAudio(id: id) { source in
            #expect(source.pathExtension == "opus")
            return .init(url: source, temporary: false)
        }
        #expect(try MeetingFolderStorage.read(id: id, directory: root) == saved)
    }

    @Test(arguments: [false, true])
    func failedPublicationKeepsOriginalAndMetadata(_ cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Synthetic recording")
        let original = store.directory(for: id).appendingPathComponent("system.wav")
        try Data([1, 2, 3]).write(to: original)
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = [original.lastPathComponent]
        #expect(await store.updateMeeting(meeting))
        store.canonicalWriteHook = { throw ServiceError("Synthetic failure") }
        let staged = root.appendingPathComponent("synthetic.opus")
        try Data([4, 5, 6]).write(to: staged)
        let operation = Task {
            try await store.prepareAppleTranscriptionAudio(id: id) { _ in
                if cancel { throw CancellationError() }
                return .init(url: staged, temporary: true)
            }
        }
        await #expect(throws: (any Error).self) { try await operation.value }
        #expect(try Data(contentsOf: original) == Data([1, 2, 3]))
        #expect(try MeetingFolderStorage.read(id: id, directory: root).audioFiles == ["system.wav"])
        #expect(store.meeting(id: id)?.audioFiles == ["system.wav"])
    }

    @Test func crashRollbackRestoresAudioAndPermissionsWithoutLeavingReplacement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("system.wav")
        let replacement = root.appendingPathComponent("system.opus")
        let second = root.appendingPathComponent("microphone.m4a")
        let metadata = root.appendingPathComponent("metadata.json")
        try Data([1]).write(to: second)
        try Data("original metadata".utf8).write(to: metadata)
        let bytes = Data(repeating: 7, count: 8 * 1024 * 1024)
        try bytes.write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: original.path)
        var transaction = LibraryFileTransaction(root: root)
        try transaction.remember(original)
        try transaction.remember(replacement)
        try transaction.remember(second)
        try transaction.remember(metadata)
        try Data("updated metadata".utf8).write(to: metadata)
        try Data([8, 9]).write(to: replacement)
        try Data([2]).write(to: second)
        try FileManager.default.removeItem(at: original)
        try LibraryFileTransaction.recover(root: root)
        #expect(try Data(contentsOf: original) == bytes)
        #expect(
            (try FileManager.default.attributesOfItem(atPath: original.path)[.posixPermissions] as? NSNumber)?.intValue
                == 0o600)
        #expect(!FileManager.default.fileExists(atPath: replacement.path))
        #expect(try Data(contentsOf: second) == Data([1]))
        #expect(try String(contentsOf: metadata, encoding: .utf8) == "original metadata")
    }

    @Test(arguments: [false, true])
    func sameExtensionAndOccupiedDestinationAreSafe(_ collision: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Synthetic recording")
        let folder = store.directory(for: id)
        let original = folder.appendingPathComponent(collision ? "microphone.wav" : "microphone.m4a")
        try Data([1]).write(to: original)
        let occupied = folder.appendingPathComponent("microphone.opus")
        if collision { try Data([3]).write(to: occupied) }
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = [original.lastPathComponent]
        #expect(await store.updateMeeting(meeting))
        let staged = root.appendingPathComponent(collision ? "synthetic.opus" : "synthetic.m4a")
        try Data([2]).write(to: staged)
        try await store.prepareAppleTranscriptionAudio(id: id) { _ in .init(url: staged, temporary: true) }
        let saved = try MeetingFolderStorage.read(id: id, directory: root)
        let output = folder.appendingPathComponent(try #require(saved.audioFiles.first))
        #expect(try Data(contentsOf: output) == Data([2]))
        if collision {
            #expect(output.lastPathComponent.hasPrefix("microphone-compatible-"))
            #expect(try Data(contentsOf: occupied) == Data([3]))
        }
        else {
            #expect(output != original)
            #expect(!FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test func revisionConflictAfterMetadataWriteDoesNotRestoreUntouchedAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var originalMeeting = Meeting(title: "Synthetic recording")
        originalMeeting.audioFiles = ["system.wav"]
        try MeetingFolderStorage.write(originalMeeting, directory: root)
        let folder = MeetingFolderStorage.folder(id: originalMeeting.id, directory: root)
        let source = folder.appendingPathComponent("system.wav")
        let staged = root.appendingPathComponent("synthetic.opus")
        try Data([1]).write(to: source)
        try Data([2]).write(to: staged)
        let replacement = CanonicalAudioReplacement(
            meetingID: originalMeeting.id, original: "system.wav", replacement: "system.opus", staged: staged,
            originalRevision: try #require(VoiceLibraryStore.revision(url: source)),
            stagedRevision: try #require(VoiceLibraryStore.revision(url: staged)))
        var updated = originalMeeting
        updated.audioFiles = ["system.opus"]
        let validationCount = Mutex(0)
        let result = CanonicalLibraryWriter.write(
            .init(
                current: .init(meetings: [updated]), previous: .init(meetings: [originalMeeting]), directory: root,
                indexIsBuilding: false, reconcileMeetingID: originalMeeting.id,
                validateInputs: {
                    let count = validationCount.withLock {
                        $0 += 1
                        return $0
                    }
                    if count == 2 {
                        try Data([3, 4, 5]).write(to: source)
                        throw ServiceError("Synthetic concurrent audio edit")
                    }
                }, audioReplacements: [replacement]))
        #expect(!result.committed)
        #expect(try Data(contentsOf: source) == Data([3, 4, 5]))
        #expect(try MeetingFolderStorage.read(id: originalMeeting.id, directory: root).audioFiles == ["system.wav"])
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.opus").path))
    }

    @Test func symbolicLinkedOriginalIsNeverConvertedOrRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let id = await store.createMeeting(title: "Synthetic recording")
        let external = root.appendingPathComponent("external.wav")
        try Data([1, 2, 3]).write(to: external)
        let link = store.directory(for: id).appendingPathComponent("system.wav")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        var meeting = try #require(store.meeting(id: id))
        meeting.audioFiles = [link.lastPathComponent]
        #expect(await store.updateMeeting(meeting))
        await #expect(throws: (any Error).self) {
            try await store.prepareAppleTranscriptionAudio(id: id) { source in
                Issue.record("A symbolic link must not reach the converter")
                return .init(url: source, temporary: false)
            }
        }
        #expect(try Data(contentsOf: external) == Data([1, 2, 3]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == external.path)
    }
}
