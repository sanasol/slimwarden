import Foundation

public enum CipherType: Int, Sendable, CaseIterable {
    case login = 1
    case secureNote = 2
    case card = 3
    case identity = 4
    case sshKey = 5

    public var title: String {
        switch self {
        case .login: return "Login"
        case .secureNote: return "Secure note"
        case .card: return "Card"
        case .identity: return "Identity"
        case .sshKey: return "SSH key"
        }
    }

    public var symbol: String {
        switch self {
        case .login: return "key.horizontal"
        case .secureNote: return "note.text"
        case .card: return "creditcard"
        case .identity: return "person.text.rectangle"
        case .sshKey: return "terminal"
        }
    }

    /// JSON object holding the type-specific fields.
    public var section: String {
        switch self {
        case .login: return "login"
        case .secureNote: return "secureNote"
        case .card: return "card"
        case .identity: return "identity"
        case .sshKey: return "sshKey"
        }
    }

    public var fields: [FieldDef] {
        switch self {
        case .login:
            return [
                FieldDef("username", "Username"),
                FieldDef("password", "Password", .hidden),
                FieldDef("totp", "One-time password", .totp),
            ]
        case .secureNote:
            return []
        case .card:
            return [
                FieldDef("cardholderName", "Cardholder name"),
                FieldDef("brand", "Brand"),
                FieldDef("number", "Number", .hidden),
                FieldDef("expMonth", "Expiry month"),
                FieldDef("expYear", "Expiry year"),
                FieldDef("code", "Security code", .hidden),
            ]
        case .identity:
            return [
                FieldDef("title", "Title"), FieldDef("firstName", "First name"),
                FieldDef("middleName", "Middle name"), FieldDef("lastName", "Last name"),
                FieldDef("username", "Username"), FieldDef("company", "Company"),
                FieldDef("email", "Email"), FieldDef("phone", "Phone"),
                FieldDef("ssn", "SSN", .hidden), FieldDef("passportNumber", "Passport number", .hidden),
                FieldDef("licenseNumber", "License number", .hidden),
                FieldDef("address1", "Address 1"), FieldDef("address2", "Address 2"),
                FieldDef("address3", "Address 3"), FieldDef("city", "City"),
                FieldDef("state", "State"), FieldDef("postalCode", "Postal code"),
                FieldDef("country", "Country"),
            ]
        case .sshKey:
            return [
                FieldDef("privateKey", "Private key", .hiddenMultiline),
                FieldDef("publicKey", "Public key", .multiline),
                FieldDef("keyFingerprint", "Fingerprint"),
            ]
        }
    }
}

public enum FieldKind: Sendable {
    case text, hidden, totp, multiline, hiddenMultiline

    public var isSecret: Bool { self == .hidden || self == .hiddenMultiline || self == .totp }
    public var isMultiline: Bool { self == .multiline || self == .hiddenMultiline }
}

public struct FieldDef: Sendable, Identifiable {
    public let key: String
    public let label: String
    public let kind: FieldKind
    public var id: String { key }

    init(_ key: String, _ label: String, _ kind: FieldKind = .text) {
        self.key = key
        self.label = label
        self.kind = kind
    }
}

public enum CustomFieldType: Int, Sendable, CaseIterable {
    case text = 0, hidden = 1, boolean = 2, linked = 3

    public var title: String {
        switch self {
        case .text: return "Text"
        case .hidden: return "Hidden"
        case .boolean: return "Boolean"
        case .linked: return "Linked"
        }
    }
}

public struct CustomField: Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var value: String
    public var type: CustomFieldType
    /// Linked fields reference another field by id; kept as-is on save.
    public var linkedId: Int?

    public init(name: String, value: String, type: CustomFieldType, linkedId: Int? = nil) {
        self.name = name
        self.value = value
        self.type = type
        self.linkedId = linkedId
    }
}

public struct PasswordHistoryEntry: Sendable, Identifiable {
    public var id = UUID()
    public let password: String
    public let date: Date?
}

public struct Folder: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
}

/// A decrypted cipher plus everything needed to re-encrypt and save it.
public struct VaultItem: Sendable, Identifiable {
    public let id: String
    public let type: CipherType
    public var name: String
    public var notes: String
    public var favorite: Bool
    public var folderId: String?
    public let organizationId: String?
    public let revisionDate: Date?
    public let creationDate: Date?
    public let deletedDate: Date?
    public let reprompt: Bool
    /// Type-specific values keyed by `FieldDef.key`.
    public var values: [String: String]
    public var uris: [String]
    public var fields: [CustomField]
    public let passwordHistory: [PasswordHistoryEntry]
    public let passkeyCount: Int
    public let attachmentCount: Int
    public let decryptionFailed: Bool

    /// Raw (encrypted) cipher JSON as received from the server.
    public let raw: JSON
    /// Key the fields are encrypted with (cipher key, org key or user key).
    public let key: SymmetricKey64

    public var username: String { values["username"] ?? "" }
    public var password: String { values["password"] ?? "" }
    public var totp: String { values["totp"] ?? "" }

    public var subtitle: String {
        switch type {
        case .login: return username
        case .card:
            let number = values["number"] ?? ""
            return number.count >= 4 ? "•••• " + number.suffix(4) : (values["brand"] ?? "")
        case .identity:
            return [values["firstName"], values["lastName"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        case .secureNote:
            return notes.split(separator: "\n").first.map(String.init) ?? ""
        case .sshKey:
            return values["keyFingerprint"] ?? ""
        }
    }

    /// Lower-cased text the search runs against.
    public var searchText: String {
        ([name, username, notes, values["email"] ?? "", values["cardholderName"] ?? ""] + uris + fields.map { $0.name })
            .joined(separator: "\n").lowercased()
    }
}

public struct ItemDraft: Sendable {
    public var type: CipherType
    public var name: String
    public var notes: String
    public var favorite: Bool
    public var folderId: String?
    public var values: [String: String]
    public var uris: [String]
    public var fields: [CustomField]

    public init(item: VaultItem) {
        type = item.type
        name = item.name
        notes = item.notes
        favorite = item.favorite
        folderId = item.folderId
        values = item.values
        uris = item.uris
        fields = item.fields
    }

    public init(type: CipherType, folderId: String? = nil) {
        self.type = type
        name = ""
        notes = ""
        favorite = false
        self.folderId = folderId
        values = [:]
        uris = type == .login ? [""] : []
        fields = []
    }
}
