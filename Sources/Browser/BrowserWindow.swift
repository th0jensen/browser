import SwiftUI
import WebKit

private struct AddressBarFrameKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

struct BrowserWindow: View {
    private let defaultBookmarks: BookmarkStore
    private var bookmarks: BookmarkStore {
        browser.spaces.profiles.resources(for: browser.profileID)?.bookmarks ?? defaultBookmarks
    }
    let session: SessionStore?
    @Environment(\.openWindow) private var openWindow
    @StateObject private var windowState: BrowserWindowState
    private var browser: BrowserModel { windowState.browser }
    @State private var address = ""
    /// What the user typed, without the inline completion.
    @State private var typedAddress = ""
    @State private var completionStart: Int?
    @State private var suggestions: [AddressSuggestion] = []
    @State private var selectedSuggestion: Int?
    @State private var addressBlurRequest = 0
    @State private var hoverCardTabID: UUID?
    @State private var isFullScreen = false
    @AppStorage("toolbarLayout.vertical") private var verticalToolbarLayout = Data()
    @AppStorage("toolbarLayout.horizontal") private var horizontalToolbarLayout = Data()
    @State private var toolbarItemIdentifiers: [String] = []
    @State private var restoreAddressFocusAfterFullscreen = false
    @State private var chromeHover: ChromeHoverController
    private var persistsToolbarLayout = !BrowserProfile.isTesting
    @State private var sidebarIsResizing = false
    @State private var sidebarWidthState = SidebarWidthState()
    @State private var browserWindow = BrowserWindowReference()
    @State private var toolbarPrefix = BrowserProfile.isTesting ? "BrowserToolbar.tests.\(UUID())" : "BrowserToolbar.window.\(UUID())"
    @AppStorage(ChromeCustomization.toolbarLabelStyleKey) private var toolbarLabelStyle = ToolbarLabelStyle.iconOnly
    @FocusState private var addressIsFocused: Bool
    @Environment(\.openSettings) private var openSettings
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBarVisibility = BookmarksBarVisibility.always
    private var compactToolbar: Bool {
        get { browser.chromePreferences.autoHideToolbar }
        nonmutating set { browser.chromePreferences.autoHideToolbar = newValue }
    }
    private var tabLayout: TabLayout {
        get { browser.chromePreferences.tabLayout }
        nonmutating set { browser.chromePreferences.tabLayout = newValue }
    }
    private var autoHideSidebar: Bool {
        get { browser.chromePreferences.autoHideSidebar }
        nonmutating set { browser.chromePreferences.autoHideSidebar = newValue }
    }
    @AppStorage(ChromeCustomization.widthKey) private var savedSidebarWidth = Double(BrowserChrome.sidebarWidth)
    @AppStorage(ChromeCustomization.bookmarkButtonKey) private var showsBookmarkButton = true

    private let contentBlocker = ContentBlocker.shared
    private var accent: Color { browser.isPrivate ? Color(red: 0.65, green: 0.48, blue: 0.86) : Color(red: 0.38, green: 0.49, blue: 0.54) }

    // The saved width supplies the first layout directly, including a window's injected defaults store.
    // Pointer movement stays in memory; the preference is written once when the drag ends.
    private var sidebarWidth: Double { sidebarWidthState.width(saved: savedSidebarWidth) }
    private var sidebarWidthBinding: Binding<Double> {
        Binding(get: { sidebarWidth }, set: { width in
            if let widthToSave = sidebarWidthState.update(width, isResizing: sidebarIsResizing),
               savedSidebarWidth != widthToSave {
                savedSidebarWidth = widthToSave
            }
        })
    }

    private func persistSidebarWidth() {
        guard let width = sidebarWidthState.finish() else { return }
        if savedSidebarWidth != width { savedSidebarWidth = width }
    }

    init(bookmarks: BookmarkStore, downloads: DownloadManager, history: HistoryStore? = nil,
         session: SessionStore? = nil, isPrivate: Bool = false, browsingData: BrowsingData? = nil) {
        self.defaultBookmarks = bookmarks
        self.session = session
        // StateObject constructs this once, before evaluating the window's first body.
        _windowState = StateObject(wrappedValue: BrowserWindowState(
            browser: isPrivate ? BrowserModel.makePrivate(downloads: downloads)
                : BrowserModel(downloads: downloads, history: history, passwords: .shared, createsInitialTab: false,
                               browsingData: browsingData),
            session: session, router: .shared))
        _chromeHover = State(initialValue: ChromeHoverController())
    }

    init(bookmarks: BookmarkStore, browser: BrowserModel, chromeHover: ChromeHoverController = ChromeHoverController(), persistsToolbarLayout: Bool = !BrowserProfile.isTesting) {
        self.defaultBookmarks = bookmarks
        self.session = nil
        _windowState = StateObject(wrappedValue: BrowserWindowState(browser: browser))
        _chromeHover = State(initialValue: chromeHover)
        self.persistsToolbarLayout = persistsToolbarLayout
    }

    private var nativeToolbarIdentifier: String {
        let identifier = "\(toolbarPrefix).\(tabLayout.rawValue)"
        if persistsToolbarLayout {
            ToolbarLayoutPersistence.prepareNativeConfiguration(identifier: identifier,
                data: tabLayout == .vertical ? verticalToolbarLayout : horizontalToolbarLayout)
        }
        return identifier
    }

    var body: some View {
        @Bindable var browser = windowState.browser
        // Keep the page host stable while the existing native chrome is shown or hidden.
        HStack(spacing: 0) {
            if tabLayout == .vertical && !autoHideSidebar {
                TabStrip(browser: browser, layout: .vertical, isFullScreen: isFullScreen,
                         hoverCardTabID: $hoverCardTabID)
                    .frame(width: sidebarWidth)
                    .privateChrome(browser.isPrivate)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(width: sidebarWidthBinding, isResizing: $sidebarIsResizing)
                            .offset(x: BrowserChrome.edgeInset)
                    }
                    .zIndex(1)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            mainColumn
        }
        .overlay(alignment: .leading) {
            if tabLayout == .vertical && autoHideSidebar {
                ChromeRevealRegion(controller: chromeHover, region: .sidebar) {
                    TabStrip(browser: browser, layout: .vertical, isFullScreen: isFullScreen,
                         hoverCardTabID: $hoverCardTabID, floating: true)
                    .frame(width: sidebarWidth)
                    .privateChrome(browser.isPrivate)
                    .background(ChromePresentationMarker(identifier: "BrowserFloatingSidebarGeometry", onViewAvailable: { view in
                        chromeHover.sidebarBoundsProvider = { [weak view] in view?.regionBounds }
                    }))
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: BrowserChrome.edgeInset, y: 4)
                    .overlay(alignment: .trailing) { SidebarResizeHandle(width: sidebarWidthBinding, isResizing: $sidebarIsResizing) }
                    .padding([.horizontal, .bottom], BrowserChrome.revealInset)
                    .modifier(SidebarToolbarInset(controller: chromeHover, outerInset: BrowserChrome.revealInset))
                }
            }
        }
        .ignoresSafeArea(.container, edges: effectiveCompactToolbar ? .top : [])
        .overlay(alignment: .top) {
            if usesFullscreenToolbarOverlay {
                ChromeRevealRegion(controller: chromeHover, region: .toolbar) {
                    fullscreenToolbar
                }
            }
        }
        .background(ChromePointerObserver(controller: chromeHover))
        .background(BrowserShortcutRouter(browser: browser))
        .background(SessionPersistenceView(browser: browser, session: session))
        .modifier(FolderEditorPresentation(browser: browser, controller: chromeHover, verticalTabs: tabLayout == .vertical))
        .overlayPreferenceValue(TabFrameKey.self) { tabFrames in
            hoverCard(tabFrames: tabFrames)
                .privateChrome(browser.isPrivate)
        }
        .sheet(item: Binding(get: { browser.clearDataPresentation }, set: { request in
            if request == nil { browser.dismissClearData() }
        })) { request in
            ClearDataView(request: request)
        }
        .sheet(isPresented: $browser.isShowingHistory) {
            if let history = browser.history {
                HistoryView(history: history) { url, inNewTab in
                    browser.isShowingHistory = false
                    browser.open(url, inNewTab: inNewTab)
                }
            }
        }
        .onChange(of: compactToolbar) { _, value in chromeHover.compactToolbar = value }
        .onChange(of: autoHideSidebar) { _, value in
            chromeHover.autoHideSidebar = value
            hoverCardTabID = nil
        }
        .onChange(of: sidebarIsResizing) { _, value in
            chromeHover.sidebarIsResizing = value
            if !value { persistSidebarWidth() }
        }
        .onChange(of: sidebarWidth) { _, value in chromeHover.sidebarWidth = value }
        .onChange(of: tabLayout) { _, value in
            chromeHover.verticalTabs = value == .vertical
            chromeHover.headerHeight = defaultHeaderHeight
            hoverCardTabID = nil
        }
        .onChange(of: browser.addressFocusRequest) { _, request in
            if request != browser.consumedAddressFocusRequest { chromeHover.addressFocusRequested() }
        }
        .onChange(of: isFullScreen) { _, _ in
            chromeHover.headerHeight = defaultHeaderHeight
            let restore = restoreAddressFocusAfterFullscreen && compactToolbar
            restoreAddressFocusAfterFullscreen = false
            if restore { browser.requestAddressFocus() }
        }
        .onChange(of: toolbarLabelStyle) { _, _ in
            if isFullScreen { chromeHover.headerHeight = defaultHeaderHeight }
        }
        .background(WindowGlassBackground(isDark: browser.isPrivate).ignoresSafeArea())
        .background(WindowChromeConfigurator(tabLayout: tabLayout, horizontalTabs: AnyView(horizontalTabs),
                                             isFullScreen: $isFullScreen, compactToolbar: effectiveCompactToolbar,
                                             insetRevealedToolbar: compactToolbar,
                                             hoverController: chromeHover,
                                             savedToolbarConfiguration: persistsToolbarLayout ? (tabLayout == .vertical ? $verticalToolbarLayout : $horizontalToolbarLayout) : nil,
                                             nativeCommands: nativeToolbarCommands,
                                             toolbarDisplayMode: toolbarLabelStyle.nativeDisplayMode,
                                             toolbarContextMenu: { NSHostingMenu(rootView: ToolbarContextMenu(
                                                 customize: { ChromeCustomization.customizeToolbar(in: browser.window) },
                                                 browser: browser, window: browser.window)) },
                                             onCustomizationChange: { chromeHover.customizationIsRunning = $0 },
                                             onToolbarItemsChange: { toolbarItemIdentifiers = $0 }, onWindowChange: { browser.window = $0; browserWindow = BrowserWindowReference(window: $0) },
                                             onToolbarRegionHeight: { height in
                                                 DispatchQueue.main.async {
                                                     if !isFullScreen { chromeHover.headerHeight = height - BrowserChrome.edgeInset }
                                                 }
                                             }))
        .tint(accent)
        .focusedSceneValue(\.browserModel, browser)
        .navigationTitle(browser.isPrivate ? "Private — \(browser.activeTab?.title ?? "Browser")" : browser.activeTab?.title ?? "Browser")
        .frame(minWidth: 680, minHeight: 440)
        .toolbar(id: nativeToolbarIdentifier) { browserToolbar }
        .environment(\.faviconContext, browser.faviconContext)
        .environment(\.chromeHoverController, chromeHover)
        .environment(\.windowChromePreferences, browser.chromePreferences)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .onChange(of: browser.activeTabID) { _, _ in
            chromeHover.activeTabChanged()
            closeSuggestions()
            completionStart = nil
            address = browser.activeTab?.url?.absoluteString ?? ""
            if let tab = browser.activeTab, !tab.isNewTab, let webView = tab.webView,
               PagePaintObserver.shared.hasPainted(in: webView) {
                chromeHover.navigationSucceeded(in: tab.id)
            }
        }
        .task {
            await contentBlocker.prepare()
        }
        .task {
            if !browser.isPrivate { await BrowserExtensions.shared.restore() }
        }
        .onDisappear {
            windowState.close()
            persistSidebarWidth()
            chromeHover.stop()
            BrowserExtensions.shared.unregister(browser)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { notification in
            rememberAddressFocusBeforeFullscreen(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { notification in
            rememberAddressFocusBeforeFullscreen(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, browser.window === window {
                windowState.close()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, browser.window === window {
                WindowChromeSettingsTarget.shared.browser = browser
                BrowserExtensions.shared.focus(browser)
                browser.requestSessionSave()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, browser.window === window {
                chromeHover.addressIsFocused = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            chromeHover.menuIsTracking = true
            chromeHover.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            chromeHover.menuIsTracking = false
        }
        .onAppear {
            windowState.appear(openWindow: openWindow)
            WindowChromeSettingsTarget.shared.browser = browser
            chromeHover.compactToolbar = compactToolbar
            chromeHover.autoHideSidebar = autoHideSidebar
            chromeHover.verticalTabs = tabLayout == .vertical
            chromeHover.sidebarWidth = sidebarWidth
            chromeHover.headerHeight = defaultHeaderHeight
            browser.chromeHover = chromeHover
            let model = browser
            chromeHover.canHideToolbar = { [weak model] in
                guard let window = model?.window, let responder = window.firstResponder as? NSView else { return true }
                let nativeToolbarHasFocus = window.toolbar?.items.contains { item in
                    guard let view = item.view else { return false }
                    return responder === view || responder.isDescendant(of: view)
                } ?? false
                if nativeToolbarHasFocus { return false }
                if window.styleMask.contains(.fullScreen), model?.chromeHover?.compactToolbar == true {
                    // SwiftUI buttons keep keyboard focus in their hosting responder. In
                    // fullscreen, leave the overlay available until focus returns to the page.
                    guard let page = model?.activeTab?.contentView else { return false }
                    return responder === page || responder.isDescendant(of: page)
                }
                return true
            }
            BrowserExtensions.shared.register(browser)
            if browser.activeTab?.isNewTab == true { browser.requestAddressFocus() }
        }
    }

    private func rememberAddressFocusBeforeFullscreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, browser.window === window else { return }
        restoreAddressFocusAfterFullscreen = addressIsFocused || chromeHover.addressIsFocused
    }

    // Horizontal tabs and pinned sidebars reveal the complete native header and
    // its safe area. Only the vertical auto-hide layout uses floating overlay chrome.
    private var effectiveCompactToolbar: Bool {
        compactToolbar && !((tabLayout == .horizontal || !autoHideSidebar) && chromeHover.toolbarIsRevealed)
    }

    private var usesFullscreenToolbarOverlay: Bool { effectiveCompactToolbar && isFullScreen }

    private var defaultHeaderHeight: CGFloat {
        let base: CGFloat = tabLayout == .vertical ? 40 : 64
        return base + (isFullScreen ? BrowserChrome.edgeInset + toolbarLabelStyle.chromeControlHeight - BrowserChrome.toolbarHeight : 0)
    }

    private var fullscreenToolbar: some View {
        VStack(spacing: BrowserChrome.edgeInset) {
            if tabLayout == .horizontal {
                HStack(spacing: BrowserChrome.edgeInset) {
                    FullscreenWindowControls(window: browserWindow.window)
                        .fixedSize(horizontal: true, vertical: false)
                    horizontalTabs
                        .glassEffect(.regular, in: Capsule())
                }
                .frame(height: BrowserChrome.tabRowHeight)
                fullscreenNavigationRow
            } else {
                HStack(spacing: BrowserChrome.edgeInset) {
                    FullscreenWindowControls(window: browserWindow.window)
                        .fixedSize(horizontal: true, vertical: false)
                    fullscreenNavigationRow
                }
                .frame(height: toolbarLabelStyle.chromeControlHeight + BrowserChrome.edgeInset * 2)
            }
        }
        .padding(.horizontal, BrowserChrome.revealInset)
        .padding(.top, BrowserChrome.edgeInset)
        .padding(.bottom, BrowserChrome.edgeInset)
        .environment(\.fullscreenToolbarOverlay, true)
        .contextMenu { ToolbarContextMenu(customize: { ChromeCustomization.customizeToolbar(in: browser.window) }, browser: browser, window: browser.window) }
    }

    private var fullscreenNavigationRow: some View {
        FullscreenToolbarRow(identifiers: toolbarItemIdentifiers,
                             focusRequest: browser.addressFocusRequest == browser.consumedAddressFocusRequest ? 0 : browser.addressFocusRequest) { identifier in
            fullscreenToolbarControl(identifier)
        } address: {
            addressField(requiresVisibleToolbar: false)
        }
    }

    @ViewBuilder
    private func fullscreenToolbarControl(_ identifier: String) -> some View {
        switch identifier {
        case "sidebar": toolbarComponent(.sidebar)
        case "layout": toolbarComponent(.tabLayout)
        case "pinSidebar": toolbarComponent(.pinSidebar)
        case "back": navigationButton(.back)
        case "forward": navigationButton(.forward)
        case "reload": navigationButton(.reload)
        case "downloads": toolbarComponent(.downloads)
        case "pins": PinnedPagesButton(browser: browser)
        case "folders": FolderToolbarButton(browser: browser)
        case "settings": toolbarComponent(.settings)
        case "newTab": toolbarComponent(.newTab)
        default:
            if browser.supportsExtensions, let item = BrowserExtensions.shared.toolbarExtensions.first(where: { "extension.\($0.id.uuidString)" == identifier }) {
                ExtensionButton(item: item, browser: browser)
            }
        }
    }

    private var horizontalTabs: some View {
        TabStrip(browser: browser, layout: .horizontal, isFullScreen: isFullScreen,
                 hoverCardTabID: $hoverCardTabID, usesNativeHoverPopover: true, floating: usesFullscreenToolbarOverlay)
            .frame(maxHeight: .infinity, alignment: .top)
            .privateChrome(browser.isPrivate)
            .tint(accent)
    }

    // MARK: Address bar

    private func editAddress(_ text: String) {
        // Typing more of the text completes it again; deleting doesn't, so the deleted completion stays gone.
        let isAppending = text.count > typedAddress.count && text.hasPrefix(typedAddress)
        typedAddress = text
        selectedSuggestion = nil
        suggestions = AddressSuggestions.rank(text, pages: browser.history?.pages ?? [],
                                              bookmarks: bookmarks.bookmarks)
        if isAppending, let completion = AddressSuggestions.inlineCompletion(of: text, with: suggestions.first) {
            completionStart = (text as NSString).length
            address = completion
        } else {
            completionStart = nil
        }
    }

    private func performAddressCommand(_ command: SuggestionAddressField.Command) -> Bool {
        switch command {
        case .moveDown, .moveUp:
            guard !suggestions.isEmpty else { return false }
            let offset = command == .moveDown ? 1 : -1
            let index = (selectedSuggestion ?? -1) + offset
            completionStart = nil
            if index < 0 {
                selectedSuggestion = nil
                address = typedAddress
            } else {
                selectedSuggestion = min(index, suggestions.count - 1)
                address = suggestions[min(index, suggestions.count - 1)].url.absoluteString
            }
            return true
        case .submit:
            if let selectedSuggestion, suggestions.indices.contains(selectedSuggestion) {
                open(suggestions[selectedSuggestion])
            } else {
                if let id = browser.activeTabID { chromeHover.addressNavigationSubmitted(in: id) }
                if completionStart != nil, let completed = AddressSuggestions.completedURL(for: address, with: suggestions.first) {
                    browser.navigate(to: completed.absoluteString)
                } else {
                    browser.navigate(to: address)
                }
                finishEditingAddress()
            }
            return true
        case .cancel:
            if suggestions.isEmpty {
                address = browser.activeTab?.url?.absoluteString ?? ""
                typedAddress = address
                finishEditingAddress()
            } else {
                address = typedAddress
                closeSuggestions()
            }
            completionStart = nil
            return true
        }
    }

    private func open(_ suggestion: AddressSuggestion) {
        // The list can report a click more than once before it closes.
        guard !suggestions.isEmpty else { return }
        address = suggestion.url.absoluteString
        browser.open(suggestion.url)
        finishEditingAddress()
    }

    private func finishEditingAddress() {
        closeSuggestions()
        completionStart = nil
        addressBlurRequest += 1
        browser.window?.makeFirstResponder(browser.focusedPage?.webView)
        addressIsFocused = false
        chromeHover.addressIsFocused = false
    }

    private func closeSuggestions() {
        suggestions = []
        selectedSuggestion = nil
        typedAddress = ""
    }

    /// Navigation, bookmarks, and the page. In the vertical layout the sidebar supplies the leading inset.
    private var mainColumn: some View {
        let leadingInset = BrowserChrome.edgeInset
        let pageShape = RoundedRectangle(cornerRadius: tabLayout == .vertical && autoHideSidebar
                                         ? BrowserChrome.sidebarCornerRadius : BrowserChrome.contentCornerRadius,
                                         style: .continuous)

        return VStack(spacing: 0) {
            if bookmarksBarVisibility.isVisible(onNewTab: browser.activeTab?.isNewTab ?? true) {
                BookmarksBar(bookmarks: bookmarks, browser: browser)
                    .contextMenu { BookmarksBehaviorMenu() }
                    .padding(.leading, leadingInset - BrowserChrome.edgeInset)
                    .padding(.bottom, BrowserChrome.edgeInset)
                    .transition(.opacity)
            }

            SplitDropCanvas(browser: browser) {
                if let split = browser.activeSplit {
                    SplitPages(browser: browser, split: split) { tab in
                        if tab.isNewTab {
                            NewTabView(bookmarks: bookmarks, browser: browser) {
                                browser.activeTabID = tab.id
                                browser.requestAddressFocus()
                            }
                        } else { webView(for: tab) }
                    }
                    .id(split.id)
                } else if let tab = browser.activeTab {
                    Group {
                        if tab.isNewTab {
                            NewTabView(bookmarks: bookmarks, browser: browser) { browser.requestAddressFocus() }
                        } else {
                            webView(for: tab)
                        }
                    }
                    .clipShape(pageShape)
                    .overlay {
                        pageShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
                }
            }
            .overlay {
                if let peek = browser.peek {
                    PeekOverlay(browser: browser, peek: peek) { webView(for: $0) }
                        .id(peek.id)
                        .clipShape(pageShape)
                }
            }
            .padding(.leading, leadingInset)
            .padding([.trailing, .bottom], BrowserChrome.edgeInset)
        }
        .padding(.top, BrowserChrome.edgeInset)
    }

    private func hoverCard(tabFrames: [UUID: Anchor<CGRect>]) -> some View {
        Group {
            if tabLayout == .vertical, let tab = browser.tab(withID: hoverCardTabID), let anchor = tabFrames[tab.id] {
                GeometryReader { geometry in
                    let tabFrame = geometry[anchor]
                    let position = CGPoint(x: tabFrame.maxX + 10,
                                           y: max(BrowserChrome.edgeInset, min(tabFrame.minY - 4, geometry.size.height - 250)))
                    TabHoverCard(tab: tab, isActive: tab.id == browser.activeTabID)
                        .offset(x: position.x, y: position.y)
                        .transition(.opacity.combined(with: .offset(x: -3)))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.14), value: hoverCardTabID)
    }

    private func webView(for tab: BrowserTab) -> some View {
        PageHost(content: tab.contentView)
            .overlay {
                if let error = tab.loadError {
                    PageErrorView(error: error, isLoading: tab.isLoading) { tab.retry() }
                }
            }
            .overlay(alignment: .topTrailing) {
                if tab.isFindBarVisible {
                    FindBar(tab: tab, browser: browser)
                        .padding(10)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: tab.isFindBarVisible)
            .overlay(alignment: .topLeading) {
                if tab.isLoading {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(accent.opacity(0.5))
                            .frame(width: max(18, geometry.size.width * tab.estimatedProgress),
                                   height: 2)
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.top, 3)
                    .transaction { $0.animation = nil }
                }
            }
            .onChange(of: tab.url) { _, url in
                if browser.activeTabID == tab.id, !addressIsFocused { address = url?.absoluteString ?? "" }
            }
            .onAppear {
                if browser.activeTabID == tab.id, !addressIsFocused { address = tab.url?.absoluteString ?? "" }
            }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "sidebar", placement: .automatic) { toolbarComponent(.sidebar) }
                .defaultCustomization(tabLayout == .vertical ? .visible : .hidden)
                .sharedBackgroundVisibility(.automatic)
            ToolbarItem(id: "layout", placement: .automatic) { toolbarComponent(.tabLayout) }
                .defaultCustomization(tabLayout == .horizontal ? .visible : .hidden)
                .sharedBackgroundVisibility(.automatic)
            ToolbarItem(id: "pinSidebar", placement: .automatic) { toolbarComponent(.pinSidebar) }
                .defaultCustomization(.hidden)
                .sharedBackgroundVisibility(.automatic)
        }
        ToolbarSpacer(.fixed, placement: .automatic)
        Group {
            ToolbarItem(id: "back", placement: .automatic) { navigationButton(.back) }
            ToolbarItem(id: "forward", placement: .automatic) { navigationButton(.forward) }
            ToolbarItem(id: "reload", placement: .automatic) { navigationButton(.reload) }
        }
        ToolbarItem(id: "address", placement: .automatic) {
            AddressToolbarHost { addressField.background(ToolbarFieldAnchor()) }
                .frame(minWidth: 160, maxWidth: .infinity)
                .background(ToolbarAlignment(browserWindow: browserWindow.window))
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
        .defaultCustomization(.visible, options: .alwaysAvailable)
        .customizationBehavior(.reorderable)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "downloads", placement: .automatic) { toolbarComponent(.downloads) }
            .sharedBackgroundVisibility(.automatic)
        ToolbarSpacer(.fixed, placement: .automatic)
        ForEach(browser.supportsExtensions ? BrowserExtensions.shared.toolbarExtensions : []) { item in
            ToolbarItem(id: "extension.\(item.id.uuidString)", placement: .automatic) { ExtensionButton(item: item, browser: browser) }
                .defaultCustomization(.hidden)
                .sharedBackgroundVisibility(.automatic)
        }
        Group {
            ToolbarItem(id: "pins", placement: .automatic) { PinnedPagesButton(browser: browser) }
                .defaultCustomization(tabLayout == .horizontal ? .visible : .hidden)
                .sharedBackgroundVisibility(.automatic)
            ToolbarItem(id: "folders", placement: .automatic) { FolderToolbarButton(browser: browser) }
                .defaultCustomization(tabLayout == .horizontal ? .visible : .hidden)
                .sharedBackgroundVisibility(.automatic)
            ToolbarItem(id: "settings", placement: .automatic) { toolbarComponent(.settings) }
                .sharedBackgroundVisibility(.automatic)
            ToolbarItem(id: "newTab", placement: .automatic) { toolbarComponent(.newTab) }
                .defaultCustomization(tabLayout == .horizontal ? .visible : .hidden)
                .sharedBackgroundVisibility(.automatic)
        }
    }

    @ViewBuilder
    private func toolbarComponent(_ component: ToolbarComponent) -> some View {
        switch component {
        case .sidebar:
            Button(action: toggleSidebar) { Label("Sidebar", systemImage: "sidebar.left") }
                .labelStyle(ChromeToolbarLabelStyle())
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .chromeToolbarButtonStyle()
                .controlSize(.regular)
                .help(autoHideSidebar ? "Show Sidebar (hover the left edge); Pin Sidebar (⌘S)" : "Automatically Hide Sidebar (⌘S)")
                .accessibilityLabel("Sidebar")
        case .tabLayout:
            Button { tabLayout = tabLayout.toggled } label: {
                Label("Tab Layout", systemImage: tabLayout == .vertical ? "rectangle.topthird.inset.filled" : "sidebar.left")
            }
            .labelStyle(ChromeToolbarLabelStyle())
            .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
            .chromeToolbarButtonStyle()
            .controlSize(.regular)
            .help(tabLayout == .vertical ? "Use Horizontal Tabs (⌥⌘S)" : "Use Vertical Tabs (⌥⌘S)")
            .accessibilityLabel(tabLayout == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs")
        case .pinSidebar:
            Button { autoHideSidebar.toggle() } label: { Label("Pin Sidebar", systemImage: autoHideSidebar ? "pin" : "pin.fill") }
                .labelStyle(ChromeToolbarLabelStyle())
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .chromeToolbarButtonStyle()
                .controlSize(.regular)
                .disabled(tabLayout != .vertical)
                .help(autoHideSidebar ? "Pin Sidebar (⌘S)" : "Automatically Hide Sidebar (⌘S)")
        case .newTab:
            Button { browser.addTab() } label: { Label("New Tab", systemImage: "plus") }
                .labelStyle(ChromeToolbarLabelStyle())
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .chromeToolbarButtonStyle()
                .controlSize(.regular)
                .help("New Tab (⌘T)").accessibilityLabel("New Tab")
        case .downloads:
            DownloadsButton(downloads: browser.downloads)
        case .settings:
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .labelStyle(ChromeToolbarLabelStyle())
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .chromeToolbarButtonStyle()
                .controlSize(.regular)
                .help("Settings")
                .accessibilityLabel("Settings")
        }
    }

    private enum NavigationAction: String { case back = "Back", forward = "Forward", reload = "Reload" }

    private func toggleSidebar() {
        if tabLayout == .horizontal { tabLayout = .vertical }
        else if autoHideSidebar { chromeHover.toggleSidebarFromToolbar() }
        else { autoHideSidebar = true }
    }

    private func performNavigation(_ action: NavigationAction) {
        switch action {
        case .back: browser.goBack()
        case .forward: browser.goForward()
        case .reload:
            if browser.focusedPage?.isLoading == true { browser.stopLoading() }
            else { browser.reload() }
        }
    }

    // SwiftUI retains the toolbar's canonical items and customization palette. Fixed
    // commands use native views so window resizing doesn't remeasure their hosting views.
    private var nativeToolbarCommands: [NativeToolbarCommand] {
        let tab = browser.focusedPage
        let isLoading = tab?.isLoading == true
        let customizationMenu: @MainActor () -> NSMenu = {
            NSHostingMenu(rootView: ToolbarContextMenu(customize: {
                ChromeCustomization.customizeToolbar(in: browser.window)
            }, browser: browser, window: browser.window))
        }
        var commands = [
            NativeToolbarCommand(identifier: "sidebar", title: "Sidebar", symbol: "sidebar.left",
                                 help: autoHideSidebar ? "Show Sidebar (hover the left edge); Pin Sidebar (⌘S)" : "Automatically Hide Sidebar (⌘S)",
                                 action: toggleSidebar, menu: customizationMenu),
            NativeToolbarCommand(identifier: "layout", title: "Tab Layout",
                                 symbol: tabLayout == .vertical ? "rectangle.topthird.inset.filled" : "sidebar.left",
                                 help: tabLayout == .vertical ? "Use Horizontal Tabs (⌥⌘S)" : "Use Vertical Tabs (⌥⌘S)",
                                 action: { tabLayout = tabLayout.toggled }, menu: customizationMenu),
            NativeToolbarCommand(identifier: "pinSidebar", title: "Pin Sidebar", symbol: autoHideSidebar ? "pin" : "pin.fill",
                                 help: autoHideSidebar ? "Pin Sidebar (⌘S)" : "Automatically Hide Sidebar (⌘S)",
                                 isEnabled: tabLayout == .vertical, action: { autoHideSidebar.toggle() }, menu: customizationMenu),
            NativeToolbarCommand(identifier: "settings", title: "Settings", symbol: "gearshape",
                                 action: { openSettings() }, menu: customizationMenu),
            NativeToolbarCommand(identifier: "newTab", title: "New Tab", symbol: "plus", help: "New Tab (⌘T)",
                                 action: { browser.addTab() }, menu: customizationMenu)
        ]
        for action in [NavigationAction.back, .forward, .reload] {
            let symbol = switch action {
            case .back: "chevron.left"
            case .forward: "chevron.right"
            case .reload: isLoading ? "xmark" : "arrow.clockwise"
            }
            let enabled = switch action {
            case .back: tab?.canNavigateBack ?? false
            case .forward: tab?.canGoForward ?? false
            case .reload: !(tab?.isNewTab ?? true)
            }
            let title = action == .reload && isLoading ? "Stop Loading" : action.rawValue
            commands.append(NativeToolbarCommand(identifier: action.rawValue.lowercased(), title: title, symbol: symbol,
                                                 help: title, isEnabled: enabled, action: { performNavigation(action) }, menu: {
                switch action {
                case .back: NSHostingMenu(rootView: historyMenu(for: Array((browser.focusedPage?.backList ?? []).reversed())))
                case .forward: NSHostingMenu(rootView: historyMenu(for: browser.focusedPage?.forwardList ?? []))
                case .reload: customizationMenu()
                }
            }))
        }
        return commands
    }

    private func navigationButton(_ action: NavigationAction) -> some View {
        let tab = browser.focusedPage
        let isLoading = tab?.isLoading == true
        let symbol = switch action {
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .reload: isLoading ? "xmark" : "arrow.clockwise"
        }
        let isDisabled = switch action {
        case .back: !(tab?.canNavigateBack ?? false)
        case .forward: !(tab?.canGoForward ?? false)
        case .reload: tab?.isNewTab ?? true
        }
        return Button { performNavigation(action) } label: {
            Label(action == .reload && isLoading ? "Stop Loading" : action.rawValue, systemImage: symbol)
                .contentTransition(.symbolEffect(.replace))
                .offset(x: toolbarLabelStyle == .iconOnly ? (action == .back ? 2 : action == .forward ? -2 : 0) : 0)
        }
        .labelStyle(ChromeToolbarLabelStyle())
        .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
        .chromeToolbarButtonStyle()
        .controlSize(.regular)
        .disabled(isDisabled)
        .help(action == .reload && isLoading ? "Stop Loading" : action.rawValue)
        .contextMenu {
            switch action {
            case .back: historyMenu(for: Array((tab?.backList ?? []).reversed()))
            case .forward: historyMenu(for: tab?.forwardList ?? [])
            case .reload: ToolbarContextMenu(customize: { ChromeCustomization.customizeToolbar(in: browser.window) }, browser: browser, window: browser.window)
            }
        }
    }

    private var addressField: some View { addressField(requiresVisibleToolbar: true) }

    private func addressField(requiresVisibleToolbar: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: browser.activeTab?.isSecure == true ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 14)
            if browser.isPrivate { privateLabel }
            AddressTextField(text: $address,
                             requiresVisibleToolbar: requiresVisibleToolbar,
                             browserWindow: browserWindow.window,
                             pageURL: browser.activeTab?.isNewTab == false ? browser.activeTab?.url : nil,
                             pageTitle: browser.activeTab?.pageTitle ?? "",
                             completionStart: completionStart,
                             suggestions: suggestions,
                             selectedSuggestion: selectedSuggestion,
                             onEdit: editAddress,
                             onCommand: performAddressCommand,
                             onChooseSuggestion: open,
                             focusRequest: browser.addressFocusRequest == browser.consumedAddressFocusRequest ? 0 : browser.addressFocusRequest,
                             onFocusApplied: { browser.consumedAddressFocusRequest = $0 },
                             onFocusChange: {
                                 addressIsFocused = $0
                                 chromeHover.addressIsFocused = $0
                                 if !$0 { closeSuggestions() }
                             }, onSubmit: {
                guard BrowserAddress.url(for: address) != nil, let tabID = browser.activeTabID else { return }
                chromeHover.addressNavigationSubmitted(in: tabID)
                browser.navigate(to: address)
                browser.window?.makeFirstResponder(browser.activeTab?.webView)
                chromeHover.addressIsFocused = false
            })
            .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
            zoomButton
            passwordButton
            trackerBlockingButton
            bookmarkButton
        }
        .padding(.horizontal, BrowserChrome.edgeInset)
        .frame(height: BrowserChrome.toolbarHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(addressIsFocused ? accent.opacity(0.7) : Color.clear, lineWidth: 1)
        }
        .contextMenu { ToolbarContextMenu(customize: { ChromeCustomization.customizeToolbar(in: browser.window) }, browser: browser, window: browser.window) }
        .privateChrome(browser.isPrivate)
    }

    @ViewBuilder
    private var zoomButton: some View {
        if let tab = browser.focusedPage, !tab.isNewTab, tab.pageZoom != 1 {
            Button { browser.resetZoom() } label: {
                Text(tab.pageZoom, format: .percent.precision(.fractionLength(0)))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset Zoom (⌘0)")
            .accessibilityLabel("Zoom \(Int((tab.pageZoom * 100).rounded())) percent, reset")
        }
    }

    private var privateLabel: some View {
        Label("Private", systemImage: "eyeglasses")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .frame(height: BrowserChrome.toolbarHeight)
            .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .help("Private Window: history, cookies, and website data aren’t kept after it closes")
            .accessibilityLabel("Private Window")
    }

    /// Shows whether trackers are blocked on the page's site, and turns blocking off for the site. A private window
    /// shows the state without changing it, since the change would be kept after it closes.
    @ViewBuilder
    private var trackerBlockingButton: some View {
        if contentBlocker.isEnabled, let tab = browser.focusedPage, !tab.isNewTab, let host = tab.host,
           ["http", "https"].contains(tab.url?.scheme?.lowercased() ?? "") {
            let isBlocking = contentBlocker.isBlocking(on: host)
            let site = ContentBlocker.site(host)
            let status = contentBlocker.isReady
                ? (isBlocking ? "Trackers are blocked on \(site)" : "Tracker blocking is off for \(site)")
                : (contentBlocker.lastError ?? "Preparing tracker protection…")
            Menu {
                Text(status)
                Button(isBlocking ? "Turn Off Blocking for This Site" : "Turn On Blocking for This Site") {
                    Task {
                        await contentBlocker.setBlocking(!isBlocking, on: host)
                        tab.reload()
                    }
                }
                .disabled(browser.isPrivate || !contentBlocker.isReady || contentBlocker.isUpdating)
            } label: {
                Image(systemName: !contentBlocker.isReady ? "exclamationmark.shield" : isBlocking ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(isBlocking ? Color.secondary : Color.orange)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ChromeIconButtonStyle(size: 26))
            .fixedSize()
            .help(status)
            .accessibilityLabel(status)
        }
    }

    /// Offers the passwords saved for exactly the page's origin, once the page shows a password field.
    @ViewBuilder
    private var passwordButton: some View {
        if let tab = browser.focusedPage, !tab.isNewTab, tab.hasPasswordFields, let passwords = browser.passwords {
            let accounts = passwords.passwords(for: PasswordOrigin(url: tab.url))
            if !accounts.isEmpty {
                Menu {
                    Text("Passwords for \(PasswordOrigin(url: tab.url)?.description ?? "this site")")
                    ForEach(accounts) { account in
                        Button(account.username.isEmpty ? "Fill Password" : "Fill “\(account.username)”") {
                            Task { await PasswordAutofill.fill(account, in: tab, from: passwords) }
                        }
                    }
                    Divider()
                    Button("Show Passwords…") { openSettings() }
                } label: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(ChromeIconButtonStyle(size: 26))
                .fixedSize()
                .help("Fill Saved Password")
                .accessibilityLabel("Fill saved password")
            }
        }
    }

    @ViewBuilder
    private var bookmarkButton: some View {
        if showsBookmarkButton, let tab = browser.activeTab, !tab.isNewTab, let url = tab.url {
            let isBookmarked = bookmarks.isBookmarked(url)
            Button { bookmarks.toggle(title: tab.pageTitle, url: url) } label: {
                Image(systemName: isBookmarked ? "star.fill" : "star")
                    .foregroundStyle(isBookmarked ? Color.yellow : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(ChromeIconButtonStyle(size: 20))
            .help(isBookmarked ? "Remove Bookmark (⌘D)" : "Bookmark This Page (⌘D)")
            .accessibilityLabel(isBookmarked ? "Remove Bookmark" : "Bookmark This Page")
            .contextMenu { ToolbarContextMenu(customize: { ChromeCustomization.customizeToolbar(in: browser.window) }, browser: browser, window: browser.window) }
        }
    }

    @ViewBuilder
    private func historyMenu(for items: [WKBackForwardListItem]) -> some View {
        ForEach(items.prefix(15), id: \.self) { item in
            Button(item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.url.absoluteString) {
                browser.go(to: item)
            }
        }
        if items.isEmpty { Text("No History") }
    }
}
