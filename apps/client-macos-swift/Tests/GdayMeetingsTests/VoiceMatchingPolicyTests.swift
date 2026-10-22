import Foundation
import Testing

@testable import GdayMeetings

struct VoiceMatchingPolicyTests {
    private let type = EmbeddingType(
        modelID: "synthetic", revision: "one", compatibilityVersion: "one", dimension: 2, normalization: "unitL2")

    private func sample(_ degrees: Double) -> VoiceExample {
        let angle = degrees * .pi / 180
        return VoiceExample(
            meetingID: UUID(), speakerID: UUID(), source: "system", audioFile: "system.wav",
            audioRevision: "fixture", start: 0, end: 4, review: .unassigned,
            embeddings: [.init(type: type, values: [cos(angle), sin(angle)])])
    }

    @MainActor @Test func savingPolicyRefreshesMatchesWithoutMeetingProjectionOrReembedding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: root)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        let person = await store.addPerson(name: "Example Person")
        var reference = sample(0)
        reference.personID = person
        reference.review = .confirmed
        var candidate = sample(40)
        for value in [reference, candidate] {
            let folder = try MeetingFolderLocation.newFolder(id: value.meetingID, date: Date(), directory: root)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("synthetic audio".utf8).write(to: folder.appendingPathComponent("system.wav"))
        }
        let referenceFile = store.directory(for: reference.meetingID).appendingPathComponent("system.wav")
        let candidateFile = store.directory(for: candidate.meetingID).appendingPathComponent("system.wav")
        reference.audioRevision = VoiceLibraryStore.revision(url: referenceFile)
        candidate.audioRevision = VoiceLibraryStore.revision(url: candidateFile)
        #expect(store.voiceLibrary.upsert([reference, candidate]))
        let provider = try #require(
            store.settings.serviceProviders.firstIndex { $0.id == store.settings.diarizationProviderID })
        store.settings.serviceProviders[provider].voiceMatchingPolicy = .init(
            suggestionThreshold: 0.55, automaticThreshold: 0.75, minimumMargin: 0.08)
        #expect(store.saveSettings())
        await store.flushVoiceAssignmentRefresh()
        #expect(store.voiceLibrary.examples.first { $0.id == candidate.id }?.suggestedPersonID == person)
        store.settings.serviceProviders[provider].voiceMatchingPolicy = .default
        #expect(store.saveSettings())
        await store.flushVoiceAssignmentRefresh()
        #expect(store.voiceLibrary.examples.first { $0.id == candidate.id }?.suggestedPersonID == nil)
        #expect(store.voiceLibrary.examples.first { $0.id == reference.id }?.review == .confirmed)
    }

    @Test func threeSimilarVoicesGroupWithoutCompetingWithEachOther() {
        let examples = [sample(0), sample(5), sample(10)]
        let groups = VoiceAutomaticGrouping.groups(examples)
        #expect(groups.count == 1)
        #expect(Set(groups[0].map(\.id)) == Set(examples.map(\.id)))
        #expect(groups.allSatisfy { $0.allSatisfy { $0.personID == nil && $0.review == .unassigned } })
    }

    @Test func ambiguousChainCannotBridgeDifferentVoices() {
        let examples = [sample(0), sample(25), sample(50)]
        // Adjacent pairs pass 0.85 but the endpoints do not. The next cluster
        // competes equally, so a zero-margin proposed join stays separate.
        #expect(VoiceAutomaticGrouping.groups(examples).count == 3)
        #expect(VoiceAutomaticGrouping.groups(examples.reversed()).count == 3)
        let relaxed = VoiceMatchingPolicy(suggestionThreshold: 0.55, automaticThreshold: 0.85, minimumMargin: 0)
        #expect(VoiceAutomaticGrouping.groups(examples, policy: relaxed).map(\.count).sorted() == [1, 2])
    }

    @Test func mergeOrderUsesCompleteLinkClusterScores() {
        let examples = [sample(0), sample(8), sample(20), sample(34)]
        let policy = VoiceMatchingPolicy(suggestionThreshold: 0.55, automaticThreshold: 0.85, minimumMargin: 0)
        let result = VoiceAutomaticGrouping.groups(examples, policy: policy)
        // Complete link first forms the two closest pairs. The second pair
        // remains ambiguous against a member of the first pair and is split.
        #expect(result.map(\.count).sorted() == [1, 1, 2])
        let reversed = VoiceAutomaticGrouping.groups(Array(examples.reversed()), policy: policy)
        #expect(result.map { Set($0.map(\.id)) } == reversed.map { Set($0.map(\.id)) })
    }

    @Test func anAmbiguousMemberDoesNotDestroyAConfidentCore() {
        let examples = [sample(0), sample(5), sample(10), sample(35)]
        let groups = VoiceAutomaticGrouping.groups(examples, policy: .init(automaticThreshold: 0.85))
        #expect(groups.map(\.count).sorted() == [1, 1, 2])
        #expect(groups.contains { Set($0.map(\.id)) == [examples[0].id, examples[1].id] })
    }

    @Test func nearestNeighborChainMatchesExhaustiveCompleteLinkWithoutTies() {
        var state: UInt64 = 17
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }
        for _ in 0..<24 {
            let examples = (0..<12).map { _ in sample(next() * 180) }
            let policy = VoiceMatchingPolicy(
                suggestionThreshold: 0.55, automaticThreshold: 0.7 + next() * 0.2, minimumMargin: 0.08)
            let actual = VoiceAutomaticGrouping.groups(examples, policy: policy)
            let expected = exhaustiveGrouping(examples, policy: policy)
            #expect(Set(actual.map { Set($0.map(\.id)) }) == Set(expected.map { Set($0.map(\.id)) }))
        }
    }

    @Test func severalSeparatedVoicesProduceDistinctProposedGroups() {
        let examples = [0.0, 2, 90, 92, 180, 182].map(sample)
        let groups = VoiceAutomaticGrouping.groups(examples)
        #expect(groups.map(\.count).sorted() == [2, 2, 2])
        #expect(groups.allSatisfy { $0.allSatisfy { $0.personID == nil && $0.review == .unassigned } })
    }

    @Test func equalSimilarityTiesAreStableAcrossInputOrder() {
        let examples = [sample(0), sample(0), sample(0), sample(90), sample(90)]
        let first = VoiceAutomaticGrouping.groups(examples)
        let reversed = VoiceAutomaticGrouping.groups(Array(examples.reversed()))
        #expect(Set(first.map { Set($0.map(\.id)) }) == Set(reversed.map { Set($0.map(\.id)) }))
        #expect(first.map(\.count).sorted() == [2, 3])
    }

    /// Small exhaustive reference protects linkage and member-margin semantics.
    private func exhaustiveGrouping(_ examples: [VoiceExample], policy: VoiceMatchingPolicy) -> [[VoiceExample]] {
        let ordered = examples.sorted { $0.id.uuidString < $1.id.uuidString }
        func similarity(_ a: Int, _ b: Int) -> Double {
            VoiceReviewSelection.similarity(ordered[a], ordered[b]) ?? -1
        }
        var groups = ordered.indices.map { [$0] }
        while true {
            var pair: (Int, Int)?
            var strongest = -2.0
            for a in groups.indices {
                for b in (a + 1)..<groups.count {
                    let score = groups[a].flatMap { x in groups[b].map { similarity(x, $0) } }.min() ?? -1
                    if score > strongest {
                        strongest = score
                        pair = (a, b)
                    }
                }
            }
            guard let (a, b) = pair, strongest >= policy.automaticThreshold else { break }
            groups[a] = (groups[a] + groups[b]).sorted()
            groups.remove(at: b)
        }
        return groups.flatMap { members -> [[VoiceExample]] in
            guard members.count > 1 else { return [members.map { ordered[$0] }] }
            let memberSet = Set(members)
            let retained = members.filter { member in
                let weakest = members.filter { $0 != member }.map { similarity(member, $0) }.min() ?? 1
                let competitor =
                    ordered.indices.filter { !memberSet.contains($0) }.map { similarity(member, $0) }.max() ?? -1
                return weakest - competitor >= policy.minimumMargin
            }
            let retainedSet = Set(retained)
            let core = retained.isEmpty ? [] : [retained.map { ordered[$0] }]
            return core + members.filter { !retainedSet.contains($0) }.map { [ordered[$0]] }
        }
    }

    @Test func doublePrecisionThresholdAndMarginBoundariesStayDistinct() {
        let degrees = 180 / Double.pi
        let automatic = VoiceMatchingPolicy.default.automaticThreshold
        #expect(VoiceAutomaticGrouping.groups([sample(0), sample(acos(automatic - 0.000000001) * degrees)]).count == 2)
        #expect(VoiceAutomaticGrouping.groups([sample(0), sample(acos(automatic + 0.000000001) * degrees)]).count == 1)
        let policy = VoiceMatchingPolicy(suggestionThreshold: 0.55, automaticThreshold: 0.9, minimumMargin: 0.08)
        let pair = [sample(0), sample(acos(0.95) * degrees)]
        let outside = sample(-acos(0.87 - 0.000000001) * degrees)
        #expect(VoiceAutomaticGrouping.groups(pair + [outside], policy: policy).map(\.count).sorted() == [1, 2])
        let ambiguous = sample(-acos(0.87 + 0.000000001) * degrees)
        #expect(VoiceAutomaticGrouping.groups(pair + [ambiguous], policy: policy).count == 3)
    }

    @Test func settingsRegroupOldProposalsButProtectHumanGroups() {
        var first = sample(0)
        first.origin = .discovery
        var second = sample(30)
        second.origin = .discovery
        second.groupID = first.groupID
        #expect(VoiceIdentificationSelection.groups([first, second]).count == 1)
        let strict = VoiceMatchingPolicy(suggestionThreshold: 0.55, automaticThreshold: 0.95, minimumMargin: 0.08)
        #expect(VoiceIdentificationSelection.groups([first, second], policy: strict).count == 2)
        var manualFirst = first
        manualFirst.manuallyGrouped = true
        second.manuallyGrouped = true
        #expect(VoiceIdentificationSelection.groups([manualFirst, second], policy: strict).count == 1)
    }

    @Test func legacyLinkedEvidenceRetainsItsAuthoredScope() {
        let first = sample(0)
        var other = sample(90)
        other.groupID = first.groupID
        let strict = VoiceMatchingPolicy(suggestionThreshold: 0.55, automaticThreshold: 1, minimumMargin: 1)
        let groups = VoiceIdentificationSelection.groups([first, other], policy: strict)
        #expect(groups.count == 1)
        #expect(Set(groups[0].evidenceExamples.map(\.id)) == [first.id, other.id])
    }

    @Test func personSpecificRejectionDoesNotFreezeAnUnknownAutomaticGroup() {
        var first = sample(0)
        first.origin = .discovery
        var rejected = sample(0)
        rejected.origin = .discovery
        rejected.rejectedPersonIDs = [UUID()]
        rejected.review = .rejected
        let groups = VoiceIdentificationSelection.groups([first, rejected])
        #expect(groups.count == 1)
        #expect(
            groups[0].evidenceExamples.first { $0.id == rejected.id }?.rejectedPersonIDs == rejected.rejectedPersonIDs)
        // An obsolete automatic group must not survive through the protected path.
        rejected.groupID = first.groupID
        rejected.embeddings = sample(90).embeddings
        #expect(VoiceIdentificationSelection.groups([first, rejected]).count == 2)
    }

    @Test func matchingUsesOnlyCompatibleModelsAndNormalizedPolicy() throws {
        let first = sample(0)
        var incompatible = sample(0)
        incompatible.embeddings[0].type.revision = "other"
        #expect(VoiceAutomaticGrouping.groups([first, incompatible]).count == 2)
        let invalid = VoiceMatchingPolicy(suggestionThreshold: .nan, automaticThreshold: .infinity, minimumMargin: -1)
        #expect(
            invalid.normalized
                == VoiceMatchingPolicy(suggestionThreshold: 0.55, automaticThreshold: 0.80, minimumMargin: 0))
        var provider = ServiceProvider(kind: .speakerLabeling)
        let original = try JSONEncoder().encode(provider)
        #expect(try JSONDecoder().decode(ServiceProvider.self, from: original).voiceMatchingPolicy == .default)
        provider.voiceMatchingPolicy = .init(suggestionThreshold: 0.6, automaticThreshold: 0.9, minimumMargin: 0.1)
        let saved = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(provider))
        #expect(saved.voiceMatchingPolicy == provider.voiceMatchingPolicy)
    }

    @Test func suggestionThresholdChangesQuestionsWithoutTrainingOnSuggestions() {
        let person = UUID()
        var confirmed = sample(0)
        confirmed.personID = person
        confirmed.review = .confirmed
        let candidate = sample(50)
        #expect(VoiceReviewSelection.rank([confirmed, candidate], for: person).map(\.id) == [candidate.id])
        let policy = VoiceMatchingPolicy(suggestionThreshold: 0.7, automaticThreshold: 0.85, minimumMargin: 0.08)
        #expect(VoiceReviewSelection.rank([confirmed, candidate], for: person, policy: policy).isEmpty)
        confirmed.review = .suggested
        #expect(VoiceReviewSelection.rank([confirmed, candidate], for: person).isEmpty)
    }
}
