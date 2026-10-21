import AppKit
import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserSpaceTests: XCTestCase {
    private let defaultID = BrowserSpaceStore.defaultSpaceID

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "BrowserSpaces-\(UUID())", directoryHint: .isDirectory)
    }

    private func tab(_ title: String, id: UUID = UUID(), spaceID: UUID? = nil, profileID: UUID? = nil) -> TabSession {
        TabSession(url: URL(string: "https://spaces.invalid/\(title)")!, title: title, interactionState: nil,
                   id: id, spaceID: spaceID, profileID: profileID)
    }

    func testLegacyMigrationKeepsSavedIdentifiersOrderAndSelection() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = BrowserSpaceStore(directory: root)
        let folders = spaces.folders(for: defaultID)
        let parent = try folders.createFolder(title: "Work")
        let first = try folders.savePage(url: URL(string: "https://spaces.invalid/first")!, title: "First", in: parent.id)
        let second = try folders.savePage(url: URL(string: "https://spaces.invalid/second")!, title: "Second", in: parent.id)
        let essential = try spaces.pinnedPages(for: defaultID).pin(url: URL(string: "https://spaces.invalid/essential")!, title: "Essential")
        let folderBytes = try Data(contentsOf: root.appending(path: "TabFolders.json"))
        let pinBytes = try Data(contentsOf: root.appending(path: "PinnedPages.json"))
        let legacy = WindowSession(tabs: [
            TabSession(url: first.url, title: first.title, interactionState: nil, folderPageID: first.id),
            TabSession(url: second.url, title: second.title, interactionState: nil, folderPageID: second.id),
            TabSession(url: essential.url, title: essential.title, interactionState: nil, pinnedPageID: essential.id),
        ], selectedIndex: 1)
        let browser = BrowserModel(spaces: spaces)
        browser.restoreSession(legacy)

        XCTAssertEqual(browser.activeSpaceID, defaultID)
        XCTAssertEqual(browser.folders.items.map(\.id), [parent.id, first.id, second.id])
        XCTAssertEqual(browser.tabs.map(\.folderPageID), [first.id, second.id, nil])
        XCTAssertEqual(browser.activeTab?.folderPageID, second.id)
        XCTAssertEqual(browser.tabs.last?.pinnedPageID, essential.id)
        XCTAssertTrue(browser.tabs[0].isSuspended)
        XCTAssertTrue(browser.tabs[2].isSuspended)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "TabFolders.json")), folderBytes)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "PinnedPages.json")), pinBytes)
    }

    func testLegacyWindowRestoresIntoDefaultEvenWhenAnotherSpaceWasSelected() throws {
        let browser = BrowserModel()
        _ = try browser.createSpace(title: "Work")
        browser.restoreSession(WindowSession(tabs: [tab("Legacy")], selectedIndex: 0))
        XCTAssertEqual(browser.activeSpaceID, defaultID)
        XCTAssertEqual(browser.activeTab?.title, "Legacy")
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.spaceID == defaultID })
    }

    func testSwitchRetainsLiveObjectsSelectionAndSplitFocus() throws {
        let browser = BrowserModel()
        let first = try XCTUnwrap(browser.activeTab)
        browser.addTab(focusAddress: false)
        let second = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(browser.makeSplit(first.id, with: second.id))
        let split = try XCTUnwrap(browser.activeSplit)
        let focusRequest = browser.addressFocusRequest
        let space = try browser.createSpace(title: "Research")
        XCTAssertEqual(browser.addressFocusRequest, focusRequest)
        XCTAssertEqual(browser.consumedAddressFocusRequest, focusRequest)
        let researchTab = try XCTUnwrap(browser.activeTab)
        XCTAssertEqual(researchTab.spaceID, space.id)
        XCTAssertEqual(browser.allTabs.count, 3)
        XCTAssertNil(browser.tab(withID: first.id))
        XCTAssertTrue(browser.tabAcrossSpaces(withID: first.id) === first)
        XCTAssertFalse(browser.makeSplit(first.id, with: researchTab.id))
        XCTAssertTrue(browser.selectSpace(defaultID))
        XCTAssertTrue(browser.tabs[0] === first)
        XCTAssertTrue(browser.tabs[1] === second)
        XCTAssertEqual(browser.activeTabID, second.id)
        XCTAssertEqual(browser.activeSplit, split)
        XCTAssertTrue(browser.selectSpace(space.id))
        XCTAssertTrue(browser.activeTab === researchTab)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testLiveWebViewAndFindStateSurviveSpaceSwitchWithoutNavigation() throws {
        let browser = BrowserModel(configuration: BrowserTab.makeConfiguration(includingExtensions: false))
        let source = try XCTUnwrap(browser.activeTab)
        source.load(URL(string: "data:text/html,<p>Space</p>")!)
        let view = try XCTUnwrap(source.webView)
        let revision = source.navigationRevision
        source.findText = "Space"
        source.isFindBarVisible = true
        defer { source.stopLoading() }
        _ = try browser.createSpace(title: "Work")
        XCTAssertTrue(source.webView === view)
        XCTAssertTrue(browser.selectSpace(defaultID))
        XCTAssertTrue(browser.activeTab === source)
        XCTAssertTrue(source.webView === view)
        XCTAssertEqual(source.navigationRevision, revision)
        XCTAssertEqual(source.findText, "Space")
        XCTAssertTrue(source.isFindBarVisible)
    }

    func testWindowSessionRestoresOnlyTheActiveSpacesVisiblePagesAndKeepsIDs() throws {
        let spaces = BrowserSpaceStore(directory: directory(), enabled: false)
        let other = try spaces.createSpace(title: "Other")
        let ids = (0..<4).map { _ in UUID() }
        let group = BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [0, 1], anchorIndex: 0,
                                                focusedIndex: 1, orientation: .vertical, weights: [0.3, 0.7])
        let ordinary = SpaceSession(spaceID: defaultID, profileID: BrowserProfile.defaultID,
                                   tabs: [tab("A", id: ids[0]), tab("B", id: ids[1])], selectedIndex: 1, splits: [group])
        let otherSession = SpaceSession(spaceID: other.id, profileID: BrowserProfile.defaultID,
                                       tabs: [tab("C", id: ids[2]), tab("D", id: ids[3])], selectedIndex: 0)
        let session = WindowSession(tabs: otherSession.tabs, selectedIndex: 0, activeSpaceID: other.id,
                                    spaceSessions: [ordinary, otherSession])
        let browser = BrowserModel(spaces: spaces)
        browser.restoreSession(session)
        XCTAssertEqual(browser.activeSpaceID, other.id)
        XCTAssertEqual(browser.activeTabID, ids[2])
        XCTAssertEqual(browser.allTabs.map(\.id), ids)
        XCTAssertNil(browser.tabAcrossSpaces(withID: ids[0])?.webView)
        XCTAssertNil(browser.tabAcrossSpaces(withID: ids[1])?.webView)
        XCTAssertNotNil(browser.activeTab?.webView)
        XCTAssertNil(browser.tabs[1].webView)
        let encoded = try PropertyListEncoder.binary.encode(browser.windowSession())
        let restored = BrowserModel(spaces: spaces)
        restored.restoreSession(try PropertyListDecoder().decode(WindowSession.self, from: encoded))
        XCTAssertEqual(restored.allTabs.map(\.id), ids)
        XCTAssertNil(restored.tabAcrossSpaces(withID: ids[0])?.webView)
        XCTAssertTrue(restored.selectSpace(defaultID))
        XCTAssertEqual(restored.activeTabID, ids[1])
        XCTAssertEqual(restored.activeSplit?.id, group.id)
        XCTAssertEqual(restored.activeSplit?.weights, [0.3, 0.7])
        XCTAssertTrue(restored.tabs.allSatisfy { $0.webView != nil })
    }

    func testSavedPagesAndEssentialsAreSpaceScopedAndDurable() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserSpaceStore(directory: root)
        let browser = BrowserModel(spaces: store)
        let url = URL(string: "https://spaces.invalid/saved")!
        let saved = try browser.folders.savePage(url: url, title: "Default page", in: nil)
        let pin = try browser.pinnedPages.pin(url: url, title: "Default essential")
        let other = try browser.createSpace(title: "Work")
        XCTAssertTrue(browser.folders.items.isEmpty)
        XCTAssertTrue(browser.pinnedPages.items.isEmpty)
        let work = try browser.folders.savePage(url: url, title: "Work page", in: nil)
        let workPin = try browser.pinnedPages.pin(url: url, title: "Work essential")
        let reopened = BrowserSpaceStore(directory: root)
        XCTAssertEqual(reopened.spaces.map(\.id), [defaultID, other.id])
        XCTAssertEqual(reopened.folders(for: defaultID).pages.map(\.id), [saved.id])
        XCTAssertEqual(reopened.pinnedPages(for: defaultID).items.map(\.id), [pin.id])
        XCTAssertEqual(reopened.folders(for: other.id).pages.map(\.id), [work.id])
        XCTAssertEqual(reopened.pinnedPages(for: other.id).items.map(\.id), [workPin.id])
    }

    func testOwnershipCannotBeChangedBySelectingAnotherSpace() throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let browser = BrowserModel(websiteDataStore: dataStore)
        let original = try XCTUnwrap(browser.activeTab)
        let other = try browser.createSpace(title: "Work")
        XCTAssertEqual(original.spaceID, defaultID)
        XCTAssertEqual(original.profileID, BrowserProfile.defaultID)
        XCTAssertEqual(browser.activeTab?.spaceID, other.id)
        XCTAssertTrue(browser.websiteDataStore(forProfileID: original.profileID) === dataStore)
        XCTAssertTrue(browser.makeConfiguration().websiteDataStore === dataStore)
        XCTAssertNil(browser.websiteDataStore(forProfileID: UUID()))
        XCTAssertFalse(browser.selectSpace(UUID()))
        browser.activeTabID = original.id
        XCTAssertNotEqual(browser.activeTabID, original.id)
    }

    func testForeignAndUnknownOwnersRemainRecoverableWithoutLoading() throws {
        let foreign = SpaceSession(spaceID: defaultID, profileID: UUID(), tabs: [tab("Foreign")], selectedIndex: 0)
        let unknown = SpaceSession(spaceID: UUID(), profileID: BrowserProfile.defaultID, tabs: [tab("Unknown")], selectedIndex: 0)
        let browser = BrowserModel()
        browser.restoreSession(WindowSession(tabs: [], selectedIndex: 0, activeSpaceID: unknown.spaceID,
                                             spaceSessions: [foreign, unknown]))
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil && $0.isNewTab })
        XCTAssertEqual(browser.windowSession().unavailableSpaceSessions, [foreign, unknown])
        let next = BrowserModel()
        next.restoreSession(browser.windowSession())
        XCTAssertEqual(next.windowSession().unavailableSpaceSessions, [foreign, unknown])
        XCTAssertTrue(next.allTabs.allSatisfy { $0.webView == nil })
    }

    func testExplicitTabOwnershipMismatchDoesNotUseTheCurrentProfile() {
        let wrong = SpaceSession(spaceID: defaultID, profileID: BrowserProfile.defaultID,
                                 tabs: [tab("Wrong", profileID: UUID())], selectedIndex: 0)
        let browser = BrowserModel()
        browser.restoreSession(WindowSession(tabs: [], selectedIndex: 0, spaceSessions: [wrong]))
        XCTAssertTrue(browser.activeTab?.isNewTab == true)
        XCTAssertNil(browser.activeTab?.webView)
        XCTAssertEqual(browser.windowSession().unavailableSpaceSessions, [wrong])
    }

    func testTwoWindowsSelectSpacesIndependentlyAndSessionStoreSavesBoth() throws {
        let spaces = BrowserSpaceStore(directory: directory(), enabled: false)
        let first = BrowserModel(spaces: spaces)
        let second = BrowserModel(spaces: spaces)
        let other = try first.createSpace(title: "Work")
        let store = SessionStore(file: nil)
        _ = store.attach(first)
        _ = store.attach(second)
        XCTAssertEqual(second.activeSpaceID, defaultID)
        XCTAssertEqual(second.spaces.spaces.last?.id, other.id)
        XCTAssertEqual(store.snapshot.windows.map(\.activeSpaceID), [other.id, defaultID])
    }

    func testPrivateAndExtensionWindowsCannotChangeOrdinarySpaces() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = BrowserSpaceStore(directory: root)
        let other = try spaces.createSpace(title: "Work")
        let privateBrowser = BrowserModel(isPrivate: true, spaces: spaces)
        XCTAssertFalse(privateBrowser.selectSpace(other.id))
        XCTAssertThrowsError(try privateBrowser.createSpace(title: "Private"))
        XCTAssertFalse(privateBrowser.websiteDataStore.isPersistent)
        let session = SessionStore(file: nil)
        XCTAssertEqual(session.attach(privateBrowser), 0)
        let extensionBrowser = BrowserModel(spaces: spaces)
        extensionBrowser.isExtensionWindow = true
        XCTAssertFalse(extensionBrowser.selectSpace(other.id))
        XCTAssertThrowsError(try extensionBrowser.createSpace(title: "Extension"))
        XCTAssertEqual(session.attach(extensionBrowser), 0)
        XCTAssertTrue(session.snapshot.windows.isEmpty)
        XCTAssertEqual(spaces.spaces.count, 2)
    }

    func testBackgroundOpenerKeepsItsSpaceAndClosingItDoesNotSwitch() throws {
        let browser = BrowserModel()
        let opener = try XCTUnwrap(browser.activeTab)
        let other = try browser.createSpace(title: "Work")
        let selected = browser.activeTabID
        let child = browser.openChildTab(of: opener, select: false)
        XCTAssertEqual(child.spaceID, defaultID)
        XCTAssertEqual(child.profileID, opener.profileID)
        XCTAssertEqual(browser.activeSpaceID, other.id)
        XCTAssertFalse(browser.tabs.contains { $0 === child })
        XCTAssertTrue(browser.allTabs.contains { $0 === child })
        browser.closeTab(child.id)
        XCTAssertNil(browser.tabAcrossSpaces(withID: child.id))
        XCTAssertEqual(browser.activeTabID, selected)
        browser.selectSpace(defaultID)
        XCTAssertTrue(browser.canReopenClosedTab)
        browser.reopenClosedTab()
        XCTAssertEqual(browser.activeTab?.spaceID, defaultID)
    }

    func testSpaceCreationFailureDoesNotPublishAnUnsavedDescriptor() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root)
        let spaces = BrowserSpaceStore(directory: root)
        XCTAssertThrowsError(try spaces.createSpace(title: "Work"))
        XCTAssertEqual(spaces.spaces.count, 1)
    }

    func testCorruptSpaceFileIsNotOverwritten() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Spaces.json")
        let original = Data("not json".utf8)
        try original.write(to: file)
        let spaces = BrowserSpaceStore(directory: root)
        XCTAssertThrowsError(try spaces.createSpace(title: "Work"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testForeignProfileMetadataCannotBeReinterpretedAsSharedLogins() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Spaces.json")
        let original = try JSONEncoder().encode([BrowserSpace(id: defaultID, title: "Foreign", profileID: UUID())])
        try original.write(to: file)
        let spaces = BrowserSpaceStore(directory: root)
        XCTAssertEqual(spaces.spaces.first?.profileID, BrowserProfile.defaultID)
        XCTAssertThrowsError(try spaces.createSpace(title: "Work"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDetachedOwnedTabCannotRestoreIntoTheDefaultDataStore() throws {
        var owner: BrowserModel? = BrowserModel(isPrivate: true)
        let detached = BrowserTab(url: URL(string: "https://spaces.invalid/private")!, title: "Private",
                                  interactionState: nil, browser: owner)
        owner = nil
        XCTAssertNil(detached.browser)
        detached.restore()
        detached.load(URL(string: "https://spaces.invalid/another")!)
        XCTAssertNil(detached.webView)
        XCTAssertEqual(detached.url?.path, "/private")
    }

    func testInactiveTabCannotBeSavedIntoTheActiveSpacesStores() throws {
        let browser = BrowserModel()
        browser.restoreSession(WindowSession(tabs: [tab("Default")], selectedIndex: 0))
        let source = try XCTUnwrap(browser.activeTab)
        _ = try browser.createSpace(title: "Work")
        XCTAssertFalse(browser.canPin(source))
        browser.pin(source)
        browser.moveToFolder(source, parentID: nil)
        XCTAssertTrue(browser.folders.pages.isEmpty)
        XCTAssertTrue(browser.pinnedPages.items.isEmpty)
        XCTAssertEqual(source.spaceID, defaultID)
    }

    func testFailedMigrationBackupLeavesTheOriginalSessionFile() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        let old = try PropertyListEncoder.binary.encode(SessionSnapshot(windows: [WindowSession(tabs: [tab("Legacy")], selectedIndex: 0)]))
        file.writeNow(old)
        try FileManager.default.createDirectory(at: root.appending(path: "Session.before-spaces.plist"), withIntermediateDirectories: true)
        let store = SessionStore(file: file)
        let browser = BrowserModel()
        _ = store.attach(browser)
        browser.addTab(focusAddress: false)
        store.saveBeforeQuitting()
        XCTAssertEqual(try Data(contentsOf: file.url), old)
    }

    func testPreviewNoteSelectsItsSourceSpaceWithoutDuplicatingThePage() throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        let window = SpaceActionWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer { source.stopLoading(); window.close() }
        _ = try browser.createSpace(title: "Work")
        let destination = URL(string: "https://spaces.invalid/note")!
        let pending = PreviewNoteActions.openPage(destination, from: source, activateApplication: {},
                                                 openElsewhere: { _ in XCTFail("The source tab is still live") })
        pending?.cancel()
        XCTAssertEqual(browser.activeSpaceID, defaultID)
        XCTAssertTrue(browser.activeTab === source)
        XCTAssertEqual(source.url, destination)
        XCTAssertEqual(browser.allTabs.count, 2)
    }

    func testReopenSessionDoesNotReplaceWorkInAnInactiveSpace() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        file.writeNow(try PropertyListEncoder.binary.encode(SessionSnapshot(closedWindows: [
            WindowSession(tabs: [tab("Reopened")], selectedIndex: 0)
        ])))
        let store = SessionStore(file: file)
        let browser = BrowserModel()
        browser.open(URL(string: "data:text/html,<title>Working</title>")!)
        let working = try XCTUnwrap(browser.activeTab)
        let liveView = try XCTUnwrap(working.webView)
        browser.addTab(focusAddress: false)
        let companion = try XCTUnwrap(browser.activeTab)
        XCTAssertTrue(browser.makeSplit(working.id, with: companion.id))
        let splitID = try XCTUnwrap(browser.activeSplit).id
        let space = try browser.createSpace(title: "Empty")
        _ = store.attach(browser)
        let ids = browser.allTabs.map(\.id)
        XCTAssertTrue(browser.isBlank)
        XCTAssertFalse(browser.canReplaceWindowWithSession)

        XCTAssertEqual(store.reopenLastSession(reusing: browser), 1)

        XCTAssertEqual(browser.activeSpaceID, space.id)
        XCTAssertEqual(browser.allTabs.map(\.id), ids)
        XCTAssertTrue(working.webView === liveView)
        XCTAssertEqual(store.snapshot.windows.count, 2)
        XCTAssertTrue(browser.selectSpace(defaultID))
        XCTAssertEqual(browser.activeSplit?.id, splitID)
        XCTAssertTrue(browser.tab(withID: working.id) === working)
        working.stopLoading()
    }

    func testReopenSessionKeepsUnavailableAndClosedTabRecoveryState() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        file.writeNow(try PropertyListEncoder.binary.encode(SessionSnapshot(closedWindows: [
            WindowSession(tabs: [tab("Reopened")], selectedIndex: 0)
        ])))
        let store = SessionStore(file: file)
        let browser = BrowserModel()
        let unavailable = SpaceSession(spaceID: UUID(), profileID: UUID(), tabs: [tab("Recovery")], selectedIndex: 0)
        browser.restoreSession(WindowSession(tabs: [], selectedIndex: 0, spaceSessions: [],
                                             unavailableSpaceSessions: [unavailable]))
        _ = store.attach(browser)
        XCTAssertTrue(browser.isBlank)
        XCTAssertFalse(browser.canReplaceWindowWithSession)
        XCTAssertEqual(store.reopenLastSession(reusing: browser), 1)
        XCTAssertEqual(browser.windowSession().unavailableSpaceSessions, [unavailable])
        let reopened = BrowserModel()
        _ = store.attach(reopened)
        XCTAssertEqual(reopened.activeTab?.title, "Reopened")
        XCTAssertEqual(browser.windowSession().unavailableSpaceSessions, [unavailable])
        reopened.activeTab?.stopLoading()

        let closedRecovery = BrowserModel()
        closedRecovery.open(URL(string: "data:text/html,<title>Closed</title>")!)
        closedRecovery.closeActiveTab()
        XCTAssertTrue(closedRecovery.isBlank)
        XCTAssertTrue(closedRecovery.canReopenClosedTab)
        XCTAssertFalse(closedRecovery.canReplaceWindowWithSession)
    }

    func testIncomingLinkStillReusesOnlyTheActiveSpacesBlankTab() throws {
        let browser = BrowserModel()
        browser.open(URL(string: "data:text/html,<title>Working</title>")!)
        let working = try XCTUnwrap(browser.activeTab)
        _ = try browser.createSpace(title: "Empty")
        let emptyID = browser.activeTabID
        browser.openInNewTabs([URL(string: "data:text/html,<title>Incoming</title>")!])
        XCTAssertEqual(browser.activeTabID, emptyID)
        XCTAssertEqual(browser.allTabs.count, 2)
        XCTAssertTrue(browser.tabAcrossSpaces(withID: working.id) === working)
        browser.allTabs.forEach { $0.stopLoading() }
    }

    func testInactivePopupCloseCallbackLeavesOtherSpaceAndWindowIntact() throws {
        let browser = BrowserModel()
        let opener = try XCTUnwrap(browser.activeTab)
        let popup = browser.openChildTab(of: opener, configuration: BrowserTab.makeConfiguration(includingExtensions: false), select: false)
        let view = try XCTUnwrap(popup.webView)
        let delegate = try XCTUnwrap(view.uiDelegate as? PageDelegate)
        let other = try browser.createSpace(title: "Other")
        let selectedID = browser.activeTabID
        let window = SpaceActionWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer { window.close() }
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.allTabs.count, 3)

        delegate.webViewDidClose(view)

        XCTAssertEqual(window.closeRequests, 0)
        XCTAssertEqual(browser.activeSpaceID, other.id)
        XCTAssertEqual(browser.activeTabID, selectedID)
        XCTAssertEqual(browser.allTabs.count, 2)
        XCTAssertNil(browser.tabAcrossSpaces(withID: popup.id))
        XCTAssertTrue(browser.tabAcrossSpaces(withID: opener.id) === opener)
        // A late duplicate callback must not close an unrelated remaining tab.
        delegate.webViewDidClose(view)
        XCTAssertEqual(window.closeRequests, 0)
    }

    func testSoleExtensionPopupStillClosesItsOwnWindow() throws {
        let browser = BrowserModel(configuration: BrowserTab.makeConfiguration(includingExtensions: false))
        browser.isExtensionWindow = true
        let popup = try XCTUnwrap(browser.activeTab)
        popup.isPopUp = true
        let view = try XCTUnwrap(popup.webView)
        let delegate = try XCTUnwrap(view.uiDelegate as? PageDelegate)
        let window = SpaceActionWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window

        delegate.webViewDidClose(view)

        XCTAssertEqual(window.closeRequests, 1)
    }

    func testLivePeekLateTitleUpdatesItsHistoryVisit() async throws {
        let history = HistoryStore(file: nil)
        await history.waitUntilLoaded()
        let browser = BrowserModel(history: history)
        let opener = try XCTUnwrap(browser.activeTab)
        let peek = browser.openPeek(from: opener)
        let view = try XCTUnwrap(peek.webView)
        let url = URL(string: "http://127.0.0.1:9/peek-title")!
        view.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>Initial Peek</title><p>Local fixture</p>")
        try await waitUntil { !peek.isLoading && history.visits.count == 1 && peek.pageTitle == "Initial Peek" }
        let visitID = try XCTUnwrap(history.visits.first).id

        _ = try await view.evaluateJavaScript("document.title = 'Late Peek Title'")
        try await waitUntil { history.visits.first?.title == "Late Peek Title" }

        XCTAssertEqual(history.visits.count, 1)
        XCTAssertEqual(history.visits.first?.id, visitID)
        XCTAssertEqual(history.visits.first?.url, url)
        browser.dismissPeek()
        _ = try await view.evaluateJavaScript("document.title = 'Closed Peek Title'")
        try await waitUntil { peek.pageTitle == "Closed Peek Title" }
        XCTAssertEqual(history.visits.first?.title, "Late Peek Title")
    }

    func testInactiveSpacePersistsRealWebKitBackForwardState() async throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appending(path: "first.html")
        let secondURL = root.appending(path: "second.html")
        try Data("<title>First Space Page</title><p>First</p>".utf8).write(to: firstURL)
        try Data("<title>Second Space Page</title><p>Second</p>".utf8).write(to: secondURL)
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        func waitForPage(_ tab: BrowserTab, title: String, back: Bool = false, forward: Bool = false) async throws {
            try await waitUntil { !tab.isLoading && tab.pageTitle == title && (!back || tab.canGoBack) && (!forward || tab.canGoForward) }
            XCTAssertEqual(tab.pageTitle, title)
            XCTAssertTrue(!tab.isLoading && (!back || tab.canGoBack) && (!forward || tab.canGoForward),
                          "Expected \(title), back=\(back), forward=\(forward); actual loading=\(tab.isLoading), back=\(tab.canGoBack), forward=\(tab.canGoForward), url=\(String(describing: tab.url)), error=\(String(describing: tab.loadError))")
        }
        source.load(firstURL)
        try await waitForPage(source, title: "First Space Page")
        source.load(secondURL)
        try await waitForPage(source, title: "Second Space Page", back: true)
        let other = try browser.createSpace(title: "Other")
        let saved = try PropertyListDecoder().decode(WindowSession.self,
            from: PropertyListEncoder.binary.encode(browser.windowSession()))
        let savedDefault = try XCTUnwrap(saved.spaceSessions?.first { $0.spaceID == defaultID })
        let interaction = try XCTUnwrap(savedDefault.tabs.first?.interactionState)
        XCTAssertFalse(interaction.isEmpty)
        let restored = BrowserModel(spaces: browser.spaces)
        defer { (browser.allTabs + restored.allTabs).forEach { $0.stopLoading() } }
        restored.restoreSession(saved)
        XCTAssertEqual(restored.activeSpaceID, other.id)
        let restoredSource = try XCTUnwrap(restored.tabAcrossSpaces(withID: source.id))
        XCTAssertNil(restoredSource.webView)
        XCTAssertEqual(restoredSource.interactionState as? Data, interaction)

        XCTAssertTrue(restored.selectSpace(defaultID))
        try await waitForPage(restoredSource, title: "Second Space Page", back: true)
        XCTAssertEqual(restoredSource.backList.map(\.url), [firstURL])
        XCTAssertEqual(restoredSource.webView?.backForwardList.currentItem?.url, secondURL)
        // The archive contains real history. It does not grant a new view access to every local file in it.
        // Exercise navigation in the original view, which received explicit read grants for both files.
        source.goBack()
        try await waitForPage(source, title: "First Space Page", forward: true)
        XCTAssertEqual(source.url, firstURL)
        XCTAssertEqual(source.forwardList.map(\.url), [secondURL])
    }

    func testCorruptAndUnreadableSessionFilesStayUntouchedByLaterSaves() throws {
        for unreadable in [false, true] {
            let root = directory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let path = root.appending(path: "Session.plist")
            let original = Data("corrupt session fixture".utf8)
            if unreadable {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                try original.write(to: path.appending(path: "keep"))
            } else { try original.write(to: path) }
            let store = SessionStore(file: StoreFile(url: path))
            let browser = BrowserModel()
            _ = store.attach(browser)
            browser.addTab(focusAddress: false)
            store.requestSave()
            store.saveBeforeQuitting()
            XCTAssertEqual(try Data(contentsOf: unreadable ? path.appending(path: "keep") : path), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "Session.before-spaces.plist").path))
        }
    }

    func testMigrationBackupIsOwnerOnlyAndNeverReplacesAnOriginalRecoveryCopy() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        let old = try PropertyListEncoder.binary.encode(SessionSnapshot(windows: [WindowSession(tabs: [tab("Original")], selectedIndex: 0)]))
        file.writeNow(old)
        let backup = root.appending(path: "Session.before-spaces.plist")
        let firstStore = SessionStore(file: file)
        XCTAssertEqual(try Data(contentsOf: backup), old)
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let newer = try PropertyListEncoder.binary.encode(SessionSnapshot(windows: [WindowSession(tabs: [tab("Newer")], selectedIndex: 0)]))
        file.writeNow(newer)
        let secondStore = SessionStore(file: file)
        XCTAssertEqual(try Data(contentsOf: backup), old)
        XCTAssertEqual(secondStore.snapshot.windows.first?.tabs.first?.title, "Newer")
        XCTAssertEqual(firstStore.snapshot.windows.first?.tabs.first?.title, "Original")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".Session-backup-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testMigrationKeepsOriginalPropertyListAndPersistsAllSpaces() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        let old = try PropertyListEncoder.binary.encode(SessionSnapshot(windows: [WindowSession(tabs: [tab("Legacy")], selectedIndex: 0)]))
        file.writeNow(old)
        let store = SessionStore(file: file)
        let spaces = BrowserSpaceStore(directory: root)
        let browser = BrowserModel(spaces: spaces)
        _ = store.attach(browser)
        let other = try browser.createSpace(title: "Work")
        store.saveBeforeQuitting()
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Session.before-spaces.plist")), old)
        let relaunched = SessionStore(file: file)
        let next = BrowserModel(spaces: BrowserSpaceStore(directory: root))
        _ = relaunched.attach(next)
        XCTAssertEqual(next.activeSpaceID, other.id)
        XCTAssertTrue(next.allTabs.first?.isSuspended == true)
        XCTAssertEqual(next.allTabs.first?.title, "Legacy")
        XCTAssertEqual(next.allTabs.map(\.id), browser.allTabs.map(\.id))
    }
}

/// Keep automated integration checks from activating or focusing a desktop window.
@MainActor
private final class SpaceActionWindow: NSWindow {
    private(set) var closeRequests = 0
    override func close() { closeRequests += 1; super.close() }
    override func makeKeyAndOrderFront(_ sender: Any?) { }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { true }
}
