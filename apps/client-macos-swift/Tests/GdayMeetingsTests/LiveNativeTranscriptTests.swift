import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct LiveNativeTranscriptTests {
    @Test func liveRowsUseNativeBadgesAndIndependentAssignmentTargets() {
        let person = Person(name: "Alex")
        var final = LiveTranscriptPhrase(session: UUID(), source: .system, start: 0, end: 2, text: "Final text")
        final.personID = person.id
        let pending = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 3, end: 5, text: "Changing text")
        let rows = LiveTranscriptDisplay.rows(finalized: [final], partials: [pending], people: [person])
        #expect(rows.map(\.speaker) == ["Alex", "mic_01"])
        #expect(rows.map(\.speakerID) == [final.id, pending.id])
        #expect(!rows[0].isProvisional)
        #expect(rows[1].isProvisional)
        var edited = pending
        edited.userEdited = true
        edited.recognizedFinal = false
        let manual = LiveTranscriptDisplay.rows(finalized: [edited], partials: [], people: [])
        #expect(!manual[0].isProvisional)
        #expect(manual[0].accessibilityHelp == "Edited text.")
        let deleted = LiveTranscriptDisplay.rows(finalized: [final], partials: [], people: [])
        #expect(deleted[0].speaker == "sys_01")
        #expect(deleted[0].personID == nil)
    }

    @Test func provisionalUnderlineEndsWhenFinalized() {
        var row = TranscriptDisplayRow(
            id: UUID(), start: 0, speaker: "Speaker 1", speakerID: UUID(), text: "A changing phrase",
            isProvisional: true, recentWordRanges: [NSRange(location: 2, length: 15)])
        let cell = TranscriptNativeCell()
        cell.configure(row, showsSpeakers: true)
        #expect(
            cell.body.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
                == NSUnderlineStyle.single.rawValue)
        #expect(
            cell.body.attributedStringValue.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
                == .systemRed)
        row.isProvisional = false
        cell.configure(row, showsSpeakers: true)
        #expect(cell.body.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
        #expect(cell.body.attributedStringValue.attribute(.foregroundColor, at: 2, effectiveRange: nil) == nil)
        #expect(cell.body.stringValue == row.text)
    }

    @Test func liveTimestampDoesNotAdvertisePlayback() {
        let row = TranscriptDisplayRow(id: UUID(), start: 3, speaker: "", speakerID: nil, text: "Example")
        let cell = TranscriptNativeCell()
        cell.configure(row, showsSpeakers: false)
        #expect(cell.time.accessibilityLabel() == "00:03")
        cell.play = {}
        #expect(cell.time.accessibilityLabel() == "Play from 00:03")
        cell.play = nil
        #expect(cell.time.accessibilityLabel() == "00:03")
    }

    @Test func refreshPreservesActiveEditAndCoalescesRows() async throws {
        let id = UUID()
        let row = TranscriptDisplayRow(id: id, start: 0, speaker: "", speakerID: nil, text: "Original")
        var saves: [(UUID, String)] = []
        var pauses = 0
        var view = NativeTranscriptView(
            rows: [row], generation: 1, showsSpeakers: false, editable: true, canPlay: false,
            followsLive: true, pauseLiveFollowing: { pauses += 1 }, play: { _ in },
            save: { saves.append(($0, $1)) }, speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let table = TranscriptNativeTable()
        coordinator.table = table
        coordinator.update(view)
        let cell = TranscriptNativeCell()
        coordinator.configure(cell, for: row)
        coordinator.beginEdit(cell, value: row)
        cell.body.stringValue = "Manual correction"
        view.generation = 2
        view.followsLive = false
        view.rows = [TranscriptDisplayRow(id: id, start: 0, speaker: "", speakerID: nil, text: "Automatic revision")]
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(cell.body.isEditable)
        #expect(cell.body.stringValue == "Manual correction")
        #expect(saves.isEmpty)
        #expect(coordinator.generation == 1)
        #expect(pauses == 1)
        coordinator.finishEdit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(saves.count == 1)
        #expect(saves.first?.0 == id)
        #expect(saves.first?.1 == "Manual correction")
        #expect(coordinator.generation == 2)
        coordinator.tearDown()
    }

    @Test func followRemainsPausedUntilExplicitlyEnabled() {
        var pauses = 0
        var view = NativeTranscriptView(
            rows: (0..<100).map {
                TranscriptDisplayRow(id: UUID(), start: Double($0), speaker: "", speakerID: nil, text: "Line \($0)")
            }, generation: 1, showsSpeakers: false, editable: true, canPlay: false,
            followsLive: true, pauseLiveFollowing: { pauses += 1 }, play: { _ in }, save: { _, _ in },
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
        #expect(scroll.contentView.bounds.minY > 0)
        // Selection input pauses live follow without treating programmatic row
        // selection during a refresh as user input.
        coordinator.userSelected()
        scroll.contentView.scroll(to: .zero)
        view.followsLive = false
        view.generation += 1
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(pauses == 1)
        #expect(scroll.contentView.bounds.minY == 0)
        view.followsLive = true
        coordinator.update(view)
        coordinator.settleLayout()
        #expect(scroll.contentView.bounds.minY > 0)
        coordinator.tearDown()
    }
}
