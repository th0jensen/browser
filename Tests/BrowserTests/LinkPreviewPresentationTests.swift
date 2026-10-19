import XCTest
import AppKit
import WebKit
@testable import Browser

@MainActor
final class LinkPreviewPresentationTests: XCTestCase {
    func testPreviewPreparesOffscreenAndRevealsCompletedContentAtomically() async throws {
        let resultGate = PreviewTestGate()
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, summaryProvider: { _ in
                await resultGate.wait()
                return LinkSummary(
                    title: "Ready", summary: "Complete useful preview content.", keyPoints: ["One fact."])
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Atomic preview fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }

        await postPreviewMessage(path: "ready", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preparation = try XCTUnwrap(controller.current)
        XCTAssertNil(controller.presentedPreview)
        XCTAssertNil(preparation.glass)
        XCTAssertNil(preparation.content)
        XCTAssertNil(preparation.state.result)

        await resultGate.open()
        try await waitUntil { controller.presentedPreview?.result?.title == "Ready" }
        XCTAssertTrue(controller.current === preparation)
        XCTAssertNotNil(preparation.glass)
        XCTAssertEqual(controller.presentedPreview?.result?.summary, "Complete useful preview content.")
    }

    func testLeavingLinkCancelsHiddenPreparationBeforeResultCompletes() async throws {
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

    func testFailedPreviewNeverMountsCard() async throws {
        let failureGate = PreviewTestGate()
        let controller = LinkPreviewController(
            observesSettings: false, modifierFlags: { .shift }, summaryProvider: { _ in
                await failureGate.wait()
                throw IntelligenceError.message("No preview")
            })
        controller.setEnabled(true)
        let fixture = makeFixture(controller: controller, title: "Failed preview fixture")
        defer { controller.setEnabled(false); fixture.window.close() }
        try await waitUntil { !fixture.view.isLoading && fixture.view.title != nil }

        await postPreviewMessage(path: "failure", to: fixture.view)
        try await waitUntil { controller.current != nil }
        let preparation = try XCTUnwrap(controller.current)
        XCTAssertNil(controller.presentedPreview)
        await failureGate.open()
        try await waitUntil { controller.current == nil }
        XCTAssertTrue(preparation.isClosed)
        XCTAssertNil(preparation.glass)
        XCTAssertNil(preparation.content)
        XCTAssertNil(preparation.panel)
    }

    func testTimedOutPreviewCancelsBeforeMountingCard() async throws {
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
        XCTAssertNil(controller.presentedPreview)
        await deadlineGate.open()
        try await waitUntil { controller.current == nil }
        XCTAssertTrue(preparation.isClosed)
        XCTAssertNil(preparation.glass)
        XCTAssertNil(preparation.content)
        XCTAssertNil(preparation.panel)
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
