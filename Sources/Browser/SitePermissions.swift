import Foundation
import Observation

/// What the user allowed or refused each site to do. Camera and microphone answers are kept between launches for
/// normal windows, and listed in Settings ▸ Site Settings; downloads are remembered until the app quits.
@MainActor
@Observable
final class SitePermissions {
    enum Permission: String {
        /// Downloading files the user didn't click to download.
        case downloads
        case camera
        case microphone

        /// Whether the answer is saved between launches.
        var isSaved: Bool {
            self != .downloads
        }
    }

    private struct Key: Hashable {
        let site: String
        let permission: Permission
    }

    /// A site's saved camera and microphone answers, `nil` where it hasn't asked.
    struct SiteDecisions: Identifiable, Equatable {
        let site: String
        var camera: Bool?
        var microphone: Bool?

        var id: String { site }
    }

    static let shared = SitePermissions(defaults: BrowserProfile.isTesting || BrowserProfile.qaDirectory != nil ? nil : .standard)
    private static let storageKey = "sitePermissions"

    /// `nil` keeps every answer in memory only.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let file: StoreFile?
    private var decisions: [Key: Bool] = [:]
    private struct PendingPrompt {
        let id: UUID
        let site: String
        let permissions: Set<Permission>
        let task: Task<Bool, Never>
    }

    @ObservationIgnored private var prompts: [String: PendingPrompt] = [:]
    @ObservationIgnored private var revisions: [Key: UInt] = [:]

    init(defaults: UserDefaults? = nil, file: StoreFile? = nil) {
        self.defaults = defaults
        self.file = file
        let saved = file?.readNow().flatMap { try? JSONDecoder().decode([String: [String: Bool]].self, from: $0) }
            ?? defaults?.dictionary(forKey: Self.storageKey) as? [String: [String: Bool]] ?? [:]
        for (site, answers) in saved {
            for (name, isAllowed) in answers {
                guard let permission = Permission(rawValue: name), permission.isSaved else { continue }
                decisions[Key(site: site, permission: permission)] = isAllowed
            }
        }
    }

    /// Refused if any of the permissions was refused, allowed only once all of them were allowed.
    func decision(for permissions: Set<Permission>, on site: String) -> Bool? {
        let known = permissions.map { decisions[Key(site: site, permission: $0)] }
        if known.contains(false) { return false }
        return known.allSatisfy { $0 == true } ? true : nil
    }

    /// Asks only when the site's answer isn't known yet, sharing one prompt between requests that arrive together.
    /// A prompt that ends without an answer, because its tab closed, refuses without remembering it.
    func decide(_ permissions: Set<Permission>, on site: String,
                ask: @escaping @MainActor () async -> Bool?) async -> Bool {
        if let decision = decision(for: permissions, on: site) { return decision }
        let promptKey = ([site] + permissions.map(\.rawValue).sorted()).joined(separator: " ")
        if let prompt = prompts[promptKey] { return await prompt.task.value }
        let id = UUID()
        let keys = permissions.map { Key(site: site, permission: $0) }
        let expectedRevisions = keys.map { revisions[$0, default: 0] }
        let task = Task { [weak self] in
            let answer = await ask()
            guard let self else { return false }
            guard self.prompts[promptKey]?.id == id else {
                return self.decision(for: permissions, on: site) ?? false
            }
            self.prompts[promptKey] = nil
            // A Settings edit or another prompt's answer takes precedence over this older question.
            guard !Task.isCancelled,
                  keys.map({ self.revisions[$0, default: 0] }) == expectedRevisions else {
                return self.decision(for: permissions, on: site) ?? false
            }
            guard let isAllowed = answer else { return false }
            for key in keys {
                self.decisions[key] = isAllowed
                self.revisions[key, default: 0] &+= 1
            }
            self.save()
            return isAllowed
        }
        prompts[promptKey] = PendingPrompt(id: id, site: site, permissions: permissions, task: task)
        return await task.value
    }

    /// Sites with a camera or microphone answer, sorted by name.
    var mediaDecisions: [SiteDecisions] {
        var sites: [String: SiteDecisions] = [:]
        for (key, isAllowed) in decisions where key.permission.isSaved {
            var site = sites[key.site] ?? SiteDecisions(site: key.site)
            if key.permission == .camera { site.camera = isAllowed } else { site.microphone = isAllowed }
            sites[key.site] = site
        }
        return sites.values.sorted { $0.site.localizedStandardCompare($1.site) == .orderedAscending }
    }

    /// Sets an answer, or forgets it with `nil` so the site asks again.
    func setDecision(_ isAllowed: Bool?, for permission: Permission, on site: String) {
        invalidatePrompts { $0.site == site && $0.permission == permission }
        let key = Key(site: site, permission: permission)
        revisions[key, default: 0] &+= 1
        decisions[key] = isAllowed
        save()
    }

    func removeDecisions(on site: String) {
        invalidatePrompts { $0.site == site }
        decisions = decisions.filter { $0.key.site != site }
        save()
    }

    func removeAllMediaDecisions() {
        invalidatePrompts { $0.permission.isSaved }
        decisions = decisions.filter { !$0.key.permission.isSaved }
        save()
    }

    /// Removing the entry invalidates an answer even when the sheet itself ignores cancellation.
    private func invalidatePrompts(matching matches: (Key) -> Bool) {
        for (name, prompt) in Array(prompts) where prompt.permissions.contains(where: {
            matches(Key(site: prompt.site, permission: $0))
        }) {
            prompt.task.cancel()
            prompts[name] = nil
        }
    }

    private func save() {
        var saved: [String: [String: Bool]] = [:]
        for (key, isAllowed) in decisions where key.permission.isSaved {
            saved[key.site, default: [:]][key.permission.rawValue] = isAllowed
        }
        defaults?.set(saved, forKey: Self.storageKey)
        file?.writeNow(try? JSONEncoder().encode(saved))
    }
}
