import AppKit

/// Composition belongs to the focused text-input client, not to a particular
/// editor class. WebKit can expose it through a view's input context instead.
@MainActor
enum FocusedTextInput {
    static func hasMarkedText(_ responder: NSResponder?) -> Bool {
        if let client = responder as? any NSTextInputClient, client.hasMarkedText() { return true }
        // Only inspect the focused view's context, never the global current
        // context, which can belong to another window or input owner.
        return (responder as? NSView)?.inputContext?.client.hasMarkedText() == true
    }
}
