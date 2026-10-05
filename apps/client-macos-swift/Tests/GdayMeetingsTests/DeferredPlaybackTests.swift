import Foundation
import Testing

@testable import GdayMeetings

@MainActor struct DeferredPlaybackTests {
    @Test(arguments: ["pause", "seek", "clear", "recording", "new request"])
    func slowMeetingLoadCannotOverrideNewerTransportIntent(_ action: String) async throws {
        let playback = MeetingPlayback()
        let gate = PlaybackLoadGate()
        var played: [String] = []
        let first = playback.requestPlayback(
            load: {
                await gate.wait()
                return Meeting(title: "First")
            }, play: { played.append($0.title) })
        #expect(try await waitForMainActorTestCondition(timeout: .seconds(2)) { gate.started })
        switch action {
        case "pause": playback.pause()
        case "seek": playback.seek(to: 5)
        case "clear": playback.clear()
        case "recording": playback.setRecordingActive(true)
        default:
            await playback.requestPlayback(load: { Meeting(title: "Second") }, play: { played.append($0.title) }).value
        }
        gate.release()
        await first.value
        #expect(played == (action == "new request" ? ["Second"] : []))
    }

    @Test func currentRequestCompletesAfterItsMeetingLoads() async throws {
        let playback = MeetingPlayback()
        let gate = PlaybackLoadGate()
        var completed = false
        let request = playback.requestPlayback(
            load: {
                await gate.wait()
                return Meeting(title: "Synthetic")
            }, play: { _ in completed = true })
        #expect(try await waitForMainActorTestCondition(timeout: .seconds(2)) { gate.started })
        #expect(!completed)
        gate.release()
        await request.value
        #expect(completed)
    }
}

@MainActor private final class PlaybackLoadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            started = true
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
