import AppKit
import SwiftUI

/// Owns the native field so loading stays inside its bounds without inspecting SwiftUI's views.
struct LibrarySearchField: View {
    @ObservedObject var controller: LocalSearchController
    @Binding var text: String
    @Binding var focused: Bool
    var activate: () -> Void
    var submit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NativeLibrarySearchField(
            text: $text, focused: $focused,
            loading: controller.isLoading, stage: controller.loadingStage,
            reduceMotion: reduceMotion, activate: activate, submit: submit
        )
        .frame(minWidth: 180, idealWidth: 280, maxWidth: 360).frame(height: 28)
    }
}

private struct NativeLibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let loading: Bool
    let stage: String
    let reduceMotion: Bool
    let activate: () -> Void
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> LoadingSearchField {
        let field = LoadingSearchField()
        field.placeholderString = "Search"
        field.setAccessibilityLabel("Search")
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.search(_:))
        field.onActivate = { [weak coordinator = context.coordinator] in coordinator?.activate() }
        field.controlSize = .regular
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        return field
    }
    func updateNSView(_ field: LoadingSearchField, context: Context) {
        context.coordinator.parent = self
        let focusChanged = context.coordinator.requestedFocus != focused
        context.coordinator.requestedFocus = focused
        if field.stringValue != text { field.stringValue = text }
        field.updateLoading(loading, reduceMotion: reduceMotion)
        field.setAccessibilityHelp(loading ? stage : "Search meeting content")
        let isEditing = field.currentEditor() != nil
        if focused, !isEditing {
            DispatchQueue.main.async { [weak field] in
                guard let field, context.coordinator.parent.focused else { return }
                field.window?.makeFirstResponder(field)
            }
        }
        else if focusChanged, !focused, isEditing {
            field.window?.makeFirstResponder(nil)
        }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeLibrarySearchField
        // A native click can begin editing before its focus binding reaches SwiftUI.
        // Only an explicit binding transition should resign that new editor.
        var requestedFocus = false
        init(_ parent: NativeLibrarySearchField) { self.parent = parent }
        func activate() {
            parent.focused = true
            parent.activate()
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.focused = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }
        @objc func search(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            if !sender.stringValue.isEmpty { parent.submit() }
        }
    }
}

private final class LoadingSearchField: NSSearchField {
    var onActivate: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.onActivate?() } }
        return accepted
    }
    private let strip = CALayer()
    private let wave = CAGradientLayer()
    private var loading = false
    private var reducedMotion = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        strip.masksToBounds = true
        strip.cornerRadius = 1
        strip.isHidden = true
        layer?.addSublayer(strip)
        wave.startPoint = CGPoint(x: 0, y: 0.5)
        wave.endPoint = CGPoint(x: 1, y: 0.5)
        strip.addSublayer(wave)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = CGRect(x: 10, y: isFlipped ? bounds.height - 4 : 2, width: max(0, bounds.width - 20), height: 2)
        wave.frame = strip.bounds
        CATransaction.commit()
    }
    func updateLoading(_ value: Bool, reduceMotion: Bool) {
        guard loading != value || reducedMotion != reduceMotion else { return }
        loading = value
        reducedMotion = reduceMotion
        strip.isHidden = !value
        wave.removeAllAnimations()
        let color = NSColor.controlAccentColor
        wave.colors = [color.withAlphaComponent(0.2).cgColor, color.cgColor, color.withAlphaComponent(0.2).cgColor]
        wave.locations = [0, 0.5, 1]
        if value, !reduceMotion {
            let animation = CABasicAnimation(keyPath: "locations")
            animation.fromValue = [-1, -0.5, 0]
            animation.toValue = [1, 1.5, 2]
            animation.duration = 1.6
            animation.repeatCount = .infinity
            wave.add(animation, forKey: "loading")
        }
    }
}
