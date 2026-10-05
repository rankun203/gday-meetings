import Foundation
import Testing

@testable import GdayMeetings

struct SearchProviderTests {
    @Test func rankedTextPagesUseRelevanceAndOffsetCursor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Retrieval fixture")
        meeting.transcript = [
            .init(start: 2, end: 3, text: "parcel parcel parcel"),
            .init(start: 4, end: 5, text: "parcel parcel parcel"),
        ]
        var other = Meeting(title: "Another fixture")
        other.transcript = [.init(start: 0, end: 1, text: "parcel " + String(repeating: "filler ", count: 100))]
        try MeetingFolderStorage.write(meeting, directory: root)
        try MeetingFolderStorage.write(other, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let provider = LocalTextSearchProvider(index: index)
        var request = ProviderSearchRequest(query: "parcel", limit: 1, ranked: true)
        var first: ProviderSearchSnapshot?
        for try await event in provider.search(request) { first = event.value }
        #expect(first?.results.first?.passage?.start == 2)
        #expect(first?.nextCursor == 1)
        #expect(first?.total == 2)
        request.after = try #require(first?.nextCursor)
        for try await event in provider.search(request) {
            #expect(event.value.results.first?.passage?.start == 0)
        }
    }

    @Test func localProviderEmitsOneFinalPageAndRejectsVoiceMode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var meeting = Meeting(title: "Planning fixture")
        meeting.transcript = [.init(start: 2, end: 5, text: "Planning a delivery")]
        try MeetingFolderStorage.write(meeting, directory: root)
        let index = try LibraryIndex(directory: root)
        try index.rebuild()
        let provider = LocalTextSearchProvider(index: index)
        let request = ProviderSearchRequest(query: "Planning")
        var events: [ProviderSearchSnapshot] = []
        for try await event in provider.search(request) {
            #expect(event.dataFlow.location == .local)
            #expect(event.dataFlow.targetID == LocalTextSearchProvider.id)
            events.append(event.value)
        }
        #expect(events.count == 1)
        #expect(events.first?.isFinal == true)
        #expect(events.first?.requestID == request.id)
        #expect(events.first?.results.count == 2)
        #expect(events.first?.nextCursor == nil)
        do {
            for try await _ in provider.search(.init(query: "quiet voice", mode: .voice)) {}
            Issue.record("Voice mode must not silently run text retrieval")
        }
        catch { #expect(error is SearchProviderError) }
    }

    @Test func fusionBreaksScoreTiesBeforeApplyingLimit() throws {
        let first = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let second = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let request = UUID()
        let text = UUID()
        let voice = UUID()
        var fusion = ReciprocalRankFusion(requestID: request, weights: [text: 1, voice: 1])
        for (provider, meetings) in [(text, [second, first]), (voice, [first, second])] {
            let results = meetings.map { meetingID in
                ProviderSearchResult(
                    id: meetingID.uuidString, meetingID: meetingID, title: "Tie fixture", excerpt: "Match",
                    sourceRevision: nil, passage: nil)
            }
            fusion.accept(
                .init(
                    requestID: request, providerID: provider, sequence: 0, results: results,
                    total: 2, nextCursor: nil, isFinal: true))
        }
        #expect(fusion.results(limit: 2).map(\.meetingID) == [first, second])
        #expect(fusion.results(limit: 1).map(\.meetingID) == [first])
        #expect(fusion.results(limit: -1).isEmpty)
    }

    @Test func fusionReplacesSnapshotsAndVotesOncePerMeeting() {
        let request = UUID()
        let text = UUID()
        let voice = UUID()
        let first = UUID()
        let second = UUID()
        var fusion = ReciprocalRankFusion(requestID: request, weights: [text: 1, voice: 1])
        func hit(_ meeting: UUID, _ id: String) -> ProviderSearchResult {
            .init(id: id, meetingID: meeting, title: "Fixture", excerpt: "Passage", sourceRevision: "v1", passage: nil)
        }
        func snapshot(_ provider: UUID, _ sequence: Int, _ hits: [ProviderSearchResult], final: Bool = false)
            -> ProviderSearchSnapshot
        {
            .init(
                requestID: request, providerID: provider, sequence: sequence, results: hits, total: nil,
                nextCursor: nil, isFinal: final)
        }
        let acceptedInitial = fusion.accept(snapshot(text, 0, [hit(first, "a"), hit(first, "b"), hit(second, "c")]))
        #expect(acceptedInitial)
        #expect(fusion.results(limit: 10).count == 2)
        #expect(fusion.results(limit: 10).first?.score == 1.0 / 61)
        let acceptedDuplicate = fusion.accept(snapshot(text, 0, [hit(second, "c")]))
        #expect(!acceptedDuplicate)
        let acceptedTextFinal = fusion.accept(snapshot(text, 1, [hit(second, "c"), hit(first, "a")], final: true))
        #expect(acceptedTextFinal)
        let acceptedVoiceFinal = fusion.accept(snapshot(voice, 0, [hit(second, "d")], final: true))
        #expect(acceptedVoiceFinal)
        #expect(fusion.isComplete)
        #expect(fusion.results(limit: 1).first?.meetingID == second)
        #expect(fusion.results(limit: 1).first?.score == 2.0 / 61)
        #expect(fusion.results(limit: 1).first?.evidence.count == 2)
        let acceptedAfterFinal = fusion.accept(snapshot(text, 2, []))
        #expect(!acceptedAfterFinal)
        let stale = ProviderSearchSnapshot(
            requestID: UUID(), providerID: voice, sequence: 9, results: [],
            total: nil, nextCursor: nil, isFinal: true)
        let acceptedStale = fusion.accept(stale)
        #expect(!acceptedStale)
        #expect(fusion.results(limit: 0).isEmpty)
    }
}

private struct FixtureSearchProvider: SearchProvider {
    let descriptor: SearchProviderDescriptor
    let meeting: UUID
    var fails = false
    func search(_ request: ProviderSearchRequest) -> AsyncThrowingStream<ProviderResult<ProviderSearchSnapshot>, Error>
    {
        AsyncThrowingStream { continuation in
            if fails {
                continuation.finish(throwing: SearchProviderError.incompleteResponse)
                return
            }
            continuation.yield(
                .init(
                    value: .init(
                        requestID: request.id, providerID: descriptor.id, sequence: 0,
                        results: [
                            .init(
                                id: "fixture", meetingID: meeting, title: "Fixture", excerpt: "Match",
                                sourceRevision: nil, passage: nil)
                        ],
                        total: 1, nextCursor: nil, isFinal: true),
                    dataFlow: .init(
                        location: .local, targetID: descriptor.id,
                        targetName: descriptor.name, startedAt: Date(), endedAt: Date(), bodies: ["Search query"],
                        purpose: "Test retrieval")))
            continuation.finish()
        }
    }
}

extension SearchProviderTests {
    @MainActor @Test func rankedSessionFinishesWithoutEnablingLegacyPaging() async throws {
        let provider = FixtureSearchProvider(
            descriptor: .init(id: UUID(), name: "Voice fixture", modes: [.voice]), meeting: UUID())
        let session = LibrarySearchSession()
        #expect(session.submit("quiet voice", mode: .voice, providers: [provider]))
        let finished = try await waitForMainActorTestCondition(timeout: .seconds(5)) { !session.isLoading }
        #expect(finished)
        #expect(session.mode == .voice)
        #expect(session.rankedResults.first?.meetingID == provider.meeting)
        #expect(!session.canLoadMore)
        #expect(session.error == nil)
    }

    @Test func fusionStreamsSuccessfulProviderAndReportsFailure() async throws {
        let text = FixtureSearchProvider(
            descriptor: .init(id: UUID(), name: "Text fixture", modes: [.text]), meeting: UUID())
        let voice = FixtureSearchProvider(
            descriptor: .init(id: UUID(), name: "Voice fixture", modes: [.voice]), meeting: UUID(), fails: true)
        var events: [SearchProgress] = []
        for try await event in SearchCoordinator(providers: [text, voice]).search(.init(query: "parcel", mode: .fusion))
        {
            events.append(event)
        }
        #expect(events.count == 2)
        #expect(events.last?.isFinal == true)
        #expect(events.last?.results.first?.meetingID == text.meeting)
        #expect(events.last?.failures[voice.descriptor.id] != nil)
    }

    @Test func fusionRequiresBothRetrievalChannels() async throws {
        let text = FixtureSearchProvider(
            descriptor: .init(id: UUID(), name: "Text fixture", modes: [.text]), meeting: UUID())
        do {
            for try await _ in SearchCoordinator(providers: [text]).search(.init(query: "parcel", mode: .fusion)) {}
            Issue.record("Fusion must not silently use text only")
        }
        catch { #expect(error is SearchProviderError) }
    }
}
