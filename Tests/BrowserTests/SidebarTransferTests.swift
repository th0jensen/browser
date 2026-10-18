import AppKit
import XCTest
@testable import Browser

@MainActor
final class SidebarTransferTests: XCTestCase {
    private func fixture(directory: URL? = nil) -> BrowserModel {
        let folder = directory ?? .temporaryDirectory
        let model = BrowserModel(pinnedPages: PinnedPageStore(directory: folder, enabled: directory != nil),
                                 folders: TabFolderStore(directory: folder, enabled: directory != nil))
        model.restoreSession(.init(tabs: [
            .init(url: URL(string: "https://example.com/rust"), title: "Rust Ownership"),
            .init(url: URL(string: "https://example.com/ww2"), title: "Battle of Britain"),
            .init(url: nil, title: "")
        ], selectedIndex: 2))
        return model
    }

    func testFolderDragHidesDescendantsWithoutChangingSavedExpansion() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = fixture(directory: directory)
        let a = try model.folders.createFolder(title: "Learning")
        let nested = try model.folders.createFolder(title: "Nested", parentID: a.id)
        _ = try model.folders.savePage(url: URL(string: "https://example.com/nested")!, title: "Nested Page", in: nested.id)
        let b = try model.folders.createFolder(title: "Travel")
        let original = try Data(contentsOf: directory.appending(path: "TabFolders.json"))
        model.tabDrag.begin(SidebarDragItem.pinned(a.id).payload, frame: .init(x: 0, y: 0, width: 200, height: 32),
                            axis: .vertical, crossing: { _, _ in }, completion: { _ in })
        XCTAssertEqual(model.sidebarFolderRows.map(\.id), [a.id, b.id])
        XCTAssertTrue(try XCTUnwrap(model.folders.item(a.id)).isExpanded)
        XCTAssertEqual(try Data(contentsOf: directory.appending(path: "TabFolders.json")), original)
        model.crossDraggedTab(SidebarDragItem.pinned(a.id).payload, past: SidebarDragItem.pinned(b.id).payload, direction: 1)
        XCTAssertEqual(model.sidebarFolderRows.map(\.id), [b.id, a.id])
        model.tabDrag.endGesture()
        XCTAssertEqual(model.sidebarFolderRows.map(\.id), [b.id, a.id, nested.id, model.folders.pages[0].id])
        try model.folders.toggleExpanded(a.id)
        model.tabDrag.begin(SidebarDragItem.pinned(a.id).payload, frame: .zero, axis: .vertical,
                            crossing: { _, _ in }, completion: { _ in })
        model.tabDrag.finish(cancelled: true)
        model.tabDrag.endGesture()
        XCTAssertFalse(try XCTUnwrap(model.folders.item(a.id)).isExpanded, "A previously closed folder stays closed")
        XCTAssertEqual(model.sidebarFolderRows.count, 2)
    }

    func testTidyFolderDragRestoresExpansionAndDoesNotPersistTemporaryCollapse() {
        let model = fixture()
        let section = TemporaryTabSection(title: "Rust Learning", symbol: "book", isExpanded: true)
        model.tabs[0].temporarySection = section
        model.tabs[1].temporarySection = section
        let before = BrowserSessionSnapshot(browser: model)
        model.tabDrag.begin(SidebarDragItem.section(section.id).payload, frame: .zero, axis: .vertical,
                            crossing: { _, _ in }, completion: { _ in })
        XCTAssertFalse(model.sectionIsExpanded(section))
        XCTAssertEqual(BrowserSessionSnapshot(browser: model), before)
        model.tabDrag.endGesture()
        XCTAssertTrue(model.sectionIsExpanded(section))
        model.setTemporarySectionExpanded(section.id, expanded: false)
        let closed = model.tabs[0].temporarySection
        model.tabDrag.begin(SidebarDragItem.section(section.id).payload, frame: .zero, axis: .vertical,
                            crossing: { _, _ in }, completion: { _ in })
        model.tabDrag.endGesture()
        XCTAssertFalse(model.sectionIsExpanded(closed))
    }

    func testTabCanMoveBetweenEssentialPinnedAndTidyWithoutReloadingOrDuplicating() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = fixture(directory: directory)
        let original = model.tabs[0]
        let selected = model.activeTabID
        let ids = Set(model.tabs.map(\.id))
        model.finishDraggedTab(original.id.uuidString, over: SidebarDragItem.essentials.payload)
        let essential = try XCTUnwrap(model.pinnedPages.items.first)
        XCTAssertEqual(original.pinnedPageID, essential.id)
        XCTAssertEqual(model.pinnedPages.items.count, 1)
        XCTAssertNil(original.webView)
        model.finishDraggedTab(SidebarDragItem.essential(essential.id).payload, over: SidebarDragItem.pinnedRoot.payload)
        XCTAssertTrue(model.pinnedPages.items.isEmpty)
        let pinned = try XCTUnwrap(model.folders.pages.first)
        XCTAssertEqual(original.folderPageID, pinned.id)
        XCTAssertEqual(TabFolderStore(directory: directory).pages, [pinned])
        XCTAssertTrue(PinnedPageStore(directory: directory).items.isEmpty)
        let section = TemporaryTabSection(title: "Study", symbol: "book")
        model.tabs[1].temporarySection = section
        model.finishDraggedTab(SidebarDragItem.pinned(pinned.id).payload, over: SidebarDragItem.section(section.id).payload)
        XCTAssertNil(original.folderPageID)
        XCTAssertEqual(original.temporarySection, section)
        XCTAssertTrue(model.folders.pages.isEmpty)
        XCTAssertEqual(Set(model.tabs.map(\.id)), ids)
        XCTAssertEqual(model.activeTabID, selected)
        XCTAssertNil(original.webView)
        model.finishDraggedTab(original.id.uuidString, over: SidebarDragItem.temporaryRoot.payload)
        XCTAssertNil(original.temporarySection)
    }

    func testClosedEssentialCanBeDraggedOutAsUnloadedTemporaryTab() throws {
        let model = fixture()
        let page = try model.pinnedPages.pin(url: URL(string: "https://example.com/closed")!, title: "Closed Essential")
        let count = model.tabs.count
        let selected = model.activeTabID
        model.finishDraggedTab(SidebarDragItem.essential(page.id).payload, over: SidebarDragItem.temporaryRoot.payload)
        XCTAssertEqual(model.tabs.count, count + 1)
        XCTAssertEqual(model.tabs.last?.url, page.url)
        XCTAssertTrue(model.tabs.last?.isSuspended == true)
        XCTAssertNil(model.tabs.last?.webView)
        XCTAssertTrue(model.pinnedPages.items.isEmpty)
        XCTAssertEqual(model.activeTabID, selected)
    }

    func testClosedPinnedTabCanBecomeEssentialWithoutLoadingIt() throws {
        let model = fixture()
        let page = try model.folders.savePage(url: URL(string: "https://example.com/closed")!, title: "Closed Pin", in: nil)
        let count = model.tabs.count
        model.finishDraggedTab(SidebarDragItem.pinned(page.id).payload, over: SidebarDragItem.essentials.payload)
        XCTAssertEqual(model.tabs.count, count)
        XCTAssertTrue(model.folders.pages.isEmpty)
        XCTAssertEqual(model.pinnedPages.items.first?.title, page.title)
    }

    func testEssentialLimitNeverRemovesTheSourcePinnedTab() throws {
        let model = fixture()
        for i in 0..<9 { try model.pinnedPages.pin(url: URL(string: "https://example.com/essential/\(i)")!, title: "Essential \(i)") }
        let page = try model.folders.savePage(url: URL(string: "https://example.com/keep")!, title: "Keep Me", in: nil)
        model.finishDraggedTab(SidebarDragItem.pinned(page.id).payload, over: SidebarDragItem.essentials.payload)
        XCTAssertEqual(model.folders.pages, [page])
        XCTAssertEqual(model.pinnedPages.items.count, 9)
        XCTAssertNotNil(model.pinnedPages.errorMessage)
    }

    func testPinTidyFolderWritesWholeGroupAndPreservesTitlesIconOrderAndCollapse() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = fixture(directory: directory)
        let section = TemporaryTabSection(title: "History Study", symbol: "globe.europe.africa", isExpanded: false)
        model.tabs[0].temporarySection = section
        model.tabs[1].temporarySection = section
        let members = Array(model.tabs.prefix(2))
        model.pinTemporarySection(section.id)
        let restored = TabFolderStore(directory: directory)
        let folder = try XCTUnwrap(restored.folders.first?.item)
        XCTAssertEqual(folder.title, section.title)
        XCTAssertEqual(folder.symbol, section.symbol)
        XCTAssertFalse(folder.isExpanded)
        XCTAssertEqual(restored.pages.map(\.title), ["Rust Ownership", "Battle of Britain"])
        XCTAssertEqual(restored.pages.map(\.id), members.compactMap(\.folderPageID))
        XCTAssertTrue(members.allSatisfy { $0.temporarySection == nil && $0.webView == nil })
        XCTAssertEqual(model.regularTabs.count, 1)
        XCTAssertTrue(model.pinnedPages.items.isEmpty, "Pin as Folder creates Pinned Tabs, not Essential Tabs")
    }

    func testFailedGroupWriteLeavesEveryTemporaryTabInPlace() throws {
        let blocker = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let model = fixture(directory: blocker)
        let section = TemporaryTabSection(title: "Rust Learning", symbol: "book")
        model.tabs[0].temporarySection = section
        model.pinTemporarySection(section.id)
        XCTAssertTrue(model.folders.items.isEmpty)
        XCTAssertEqual(model.tabs[0].temporarySection, section)
        XCTAssertNil(model.tabs[0].folderPageID)
    }

    func testEssentialZoneWinsOverNestedTileAndRootTargetAliasesRemainDistinct() {
        let drag = TabReorderController()
        let source = CGRect(x: 0, y: 200, width: 200, height: 32)
        let zone = CGRect(x: 0, y: 0, width: 200, height: 80)
        drag.register("source", frame: source, axis: .vertical)
        drag.register("tile", frame: zone, axis: .vertical)
        drag.register(SidebarDragItem.essentials.payload, frame: zone, axis: .vertical, priority: 2)
        var dropped: String?
        drag.begin("source", frame: source, axis: .vertical, crossing: { _, _ in }, completion: { dropped = $0 })
        drag.update(translation: CGSize(width: 900, height: -176))
        drag.endGesture()
        XCTAssertEqual(dropped, SidebarDragItem.essentials.payload)
        XCTAssertEqual(SidebarDragItem("browser-pinned-end"), .pinnedRoot)
        XCTAssertEqual(SidebarDragItem("browser-temporary-end"), .temporaryRoot)
        XCTAssertNil(SidebarDragItem("foreign:bad"))
    }
}

extension SidebarTransferTests {
    func testReparentedRowKeepsItsFreshDragTargetWhenOldViewDisappears() {
        let drag = TabReorderController()
        let old = UUID(), current = UUID()
        let a = CGRect(x: 0, y: 0, width: 200, height: 32)
        let b = a.offsetBy(dx: 0, dy: 36)
        drag.register("source", frame: a, axis: .vertical, owner: old)
        drag.register("source", frame: b, axis: .vertical, owner: current)
        drag.unregister("source", owner: old)
        drag.register("destination", frame: a, axis: .vertical)
        var crossed: [String] = []
        drag.begin("source", frame: b, axis: .vertical, crossing: { id, _ in crossed.append(id) }, completion: { _ in })
        drag.update(translation: CGSize(width: 0, height: -36))
        XCTAssertEqual(crossed, ["destination"])
        drag.endGesture()
    }

    func testTidyFolderReordersAsOneGroupAndRestoresItsOpenState() {
        let model = fixture()
        let rust = TemporaryTabSection(title: "Rust Learning", symbol: "curlybraces")
        let history = TemporaryTabSection(title: "WW2 Study", symbol: "globe.europe.africa")
        let first = model.tabs[0], second = model.tabs[1]
        first.temporarySection = rust
        second.temporarySection = history
        model.tabDrag.begin(SidebarDragItem.section(rust.id).payload, frame: .zero, axis: .vertical,
                            crossing: { _, _ in }, completion: { _ in })
        model.crossDraggedTab(SidebarDragItem.section(rust.id).payload,
                             past: SidebarDragItem.section(history.id).payload, direction: 1)
        XCTAssertEqual(model.tabs.prefix(2).map(\.id), [second.id, first.id])
        XCTAssertFalse(model.sectionIsExpanded(rust))
        XCTAssertTrue(first.temporarySection?.isExpanded == true)
        model.tabDrag.endGesture()
        XCTAssertTrue(model.sectionIsExpanded(first.temporarySection))
    }
}
