import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class NativeFindTests: XCTestCase {
    func testShowFindFocusesNativeInputAcceptsTypingAndReturnsFocusToPage() async throws {
        let fixture = try NativeFindFixture()
        defer { fixture.close() }
        try await waitFor("the hosted page") { fixture.pageIsReady }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.webView))
        fixture.browser.showFindBar()
        try await waitFor("Find on Page to own the native field editor") { fixture.findEditor != nil }
        let editor = try XCTUnwrap(fixture.findEditor)
        editor.selectAll(nil)
        editor.insertText("needle", replacementRange: editor.selectedRange())
        try await waitFor("native typing to update the page query") {
            fixture.tab.findText == "needle" && fixture.findEditor?.string == "needle"
        }

        // Repeating Command-F must recover focus after the user clicks back into the page.
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.webView))
        fixture.browser.showFindBar()
        try await waitFor("a repeated Find command to focus its existing input") { fixture.findEditor != nil }
        fixture.browser.closeFindBar()
        try await waitFor("closing Find to return keyboard focus to the page") {
            !fixture.tab.isFindBarVisible && fixture.pageOwnsFocus(fixture.webView)
        }
    }

    func testFindTargetsPeekAndClosingReturnsFocusToPeekInsteadOfItsOpener() async throws {
        let fixture = try NativeFindFixture()
        defer { fixture.close() }
        try await waitFor("the hosted opener") { fixture.pageIsReady }
        let peek = fixture.browser.openPeek(from: fixture.tab)
        let peekView = try XCTUnwrap(peek.webView)
        peekView.loadHTMLString("<html><head><title>Peek Find Fixture</title></head><body>peek needle</body></html>", baseURL: nil)
        try await waitFor("the hosted Peek page") {
            peekView.window === fixture.window && !peekView.isLoading && peek.pageTitle == "Peek Find Fixture"
        }
        XCTAssertTrue(fixture.window.makeFirstResponder(peekView))
        fixture.browser.showFindBar()
        try await waitFor("Peek Find to focus its input") { fixture.findEditor != nil }
        XCTAssertTrue(peek.isFindBarVisible)
        XCTAssertFalse(fixture.tab.isFindBarVisible)
        let editor = try XCTUnwrap(fixture.findEditor)
        editor.selectAll(nil)
        editor.insertText("peek needle", replacementRange: editor.selectedRange())
        try await waitFor("Find to edit the Peek query") { peek.findText == "peek needle" }
        XCTAssertTrue(fixture.tab.findText.isEmpty)
        fixture.browser.closeFindBar()
        try await waitFor("Find close to restore Peek keyboard focus") {
            !peek.isFindBarVisible && fixture.pageOwnsFocus(peekView)
        }
        XCTAssertTrue(fixture.browser.peek?.tab === peek)
    }

    private func waitFor(_ description: String, timeout: Duration = .seconds(4),
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw NativeFindTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(15))
        }
    }
}

private enum NativeFindTestError: Error { case timedOut }

@MainActor
private final class NativeFindFixture {
    let suite: String
    let defaults: UserDefaults
    let browser: BrowserModel
    let hover = ChromeHoverController()
    let tab: BrowserTab
    let webView: WKWebView
    let window: NSWindow

    init() throws {
        let suite = "NativeFindTests-\(UUID().uuidString)"
        self.suite = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.defaults = defaults
        defaults.set(TabLayout.horizontal.rawValue, forKey: TabLayout.storageKey)
        defaults.set(BookmarksBarVisibility.never.rawValue, forKey: BookmarksBarVisibility.storageKey)
        let browser = BrowserModel(sitePermissions: SitePermissions(), chromePreferences: WindowChromePreferences(defaults: defaults),
                               zoomLevels: ZoomStore(defaults: nil), websiteDataStore: .nonPersistent(), isPrivate: true)
        self.browser = browser
        let tab = try XCTUnwrap(browser.activeTab)
        self.tab = tab
        tab.isNewTab = false
        browser.consumedAddressFocusRequest = browser.addressFocusRequest
        let webView = try XCTUnwrap(tab.webView)
        self.webView = webView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let host = NSHostingController(rootView: AnyView(
            BrowserWindow(bookmarks: BookmarkStore(), browser: browser, chromeHover: hover,
                          persistsToolbarLayout: false).defaultAppStorage(defaults)))
        host.sizingOptions = .minSize
        window.contentViewController = host
        if let laptop = NSScreen.screens.first(where: { $0.localizedName.contains("Built-in") }) {
            window.setFrameOrigin(NSPoint(x: laptop.visibleFrame.minX + 30, y: laptop.visibleFrame.minY + 30))
        }
        window.makeKeyAndOrderFront(nil)
        window.toolbar?.autosavesConfiguration = false
        webView.loadHTMLString("<html><head><title>Native Find Fixture</title></head><body>one needle two needle</body></html>", baseURL: nil)
    }

    var pageIsReady: Bool {
        webView.window === window && !webView.isLoading && tab.pageTitle == "Native Find Fixture"
    }

    var findEditor: NSTextView? {
        guard let root = window.contentView else { return nil }
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.placeholderString == "Find on Page" { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        guard let field = find(root), let editor = field.currentEditor() as? NSTextView,
              window.firstResponder === editor else { return nil }
        return editor
    }

    func pageOwnsFocus(_ page: WKWebView) -> Bool {
        window.firstResponder === page || (window.firstResponder as? NSView)?.isDescendant(of: page) == true
    }

    func close() {
        browser.dismissPeek()
        hover.stop()
        webView.stopLoading()
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
