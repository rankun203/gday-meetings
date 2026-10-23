import Foundation

/// Default instructions match Rust's chat/summarize.rs build_system_prompt.
enum SummaryPrompt {
    static let defaultInstructions = """
        You are a meeting summarizer. Given a transcript, produce a structured summary. Do not insert opinions — state the facts. Follow the same language as the session.

        ## Output format

        # {Title}

        {One sentence description}, meeting duration.

        ## Attendees

        - {Name 1}
        - {Name 2}

        ## TODO

        - [ ] **{Owner 1}**: ...
        - [ ] **{Owner 2}**: ...

        ## {Topic 1}

        {list down opinions of each attendee}

        {conclusion}

        ## {Topic 2}

        ...

        ## Rules

        - Include a TODO section with action items and owners near the top, right after attendees. If there are no action items, write "No action items."
        - Use markdown checkbox syntax: `- [ ] **Owner**: task description` (incomplete) or `- [x] **Owner**: task description` (completed). One item per owner; if ambiguous, assign to the most likely owner; if shared, create separate items per person.
        - Cite every key point, decision, action item, or claim with an inline [MM:SS] timestamp from the transcript. Always add a space before the first timestamp: `text [12:45]` not `text[12:45]`. Chain multiple: [12:45][15:20].
        - When using an attached Notes image, cite it with a descriptive Markdown link using its supplied assets/ path. Do not embed the image in the summary or invent image paths.
        - When providing Chinese content, add a space between Chinese characters and English letters or Arabic numerals.
        """

    static func messages(
        provider: ServiceProvider, meeting: Meeting, people: [Person], now: Date = Date(), instructions: String? = nil
    ) -> [LLMMessage] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd HH:mm z"
        var system =
            provider.summaryPrompt + "\n\nLanguage: \(meeting.language)\nCurrent time: \(formatter.string(from: now))"
        if let instructions = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !instructions.isEmpty {
            system += "\n\n## User Instructions\n\n"
            system +=
                "For this summary, these instructions take precedence over the default language and format above.\n\n"
            system += instructions
        }
        let participantIDs = Set(meeting.associatedPersonIDs)
        let speakersByID = Dictionary(meeting.speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let associatedSpeakers = meeting.transcript.compactMap { segment -> MeetingSpeaker? in
            guard let id = segment.speakerID, let speaker = speakersByID[id],
                segment.allowsPersonAssociation(from: speaker)
            else { return nil }
            return speaker
        }
        let certainParticipantIDs = Set(MeetingListEntry(meeting).personIDs)
        let participants = people.filter { participantIDs.contains($0.id) }
        let participantNames = Dictionary(
            uniqueKeysWithValues: participants.map {
                ($0.id, certainParticipantIDs.contains($0.id) ? $0.name : "\($0.name) ?")
            })
        let sourceLabels = Set(
            meeting.transcript.compactMap { segment -> String? in
                let speaker = segment.speakerID.flatMap { speakersByID[$0] }
                if segment.allowsPersonAssociation(from: speaker),
                    let personID = speaker?.personID, participantNames[personID] != nil
                {
                    return nil
                }
                let name = meeting.speakerName(for: segment, people: people, tentativeNameSuffix: " ?")
                guard !name.isEmpty,
                    segment.sourcePlaceholder == true || speaker?.sourcePlaceholder != nil
                        || ["sys", "mic"].contains(name.lowercased())
                else { return nil }
                return name
            })
        let unnamedTranscriptLabels = meeting.transcript.compactMap { segment -> String? in
            if let id = segment.speakerID, let speaker = speakersByID[id],
                segment.allowsPersonAssociation(from: speaker),
                let personID = speaker.personID, participantNames[personID] != nil
            {
                return nil
            }
            let name = meeting.speakerName(for: segment, people: people, tentativeNameSuffix: " ?")
            return name.isEmpty || sourceLabels.contains(name) ? nil : name
        }
        let names = Set(unnamedTranscriptLabels + participantNames.values)
        let duration = max(0, Int(meeting.duration))
        var context = "Here is the meeting transcript:\n\nMeeting info\nMeeting: \(meeting.title)\n"
        context +=
            "Started: \(formatter.string(from: meeting.createdAt))\nDuration: \(duration / 60)m \(duration % 60)s\n"
        if !names.isEmpty { context += "Participants: \(names.sorted().joined(separator: ", "))\n" }
        if !sourceLabels.isEmpty {
            context +=
                "\nUnidentified-speaker labels (\(sourceLabels.sorted().joined(separator: ", "))) mark speech without a recognized person. `sys` means system audio; `mic` means microphone audio. Each source can contain several people; these labels are not participant names. Infer a speaker from surrounding lines only when the context supports it. Keep the speaker unidentified or state uncertainty when the evidence is insufficient.\n"
        }
        if associatedSpeakers.contains(where: {
            $0.voiceReviewOrigin?.transcriptAssociationTier == .tentative
                && $0.personID.map { participantNames[$0] != nil } == true
        }) {
            context +=
                "\nA name followed by `?` is a low-confidence speaker association. Include these participants and preserve `?` whenever attributing speech or actions to them.\n"
        }
        if !meeting.notes.isEmpty { context += "\nSession notes\n\(NotesDocument(meeting.notes).citedText)\n" }
        let participantNotes = participants.filter { !$0.notes.isEmpty }
        if !participantNotes.isEmpty {
            context +=
                "\nParticipant notes\n"
                + participantNotes.map { "\(participantNames[$0.id] ?? $0.name): \($0.notes)" }.joined(separator: "\n")
                + "\n"
        }
        // Meeting tags currently have no notes field.
        context += "\nASR disclaimer\n"
        context += "This transcript was generated by automatic speech recognition (ASR). "
        context += "Names and words may be mis-recognized, especially those marked as low confidence. "
        context +=
            "If a mis-recognized word sounds similar to a known participant or term (e.g. from the notes above), it likely refers to that person or term — use the correct one in the summary, and on its first occurrence put the original ASR word in parentheses, e.g. `CorrectTerm (original-asr-word)`.\n"
        context += "\nTranscript\n"
        context += meeting.transcript.map { segment in
            let seconds = max(0, Int(segment.start))
            let timestamp = String(format: "[%02d:%02d]", seconds / 60, seconds % 60)
            let name = meeting.speakerName(for: segment, people: people, tentativeNameSuffix: " ?")
            return "\(timestamp) \(name.isEmpty ? "" : name + ": ")\(segment.text)"
        }.joined(separator: "\n")
        return [.init(role: "system", content: system), .init(role: "user", content: context)]
    }
}
