import Foundation

/// Synthetic words exercise the transcription-only recording path.
/// This fixture never opens capture hardware or invokes a provider.
@MainActor enum LiveTranscriptPreviewReplay {
    static func start(store: MeetingStore, meetingID: UUID, directory: URL) {
        guard UIPreview.enabled else { return }
        let controller = store.liveTranscript
        controller.begin(
            meetingID: meetingID, language: "zh-Hans", directory: directory,
            sources: [.system], sink: LiveAudioSink(), enabled: true)
        let session = UUID()
        Task { @MainActor [weak store] in
            for index in 0..<180 {
                guard let store, store.recordingID == meetingID else { return }
                let start = Double(index * 2)
                let words = ["这是示例文字", "我们继续讨论", "接下来检查安排"]
                var phrase = LiveTranscriptPhrase(
                    session: session, source: .system, start: start, end: start + 1.8,
                    text: words[index % words.count],
                    words: [
                        .init(text: words[index % words.count], start: start, end: start + 1.8)
                    ], locale: "zh-Hans", recognizedFinal: false)
                controller.receivePreview(phrase, final: false)
                try? await Task.sleep(for: .milliseconds(300))
                guard store.recordingID == meetingID else { return }
                phrase.recognizedFinal = true
                controller.receivePreview(phrase, final: true)
                try? await Task.sleep(for: .milliseconds(700))
                guard store.recordingID == meetingID else { return }

            }
        }
    }
}
