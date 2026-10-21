import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class CommandPaletteTests: XCTestCase {
    func testOpeningAndEscapeKeepTheSourcePageAndRestoreNativeFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let source = fixture.source
        let revision = source.navigationRevision
        let view = source.webView
        let childCount = fixture.window.childWindows?.count ?? 0
        XCTAssertTrue(fixture.window.makeFirstResponder(try XCTUnwrap(view)))
        let palette = try await open(fixture)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertTrue(fixture.browser.activeTab === source)
        XCTAssertTrue(source.webView === view)
        XCTAssertEqual(source.navigationRevision, revision)
        XCTAssertEqual(fixture.window.childWindows?.count ?? 0, childCount, "The palette is not a second window")
        XCTAssertEqual(palette.glass?.style, .regular)
        XCTAssertTrue(palette.glass?.window === fixture.window)
        XCTAssertTrue(fixture.window.firstResponder === palette.field.currentEditor())
        XCTAssertEqual(palette.field.accessibilityLabel(), "Command Bar, search or enter address")
        XCTAssertEqual(palette.table.accessibilityLabel(), "Command Bar results")

        let glass = try XCTUnwrap(palette.glass)
        let anchor = try XCTUnwrap(palette.anchor)
        let area = try XCTUnwrap(glass.superview).convert(anchor.bounds, from: anchor)
        XCTAssertEqual(glass.frame.midX, area.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(glass.frame.width, area.width - 31)
        XCTAssertLessThanOrEqual(glass.frame.width, 720)
        XCTAssertLessThan(glass.frame.height, area.height)
        palette.perform(.cancel)
        XCTAssertFalse(palette.isPresented)
        XCTAssertTrue(fixture.window.firstResponder === view)
        XCTAssertTrue(fixture.browser.focusedPage === source)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertEqual(source.navigationRevision, revision)
    }

    func testCancellingOverPeekRestoresThatSamePeekAndNativeFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let peek = fixture.browser.openPeek(from: fixture.source)
        try await waitFor("Peek attachment") { peek.webView?.window === fixture.window }
        let revision = fixture.source.navigationRevision
        let palette = try await open(fixture)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        XCTAssertTrue(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        try await waitFor("original Peek focus") { fixture.window.firstResponder === peek.webView }
        XCTAssertFalse(palette.isPresented)
        XCTAssertTrue(fixture.browser.peek?.tab === peek)
        XCTAssertTrue(fixture.browser.focusedPage === peek)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
    }

    func testOutsideDismissalConsumesBothClickEdgesWithoutNavigation() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        XCTAssertTrue(fixture.window.makeFirstResponder(try XCTUnwrap(fixture.source.webView)))
        let revision = fixture.source.navigationRevision
        let palette = try await open(fixture)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 2, y: 2),
                modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            XCTAssertNil(palette.handle(event), "Dismissal must not leak \(type) to the source page")
        }
        XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
        XCTAssertTrue(fixture.window.firstResponder === fixture.source.webView)
    }

    func testDirectSpaceAcceptanceSelectsItsExistingPageWithoutAPhantomTab() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        let originalSpace = browser.activeSpaceID
        let destination = try browser.createSpace(title: "Research")
        let target = try XCTUnwrap(browser.activeTab)
        target.load(URL(string: "data:text/html,<title>Research Page</title>")!)
        try await waitFor("destination page") { target.pageTitle == "Research Page" }
        let targetView = try XCTUnwrap(target.webView)
        let revision = target.navigationRevision
        XCTAssertTrue(browser.selectSpace(originalSpace))
        _ = browser.openPeek(from: fixture.source)
        let count = browser.allTabs.count
        let ids = browser.allTabs.map(\.id)
        let palette = try await open(fixture)
        try await type("Research", in: palette)
        XCTAssertEqual(palette.results.first?.action, .switchSpace(.init(id: destination.id, profileID: destination.profileID)))
        XCTAssertEqual(palette.results.first?.actionLabel, "Switch Space")
        palette.perform(.submit)
        try await waitFor("Space destination attachment and focus") {
            !palette.isPresented && browser.activeSpaceID == destination.id
                && browser.focusedPage === target && fixture.window.firstResponder === targetView
        }
        XCTAssertNil(browser.peek)
        XCTAssertEqual(browser.allTabs.count, count)
        XCTAssertEqual(browser.allTabs.map(\.id), ids)
        XCTAssertTrue(target.webView === targetView)
        XCTAssertEqual(target.navigationRevision, revision)
    }

    func testUnvisitedSpaceAcceptanceFocusesAddressWithoutCreatingATab() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        let destination = try browser.spaces.createSpace(title: "Empty Destination")
        let sourceRevision = fixture.source.navigationRevision
        let palette = try await open(fixture)
        try await type("Empty Destination", in: palette)
        XCTAssertEqual(palette.results.first?.action, .switchSpace(.init(id: destination.id, profileID: destination.profileID)))
        palette.perform(.submit)
        try await waitFor("empty Space native address focus") {
            let field = (fixture.window.firstResponder as? NSTextView)?.delegate as? AddressField
            return !palette.isPresented && browser.activeSpaceID == destination.id && field != nil && field !== palette.field
        }
        XCTAssertTrue(browser.tabs.isEmpty)
        XCTAssertNil(browser.activeTab)
        XCTAssertEqual(browser.allTabs.count, 1)
        XCTAssertEqual(fixture.source.navigationRevision, sourceRevision)
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        let field = try XCTUnwrap((editor.delegate as AnyObject?) as? AddressField)
        let coordinator = try XCTUnwrap(field.delegate as? AddressTextField.Coordinator)
        let url = URL(string: "http://127.0.0.1:9/Docs/?token=AbC#Part")!
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        editor.selectAll(nil)
        editor.insertText(url.absoluteString, replacementRange: editor.selectedRange())
        try await waitFor("empty Space address binding") { coordinator.parent.text == url.absoluteString }
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitFor("explicit empty Space navigation") { browser.activeTab?.url == url }
        XCTAssertEqual(browser.allTabs.count, 2)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(fixture.source.navigationRevision, sourceRevision)
    }

    func testFallbackAddressSubmissionFromEmptySpaceCreatesOnlyTheIntendedDestination() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        let destination = try browser.spaces.createSpace(title: "Empty Fallback", icon: .book, theme: .purple)
        let sourceRevision = fixture.source.navigationRevision
        XCTAssertTrue(browser.selectSpace(destination.id, createsInitialTab: false))
        XCTAssertNil(browser.activeTab)
        XCTAssertEqual(browser.allTabs.count, 1)
        browser.requestAddressFocus()
        try await waitFor("empty fallback editor focus") {
            let editor = fixture.window.firstResponder as? NSTextView
            let field = (editor?.delegate as AnyObject?) as? AddressField
            return browser.consumedAddressFocusRequest == browser.addressFocusRequest && field != nil
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
        let field = try XCTUnwrap((editor.delegate as AnyObject?) as? AddressField)
        let coordinator = try XCTUnwrap(field.delegate as? AddressTextField.Coordinator)
        let url = URL(string: "http://127.0.0.1:9/Fallback/Docs?token=AbC#Part")!
        editor.selectAll(nil)
        editor.insertText(url.absoluteString, replacementRange: editor.selectedRange())
        try await waitFor("fallback address binding") { coordinator.parent.text == url.absoluteString }
        coordinator.parent.onSubmit()
        try await waitFor("fallback destination navigation") { browser.activeTab?.url == url }
        let target = try XCTUnwrap(browser.activeTab)
        XCTAssertEqual(target.spaceID, destination.id)
        XCTAssertEqual(target.profileID, destination.profileID)
        XCTAssertTrue(target.webView?.configuration.websiteDataStore === browser.websiteDataStore)
        XCTAssertTrue(browser.focusedPage === target)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.allTabs.count, 2)
        XCTAssertTrue(browser.tabAcrossSpaces(withID: fixture.source.id) === fixture.source)
        XCTAssertEqual(fixture.source.navigationRevision, sourceRevision)
        XCTAssertEqual(browser.spaces.space(destination.id)?.icon, .book)
        XCTAssertEqual(browser.spaces.space(destination.id)?.theme, .purple)
    }

    func testSharedStripEntryActionOpensPaletteAndLegacyHostKeepsCompatibility() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        for layout in [TabLayout.vertical, .horizontal] {
            let strip = TabStrip(browser: fixture.browser, layout: layout, isFullScreen: false,
                                 hoverCardTabID: .constant(nil), newTabAction: { fixture.browser.showCommandPalette() })
            let count = fixture.browser.allTabs.count
            // The row/plus and strip menu use this same action. Older hosts can
            // omit it without importing the command-palette module.
            strip.requestNewTab()
            try await waitFor("shared strip destination request") { fixture.browser.commandPalette?.isPresented == true }
            XCTAssertEqual(fixture.browser.allTabs.count, count)
            fixture.browser.commandPalette?.dismiss()
        }
        let legacy = TabStrip(browser: fixture.browser, layout: .horizontal, isFullScreen: false, hoverCardTabID: .constant(nil))
        let count = fixture.browser.allTabs.count
        legacy.requestNewTab()
        XCTAssertEqual(fixture.browser.allTabs.count, count + 1)
        XCTAssertTrue(fixture.browser.activeTab?.isNewTab == true)
        XCTAssertNil(fixture.browser.activeTab?.webView)
    }

    func testAcceptedOtherSpaceTabHasNoPhantomTabAndFocusesTheExactPage() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let source = fixture.source
        let sourceSpace = fixture.browser.activeSpaceID
        let view = source.webView
        let revision = source.navigationRevision
        _ = try fixture.browser.createSpace(title: "Work")
        let count = fixture.browser.allTabs.count
        let palette = try await open(fixture)
        try await type("Palette Source", in: palette)
        XCTAssertEqual(palette.results.first?.destinationSpace, "Default")
        guard case .switchTab(let destination) = palette.results.first?.action else { return XCTFail("Expected live source result") }
        XCTAssertEqual(destination.id, source.id)
        XCTAssertEqual(palette.table.selectedRow, 0)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        XCTAssertTrue(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await waitFor("destination attachment and exact focus") {
            !palette.isPresented && fixture.browser.focusedPage === source && fixture.window.firstResponder === view
        }
        XCTAssertEqual(fixture.browser.activeSpaceID, sourceSpace)
        XCTAssertEqual(fixture.browser.allTabs.count, count)
        XCTAssertEqual(source.navigationRevision, revision)
        XCTAssertTrue(source.webView === view)
    }

    func testAcceptedActiveResultDismissesPeekButRejectedClosedResultKeepsIt() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        let source = fixture.source
        browser.addTab(focusAddress: false)
        let target = try XCTUnwrap(browser.activeTab)
        target.load(URL(string: "data:text/html,<title>Closed Target</title>")!)
        try await waitFor("target title") { target.pageTitle == "Closed Target" }
        browser.activeTabID = source.id
        let peek = browser.openPeek(from: source)
        let palette = try await open(fixture)
        try await type("Closed Target", in: palette)
        guard case .switchTab = palette.results.first?.action else { return XCTFail("Expected live target") }
        browser.closeTab(target.id)
        let count = browser.allTabs.count
        let revision = source.navigationRevision
        palette.acceptSelectedResult()
        XCTAssertTrue(palette.isPresented)
        XCTAssertTrue(browser.peek?.tab === peek)
        XCTAssertTrue(browser.focusedPage === peek)
        XCTAssertEqual(browser.allTabs.count, count)
        XCTAssertEqual(source.navigationRevision, revision)
        try await type("Palette Source", in: palette)
        palette.acceptSelectedResult()
        try await waitFor("accepted source focus") { !palette.isPresented && fixture.window.firstResponder === source.webView }
        XCTAssertNil(browser.peek)
        XCTAssertTrue(browser.focusedPage === source)
        XCTAssertEqual(browser.allTabs.count, count)
        XCTAssertEqual(source.navigationRevision, revision)
    }

    func testSavedAcceptanceDismissesPeekAndKeepsTheExactLivePage() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        let saved = try browser.folders.savePage(url: URL(string: "https://saved.invalid/home")!, title: "Saved Source", in: nil)
        fixture.source.folderPageID = saved.id
        let revision = fixture.source.navigationRevision
        let url = fixture.source.url
        _ = browser.openPeek(from: fixture.source)
        let palette = try await open(fixture)
        try await type("saved.invalid", in: palette)
        guard case .openSavedPage = palette.results.first?.action else { return XCTFail("Expected saved result") }
        palette.perform(.submit)
        try await waitFor("saved page focus") { !palette.isPresented && fixture.window.firstResponder === fixture.source.webView }
        XCTAssertNil(browser.peek)
        XCTAssertTrue(browser.focusedPage === fixture.source)
        XCTAssertEqual(browser.allTabs.count, 1)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
        XCTAssertEqual(fixture.source.url, url)
    }

    func testExplicitNewTabCommandCreatesOnlyAfterAcceptanceAndFocusesNativeAddress() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        try await type("New Tab", in: palette)
        XCTAssertEqual(palette.results.first?.action, .command(.newTab))
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        palette.perform(.submit)
        try await waitFor("accepted New Tab command focus") {
            let field = (fixture.window.firstResponder as? NSTextView)?.delegate as? AddressField
            return !palette.isPresented && field != nil && field !== palette.field
                && fixture.browser.activeTab?.isNewTab == true
        }
        XCTAssertEqual(fixture.browser.allTabs.count, 2)
        XCTAssertNil(fixture.browser.activeTab?.webView)
    }

    func testTypedAddressCreatesOnlyItsAcceptedDestinationAndPreservesSource() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let originalURL = fixture.source.url
        let revision = fixture.source.navigationRevision
        let palette = try await open(fixture)
        let destination = URL(string: "http://127.0.0.1:9/Docs/?token=AbC#Part")!
        try await type(destination.absoluteString, in: palette)
        XCTAssertEqual(palette.results.first?.action, .navigate(destination))
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        palette.perform(.submit)
        try await waitFor("accepted destination") { fixture.browser.activeTab?.url == destination }
        XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(fixture.browser.allTabs.count, 2)
        XCTAssertFalse(fixture.browser.activeTab === fixture.source)
        XCTAssertEqual(fixture.source.url, originalURL)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
    }

    func testPrivatePaletteExcludesNormalSavedHistoryAndTabs() async throws {
        let fixture = try await fixture(isPrivate: true)
        defer { fixture.close() }
        fixture.bookmarks.toggle(title: "Secret Bookmark", url: URL(string: "https://secret.invalid")!)
        let palette = try await open(fixture)
        try await type("secret", in: palette)
        XCTAssertEqual(palette.results.map(\.action), [.search("secret")])
        XCTAssertNil(fixture.browser.history)
        XCTAssertFalse(AddressBrowserCommand.showHistory.isAvailable(in: fixture.browser))
        palette.perform(.cancel)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
    }

    func testNativeCompletionDeletionPasteIMEAndResultKeys() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let url = URL(string: "http://www.example.invalid:8765/Docs/?token=AbC#Part")!
        fixture.browser.history?.recordVisit(to: url, title: "Example")
        let palette = try await open(fixture)
        try await type("exa", in: palette)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.string, "example.invalid:8765")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: editor.string.utf16.count - 3))
        XCTAssertEqual(AddressSuggestions.completedURL(for: editor.string, with: palette.results.first?.completionSuggestion)?.absoluteString,
                       "http://www.example.invalid:8765")
        editor.deleteBackward(nil)
        try await waitFor("native suffix deletion") { palette.completionStart == nil && editor.string == "exa" }
        editor.selectAll(nil)
        editor.insertText(url.absoluteString, replacementRange: editor.selectedRange())
        try await waitFor("native pasted URL") { palette.typedText == url.absoluteString }
        XCTAssertEqual(editor.string, url.absoluteString)
        XCTAssertNil(palette.completionStart)
        XCTAssertTrue(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(palette.table.selectedRow, 1)
        XCTAssertTrue(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertEqual(palette.table.selectedRow, 0)
        let count = fixture.browser.allTabs.count
        editor.selectAll(nil)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.field))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(palette.results.isEmpty)
        XCTAssertFalse(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        palette.acceptSelectedResult()
        XCTAssertEqual(fixture.browser.allTabs.count, count)
        XCTAssertTrue(palette.isPresented)
        editor.insertText("日本語", replacementRange: editor.markedRange())
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.field))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(palette.typedText, "日本語")
        palette.perform(.cancel)
    }

    func testManyResultsStayBoundedOnResizeAndTabFocusStaysInThePalette() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        for index in 0..<20 {
            fixture.browser.history?.recordVisit(to: URL(string: "https://result\(index).invalid/Docs")!, title: "Result \(index)")
        }
        let palette = try await open(fixture)
        try await type("result", in: palette)
        XCTAssertLessThanOrEqual(palette.results.count, AddressResults.limit)
        XCTAssertEqual(palette.table.selectedRow, 0)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        let completedInput = editor.string
        XCTAssertTrue(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(fixture.window.firstResponder === palette.table)
        let backtab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48))
        palette.table.keyDown(with: backtab)
        XCTAssertTrue(fixture.window.firstResponder === palette.field.currentEditor())
        XCTAssertEqual(palette.field.currentEditor()?.string, completedInput)
        fixture.window.setContentSize(NSSize(width: 700, height: 480))
        try await waitFor("responsive palette width") { (palette.anchor?.bounds.width ?? 1000) < 700 }
        palette.layoutPresentation()
        let glass = try XCTUnwrap(palette.glass)
        let anchor = try XCTUnwrap(palette.anchor)
        let area = try XCTUnwrap(glass.superview).convert(anchor.bounds, from: anchor)
        XCTAssertEqual(glass.frame.midX, area.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(glass.frame.width, area.width - 31)
        XCTAssertLessThanOrEqual(glass.frame.height, area.height - 31)
        XCTAssertLessThanOrEqual(palette.results.count, AddressResults.limit)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
    }

    func testLocationRequestDismissesPaletteAndKeepsTheNativeAddressPath() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        fixture.browser.requestAddressFocus()
        try await waitFor("native address focus") {
            let field = (fixture.window.firstResponder as? NSTextView)?.delegate as? AddressField
            return !palette.isPresented && field != nil && field !== palette.field
        }
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertTrue(fixture.browser.activeTab === fixture.source)
    }

    func testContextChangeAndDeactivationCancelWithoutAcceptance() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        try await type("http://127.0.0.1:9/must-not-open", in: palette)
        fixture.browser.addTab(focusAddress: false)
        palette.acceptSelectedResult()
        XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(fixture.browser.allTabs.count, 2)
        XCTAssertTrue(fixture.browser.activeTab?.isNewTab == true)
        _ = try await open(fixture)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(fixture.browser.allTabs.count, 2)
    }

    private func fixture(isPrivate: Bool = false) async throws -> PaletteFixture {
        let fixture = try PaletteFixture(isPrivate: isPrivate)
        do {
            try await waitFor("hosted page and palette anchor") {
                fixture.browser.window === fixture.window && fixture.browser.commandPalette?.anchor?.window === fixture.window
                    && fixture.source.webView?.window === fixture.window && fixture.source.pageTitle == "Palette Source"
            }
            return fixture
        } catch { fixture.close(); throw error }
    }

    private func open(_ fixture: PaletteFixture) async throws -> CommandPaletteController {
        fixture.browser.showCommandPalette()
        try await waitFor("Command-T presentation request") {
            fixture.browser.commandPalette?.isPresented == true && fixture.browser.commandPalette?.field.currentEditor() != nil
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        return try XCTUnwrap(fixture.browser.commandPalette)
    }

    private func type(_ query: String, in palette: CommandPaletteController) async throws {
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: editor.selectedRange())
        try await waitFor("local results for \(query)") { palette.typedText == query && palette.results.last?.action == .search(query) }
    }

    private func waitFor(_ description: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for \(description)"); throw PaletteFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private enum PaletteFailure: Error { case timeout }

@MainActor
private final class PaletteFixture {
    let suite = "CommandPalette-\(UUID())"
    let defaults: UserDefaults
    let browser: BrowserModel
    let bookmarks: BookmarkStore
    let source: BrowserTab
    let window: NSWindow

    init(isPrivate: Bool) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(BookmarksBarVisibility.never.rawValue, forKey: BookmarksBarVisibility.storageKey)
        defaults.set(TabLayout.vertical.rawValue, forKey: TabLayout.storageKey)
        defaults.set(false, forKey: CompactToolbar.storageKey)
        let spaces = BrowserSpaceStore(directory: .temporaryDirectory.appending(path: UUID().uuidString), enabled: false)
        let history = HistoryStore(file: nil)
        history.recordVisit(to: URL(string: "https://secret.invalid/history")!, title: "Secret History")
        browser = BrowserModel(sitePermissions: SitePermissions(), chromePreferences: WindowChromePreferences(defaults: defaults),
                               history: history, websiteDataStore: .nonPersistent(), isPrivate: isPrivate, spaces: spaces)
        bookmarks = BookmarkStore(defaults: defaults)
        source = try XCTUnwrap(browser.activeTab)
        source.load(URL(string: "data:text/html,<title>Palette Source</title><p>Still visible</p>")!)
        browser.consumedAddressFocusRequest = browser.addressFocusRequest
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let host = NSHostingController(rootView: BrowserWindow(bookmarks: bookmarks, browser: browser).defaultAppStorage(defaults))
        host.sizingOptions = .minSize
        window.contentViewController = host
        window.orderBack(nil)
        window.toolbar?.autosavesConfiguration = false
    }

    func close() {
        browser.commandPalette?.dismiss(restoreFocus: false)
        browser.dismissPeek()
        for tab in browser.allTabs { tab.stopLoading() }
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
