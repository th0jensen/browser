import XCTest
import AppKit
import WebKit
@testable import Browser

@MainActor
final class LinkPreviewPresentationTests: XCTestCase {
    func testPreviewShowsShimmerThenCascadesContentInPlace() async throws {
        let partialGate = PreviewTestGate()
        let finalGate = PreviewTestGate()
        let partial = LinkSummary(title: "Loading", summary: "Useful partial preview content is ready.")
        let final = LinkSummary(
            title: "Ready", summary: "Complete useful preview content is ready.", keyPoints: ["One fact."])
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, streamingSummaryProvider: { _, update in
                await partialGate.wait()
                await update(partial)
                await finalGate.wait()
                return final
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Streaming preview fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }

        let sourceResponder = fixture.window.firstResponder
        await postPreviewMessage(path: "ready", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preparation = try XCTUnwrap(controller.current)
        let glass = try XCTUnwrap(preparation.glass)
        XCTAssertNotNil(controller.presentedPreview)
        XCTAssertTrue(preparation.state.isLoading)
        XCTAssertNil(preparation.state.result)
        XCTAssertEqual(glass.style, .regular)
        XCTAssertNil(preparation.panel)
        XCTAssertFalse(preparation.state.isKept)
        XCTAssertTrue(fixture.window.firstResponder === sourceResponder)

        await partialGate.open()
        try await waitUntil { controller.presentedPreview?.result?.title == "Loading" }
        XCTAssertTrue(preparation.glass === glass)
        XCTAssertTrue(preparation.state.isLoading)
        XCTAssertTrue(controller.current === preparation)

        await finalGate.open()
        try await waitUntil { controller.presentedPreview?.result?.title == "Ready" }
        XCTAssertTrue(preparation.glass === glass)
        XCTAssertFalse(preparation.state.isLoading)
        XCTAssertEqual(controller.presentedPreview?.result?.summary, final.summary)
        XCTAssertTrue(fixture.window.firstResponder === sourceResponder)
    }

    func testLeavingLinkCancelsLoadingPreviewBeforeResultCompletes() async throws {
        let resultGate = PreviewTestGate()
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, summaryProvider: { _ in
                await resultGate.wait()
                return LinkSummary(title: "Stale", summary: "This must never appear.")
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Cancelled preview fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }

        await postPreviewMessage(path: "stale", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preparation = try XCTUnwrap(controller.current)
        await postPreviewLeave(to: fixture.view)
        try await waitUntil { controller.current == nil }
        await resultGate.open()
        await Task.yield()
        XCTAssertTrue(preparation.isClosed)
        XCTAssertNil(controller.presentedPreview)
        XCTAssertNil(preparation.glass)
    }

    func testEarlyRefusalStopsShimmerAndShowsUnavailableState() async throws {
        let failureGate = PreviewTestGate()
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, streamingSummaryProvider: { _, update in
                await failureGate.wait()
                await update(LinkSummary(title: "", summary: "I cannot summarize this page safely."))
                throw IntelligenceError.message("No preview")
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Failed preview fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }

        await postPreviewMessage(path: "failure", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preparation = try XCTUnwrap(controller.current)
        XCTAssertNotNil(controller.presentedPreview)
        XCTAssertTrue(preparation.state.isLoading)
        await failureGate.open()
        try await waitUntil { preparation.task == nil && !preparation.state.isLoading }
        XCTAssertTrue(controller.current === preparation)
        XCTAssertFalse(preparation.isClosed)
        XCTAssertNil(preparation.state.result)
        XCTAssertEqual(preparation.state.failure, .summaryFailed)
        XCTAssertEqual(preparation.state.error, LinkPreviewFailure.summaryFailed.message)
        XCTAssertNotNil(preparation.glass)
    }

    func testErrorAfterUsablePartialKeepsCascadedContentOnScreen() async throws {
        let partialGate = PreviewTestGate()
        let partial = LinkSummary(title: "Partial", summary: "Useful partial preview content is available.")
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, streamingSummaryProvider: { _, update in
                await partialGate.wait()
                await update(partial)
                throw IntelligenceError.message("Late generation failure")
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Late failure fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }

        await postPreviewMessage(path: "late-failure", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preparation = try XCTUnwrap(controller.current)
        XCTAssertNotNil(controller.presentedPreview)
        XCTAssertTrue(preparation.state.isLoading)
        await partialGate.open()
        try await waitUntil { preparation.task == nil }
        XCTAssertTrue(controller.current === preparation)
        XCTAssertFalse(preparation.isClosed)
        XCTAssertEqual(controller.presentedPreview?.result?.summary, partial.summary)
        XCTAssertFalse(preparation.state.isLoading)
        XCTAssertNil(preparation.state.error)
        XCTAssertNotNil(preparation.glass)
    }

    func testTimedOutPreviewStopsShimmerAndShowsUnavailableState() async throws {
        let deadlineGate = PreviewTestGate()
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, summaryProvider: { _ in
                try await Task.sleep(for: .seconds(30))
                return LinkSummary(title: "Late", summary: "This must never appear.")
            }, waitForPreparationDeadline: {
                await deadlineGate.wait()
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Timed out preview fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }

        await postPreviewMessage(path: "timeout", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preparation = try XCTUnwrap(controller.current)
        XCTAssertNotNil(controller.presentedPreview)
        XCTAssertTrue(preparation.state.isLoading)
        await deadlineGate.open()
        try await waitUntil { !preparation.state.isLoading }
        XCTAssertTrue(controller.current === preparation)
        XCTAssertFalse(preparation.isClosed)
        XCTAssertEqual(preparation.state.failure, .timedOut)
        XCTAssertEqual(preparation.state.error, LinkPreviewFailure.timedOut.message)
        XCTAssertNotNil(preparation.glass)
    }

    func testStaticFailuresKeepSameRichCardAndSourceLink() async throws {
        for failure in [LinkPreviewFailure.blocked, .loginRequired, .insufficientText, .unsupportedContent, .fetchFailed] {
            let gate = PreviewTestGate()
            let controller = LinkPreviewController(
                observesSettings: false, modifierFlags: { .shift }, summaryProvider: { _ in
                    await gate.wait()
                    throw failure
                })
            controller.setEnabled(true)
            let fixture = makeFixture(controller: controller, title: "Static outcome fixture")
            defer { controller.setEnabled(false); fixture.window.close() }
            try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }
            await postPreviewMessage(path: "source", to: fixture.view)
            try await waitUntil { controller.current != nil }
            let preview = try XCTUnwrap(controller.current)
            let glass = try XCTUnwrap(preview.glass)
            XCTAssertTrue(preview.state.isLoading)
            await gate.open()
            try await waitUntil { !preview.state.isLoading }
            XCTAssertEqual(preview.state.failure, failure)
            XCTAssertNil(preview.state.result)
            XCTAssertTrue(preview.glass === glass)
            XCTAssertNil(preview.panel)
            XCTAssertEqual(preview.state.contextText, failure.message + "\n\nhttps://example.com/source")
        }
    }

    func testTimeoutRejectsLateUpdateFromUncancelledCallback() async throws {
        let deadline = PreviewTestGate()
        let resultGate = PreviewTestGate()
        let returned = PreviewTestGate()
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, streamingSummaryProvider: { _, update in
                await resultGate.wait()
                let late = LinkSummary(title: "Late", summary: "Late callback must not replace the timeout.")
                await Task.detached { await update(late) }.value
                await returned.open()
                return late
            }, waitForPreparationDeadline: { await deadline.wait() })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Late callback fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }
        await postPreviewMessage(path: "late", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preview = try XCTUnwrap(controller.current)
        await deadline.open()
        try await waitUntil { !preview.state.isLoading }
        await resultGate.open()
        await returned.wait()
        XCTAssertNil(preview.state.result)
        XCTAssertEqual(preview.state.failure, .timedOut)
        XCTAssertNotNil(preview.glass)
    }

    func testDetachedLoadingNoteReceivesFailureAfterSourceNavigation() async throws {
        let failureGate = PreviewTestGate()
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, summaryProvider: { _ in
                await failureGate.wait()
                throw LinkPreviewFailure.blocked
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Detached failure fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }
        await postPreviewMessage(path: "detached-source", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let note = try XCTUnwrap(controller.current)
        let glass = try XCTUnwrap(note.glass)
        controller.keepPreview()
        let panel = try XCTUnwrap(note.panel)
        XCTAssertTrue(note.state.isLoading)
        XCTAssertTrue(note.state.isKept)
        XCTAssertNil(controller.current)

        controller.dismiss(for: fixture.view)
        fixture.view.loadHTMLString("<title>Source navigated</title>", baseURL: URL(string: "https://example.com/new"))
        try await waitUntil { !fixture.view.isLoading && fixture.view.title == "Source navigated" }
        await failureGate.open()
        try await waitUntil { !note.state.isLoading }
        XCTAssertFalse(note.isClosed)
        XCTAssertTrue(note.glass === glass)
        XCTAssertTrue(note.panel === panel)
        XCTAssertTrue(controller.keptNotes.contains { $0 === note.state })
        XCTAssertEqual(note.state.failure, .blocked)
        XCTAssertNil(note.state.result)
        XCTAssertEqual(note.state.contextText, LinkPreviewFailure.blocked.message + "\n\nhttps://example.com/detached-source")
    }

    private func makeFixture(
        controller: LinkPreviewController, title: String
    ) -> (view: WKWebView, window: LinkPreviewFixtureWindow) {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        controller.install(in: view, tab: BrowserTab())
        let window = LinkPreviewFixtureWindow(
            contentRect: view.bounds, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        view.loadHTMLString("<title>\(title)</title>", baseURL: URL(string: "https://example.com"))
        return (view, window)
    }

    private func postPreviewMessage(path: String, to view: WKWebView) async {
        let script = """
        window.webkit.messageHandlers.browserLinkPreview.postMessage({
          url:'https://example.com/\(path)',x:20,y:40,width:120,height:20
        });0
        """
        await evaluate(script, in: view)
    }

    private func postPreviewLeave(to view: WKWebView) async {
        await evaluate("window.webkit.messageHandlers.browserLinkPreview.postMessage({leave:true});0", in: view)
    }

    private func evaluate(_ script: String, in view: WKWebView) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            view.evaluateJavaScript(script, in: nil, in: .world(name: "BrowserLinkPreviews")) { _ in
                continuation.resume()
            }
        }
    }
}

private actor PreviewTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// XCTest's host is not frontmost, so model an eligible browser source window without activating it.
@MainActor
private final class LinkPreviewFixtureWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
