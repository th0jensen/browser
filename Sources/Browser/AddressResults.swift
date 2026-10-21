import Foundation

/// Local Browser design. Results carry actions, not text to reinterpret as a command.
struct AddressResult: Identifiable, Equatable {
    struct TabDestination: Hashable {
        let id: UUID
        let instance: ObjectIdentifier
        let spaceID: UUID
        let profileID: UUID
    }

    struct SpaceDestination: Hashable {
        let id: UUID
        let profileID: UUID
    }

    enum SavedKind: Hashable { case folderPage, essential }
    enum Action: Hashable {
        case switchTab(TabDestination)
        case switchSpace(SpaceDestination)
        case openURL(AddressSuggestion)
        case navigate(URL)
        case openSavedPage(id: UUID, spaceID: UUID, kind: SavedKind, url: URL)
        case command(AddressBrowserCommand)
        case search(String)
    }

    let owner: ObjectIdentifier
    let action: Action
    let title: String
    let detail: String
    let destinationSpace: String?

    var id: Action { action }
    var actionLabel: String {
        switch action {
        case .switchTab: "Switch to Tab"
        case .switchSpace: "Switch Space"
        case .openURL(let page): page.isBookmarked ? "Open Bookmark" : "Open History Page"
        case .navigate: "Open Page"
        case .openSavedPage: "Open Saved Tab"
        case .command: "Run Command"
        case .search: "Search the Web"
        }
    }

    /// Only a navigation result can supply an inline URL completion.
    var completionSuggestion: AddressSuggestion? {
        if case .openURL(let page) = action { return page }
        return nil
    }

    var editorText: String {
        switch action {
        case .openURL(let page): page.url.absoluteString
        case .navigate(let url): url.absoluteString
        case .openSavedPage(_, _, _, let url): url.absoluteString
        case .switchTab, .switchSpace, .command: title
        case .search(let query): query
        }
    }

    var symbol: String {
        switch action {
        case .switchTab: "rectangle.on.rectangle"
        case .switchSpace: "square.grid.2x2"
        case .openURL(let page): page.isBookmarked ? "star" : "clock"
        case .navigate: "globe"
        case .openSavedPage: "pin"
        case .command: "command"
        case .search: "magnifyingglass"
        }
    }
}

/// A small allowlist of existing browser actions. Availability is checked again on execution.
enum AddressBrowserCommand: String, CaseIterable, Hashable {
    case newTab, reopenClosedTab, reload, showHistory

    var title: String {
        switch self {
        case .newTab: "New Blank Tab"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .reload: "Reload Page"
        case .showHistory: "Show All History"
        }
    }

    @MainActor func isAvailable(in browser: BrowserModel) -> Bool {
        guard !browser.isClosed, !browser.isExtensionWindow else { return false }
        return switch self {
        case .newTab: true
        case .reopenClosedTab: browser.canReopenClosedTab
        case .reload: browser.focusedPage?.isNewTab == false
        case .showHistory: !browser.isPrivate && browser.history != nil
        }
    }

    @MainActor @discardableResult
    func execute(in browser: BrowserModel) -> Bool {
        guard isAvailable(in: browser) else { return false }
        switch self {
        case .newTab: browser.addTab()
        case .reopenClosedTab: browser.reopenClosedTab()
        case .reload: browser.reload()
        case .showHistory: browser.isShowingHistory = true
        }
        return true
    }
}

@MainActor
enum AddressResults {
    static let limit = 8

    /// Synchronous, local descriptor reads only. Never restores a web view or fetches a favicon.
    static func results(for input: String, browser: BrowserModel, bookmarks: [Bookmark], now: Date = .now,
                        includesTypedAddress: Bool = false) -> [AddressResult] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !browser.isClosed else { return [] }
        let lowerQuery = query.lowercased()
        let words = lowerQuery.split(whereSeparator: \.isWhitespace)
        func matches(_ text: String) -> Bool {
            let text = text.lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        let owner = ObjectIdentifier(browser)
        var results: [AddressResult] = []
        for command in AddressBrowserCommand.allCases where command.isAvailable(in: browser) && matches(command.title) {
            results.append(AddressResult(owner: owner, action: .command(command), title: command.title,
                                         detail: "Browser command", destinationSpace: nil))
        }
        if !browser.isPrivate, !browser.isExtensionWindow {
            // Exact Space names come first even when many names share a prefix.
            // Two descriptor passes keep the small result quota without a full sort.
            for exact in [true, false] {
                guard results.count < 3 else { break }
                for space in browser.spaces.spaces {
                    guard results.count < 3 else { break }
                    guard (space.title.lowercased() == lowerQuery) == exact,
                          matches(space.title), browser.websiteDataStore(forProfileID: space.profileID) != nil else { continue }
                    let destination = AddressResult.SpaceDestination(id: space.id, profileID: space.profileID)
                    results.append(AddressResult(owner: owner, action: .switchSpace(destination), title: space.title,
                                                 detail: "Space", destinationSpace: space.title))
                }
            }
        }
        // Private/extension windows use only their own active descriptors, never ordinary Space stores.
        let scopedTabs = browser.isPrivate || browser.isExtensionWindow ? browser.tabs : browser.allTabs
        for tab in scopedTabs {
            guard results.count < 3 else { break }
            guard matches("\(tab.title) \(tab.url?.absoluteString ?? "")") else { continue }
            let destination = AddressResult.TabDestination(id: tab.id, instance: ObjectIdentifier(tab),
                                                          spaceID: tab.spaceID, profileID: tab.profileID)
            results.append(AddressResult(owner: owner, action: .switchTab(destination), title: tab.title,
                                         detail: tab.url.map(AddressSuggestions.strippedAddress) ?? "New Tab",
                                         destinationSpace: browser.isPrivate ? "Private Window"
                                            : browser.isExtensionWindow ? "Extension Window" : browser.spaces.space(tab.spaceID)?.title))
        }
        if !browser.isPrivate, !browser.isExtensionWindow {
            for space in browser.spaces.spaces {
                guard results.count < 5 else { break }
                for page in browser.folders(forSpaceID: space.id).pages {
                    guard results.count < 5 else { break }
                    guard let url = page.url, matches("\(page.title) \(url.absoluteString)") else { continue }
                    results.append(AddressResult(owner: owner, action: .openSavedPage(id: page.id, spaceID: space.id, kind: .folderPage, url: url),
                                                 title: page.title, detail: AddressSuggestions.strippedAddress(url), destinationSpace: space.title))
                }
                guard results.count < 5 else { break }
                for page in browser.pinnedPages(forSpaceID: space.id).items {
                    guard results.count < 5 else { break }
                    guard matches("\(page.title) \(page.url.absoluteString)") else { continue }
                    results.append(AddressResult(owner: owner, action: .openSavedPage(id: page.id, spaceID: space.id, kind: .essential, url: page.url),
                                                 title: page.title, detail: AddressSuggestions.strippedAddress(page.url), destinationSpace: space.title))
                }
            }
        }
        // Saved profile data is deliberately absent in private mode, even if a caller supplies it.
        let pages = browser.isPrivate ? [] : browser.history?.pages ?? []
        let saved = browser.isPrivate ? [] : bookmarks
        let typedURL = includesTypedAddress ? BrowserAddress.url(for: query) : nil
        let navigationURL = typedURL == SearchEngine.current.searchURL(for: query) ? nil : typedURL
        let reserved = navigationURL == nil ? 1 : 2
        for page in AddressSuggestions.rank(query, pages: pages, bookmarks: saved, now: now, limit: limit - reserved - results.count) {
            results.append(AddressResult(owner: owner, action: .openURL(page), title: page.displayTitle,
                                         detail: AddressSuggestions.strippedAddress(page.url), destinationSpace: nil))
        }
        if let url = navigationURL {
            results.append(AddressResult(owner: owner, action: .navigate(url), title: query,
                                         detail: url.absoluteString, destinationSpace: nil))
        }
        results.append(AddressResult(owner: owner, action: .search(query), title: query,
                                     detail: "Search with \(SearchEngine.current.title)", destinationSpace: nil))
        return results
    }

    /// A destination can attach after the edit ends (New Tab, splits, or a Space
    /// switch). Wait briefly without overriding a later selection or focus request.
    static func focusDestination(in browser: BrowserModel) -> Task<Void, Never>? {
        guard let target = browser.focusedPage, !target.isNewTab, let window = browser.window else { return nil }
        if target.webView?.window === window {
            target.focusPage()
            return nil
        }
        let responder = window.firstResponder
        let addressRequest = browser.addressFocusRequest
        let findRequest = browser.findFocusRequest
        let findVisible = target.isFindBarVisible
        return Task { @MainActor [weak browser, weak target, weak window, weak responder] in
            for _ in 0..<20 {
                guard !Task.isCancelled, let browser, let target, let window, !browser.isClosed,
                      browser.focusedPage === target, browser.window === window,
                      window.firstResponder === responder,
                      browser.addressFocusRequest == addressRequest,
                      browser.findFocusRequest == findRequest,
                      target.isFindBarVisible == findVisible else { return }
                if target.webView?.window === window { target.focusPage(); return }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    @discardableResult
    static func execute(_ result: AddressResult, in browser: BrowserModel, inNewTab: Bool = false,
                        navigationSource: BrowserTab? = nil) -> Bool {
        guard result.owner == ObjectIdentifier(browser), !browser.isClosed else { return false }
        func navigate(_ url: URL) -> Bool {
            if let source = navigationSource {
                guard source.browser === browser, source.spaceID == browser.activeSpaceID,
                      browser.focusedPage === source,
                      (browser.tabAcrossSpaces(withID: source.id) === source || browser.peek?.tab === source),
                      browser.websiteDataStore(forProfileID: source.profileID) != nil else { return false }
                // Editing a Peek navigates that same live Peek, not its opener.
                source.load(url)
            } else { browser.open(url, inNewTab: inNewTab) }
            return true
        }
        switch result.action {
        case .switchSpace(let destination):
            guard !browser.isPrivate, !browser.isExtensionWindow,
                  let space = browser.spaces.space(destination.id), space.profileID == destination.profileID,
                  browser.websiteDataStore(forProfileID: space.profileID) != nil,
                  browser.selectSpace(space.id, createsInitialTab: false) else { return false }
            browser.dismissPeek()
            if browser.activeTab?.isNewTab != false { browser.requestAddressFocus() }
        case .switchTab(let destination):
            let tab = browser.isPrivate || browser.isExtensionWindow
                ? browser.tab(withID: destination.id) : browser.tabAcrossSpaces(withID: destination.id)
            guard let tab, ObjectIdentifier(tab) == destination.instance,
                  tab.browser === browser, tab.spaceID == destination.spaceID,
                  tab.profileID == destination.profileID else { return false }
            if browser.activeSpaceID != destination.spaceID {
                guard browser.selectSpace(destination.spaceID) else { return false }
            }
            // Reassigning an already-active ID has no selection side effects.
            // Dismiss Peek only after validation so this exact page becomes focused.
            browser.dismissPeek()
            browser.activeTabID = tab.id
            if tab.isNewTab { browser.requestAddressFocus() }
        case .openURL(let page):
            guard !browser.isPrivate else { return false }
            return navigate(page.url)
        case .navigate(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else { return false }
            return navigate(url)
        case .openSavedPage(let id, let spaceID, let kind, let url):
            guard !browser.isPrivate, !browser.isExtensionWindow, browser.spaces.space(spaceID) != nil else { return false }
            switch kind {
            case .folderPage:
                guard let page = browser.folders(forSpaceID: spaceID).item(id), page.kind == .page, page.url == url,
                      browser.selectSpace(spaceID, createsInitialTab: false) else { return false }
                browser.dismissPeek()
                browser.openFolderPage(page)
            case .essential:
                guard let page = browser.pinnedPages(forSpaceID: spaceID).items.first(where: { $0.id == id && $0.url == url }),
                      browser.selectSpace(spaceID, createsInitialTab: false) else { return false }
                browser.dismissPeek()
                browser.openPinned(page)
            }
        case .command(let command): return command.execute(in: browser)
        case .search(let query):
            guard let url = SearchEngine.current.searchURL(for: query) else { return false }
            return navigate(url)
        }
        return true
    }
}
