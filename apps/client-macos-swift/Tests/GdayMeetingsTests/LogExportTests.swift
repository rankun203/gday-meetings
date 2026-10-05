import Foundation
import Testing

@testable import GdayMeetings

struct LogExportTests {
    /// OSLogStore scoped to this process reads back capture and network lines
    /// without entitlements, which Help → Export Logs relies on.
    @Test func exportIncludesCaptureAndNetworkEntriesFromThisProcess() throws {
        let marker = UUID().uuidString
        let start = Date().addingTimeInterval(-5)
        CaptureLog.capture.notice("Export test \(marker, privacy: .public)")
        var request = URLRequest(url: URL(string: "https://files.example.com/upload?filename=secret.opus")!)
        request.httpMethod = "POST"
        NetworkLog.record(
            NetworkTrace(provider: "Filedrop \(marker)", data: "recorded audio"), request: request, bytesSent: 42,
            outcome: "HTTP 200", failed: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try LogExport.export(since: start, to: directory)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(marker))
        #expect(text.contains(":capture] notice"))
        #expect(text.contains(":network] notice"))
        #expect(text.contains("POST files.example.com/upload · 42 bytes sent · HTTP 200"))
        #expect(!text.contains("secret.opus"))
    }

    @Test func networkMessageDropsQueryFragmentAndCredentials() {
        let url = URL(string: "https://user:password@api.example.com:8443/v1/chat?token=abc&filename=a.opus#frag")!
        let text = NetworkLog.message(
            NetworkTrace(provider: "Office LLM", data: "meeting text (2 messages)"), method: "POST", url: url,
            bytesSent: 1200, outcome: "HTTP 200")
        #expect(
            text
                == "Office LLM · meeting text (2 messages) · POST api.example.com:8443/v1/chat · 1200 bytes sent · HTTP 200"
        )
        for secret in ["token", "abc", "a.opus", "frag", "user", "password"] { #expect(!text.contains(secret)) }
    }

    @Test func networkOutcomeOmitsErrorDescriptions() {
        let error = URLError(
            .timedOut, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://example.com/?token=secret")!])
        #expect(NetworkLog.outcome(error) == "failed (URLError -1001)")
        #expect(NetworkLog.outcome(URLError(.cancelled)) == "cancelled")
        #expect(
            NetworkLog.outcome(ServiceError("Contains https://example.com/?token=secret")) == "failed (ServiceError)")
    }
}
