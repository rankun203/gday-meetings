// Append only to the isolated copy of LibrarySearchResultsView.swift.
// Direct table inputs intentionally bypass the coordinator's user-facing result cap.
@MainActor
func nativeMeasureSearchTableLayout(count: Int) -> [String: Double] {
    let session = LibrarySearchSession()
    session.finishPeopleOnly()
    let rows = (0..<count).map { number in
        let id = UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", number))!
        let passage = LibrarySearchResult(
            id: Int64(number), meetingID: id, title: "Synthetic planning meeting",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), kind: .transcript,
            segmentID: nil, start: Double(number * 15),
            excerpt:
                "Review the release plan and confirm the next testing steps. Share the updated schedule after the discussion."
        )
        return SearchDisplayResult(
            id: String(number), meetingID: id, title: passage.title, excerpt: passage.excerpt,
            createdAt: passage.createdAt, passage: passage, audio: nil)
    }
    let summaries = Dictionary(
        uniqueKeysWithValues: rows.map { ($0.meetingID, "Release planning and testing schedule") })
    let start = ContinuousClock.now
    let view = NativeSearchResults(
        session: session, results: rows, generation: UUID(), showRankingDetails: false,
        summaries: summaries, playableMeetings: Set(rows.map(\.meetingID)), canPlay: true,
        open: { _ in }, play: { _ in })
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
    let window = NSWindow(
        contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    func table(in view: NSView) -> NSTableView? {
        if let result = view as? NSTableView { return result }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
    guard let table = table(in: host) else {
        preconditionFailure("Native search table was not materialized")
    }
    table.layoutSubtreeIfNeeded()
    let elapsed = start.duration(to: .now).components
    let cells = (0..<table.numberOfRows).filter {
        table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil
    }.count
    let replacement = NativeSearchResults(
        session: session, results: rows, generation: UUID(), showRankingDetails: false,
        summaries: summaries, playableMeetings: Set(rows.map(\.meetingID)), canPlay: true,
        open: { _ in }, play: { _ in })
    let updateStart = ContinuousClock.now
    (table.delegate as! NativeSearchResults.Coordinator).update(replacement)
    let updateElapsed = updateStart.duration(to: .now).components
    let result = [
        "count": Double(count),
        "milliseconds": Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
        "tableReloadMilliseconds": Double(updateElapsed.seconds) * 1000 + Double(updateElapsed.attoseconds) / 1e15,
        "tableRows": Double(table.numberOfRows), "materializedCells": Double(cells),
        "viewportWidth": 1280.0, "viewportHeight": 720.0,
    ]
    window.contentView = nil
    window.close()
    return result
}
