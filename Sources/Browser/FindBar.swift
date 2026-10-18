import AppKit
import SwiftUI

/// Searches the active tab's page, shown over its top edge.
struct FindBar: View {
    @Bindable var tab: BrowserTab
    let browser: BrowserModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            FindTextField(text: $tab.findText, focusRequest: browser.findFocusRequest,
                          submit: { browser.findNext() }, cancel: { browser.closeFindBar() })
                .frame(width: 180)
                .onChange(of: tab.findText) { _, text in
                    if !browser.isPrivate {
                        let pasteboard = NSPasteboard(name: .find)
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                    }
                    tab.findAsYouType()
                }

            if tab.findHasNoMatches {
                Text("Not Found")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

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
            .disabled(tab.findText.isEmpty)

            Button { browser.closeFindBar() } label: {
                Image(systemName: "xmark")
            }
            .help("Done")
        }
        .buttonStyle(ChromeIconButtonStyle(size: 24))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 34)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .animation(.easeOut(duration: 0.15), value: tab.findHasNoMatches)
    }
}

/// The native field may attach after the overlay appears, so apply focus only once it has a window.
private struct FindTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
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
        if (field.currentEditor()?.string ?? field.stringValue) != text { field.stringValue = text }
        field.requestFocus(focusRequest)
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindTextField
        init(_ parent: FindTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.currentEditor()?.string ?? field.stringValue
        }
        @objc func submit() { parent.submit() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) { parent.cancel(); return true }
            if selector == #selector(NSResponder.insertNewline(_:)) { parent.submit(); return true }
            return false
        }
    }
}

private final class FindField: NSTextField {
    private var requestedFocus = 0
    private var appliedFocus = -1
    func requestFocus(_ request: Int) {
        requestedFocus = request
        DispatchQueue.main.async { [weak self] in self?.applyFocus() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.applyFocus() }
    }
    private func applyFocus() {
        guard requestedFocus != appliedFocus, let window, !isHiddenOrHasHiddenAncestor else { return }
        if window.makeFirstResponder(self) {
            selectText(nil)
            appliedFocus = requestedFocus
        }
    }
}
