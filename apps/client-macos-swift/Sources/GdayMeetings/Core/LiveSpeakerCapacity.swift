import Foundation

/// Capacity is sticky within a window, independent of name assignments and embeddings.
struct LiveSpeakerCapacity {
    static let establishmentSeconds = 3.0
    static let silenceBoundarySeconds = 0.3
    static let maximumBoundaryWait = 5.0
    static let recentSeconds = 45.0
    private(set) var established: Set<Int> = []
    private var sustained = [Double](repeating: 0, count: 8)
    private var lastActive = [Double](repeating: -.infinity, count: 8)
    private var silence = 0.0
    private var requestedAt: Double?
    private(set) var firstReachedCapacityAt: Double?
    private(set) var saturatedBootstrap = false
    private var bootstrapRecentSlots: Set<Int> = []

    mutating func accept(_ active: [Bool], time: Double, duration: Double = 0.01) {
        guard active.count == 8, time.isFinite, time >= 0, duration.isFinite, duration > 0 else { return }
        for slot in 0..<8 {
            if active[slot] {
                sustained[slot] += duration
                lastActive[slot] = time
                if sustained[slot] + 0.000_001 >= Self.establishmentSeconds { established.insert(slot) }
            }
            else {
                sustained[slot] = 0
            }
        }
        silence = active.contains(true) ? 0 : silence + duration
        if established.count == 8 {
            if firstReachedCapacityAt == nil { firstReachedCapacityAt = time }
            if requestedAt == nil { requestedAt = time }
        }
    }

    mutating func finishBootstrap(at time: Double) {
        saturatedBootstrap = established.count == 8
        bootstrapRecentSlots = Set(lastActive.indices.filter { time - lastActive[$0] <= Self.recentSeconds })
        requestedAt = nil
    }

    mutating func shouldRollover(at time: Double) -> Bool {
        guard established.count == 8 else { return false }
        // A reset that immediately fills all slots does not restore capacity. Retry
        // only after a previous slot has left the retained-audio horizon.
        if saturatedBootstrap {
            guard bootstrapRecentSlots.contains(where: { time - lastActive[$0] > Self.recentSeconds }) else {
                return false
            }
            saturatedBootstrap = false
            requestedAt = time
        }
        if requestedAt == nil { requestedAt = time }
        return silence + 0.000_001 >= Self.silenceBoundarySeconds
            || time - (requestedAt ?? time) >= Self.maximumBoundaryWait
    }
}
