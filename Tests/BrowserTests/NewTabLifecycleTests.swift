import WebKit
import XCTest
@testable import Browser

@MainActor
final class NewTabLifecycleTests: XCTestCase {
    func testBlankTabsAndSelectionDoNotAllocateWebViews() throws {
        let browser = BrowserModel()
        for _ in 0..<20 { browser.addTab(focusAddress: false) }
        for tab in browser.tabs { browser.activeTabID = tab.id }
        XCTAssertEqual(browser.tabs.count, 21)
        XCTAssertTrue(browser.tabs.allSatisfy { $0.isNewTab && !$0.isSuspended && $0.webView == nil && $0.contentView.subviews.isEmpty })
    }

    func testOpeningAddressMaterializesOnlyThatTabWithItsWindowStore() throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let browser = BrowserModel(websiteDataStore: store, isPrivate: true)
        let blank = try XCTUnwrap(browser.activeTab)
        browser.addTab(focusAddress: false)
        let destination = URL(string: "http://127.0.0.1:9/lazy-navigation")!
        browser.open(destination)
        let selected = try XCTUnwrap(browser.activeTab)
        XCTAssertFalse(selected.isNewTab)
        XCTAssertEqual(selected.url, destination)
        XCTAssertTrue(selected.webView?.configuration.websiteDataStore === store)
        XCTAssertNil(selected.webView?.configuration.webExtensionController)
        XCTAssertNil(blank.webView)
        selected.stopLoading()
    }

    func testWebKitSuppliedPopupConfigurationRemainsEagerAndPreserved() throws {
        let browser = BrowserModel()
        let opener = try XCTUnwrap(browser.activeTab)
        opener.restore()
        let configuration = try XCTUnwrap(opener.webView?.configuration)
        let child = browser.openChildTab(of: opener, configuration: configuration, select: false)
        let view = try XCTUnwrap(child.webView)
        XCTAssertTrue(view.configuration.websiteDataStore === browser.websiteDataStore)
        XCTAssertTrue(view.configuration.processPool === configuration.processPool)
        XCTAssertTrue(view.configuration.userContentController === configuration.userContentController)
        XCTAssertTrue(child.isPopUp)
    }

    func testBackgroundChildRequestLoadsWithoutSuppliedConfiguration() async throws {
        let browser = BrowserModel.makePrivate(downloads: DownloadManager())
        let opener = try XCTUnwrap(browser.activeTab)
        let request = URLRequest(url: URL(string: "data:text/html,<title>BackgroundChild</title>")!)
        let child = browser.openChildTab(of: opener, loading: request, select: false)
        XCTAssertTrue(try XCTUnwrap(child.webView).configuration.websiteDataStore === browser.websiteDataStore)
        XCTAssertEqual(browser.activeTabID, opener.id)
        XCTAssertNil(opener.webView)
        try await waitUntil { child.pageTitle == "BackgroundChild" && !child.isLoading }
    }

    func testBlankSplitPanesStayNativeUntilNavigation() throws {
        let browser = BrowserModel()
        let first = try XCTUnwrap(browser.activeTab)
        browser.addTab(focusAddress: false)
        let second = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(browser.makeSplit(first.id, with: second.id))
        browser.restoreVisibleSplit()
        XCTAssertNil(first.webView)
        XCTAssertNil(second.webView)
        second.load(URL(string: "http://127.0.0.1:9/split-navigation")!)
        XCTAssertNotNil(second.webView)
        XCTAssertNil(first.webView)
        second.stopLoading()
    }
}
