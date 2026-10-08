import Foundation

struct VoiceEmbeddingAudioSample: Sendable {
    var start: Double
    var end: Double
    var samples: [Float]
    var spans: [SpeakerEvidenceSpan]? = nil
}

/// Extracts saved speech examples using the shared, bounded inference coordinator.
actor VoiceEmbeddingWorker {
    private var lease: LocalModelLease?
    private var extractor: CommunityVoiceEmbeddingExtractor?
    private var cancelled = false
    private var activeExtractions = 0

    func prepare(priority: ProcessingCoordinator.Priority = .processing) async throws {
        let acquired = try await LocalModelManager.shared.acquire(
            .community1, modelNames: ["FBank", "Embedding"], priority: priority)
        guard !cancelled, !Task.isCancelled else {
            await LocalModelManager.shared.release(acquired)
            throw CancellationError()
        }
        do {
            let extractor = try CommunityVoiceEmbeddingExtractor(models: acquired.models)
            self.extractor = extractor
            lease = acquired
        }
        catch {
            await LocalModelManager.shared.release(acquired)
            throw error
        }
    }

    func extract(_ sample: VoiceEmbeddingAudioSample, priority: ProcessingCoordinator.Priority = .processing)
        async throws
        -> TypedVoiceEmbedding?
    {
        guard Self.hasValidPhysicalSupport(sample) else {
            throw ServiceError("The voice sample does not match its recorded speech ranges.")
        }
        guard let extractor, !cancelled, !Task.isCancelled else { throw CancellationError() }
        activeExtractions += 1
        let values: [Double]
        do {
            values = try await ProcessingCoordinator.shared.withPermit(for: .inference, priority: priority) {
                try await ProcessingCoordinator.shared.withPermit(for: .communityInference, priority: priority) {
                    try await extractor.extract(samples: sample.samples)
                }
            }
        }
        catch {
            activeExtractions -= 1
            await releaseIfCancelled()
            throw error
        }
        activeExtractions -= 1
        await releaseIfCancelled()
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        return TypedVoiceEmbedding.normalizing(
            type: CommunityVoiceEmbeddingExtractor.embeddingType, values: values,
            provenance: sample.spans == nil ? "saved-example-speech-span" : "saved-example-clean-fragments-v1")
    }

    nonisolated static func hasValidPhysicalSupport(_ sample: VoiceEmbeddingAudioSample) -> Bool {
        guard let spans = sample.spans else { return true }
        guard !spans.isEmpty, spans.first?.start == sample.start, spans.last?.end == sample.end else { return false }
        var end = -Double.infinity
        var duration = 0.0
        for span in spans {
            guard span.start.isFinite, span.end.isFinite, span.start >= 0,
                span.end > span.start, span.start >= end
            else { return false }
            end = span.end
            duration += span.end - span.start
        }
        // Every boundary is rounded independently at 16 kHz. Allow one frame
        // per boundary, never silence padding or an entire enclosing gap.
        return abs(Double(sample.samples.count) - duration * 16_000) <= Double(spans.count * 2)
            && sample.samples.allSatisfy { $0.isFinite }
    }

    func cancel() async {
        cancelled = true
        extractor = nil
        await releaseIfCancelled()
    }

    private func releaseIfCancelled() async {
        guard cancelled, activeExtractions == 0, let lease else { return }
        self.lease = nil
        await LocalModelManager.shared.release(lease)
    }
}
