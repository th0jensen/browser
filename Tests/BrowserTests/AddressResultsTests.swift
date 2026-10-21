import AppKit
import XCTest
import WebKit
@testable import Browser

@MainActor
final class AddressResultsTests: XCTestCase {
    private func browser(history: HistoryStore? = nil) -> BrowserModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "AddressResults-\(UUID())")
        return BrowserModel(history: history, websiteDataStore: .nonPersistent(),
                            spaces: BrowserSpaceStore(directory: root, enabled: false))
    }

    private func result(_ query: String, in browser: BrowserModel,
                        matching predicate: (AddressResult.Action) -> Bool) throws -> AddressResult {
        try XCTUnwrap(AddressResults.results(for: query, browser: browser, bookmarks: []).first { predicate($0.action) })
    }

    func testDirectSpaceResultHasStableIdentityAndPreservesExistingTabs() throws {
        let browser = browser()
        let source = try XCTUnwrap(browser.activeTab)
        let destination = try browser.createSpace(title: "Research")
        let target = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(browser.selectSpace(source.spaceID))
        let count = browser.allTabs.count
        let revision = source.navigationRevision
        let first = try result("Research", in: browser) { if case .switchSpace = $0 { true } else { false } }
        let second = try result("Research", in: browser) { if case .switchSpace = $0 { true } else { false } }
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.actionLabel, "Switch Space")
        XCTAssertEqual(first.editorText, "Research")
        XCTAssertEqual(first.destinationSpace, "Research")
        XCTAssertNil(first.completionSuggestion)
        XCTAssertTrue(browser.activeTab === source, "Ranking must not select the destination")
        XCTAssertTrue(AddressResults.execute(first, in: browser, inNewTab: true))
        XCTAssertEqual(browser.activeSpaceID, destination.id)
        XCTAssertTrue(browser.activeTab === target)
        XCTAssertEqual(browser.allTabs.count, count)
        XCTAssertEqual(source.navigationRevision, revision)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
        let peek = browser.openPeek(from: target)
        XCTAssertTrue(browser.focusedPage === peek)
        XCTAssertTrue(AddressResults.execute(first, in: browser))
        XCTAssertNil(browser.peek, "An accepted current-Space action must also leave the ordinary destination focused")
        XCTAssertTrue(browser.focusedPage === target)
        XCTAssertEqual(browser.allTabs.count, count)
    }

    func testSpaceNameExactMatchWinsWithinBoundedStableResults() throws {
        let browser = browser()
        for index in 0..<20 { _ = try browser.spaces.createSpace(title: "Work \(index)") }
        let exact = try browser.spaces.createSpace(title: "Work")
        let results = AddressResults.results(for: "Work", browser: browser, bookmarks: [])
        XCTAssertEqual(results.first?.action, .switchSpace(.init(id: exact.id, profileID: exact.profileID)))
        XCTAssertLessThanOrEqual(results.count, AddressResults.limit)
        XCTAssertEqual(results.map(\.id), AddressResults.results(for: "Work", browser: browser, bookmarks: []).map(\.id))
        XCTAssertEqual(browser.allTabs.count, 1)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testUnvisitedSpaceSelectionDoesNotCreateATabAndExplicitNavigationStillWorks() throws {
        let browser = browser()
        let source = try XCTUnwrap(browser.activeTab)
        let destination = try browser.spaces.createSpace(title: "Unvisited")
        let focusRequest = browser.addressFocusRequest
        let result = try result("Unvisited", in: browser) { if case .switchSpace = $0 { true } else { false } }
        XCTAssertTrue(AddressResults.execute(result, in: browser, inNewTab: true))
        XCTAssertEqual(browser.activeSpaceID, destination.id)
        XCTAssertNil(browser.activeTab)
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertEqual(browser.allTabs.count, 1)
        XCTAssertTrue(browser.allTabs.first === source)
        XCTAssertNil(source.webView)
        XCTAssertGreaterThan(browser.addressFocusRequest, focusRequest)
        let url = URL(string: "http://127.0.0.1:9/Docs?token=AbC")!
        browser.navigate(to: url.absoluteString)
        defer { browser.activeTab?.stopLoading() }
        XCTAssertEqual(browser.activeTab?.url, url)
        XCTAssertEqual(browser.activeTab?.spaceID, destination.id)
        XCTAssertEqual(browser.allTabs.count, 2, "Only explicit navigation creates the destination")
    }

    func testMissingForeignProfileAndForeignOwnerSpaceActionsPreservePeek() throws {
        let browser = browser()
        let source = try XCTUnwrap(browser.activeTab)
        let destination = try browser.spaces.createSpace(title: "Work")
        let otherWindow = self.browser()
        let peek = browser.openPeek(from: source)
        defer { browser.dismissPeek() }
        let originalSpace = browser.activeSpaceID
        let revision = source.navigationRevision
        let actions = [
            AddressResult(owner: ObjectIdentifier(browser), action: .switchSpace(.init(id: UUID(), profileID: destination.profileID)),
                          title: "Removed Space", detail: "Space", destinationSpace: "Removed Space"),
            AddressResult(owner: ObjectIdentifier(browser), action: .switchSpace(.init(id: destination.id, profileID: UUID())),
                          title: "Stale Profile", detail: "Space", destinationSpace: "Work"),
            AddressResult(owner: ObjectIdentifier(otherWindow), action: .switchSpace(.init(id: destination.id, profileID: destination.profileID)),
                          title: "Work", detail: "Space", destinationSpace: "Work"),
        ]
        for action in actions {
            XCTAssertFalse(AddressResults.execute(action, in: browser, inNewTab: true))
            XCTAssertEqual(browser.activeSpaceID, originalSpace)
            XCTAssertTrue(browser.activeTab === source)
            XCTAssertTrue(browser.peek?.tab === peek)
            XCTAssertTrue(browser.focusedPage === peek)
            XCTAssertEqual(browser.allTabs.count, 1)
            XCTAssertEqual(source.navigationRevision, revision)
        }
    }

    func testPrivateAndExtensionResultsNeverExposeOrdinarySpaces() throws {
        let normal = browser()
        let secret = try normal.spaces.createSpace(title: "Secret Space")
        let privateBrowser = BrowserModel(websiteDataStore: .nonPersistent(), isPrivate: true, spaces: normal.spaces)
        let extensionBrowser = BrowserModel(websiteDataStore: .nonPersistent(), spaces: normal.spaces)
        extensionBrowser.isExtensionWindow = true
        for scoped in [privateBrowser, extensionBrowser] {
            let results = AddressResults.results(for: "Secret", browser: scoped, bookmarks: [])
            XCTAssertEqual(results.map(\.action), [.search("Secret")])
            let forged = AddressResult(owner: ObjectIdentifier(scoped), action: .switchSpace(.init(id: secret.id, profileID: secret.profileID)),
                                       title: secret.title, detail: "Space", destinationSpace: secret.title)
            XCTAssertFalse(AddressResults.execute(forged, in: scoped))
            let live = try result("New Tab", in: scoped) { if case .switchTab = $0 { true } else { false } }
            XCTAssertEqual(live.destinationSpace, scoped.isPrivate ? "Private Window" : "Extension Window")
            XCTAssertEqual(scoped.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
            XCTAssertEqual(scoped.tabs.count, 1)
        }
    }

    func testLiveTabSelectionAcrossSpacesKeepsExactObjectAndNavigation() throws {
        let browser = browser()
        let target = try XCTUnwrap(browser.activeTab)
        target.load(URL(string: "data:text/html,<p>Target</p>")!)
        defer { target.stopLoading() }
        let view = target.webView
        let revision = target.navigationRevision
        let originalSpace = browser.activeSpaceID
        let work = try browser.createSpace(title: "Work")
        let count = browser.allTabs.count
        let result = try result("data:text", in: browser) { if case .switchTab = $0 { true } else { false } }
        XCTAssertEqual(result.destinationSpace, "Default")
        XCTAssertEqual(result.actionLabel, "Switch to Tab")
        XCTAssertEqual(browser.activeSpaceID, work.id, "Ranking must not change Space")
        XCTAssertTrue(AddressResults.execute(result, in: browser))
        XCTAssertEqual(browser.activeSpaceID, originalSpace)
        XCTAssertTrue(browser.activeTab === target)
        XCTAssertTrue(target.webView === view)
        XCTAssertEqual(target.navigationRevision, revision)
        XCTAssertEqual(browser.allTabs.count, count)
    }

    func testLiveTabSelectionInCurrentSpaceSelectsExactSplitCompanion() throws {
        let browser = browser()
        let target = try XCTUnwrap(browser.activeTab)
        browser.addTab(focusAddress: false)
        let companion = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(browser.makeSplit(target.id, with: companion.id))
        browser.activeTabID = companion.id
        let result = try XCTUnwrap(AddressResults.results(for: "New Tab", browser: browser, bookmarks: []).first {
            if case .switchTab(let destination) = $0.action { return destination.id == target.id }
            return false
        })
        XCTAssertTrue(AddressResults.execute(result, in: browser))
        XCTAssertTrue(browser.activeTab === target)
        XCTAssertEqual(browser.activeSplit?.focusedID, target.id)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(browser.tabs.allSatisfy { $0.webView == nil })
    }

    func testAlreadyActiveLiveResultDismissesPeekWithoutNavigationOrDuplication() throws {
        let browser = browser()
        let source = try XCTUnwrap(browser.activeTab)
        source.load(URL(string: "data:text/html,<p>Source</p>")!)
        defer { source.stopLoading(); browser.dismissPeek() }
        let result = try result("data:text", in: browser) { if case .switchTab = $0 { true } else { false } }
        let peek = browser.openPeek(from: source)
        let url = source.url
        let revision = source.navigationRevision
        let view = source.webView
        let count = browser.allTabs.count
        XCTAssertTrue(browser.focusedPage === peek)
        XCTAssertTrue(browser.activeTab === source)

        XCTAssertTrue(AddressResults.execute(result, in: browser))

        XCTAssertNil(browser.peek)
        XCTAssertTrue(browser.focusedPage === source)
        XCTAssertTrue(browser.activeTab === source)
        XCTAssertTrue(source.webView === view)
        XCTAssertEqual(browser.allTabs.count, count)
        XCTAssertEqual(source.url, url)
        XCTAssertEqual(source.navigationRevision, revision)
    }

    func testAlreadyActiveSavedResultsDismissPeekWithoutNavigationOrDuplication() throws {
        for kind in [AddressResult.SavedKind.folderPage, .essential] {
            let browser = browser()
            let source = try XCTUnwrap(browser.activeTab)
            source.load(URL(string: "data:text/html,<p>Retained</p>")!)
            defer { source.stopLoading(); browser.dismissPeek() }
            let home = URL(string: "https://saved.invalid/home")!
            switch kind {
            case .folderPage:
                source.folderPageID = try browser.folders.savePage(url: home, title: "Saved Source", in: nil).id
            case .essential:
                source.pinnedPageID = try browser.pinnedPages.pin(url: home, title: "Saved Source").id
            }
            let result = try result("saved.invalid", in: browser) { if case .openSavedPage = $0 { true } else { false } }
            let peek = browser.openPeek(from: source)
            let url = source.url
            let revision = source.navigationRevision
            let view = source.webView
            let count = browser.allTabs.count
            XCTAssertTrue(browser.focusedPage === peek)
            XCTAssertTrue(browser.activeTab === source)

            XCTAssertTrue(AddressResults.execute(result, in: browser))

            XCTAssertNil(browser.peek)
            XCTAssertTrue(browser.focusedPage === source)
            XCTAssertTrue(browser.activeTab === source)
            XCTAssertTrue(source.webView === view)
            XCTAssertEqual(browser.allTabs.count, count)
            XCTAssertEqual(source.url, url)
            XCTAssertEqual(source.navigationRevision, revision)
        }
    }

    func testRejectedSavedResultsDoNotDismissPeekOrNavigate() throws {
        for kind in [AddressResult.SavedKind.folderPage, .essential] {
            let browser = browser()
            let source = try XCTUnwrap(browser.activeTab)
            let home = URL(string: "https://saved.invalid/stale")!
            let id: UUID
            switch kind {
            case .folderPage:
                id = try browser.folders.savePage(url: home, title: "Stale Saved", in: nil).id
            case .essential:
                id = try browser.pinnedPages.pin(url: home, title: "Stale Saved").id
            }
            let result = try result("Stale Saved", in: browser) { if case .openSavedPage = $0 { true } else { false } }
            switch kind {
            case .folderPage: try browser.folders.removePage(id)
            case .essential: try browser.pinnedPages.remove(id)
            }
            let peek = browser.openPeek(from: source)
            defer { browser.dismissPeek() }
            let revision = source.navigationRevision
            let count = browser.allTabs.count

            XCTAssertFalse(AddressResults.execute(result, in: browser))

            XCTAssertTrue(browser.peek?.tab === peek)
            XCTAssertTrue(browser.focusedPage === peek)
            XCTAssertTrue(browser.activeTab === source)
            XCTAssertEqual(browser.allTabs.count, count)
            XCTAssertEqual(source.navigationRevision, revision)
            XCTAssertNil(source.webView)
        }
    }

    func testClosedAndReplacedTabResultsDoNothing() throws {
        let browser = browser()
        let target = try XCTUnwrap(browser.activeTab)
        let result = try result("New Tab", in: browser) { if case .switchTab = $0 { true } else { false } }
        browser.addTab(focusAddress: false)
        browser.closeTab(target.id)
        let selected = browser.activeTabID
        let source = try XCTUnwrap(browser.activeTab)
        let peek = browser.openPeek(from: source)
        defer { browser.dismissPeek() }
        let revision = source.navigationRevision
        let count = browser.allTabs.count
        XCTAssertFalse(AddressResults.execute(result, in: browser))
        XCTAssertEqual(browser.activeTabID, selected)
        XCTAssertTrue(browser.peek?.tab === peek)
        XCTAssertTrue(browser.focusedPage === peek)
        XCTAssertEqual(browser.allTabs.count, count)
        XCTAssertEqual(source.navigationRevision, revision)
        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: nil, title: "Replacement", interactionState: nil, id: target.id),
        ], selectedIndex: 0))
        XCTAssertFalse(browser.activeTab === target)
        let replacement = try XCTUnwrap(browser.activeTab)
        let replacementPeek = browser.openPeek(from: replacement)
        let replacementRevision = replacement.navigationRevision
        XCTAssertFalse(AddressResults.execute(result, in: browser))
        XCTAssertTrue(browser.peek?.tab === replacementPeek)
        XCTAssertTrue(browser.focusedPage === replacementPeek)
        XCTAssertEqual(replacement.navigationRevision, replacementRevision)
        XCTAssertEqual(browser.tabs.count, 1)
    }

    func testDeferredDestinationFocusStopsForLaterFocusSelectionAndCancellation() async throws {
        for change in ["selection", "address", "find", "responder", "cancel"] {
            let browser = browser()
            let source = try XCTUnwrap(browser.activeTab)
            source.isNewTab = false
            source.restore()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let root = NSView(frame: window.contentLayoutRect)
            window.contentView = root
            browser.window = window
            defer { source.stopLoading(); window.close() }
            let task = try XCTUnwrap(AddressResults.focusDestination(in: browser))
            switch change {
            case "selection": browser.addTab(focusAddress: false)
            case "address": browser.requestAddressFocus()
            case "find": browser.findFocusRequest += 1
            case "responder":
                let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
                root.addSubview(field)
                XCTAssertTrue(window.makeFirstResponder(field))
            default: task.cancel()
            }
            let responder = window.firstResponder
            root.addSubview(source.contentView)
            await task.value
            XCTAssertTrue(window.firstResponder === responder, "Must not override later \(change)")
            XCTAssertFalse(window.firstResponder === source.webView)
        }
    }

    func testTypedCommandUsesAllowlistAndRechecksAvailability() throws {
        let browser = browser()
        XCTAssertEqual(AddressBrowserCommand.newTab.title, "New Blank Tab")
        let newTab = try result("new tab", in: browser) { $0 == .command(.newTab) }
        XCTAssertEqual(newTab.actionLabel, "Run Command")
        XCTAssertNil(newTab.completionSuggestion)
        XCTAssertTrue(AddressResults.execute(newTab, in: browser))
        XCTAssertEqual(browser.tabs.count, 2)
        let second = try XCTUnwrap(browser.activeTabID)
        browser.closeTab(second)
        let reopen = try result("reopen closed", in: browser) { $0 == .command(.reopenClosedTab) }
        XCTAssertTrue(AddressResults.execute(reopen, in: browser))
        XCTAssertFalse(AddressResults.execute(reopen, in: browser), "The closed-tab entry was already consumed")
        let otherWindow = self.browser()
        XCTAssertFalse(AddressResults.execute(newTab, in: otherWindow))
        browser.windowDidClose()
        XCTAssertFalse(AddressResults.execute(newTab, in: browser))
    }

    func testPrivateResultsExcludeNormalProfileDataAndRejectForeignActions() throws {
        let history = HistoryStore(file: nil)
        history.recordVisit(to: URL(string: "https://secret.example/history")!, title: "Secret History")
        let normal = browser(history: history)
        normal.restoreSession(WindowSession(tabs: [
            TabSession(url: URL(string: "https://secret.example/tab")!, title: "Secret Normal Tab", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil),
        ], selectedIndex: 1))
        _ = try normal.createSpace(title: "Secret Work")
        let secret = Bookmark(title: "Secret Bookmark", url: URL(string: "https://secret.example/bookmark")!)
        _ = try normal.folders.savePage(url: URL(string: "https://secret.example/saved")!, title: "Secret Saved", in: nil)
        let normalTab = try result("Secret Normal Tab", in: normal) { if case .switchTab = $0 { true } else { false } }
        let normalHistory = try result("Secret History", in: normal) { if case .openURL = $0 { true } else { false } }
        let privateBrowser = BrowserModel(history: history, websiteDataStore: .nonPersistent(), isPrivate: true, spaces: normal.spaces)
        let results = AddressResults.results(for: "secret", browser: privateBrowser, bookmarks: [secret])
        XCTAssertEqual(results.map(\.action), [.search("secret")])
        XCTAssertFalse(AddressResults.execute(normalTab, in: privateBrowser))
        XCTAssertFalse(AddressResults.execute(normalHistory, in: privateBrowser))
        XCTAssertFalse(AddressBrowserCommand.showHistory.isAvailable(in: privateBrowser))
        let privateTab = try result("New Tab", in: privateBrowser) { if case .switchTab = $0 { true } else { false } }
        XCTAssertEqual(privateTab.destinationSpace, "Private Window")
        XCTAssertTrue(AddressResults.execute(privateTab, in: privateBrowser))
        XCTAssertFalse(AddressResults.execute(privateTab, in: normal))
    }

    func testSavedResultShowsDestinationAndRechecksSavedID() throws {
        let browser = browser()
        let work = try browser.createSpace(title: "Work")
        let saved = try browser.folders.savePage(url: URL(string: "https://saved.invalid/Docs?token=AbC")!, title: "Guide", in: nil)
        XCTAssertTrue(browser.selectSpace(BrowserSpaceStore.defaultSpaceID))
        let result = try result("Guide", in: browser) { if case .openSavedPage = $0 { true } else { false } }
        XCTAssertEqual(result.destinationSpace, "Work")
        XCTAssertEqual(result.actionLabel, "Open Saved Tab")
        XCTAssertNil(result.completionSuggestion)
        XCTAssertTrue(AddressResults.execute(result, in: browser))
        defer { browser.activeTab?.stopLoading() }
        XCTAssertEqual(browser.activeSpaceID, work.id)
        XCTAssertEqual(browser.activeTab?.folderPageID, saved.id)
        try browser.folders.removePage(saved.id)
        XCTAssertFalse(AddressResults.execute(result, in: browser))
    }

    func testFolderSavedResultFromSecondWindowDoesNotCreateABlankTab() throws {
        try assertSavedResultFromSecondWindow(kind: .folderPage)
    }

    func testEssentialResultFromSecondWindowDoesNotCreateABlankTab() throws {
        try assertSavedResultFromSecondWindow(kind: .essential)
    }

    private func assertSavedResultFromSecondWindow(kind: AddressResult.SavedKind) throws {
        let firstWindow = browser()
        let destination = try firstWindow.createSpace(title: "Remote Space")
        let url = URL(string: "http://127.0.0.1:9/Remote/Docs?token=AbC#Part")!
        let savedID: UUID
        switch kind {
        case .folderPage: savedID = try firstWindow.folders.savePage(url: url, title: "Remote Guide", in: nil).id
        case .essential: savedID = try firstWindow.pinnedPages.pin(url: url, title: "Remote Guide").id
        }
        let firstIDs = firstWindow.allTabs.map(\.id)
        let secondWindow = BrowserModel(websiteDataStore: firstWindow.websiteDataStore, spaces: firstWindow.spaces)
        let source = try XCTUnwrap(secondWindow.activeTab)
        let peek = secondWindow.openPeek(from: source)
        defer { secondWindow.dismissPeek(); secondWindow.allTabs.forEach { $0.stopLoading() } }
        XCTAssertTrue(secondWindow.focusedPage === peek)
        XCTAssertFalse(secondWindow.allTabs.contains { $0.spaceID == destination.id })
        let count = secondWindow.allTabs.count
        let result = try result("Remote Guide", in: secondWindow) {
            if case .openSavedPage(let id, _, let savedKind, _) = $0 { return id == savedID && savedKind == kind }
            return false
        }

        XCTAssertTrue(AddressResults.execute(result, in: secondWindow, inNewTab: true))

        let target = try XCTUnwrap(secondWindow.activeTab)
        XCTAssertEqual(secondWindow.activeSpaceID, destination.id)
        XCTAssertEqual(secondWindow.tabs.count, 1)
        XCTAssertTrue(secondWindow.tabs.allSatisfy { !$0.isNewTab })
        XCTAssertEqual(secondWindow.allTabs.count, count + 1)
        XCTAssertEqual(target.url, url)
        XCTAssertEqual(target.spaceID, destination.id)
        XCTAssertEqual(target.profileID, destination.profileID)
        XCTAssertTrue(target.browser === secondWindow)
        XCTAssertTrue(target.webView?.configuration.websiteDataStore === secondWindow.websiteDataStore)
        XCTAssertEqual(kind == .folderPage ? target.folderPageID : target.pinnedPageID, savedID)
        XCTAssertNil(secondWindow.peek)
        XCTAssertTrue(secondWindow.tabAcrossSpaces(withID: source.id) === source)
        XCTAssertEqual(firstWindow.allTabs.map(\.id), firstIDs)
        XCTAssertTrue(firstWindow.allTabs.allSatisfy { $0.webView == nil })
    }

    func testOnlyURLResultsSupplyCompletionAndKeepOriginalURL() throws {
        let browser = browser()
        let url = URL(string: "http://www.example.com:8765/Docs/Guide?token=AbC#Part")!
        let bookmark = Bookmark(title: "Guide", url: url)
        let results = AddressResults.results(for: "example.com:8765/D", browser: browser, bookmarks: [bookmark])
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.actionLabel, "Open Bookmark")
        let completion = try XCTUnwrap(AddressSuggestions.inlineCompletion(of: "example.com:8765/D", with: first.completionSuggestion))
        XCTAssertEqual(AddressSuggestions.completedURL(for: completion, with: first.completionSuggestion), url)
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "example.com:8765/d", with: first.completionSuggestion))
        XCTAssertEqual(results.last?.actionLabel, "Search the Web")
        XCTAssertNil(results.last?.completionSuggestion)
        XCTAssertEqual(results.last?.action, .search("example.com:8765/D"))
    }

    func testLiveMatchDoesNotBorrowInlineCompletionFromLaterHistoryResult() throws {
        let url = URL(string: "http://mixed.invalid:8765/Docs?token=AbC")!
        let history = HistoryStore(file: nil)
        history.recordVisit(to: url, title: "Mixed History")
        let browser = browser(history: history)
        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: url, title: "Mixed Live Tab", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil),
        ], selectedIndex: 1))
        let results = AddressResults.results(for: "mixed.invalid", browser: browser, bookmarks: [])
        let first = try XCTUnwrap(results.first)
        guard case .switchTab = first.action else { return XCTFail("Live results must keep their action") }
        // Completion follows the first result's action. Do not turn a switch action
        // into a navigation by borrowing a URL from a later history row.
        XCTAssertNil(first.completionSuggestion)
        XCTAssertNil(AddressSuggestions.inlineCompletion(of: "mixed.invalid", with: first.completionSuggestion))
        let historyResult = try XCTUnwrap(results.first { if case .openURL = $0.action { true } else { false } })
        XCTAssertEqual(historyResult.completionSuggestion?.url, url)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testHistoryLabelAndRankingDoNotRestoreViewsOrNavigate() throws {
        let history = HistoryStore(file: nil)
        history.recordVisit(to: URL(string: "http://history.invalid:8765/Docs?token=AbC")!, title: "History Result")
        let browser = browser(history: history)
        let revision = browser.activeTab?.navigationRevision
        let results = AddressResults.results(for: "History Result", browser: browser, bookmarks: [])
        XCTAssertEqual(results.first?.actionLabel, "Open History Page")
        XCTAssertEqual(browser.activeTab?.navigationRevision, revision)
        XCTAssertNil(browser.activeTab?.webView)
        XCTAssertLessThanOrEqual(results.count, AddressResults.limit)
        XCTAssertEqual(results, AddressResults.results(for: "History Result", browser: browser, bookmarks: []))
    }
}
