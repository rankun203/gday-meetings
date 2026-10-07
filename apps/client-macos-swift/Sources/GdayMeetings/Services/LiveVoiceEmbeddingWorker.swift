import Foundation

/// Optional voice work has one bounded job and never waits on capture delivery.
actor LiveVoiceEmbeddingWorker {
    private var lease: LocalModelLease?
    private var extractor: CommunityVoiceEmbeddingExtractor?
    private var cancelled = false
    private var activeExtractions = 0

    func prepare(priority: ProcessingCoordinator.Priority = .capture) async throws {
        let acquired = try await LocalModelManager.shared.acquire(.voiceEmbedding, priority: priority)
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

    func extract(_ sample: LiveSpeakerAudioSample, priority: ProcessingCoordinator.Priority = .capture) async throws
        -> TypedVoiceEmbedding?
    {
        guard let extractor, !cancelled, !Task.isCancelled else { throw CancellationError() }
        activeExtractions += 1
        let values: [Double]
        do {
            values = try await ProcessingCoordinator.shared.withPermit(for: .inference, priority: priority) {
                try await extractor.extract(samples: sample.samples)
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
            type: .community1, values: values,
            provenance: "live-clean-single-speaker-span")
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
