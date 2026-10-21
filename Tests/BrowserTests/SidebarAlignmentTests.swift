import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class SidebarAlignmentTests: XCTestCase {
    func testGutterBudgetPreservesPageOriginAndResizeBoundary() {
        XCTAssertEqual(BrowserChrome.dockedSidebarHorizontalInset, BrowserChrome.edgeInset / 2)
        // SwiftUI mirrors offset in RTL; hosted native-frame assertions below
        // verify both directions rather than applying a second sign reversal.
        for width: CGFloat in [180, 188, 236, 420] {
            let outer = BrowserChrome.dockedSidebarHorizontalInset
            let columnWidth = width + BrowserChrome.edgeInset
            XCTAssertEqual(outer * 2, BrowserChrome.edgeInset)
            // The docked host and main column retain their original allocation;
            // only sidebar content moves inside that existing visible budget.
            let rowLeading = outer + BrowserChrome.edgeInset
            let rowTrailing = outer + width - BrowserChrome.edgeInset
            XCTAssertEqual(rowLeading, columnWidth - rowTrailing, accuracy: 0.001)
            XCTAssertEqual(outer + width / 2, columnWidth / 2, accuracy: 0.001)
        }
    }

    func testHostedDockedContentsCenterBetweenWindowEdgeAndActualPageInBothDirections() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for width in [180.0, 236.0, 420.0] {
                let fixture = try Fixture(width: width, direction: direction)
                defer { fixture.close() }
                try await fixture.settle(docked: true)
                let viewport = try XCTUnwrap(fixture.viewportFrame())
                let page = fixture.pageFrame
                let windowBounds = fixture.root.bounds
                let outer = direction == .leftToRight ? viewport.minX - windowBounds.minX : windowBounds.maxX - viewport.maxX
                let inner = direction == .leftToRight ? page.minX - viewport.maxX : viewport.minX - page.maxX
                XCTAssertEqual(outer, BrowserChrome.dockedSidebarHorizontalInset, accuracy: 0.5)
                XCTAssertEqual(inner, outer, accuracy: 0.5, "The page gutter must not bias the docked content left/right")
                XCTAssertEqual(viewport.width, width, accuracy: 0.5)
                let selector = try XCTUnwrap(fixture.find(SpaceSelectorView.self))
                let group = selector.selectorGroup.convert(selector.selectorGroup.bounds, to: fixture.root)
                XCTAssertEqual(group.midX, viewport.midX, accuracy: 0.5)
                XCTAssertEqual(page.width, windowBounds.width - width - BrowserChrome.edgeInset * 2, accuracy: 0.5)
                XCTAssertTrue(fixture.browser.activeTab === fixture.tab)
                XCTAssertTrue(fixture.tab.webView === fixture.webView)
            }
        }
    }

    func testFloatingGeometryStaysUnchangedAndToggleKeepsTheSamePage() async throws {
        let fixture = try Fixture(width: 236, direction: .leftToRight)
        defer { fixture.close() }
        try await fixture.settle(docked: true)
        let original = fixture.pageFrame
        let tabs = fixture.browser.allTabs.map(ObjectIdentifier.init)
        let space = fixture.browser.activeSpaceID
        fixture.browser.chromePreferences.autoHideSidebar = true
        try await fixture.settle(docked: false)
        fixture.hover.pointerMoved(to: CGPoint(x: 1, y: 200))
        try await waitFor {
            fixture.hover.sidebarIsRevealed && abs((fixture.viewportFrame()?.minX ?? -100) - BrowserChrome.revealInset) < 0.5
        }
        XCTAssertEqual(fixture.pageFrame.minX, BrowserChrome.edgeInset, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(fixture.viewportFrame()).width, 236, accuracy: 0.5)
        fixture.browser.chromePreferences.autoHideSidebar = false
        try await fixture.settle(docked: true)
        XCTAssertEqual(fixture.pageFrame.minX, original.minX, accuracy: 0.5)
        XCTAssertEqual(fixture.pageFrame.width, original.width, accuracy: 0.5)
        XCTAssertEqual(fixture.browser.allTabs.map(ObjectIdentifier.init), tabs)
        XCTAssertEqual(fixture.browser.activeSpaceID, space)
        XCTAssertTrue(fixture.tab.webView === fixture.webView)
    }

    func testDockAndFloatKeepTheOriginalNativeWindowMaterial() async throws {
        let fixture = try Fixture(width: 236, direction: .leftToRight)
        defer { fixture.close() }
        try await fixture.settle(docked: true)
        let material = try XCTUnwrap(windowMaterial(in: fixture.root))
        for floating in [true, false] {
            fixture.browser.chromePreferences.autoHideSidebar = floating
            try await fixture.settle(docked: !floating)
            XCTAssertTrue(windowMaterial(in: fixture.root) === material)
            XCTAssertEqual(material.material, .titlebar)
            XCTAssertEqual(material.blendingMode, .behindWindow)
            XCTAssertEqual(material.state, .active)
            XCTAssertNil(material.appearance, "Ordinary sidebar must not force a tint/appearance")
            XCTAssertFalse(fixture.window.isOpaque)
            XCTAssertEqual(fixture.window.backgroundColor.alphaComponent, 0)
        }
    }

    private func windowMaterial(in root: NSView) -> NSVisualEffectView? {
        if let view = root as? NSVisualEffectView, view.material == .titlebar, view.blendingMode == .behindWindow { return view }
        return root.subviews.lazy.compactMap { self.windowMaterial(in: $0) }.first
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("Sidebar geometry did not settle"); throw WaitFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private enum WaitFailure: Error { case timeout }
}

@MainActor
private final class Fixture {
    let suite = "SidebarAlignment-\(UUID())"
    let defaults: UserDefaults
    let browser: BrowserModel
    let hover = ChromeHoverController()
    let tab: BrowserTab
    let webView: WKWebView
    let window: AlignmentTestWindow
    let width: Double
    let direction: LayoutDirection
    var root: NSView { window.contentViewController!.view }
    var pageFrame: NSRect { webView.convert(webView.bounds, to: root) }

    init(width: Double, direction: LayoutDirection) throws {
        self.width = width
        self.direction = direction
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(width, forKey: ChromeCustomization.widthKey)
        defaults.set(BookmarksBarVisibility.never.rawValue, forKey: BookmarksBarVisibility.storageKey)
        let chrome = WindowChromePreferences(defaults: defaults)
        chrome.tabLayout = .vertical
        chrome.autoHideSidebar = false
        chrome.autoHideToolbar = false
        chrome.showsSpaceTitle = false
        browser = BrowserModel(chromePreferences: chrome, history: HistoryStore(file: nil), websiteDataStore: .nonPersistent(),
                               spaces: BrowserSpaceStore(directory: .temporaryDirectory.appending(path: UUID().uuidString), enabled: false))
        tab = try XCTUnwrap(browser.activeTab)
        tab.isNewTab = false
        tab.restore() // Empty, local WebKit page; no network or page navigation is needed.
        webView = try XCTUnwrap(tab.webView)
        browser.consumedAddressFocusRequest = browser.addressFocusRequest
        window = AlignmentTestWindow(contentRect: .init(x: 0, y: 0, width: 1600, height: 1000),
                                     styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let host = NSHostingController(rootView: BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser,
                                                               chromeHover: hover, persistsToolbarLayout: false)
            .defaultAppStorage(defaults).environment(\.layoutDirection, direction))
        host.sizingOptions = .minSize
        window.contentViewController = host
        window.orderBack(nil)
        window.toolbar?.autosavesConfiguration = false
    }

    func find<T: NSView>(_ type: T.Type) -> T? {
        func walk(_ view: NSView) -> T? {
            (view as? T) ?? view.subviews.lazy.compactMap { walk($0) }.first
        }
        return walk(root)
    }
    func viewportFrame() -> NSRect? {
        guard let view = find(SidebarSpaceSwipeView.self) else { return nil }
        return view.convert(view.bounds, to: root)
    }
    func settle(docked: Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while true {
            root.layoutSubtreeIfNeeded()
            let expected = docked && direction == .leftToRight ? width + BrowserChrome.edgeInset : BrowserChrome.edgeInset
            if browser.window === window, abs(pageFrame.minX - expected) < 0.5, pageFrame.width > 100,
               !docked || viewportFrame() != nil { break }
            guard ContinuousClock.now < end else {
                XCTFail("Page frame \(pageFrame), expected leading \(expected), viewport \(String(describing: viewportFrame()))")
                throw WaitFailure.timeout
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(60))
        root.layoutSubtreeIfNeeded()
    }
    func close() {
        hover.stop()
        webView.stopLoading()
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
    private enum WaitFailure: Error { case timeout }
}

@MainActor
private final class AlignmentTestWindow: NSWindow {
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
