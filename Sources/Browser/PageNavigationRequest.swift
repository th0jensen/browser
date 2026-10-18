import WebKit

/// A suspended navigation decision belongs to this tab, web view and browsing request only.
@MainActor
struct PageNavigationRequest {
    private weak var tab: BrowserTab?
    private weak var webView: WKWebView?
    private let revision: Int
    private let requiresBrowser: Bool

    init(tab: BrowserTab, webView: WKWebView) {
        tab.invalidateNavigation()
        self.tab = tab
        self.webView = webView
        revision = tab.navigationRevision
        requiresBrowser = tab.browser != nil
    }

    var isCurrent: Bool {
        guard let tab, let webView, tab.navigationRevision == revision, tab.webView === webView else { return false }
        guard let browser = tab.browser else { return !requiresBrowser }
        return !browser.isClosed && browser.tab(for: webView) === tab
    }
}
