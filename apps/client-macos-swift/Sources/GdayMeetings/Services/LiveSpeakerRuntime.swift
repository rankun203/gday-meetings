import Foundation

/// Capture owns lifecycle and publication; providers own model/stream resources.
protocol LiveSpeakerRuntime: Actor {
    func start(
        model: LocalModelID, sources: [LiveAudioSource], sink: LiveAudioSink,
        boundaries: [LiveAudioSource: Double],
        event: @escaping @Sendable (LiveSpeakerEvent) async -> Void,
        gap: @escaping @Sendable (LiveTranscriptGap) async -> Void,
        failure: @escaping @Sendable (String) async -> Void,
        sample: @escaping @Sendable (LiveSpeakerAudioSample) async -> Void
    ) async throws
    func finish() async -> Bool
    func cancel() async
}

protocol LiveVoiceEmbeddingProcessing: Actor {
    func prepare(priority: ProcessingCoordinator.Priority) async throws
    func extract(_ sample: LiveSpeakerAudioSample, priority: ProcessingCoordinator.Priority) async throws
        -> TypedVoiceEmbedding?
    func cancel() async
}

extension LocalLiveDiarization: LiveSpeakerRuntime {}
extension LiveVoiceEmbeddingWorker: LiveVoiceEmbeddingProcessing {}
