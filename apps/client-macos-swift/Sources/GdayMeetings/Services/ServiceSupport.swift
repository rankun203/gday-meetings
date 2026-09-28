import Foundation
import Security

struct ServiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ServiceHTTPStatusError: LocalizedError {
    let statusCode: Int
    var errorDescription: String? {
        "The server rejected the request (HTTP \(statusCode)). Check the server address and sign-in."
    }
}

// Keep migration policy independent of Security so failure paths can be tested
// without reading or changing the user's real credentials.
protocol CredentialStorage {
    func read(account: String, service: String) throws -> String?
    func write(_ value: String, account: String, service: String) throws
    func remove(account: String, service: String) throws
}

struct CredentialIdentityMigration {
    static let service = "com.gdaymeetings.macos"
    static let legacyService = "app.gday.meetings.swift"
    let storage: any CredentialStorage

    func get(_ account: String) throws -> String? {
        if let current = try storage.read(account: account, service: Self.service) { return current }
        guard let legacy = try storage.read(account: account, service: Self.legacyService) else { return nil }
        // Persist the replacement before removing the only surviving credential.
        try set(legacy, for: account)
        return legacy
    }
    func set(_ value: String, for account: String) throws {
        try storage.write(value, account: account, service: Self.service)
        try storage.remove(account: account, service: Self.legacyService)
    }
    func delete(_ account: String) throws {
        // Remove fallback FIRST. If this fails, retain the canonical credential and
        // report failure; never claim sign-out while leaving a resurrectable token.
        try storage.remove(account: account, service: Self.legacyService)
        try storage.remove(account: account, service: Self.service)
    }
}

enum KeychainStore {
    static let service = CredentialIdentityMigration.service
    private static let migration = CredentialIdentityMigration(storage: SecurityCredentialStorage())
    static func get(_ account: String) throws -> String? { UIPreview.enabled ? nil : try migration.get(account) }
    static func set(_ value: String, for account: String) throws {
        if !UIPreview.enabled { try migration.set(value, for: account) }
    }
    static func delete(_ account: String) throws { if !UIPreview.enabled { try migration.delete(account) } }
}

private struct SecurityCredentialStorage: CredentialStorage {
    func read(account: String, service: String) throws -> String? {
        var query = base(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { throw ServiceError("Unable to read credentials from Keychain (\(status)).") }
        return value
    }
    func write(_ value: String, account: String, service: String) throws {
        let label = KeychainPrompt.label(account)
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrLabel as String: label]
        let status = SecItemUpdate(base(account, service: service) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = base(account, service: service)
            query.merge(attributes) { _, new in new }
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            // Use SecItem attributes only; preserve existing access policies.
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw ServiceError("Unable to save credentials to Keychain (\(added)).")
            }
        }
        else if status != errSecSuccess {
            throw ServiceError("Unable to update Keychain (\(status)).")
        }
    }
    func remove(account: String, service: String) throws {
        let status = SecItemDelete(base(account, service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServiceError("Unable to remove Keychain credentials (\(status)).")
        }
    }
    private func base(_ account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum KeychainPrompt {
    static func label(_ account: String) -> String {
        switch account {
        case "gday-oauth": return "Gday Meetings — server sign-in tokens"
        default:
            return account.hasPrefix("provider-")
                ? "Gday Meetings — provider API key" : "Gday Meetings — saved online credentials"
        }
    }
}

// Credentials must never follow redirects to another origin.
final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
enum ServiceHTTP {
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
    static func origin(_ text: String) throws -> URL {
        guard let u = URL(string: text), let host = u.host, u.user == nil, u.password == nil,
            u.query == nil, u.fragment == nil, u.path.isEmpty || u.path == "/",
            u.scheme == "https" || (u.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(host))
        else { throw ServiceError("Enter an HTTPS server origin. HTTP is supported only on localhost.") }
        return URL(string: "\(u.scheme!)://\(host)\(u.port.map { ":\($0)" } ?? "")")!
    }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool { a.scheme == b.scheme && a.host == b.host && a.port == b.port }
    static func json(_ request: URLRequest, trace: NetworkTrace) async throws -> [String: Any] {
        let (data, response) = try await data(for: request, trace: trace)
        return try decode(data, response)
    }
    /// Every outbound request goes through `data`, `upload`, or `consumeStream` so it appears in the network log.
    static func data(for request: URLRequest, trace: NetworkTrace) async throws -> (Data, URLResponse) {
        try await logged(request, trace: trace, bytesSent: request.httpBody?.count ?? 0) {
            try await session.data(for: request)
        }
    }
    static func upload(for request: URLRequest, fromFile file: URL, trace: NetworkTrace) async throws -> (
        Data, URLResponse
    ) {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return try await logged(request, trace: trace, bytesSent: size) {
            try await session.upload(for: request, fromFile: file)
        }
    }
    private static func logged(
        _ request: URLRequest, trace: NetworkTrace, bytesSent: Int,
        _ send: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        do {
            let result = try await send()
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 0
            NetworkLog.record(
                trace, request: request, bytesSent: bytesSent, outcome: NetworkLog.outcome(result.1),
                failed: !(200..<300).contains(status))
            return result
        }
        catch {
            NetworkLog.record(
                trace, request: request, bytesSent: bytesSent, outcome: NetworkLog.outcome(error), failed: true)
            throw error
        }
    }
    static func decode(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceHTTPStatusError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ServiceError("The server returned an invalid response.")
        }
        return value
    }
    static func request(_ url: URL, json: [String: Any]) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 120
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: json)
        return r
    }
    static func form(_ url: URL, _ values: [String: String]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        r.httpBody = Data(
            values.sorted { $0.key < $1.key }.map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").utf8)
        return r
    }
}

struct LLMMessage: Codable {
    let role: String
    let content: String
}
enum LLMService {
    static func complete(
        baseURL: String, apiKey: String, model: String, messages: [LLMMessage],
        provider: String = ServiceProviderKind.openAICompatible.title
    ) async throws -> String {
        guard let base = URL(string: baseURL),
            base.scheme == "https"
                || (base.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(base.host ?? "")),
            base.user == nil, base.password == nil
        else { throw ServiceError("Use an HTTPS AI endpoint, or HTTP on localhost.") }
        let endpoint = base.path.hasSuffix("/chat/completions") ? base : base.appendingPathComponent("chat/completions")
        var r = try ServiceHTTP.request(
            endpoint,
            json: [
                "model": model, "messages": messages.map { ["role": $0.role, "content": $0.content] }, "stream": false,
            ])
        if !apiKey.isEmpty { r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let result = try await ServiceHTTP.json(
            r, trace: .init(provider: provider, data: "meeting text (\(messages.count) messages)"))
        guard let choices = result["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any], let text = message["content"] as? String
        else { throw ServiceError("The AI provider returned no message.") }
        return text
    }
}
