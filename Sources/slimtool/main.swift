import Foundation
import SlimwardenCore

// Developer CLI for exercising the core against a server.
// Usage: LW_DIR=... LW_PASSWORD=... slimtool <login server email [totp] | sync | list | show <name> | edit <name> <field> <value> | new <name> | fav <name> | trash <name>>

let env = ProcessInfo.processInfo.environment
let storage = Storage(directory: env["LW_DIR"].map { URL(fileURLWithPath: $0) })
let password = env["LW_PASSWORD"] ?? ""
let args = Array(CommandLine.arguments.dropFirst())

func find(_ snapshot: VaultSnapshot, _ name: String) -> VaultItem {
    guard let item = snapshot.items.first(where: { $0.name == name }) else {
        print("not found: \(name)"); exit(1)
    }
    return item
}

func dump(_ item: VaultItem) {
    print("[\(item.type.title)] \(item.name) fav=\(item.favorite) folder=\(item.folderId ?? "-") deleted=\(item.deletedDate != nil) failed=\(item.decryptionFailed)")
    for def in item.type.fields { if let v = item.values[def.key] { print("  \(def.label): \(v)") } }
    for u in item.uris { print("  uri: \(u)") }
    for f in item.fields { print("  field \(f.name) (\(f.type.title)): \(f.value)") }
    if !item.notes.isEmpty { print("  notes: \(item.notes)") }
    for h in item.passwordHistory { print("  history: \(h.password) @ \(h.date.map { "\($0)" } ?? "-")") }
    if item.passkeyCount > 0 { print("  passkeys: \(item.passkeyCount)") }
    if let totp = TOTP(item.totp) { print("  TOTP now: \(totp.code())") }
}

do {
    switch args.first {
    case "demo":
        try makeDemo()
        print("demo vault written to \(storage.directory.path)")
    case "login":
        let tf = args.count > 3 ? TwoFactor(provider: 0, token: args[3], remember: false) : nil
        let s = try await VaultSession.login(storage: storage, server: args[1], email: args[2], password: password, twoFactor: tf)
        let snap = try await s.sync()
        print("logged in, \(snap.items.count) items, \(snap.folders.count) folders")
    default:
        let start = Date()
        let s = try await VaultSession.unlock(storage: storage, password: password)
        print(String(format: "unlocked in %.2fs", Date().timeIntervalSince(start)))
        var snap = await s.snapshot()
        switch args.first {
        case "sync":
            snap = try await s.sync()
            print("synced \(snap.items.count) items")
        case "list":
            let t = Date()
            snap = await s.snapshot()
            print(String(format: "decrypted %d items in %.3fs", snap.items.count, Date().timeIntervalSince(t)))
            for i in snap.items.sorted(by: { $0.name < $1.name }) {
                print("\(i.type.title)\t\(i.name)\t\(i.subtitle)\(i.decryptionFailed ? "\tFAILED" : "")")
            }
            print("folders: \(snap.folders.map(\.name))")
        case "show":
            dump(find(snap, args[1]))
        case "edit":
            let item = find(snap, args[1])
            var d = ItemDraft(item: item)
            switch args[2] {
            case "name": d.name = args[3]
            case "notes": d.notes = args[3]
            case "uri": d.uris.append(args[3])
            case "field": d.fields.append(CustomField(name: "f\(d.fields.count)", value: args[3], type: .hidden))
            default: d.values[args[2]] = args[3]
            }
            dump(try await s.save(d, original: item))
        case "new":
            var d = ItemDraft(type: .login)
            d.name = args[1]
            d.values = ["username": "user@example.com", "password": "secret-1", "totp": "JBSWY3DPEHPK3PXP"]
            d.uris = ["https://example.com"]
            d.fields = [CustomField(name: "pin", value: "1234", type: .hidden)]
            d.notes = "created by slimtool"
            dump(try await s.save(d, original: nil))
        case "fav":
            let item = find(snap, args[1])
            dump(try await s.setFavorite(item, !item.favorite))
        case "trash":
            _ = try await s.trash(find(snap, args[1]))
            print("trashed")
        default:
            print("unknown command")
        }
    }
} catch {
    print("error: \(error.localizedDescription) [\(error)]")
    exit(1)
}

// MARK: Offline demo vault for UI checks (fake data, never sent anywhere)

func makeDemo() throws {
    let email = "demo@lw.test"
    let kdf = KdfParams(type: .pbkdf2, iterations: 600_000)
    let masterKey = try Crypto.makeMasterKey(password: password, email: email, kdf: kdf)
    let userKey = SymmetricKey64.random()
    let protected = try EncString.encrypt(userKey.combined, with: Crypto.stretch(masterKey: masterKey))
    try storage.saveAccount(AccountRecord(server: env["DEMO_SERVER"] ?? "https://demo.invalid", email: email, kdf: kdf,
                                          encryptedUserKey: protected.string, deviceId: UUID().uuidString))
    func e(_ s: String) -> JSON { .string(try! EncString.encrypt(s, with: userKey).string) }
    let folder = "f-1"
    var ciphers: [JSON] = []
    func add(_ id: String, _ type: Int, _ name: String, fav: Bool = false, folderId: String? = nil, _ extra: [String: JSON]) {
        var o: [String: JSON] = ["id": .string(id), "type": .int(type), "name": e(name), "favorite": .bool(fav),
                                 "folderId": folderId.map { .string($0) } ?? .null, "organizationId": .null,
                                 "revisionDate": .string("2026-10-01T10:00:00.123456Z"),
                                 "creationDate": .string("2024-01-01T10:00:00Z"), "deletedDate": .null, "reprompt": .int(0)]
        for (k, v) in extra { o[k] = v }
        ciphers.append(.object(o))
    }
    add("c1", 1, "GitHub", fav: true, folderId: folder, [
        "login": .object(["username": e("octo@cat.dev"), "password": e("P@ss-гитхаб"), "totp": e("JBSWY3DPEHPK3PXP"),
                          "uris": .array([.object(["uri": e("https://github.com"), "match": .null])])]),
        "fields": .array([.object(["name": e("API token"), "value": e("ghp_secret"), "type": .int(1)])]),
        "notes": e("многострочная\nзаметка"),
        "passwordHistory": .array([.object(["password": e("old-pass"), "lastUsedDate": .string("2025-05-01T10:00:00Z")])])])
    let sites: [(String, String, String, Bool, Bool)] = [
        ("Google", "google.com", "alex@gmail.com", true, true),
        ("Apple ID", "apple.com", "alex@icloud.com", true, false),
        ("Netflix", "netflix.com", "alex@gmail.com", false, false),
        ("Spotify", "spotify.com", "alex.music", false, false),
        ("Amazon", "amazon.com", "alex@gmail.com", false, true),
        ("Cloudflare", "cloudflare.com", "ops@example.dev", false, true),
        ("DigitalOcean", "digitalocean.com", "ops@example.dev", false, true),
        ("Discord", "discord.com", "alex#4242", false, true),
        ("Dropbox", "dropbox.com", "alex@gmail.com", false, false),
        ("Figma", "figma.com", "alex@studio.design", false, false),
        ("GitLab", "gitlab.com", "alex", false, true),
        ("Linear", "linear.app", "alex@example.dev", false, false),
        ("Notion", "notion.so", "alex@example.dev", false, false),
        ("Reddit", "reddit.com", "throwaway_alex", false, false),
        ("Slack", "slack.com", "alex@example.dev", false, false),
        ("Stripe", "stripe.com", "billing@example.dev", false, true),
        ("Telegram", "telegram.org", "+1 555 0100", false, false),
        ("Twitch", "twitch.tv", "alexplays", false, false),
        ("X", "x.com", "@alex", false, true),
        ("YouTube", "youtube.com", "alex@gmail.com", false, false),
    ]
    for (i, site) in sites.enumerated() {
        add("s\(i)", 1, site.0, fav: site.3, folderId: site.0 == "Cloudflare" || site.0 == "DigitalOcean" || site.0 == "Stripe" ? folder : nil, [
            "login": .object(["username": e(site.2), "password": e(PasswordGenerator.generate(GeneratorOptions())),
                              "totp": site.4 ? e("JBSWY3DPEHPK3PXP") : .null,
                              "uris": .array([.object(["uri": e("https://\(site.1)"), "match": .null])])])])
    }
    add("c3", 3, "Visa Platinum", [
        "card": .object(["cardholderName": e("Alex Doe"), "brand": e("Visa"), "number": e("4111111111111111"),
                         "expMonth": e("12"), "expYear": e("2030"), "code": e("123")])])
    add("c6", 3, "Mastercard Travel", [
        "card": .object(["cardholderName": e("Alex Doe"), "brand": e("Mastercard"), "number": e("5555555555554444"),
                         "expMonth": e("08"), "expYear": e("2029"), "code": e("321")])])
    add("c4", 2, "Home Wi-Fi", fav: true, ["secureNote": .object(["type": .int(0)]), "notes": e("SSID: home\npass: correct-horse-battery")])
    add("c5", 4, "Passport", ["identity": .object(["firstName": e("Alex"), "lastName": e("Doe"), "passportNumber": e("X1234567")])])
    let filler = args.count > 1 ? Int(args[1]) ?? 0 : 0
    for i in 0..<filler {
        add("g\(i)", 1, "site-\(i).example", ["login": .object(["username": e("user\(i)"), "password": e("pw-\(i)"),
                                                               "uris": .array([.object(["uri": e("https://site-\(i).example")])])])])
    }
    try storage.saveVault(.object(["profile": .object([:]),
                                   "folders": .array([.object(["id": .string(folder), "name": e("Work")]), .object(["id": .string("f-2"), "name": e("Personal")])]),
                                   "ciphers": .array(ciphers)]))
}
