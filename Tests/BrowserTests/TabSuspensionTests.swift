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

    /// Hold the first media reply so changes run across a real suspension point.
    private func duringMediaCheck(_ browser: BrowserModel, candidates: [BrowserTab],
                                  change: (WKWebView) async throws -> Void) async throws {
        var source: WKWebView?
        var reply: CheckedContinuation<WKMediaPlaybackState, Never>?
        var queried = false
        let task = Task {
            await browser.suspendTabs(candidates) { view in
                guard !queried else { return .none }
                queried = true
                source = view
                return await withCheckedContinuation { reply = $0 }
            }
        }
        defer {
            task.cancel()
            reply?.resume(returning: .none)
        }
        try await waitUntil { reply != nil }
        try await change(XCTUnwrap(source))
        reply?.resume(returning: .none)
        reply = nil
        await task.value
    }

    func testWindowWideOrderIncludesLoadedInactiveSpaceWithoutRestoringOtherTabs() async throws {
        let browser = BrowserModel()
        let initialBlank = try XCTUnwrap(browser.tabs.first)
        let inactive = try await openLoadedTab(browser, titled: "Inactive")
        let dormant = try await openLoadedTab(browser, titled: "Dormant")
        dormant.suspend()
        _ = try browser.createSpace(title: "Work")
        let current = try await openLoadedTab(browser, titled: "Current")
        browser.addTab()
        let selected = browser.activeTabID
        let currentSpaceID = browser.activeSpaceID
        let time = ContinuousClock.now - .seconds(60)
        inactive.lastActive = time
        current.lastActive = time

        XCTAssertNil(browser.tab(withID: inactive.id))
        XCTAssertIdentical(browser.tabAcrossSpaces(withID: inactive.id), inactive)
        XCTAssertTrue(browser.canSuspendTab(inactive))
        let candidates = browser.suspendableTabs
        XCTAssertEqual(candidates.map(\.id), [inactive.id, current.id])
        XCTAssertNil(initialBlank.webView)
        XCTAssertNil(dormant.webView)
        await browser.suspendTabs(candidates) { _ in .none }

        XCTAssertTrue(inactive.isSuspended)
        XCTAssertTrue(current.isSuspended)
        XCTAssertNil(initialBlank.webView)
        XCTAssertNil(dormant.webView)
        XCTAssertEqual(browser.activeSpaceID, currentSpaceID)
        XCTAssertEqual(browser.activeTabID, selected)
    }

    func testOnlyActiveSpacesVisibleSplitIsProtectedFromWindowWidePass() async throws {
        let browser = BrowserModel()
        let inactiveFirst = try await openLoadedTab(browser, titled: "InactiveFirst")
        let inactiveSecond = try await openLoadedTab(browser, titled: "InactiveSecond")
        XCTAssertTrue(browser.makeSplit(inactiveFirst.id, with: inactiveSecond.id))
        _ = try browser.createSpace(title: "Work")
        let visibleFirst = try await openLoadedTab(browser, titled: "VisibleFirst")
        let visibleSecond = try await openLoadedTab(browser, titled: "VisibleSecond")
        XCTAssertTrue(browser.makeSplit(visibleFirst.id, with: visibleSecond.id))

        XCTAssertEqual(browser.visibleTabIDs, [visibleFirst.id, visibleSecond.id])
        XCTAssertEqual(Set(browser.suspendableTabs.map(\.id)), [inactiveFirst.id, inactiveSecond.id])
        await browser.suspendTabs(browser.allTabs) { _ in .none }

        XCTAssertTrue(inactiveFirst.isSuspended)
        XCTAssertTrue(inactiveSecond.isSuspended)
        XCTAssertFalse(visibleFirst.isSuspended)
        XCTAssertFalse(visibleSecond.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(visibleFirst))
        XCTAssertFalse(browser.canSuspendTab(visibleSecond))
    }

    func testPopupCreatedInInactiveSpaceDuringMediaQueryProtectsBothPagesUntilClosure() async throws {
        let browser = BrowserModel()
        let opener = try await openLoadedTab(browser, titled: "Opener")
        let currentSpace = try browser.createSpace(title: "Work")
        var popup: BrowserTab?

        try await duringMediaCheck(browser, candidates: [opener]) { _ in
            popup = browser.openChildTab(of: opener, configuration: BrowserTab.makeConfiguration(), select: false)
        }

        let child = try XCTUnwrap(popup)
        XCTAssertEqual(child.spaceID, opener.spaceID)
        XCTAssertNil(browser.tab(withID: child.id))
        XCTAssertFalse(opener.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(opener))
        XCTAssertFalse(browser.canSuspendTab(child))
        XCTAssertFalse(browser.suspendableTabs.contains { $0 === opener || $0 === child })
        browser.closeTab(opener.id)
        XCTAssertNil(browser.tabAcrossSpaces(withID: opener.id))
        XCTAssertTrue(browser.canSuspendTab(child))
        XCTAssertTrue(browser.suspendableTabs.contains { $0 === child })
        await browser.suspendTabs([child]) { _ in .none }
        XCTAssertTrue(child.isSuspended)
        XCTAssertEqual(browser.activeSpaceID, currentSpace.id)
    }

    func testSpaceSwitchDuringMediaQueryProtectsNewlyVisibleTab() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Selected")
        _ = try browser.createSpace(title: "Work")

        try await duringMediaCheck(browser, candidates: [tab]) { source in
            XCTAssertTrue(browser.selectSpace(tab.spaceID))
            XCTAssertIdentical(browser.activeTab, tab)
            XCTAssertIdentical(tab.webView, source)
        }

        XCTAssertFalse(tab.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(tab))
    }

    func testReorderedCandidateStaysEligibleButInactiveClosureInvalidatesMembership() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Moving")
        browser.addTab()
        let destination = browser.tabs.count - 1

        try await duringMediaCheck(browser, candidates: [tab]) { source in
            XCTAssertTrue(browser.moveTab(tab.id, to: destination))
            XCTAssertTrue(browser.canSuspendTab(tab))
            _ = try browser.createSpace(title: "Work")
            XCTAssertTrue(browser.canSuspendTab(tab))
            browser.closeTab(tab.id)
            XCTAssertNil(browser.tabAcrossSpaces(withID: tab.id))
            XCTAssertIdentical(tab.webView, source)
            XCTAssertFalse(browser.canSuspendTab(tab))
        }

        XCTAssertFalse(tab.isSuspended)
        var queries = 0
        await browser.suspendTabs([tab]) { _ in queries += 1; return .none }
        XCTAssertEqual(queries, 0)
    }

    func testReplacedDescriptorWithSameIDDoesNotKeepOldObjectEligible() async throws {
        let browser = BrowserModel()
        let old = try await openLoadedTab(browser, titled: "Old")
        _ = try browser.createSpace(title: "Work")

        try await duringMediaCheck(browser, candidates: [old]) { source in
            let replacement = TabSession(url: nil, title: "", interactionState: nil, id: old.id)
            browser.restoreSession(WindowSession(tabs: [replacement], selectedIndex: 0))
            XCTAssertNotIdentical(browser.tabAcrossSpaces(withID: old.id), old)
            XCTAssertIdentical(old.webView, source)
            XCTAssertFalse(browser.canSuspendTab(old))
        }

        XCTAssertFalse(old.isSuspended)
    }

    func testSelectionDuringMediaQueryProtectsSelectedTabButContinuesPass() async throws {
        let browser = BrowserModel()
        let first = try await openLoadedTab(browser, titled: "First")
        let second = try await openLoadedTab(browser, titled: "Second")
        browser.addTab()

        try await duringMediaCheck(browser, candidates: browser.suspendableTabs) { _ in
            browser.activeTabID = first.id
        }

        XCTAssertFalse(first.isSuspended)
        XCTAssertTrue(second.isSuspended)
    }

    func testClosedTabIsNotSuspendedAfterMediaQuery() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Closing")
        browser.addTab()

        try await duringMediaCheck(browser, candidates: [tab]) { source in
            browser.closeTab(tab.id)
            XCTAssertIdentical(tab.webView, source)
        }

        XCTAssertNotNil(tab.webView)
        XCTAssertFalse(browser.canSuspendTab(tab))
    }

    func testClosedAndSuspendedCandidatesSkipMediaQuery() async throws {
        let browser = BrowserModel()
        let closed = try await openLoadedTab(browser, titled: "Closed")
        let suspended = try await openLoadedTab(browser, titled: "Suspended")
        browser.addTab()
        browser.closeTab(closed.id)
        suspended.suspend()
        var queries = 0

        await browser.suspendTabs([closed, suspended]) { _ in
            queries += 1
            return .none
        }

        XCTAssertEqual(queries, 0)
        XCTAssertFalse(closed.isSuspended)
        XCTAssertTrue(suspended.isSuspended)
    }

    func testSuspensionDuringMediaQueryDoesNotRestoreOrQueryAgain() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Suspending")
        browser.addTab()

        try await duringMediaCheck(browser, candidates: [tab, tab]) { _ in tab.suspend() }

        XCTAssertTrue(tab.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(tab))
    }

    func testReplacementWebViewRejectsOldMediaReply() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Restored")
        browser.addTab()

        try await duringMediaCheck(browser, candidates: [tab]) { source in
            tab.suspend()
            tab.restore()
            try await waitUntil { !tab.isLoading && tab.pageTitle == "Restored" }
            XCTAssertNotIdentical(tab.webView, source)
            XCTAssertTrue(browser.canSuspendTab(tab))
        }

        XCTAssertFalse(tab.isSuspended)
    }

    func testNavigationOnSameWebViewRejectsOldMediaReply() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Before")
        browser.addTab()

        try await duringMediaCheck(browser, candidates: [tab]) { source in
            tab.invalidateNavigation()
            source.load(URLRequest(url: self.page(titled: "After")))
            try await waitUntil { !tab.isLoading && tab.pageTitle == "After" }
            XCTAssertIdentical(tab.webView, source)
            XCTAssertTrue(browser.canSuspendTab(tab))
        }

        XCTAssertFalse(tab.isSuspended)
    }

    func testNewPopupProtectsOpenerDuringMediaQuery() async throws {
        let browser = BrowserModel()
        let opener = try await openLoadedTab(browser, titled: "Opener")
        browser.addTab()

        try await duringMediaCheck(browser, candidates: [opener]) { _ in
            browser.openChildTab(of: opener, configuration: BrowserTab.makeConfiguration(), select: false)
        }

        XCTAssertFalse(opener.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(opener))
        XCTAssertFalse(browser.suspendableTabs.contains { $0 === opener })
    }

    func testChangedPopupRelationProtectsChildUntilOpenerCloses() async throws {
        let browser = BrowserModel()
        let opener = try await openLoadedTab(browser, titled: "Opener")
        let child = browser.openChildTab(of: opener, loading: URLRequest(url: page(titled: "Child")), select: false)
        try await waitUntil { !child.isLoading && child.pageTitle == "Child" }
        browser.addTab()

        try await duringMediaCheck(browser, candidates: [child]) { _ in child.isPopUp = true }

        XCTAssertFalse(child.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(child))
        browser.closeTab(opener.id)
        XCTAssertTrue(browser.canSuspendTab(child))
        await browser.suspendTabs([child]) { _ in .none }
        XCTAssertTrue(child.isSuspended)
    }

    func testVisibleSplitCompanionIsProtectedDuringMediaQuery() async throws {
        let browser = BrowserModel()
        let companion = try await openLoadedTab(browser, titled: "Companion")
        let focused = try await openLoadedTab(browser, titled: "Focused")

        try await duringMediaCheck(browser, candidates: [companion]) { _ in
            XCTAssertTrue(browser.makeSplit(companion.id, with: focused.id))
            XCTAssertEqual(browser.activeTabID, focused.id)
        }

        XCTAssertFalse(companion.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(companion))
        XCTAssertFalse(browser.canSuspendTab(focused))
        browser.addTab()
        XCTAssertEqual(Set(browser.suspendableTabs.map(\.id)), [companion.id, focused.id])
    }

    func testErrorAndSelectionWaitersAreRecheckedAfterMediaQuery() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Protected")
        browser.addTab()
        let error = try XCTUnwrap(PageLoadError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), url: tab.url))
        try await duringMediaCheck(browser, candidates: [tab]) { _ in
            tab.showLoadError(error, coversPreviousPage: true)
        }
        XCTAssertFalse(tab.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(tab))
        tab.clearLoadError()

        var waiter: Task<Bool, Never>?
        defer { tab.stopWaitingForSelection() }
        try await duringMediaCheck(browser, candidates: [tab]) { _ in
            waiter = Task { await tab.waitUntilSelected() }
            try await waitUntil { !tab.canSuspend }
        }
        XCTAssertFalse(tab.isSuspended)
        XCTAssertFalse(browser.canSuspendTab(tab))
        tab.stopWaitingForSelection()
        let selected = await (try XCTUnwrap(waiter)).value
        XCTAssertFalse(selected)
        XCTAssertTrue(browser.canSuspendTab(tab))
    }

    func testInspectorAndCaptureGuardsIncludeMutedCameraAndMicrophone() {
        let states: [WKMediaCaptureState] = [.none, .active, .muted]
        for isInspecting in [false, true] {
            for camera in states {
                for microphone in states {
                    XCTAssertEqual(BrowserTab.permitsSuspension(isInspecting: isInspecting, camera: camera, microphone: microphone),
                                   !isInspecting && camera == .none && microphone == .none)
                }
            }
        }
    }

    func testLoadingStartedDuringMediaQueryKeepsPageLoaded() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Before")
        browser.addTab()

        try await duringMediaCheck(browser, candidates: [tab]) { source in
            source.load(URLRequest(url: self.page(titled: "Loading")))
            XCTAssertTrue(tab.isLoading)
            XCTAssertFalse(browser.canSuspendTab(tab))
        }

        XCTAssertFalse(tab.isSuspended)
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Loading" }
    }

    func testLRUTiesUseTabOrderAndMediaRepliesDoNotReorderPass() async throws {
        let browser = BrowserModel()
        let first = try await openLoadedTab(browser, titled: "First")
        let second = try await openLoadedTab(browser, titled: "Second")
        let third = try await openLoadedTab(browser, titled: "Third")
        browser.addTab()
        let time = ContinuousClock.now - .seconds(60)
        [first, second, third].forEach { $0.lastActive = time }
        let candidates = browser.suspendableTabs
        XCTAssertEqual(candidates.map(\.id), [first.id, second.id, third.id])
        var queries: [WKWebView] = []
        let sources = try [first, second, third].map { try XCTUnwrap($0.webView) }

        await browser.suspendTabs(candidates) { source in
            queries.append(source)
            third.lastActive = time - .seconds(60)
            if source === sources[0] { return .playing }
            return source === sources[1] ? .paused : .none
        }

        XCTAssertEqual(queries, sources)
        XCTAssertFalse(first.isSuspended)
        XCTAssertTrue(second.isSuspended)
        XCTAssertTrue(third.isSuspended)
    }

    func testCancelledPassDoesNotSuspendOrQueryRemainingTabs() async throws {
        let browser = BrowserModel()
        let tab = try await openLoadedTab(browser, titled: "Cancelled")
        browser.addTab()
        var queries = 0
        let task = Task {
            await browser.suspendTabs([tab, tab]) { _ in
                queries += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return .none
            }
        }
        await task.value
        XCTAssertEqual(queries, 1)
        XCTAssertFalse(tab.isSuspended)
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
