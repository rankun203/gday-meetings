import SwiftUI

/// Named people and unidentified voice groups open the same listening session.
struct PeopleMatchReviewLauncher: View {
    @EnvironmentObject private var store: MeetingStore
    let library: VoiceLibraryStore

    var body: some View {
        PeopleMatchReviewLauncherHost(store: store, library: library).equatable()
    }
}

private struct PeopleMatchReviewLauncherHost: View, Equatable {
    let store: MeetingStore
    let library: VoiceLibraryStore

    static func == (left: Self, right: Self) -> Bool {
        left.store === right.store && left.library === right.library
    }

    var body: some View {
        PeopleMatchReviewLauncherContent(store: store, library: library)
    }
}

private struct PeopleMatchReviewLauncherContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.showManagedTask) private var showManagedTask
    let store: MeetingStore
    let library: VoiceLibraryStore
    @StateObject private var observation: VoiceReviewLauncherObservation

    init(store: MeetingStore, library: VoiceLibraryStore) {
        self.store = store
        self.library = library
        _observation = StateObject(wrappedValue: VoiceReviewLauncherObservation(store: store, library: library))
    }
    @ScaledMetric(relativeTo: .headline) private var rowHeight = VoiceReviewLauncherRow.baseHeight
    @ViewState private var scrolling = false
    @ViewState private var query = ""
    @ViewState private var managingSamples = false
    private struct ReviewTarget: Identifiable {
        let id: UUID
        let personID: UUID?
        var group: VoiceIdentificationGroup? = nil
    }
    @ViewState private var target: ReviewTarget?
    @ViewState private var presentation = VoiceReviewLauncherPresentation.empty
    @ViewState private var catalog = VoiceReviewLauncherPresentation.empty
    @ViewState private var catalogRevision = UUID()
    @ViewState private var catalogRequest: UUID?
    @ViewState private var loading = true
    @ViewState private var loadedSnapshot: SnapshotRequest?
    @ViewState private var error: String?
    private struct SnapshotRequest: Equatable {
        let observation: VoiceReviewLauncherObservation.Snapshot
    }
    private var snapshotRequest: SnapshotRequest {
        SnapshotRequest(observation: observation.snapshot)
    }
    private struct FilterRevision: Equatable {
        let catalog: UUID
        let query: String
        let scrolling: Bool
    }
    private var filterRevision: FilterRevision {
        FilterRevision(catalog: catalogRevision, query: query, scrolling: scrolling)
    }
    private var visibleCount: Int { presentation.people.count + presentation.groups.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Library").font(.title2.bold())
                    Text("Choose a person to listen, name voices, and confirm samples.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await loadCandidates(forceRefresh: true) } }
                    .labelStyle(.iconOnly).help("Refresh Review Library").disabled(loading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Find a Person or Recording", text: $query).textFieldStyle(.roundedBorder).disabled(loading)
            List {
                if !presentation.people.isEmpty {
                    Section("People") {
                        ForEach(presentation.people) { row in
                            Button {
                                observation.cover()
                                target = ReviewTarget(id: row.id, personID: row.id)
                            } label: {
                                VoiceReviewLauncherRow(row: row, unnamed: false, height: rowHeight).equatable()
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if !presentation.groups.isEmpty {
                    Section("Unidentified Voices") {
                        ForEach(presentation.groups) { row in
                            Button {
                                observation.cover()
                                target = ReviewTarget(id: row.id, personID: nil, group: row.group)
                            } label: {
                                VoiceReviewLauncherRow(row: row, unnamed: true, height: rowHeight).equatable()
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if visibleCount > 0 {
                    ListCountFooter(
                        text:
                            "\(presentation.people.count) \(presentation.people.count == 1 ? "Person" : "People") · \(presentation.groups.count) Unidentified \(presentation.groups.count == 1 ? "Voice" : "Voices")"
                    ).selectionDisabled()
                }
            }.listStyle(.inset)
                .environment(\.defaultMinListRowHeight, rowHeight)
                .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
                .disabled(loading || error != nil)
                .overlay {
                    if loading {
                        ProgressView("Finding samples to review…")
                    }
                    else if let error {
                        ContentUnavailableView {
                            Label("Couldn’t Load Matches", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try Again") { Task { await loadCandidates(forceRefresh: true) } }
                        }
                    }
                    else if visibleCount == 0 {
                        ContentUnavailableView {
                            Label(
                                query.isEmpty ? "No Matches to Review" : "No Matching People",
                                systemImage: "person.crop.circle")
                        } description: {
                            Text(
                                query.isEmpty
                                    ? "No playable samples are waiting for identification or review."
                                    : "Try another name or recording title.")
                        }
                    }
                }
            Divider()
            VoicePreparationControls(library: library, manageSamples: { managingSamples = true }) { id in
                dismiss()
                showManagedTask(id)
            }
        }.padding(24).frame(width: 660, height: 600)
            .task(id: snapshotRequest) { await loadCandidates() }
            .task(id: filterRevision) { await filterCatalog() }
            .sheet(isPresented: $managingSamples) {
                VoiceSampleManagementView(library: library)
                    .environment(\.showManagedTask) { id in
                        managingSamples = false
                        dismiss()
                        showManagedTask(id)
                    }
            }
            .sheet(
                item: $target,
                onDismiss: {
                    if !observation.reveal() {
                        Task { await loadCandidates() }
                    }
                }
            ) { selected in
                PersonMatchReviewView(
                    library: library, personID: selected.personID,
                    initialGroup: selected.group
                )
            }

    }

    private func loadCandidates(forceRefresh: Bool = false) async {
        guard target == nil, let request = observation.beginRequest() else { return }
        let queryState = snapshotRequest
        loading = loadedSnapshot == nil
        error = nil
        do {
            let snapshot = try await library.reviewSnapshot(
                for: Set(queryState.observation.people.map(\.id)), forceRefresh: forceRefresh,
                policy: queryState.observation.policy)
            guard !Task.isCancelled, observation.accepts(request), target == nil else { return }
            let meetings = store.meetings
            let index = store.libraryIndex
            let context = await Task.detached {
                let meetingIDs = Set(
                    snapshot.candidates.values.flatMap { $0.map(\.meetingID) }
                        + snapshot.unnamedGroups.flatMap { $0.examples.map(\.meetingID) })
                var titles = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.title) })
                var dates = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0.createdAt) })
                if let index {
                    for id in meetingIDs {
                        if let entry = try? index.entry(id: id) {
                            titles[id] = entry.title
                            dates[id] = entry.createdAt
                        }
                    }
                }
                return (titles, dates)
            }.value
            guard !Task.isCancelled, observation.accepts(request), target == nil else { return }
            let prepared = await VoiceReviewLauncherPresentation.prepare(
                snapshot: snapshot, people: queryState.observation.people, titles: context.0,
                dates: context.1)
            guard !Task.isCancelled, observation.accepts(request), target == nil else { return }
            catalog = prepared
            catalogRequest = request
            catalogRevision = UUID()
            loadedSnapshot = queryState
        }
        catch {
            guard !Task.isCancelled, observation.accepts(request), target == nil else { return }
            self.error = error.localizedDescription
            presentation = .empty
            loading = false
        }
    }

    private func filterCatalog() async {
        guard catalogRequest != nil, !observation.covered, target == nil, !scrolling else { return }
        let revision = filterRevision
        let filtered = await catalog.filtered(query: revision.query)
        guard !Task.isCancelled, !observation.covered, target == nil, !scrolling, filterRevision == revision else {
            return
        }
        presentation = filtered
        loading = false
    }
}

/// Recording recency, independent of candidate ranking or extraction time.
enum VoiceReviewMeetingContext {
    static func latestMeetingID(in examples: [VoiceExample], dates: [UUID: Date]) -> UUID? {
        Set(examples.map(\.meetingID)).sorted {
            let left = dates[$0] ?? .distantPast
            let right = dates[$1] ?? .distantPast
            return left == right ? $0.uuidString < $1.uuidString : left > right
        }.first
    }
}

/// Immutable display inputs keep list cells independent of scan progress and playback.
private struct VoiceReviewLauncherRow: View, Equatable {
    let row: VoiceReviewLauncherPresentation.Row
    let unnamed: Bool
    let height: CGFloat
    static let baseHeight =
        ceil(
            NSFont.preferredFont(forTextStyle: .headline).ascender
                - NSFont.preferredFont(forTextStyle: .headline).descender
                + NSFont.preferredFont(forTextStyle: .headline).leading) + 16

    static func == (left: Self, right: Self) -> Bool {
        left.row.id == right.row.id && left.row.title == right.row.title
            && left.row.count == right.row.count && left.row.meetingCount == right.row.meetingCount
            && left.row.recordingID == right.row.recordingID && left.row.recordingTitle == right.row.recordingTitle
            && left.unnamed == right.unnamed
            && left.row.qualityIssue == right.row.qualityIssue && left.row.qualityHelp == right.row.qualityHelp
            && left.height == right.height
    }
    private var summary: String {
        "\(row.title), \(row.count) \(row.count == 1 ? "sample" : "samples") to review, \(row.meetingCount) \(row.meetingCount == 1 ? "meeting" : "meetings")"
            + (row.recordingTitle.map { ", \($0)" } ?? "")
            + (row.qualityHelp.map { ". \($0)" } ?? "")
    }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: unnamed ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                .foregroundStyle(.secondary)
            if unnamed {
                Text(row.title).font(.headline).lineLimit(1).truncationMode(.tail)
            }
            else {
                Text(row.title).font(.headline).lineLimit(1).truncationMode(.tail)
                    .modifier(VoiceReviewLabelStyle(tint: TranscriptSpeakerPalette.color(for: row.id.uuidString)))
            }
            Text("· \(row.count) \(row.count == 1 ? "sample" : "samples") to review")
                .font(.callout).foregroundStyle(.secondary).fixedSize()
            if let issue = row.qualityIssue {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).fixedSize()
                    .accessibilityLabel(issue).help(row.qualityHelp ?? issue)
            }
            if let title = row.recordingTitle {
                Text(title).font(.callout).lineLimit(1).truncationMode(.tail)
                    .modifier(
                        VoiceReviewLabelStyle(
                            tint: TranscriptSpeakerPalette.color(
                                for: row.recordingID.map { "recording:\($0.uuidString)" } ?? "recording"),
                            role: .context))
            }
            if row.meetingCount > 1 {
                Text("+\(row.meetingCount - 1) \(row.meetingCount == 2 ? "meeting" : "meetings")")
                    .font(.callout).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .contentShape(Rectangle()).accessibilityElement(children: .ignore)
        .accessibilityLabel(summary).help(summary)
    }
}
