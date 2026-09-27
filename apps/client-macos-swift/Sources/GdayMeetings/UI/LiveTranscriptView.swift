import AppKit
import SwiftUI

/// Only this tab observes volatile recognition text. Recording controls never
/// share its scroll view or subscribe to partial-result updates.
struct LiveTranscriptView: View {
    @ObservedObject var controller: LiveTranscriptController
    @ViewState private var followsLive = true
    @ViewState private var finalized: [LiveTranscriptPhrase] = []

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("Live Transcript", isOn: Binding(get: { controller.enabled }, set: controller.setEnabled))
                        .toggleStyle(.switch).controlSize(.small)
                    Spacer()
                    Button("Follow Live") {
                        followsLive = true
                        proxy.scrollTo("live-end", anchor: .bottom)
                    }.disabled(followsLive || !controller.enabled)
                }
                Text(controller.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if finalized.isEmpty && controller.partials.isEmpty {
                            ContentUnavailableView {
                                Label(
                                    controller.enabled ? "No Live Text Yet" : "Live Transcript Is Off",
                                    systemImage: "text.bubble")
                            } description: {
                                Text(
                                    controller.enabled
                                        ? "Recording continues. You can transcribe the saved audio after recording."
                                        : "Turn on Live Transcript to see text here. You can also transcribe the saved audio after recording."
                                )
                            }
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(LiveTranscriptPresentation.rows(finalized: finalized, partials: controller.partials)) {
                            row in
                            phraseView(row.phrase, provisional: row.provisional)
                        }
                        Color.clear.frame(height: 1).id("live-end")
                    }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(LiveScrollObserver { followsLive = false })
                .onChange(of: controller.partials) { _, _ in
                    if followsLive { proxy.scrollTo("live-end", anchor: .bottom) }
                }
                .onChange(of: finalized) { _, _ in
                    if followsLive { proxy.scrollTo("live-end", anchor: .bottom) }
                }
            }
        }
        .onAppear { refreshFinalized() }
        .onChange(of: controller.draft?.phrases) { _, _ in refreshFinalized() }
    }
    private func refreshFinalized() {
        finalized = (controller.draft?.phrases ?? []).sorted(by: LiveTranscriptPhrase.ordered)
    }
    private func styledText(_ phrase: LiveTranscriptPhrase, provisional: Bool) -> AttributedString {
        var text = AttributedString(phrase.text)
        if provisional, controller.enabled,
            phrase.id == LiveTranscriptPresentation.activePhraseID(controller.partials)
        {
            let ranges = LiveTranscriptPresentation.recentWordRanges(in: phrase)
            for (index, range) in ranges.enumerated() {
                guard let attributedRange = Range(range, in: text) else { continue }
                text[attributedRange].foregroundColor = index == ranges.count - 1 ? .red : trailingWordColor
            }
        }
        return text
    }
    private var trailingWordColor: Color {
        if #available(macOS 15, *) { return .red.mix(with: .primary, by: 0.5) }
        return Color(nsColor: NSColor.systemRed.blended(withFraction: 0.5, of: .labelColor) ?? .systemRed)
    }
    private func phraseView(_ phrase: LiveTranscriptPhrase, provisional: Bool) -> some View {
        TranscriptRow(start: phrase.start, source: phrase.source.title, provisional: provisional) {
            Text(styledText(phrase, provisional: provisional)).foregroundStyle(.primary).textSelection(.enabled)
                .accessibilityLabel(provisional ? "Draft: \(phrase.text)" : phrase.text)
        }
    }
}

/// Observe local native wheel events without intercepting or changing scrolling.
private struct LiveScrollObserver: NSViewRepresentable {
    var scrolled: () -> Void
    func makeNSView(context: Context) -> Observer { Observer(scrolled: scrolled) }
    func updateNSView(_ view: Observer, context: Context) { view.scrolled = scrolled }
    final class Observer: NSView {
        var scrolled: () -> Void
        private var monitor: Any?
        init(scrolled: @escaping () -> Void) {
            self.scrolled = scrolled
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window,
                    self.bounds.contains(self.convert(event.locationInWindow, from: nil)), event.scrollingDeltaY != 0
                {
                    self.scrolled()
                }
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
