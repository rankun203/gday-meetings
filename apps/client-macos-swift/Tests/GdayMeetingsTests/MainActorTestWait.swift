import Foundation

/// A wall deadline can expire while unrelated synchronous UI tests hold MainActor,
/// before the operation under test gets its first turn. Charge normal polling time
/// to the responsiveness budget, cap long scheduler stalls, and retain a separate
/// hard deadline so a broken operation cannot wait indefinitely.
@MainActor
func waitForMainActorTestCondition(
    timeout: Duration = .seconds(3), maximumWallTime: Duration = .seconds(15),
    _ condition: () -> Bool
) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: maximumWallTime)
    var remaining = timeout
    while !condition(), remaining > .zero, clock.now < deadline {
        let started = clock.now
        try await Task.sleep(for: .milliseconds(10))
        remaining -= min(started.duration(to: clock.now), .milliseconds(50))
    }
    return condition()
}
