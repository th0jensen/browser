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
}

/// Owns extension resources and one controller shared by every window, tab and restored web view.
@MainActor
@Observable
final class BrowserExtensions: NSObject {
    static let shared: BrowserExtensions = {
        BrowserExtensions(persistent: !BrowserProfile.isTesting)
    }()
    let controller: WKWebExtensionController
    private(set) var installed: [InstalledExtension] = []
    private(set) var errors: [UUID: String] = [:]
    var lastError: String?
    private(set) var isBusy = false
    private(set) var actionRevision = 0
    @ObservationIgnored private var contexts: [UUID: WKWebExtensionContext] = [:]
    @ObservationIgnored private var ruleLists: [UUID: WKContentRuleList] = [:]
    @ObservationIgnored private var windows = NSHashTable<BrowserModel>.weakObjects()
    @ObservationIgnored private weak var focusedBrowser: BrowserModel?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private let applicationDirectories: [URL]
    @ObservationIgnored private var popupPresentation: ChromePopoverPresentation?
    @ObservationIgnored private weak var popupBrowser: BrowserModel?
    @ObservationIgnored private weak var popupContext: WKWebExtensionContext?
    @ObservationIgnored private var extensionWindows: [UUID: ExtensionWindowController] = [:]

    init(directory: URL? = nil, persistent: Bool = true, applicationDirectories: [URL]? = nil) {
        self.directory = directory ?? BrowserProfile.directory.appending(path: "Extensions", directoryHint: .isDirectory)
        self.applicationDirectories = applicationDirectories ?? (persistent && !BrowserProfile.isTesting ? DiscoveredExtension.applicationDirectories : [])
        let controllerConfiguration: WKWebExtensionController.Configuration = persistent ? .default() : .nonPersistent()
        let webConfiguration = WKWebViewConfiguration()
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
            }
        } catch { lastError = error.localizedDescription }
    }

    func restore() async {
        if let restoration { await restoration.value; return }
        let task = Task { await restoreInstalled() }
        restoration = task
        await task.value
    }

    private func restoreInstalled() async {
        isBusy = true
        defer { isBusy = false }
        await discoverApplications()
        await restoreEnabled()
    }

    private func restoreEnabled() async {
        for item in installed where item.isEnabled {
            do { try await load(item, askPermission: false); errors[item.id] = nil }
            catch { errors[item.id] = error.localizedDescription }
        }
    }

    func refreshInstalledApplications() async {
        await restore()
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
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
                if installed[index].sourceIdentifier != candidate.identifier || installed[index].sourceAppName != candidate.appName {
                    installed[index].sourceIdentifier = candidate.identifier
                    installed[index].sourceAppName = candidate.appName
                    do { try persist() } catch { lastError = error.localizedDescription }
                }
                continue
            }
            do {
                switch candidate.kind {
                case .webExtension: try await importWebExtension(from: candidate.resource, discovery: candidate)
                case .contentBlocker: try await importBlocker(from: candidate.resource, name: candidate.name, discovery: candidate)
                }
            } catch { lastError = "\(candidate.appName): \(error.localizedDescription)" }
        }
    }

    var toolbarExtensions: [InstalledExtension] {
        let _ = actionRevision
        return installed.filter { $0.isEnabled && $0.kind == .webExtension && contexts[$0.id]?.action(for: nil) != nil }
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        if configuration.webExtensionController == nil { configuration.webExtensionController = controller }
        for list in ruleLists.values { configuration.userContentController.add(list) }
    }

    func register(_ browser: BrowserModel) {
        guard !windows.contains(browser) else { return }
        windows.add(browser)
        controller.didOpenWindow(browser)
        browser.tabs.forEach { controller.didOpenTab($0) }
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
        for list in ruleLists.values { webView.configuration.userContentController.add(list) }
    }

    private func persist() throws {
        try JSONEncoder().encode(installed).write(to: directory.appending(path: "extensions.json"), options: .atomic)
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
        isBusy = true
        defer { isBusy = false }
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
                              let rules = bundle.url(forResource: "blockerList", withExtension: "json")
                                ?? bundle.url(forResource: "precompiledList", withExtension: "json") {
                        try await importBlocker(from: rules, name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                                              ?? bundleURL.deletingPathExtension().lastPathComponent)
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
                                      sourceIdentifier: discovery?.identifier, sourceAppName: discovery?.appName)
        try copyResource(url, for: item)
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
                                      sourceIdentifier: discovery?.identifier, sourceAppName: discovery?.appName)
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
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            if enabled { try await load(item, askPermission: true) }
            else { try unload(item) }
            guard let index = installed.firstIndex(where: { $0.id == item.id }) else { return }
            installed[index].isEnabled = enabled
            try persist()
            errors[item.id] = nil
        } catch { errors[item.id] = error.localizedDescription }
    }

    func load(_ item: InstalledExtension, askPermission: Bool) async throws {
        let resource = directory.appending(path: item.id.uuidString).appending(path: item.filename)
        switch item.kind {
        case .webExtension:
            guard contexts[item.id] == nil else { return }
            if item.needsNativeMessaging {
                throw ExtensionFailure("This extension requires Safari’s native companion messaging, which Browser cannot host. Import its content-blocker JSON rules instead, when available.")
            }
            let webExtension = try await readWebExtension(at: resource)
            if askPermission {
                let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
                let sites = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
                guard await confirm(name: item.name, detail: "Allow these extension permissions:\n"
                                    + (permissions + sites).joined(separator: "\n")) else {
                    throw ExtensionFailure("Extension access was not allowed.")
                }
            }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = item.id.uuidString
            context.baseURL = URL(string: "webkit-extension://\(item.id.uuidString.lowercased())/")!
            for permission in webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in webExtension.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: pattern) }
            try controller.load(context)
            contexts[item.id] = context
            actionRevision += 1
        case .contentBlocker:
            guard ruleLists[item.id] == nil else { return }
            let text = try String(contentsOf: resource, encoding: .utf8)
            let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: item.id.uuidString,
                                                                                       encodedContentRuleList: text)
            guard let list else { throw ExtensionFailure("WebKit did not compile the content-blocker rules.") }
            ruleLists[item.id] = list
            for browser in windows.allObjects {
                for tab in browser.tabs { if let webView = tab.webView { webView.configuration.userContentController.add(list) } }
            }
        }
    }

    private func unload(_ item: InstalledExtension) throws {
        if let context = contexts[item.id] {
            if popupContext === context { closePopup() }
            try controller.unload(context)
            contexts[item.id] = nil
        }
        actionRevision += 1
        if let list = ruleLists.removeValue(forKey: item.id) {
            for browser in windows.allObjects {
                for tab in browser.tabs { tab.webView?.configuration.userContentController.remove(list) }
            }
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
