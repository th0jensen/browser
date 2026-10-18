import AppKit
import SwiftUI

/// Opens the links and files other apps hand to the browser, such as a link clicked in Mail once it's the default
/// browser: in new tabs of the frontmost normal window, or in a new window when only private windows are open.
@MainActor
final class ExternalURLRouter {
    static let shared = ExternalURLRouter()

    private var browsers: [WeakBrowser] = []
    /// Links waiting for the window that was asked to open for them.
    private var pendingURLs: [URL] = []
    private var isOpeningWindow = false
    private var openWindow: OpenWindowAction?

    private struct WeakBrowser {
        weak var browser: BrowserModel?
    }

    /// Web pages and local files open; other schemes, like `javascript:`, are ignored.
    static func canOpen(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host()?.isEmpty == false
        case "file": url.isFileURL
        default: false
        }
    }

    /// The first normal window of those open, front to back. A private window never takes links from other apps,
    /// since the user didn't choose to open them privately.
    static func destination(among browsers: [BrowserModel]) -> BrowserModel? {
        browsers.first { !$0.isPrivate && !$0.isExtensionWindow && !$0.isClosed }
    }

    /// A window joins when it appears, and takes the links that were waiting for a window to open.
    func register(_ browser: BrowserModel, openWindow: OpenWindowAction? = nil) {
        guard !browser.isExtensionWindow else { return }
        if let openWindow { self.openWindow = openWindow }
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
        browsers.append(WeakBrowser(browser: browser))
        guard !browser.isPrivate else {
            openPendingWindowIfNeeded()
            return
        }
        isOpeningWindow = false
        let urls = pendingURLs
        pendingURLs = []
        browser.openInNewTabs(urls)
    }

    /// SwiftUI may retain a closed window's model; it must stop being a link destination immediately.
    func unregister(_ browser: BrowserModel) {
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
    }

    func open(_ urls: [URL]) {
        let urls = urls.filter(Self.canOpen)
        guard !urls.isEmpty else { return }
        let windows = NSApp.orderedWindows
        let frontToBack = { (browser: BrowserModel) in
            windows.firstIndex { $0 === browser.window } ?? .max
        }
        let open = browsers.compactMap(\.browser).sorted { frontToBack($0) < frontToBack($1) }
        if let browser = Self.destination(among: open) {
            browser.openInNewTabs(urls)
            if let window = browser.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate()
            return
        }
        // At launch the first window appears on its own, and takes the links when it registers.
        pendingURLs += urls
        openPendingWindowIfNeeded()
    }

    private func openPendingWindowIfNeeded() {
        if !pendingURLs.isEmpty, let openWindow, !isOpeningWindow {
            isOpeningWindow = true
            openWindow(id: BrowserApp.windowID)
        }
    }
}
