import AppKit
import QuickLookUI

/// Decorations preserve the editor's Markdown and native UTF-16 selection ranges.
@MainActor final class NotesImagePresentation: NSObject {
    weak var text: NotesTextView?
    var views: [NotesImageView] = []
    private var signature = ""
    private var references: [NotesImageReference] = []
    private var referencesDirty = true
    private let parseReferences: (String) -> [NotesImageReference]
    private var pendingEdits: [(NSRange, Int)] = []
    private var proposedEdit: (range: NSRange, replacement: String)?
    private static let spacingKey = NSAttributedString.Key("GdayNotesImageSpacing")
    private var cache: [String: NSImage] = [:]
    init(text: NotesTextView, parseReferences: @escaping (String) -> [NotesImageReference] = NotesImageReference.parse)
    {
        self.text = text
        self.parseReferences = parseReferences
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: text.textStorage)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func storageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
            storage.editedMask.contains(.editedCharacters)
        else { return }
        referencesDirty = true
        // A processed range can be the union of several character and attribute
        // edits. Rebase only a matching native edit; otherwise reconcile parsed
        // references without treating that union as deleted text.
        defer { proposedEdit = nil }
        guard let proposedEdit else { return }
        let replacement = storage.editedRange
        guard replacement.location == proposedEdit.range.location,
            replacement.length == proposedEdit.replacement.utf16.count,
            storage.changeInLength == replacement.length - proposedEdit.range.length,
            (storage.string as NSString).substring(with: replacement) == proposedEdit.replacement
        else { return }
        let replacesDocument =
            proposedEdit.range.location == 0
            && proposedEdit.range.length == storage.length - storage.changeInLength
        let unchangedImage = views.contains {
            $0.reference.range == proposedEdit.range && $0.reference.markdown == proposedEdit.replacement
        }
        if !replacesDocument && !unchangedImage {
            pendingEdits.append((proposedEdit.range, replacement.length))
        }
    }

    func prepare() {
        guard let text, let directory = text.editor?.directory, let storage = text.textStorage else { return }
        let width = max(40, text.bounds.width - text.textContainerInset.width * 2 - 10)
        reconcileRanges()
        let versions = references.map { reference -> String in
            guard let file = try? NotesAssets.safeURL(relativePath: reference.displayPath, directory: directory),
                let metadata = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            else { return "missing" }
            return "\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(metadata.fileSize ?? 0)"
        }.joined(separator: ",")
        let key = references.map { "\($0.range):\($0.markdown)" }.joined(separator: "\n") + "\n@\(width)@" + versions
        guard key != signature else { return }
        signature = key
        if let content = text.textLayoutManager?.textContentManager {
            content.performEditingTransaction {
                updateDecorations(text: text, storage: storage, directory: directory, width: width)
            }
        }
        else {
            updateDecorations(text: text, storage: storage, directory: directory, width: width)
        }
    }
    private func updateDecorations(text: NotesTextView, storage: NSTextStorage, directory: URL, width: CGFloat) {
        storage.beginEditing()
        defer {
            storage.endEditing()
            text.needsLayout = true
        }
        var available = views
        var updated: [NotesImageView] = []
        var desiredSpacing: [(NSRange, CGFloat)] = []
        for reference in references {
            do {
                let original = try NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory)
                let requestedDisplay = try NotesAssets.safeURL(
                    relativePath: reference.displayPath, directory: directory)
                let display =
                    FileManager.default.fileExists(atPath: requestedDisplay.path) ? requestedDisplay : original
                let info = try NotesImageStore.info(at: original)
                let displayWidth = min(width, reference.width ?? info.naturalSize.width)
                let size = CGSize(
                    width: displayWidth, height: displayWidth * info.naturalSize.height / info.naturalSize.width)
                let metadata = try display.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let cacheKey =
                    display.path
                    + "@\(Int(displayWidth * 2))-\(metadata.contentModificationDate?.timeIntervalSince1970 ?? 0)-\(metadata.fileSize ?? 0)"
                let reusable = available.first { $0.reference == reference }
                let image: NSImage
                if let reusable, reusable.assetKey == cacheKey, let retained = reusable.image {
                    image = retained
                }
                else if let cached = cache[cacheKey] {
                    image = cached
                }
                else {
                    let cg = try NotesImageStore.thumbnail(
                        at: display, maximumPixels: Int(max(size.width, size.height) * 2))
                    image = NSImage(cgImage: cg, size: size)
                    cache[cacheKey] = image
                    if cache.count > 30 { cache = [cacheKey: image] }
                }
                desiredSpacing.append(
                    ((text.string as NSString).paragraphRange(for: reference.range), size.height + 16))
                let view: NotesImageView
                if let index = available.firstIndex(where: { $0.reference == reference }) {
                    view = available.remove(at: index)
                }
                else {
                    view = NotesImageView(frame: NSRect(origin: .zero, size: size))
                    view.isHidden = true
                    text.addSubview(view)
                }
                view.frame.size = size
                view.image = image
                view.assetKey = cacheKey
                view.reference = reference
                view.original = original
                view.text = text
                view.setAccessibilityElement(true)
                view.setAccessibilityRole(.image)
                view.setAccessibilityLabel(reference.alt.isEmpty ? "Image in notes" : reference.alt)
                updated.append(view)
            }
            catch {
                // Missing and unsupported images retain their editable Markdown.
                continue
            }
        }
        available.forEach { $0.removeFromSuperview() }
        views = updated
        var stale: [NSRange] = []
        storage.enumerateAttribute(Self.spacingKey, in: NSRange(location: 0, length: storage.length)) {
            value, range, _ in
            guard value != nil else { return }
            if !desiredSpacing.contains(where: { $0.0 == range && ($0.1 == (value as? CGFloat)) }) {
                stale.append(range)
            }
        }
        for range in stale {
            storage.removeAttribute(Self.spacingKey, range: range)
            storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: range)
        }
        for (range, height) in desiredSpacing where range.length > 0 {
            let existing = storage.attribute(Self.spacingKey, at: range.location, effectiveRange: nil) as? CGFloat
            guard existing != height else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = height
            storage.addAttributes([.paragraphStyle: paragraph, Self.spacingKey: height], range: range)
        }
    }
    // Rebase surviving decorations immediately after edits, without touching
    // text storage or invalidating layout. Unrelated typing keeps them visible.
    func willChange(_ range: NSRange, replacement: String) {
        proposedEdit = (range, replacement)
    }
    private func applyPendingEdits() {
        for (range, replacementLength) in pendingEdits {
            let delta = replacementLength - range.length
            views = views.filter { view in
                let image = view.reference.range
                if NSMaxRange(range) <= image.location {
                    view.reference.range.location += delta
                }
                else if range.location <= image.location && NSMaxRange(range) >= NSMaxRange(image) {
                    view.removeFromSuperview()
                    return false
                }
                return true
            }
        }
        pendingEdits.removeAll(keepingCapacity: true)
    }
    func didChangeText() {
        reconcileRanges()
        pendingEdits.removeAll(keepingCapacity: true)
    }
    func reconcileRanges() {
        guard let text, referencesDirty else { return }
        referencesDirty = false
        applyPendingEdits()
        references = parseReferences(text.string)
        var unmatched = references
        views = views.filter { view in
            let index =
                unmatched.firstIndex {
                    $0.range.location == view.reference.range.location && $0.originalPath == view.reference.originalPath
                } ?? unmatched.firstIndex { $0.markdown == view.reference.markdown }
                ?? unmatched.firstIndex { $0.originalPath == view.reference.originalPath }
            guard let index else {
                view.removeFromSuperview()
                return false
            }
            view.reference = unmatched.remove(at: index)
            return true
        }
    }
    func layout() {
        guard let text, let manager = text.textLayoutManager, let content = manager.textContentManager else { return }
        reconcileRanges()
        for view in views {
            guard
                let location = content.location(
                    content.documentRange.location, offsetBy: view.reference.range.location),
                let fragment = manager.textLayoutFragment(for: location)
            else {
                view.isHidden = true
                continue
            }
            view.isHidden = false
            // Paragraph spacing belongs after the final wrapped line of the image syntax.
            let lines = fragment.textLineFragments.filter { $0.characterRange.length > 0 }
            let bottom = lines.map { $0.typographicBounds.maxY }.max() ?? 20
            view.frame.origin = CGPoint(
                x: text.textContainerOrigin.x + 5,
                y: text.textContainerOrigin.y + fragment.layoutFragmentFrame.minY + bottom + 8)
        }
    }
    func setImageCursor(at point: NSPoint) -> Bool {
        guard let text else { return false }
        for view in views where !view.isHidden {
            let local = view.convert(point, from: text)
            if let cursor = view.cursor(at: local) {
                cursor.set()
                return true
            }
        }
        return false
    }
    func invalidate() {
        signature = ""
        referencesDirty = true
        proposedEdit = nil
        pendingEdits.removeAll(keepingCapacity: true)
    }
}

@MainActor final class NotesImageView: NSView {
    weak var text: NotesTextView?
    var image: NSImage?
    var assetKey = ""
    var reference = NotesImageReference(
        range: .init(location: 0, length: 0), originalPath: "", displayPath: "", alt: "")
    var original: URL?
    private var previewWindow: NSWindowController?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    var resizeHandle: NSRect {
        let width = min(32, bounds.width)
        let height = min(32, bounds.height)
        return NSRect(x: bounds.maxX - width, y: bounds.maxY - height, width: width, height: height)
    }
    func cursor(at point: NSPoint) -> NSCursor? {
        guard bounds.contains(point) else { return nil }
        return text?.isEditable == true && resizeHandle.contains(point) ? Self.resizeCursor : .arrow
    }
    static let resizeCursor: NSCursor = {
        if #available(macOS 15.0, *) {
            return .frameResize(position: .bottomRight, directions: .all)
        }
        let image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)!
        image.size = NSSize(width: 18, height: 18)
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }()
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
        guard text?.isEditable == true else { return }
        addCursorRect(
            resizeHandle,
            cursor: Self.resizeCursor)
    }
    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil))?.set()
    }
    override func mouseMoved(with event: NSEvent) {
        if let cursor = cursor(at: convert(event.locationInWindow, from: nil)) {
            cursor.set()
            return
        }
        super.mouseMoved(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        guard let text else { return }
        if event.clickCount == 2 {
            quickLook(nil)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        text.setSelectedRange(reference.range)
        window?.makeFirstResponder(text)
        guard text.isEditable, resizeHandle.contains(point) else { return }
        let initialWidth = Double(frame.width)
        let aspect = frame.height / frame.width
        let initialX = text.convert(event.locationInWindow, from: nil).x
        let cursor = Self.resizeCursor
        cursor.push()
        defer {
            NSCursor.pop()
            let point = convert(window?.mouseLocationOutsideOfEventStream ?? event.locationInWindow, from: nil)
            (self.cursor(at: point) ?? .iBeam).set()
        }
        var proposed = initialWidth
        let outline = NSView(frame: frame)
        outline.wantsLayer = true
        outline.layer?.borderColor = NSColor.controlAccentColor.cgColor
        outline.layer?.borderWidth = 2
        text.addSubview(outline)
        defer { outline.removeFromSuperview() }
        let maximum = max(24, Double(text.bounds.width - text.textContainerInset.width * 2 - 10))
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            cursor.set()
            proposed = min(
                maximum, max(24, initialWidth + Double(text.convert(next.locationInWindow, from: nil).x - initialX)))
            outline.frame.size = CGSize(width: proposed, height: proposed * aspect)
        }
        text.resizeImage(reference, width: proposed)
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [
            NSAccessibilityCustomAction(
                name: "Quick Look",
                handler: { [weak self] in
                    self?.quickLook(nil)
                    return self != nil
                }),
            NSAccessibilityCustomAction(
                name: "Image Width",
                handler: { [weak self] in
                    guard let self, self.text?.isEditable == true else { return false }
                    self.editWidth(nil)
                    return true
                }),
            NSAccessibilityCustomAction(
                name: "Edit Description",
                handler: { [weak self] in
                    guard let self, self.text?.isEditable == true else { return false }
                    self.editDescription(nil)
                    return true
                }),
        ]
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [
            ("Quick Look", #selector(quickLook(_:))), ("Edit Description…", #selector(editDescription(_:))),
            ("Image Width…", #selector(editWidth(_:))), ("Original Size", #selector(originalSize(_:))),
            ("Copy Image", #selector(copyImage(_:))), ("Show in Finder", #selector(showInFinder(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }
    @objc func quickLook(_ sender: Any?) {
        guard let original else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = original.lastPathComponent
        let preview = QLPreviewView(frame: panel.contentView!.bounds, style: .normal)!
        preview.autoresizingMask = [.width, .height]
        preview.previewItem = original as NSURL
        panel.contentView?.addSubview(preview)
        previewWindow = NSWindowController(window: panel)
        panel.center()
        previewWindow?.showWindow(nil)
    }
    @objc func showInFinder(_ sender: Any?) {
        if let original { NSWorkspace.shared.activateFileViewerSelecting([original]) }
    }
    @objc func copyImage(_ sender: Any?) {
        guard let original, let image = NSImage(contentsOf: original) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
    @objc func originalSize(_ sender: Any?) { text?.resizeImage(reference, width: nil) }
    @objc func editWidth(_ sender: Any?) {
        prompt(
            title: "Image Width", value: String(Int(reference.width ?? frame.width)), placeholder: "Width in points",
            validator: { value in Double(value).map { $0.isFinite && $0 >= 1 && $0 <= 100_000 } ?? false }
        ) { [weak self] value in
            guard let self, let width = Double(value), width.isFinite, width >= 1, width <= 100_000 else { return }
            self.text?.resizeImage(self.reference, width: width)
        }
    }
    @objc func editDescription(_ sender: Any?) {
        prompt(title: "Image Description", value: reference.alt, placeholder: "Describe the image") {
            [weak self] value in
            guard let self else { return }
            var changed = self.reference
            changed.alt = value.replacingOccurrences(of: "\n", with: " ")
            self.text?.replaceImage(self.reference, with: changed)
        }
    }
    private func prompt(
        title: String, value: String, placeholder: String, validator: @escaping (String) -> Bool = { _ in true },
        apply: @escaping (String) -> Void
    ) {
        guard text?.isEditable == true, let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = value
        field.placeholderString = placeholder
        field.setAccessibilityLabel(title)
        alert.accessoryView = field
        let validation = NotesImageFieldValidation(field: field, button: alert.buttons[0], validate: validator)
        field.delegate = validation
        validation.update()
        alert.beginSheetModal(for: window) { response in
            _ = validation
            if response == .alertFirstButtonReturn { apply(field.stringValue) }
        }
    }
}

@MainActor private final class NotesImageFieldValidation: NSObject, NSTextFieldDelegate {
    let field: NSTextField
    let button: NSButton
    let validate: (String) -> Bool
    init(field: NSTextField, button: NSButton, validate: @escaping (String) -> Bool) {
        self.field = field
        self.button = button
        self.validate = validate
    }
    func update() { button.isEnabled = validate(field.stringValue) }
    func controlTextDidChange(_ notification: Notification) { update() }
}
