import Foundation

struct VoiceDiscoveryUnavailable: LocalizedError {
    var errorDescription: String? {
        "Download or verify Community-1 in Service Providers to find voices in unlabeled recordings."
    }
}

/// One job owns this session. Recordings remain isolated results and process sequentially.
actor LocalVoiceRecordingDiscoverer: VoiceRecordingDiscovering {
    private var lease: LocalModelLease?
    private var leaseOwner: LocalModelManager?
    private let worker = CommunityDiarizationWorker()
    func discover(files: [URL]) async throws -> LocalDiarizationResult {
        let manager = await LocalModelManager.shared
        if lease == nil {
            do {
                lease = try await manager.acquire(.community1)
                leaseOwner = manager
            }
            catch LocalModelError.unavailable { throw VoiceDiscoveryUnavailable() }
        }
        guard let lease else { throw VoiceDiscoveryUnavailable() }
        try Task.checkCancellation()
        let worker = worker
        return try await ProcessingCoordinator.shared.withPermit(for: .inference, priority: .processing) {
            try await worker.run(files: files, lease: lease, recognize: true)
        }
    }
    func finish() async {
        guard let lease else { return }
        self.lease = nil
        let owner = leaseOwner
        leaseOwner = nil
        await owner?.release(lease)
    }
}
