import AppKit
import XCTest
@testable import Browser

@MainActor
final class PageAttachmentTests: XCTestCase {
    func testLoadedSelectionAttachesBeforeReturningWithoutReplacingWebViews() throws {
        let (browser, first, second, host, window) = try fixture()
        defer { window.close() }
        let firstWebView = try XCTUnwrap(first.webView)
        let secondWebView = try XCTUnwrap(second.webView)

        browser.activeTabID = second.id
        XCTAssertTrue(second.contentView.superview === host)
        XCTAssertNil(first.contentView.superview)
        browser.activeTabID = first.id
        XCTAssertTrue(first.contentView.superview === host)
        XCTAssertNil(second.contentView.superview)
        XCTAssertTrue(first.webView === firstWebView)
        XCTAssertTrue(second.webView === secondWebView)
    }

    func testStructuralAndFindTransitionsWaitForSwiftUI() throws {
        let (browser, first, second, host, window) = try fixture()
        defer { window.close() }
        first.isFindBarVisible = true
        browser.activeTabID = second.id
        XCTAssertTrue(first.contentView.superview === host)
        XCTAssertNil(second.contentView.superview)
        first.isFindBarVisible = false
        browser.activeTabID = first.id
        browser.addTab(focusAddress: false)
        XCTAssertTrue(first.contentView.superview === host, "New Tab replaces the page structure through SwiftUI")
        browser.activeTabID = first.id
        XCTAssertTrue(browser.makeSplit(first.id, with: second.id))
        browser.activeTabID = first.id
        XCTAssertTrue(first.contentView.superview === host, "Split panes must keep their separate native hosts")
    }

    func testSelectionDoesNotStealAViewFromAnotherWindow() throws {
        let (browser, first, second, host, window) = try fixture()
        defer { window.close() }
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        browser.window = other
        browser.activeTabID = second.id
        XCTAssertTrue(first.contentView.superview === host)
        XCTAssertNil(second.contentView.superview)
    }

    func testSelectionLeavesDestinationOwnedByAnotherWindowAlone() throws {
        let (browser, first, second, host, window) = try fixture()
        defer { window.close() }
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.contentView = second.contentView
        browser.activeTabID = second.id
        XCTAssertTrue(first.contentView.superview === host)
        XCTAssertTrue(second.contentView.window === other)
    }

    func testSuspendedSelectionAttachesItsRestoredView() throws {
        let (browser, first, second, host, window) = try fixture()
        defer { window.close() }
        let oldView = try XCTUnwrap(second.webView)
        second.suspend()
        XCTAssertNil(second.webView)
        browser.activeTabID = second.id
        XCTAssertNotNil(second.webView)
        XCTAssertFalse(second.webView === oldView)
        XCTAssertTrue(second.contentView.superview === host)
        XCTAssertNil(first.contentView.superview)
    }

    private func fixture() throws -> (BrowserModel, BrowserTab, BrowserTab, PageHostView, NSWindow) {
        let browser = BrowserModel()
        let first = try XCTUnwrap(browser.activeTab)
        browser.addTab(focusAddress: false)
        let second = try XCTUnwrap(browser.activeTab)
        for tab in [first, second] { tab.isNewTab = false; tab.restore() }
        browser.activeTabID = first.id
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = PageHostView()
        window.contentView = host
        host.show(first.contentView)
        browser.window = window
        return (browser, first, second, host, window)
    }
}
