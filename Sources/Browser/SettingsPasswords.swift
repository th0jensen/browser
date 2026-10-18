import AppKit
import LocalAuthentication
import SwiftUI

/// Saved passwords stay hidden until the user unlocks them with Touch ID or their login password, and lock again
/// when the tab closes or the app goes to the background.
struct PasswordSettings: View {
    @Bindable var passwords: PasswordManager
    let passkeys: PasskeyAccess
    @State private var isUnlocked = false
    @State private var unlockRequestID: UUID?
    @State private var passwordSearchQuery = ""
    @State private var revealedPasswords: [SavedPassword.ID: String] = [:]
    @State private var passwordToRemove: SavedPassword?

    private var matchingAccounts: [SavedPassword] {
        let searchText = passwordSearchQuery.trimmingCharacters(in: .whitespaces)
        guard !searchText.isEmpty else { return passwords.passwords }
        return passwords.passwords.filter {
            $0.origin.host.localizedCaseInsensitiveContains(searchText) || $0.username.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $passwords.offersToSave) {
                    Text("Offer to save passwords")
                    Text("Browser asks when you submit a password on a secure site, keeps passwords in your keychain, and "
                         + "fills them in on that site when you choose. Private windows never save or fill them.")
                }
            }

            if let error = passwords.lastError {
                Section("Password Storage") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Dismiss") { passwords.dismissError() }
                }
            }

            Section("Saved Passwords") {
                if isUnlocked {
                    savedPasswords
                } else {
                    HStack {
                        Text("Unlock to see your saved passwords.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Unlock…") { Task { await unlock() } }
                    }
                }
            }

            if !passwords.neverSaveSites.isEmpty {
                Section("Never Saved") {
                    ForEach(passwords.neverSaveSites, id: \.self) { site in
                        HStack {
                            Text(site)
                            Spacer()
                            Button { passwords.allowSaving(on: site) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Offer to Save Passwords Again")
                        }
                    }
                }
            }

            Section("Passkeys") {
                passkeyStatus
            }
        }
        .task { passkeys.refresh() }
        .onDisappear(perform: lock)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in lock() }
        .confirmationDialog("Remove this saved password?", isPresented: Binding(get: { passwordToRemove != nil },
                                                                                set: { if !$0 { passwordToRemove = nil } }),
                            presenting: passwordToRemove) { account in
            Button("Remove", role: .destructive) {
                revealedPasswords[account.id] = nil
                passwords.remove(account)
            }
        } message: { account in
            Text("Browser forgets the password for \(account.username.isEmpty ? "this site" : "“\(account.username)”") "
                 + "on \(account.origin.host). It can’t be undone.")
        }
    }

    @ViewBuilder
    private var savedPasswords: some View {
        TextField("Search", text: $passwordSearchQuery, prompt: Text("Search Passwords"))
            .labelsHidden()
        if matchingAccounts.isEmpty {
            Text(passwordSearchQuery.isEmpty ? "No passwords are saved." : "No passwords match “\(passwordSearchQuery)”.")
                .foregroundStyle(.secondary)
        }
        ForEach(matchingAccounts) { account in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.origin.port == 443 ? account.origin.host : "\(account.origin.host):\(account.origin.port)")
                    Text(account.username.isEmpty ? "No user name" : account.username)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(revealedPasswords[account.id] ?? "••••••••")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button {
                    revealedPasswords[account.id] = revealedPasswords[account.id] == nil ? passwords.password(for: account) : nil
                } label: {
                    Image(systemName: revealedPasswords[account.id] == nil ? "eye" : "eye.slash")
                }
                .help(revealedPasswords[account.id] == nil ? "Show Password" : "Hide Password")
                Button { copy(account) } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy Password")
                Button { passwordToRemove = account } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Remove Password")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var passkeyStatus: some View {
        LabeledContent("Access") {
            Text(passkeys.status == .unavailable ? "Unavailable in this build" : passkeys.status == .authorized ? "Enabled" : passkeys.status == .denied ? "Not allowed" : "Not enabled")
                .foregroundStyle(.secondary)
        }
        if passkeys.status == .notDetermined {
            Button("Enable Passkeys…") { Task { await passkeys.requestAccess() } }.disabled(passkeys.isRequesting)
        }
        Text(passkeys.status.description).font(.caption).foregroundStyle(.secondary)
        if passkeys.status != .unavailable { Button("Refresh Access") { passkeys.refresh() } }
    }

    private func unlock() async {
        let request = UUID()
        unlockRequestID = request
        let context = LAContext()
        guard (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                 localizedReason: "show your saved passwords")) == true,
              unlockRequestID == request, NSApp.isActive else { return }
        passwords.reload()
        isUnlocked = true
        unlockRequestID = nil
    }

    private func lock() {
        unlockRequestID = nil
        passwordToRemove = nil
        isUnlocked = false
        revealedPasswords = [:]
        passwordSearchQuery = ""
    }

    /// Marked as concealed, so clipboard managers that respect it don't keep the password.
    private func copy(_ account: SavedPassword) {
        guard let password = passwords.password(for: account) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(password, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}
