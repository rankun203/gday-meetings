import AppKit
import Foundation
import SwiftUI
import Testing

@testable import GdayMeetings

/// A controlled publication experiment, not a provider or input-latency benchmark.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GDAY_PERFORMANCE"] == "1"))
struct SummaryPerformanceTests {
    /// Seed size changes between processes; fragment size and delivery cadence stay fixed.
    @Test func summaryCapacity() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GDAY_SUMMARY_CAPACITY"] == "1" else { return }
        let initialBytes = Int(environment["GDAY_SUMMARY_INITIAL_BYTES"] ?? "10240") ?? 10240
        let mode = environment["GDAY_SUMMARY_MODE"] ?? "visible"
        guard (1024...512_000).contains(initialBytes), ["visible", "hidden"].contains(mode) else {
            throw NSError(
                domain: "SummaryCapacity", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid capacity configuration."])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-summary-capacity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        PerformanceResourceMetrics.prepareApplication()
        let store = MeetingStore(dataDirectory: directory)
        for index in 0..<26 { store.createMeeting(title: "Synthetic meeting \(index)") }
        let id = store.meetings[0].id
        let playback = MeetingPlayback()
        let fragment =
            "- Review the synthetic release plan, confirm the next action, and update the shared notes. 会议记录 e\u{301} 🙂 Keep the outcome clear.\n"
        let repetitions = max(1, (initialBytes + fragment.utf8.count - 1) / fragment.utf8.count)
        var payload = "# Summary\n\n" + String(repeating: fragment, count: repetitions)
        let seededBytes = payload.utf8.count
        let seededUTF16 = payload.utf16.count
        let seededLines = payload.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let fragmentBytes = fragment.utf8.count
        let fragmentUTF16 = fragment.utf16.count
        store.summaryDrafts.values[id] = payload
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Synthetic Summary Capacity"
        window.isReleasedWhenClosed = false
        defer { window.close() }
        if mode == "visible" {
            window.contentView = NSHostingView(
                rootView: SummaryCapacityDocument(drafts: store.summaryDrafts, meetingID: id)
                    .environmentObject(store).environmentObject(playback))
        }
        else {
            window.contentView = NSHostingView(
                rootView: LibraryView(selectedMeetingID: id).environmentObject(store).environmentObject(playback))
        }
        window.orderFront(nil)
        _ = RecordingPerformanceTests.run(seconds: 1, rate: 0, window: window) { _ in }
        try PerformanceResourceMetrics.waitForStartGate(task: "summary", mode: mode)
        let metrics = try PerformanceResourceMetrics(
            task: "summary", mode: mode, initialPayload: payload, cadenceHz: 10, fragmentBytes: fragment.utf8.count)
        try metrics.record(event: "begin", phase: "grow", payload: payload, updates: 0, skipped: 0, insertedBytes: 0)
        let started = ProcessInfo.processInfo.systemUptime
        var updates = 0
        var skipped = 0
        var nextSlot = 0
        var nextSample = 1.0
        var phase = "grow"
        var stopped = false

        while ProcessInfo.processInfo.systemUptime - started < 30 {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed >= 25, phase != "hold" {
                phase = "hold"
                skipped = max(skipped, 250 - updates)
                try metrics.record(
                    event: "phase", phase: phase, payload: payload, updates: updates, skipped: skipped,
                    insertedBytes: updates * fragmentBytes,
                    payloadUTF8Bytes: seededBytes + updates * fragmentBytes,
                    payloadUTF16Units: seededUTF16 + updates * fragmentUTF16, lineCount: seededLines + updates)
            }
            if elapsed < 25 {
                let slot = Int(elapsed * 10)
                if slot >= nextSlot {
                    skipped += max(0, slot - nextSlot)
                    nextSlot = slot + 1
                    let actionUTC = Date()
                    let actionStarted = ProcessInfo.processInfo.systemUptime
                    payload += fragment
                    store.summaryDrafts.values[id] = payload
                    RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let duration = ProcessInfo.processInfo.systemUptime - actionStarted
                    updates += 1
                    try metrics.recordAction(
                        name: "publish_and_layout", startedAt: actionUTC, durationSeconds: duration,
                        payloadBytes: seededBytes + updates * fragmentBytes)
                    if duration > 2 {
                        stopped = true
                        break
                    }
                }
            }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.004))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if ProcessInfo.processInfo.systemUptime - started >= nextSample {
                let sample = try metrics.record(
                    phase: phase, payload: payload, updates: updates, skipped: skipped,
                    insertedBytes: updates * fragmentBytes,
                    payloadUTF8Bytes: seededBytes + updates * fragmentBytes,
                    payloadUTF16Units: seededUTF16 + updates * fragmentUTF16, lineCount: seededLines + updates)
                nextSample = floor(ProcessInfo.processInfo.systemUptime - started) + 1
                if let footprint = sample.physicalFootprintBytes, footprint > 2 * 1024 * 1024 * 1024 {
                    stopped = true
                    break
                }
            }
            if ProcessInfo.processInfo.systemUptime - started > 45 {
                stopped = true
                break
            }
        }
        try metrics.record(
            event: "end", phase: stopped ? "safety_stop" : "complete", payload: payload,
            updates: updates, skipped: skipped, insertedBytes: updates * fragmentBytes,
            payloadUTF8Bytes: seededBytes + updates * fragmentBytes,
            payloadUTF16Units: seededUTF16 + updates * fragmentUTF16, lineCount: seededLines + updates)
    }

    @Test func hiddenSummaryPublication() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-summary-perf-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        for index in 0..<26 { store.createMeeting(title: "Synthetic meeting \(index)") }
        let id = store.meetings[0].id
        let playback = MeetingPlayback()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(
            rootView: LibraryView(selectedMeetingID: id).environmentObject(store).environmentObject(playback))
        _ = RecordingPerformanceTests.run(seconds: 1, rate: 0, window: window) { _ in }
        let paragraph = "- Review the synthetic release checklist and record the next action.\n"

        // Alternate order to reduce warm-up bias. Both conditions use the same
        // draft text, window, cadence, and forced layout/drawing. The broadcast
        // condition restores the store notification removed by the repair.
        for repetition in 0..<3 {
            for broadcasts in (repetition.isMultiple(of: 2) ? [false, true] : [true, false]) {
                store.summaryDrafts.values[id] = ""
                _ = RecordingPerformanceTests.run(seconds: 0.3, rate: 0, window: window) { _ in }
                let usage = RecordingPerformanceTests.run(seconds: 4, rate: 10, window: window) { index in
                    if broadcasts { store.objectWillChange.send() }
                    store.summaryDrafts.values[id] = "# Summary\n\n" + String(repeating: paragraph, count: index + 1)
                }
                RecordingPerformanceTests.report(
                    "hidden Summary \(broadcasts ? "library broadcast" : "document only") repeat \(repetition + 1)",
                    usage)
            }
        }
    }
}

private struct SummaryCapacityDocument: View {
    @ObservedObject var drafts: SummaryDraftState
    let meetingID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Summary").font(.headline)
            MeetingMarkdownReadingView(
                meetingID: meetingID, markdown: drafts.values[meetingID] ?? "", showsTimestamps: false,
                emptyMessage: "Writing summary…"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.padding(20)
    }
}
