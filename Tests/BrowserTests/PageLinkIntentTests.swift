import AppKit
import WebKit
import XCTest
@testable import Browser

@MainActor
final class PageLinkIntentTests: XCTestCase {
    func testShiftOnlyLeftClickIsExplicitAndDoesNotNeedAutomaticPeek() {
        for automatic in [false, true] {
            XCTAssertEqual(intent(.shift, automatic: automatic), .peek)
            XCTAssertEqual(intent([.shift, .capsLock], automatic: automatic), .peek)
        }
        XCTAssertEqual(intent(.shift, button: 0), .standard, "No mouse click")
        XCTAssertEqual(intent(.shift, button: 2), .standard, "Right click")
    }

    func testCommandAndMiddleClickTakePriority() {
        for keys: NSEvent.ModifierFlags in [.command, [.command, .shift], [.command, .option]] {
            XCTAssertEqual(intent(keys), .backgroundTab)
        }
        for keys: NSEvent.ModifierFlags in [[], .shift, [.shift, .control]] {
            XCTAssertEqual(intent(keys, button: 4), .backgroundTab)
        }
        XCTAssertEqual(intent([.command, .shift], canPeek: false), .backgroundTab)
    }

    func testOtherModifiersAndNonLinkActionsStayWithWebKit() {
        for keys: NSEvent.ModifierFlags in [.control, .option, [.shift, .control], [.shift, .option], [.shift, .option, .control]] {
            XCTAssertEqual(intent(keys, automatic: true), .standard)
        }
        XCTAssertEqual(intent(.shift, canPeek: false), .standard)
        XCTAssertEqual(PageLinkIntent.decide(isLinkActivated: false, modifiers: [.shift, .command],
                                            buttonMask: 4, canPeek: true, automaticPeek: true), .standard)
        XCTAssertEqual(intent([], automatic: true), .peek)
        XCTAssertEqual(intent([], automatic: false), .standard)
    }

    func testShiftSameFrameOpensOnlyPeekInTheSourceProfile() async throws {
        for isPrivate in [false, true] {
            let browser = BrowserModel(isPrivate: isPrivate)
            defer { browser.dismissPeek() }
            let (source, view, delegate) = try source(in: browser)
            let action = LinkAction(target: try await frame(in: view), modifiers: .shift)
            let policy = await delegate.webView(view, decidePolicyFor: action)
            XCTAssertEqual(policy, .cancel)
            let peek = try XCTUnwrap(browser.peek)
            XCTAssertEqual(peek.openerID, source.id)
            XCTAssertEqual(browser.activeTabID, source.id)
            XCTAssertEqual(browser.tabs.count, 1)
            XCTAssertFalse(peek.tab.isPopUp)
            XCTAssertTrue(peek.tab.webView?.configuration.websiteDataStore === browser.websiteDataStore)
            if isPrivate { XCTAssertFalse(browser.websiteDataStore.isPersistent) }
        }
    }

    func testWebKitLinkRoutingWithInjectedShiftClickKeepsSourceStateInBothFramePaths() async throws {
        for blank in [false, true] {
            let browser = BrowserModel(isPrivate: true)
            defer { browser.dismissPeek() }
            let (source, view, delegate) = try source(in: browser)
            _ = try await frame(in: view)
            let original = view.url
            // DOM clicks do not supply trusted native modifier metadata. Inject
            // that metadata while WebKit supplies the real frames and popup configuration.
            let bridge = ShiftClickBridge(delegate: delegate)
            view.navigationDelegate = bridge
            view.uiDelegate = bridge
            try await view.evaluateJavaScript("""
                document.body.innerHTML = '<a id="link" href="https://peek-test.invalid/page" \(blank ? "target=\"_blank\"" : "")>Link</a>';
                window.keepMe = 42;
                document.getElementById('link').click();
                """)
            for _ in 0..<200 where browser.peek == nil { try await Task.sleep(for: .milliseconds(10)) }
            let peek = try XCTUnwrap(browser.peek)
            XCTAssertEqual(peek.openerID, source.id)
            XCTAssertEqual(browser.tabs.count, 1)
            XCTAssertEqual(view.url, original)
            XCTAssertEqual(peek.tab.isPopUp, blank)
            XCTAssertEqual(bridge.windowRequests, blank ? 1 : 0)
            let retained = try await view.evaluateJavaScript("window.keepMe") as? Int
            XCTAssertEqual(retained, 42)
        }
    }

    func testShiftNewWindowDefersToUIAndKeepsSuppliedConfigurationWithoutLoadingTwice() async throws {
        for isPrivate in [false, true] {
            let browser = BrowserModel(isPrivate: isPrivate)
            defer { browser.dismissPeek() }
            let (source, view, delegate) = try source(in: browser)
            let action = LinkAction(modifiers: .shift)
            let policy = await delegate.webView(view, decidePolicyFor: action)
            XCTAssertEqual(policy, .allow)
            XCTAssertNil(browser.peek)
            XCTAssertEqual(browser.tabs.count, 1)

            let configuration = browser.makeConfiguration()
            let controller = configuration.userContentController
            let returned = try XCTUnwrap(delegate.webView(view, createWebViewWith: configuration,
                                                         for: action, windowFeatures: WKWindowFeatures()))
            let peek = try XCTUnwrap(browser.peek)
            XCTAssertTrue(returned === peek.tab.webView)
            XCTAssertTrue(returned.configuration.userContentController === controller)
            XCTAssertTrue(returned.configuration.websiteDataStore === browser.websiteDataStore)
            XCTAssertTrue(peek.tab.isPopUp)
            XCTAssertEqual(peek.openerID, source.id)
            XCTAssertEqual(browser.tabs.count, 1)
            XCTAssertNil(returned.url, "WebKit, not the delegate, loads the new-window request")
            XCTAssertFalse(returned.isLoading)
            browser.expandPeek()
            XCTAssertTrue(browser.activeTab === peek.tab)
            XCTAssertTrue(browser.activeTab?.webView === returned)
        }
    }

    func testCommandShiftAndMiddleNewWindowsOpenOneBackgroundTabWithOpenerConfiguration() async throws {
        for (keys, button): (NSEvent.ModifierFlags, Int) in [([.command, .shift], 1), (.shift, 4)] {
            let browser = BrowserModel(isPrivate: true)
            let (source, view, delegate) = try source(in: browser)
            let action = LinkAction(modifiers: keys, button: button)
            let policy = await delegate.webView(view, decidePolicyFor: action)
            XCTAssertEqual(policy, .allow)
            XCTAssertEqual(browser.tabs.count, 1)
            let configuration = browser.makeConfiguration()
            let returned = try XCTUnwrap(delegate.webView(view, createWebViewWith: configuration,
                                                         for: action, windowFeatures: WKWindowFeatures()))
            XCTAssertNil(browser.peek)
            XCTAssertEqual(browser.tabs.count, 2)
            XCTAssertEqual(browser.activeTabID, source.id)
            let child = try XCTUnwrap(browser.tab(for: returned))
            XCTAssertEqual(child.openerID, source.id)
            XCTAssertTrue(child.isPopUp)
            XCTAssertTrue(returned.configuration.userContentController === configuration.userContentController)
            XCTAssertTrue(returned.configuration.websiteDataStore === browser.websiteDataStore)
            XCTAssertNil(returned.url)
        }
    }

    func testExtensionNewWindowModifierClicksKeepOneBackgroundTabAndExtensionConfiguration() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Modifier routing fixture",
                                       "description": "Tests extension modifier-click routing", "version": "1.0", "permissions": []]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appending(path: "manifest.json"))
        try "<title>Extension source ready</title>".write(to: directory.appending(path: "source.html"), atomically: true, encoding: .utf8)
        let store = BrowserExtensions.shared
        try await store.importResources(from: directory)
        let item = try XCTUnwrap(store.installed.last)
        defer { store.remove(item) }
        try await store.load(item, askPermission: false)
        let context = try XCTUnwrap(store.context(for: item))
        let browser = BrowserModel(configuration: try XCTUnwrap(context.webViewConfiguration))
        store.register(browser)
        defer { browser.tabs.forEach { $0.stopLoading() }; store.unregister(browser) }
        let source = try XCTUnwrap(browser.activeTab)
        source.load(context.baseURL.appending(path: "source.html"))
        for _ in 0..<200 where source.pageTitle != "Extension source ready" || source.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(source.pageTitle, "Extension source ready")
        let view = try XCTUnwrap(source.webView)
        let delegate = try XCTUnwrap(view.navigationDelegate as? PageDelegate)
        XCTAssertEqual(view.url?.scheme, "webkit-extension")
        XCTAssertEqual(source.extensionOrigin, context.baseURL)
        XCTAssertFalse(browser.canPeek(URL(string: "https://example.com/page")!, from: source))
        let windowCount = context.openWindows.count

        for destination in [context.baseURL.appending(path: "source.html"), URL(string: "https://example.com/page")!] {
            for (keys, button): (NSEvent.ModifierFlags, Int) in [(.command, 1), ([.command, .shift], 1), ([], 4), (.shift, 4)] {
                let action = LinkAction(url: destination, modifiers: keys, button: button)
                XCTAssertNil(action.targetFrame)
                let policy = await delegate.webView(view, decidePolicyFor: action)
                XCTAssertEqual(policy, .allow)
                XCTAssertEqual(browser.tabs.count, 1)
                let configuration = try XCTUnwrap(context.webViewConfiguration)
                let returned = try XCTUnwrap(delegate.webView(view, createWebViewWith: configuration,
                                                             for: action, windowFeatures: WKWindowFeatures()))
                let child = try XCTUnwrap(browser.tab(for: returned))
                XCTAssertEqual(browser.tabs.count, 2)
                XCTAssertEqual(context.openWindows.count, windowCount)
                XCTAssertEqual(browser.activeTabID, source.id)
                XCTAssertEqual(child.openerID, source.id)
                XCTAssertEqual(child.extensionOrigin, context.baseURL)
                XCTAssertTrue(child.isPopUp)
                XCTAssertTrue(returned.configuration.userContentController === configuration.userContentController)
                XCTAssertTrue(returned.configuration.websiteDataStore === view.configuration.websiteDataStore)
                XCTAssertTrue(returned.configuration.webExtensionController === configuration.webExtensionController)
                XCTAssertNil(returned.url, "WebKit loads the returned view; the callback must not load it again")
                XCTAssertFalse(returned.isLoading)
                XCTAssertNil(browser.peek)
                browser.closeTab(child.id)
            }
        }
    }

    func testShiftDownloadKeepsDownloadPolicyWithoutOpeningAPeekOrTab() async throws {
        let browser = BrowserModel(isPrivate: true)
        let (_, view, delegate) = try source(in: browser)
        let main = try await frame(in: view)
        for target: WKFrameInfo? in [main, nil] {
            let action = LinkAction(target: target, modifiers: .shift, download: true)
            let policy = await delegate.webView(view, decidePolicyFor: action)
            XCTAssertEqual(policy, .download)
            XCTAssertNil(browser.peek)
            XCTAssertEqual(browser.tabs.count, 1)
        }
    }

    func testUntrustedDOMShiftClickDoesNotRequestExplicitPeek() async throws {
        let browser = BrowserModel(isPrivate: true)
        let (_, view, delegate) = try source(in: browser)
        _ = try await frame(in: view)
        let originalURL = view.url
        let probe = DOMClickProbe(delegate: delegate)
        view.navigationDelegate = probe
        // No ShiftClickBridge: production sees WebKit's unmodified action metadata.
        let trusted = try await view.evaluateJavaScript("""
            document.body.innerHTML = '<a id="link" href="https://untrusted-click.invalid/page">Link</a>';
            const event = new MouseEvent('click', {
                bubbles: true, cancelable: true, view: window, shiftKey: true, button: 0, buttons: 1
            });
            document.getElementById('link').dispatchEvent(event);
            event.isTrusted;
            """) as? Bool
        XCTAssertEqual(trusted, false)
        for _ in 0..<200 where probe.linkPolicy == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(probe.linkPolicy, .allow)
        XCTAssertNil(browser.peek)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(view.url, originalURL)
    }

    func testMainFrameCommandShiftAndMiddleStillOpenBackgroundTabs() async throws {
        for (keys, button): (NSEvent.ModifierFlags, Int) in [([.command, .shift], 1), (.shift, 4)] {
            let browser = BrowserModel(isPrivate: true)
            let (source, view, delegate) = try source(in: browser)
            let policy = await delegate.webView(view, decidePolicyFor: LinkAction(target: try await frame(in: view), modifiers: keys, button: button))
            XCTAssertEqual(policy, .cancel)
            XCTAssertNil(browser.peek)
            XCTAssertEqual(browser.tabs.count, 2)
            XCTAssertEqual(browser.activeTabID, source.id)
            browser.tabs.forEach { $0.stopLoading() }
        }
    }

    func testNonWebTargetsAndExtensionWindowsDoNotPeekOnEitherPath() async throws {
        let browser = BrowserModel(isPrivate: true)
        let (_, view, delegate) = try source(in: browser)
        for address in ["file:///tmp/test.html", "mailto:test@example.com", "javascript:void(0)",
                        "data:text/html,test", "about:blank", "webkit-extension://test/page", "https:opaque"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertFalse(browser.canPeek(url, from: try XCTUnwrap(browser.activeTab)), address)
            try await assertNoPeek(for: url, browser: browser, view: view, delegate: delegate)
        }
        browser.isExtensionWindow = true
        try await assertNoPeek(for: URL(string: "https://example.com/page")!, browser: browser, view: view, delegate: delegate)
    }

    func testNoActivatedLinkAndSubframeTargetsDoNotPeek() async throws {
        let browser = BrowserModel(isPrivate: true)
        let (_, view, delegate) = try source(in: browser)
        for type: WKNavigationType in [.other, .formSubmitted, .backForward, .reload] {
            let action = LinkAction(target: try await frame(in: view), modifiers: .shift, type: type)
            let policy = await delegate.webView(view, decidePolicyFor: action)
            XCTAssertEqual(policy, .allow)
            XCTAssertNil(browser.peek)
            let child = delegate.webView(view, createWebViewWith: browser.makeConfiguration(),
                                         for: LinkAction(modifiers: .shift, type: type), windowFeatures: WKWindowFeatures())
            XCTAssertNotNil(child)
            XCTAssertNil(browser.peek)
            if let child, let tab = browser.tab(for: child) { browser.closeTab(tab.id) }
        }
        let policy = await delegate.webView(view, decidePolicyFor: LinkAction(target: try await frame(in: view, main: false), modifiers: .shift))
        XCTAssertEqual(policy, .allow)
        XCTAssertNil(browser.peek)
    }

    func testPeekRejectsInactiveForeignClosedAndExtensionSources() throws {
        let browser = BrowserModel(isPrivate: true)
        let (original, _, _) = try source(in: browser)
        let url = URL(string: "https://example.com/page")!
        XCTAssertTrue(browser.canPeek(url, from: original))
        browser.addTab(focusAddress: false)
        XCTAssertFalse(browser.canPeek(url, from: original))
        let active = try XCTUnwrap(browser.activeTab)
        let other = BrowserModel(isPrivate: true)
        XCTAssertFalse(other.canPeek(url, from: active))
        active.extensionOrigin = URL(string: "webkit-extension://test/")
        XCTAssertFalse(browser.canPeek(url, from: active))
        active.extensionOrigin = nil
        browser.windowDidClose()
        XCTAssertFalse(browser.canPeek(url, from: active))
    }

    func testInactiveAndMismatchedLiveViewsCannotTriggerExplicitPeek() async throws {
        let browser = BrowserModel(isPrivate: true)
        let (_, view, delegate) = try source(in: browser)
        browser.addTab(focusAddress: false)
        let action = LinkAction(target: try await frame(in: view), modifiers: .shift)
        let policy = await delegate.webView(view, decidePolicyFor: action)
        XCTAssertEqual(policy, .allow)
        XCTAssertNil(browser.peek)
        let wrongView = WKWebView(frame: .zero, configuration: browser.makeConfiguration())
        let wrongPolicy = await delegate.webView(wrongView, decidePolicyFor: action)
        XCTAssertEqual(wrongPolicy, .cancel)
        XCTAssertNil(browser.peek)
        XCTAssertNil(delegate.webView(wrongView, createWebViewWith: browser.makeConfiguration(),
                                      for: LinkAction(modifiers: .shift), windowFeatures: WKWindowFeatures()))
    }

    func testAutomaticSavedTabPeekDefaultsToCrossSiteAndExplicitPeekIgnoresThatPreference() throws {
        let previous = UserDefaults.standard.object(forKey: PinnedNavigation.peekEnabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PinnedNavigation.peekEnabledKey) }
        UserDefaults.standard.removeObject(forKey: PinnedNavigation.peekEnabledKey)
        let browser = BrowserModel(isPrivate: true)
        let (tab, _, _) = try source(in: browser)
        let home = URL(string: "https://example.com/home")!
        let external = URL(string: "https://elsewhere.invalid/page")!
        XCTAssertFalse(browser.shouldPeek(external, from: tab))
        let saved = try browser.folders.savePage(url: home, title: "Home", in: nil)
        tab.folderPageID = saved.id
        XCTAssertTrue(browser.shouldPeek(external, from: tab))
        XCTAssertFalse(browser.shouldPeek(URL(string: "https://docs.example.com/page")!, from: tab))
        UserDefaults.standard.set(false, forKey: PinnedNavigation.peekEnabledKey)
        XCTAssertFalse(browser.shouldPeek(external, from: tab))
        XCTAssertTrue(browser.canPeek(home, from: tab))
        XCTAssertEqual(intent(.shift, canPeek: browser.canPeek(home, from: tab), automatic: browser.shouldPeek(home, from: tab)), .peek)
    }

    private func intent(_ keys: NSEvent.ModifierFlags, button: Int = 1, canPeek: Bool = true,
                        automatic: Bool = false) -> PageLinkIntent {
        PageLinkIntent.decide(isLinkActivated: true, modifiers: keys, buttonMask: button,
                              canPeek: canPeek, automaticPeek: automatic)
    }

    private func source(in browser: BrowserModel) throws -> (BrowserTab, WKWebView, PageDelegate) {
        let tab = try XCTUnwrap(browser.activeTab)
        tab.restore()
        let view = try XCTUnwrap(tab.webView)
        return (tab, view, try XCTUnwrap(view.navigationDelegate as? PageDelegate))
    }

    // WKFrameInfo needs WebKit's backing frame data, including when it is released.
    // Capture a real frame instead of constructing an invalid test subclass.
    private func frame(in view: WKWebView, main: Bool = true) async throws -> WKFrameInfo {
        let original = view.navigationDelegate
        let capture = FrameCapture()
        view.navigationDelegate = capture
        defer { view.navigationDelegate = original }
        view.loadHTMLString("<iframe srcdoc='<p>Frame</p>'></iframe>", baseURL: URL(string: "https://source.invalid"))
        for _ in 0..<200 {
            if capture.finished, let frame = main ? capture.main : capture.subframe { return frame }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(main ? capture.main : capture.subframe)
    }

    private func assertNoPeek(for url: URL, browser: BrowserModel, view: WKWebView, delegate: PageDelegate) async throws {
        let policy = await delegate.webView(view, decidePolicyFor: LinkAction(url: url, target: try await frame(in: view), modifiers: .shift))
        XCTAssertEqual(policy, .allow, url.absoluteString)
        let child = delegate.webView(view, createWebViewWith: browser.makeConfiguration(),
                                     for: LinkAction(url: url, modifiers: .shift), windowFeatures: WKWindowFeatures())
        XCTAssertNotNil(child)
        XCTAssertNil(browser.peek, url.absoluteString)
        if let child, let tab = browser.tab(for: child) { browser.closeTab(tab.id) }
    }
}

@MainActor
private final class FrameCapture: NSObject, WKNavigationDelegate {
    var main: WKFrameInfo?
    var subframe: WKFrameInfo?
    var finished = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let frame = action.targetFrame {
            if frame.isMainFrame { main = frame } else { subframe = frame }
        }
        return .allow
    }
}

@MainActor
private final class DOMClickProbe: NSObject, WKNavigationDelegate {
    let delegate: PageDelegate
    var linkPolicy: WKNavigationActionPolicy?

    init(delegate: PageDelegate) { self.delegate = delegate }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let policy = await delegate.webView(webView, decidePolicyFor: action)
        if action.navigationType == .linkActivated {
            linkPolicy = policy
            // Record production's decision, but do not load a remote test URL.
            return .cancel
        }
        return policy
    }
}

@MainActor
private final class ShiftClickBridge: NSObject, WKNavigationDelegate, WKUIDelegate {
    let delegate: PageDelegate
    var windowRequests = 0

    init(delegate: PageDelegate) { self.delegate = delegate }

    private func shifted(_ action: WKNavigationAction) -> WKNavigationAction {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return action }
        return LinkAction(url: url, target: action.targetFrame, modifiers: .shift)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        await delegate.webView(webView, decidePolicyFor: shifted(action))
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        windowRequests += 1
        return delegate.webView(webView, createWebViewWith: configuration, for: shifted(action), windowFeatures: windowFeatures)
    }
}

@MainActor
private final class LinkAction: WKNavigationAction {
    private let destination: URLRequest
    private let target: WKFrameInfo?
    private let keys: NSEvent.ModifierFlags
    private let button: Int
    private let type: WKNavigationType
    private let download: Bool

    init(url: URL = URL(string: "https://example.com/page")!, target: WKFrameInfo? = nil,
         modifiers: NSEvent.ModifierFlags, button: Int = 1, type: WKNavigationType = .linkActivated,
         download: Bool = false) {
        destination = URLRequest(url: url)
        self.target = target
        keys = modifiers
        self.button = button
        self.type = type
        self.download = download
        super.init()
    }

    override var request: URLRequest { destination }
    override var targetFrame: WKFrameInfo? { target }
    override var navigationType: WKNavigationType { type }
    override var modifierFlags: NSEvent.ModifierFlags { keys }
    override var buttonNumber: Int { button }
    override var shouldPerformDownload: Bool { download }
}
