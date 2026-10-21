import SwiftUI

/// Named people and proposed unnamed people open the same listening session.
struct PeopleMatchReviewLauncher: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: VoiceLibraryStore
    @ViewState private var query = ""
    @ViewState private var managingSamples = false
    private struct ReviewTarget: Identifiable {
        let id: UUID
        let personID: UUID?
        var group: VoiceIdentificationGroup? = nil
    }
    @ViewState private var target: ReviewTarget?
    @ViewState private var pendingRecording: VoiceExampleRecordingTarget?
    @ViewState private var recording: VoiceExampleRecordingTarget?
    @ViewState private var candidates: [UUID: [VoiceExample]] = [:]
    @ViewState private var unnamedGroups: [VoiceIdentificationGroup] = []
    @ViewState private var titles: [UUID: String] = [:]
    @ViewState private var meetingDates: [UUID: Date] = [:]
    @ViewState private var loading = true
    @ViewState private var loadedSnapshot: SnapshotRequest?
    @ViewState private var error: String?
    @ViewState private var loadRequest = UUID()
    private var people: [Person] {
        store.people.filter { person in
            let examples = candidates[person.id] ?? []
            return !examples.isEmpty
                && (query.isEmpty || person.name.localizedStandardContains(query)
                    || matchesRecording(examples))
        }.sorted {
            let left = candidates[$0.id]?.count ?? 0
            let right = candidates[$1.id]?.count ?? 0
            return left == right ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : left > right
        }
    }
    private var visibleGroups: [VoiceIdentificationGroup] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return unnamedGroups }
        return unnamedGroups.filter {
            "Unnamed Person".localizedStandardContains(query) || matchesRecording($0.examples)
        }
    }
    private struct SnapshotRequest: Equatable {
        let people: Set<UUID>
        let revision: Int
        let metadataRevision: Int
    }
    private var snapshotRequest: SnapshotRequest {
        SnapshotRequest(
            people: Set(store.people.map(\.id)), revision: library.reviewEvidenceRevision,
            metadataRevision: library.reviewMetadataRevision)
    }
    private var visibleCount: Int { people.count + visibleGroups.count }

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
                if !people.isEmpty {
                    Section("People") {
                        ForEach(people) { person in
                            Button {
                                target = ReviewTarget(id: person.id, personID: person.id)
                            } label: {
                                launcherRow(
                                    title: person.name, count: candidates[person.id]?.count ?? 0,
                                    meetings: Set((candidates[person.id] ?? []).map(\.meetingID)).count, unnamed: false,
                                    recordingTitle: recordingTitle(for: candidates[person.id] ?? []))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if !visibleGroups.isEmpty {
                    Section("Unnamed People") {
                        ForEach(visibleGroups) { group in
                            Button {
                                target = ReviewTarget(id: group.id, personID: nil, group: group)
                            } label: {
                                launcherRow(
                                    title: "Unnamed Person", count: group.examples.count,
                                    meetings: Set(group.examples.map(\.meetingID)).count, unnamed: true,
                                    recordingTitle: recordingTitle(for: group.examples))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if visibleCount > 0 {
                    ListCountFooter(
                        text:
                            "\(people.count) \(people.count == 1 ? "Person" : "People") · \(visibleGroups.count) Unnamed \(visibleGroups.count == 1 ? "Person" : "People")"
                    ).selectionDisabled()
                }
            }.listStyle(.inset).disabled(loading || error != nil)
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
            HStack(alignment: .top, spacing: 16) {
                VoicePreparationControls(library: library)
                Spacer(minLength: 0)
                Button("Manage Samples…") { managingSamples = true }.fixedSize()
            }
        }.padding(24).frame(width: 660, height: 600)
            .task(id: snapshotRequest) { await loadCandidates() }
            .sheet(isPresented: $managingSamples) { VoiceSampleManagementView(library: library) }
            .sheet(
                item: $target,
                onDismiss: {
                    if let pendingRecording {
                        recording = pendingRecording
                        self.pendingRecording = nil
                    }
                    Task { await loadCandidates() }
                }
            ) { selected in
                PersonMatchReviewView(
                    library: library, personID: selected.personID,
                    initialGroup: selected.group
                ) { id in
                    pendingRecording = id
                    target = nil
                }
            }
            .sheet(isPresented: Binding(get: { recording != nil }, set: { if !$0 { recording = nil } })) {
                if let recording {
                    MeetingDetailSheet(
                        meetingID: recording.id, initialTranscriptRowID: recording.transcriptRowID,
                        initialContentTab: recording.opensTranscript ? .transcript : nil
                    ) { self.recording = nil }
                }
            }
    }

    private func launcherRow(
        title: String, count: Int, meetings: Int, unnamed: Bool, recordingTitle: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: unnamed ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                .foregroundStyle(.secondary)
            Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
            if let recordingTitle {
                Text("· \(count) \(count == 1 ? "sample" : "samples")")
                    .font(.callout).foregroundStyle(.secondary).fixedSize()
                Text(recordingTitle)
                    .font(.callout).lineLimit(1).truncationMode(.tail)
                    .modifier(VoiceReviewLabelStyle(tint: .systemBlue))
                    .help(recordingTitle)
                if meetings > 1 {
                    Text("+\(meetings - 1) \(meetings == 2 ? "meeting" : "meetings")").font(.callout).foregroundStyle(
                        .secondary
                    ).fixedSize()
                }
            }
            else {
                Text(
                    "· \(count) \(count == 1 ? "sample" : "samples") to review · \(meetings) \(meetings == 1 ? "meeting" : "meetings")"
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize()
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }.padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .help(
                "\(title) · \(count) samples to review · \(meetings) meetings"
                    + (recordingTitle.map { " · \($0)" } ?? ""))
    }

    private func recordingTitle(for examples: [VoiceExample]) -> String? {
        guard
            let meetingID = VoiceReviewMeetingContext.latestMeetingID(
                in: examples, dates: meetingDates)
        else { return nil }
        return titles[meetingID] ?? "Saved Recording"
    }

    private func matchesRecording(_ examples: [VoiceExample]) -> Bool {
        examples.contains { example in
            let title = titles[example.meetingID] ?? store.meetings.first { $0.id == example.meetingID }?.title ?? ""
            return title.localizedStandardContains(query)
        }
    }

    private func loadCandidates(forceRefresh: Bool = false) async {
        guard target == nil else { return }
        let request = UUID()
        loadRequest = request
        let queryState = snapshotRequest
        loading =
            loadedSnapshot?.people != queryState.people
            || loadedSnapshot?.metadataRevision != queryState.metadataRevision
        error = nil
        do {
            let snapshot = try await library.reviewSnapshot(
                for: Set(store.people.map(\.id)), forceRefresh: forceRefresh)
            let result = snapshot.candidates
            guard !Task.isCancelled, loadRequest == request else { return }
            let groups = snapshot.unnamedGroups
            let meetingIDs = Set(
                result.values.flatMap { $0.map(\.meetingID) } + groups.flatMap { $0.examples.map(\.meetingID) })
            var nextTitles = Dictionary(uniqueKeysWithValues: store.meetings.map { ($0.id, $0.title) })
            var nextDates = Dictionary(uniqueKeysWithValues: store.meetings.map { ($0.id, $0.createdAt) })
            if let index = store.libraryIndex {
                let loaded = await Task.detached {
                    var values: [UUID: String] = [:]
                    var dates: [UUID: Date] = [:]
                    for id in meetingIDs {
                        if let entry = try? index.entry(id: id) {
                            values[id] = entry.title
                            dates[id] = entry.createdAt
                        }
                    }
                    return (values, dates)
                }.value
                guard !Task.isCancelled, loadRequest == request else { return }
                nextTitles.merge(loaded.0) { _, new in new }
                nextDates.merge(loaded.1) { _, new in new }
            }
            // Publish context and queues together so counts and titles describe
            // the same pending evidence, including after returning from review.
            titles = nextTitles
            meetingDates = nextDates
            candidates = result
            unnamedGroups = groups
            loadedSnapshot = snapshotRequest
        }
        catch {
            guard !Task.isCancelled, loadRequest == request else { return }
            self.error = error.localizedDescription
            candidates = [:]
            unnamedGroups = []
        }
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
