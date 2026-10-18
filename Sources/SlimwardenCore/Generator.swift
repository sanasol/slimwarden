import Foundation

public struct GeneratorOptions: Codable, Sendable, Equatable {
    public var length = 20
    public var uppercase = true
    public var lowercase = true
    public var digits = true
    public var symbols = true
    public var avoidAmbiguous = false

    public init() {}
}

public enum PasswordGenerator {
    public static func generate(_ o: GeneratorOptions) -> String {
        let ambiguous = Set("Il1O0o")
        func set(_ s: String) -> [Character] {
            o.avoidAmbiguous ? s.filter { !ambiguous.contains($0) } : Array(s)
        }
        var groups: [[Character]] = []
        if o.uppercase { groups.append(set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")) }
        if o.lowercase { groups.append(set("abcdefghijklmnopqrstuvwxyz")) }
        if o.digits { groups.append(set("0123456789")) }
        if o.symbols { groups.append(set("!@#$%^&*-_=+?")) }
        if groups.isEmpty { groups.append(set("abcdefghijklmnopqrstuvwxyz")) }
        let all = groups.flatMap { $0 }
        let length = max(o.length, groups.count)

        var rng = SystemRandomNumberGenerator()
        // One character from every enabled group, the rest from the union, then shuffle.
        var chars = groups.map { $0.randomElement(using: &rng)! }
        while chars.count < length { chars.append(all.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars)
    }
}

public struct GeneratedEntry: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public let value: String
    public let date: Date

    public init(value: String, date: Date = Date()) {
        self.value = value
        self.date = date
    }
}
