import AppKit
import SwiftUI
import Testing

@testable import GdayMeetings

@MainActor struct TranscriptLayoutServiceTests {
    private func input(meeting: UUID, row: UUID = UUID(), text: String = "Synthetic passage.", width: CGFloat = 200)
        -> TranscriptMeasurementInput
    {
        let display = TranscriptDisplayRow(id: row, start: 0, end: 1, speaker: "Speaker", speakerID: nil, text: text)
        return .init(
            key: .init(
                meetingID: meeting, rowID: row, textRevision: display.textRevision,
                effectiveWidth: width, typographyVersion: 1, layoutVersion: 2), text: text)
    }
    @Test func warmPagesReuseHeightsWithoutRetainingTablesOrMeasuringAgain() async {
        let service = TranscriptLayoutService()
        let meeting = UUID()
        let page = UUID()
        let inputs = (0..<40).map { _ in input(meeting: meeting) }
        var publications = 0
        service.activate(page) { _ in publications += 1 }
        service.request(inputs, owner: page)
        await service.waitUntilIdle()
        #expect(service.statistics.measurements == 40)
        #expect(publications == 3)
        service.deactivate(page)
        let next = UUID()
        service.activate(next) { _ in }
        service.request(inputs, owner: next)
        await service.waitUntilIdle()
        #expect(service.statistics.measurements == 40)
        #expect(inputs.allSatisfy { service.height(for: $0.key) != nil })
    }
    @Test func revisionsWidthsAndMeetingsAreIndependent() async {
        let service = TranscriptLayoutService(widthsPerRow: 2)
        let meeting = UUID()
        let row = UUID()
        let owner = UUID()
        service.activate(owner) { _ in }
        let a = input(meeting: meeting, row: row)
        let b = input(meeting: meeting, row: row, text: "Changed synthetic passage.")
        let c = input(meeting: meeting, row: row, width: 201)
        service.request([a, b, c], owner: owner)
        await service.waitUntilIdle()
        #expect(service.entryCount == 2)
        #expect(service.height(for: a.key) == nil)
        #expect(service.height(for: b.key) != nil)
        #expect(service.height(for: input(meeting: UUID(), row: row).key) == nil)
        service.remove(meetingID: meeting)
        #expect(service.entryCount == 0)
    }
    @Test func rapidNavigationKeepsQueueBoundedAndPublishesOnlyLatestPage() async {
        let service = TranscriptLayoutService(pendingByteBudget: 16_000, pendingCountLimit: 8, batchSize: 2)
        var obsoletePublications = 0
        for _ in 0..<100 {
            let owner = UUID()
            service.activate(owner) { _ in obsoletePublications += 1 }
            service.request(
                (0..<100).map { _ in input(meeting: UUID(), text: String(repeating: "Synthetic text. ", count: 100)) },
                owner: owner)
            #expect(service.pendingCount <= 8)
            #expect(service.pendingBytes <= 16_000)
        }
        let latest = UUID()
        let measurement = input(meeting: UUID())
        var latestPublications = 0
        service.activate(latest) { _ in latestPublications += 1 }
        service.request([measurement], owner: latest)
        await service.waitUntilIdle()
        #expect(obsoletePublications == 0)
        #expect(latestPublications == 1)
        #expect(service.height(for: measurement.key) != nil)
    }
    @Test func freshLongMeetingTablesReuseWindowMeasurementsAndKeepDelegateCheap() async {
        let service = TranscriptLayoutService()
        let meeting = UUID()
        let rows = (0..<10_000).map {
            TranscriptDisplayRow(
                id: UUID(), start: Double($0), end: Double($0 + 1), speaker: "Speaker", speakerID: nil,
                text: "A synthetic transcript passage used to validate navigation.")
        }
        let view = NativeTranscriptView(
            rows: rows, layoutService: service, generation: 1, showsSpeakers: true,
            editable: true, canPlay: true, meetingID: meeting, play: { _ in }, save: { _, _ in },
            speakerPicker: { _, _ in AnyView(EmptyView()) })
        func tablePage() -> (NSScrollView, TranscriptNativeTable, NativeTranscriptView.Coordinator) {
            let scroll = TranscriptNativeScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            let table = TranscriptNativeTable(frame: scroll.bounds)
            let column = NSTableColumn(identifier: .init("transcript"))
            column.width = 600
            table.addTableColumn(column)
            table.usesAutomaticRowHeights = false
            let coordinator = NativeTranscriptView.Coordinator(view)
            coordinator.table = table
            table.dataSource = coordinator
            table.delegate = coordinator
            scroll.documentView = table
            coordinator.update(view)
            coordinator.settleLayout()
            return (scroll, table, coordinator)
        }
        let (coldScroll, coldTable, cold) = tablePage()
        // Every row callback must remain a lookup, even for an uncached transcript.
        for index in rows.indices { _ = cold.tableView(coldTable, heightOfRow: index) }
        #expect(service.statistics.measurements == 0)
        cold.requestVisibleMeasurements()
        await service.waitUntilIdle()
        let measured = service.statistics.measurements
        #expect(measured > 0 && measured < 128)
        let height = cold.tableView(coldTable, heightOfRow: 0)
        cold.tearDown()
        let (warmScroll, warmTable, warm) = tablePage()
        #expect(coldTable !== warmTable)
        #expect(cold !== warm)
        #expect(warm.tableView(warmTable, heightOfRow: 0) == height)
        #expect(service.statistics.measurements == measured)
        print(
            "Transcript fixture: rows=10000 delegateMeasurements=0 coldMeasurements=\(measured) warmAdditionalMeasurements=0 peakPendingCount=\(service.statistics.peakPendingCount) peakPendingBytes=\(service.statistics.peakPendingBytes) estimatedCacheBytes=\(service.estimatedBytes)"
        )
        warm.tearDown()
        _ = coldScroll
        _ = warmScroll
    }
    @Test func removedRowsCannotReturnFromAnObsoleteBatch() async {
        let service = TranscriptLayoutService()
        let owner = UUID()
        let meeting = UUID()
        let measurement = input(meeting: meeting)
        service.activate(owner) { _ in Issue.record("Removed row must not publish") }
        service.request([measurement], owner: owner)
        service.invalidate(meetingID: meeting, retaining: [])
        await service.waitUntilIdle()
        #expect(service.height(for: measurement.key) == nil)
        #expect(service.entryCount == 0)
    }
    @Test func oversizedRowRunsAloneWithoutRetainingAnotherQueue() async {
        let service = TranscriptLayoutService(pendingByteBudget: 512, batchSize: 16)
        let owner = UUID()
        let meeting = UUID()
        let oversized = input(meeting: meeting, text: String(repeating: "Synthetic paragraph. ", count: 200))
        service.activate(owner) { _ in }
        service.request([oversized, input(meeting: meeting)], owner: owner)
        #expect(service.pendingCount == 1)
        #expect(service.pendingBytes == oversized.estimatedBytes)
        await service.waitUntilIdle()
        #expect(service.statistics.measurements == 1)
        #expect(service.height(for: oversized.key) != nil)
    }
    @Test func cancelledByteFullBatchRequestsLatestViewportAgain() async {
        let service = TranscriptLayoutService(pendingByteBudget: 256, batchSize: 1)
        let owner = UUID()
        let meeting = UUID()
        let old = input(meeting: meeting, text: String(repeating: "Old synthetic text. ", count: 20))
        let latest = input(meeting: meeting)
        var retries = 0
        service.activate(
            owner,
            retry: {
                retries += 1
                service.request([latest], owner: owner)
            }
        ) { _ in }
        service.request([old], owner: owner)
        service.request([latest], owner: owner)
        await service.waitUntilIdle()
        #expect(retries == 1)
        #expect(service.height(for: latest.key) != nil)
        #expect(service.pendingCount == 0)
    }
    @Test func closedForegroundPageAllowsBackgroundOwnerToResume() async {
        let service = TranscriptLayoutService()
        let background = UUID()
        let foreground = UUID()
        service.activate(background) { _ in }
        service.activate(foreground) { _ in }
        #expect(!service.isAvailable(to: background))
        service.deactivate(foreground)
        #expect(service.isAvailable(to: background))
        let measurement = input(meeting: UUID())
        service.activate(background) { _ in }
        service.request([measurement], owner: background)
        await service.waitUntilIdle()
        #expect(service.height(for: measurement.key) != nil)
    }
    @Test func estimatedBudgetAndWidthVariantsRemainBounded() async {
        let service = TranscriptLayoutService(budget: 256 * 8, widthsPerRow: 2)
        let owner = UUID()
        let meeting = UUID()
        let row = UUID()
        service.activate(owner) { _ in }
        for width in 100..<120 {
            service.request([input(meeting: meeting, row: row, width: CGFloat(width))], owner: owner)
            await service.waitUntilIdle()
            #expect(service.entryCount <= 2)
        }
        service.request((0..<40).map { _ in input(meeting: meeting) }, owner: owner)
        await service.waitUntilIdle()
        #expect(service.estimatedBytes <= 256 * 8)
        service.deactivate(owner)
        service.discardInactive()
        #expect(service.entryCount == 0)
    }
    @Test func measurementMatchesNativeFieldAcrossLanguagesAndWrapBoundaries() async {
        let service = TranscriptLayoutService(widthsPerRow: 100)
        let owner = UUID()
        let meeting = UUID()
        service.activate(owner) { _ in }
        for text in [
            "Words near a wrapping boundary.", "示例文字用于检查换行。", "مرحبا بالعالم", "Emoji 👩🏽‍💻 sample", "First\nSecond",
            "First\rSecond", "First\u{2028}Second", "", "a\tb",
        ] {
            for width in [CGFloat(40), 75, 125, 125.5, 126, 250] {
                let measurement = input(meeting: meeting, text: text, width: width)
                service.request([measurement], owner: owner)
                await service.waitUntilIdle()
                let field = TranscriptNativeCell().body
                field.stringValue = text
                let size = field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 100_000))
                let native = max(20, ceil(size.height) + 2) + 8
                #expect(
                    service.height(for: measurement.key) == native, "Native field metrics must match for width \(width)"
                )
            }
        }
    }
}
