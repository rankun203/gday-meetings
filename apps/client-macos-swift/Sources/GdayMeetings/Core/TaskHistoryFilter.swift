import Foundation

enum TaskHistoryType: String, CaseIterable, Identifiable, Sendable {
    case all = "All Types"
    case recordingFinalization = "Save Recording"
    case transcription = "Transcription"
    case diarization = "Speaker Diarization"
    case speakerAssociation = "Speaker Association"
    case summary = "Summary"
    case todoExtraction = "Extract To-Dos"
    case findVoices = "Scan Recordings"
    case prepareVoices = "Prepare Reviewed Voices"
    case searchIndex = "Search Index"
    case maintenance = "Search Index Maintenance"
    case libraryIndex = "Updating Library"
    case chat = "Chat"
    case archive = "Archive"
    case importAudio = "Audio Import"
    case other = "Other Tasks"

    var id: String { rawValue }
    static var menuCases: [Self] {
        allCases.filter { $0 != .all }.sorted {
            $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending
        }
    }
    private static let knownKinds = [
        "recordingFinalization", "transcription", "diarization", "speakerAssociation", "summary",
        "todoExtraction", "searchIndex", "libraryIndex", "chat", "contextChat", "archive", "importAudio",
    ]
    var predicate: String {
        switch self {
        case .all: "1"
        case .findVoices, .prepareVoices: "0"
        case .searchIndex: "kind='searchIndex' AND automatic=0"
        case .maintenance: "kind='searchIndex' AND automatic=1"
        case .chat: "kind IN ('chat','contextChat')"
        case .other:
            "kind NOT IN (\(Self.knownKinds.map(ManagedTaskIndex.literal).joined(separator: ",")))"
        default: "kind=\(ManagedTaskIndex.literal(String(describing: self)))"
        }
    }
    func includes(_ record: ManagedTaskRecord) -> Bool {
        switch self {
        case .all: true
        case .findVoices, .prepareVoices: false
        case .searchIndex: record.kind == .searchIndex && !record.isAutomatic
        case .maintenance: record.isMaintenance
        case .chat: record.kind == .chat || record.kind == .contextChat
        case .other: !Self.knownKinds.contains(record.kind.rawValue)
        default: record.kind.rawValue == String(describing: self)
        }
    }
    func includes(_ job: VoicePreparationJob) -> Bool {
        self == .all || (job.discover ? self == .findVoices : self == .prepareVoices)
    }
}

/// Presentation combines execution status and operation type before counting or paging.
/// Legacy TaskHistoryScope predicates retain their scheduler and recovery semantics.
struct TaskHistoryQuery: Hashable, Sendable {
    var status: TaskHistoryScope = .all
    var type: TaskHistoryType = .all

    /// The menu selects one status or one type. Keep invalidation scoped to those
    /// presentations; choosing a different section resets the previous selection.
    static let allCases =
        TaskHistoryScope.allCases.filter { $0 != .maintenance }.map { Self(status: $0) }
        + TaskHistoryType.allCases.filter { $0 != .all }.map { Self(type: $0) }

    private var statusPredicate: String {
        switch status {
        case .active: "state IN ('queued','running')"
        case .history: "state IN ('completed','cancelled')"
        default: status.predicate
        }
    }
    var predicate: String { "(\(statusPredicate)) AND (\(type.predicate))" }
    func includes(_ record: ManagedTaskRecord) -> Bool {
        let statusMatches =
            status == .attention
            ? record.needsAttention
            : status == .maintenance ? record.isMaintenance : status.includes(record.state)
        return statusMatches && type.includes(record)
    }
    func includes(_ job: VoicePreparationJob) -> Bool { status.includes(job) && type.includes(job) }
}

extension ManagedTaskRecord {
    /// Progress does not change the ordering; only durable execution transitions do.
    var taskHistoryActivityAt: Date {
        max(
            createdAt, finishedAt ?? createdAt,
            timeline?.filter { $0.kind != .waitingForProvider }.map(\.date).max() ?? createdAt)
    }
}

extension VoicePreparationJob {
    var taskHistoryActivityAt: Date { max(createdAt, timeline?.map(\.date).max() ?? createdAt) }
}
