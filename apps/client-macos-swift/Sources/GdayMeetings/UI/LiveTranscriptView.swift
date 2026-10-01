import SwiftUI

/// The live tab uses the same native rows and editing gestures as saved text.
/// Recognition updates remain isolated from the recording controls.
struct LiveTranscriptView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var controller: LiveTranscriptController
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    @ViewState private var followsLive = true
    @ViewState private var displayRows: [TranscriptDisplayRow] = []
    @ViewState private var displayGeneration = 0
    @ViewState private var hasUnresolvedTiming = false
    @ViewState private var displayedPhrases: [UUID: LiveTranscriptPhrase] = [:]

    var body: some View {
        let phrases = displayedPhrases
        let displayedMeetingID = controller.draft?.meetingID
        VStack(alignment: .leading, spacing: 8) {
            LiveTranscriptHeader(
                enabled: Binding(get: { controller.enabled }, set: controller.setEnabled),
                recognizesSpeakers: Binding(
                    get: { controller.speakerLabelsEnabled || controller.speakerRecognitionEnabled },
                    set: { enabled in
                        controller.setSpeakerLabelsEnabled(enabled)
                        controller.setSpeakerRecognitionEnabled(enabled)
                    }),
                followsLive: followsLive, hasRows: !displayRows.isEmpty,
                issues: headerIssues, showsProviderSettings: controller.canOpenProviderSettings,
                follow: { followsLive = true },
                openProviders: {
                    settingsTab = "providers"
                    openSettings()
                })
            if displayRows.isEmpty {
                ContentUnavailableView {
                    Label(
                        controller.enabled ? "No Live Text Yet" : "Live Transcript Is Off", systemImage: "text.bubble")
                } description: {
                    Text(
                        controller.enabled
                            ? "Recording continues. You can transcribe the saved audio after recording."
                            : "Turn on Live Transcript to see text here. You can also transcribe the saved audio after recording."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                NativeTranscriptView(
                    rows: displayRows, generation: displayGeneration, showsSpeakers: true,
                    editable: store.libraryWritable, canPlay: false, meetingID: controller.draft?.meetingID,
                    followsLive: followsLive, pauseLiveFollowing: { followsLive = false }, play: { _ in },
                    save: { id, text in
                        guard store.libraryWritable, controller.draft?.meetingID == displayedMeetingID,
                            let phrase = phrases[id]
                        else { return }
                        followsLive = false
                        controller.updateText(phrase: phrase, text: text)
                    },
                    speakerPicker: { id, completed in
                        if let meetingID = controller.draft?.meetingID,
                            let phrase = phrases[id]
                        {
                            return AnyView(
                                TranscriptSpeakerPicker(
                                    meetingID: meetingID,
                                    speaker: MeetingSpeaker(
                                        id: id, label: phrase.speakerLabel, track: phrase.source.rawValue,
                                        providerName: controller.draft?.provider ?? "This Mac",
                                        personID: phrase.personID),
                                    completed: completed,
                                    assignment: { personID in
                                        guard store.libraryWritable,
                                            controller.draft?.meetingID == displayedMeetingID,
                                            personID == nil || store.people.contains(where: { $0.id == personID })
                                        else { return }
                                        followsLive = false
                                        controller.assignPerson(phrase: phrase, personID: personID)
                                    },
                                    lineAssignment: phrase.speakerIdentity == nil
                                        ? nil
                                        : { personID in
                                            guard store.libraryWritable,
                                                controller.draft?.meetingID == displayedMeetingID,
                                                personID == nil || store.people.contains(where: { $0.id == personID })
                                            else { return }
                                            followsLive = false
                                            controller.assignPersonToLine(phrase: phrase, personID: personID)
                                        }
                                ).environmentObject(store))
                        }
                        return AnyView(Text("Speaker is unavailable."))
                    })
            }
        }
        .onAppear { refreshRows() }
        .onChange(of: controller.draft) { _, _ in refreshRows() }
        .onChange(of: controller.partials) { _, _ in refreshRows() }
        .onChange(of: controller.enabled) { _, _ in refreshRows() }
        .onChange(of: controller.speakerLabelsEnabled) { _, _ in refreshRows() }
        .onChange(of: store.people.map { PersonDisplayIdentity(id: $0.id, name: $0.name) }) { _, _ in refreshRows() }
    }

    private var headerIssues: [String] {
        controller.liveTranscriptIssues
            + (hasUnresolvedTiming
                ? ["Some edited passages overlap recognition text because their word timing is unavailable."] : [])
    }

    private func refreshRows() {
        let presented = controller.presentedRows
        let finalized = presented.finalized
        let partials = presented.partials
        displayedPhrases = Dictionary(uniqueKeysWithValues: (finalized + partials).map { ($0.id, $0) })
        hasUnresolvedTiming = (finalized + partials).contains(where: \.hasUnresolvedTiming)
        let updated = LiveTranscriptDisplay.rows(
            finalized: finalized, partials: partials, people: store.people, recognitionEnabled: controller.enabled)
        if updated != displayRows {
            displayRows = updated
            displayGeneration += 1
        }
    }
}

enum LiveTranscriptDisplay {
    static func rows(
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase], people: [Person],
        recognitionEnabled: Bool = true
    )
        -> [TranscriptDisplayRow]
    {
        let activePhraseID = recognitionEnabled ? LiveTranscriptPresentation.activePhraseID(partials) : nil
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let rows = LiveTranscriptPresentation.rows(finalized: finalized, partials: partials)
        func personID(_ phrase: LiveTranscriptPhrase) -> UUID? {
            phrase.personID.flatMap { names[$0] == nil ? nil : $0 }
        }
        func key(_ phrase: LiveTranscriptPhrase) -> String {
            TranscriptSpeakerPalette.displayKey(
                personID: personID(phrase), track: phrase.source.rawValue, label: phrase.speakerLabel)
        }
        return rows.map { row in
            let phrase = row.phrase
            return TranscriptDisplayRow(
                id: phrase.id, start: phrase.start,
                speaker: phrase.personID.flatMap { names[$0] } ?? phrase.speakerLabel,
                speakerID: phrase.id, text: phrase.text,
                personID: personID(phrase), speakerColorIndex: TranscriptSpeakerPalette.index(for: key(phrase)),
                isProvisional: row.provisional && !phrase.isUserEdited,
                recentWordRanges: row.provisional && !phrase.isUserEdited && phrase.id == activePhraseID
                    ? LiveTranscriptPresentation.recentWordRanges(in: phrase).map { NSRange($0, in: phrase.text) } : [],
                accessibilityHelp: phrase.isUserEdited ? "Edited text." : nil)
        }
    }
}

private struct PersonDisplayIdentity: Equatable {
    let id: UUID
    let name: String
}

/// Compact controls stay separate from volatile transcript rows.
struct LiveTranscriptHeader: View {
    @Binding var enabled: Bool
    @Binding var recognizesSpeakers: Bool
    let followsLive: Bool
    let hasRows: Bool
    let issues: [String]
    let showsProviderSettings: Bool
    let follow: () -> Void
    let openProviders: () -> Void
    @ViewState private var showsIssues = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Live Transcript", isOn: $enabled)
                .toggleStyle(.switch).controlSize(.small).fixedSize()
            if enabled {
                Toggle("Speaker Recognition", isOn: $recognizesSpeakers)
                    .toggleStyle(.switch).controlSize(.small).fixedSize()
            }
            if !issues.isEmpty {
                Button {
                    showsIssues.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show transcript issues")
                .accessibilityLabel("Transcript issues")
                .popover(isPresented: $showsIssues) {
                    LiveTranscriptIssueDetails(
                        issues: issues, showsProviderSettings: showsProviderSettings,
                        openProviders: {
                            showsIssues = false
                            openProviders()
                        })
                }
            }
            Spacer(minLength: 8)
            Button("Follow Live", action: follow)
                .disabled(followsLive || !hasRows)
                .fixedSize()
        }
    }
}

struct LiveTranscriptIssueDetails: View {
    let issues: [String]
    let showsProviderSettings: Bool
    let openProviders: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript Issues").font(.headline)
            ForEach(issues, id: \.self) { issue in
                Text(issue).fixedSize(horizontal: false, vertical: true)
            }
            if showsProviderSettings {
                Button("Open Service Providers", action: openProviders)
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}
