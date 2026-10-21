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
        XCTAssertTrue(glass.superview?.superview === anchor, "Only the representable may own the presentation subtree")
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

    func testRepresentableHostDetachmentDismissesAndReleasesTheNativeOverlay() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        let anchor = try XCTUnwrap(palette.anchor as? CommandPaletteAnchor)
        XCTAssertTrue(palette.glass?.superview?.superview === anchor)
        XCTAssertFalse(anchor.subviews.isEmpty)
        weak var glass: NSGlassEffectView?
        glass = palette.glass
        fixture.window.contentViewController = nil
        fixture.window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        try await waitFor("detached representable cleanup") {
            anchor.window == nil && !palette.isPresented && glass == nil
        }
        XCTAssertTrue(anchor.subviews.isEmpty)
        XCTAssertFalse(palette.present(), "A detached host must not present in its old window")
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
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

    func testBlankLiveResultSelectsItsExactTabAndFocusesNativeAddressWithoutAWebView() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        browser.addTab(focusAddress: false)
        let blank = try XCTUnwrap(browser.activeTab)
        browser.activeTabID = fixture.source.id
        let count = browser.allTabs.count
        let revision = fixture.source.navigationRevision
        let palette = try await open(fixture)
        try await type("New Tab", in: palette)
        let row = try XCTUnwrap(palette.results.firstIndex {
            if case .switchTab(let destination) = $0.action { return destination.id == blank.id }
            return false
        })
        palette.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        palette.perform(.submit)
        try await waitFor("blank live-tab address focus") {
            let editor = fixture.window.firstResponder as? NSTextView
            let field = (editor?.delegate as AnyObject?) as? AddressField
            return !palette.isPresented && browser.activeTab === blank && field != nil && field !== palette.field
                && browser.consumedAddressFocusRequest == browser.addressFocusRequest
        }
        XCTAssertNil(blank.webView)
        XCTAssertNil(AddressResults.focusDestination(in: browser), "Blank pages must not poll for a web view")
        XCTAssertEqual(browser.allTabs.count, count)
        XCTAssertTrue(browser.focusedPage === blank)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
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

    func testCompletionAcceptanceSurvivesTableFocusButExplicitRowsKeepTheFullURL() async throws {
        let full = URL(string: "http://www.example.invalid:8765/Docs/?token=AbC#Part")!
        let origin = URL(string: "http://www.example.invalid:8765")!
        for mode in ["editor", "table", "unchangedUp", "explicitRow"] {
            let fixture = try await fixture()
            defer { fixture.close() }
            fixture.browser.history?.recordVisit(to: full, title: "Example")
            let revision = fixture.source.navigationRevision
            let palette = try await open(fixture)
            try await type("exa", in: palette)
            let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
            XCTAssertEqual(editor.string, "example.invalid:8765")
            XCTAssertEqual(palette.table.selectedRow, 0)
            let resultID = palette.results.first?.id
            if mode != "editor" {
                XCTAssertTrue(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
                XCTAssertTrue(fixture.window.firstResponder === palette.table)
                XCTAssertNil(palette.field.currentEditor())
                XCTAssertEqual(palette.field.stringValue, "example.invalid:8765")
                XCTAssertEqual(palette.results.first?.id, resultID)
                if mode == "unchangedUp" {
                    palette.perform(.moveUp)
                    XCTAssertEqual(palette.table.selectedRow, 0)
                }
            }
            if mode == "explicitRow" {
                // This is the same explicit-row acceptance path as the native click action.
                palette.acceptSelectedResult(acceptCompletion: false)
            } else if mode == "editor" {
                XCTAssertTrue(palette.control(palette.field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            } else {
                let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil,
                    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                palette.table.keyDown(with: enter)
            }
            let expected = mode == "explicitRow" ? full : origin
            do {
                try await waitFor("completion acceptance from \(mode)") {
                    guard let url = fixture.browser.activeTab?.url, fixture.browser.activeTab !== fixture.source else { return false }
                    if mode == "explicitRow" { return url == full }
                    // WebKit can canonicalize an origin's empty path to '/'.
                    return url.scheme == origin.scheme && url.host() == origin.host() && url.port == origin.port
                        && ["", "/"].contains(url.path) && url.query == nil && url.fragment == nil
                }
            } catch {
                XCTFail("Accepted URL from \(mode): \(fixture.browser.activeTab?.url?.absoluteString ?? "nil"), expected \(expected.absoluteString)")
                throw error
            }
            XCTAssertFalse(palette.isPresented)
            XCTAssertEqual(fixture.browser.allTabs.count, 2)
            XCTAssertEqual(fixture.source.navigationRevision, revision)
            XCTAssertEqual(fixture.browser.activeTab?.url?.scheme, "http")
            XCTAssertEqual(fixture.browser.activeTab?.url?.port, 8765)
        }
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
        XCTAssertTrue(glass.superview?.superview === anchor)
        let area = try XCTUnwrap(glass.superview).convert(anchor.bounds, from: anchor)
        XCTAssertEqual(glass.frame.midX, area.midX, accuracy: 1)
        XCTAssertLessThanOrEqual(glass.frame.width, area.width - 31)
        XCTAssertLessThanOrEqual(glass.frame.height, area.height - 31)
        XCTAssertLessThanOrEqual(palette.results.count, AddressResults.limit)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
    }

    func testResultClipAndTextGeometryFitsAcrossCountsScrollerStylesAndResizes() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let longSpace = "Research Space with a deliberately long destination context name"
        try fixture.browser.spaces.updateSpace(fixture.browser.activeSpaceID, title: longSpace, icon: .book, theme: .purple)
        for count in [3, 5, 7, 8] {
            for index in 0..<(count - 2) {
                fixture.browser.history?.recordVisit(to: URL(string: "http://geometry.invalid/\(count)/\(index)")!,
                    title: "Readable\(count) " + String(repeating: "Long history title ", count: 8))
            }
        }
        let palette = try await open(fixture)
        let scroll = try XCTUnwrap(palette.table.enclosingScrollView as? CommandPaletteResultsScrollView)
        let webView = try XCTUnwrap(fixture.source.webView)
        let sourceRevision = fixture.source.navigationRevision
        for (style, direction) in [(NSScroller.Style.legacy, NSUserInterfaceLayoutDirection.leftToRight),
                                   (.overlay, .leftToRight), (.legacy, .rightToLeft), (.overlay, .rightToLeft)] {
            palette.glass?.contentView?.userInterfaceLayoutDirection = direction
            palette.field.userInterfaceLayoutDirection = direction
            palette.table.userInterfaceLayoutDirection = direction
            scroll.userInterfaceLayoutDirection = direction
            scroll.scrollerStyle = style // Local test views only; no user preference override.
            for size in [NSSize(width: 1440, height: 852), NSSize(width: 700, height: 480), NSSize(width: 1440, height: 852)] {
                fixture.window.setFrame(NSRect(origin: fixture.window.frame.origin, size: size), display: false)
                fixture.window.layoutIfNeeded()
                try await waitFor("native resized content area") {
                    guard let anchor = palette.anchor else { return false }
                    return anchor.bounds.width > size.width / 2 && anchor.bounds.width < size.width
                }
                for count in [1, 3, 5, 7, 8, 5, 3, 1] {
                    let title = (count == 1 ? "Geometry source" : "Readable\(count) " + String(repeating: "Long live title ", count: 8))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let json = String(decoding: try JSONEncoder().encode(title), as: UTF8.self)
                    _ = try await webView.evaluateJavaScript("document.title = \(json)")
                    try await waitFor("local title metadata") { fixture.source.pageTitle == title }
                    XCTAssertTrue(fixture.window.firstResponder === palette.field.currentEditor())
                    try await type("Readable\(count)", in: palette)
                    await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                    fixture.window.contentView?.layoutSubtreeIfNeeded()
                    palette.layoutPresentation()
                    scroll.layoutSubtreeIfNeeded()
                    XCTAssertEqual(palette.results.count, count)
                    try assertReadableResultGeometry(palette, longSpace: longSpace)
                    XCTAssertTrue(fixture.window.firstResponder === palette.field.currentEditor())
                }
            }
        }
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertEqual(fixture.source.navigationRevision, sourceRevision)
    }

    private func assertReadableResultGeometry(_ palette: CommandPaletteController, longSpace: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let table = palette.table
        let scroll = try XCTUnwrap(table.enclosingScrollView, file: file, line: line)
        let anchor = try XCTUnwrap(palette.anchor, file: file, line: line)
        let clip = scroll.contentView
        let naturalHeight = table.rect(ofRow: table.numberOfRows - 1).maxY
        let heightLimit = min(336, max(table.rowHeight, anchor.bounds.height - 160))
        let fitting = naturalHeight <= heightLimit
        let diagnostic = "rows=\(table.numberOfRows), style=\(scroll.scrollerStyle), clip=\(clip.bounds), table=\(table.frame), row=\(table.rowHeight), spacing=\(table.intercellSpacing), insets=\(scroll.contentInsets)"
        XCTAssertEqual(table.effectiveStyle, .plain, diagnostic, file: file, line: line)
        XCTAssertEqual(table.rowsHeight, naturalHeight, accuracy: 0.5, file: file, line: line)
        var columnWidth = clip.bounds.width
        if naturalHeight > clip.bounds.height, let scroller = scroll.verticalScroller, !scroller.isHidden {
            let overlap = clip.convert(scroller.bounds, from: scroller).intersection(clip.bounds)
            if !overlap.isNull { columnWidth -= overlap.width }
        }
        XCTAssertEqual(table.tableColumns[0].width, columnWidth, accuracy: 0.5, diagnostic, file: file, line: line)
        XCTAssertEqual(table.frame.width, clip.bounds.width, accuracy: 0.5, diagnostic, file: file, line: line)
        XCTAssertFalse(scroll.hasHorizontalScroller, file: file, line: line)
        if fitting {
            XCTAssertGreaterThanOrEqual(clip.bounds.height + 0.5, naturalHeight, diagnostic, file: file, line: line)
            // AppKit can align half of the one-point intercell gap outside the
            // clip. Text rectangles below must still be wholly visible.
            XCTAssertTrue(scroll.documentVisibleRect.insetBy(dx: -0.5, dy: -0.5).contains(table.rect(ofRow: table.numberOfRows - 1)),
                          diagnostic, file: file, line: line)
        } else {
            XCTAssertLessThan(clip.bounds.height, naturalHeight, diagnostic, file: file, line: line)
            XCTAssertLessThanOrEqual(clip.bounds.height, heightLimit + 0.5, diagnostic, file: file, line: line)
            table.scrollRowToVisible(table.numberOfRows - 1)
            scroll.layoutSubtreeIfNeeded()
        }
        let rows = fitting ? Array(0..<table.numberOfRows) : [table.numberOfRows - 1]
        for row in rows {
            let cell = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? CommandPaletteResultCell,
                                     file: file, line: line)
            cell.layoutSubtreeIfNeeded()
            let labels = cell.subviews.compactMap { $0 as? NSTextField }
            XCTAssertEqual(labels.count, 2, file: file, line: line)
            XCTAssertEqual(cell.returnSymbol.isHidden, !table.isRowSelected(row), file: file, line: line)
            XCTAssertTrue(cell.accessibilityLabel()?.contains(palette.results[row].actionLabel) == true, file: file, line: line)
            if let space = palette.results[row].destinationSpace {
                XCTAssertEqual(space, longSpace, file: file, line: line)
                XCTAssertTrue(cell.accessibilityLabel()?.contains(space) == true, file: file, line: line)
                XCTAssertTrue(cell.toolTip?.contains(space) == true, file: file, line: line)
            }
            try assertNativeAlignment(palette, cell: cell, file: file, line: line)
            for label in labels where !label.isHidden {
                let frame = label.convert(label.bounds, to: table)
                XCTAssertTrue(cell.bounds.contains(label.frame), "\(label.identifier?.rawValue ?? "label") outside cell: \(diagnostic)", file: file, line: line)
                XCTAssertGreaterThanOrEqual(label.frame.height + 0.5, label.intrinsicContentSize.height, diagnostic, file: file, line: line)
                XCTAssertTrue(scroll.documentVisibleRect.contains(frame), "\(label.identifier?.rawValue ?? "label") clipped: \(diagnostic)", file: file, line: line)
                if let scroller = scroll.verticalScroller, !scroller.isHidden {
                    let obstruction = table.convert(scroller.bounds, from: scroller)
                    XCTAssertFalse(frame.intersects(obstruction), "Label under scroller: \(diagnostic)", file: file, line: line)
                }
                XCTAssertEqual(label.alignment, .left, file: file, line: line)
                XCTAssertEqual(label.toolTip, label.stringValue, file: file, line: line)
            }
        }
    }

    private func assertNativeAlignment(_ palette: CommandPaletteController, cell: CommandPaletteResultCell,
                                       file: StaticString, line: UInt) throws {
        let content = try XCTUnwrap(palette.glass?.contentView, file: file, line: line)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView, file: file, line: line)
        let window = try XCTUnwrap(editor.window, file: file, line: line)
        let caret = content.convert(window.convertFromScreen(editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)), from: nil)
        let headerIcon = try XCTUnwrap(content.subviews.first { $0.identifier?.rawValue == "CommandPalette.icon" } as? NSImageView,
                                      file: file, line: line)
        func imageAlignment(_ view: NSImageView) throws -> NSRect {
            let image = try XCTUnwrap(view.image, file: file, line: line)
            let drawn = view.cell?.imageRect(forBounds: view.bounds) ?? view.bounds
            let alignment = image.alignmentRect
            let x = drawn.width / image.size.width
            let y = drawn.height / image.size.height
            let imageY = view.isFlipped ? image.size.height - alignment.maxY : alignment.minY
            return content.convert(NSRect(x: drawn.minX + alignment.minX * x, y: drawn.minY + imageY * y,
                                           width: alignment.width * x, height: alignment.height * y), from: view)
        }
        func baseline(_ field: NSTextField) -> CGFloat {
            let y = field.isFlipped ? field.bounds.minY + field.firstBaselineOffsetFromTop
                : field.bounds.maxY - field.firstBaselineOffsetFromTop
            return content.convert(NSPoint(x: 0, y: y), from: field).y
        }
        let titleRect = content.convert(try XCTUnwrap(cell.title.cell, file: file, line: line).titleRect(forBounds: cell.title.bounds), from: cell.title)
        XCTAssertEqual(titleRect.minX, caret.minX, accuracy: 0.5, "Native text/caret guides, not outer frames", file: file, line: line)
        let scroll = try XCTUnwrap(palette.table.enclosingScrollView, file: file, line: line)
        var leadingObstruction: CGFloat = 0
        if palette.table.rowsHeight > scroll.contentView.bounds.height, let scroller = scroll.verticalScroller, !scroller.isHidden {
            let overlap = scroll.contentView.convert(scroller.bounds, from: scroller).intersection(scroll.contentView.bounds)
            if !overlap.isNull, overlap.width > 0, overlap.midX <= scroll.contentView.bounds.midX {
                leadingObstruction = overlap.maxX - scroll.contentView.bounds.minX
            }
        }
        XCTAssertEqual(titleRect.minX, CommandPaletteLayout.textX + leadingObstruction, accuracy: 0.5, file: file, line: line)
        let rowIcon = try imageAlignment(cell.symbol)
        let inputIcon = try imageAlignment(headerIcon)
        XCTAssertEqual(rowIcon.midX, inputIcon.midX, accuracy: 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(rowIcon.maxX, titleRect.minX, file: file, line: line)
        if let scroller = scroll.verticalScroller, !scroller.isHidden {
            XCTAssertFalse(rowIcon.intersects(content.convert(scroller.bounds, from: scroller)), file: file, line: line)
        }
        let titleFont = try XCTUnwrap(cell.title.font, file: file, line: line)
        let top = baseline(cell.title) - titleFont.capHeight
        var bottom = baseline(cell.title) - titleFont.descender
        if !cell.detail.isHidden {
            let rect = content.convert(try XCTUnwrap(cell.detail.cell, file: file, line: line).titleRect(forBounds: cell.detail.bounds), from: cell.detail)
            XCTAssertEqual(rect.minX, titleRect.minX, accuracy: 0.5, file: file, line: line)
            bottom = baseline(cell.detail) - (cell.detail.font?.descender ?? 0)
        }
        XCTAssertEqual((top + bottom) / 2, rowIcon.midY, accuracy: 0.5, "Typographic row group and icon must share a centre", file: file, line: line)
        XCTAssertEqual(rowIcon.midY, content.convert(cell.bounds, from: cell).midY, accuracy: 0.5, file: file, line: line)
        if !cell.returnSymbol.isHidden {
            let glyph = try imageAlignment(cell.returnSymbol)
            XCTAssertEqual(glyph.midY, rowIcon.midY, accuracy: 0.5, file: file, line: line)
            let titleEnd = content.convert(cell.title.frame, from: cell).maxX
            XCTAssertLessThanOrEqual(titleEnd, glyph.minX, file: file, line: line)
        }
        let layout = try XCTUnwrap(editor.layoutManager, file: file, line: line)
        let container = try XCTUnwrap(editor.textContainer, file: file, line: line)
        layout.ensureLayout(for: container)
        let range = layout.glyphRange(for: container)
        let fragment = layout.lineFragmentRect(forGlyphAt: range.location, effectiveRange: nil)
        let location = layout.location(forGlyphAt: range.location)
        let nativeBaseline = content.convert(NSPoint(x: 0, y: editor.textContainerOrigin.y + fragment.minY + location.y), from: editor).y
        XCTAssertEqual(nativeBaseline - (editor.font?.capHeight ?? 0) / 2, inputIcon.midY, accuracy: 0.5,
                       "Live native editor baseline, not its outer frame", file: file, line: line)
        XCTAssertEqual(inputIcon.midY, 32, accuracy: 0.5, file: file, line: line)
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
final class PaletteFixture {
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
