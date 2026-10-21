import AppKit
import WebKit
import XCTest
@testable import Browser

@MainActor
final class CommandPalettePrefillTests: XCTestCase {
    func testUnmodifiedLocalPeekPrefillAndToggleReopenRetainExactDocumentWithoutSearch() async throws {
        for isPrivate in [false, true] {
            for scheme in ["data", "file", "about"] {
                let fixture = try await fixture(isPrivate: isPrivate)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { fixture.close(); try? FileManager.default.removeItem(at: directory) }
                let html = "<title>Local Peek</title><p>Local only</p>"
                let url: URL
                switch scheme {
                case "data": url = URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString())!
                case "file":
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    url = directory.appendingPathComponent("PrivateNotesWithoutExtension")
                    try html.write(to: url, atomically: true, encoding: .utf8)
                default: url = URL(string: "about:blank")!
                }
                let browser = fixture.browser
                let page = browser.openPeek(from: fixture.source)
                // Supply HTML directly for an extensionless file base URL.
                // Loading that fixture as a file can invoke WebKit's download UI.
                if scheme == "file" { page.webView?.loadHTMLString(html, baseURL: url) }
                else { page.load(url) }
                try await waitFor("local Peek document: \(scheme), private=\(isPrivate)") {
                    page.url == url && !page.isLoading && page.webView?.window === fixture.window
                }
                let view = try XCTUnwrap(page.webView)
                try await setDocumentState(in: view)
                fixture.window.makeFirstResponder(view)
                let probe = PrefillNavigationProbe()
                let originalDelegate = view.navigationDelegate
                view.navigationDelegate = probe
                defer { view.navigationDelegate = originalDelegate }
                let peekID = browser.peek?.id
                let revision = page.navigationRevision
                let openerRevision = fixture.source.navigationRevision
                let openerURL = fixture.source.url
                let openerView = fixture.source.webView
                let ids = browser.allTabs.map(\.id)
                let spaceID = browser.activeSpaceID
                let selectedID = browser.activeTabID
                for attempt in 0..<2 {
                    if attempt == 1 {
                        _ = try await toggleOpen(fixture)
                        browser.toggleCommandPalette()
                        XCTAssertFalse(browser.commandPalette?.isPresented == true)
                    }
                    let palette = try await toggleOpen(fixture)
                    let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
                    XCTAssertEqual(editor.string, url.absoluteString)
                    XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: url.absoluteString.utf16.count))
                    XCTAssertEqual(palette.results.first?.action, .navigate(url))
                    XCTAssertEqual(palette.table.selectedRow, 0)
                    palette.perform(.submit)
                    await nextTurn()
                    XCTAssertFalse(palette.isPresented)
                    XCTAssertFalse(browser.commandPaletteWantsPresentation)
                    XCTAssertTrue(browser.focusedPage === page)
                    XCTAssertTrue(browser.peek?.tab === page)
                    XCTAssertEqual(browser.peek?.id, peekID)
                    XCTAssertTrue(page.webView === view)
                    XCTAssertTrue(fixture.window.firstResponder === view)
                    XCTAssertEqual(page.url, url)
                    XCTAssertEqual(page.navigationRevision, revision)
                    XCTAssertEqual(fixture.source.url, openerURL)
                    XCTAssertEqual(fixture.source.navigationRevision, openerRevision)
                    XCTAssertTrue(fixture.source.webView === openerView)
                    XCTAssertEqual(browser.allTabs.map(\.id), ids)
                    XCTAssertEqual(browser.activeSpaceID, spaceID)
                    XCTAssertEqual(browser.activeTabID, selectedID)
                    XCTAssertTrue(probe.requests.isEmpty, "No reload or search for an unchanged local source")
                    let state = try await documentState(in: view)
                    XCTAssertEqual(state, "retained|private unsaved text|4|7")
                }
            }
        }
    }

    func testUnmodifiedHTTPPrefillDoesNotSelectMatchingOpenerOrAnotherSpace() async throws {
        for duplicateInOtherSpace in [false, true] {
            let fixture = try await fixture()
            defer { fixture.close() }
            let browser = fixture.browser
            let sharedURL = URL(string: "http://127.0.0.1:9/Shared/Docs?token=AbC#Part")!
            let sourceSpaceID = browser.activeSpaceID
            try await loadLocalHTML(fixture.source, baseURL: duplicateInOtherSpace ? URL(string: "http://127.0.0.1:9/Opener")! : sharedURL)
            let other: BrowserTab
            if duplicateInOtherSpace {
                _ = try browser.createSpace(title: "Other duplicate Space")
                other = try XCTUnwrap(browser.activeTab)
                try await loadLocalHTML(other, baseURL: sharedURL)
                XCTAssertTrue(browser.selectSpace(sourceSpaceID))
                try await waitFor("restored source") { fixture.source.webView?.window === fixture.window }
            } else { other = fixture.source }
            let page = browser.openPeek(from: fixture.source)
            try await loadLocalHTML(page, baseURL: sharedURL)
            try await waitFor("visible shared Peek") { page.webView?.window === fixture.window }
            let view = try XCTUnwrap(page.webView)
            try await setDocumentState(in: view)
            let probe = PrefillNavigationProbe()
            let originalDelegate = view.navigationDelegate
            view.navigationDelegate = probe
            defer { view.navigationDelegate = originalDelegate }
            let peekID = browser.peek?.id
            let revision = page.navigationRevision
            let sourceRevision = fixture.source.navigationRevision
            let sourceURL = fixture.source.url
            let otherRevision = other.navigationRevision
            let otherView = other.webView
            let ids = browser.allTabs.map(\.id)
            let selectedID = browser.activeTabID
            let palette = try await toggleOpen(fixture)
            XCTAssertEqual(palette.results.first?.action, .navigate(sharedURL))
            XCTAssertTrue(palette.results.contains {
                if case .switchTab(let destination) = $0.action { return destination.id == other.id }
                return false
            }, "Keep the other exact-tab action available, but not selected by default")
            palette.perform(.submit)
            await nextTurn()
            XCTAssertFalse(palette.isPresented)
            XCTAssertEqual(browser.peek?.id, peekID)
            XCTAssertTrue(browser.focusedPage === page)
            XCTAssertTrue(page.webView === view)
            XCTAssertEqual(page.url, sharedURL)
            XCTAssertEqual(page.navigationRevision, revision)
            XCTAssertEqual(browser.activeTabID, selectedID)
            XCTAssertEqual(browser.activeSpaceID, sourceSpaceID)
            XCTAssertEqual(browser.allTabs.map(\.id), ids)
            XCTAssertEqual(fixture.source.url, sourceURL)
            XCTAssertEqual(fixture.source.navigationRevision, sourceRevision)
            XCTAssertEqual(other.url, sharedURL)
            XCTAssertEqual(other.navigationRevision, otherRevision)
            XCTAssertTrue(other.webView === otherView)
            XCTAssertTrue(probe.requests.isEmpty)
            let state = try await documentState(in: view)
            XCTAssertEqual(state, "retained|private unsaved text|4|7")
        }
    }

    func testExplicitTabSpaceAndSearchRowsStillExecuteInsteadOfCurrentSourceIntent() async throws {
        for action in ["tab", "space", "search"] {
            let fixture = try await fixture()
            defer { fixture.close() }
            let browser = fixture.browser
            let shared = URL(string: "http://127.0.0.1:9/Explicit")!
            if action == "tab" { try await loadLocalHTML(fixture.source, baseURL: shared) }
            let destination = action == "space" ? try browser.spaces.createSpace(title: "Explicit Destination Room") : nil
            let page = browser.openPeek(from: fixture.source)
            try await loadLocalHTML(page, baseURL: action == "tab" ? shared : URL(string: "about:blank")!)
            try await waitFor("explicit action Peek") { page.webView?.window === fixture.window }
            let view = try XCTUnwrap(page.webView)
            let probe = PrefillNavigationProbe()
            let originalDelegate = view.navigationDelegate
            view.navigationDelegate = probe
            defer { view.navigationDelegate = originalDelegate }
            let initialURL = try XCTUnwrap(page.url)
            let initialRevision = page.navigationRevision
            let peekID = browser.peek?.id
            let ids = browser.allTabs.map(\.id)
            let palette = try await toggleOpen(fixture)
            if action == "space" {
                let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
                editor.insertText("Explicit Destination Room", replacementRange: editor.selectedRange())
                try await waitFor("edited Space query") { palette.typedText == "Explicit Destination Room" }
            }
            let row = try XCTUnwrap(palette.results.firstIndex {
                switch $0.action {
                case .switchTab(let target): action == "tab" && target.id == fixture.source.id
                case .switchSpace(let target): action == "space" && target.id == destination?.id
                case .search: action == "search"
                default: false
                }
            })
            palette.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            palette.acceptSelectedResult(acceptCompletion: false)
            XCTAssertFalse(palette.isPresented)
            XCTAssertEqual(browser.allTabs.map(\.id), ids)
            if action == "search" {
                let expected = SearchEngine.current.searchURL(for: initialURL.absoluteString)
                try await waitFor("explicit search transport") { !probe.requests.isEmpty }
                XCTAssertEqual(probe.requests, [expected])
                XCTAssertGreaterThan(page.navigationRevision, initialRevision)
                XCTAssertTrue(page.webView === view)
                XCTAssertTrue(browser.focusedPage === page)
                XCTAssertEqual(browser.peek?.id, peekID)
            } else {
                XCTAssertNil(browser.peek)
                XCTAssertEqual(browser.activeSpaceID, destination?.id ?? fixture.source.spaceID)
                if action == "tab" { XCTAssertTrue(browser.activeTab === fixture.source) }
                XCTAssertTrue(probe.requests.isEmpty)
            }
        }
    }

    func testCommandGClosesNewDestinationAndRestoresOriginalPageOrNativeInputFocus() async throws {
        for fromNativeInput in [false, true] {
            let fixture = try await fixture()
            defer { fixture.close() }
            let browser = fixture.browser
            if fromNativeInput {
                browser.requestAddressFocus()
                try await waitFor("native address editor") {
                    ((fixture.window.firstResponder as? NSTextView)?.delegate as? AddressField)?.identifier?.rawValue != "BrowserCommandPaletteInput"
                        && (fixture.window.firstResponder as? NSTextView)?.delegate is AddressField
                }
            } else { fixture.window.makeFirstResponder(fixture.source.webView) }
            let originalOwner = responderOwner(in: fixture.window)
            let revision = fixture.source.navigationRevision
            let view = fixture.source.webView
            let ids = browser.allTabs.map(\.id)
            let addressRequest = browser.addressFocusRequest
            browser.showCommandPalette()
            let palette = try await waitForOpen(fixture, mode: .newDestination)
            let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
            editor.insertText("unsubmitted destination", replacementRange: editor.selectedRange())
            browser.toggleCommandPalette()
            XCTAssertFalse(palette.isPresented)
            XCTAssertFalse(browser.commandPaletteWantsPresentation)
            XCTAssertTrue(responderOwner(in: fixture.window) === originalOwner)
            XCTAssertEqual(browser.addressFocusRequest, addressRequest, "Toggle close is not Cmd-L")
            await nextTurn()
            await nextTurn()
            XCTAssertFalse(palette.isPresented)
            XCTAssertEqual(browser.allTabs.map(\.id), ids)
            XCTAssertEqual(fixture.source.navigationRevision, revision)
            XCTAssertTrue(fixture.source.webView === view)
            _ = try await toggleOpen(fixture)
            XCTAssertEqual(palette.mode, .editCurrentDestination)
            XCTAssertEqual(palette.field.currentEditor()?.string, fixture.source.url?.absoluteString)
        }
    }

    func testQueuedDoubleToggleCancelsPresentationAndLaterRequestsUseOnlyLiveIntent() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        fixture.window.makeFirstResponder(fixture.source.webView)
        let responder = fixture.window.firstResponder
        let view = fixture.source.webView
        let revision = fixture.source.navigationRevision
        let ids = browser.allTabs.map(\.id)
        for pendingNewTab in [false, true] {
            if pendingNewTab { browser.showCommandPalette() }
            else { browser.toggleCommandPalette() }
            XCTAssertTrue(browser.commandPaletteWantsPresentation)
            XCTAssertFalse(browser.commandPalette?.isPresented == true)
            browser.toggleCommandPalette()
            XCTAssertFalse(browser.commandPaletteWantsPresentation)
            let request = browser.commandPaletteRequest
            try await waitFor("consumed pending close") { (browser.commandPalette?.anchor as? CommandPaletteAnchor)?.applied == request }
            await nextTurn()
            await nextTurn()
            XCTAssertFalse(browser.commandPalette?.isPresented == true)
            XCTAssertTrue(fixture.window.firstResponder === responder)
        }
        browser.toggleCommandPalette()
        browser.toggleCommandPalette()
        browser.toggleCommandPalette()
        let palette = try await waitForOpen(fixture, mode: .editCurrentDestination)
        XCTAssertEqual(palette.field.currentEditor()?.string, fixture.source.url?.absoluteString)
        palette.perform(.cancel)
        XCTAssertFalse(browser.commandPaletteWantsPresentation)
        browser.toggleCommandPalette()
        browser.requestAddressFocus() // Cancels an unapplied palette, not only a visible one.
        await nextTurn()
        await nextTurn()
        XCTAssertFalse(browser.commandPaletteWantsPresentation)
        XCTAssertFalse(palette.isPresented)
        XCTAssertEqual(browser.allTabs.map(\.id), ids)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
        XCTAssertTrue(fixture.source.webView === view)
    }

    func testLongCurrentURLKeepsNativeCaretAcrossResizeAndRepeatedNewTabSelectsAll() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let url = URL(string: "http://127.0.0.1:9/" + String(repeating: "LongCaseSensitivePath/", count: 70) + "Café/🦊?token=AbC#Part")!
        try await loadLocalHTML(fixture.source, baseURL: url)
        let revision = fixture.source.navigationRevision
        let view = fixture.source.webView
        let palette = try await toggleOpen(fixture)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        let text = url.absoluteString
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        editor.moveToEndOfDocument(nil)
        for size in [NSSize(width: 620, height: 460), NSSize(width: 1240, height: 820)] {
            fixture.window.setContentSize(size)
            await nextTurn()
            palette.layoutPresentation()
            // NSTextInputClient.firstRect at document end can be zero in this
            // non-key hosted field. Use real TextKit insertion positions and a
            // native scroll-to-visible operation, not that invalid IME rect.
            let insertion = try nativeInsertion(in: editor)
            let pixel = 1 / fixture.window.backingScaleFactor
            editor.scrollToVisible(NSRect(x: insertion.rect.minX, y: insertion.rect.minY,
                                          width: pixel, height: insertion.rect.height))
            palette.layoutPresentation()
            let measured = try nativeInsertion(in: editor)
            let clip = try XCTUnwrap(editor.superview as? NSClipView)
            let viewport = editor.convert(clip.bounds, from: clip)
            let content = try XCTUnwrap(palette.glass?.contentView)
            let input = content.convert(palette.field.bounds, from: palette.field)
            let visibleInput = content.convert(clip.bounds, from: clip)
            let diagnostic = "insertion=\(measured.rect), viewport=\(viewport), field=\(input), nativeViewport=\(visibleInput), editor=\(editor.frame), origin=\(editor.textContainerOrigin), selection=\(editor.selectedRange()), characters=\(editor.string.utf16.count)"
            XCTAssertGreaterThan(measured.rect.height, 0, diagnostic)
            XCTAssertTrue(measured.rect.minX.isFinite && measured.rect.minY.isFinite, diagnostic)
            XCTAssertGreaterThan(viewport.minX, editor.bounds.minX, "Must exercise actual horizontal scrolling: \(diagnostic)")
            XCTAssertGreaterThanOrEqual(measured.rect.minX, viewport.minX - 0.5, diagnostic)
            XCTAssertLessThanOrEqual(measured.rect.maxX, viewport.maxX + 0.5, diagnostic)
            XCTAssertGreaterThanOrEqual(measured.rect.minY, viewport.minY - 0.5, diagnostic)
            XCTAssertLessThanOrEqual(measured.rect.maxY, viewport.maxY + 0.5, diagnostic)
            // The cell's native clip has measured outsets beyond the control.
            // Bound both real regions inside glass; do not invent a clip width.
            for region in [input, visibleInput] {
                XCTAssertGreaterThanOrEqual(region.minX, content.bounds.minX, diagnostic)
                XCTAssertLessThanOrEqual(region.maxX, content.bounds.maxX, diagnostic)
            }
            let baseline = content.convert(NSPoint(x: 0, y: measured.baseline), from: editor).y
            XCTAssertEqual(baseline - (editor.font?.capHeight ?? 0) / 2, 32, accuracy: 0.5, diagnostic)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(editor.selectedRange(), NSRange(location: text.utf16.count, length: 0))
            XCTAssertTrue(palette.field.currentEditor() === editor)
            XCTAssertFalse(editor.hasMarkedText())
        }
        fixture.browser.showCommandPalette()
        _ = try await waitForOpen(fixture, mode: .newDestination)
        XCTAssertEqual(editor.string, "")
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await waitFor("long new-destination input") { palette.typedText == text }
        fixture.browser.showCommandPalette()
        _ = try await waitForOpen(fixture, mode: .newDestination)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        editor.insertText("short", replacementRange: editor.selectedRange())
        try await waitFor("short native input") { palette.typedText == "short" }
        palette.layoutPresentation()
        let start = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        XCTAssertGreaterThan(start.height, 0)
        let content = try XCTUnwrap(palette.glass?.contentView)
        let leading = content.convert(fixture.window.convertFromScreen(start), from: nil).minX
        XCTAssertEqual(leading, CommandPaletteLayout.textX, accuracy: 0.5)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
        XCTAssertTrue(fixture.source.webView === view)
    }

    func testConsumingOwnClosedRequestDoesNotCancelDeferredExactPageFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let browser = fixture.browser
        let originalSpace = browser.activeSpaceID
        _ = try browser.createSpace(title: "Deferred Focus Space")
        let target = try XCTUnwrap(browser.activeTab)
        try await loadLocalHTML(target, baseURL: URL(string: "http://127.0.0.1:9/Deferred")!)
        let targetView = try XCTUnwrap(target.webView)
        let revision = target.navigationRevision
        XCTAssertTrue(browser.selectSpace(originalSpace))
        try await waitFor("inactive destination detached") { targetView.window == nil }
        browser.showCommandPalette()
        let palette = try await waitForOpen(fixture, mode: .newDestination)
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        editor.insertText("Retained Page", replacementRange: editor.selectedRange())
        try await waitFor("exact inactive target result") {
            if case .switchTab(let destination) = palette.results.first?.action { return destination.id == target.id }
            return false
        }
        let ids = browser.allTabs.map(\.id)
        palette.perform(.submit)
        let closedRequest = browser.commandPaletteRequest
        XCTAssertFalse(palette.isPresented)
        XCTAssertFalse(browser.commandPaletteWantsPresentation)
        XCTAssertNil(targetView.window, "No actor suspension yet: the exact destination focus must still be deferred")
        let anchor = try XCTUnwrap(palette.anchor as? CommandPaletteAnchor)
        anchor.applyRequest() // Same production consumer, before the pending focus task can run.
        XCTAssertEqual(anchor.applied, closedRequest)
        try await waitFor("deferred exact native destination focus") {
            targetView.window === fixture.window && fixture.window.firstResponder === targetView
        }
        XCTAssertTrue(browser.focusedPage === target)
        XCTAssertEqual(browser.allTabs.map(\.id), ids)
        XCTAssertTrue(target.webView === targetView)
        XCTAssertEqual(target.navigationRevision, revision)
    }

    func testSaturatedExtensionlessFilePrefillKeepsCurrentSourceAndExplicitSearch() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        // Supplied HTML with a logical file base. This grants no filesystem access.
        let url = URL(string: "file:///CommandBarFixture/PrivateNotes")!
        let page = fixture.browser.openPeek(from: fixture.source)
        try await loadLocalHTML(page, baseURL: url)
        try await waitFor("saturated file Peek") { page.webView?.window === fixture.window }
        for index in 1...7 {
            fixture.bookmarks.toggle(title: "Matching Bookmark \(index)", url: URL(string: url.absoluteString + String(index))!)
        }
        let generic = AddressResults.results(for: url.absoluteString, browser: fixture.browser,
                                             bookmarks: fixture.bookmarks.bookmarks, includesTypedAddress: true)
        XCTAssertEqual(generic.count, 8)
        XCTAssertEqual(generic.filter { if case .openURL = $0.action { true } else { false } }.count, 7)
        let palette = try await toggleOpen(fixture)
        XCTAssertEqual(palette.results.count, 8)
        XCTAssertEqual(palette.results.first?.action, .navigate(url))
        XCTAssertEqual(palette.results.filter { if case .openURL = $0.action { true } else { false } }.count, 6)
        guard case .search(let query) = palette.results.last?.action else { return XCTFail("Reserved Search must survive current-source insertion") }
        XCTAssertEqual(query, url.absoluteString)
        XCTAssertEqual(palette.table.selectedRow, 0)
        let revision = page.navigationRevision
        let view = page.webView
        let peekID = fixture.browser.peek?.id
        palette.perform(.submit)
        XCTAssertEqual(page.url, url)
        XCTAssertEqual(page.navigationRevision, revision)
        XCTAssertTrue(page.webView === view)
        XCTAssertEqual(fixture.browser.peek?.id, peekID)
        XCTAssertTrue(fixture.browser.focusedPage === page)
        XCTAssertEqual(fixture.browser.allTabs.count, 1)
    }

    func testUneditedInitialSourceRejectsStaleRevisionAndReplacedIdentity() async throws {
        for replace in [false, true] {
            let fixture = try await fixture()
            defer { fixture.close() }
            let browser = fixture.browser
            let palette = try await toggleOpen(fixture)
            XCTAssertEqual(palette.results.first?.action, .navigate(try XCTUnwrap(fixture.source.url)))
            if replace {
                browser.restoreSession(WindowSession(tabs: [TabSession(url: nil, title: "", interactionState: nil, id: fixture.source.id)], selectedIndex: 0))
                XCTAssertFalse(browser.activeTab === fixture.source)
            } else { fixture.source.invalidateNavigation() }
            let target = browser.focusedPage
            let urls = browser.allTabs.map(\.url)
            let revisions = browser.allTabs.map(\.navigationRevision)
            let ids = browser.allTabs.map(\.id)
            let selectedID = browser.activeTabID
            let spaceID = browser.activeSpaceID
            palette.perform(.submit)
            XCTAssertFalse(palette.isPresented)
            XCTAssertTrue(browser.focusedPage === target)
            XCTAssertEqual(browser.allTabs.map(\.id), ids)
            XCTAssertEqual(browser.allTabs.map(\.url), urls)
            XCTAssertEqual(browser.allTabs.map(\.navigationRevision), revisions)
            XCTAssertEqual(browser.activeTabID, selectedID)
            XCTAssertEqual(browser.activeSpaceID, spaceID)
            if replace { XCTAssertNil(target?.webView) }
        }
    }

    /// TextKit's primary insertion position is valid without an active input
    /// context. Positions are native offsets in the line fragment (SDK contract),
    /// not a glyph-ink estimate or an empty firstRect converted from screen zero.
    private func nativeInsertion(in editor: NSTextView) throws -> (rect: NSRect, baseline: CGFloat) {
        let selection = editor.selectedRange()
        XCTAssertEqual(selection.length, 0)
        XCTAssertGreaterThan(selection.location, 0)
        XCTAssertLessThanOrEqual(selection.location, editor.string.utf16.count)
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let character = selection.location - 1
        let count = layout.getLineFragmentInsertionPoints(forCharacterAt: character, alternatePositions: false,
                                                         inDisplayOrder: false, positions: nil, characterIndexes: nil)
        XCTAssertGreaterThan(count, 0)
        var positions = [CGFloat](repeating: 0, count: count)
        var indexes = [Int](repeating: 0, count: count)
        let returned = positions.withUnsafeMutableBufferPointer { positions in
            indexes.withUnsafeMutableBufferPointer { indexes in
                layout.getLineFragmentInsertionPoints(forCharacterAt: character, alternatePositions: false,
                    inDisplayOrder: false, positions: positions.baseAddress, characterIndexes: indexes.baseAddress)
            }
        }
        XCTAssertEqual(returned, count)
        let index = try XCTUnwrap(indexes.firstIndex(of: selection.location))
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
        XCTAssertGreaterThan(glyph.length, 0)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph.location, effectiveRange: nil)
        let origin = editor.textContainerOrigin
        let rect = NSRect(x: origin.x + fragment.minX + positions[index], y: origin.y + fragment.minY,
                          width: 0, height: fragment.height)
        XCTAssertGreaterThan(rect.height, 0)
        return (rect, rect.minY + layout.location(forGlyphAt: glyph.location).y)
    }

    private func fixture(isPrivate: Bool = false) async throws -> PaletteFixture {
        let fixture = try PaletteFixture(isPrivate: isPrivate)
        do {
            try await waitFor("hosted source") {
                fixture.browser.window === fixture.window && fixture.source.webView?.window === fixture.window
                    && fixture.source.pageTitle == "Palette Source" && fixture.browser.commandPalette?.anchor?.window === fixture.window
            }
            return fixture
        } catch { fixture.close(); throw error }
    }

    private func loadLocalHTML(_ page: BrowserTab, baseURL: URL) async throws {
        if page.webView == nil {
            page.load(URL(string: "about:blank")!)
            try await waitFor("local blank view") { page.url?.absoluteString == "about:blank" && !page.isLoading }
        }
        page.webView?.loadHTMLString("<title>Retained Page</title><p>Local HTML</p>", baseURL: baseURL)
        try await waitFor("local base URL") { page.url == baseURL && !page.isLoading && page.pageTitle == "Retained Page" }
    }

    private func setDocumentState(in view: WKWebView) async throws {
        _ = try await view.evaluateJavaScript("window.arcState = 'retained'; document.body.innerHTML = '<input id=retained>'; var input = document.getElementById('retained'); input.value = 'private unsaved text'; input.focus(); input.setSelectionRange(4, 7);")
    }

    private func documentState(in view: WKWebView) async throws -> String? {
        try await view.evaluateJavaScript("window.arcState + '|' + document.getElementById('retained').value + '|' + document.getElementById('retained').selectionStart + '|' + document.getElementById('retained').selectionEnd") as? String
    }

    private func responderOwner(in window: NSWindow) -> NSResponder? {
        ((window.firstResponder as? NSTextView)?.delegate as? NSResponder) ?? window.firstResponder
    }

    private func toggleOpen(_ fixture: PaletteFixture) async throws -> CommandPaletteController {
        XCTAssertFalse(fixture.browser.commandPaletteWantsPresentation)
        XCTAssertFalse(fixture.browser.commandPalette?.isPresented == true)
        fixture.browser.toggleCommandPalette()
        return try await waitForOpen(fixture, mode: .editCurrentDestination)
    }

    private func waitForOpen(_ fixture: PaletteFixture, mode: CommandPaletteMode) async throws -> CommandPaletteController {
        let request = fixture.browser.commandPaletteRequest
        try await waitFor("applied palette request") {
            guard let palette = fixture.browser.commandPalette, let anchor = palette.anchor as? CommandPaletteAnchor else { return false }
            return anchor.applied == request && palette.isPresented && palette.mode == mode && palette.field.currentEditor() != nil
        }
        await nextTurn()
        return try XCTUnwrap(fixture.browser.commandPalette)
    }

    private func nextTurn() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func waitFor(_ name: String, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for \(name)"); throw PrefillFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum PrefillFailure: Error { case timeout }

@MainActor
private final class PrefillNavigationProbe: NSObject, WKNavigationDelegate {
    var requests: [URL] = []
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if let url = navigationAction.request.url { requests.append(url) }
        return .cancel // No fixture action can issue an external request.
    }
}
