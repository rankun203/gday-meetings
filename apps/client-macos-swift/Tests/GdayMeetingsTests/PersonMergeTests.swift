import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct PersonMergeTests {
    @Test(arguments: [false, true])
    func multiplePeopleMergeAsOneTransaction(failSave: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let first = store.addPerson(name: "Alex One")
        let second = store.addPerson(name: "Alex Two")
        let kept = store.addPerson(name: "Alex")
        let unrelated = store.addPerson(name: "Sam")
        let older = store.createMeeting(title: "Older synthetic meeting")
        let newer = store.createMeeting(title: "Newer synthetic meeting")
        for id in [older, newer] {
            var meeting = try #require(store.meeting(id: id))
            meeting.personIDs = [first, second, kept, unrelated]
            #expect(store.updateMeeting(meeting))
        }
        #expect(
            store.voiceLibrary.upsert([
                VoiceExample(
                    meetingID: newer, speakerID: UUID(), source: "system", personID: first, review: .confirmed),
                VoiceExample(
                    meetingID: older, speakerID: UUID(), source: "system", personID: second, review: .confirmed),
            ]))
        store.clearLoadedMeetingCache()
        if failSave {
            try Data("broken".utf8).write(to: store.directory(for: older).appendingPathComponent("content.json"))
        }
        #expect(!store.mergePeople(ids: [first, second], into: unrelated))
        #expect(store.mergePeople(ids: [first, second, kept], into: kept) == !failSave)
        let diskPeople = try FileEntityStorage.load(Person.self, kind: "people", directory: root)
        #expect(Set(diskPeople.map(\.id)) == (failSave ? [first, second, kept, unrelated] : [kept, unrelated]))
        let meeting = try MeetingFolderStorage.read(id: newer, directory: root)
        #expect(Set(meeting.personIDs) == (failSave ? [first, second, kept, unrelated] : [kept, unrelated]))
        let voices = VoiceLibraryStore(directory: root)
        #expect(Set(voices.examples.compactMap(\.personID)) == (failSave ? [first, second] : [kept]))
    }

    @Test func metadataOnlyMeetingAndLoadedMeetingBothMerge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let source = store.addPerson(name: "Alex")
        let target = store.addPerson(name: "Alex")
        let unloaded = store.createMeeting(title: "Metadata only")
        var first = try #require(store.meeting(id: unloaded))
        first.personIDs = [source]
        #expect(store.updateMeeting(first))
        let contentURL = store.directory(for: unloaded).appendingPathComponent("content.json")
        store.clearLoadedMeetingCache()
        try FileManager.default.removeItem(at: contentURL)
        let loaded = store.createMeeting(title: "Loaded meeting")
        var second = try #require(store.meeting(id: loaded))
        second.personIDs = [source]
        #expect(store.updateMeeting(second))
        #expect(!store.mergePerson(id: source, into: source))
        #expect(store.mergePerson(id: source, into: target))
        #expect(store.meeting(id: loaded)?.personIDs == [target])
        #expect(try MeetingFolderStorage.read(id: unloaded, directory: root).personIDs == [target])
        #expect(!FileManager.default.fileExists(atPath: contentURL.path))
    }

    @Test func voiceMergeKeepsReviewStateAndResolvesConflictingRejections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = VoiceLibraryStore(directory: root)
        let source = UUID()
        let target = UUID()
        let confirmed = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", personID: source,
            review: .confirmed, rejectedPersonIDs: [target])
        let suggested = VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", suggestedPersonID: source,
            review: .suggested, rejectedPersonIDs: [target])
        #expect(library.upsert([confirmed, suggested]))
        #expect(library.mergePerson(id: source, into: target))
        let reopened = VoiceLibraryStore(directory: root)
        let kept = try #require(reopened.examples.first { $0.id == confirmed.id })
        #expect(kept.personID == target && kept.review == .confirmed && kept.rejectedPersonIDs.isEmpty)
        let pending = try #require(reopened.examples.first { $0.id == suggested.id })
        #expect(pending.personID == nil && pending.suggestedPersonID == nil)
        #expect(pending.review != .confirmed && pending.rejectedPersonIDs == [target])
    }

    @Test func mergePreservesRelationshipsAcrossPagesAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let sourceID = store.addPerson(name: "Alex")
        let targetID = store.addPerson(name: "Alex")
        let tag = store.addTag(name: "Team")
        var source = try #require(store.people.first { $0.id == sourceID })
        source.email = "alex.old@example.invalid"
        source.notes = "Source note"
        source.tagIDs = [tag]
        source.voiceSamples = [.init(meetingID: UUID(), speakerID: UUID(), scope: "synthetic", embedding: [1, 0])]
        var target = try #require(store.people.first { $0.id == targetID })
        target.email = "alex@example.invalid"
        target.notes = "Target note"
        store.updatePerson(source)
        store.updatePerson(target)
        var ids: [UUID] = []
        for index in 0..<25 {
            let id = store.createMeeting(title: "Synthetic meeting \(index)")
            ids.append(id)
            var meeting = try #require(store.meeting(id: id))
            meeting.personIDs = [sourceID, targetID]
            meeting.speakers = [
                MeetingSpeaker(
                    label: "Speaker 1", track: "system", providerName: "Synthetic", personID: sourceID,
                    confirmed: true, manuallyAssigned: true)
            ]
            meeting.transcript = [.init(start: 0, end: 1, speaker: "Speaker 1", text: "Synthetic passage")]
            #expect(store.updateMeeting(meeting))
        }
        let example = VoiceExample(
            meetingID: ids[0], speakerID: UUID(), source: "system", personID: sourceID,
            review: .confirmed)
        #expect(store.voiceLibrary.upsert([example]))
        #expect(store.voiceLibrary.assign(meetingID: ids[0], speakerID: example.speakerID, personID: sourceID))
        // Install the projection after voice review has reconciled its assignments.
        #expect(store.ensureMeetingLoaded(id: ids[0]))
        var projected = try #require(store.meetings.first { $0.id == ids[0] })
        projected.personIDs = [targetID]
        projected.speakers[0].personID = targetID
        projected.speakers[0].manuallyAssigned = true
        projected.speakers[0].voiceReviewOrigin = .init(speakerID: UUID(), personID: sourceID)
        #expect(store.updateMeeting(projected))
        let chat = ChatMessage(content: "Synthetic question")
        store.saveContextChat(key: MeetingStore.contextChatKey(personID: sourceID), messages: [chat])
        store.clearLoadedMeetingCache()
        #expect(store.mergePerson(id: sourceID, into: targetID))
        #expect(store.meetings.isEmpty)
        let reopened = MeetingStore(dataDirectory: root)
        #expect(reopened.people.count == 1)
        let person = try #require(reopened.people.first)
        #expect(person.id == targetID && person.email == target.email && person.tagIDs == [tag])
        #expect(person.notes.contains(source.notes) && person.notes.contains(target.notes))
        #expect(person.notes.contains(source.email))
        #expect(person.voiceSamples == source.voiceSamples)
        #expect(reopened.contextualChats[MeetingStore.contextChatKey(personID: targetID)] == [chat])
        #expect(reopened.voiceLibrary.examples.first?.personID == targetID)
        #expect(reopened.voiceLibrary.decisions.first?.personID == targetID)
        #expect(!reopened.voiceLibrary.canUndo)
        for id in ids {
            let meeting = try MeetingFolderStorage.read(id: id, directory: root)
            #expect(meeting.personIDs == [targetID])
            #expect(meeting.speakers.first?.personID == targetID)
            #expect(meeting.speakers.first?.manuallyAssigned == true)
            #expect(meeting.transcript.first?.text == "Synthetic passage")
            if id == ids[0] { #expect(meeting.speakers.first?.voiceReviewOrigin?.personID == targetID) }
        }
        #expect(try reopened.libraryIndex?.count(personID: sourceID) == 0)
        #expect(try reopened.libraryIndex?.count(personID: targetID) == 25)
    }

    @Test func failedMergeRollsBackPeopleVoicesAndMeetingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(dataDirectory: root)
        let sourceID = store.addPerson(name: "Alex")
        let targetID = store.addPerson(name: "Alex")
        let older = store.createMeeting(title: "Older")
        let newer = store.createMeeting(title: "Newer")
        for id in [older, newer] {
            var meeting = try #require(store.meeting(id: id))
            meeting.personIDs = [sourceID]
            #expect(store.updateMeeting(meeting))
        }
        let example = VoiceExample(
            meetingID: newer, speakerID: UUID(), source: "system", personID: sourceID,
            review: .confirmed)
        #expect(store.voiceLibrary.upsert([example]))
        store.clearLoadedMeetingCache()
        let brokenURL = store.directory(for: older).appendingPathComponent("content.json")
        try Data("broken".utf8).write(to: brokenURL)
        #expect(!store.mergePerson(id: sourceID, into: targetID))
        #expect(store.people.count == 2)
        #expect(store.voiceLibrary.examples.first?.personID == sourceID)
        #expect(try MeetingFolderStorage.read(id: newer, directory: root).personIDs == [sourceID])
        #expect(try FileEntityStorage.load(Person.self, kind: "people", directory: root).count == 2)
        #expect(try String(contentsOf: brokenURL, encoding: .utf8) == "broken")
    }

    @Test func hiddenOriginsAndContactConflictsArePreserved() {
        let source = Person(name: "Alex Example", email: "alex@example.invalid", notes: "A note")
        let target = Person(name: "Alex", notes: "A note")
        let merged = PersonMerge.combining(source, into: target)
        #expect(merged.email == source.email)
        #expect(merged.notes == "A note\n\nAlso known as: Alex Example")
        var meeting = Meeting()
        meeting.speakers = [
            .init(
                label: "Speaker 1", track: "system", providerName: "Synthetic",
                voiceReviewOrigin: .init(speakerID: UUID(), personID: source.id))
        ]
        PersonMerge(sourceID: source.id, targetID: target.id).apply(to: &meeting)
        #expect(meeting.speakers.first?.voiceReviewOrigin?.personID == target.id)
    }
}
