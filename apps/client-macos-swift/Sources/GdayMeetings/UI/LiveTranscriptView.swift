import SwiftUI

/// The live tab uses the same native rows and editing gestures as saved text.
/// Recognition updates remain isolated from the recording controls.
struct LiveTranscriptView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var controller: LiveTranscriptController
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "defaults"
    @ViewState private var followsLive = true
    @StateObject private var displayCache = LiveTranscriptStreamDisplayCache()
    @ViewState private var hasUnresolvedTiming = false

    var body: some View {
        let displayedMeetingID = controller.draft?.meetingID
        VStack(alignment: .leading, spacing: 8) {
            LiveTranscriptHeader(
                enabled: Binding(get: { controller.enabled }, set: controller.setEnabled),
                recognizesSpeakers: Binding(
                    get: { controller.speakerLabelsEnabled },
                    set: { enabled in
                        controller.setSpeakerLabelsEnabled(enabled)
                    }),
                followsLive: followsLive, hasRows: displayCache.count > 0,
                issues: headerIssues, showsProviderSettings: controller.canOpenProviderSettings,
                follow: { followsLive = true },
                openProviders: {
                    settingsTab = "providers"
                    openSettings()
                })
            if displayCache.count == 0 {
                ContentUnavailableView {
                    Label(
                        controller.enabled ? "No Live Text Yet" : "Live Transcription Is Off",
                        systemImage: "text.bubble")
                } description: {
                    Text(
                        controller.enabled
                            ? "Recording continues. You can transcribe the saved audio after recording."
                            : "Turn on Transcribe to see text here. You can also transcribe the saved audio after recording."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                NativeTranscriptView(
                    rows: [], generation: displayCache.revision, showsSpeakers: true,
                    editable: store.libraryWritable, canPlay: false, meetingID: controller.draft?.meetingID,
                    liveRows: displayCache,
                    captureSave: { id in
                        let phrase = displayCache.phrase(id: id)
                        return { text in
                            guard store.libraryWritable, controller.draft?.meetingID == displayedMeetingID,
                                let phrase
                            else { return }
                            followsLive = false
                            controller.updateText(phrase: phrase, text: text)
                        }
                    }, followsLive: followsLive, pauseLiveFollowing: { followsLive = false }, play: { _ in },
                    save: { id, text in
                        guard store.libraryWritable, controller.draft?.meetingID == displayedMeetingID,
                            let phrase = displayCache.phrase(id: id)
                        else { return }
                        followsLive = false
                        controller.updateText(phrase: phrase, text: text)
                    },
                    speakerPicker: { id, completed in
                        if let meetingID = controller.draft?.meetingID,
                            let phrase = displayCache.phrase(id: id)
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
        .onChange(of: controller.streamRevision) { _, _ in refreshRows() }
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
        displayCache.update(
            controller.presentedStream, people: store.people,
            enabled: controller.speakerLabelsEnabled, recognitionEnabled: controller.enabled)
        hasUnresolvedTiming = displayCache.hasUnresolvedTiming
    }
}

enum LiveTranscriptDisplay {
    static func rows(
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase], people: [Person],
        recognitionEnabled: Bool = true, overrides: [LiveTranscriptOverride] = []
    ) -> [TranscriptDisplayRow] {
        snapshot(
            finalized: finalized, partials: partials, people: people,
            recognitionEnabled: recognitionEnabled, overrides: overrides
        ).rows
    }

    static func snapshot(
        finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase], people: [Person],
        recognitionEnabled: Bool = true, overrides: [LiveTranscriptOverride] = []
    ) -> (rows: [TranscriptDisplayRow], phrases: [UUID: LiveTranscriptPhrase]) {
        let activePhraseID = recognitionEnabled ? LiveTranscriptPresentation.activePhraseID(partials) : nil
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let groups = LiveTranscriptParagraphs.groups(finalized: finalized, partials: partials, overrides: overrides)
        return snapshot(groups: groups, names: names, activePhraseID: activePhraseID)
    }

    static func snapshot(
        groups: [LiveTranscriptParagraphs.Paragraph], names: [UUID: String], activePhraseID: UUID?
    ) -> (rows: [TranscriptDisplayRow], phrases: [UUID: LiveTranscriptPhrase]) {
        let rows = groups.map { group in
            let phrase = group.phrase
            let personID = phrase.personID.flatMap { names[$0] == nil ? nil : $0 }
            let provisionalRanges = group.parts.filter { $0.provisional && !$0.phrase.isUserEdited }.map(\.textRange)
            let recentRanges = group.parts.filter {
                $0.provisional && !$0.phrase.isUserEdited && $0.phrase.id == activePhraseID
            }
            .flatMap { part in
                LiveTranscriptPresentation.recentWordRanges(in: part.phrase).map {
                    let range = NSRange($0, in: part.phrase.text)
                    return NSRange(location: part.textRange.location + range.location, length: range.length)
                }
            }
            let key = TranscriptSpeakerPalette.displayKey(
                personID: personID, track: phrase.source.rawValue, label: phrase.speakerLabel)
            return TranscriptDisplayRow(
                id: phrase.id, start: phrase.start,
                speaker: personID.flatMap { names[$0] } ?? phrase.speakerLabel,
                speakerID: phrase.id, text: phrase.text,
                personID: personID, speakerColorIndex: TranscriptSpeakerPalette.index(for: key),
                isProvisional: !provisionalRanges.isEmpty, provisionalTextRanges: provisionalRanges,
                recentWordRanges: recentRanges,
                accessibilityHelp: phrase.isUserEdited ? "Edited text." : nil,
                isSourcePlaceholder: !phrase.hasSpeakerIdentity)
        }
        return (rows, Dictionary(uniqueKeysWithValues: groups.map { ($0.phrase.id, $0.phrase) }))
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
            Toggle("Transcribe", isOn: $enabled)
                .toggleStyle(.switch).controlSize(.small).fixedSize()
            Toggle("Label Speakers", isOn: $recognizesSpeakers)
                .toggleStyle(.switch).controlSize(.small).fixedSize()
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
