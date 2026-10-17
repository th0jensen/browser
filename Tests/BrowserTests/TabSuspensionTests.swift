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

    func testSameDocumentNavigationRefreshesHistoryWithoutLoading() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Before")
        browser.open(page(titled: "History"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "History" }
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertEqual(tab.backList.map(\.url), [page(titled: "Before")])

        // WebKit may omit script-created entries from its native history menu and skip them during native
        // back/forward navigation. Mirror the public list rather than assuming every pushState is visible.
        func waitForHistory(at url: URL) async throws {
            try await waitUntil {
                !tab.isLoading && tab.url == url && tab.backList == webView.backForwardList.backList
                    && tab.forwardList == webView.backForwardList.forwardList
            }
            XCTAssertFalse(tab.isLoading)
            XCTAssertEqual(tab.canGoBack, webView.canGoBack)
            XCTAssertEqual(tab.canGoForward, webView.canGoForward)
        }

        let firstState = try XCTUnwrap(URL(string: page(titled: "History").absoluteString + "#one"))
        let secondState = try XCTUnwrap(URL(string: page(titled: "History").absoluteString + "#two"))
        _ = try await webView.evaluateJavaScript("history.pushState({}, '', '#one'); 0")
        try await waitForHistory(at: firstState)
        _ = try await webView.evaluateJavaScript("history.pushState({}, '', '#two'); 0")
        try await waitForHistory(at: secondState)

        // JavaScript history traversal reaches the individual same-document entries on every SDK.
        _ = try await webView.evaluateJavaScript("history.back(); 0")
        try await waitForHistory(at: firstState)
        _ = try await webView.evaluateJavaScript("history.forward(); 0")
        try await waitForHistory(at: secondState)

        let nativeBackURL = try XCTUnwrap(webView.backForwardList.backItem?.url)
        browser.goBack()
        try await waitForHistory(at: nativeBackURL)
    }
}

final class ThumbnailCaptureStateTests: XCTestCase {
    func testThumbnailCaptureAllowsOnlyOneSnapshotAtATime() throws {
        var state = ThumbnailCaptureState()
        let request = try XCTUnwrap(state.begin(minimumAge: .zero))
        XCTAssertNil(state.begin(minimumAge: .zero))
        XCTAssertTrue(state.isCapturing)

        XCTAssertTrue(state.complete(request, capturedImage: true))
        XCTAssertFalse(state.isCapturing)
        XCTAssertNotNil(state.begin(minimumAge: .zero))
    }

    func testNavigationRejectsOldSnapshotEvenWhenURLIsUnchanged() throws {
        var state = ThumbnailCaptureState()
        let request = try XCTUnwrap(state.begin(minimumAge: .zero))
        state.invalidate()

        XCTAssertNil(state.begin(minimumAge: .zero))
        XCTAssertFalse(state.complete(request, capturedImage: true))
        XCTAssertNotNil(state.begin(minimumAge: .seconds(2)))
    }

    func testRecentSnapshotSkipsRapidTabSwitchesButNotFreshNavigation() throws {
        var state = ThumbnailCaptureState()
        let now = ContinuousClock.now
        let request = try XCTUnwrap(state.begin(minimumAge: .zero, now: now))
        XCTAssertTrue(state.complete(request, capturedImage: true, now: now))

        XCTAssertNil(state.begin(minimumAge: .seconds(2), now: now + .seconds(1)))
        let agedRequest = try XCTUnwrap(state.begin(minimumAge: .seconds(2), now: now + .seconds(2)))
        XCTAssertTrue(state.complete(agedRequest, capturedImage: true, now: now + .seconds(2)))
        state.invalidate()
        XCTAssertNotNil(state.begin(minimumAge: .seconds(2), now: now + .seconds(2)))
    }

    func testFailedSnapshotCanRetryImmediately() throws {
        var state = ThumbnailCaptureState()
        let request = try XCTUnwrap(state.begin(minimumAge: .zero))
        XCTAssertFalse(state.complete(request, capturedImage: false))
        XCTAssertNotNil(state.begin(minimumAge: .seconds(2)))
    }

    func testSuspensionDropsCaptureAndLateCompletionCannotFinishRestoredCapture() throws {
        var state = ThumbnailCaptureState()
        let oldRequest = try XCTUnwrap(state.begin(minimumAge: .zero))
        state.invalidate(cancelCapture: true)
        let restoredRequest = try XCTUnwrap(state.begin(minimumAge: .zero))

        XCTAssertFalse(state.complete(oldRequest, capturedImage: true))
        XCTAssertTrue(state.isCapturing)
        XCTAssertTrue(state.complete(restoredRequest, capturedImage: true))
    }
}
