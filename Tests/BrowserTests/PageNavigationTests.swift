import WebKit
import XCTest
@testable import Browser

@MainActor
final class PageNavigationTests: XCTestCase {
    func testNewAddressInvalidatesAnAwaitingDecisionOnTheSameWebView() throws {
        let browser = BrowserModel()
        let tab = try XCTUnwrap(browser.activeTab)
        tab.restore()
        let view = try XCTUnwrap(tab.webView)
        let pending = PageNavigationRequest(tab: tab, webView: view)
        XCTAssertTrue(pending.isCurrent)

        browser.open(URL(string: "https://navigation-test.invalid/newer")!)

        XCTAssertTrue(tab.webView === view)
        XCTAssertFalse(pending.isCurrent)
        let current = PageNavigationRequest(tab: tab, webView: view)
        XCTAssertTrue(current.isCurrent)
        XCTAssertFalse(pending.isCurrent)
        tab.stopLoading()
    }

    func testClosedTabCannotResumeNavigationEvenWhenItsWebViewIsRetained() throws {
        let browser = BrowserModel()
        let tab = try XCTUnwrap(browser.activeTab)
        tab.restore()
        let view = try XCTUnwrap(tab.webView)
        let pending = PageNavigationRequest(tab: tab, webView: view)

        browser.closeTab(tab.id)

        XCTAssertTrue(tab.webView === view)
        XCTAssertFalse(pending.isCurrent)
    }

    func testClosedAndReopenedWindowRejectsItsOldNavigationDecision() throws {
        let browser = BrowserModel()
        let tab = try XCTUnwrap(browser.activeTab)
        tab.restore()
        let view = try XCTUnwrap(tab.webView)
        let pending = PageNavigationRequest(tab: tab, webView: view)

        browser.windowDidClose()
        XCTAssertFalse(pending.isCurrent)
        XCTAssertNil(ExternalURLRouter.destination(among: [browser]))
        browser.windowDidAppear()

        XCTAssertFalse(pending.isCurrent)
        XCTAssertTrue(PageNavigationRequest(tab: tab, webView: view).isCurrent)
    }
}
