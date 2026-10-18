import AppKit
import WebKit

extension PageDelegate {
    /// WebKit's macOS menu hook preserves its hit-tested link, image, selection,
    /// editing, extension and Inspect Element actions. Only page commands are added.
    @objc(_webView:getContextMenuFromProposedMenu:forElement:userInfo:completionHandler:)
    func customizeContextMenu(_ webView: WKWebView, proposedMenu menu: NSMenu,
                              element: NSObject, userInfo: AnyObject?,
                              completionHandler: (NSMenu?) -> Void) {
        guard let tab, let browser = tab.browser, !tab.isNewTab else {
            completionHandler(menu)
            return
        }

        var additions: [NSMenuItem] = []
        func addNavigation(_ title: String, identifier: String, enabled: Bool,
                           action: @escaping @MainActor () -> Void) {
            guard !menu.items.contains(where: { $0.identifier?.rawValue == identifier }) else { return }
            additions.append(PageContextMenuItem(title, enabled: enabled, action: action))
        }
        addNavigation("Back", identifier: "WKMenuItemIdentifierGoBack", enabled: webView.canGoBack) {
            [weak webView] in webView?.goBack()
        }
        addNavigation("Forward", identifier: "WKMenuItemIdentifierGoForward", enabled: webView.canGoForward) {
            [weak webView] in webView?.goForward()
        }
        addNavigation("Reload Page", identifier: "WKMenuItemIdentifierReload", enabled: true) {
            [weak webView] in webView?.reload()
        }
        if !additions.isEmpty { additions.append(.separator()) }

        let url = webView.url ?? tab.url
        additions.append(PageContextMenuItem("Copy Page Address", enabled: url != nil) {
            guard let url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
        })
        additions.append(PageContextMenuItem("Save Webpage As…") { [weak browser, weak tab] in
            guard let browser, let tab, browser.activeTabID == tab.id || browser.peek?.tab.id == tab.id else { return }
            browser.saveWebpage()
        })
        let saved = browser.folders.item(tab.folderPageID)
        additions.append(PageContextMenuItem(saved == nil ? "Pin tab" : "Unpin tab",
                                            enabled: saved != nil || tab.url.map(PinnedPageStore.valid) == true) { [weak browser, weak tab] in
            guard let browser, let tab else { return }
            if let saved { browser.moveFolderPageToTemporaryTabs(saved) }
            else { browser.moveToFolder(tab, parentID: nil) }
        })
        let essential = browser.pinnedPages.items.first { $0.id == tab.pinnedPageID }
        additions.append(PageContextMenuItem(essential == nil ? "Add to Essential Tabs" : "Remove from Essential Tabs",
                                            enabled: essential != nil || browser.canPin(tab)) { [weak browser, weak tab] in
            guard let browser, let tab else { return }
            if let essential { browser.unpin(essential) }
            else { browser.pin(tab) }
        })

        // Keep WebKit's actual Inspect Element item last: it knows which DOM node was clicked.
        var insertionIndex = menu.items.firstIndex {
            $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement"
        } ?? menu.numberOfItems
        if insertionIndex > 0, menu.items[insertionIndex - 1].isSeparatorItem { insertionIndex -= 1 }
        if insertionIndex > 0 { additions.insert(.separator(), at: 0) }
        if insertionIndex < menu.numberOfItems, !menu.items[insertionIndex].isSeparatorItem {
            additions.append(.separator())
        }
        for (offset, item) in additions.enumerated() { menu.insertItem(item, at: insertionIndex + offset) }
        completionHandler(menu)
    }
}

@MainActor
private final class PageContextMenuItem: NSMenuItem, NSMenuItemValidation {
    private let command: @MainActor () -> Void
    private let available: Bool

    init(_ title: String, enabled: Bool = true, action: @escaping @MainActor () -> Void) {
        command = action
        available = enabled
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { available }
    @objc private func invoke() { if available { command() } }
}
