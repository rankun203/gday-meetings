import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

/// Hosted Notes workload. Opt in explicitly; fixtures and saved files are temporary.
@Suite(.serialized) @MainActor struct NotesCapacityTests {
    @Test func sustainedEditingByPayloadSize() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GDAY_NOTES_CAPACITY"] == "1" else { return }
        let sizes = (environment["GDAY_NOTES_CAPACITY_BYTES"] ?? "10240,102400")
            .split(separator: ",").compactMap { Int($0) }.filter { (1...512_000).contains($0) }
        let mode = environment["GDAY_NOTES_CAPACITY_MODE"] ?? "append"
        try #require(["append", "beginning", "middle", "style", "image"].contains(mode))
        for bytes in sizes { try await exercise(bytes: bytes, mode: mode) }
    }

    private func exercise(bytes: Int, mode: String) async throws {
        PerformanceResourceMetrics.prepareApplication()
        let fixtures = NotesImageTests()
        let directory = try fixtures.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(dataDirectory: directory)
        for index in 0..<26 { store.createMeeting(title: "Synthetic meeting \(index)") }
        let meetingID = store.meetings[0].id
        let imageDirectory = store.directory(for: meetingID)
        let path = try NotesImageStore.write(fixtures.png(), filename: "diagram.png", directory: imageDirectory)
        let images = String(repeating: "![Diagram](\(path))\n", count: 4)
        let line = "会议记录 👩🏽‍💻 Review the proposed change and record the next action.\n"
        let count = max(1, (bytes - images.utf8.count + line.utf8.count - 1) / line.utf8.count)
        let initial = String(repeating: line, count: count) + images
        var meeting = store.meetings[0]
        meeting.notes = initial
        store.updateMeeting(meeting)
        #expect(store.flushNotes())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Notes capacity evaluation"
        let fullLibrary = ProcessInfo.processInfo.environment["GDAY_NOTES_CAPACITY_WORKSPACE"] == "library"
        let scope = fullLibrary ? "library" : "component"
        let root: AnyView =
            fullLibrary
            ? AnyView(
                LibraryView(selectedMeetingID: meetingID).environmentObject(store).environmentObject(MeetingPlayback()))
            : AnyView(
                MeetingNotesWorkspace(meetingID: meetingID).environmentObject(store).environmentObject(
                    MeetingPlayback()))
        let host = NSHostingView(rootView: root)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            store.closeNotes(id: meetingID)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(25))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func editor(in view: NSView) -> NotesTextView? {
            if let text = view as? NotesTextView { return text }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        // In library mode, select Notes through the UI before opening the start gate.
        try PerformanceResourceMetrics.waitForStartGate(task: "notes", mode: "\(scope)-\(mode)")
        let text = try #require(editor(in: host))
        window.makeFirstResponder(text)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try fixtures.png(), forType: .png)
        let fragment = mode == "style" ? "**文**" : "文"
        let operationLimit = Int(ProcessInfo.processInfo.environment["GDAY_PERFORMANCE_OPERATIONS"] ?? "250") ?? 250
        try #require((1...250).contains(operationLimit))
        let rate = 10.0
        let metrics = try PerformanceResourceMetrics(
            task: "notes", mode: "\(scope)-\(mode)", initialPayload: initial, cadenceHz: rate,
            fragmentBytes: fragment.utf8.count,
            imageReferenceCount: 4, uniqueAssetPixels: 80_000)
        _ = try metrics.record(
            event: "begin", phase: "typing", payload: text.string, updates: 0, skipped: 0, insertedBytes: 0)
        var updates = 0
        var skipped = 0
        var nextUpdate = 0.0
        var nextSample = 0.0
        var aborted = false
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 25 && updates < operationLimit {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            if elapsed >= nextUpdate {
                skipped += max(0, Int((elapsed - nextUpdate) * rate))
                nextUpdate = elapsed + 1 / rate
                let source = text.string as NSString
                let location: Int
                switch mode {
                case "beginning": location = 0
                case "middle", "style", "image":
                    // Use a paragraph boundary, never split a Unicode grapheme.
                    location = source.paragraphRange(for: NSRange(location: source.length / 2, length: 0)).location
                default: location = source.length
                }
                let actionUTC = Date()
                let actionStarted = ProcessInfo.processInfo.systemUptime
                if mode == "image" {
                    text.setSelectedRange(NSRange(location: location, length: 0))
                    try #require(text.pasteImages(from: pasteboard))
                }
                else {
                    text.insertText(fragment, replacementRange: NSRange(location: location, length: 0))
                }
                try await Task.sleep(for: .milliseconds(1))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let actionDuration = ProcessInfo.processInfo.systemUptime - actionStarted
                updates += 1
                try metrics.recordAction(
                    name: mode == "image" ? "paste-image-and-layout" : "insert-and-style-layout", startedAt: actionUTC,
                    durationSeconds: actionDuration,
                    payloadBytes: text.string.utf8.count)
                if actionDuration > 2 {
                    aborted = true
                    break
                }
            }
            if elapsed >= nextSample {
                nextSample = elapsed + 1
                let sample = try metrics.record(
                    phase: "typing", payload: text.string, updates: updates, skipped: skipped,
                    insertedBytes: text.string.utf8.count - initial.utf8.count)
                if (sample.physicalFootprintBytes ?? 0) > 2 * 1024 * 1024 * 1024 {
                    aborted = true
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = try metrics.record(
            event: "phase", phase: aborted ? "guard-stop" : "hold", payload: text.string,
            updates: updates, skipped: skipped, insertedBytes: text.string.utf8.count - initial.utf8.count)
        for second in 0..<5 {
            try await Task.sleep(for: .seconds(1))
            if second == 0 {
                _ = try metrics.record(
                    event: "phase", phase: "save-start", payload: text.string, updates: updates,
                    skipped: skipped, insertedBytes: text.string.utf8.count - initial.utf8.count)
                #expect(store.flushNotes())
                _ = try metrics.record(
                    event: "phase", phase: "save-end", payload: text.string, updates: updates,
                    skipped: skipped, insertedBytes: text.string.utf8.count - initial.utf8.count)
            }
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            _ = try metrics.record(
                phase: "hold", payload: text.string, updates: updates, skipped: skipped,
                insertedBytes: text.string.utf8.count - initial.utf8.count)
        }
        _ = try metrics.record(
            event: "end", phase: aborted ? "guard-stop" : "finished", payload: text.string,
            updates: updates, skipped: skipped, insertedBytes: text.string.utf8.count - initial.utf8.count)
        #expect(store.meetings.first?.notes == text.document.markdown)
        if ProcessInfo.processInfo.environment["GDAY_PERFORMANCE_OPERATIONS"] != nil {
            #expect(updates == operationLimit, "The fixed-work scaling batch did not complete")
        }
        if mode == "image" {
            #expect(NotesImageReference.parse(in: text.string).count == 4 + updates)
        }
    }
}
