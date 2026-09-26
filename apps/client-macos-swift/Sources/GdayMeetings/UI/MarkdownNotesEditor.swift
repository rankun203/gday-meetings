import AppKit
import SwiftUI

struct MeetingNotesEditor: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    var body: some View {
        MarkdownNotesEditor(
            meetingID: meetingID,
            markdown: store.meetings.first { $0.id == meetingID }?.notes ?? "",
            editable: store.libraryWritable,
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
            changed: { store.editNotes(id: meetingID, text: $0) }, flush: { _ = store.flushNotes() }
        )
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
        .onAppear { store.openNotes(id: meetingID) }
        .onDisappear { _ = store.flushNotes() }
        .id(meetingID)
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
        text.textContainerInset = NSSize(width: 52, height: 12)
        text.drawsBackground = false
        text.setAccessibilityLabel("Meeting Notes")
        text.editor = self
        text.load(markdown)
        text.delegate = text
        text.textStorage?.delegate = text
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NotesTextView else { return }
        text.editor = self
        text.isEditable = editable
        if text.document.markdown != markdown { text.load(markdown) }
        text.needsLayout = true
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: ()) {
        (scroll.documentView as? NotesTextView)?.editor?.flush()
    }
}

final class NotesTextView: NSTextView, NSTextViewDelegate, NSTextStorageDelegate {
    var editor: MarkdownNotesEditor?
    var document = NotesDocument("")
    var notesPasteboard = NSPasteboard.general
    private var applyingStyle = false
    private var gutterButtons: [NSButton] = []
    private var gutterTimes: [ObjectIdentifier: TimeInterval] = [:]
    private var notesTrackingArea: NSTrackingArea?
    private static let pasteType = NSPasteboard.PasteboardType("com.gdaymeetings.timed-notes")
    private struct Clipboard: Codable {
        var meetingID: UUID
        var markdown: String
    }

    func load(_ markdown: String) {
        document = NotesDocument(markdown)
        string = document.text
        style(NSRange(location: 0, length: (string as NSString).length))
        needsLayout = true
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?)
        -> Bool
    {
        guard let replacementString else { return true }
        let previous = document
        document.replace(affectedCharRange, with: replacementString, clock: editor?.clock())
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
        editor?.changed(document.markdown)
        needsLayout = true
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { editor?.flush() }
        return result
    }
    func textStorage(
        _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange, changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !applyingStyle else { return }
        style((string as NSString).paragraphRange(for: editedRange))
    }
    private func style(_ range: NSRange) {
        guard let storage = textStorage, range.length > 0, NSMaxRange(range) <= storage.length else { return }
        applyingStyle = true
        defer { applyingStyle = false }
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
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: source as String, range: range) {
                storage.addAttributes(attributes, range: match.range)
            }
        }
        typingAttributes = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor,
        ]
    }
    override func layout() {
        super.layout()
        updateGutter()
    }
    private func updateGutter() {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return }
        var labels: [(NSRect, TimeInterval, Int)] = []
        let visible = visibleRect
        manager.enumerateTextLayoutFragments(
            from: manager.textViewportLayoutController.viewportRange?.location, options: []
        ) { fragment in
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let lineIndex = self.document.lineIndex(at: offset)
            let rect = fragment.layoutFragmentFrame.offsetBy(
                dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
            if rect.minY > visible.maxY { return false }
            if rect.intersects(visible), let time = self.document.lines[lineIndex].time,
                offset == self.document.range(of: lineIndex).location
            {
                labels.append((NSRect(x: 2, y: rect.minY, width: 46, height: 20), time, lineIndex))
            }
            return true
        }
        while gutterButtons.count < labels.count {
            let button = NSButton(title: "", target: self, action: #selector(playGutter(_:)))
            button.isBordered = false
            button.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
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
            button.title = NotesDocument.timestamp(time)
            button.isEnabled = editor?.canPlay() == true
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
        (super.accessibilityChildren() ?? []) + gutterButtons.filter { !$0.isHidden }
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
                if editor?.canPlay() == true, let time = document.time(atLine: document.lineIndex(at: position)) {
                    editor?.play(time)
                }
                return
            }
        }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let lineIndex = document.lineIndex(at: index)
        let line = document.lines[lineIndex].text as NSString
        if isEditable, let expression = try? NSRegularExpression(pattern: #"^\s*[-+*] (\[[ xX]\]) "#),
            let match = expression.firstMatch(in: line as String, range: NSRange(location: 0, length: line.length))
        {
            let checkbox = NSRange(
                location: document.range(of: lineIndex).location + match.range(at: 1).location, length: 3)
            if NSLocationInRange(index, checkbox) {
                let checked = (string as NSString).substring(with: checkbox).lowercased() == "[x]"
                insertText(checked ? "[ ]" : "[x]", replacementRange: checkbox)
                return
            }
        }
        super.mouseDown(with: event)
    }
    override func cursorUpdate(with event: NSEvent) {
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.command), document.time(atLine: document.lineIndex(at: index)) != nil,
            editor?.canPlay() == true
        {
            NSCursor.pointingHand.set()
        }
        else {
            super.cursorUpdate(with: event)
        }
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
        updateTimelineHover(event)
        super.mouseMoved(with: event)
    }
    override func flagsChanged(with event: NSEvent) {
        updateTimelineHover(event)
        super.flagsChanged(with: event)
    }
    override func mouseExited(with event: NSEvent) {
        gutterButtons.forEach { $0.highlight(false) }
        super.mouseExited(with: event)
    }
    private func updateTimelineHover(_ event: NSEvent) {
        let position = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: position)
        let time =
            event.modifierFlags.contains(.command) && editor?.canPlay() == true
            ? document.time(atLine: document.lineIndex(at: index)) : nil
        for button in gutterButtons {
            button.highlight(time != nil && button.tag == document.timedLine(for: document.lineIndex(at: index)))
        }
        if time != nil {
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
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
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
        var copied = NotesDocument(text)
        let first = document.lineIndex(at: range.location)
        for index in copied.lines.indices where first + index < document.lines.count {
            copied.setTime(document.time(atLine: first + index), line: index)
        }
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
            let pasted = NotesDocument(payload.markdown)
            let first = document.lineIndex(at: selectedRange().location)
            insertText(pasted.text, replacementRange: selectedRange())
            if payload.meetingID == editor?.meetingID {
                for index in pasted.lines.indices where first + index < document.lines.count {
                    document.setTime(pasted.lines[index].time, line: first + index)
                }
                editor?.changed(document.markdown)
                needsLayout = true
            }
        }
        else if let value = notesPasteboard.string(forType: .string) {
            insertText(NotesDocument(value).text, replacementRange: selectedRange())
        }
        else {
            super.paste(sender)
        }
    }
}
