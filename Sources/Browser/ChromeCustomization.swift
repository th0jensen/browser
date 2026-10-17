import AppKit
import SwiftUI

enum ToolbarComponent: String, CaseIterable, Identifiable {
    case sidebar, tabLayout, pinSidebar, newTab, downloads, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sidebar: "Reveal Sidebar"
        case .tabLayout: "Tab Layout"
        case .pinSidebar: "Pin / Auto-hide Sidebar"
        case .newTab: "New Tab"
        case .downloads: "Downloads"
        case .settings: "Extensions and Settings"
        }
    }
}

enum ChromeCustomization {
    static let widthKey = "verticalSidebarWidth"
    static let compactKey = "compactSidebarTabs"
    static let bookmarkButtonKey = "showsBookmarkButton"
    @MainActor static func customizeToolbar(in window: NSWindow? = nil) {
        let target = window ?? NSApp.orderedWindows.first { $0.toolbar?.allowsUserCustomization == true }
        target?.toolbar?.isVisible = true
        target?.makeKeyAndOrderFront(nil)
        target?.runToolbarCustomizationPalette(nil)
    }

}

/// The same menu is used in the toolbar, tab rows and empty sidebar space.
struct ChromeCustomizationMenu: View {
    let customize: () -> Void
    @AppStorage(TabLayout.storageKey) private var layout = TabLayout.horizontal
    @AppStorage(SidebarVisibility.autoHideKey) private var autoHide = false
    @AppStorage(CompactToolbar.storageKey) private var compactToolbar = false
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarks = BookmarksBarVisibility.always
    @AppStorage(ChromeCustomization.bookmarkButtonKey) private var showsBookmarkButton = true

    var body: some View {
        Divider()
        Button("Customize Toolbar…", action: customize)
        Toggle("Compact Toolbar (⌘S)", isOn: $compactToolbar)
        Picker("Tab Layout", selection: $layout) {
            Text("Horizontal").tag(TabLayout.horizontal)
            Text("Vertical").tag(TabLayout.vertical)
        }
        if layout == .vertical { Toggle("Automatically Hide Sidebar", isOn: $autoHide) }
        Toggle("Show Bookmarks Bar", isOn: Binding(get: { bookmarks != .never }, set: { bookmarks = $0 ? .always : .never }))
        Toggle("Show Bookmark Button", isOn: $showsBookmarkButton)
        Picker("Bookmarks Bar Behavior", selection: $bookmarks) {
            ForEach(BookmarksBarVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
        }
    }
}

