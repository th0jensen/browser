import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class RetainedToolbarInteractionTests: XCTestCase {
    func testNativeCommandsPreserveCanonicalCustomizationAcrossModelUpdatesAndLayoutChanges() async throws {
        let fixture = try await fixture(layout: .horizontal, compact: false)
        defer { fixture.close() }
        let window = fixture.window
        let toolbar = try XCTUnwrap(window.toolbar)
        let delegate = try XCTUnwrap(toolbar.delegate)
        let initialDefaults = try defaults(of: toolbar)
        let initialAllowed = try allowed(of: toolbar)
        let reload = try nativeButton("reload", in: window)
        let newTab = try nativeButton("newTab", in: window)
        XCTAssertTrue(toolbar.allowsUserCustomization)
        XCTAssertNotNil(reload.commandMenu())
        XCTAssertTrue(initialAllowed.contains(.space))
        XCTAssertTrue(initialAllowed.contains(.flexibleSpace))
        XCTAssertFalse(initialAllowed.contains { $0.rawValue.hasPrefix("divider") })
        let palettePin = try XCTUnwrap(delegate.toolbar?(toolbar, itemForItemIdentifier: .init("pinSidebar"), willBeInsertedIntoToolbar: false))
        XCTAssertEqual(palettePin.label, "Pin Sidebar")
        XCTAssertEqual(palettePin.paletteLabel, "Pin Sidebar")
        toolbar.insertItem(withItemIdentifier: .init("pinSidebar"), at: 0)
        toolbar.insertItem(withItemIdentifier: .space, at: toolbar.items.count)
        toolbar.insertItem(withItemIdentifier: .space, at: toolbar.items.count)
        try await waitFor("customized pin command to acquire its native view") {
            toolbar.items.first { $0.itemIdentifier.rawValue == "pinSidebar" }?.view is NativeToolbarCommandButton
        }
        let pin = try nativeButton("pinSidebar", in: window)
        XCTAssertFalse(pin.isEnabled)
        for index in 0..<3 {
            fixture.browser.open(URL(string: "data:text/html,<title>NativeState\(index)</title><p>Ready</p>")!)
            try await waitFor("model navigation to update native commands") {
                !fixture.tab.isLoading && fixture.tab.pageTitle == "NativeState\(index)" && reload.isEnabled
            }
            fixture.defaults.set(index.isMultiple(of: 2), forKey: ChromeCustomization.bookmarkButtonKey)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(try nativeButton("reload", in: window) === reload)
            XCTAssertTrue(try nativeButton("newTab", in: window) === newTab)
            XCTAssertEqual(try defaults(of: toolbar), initialDefaults)
            XCTAssertEqual(try allowed(of: toolbar), initialAllowed)
            XCTAssertTrue(toolbar.delegate === delegate)
            for (identifier, label) in [("reload", "Reload"), ("newTab", "New Tab"), ("pinSidebar", "Pin Sidebar")] {
                let item = try item(identifier, in: window)
                XCTAssertEqual(item.label, label)
                XCTAssertEqual(item.paletteLabel, label)
            }
        }
        let layout = try nativeButton("layout", in: window)
        layout.performClick(nil)
        try await waitFor("native layout action to switch the actual window to vertical tabs") {
            window.toolbarStyle == .unifiedCompact && fixture.browser.chromePreferences.tabLayout == .vertical
                && window.toolbar?.delegate is ToolbarCustomizationAdapter
                && (try? self.defaults(of: window.toolbar!)).map { $0.contains(.init("sidebar")) } == true
        }
        let verticalToolbar = try XCTUnwrap(window.toolbar)
        let verticalDefaults = try defaults(of: verticalToolbar)
        let verticalAllowed = try allowed(of: verticalToolbar)
        XCTAssertTrue(verticalDefaults.contains(.init("sidebar")))
        for _ in 0..<2 {
            fixture.browser.chromePreferences.tabLayout = .horizontal
            try await waitFor("horizontal layout round trip") { window.toolbarStyle == .expanded && window.toolbar?.delegate is ToolbarCustomizationAdapter && (try? self.defaults(of: window.toolbar!)) == initialDefaults }
            let current = try XCTUnwrap(window.toolbar)
            XCTAssertEqual(try defaults(of: current), initialDefaults)
            XCTAssertEqual(try allowed(of: current), initialAllowed)
            XCTAssertTrue(current.allowsUserCustomization)
            XCTAssertEqual(try item("newTab", in: window).paletteLabel, "New Tab")
            fixture.browser.chromePreferences.tabLayout = .vertical
            try await waitFor("vertical layout round trip") { window.toolbarStyle == .unifiedCompact && window.toolbar?.delegate is ToolbarCustomizationAdapter && (try? self.defaults(of: window.toolbar!)) == verticalDefaults }
            let currentVertical = try XCTUnwrap(window.toolbar)
            XCTAssertEqual(try defaults(of: currentVertical), verticalDefaults)
            XCTAssertEqual(try allowed(of: currentVertical), verticalAllowed)
        }
        fixture.browser.chromePreferences.tabLayout = .vertical
        let finalVerticalToolbar = try XCTUnwrap(window.toolbar)
        if !finalVerticalToolbar.itemIdentifiers.contains(.init("newTab")) {
            finalVerticalToolbar.insertItem(withItemIdentifier: .init("newTab"), at: finalVerticalToolbar.items.count)
        }
        try await waitFor("vertical native commands after structural updates") {
            window.toolbarStyle == .unifiedCompact && window.toolbar?.items.first { $0.itemIdentifier.rawValue == "newTab" }?.view is NativeToolbarCommandButton
        }
        fixture.browser.chromePreferences.autoHideToolbar = true
        try await waitFor("updated native commands to become concealed") {
            !self.toolbarIsVisible(in: window)
        }
        let concealedNewTab = try nativeButton("newTab", in: window)
        let hiddenCount = fixture.browser.tabs.count
        XCTAssertFalse(concealedNewTab.accessibilityPerformPress())
        XCTAssertEqual(fixture.browser.tabs.count, hiddenCount)
        XCTAssertFalse(try XCTUnwrap(addressField(in: window)).acceptsFirstResponder)
        let root = try XCTUnwrap(window.contentView?.superview)
        let pageFrame = try frame(fixture.webView, in: window)
        let hit = root.hitTest(root.convert(NSPoint(x: pageFrame.midX, y: pageFrame.maxY - 12), from: nil))
        XCTAssertTrue(hit === fixture.webView || hit?.isDescendant(of: fixture.webView) == true)
        fixture.browser.chromePreferences.autoHideToolbar = false
        try await waitFor("updated native commands to become available again") { self.toolbarIsVisible(in: window) }
        let count = fixture.browser.tabs.count
        try nativeButton("newTab", in: window).performClick(nil)
        try await waitFor("latest native new-tab action to add a tab and focus the editor") {
            fixture.browser.tabs.count == count + 1 && self.addressField(in: window)?.currentEditor() != nil
        }
        XCTAssertTrue(fixture.browser.activeTab?.isNewTab == true)
    }

    func testDetachingNativeCommandsRestoresCanonicalPaletteMetadataAndHosts() throws {
        let delegate = RetainedCommandDelegate()
        let toolbar = NSToolbar(identifier: "DetachNativeCommands-\(UUID())")
        toolbar.delegate = delegate
        toolbar.allowsUserCustomization = true
        toolbar.insertItem(withItemIdentifier: .init("reload"), at: 0)
        let window = ToolbarInteractionWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.toolbar = toolbar
        let chrome = WindowChromeView()
        window.contentView = chrome
        let item = try XCTUnwrap(toolbar.items.first)
        let canonicalHost = try XCTUnwrap(item.view)
        let defaultItems = try defaults(of: toolbar)
        let allowedItems = try allowed(of: toolbar)
        for _ in 0..<3 {
            chrome.setNativeCommands([.init(identifier: "reload", title: "Stop Loading", symbol: "xmark", action: {})])
            XCTAssertTrue(item.view is NativeToolbarCommandButton)
            XCTAssertEqual(item.label, "Canonical Reload")
            XCTAssertEqual(item.paletteLabel, "Canonical Reload Palette")
        }
        chrome.detachNativeCommands()
        XCTAssertTrue(item.view === canonicalHost)
        XCTAssertTrue(toolbar.delegate === delegate)
        XCTAssertEqual(try defaults(of: toolbar), defaultItems)
        XCTAssertEqual(try allowed(of: toolbar), allowedItems)
        XCTAssertEqual(item.label, "Canonical Reload")
        XCTAssertEqual(item.paletteLabel, "Canonical Reload Palette")
    }

    func testLocationRequestSelectsWholeURLAndDismissesAfterFocusLossAndSuccessfulSubmission() async throws {
        let fixture = try await fixture(layout: .vertical)
        defer { fixture.close() }
        let window = fixture.window
        let pageFrame = try frame(fixture.webView, in: window)
        fixture.browser.requestAddressFocus() // Shared action used by the Command-G and Command-L menu entries.
        try await waitFor("location request to reveal and focus the native editor") {
            self.toolbarIsVisible(in: window) && self.addressField(in: window)?.currentEditor() != nil
        }
        let field = try XCTUnwrap(addressField(in: window))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: (field.stringValue as NSString).length))
        XCTAssertFalse(field.stringValue.isEmpty)
        fixture.hover.pointerMoved(to: CGPoint(x: 400, y: 1))
        XCTAssertTrue(window.makeFirstResponder(fixture.webView))
        try await waitFor("focus loss to conceal the toolbar despite the pointer remaining in its header") {
            !fixture.hover.addressIsFocused && !self.toolbarIsVisible(in: window)
        }
        fixture.hover.pointerMoved(to: CGPoint(x: 401, y: 1))
        XCTAssertFalse(toolbarIsVisible(in: window), "The same top-edge visit must not reopen a dismissed editing session")

        fixture.browser.requestAddressFocus()
        try await waitFor("another location request to restore native focus") { field.currentEditor() != nil && self.toolbarIsVisible(in: window) }
        let destination = URL(string: "https://example.com/submitted-toolbar-fixture")!
        let originalDelegate = try XCTUnwrap(fixture.webView.navigationDelegate)
        let navigation = SubmittedPageFixture(url: destination, original: originalDelegate)
        fixture.webView.navigationDelegate = navigation
        defer { fixture.webView.navigationDelegate = originalDelegate }
        field.stringValue = destination.absoluteString
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(field.sendAction(try XCTUnwrap(field.action), to: field.target))
        try await waitFor("submitted URL to reach the local navigation fixture") { navigation.intercepted }
        try await Task.sleep(for: ChromeHoverController.hideDelay + .milliseconds(40))
        XCTAssertTrue(toolbarIsVisible(in: window), "Submission must remain revealed until its page actually finishes")
        navigation.finish(in: fixture.webView)
        try await waitFor("successful native WebKit navigation to dismiss submitted chrome") {
            navigation.finished && !fixture.tab.isLoading && fixture.tab.pageTitle == "Submitted Toolbar Page"
                && !self.toolbarIsVisible(in: window)
        }
        XCTAssertEqual(fixture.tab.url, destination)
        XCTAssertNil(fixture.tab.loadError)
        XCTAssertTrue(window.firstResponder === fixture.webView || (window.firstResponder as? NSView)?.isDescendant(of: fixture.webView) == true)
        assertFramesEqual(try frame(fixture.webView, in: window), pageFrame)
    }

    func testCombinedOverlaysReduceSidebarHeightAndKeepClicksInsideItsMeasuredWidth() async throws {
        let fixture = try await fixture(layout: .vertical)
        defer { fixture.close() }
        let window = fixture.window
        let pageFrame = try frame(fixture.webView, in: window)
        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 200))
        try await waitFor("floating sidebar native geometry") { fixture.hover.sidebarIsRevealed && (self.sidebarMarker(in: window)?.bounds.width ?? 0) > 0 }
        let marker = try XCTUnwrap(sidebarMarker(in: window))
        let sidebarOnly = try frame(marker, in: window)
        fixture.hover.revealToolbar()
        try await waitFor("both overlays to reserve separate vertical regions") {
            guard self.toolbarIsVisible(in: window), let current = try? self.frame(marker, in: window) else { return false }
            return current.height < sidebarOnly.height
        }
        let together = try frame(marker, in: window)
        XCTAssertTrue(fixture.hover.sidebarIsRevealed)
        XCTAssertEqual(together.minY, sidebarOnly.minY, accuracy: 0.5)
        XCTAssertEqual(together.width, sidebarOnly.width, accuracy: 0.5)
        XCTAssertLessThan(together.maxY, sidebarOnly.maxY)
        let address = try XCTUnwrap(addressField(in: window))
        XCTAssertLessThanOrEqual(together.maxY, try frame(address, in: window).minY - BrowserChrome.edgeInset)
        assertFramesEqual(try frame(fixture.webView, in: window), pageFrame)
        for width in [180.0, 340.0] {
            fixture.defaults.set(width, forKey: ChromeCustomization.widthKey)
            try await waitFor("sidebar to adopt its customized native width") { abs(marker.bounds.width - width) < 0.5 }
            let bounds = try frame(marker, in: window)
            let y = bounds.maxY - BrowserChrome.edgeInset - BrowserChrome.sidebarTabHeight / 2
            let root = try XCTUnwrap(window.contentView?.superview)
            let outside = root.hitTest(root.convert(NSPoint(x: bounds.maxX + 2, y: y), from: nil))
            XCTAssertTrue(outside === fixture.webView || outside?.isDescendant(of: fixture.webView) == true,
                          "Sidebar hit testing must stop at its measured right edge")
            let inside = root.hitTest(root.convert(NSPoint(x: bounds.midX, y: y), from: nil))
            XCTAssertFalse(inside === fixture.webView || inside?.isDescendant(of: fixture.webView) == true,
                           "The actual sidebar tab row must receive clicks within its measured width")
            fixture.hover.pointerMoved(to: CGPoint(x: bounds.maxX - 1, y: window.frame.height - y))
            try await Task.sleep(for: ChromeHoverController.hideDelay + .milliseconds(20))
            XCTAssertTrue(fixture.hover.sidebarIsRevealed)
        }
        let final = try frame(marker, in: window)
        fixture.hover.pointerMoved(to: CGPoint(x: final.maxX + 2, y: window.frame.height - final.midY))
        try await waitFor("leaving the measured sidebar edge to conceal it") { !fixture.hover.sidebarIsRevealed }
    }

    private func fixture(layout: TabLayout, compact: Bool = true) async throws -> ToolbarInteractionFixture {
        let fixture = try ToolbarInteractionFixture(layout: layout, compact: compact)
        do {
            try await waitFor("browser window and canonical native commands") {
                fixture.browser.window === fixture.window && fixture.webView.window === fixture.window
                    && fixture.window.toolbar?.delegate is ToolbarCustomizationAdapter
                    && fixture.window.toolbar?.items.first { $0.itemIdentifier.rawValue == "reload" }?.view is NativeToolbarCommandButton
                    && self.toolbarIsVisible(in: fixture.window) == !compact
            }
            fixture.webView.loadHTMLString("<title>Initial Toolbar Page</title><p>Ready</p>", baseURL: URL(string: "https://example.com/initial-toolbar-fixture"))
            try await waitFor("local native page to complete") { !fixture.tab.isLoading && fixture.tab.pageTitle == "Initial Toolbar Page" }
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            return fixture
        } catch { fixture.close(); throw error }
    }

    private func defaults(of toolbar: NSToolbar) throws -> [NSToolbarItem.Identifier] {
        try XCTUnwrap(try XCTUnwrap(toolbar.delegate).toolbarDefaultItemIdentifiers?(toolbar))
    }
    private func allowed(of toolbar: NSToolbar) throws -> [NSToolbarItem.Identifier] {
        try XCTUnwrap(try XCTUnwrap(toolbar.delegate).toolbarAllowedItemIdentifiers?(toolbar))
    }
    private func item(_ identifier: String, in window: NSWindow) throws -> NSToolbarItem {
        try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == identifier })
    }
    private func nativeButton(_ identifier: String, in window: NSWindow) throws -> NativeToolbarCommandButton {
        try XCTUnwrap(try item(identifier, in: window).view as? NativeToolbarCommandButton)
    }
    private func addressField(in window: NSWindow) -> AddressField? {
        window.toolbar?.items.first { $0.itemIdentifier.rawValue == "address" }?.view.flatMap { descendant(AddressField.self, in: $0) }
    }
    private func toolbarIsVisible(in window: NSWindow) -> Bool { window.toolbar?.isVisible == true && addressField(in: window)?.window != nil && addressField(in: window)?.isHiddenOrHasHiddenAncestor == false }
    private func sidebarMarker(in window: NSWindow) -> NSView? {
        guard let root = window.contentView else { return nil }
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == "BrowserFloatingSidebarGeometry" { return view }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(root)
    }
    private func descendant<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let result = view as? View { return result }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }
    private func frame(_ view: NSView, in window: NSWindow) throws -> NSRect {
        let owner = try XCTUnwrap(view.window)
        return window.convertFromScreen(owner.convertToScreen(view.convert(view.bounds, to: nil)))
    }
    private func assertFramesEqual(_ actual: NSRect, _ expected: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }
    private func waitFor(_ description: String, timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for \(description)"); throw ToolbarInteractionFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum ToolbarInteractionFailure: Error { case timeout }

@MainActor private final class ToolbarInteractionFixture {
    let suite: String
    let defaults: UserDefaults
    let browser: BrowserModel
    let hover = ChromeHoverController()
    let tab: BrowserTab
    let webView: WKWebView
    let window: ToolbarInteractionWindow

    init(layout: TabLayout, compact: Bool) throws {
        let suite = "RetainedToolbarInteractions-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.suite = suite
        self.defaults = defaults
        defaults.set(layout.rawValue, forKey: TabLayout.storageKey)
        defaults.set(compact, forKey: CompactToolbar.storageKey)
        defaults.set(true, forKey: SidebarVisibility.autoHideKey)
        defaults.set(BookmarksBarVisibility.never.rawValue, forKey: BookmarksBarVisibility.storageKey)
        let browser = BrowserModel(sitePermissions: SitePermissions(), chromePreferences: WindowChromePreferences(defaults: defaults))
        let tab = try XCTUnwrap(browser.activeTab)
        self.browser = browser
        self.tab = tab
        tab.isNewTab = false
        tab.restore()
        browser.consumedAddressFocusRequest = browser.addressFocusRequest
        webView = try XCTUnwrap(tab.webView)
        let window = ToolbarInteractionWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                              backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let host = NSHostingController(rootView: BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser, chromeHover: hover).defaultAppStorage(defaults))
        host.sizingOptions = .minSize
        window.contentViewController = host
        window.orderBack(nil)
        window.toolbar?.autosavesConfiguration = false
    }
    func close() {
        hover.stop()
        webView.stopLoading()
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor private final class ToolbarInteractionWindow: NSWindow {
    override func setAccessibilityFrame(_ accessibilityFrame: NSRect) {}
    @available(macOS, deprecated: 10.10)
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard attribute != .size, attribute != .position else { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
    @available(macOS, deprecated: 10.10)
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        guard attribute != .size, attribute != .position else { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }
}

/// Replaces only transport for one URL; native field submission, BrowserModel loading,
/// WebKit document completion and the original PageDelegate success callback stay real.
@MainActor private final class SubmittedPageFixture: NSObject, WKNavigationDelegate {
    let url: URL
    let original: WKNavigationDelegate
    private(set) var intercepted = false
    private(set) var finished = false
    init(url: URL, original: WKNavigationDelegate) { self.url = url; self.original = original }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !intercepted, navigationAction.request.url == url { intercepted = true; return .cancel }
        return .allow
    }
    func finish(in webView: WKWebView) {
        webView.loadHTMLString("<title>Submitted Toolbar Page</title><p>Complete</p>", baseURL: url)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { original.webView?(webView, didStartProvisionalNavigation: navigation) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { original.webView?(webView, didCommit: navigation) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        original.webView?(webView, didFinish: navigation)
        finished = true
    }
}

@MainActor private final class RetainedCommandDelegate: NSObject, NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("reload"), .space, .flexibleSpace] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("reload")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Canonical Reload"
        item.paletteLabel = "Canonical Reload Palette"
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        return item
    }
}
