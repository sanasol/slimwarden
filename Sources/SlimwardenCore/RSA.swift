import Foundation
import Security

/// RSA-OAEP decryption of organization keys with the user's PKCS#8 private key.
public struct RSAPrivateKey {
    let key: SecKey

    public init(pkcs8 der: Data) throws {
        let pkcs1 = try Self.pkcs1(fromPKCS8: der)
        let attrs: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            throw CryptoError.invalidKey
        }
        self.key = key
    }

    public func decrypt(_ enc: EncString) throws -> Data {
        let algorithm: SecKeyAlgorithm
        switch enc.type {
        case 3, 5: algorithm = .rsaEncryptionOAEPSHA256
        case 4, 6: algorithm = .rsaEncryptionOAEPSHA1
        default: throw CryptoError.unsupportedEncType(enc.type)
        }
        var error: Unmanaged<CFError>?
        guard let out = SecKeyCreateDecryptedData(key, algorithm, enc.ct as CFData, &error) else {
            throw CryptoError.invalidKey
        }
        return out as Data
    }

    /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE, privateKey OCTET STRING }
    static func pkcs1(fromPKCS8 der: Data) throws -> Data {
        var reader = DERReader(bytes: [UInt8](der))
        var seq = try reader.read(tag: 0x30)
        _ = try seq.read(tag: 0x02)
        _ = try seq.read(tag: 0x30)
        let octets = try seq.read(tag: 0x04)
        return Data(octets.bytes[octets.start..<octets.end])
    }
}

struct DERReader {
    let bytes: [UInt8]
    var start: Int
    var end: Int

    init(bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.start = start
        self.end = end ?? bytes.count
    }

    /// Reads the next TLV with the given tag and returns a reader over its contents.
    mutating func read(tag: UInt8) throws -> DERReader {
        guard start < end, bytes[start] == tag else { throw CryptoError.invalidKey }
        var i = start + 1
        guard i < end else { throw CryptoError.invalidKey }
        var length = Int(bytes[i])
        i += 1
        if length & 0x80 != 0 {
            let n = length & 0x7f
            guard n <= 4, i + n <= end else { throw CryptoError.invalidKey }
            length = 0
            for _ in 0..<n { length = (length << 8) | Int(bytes[i]); i += 1 }
        }
        guard i + length <= end else { throw CryptoError.invalidKey }
        let inner = DERReader(bytes: bytes, start: i, end: i + length)
        start = i + length
        return inner
    }
}
