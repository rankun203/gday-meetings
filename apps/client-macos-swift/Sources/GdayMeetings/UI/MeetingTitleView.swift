import SwiftUI

/// Reading preserves the header height; only a deliberate edit creates a field.
struct MeetingTitleView: View {
    @Binding var title: String
    var editable: Bool
    @ViewState private var draft = ""
    @ViewState private var isEditing = false

    var body: some View {
        Group {
            if isEditing {
                MeetingTitleEditor(text: $draft, finish: { finish(cancel: $0) })
            }
            else {
                Text(Self.displayTitle(title))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { begin() }
                    .accessibilityLabel(title)
                    .accessibilityAction(named: "Edit Title") { begin() }
                    .contextMenu { Button("Edit Title", action: begin).disabled(!editable) }
                    .help(title)
            }
        }
        .font(.title2.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { finish() }
    }
    static func displayTitle(_ title: String) -> String {
        guard let newline = title.firstIndex(where: \.isNewline) else { return title }
        return String(title[..<newline]) + "…"
    }
    private func begin() {
        guard editable else { return }
        draft = title
        isEditing = true
    }
    private func finish(cancel: Bool = false) {
        guard isEditing else { return }
        // End the session before focus changes can send another completion.
        isEditing = false
        if !cancel && draft != title { title = draft }
    }
}

struct MeetingTitleEditor: NSViewRepresentable {
    @Binding var text: String
    var finish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> MeetingTitleTextField {
        let field = MeetingTitleTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.setAccessibilityLabel("Meeting title")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: MeetingTitleTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MeetingTitleEditor
        private var completed = false
        init(_ parent: MeetingTitleEditor) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) { complete(cancel: false) }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.text = textView.string
                complete(cancel: false)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                complete(cancel: true)
                return true
            }
            return false
        }
        private func complete(cancel: Bool) {
            guard !completed else { return }
            completed = true
            parent.finish(cancel)
        }
    }
}

final class MeetingTitleTextField: NSTextField {
    private var didFocus = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didFocus else { return }
        // SwiftUI attaches the field during an update; request focus after that
        // transaction, when the native responder chain contains the editor.
        DispatchQueue.main.async { [weak self] in self?.focusForEditing() }
    }
    func focusForEditing() {
        guard !didFocus, let window, window.makeFirstResponder(self), let editor = currentEditor() else { return }
        didFocus = true
        editor.selectedRange = NSRange(location: 0, length: (stringValue as NSString).length)
    }
}
