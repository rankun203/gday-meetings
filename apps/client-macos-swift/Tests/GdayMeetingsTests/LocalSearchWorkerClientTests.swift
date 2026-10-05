import Darwin
import Foundation
import Testing

@testable import GdayMeetings

struct LocalSearchWorkerClientTests {
    @Test func shutdownStopsAnUncooperativeOwnedWorkerAndRejectsQueuedRequests() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("worker.sh")
        let pidFile = root.appendingPathComponent("worker.pid")
        let script = #"""
            #!/bin/sh
            trap '' TERM
            printf '%s\n' "$$" > "$(/usr/bin/dirname "$0")/worker.pid"
            while IFS= read -r request; do
                exec /bin/sleep 30
            done
            """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let worker = LocalSearchWorkerClient(executable: executable, modelCache: root)
        let active = Task { try await worker.embed(texts: ["Synthetic active request"]) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(
            Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let queued = Task { try await worker.embed(texts: ["Synthetic queued request"]) }
        let started = ContinuousClock.now
        await worker.shutdown()
        #expect(started.duration(to: .now) < .seconds(2))
        for task in [active, queued] {
            do {
                _ = try await task.value
                Issue.record("Shutdown must reject active and queued worker requests.")
            }
            catch { #expect(error is CancellationError) }
        }
        #expect(Darwin.kill(pid, 0) == -1)
        do {
            _ = try await worker.embed(texts: ["Synthetic later request"])
            Issue.record("A stopped client must not launch a replacement worker.")
        }
        catch { #expect(error is CancellationError) }
    }

    @Test func workerProtocolAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("worker.sh")
        let vector = [1.0] + Array(repeating: 0.0, count: 511)
        let result: [String: Any] = [
            "model": LocalSearchConfiguration.modelID,
            "revision": LocalSearchConfiguration.modelRevision, "preprocessing": "clsp-16khz-mono-v1",
            "dimension": 512, "normalization": "unitL2", "vectors": [vector],
        ]
        let response = try #require(
            String(
                data: JSONSerialization.data(withJSONObject: ["id": "REQUEST_ID", "final": true, "result": result]),
                encoding: .utf8))
        let script = #"""
            #!/bin/sh
            while IFS= read -r request; do
                case "$request" in
                    *stall*) exec /bin/sleep 30 ;;
                    *invalid*) printf '%s\n' '{"final":true}'; continue ;;
                esac
                request_id=$(printf '%s' "$request" | /usr/bin/sed -E 's/.*"id":"([^"]+)".*/\1/')
                printf '%s\n' 'RESPONSE_JSON' | /usr/bin/sed "s/REQUEST_ID/$request_id/"
            done
            """#.replacingOccurrences(of: "RESPONSE_JSON", with: response)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let worker = LocalSearchWorkerClient(executable: executable, modelCache: root)
        let first = try await worker.embed(texts: ["quiet voice"])
        #expect(first.vectors.first == vector)
        let second = try await worker.embed(texts: ["clear voice"])
        #expect(second.vectors.first == vector)
        do {
            _ = try await worker.embed(texts: ["invalid"])
            Issue.record("Malformed responses must fail validation")
        }
        catch { #expect(error is SearchProviderError) }
        let task = Task { try await worker.embed(texts: ["stall"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation must stop a pending worker request")
        }
        catch { #expect(error is CancellationError) }
        let recovered = try await worker.embed(texts: ["quiet voice"])
        #expect(recovered.vectors.first == vector)
        let impatientWorker = LocalSearchWorkerClient(executable: executable, modelCache: root, timeoutSeconds: 0.1)
        do {
            _ = try await impatientWorker.embed(texts: ["stall"])
            Issue.record("A stalled worker must report a timeout")
        }
        catch {
            #expect(!(error is CancellationError))
            #expect(error.localizedDescription.contains("took too long"))
        }
    }
}
