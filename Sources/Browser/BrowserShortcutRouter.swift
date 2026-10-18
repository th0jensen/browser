import AppKit
import SwiftUI

/// Resolve browser commands through the main menu before native web/toolbar
/// views interpret them as text commands. A performed command consumes its event.
struct BrowserShortcutRouter: NSViewRepresentable {
    func makeNSView(context: Context) -> BrowserShortcutView { BrowserShortcutView() }
    func updateNSView(_ view: BrowserShortcutView, context: Context) {}
    static func dismantleNSView(_ view: BrowserShortcutView, coordinator: ()) { view.stop() }
}

final class BrowserShortcutView: NSView {
    private var monitor: Any?

    isolated deinit { stop() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  window.toolbar?.customizationPaletteIsRunning != true,
                  let source = event.window, Self.isBrowserCommand(event) else { return event }
            let isToolbarWindow = window.toolbar?.items.contains { $0.view?.window === source } == true
            guard source === window || isToolbarWindow else { return event }
            // Keep menu validation, alternate shortcuts and their existing actions.
            // Returning nil prevents a successful command reaching a second responder.
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? nil : event
        }
    }

    private static func isBrowserCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g", "l": return modifiers == .command
        case "t": return modifiers == .command || modifiers == [.command, .shift]
        case "s":
            return modifiers == .command || modifiers == [.command, .shift]
                || modifiers == [.command, .control] || modifiers == [.command, .option]
        default: return false
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
