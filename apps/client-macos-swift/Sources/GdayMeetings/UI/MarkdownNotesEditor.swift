import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
            changed: { store.editNotes(id: meetingID, text: $0) }, flush: { _ = store.flushNotes() },
            directory: store.directory(for: meetingID), imageError: { store.errorMessage = $0 },
            audioDrop: { urls in
                Task {
                    do { _ = try await store.importAudioFiles(urls) }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
        )
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
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
    var directory: URL? = nil
    var imageError: (String) -> Void = { _ in }
    var audioDrop: ([URL]) -> Void = { _ in }

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
        text.registerForDraggedTypes(Array(Set(text.registeredDraggedTypes + [.fileURL, .png, .tiff])))
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
        guard let text = scroll.documentView as? NotesTextView else { return }
        // Retain this meeting's editor until its final save completes, but do not
        // publish notes or errors while SwiftUI is dismantling its view graph.
        DispatchQueue.main.async { text.finishEditingSession() }
    }
}

final class NotesTextView: NSTextView, NSTextViewDelegate, NSTextStorageDelegate {
    var editor: MarkdownNotesEditor?
    var document = NotesDocument("")
    var notesPasteboard = NSPasteboard.general
    private var styledText: String?
    private var imageLayoutScheduled = false
    lazy var images = NotesImagePresentation(text: self)
    var lastInsertionDate: Date?
    private var imageSaveTask: Task<Void, Never>?
    private var normalizingImages = false
    private var normalizedImages: Set<String> = []
    private var gutterButtons: [NSButton] = []
    private var gutterTimes: [ObjectIdentifier: TimeInterval] = [:]
    private var notesTrackingArea: NSTrackingArea?
    private static let pasteType = NSPasteboard.PasteboardType("com.gdaymeetings.timed-notes")
    private struct Clipboard: Codable {
        var meetingID: UUID
        var markdown: String
    }

    func load(_ markdown: String) {
        undoManager?.removeAllActions()
        lastInsertionDate = nil
        imageSaveTask?.cancel()
        normalizedImages.removeAll()
        document = NotesDocument(markdown)
        images.invalidate()
        string = document.text
        styledText = nil
        scheduleImageLayout()
        needsLayout = true
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?)
        -> Bool
    {
        guard let replacementString else { return true }
        images.willChange(affectedCharRange, replacementLength: (replacementString as NSString).length)
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
    func prepareImageLayout() {
        guard let content = textLayoutManager?.textContentManager else { return }
        content.performEditingTransaction {
            textStorage?.beginEditing()
            if styledText != string {
                let current = string as NSString
                var range = NSRange(location: 0, length: current.length)
                if let previous = styledText as NSString? {
                    var start = 0
                    while start < min(previous.length, current.length),
                        previous.character(at: start) == current.character(at: start)
                    { start += 1 }
                    var tail = 0
                    while tail < min(previous.length, current.length) - start,
                        previous.character(at: previous.length - tail - 1)
                            == current.character(at: current.length - tail - 1)
                    { tail += 1 }
                    range = current.paragraphRange(for: NSRange(location: start, length: current.length - start - tail))
                }
                style(range)
                styledText = string
            }
            images.prepare()
            textStorage?.endEditing()
        }
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
        // Mutating paragraph attributes inside viewport layout leaves TextKit's
        // fragments with stale ranges after a large replacement.
        scheduleImageLayout()
        super.layout()
        images.layout()
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
        if images.setResizeCursor(at: convert(event.locationInWindow, from: nil)) { return }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.command), document.time(at: index) != nil,
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
        if images.setResizeCursor(at: position) { return }
        let index = characterIndexForInsertion(at: position)
        let time =
            event.modifierFlags.contains(.command) && editor?.canPlay() == true
            ? document.time(at: index) : nil
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
        do {
            let largest = NotesImageReference.parse(in: string).filter {
                $0.originalPath == reference.originalPath && $0.range != reference.range
            }.compactMap(\.width).max()
            let resized = try NotesImageStore.resized(
                reference, width: width, directory: directory, previewWidth: largest)
            replaceImage(reference, with: resized)
        }
        catch { editor?.imageError(error.localizedDescription) }
    }
    @discardableResult func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        guard isEditable, let directory = editor?.directory else { return false }
        do {
            let urls =
                pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                ?? []
            let imageURLs = urls.filter { NotesImageStore.isImage($0) }
            var references: [NotesImageReference] = []
            if !imageURLs.isEmpty {
                references = try imageURLs.map { try NotesImageStore.importFile($0, directory: directory) }
            }
            else if let bytes = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
                references = [try NotesImageStore.importClipboard(bytes, directory: directory)]
            }
            else if let image = NSImage(pasteboard: pasteboard), let bytes = image.tiffRepresentation {
                references = [try NotesImageStore.importClipboard(bytes, directory: directory)]
            }
            else {
                return false
            }
            let selected = selectedRange()
            let source = string as NSString
            let prefix =
                selected.location > 0
                    && source.substring(with: NSRange(location: selected.location - 1, length: 1)) != "\n" ? "\n" : ""
            let suffix =
                NSMaxRange(selected) < source.length
                    && source.substring(with: NSRange(location: NSMaxRange(selected), length: 1)) == "\n" ? "" : "\n"
            insertText(prefix + references.map(\.markdown).joined(separator: "\n") + suffix, replacementRange: selected)
            return true
        }
        catch {
            editor?.imageError(error.localizedDescription)
            return true
        }
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
        normalizeImageWidths()
        editor?.flush()
        undoManager?.removeAllActions()
        guard let directory = editor?.directory,
            let saved = try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8),
            saved == document.markdown
        else { return }
        do { try NotesImageClipboard.cleanupSaved(directory: directory, markdown: saved) }
        catch { editor?.imageError(error.localizedDescription) }
    }

    func normalizeImageWidths() {
        guard !normalizingImages, isEditable, let directory = editor?.directory else { return }
        normalizingImages = true
        defer { normalizingImages = false }
        for reference in NotesImageReference.parse(in: string).reversed() where reference.width != nil {
            do {
                let original = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory)
                let metadata = try original.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let version =
                    "@\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(metadata.fileSize ?? 0)"
                let key = reference.markdown + version
                if normalizedImages.contains(key) { continue }
                let largest = NotesImageReference.parse(in: string).filter { $0.originalPath == reference.originalPath }
                    .compactMap(\.width).max()
                let desired = try NotesImageStore.resized(
                    reference, width: reference.width, directory: directory, previewWidth: largest)
                normalizedImages.insert(key)
                normalizedImages.insert(desired.markdown + version)
                if desired.markdown != reference.markdown {
                    replaceSourcePreservingSelection(in: reference.range, with: desired.markdown)
                }
            }
            catch { editor?.imageError(error.localizedDescription) }
        }
        editor?.flush()
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
