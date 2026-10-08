import Foundation

/// Saved rows already record whether a label describes an audio source.
/// Repairing source labels does not need to reopen the recording checkpoint.
@MainActor final class LiveSourcePlaceholderRecovery {
    var tasks: [UUID: Task<Void, Never>] = [:]
    var resolve: @Sendable (Meeting) async -> [UUID: LiveAudioSource] = { meeting in
        await Task.detached(priority: .utility) { LiveSourcePlaceholderRecovery.sources(in: meeting) }.value
    }

    nonisolated static func sources(in meeting: Meeting) -> [UUID: LiveAudioSource] {
        let missing = Set(meeting.speakers.filter { $0.sourcePlaceholder == nil }.map(\.id))
        guard !missing.isEmpty else { return [:] }
        var sources: [UUID: LiveAudioSource] = [:]
        for row in meeting.transcript where row.sourcePlaceholder == true && missing.contains(row.id) {
            guard !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sources[row.id] = row.source ?? .system
        }
        return sources
    }

    nonisolated static func matchingSpeakerMetadata(_ current: [MeetingSpeaker], _ expected: [MeetingSpeaker]) -> Bool {
        guard current.count == expected.count else { return false }
        for (speaker, baseline) in zip(current, expected) {
            var value = speaker
            // An unrelated save can allocate colors. Color does not determine attribution.
            value.colorSlot = baseline.colorSlot
            guard value == baseline else { return false }
        }
        return true
    }
}

extension MeetingStore {
    func scheduleLiveSourcePlaceholderRecovery(_ snapshot: Meeting) {
        guard libraryWritable, snapshot.liveTranscriptAdopted, recordingID != snapshot.id,
            snapshot.speakers.contains(where: { $0.sourcePlaceholder == nil }),
            liveSourceRecovery.tasks[snapshot.id] == nil
        else { return }
        let generation = externalReloadGeneration
        let resolve = liveSourceRecovery.resolve
        liveSourceRecovery.tasks[snapshot.id] = Task { [weak self] in
            let sources = await resolve(snapshot)
            guard let self else { return }
            defer { liveSourceRecovery.tasks.removeValue(forKey: snapshot.id) }
            guard !sources.isEmpty, !Task.isCancelled else { return }
            _ = await commitSourcePlaceholderRecovery(sources, expected: snapshot, generation: generation)
        }
    }
}
