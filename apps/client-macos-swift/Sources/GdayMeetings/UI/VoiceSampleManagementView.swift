import SwiftUI

/// Maintenance keeps stored evidence reachable independently of the listening queue.
enum VoiceSampleMaintenance {
    static func examples(_ examples: [VoiceExample], personID: UUID?, ignoredOnly: Bool) -> [VoiceExample] {
        examples.filter { example in
            (!ignoredOnly || example.excluded)
                && (personID == nil || example.personID == personID || example.namedPersonID == personID
                    || example.suggestedPersonID == personID
                    || personID.map(example.rejectedPersonIDs.contains) == true)
        }.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
    }
}

struct VoiceSampleManagementView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: VoiceLibraryStore
    var personID: UUID? = nil
    @ViewState private var ignoredOnly = false
    @ViewState private var selected = Set<UUID>()
    @ViewState private var saving = false
    @ViewState private var editingName = false
    @ViewState private var error: String?
    @ViewState private var meetings: [UUID: MeetingListEntry] = [:]
    private struct CombineRequest: Identifiable {
        let id = UUID()
        let examples: [VoiceExample]
    }
    @ViewState private var combining: CombineRequest?
    private var examples: [VoiceExample] {
        VoiceSampleMaintenance.examples(library.examples, personID: personID, ignoredOnly: ignoredOnly)
    }
    private var selectedExamples: [VoiceExample] { examples.filter { selected.contains($0.id) } }
    private var canEdit: Bool {
        library.isLoaded && store.libraryWritable && store.recordingID == nil && !store.isStartingRecording
            && !store.isFinalizingRecording && !saving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Manage Samples").font(.title2.bold())
                Spacer()
                Button("Undo Library Change", systemImage: "arrow.uturn.backward") {
                    guard let token = library.reviewUndoID else { return }
                    perform(.undo, expectedUndoID: token)
                }.disabled(!canEdit || editingName || !library.canUndo || library.reviewUndoID == nil)
                    .help("Undo the most recent saved voice change in this library.")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving || editingName)
            }
            Text("Restore ignored samples, remove assignments, or organize samples. Recordings are kept.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Show Samples", selection: $ignoredOnly) {
                Text("All").tag(false)
                Text("Ignored").tag(true)
            }.pickerStyle(.segmented).disabled(saving || editingName)
            List(selection: $selected) {
                ForEach(examples) { example in
                    HStack(spacing: 12) {
                        VoiceExamplePlaybackButton(example: example).disabled(saving || editingName)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meetings[example.meetingID]?.title ?? "Saved Recording")
                                .font(.headline).lineLimit(1)
                            Text(
                                PersonMatchReviewView.metadataLabel(
                                    example, date: meetings[example.meetingID]?.createdAt)
                            )
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 8) {
                                VoiceSampleNameLabel(
                                    example: example, editing: $editingName,
                                    createAndAssign: { name in await nameSample(example, newName: name) }
                                ) { person in await nameSample(example, personID: person) }
                                .disabled(!canEdit)
                                VoiceSampleStatusLabel(title: status(example), kind: kind(example))
                            }
                        }
                        Spacer()
                    }.padding(.vertical, 4).tag(example.id)
                }
                if !examples.isEmpty {
                    ListCountFooter(
                        text: ListCountFooter.text(count: examples.count, singular: "Sample", plural: "Samples")
                    )
                    .selectionDisabled()
                }
            }.listStyle(.inset).disabled(saving)
                .overlay {
                    if !library.isLoaded {
                        ProgressView("Loading samples…")
                    }
                    else if examples.isEmpty {
                        ContentUnavailableView(
                            "No Samples", systemImage: "waveform",
                            description: Text(
                                ignoredOnly
                                    ? "No ignored samples match this person or library."
                                    : "No stored samples match this person or library."))
                    }
                }
            if let message = error ?? library.errorMessage {
                AppInlineMessage(text: message, systemImage: "exclamationmark.triangle", tint: .red)
            }
            if store.recordingID != nil || store.isStartingRecording || store.isFinalizingRecording {
                Text("Finish the recording before changing samples.").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Menu("Sample Actions") {
                    Button("Restore Ignored Samples") {
                        perform(.exclude(ids: selected, excluded: false), evidence: selectedExamples)
                    }
                    .disabled(!selectedExamples.contains(where: \.excluded))
                    Button("Ignore Samples") {
                        perform(.exclude(ids: selected, excluded: true), evidence: selectedExamples)
                    }
                    .disabled(!selectedExamples.contains { !$0.excluded })
                    Button("Remove Assignment") { perform(.clear(ids: selected), evidence: selectedExamples) }
                        .disabled(
                            !selectedExamples.contains {
                                $0.personID != nil || $0.namedPersonID != nil || $0.suggestedPersonID != nil
                            })
                    Divider()
                    Button("Separate Selected Samples") { perform(.split(ids: selected), evidence: selectedExamples) }
                    Button("Combine Selected Samples") {
                        perform(.merge(ids: selected), evidence: selectedExamples)
                    }.disabled(Set(selectedExamples.map(\.groupID)).count < 2)
                    Button("Combine with Other Samples…") {
                        playback.pause()
                        combining = CombineRequest(examples: selectedExamples)
                    }
                }.disabled(!canEdit || editingName || selectedExamples.isEmpty)
            }
        }.padding(24).frame(width: 760, height: 580)
            .interactiveDismissDisabled(saving || editingName)
            .onChange(of: ignoredOnly) { _, _ in selected.removeAll() }
            .onChange(of: examples.map(\.id)) { _, ids in selected.formIntersection(ids) }
            .onDisappear { playback.pause() }
            .task(id: Set(library.examples.map(\.meetingID))) {
                guard let index = store.libraryIndex else { return }
                let ids = Set(library.examples.map(\.meetingID))
                let loaded = await Task.detached {
                    var entries: [UUID: MeetingListEntry] = [:]
                    for id in ids { if let entry = try? index.entry(id: id) { entries[id] = entry } }
                    return entries
                }.value
                if !Task.isCancelled { meetings = loaded }
            }
            .sheet(item: $combining) { request in
                combineSheet(request)
            }
    }

    private func combineSheet(_ request: CombineRequest) -> some View {
        let selectedGroups = Set(request.examples.map(\.groupID))
        let groups = Dictionary(grouping: library.examples, by: \.groupID)
            .filter { !selectedGroups.contains($0.key) }
            .sorted { $0.key.uuidString < $1.key.uuidString }
        return VStack(alignment: .leading, spacing: 16) {
            Text("Combine Samples").font(.title2.bold())
            Text("Choose the samples to combine with your selection. Person assignments stay unchanged.")
                .font(.callout).foregroundStyle(.secondary)
            List(groups, id: \.key) { group in
                Button {
                    let evidence = request.examples + group.value
                    perform(.merge(ids: Set(evidence.map(\.id))), evidence: evidence, dismissCombine: true)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.value.first.map(name) ?? "Unnamed Person").font(.headline)
                        Text(
                            "\(group.value.count) samples · \(group.value.first.flatMap { meetings[$0.meetingID]?.title } ?? "Saved Recording")"
                        )
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }.frame(height: 250)
                .overlay {
                    if groups.isEmpty { Text("No other samples are available.").foregroundStyle(.secondary) }
                }
            if let error { AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red) }
            HStack {
                Button("Cancel") { combining = nil }.keyboardShortcut(.cancelAction)
                if saving { ProgressView().controlSize(.small) }
            }
        }.padding(24).frame(width: 480).disabled(saving).interactiveDismissDisabled(saving)
    }

    private func perform(
        _ action: VoiceReviewAction, evidence: [VoiceExample]? = nil,
        expectedUndoID: UUID? = nil, dismissCombine: Bool = false
    ) {
        guard canEdit else { return }
        playback.pause()
        saving = true
        error = nil
        Task {
            if await store.reviewVoiceExamples(action, expectedExamples: evidence, expectedUndoID: expectedUndoID) {
                selected.removeAll()
                if dismissCombine { combining = nil }
            }
            else {
                error = store.errorMessage ?? library.errorMessage ?? "Couldn’t save this change. Try again."
            }
            saving = false
        }
    }

    private func nameSample(_ example: VoiceExample, personID: UUID? = nil, newName: String? = nil) async -> Bool {
        guard canEdit else { return false }
        playback.pause()
        saving = true
        defer { saving = false }
        let succeeded: Bool
        if let newName {
            succeeded =
                await store.nameVoiceGroupResult(
                    exampleIDs: [example.id], confirmedExampleID: example.id, personID: nil,
                    newPersonName: newName, expectedExamples: [example]) != nil
        }
        else if let personID {
            succeeded = await store.reviewVoiceExamples(
                .confirm(ids: [example.id], personID: personID), expectedExamples: [example])
        }
        else {
            return false
        }
        if succeeded { editingName = false }
        return succeeded
    }

    private func name(_ example: VoiceExample) -> String {
        let id = example.personID ?? example.namedPersonID ?? example.suggestedPersonID
        return store.people.first { $0.id == id }?.name ?? "Unnamed Person"
    }
    private func status(_ example: VoiceExample) -> String {
        if example.excluded { return "Ignored" }
        if example.manuallyCleared { return "Assignment Removed" }
        switch example.review {
        case .confirmed: return "Confirmed"
        case .rejected: return "Rejected"
        case .suggested, .unassigned: return "Needs Review"
        }
    }
    private func kind(_ example: VoiceExample) -> VoiceSampleStatusKind {
        if example.excluded || example.manuallyCleared { return .ignored }
        switch example.review {
        case .confirmed: return .confirmed
        case .rejected: return .rejected
        case .suggested, .unassigned: return .needsReview
        }
    }
}
