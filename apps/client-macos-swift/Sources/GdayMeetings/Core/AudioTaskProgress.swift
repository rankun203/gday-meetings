import AVFoundation
import Foundation

/// Successful inference measurements exclude model preparation and audio conversion.
struct AudioTaskProgress: Sendable {
    var details: TaskProgress
    var processedAudioSeconds: Double?
    var processingSeconds: Double?

    init(_ details: TaskProgress, processedAudioSeconds: Double? = nil, processingSeconds: Double? = nil) {
        self.details = details
        self.processedAudioSeconds = processedAudioSeconds
        self.processingSeconds = processingSeconds
    }

    static func elapsed(since start: SuspendingClock.Instant) -> Double {
        let parts = start.duration(to: SuspendingClock.now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func durations(_ files: [URL]) throws -> [Double] {
        try files.map { file in
            let duration: Double
            if ["opus", "ogg"].contains(file.pathExtension.lowercased()) {
                duration = Double(try OpusFileDecoder(file).totalFrames) / StreamingAudioReader.sampleRate
            }
            else {
                let audio = try AVAudioFile(forReading: file)
                duration = Double(audio.length) / audio.processingFormat.sampleRate
            }
            guard duration.isFinite, duration >= 0 else { throw ServiceError("Couldn’t read the audio duration.") }
            return duration
        }
    }
}

/// Serializes synchronous framework callbacks without a task per progress update.
struct AudioProgressChannel: Sendable {
    let continuation: AsyncStream<TaskProgress>.Continuation
    private let consumer: Task<Void, Never>

    init(report: (@Sendable (AudioTaskProgress) async -> Void)?) {
        let pair = AsyncStream<TaskProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        consumer = Task {
            for await details in pair.stream {
                guard !Task.isCancelled else { break }
                await report?(AudioTaskProgress(details))
            }
        }
    }

    func finish() async {
        continuation.finish()
        await consumer.value
    }
}

extension MeetingStore {
    func reportAudioTaskProgress(
        _ update: AudioTaskProgress, kind: BackgroundJob.Kind, meetingID: UUID,
        key: TaskPerformanceKey, attemptID: UUID?
    ) {
        guard let attemptID, jobProgressAttemptID(kind, .meeting(meetingID)) == attemptID,
            isJobRunning(kind, .meeting(meetingID)), !Task.isCancelled
        else { return }
        var details = update.details
        if let completed = details.completed, let total = details.total, details.unit == "audio seconds" {
            details.estimatedRemainingSeconds = taskProgressEstimate(key: key, remainingUnits: total - completed)
        }
        setJobProgress(kind, .meeting(meetingID), details.phase, details: details, attemptID: attemptID)
    }
}

/// Samples stay in memory until the owning operation saves successfully.
actor AudioPerformanceMeasurement {
    private var units = 0.0
    private var seconds = 0.0

    func include(_ update: AudioTaskProgress) {
        guard let units = update.processedAudioSeconds, let seconds = update.processingSeconds,
            units.isFinite, seconds.isFinite, units > 0, seconds > 0
        else { return }
        self.units += units
        self.seconds += seconds
    }

    var sample: (units: Double, seconds: Double) { (units, seconds) }
}

extension MeetingStore {
    func commitAudioPerformance(
        _ measurement: AudioPerformanceMeasurement, kind: BackgroundJob.Kind, meetingID: UUID,
        key: TaskPerformanceKey, attemptID: UUID?
    ) async {
        let sample = await measurement.sample
        guard let attemptID, jobProgressAttemptID(kind, .meeting(meetingID)) == attemptID,
            isJobRunning(kind, .meeting(meetingID)), !Task.isCancelled
        else { return }
        reportTaskPerformance(key: key, completedUnits: sample.units, elapsedSeconds: sample.seconds)
    }
}
