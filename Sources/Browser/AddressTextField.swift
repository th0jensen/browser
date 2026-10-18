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
    var completionStart: Int? = nil
    var suggestions: [AddressSuggestion] = []
    var selectedSuggestion: Int? = nil
    var onEdit: ((String) -> Void)? = nil
    var onCommand: ((SuggestionAddressField.Command) -> Bool)? = nil
    var onChooseSuggestion: ((AddressSuggestion) -> Void)? = nil
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
        field.onEndEditing = { context.coordinator.closeSuggestions() }
        return field
    }

    func updateNSView(_ field: AddressField, context: Context) {
        context.coordinator.parent = self
        field.browserWindow = browserWindow
        field.requiresVisibleToolbar = requiresVisibleToolbar
        field.regionIsVisible = chromeRegionIsVisible
        field.updatePresentation(text: text, url: pageURL, title: pageTitle, completionStart: completionStart)
        context.coordinator.updateSuggestions(for: field)
        field.requestFocus(focusRequest)
    }

    static func dismantleNSView(_ view: AddressField, coordinator: Coordinator) {
        coordinator.closeSuggestions()
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        private var suggestionPanel: AddressSuggestionPanel?
        var parent: AddressTextField
        init(parent: AddressTextField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let editedText = field.currentEditor()?.string ?? field.stringValue
            parent.text = editedText
            parent.onEdit?(editedText)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let command: SuggestionAddressField.Command
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): command = .moveUp
            case #selector(NSResponder.moveDown(_:)): command = .moveDown
            case #selector(NSResponder.insertNewline(_:)): command = .submit
            case #selector(NSResponder.cancelOperation(_:)): command = .cancel
            default: return false
            }
            return parent.onCommand?(command) ?? false
        }

        func updateSuggestions(for field: AddressField) {
            guard !parent.suggestions.isEmpty, parent.chromeRegionIsVisible,
                  !field.isHiddenOrHasHiddenAncestor, let window = field.window,
                  field.currentEditor() != nil else { closeSuggestions(); return }
            let panel: AddressSuggestionPanel
            if let existing = suggestionPanel { panel = existing }
            else {
                panel = AddressSuggestionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.hidesOnDeactivate = true
                panel.isReleasedWhenClosed = false
                suggestionPanel = panel
            }
            let content = AddressSuggestionList(suggestions: parent.suggestions, selectedIndex: parent.selectedSuggestion) { [weak self] suggestion in
                self?.parent.onChooseSuggestion?(suggestion)
                self?.closeSuggestions()
            }
            panel.contentView = NSHostingView(rootView: content)
            let anchor = window.convertToScreen(field.convert(field.bounds, to: nil))
            let width = max(300, anchor.width + 70)
            let height = CGFloat(parent.suggestions.count * 29 + 10)
            let screen = window.screen?.visibleFrame ?? anchor
            let x = min(max(anchor.minX - 22, screen.minX), screen.maxX - width)
            panel.setFrame(NSRect(x: x, y: anchor.minY - height - 8, width: width, height: height), display: true)
            if panel.parent !== window {
                panel.parent?.removeChildWindow(panel)
                window.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        }

        func closeSuggestions() {
            if let panel = suggestionPanel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            suggestionPanel = nil
        }

        @objc func submit() {
            if parent.onCommand?(.submit) != true { parent.onSubmit() }
        }
    }
}

final class AddressField: NSTextField {
    weak var browserWindow: NSWindow?
    var requiresVisibleToolbar = true
    var regionIsVisible = true
    var onFocusChange: ((Bool) -> Void)?
    var onFocusApplied: ((Int) -> Void)?
    var onEditingStarted: ((String) -> Void)?
    var onEndEditing: (() -> Void)?
    private var requestedFocus = 0
    private var appliedFocus = 0
    private var editingText = ""
    private var pageURL: URL?
    private var pageTitle = ""
    private var isPresentingEditor = false
    private var previewCell: NSTextFieldCell?

    func updatePresentation(text: String, url: URL?, title: String, completionStart: Int? = nil) {
        pageURL = url
        pageTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentEditor() != nil { isPresentingEditor = true }
        editingText = isPresentingEditor ? text : (url?.absoluteString ?? text)
        if let editor = currentEditor() as? NSTextView, isPresentingEditor {
            if editor.string != editingText {
                editor.string = editingText
                let length = (editingText as NSString).length
                let start = min(completionStart ?? length, length)
                editor.selectedRange = NSRange(location: start, length: length - start)
            }
        } else if stringValue != editingText { stringValue = editingText }
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
        let textAtFocus = editingText
        let result = super.becomeFirstResponder()
        if result {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window else { return }
                let focused = canReceiveFocus && (window.firstResponder === self || window.firstResponder === currentEditor())
                // AppKit may establish first responder before delivering the
                // mouse event. Select after that event's native caret handling.
                if focused && !wasEditing && currentEditor()?.string == textAtFocus {
                    currentEditor()?.selectAll(nil)
                }
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
        onEndEditing?()
        showPageTitle()
        onFocusChange?(false)
    }
}

/// Suggestions remain attached to the native toolbar without taking its field editor's focus.
private final class AddressSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
