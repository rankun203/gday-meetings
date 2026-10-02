import Foundation

/// Ordered recording events keep crash recovery independent of display history.
enum LiveTranscriptJournalRecord: Codable, Sendable {
    case begin(LiveTranscriptDraft, labeling: Bool)
    case phrase(LiveTranscriptPhrase, final: Bool)
    case speaker(LiveSpeakerEvent)
    case gap(LiveTranscriptGap, speaker: Bool)
    case state(LiveTranscriptDraft, labeling: Bool)
    case finish
    case discardPartials

    static func replay(_ records: [Self]) -> LiveTranscriptDraft? {
        var draft: LiveTranscriptDraft?
        let stream = LiveTranscriptStream()
        for record in records {
            switch record {
            case .begin(let initial, let labeling):
                draft = initial
                stream.reset(labeling: labeling, sources: initial.liveSources ?? [.system])
            case .phrase(let phrase, let final):
                guard draft != nil else { continue }
                if final { draft?.phrases.append(phrase) }
                stream.accept(phrase, final: final)
            case .speaker(let event):
                if draft?.speakerTimeline == nil { draft?.speakerTimeline = LiveSpeakerTimeline() }
                _ = draft?.speakerTimeline?.accept(event)
                stream.accept(event)
            case .gap(let gap, let speaker):
                if speaker {
                    if draft?.speakerTimeline == nil { draft?.speakerTimeline = LiveSpeakerTimeline() }
                    draft?.speakerTimeline?.gaps.append(gap)
                }
                else {
                    draft?.gaps.append(gap)
                }
                stream.accept(gap)
            case .state(let state, let labeling):
                draft?.locale = state.locale
                draft?.complete = state.complete
                draft?.speakerLabelsComplete = state.speakerLabelsComplete
                draft?.overrides = state.overrides
                if let speakers = state.speakerTimeline?.speakers {
                    for speaker in speakers {
                        if let index = draft?.speakerTimeline?.speakers.firstIndex(where: { $0.id == speaker.id }) {
                            draft?.speakerTimeline?.speakers[index] = speaker
                        }
                    }
                }
                stream.setLabeling(labeling)
            case .finish:
                stream.finish()
            case .discardPartials:
                stream.discardPartials()
            }
        }
        draft?.effectivePhrases = stream.snapshot.phrases
        draft?.rawSpeakerPhrases = stream.snapshot.rawPhrases
        return draft
    }
}

struct LiveTranscriptWordEvidence: Codable, Sendable {
    struct Word: Codable, Sendable {
        var phraseID: UUID
        var session: UUID
        var source: LiveAudioSource
        var start: Double
        var end: Double
        var text: String
        var speakerID: UUID?
        var speakerLabel: String?
        var timed: Bool
        var recognitionFinal: Bool
    }
    var version = 1
    var meetingID: UUID
    var words: [Word]

    init(meetingID: UUID, phrases: [LiveTranscriptPhrase]) {
        self.meetingID = meetingID
        words = phrases.flatMap { phrase in
            let values =
                phrase.hasCompleteWordTiming
                ? phrase.words : [.init(text: phrase.text, start: phrase.start, end: phrase.end)]
            return values.map {
                Word(
                    phraseID: phrase.id, session: phrase.session, source: phrase.source,
                    start: $0.start, end: $0.end, text: $0.text,
                    speakerID: phrase.speakerIdentity,
                    speakerLabel: phrase.speakerIdentity == nil ? nil : phrase.diarizationLabel,
                    timed: phrase.hasCompleteWordTiming, recognitionFinal: phrase.recognitionIsFinal)
            }
        }
    }
}
