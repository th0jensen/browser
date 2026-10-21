import AppKit
import SwiftUI

/// The address bar's text field. It's an AppKit field so it can complete the text inline, with the completed part
/// selected, and handle the arrow keys, Return, and Esc for the suggestion list.
struct SuggestionAddressField: NSViewRepresentable {
    enum Command: Equatable {
        case moveUp
        case moveDown
        case submit
        case cancel
    }

    @Binding var text: String
    @Binding var isFocused: Bool
    /// Where an inline completion starts in `text`, in UTF-16 units. The rest is selected so typing replaces it.
    var completionStart: Int?
    /// Increase to focus the field, or to resign it.
    var focusRequest: Int
    var blurRequest: Int
    /// Called with the text as the user edits it.
    var edit: (String) -> Void
    /// Returns whether the command was handled, otherwise the field handles it as usual.
    var perform: (Command) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Search or enter address"
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Address and search")
        field.delegate = context.coordinator
        field.didBecomeFocused = { [weak coordinator = context.coordinator] in
            coordinator?.setFocused(true)
        }
        return field
    }

    func updateNSView(_ field: FocusableTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // A private window's toolbar is dark whatever the system appearance.
        field.appearance = context.environment.colorScheme == .dark ? NSAppearance(named: .darkAqua) : nil

        // Set through the field editor while editing, which doesn't count as the user editing.
        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != text {
                editor.string = text
                let length = (text as NSString).length
                let start = min(completionStart ?? length, length)
                editor.selectedRange = NSRange(location: start, length: length - start)
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }

        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            field.focus()
        }
        if coordinator.blurRequest != blurRequest {
            coordinator.blurRequest = blurRequest
            if field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SuggestionAddressField
        var focusRequest: Int
        var blurRequest: Int

        init(_ parent: SuggestionAddressField) {
            self.parent = parent
            focusRequest = parent.focusRequest
            blurRequest = parent.blurRequest
        }

        /// Focus can change while SwiftUI updates the field, so the binding changes afterwards.
        func setFocused(_ isFocused: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self, parent.isFocused != isFocused else { return }
                parent.isFocused = isFocused
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.edit(field.stringValue)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            setFocused(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            let command: Command? = switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): .moveUp
            case #selector(NSResponder.moveDown(_:)): .moveDown
            case #selector(NSResponder.insertNewline(_:)): .submit
            case #selector(NSResponder.cancelOperation(_:)): .cancel
            default: nil
            }
            return command.map(parent.perform) ?? false
        }
    }
}

final class FocusableTextField: NSTextField {
    var didBecomeFocused: (() -> Void)?
    private var focusesInWindow = false

    /// Focuses the field, or does once it's in a window.
    func focus() {
        if let window {
            window.makeFirstResponder(self)
        } else {
            focusesInWindow = true
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesInWindow, let window else { return }
        focusesInWindow = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome { didBecomeFocused?() }
        return didBecome
    }
}
