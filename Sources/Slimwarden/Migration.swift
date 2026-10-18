import Foundation

/// One-time import of data from the app's pre-release name (LiteWarden).
enum Migration {
    static func run() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("LiteWarden", isDirectory: true)
        let new = support.appendingPathComponent("Slimwarden", isDirectory: true)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.appendingPathComponent("account.json").path) {
            try? fm.removeItem(at: new)
            try? fm.moveItem(at: old, to: new)
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromLiteWarden"),
              let legacy = UserDefaults(suiteName: "ws.sanasol.litewarden") else { return }
        for key in ["lastServer", "lastEmail", "unlockMode", "showIcons", "menuBarMode"] {
            if defaults.object(forKey: key) == nil, let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromLiteWarden")
    }
}
