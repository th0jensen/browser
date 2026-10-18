import AppKit
import SwiftUI
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

    func testFolderHoverFeedbackOccursOnEntryAndReentryButNotWhileLingeringOrExpanding() async throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let folder = try store.createFolder(title: "Drop here")
        _ = try store.savePage(url: URL(string: "https://example.com/first")!, title: "First child", in: folder.id)
        _ = try store.savePage(url: URL(string: "https://example.com/second")!, title: "Second child", in: folder.id)
        let browser = BrowserModel(folders: store)
        browser.restoreSession(BrowserSessionSnapshot(tabs: [
            .init(url: URL(string: "https://example.com/dragged")!, title: "Dragged tab"),
            .init(url: nil, title: ""),
        ], selectedIndex: 1))
        let source = browser.tabs[0].id.uuidString
        var feedback = 0
        browser.reorderFeedback = { feedback += 1 }
        var sidebarFrame: CGRect?
        let host = NSHostingView(rootView: FolderSidebar(browser: browser, rowHeight: 32)
            .frame(width: 220, height: 160, alignment: .top)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { sidebarFrame = $0 })
        host.sceneBridgingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 160),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { browser.tabDrag.endGesture(); window.close() }
        try await waitForFolderHover { sidebarFrame != nil }
        let targetFrame = try XCTUnwrap(sidebarFrame)
        let sourceFrame = CGRect(x: targetFrame.minX, y: targetFrame.minY + 125, width: 220, height: 32)
        browser.tabDrag.register(source, frame: sourceFrame, axis: .vertical)
        XCTAssertTrue(browser.tabDrag.begin(source, frame: sourceFrame, axis: .vertical,
                                            crossing: { _, _ in }, completion: { _ in }))
        let entered = CGSize(width: 0, height: targetFrame.minY + 16 - sourceFrame.midY)
        browser.tabDrag.update(translation: entered)
        try await waitForFolderHover { feedback == 1 }
        let firstChild = CGSize(width: 0, height: entered.height + 32 + BrowserChrome.smallGap)
        browser.tabDrag.update(translation: firstChild)
        try await waitForFolderHover { feedback == 2 }
        let secondChild = CGSize(width: 0, height: firstChild.height + 32 + BrowserChrome.smallGap)
        browser.tabDrag.update(translation: secondChild)
        try await waitForFolderHover { feedback == 3 }
        for offset in [1.0, 2.0, -1.0] {
            browser.tabDrag.update(translation: CGSize(width: 0, height: secondChild.height + offset))
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertEqual(feedback, 3, "Pointer motion inside the same child row must stay quiet")
        browser.tabDrag.update(translation: .zero)
        try await waitForFolderHover { !browser.tabDrag.isOver(SidebarDragItem.pinned(folder.id).payload) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        browser.tabDrag.update(translation: entered)
        try await waitForFolderHover { feedback == 4 }
        browser.tabDrag.endGesture()
        browser.changeFolders { try store.toggleExpanded(folder.id) }
        browser.changeFolders { try store.toggleExpanded(folder.id) }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(feedback, 4, "Folder expansion and collapse are unrelated to drag-hover feedback")
    }

    func testFolderHoverAcceptsTemporarySavedAndEssentialTabsButRejectsOtherSources() throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let pins = PinnedPageStore(directory: .temporaryDirectory, enabled: false)
        let folder = try store.createFolder(title: "Target")
        let page = try store.savePage(url: URL(string: "https://example.com/saved")!, title: "Saved", in: folder.id)
        let sibling = try store.savePage(url: URL(string: "https://example.com/sibling")!, title: "Sibling", in: folder.id)
        let rootPage = try store.savePage(url: URL(string: "https://example.com/root")!, title: "Root page", in: nil)
        let essential = try pins.pin(url: URL(string: "https://example.com/essential")!, title: "Essential")
        let browser = BrowserModel(pinnedPages: pins, folders: store)
        browser.restoreSession(BrowserSessionSnapshot(tabs: [
            .init(url: URL(string: "https://example.com/temporary")!, title: "Temporary"),
            .init(url: nil, title: ""),
        ], selectedIndex: 1))
        var feedback = 0
        browser.reorderFeedback = { feedback += 1 }
        let frame = CGRect(x: 0, y: 0, width: 200, height: 32)
        let validSources = [browser.tabs[0].id.uuidString, SidebarDragItem.pinned(page.id).payload,
                            SidebarDragItem.essential(essential.id).payload]
        for source in validSources {
            XCTAssertTrue(browser.tabDrag.begin(source, frame: frame, axis: .vertical,
                                                crossing: { _, _ in }, completion: { _ in }))
            browser.didEnterFolderRowDropTarget(folder.id)
            browser.didEnterFolderRowDropTarget(sibling.id)
            browser.didEnterFolderRowDropTarget(rootPage.id)
            browser.tabDrag.endGesture()
        }
        XCTAssertEqual(feedback, 6, "Saved tabs can hover over their folder and sibling rows, but root pages retain reorder feedback")
        let invalidSources = [browser.tabs[1].id.uuidString, SidebarDragItem.pinned(folder.id).payload,
                              SidebarDragItem.essential(UUID()).payload, SidebarDragItem.section(UUID()).payload, "foreign"]
        for source in invalidSources {
            XCTAssertTrue(browser.tabDrag.begin(source, frame: frame, axis: .vertical,
                                                crossing: { _, _ in }, completion: { _ in }))
            browser.didEnterFolderRowDropTarget(folder.id)
            browser.didEnterFolderRowDropTarget(page.id)
            browser.tabDrag.endGesture()
        }
        XCTAssertEqual(feedback, 6)
        XCTAssertEqual(store.item(page.id)?.parentID, folder.id, "Hover must not move or materialize saved pages")
        XCTAssertEqual(browser.tabs.count, 2)
    }

    func testSavedChildNativeReorderPulsesOncePerRowWithoutDuplicateCrossingFeedback() async throws {
        let store = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let folder = try store.createFolder(title: "Saved")
        let pages = try (0..<3).map {
            try store.savePage(url: URL(string: "https://example.com/child/\($0)")!, title: "Child \($0)", in: folder.id)
        }
        let browser = BrowserModel(folders: store)
        browser.tabDrag.canSplit = { _, _ in false } // Isolate row reordering from its independent split targets.
        var feedback = 0
        browser.reorderFeedback = { feedback += 1 }
        var sidebarFrame: CGRect?
        let host = NSHostingView(rootView: FolderSidebar(browser: browser, rowHeight: 32)
            .frame(width: 220, height: 200, alignment: .top)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { sidebarFrame = $0 })
        host.sceneBridgingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
        defer { browser.tabDrag.endGesture(); window.close() }
        try await waitForFolderHover { sidebarFrame != nil }
        let frame = try XCTUnwrap(sidebarFrame)
        let rowSpacing = 32 + BrowserChrome.smallGap
        let sourceFrame = CGRect(x: frame.minX + 14, y: frame.minY + rowSpacing, width: 206, height: 32)
        let source = SidebarDragItem.pinned(pages[0].id).payload
        browser.tabDrag.register(source, frame: sourceFrame, axis: .vertical)
        XCTAssertTrue(browser.tabDrag.begin(source, frame: sourceFrame, axis: .vertical,
            crossing: { target, direction in browser.crossDraggedTab(source, past: target, direction: direction) },
            completion: { _ in }))
        // Jump straight past a child's midpoint so native crossing reorders before SwiftUI processes onChange.
        browser.tabDrag.update(translation: CGSize(width: 0, height: rowSpacing + 1))
        try await waitForFolderHover { feedback == 1 && store.pages.map(\.id) == [pages[1].id, pages[0].id, pages[2].id] }
        for offset in [1.0, 2.0, 3.0] {
            browser.tabDrag.update(translation: CGSize(width: 0, height: rowSpacing + offset))
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertEqual(feedback, 1, "The native crossing and row entry describe the same haptic event")
        browser.tabDrag.update(translation: CGSize(width: 0, height: rowSpacing * 2 + 1))
        try await waitForFolderHover { feedback == 2 && store.pages.map(\.id) == [pages[1].id, pages[2].id, pages[0].id] }
        browser.tabDrag.endGesture()
        XCTAssertTrue(browser.reorderSavedPage(pages[0].id, past: pages[1].id))
        XCTAssertEqual(feedback, 3, "Direct saved-page reorder callers keep their existing feedback")
    }

    private func waitForFolderHover(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Folder hover state did not update")
                throw FolderHoverTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

}

private enum FolderHoverTestError: Error { case timedOut }
