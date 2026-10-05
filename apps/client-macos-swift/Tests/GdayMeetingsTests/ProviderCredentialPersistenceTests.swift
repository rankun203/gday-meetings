import Foundation
import Testing

@testable import GdayMeetings

struct ProviderCredentialPersistenceTests {
    @Test func failedConfigSaveRestoresCredentialDestinationPair() throws {
        var provider = ServiceProvider(kind: .runpod)
        provider.endpoint = "https://old.example/v2/worker"
        let old = ProviderCredentialPersistence.account(for: provider)
        provider.endpoint = "https://new.example/v2/worker"
        let new = ProviderCredentialPersistence.account(for: provider)
        #expect(old != new)
        var secrets = [old: "old-key"]
        #expect(throws: (any Error).self) {
            try ProviderCredentialPersistence.save(
                previous: secrets, next: [new: "new-key"],
                write: { secrets[$0] = $1 }, remove: { secrets.removeValue(forKey: $0) },
                persistSettings: { throw ServiceError("Disk full") })
        }
        #expect(secrets == [old: "old-key"])
    }

    @Test func rollbackFailureCannotPairNewSecretWithOldEndpoint() throws {
        var provider = ServiceProvider(kind: .runpod)
        provider.endpoint = "https://old.example"
        let old = ProviderCredentialPersistence.account(for: provider)
        provider.endpoint = "https://new.example"
        let new = ProviderCredentialPersistence.account(for: provider)
        var secrets = [old: "old-key"]
        var diskFailed = false
        #expect(throws: (any Error).self) {
            try ProviderCredentialPersistence.save(
                previous: secrets, next: [new: "new-key"],
                write: { account, key in
                    if diskFailed { throw ServiceError("Keychain unavailable") }
                    secrets[account] = key
                },
                remove: { account in
                    if diskFailed { throw ServiceError("Keychain unavailable") }
                    secrets.removeValue(forKey: account)
                },
                persistSettings: {
                    diskFailed = true
                    throw ServiceError("Disk full")
                })
        }
        #expect(secrets[old] != "new-key")
        #expect(secrets[new] == "new-key")
    }

    @Test func successfulSaveUpdatesCredentialsAndPrivateConfig() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data("old".utf8).write(to: url)
        var secrets = ["old": "old-key"]
        try ProviderCredentialPersistence.save(
            previous: secrets, next: ["new": "new-key"],
            write: { secrets[$0] = $1 }, remove: { secrets.removeValue(forKey: $0) },
            persistSettings: { try ProviderCredentialPersistence.writeSettings(Data("new".utf8), to: url) })
        #expect(secrets == ["new": "new-key"])
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}
