import SlimwardenCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppDelegate.menuBarKey) private var menuBarMode = true

    var body: some View {
        Form {
            Section {
                Picker("Unlock with", selection: Binding(get: { model.unlockMode }, set: { model.setUnlockMode($0) })) {
                    ForEach(UnlockMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                            .disabled(mode == .touchID && !KeychainStore.biometryAvailable)
                    }
                }
                .disabled(model.phase != .unlocked)
                Text(description).font(.caption).foregroundStyle(.secondary)
                if model.phase != .unlocked {
                    Text("Unlock the vault to change this.").font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Window") {
                Toggle("Keep running in the menu bar when the window is closed", isOn: $menuBarMode)
                Text(menuBarMode ? "Closing the window hides Slimwarden to the menu bar. Quit from the menu bar icon or ⌘Q."
                                 : "Closing the window quits Slimwarden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                Toggle("Show website icons", isOn: Binding(get: { model.showIcons }, set: { model.showIcons = $0 }))
                Text("Icons are fetched through your own server's icon service.").font(.caption).foregroundStyle(.secondary)
            }
            if let account = model.account {
                Section("Account") {
                    LabeledContent("Email", value: account.email)
                    LabeledContent("Server", value: account.server)
                    if let date = account.lastSync {
                        LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Log out…", role: .destructive) { model.logout() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var description: String {
        switch model.unlockMode {
        case .password:
            return "The vault key is kept only in memory. The master password is required on every launch and after locking."
        case .touchID:
            return "The vault key is stored in your login keychain, readable only by Slimwarden. Touch ID is required to unlock. The vault locks on sleep and screen lock."
        case .never:
            return "The vault key is stored in your login keychain and the vault opens automatically. It does not lock on sleep or screen lock."
        }
    }
}
