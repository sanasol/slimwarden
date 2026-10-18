import SlimwardenCore
import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("lastServer") private var server = ""
    @AppStorage("lastEmail") private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var rememberDevice = true
    @State private var twoFactorProviders: [Int]?
    @State private var provider = 0
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Log in to your vault").font(.title2.bold())

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Server").gridColumnAlignment(.trailing)
                    TextField("", text: $server, prompt: Text("vault.example.com"))
                }
                GridRow {
                    Text("Email")
                    TextField("", text: $email).textContentType(.username)
                }
                GridRow {
                    Text("Master password")
                    SecureField("", text: $password).textContentType(.password)
                }
                if let providers = twoFactorProviders {
                    GridRow {
                        Text("Two-step login")
                        Picker("", selection: $provider) {
                            if providers.contains(0) { Text("Authenticator app").tag(0) }
                            if providers.contains(1) { Text("Email").tag(1) }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Code")
                        HStack {
                            TextField("", text: $code)
                            if provider == 1 {
                                Button("Send code") { sendEmail() }.disabled(busy)
                            }
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("Remember this device", isOn: $rememberDevice)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 420)
            .onSubmit(login)

            if let error {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }

            Button(action: login) {
                if busy { ProgressView().controlSize(.small) } else { Text("Log in").frame(width: 120) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || server.isEmpty || email.isEmpty || password.isEmpty)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func login() {
        guard !busy, !server.isEmpty, !email.isEmpty, !password.isEmpty else { return }
        busy = true
        error = nil
        let twoFactor = twoFactorProviders == nil ? nil
            : TwoFactor(provider: provider, token: code.trimmingCharacters(in: .whitespaces), remember: rememberDevice)
        Task {
            defer { busy = false }
            do {
                let session = try await VaultSession.login(storage: model.storage, server: server, email: email,
                                                           password: password, twoFactor: twoFactor)
                password = ""
                await model.didUnlock(session)
            } catch APIError.twoFactorRequired(let providers) {
                let supported = providers.filter { $0 == 0 || $0 == 1 }
                if supported.isEmpty {
                    error = "This account only offers two-step methods Slimwarden doesn't support (e.g. WebAuthn, YubiKey)."
                } else {
                    if twoFactorProviders != nil { error = "Invalid code" }
                    twoFactorProviders = supported
                    provider = supported[0]
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func sendEmail() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await VaultSession.requestEmailCode(server: server, email: email, password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Vault is locked").font(.title2.bold())
            if let account = model.account {
                Text("\(account.email)\n\(URL(string: account.server)?.host() ?? account.server)")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            SecureField("Master password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($focused)
                .onSubmit(unlock)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            Button(action: unlock) {
                if busy { ProgressView().controlSize(.small) } else { Text("Unlock").frame(width: 100) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || password.isEmpty)

            if model.canUseKeychainUnlock {
                Button {
                    Task { await quickUnlock() }
                } label: {
                    Label(model.unlockMode == .touchID ? "Unlock with Touch ID" : "Unlock without password",
                          systemImage: model.unlockMode == .touchID ? "touchid" : "lock.open")
                }
                .disabled(busy)
            }

            Button("Log out", role: .destructive) { model.logout() }
                .buttonStyle(.link)
                .padding(.top, 20)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            focused = true
            if model.unlockMode == .touchID && model.canUseKeychainUnlock {
                Task { await quickUnlock() }
            }
        }
    }

    private func quickUnlock() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await model.unlockFromKeychain()
    }

    private func unlock() {
        guard !busy, !password.isEmpty else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let session = try await VaultSession.unlock(storage: model.storage, password: password)
                password = ""
                await model.didUnlock(session)
            } catch CryptoError.macMismatch {
                error = "Wrong master password"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
