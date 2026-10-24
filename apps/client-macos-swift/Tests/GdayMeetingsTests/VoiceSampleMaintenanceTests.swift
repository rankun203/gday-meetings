import Foundation
import Testing

@testable import GdayMeetings

struct VoiceSampleMaintenanceTests {
    @Test func ignoredAndUnplayableEvidenceRemainReachableOutsideReviewQueue() {
        let person = UUID()
        var ignored = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        ignored.namedPersonID = person
        ignored.excluded = true
        var rejected = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "microphone")
        rejected.rejectedPersonIDs = [person]
        rejected.review = .rejected
        let unnamed = VoiceExample(meetingID: UUID(), speakerID: UUID(), source: "system")
        let evidence = [ignored, rejected, unnamed]
        #expect(VoiceSampleMaintenance.examples(evidence, personID: nil, ignoredOnly: false).count == 3)
        #expect(
            Set(VoiceSampleMaintenance.examples(evidence, personID: person, ignoredOnly: false).map(\.id)) == [
                ignored.id, rejected.id,
            ])
        #expect(
            VoiceSampleMaintenance.examples(evidence, personID: person, ignoredOnly: true).map(\.id) == [ignored.id])
        #expect(VoiceSampleMaintenance.examples(evidence, personID: UUID(), ignoredOnly: false).isEmpty)
    }

    @Test @MainActor func restoringAndClearingPersistWithGuardedCrossSessionUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func openStore() async -> MeetingStore {
            let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
            await store.libraryMonitor?.stop()
            store.libraryMonitor = nil
            store.voiceLibrary.didChange = nil
            return store
        }
        let store = await openStore()
        let person = await store.addPerson(name: "Alex")
        let meeting = UUID()
        let folder = try MeetingFolderLocation.newFolder(id: meeting, date: Date(), directory: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("synthetic audio".utf8).write(to: audio)
        let sample = VoiceExample(
            meetingID: meeting, speakerID: UUID(), source: "system",
            audioFile: "system.wav", audioRevision: VoiceLibraryStore.revision(url: audio), start: 0, end: 4)
        #expect(store.voiceLibrary.upsert([sample]))
        #expect(await store.reviewVoiceExamples(.confirm(ids: [sample.id], personID: person)))
        #expect(await store.reviewVoiceExamples(.exclude(ids: [sample.id], excluded: true)))

        let ignoredStore = await openStore()
        let ignored = try #require(
            VoiceSampleMaintenance.examples(
                ignoredStore.voiceLibrary.examples,
                personID: person, ignoredOnly: true
            ).first)
        #expect(
            await ignoredStore.reviewVoiceExamples(
                .exclude(ids: [ignored.id], excluded: false), expectedExamples: [ignored]))
        let restoredStore = await openStore()
        let restored = try #require(restoredStore.voiceLibrary.examples.first)
        #expect(!restored.excluded)
        #expect(restored.personID == person)
        #expect(restored.review == .confirmed)
        let restoreUndo = try #require(restoredStore.voiceLibrary.reviewUndoID)
        #expect(await restoredStore.reviewVoiceExamples(.undo, expectedUndoID: restoreUndo))
        let undoneStore = await openStore()
        let undone = try #require(undoneStore.voiceLibrary.examples.first)
        #expect(undone.excluded)
        #expect(undone.personID == person)
        #expect(
            await undoneStore.reviewVoiceExamples(
                .exclude(ids: [sample.id], excluded: false), expectedExamples: [undone]))
        let beforeClear = try #require(undoneStore.voiceLibrary.examples.first)
        #expect(await undoneStore.reviewVoiceExamples(.clear(ids: [sample.id]), expectedExamples: [beforeClear]))
        let clearedStore = await openStore()
        let cleared = try #require(
            VoiceSampleMaintenance.examples(
                clearedStore.voiceLibrary.examples,
                personID: nil, ignoredOnly: false
            ).first)
        #expect(!cleared.excluded)
        #expect(cleared.personID == nil)
        #expect(cleared.manuallyCleared)
        #expect(cleared.rejectedPersonIDs.isEmpty)
        #expect(try await clearedStore.voiceLibrary.reviewCandidates(for: person).isEmpty)
        #expect(try await clearedStore.voiceLibrary.identificationGroups().isEmpty)
        // A later edit replaces the immediate Undo opportunity. The stored
        // sample must still support naming when reopened for maintenance.
        var other = sample
        other.id = UUID()
        other.speakerID = UUID()
        other.start = 8
        other.end = 12
        #expect(clearedStore.voiceLibrary.upsert([other]))
        #expect(await clearedStore.reviewVoiceExamples(.exclude(ids: [other.id], excluded: true)))
        let namingStore = await openStore()
        let original = try #require(
            VoiceSampleMaintenance.examples(
                namingStore.voiceLibrary.examples,
                personID: nil, ignoredOnly: false
            ).first { $0.id == sample.id })
        #expect(
            await namingStore.reviewVoiceExamples(
                .confirm(ids: [original.id], personID: person), expectedExamples: [original]))
        let namedStore = await openStore()
        let named = try #require(namedStore.voiceLibrary.examples.first { $0.id == sample.id })
        #expect(named.personID == person)
        #expect(named.review == .confirmed)
        #expect(!named.manuallyCleared)

    }
    @Test @MainActor func creatingPersonRestoresSingleIgnoredOrClearedExcerptAndUndoSurvivesReopening() async throws {
        for ignored in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            func openStore() async -> MeetingStore {
                let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
                await store.libraryMonitor?.stop()
                store.libraryMonitor = nil
                store.voiceLibrary.didChange = nil
                return store
            }
            let store = await openStore()
            let meeting = UUID()
            let folder = try MeetingFolderLocation.newFolder(id: meeting, date: Date(), directory: root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let audio = folder.appendingPathComponent("system.wav")
            try Data("synthetic audio".utf8).write(to: audio)
            let sample = VoiceExample(
                meetingID: meeting, speakerID: UUID(), source: "system",
                audioFile: "system.wav", audioRevision: VoiceLibraryStore.revision(url: audio), start: 0, end: 4)
            var alias = sample
            alias.id = UUID()
            alias.speakerID = UUID()
            alias.groupID = UUID()
            #expect(store.voiceLibrary.upsert([sample, alias]))
            if ignored {
                #expect(await store.reviewVoiceExamples(.exclude(ids: [sample.id], excluded: true)))
            }
            else {
                #expect(await store.reviewVoiceExamples(.clear(ids: [sample.id, alias.id])))
            }
            let before = await openStore()
            let anchor = try #require(before.voiceLibrary.examples.first { $0.id == sample.id })
            let receipt = try #require(
                await before.nameVoiceGroupResult(
                    exampleIDs: [anchor.id],
                    confirmedExampleID: anchor.id, personID: nil, newPersonName: "New Person",
                    expectedExamples: [anchor]))
            await before.flushVoiceAssignmentRefresh()
            let person = try #require(receipt.personID)
            let reopened = await openStore()
            #expect(
                reopened.voiceLibrary.examples.allSatisfy {
                    $0.personID == person && $0.review == .confirmed && !$0.excluded && !$0.manuallyCleared
                })
            #expect(reopened.people.contains { $0.id == person })
            let undo = try #require(reopened.voiceLibrary.reviewUndoID)
            #expect(await reopened.reviewVoiceExamples(.undo, expectedUndoID: undo))
            await reopened.flushVoiceAssignmentRefresh()
            let undone = await openStore()
            #expect(!undone.people.contains { $0.id == person })
            #expect(
                undone.voiceLibrary.examples.allSatisfy {
                    $0.personID == nil && $0.excluded == ignored && $0.manuallyCleared == !ignored
                })
            var fresh = sample
            fresh.id = UUID()
            fresh.speakerID = UUID()
            fresh.start = 8
            fresh.end = 12
            #expect(undone.voiceLibrary.upsert([fresh]))
            let groupEvidence = undone.voiceLibrary.examples
            let groupName = try #require(
                await undone.nameVoiceGroupResult(
                    exampleIDs: Set(groupEvidence.map(\.id)), confirmedExampleID: fresh.id,
                    personID: nil, newPersonName: "Another Person", expectedExamples: groupEvidence))
            await undone.flushVoiceAssignmentRefresh()
            let groupPerson = try #require(groupName.personID)
            let groupReopened = await openStore()
            #expect(groupReopened.voiceLibrary.examples.first { $0.id == fresh.id }?.personID == groupPerson)
            #expect(
                groupReopened.voiceLibrary.examples.filter { $0.id != fresh.id }.allSatisfy {
                    $0.personID == nil && $0.excluded == ignored && $0.manuallyCleared == !ignored
                })

        }
    }

}
