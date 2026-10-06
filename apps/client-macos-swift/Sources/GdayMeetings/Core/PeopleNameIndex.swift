import Foundation
import NaturalLanguage

struct PeopleNameRecord: Equatable, Sendable {
    let id: UUID
    let name: String
}

enum PeopleNameMatchKind: String, Sendable { case exact, pinyin, initials, prefix, spelling }

struct PeopleNameCandidate: Identifiable, Equatable, Sendable {
    var id: UUID { personID }
    let personID: UUID
    let name: String
    let score: Double
    let kind: PeopleNameMatchKind
    /// UTF-16 offsets refer to the original, unnormalized query.
    let span: NSRange
    let matchedPhrase: String
    let residualQuery: String
    var isConfident: Bool { score > 0.906 }
}

struct PeopleNameResolution: Equatable, Sendable {
    let query: String
    let candidates: [PeopleNameCandidate]
    let residualQuery: String
    var confident: [PeopleNameCandidate] { candidates.filter(\.isConfident) }
    var unambiguousPeople: Set<UUID> {
        Set(
            confident.filter { match in
                !candidates.contains { other in
                    other.personID != match.personID && other.score >= match.score - 0.02
                        && NSIntersectionRange(other.span, match.span).length > 0
                }
            }.map(\.personID))
    }
    static func empty(_ query: String) -> Self { .init(query: query, candidates: [], residualQuery: query) }
}

/// An immutable name-only index. It never reads profiles, voice samples, or meeting text.
struct PeopleNameIndex: Sendable {
    private struct Alias: Hashable, Sendable {
        let text: String
        let full: Bool
        let pinyin: Bool
    }
    private struct Entry: Sendable {
        let person: PeopleNameRecord
        let aliases: [Alias]
        let words: Set<String>
        let initials: String?
    }
    private struct Posting: Sendable {
        let alias: Alias
        let people: [Int]
        let characters: [Character]
        let wordCount: Int
    }
    private struct Token {
        let text: String
        let normalized: String
        let latin: String
        let range: Range<String.Index>
    }
    private struct Match {
        let entry: Entry
        var score: Double
        let kind: PeopleNameMatchKind
        let span: NSRange
        let full: Bool
    }
    private let entries: [Entry]
    private let postings: [Posting]
    private let exactLookup: [String: [Int]]
    private let prefixLookup: [String: [Int]]
    private let lengthLookup: [Int: [Int]]
    private let initialsLookup: [String: [Int]]
    private let maximumAliasLength: Int
    let count: Int

    init(people: [PeopleNameRecord]) {
        entries = people.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { person in
            let name = Self.normalize(person.name)
            let latin = Self.latin(person.name)
            let parts = latin.split(separator: " ").map(String.init)
            var aliases: [Alias] = [.init(text: name, full: true, pinyin: false)]
            let words = Self.tokens(person.name).map(\.normalized)
            aliases += words.map { .init(text: $0, full: words.count == 1, pinyin: false) }
            if words.count > 1 {
                aliases.append(.init(text: words.reversed().joined(separator: " "), full: true, pinyin: false))
            }
            for value in [
                parts.joined(separator: " "), parts.reversed().joined(separator: " "), parts.joined(),
                parts.reversed().joined(),
            ] {
                aliases.append(.init(text: value, full: true, pinyin: name != latin))
            }
            aliases += parts.map { .init(text: $0, full: parts.count == 1, pinyin: name != latin) }
            let letters = person.name.filter(\.isLetter)
            let initials =
                (2...4).contains(letters.count) && letters.allSatisfy({ $0.isASCII && $0.isUppercase })
                ? letters.lowercased() : nil
            return Entry(person: person, aliases: Array(Set(aliases)), words: Set(parts), initials: initials)
        }
        var owners: [Alias: [Int]] = [:]
        var initials: [String: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            for alias in entry.aliases { owners[alias, default: []].append(index) }
            if let abbreviation = entry.initials { initials[abbreviation, default: []].append(index) }
        }
        let indexed = owners.map { alias, people in
            Posting(
                alias: alias, people: people, characters: Array(alias.text),
                wordCount: alias.text.split(separator: " ").count)
        }
        postings = indexed
        initialsLookup = initials
        var exact: [String: [Int]] = [:]
        var prefixes: [String: [Int]] = [:]
        var lengths: [Int: [Int]] = [:]
        for (index, posting) in indexed.enumerated() {
            exact[posting.alias.text, default: []].append(index)
            lengths[posting.characters.count, default: []].append(index)
            if posting.wordCount == 1, posting.characters.count >= 3 {
                prefixes[String(posting.characters.prefix(3)), default: []].append(index)
            }
        }
        exactLookup = exact
        prefixLookup = prefixes
        lengthLookup = lengths
        maximumAliasLength = lengths.keys.max() ?? 0
        count = entries.count
    }

    func resolve(_ query: String) -> PeopleNameResolution {
        let tokens = Array(Self.tokens(query).prefix(128))
        guard !tokens.isEmpty, !entries.isEmpty else { return .empty(query) }
        var matches: [Match] = []
        var phraseCache: [String: [Int: (Double, PeopleNameMatchKind, Bool)]] = [:]
        for start in tokens.indices {
            for end in start..<min(tokens.count, start + 6) {
                if end > start {
                    let gap = query[tokens[end - 1].range.upperBound..<tokens[end].range.lowerBound]
                    if gap.contains(where: { !$0.isWhitespace && $0 != "-" && $0 != "." }) { break }
                }
                let range = tokens[start].range.lowerBound..<tokens[end].range.upperBound
                let phrase = String(query[range])
                if phrase.count > 96 { break }
                let normalized = tokens[start...end].map(\.normalized).joined(separator: " ")
                let rawNormalized = Self.normalize(phrase)
                let pinyin = tokens[start...end].map(\.latin).joined(separator: " ")
                let syllables = pinyin.split(separator: " ").map(String.init)
                let forms = Set([
                    pinyin, syllables.joined(), syllables.reversed().joined(),
                    syllables.reversed().joined(separator: " "),
                ])
                let initials = syllables.compactMap(\.first).map(String.init).joined()
                let span = NSRange(range, in: query)
                if Task.isCancelled { return .empty(query) }
                let cacheKey = normalized + "|" + rawNormalized + "|" + pinyin
                let base: [Int: (Double, PeopleNameMatchKind, Bool)]
                if let cached = phraseCache[cacheKey] {
                    base = cached
                }
                else {
                    base = baseMatches(
                        normalized, raw: rawNormalized, forms: forms, initials: initials,
                        syllables: syllables.count, tokenCount: end - start + 1)
                    phraseCache[cacheKey] = base
                }
                for (entryIndex, value) in base {
                    let entry = entries[entryIndex]
                    let best = value
                    matches.append(.init(entry: entry, score: best.0, kind: best.1, span: span, full: best.2))
                }
            }
        }
        // A whole identified name owns its span. Preserve duplicate records for the same full name.
        let complete = matches.filter { $0.full && $0.score > 0.906 && $0.kind != .initials }
        matches.removeAll { candidate in
            complete.contains { owner in
                guard owner.entry.person.id != candidate.entry.person.id,
                    owner.entry.person.name != candidate.entry.person.name,
                    NSIntersectionRange(owner.span, candidate.span).length == candidate.span.length
                else { return false }
                return owner.span.length > candidate.span.length
                    || owner.span == candidate.span && owner.kind == .exact
                        && [.initials, .spelling, .prefix].contains(candidate.kind)
            }
        }
        var bestByPerson: [UUID: Match] = [:]
        for match in matches {
            if let old = bestByPerson[match.entry.person.id],
                old.score > match.score
                    || old.score == match.score && old.span.length >= match.span.length
            {
                continue
            }
            bestByPerson[match.entry.person.id] = match
        }
        let candidates = bestByPerson.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.span.location != $1.span.location { return $0.span.location < $1.span.location }
            if $0.entry.person.name != $1.entry.person.name { return $0.entry.person.name < $1.entry.person.name }
            return $0.entry.person.id.uuidString < $1.entry.person.id.uuidString
        }.map { match in
            PeopleNameCandidate(
                personID: match.entry.person.id, name: match.entry.person.name,
                score: match.score, kind: match.kind, span: match.span,
                matchedPhrase: (query as NSString).substring(with: match.span),
                residualQuery: query)
        }
        return .init(
            query: query, candidates: candidates,
            residualQuery: query)
    }

    private func baseMatches(
        _ normalized: String, raw: String, forms: Set<String>, initials: String, syllables: Int, tokenCount: Int
    ) -> [Int: (Double, PeopleNameMatchKind, Bool)] {
        var best: [Int: (Double, PeopleNameMatchKind, Bool)] = [:]
        func accept(_ index: Int, score: Double, kind: PeopleNameMatchKind) {
            let posting = postings[index]
            for person in posting.people {
                if let old = best[person], old.0 > score || old.0 == score && (old.2 || !posting.alias.full) {
                    continue
                }
                best[person] = (score, kind, posting.alias.full)
            }
        }
        for form in Set([normalized, raw]) {
            for index in exactLookup[form] ?? [] where !postings[index].alias.pinyin {
                accept(index, score: 1, kind: .exact)
            }
        }
        for form in forms {
            for index in exactLookup[form] ?? [] where form != normalized || postings[index].alias.pinyin {
                accept(index, score: 0.97, kind: .pinyin)
            }
        }
        let characters = Array(normalized)
        if tokenCount == 1, characters.count >= 3 {
            for index in prefixLookup[String(characters.prefix(3))] ?? []
            where postings[index].alias.text.hasPrefix(normalized) {
                accept(index, score: 0.9, kind: .prefix)
            }
        }
        if characters.count >= 3 {
            let minimum = Int(ceil(Double(characters.count) * 0.75))
            let maximum = min(maximumAliasLength, Int(floor(Double(characters.count) / 0.75)))
            if minimum <= maximum {
                for length in minimum...maximum {
                    for index in lengthLookup[length] ?? [] {
                        if Task.isCancelled { return [:] }
                        let posting = postings[index]
                        guard posting.wordCount == 1 || tokenCount > 1 else { continue }
                        // An edit changes at most one word boundary. This cheap bound
                        // retains every alias that can meet the character-distance cutoff.
                        guard abs(posting.wordCount - tokenCount) <= max(length, characters.count) / 4 else { continue }
                        let similarity = Self.similarity(characters, posting.characters)
                        if similarity >= 0.75 { accept(index, score: 0.6 + (similarity - 0.75) * 1.4, kind: .spelling) }
                    }
                }
            }
        }
        if syllables > 1 {
            for key in Set([initials, String(initials.reversed())]) where key.count == syllables {
                for person in initialsLookup[key] ?? [] {
                    if best[person].map({ $0.0 >= 0.95 }) == true { continue }
                    best[person] = (0.95, .initials, false)
                }
            }
        }
        return best
    }

    static func normalize(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
    static func latin(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 128 }) { return normalize(text) }
        return normalize(text.applyingTransform(.mandarinToLatin, reverse: false) ?? text)
    }
    private static func tokens(_ text: String) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var result: [Token] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let source = String(text[range])
            var token = source
            if token.lowercased().hasSuffix("'s") || token.lowercased().hasSuffix("’s") { token.removeLast(2) }
            let normalized = normalize(token)
            if !normalized.isEmpty {
                result.append(.init(text: token, normalized: normalized, latin: latin(token), range: range))
            }
            return true
        }
        return result
    }
    private static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        let size = max(a.count, b.count)
        let edits = size / 4
        guard size > 0, abs(a.count - b.count) <= edits else { return 0 }
        let outside = size + 1
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var current = Array(repeating: outside, count: b.count + 1)
            current[0] = i + 1
            let lower = max(0, i - edits)
            let upper = min(b.count - 1, i + edits)
            guard lower <= upper else { return 0 }
            for j in lower...upper {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (character == b[j] ? 0 : 1))
            }
            if current.min()! > edits { return 0 }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(size)
    }
}
