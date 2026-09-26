import Foundation

/// The live draft is independent of the editable/batch transcript. Replacing one never deletes the other.
struct LiveTranscriptDraft: Codable, Equatable {
    var version = 1
    var meetingID: UUID
    var provider = "This Mac"
    var locale: String
    var phrases: [LiveTranscriptPhrase] = []
    var gaps: [LiveTranscriptGap] = []
    var complete = false

    var segments: [TranscriptSegment] {
        phrases.sorted(by: LiveTranscriptPhrase.ordered).map {
            TranscriptSegment(id: $0.id, start: $0.start, end: $0.end, speaker: "", text: $0.text)
        }
    }

    mutating func accept(_ phrase: LiveTranscriptPhrase) {
        guard phrase.start.isFinite, phrase.end.isFinite, phrase.start >= 0, phrase.end >= phrase.start,
            !phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // Apple replaces a time range, not a text prefix. Source and recognition generation isolate two feeds.
        phrases.removeAll {
            $0.source == phrase.source && $0.session == phrase.session
                && ($0.start == phrase.start || ($0.start < phrase.end && $0.end > phrase.start))
        }
        phrases.append(phrase)
    }

    static func read(at directory: URL, meetingID: UUID) throws -> Self? {
        let file = directory.appendingPathComponent("live-transcript.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        guard value.version == 1, value.meetingID == meetingID else {
            throw MeetingError.message("This live transcript uses an unsupported format.")
        }
        return value
    }

    func save(at directory: URL) throws {
        try PrivateTranscriptFile.write(try JSONEncoder().encode(self), name: "live-transcript.json", at: directory)
    }
}

enum LiveAudioSource: String, Codable, CaseIterable {
    case microphone, system
    var title: String { self == .microphone ? "Microphone" : "System Audio" }
}

struct LiveTranscriptPhrase: Codable, Identifiable, Equatable {
    var id = UUID()
    var session: UUID
    var source: LiveAudioSource
    var start: Double
    var end: Double
    var text: String
    var words: [LiveTranscriptWord] = []
    var locale: String?
    static func ordered(_ left: Self, _ right: Self) -> Bool {
        left.start == right.start ? left.source.rawValue < right.source.rawValue : left.start < right.start
    }
    static func replacingPartials(_ partials: [Self], with phrase: Self, final: Bool) -> [Self] {
        let retained = partials.filter { $0.source != phrase.source || $0.session != phrase.session }
        return final ? retained : retained + [phrase]
    }
}

struct LiveTranscriptWord: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct LiveTranscriptGap: Codable, Equatable {
    var source: LiveAudioSource
    var start: Double
    var end: Double
    var reason: String
}
