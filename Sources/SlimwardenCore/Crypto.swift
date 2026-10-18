import CArgon2
import CommonCrypto
import CryptoKit
import Foundation

public enum CryptoError: Error, LocalizedError {
    case invalidEncString
    case unsupportedEncType(Int)
    case macMismatch
    case aesFailure(Int32)
    case kdfFailure(String)
    case invalidKey

    public var errorDescription: String? {
        switch self {
        case .invalidEncString: return "Invalid encrypted string"
        case .unsupportedEncType(let t): return "Unsupported encryption type \(t)"
        case .macMismatch: return "Wrong password or corrupted data (MAC mismatch)"
        case .aesFailure(let s): return "AES failure (\(s))"
        case .kdfFailure(let s): return "KDF failure: \(s)"
        case .invalidKey: return "Invalid key"
        }
    }
}

/// 64-byte symmetric key: 32 bytes AES-256 + 32 bytes HMAC-SHA256.
public struct SymmetricKey64: Sendable {
    public let enc: Data
    public let mac: Data?

    public init(enc: Data, mac: Data?) {
        self.enc = enc
        self.mac = mac
    }

    public init(_ data: Data) throws {
        switch data.count {
        case 64: self.init(enc: data.prefix(32), mac: data.suffix(32))
        case 32: self.init(enc: data, mac: nil)
        default: throw CryptoError.invalidKey
        }
    }

    public var combined: Data { enc + (mac ?? Data()) }

    public static func random() -> SymmetricKey64 {
        SymmetricKey64(enc: Crypto.randomBytes(32), mac: Crypto.randomBytes(32))
    }
}

public enum KdfType: Int, Codable, Sendable {
    case pbkdf2 = 0
    case argon2id = 1
}

public struct KdfParams: Codable, Sendable, Equatable {
    public var type: KdfType
    public var iterations: Int
    public var memory: Int?       // MiB
    public var parallelism: Int?

    public init(type: KdfType, iterations: Int, memory: Int? = nil, parallelism: Int? = nil) {
        self.type = type
        self.iterations = iterations
        self.memory = memory
        self.parallelism = parallelism
    }
}

public enum Crypto {
    public static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess)
        return data
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: CryptoKit.SymmetricKey(data: key)))
    }

    public static func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, length: Int = 32) throws -> Data {
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), length)
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.kdfFailure("PBKDF2 status \(status)") }
        return out
    }

    public static func argon2id(password: Data, salt: Data, iterations: Int, memoryKiB: Int, parallelism: Int, length: Int = 32) throws -> Data {
        var out = Data(count: length)
        let rc = out.withUnsafeMutableBytes { outPtr in
            password.withUnsafeBytes { pwPtr in
                salt.withUnsafeBytes { saltPtr in
                    argon2id_hash_raw(
                        UInt32(iterations), UInt32(memoryKiB), UInt32(parallelism),
                        pwPtr.baseAddress, password.count,
                        saltPtr.baseAddress, salt.count,
                        outPtr.baseAddress, length)
                }
            }
        }
        guard rc == ARGON2_OK.rawValue else {
            throw CryptoError.kdfFailure(String(cString: argon2_error_message(rc)))
        }
        return out
    }

    /// HKDF-Expand only (RFC 5869 step 2), as used by Bitwarden to stretch the master key.
    public static func hkdfExpand(prk: Data, info: String, length: Int) -> Data {
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < length {
            previous = hmacSHA256(key: prk, data: previous + Data(info.utf8) + Data([counter]))
            output += previous
            counter += 1
        }
        return output.prefix(length)
    }

    public static func aesCBC(_ operation: Int, key: Data, iv: Data, data: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLen = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(operation), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &outLen)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.aesFailure(status) }
        return out.prefix(outLen)
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    // MARK: Bitwarden key derivation

    public static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func makeMasterKey(password: String, email: String, kdf: KdfParams) throws -> Data {
        let pw = Data(password.utf8)
        let salt = Data(normalizedEmail(email).utf8)
        switch kdf.type {
        case .pbkdf2:
            return try pbkdf2SHA256(password: pw, salt: salt, iterations: kdf.iterations)
        case .argon2id:
            let memory = (kdf.memory ?? 64) * 1024
            return try argon2id(password: pw, salt: sha256(salt), iterations: kdf.iterations,
                                memoryKiB: memory, parallelism: kdf.parallelism ?? 4)
        }
    }

    /// Hash sent to the server for authentication.
    public static func masterPasswordHash(masterKey: Data, password: String) throws -> String {
        try pbkdf2SHA256(password: masterKey, salt: Data(password.utf8), iterations: 1).base64EncodedString()
    }

    public static func stretch(masterKey: Data) -> SymmetricKey64 {
        SymmetricKey64(enc: hkdfExpand(prk: masterKey, info: "enc", length: 32),
                       mac: hkdfExpand(prk: masterKey, info: "mac", length: 32))
    }
}
