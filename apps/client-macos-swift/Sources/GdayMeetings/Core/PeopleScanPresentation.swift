import Combine
import Foundation

/// The review sheet displays one scan, independently of preparation-only history.
struct PeopleScanPresentation: Equatable {
    struct Failure: Identifiable, Equatable {
        let id: String
        let message: String
        let count: Int
    }
    let jobID: UUID
    let providerID: UUID
    let providerName: String
    let state: VoicePreparationState
    let date: Date
    let progress: String
    let failureCount: Int
    let status: String
    let failures: [Failure]

    static func relevantJob(in jobs: [VoicePreparationJob]) -> VoicePreparationJob? {
        let scans = jobs.filter(\.discover)
        return scans.filter { [.running, .queued].contains($0.state) }.max(by: older)
            ?? scans.max(by: older)
    }

    static func errorPreview(_ failures: [String: String]) -> [Failure] {
        // Prioritize scan-wide blockers, then recordings, then examples. Group
        // identical messages while retaining only the three highest-priority rows.
        var grouped: [String: (key: String, count: Int)] = [:]
        func rank(_ key: String) -> String {
            (key == "configuration" ? "0" : key.hasPrefix("recording-") ? "1" : "2") + key
        }
        for (key, message) in failures {
            if let existing = grouped[message] {
                grouped[message] = (rank(key) < rank(existing.key) ? key : existing.key, existing.count + 1)
            }
            else {
                grouped[message] = (key, 1)
            }
        }
        var result: [Failure] = []
        for (message, entry) in grouped {
            let position = result.firstIndex { rank(entry.key) < rank($0.id) } ?? result.endIndex
            if position < 3 {
                result.insert(Failure(id: entry.key, message: message, count: entry.count), at: position)
                if result.count > 3 { result.removeLast() }
            }
        }
        return result
    }

    static func prepare(jobs: [VoicePreparationJob]) -> Self? {
        relevantJob(in: jobs).map { prepare(job: $0, failures: errorPreview($0.failures)) }
    }

    static func prepare(job: VoicePreparationJob, failures: [Failure]) -> Self {
        Self(
            jobID: job.id, providerID: job.providerID, providerName: job.providerName, state: job.state,
            date: job.taskHistoryActivityAt, progress: job.progress, failureCount: job.failures.count,
            status: job.outcomeTitle, failures: failures)
    }

    private static func older(_ left: VoicePreparationJob, _ right: VoicePreparationJob) -> Bool {
        left.taskHistoryActivityAt == right.taskHistoryActivityAt
            ? left.id.uuidString < right.id.uuidString : left.taskHistoryActivityAt < right.taskHistoryActivityAt
    }

    @MainActor static func resumeUnavailableReason(for job: VoicePreparationJob, provider: ServiceProvider?) -> String?
    {
        guard let provider else {
            return "Choose a Speaker Diarization provider in General settings before starting a new scan."
        }
        return VoiceLibraryPreparation.resumeUnavailableReason(for: job, provider: provider)
    }

}

/// Subscribe only to inputs this section consumes. Playback and review selection do
/// not refresh scan status; error previews are bounded before SwiftUI evaluates them.
@MainActor final class PeopleScanObservation: ObservableObject {
    @Published private(set) var presentation: PeopleScanPresentation?
    @Published private(set) var provider: ServiceProvider?
    @Published private(set) var busy = false
    @Published private(set) var writable = false
    @Published private(set) var recording = false
    private var subscriptions = Set<AnyCancellable>()
    private var previewJobID: UUID?
    private var previewFailures: [String: String] = [:]
    private var preview: [PeopleScanPresentation.Failure] = []

    init(store: MeetingStore, library: VoiceLibraryStore) {
        library.$jobs.sink { [weak self] jobs in
            guard let self else { return }
            let job = PeopleScanPresentation.relevantJob(in: jobs)
            if previewJobID != job?.id || previewFailures != (job?.failures ?? [:]) {
                previewJobID = job?.id
                previewFailures = job?.failures ?? [:]
                preview = PeopleScanPresentation.errorPreview(previewFailures)
            }
            let value = job.map { PeopleScanPresentation.prepare(job: $0, failures: self.preview) }
            if presentation != value { presentation = value }
            let active = jobs.contains { $0.state == .queued || $0.state == .running }
            if busy != active { busy = active }
        }.store(in: &subscriptions)
        store.$settings.sink { [weak self] settings in
            let value = settings.serviceProviders.first { $0.id == settings.diarizationProviderID }
            if self?.provider != value { self?.provider = value }
        }.store(in: &subscriptions)
        Publishers.CombineLatest3(store.$recordingID, store.$isStartingRecording, store.$isFinalizingRecording)
            .map { $0 != nil || $1 || $2 }.removeDuplicates()
            .sink { [weak self] in self?.recording = $0 }.store(in: &subscriptions)
        // Writability has no dedicated publisher. Throttling guarantees a latest
        // read even while unrelated store changes continue during a scan.
        store.objectWillChange.throttle(for: .milliseconds(10), scheduler: RunLoop.main, latest: true)
            .sink { [weak self, weak store] in
                guard let self, let store else { return }
                let available = store.libraryWritable
                if writable != available { writable = available }
            }.store(in: &subscriptions)
        writable = store.libraryWritable
        recording = store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording
    }
}
