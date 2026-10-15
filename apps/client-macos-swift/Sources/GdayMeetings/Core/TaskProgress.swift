import CryptoKit
import Darwin
import Foundation

/// A phase's measured work. Elapsed time never advances the fraction or finishes a task.
struct TaskProgress: Codable, Equatable, Sendable {
    var phase: String
    var completed: Double? = nil
    var total: Double? = nil
    var unit: String? = nil
    var startedAt = Date()
    var estimatedRemainingSeconds: Double? = nil

    var fractionCompleted: Double? {
        guard let completed, let total, completed.isFinite, total.isFinite,
            completed >= 0, total > 0
        else { return nil }
        return min(completed / total, 1)
    }

    var remainingTimeText: String? {
        guard let seconds = estimatedRemainingSeconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 60 { return "Less than a minute remaining in this step" }
        let minutes = ceil(seconds / 60)
        if minutes < 60 { return "About \(Int(minutes)) \(minutes == 1 ? "minute" : "minutes") remaining in this step" }
        let hours = min(ceil(seconds / 3600), 999_999)
        return "About \(Int(hours)) \(hours == 1 ? "hour" : "hours") remaining in this step"
    }
}

struct TaskPerformanceKey: Hashable, Sendable {
    let digest: String

    init(operation: String, provider: String, model: String, configuration: String = "") {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let hardware = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let process = ProcessInfo.processInfo
        let components = [
            operation, provider, model, configuration, hardware,
            String(process.processorCount), String(process.physicalMemory), process.operatingSystemVersionString,
        ]
        // Length prefixes keep different combinations distinct without retaining provider identifiers.
        let value = components.map { "\($0.utf8.count):\($0)" }.joined()
        digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Disposable local performance data, independent of provider settings and recovery journals.
@MainActor final class TaskPerformanceCache {
    private struct Sample: Codable {
        var secondsPerUnit: Double
        var date: Date
    }
    private struct Archive: Codable {
        var version = 1
        var samples: [String: [Sample]] = [:]
    }
    private var archive = Archive()
    private let url: URL
    private let writer = DispatchQueue(label: "gday.task-performance-cache", qos: .utility)

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Archive.self, from: data),
            saved.version == 1
        {
            archive = saved
        }
    }

    func estimate(key: TaskPerformanceKey, remainingUnits: Double, now: Date = Date()) -> Double? {
        guard remainingUnits.isFinite, remainingUnits > 0 else { return nil }
        let rates = (archive.samples[key.digest] ?? []).filter {
            $0.secondsPerUnit.isFinite && $0.secondsPerUnit > 0
                && now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) < 30 * 86400
        }.map(\.secondsPerUnit).sorted()
        guard !rates.isEmpty else { return nil }
        let median = rates[rates.count / 2]
        let estimate = median * remainingUnits
        return estimate.isFinite ? estimate : nil
    }

    func record(key: TaskPerformanceKey, completedUnits: Double, elapsedSeconds: Double, now: Date = Date()) {
        guard completedUnits.isFinite, completedUnits > 0, elapsedSeconds.isFinite, elapsedSeconds >= 0.25 else {
            return
        }
        let rate = elapsedSeconds / completedUnits
        guard rate.isFinite, rate > 0 else { return }
        var samples = archive.samples[key.digest] ?? []
        samples.append(Sample(secondsPerUnit: rate, date: now))
        archive.samples[key.digest] = Array(samples.suffix(9))
        if archive.samples.count > 128 {
            let oldest = archive.samples.min {
                ($0.value.last?.date ?? .distantPast) < ($1.value.last?.date ?? .distantPast)
            }
            if let oldest { archive.samples.removeValue(forKey: oldest.key) }
        }
        guard let data = try? JSONEncoder().encode(archive) else { return }
        let destination = url
        writer.async {
            do {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            catch {
                // Estimates are optional; a cache write must not fail the underlying task.
            }
        }
    }
}

extension MeetingStore {
    func taskProgressEstimate(key: TaskPerformanceKey, remainingUnits: Double) -> Double? {
        taskPerformanceCache.estimate(key: key, remainingUnits: remainingUnits)
    }

    /// Call only after a measured processing phase succeeds, never on queue, failure, or recovery paths.
    func reportTaskPerformance(key: TaskPerformanceKey, completedUnits: Double, elapsedSeconds: Double) {
        taskPerformanceCache.record(key: key, completedUnits: completedUnits, elapsedSeconds: elapsedSeconds)
    }
}
