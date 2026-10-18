import Foundation

/// What is needed to unlock offline: everything secret here is encrypted with the master key or user key.
public struct AccountRecord: Codable, Sendable {
    public var server: String
    public var email: String
    public var kdf: KdfParams
    /// User key protected by the stretched master key.
    public var encryptedUserKey: String
    public var deviceId: String
    /// Refresh token encrypted with the user key.
    public var encryptedRefreshToken: String?
    public var lastSync: Date?

    public init(server: String, email: String, kdf: KdfParams, encryptedUserKey: String, deviceId: String) {
        self.server = server
        self.email = email
        self.kdf = kdf
        self.encryptedUserKey = encryptedUserKey
        self.deviceId = deviceId
    }
}

public struct GeneratorState: Codable, Sendable {
    public var options = GeneratorOptions()
    /// History JSON encrypted with the user key.
    public var encryptedHistory: String?

    public init() {}
}

public final class Storage: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("Slimwarden", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    var accountURL: URL { directory.appendingPathComponent("account.json") }
    var vaultURL: URL { directory.appendingPathComponent("vault.json") }
    var generatorURL: URL { directory.appendingPathComponent("generator.json") }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func loadAccount() -> AccountRecord? {
        guard let data = try? Data(contentsOf: accountURL) else { return nil }
        return try? JSONDecoder().decode(AccountRecord.self, from: data)
    }

    public func saveAccount(_ account: AccountRecord) throws {
        try write(JSONEncoder().encode(account), to: accountURL)
    }

    /// Cached sync payload (ciphers are still encrypted field-by-field).
    public func loadVault() -> JSON? {
        guard let data = try? Data(contentsOf: vaultURL) else { return nil }
        return try? JSON.parse(data)
    }

    public func saveVault(_ vault: JSON) throws {
        try write(vault.data(), to: vaultURL)
    }

    public func loadGenerator() -> GeneratorState {
        guard let data = try? Data(contentsOf: generatorURL),
              let state = try? JSONDecoder().decode(GeneratorState.self, from: data)
        else { return GeneratorState() }
        return state
    }

    public func saveGenerator(_ state: GeneratorState) {
        if let data = try? JSONEncoder().encode(state) { try? write(data, to: generatorURL) }
    }

    public func wipe() {
        for url in [accountURL, vaultURL, generatorURL] { try? FileManager.default.removeItem(at: url) }
    }
}
