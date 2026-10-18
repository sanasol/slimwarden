import AppKit
import SlimwardenCore
import SwiftUI

@main
struct SlimwardenApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(AppDelegate.menuBarKey) private var menuBarMode = true

    init() {
        Migration.run()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("Slimwarden", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 480)
        }
        .defaultSize(width: 1100, height: 700)
        .commands { AppCommands(model: model) }

        Window("Password Generator", id: "generator") {
            GeneratorView()
                .environment(model)
                .frame(minWidth: 420, minHeight: 420)
        }
        .defaultSize(width: 460, height: 560)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra("Slimwarden", systemImage: "lock.shield", isInserted: $menuBarMode) {
            MenuBarContent().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let menuBarKey = "menuBarMode"

    static var menuBarMode: Bool {
        UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            DispatchQueue.main.async {
                // Last regular window closed: drop the Dock icon and live in the menu bar.
                guard Self.menuBarMode, closing?.styleMask.contains(.titled) == true else { return }
                let remaining = NSApp.windows.filter { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }
                if remaining.isEmpty { NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !Self.menuBarMode }

    static func showDockIcon() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Slimwarden") { open("main") }
        if model.phase == .unlocked {
            Button("Password Generator") { open("generator") }
            let favorites = model.items.filter { $0.favorite && $0.deletedDate == nil }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !favorites.isEmpty {
                Menu("Favorites") {
                    ForEach(favorites) { item in
                        Menu(item.name) {
                            if !item.username.isEmpty { Button("Copy Username") { model.copy(item.username) } }
                            if !item.password.isEmpty { Button("Copy Password") { model.copy(item.password) } }
                            if let totp = TOTP(item.totp) { Button("Copy One-Time Code") { model.copy(totp.code()) } }
                            if let uri = item.uris.first { Button("Copy URL") { model.copy(uri) } }
                        }
                    }
                }
            }
            Divider()
            Button("Sync Now") { Task { await model.sync() } }
            Button("Lock") { model.lock() }
        } else if model.phase == .locked {
            Divider()
            Button("Unlock…") { open("main") }
        }
        Divider()
        Button("Quit Slimwarden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func open(_ id: String) {
        AppDelegate.showDockIcon()
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Item") { model.startCreating() }
                .keyboardShortcut("n")
                .disabled(model.phase != .unlocked)
        }
        CommandMenu("Vault") {
            Button("Sync") { Task { await model.sync() } }
                .keyboardShortcut("r")
                .disabled(model.phase != .unlocked)
            Button("Password Generator") { openWindow(id: "generator") }
                .keyboardShortcut("g")
                .disabled(model.phase != .unlocked)
            Divider()
            Button("Lock") { model.lock() }
                .keyboardShortcut("l")
                .disabled(model.phase != .unlocked)
        }
        CommandMenu("Item") {
            let item = model.selectedItem
            Button("Copy Username") { model.copy(item?.username ?? "") }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(item?.username.isEmpty ?? true)
            Button("Copy Password") { model.copy(item?.password ?? "") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(item?.password.isEmpty ?? true)
            Button("Copy One-Time Code") { model.copy(TOTP(item?.totp ?? "")?.code() ?? "") }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(TOTP(item?.totp ?? "") == nil)
            Divider()
            Button("Edit") { if let item { model.startEditing(item) } }
                .keyboardShortcut("e")
                .disabled(item == nil || item?.deletedDate != nil)
            Button(item?.favorite == true ? "Unpin from Favorites" : "Pin to Favorites") {
                if let item { model.toggleFavorite(item) }
            }
            .keyboardShortcut("d")
            .disabled(item == nil)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .login: LoginView()
            case .locked: UnlockView()
            case .unlocked: MainView()
            }
        }
        .onAppear { AppDelegate.showDockIcon() }
        .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
