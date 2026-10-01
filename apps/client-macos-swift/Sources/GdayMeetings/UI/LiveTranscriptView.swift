import SwiftUI

/// The live tab uses the same native rows and editing gestures as saved text.
/// Recognition updates remain isolated from the recording controls.
struct LiveTranscriptView: View {
    @EnvironmentObject private var store: MeetingStore
    @ObservedObject var controller: LiveTranscriptController
    @ViewState private var followsLive = true
    @ViewState private var displayRows: [TranscriptDisplayRow] = []
    @ViewState private var displayGeneration = 0
    @ViewState private var hasUnresolvedTiming = false
    @ViewState private var displayedPhrases: [UUID: LiveTranscriptPhrase] = [:]

    var body: some View {
        let phrases = displayedPhrases
        let displayedMeetingID = controller.draft?.meetingID
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Live Transcript", isOn: Binding(get: { controller.enabled }, set: controller.setEnabled))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                Button("Follow Live") { followsLive = true }
                    .disabled(followsLive || displayRows.isEmpty)
            }
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle(
                    "Live Speaker Labels",
                    isOn: Binding(
                        get: { controller.speakerLabelsEnabled }, set: controller.setSpeakerLabelsEnabled))
                Toggle(
                    "Speaker Recognition",
                    isOn: Binding(
                        get: { controller.speakerRecognitionEnabled }, set: controller.setSpeakerRecognitionEnabled))
            }.toggleStyle(.switch).controlSize(.small)
            if controller.speakerLabelsEnabled, !controller.speakerLabelStatus.isEmpty {
                Text(controller.speakerLabelStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if controller.speakerRecognitionEnabled, !controller.speakerRecognitionStatus.isEmpty {
                Text(controller.speakerRecognitionStatus).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hasUnresolvedTiming {
                Text("Some edited passages overlap recognition text because their word timing is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
        .onChange(of: controller.speakerLabelsEnabled) { _, _ in refreshRows() }
        .onChange(of: store.people) { _, _ in refreshRows() }
    }

    private func refreshRows() {
        let finalized = controller.presentedFinalized.sorted(by: LiveTranscriptPhrase.ordered)
        let partials = controller.presentedPartials
        displayedPhrases = Dictionary(uniqueKeysWithValues: (finalized + partials).map { ($0.id, $0) })
        hasUnresolvedTiming = (finalized + partials).contains(where: \.hasUnresolvedTiming)
        displayRows = LiveTranscriptDisplay.rows(finalized: finalized, partials: partials, people: store.people)
        displayGeneration += 1
    }
}

enum LiveTranscriptDisplay {
    static func rows(finalized: [LiveTranscriptPhrase], partials: [LiveTranscriptPhrase], people: [Person])
        -> [TranscriptDisplayRow]
    {
        let names = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0.name) })
        let rows = LiveTranscriptPresentation.rows(finalized: finalized, partials: partials)
        func personID(_ phrase: LiveTranscriptPhrase) -> UUID? {
            phrase.personID.flatMap { names[$0] == nil ? nil : $0 }
        }
        func key(_ phrase: LiveTranscriptPhrase) -> String {
            personID(phrase)?.uuidString ?? phrase.speakerIdentity?.uuidString ?? phrase.speakerLabel
        }
        let colors = TranscriptSpeakerPalette.indices(for: rows.map { key($0.phrase) })
        return rows.map { row in
            let phrase = row.phrase
            return TranscriptDisplayRow(
                id: phrase.id, start: phrase.start,
                speaker: phrase.personID.flatMap { names[$0] } ?? phrase.speakerLabel,
                speakerID: phrase.id, text: phrase.text,
                personID: personID(phrase), speakerColorIndex: colors[key(phrase)],
                isProvisional: row.provisional && !phrase.isUserEdited,
                recentWordRanges: row.provisional && !phrase.isUserEdited
                    ? LiveTranscriptPresentation.recentWordRanges(in: phrase).map { NSRange($0, in: phrase.text) } : [],
                accessibilityHelp: phrase.isUserEdited ? "Edited text." : nil)
        }
    }
}
