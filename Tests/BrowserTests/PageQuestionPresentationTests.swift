import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class PageQuestionPresentationTests: XCTestCase {
    func testResponsiveGeometryAnchorsCompactFindAndBoundsExpandedCard() {
        for available in [CGSize(width: 1000, height: 700), CGSize(width: 250, height: 220), CGSize(width: 140, height: 90)] {
            let compact = PageFindGeometry(available: available, contentHeight: 34)
            let expanded = PageFindGeometry(available: available, contentHeight: 2000)
            XCTAssertEqual(compact.frame.height, 34)
            XCTAssertLessThanOrEqual(expanded.frame.width, 400)
            XCTAssertLessThanOrEqual(expanded.frame.width, max(240, available.width * 0.55))
            XCTAssertLessThanOrEqual(expanded.frame.height, available.height * 0.65)
            XCTAssertLessThanOrEqual(expanded.frame.height, available.height - 20)
            XCTAssertLessThanOrEqual(expanded.frame.height, 480)
            XCTAssertEqual(expanded.frame.maxX, available.width - 10)
            XCTAssertEqual(expanded.frame.minY, 10)
            XCTAssertLessThan(compact.frame.height, expanded.frame.height)
        }
        XCTAssertTrue(PageFindGeometry(available: .zero, contentHeight: 400).frame.isEmpty)
    }

    func testFindPrefillsOneControllerAndTypingAndReturnDoNotStartInference() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.tab.findText = "museum"
        fixture.browser.showPageQuestion()
        let initial = try XCTUnwrap(fixture.browser.pageQuestion)
        XCTAssertEqual(initial.question, "museum")
        XCTAssertNil(initial.snapshot)
        XCTAssertFalse(initial.isWorking)
        fixture.browser.showPageQuestion()
        XCTAssertTrue(fixture.browser.pageQuestion === initial)
        let calls = PresentationCalls()
        let controller = fixture.install(provider: { _, _ in
            await calls.called()
            return PageAnswer(answer: "09:00", evidenceIDs: [1], insufficientEvidence: false)
        })
        try await wait(fixture) { fixture.findEditor != nil }
        let editor = try XCTUnwrap(fixture.findEditor)
        editor.selectAll(nil)
        editor.insertText("09:00", replacementRange: editor.selectedRange())
        try await wait(fixture) { fixture.tab.findText == "09:00" && controller.question == "09:00" }
        fixture.browser.findNext()
        try await wait(fixture) { await fixture.tab.selectedText() == "09:00" }
        let selected = try await fixture.webView.evaluateJavaScript("getSelection().toString()", contentWorld: .page) as? String
        XCTAssertEqual(selected, "09:00")
        let field = try XCTUnwrap(fixture.findField)
        let coordinator = try XCTUnwrap(field.delegate as? FindTextField.Coordinator)
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        let beforeAsk = await calls.count
        XCTAssertEqual(beforeAsk, 0)
        XCTAssertNil(controller.snapshot)
        fixture.browser.askOnPageFromFind()
        try await wait(fixture) { controller.answer == "09:00" }
        let afterAsk = await calls.count
        XCTAssertEqual(afterAsk, 1)
    }

    func testNativeRegularGlassExpandsOverVisiblePageAndShrinksAfterInvalidation() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.browser.showFindBar()
        try await wait(fixture) { fixture.surface?.glass.frame.height == 34 }
        let surface = try XCTUnwrap(fixture.surface)
        XCTAssertEqual(surface.glass.style, .regular)
        XCTAssertTrue(surface.glass.window === fixture.window)
        XCTAssertTrue(fixture.webView.window === fixture.window)
        XCTAssertNil(fixture.window.attachedSheet)
        XCTAssertNil(fixture.window.sheetParent)
        let gate = PresentationAnswerGate()
        let controller = fixture.install(provider: { _, _ in try await gate.answer() })
        fixture.tab.findText = "When does the museum open?"
        fixture.browser.findTextDidChange(in: fixture.tab)
        fixture.browser.askOnPageFromFind()
        try await wait(fixture) { controller.isWorking && surface.glass.frame.height > 34 }
        XCTAssertTrue(fixture.surface === surface)
        try await wait(fixture) { await gate.isWaiting }
        await gate.finish()
        try await wait(fixture) { controller.answer != nil && surface.glass.frame.height > 150 }
        XCTAssertTrue(fixture.surface === surface)
        XCTAssertLessThanOrEqual(surface.glass.frame.height, min(480, surface.bounds.height - 20))
        XCTAssertEqual(surface.glass.frame.maxX, surface.bounds.width - 10, accuracy: 1)
        // Outside the native card must remain a live, interactive webpage.
        XCTAssertNil(surface.hitTest(surface.convert(NSPoint(x: 10, y: surface.bounds.midY), to: surface.superview)))
        fixture.window.setContentSize(NSSize(width: 280, height: 240))
        try await wait(fixture) { surface.bounds.width < 300 && surface.glass.frame.width < 300 }
        XCTAssertLessThanOrEqual(surface.glass.frame.maxY, surface.bounds.height)
        XCTAssertLessThanOrEqual(surface.glass.frame.maxX, surface.bounds.width)
        fixture.tab.webView?.loadHTMLString("<title>New document</title><p>New page</p>", baseURL: nil)
        try await wait(fixture) { fixture.browser.pageQuestion == nil && surface.glass.frame.height == 34 }
        XCTAssertNil(controller.answer)
        XCTAssertNil(controller.snapshot)
    }

    func testRevealKeepsAnswerAndNativeFocusThenPageAndFindCanBeReentered() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.tab.findText = "museum"
        fixture.browser.showPageQuestion()
        let controller = fixture.install(provider: { _, _ in
            PageAnswer(answer: "09:00", evidenceIDs: [1], insufficientEvidence: false)
        })
        fixture.browser.askOnPageFromFind()
        try await wait(fixture) { controller.answer != nil && fixture.findEditor != nil }
        let responder = fixture.window.firstResponder
        let snapshot = controller.snapshot?.token
        let block = try XCTUnwrap(controller.excerpts.first)
        let revealed = await controller.reveal(block)
        XCTAssertTrue(revealed)
        let selection = try await fixture.webView.evaluateJavaScript("getSelection().toString()", contentWorld: .page) as? String
        XCTAssertEqual(selection, block.text)
        XCTAssertTrue(fixture.window.firstResponder === responder)
        XCTAssertTrue(fixture.browser.pageQuestion === controller)
        XCTAssertEqual(controller.answer, "09:00")
        XCTAssertEqual(controller.snapshot?.token, snapshot)
        XCTAssertTrue(fixture.tab.isFindBarVisible)
        fixture.browser.returnToPageFromQuestion(controller)
        XCTAssertTrue(fixture.pageOwnsFocus)
        XCTAssertTrue(fixture.browser.pageQuestion === controller)
        fixture.browser.showFindBar()
        try await wait(fixture) { fixture.findEditor != nil }
        XCTAssertTrue(fixture.browser.pageQuestion === controller)
        XCTAssertEqual(controller.answer, "09:00")
        fixture.browser.dismissPageQuestion()
        fixture.browser.showPageQuestion()
        try await wait(fixture) { fixture.findEditor != nil }
        let newerResponder = fixture.window.firstResponder
        fixture.browser.returnToPageFromQuestion(controller)
        XCTAssertTrue(fixture.window.firstResponder === newerResponder)
        XCTAssertFalse(fixture.pageOwnsFocus)
    }

    func testEscapeIsWindowAndFocusLocalAndDoesNotConsumeIMEComposition() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.browser.showPageQuestion()
        try await wait(fixture) { fixture.findEditor != nil }
        let surface = try XCTUnwrap(fixture.surface)
        let editor = try XCTUnwrap(fixture.findEditor)
        let event = try XCTUnwrap(escape(in: fixture.window))
        editor.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(surface.handleEscape(event))
        XCTAssertNotNil(fixture.browser.pageQuestion)
        editor.unmarkText()
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        XCTAssertFalse(surface.handleEscape(try XCTUnwrap(escape(in: otherWindow))))
        XCTAssertNotNil(fixture.browser.pageQuestion)
        XCTAssertTrue(surface.handleEscape(event))
        XCTAssertNil(fixture.browser.pageQuestion)
        XCTAssertFalse(fixture.tab.isFindBarVisible)
        XCTAssertTrue(fixture.pageOwnsFocus)
        fixture.browser.showPageQuestion()
        try await wait(fixture) { fixture.findEditor != nil }
        let currentSurface = try XCTUnwrap(fixture.surface)
        let outside = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
        fixture.window.contentView?.addSubview(outside)
        XCTAssertTrue(fixture.window.makeFirstResponder(outside))
        XCTAssertFalse(currentSurface.handleEscape(event))
        XCTAssertNotNil(fixture.browser.pageQuestion)
    }

    func testIMEFindEditCommitsNormallyWithoutAskOrPrematureReturn() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.tab.findText = "museum"
        fixture.browser.showPageQuestion()
        let calls = PresentationCalls()
        let controller = fixture.install(provider: { _, _ in
            await calls.called()
            return PageAnswer(answer: "09:00", evidenceIDs: [1], insufficientEvidence: false)
        })
        try await wait(fixture) { fixture.findEditor != nil }
        let field = try XCTUnwrap(fixture.findField)
        let editor = try XCTUnwrap(fixture.findEditor)
        let coordinator = try XCTUnwrap(field.delegate as? FindTextField.Coordinator)
        editor.selectAll(nil)
        editor.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(fixture.tab.findText, "museum")
        XCTAssertEqual(controller.question, "museum")
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        fixture.browser.askOnPageFromFind()
        XCTAssertFalse(controller.isWorking)
        editor.unmarkText()
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await wait(fixture) { fixture.tab.findText == "東京" && controller.question == "東京" }
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(controller.snapshot)
    }

    func testCompositionCancelsPendingAnswerWithoutReplacingCommittedFindText() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.tab.findText = "museum"
        fixture.browser.showPageQuestion()
        let gate = PresentationAnswerGate()
        let controller = fixture.install(provider: { _, _ in try await gate.answer() })
        try await wait(fixture) { fixture.findEditor != nil }
        fixture.browser.askOnPageFromFind()
        try await wait(fixture) { await gate.isWaiting }
        XCTAssertTrue(controller.isWorking)
        let field = try XCTUnwrap(fixture.findField)
        let editor = try XCTUnwrap(fixture.findEditor)
        let coordinator = try XCTUnwrap(field.delegate as? FindTextField.Coordinator)
        editor.selectAll(nil)
        editor.setMarkedText("東京", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertFalse(controller.isWorking)
        XCTAssertNil(controller.snapshot)
        XCTAssertNil(controller.answer)
        XCTAssertEqual(fixture.tab.findText, "museum")
        XCTAssertEqual(controller.question, "museum")
        XCTAssertTrue(fixture.window.firstResponder === editor)
        fixture.browser.askOnPageFromFind()
        XCTAssertFalse(controller.isWorking)
        await gate.finish()
        try await wait(fixture) { await gate.completed }
        await Task.yield()
        XCTAssertNil(controller.answer)
        XCTAssertTrue(fixture.browser.pageQuestion === controller)
        editor.unmarkText()
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await wait(fixture) { fixture.tab.findText == "東京" && controller.question == "東京" }
        XCTAssertFalse(controller.isWorking)
    }

    func testDeferredFindFocusDoesNotOverrideANewerResponderOrHiddenSurface() async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.browser.showPageQuestion()
        try await wait(fixture) { fixture.findEditor != nil }
        let field = try XCTUnwrap(fixture.findField as? FindField)
        let outside = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 25))
        fixture.window.contentView?.addSubview(outside)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.webView))
        field.requestFocus(1000)
        XCTAssertTrue(fixture.window.makeFirstResponder(outside))
        let newerResponder = fixture.window.firstResponder
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fixture.window.firstResponder === newerResponder)
        fixture.tab.isFindBarVisible = false
        field.requestFocus(1001)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(fixture.window.firstResponder === newerResponder)
    }

    func testPageEscapePassesNonTextViewMarkedClientThenClosesOnlyFind() async throws {
        try await checkPageComposition(useInputContext: false)
    }

    func testPageEscapePassesInputContextMarkedClientThenClosesOnlyFind() async throws {
        try await checkPageComposition(useInputContext: true)
    }

    private func checkPageComposition(useInputContext: Bool) async throws {
        let fixture = try PresentationFixture()
        defer { fixture.close() }
        try await ready(fixture)
        fixture.tab.findText = "museum"
        fixture.browser.showPageQuestion()
        let controller = fixture.install(provider: { _, _ in
            PageAnswer(answer: "09:00", evidenceIDs: [1], insufficientEvidence: false)
        })
        fixture.browser.askOnPageFromFind()
        try await wait(fixture) { controller.answer != nil && fixture.findEditor != nil }
        let surface = try XCTUnwrap(fixture.surface)
        let token = controller.snapshot?.token
        let tabIDs = fixture.browser.tabs.map(\.id)
        let client = MarkedClientView(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
        let focused: NSView
        if useInputContext { focused = InputContextProxyView(client: client) }
        else { focused = client }
        fixture.webView.addSubview(focused)
        XCTAssertTrue(focused.isDescendant(of: fixture.webView))
        XCTAssertTrue(fixture.window.makeFirstResponder(focused))
        client.marked = true
        XCTAssertFalse(fixture.window.firstResponder is NSTextView)
        if useInputContext {
            XCTAssertFalse(focused is any NSTextInputClient)
            XCTAssertTrue(focused.inputContext?.client === client)
        }
        XCTAssertTrue(FocusedTextInput.hasMarkedText(fixture.window.firstResponder))
        let event = try XCTUnwrap(escape(in: fixture.window))
        XCTAssertFalse(surface.handleEscape(event))
        XCTAssertTrue(client.marked)
        XCTAssertEqual(client.unmarkCount, 0)
        XCTAssertTrue(fixture.window.firstResponder === focused)
        XCTAssertTrue(fixture.browser.pageQuestion === controller)
        XCTAssertTrue(fixture.tab.isFindBarVisible)
        XCTAssertEqual(controller.answer, "09:00")
        XCTAssertEqual(controller.snapshot?.token, token)
        fixture.browser.askOnPageFromFind()
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.answer, "09:00")
        // The input client, not the Escape monitor, owns composition cancellation.
        client.unmarkText()
        XCTAssertFalse(FocusedTextInput.hasMarkedText(fixture.window.firstResponder))
        XCTAssertTrue(surface.handleEscape(event))
        XCTAssertNil(fixture.browser.pageQuestion)
        XCTAssertFalse(fixture.tab.isFindBarVisible)
        XCTAssertNil(controller.answer)
        XCTAssertTrue(fixture.pageOwnsFocus)
        XCTAssertEqual(fixture.browser.tabs.map(\.id), tabIDs)
        XCTAssertEqual(fixture.browser.activeTabID, fixture.tab.id)
        XCTAssertFalse(surface.handleEscape(event))
    }

    func testPeekFallbackPassesPageCompositionAndUnmarkedEscapeClosesOnlyPeek() async throws {
        for useInputContext in [false, true] {
            let fixture = try PresentationFixture()
            defer { fixture.close() }
            try await ready(fixture)
            let peek = fixture.browser.openPeek(from: fixture.tab)
            let view = try XCTUnwrap(peek.webView)
            let root = try XCTUnwrap(fixture.window.contentView)
            peek.contentView.frame = root.bounds
            peek.contentView.autoresizingMask = [.width, .height]
            root.addSubview(peek.contentView)
            let fallback = PeekEscapeHandler.EscapeView()
            fallback.browser = fixture.browser
            root.addSubview(fallback)
            view.loadHTMLString("<title>IME Peek fixture</title><p>Peek source</p>", baseURL: nil)
            try await wait(fixture) { !peek.isLoading && peek.pageTitle == "IME Peek fixture" && view.window === fixture.window }
            let client = MarkedClientView(frame: NSRect(x: 10, y: 10, width: 120, height: 24))
            let focused: NSView = useInputContext ? InputContextProxyView(client: client) : client
            view.addSubview(focused)
            XCTAssertTrue(fixture.window.makeFirstResponder(focused))
            client.marked = true
            let event = try XCTUnwrap(escape(in: fixture.window))
            XCTAssertFalse(fallback.handleEscape(event))
            XCTAssertTrue(fixture.browser.peek?.tab === peek)
            XCTAssertTrue(client.marked)
            XCTAssertEqual(client.unmarkCount, 0)
            XCTAssertTrue(fixture.window.firstResponder === focused)
            client.unmarkText()
            // Find owns the first unmarked Escape when it is present in Peek.
            peek.isFindBarVisible = true
            XCTAssertFalse(fallback.handleEscape(event))
            XCTAssertTrue(fixture.browser.peek?.tab === peek)
            XCTAssertTrue(peek.isFindBarVisible)
            peek.isFindBarVisible = false
            XCTAssertTrue(fallback.handleEscape(event))
            XCTAssertNil(fixture.browser.peek)
            XCTAssertEqual(fixture.browser.tabs.map(\.id), [fixture.tab.id])
            XCTAssertEqual(fixture.browser.activeTabID, fixture.tab.id)
            XCTAssertFalse(fallback.handleEscape(event))
        }
    }

    func testFocusedTextInputChecksContextEvenWhenDirectClientIsUnmarked() {
        XCTAssertFalse(FocusedTextInput.hasMarkedText(nil))
        XCTAssertFalse(FocusedTextInput.hasMarkedText(NSResponder()))
        let direct = MarkedClientView()
        let contextClient = MarkedClientView()
        direct.suppliedContext = NSTextInputContext(client: contextClient)
        contextClient.marked = true
        XCTAssertFalse(direct.hasMarkedText())
        XCTAssertTrue(FocusedTextInput.hasMarkedText(direct))
        contextClient.marked = false
        XCTAssertFalse(FocusedTextInput.hasMarkedText(direct))
        direct.marked = true
        XCTAssertTrue(FocusedTextInput.hasMarkedText(direct))
        XCTAssertEqual(direct.unmarkCount, 0)
        XCTAssertEqual(contextClient.unmarkCount, 0)
    }

    private func ready(_ fixture: PresentationFixture) async throws {
        try await wait(fixture) { fixture.webView.window === fixture.window && !fixture.tab.isLoading && fixture.tab.pageTitle == "Presentation fixture" }
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.webView))
    }
    private func wait(_ fixture: PresentationFixture, file: StaticString = #filePath, line: UInt = #line,
                      _ predicate: () async -> Bool) async throws {
        for _ in 0..<300 {
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("Presentation fixture timed out: page=\(fixture.tab.pageTitle), attached=\(fixture.webView.window === fixture.window), Find=\(fixture.tab.isFindBarVisible), surface=\(fixture.surface != nil), bounds=\(fixture.surface?.bounds ?? .zero), height=\(fixture.surface?.glass.frame.height ?? -1), field=\(fixture.findField != nil), editor=\(fixture.findEditor != nil)", file: file, line: line)
        throw IntelligenceError.message("Presentation fixture timed out")
    }
    private func escape(in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)
    }
}

@MainActor
private final class PresentationFixture {
    let browser = BrowserModel(isPrivate: true)
    let tab: BrowserTab
    let webView: WKWebView
    let window: NSWindow
    init() throws {
        tab = try XCTUnwrap(browser.activeTab)
        tab.load(URL(string: "about:blank")!)
        webView = try XCTUnwrap(tab.webView)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: FixturePage(tab: tab, browser: browser))
        host.sizingOptions = []
        // Outside controls used by focus tests are siblings of the hosting view,
        // not unsupported direct additions to NSHostingController.view.
        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 600))
        container.addChild(host)
        host.view.frame = container.view.bounds
        host.view.autoresizingMask = [.width, .height]
        container.view.addSubview(host.view)
        window.contentViewController = container
        window.setContentSize(NSSize(width: 850, height: 600))
        // SwiftUI defers layout for hidden windows. This is an XCTest fixture,
        // not an installed browser/GUI QA launch or a visual-parity check.
        if let laptop = NSScreen.screens.first(where: { $0.localizedName.contains("Built-in") }) {
            window.setFrameOrigin(NSPoint(x: laptop.visibleFrame.minX + 30, y: laptop.visibleFrame.minY + 30))
        }
        window.orderFront(nil)
        webView.loadHTMLString("<title>Presentation fixture</title><main><p>The museum opens at 09:00.</p><p>Entry costs €8.</p></main>", baseURL: URL(string: "https://fixture.invalid/page"))
    }
    var surface: PageFindSurfaceView? { descendant(window.contentView) }
    var findField: NSTextField? {
        func find(_ view: NSView?) -> NSTextField? {
            guard let view else { return nil }
            if let field = view as? NSTextField, field.placeholderString == "Find on Page" { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(window.contentView)
    }
    var findEditor: NSTextView? {
        guard let editor = findField?.currentEditor() as? NSTextView, window.firstResponder === editor else { return nil }
        return editor
    }
    var pageOwnsFocus: Bool { window.firstResponder === webView || (window.firstResponder as? NSView)?.isDescendant(of: webView) == true }
    func install(provider: @escaping PageQuestionController.Provider) -> PageQuestionController {
        browser.pageQuestion?.close(restoreFocus: false)
        let controller = PageQuestionController(tab: tab, browser: browser, provider: provider)
        controller.question = tab.findText
        browser.pageQuestion = controller
        return controller
    }
    func close() {
        browser.windowDidClose()
        window.close()
    }
    private func descendant<T: NSView>(_ view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant($0) }.first
    }
}

private struct FixturePage: View {
    @Bindable var tab: BrowserTab
    @Bindable var browser: BrowserModel
    var body: some View {
        PageHost(content: tab.contentView)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if tab.isFindBarVisible, browser.focusedPage === tab {
                    PageFindSurface(tab: tab, browser: browser)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

/// Deterministic protocol clients exercise Escape routing only. They do not
/// simulate a physical IME or establish WebKit's native event delivery behavior.
@MainActor
private final class MarkedClientView: NSView, @MainActor NSTextInputClient {
    var marked = false
    var suppliedContext: NSTextInputContext?
    private(set) var unmarkCount = 0
    override var acceptsFirstResponder: Bool { true }
    override var inputContext: NSTextInputContext? { suppliedContext ?? super.inputContext }
    func hasMarkedText() -> Bool { marked }
    func markedRange() -> NSRange { NSRange(location: marked ? 0 : NSNotFound, length: marked ? 1 : 0) }
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) { marked = true }
    func unmarkText() { marked = false; unmarkCount += 1 }
    func insertText(_ string: Any, replacementRange: NSRange) { marked = false }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
}

@MainActor
private final class InputContextProxyView: NSView {
    let client: MarkedClientView
    private lazy var context = NSTextInputContext(client: client)
    override var acceptsFirstResponder: Bool { true }
    override var inputContext: NSTextInputContext? { context }
    init(client: MarkedClientView) {
        self.client = client
        super.init(frame: client.frame)
        addSubview(client)
    }
    required init?(coder: NSCoder) { return nil }
}

private actor PresentationCalls {
    private(set) var count = 0
    func called() { count += 1 }
}

private actor PresentationAnswerGate {
    private var waiter: CheckedContinuation<PageAnswer, any Error>?
    var isWaiting: Bool { waiter != nil }
    private(set) var completed = false
    func answer() async throws -> PageAnswer {
        let answer = try await withCheckedThrowingContinuation { waiter = $0 }
        completed = true
        return answer
    }
    func finish() {
        waiter?.resume(returning: PageAnswer(answer: "09:00", evidenceIDs: [1], insufficientEvidence: false))
        waiter = nil
    }
}
