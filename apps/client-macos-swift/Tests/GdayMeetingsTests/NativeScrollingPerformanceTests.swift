import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

/// Opt-in equal-work scrolling probe. These are callback/layout timings, not presented frames.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["GDAY_NATIVE_SCROLL_PERFORMANCE"] == "1"))
struct NativeScrollingPerformanceTests {
    @Test(arguments: [1000, 10000], ["idle", "playback", "live", "live-speakers"])
    func nativeScrolling(count: Int, mode: String) async throws {
        if let selected = ProcessInfo.processInfo.environment["GDAY_NATIVE_SCROLL_MODE"], selected != mode { return }
        PerformanceResourceMetrics.prepareApplication()
        let model = ScrollFixture(count: count, mode: mode)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let mounted = ProcessInfo.processInfo.systemUptime
        window.contentView = NSHostingView(rootView: ScrollFixtureView(model: model))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let firstLayout = ProcessInfo.processInfo.systemUptime - mounted
        // Warm layout and native caches before measuring the equal-work run.
        try await Task.sleep(for: .seconds(1))
        let scrolls = descendants(window.contentView!).compactMap { $0 as? NSScrollView }
        let meetingScroll = try #require(scrolls.first { $0.documentView is MeetingNativeTable })
        let transcriptScroll = try #require(scrolls.first { $0.documentView is TranscriptNativeTable })
        try PerformanceResourceMetrics.waitForStartGate(task: "native-scroll", mode: "\(mode)-\(count)")
        let metrics = try PerformanceResourceMetrics(
            task: "native-scroll", mode: "\(mode)-\(count)", initialPayload: "", cadenceHz: 60, fragmentBytes: 0)
        let started = ProcessInfo.processInfo.systemUptime
        var previous = started
        var intervals: [Double] = []
        var actions: [Double] = []
        var delivered = 0
        for tick in 0..<1800 {
            let deadline = started + Double(tick + 1) / 60
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - started < 90 else {
                Issue.record("Native scrolling exceeded its 90-second watchdog; equal work is incomplete.")
                return
            }
            intervals.append(now - previous)
            previous = now
            let actionStarted = now
            // Repeated traversal covers the full history with identical normalized positions.
            let phase = Double((tick + 1) % 600) / 600
            let position = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            for scroll in [meetingScroll, transcriptScroll] {
                (scroll as? TranscriptNativeScrollView)?.willScroll?()
                let extent = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: extent * position))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            if mode == "playback" {
                model.playback.progress.update(Double(count) * position)
                delivered += 1
            }
            if model.isLive, tick % 30 == 0 {
                model.appendLive(index: delivered)
                delivered += 1
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            actions.append(ProcessInfo.processInfo.systemUptime - actionStarted)
            if tick % 60 == 59 {
                try metrics.record(
                    phase: "scrolling", payload: "", updates: delivered, skipped: 0, insertedBytes: 0,
                    lineCount: count + (model.isLive ? delivered : 0))
            }
        }
        #expect(mode != "playback" || delivered == 1800)
        #expect(!model.isLive || delivered == 60)
        #expect(!model.isLive || model.stream.frozenCount + model.stream.hotFinalized.count == count + 60)
        try metrics.record(
            event: "end", phase: "complete", payload: "", updates: delivered, skipped: 0, insertedBytes: 0,
            lineCount: count + (model.isLive ? delivered : 0))
        func p95(_ values: [Double]) -> Double { values.sorted()[Int(Double(values.count - 1) * 0.95)] }
        let report: [String: Any] = [
            "measurement": "callback-and-synchronous-layout-proxy", "presented_frames_measured": false,
            "rows": count, "mode": mode, "operations": actions.count, "updates": delivered,
            "first_layout_s": firstLayout, "elapsed_s": ProcessInfo.processInfo.systemUptime - started,
            "callback_interval_p95_s": p95(intervals), "callback_interval_max_s": intervals.max() ?? 0,
            "callback_gaps_over_100ms": intervals.filter { $0 > 0.1 }.count,
            "layout_action_p95_s": p95(actions), "layout_action_max_s": actions.max() ?? 0,
            "layout_actions_over_100ms": actions.filter { $0 > 0.1 }.count,
            "display_refresh_hz": window.screen?.maximumFramesPerSecond ?? 0,
            "revision": ProcessInfo.processInfo.environment["GDAY_PERFORMANCE_BUILD_REVISION"] ?? "unspecified",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("PERF_NATIVE_SCROLL " + String(decoding: data, as: UTF8.self))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@MainActor private final class ScrollFixture: ObservableObject {
    let entries: [MeetingListEntry]
    let rows: [TranscriptDisplayRow]
    let playback = MeetingPlayback()
    let meeting = Meeting(title: "Synthetic scrolling fixture")
    let stream = LiveTranscriptStream()
    let liveRows = LiveTranscriptStreamDisplayCache()
    let session = UUID()
    let mode: String
    var isLive: Bool { mode == "live" || mode == "live-speakers" }
    @Published var revision = 1
    @Published var selection: UUID?

    init(count: Int, mode: String) {
        self.mode = mode
        entries = (0..<count).map { index in
            var meeting = Meeting(title: "Synthetic meeting \(index)")
            meeting.summary = "Summary \(index)"
            return MeetingListEntry(meeting)
        }
        rows = (0..<count).map { index in
            TranscriptDisplayRow(
                id: UUID(), start: Double(index), end: Double(index) + 2,
                speaker: index.isMultiple(of: 2) ? "Speaker A" : "Speaker B", speakerID: nil,
                text: "Synthetic passage \(index). This text checks wrapping and scrolling across a long transcript.")
        }
        if mode == "playback" { playback.select(meeting: meeting, files: []) }
        if isLive {
            stream.reset(labeling: mode == "live-speakers")
            for index in 0..<count { acceptLive(index: index) }
            refreshLive()
        }
    }

    func appendLive(index: Int) {
        if mode == "live-speakers" {
            let start = Double(rows.count + index) * 3
            let source: LiveAudioSource = index.isMultiple(of: 2) ? .microphone : .system
            let generation = UUID()
            let speakers = (0..<8).map {
                LiveSpeakerIdentity(
                    id: UUID(), source: source, generation: generation, slot: $0,
                    model: "synthetic", revision: "1")
            }
            stream.accept(
                .init(
                    source: source, generation: generation, sequence: 0, speakers: speakers,
                    intervals: [.init(speakerID: speakers[0].id, start: start, end: start + 2)],
                    start: start, end: start + 2))
            stream.accept(
                .init(source: source, start: start + 2, end: start + 3, reason: "Synthetic labeling gap"))
        }
        acceptLive(index: rows.count + index)
        refreshLive()
    }
    private func acceptLive(index: Int) {
        stream.accept(
            .init(
                session: session, source: index.isMultiple(of: 2) ? .microphone : .system,
                start: Double(index) * (mode == "live-speakers" ? 3 : 1),
                end: Double(index) * (mode == "live-speakers" ? 3 : 1) + 2,
                text: "Synthetic live passage \(index)."), final: true)
    }
    private func refreshLive() {
        liveRows.update(stream, people: [], enabled: mode == "live-speakers", recognitionEnabled: true)
        revision = liveRows.revision
    }
}

private struct ScrollFixtureView: View {
    @ObservedObject var model: ScrollFixture
    var body: some View {
        HStack(spacing: 0) {
            NativeMeetingList(
                entries: model.entries, selection: $model.selection, isFinalizing: false, isPlaying: false,
                canPlay: false, archiveStatuses: [:], viewportChanged: { _ in }, play: { _ in },
                reveal: { _ in }, export: { _ in }, delete: { _ in }
            )
            .frame(width: 360)
            NativeTranscriptView(
                rows: model.isLive ? [] : model.rows, generation: model.revision,
                showsSpeakers: true, editable: false, canPlay: false,
                playback: model.playback, meetingID: model.meeting.id,
                liveRows: model.isLive ? model.liveRows : nil, followsLive: false,
                play: { _ in }, save: { _, _ in }, speakerPicker: { _, _, _ in AnyView(EmptyView()) })
        }
    }
}
