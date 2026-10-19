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
        tab.restore()
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
    func testPreviewHoverBridgeAndTextDragHitTargets() async throws {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = PreviewFixtureWindow(contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        let anchor = window.convertToScreen(NSRect(x: 100, y: 460, width: 250, height: 20))
        var dragFocusRequests: [LinkPreviewPanel] = []
        let preview = LinkPreviewPresentation(url: URL(string: "https://example.com/hover")!, sourceView: view,
            anchor: anchor, open: {}, didKeep: { _ in }, didClose: { _ in },
            focusNote: { dragFocusRequests.append($0) })
        preview.state.result = LinkSummary(title: "Hover", summary: "Useful preview content.")
        defer { preview.close(); window.close() }
        preview.show()
        try await waitUntil { preview.state.contentHeight != 150 }
        let glass = try XCTUnwrap(preview.glass)
        let host = try XCTUnwrap(preview.content)
        XCTAssertTrue(glass.window === window, "Hover glass samples the webpage in the same window")
        XCTAssertNil(preview.panel)
        XCTAssertTrue(glass.contentView === host)
        XCTAssertEqual(glass.style, .regular)
        XCTAssertEqual(anchor.minY - preview.frame.maxY, 24, accuracy: 0.5)
        XCTAssertTrue(preview.containsHoverPoint(NSPoint(x: anchor.midX, y: anchor.minY - 8)))
        XCTAssertTrue(preview.containsHoverPoint(NSPoint(x: anchor.midX, y: (anchor.minY + preview.frame.maxY) / 2)))
        XCTAssertFalse(preview.containsHoverPoint(NSPoint(x: anchor.maxX + 150, y: anchor.minY - 100)))
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let drag = PreviewDragView(preview: preview)
        drag.frame = NSRect(x: 10, y: 10, width: 300, height: 250)
        drag.excludingFooter = true
        parent.addSubview(drag)
        XCTAssertTrue(drag.hitTest(NSPoint(x: 100, y: 150)) === drag, "Summary text remains a drag target")
        XCTAssertTrue(drag.hitTest(NSPoint(x: 15, y: 15)) === drag, "Empty padding remains a drag target")
        XCTAssertNil(drag.hitTest(NSPoint(x: 290, y: 25)), "Open Page remains clickable")
        let frame = preview.frame
        let sourceFrame = window.frame
        let tint = glass.tintColor
        preview.beginDrag()
        let panel = try XCTUnwrap(preview.panel)
        XCTAssertEqual(dragFocusRequests.count, 1, "The note is focused before the first drag event is tracked")
        XCTAssertTrue(dragFocusRequests.first === panel)
        XCTAssertTrue(glass.window === panel)
        XCTAssertTrue(glass.contentView === host, "Detaching keeps the same contextual content host")
        let surface = try XCTUnwrap(panel.contentView)
        XCTAssertFalse(surface === glass, "The panel's rounded alpha shape is independent of glass rendering")
        XCTAssertTrue(glass.superview === surface)
        XCTAssertEqual(surface.layer?.cornerRadius, glass.cornerRadius)
        XCTAssertEqual(surface.layer?.masksToBounds, true)
        XCTAssertEqual(surface.focusRingType, .none)
        XCTAssertEqual(glass.focusRingType, .none)
        preview.resize(height: 480)
        XCTAssertEqual(panel.frame, frame, "Card does not jump while dragging")
        preview.moveDuringDrag(to: NSPoint(x: frame.minX + 35, y: frame.minY - 20))
        XCTAssertEqual(glass.tintColor, tint)
        XCTAssertEqual(glass.style, .regular)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: frame.minX + 35, y: frame.minY - 20))
        XCTAssertEqual(window.frame, sourceFrame, "Tearing off a card must never move the browser window")
        preview.endDrag()
        XCTAssertTrue(preview.state.isKept)
        XCTAssertEqual(glass.frame, surface.bounds)
        XCTAssertEqual(glass.tintColor, tint)
        preview.beginDrag()
        XCTAssertEqual(dragFocusRequests.count, 2, "An existing note also gains focus before tracking")
        preview.endDrag()
        XCTAssertEqual(dragFocusRequests.count, 2, "Dropping does not change focus or styling")

        let menu = preview.actions.actionsMenu()
        XCTAssertFalse(menu.allowsContextMenuPlugIns)
        XCTAssertFalse(menu.automaticallyInsertsWritingToolsItems)
        XCTAssertEqual(Array(menu.items.filter { !$0.isSeparatorItem }.map(\.title).prefix(3)), ["Open Page", "Copy Text", "Copy Link"])
        preview.close()
        XCTAssertNil(glass.superview)
    }

    func testTooSmallPreviewSourceDoesNotPresentAnAlreadyClosedPanel() throws {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let window = PreviewFixtureWindow(contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var closes = 0
        let preview = LinkPreviewPresentation(url: URL(string: "https://example.com/tiny")!, sourceView: view,
            anchor: window.convertToScreen(NSRect(x: 10, y: 10, width: 40, height: 20)), open: {}, didKeep: { _ in }, didClose: { _ in closes += 1 })
        preview.state.result = LinkSummary(title: "Tiny", summary: "Useful preview content.")
        preview.show()
        XCTAssertTrue(preview.isClosed)
        XCTAssertNil(preview.panel)
        XCTAssertEqual(closes, 1)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testDraggedPreviewBecomesIndependentNoteAndFinishesWhileAnotherPreviewLoads() async throws {
        let controller = LinkPreviewController(observesSettings: false, modifierFlags: { .shift }, summaryProvider: { url in
            if url.path == "/first" { try await Task.sleep(for: .milliseconds(200)) }
            return LinkSummary(title: url.lastPathComponent, summary: "A useful summary of \(url.lastPathComponent).", keyPoints: ["A specific fact."])
        })
        controller.setEnabled(true)
        let tab = BrowserTab()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        controller.install(in: view, tab: tab)
        let window = PreviewFixtureWindow(contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { controller.setEnabled(false); window.close() }
        view.loadHTMLString("<title>Notes fixture</title><p>Notes</p>", baseURL: URL(string: "https://example.com"))
        try await waitUntil { !view.isLoading && view.title != nil }
        func show(_ path: String) async {
            let script = "window.webkit.messageHandlers.browserLinkPreview.postMessage({url:'https://example.com/\(path)',x:20,y:40,width:120,height:20});0"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                view.evaluateJavaScript(script, in: nil, in: .world(name: "BrowserLinkPreviews")) { _ in continuation.resume() }
            }
        }
        await show("first")
        try await waitUntil { controller.presentedPreview != nil }
        let state = try XCTUnwrap(controller.presentedPreview)
        let presentation = try XCTUnwrap(controller.current)
        XCTAssertNil(presentation.panel)
        XCTAssertTrue(presentation.glass?.window === window)
        controller.keepPreview() // The native drag handle calls this after its movement threshold.
        let notePanel = try XCTUnwrap(presentation.panel)
        XCTAssertTrue(state.isKept)
        XCTAssertNil(controller.presentedPreview)
        XCTAssertNil(notePanel.parent)
        XCTAssertTrue(notePanel.canBecomeKey)
        controller.dismiss(for: view)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(controller.keptNotes.map(\.id), [state.id])
        await show("second")
        try await waitUntil { controller.presentedPreview?.result?.title == "second" && state.result?.title == "first" }
        XCTAssertEqual(controller.keptNotes.first?.result?.title, "first")
        controller.keepPreview()
        XCTAssertEqual(controller.keptNotes.count, 2)
        controller.closeNote(id: state.id)
        XCTAssertEqual(controller.keptNotes.count, 1)
        XCTAssertFalse(notePanel.isVisible)
        controller.setEnabled(false)
        XCTAssertTrue(controller.keptNotes.isEmpty)
    }

    func testNoteCopyIncludesSummaryKeyPointsAndSource() throws {
        let first = LinkPreviewState(url: URL(string: "https://example.com/article?part=2")!)
        first.result = LinkSummary(title: "Oaxaca", summary: "A destination overview.", keyPoints: ["Visit Monte Alban.", "Explore the Zocalo."])
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        PreviewNoteActions.copyText(first, to: pasteboard)
        let text = try XCTUnwrap(pasteboard.string(forType: .string))
        for expected in ["Oaxaca", "A destination overview.", "• Visit Monte Alban.", "• Explore the Zocalo.", first.url.absoluteString] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        PreviewNoteActions.copyLink(first, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .URL), first.url.absoluteString)
        XCTAssertNil(pasteboard.string(forType: .string)?.range(of: "destination overview"))
    }

    func testOpenPreviewSelectsSourceRestoresWindowAndActivatesApplication() async throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        source.restore()
        browser.addTab(focusAddress: false)
        let window = PreviewActionWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = source.contentView
        browser.window = window
        defer { source.stopLoading(); window.close() }
        let destination = URL(string: "data:text/html,<title>PreviewDestination</title>")!
        var activations = 0
        var fallbacks: [URL] = []
        let pending = PreviewNoteActions.openPage(destination, from: source, activateApplication: {
            XCTAssertEqual(source.url, destination)
            activations += 1
        }, openElsewhere: { fallbacks.append($0) })
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(window.frontRequests, 1)
        await pending?.value
        XCTAssertEqual(source.url, destination)
        XCTAssertEqual(browser.activeTabID, source.id)
        XCTAssertEqual(window.restoreRequests, 1)
        XCTAssertEqual(window.frontRequests, 1)
        XCTAssertTrue(window.requestedResponder === source.webView)
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(fallbacks.isEmpty)
    }

    func testOpenPreviewPreservesLiveSourcePeek() async throws {
        let browser = BrowserModel()
        let opener = try XCTUnwrap(browser.activeTab)
        let source = browser.openPeek(from: opener)
        let window = PreviewActionWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = source.contentView
        browser.window = window
        defer { browser.dismissPeek(); window.close() }
        let destination = URL(string: "data:text/html,<title>PeekDestination</title>")!
        var activations = 0
        let pending = PreviewNoteActions.openPage(destination, from: source, activateApplication: {
            XCTAssertEqual(source.url, destination)
            activations += 1
        }, openElsewhere: { _ in XCTFail("A live peek remains a valid destination") })
        XCTAssertEqual(activations, 1)
        await pending?.value
        XCTAssertTrue(browser.peek?.tab === source)
        XCTAssertEqual(browser.activeTabID, opener.id)
        XCTAssertEqual(source.url, destination)
        XCTAssertTrue(window.requestedResponder === source.webView)
        XCTAssertEqual(activations, 1)
    }

    func testOpenPreviewRoutesElsewhereAfterSourceTabCloses() throws {
        let browser = BrowserModel()
        let source = try XCTUnwrap(browser.activeTab)
        browser.closeTab(source.id)
        let destination = URL(string: "https://example.com/preview")!
        var activations = 0
        var routed: [URL] = []
        PreviewNoteActions.openPage(destination, from: source, activateApplication: { activations += 1 },
                                    openElsewhere: { routed.append($0) })
        XCTAssertEqual(routed, [destination])
        XCTAssertEqual(activations, 1)
        XCTAssertNotEqual(browser.activeTabID, source.id)
    }

    func testOpenPreviewStartsNavigationAndActivatesBeforeDestinationFinishes() async throws {
        let handler = PreviewDelayedSchemeHandler()
        let configuration = BrowserTab.makeConfiguration(includingExtensions: false)
        configuration.setURLSchemeHandler(handler, forURLScheme: "preview-load")
        let browser = BrowserModel(configuration: configuration, isPrivate: true)
        let source = try XCTUnwrap(browser.activeTab)
        let window = PreviewActionWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                         styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = source.contentView
        browser.window = window
        defer { source.stopLoading(); window.close() }
        var activations = 0
        let destination = URL(string: "preview-load://fixture/destination")!
        let pending = PreviewNoteActions.openPage(destination, from: source,
            activateApplication: {
                XCTAssertEqual(source.url, destination)
                XCTAssertTrue(source.webView?.isLoading == true)
                activations += 1
            }, openElsewhere: { _ in XCTFail("The source is live") })
        try await waitUntil { handler.pending != nil }
        XCTAssertTrue(source.isLoading)
        await pending?.value
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(window.frontRequests, 1)
        XCTAssertEqual(window.restoreRequests, 1)
        XCTAssertTrue(window.requestedResponder === source.webView)
        handler.finish()
        try await waitUntil { !source.isLoading }
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(window.frontRequests, 1)
        XCTAssertEqual(window.restoreRequests, 1)
    }

    func testDeferredPreviewFocusRespectsLaterResponderAddressAndFindRequests() async throws {
        for change in ["none", "responder", "address", "find"] {
            let browser = BrowserModel()
            let source = try XCTUnwrap(browser.activeTab)
            let window = PreviewActionWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                             styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            browser.window = window
            defer { source.stopLoading(); window.close() }
            let originalResponder = NSResponder()
            let newResponder = NSResponder()
            _ = window.makeFirstResponder(originalResponder)
            let pending = PreviewNoteActions.openPage(URL(string: "data:text/html,<p>Focus</p>")!, from: source,
                activateApplication: {}, openElsewhere: { _ in XCTFail("The source is live") })
            XCTAssertNotNil(pending)
            let waitingResponder = window.firstResponder
            switch change {
            case "responder": _ = window.makeFirstResponder(newResponder)
            case "address": browser.requestAddressFocus()
            case "find": source.findText = "fixture"; browser.showFindBar()
            default: break
            }
            window.contentView = source.contentView
            await pending?.value
            let expected: NSResponder? = change == "none" ? source.webView : (change == "responder" ? newResponder : waitingResponder)
            XCTAssertTrue(window.requestedResponder === expected, change)
        }
    }

    func testPreviewDestinationAddressesExcludePrivateAndLocalNetworks() {
        for address in ["127.0.0.1", "10.20.0.1", "172.16.0.1", "172.31.255.255", "192.168.2.1", "169.254.1.2", "100.64.0.1", "0.0.0.0", "224.0.0.1", "::1", "fe80::1", "fc00::1", "::ffff:127.0.0.1", "2001:db8::1", "invalid"] {
            XCTAssertFalse(LinkPreviewFetcher.isPublicAddress(address), address)
        }
        for address in ["1.1.1.1", "8.8.8.8", "172.32.0.1", "2606:4700:4700::1111"] {
            XCTAssertTrue(LinkPreviewFetcher.isPublicAddress(address), address)
        }
    }

    func testPreviewImagesUsePublisherMetadataAndRejectLocalOrExecutableURLs() throws {
        let page = URL(string: "https://publisher.example.com/articles/travel")!
        XCTAssertEqual(LinkPreviewFetcher.previewImage(in: "<meta content='/images/oaxaca.jpg?a=1&amp;b=2' property='og:image'>", relativeTo: page)?.absoluteString,
                       "https://publisher.example.com/images/oaxaca.jpg?a=1&b=2")
        XCTAssertEqual(LinkPreviewFetcher.previewImage(in: "<META CONTENT=//cdn.example.com/hero.webp NAME=twitter:image>", relativeTo: page)?.absoluteString,
                       "https://cdn.example.com/hero.webp")
        XCTAssertEqual(LinkPreviewFetcher.previewImage(in: "<meta property='og:image' content='http://127.0.0.1/private'><meta name='twitter:image' content='https://cdn.example.com/fallback.png'>", relativeTo: page)?.path,
                       "/fallback.png")
        for image in ["javascript:alert(1)", "data:image/png;base64,abc", "file:///tmp/image.png", "http://localhost/x", "https://server.local/x", ""] {
            XCTAssertNil(LinkPreviewFetcher.previewImage(in: "<meta property='og:image' content='\(image)'>", relativeTo: page), image)
        }
        XCTAssertNil(LinkPreviewFetcher.previewImage(in: "<script>const image = 'https://example.com/hero.jpg'</script>", relativeTo: page))
    }

    func testLongPreviewFitsSmallPaneAndWindowDeactivationDismissesIt() async throws {
        let controller = LinkPreviewController(observesSettings: false, modifierFlags: { .shift }, summaryProvider: { _ in
            LinkSummary(title: "Travel", summary: "A guide to visiting Oaxaca and its surrounding towns.",
                        keyPoints: Array(repeating: String(repeating: "A detailed fact about the destination. ", count: 4), count: 3))
        })
        controller.setEnabled(true)
        let tab = BrowserTab()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 260, height: 270))
        controller.install(in: view, tab: tab)
        let window = PreviewFixtureWindow(contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { controller.dismiss(for: view); window.close() }
        view.loadHTMLString("<title>Small preview fixture</title><p>Travel links</p>", baseURL: URL(string: "https://example.com"))
        try await waitUntil { !view.isLoading && view.title != nil }
        let script = "window.webkit.messageHandlers.browserLinkPreview.postMessage({url:'https://example.com/travel',x:10,y:20,width:180,height:20});0"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.evaluateJavaScript(script, in: nil, in: .world(name: "BrowserLinkPreviews")) { _ in continuation.resume() }
        }
        try await waitUntil { controller.presentedPreview?.result != nil }
        try await waitUntil { (controller.presentedPreview?.contentHeight ?? 0) > 300 }
        let presentation = try XCTUnwrap(controller.current)
        let glass = try XCTUnwrap(presentation.glass)
        let bounds = window.convertToScreen(view.convert(view.bounds, to: nil))
        XCTAssertTrue(glass.window === window)
        XCTAssertTrue(bounds.contains(presentation.frame), "\(presentation.frame) outside \(bounds)")
        XCTAssertLessThan(presentation.frame.width, 260)
        XCTAssertLessThan(presentation.frame.height, try XCTUnwrap(controller.presentedPreview).contentHeight)
        XCTAssertEqual(controller.presentedPreview?.result?.keyPoints.count, 3)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertNil(controller.presentedPreview)
        XCTAssertNil(glass.superview)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
    }

    func testNativePreviewMessageShowsSummaryAndNavigationDismissesIt() async throws {
        var modifierFlags = NSEvent.ModifierFlags()
        let controller = LinkPreviewController(observesSettings: false, modifierFlags: { modifierFlags }, summaryProvider: { _ in
            LinkSummary(title: "Rust Ownership", summary: "Each value has one owner. Borrowing permits references without taking ownership.")
        })
        controller.setEnabled(true)
        let browser = BrowserModel()
        let tab = try XCTUnwrap(browser.activeTab)
        tab.restore()
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
        func sendMessage() async -> String? {
            await withCheckedContinuation { continuation in
                view.evaluateJavaScript(script, in: nil, in: .world(name: "BrowserLinkPreviews")) { result in
                    switch result {
                    case .success: continuation.resume(returning: nil)
                    case .failure(let error): continuation.resume(returning: error.localizedDescription)
                    }
                }
            }
        }
        let unmodifiedError = await sendMessage()
        XCTAssertNil(unmodifiedError)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.presentedPreview, "Native presentation must reject messages when Shift is not held")
        modifierFlags.insert(.shift)
        let shiftedError = await sendMessage()
        XCTAssertNil(shiftedError)
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

    func testGoogleHoverPreviewRequiresShiftAndTextContent() async throws {
        let controller = LinkPreviewController(observesSettings: false, modifierFlags: { .shift },
                                               summaryProvider: { url in
            LinkSummary(title: url.lastPathComponent, summary: "Previewed website content.")
        })
        controller.setEnabled(true)
        let world = WKContentWorld.world(name: "BrowserLinkPreviews")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: """
        window.__previewListeners = {};
        const nativeAddEventListener = document.addEventListener.bind(document);
        document.addEventListener = (type, listener, options) => {
          window.__previewListeners[type] = listener;
          return nativeAddEventListener(type, listener, options);
        };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        let tab = BrowserTab()
        controller.install(in: view, tab: tab)
        let window = PreviewFixtureWindow(contentRect: view.bounds, styleMask: [.titled, .closable],
                                          backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { controller.setEnabled(false); window.close() }
        view.loadHTMLString("""
        <title>Google results fixture</title>
        <a id="text" href="https://example.com/article"><span id="textTarget">Website article</span></a>
        <a id="image" href="https://example.com/image-result"><img id="imageTarget" alt="Image result"></a>
        """, baseURL: URL(string: "https://www.google.com/search?q=preview"))
        try await waitUntil { !view.isLoading && view.title == "Google results fixture" }

        func hover(_ selector: String, shift: Bool) async -> String? {
            let source = """
            (() => {
              const handler = window.__previewListeners?.mouseover;
              if (typeof handler !== 'function') return 'missing mouseover listener';
              try {
                handler({isTrusted:true,target:document.querySelector('\(selector)'),shiftKey:\(shift)});
                return null;
              } catch (error) { return String(error?.stack || error); }
            })()
            """
            return await withCheckedContinuation { continuation in
                view.evaluateJavaScript(source, in: nil, in: world) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? String)
                    case .failure(let error): continuation.resume(returning: String(describing: (error as NSError).userInfo))
                    }
                }
            }
        }

        var unmodifiedError = await hover("#textTarget", shift: false)
        for _ in 0..<50 where unmodifiedError == "missing mouseover listener" {
            try await Task.sleep(for: .milliseconds(20))
            unmodifiedError = await hover("#textTarget", shift: false)
        }
        XCTAssertNil(unmodifiedError)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNil(controller.presentedPreview, "Google links must not preview without Shift")
        let imageError = await hover("#imageTarget", shift: true)
        XCTAssertNil(imageError)
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertNil(controller.presentedPreview, "Image links must not produce website previews")
        let textError = await hover("#textTarget", shift: true)
        XCTAssertNil(textError)
        try await waitUntil { controller.presentedPreview?.result?.title == "article" }
    }
}

// The test runner does not activate its host app. Model an eligible source window
// without taking focus away from the user's running Release browser.
@MainActor private final class PreviewFixtureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

/// Record explicit activation requests without taking over the user's desktop.
@MainActor private final class PreviewActionWindow: NSWindow {
    private var minimized = true
    var restoreRequests = 0
    var frontRequests = 0
    var requestedResponder: NSResponder?
    override var isMiniaturized: Bool { minimized }
    override var isKeyWindow: Bool { frontRequests > 0 }
    override var firstResponder: NSResponder? { requestedResponder }
    override func deminiaturize(_ sender: Any?) { minimized = false; restoreRequests += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { frontRequests += 1 }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { requestedResponder = responder; return true }
}

@MainActor private final class PreviewDelayedSchemeHandler: NSObject, @MainActor WKURLSchemeHandler {
    private(set) var pending: (any WKURLSchemeTask)?
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) { pending = urlSchemeTask }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) { pending = nil }
    func finish() {
        guard let pending, let url = pending.request.url else { return }
        self.pending = nil
        let data = Data("<title>Loaded destination</title><p>Ready</p>".utf8)
        pending.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
        pending.didReceive(data)
        pending.didFinish()
    }
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
