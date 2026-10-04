import SwiftUI

/// Review recorded evidence separately from contact details and speaker labels.
struct VoiceLibraryView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: VoiceLibraryStore
    var personID: UUID? = nil
    @ViewState private var filter = VoiceFilter.review
    @ViewState private var selectedGroup: UUID?
    @ViewState private var selectedExamples = Set<UUID>()
    @ViewState private var assigning = false
    @ViewState private var assignmentExamples = Set<UUID>()
    @ViewState private var merging = false
    private struct RecordingTarget: Identifiable {
        let id: UUID
        let rowID: UUID?
    }
    @ViewState private var selectedRecording: RecordingTarget?
    @ViewState private var localError: String?
    @ViewState private var meetingEntries: [UUID: MeetingListEntry] = [:]
    @ViewState private var attemptedRecovery = Set<UUID>()
    @ViewState private var recovering = Set<UUID>()
    @ViewState private var recoveryErrors: [UUID: String] = [:]

    private enum VoiceFilter: String, CaseIterable, Identifiable {
        case review = "Review"
        case unnamed = "Unnamed"
        case named = "Named"
        case all = "All"
        var id: Self { self }
    }
    private struct Group: Identifiable {
        let id: UUID
        let examples: [VoiceExample]
    }
    private var person: Person? { store.people.first { $0.id == personID } }
    private var groups: [Group] {
        let eligible = library.examples.filter { example in
            if let personID {
                return example.personID == personID || example.suggestedPersonID == personID
                    || example.rejectedPersonIDs.contains(personID)
            }
            switch filter {
            case .review:
                return example.review == .suggested
                    && !example.excluded && example.review != .rejected && !example.manuallyCleared
            case .unnamed: return example.personID == nil && example.review != .suggested
            case .named: return example.personID != nil
            case .all: return true
            }
        }
        return Dictionary(grouping: eligible, by: \.groupID).map { Group(id: $0.key, examples: $0.value) }
            .sorted {
                ($0.examples.map(\.createdAt).max() ?? .distantPast)
                    > ($1.examples.map(\.createdAt).max() ?? .distantPast)
            }
    }
    private var current: Group? { groups.first { $0.id == selectedGroup } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.map { "\($0.name)’s Voice Samples" } ?? "Review Voices").font(.title2.bold())
                    Text("Listen to examples before confirming a person.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Undo", systemImage: "arrow.uturn.backward") { library.undo() }
                    .disabled(!library.canUndo || !store.libraryWritable)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    if personID == nil {
                        Picker("Voices", selection: $filter) {
                            ForEach(VoiceFilter.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).padding(.horizontal, 12).padding(.top, 12)
                    }
                    List(selection: $selectedGroup) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                Label(groupTitle(group), systemImage: groupIcon(group)).font(.headline)
                                Text(groupSummary(group))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(group.id)
                        }
                    }
                    Text("Select individual examples to change their assignments.")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                VStack(alignment: .leading, spacing: 0) {
                    if let current {
                        evidenceHeader(current)
                        Divider()
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(current.examples.sorted { ($0.start ?? 0) < ($1.start ?? 0) }) { example in
                                    exampleCard(example)
                                }
                            }.padding(16)
                        }
                        Divider()
                        selectionActions
                    }
                    else {
                        ContentUnavailableView {
                            Label(groups.isEmpty ? "No Voice Samples" : "Select a Voice", systemImage: "waveform")
                        } description: {
                            Text(
                                groups.isEmpty
                                    ? "Use Speaker Association below to find voice examples in saved recordings."
                                    : "Listen to recording excerpts and review their assignments.")
                        }
                    }
                }.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = localError ?? library.errorMessage ?? playback.errorMessage,
                !recoveryErrors.values.contains(error)
            {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 8)
            }
            Divider()
            VoicePreparationControls(library: library).padding(16)
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 600, idealHeight: 720)
        .onChange(of: selectedGroup) { _, _ in selectedExamples.removeAll() }
        .onChange(of: filter) { _, _ in
            selectedGroup = groups.first?.id
            selectedExamples.removeAll()
        }
        .onAppear { selectedGroup = groups.first?.id }
        .onChange(of: library.examples) { _, _ in
            if !groups.contains(where: { $0.id == selectedGroup }) { selectedGroup = groups.first?.id }
            selectedExamples.formIntersection(library.examples.map(\.id))
        }
        .task(id: selectedGroup) { await loadMeetingEntries() }
        .sheet(isPresented: $assigning) {
            VoicePersonAssignmentView(count: assignmentExamples.count) { personID in
                guard library.confirm(ids: assignmentExamples, personID: personID) else { return false }
                selectedExamples.removeAll()
                return true
            }
        }
        .sheet(isPresented: $merging) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Merge Voice Groups").font(.title2.bold())
                Text("Move the selected examples into another group. Person assignments stay unchanged.")
                    .foregroundStyle(.secondary)
                List(allGroups.filter { $0.id != selectedGroup }) { group in
                    HStack {
                        Button {
                            guard library.merge(ids: selectedExamples.union(group.examples.map(\.id))) else { return }
                            selectedExamples.removeAll()
                            merging = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(groupTitle(group)).font(.headline)
                                Text(groupSummary(group))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if let example = group.examples.first(where: \.isPlayable) {
                            VoiceExamplePlaybackButton(example: example)
                        }
                    }
                }.frame(height: 240)
                Button("Cancel") { merging = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 480)
        }
        .sheet(item: $selectedRecording) { target in
            VStack {
                HStack {
                    Spacer()
                    Button("Done") { selectedRecording = nil }.keyboardShortcut(.cancelAction)
                }
                .padding()
                MeetingDetailView(meetingID: target.id, initialTranscriptRowID: target.rowID)
            }.frame(width: 880, height: 680)
        }
    }

    private func groupTitle(_ group: Group) -> String {
        let names = Set(group.examples.compactMap { name(for: $0.personID) })
        if names.count == 1, let name = names.first { return name }
        if names.count > 1 { return "Multiple Assignments" }
        if let suggestion = group.examples.compactMap({ name(for: $0.suggestedPersonID) }).first {
            return "Suggested: \(suggestion)"
        }
        return "Unnamed Voice"
    }

    private var allGroups: [Group] {
        Dictionary(grouping: library.examples, by: \.groupID).map { Group(id: $0.key, examples: $0.value) }
            .sorted { groupTitle($0).localizedStandardCompare(groupTitle($1)) == .orderedAscending }
    }

    private func groupIcon(_ group: Group) -> String {
        group.examples.contains { $0.personID != nil } ? "person.crop.circle" : "waveform"
    }

    private func groupSummary(_ group: Group) -> String {
        let examples = group.examples.count
        let recordings = Set(group.examples.map(\.meetingID)).count
        return
            "\(examples) \(examples == 1 ? "example" : "examples") · \(recordings) \(recordings == 1 ? "recording" : "recordings")"
    }

    private func name(for id: UUID?) -> String? { store.people.first { $0.id == id }?.name }

    private func evidenceHeader(_ group: Group) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(groupTitle(group)).font(.title3.bold())
            }
            Spacer()
            Button("Select All") { selectedExamples = Set(group.examples.map(\.id)) }
        }.padding(16)
    }

    private func exampleCard(_ example: VoiceExample) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Toggle(
                    "Select Example",
                    isOn: Binding(
                        get: { selectedExamples.contains(example.id) },
                        set: {
                            if $0 {
                                selectedExamples.insert(example.id)
                            }
                            else {
                                selectedExamples.remove(example.id)
                            }
                        }
                    )
                ).toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Select voice example")
                VoiceExamplePlaybackButton(example: example)
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        meetingEntries[example.meetingID]?.title
                            ?? store.meetings.first { $0.id == example.meetingID }?.title ?? "Saved Recording"
                    )
                    .font(.headline).lineLimit(2)
                    if let date = meetingEntries[example.meetingID]?.createdAt {
                        Text(date, format: .dateTime.month(.abbreviated).day().year()).font(.caption).foregroundStyle(
                            .secondary)
                    }
                    HStack {
                        Text(sourceTitle(example.source))
                        if let start = example.start, let end = example.end {
                            Button("\(TranscriptRow<Text>.timestamp(start))–\(TranscriptRow<Text>.timestamp(end))") {
                                open(example, playAtStart: true)
                            }
                            .buttonStyle(.link).monospacedDigit()
                            .disabled(playback.isPlaybackBlocked || !audioAvailable(example))
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                    Label(status(example), systemImage: example.excluded ? "minus.circle" : "person.crop.circle")
                        .font(.caption)
                }
                Spacer(minLength: 0)
                Button("Open Recording") { open(example) }.controlSize(.small)
            }
            if !audioAvailable(example) {
                HStack {
                    Text(
                        recoveryErrors[example.id] ?? library.availabilityReason(for: example)
                            ?? "This example’s audio excerpt is unavailable."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if example.range == nil {
                        if recovering.contains(example.id) { ProgressView().controlSize(.small) }
                        Button("Find Playable Example") { Task { await recover(example) } }
                            .controlSize(.small).disabled(recovering.contains(example.id) || !store.libraryWritable)
                    }
                }
            }
            HStack(spacing: 8) {
                if let candidate = candidateID(example),
                    let candidateName = name(for: candidate)
                {
                    if example.review != .confirmed {
                        Button("Confirm \(candidateName)") { library.confirm(ids: [example.id], personID: candidate) }
                    }
                    Button("Not \(candidateName)") { library.reject(ids: [example.id], personID: candidate) }
                }
                Button("Assign…") {
                    selectedExamples = [example.id]
                    presentAssignment(ids: [example.id])
                }
                Spacer()
                Menu {
                    Button(example.excluded ? "Use for Voice Recognition" : "Don’t Use for Voice Recognition") {
                        library.exclude(ids: [example.id], excluded: !example.excluded)
                    }
                    if example.personID != nil { Button("Remove Assignment") { library.clear(ids: [example.id]) } }
                    Button("Separate from Group") { library.split(ids: [example.id]) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).fixedSize().help("Voice example actions")
                .accessibilityLabel("Voice example actions")
            }.controlSize(.small).disabled(!store.libraryWritable)
            VoiceExampleDetailsView(library: library, example: example)
        }
        .padding(12)
        .background(
            selectedExamples.contains(example.id) ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private var selectionActions: some View {
        HStack {
            Text("\(selectedExamples.count) selected").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Assign Selected…") { presentAssignment(ids: selectedExamples) }.disabled(selectedExamples.isEmpty)
            Menu("Group") {
                Button("Merge with Another Group…") { merging = true }
                    .disabled(allGroups.count < 2)
                Button("Separate Selected Examples") { library.split(ids: selectedExamples) }
            }.fixedSize().disabled(selectedExamples.isEmpty)
            Menu("More") {
                Button("Don’t Use for Voice Recognition") { library.exclude(ids: selectedExamples) }
                Button("Use for Voice Recognition") { library.exclude(ids: selectedExamples, excluded: false) }
                Button("Remove Assignment") { library.clear(ids: selectedExamples) }
            }.fixedSize().disabled(selectedExamples.isEmpty)
        }.padding(12).disabled(!store.libraryWritable)
    }

    private func status(_ example: VoiceExample) -> String {
        if example.excluded { return "Not used for voice recognition" }
        switch example.review {
        case .confirmed: return name(for: example.personID).map { "Confirmed: \($0)" } ?? "Confirmed"
        case .suggested: return name(for: example.suggestedPersonID).map { "Suggested: \($0)" } ?? "Needs Review"
        case .rejected: return "Assignment Rejected"
        case .unassigned: return example.manuallyCleared ? "Assignment Removed" : "Unassigned"
        }
    }

    private func candidateID(_ example: VoiceExample) -> UUID? {
        example.personID ?? example.suggestedPersonID
    }

    private func presentAssignment(ids: Set<UUID>) {
        assignmentExamples = ids
        assigning = true
    }

    private func sourceTitle(_ source: String) -> String {
        if source == "microphone" || source == "mic" { return "Microphone" }
        if source == "system" || source == "sys" { return "System Audio" }
        return "Recording Audio"
    }

    private func audioAvailable(_ example: VoiceExample) -> Bool {
        guard example.isPlayable, library.audioIsCurrent(example), let file = example.audioFile else { return false }
        return FileManager.default.fileExists(
            atPath: store.directory(for: example.meetingID).appendingPathComponent(file).path)
    }

    private func loadMeetingEntries() async {
        guard let index = store.libraryIndex else { return }
        let ids = Set(current?.examples.map(\.meetingID) ?? [])
        let entries = await Task.detached(priority: .userInitiated) {
            var values: [UUID: MeetingListEntry] = [:]
            for id in ids { if let entry = try? index.entry(id: id) { values[id] = entry } }
            return values
        }.value
        guard !Task.isCancelled else { return }
        meetingEntries.merge(entries) { _, new in new }
        for example in current?.examples ?? [] where example.range == nil {
            guard !Task.isCancelled else { return }
            guard attemptedRecovery.insert(example.id).inserted else { continue }
            await recover(example)
        }
    }

    private func recover(_ example: VoiceExample) async {
        guard !recovering.contains(example.id), store.libraryWritable else { return }
        recovering.insert(example.id)
        recoveryErrors.removeValue(forKey: example.id)
        defer { recovering.remove(example.id) }
        let updated = await store.voicePreparation.findPlayableExample(
            exampleID: example.id, directory: store.directory(for: example.meetingID))
        if updated == nil {
            recoveryErrors[example.id] =
                store.voicePreparation.errorMessage
                ?? "Couldn’t find a playable example. Open the recording to review its transcript."
        }
    }

    private func open(_ example: VoiceExample, playAtStart: Bool = false) {
        guard store.ensureMeetingLoaded(id: example.meetingID),
            let meeting = store.meeting(id: example.meetingID)
        else {
            localError = "Couldn’t open this recording."
            return
        }
        selectedRecording = RecordingTarget(
            id: meeting.id, rowID: VoiceExampleTranscriptNavigation.rowID(for: example, meeting: meeting))
        localError = nil
        if playAtStart, let start = example.start, let file = example.audioFile {
            playback.play(
                meeting: meeting, files: [store.directory(for: meeting.id).appendingPathComponent(file)], at: start)
        }
    }
}

struct PersonVoiceSamplesView: View {
    @ObservedObject var library: VoiceLibraryStore
    let personID: UUID
    let review: () -> Void
    private var examples: [VoiceExample] { library.examples(for: personID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Voice Samples", systemImage: "waveform").font(.headline)
                Spacer()
                Button("Review Voice Samples…", action: review)
            }
            if examples.isEmpty {
                Text("No reviewed voice samples. Review recording excerpts to confirm this person’s voice.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            else {
                Text(
                    "\(examples.filter { $0.review == .confirmed && !$0.excluded }.count) confirmed · \(examples.filter { !$0.excluded && !$0.manuallyCleared && $0.review == .suggested }.count) to review"
                )
                .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    ForEach(
                        Array(
                            examples.filter {
                                $0.isPlayable && !$0.excluded && $0.review != .rejected && !$0.manuallyCleared
                            }.prefix(2))
                    ) { example in
                        HStack(spacing: 4) {
                            VoiceExamplePlaybackButton(example: example)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(
                                    example.review == .confirmed
                                        ? "Confirmed Example" : "Needs Review"
                                ).font(.caption)
                                if let start = example.start, let end = example.end {
                                    Text(
                                        "\(TranscriptRow<Text>.timestamp(start))–\(TranscriptRow<Text>.timestamp(end))"
                                    )
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct VoicePreparationControls: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var library: VoiceLibraryStore
    @ViewState private var expanded = false
    @ViewState private var providerID: UUID?
    @ViewState private var loading = false
    @ViewState private var error: String?
    private var provider: ServiceProvider? {
        store.settings.serviceProviders.first { $0.id == providerID }
    }
    private var active: Bool {
        library.jobs.contains { $0.state == .running || $0.state == .queued }
    }
    var body: some View {
        DisclosureGroup("Speaker Association", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Prepare reviewed examples for a provider, or find voices in saved recordings. Review examples before using them to identify people."
                )
                .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Picker("Provider", selection: $providerID) {
                        Text("Choose a Provider").tag(UUID?.none)
                        ForEach(
                            store.settings.serviceProviders.filter {
                                $0.kind.capabilities.contains(.speakerRecognition)
                                    || $0.kind.capabilities.contains(.diarization)
                            }
                        ) { provider in
                            Text(provider.name).tag(Optional(provider.id))
                        }
                    }.frame(maxWidth: 360)
                    if loading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                HStack {
                    Button("Prepare Reviewed Voices") { start(discover: false) }
                        .disabled(!canStart)
                    Button("Find Voices in Recordings") { start(discover: true) }
                        .disabled(!canStart)
                }
                Text("Recordings without voice examples need the Community-1 Speaker Labeling model.")
                    .font(.caption).foregroundStyle(.secondary)
                if let provider {
                    if let reason = VoiceLibraryPreparation.capability(for: provider).unavailableReason {
                        Label(reason, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    else {
                        Text("Voice examples are processed on this Mac. Compatible prepared examples are reused.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                else {
                    Text("Choose a provider above. Add providers in Settings → Service Providers.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.recordingID != nil {
                    Text("Finish the recording before preparing voice examples.").font(.caption).foregroundStyle(
                        .secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                ForEach(Array(library.jobs.suffix(3).reversed())) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.providerName).font(.headline)
                            Text("\(job.progress) · \(stateTitle(job.state))").font(.caption).foregroundStyle(
                                .secondary)
                            if !job.failures.isEmpty {
                                DisclosureGroup("\(job.failures.count) Examples Need Attention") {
                                    ForEach(job.failures.keys.sorted(), id: \.self) { key in
                                        Text(job.failures[key] ?? "Couldn’t prepare this example.")
                                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }.disclosureGroupStyle(AppDisclosureStyle())
                            }
                        }
                        Spacer()
                        if job.state == .running || job.state == .queued {
                            Button("Pause") { store.voicePreparation.pause(jobID: job.id) }
                        }
                        else if job.state == .paused || job.state == .failed {
                            Button(job.state == .failed ? "Retry" : "Resume") {
                                store.voicePreparation.resume(jobID: job.id, directory: { store.directory(for: $0) })
                            }.disabled(active || !store.libraryWritable || store.recordingID != nil)
                        }
                    }
                }
            }.padding(.top, 12)
        }
        .disclosureGroupStyle(AppDisclosureStyle())
        .onAppear {
            providerID =
                store.settings.speakerRecognitionProviderID
                ?? store.settings.serviceProviders.first { VoiceLibraryPreparation.capability(for: $0).isAvailable }?.id
        }
    }
    private var canStart: Bool {
        !loading && !active && store.libraryWritable && store.recordingID == nil
            && provider.map { VoiceLibraryPreparation.capability(for: $0).isAvailable } == true
    }
    private func stateTitle(_ state: VoicePreparationState) -> String {
        switch state {
        case .queued: return "Queued"
        case .running: return "Preparing"
        case .paused: return "Paused"
        case .completed: return "Complete"
        case .failed: return "Needs Attention"
        }
    }
    private func start(discover: Bool) {
        guard let provider else { return }
        loading = true
        error = nil
        Task {
            defer { loading = false }
            do {
                let meetings = try await store.voicePreparationMeetings()
                store.voicePreparation.start(
                    provider: provider, meetings: meetings,
                    directory: { store.directory(for: $0) }, discover: discover)
                error = store.voicePreparation.errorMessage
            }
            catch { self.error = "Couldn’t load recordings. " + error.localizedDescription }
        }
    }
}

private struct VoiceExamplePlaybackButton: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let example: VoiceExample
    private var playing: Bool {
        guard let start = example.start, let end = example.end else { return false }
        return playback.meetingID == example.meetingID && playback.excerptRange == start..<end && playback.isPlaying
            && playback.audioURL(forTrack: playback.selectedTrack)?.lastPathComponent == example.audioFile
    }
    private var available: Bool {
        guard example.isPlayable, store.voiceLibrary.audioIsCurrent(example), let file = example.audioFile else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: store.directory(for: example.meetingID).appendingPathComponent(file).path)
    }
    var body: some View {
        Button {
            if playing {
                playback.pause()
                return
            }
            guard store.ensureMeetingLoaded(id: example.meetingID),
                let meeting = store.meeting(id: example.meetingID), let file = example.audioFile,
                let start = example.start, let end = example.end
            else { return }
            playback.playExcerpt(
                meeting: meeting, directory: store.directory(for: meeting.id), audioFile: file,
                start: start, end: end)
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless).modifier(ActionHover()).disabled(!available || playback.isPlaybackBlocked)
        .help(!available ? "The recording excerpt is unavailable." : playing ? "Pause excerpt" : "Play excerpt")
        .accessibilityLabel(playing ? "Pause excerpt" : "Play excerpt")
    }
}

private struct VoicePersonAssignmentView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let assign: (UUID) -> Bool
    @ViewState private var query = ""
    @ViewState private var error: String?
    @FocusState private var searchFocused: Bool
    private var name: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [Person] { TranscriptSpeakerSearch.matches(store.people, query: query) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Assign \(count) Selected \(count == 1 ? "Example" : "Examples")").font(.title2.bold())
            Text("Only the selected examples will be confirmed for this person.").foregroundStyle(.secondary)
            TextField("Search people or enter a name", text: $query)
                .focused($searchFocused)
                .onSubmit { if let person = matches.first { complete(person.id) } }
            List(matches) { person in
                Button {
                    complete(person.id)
                } label: {
                    Text(person.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }.buttonStyle(ActionButtonStyle())
            }.frame(height: 220)
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !name.isEmpty
                    && !store.people.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
                {
                    Button("Create Person") {
                        let id = store.addPerson(name: name)
                        if store.people.contains(where: { $0.id == id }) {
                            error = nil
                        }
                        else {
                            error = store.errorMessage ?? "Couldn’t save this person. Try again."
                        }
                    }
                }
            }
        }.padding(24).frame(width: 440)
            .task { searchFocused = true }
    }
    private func complete(_ personID: UUID) {
        guard store.people.contains(where: { $0.id == personID }) else {
            error = store.errorMessage ?? "Couldn’t save this person. Try again."
            return
        }
        if assign(personID) {
            dismiss()
        }
        else {
            error = store.voiceLibrary.errorMessage ?? "Couldn’t save the assignment. Try again."
        }
    }
}
