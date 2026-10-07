import Foundation

/// Compile with the experimental LiveSpeakerCapacity.swift; no app or model imports.
@main struct CapacityPolicyChecks {
    enum Failure: Error { case check(String) }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.check(message) }
    }

    static func feed(
        _ slots: Set<Int>, frames: Int, capacity: inout LiveSpeakerCapacity, time: inout Double
    ) {
        for _ in 0..<frames {
            capacity.accept((0..<8).map { slots.contains($0) }, time: time)
            time += 0.01
        }
    }

    static func repeatedShortTurns() throws {
        var capacity = LiveSpeakerCapacity()
        var time = 0.0
        for _ in 0..<3 {
            for slot in 0..<8 {
                feed([slot], frames: 100, capacity: &capacity, time: &time)
                feed([], frames: 20, capacity: &capacity, time: &time)
            }
        }
        try require(capacity.established.count == 8, "Three separate one-second turns must establish each channel")
        try require(capacity.firstReachedCapacityAt != nil, "The eighth channel must record the capacity timestamp")
        feed([], frames: 10, capacity: &capacity, time: &time)
        try require(capacity.shouldRollover(at: time), "A 300 ms silence permits handoff")
    }

    static func rejectsIsolatedBlipsAndCreditsThresholdOnce() throws {
        var capacity = LiveSpeakerCapacity()
        var time = 0.0
        for _ in 0..<100 {
            feed(Set(0..<8), frames: 29, capacity: &capacity, time: &time)
            feed([], frames: 1, capacity: &capacity, time: &time)
        }
        try require(capacity.established.isEmpty, "Runs shorter than 300 ms must contribute no evidence")
        for _ in 0..<9 {
            feed([0], frames: 30, capacity: &capacity, time: &time)
            feed([], frames: 1, capacity: &capacity, time: &time)
        }
        try require(capacity.established.isEmpty, "Nine 300 ms runs remain below three seconds")
        feed([0], frames: 29, capacity: &capacity, time: &time)
        try require(capacity.established.isEmpty, "A new run earns no credit before its screen")
        feed([0], frames: 1, capacity: &capacity, time: &time)
        try require(capacity.established == [0], "Ten 300 ms runs establish exactly one channel")
    }

    static func preservesContinuousThresholdAndStickyCounts() throws {
        var capacity = LiveSpeakerCapacity()
        var time = 0.0
        feed([0], frames: 299, capacity: &capacity, time: &time)
        try require(capacity.established.isEmpty, "A continuous run must not be double-counted")
        feed([0], frames: 1, capacity: &capacity, time: &time)
        try require(capacity.established == [0], "Three continuous seconds still establish a channel")
        feed([], frames: 6000, capacity: &capacity, time: &time)
        try require(capacity.established == [0], "Established channels remain sticky across silence")
        try require(!capacity.shouldRollover(at: time), "One established channel cannot roll over")
        capacity = LiveSpeakerCapacity()
        try require(capacity.established.isEmpty, "A new window must start empty")
    }

    static func saturatedBootstrapRearmsAfterPopulationChanges() throws {
        var capacity = LiveSpeakerCapacity()
        var time = 0.0
        feed(Set(0..<8), frames: 300, capacity: &capacity, time: &time)
        let firstReached = capacity.firstReachedCapacityAt
        capacity.finishBootstrap(at: time)
        try require(capacity.saturatedBootstrap, "All eight bootstrap channels must block reset loops")
        feed(Set(0..<8), frames: 1000, capacity: &capacity, time: &time)
        try require(!capacity.shouldRollover(at: time), "Recent saturation must not reset repeatedly")
        feed(Set(1..<8), frames: 4600, capacity: &capacity, time: &time)
        try require(!capacity.shouldRollover(at: time), "Population change starts the boundary wait")
        feed(Set(1..<8), frames: 501, capacity: &capacity, time: &time)
        try require(capacity.shouldRollover(at: time), "A changed recent population permits a bounded retry")
        try require(
            capacity.firstReachedCapacityAt == firstReached, "Bootstrap rearming must retain the first capacity cut")
    }

    static func main() throws {
        try repeatedShortTurns()
        try rejectsIsolatedBlipsAndCreditsThresholdOnce()
        try preservesContinuousThresholdAndStickyCounts()
        try saturatedBootstrapRearmsAfterPopulationChanges()
        print("Four capacity policy checks passed.")
    }
}
