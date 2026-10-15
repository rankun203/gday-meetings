import Foundation

/// Long-running network or file work that runs beside recording. Each job is
/// unique by kind and scope, so one meeting can't run two transcriptions at once
/// while other meetings keep their actions. Recording start and stop are not
/// jobs; they use the recording state in MeetingStore.
struct BackgroundJob: Identifiable, Equatable {
    struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }
        static let transcription = Self(rawValue: "transcription")
        static let diarization = Self(rawValue: "diarization")
        static let summary = Self(rawValue: "summary")
        static let recordingFinalization = Self(rawValue: "recordingFinalization")
        static let speakerAssociation = Self(rawValue: "speakerAssociation")
        static let todoExtraction = Self(rawValue: "todoExtraction")
        static let libraryIndex = Self(rawValue: "libraryIndex")
        static let searchIndex = Self(rawValue: "searchIndex")
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
    enum Scope: Hashable, Sendable {
        case meeting(UUID)
        /// A person, tag, or library chat, keyed by MeetingStore.contextChatKey.
        case context(String)
        case library
    }
    struct Key: Hashable, Sendable {
        let kind: Kind
        let scope: Scope
    }
    let key: Key
    var progress: String
    var attemptID = UUID()
    var progressDetails: TaskProgress?
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
        guard !isChangingLibrary, !isPreparingToQuit else { return false }
        guard !backgroundJobs.contains(where: { $0.key == key }) else { return false }
        backgroundJobs.append(
            BackgroundJob(key: key, progress: progress, progressDetails: TaskProgress(phase: progress)))
        recordManagedTaskProgress(key, progress: progress, details: backgroundJobs.last?.progressDetails)
        return true
    }
    func jobProgressAttemptID(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope) -> UUID? {
        backgroundJobs.first { $0.key == .init(kind: kind, scope: scope) }?.attemptID
    }

    func setJobProgress(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope, _ progress: String) {
        // Legacy messages may contain changing counts. They do not declare a phase boundary.
        updateJobProgress(
            kind, scope, progress, details: TaskProgress(phase: progress),
            attemptID: nil, publishesPhaseChanges: false)
    }

    func setJobProgress(
        _ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope, _ progress: String,
        details: TaskProgress, attemptID: UUID? = nil
    ) {
        updateJobProgress(
            kind, scope, progress, details: details, attemptID: attemptID,
            publishesPhaseChanges: true)
    }

    private func updateJobProgress(
        _ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope, _ progress: String,
        details: TaskProgress, attemptID: UUID?, publishesPhaseChanges: Bool
    ) {
        let key = BackgroundJob.Key(kind: kind, scope: scope)
        guard let index = backgroundJobs.firstIndex(where: { $0.key == key }),
            attemptID == nil || backgroundJobs[index].attemptID == attemptID
        else { return }
        var update = backgroundJobs[index]
        update.progress = progress
        update.progressDetails = details
        if update.progressDetails?.phase == backgroundJobs[index].progressDetails?.phase,
            let startedAt = backgroundJobs[index].progressDetails?.startedAt
        {
            update.progressDetails?.startedAt = startedAt
        }
        if (publishesPhaseChanges && backgroundJobs[index].progressDetails?.phase != details.phase)
            || (jobProgressUpdatedAt[key].map({ $0.duration(to: .now) >= .milliseconds(500) }) ?? true)
        {
            pendingJobProgress.removeValue(forKey: key)
            jobProgressUpdatedAt[key] = .now
            if backgroundJobs[index] != update {
                backgroundJobs[index] = update
                recordManagedTaskProgress(key, progress: progress, details: update.progressDetails)
            }
            return
        }
        pendingJobProgress[key] = update
        guard jobProgressFlush == nil else { return }
        jobProgressFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            let pending = pendingJobProgress
            pendingJobProgress.removeAll()
            jobProgressFlush = nil
            var jobs = backgroundJobs
            for (key, update) in pending {
                guard let index = jobs.firstIndex(where: { $0.key == key }),
                    jobs[index].attemptID == update.attemptID, jobs[index] != update
                else { continue }
                jobs[index] = update
                jobProgressUpdatedAt[key] = .now
                recordManagedTaskProgress(key, progress: update.progress, details: update.progressDetails)
            }
            if jobs != backgroundJobs { backgroundJobs = jobs }
        }
    }
    func endJob(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope) {
        let key = BackgroundJob.Key(kind: kind, scope: scope)
        pendingJobProgress.removeValue(forKey: key)
        jobProgressUpdatedAt.removeValue(forKey: key)
        backgroundJobs.removeAll { $0.key == key }
    }
    func isJobRunning(_ kind: BackgroundJob.Kind, _ scope: BackgroundJob.Scope) -> Bool {
        let key = BackgroundJob.Key(kind: kind, scope: scope)
        return backgroundJobs.contains { $0.key == key }
            || managedTaskReservations.contains(key)
            || managedTaskActiveCounts[key, default: 0] > 0
            || managedTasks.contains { $0.key == key && $0.state.isActive }
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
