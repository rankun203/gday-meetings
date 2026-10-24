import SwiftUI

/// A listening session retains its candidate order and focus while references are compared.
struct PersonMatchReviewView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let library: VoiceLibraryStore
    var personID: UUID? = nil
    var initialGroup: VoiceIdentificationGroup? = nil

    var body: some View {
        PersonMatchReviewContent(
            store: store, playback: playback, library: library, personID: personID,
            initialGroup: initialGroup
        ).equatable()
    }
    static func metadataLabel(_ example: VoiceExample, date: Date?) -> String {
        VoiceReviewPresentation.metadataLabel(example, date: date)
    }
    static func metadataHelp(_ example: VoiceExample, date: Date?) -> String {
        VoiceReviewPresentation.metadataHelp(example, date: date)
    }
}

private struct PersonMatchReviewContent: View, Equatable {
    let store: MeetingStore
    let playback: MeetingPlayback
    let library: VoiceLibraryStore
    let personID: UUID?
    let initialGroup: VoiceIdentificationGroup?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var observation: VoiceReviewObservation
    @ViewState private var session = VoiceMatchReviewSession()
    @ViewState private var presentation = VoiceReviewPresentation.empty
    @ViewState private var presentationCache = VoiceReviewPresentationCache()
    @ViewState private var presentationRequest = UUID()
    @ViewState private var presentationDirectoryRevision: UUID?
    @ViewState private var audioSelection = VoiceReviewAudioSelection()
    private var references: [VoiceExample] { presentation.references }

    init(
        store: MeetingStore, playback: MeetingPlayback, library: VoiceLibraryStore,
        personID: UUID?, initialGroup: VoiceIdentificationGroup?
    ) {
        self.store = store
        self.playback = playback
        self.library = library
        self.personID = personID
        self.initialGroup = initialGroup
        _observation = StateObject(
            wrappedValue: VoiceReviewObservation(store: store, library: library, playback: playback))
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store && lhs.playback === rhs.playback && lhs.library === rhs.library
            && lhs.personID == rhs.personID && lhs.initialGroup?.id == rhs.initialGroup?.id
    }

    private struct PresentationRevision: Equatable {
        let metadata: Int
        let directory: UUID
        let index: UUID
        let person: UUID?
        let saving: Bool
        let loading: Bool
    }
    private var presentationRevision: PresentationRevision {
        .init(
            metadata: observation.snapshot.reviewMetadataRevision,
            directory: observation.snapshot.directoryRevision, index: observation.snapshot.meetingIndexRevision,
            person: reviewPersonID, saving: saving, loading: loading)
    }
    @ViewState private var loading = true
    @ViewState private var checkingRequest: UUID?
    private var checkingMatches: Bool { checkingRequest != nil }
    @ViewState private var loadFailed = false
    @ViewState private var saving = false
    private enum SavingAction { case confirm, reject, ignore, name, undo, alternate }
    @ViewState private var savingAction: SavingAction?
    @ViewState private var initialized = false
    @ViewState private var editingName = false
    @ViewState private var nameFocused = false
    @ViewState private var error: String?
    @ViewState private var active = false
    @ViewState private var playbackOwner: UUID?
    @ViewState private var recording: VoiceExampleRecordingTarget?
    @ViewState private var openingRecording = false
    @ViewState private var alternateTask: Task<Void, Never>?
    @ViewState private var alternateRequest: UUID?
    @ViewState private var alternateMessage: String?
    @ViewState private var loadRequest = UUID()
    @ViewState private var groupEvidence: [VoiceExample] = []
    private struct GroupNamingContext: Identifiable {
        let id = UUID()
        let anchor: VoiceExample
        let examples: [VoiceExample]
    }
    @ViewState private var namingContext: GroupNamingContext?

    private enum Selection: Hashable {
        case candidate(UUID)
        case reference(UUID)
    }
    private var selection: Binding<Selection?> {
        Binding(
            get: {
                if let id = session.referenceID { return .reference(id) }
                return session.candidateID.map(Selection.candidate)
            },
            set: { value in
                switch value {
                case .candidate(let id): session.selectCandidate(id)
                case .reference(let id): session.selectReference(id)
                case nil: break
                }
            })
    }
    private var reviewPersonID: UUID? { session.personID ?? personID }
    private var personName: String {
        observation.snapshot.people.first { $0.id == reviewPersonID }?.name ?? "Unidentified Voice"
    }
    private var current: VoiceExample? {
        if let id = session.referenceID { return references.first { $0.id == id } }
        return session.examples.first { $0.id == session.candidateID }
    }
    private var canUndo: Bool {
        guard let last = session.history.last else { return false }
        return last.undoID == nil || (observation.snapshot.canUndo && last.undoID == observation.snapshot.reviewUndoID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(personName).font(.title2.bold()).lineLimit(2)
                    Text("Review Matches").font(.headline).foregroundStyle(.secondary)
                    if !loading && !loadFailed && !session.examples.isEmpty {
                        Text(
                            "\(session.decidedCount) of \(session.examples.count) reviewed · \(session.skippedCount) skipped"
                                + (session.noLongerNeededIDs.isEmpty
                                    ? "" : " · \(session.noLongerNeededIDs.count) no longer needed")
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: undo) {
                    HStack {
                        Image(systemName: "arrow.uturn.backward")
                            .opacity(saving && savingAction == .undo ? 0 : 1)
                            .overlay {
                                if saving && savingAction == .undo { ProgressView().controlSize(.mini) }
                            }
                        Text("Undo")
                    }
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canUndo || saving || editingName || !observation.snapshot.libraryWritable)
                Button("Done") {
                    cancelAlternative()
                    playback.endReviewPlayback(playbackOwner)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction).disabled(saving && savingAction != .alternate)
            }.padding(24)
            Divider()
            HSplitView {
                sampleList.frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                VStack(alignment: .leading, spacing: 0) {
                    if let example = current {
                        focusedSample(example, isReference: session.referenceID != nil)
                    }
                    else if loading {
                        ProgressView("Finding samples…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    else if checkingMatches || saving {
                        ProgressView("Checking for more matches…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    else if loadFailed {
                        ContentUnavailableView {
                            Label("Couldn’t Load Samples", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text("Try again when the voice library has finished updating.")
                        } actions: {
                            Button("Try Again") { Task { await loadCandidates(useProvided: false) } }
                        }
                    }
                    else if session.examples.isEmpty {
                        ContentUnavailableView {
                            Label(
                                session.additionalCandidates.isEmpty
                                    ? "No Matches to Review" : "Samples Ready to Review",
                                systemImage: "waveform")
                        } description: {
                            Text(
                                session.additionalCandidates.isEmpty
                                    ? "No useful voice examples need review right now."
                                    : "New useful examples are available when you want to review more.")
                        } actions: {
                            Button(
                                session.additionalCandidates.isEmpty ? "Check for More Samples" : "Review More Samples"
                            ) {
                                Task { await loadCandidates(useProvided: false, admitNewCandidates: true) }
                            }
                        }
                    }
                    else {
                        ContentUnavailableView {
                            Label("Review Complete", systemImage: "checkmark.circle")
                        } description: {
                            if session.skippedCount > 0 {
                                Text(
                                    "\(session.skippedCount) \(session.skippedCount == 1 ? "sample" : "samples") skipped."
                                )
                            }
                        } actions: {
                            if !session.additionalCandidates.isEmpty {
                                Button("Review More Samples") {
                                    Task { await loadCandidates(useProvided: true, admitNewCandidates: true) }
                                }
                            }
                            else {
                                Text("You’ve reviewed the useful examples in this batch.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.readingBackground)
            }
            if let message = error ?? observation.snapshot.playbackError {
                AppInlineMessage(text: message, systemImage: "exclamationmark.triangle", tint: .red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
        .frame(minWidth: 840, idealWidth: 960, minHeight: 560, idealHeight: 650)
        .interactiveDismissDisabled(saving && savingAction != .alternate)
        .task {
            active = true
            playbackOwner = playback.beginReviewPlayback()
            await loadCandidates(useProvided: true)
        }
        .task(id: matchRevision) {
            guard active, initialized, !saving, !editingName else { return }
            let request = UUID()
            checkingRequest = request
            defer { if checkingRequest == request { checkingRequest = nil } }
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            await loadCandidates(useProvided: true, background: true)
        }
        .task(id: presentationRevision) {
            guard active, initialized, !saving, !loading else { return }
            await refreshPresentation()
        }
        .onChange(of: session.displayedID) { _, _ in
            guard playback.ownsReviewPlayback(playbackOwner), recording == nil else { return }
            playback.pause()
            alternateMessage = nil
            _ = audioSelection.select(nil, libraryDirectory: store.dataDirectory)
            error = nil
            if let current { play(current) }
        }
        .onChange(of: observation.snapshot.recordingBusy) { _, busy in
            if busy { cancelAlternative() }
        }
        .sheet(
            item: $recording,
            onDismiss: {
                guard active else { return }
                playbackOwner = playback.beginReviewPlayback()
            }
        ) { target in
            MeetingDetailSheet(
                meetingID: target.id, initialTranscriptRowID: target.transcriptRowID,
                initialContentTab: target.opensTranscript ? .transcript : nil
            ) { recording = nil }
        }
        .sheet(item: $namingContext, onDismiss: { editingName = false }) { context in
            VoiceSampleNameEditor(
                title: "Name This Person",
                explanation:
                    "Name this voice to improve recognition in future recordings.",
                createAndAssign: { name in await nameGroup(context, newPersonName: name) }
            ) { id in await nameGroup(context, personID: id) }
        }
        .onChange(of: references.map(\.id)) { _, ids in
            if let referenceID = session.referenceID, !ids.contains(referenceID) {
                session.returnToCandidate()
            }
        }
        .onDisappear {
            active = false
            presentationRequest = UUID()
            _ = audioSelection.select(nil, libraryDirectory: store.dataDirectory)
            cancelAlternative()
            playback.endReviewPlayback(playbackOwner)
        }
    }

    private var sampleList: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                Section {
                    ForEach(session.examples) { example in
                        sampleRow(
                            example,
                            status: session.unavailableIDs.contains(example.id)
                                ? "Unavailable"
                                : (session.noLongerNeededIDs.contains(example.id)
                                    ? "No Longer Needed"
                                    : session.decisions[example.id].map(decisionTitle) ?? "Needs Review"),
                            kind: session.unavailableIDs.contains(example.id)
                                ? .ignored
                                : (session.noLongerNeededIDs.contains(example.id)
                                    ? .ignored : session.decisions[example.id].map(decisionKind) ?? .needsReview),
                            selected: session.referenceID == nil && session.candidateID == example.id
                        ).tag(Selection.candidate(example.id)).id(Selection.candidate(example.id))
                    }
                } header: {
                    HStack {
                        Text("Candidates · \(session.remainingCount) Remaining")
                        Spacer()
                        if session.remainingCount == 0 && !session.additionalCandidates.isEmpty {
                            Button("Review More") {
                                Task { await loadCandidates(useProvided: true, admitNewCandidates: true) }
                            }.controlSize(.small)
                                .accessibilityLabel("Review More Samples")
                        }
                    }
                }
                if !session.examples.isEmpty {
                    ListCountFooter(
                        text: ListCountFooter.text(
                            count: session.examples.count, singular: "Sample", plural: "Samples")
                    )
                    .selectionDisabled()
                }
            }.listStyle(.inset).disabled(saving || editingName || loading)
                .onChange(of: session.displayedID, initial: true) { _, _ in
                    revealSelection(using: proxy)
                }
                .onChange(of: session.examples.map(\.id) + references.map(\.id)) { _, _ in
                    revealSelection(using: proxy)
                }
        }
    }

    private func revealSelection(using proxy: ScrollViewProxy) {
        guard let target = selection.wrappedValue else { return }
        Task { @MainActor in
            await Task.yield()
            guard selection.wrappedValue == target else { return }
            proxy.scrollTo(target)
        }
    }

    private func sampleRow(
        _ example: VoiceExample, status: String, kind: VoiceSampleStatusKind, selected: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(presentation.rows[example.id]?.title ?? "Saved Recording")
                .font(.headline).lineLimit(1)
            Text(presentation.rows[example.id]?.metadata ?? "")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                .help(presentation.rows[example.id]?.help ?? "")
            VoiceSampleStatusLabel(title: status, kind: kind, selected: selected)
        }.padding(.vertical, 6)
    }

    private func focusedSample(_ example: VoiceExample, isReference: Bool) -> some View {
        let decision = isReference ? nil : session.decisions[example.id]
        let confirmed =
            decision.map {
                if case .confirmed = $0 { return true }
                return false
            } ?? false
        let actions = VoiceMatchReviewSession.actions(
            for: example, decision: decision, isReference: isReference, personID: reviewPersonID)
        let unavailable = session.unavailableIDs.contains(example.id)
        return VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(presentation.rows[example.id]?.title ?? "Saved Recording").font(.title3.bold())
                                .lineLimit(3)
                            Text(presentation.rows[example.id]?.metadata ?? "")
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                .help(presentation.rows[example.id]?.help ?? "")
                        }
                        Spacer()
                        Button("Open Recording") { open(example) }
                            .disabled(saving || editingName || openingRecording)
                    }
                    Divider()
                    Text(
                        isReference
                            ? "Confirmed Sample"
                            : (session.noLongerNeededIDs.contains(example.id)
                                ? "No Review Needed" : decision.map(decisionTitle))
                                ?? (reviewPersonID == nil
                                    ? "Who is speaking?" : "Does this voice belong to \(personName)?")
                    )
                    .font(.headline)
                    HStack(spacing: 12) {
                        ReviewSamplePlaybackButton(
                            playback: playback, example: example, available: audioAvailable(example),
                            disabled: editingName || saving, shortcutEnabled: !nameFocused && !editingName,
                            play: { play(example) })
                        VStack(alignment: .leading, spacing: 4) {
                            if isReference {
                                sampleNameLabel(example)
                                VoiceSampleStatusLabel(title: "Confirmed", kind: .confirmed)
                            }
                            else if let decision {
                                if confirmed || decision == .skipped || decision == .ignored || decision == .rejected {
                                    if reviewPersonID == nil {
                                        unnamedNameLabel(example)
                                    }
                                    else {
                                        sampleNameLabel(example)
                                    }
                                }
                                VoiceSampleStatusLabel(title: decisionTitle(decision), kind: decisionKind(decision))
                            }
                            else if reviewPersonID == nil {
                                unnamedNameLabel(example)
                                VoiceSampleStatusLabel(title: "Needs Review", kind: .needsReview)
                            }
                            else {
                                Text("Sample Name").font(.caption).foregroundStyle(.secondary)
                                sampleNameLabel(example)
                            }
                        }
                    }
                    if !isReference, let reference = references.first(where: { audioAvailable($0) }) {
                        Button("Compare with Reference") { session.selectReference(reference.id) }
                            .disabled(saving || editingName)
                    }
                    if isReference {
                        Text("You confirmed this sample. You can correct its name or remove it from this person.")
                            .font(.callout).foregroundStyle(.secondary)
                        if session.candidateID != nil {
                            Button("Return to Candidate") { session.returnToCandidate() }
                        }
                    }
                    else if session.noLongerNeededIDs.contains(example.id) {
                        Text("This sample no longer needs review. You can still correct its identity.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    else if decision == nil {
                        Text(
                            reviewPersonID == nil
                                ? "Name this voice to improve recognition in future recordings."
                                : "Confirm the voice matches this person."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    if let issue = example.currentSampleQuality?.issue {
                        Label(issue.label, systemImage: "waveform.badge.exclamationmark")
                            .font(.callout).foregroundStyle(.secondary)
                            .help(VoiceSampleQuality.assessmentDetail)
                    }
                    VoiceSampleTranscriptView(example: example)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(example.id)
            if unavailable {
                Text("This sample is no longer in the voice library. Refresh matches to continue.").foregroundStyle(
                    .secondary)
            }
            else if !audioAvailable(example) {
                Text("This excerpt is unavailable. Open the recording to inspect its source.").foregroundStyle(
                    .secondary)
            }
            else if observation.snapshot.playbackBlocked {
                Text("Finish the recording before playing samples.").foregroundStyle(.secondary)
            }
            if let alternateMessage {
                Text(alternateMessage).font(.callout).foregroundStyle(.secondary)
            }
            if !isReference {
                HStack {
                    Button {
                        tryAnotherSample(example)
                    } label: {
                        actionLabel("Try Another Sample", action: .alternate)
                    }.disabled(
                        saving || editingName || unavailable || decision != nil || !observation.snapshot.libraryWritable
                            || observation.snapshot.recordingBusy || observation.snapshot.playbackBlocked)
                    if saving && savingAction == .alternate {
                        Button("Cancel", action: cancelAlternative)
                            .accessibilityLabel("Cancel Sample Preparation")
                    }
                }
            }
            Divider()
            VoiceReviewActionsLayout {
                HStack(spacing: 12) { secondaryDecisions(example, actions: actions) }
                HStack(spacing: 12) { identityDecisions(example, actions: actions) }
            }.disabled(saving || editingName || !observation.snapshot.libraryWritable || unavailable)
        }.padding(24)
    }

    private func unnamedNameLabel(_ example: VoiceExample) -> some View {
        Text("Unidentified Voice").font(.headline)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginGroupNaming(example) }
            .contextMenu { Button("Name This Person…") { beginGroupNaming(example) } }
            .accessibilityAction(named: "Name This Person") { beginGroupNaming(example) }
            .help("Double-click to name this person.")
    }

    private func sampleNameLabel(_ example: VoiceExample) -> some View {
        VoiceSampleNameLabel(
            example: example, suggestedName: personName, editing: $editingName,
            focusChanged: { nameFocused = $0 },
            createAndAssign: { name in await createAndAssign(example, name: name) }
        ) { id in await assign(example, to: id) }
        .disabled(session.unavailableIDs.contains(example.id))
    }

    private func actionLabel(_ title: String, action: SavingAction) -> some View {
        Text(title)
            .opacity(saving && savingAction == action ? 0 : 1)
            .overlay {
                if saving && savingAction == action { ProgressView().controlSize(.small) }
            }
            .accessibilityLabel(title)
            .accessibilityValue(saving && savingAction == action ? "Saving" : "")
    }

    @ViewBuilder private func secondaryDecisions(_ example: VoiceExample, actions: VoiceMatchReviewSession.Actions)
        -> some View
    {
        Button("Skip", action: skip).keyboardShortcut("s", modifiers: .command).disabled(!actions.canSkip)
        Button {
            decide(.exclude(ids: [example.id], excluded: true), example: example, decision: .ignored, action: .ignore)
        } label: {
            actionLabel("Ignore Sample", action: .ignore)
        }
        .help("Remove this sample from review and voice recognition. The recording is kept.")
        .disabled(!actions.canIgnore)
    }
    @ViewBuilder private func identityDecisions(_ example: VoiceExample, actions: VoiceMatchReviewSession.Actions)
        -> some View
    {
        if let personID = reviewPersonID {
            Button {
                decide(
                    .reject(
                        ids: [example.id], personID: personID,
                        restoreExcluded: session.decisions[example.id] == .ignored
                    ), example: example, decision: .rejected,
                    action: .reject)
            } label: {
                actionLabel("Not \(personName)", action: .reject)
            }
            .lineLimit(1).disabled(!actions.canReject)
            Button {
                decide(
                    .confirm(ids: [example.id], personID: personID), example: example,
                    decision: .confirmed(personID), action: .confirm)
            } label: {
                actionLabel("Confirm", action: .confirm)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).buttonRepeatBehavior(.disabled)
            .disabled(!actions.canConfirm || saving || editingName)
        }
        else {
            Button {
                beginGroupNaming(example)
            } label: {
                actionLabel("Name This Person…", action: .name)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).buttonRepeatBehavior(.disabled)
            .disabled(saving || editingName)
        }
    }

    private func decisionKind(_ decision: VoiceMatchReviewSession.Decision) -> VoiceSampleStatusKind {
        switch decision {
        case .confirmed: return .confirmed
        case .rejected: return .rejected
        case .ignored: return .ignored
        case .skipped: return .skipped
        }
    }

    private func decisionTitle(_ decision: VoiceMatchReviewSession.Decision) -> String {
        switch decision {
        case .confirmed(let id): return "Confirmed: \(store.people.first { $0.id == id }?.name ?? "Person")"
        case .rejected: return "Not \(personName)"
        case .ignored: return "Ignored"
        case .skipped: return "Skipped"
        }
    }

    private struct MatchRevision: Equatable {
        let evidence: Int
        let policy: VoiceMatchingPolicy
        let person: UUID?
        let saving: Bool
        let editing: Bool
    }
    private var matchRevision: MatchRevision {
        MatchRevision(
            evidence: observation.snapshot.reviewEvidenceRevision, policy: observation.snapshot.policy,
            person: reviewPersonID,
            saving: saving, editing: editingName)
    }

    private func loadCandidates(
        useProvided: Bool, retryOnDrift: Bool = true, background: Bool = false, admitNewCandidates: Bool = false
    ) async {
        let interval = ReviewPerformance.signposter.beginInterval(
            "Load review candidates", id: ReviewPerformance.signposter.makeSignpostID())
        defer { ReviewPerformance.signposter.endInterval("Load review candidates", interval) }
        let request = UUID()
        loadRequest = request
        if !background { loading = true }
        loadFailed = false
        error = nil
        do {
            let policy = observation.snapshot.policy
            let snapshot = try await library.reviewSnapshot(
                for: Set(store.people.map(\.id)), forceRefresh: !useProvided, policy: policy,
                includeUnnamedGroups: reviewPersonID == nil)
            let currentEvidence = library.examples
            let input = session.refreshInput(
                from: snapshot, initialGroup: initialGroup, fallbackPersonID: personID,
                retainedGroupEvidence: groupEvidence, currentEvidence: currentEvidence)
            let candidates = input.examples
            guard active, !Task.isCancelled, loadRequest == request else { return }
            let directoryRevision = store.directoryRevision
            let root = store.dataDirectory
            var proposedSession = initialized ? session : VoiceMatchReviewSession(personID: personID)
            proposedSession.refreshQueue(
                candidates, currentEvidence: currentEvidence, admitNewCandidates: admitNewCandidates,
                coveredExampleIDs: reviewPersonID.flatMap { snapshot.coveredExampleIDs[$0] } ?? [])
            let evidence = reviewPersonID.map { library.referenceEvidence(for: $0) } ?? []
            let potential = proposedSession.examples + proposedSession.additionalCandidates
            let evidenceIDs = Set((potential + input.groupEvidence + evidence).map(\.id))
            let dependencies = VoiceReviewPresentationEvidence(examples: library.reviewEvidence(for: evidenceIDs))
            let labels = await loadTitles(for: potential + evidence)
            var prepared = await presentationCache.prepare(
                .init(
                    candidates: potential, referenceEvidence: evidence, personID: reviewPersonID,
                    meetings: labels, libraryDirectory: store.dataDirectory), forceRefresh: !useProvided)
            let eligible = candidates.filter { prepared.playableCandidateIDs.contains($0.id) }
            var nextSession = initialized ? session : VoiceMatchReviewSession(personID: personID)
            nextSession.refreshQueue(
                eligible, currentEvidence: currentEvidence, admitNewCandidates: admitNewCandidates,
                coveredExampleIDs: reviewPersonID.flatMap { snapshot.coveredExampleIDs[$0] } ?? [])
            // Retained decisions stay in the candidate section. If a source
            // disappeared, deduplicate references against the final queue only.
            if nextSession.examples != proposedSession.examples {
                prepared = await presentationCache.prepare(
                    .init(
                        candidates: nextSession.examples, referenceEvidence: evidence, personID: reviewPersonID,
                        meetings: labels, libraryDirectory: store.dataDirectory))
            }
            guard active, !Task.isCancelled, loadRequest == request else { return }
            guard store.dataDirectory == root,
                snapshot.revision == library.reviewEvidenceRevision,
                policy
                    == (store.settings.serviceProviders.first(where: { $0.id == store.settings.diarizationProviderID })?
                        .voiceMatchingPolicy ?? .default),
                dependencies.matches(library.reviewEvidence(for: evidenceIDs))
            else {
                if retryOnDrift {
                    await loadCandidates(
                        useProvided: true, retryOnDrift: false, background: background,
                        admitNewCandidates: admitNewCandidates)
                }
                else {
                    loading = false
                    loadFailed = true
                    error = "The library changed while loading samples. Try again."
                }
                return
            }
            session = nextSession
            reconcileAudioAvailability(prepared)
            presentation = prepared
            presentationDirectoryRevision = directoryRevision
            groupEvidence = input.groupEvidence
            initialized = true
        }
        catch {
            guard active, !Task.isCancelled, loadRequest == request else { return }
            loadFailed = true
            self.error = error.localizedDescription
        }
        loading = false
    }
    private func audioAvailable(_ example: VoiceExample) -> Bool {
        if audioSelection.request?.example.id == example.id { return audioSelection.available }
        return presentation.rows[example.id]?.audioAvailable == true
    }

    private func play(_ example: VoiceExample) {
        guard active, !editingName, recording == nil, playback.ownsReviewPlayback(playbackOwner) else { return }
        playback.pause()
        guard let request = audioSelection.select(example, libraryDirectory: store.dataDirectory) else { return }
        playback.requestPlayback(
            reviewOwner: playbackOwner,
            load: {
                let available = await request.verify()
                guard active, session.displayedID == example.id,
                    audioSelection.complete(request, available: available), available,
                    !editingName, !saving
                else { return nil }
                guard await store.ensureMeetingLoaded(id: example.meetingID), active,
                    session.displayedID == example.id, audioSelection.request?.id == request.id,
                    !editingName, !saving
                else { return nil }
                return store.meeting(id: example.meetingID)
            },
            play: { meeting in
                guard active, audioSelection.request?.id == request.id,
                    session.displayedID == example.id, !editingName, !saving, let range = example.range
                else { return }
                playback.playExcerpts(
                    meeting: meeting, directory: store.directory(for: meeting.id), audioFile: range.audioFile,
                    spans: range.supportSpans)
            })
    }

    private func reconcileAudioAvailability(_ prepared: VoiceReviewPresentation) {
        guard let request = audioSelection.request else { return }
        let latest = (session.examples + prepared.references).first { $0.id == request.example.id }
        if latest?.hasSameReviewEvidence(as: request.example) != true
            || (audioSelection.isVerified
                && prepared.rows[request.example.id]?.audioAvailable != audioSelection.available)
        {
            _ = audioSelection.select(nil, libraryDirectory: store.dataDirectory)
        }
    }

    private func refreshPresentation() async {
        let interval = ReviewPerformance.signposter.beginInterval(
            "Prepare review presentation", id: ReviewPerformance.signposter.makeSignpostID())
        defer { ReviewPerformance.signposter.endInterval("Prepare review presentation", interval) }
        let request = UUID()
        presentationRequest = request
        let revision = library.reviewMetadataRevision
        let directoryRevision = store.directoryRevision
        let indexRevision = store.meetingIndexRevision
        let candidates = session.examples
        let person = reviewPersonID
        let evidence = person.map { library.referenceEvidence(for: $0) } ?? []
        let labels = await loadTitles(for: candidates + evidence)
        let prepared = await presentationCache.prepare(
            .init(
                candidates: candidates, referenceEvidence: evidence, personID: person,
                meetings: labels, libraryDirectory: store.dataDirectory),
            forceRefresh: presentationDirectoryRevision != directoryRevision)
        guard active, !Task.isCancelled, !saving, presentationRequest == request,
            library.reviewMetadataRevision == revision, store.directoryRevision == directoryRevision,
            store.meetingIndexRevision == indexRevision, reviewPersonID == person, session.examples == candidates
        else { return }
        reconcileAudioAvailability(prepared)
        presentation = prepared
        presentationDirectoryRevision = directoryRevision
    }
    private func skip() {
        guard let current, session.referenceID == nil, !saving else { return }
        playback.pause()
        session.record(.skipped, for: current.id, undoID: nil)
    }
    private func decide(
        _ action: VoiceReviewAction, example: VoiceExample, decision: VoiceMatchReviewSession.Decision,
        action savingAction: SavingAction
    ) {
        guard !saving, !editingName else { return }
        let isReference = session.referenceID == example.id
        self.savingAction = savingAction
        saving = true
        playback.pause()
        error = nil
        Task {
            if let receipt = await store.reviewVoiceExamplesResult(action, expectedExamples: [example]) {
                refreshOwnEvidence()
                if isReference {
                    session.recordReference(for: example.id, undoID: receipt.undoID)
                }
                else {
                    recordCandidateDecision(decision, example: example, undoID: receipt.undoID)
                }
            }
            else {
                error = store.errorMessage ?? library.errorMessage ?? "Couldn’t save this review. Try again."
            }
            saving = false
        }
    }
    private func recordCandidateDecision(
        _ decision: VoiceMatchReviewSession.Decision, example: VoiceExample, undoID: UUID?
    ) {
        if session.decisions[example.id] == nil {
            session.record(decision, for: example.id, undoID: undoID)
        }
        else {
            session.correct(decision, for: example.id, undoID: undoID)
        }
    }

    private func assign(_ example: VoiceExample, to person: UUID) async -> Bool {
        guard !saving else { return false }
        let isReference = session.referenceID == example.id
        savingAction = .name
        saving = true
        defer { saving = false }
        guard
            let receipt = await store.reviewVoiceExamplesResult(
                .confirm(ids: [example.id], personID: person), expectedExamples: [example])
        else { return false }
        editingName = false
        refreshOwnEvidence()
        if isReference {
            session.recordReference(for: example.id, undoID: receipt.undoID)
        }
        else {
            recordCandidateDecision(.confirmed(person), example: example, undoID: receipt.undoID)
        }
        return true
    }
    private func createAndAssign(_ example: VoiceExample, name: String) async -> Bool {
        guard !saving else { return false }
        let isReference = session.referenceID == example.id
        savingAction = .name
        saving = true
        defer { saving = false }
        guard
            let receipt = await store.nameVoiceGroupResult(
                exampleIDs: [example.id], confirmedExampleID: example.id, personID: nil,
                newPersonName: name, expectedExamples: [example]),
            let person = receipt.personID
        else { return false }
        editingName = false
        refreshOwnEvidence()
        if isReference {
            session.recordReference(for: example.id, undoID: receipt.undoID)
        }
        else {
            recordCandidateDecision(.confirmed(person), example: example, undoID: receipt.undoID)
        }
        return true
    }
    private func beginGroupNaming(_ example: VoiceExample) {
        guard !saving, !editingName, reviewPersonID == nil, store.libraryWritable,
            !session.unavailableIDs.contains(example.id)
        else { return }
        playback.pause()
        if session.decisions[example.id] == .ignored || session.decisions[example.id] == .rejected {
            namingContext = GroupNamingContext(anchor: example, examples: [example])
            editingName = true
            return
        }
        let ignored = session.examples.filter { session.decisions[$0.id] == .ignored }
        let evidence = session.namingEvidence(groupEvidence).filter { candidate in
            !candidate.excluded && !candidate.manuallyCleared
                && !ignored.contains { VoiceReviewSelection.sameAudio($0, candidate) }
        }
        guard evidence.contains(where: { $0.id == example.id }) else { return }
        namingContext = GroupNamingContext(anchor: example, examples: evidence)
        editingName = true
    }

    private func nameGroup(
        _ context: GroupNamingContext, personID: UUID? = nil, newPersonName: String? = nil
    ) async -> Bool {
        guard !saving else { return false }
        savingAction = .name
        saving = true
        defer { saving = false }
        guard
            let receipt = await store.nameVoiceGroupResult(
                exampleIDs: Set(context.examples.map(\.id)), confirmedExampleID: context.anchor.id,
                personID: personID, newPersonName: newPersonName, expectedExamples: context.examples),
            let namedPerson = receipt.personID
        else { return false }
        editingName = false
        session.recordNaming(
            personID: namedPerson, confirmedExampleID: context.anchor.id,
            updatedExamples: library.examples, undoID: receipt.undoID)
        refreshOwnEvidence()
        return true
    }

    private func refreshOwnEvidence() {
        // Publish the pending derived refresh with the decision, before the last
        // candidate can momentarily render a premature completion screen.
        checkingRequest = UUID()
        session.refreshExamples(library.examples, authoritative: true)
        let latest = Dictionary(uniqueKeysWithValues: library.examples.map { ($0.id, $0) })
        groupEvidence = groupEvidence.map { latest[$0.id] ?? $0 }
    }

    private func undo() {
        guard let last = session.history.last, canUndo, !saving else { return }
        savingAction = .undo
        saving = true
        playback.pause()
        error = nil
        Task {
            let succeeded: Bool
            if let token = last.undoID {
                succeeded = await store.reviewVoiceExamples(.undo, expectedUndoID: token)
            }
            else {
                succeeded = true
            }
            if succeeded {
                session.restoreLast(updatedExamples: library.examples)
                if last.namingSnapshot != nil {
                    groupEvidence = session.restoredNamingEvidence(
                        initialEvidence: initialGroup?.evidenceExamples ?? [], currentEvidence: library.examples)
                }
                refreshOwnEvidence()
            }
            else {
                error = store.errorMessage ?? "Couldn’t undo this review. Try again."
            }
            saving = false
        }
    }
    private func tryAnotherSample(_ example: VoiceExample) {
        guard !saving, !editingName, active, store.recordingID == nil,
            !store.isStartingRecording, !store.isFinalizingRecording, !playback.isPlaybackBlocked
        else { return }
        playback.pause()
        _ = audioSelection.select(nil, libraryDirectory: store.dataDirectory)
        saving = true
        savingAction = .alternate
        alternateMessage = nil
        alternateTask?.cancel()
        let request = UUID()
        alternateRequest = request
        alternateTask = Task {
            defer {
                // Only the current request can clear its saving state. A cancelled
                // preparation may finish after the user starts another request.
                if alternateRequest == request {
                    alternateRequest = nil
                    alternateTask = nil
                    saving = false
                    savingAction = nil
                }
            }
            do {
                let result = try await store.voicePreparation.tryAnotherSample(
                    exampleID: example.id, directory: store.directory(for: example.meetingID))
                guard active, !Task.isCancelled, alternateRequest == request else { return }
                switch result {
                case .prepared(let replacement):
                    session.showAlternative(replacement, currentEvidence: library.examples)
                    groupEvidence = session.namingEvidence(groupEvidence + [replacement])
                    await refreshPresentation()
                    // Selection changed while preparation disabled autoplay.
                    if active, !Task.isCancelled, alternateRequest == request,
                        session.displayedID == replacement.id
                    {
                        saving = false
                        play(replacement)
                    }
                case .exhausted:
                    alternateMessage = "No other speech excerpts are available for this voice."
                case .analysisUnavailable:
                    alternateMessage = "Scan recordings again to find other excerpts."
                case .speakerUnresolved:
                    alternateMessage = "Couldn’t find another excerpt for this voice."
                }
            }
            catch is CancellationError {}
            catch {
                if active, !Task.isCancelled, alternateRequest == request { self.error = error.localizedDescription }
            }
        }
    }

    private func cancelAlternative() {
        guard alternateRequest != nil else { return }
        alternateRequest = nil
        alternateTask?.cancel()
        alternateTask = nil
        if playback.ownsReviewPlayback(playbackOwner) { playback.pause() }
        _ = audioSelection.select(nil, libraryDirectory: store.dataDirectory)
        if savingAction == .alternate {
            saving = false
            savingAction = nil
        }
    }

    private func open(_ example: VoiceExample) {
        guard !openingRecording, active, playback.ownsReviewPlayback(playbackOwner) else { return }
        openingRecording = true
        playback.pause()
        Task {
            defer { openingRecording = false }
            let loaded = await store.ensureMeetingLoaded(id: example.meetingID)
            guard active, session.displayedID == example.id, playback.ownsReviewPlayback(playbackOwner) else { return }
            guard loaded, let meeting = store.meeting(id: example.meetingID) else {
                error = "Couldn’t open this recording."
                return
            }
            _ = audioSelection.select(nil, libraryDirectory: store.dataDirectory)
            // Retain ownership across the child sheet so closing the whole
            // journey also pauses its source. The cleared selection invalidates
            // any pending excerpt request before the full source is selected.
            playback.selectRecording(
                meeting: meeting, files: store.audioURLs(for: meeting), audioFile: example.range?.audioFile,
                at: example.range?.start ?? 0)
            recording = VoiceExampleRecordingTarget(example: example, meeting: meeting)
        }
    }
    private func loadTitles(for examples: [VoiceExample]) async -> [UUID: MeetingListEntry] {
        let index = store.libraryIndex
        let loaded = store.meetings
        let ids = Set(examples.map(\.meetingID))
        return await Task.detached {
            var result = Dictionary(
                uniqueKeysWithValues: loaded.filter { ids.contains($0.id) }.map {
                    ($0.id, MeetingListEntry($0))
                })
            if let index {
                for id in ids { if let entry = try? index.entry(id: id) { result[id] = entry } }
            }
            return result
        }.value
    }

}
private struct ReviewSamplePlaybackButton: View {
    @ObservedObject var playback: MeetingPlayback
    let example: VoiceExample
    let available: Bool
    let disabled: Bool
    let shortcutEnabled: Bool
    let play: () -> Void
    private var playing: Bool {
        guard let range = example.range else { return false }
        return playback.isPlaying && playback.meetingID == example.meetingID
            && playback.excerptRanges == range.supportSpans.map { $0.start..<$0.end }
            && playback.audioURL(forTrack: playback.selectedTrack)?.lastPathComponent == range.audioFile
    }
    var body: some View {
        VoiceSamplePlaybackControl(playing: playing, available: available && !playback.isPlaybackBlocked) {
            if playing {
                playback.pause()
            }
            else {
                play()
            }
        }
        .keyboardShortcut(shortcutEnabled ? KeyboardShortcut(.space, modifiers: []) : nil)
        .disabled(disabled)
    }
}

enum VoiceSampleStatusKind {
    case confirmed, needsReview, rejected, ignored, skipped
    var symbol: String {
        switch self {
        case .confirmed: "checkmark.circle.fill"
        case .needsReview: "questionmark.circle.fill"
        case .rejected: "xmark.circle.fill"
        case .ignored: "minus.circle.fill"
        case .skipped: "forward.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .confirmed: .green
        case .needsReview: .orange
        case .rejected: .red
        case .ignored, .skipped: .secondary
        }
    }
}

struct VoiceSampleStatusLabel: View {
    let title: String
    let kind: VoiceSampleStatusKind
    var selected = false
    var body: some View {
        Label {
            Text(title).foregroundStyle(selected ? .primary : .secondary)
        } icon: {
            Image(systemName: kind.symbol).foregroundStyle(selected ? Color.primary : kind.color)
        }.font(.caption)
    }
}

/// Shared label editing keeps sample assignment available without leaving the listening context.
struct VoiceSampleNameLabel: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let example: VoiceExample
    var suggestedName: String? = nil
    @Binding var editing: Bool
    var beginEditing: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var createAndAssign: ((String) async -> Bool)? = nil
    let assign: (UUID) async -> Bool
    @ViewState private var showingEditor = false
    @FocusState private var nameFocused: Bool
    private struct EditActions {
        let createAndAssign: ((String) async -> Bool)?
        let assign: (UUID) async -> Bool
    }
    @ViewState private var editActions: EditActions?
    private var name: String {
        store.people.first { $0.id == example.personID }?.name
            ?? store.people.first { $0.id == example.namedPersonID }?.name
            ?? store.people.first { $0.id == example.suggestedPersonID }?.name
            ?? suggestedName ?? "Unknown Person"
    }
    private var tint: NSColor {
        let personID = example.personID ?? example.namedPersonID ?? example.suggestedPersonID
        return personID.map { TranscriptSpeakerPalette.color(for: $0.uuidString) }
            ?? TranscriptSpeakerPalette.color(for: "unidentified-voice")
    }
    var body: some View {
        Text(name).font(.headline)
            .modifier(VoiceReviewLabelStyle(tint: tint))
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: edit)
            .contextMenu { Button("Edit Sample Name…", action: edit) }
            .accessibilityLabel("Sample name: \(name)")
            .accessibilityAction(named: "Edit Sample Name", edit)
            .popover(isPresented: $showingEditor) {
                if let editActions {
                    VoiceSampleNameEditor(createAndAssign: editActions.createAndAssign, assign: editActions.assign)
                }
            }
            .onChange(of: showingEditor) { _, showing in
                editing = showing
                if !showing { editActions = nil }
            }
            .help("Double-click or press Space to edit the sample name.")
            .focusable()
            .focused($nameFocused)
            .onChange(of: nameFocused) { _, focused in focusChanged(focused) }
            .onDisappear { focusChanged(false) }
            .onKeyPress(.space) {
                edit()
                return .handled
            }
    }
    private func edit() {
        guard store.libraryWritable, !showingEditor else { return }
        playback.pause()
        beginEditing()
        // Keep the evidence captured at opening even if the parent refreshes
        // while the user is typing.
        editActions = EditActions(createAndAssign: createAndAssign, assign: assign)
        editing = true
        showingEditor = true
    }
}

private struct VoiceSampleNameEditor: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    var title = "Edit Sample Name"
    var explanation: String? = nil
    let createAndAssign: ((String) async -> Bool)?
    let assign: (UUID) async -> Bool
    @ViewState private var query = ""
    @ViewState private var saving = false
    @ViewState private var error: String?
    @FocusState private var focused: Bool
    @ViewState private var selectedPerson: UUID?
    private var canCreate: Bool { !name.isEmpty && exact == nil }
    private var name: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [Person] { TranscriptSpeakerSearch.matches(store.people, query: query) }
    private var exact: Person? { store.people.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let explanation { Text(explanation).font(.callout).foregroundStyle(.secondary) }
            TextField("Search People or Enter a Name", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(submit)
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onChange(of: query) { _, _ in
                    selectedPerson = matches.first?.id
                }
            List(selection: $selectedPerson) {
                ForEach(matches) { person in
                    Text(person.name).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(person.id)
                        .simultaneousGesture(TapGesture().onEnded { selectedPerson = person.id })
                        .simultaneousGesture(TapGesture(count: 2).onEnded { save(person.id) })
                }
            }.frame(height: 190)
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) {
                    submit()
                    return .handled
                }
            if let error { AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                if selectedPerson != nil {
                    if canCreate {
                        Button("Create “\(name)”", action: create).lineLimit(1)
                            .buttonRepeatBehavior(.disabled)
                    }
                    Button("Use Name", action: submit).keyboardShortcut(.defaultAction)
                        .buttonRepeatBehavior(.disabled)
                }
                else if canCreate {
                    Button("Create “\(name)”", action: submit).lineLimit(1).keyboardShortcut(.defaultAction)
                        .buttonRepeatBehavior(.disabled)
                }
                else {
                    Button("Use Name", action: submit).disabled(selectedPerson == nil).keyboardShortcut(.defaultAction)
                        .buttonRepeatBehavior(.disabled)
                }
            }
        }.padding(16).frame(width: 340).disabled(saving).interactiveDismissDisabled(saving)
            .task {
                selectedPerson = matches.first?.id
                focused = true
            }
    }
    private func submit() {
        guard !saving else { return }
        if let selectedPerson {
            save(selectedPerson)
        }
        else if canCreate {
            create()
        }
    }
    private func moveSelection(_ offset: Int) {
        guard !matches.isEmpty else {
            selectedPerson = nil
            return
        }
        let current = matches.firstIndex { $0.id == selectedPerson } ?? (offset > 0 ? -1 : matches.count)
        selectedPerson = matches[min(max(current + offset, 0), matches.count - 1)].id
    }
    private func save(_ id: UUID) {
        guard !saving else { return }
        saving = true
        Task { await complete(id) }
    }
    private func create() {
        guard !saving, !name.isEmpty else { return }
        saving = true
        let requestedName = name
        Task {
            if let createAndAssign {
                if await createAndAssign(requestedName) {
                    dismiss()
                }
                else {
                    error =
                        store.errorMessage ?? store.voiceLibrary.errorMessage
                        ?? "Couldn’t save the name and sample. Try again."
                }
                saving = false
                return
            }
            let id = await store.addPerson(name: requestedName)
            guard store.people.contains(where: { $0.id == id }) else {
                error = store.errorMessage ?? "Couldn’t create this person. Try again."
                saving = false
                return
            }
            await complete(id)
        }
    }
    private func complete(_ id: UUID) async {
        if await assign(id) {
            dismiss()
        }
        else {
            error = store.errorMessage ?? store.voiceLibrary.errorMessage ?? "Couldn’t save the sample name. Try again."
        }
        saving = false
    }
}

/// Quiet context labels share speaker colors without adopting button chrome.
struct VoiceReviewLabelStyle: ViewModifier {
    let tint: NSColor
    var role: IdentityLabelRole = .person
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color(nsColor: TranscriptSpeakerPalette.foreground(for: tint, role: role)))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(
                Color(nsColor: TranscriptSpeakerPalette.fill(for: tint, role: role)),
                in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A single set of controls owns the shortcuts even when actions wrap.
private struct VoiceReviewActionsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = proposal.width ?? sizes.reduce(12) { $0 + $1.width }
        let fits = sizes.reduce(12) { $0 + $1.width } <= width
        return CGSize(
            width: width, height: fits ? (sizes.map(\.height).max() ?? 0) : sizes.reduce(12) { $0 + $1.height })
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let fits = sizes[0].width + sizes[1].width + 12 <= bounds.width
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: ProposedViewSize(sizes[0]))
        subviews[1].place(
            at: CGPoint(
                x: bounds.maxX - sizes[1].width,
                y: fits ? bounds.minY : bounds.minY + sizes[0].height + 12), proposal: ProposedViewSize(sizes[1]))
    }
}
