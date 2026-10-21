import AppKit
import WebKit
import XCTest
@testable import Browser

@MainActor
final class PeekSplitTests: XCTestCase {
    func testSplitAdoptsBothLivePagesAndPreservesInputScrollHistoryAndPrivateStore() async throws {
        for isPrivate in [false, true] {
            let store = WKWebsiteDataStore.nonPersistent()
            let browser = BrowserModel(websiteDataStore: store, isPrivate: isPrivate)
            let other = BrowserModel(websiteDataStore: .nonPersistent(), isPrivate: isPrivate)
            let source = try XCTUnwrap(browser.activeTab)
            let sourceView = try await loadPage("Source", in: source)
            let sourceState = try await pageState(in: sourceView)
            let sourceBackList = sourceView.backForwardList.backList
            let sourceItem = sourceView.backForwardList.currentItem
            let tab = browser.openPeek(from: source)
            let view = try await loadPage("Peek", in: tab)
            let state = try await pageState(in: view)
            let backList = view.backForwardList.backList
            let currentItem = view.backForwardList.currentItem
            let sourceRevision = source.navigationRevision
            let peekRevision = tab.navigationRevision
            let peekID = try XCTUnwrap(browser.peek).id
            let scriptController = view.configuration.userContentController

            XCTAssertNil(browser.peekSplitUnavailableReason(for: peekID))
            XCTAssertTrue(browser.splitPeek(id: peekID))
            XCTAssertNil(browser.peek)
            XCTAssertEqual(browser.tabs.map(\.id), [source.id, tab.id])
            XCTAssertTrue(browser.tabs.first === source)
            XCTAssertTrue(browser.tabs.last === tab)
            XCTAssertTrue(browser.activeTab === tab)
            XCTAssertTrue(browser.focusedPage === tab)
            XCTAssertTrue(source.webView === sourceView)
            XCTAssertTrue(tab.webView === view)
            XCTAssertTrue(view.configuration.userContentController === scriptController)
            XCTAssertTrue(view.configuration.websiteDataStore === sourceView.configuration.websiteDataStore)
            XCTAssertTrue(view.configuration.websiteDataStore === store)
            XCTAssertFalse(view.configuration.websiteDataStore === other.websiteDataStore)
            XCTAssertEqual(source.navigationRevision, sourceRevision, "No source navigation or suspension")
            XCTAssertEqual(tab.navigationRevision, peekRevision, "Adopt, do not dismiss, stop, suspend, or reload")
            let group = try XCTUnwrap(browser.activeSplit)
            XCTAssertEqual(group.tabIDs, [source.id, tab.id])
            XCTAssertEqual(group.anchorID, source.id)
            XCTAssertEqual(group.focusedID, tab.id)
            XCTAssertEqual(group.orientation, .horizontal)
            XCTAssertEqual(group.weights, [0.5, 0.5])
            XCTAssertEqual(browser.visibleTabIDs, [source.id, tab.id])
            XCTAssertEqual(SplitTabGroup.limit, 2)
            XCTAssertEqual(sourceView.backForwardList.backList, sourceBackList)
            XCTAssertTrue(sourceView.backForwardList.currentItem === sourceItem)
            XCTAssertEqual(view.backForwardList.backList, backList)
            XCTAssertTrue(view.backForwardList.currentItem === currentItem)
            let afterSource = try await pageState(in: sourceView)
            let afterPeek = try await pageState(in: view)
            XCTAssertEqual(afterSource, sourceState)
            XCTAssertEqual(afterPeek, state)
            let selected = await tab.waitUntilSelected()
            XCTAssertTrue(selected)
            XCTAssertNil(other.activeTab?.webView, "Do not borrow or load a different browsing context")
            XCTAssertFalse(browser.splitPeek(id: peekID), "A consumed action cannot adopt the page twice")
            XCTAssertEqual(browser.tabs.count, 2)
            let snapshot = BrowserSessionSnapshot(browser: browser)
            XCTAssertEqual(snapshot.tabs.count, 2)
            XCTAssertEqual(snapshot.splits?.count, 1)
        }
    }

    func testExistingSourceSplitIsDisabledWithExplanationAndLeavesAllWorkIntact() async throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        let sourceView = try await loadPage("Source", in: source)
        browser.addTab(focusAddress: false)
        let companion = try XCTUnwrap(browser.activeTab)
        let companionView = try await loadPage("Companion", in: companion)
        XCTAssertTrue(browser.makeSplit(companion.id, with: source.id, orientation: .vertical))
        let tab = browser.openPeek(from: source)
        let view = try await loadPage("Peek", in: tab)
        let peek = try XCTUnwrap(browser.peek)
        let originalSplits = browser.splits
        let originalTabs = browser.tabs.map(\.id)
        let revision = tab.navigationRevision

        let reason = try XCTUnwrap(browser.peekSplitUnavailableReason(for: peek.id))
        XCTAssertTrue(reason.contains("two panes"))
        XCTAssertTrue(reason.contains("Separate"))
        XCTAssertFalse(browser.splitPeek(id: peek.id))
        XCTAssertEqual(browser.peek?.id, peek.id)
        XCTAssertTrue(browser.peek?.tab === tab)
        XCTAssertEqual(browser.tabs.map(\.id), originalTabs)
        XCTAssertEqual(browser.splits, originalSplits)
        XCTAssertEqual(browser.activeTabID, source.id)
        XCTAssertTrue(source.webView === sourceView)
        XCTAssertTrue(companion.webView === companionView)
        XCTAssertTrue(tab.webView === view)
        XCTAssertEqual(tab.navigationRevision, revision, "A rejected action must not close the Peek")
        browser.dismissPeek()
    }

    func testSuccessfulSplitPreservesAnUnrelatedSplit() async throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        _ = try await loadPage("Source", in: source)
        browser.addTab(focusAddress: false)
        let first = try XCTUnwrap(browser.activeTab)
        browser.addTab(focusAddress: false)
        let second = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(browser.makeSplit(second.id, with: first.id, orientation: .vertical))
        let unrelated = try XCTUnwrap(browser.activeSplit)
        browser.activeTabID = source.id
        let tab = browser.openPeek(from: source)
        _ = try await loadPage("Peek", in: tab)
        XCTAssertTrue(browser.splitPeek())
        XCTAssertEqual(browser.splits.count, 2)
        XCTAssertEqual(browser.split(containing: first.id), unrelated)
        XCTAssertEqual(browser.activeSplit?.tabIDs, [source.id, tab.id])
        XCTAssertEqual(browser.tabs.count, 4)
    }

    func testSourceNavigationInvalidatesSplitWithoutClosingPeek() async throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        _ = try await loadPage("Source", in: source)
        let tab = browser.openPeek(from: source)
        _ = try await loadPage("Peek", in: tab)
        source.invalidateNavigation()
        try assertRejected(browser)
        browser.dismissPeek()
    }

    func testReplacedSourceOrPeekWebViewIsRejectedWithoutMutatingWork() throws {
        for replacingSource in [false, true] {
            let browser = BrowserModel(isPrivate: true)
            let source = try XCTUnwrap(browser.activeTab)
            source.isNewTab = false
            source.restore()
            let tab = browser.openPeek(from: source)
            let old = try XCTUnwrap(replacingSource ? source.webView : tab.webView)
            let replaced = replacingSource ? source : tab
            replaced.suspend()
            replaced.restore()
            XCTAssertFalse(replaced.webView === old)
            try assertRejected(browser)
            browser.dismissPeek()
        }
    }

    func testForeignSourceOrPeekOwnerCannotBorrowTheActivePrivateContext() throws {
        for changingSource in [false, true] {
            let browser = BrowserModel(websiteDataStore: .nonPersistent(), isPrivate: true)
            let other = BrowserModel(websiteDataStore: .nonPersistent(), isPrivate: true)
            let source = try XCTUnwrap(browser.activeTab)
            source.restore()
            let tab = browser.openPeek(from: source)
            let changed = changingSource ? source : tab
            changed.browser = other
            try assertRejected(browser)
            XCTAssertEqual(other.tabs.count, 1)
            XCTAssertNil(other.activeTab?.webView)
            changed.browser = browser
            browser.dismissPeek()
        }
    }

    func testClosedSourceDoesNotGetReinsertedOrDismissAnOrphanPeek() throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        source.restore()
        browser.closeTab(source.id)
        browser.openPeek(from: source)
        try assertRejected(browser)
        XCTAssertFalse(browser.tabs.contains { $0 === source })
        browser.dismissPeek()
    }

    func testClosedWindowAndChangedWindowContextAreRejected() throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        source.restore()
        browser.windowDidClose()
        browser.openPeek(from: source)
        try assertRejected(browser)
        browser.dismissPeek()
        browser.windowDidAppear()
        browser.openPeek(from: source)
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        browser.window = window
        try assertRejected(browser)
        browser.dismissPeek()
    }

    func testStaleControlIDLeavesTheNewPeekOpenAndNoCapturedSourceFailsClosed() throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        source.restore()
        browser.openPeek(from: source)
        let oldID = try XCTUnwrap(browser.peek).id
        let current = browser.openPeek(from: source)
        let currentID = try XCTUnwrap(browser.peek).id
        XCTAssertNotNil(browser.peekSplitUnavailableReason(for: oldID))
        XCTAssertFalse(browser.splitPeek(id: oldID))
        XCTAssertEqual(browser.peek?.id, currentID)
        XCTAssertTrue(browser.peek?.tab === current)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.splits.isEmpty)
        let uncaptured = PeekPage(openerID: source.id, tab: current)
        XCTAssertNil(uncaptured.sourceForSplit(in: browser))
        browser.dismissPeek()
    }

    private func assertRejected(_ browser: BrowserModel, file: StaticString = #filePath, line: UInt = #line) throws {
        let peek = try XCTUnwrap(browser.peek, file: file, line: line)
        let tabs = browser.tabs.map(\.id), splits = browser.splits
        let sourceID = browser.activeTabID
        let view = peek.tab.webView
        let revision = peek.tab.navigationRevision
        XCTAssertNotNil(browser.peekSplitUnavailableReason(for: peek.id), file: file, line: line)
        XCTAssertFalse(browser.splitPeek(id: peek.id), file: file, line: line)
        XCTAssertEqual(browser.peek?.id, peek.id, file: file, line: line)
        XCTAssertTrue(browser.peek?.tab === peek.tab, file: file, line: line)
        XCTAssertTrue(peek.tab.webView === view, file: file, line: line)
        XCTAssertEqual(peek.tab.navigationRevision, revision, file: file, line: line)
        XCTAssertEqual(browser.tabs.map(\.id), tabs, file: file, line: line)
        XCTAssertEqual(browser.splits, splits, file: file, line: line)
        XCTAssertEqual(browser.activeTabID, sourceID, file: file, line: line)
    }

    private func loadPage(_ title: String, in tab: BrowserTab) async throws -> WKWebView {
        tab.isNewTab = false
        tab.contentView.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        tab.restore()
        let view = try XCTUnwrap(tab.webView)
        view.frame = tab.contentView.bounds
        view.loadHTMLString("<title>\(title)</title><input id='entry'><div style='height:4000px'>Scrollable content</div>",
                            baseURL: URL(string: "https://peek-split.invalid/\(title)"))
        for _ in 0..<200 where tab.pageTitle != title || tab.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(tab.pageTitle, title)
        try await view.evaluateJavaScript("""
            window.keepMe = '\(title) state';
            document.getElementById('entry').value = '\(title) input';
            history.pushState({}, '', '#one'); history.pushState({}, '', '#two');
            window.scrollTo(0, 180);
            """)
        let position = try await view.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertGreaterThan(position ?? 0, 0)
        return view
    }

    private func pageState(in view: WKWebView) async throws -> String {
        let state = try await view.evaluateJavaScript("""
            JSON.stringify({ input: document.getElementById('entry').value, state: window.keepMe,
                scroll: window.scrollY, history: history.length, url: location.href, title: document.title });
            """) as? String
        return try XCTUnwrap(state)
    }
}
