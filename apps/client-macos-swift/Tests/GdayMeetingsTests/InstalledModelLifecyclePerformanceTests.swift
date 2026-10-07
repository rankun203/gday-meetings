import Foundation
import Testing

@testable import GdayMeetings

/// Opt-in native inference using copied assets and synthetic text. No library or capture access.
@MainActor
struct InstalledModelLifecyclePerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_INSTALLED_MODEL_SOURCE"] != nil))
    func nativeQueryPreparationAndRelease() async throws {
        let source = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["GDAY_INSTALLED_MODEL_SOURCE"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("model-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = LocalModelManager(root: root)
        let id = LocalModelID.granite97M
        let descriptor = LocalModelRegistry.descriptor(id)
        let destination = manager.modelDirectory(for: id)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appendingPathComponent(id.rawValue).appendingPathComponent(descriptor.revision), to: destination)
        // The copied identity differs; force this run to establish its own verification receipt.
        let receipt = destination.appendingPathComponent(".gday-validation.json")
        if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }

        var previous = PerformanceResourceSnapshot.capture()
        func report(_ phase: String) async throws {
            let current = PerformanceResourceSnapshot.capture()
            let metrics = await manager.lifecycleMetrics()
            let fields: [String: Any] = [
                "phase": phase,
                "wall_seconds": current.monotonicSeconds - previous.monotonicSeconds,
                "main_cpu_seconds": current.mainCPUSeconds - previous.mainCPUSeconds,
                "process_cpu_seconds": current.processCPUSeconds - previous.processCPUSeconds,
                "footprint_bytes": current.physicalFootprintBytes.map { $0 as Any } ?? NSNull(),
                "loaded_graphs": metrics.loadedModelCount,
                "preparations": metrics.preparationCount,
                "hashed_bytes": metrics.hashedBytes,
                "leases": manager.state(for: id).inUse,
            ]
            print(
                "PERF_NATIVE_MODEL "
                    + String(
                        decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                        as: UTF8.self))
            previous = current
        }
        for _ in 0..<100 { #expect(await manager.health(for: id) == .ready) }
        let available = await manager.lifecycleMetrics()
        #expect(available.loadedModelCount == 0)
        #expect(available.hashedBytes == 0)
        try await report("availability_100")

        let encoder = CoreMLSemanticEmbedding(modelID: .granite97M, manager: manager)
        try await encoder.prepare()
        try await report("query_prepare")
        for _ in 0..<5 {
            try await encoder.prepare()
            let vector = try await encoder.embed("When is the next planning meeting?", isQuery: true)
            #expect(vector.count == SemanticModelID.granite97M.dimensions)
            #expect(vector.allSatisfy { $0.isFinite })
        }
        let reused = await manager.lifecycleMetrics()
        #expect(reused.preparationCount == 1)
        #expect(reused.loadedModelCount == 1)
        #expect(reused.verificationPasses == 1)
        #expect(manager.state(for: id).inUse == 1)
        try await report("five_queries")
        await encoder.unload()
        #expect(manager.state(for: id).inUse == 0)
        try await report("release")
        #expect(await manager.validate(id) == .ready)
        #expect(await manager.lifecycleMetrics().loadedModelCount == 1)
        try await report("cached_validation")
        for cycle in 1...5 {
            try await encoder.prepare()
            _ = try await encoder.embed("What was decided about the schedule?", isQuery: true)
            await encoder.unload()
            try await Task.sleep(for: .seconds(1))
            #expect(manager.state(for: id).inUse == 0)
            try await report("reload_release_\(cycle)")
        }
        let final = await manager.lifecycleMetrics()
        #expect(final.loadedModelCount == 6)
        #expect(final.preparationCount == 6)
        #expect(final.verificationPasses == 1)
    }
}
