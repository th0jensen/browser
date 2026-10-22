import Foundation
import Observation

/// Local design: the first matching rule wins. An unavailable destination falls back, not through to another rule.
struct LinkRouteRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var host: String
    var includesSubdomains: Bool
    var destinationSpaceID: UUID
    /// Reserved for callers with a verified identity. The current application URL callback supplies none.
    var sourceBundleID: String? = nil

    static func normalizedHost(_ input: String) -> String? {
        var host = input.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        // Accept a host, never a URL, wildcard, credential, port, path, or escaped separator.
        guard !host.isEmpty, !host.contains(where: { $0.isWhitespace }),
              !host.contains(where: { "/\\:@?#%*[]".contains($0) }),
              let url = URL(string: "https://\(host)"),
              let ascii = url.host(percentEncoded: false)?.lowercased(), ascii.utf8.count <= 253 else { return nil }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { return nil }
        return ascii
    }

    /// `verifiedSourceBundleID` must come from a trusted platform event, never the frontmost app or page data.
    func matches(_ url: URL, verifiedSourceBundleID: String? = nil) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let raw = url.host(percentEncoded: false), let candidate = Self.normalizedHost(raw),
              let host = Self.normalizedHost(host),
              sourceBundleID == nil || (verifiedSourceBundleID != nil && sourceBundleID == verifiedSourceBundleID) else { return false }
        return candidate == host || (includesSubdomains && candidate.hasSuffix("." + host))
    }
}

/// A descriptor-only snapshot shared by rule editing, labels, and delivery checks.
/// Resolve both owners through the same injected store. Never request WebKit resources here.
@MainActor
struct LinkRouteDestination: Identifiable, Equatable {
    enum Availability: Equatable {
        case available, missingSpace, unreadableSpaces, missingProfile, unreadableProfiles
    }

    let id: UUID
    let space: BrowserSpace?
    let profile: BrowserProfileDescriptor?
    let availability: Availability
    var isAvailable: Bool { availability == .available }

    init(spaceID: UUID, spaces: BrowserSpaceStore) {
        id = spaceID
        space = spaces.loadFailed ? nil : spaces.space(spaceID)
        profile = spaces.profiles.loadFailed ? nil : space.flatMap { spaces.profiles.profile($0.profileID) }
        if spaces.loadFailed { availability = .unreadableSpaces }
        else if space == nil { availability = .missingSpace }
        else if spaces.profiles.loadFailed { availability = .unreadableProfiles }
        else if profile == nil { availability = .missingProfile }
        else { availability = .available }
    }

    static func all(in spaces: BrowserSpaceStore) -> [Self] {
        guard !spaces.loadFailed else { return [] }
        return spaces.spaces.map { Self(spaceID: $0.id, spaces: spaces) }
    }

    var label: String {
        switch availability {
        case .available: "\(profile!.title) — \(space!.title)"
        case .missingSpace: "Missing Space (\(id))"
        case .unreadableSpaces: "Space unavailable (\(id)) — Spaces file could not be read"
        case .missingProfile: "\(space!.title) — missing profile (\(space!.profileID))"
        case .unreadableProfiles: "\(space!.title) — profile unavailable (\(space!.profileID)); Profiles file could not be read"
        }
    }

    var identityDescription: String {
        "Space ID: \(id)" + (space.map { "\nProfile ID: \($0.profileID)" } ?? "")
    }
}

@MainActor @Observable
final class LinkRouteRuleStore {
    static let shared = LinkRouteRuleStore(directory: BrowserProfile.directory, enabled: !BrowserProfile.isTesting)
    private(set) var rules: [LinkRouteRule] = []
    private(set) var loadFailed = false
    private let directory: URL
    private let enabled: Bool

    enum Failure: LocalizedError {
        case invalidHost, unavailableDestination, unreadableFile, invalidRules
        var errorDescription: String? {
            switch self {
            case .invalidHost: "Enter a host such as example.com, without a scheme, port, or path."
            case .unavailableDestination: "Choose an available Space with a known owning profile."
            case .unreadableFile: "The link rules file could not be read. Keep the file for recovery before changing rules."
            case .invalidRules: "The link rules contain duplicate identifiers."
            }
        }
    }

    init(directory: URL, enabled: Bool = true) {
        self.directory = directory
        self.enabled = enabled
        let file = directory.appending(path: "LinkRoutes.json")
        guard enabled, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            rules = try Self.validated(JSONDecoder().decode([LinkRouteRule].self, from: Data(contentsOf: file)))
        } catch { loadFailed = true }
    }

    func firstMatch(for url: URL) -> LinkRouteRule? {
        // NSApplicationDelegate.application(_:open:) does not provide a verified source identity.
        rules.first { $0.matches(url) }
    }

    func save(_ rule: LinkRouteRule, spaces: BrowserSpaceStore) throws {
        guard LinkRouteDestination(spaceID: rule.destinationSpaceID, spaces: spaces).isAvailable else {
            throw Failure.unavailableDestination
        }
        var next = rules
        if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index] = rule }
        else { next.append(rule) }
        try persist(next)
    }

    func remove(_ id: UUID) throws { try persist(rules.filter { $0.id != id }) }

    func move(_ id: UUID, by offset: Int) throws {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(index + offset) else { return }
        var next = rules
        next.swapAt(index, index + offset)
        try persist(next)
    }

    private static func validated(_ rules: [LinkRouteRule]) throws -> [LinkRouteRule] {
        var ids = Set<UUID>()
        return try rules.map { rule in
            guard ids.insert(rule.id).inserted else { throw Failure.invalidRules }
            guard let host = LinkRouteRule.normalizedHost(rule.host) else { throw Failure.invalidHost }
            var rule = rule
            rule.host = host
            return rule
        }
    }

    private func persist(_ next: [LinkRouteRule]) throws {
        guard !loadFailed else { throw Failure.unreadableFile }
        let next = try Self.validated(next)
        if enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "LinkRoutes.json")
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        rules = next
    }
}
