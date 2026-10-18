import Foundation

public struct KeyRing: Sendable {
    public let userKey: SymmetricKey64
    public var orgKeys: [String: SymmetricKey64] = [:]

    public init(userKey: SymmetricKey64) {
        self.userKey = userKey
    }

    /// Decrypts organization keys from the sync profile (RSA with the user's private key).
    public mutating func loadOrganizations(profile: JSON) {
        guard let orgs = profile["organizations"]?.array, !orgs.isEmpty,
              let pkString = profile["privateKey"]?.string,
              let pkDer = try? EncString(pkString).decrypt(with: userKey),
              let privateKey = try? RSAPrivateKey(pkcs8: pkDer)
        else { return }
        for org in orgs {
            guard let id = org["id"]?.string, let keyString = org["key"]?.string,
                  let enc = try? EncString(keyString),
                  let raw = try? (enc.isRSA ? privateKey.decrypt(enc) : enc.decrypt(with: userKey)),
                  let key = try? SymmetricKey64(raw)
            else { continue }
            orgKeys[id] = key
        }
    }

    public func baseKey(organizationId: String?) -> SymmetricKey64? {
        if let organizationId { return orgKeys[organizationId] }
        return userKey
    }
}

public enum BWDate {
    nonisolated(unsafe) static let parser = ISO8601DateFormatter()
    public static func parse(_ string: String?) -> Date? {
        guard var s = string else { return nil }
        // Drop fractional seconds of any precision; keep the zone designator.
        if let dot = s.firstIndex(of: ".") {
            let rest = s[s.index(after: dot)...]
            let zoneStart = rest.firstIndex(where: { !$0.isNumber }) ?? rest.endIndex
            s = String(s[..<dot]) + String(rest[zoneStart...])
        }
        if !s.hasSuffix("Z") && !s.contains("+") && s.count == 19 { s += "Z" }
        return parser.date(from: s)
    }

    public static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

public enum CipherCodec {
    public static func decryptFolder(_ raw: JSON, keys: KeyRing) -> Folder? {
        guard let id = raw["id"]?.string else { return nil }
        let name = (try? raw["name"]?.string.map { try EncString($0).decryptString(with: keys.userKey) }) ?? nil
        return Folder(id: id, name: name ?? "<undecryptable>")
    }

    public static func itemKey(_ raw: JSON, keys: KeyRing) throws -> SymmetricKey64 {
        let orgId = raw["organizationId"]?.string
        guard let base = keys.baseKey(organizationId: orgId) else { throw CryptoError.invalidKey }
        if let keyString = raw["key"]?.string, !keyString.isEmpty {
            return try SymmetricKey64(EncString(keyString).decrypt(with: base))
        }
        return base
    }

    public static func decrypt(_ raw: JSON, keys: KeyRing) -> VaultItem? {
        guard let id = raw["id"]?.string, let typeRaw = raw["type"]?.int else { return nil }
        let type = CipherType(rawValue: typeRaw) ?? .secureNote
        var failed = false
        let key: SymmetricKey64
        do { key = try itemKey(raw, keys: keys) } catch { key = keys.userKey; failed = true }

        func dec(_ value: JSON?) -> String {
            guard let s = value?.string, !s.isEmpty else { return "" }
            do { return try EncString(s).decryptString(with: key) } catch { failed = true; return "" }
        }

        var values: [String: String] = [:]
        let section = raw[type.section]
        for def in type.fields {
            let v = dec(section?[def.key])
            if !v.isEmpty { values[def.key] = v }
        }

        let uris = (raw["login"]?["uris"]?.array ?? []).map { dec($0["uri"]) }.filter { !$0.isEmpty }

        let fields: [CustomField] = (raw["fields"]?.array ?? []).map { f in
            CustomField(name: dec(f["name"]), value: dec(f["value"]),
                        type: CustomFieldType(rawValue: f["type"]?.int ?? 0) ?? .text,
                        linkedId: f["linkedId"]?.int)
        }

        let history: [PasswordHistoryEntry] = (raw["passwordHistory"]?.array ?? []).map { h in
            PasswordHistoryEntry(password: dec(h["password"]), date: BWDate.parse(h["lastUsedDate"]?.string))
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        let name = dec(raw["name"])
        return VaultItem(
            id: id, type: type,
            name: name.isEmpty ? (failed ? "<undecryptable>" : "") : name,
            notes: dec(raw["notes"]),
            favorite: raw["favorite"]?.bool ?? false,
            folderId: raw["folderId"]?.string,
            organizationId: raw["organizationId"]?.string,
            revisionDate: BWDate.parse(raw["revisionDate"]?.string),
            creationDate: BWDate.parse(raw["creationDate"]?.string),
            deletedDate: BWDate.parse(raw["deletedDate"]?.string),
            reprompt: (raw["reprompt"]?.int ?? 0) == 1,
            values: values, uris: uris, fields: fields,
            passwordHistory: history,
            passkeyCount: raw["login"]?["fido2Credentials"]?.array?.count ?? 0,
            attachmentCount: raw["attachments"]?.array?.count ?? 0,
            decryptionFailed: failed,
            raw: raw, key: key)
    }

    static let requestKeys: Set<String> = [
        "type", "folderId", "organizationId", "key", "name", "notes", "fields", "login", "card",
        "identity", "secureNote", "sshKey", "favorite", "reprompt", "passwordHistory", "attachments2",
    ]

    /// Builds the request body for create (`original == nil`) or update.
    public static func encode(_ draft: ItemDraft, original: VaultItem?, keys: KeyRing) throws -> JSON {
        let key: SymmetricKey64
        var body: [String: JSON] = [:]
        if let original {
            key = original.key
            for (k, v) in original.raw.object ?? [:] where requestKeys.contains(k) { body[k] = v }
            body["lastKnownRevisionDate"] = original.raw["revisionDate"]
        } else {
            key = keys.userKey
            body["type"] = .int(draft.type.rawValue)
            body["reprompt"] = .int(0)
        }

        func enc(_ s: String) throws -> JSON {
            s.isEmpty ? .null : .string(try EncString.encrypt(s, with: key).string)
        }

        body["name"] = try enc(draft.name.isEmpty ? "Untitled" : draft.name)
        body["notes"] = try enc(draft.notes)
        body["favorite"] = .bool(draft.favorite)
        body["folderId"] = draft.folderId.map { .string($0) } ?? .null

        var section = body[draft.type.section]?.object ?? [:]
        for def in draft.type.fields {
            let newValue = draft.values[def.key] ?? ""
            let oldValue = original?.values[def.key] ?? ""
            // Keep untouched ciphertext so nothing changes needlessly.
            if original == nil || newValue != oldValue { section[def.key] = try enc(newValue) }
        }

        if draft.type == .login {
            let newURIs = draft.uris.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if original == nil || newURIs != original!.uris {
                let oldEntries = original?.raw["login"]?["uris"]?.array ?? []
                section["uris"] = .array(try newURIs.enumerated().map { i, uri in
                    let checksum = Data(Crypto.sha256(Data(uri.utf8))).base64EncodedString()
                    var entry = oldEntries.indices.contains(i) ? (oldEntries[i].object ?? [:]) : ["match": .null]
                    entry["uri"] = try enc(uri)
                    entry["uriChecksum"] = try enc(checksum)
                    return .object(entry)
                })
            }
            section["uri"] = nil
            let oldPassword = original?.password ?? ""
            if let original, !oldPassword.isEmpty, oldPassword != (draft.values["password"] ?? "") {
                let now = BWDate.format(Date())
                section["passwordRevisionDate"] = .string(now)
                var history = original.raw["passwordHistory"]?.array ?? []
                history.insert(.object(["password": try enc(oldPassword), "lastUsedDate": .string(now)]), at: 0)
                body["passwordHistory"] = .array(Array(history.prefix(5)))
            }
        }
        if draft.type == .secureNote { section["type"] = section["type"] ?? .int(0) }
        body[draft.type.section] = .object(section)

        if draft.fields != (original?.fields ?? []) {
            body["fields"] = .array(try draft.fields.map { f in
                var obj: [String: JSON] = ["name": try enc(f.name), "value": try enc(f.value), "type": .int(f.type.rawValue)]
                obj["linkedId"] = f.linkedId.map { .int($0) } ?? .null
                return .object(obj)
            })
        }
        return .object(body)
    }
}
