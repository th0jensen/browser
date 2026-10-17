import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class CompactToolbarTests: XCTestCase {
    func testCompactToolbarRevealsOverTheSameFullHeightPageInBothLayouts() async throws {
        for layout in [TabLayout.horizontal, .vertical] {
            let fixture = try await makeFixture(layout: layout)
            defer { fixture.close() }
            let window = fixture.window
            let webView = fixture.webView
            let page = fixture.tab.contentView
            let hiddenFrame = try await settledPageFrame(in: fixture)
            let content = try XCTUnwrap(window.contentView)
            let contentFrame = try frameInWindow(content, window: window)

            XCTAssertFalse(try XCTUnwrap(window.toolbar).isVisible)
            XCTAssertFalse(fixture.hover.toolbarIsRevealed)
            XCTAssertEqual(hiddenFrame.minX, contentFrame.minX + BrowserChrome.edgeInset, accuracy: 1)
            XCTAssertEqual(hiddenFrame.maxX, contentFrame.maxX - BrowserChrome.edgeInset, accuracy: 1)
            XCTAssertEqual(hiddenFrame.minY, contentFrame.minY + BrowserChrome.edgeInset, accuracy: 1)
            XCTAssertEqual(hiddenFrame.maxY, contentFrame.maxY - BrowserChrome.edgeInset, accuracy: 1,
                           "Compact pages must extend beneath the native titlebar in \(layout)")
            assertWindowControls(hidden: true, in: window)
            XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right })

            fixture.hover.pointerMoved(to: CGPoint(x: window.frame.width / 2, y: 1))
            try await waitFor("native toolbar to reveal in \(layout)") { window.toolbar?.isVisible == true }
            let revealedFrame = try await settledPageFrame(in: fixture)
            assertEqualFrames(revealedFrame, hiddenFrame, "Revealing compact chrome must overlay the page")
            assertWindowControls(hidden: false, in: window)
            try assertNativeToolbarMetrics(in: window)
            XCTAssertEqual(window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right }, layout == .horizontal)
            let revealedAccessory = window.titlebarAccessoryViewControllers.first { $0.layoutAttribute == .right }
            XCTAssertTrue(fixture.tab.webView === webView)
            XCTAssertTrue(fixture.tab.contentView === page)
            XCTAssertTrue(webView.superview === page)

            fixture.hover.pointerMoved(to: CGPoint(x: window.frame.width / 2, y: 300))
            try await waitFor("native toolbar to hide after leaving its region") {
                !fixture.hover.toolbarIsRevealed && window.toolbar?.isVisible == false
            }
            assertEqualFrames(try await settledPageFrame(in: fixture), hiddenFrame,
                              "Hiding compact chrome must keep the native page frame")
            XCTAssertTrue(fixture.tab.webView === webView)
            XCTAssertTrue(webView.superview === page)
            assertWindowControls(hidden: true, in: window)
            XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right })

            if layout == .horizontal {
                fixture.hover.pointerMoved(to: CGPoint(x: window.frame.width / 2, y: 1))
                try await waitFor("horizontal accessory to return with revealed toolbar") {
                    window.toolbar?.isVisible == true
                        && window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right }
                }
                XCTAssertTrue(window.titlebarAccessoryViewControllers.first { $0.layoutAttribute == .right } === revealedAccessory,
                              "Repeated reveal must reuse the native horizontal tab accessory")
                assertEqualFrames(try await settledPageFrame(in: fixture), hiddenFrame,
                                  "Reattaching horizontal tabs must overlay the same page frame")
                XCTAssertTrue(fixture.tab.webView === webView)
            }
        }
    }

    func testSidebarAndToolbarHoverRemainIndependentNativeOverlays() async throws {
        let fixture = try await makeFixture(layout: .vertical)
        defer { fixture.close() }
        let window = fixture.window
        let pageFrame = try await settledPageFrame(in: fixture)

        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 200))
        try await waitFor("floating sidebar to appear") { fixture.hover.sidebarIsRevealed }
        XCTAssertFalse(fixture.hover.toolbarIsRevealed)
        XCTAssertFalse(try XCTUnwrap(window.toolbar).isVisible,
                       "The left edge must not reveal the native toolbar")
        assertEqualFrames(try await settledPageFrame(in: fixture), pageFrame,
                          "A floating sidebar must overlay the page without reserving width")

        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 1))
        try await waitFor("top edge to reveal only the toolbar") {
            fixture.hover.toolbarIsRevealed && !fixture.hover.sidebarIsRevealed && window.toolbar?.isVisible == true
        }
        assertEqualFrames(try await settledPageFrame(in: fixture), pageFrame,
                          "Switching hover regions must preserve the page frame")

        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 200))
        try await waitFor("left edge to leave toolbar hidden while retaining sidebar") {
            fixture.hover.sidebarIsRevealed && !fixture.hover.toolbarIsRevealed && window.toolbar?.isVisible == false
        }
        assertEqualFrames(try await settledPageFrame(in: fixture), pageFrame,
                          "Independent sidebar reveal must preserve full page height")
        fixture.hover.pointerMoved(to: CGPoint(x: 600, y: 300))
        try await waitFor("both overlay regions to close") {
            !fixture.hover.sidebarIsRevealed && !fixture.hover.toolbarIsRevealed
        }
        assertEqualFrames(try await settledPageFrame(in: fixture), pageFrame,
                          "Closing both overlays must preserve native page geometry")
    }

    func testNewTabRevealsAndFocusesNativeAddressFieldThenExitingCompactRestoresChrome() async throws {
        let fixture = try await makeFixture(layout: .horizontal)
        defer { fixture.close() }
        let window = fixture.window
        let originalPageFrame = try await settledPageFrame(in: fixture)
        let originalPage = fixture.tab.contentView
        let originalWebView = fixture.webView
        let previousFocusRequest = fixture.browser.addressFocusRequest

        // This is the model action used by the native Command-T menu command.
        fixture.browser.addTab()
        try await waitFor("new tab to reveal the native toolbar and apply its address focus") {
            guard let field = self.addressField(in: window), let editor = field.currentEditor() else { return false }
            return window.toolbar?.isVisible == true && window.firstResponder === editor
                && fixture.browser.consumedAddressFocusRequest == fixture.browser.addressFocusRequest
        }
        XCTAssertEqual(fixture.browser.tabs.count, 2)
        XCTAssertEqual(fixture.browser.addressFocusRequest, previousFocusRequest + 1)
        XCTAssertTrue(fixture.browser.activeTab?.isNewTab == true)
        XCTAssertTrue(fixture.hover.addressIsFocused)
        XCTAssertTrue(window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right })
        try assertNativeToolbarMetrics(in: window)

        // A focused native field must keep the toolbar usable after the pointer leaves.
        fixture.hover.pointerMoved(to: CGPoint(x: 600, y: 300))
        try await Task.sleep(for: ChromeHoverController.hideDelay + .milliseconds(80))
        XCTAssertTrue(try XCTUnwrap(window.toolbar).isVisible)
        let field = try XCTUnwrap(addressField(in: window))
        XCTAssertTrue(window.firstResponder === field.currentEditor())

        // Return to the loaded page and end editing through AppKit, rather than mutating hover focus state.
        fixture.browser.activeTabID = fixture.tab.id
        XCTAssertTrue(window.makeFirstResponder(originalWebView))
        try await waitFor("address editor to resign and compact toolbar to hide") {
            !fixture.hover.addressIsFocused && window.toolbar?.isVisible == false
        }
        assertEqualFrames(try await settledPageFrame(in: fixture), originalPageFrame,
                          "Returning from a new tab must restore the same compact page frame")
        XCTAssertTrue(fixture.tab.contentView === originalPage)
        XCTAssertTrue(fixture.tab.webView === originalWebView)
        XCTAssertTrue(originalWebView.superview === originalPage)

        fixture.defaults.set(false, forKey: CompactToolbar.storageKey)
        try await waitFor("leaving compact mode to restore native toolbar and horizontal tabs") {
            !fixture.hover.compactToolbar && window.toolbar?.isVisible == true
                && window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right }
        }
        let normalFrame = try await settledPageFrame(in: fixture)
        XCTAssertEqual(normalFrame.maxY, window.contentLayoutRect.maxY - BrowserChrome.edgeInset, accuracy: 1)
        XCTAssertLessThan(normalFrame.height, originalPageFrame.height,
                          "Normal chrome must reserve its native titlebar and toolbar height again")
        XCTAssertEqual(normalFrame.minX, originalPageFrame.minX, accuracy: 1)
        XCTAssertEqual(normalFrame.minY, originalPageFrame.minY, accuracy: 1)
        XCTAssertEqual(normalFrame.width, originalPageFrame.width, accuracy: 1)
        assertWindowControls(hidden: false, in: window)
        try assertNativeToolbarMetrics(in: window)
        XCTAssertTrue(fixture.tab.contentView === originalPage)
        XCTAssertTrue(fixture.tab.webView === originalWebView)
        XCTAssertTrue(originalWebView.superview === originalPage)
    }

    func testFullscreenGlassGroupsFollowCanonicalNativeCustomizationOrder() async throws {
        let fixture = try await makeFixture(layout: .horizontal)
        defer { fixture.close() }
        let toolbar = try XCTUnwrap(fixture.window.toolbar)
        let identifiers: [NSToolbarItem.Identifier] = [
            .init("reload"), .space, .init("back"), .init("divider0"), .init("address"),
            .flexibleSpace, .init("forward"), .space, .init("newTab")
        ]
        toolbar.itemIdentifiers = identifiers
        try await waitFor("canonical toolbar customization order to apply") {
            toolbar.items.map(\.itemIdentifier) == identifiers
        }
        let parts = FullscreenToolbarPart.parts(for: toolbar.items.map { $0.itemIdentifier.rawValue })
        XCTAssertEqual(parts.map(\.content), [
            .controls(["reload"]), .space, .controls(["back"]), .divider, .address,
            .flexibleSpace, .controls(["forward"]), .space, .controls(["newTab"])
        ])
        XCTAssertEqual(parts.map(\.id), Array(identifiers.indices),
                       "Repeated native spaces must have distinct stable positions")
    }

    func testFullscreenOverlayAddressFocusWorksWhileCanonicalNativeToolbarStaysHidden() async throws {
        let window = CompactToolbarTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let toolbar = NSToolbar(identifier: "FullscreenOverlayFocus-\(UUID().uuidString)")
        toolbar.allowsUserCustomization = true
        window.toolbar = toolbar
        toolbar.isVisible = false
        var appliedRequest = 0
        let row = FullscreenToolbarRow(identifiers: ["back", "address", "reload"]) { identifier in
            Button(identifier) {}.buttonStyle(.plain)
        } address: {
            AddressTextField(text: .constant("https://example.com"), requiresVisibleToolbar: false,
                             focusRequest: 1, onFocusApplied: { appliedRequest = $0 },
                             onFocusChange: { _ in }, onSubmit: {})
                .frame(height: BrowserChrome.toolbarHeight)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        let host = NSHostingView(rootView: row.padding(BrowserChrome.edgeInset))
        host.sceneBridgingOptions = []
        window.contentView = host
        window.orderBack(nil)
        toolbar.isVisible = false
        try await waitFor("fullscreen overlay address field to focus with hidden native toolbar") {
            guard let field = self.descendant(AddressField.self, in: host), let editor = field.currentEditor() else { return false }
            return appliedRequest == 1 && window.firstResponder === editor
        }
        XCTAssertFalse(toolbar.isVisible)
        let field = try XCTUnwrap(descendant(AddressField.self, in: host))
        XCTAssertFalse(field.requiresVisibleToolbar)
        XCTAssertTrue(window.makeFirstResponder(nil))
        field.requestFocus(2)
        try await waitFor("a repeated location request to restore overlay field focus") {
            appliedRequest == 2 && field.currentEditor() != nil && window.firstResponder === field.currentEditor()
        }
        XCTAssertFalse(toolbar.isVisible, "Overlay focus must not reveal AppKit's fullscreen toolbar host")
    }

    private func makeFixture(layout: TabLayout) async throws -> CompactToolbarFixture {
        let fixture = try CompactToolbarFixture(layout: layout)
        do {
            try await waitFor("compact native window to install its loaded page") {
                fixture.browser.window === fixture.window && fixture.webView.window === fixture.window
                    && fixture.webView.bounds.width > 0 && fixture.webView.bounds.height > 0
                    && fixture.hover.compactToolbar && fixture.window.toolbar?.isVisible == false
            }
            fixture.webView.loadHTMLString("<html><head><title>Compact toolbar fixture</title></head><body>Native page geometry</body></html>",
                                           baseURL: URL(string: "https://example.com")!)
            try await waitFor("local WKWebView fixture to load") {
                !fixture.webView.isLoading && fixture.tab.pageTitle == "Compact toolbar fixture"
            }
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    private func addressField(in window: NSWindow) -> AddressField? {
        guard let view = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "address" })?.view else { return nil }
        return descendant(AddressField.self, in: view)
    }

    private func descendant<View: NSView>(_ type: View.Type, in view: NSView) -> View? {
        if let match = view as? View { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    private func assertNativeToolbarMetrics(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "address" }?.view,
                                 file: file, line: line)
        let anchor = try XCTUnwrap(descendant(ToolbarFieldAnchorView.self, in: item), file: file, line: line)
        XCTAssertEqual(try frameInWindow(anchor, window: window).height, 24, accuracy: 1,
                       "Compact reveal must preserve the native 24-point address field", file: file, line: line)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton), file: file, line: line)
        XCTAssertEqual(try frameInWindow(close, window: window).minX, 17, accuracy: 0.5,
                       "Compact reveal must preserve the 17-point traffic-light leading inset", file: file, line: line)
    }

    private func assertWindowControls(hidden: Bool, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            XCTAssertEqual(window.standardWindowButton(type)?.isHidden, hidden,
                           "Native window controls must follow compact toolbar visibility", file: file, line: line)
        }
    }

    private func frameInWindow(_ view: NSView, window: NSWindow) throws -> NSRect {
        let owner = try XCTUnwrap(view.window)
        return window.convertFromScreen(owner.convertToScreen(view.convert(view.bounds, to: nil)))
    }

    private func settledPageFrame(in fixture: CompactToolbarFixture) async throws -> NSRect {
        var previous: NSRect?
        var stableSamples = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            let frame = try frameInWindow(fixture.webView, window: fixture.window)
            stableSamples = frame == previous ? stableSamples + 1 : 0
            if stableSamples >= 5 { return frame }
            previous = frame
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native WKWebView geometry did not settle")
        throw CompactToolbarTestError.timedOut
    }

    private func assertEqualFrames(_ actual: NSRect, _ expected: NSRect, _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, message, file: file, line: line)
    }

    private func waitFor(_ description: String, timeout: Duration = .seconds(5),
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw CompactToolbarTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum CompactToolbarTestError: Error { case timedOut }

@MainActor
private final class CompactToolbarFixture {
    let suite: String
    let defaults: UserDefaults
    let window: CompactToolbarTestWindow
    let browser: BrowserModel
    let hover = ChromeHoverController()
    let tab: BrowserTab
    let webView: WKWebView

    init(layout: TabLayout) throws {
        let suite = "BrowserCompactToolbarTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.suite = suite
        self.defaults = defaults
        defaults.set(layout.rawValue, forKey: TabLayout.storageKey)
        defaults.set(true, forKey: CompactToolbar.storageKey)
        defaults.set(true, forKey: SidebarVisibility.autoHideKey)
        defaults.set(BookmarksBarVisibility.never.rawValue, forKey: BookmarksBarVisibility.storageKey)
        let browser = BrowserModel(sitePermissions: SitePermissions())
        let tab = try XCTUnwrap(browser.activeTab)
        self.browser = browser
        self.tab = tab
        tab.isNewTab = false
        // The model creates its initial tab with a focus request. A loaded-page fixture starts unfocused.
        browser.consumedAddressFocusRequest = browser.addressFocusRequest
        webView = try XCTUnwrap(tab.webView)
        let window = CompactToolbarTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                          backing: .buffered, defer: false)
        self.window = window
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: AnyView(
            BrowserWindow(bookmarks: BookmarkStore(), browser: browser, chromeHover: hover).defaultAppStorage(defaults)))
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

/// External window managers must not resize this isolated geometry fixture through AX.
@MainActor private final class CompactToolbarTestWindow: NSWindow {
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
