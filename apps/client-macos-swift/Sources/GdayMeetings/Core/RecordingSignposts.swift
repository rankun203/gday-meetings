import os

/// Fixed operation names identify work without including meeting content or identifiers.
/// These intervals appear in Instruments Points of Interest, independently of Core ML events.
enum RecordingSignposts {
    static let signposter = OSSignposter(subsystem: "com.gdaymeetings.macos", category: .pointsOfInterest)
}
