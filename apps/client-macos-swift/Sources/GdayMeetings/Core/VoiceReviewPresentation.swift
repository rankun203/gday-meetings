import Foundation

/// New questions and model representations can arrive during preparation.
/// Existing displayed evidence must still carry the same decisions and audio.
struct VoiceReviewPresentationEvidence {
    let examples: [VoiceExample]

    func matches(_ current: [VoiceExample]) -> Bool {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let previousDecisions = VoiceExactReviewDecisions(examples)
        let currentDecisions = VoiceExactReviewDecisions(current)
        func displayEvidence(_ example: VoiceExample) -> VoiceExample {
            var value = example
            value.embeddings = []
            value.rejectedPersonIDs.sort { $0.uuidString < $1.uuidString }
            return value
        }
        return examples.allSatisfy { previous in
            guard let latest = currentByID[previous.id] else { return false }
            return displayEvidence(previousDecisions.applying(to: previous))
                == displayEvidence(currentDecisions.applying(to: latest))
        }
    }
}

/// Immutable display data prepared away from the UI actor. Selection and local
/// review decisions remain in the session, so preparation cannot move focus.
struct VoiceReviewPresentation: Sendable {
    struct Input: Equatable, Sendable {
        let candidates: [VoiceExample]
        let referenceEvidence: [VoiceExample]
        let personID: UUID?
        let meetings: [UUID: MeetingListEntry]
        let libraryDirectory: URL
    }

    struct Row: Sendable {
        let title: String
        let metadata: String
        let help: String
        let audioAvailable: Bool
        let referenceStatus: String
    }

    let references: [VoiceExample]
    let rows: [UUID: Row]
    let playableCandidateIDs: Set<UUID>

    static let empty = Self(references: [], rows: [:], playableCandidateIDs: [])

    static func prepare(_ input: Input) async -> Self {
        await Task.detached(priority: .userInitiated) { make(input) }.value
    }

    fileprivate static func make(_ input: Input) -> Self {
        let candidateAudio = Set(input.candidates.compactMap(VoiceExactReviewDecisions.Key.init))
        let references =
            input.personID.map { person in
                VoiceMatchReviewSession.referenceExamples(input.referenceEvidence, personID: person).filter { example in
                    VoiceExactReviewDecisions.Key(example).map { !candidateAudio.contains($0) } ?? true
                }
            } ?? []
        var rows: [UUID: Row] = [:]
        for example in input.candidates + references {
            let meeting = input.meetings[example.meetingID]
            rows[example.id] = Row(
                title: meeting?.title ?? "Saved Recording",
                metadata: metadataLabel(example, date: meeting?.createdAt),
                help: metadataHelp(example, date: meeting?.createdAt),
                audioAvailable: audioAvailable(example, libraryDirectory: input.libraryDirectory),
                referenceStatus: example.review == .confirmed
                    ? "Confirmed"
                    : (example.namedPersonID == input.personID
                        ? "Associated · Needs Review" : "Automatic Match · Needs Review"))
        }
        return Self(
            references: references, rows: rows,
            playableCandidateIDs: Set(input.candidates.filter { rows[$0.id]?.audioAvailable == true }.map(\.id)))
    }

    static func audioAvailable(_ example: VoiceExample, libraryDirectory: URL) -> Bool {
        guard let range = example.range, let revision = example.audioRevision,
            let folder = try? MeetingFolderLocation.resolve(id: example.meetingID, directory: libraryDirectory)
        else { return false }
        return VoiceLibraryStore.revision(url: folder.appendingPathComponent(range.audioFile)) == revision
    }

    static func metadataLabel(_ example: VoiceExample, date: Date?) -> String {
        guard let date else { return timeLabel(example) }
        let compact: String
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            compact = date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        else {
            compact = date.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits).hour().minute())
        }
        return "\(compact) · \(timeLabel(example))"
    }

    static func metadataHelp(_ example: VoiceExample, date: Date?) -> String {
        guard let date else { return timeLabel(example) }
        return "\(date.formatted(date: .complete, time: .shortened)) · \(timeLabel(example))"
    }

    static func timeLabel(_ example: VoiceExample) -> String {
        guard let range = example.range else { return "Audio unavailable" }
        return "\(timestamp(range.start))–\(timestamp(range.end)) · \(Int(range.speechDuration.rounded()))s"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(min(seconds, Double(Int.max / 2)))) : 0
        if value >= 3600 {
            return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Input comparison and rebuilding both run on this worker. Reuse is limited to
/// identical evidence and meeting metadata; explicit refresh rechecks the disk.
actor VoiceReviewPresentationCache {
    private var cached: (VoiceReviewPresentation.Input, VoiceReviewPresentation)?

    func prepare(_ input: VoiceReviewPresentation.Input, forceRefresh: Bool = false) -> VoiceReviewPresentation {
        if !forceRefresh, let cached, cached.0 == input { return cached.1 }
        let result = VoiceReviewPresentation.make(input)
        cached = (input, result)
        return result
    }
}

/// Each selection has a unique request, including returning to the same sample.
/// A late disk check can therefore never enable playback for a newer selection.
struct VoiceReviewAudioSelection {
    struct Request: Sendable {
        let id = UUID()
        let example: VoiceExample
        let libraryDirectory: URL

        func verify() async -> Bool {
            await Task.detached(priority: .userInitiated) {
                VoiceReviewPresentation.audioAvailable(example, libraryDirectory: libraryDirectory)
            }.value
        }
    }

    private(set) var request: Request?
    private(set) var available = false
    private(set) var isVerified = false

    mutating func select(_ example: VoiceExample?, libraryDirectory: URL) -> Request? {
        available = false
        isVerified = false
        request = example.map { Request(example: $0, libraryDirectory: libraryDirectory) }
        return request
    }

    @discardableResult
    mutating func complete(_ completed: Request, available: Bool) -> Bool {
        guard request?.id == completed.id else { return false }
        self.available = available
        isVerified = true
        return true
    }
}
