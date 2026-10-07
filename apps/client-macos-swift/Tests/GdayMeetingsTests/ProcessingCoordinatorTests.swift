import Foundation
import Testing

@testable import GdayMeetings

private actor ProcessingTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ProcessingTestOrder {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}

struct ProcessingCoordinatorTests {
    @Test func sharedCommunityInferenceNeverOverlapsEvenForCapture() async throws {
        let coordinator = ProcessingCoordinator()
        let gate = ProcessingTestGate()
        let order = ProcessingTestOrder()
        let first = Task {
            try await coordinator.withPermit(for: .communityInference, priority: .processing) {
                await order.add("offline")
                await gate.wait()
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !gate.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        let capture = Task {
            try await coordinator.withPermit(for: .communityInference, priority: .capture) {
                await order.add("capture")
            }
        }
        try await pending(1, in: coordinator)
        #expect(await order.values == ["offline"])
        await gate.open()
        try await first.value
        try await capture.value
        #expect(await order.values == ["offline", "capture"])
    }

    private func pending(_ count: Int, in coordinator: ProcessingCoordinator) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await coordinator.pendingCount != count, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await coordinator.pendingCount == count)
    }

    @Test func cancelledWaiterDoesNotConsumeCapacity() async throws {
        let coordinator = ProcessingCoordinator()
        await coordinator.setMaintenanceSuspended(true)
        let waiting = Task {
            try await coordinator.withPermit(for: .inference, priority: .maintenance) { 1 }
        }
        try await pending(1, in: coordinator)
        waiting.cancel()
        do {
            _ = try await waiting.value
            Issue.record("Cancelled maintenance was admitted.")
        }
        catch { #expect(error is CancellationError) }
        try await pending(0, in: coordinator)
        await coordinator.setMaintenanceSuspended(false)
        #expect(try await coordinator.withPermit(for: .inference, priority: .interactive) { 2 } == 2)
    }

    @Test func interactiveWorkRunsBeforeQueuedMaintenanceAtTheNextUnitBoundary() async throws {
        let coordinator = ProcessingCoordinator()
        let gate = ProcessingTestGate()
        let reservedGate = ProcessingTestGate()
        let order = ProcessingTestOrder()
        let first = Task {
            try await coordinator.withPermit(for: .storage, priority: .processing) {
                await order.add("first")
                await gate.wait()
            }
        }
        let reserved = Task {
            try await coordinator.withPermit(for: .storage, priority: .processing) { await reservedGate.wait() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !reservedGate.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        while await !gate.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        let maintenance = Task {
            try await coordinator.withPermit(for: .storage, priority: .maintenance) { await order.add("maintenance") }
        }
        try await pending(1, in: coordinator)
        let interactive = Task {
            try await coordinator.withPermit(for: .storage, priority: .interactive) { await order.add("interactive") }
        }
        try await pending(2, in: coordinator)
        #expect(await order.values == ["first"])
        await gate.open()
        try await first.value
        try await interactive.value
        try await maintenance.value
        await reservedGate.open()
        try await reserved.value
        #expect(await order.values == ["first", "interactive", "maintenance"])
    }

    @Test func captureAndInteractiveWorkHaveCapacityBesideBackgroundWork() async throws {
        let coordinator = ProcessingCoordinator()
        let gate = ProcessingTestGate()
        let first = Task {
            try await coordinator.withPermit(for: .inference, priority: .processing) { await gate.wait() }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await !gate.isWaiting, ContinuousClock.now < deadline { await Task.yield() }
        #expect(try await coordinator.withPermit(for: .inference, priority: .capture) { 7 } == 7)
        #expect(try await coordinator.withPermit(for: .inference, priority: .interactive) { 8 } == 8)
        await gate.open()
        try await first.value
    }

    @Test func staleResumeCannotUnsuspendANewerRecording() async throws {
        let coordinator = ProcessingCoordinator()
        await coordinator.setMaintenanceSuspended(true, generation: 3)
        await coordinator.setMaintenanceSuspended(false, generation: 2)
        let work = Task {
            try await coordinator.withPermit(for: .inference, priority: .maintenance) { 1 }
        }
        try await pending(1, in: coordinator)
        await coordinator.setMaintenanceSuspended(false, generation: 4)
        #expect(try await work.value == 1)
    }

    @Test func recordingDefersNewProcessingButKeepsCaptureAndInteractiveAdmission() async throws {
        let coordinator = ProcessingCoordinator()
        await coordinator.setMaintenanceSuspended(true)
        let processing = Task {
            try await coordinator.withPermit(for: .inference, priority: .processing) { 3 }
        }
        try await pending(1, in: coordinator)
        #expect(try await coordinator.withPermit(for: .inference, priority: .capture) { 1 } == 1)
        #expect(try await coordinator.withPermit(for: .modelPreparation, priority: .interactive) { 2 } == 2)
        try await pending(1, in: coordinator)
        await coordinator.setMaintenanceSuspended(false)
        #expect(try await processing.value == 3)
    }

    @Test func recordingGenerationsBelongToTheirOwner() async throws {
        let coordinator = ProcessingCoordinator()
        let first = UUID()
        let second = UUID()
        await coordinator.setMaintenanceSuspended(true, generation: 9, owner: first)
        await coordinator.setMaintenanceSuspended(false, generation: 10, owner: first)
        await coordinator.setMaintenanceSuspended(true, generation: 1, owner: second)
        await coordinator.setMaintenanceSuspended(false, generation: 11, owner: first)
        await coordinator.releaseOwner(first)
        let work = Task {
            try await coordinator.withPermit(for: .inference, priority: .maintenance) { 1 }
        }
        try await pending(1, in: coordinator)
        await coordinator.setMaintenanceSuspended(false, generation: 2, owner: second)
        #expect(try await work.value == 1)
    }
}
