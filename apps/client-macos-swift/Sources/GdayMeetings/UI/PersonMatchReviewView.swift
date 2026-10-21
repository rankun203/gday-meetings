import SwiftUI

/// A listening session retains its candidate order and focus while references are compared.
struct PersonMatchReviewView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: VoiceLibraryStore
    var personID: UUID? = nil
    var initialGroup: VoiceIdentificationGroup? = nil
    let openRecording: (VoiceExampleRecordingTarget) -> Void
    @ViewState private var session = VoiceMatchReviewSession()
    private var references: [VoiceExample] {
        guard let personID = session.personID ?? personID else { return [] }
        let candidateAudio = Set(session.examples.compactMap(VoiceExactReviewDecisions.Key.init))
        return VoiceMatchReviewSession.referenceExamples(library.referenceEvidence(for: personID), personID: personID)
            .filter { example in
                VoiceExactReviewDecisions.Key(example).map { !candidateAudio.contains($0) } ?? true
            }
    }
    @ViewState private var loading = true
    @ViewState private var loadFailed = false
    @ViewState private var saving = false
    private enum SavingAction { case confirm, reject, ignore, name, undo }
    @ViewState private var savingAction: SavingAction?
    @ViewState private var initialized = false
    @ViewState private var editingName = false
    @ViewState private var error: String?
    @ViewState private var active = false
    @ViewState private var meetings: [UUID: MeetingListEntry] = [:]
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
        store.people.first { $0.id == reviewPersonID }?.name ?? "Unnamed Person"
    }
    private var current: VoiceExample? {
        if let id = session.referenceID { return references.first { $0.id == id } }
        return session.examples.first { $0.id == session.candidateID }
    }
    private var canUndo: Bool {
        guard let last = session.history.last else { return false }
        return last.undoID == nil || (library.canUndo && last.undoID == library.reviewUndoID)
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
                .disabled(!canUndo || saving || editingName || !store.libraryWritable)
                Button("Done") {
                    playback.pause()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction).disabled(saving)
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
                            Label("No Matches to Review", systemImage: "waveform")
                        } description: {
                            Text(
                                references.isEmpty
                                    ? "No playable candidates are available for this person."
                                    : "No playable candidates are available. Existing samples remain available in the list."
                            )
                        } actions: {
                            Button("Refresh Matches") { Task { await loadCandidates(useProvided: false) } }
                        }
                    }
                    else {
                        ContentUnavailableView {
                            Label("Review Complete", systemImage: "checkmark.circle")
                        } description: {
                            Text("Your decisions remain visible in the list. Skipped samples stay undecided.")
                        } actions: {
                            Button("Refresh Matches") { Task { await loadCandidates(useProvided: false) } }
                        }
                    }
                }.frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.readingBackground)
            }
            if let message = error ?? playback.errorMessage {
                AppInlineMessage(text: message, systemImage: "exclamationmark.triangle", tint: .red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        }
        .frame(minWidth: 840, idealWidth: 960, minHeight: 560, idealHeight: 650)
        .interactiveDismissDisabled(saving)
        .task {
            active = true
            playback.pause()
            await loadCandidates(useProvided: true)
        }
        .task(id: Set(references.map(\.meetingID))) {
            await loadTitles(for: session.examples + references, request: loadRequest)
        }
        .onChange(of: session.displayedID) { _, _ in
            playback.pause()
            error = nil
            if let current { play(current) }
        }
        .sheet(item: $namingContext, onDismiss: { editingName = false }) { context in
            VoiceSampleNameEditor(
                title: "Name This Person",
                explanation:
                    "Confirm the current sample and associate the other samples with this person. Review each sample individually.",
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
            playback.pause()
        }
    }

    private var sampleList: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                Section("Candidates · \(session.remainingCount) Remaining") {
                    ForEach(session.examples) { example in
                        sampleRow(
                            example,
                            status: session.unavailableIDs.contains(example.id)
                                ? "Unavailable" : session.decisions[example.id].map(decisionTitle) ?? "Needs Review",
                            kind: session.unavailableIDs.contains(example.id)
                                ? .ignored : session.decisions[example.id].map(decisionKind) ?? .needsReview,
                            selected: session.referenceID == nil && session.candidateID == example.id
                        ).tag(Selection.candidate(example.id)).id(Selection.candidate(example.id))
                    }
                }
                if reviewPersonID != nil {
                    Section("Existing Samples") {
                        ForEach(references) { example in
                            sampleRow(
                                example, status: referenceStatus(example),
                                kind: example.review == .confirmed ? .confirmed : .needsReview,
                                selected: session.referenceID == example.id
                            ).tag(Selection.reference(example.id)).id(Selection.reference(example.id))
                        }
                        if references.isEmpty && !loading && reviewPersonID != nil {
                            Text("No confirmed or associated samples are available.")
                                .font(.caption).foregroundStyle(.secondary).selectionDisabled()
                        }
                    }
                }
                if !session.examples.isEmpty || !references.isEmpty {
                    ListCountFooter(
                        text: ListCountFooter.text(
                            count: session.examples.count + references.count, singular: "Sample", plural: "Samples")
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
            Text(meetings[example.meetingID]?.title ?? "Saved Recording")
                .font(.headline).lineLimit(1)
            Text(Self.metadataLabel(example, date: meetings[example.meetingID]?.createdAt))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                .help(Self.metadataHelp(example, date: meetings[example.meetingID]?.createdAt))
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
                            Text(meetings[example.meetingID]?.title ?? "Saved Recording").font(.title3.bold())
                                .lineLimit(3)
                            Text(Self.metadataLabel(example, date: meetings[example.meetingID]?.createdAt))
                                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                                .help(Self.metadataHelp(example, date: meetings[example.meetingID]?.createdAt))
                        }
                        Spacer()
                        Button("Open Recording") { open(example) }.disabled(saving || editingName)
                    }
                    Divider()
                    Text(
                        isReference
                            ? (example.review == .confirmed
                                ? "Confirmed Sample" : "Does this voice belong to \(personName)?")
                            : decision.map(decisionTitle)
                                ?? (reviewPersonID == nil
                                    ? "Who is speaking?" : "Does this voice belong to \(personName)?")
                    )
                    .font(.headline)
                    HStack(spacing: 12) {
                        VoiceSamplePlaybackControl(
                            playing: playing(example), available: audioAvailable(example) && !playback.isPlaybackBlocked
                        ) {
                            if playing(example) {
                                playback.pause()
                            }
                            else {
                                play(example)
                            }
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .disabled(editingName || saving)
                        VStack(alignment: .leading, spacing: 4) {
                            if isReference {
                                sampleNameLabel(example)
                                VoiceSampleStatusLabel(
                                    title: referenceStatus(example),
                                    kind: example.review == .confirmed ? .confirmed : .needsReview)
                            }
                            else if let decision {
                                if confirmed || decision == .skipped {
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
                    if isReference {
                        Text(
                            example.review == .confirmed
                                ? "You confirmed this sample. You can correct its name or remove it from this person."
                                : (example.namedPersonID == reviewPersonID
                                    ? "This sample is associated with this person. Confirm it after listening."
                                    : "This voice may belong to this person. Confirm it after listening.")
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        if session.candidateID != nil {
                            Button("Return to Candidate") { session.returnToCandidate() }
                        }
                    }
                    else if decision == nil {
                        Text(
                            reviewPersonID == nil
                                ? "Name this person once, then review each proposed sample."
                                : "Confirm only the voice heard in this sample. Double-click its name to correct it."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    VoiceSampleTranscriptView(example: example)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if unavailable {
                Text("This sample is no longer in the voice library. Refresh matches to continue.").foregroundStyle(
                    .secondary)
            }
            else if !audioAvailable(example) {
                Text("This excerpt is unavailable. Open the recording to inspect its source.").foregroundStyle(
                    .secondary)
            }
            else if playback.isPlaybackBlocked {
                Text("Finish the recording before playing samples.").foregroundStyle(.secondary)
            }
            if isReference || decision == nil || confirmed || decision == .skipped {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        secondaryDecisions(example, actions: actions)
                        Spacer()
                        identityDecisions(example, actions: actions)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            secondaryDecisions(example, actions: actions)
                            Spacer()
                        }
                        HStack(spacing: 12) {
                            Spacer()
                            identityDecisions(example, actions: actions)
                        }
                    }
                }.disabled(saving || editingName || !store.libraryWritable || unavailable)
            }
        }.padding(24)
    }

    private func unnamedNameLabel(_ example: VoiceExample) -> some View {
        Text("Unnamed Person").font(.headline)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { beginGroupNaming(example) }
            .contextMenu { Button("Name This Person…") { beginGroupNaming(example) } }
            .accessibilityAction(named: "Name This Person") { beginGroupNaming(example) }
            .help("Double-click to name this person.")
    }

    private func sampleNameLabel(_ example: VoiceExample) -> some View {
        VoiceSampleNameLabel(
            example: example, suggestedName: personName, editing: $editingName,
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
    }
    @ViewBuilder private func identityDecisions(_ example: VoiceExample, actions: VoiceMatchReviewSession.Actions)
        -> some View
    {
        if let personID = reviewPersonID {
            Button {
                decide(
                    .reject(ids: [example.id], personID: personID), example: example, decision: .rejected,
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
            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            .disabled(!actions.canConfirm)
        }
        else {
            Button {
                beginGroupNaming(example)
            } label: {
                actionLabel("Name This Person…", action: .name)
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
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
    private func referenceStatus(_ example: VoiceExample) -> String {
        if example.review == .confirmed { return "Confirmed" }
        return example.namedPersonID == reviewPersonID ? "Associated · Needs Review" : "Automatic Match · Needs Review"
    }

    private func loadCandidates(useProvided: Bool) async {
        let request = UUID()
        loadRequest = request
        loading = true
        loadFailed = false
        error = nil
        do {
            let snapshot = try await library.reviewSnapshot(
                for: Set(store.people.map(\.id)), forceRefresh: !useProvided)
            let input = session.refreshInput(
                from: snapshot, initialGroup: initialGroup, fallbackPersonID: personID,
                retainedGroupEvidence: groupEvidence)
            let candidates = input.examples
            guard active, !Task.isCancelled, loadRequest == request else { return }
            groupEvidence = input.groupEvidence
            let eligible = candidates.filter(audioAvailable)
            await loadTitles(for: eligible + references, request: request)
            guard active, !Task.isCancelled, loadRequest == request else { return }
            if initialized {
                session.refreshQueue(eligible, currentEvidence: library.examples)
            }
            else {
                session = VoiceMatchReviewSession(examples: eligible, personID: personID)
                initialized = true
            }
        }
        catch {
            guard active, !Task.isCancelled, loadRequest == request else { return }
            loadFailed = true
            self.error = error.localizedDescription
        }
        loading = false
    }
    private func audioAvailable(_ example: VoiceExample) -> Bool {
        guard example.isPlayable, library.audioIsCurrent(example), let file = example.audioFile else { return false }
        return FileManager.default.fileExists(
            atPath: store.directory(for: example.meetingID).appendingPathComponent(file).path)
    }
    private func playing(_ example: VoiceExample) -> Bool {
        guard let range = example.range else { return false }
        return playback.isPlaying && playback.meetingID == example.meetingID
            && playback.excerptRanges == range.supportSpans.map { $0.start..<$0.end }
            && playback.audioURL(forTrack: playback.selectedTrack)?.lastPathComponent == range.audioFile
    }
    private func play(_ example: VoiceExample) {
        guard active, !editingName, audioAvailable(example) else { return }
        playback.pause()
        playback.requestPlayback(
            load: {
                guard await store.ensureMeetingLoaded(id: example.meetingID), active, session.displayedID == example.id,
                    !editingName
                else { return nil }
                return store.meeting(id: example.meetingID)
            },
            play: { meeting in
                guard let range = example.range else { return }
                playback.playExcerpts(
                    meeting: meeting, directory: store.directory(for: meeting.id), audioFile: range.audioFile,
                    spans: range.supportSpans)
            })
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
        guard !saving else { return }
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
        guard !saving, reviewPersonID == nil, store.libraryWritable,
            !session.unavailableIDs.contains(example.id)
        else { return }
        playback.pause()
        let ignored = session.examples.filter { session.decisions[$0.id] == .ignored }
        let evidence = groupEvidence.filter { candidate in
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
                refreshOwnEvidence()
            }
            else {
                error = store.errorMessage ?? "Couldn’t undo this review. Try again."
            }
            saving = false
        }
    }
    private func open(_ example: VoiceExample) {
        playback.pause()
        Task {
            guard await store.ensureMeetingLoaded(id: example.meetingID), active,
                let meeting = store.meeting(id: example.meetingID)
            else {
                error = "Couldn’t open this recording."
                return
            }
            active = false
            openRecording(VoiceExampleRecordingTarget(example: example, meeting: meeting))
            dismiss()
        }
    }
    private func loadTitles(for examples: [VoiceExample], request: UUID) async {
        guard let index = store.libraryIndex else { return }
        let ids = Set(examples.map(\.meetingID))
        let loaded = await Task.detached {
            var result: [UUID: MeetingListEntry] = [:]
            for id in ids { if let entry = try? index.entry(id: id) { result[id] = entry } }
            return result
        }.value
        if active, !Task.isCancelled, loadRequest == request {
            meetings.merge(loaded) { _, new in new }
        }
    }
    static func metadataLabel(_ example: VoiceExample, date: Date?) -> String {
        guard let date else { return timeLabel(example) }
        let compact: String
        if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            compact = date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        }
        else {
            compact = date.formatted(.dateTime.day().month(.abbreviated).year(.twoDigits).hour().minute())
        }
        return "\(compact) · \(timeLabel(example))"
    }
    static func metadataHelp(_ example: VoiceExample, date: Date?) -> String {
        guard let date else { return timeLabel(example) }
        return "\(date.formatted(date: .complete, time: .shortened)) · \(timeLabel(example))"
    }
    static func timeLabel(_ example: VoiceExample) -> String {
        guard let range = example.range else { return "Audio unavailable" }
        return
            "\(TranscriptRow<Text>.timestamp(range.start))–\(TranscriptRow<Text>.timestamp(range.end)) · \(Int(range.speechDuration.rounded()))s"
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
    var createAndAssign: ((String) async -> Bool)? = nil
    let assign: (UUID) async -> Bool
    @ViewState private var showingEditor = false
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
        return personID.map { TranscriptSpeakerPalette.color(for: $0.uuidString) } ?? .systemBlue
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
            .help("Double-click to edit the sample name. Use the context menu for Edit Sample Name.")
            .focusable()
            .onKeyPress(.return) {
                edit()
                return .handled
            }
    }
    private func edit() {
        guard store.libraryWritable else { return }
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
    private var name: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [Person] { TranscriptSpeakerSearch.matches(store.people, query: query) }
    private var exact: Person? { store.people.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if let explanation { Text(explanation).font(.callout).foregroundStyle(.secondary) }
            TextField("Search People or Enter a Name", text: $query).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if let selectedPerson { save(selectedPerson) } }
                .onKeyPress(.downArrow) {
                    moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(-1)
                    return .handled
                }
                .onChange(of: query) { _, _ in selectedPerson = matches.first?.id }
            List(selection: $selectedPerson) {
                ForEach(matches) { person in
                    Text(person.name).padding(.vertical, 4).tag(person.id)
                        .onTapGesture(count: 2) { save(person.id) }
                }
            }.frame(height: 190)
                .onKeyPress(.return) {
                    if let selectedPerson { save(selectedPerson) }
                    return .handled
                }
            if let error { AppInlineMessage(text: error, systemImage: "exclamationmark.triangle", tint: .red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                if let selectedPerson { Button("Use Name") { save(selectedPerson) } }
                if !name.isEmpty, exact == nil { Button("Create “\(name)”", action: create).lineLimit(1) }
            }
        }.padding(16).frame(width: 340).disabled(saving).interactiveDismissDisabled(saving)
            .task {
                selectedPerson = matches.first?.id
                focused = true
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
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color(nsColor: TranscriptSpeakerPalette.foreground(for: tint)))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(nsColor: tint).opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
    }
}
