import WebKit
import XCTest
@testable import Browser

@MainActor
final class UpstreamIntegrationTests: XCTestCase {
    private func page(_ name: String) -> URL {
        URL(string: "http://127.0.0.1:9/\(name)")!
    }

    private func assertPrivateConfiguration(_ tab: BrowserTab, in browser: BrowserModel,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        tab.restore()
        let configuration = try XCTUnwrap(tab.webView?.configuration, file: file, line: line)
        XCTAssertTrue(configuration.websiteDataStore === browser.websiteDataStore, file: file, line: line)
        XCTAssertFalse(configuration.websiteDataStore.isPersistent, file: file, line: line)
        XCTAssertNil(configuration.webExtensionController, file: file, line: line)
    }

    private func assertDefaultOwnershipMigration(_ migrated: WindowSession, from legacy: WindowSession,
                                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(migrated.activeSpaceID, BrowserSpaceStore.defaultSpaceID, file: file, line: line)
        XCTAssertEqual(migrated.spaceSessions?.count, 1, file: file, line: line)
        XCTAssertEqual(migrated.spaceSessions?.first?.tabs, migrated.tabs, file: file, line: line)
        XCTAssertTrue(migrated.tabs.allSatisfy { $0.id != nil && $0.spaceID == BrowserSpaceStore.defaultSpaceID
            && $0.profileID == BrowserProfile.defaultID }, file: file, line: line)
        var normalized = migrated
        normalized.activeSpaceID = nil
        normalized.spaceSessions = nil
        normalized.tabs = migrated.tabs.map { tab in
            var tab = tab
            tab.id = nil; tab.spaceID = nil; tab.profileID = nil
            return tab
        }
        XCTAssertEqual(normalized, legacy, file: file, line: line)
    }

    func testAnIsolatedNormalProfileStillRecordsItsSessionAndHistory() throws {
        let history = HistoryStore(file: nil)
        let normal = BrowserModel(history: history, websiteDataStore: .nonPersistent())
        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager())
        let sessions = SessionStore(file: nil)

        XCTAssertFalse(normal.isPrivate)
        XCTAssertFalse(normal.websiteDataStore.isPersistent)
        XCTAssertTrue(normal.history === history)
        normal.activeTab?.restore()
        XCTAssertNotNil(normal.activeTab?.webView?.configuration.webExtensionController)
        XCTAssertTrue(privateWindow.isPrivate)
        XCTAssertNil(privateWindow.history)
        XCTAssertFalse(normal.websiteDataStore === privateWindow.websiteDataStore)
        XCTAssertEqual(sessions.attach(normal), 0)
        XCTAssertEqual(sessions.snapshot.windows.count, 1)
        XCTAssertTrue(normal.sessionStore === sessions)
    }

    func testPrivatePeekPopUpsDuplicateAndSuspensionKeepTheirWindowStore() throws {
        let browser = BrowserModel.makePrivate(downloads: DownloadManager())
        let original = try XCTUnwrap(browser.activeTab)
        try assertPrivateConfiguration(original, in: browser)
        browser.addTab()
        try assertPrivateConfiguration(try XCTUnwrap(browser.activeTab), in: browser)

        let peek = browser.openPeek(from: original)
        try assertPrivateConfiguration(peek, in: browser)
        browser.expandPeek()
        XCTAssertTrue(browser.activeTab === peek)
        try assertPrivateConfiguration(peek, in: browser)
        let openerConfiguration = try XCTUnwrap(peek.webView?.configuration)
        let popUp = browser.openChildTab(of: peek, configuration: openerConfiguration, select: false)
        try assertPrivateConfiguration(popUp, in: browser)

        // Leave the URL-bearing tab suspended so this fixture needs no successful network load.
        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: page("private"), title: "Private page", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil),
        ], selectedIndex: 1))
        let suspended = browser.tabs[0]
        XCTAssertTrue(suspended.isSuspended)
        browser.duplicateTab(suspended.id)
        let duplicate = try XCTUnwrap(browser.activeTab)
        XCTAssertFalse(duplicate === suspended)
        XCTAssertEqual(duplicate.url, page("private"))
        try assertPrivateConfiguration(duplicate, in: browser)
        duplicate.suspend()
        XCTAssertTrue(duplicate.isSuspended)
        duplicate.restore()
        try assertPrivateConfiguration(duplicate, in: browser)
        duplicate.webView?.stopLoading()
    }

    func testPrivateAndExtensionWindowsCannotConsumeOrPersistNormalSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = StoreFile(url: directory.appending(path: "Session.plist"))
        let expected = WindowSession(tabs: [
            TabSession(url: page("saved"), title: "Saved page", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil),
        ], selectedIndex: 1)
        file.writeNow(try PropertyListEncoder().encode(SessionSnapshot(windows: [expected])))
        let sessions = SessionStore(file: file)
        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager())
        let extensionWindow = BrowserModel()
        extensionWindow.isExtensionWindow = true

        XCTAssertEqual(sessions.attach(privateWindow), 0)
        XCTAssertEqual(sessions.attach(extensionWindow), 0)
        XCTAssertEqual(sessions.snapshot.windows, [expected], "Excluded windows must leave pending normal windows intact")
        XCTAssertNil(privateWindow.sessionStore)
        XCTAssertNil(extensionWindow.sessionStore)
        XCTAssertTrue(privateWindow.isBlank)
        XCTAssertTrue(extensionWindow.isBlank)

        let normal = BrowserModel()
        XCTAssertEqual(sessions.attach(normal), 0)
        let migrated = normal.windowSession()
        assertDefaultOwnershipMigration(migrated, from: expected)
        sessions.saveBeforeQuitting()
        let disk = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
        XCTAssertEqual(disk.windows, [migrated])
    }

    func testPrivateSavedPagesAndIntelligenceRemainWithinTheWindow() throws {
        let first = BrowserModel.makePrivate(downloads: DownloadManager())
        let second = BrowserModel.makePrivate(downloads: DownloadManager())
        let normal = BrowserModel()
        let sharedPins = PinnedPageStore.shared.items
        let sharedFolders = TabFolderStore.shared.items
        let pin = try first.pinnedPages.pin(url: page("essential"), title: "Private essential")
        let folder = try first.folders.createFolder(title: "Private folder")
        let saved = try first.folders.savePage(url: page("folder-page"), title: "Private saved page", in: folder.id)

        XCTAssertFalse(first.pinnedPages === second.pinnedPages)
        XCTAssertFalse(first.folders === second.folders)
        XCTAssertFalse(first.pinnedPages === PinnedPageStore.shared)
        XCTAssertFalse(first.folders === TabFolderStore.shared)
        XCTAssertTrue(first.pinnedPages.items.contains { $0.id == pin.id })
        XCTAssertNotNil(first.folders.item(saved.id))
        XCTAssertTrue(second.pinnedPages.items.isEmpty)
        XCTAssertTrue(second.folders.items.isEmpty)
        XCTAssertTrue(normal.pinnedPages.items.isEmpty)
        XCTAssertTrue(normal.folders.items.isEmpty)
        XCTAssertEqual(PinnedPageStore.shared.items, sharedPins)
        XCTAssertEqual(TabFolderStore.shared.items, sharedFolders)

        let tabs = (0..<7).map { TabSession(url: page("temporary-\($0)"), title: "Tab \($0)", interactionState: nil) }
            + [TabSession(url: nil, title: "", interactionState: nil)]
        let session = WindowSession(tabs: tabs, selectedIndex: tabs.count - 1)
        first.restoreSession(session)
        normal.restoreSession(session)
        XCTAssertTrue(normal.canTidyTabs, "The same set of normal tabs should be eligible")
        XCTAssertFalse(first.canTidyTabs)
        first.tidyTemporaryTabs()
        XCTAssertFalse(first.isTidyingTabs)
        XCTAssertTrue(first.namingSavedPageIDs.isEmpty)
        XCTAssertTrue(first.tabs.allSatisfy { $0.temporarySection == nil })
    }

    func testWindowSessionRoundTripPreservesOurMetadataAndSuspendedWebKitState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pins = PinnedPageStore(directory: directory, enabled: false)
        let folders = TabFolderStore(directory: directory, enabled: false)
        let pin = try pins.pin(url: page("essential"), title: "Essential")
        let folder = try folders.createFolder(title: "Research")
        let saved = try folders.savePage(url: page("saved"), title: "Saved", in: folder.id)
        let section = TemporaryTabSection(title: "Reading", symbol: "book", isExpanded: false)
        // Keep this opaque data on a suspended tab; only WebKit should decode real interaction archives.
        let archivedState = Data([0x57, 0x4B, 0x01, 0x02])
        let split = BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [1, 0], anchorIndex: 0,
                                                 focusedIndex: 1, orientation: .vertical, weights: [0.25, 0.75])
        let expected = WindowSession(tabs: [
            TabSession(url: pin.url, title: pin.title, interactionState: archivedState, pinnedPageID: pin.id),
            TabSession(url: saved.url, title: saved.title, interactionState: nil, folderPageID: saved.id),
            TabSession(url: page("temporary"), title: "Read next", interactionState: nil, temporarySection: section),
            TabSession(url: nil, title: "", interactionState: nil),
        ], selectedIndex: 3, splits: [split])
        let encoded = try PropertyListEncoder().encode(SessionSnapshot(windows: [expected]))
        let decoded = try PropertyListDecoder().decode(SessionSnapshot.self, from: encoded)
        let browser = BrowserModel(pinnedPages: pins, folders: folders)
        browser.restoreSession(try XCTUnwrap(decoded.windows.first))

        XCTAssertTrue(browser.tabs[0].isSuspended)
        XCTAssertTrue(browser.tabs[1].isSuspended)
        XCTAssertEqual(browser.tabs[0].interactionState as? Data, archivedState)
        XCTAssertEqual(browser.tabs[0].pinnedPageID, pin.id)
        XCTAssertEqual(browser.tabs[1].folderPageID, saved.id)
        XCTAssertEqual(browser.tabs[2].temporarySection, section)
        XCTAssertEqual(browser.splits.first?.tabIDs, [browser.tabs[1].id, browser.tabs[0].id])
        XCTAssertEqual(browser.splits.first?.focusedID, browser.tabs[1].id)
        let migrated = browser.windowSession()
        assertDefaultOwnershipMigration(migrated, from: expected)

        let file = StoreFile(url: directory.appending(path: "Session.plist"))
        let sessions = SessionStore(file: file)
        _ = sessions.attach(browser)
        sessions.saveBeforeQuitting()
        let onDisk = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
        XCTAssertEqual(onDisk.windows, [migrated])
    }
}
