import Foundation
import Testing

@testable import GdayMeetings

private actor ControlledSpeakerRuntime: LiveSpeakerRuntime {
    var eventCallback: (@Sendable (LiveSpeakerEvent) async -> Void)?
    var sampleCallback: (@Sendable (LiveSpeakerAudioSample) async -> Void)?
    var finalSample: LiveSpeakerAudioSample?
    var finished = false
    var started: Bool { eventCallback != nil }
    func start(
        model: LocalModelID, sources: [LiveAudioSource], sink: LiveAudioSink,
        boundaries: [LiveAudioSource: Double], event: @escaping @Sendable (LiveSpeakerEvent) async -> Void,
        gap: @escaping @Sendable (LiveTranscriptGap) async -> Void,
        failure: @escaping @Sendable (String) async -> Void,
        sample: @escaping @Sendable (LiveSpeakerAudioSample) async -> Void
    ) async throws {
        eventCallback = event
        sampleCallback = sample
    }
    func emit(_ event: LiveSpeakerEvent, sample: LiveSpeakerAudioSample) async {
        await eventCallback?(event)
        await sampleCallback?(sample)
    }
    func emitSample(_ sample: LiveSpeakerAudioSample) async { await sampleCallback?(sample) }
    func finishWith(_ sample: LiveSpeakerAudioSample) { finalSample = sample }
    func finish() async -> Bool {
        if let finalSample { await sampleCallback?(finalSample) }
        finished = true
        return true
    }
    func cancel() async {}
}

private actor ControlledVoiceWorker: LiveVoiceEmbeddingProcessing {
    var prepares = 0
    var cancels = 0
    var extracted: [Double] = []
    var prepareGate: CheckedContinuation<Void, Never>?
    var extractionGate: CheckedContinuation<Void, Never>?
    func prepare(priority: ProcessingCoordinator.Priority) async throws {
        prepares += 1
        await withCheckedContinuation { prepareGate = $0 }
    }
    func releasePreparation() {
        prepareGate?.resume()
        prepareGate = nil
    }
    func releaseExtraction() {
        extractionGate?.resume()
        extractionGate = nil
    }
    func extract(_ sample: LiveSpeakerAudioSample, priority: ProcessingCoordinator.Priority) async throws
        -> TypedVoiceEmbedding?
    {
        extracted.append(sample.start)
        if extracted.count == 1 { await withCheckedContinuation { extractionGate = $0 } }
        return .init(
            type: .init(
                modelID: "synthetic", revision: "1", compatibilityVersion: "1", dimension: 2,
                normalization: "unitL2"), values: [1, 0])
    }
    func cancel() async {
        cancels += 1
        releasePreparation()
        releaseExtraction()
    }
}

@MainActor struct LiveObservationLifecycleTests {
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw MeetingError.message("Controlled runtime did not advance")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @Test(arguments: [false, true])
    func preparationQueueNamingToggleAndFinalCallbacksAreDrainedBeforeSeal(reviewTimesOut: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = ControlledSpeakerRuntime()
        let worker = ControlledVoiceWorker()
        let controller = LiveTranscriptController(
            speakerRuntime: { runtime }, voiceWorker: { worker }, reviewDrainTimeout: reviewTimesOut ? 0.05 : 5)
        var reviewGate: CheckedContinuation<Void, Never>?
        var reviewSizes: [Int] = []
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory, sources: [.microphone],
            sink: LiveAudioSink(), enabled: false, diarizationProvider: .init(kind: .speakerLabeling),
            speakerLabelsEnabled: true, speakerRecognitionEnabled: false, observationPolicy: .init(),
            observationReview: { snapshot in
                reviewSizes.append(snapshot.count)
                if reviewSizes.count == 1 { await withCheckedContinuation { reviewGate = $0 } }
                return true
            })
        try await wait {
            let started = await runtime.started
            let prepares = await worker.prepares
            return started && prepares == 1
        }
        let local = UUID()
        let generation = UUID()
        func sample(_ start: Double) -> LiveSpeakerAudioSample {
            .init(
                speakerID: local, source: .microphone, generation: generation,
                start: start, end: start + 3, samples: [0.1])
        }
        let event = LiveSpeakerEvent(
            source: .microphone, generation: generation, sequence: 0,
            speakers: [
                .init(
                    id: local, source: .microphone, generation: generation, slot: 0,
                    model: "synthetic", revision: "1")
            ],
            intervals: [.init(speakerID: local, start: 0, end: 10)], start: 0, end: 10,
            continuity: .init(
                generation: generation.uuidString, source: LiveAudioSource.microphone.rawValue,
                localSpeakerIDs: [local.uuidString],
                publicationStart: 0, observedEnd: 10, policyRevision: SpeakerEvidenceWindow.protectedPolicy))
        await runtime.emit(event, sample: sample(0))
        controller.setSpeakerRecognitionEnabled(true)
        controller.setSpeakerRecognitionEnabled(false)
        #expect(await worker.prepares == 1)
        #expect(await worker.cancels == 0)
        await worker.releasePreparation()
        try await wait { await worker.extracted.count == 1 }
        await runtime.finishWith(sample(5))
        var didFinish = false
        let finishing = Task {
            await controller.finish()
            didFinish = true
        }
        try await wait { await runtime.finished }
        await worker.releaseExtraction()
        try await wait { reviewGate != nil }
        try await wait { (try? SpeakerEvidenceStore.read(directory: directory).samples.count) == 2 }
        if !reviewTimesOut { #expect(!didFinish) }
        if reviewTimesOut {
            await finishing.value
            #expect(controller.liveTranscriptIssues.contains { $0.contains("review examples did not finish") })
            reviewGate?.resume()
        }
        else {
            reviewGate?.resume()
            await finishing.value
            #expect(reviewSizes.last == 2)
        }
        #expect(await worker.extracted == [0, 5])
        let evidence = try SpeakerEvidenceStore.read(directory: directory)
        #expect(evidence.samples.map(\.start) == [0, 5])
        #expect(try SpeakerEvidenceStore.isComplete(directory: directory))
        #expect(controller.speakerEvidenceComplete)
        #expect(controller.draft?.speakerTimeline?.speakers.contains { $0.voiceEmbedding != nil } == true)
        let before = evidence.samples.count
        await runtime.emitSample(sample(7))
        #expect(try SpeakerEvidenceStore.read(directory: directory).samples.count == before)
    }
    @Test func anonymousEmbeddingsFollowLabelTogglesWithNamingAlwaysOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let runtime = ControlledSpeakerRuntime()
        let worker = ControlledVoiceWorker()
        let controller = LiveTranscriptController(speakerRuntime: { runtime }, voiceWorker: { worker })
        controller.begin(
            meetingID: UUID(), language: "en", directory: directory, sources: [.microphone],
            sink: LiveAudioSink(), enabled: false, diarizationProvider: .init(kind: .speakerLabeling),
            speakerLabelsEnabled: false, speakerRecognitionEnabled: false, observationPolicy: .init())
        #expect(await worker.prepares == 0)
        controller.setSpeakerLabelsEnabled(true)
        try await wait { await worker.prepares == 1 }
        await worker.releasePreparation()
        try await wait { controller.speakerRecognitionStatus.contains("is ready") }
        // Disabling labels must release anonymous analysis even though naming
        // was never enabled. Wait for that cancellation before starting again.
        controller.setSpeakerLabelsEnabled(false)
        try await wait { await worker.cancels > 0 }
        controller.setSpeakerLabelsEnabled(true)
        try await wait { await worker.prepares == 2 }
        await worker.releasePreparation()
        try await wait { controller.speakerRecognitionStatus.contains("is ready") }
        let local = UUID()
        let generation = UUID()
        let sample = LiveSpeakerAudioSample(
            speakerID: local, source: .microphone, generation: generation,
            start: 0, end: 3, samples: [0.1])
        let event = LiveSpeakerEvent(
            source: .microphone, generation: generation, sequence: 0,
            speakers: [
                .init(
                    id: local, source: .microphone, generation: generation, slot: 0,
                    model: "synthetic", revision: "1")
            ],
            intervals: [.init(speakerID: local, start: 0, end: 4)], start: 0, end: 4,
            continuity: .init(
                generation: generation.uuidString, source: LiveAudioSource.microphone.rawValue,
                localSpeakerIDs: [local.uuidString], publicationStart: 0, observedEnd: 4,
                policyRevision: SpeakerEvidenceWindow.protectedPolicy))
        await runtime.emit(event, sample: sample)
        try await wait { await worker.extracted.count == 1 }
        await worker.releaseExtraction()
        await controller.finish()
        #expect(try SpeakerEvidenceStore.read(directory: directory).samples.count == 1)
        #expect(controller.speakerEvidenceComplete)
        #expect(controller.draft?.speakerTimeline?.speakers.contains { $0.voiceEmbedding != nil } == true)
        #expect(controller.draft?.speakerTimeline?.speakers.allSatisfy { $0.personID == nil } == true)
    }

}
