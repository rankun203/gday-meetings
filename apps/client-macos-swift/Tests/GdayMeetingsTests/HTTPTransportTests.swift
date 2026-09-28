import Foundation
import Network
import Testing

@testable import GdayMeetings

/// A real TCP fixture bound only to loopback. It receives complete HTTP bodies;
/// application URLSession configuration and production request builders remain unchanged.
final class HTTPFixture: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
    }
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = "{}"
        var bodyChunks: [Data]?
        var chunkDelay: TimeInterval = 0
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.gdaymeetings.macos.tests.http")
    private let respond: @Sendable (Request) -> Response
    private var received: [Request] = []
    private var started = false
    private(set) var origin = ""
    var requests: [Request] { queue.sync { received } }
    init(respond: @escaping @Sendable (Request) -> Response) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                guard !self.started else { return }
                switch state {
                case .ready:
                    self.started = true
                    continuation.resume(returning: self.listener.port!.rawValue)
                case .failed(let error):
                    self.started = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
                self.read(connection, data: Data())
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                guard !self.started else { return }
                self.started = true
                self.listener.cancel()
                continuation.resume(
                    throwing: ServiceError("The loopback test listener did not start within five seconds."))
            }
        }
        origin = "http://127.0.0.1:\(port)"
    }
    func stop() { listener.cancel() }
    private func read(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { next, _, complete, error in
            guard let next, error == nil else {
                connection.cancel()
                return
            }
            let buffer = data + next
            guard buffer.count < 1024 * 1024 else {
                connection.cancel()
                return
            }
            guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete {
                    connection.cancel()
                }
                else {
                    self.read(connection, data: buffer)
                }
                return
            }
            let head = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let line = head[0].split(separator: " ")
            guard line.count == 3 else {
                connection.cancel()
                return
            }
            var headers: [String: String] = [:]
            for field in head.dropFirst() {
                guard let colon = field.firstIndex(of: ":") else { continue }
                headers[String(field[..<colon]).lowercased()] = field[field.index(after: colon)...].trimmingCharacters(
                    in: .whitespaces)
            }
            let raw = Data(buffer[separator.upperBound...])
            let body: Data
            if headers["transfer-encoding"]?.lowercased() == "chunked" {
                guard let decoded = Self.chunks(raw) else {
                    self.read(connection, data: buffer)
                    return
                }
                body = decoded
            }
            else {
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard raw.count >= length else {
                    self.read(connection, data: buffer)
                    return
                }
                body = Data(raw.prefix(length))
            }
            let request = Request(method: String(line[0]), target: String(line[1]), headers: headers, body: body)
            self.received.append(request)
            let response = self.respond(request)
            let chunks = response.bodyChunks ?? [Data(response.body.utf8)]
            let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/json"
            var responseHead =
                "HTTP/1.1 \(response.status) Fixture\r\nContent-Type: \(type)\r\nContent-Length: \(chunks.reduce(0) { $0 + $1.count })\r\nConnection: close\r\n"
            for (key, value) in response.headers where key.lowercased() != "content-type" {
                responseHead += "\(key): \(value)\r\n"
            }
            connection.send(
                content: Data((responseHead + "\r\n").utf8),
                completion: .contentProcessed { _ in
                    self.send(chunks, index: 0, delay: response.chunkDelay, to: connection)
                })
        }
    }
    private func send(_ chunks: [Data], index: Int, delay: TimeInterval, to connection: NWConnection) {
        guard index < chunks.count else {
            connection.cancel()
            return
        }
        connection.send(
            content: chunks[index],
            completion: .contentProcessed { error in
                guard error == nil else {
                    connection.cancel()
                    return
                }
                self.queue.asyncAfter(deadline: .now() + delay) {
                    self.send(chunks, index: index + 1, delay: delay, to: connection)
                }
            })
    }
    private static func chunks(_ data: Data) -> Data? {
        var cursor = data.startIndex
        var decoded = Data()
        while cursor < data.endIndex {
            guard let line = data.range(of: Data("\r\n".utf8), in: cursor..<data.endIndex),
                let length = Int(
                    String(decoding: data[cursor..<line.lowerBound], as: UTF8.self).components(separatedBy: ";")[0],
                    radix: 16)
            else { return nil }
            cursor = line.upperBound
            if length == 0 { return decoded }
            guard data.endIndex - cursor >= length + 2 else { return nil }
            decoded.append(data[cursor..<(cursor + length)])
            cursor += length + 2
        }
        return nil
    }
}

struct HTTPTransportTests {
    @Test func chatSendsRealJSONRequest() async throws {
        let server = try HTTPFixture { _ in
            .init(body: #"{"choices":[{"message":{"role":"assistant","content":"Fixture answer"}}]}"#)
        }
        try await server.start()
        defer { server.stop() }
        let answer = try await LLMService.complete(
            baseURL: server.origin + "/v1", apiKey: "synthetic-chat-key", model: "fixture-model",
            messages: [.init(role: "user", content: "Meeting context")])
        #expect(answer == "Fixture answer")
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.target == "/v1/chat/completions")
        #expect(request.headers["authorization"] == "Bearer synthetic-chat-key")
        #expect(request.headers["content-type"] == "application/json")
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        #expect(json["model"] as? String == "fixture-model")
        #expect(json["stream"] as? Bool == false)
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "user", "content": "Meeting context"]])
    }
    @Test func runpodSendsAudioReferences() async throws {
        let server = try HTTPFixture { _ in .init(body: #"{"id":"fixture-job","status":"IN_QUEUE"}"#) }
        try await server.start()
        defer { server.stop() }
        var provider = ServiceProvider(kind: .runpod)
        provider.enabledCapabilities = [.transcription]
        provider.endpoint = server.origin + "/v2/test"
        provider.apiKey = "synthetic-key"
        let job = try await RunPodProvider(provider: provider).submit(
            tracks: [
                ProviderAudioTrack(
                    url: URL(string: "https://audio.example/input.wav?signature=fixture")!, trackName: "mic",
                    sourceType: "mic")
            ], language: "en")
        #expect(job == "fixture-job")
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.target == "/v2/test/run")
        #expect(request.headers["authorization"] == "Bearer synthetic-key")
        let json = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let input = try #require(json["input"] as? [String: Any])
        let tracks = try #require(input["tracks"] as? [[String: String]])
        #expect(tracks.first?["audio_url"] == "https://audio.example/input.wav?signature=fixture")
        #expect(tracks.first?["audio_base64"] == nil)
    }
    @Test func filedropChecksWithoutUploadingAndStreamsAudio() async throws {
        let server = try HTTPFixture { request in
            if request.target == "/health" { return .init(body: #"{"status":"available"}"#) }
            if request.target == "/info" {
                return .init(
                    body: #"{"allowed_extensions":["opus"],"max_file_size_bytes":104857600,"expiry_secs":600}"#)
            }
            if request.target == "/upload" {
                return .init(
                    status: 400,
                    body: #"{"error":"filename required (?filename=name.opus or Content-Disposition header)"}"#)
            }
            return .init(body: #"{"url":"/d/fixture.opus","size":13,"expires_in_secs":600}"#)
        }
        try await server.start()
        defer { server.stop() }
        var provider = ServiceProvider(kind: .filedrop)
        provider.endpoint = server.origin
        provider.apiKey = "synthetic-filedrop-key"
        provider.enabledCapabilities = [.fileTransfer]
        let adapter = FiledropProvider(provider: provider)
        _ = try await adapter.checkConnection()
        #expect(server.requests.count == 3)
        #expect(server.requests.allSatisfy { $0.body.isEmpty })
        let probe = try #require(server.requests.last)
        #expect(probe.method == "POST")
        #expect(probe.target == "/upload")
        #expect(probe.headers["authorization"] == "Bearer synthetic-filedrop-key")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        let audio = Data("fixture audio".utf8)
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let receipt = try await adapter.upload(file: file)
        #expect(receipt.url.absoluteString == server.origin + "/d/fixture.opus")
        #expect(receipt.expiresAt.timeIntervalSinceNow > 590)
        let request = try #require(server.requests.last)
        #expect(request.body == audio)
        #expect(request.headers["content-type"] == "application/octet-stream")
        #expect(request.headers["authorization"] == "Bearer synthetic-filedrop-key")
    }

    @Test func filedropRejectsForeignDownloadURL() async throws {
        let server = try HTTPFixture { request in
            if request.target == "/info" {
                return .init(
                    body: #"{"allowed_extensions":["opus"],"max_file_size_bytes":104857600,"expiry_secs":600}"#)
            }
            return .init(body: #"{"url":"https://other.example/stolen.opus","size":13,"expires_in_secs":600}"#)
        }
        try await server.start()
        defer { server.stop() }
        var provider = ServiceProvider(kind: .filedrop)
        provider.endpoint = server.origin
        provider.apiKey = "synthetic-filedrop-key"
        provider.enabledCapabilities = [.fileTransfer]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        try Data("fixture audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await #expect(throws: (any Error).self) { try await FiledropProvider(provider: provider).upload(file: file) }
    }

    @Test(arguments: [401, 307]) func failuresAndRedirectsAreSurfaced(status: Int) async throws {
        // A redirect target is a second independent loopback listener, proving no
        // follow-up request receives the synthetic bearer credential or audio.
        let destination = try HTTPFixture { _ in
            .init(body: #"{"choices":[{"message":{"content":"Unsafe redirect"}}],"text":"Unsafe redirect"}"#)
        }
        try await destination.start()
        defer { destination.stop() }
        let redirectURL = destination.origin + "/must-not-be-contacted"
        let server = try HTTPFixture { _ in
            .init(
                status: status, headers: status == 307 ? ["Location": redirectURL] : [:],
                body: #"{"error":"Fixture rejection"}"#)
        }
        try await server.start()
        defer { server.stop() }
        do {
            _ = try await LLMService.complete(
                baseURL: server.origin + "/v1", apiKey: "synthetic-secret", model: "fixture", messages: [])
            Issue.record("Chat must surface HTTP \(status)")
        }
        catch { #expect(error.localizedDescription.contains(String(status))) }
        var provider = ServiceProvider(kind: .runpod)
        provider.enabledCapabilities = [.transcription]
        provider.endpoint = server.origin + "/v2/test"
        provider.apiKey = "synthetic-secret"
        do {
            _ = try await RunPodProvider(provider: provider).submit(
                tracks: [
                    ProviderAudioTrack(
                        url: URL(string: "https://audio.example/input.wav")!, trackName: "mic", sourceType: "mic")
                ], language: "en")
            Issue.record("Transcription must surface HTTP \(status)")
        }
        catch { #expect(error.localizedDescription.contains(String(status))) }
        #expect(server.requests.count == 2)
        #expect(destination.requests.isEmpty)
    }
}
