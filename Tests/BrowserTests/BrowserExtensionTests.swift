import WebKit
import XCTest
import Observation
@testable import Browser

@MainActor
final class BrowserExtensionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func makeExtension(permissions: [String] = []) throws -> URL {
        let folder = directory.appending(path: "source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Test Extension", "description": "Browser integration fixture",
                                       "version": "1.0", "permissions": permissions]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appending(path: "manifest.json"))
        return folder
    }

    func testImportCopiesResourcesAndStaysDisabledAcrossLaunches() async throws {
        let source = try makeExtension()
        let storage = directory.appending(path: "installed")
        let store = BrowserExtensions(directory: storage, persistent: false)
        try await store.importResources(from: source)
        let item = try XCTUnwrap(store.installed.first)
        XCTAssertEqual(item.name, "Test Extension")
        XCTAssertFalse(item.isEnabled)
        XCTAssertNil(store.context(for: item))
        try FileManager.default.removeItem(at: source)
        let reopened = BrowserExtensions(directory: storage, persistent: false)
        await reopened.restore()
        XCTAssertEqual(reopened.installed.first?.id, item.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storage.appending(path: item.id.uuidString)
            .appending(path: item.filename).appending(path: "manifest.json").path))
        reopened.remove(item)
        XCTAssertTrue(reopened.installed.isEmpty)
        XCTAssertTrue(BrowserExtensions(directory: storage, persistent: false).installed.isEmpty)
    }

    func testNativeMessagingRequirementIsReportedWithoutEnabling() async throws {
        let source = try makeExtension(permissions: ["nativeMessaging"])
        let store = BrowserExtensions(directory: directory.appending(path: "installed"), persistent: false)
        try await store.importResources(from: source)
        let item = try XCTUnwrap(store.installed.first)
        XCTAssertTrue(item.needsNativeMessaging)
        await store.setEnabled(item, true)
        XCTAssertFalse(store.installed[0].isEnabled)
        XCTAssertNotNil(store.errors[item.id])
        XCTAssertNil(store.context(for: item))
    }

    func testPreviouslyEnabledExtensionLoadsAndSeesBrowserTabs() async throws {
        let source = try makeExtension()
        let storage = directory.appending(path: "installed")
        let importer = BrowserExtensions(directory: storage, persistent: false)
        try await importer.importResources(from: source)
        var item = try XCTUnwrap(importer.installed.first)
        item.isEnabled = true
        try JSONEncoder().encode([item]).write(to: storage.appending(path: "extensions.json"))

        let store = BrowserExtensions(directory: storage, persistent: false)
        await store.restore()
        let context = try XCTUnwrap(store.context(for: item))
        XCTAssertTrue(context.isLoaded)
        let browser = BrowserModel()
        store.register(browser)
        XCTAssertTrue(context.openWindows.contains { ($0 as? BrowserModel) === browser })
        let active = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(context.openTabs.contains { ($0 as? BrowserTab) === active })
        XCTAssertTrue((active.window(for: context) as? BrowserModel) === browser)
        store.unregister(browser)
        XCTAssertTrue(context.openWindows.isEmpty)
        XCTAssertTrue(context.openTabs.isEmpty)
        await store.setEnabled(item, false)
        XCTAssertFalse(context.isLoaded)
    }

    func testConcurrentRestorationPublishesToolbarActionsWithoutReactivation() async throws {
        let source = try makeExtension()
        let manifestURL = source.appending(path: "manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["action"] = ["default_title": "Test Extension"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let storage = directory.appending(path: "installed")
        let importer = BrowserExtensions(directory: storage, persistent: false)
        try await importer.importResources(from: source)
        var item = try XCTUnwrap(importer.installed.first)
        item.isEnabled = true
        try JSONEncoder().encode([item]).write(to: storage.appending(path: "extensions.json"))
        let store = BrowserExtensions(directory: storage, persistent: false)
        let changed = expectation(description: "Restoration invalidates the toolbar")
        withObservationTracking { _ = store.toolbarExtensions } onChange: { changed.fulfill() }
        async let first: Void = store.restore()
        async let second: Void = store.restore()
        _ = await (first, second)
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(store.toolbarExtensions.map(\.id), [item.id])
        XCTAssertTrue(store.context(for: item)?.isLoaded == true)
        XCTAssertTrue(store.installed[0].isEnabled)
    }

    func testNavigationPreparationLoadsKnownEnabledExtensionsBeforeApplicationDiscovery() async throws {
        let source = try makeExtension()
        let storage = directory.appending(path: "installed")
        let importer = BrowserExtensions(directory: storage, persistent: false)
        try await importer.importResources(from: source)
        var item = try XCTUnwrap(importer.installed.first)
        item.isEnabled = true
        try JSONEncoder().encode([item]).write(to: storage.appending(path: "extensions.json"))
        let fixture = try makeSafariApp()
        let store = BrowserExtensions(directory: storage, persistent: false, applicationDirectories: [fixture.applications])

        await store.prepare()

        XCTAssertTrue(store.context(for: item)?.isLoaded == true)
        XCTAssertEqual(store.installed.count, 1, "Navigation must not wait for scanning other applications")
        await store.restore()
        XCTAssertEqual(store.installed.count, 2)
        XCTAssertTrue(store.context(for: item)?.isLoaded == true)
    }

    func testConcurrentLoadsShareOneRuntimeRequestAndFailedLoadsCanRetry() async throws {
        let source = try makeExtension()
        let storage = directory.appending(path: "installed")
        let importer = BrowserExtensions(directory: storage, persistent: false)
        try await importer.importResources(from: source)
        let item = try XCTUnwrap(importer.installed.first)
        let gate = ExtensionLoadGate()
        defer { gate.resumeAll() }
        var reads = 0
        let store = BrowserExtensions(directory: storage, persistent: false, extensionReader: { url in
            reads += 1
            if reads == 1 { throw ExtensionFailure("Temporary read failure") }
            let webExtension = try await WKWebExtension(resourceBaseURL: URL(filePath: url.path, directoryHint: .isDirectory))
            await gate.pause()
            return webExtension
        })
        do {
            try await store.load(item, askPermission: false)
            XCTFail("The failed first attempt must be reported")
        } catch { XCTAssertEqual(error.localizedDescription, "Temporary read failure") }

        let first = Task { try await store.load(item, askPermission: false) }
        try await gate.waitUntil { gate.requests == 1 }
        let second = Task { try await store.load(item, askPermission: false) }
        await Task.yield()
        XCTAssertEqual(reads, 2, "Concurrent callers must join the retry instead of reading the extension twice")
        gate.resumeAll()
        try await first.value
        try await second.value
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(store.context(for: item)?.isLoaded == true)
        store.remove(item)
    }

    func testDisablingDuringNavigationPreparationCannotReactivateTheExtension() async throws {
        let source = try makeExtension()
        let storage = directory.appending(path: "installed")
        let importer = BrowserExtensions(directory: storage, persistent: false)
        try await importer.importResources(from: source)
        var item = try XCTUnwrap(importer.installed.first)
        item.isEnabled = true
        try JSONEncoder().encode([item]).write(to: storage.appending(path: "extensions.json"))
        let gate = ExtensionLoadGate()
        defer { gate.resumeAll() }
        let store = BrowserExtensions(directory: storage, persistent: false, extensionReader: { url in
            let webExtension = try await WKWebExtension(resourceBaseURL: URL(filePath: url.path, directoryHint: .isDirectory))
            await gate.pause()
            return webExtension
        })
        let preparation = Task { await store.prepare() }
        try await gate.waitUntil { gate.requests == 1 }
        await store.setEnabled(item, false)
        gate.resumeAll()
        await preparation.value

        XCTAssertFalse(try XCTUnwrap(store.installed.first).isEnabled)
        XCTAssertNil(store.context(for: item))
        XCTAssertNil(store.errors[item.id], "A superseded load must not publish a stale error")
        store.remove(item)
    }

    func testRemovingDuringRuleCompilationCannotRestoreDeletedBlockingRules() async throws {
        let source = directory.appending(path: "blocker.json")
        try #"[{"trigger":{"url-filter":"example.com"},"action":{"type":"block"}}]"#
            .write(to: source, atomically: true, encoding: .utf8)
        let storage = directory.appending(path: "installed")
        let importer = BrowserExtensions(directory: storage, persistent: false)
        try await importer.importResources(from: source)
        var item = try XCTUnwrap(importer.installed.first)
        item.isEnabled = true
        try JSONEncoder().encode([item]).write(to: storage.appending(path: "extensions.json"))
        let gate = ExtensionLoadGate()
        defer { gate.resumeAll() }
        let store = BrowserExtensions(directory: storage, persistent: false, ruleListCompiler: { identifier, rules in
            let list = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier,
                                                                                      encodedContentRuleList: rules)
            await gate.pause()
            return list
        })
        let preparation = Task { await store.prepare() }
        try await gate.waitUntil { gate.requests == 1 }
        store.remove(item)
        gate.resumeAll()
        await preparation.value

        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertNil(store.activeRuleCounts[item.id])
        XCTAssertNil(store.errors[item.id])
    }

    private func makeSafariApp() throws -> (applications: URL, plugin: URL) {
        let applications = directory.appending(path: "Applications")
        let app = applications.appending(path: "Fixture.app")
        let plugin = app.appending(path: "Contents/PlugIns/Fixture.appex")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plugins = try XCTUnwrap(Bundle(for: BrowserExtensionTests.self).builtInPlugInsURL)
        try FileManager.default.copyItem(at: plugins.appending(path: "BrowserExtensionFixture.appex"), to: plugin)
        let appInfo: [String: Any] = ["CFBundleIdentifier": "dev.browser.fixture", "CFBundlePackageType": "APPL", "CFBundleDisplayName": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        return (applications, plugin)
    }

    func testDiscoveryFindsInstalledSafariExtensionsAndKeepsThemDisabled() async throws {
        let fixture = try makeSafariApp()
        let store = BrowserExtensions(directory: directory.appending(path: "installed"), persistent: false,
                                      applicationDirectories: [fixture.applications])
        await store.restore()
        let item = try XCTUnwrap(store.installed.first, store.lastError ?? "No extension discovered")
        XCTAssertEqual(item.sourceIdentifier, "dev.browser.fixture.extension")
        XCTAssertEqual(item.sourceAppName, "Fixture")
        XCTAssertFalse(item.isEnabled)
        await store.refreshInstalledApplications()
        XCTAssertEqual(store.installed.count, 1)
        XCTAssertEqual(store.installed[0].id, item.id)
    }

    func testDiscoveryAdoptsImportedBundleWithoutLosingEnabledStateOrIdentity() async throws {
        let fixture = try makeSafariApp()
        let storage = directory.appending(path: "installed")
        let importer = BrowserExtensions(directory: storage, persistent: false)
        try await importer.importResources(from: fixture.plugin)
        var item = try XCTUnwrap(importer.installed.first)
        item.isEnabled = true
        try JSONEncoder().encode([item]).write(to: storage.appending(path: "extensions.json"))
        let store = BrowserExtensions(directory: storage, persistent: false, applicationDirectories: [fixture.applications])
        await store.restore()
        XCTAssertEqual(store.installed.count, 1)
        XCTAssertEqual(store.installed[0].id, item.id)
        XCTAssertTrue(store.installed[0].isEnabled)
        XCTAssertEqual(store.installed[0].sourceIdentifier, "dev.browser.fixture.extension")
        XCTAssertEqual(store.context(for: item)?.uniqueIdentifier, item.id.uuidString)
        XCTAssertEqual(store.toolbarExtensions.map(\.id), [item.id])
    }

    func testBlockerAffectsExistingAndNewViewsAndCanBeDisabled() async throws {
        let source = directory.appending(path: "blocker.json")
        try #"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".advert"}}]"#
            .write(to: source, atomically: true, encoding: .utf8)
        let store = BrowserExtensions(directory: directory.appending(path: "installed"), persistent: false)
        try await store.importResources(from: source)
        let item = try XCTUnwrap(store.installed.first)
        let browser = BrowserModel()
        store.register(browser)
        browser.activeTab?.restore()
        let existing = try XCTUnwrap(browser.activeTab?.webView)
        await store.setEnabled(item, true)
        XCTAssertNil(store.errors[item.id])

        let configuration = WKWebViewConfiguration()
        store.configure(configuration)
        XCTAssertTrue(configuration.webExtensionController === store.controller)
        let fresh = WKWebView(frame: .zero, configuration: configuration)
        try await assertDisplay("none", in: existing)
        try await assertDisplay("none", in: fresh)

        await store.setEnabled(item, false)
        try await assertDisplay("block", in: existing)
        store.unregister(browser)
    }

    func testInvalidBlockerIsNotInstalled() async throws {
        let source = directory.appending(path: "invalid.json")
        try "{}".write(to: source, atomically: true, encoding: .utf8)
        let store = BrowserExtensions(directory: directory.appending(path: "installed"), persistent: false)
        do {
            try await store.importResources(from: source)
            XCTFail("Invalid content-blocker JSON must fail compilation")
        } catch { XCTAssertTrue(store.installed.isEmpty) }
    }

    private func makeBlockerApp() throws -> (applications: URL, resources: URL) {
        let applications = directory.appending(path: "BlockerApplications")
        let app = applications.appending(path: "FixtureBlocker.app")
        let plugin = app.appending(path: "Contents/PlugIns/Ads.appex")
        let resources = plugin.appending(path: "Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let appInfo: [String: Any] = ["CFBundleIdentifier": "dev.browser.blocker", "CFBundlePackageType": "APPL", "CFBundleDisplayName": "Fixture Blocker"]
        let pluginInfo: [String: Any] = ["CFBundleIdentifier": "dev.browser.blocker.ads", "CFBundlePackageType": "XPC!", "CFBundleDisplayName": "Block Ads",
                                       "NSExtension": ["NSExtensionPointIdentifier": "com.apple.Safari.content-blocker"]]
        try PropertyListSerialization.data(fromPropertyList: appInfo, format: .xml, options: 0).write(to: app.appending(path: "Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: pluginInfo, format: .xml, options: 0).write(to: plugin.appending(path: "Contents/Info.plist"))
        try #"[{"trigger":{"url-filter":"webkit.svg"},"action":{"type":"block"}}]"#
            .write(to: resources.appending(path: "blockerList.json"), atomically: true, encoding: .utf8)
        return (applications, resources)
    }

    func testDiscoveryMigratesEnabledPlaceholderToRealBundledRules() async throws {
        let fixture = try makeBlockerApp()
        let storage = directory.appending(path: "installed")
        let original = BrowserExtensions(directory: storage, persistent: false, applicationDirectories: [fixture.applications])
        await original.restore()
        var item = try XCTUnwrap(original.installed.first)
        XCTAssertEqual(item.ruleCount, 0)
        item.isEnabled = true // Reproduce the previously persisted, falsely enabled placeholder.
        try JSONEncoder().encode([item]).write(to: storage.appending(path: "extensions.json"))
        try #"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".advert"}}]"#
            .write(to: fixture.resources.appending(path: "precompiledList.json"), atomically: true, encoding: .utf8)

        let restored = BrowserExtensions(directory: storage, persistent: false, applicationDirectories: [fixture.applications])
        await restored.restore()
        XCTAssertEqual(restored.installed.first?.id, item.id)
        XCTAssertEqual(restored.installed.first?.isEnabled, true)
        XCTAssertEqual(restored.activeRuleCounts[item.id], 1)
        XCTAssertNil(restored.errors[item.id])
        XCTAssertEqual(restored.toolbarExtensions.map { restored.toolbarName(for: $0) }, ["Fixture Blocker"])

        // Also covers registering an already-created page after rule restoration.
        let browser = BrowserModel()
        browser.activeTab?.restore()
        restored.register(browser)
        defer { restored.unregister(browser) }
        try await assertDisplay("none", in: XCTUnwrap(browser.activeTab?.webView))
        await restored.refreshInstalledApplications()
        XCTAssertEqual(restored.installed.count, 1)
        XCTAssertEqual(restored.installed[0].id, item.id)
        XCTAssertEqual(restored.activeRuleCounts[item.id], 1)
    }

    func testPlaceholderIsNeverReportedAsActiveBlocking() async throws {
        let fixture = try makeBlockerApp()
        let store = BrowserExtensions(directory: directory.appending(path: "installed"), persistent: false,
                                      applicationDirectories: [fixture.applications])
        await store.restore()
        let item = try XCTUnwrap(store.installed.first)
        await store.setEnabled(item, true)
        XCTAssertFalse(store.installed[0].isEnabled)
        XCTAssertNotNil(store.errors[item.id])
        XCTAssertNil(store.activeRuleCounts[item.id])
        XCTAssertEqual(store.toolbarExtensions.count, 1, "The blocker control remains available for customization")
    }

    func testVerificationTabReportsLoadCompletionAndBridgesMessagesToExtensionPage() async throws {
        let source = try makeExtension()
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Verification Bridge", "description": "Tests the client-check exchange", "version": "1.0",
            "permissions": ["tabs"], "host_permissions": ["https://example.com/*"],
            "content_scripts": [["matches": ["https://example.com/*"], "js": ["bridge.js"], "run_at": "document_end"]]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: source.appending(path: "manifest.json"))
        try "<html><head><script src='receiver.js'></script></head><body>Receiver</body></html>"
            .write(to: source.appending(path: "receiver.html"), atomically: true, encoding: .utf8)
        try """
        window.updates = [];
        chrome.tabs.onUpdated.addListener((id, change, tab) => {
            if (tab.url?.startsWith('https://example.com') && change.status) window.updates.push(change.status);
        });
        chrome.runtime.onMessage.addListener((message, sender, reply) => {
            if (message.type === 'verification-ping') {
                window.senderOrigin = sender.origin;
                window.hasSenderTab = typeof sender.tab?.id === 'number';
                reply('verification-pong');
            }
        });
        document.title = 'Receiver ready';
        """.write(to: source.appending(path: "receiver.js"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.sendMessage({type: 'verification-ping'}, reply => {
            document.documentElement.setAttribute('data-bridge-reply', reply || 'missing');
        });
        """.write(to: source.appending(path: "bridge.js"), atomically: true, encoding: .utf8)

        let store = BrowserExtensions.shared
        try await store.importResources(from: source)
        let item = try XCTUnwrap(store.installed.last)
        defer { store.remove(item) }
        try await store.load(item, askPermission: false)
        let context = try XCTUnwrap(store.context(for: item))
        let browser = BrowserModel(configuration: try XCTUnwrap(context.webViewConfiguration))
        store.register(browser)
        defer { store.unregister(browser) }
        let receiver = try XCTUnwrap(browser.activeTab)
        receiver.load(context.baseURL.appending(path: "receiver.html"))
        try await waitUntil { receiver.pageTitle == "Receiver ready" }

        browser.addTab()
        let verifier = try XCTUnwrap(browser.activeTab)
        verifier.isNewTab = false
        verifier.restore()
        let webView = try XCTUnwrap(verifier.webView)
        webView.loadHTMLString("<html><body>Verification fixture</body></html>", baseURL: URL(string: "https://example.com/")!)
        var reply: String?
        for _ in 0..<100 {
            reply = try? await webView.evaluateJavaScript("document.documentElement.getAttribute('data-bridge-reply')") as? String
            if reply == "verification-pong" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(reply, "verification-pong")
        let receiverView = try XCTUnwrap(receiver.webView)
        let origin = try await receiverView.evaluateJavaScript("window.senderOrigin") as? String
        let hasTab = try await receiverView.evaluateJavaScript("window.hasSenderTab") as? Bool
        let complete = try await receiverView.evaluateJavaScript("window.updates.includes('complete')") as? Bool
        XCTAssertEqual(origin, "https://example.com")
        XCTAssertEqual(hasTab, true)
        XCTAssertEqual(complete, true)

        receiver.load(URL(string: "data:text/html,<title>Outside</title>")!)
        try await waitUntil { receiver.pageTitle == "Outside" && !receiver.isLoading }
        XCTAssertNil(receiver.extensionOrigin)
        receiver.load(context.baseURL.appending(path: "receiver.html"))
        try await waitUntil { receiver.pageTitle == "Receiver ready" && !receiver.isLoading }
        XCTAssertEqual(receiver.extensionOrigin, context.baseURL)
        XCTAssertEqual(context.baseURL.host, item.id.uuidString.lowercased())
        receiver.suspend()
        receiver.restore()
        var restoredTitle: String?
        for _ in 0..<100 {
            restoredTitle = try? await receiver.webView?.evaluateJavaScript("document.title") as? String
            if restoredTitle == "Receiver ready" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(restoredTitle, "Receiver ready")

        let priorWindows = context.openWindows.compactMap { $0 as? BrowserModel }
        _ = try await receiver.webView?.evaluateJavaScript("window.verificationPopup = window.open('about:blank'); 0")
        try await waitUntil { context.openWindows.count > priorWindows.count }
        let popupBrowser = try XCTUnwrap(context.openWindows.compactMap { $0 as? BrowserModel }
            .first { candidate in !priorWindows.contains { $0 === candidate } })
        defer { popupBrowser.window?.close() }
        let popupView = try XCTUnwrap(popupBrowser.activeTab?.webView)
        let popupHasOpener = try await popupView.evaluateJavaScript("window.opener !== null") as? Bool
        XCTAssertEqual(popupHasOpener, true)
        popupBrowser.activeTab?.load(URL(string: "data:text/html,<title>PopupVerifier</title>")!)
        var popupTitle: String?
        for _ in 0..<100 {
            popupTitle = try? await popupBrowser.activeTab?.webView?.evaluateJavaScript("document.title") as? String
            if popupTitle == "PopupVerifier" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(popupTitle, "PopupVerifier")
        popupBrowser.window?.close()
        try await waitUntil { !context.openWindows.contains { ($0 as? BrowserModel) === popupBrowser } }
    }

    private func assertDisplay(_ expected: String, in webView: WKWebView) async throws {
        webView.loadHTMLString("<html><body><div class='advert'>Advertisement</div></body></html>",
                              baseURL: URL(string: "https://example.com")!)
        for _ in 0..<100 {
            let display = try? await webView.evaluateJavaScript("getComputedStyle(document.querySelector('.advert')).display") as? String
            if display == expected { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Expected advertisement display to be \(expected)")
    }
}

@MainActor
private final class ExtensionLoadGate {
    private(set) var requests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "ExtensionLoadGate", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a suspended extension load"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func pause() async {
        requests += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeAll() {
        isOpen = true
        let current = waiters
        waiters = []
        current.forEach { $0.resume() }
    }
}
