import AppKit
import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct ManagedTaskWakeObserverTests {
    @Test func wakeUsesWorkspaceNotificationAndStopsObservingOnRelease() async throws {
        let center = NotificationCenter()
        var wakes = 0
        var observer: ManagedTaskWakeObserver? = ManagedTaskWakeObserver(center: center) { wakes += 1 }
        #expect(observer != nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(try await waitForMainActorTestCondition { wakes == 1 })
        observer = nil
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<10 { await Task.yield() }
        #expect(wakes == 1)
    }
}
