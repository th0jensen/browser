import XCTest
import AppKit
import SwiftUI
import WebKit
@testable import Browser

@MainActor
final class BrowserIntelligenceTests: XCTestCase {
    func testTidyPromptContainsEverySubjectAndExistingTopics() throws {
        let tabs = ["Rust Ownership", "Rust Lifetimes", "Battle of Britain"].map {
            TidyTabInput(id: UUID(), title: $0, url: URL(string: "https://example.com/book")!)
        }
        let json = LocalIntelligence.tidyPrompt(tabs, topics: ["Rust Learning"])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(object["tabs"] as? [[String: String]])
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map { $0["title"]! }, ["Rust Ownership", "Rust Lifetimes", "Battle of Britain"])
        XCTAssertEqual(records.map { $0["id"]! }, ["0", "1", "2"])
        XCTAssertEqual(object["existingTopics"] as? [String], ["Rust Learning"])
    }
    private func model(count: Int = 8, folders: TabFolderStore? = nil, pins: PinnedPageStore? = nil) -> BrowserModel {
        let browser = BrowserModel(pinnedPages: pins, folders: folders)
        browser.restoreSession(.init(tabs: (0..<count).map {
            .init(url: URL(string: "https://example.com/topic/\($0)"), title: "Page \($0)")
        } + [.init(url: nil, title: "")], selectedIndex: count))
        return browser
    }

    func testTidyCannotLoseDuplicateOrSaveTemporaryTabsAndRemovingGroupsPreservesTabs() throws {
        let browser = model()
        let original = browser.tabs.map(\.id)
        let first = TemporaryTabSection(title: "Rust learning", symbol: "curlybraces")
        let second = TemporaryTabSection(title: "WW2 study", symbol: "book")
        browser.applyTidyTabs([
            .init(section: first, tabIDs: [original[3], original[1], original[3], UUID()]),
            .init(section: second, tabIDs: [original[1], original[4], original[2]])
        ], eligible: Set(original))
        XCTAssertEqual(browser.tabs.prefix(4).map(\.id), [original[3], original[1], original[4], original[2]])
        XCTAssertEqual(Set(browser.tabs.map(\.id)), Set(original))
        XCTAssertEqual(browser.tabs.count, original.count)
        XCTAssertEqual(browser.tab(withID: original[1])?.temporarySection, first)
        XCTAssertTrue(browser.folders.items.isEmpty)
        XCTAssertTrue(browser.pinnedPages.items.isEmpty)
        browser.addTab(focusAddress: false)
        let added = browser.activeTabID
        let currentOrder = browser.tabs.map(\.id)
        browser.removeTemporarySections()
        XCTAssertEqual(browser.tabs.map(\.id), currentOrder)
        XCTAssertEqual(browser.tabs.last?.id, added)
        XCTAssertTrue(browser.regularTabs.allSatisfy { $0.temporarySection == nil })
    }

    func testTidyOnlyTouchesEligibleTemporaryTabs() throws {
        let folders = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let saved = try folders.savePage(url: URL(string: "https://saved.example.com")!, title: "Saved", in: nil)
        let pins = PinnedPageStore(directory: .temporaryDirectory, enabled: false)
        let pin = try pins.pin(url: URL(string: "https://pin.example.com")!, title: "Pin")
        let browser = model(folders: folders, pins: pins)
        browser.openFolderPage(saved)
        browser.openPinned(pin)
        let savedTab = try XCTUnwrap(browser.tabs.first { $0.folderPageID == saved.id })
        let pinTab = try XCTUnwrap(browser.tabs.first { $0.pinnedPageID == pin.id })
        let original = browser.tabs.map(\.id)
        let section = TemporaryTabSection(title: "Study", symbol: "book")
        browser.applyTidyTabs([.init(section: section, tabIDs: original)], eligible: [original[0]])
        XCTAssertEqual(browser.tabs.map(\.id), original)
        XCTAssertEqual(browser.tabs[0].temporarySection, section)
        XCTAssertNil(browser.tabs[1].temporarySection)
        XCTAssertNil(savedTab.temporarySection)
        XCTAssertNil(pinTab.temporarySection)
        XCTAssertEqual(folders.item(saved.id)?.title, "Saved")
    }

    func testSectionsSurviveSessionRestorationWithoutLoadingBackgroundPages() throws {
        let browser = model()
        let section = TemporaryTabSection(title: "Rust learning", symbol: "curlybraces")
        browser.applyTidyTabs([.init(section: section, tabIDs: Array(browser.regularTabs.prefix(3)).map(\.id))], eligible: Set(browser.regularTabs.map(\.id)))
        let snapshot = BrowserSessionSnapshot(browser: browser)
        let decoded = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = BrowserModel()
        restored.restoreSession(decoded)
        XCTAssertEqual(restored.tabs.prefix(3).map(\.temporarySection), [section, section, section])
        XCTAssertTrue(restored.tabs.dropLast().allSatisfy(\.isSuspended))
        XCTAssertEqual(snapshot, BrowserSessionSnapshot(browser: restored))
    }

    func testOldSessionsAndFoldersDecodeWithoutIntelligenceFields() throws {
        let data = Data(#"{"tabs":[{"url":"https://example.com","title":"Example"}],"selectedIndex":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: data)
        XCTAssertNil(snapshot.tabs[0].temporarySection)
        let item = Data("{\"id\":\"\(UUID())\",\"kind\":\"page\",\"title\":\"Example\",\"url\":\"https://example.com\",\"symbol\":\"folder\",\"emoji\":\"\",\"color\":\"primary\",\"isExpanded\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(TabFolderItem.self, from: item).nameSource)
    }

    func testManualSavedNamePersistsWithoutLiveTabAndSurvivesPageTitleUpdates() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folders = TabFolderStore(directory: directory)
        let page = try folders.savePage(url: URL(string: "https://example.com")!, title: "Long original title", in: nil)
        let browser = BrowserModel(folders: folders)
        try browser.renameSavedPage(page.id, to: "  Rust Ownership  ")
        try folders.updatePageTitle(page.id, title: "New title from website")
        XCTAssertEqual(folders.item(page.id)?.title, "Rust Ownership")
        XCTAssertEqual(folders.item(page.id)?.nameSource, .manual)
        let reopened = TabFolderStore(directory: directory)
        XCTAssertEqual(reopened.item(page.id), folders.item(page.id))
        browser.openFolderPage(try XCTUnwrap(reopened.item(page.id)))
        XCTAssertEqual(browser.activeTab?.title, "Rust Ownership")
        try folders.resetPageName(page.id)
        XCTAssertEqual(browser.activeTab?.title, "New title from website")
        XCTAssertEqual(folders.item(page.id)?.nameSource, .original)
        try folders.updatePageTitle(page.id, title: "Latest website title")
        XCTAssertEqual(browser.activeTab?.title, "Latest website title")
        XCTAssertThrowsError(try browser.renameSavedPage(page.id, to: "\n\t"))
    }

    func testReorderingFeedbackOnlyFiresForActualMovesAndSectionsFollowDestination() throws {
        let browser = model(count: 3)
        let original = browser.tabs.map(\.id)
        let section = TemporaryTabSection(title: "Learning", symbol: "book")
        browser.tabs[1].temporarySection = section
        var feedback = 0
        browser.reorderFeedback = { feedback += 1 }
        XCTAssertFalse(browser.moveTab(original[0], to: 0, haptic: true))
        XCTAssertFalse(browser.moveTab(UUID(), to: 1, haptic: true))
        XCTAssertFalse(browser.moveTab(original[0], to: 999, haptic: true))
        XCTAssertEqual(feedback, 0)
        XCTAssertTrue(browser.moveTab(original[0], to: 1, haptic: true))
        XCTAssertEqual(feedback, 1)
        XCTAssertEqual(browser.tab(withID: original[0])?.temporarySection, section)
        XCTAssertTrue(browser.moveTab(original[0], to: 2))
        XCTAssertEqual(feedback, 1, "Programmatic reordering should not vibrate")
    }

    func testDownloadNamesPreserveExtensionsAndCannotEscapeDirectory() {
        XCTAssertEqual(DownloadManager.tidyFilename(stem: "Annual Report.pdf", original: "d38.pdf"), "Annual Report.pdf")
        XCTAssertEqual(DownloadManager.tidyFilename(stem: "Rust Source", original: "rust-1.90.tar.gz"), "Rust Source.tar.gz")
        XCTAssertEqual(DownloadManager.tidyFilename(stem: "../../Secret:/\\file", original: "file.PDF"), "Secret file.PDF")
        XCTAssertEqual(DownloadManager.tidyFilename(stem: "..\n", original: "original.zip"), "original.zip")
        XCTAssertFalse(DownloadManager.tidyFilename(stem: ".hidden", original: "file").hasPrefix("."))
    }

    func testPreviewRejectsNonWebAndLocalLinksAndRemovesExecutableMarkup() {
        for url in ["file:///etc/passwd", "javascript:alert(1)", "http://localhost", "http://127.0.0.1/a", "http://192.168.1.1", "http://[::1]", "https://user:pass@example.com"] {
            XCTAssertFalse(LinkPreviewFetcher.isPublicWebURL(URL(string: url)!), url)
        }
        XCTAssertTrue(LinkPreviewFetcher.isPublicWebURL(URL(string: "https://doc.rust-lang.org/book/")!))
        XCTAssertEqual(LinkPreviewFetcher.readableText("<script>bad()</script><nav>Home</nav><h1>Rust &amp; Ownership</h1><p>Safe memory.</p><style>css</style>"), "Rust & Ownership Safe memory.")
    }

    func testPromptHintsExcludeCredentialsAndQuerySecrets() throws {
        let url = URL(string: "https://user:password@example.com/book?token=secret#private")!
        XCTAssertEqual(LocalIntelligence.pageHint(url), "example.com/book")
        XCTAssertEqual(LocalIntelligence.withoutNotificationCount("(24) Rust Book"), "Rust Book")
        XCTAssertEqual(LocalIntelligence.topicTitle("create window in jai - Google Search"), "create window in jai")
        XCTAssertEqual(LocalIntelligence.topicPageHint(URL(string: "https://www.google.com/search?q=jai")!), "")
        XCTAssertEqual(try LocalIntelligence.cleanName("\" Rust\n Ownership \"", limit: 72), "Rust Ownership")
    }
}

extension BrowserIntelligenceTests {
    func testSavedTabReorderingRatchetsOnEachActualCrossing() throws {
        let folders = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let pages = try (0..<3).map { try folders.savePage(url: URL(string: "https://example.com/\($0)")!, title: "Page \($0)", in: nil) }
        let browser = BrowserModel(folders: folders)
        var ticks = 0
        browser.reorderFeedback = { ticks += 1 }
        XCTAssertTrue(browser.reorderSavedPage(pages[0].id, past: pages[1].id))
        XCTAssertEqual(folders.pages.map(\.id), [pages[1].id, pages[0].id, pages[2].id])
        XCTAssertTrue(browser.reorderSavedPage(pages[0].id, past: pages[2].id))
        XCTAssertEqual(folders.pages.map(\.id), [pages[1].id, pages[2].id, pages[0].id])
        XCTAssertFalse(browser.reorderSavedPage(pages[0].id, past: pages[0].id))
        XCTAssertEqual(ticks, 2)
    }

    func testRealDownloadTidyAndUndoNeverOverwriteFilesAndKeepQuarantine() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appending(path: "Rust Notes.txt")
        try "existing".write(to: existing, atomically: true, encoding: .utf8)
        let downloads = DownloadManager(directory: directory, shouldTidyDownloads: { true }, suggestName: { _, title, _ in
            XCTAssertEqual(title, "Ownership Tutorial")
            return "Rust Notes"
        })
        let browser = BrowserModel(downloads: downloads)
        let tab = try XCTUnwrap(browser.activeTab)
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString("<title>Ownership Tutorial</title><a id='file' download='a848.txt' href='data:text/plain,hello'>Download</a>", baseURL: URL(string: "https://example.com"))
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Ownership Tutorial" }
        _ = try await view.evaluateJavaScript("document.getElementById('file').click(); 0")
        try await waitUntil { downloads.items.first?.originalName != nil }
        let item = try XCTUnwrap(downloads.items.first)
        XCTAssertEqual(item.name, "Rust Notes 2.txt")
        XCTAssertEqual(item.originalName, "a848.txt")
        let renamed = try XCTUnwrap(item.destinationURL)
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "hello")
        XCTAssertNotNil(try renamed.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        try "another".write(to: directory.appending(path: "a848.txt"), atomically: true, encoding: .utf8)
        downloads.undoTidyName(item)
        XCTAssertNil(item.originalName)
        XCTAssertEqual(item.name, "a848 2.txt")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "a848.txt"), encoding: .utf8), "another")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(item.destinationURL), encoding: .utf8), "hello")
    }
}


extension BrowserIntelligenceTests {
    func testNativePreviewMessageShowsSummaryAndNavigationDismissesIt() async throws {
        guard BrowserIntelligence.unavailableReason == nil else { throw XCTSkip("On-device model unavailable on this runner") }
        let controller = LinkPreviewController(observesSettings: false, summaryProvider: { _ in
            LinkSummary(title: "Rust Ownership", summary: "Each value has one owner. Borrowing permits references without taking ownership.")
        })
        controller.setEnabled(true)
        let browser = BrowserModel()
        let tab = try XCTUnwrap(browser.activeTab)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        controller.install(in: view, tab: tab)
        let window = PreviewFixtureWindow(contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Link Preview QA"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { controller.dismiss(for: view); window.close() }
        view.loadHTMLString("<title>Preview fixture</title><p>Hover a link to preview it.</p>", baseURL: URL(string: "https://example.com"))
        try await waitUntil { !view.isLoading && view.title == "Preview fixture" }
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(view.window?.isKeyWindow == true)
        XCTAssertFalse(view.isHiddenOrHasHiddenAncestor)
        let script = "window.webkit.messageHandlers.browserLinkPreview.postMessage({url:'https://doc.rust-lang.org/book/',x:30,y:40,width:120,height:20});0"
        let scriptError: String? = await withCheckedContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: .world(name: "BrowserLinkPreviews")) { result in
                switch result {
                case .success: continuation.resume(returning: nil)
                case .failure(let error): continuation.resume(returning: error.localizedDescription)
                }
            }
        }
        XCTAssertNil(scriptError)
        try await waitUntil { controller.presentedPreview?.result != nil }
        XCTAssertEqual(controller.presentedPreview?.result?.title, "Rust Ownership")
        controller.dismiss(for: view)
        XCTAssertNil(controller.presentedPreview)
        // Disabled previews ignore even a well-formed message in their isolated world.
        controller.setEnabled(false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.evaluateJavaScript(script, in: nil, in: .world(name: "BrowserLinkPreviews")) { _ in continuation.resume() }
        }
        XCTAssertNil(controller.presentedPreview)
    }
}

// The test runner does not activate its host app. Model an eligible source window
// without taking focus away from the user's running Release browser.
@MainActor private final class PreviewFixtureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

extension BrowserIntelligenceTests {
    func testGroupsCollapseTogetherPersistAndRevealKeyboardSelection() throws {
        let browser = model()
        let ids = browser.regularTabs.map(\.id)
        let section = TemporaryTabSection(title: "rust-learning", symbol: "book")
        browser.applyTidyTabs([.init(section: section, tabIDs: Array(ids.prefix(3)))], eligible: Set(ids))
        browser.setTemporarySectionExpanded(section.id, expanded: false)
        XCTAssertEqual(browser.temporaryTabGroups.first?.tabs.count, 3)
        XCTAssertEqual(browser.temporaryTabGroups.first?.section?.title, "Rust Learning")
        XCTAssertTrue(browser.tabs.prefix(3).allSatisfy { $0.temporarySection?.isExpanded == false })
        let snapshot = BrowserSessionSnapshot(browser: browser)
        let restored = BrowserModel()
        restored.restoreSession(try JSONDecoder().decode(BrowserSessionSnapshot.self, from: JSONEncoder().encode(snapshot)))
        XCTAssertEqual(restored.temporaryTabGroups.first?.section?.isExpanded, false)
        restored.activeTabID = restored.tabs[1].id
        XCTAssertTrue(restored.tabs.prefix(3).allSatisfy { $0.temporarySection?.isExpanded == true })
        XCTAssertEqual(restored.tabs.count, snapshot.tabs.count)
    }

    func testDroppingIntoGroupKeepsGroupOrderAndRemovingGroupKeepsEveryTab() {
        let browser = model(count: 4)
        let ids = browser.tabs.map(\.id)
        let first = TemporaryTabSection(title: "rust", symbol: "book")
        let second = TemporaryTabSection(title: "ww2-study", symbol: "clock", isExpanded: false)
        browser.applyTidyTabs([.init(section: first, tabIDs: [ids[0], ids[1]]),
                               .init(section: second, tabIDs: [ids[2], ids[3]])], eligible: Set(ids))
        XCTAssertTrue(browser.moveTemporaryTab(ids[0], toSection: second.id))
        XCTAssertEqual(browser.temporaryTabGroups.prefix(2).map(\.id), [first.id, second.id])
        XCTAssertEqual(browser.temporaryTabGroups[1].tabs.map(\.id), [ids[2], ids[3], ids[0]])
        XCTAssertFalse(browser.moveTemporaryTab(ids[0], toSection: second.id))
        XCTAssertFalse(browser.moveTemporaryTab(UUID(), toSection: second.id))
        browser.removeTemporarySection(second.id)
        XCTAssertEqual(Set(browser.tabs.map(\.id)), Set(ids))
        XCTAssertTrue(browser.regularTabs.filter { [ids[0], ids[2], ids[3]].contains($0.id) }.allSatisfy { $0.temporarySection == nil })
    }

    func testGroupTitleMigrationAndFormattingPreserveAcronymsAndBrandCase() throws {
        let old = Data("{\"id\":\"\(UUID())\",\"title\":\"jai programming\",\"symbol\":\"curlybraces\"}".utf8)
        let section = try JSONDecoder().decode(TemporaryTabSection.self, from: old)
        XCTAssertTrue(section.isExpanded)
        XCTAssertEqual(section.title, "Jai Programming")
        XCTAssertEqual(LocalIntelligence.displayTitle("ww2_study"), "WW2 Study")
        XCTAssertEqual(LocalIntelligence.displayTitle("WW2-study"), "WW2 Study")
        XCTAssertEqual(LocalIntelligence.displayTitle("ios and macOS development"), "iOS And macOS Development")
        XCTAssertEqual(LocalIntelligence.displayTitle("AI research and API design"), "AI Research And API Design")
    }

    func testInlineNameEditorHandlesReturnEscapeAndFocusLossExactlyOnce() {
        var committed: [String] = [], cancellations = 0
        let field = InlineTabNameField.NameField(string: "Friendly Title")
        let editor = NSTextView()
        editor.string = "Friendly Title"
        let enter = InlineTabNameField.Coordinator(commit: { committed.append($0) }, cancel: { cancellations += 1 })
        XCTAssertTrue(enter.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        enter.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(committed, ["Friendly Title"])
        let escape = InlineTabNameField.Coordinator(commit: { committed.append($0) }, cancel: { cancellations += 1 })
        XCTAssertTrue(escape.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        escape.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(committed.count, 1)
        let blur = InlineTabNameField.Coordinator(commit: { committed.append($0) }, cancel: {})
        blur.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(committed.count, 2)
    }
}


extension BrowserIntelligenceTests {
    func testSavedTabTitleEditsInItsRowAndSavesTheActualFieldEditorText() async throws {
        let folders = TabFolderStore(directory: .temporaryDirectory, enabled: false)
        let page = try folders.savePage(url: URL(string: "https://example.com")!, title: "Original Page", in: nil)
        let browser = BrowserModel(folders: folders)
        let host = NSHostingView(rootView: SavedTabTitle(browser: browser, page: page, isActive: false).frame(width: 200, height: 32))
        let window = PreviewFixtureWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        func field(in view: NSView) -> InlineTabNameField.NameField? {
            if let field = view as? InlineTabNameField.NameField { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        browser.renamingSavedPageID = page.id
        try await waitUntil { field(in: host)?.currentEditor() != nil }
        let input = try XCTUnwrap(field(in: host))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: "Original Page".utf16.count))
        XCTAssertGreaterThan(input.frame.width, 120)
        editor.string = "My Friendly Title"
        let delegate = try XCTUnwrap(input.delegate as? InlineTabNameField.Coordinator)
        XCTAssertTrue(delegate.control(input, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitUntil { field(in: host) == nil }
        XCTAssertNil(browser.renamingSavedPageID)
        XCTAssertEqual(folders.item(page.id)?.title, "My Friendly Title")
        XCTAssertEqual(folders.item(page.id)?.nameSource, .manual)
    }
}

extension BrowserIntelligenceTests {
    func testLiveSidebarDragUsesCorrectRowAndLocksHorizontalMovement() {
        let drag = TabReorderController()
        let a = CGRect(x: 8, y: 8, width: 200, height: 32)
        let b = a.offsetBy(dx: 0, dy: 36)
        let c = b.offsetBy(dx: 0, dy: 36)
        drag.register("a", frame: a, axis: .vertical)
        drag.register("b", frame: b, axis: .vertical)
        drag.register("c", frame: c, axis: .vertical)
        var crossings: [String] = []
        var completed = 0
        XCTAssertTrue(drag.begin("b", frame: b, axis: .vertical, crossing: { id, direction in
            crossings.append("\(id):\(direction)")
        }, completion: { _ in completed += 1 }))
        drag.update(translation: CGSize(width: 900, height: 38))
        XCTAssertEqual(drag.payload, "b")
        XCTAssertEqual(drag.offset(for: "b", frame: b), CGSize(width: 0, height: 36))
        XCTAssertEqual(drag.offset(for: "a", frame: a), .zero, "A neighboring row never becomes the dragged element")
        XCTAssertEqual(crossings, ["c:1"])
        // Layout moves the source into its new slot; it stays at the same pointer position.
        drag.register("b", frame: c, axis: .vertical)
        drag.register("c", frame: b, axis: .vertical)
        XCTAssertEqual(drag.offset(for: "b", frame: c), .zero)
        drag.endGesture()
        drag.endGesture()
        XCTAssertEqual(completed, 1)
        XCTAssertNil(drag.payload)
    }

    func testEscapeCannotRestartTheSameDragBeforeMouseUp() {
        let drag = TabReorderController()
        let frame = CGRect(x: 8, y: 8, width: 200, height: 32)
        drag.register("a", frame: frame, axis: .vertical)
        var completed = 0
        drag.begin("a", frame: frame, axis: .vertical, crossing: { _, _ in }, completion: { target in
            XCTAssertNil(target); completed += 1
        })
        drag.finish(cancelled: true)
        XCTAssertNil(drag.payload)
        XCTAssertFalse(drag.begin("a", frame: frame, axis: .vertical, crossing: { _, _ in }, completion: { _ in XCTFail() }))
        drag.endGesture()
        XCTAssertEqual(completed, 1)
        XCTAssertTrue(drag.begin("a", frame: frame, axis: .vertical, crossing: { _, _ in }, completion: { _ in }))
        drag.endGesture()
    }

    func testLiveReorderRejectsStaleCrossingsAndTransfersGroupsOnlyOnDrop() {
        let browser = model(count: 3)
        let ids = browser.tabs.map(\.id)
        var ticks = 0
        browser.reorderFeedback = { ticks += 1 }
        browser.crossDraggedTab(ids[0].uuidString, past: ids[1].uuidString, direction: 1)
        XCTAssertEqual(Array(browser.tabs.prefix(2)).map(\.id), [ids[1], ids[0]])
        browser.crossDraggedTab(ids[0].uuidString, past: ids[1].uuidString, direction: 1)
        XCTAssertEqual(ticks, 1, "Stale layout frames cannot swap the source back")
        let section = TemporaryTabSection(title: "Rust Learning", symbol: "book")
        browser.tab(withID: ids[2])?.temporarySection = section
        browser.crossDraggedTab(ids[0].uuidString, past: ids[2].uuidString, direction: 1)
        XCTAssertNil(browser.tab(withID: ids[0])?.temporarySection, "Keep the gesture's row in its original hierarchy until mouse-up")
        browser.finishDraggedTab(ids[0].uuidString, over: "browser-section:\(section.id.uuidString)")
        XCTAssertEqual(browser.tab(withID: ids[0])?.temporarySection, section)
        XCTAssertEqual(ticks, 2)
    }
}

extension BrowserIntelligenceTests {
    func testHorizontalDragLocksVerticalMovementAndIgnoresSidebarTargets() {
        let drag = TabReorderController()
        let a = CGRect(x: 0, y: 0, width: 100, height: 32)
        let b = a.offsetBy(dx: 104, dy: 0)
        drag.register("a", frame: a, axis: .horizontal)
        drag.register("b", frame: b, axis: .horizontal)
        drag.register("sidebar", frame: a.offsetBy(dx: 50, dy: 0), axis: .vertical)
        var crossed: [String] = []
        drag.begin("a", frame: a, axis: .horizontal, crossing: { id, _ in crossed.append(id) }, completion: { _ in })
        drag.update(translation: CGSize(width: 80, height: 700))
        XCTAssertEqual(drag.offset(for: "a", frame: a), CGSize(width: 80, height: 0))
        XCTAssertTrue(crossed.isEmpty)
        drag.update(translation: CGSize(width: 110, height: -700))
        XCTAssertEqual(drag.offset(for: "a", frame: a), CGSize(width: 104, height: 0))
        XCTAssertEqual(crossed, ["b"])
        drag.endGesture()
    }
}
