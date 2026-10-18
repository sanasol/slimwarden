import AppKit
import SlimwardenCore
import Observation
import SwiftUI

enum SidebarFilter: Hashable {
    case all, favorites, totp, trash, noFolder
    case type(CipherType)
    case folder(String)
}

enum UnlockMode: String, CaseIterable, Identifiable {
    case password, touchID, never
    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "Master password"
        case .touchID: return "Touch ID"
        case .never: return "Don't lock"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Phase { case login, locked, unlocked }

    let storage = Storage(directory: ProcessInfo.processInfo.environment["SLIMWARDEN_DIR"].map { URL(fileURLWithPath: $0) })
    var phase: Phase
    var session: VaultSession?

    var items: [VaultItem] = []
    var folders: [Folder] = []
    var lastSync: Date?
    var syncing = false
    var offline = false
    var errorMessage: String?

    var filter: SidebarFilter = .all
    var search = ""
    var selection: String?
    var editing: EditRequest?

    var generatorOptions = GeneratorOptions()
    var generatorHistory: [GeneratedEntry] = []

    struct EditRequest: Identifiable {
        let id = UUID()
        let original: VaultItem?
        var draft: ItemDraft
    }

    private var syncTimer: Timer?
    private var sessionExpiredShown = false
    private var clipboardChangeCount = 0

    var unlockMode: UnlockMode {
        didSet { UserDefaults.standard.set(unlockMode.rawValue, forKey: "unlockMode") }
    }

    init() {
        let stored = storage.loadAccount()
        account = stored
        phase = stored == nil ? .login : .locked
        unlockMode = UserDefaults.standard.string(forKey: "unlockMode").flatMap(UnlockMode.init)
            ?? (KeychainStore.biometryAvailable ? .touchID : .password)
        observeSystemLock()
        if phase == .locked && unlockMode == .never {
            Task { await unlockFromKeychain() }
        }
    }

    // MARK: Keychain unlock

    private var keychainAccount: String? {
        account.map { "\($0.email)@\($0.server)" }
    }

    var canUseKeychainUnlock: Bool {
        unlockMode != .password && keychainAccount.map(KeychainStore.exists) == true
    }

    /// Returns false when the master password is needed instead.
    @discardableResult
    func unlockFromKeychain() async -> Bool {
        guard let name = keychainAccount, unlockMode != .password else { return false }
        do {
            if unlockMode == .touchID {
                try await KeychainStore.authenticate(reason: "unlock your vault")
            }
            guard let key = try KeychainStore.load(account: name) else { return false }
            let session = try VaultSession.unlock(storage: storage, userKey: key)
            await didUnlock(session)
            return true
        } catch KeychainStore.Failure.cancelled {
            return false
        } catch {
            KeychainStore.delete(account: name)
            errorMessage = "Quick unlock is unavailable (\(error.localizedDescription)). Use the master password."
            return false
        }
    }

    func setUnlockMode(_ mode: UnlockMode) {
        guard let name = keychainAccount, let session else { unlockMode = mode; return }
        Task {
            if mode == .touchID {
                do { try await KeychainStore.authenticate(reason: "turn on Touch ID unlock") } catch { return }
            }
            do {
                if mode == .password {
                    KeychainStore.delete(account: name)
                } else {
                    try KeychainStore.save(await session.userKeyData, account: name)
                }
                unlockMode = mode
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func storeKeyIfNeeded(_ session: VaultSession) async {
        guard let name = keychainAccount else { return }
        if unlockMode == .password {
            KeychainStore.delete(account: name)
        } else if !KeychainStore.exists(account: name) {
            try? KeychainStore.save(await session.userKeyData, account: name)
        }
    }

    /// Cached copy of the stored account (rows read it, so avoid disk access per render).
    private(set) var account: AccountRecord?

    var showIcons: Bool = UserDefaults.standard.object(forKey: "showIcons") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showIcons, forKey: "showIcons") }
    }

    // MARK: Session

    func didUnlock(_ session: VaultSession) async {
        self.session = session
        account = storage.loadAccount()
        sessionExpiredShown = false
        await storeKeyIfNeeded(session)
        apply(await session.snapshot())
        generatorHistory = await session.loadGeneratorHistory()
        generatorOptions = storage.loadGenerator().options
        phase = .unlocked
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync() }
        }
        await sync()
    }

    func lock(automatic: Bool = false) {
        guard phase == .unlocked else { return }
        if automatic && unlockMode == .never { return }
        syncTimer?.invalidate()
        session = nil
        items = []
        folders = []
        selection = nil
        editing = nil
        search = ""
        generatorHistory = []
        phase = .locked
    }

    func logout() {
        if let name = keychainAccount { KeychainStore.delete(account: name) }
        lock()
        storage.wipe()
        account = nil
        IconLoader.shared.clearCache()
        phase = .login
    }

    func sync() async {
        guard let session, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            apply(try await session.sync())
            account = storage.loadAccount()
            offline = false
        } catch APIError.unauthorized {
            offline = true
            if !sessionExpiredShown {
                sessionExpiredShown = true
                errorMessage = "Session expired. Log out and log in again to sync."
            }
        } catch {
            offline = true
        }
    }

    private func apply(_ snapshot: VaultSnapshot) {
        items = snapshot.items
        folders = snapshot.folders
        lastSync = snapshot.lastSync
    }

    private func replace(_ item: VaultItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else { items.append(item) }
    }

    private func observeSystemLock() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock(automatic: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lock(automatic: true) }
        }
    }

    // MARK: Listing

    var visibleItems: [VaultItem] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let terms = query.split(separator: " ").map(String.init)
        return items.filter { item in
            let inTrash = item.deletedDate != nil
            switch filter {
            case .trash: if !inTrash { return false }
            default: if inTrash { return false }
            }
            switch filter {
            case .all, .trash: break
            case .favorites: if !item.favorite { return false }
            case .totp: if item.totp.isEmpty { return false }
            case .noFolder: if item.folderId != nil { return false }
            case .type(let t): if item.type != t { return false }
            case .folder(let id): if item.folderId != id { return false }
            }
            if terms.isEmpty { return true }
            let text = item.searchText
            return terms.allSatisfy { text.contains($0) }
        }
        .sorted { a, b in
            if a.favorite != b.favorite { return a.favorite }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func count(_ filter: SidebarFilter) -> Int {
        items.lazy.filter { item in
            if filter == .trash { return item.deletedDate != nil }
            guard item.deletedDate == nil else { return false }
            switch filter {
            case .all: return true
            case .favorites: return item.favorite
            case .totp: return !item.totp.isEmpty
            case .noFolder: return item.folderId == nil
            case .type(let t): return item.type == t
            case .folder(let id): return item.folderId == id
            case .trash: return false
            }
        }.count
    }

    var selectedItem: VaultItem? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    func folderName(_ id: String?) -> String? {
        guard let id else { return nil }
        return folders.first { $0.id == id }?.name
    }

    // MARK: Mutations

    func perform(_ action: @escaping (VaultSession) async throws -> Void) {
        guard let session else { return }
        Task {
            do { try await action(session) } catch { errorMessage = error.localizedDescription }
        }
    }

    func toggleFavorite(_ item: VaultItem) {
        perform { session in
            let updated = try await session.setFavorite(item, !item.favorite)
            await MainActor.run { self.replace(updated) }
        }
    }

    func move(_ item: VaultItem, to folderId: String?) {
        perform { session in
            let moved = try await session.move(item, toFolder: folderId)
            await MainActor.run { self.replace(moved) }
        }
    }

    func trash(_ item: VaultItem) {
        perform { session in
            let trashed = try await session.trash(item)
            await MainActor.run {
                self.replace(trashed)
                if self.selection == item.id { self.selection = nil }
            }
        }
    }

    func deletePermanently(_ item: VaultItem) {
        perform { session in
            try await session.deletePermanently(item)
            await MainActor.run {
                self.items.removeAll { $0.id == item.id }
                if self.selection == item.id { self.selection = nil }
            }
        }
    }

    func restore(_ item: VaultItem) {
        perform { session in
            let restored = try await session.restore(item)
            await MainActor.run { self.replace(restored) }
        }
    }

    func save(_ request: EditRequest) async -> Bool {
        guard let session else { return false }
        do {
            let saved = try await session.save(request.draft, original: request.original)
            replace(saved)
            selection = saved.id
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func startEditing(_ item: VaultItem) {
        editing = EditRequest(original: item, draft: ItemDraft(item: item))
    }

    func startCreating(_ type: CipherType = .login) {
        var folderId: String?
        if case .folder(let id) = filter { folderId = id }
        var draft = ItemDraft(type: type, folderId: folderId)
        if filter == .favorites { draft.favorite = true }
        editing = EditRequest(original: nil, draft: draft)
    }

    // MARK: Folders

    func createFolder(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        perform { session in
            let folder = try await session.createFolder(name: name)
            await MainActor.run {
                self.folders.append(folder)
                self.sortFolders()
                self.filter = .folder(folder.id)
            }
        }
    }

    func renameFolder(_ folder: Folder, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != folder.name else { return }
        perform { session in
            let renamed = try await session.renameFolder(id: folder.id, name: name)
            await MainActor.run {
                if let i = self.folders.firstIndex(where: { $0.id == folder.id }) { self.folders[i] = renamed }
                self.sortFolders()
            }
        }
    }

    func deleteFolder(_ folder: Folder) {
        perform { session in
            let snapshot = try await session.deleteFolder(id: folder.id)
            await MainActor.run {
                if self.filter == .folder(folder.id) { self.filter = .all }
                self.apply(snapshot)
            }
        }
    }

    private func sortFolders() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Clipboard

    func copy(_ value: String) {
        guard !value.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        // Ask clipboard managers not to record it.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        clipboardChangeCount = pb.changeCount
        let expected = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            if NSPasteboard.general.changeCount == expected { NSPasteboard.general.clearContents() }
        }
    }

    // MARK: Generator

    func generate() -> String {
        PasswordGenerator.generate(generatorOptions)
    }

    /// Remembers a generated password once it is actually used (copied or put into an item).
    func recordGenerated(_ value: String) {
        guard !value.isEmpty, generatorHistory.first?.value != value else { return }
        generatorHistory.insert(GeneratedEntry(value: value), at: 0)
        if generatorHistory.count > 200 { generatorHistory.removeLast(generatorHistory.count - 200) }
        persistGenerator()
    }

    func clearGeneratorHistory() {
        generatorHistory = []
        persistGenerator()
    }

    func persistGenerator() {
        guard let session else { return }
        let history = generatorHistory, options = generatorOptions
        Task { await session.saveGeneratorHistory(history, options: options) }
    }
}
