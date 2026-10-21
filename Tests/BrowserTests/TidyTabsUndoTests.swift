import WebKit
import XCTest
@testable import Browser

@MainActor
final class TidyTabsUndoTests: XCTestCase {
    private func model(isPrivate: Bool = false) -> BrowserModel {
        let browser = BrowserModel(isPrivate: isPrivate)
        browser.restoreSession(.init(tabs: (0..<8).map {
            .init(url: URL(string: "https://example.com/topic/\($0)"), title: "Page \($0)")
        } + [.init(url: nil, title: "")], selectedIndex: 8))
        return browser
    }

    private func group(_ browser: BrowserModel, title: String = "Study") {
        let ids = browser.regularTabs.filter { !$0.isNewTab }.map(\.id)
        browser.applyTidyTabs([.init(section: .init(title: title, symbol: "book"), tabIDs: Array(ids.reversed()))],
                              eligible: Set(ids))
    }

    private func assertPages(_ browser: BrowserModel, _ expected: [UUID], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(browser.tabs.map(\.id)), Set(expected), file: file, line: line)
        XCTAssertEqual(browser.tabs.count, expected.count, file: file, line: line)
    }

    func testUndoRestoresOrderAndPerTabSectionsIncludingExpansionWithoutLoadingPages() {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        let first = TemporaryTabSection(title: "Original", symbol: "book", isExpanded: false)
        let second = TemporaryTabSection(title: "Other", symbol: "clock")
        browser.tabs[0].temporarySection = first
        browser.tabs[1].temporarySection = first
        browser.tabs[3].temporarySection = second
        let sections = browser.tabs.map(\.temporarySection)
        XCTAssertFalse(browser.canUndoTidyTabs)

        group(browser)
        XCTAssertTrue(browser.canUndoTidyTabs)
        XCTAssertNotEqual(browser.tabs.map(\.id), ids)
        browser.undoTidyTabs()

        XCTAssertEqual(browser.tabs.map(\.id), ids)
        XCTAssertEqual(browser.tabs.map(\.temporarySection), sections)
        XCTAssertTrue(browser.tabs.allSatisfy { $0.webView == nil })
        XCTAssertFalse(browser.canUndoTidyTabs)
        XCTAssertTrue(browser.folders.items.isEmpty)
        XCTAssertTrue(browser.pinnedPages.items.isEmpty)
        browser.undoTidyTabs()
        assertPages(browser, ids)
    }

    private func loadBackgroundPage(_ browser: BrowserModel) async throws -> BrowserTab {
        let tab = try XCTUnwrap(browser.tabs.first)
        XCTAssertNotEqual(browser.activeTabID, tab.id)
        tab.restore()
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString("<title>Tidy background fixture</title><p>Local test content.</p>", baseURL: tab.url)
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Tidy background fixture" }
        return tab
    }

    func testUndoSurvivesLiveBackgroundTabSuspensionAndStillCancelsPendingNavigation() async throws {
        let browser = model()
        let tab = try await loadBackgroundPage(browser)
        let view = try XCTUnwrap(tab.webView)
        let pending = PageNavigationRequest(tab: tab, webView: view)
        XCTAssertTrue(pending.isCurrent)
        let original = TemporaryTabSection(title: "Original", symbol: "clock", isExpanded: false)
        tab.temporarySection = original
        let ids = browser.tabs.map(\.id)
        let sections = browser.tabs.map(\.temporarySection)
        group(browser)
        let contentRevision = tab.contentNavigationRevision
        let requestRevision = tab.navigationRevision
        XCTAssertTrue(tab.canSuspend)

        tab.suspend()

        XCTAssertTrue(tab.isSuspended)
        XCTAssertNil(tab.webView)
        XCTAssertGreaterThan(tab.navigationRevision, requestRevision)
        XCTAssertEqual(tab.contentNavigationRevision, contentRevision)
        XCTAssertFalse(pending.isCurrent, "Resource suspension must cancel decisions for the released web view")
        XCTAssertTrue(browser.canUndoTidyTabs)
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs.map(\.id), ids)
        XCTAssertEqual(browser.tabs.map(\.temporarySection), sections)
        XCTAssertNil(tab.webView, "Undo must not restore a suspended web view")
        XCTAssertFalse(browser.canUndoTidyTabs)
        assertPages(browser, ids)
    }

    func testRealMainFrameSameURLAndAwayAndBackNavigationsInvalidateUndo() async throws {
        for awayAndBack in [false, true] {
            let browser = model()
            let tab = try await loadBackgroundPage(browser)
            let view = try XCTUnwrap(tab.webView)
            let url = try XCTUnwrap(tab.url)
            let ids = browser.tabs.map(\.id)
            group(browser)
            let section = tab.temporarySection
            let position = try XCTUnwrap(browser.tabs.firstIndex { $0.id == tab.id })
            let revision = tab.contentNavigationRevision
            if awayAndBack {
                view.loadHTMLString("<title>Away fixture</title>", baseURL: url.appending(path: "away"))
                try await waitUntil { !tab.isLoading && tab.pageTitle == "Away fixture" }
            }
            // Go through WebKit's main-frame policy callback, not invalidateNavigation().
            view.loadHTMLString("<title>Returned fixture</title>", baseURL: url)
            try await waitUntil { !tab.isLoading && tab.pageTitle == "Returned fixture" }
            XCTAssertEqual(tab.url, url)
            XCTAssertGreaterThan(tab.contentNavigationRevision, revision)

            browser.undoTidyTabs()

            XCTAssertEqual(browser.tabs[position].id, tab.id)
            XCTAssertEqual(tab.temporarySection, section)
            assertPages(browser, ids)
        }
    }

    func testExplicitReloadAtSameURLInvalidatesUndoBeforeItsDecisionResumes() async throws {
        let browser = model()
        let tab = try await loadBackgroundPage(browser)
        let view = try XCTUnwrap(tab.webView)
        let pending = PageNavigationRequest(tab: tab, webView: view)
        let ids = browser.tabs.map(\.id)
        group(browser)
        let section = tab.temporarySection
        let position = try XCTUnwrap(browser.tabs.firstIndex { $0.id == tab.id })
        let url = tab.url
        let revision = tab.contentNavigationRevision

        tab.reload()

        XCTAssertGreaterThan(tab.contentNavigationRevision, revision)
        XCTAssertFalse(pending.isCurrent)
        XCTAssertEqual(tab.url, url)
        tab.stopLoading() // The eligibility check does not need an external page response.
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs[position].id, tab.id)
        XCTAssertEqual(tab.temporarySection, section)
        assertPages(browser, ids)
    }

    func testUndoRetainsTabsOpenedAfterGroupingInTheirCurrentSlots() {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        group(browser)
        browser.addTab(focusAddress: false)
        let added = browser.activeTabID
        browser.duplicateTab(ids[0])
        let duplicate = browser.activeTabID
        let newSlots = browser.tabs.enumerated().filter { !ids.contains($0.element.id) }.map { ($0.offset, $0.element.id) }
        browser.undoTidyTabs()

        for (index, id) in newSlots { XCTAssertEqual(browser.tabs[index].id, id) }
        XCTAssertEqual(browser.tabs.filter { ids.contains($0.id) }.map(\.id), ids)
        XCTAssertEqual(browser.activeTabID, duplicate)
        XCTAssertNotNil(added)
        assertPages(browser, ids + newSlots.map { $0.1 })
    }

    func testUndoNeverReopensClosedTabsOrChangesNavigatedTabs() throws {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        group(browser)
        browser.closeTab(ids[2])
        let navigated = try XCTUnwrap(browser.tab(withID: ids[4]))
        navigated.load(URL(string: "about:blank")!)
        let revisionOnly = try XCTUnwrap(browser.tab(withID: ids[5]))
        // Also reject a reload or an away-and-back navigation to the same URL.
        revisionOnly.invalidateNavigation()
        let slots = browser.tabs.enumerated().filter { [navigated.id, revisionOnly.id].contains($0.element.id) }
        let section = navigated.temporarySection
        browser.undoTidyTabs()

        XCTAssertNil(browser.tab(withID: ids[2]))
        XCTAssertEqual(navigated.url?.absoluteString, "about:blank")
        XCTAssertEqual(navigated.temporarySection, section)
        XCTAssertNotNil(revisionOnly.temporarySection)
        for (index, tab) in slots { XCTAssertEqual(browser.tabs[index].id, tab.id) }
        assertPages(browser, ids.filter { $0 != ids[2] })
    }

    func testUndoPreservesLaterManualRenameMoveAndExpansion() throws {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        group(browser)
        let moved = try XCTUnwrap(browser.tab(withID: ids[0]))
        XCTAssertTrue(browser.moveTab(moved.id, to: 0))
        // Reordering within one section must also protect the moved tab.
        let position = try XCTUnwrap(browser.tabs.firstIndex { $0.id == moved.id })
        var renamed = try XCTUnwrap(browser.tab(withID: ids[1])?.temporarySection)
        renamed.title = "My Manual Name"
        browser.tab(withID: ids[1])?.temporarySection = renamed
        browser.tab(withID: ids[3])?.temporarySection?.isExpanded = false
        browser.undoTidyTabs()

        XCTAssertEqual(browser.tabs[position].id, moved.id)
        XCTAssertNotNil(moved.temporarySection)
        XCTAssertEqual(browser.tab(withID: ids[1])?.temporarySection?.title, "My Manual Name")
        XCTAssertEqual(browser.tab(withID: ids[3])?.temporarySection?.isExpanded, false)
        XCTAssertNil(browser.tab(withID: ids[2])?.temporarySection)
        assertPages(browser, ids)
    }

    func testUndoDoesNotReverseExplicitPinAsFolderOrEssentialOrSavedName() throws {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        let section = TemporaryTabSection(title: "Keep", symbol: "book", isExpanded: false)
        browser.applyTidyTabs([.init(section: section, tabIDs: [ids[3], ids[1]])], eligible: Set(ids))
        browser.pinTemporarySection(section.id)
        let saved = try XCTUnwrap(browser.tab(withID: ids[3])?.folderPageID)
        try browser.renameSavedPage(saved, to: "My Saved Name")
        browser.pin(try XCTUnwrap(browser.tab(withID: ids[4])))
        let folders = browser.folders.items
        let pins = browser.pinnedPages.items
        let savedSlots = browser.tabs.enumerated().filter { $0.element.folderPageID != nil || $0.element.pinnedPageID != nil }
        browser.undoTidyTabs()

        XCTAssertEqual(browser.folders.items, folders)
        XCTAssertEqual(browser.pinnedPages.items, pins)
        XCTAssertEqual(browser.folders.item(saved)?.title, "My Saved Name")
        XCTAssertEqual(browser.folders.folders.first?.item.isExpanded, false)
        for (index, tab) in savedSlots { XCTAssertEqual(browser.tabs[index].id, tab.id) }
        assertPages(browser, ids)
    }

    func testRepeatedGroupingUndoRestoresOnlyThePreviousOperation() {
        let browser = model()
        group(browser, title: "First")
        let firstOrder = browser.tabs.map(\.id)
        let firstSections = browser.tabs.map(\.temporarySection)
        group(browser, title: "Second")
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs.map(\.id), firstOrder)
        XCTAssertEqual(browser.tabs.map(\.temporarySection), firstSections)
        XCTAssertFalse(browser.canUndoTidyTabs)
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs.map(\.id), firstOrder)
    }

    func testEmptyInvalidAndNoOpAssignmentsPreserveGroupsAndPreviousUndo() {
        let browser = model()
        let original = browser.tabs.map(\.id)
        group(browser)
        let grouped = BrowserSessionSnapshot(browser: browser)
        let eligible = Set(original)
        let section = TemporaryTabSection(title: "Study", symbol: "book")
        browser.applyTidyTabs([], eligible: eligible)
        browser.applyTidyTabs([.init(section: section, tabIDs: [])], eligible: eligible)
        browser.applyTidyTabs([.init(section: section, tabIDs: [UUID(), original.last!])], eligible: eligible)
        var invalid = TemporaryTabSection(title: "Invalid fixture", symbol: "book")
        // Initialization normalizes whitespace to a valid "Untitled" title.
        invalid.title = " \n\t"
        browser.applyTidyTabs([.init(section: invalid, tabIDs: original)], eligible: eligible)
        let current = browser.regularTabs.filter { !$0.isNewTab }
        browser.applyTidyTabs([.init(section: current[0].temporarySection!, tabIDs: current.map(\.id))], eligible: eligible)
        XCTAssertEqual(BrowserSessionSnapshot(browser: browser), grouped)
        XCTAssertTrue(browser.canUndoTidyTabs)
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs.map(\.id), original)
        XCTAssertTrue(browser.tabs.allSatisfy { $0.temporarySection == nil })
    }

    func testManualSectionReorderKeepsMovedGroupInItsCurrentSlots() {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        let first = TemporaryTabSection(title: "First", symbol: "book")
        let second = TemporaryTabSection(title: "Second", symbol: "clock")
        browser.applyTidyTabs([.init(section: first, tabIDs: Array(ids.prefix(4))),
                               .init(section: second, tabIDs: Array(ids[4..<8]))], eligible: Set(ids))
        browser.crossDraggedTab(SidebarDragItem.section(first.id).payload,
                                past: SidebarDragItem.section(second.id).payload, direction: 1)
        let moved = browser.tabs.enumerated().filter { $0.element.temporarySection?.id == first.id }
        browser.undoTidyTabs()
        for (index, tab) in moved {
            XCTAssertEqual(browser.tabs[index].id, tab.id)
            XCTAssertEqual(tab.temporarySection, first)
        }
        XCTAssertTrue(browser.tabs.filter { ids[4..<8].contains($0.id) }.allSatisfy { $0.temporarySection == nil })
        assertPages(browser, ids)
    }

    func testManualExpansionAndRemovalDisableUndoWhenNoMemberStillMatches() {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        let first = TemporaryTabSection(title: "First", symbol: "book")
        let second = TemporaryTabSection(title: "Second", symbol: "clock")
        browser.applyTidyTabs([.init(section: first, tabIDs: Array(ids.prefix(4))),
                               .init(section: second, tabIDs: Array(ids[4..<8]))], eligible: Set(ids))
        browser.setTemporarySectionExpanded(first.id, expanded: false)
        browser.removeTemporarySection(second.id)
        let manual = BrowserSessionSnapshot(browser: browser)
        XCTAssertFalse(browser.canUndoTidyTabs)
        browser.undoTidyTabs()
        XCTAssertEqual(BrowserSessionSnapshot(browser: browser), manual)
        assertPages(browser, ids)
    }

    func testNewTabAndNonWebURLsAreNotEligibleForApplyOrUndo() {
        let browser = model()
        browser.restoreSession(.init(tabs: [.init(url: URL(filePath: "/tmp/tidy-local.html"), title: "Local"),
                                            .init(url: URL(string: "https://example.com"), title: "Web"),
                                            .init(url: nil, title: "")], selectedIndex: 2))
        let ids = browser.tabs.map(\.id)
        browser.applyTidyTabs([.init(section: .init(title: "Study", symbol: "book"), tabIDs: ids)], eligible: Set(ids))
        XCTAssertNil(browser.tabs[0].temporarySection)
        XCTAssertNotNil(browser.tabs[1].temporarySection)
        XCTAssertNil(browser.tabs[2].temporarySection)
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs.map(\.id), ids)
        XCTAssertTrue(browser.tabs.allSatisfy { $0.temporarySection == nil })
    }

    func testDuplicateAssignmentsCannotLoseOrDuplicatePagesOnApplyOrUndo() {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        let first = TemporaryTabSection(title: "First", symbol: "book")
        browser.applyTidyTabs([.init(section: first, tabIDs: [ids[5], ids[2], ids[5], UUID()]),
                               .init(section: .init(title: "Second", symbol: "clock"), tabIDs: ids)], eligible: Set(ids))
        assertPages(browser, ids)
        XCTAssertEqual(browser.tab(withID: ids[5])?.temporarySection, first)
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs.map(\.id), ids)
        assertPages(browser, ids)
    }

    func testInferenceRevalidatesNavigationMembershipAndManualEditsAndKeepsNewTabs() async throws {
        let browser = model()
        let ids = browser.tabs.map(\.id)
        var response: CheckedContinuation<[TidyTabAssignment], any Error>?
        browser.tidyTemporaryTabs { _ in
            try await withCheckedThrowingContinuation { response = $0 }
        }
        try await waitUntil { response != nil }
        XCTAssertFalse(browser.canUndoTidyTabs)
        browser.moveToFolder(try XCTUnwrap(browser.tab(withID: ids[0])), parentID: nil)
        browser.pin(try XCTUnwrap(browser.tab(withID: ids[1])))
        browser.tab(withID: ids[2])?.invalidateNavigation()
        let manual = TemporaryTabSection(title: "Manual", symbol: "book", isExpanded: false)
        browser.tab(withID: ids[3])?.temporarySection = manual
        // Membership changes must remain invalid even after moving back.
        let roundTrip = try XCTUnwrap(browser.tab(withID: ids[4]))
        browser.moveToFolder(roundTrip, parentID: nil)
        browser.moveFolderPageToTemporaryTabs(try XCTUnwrap(browser.folders.item(roundTrip.folderPageID)))
        XCTAssertTrue(browser.moveTab(ids[5], to: 0))
        browser.closeTab(ids[6])
        browser.addTab(focusAddress: false)
        let added = try XCTUnwrap(browser.activeTabID)
        let unchanged = Set(ids.prefix(6) + [added])
        let slots = browser.tabs.enumerated().filter { unchanged.contains($0.element.id) }
        let folders = browser.folders.items
        let pins = browser.pinnedPages.items
        response?.resume(returning: [.init(section: .init(title: "Late", symbol: "book"), tabIDs: Array(ids.reversed()))])
        try await waitUntil { !browser.isTidyingTabs }

        for (index, tab) in slots { XCTAssertEqual(browser.tabs[index].id, tab.id) }
        XCTAssertNil(browser.tab(withID: ids[2])?.temporarySection)
        XCTAssertEqual(browser.tab(withID: ids[3])?.temporarySection, manual)
        XCTAssertNil(roundTrip.temporarySection)
        XCTAssertNil(browser.tab(withID: ids[5])?.temporarySection)
        XCTAssertNotNil(browser.tab(withID: ids[7])?.temporarySection)
        browser.undoTidyTabs()
        XCTAssertEqual(browser.folders.items, folders)
        XCTAssertEqual(browser.pinnedPages.items, pins)
        XCTAssertEqual(browser.tab(withID: ids[3])?.temporarySection, manual)
        assertPages(browser, ids.filter { $0 != ids[6] } + [added])
    }

    func testFailureAndCancellationKeepPreviousGroupingAndUndo() async throws {
        let browser = model()
        let original = browser.tabs.map(\.id)
        group(browser)
        let grouped = BrowserSessionSnapshot(browser: browser)
        browser.tidyTemporaryTabs { _ in throw CocoaError(.fileReadUnknown) }
        try await waitUntil { !browser.isTidyingTabs }
        XCTAssertNotNil(browser.intelligenceError)
        XCTAssertEqual(BrowserSessionSnapshot(browser: browser), grouped)
        XCTAssertTrue(browser.canUndoTidyTabs)

        var response: CheckedContinuation<[TidyTabAssignment], any Error>?
        browser.tidyTemporaryTabs { _ in
            try await withCheckedThrowingContinuation { response = $0 }
        }
        try await waitUntil { response != nil }
        browser.cancelTidyingTabs()
        response?.resume(returning: [.init(section: .init(title: "Too Late", symbol: "book"), tabIDs: original)])
        try await waitUntil { !browser.isTidyingTabs }
        XCTAssertEqual(BrowserSessionSnapshot(browser: browser), grouped)
        XCTAssertNil(browser.intelligenceError)
        XCTAssertTrue(browser.canUndoTidyTabs)
        browser.undoTidyTabs()
        XCTAssertEqual(browser.tabs.map(\.id), original)
    }

    func testPrivateModeAndUnavailableUndoAreNoOps() {
        let browser = model(isPrivate: true)
        let before = BrowserSessionSnapshot(browser: browser)
        var requested = false
        browser.tidyTemporaryTabs { _ in requested = true; return [] }
        group(browser)
        browser.undoTidyTabs()
        XCTAssertFalse(requested)
        XCTAssertFalse(browser.canTidyTabs)
        XCTAssertFalse(browser.canUndoTidyTabs)
        XCTAssertEqual(BrowserSessionSnapshot(browser: browser), before)
    }
}
