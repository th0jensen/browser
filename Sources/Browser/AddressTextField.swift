import AppKit
import SwiftUI

/// A native field lets every new-tab path explicitly request the toolbar's field editor.
struct AddressTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onFocusApplied: (Int) -> Void
    let onFocusChange: (Bool) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> AddressField {
        let field = AddressField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
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
        return field
    }

    func updateNSView(_ field: AddressField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
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
    var onFocusChange: ((Bool) -> Void)?
    var onFocusApplied: ((Int) -> Void)?
    private var requestedFocus = 0
    private var appliedFocus = 0

    func requestFocus(_ request: Int) {
        requestedFocus = request
        DispatchQueue.main.async { [weak self] in self?.applyFocus() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.applyFocus() }
    }

    private func applyFocus() {
        guard requestedFocus > 0, requestedFocus != appliedFocus, let window else { return }
        if window.makeFirstResponder(self) {
            selectText(nil)
            appliedFocus = requestedFocus
            onFocusApplied?(requestedFocus)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onFocusChange?(true) } }
        return result
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChange?(false)
    }
}
