import WebKit
import XCTest
@testable import Browser

@MainActor
final class TabSuspensionTests: XCTestCase {
    private func page(titled title: String) -> URL {
        URL(string: "data:text/html,<title>\(title)</title>")!
    }

    private func openLoadedTab(_ browser: BrowserModel, titled title: String) async throws -> BrowserTab {
        browser.open(page(titled: title), inNewTab: true)
        let tab = try XCTUnwrap(browser.activeTab)
        try await waitUntil { !tab.isLoading && tab.pageTitle == title }
        return tab
    }

    func testOnlyIdleBackgroundPagesAreSuspendableLeastRecentlyUsedFirst() async throws {
        let browser = BrowserModel()
        let newTab = try XCTUnwrap(browser.activeTab)
        let first = try await openLoadedTab(browser, titled: "First")
        let second = try await openLoadedTab(browser, titled: "Second")
        let active = try await openLoadedTab(browser, titled: "Active")
        first.lastActive = .now - .seconds(60)
        let loading = browser.openChildTab(of: active, loading: URLRequest(url: page(titled: "Loading")), select: false)

        XCTAssertTrue(loading.isLoading)
        XCTAssertEqual(browser.suspendableTabs.map(\.id), [first.id, second.id])
        XCTAssertFalse(browser.suspendableTabs.contains { $0 === newTab || $0 === active })

        browser.activeTabID = first.id
        XCTAssertGreaterThan(active.lastActive, second.lastActive)
        try await waitUntil { !loading.isLoading }
        XCTAssertEqual(browser.suspendableTabs.map(\.id), [second.id, loading.id, active.id])
    }

    func testPopUpAndOpenerStayLoadedWhileBothAreOpen() async throws {
        let browser = BrowserModel()
        let opener = try await openLoadedTab(browser, titled: "Opener")
        let popUp = browser.openChildTab(of: opener, configuration: BrowserTab.makeConfiguration(), select: false)
        let other = try await openLoadedTab(browser, titled: "Other")
        browser.activeTabID = browser.tabs[0].id

        XCTAssertEqual(browser.suspendableTabs.map(\.id), [other.id])

        browser.closeTab(opener.id)
        XCTAssertTrue(browser.suspendableTabs.contains { $0 === popUp })
    }

    func testSuspendedTabKeepsItsPageAndRestoresHistoryWhenSelected() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "First")
        browser.open(page(titled: "Second"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Second" }
        browser.addTab()

        weak var suspendedWebView: WKWebView?
        autoreleasepool { suspendedWebView = tab.webView }
        await browser.suspendTabs(browser.suspendableTabs)

        XCTAssertTrue(tab.isSuspended)
        XCTAssertTrue(tab.contentView.subviews.isEmpty)
        XCTAssertEqual(tab.pageTitle, "Second")
        XCTAssertEqual(tab.url, page(titled: "Second"))
        XCTAssertTrue(tab.canGoBack)
        try await waitUntil { suspendedWebView == nil }

        browser.activeTabID = tab.id
        XCTAssertFalse(tab.isSuspended)
        XCTAssertEqual(tab.contentView.subviews, [tab.webView].compactMap { $0 })
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Second" && tab.canGoBack }
        XCTAssertEqual(tab.backList.map(\.url), [page(titled: "First")])

        browser.goBack()
        try await waitUntil { tab.pageTitle == "First" && tab.canGoForward }
    }

    func testDuplicateAndReopenRestoreASuspendedTabsHistory() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "First")
        browser.open(page(titled: "Second"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Second" }
        browser.addTab()
        tab.suspend()

        browser.duplicateTab(tab.id)
        let duplicate = try XCTUnwrap(browser.activeTab)
        XCTAssertNotIdentical(duplicate, tab)
        XCTAssertEqual(duplicate.title, "Second")
        try await waitUntil { !duplicate.isLoading && duplicate.pageTitle == "Second" && duplicate.canGoBack }
        XCTAssertTrue(tab.isSuspended)

        browser.closeTab(tab.id)
        browser.reopenClosedTab()
        let reopened = try XCTUnwrap(browser.activeTab)
        XCTAssertFalse(reopened.isNewTab)
        try await waitUntil { !reopened.isLoading && reopened.pageTitle == "Second" && reopened.canGoBack }
    }

    func testBackgroundTabWithCrashedPageRestoresWhenSelected() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Crashed")
        let webView = try XCTUnwrap(tab.webView)
        let pid = webView.responds(to: NSSelectorFromString("_webProcessIdentifier"))
            ? webView.value(forKey: "_webProcessIdentifier") as? pid_t : nil
        guard let pid else { throw XCTSkip("WebKit doesn't expose the page's process") }
        browser.addTab()

        guard kill(pid, SIGKILL) == 0 else {
            throw XCTSkip("The app sandbox does not allow killing WebKit’s process: \(String(cString: strerror(errno)))")
        }

        try await waitUntil { tab.isSuspended }
        browser.activeTabID = tab.id
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Crashed" && !tab.isSuspended }
    }
}
