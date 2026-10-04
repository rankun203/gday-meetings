import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct LiveNativeTranscriptTests {
    @Test func streamUpdatesKeepFrozenNativeRowsAndViewport() {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        let session = UUID()
        for index in 0..<1000 {
            stream.accept(
                .init(
                    session: session, source: .system, start: Double(index * 2),
                    end: Double(index * 2) + 1, text: "Sample sentence."), final: true)
        }
        let cache = LiveTranscriptStreamDisplayCache()
        cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
        var view = NativeTranscriptView(
            rows: [], generation: cache.revision, showsSpeakers: true, editable: true, canPlay: false,
            liveRows: cache, followsLive: false, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        let table = ReloadTrackingTranscriptTable(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        coordinator.update(view)
        coordinator.settleLayout()
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        let reloads = table.fullReloads
        let frozen = cache.frozenCount
        let first = coordinator.rows[0]
        for tick in 0..<10 {
            stream.accept(
                .init(
                    session: session, source: .system, start: 2000,
                    end: 2001, text: "Current words \(tick)"), final: false)
            cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
            view.generation = cache.revision
            coordinator.update(view)
            coordinator.settleLayout()
            #expect(table.fullReloads == reloads)
            #expect(table.changedRows.allSatisfy { $0 >= frozen })
            #expect(table.selectedRow == 2)
            #expect(scroll.contentView.bounds.minY == 0)
            #expect(coordinator.rows[0] == first)
        }
        coordinator.tearDown()
    }

    @Test func streamingEditorCommitsCapturedScopeAfterTailGrows() async throws {
        let stream = LiveTranscriptStream()
        stream.reset(labeling: false)
        var phrase = LiveTranscriptPhrase(session: UUID(), source: .system, start: 0, end: 1, text: "Original words")
        stream.accept(phrase, final: false)
        let cache = LiveTranscriptStreamDisplayCache()
        cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
        var capturedEnd: Double?
        var savedText: String?
        var view = NativeTranscriptView(
            rows: [], generation: cache.revision, showsSpeakers: true, editable: true, canPlay: false,
            liveRows: cache,
            captureSave: { id in
                let end = cache.phrase(id: id)?.end
                return { text in
                    capturedEnd = end
                    savedText = text
                }
            }, followsLive: false, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let table = TranscriptNativeTable()
        coordinator.table = table
        coordinator.update(view)
        let cell = TranscriptNativeCell()
        coordinator.configure(cell, for: coordinator.rows[0])
        coordinator.beginEdit(cell, value: coordinator.rows[0])
        cell.body.stringValue = "Manual correction"
        let editingRevision = coordinator.generation
        phrase.end = 3
        phrase.text = "Original words with later words"
        stream.accept(phrase, final: false)
        cache.update(stream, people: [], enabled: false, recognitionEnabled: true)
        view.generation = cache.revision
        coordinator.update(view)
        #expect(coordinator.generation == editingRevision)
        #expect(cell.body.stringValue == "Manual correction")
        coordinator.finishEdit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(capturedEnd == 1)
        #expect(savedText == "Manual correction")
        #expect(coordinator.generation == cache.revision)
        coordinator.tearDown()
    }

    @Test func unidentifiedBeginningKeepsTextWithoutAnEmptyBadge() {
        let cell = TranscriptNativeCell()
        cell.configure(
            TranscriptDisplayRow(id: UUID(), start: 0, end: 1, speaker: "", speakerID: nil, text: "Opening words"),
            showsSpeakers: true)
        #expect(cell.badge.isHidden)
        #expect(cell.body.stringValue == "Opening words")
    }

    @Test func liveRowsUseNativeBadgesAndIndependentAssignmentTargets() {
        let person = Person(name: "Alex")
        var final = LiveTranscriptPhrase(session: UUID(), source: .system, start: 0, end: 2, text: "Final text")
        final.personID = person.id
        let pending = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 3, end: 5, text: "Changing text")
        let rows = LiveTranscriptDisplay.rows(finalized: [final], partials: [pending], people: [person])
        #expect(rows.map(\.speaker) == ["Alex", "mic"])
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
        #expect(deleted[0].speaker == "sys")
        #expect(deleted[0].personID == nil)
    }

    @Test func liveColorsSurviveUnrelatedSpeakerChangesAndRowReplacement() {
        let session = UUID()
        let first = LiveTranscriptPhrase(session: session, source: .microphone, start: 0, end: 1, text: "First.")
        let replacement = LiveTranscriptPhrase(session: session, source: .microphone, start: 1, end: 2, text: "Second")
        let other = LiveTranscriptPhrase(session: UUID(), source: .system, start: 0, end: 1, text: "Other")
        let original = LiveTranscriptDisplay.rows(finalized: [first], partials: [], people: [])[0]
        let expanded = LiveTranscriptDisplay.rows(finalized: [other, first, replacement], partials: [], people: [])
        #expect(original.speakerColorKey != nil)
        #expect(expanded.first { $0.id == first.id }?.speakerColorKey == original.speakerColorKey)
        #expect(expanded.first { $0.id == replacement.id }?.speakerColorKey == original.speakerColorKey)
        #expect(expanded.first { $0.id == replacement.id }?.speakerID == replacement.id)
        var view = NativeTranscriptView(
            rows: [original], generation: 1, showsSpeakers: true, editable: false, canPlay: false,
            meetingID: UUID(), play: { _ in }, save: { _, _ in }, speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let table = TranscriptNativeTable(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        coordinator.update(view)
        let cell = TranscriptNativeCell()
        coordinator.configure(cell, for: original)
        let originalTint = cell.badge.tint
        view.rows = expanded
        view.generation += 1
        coordinator.update(view)
        coordinator.configure(cell, for: expanded.first { $0.id == replacement.id }!)
        #expect(cell.badge.tint == originalTint)
        coordinator.configure(cell, for: expanded.first { $0.id == other.id }!)
        #expect(cell.badge.tint != originalTint)
        coordinator.tearDown()
    }

    @Test func anonymousRowsShareSourceColorIdentityWithoutMergingAssignmentTargets() {
        let first = LiveTranscriptPhrase(session: UUID(), source: .system, start: 0, end: 1, text: "First passage")
        let second = LiveTranscriptPhrase(session: UUID(), source: .system, start: 2, end: 3, text: "Second passage")
        let rows = LiveTranscriptDisplay.rows(finalized: [first, second], partials: [], people: [])
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.phrases = [first, second]
        let savedSpeakers = draft.speakers
        #expect(savedSpeakers.count == 2)
        #expect(savedSpeakers[0].id != savedSpeakers[1].id)
        let savedKey = TranscriptSpeakerPalette.displayKey(
            personID: savedSpeakers[0].personID, track: savedSpeakers[0].track, label: savedSpeakers[0].label)
        #expect(
            savedKey
                == TranscriptSpeakerPalette.displayKey(
                    personID: savedSpeakers[1].personID, track: savedSpeakers[1].track, label: savedSpeakers[1].label))
        #expect(rows[0].speakerColorKey == savedKey)
        #expect(rows[0].speakerColorKey == rows[1].speakerColorKey)
        #expect(savedSpeakers.allSatisfy { $0.colorSlot == rows[0].speakerColorIndex })
        #expect(rows[0].speakerID != rows[1].speakerID)
        #expect(savedKey == TranscriptSpeakerPalette.displayKey(personID: nil, track: "SYS", label: first.speakerLabel))
        let person = UUID()
        #expect(
            TranscriptSpeakerPalette.displayKey(personID: person, track: "system", label: "First")
                == TranscriptSpeakerPalette.displayKey(personID: person, track: "microphone", label: "Another"))
    }

    @Test func liveSpeakerColorsSurviveDraftAdoptionAndReopening() throws {
        let session = UUID()
        let microphone = LiveSpeakerIdentity(
            id: UUID(), source: .microphone, generation: session, slot: 0,
            model: "Synthetic", revision: "1", personID: UUID())
        let system = LiveSpeakerIdentity(
            id: UUID(), source: .system, generation: session, slot: 0,
            model: "Synthetic", revision: "1", personID: UUID())
        var timeline = LiveSpeakerTimeline()
        timeline.speakers = [microphone, system]
        timeline.intervals = [
            .init(speakerID: microphone.id, start: 0, end: 2),
            .init(speakerID: system.id, start: 3, end: 5),
        ]
        let phrases = [
            LiveTranscriptPhrase(session: session, source: .microphone, start: 0, end: 2, text: "First voice."),
            LiveTranscriptPhrase(session: session, source: .system, start: 3, end: 5, text: "Second voice."),
        ]
        let attributed = phrases.flatMap { timeline.attributing($0) }
        let live = LiveTranscriptDisplay.rows(finalized: attributed, partials: [], people: [])
        #expect(Set(live.compactMap(\.speakerColorIndex)).count == 2)
        var draft = LiveTranscriptDraft(meetingID: UUID(), locale: "en")
        draft.effectivePhrases = attributed
        draft.speakerTimeline = timeline
        var meeting = Meeting(title: "Synthetic recording")
        meeting.speakers = draft.speakers
        let saved = MeetingSpeakerColors.assigning(meeting)
        let reopened = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(saved))
        for (index, phrase) in attributed.enumerated() {
            #expect(
                reopened.speakers.first { $0.id == phrase.speakerIdentity }?.colorSlot == live[index].speakerColorIndex)
        }
    }

    @Test func provisionalUnderlineEndsWhenFinalized() {
        var row = TranscriptDisplayRow(
            id: UUID(), start: 0, end: 1, speaker: "Speaker 1", speakerID: UUID(), text: "A changing phrase",
            isProvisional: true, recentWordRanges: [NSRange(location: 2, length: 15)])
        let cell = TranscriptNativeCell()
        cell.configure(row, showsSpeakers: true)
        #expect(
            cell.body.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
                == NSUnderlineStyle.single.rawValue)
        #expect(
            cell.body.attributedStringValue.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
                == NSColor(Color.red))
        row.isProvisional = false
        cell.configure(row, showsSpeakers: true)
        #expect(cell.body.attributedStringValue.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
        #expect(cell.body.attributedStringValue.attribute(.foregroundColor, at: 2, effectiveRange: nil) == nil)
        #expect(cell.body.stringValue == row.text)
    }

    @Test func onlyNewestEnabledPartialHasOriginalTwoColorTrail() {
        let earlier = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 2, text: "Earlier source words")
        let newest = LiveTranscriptPhrase(
            session: UUID(), source: .system, start: 1, end: 3, text: "Newest source words")
        let rows = LiveTranscriptDisplay.rows(finalized: [], partials: [earlier, newest], people: [])
        #expect(rows.first { $0.id == earlier.id }?.recentWordRanges.isEmpty == true)
        let active = rows.first { $0.id == newest.id }!
        #expect(active.recentWordRanges.count == 2)
        let cell = TranscriptNativeCell()
        cell.configure(active, showsSpeakers: true)
        let trailing =
            cell.body.attributedStringValue.attribute(
                .foregroundColor, at: active.recentWordRanges[0].location, effectiveRange: nil) as? NSColor
        let latest =
            cell.body.attributedStringValue.attribute(
                .foregroundColor, at: active.recentWordRanges[1].location, effectiveRange: nil) as? NSColor
        #expect(trailing == TranscriptLiveWordColor.trailing)
        #expect(latest == NSColor(Color.red))
        #expect(trailing != latest)
        let disabled = LiveTranscriptDisplay.rows(
            finalized: [], partials: [earlier, newest], people: [], recognitionEnabled: false)
        #expect(disabled.allSatisfy { $0.recentWordRanges.isEmpty })
        let final = LiveTranscriptDisplay.rows(finalized: [newest], partials: [], people: [])
        #expect(final[0].recentWordRanges.isEmpty)
    }

    @Test func liveTimestampDoesNotAdvertisePlayback() {
        let row = TranscriptDisplayRow(id: UUID(), start: 3, end: 4, speaker: "", speakerID: nil, text: "Example")
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
        let row = TranscriptDisplayRow(id: id, start: 0, end: 1, speaker: "", speakerID: nil, text: "Original")
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
        view.rows = [
            TranscriptDisplayRow(id: id, start: 0, end: 1, speaker: "", speakerID: nil, text: "Automatic revision")
        ]
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

    @Test func nativeRefreshSkipsUnchangedRowsAndReloadsOnlyRevisedRow() {
        let first = TranscriptDisplayRow(id: UUID(), start: 0, end: 1, speaker: "", speakerID: nil, text: "First")
        let second = TranscriptDisplayRow(id: UUID(), start: 1, end: 2, speaker: "", speakerID: nil, text: "Second")
        var view = NativeTranscriptView(
            rows: [first, second], generation: 1, showsSpeakers: false,
            editable: true, canPlay: false, followsLive: false, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        let coordinator = NativeTranscriptView.Coordinator(view)
        let table = ReloadTrackingTranscriptTable()
        table.addTableColumn(NSTableColumn(identifier: .init("transcript")))
        table.dataSource = coordinator
        coordinator.table = table
        coordinator.update(view)
        let initialReloads = table.fullReloads
        view.generation += 1
        coordinator.update(view)
        #expect(table.fullReloads == initialReloads)
        #expect(table.changedRows.isEmpty)
        view.rows[1] = TranscriptDisplayRow(
            id: second.id, start: 1, end: 2, speaker: "", speakerID: nil, text: "Revised")
        view.generation += 1
        coordinator.update(view)
        #expect(table.fullReloads == initialReloads)
        #expect(table.changedRows == IndexSet(integer: 1))
        coordinator.tearDown()
    }

    @Test func followRemainsPausedUntilExplicitlyEnabled() {
        var pauses = 0
        var view = NativeTranscriptView(
            rows: (0..<100).map {
                TranscriptDisplayRow(
                    id: UUID(), start: Double($0), end: Double($0) + 1, speaker: "", speakerID: nil, text: "Line \($0)")
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

@MainActor private final class ReloadTrackingTranscriptTable: TranscriptNativeTable {
    var fullReloads = 0
    var changedRows = IndexSet()
    override func reloadData() {
        fullReloads += 1
        super.reloadData()
    }
    override func reloadData(forRowIndexes rows: IndexSet, columnIndexes columns: IndexSet) {
        changedRows.formUnion(rows)
        super.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }
}
