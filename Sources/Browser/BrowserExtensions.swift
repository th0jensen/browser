import AppKit
import Observation
import UniformTypeIdentifiers
import WebKit

struct InstalledExtension: Codable, Identifiable {
    enum Kind: String, Codable, Sendable { case webExtension, contentBlocker }
    let id: UUID
    let name: String
    let kind: Kind
    let filename: String
    let needsNativeMessaging: Bool
    var isEnabled = false
    var sourceIdentifier: String?
    var sourceAppName: String?
    var sourceAppPath: String?
    var ruleCount: Int?
    var hasToolbarAction: Bool?
    var toolbarActionLabel: String?
    var toolbarIconIsTemplate: Bool?
}

/// Owns extension resources and one controller shared by every window, tab and restored web view.
@MainActor
@Observable
final class BrowserExtensions: NSObject {
    typealias ExtensionReader = @MainActor (URL) async throws -> WKWebExtension
    typealias RuleListCompiler = @MainActor (String, String) async throws -> WKContentRuleList?

    private final class AppliedRules {
        var revision: UInt64 = 0
        var lists: [UUID: WKContentRuleList] = [:]
    }

    private struct PendingLoad {
        let revision: UInt64
        let task: Task<Void, Error>
    }
    static let shared: BrowserExtensions = {
        BrowserExtensions(persistent: !BrowserProfile.isTesting)
    }()
    let controller: WKWebExtensionController
    private(set) var installed: [InstalledExtension] = []
    private(set) var errors: [UUID: String] = [:]
    var lastError: String?
    private(set) var isBusy = false
    @ObservationIgnored private var activeExtensionUpdates = 0
    private(set) var actionRevision = 0
    private(set) var activeRuleCounts: [UUID: Int] = [:]
    @ObservationIgnored private var blockerIcons: [String: NSImage] = [:]
    @ObservationIgnored private var toolbarIcons: [UUID: NSImage] = [:]
    @ObservationIgnored private var contexts: [UUID: WKWebExtensionContext] = [:]
    @ObservationIgnored private var ruleLists: [UUID: WKContentRuleList] = [:]
    @ObservationIgnored private var ruleListRevision: UInt64 = 0
    @ObservationIgnored private let appliedRules = NSMapTable<WKUserContentController, AppliedRules>.weakToStrongObjects()
    @ObservationIgnored private var pendingLoads: [UUID: PendingLoad] = [:]
    @ObservationIgnored private var loadRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private let extensionReader: ExtensionReader?
    @ObservationIgnored private let ruleListCompiler: RuleListCompiler
    @ObservationIgnored private var windows = NSHashTable<BrowserModel>.weakObjects()
    @ObservationIgnored private weak var focusedBrowser: BrowserModel?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var didPrepare = false
    var isPreparedForNavigation: Bool { didPrepare }
    @ObservationIgnored private let applicationDirectories: [URL]
    @ObservationIgnored private var popupPresentation: ChromePopoverPresentation?
    @ObservationIgnored private weak var popupBrowser: BrowserModel?
    @ObservationIgnored private weak var popupContext: WKWebExtensionContext?
    @ObservationIgnored private var extensionWindows: [UUID: ExtensionWindowController] = [:]

    init(directory: URL? = nil, persistent: Bool = true, applicationDirectories: [URL]? = nil,
         extensionReader: ExtensionReader? = nil, ruleListCompiler: RuleListCompiler? = nil) {
        self.directory = directory ?? BrowserProfile.directory.appending(path: "Extensions", directoryHint: .isDirectory)
        self.applicationDirectories = applicationDirectories ?? (persistent && !BrowserProfile.isTesting ? DiscoveredExtension.applicationDirectories : [])
        self.extensionReader = extensionReader
        self.ruleListCompiler = ruleListCompiler ?? { identifier, rules in
            try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier,
                                                                             encodedContentRuleList: rules)
        }
        let controllerConfiguration: WKWebExtensionController.Configuration = persistent ? .default() : .nonPersistent()
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = BrowserProfile.websiteDataStore
        BrowserTab.applyBrowserPreferences(to: webConfiguration)
        controllerConfiguration.webViewConfiguration = webConfiguration
        controllerConfiguration.defaultWebsiteDataStore = BrowserProfile.websiteDataStore
        controller = WKWebExtensionController(configuration: controllerConfiguration)
        super.init()
        controller.delegate = self
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let index = self.directory.appending(path: "extensions.json")
            if FileManager.default.fileExists(atPath: index.path) {
                installed = try JSONDecoder().decode([InstalledExtension].self, from: Data(contentsOf: index))
                for item in installed where item.kind == .webExtension {
                    let icon = NSImage(contentsOf: self.directory.appending(path: item.id.uuidString).appending(path: "toolbar-icon.png"))
                    icon?.isTemplate = item.toolbarIconIsTemplate ?? false
                    toolbarIcons[item.id] = icon
                }
            }
        } catch { lastError = error.localizedDescription }
        // No startup runtime work is necessary when there are no enabled extensions.
        didPrepare = !installed.contains(where: \.isEnabled)
    }

    func restore() async {
        if let restoration { await restoration.value; return }
        let task = Task { await restoreInstalled() }
        restoration = task
        await task.value
    }

    /// Restore known enabled extensions before navigating; application discovery can finish afterward.
    func prepare() async {
        guard !didPrepare else { return }
        if let preparation { await preparation.value; return }
        let task = Task {
            await restoreEnabled()
            didPrepare = true
        }
        preparation = task
        await task.value
    }

    private func restoreInstalled() async {
        beginExtensionUpdate()
        defer { endExtensionUpdate() }
        await prepare()
        await discoverApplications()
        await restoreEnabled()
    }

    private func restoreEnabled() async {
        let identifiers = installed.filter(\.isEnabled).map(\.id)
        for identifier in identifiers {
            // Each earlier load can suspend while Settings disables or removes later items.
            guard let item = installed.first(where: { $0.id == identifier && $0.isEnabled }) else { continue }
            do {
                try await load(item, askPermission: false)
                if installed.contains(where: { $0.id == identifier && $0.isEnabled }) { errors[identifier] = nil }
            } catch is CancellationError {
                // A newer user choice owns this extension's runtime and error state.
            } catch {
                if installed.contains(where: { $0.id == identifier && $0.isEnabled }) {
                    errors[identifier] = error.localizedDescription
                }
            }
        }
    }

    func refreshInstalledApplications() async {
        await restore()
        guard !isBusy else { return }
        beginExtensionUpdate()
        defer { endExtensionUpdate() }
        await discoverApplications()
        await restoreEnabled()
    }

    private func discoverApplications() async {
        let directories = applicationDirectories
        let candidates = await Task.detached(priority: .utility) { DiscoveredExtension.scan(directories) }.value
        for candidate in candidates {
            if let index = installed.firstIndex(where: { item in
                if item.sourceIdentifier == candidate.identifier { return true }
                guard item.sourceIdentifier == nil, item.kind == candidate.kind else { return false }
                if item.kind == .contentBlocker { return item.name == candidate.name }
                let resource = directory.appending(path: item.id.uuidString).appending(path: item.filename)
                return Bundle(url: resource)?.bundleIdentifier == candidate.identifier
            }) {
                do {
                    if candidate.kind == .contentBlocker {
                        let destination = directory.appending(path: installed[index].id.uuidString).appending(path: installed[index].filename)
                        let data = try Data(contentsOf: candidate.resource)
                        if (try? Data(contentsOf: destination)) != data {
                            try data.write(to: destination, options: .atomic)
                            try unload(installed[index])
                        }
                    }
                    installed[index].sourceIdentifier = candidate.identifier
                    installed[index].sourceAppName = candidate.appName
                    installed[index].sourceAppPath = candidate.appURL?.path
                    installed[index].ruleCount = candidate.ruleCount
                    try persist()
                } catch { lastError = "\(candidate.appName): \(error.localizedDescription)" }
                continue
            }
            do {
                switch candidate.kind {
                case .webExtension: try await importWebExtension(from: candidate.resource, discovery: candidate)
                case .contentBlocker: try await importBlocker(from: candidate.resource, name: candidate.name, discovery: candidate)
                }
            } catch { lastError = "\(candidate.appName): \(error.localizedDescription)" }
        }
        // A content blocker has no action of its own. Its companion's declared
        // toolbar icon can still represent the app without loading that companion.
        let blockerApps = Set(candidates.filter { $0.kind == .contentBlocker }.map(\.appName))
        for candidate in candidates where candidate.kind == .webExtension && blockerApps.contains(candidate.appName) {
            if let webExtension = try? await readWebExtension(at: candidate.resource),
               let icon = webExtension.actionIcon(for: CGSize(width: 16, height: 16)) {
                icon.isTemplate = true
                blockerIcons[candidate.appName] = icon
                actionRevision += 1
            }
        }
    }

    var toolbarExtensions: [InstalledExtension] {
        let _ = actionRevision
        var blockerGroups = Set<String>()
        return installed.filter {
            if $0.kind == .contentBlocker { return blockerGroups.insert(blockerGroup($0)).inserted }
            return $0.isEnabled && $0.hasToolbarAction != false
        }
    }

    func toolbarIcon(for item: InstalledExtension) -> NSImage? {
        if let icon = toolbarIcons[item.id] { return icon }
        if let path = item.sourceAppPath { return NSWorkspace.shared.icon(forFile: path) }
        return nil
    }

    private func cacheToolbarMetadata(_ item: InstalledExtension, extension webExtension: WKWebExtension,
                                      action: WKWebExtension.Action? = nil) {
        guard let index = installed.firstIndex(where: { $0.id == item.id }) else { return }
        let declared = ["action", "browser_action", "page_action"].contains { webExtension.manifest[$0] != nil }
        let label = action?.label.isEmpty == false ? action?.label : webExtension.displayActionLabel ?? item.name
        var changed = installed[index].hasToolbarAction != declared || installed[index].toolbarActionLabel != label
        installed[index].hasToolbarAction = declared
        installed[index].toolbarActionLabel = label
        if let icon = action?.icon(for: CGSize(width: 32, height: 32)) ?? webExtension.actionIcon(for: CGSize(width: 32, height: 32)),
           let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let file = directory.appending(path: item.id.uuidString).appending(path: "toolbar-icon.png")
            toolbarIcons[item.id] = icon
            if installed[index].toolbarIconIsTemplate != icon.isTemplate { installed[index].toolbarIconIsTemplate = icon.isTemplate; changed = true }
            if (try? Data(contentsOf: file)) != png { try? png.write(to: file, options: .atomic); changed = true }
        }
        if changed { try? persist() }
    }

    private func blockerGroup(_ item: InstalledExtension) -> String { item.sourceAppName ?? item.id.uuidString }
    func blockers(for item: InstalledExtension) -> [InstalledExtension] {
        installed.filter { $0.kind == .contentBlocker && blockerGroup($0) == blockerGroup(item) }
    }
    func toolbarName(for item: InstalledExtension) -> String { item.kind == .contentBlocker ? item.sourceAppName ?? item.name : item.name }
    func blockerIcon(for item: InstalledExtension) -> NSImage? {
        if let icon = blockerIcons[blockerGroup(item)] { return icon }
        guard let path = installed.first(where: { $0.id == item.id })?.sourceAppPath ?? item.sourceAppPath else { return nil }
        if let icon = blockerIcons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        blockerIcons[path] = icon
        return icon
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        if configuration.webExtensionController == nil { configuration.webExtensionController = controller }
        applyRules(to: configuration.userContentController)
    }

    func register(_ browser: BrowserModel) {
        guard !browser.isPrivate, !windows.contains(browser) else { return }
        windows.add(browser)
        controller.didOpenWindow(browser)
        browser.tabs.forEach {
            controller.didOpenTab($0)
            if let webView = $0.webView { updateRules(in: webView) }
        }
        focus(browser)
    }

    func unregister(_ browser: BrowserModel) {
        if popupBrowser === browser { closePopup() }
        guard windows.contains(browser) else { return }
        for tab in browser.tabs { controller.didCloseTab(tab, windowIsClosing: true) }
        controller.didCloseWindow(browser)
        windows.remove(browser)
        if focusedBrowser === browser { focusedBrowser = nil; controller.didFocusWindow(nil) }
    }

    func focus(_ browser: BrowserModel) {
        guard windows.contains(browser) else { return }
        focusedBrowser = browser
        controller.didFocusWindow(browser)
    }

    func didOpen(_ tab: BrowserTab) {
        guard let browser = tab.browser, windows.contains(browser) else { return }
        controller.didOpenTab(tab)
    }

    func didClose(_ tab: BrowserTab) {
        guard let browser = tab.browser, windows.contains(browser) else { return }
        controller.didCloseTab(tab)
    }

    func didActivate(_ tab: BrowserTab, previous: BrowserTab?) {
        guard let browser = tab.browser, windows.contains(browser) else { return }
        controller.didActivateTab(tab, previousActiveTab: previous)
    }

    func didChange(_ properties: WKWebExtension.TabChangedProperties, for tab: BrowserTab) {
        guard let browser = tab.browser, windows.contains(browser) else { return }
        controller.didChangeTabProperties(properties, for: tab)
    }

    func updateRules(in webView: WKWebView) {
        applyRules(to: webView.configuration.userContentController)
    }

    private func applyRules(to controller: WKUserContentController) {
        let applied: AppliedRules
        if let existing = appliedRules.object(forKey: controller) {
            guard existing.revision != ruleListRevision else { return }
            applied = existing
        } else {
            applied = AppliedRules()
            appliedRules.setObject(applied, forKey: controller)
        }
        // Keep other providers' lists intact and reconcile only changed extension lists.
        for (id, previous) in applied.lists where ruleLists[id] !== previous {
            controller.remove(previous)
        }
        for (id, current) in ruleLists where applied.lists[id] !== current {
            controller.add(current)
        }
        applied.lists = ruleLists
        applied.revision = ruleListRevision
    }

    private func updateAllRules() {
        // Configurations may be prepared before their window registers, and popups can share controllers.
        for controller in appliedRules.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
            applyRules(to: controller)
        }
        for browser in windows.allObjects {
            for tab in browser.tabs { if let webView = tab.webView { updateRules(in: webView) } }
        }
    }

    private func persist() throws {
        try JSONEncoder().encode(installed).write(to: directory.appending(path: "extensions.json"), options: .atomic)
    }

    private func beginExtensionUpdate() {
        activeExtensionUpdates += 1
        isBusy = true
    }

    private func endExtensionUpdate() {
        activeExtensionUpdates -= 1
        isBusy = activeExtensionUpdates > 0
    }

    func chooseImport() async {
        let panel = NSOpenPanel()
        panel.title = "Import Browser Extensions"
        panel.message = "Choose a Safari extension app (such as Dashlane or 1Blocker), a Web Extension folder/ZIP, or content-blocker JSON."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications")
        guard await panel.begin() == .OK else { return }
        beginExtensionUpdate()
        defer { endExtensionUpdate() }
        for url in panel.urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do { try await importResources(from: url) }
            catch { lastError = error.localizedDescription }
        }
    }

    func importResources(from url: URL) async throws {
        if url.pathExtension == "app" {
            let plugins = url.appending(path: "Contents/PlugIns")
            let bundles = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "appex" }
            var imported = 0
            var failures: [String] = []
            for bundleURL in bundles {
                guard let bundle = Bundle(url: bundleURL),
                      let spec = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                      let point = spec["NSExtensionPointIdentifier"] as? String else { continue }
                do {
                    if point == "com.apple.Safari.web-extension" {
                        try await importWebExtension(from: bundleURL)
                        imported += 1
                    } else if point == "com.apple.Safari.content-blocker",
                              let rules = DiscoveredExtension.blockerResource(in: bundle) {
                        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundleURL.deletingPathExtension().lastPathComponent
                        let appName = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
                        let discovery = DiscoveredExtension(identifier: bundle.bundleIdentifier ?? bundleURL.lastPathComponent,
                                                             appName: appName, name: name, kind: .contentBlocker,
                                                             resource: rules.url, appURL: url, ruleCount: rules.count)
                        try await importBlocker(from: rules.url, name: name, discovery: discovery)
                        imported += 1
                    }
                } catch { failures.append("\(bundleURL.lastPathComponent): \(error.localizedDescription)") }
            }
            if imported == 0 && failures.isEmpty {
                throw ExtensionFailure("No supported Web Extensions or bundled content-blocker JSON found in this app. Native Safari App Extensions require Safari.")
            }
            if !failures.isEmpty { throw ExtensionFailure(failures.joined(separator: "\n")) }
        } else if url.pathExtension == "json" {
            try await importBlocker(from: url, name: url.deletingPathExtension().lastPathComponent)
        } else {
            try await importWebExtension(from: url)
        }
    }

    private func readWebExtension(at url: URL) async throws -> WKWebExtension {
        if let extensionReader { return try await extensionReader(url) }
        if url.pathExtension == "appex", let bundle = Bundle(url: url) {
            return try await WKWebExtension(appExtensionBundle: bundle)
        }
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let resourceURL = isDirectory ? URL(filePath: url.path, directoryHint: .isDirectory) : url
        return try await WKWebExtension(resourceBaseURL: resourceURL)
    }

    private func importWebExtension(from url: URL, discovery: DiscoveredExtension? = nil) async throws {
        let webExtension = try await readWebExtension(at: url)
        guard webExtension.errors.isEmpty else { throw webExtension.errors[0] }
        let id = UUID()
        let filename = url.pathExtension == "appex" ? "extension.appex" : url.pathExtension == "zip" ? "extension.zip" : "resources"
        let item = InstalledExtension(id: id, name: webExtension.displayName ?? url.lastPathComponent,
                                      kind: .webExtension, filename: filename,
                                      needsNativeMessaging: webExtension.requestedPermissions.contains(.nativeMessaging),
                                      sourceIdentifier: discovery?.identifier, sourceAppName: discovery?.appName,
                                      sourceAppPath: discovery?.appURL?.path)
        try copyResource(url, for: item)
        cacheToolbarMetadata(item, extension: webExtension)
    }

    private func importBlocker(from url: URL, name: String, discovery: DiscoveredExtension? = nil) async throws {
        let id = UUID()
        let text = try String(contentsOf: url, encoding: .utf8)
        // Compile before adding it so invalid input never appears as a working blocker.
        let identifier = id.uuidString
        _ = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: text)
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
        let item = InstalledExtension(id: id, name: name, kind: .contentBlocker,
                                      filename: "rules.json", needsNativeMessaging: false,
                                      sourceIdentifier: discovery?.identifier, sourceAppName: discovery?.appName,
                                      sourceAppPath: discovery?.appURL?.path,
                                      ruleCount: DiscoveredExtension.usableRuleCount(Data(text.utf8)))
        try copyResource(url, for: item)
    }

    private func copyResource(_ source: URL, for item: InstalledExtension) throws {
        let folder = directory.appending(path: item.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: folder.appending(path: item.filename))
            installed.append(item)
            try persist()
        } catch {
            installed.removeAll { $0.id == item.id }
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func setEnabled(_ item: InstalledExtension, _ enabled: Bool) async {
        // Disabling must invalidate an in-flight restoration or permission request immediately.
        guard !enabled || !isBusy else { return }
        if enabled { beginExtensionUpdate() }
        defer { if enabled { endExtensionUpdate() } }
        do {
            if enabled { try await load(item, askPermission: true) }
            else { try unload(item) }
            guard let index = installed.firstIndex(where: { $0.id == item.id }) else { return }
            installed[index].isEnabled = enabled
            try persist()
            errors[item.id] = nil
        } catch is CancellationError {
            // A disable/remove superseded this request.
        } catch {
            if installed.contains(where: { $0.id == item.id }) { errors[item.id] = error.localizedDescription }
        }
    }

    func load(_ item: InstalledExtension, askPermission: Bool) async throws {
        guard installed.contains(where: { $0.id == item.id }) else { throw CancellationError() }
        if let pending = pendingLoads[item.id] { return try await pending.task.value }
        let revision = loadRevisions[item.id, default: 0]
        let task = Task { try await self.loadRuntime(item, askPermission: askPermission, revision: revision) }
        pendingLoads[item.id] = PendingLoad(revision: revision, task: task)
        defer {
            if pendingLoads[item.id]?.revision == revision { pendingLoads[item.id] = nil }
        }
        try await task.value
    }

    private func validateLoad(_ identifier: UUID, revision: UInt64) throws {
        try Task.checkCancellation()
        guard loadRevisions[identifier, default: 0] == revision,
              installed.contains(where: { $0.id == identifier }) else { throw CancellationError() }
    }

    private func invalidateLoad(_ identifier: UUID) {
        loadRevisions[identifier, default: 0] &+= 1
        pendingLoads.removeValue(forKey: identifier)?.task.cancel()
    }

    private func loadRuntime(_ item: InstalledExtension, askPermission: Bool, revision: UInt64) async throws {
        try validateLoad(item.id, revision: revision)
        let resource = directory.appending(path: item.id.uuidString).appending(path: item.filename)
        switch item.kind {
        case .webExtension:
            guard contexts[item.id] == nil else { return }
            if item.needsNativeMessaging {
                throw ExtensionFailure("This extension requires Safari’s native companion messaging, which Browser cannot host. Import its content-blocker JSON rules instead, when available.")
            }
            let webExtension = try await readWebExtension(at: resource)
            try validateLoad(item.id, revision: revision)
            if askPermission {
                let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
                let sites = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
                guard await confirm(name: item.name, detail: "Allow these extension permissions:\n"
                                    + (permissions + sites).joined(separator: "\n")) else {
                    throw ExtensionFailure("Extension access was not allowed.")
                }
                try validateLoad(item.id, revision: revision)
            }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = item.id.uuidString
            context.baseURL = URL(string: "webkit-extension://\(item.id.uuidString.lowercased())/")!
            for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in webExtension.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            contexts[item.id] = context
            cacheToolbarMetadata(item, extension: webExtension, action: context.action(for: nil))
            actionRevision += 1
        case .contentBlocker:
            guard ruleLists[item.id] == nil else { return }
            let text = try String(contentsOf: resource, encoding: .utf8)
            let count = DiscoveredExtension.usableRuleCount(Data(text.utf8)) ?? 0
            guard count > 0 else {
                throw ExtensionFailure("This category contains only a placeholder, with no usable blocking rules. Its Safari companion must provide the real list; it is not active in Browser.")
            }
            let list = try await ruleListCompiler(item.id.uuidString, text)
            try validateLoad(item.id, revision: revision)
            guard let list else { throw ExtensionFailure("WebKit did not compile the content-blocker rules.") }
            ruleLists[item.id] = list
            ruleListRevision &+= 1
            activeRuleCounts[item.id] = count
            actionRevision += 1
            updateAllRules()
        }
    }

    private func unload(_ item: InstalledExtension) throws {
        invalidateLoad(item.id)
        if let context = contexts[item.id] {
            if popupContext === context { closePopup() }
            try controller.unload(context)
            contexts[item.id] = nil
        }
        actionRevision += 1
        activeRuleCounts[item.id] = nil
        if ruleLists.removeValue(forKey: item.id) != nil {
            ruleListRevision &+= 1
            updateAllRules()
        }
    }

    func remove(_ item: InstalledExtension) {
        do {
            try unload(item)
            try FileManager.default.removeItem(at: directory.appending(path: item.id.uuidString))
            installed.removeAll { $0.id == item.id }
            errors[item.id] = nil
            try persist()
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: item.id.uuidString) { _ in }
        } catch { lastError = error.localizedDescription }
    }

    func context(for item: InstalledExtension) -> WKWebExtensionContext? { contexts[item.id] }

    func retainWindow(_ window: NSWindow, browser: BrowserModel) {
        let id = UUID()
        let owner = ExtensionWindowController(window: window)
        owner.onClose = { [weak self, weak browser] in
            if let browser { self?.unregister(browser) }
            self?.extensionWindows[id] = nil
        }
        window.delegate = owner
        extensionWindows[id] = owner
    }

    private func confirm(name: String, detail: String) async -> Bool {
        guard let window = NSApp.keyWindow ?? focusedBrowser?.window else { return false }
        let alert = NSAlert()
        alert.messageText = "Allow “\(name)”?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don’t Allow")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}

struct ExtensionFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension BrowserExtensions: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        windows.allObjects
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        focusedBrowser
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let browser = configuration.window as? BrowserModel ?? focusedBrowser ?? windows.allObjects.first else {
            throw ExtensionFailure("Open a browser window first.")
        }
        let previous = browser.activeTabID
        let isExtensionPage = configuration.url?.scheme == context.baseURL.scheme
            && configuration.url?.host == context.baseURL.host
        browser.addTab(configuration: isExtensionPage ? context.webViewConfiguration ?? BrowserTab.makeConfiguration()
                       : BrowserTab.makeConfiguration(), focusAddress: configuration.url == nil)
        guard let tab = browser.activeTab else { throw ExtensionFailure("Could not create a tab.") }
        tab.extensionOrigin = isExtensionPage ? context.baseURL : nil
        if let url = configuration.url { tab.load(url) }
        if configuration.index < browser.tabs.count { browser.moveTab(tab.id, to: configuration.index) }
        if !configuration.shouldBeActive { browser.activeTabID = previous }
        return tab
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                for context: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard !configuration.shouldBePrivate else { throw ExtensionFailure("Private extension windows are not supported yet.") }
        guard configuration.tabs.isEmpty else { throw ExtensionFailure("Moving existing tabs into a new window is not supported yet.") }
        let firstURL = configuration.tabURLs.first
        let isExtensionPage = firstURL?.scheme == context.baseURL.scheme && firstURL?.host == context.baseURL.host
        return openWindow(configuration: isExtensionPage ? context.webViewConfiguration ?? BrowserTab.makeConfiguration()
                          : BrowserTab.makeConfiguration(),
                          urls: configuration.tabURLs, frame: configuration.frame, focus: configuration.shouldBeFocused)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext) async throws {
        guard let url = context.optionsPageURL, let browser = focusedBrowser ?? windows.allObjects.first else { return }
        browser.addTab(configuration: context.webViewConfiguration ?? BrowserTab.makeConfiguration(), focusAddress: false)
        browser.activeTab?.extensionOrigin = context.baseURL
        browser.activeTab?.load(url)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<WKWebExtension.Permission>, Date?) {
        let allowed = await confirm(name: context.webExtension.displayName ?? "Extension",
                                    detail: "Additional permissions:\n" + permissions.map(\.rawValue).sorted().joined(separator: "\n"))
        return (allowed ? permissions.subtracting([.nativeMessaging]) : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<URL>, Date?) {
        let allowed = await confirm(name: context.webExtension.displayName ?? "Extension",
                                    detail: "Access to:\n" + urls.map(\.absoluteString).sorted().joined(separator: "\n"))
        return (allowed ? urls : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
                                in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext) async -> (Set<WKWebExtension.MatchPattern>, Date?) {
        let allowed = await confirm(name: context.webExtension.displayName ?? "Extension",
                                    detail: "Access to websites:\n" + patterns.map(\.string).sorted().joined(separator: "\n"))
        return (allowed ? patterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
                                forExtensionContext context: WKWebExtensionContext) { actionRevision += 1 }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
                                for context: WKWebExtensionContext) async throws {
        guard let tab = action.associatedTab as? BrowserTab ?? focusedBrowser?.activeTab,
              let browser = tab.browser, let view = tab.contentView.superview,
              let window = view.window, let popover = action.popupPopover else {
            throw ExtensionFailure("The extension popup needs a visible browser tab.")
        }
        closePopup()
        popupBrowser = browser
        popupContext = context
        let presentation = ChromePopoverPresentation(popover: popover, owner: window, controller: browser.chromeHover) { [weak self] closed in
            guard let self, popupPresentation === closed else { return }
            popupPresentation = nil
            popupBrowser = nil
            popupContext = nil
        }
        popupPresentation = presentation
        popover.behavior = .transient
        popover.show(relativeTo: NSRect(x: view.bounds.maxX - 40, y: view.bounds.maxY - 1, width: 1, height: 1),
                     of: view, preferredEdge: .minY)
        if !popover.isShown { presentation.finish() }
    }

    private func closePopup() {
        let presentation = popupPresentation
        popupPresentation = nil
        popupBrowser = nil
        popupContext = nil
        presentation?.close()
    }
}
