import Foundation
import LocalAuthentication
import Security

/// Keeps the vault's user key in the login keychain so the vault can be opened with Touch ID or without a prompt.
/// The item's ACL only trusts this app's code signature; Touch ID is checked by the app before reading.
enum KeychainStore {
    static let service = "ws.sanasol.slimwarden.userkey"

    enum Failure: Error, LocalizedError {
        case status(OSStatus)
        case cancelled
        case biometry(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return "Touch ID cancelled"
            case .biometry(let message): return message
            case .status(let s): return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
        }
    }

    static var biometryAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private static func query(account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    static func save(_ key: Data, account: String) throws {
        delete(account: account)
        var q = query(account: account)
        q[kSecValueData] = key
        q[kSecAttrLabel] = "Slimwarden vault key"
        q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.status(status) }
    }

    static func load(account: String) throws -> Data? {
        var q = query(account: account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled, errSecAuthFailed: throw Failure.cancelled
        default: throw Failure.status(status)
        }
    }

    static func exists(account: String) -> Bool {
        var q = query(account: account)
        q[kSecReturnAttributes] = true
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }

    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Use master password"
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError where [.userCancel, .appCancel, .systemCancel, .userFallback].contains(error.code) {
            throw Failure.cancelled
        } catch {
            throw Failure.biometry(error.localizedDescription)
        }
    }
}
