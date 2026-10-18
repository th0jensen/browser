import AppKit
import WebKit

/// WebKit only enables the Web Inspector through Safari's Develop menu, so these hooks use private API.
/// Every selector is checked first, so the Inspector just stays unavailable if WebKit changes.
@MainActor
enum WebInspector {
    /// Adds Inspect Element to the page's context menu.
    static func enableDeveloperExtras(in configuration: WKWebViewConfiguration) {
        let preferences = configuration.preferences
        guard preferences.responds(to: NSSelectorFromString("_setDeveloperExtrasEnabled:")) else { return }
        preferences.setValue(true, forKey: "developerExtrasEnabled")
    }

    /// Opens the Inspector docked in the page, or in its own window if that's where the user last put it.
    static func show(for webView: WKWebView) {
        let showSelector = NSSelectorFromString("show")
        guard webView.isInspectable, let inspector = inspector(for: webView), inspector.responds(to: showSelector) else {
            NSSound.beep()
            return
        }
        inspector.perform(showSelector)
    }

    /// Whether the Inspector is open for the page, docked or in its own window.
    static func isOpen(for webView: WKWebView) -> Bool {
        guard let inspector = inspector(for: webView),
              inspector.responds(to: NSSelectorFromString("isConnected")) else { return false }
        return inspector.value(forKey: "isConnected") as? Bool ?? false
    }

    private static func inspector(for webView: WKWebView) -> NSObject? {
        let inspectorSelector = NSSelectorFromString("_inspector")
        guard webView.responds(to: inspectorSelector) else { return nil }
        return webView.perform(inspectorSelector)?.takeUnretainedValue() as? NSObject
    }
}
