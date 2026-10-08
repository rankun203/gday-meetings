import Foundation

/// Preserve a first opportunity and a recent refresh per local voice, with FIFO
/// service across voices. Bounded PCM storage makes overload explicit.
struct LiveVoiceSampleQueue {
    struct Entry {
        var sample: LiveSpeakerAudioSample
        var token: UUID
    }
    private(set) var entries: [Entry] = []
    private(set) var lastOmitted: Entry?
    let capacity = 32
    mutating func enqueue(_ sample: LiveSpeakerAudioSample, token: UUID) -> Bool {
        lastOmitted = nil
        let matches = entries.indices.filter {
            entries[$0].sample.speakerID == sample.speakerID && entries[$0].token == token
        }
        if matches.count >= 2, let last = matches.last {
            lastOmitted = entries[last]
            entries[last] = .init(sample: sample, token: token)
            return true
        }
        guard entries.count < capacity else {
            lastOmitted = .init(sample: sample, token: token)
            return false
        }
        entries.append(.init(sample: sample, token: token))
        return true
    }
    mutating func pop() -> Entry? { entries.isEmpty ? nil : entries.removeFirst() }
    mutating func removeAll() {
        entries.removeAll()
        lastOmitted = nil
    }
}
