import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserTabTests: XCTestCase {
    private func page(titled title: String) -> URL {
        URL(string: "data:text/html,<title>\(title)</title>")!
    }

    func testTabMirrorsWebViewStateAndHistory() async throws {
        let browser = BrowserModel()
        let tab = try XCTUnwrap(browser.activeTab)

        browser.open(page(titled: "First"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "First" }
        XCTAssertEqual(tab.url, page(titled: "First"))
        XCTAssertFalse(tab.isNewTab)
        XCTAssertFalse(tab.canGoBack)

        browser.open(page(titled: "Second"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Second" }
        XCTAssertTrue(tab.canGoBack)
        XCTAssertEqual(tab.backList.map(\.url), [page(titled: "First")])
        XCTAssertEqual(tab.estimatedProgress, 1)

        browser.goBack()
        try await waitUntil { tab.pageTitle == "First" && tab.canGoForward }
        XCTAssertEqual(tab.forwardList.map(\.url), [page(titled: "Second")])
        XCTAssertTrue(tab.backList.isEmpty)
    }

    func testReopenedTabRestoresItsHistory() async throws {
        let browser = BrowserModel()
        let tab = try XCTUnwrap(browser.activeTab)
        browser.open(page(titled: "First"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "First" }
        browser.open(page(titled: "Second"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Second" }

        browser.closeTab(tab.id)
        browser.reopenClosedTab()

        let reopened = try XCTUnwrap(browser.activeTab)
        XCTAssertFalse(reopened.isNewTab)
        try await waitUntil { reopened.pageTitle == "Second" && reopened.canGoBack }
    }

    func testPopUpsOpenAsSelectedTabsNextToTheirOpener() async throws {
        let browser = BrowserModel()
        let opener = try XCTUnwrap(browser.activeTab)
        browser.addTab()
        let lastTabID = browser.activeTabID
        browser.activeTabID = opener.id
        browser.open(page(titled: "Opener"))
        try await waitUntil { !opener.isLoading && opener.pageTitle == "Opener" }

        _ = try await opener.webView?.evaluateJavaScript("window.popup = window.open('about:blank'); 0")

        try await waitUntil { browser.tabs.count == 3 }
        let popUp = browser.tabs[1]
        XCTAssertEqual(browser.activeTabID, popUp.id)
        XCTAssertEqual(browser.tabs.last?.id, lastTabID)
        XCTAssertFalse(popUp.isNewTab)
        let hasOpener = try await popUp.webView?.evaluateJavaScript("window.opener !== null") as? Bool
        XCTAssertEqual(hasOpener, true)

        _ = try await opener.webView?.evaluateJavaScript("window.popup.close(); 0")
        try await waitUntil { browser.tabs.count == 2 }
        XCTAssertNil(browser.tab(withID: popUp.id))
    }

    func testChildTabsKeepTheOrderTheyWereOpenedIn() throws {
        let browser = BrowserModel()
        let opener = try XCTUnwrap(browser.activeTab)
        browser.addTab()
        let otherID = browser.activeTabID

        let first = browser.openChildTab(of: opener, loading: URLRequest(url: page(titled: "A")), select: false)
        let second = browser.openChildTab(of: opener, loading: URLRequest(url: page(titled: "B")), select: false)

        XCTAssertEqual(browser.tabs.map(\.id), [opener.id, first.id, second.id, otherID])
        XCTAssertEqual(browser.activeTabID, otherID)
        XCTAssertFalse(first.isNewTab)
    }

    func testClosedTabsAreReleased() async throws {
        let browser = BrowserModel()
        weak var closedTab: BrowserTab?
        weak var closedWebView: WKWebView?
        autoreleasepool {
            browser.addTab()
            browser.activeTab?.restore()
            closedTab = browser.activeTab
            closedWebView = browser.activeTab?.webView
            browser.closeActiveTab()
        }

        XCTAssertNil(closedTab)
        try await waitUntil { closedWebView == nil }
    }
}

@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for condition")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
