import SwiftUI

/// The live tab uses the same native rows and editing gestures as saved text.
/// Recognition updates remain isolated from the recording controls.
struct LiveTranscriptView: View {
    @Environment(\.transcriptLayoutService) private var layoutService
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
            if displayCache.count == 0 {
                ContentUnavailableView {
                    Label(
                        controller.enabled ? "No Live Text Yet" : "Live Transcription Is Off",
                        systemImage: "text.bubble")
                } description: {
                    Text(
                        controller.enabled
                            ? "Recording continues. You can transcribe the saved audio after recording."
                            : "Enable live transcription in Settings to show text in future recordings. You can also transcribe the saved audio after recording."
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else {
                NativeTranscriptView(
                    rows: [], layoutService: layoutService, generation: displayCache.revision, showsSpeakers: false,
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
                    speakerPicker: { _, _, _ in AnyView(EmptyView()) })
            }
        }
        .overlay(alignment: .bottom) {
            LiveTranscriptHeader(
                followsLive: followsLive, hasRows: displayCache.count > 0,
                issues: headerIssues, showsProviderSettings: false,
                follow: { followsLive = true },
                openProviders: {
                    settingsTab = "providers"
                    openSettings()
                })
                .padding(12)
        }
        .onAppear { refreshRows() }
        .onChange(of: controller.streamRevision) { _, _ in refreshRows() }
        .onChange(of: controller.enabled) { _, _ in refreshRows() }
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
            enabled: false, recognitionEnabled: controller.enabled)
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
                personID: nil, track: phrase.source.rawValue, label: phrase.speakerLabel)
            return TranscriptDisplayRow(
                id: phrase.id, start: phrase.start, end: phrase.end,
                speaker: personID.flatMap { names[$0] } ?? phrase.speakerLabel,
                speakerID: phrase.id, text: phrase.text,
                personID: personID, speakerColorIndex: phrase.resolvedSpeakerColorSlot, speakerColorKey: key,
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

/// Floating controls leave the full transcript height available while following live text.
struct LiveTranscriptHeader: View {
    let followsLive: Bool
    let hasRows: Bool
    let issues: [String]
    let showsProviderSettings: Bool
    let follow: () -> Void
    let openProviders: () -> Void
    @ViewState private var showsIssues = false

    var body: some View {
        HStack(spacing: 12) {
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
            if !followsLive && hasRows {
                Button(action: follow) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .help("Follow Live")
                .accessibilityLabel("Follow Live")
            }
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
