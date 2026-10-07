import Foundation

/// State describes execution; attention describes a decision that remains unresolved.
enum TaskAttentionReason: String, Codable, Sendable {
    case retry, restart, reviewRequest, externalChange
    var title: String {
        switch self {
        case .retry: "Choose whether to retry"
        case .restart: "Choose whether to submit again"
        case .reviewRequest: "Review the saved request"
        case .externalChange: "Choose whether to resume the changed task"
        }
    }
}

struct TaskAttemptEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case queued, started, paused, resumed, ended, waitingForProvider
        var title: String {
            switch self {
            case .queued: "Queued"
            case .started: "Started"
            case .paused: "Paused"
            case .resumed: "Resumed"
            case .ended: "Ended"
            case .waitingForProvider: "Waiting for Provider"
            }
        }
    }
    var id = UUID()
    var kind: Kind
    var date: Date
    var reason: String?
}

struct TaskTiming: Equatable {
    var active: TimeInterval = 0
    var waiting: TimeInterval = 0
    static func measure(_ events: [TaskAttemptEvent], now: Date = Date()) -> Self {
        var result = Self()
        for (index, event) in events.enumerated() {
            let end = index + 1 < events.count ? events[index + 1].date : now
            let duration = max(0, end.timeIntervalSince(event.date))
            switch event.kind {
            case .started, .resumed: result.active += duration
            case .queued, .paused, .waitingForProvider: result.waiting += duration
            case .ended: break
            }
        }
        return result
    }
    static func text(_ duration: TimeInterval) -> String {
        Duration.seconds(duration).formatted(.time(pattern: .hourMinuteSecond))
    }
}

extension ManagedTaskRecord {
    var attentionReason: TaskAttentionReason? {
        guard attentionAcknowledged != true else { return nil }
        if state == .paused, recovery == .manual, errorMessage != nil { return .externalChange }
        guard state == .failed, recovery != .automatic, recovery != .none else { return nil }
        switch recovery {
        case .restartRequired: return .restart
        case .blocked: return .reviewRequest
        case .manual: return .retry
        case .automatic, .none: return nil
        }
    }
    var needsAttention: Bool { attentionReason != nil }
    var operationTitle: String {
        consolidatesRetainedVoiceEvidence == true ? "Speaker Consolidation" : TaskDescription.operation(kind)
    }
    var isMaintenance: Bool { kind == .searchIndex && isAutomatic }
    mutating func recordTransition(from previous: Self?, now: Date = Date()) {
        if let previous { timeline = previous.timeline ?? timeline }
        guard previous?.state != state else { return }
        var events = timeline ?? previous?.timeline ?? []
        if events.isEmpty, previous == nil, state == .queued {
            events.append(.init(kind: .queued, date: createdAt, reason: nil))
        }
        let kind: TaskAttemptEvent.Kind
        switch state {
        case .queued: kind = .queued
        case .running:
            kind = events.contains(where: { $0.kind == .started || $0.kind == .resumed }) ? .resumed : .started
        case .paused: kind = .paused
        case .completed, .failed, .cancelled: kind = .ended
        }
        if !(previous == nil && state == .queued) {
            var reason = errorMessage
            if state == .queued, let previous {
                if previous.restartRequested {
                    reason = "Restart requested"
                }
                else if previous.state == .paused {
                    reason = previous.recovery == .automatic ? "Resume after recording" : "Resume requested"
                }
                else if previous.state == .running {
                    reason = "Recovered after interruption"
                }
                else if previous.state == .failed || previous.state == .cancelled {
                    reason = "Retry requested"
                }
            }
            events.append(.init(kind: kind, date: now, reason: reason))
        }
        if state == .running, [.transcription, .summary].contains(self.kind), providerID != ThisMacProvider.id {
            events.append(.init(kind: .waitingForProvider, date: now, reason: "Remote provider time is waiting time."))
        }
        timeline = events
        if state.isActive { attentionAcknowledged = false }
    }
}

extension VoicePreparationJob {
    var needsAttention: Bool { state == .failed && !failures.isEmpty && attentionAcknowledged != true }
    var operationTitle: String { discover ? "Find Voices" : "Prepare Voice Library" }
    mutating func recordTransition(from previous: Self, now: Date = Date()) {
        guard state != previous.state else { return }
        var events = timeline ?? previous.timeline ?? []
        let kind: TaskAttemptEvent.Kind
        switch state {
        case .queued: kind = .queued
        case .running: kind = previous.state == .paused ? .resumed : .started
        case .paused: kind = .paused
        case .completed, .failed, .cancelled: kind = .ended
        }
        let reason: String?
        switch state {
        case .paused: reason = "Pause requested"
        case .cancelled: reason = "Cancellation requested"
        case .failed: reason = "Review recording and voice example failures."
        case .running:
            reason =
                previous.state == .paused
                ? "Resume requested"
                : [.failed, .cancelled].contains(previous.state) ? "Retry requested" : nil
        case .queued, .completed: reason = nil
        }
        events.append(.init(kind: kind, date: now, reason: reason))
        timeline = events
        if state == .running || state == .failed { attentionAcknowledged = false }
    }
}

/// A presentation adapter over each executor's authoritative recovery record.
struct TaskDescription {
    var operation: String
    var affectedItem: String
    var state: String
    var progress: String
    var attention: Bool
    var date: Date
    init(_ row: TaskHistoryRow, recordingActive: Bool = false) {
        switch row {
        case .managed(let task):
            operation = task.operationTitle
            affectedItem = task.meetingTitle
            state = task.state.rawValue.capitalized
            progress =
                [.failed, .paused].contains(task.state)
                ? task.errorMessage ?? task.attentionReason?.title ?? task.progress : task.progress
            if recordingActive, [.searchIndex, .diarization].contains(task.kind), task.state == .queued {
                progress = "Waiting for recording to finish"
            }
            attention = task.needsAttention
            date = task.finishedAt ?? task.timeline?.last?.date ?? task.createdAt
        case .voice(let job):
            operation = job.operationTitle
            affectedItem = "People Library · " + job.providerName
            state = job.state.rawValue.capitalized
            progress =
                job.failures.isEmpty
                ? job.progress : "\(job.failures.count) failed " + (job.failures.count == 1 ? "item" : "items")
            if job.needsAttention { progress = "Review " + progress }
            if job.state == .paused, let reason = job.timeline?.last?.reason { progress = reason }
            attention = job.needsAttention
            date = job.timeline?.last?.date ?? job.createdAt
        }
    }
    static func operation(_ kind: BackgroundJob.Kind) -> String {
        switch kind {
        case .transcription: "Transcription"
        case .summary: "Summary"
        case .searchIndex: "Search Index"
        case .diarization: "Speaker Labeling"
        case .chat, .contextChat: "Chat"
        case .archive: "Archive"
        case .importAudio: "Audio Import"
        default: "Other Task"
        }
    }
}

/// Fields that affect execution or recovery. Presentation updates cannot change intent.
struct ManagedTaskExecutionIntent: Encodable, Sendable {
    let kind: BackgroundJob.Kind
    let meetingID: UUID
    let providerID: UUID?
    let summaryInstructions: String?
    let searchIndexRevision: String?
    let state: ManagedTaskState
    let recovery: ManagedTaskRecovery
    let attemptKey: String?
    let remoteJobID: String?
    let speakerLabelingResultID: UUID?
    let submissionUncertain: Bool
    let hasSavedResult: Bool
    let providerFailed: Bool
    let userStopped: Bool
    let dismissRequested: Bool
    let restartRequested: Bool
    init(_ record: ManagedTaskRecord) {
        kind = record.kind
        meetingID = record.meetingID
        providerID = record.providerID
        summaryInstructions = record.summaryInstructions
        searchIndexRevision = record.searchIndexRevision
        state = record.state
        recovery = record.recovery
        attemptKey = record.attemptKey
        remoteJobID = record.remoteJobID
        speakerLabelingResultID = record.speakerLabelingResultID
        submissionUncertain = record.submissionUncertain
        hasSavedResult = record.hasSavedResult
        providerFailed = record.providerFailed
        userStopped = record.userStopped
        dismissRequested = record.dismissRequested
        restartRequested = record.restartRequested
    }
}
