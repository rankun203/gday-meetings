import Foundation
import Testing

@testable import GdayMeetings

struct PeopleNameIndexTests {
    private func person(_ name: String) -> PeopleNameRecord { .init(id: UUID(), name: name) }
    private func resolve(_ text: String, _ people: [PeopleNameRecord], frequent: Set<String> = [])
        -> PeopleNameResolution
    {
        PeopleNameIndex(people: people).resolve(text, frequentWords: frequent, detectNames: { _ in [] })
    }

    @Test func fullNamesReversedOrderAndDuplicateRecordsRemainDistinct() {
        let first = person("Zora Vale")
        let duplicate = person("Zora Vale")
        for query in ["Zora Vale budget", "Vale Zora budget"] {
            let result = resolve(query, [first, duplicate])
            #expect(Set(result.confident.map(\.personID)) == [first.id, duplicate.id])
            #expect(result.confident.allSatisfy { $0.score == 1 })
            #expect(result.residualQuery == "budget")
        }
    }
    @Test func wholeNameSuppressesConflictingShorterNameButNotAnotherMention() {
        let full = person("Zora Vale")
        let first = person("Zora")
        let surname = person("Mira Vale")
        let result = resolve("Zora Vale budget", [full, first, surname])
        #expect(result.confident.map(\.personID) == [full.id])
        #expect(!result.candidates.contains { $0.personID == first.id || $0.personID == surname.id })
        let separate = resolve("Zora Vale and Zora budget", [full, first])
        #expect(Set(separate.confident.map(\.personID)) == [full.id, first.id])
    }
    @Test func grammarIsNotConflictingSurnameAndLowercasePrefixIsNameEvidence() {
        let sam = person("Sam Vale")
        #expect(
            resolve("Sam discussed budgets", [sam], frequent: ["discussed", "budgets"]).confident.first?.score == 1)
        let alexander = person("Alexander")
        let other = person("Bo Wang")
        let result = resolve("alex wang", [alexander, other], frequent: ["alex"])
        #expect(result.candidates.first { $0.personID == alexander.id }?.kind == .prefix)
        #expect(result.candidates.first { $0.personID == other.id }?.score ?? 0 <= 0.8)
        #expect(result.confident.isEmpty)
    }
    @Test func unknownAdjacentNamesAndNounTopicsRemainUncertain() {
        let person = person("Bo Wang")
        for query in ["alex wang", "budget wang", "wang budget"] {
            let result = resolve(query, [person], frequent: ["alex", "budget"])
            #expect(result.candidates.first { $0.personID == person.id }?.score == 0.8)
            #expect(result.confident.isEmpty)
            #expect(result.residualQuery == query)
        }
        #expect(resolve("Wang discussed budgets", [person]).confident.first?.score == 1)
        #expect(resolve("Bo Wang budget", [person]).confident.first?.score == 1)
        #expect(resolve("Bo Wang budget", [person]).residualQuery == "budget")
    }
    @Test func extraSurnamePreservesSingleNameAndCapsConflictingRecord() {
        let first = person("Zora")
        let conflicting = person("Mira Singh")
        let result = resolve("Zora Singh", [first, conflicting])
        #expect(result.confident.first?.personID == first.id)
        #expect(result.candidates.first { $0.personID == conflicting.id }?.score ?? 0 <= 0.8)
    }
    @Test func prefixAndShortSpellingStaySuggestions() {
        let alex = person("Alexander")
        let john = person("John")
        #expect(resolve("alex", [alex]).candidates.first?.score == 0.9)
        let spelling = resolve("Jon", [john])
        #expect(spelling.candidates.first?.kind == .spelling)
        #expect(spelling.candidates.first?.score == 0.6)
        #expect(spelling.confident.isEmpty)
        #expect(spelling.residualQuery == "Jon")
    }
    @Test func pinyinNamesAndInitialsExpandOnlyToInitialsRecords() {
        let full = person("Mingzhe Lin")
        let initials = person("HL")
        #expect(resolve("明哲预算", [full]).confident.first?.personID == full.id)
        for phrase in ["Li Hong", "Hong Li", "李红", "hl's update"] {
            let result = resolve(phrase, [initials])
            #expect(result.confident.first?.personID == initials.id)
            #expect(result.confident.first?.score ?? 0 >= 0.95)
        }
        let ordinary = person("Hale")
        #expect(resolve("Hong Li", [ordinary]).confident.isEmpty)
    }
    @Test func fullNameWinsOverInitialsExpansionAndSegmentsPreventCrossingSyllables() {
        let full = person("Lena Zhao")
        let initials = person("LZ")
        let unrelated = person("MJ")
        #expect(resolve("Lena Zhao", [full, initials]).confident.map(\.personID) == [full.id])
        #expect(resolve("宇明讲了计划", [unrelated]).confident.isEmpty)
    }
    @Test func commonWordsAndOrdinaryInitialsExpansionsNeedContextualNameEvidence() {
        let grace = person("Grace")
        let initials = person("HT")
        let pinyin = person("Li Wu")
        let index = PeopleNameIndex(people: [grace, initials, pinyin])
        let words: Set<String> = ["grace", "how", "things", "礼物"]
        #expect(
            index.resolve("grace period", frequentWords: words, detectNames: { _ in [] }).candidates.first?.score == 0.5
        )
        #expect(index.resolve("how things work", frequentWords: words, detectNames: { _ in [] }).confident.isEmpty)
        #expect(index.resolve("礼物", frequentWords: words, detectNames: { _ in [] }).confident.isEmpty)
        let named = index.resolve(
            "Grace talked", frequentWords: words, detectNames: { _ in [NSRange(location: 0, length: 5)] })
        #expect(named.confident.first?.personID == grace.id)
    }
    @Test func spansReferToOriginalUTF16AndUncertainWordsRemainInTopic() throws {
        let name = person("Zora Vale")
        let prefix = person("Alexander")
        let query = "😀 Zora Vale and alex budget"
        let result = resolve(query, [name, prefix])
        let found = try #require(result.confident.first)
        #expect((query as NSString).substring(with: found.span) == "Zora Vale")
        #expect(found.matchedPhrase == "Zora Vale")
        #expect(result.residualQuery.contains("alex budget"))
        #expect(!result.residualQuery.contains("Zora Vale"))
        #expect(resolve("Zora Vale", [name]).residualQuery.isEmpty)
    }
    @Test func indexRebuildsOnlyWhenNamesChangeAndRemovesDeletedPeople() async throws {
        let resolver = PeopleNameResolver()
        let old = person("Zora Vale")
        await resolver.update([old])
        await resolver.update([old])
        #expect(await resolver.rebuildCount == 1)
        let changed = PeopleNameRecord(id: old.id, name: "Nora Vale")
        await resolver.update([changed])
        #expect(await resolver.rebuildCount == 2)
        #expect(try await resolver.resolve("Nora Vale", people: [changed]).confident.first?.name == "Nora Vale")
        #expect(try await resolver.resolve("Nora Vale", people: []).candidates.isEmpty)
    }
}
