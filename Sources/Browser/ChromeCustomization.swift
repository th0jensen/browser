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
    static let toolbarLabelStyleKey = "toolbarLabelStyle"
    @MainActor static func customizeToolbar(in window: NSWindow? = nil) {
        let target = window ?? NSApp.orderedWindows.first { $0.toolbar?.allowsUserCustomization == true }
        target?.toolbar?.isVisible = true
        target?.makeKeyAndOrderFront(nil)
        target?.runToolbarCustomizationPalette(nil)
    }

}

/// Toolbar actions stay about chrome; tab and folder actions live on their own items.
struct ToolbarContextMenu: View {
    let customize: () -> Void
    var browser: BrowserModel? = nil
    var window: NSWindow? = nil
    @AppStorage(CompactToolbar.storageKey) private var autoHide = false
    @AppStorage(TabLayout.storageKey) private var layout = TabLayout.horizontal
    @AppStorage(ChromeCustomization.toolbarLabelStyleKey) private var labelStyle = ToolbarLabelStyle.iconOnly

    var body: some View {
        Toggle("Auto-hide Toolbar", isOn: $autoHide)
            .keyboardShortcut("s", modifiers: [.control, .command])
        if let browser {
            Button("Focus Address Bar") { browser.requestAddressFocus() }
                .keyboardShortcut("l", modifiers: .command)
        }
        Divider()
        TabLayoutMenu()
        if layout == .vertical { Menu("Sidebar") { SidebarBehaviorMenu() } }
        Menu("Bookmarks") { BookmarksBehaviorMenu() }
        Divider()
        Menu("Toolbar Display") {
            displayChoice("Icons Only", style: .iconOnly)
            displayChoice("Icons and Text", style: .titleAndIcon)
            displayChoice("Text Only", style: .titleOnly)
        }
        Button("Customize Toolbar…", action: customize)
    }

    private func displayChoice(_ title: String, style: ToolbarLabelStyle) -> some View {
        Toggle(title, isOn: Binding(get: { labelStyle == style }, set: { if $0 { labelStyle = style } }))
    }
}

extension ToolbarLabelStyle {
    var chromeControlHeight: CGFloat { self == .titleAndIcon ? 42 : BrowserChrome.toolbarHeight }
    var nativeDisplayMode: NSToolbar.DisplayMode {
        self == .titleOnly ? .labelOnly : self == .titleAndIcon ? .iconAndLabel : .iconOnly
    }
}

/// Custom toolbar views must follow the same persisted style as the native scene.
struct ChromeToolbarLabelStyle: LabelStyle {
    @AppStorage(ChromeCustomization.toolbarLabelStyleKey) private var style = ToolbarLabelStyle.iconOnly

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if style == .titleOnly { configuration.title }
        else if style == .titleAndIcon {
            VStack(spacing: 2) {
                configuration.icon
                configuration.title.font(.system(size: 10))
            }
        } else { configuration.icon }
    }
}

struct TabLayoutMenu: View {
    @AppStorage(TabLayout.storageKey) private var layout = TabLayout.horizontal

    var body: some View {
        Menu("Tab Layout") {
            Picker("Layout", selection: $layout) {
                Text("Horizontal").tag(TabLayout.horizontal)
                Text("Vertical").tag(TabLayout.vertical)
            }.pickerStyle(.inline).labelsHidden()
        }
    }
}

struct SidebarBehaviorMenu: View {
    @AppStorage(SidebarVisibility.autoHideKey) private var autoHide = false
    @AppStorage(ChromeCustomization.compactKey) private var compactTabs = true

    var body: some View {
        Toggle("Auto-hide Sidebar", isOn: $autoHide)
            .keyboardShortcut("s", modifiers: .command)
        Toggle("Compact Tab Rows", isOn: $compactTabs)
    }
}

struct BookmarksBehaviorMenu: View {
    @AppStorage(BookmarksBarVisibility.storageKey) private var visibility = BookmarksBarVisibility.always
    @AppStorage(ChromeCustomization.bookmarkButtonKey) private var showsButton = true

    var body: some View {
        Picker("Bookmarks Bar", selection: $visibility) {
            ForEach(BookmarksBarVisibility.allCases) { value in Text(value.title).tag(value) }
        }.pickerStyle(.inline)
        Divider()
        Toggle("Show Bookmark Button", isOn: $showsButton)
    }
}
