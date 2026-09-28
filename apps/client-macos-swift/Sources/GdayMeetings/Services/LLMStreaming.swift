import Foundation

/// Buffers complete SSE lines, so transport chunks may split UTF-8 or JSON anywhere.
struct CompletionEventDecoder {
    private var line: [UInt8] = []
    private var fields: [String] = []
    private var firstLine = true
    private var byteCount = 0
    private(set) var text = ""
    private(set) var done = false
    private var finished = false

    mutating func receive(_ byte: UInt8) throws -> Bool {
        byteCount += 1
        guard byteCount <= 8 * 1024 * 1024 else { throw ServiceError("The summary response is too large.") }
        guard !done else { return false }
        if byte != 10 {
            line.append(byte)
            return false
        }
        if line.last == 13 { line.removeLast() }
        guard var value = String(bytes: line, encoding: .utf8) else {
            throw ServiceError("The summary stream contains invalid text.")
        }
        line.removeAll(keepingCapacity: true)
        if firstLine {
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            firstLine = false
        }
        if value.isEmpty { return try dispatch() }
        if value.hasPrefix("data:") {
            var data = String(value.dropFirst(5))
            if data.first == " " { data.removeFirst() }
            fields.append(data)
        }
        return false
    }

    private mutating func dispatch() throws -> Bool {
        guard !fields.isEmpty else { return false }
        let payload = fields.joined(separator: "\n")
        fields.removeAll(keepingCapacity: true)
        if payload == "[DONE]" {
            done = true
            return false
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            throw ServiceError("The summary stream contains an invalid response.")
        }
        if object["error"] != nil { throw ServiceError("The provider could not finish the summary. Try again.") }
        guard let choices = object["choices"] as? [[String: Any]] else {
            throw ServiceError("The summary stream contains an invalid response.")
        }
        guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return false }
        if let reason = choice["finish_reason"] as? String {
            guard reason == "stop" else {
                throw ServiceError("The provider stopped before completing the summary. Try again.")
            }
            finished = true
        }
        guard let delta = choice["delta"] as? [String: Any], let content = delta["content"] as? String,
            !content.isEmpty
        else { return false }
        text += content
        return true
    }

    func result() throws -> String {
        guard done || finished, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ServiceError("The summary stream ended before a complete response arrived. Try again.")
        }
        return text
    }
}

extension ServiceHTTP {
    /// Log one request for the entire stream; do not log meeting content or chunks.
    static func consumeStream<T>(
        _ request: URLRequest, trace: NetworkTrace,
        consume: (URLSession.AsyncBytes, URLResponse) async throws -> T
    ) async throws -> T {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            // Breaking on [DONE] or throwing must stop a connection left open by a provider.
            defer { bytes.task.cancel() }
            let result = try await consume(bytes, response)
            NetworkLog.record(
                trace, request: request, bytesSent: request.httpBody?.count ?? 0,
                outcome: NetworkLog.outcome(response), failed: false)
            return result
        }
        catch {
            NetworkLog.record(
                trace, request: request, bytesSent: request.httpBody?.count ?? 0,
                outcome: NetworkLog.outcome(error), failed: true)
            throw error
        }
    }
}

extension LLMService {
    static func stream(
        baseURL: String, apiKey: String, model: String, messages: [LLMMessage], provider: String,
        onPartial: @MainActor (String) -> Void
    ) async throws -> String {
        let base = try ProviderEndpoint.base(baseURL)
        let endpoint = base.path.hasSuffix("/chat/completions") ? base : base.appendingPathComponent("chat/completions")
        var request = try ServiceHTTP.request(
            endpoint,
            json: [
                "model": model, "messages": messages.map { ["role": $0.role, "content": $0.content] }, "stream": true,
            ])
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return try await ServiceHTTP.consumeStream(
            request, trace: .init(provider: provider, data: "meeting text (\(messages.count) messages)")
        ) { bytes, response in
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ServiceHTTPStatusError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            if http.mimeType?.lowercased() == "application/json" {
                // Some compatible providers ignore stream=true. Consume that same response;
                // never retry a paid generation merely to change transport format.
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    data.append(byte)
                    guard data.count <= 8 * 1024 * 1024 else {
                        throw ServiceError("The summary response is too large.")
                    }
                }
                let object = try ServiceHTTP.decode(data, response)
                guard let choices = object["choices"] as? [[String: Any]],
                    let message = choices.first?["message"] as? [String: Any], let text = message["content"] as? String,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw ServiceError("The AI provider returned no message.") }
                try Task.checkCancellation()
                await onPartial(text)
                return text
            }
            var decoder = CompletionEventDecoder()
            var lastUpdate = ContinuousClock.now
            var hasPublished = false
            for try await byte in bytes {
                try Task.checkCancellation()
                if try decoder.receive(byte) {
                    let now = ContinuousClock.now
                    // Re-render at most ten times per second, except the first chunk.
                    if !hasPublished || lastUpdate.duration(to: now) >= .milliseconds(100) {
                        await onPartial(decoder.text)
                        lastUpdate = now
                        hasPublished = true
                    }
                }
                if decoder.done { break }
            }
            try Task.checkCancellation()
            let result = try decoder.result()
            await onPartial(result)
            return result
        }
    }
}
