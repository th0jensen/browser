import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class CommandPaletteCurrentTests: XCTestCase {
    func testCommandGTogglesClosedAndOpenRestoringCurrentURLAndFocusWithoutNavigation() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        try await loadCurrentPage(fixture)
        let source = fixture.source
        let url = try XCTUnwrap(source.url).absoluteString
        let revision = source.navigationRevision
        let ids = fixture.browser.allTabs.map(\.id)
        let view = source.webView
        fixture.window.makeFirstResponder(view)
        let previousResponder = fixture.window.firstResponder
        let palette = try await toggleOpen(fixture)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.string, url)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: url.utf16.count))
        XCTAssertEqual(palette.glass?.style, .regular)
        XCTAssertTrue(palette.glass?.window === fixture.window)
        XCTAssertTrue(palette.glass?.superview?.superview === palette.anchor)
        XCTAssertEqual(palette.glass?.superview?.layer?.backgroundColor?.alpha ?? 0, 0)
        editor.insertText("café 🦊 partial edit", replacementRange: editor.selectedRange())
        try await waitFor("partial native edit") { palette.typedText == "café 🦊 partial edit" }
        fixture.browser.toggleCommandPalette()
        XCTAssertFalse(palette.isPresented)
        XCTAssertFalse(fixture.browser.commandPaletteWantsPresentation)
        XCTAssertTrue(fixture.window.firstResponder === previousResponder)
        _ = try await toggleOpen(fixture)
        let reopened = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        XCTAssertEqual(reopened.string, url)
        XCTAssertEqual(reopened.selectedRange(), NSRange(location: 0, length: url.utf16.count))
        XCTAssertEqual(fixture.browser.allTabs.map(\.id), ids)
        XCTAssertEqual(source.navigationRevision, revision)
        XCTAssertTrue(source.webView === view)
        palette.perform(.cancel)
        XCTAssertEqual(source.url?.absoluteString, url)
        XCTAssertEqual(source.navigationRevision, revision)
        XCTAssertEqual(fixture.browser.allTabs.map(\.id), ids)
    }

    func testNewDestinationStillStartsBlankAfterEditingModeAndOnlyAcceptanceAddsATab() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        try await loadCurrentPage(fixture)
        let sourceURL = fixture.source.url
        let revision = fixture.source.navigationRevision
        _ = try await open(fixture, mode: .editCurrentDestination)
        let palette = try await open(fixture, mode: .newDestination)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertTrue(palette.results.isEmpty)
        XCTAssertEqual(palette.glass?.frame.height, 64)
        XCTAssertEqual(palette.glass?.contentView?.subviews.compactMap { $0 as? NSTextField }.count, 1)
        XCTAssertTrue(palette.glass?.contentView?.subviews.compactMap { $0 as? NSBox }.allSatisfy(\.isHidden) == true)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        let url = URL(string: "http://127.0.0.1:9/New/Docs?token=AbC#Part")!
        try await type(url.absoluteString, in: palette)
        palette.perform(.submit)
        try await waitFor("new destination") { fixture.browser.activeTab?.url == url }
        XCTAssertEqual(fixture.browser.allTabs.count, 2)
        XCTAssertFalse(fixture.browser.activeTab === fixture.source)
        XCTAssertEqual(fixture.source.url, sourceURL)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
    }

    func testCurrentModeURLSearchHistoryAndBookmarkNavigateOnlyCapturedSource() async throws {
        for kind in ["url", "search", "history", "bookmark"] {
            let fixture = try await fixture()
            defer { fixture.close() }
            try await loadCurrentPage(fixture)
            let source = fixture.source
            let view = try XCTUnwrap(source.webView)
            let originalDelegate = view.navigationDelegate
            let transport = CancelPaletteTransport()
            view.navigationDelegate = transport
            defer { view.navigationDelegate = originalDelegate }
            let destination = URL(string: "http://127.0.0.1:8765/\(kind)/Docs?token=AbC#Part")!
            let query: String
            switch kind {
            case "history":
                query = "Local History Destination"
                fixture.browser.history?.recordVisit(to: destination, title: query)
            case "bookmark":
                query = "Local Bookmark Destination"
                fixture.bookmarks.toggle(title: query, url: destination)
            case "search": query = "a specific current page search"
            default: query = destination.absoluteString
            }
            let revision = source.navigationRevision
            let palette = try await open(fixture, mode: .editCurrentDestination)
            try await type(query, in: palette)
            if kind == "history" || kind == "bookmark" {
                guard case .openURL = palette.results.first?.action else { return XCTFail("Expected URL navigation result") }
            }
            palette.perform(.submit)
            let expected = kind == "search" ? SearchEngine.current.searchURL(for: query) : destination
            try await waitFor("captured-source \(kind) navigation") { source.url == expected }
            XCTAssertFalse(palette.isPresented)
            XCTAssertTrue(fixture.browser.activeTab === source)
            XCTAssertTrue(fixture.browser.focusedPage === source)
            XCTAssertTrue(source.webView === view)
            XCTAssertEqual(fixture.browser.allTabs.count, 1)
            XCTAssertGreaterThan(source.navigationRevision, revision)
        }
    }

    func testCurrentModeUsesFocusedSplitPaneAndLivePeekRatherThanTheirOtherPages() async throws {
        for usePeek in [false, true] {
            let fixture = try await fixture()
            defer { fixture.close() }
            let browser = fixture.browser
            let target: BrowserTab
            if usePeek {
                target = browser.openPeek(from: fixture.source)
            } else {
                browser.addTab(focusAddress: false)
                target = try XCTUnwrap(browser.activeTab)
                XCTAssertTrue(browser.makeSplit(fixture.source.id, with: target.id))
                browser.activeTabID = target.id
            }
            target.load(URL(string: "data:text/html,<title>Focused Target</title><p>Retain</p>")!)
            try await waitFor("focused target") { target.pageTitle == "Focused Target" && !target.isLoading }
            let sourceRevision = fixture.source.navigationRevision
            let targetView = target.webView
            let count = browser.allTabs.count
            let peekID = browser.peek?.id
            let split = browser.activeSplit
            let palette = try await open(fixture, mode: .editCurrentDestination)
            XCTAssertEqual(palette.field.currentEditor()?.string, target.url?.absoluteString)
            let destination = URL(string: "http://127.0.0.1:9/Focused/Docs?token=AbC#Part")!
            try await type(destination.absoluteString, in: palette)
            palette.perform(.submit)
            try await waitFor("focused current destination") { target.url == destination }
            XCTAssertEqual(browser.allTabs.count, count)
            XCTAssertTrue(browser.focusedPage === target)
            XCTAssertTrue(target.webView === targetView)
            XCTAssertEqual(browser.peek?.id, peekID)
            XCTAssertEqual(browser.activeSplit, split)
            XCTAssertEqual(fixture.source.navigationRevision, sourceRevision)
        }
    }

    func testBlankAndEmptySpaceCurrentModeAreSideEffectFreeUntilExplicitAcceptance() async throws {
        for empty in [false, true] {
            let fixture = try await fixture()
            defer { fixture.close() }
            let browser = fixture.browser
            if empty {
                let space = try browser.spaces.createSpace(title: "Empty current destination")
                XCTAssertTrue(browser.selectSpace(space.id, createsInitialTab: false))
            } else { browser.addTab(focusAddress: false) }
            let target = browser.activeTab
            let ids = browser.allTabs.map(\.id)
            let palette = try await open(fixture, mode: .editCurrentDestination)
            XCTAssertEqual(palette.field.currentEditor()?.string, "")
            XCTAssertEqual(browser.allTabs.map(\.id), ids)
            XCTAssertNil(target?.webView)
            palette.perform(.cancel)
            XCTAssertEqual(browser.allTabs.map(\.id), ids)
            _ = try await open(fixture, mode: .editCurrentDestination)
            let destination = URL(string: "http://127.0.0.1:9/EmptyCurrent")!
            try await type(destination.absoluteString, in: palette)
            palette.perform(.submit)
            try await waitFor("blank/empty acceptance") { browser.activeTab?.url == destination }
            XCTAssertEqual(browser.allTabs.count, ids.count + (empty ? 1 : 0))
            if !empty { XCTAssertTrue(browser.activeTab === target) }
        }
    }

    func testStaleCurrentSourceCannotNavigateAReplacementSelectionOrPeek() async throws {
        for change in ["tab", "space", "revision", "replacement", "peek", "peekRevision"] {
            let fixture = try await fixture()
            defer { fixture.close() }
            let browser = fixture.browser
            let target = change.hasPrefix("peek") ? browser.openPeek(from: fixture.source) : fixture.source
            let palette = try await open(fixture, mode: .editCurrentDestination)
            try await type("http://127.0.0.1:9/MustNotNavigate", in: palette)
            switch change {
            case "tab": browser.addTab(focusAddress: false)
            case "space": _ = try browser.createSpace(title: "Different")
            case "revision", "peekRevision": target.invalidateNavigation()
            case "replacement":
                browser.restoreSession(WindowSession(tabs: [TabSession(url: nil, title: "", interactionState: nil, id: target.id)], selectedIndex: 0))
            default: _ = browser.openPeek(from: fixture.source)
            }
            let tabs = browser.allTabs
            let urls = tabs.map(\.url)
            let revisions = tabs.map(\.navigationRevision)
            let activeID = browser.activeTabID
            let spaceID = browser.activeSpaceID
            let peek = browser.peek
            let peekRevision = peek?.tab.navigationRevision
            palette.acceptSelectedResult()
            XCTAssertEqual(browser.allTabs.map(\.id), tabs.map(\.id))
            XCTAssertEqual(browser.allTabs.map(\.url), urls)
            XCTAssertEqual(browser.allTabs.map(\.navigationRevision), revisions)
            XCTAssertEqual(browser.activeTabID, activeID)
            XCTAssertEqual(browser.activeSpaceID, spaceID)
            XCTAssertEqual(browser.peek?.id, peek?.id)
            XCTAssertEqual(browser.peek?.tab.navigationRevision, peekRevision)
        }
    }

    func testCurrentModeIMEIsNotSubmittedAndToggleClosesBeforeNextOpenReseeds() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        try await loadCurrentPage(fixture)
        let revision = fixture.source.navigationRevision
        let palette = try await open(fixture, mode: .editCurrentDestination)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.field))
        XCTAssertFalse(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        palette.perform(.submit)
        XCTAssertTrue(palette.isPresented)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
        fixture.browser.toggleCommandPalette()
        XCTAssertFalse(palette.isPresented)
        _ = try await toggleOpen(fixture)
        let reopened = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        XCTAssertFalse(reopened.hasMarkedText())
        let expected = try XCTUnwrap(fixture.source.url).absoluteString
        XCTAssertEqual(reopened.string, expected)
        XCTAssertEqual(reopened.selectedRange(), NSRange(location: 0, length: expected.utf16.count))
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
    }

    func testMenuRouterDispatchesCurrentNewAndFindAlternatesOnce() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let target = PaletteMenuTarget(browser: fixture.browser)
        let menu = NSMenu(title: "Browser commands")
        menu.autoenablesItems = false
        for (title, key, modifiers, action) in [
            (CommandPaletteMode.editCurrentDestination.menuTitle, "g", NSEvent.ModifierFlags.command, #selector(PaletteMenuTarget.current)),
            (CommandPaletteMode.newDestination.menuTitle, "t", .command, #selector(PaletteMenuTarget.new)),
            ("Open Location", "l", .command, #selector(PaletteMenuTarget.location)),
            ("Find Next", "g", [.command, .option], #selector(PaletteMenuTarget.next)),
            ("Find Previous", "G", [.command, .option, .shift], #selector(PaletteMenuTarget.previous)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            menu.addItem(item)
        }
        func event(_ key: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            let characters = modifiers.contains(.shift) ? key.uppercased() : key
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: key == "g" ? 5 : 17))
        }
        let request = fixture.browser.commandPaletteRequest
        let addressRequest = fixture.browser.addressFocusRequest
        XCTAssertTrue(BrowserShortcutView.performMenuCommand(try event("g", .command), menu: menu))
        XCTAssertEqual(target.currentCalls, 1)
        XCTAssertEqual(fixture.browser.commandPaletteRequest, request + 1)
        XCTAssertEqual(fixture.browser.commandPaletteMode, .editCurrentDestination)
        XCTAssertEqual(fixture.browser.addressFocusRequest, addressRequest)
        XCTAssertTrue(BrowserShortcutView.performMenuCommand(try event("g", [.command, .option]), menu: menu))
        XCTAssertTrue(BrowserShortcutView.performMenuCommand(try event("g", [.command, .option, .shift]), menu: menu))
        XCTAssertEqual(target.nextCalls, 1)
        XCTAssertEqual(target.previousCalls, 1)
        XCTAssertEqual(fixture.browser.commandPaletteRequest, request + 1)
        XCTAssertFalse(BrowserShortcutView.performMenuCommand(try event("g", []), menu: menu))
        XCTAssertTrue(BrowserShortcutView.performMenuCommand(try event("t", .command), menu: menu))
        XCTAssertEqual(fixture.browser.commandPaletteRequest, request + 2)
        XCTAssertEqual(fixture.browser.commandPaletteMode, .newDestination)
        XCTAssertTrue(BrowserShortcutView.performMenuCommand(try event("l", .command), menu: menu))
        XCTAssertEqual(fixture.browser.addressFocusRequest, addressRequest + 1)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertEqual(CommandPaletteMode.editCurrentDestination.menuTitle, "Toggle Command Bar")
    }

    func testOnlySelectedResultShowsReturnAcrossSelectionReloadAndReuse() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        for index in 0..<5 {
            fixture.browser.history?.recordVisit(to: URL(string: "http://minimal.invalid/\(index)")!, title: "Minimal row \(index)")
        }
        let palette = try await open(fixture, mode: .newDestination)
        XCTAssertTrue(palette.results.isEmpty)
        try await type("unmatched query", in: palette)
        try assertSelectedGlyph(palette)
        XCTAssertTrue((palette.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CommandPaletteResultCell)?.detail.isHidden == true)
        try await type("Minimal", in: palette)
        try assertSelectedGlyph(palette)
        palette.perform(.moveDown)
        try assertSelectedGlyph(palette)
        palette.perform(.moveUp)
        try assertSelectedGlyph(palette)
        palette.table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        try assertSelectedGlyph(palette)
        palette.table.reloadData()
        palette.table.layoutSubtreeIfNeeded()
        try assertSelectedGlyph(palette)
        let old = try XCTUnwrap(palette.table.view(atColumn: 0, row: 3, makeIfNecessary: true) as? CommandPaletteResultCell)
        let oldRow = try XCTUnwrap(palette.table.rowView(atRow: 3, makeIfNecessary: true))
        let oldGlass = try XCTUnwrap(oldRow.subviews.compactMap { $0 as? NSGlassEffectView }.first)
        old.backgroundStyle = .normal // Inactive-window drawing must not decide selection.
        XCTAssertEqual(old.returnSymbol.isHidden, !palette.table.isRowSelected(3))
        try await type("", in: palette)
        XCTAssertTrue(palette.results.isEmpty)
        XCTAssertTrue(old.returnSymbol.isHidden)
        XCTAssertTrue(oldGlass.isHidden, "A detached/reused row must not retain its glass selection")
        try await type("Minimal", in: palette)
        try assertSelectedGlyph(palette)
        XCTAssertEqual(palette.table.selectedRow, 0)
    }

    private func assertSelectedGlyph(_ palette: CommandPaletteController) throws {
        XCTAssertEqual(palette.table.selectionHighlightStyle, .none, "No flat AppKit selection fill")
        for row in 0..<palette.results.count {
            let cell = try XCTUnwrap(palette.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? CommandPaletteResultCell)
            let rowView = try XCTUnwrap(palette.table.rowView(atRow: row, makeIfNecessary: true))
            rowView.layoutSubtreeIfNeeded()
            let glass = try XCTUnwrap(rowView.subviews.compactMap { $0 as? NSGlassEffectView }.first)
            XCTAssertEqual(glass.identifier?.rawValue, "CommandResult.selectionGlass")
            XCTAssertEqual(glass.style, .regular)
            XCTAssertEqual(glass.isHidden, !palette.table.isRowSelected(row))
            XCTAssertEqual(glass.cornerRadius, glass.bounds.height / 2, accuracy: 0.5)
            XCTAssertGreaterThan(glass.bounds.height, 0)
            XCTAssertTrue(rowView.bounds.contains(glass.frame))
            XCTAssertNil(glass.hitTest(NSPoint(x: glass.bounds.midX, y: glass.bounds.midY)))
            XCTAssertFalse(glass.isAccessibilityElement())
            XCTAssertEqual(rowView.interiorBackgroundStyle, .normal)
            let glassIndex = try XCTUnwrap(rowView.subviews.firstIndex { $0 === glass })
            let cellIndex = try XCTUnwrap(rowView.subviews.firstIndex { $0 === cell })
            XCTAssertLessThan(glassIndex, cellIndex, "Glass stays behind native row controls")
            cell.layoutSubtreeIfNeeded()
            XCTAssertEqual(cell.returnSymbol.isHidden, row != palette.table.selectedRow)
            XCTAssertEqual(cell.isResultSelected, row == palette.table.selectedRow)
            XCTAssertFalse(cell.returnSymbol.isAccessibilityElement())
            XCTAssertEqual(cell.subviews.compactMap { $0 as? NSTextField }.count, 2)
            XCTAssertTrue(cell.accessibilityLabel()?.contains(palette.results[row].actionLabel) == true)
            XCTAssertGreaterThan(cell.title.frame.width, cell.bounds.width * 0.65)
        }
    }

    private func fixture() async throws -> PaletteFixture {
        let fixture = try PaletteFixture(isPrivate: false)
        do {
            try await waitFor("hosted source") {
                fixture.browser.window === fixture.window && fixture.source.webView?.window === fixture.window
                    && fixture.source.pageTitle == "Palette Source" && fixture.browser.commandPalette?.anchor?.window === fixture.window
            }
            return fixture
        } catch { fixture.close(); throw error }
    }

    private func loadCurrentPage(_ fixture: PaletteFixture) async throws {
        let base = URL(string: "http://127.0.0.1:8765/Docs/Café/🦊?token=AbC&language=日本語#Section")!
        fixture.source.webView?.loadHTMLString("<title>Current Source</title><p>Local current URL fixture</p>", baseURL: base)
        try await waitFor("local current URL") {
            fixture.source.pageTitle == "Current Source" && !fixture.source.isLoading && fixture.source.url?.host() == "127.0.0.1"
        }
    }

    private func open(_ fixture: PaletteFixture, mode: CommandPaletteMode) async throws -> CommandPaletteController {
        fixture.browser.showCommandPalette(mode: mode)
        return try await waitForOpen(fixture, mode: mode)
    }

    private func toggleOpen(_ fixture: PaletteFixture) async throws -> CommandPaletteController {
        XCTAssertFalse(fixture.browser.commandPalette?.isPresented == true)
        XCTAssertFalse(fixture.browser.commandPaletteWantsPresentation)
        fixture.browser.toggleCommandPalette()
        return try await waitForOpen(fixture, mode: .editCurrentDestination)
    }

    private func waitForOpen(_ fixture: PaletteFixture, mode: CommandPaletteMode) async throws -> CommandPaletteController {
        let request = fixture.browser.commandPaletteRequest
        try await waitFor("applied command palette request") {
            guard let palette = fixture.browser.commandPalette, let anchor = palette.anchor as? CommandPaletteAnchor else { return false }
            return anchor.applied == request && palette.isPresented && palette.mode == mode && palette.field.currentEditor() != nil
        }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        return try XCTUnwrap(fixture.browser.commandPalette)
    }

    private func type(_ text: String, in palette: CommandPaletteController) async throws {
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await waitFor("native edit") { palette.typedText == text }
    }

    private func waitFor(_ name: String, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for \(name)"); throw CurrentPaletteFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum CurrentPaletteFailure: Error { case timeout }

@MainActor
private final class CancelPaletteTransport: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy { .cancel }
}

@MainActor
private final class PaletteMenuTarget: NSObject {
    let browser: BrowserModel
    var currentCalls = 0
    var nextCalls = 0
    var previousCalls = 0
    init(browser: BrowserModel) { self.browser = browser }
    @objc func current() { currentCalls += 1; browser.toggleCommandPalette() }
    @objc func new() {
        let compatibleAction: () -> Void = browser.showCommandPalette
        compatibleAction()
    }
    @objc func location() { browser.requestAddressFocus() }
    @objc func next() { nextCalls += 1 }
    @objc func previous() { previousCalls += 1 }
}
