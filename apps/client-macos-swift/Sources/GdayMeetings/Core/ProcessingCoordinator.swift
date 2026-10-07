import Foundation

/// Admission is bounded around actual work, never around an idle model lease.
actor ProcessingCoordinator {
    enum Resource: Sendable, Hashable {
        case modelPreparation, inference, communityInference, storage
        var capacity: Int { self == .communityInference ? 1 : 2 }
    }
    enum Priority: Int, Sendable {
        case maintenance, processing, interactive, capture
    }
    static let shared = ProcessingCoordinator()
    private struct Waiter {
        let id: UUID
        let resource: Resource
        let priority: Priority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private var admitted: [UUID: Resource] = [:]
    private var waiting: [Waiter] = []
    private var sequence: UInt64 = 0
    private var suspendedOwners: Set<UUID?> = []
    private var suspensionGenerations: [UUID?: UInt64] = [:]
    private var maintenanceSuspended: Bool { !suspendedOwners.isEmpty }
    var pendingCount: Int { waiting.count }

    func setMaintenanceSuspended(_ suspended: Bool, generation: UInt64? = nil, owner: UUID? = nil) {
        if let generation {
            guard generation >= suspensionGenerations[owner, default: 0] else { return }
            suspensionGenerations[owner] = generation
        }
        if suspended {
            suspendedOwners.insert(owner)
        }
        else {
            suspendedOwners.remove(owner)
        }
        drain()
    }

    func releaseOwner(_ owner: UUID) {
        suspendedOwners.remove(owner)
        suspensionGenerations.removeValue(forKey: owner)
        drain()
    }

    func withPermit<T: Sendable>(
        for resource: Resource, priority: Priority,
        waiting: @Sendable (String) -> Void = { _ in },
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sequence &+= 1
                self.waiting.append(
                    Waiter(
                        id: id, resource: resource, priority: priority, sequence: sequence, continuation: continuation))
                drain()
                if admitted[id] == nil {
                    waiting(
                        waitsForRecording(resource: resource, priority: priority)
                            ? "Waiting for recording to finish" : "Waiting for local processing")
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await operation()
                release(id)
                return result
            }
            catch {
                release(id)
                throw error
            }
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }
    private func release(_ id: UUID) {
        admitted.removeValue(forKey: id)
        drain()
    }
    private func waitsForRecording(resource: Resource, priority: Priority) -> Bool {
        maintenanceSuspended
            && (priority == .maintenance || resource != .storage && priority == .processing)
    }
    private func drain() {
        waiting.sort {
            $0.priority == $1.priority ? $0.sequence < $1.sequence : $0.priority.rawValue > $1.priority.rawValue
        }
        var index = 0
        while index < waiting.count {
            let waiter = waiting[index]
            if waitsForRecording(resource: waiter.resource, priority: waiter.priority)
                || admitted.values.filter({ $0 == waiter.resource }).count >= waiter.resource.capacity
                || waiter.resource != .storage && waiter.priority.rawValue < Priority.interactive.rawValue
                    && admitted.values.filter({ $0 == waiter.resource }).count >= 1
            {
                index += 1
                continue
            }
            waiting.remove(at: index)
            admitted[waiter.id] = waiter.resource
            waiter.continuation.resume()
        }
    }
}
