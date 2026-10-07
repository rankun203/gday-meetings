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
            startedAt: controller.loadingStartedAt, duration: controller.loadingDuration, ready: controller.isReady,
            reduceMotion: reduceMotion, activate: activate, submit: submit
        )
        .frame(minWidth: 180, idealWidth: 280, maxWidth: 360).frame(height: 28)
        .task {
            if UIPreview.enabled,
                ProcessInfo.processInfo.arguments.contains("--synthetic-search-loading")
                    || Bundle.main.object(forInfoDictionaryKey: "GdaySyntheticSearchLoading") as? Bool == true
            {
                await controller.previewLoading()
            }
        }
    }
}

private struct NativeLibrarySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let loading: Bool
    let stage: String
    let startedAt: TimeInterval
    let duration: TimeInterval
    let ready: Bool
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
        field.updateLoading(loading, startedAt: startedAt, duration: duration, ready: ready, reduceMotion: reduceMotion)
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
    private let strip = CAShapeLayer()
    private var loading = false
    private var reducedMotion = false
    private var startedAt: TimeInterval = 0
    private var duration: TimeInterval = 1
    private var progressUpdates: Task<Void, Never>?
    deinit { progressUpdates?.cancel() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        strip.opacity = 0
        strip.lineWidth = 2
        strip.lineCap = .round
        strip.fillColor = nil
        strip.strokeEnd = 0
        layer?.addSublayer(strip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = bounds
        let y = isFlipped ? bounds.height - 3 : 3
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10, y: y))
        path.addLine(to: CGPoint(x: max(10, bounds.width - 10), y: y))
        strip.path = path
        strip.strokeColor = NSColor.controlAccentColor.cgColor
        CATransaction.commit()
    }
    func updateLoading(_ value: Bool, startedAt: TimeInterval, duration: TimeInterval, ready: Bool, reduceMotion: Bool)
    {
        guard
            loading != value || reducedMotion != reduceMotion
                || (value && (self.startedAt != startedAt || self.duration != duration))
        else { return }
        let newLoad = value && (!loading || self.startedAt != startedAt)
        let previous = newLoad ? 0 : (strip.presentation()?.strokeEnd ?? strip.strokeEnd)
        let opacity = strip.presentation()?.opacity ?? strip.opacity
        loading = value
        reducedMotion = reduceMotion
        self.startedAt = startedAt
        self.duration = duration
        progressUpdates?.cancel()
        strip.removeAllAnimations()
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        let fraction = min(0.95, elapsed / max(0.001, duration))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.strokeEnd = value ? (reduceMotion ? fraction : 0.95) : (ready ? 1 : previous)
        strip.opacity = value ? 1 : 0
        CATransaction.commit()
        if value {
            if reduceMotion {
                progressUpdates = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(250)) }
                        catch { return }
                        guard let self else { return }
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        self.strip.strokeEnd = min(
                            0.95, max(0, ProcessInfo.processInfo.systemUptime - startedAt) / max(0.001, duration))
                        CATransaction.commit()
                    }
                }
                return
            }
            animate("opacity", from: Double(opacity), to: 1, duration: 0.18)
            animate(
                "strokeEnd", from: newLoad ? fraction : previous, to: 0.95,
                duration: max(0.1, duration * 0.95 - elapsed))
        }
        else if !reduceMotion {
            if ready { animate("strokeEnd", from: previous, to: 1, duration: 0.16) }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity
            fade.toValue = 0
            fade.duration = 0.2
            fade.beginTime = strip.convertTime(CACurrentMediaTime(), from: nil) + (ready ? 0.16 : 0)
            fade.fillMode = .backwards
            strip.add(fade, forKey: "opacity")
        }
    }
    private func animate(_ key: String, from: Double, to: Double, duration: TimeInterval) {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        strip.add(animation, forKey: key)
    }
}
