import AppKit
import SwiftUI

/// Searches the active tab's page, shown over its top edge.
struct FindBar: View {
    @Bindable var tab: BrowserTab
    let browser: BrowserModel
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            if !compact {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            FindTextField(text: $tab.findText, focusRequest: browser.findFocusRequest,
                          canFocus: { browser.focusedPage === tab && tab.isFindBarVisible },
                          compositionChanged: {
                              if browser.pageQuestion?.sourceTabID == tab.id { browser.pageQuestion?.cancel() }
                          },
                          submit: { browser.findNext() }, cancel: { browser.closeFindBar() })
                .frame(minWidth: 44, maxWidth: .infinity)
                .help("Return finds text on this page. Ask uses this text as a local question.")
                .onChange(of: tab.findText) { _, _ in browser.findTextDidChange(in: tab) }

            if tab.findHasNoMatches && !compact {
                Text("Not Found").font(.caption).foregroundStyle(.secondary)
            }

            if compact {
                Menu {
                    Button("Previous Match") { browser.findNext(backwards: true) }
                    Button("Next Match") { browser.findNext() }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Find matches")
                .disabled(tab.findText.isEmpty)
            } else {
                Group {
                    Button { browser.findNext(backwards: true) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .help("Previous Match (⇧⌥⌘G)")
                    Button { browser.findNext() } label: {
                        Image(systemName: "chevron.down")
                    }
                    .help("Next Match (⌥⌘G)")
                }
                .buttonStyle(ChromeIconButtonStyle(size: 22))
                .disabled(tab.findText.isEmpty)
            }

            Button("Ask") { browser.askOnPageFromFind() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Ask on Page")
                .help("Answer this question using captured page text, only on this Mac")
                .disabled(!browser.canAskOnPage)

            Button { browser.closeFindBar() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(ChromeIconButtonStyle(size: 22))
            .accessibilityLabel("Close Find and Ask on Page")
            .help("Close (Escape)")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
}

/// The native field may attach after the overlay appears, so apply focus only once it has a window.
struct FindTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    var canFocus: @MainActor () -> Bool = { true }
    var compositionChanged: @MainActor () -> Void = {}
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FindField {
        let field = FindField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Find on Page"
        field.usesSingleLineMode = true
        field.setAccessibilityLabel("Find on page")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }
    func updateNSView(_ field: FindField, context: Context) {
        context.coordinator.parent = self
        field.canFocus = canFocus
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
           (field.currentEditor()?.string ?? field.stringValue) != text { field.stringValue = text }
        field.requestFocus(focusRequest)
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindTextField
        init(_ parent: FindTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
                parent.compositionChanged()
                return
            }
            parent.text = field.currentEditor()?.string ?? field.stringValue
        }
        @objc func submit() { parent.submit() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.cancel(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.submit(); return true }
            return false
        }
    }
}

final class FindField: NSTextField {
    var canFocus: @MainActor () -> Bool = { true }
    private var requestedFocus = 0
    private var appliedFocus = -1
    func requestFocus(_ request: Int) {
        requestedFocus = request
        scheduleFocus()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFocus()
    }
    private func scheduleFocus() {
        guard let window, requestedFocus != appliedFocus else { return }
        let request = requestedFocus
        DispatchQueue.main.async { [weak self, weak window, weak responder = window.firstResponder] in
            guard let self, let window, self.window === window,
                  request == self.requestedFocus, request != self.appliedFocus else { return }
            self.appliedFocus = request
            // Do not take focus back after a newer click, focus request, or IME edit.
            guard self.canFocus(), !self.isHiddenOrHasHiddenAncestor,
                  window.firstResponder === responder,
                  (self.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
            if window.makeFirstResponder(self) { self.selectText(nil) }
        }
    }
}
