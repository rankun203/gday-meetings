import Foundation

/// Long-running network or file work that runs beside recording. Each job is
/// unique by kind and scope, so one meeting can't run two transcriptions at once
/// while other meetings keep their actions. Recording start and stop are not
/// jobs; they use the recording state in MeetingStore.
struct BackgroundJob: Identifiable, Equatable {
    struct Kind: RawRepresentable, Codable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let transcription = Self(rawValue: "transcription")
        static let summary = Self(rawValue: "summary")
        static let chat = Self(rawValue: "chat")
        static let archive = Self(rawValue: "archive")
        static let contextChat = Self(rawValue: "contextChat")
        static let importAudio = Self(rawValue: "importAudio")
        init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
    enum Scope: Hashable {
        case meeting(UUID)
        /// A person, tag, or library chat, keyed by MeetingStore.contextChatKey.
        case context(String)
        case library
    }
    struct Key: Hashable {
        let kind: Kind
        let scope: Scope
    }
    let key: Key
    var progress: String
    var id: Key { key }
    var meetingID: UUID? {
        if case .meeting(let id) = key.scope { return id }
        return nil
    }
}

extension MeetingStore {
    /// Registers a job. Returns false when the same kind already runs for this
    /// scope; callers check and begin without suspending, so the check can't race.
    func beginJob(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope, progress: String) -> Bool {
        let key = BackgroundJob.Key(kind: kind, scope: scope)
        guard !isChangingLibrary else { return false }
        guard !backgroundJobs.contains(where: { $0.key == key }) else { return false }
        backgroundJobs.append(BackgroundJob(key: key, progress: progress))
        return true
    }
    func setJobProgress(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope, _ progress: String) {
        let key = BackgroundJob.Key(kind: kind, scope: scope)
        guard let index = backgroundJobs.firstIndex(where: { $0.key == key }) else { return }
        backgroundJobs[index].progress = progress
        recordManagedTaskProgress(key, progress: progress)
    }
    func endJob(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope) {
        let key = BackgroundJob.Key(kind: kind, scope: scope)
        backgroundJobs.removeAll { $0.key == key }
    }
    func isJobRunning(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope) -> Bool {
        backgroundJobs.contains { $0.key == BackgroundJob.Key(kind: kind, scope: scope) }
    }
    var isImportingAudio: Bool { backgroundJobs.contains { $0.key.kind == .importAudio } }

    /// Progress text naming the meeting, so concurrent jobs stay distinguishable.
    func progressText(for job: BackgroundJob) -> String {
        guard let id = job.meetingID, let meeting = meetings.first(where: { $0.id == id }) else {
            return job.progress
        }
        return "\(meeting.title): \(job.progress)"
    }
    /// Progress for the most recently started job. It is derived from the job
    /// list, so it clears only when the last job ends.
    var statusMessage: String { backgroundJobs.last.map(progressText) ?? "" }
}
