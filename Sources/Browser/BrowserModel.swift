import AppKit
import Foundation
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class BrowserModel: NSObject {
    @ObservationIgnored weak var chromeHover: ChromeHoverController?
    let chromePreferences: WindowChromePreferences
    let downloads: DownloadManager
    let sitePermissions: SitePermissions
    let history: HistoryStore?
    let zoomLevels: ZoomStore
    let websiteDataStore: WKWebsiteDataStore
    let passwords: PasswordManager?
    /// QA profiles are nonpersistent too; privacy is a separate browsing mode.
    let isPrivate: Bool
    @ObservationIgnored weak var sessionStore: SessionStore?
    var findFocusRequest = 0
    var isShowingHistory = false
    var isShowingClearData = false
    let pinnedPages: PinnedPageStore
    let folders: TabFolderStore
    var folderEditorRequest: FolderEditorRequest?
    var renamingSavedPageID: UUID?
    var isTidyingTabs = false
    var intelligenceError: String?
    @ObservationIgnored var reorderFeedback: () -> Void = {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }
    @ObservationIgnored private var tidyTask: Task<Void, Never>?
    private var tidyUndo: TidyUndoSnapshot?
    @ObservationIgnored private var titleTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var titleTaskTokens: [UUID: UUID] = [:]
    private(set) var namingSavedPageIDs: Set<UUID> = []
    @ObservationIgnored let tabDrag = TabReorderController()

    private(set) var tabs: [BrowserTab] = []
    private(set) var peek: PeekPage?
    var splits: [SplitTabGroup] = []
    private var closedTabs: [ClosedTab] = []
    var activeTabID: UUID? {
        didSet {
            guard oldValue != activeTabID else { return }
            dismissPeek()
            if let previousTab = tab(withID: oldValue) {
                if let view = previousTab.webView { LinkPreviewController.shared.dismiss(for: view) }
                // Keep a preview of the page being left for background-tab hover cards.
                previousTab.captureThumbnail(afterScreenUpdates: false, minimumAge: .seconds(2))
                previousTab.lastActive = .now
            }
            if activeTab?.isNewTab != true { activeTab?.restore() }
            restoreVisibleSplit()
            activeTab?.didBecomeSelected()
            // A plain loaded page already has a native host. Attach its replacement
            // now so toolbar and tab-strip updates cannot delay showing the page.
            // Structural changes and overlays stay with SwiftUI's normal update.
            if let previous = tab(withID: oldValue), let selected = activeTab,
               previous.webView != nil, selected.webView != nil,
               !previous.isNewTab, !selected.isNewTab,
               previous.loadError == nil, selected.loadError == nil,
               !previous.isFindBarVisible, !selected.isFindBarVisible,
               split(containing: previous.id) == nil, activeSplit == nil,
               let host = previous.contentView.superview as? PageHostView,
               let window, host.window === window,
               selected.contentView.window == nil || selected.contentView.window === window {
                host.show(selected.contentView)
            }
            let representedTab = tab(withID: activeSplit?.anchorID) ?? activeTab
            if let pageID = representedTab?.folderPageID { changeFolders { try folders.reveal(pageID) } }
            if let section = representedTab?.temporarySection, !section.isExpanded { setTemporarySectionExpanded(section.id, expanded: true) }
            if let activeTab {
                BrowserExtensions.shared.didActivate(activeTab, previous: tab(withID: oldValue))
            }
            updateWindowTitle()
        }
    }
    var addressFocusRequest = 0
    @ObservationIgnored var consumedAddressFocusRequest = 0
    @ObservationIgnored private var suspender: TabSuspender?
    @ObservationIgnored weak var window: NSWindow? {
        didSet { updateWindowTitle() }
    }
    @ObservationIgnored var isExtensionWindow = false
    @ObservationIgnored private(set) var isClosed = false

    private struct ClosedTab {
        let url: URL?
        let title: String
        /// The tab's back-forward history, restored when it reopens.
        let interactionState: Any?
        let folderPageID: UUID?
    }

    init(downloads: DownloadManager = DownloadManager(), sitePermissions: SitePermissions = .shared,
         configuration: WKWebViewConfiguration? = nil, pinnedPages: PinnedPageStore? = nil,
         folders: TabFolderStore? = nil, chromePreferences: WindowChromePreferences? = nil,
         history: HistoryStore? = nil, zoomLevels: ZoomStore = .shared,
         websiteDataStore: WKWebsiteDataStore = BrowserProfile.websiteDataStore,
         passwords: PasswordManager? = nil, isPrivate: Bool = false, createsInitialTab: Bool = true) {
        self.chromePreferences = chromePreferences ?? WindowChromePreferences()
        self.downloads = downloads
        self.sitePermissions = isPrivate ? SitePermissions() : sitePermissions
        self.history = isPrivate ? nil : history
        self.zoomLevels = isPrivate ? ZoomStore(defaults: nil) : zoomLevels
        self.websiteDataStore = isPrivate && websiteDataStore.isPersistent ? .nonPersistent() : websiteDataStore
        self.isPrivate = isPrivate
        self.passwords = !isPrivate && websiteDataStore.isPersistent && BrowserProfile.qaDirectory == nil ? passwords : nil
        self.pinnedPages = pinnedPages ?? (BrowserProfile.isTesting || isPrivate
            ? PinnedPageStore(directory: BrowserProfile.directory, enabled: false) : .shared)
        self.folders = folders ?? (BrowserProfile.isTesting || isPrivate
            ? TabFolderStore(directory: BrowserProfile.directory, enabled: false) : .shared)
        super.init()
        tabDrag.canSplit = { [weak self] source, target in self?.canSplitDrag(source, with: target) == true }
        if createsInitialTab { addTab(configuration: configuration) }
        suspender = TabSuspender(browser: self)
    }

    isolated deinit {
        tidyTask?.cancel()
        titleTasks.values.forEach { $0.cancel() }
    }

    static func makePrivate(downloads: DownloadManager) -> BrowserModel {
        BrowserModel(downloads: downloads, sitePermissions: SitePermissions(), zoomLevels: ZoomStore(defaults: nil),
                     websiteDataStore: .nonPersistent(), isPrivate: true)
    }

    func makeConfiguration(for url: URL? = nil) -> WKWebViewConfiguration {
        let context = !isPrivate ? url.flatMap { BrowserExtensions.shared.controller.extensionContext(for: $0) } : nil
        let configuration = context?.webViewConfiguration ?? BrowserTab.makeConfiguration(includingExtensions: !isPrivate)
        configuration.websiteDataStore = websiteDataStore
        preparePageConfiguration(configuration)
        return configuration
    }

    func preparePageConfiguration(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = websiteDataStore
        if passwords != nil {
            PasswordAutofill.install(in: configuration.userContentController, handler: PasswordMessageHandler(browser: self))
        }
    }

    func tab(for webView: WKWebView) -> BrowserTab? {
        (tabs + (peek.map { [$0.tab] } ?? [])).first { $0.webView === webView }
    }

    func requestSessionSave() {
        guard !isPrivate, !isExtensionWindow else { return }
        sessionStore?.requestSave()
    }

    func windowDidAppear() { isClosed = false }

    func windowDidClose() {
        guard !isClosed else { return }
        isClosed = true
        cancelTidyingTabs()
        titleTasks.values.forEach { $0.cancel() }
        for tab in tabs { tab.stopLoading() }
        dismissPeek()
    }

    var activeTab: BrowserTab? {
        tab(withID: activeTabID)
    }

    var focusedPage: BrowserTab? { peek?.tab ?? activeTab }

    func updateWindowTitle() {
        // WindowGroup titles belong to SwiftUI's navigationTitle. Only the
        // independently hosted extension windows need the AppKit assignment.
        guard isExtensionWindow else { return }
        let title = activeTab?.title ?? "Browser"
        if window?.title != title { window?.title = title }
    }

    var canReopenClosedTab: Bool {
        !closedTabs.isEmpty
    }

    var unpinnedTabs: [BrowserTab] {
        let ids = Set(pinnedPages.items.map(\.id))
        return tabs.filter { !ids.contains($0.pinnedPageID ?? $0.id) }
    }

    var regularTabs: [BrowserTab] {
        let saved = Set(folders.pages.map(\.id))
        return unpinnedTabs.filter { !saved.contains($0.folderPageID ?? $0.id) }
    }

    func requestNewFolder(parentID: UUID? = nil, containing tab: BrowserTab? = nil) {
        folderEditorRequest = FolderEditorRequest(parentID: parentID, tabID: tab?.id)
    }

    func saveFolder(_ request: FolderEditorRequest, title: String, parentID: UUID?, symbol: String,
                    emoji: String, color: FolderColor) throws {
        if let id = request.folderID {
            try folders.updateFolder(id, title: title, parentID: parentID, symbol: symbol, emoji: emoji, color: color)
        } else {
            let tab = tab(withID: request.tabID)
            let initialPage = tab.flatMap { tab in tab.url.map { (url: $0, title: tab.title) } }
            let folder = try folders.createFolder(title: title, parentID: parentID, symbol: symbol,
                                                  emoji: emoji, color: color, initialPage: initialPage)
            if let tab, let page = folders.pages.first(where: { $0.parentID == folder.id }) {
                if let old = tab.folderPageID { try folders.removePage(old) }
                tab.folderPageID = page.id
                tab.pinnedPageID = nil
                tab.temporarySection = nil
                tidySavedTabTitle(tab)
            }
        }
    }

    func changeFolders(_ action: () throws -> Void) {
        do { try action() }
        catch { if let window { NSAlert(error: error).beginSheetModal(for: window) } }
    }

    func moveToFolder(_ tab: BrowserTab, parentID: UUID?, before: UUID? = nil) {
        if peek?.tab === tab { expandPeek() }
        changeFolders {
            if let id = tab.folderPageID, folders.item(id) != nil {
                try folders.move(id, to: parentID, before: before)
            } else if let url = tab.url {
                let page = try folders.savePage(url: url, title: tab.title, in: parentID)
                do {
                    if before != nil { try folders.move(page.id, to: parentID, before: before) }
                    if let essentialID = tab.pinnedPageID { try pinnedPages.remove(essentialID) }
                } catch { try? folders.removePage(page.id); throw error }
                tab.folderPageID = page.id
                tab.pinnedPageID = nil
                tab.temporarySection = nil
                tidySavedTabTitle(tab)
            }
        }
    }

    func openFolderPage(_ page: TabFolderItem) {
        guard page.kind == .page, folders.item(page.id) != nil, let url = page.url else { return }
        if let existing = tabs.first(where: { $0.folderPageID == page.id }) {
            activeTabID = existing.id
        } else {
            let tab = adopt(BrowserTab(url: url, title: page.title, interactionState: nil, browser: self))
            tab.folderPageID = page.id
            tabs.append(tab)
            BrowserExtensions.shared.didOpen(tab)
            activeTabID = tab.id
        }
    }

    func moveFolderPageToTemporaryTabs(_ page: TabFolderItem) {
        if let tab = tabs.first(where: { $0.folderPageID == page.id }) { cancelSavedTitle(for: tab) }
        changeFolders {
            try folders.removePage(page.id)
            if let tab = tabs.first(where: { $0.folderPageID == page.id }) {
                tab.folderPageID = nil
            } else if let url = page.url {
                let tab = adopt(BrowserTab(url: url, title: page.title, interactionState: nil, browser: self))
                tabs.append(tab)
                BrowserExtensions.shared.didOpen(tab)
            }
        }
    }

    /// Folder headers and the saved tab rows inside them provide feedback on actual target entry.
    func didEnterFolderRowDropTarget(_ targetID: UUID) {
        guard let target = folders.item(targetID),
              target.kind == .folder || target.parentID.flatMap({ folders.item($0) })?.kind == .folder,
              let payload = tabDrag.payload, let source = SidebarDragItem(payload) else { return }
        let parentID = target.kind == .folder ? target.id : target.parentID
        let url: URL?
        switch source {
        case .tab(let id):
            guard let tab = tab(withID: id), !tab.isNewTab, tab.folderPageID != targetID else { return }
            url = tab.url
        case .pinned(let id):
            guard id != targetID, let page = folders.item(id), page.kind == .page,
                  folders.canMove(id, to: parentID) else { return }
            url = page.url
        case .essential(let id):
            url = pinnedPages.items.first { $0.id == id }?.url
        default: return
        }
        guard let url, PinnedPageStore.valid(url) else { return }
        reorderFeedback()
    }

    @discardableResult
    func acceptFolderDrop(_ payload: String, parentID: UUID?, before: UUID? = nil) -> Bool {
        let prefix = "browser-folder:"
        if payload.hasPrefix(prefix), let id = UUID(uuidString: String(payload.dropFirst(prefix.count))),
           let moving = folders.item(id), folders.canMove(id, to: parentID) {
            let previous = folders.items
            changeFolders { try folders.move(id, to: parentID, before: before) }
            if moving.kind == .page, previous != folders.items { reorderFeedback() }
            return previous != folders.items
        }
        if let id = UUID(uuidString: payload), let tab = tab(withID: id),
           let url = tab.url, PinnedPageStore.valid(url) {
            moveToFolder(tab, parentID: parentID, before: before)
            return true
        }
        return false
    }

    /// Ignore geometry from before an animated move, rather than swapping back.
    func crossDraggedTab(_ source: String, past target: String, direction: Int) {
        guard let source = SidebarDragItem(source), let target = SidebarDragItem(target) else { return }
        switch (source, target) {
        case (.tab(let id), .tab(let targetID)):
            guard let from = tabs.firstIndex(where: { $0.id == id }), let to = tabs.firstIndex(where: { $0.id == targetID }),
                  tabs[from].pinnedPageID == nil, tabs[to].pinnedPageID == nil,
                  tabs[from].temporarySection?.id == tabs[to].temporarySection?.id,
                  direction > 0 ? to > from : to < from else { return }
            _ = withAnimation(.snappy(duration: 0.18)) { moveTab(id, to: to, haptic: true) }
        case (.pinned(let id), .pinned(let targetID)):
            guard let page = folders.item(id), let other = folders.item(targetID), page.parentID == other.parentID,
                  page.kind == .folder || other.kind == .page else { return }
            let siblings = folders.items.filter { $0.parentID == page.parentID }
            guard let from = siblings.firstIndex(where: { $0.id == id }), let to = siblings.firstIndex(where: { $0.id == targetID }),
                  direction > 0 ? to > from : to < from else { return }
            // Child-page rows already pulse on entry, including when this crossing moves the row.
            let usesRowEntryFeedback = page.kind == .page && other.kind == .page
                && other.parentID.flatMap({ folders.item($0) })?.kind == .folder
            _ = withAnimation(.snappy(duration: 0.18)) {
                reorderPinnedItem(id, past: targetID, haptic: !usesRowEntryFeedback)
            }
        case (.section(let id), .section(let targetID)):
            reorderTemporarySection(id, past: targetID, direction: direction)
        case (.section(let id), .tab(let targetID)):
            if let other = regularTabs.first(where: { $0.id == targetID }) {
                reorderTemporarySection(id, past: other.temporarySection?.id ?? other.id, direction: direction)
            }
        default: break
        }
    }

    func finishDraggedTab(_ source: String, over target: String?) {
        if let target, target.hasPrefix(TabReorderController.pageSplitPrefix) {
            let pieces = target.dropFirst(TabReorderController.pageSplitPrefix.count).split(separator: ":", maxSplits: 1)
            guard pieces.count == 2, let edge = SplitEdge(rawValue: String(pieces[0])),
                  canSplitDrag(source, with: String(pieces[1])), let item = SidebarDragItem(source),
                  let first = dragTab(item), let targetID = UUID(uuidString: String(pieces[1])) else { return }
            makeSplit(first.id, with: targetID, placement: edge)
            return
        }
        if let target, target.hasPrefix(TabReorderController.splitPrefix) {
            let destination = String(target.dropFirst(TabReorderController.splitPrefix.count))
            guard canSplitDrag(source, with: destination), let a = SidebarDragItem(source), let b = SidebarDragItem(destination),
                  let first = dragTab(a), let second = dragTab(b) else { return }
            makeSplit(first.id, with: second.id)
            return
        }
        guard let source = SidebarDragItem(source), let rawTarget = target, let target = SidebarDragItem(rawTarget) else { return }
        switch target {
        case .essentials, .essential:
            if let page = pinnedDragPage(source) { pinSavedPageToEssentials(page) }
            else if let tab = dragTab(source) { pin(tab) }
        case .pinnedRoot:
            if case .section(let id) = source { pinTemporarySection(id); return }
            if case .pinned(let id) = source { _ = acceptFolderDrop(SidebarDragItem.pinned(id).payload, parentID: nil) }
            else if let tab = dragTab(source) { moveToFolder(tab, parentID: nil) }
        case .pinned(let targetID):
            guard let item = folders.item(targetID) else { return }
            let parent = item.kind == .folder ? item.id : item.parentID
            if case .section(let id) = source { pinTemporarySection(id, parentID: parent); return }
            if case .pinned(let id) = source {
                if let page = folders.item(id), item.kind == .page, page.parentID == item.parentID { return }
                _ = acceptFolderDrop(SidebarDragItem.pinned(id).payload, parentID: parent, before: item.kind == .page ? item.id : nil)
            } else if let tab = dragTab(source) { moveToFolder(tab, parentID: parent, before: item.kind == .page ? item.id : nil) }
        case .temporaryRoot:
            if let tab = regularizeDragPage(source) {
                tab.temporarySection = nil
                requestSessionSave()
            }
        case .section(let id):
            if case .section = source { return }
            if let tab = regularizeDragPage(source) { _ = moveTemporaryTab(tab.id, toSection: id) }
        case .tab(let targetID):
            guard let other = tab(withID: targetID) else { return }
            if let folderID = other.folderPageID {
                finishDraggedTab(source.payload, over: SidebarDragItem.pinned(folderID).payload); return
            }
            if case .section = source { return }
            guard let tab = regularizeDragPage(source), tab.id != other.id,
                  let to = tabs.firstIndex(where: { $0.id == other.id }) else { return }
            _ = moveTab(tab.id, to: to, haptic: true)
        }
    }

    @discardableResult
    func reorderSavedPage(_ id: UUID, past targetID: UUID) -> Bool { reorderPinnedItem(id, past: targetID) }

    @discardableResult
    func reorderPinnedItem(_ id: UUID, past targetID: UUID, haptic: Bool = true) -> Bool {
        guard let page = folders.item(id), let target = folders.item(targetID),
              page.parentID == target.parentID, id != targetID else { return false }
        let siblings = folders.items.filter { $0.parentID == page.parentID }
        guard let source = siblings.firstIndex(where: { $0.id == id }),
              let destination = siblings.firstIndex(where: { $0.id == targetID }) else { return false }
        let before = destination > source ? (siblings.indices.contains(destination + 1) ? siblings[destination + 1].id : nil) : targetID
        let previous = folders.items
        changeFolders { try folders.move(id, to: page.parentID, before: before) }
        guard previous != folders.items else { return false }
        if haptic { reorderFeedback() }
        return true
    }

    func canPin(_ tab: BrowserTab) -> Bool {
        guard let url = tab.url, PinnedPageStore.valid(url) else { return false }
        return pinnedPages.items.count < PinnedPageStore.limit || pinnedPages.items.contains { $0.url == url }
    }

    func pin(_ tab: BrowserTab) {
        if peek?.tab === tab { expandPeek() }
        guard let url = tab.url else { return }
        pinToEssentials(url: url, title: tab.title, folderPageID: tab.folderPageID, tab: tab)
    }

    func pinSavedPageToEssentials(_ page: TabFolderItem) {
        guard page.kind == .page, let url = page.url else { return }
        pinToEssentials(url: url, title: page.title, folderPageID: page.id,
                        tab: tabs.first { $0.folderPageID == page.id })
    }

    private func pinToEssentials(url: URL, title: String, folderPageID: UUID?, tab: BrowserTab?) {
        if let tab { cancelSavedTitle(for: tab) }
        let previousIDs = Set(pinnedPages.items.map(\.id))
        do {
            let page = try pinnedPages.pin(url: url, title: title)
            do { if let folderPageID { try folders.removePage(folderPageID) } }
            catch { if !previousIDs.contains(page.id) { try? pinnedPages.remove(page.id) }; throw error }
            tabs.filter { $0.pinnedPageID == page.id }.forEach { $0.pinnedPageID = nil }
            tab?.folderPageID = nil
            tab?.temporarySection = nil
            tab?.pinnedPageID = page.id
            requestSessionSave()
        } catch { reportPinnedPageError(error) }
    }

    func unpin(_ page: PinnedPage) {
        let existing = tabs.filter { $0.pinnedPageID == page.id }
        let created = existing.isEmpty ? materializeEssential(page) : nil
        let retained = existing + (created.map { [$0] } ?? [])
        retained.forEach { $0.pinnedPageID = nil }
        // Persist the destination before removing its durable Essential descriptor.
        requestSessionSave()
        do { try pinnedPages.remove(page.id) }
        catch {
            retained.first?.pinnedPageID = page.id
            reportPinnedPageError(error)
        }
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
            let tab = adopt(BrowserTab(url: page.url, title: page.title, interactionState: nil, browser: self))
            tab.pinnedPageID = page.id
            tabs.append(tab)
            BrowserExtensions.shared.didOpen(tab)
            activeTabID = tab.id
        }
    }

    var isBlank: Bool { tabs.count == 1 && tabs[0].isNewTab }

    func windowSession() -> WindowSession {
        let metadata = BrowserSessionSnapshot(browser: self)
        return WindowSession(tabs: zip(tabs, metadata.tabs).map { tab, saved in
            TabSession(url: saved.url, title: saved.title, interactionState: saved.url == nil ? nil : tab.interactionState as? Data,
                       pinnedPageID: saved.pinnedPageID, folderPageID: saved.folderPageID,
                       temporarySection: saved.temporarySection)
        }, selectedIndex: metadata.selectedIndex, splits: metadata.splits)
    }

    func restoreSession(_ session: WindowSession) {
        let legacy = BrowserSessionSnapshot(tabs: session.tabs.map {
            BrowserSessionSnapshot.Tab(url: $0.url, title: $0.title, pinnedPageID: $0.pinnedPageID,
                                       folderPageID: $0.folderPageID, temporarySection: $0.temporarySection)
        }, selectedIndex: session.selectedIndex)
        restoreSession(legacy, interactionStates: session.tabs.map(\.interactionState), splits: session.splits)
    }

    func restoreSession(_ session: BrowserSessionSnapshot, interactionStates: [Data?] = [],
                        splits: [BrowserSessionSnapshot.Split]? = nil) {
        guard !session.tabs.isEmpty else { return }
        let previous = tabs
        var boundPins = Set<UUID>()
        var boundFolders = Set<UUID>()
        tabs = session.tabs.enumerated().map { index, saved in
            guard let url = saved.url, ["https", "http", "file", "webkit-extension"].contains(url.scheme ?? "") else { return makeTab() }
            let tab = adopt(BrowserTab(url: url, title: saved.title, interactionState: interactionStates.indices.contains(index) ? interactionStates[index] : nil, browser: self, restoresVisit: true))
            let page = saved.folderPageID == nil ? (pinnedPages.items.first { $0.id == saved.pinnedPageID }
                ?? pinnedPages.items.first { $0.url == url }) : nil
            if let page, boundPins.insert(page.id).inserted { tab.pinnedPageID = page.id }
            if tab.pinnedPageID == nil {
                let folderPage = folders.pages.first { $0.id == saved.folderPageID }
                    ?? folders.pages.first { $0.url == url && !boundFolders.contains($0.id) }
                if let folderPage, boundFolders.insert(folderPage.id).inserted { tab.folderPageID = folderPage.id }
            }
            if tab.folderPageID == nil && tab.pinnedPageID == nil { tab.temporarySection = saved.temporarySection }
            return tab
        }
        previous.forEach { BrowserExtensions.shared.didClose($0) }
        tabs.forEach { BrowserExtensions.shared.didOpen($0) }
        restoreSplits(splits ?? session.splits ?? [])
        activeTabID = tabs[min(max(0, session.selectedIndex), tabs.count - 1)].id
    }

    func tab(withID id: UUID?) -> BrowserTab? {
        guard let id else { return nil }
        if peek?.tab.id == id { return peek?.tab }
        return tabs.first { $0.id == id }
    }

    func shouldPeek(_ url: URL, from tab: BrowserTab) -> Bool {
        guard tab.id == activeTabID, let home = tab.pinnedHomeURL, PinnedNavigation.isWebURL(url),
              !isExtensionWindow else { return false }
        let enabled = UserDefaults.standard.object(forKey: PinnedNavigation.peekEnabledKey) as? Bool ?? true
        return enabled && !PinnedNavigation.isSameSite(url, as: home)
    }

    /// Kept outside the tab/session list until expanded, with the normal WebKit
    /// profile, extensions, permissions and navigation delegate.
    @discardableResult
    func openPeek(from opener: BrowserTab, request: URLRequest? = nil,
                  configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        dismissPeek()
        if let view = opener.webView { LinkPreviewController.shared.dismiss(for: view) }
        let tab = makeTab(configuration: configuration ?? makeConfiguration())
        tab.openerID = opener.id
        tab.isPopUp = configuration != nil
        tab.isNewTab = false
        peek = PeekPage(openerID: opener.id, tab: tab)
        BrowserExtensions.shared.didOpen(tab)
        BrowserExtensions.shared.didActivate(tab, previous: opener)
        if let request { tab.webView?.load(request) }
        return tab
    }

    func dismissPeek() {
        guard let previous = peek else { return }
        peek = nil
        previous.tab.stopWaitingForSelection()
        previous.tab.stopLoading()
        BrowserExtensions.shared.didClose(previous.tab)
        if let activeTab { BrowserExtensions.shared.didActivate(activeTab, previous: nil) }
        window?.makeFirstResponder(activeTab?.webView)
    }

    /// Adopt the existing web view, preserving its history, forms and load.
    func expandPeek() {
        guard let previous = peek else { return }
        peek = nil
        let insertion = tabs.firstIndex { $0.id == previous.openerID }.map { $0 + 1 } ?? tabs.count
        tabs.insert(previous.tab, at: insertion)
        activeTabID = previous.tab.id
        previous.tab.didBecomeSelected()
        requestSessionSave()
    }

    private func makeTab(configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        if let configuration { return adopt(BrowserTab(configuration: configuration, browser: self)) }
        return adopt(BrowserTab(newTabIn: self))
    }

    private func adopt(_ tab: BrowserTab) -> BrowserTab {
        tab.browser = self
        tab.didAttachToBrowser()
        return tab
    }

    func addTab(configuration: WKWebViewConfiguration? = nil, focusAddress: Bool = true) {
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
            : adopt(BrowserTab(url: original.url, title: original.pageTitle, interactionState: original.interactionState, browser: self, restoresVisit: true))
        tabs.insert(tab, at: index + 1)
        BrowserExtensions.shared.didOpen(tab)
        activeTabID = tab.id
        if tab.isNewTab { requestAddressFocus() }
    }

    @discardableResult
    func moveTab(_ id: UUID, to destinationIndex: Int, haptic: Bool = false) -> Bool {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == id }),
              tabs.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return false }
        tabs[sourceIndex].invalidateGroupingOrder()
        tabs[sourceIndex].temporarySection = tabs[destinationIndex].temporarySection
        tabs.move(fromOffsets: IndexSet(integer: sourceIndex),
                  toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex)
        if !isPrivate { BrowserExtensions.shared.controller.didMoveTab(tabs[destinationIndex], from: sourceIndex, in: self) }
        if haptic { reorderFeedback() }
        return true
    }

    func closeOtherTabs(than id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let retained = Set(split(containing: id)?.tabIDs ?? [id])
        let closingTabs = tabs.filter { !retained.contains($0.id) }
        for tab in closingTabs {
            rememberClosedTab(tab)
        }
        tabs.removeAll { !retained.contains($0.id) }
        pruneSplits()
        closingTabs.forEach { BrowserExtensions.shared.didClose($0) }
        activeTabID = id
    }

    func closeTabs(after id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTabs = Array(tabs[(index + 1)...])
        closingTabs.forEach(rememberClosedTab)
        let closingIDs = Set(closingTabs.map(\.id))
        tabs.removeAll { closingIDs.contains($0.id) }
        pruneSplits()
        closingTabs.forEach { BrowserExtensions.shared.didClose($0) }
        if let activeTabID, closingIDs.contains(activeTabID) {
            self.activeTabID = id
        }
    }

    func closeActiveTab() {
        if peek != nil { dismissPeek(); return }
        guard let activeTabID else { return }
        if let tab = activeTab, tab.isAwayFromPinnedPage { tab.returnToPinnedPage(); return }
        closeTab(activeTabID)
    }

    func closeTab(_ id: UUID) {
        if peek?.tab.id == id { dismissPeek(); return }
        if peek?.openerID == id { dismissPeek() }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let nextPane = split(containing: id)?.tabIDs.first { $0 != id }
        rememberClosedTab(tabs[index])
        let closed = tabs.remove(at: index)
        pruneSplits()
        BrowserExtensions.shared.didClose(closed)
        if tabs.isEmpty {
            if isExtensionWindow {
                activeTabID = nil
                window?.close()
            } else {
                addTab()
            }
        } else if activeTabID == id {
            activeTabID = nextPane ?? tabs[min(index, tabs.count - 1)].id
        }
    }

    /// Remembers a closing tab so it can reopen, and dismisses the panels its page is waiting to show.
    private func rememberClosedTab(_ tab: BrowserTab) {
        cancelSavedTitle(for: tab)
        if renamingSavedPageID == tab.folderPageID { renamingSavedPageID = nil }
        tab.stopWaitingForSelection()
        tab.stopLoading()
        let isBlank = tab.isNewTab || tab.url == nil
        closedTabs.append(ClosedTab(url: isBlank ? nil : tab.url, title: tab.pageTitle,
                                    interactionState: isBlank ? nil : tab.interactionState, folderPageID: tab.folderPageID))
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
                                   interactionState: closedTab.interactionState, browser: self, restoresVisit: true))
        if let id = closedTab.folderPageID, folders.item(id) != nil,
           !tabs.contains(where: { $0.folderPageID == id }) { tab.folderPageID = id }
        tabs.append(tab)
        BrowserExtensions.shared.didOpen(tab)
        activeTabID = tab.id
    }

    /// Opens a tab after the opener and any tabs it opened before, like a page's pop-up or a ⌘-clicked link.
    /// Pass WebKit's configuration for a pop-up, or a request to load.
    @discardableResult
    func openChildTab(of opener: BrowserTab, configuration: WKWebViewConfiguration? = nil,
                      loading request: URLRequest? = nil, select: Bool) -> BrowserTab {
        let tab = makeTab(configuration: configuration ?? makeConfiguration())
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
        let visible = tabs.filter { !isSplitCompanion($0) }
        guard visible.indices.contains(index) else { return }
        selectRepresentedTab(visible[index])
    }

    func selectLastTab() {
        selectTab(at: tabs.filter { !isSplitCompanion($0) }.count - 1)
    }

    func switchTab(by offset: Int) {
        let visible = tabs.filter { !isSplitCompanion($0) }
        let current = activeSplit?.anchorID ?? activeTabID
        guard let currentIndex = visible.firstIndex(where: { $0.id == current }), !visible.isEmpty else { return }
        selectTab(at: (currentIndex + offset % visible.count + visible.count) % visible.count)
    }

    func open(_ url: URL, inNewTab: Bool = false) {
        dismissPeek()
        if inNewTab || activeTab == nil {
            let tab = makeTab()
            tabs.append(tab)
            BrowserExtensions.shared.didOpen(tab)
            activeTabID = tab.id
        }
        activeTab?.load(url)
    }

    /// Opens links from other apps in new tabs, using the window's only tab if it's a new tab.
    func openInNewTabs(_ urls: [URL]) {
        for url in urls {
            open(url, inNewTab: !isBlank)
        }
    }

    func navigate(to input: String) {
        guard let url = BrowserAddress.url(for: input) else { return }
        dismissPeek()
        activeTab?.load(url)
    }

    func reload() {
        if let peek { peek.tab.reload(); return }
        guard let activeTabID else { return }
        reloadTab(activeTabID)
    }

    func reloadTab(_ id: UUID) {
        guard let tab = tab(withID: id), !tab.isNewTab else { return }
        tab.reload()
    }

    func stopLoading() {
        (peek?.tab ?? activeTab)?.webView?.stopLoading()
    }

    func goBack() {
        (peek?.tab ?? activeTab)?.goBack()
    }

    func goForward() {
        (peek?.tab ?? activeTab)?.goForward()
    }

    func go(to item: WKBackForwardListItem) {
        activeTab?.invalidateNavigation()
        activeTab?.webView?.go(to: item)
    }

    func requestAddressFocus() {
        dismissPeek()
        chromeHover?.addressFocusRequested()
        addressFocusRequest += 1
    }

    // MARK: Find

    /// Shows the find bar, starting with the text last searched for in any app.
    func showFindBar() {
        guard let tab = focusedPage, !tab.isNewTab else { return }
        if tab.findText.isEmpty, let text = NSPasteboard(name: .find).string(forType: .string) {
            tab.findText = text
        }
        tab.isFindBarVisible = true
        findFocusRequest += 1
    }

    func findNext(backwards: Bool = false) {
        guard let tab = focusedPage, !tab.isNewTab else { return }
        guard !tab.findText.isEmpty else { return showFindBar() }
        tab.isFindBarVisible = true
        tab.find(backwards: backwards)
    }

    func useSelectionForFind() {
        guard let tab = focusedPage, !tab.isNewTab else { return }
        Task {
            guard let text = await tab.selectedText(), !text.isEmpty else { return }
            if !isPrivate {
                let pasteboard = NSPasteboard(name: .find)
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            tab.findText = text
            tab.isFindBarVisible = true
            tab.find()
        }
    }

    func closeFindBar() {
        guard let tab = focusedPage else { return }
        tab.isFindBarVisible = false
        tab.focusPage()
    }

    // MARK: Zoom

    var canZoom: Bool {
        focusedPage.map { !$0.isNewTab && !$0.isSuspended } ?? false
    }

    func zoomIn() {
        guard canZoom, let tab = focusedPage else { return }
        tab.setZoom(ZoomStore.level(after: tab.pageZoom))
    }

    func zoomOut() {
        guard canZoom, let tab = focusedPage else { return }
        tab.setZoom(ZoomStore.level(before: tab.pageZoom))
    }

    func resetZoom() {
        guard canZoom else { return }
        focusedPage?.setZoom(1)
    }

    // MARK: Print

    /// Prints the active page, with the print panel as a sheet on its window.
    func printActivePage() {
        guard let tab = focusedPage, !tab.isNewTab, let webView = tab.webView, let window = webView.window else { return }
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // WebKit prints blank pages unless the operation's view has a size.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func toggleAddressFocus() {
        guard chromeHover?.addressIsFocused == true
                || addressFocusRequest != consumedAddressFocusRequest else {
            requestAddressFocus()
            return
        }

        consumedAddressFocusRequest = addressFocusRequest
        // Cancel any queued focus application before returning the field editor to the page.
        let field = (window?.firstResponder as? AddressField)
            ?? ((window?.firstResponder as? NSTextView)?.delegate as? AddressField)
        field?.requestFocus(0)
        window?.makeFirstResponder(activeTab?.webView)
        chromeHover?.dismissAddressFocus()
    }

    func showWebInspector() {
        guard let tab = focusedPage, !tab.isNewTab, let webView = tab.webView else { return }
        WebInspector.show(for: webView)
    }

    /// Background tabs that can be suspended to free memory, least recently used first. A pop-up and its opener
    /// can script each other, so neither is suspended while both are open.
    var suspendableTabs: [BrowserTab] {
        var linkedIDs = Set<UUID>()
        for tab in tabs where tab.isPopUp {
            guard let openerID = tab.openerID, self.tab(withID: openerID) != nil else { continue }
            linkedIDs.formUnion([tab.id, openerID])
        }
        return tabs
            .filter { !visibleTabIDs.contains($0.id) && $0.canSuspend && !linkedIDs.contains($0.id) }
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
    static func url(for input: String, searchEngine: SearchEngine = .current) -> URL? {
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

        return searchEngine.searchURL(for: text)
    }
}

extension BrowserModel {
    struct TemporaryTabGroup: Identifiable {
        let id: UUID
        let section: TemporaryTabSection?
        var tabs: [BrowserTab]
    }

    var temporaryTabGroups: [TemporaryTabGroup] {
        var result: [TemporaryTabGroup] = []
        var indices: [UUID: Int] = [:]
        for tab in regularTabs where !isSplitCompanion(tab) {
            let id = tab.temporarySection?.id ?? tab.id
            if let index = indices[id] { result[index].tabs.append(tab) }
            else {
                indices[id] = result.count
                result.append(TemporaryTabGroup(id: id, section: tab.temporarySection, tabs: [tab]))
            }
        }
        return result
    }

    func setTemporarySectionExpanded(_ id: UUID, expanded: Bool) {
        for tab in regularTabs where tab.temporarySection?.id == id {
            guard var section = tab.temporarySection, section.isExpanded != expanded else { continue }
            section.isExpanded = expanded
            tab.temporarySection = section
        }
        requestSessionSave()
    }

    func removeTemporarySection(_ id: UUID) {
        regularTabs.filter { $0.temporarySection?.id == id }.forEach { $0.temporarySection = nil }
        requestSessionSave()
    }

    @discardableResult
    func moveTemporaryTab(_ id: UUID, toSection sectionID: UUID) -> Bool {
        guard let tab = regularTabs.first(where: { $0.id == id }), tab.temporarySection?.id != sectionID,
              let destination = regularTabs.first(where: { $0.temporarySection?.id == sectionID })?.temporarySection else { return false }
        let previous = tabs.map(\.id)
        let groups = temporaryTabGroups
        tab.invalidateGroupingOrder()
        tab.temporarySection = destination
        let order = groups.flatMap { group -> [UUID] in
            let members = group.tabs.filter { $0.id != id }.map(\.id)
            return group.section?.id == sectionID ? members + [id] : members
        }
        reorderTemporaryTabs(order)
        if previous != tabs.map(\.id) { reorderFeedback() }
        return true
    }

    /// Value-only state: undo does not keep a tab or its web view alive.
    private struct TidyTabState: Equatable {
        let id: UUID
        let identity: ObjectIdentifier
        let url: URL?
        let contentNavigationRevision: Int
        let groupingRevision: Int
        let section: TemporaryTabSection?

        @MainActor init(_ tab: BrowserTab) {
            id = tab.id
            identity = ObjectIdentifier(tab)
            url = tab.url
            contentNavigationRevision = tab.contentNavigationRevision
            groupingRevision = tab.groupingRevision
            section = tab.temporarySection
        }
    }

    private struct TidyUndoSnapshot {
        let before: [TidyTabState]
        let after: [TidyTabState]
    }

    private var tidyCandidates: [BrowserTab] {
        regularTabs.filter {
            $0.pinnedPageID == nil && $0.folderPageID == nil
                && !$0.isNewTab && $0.url.map(PinnedPageStore.valid) == true
        }
    }

    private func matchingTidyTabs(_ states: [TidyTabState]) -> Set<UUID> {
        let current = Dictionary(uniqueKeysWithValues: tidyCandidates.map { ($0.id, TidyTabState($0)) })
        return Set(states.filter { current[$0.id] == $0 }.map(\.id))
    }

    var canTidyTabs: Bool { !isPrivate && tidyCandidates.count > 6 }

    var canUndoTidyTabs: Bool {
        guard !isPrivate, !isTidyingTabs, let tidyUndo else { return false }
        return !matchingTidyTabs(tidyUndo.after).isEmpty
    }

    func undoTidyTabs() {
        guard !isPrivate, !isTidyingTabs, let snapshot = tidyUndo else { return }
        let eligible = matchingTidyTabs(snapshot.after)
        guard !eligible.isEmpty else { return }
        tidyUndo = nil
        for state in snapshot.before where eligible.contains(state.id) {
            tab(withID: state.id)?.temporarySection = state.section
        }
        // Only replace eligible slots. New, saved, navigated and manually edited
        // tabs stay where they are now; closed tabs are never recreated.
        reorderTemporaryTabs(snapshot.before.map(\.id), eligible: eligible)
    }

    func tidyTemporaryTabs() {
        guard canTidyTabs, !isTidyingTabs else { return }
        if let reason = BrowserIntelligence.unavailableReason { intelligenceError = reason; return }
        tidyTemporaryTabs { try await LocalIntelligence.shared.tidy($0) }
    }

    /// The provider seam keeps regression tests independent of model availability.
    func tidyTemporaryTabs(using provider: @escaping @MainActor ([TidyTabInput]) async throws -> [TidyTabAssignment]) {
        guard canTidyTabs, !isTidyingTabs else { return }
        let candidates = tidyCandidates
        let state = candidates.map(TidyTabState.init)
        let input = candidates.compactMap { tab in
            tab.url.map { TidyTabInput(id: tab.id, title: tab.pageTitle, url: $0) }
        }
        isTidyingTabs = true
        intelligenceError = nil
        tidyTask = Task { [weak self] in
            do {
                let result = try await provider(input)
                try Task.checkCancellation()
                guard let self else { return }
                self.applyTidyTabs(result, eligible: self.matchingTidyTabs(state))
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { self?.intelligenceError = "Couldn’t tidy tabs. \(error.localizedDescription)" }
            }
            self?.isTidyingTabs = false
            self?.tidyTask = nil
        }
    }

    func cancelTidyingTabs() { tidyTask?.cancel() }

    /// Invalid, repeated or vanished IDs cannot remove or duplicate any tab.
    func applyTidyTabs(_ result: [TidyTabAssignment], eligible: Set<UUID>) {
        guard !isPrivate else { return }
        let candidates = tidyCandidates.filter { eligible.contains($0.id) }
        let current = Set(candidates.map(\.id))
        var sections: [UUID: TemporaryTabSection] = [:], order: [UUID] = []
        for assignment in result where !assignment.section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            for id in assignment.tabIDs where current.contains(id) && sections[id] == nil {
                sections[id] = assignment.section
                order.append(id)
            }
        }
        // An empty or wholly invalid response must not erase existing groups or undo.
        guard !order.isEmpty else { return }
        let before = candidates.map(TidyTabState.init)
        for tab in candidates { tab.temporarySection = sections[tab.id] }
        order += candidates.filter { sections[$0.id] == nil }.map(\.id)
        reorderTemporaryTabs(order, eligible: current)
        let after = tidyCandidates.filter { current.contains($0.id) }.map(TidyTabState.init)
        if before != after {
            tidyUndo = TidyUndoSnapshot(before: before, after: after)
        }
    }

    private func reorderTemporaryTabs(_ ids: [UUID], eligible: Set<UUID>? = nil) {
        let candidates = regularTabs.filter { eligible?.contains($0.id) ?? true }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var ordered = ids.compactMap { id in seen.insert(id).inserted ? byID[id] : nil }
        ordered += candidates.filter { !seen.contains($0.id) }
        let oldIndices = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($0.element.id, $0.offset) })
        var iterator = ordered.makeIterator()
        for index in tabs.indices where byID[tabs[index].id] != nil {
            if let next = iterator.next() { tabs[index] = next }
        }
        for (index, tab) in tabs.enumerated() {
            if !isPrivate, let old = oldIndices[tab.id], old != index {
                BrowserExtensions.shared.controller.didMoveTab(tab, from: old, in: self)
            }
        }
        requestSessionSave()
    }

    func removeTemporarySections() {
        cancelTidyingTabs()
        regularTabs.forEach { $0.temporarySection = nil }
        requestSessionSave()
    }

    func savedTabFinishedLoading(_ tab: BrowserTab) {
        guard !isPrivate, let id = tab.folderPageID, tab.loadError == nil, !isExtensionWindow, !tab.isAwayFromPinnedPage else { return }
        changeFolders { try folders.updatePageTitle(id, title: tab.pageTitle) }
        tidySavedTabTitle(tab)
    }

    func savedTabBeganLoading(_ tab: BrowserTab) {
        cancelSavedTitle(for: tab)
        if !isPrivate, !BrowserProfile.isTesting, tab.folderPageID != nil,
           UserDefaults.standard.bool(forKey: BrowserIntelligence.tidyTabTitlesKey) {
            Task { await LocalIntelligence.shared.prepare(.name) }
        }
    }

    private func cancelSavedTitle(for tab: BrowserTab) {
        titleTasks.removeValue(forKey: tab.id)?.cancel()
        titleTaskTokens.removeValue(forKey: tab.id)
        if let id = tab.folderPageID { namingSavedPageIDs.remove(id) }
    }

    func tidySavedTabTitle(_ tab: BrowserTab) {
        guard !isPrivate else { return }
        guard !BrowserProfile.isTesting, UserDefaults.standard.bool(forKey: BrowserIntelligence.tidyTabTitlesKey),
              !tab.isLoading, !tab.isNewTab, tab.loadError == nil, tab.pinnedPageID == nil,
              let id = tab.folderPageID, let page = folders.item(id), page.nameSource == nil,
              let url = tab.url, PinnedPageStore.valid(url), !tab.pageTitle.isEmpty, titleTasks[tab.id] == nil,
              BrowserIntelligence.unavailableReason == nil else { return }
        let originalTitle = tab.pageTitle
        let token = UUID()
        titleTaskTokens[tab.id] = token
        namingSavedPageIDs.insert(id)
        titleTasks[tab.id] = Task { [weak self, weak tab] in
            defer {
                if let self, let tab, self.titleTaskTokens[tab.id] == token {
                    self.titleTasks[tab.id] = nil
                    self.titleTaskTokens[tab.id] = nil
                    self.namingSavedPageIDs.remove(id)
                }
            }
            do {
                let name = try await LocalIntelligence.shared.savedTabName(title: originalTitle, url: url)
                guard let self, let tab, !Task.isCancelled, self.tabs.contains(where: { $0 === tab }),
                      tab.folderPageID == id, tab.pinnedPageID == nil, tab.url == url, !tab.isLoading,
                      UserDefaults.standard.bool(forKey: BrowserIntelligence.tidyTabTitlesKey),
                      self.folders.item(id)?.nameSource == nil else { return }
                try self.folders.renamePage(id, title: name, source: .automatic)
            } catch { /* Automatic naming is optional; keep the page's original title on failure. */ }
        }
    }

    func renameSavedPage(_ id: UUID, to title: String) throws {
        let name = try LocalIntelligence.cleanName(title, limit: 160)
        if let tab = tabs.first(where: { $0.folderPageID == id }) { cancelSavedTitle(for: tab) }
        try folders.renamePage(id, title: name, source: .manual)
    }
}

extension BrowserModel {
    var sidebarFolderRows: [TabFolderStore.Row] {
        let companions = Set(tabs.filter(isSplitCompanion).compactMap(\.folderPageID))
        if let payload = tabDrag.payload, case .pinned(let id) = SidebarDragItem(payload), folders.item(id)?.kind == .folder {
            return folders.visibleRows(collapsing: [id]).filter { !companions.contains($0.id) }
        }
        return folders.visibleRows.filter { !companions.contains($0.id) }
    }

    func sectionIsExpanded(_ section: TemporaryTabSection?) -> Bool {
        guard let section else { return true }
        return section.isExpanded && tabDrag.payload != SidebarDragItem.section(section.id).payload
    }

    var canDragToEssentials: Bool {
        guard let payload = tabDrag.payload, let item = SidebarDragItem(payload) else { return false }
        switch item {
        case .tab(let id): return tab(withID: id).map(canPin) ?? false
        case .pinned(let id):
            guard let page = folders.item(id), page.kind == .page, let url = page.url else { return false }
            return pinnedPages.items.count < PinnedPageStore.limit || pinnedPages.items.contains { $0.url == url }
        case .essential: return true
        default: return false
        }
    }

    private func materializeEssential(_ page: PinnedPage) -> BrowserTab {
        if let existing = tabs.first(where: { $0.pinnedPageID == page.id }) { return existing }
        let tab = adopt(BrowserTab(url: page.url, title: page.title, interactionState: nil, browser: self))
        tab.pinnedPageID = page.id
        tabs.append(tab)
        BrowserExtensions.shared.didOpen(tab)
        return tab
    }

    private func pinnedDragPage(_ source: SidebarDragItem) -> TabFolderItem? {
        if case .pinned(let id) = source, let page = folders.item(id), page.kind == .page { return page }
        return nil
    }

    private func dragTab(_ source: SidebarDragItem) -> BrowserTab? {
        switch source {
        case .tab(let id): return tab(withID: id)
        case .essential(let id): return pinnedPages.items.first { $0.id == id }.map(materializeEssential)
        case .pinned(let id):
            guard let page = folders.item(id), page.kind == .page, let url = page.url else { return nil }
            if let existing = tabs.first(where: { $0.folderPageID == id }) { return existing }
            let tab = adopt(BrowserTab(url: url, title: page.title, interactionState: nil, browser: self))
            tab.folderPageID = id
            tabs.append(tab)
            BrowserExtensions.shared.didOpen(tab)
            return tab
        default: return nil
        }
    }

    private func regularizeDragPage(_ source: SidebarDragItem) -> BrowserTab? {
        guard let tab = dragTab(source) else { return nil }
        if let essential = pinnedPages.items.first(where: { $0.id == tab.pinnedPageID }) { unpin(essential) }
        if let page = folders.item(tab.folderPageID) { moveFolderPageToTemporaryTabs(page) }
        guard tab.pinnedPageID == nil, tab.folderPageID == nil else { return nil }
        return tab
    }

    func canPinTemporarySection(_ id: UUID) -> Bool {
        let members = regularTabs.filter { $0.temporarySection?.id == id }
        return !members.isEmpty && members.allSatisfy { $0.url.map(PinnedPageStore.valid) == true }
    }

    func pinTemporarySection(_ id: UUID, parentID: UUID? = nil) {
        let members = regularTabs.filter { $0.temporarySection?.id == id }
        guard canPinTemporarySection(id), let section = members.first?.temporarySection else { return }
        changeFolders {
            let saved = try folders.pinGroup(title: section.title, symbol: section.symbol, expanded: section.isExpanded,
                                            parentID: parentID, pages: members.map { (url: $0.url!, title: $0.title) })
            for (tab, page) in zip(members, saved.pages) {
                tab.folderPageID = page.id
                tab.temporarySection = nil
                tidySavedTabTitle(tab)
            }
            requestSessionSave()
        }
    }

    private func reorderTemporarySection(_ id: UUID, past targetID: UUID, direction: Int) {
        var groups = temporaryTabGroups
        guard let from = groups.firstIndex(where: { $0.id == id }), let to = groups.firstIndex(where: { $0.id == targetID }),
              direction > 0 ? to > from : to < from else { return }
        groups[from].tabs.forEach { $0.invalidateGroupingOrder() }
        groups.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        reorderTemporaryTabs(groups.flatMap { $0.tabs.map(\.id) })
        reorderFeedback()
    }
}
