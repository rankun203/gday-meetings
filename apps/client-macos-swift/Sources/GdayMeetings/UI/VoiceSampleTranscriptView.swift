import SwiftUI

/// The review detail pane owns scrolling; the excerpt grows with its text while
/// review decisions remain pinned outside that shared viewport.
struct VoiceSampleTranscriptView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let example: VoiceExample
    @ViewState private var passages: [VoiceSampleTranscript.Passage] = []
    @ViewState private var loadedExample: VoiceSampleTranscript.Request?
    @ViewState private var loading = true
    @ViewState private var request = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if loading || loadedExample != VoiceSampleTranscript.Request(example) {
                ProgressView("Loading transcript…").controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            else if passages.isEmpty {
                Text("Transcript unavailable.").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            else {
                VoiceSampleTranscriptContent(
                    example: example, passages: passages, progress: playback.progress,
                    playbackMeetingID: playback.meetingID, audioFile: matchingAudioFile,
                    excerptRanges: playback.excerptRanges)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .modifier(AppContentSurface())
        .task(id: VoiceSampleTranscript.Request(example)) { await load() }
        .onDisappear { request = UUID() }
    }

    private var matchingAudioFile: String? {
        guard let file = example.audioFile,
            let playingURL = playback.audioURL(forTrack: playback.selectedTrack),
            playingURL.standardizedFileURL
                == store.directory(for: example.meetingID).appendingPathComponent(file).standardizedFileURL
        else { return nil }
        return file
    }

    private func load() async {
        let token = UUID()
        request = token
        loading = true
        loadedExample = nil
        passages = []
        let directory = store.dataDirectory
        guard await store.ensureMeetingLoaded(id: example.meetingID),
            !Task.isCancelled, request == token, store.dataDirectory == directory,
            let meeting = store.meeting(id: example.meetingID)
        else {
            if !Task.isCancelled, request == token {
                loadedExample = VoiceSampleTranscript.Request(example)
                loading = false
            }
            return
        }
        let sample = example
        let worker = Task.detached(priority: .userInitiated) {
            try VoiceSampleTranscript.passages(for: sample, meeting: meeting)
        }
        let result = try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, request == token, store.dataDirectory == directory else { return }
        passages = result ?? []
        loadedExample = VoiceSampleTranscript.Request(example)
        loading = false
    }
}

private struct VoiceSampleTranscriptContent: View {
    let example: VoiceExample
    let passages: [VoiceSampleTranscript.Passage]
    @ObservedObject var progress: PlaybackProgress
    let playbackMeetingID: UUID?
    let audioFile: String?
    let excerptRanges: [Range<Double>]

    private var time: Double? {
        VoiceSampleTranscript.playbackTime(
            for: example, meetingID: playbackMeetingID, audioFile: audioFile,
            excerptRanges: excerptRanges, time: progress.displayedTime)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(passages) { passage in
                Text(highlighted(passage))
                    .font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample transcript")
    }

    private func highlighted(_ passage: VoiceSampleTranscript.Passage) -> AttributedString {
        var value = AttributedString(passage.text)
        for offset in passage.highlightedRanges(at: time) {
            guard let range = Range(NSRange(location: offset.location, length: offset.length), in: passage.text),
                let start = AttributedString.Index(range.lowerBound, within: value),
                let end = AttributedString.Index(range.upperBound, within: value)
            else { continue }
            value[start..<end].backgroundColor = Color.accentColor.opacity(0.24)
        }
        return value
    }
}
