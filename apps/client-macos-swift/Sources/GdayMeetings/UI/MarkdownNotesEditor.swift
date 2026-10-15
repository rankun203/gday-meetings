import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum NotesTimestampGutter {
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let minimumWidth = width(hourDigits: 2)

    static func width(hourDigits: Int) -> CGFloat {
        // Reserve two hour digits before recording reaches an hour,
        // so crossing that boundary does not shift the notes or image previews.
        let button = MarkdownActionButton(
            title: String(repeating: "9", count: max(2, hourDigits)) + ":59:59", target: nil, action: nil)
        button.isBordered = false
        button.font = font
        return ceil(button.cell?.cellSize.width ?? button.intrinsicContentSize.width) + 2
    }
}

struct MeetingNotesEditor: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    var showsPanelBorder = true
    var editingEnabled = true
    var body: some View {
        NotesDraftEditor(
            draft: store.notesStorage.draft(meetingID, fallback: store.meeting(id: meetingID)?.notes ?? ""),
            editor: MarkdownNotesEditor(
                meetingID: meetingID,
                markdown: "",
                editable: store.libraryWritable && editingEnabled,
                clock: {
                    NotesDocument.clock(
                        recording: store.recordingID == meetingID ? store.recordingDuration : nil,
                        playback: playback.meetingID == meetingID ? playback.progress.time : nil)
                },
                playbackTime: { playback.meetingID == meetingID ? playback.progress.time : nil },
                canPlay: {
                    !playback.isPlaybackBlocked
                        && !(store.meetings.first { $0.id == meetingID }?.audioFiles.isEmpty ?? true)
                },
                play: { time in
                    guard let meeting = store.meetings.first(where: { $0.id == meetingID }) else { return }
                    playback.play(
                        meeting: meeting, files: store.audioURLs(for: meeting), at: NotesDocument.playbackStart(time))
                },
                changed: { store.editNotes(id: meetingID, text: $0) }, flush: { Task { await store.flushNotes() } },
                directory: store.directory(for: meetingID), imageError: { store.errorMessage = $0 },
                audioDrop: { urls in
                    Task {
                        do { _ = try await store.importAudioFiles(urls) }
                        catch { store.errorMessage = error.localizedDescription }
                    }
                }
            )
        )
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(
                Color(nsColor: .separatorColor).opacity(showsPanelBorder ? 0.6 : 0))
        )
        .onDisappear { Task { await store.flushNotes() } }
        .id(meetingID)
    }
}

private struct NotesDraftEditor: View {
    @ObservedObject var draft: NotesDraft
    var editor: MarkdownNotesEditor
    var body: some View {
        var value = editor
        value.markdown = draft.text
        value.registerPreparation = { draft.prepareForSave = $0 }
        return value
    }
}

struct MarkdownNotesEditor: NSViewRepresentable {
    let meetingID: UUID
    var markdown: String
    var editable: Bool
    var clock: () -> TimeInterval?
    var playbackTime: () -> TimeInterval? = { nil }
    var canPlay: () -> Bool
    var play: (TimeInterval) -> Void
    var changed: (String) -> Void
    var flush: () -> Void
    var directory: URL? = nil
    var imageError: (String) -> Void = { _ in }
    var audioDrop: ([URL]) -> Void = { _ in }
    var registerPreparation: (@escaping @MainActor () async -> Void) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NotesTextView(usingTextLayoutManager: true)
        text.isRichText = false
        text.importsGraphics = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.allowsUndo = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: NotesTimestampGutter.minimumWidth + 6, height: 12)
        text.drawsBackground = false
        text.setAccessibilityLabel("Meeting Notes")
        text.editor = self
        registerPreparation { [weak text] in await text?.prepareImagesForSave() }
        text.registerForDraggedTypes(Array(Set(text.registeredDraggedTypes + [.fileURL, .png, .tiff])))
        text.load(markdown)
        text.delegate = text
        text.textStorage?.delegate = text
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NotesTextView else { return }
        update(text)
    }
    func update(_ text: NotesTextView) {
        text.editor = self
        if text.isEditable != editable { text.isEditable = editable }
        if !editable, text.window?.firstResponder === text {
            text.window?.makeFirstResponder(nil)
        }
        if text.document.markdown != markdown, !text.hasMarkedText() { text.load(markdown) }
        text.refreshPlaybackAvailability()
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        guard let text = scroll.documentView as? NotesTextView else { return }
        // Retain this meeting's editor until its final save completes, but do not
        // publish notes or errors while SwiftUI is dismantling its view graph.
        DispatchQueue.main.async { text.finishEditingSession() }
    }
}

final class NotesTextView: NSTextView, NSTextViewDelegate, NSTextStorageDelegate {
    var editor: MarkdownNotesEditor?
    var document = NotesDocument("") {
        didSet { cachedLineIndex = nil }
    }
    private var cachedLineIndex: NotesEditorLineIndex?
    var lineLayoutIndex: NotesEditorLineIndex {
        if let cachedLineIndex { return cachedLineIndex }
        let index = NotesEditorLineIndex(document)
        cachedLineIndex = index
        return index
    }
    var notesPasteboard = NSPasteboard.general
    private var needsFullStyle = true
    private var pendingStyleRange: NSRange?
    private var imageLayoutScheduled = false
    lazy var images = NotesImagePresentation(text: self)
    var lastInsertionDate: Date?
    private var imageSaveTask: Task<Void, Never>?
    private var normalizingImages = false
    private var imagePreparationTask: Task<Void, Never>?
    private var imageNormalizationTask: Task<Void, Never>?
    private var imageUserOperation = false
    private var imagePreparationRevision = UUID()
    private var gutterButtons: [NSButton] = []
    private var gutterHourDigits = 2
    private var gutterWidth = NotesTimestampGutter.minimumWidth
    private var gutterTimes: [ObjectIdentifier: TimeInterval] = [:]
    private var gutterPlaybackAvailable = false
    private var notesTrackingArea: NSTrackingArea?
    private static let pasteType = NSPasteboard.PasteboardType("com.gdaymeetings.timed-notes")
    private struct Clipboard: Codable {
        var meetingID: UUID
        var markdown: String
    }

    func refreshPlaybackAvailability() {
        let available = editor?.canPlay() == true
        guard available != gutterPlaybackAvailable else { return }
        gutterPlaybackAvailable = available
        for button in gutterButtons { button.isEnabled = available }
    }

    func load(_ markdown: String) {
        undoManager?.removeAllActions()
        lastInsertionDate = nil
        imageSaveTask?.cancel()
        imagePreparationTask?.cancel()
        imageNormalizationTask?.cancel()
        imageUserOperation = false
        imagePreparationRevision = UUID()
        document = NotesDocument(markdown)
        images.invalidate()
        textStorage?.delegate = self
        needsFullStyle = true
        pendingStyleRange = nil
        string = document.text
        scheduleImageLayout()
        needsLayout = true
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?)
        -> Bool
    {
        guard let replacementString else { return true }
        images.willChange(affectedCharRange, replacement: replacementString)
        let previous = document
        let now = Date()
        let phraseClock =
            affectedCharRange.length == 0 && !replacementString.isEmpty
                && lastInsertionDate.map { now.timeIntervalSince($0) >= 15 } == true ? editor?.clock() : nil
        document.replace(affectedCharRange, with: replacementString, clock: editor?.clock(), phraseClock: phraseClock)
        if !replacementString.isEmpty, undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            lastInsertionDate = now
        }
        if undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            registerDocumentUndo(previous)
        }
        return true
    }
    private func registerDocumentUndo(_ value: NotesDocument) {
        undoManager?.registerUndo(withTarget: self) { target in
            let current = target.document
            target.document = value
            target.registerDocumentUndo(current)
            target.editor?.changed(value.markdown)
            target.needsLayout = true
        }
    }
    func textDidChange(_ notification: Notification) {
        // Native undo owns text mutations. The companion undo action restores
        // timeline metadata in the same undo group.
        images.didChangeText()
        editor?.changed(document.markdown)
        needsLayout = true
        imageSaveTask?.cancel()
        if !normalizingImages, undoManager?.isUndoing != true, undoManager?.isRedoing != true {
            imageSaveTask?.cancel()
            imageSaveTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch { return }
                self?.normalizeImageWidths()
            }
        }
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            normalizeImageWidths()
            editor?.flush()
        }
        return result
    }
    private static var expressions: [String: NSRegularExpression] = [:]
    private func style(_ range: NSRange) {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttributes(
            [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor],
            range: range)
        let source = storage.string as NSString
        let patterns: [(String, [NSAttributedString.Key: Any])] = [
            (#"(?m)^#{1,6} .+$"#, [.font: NSFont.boldSystemFont(ofSize: 18)]),
            (#"\*\*[^\n*]+\*\*"#, [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]),
            (
                #"(?<!\*)\*[^\n*]+\*(?!\*)"#,
                [
                    .font: NSFontManager.shared.convert(
                        NSFont.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
                ]
            ),
            (#"`[^\n`]+`"#, [.font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)]),
            (#"(?m)^> .+$"#, [.foregroundColor: NSColor.secondaryLabelColor]),
            (#"\[[^\]\n]+\]\([^\)\n]+\)"#, [.foregroundColor: NSColor.linkColor]),
            (#"(?m)^(?:#{1,6}|>|[-+*]|\d+\.) |\*\*|`|\[[ xX]\]"#, [.foregroundColor: NSColor.secondaryLabelColor]),
        ]
        for (pattern, attributes) in patterns {
            guard let expression = Self.expressions[pattern] ?? (try? NSRegularExpression(pattern: pattern)) else {
                continue
            }
            Self.expressions[pattern] = expression
            for match in expression.matches(in: source as String, range: range) {
                storage.addAttributes(attributes, range: match.range)
            }
        }
        typingAttributes = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: NSParagraphStyle.default,
        ]
    }
    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !needsFullStyle else { return }
        // NSTextStorage may combine several edits. Treat its range as a
        // conservative styling boundary, never as an exact replacement.
        var affected = editedRange
        if let pending = pendingStyleRange {
            let oldEnd = NSMaxRange(editedRange) - delta
            let start =
                pending.location <= editedRange.location
                ? pending.location : max(editedRange.location, pending.location + delta)
            let end =
                NSMaxRange(pending) >= oldEnd
                ? NSMaxRange(pending) + delta : max(NSMaxRange(pending), NSMaxRange(editedRange))
            affected = NSUnionRange(affected, NSRange(location: start, length: max(0, end - start)))
        }
        pendingStyleRange = affected
    }
    func prepareImageLayout() {
        guard let content = textLayoutManager?.textContentManager, let storage = textStorage else { return }
        if storage.delegate !== self {
            storage.delegate = self
            needsFullStyle = true
        }
        if needsFullStyle || pendingStyleRange != nil {
            let current = storage.string as NSString
            let dirty = pendingStyleRange ?? NSRange(location: 0, length: current.length)
            let start = min(dirty.location, current.length)
            let length = min(dirty.length, current.length - start)
            let range =
                needsFullStyle
                ? NSRange(location: 0, length: current.length)
                : current.paragraphRange(for: NSRange(location: start, length: length))
            needsFullStyle = false
            pendingStyleRange = nil
            if range.length > 0 {
                content.performEditingTransaction {
                    storage.beginEditing()
                    style(range)
                    storage.endEditing()
                }
            }
        }
        images.prepare()
    }
    private func scheduleImageLayout() {
        guard !imageLayoutScheduled else { return }
        imageLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageLayoutScheduled = false
            self.prepareImageLayout()
        }
    }
    override func layout() {
        let tenths = Int((min(1_000_000_000_000, lineLayoutIndex.latestTimestamp) * 10).rounded())
        let hourDigits = max(2, String(tenths / 36_000).count)
        if hourDigits != gutterHourDigits {
            gutterHourDigits = hourDigits
            gutterWidth = NotesTimestampGutter.width(hourDigits: hourDigits)
        }
        let inset = gutterWidth + 6
        if textContainerInset.width != inset {
            textContainerInset.width = inset
        }
        // Mutating paragraph attributes inside viewport layout leaves TextKit's
        // fragments with stale ranges after a large replacement.
        scheduleImageLayout()
        super.layout()
        images.layout()
        updateGutter()
    }
    private func updateGutter() {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return }
        gutterPlaybackAvailable = editor?.canPlay() == true
        var labels: [(NSRect, TimeInterval, Int)] = []
        let lineIndex = lineLayoutIndex
        let visible = visibleRect
        manager.enumerateTextLayoutFragments(
            from: manager.textViewportLayoutController.viewportRange?.location, options: []
        ) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = lineIndex.line(at: offset)
            let rect = fragment.layoutFragmentFrame.offsetBy(
                dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            if rect.minY > visible.maxY { return false }
            if rect.intersects(visible), let time = self.document.lines[line].time,
                offset == lineIndex.start(of: line)
            {
                labels.append((NSRect(x: 2, y: rect.minY, width: self.gutterWidth, height: 20), time, line))
            }
            return true
        }
        while gutterButtons.count < labels.count {
            let button = MarkdownActionButton(title: "", target: self, action: #selector(playGutter(_:)))
            button.isBordered = false
            button.font = NotesTimestampGutter.font
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "Play from this point"
            addSubview(button)
            gutterButtons.append(button)
        }
        gutterTimes.removeAll(keepingCapacity: true)
        for (index, button) in gutterButtons.enumerated() {
            button.isHidden = index >= labels.count
            guard index < labels.count else { continue }
            let (rect, time, lineIndex) = labels[index]
            button.tag = lineIndex
            button.frame = rect
            button.title = NotesDocument.displayTimestamp(time)
            button.isEnabled = gutterPlaybackAvailable
            button.setAccessibilityLabel("Play from \(Int(time) / 60) minutes \(Int(time) % 60) seconds")
            gutterTimes[ObjectIdentifier(button)] = time
        }
    }
    @objc private func playGutter(_ sender: NSButton) {
        guard editor?.canPlay() == true, let time = gutterTimes[ObjectIdentifier(sender)] else { return }
        editor?.play(time)
    }
    @objc func playFromLine(_ sender: Any?) {
        guard editor?.canPlay() == true,
            let time = document.time(atLine: document.lineIndex(at: selectedRange().location))
        else { return }
        editor?.play(time)
    }
    @objc func setTimeToPlayback(_ sender: Any?) {
        guard let time = editor?.playbackTime(), isEditable else { return }
        registerDocumentUndo(document)
        let selected = selectedRange()
        for line in document.lineIndex(at: selected.location)...document.lineIndex(at: NSMaxRange(selected)) {
            document.setTime(time, line: line)
        }
        editor?.changed(document.markdown)
        needsLayout = true
    }
    override func accessibilityChildren() -> [Any]? {
        (super.accessibilityChildren() ?? []) + gutterButtons.filter { !$0.isHidden } + images.views
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [
            NSAccessibilityCustomAction(
                name: "Play From Line",
                handler: { [weak self] in
                    guard let self, self.editor?.canPlay() == true else { return false }
                    self.playFromLine(nil)
                    return true
                })
        ]
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let position = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            // Let a Command-drag keep AppKit's selection behavior.
            if let next = window?.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking,
                dequeue: false), next.type == .leftMouseUp
            {
                _ = window?.nextEvent(matching: .leftMouseUp)
                if editor?.canPlay() == true, let time = document.time(at: position) {
                    editor?.play(time)
                }
                return
            }
        }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if let checkbox = taskMarker(at: index) {
            let checked = (string as NSString).substring(with: checkbox).lowercased() == "[x]"
            insertText(checked ? "[ ]" : "[x]", replacementRange: checkbox)
            return
        }
        super.mouseDown(with: event)
    }
    private static let taskMarkerExpression = try? NSRegularExpression(pattern: #"^\s*[-+*] (\[[ xX]\]) "#)
    private func taskMarker(at index: Int) -> NSRange? {
        guard isEditable else { return nil }
        let lineIndex = document.lineIndex(at: index)
        guard document.lines.indices.contains(lineIndex) else { return nil }
        let line = document.lines[lineIndex].text as NSString
        if let expression = Self.taskMarkerExpression,
            let match = expression.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
        {
            let checkbox = NSRange(
                location: document.range(of: lineIndex).location + match.range(at: 1).location, length: 3)
            if NSLocationInRange(index, checkbox) { return checkbox }
        }
        return nil
    }
    override func cursorUpdate(with event: NSEvent) {
        if updateImageCursor(event) { return }
        super.cursorUpdate(with: event)
        updateTimelineHover(event)
    }
    override func updateTrackingAreas() {
        if let notesTrackingArea { removeTrackingArea(notesTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        notesTrackingArea = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) {
        if updateImageCursor(event) { return }
        super.mouseMoved(with: event)
        updateTimelineHover(event)
    }
    override func flagsChanged(with event: NSEvent) {
        if updateImageCursor(event) { return }
        super.flagsChanged(with: event)
        updateTimelineHover(event)
    }
    override func mouseExited(with event: NSEvent) {
        gutterButtons.forEach { $0.highlight(false) }
        super.mouseExited(with: event)
    }
    private func hoverPosition(_ event: NSEvent) -> NSPoint {
        let location =
            event.type == .flagsChanged
            ? (window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow) : event.locationInWindow
        return convert(location, from: nil)
    }
    private func updateImageCursor(_ event: NSEvent) -> Bool {
        guard images.setImageCursor(at: hoverPosition(event)) else { return false }
        gutterButtons.forEach { $0.highlight(false) }
        return true
    }
    private func updateTimelineHover(_ event: NSEvent) {
        let position = hoverPosition(event)
        let index = characterIndexForInsertion(at: position)
        let time =
            event.modifierFlags.contains(.command) && editor?.canPlay() == true
            ? document.time(at: index) : nil
        for button in gutterButtons {
            button.highlight(time != nil && button.tag == document.timedLine(for: document.lineIndex(at: index)))
        }
        let overButton = gutterButtons.contains { !$0.isHidden && $0.isEnabled && $0.frame.contains(position) }
        if time != nil || overButton || taskMarker(at: index) != nil {
            NSCursor.pointingHand.set()
        }
        else {
            NSCursor.iBeam.set()
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            playFromLine(nil)
            return
        }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        menu.addItem(.separator())
        let play = NSMenuItem(title: "Play From Line", action: #selector(playFromLine(_:)), keyEquivalent: "\r")
        play.keyEquivalentModifierMask = [.command]
        play.target = self
        menu.addItem(play)
        let time = NSMenuItem(
            title: "Set Time to Playback Position", action: #selector(setTimeToPlayback(_:)), keyEquivalent: "")
        time.target = self
        menu.addItem(time)
        return menu
    }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        Array(Set(super.readablePasteboardTypes + [.png, .tiff, .fileURL, Self.pasteType]))
    }
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)), isEditable,
            notesPasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
                || notesPasteboard.availableType(from: [.png, .tiff, Self.pasteType]) != nil
        {
            return true
        }
        if menuItem.action == #selector(playFromLine(_:)) {
            return editor?.canPlay() == true
                && document.time(atLine: document.lineIndex(at: selectedRange().location)) != nil
        }
        if menuItem.action == #selector(setTimeToPlayback(_:)) { return isEditable && editor?.playbackTime() != nil }
        return super.validateMenuItem(menuItem)
    }
    @objc func markdownBold(_ sender: Any?) { wrapSelection("**") }
    @objc func markdownItalic(_ sender: Any?) { wrapSelection("*") }
    private func wrapSelection(_ delimiter: String) {
        let selected = selectedRange()
        let value = (string as NSString).substring(with: selected)
        let replacement =
            value.hasPrefix(delimiter) && value.hasSuffix(delimiter) && value.count >= delimiter.count * 2
            ? String(value.dropFirst(delimiter.count).dropLast(delimiter.count)) : delimiter + value + delimiter
        insertText(replacement, replacementRange: selected)
    }
    @objc func markdownLink(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.addButton(withTitle: "Add Link")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://example.com"
        field.setAccessibilityLabel("Link address")
        alert.accessoryView = field
        guard let window else { return }
        let selected = selectedRange()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let label = (self.string as NSString).substring(with: selected)
            self.insertText("[\(label)](\(field.stringValue))", replacementRange: selected)
        }
    }
    override func insertNewline(_ sender: Any?) {
        let selected = selectedRange()
        let line = document.lines[document.lineIndex(at: selected.location)].text
        if let regex = try? NSRegularExpression(pattern: #"^(\s*)([-+*]|\d+\.)( \[[ xX]\])? "#),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        {
            let prefix = (line as NSString).substring(with: match.range)
            if line == prefix {
                insertText("", replacementRange: document.range(of: document.lineIndex(at: selected.location)))
            }
            else {
                var continued = prefix.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(
                    of: "[X]", with: "[ ]")
                let bullet = (line as NSString).substring(with: match.range(at: 2))
                if let number = Int(bullet.dropLast()), number < Int.max, bullet.hasSuffix(".") {
                    continued = continued.replacingOccurrences(of: bullet, with: "\(number + 1).")
                }
                insertText("\n" + continued, replacementRange: selected)
            }
            return
        }
        super.insertNewline(sender)
    }
    override func insertTab(_ sender: Any?) { indent(outdent: false) }
    override func insertBacktab(_ sender: Any?) { indent(outdent: true) }
    private func indent(outdent: Bool) {
        let index = document.lineIndex(at: selectedRange().location)
        let line = document.lines[index].text
        if line.range(of: #"^\s*(?:[-+*]|\d+\.) "#, options: .regularExpression) == nil {
            if outdent {
                super.insertBacktab(nil)
            }
            else {
                super.insertTab(nil)
            }
            return
        }
        let range = document.range(of: index)
        if outdent {
            let count = line.hasPrefix("    ") ? 4 : line.hasPrefix("\t") ? 1 : 0
            insertText("", replacementRange: NSRange(location: range.location, length: count))
        }
        else {
            insertText("    ", replacementRange: NSRange(location: range.location, length: 0))
        }
    }
    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let text = (string as NSString).substring(with: range)
        let copied = document.slice(range)
        notesPasteboard.clearContents()
        notesPasteboard.setString(text, forType: .string)
        if let meetingID = editor?.meetingID,
            let data = try? JSONEncoder().encode(Clipboard(meetingID: meetingID, markdown: copied.markdown))
        {
            notesPasteboard.setData(data, forType: Self.pasteType)
        }
    }
    override func cut(_ sender: Any?) {
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }
    override func paste(_ sender: Any?) {
        if let data = notesPasteboard.data(forType: Self.pasteType),
            let payload = try? JSONDecoder().decode(Clipboard.self, from: data)
        {
            var content = payload.markdown
            if payload.meetingID != editor?.meetingID, let destination = editor?.directory {
                let source = destination.deletingLastPathComponent().appendingPathComponent(
                    payload.meetingID.uuidString)
                do { content = try NotesImageClipboard.copyAssets(in: content, from: source, to: destination) }
                catch {
                    editor?.imageError(error.localizedDescription)
                    return
                }
            }
            let pasted = NotesDocument(content)
            let insertion = selectedRange().location
            insertText(pasted.text, replacementRange: selectedRange())
            if payload.meetingID == editor?.meetingID {
                document.applyCopiedTimes(pasted, at: insertion)
                editor?.changed(document.markdown)
                needsLayout = true
            }
        }
        else if pasteImages(from: notesPasteboard) {
            return
        }
        else if let value = notesPasteboard.string(forType: .string) {
            insertText(NotesDocument(value).text, replacementRange: selectedRange())
        }
        else {
            super.paste(sender)
        }
    }
    func resizeImage(_ reference: NotesImageReference, width: Double?) {
        guard isEditable, let directory = editor?.directory else { return }
        let source = string
        let request = UUID()
        imagePreparationRevision = request
        imagePreparationTask?.cancel()
        imageUserOperation = true
        imagePreparationTask = Task { [weak self] in
            let lease = UUID()
            await NotesImagePreparation.shared.retainResults(lease, directory: directory)
            defer { Task { await NotesImagePreparation.shared.releaseResults(lease) } }
            defer { if self?.imagePreparationRevision == request { self?.imageUserOperation = false } }
            do {
                let resized = try await NotesImagePreparation.shared.resize(
                    reference, width: width, source: source, directory: directory)
                guard let self, !Task.isCancelled, self.imagePreparationRevision == request,
                    self.string == source, self.isEditable, !self.hasMarkedText()
                else { return }
                self.undoManager?.beginUndoGrouping()
                self.replaceImage(reference, with: resized)
                self.undoManager?.endUndoGrouping()
            }
            catch { if !Task.isCancelled { self?.editor?.imageError(error.localizedDescription) } }
        }
    }
    func prepareImagesForSave() async {
        await waitForImagePreparation()
        normalizeImageWidths()
        await waitForImagePreparation()
    }
    func waitForImagePreparation() async {
        await imagePreparationTask?.value
        await imageNormalizationTask?.value
    }
    @discardableResult func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, let directory = editor?.directory else { return false }
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let imageURLs = urls.filter {
            (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
        }
        let bytes =
            imageURLs.isEmpty
            ? (pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
                ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation) : nil
        guard !imageURLs.isEmpty || bytes != nil else { return false }
        let source = string
        let selected = selectedRange()
        let request = UUID()
        imagePreparationRevision = request
        imagePreparationTask?.cancel()
        imageUserOperation = true
        imagePreparationTask = Task { [weak self] in
            let lease = UUID()
            await NotesImagePreparation.shared.retainResults(lease, directory: directory)
            defer { Task { await NotesImagePreparation.shared.releaseResults(lease) } }
            defer { if self?.imagePreparationRevision == request { self?.imageUserOperation = false } }
            do {
                let references = try await NotesImagePreparation.shared.importImages(
                    urls: imageURLs, bytes: bytes, directory: directory)
                guard let self, !Task.isCancelled, self.imagePreparationRevision == request, self.isEditable else {
                    return
                }
                guard self.string == source, !self.hasMarkedText() else {
                    self.editor?.imageError(
                        "The notes changed while the image was being prepared. Paste the image again.")
                    return
                }
                let value = source as NSString
                let prefix =
                    selected.location > 0
                        && value.substring(with: NSRange(location: selected.location - 1, length: 1)) != "\n"
                    ? "\n" : ""
                let suffix =
                    NSMaxRange(selected) < value.length
                        && value.substring(with: NSRange(location: NSMaxRange(selected), length: 1)) == "\n" ? "" : "\n"
                self.undoManager?.beginUndoGrouping()
                self.insertText(
                    prefix + references.map(\.markdown).joined(separator: "\n") + suffix, replacementRange: selected)
                self.undoManager?.endUndoGrouping()
            }
            catch { if !Task.isCancelled { self?.editor?.imageError(error.localizedDescription) } }
        }
        return true
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
            ? .copy : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        return sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
            ? .copy : super.draggingUpdated(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        guard sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil else {
            return super.performDragOperation(sender)
        }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        if pasteImages(from: sender.draggingPasteboard) { return true }
        let urls =
            sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        let audio = urls.filter {
            (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .audio)) == true
        }
        if !audio.isEmpty {
            editor?.audioDrop(audio)
            return true
        }
        return super.performDragOperation(sender)
    }

    func finishEditingSession() {
        imageSaveTask?.cancel()
        Task { @MainActor in
            await self.waitForImagePreparation()
            self.normalizeImageWidths()
            await self.waitForImagePreparation()
            self.editor?.flush()
            self.undoManager?.removeAllActions()
            if let directory = self.editor?.directory {
                do {
                    try await NotesImagePreparation.shared.cleanupSavedIfMatching(
                        self.document.markdown, directory: directory)
                }
                catch { self.editor?.imageError(error.localizedDescription) }
            }
        }
    }

    func normalizeImageWidths() {
        guard !normalizingImages, !imageUserOperation, isEditable, !hasMarkedText(), let directory = editor?.directory
        else { return }
        let source = string
        guard source.contains("width=") else { return }
        let request = imagePreparationRevision
        imageNormalizationTask?.cancel()
        imageNormalizationTask = Task { [weak self] in
            let lease = UUID()
            await NotesImagePreparation.shared.retainResults(lease, directory: directory)
            defer { Task { await NotesImagePreparation.shared.releaseResults(lease) } }
            do {
                let replacements = try await NotesImagePreparation.shared.normalize(source, directory: directory)
                guard let self, !Task.isCancelled, self.imagePreparationRevision == request,
                    self.string == source, self.isEditable, !self.hasMarkedText()
                else { return }
                self.normalizingImages = true
                defer { self.normalizingImages = false }
                let changes = replacements.filter { $0.0.markdown != $0.1.markdown }
                guard !changes.isEmpty else { return }
                self.undoManager?.beginUndoGrouping()
                for (reference, desired) in changes.reversed() {
                    self.replaceSourcePreservingSelection(in: reference.range, with: desired.markdown)
                }
                self.undoManager?.endUndoGrouping()
                self.editor?.flush()
            }
            catch { if !Task.isCancelled { self?.editor?.imageError(error.localizedDescription) } }
        }
    }

    func replaceImage(_ reference: NotesImageReference, with replacement: NotesImageReference) {
        guard NotesImageReference.parse(in: string).contains(reference) else {
            editor?.imageError("This image changed while its controls were open. Select the image again.")
            return
        }
        breakUndoCoalescing()
        window?.makeFirstResponder(self)
        replaceSourcePreservingSelection(in: reference.range, with: replacement.markdown)
        breakUndoCoalescing()
    }
    private func replaceSourcePreservingSelection(in range: NSRange, with replacement: String) {
        let before = (string as NSString).substring(with: range) as NSString
        let after = replacement as NSString
        var prefix = 0
        while prefix < min(before.length, after.length), before.character(at: prefix) == after.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(before.length, after.length) - prefix,
            before.character(at: before.length - suffix - 1) == after.character(at: after.length - suffix - 1)
        { suffix += 1 }
        let edit = NSRange(location: range.location + prefix, length: before.length - prefix - suffix)
        let inserted = after.substring(with: NSRange(location: prefix, length: after.length - prefix - suffix))
        let delta = (inserted as NSString).length - edit.length
        let selection = selectedRange()
        let viewport = enclosingScrollView?.contentView.bounds.origin
        func adjusted(_ offset: Int) -> Int {
            if offset <= edit.location { return offset }
            if offset >= NSMaxRange(edit) { return offset + delta }
            return edit.location + min(offset - edit.location, (inserted as NSString).length)
        }
        insertText(inserted, replacementRange: edit)
        let start = adjusted(selection.location)
        setSelectedRange(NSRange(location: start, length: max(0, adjusted(NSMaxRange(selection)) - start)))
        if let viewport, let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: viewport)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

}
