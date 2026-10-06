import AppKit
import Foundation
import Testing

@testable import GdayMeetings

struct NativeSearchLayoutTests {
    @Test @MainActor func measureNativeTableLayout() throws {
        guard let path = ProcessInfo.processInfo.environment["GDAY_NATIVE_LAYOUT_OUTPUT"] else {
            return
        }
        precondition(path.contains("/experiments/search-index-scale/runs/native/"))
        _ = NSApplication.shared
        var samples: [[String: Double]] = []
        for repetition in 0..<6 {
            // Rotate order so one count does not always receive first-use framework costs.
            let limits = [10, 20, 50, 100]
            for offset in 0..<4 {
                let count = limits[(offset + repetition) % 4]
                var sample = autoreleasepool { nativeMeasureSearchTableLayout(count: count) }
                #expect(sample["tableRows"] == Double(count))
                #expect(sample["materializedCells"]! > 0)
                sample["repetition"] = Double(repetition)
                samples.append(sample)
            }
        }
        let report: [String: Any] = [
            "scope":
                "Production native results table in an offscreen window; host construction and synchronous layout only, not visible presentation or display scanout",
            "providerRetrievalIncluded": false, "queryEmbeddingIncluded": false,
            "coordinatorCapBypassedForMeasurement": true,
            "samples": samples,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path))
    }
}
