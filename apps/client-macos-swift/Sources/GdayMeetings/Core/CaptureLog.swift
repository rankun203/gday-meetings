import AVFoundation
import OSLog

/// Recording diagnostics in the unified log. Log decisions and state changes
/// only: never per buffer, never audio content, and no personal data beyond
/// device names. Read live with
/// `log stream --level info --predicate 'subsystem == "com.gdaymeetings.macos"'`.
enum CaptureLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.gdaymeetings.macos"
    /// Source setup, device binding, formats, voice processing, and triggers.
    static let capture = Logger(subsystem: subsystem, category: "capture")
    /// Library reads and disposable index reconciliation.
    static let library = Logger(subsystem: subsystem, category: "library")
    /// Rebuild scheduling, attempts, backoff, and the loop guard.
    static let recovery = Logger(subsystem: subsystem, category: "recovery")

    /// A format as "48000 Hz 1 ch" for log lines.
    static func describe(_ format: AVAudioFormat?) -> String {
        guard let format else { return "none" }
        return "\(Int(format.sampleRate)) Hz \(format.channelCount) ch"
    }
}

/// Saves this app run's diagnostics (capture, recovery, and network transmission
/// entries) to a text file for support. `OSLogStore` scoped to the current process
/// needs no entitlement, so only entries from this run are available; earlier runs
/// need `log show`.
enum LogExport {
    /// All of this app's categories, including `network` (see `NetworkLog`), plus
    /// AVAudioEngine's (engine start, stop, configuration changes, and format
    /// mismatches). Core Audio's HAL entries are too verbose.
    static let subsystems = [CaptureLog.subsystem, "com.apple.avfaudio"]

    static func export(since start: Date, to directory: URL) throws -> URL {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "subsystem IN %@", subsystems)
        let entries = try store.getEntries(at: store.position(date: start), matching: predicate)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            lines.append(
                "\(formatter.string(from: entry.date)) [\(entry.subsystem):\(entry.category)] \(entry.level.label) \(entry.composedMessage)"
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("gday-meetings-log-\(stamp).txt")
        let header = "Gday Meetings log from \(formatter.string(from: start)); \(lines.count) entries.\n"
        try (header + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// ~/Library/Logs/Gday Meetings, where Console also lists log files.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Logs/Gday Meetings", isDirectory: true)
    }
}

extension OSLogEntryLog.Level {
    fileprivate var label: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "log"
        }
    }
}
