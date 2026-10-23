import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct LiveTranscriptionActivityTests {
    @Test(.timeLimit(.minutes(1)))
    func stopDisposesAudioQueuedBeforeControllerStartup() async throws {
        let probe = PreparationProbe()
        let controller = LiveTranscriptController { language, activity in
            try await probe.prepare(language, activity: activity)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = LiveAudioQueue(bufferDuringPreparation: true)
        let sink = LiveAudioSink()
        sink.replace([.microphone: queue])
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80))
        buffer.frameLength = 80
        buffer.floatChannelData![0].initialize(repeating: 0, count: 80)
        sink.append(buffer, start: 0, source: .microphone)
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory,
            sources: [.microphone], sink: sink, enabled: true, preparedQueues: [.microphone: queue])
        let pending = await probe.next()
        await controller.finish()
        var iterator = queue.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        pending.completion.resume(throwing: CancellationError())
    }

    @Test(.timeLimit(.minutes(1)))
    func preparationFailureCanRetryAndRejectsOldMessages() async throws {
        let probe = PreparationProbe()
        let controller = LiveTranscriptController { language, activity in
            try await probe.prepare(language, activity: activity)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory,
            sources: [.microphone], sink: LiveAudioSink(), enabled: true)
        let first = await probe.next()
        #expect(controller.activity == .loading("Preparing en"))
        let phrase = LiveTranscriptPhrase(
            session: UUID(), source: .microphone, start: 0, end: 1, text: "Keep this text.")
        controller.receive(phrase, final: true, token: controller.generation)
        first.completion.resume(throwing: MeetingError.message("Download failed."))
        while controller.activity.isLoading { await Task.yield() }
        #expect(controller.activity == .failed("Download failed."))
        #expect(controller.enabled)
        await first.activity(.loading("Late loading after failure"))
        #expect(controller.activity == .failed("Download failed."))

        controller.retryTranscription()
        let retry = await probe.next()
        await first.activity(.loading("Stale download"))
        #expect(controller.activity == .loading("Preparing en"))
        #expect(controller.liveTranscriptIssues.isEmpty)
        #expect(controller.presentedStream.snapshot.phrases.contains { $0.text == "Keep this text." })
        retry.completion.resume(throwing: MeetingError.message("Retry failed."))
        while controller.activity.isLoading { await Task.yield() }
        #expect(controller.activity == .failed("Retry failed."))
        await controller.finish()
        #expect(controller.activity == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func languageChangeAndStopRejectPendingPreparation() async throws {
        let probe = PreparationProbe()
        let controller = LiveTranscriptController { language, activity in
            try await probe.prepare(language, activity: activity)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory,
            sources: [.microphone], sink: LiveAudioSink(), enabled: true)
        let original = await probe.next()
        controller.changeLanguage("fr")
        let replacement = await probe.next()
        await original.activity(.loading("Old language"))
        #expect(controller.activity == .loading("Preparing fr"))
        original.completion.resume(throwing: CancellationError())

        await controller.finish()
        await replacement.activity(.loading("Download completed after Stop"))
        #expect(controller.activity == .idle)
        replacement.completion.resume(throwing: CancellationError())
        controller.retryTranscription()
        #expect(controller.activity == .idle)
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppedPreparationReturningSuccessCannotStartRecognition() async {
        let probe = PreparationProbe()
        let controller = LiveTranscriptController { language, activity in
            try await probe.prepare(language, activity: activity)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory,
            sources: [.microphone], sink: LiveAudioSink(), enabled: true)
        let pending = await probe.next()
        await controller.finish()
        pending.completion.resume(returning: Locale(identifier: "en-US"))
        await Task.yield()
        #expect(controller.activity == .idle)
        #expect(controller.presentedStream.snapshot.phrases.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func disablingTranscriptionClearsLoadingAndIgnoresLateStatus() async {
        let probe = PreparationProbe()
        let controller = LiveTranscriptController { language, activity in
            try await probe.prepare(language, activity: activity)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory,
            sources: [.system], sink: LiveAudioSink(), enabled: true)
        let pending = await probe.next()
        controller.setEnabled(false)
        await pending.activity(.loading("Late preparation"))
        #expect(controller.activity == .idle)
        #expect(!controller.enabled)
        pending.completion.resume(throwing: CancellationError())
        await controller.finish()
    }
}

private actor PreparationProbe {
    struct Call: Sendable {
        let activity: @Sendable (ProviderActivity) async -> Void
        let completion: CheckedContinuation<Locale, any Error>
    }
    private var calls: [Call] = []
    private var observer: CheckedContinuation<Call, Never>?

    func prepare(_ language: String, activity: @escaping @Sendable (ProviderActivity) async -> Void) async throws
        -> Locale
    {
        await activity(.loading("Preparing \(language)"))
        return try await withCheckedThrowingContinuation { completion in
            let call = Call(activity: activity, completion: completion)
            if let observer {
                self.observer = nil
                observer.resume(returning: call)
            }
            else {
                calls.append(call)
            }
        }
    }

    func next() async -> Call {
        if !calls.isEmpty { return calls.removeFirst() }
        return await withCheckedContinuation { observer = $0 }
    }
}
