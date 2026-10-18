import Foundation

public struct VaultSnapshot: Sendable {
    public let items: [VaultItem]
    public let folders: [Folder]
    public let lastSync: Date?
}

/// Unlocked vault: keys in memory, network access, local cache.
public actor VaultSession {
    public let storage: Storage
    public private(set) var account: AccountRecord
    var keys: KeyRing
    let api: APIClient
    var accessToken: String?
    var tokenExpiry = Date.distantPast
    var refreshToken: String?
    var vault: JSON

    init(storage: Storage, account: AccountRecord, keys: KeyRing, vault: JSON) throws {
        guard let server = URL(string: account.server) else { throw APIError.badResponse }
        self.storage = storage
        self.account = account
        self.keys = keys
        self.vault = vault
        api = APIClient(server: server, deviceId: account.deviceId)
        if let enc = account.encryptedRefreshToken {
            refreshToken = try? EncString(enc).decryptString(with: keys.userKey)
        }
    }

    static func decryptUserKey(_ encrypted: String, masterKey: Data) throws -> SymmetricKey64 {
        let enc = try EncString(encrypted)
        let wrapping = enc.type == 0 ? SymmetricKey64(enc: masterKey, mac: nil) : Crypto.stretch(masterKey: masterKey)
        return try SymmetricKey64(enc.decrypt(with: wrapping))
    }

    static func keyRing(userKey: SymmetricKey64, vault: JSON) -> KeyRing {
        var ring = KeyRing(userKey: userKey)
        if let profile = vault["profile"] { ring.loadOrganizations(profile: profile) }
        return ring
    }

    // MARK: Entry points

    /// Full online login. Throws `APIError.twoFactorRequired` when a code is needed.
    public static func login(storage: Storage, server: String, email: String, password: String,
                             twoFactor: TwoFactor? = nil) async throws -> VaultSession {
        guard let url = APIClient.normalize(server: server) else { throw APIError.badResponse }
        let email = Crypto.normalizedEmail(email)
        let deviceId = storage.loadAccount()?.deviceId ?? UUID().uuidString.lowercased()
        let api = APIClient(server: url, deviceId: deviceId)
        let kdf = try await api.prelogin(email: email)
        let masterKey = try await Task.detached { try Crypto.makeMasterKey(password: password, email: email, kdf: kdf) }.value
        let hash = try Crypto.masterPasswordHash(masterKey: masterKey, password: password)
        let token = try await api.login(email: email, passwordHash: hash, twoFactor: twoFactor)
        guard let encKey = token.encryptedUserKey else { throw APIError.badResponse }
        let userKey = try decryptUserKey(encKey, masterKey: masterKey)

        var account = AccountRecord(server: url.absoluteString, email: email, kdf: kdf,
                                    encryptedUserKey: encKey, deviceId: deviceId)
        if let rt = token.refreshToken {
            account.encryptedRefreshToken = try EncString.encrypt(rt, with: userKey).string
        }
        try storage.saveAccount(account)
        try? FileManager.default.removeItem(at: storage.vaultURL)

        let session = try VaultSession(storage: storage, account: account,
                                       keys: KeyRing(userKey: userKey), vault: .object([:]))
        await session.setToken(token)
        return session
    }

    public static func requestEmailCode(server: String, email: String, password: String) async throws {
        guard let url = APIClient.normalize(server: server) else { throw APIError.badResponse }
        let email = Crypto.normalizedEmail(email)
        let api = APIClient(server: url, deviceId: UUID().uuidString)
        let kdf = try await api.prelogin(email: email)
        let masterKey = try Crypto.makeMasterKey(password: password, email: email, kdf: kdf)
        try await api.sendEmailCode(email: email, passwordHash: try Crypto.masterPasswordHash(masterKey: masterKey, password: password))
    }

    /// Offline unlock from the stored account and cached vault.
    public static func unlock(storage: Storage, password: String) async throws -> VaultSession {
        guard let account = storage.loadAccount() else { throw APIError.unauthorized }
        let masterKey = try await Task.detached {
            try Crypto.makeMasterKey(password: password, email: account.email, kdf: account.kdf)
        }.value
        let userKey = try decryptUserKey(account.encryptedUserKey, masterKey: masterKey)
        let vault = storage.loadVault() ?? .object([:])
        return try VaultSession(storage: storage, account: account,
                                keys: keyRing(userKey: userKey, vault: vault), vault: vault)
    }

    /// Unlock with a user key kept elsewhere (keychain), skipping the KDF.
    public static func unlock(storage: Storage, userKey keyData: Data) throws -> VaultSession {
        guard let account = storage.loadAccount() else { throw APIError.unauthorized }
        let userKey = try SymmetricKey64(keyData)
        // Make sure the stored key still belongs to this account.
        if let check = account.encryptedRefreshToken ?? (storage.loadVault()?["profile"]?["privateKey"]?.string),
           (try? EncString(check).decrypt(with: userKey)) == nil {
            throw CryptoError.invalidKey
        }
        let vault = storage.loadVault() ?? .object([:])
        return try VaultSession(storage: storage, account: account,
                                keys: keyRing(userKey: userKey, vault: vault), vault: vault)
    }

    public var userKeyData: Data { keys.userKey.combined }

    // MARK: Tokens

    func setToken(_ token: TokenResponse) {
        accessToken = token.accessToken
        tokenExpiry = token.expiresAt
        if let rt = token.refreshToken, rt != refreshToken {
            refreshToken = rt
            account.encryptedRefreshToken = try? EncString.encrypt(rt, with: keys.userKey).string
            try? storage.saveAccount(account)
        }
    }

    func validToken(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, tokenExpiry > Date() { return accessToken }
        guard let refreshToken else { throw APIError.unauthorized }
        let token = try await api.refresh(refreshToken: refreshToken)
        setToken(token)
        return token.accessToken
    }

    func authorized<T: Sendable>(_ call: @Sendable (String) async throws -> T) async throws -> T {
        do {
            return try await call(validToken())
        } catch APIError.unauthorized {
            return try await call(validToken(forceRefresh: true))
        }
    }

    // MARK: Vault

    public func snapshot() -> VaultSnapshot {
        let keys = keys
        let ciphers = vault["ciphers"]?.array ?? []
        let items = ciphers.compactMap { CipherCodec.decrypt($0, keys: keys) }
        let folders = (vault["folders"]?.array ?? []).compactMap { CipherCodec.decryptFolder($0, keys: keys) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return VaultSnapshot(items: items, folders: folders, lastSync: account.lastSync)
    }

    public var hasCache: Bool { vault["ciphers"] != nil }

    public func sync() async throws -> VaultSnapshot {
        let api = api
        let full = try await authorized { try await api.sync(token: $0) }
        vault = .object([
            "profile": full["profile"] ?? .null,
            "folders": full["folders"] ?? .array([]),
            "ciphers": full["ciphers"] ?? .array([]),
        ])
        try storage.saveVault(vault)
        account.lastSync = Date()
        try? storage.saveAccount(account)
        // Organization membership may have changed.
        keys = VaultSession.keyRing(userKey: keys.userKey, vault: vault)
        return snapshot()
    }

    func replaceCipher(_ cipher: JSON) {
        guard let id = cipher["id"]?.string else { return }
        var list = vault["ciphers"]?.array ?? []
        if let i = list.firstIndex(where: { $0["id"]?.string == id }) { list[i] = cipher } else { list.append(cipher) }
        vault["ciphers"] = .array(list)
        try? storage.saveVault(vault)
    }

    func removeCipher(id: String) {
        var list = vault["ciphers"]?.array ?? []
        list.removeAll { $0["id"]?.string == id }
        vault["ciphers"] = .array(list)
        try? storage.saveVault(vault)
    }

    public func save(_ draft: ItemDraft, original: VaultItem?) async throws -> VaultItem {
        let body = try CipherCodec.encode(draft, original: original, keys: keys)
        let api = api
        let response: JSON
        if let original {
            let id = original.id
            response = try await authorized { try await api.updateCipher(id: id, body: body, token: $0) }
        } else {
            response = try await authorized { try await api.createCipher(body: body, token: $0) }
        }
        replaceCipher(response)
        guard let item = CipherCodec.decrypt(response, keys: keys) else { throw APIError.badResponse }
        return item
    }

    public func setFavorite(_ item: VaultItem, _ favorite: Bool) async throws -> VaultItem {
        try await updatePartial(item, favorite: favorite, folderId: item.folderId)
    }

    public func move(_ item: VaultItem, toFolder folderId: String?) async throws -> VaultItem {
        try await updatePartial(item, favorite: item.favorite, folderId: folderId)
    }

    func updatePartial(_ item: VaultItem, favorite: Bool, folderId: String?) async throws -> VaultItem {
        let api = api
        let id = item.id
        _ = try await authorized { try await api.setFavorite(id: id, favorite: favorite, folderId: folderId, token: $0) }
        var raw = item.raw
        raw["favorite"] = .bool(favorite)
        raw["folderId"] = folderId.map { .string($0) } ?? .null
        replaceCipher(raw)
        return CipherCodec.decrypt(raw, keys: keys) ?? item
    }

    public func trash(_ item: VaultItem) async throws -> VaultItem {
        let api = api
        let id = item.id
        try await authorized { try await api.trashCipher(id: id, token: $0) }
        var raw = item.raw
        raw["deletedDate"] = .string(BWDate.format(Date()))
        replaceCipher(raw)
        return CipherCodec.decrypt(raw, keys: keys) ?? item
    }

    // MARK: Folders

    func replaceFolder(_ folder: JSON) {
        guard let id = folder["id"]?.string else { return }
        var list = vault["folders"]?.array ?? []
        if let i = list.firstIndex(where: { $0["id"]?.string == id }) { list[i] = folder } else { list.append(folder) }
        vault["folders"] = .array(list)
        try? storage.saveVault(vault)
    }

    public func createFolder(name: String) async throws -> Folder {
        let api = api
        let enc = try EncString.encrypt(name, with: keys.userKey).string
        let json = try await authorized { try await api.createFolder(name: enc, token: $0) }
        replaceFolder(json)
        return CipherCodec.decryptFolder(json, keys: keys) ?? Folder(id: json["id"]?.string ?? "", name: name)
    }

    public func renameFolder(id: String, name: String) async throws -> Folder {
        let api = api
        let enc = try EncString.encrypt(name, with: keys.userKey).string
        let json = try await authorized { try await api.renameFolder(id: id, name: enc, token: $0) }
        replaceFolder(json)
        return Folder(id: id, name: name)
    }

    /// Deletes the folder; its items move to "No folder" (server does the same).
    public func deleteFolder(id: String) async throws -> VaultSnapshot {
        let api = api
        try await authorized { try await api.deleteFolder(id: id, token: $0) }
        vault["folders"] = .array((vault["folders"]?.array ?? []).filter { $0["id"]?.string != id })
        vault["ciphers"] = .array((vault["ciphers"]?.array ?? []).map { cipher in
            guard cipher["folderId"]?.string == id else { return cipher }
            var c = cipher
            c["folderId"] = .null
            return c
        })
        try? storage.saveVault(vault)
        return snapshot()
    }

    public func deletePermanently(_ item: VaultItem) async throws {
        let api = api
        let id = item.id
        try await authorized { try await api.deleteCipher(id: id, token: $0) }
        removeCipher(id: id)
    }

    public func restore(_ item: VaultItem) async throws -> VaultItem {
        let api = api
        let id = item.id
        let response = try await authorized { try await api.restoreCipher(id: id, token: $0) }
        replaceCipher(response)
        return CipherCodec.decrypt(response, keys: keys) ?? item
    }

    // MARK: Generator history (encrypted with the user key)

    public func loadGeneratorHistory() -> [GeneratedEntry] {
        let state = storage.loadGenerator()
        guard let enc = state.encryptedHistory,
              let data = try? EncString(enc).decrypt(with: keys.userKey),
              let list = try? JSONDecoder().decode([GeneratedEntry].self, from: data)
        else { return [] }
        return list
    }

    public func saveGeneratorHistory(_ history: [GeneratedEntry], options: GeneratorOptions) {
        var state = storage.loadGenerator()
        state.options = options
        if let data = try? JSONEncoder().encode(history) {
            state.encryptedHistory = try? EncString.encrypt(data, with: keys.userKey).string
        }
        storage.saveGenerator(state)
    }

    public func logout() {
        storage.wipe()
    }
}
