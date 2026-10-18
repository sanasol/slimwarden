import Foundation

public enum APIError: Error, LocalizedError {
    case http(Int, String)
    case twoFactorRequired(providers: [Int])
    case badResponse
    case unauthorized

    public var errorDescription: String? {
        switch self {
        case .http(let code, let message): return message.isEmpty ? "Server error \(code)" : message
        case .twoFactorRequired: return "Two-step login code required"
        case .badResponse: return "Unexpected server response"
        case .unauthorized: return "Session expired, log in again"
        }
    }
}

public struct TokenResponse: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let encryptedUserKey: String?
    public let privateKey: String?
}

public struct TwoFactor: Sendable {
    public let provider: Int   // 0 = authenticator app, 1 = email
    public let token: String
    public let remember: Bool

    public init(provider: Int, token: String, remember: Bool) {
        self.provider = provider
        self.token = token
        self.remember = remember
    }
}

public final class APIClient: @unchecked Sendable {
    public let server: URL
    let session: URLSession
    let deviceId: String

    public init(server: URL, deviceId: String) {
        self.server = server
        self.deviceId = deviceId
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    /// Accepts "vault.example.com" or a full URL; strips trailing slashes.
    public static func normalize(server: String) -> URL? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    func url(_ path: String) -> URL {
        URL(string: server.absoluteString + path)!
    }

    func send(_ request: URLRequest) async throws -> JSON {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("7", forHTTPHeaderField: "Device-Type")
        request.setValue("desktop", forHTTPHeaderField: "Bitwarden-Client-Name")
        request.setValue("2025.1.0", forHTTPHeaderField: "Bitwarden-Client-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        let json = ((try? JSON.parse(data)) ?? .null).camelCased()
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            if let providers = json["twoFactorProviders2"]?.object?.keys.compactMap({ Int($0) })
                ?? json["twoFactorProviders"]?.array?.compactMap({ $0.int ?? $0.string.flatMap(Int.init) }) {
                throw APIError.twoFactorRequired(providers: providers.sorted())
            }
            let message = json["errorModel"]?["message"]?.string
                ?? json["error_description"]?.string
                ?? json["message"]?.string
                ?? String(data: data, encoding: .utf8)?.prefix(300).description ?? ""
            throw APIError.http(http.statusCode, message)
        }
        return json
    }

    func jsonRequest(_ method: String, _ path: String, body: JSON?, token: String?) throws -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        if let body {
            r.httpBody = try body.data()
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    func formRequest(_ path: String, _ fields: [(String, String)], email: String? = nil) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = "POST"
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        r.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let email {
            let b64 = Data(email.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            r.setValue(b64, forHTTPHeaderField: "Auth-Email")
        }
        return r
    }

    // MARK: Identity

    public func prelogin(email: String) async throws -> KdfParams {
        let body: JSON = .object(["email": .string(email)])
        var json: JSON
        do {
            json = try await send(jsonRequest("POST", "/identity/accounts/prelogin", body: body, token: nil))
        } catch APIError.http(404, _) {
            json = try await send(jsonRequest("POST", "/api/accounts/prelogin", body: body, token: nil))
        }
        let type = KdfType(rawValue: json["kdf"]?.int ?? 0) ?? .pbkdf2
        return KdfParams(type: type, iterations: json["kdfIterations"]?.int ?? 600_000,
                         memory: json["kdfMemory"]?.int, parallelism: json["kdfParallelism"]?.int)
    }

    public func login(email: String, passwordHash: String, twoFactor: TwoFactor?) async throws -> TokenResponse {
        var fields: [(String, String)] = [
            ("grant_type", "password"),
            ("username", email),
            ("password", passwordHash),
            ("scope", "api offline_access"),
            ("client_id", "desktop"),
            ("deviceType", "7"),
            ("deviceIdentifier", deviceId),
            ("deviceName", "macos"),
        ]
        if let twoFactor {
            fields += [
                ("twoFactorToken", twoFactor.token),
                ("twoFactorProvider", String(twoFactor.provider)),
                ("twoFactorRemember", twoFactor.remember ? "1" : "0"),
            ]
        }
        return try parseToken(await send(formRequest("/identity/connect/token", fields, email: email)))
    }

    public func refresh(refreshToken: String) async throws -> TokenResponse {
        let fields = [("grant_type", "refresh_token"), ("client_id", "desktop"), ("refresh_token", refreshToken)]
        do {
            return try parseToken(await send(formRequest("/identity/connect/token", fields)))
        } catch APIError.http(400, _) {
            throw APIError.unauthorized
        }
    }

    public func sendEmailCode(email: String, passwordHash: String) async throws {
        let body: JSON = .object(["email": .string(email), "masterPasswordHash": .string(passwordHash)])
        _ = try await send(jsonRequest("POST", "/api/two-factor/send-email-login", body: body, token: nil))
    }

    func parseToken(_ json: JSON) throws -> TokenResponse {
        guard let access = json["access_token"]?.string else { throw APIError.badResponse }
        let expires = json["expires_in"]?.int ?? 3600
        return TokenResponse(
            accessToken: access,
            refreshToken: json["refresh_token"]?.string,
            expiresAt: Date().addingTimeInterval(TimeInterval(expires - 60)),
            encryptedUserKey: json["key"]?.string,
            privateKey: json["privateKey"]?.string)
    }

    // MARK: Vault

    public func sync(token: String) async throws -> JSON {
        try await send(jsonRequest("GET", "/api/sync?excludeDomains=true", body: nil, token: token))
    }

    public func updateCipher(id: String, body: JSON, token: String) async throws -> JSON {
        try await send(jsonRequest("PUT", "/api/ciphers/\(id)", body: body, token: token))
    }

    public func createCipher(body: JSON, token: String) async throws -> JSON {
        try await send(jsonRequest("POST", "/api/ciphers", body: body, token: token))
    }

    public func setFavorite(id: String, favorite: Bool, folderId: String?, token: String) async throws -> JSON {
        let body: JSON = .object(["favorite": .bool(favorite), "folderId": folderId.map { .string($0) } ?? .null])
        return try await send(jsonRequest("PUT", "/api/ciphers/\(id)/partial", body: body, token: token))
    }

    /// Moves the item to trash (restorable from the web vault).
    public func trashCipher(id: String, token: String) async throws {
        _ = try await send(jsonRequest("PUT", "/api/ciphers/\(id)/delete", body: nil, token: token))
    }

    public func createFolder(name: String, token: String) async throws -> JSON {
        try await send(jsonRequest("POST", "/api/folders", body: .object(["name": .string(name)]), token: token))
    }

    public func renameFolder(id: String, name: String, token: String) async throws -> JSON {
        try await send(jsonRequest("PUT", "/api/folders/\(id)", body: .object(["name": .string(name)]), token: token))
    }

    public func deleteFolder(id: String, token: String) async throws {
        _ = try await send(jsonRequest("DELETE", "/api/folders/\(id)", body: nil, token: token))
    }

    public func deleteCipher(id: String, token: String) async throws {
        _ = try await send(jsonRequest("DELETE", "/api/ciphers/\(id)", body: nil, token: token))
    }

    public func restoreCipher(id: String, token: String) async throws -> JSON {
        try await send(jsonRequest("PUT", "/api/ciphers/\(id)/restore", body: nil, token: token))
    }
}
