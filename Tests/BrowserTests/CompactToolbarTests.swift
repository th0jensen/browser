import AppKit
import Observation
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class CompactToolbarTests: XCTestCase {
    func testVerticalCompactToolbarRevealsOverTheSameFullHeightPage() async throws {
        let fixture = try await makeFixture(layout: .vertical)
        defer { fixture.close() }
        let window = fixture.window
        let page = fixture.tab.contentView
        let webView = fixture.webView
        let hiddenFrame = try await settledPageFrame(in: fixture)
        let content = try XCTUnwrap(window.contentView)
        let contentFrame = try frameInWindow(content, window: window)
        let nativeField = try XCTUnwrap(addressField(in: window))
        XCTAssertFalse(nativeToolbarIsVisible(in: window))
        XCTAssertFalse(nativeField.acceptsFirstResponder)
        XCTAssertFalse(nativeField.becomeFirstResponder())
        XCTAssertEqual(hiddenFrame.minX, contentFrame.minX + BrowserChrome.edgeInset, accuracy: 1)
        XCTAssertEqual(hiddenFrame.maxX, contentFrame.maxX - BrowserChrome.edgeInset, accuracy: 1)
        XCTAssertEqual(hiddenFrame.minY, contentFrame.minY + BrowserChrome.edgeInset, accuracy: 1)
        XCTAssertEqual(hiddenFrame.maxY, contentFrame.maxY - BrowserChrome.edgeInset, accuracy: 1)
        assertWindowControls(hidden: true, in: window)
        try assertPageReceivesHitsUnderHiddenChrome(in: fixture)
        fixture.hover.pointerMoved(to: CGPoint(x: window.frame.width / 2, y: 1))
        XCTAssertTrue(nativeToolbarIsVisible(in: window))
        try await waitFor("native toolbar reveal") { self.nativeToolbarIsVisible(in: window) }
        assertEqualFrames(try await settledPageFrame(in: fixture), hiddenFrame, "Floating chrome must overlay the page")
        assertWindowControls(hidden: false, in: window)
        try assertNativeToolbarMetrics(in: window, extraInset: BrowserChrome.edgeInset / 2)
        XCTAssertTrue(addressField(in: window) === nativeField)
        XCTAssertTrue(fixture.tab.webView === webView)
        XCTAssertTrue(fixture.tab.contentView === page)
        fixture.hover.pointerMoved(to: CGPoint(x: window.frame.width / 2, y: 300))
        try await waitFor("native toolbar hide") { !self.nativeToolbarIsVisible(in: window) }
        assertEqualFrames(try await settledPageFrame(in: fixture), hiddenFrame, "Hiding floating chrome must retain the page frame")
        XCTAssertTrue(addressField(in: window) === nativeField)
        assertWindowControls(hidden: true, in: window)
        try assertPageReceivesHitsUnderHiddenChrome(in: fixture)
    }

    func testHorizontalTabsAlwaysKeepChromeVisibleDespiteSavedAutoHideChoices() async throws {
        let fixture = try await makeFixture(layout: .horizontal)
        defer { fixture.close() }
        let window = fixture.window
        let page = fixture.tab.contentView
        XCTAssertFalse(fixture.browser.chromePreferences.autoHideToolbar)
        XCTAssertFalse(fixture.browser.chromePreferences.autoHideSidebar)
        XCTAssertTrue(nativeToolbarIsVisible(in: window))
        XCTAssertTrue(horizontalTabsAreVisible(in: window))
        fixture.hover.pointerMoved(to: CGPoint(x: 400, y: 400))
        try await Task.sleep(for: ChromeHoverController.hideDelay + .milliseconds(80))
        XCTAssertTrue(nativeToolbarIsVisible(in: window))
        assertWindowControls(hidden: false, in: window)
        fixture.browser.chromePreferences.tabLayout = .vertical
        try await waitFor("vertical mode to restore its saved auto-hide choice") { !self.nativeToolbarIsVisible(in: window) }
        fixture.browser.chromePreferences.tabLayout = .horizontal
        try await waitFor("horizontal mode to restore permanent chrome") {
            self.nativeToolbarIsVisible(in: window) && self.horizontalTabsAreVisible(in: window)
        }
        XCTAssertTrue(fixture.tab.contentView === page)
    }

    func testSidebarAndToolbarHoverRemainIndependentNativeOverlays() async throws {
        let fixture = try await makeFixture(layout: .vertical)
        defer { fixture.close() }
        let window = fixture.window
        let pageFrame = try await settledPageFrame(in: fixture)

        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 200))
        try await waitFor("floating sidebar to appear") { fixture.hover.sidebarIsRevealed }
        XCTAssertFalse(fixture.hover.toolbarIsRevealed)
        XCTAssertFalse(nativeToolbarIsVisible(in: window),
                       "The left edge must not reveal the native toolbar")
        assertEqualFrames(try await settledPageFrame(in: fixture), pageFrame,
                          "A floating sidebar must overlay the page without reserving width")

        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 1))
        try await waitFor("top edge to reveal only the toolbar") {
            fixture.hover.toolbarIsRevealed && !fixture.hover.sidebarIsRevealed && self.nativeToolbarIsVisible(in: window)
        }
        assertEqualFrames(try await settledPageFrame(in: fixture), pageFrame,
                          "Switching hover regions must preserve the page frame")

        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 200))
        try await waitFor("left edge to leave toolbar hidden while retaining sidebar") {
            fixture.hover.sidebarIsRevealed && !fixture.hover.toolbarIsRevealed && !self.nativeToolbarIsVisible(in: window)
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
        let fixture = try await makeFixture(layout: .vertical)
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
            return self.nativeToolbarIsVisible(in: window) && window.firstResponder === editor
                && fixture.browser.consumedAddressFocusRequest == fixture.browser.addressFocusRequest
        }
        XCTAssertEqual(fixture.browser.tabs.count, 2)
        XCTAssertEqual(fixture.browser.addressFocusRequest, previousFocusRequest + 1)
        XCTAssertTrue(fixture.browser.activeTab?.isNewTab == true)
        XCTAssertTrue(fixture.hover.addressIsFocused)
        // Native titlebar alignment is coalesced after the field editor appears.
        try await waitFor("native window controls to finish reveal alignment") {
            guard let close = window.standardWindowButton(.closeButton), close.window != nil else { return false }
            let frame = close.convert(close.bounds, to: nil)
            return abs(frame.minX - BrowserChrome.windowControlsLeadingInset(controlHeight: frame.height) - BrowserChrome.edgeInset / 2) < 0.5
        }
        try assertNativeToolbarMetrics(in: window, extraInset: BrowserChrome.edgeInset / 2)

        // A focused native field must keep the toolbar usable after the pointer leaves.
        fixture.hover.pointerMoved(to: CGPoint(x: 600, y: 300))
        try await Task.sleep(for: ChromeHoverController.hideDelay + .milliseconds(80))
        XCTAssertTrue(nativeToolbarIsVisible(in: window))
        let field = try XCTUnwrap(addressField(in: window))
        XCTAssertTrue(window.firstResponder === field.currentEditor())

        // Return to the loaded page and end editing through AppKit, rather than mutating hover focus state.
        fixture.browser.activeTabID = fixture.tab.id
        XCTAssertTrue(window.makeFirstResponder(originalWebView))
        try await waitFor("address editor to resign and compact toolbar to hide") {
            !fixture.hover.addressIsFocused && !self.nativeToolbarIsVisible(in: window)
        }
        assertEqualFrames(try await settledPageFrame(in: fixture), originalPageFrame,
                          "Returning from a new tab must restore the same compact page frame")
        XCTAssertTrue(fixture.tab.contentView === originalPage)
        XCTAssertTrue(fixture.tab.webView === originalWebView)
        XCTAssertTrue(originalWebView.superview === originalPage)

        fixture.browser.chromePreferences.autoHideToolbar = false
        try await waitFor("leaving compact mode to restore native toolbar") {
            !fixture.hover.compactToolbar && self.nativeToolbarIsVisible(in: window)
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

    func testFullscreenNativeWindowControlsReserveTabSpaceAndRouteWindowActions() async throws {
        let window = FullscreenControlsTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let header = HStack(spacing: BrowserChrome.edgeInset) {
            FullscreenWindowControls(window: window)
                .fixedSize(horizontal: true, vertical: false)
            HorizontalTabAnchor()
                .frame(maxWidth: .infinity)
        }
        .frame(height: BrowserChrome.tabRowHeight)
        .padding(.horizontal, BrowserChrome.edgeInset)
        .frame(width: 800, height: 200, alignment: .top)
        let host = NSHostingView(rootView: header)
        host.sceneBridgingOptions = []
        host.sizingOptions = []
        host.safeAreaRegions = []
        installStandaloneHost(host, in: window)
        window.orderBack(nil)
        try await waitFor("native fullscreen window controls to lay out beside tabs") {
            guard let controls = self.descendant(FullscreenWindowControlsView.self, in: host),
                  let tab = self.descendant(HorizontalTabAnchorView.self, in: host) else { return false }
            return controls.bounds.height == BrowserChrome.tabRowHeight && tab.bounds.width > 0
        }
        host.layoutSubtreeIfNeeded()
        let controls = try XCTUnwrap(descendant(FullscreenWindowControlsView.self, in: host))
        let close = try XCTUnwrap(controls.controlButtons[.closeButton])
        let miniaturize = try XCTUnwrap(controls.controlButtons[.miniaturizeButton])
        let fullscreen = try XCTUnwrap(controls.controlButtons[.zoomButton])
        let tabs = try XCTUnwrap(descendant(HorizontalTabAnchorView.self, in: host))
        let contentFrame = try frameInWindow(host, window: window)
        let closeFrame = try frameInWindow(close, window: window)
        let tabsFrame = try frameInWindow(tabs, window: window)
        XCTAssertEqual(closeFrame.minX, BrowserChrome.edgeInset + (BrowserChrome.toolbarHeight - closeFrame.height) / 2, accuracy: 0.5)
        XCTAssertEqual(contentFrame.maxY - closeFrame.midY, BrowserChrome.tabRowHeight / 2, accuracy: 0.5,
                       "Fullscreen traffic lights must keep the native horizontal titlebar center")
        XCTAssertEqual(closeFrame.midY, tabsFrame.midY, accuracy: 0.5)
        XCTAssertEqual(try frameInWindow(miniaturize, window: window).midY, closeFrame.midY, accuracy: 0.5)
        let fullscreenFrame = try frameInWindow(fullscreen, window: window)
        XCTAssertEqual(fullscreenFrame.midY, closeFrame.midY, accuracy: 0.5)
        XCTAssertEqual(tabsFrame.minX - fullscreenFrame.maxX, BrowserChrome.edgeInset, accuracy: 0.5,
                       "Horizontal tabs must reserve every native window control plus the shared gap")
        XCTAssertFalse(controls.isOpaque, "Window controls must not introduce an opaque fullscreen backdrop")
        XCTAssertTrue(close.target as? NSWindow === window)
        XCTAssertTrue(miniaturize.target as? NSWindow === window)
        XCTAssertTrue(fullscreen.target as? NSWindow === window)
        close.performClick(nil)
        miniaturize.performClick(nil)
        fullscreen.performClick(nil)
        XCTAssertEqual(window.closeRequests, 1)
        XCTAssertEqual(window.miniaturizeRequests, 1)
        XCTAssertEqual(window.fullscreenRequests, 1)
    }

    func testFullscreenControlsStayActiveWhenParkedNativeOriginalsAreDisabled() throws {
        let window = FullscreenControlsTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.simulatesFullscreen = false; window.close() }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            try XCTUnwrap(window.standardWindowButton(type)).isEnabled = false
        }
        window.simulatesFullscreen = true
        let controls = FullscreenWindowControlsView(frame: NSRect(x: 0, y: 0, width: 80, height: 32))
        controls.configure(targetWindow: window, isEnabled: true)
        let close = try XCTUnwrap(controls.controlButtons[.closeButton])
        let miniaturize = try XCTUnwrap(controls.controlButtons[.miniaturizeButton])
        let fullscreen = try XCTUnwrap(controls.controlButtons[.zoomButton])
        XCTAssertTrue(close.isEnabled, "A parked native titlebar must not disable fullscreen close")
        XCTAssertTrue(fullscreen.isEnabled, "A parked native titlebar must not disable exiting fullscreen")
        XCTAssertFalse(miniaturize.isEnabled, "Fullscreen windows retain native non-miniaturizable behavior")
        close.performClick(nil)
        miniaturize.performClick(nil)
        fullscreen.performClick(nil)
        XCTAssertEqual(window.closeRequests, 1)
        XCTAssertEqual(window.miniaturizeRequests, 0)
        XCTAssertEqual(window.fullscreenRequests, 1)

        controls.configure(targetWindow: window, isEnabled: false)
        XCTAssertTrue(controls.controlButtons.values.allSatisfy { !$0.isEnabled },
                      "The retained hidden-region environment must disable every fullscreen control")
        close.performClick(nil)
        fullscreen.performClick(nil)
        XCTAssertEqual(window.closeRequests, 1)
        XCTAssertEqual(window.fullscreenRequests, 1)

        window.simulatesFullscreen = false
        controls.configure(targetWindow: window, isEnabled: true)
        XCTAssertTrue(controls.controlButtons.values.allSatisfy { !$0.isEnabled },
                      "Windowed controls must continue mirroring native original enablement")
    }

    func testRetainedHiddenToolbarRegionDefersAddressFocusAndHitTestingUntilRevealed() async throws {
        let window = FullscreenControlsTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let toolbar = NSToolbar(identifier: "RetainedToolbarFocus-\(UUID().uuidString)")
        window.toolbar = toolbar
        toolbar.isVisible = false
        let hover = ChromeHoverController()
        hover.compactToolbar = true
        defer { hover.stop() }
        var appliedRequest = 0
        let request = ChromeRegionFocusRequest()
        let region = ChromeRevealRegion(controller: hover, region: .toolbar) {
            HStack(spacing: BrowserChrome.edgeInset) {
                FullscreenWindowControls(window: window)
                    .fixedSize(horizontal: true, vertical: false)
                AddressTextField(text: .constant("https://example.com"), requiresVisibleToolbar: false,
                             focusRequest: request.value, onFocusApplied: { appliedRequest = $0 },
                             onFocusChange: { _ in }, onSubmit: {})
                    .frame(width: 300, height: BrowserChrome.toolbarHeight)
            }
            .frame(height: BrowserChrome.tabRowHeight)
        }
        let host = NSHostingView(rootView: region.frame(width: 800, height: 200, alignment: .top))
        host.sceneBridgingOptions = []
        host.sizingOptions = []
        host.safeAreaRegions = []
        installStandaloneHost(host, in: window)
        window.orderBack(nil)
        toolbar.isVisible = false
        try await waitFor("retained hidden field to receive its visibility environment") {
            self.descendant(AddressField.self, in: host)?.regionIsVisible == false
        }
        let field = try XCTUnwrap(descendant(AddressField.self, in: host))
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(appliedRequest, 0, "A retained invisible field must leave its focus request pending")
        XCTAssertNil(field.currentEditor())
        XCTAssertFalse(field.acceptsFirstResponder)
        XCTAssertFalse(field.becomeFirstResponder())
        _ = window.makeFirstResponder(field)
        XCTAssertFalse(window.firstResponder === field,
                       "Native keyboard traversal must not focus a retained invisible field")
        XCTAssertNil(field.currentEditor())
        let controls = try XCTUnwrap(descendant(FullscreenWindowControlsView.self, in: host))
        XCTAssertTrue(controls.controlButtons.values.allSatisfy { !$0.isEnabled })
        controls.controlButtons.values.forEach { $0.performClick(nil) }
        XCTAssertEqual(window.closeRequests + window.miniaturizeRequests + window.fullscreenRequests, 0,
                       "Retained invisible native controls must reject keyboard activation")
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: host)
        let hit = host.hitTest(point)
        XCTAssertFalse(hit === field || hit?.isDescendant(of: field) == true,
                       "The retained invisible region must not intercept native page clicks")

        hover.revealToolbar()
        try await waitFor("first reveal to apply the retained field's pending focus") {
            field.regionIsVisible && appliedRequest == 1 && field.currentEditor() != nil
                && window.firstResponder === field.currentEditor()
        }
        XCTAssertTrue(descendant(AddressField.self, in: host) === field)
        XCTAssertTrue(controls.controlButtons[.closeButton]?.isEnabled == true)
        XCTAssertTrue(window.makeFirstResponder(nil))
        hover.toolbarIsRevealed = false
        try await waitFor("retained field to become invisible again") { !field.regionIsVisible }
        XCTAssertFalse(field.acceptsFirstResponder)
        _ = window.makeFirstResponder(field)
        XCTAssertFalse(window.firstResponder === field)
        XCTAssertNil(field.currentEditor())
        request.value = 2
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(appliedRequest, 1)
        hover.revealToolbar()
        try await waitFor("second reveal to focus the same native field") {
            field.regionIsVisible && appliedRequest == 2 && window.firstResponder === field.currentEditor()
        }
        XCTAssertTrue(host.window === window)
        XCTAssertTrue(descendant(FullscreenWindowControlsView.self, in: host) === controls)
        XCTAssertTrue(descendant(AddressField.self, in: host) === field,
                      "Repeated reveal must reuse the existing native field and hosting view")
        XCTAssertFalse(toolbar.isVisible)
    }

    private func installStandaloneHost<Content: View>(_ host: NSHostingView<Content>, in window: NSWindow) {
        let content = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 200))
        window.contentView = content
        host.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor),
            host.heightAnchor.constraint(equalToConstant: 200)
        ])
    }

    private func makeFixture(layout: TabLayout) async throws -> CompactToolbarFixture {
        let fixture = try CompactToolbarFixture(layout: layout)
        do {
            try await waitFor("compact native window to install its loaded page") {
                fixture.browser.window === fixture.window && fixture.webView.window === fixture.window
                    && fixture.webView.bounds.width > 0 && fixture.webView.bounds.height > 0
                    && fixture.hover.compactToolbar == (layout == .vertical)
                    && self.nativeToolbarIsVisible(in: fixture.window) == (layout == .horizontal)
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

    private func assertPageReceivesHitsUnderHiddenChrome(in fixture: CompactToolbarFixture,
                                                         file: StaticString = #filePath, line: UInt = #line) throws {
        let window = fixture.window
        let root = try XCTUnwrap(window.contentView?.superview, file: file, line: line)
        let page = try frameInWindow(fixture.webView, window: window)
        for x in [page.minX + 20, page.midX, page.maxX - 20] {
            let point = root.convert(NSPoint(x: x, y: page.maxY - 12), from: nil)
            let hit = root.hitTest(point)
            XCTAssertTrue(hit === fixture.webView || hit?.isDescendant(of: fixture.webView) == true,
                          "Concealed chrome must leave the top of the page clickable", file: file, line: line)
        }
    }

    private func nativeToolbarIsVisible(in window: NSWindow) -> Bool {
        guard window.toolbar?.isVisible == true, let field = addressField(in: window), field.window != nil else { return false }
        return !field.isHiddenOrHasHiddenAncestor
    }

    private func horizontalTabAnchor(in window: NSWindow) -> HorizontalTabAnchorView? {
        guard let root = window.contentView?.superview else { return nil }
        return descendant(HorizontalTabAnchorView.self, in: root)
    }

    private func horizontalTabsAreVisible(in window: NSWindow) -> Bool {
        guard let tabs = horizontalTabAnchor(in: window), tabs.window != nil else { return false }
        return !tabs.isHiddenOrHasHiddenAncestor
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

    private func assertNativeToolbarMetrics(in window: NSWindow, extraInset: CGFloat = 0, file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "address" }?.view,
                                 file: file, line: line)
        let anchor = try XCTUnwrap(descendant(ToolbarFieldAnchorView.self, in: item), file: file, line: line)
        XCTAssertEqual(try frameInWindow(anchor, window: window).height, 24, accuracy: 1,
                       "Compact reveal must preserve the native 24-point address field", file: file, line: line)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton), file: file, line: line)
        let closeFrame = try frameInWindow(close, window: window)
        XCTAssertEqual(closeFrame.minX, BrowserChrome.windowControlsLeadingInset(controlHeight: closeFrame.height) + extraInset, accuracy: 0.5,
                       "Window controls must preserve the balanced inset for their native control size", file: file, line: line)
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
        let browser = BrowserModel(sitePermissions: SitePermissions(), chromePreferences: WindowChromePreferences(defaults: defaults))
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
@MainActor private class CompactToolbarTestWindow: NSWindow {
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

@MainActor private final class FullscreenControlsTestWindow: CompactToolbarTestWindow {
    var simulatesFullscreen = false

    override var styleMask: NSWindow.StyleMask {
        get { simulatesFullscreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }

    private(set) var closeRequests = 0
    private(set) var miniaturizeRequests = 0
    private(set) var fullscreenRequests = 0

    override func performClose(_ sender: Any?) { closeRequests += 1 }
    override func performMiniaturize(_ sender: Any?) { miniaturizeRequests += 1 }
    override func toggleFullScreen(_ sender: Any?) { fullscreenRequests += 1 }
}

@MainActor @Observable private final class ChromeRegionFocusRequest {
    var value = 1
}
