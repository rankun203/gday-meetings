import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptPassagePresentationTests {
    private func row(_ text: String, at start: Double, speaker: MeetingSpeaker? = nil) -> TranscriptSegment {
        let id = UUID()
        return .init(
            id: id, start: start, end: start + 1, speaker: speaker?.label ?? "sys", text: text,
            speakerID: speaker?.id, source: .system, sourcePlaceholder: speaker == nil,
            analysisTrackID: "track0",
            timing: .init(
                text: text,
                spans: [
                    .init(
                        range: .init(location: 0, length: text.utf16.count), start: start,
                        end: start + 1, granularity: .run)
                ]),
            sourceSpans: [.init(rowID: id, range: .init(location: 0, length: text.utf16.count), text: text)])
    }
    @Test func continuationGroupsWithoutChangingCanonicalAttribution() {
        let speaker = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic")
        let rows = [
            row("A sentence", at: 0, speaker: speaker), row(" ends", at: 1), row(".", at: 2), row("Next", at: 3),
        ]
        let analysis = LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: [
                .init(track: "track0", label: "A", start: 0, end: 1),
                .init(track: "track0", label: "A", start: 2, end: 2.5),
            ], speakers: [speaker])
        let grouped = TranscriptPassagePresentation.groups(rows, speakers: [speaker], analysis: analysis)
        #expect(grouped.map(\.count) == [3, 1])
        #expect(grouped.flatMap { $0 } == rows)
        #expect(grouped[0][1].speakerID == nil)
        #expect(TranscriptPassagePresentation.endsSentence("你好。", before: "下一句"))
        #expect(!TranscriptPassagePresentation.endsSentence("Version 1.", before: "5 remains"))
    }
    @Test func differentVoiceOverlapSessionAndManualBoundariesStopComposition() {
        var speaker = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic")
        let first = row("Start", at: 0, speaker: speaker)
        var second = row(" continuation", at: 1)
        var analysis = LocalDiarizationResult(
            modelRevision: "synthetic",
            ranges: [
                .init(track: "track0", label: "B", start: 1, end: 2)
            ], speakers: [speaker])
        #expect(
            TranscriptPassagePresentation.groups([first, second], speakers: [speaker], analysis: analysis).count == 2)
        analysis.ranges = []
        second.session = UUID()
        #expect(
            TranscriptPassagePresentation.groups([first, second], speakers: [speaker], analysis: analysis).count == 2)
        second.session = nil
        second.source = .microphone
        #expect(
            TranscriptPassagePresentation.groups([first, second], speakers: [speaker], analysis: analysis).count == 2)
        second.source = .system
        speaker.manuallyAssigned = true
        #expect(
            TranscriptPassagePresentation.groups([first, second], speakers: [speaker], analysis: analysis).count == 2)
    }
    @Test func displayCompositionPreservesWhitespacePunctuationAndAnchorContinuity() throws {
        let first = row("Hello", at: 0)
        var second = row(" world", at: 1)
        func display(_ segment: TranscriptSegment) -> TranscriptDisplayRow {
            .init(
                id: segment.id, start: segment.start, end: segment.end, speaker: segment.speaker,
                speakerID: segment.speakerID, text: String(segment.text.drop(while: { $0.isWhitespace })))
        }
        var passage = try #require(
            TranscriptDisplayRow.passage(rows: [display(first), display(second)], segments: [first, second]))
        #expect(passage.text == "Hello world")
        #expect(passage.sourceRow(atUTF16: 7).id == second.id)
        second.text = "."
        passage = try #require(
            TranscriptDisplayRow.passage(rows: [display(first), display(second)], segments: [first, second]))
        #expect(passage.text == "Hello.")
        second.text = "world"
        second.sourceSpans = [.init(rowID: first.id, range: .init(location: 10, length: 5), text: "world")]
        passage = try #require(
            TranscriptDisplayRow.passage(rows: [display(first), display(second)], segments: [first, second]))
        #expect(passage.text == "Hello world")
        second.sourceSpans?[0].range.location = 5
        passage = try #require(
            TranscriptDisplayRow.passage(rows: [display(first), display(second)], segments: [first, second]))
        #expect(passage.text == "Helloworld")
        #expect(TranscriptPassagePresentation.groups([first, second], speakers: [], analysis: nil).count == 2)
    }

    @Test func contextMenuEditKeepsTargetFromOpeningEvent() throws {
        let first = TranscriptDisplayRow(id: UUID(), start: 0, end: 1, speaker: "A", speakerID: UUID(), text: "First")
        let next = TranscriptDisplayRow(id: UUID(), start: 1, end: 2, speaker: "sys", speakerID: nil, text: "next")
        var passage = TranscriptDisplayRow(
            id: first.id, start: 0, end: 2, speaker: "A", speakerID: first.speakerID, text: "First next")
        passage.constituents = [first, next]
        passage.constituentTextRanges = [NSRange(location: 0, length: 5), NSRange(location: 6, length: 4)]
        let cell = TranscriptNativeCell(frame: .zero)
        cell.allowsEditing = true
        var edited: UUID?
        cell.editText = { edited = first.id }
        cell.contextMenuEdit = { event in
            let target = passage.sourceRow(atUTF16: Int(event.locationInWindow.x)).id
            return { edited = target }
        }
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: 7, y: 1), modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try #require(cell.menu(for: event))
        let index = menu.indexOfItem(withTitle: "Edit Transcript")
        #expect(index >= 0)
        // The menu action carries no original click; its captured target must survive.
        menu.performActionForItem(at: index)
        #expect(edited == next.id)
    }

    @Test func compoundDisplayRoutesConstituentPlaybackNavigationAndExpansion() {
        let meetingID = UUID()
        let first = TranscriptDisplayRow(id: UUID(), start: 0, end: 1, speaker: "A", speakerID: UUID(), text: "First")
        let next = TranscriptDisplayRow(id: UUID(), start: 2, end: 3, speaker: "sys", speakerID: nil, text: "next")
        var passage = TranscriptDisplayRow(
            id: first.id, start: 0, end: 3, speaker: "A", speakerID: first.speakerID, text: "First next")
        passage.constituents = [first, next]
        passage.constituentTextRanges = [NSRange(location: 0, length: 5), NSRange(location: 6, length: 4)]
        #expect(passage.containsSourceRow(next.id))
        #expect(passage.sourceRow(atUTF16: 7).id == next.id)
        let view = NativeTranscriptView(
            rows: [passage], generation: 0, showsSpeakers: true, editable: true, canPlay: true,
            meetingID: meetingID, sourceRowIDs: [first.id, next.id],
            play: { _ in }, save: { _, _ in }, speakerPicker: { _, _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let table = TranscriptNativeTable(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.update(view)
        coordinator.updatePlayback(meetingID: meetingID, time: 2.5, follows: false)
        #expect(coordinator.activeRows == [0])
        coordinator.updatePlayback(meetingID: meetingID, time: 1.5, follows: false)
        #expect(coordinator.activeRows.isEmpty)
        coordinator.edit(id: next.id)
        #expect(coordinator.rows.map(\.id) == [first.id, next.id])
        coordinator.update(view)
        #expect(coordinator.rows.map(\.id) == [first.id, next.id])
        coordinator.tearDown()
    }
}
