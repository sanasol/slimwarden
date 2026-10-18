import CryptoKit
import Foundation

public struct TOTP: Sendable {
    public enum Algorithm: Sendable { case sha1, sha256, sha512 }

    public let secret: Data
    public let digits: Int
    public let period: Int
    public let algorithm: Algorithm
    public let steam: Bool

    /// Accepts `otpauth://totp/...`, `steam://SECRET` or a bare base32 secret.
    public init?(_ input: String) {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var secretString = s
        var digits = 6
        var period = 30
        var algorithm = Algorithm.sha1
        var steam = false

        if s.lowercased().hasPrefix("otpauth://") {
            guard let comps = URLComponents(string: s) else { return nil }
            let items = Dictionary((comps.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
                                   uniquingKeysWith: { a, _ in a })
            secretString = items["secret"] ?? ""
            if let d = items["digits"].flatMap(Int.init), (1...10).contains(d) { digits = d }
            if let p = items["period"].flatMap(Int.init), p > 0 { period = p }
            switch items["algorithm"]?.uppercased() {
            case "SHA256": algorithm = .sha256
            case "SHA512": algorithm = .sha512
            default: break
            }
            if comps.host?.lowercased() == "steam" || items["encoder"]?.lowercased() == "steam" { steam = true }
        } else if s.lowercased().hasPrefix("steam://") {
            secretString = String(s.dropFirst("steam://".count))
            steam = true
        }
        if steam { digits = 5 }

        guard let secret = Self.base32Decode(secretString), !secret.isEmpty else { return nil }
        self.secret = secret
        self.digits = digits
        self.period = period
        self.algorithm = algorithm
        self.steam = steam
    }

    public func code(at date: Date = Date()) -> String {
        var counter = UInt64(date.timeIntervalSince1970) / UInt64(period)
        counter = counter.bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = CryptoKit.SymmetricKey(data: secret)
        let hash: Data
        switch algorithm {
        case .sha1: hash = Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: hash = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: hash = Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(hash[hash.count - 1] & 0x0f)
        var value = (UInt32(hash[offset]) & 0x7f) << 24
            | UInt32(hash[offset + 1]) << 16
            | UInt32(hash[offset + 2]) << 8
            | UInt32(hash[offset + 3])

        if steam {
            let alphabet = Array("23456789BCDFGHJKMNPQRTVWXY")
            var out = ""
            for _ in 0..<digits {
                out.append(alphabet[Int(value % UInt32(alphabet.count))])
                value /= UInt32(alphabet.count)
            }
            return out
        }
        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let code = String(UInt64(value) % modulus)
        return String(repeating: "0", count: max(0, digits - code.count)) + code
    }

    public func secondsRemaining(at date: Date = Date()) -> Int {
        period - Int(date.timeIntervalSince1970) % period
    }

    static func base32Decode(_ string: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { lookup[c] = UInt8(i) }
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for c in string.uppercased() where c != "=" && c != " " && c != "-" {
            guard let v = lookup[c] else { return nil }
            buffer = (buffer << 5) | UInt32(v)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xff))
            }
        }
        return out
    }
}
