import Combine
import Foundation

struct VoiceReviewLauncherPresentation: Sendable {
    struct Row: Identifiable, Sendable {
        let id: UUID
        let title: String
        let count: Int
        let meetingCount: Int
        let recordingTitle: String?
        let group: VoiceIdentificationGroup?
        let recordingSearchTitles: [String]
        let qualityIssue: String?
        let qualityHelp: String?

        init(
            id: UUID, title: String, count: Int, meetingCount: Int, recordingTitle: String?,
            group: VoiceIdentificationGroup?, recordingSearchTitles: [String],
            qualityIssue: String? = nil, qualityHelp: String? = nil
        ) {
            self.id = id
            self.title = title
            self.count = count
            self.meetingCount = meetingCount
            self.recordingTitle = recordingTitle
            self.group = group
            self.recordingSearchTitles = recordingSearchTitles
            self.qualityIssue = qualityIssue
            self.qualityHelp = qualityHelp
        }
    }
    let people: [Row]
    let groups: [Row]
    static let empty = Self(people: [], groups: [])

    static func prepare(
        snapshot: VoiceReviewSnapshot, people: [Person], titles: [UUID: String],
        dates: [UUID: Date], query: String = ""
    ) async -> Self {
        await Task.detached(priority: .userInitiated) {
            func row(id: UUID, title: String, examples: [VoiceExample], group: VoiceIdentificationGroup? = nil) -> Row {
                let meeting = VoiceReviewMeetingContext.latestMeetingID(in: examples, dates: dates)
                let sample =
                    group.flatMap { group in examples.first { $0.id == group.representativeID } }
                    ?? examples.first
                let issue = sample?.currentSampleQuality?.issue?.label
                let qualityHelp = issue.map {
                    (group == nil ? "First sample: " : "Representative sample: ") + $0 + ". "
                        + VoiceSampleQuality.assessmentDetail
                }
                return Row(
                    id: id, title: title, count: examples.count, meetingCount: Set(examples.map(\.meetingID)).count,
                    recordingTitle: meeting.map { titles[$0] ?? "Saved Recording" }, group: group,
                    recordingSearchTitles: Array(Set(examples.compactMap { titles[$0.meetingID] })),
                    qualityIssue: issue, qualityHelp: qualityHelp)
            }
            let named = people.compactMap { person -> Row? in
                let examples = snapshot.candidates[person.id] ?? []
                guard !examples.isEmpty else { return nil }
                return row(id: person.id, title: person.name, examples: examples)
            }.sorted {
                $0.count == $1.count
                    ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.count > $1.count
            }
            let groups = snapshot.unnamedGroups.map {
                row(id: $0.id, title: "Unidentified Voice", examples: $0.examples, group: $0)
            }
            return Self(people: named, groups: groups).matching(query)
        }.value
    }

    func filtered(query: String) async -> Self {
        await Task.detached(priority: .userInitiated) { matching(query) }.value
    }

    private func matching(_ query: String) -> Self {
        func matches(_ row: Row) -> Bool {
            row.title.localizedStandardContains(query)
                || row.recordingSearchTitles.contains { $0.localizedStandardContains(query) }
        }
        return Self(
            people: query.isEmpty ? people : people.filter(matches),
            groups: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? groups : groups.filter(matches))
    }
}

/// Covered choosers retain their published state while evidence keeps changing.
/// Returning to the chooser captures the latest values once.
@MainActor
final class VoiceReviewLauncherObservation: ObservableObject {
    struct Snapshot: Equatable {
        let people: [Person]
        let policy: VoiceMatchingPolicy
        let evidenceRevision: Int
        let metadataRevision: Int
        let directoryRevision: UUID
        let meetingIndexRevision: UUID
    }
    @Published private(set) var snapshot: Snapshot
    private let store: MeetingStore
    private let library: VoiceLibraryStore
    private var subscriptions: [AnyCancellable] = []
    private var pendingRefresh: DispatchWorkItem?
    private var requestID = UUID()
    private(set) var covered = false

    init(store: MeetingStore, library: VoiceLibraryStore) {
        self.store = store
        self.library = library
        snapshot = Self.capture(store: store, library: library)
        subscriptions = [
            store.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() },
            library.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() },
        ]
    }

    deinit {
        pendingRefresh?.cancel()
        subscriptions.forEach { $0.cancel() }
    }

    func cover() {
        covered = true
        requestID = UUID()
    }

    @discardableResult
    func reveal() -> Bool {
        covered = false
        let previous = snapshot
        refresh()
        return previous != snapshot
    }

    func beginRequest() -> UUID? {
        guard !covered else { return nil }
        requestID = UUID()
        return requestID
    }

    func accepts(_ request: UUID) -> Bool {
        !covered && requestID == request
    }

    private func scheduleRefresh() {
        guard !covered, pendingRefresh == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRefresh = nil
            self.refresh()
        }
        pendingRefresh = work
        DispatchQueue.main.async(execute: work)
    }

    private func refresh() {
        guard !covered else { return }
        let next = Self.capture(store: store, library: library)
        if next != snapshot { snapshot = next }
    }

    private static func capture(store: MeetingStore, library: VoiceLibraryStore) -> Snapshot {
        Snapshot(
            people: store.people,
            policy: store.settings.serviceProviders.first { $0.id == store.settings.diarizationProviderID }?
                .voiceMatchingPolicy ?? .default, evidenceRevision: library.reviewEvidenceRevision,
            metadataRevision: library.reviewMetadataRevision, directoryRevision: store.directoryRevision,
            meetingIndexRevision: store.meetingIndexRevision)
    }
}
