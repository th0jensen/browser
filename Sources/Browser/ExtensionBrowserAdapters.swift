import AppKit
import WebKit

extension BrowserModel: WKWebExtensionWindow {
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { allTabs + (peek.map { [$0.tab] } ?? []) }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { peek?.tab ?? activeTab }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { isPrivate }
    func focus(for context: WKWebExtensionContext) async throws {
        window?.makeKeyAndOrderFront(nil)
    }
    func close(for context: WKWebExtensionContext) async throws { window?.performClose(nil) }
}

extension BrowserTab: WKWebExtensionTab {
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { browser }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { browser?.allTabs.firstIndex(where: { $0.id == id }) ?? browser?.allTabs.count ?? 0 }
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { openerID.flatMap { browser?.tabAcrossSpaces(withID: $0) } }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func title(for context: WKWebExtensionContext) -> String? { title }
    func url(for context: WKWebExtensionContext) -> URL? { url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoading }
    func isSelected(for context: WKWebExtensionContext) -> Bool { (browser?.peek?.tab.id ?? browser?.activeTabID) == id }
    func size(for context: WKWebExtensionContext) -> CGSize { contentView.bounds.size }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1) }
    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext) async throws { setZoom(zoomFactor) }
    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws { load(url) }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        restore()
        if fromOrigin { webView?.reloadFromOrigin() } else { reload() }
    }
    func goBack(for context: WKWebExtensionContext) async throws { goBack() }
    func goForward(for context: WKWebExtensionContext) async throws { webView?.goForward() }
    func activate(for context: WKWebExtensionContext) async throws {
        if browser?.peek?.tab === self { browser?.window?.makeFirstResponder(webView) }
        else if let browser {
            if spaceID != browser.activeSpaceID, !browser.selectSpace(spaceID) {
                throw ExtensionFailure("The tab's Space is not available in this window.")
            }
            browser.activeTabID = id
        }
    }
    func setSelected(_ selected: Bool, for context: WKWebExtensionContext) async throws {
        if selected { try await activate(for: context) }
    }
    func close(for context: WKWebExtensionContext) async throws { browser?.closeTab(id) }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
}
