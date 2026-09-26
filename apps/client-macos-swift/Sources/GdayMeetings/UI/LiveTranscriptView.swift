import AppKit
import SwiftUI

struct LiveTranscriptView: View {
    @ObservedObject var controller: LiveTranscriptController
    @ViewState private var followsLive = true
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Live Transcript", isOn: Binding(get: { controller.enabled }, set: controller.setEnabled))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if !followsLive {
                    Button("Follow Live") { followsLive = true }
                }
            }
            Text(controller.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if controller.enabled {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if (controller.draft?.phrases.count ?? 0) > 100 {
                                Text("Showing the latest 100 phrases. The full draft is saved in Transcript.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(
                                Array((controller.draft?.phrases ?? []).suffix(100)).sorted(
                                    by: LiveTranscriptPhrase.ordered)
                            ) { phrase in
                                phraseView(phrase, provisional: false)
                            }
                            ForEach(controller.partials.sorted(by: LiveTranscriptPhrase.ordered)) { phrase in
                                phraseView(phrase, provisional: true)
                            }
                            Color.clear.frame(height: 1).id("live-end")
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(LiveScrollObserver { followsLive = false })
                    .onChange(of: controller.partials) { _, _ in
                        if followsLive { proxy.scrollTo("live-end", anchor: .bottom) }
                    }
                    .onChange(of: controller.draft?.phrases.count) { _, _ in
                        if followsLive { proxy.scrollTo("live-end", anchor: .bottom) }
                    }
                    .onChange(of: followsLive) { _, follows in
                        if follows { proxy.scrollTo("live-end", anchor: .bottom) }
                    }
                }.frame(minHeight: 65, idealHeight: 110, maxHeight: 150)
            }
        }
    }
    private func phraseView(_ phrase: LiveTranscriptPhrase, provisional: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(phrase.source.title).font(.caption2).foregroundStyle(.secondary)
            Text(phrase.text).foregroundStyle(provisional ? .secondary : .primary).textSelection(.enabled)
                .accessibilityLabel(provisional ? "Draft: \(phrase.text)" : phrase.text)
        }
    }
}

/// Finalized live text remains independently recoverable when batch transcription replaces the editable transcript.
struct SavedLiveTranscriptView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    @ViewState private var draft: LiveTranscriptDraft?
    @ViewState private var failure: String?
    @ViewState private var expanded = false
    @ViewState private var revisions: [TranscriptRevision] = []
    var body: some View {
        Group {
            if let draft {
                DisclosureGroup("Live Draft · This Mac", isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !draft.complete {
                            Text("The live draft may be incomplete.").font(.caption).foregroundStyle(.secondary)
                        }
                        if !draft.gaps.isEmpty {
                            Text("Some audio has no live text. Transcribe the saved recording to include it.").font(
                                .caption
                            ).foregroundStyle(.secondary)
                        }
                        if draft.phrases.isEmpty {
                            Text("No live text was saved. Transcribe the recording to create a transcript.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(draft.segments) { segment in
                            VStack(alignment: .leading, spacing: 4) {
                                Button("\(segment.speaker) · \(RecordingWorkspaceView.elapsed(segment.start))") {
                                    if let meeting = store.meetings.first(where: { $0.id == meetingID }) {
                                        playback.play(
                                            meeting: meeting, files: store.audioURLs(for: meeting), at: segment.start)
                                    }
                                }.buttonStyle(.link).font(.caption)
                                    .help("Play from this point")
                                    .disabled(playback.isPlaybackBlocked || store.recordingID == meetingID)
                                Text(segment.text).textSelection(.enabled)
                            }
                        }
                        Button("Use Live Draft as Transcript") { apply(draft) }
                            .disabled(draft.phrases.isEmpty || !store.libraryWritable || store.recordingID == meetingID)
                        Text(
                            "Keeps the current transcript as a saved revision. Summaries and search use the selected transcript."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !revisions.isEmpty {
                Menu("Saved Transcript Revisions") {
                    ForEach(revisions.reversed()) { revision in
                        Button("\(revision.title) · \(revision.savedAt.formatted(date: .abbreviated, time: .standard))")
                        {
                            store.restoreTranscript(revision, meetingID: meetingID)
                            load()
                        }
                    }
                }.disabled(!store.libraryWritable || store.recordingID == meetingID)
            }
            if let failure { Text(failure).foregroundStyle(.secondary).font(.caption) }
        }
        .task(id: meetingID) {
            load()
            expanded = store.meetings.first(where: { $0.id == meetingID })?.transcript.isEmpty ?? true
        }
        .onChange(of: store.meetings.first { $0.id == meetingID }?.transcript) { _, _ in load() }
        .onChange(of: store.recordingID) { _, _ in load() }
    }
    private func load() {
        failure = nil
        draft = nil
        revisions = []
        do {
            draft = try LiveTranscriptDraft.read(at: store.directory(for: meetingID), meetingID: meetingID)
            revisions = try TranscriptRevisions.read(at: store.directory(for: meetingID)).revisions
        }
        catch { failure = error.localizedDescription }
    }
    private func apply(_ value: LiveTranscriptDraft) {
        guard value.meetingID == meetingID,
            var meeting = store.meetings.first(where: { $0.id == meetingID }), store.preserveTranscript(meeting)
        else { return }
        meeting.transcript = value.segments
        meeting.replaceSpeakers([])
        store.updateMeeting(meeting)
        load()
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
