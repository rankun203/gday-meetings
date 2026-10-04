import Foundation
import Testing

@testable import GdayMeetings

struct ServiceProviderTests {
    @Test func providerCredentialsAndDefaults() throws {
        var provider = ServiceProvider(kind: .runpod)
        #expect(provider.endpoint.isEmpty)
        #expect(provider.apiKey.isEmpty)
        #expect(provider.enabledCapabilities == provider.kind.capabilities)
        provider.apiKey = "test-secret"
        let encoded = try JSONEncoder().encode(provider)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("test-secret"))
        let restored = try JSONDecoder().decode(ServiceProvider.self, from: encoded)
        #expect(restored.id == provider.id)
        #expect(restored.apiKey.isEmpty)
        #expect(restored.supports(.transcription))
    }
    @Test func newProvidersEnableSupportedCapabilitiesAndEditsRetainChoices() throws {
        for kind in ServiceProviderKind.allCases {
            var provider = ServiceProvider(kind: kind)
            #expect(provider.enabledCapabilities == kind.capabilities)
            provider.enabledCapabilities = []
            provider.name = "Edited"
            let restored = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(provider))
            #expect(restored.enabledCapabilities.isEmpty)
        }
    }

    @Test func liveTranscriptionRequiresSelectedEnabledCapability() throws {
        var settings = AppSettings()
        #expect(settings.liveTranscriptionEnabled)
        settings.thisMacCapabilities = []
        #expect(!settings.liveTranscriptionEnabled)
        settings.thisMacCapabilities = ThisMacProvider.capabilities
        settings.liveTranscriptionProviderID = nil
        #expect(!settings.liveTranscriptionEnabled)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.liveTranscriptionProviderID == nil)
        settings.liveTranscriptionProviderID = ThisMacProvider.id
        settings.showLiveTranscript = false
        #expect(!settings.liveTranscriptionEnabled)
    }
    @Test func runpodSubmissionUsesRemoteURLsOnly() throws {
        var provider = ServiceProvider(kind: .runpod)
        provider.endpoint = "https://api.runpod.ai/v2/example"
        provider.apiKey = "test-key"
        provider.enabledCapabilities = [.transcription]
        let adapter = RunPodProvider(provider: provider)
        let track = ProviderAudioTrack(
            url: URL(string: "https://storage.example/audio.opus?signature=temporary")!,
            trackName: "mic", sourceType: "mic")
        let request = try adapter.submissionRequest(tracks: [track], language: "en", diarize: false)
        #expect(request.url?.absoluteString == "https://api.runpod.ai/v2/example/run")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let input = try #require(body["input"] as? [String: Any])
        let tracks = try #require(input["tracks"] as? [[String: Any]])
        #expect(tracks.first?["audio_url"] as? String == track.url.absoluteString)
        #expect(tracks.first?["audio_base64"] == nil)
        #expect(throws: (any Error).self) {
            try adapter.submissionRequest(
                tracks: [
                    .init(
                        url: URL(fileURLWithPath: "/tmp/private.wav"),
                        trackName: "mic", sourceType: "mic")
                ], language: "en", diarize: false)
        }
    }
    @Test func disabledCapabilitiesPreventSubmissions() throws {
        var provider = ServiceProvider(kind: .runpod)
        provider.enabledCapabilities = []
        provider.endpoint = "https://api.runpod.ai/v2/example"
        provider.apiKey = "test-key"
        let tracks = [
            ProviderAudioTrack(
                url: URL(string: "https://storage.example/audio.opus")!, trackName: "mic", sourceType: "mic")
        ]
        #expect(throws: (any Error).self) {
            try RunPodProvider(provider: provider).submissionRequest(tracks: tracks, language: "en", diarize: false)
        }
        provider.enabledCapabilities = [.transcription]
        #expect(throws: (any Error).self) {
            try RunPodProvider(provider: provider).submissionRequest(tracks: tracks, language: "en", diarize: true)
        }
        provider.isEnabled = false
        #expect(throws: (any Error).self) {
            try RunPodProvider(provider: provider).submissionRequest(tracks: tracks, language: "en", diarize: false)
        }
    }
    @Test func workerFailureDoesNotExposeTraceback() throws {
        guard
            case .failed(let message) = try RunPodProvider.parseStatus([
                "status": "FAILED",
                "error":
                    "Traceback at /private/worker: 'auto' is not a valid language code. https://example.com/private-audio",
            ])
        else {
            Issue.record("Expected a failed job")
            return
        }
        #expect(message == "RunPod transcription failed.")
        #expect(!message.contains("Traceback"))
        #expect(!message.contains("private-audio"))
        guard
            case .failed(let generic) = try RunPodProvider.parseStatus([
                "status": "FAILED", "error": "Secret diagnostic output",
            ])
        else {
            Issue.record("Expected a failed job")
            return
        }
        #expect(generic == "RunPod transcription failed.")
    }
    @Test func runpodExplicitEmbeddingTypeOverridesHistoricalContract() throws {
        var other = EmbeddingType.community1
        other.modelID = "synthetic-other-model"
        let type = try JSONSerialization.jsonObject(with: JSONEncoder().encode(other))
        for declared: Any in [type, ["invalid": true], "invalid", 42, NSNull()] {
            let payload: [String: Any] = [
                "status": "COMPLETED",
                "output": [
                    "tracks": [
                        "system": [
                            "segments": [
                                ["start": 0.0, "end": 2.0, "text": "Synthetic passage", "speaker": "speaker_0"]
                            ],
                            "speaker_embeddings": ["speaker_0": [2.0] + Array(repeating: 0.0, count: 255)],
                            "speaker_embedding_type": declared,
                        ]
                    ]
                ],
            ]
            guard case .complete(let rows) = try RunPodProvider.parseStatus(payload) else {
                Issue.record("Missing transcript")
                return
            }
            #expect(rows.first?.embedding == nil)
            if declared is [String: Bool] || declared is String || declared is Int || declared is NSNull {
                #expect(rows.first?.voiceEmbedding == nil)
            }
            else {
                #expect(rows.first?.voiceEmbedding?.type == other)
                #expect(rows.first?.voiceEmbedding?.isValid == true)
            }
        }
    }

    @Test func runpodStatusValidatesResults() throws {
        let result: [String: Any] = [
            "status": "COMPLETED",
            "output": [
                "tracks": [
                    "mic": [
                        "segments": [
                            ["start": 1.0, "end": 2.0, "text": "Hello", "speaker": "mic_0"]
                        ]
                    ]
                ]
            ],
        ]
        guard case .complete(let segments) = try RunPodProvider.parseStatus(result) else {
            Issue.record("Expected completed transcript")
            return
        }
        #expect(segments.count == 1)
        #expect(segments.first?.speaker == "mic_0")
        #expect(throws: (any Error).self) { try RunPodProvider.parseStatus(["status": "COMPLETED"]) }
        #expect(throws: (any Error).self) { try RunPodProvider.parseStatus(["status": "UNKNOWN"]) }
        #expect(throws: (any Error).self) {
            try RunPodProvider.parseStatus([
                "status": "COMPLETED",
                "output": [
                    "tracks": [
                        "mic": [
                            "segments": [
                                ["start": -1.0, "end": 2.0, "text": "Invalid"]
                            ]
                        ]
                    ]
                ],
            ])
        }
    }
    @MainActor @Test func disabledSummariesDoNotSendContent() async {
        let llm = ServiceProvider(kind: .openAICompatible)
        await #expect(throws: (any Error).self) {
            try await OpenAISummaryProvider(provider: llm).summarize(
                transcript: "private transcript", instructions: "Summarize")
        }
    }
    @Test func savedSearchCapabilityDoesNotEnableWebsiteSearch() throws {
        var website = ServiceProvider(kind: .gdayWebsite)
        website.enabledCapabilities = [.transcription, .search]
        let restored = try JSONDecoder().decode(ServiceProvider.self, from: JSONEncoder().encode(website))
        #expect(restored.enabledCapabilities.contains(.search))
        #expect(!restored.supports(.search))
        #expect(restored.supports(.transcription))
        #expect(!ServiceProviderKind.gdayWebsite.capabilities.contains(.search))
    }

    @Test func endpointRejectsCredentialsQueriesAndOperationURLs() throws {
        for text in [
            "", "https://key@example.com", "https://example.com?token=secret", "http://example.com",
            "file:///tmp/audio",
        ] {
            #expect(throws: (any Error).self) { try ProviderEndpoint.base(text) }
        }
        #expect(try ProviderEndpoint.base("http://localhost:8080/v1").host == "localhost")
        #expect(throws: (any Error).self) { try ProviderEndpoint.runpod("https://api.runpod.ai/v2/example/run") }
    }
}
