import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct NativeTranscriptTests {
    @Test func timestampRevisionPreservesUntouchedOverlappingPlaybackCell() throws {
        let playback = MeetingPlayback()
        let meeting = Meeting(title: "Synthetic playback revision")
        playback.select(meeting: meeting, files: [])
        playback.progress.update(5)
        let first = TranscriptDisplayRow(id: UUID(), start: 0, end: 10, speaker: "", speakerID: nil, text: "First")
        let second = TranscriptDisplayRow(
            id: UUID(), start: 10, end: 11, speaker: "", speakerID: nil, text: "Second")
        var view = NativeTranscriptView(
            rows: [first, second], generation: 1, showsSpeakers: false, editable: true, canPlay: true,
            playback: playback, meetingID: meeting.id, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let table = TranscriptNativeTable(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.update(view)
        coordinator.settleLayout()
        let untouched = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? TranscriptNativeCell)
        #expect(untouched.isPlaybackRow)
        view.rows[1] = TranscriptDisplayRow(
            id: second.id, start: 3, end: 8, speaker: "", speakerID: nil, text: "Second")
        view.generation += 1
        coordinator.update(view)
        #expect(coordinator.activeRow == 1)
        #expect(untouched.isPlaybackRow)
        let current = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? TranscriptNativeCell)
        #expect(current.isPlaybackRow)
        playback.progress.update(9)
        #expect(untouched.isPlaybackRow)
        #expect(!current.isPlaybackRow)
        playback.progress.update(10)
        #expect(!untouched.isPlaybackRow)
        #expect(coordinator.activeRows.isEmpty)
        coordinator.tearDown()
    }

    @Test func playbackHighlightFollowsClockSeekAndMeetingWithoutReloadingRows() {
        let meetingID = UUID()
        let rows = [0.0, 2, 5, 14, 18].map {
            TranscriptDisplayRow(id: UUID(), start: $0, end: $0 + 1, speaker: "Alex", speakerID: nil, text: "At \($0)")
        }
        let view = NativeTranscriptView(
            rows: rows, generation: 1, showsSpeakers: true, editable: true, canPlay: true,
            meetingID: meetingID, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let table = TranscriptNativeTable()
        coordinator.table = table
        coordinator.update(view)
        coordinator.updatePlayback(meetingID: meetingID, time: 2)
        #expect(coordinator.activeRow == 1)
        coordinator.updatePlayback(meetingID: meetingID, time: 18.2)
        #expect(coordinator.activeRow == 4)
        coordinator.updatePlayback(meetingID: meetingID, time: 5)
        #expect(coordinator.activeRow == 2)
        coordinator.updatePlayback(meetingID: UUID(), time: 5)
        #expect(coordinator.activeRow == nil)
        coordinator.updatePlayback(meetingID: nil, time: 5)
        #expect(coordinator.activeRow == nil)
        coordinator.updatePlayback(meetingID: meetingID, time: -1)
        #expect(coordinator.activeRow == nil)
        #expect(coordinator.generation == 1)
        #expect(coordinator.heights.statistics.measurements == 0)
    }

    @Test func playbackSubscriptionFollowsActualProgressIncludingScrub() {
        let playback = MeetingPlayback()
        let meeting = Meeting(title: "Clock")
        let rows = [0.0, 2, 5].map {
            TranscriptDisplayRow(id: UUID(), start: $0, end: $0 + 1, speaker: "", speakerID: nil, text: "At \($0)")
        }
        let view = NativeTranscriptView(
            rows: rows, generation: 1, showsSpeakers: false, editable: true, canPlay: true,
            playback: playback, meetingID: meeting.id, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let table = TranscriptNativeTable()
        coordinator.table = table
        coordinator.update(view)
        #expect(coordinator.activeRow == nil)
        playback.select(meeting: meeting, files: [])
        playback.progress.update(2)
        #expect(coordinator.activeRow == 1)
        playback.progress.update(5.2)
        #expect(coordinator.activeRow == 2)
        playback.progress.scrub(to: 0)
        #expect(coordinator.activeRow == 0)
        playback.progress.scrub(to: nil)
        #expect(coordinator.activeRow == 2)
    }

    @Test func overlappingPlaybackHighlightsEveryIntervalAndClearsExpiredRows() throws {
        let playback = MeetingPlayback()
        let meeting = Meeting(title: "Overlapping sources")
        // Deliberately unsorted, including equal starts and nested intervals.
        let intervals: [(Double, Double, String)] = [
            (4, 6, "System Audio"), (1, 10, "Microphone"), (4, 8, "System Audio"),
            (12, 14, "Microphone"), (6, 6, "Empty"), (8, 7, "Invalid"),
            (.nan, 20, "Invalid"), (0, .infinity, "Invalid"),
        ]
        let rows = intervals.map {
            TranscriptDisplayRow(id: UUID(), start: $0.0, end: $0.1, speaker: $0.2, speakerID: nil, text: "Example")
        }
        var view = NativeTranscriptView(
            rows: rows, generation: 1, showsSpeakers: true, editable: true, canPlay: true,
            playback: playback, meetingID: meeting.id, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let table = TranscriptNativeTable()
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        coordinator.table = table
        coordinator.update(view)
        playback.select(meeting: meeting, files: [])
        playback.progress.update(4)
        #expect(coordinator.activeRows == [0, 1, 2])
        #expect(coordinator.activeRow == 2)
        for row in 0..<4 {
            let cell = TranscriptNativeCell()
            coordinator.configure(cell, for: rows[row])
            #expect(cell.isPlaybackRow == (row < 3))
            let nativeRow = try #require(coordinator.tableView(table, rowViewForRow: row) as? TranscriptNativeRowView)
            #expect(nativeRow.isPlaybackRow == (row < 3))
        }
        playback.progress.update(6)
        #expect(coordinator.activeRows == [1, 2])
        playback.progress.update(8)
        #expect(coordinator.activeRows == [1])
        playback.progress.update(10)
        #expect(coordinator.activeRows.isEmpty)
        playback.progress.update(12)
        #expect(coordinator.activeRows == [3])
        playback.progress.scrub(to: 5)
        #expect(coordinator.activeRows == [0, 1, 2])
        playback.progress.scrub(to: nil)
        #expect(coordinator.activeRows == [3])
        playback.progress.update(5)
        view.rows = [rows[3]]
        view.generation += 1
        coordinator.update(view)
        #expect(coordinator.activeRows.isEmpty)
        playback.progress.update(12)
        #expect(coordinator.activeRows == [0])
        coordinator.updatePlayback(meetingID: UUID(), time: 12)
        #expect(coordinator.activeRows.isEmpty)
        coordinator.updatePlayback(meetingID: meeting.id, time: .nan)
        #expect(coordinator.activeRows.isEmpty)
        coordinator.updatePlayback(meetingID: meeting.id, time: -1)
        #expect(coordinator.activeRows.isEmpty)
        #expect(coordinator.heights.statistics.measurements == 0)
        coordinator.tearDown()
    }

    @Test func speakerForegroundContrastsWithTintedChipInLightAndDarkAppearance() {
        func luminance(_ components: [CGFloat]) -> Double {
            let linear = components.map { component -> Double in
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                for index in 0..<8 {
                    let tint = TranscriptSpeakerPalette.color(for: "", index: index)
                    let foreground = TranscriptSpeakerPalette.foreground(for: tint).usingColorSpace(.sRGB)!
                    let fill = tint.usingColorSpace(.sRGB)!
                    let base = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
                    let fg = luminance([foreground.redComponent, foreground.greenComponent, foreground.blueComponent])
                    let bg = luminance(
                        zip(
                            [fill.redComponent, fill.greenComponent, fill.blueComponent],
                            [base.redComponent, base.greenComponent, base.blueComponent]
                        ).map { $0 * 0.12 + $1 * 0.88 })
                    #expect((max(fg, bg) + 0.05) / (min(fg, bg) + 0.05) >= 4.5)
                }
            }
        }
    }

    @Test func initialDeepPositionSettlesWithoutAnimationAndMeetingChangeResets() async throws {
        let playback = MeetingPlayback()
        let meeting = Meeting(title: "Deep transcript")
        playback.select(meeting: meeting, files: [])
        playback.progress.update(1_000)
        let rows = (0..<2_000).map {
            TranscriptDisplayRow(
                id: UUID(), start: Double($0), end: Double($0) + 1, speaker: "Alex", speakerID: nil,
                text: String(repeating: "Wrapped transcript content. ", count: $0 % 3 + 1))
        }
        var view = NativeTranscriptView(
            rows: rows, generation: 1, showsSpeakers: true, editable: true, canPlay: true,
            playback: playback, meetingID: meeting.id, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let table = TranscriptNativeTable(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        table.usesAutomaticRowHeights = false
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(coordinator.activeRow == 1_000)
        #expect(table.rows(in: scroll.contentView.bounds).contains(1_000))
        let targetOffset = scroll.contentView.bounds.minY - table.rect(ofRow: 1_000).minY
        coordinator.requestVisibleMeasurements()
        await coordinator.heights.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(300))
        #expect(table.rows(in: scroll.contentView.bounds).contains(1_000))
        #expect(abs(scroll.contentView.bounds.minY - table.rect(ofRow: 1_000).minY - targetOffset) < 1)
        // A provider result replaces a live/history version in the same meeting.
        // The old viewport must not stay below the end of the new document.
        view.transcriptSourceID = UUID()
        view.rows = Array(rows.prefix(3))
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(coordinator.rows.count == 3)
        #expect(coordinator.activeRows.isEmpty)
        #expect(scroll.contentView.bounds.minY == 0)
        view.meetingID = UUID()
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(coordinator.activeRow == nil)
        #expect(scroll.contentView.bounds.minY == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scroll.contentView.bounds.minY == 0)
    }

    @Test func reviewNavigationWaitsForRowsWithoutChangingPlayback() {
        let playback = MeetingPlayback()
        let playingMeeting = Meeting(title: "Existing playback")
        playback.select(meeting: playingMeeting, files: [])
        playback.progress.update(17)
        let previous = playback.progress.snapshot
        let rows = (0..<200).map {
            TranscriptDisplayRow(
                id: UUID(), start: Double($0), end: Double($0) + 1, speaker: "Speaker", speakerID: nil,
                text: "A saved transcript passage.")
        }
        var playbackRequests = 0
        var view = NativeTranscriptView(
            rows: [], generation: 1, showsSpeakers: true, editable: false, canPlay: true,
            playback: playback, meetingID: UUID(), initialRowID: rows[100].id,
            play: { _ in playbackRequests += 1 }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let table = TranscriptNativeTable(frame: scroll.bounds)
        table.usesAutomaticRowHeights = false
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(table.selectedRow == -1)
        #expect(playback.progress.snapshot == previous)
        view.rows = rows
        view.generation = 2
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(table.rows(in: scroll.contentView.bounds).contains(100))
        #expect(table.selectedRow == 100)
        #expect((table.rowView(atRow: 100, makeIfNecessary: true) as? TranscriptNativeRowView)?.isReviewTarget == true)
        #expect(coordinator.activeRows.isEmpty)
        let positioned = scroll.contentView.bounds.minY
        coordinator.settleLayout()
        #expect(abs(scroll.contentView.bounds.minY - positioned) < 1)
        view.initialRowID = rows[150].id
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(table.rows(in: scroll.contentView.bounds).contains(150))
        #expect(table.selectedRow == 150)
        #expect((table.rowView(atRow: 150, makeIfNecessary: true) as? TranscriptNativeRowView)?.isReviewTarget == true)
        #expect((table.rowView(atRow: 100, makeIfNecessary: true) as? TranscriptNativeRowView)?.isReviewTarget == false)
        #expect(playback.progress.snapshot == previous)
        #expect(playbackRequests == 0)
        coordinator.tearDown()
    }

    @Test func speakerPaletteSurvivesInsertionRemovalAndReordering() {
        let keys = (0..<32).map { "speaker-\($0)" }
        let colors = TranscriptSpeakerPalette.indices(for: keys)
        #expect(colors == TranscriptSpeakerPalette.indices(for: keys.reversed()))
        #expect(Set(colors.values).count == keys.count)
        for key in keys {
            #expect(TranscriptSpeakerPalette.indices(for: [key], preserving: colors)[key] == colors[key])
            #expect(
                TranscriptSpeakerPalette.indices(for: ["new-speaker", key], preserving: colors)[key] == colors[key])
        }
        #expect(TranscriptSpeakerPalette.color(for: "", index: 8) != TranscriptSpeakerPalette.color(for: "", index: 0))
    }

    @Test func speakerChipsFollowPersonIdentityAndUnassignedOutline() {
        let person = UUID()
        let first = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "Alex", speakerID: UUID(), text: "", personID: person)
        let second = TranscriptDisplayRow(
            id: UUID(), start: 1, end: 2, speaker: "Alex", speakerID: UUID(), text: "", personID: person)
        let cell = TranscriptNativeCell(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        cell.configure(first, showsSpeakers: true)
        cell.layout()
        let tint = cell.badge.tint
        #expect(!cell.badge.unresolved)
        #expect(cell.badge.frame.width < 100)
        cell.configure(second, showsSpeakers: true)
        #expect(cell.badge.tint == tint)
        cell.configure(
            TranscriptDisplayRow(id: UUID(), start: 2, end: 3, speaker: "mic_00", speakerID: UUID(), text: ""),
            showsSpeakers: true)
        #expect(cell.badge.unresolved)
    }

    @Test func manualScrollCancelsAndTemporarilySuppressesPlaybackFollow() async throws {
        let id = UUID()
        let rows = (0..<100).map {
            TranscriptDisplayRow(
                id: UUID(), start: Double($0), end: Double($0) + 1, speaker: "", speakerID: nil, text: "Line \($0)")
        }
        let view = NativeTranscriptView(
            rows: rows, generation: 1, showsSpeakers: false, editable: true, canPlay: true,
            meetingID: id, play: { _ in }, save: { _, _ in }, speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let table = TranscriptNativeTable(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.update(view)
        table.layoutSubtreeIfNeeded()
        coordinator.updatePlayback(meetingID: id, time: 40)
        try await Task.sleep(for: .milliseconds(300))
        #expect(scroll.contentView.bounds.minY > 0)
        coordinator.updatePlayback(meetingID: id, time: 80)
        coordinator.userScrolled()
        let stoppedRow = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        let stoppedID = rows[stoppedRow].id
        let stoppedOffset = scroll.contentView.bounds.minY - table.rect(ofRow: stoppedRow).minY
        coordinator.updatePlayback(meetingID: id, time: 90)
        try await Task.sleep(for: .milliseconds(300))
        let currentRow = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        #expect(rows[currentRow].id == stoppedID)
        #expect(abs(scroll.contentView.bounds.minY - table.rect(ofRow: currentRow).minY - stoppedOffset) < 1)
        #expect(coordinator.activeRow == 90)
        coordinator.cancelFollow()
    }

    @Test func measurementCorrectionCompletesPausedSeekIntoColdRows() async throws {
        let id = UUID()
        let rows = (0..<2_000).map {
            TranscriptDisplayRow(
                id: UUID(), start: Double($0), end: Double($0 + 1), speaker: "", speakerID: nil,
                text: String(repeating: "Synthetic wrapped seek passage. ", count: 4))
        }
        let view = NativeTranscriptView(
            rows: rows, generation: 1, showsSpeakers: false, editable: true, canPlay: true,
            meetingID: id, play: { _ in }, save: { _, _ in }, speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        defer { coordinator.tearDown() }
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let table = TranscriptNativeTable(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        table.usesAutomaticRowHeights = false
        scroll.documentView = table
        coordinator.table = table
        coordinator.update(view)
        coordinator.settleLayout()
        coordinator.updatePlayback(meetingID: id, time: 1_500)
        try await Task.sleep(for: .milliseconds(800))
        #expect(!coordinator.isFollowing)
        coordinator.requestVisibleMeasurements()
        await coordinator.heights.waitUntilIdle()
        coordinator.requestVisibleMeasurements()
        #expect(!coordinator.hasNavigationAnchor)
        #expect(coordinator.activeRow == 1_500)
        #expect(table.rows(in: scroll.contentView.bounds).contains(1_500))
        #expect(abs(table.rect(ofRow: 1_500).minY - scroll.contentView.bounds.minY - 90) < 1)
        // Cancel a new seek before its target reaches the viewport. A later
        // correction must preserve the reader's current position.
        coordinator.updatePlayback(meetingID: id, time: 100)
        coordinator.cancelFollow()
        #expect(coordinator.hasNavigationAnchor)
        let top = table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
        let offset = scroll.contentView.bounds.minY - table.rect(ofRow: top).minY
        var revised = view
        revised.rows[top] = TranscriptDisplayRow(
            id: rows[top].id, start: rows[top].start, end: rows[top].end, speaker: "", speakerID: nil,
            text: String(repeating: "Revised synthetic passage. ", count: 20))
        revised.generation += 1
        coordinator.update(revised)
        coordinator.requestVisibleMeasurements()
        await coordinator.heights.waitUntilIdle()
        #expect(table.row(at: NSPoint(x: 0, y: scroll.contentView.bounds.minY)) == top)
        #expect(abs(scroll.contentView.bounds.minY - table.rect(ofRow: top).minY - offset) < 1)
        #expect(!coordinator.hasNavigationAnchor)
    }

    @Test func hoverWaitsUntilScrollingStops() async throws {
        let table = TranscriptNativeTable()
        table.delayHover()
        #expect(!table.hoverEnabled)
        try await Task.sleep(for: .milliseconds(100))
        table.delayHover()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!table.hoverEnabled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(table.hoverEnabled)
    }

    @Test func momentumDoesNotRepeatedlyInvalidateVisibleRows() async throws {
        let table = HoverInvalidationTable()
        table.delayHover()
        try await Task.sleep(for: .milliseconds(180))
        #expect(table.hoverEnabled)
        let before = table.invalidations
        table.delayHover()
        #expect(table.invalidations == before + 1)
        for _ in 0..<1_000 { table.delayHover() }
        #expect(table.invalidations == before + 1)
        #expect(!table.hoverEnabled)
        try await Task.sleep(for: .milliseconds(180))
        #expect(table.hoverEnabled)
        #expect(table.invalidations == before + 2)
    }

    @Test func recycledCellCommitsToOriginalSegmentBeforeNewBinding() {
        let first = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "Alex", speakerID: nil, text: "First")
        let second = TranscriptDisplayRow(
            id: UUID(), start: 4, end: 5, speaker: "Sam", speakerID: nil, text: "Second")
        var saved: [(UUID, String)] = []
        let view = NativeTranscriptView(
            rows: [first, second], generation: 1, showsSpeakers: true,
            editable: true, canPlay: false, play: { _ in }, save: { saved.append(($0, $1)) },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        coordinator.rows = [first, second]
        let cell = TranscriptNativeCell()
        coordinator.configure(cell, for: first)
        coordinator.beginEdit(cell, value: first)
        cell.body.stringValue = "First revised"
        coordinator.configure(cell, for: second)
        coordinator.finishEdit()
        #expect(saved.count == 1)
        #expect(saved.first?.0 == first.id)
        #expect(saved.first?.1 == "First revised")
        #expect(cell.body.stringValue == "Second")
        #expect(!cell.body.isEditable)
    }

    @Test func nativeFieldEditorAcceptsDraftAndCommitsOnce() {
        let row = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "Alex", speakerID: nil, text: "Original")
        var saved: [String] = []
        let view = NativeTranscriptView(
            rows: [row], generation: 1, showsSpeakers: true,
            editable: true, canPlay: false, play: { _ in }, save: { _, text in saved.append(text) },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        coordinator.rows = [row]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 100), styleMask: .borderless, backing: .buffered,
            defer: false)
        let table = TranscriptNativeTable(frame: window.contentView!.bounds)
        window.contentView = table
        coordinator.table = table
        let cell = TranscriptNativeCell(frame: table.bounds)
        table.addSubview(cell)
        coordinator.configure(cell, for: row)
        coordinator.beginEdit(cell, value: row)
        #expect(cell.body.isEditable)
        if let editor = cell.body.currentEditor() as? NSTextView {
            #expect(editor.isEditable)
            editor.insertText("Revised", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        else {
            Issue.record("Expected the native window field editor")
        }
        coordinator.finishEdit()
        #expect(saved == ["Revised"])
        window.orderOut(nil)
    }

    @Test func cancelledNativeEditRestoresReadingTextWithoutSaving() {
        let row = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "Alex", speakerID: nil, text: "Original")
        var saved: [String] = []
        let view = NativeTranscriptView(
            rows: [row], generation: 1, showsSpeakers: true,
            editable: true, canPlay: false, play: { _ in }, save: { _, text in saved.append(text) },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        coordinator.rows = [row]
        let cell = TranscriptNativeCell()
        coordinator.configure(cell, for: row)
        coordinator.beginEdit(cell, value: row)
        cell.body.stringValue = "Unwanted"
        coordinator.finishEdit(cancel: true)
        #expect(saved.isEmpty)
        #expect(cell.body.stringValue == "Original")
    }
}

@MainActor private final class HoverInvalidationTable: TranscriptNativeTable {
    var invalidations = 0
    override func redrawVisibleRows() {
        invalidations += 1
        super.redrawVisibleRows()
    }
}
