import CommonCrypto
import Foundation

/// Bitwarden "EncString": `<type>.<iv>|<ct>|<mac>` (base64 parts).
public struct EncString: Sendable, Equatable {
    public let type: Int
    public let iv: Data
    public let ct: Data
    public let mac: Data?

    public init(_ string: String) throws {
        let headerParts = string.split(separator: ".", maxSplits: 1).map(String.init)
        let type: Int
        let body: String
        if headerParts.count == 2, let t = Int(headerParts[0]) {
            type = t
            body = headerParts[1]
        } else {
            // Legacy strings without a header.
            body = string
            type = string.split(separator: "|").count == 3 ? 2 : 0
        }
        let parts = body.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch type {
        case 0:
            guard parts.count == 2, let iv = Data(base64Encoded: parts[0]), let ct = Data(base64Encoded: parts[1])
            else { throw CryptoError.invalidEncString }
            self.init(type: 0, iv: iv, ct: ct, mac: nil)
        case 1, 2:
            guard parts.count == 3, let iv = Data(base64Encoded: parts[0]), let ct = Data(base64Encoded: parts[1]),
                  let mac = Data(base64Encoded: parts[2])
            else { throw CryptoError.invalidEncString }
            self.init(type: type, iv: iv, ct: ct, mac: mac)
        case 3, 4, 5, 6:
            // RSA: ciphertext only (5/6 carry a legacy MAC we ignore).
            guard let ct = Data(base64Encoded: parts[0]) else { throw CryptoError.invalidEncString }
            self.init(type: type, iv: Data(), ct: ct, mac: nil)
        default:
            throw CryptoError.unsupportedEncType(type)
        }
    }

    public var isRSA: Bool { (3...6).contains(type) }

    public init(type: Int, iv: Data, ct: Data, mac: Data?) {
        self.type = type
        self.iv = iv
        self.ct = ct
        self.mac = mac
    }

    public var string: String {
        var s = "\(type).\(iv.base64EncodedString())|\(ct.base64EncodedString())"
        if let mac { s += "|\(mac.base64EncodedString())" }
        return s
    }

    public func decrypt(with key: SymmetricKey64) throws -> Data {
        switch type {
        case 0:
            return try Crypto.aesCBC(kCCDecrypt, key: key.enc, iv: iv, data: ct)
        case 2:
            guard let macKey = key.mac, let mac else { throw CryptoError.invalidKey }
            let computed = Crypto.hmacSHA256(key: macKey, data: iv + ct)
            guard Crypto.constantTimeEqual(computed, mac) else { throw CryptoError.macMismatch }
            return try Crypto.aesCBC(kCCDecrypt, key: key.enc, iv: iv, data: ct)
        default:
            throw CryptoError.unsupportedEncType(type)
        }
    }

    public func decryptString(with key: SymmetricKey64) throws -> String {
        let data = try decrypt(with: key)
        guard let s = String(data: data, encoding: .utf8) else { throw CryptoError.invalidEncString }
        return s
    }

    public static func encrypt(_ data: Data, with key: SymmetricKey64) throws -> EncString {
        guard let macKey = key.mac else { throw CryptoError.invalidKey }
        let iv = Crypto.randomBytes(16)
        let ct = try Crypto.aesCBC(kCCEncrypt, key: key.enc, iv: iv, data: data)
        let mac = Crypto.hmacSHA256(key: macKey, data: iv + ct)
        return EncString(type: 2, iv: iv, ct: ct, mac: mac)
    }

    public static func encrypt(_ string: String, with key: SymmetricKey64) throws -> EncString {
        try encrypt(Data(string.utf8), with: key)
    }
}
