import CryptoKit
import Foundation
import Testing

@testable import GdayMeetings

struct ServiceTests {
    @Test func secureOrigins() throws {
        #expect(try ServiceHTTP.origin("https://meetings.example/").absoluteString == "https://meetings.example")
        #expect(try ServiceHTTP.origin("http://127.0.0.1:1234").port == 1234)
        #expect(throws: (any Error).self) { try ServiceHTTP.origin("http://remote.example") }
        #expect(throws: (any Error).self) { try ServiceHTTP.origin("https://user:secret@remote.example") }
        #expect(throws: (any Error).self) { try ServiceHTTP.origin("https://remote.example/path") }
        #expect(throws: (any Error).self) { try ServiceHTTP.origin("https://remote.example?token=secret") }
    }
    @Test @MainActor func signedIdentityValidation() throws {
        let key = Curve25519.Signing.PrivateKey()
        let access = "access-token"
        let digest = Data(SHA512.hash(data: Data(access.utf8)))
        let header = GdayServerService.base64(
            try JSONSerialization.data(withJSONObject: ["alg": "EdDSA", "kid": "test"]))
        let payload = GdayServerService.base64(
            try JSONSerialization.data(withJSONObject: [
                "iss": "https://test.example/auth", "sub": "user", "aud": "client", "nonce": "nonce",
                "exp": Date().timeIntervalSince1970 + 600, "at_hash": GdayServerService.base64(digest.prefix(32)),
            ]))
        let signature = try key.signature(for: Data("\(header).\(payload)".utf8))
        let token = "\(header).\(payload).\(GdayServerService.base64(signature))"
        let jwks: [String: Any] = [
            "keys": [
                [
                    "kid": "test", "kty": "OKP", "crv": "Ed25519",
                    "x": GdayServerService.base64(key.publicKey.rawRepresentation),
                ]
            ]
        ]
        let claims = try GdayServerService.verifyIDToken(
            token, jwks: jwks, issuer: "https://test.example/auth", clientID: "client", nonce: "nonce",
            accessToken: access)
        #expect(claims["sub"] as? String == "user")
        #expect(throws: (any Error).self) {
            try GdayServerService.verifyIDToken(
                token, jwks: jwks, issuer: "https://other.example/auth", clientID: "client", nonce: "nonce",
                accessToken: access)
        }
        #expect(throws: (any Error).self) {
            try GdayServerService.verifyIDToken(
                token, jwks: jwks, issuer: "https://test.example/auth", clientID: "other", nonce: "nonce",
                accessToken: access)
        }
        #expect(throws: (any Error).self) {
            try GdayServerService.verifyIDToken(
                token, jwks: jwks, issuer: "https://test.example/auth", clientID: "client", nonce: "replay",
                accessToken: access)
        }
        #expect(throws: (any Error).self) {
            try GdayServerService.verifyIDToken(
                token, jwks: jwks, issuer: "https://test.example/auth", clientID: "client", nonce: "nonce",
                accessToken: "swapped")
        }
        #expect(throws: (any Error).self) {
            try GdayServerService.verifyIDToken(
                token + "x", jwks: jwks, issuer: "https://test.example/auth", clientID: "client", nonce: "nonce",
                accessToken: access)
        }
    }
    @Test @MainActor func durableTranscriptParsing() throws {
        let fixture = Data(
            #"{"status":"COMPLETED","outputs":[{"type":"SUMMARY_OUTPUT","body":"summary"},{"type":"TRANSCRIPT_OUTPUT","body":{"tracks":{"mic":{"segments":[{"start":2,"end":3,"text":"Later","speaker":"S1"}]},"system":{"segments":[{"start":0,"end":1,"text":"Earlier"}]}}}}]}"#
                .utf8)
        let object = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        guard case .complete(let segments) = try GdayServerService.parseTask(object) else {
            Issue.record("Expected transcript")
            return
        }
        #expect(segments.count == 2)
        #expect(segments[0].text == "Earlier")
        #expect(segments[1].speaker == "S1")
        #expect(throws: (any Error).self) { try GdayServerService.parseTask(["status": "COMPLETED", "outputs": []]) }
        #expect(throws: (any Error).self) { try GdayServerService.parseTask([:]) }
        guard case .processing = try GdayServerService.parseTask(["status": "RUNNING", "outputs": []]) else {
            Issue.record("Expected processing")
            return
        }
    }
    @Test func transcriptionCheckpointSurvivesRestart() throws {
        let attempt = ProviderTranscriptionAttempt(
            providerID: UUID(), endpoint: "https://server.example", kind: .gdayWebsite, title: "Original title",
            idempotencyKey: "stable-attempt",
            inputs: [
                ServerTrackInput(
                    url: URL(string: "https://server.example/files/audio?token=secret")!, trackName: "mic",
                    sourceType: "mic", channels: 1)
            ], taskID: "durable-task")
        var meeting = Meeting(title: "Editable title")
        meeting.transcriptionAttempt = attempt
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        #expect(restored.transcriptionAttempt == attempt)
        #expect(restored.transcriptionAttempt?.title == "Original title")
        let oldMeeting = try JSONDecoder().decode(Meeting.self, from: Data(#"{"title":"Old meeting"}"#.utf8))
        #expect(oldMeeting.transcriptionAttempt == nil)
    }
    @Test func formEncoding() {
        let r = ServiceHTTP.form(
            URL(string: "https://example.test/token")!, ["code": "a+b c&=", "grant_type": "authorization_code"])
        #expect(String(data: r.httpBody!, encoding: .utf8) == "code=a%2Bb%20c%26%3D&grant_type=authorization_code")
    }
}
