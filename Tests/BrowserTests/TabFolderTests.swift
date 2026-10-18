import XCTest
@testable import Browser

@MainActor
final class TabFolderTests: XCTestCase {
    func testNestedFoldersIconsAndPagesAreDurableWithoutWindowSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TabFolderStore(directory: directory)
        let trip = try store.createFolder(title: "Trip", symbol: "airplane", color: .blue)
        let docs = try store.createFolder(title: "Travel Docs", parentID: trip.id, emoji: "🗺️", color: .green)
        let page = try store.savePage(url: XCTUnwrap(URL(string: "https://example.com/tickets")), title: "Tickets", in: docs.id)
        try store.toggleExpanded(docs.id)
        let reopened = TabFolderStore(directory: directory)
        XCTAssertEqual(reopened.items, store.items)
        XCTAssertEqual(reopened.item(docs.id)?.emoji, "🗺️")
        XCTAssertEqual(reopened.path(for: docs), "Trip / Travel Docs")
        XCTAssertFalse(reopened.visibleRows.contains { $0.id == page.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Session.json").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "TabFolders.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCyclesAndMovingIntoPagesAreRejectedWithoutChangingStructure() throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let first = try store.createFolder(title: "First")
        let second = try store.createFolder(title: "Second", parentID: first.id)
        let third = try store.createFolder(title: "Third", parentID: second.id)
        let page = try store.savePage(url: XCTUnwrap(URL(string: "https://example.com")), title: "Example", in: third.id)
        let original = store.items
        XCTAssertThrowsError(try store.move(first.id, to: third.id))
        XCTAssertThrowsError(try store.move(second.id, to: second.id))
        XCTAssertThrowsError(try store.move(first.id, to: page.id))
        XCTAssertEqual(store.items, original)
        try store.move(third.id, to: nil, before: first.id)
        XCTAssertEqual(store.visibleRows.map(\.id), [third.id, page.id, first.id, second.id])
    }

    func testDropIntoNestedFolderExpandsAncestorsAndRemovingFolderKeepsChildren() throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let parent = try store.createFolder(title: "Parent")
        let child = try store.createFolder(title: "Child", parentID: parent.id)
        let page = try store.savePage(url: XCTUnwrap(URL(string: "https://example.com")), title: "Example", in: nil)
        try store.toggleExpanded(parent.id)
        try store.toggleExpanded(child.id)
        try store.move(page.id, to: child.id)
        XCTAssertEqual(store.visibleRows.map(\.depth), [0, 1, 2])
        try store.removeFolder(parent.id)
        XCTAssertEqual(store.visibleRows.map(\.id), [child.id, page.id])
        XCTAssertNil(store.item(child.id)?.parentID)
        XCTAssertEqual(store.item(page.id)?.parentID, child.id)
    }

    func testFolderPageSessionRestoresLazilyAndClosingDoesNotDeleteSavedPage() throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let folder = try store.createFolder(title: "Work")
        let page = try store.savePage(url: XCTUnwrap(URL(string: "https://example.com/work")), title: "Work page", in: folder.id)
        let browser = BrowserModel(folders: store)
        browser.restoreSession(.init(tabs: [.init(url: page.url, title: page.title), .init(url: nil, title: "")], selectedIndex: 1))
        let tab = try XCTUnwrap(browser.tabs.first)
        XCTAssertEqual(tab.folderPageID, page.id, "Recover membership even if a crash preceded the window snapshot")
        XCTAssertTrue(tab.isSuspended)
        XCTAssertEqual(browser.regularTabs.count, 1)
        XCTAssertEqual(browser.unpinnedTabs.count, 2, "Horizontal tabs must still include open folder pages")
        let snapshot = BrowserSessionSnapshot(browser: browser)
        let second = BrowserModel(folders: store)
        second.restoreSession(try JSONDecoder().decode(BrowserSessionSnapshot.self, from: JSONEncoder().encode(snapshot)))
        XCTAssertEqual(second.tabs.first?.folderPageID, page.id)
        XCTAssertTrue(second.tabs[0].isSuspended)
        browser.closeTab(tab.id)
        XCTAssertEqual(store.item(page.id), page)
        browser.openFolderPage(page)
        let openedID = browser.activeTabID
        browser.openFolderPage(page)
        XCTAssertEqual(browser.activeTabID, openedID, "Opening a saved item should reuse its live tab")
        browser.closeActiveTab()
        XCTAssertNotNil(store.item(page.id))
        browser.openFolderPage(page)
        XCTAssertNotEqual(browser.activeTabID, openedID)
    }

    func testExplicitFolderMembershipWinsOverMatchingFavoriteURL() throws {
        let pins = PinnedPageStore(directory: .temporaryDirectory, enabled: false)
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        _ = try pins.pin(url: url, title: "Favorite")
        let page = try store.savePage(url: url, title: "Saved page", in: nil)
        let browser = BrowserModel(pinnedPages: pins, folders: store)
        browser.restoreSession(.init(tabs: [.init(url: url, title: "Saved", folderPageID: page.id), .init(url: nil, title: "")], selectedIndex: 1))
        XCTAssertNil(browser.tabs[0].pinnedPageID)
        XCTAssertEqual(browser.tabs[0].folderPageID, page.id)
    }

    func testMovingUnloadedPageToTemporaryTabsKeepsItWithoutLoading() throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let page = try store.savePage(url: XCTUnwrap(URL(string: "https://example.com")), title: "Example", in: nil)
        let browser = BrowserModel(folders: store)
        let activeID = browser.activeTabID
        browser.moveFolderPageToTemporaryTabs(page)
        XCTAssertNil(store.item(page.id))
        XCTAssertEqual(browser.activeTabID, activeID)
        XCTAssertEqual(browser.regularTabs.count, 2)
        XCTAssertTrue(browser.tabs[1].isSuspended)
        XCTAssertEqual(browser.tabs[1].url, page.url)
    }

    func testInvalidPagesAndFailedWritesDoNotPublishPartialFolders() throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        XCTAssertThrowsError(try store.createFolder(title: "Unsafe", initialPage: (XCTUnwrap(URL(string: "javascript:alert(1)")), "Unsafe")))
        XCTAssertTrue(store.items.isEmpty)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let broken = TabFolderStore(directory: file)
        XCTAssertThrowsError(try broken.createFolder(title: "Must not appear"))
        XCTAssertTrue(broken.items.isEmpty)
    }

    func testTabDropKeepsWebViewAndKeyboardSelectionRevealsItsFolder() throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let folder = try store.createFolder(title: "Saved")
        let child = try store.createFolder(title: "Child", parentID: folder.id)
        let browser = BrowserModel(folders: store)
        let tab = try XCTUnwrap(browser.activeTab)
        tab.load(try XCTUnwrap(URL(string: "https://example.com")))
        let view = tab.webView
        XCTAssertTrue(browser.acceptFolderDrop(tab.id.uuidString, parentID: child.id))
        XCTAssertTrue(tab.webView === view)
        XCTAssertEqual(browser.tabs.count, 1)
        let pageID = try XCTUnwrap(tab.folderPageID)
        XCTAssertEqual(store.item(pageID)?.parentID, child.id)
        XCTAssertFalse(browser.acceptFolderDrop("browser-folder:\(folder.id)", parentID: child.id))
        browser.addTab()
        try store.toggleExpanded(folder.id)
        XCTAssertFalse(store.visibleRows.contains { $0.id == pageID })
        browser.activeTabID = tab.id
        XCTAssertTrue(store.visibleRows.contains { $0.id == pageID })
        XCTAssertTrue(browser.acceptFolderDrop("browser-folder:\(pageID)", parentID: nil))
        XCTAssertNil(store.item(pageID)?.parentID)
    }
}
