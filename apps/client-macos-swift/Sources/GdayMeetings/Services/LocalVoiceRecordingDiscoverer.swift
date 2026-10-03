import Foundation

struct VoiceDiscoveryUnavailable: LocalizedError {
    var errorDescription: String? {
        "Download or verify Community-1 in Service Providers to find voices in unlabeled recordings."
    }
}

/// Discovery owns an isolated result. It never applies labels to the saved transcript.
actor LocalVoiceRecordingDiscoverer: VoiceRecordingDiscovering {
    func discover(files: [URL]) async throws -> LocalDiarizationResult {
        let manager = await LocalModelManager.shared
        let lease: LocalModelLease
        do { lease = try await manager.acquire(.community1) }
        catch is CancellationError { throw CancellationError() }
        catch { throw VoiceDiscoveryUnavailable() }
        do {
            let result = try await CommunityDiarizationWorker().run(files: files, lease: lease, recognize: true)
            await manager.release(lease)
            return result
        }
        catch {
            await manager.release(lease)
            throw error
        }
    }
}
