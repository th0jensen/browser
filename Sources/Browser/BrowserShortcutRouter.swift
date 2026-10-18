import AppKit
import SwiftUI

/// Resolve browser commands through the main menu before native web/toolbar
/// views interpret them as text commands. A performed command consumes its event.
struct BrowserShortcutRouter: NSViewRepresentable {
    let browser: BrowserModel
    func makeNSView(context: Context) -> BrowserShortcutView {
        let view = BrowserShortcutView()
        view.browser = browser
        return view
    }
    func updateNSView(_ view: BrowserShortcutView, context: Context) { view.browser = browser }
    static func dismantleNSView(_ view: BrowserShortcutView, coordinator: ()) { view.stop() }
}

final class BrowserShortcutView: NSView {
    private var monitor: Any?
    weak var browser: BrowserModel?

    isolated deinit { stop() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown, .otherMouseUp]) { [weak self, weak window] event in
            guard let window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                  window.toolbar?.customizationPaletteIsRunning != true,
                  let source = event.window else { return event }
            let isToolbarWindow = window.toolbar?.items.contains { $0.view?.window === source } == true
            guard source === window || isToolbarWindow else { return event }
            if event.type == .otherMouseDown || event.type == .otherMouseUp {
                guard let browser = self?.browser else { return event }
                return BrowserMouseNavigation.handle(type: event.type, button: event.buttonNumber,
                                                      back: { browser.goBack() }, forward: { browser.goForward() }) ? nil : event
            }
            guard Self.isBrowserCommand(event) else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if self?.browser?.chromePreferences.tabLayout == .horizontal,
               event.charactersIgnoringModifiers?.lowercased() == "s",
               modifiers == .command || modifiers == [.command, .control] { return nil }
            // Keep menu validation, alternate shortcuts and their existing actions.
            // Returning nil prevents a successful command reaching a second responder.
            return NSApp.mainMenu?.performKeyEquivalent(with: event) == true ? nil : event
        }
    }

    private static func isBrowserCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g": return modifiers == .command || modifiers == [.command, .option]
                || modifiers == [.command, .option, .shift]
        case "l": return modifiers == .command || modifiers == [.command, .option]
        case "f", "e", "p", "y", "-", "0": return modifiers == .command
        case "n": return modifiers == .command || modifiers == [.command, .shift]
        case "t": return modifiers == .command || modifiers == [.command, .shift]
        case "w", "o", "[", "]": return modifiers == .command
        case "+", "=": return modifiers == .command || modifiers == [.command, .shift] || modifiers == [.command, .option]
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

/// Standard extra mouse buttons, including Logitech's native Back/Forward mode.
/// Consume both edges, but navigate on press only. Middle-click remains WebKit's.
enum BrowserMouseNavigation {
    @MainActor static func handle(type: NSEvent.EventType, button: Int,
                                  back: () -> Void, forward: () -> Void) -> Bool {
        guard type == .otherMouseDown || type == .otherMouseUp, button == 3 || button == 4 else { return false }
        if type == .otherMouseDown {
            if button == 3 { back() } else { forward() }
        }
        return true
    }
}
