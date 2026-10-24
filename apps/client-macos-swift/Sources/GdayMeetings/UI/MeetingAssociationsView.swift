import AppKit
import SwiftUI

struct MeetingTagsView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.showTag) private var showTag
    let meetingID: UUID
    @ViewState private var addingTag = false
    @ViewState private var tagName = ""
    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        HStack(spacing: 8) {
            Text("Tags").font(.callout).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(store.tags.filter { meeting?.tagIDs.contains($0.id) ?? false }) { tag in
                        TagAssociationChip(
                            id: tag.id, name: tag.name, removalHelp: "Remove \(tag.name) from this meeting",
                            open: { showTag(tag.id) }, remove: { setTag(tag.id, selected: false) })
                    }
                    Menu {
                        ForEach(store.tags) { tag in
                            Toggle(
                                tag.name,
                                isOn: Binding(
                                    get: { meeting?.tagIDs.contains(tag.id) ?? false },
                                    set: { setTag(tag.id, selected: $0) }))
                        }
                        Divider()
                        Button("New Tag…") {
                            tagName = ""
                            addingTag = true
                        }
                    } label: {
                        Label("Add Tag", systemImage: "plus").labelStyle(.iconOnly)
                            .frame(minWidth: 28, minHeight: 28)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help("Add tags to this meeting")
                }
            }.scrollIndicators(.hidden).frame(height: 32)
        }
        .sheet(isPresented: $addingTag) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Tag").font(.headline)
                TextField("Name", text: $tagName).onSubmit(addTag)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { addingTag = false }.keyboardShortcut(.cancelAction)
                    Button("Add Tag", action: addTag).keyboardShortcut(.defaultAction)
                        .disabled(tagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 320)
        }
    }

    private func setTag(_ id: UUID, selected: Bool) {
        Task {
            guard var meeting else { return }
            meeting.tagIDs.removeAll { $0 == id }
            if selected { meeting.tagIDs.append(id) }
            await store.updateMeeting(meeting)
        }
    }
    private func addTag() {
        let name = tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        addingTag = false
        Task {
            let id: UUID
            if let existing = store.tags.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
            {
                id = existing.id
            }
            else {
                id = await store.addTag(name: name)
            }
            guard store.tags.contains(where: { $0.id == id }) else { return }
            setTag(id, selected: true)
        }
    }
}

struct MeetingSpeakersView: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var newPersonSpeaker: MeetingSpeaker?
    @ViewState private var personName = ""
    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meeting {
                let speakers = meeting.assignableSpeakers
                let passageAssignments = meeting.speakerLabelAssignments
                ForEach(speakers) { speaker in
                    speakerRow(speaker, passageAssignments: passageAssignments[speaker.id] ?? .init())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .sheet(item: $newPersonSpeaker) { speaker in
            VStack(alignment: .leading, spacing: 16) {
                Text("New Person").font(.headline)
                TextField("Name", text: $personName).onSubmit { createPerson(speaker) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { newPersonSpeaker = nil }.keyboardShortcut(.cancelAction)
                    Button("Assign Person") { createPerson(speaker) }.keyboardShortcut(.defaultAction)
                        .disabled(personName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 320)
        }
    }

    private func speakerRow(_ speaker: MeetingSpeaker, passageAssignments: SpeakerLabelAssignmentSummary) -> some View {
        HStack(spacing: 12) {
            Text(speaker.displayLabel.isEmpty ? "Unlabeled" : speaker.displayLabel)
                .font(.callout.monospaced())
                .lineLimit(1)
                .help([speaker.providerName, speaker.track].filter { !$0.isEmpty }.joined(separator: " · "))
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let personID = speaker.personID,
                    speaker.manuallyAssigned == true
                        || store.voiceLibrary.referenceDecision(
                            meetingID: meetingID, speakerID: speaker.id, personID: personID) != nil
                {
                    SpeakerReferenceStatus(
                        library: store.voiceLibrary, preparation: store.voicePreparation,
                        meetingID: meetingID, speakerID: speaker.id, personID: personID)
                }
                if !speaker.canAssignPerson {
                    Text(personName(for: speaker, passageAssignments: passageAssignments) ?? "Unassigned").lineLimit(1)
                        .frame(maxWidth: 240)
                }
                actions(speaker, passageAssignments: passageAssignments)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 28)
    }

    private func personName(for speaker: MeetingSpeaker, passageAssignments: SpeakerLabelAssignmentSummary) -> String? {
        let personID = speaker.personID ?? passageAssignments.uniformPersonID
        guard let name = store.people.first(where: { $0.id == personID })?.name else { return nil }
        let tentative =
            speaker.voiceReviewOrigin?.transcriptAssociationTier == .tentative
            || (speaker.personID == nil && passageAssignments.hasTentativePerson)
        return tentative ? "\(name) (Tentative)" : name
    }

    private func assignmentTint(for speaker: MeetingSpeaker, passageAssignments: SpeakerLabelAssignmentSummary)
        -> NSColor?
    {
        guard let personID = speaker.personID ?? passageAssignments.uniformPersonID else { return nil }
        return TranscriptSpeakerPalette.color(for: personID.uuidString)
    }

    @ViewBuilder private func actions(_ speaker: MeetingSpeaker, passageAssignments: SpeakerLabelAssignmentSummary)
        -> some View
    {
        let variesByPassage = passageAssignments.variesByPassage
        if !speaker.canAssignPerson {
            Button("Remove Assignment") {
                Task { await store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: nil) }
            }
        }
        else {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.people) { person in
                        Button(person.name) {
                            Task {
                                await store.assignSpeaker(
                                    meetingID: meetingID, speakerID: speaker.id, personID: person.id)
                            }
                        }
                    }
                    Divider()
                    Button("New Person…") {
                        personName = ""
                        newPersonSpeaker = speaker
                    }
                    if speaker.personID != nil || passageAssignments.hasAssignments {
                        Button("Remove Assignment") {
                            Task {
                                await store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: nil)
                            }
                        }
                    }
                } label: {
                    if let name = personName(for: speaker, passageAssignments: passageAssignments),
                        let tint = assignmentTint(for: speaker, passageAssignments: passageAssignments)
                    {
                        Text(name)
                            .foregroundStyle(Color(nsColor: TranscriptSpeakerPalette.foreground(for: tint)))
                    }
                    else {
                        Text(variesByPassage ? "Varies by Passage" : "Assign Person")
                    }
                }
                .modifier(
                    SpeakerAssignmentMenuStyle(
                        tint: personName(for: speaker, passageAssignments: passageAssignments) == nil
                            ? nil : assignmentTint(for: speaker, passageAssignments: passageAssignments))
                )
                .lineLimit(1)
                .frame(maxWidth: 240, alignment: .trailing)
                .accessibilityLabel(
                    "Assign \(speaker.displayLabel.isEmpty ? "unlabeled speaker" : speaker.displayLabel) to a person"
                )
                .accessibilityValue(
                    personName(for: speaker, passageAssignments: passageAssignments)
                        ?? (variesByPassage ? "Varies by passage" : "Unassigned")
                )
                .help(
                    speaker.passageAssignmentOrigin == nil
                        ? "Assign a person to every passage with this speaker label. Individually corrected passages keep their assignments."
                        : "Assign a person to this corrected passage."
                )
            }
        }
    }

    private func createPerson(_ speaker: MeetingSpeaker) {
        let name = personName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newPersonSpeaker = nil
        Task {
            let personID = await store.addPerson(name: name)
            guard store.people.contains(where: { $0.id == personID }) else { return }
            await store.assignSpeaker(meetingID: meetingID, speakerID: speaker.id, personID: personID)
        }
    }
}

extension TranscriptSpeakerPalette {
    /// A person keeps the same color across meetings and assignment changes.
    static func assignmentTint(for speaker: MeetingSpeaker) -> NSColor? {
        guard let personID = speaker.personID else { return nil }
        return color(for: personID.uuidString)
    }
}

private struct SpeakerAssignmentMenuStyle: ViewModifier {
    let tint: NSColor?

    @ViewBuilder func body(content: Content) -> some View {
        if let tint {
            content
                .menuStyle(.borderlessButton)
                .foregroundStyle(Color(nsColor: TranscriptSpeakerPalette.foreground(for: tint)))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Color(nsColor: TranscriptSpeakerPalette.fill(for: tint)), in: RoundedRectangle(cornerRadius: 9))
        }
        else {
            content
        }
    }
}

struct SpeakerReferenceValidation: Equatable {
    var decision: VoiceSpeakerDecision?
    var dependency: VoiceReferenceFeedbackDependency
    var personExists: Bool

    var hasCurrentSample: Bool {
        guard personExists, let result = decision?.referenceSelectionResult,
            let sample = dependency.sample, sample.id == result.sampleID,
            sample.personID == decision?.personID, sample.review == .confirmed,
            !sample.excluded, !sample.manuallyCleared, sample.audioRevision == result.audioRevision
        else { return false }
        return true
    }

    func hasSameSample(as other: Self) -> Bool {
        decision == other.decision && personExists == other.personExists
            && dependency.sample == other.dependency.sample
            && dependency.representationRevision == other.dependency.representationRevision
            && dependency.profileEligible == other.dependency.profileEligible
    }
}

/// Preserve a verified answer during a refresh of the same assignment. Known
/// sample removal, reassignment, or representation changes invalidate it at once.
struct SpeakerReferenceValidationState {
    private(set) var validation: SpeakerReferenceValidation?
    private(set) var usage: VoiceReferenceSampleUsage?
    private(set) var failed = false
    private(set) var refreshFailed = false

    func usage(for current: SpeakerReferenceValidation) -> VoiceReferenceSampleUsage? {
        guard current.hasCurrentSample else { return .unavailable }
        guard current.dependency.profileEligible else { return .stored }
        guard let validation, current.hasSameSample(as: validation) else { return nil }
        return usage
    }

    func failed(for current: SpeakerReferenceValidation) -> Bool {
        guard let validation, current.hasSameSample(as: validation) else { return false }
        return failed
    }

    func refreshFailed(for current: SpeakerReferenceValidation) -> Bool {
        guard let validation, current.hasSameSample(as: validation) else { return false }
        return refreshFailed
    }

    mutating func begin(_ current: SpeakerReferenceValidation) {
        let retained = usage(for: current)
        validation = current
        usage = retained
        failed = false
        refreshFailed = false
    }

    mutating func complete(_ usage: VoiceReferenceSampleUsage, for current: SpeakerReferenceValidation) {
        guard validation == current else { return }
        self.usage = usage
        failed = false
        refreshFailed = false
    }

    mutating func fail(_ current: SpeakerReferenceValidation) {
        guard validation == current else { return }
        // A transient shared-query failure does not erase a previously verified
        // answer for unchanged evidence. Initial verification remains explicit.
        failed = usage == nil
        refreshFailed = true
    }
}

/// Recognition evidence has its own outcome beside the transcript identity.
private struct SpeakerReferenceStatus: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var library: VoiceLibraryStore
    @ObservedObject var preparation: VoiceLibraryPreparation
    let meetingID: UUID
    let speakerID: UUID
    let personID: UUID
    @ViewState private var validationState = SpeakerReferenceValidationState()
    @ViewState private var showingDetails = false
    @ViewState private var showingSamples = false

    private var decision: VoiceSpeakerDecision? {
        library.referenceDecision(meetingID: meetingID, speakerID: speakerID, personID: personID)
    }
    private var validation: SpeakerReferenceValidation {
        let current = decision
        return .init(
            decision: current,
            dependency: library.referenceFeedbackDependency(
                personID: personID, result: current?.referenceSelectionResult),
            personExists: store.people.contains { $0.id == personID })
    }
    private var working: Bool { preparation.referenceTokens[speakerID] != nil }
    private var waiting: Bool {
        decision?.referenceSelectionPending == true && decision?.referenceSelectionResult == nil
    }
    private var canRetry: Bool {
        decision != nil && !working && store.libraryWritable && store.recordingID == nil
            && !store.isStartingRecording && !store.isFinalizingRecording
    }
    private var status: (symbol: String, meaning: String, tint: Color) {
        let value = baseStatus
        guard validationState.refreshFailed(for: validation), validationState.usage(for: validation) != nil else {
            return value
        }
        return (
            value.symbol,
            value.meaning + " Couldn’t refresh this status. The last verified result is shown.",
            value.tint
        )
    }
    private var baseStatus: (symbol: String, meaning: String, tint: Color) {
        guard let result = decision?.referenceSelectionResult else {
            return ("questionmark.circle", "No voice-sample outcome was recorded for this assignment.", .secondary)
        }
        switch result.outcome {
        case .sampleAdded, .sampleAvailable:
            if validationState.failed(for: validation) {
                return (
                    "exclamationmark.triangle", "Couldn’t check whether this voice sample is in use. Retry the check.",
                    .orange
                )
            }
            switch validationState.usage(for: validation) {
            case .available:
                return (
                    "checkmark.circle.fill",
                    result.outcome == .sampleAdded
                        ? "Voice sample added. It is available for recognition with the same voice model."
                        : "A voice sample is already available for recognition with the same voice model.", .green
                )
            case .stored:
                return (
                    "archivebox", "Voice sample saved. It is not currently selected for recognition.",
                    .secondary
                )
            case .unavailable:
                return (
                    "minus.circle",
                    "This voice sample is no longer available for this person. Retry to check for another sample.",
                    .secondary
                )
            case nil:
                return ("ellipsis.circle", "Checking whether the saved voice sample is in use.", .secondary)
            }
        case .scanNeeded:
            return (
                "magnifyingglass.circle",
                "Scan this recording to check for a voice sample. The person assignment is saved.", .secondary
            )
        case .audioUnavailable:
            return (
                "speaker.slash",
                "No voice sample was added because recording audio was unavailable. The person assignment is saved.",
                .secondary
            )
        case .noSuitableSample:
            return (
                "waveform.badge.exclamationmark", "No suitable voice sample was found. The person assignment is saved.",
                .secondary
            )
        case .alreadyRepresented:
            return (
                "waveform",
                "No new voice sample was added. The existing recognition profile was kept.",
                .secondary
            )
        case .conflictingEvidence:
            return (
                "person.crop.circle.badge.exclamationmark",
                "No voice sample was added because it conflicted with confirmed voice evidence. Review this person’s voice samples.",
                .orange
            )
        case .failed:
            return (
                "exclamationmark.triangle",
                "Couldn’t prepare a voice sample. The person assignment is saved. Check the sample again to retry.",
                .orange
            )
        case .passageOnly:
            return ("text.bubble", "This passage assignment did not add a recording-wide voice sample.", .secondary)
        }
    }

    var body: some View {
        let currentValidation = validation
        Group {
            if working {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                }
                .help("Checking recording audio for a suitable voice sample. The person assignment is saved.")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Checking voice sample")
            }
            else if waiting {
                Button("Waiting…") { showingDetails = true }.buttonStyle(.plain)
                    .font(.caption).foregroundStyle(.secondary)
                    .help(
                        "Voice-sample preparation is waiting. It resumes when the recording and voice library are available."
                    )
                    .accessibilityLabel("Waiting to check voice sample")
                    .contextMenu { retryButton }
            }
            else {
                let value = status
                Button {
                    showingDetails = true
                } label: {
                    Image(systemName: value.symbol).foregroundStyle(value.tint)
                }
                .buttonStyle(.plain)
                .help(value.meaning)
                .accessibilityLabel(value.meaning)
                .contextMenu { retryButton }
            }
        }
        .popover(isPresented: $showingDetails) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Voice Sample").font(.headline)
                Text(
                    working
                        ? "Checking recording audio for a suitable voice sample. The person assignment is saved."
                        : (waiting
                            ? "Voice-sample preparation is waiting. It resumes when the recording and voice library are available."
                            : status.meaning)
                )
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                retryButton
                Button("Review Voice Samples…") { showingSamples = true }
            }
            .padding(16).frame(width: 300)
            .sheet(isPresented: $showingSamples) {
                PersonSamplesView(library: library, personID: personID)
            }
        }
        .task(id: currentValidation) {
            validationState.begin(currentValidation)
            guard let result = currentValidation.decision?.referenceSelectionResult,
                result.outcome == .sampleAdded || result.outcome == .sampleAvailable,
                currentValidation.hasCurrentSample
            else { return }
            do {
                let checked = try await library.referenceSampleUsage(
                    result: result, personID: personID, people: store.people)
                try Task.checkCancellation()
                guard validation == currentValidation else { return }
                validationState.complete(checked, for: currentValidation)
            }
            catch is CancellationError {}
            catch {
                guard !Task.isCancelled, validation == currentValidation else { return }
                validationState.fail(currentValidation)
            }
        }
    }

    private var retryButton: some View {
        Button("Check Voice Sample Again") {
            guard let expected = decision else { return }
            Task {
                _ = await store.retrySpeakerReference(
                    meetingID: meetingID, speakerID: speakerID, personID: personID, expectedDecision: expected)
            }
        }.disabled(!canRetry)
    }
}
