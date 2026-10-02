import Foundation

/// Input discontinuities use recording time. Converted buffers use a continuous
/// sample cursor so resampler carry does not look like a capture gap.
struct LiveAudioInputTimeline {
    static let gapTolerance = 1.0 / 16_000 + 0.000_001

    static func hasGap(from end: Double, to start: Double) -> Bool {
        end.isFinite && start.isFinite && start - end > gapTolerance
    }

    private(set) var previousEnd: Double
    private var origin: Double?
    private var outputFrame: Int64?

    init(boundary: Double) {
        previousEnd = boundary.isFinite && boundary >= 0 ? boundary : 0
    }

    /// Call before conversion, including for packets that produce no output yet.
    /// Capture already trims overlapping input; a stale packet cannot rewind time.
    mutating func receive(start: Double, duration: Double) -> Bool {
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0,
            (start + duration).isFinite
        else { return false }
        let gap = Self.hasGap(from: previousEnd, to: start)
        if gap {
            origin = start
            outputFrame = nil
        }
        else if origin == nil {
            origin = start
        }
        previousEnd = max(previousEnd, start + duration)
        return gap
    }

    mutating func convertedStart(frameCount: Int, sampleRate: Double) -> Int64? {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0, let origin else { return nil }
        let initialFrame = (origin * sampleRate).rounded()
        guard initialFrame.isFinite, initialFrame >= 0, initialFrame < Double(Int64.max) else { return nil }
        let start = outputFrame ?? Int64(initialFrame)
        let (end, overflow) = start.addingReportingOverflow(Int64(frameCount))
        guard !overflow else { return nil }
        outputFrame = end
        return start
    }
}
