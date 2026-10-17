import AppKit
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class BrowserModel: NSObject {
    let downloads: DownloadManager
    let sitePermissions: SitePermissions
    let pinnedPages: PinnedPageStore

    private(set) var tabs: [BrowserTab] = []
    private var closedTabs: [ClosedTab] = []
    var activeTabID: UUID? {
        didSet {
            guard oldValue != activeTabID else { return }
            if let previousTab = tab(withID: oldValue) {
                // Keep a preview of the page being left for background-tab hover cards.
                previousTab.captureThumbnail(afterScreenUpdates: false)
                previousTab.lastActive = .now
            }
            activeTab?.restore()
            activeTab?.didBecomeSelected()
            if let activeTab {
                BrowserExtensions.shared.didActivate(activeTab, previous: tab(withID: oldValue))
            }
        }
    }
    var addressFocusRequest = 0
    @ObservationIgnored var consumedAddressFocusRequest = 0
    @ObservationIgnored private var suspender: TabSuspender?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var isExtensionWindow = false

    private struct ClosedTab {
        let url: URL?
        let title: String
        /// The tab's back-forward history, restored when it reopens.
        let interactionState: Any?
    }

    init(downloads: DownloadManager = DownloadManager(), sitePermissions: SitePermissions = .shared,
         configuration: WKWebViewConfiguration = BrowserTab.makeConfiguration(), pinnedPages: PinnedPageStore? = nil) {
        self.downloads = downloads
        self.sitePermissions = sitePermissions
        self.pinnedPages = pinnedPages ?? (BrowserProfile.isTesting
            ? PinnedPageStore(directory: BrowserProfile.directory, enabled: false) : .shared)
        super.init()
        addTab(configuration: configuration)
        suspender = TabSuspender(browser: self)
    }

    var activeTab: BrowserTab? {
        tab(withID: activeTabID)
    }

    var canReopenClosedTab: Bool {
        !closedTabs.isEmpty
    }

    var regularTabs: [BrowserTab] {
        let ids = Set(pinnedPages.items.map(\.id))
        return tabs.filter { !ids.contains($0.pinnedPageID ?? $0.id) }
    }

    func canPin(_ tab: BrowserTab) -> Bool {
        guard let url = tab.url, PinnedPageStore.valid(url) else { return false }
        return pinnedPages.items.count < PinnedPageStore.limit || pinnedPages.items.contains { $0.url == url }
    }

    func pin(_ tab: BrowserTab) {
        guard let url = tab.url else { return }
        do {
            let page = try pinnedPages.pin(url: url, title: tab.title)
            tabs.filter { $0.pinnedPageID == page.id }.forEach { $0.pinnedPageID = nil }
            tab.pinnedPageID = page.id
        } catch { reportPinnedPageError(error) }
    }

    func unpin(_ page: PinnedPage) {
        do {
            try pinnedPages.remove(page.id)
            tabs.filter { $0.pinnedPageID == page.id }.forEach { $0.pinnedPageID = nil }
        } catch { reportPinnedPageError(error) }
    }

    private func reportPinnedPageError(_ error: Error) {
        pinnedPages.errorMessage = error.localizedDescription
        if let window { NSAlert(error: error).beginSheetModal(for: window) }
    }

    func openPinned(_ page: PinnedPage) {
        guard pinnedPages.items.contains(where: { $0.id == page.id }) else { return }
        if let tab = tabs.first(where: { $0.pinnedPageID == page.id }) {
            activeTabID = tab.id
        } else {
            let tab = adopt(BrowserTab(url: page.url, title: page.title, interactionState: nil))
            tab.pinnedPageID = page.id
            tabs.append(tab)
            BrowserExtensions.shared.didOpen(tab)
            activeTabID = tab.id
        }
    }

    func restoreSession(_ session: BrowserSessionSnapshot) {
        guard !session.tabs.isEmpty else { return }
        let previous = tabs
        var boundPins = Set<UUID>()
        tabs = session.tabs.map { saved in
            guard let url = saved.url, ["https", "http", "webkit-extension"].contains(url.scheme ?? "") else { return makeTab() }
            let tab = adopt(BrowserTab(url: url, title: saved.title, interactionState: nil))
            let page = pinnedPages.items.first { $0.id == saved.pinnedPageID }
                ?? pinnedPages.items.first { $0.url == url }
            if let page, boundPins.insert(page.id).inserted { tab.pinnedPageID = page.id }
            return tab
        }
        previous.forEach { BrowserExtensions.shared.didClose($0) }
        tabs.forEach { BrowserExtensions.shared.didOpen($0) }
        activeTabID = tabs[min(max(0, session.selectedIndex), tabs.count - 1)].id
    }

    func tab(withID id: UUID?) -> BrowserTab? {
        guard let id else { return nil }
        return tabs.first { $0.id == id }
    }

    private func makeTab(configuration: WKWebViewConfiguration = BrowserTab.makeConfiguration()) -> BrowserTab {
        adopt(BrowserTab(configuration: configuration))
    }

    private func adopt(_ tab: BrowserTab) -> BrowserTab {
        tab.browser = self
        return tab
    }

    func addTab(configuration: WKWebViewConfiguration = BrowserTab.makeConfiguration(), focusAddress: Bool = true) {
        let tab = makeTab(configuration: configuration)
        tabs.append(tab)
        BrowserExtensions.shared.didOpen(tab)
        activeTabID = tab.id
        if focusAddress { requestAddressFocus() }
    }

    func duplicateTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let original = tabs[index]
        // The copy starts suspended, so selecting it restores the original's history and scroll position.
        let tab = original.url == nil ? makeTab()
            : adopt(BrowserTab(url: original.url, title: original.pageTitle, interactionState: original.interactionState))
        tabs.insert(tab, at: index + 1)
        BrowserExtensions.shared.didOpen(tab)
        activeTabID = tab.id
        if tab.isNewTab { requestAddressFocus() }
    }

    func moveTab(_ id: UUID, to destinationIndex: Int) {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              tabs.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        tabs.move(fromOffsets: IndexSet(integer: sourceIndex),
                  toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex)
        BrowserExtensions.shared.controller.didMoveTab(tabs[destinationIndex], from: sourceIndex, in: self)
    }

    func closeOtherTabs(than id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let closingTabs = tabs.filter { $0.id != id }
        for tab in closingTabs {
            rememberClosedTab(tab)
        }
        tabs.removeAll { $0.id != id }
        closingTabs.forEach { BrowserExtensions.shared.didClose($0) }
        activeTabID = id
    }

    func closeTabs(after id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTabs = Array(tabs[(index + 1)...])
        closingTabs.forEach(rememberClosedTab)
        let closingIDs = Set(closingTabs.map(\.id))
        tabs.removeAll { closingIDs.contains($0.id) }
        closingTabs.forEach { BrowserExtensions.shared.didClose($0) }
        if let activeTabID, closingIDs.contains(activeTabID) {
            self.activeTabID = id
        }
    }

    func closeActiveTab() {
        guard let activeTabID else { return }
        closeTab(activeTabID)
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        rememberClosedTab(tabs[index])
        let closed = tabs.remove(at: index)
        BrowserExtensions.shared.didClose(closed)
        if tabs.isEmpty {
            if isExtensionWindow {
                activeTabID = nil
                window?.close()
            } else {
                addTab()
            }
        } else if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Remembers a closing tab so it can reopen, and dismisses the panels its page is waiting to show.
    private func rememberClosedTab(_ tab: BrowserTab) {
        tab.stopWaitingForSelection()
        let isBlank = tab.isNewTab || tab.url == nil
        closedTabs.append(ClosedTab(url: isBlank ? nil : tab.url, title: tab.pageTitle,
                                    interactionState: isBlank ? nil : tab.interactionState))
        if closedTabs.count > 10 { closedTabs.removeFirst() }
    }

    func reopenClosedTab() {
        guard let closedTab = closedTabs.popLast() else { return }
        guard closedTab.url != nil else {
            addTab()
            return
        }
        // Selecting the suspended tab restores its history, or loads its address.
        let tab = adopt(BrowserTab(url: closedTab.url, title: closedTab.title,
                                   interactionState: closedTab.interactionState))
        tabs.append(tab)
        BrowserExtensions.shared.didOpen(tab)
        activeTabID = tab.id
    }

    /// Opens a tab after the opener and any tabs it opened before, like a page's pop-up or a ⌘-clicked link.
    /// Pass WebKit's configuration for a pop-up, or a request to load.
    @discardableResult
    func openChildTab(of opener: BrowserTab, configuration: WKWebViewConfiguration? = nil,
                      loading request: URLRequest? = nil, select: Bool) -> BrowserTab {
        let tab = configuration.map(makeTab) ?? makeTab()
        tab.isNewTab = false
        tab.openerID = opener.id
        tab.isPopUp = configuration != nil
        // Background tabs lay out at the size they'll be shown at.
        tab.contentView.frame = opener.contentView.frame
        var index = (tabs.firstIndex { $0.id == opener.id } ?? tabs.count - 1) + 1
        while tabs.indices.contains(index), tabs[index].openerID == opener.id {
            index += 1
        }
        tabs.insert(tab, at: index)
        BrowserExtensions.shared.didOpen(tab)
        if let request { tab.webView?.load(request) }
        if select { activeTabID = tab.id }
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeTabID = tabs[index].id
    }

    func selectLastTab() {
        guard !tabs.isEmpty else { return }
        selectTab(at: tabs.count - 1)
    }

    func switchTab(by offset: Int) {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == activeTabID }),
              !tabs.isEmpty else { return }
        selectTab(at: (currentIndex + offset + tabs.count) % tabs.count)
    }

    func open(_ url: URL, inNewTab: Bool = false) {
        if inNewTab || activeTab == nil {
            let tab = makeTab()
            tabs.append(tab)
            BrowserExtensions.shared.didOpen(tab)
            activeTabID = tab.id
        }
        activeTab?.load(url)
    }

    func navigate(to input: String) {
        guard let url = BrowserAddress.url(for: input) else { return }
        activeTab?.load(url)
    }

    func reload() {
        guard let activeTabID else { return }
        reloadTab(activeTabID)
    }

    func reloadTab(_ id: UUID) {
        guard let tab = tab(withID: id), !tab.isNewTab else { return }
        tab.reload()
    }

    func stopLoading() {
        activeTab?.webView?.stopLoading()
    }

    func goBack() {
        activeTab?.goBack()
    }

    func goForward() {
        activeTab?.webView?.goForward()
    }

    func go(to item: WKBackForwardListItem) {
        activeTab?.webView?.go(to: item)
    }

    func requestAddressFocus() {
        addressFocusRequest += 1
    }

    #if DEBUG
    func showWebInspector() {
        guard let tab = activeTab, !tab.isNewTab, let webView = tab.webView else { return }
        WebInspector.show(for: webView)
    }
    #endif

    /// Background tabs that can be suspended to free memory, least recently used first. A pop-up and its opener
    /// can script each other, so neither is suspended while both are open.
    var suspendableTabs: [BrowserTab] {
        var linkedIDs = Set<UUID>()
        for tab in tabs where tab.isPopUp {
            guard let openerID = tab.openerID, self.tab(withID: openerID) != nil else { continue }
            linkedIDs.formUnion([tab.id, openerID])
        }
        return tabs
            .filter { $0.id != activeTabID && $0.canSuspend && !linkedIDs.contains($0.id) }
            .sorted { $0.lastActive < $1.lastActive }
    }

    /// Suspends the tabs in order, except pages playing media. Each is checked again after asking WebKit about
    /// media, since it might have been selected in the meantime.
    func suspendTabs(_ candidates: [BrowserTab]) async {
        for tab in candidates {
            guard !(await tab.isPlayingMedia()), suspendableTabs.contains(where: { $0 === tab }) else { continue }
            tab.suspend()
        }
    }
}

enum BrowserAddress {
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let url = URL(string: text),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           url.host() != nil {
            return url
        }

        if !text.contains(where: \.isWhitespace),
           (text.contains(".") || text == "localhost"),
           let url = URL(string: "https://\(text)"),
           url.host() != nil {
            return url
        }

        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }
}
