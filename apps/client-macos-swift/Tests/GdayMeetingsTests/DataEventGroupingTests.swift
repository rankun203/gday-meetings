import Foundation
import Testing

@testable import GdayMeetings

struct DataEventGroupingTests {
    private let firstTarget = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondTarget = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func sameNameProvidersStaySeparateAndRenamesKeepHistory() throws {
        let first = event(targetID: firstTarget, name: "Example Provider", time: 1)
        let renamed = event(targetID: firstTarget, name: "Renamed Provider", time: 3)
        let second = event(targetID: secondTarget, name: "Example Provider", time: 2)
        let groups = DataEventGroup.groups([first, renamed, second])
        #expect(groups.count == 2)
        let shared = try #require(groups.first)
        #expect(shared.events.map(\.id) == [renamed.id, first.id])
        #expect(shared.destination.targetName == "Renamed Provider")
        #expect(shared.id == DataEventGroup.groups([first]).first?.id)
        #expect(groups.last?.events.map(\.id) == [second.id])
    }

    @Test func endpointDomainAndLocationStayDistinctForOneProvider() {
        let original = event(targetID: firstTarget, time: 1)
        var newDomain = event(targetID: firstTarget, time: 2)
        newDomain.dataFlow.domain = "other.example.invalid"
        var local = event(targetID: firstTarget, time: 3)
        local.dataFlow.location = .local
        #expect(DataEventGroup.groups([original, newDomain, local]).count == 3)
    }

    @Test func legacyProvidersNeverMergeBasedOnNamesOrDomains() throws {
        let current = event(targetID: firstTarget, name: "This Mac", time: 1)
        let first = try legacy(current)
        var second = first
        second.id = UUID()
        let groups = DataEventGroup.groups([first, second])
        #expect(groups.count == 2)
        #expect(Set(groups.compactMap { $0.destination.legacyEventID }) == [first.id, second.id])
        #expect(groups.allSatisfy { $0.destination.targetID == nil && $0.events.count == 1 })
    }

    @Test func actionAndExactBodyDistinguishGroupsWithoutParsingFilenames() {
        let sent = event(
            targetID: firstTarget, bodies: ["notes (draft).md", "notes.md", "content.json (chat)"], time: 1)
        var received = sent
        received.id = UUID()
        received.action = .received
        var language = event(targetID: firstTarget, bodies: ["content.json (language)"], time: 2)
        language.dataFlow.purpose = "Summary"
        let groups = DataEventGroup.groups([sent, received, language])
        #expect(groups.count == 7)
        #expect(groups.filter { $0.file == "notes (draft).md" }.count == 2)
        #expect(groups.filter { $0.file == "content.json (chat)" }.count == 2)
        #expect(groups.filter { $0.file == "content.json (language)" }.count == 1)
    }

    @Test func multipleBodiesRetainWholeReceiptWithoutDuplicateOccurrences() {
        var shared = event(targetID: firstTarget, bodies: ["notes.md", "transcript.json", "notes.md"], time: 1)
        shared.dataFlow.requestBytes = 100
        let groups = DataEventGroup.groups([shared, shared])
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.events == [shared] })
        #expect(groups.allSatisfy { $0.events[0].dataFlow.bodies.count == 3 })
        // The full request is visible in either group; no per-file byte claim is made.
        #expect(groups.allSatisfy { $0.events[0].dataFlow.requestBytes == 100 })
    }

    @Test func latestLiveRevisionReplacesReceiptAndPreservesGroupIdentity() throws {
        var started = event(targetID: firstTarget, bodies: ["System Audio"], time: 1)
        started.dataFlow.endedAt = nil
        var ended = started
        ended.dataFlow.endedAt = Date(timeIntervalSince1970: 90)
        ended.dataFlow.responseBytes = 80
        let before = try #require(DataEventGroup.groups([started]).first)
        let after = try #require(DataEventGroup.groups([started, ended]).first)
        #expect(after.id == before.id)
        #expect(after.events == [ended])
        // A replacement's bodies supersede the earlier list rather than leaving stale groups.
        var corrected = ended
        corrected.dataFlow.bodies = ["Microphone"]
        #expect(DataEventGroup.groups([started, ended, corrected]).map(\.file) == ["Microphone"])
    }

    @Test func sortingAndGroupIDsAreDeterministicAcrossInputOrder() {
        let first = event(targetID: firstTarget, bodies: ["notes.md", "transcript.json"], time: 1)
        let newer = event(targetID: firstTarget, bodies: ["notes.md"], time: 3)
        let equalTime = event(targetID: secondTarget, bodies: ["summary.md"], time: 3)
        let input = [first, newer, equalTime]
        let groups = DataEventGroup.groups(input)
        #expect(groups == DataEventGroup.groups(input.reversed()))
        #expect(groups.last?.file == "transcript.json")
        #expect(groups.first(where: { $0.file == "notes.md" })?.events.map(\.id) == [newer.id, first.id])
    }

    @Test func missingBodyAndEmptyBodyStayVisibleAndDistinct() {
        let missing = event(targetID: firstTarget, bodies: [], time: 1)
        let empty = event(targetID: firstTarget, bodies: [""], time: 2)
        let groups = DataEventGroup.groups([missing, empty])
        #expect(groups.count == 2)
        #expect(groups.first?.file == "")
        #expect(groups.last?.file == "")
    }

    @Test func explicitPathsGroupAnnotatedBodiesByFileAndPreserveReceiptDetails() throws {
        var upload = event(targetID: firstTarget, bodies: ["audio (draft).opus (converted to WAV for upload)"], time: 1)
        upload.dataFlow.filePaths = ["audio (draft).opus"]
        var linked = event(
            targetID: firstTarget, bodies: ["audio (draft).opus (audio download link)", "language"], time: 2)
        linked.dataFlow.filePaths = ["audio (draft).opus", "audio (draft).opus"]
        let groups = DataEventGroup.groups([upload, linked])
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.file == "audio (draft).opus")
        #expect(group.isFile)
        #expect(group.events == [linked, upload])
        #expect(group.latest == linked)
        #expect(group.latest.dataFlow.bodies.contains("language"))
    }

    @Test func matchingBodyLabelsDoNotBecomeExplicitFileReferences() {
        let body = event(targetID: firstTarget, bodies: ["notes.md"], time: 1)
        var file = event(targetID: firstTarget, bodies: ["notes.md"], time: 2)
        file.dataFlow.filePaths = ["notes.md"]
        let groups = DataEventGroup.groups([body, file])
        #expect(groups.count == 2)
        #expect(groups.first?.isFile == true)
        #expect(groups.last?.isFile == false)
        #expect(groups.first?.file == groups.last?.file)
    }

    @Test func legacySavedFilesUseSeparateStorageIdentityAndExactPaths() throws {
        var first = event(targetID: firstTarget, name: "This Mac", bodies: ["notes (draft).md"], time: 1)
        first.action = .modified
        first.dataFlow.location = .local
        first.dataFlow.domain = nil
        first.dataFlow.purpose = "Saved file"
        first = try legacy(first)
        var second = first
        second.id = UUID()
        second.dataFlow.startedAt = Date(timeIntervalSince1970: 2)
        var modern = event(targetID: ThisMacProvider.id, name: "This Mac", bodies: ["notes (draft).md"], time: 3)
        modern.action = .modified
        modern.dataFlow.location = .local
        modern.dataFlow.domain = nil
        modern.dataFlow.purpose = "Saved file"
        modern.dataFlow.filePaths = ["notes (draft).md"]
        let groups = DataEventGroup.groups([first, second, modern])
        #expect(groups.count == 2)
        let old = try #require(groups.first { $0.destination.legacyLocalStorage })
        #expect(old.events == [second, first])
        #expect(old.isFile)
        #expect(old.file == "notes (draft).md")
        #expect(old.destination.targetID == nil)
        #expect(old.id == DataEventGroup.groups([first]).first?.id)
        #expect(old.id != groups.first?.id)
    }

    @Test func legacyStorageCompatibilityRequiresEverySchemaPredicate() throws {
        var saved = event(targetID: firstTarget, name: "This Mac", time: 1)
        saved.action = .created
        saved.dataFlow.location = .local
        saved.dataFlow.domain = nil
        saved.dataFlow.purpose = "Saved file"
        saved = try legacy(saved)
        var candidates = [MeetingDataEvent](repeating: saved, count: 5)
        candidates[0].dataFlow.location = .remote
        candidates[1].dataFlow.domain = "localhost"
        candidates[2].action = .sent
        candidates[3].dataFlow.purpose = "Live transcription"
        candidates[4].dataFlow.targetName = "Local Provider"
        for candidate in candidates {
            var repeated = candidate
            repeated.id = UUID()
            let groups = DataEventGroup.groups([candidate, repeated])
            #expect(groups.count == 2)
            #expect(groups.allSatisfy { !$0.destination.legacyLocalStorage && !$0.isFile })
        }
    }

    private func legacy(_ event: MeetingDataEvent) throws -> MeetingDataEvent {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        var flow = try #require(json["dataFlow"] as? [String: Any])
        flow.removeValue(forKey: "targetID")
        flow.removeValue(forKey: "filePaths")
        json["dataFlow"] = flow
        return try JSONDecoder().decode(MeetingDataEvent.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func event(
        targetID: UUID, name: String = "Example Provider", bodies: [String] = ["notes.md"], time: TimeInterval
    ) -> MeetingDataEvent {
        MeetingDataEvent(
            action: .sent,
            dataFlow: DataFlow(
                location: .remote, targetID: targetID, targetName: name, domain: "provider.example.invalid",
                startedAt: Date(timeIntervalSince1970: time), endedAt: Date(timeIntervalSince1970: time + 0.5),
                bodies: bodies, purpose: "Summary"))
    }
}
