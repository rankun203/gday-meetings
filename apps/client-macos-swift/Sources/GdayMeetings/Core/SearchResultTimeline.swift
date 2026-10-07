import Foundation

/// A static source interval, independent of playback state.
struct SearchResultTimeline: Equatable, Sendable {
    let duration: Double
    let start: Double
    let end: Double

    init?(duration: Double, start: Double, end: Double) {
        guard duration.isFinite, duration > 0, start.isFinite, end.isFinite,
            start >= 0, end > start, start < duration
        else { return nil }
        self.duration = duration
        self.start = start
        self.end = min(end, duration)
    }

    var startFraction: Double { start / duration }
    var endFraction: Double { end / duration }
}

extension SearchDisplayResult {
    var playbackStart: Double? {
        if passage?.kind == .title { return 0 }
        return passage?.start ?? audio?.start
    }

    func timeline(duration: Double) -> SearchResultTimeline? {
        if passage?.kind == .title {
            return SearchResultTimeline(duration: duration, start: 0, end: duration)
        }
        if let audio {
            return SearchResultTimeline(duration: duration, start: audio.start, end: audio.start + audio.duration)
        }
        guard let start = passage?.start,
            let end = passage?.end
        else { return nil }
        return SearchResultTimeline(duration: duration, start: start, end: end)
    }
}
