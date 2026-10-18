import Foundation
import Observation
import WebKit

/// Blocks the trackers in `TrackerBlocklist` in every web view. The rule list is compiled off the main thread once,
/// and kept in WebKit's rule list store between launches until the list or the sites where blocking is off change.
@MainActor
@Observable
final class ContentBlocker {
    static let shared: ContentBlocker = {
        let isolated = BrowserProfile.isTesting || BrowserProfile.qaDirectory != nil
        if BrowserProfile.isTesting { return ContentBlocker() }
        let store: WKContentRuleListStore
        if isolated {
            let directory = BrowserProfile.directory.appending(path: "ContentRules", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store = WKContentRuleListStore(url: directory)
        } else {
            store = .default()
        }
        return ContentBlocker(defaults: isolated ? nil : .standard, store: store)
    }()
    static let enabledKey = "blocksTrackers"
    private static let exceptionsKey = "trackerBlockingExceptions"
    private static let signatureKey = "trackerRuleListSignature"
    private static let identifier = "Trackers"

    private(set) var isEnabled: Bool
    /// Sites where blocking is off, along with their subdomains. Stored without "www.".
    private(set) var exceptions: [String]
    private(set) var isUpdating = false
    private(set) var lastError: String?
    /// Whether the installed rules reflect the current list and exceptions.
    var isReady: Bool { installedSignature == Self.signature(exceptions: exceptions) }
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let store: WKContentRuleListStore?
    @ObservationIgnored private var ruleList: WKContentRuleList?
    private var installedSignature: String?
    @ObservationIgnored private let installedLists = NSMapTable<WKUserContentController, WKContentRuleList>.weakToStrongObjects()
    @ObservationIgnored private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Pass `nil` defaults to keep the settings in memory only, and a `nil` store to never block anything.
    init(defaults: UserDefaults? = nil, store: WKContentRuleListStore? = nil) {
        self.defaults = defaults
        self.store = store
        isEnabled = defaults?.object(forKey: Self.enabledKey) as? Bool ?? true
        exceptions = defaults?.stringArray(forKey: Self.exceptionsKey) ?? []
        if store != nil { loadRuleList() }
    }

    /// Blocks trackers in a web view's pages from now on, and whenever the rule list changes.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        apply(to: controller)
    }

    /// Call before a page's first load when protection must already be installed.
    func prepare() async {
        await loading?.value
        if !isReady { await loadRuleList().value }
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        defaults?.set(isEnabled, forKey: Self.enabledKey)
        controllers.allObjects.forEach(apply)
        if isEnabled && !isReady { loadRuleList() }
    }

    /// Whether pages from the host have their trackers blocked.
    func isBlocking(on host: String?) -> Bool {
        isEnabled && exception(covering: host) == nil
    }

    func exception(covering host: String?) -> String? {
        guard let host = host.map(Self.site) else { return nil }
        return exceptions.first { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Turns blocking on or off for a host's site, and returns once pages loaded from now on follow the change.
    func setBlocking(_ isBlocking: Bool, on host: String) async {
        let site = Self.site(host)
        if isBlocking {
            exceptions.removeAll { site == $0 || site.hasSuffix("." + $0) }
        } else if exception(covering: site) == nil {
            exceptions.append(site)
            exceptions.sort()
        }
        await saveExceptions()
    }

    func removeException(_ site: String) async {
        exceptions.removeAll { $0 == site }
        await saveExceptions()
    }

    func removeAllExceptions() async {
        exceptions = []
        await saveExceptions()
    }

    private func saveExceptions() async {
        defaults?.set(exceptions, forKey: Self.exceptionsKey)
        await loadRuleList().value
    }

    /// The host without "www.", lowercased, as rules match it.
    static func site(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func signature(exceptions: [String]) -> String {
        "\(TrackerBlocklist.version) \(exceptions.sorted().joined(separator: " "))"
    }

    /// Loads one rule list at a time, each for the exceptions as they are when it starts.
    @discardableResult
    private func loadRuleList() -> Task<Void, Never> {
        let previous = loading
        let task = Task { [weak self] in
            await previous?.value
            await self?.loadLatestRuleList()
        }
        loading = task
        return task
    }

    private func loadLatestRuleList() async {
        guard let store else { return }
        isUpdating = true
        defer { isUpdating = false }
        let exceptions = exceptions
        let signature = Self.signature(exceptions: exceptions)
        if installedSignature == signature { lastError = nil; return }
        if defaults?.string(forKey: Self.signatureKey) == signature,
           let list = try? await store.contentRuleList(forIdentifier: Self.identifier) {
            install(list, signature: signature)
            return
        }
        let encoded = await Self.encodedRules(exceptions: exceptions)
        do {
            guard let list = try await store.compileContentRuleList(forIdentifier: Self.identifier,
                                                                     encodedContentRuleList: encoded) else {
                lastError = "WebKit couldn’t prepare tracker protection. Try again."
                return
            }
            defaults?.set(signature, forKey: Self.signatureKey)
            install(list, signature: signature)
        } catch {
            lastError = "Tracker protection couldn’t be updated. " + error.localizedDescription
        }
    }

    @concurrent
    nonisolated private static func encodedRules(exceptions: [String]) async -> String {
        TrackerBlocklist.encodedRules(exceptions: exceptions)
    }

    private func install(_ list: WKContentRuleList, signature: String) {
        ruleList = list
        installedSignature = signature
        lastError = nil
        controllers.allObjects.forEach(apply)
    }

    private func apply(to controller: WKUserContentController) {
        // The controller also holds extension-provided rules. Only replace our own list.
        if let previous = installedLists.object(forKey: controller) {
            controller.remove(previous)
            installedLists.removeObject(forKey: controller)
        }
        if isEnabled, let ruleList {
            controller.add(ruleList)
            installedLists.setObject(ruleList, forKey: controller)
        }
    }
}
