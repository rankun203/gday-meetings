import AppKit
import Darwin
import Foundation

/// Measurement-only code copied into an isolated app; never compiled into the product.
enum StartupProbe {
    static let lock = NSLock()
    static let processStart: TimeInterval = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        return Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
    }()
    static func mark(_ name: String) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "GdayStartupReceipt") as? String else { return }
        let elapsed = (Date().timeIntervalSince1970 - processStart) * 1_000
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let record: [String: Any] = [
            "event": name, "process": getpid(), "milliseconds": elapsed,
            "peakRSSBytes": usage.ru_maxrss,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(10)
        lock.lock()
        defer { lock.unlock() }
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        catch {}
    }
    @MainActor static func windowAppeared() {
        mark("view-appeared")
        Task { @MainActor in
            for _ in 0..<1_000 {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                    window.contentView?.layoutSubtreeIfNeeded()
                    mark("window-visible-layout-complete")
                    return
                }
                try? await Task.sleep(for: .milliseconds(1))
            }
            mark("window-visibility-timeout")
        }
    }
}
