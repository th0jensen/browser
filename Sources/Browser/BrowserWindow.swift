import SwiftUI
import WebKit

struct BrowserWindow: View {
    let bookmarks: BookmarkStore
    @State private var browser: BrowserModel
    @State private var address = ""
    @State private var hoverCardTabID: UUID?
    @State private var isFullScreen = false
    @State private var sidebarIsRevealed = false
    @State private var sidebarOpenedFromToolbar = false
    @State private var sidebarHideTask: Task<Void, Never>?
    @State private var isTrackingMenu = false
    @State private var sidebarIsResizing = false
    @State private var browserWindow = BrowserWindowReference()
    @State private var toolbarPrefix = BrowserProfile.isTesting ? "BrowserToolbar.tests.\(UUID())" : "BrowserToolbar.v5"
    @FocusState private var addressIsFocused: Bool
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBarVisibility = BookmarksBarVisibility.always
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.horizontal
    @AppStorage(SidebarVisibility.autoHideKey) private var autoHideSidebar = false
    @AppStorage(ChromeCustomization.widthKey) private var sidebarWidth = Double(BrowserChrome.sidebarWidth)
    @AppStorage(ChromeCustomization.bookmarkButtonKey) private var showsBookmarkButton = true

    private let accent = Color(red: 0.38, green: 0.49, blue: 0.54)

    init(bookmarks: BookmarkStore, downloads: DownloadManager) {
        self.bookmarks = bookmarks
        _browser = State(initialValue: BrowserModel(downloads: downloads))
    }

    init(bookmarks: BookmarkStore, browser: BrowserModel) {
        self.bookmarks = bookmarks
        _browser = State(initialValue: browser)
    }

    var body: some View {
        // The main column keeps one identity across layouts, so switching layouts doesn't rebuild the page host.
        HStack(spacing: 0) {
            if tabLayout == .vertical && !autoHideSidebar {
                TabStrip(browser: browser, layout: .vertical, isFullScreen: isFullScreen,
                         hoverCardTabID: $hoverCardTabID, customize: { ChromeCustomization.customizeToolbar(in: browser.window) })
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) { SidebarResizeHandle(width: $sidebarWidth, isResizing: $sidebarIsResizing) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            mainColumn
        }
        .overlay(alignment: .leading) {
            if tabLayout == .vertical && autoHideSidebar && sidebarIsRevealed {
                TabStrip(browser: browser, layout: .vertical, isFullScreen: isFullScreen,
                         hoverCardTabID: $hoverCardTabID, customize: { ChromeCustomization.customizeToolbar(in: browser.window) })
                    .frame(width: sidebarWidth)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: BrowserChrome.sidebarCornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
                    .overlay(alignment: .trailing) { SidebarResizeHandle(width: $sidebarWidth, isResizing: $sidebarIsResizing) }
                    .padding([.leading, .bottom], BrowserChrome.edgeInset)
                    .padding(.top, BrowserChrome.edgeInset)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .onContinuousHover { phase in
            guard tabLayout == .vertical, autoHideSidebar, !sidebarIsResizing else { return }
            switch phase {
            case .active(let point):
                sidebarOpenedFromToolbar = false
                let topInset: CGFloat = 0
                if point.x <= 10 {
                    revealSidebar()
                } else if sidebarIsRevealed && point.x <= sidebarWidth + BrowserChrome.edgeInset
                            && point.y >= topInset {
                    sidebarHideTask?.cancel()
                } else if sidebarIsRevealed {
                    scheduleSidebarHide()
                }
            case .ended: scheduleSidebarHide()
            }
        }
        .overlayPreferenceValue(TabFrameKey.self) { tabFrames in
            hoverCard(tabFrames: tabFrames)
        }
        .animation(.easeOut(duration: 0.18), value: bookmarksBarVisibility)
        .animation(.easeOut(duration: 0.18), value: browser.activeTab?.isNewTab)
        .animation(.snappy(duration: 0.25), value: tabLayout)
        .animation(.snappy(duration: 0.25), value: autoHideSidebar)
        .animation(.snappy(duration: 0.25), value: sidebarIsRevealed)
        .onChange(of: autoHideSidebar) { _, _ in
            sidebarHideTask?.cancel()
            sidebarIsRevealed = false
            sidebarOpenedFromToolbar = false
            hoverCardTabID = nil
        }
        .onChange(of: sidebarIsResizing) { _, resizing in
            if resizing { sidebarHideTask?.cancel() }
        }
        .onChange(of: tabLayout) { _, _ in
            hoverCardTabID = nil
            sidebarHideTask?.cancel()
            sidebarIsRevealed = false
            sidebarOpenedFromToolbar = false
        }
        .background(WindowGlassBackground().ignoresSafeArea())
        .background(WindowChromeConfigurator(tabLayout: tabLayout, horizontalTabs: AnyView(horizontalTabs),
                                             isFullScreen: $isFullScreen, onWindowChange: { browser.window = $0; browserWindow = BrowserWindowReference(window: $0) }))
        .tint(accent)
        .focusedSceneValue(\.browserModel, browser)
        .frame(minWidth: 680, minHeight: 440)
        .toolbar(id: "\(toolbarPrefix).\(tabLayout.rawValue)") { browserToolbar }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onChange(of: browser.activeTabID) { _, _ in
            address = browser.activeTab?.url?.absoluteString ?? ""
        }
        .onOpenURL { browser.open($0) }
        .task {
            await BrowserExtensions.shared.restore()
            BrowserSessionStore.shared.restore(in: browser)
            if browser.activeTab?.isNewTab == true { browser.requestAddressFocus() }
        }
        .onChange(of: BrowserSessionSnapshot(browser: browser)) { _, _ in BrowserSessionStore.shared.save(browser) }
        .onDisappear {
            sidebarHideTask?.cancel()
            BrowserExtensions.shared.unregister(browser)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, browser.window === window {
                BrowserExtensions.shared.focus(browser)
                BrowserSessionStore.shared.save(browser)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            isTrackingMenu = true
            sidebarHideTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            isTrackingMenu = false
            scheduleSidebarHide()
        }
        .onAppear {
            BrowserExtensions.shared.register(browser)
            if browser.activeTab?.isNewTab == true { browser.requestAddressFocus() }
        }
    }

    private func revealSidebar() {
        sidebarHideTask?.cancel()
        sidebarIsRevealed = true
    }

    private var horizontalTabs: some View {
        TabStrip(browser: browser, layout: .horizontal, isFullScreen: isFullScreen,
                 hoverCardTabID: $hoverCardTabID, usesNativeHoverPopover: true,
                 customize: { ChromeCustomization.customizeToolbar(in: browser.window) })
            .frame(maxHeight: .infinity, alignment: .top)
            .tint(accent)
    }

    private func scheduleSidebarHide() {
        sidebarHideTask?.cancel()
        guard sidebarIsRevealed, !isTrackingMenu, !sidebarIsResizing, !sidebarOpenedFromToolbar else { return }
        sidebarHideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            guard !sidebarIsResizing, !isTrackingMenu, !sidebarOpenedFromToolbar else { return }
            sidebarIsRevealed = false
            hoverCardTabID = nil
        }
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
                    .contextMenu { ChromeCustomizationMenu { ChromeCustomization.customizeToolbar(in: browser.window) } }
                    .padding(.leading, leadingInset - BrowserChrome.edgeInset)
                    .padding(.bottom, BrowserChrome.edgeInset)
                    .transition(.opacity)
            }

            if let tab = browser.activeTab {
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
                .padding(.leading, leadingInset)
                .padding([.trailing, .bottom], BrowserChrome.edgeInset)
            }
        }
        .padding(.top, BrowserChrome.edgeInset)
    }

    private func hoverCard(tabFrames: [UUID: Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            if tabLayout == .vertical, let tab = browser.tab(withID: hoverCardTabID), let anchor = tabFrames[tab.id] {
                let tabFrame = geometry[anchor]
                let position = tabLayout == .vertical
                    // Beside the sidebar row, kept clear of the window's bottom edge.
                    ? CGPoint(x: tabFrame.maxX + 10,
                              y: max(BrowserChrome.edgeInset, min(tabFrame.minY - 4, geometry.size.height - 250)))
                    : CGPoint(x: min(max(tabFrame.minX, BrowserChrome.edgeInset),
                                     geometry.size.width - TabHoverCard.width - BrowserChrome.edgeInset),
                              y: tabFrame.maxY + 6)
                TabHoverCard(tab: tab, isActive: tab.id == browser.activeTabID)
                    .offset(x: position.x, y: position.y)
                    .transition(tabLayout == .vertical ? .opacity.combined(with: .offset(x: -3))
                                                       : .opacity.combined(with: .offset(y: -3)))
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
                    .animation(.easeOut(duration: 0.18), value: tab.estimatedProgress)
                }
            }
            .onChange(of: tab.url) { _, url in
                if !addressIsFocused { address = url?.absoluteString ?? "" }
            }
            .onAppear {
                if !addressIsFocused { address = tab.url?.absoluteString ?? "" }
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
        .customizationBehavior(.disabled)
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: NSToolbarItem.Identifier.flexibleSpace.rawValue, placement: .automatic) { Spacer() }
            .defaultCustomization(.hidden)
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(id: "downloads", placement: .automatic) { toolbarComponent(.downloads) }
            .sharedBackgroundVisibility(.automatic)
        ForEach(BrowserExtensions.shared.toolbarExtensions) { item in
            ToolbarItem(id: "extension.\(item.id.uuidString)", placement: .automatic) { ExtensionButton(item: item, browser: browser) }
                .sharedBackgroundVisibility(.automatic)
        }
        ToolbarItem(id: "pins", placement: .automatic) { PinnedPagesButton(browser: browser) }
            .defaultCustomization(tabLayout == .horizontal ? .visible : .hidden)
            .sharedBackgroundVisibility(.automatic)
        ToolbarItem(id: "settings", placement: .automatic) { toolbarComponent(.settings) }
            .sharedBackgroundVisibility(.automatic)
        ToolbarItem(id: "newTab", placement: .automatic) { toolbarComponent(.newTab) }
            .defaultCustomization(tabLayout == .horizontal ? .visible : .hidden)
            .sharedBackgroundVisibility(.automatic)
        Group {
            ToolbarItem(id: NSToolbarItem.Identifier.space.rawValue, placement: .automatic) {
                Color.clear.frame(width: 20, height: 1).accessibilityLabel("Space")
            }
            .defaultCustomization(.hidden)
            .sharedBackgroundVisibility(.hidden)
            ForEach(0..<4) { index in
                ToolbarItem(id: "divider\(index)", placement: .automatic) {
                    Label {
                        Text("Divider")
                    } icon: {
                        Rectangle().fill(.separator).frame(width: 1, height: 20)
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 12)
                    .accessibilityLabel("Divider")
                }
                .defaultCustomization(.hidden)
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    @ViewBuilder
    private func toolbarComponent(_ component: ToolbarComponent) -> some View {
        switch component {
        case .sidebar:
            Button {
                if tabLayout == .horizontal { tabLayout = .vertical }
                else if autoHideSidebar {
                    if sidebarIsRevealed { sidebarIsRevealed = false; sidebarOpenedFromToolbar = false }
                    else { sidebarOpenedFromToolbar = true; revealSidebar() }
                }
                else { autoHideSidebar = true }
            } label: { Label("Sidebar", systemImage: "sidebar.left") }
                .labelStyle(.iconOnly)
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .buttonStyle(.automatic)
                .controlSize(.regular)
                .help(autoHideSidebar ? "Show Sidebar (hover the left edge); Pin Sidebar (⌘S)" : "Automatically Hide Sidebar (⌘S)")
                .accessibilityLabel("Sidebar")
        case .tabLayout:
            Button { tabLayout = tabLayout.toggled } label: {
                Label("Tab Layout", systemImage: tabLayout == .vertical ? "rectangle.topthird.inset.filled" : "sidebar.left")
            }
            .labelStyle(.iconOnly)
            .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
            .buttonStyle(.automatic)
            .controlSize(.regular)
            .help(tabLayout == .vertical ? "Use Horizontal Tabs (⌥⌘S)" : "Use Vertical Tabs (⌥⌘S)")
            .accessibilityLabel(tabLayout == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs")
        case .pinSidebar:
            Button { autoHideSidebar.toggle() } label: { Label("Pin Sidebar", systemImage: autoHideSidebar ? "pin" : "pin.fill") }
                .labelStyle(.iconOnly)
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .buttonStyle(.automatic)
                .controlSize(.regular)
                .disabled(tabLayout != .vertical)
                .help(autoHideSidebar ? "Pin Sidebar (⌘S)" : "Automatically Hide Sidebar (⌘S)")
        case .newTab:
            Button { browser.addTab() } label: { Label("New Tab", systemImage: "plus") }
                .labelStyle(.iconOnly)
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .buttonStyle(.automatic)
                .controlSize(.regular)
                .help("New Tab (⌘T)").accessibilityLabel("New Tab")
        case .downloads:
            DownloadsButton(downloads: browser.downloads)
        case .settings:
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .labelStyle(.iconOnly)
                .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
                .buttonStyle(.automatic)
                .controlSize(.regular)
                .help("Settings")
                .accessibilityLabel("Settings")
        }
    }

    private enum NavigationAction: String { case back = "Back", forward = "Forward", reload = "Reload" }

    private func navigationButton(_ action: NavigationAction) -> some View {
        let tab = browser.activeTab
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
        return Button {
            switch action {
            case .back: browser.goBack()
            case .forward: browser.goForward()
            case .reload:
                if isLoading { browser.stopLoading() } else { browser.reload() }
            }
        } label: {
            Label(action == .reload && isLoading ? "Stop Loading" : action.rawValue, systemImage: symbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .labelStyle(.iconOnly)
        .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
        .buttonStyle(.automatic)
        .controlSize(.regular)
        .disabled(isDisabled)
        .help(action == .reload && isLoading ? "Stop Loading" : action.rawValue)
        .contextMenu {
            switch action {
            case .back: historyMenu(for: Array((tab?.backList ?? []).reversed()))
            case .forward: historyMenu(for: tab?.forwardList ?? [])
            case .reload: ChromeCustomizationMenu { ChromeCustomization.customizeToolbar(in: browser.window) }
            }
        }
    }

    private var addressField: some View {
        HStack(spacing: 7) {
            Image(systemName: browser.activeTab?.isSecure == true ? "lock.fill" : "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            AddressTextField(text: $address,
                             focusRequest: browser.addressFocusRequest == browser.consumedAddressFocusRequest ? 0 : browser.addressFocusRequest,
                             onFocusApplied: { browser.consumedAddressFocusRequest = $0 },
                             onFocusChange: { addressIsFocused = $0 }, onSubmit: {
                browser.navigate(to: address)
                browser.window?.makeFirstResponder(browser.activeTab?.webView)
            })
            .frame(minWidth: 0, idealWidth: 200, maxWidth: .infinity)
            bookmarkButton
        }
        .padding(.horizontal, BrowserChrome.edgeInset)
        .frame(height: BrowserChrome.toolbarHeight)
        .glassEffect(.regular.interactive(), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(addressIsFocused ? accent.opacity(0.7) : Color.clear, lineWidth: 1)
        }
        .contextMenu { ChromeCustomizationMenu { ChromeCustomization.customizeToolbar(in: browser.window) } }
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
            .contextMenu { ChromeCustomizationMenu { ChromeCustomization.customizeToolbar(in: browser.window) } }
        }
    }

    @ViewBuilder
    private func historyMenu(for items: [WKBackForwardListItem]) -> some View {
        ForEach(items.prefix(15), id: \.self) { item in
            Button(item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.url.absoluteString) {
                browser.go(to: item)
            }
        }
        ChromeCustomizationMenu { ChromeCustomization.customizeToolbar(in: browser.window) }
    }
}
