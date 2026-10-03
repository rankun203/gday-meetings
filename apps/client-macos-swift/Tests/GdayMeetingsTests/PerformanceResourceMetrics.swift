import AppKit
import Darwin
import Foundation

/// Process counters sampled on the main thread. Device attribution comes from Instruments.
struct PerformanceResourceSnapshot {
    let utc: Date
    let monotonicSeconds: Double
    let mainCPUSeconds: Double
    let processCPUSeconds: Double
    let physicalFootprintBytes: UInt64?
    let residentBytes: UInt64?
    let diskReadBytes: UInt64?
    let diskWriteBytes: UInt64?

    @MainActor static func capture() -> Self {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V2, $0)
            }
        }
        return Self(
            utc: Date(), monotonicSeconds: ProcessInfo.processInfo.systemUptime,
            mainCPUSeconds: RecordingPerformanceTests.threadCPU(),
            processCPUSeconds: RecordingPerformanceTests.processCPU(),
            physicalFootprintBytes: status == 0 ? usage.ri_phys_footprint : nil,
            residentBytes: status == 0 ? usage.ri_resident_size : nil,
            diskReadBytes: status == 0 ? usage.ri_diskio_bytesread : nil,
            diskWriteBytes: status == 0 ? usage.ri_diskio_byteswritten : nil)
    }
}

/// Shared, opt-in resource log for sequential capacity tests. Missing counters stay null.
@MainActor
final class PerformanceResourceMetrics {
    private let task: String
    private let mode: String
    private let runID: String
    private let initialBytes: Int
    private let cadenceHz: Double
    private let fragmentBytes: Int
    private let imageReferenceCount: Int?
    private let uniqueAssetPixels: Int?
    private let started: PerformanceResourceSnapshot
    private var previous: PerformanceResourceSnapshot
    private var peakFootprint: UInt64?
    private var output: FileHandle?
    private var pendingActions: [[String: Any]] = []
    private var bufferedLog = Data()
    private var loggingBytes = 0

    init(
        task: String, mode: String, initialPayload: String, cadenceHz: Double, fragmentBytes: Int,
        imageReferenceCount: Int? = nil, uniqueAssetPixels: Int? = nil
    ) throws {
        self.task = task
        self.mode = mode
        runID = Self.runID
        initialBytes = initialPayload.utf8.count
        self.cadenceHz = cadenceHz
        self.fragmentBytes = fragmentBytes
        self.imageReferenceCount = imageReferenceCount
        self.uniqueAssetPixels = uniqueAssetPixels
        started = .capture()
        previous = started
        peakFootprint = started.physicalFootprintBytes
        if let path = ProcessInfo.processInfo.environment["GDAY_PERFORMANCE_METRICS_PATH"] {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try output?.seekToEnd()
        }
    }

    deinit { try? output?.close() }

    private static let runID =
        ProcessInfo.processInfo.environment["GDAY_PERFORMANCE_RUN_ID"] ?? UUID().uuidString

    private static var preparedApplication = false

    /// SwiftPM's test host does not enter NSApplication.run(), which normally
    /// completes launch before processing events. Finish that lifecycle once.
    static func prepareApplication() {
        guard !preparedApplication else { return }
        preparedApplication = true
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
    }

    /// Open and settle the test window first, then let the external probe signal readiness.
    static func waitForStartGate(task: String, mode: String) throws {
        let ready: [String: Any] = [
            "schema_version": 1, "event": "ready", "task": task, "mode": mode,
            "run_id": runID, "pid": getpid(), "utc": timestamp(Date()),
        ]
        writeConsole(ready)
        guard let path = ProcessInfo.processInfo.environment["GDAY_PERFORMANCE_START_GATE"] else { return }
        let data = try JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path + ".ready.json"), options: .atomic)
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while !FileManager.default.fileExists(atPath: path) {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NSError(
                    domain: "PerformanceResourceMetrics", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The performance start gate did not open within 120 seconds."]
                )
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    @discardableResult
    func record(
        event: String = "sample", phase: String, payload: String,
        updates: Int, skipped: Int, insertedBytes: Int, actionDurationSeconds: Double? = nil,
        payloadUTF8Bytes: Int? = nil, payloadUTF16Units: Int? = nil, lineCount: Int? = nil
    ) throws -> PerformanceResourceSnapshot {
        let current = PerformanceResourceSnapshot.capture()
        if let footprint = current.physicalFootprintBytes {
            peakFootprint = max(peakFootprint ?? footprint, footprint)
        }
        func number<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        func difference(_ value: UInt64?, _ reference: UInt64?) -> UInt64? {
            guard let value, let reference, value >= reference else { return nil }
            return value - reference
        }
        let fields: [String: Any] = [
            "schema_version": 1, "event": event, "run_id": runID, "task": task, "mode": mode,
            "build_revision": ProcessInfo.processInfo.environment["GDAY_PERFORMANCE_BUILD_REVISION"] ?? "unspecified",
            "pid": getpid(), "utc": Self.timestamp(current.utc),
            "monotonic_s": current.monotonicSeconds, "elapsed_s": current.monotonicSeconds - started.monotonicSeconds,
            "interval_s": current.monotonicSeconds - previous.monotonicSeconds, "phase": phase,
            "initial_payload_utf8_bytes": initialBytes,
            "actual_payload_utf8_bytes": payloadUTF8Bytes ?? payload.utf8.count,
            "actual_payload_utf16_units": payloadUTF16Units ?? payload.utf16.count,
            "lines": lineCount ?? payload.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 },
            "inserted_bytes": insertedBytes, "delivery_count": updates, "skipped_delivery_count": skipped,
            "cadence_hz": cadenceHz, "fragment_bytes": fragmentBytes,
            "action_duration_s": number(actionDurationSeconds),
            "image_reference_count": number(imageReferenceCount), "unique_asset_pixels": number(uniqueAssetPixels),
            "main_cpu_ns": Int64((current.mainCPUSeconds - started.mainCPUSeconds) * 1e9),
            "process_cpu_ns": Int64((current.processCPUSeconds - started.processCPUSeconds) * 1e9),
            "main_cpu_ns_delta": Int64((current.mainCPUSeconds - previous.mainCPUSeconds) * 1e9),
            "process_cpu_ns_delta": Int64((current.processCPUSeconds - previous.processCPUSeconds) * 1e9),
            "physical_footprint_bytes": number(current.physicalFootprintBytes),
            "resident_bytes": number(current.residentBytes), "sampled_peak_footprint_bytes": number(peakFootprint),
            "disk_read_bytes": number(difference(current.diskReadBytes, started.diskReadBytes)),
            "disk_write_bytes": number(difference(current.diskWriteBytes, started.diskWriteBytes)),
            "disk_read_bytes_delta": number(difference(current.diskReadBytes, previous.diskReadBytes)),
            "disk_write_bytes_delta": number(difference(current.diskWriteBytes, previous.diskWriteBytes)),
            "metrics_stdout_logical_bytes": loggingBytes, "disk_includes_stdout_logging": true,
            "metrics_file_flushed_after_final_snapshot": true,
            "gpu": NSNull(), "ane": NSNull(), "core_ml": NSNull(),
        ]
        try write(fields)
        previous = current
        return current
    }

    /// Operation duration includes the caller's stated boundary, not unmeasured input latency.
    func recordAction(name: String, startedAt: Date, durationSeconds: Double, payloadBytes: Int) throws {
        pendingActions.append([
            "schema_version": 1, "event": "action", "run_id": runID, "task": task, "mode": mode,
            "pid": getpid(), "utc": Self.timestamp(startedAt),
            "elapsed_s": startedAt.timeIntervalSince(started.utc), "action": name,
            "action_duration_s": durationSeconds, "actual_payload_utf8_bytes": payloadBytes,
        ])
    }

    private func write(_ fields: [String: Any]) throws {
        var console = Data()
        for item in pendingActions + [fields] {
            let line = try JSONSerialization.data(withJSONObject: item, options: [.sortedKeys])
            if output != nil {
                bufferedLog.append(line)
                bufferedLog.append(10)
            }
            console.append(Data("PERF_RESOURCE ".utf8))
            console.append(line)
            console.append(10)
        }
        try FileHandle.standardOutput.write(contentsOf: console)
        loggingBytes += console.count
        pendingActions.removeAll(keepingCapacity: true)
        if fields["event"] as? String == "end", let output {
            try output.write(contentsOf: bufferedLog)
            bufferedLog.removeAll()
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func writeConsole(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return }
        print("PERF_RESOURCE \(text)")
        fflush(stdout)
    }
}
