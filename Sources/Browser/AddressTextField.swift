import AppKit
import SwiftUI

/// A native field lets every new-tab path explicitly request the toolbar's field editor.
struct AddressTextField: NSViewRepresentable {
    @Environment(\.chromeRegionIsVisible) private var chromeRegionIsVisible
    @Binding var text: String
    var requiresVisibleToolbar = true
    var browserWindow: NSWindow?
    var pageURL: URL?
    var pageTitle = ""
    let focusRequest: Int
    let onFocusApplied: (Int) -> Void
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> AddressField {
        let field = AddressField()
        field.browserWindow = browserWindow
        field.requiresVisibleToolbar = requiresVisibleToolbar
        field.regionIsVisible = chromeRegionIsVisible
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .textColor
        field.placeholderString = "Search or enter address"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Address and search")
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.onFocusChange = { context.coordinator.parent.onFocusChange($0) }
        field.onFocusApplied = { context.coordinator.parent.onFocusApplied($0) }
        field.onEditingStarted = { context.coordinator.parent.text = $0 }
        return field
    }

    func updateNSView(_ field: AddressField, context: Context) {
        context.coordinator.parent = self
        field.browserWindow = browserWindow
        field.requiresVisibleToolbar = requiresVisibleToolbar
        field.regionIsVisible = chromeRegionIsVisible
        field.updatePresentation(text: text, url: pageURL, title: pageTitle)
        field.requestFocus(focusRequest)
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AddressTextField
        init(parent: AddressTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        @objc func submit() { parent.onSubmit() }
    }
}

final class AddressField: NSTextField {
    weak var browserWindow: NSWindow?
    var requiresVisibleToolbar = true
    var regionIsVisible = true
    var onFocusChange: ((Bool) -> Void)?
    var onFocusApplied: ((Int) -> Void)?
    var onEditingStarted: ((String) -> Void)?
    private var requestedFocus = 0
    private var appliedFocus = 0
    private var editingText = ""
    private var pageURL: URL?
    private var pageTitle = ""
    private var isPresentingEditor = false
    private var previewCell: NSTextFieldCell?

    func updatePresentation(text: String, url: URL?, title: String) {
        pageURL = url
        pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        editingText = isPresentingEditor ? text : (url?.absoluteString ?? text)
        if stringValue != editingText { stringValue = editingText }
        if !isPresentingEditor { showPageTitle() }
    }

    private func showPageTitle() {
        needsDisplay = true
        guard let pageURL else {
            previewCell = nil
            return
        }
        let site = pageURL.host() ?? pageURL.absoluteString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor
        ]
        let title = NSMutableAttributedString(string: site, attributes: attributes)
        if !pageTitle.isEmpty, pageTitle != site, pageTitle != pageURL.absoluteString {
            title.append(NSAttributedString(string: " / ", attributes: attributes.merging([
                .foregroundColor: NSColor.textColor.withAlphaComponent(0.5)
            ]) { _, value in value }))
            title.append(NSAttributedString(string: pageTitle, attributes: attributes.merging([
                .foregroundColor: NSColor.textColor.withAlphaComponent(0.72)
            ]) { _, value in value }))
        }
        // The preview is only painted. The real cell and its field editor always
        // contain the URL, including when AppKit starts editing before mouseDown.
        if previewCell == nil { previewCell = cell?.copy() as? NSTextFieldCell }
        previewCell?.lineBreakMode = .byTruncatingTail
        if previewCell?.attributedStringValue.isEqual(to: title) != true {
            previewCell?.attributedStringValue = title
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if !isPresentingEditor, let previewCell {
            previewCell.draw(withFrame: bounds, in: self)
        } else {
            super.draw(dirtyRect)
        }
    }

    private func prepareForEditing() {
        guard !isPresentingEditor else { return }
        isPresentingEditor = true
        editingText = pageURL?.absoluteString ?? editingText
        if stringValue != editingText { stringValue = editingText }
        needsDisplay = true
        onEditingStarted?(editingText)
    }

    private var canReceiveFocus: Bool {
        window != nil && regionIsVisible && !isHiddenOrHasHiddenAncestor
            && (!requiresVisibleToolbar || (browserWindow ?? window)?.toolbar?.isVisible != false)
    }

    override var acceptsFirstResponder: Bool { canReceiveFocus && super.acceptsFirstResponder }

    override func mouseDown(with event: NSEvent) {
        guard canReceiveFocus, let window else { return }
        prepareForEditing()
        guard window.makeFirstResponder(self) else { return }
        // The default mouseDown tracks the click and collapses the selection to
        // the clicked character. Enter editing directly for the initial click;
        // subsequent clicks go to the native field editor for caret placement.
        selectText(nil)
        onFocusChange?(true)
    }

    func requestFocus(_ request: Int) {
        requestedFocus = request
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.applyPendingFocus() }
    }

    func applyPendingFocus() {
        guard canReceiveFocus, requestedFocus > 0, requestedFocus != appliedFocus, !isHiddenOrHasHiddenAncestor,
              let window else { return }
        if window.makeFirstResponder(self) {
            selectText(nil)
            appliedFocus = requestedFocus
            onFocusChange?(true)
            onFocusApplied?(requestedFocus)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        onFocusChange?(false)
    }

    override func becomeFirstResponder() -> Bool {
        guard canReceiveFocus else { return false }
        let wasEditing = isPresentingEditor
        prepareForEditing()
        let result = super.becomeFirstResponder()
        if result {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window else { return }
                let focused = canReceiveFocus && (window.firstResponder === self || window.firstResponder === currentEditor())
                // AppKit may establish first responder before delivering the
                // mouse event. Select after that event's native caret handling.
                if focused && !wasEditing { currentEditor()?.selectAll(nil) }
                onFocusChange?(focused)
            }
        } else {
            isPresentingEditor = false
            showPageTitle()
        }
        return result
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isPresentingEditor = false
        showPageTitle()
        onFocusChange?(false)
    }
}
