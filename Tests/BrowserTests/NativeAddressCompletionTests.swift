import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class NativeAddressCompletionTests: XCTestCase {
    func testReplacingAVisiblePagesAddressPublishesNativeEditorTextAndKeepsAcceptingInput() async throws {
        let fixture = NativeAddressFixture(completion: nil)
        defer { fixture.close() }
        try await waitFor("native address focus") { fixture.field?.currentEditor() != nil && fixture.state.appliedFocus == 1 }
        // A real key event arrives after AppKit's queued initial select-all has completed.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let field = try XCTUnwrap(fixture.field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("a different address", replacementRange: editor.selectedRange())
        try await waitFor("replacement to reach the binding and edit callback") {
            fixture.state.edits.last == "a different address" && fixture.state.text == "a different address"
                && editor.string == "a different address"
        }
        XCTAssertEqual(fixture.state.bindingWrites.last, "a different address")
        XCTAssertFalse(fixture.state.edits.contains(fixture.state.pageURL.absoluteString))
        XCTAssertTrue(fixture.window.firstResponder === editor)

        // A page-title update drives another representable update while the real URL remains nonnil.
        fixture.state.pageTitle = "Updated page title"
        editor.insertText(" plus more", replacementRange: editor.selectedRange())
        try await waitFor("continued editing after another SwiftUI update") {
            fixture.state.edits.last == "a different address plus more"
                && fixture.state.text == "a different address plus more"
                && editor.string == "a different address plus more"
        }
        XCTAssertEqual(fixture.state.bindingWrites.last, "a different address plus more")
        XCTAssertTrue(field.currentEditor() === editor)
    }

    func testInlineCompletionSelectsOnlyTheSuffixAndSubsequentNativeEditsReplaceIt() async throws {
        let fixture = NativeAddressFixture(completion: "example.org")
        defer { fixture.close() }
        try await waitFor("native address focus") { fixture.field?.currentEditor() != nil && fixture.state.appliedFocus == 1 }
        // A real key event arrives after AppKit's queued initial select-all has completed.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let field = try XCTUnwrap(fixture.field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("exa", replacementRange: editor.selectedRange())
        do {
            try await waitFor("inline suffix selection") {
                fixture.state.edits.last == "exa" && fixture.state.text == "example.org"
                    && editor.string == "example.org" && editor.selectedRange() == NSRange(location: 3, length: 8)
            }
        } catch {
            XCTFail("Inline completion diagnostic: editor=\(editor.string.debugDescription), selection=\(editor.selectedRange()), text=\(fixture.state.text.debugDescription), edits=\(fixture.state.edits), bindingWrites=\(fixture.state.bindingWrites), completionStart=\(String(describing: fixture.state.completionStart)), fieldValue=\(field.stringValue.debugDescription), ownsFocus=\(fixture.window.firstResponder === editor), sameEditor=\(field.currentEditor() === editor)")
            throw error
        }
        XCTAssertEqual(fixture.state.bindingWrites.last, "exa", "The binding must receive typed text before completion is presented")
        XCTAssertTrue(fixture.window.firstResponder === editor)

        editor.insertText("m", replacementRange: editor.selectedRange())
        try await waitFor("typing over the selected completion") {
            fixture.state.edits.last == "exam" && editor.string == "example.org"
                && editor.selectedRange() == NSRange(location: 4, length: 7)
        }
        XCTAssertEqual(fixture.state.bindingWrites.last, "exam")
        XCTAssertEqual(fixture.state.edits, ["exa", "exam"], "Presenting completion must not synthesize user edits")

        editor.selectAll(nil)
        editor.insertText("c++ native query", replacementRange: editor.selectedRange())
        try await waitFor("replacing the completion with a new query") {
            fixture.state.edits.last == "c++ native query" && fixture.state.text == "c++ native query"
                && editor.string == "c++ native query"
        }
        XCTAssertNil(fixture.state.completionStart)
        XCTAssertEqual(fixture.state.bindingWrites.last, "c++ native query")
        XCTAssertTrue(field.currentEditor() === editor)
    }

    private func waitFor(_ description: String, timeout: Duration = .seconds(3),
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(description)", file: file, line: line)
                throw NativeAddressTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum NativeAddressTestError: Error { case timedOut }

@MainActor
@Observable
private final class NativeAddressState {
    let pageURL = URL(string: "https://original.example/current-page")!
    var pageTitle = "Original Page"
    var text = "https://original.example/current-page"
    var completionStart: Int?
    var appliedFocus = 0
    var bindingWrites: [String] = []
    var edits: [String] = []
    let completion: String?

    init(completion: String?) { self.completion = completion }

    func edit(_ text: String) {
        edits.append(text)
        if let completion, !text.isEmpty, completion.hasPrefix(text), completion != text {
            self.text = completion
            completionStart = text.utf16.count
        } else {
            completionStart = nil
        }
    }
}

@MainActor
private struct NativeAddressHost: View {
    let state: NativeAddressState

    var body: some View {
        AddressTextField(text: Binding(get: { state.text }, set: {
            state.bindingWrites.append($0)
            state.text = $0
        }), requiresVisibleToolbar: false, pageURL: state.pageURL, pageTitle: state.pageTitle,
           completionStart: state.completionStart, onEdit: state.edit,
           focusRequest: 1, onFocusApplied: { state.appliedFocus = $0 },
           onFocusChange: { _ in }, onSubmit: {})
            .frame(width: 540, height: 32)
            .padding(16)
    }
}

@MainActor
private final class NativeAddressFixture {
    let state: NativeAddressState
    let host: NSHostingView<NativeAddressHost>
    let window: NativeAddressTestWindow

    init(completion: String?) {
        let state = NativeAddressState(completion: completion)
        self.state = state
        host = NSHostingView(rootView: NativeAddressHost(state: state))
        host.sceneBridgingOptions = []
        window = NativeAddressTestWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 70),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderBack(nil)
    }

    var field: AddressField? {
        func find(_ view: NSView) -> AddressField? {
            if let field = view as? AddressField { return field }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        return find(host)
    }

    func close() {
        window.makeFirstResponder(nil)
        window.close()
    }
}

@MainActor
private final class NativeAddressTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
