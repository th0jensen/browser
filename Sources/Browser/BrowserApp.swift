import SwiftUI
import Darwin

@main
struct BrowserApp: App {
    @State private var bookmarks = BookmarkStore()
    @State private var downloads = DownloadManager()

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
                .frame(minWidth: 680, minHeight: 440)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    BrowserSessionStore.shared.flush()
                }
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            ToolbarCommands()
            BrowserCommands(bookmarks: bookmarks)
        }
        Settings { BrowserSettings() }
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
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.horizontal
    @AppStorage(SidebarVisibility.autoHideKey) private var autoHideSidebar = false
    @AppStorage(CompactToolbar.storageKey) private var compactToolbar = false

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
            Button("Close Tab") { browser?.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Webpage As…") { browser?.saveWebpage() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(browser?.activeTab?.isNewTab != false)
        }
        CommandMenu("Tabs") {
            Button("Pin Webpage") {
                if let browser, let tab = browser.activeTab { browser.pin(tab) }
            }
            .disabled(browser.flatMap { model in model.activeTab.map { model.canPin($0) } } != true)
            if let browser, !browser.pinnedPages.items.isEmpty {
                Menu("Pinned Pages") {
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
        CommandGroup(after: .toolbar) {
            Button("Open Location") { browser?.requestAddressFocus() }
                .keyboardShortcut("l", modifiers: .command)
            Button("Reload Page") { browser?.reload() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Back") { browser?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward") { browser?.goForward() }
                .keyboardShortcut("]", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(compactToolbar ? "Show Toolbar Permanently" : "Compact Toolbar") { compactToolbar.toggle() }
                .keyboardShortcut("s", modifiers: .command)
            Button(tabLayout == .vertical ? "Use Horizontal Tabs" : "Use Vertical Tabs") {
                tabLayout = tabLayout.toggled
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button(autoHideSidebar && tabLayout == .vertical ? "Pin Sidebar" : "Automatically Hide Sidebar") {
                let isAutoHiding = tabLayout == .vertical && autoHideSidebar
                tabLayout = .vertical
                autoHideSidebar = !isAutoHiding
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
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
        #if DEBUG
        CommandMenu("Develop") {
            Button("Show Web Inspector") { browser?.showWebInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(browser?.activeTab?.isNewTab != false)
        }
        #endif
    }
}
