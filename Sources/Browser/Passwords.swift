import Foundation
import Observation
import Security
import WebKit

/// The HTTPS host and port a password belongs to. Passwords only fill on exactly the same origin, so one saved on
/// accounts.example.com isn't offered on example.com, and none are saved or filled on plain HTTP.
struct PasswordOrigin: Hashable, Comparable, CustomStringConvertible, Sendable {
    let host: String
    let port: Int

    init?(host: String, port: Int = 443) {
        let host = host.lowercased()
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        self.host = host
        self.port = port
    }

    init?(url: URL?) {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host() else { return nil }
        self.init(host: host, port: url.port ?? 443)
    }

    /// WebKit reports port 0 for the scheme's default port.
    @MainActor
    init?(_ origin: WKSecurityOrigin) {
        guard origin.protocol.lowercased() == "https" else { return nil }
        self.init(host: origin.host, port: origin.port == 0 ? 443 : origin.port)
    }

    /// As a page's `location.origin` reads it.
    var description: String {
        port == 443 ? "https://\(host)" : "https://\(host):\(port)"
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.host, lhs.port) < (rhs.host, rhs.port)
    }
}

/// A saved sign-in, without its password, which stays in the keychain until it's needed.
struct SavedPassword: Identifiable, Hashable, Sendable {
    let origin: PasswordOrigin
    /// Empty for sites that only ask for a password.
    let username: String

    var id: String { "\(origin) \(username)" }
}

@MainActor
protocol PasswordStorage: AnyObject {
    func savedPasswords() throws -> [SavedPassword]
    func password(for account: SavedPassword) throws -> String?
    func save(_ password: String, for account: SavedPassword) throws
    func remove(_ account: SavedPassword) throws
}

enum PasswordStorageError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error (\(status))."
        }
    }
}

/// Isolated QA and tests must never list, change, or reveal the shared profile's keychain items.
@MainActor
final class EphemeralPasswordStorage: PasswordStorage {
    private var items: [SavedPassword: String] = [:]

    func savedPasswords() throws -> [SavedPassword] { Array(items.keys) }
    func password(for account: SavedPassword) throws -> String? { items[account] }
    func save(_ password: String, for account: SavedPassword) throws { items[account] = password }
    func remove(_ account: SavedPassword) throws { items[account] = nil }
}

/// Keeps passwords as internet password items in the login keychain, which only this app can read without asking.
/// The data protection keychain would need a provisioning profile in every build.
final class KeychainPasswordStorage: PasswordStorage {
    /// Marks the items this app saves, so it never lists or reads another app's.
    private static let itemDescription = "Browser website password"

    private func query(for origin: PasswordOrigin? = nil, username: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrDescription as String: Self.itemDescription,
        ]
        if let origin {
            query[kSecAttrServer as String] = origin.host
            query[kSecAttrPort as String] = origin.port
        }
        if let username { query[kSecAttrAccount as String] = username }
        return query
    }

    func savedPasswords() throws -> [SavedPassword] {
        var query = query()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PasswordStorageError.keychain(status) }
        return (result as? [[String: Any]] ?? []).compactMap { item in
            guard let host = item[kSecAttrServer as String] as? String,
                  let origin = PasswordOrigin(host: host, port: item[kSecAttrPort as String] as? Int ?? 443)
            else { return nil }
            return SavedPassword(origin: origin, username: item[kSecAttrAccount as String] as? String ?? "")
        }
    }

    func password(for account: SavedPassword) throws -> String? {
        var query = query(for: account.origin, username: account.username)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PasswordStorageError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    func save(_ password: String, for account: SavedPassword) throws {
        let query = query(for: account.origin, username: account.username)
        let data = Data(password.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = account.origin.host
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PasswordStorageError.keychain(status) }
    }

    func remove(_ account: SavedPassword) throws {
        let status = SecItemDelete(query(for: account.origin, username: account.username) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw PasswordStorageError.keychain(status) }
    }
}

/// Saves the passwords the user signs in with, and fills them back in when asked. Private windows have none.
@MainActor
@Observable
final class PasswordManager {
    static let shared: PasswordManager = {
        if BrowserProfile.isTesting || BrowserProfile.qaDirectory != nil {
            return PasswordManager(storage: EphemeralPasswordStorage())
        }
        return PasswordManager(storage: KeychainPasswordStorage(), defaults: .standard)
    }()
    static let offersToSaveKey = "offersToSavePasswords"
    private static let neverSaveKey = "neverSavePasswordSites"

    enum Offer: Equatable {
        case save
        /// The site has a different password saved for the same user name.
        case update
    }

    /// The credential state the user is being asked to replace. Recheck it after waiting for the tab or sheet.
    struct SaveProposal: Equatable {
        let offer: Offer
        fileprivate let account: SavedPassword
        fileprivate let revision: UInt64
        fileprivate let previousPassword: String?
    }

    /// Every saved sign-in, by site then user name. Loaded the first time it's needed.
    private(set) var passwords: [SavedPassword] = []
    private(set) var lastError: String?
    var usesEphemeralStorage: Bool { storage is EphemeralPasswordStorage }
    /// Sites the user asked never to save passwords for, as origins.
    private(set) var neverSaveSites: [String]
    var offersToSave: Bool {
        didSet { defaults?.set(offersToSave, forKey: Self.offersToSaveKey) }
    }
    @ObservationIgnored private let storage: PasswordStorage
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var pendingSaveOffers: Set<SavedPassword> = []
    @ObservationIgnored private var passwordRevisions: [SavedPassword: UInt64] = [:]

    /// Pass `nil` defaults to keep the settings in memory only.
    init(storage: PasswordStorage, defaults: UserDefaults? = nil) {
        self.storage = storage
        self.defaults = defaults
        offersToSave = defaults?.object(forKey: Self.offersToSaveKey) as? Bool ?? true
        neverSaveSites = defaults?.stringArray(forKey: Self.neverSaveKey) ?? []
    }

    func reload() {
        do {
            passwords = try storage.savedPasswords().sorted {
                ($0.origin, $0.username.localizedLowercase) < ($1.origin, $1.username.localizedLowercase)
            }
            hasLoaded = true
        } catch {
            hasLoaded = false
            report(error, operation: "load saved passwords")
        }
    }

    func dismissError() { lastError = nil }

    private func report(_ error: Error, operation: String) {
        lastError = "Browser couldn’t \(operation). \(error.localizedDescription)"
    }

    func loadIfNeeded() {
        if !hasLoaded { reload() }
    }

    /// The sign-ins saved for exactly this origin.
    func passwords(for origin: PasswordOrigin?) -> [SavedPassword] {
        guard let origin else { return [] }
        return passwords.filter { $0.origin == origin }
    }

    func password(for account: SavedPassword) -> String? {
        do { return try storage.password(for: account) }
        catch {
            report(error, operation: "read this password")
            return nil
        }
    }

    /// Whether to offer to save a sign-in: not when saving is off or refused for the site, or the same password is
    /// already saved.
    func offer(for capture: PasswordCapture) -> Offer? {
        saveProposal(for: capture)?.offer
    }

    func saveProposal(for capture: PasswordCapture) -> SaveProposal? {
        guard offersToSave, !neverSaveSites.contains(capture.origin.description) else { return nil }
        loadIfNeeded()
        guard hasLoaded else { return nil }
        // A failed read must not be mistaken for a changed password.
        do {
            let previousPassword = try storage.password(for: capture.account)
            guard previousPassword != capture.password else { return nil }
            return SaveProposal(offer: previousPassword == nil ? .save : .update, account: capture.account,
                                revision: passwordRevisions[capture.account, default: 0], previousPassword: previousPassword)
        }
        catch {
            report(error, operation: "read this password")
            return nil
        }
    }

    /// All windows share this reservation, including tabs with different script message handlers.
    func reserveSaveOffer(for capture: PasswordCapture) -> SaveProposal? {
        guard !pendingSaveOffers.contains(capture.account), let proposal = saveProposal(for: capture) else { return nil }
        pendingSaveOffers.insert(capture.account)
        return proposal
    }

    func releaseSaveOffer(for account: SavedPassword) {
        pendingSaveOffers.remove(account)
    }

    /// A newer save, removal, or preference change supersedes a sheet that was already waiting for the user.
    @discardableResult
    func save(_ capture: PasswordCapture, ifUnchanged proposal: SaveProposal) throws -> Bool {
        guard capture.account == proposal.account, passwordRevisions[capture.account, default: 0] == proposal.revision,
              offersToSave, !neverSaveSites.contains(capture.origin.description) else { return false }
        let currentPassword: String?
        do { currentPassword = try storage.password(for: capture.account) }
        catch {
            report(error, operation: "check this saved password")
            throw error
        }
        guard currentPassword == proposal.previousPassword, currentPassword != capture.password else { return false }
        try save(capture)
        return true
    }

    func save(_ capture: PasswordCapture) throws {
        do { try storage.save(capture.password, for: capture.account) }
        catch {
            report(error, operation: "save this password")
            throw error
        }
        passwordRevisions[capture.account, default: 0] &+= 1
        reload()
    }

    func remove(_ account: SavedPassword) {
        do {
            try storage.remove(account)
            passwordRevisions[account, default: 0] &+= 1
            reload()
        } catch {
            report(error, operation: "remove this password")
        }
    }

    func neverSave(on origin: PasswordOrigin) {
        guard !neverSaveSites.contains(origin.description) else { return }
        neverSaveSites.append(origin.description)
        neverSaveSites.sort()
        defaults?.set(neverSaveSites, forKey: Self.neverSaveKey)
    }

    func allowSaving(on site: String) {
        neverSaveSites.removeAll { $0 == site }
        defaults?.set(neverSaveSites, forKey: Self.neverSaveKey)
    }
}
