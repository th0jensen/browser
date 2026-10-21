import AppKit

/// Local interaction design inspired by Arc's shipped Shift-click UI text.
/// This is not a recovered Arc runtime rule. Shift-hover summaries are separate.
enum PageLinkIntent: Equatable {
    case standard
    case backgroundTab
    case peek

    static func decide(isLinkActivated: Bool, modifiers: NSEvent.ModifierFlags, buttonMask: Int,
                       canPeek: Bool, automaticPeek: Bool) -> Self {
        guard isLinkActivated else { return .standard }
        // WebKit uses a button mask here, not AppKit's zero-based button number.
        if modifiers.contains(.command) || buttonMask == 1 << 2 { return .backgroundTab }
        guard canPeek else { return .standard }
        let keys = modifiers.intersection([.command, .shift, .control, .option])
        if keys == .shift, buttonMask == 1 { return .peek }
        // Leave other modifier combinations to WebKit (for example Option-download).
        return keys.isEmpty && automaticPeek ? .peek : .standard
    }
}
