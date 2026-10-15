import Foundation

/// Reconcile a recording command against its saved baseline without replacing unrelated edits.
enum RecordingMeetingMerge {
    static func merge(baseline: Meeting, proposed: Meeting, disk: Meeting, preferProposedOnConflict: Bool = false)
        throws -> Meeting
    {
        guard baseline.id == proposed.id, disk.id == proposed.id else {
            throw MeetingError.message("The recording’s meeting changed. Its saved files were kept.")
        }
        var result = disk
        func merge<Value: Equatable>(_ key: WritableKeyPath<Meeting, Value>) throws {
            guard proposed[keyPath: key] != baseline[keyPath: key] else { return }
            guard
                preferProposedOnConflict || disk[keyPath: key] == baseline[keyPath: key]
                    || disk[keyPath: key] == proposed[keyPath: key]
            else {
                throw MeetingError.message(
                    "The same meeting information changed on disk. The recording’s saved files were kept.")
            }
            result[keyPath: key] = proposed[keyPath: key]
        }
        try merge(\.title)
        try merge(\.language)
        try merge(\.createdAt)
        try merge(\.duration)
        try merge(\.summary)
        try merge(\.tagIDs)
        try merge(\.chat)
        try merge(\.todos)
        // Audio files and their profile describe one artifact and must agree.
        let localAudioChanged =
            proposed.audioFiles != baseline.audioFiles || proposed.recordingProfile != baseline.recordingProfile
        let diskAudioChanged =
            disk.audioFiles != baseline.audioFiles || disk.recordingProfile != baseline.recordingProfile
        if !preferProposedOnConflict && localAudioChanged && diskAudioChanged
            && (proposed.audioFiles != disk.audioFiles || proposed.recordingProfile != disk.recordingProfile)
        {
            throw MeetingError.message("The recording’s audio information changed on disk. Its saved files were kept.")
        }
        if preferProposedOnConflict && localAudioChanged && diskAudioChanged {
            result.audioFiles = proposed.audioFiles
            result.recordingProfile = proposed.recordingProfile
        }
        try merge(\.audioFiles)
        try merge(\.recordingProfile)
        func sameTranscript(_ lhs: Meeting, _ rhs: Meeting) -> Bool {
            lhs.transcript == rhs.transcript && lhs.transcriptSource == rhs.transcriptSource
                && lhs.speakerLabelSource == rhs.speakerLabelSource && lhs.speakers == rhs.speakers
                && lhs.liveTranscriptAdopted == rhs.liveTranscriptAdopted && lhs.personIDs == rhs.personIDs
        }
        if !preferProposedOnConflict && !sameTranscript(proposed, baseline) && !sameTranscript(disk, baseline)
            && !sameTranscript(proposed, disk)
        {
            throw MeetingError.message(
                "The recording’s transcript information changed on disk. Its saved files were kept.")
        }
        if preferProposedOnConflict && !sameTranscript(proposed, baseline) && !sameTranscript(disk, baseline) {
            result.transcript = proposed.transcript
            result.transcriptSource = proposed.transcriptSource
            result.speakerLabelSource = proposed.speakerLabelSource
            result.liveTranscriptAdopted = proposed.liveTranscriptAdopted
            result.speakers = proposed.speakers
            result.personIDs = proposed.personIDs
        }
        try merge(\.transcript)
        try merge(\.transcriptSource)
        try merge(\.speakerLabelSource)
        try merge(\.liveTranscriptAdopted)
        try merge(\.speakers)
        try merge(\.personIDs)
        try merge(\.transcriptionAttempt)
        for kind in Set(proposed.completedTaskIDs.keys).union(baseline.completedTaskIDs.keys) {
            let receipt = proposed.completedTaskIDs[kind]
            guard baseline.completedTaskIDs[kind] != receipt else { continue }
            guard
                preferProposedOnConflict || disk.completedTaskIDs[kind] == baseline.completedTaskIDs[kind]
                    || disk.completedTaskIDs[kind] == receipt
            else {
                throw MeetingError.message(
                    "The recording’s processing information changed on disk. Its saved files were kept.")
            }
            result.completedTaskIDs[kind] = receipt
        }
        // Markdown has its own save and conflict-copy protocol.
        result.notes = proposed.notes
        return result
    }
}
