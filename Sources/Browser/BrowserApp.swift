import AppKit
import SwiftUI
import Darwin

@main
struct BrowserApp: App {
    static let windowID = "browser"
    static let privateWindowID = "private"
    @State private var history: HistoryStore
    @State private var session: SessionStore
    @State private var browsingData: BrowsingData
    @NSApplicationDelegateAdaptor(BrowserApplicationDelegate.self) private var applicationDelegate
    @State private var bookmarks = BookmarkStore()
    @State private var downloads = DownloadManager()
    @AppStorage(ChromeCustomization.toolbarLabelStyleKey) private var toolbarLabelStyle = ToolbarLabelStyle.iconOnly

    init() {
        // Legacy migration tooling can prepare a sandbox without opening a window.
        if CommandLine.arguments.contains("--prepare-profile") {
            do { try BrowserProfile.prepare(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("Could not prepare Browser profile: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        let history = HistoryStore(file: BrowserProfile.isTesting ? nil : .applicationSupport(named: "History.plist"))
        let session = SessionStore(file: BrowserProfile.isTesting ? nil : .applicationSupport(named: "Session.plist"),
                                   restoresWindows: SessionPreferences.restoresWindows)
        _history = State(initialValue: history)
        _session = State(initialValue: session)
        _browsingData = State(initialValue: BrowsingData(history: history, session: session))
    }

    var body: some Scene {
        WindowGroup(id: Self.windowID) {
            BrowserWindow(bookmarks: bookmarks, downloads: downloads, history: history, session: session)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .environment(browsingData)
                .modifier(ScrollbarVisibility())
                .frame(minWidth: 680, minHeight: 440)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    session.saveBeforeQuitting()
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: ["*"])
        .windowToolbarLabelStyle($toolbarLabelStyle)
        .commands {
            ToolbarCommands()
            BrowserCommands(bookmarks: bookmarks, history: history, session: session, updater: .shared)
        }
        WindowGroup("Private Window", id: Self.privateWindowID) {
            BrowserWindow(bookmarks: bookmarks, downloads: downloads, history: nil, session: nil, isPrivate: true)
                .handlesExternalEvents(preferring: [], allowing: [])
                .modifier(ScrollbarVisibility())
                .environment(browsingData)
                .frame(minWidth: 680, minHeight: 440)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])
        .windowToolbarLabelStyle($toolbarLabelStyle)
        Settings { BrowserSettings(browsingData: browsingData) }
            .windowStyle(.hiddenTitleBar)
    }
}

private final class BrowserApplicationDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalURLRouter.shared.open(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the artwork bundled with this variant for its running app icon.
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = Bundle.main.url(forResource: name, withExtension: nil),
              let icon = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = icon
    }
}

private struct BrowserModelKey: FocusedValueKey {
    typealias Value = BrowserModel
}

extension FocusedValues {
    var browserModel: BrowserModel? {
        get { self[BrowserModelKey.self] }
        set { self[BrowserModelKey.self] = newValue }
    }
}

private struct BrowserCommands: Commands {
    let bookmarks: BookmarkStore
    let history: HistoryStore
    let session: SessionStore
    let updater: AppUpdater
    @FocusedValue(\.browserModel) private var browser
    @Environment(\.openWindow) private var openWindow
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBarVisibility = BookmarksBarVisibility.always
    private var tabLayout: TabLayout {
        get { chrome.tabLayout }
        nonmutating set { chrome.tabLayout = newValue }
    }
    private var chrome: WindowChromePreferences { browser?.chromePreferences ?? WindowChromeSettingsTarget.shared.preferences }
    private var autoHideSidebar: Bool {
        get { chrome.autoHideSidebar }
        nonmutating set { chrome.autoHideSidebar = newValue }
    }
    private var compactToolbar: Bool {
        get { chrome.autoHideToolbar }
        nonmutating set { chrome.autoHideToolbar = newValue }
    }

    private var bookmarkableTab: BrowserTab? {
        guard let tab = browser?.focusedPage, !tab.isNewTab, tab.url != nil else { return nil }
        return tab
    }

    private var pageTab: BrowserTab? {
        guard let tab = browser?.focusedPage, !tab.isNewTab else { return nil }
        return tab
    }

    var body: some Commands {
        if updater.isAvailable {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: BrowserApp.windowID) }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Private Window") { openWindow(id: BrowserApp.privateWindowID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Tab") { browser?.addTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Close Tab") {
                if let browser { browser.closeActiveTab() }
                else { NSApp.keyWindow?.performClose(nil) }
            }
                .keyboardShortcut("w", modifiers: .command)
            Button("Open Peek in New Tab") { browser?.expandPeek() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(browser?.peek == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Webpage As…") { browser?.saveWebpage() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(browser?.activeTab?.isNewTab != false)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { browser?.printActivePage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(pageTab?.webView == nil)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { browser?.showFindBar() }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find Next") { browser?.findNext() }
                    .keyboardShortcut("g", modifiers: [.command, .option])
                Button("Find Previous") { browser?.findNext(backwards: true) }
                    .keyboardShortcut("g", modifiers: [.command, .option, .shift])
                Button("Use Selection for Find") { browser?.useSelectionForFind() }
                    .keyboardShortcut("e", modifiers: .command)
            }
            .disabled(pageTab == nil)
            Button("Ask on Page…") { browser?.showPageQuestion() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(browser?.canAskOnPage != true)
            // Replacing the group removes these too, so they're sent to the page or text field as AppKit would.
            Menu("Spelling and Grammar") {
                Button("Show Spelling and Grammar") { send(#selector(NSText.showGuessPanel(_:))) }
                    .keyboardShortcut(":", modifiers: .command)
                Button("Check Document Now") { send(#selector(NSText.checkSpelling(_:))) }
                    .keyboardShortcut(";", modifiers: .command)
            }
            Menu("Speech") {
                Button("Start Speaking") { send(#selector(NSTextView.startSpeaking(_:))) }
                Button("Stop Speaking") { send(#selector(NSTextView.stopSpeaking(_:))) }
            }
        }
        CommandMenu("Tabs") {
            Button("Add Right Split") {
                guard let browser, let tab = browser.activeTab else { return }
                browser.addTab(focusAddress: false)
                if let newTab = browser.activeTab {
                    browser.makeSplit(newTab.id, with: tab.id, placement: .right)
                    browser.activeTabID = newTab.id
                    browser.requestAddressFocus()
                }
            }
            .keyboardShortcut("+", modifiers: [.command, .option])
            .disabled(browser == nil || (browser?.activeSplit?.tabIDs.count ?? 1) >= SplitTabGroup.limit)
            if let browser, let tab = browser.activeTab, browser.activeSplit != nil {
                SplitTabMenu(browser: browser, tab: tab)
            }
            Divider()
            Button("New Folder…") { browser?.requestNewFolder() }
            Button(browser?.isTidyingTabs == true ? "Cancel Tidy Tabs" : "Tidy Tabs") {
                if browser?.isTidyingTabs == true { browser?.cancelTidyingTabs() } else { browser?.tidyTemporaryTabs() }
            }.disabled(browser?.isTidyingTabs != true && (browser?.canTidyTabs != true || BrowserIntelligence.unavailableReason != nil))
            if browser?.regularTabs.contains(where: { $0.temporarySection != nil }) == true {
                Button("Remove All Temporary Groups") { browser?.removeTemporarySections() }
            }
            Divider()
            if let browser, !browser.folders.pages.isEmpty {
                Menu("Pinned Tabs") {
                    ForEach(browser.folders.pages) { page in
                        Button(page.title) { browser.openFolderPage(page) }
                    }
                }
            }
            Divider()
            if let browser, let tab = browser.activeTab { TabPinActions(browser: browser, tab: tab) }
            if let browser, !browser.pinnedPages.items.isEmpty {
                Menu("Essential Tabs") {
                    ForEach(browser.pinnedPages.items) { page in
                        Button(page.title) { browser.openPinned(page) }
                    }
                }
            }
            Divider()
            Button("Next Tab") { browser?.switchTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { browser?.switchTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Cycle to Next Tab") { browser?.switchTab(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Cycle to Previous Tab") { browser?.switchTab(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])

            Divider()

            ForEach(1...8, id: \.self) { number in
                Button("Select Tab \(number)") { browser?.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
            Button("Select Last Tab") { browser?.selectLastTab() }
                .keyboardShortcut("9", modifiers: .command)
        }
        // Native toggleToolbarShown: only changes NSToolbar.isVisible, which
        // auto-hide legitimately reconciles on the next layout. Use the shared
        // preference so View, keyboard, Settings and context menu agree.
        CommandGroup(replacing: .toolbar) {
            Button(compactToolbar ? "Show Toolbar" : "Automatically Hide Toolbar") {
                compactToolbar.toggle()
            }
            .disabled(tabLayout == .horizontal)
            .keyboardShortcut("s", modifiers: [.command, .control])
            Button("Customize Toolbar…") { ChromeCustomization.customizeToolbar(in: browser?.window) }
        }
        CommandGroup(after: .toolbar) {
            Button("Open Location") { browser?.requestAddressFocus() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Toggle Address Bar") { browser?.toggleAddressFocus() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Reload Page") { browser?.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Actual Size") { browser?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(pageTab.map { $0.pageZoom == 1 } ?? true)
            Button("Zoom In") { browser?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!(browser?.canZoom ?? false))
            Button("Zoom Out") { browser?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!(browser?.canZoom ?? false))
        }
        CommandGroup(after: .sidebar) {
            Button(tabLayout == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs") {
                tabLayout = tabLayout.toggled
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button(autoHideSidebar && tabLayout == .vertical ? "Pin Sidebar" : "Automatically Hide Sidebar") {
                let isAutoHiding = tabLayout == .vertical && autoHideSidebar
                tabLayout = .vertical
                autoHideSidebar = !isAutoHiding
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(tabLayout == .horizontal)
            Divider()
            Picker("Bookmarks Bar", selection: $bookmarksBarVisibility) {
                ForEach(BookmarksBarVisibility.allCases) { visibility in
                    Text(visibility.title).tag(visibility)
                }
            }
            Button(bookmarksBarVisibility == .never ? "Show Bookmarks Bar" : "Hide Bookmarks Bar") {
                bookmarksBarVisibility = bookmarksBarVisibility == .never ? .always : .never
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
        }
        CommandMenu("History") {
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Reopen All Windows from Last Session") {
                // A private window can't take the restored tabs.
                for _ in 0..<session.reopenLastSession(reusing: browser?.isPrivate == true ? nil : browser) {
                    openWindow(id: BrowserApp.windowID)
                }
            }
            .disabled(session.reopenableWindows.isEmpty)

            let recentVisits = history.recentVisits(limit: 15)
            if !recentVisits.isEmpty {
                Divider()
                ForEach(recentVisits) { visit in
                    Button(Self.menuTitle(visit.displayTitle)) { browser?.open(visit.url) }
                }
            }

            Divider()
            Button("Show All History") { browser?.isShowingHistory.toggle() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(browser?.history == nil)
            Button("Clear History and Website Data…") { browser?.isShowingClearData = true }
                .disabled(browser == nil)
        }
        CommandMenu("Bookmarks") {
            Button(bookmarks.isBookmarked(bookmarkableTab?.url) ? "Remove Bookmark" : "Bookmark This Page") {
                guard let tab = bookmarkableTab, let url = tab.url else { return }
                bookmarks.toggle(title: tab.pageTitle, url: url)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(bookmarkableTab == nil)

            if !bookmarks.bookmarks.isEmpty {
                Divider()
                ForEach(bookmarks.bookmarks) { bookmark in
                    Button(bookmark.displayTitle) { browser?.open(bookmark.url) }
                }
            }
        }
        CommandMenu("Develop") {
            Button("Show Web Inspector") { browser?.showWebInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(browser?.activeTab?.isNewTab != false)
        }
    }

    /// Sends an editing action to the focused page or text field.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    private static func menuTitle(_ title: String) -> String {
        title.count > 60 ? String(title.prefix(59)) + "…" : title
    }
}
