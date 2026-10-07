import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

/// Synthetic file verification only. This does not measure Core ML, audio capture, GPU, or ANE work.
@MainActor
struct ModelLifecyclePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_MODEL_LIFECYCLE_PERF"] == "1"))
    func availabilityAndPreparationResourceSample() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(repeating: 17, count: 8 * 1024 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let manager = LocalModelManager(
            root: root,
            descriptor: { id in
                .init(
                    id: id, title: "Synthetic", repository: "synthetic/model", revision: "pinned",
                    assets: [.init(path: "data", remotePath: "data", bytes: Int64(data.count), digest: digest)],
                    modelNames: ["Synthetic"])
            },
            preparer: { _, _ in
                try await Task.sleep(for: .milliseconds(50))
                return [:]
            })
        let directory = manager.modelDirectory(for: .granite97M)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("data"))
        let before = PerformanceResourceSnapshot.capture()
        for _ in 0..<100 { #expect(await manager.health(for: .granite97M) == .ready) }
        let after = PerformanceResourceSnapshot.capture()
        let cold = try await manager.acquire(.granite97M)
        manager.release(cold)
        let warm = try await manager.acquire(.granite97M)
        manager.release(warm)
        let metrics = await manager.lifecycleMetrics()
        print(
            String(
                format:
                    "PERF synthetic model availability: 100 checks, wall %.3f ms, main CPU %.3f ms, process CPU %.3f ms, footprint before %@ bytes after %@ bytes; verification passes %d bytes %lld, preparations %d seconds %.6f",
                (after.monotonicSeconds - before.monotonicSeconds) * 1000,
                (after.mainCPUSeconds - before.mainCPUSeconds) * 1000,
                (after.processCPUSeconds - before.processCPUSeconds) * 1000,
                before.physicalFootprintBytes.map(String.init) ?? "unavailable",
                after.physicalFootprintBytes.map(String.init) ?? "unavailable",
                metrics.verificationPasses, metrics.hashedBytes, metrics.preparationCount, metrics.preparationSeconds))
        #expect(metrics.verificationPasses == 1)
        #expect(metrics.hashedBytes == Int64(data.count))
        #expect(metrics.preparationCount == 2)
        #expect(manager.state(for: .granite97M).inUse == 0)
    }
}
