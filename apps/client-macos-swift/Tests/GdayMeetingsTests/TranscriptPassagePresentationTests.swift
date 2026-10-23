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
    private func fragments(_ values: [(String, MeetingSpeaker?)]) -> [TranscriptSegment] {
        let original = UUID()
        var offset = 0
        return values.enumerated().map { index, value in
            var segment = row(value.0, at: Double(index), speaker: value.1)
            segment.sourceSpans = [
                .init(
                    rowID: original, range: .init(location: offset, length: value.0.utf16.count), text: value.0)
            ]
            offset += value.0.utf16.count
            return segment
        }
    }

    @Test func originalPassageGroupsUnknownWordsPunctuationAndSentences() {
        let speaker = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic")
        let rows = fragments([("A sentence", speaker), (" ends", nil), (".", nil), (" Next sentence.", speaker)])
        let grouped = TranscriptPassagePresentation.groups(rows, speakers: [speaker], analysis: nil)
        #expect(grouped.map(\.count) == [4])
        #expect(grouped.flatMap { $0 } == rows)
        #expect(grouped[0][1].speakerID == nil)
        #expect(grouped[0][2].speakerID == nil)
    }

    @Test func entirelyUnresolvedOriginalPassageStillReadsAsOneParagraph() {
        let rows = fragments([("你", nil), ("好", nil), ("。", nil), (" 下一句", nil)])
        #expect(TranscriptPassagePresentation.groups(rows, speakers: [], analysis: nil).map(\.count) == [4])
    }

    @Test func differentVoiceSessionSourceAndPassageCorrectionBoundariesStopComposition() {
        var speaker = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic")
        let other = MeetingSpeaker(label: "B", track: "track0", providerName: "Synthetic")
        var rows = fragments([("Start", speaker), (" unknown", nil), (" changed", other)])
        #expect(
            TranscriptPassagePresentation.groups(rows, speakers: [speaker, other], analysis: nil).map(\.count) == [
                2, 1,
            ])
        rows[1].session = UUID()
        #expect(
            TranscriptPassagePresentation.groups(Array(rows.prefix(2)), speakers: [speaker], analysis: nil).count == 2)
        rows[1].session = nil
        rows[1].source = .microphone
        #expect(
            TranscriptPassagePresentation.groups(Array(rows.prefix(2)), speakers: [speaker], analysis: nil).count == 2)
        rows[1].source = .system
        speaker.manuallyAssigned = true
        speaker.personID = UUID()
        #expect(
            TranscriptPassagePresentation.groups(Array(rows.prefix(2)), speakers: [speaker], analysis: nil).count == 1)
        speaker.passageAssignmentOrigin = .init(speaker: "A")
        #expect(
            TranscriptPassagePresentation.groups(Array(rows.prefix(2)), speakers: [speaker], analysis: nil).count == 2)
    }

    @Test func separateOriginalPassagesAndEditedAnchorsKeepTheirBoundaries() {
        let speaker = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic")
        let separate = [
            row("First paragraph", at: 0, speaker: speaker), row("Second paragraph", at: 1, speaker: speaker),
        ]
        #expect(TranscriptPassagePresentation.groups(separate, speakers: [speaker], analysis: nil).count == 2)
        var rows = fragments([("First", speaker), (" next", speaker)])
        rows[1].text = "Edited"
        #expect(TranscriptPassagePresentation.groups(rows, speakers: [speaker], analysis: nil).count == 2)
    }

    @Test func mixedDisplayRetainsClickedUnknownIdentityAndSupportedHeader() throws {
        let speaker = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic")
        let segments = fragments([("Unknown ", nil), ("known", speaker), (".", nil)])
        let person = UUID()
        let rows = segments.map {
            TranscriptDisplayRow(
                id: $0.id, start: $0.start, end: $0.end, speaker: $0.speaker,
                speakerID: $0.speakerID, text: $0.text,
                personID: $0.speakerID == nil ? nil : person,
                isSourcePlaceholder: $0.sourcePlaceholder == true,
                transcriptAssociationTier: $0.speakerID == nil ? nil : .automatic)
        }
        let passage = try #require(TranscriptDisplayRow.passage(rows: rows, segments: segments))
        #expect(passage.text == "Unknown known.")
        #expect(passage.speakerID == speaker.id)
        #expect(passage.sourceRow(atUTF16: 1).speakerID == nil)
        #expect(passage.sourceRow(atUTF16: 9).speakerID == speaker.id)
        #expect(passage.sourceRow(atUTF16: 13).speakerID == nil)
        #expect(passage.accessibilityHelp == "Some words have no speaker label.")
        #expect(passage.canonicalRows == rows)
        #expect(passage.id == segments[0].id)
        #expect(passage.speakerSourceRowID == segments[1].id)
        let assignmentTarget = try #require(passage.canonicalRows.first { $0.id == passage.speakerSourceRowID })
        #expect(assignmentTarget.speakerID == passage.speakerID)
        #expect(assignmentTarget.transcriptAssociationTier == .automatic)
        let cell = TranscriptNativeCell(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
        cell.configure(passage, showsSpeakers: true)
        #expect(cell.badge.unresolved)
        #expect(cell.badge.toolTip?.contains("Some words have no speaker label.") == true)
        #expect(cell.body.toolTip == "Some words have no speaker label.")
    }

    @Test func separateTurnProjectionsWithSameVoiceAndPersonKeepOneReadingPassage() throws {
        let base = UUID()
        let person = UUID()
        var first = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic", personID: person)
        first.voiceReviewOrigin = .init(speakerID: base, transcriptAssociationTier: .automatic)
        var next = first
        next.id = UUID()
        next.voiceReviewOrigin?.transcriptAssociationTier = .tentative
        let segments = fragments([("One", first), (" paragraph.", next)])
        let groups = TranscriptPassagePresentation.groups(segments, speakers: [first, next], analysis: nil)
        #expect(groups.map(\.count) == [2])
        let rows = segments.enumerated().map { index, segment in
            TranscriptDisplayRow(
                id: segment.id, start: segment.start, end: segment.end, speaker: "Example Person",
                speakerID: segment.speakerID, text: segment.text, personID: person,
                transcriptAssociationTier: index == 0 ? .automatic : .tentative)
        }
        let display = try #require(TranscriptDisplayRow.passage(rows: rows, segments: segments))
        #expect(display.transcriptAssociationTier == .tentative)
        #expect(display.canonicalRows[0].transcriptAssociationTier == .automatic)
        #expect(display.canonicalRows[1].transcriptAssociationTier == .tentative)
        var unmatched = first
        unmatched.id = base
        unmatched.personID = nil
        unmatched.voiceReviewOrigin = nil
        let withGap = fragments([("One", first), (" unmatched", unmatched), (" paragraph.", next)])
        #expect(
            TranscriptPassagePresentation.groups(withGap, speakers: [first, unmatched, next], analysis: nil).map(
                \.count) == [3])
    }

    @Test func overlappingNativeIntervalsKeepOriginalReadingAndConstituentPlayback() throws {
        let speaker = MeetingSpeaker(label: "A", track: "track0", providerName: "Synthetic")
        var segments = fragments([("Native", speaker), (" timing.", nil)])
        segments[0].end = 3
        let grouped = TranscriptPassagePresentation.groups(segments, speakers: [speaker], analysis: nil)
        #expect(grouped.map(\.count) == [2])
        let rows = segments.map {
            TranscriptDisplayRow(
                id: $0.id, start: $0.start, end: $0.end, speaker: $0.speaker,
                speakerID: $0.speakerID, text: $0.text)
        }
        let passage = try #require(TranscriptDisplayRow.passage(rows: rows, segments: segments))
        #expect(passage.end == 3)
        #expect(passage.canonicalRows.map(\.end) == [3, 2])
        #expect(passage.sourceRow(atUTF16: 8).id == segments[1].id)
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
        #expect(TranscriptPassagePresentation.groups([first, second], speakers: [], analysis: nil).count == 1)
    }

    @Test func readablePreviewUsesProductionMatchingAndOriginalReadingBoundaries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        await store.libraryMonitor?.stop()
        store.libraryMonitor = nil
        _ = await store.addPerson(name: "Person A")
        _ = await store.addPerson(name: "Person B")
        var meeting = Meeting(title: "Synthetic readable transcript", audioFiles: ["microphone.wav"])
        meeting.duration = 60
        let folder = store.directory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Synthetic audio revision".utf8).write(to: folder.appendingPathComponent("microphone.wav"))
        try await store.insertImportedMeeting(meeting)
        try await UIPreview.seedReadableTranscriptPresentation(store: store, meeting: meeting)
        await store.refreshVoiceAssignments(meetingIDs: [meeting.id])
        await store.flushVoiceAssignmentRefresh()
        let current = try #require(store.meeting(id: meeting.id))
        let grouped = TranscriptPassagePresentation.groups(
            current.transcript, speakers: current.speakers, analysis: nil)
        #expect(grouped.map(\.count) == [4, 1, 1, 3])
        #expect(grouped[0].map(\.text).joined() == "The schedule is ready, and the notes are saved.")
        #expect(grouped[0][1].speakerID == nil)
        #expect(grouped.last?.allSatisfy { $0.speakerID == nil } == true)
        #expect(grouped.flatMap { $0 } == current.transcript)
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
