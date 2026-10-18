import AppKit
import WebKit
import XCTest
@testable import Browser

@MainActor
final class PeekTests: XCTestCase {
    private func model() throws -> BrowserModel {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let folders = TabFolderStore(directory: directory, enabled: false)
        return BrowserModel(folders: folders)
    }
    private func waitForTitle(_ title: String, in tab: BrowserTab) async throws {
        for _ in 0..<200 {
            if tab.pageTitle == title { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Page did not finish loading: \(title)")
    }
    private func loadPinnedHTML(in browser: BrowserModel, blank: Bool = false) async throws -> BrowserTab {
        let tab = try XCTUnwrap(browser.activeTab)
        let home = URL(string: "https://example.com/home")!
        let page = try browser.folders.savePage(url: home, title: "Pinned Home", in: nil)
        tab.folderPageID = page.id
        tab.isNewTab = false
        tab.webView?.loadHTMLString("<title>Pinned Test</title><a id='external' href='https://external.invalid/article' \(blank ? "target='_blank'" : "")>External</a>", baseURL: home)
        try await waitForTitle("Pinned Test", in: tab)
        return tab
    }
    func testSiteComparisonDoesNotConfuseUnrelatedHostsOrPublicSuffixes() {
        let home = URL(string: "https://www.example.co.uk/home")!
        XCTAssertTrue(PinnedNavigation.isSameSite(URL(string: "https://example.co.uk/chapter")!, as: home))
        XCTAssertTrue(PinnedNavigation.isSameSite(URL(string: "https://docs.example.co.uk/chapter")!, as: home))
        for url in ["https://another.co.uk", "https://evil-example.co.uk", "https://example.co.uk.evil.com", "mailto:a@example.co.uk"] {
            XCTAssertFalse(PinnedNavigation.isSameSite(URL(string: url)!, as: home), url)
        }
        XCTAssertTrue(PinnedNavigation.isHome(URL(string: "https://www.example.co.uk/home#part")!, home: home))
        XCTAssertFalse(PinnedNavigation.isHome(URL(string: "https://www.example.co.uk/other")!, home: home))
    }
    func testExternalLinksActuallyOpenPeekWithoutNavigatingOrAddingSessionTabs() async throws {
        let browser = try model()
        let previous = UserDefaults.standard.object(forKey: PinnedNavigation.peekEnabledKey)
        UserDefaults.standard.set(true, forKey: PinnedNavigation.peekEnabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PinnedNavigation.peekEnabledKey); browser.dismissPeek() }
        let tab = try await loadPinnedHTML(in: browser)
        let original = tab.url
        try await tab.webView?.evaluateJavaScript("window.keepMe = 42; document.getElementById('external').click()")
        for _ in 0..<100 where browser.peek == nil { try await Task.sleep(for: .milliseconds(10)) }
        let peek = try XCTUnwrap(browser.peek)
        XCTAssertEqual(peek.openerID, tab.id)
        XCTAssertEqual(browser.activeTabID, tab.id)
        XCTAssertEqual(tab.url, original)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(BrowserSessionSnapshot(browser: browser).tabs.count, 1)
        XCTAssertTrue(peek.tab.webView?.configuration.websiteDataStore === tab.webView?.configuration.websiteDataStore)
        let isSelected = await peek.tab.waitUntilSelected()
        XCTAssertTrue(isSelected)
        browser.closeActiveTab()
        XCTAssertNil(browser.peek)
        XCTAssertEqual(browser.tabs.count, 1)
        let retained = try await tab.webView?.evaluateJavaScript("window.keepMe") as? Int
        XCTAssertEqual(retained, 42)
    }
    func testTargetBlankLinkUsesPeekAndPreservesOpenerConfiguration() async throws {
        let browser = try model()
        let previous = UserDefaults.standard.object(forKey: PinnedNavigation.peekEnabledKey)
        UserDefaults.standard.set(true, forKey: PinnedNavigation.peekEnabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PinnedNavigation.peekEnabledKey); browser.dismissPeek() }
        let tab = try await loadPinnedHTML(in: browser, blank: true)
        try await tab.webView?.evaluateJavaScript("document.getElementById('external').click()")
        for _ in 0..<100 where browser.peek == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(browser.peek)
        XCTAssertTrue(browser.peek?.tab.isPopUp == true)
        XCTAssertEqual(browser.tabs.count, 1)
    }
    func testExpandAdoptsSameWebViewAndItsStateWithoutReloading() async throws {
        let browser = try model(), opener = try XCTUnwrap(browser.activeTab)
        let tab = browser.openPeek(from: opener)
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString("<title>Peek Content</title><input value='retained'>", baseURL: URL(string: "https://external.invalid/article"))
        try await waitForTitle("Peek Content", in: tab)
        try await view.evaluateJavaScript("window.keepMe = 42")
        browser.expandPeek()
        XCTAssertNil(browser.peek)
        XCTAssertTrue(browser.activeTab === tab)
        XCTAssertTrue(browser.activeTab?.webView === view)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(BrowserSessionSnapshot(browser: browser).tabs.count, 2)
        let retained = try await view.evaluateJavaScript("window.keepMe") as? Int
        XCTAssertEqual(retained, 42)
    }
    func testPopupClosingItsPeekDoesNotCloseTheOnlyBrowserWindow() throws {
        final class WindowDelegate: NSObject, NSWindowDelegate {
            var closed = false
            func windowWillClose(_ notification: Notification) { closed = true }
        }
        let browser = try model(), opener = try XCTUnwrap(browser.activeTab)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let delegate = WindowDelegate()
        window.delegate = delegate
        browser.window = window
        let tab = browser.openPeek(from: opener, configuration: BrowserTab.makeConfiguration())
        let view = try XCTUnwrap(tab.webView)
        view.uiDelegate?.webViewDidClose?(view)
        XCTAssertNil(browser.peek)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertFalse(delegate.closed)
        window.close()
    }
    func testCloseAwayFromSavedURLReturnsHomeAndDoesNotRemovePinnedItem() async throws {
        let browser = try model(), tab = try await loadPinnedHTML(in: browser)
        let home = try XCTUnwrap(tab.pinnedHomeURL)
        tab.load(URL(string: "https://example.com/another-page")!)
        XCTAssertTrue(tab.isAwayFromPinnedPage)
        browser.closeActiveTab()
        XCTAssertEqual(tab.url, home)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.folders.item(tab.folderPageID)?.url, home)
        XCTAssertFalse(tab.isAwayFromPinnedPage)
        tab.webView?.stopLoading()
    }
    func testSwitchingTabsDismissesPeekAndDisabledOrOrdinaryTabsDoNotPeek() async throws {
        let browser = try model(), opener = try await loadPinnedHTML(in: browser)
        let previous = UserDefaults.standard.object(forKey: PinnedNavigation.peekEnabledKey)
        defer { UserDefaults.standard.set(previous, forKey: PinnedNavigation.peekEnabledKey) }
        UserDefaults.standard.set(false, forKey: PinnedNavigation.peekEnabledKey)
        XCTAssertFalse(browser.shouldPeek(URL(string: "https://another.com")!, from: opener))
        browser.openPeek(from: opener)
        browser.addTab(focusAddress: false)
        XCTAssertNil(browser.peek)
        UserDefaults.standard.set(true, forKey: PinnedNavigation.peekEnabledKey)
        XCTAssertFalse(browser.shouldPeek(URL(string: "https://another.com")!, from: try XCTUnwrap(browser.activeTab)))
    }
}
