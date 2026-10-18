import SwiftUI
import Darwin

@main
struct BrowserApp: App {
    @NSApplicationDelegateAdaptor(BrowserApplicationDelegate.self) private var applicationDelegate
    @State private var bookmarks = BookmarkStore()
    @State private var downloads = DownloadManager()
    @AppStorage(ChromeCustomization.toolbarLabelStyleKey) private var toolbarLabelStyle = ToolbarLabelStyle.iconOnly

    init() {
        // Deployment initializes the canonical sandbox before copying an older debug profile into it.
        if CommandLine.arguments.contains("--prepare-profile") {
            do { try BrowserProfile.prepare(); exit(0) }
            catch {
                FileHandle.standardError.write(Data("Could not prepare Browser profile: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            BrowserWindow(bookmarks: bookmarks, downloads: downloads)
                .modifier(ScrollbarVisibility())
                .frame(minWidth: 680, minHeight: 440)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    BrowserSessionStore.shared.flush()
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarLabelStyle($toolbarLabelStyle)
        .commands {
            ToolbarCommands()
            BrowserCommands(bookmarks: bookmarks)
        }
        Settings { BrowserSettings() }
            .windowStyle(.hiddenTitleBar)
    }
}

private final class BrowserApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Both build variants share a bundle identity. Use this bundle's icon for
        // the running app rather than a cached icon from the other variant.
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
    @FocusedValue(\.browserModel) private var browser
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
        guard let tab = browser?.activeTab, !tab.isNewTab, tab.url != nil else { return nil }
        return tab
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
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
            .keyboardShortcut("+", modifiers: [.command, .shift])
            .disabled(browser == nil || (browser?.activeSplit?.tabIDs.count ?? 1) >= SplitTabGroup.limit)
            if let browser, let tab = browser.activeTab, browser.activeSplit != nil {
                SplitTabMenu(browser: browser, tab: tab)
            }
            Divider()
            Button("New Folder…") { browser?.requestNewFolder() }
            Button(browser?.isTidyingTabs == true ? "Cancel Tidying" : "Tidy Tabs") {
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
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
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
}
