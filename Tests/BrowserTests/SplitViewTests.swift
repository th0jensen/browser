import XCTest
@testable import Browser

@MainActor
final class SplitViewTests: XCTestCase {
    private func fixture(_ count: Int = 5) -> BrowserModel {
        let model = BrowserModel()
        for _ in 1..<count { model.addTab(focusAddress: false) }
        return model
    }

    func testCombinesExistingPagesAsOneItemWithoutReplacingWebViews() throws {
        let model = fixture()
        let first = model.tabs[0], second = model.tabs[1]
        let firstView = try XCTUnwrap(first.webView), secondView = try XCTUnwrap(second.webView)
        XCTAssertTrue(model.makeSplit(second.id, with: first.id))
        let group = try XCTUnwrap(model.activeSplit)
        XCTAssertEqual(group.tabIDs, [first.id, second.id])
        XCTAssertEqual(group.anchorID, first.id)
        XCTAssertEqual(model.visibleTabIDs, [first.id, second.id])
        XCTAssertFalse(model.isSplitCompanion(first))
        XCTAssertTrue(model.isSplitCompanion(second))
        XCTAssertTrue(first.webView === firstView)
        XCTAssertTrue(second.webView === secondView)
        XCTAssertEqual(model.tabs.count, 5)
        model.activeTabID = second.id
        XCTAssertEqual(model.activeSplit?.focusedID, second.id)
        model.activeTabID = model.tabs[4].id
        model.selectRepresentedTab(first)
        XCTAssertEqual(model.activeTabID, second.id)
    }

    func testSeparatingAndRemovingPanePreservesEveryPageAndItsView() throws {
        let model = fixture(3)
        let tabs = model.tabs
        let views = tabs.map(\.webView)
        model.makeSplit(tabs[1].id, with: tabs[0].id)
        model.activeTabID = tabs[1].id
        model.removeSplitPane(tabs[1].id)
        XCTAssertTrue(model.splits.isEmpty)
        XCTAssertFalse(model.isSplitCompanion(tabs[1]))
        model.makeSplit(tabs[1].id, with: tabs[0].id)
        model.separateSplit(try XCTUnwrap(model.activeSplit).id)
        XCTAssertTrue(model.splits.isEmpty)
        XCTAssertEqual(model.tabs.map(\.id), tabs.map(\.id))
        for (tab, view) in zip(model.tabs, views) { XCTAssertTrue(tab.webView === view) }
    }

    func testTwoPaneLimitRejectsThirdPagesAndGroupMergesWithoutLosingPages() {
        let model = fixture(5)
        let ids = model.tabs.map(\.id)
        model.makeSplit(ids[1], with: ids[0])
        model.makeSplit(ids[3], with: ids[2], orientation: .vertical)
        XCTAssertFalse(model.makeSplit(ids[2], with: ids[0]))
        XCTAssertFalse(model.makeSplit(ids[4], with: ids[0]))
        XCTAssertFalse(model.canSplitDrag(ids[4].uuidString, with: ids[0].uuidString))
        XCTAssertFalse(model.makeSplit(ids[1], with: ids[0]))
        XCTAssertFalse(model.makeSplit(ids[0], with: ids[0]))
        XCTAssertEqual(model.splits.count, 2)
        XCTAssertEqual(model.tabs.map(\.id), ids)
        model.closeTab(ids[0])
        XCTAssertNil(model.split(containing: ids[1]))
        XCTAssertEqual(model.activeTabID, ids[2])
    }

    func testClosingRepresentedSplitClosesOnlyItsFocusedPane() {
        let model = fixture(4)
        let ids = model.tabs.map(\.id)
        model.makeSplit(ids[1], with: ids[0])
        model.activeTabID = ids[1]
        model.closeRepresentedTab(model.tabs[0])
        XCTAssertEqual(model.tabs.map(\.id), [ids[0], ids[2], ids[3]])
        XCTAssertEqual(model.activeTabID, ids[0])
        XCTAssertTrue(model.splits.isEmpty)
        model.makeSplit(ids[2], with: ids[0])
        model.activeTabID = ids[2]
        model.closeActiveTab()
        XCTAssertEqual(model.activeTabID, ids[0])
        XCTAssertEqual(model.tabs.map(\.id), [ids[0], ids[3]])
    }

    func testGroupedKeyboardNavigationAndClosingOtherTabs() {
        let model = fixture(4)
        let ids = model.tabs.map(\.id)
        model.makeSplit(ids[1], with: ids[0])
        model.activeTabID = ids[1]
        model.switchTab(by: 1)
        XCTAssertEqual(model.activeTabID, ids[2])
        model.switchTab(by: -1)
        XCTAssertEqual(model.activeTabID, ids[1])
        model.closeOtherTabs(than: ids[0])
        XCTAssertEqual(model.tabs.map(\.id), Array(ids.prefix(2)))
        XCTAssertEqual(model.splits.count, 1)
        model.closeRepresentedTab(model.tabs[0])
        XCTAssertEqual(model.tabs.count, 1)
        XCTAssertTrue(model.splits.isEmpty)
        XCTAssertEqual(model.tabs.first?.id, ids[1])
    }

    func testSessionRestoresPaneOrderFocusSizesAndOrientation() throws {
        let model = fixture(4)
        let ids = model.tabs.map(\.id)
        model.makeSplit(ids[1], with: ids[0])
        let group = try XCTUnwrap(model.activeSplit)
        model.setSplitOrientation(group.id, .vertical)
        model.setSplitWeights(group.id, [0.35, 0.65])
        model.reverseSplit(group.id)
        model.activeTabID = ids[1]
        model.activeTabID = ids[3]
        let snapshot = BrowserSessionSnapshot(browser: model)
        let data = try JSONEncoder().encode(snapshot)
        let restored = fixture(1)
        restored.restoreSession(try JSONDecoder().decode(BrowserSessionSnapshot.self, from: data))
        XCTAssertEqual(BrowserSessionSnapshot(browser: restored), snapshot)
        let saved = try XCTUnwrap(restored.splits.first)
        XCTAssertEqual(saved.tabIDs, [restored.tabs[1].id, restored.tabs[0].id])
        XCTAssertEqual(saved.orientation, .vertical)
        XCTAssertEqual(saved.anchorID, restored.tabs[0].id)
        XCTAssertEqual(saved.focusedID, restored.tabs[1].id)
        XCTAssertEqual(saved.weights, [0.65, 0.35])
    }

    func testOldAndMalformedSessionsDoNotCreateInvalidOrOverlappingSplits() throws {
        let old = Data(#"{"tabs":[{"title":""}],"selectedIndex":0}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(BrowserSessionSnapshot.self, from: old).splits)
        let model = fixture(4)
        let valid = BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [0, 1], anchorIndex: 0,
                                                focusedIndex: 1, orientation: .horizontal, weights: [-1, 0])
        var overlap = valid; overlap.id = UUID(); overlap.tabIndices = [1, 2]
        var invalid = valid; invalid.id = UUID(); invalid.tabIndices = [2, 999]
        model.restoreSplits([valid, overlap, invalid])
        XCTAssertEqual(model.splits.count, 1)
        XCTAssertEqual(model.splits[0].weights, [0.5, 0.5])
        XCTAssertEqual(SplitTabGroup.normalizedWeights([.infinity, 1], count: 2), [0.5, 0.5])
        XCTAssertEqual(SplitTabGroup.normalizedWeights([0.00001, 1], count: 2), [0.5, 0.5])
    }

    func testCenterDropSplitsButPassingEdgesStillReordersAndEscapeCancels() {
        let model = fixture(2)
        let a = model.tabs[0].id.uuidString, b = model.tabs[1].id.uuidString
        let drag = model.tabDrag
        let top = CGRect(x: 0, y: 0, width: 200, height: 32)
        let bottom = top.offsetBy(dx: 0, dy: 36)
        let splitTarget = TabReorderController.splitPrefix + b
        drag.register(a, frame: top, axis: .vertical)
        drag.register(b, frame: bottom, axis: .vertical)
        drag.register(splitTarget, frame: bottom.insetBy(dx: 0, dy: 9), axis: .vertical, priority: 3)
        var crossings = 0
        drag.begin(a, frame: top, axis: .vertical, crossing: { _, _ in crossings += 1 }, completion: { model.finishDraggedTab(a, over: $0) })
        drag.update(translation: CGSize(width: 99, height: 36))
        XCTAssertEqual(drag.splitTarget, splitTarget)
        XCTAssertEqual(drag.splitTargetFrame, bottom.insetBy(dx: 0, dy: 9))
        XCTAssertEqual(crossings, 0)
        drag.endGesture()
        XCTAssertEqual(model.splits.count, 1)
        model.separateSplit(model.splits[0].id)
        drag.begin(a, frame: top, axis: .vertical, crossing: { _, _ in crossings += 1 }, completion: { _ in })
        drag.update(translation: CGSize(width: 0, height: 48))
        XCTAssertNil(drag.splitTarget)
        XCTAssertEqual(crossings, 1)
        drag.finish(cancelled: true)
        drag.endGesture()
        XCTAssertTrue(model.splits.isEmpty)
    }

    func testSavedPageDropMaterializesOnlyTheTwoPagesAndKeepsDescriptors() throws {
        let model = fixture(1)
        let a = try model.folders.savePage(url: URL(string: "https://example.com/a")!, title: "Saved A", in: nil)
        let b = try model.folders.savePage(url: URL(string: "https://example.com/b")!, title: "Saved B", in: nil)
        let source = SidebarDragItem.pinned(a.id).payload, target = SidebarDragItem.pinned(b.id).payload
        XCTAssertTrue(model.canSplitDrag(source, with: target))
        model.finishDraggedTab(source, over: TabReorderController.splitPrefix + target)
        XCTAssertEqual(model.splits.count, 1)
        XCTAssertEqual(model.tabs.count, 3)
        XCTAssertEqual(model.folders.pages.count, 2)
        XCTAssertEqual(model.sidebarFolderRows.filter { $0.item.kind == .page }.count, 1)
        XCTAssertEqual(Set(model.activeSplit!.tabIDs), model.visibleTabIDs)
        XCTAssertTrue(model.activeSplit!.tabIDs.allSatisfy { model.tab(withID: $0)?.webView != nil })
    }

    func testWebpagePreviewTracksPointerAndCancelRestoresNormalDragWithoutChangingTabs() {
        let model = fixture(3)
        let source = model.tabs[0].id.uuidString, target = model.tabs[1].id.uuidString
        let drag = model.tabDrag
        let original = BrowserSessionSnapshot(browser: model)
        let row = CGRect(x: 0, y: 30, width: 220, height: 32)
        let page = CGRect(x: 240, y: 0, width: 800, height: 600)
        let owner = UUID()
        drag.register(source, frame: row, axis: .vertical)
        drag.registerPage(frame: page, payload: target, owner: owner)
        drag.begin(source, frame: row, axis: .vertical, crossing: { _, _ in XCTFail("Page preview must not reorder sidebar tabs") },
                   completion: { model.finishDraggedTab(source, over: $0) })
        drag.update(translation: CGSize(width: 800, height: 200), pointer: CGPoint(x: 1000, y: 300))
        XCTAssertEqual(drag.pageSplitEdge, .right)
        XCTAssertEqual(drag.offset(for: source, frame: row).width, 800)
        XCTAssertEqual(BrowserSessionSnapshot(browser: model), original)
        drag.update(translation: CGSize(width: 600, height: 10), pointer: CGPoint(x: 640, y: 10))
        XCTAssertEqual(drag.pageSplitEdge, .top)
        drag.finish(cancelled: true)
        drag.endGesture()
        XCTAssertNil(drag.pageSplitEdge)
        XCTAssertEqual(BrowserSessionSnapshot(browser: model), original)
        drag.unregisterPage(owner: owner)
    }

    func testWebpageDropPreservesChosenSideAndAllocatesHalfToEachGroup() throws {
        for edge in SplitEdge.allCases {
            let model = fixture(3)
            let source = model.tabs[0], target = model.tabs[1]
            let drag = model.tabDrag
            let row = CGRect(x: 0, y: 30, width: 220, height: 32)
            let page = CGRect(x: 240, y: 0, width: 800, height: 600)
            drag.registerPage(frame: page, payload: target.id.uuidString, owner: UUID())
            drag.begin(source.id.uuidString, frame: row, axis: .vertical, crossing: { _, _ in },
                       completion: { model.finishDraggedTab(source.id.uuidString, over: $0) })
            let point: CGPoint = switch edge {
            case .left: CGPoint(x: 260, y: 300)
            case .right: CGPoint(x: 1020, y: 300)
            case .top: CGPoint(x: 640, y: 10)
            case .bottom: CGPoint(x: 640, y: 590)
            }
            drag.update(translation: .zero, pointer: point)
            XCTAssertEqual(drag.pageSplitEdge, edge)
            drag.endGesture()
            let split = try XCTUnwrap(model.activeSplit)
            XCTAssertEqual(split.orientation, edge.orientation)
            XCTAssertEqual(split.tabIDs, edge.leading ? [source.id, target.id] : [target.id, source.id])
            XCTAssertEqual(split.weights, [0.5, 0.5])
            XCTAssertNil(drag.pageSplitEdge)
        }
    }

    func testWebpageCannotSplitWithItselfOrItsOwnGroup() {
        let model = fixture(2)
        let ids = model.tabs.map(\.id)
        let drag = model.tabDrag
        let row = CGRect(x: 0, y: 30, width: 220, height: 32)
        let page = CGRect(x: 240, y: 0, width: 800, height: 600)
        let owner = UUID()
        drag.registerPage(frame: page, payload: ids[0].uuidString, owner: owner)
        drag.begin(ids[0].uuidString, frame: row, axis: .vertical, crossing: { _, _ in }, completion: { _ in })
        drag.update(translation: .zero, pointer: CGPoint(x: 800, y: 300))
        XCTAssertNil(drag.pageSplitEdge)
        drag.endGesture()
        model.makeSplit(ids[1], with: ids[0])
        XCTAssertFalse(model.canSplitDrag(ids[1].uuidString, with: ids[0].uuidString))
        drag.unregisterPage(owner: UUID())
        // An unrelated old view cannot revoke the currently mounted canvas.
        drag.begin(ids[0].uuidString, frame: row, axis: .vertical, crossing: { _, _ in }, completion: { _ in })
        drag.endGesture()
    }

    func testHorizontalTabCenterIsASplitTargetAndItsEdgesRemainReorderTargets() {
        let model = fixture(2)
        let source = model.tabs[0].id.uuidString, target = model.tabs[1].id.uuidString
        let drag = model.tabDrag
        let a = CGRect(x: 0, y: 0, width: 100, height: 30), b = CGRect(x: 104, y: 0, width: 100, height: 30)
        drag.register(source, frame: a, axis: .horizontal)
        drag.register(target, frame: b, axis: .horizontal)
        drag.register(TabReorderController.splitPrefix + target, frame: b.insetBy(dx: 27, dy: 0), axis: .horizontal, priority: 3)
        var crossed = 0
        drag.begin(source, frame: a, axis: .horizontal, crossing: { _, _ in crossed += 1 }, completion: { _ in })
        drag.update(translation: CGSize(width: 104, height: 99))
        XCTAssertEqual(drag.splitTarget, TabReorderController.splitPrefix + target)
        XCTAssertEqual(drag.offset(for: source, frame: a).height, 0)
        XCTAssertEqual(crossed, 0)
        drag.update(translation: CGSize(width: 145, height: 99))
        XCTAssertNil(drag.splitTarget)
        XCTAssertEqual(crossed, 1)
        drag.endGesture()
    }

    func testLegacyFourPaneSessionKeepsFocusedPairAndReturnsOthersToTabs() {
        let model = fixture(4)
        let ids = model.tabs.map(\.id)
        let legacy = BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [0, 1, 2, 3], anchorIndex: 0,
                                                  focusedIndex: 2, orientation: .horizontal, weights: [0.2, 0.2, 0.3, 0.3])
        model.restoreSplits([legacy])
        XCTAssertEqual(model.splits.count, 1)
        XCTAssertEqual(model.splits[0].tabIDs, [ids[0], ids[2]])
        XCTAssertEqual(model.splits[0].weights, [0.4, 0.6])
        XCTAssertFalse(model.isSplitCompanion(model.tabs[1]))
        XCTAssertFalse(model.isSplitCompanion(model.tabs[3]))
        XCTAssertEqual(model.tabs.count, 4)
    }
}
