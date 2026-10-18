import SwiftUI

struct AppearanceSettings: View {
    @State private var windowSettingsTarget = WindowChromeSettingsTarget.shared
    @AppStorage(ChromeCustomization.widthKey) private var sidebarWidth = Double(BrowserChrome.sidebarWidth)
    @AppStorage(ChromeCustomization.compactKey) private var usesCompactTabs = true
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBarVisibility = BookmarksBarVisibility.always
    @AppStorage(ChromeCustomization.bookmarkButtonKey) private var showsBookmarkButton = true
    @AppStorage(AppearancePreferences.hideScrollbarsKey) private var hidesScrollbars = false
    @AppStorage(AppearancePreferences.dimInactiveSplitsKey) private var dimsInactivePanes = true
    @AppStorage(AppearancePreferences.inactiveSplitOpacityKey) private var inactivePaneOpacity = 0.85

    private var tabLayout: TabLayout { windowSettingsTarget.preferences.tabLayout }

    var body: some View {
        Form {
            Section("Tabs") {
                Picker("Tab layout", selection: Binding(get: { windowSettingsTarget.preferences.tabLayout }, set: { windowSettingsTarget.preferences.tabLayout = $0 })) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical").tag(TabLayout.vertical)
                }
            }
            Section("Bookmarks") {
                Picker("Bookmarks bar", selection: $bookmarksBarVisibility) {
                    ForEach(BookmarksBarVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
                }
                Toggle("Show bookmark button", isOn: $showsBookmarkButton)
            }
            Section("Toolbar") {
                Toggle("Automatically hide toolbar", isOn: Binding(get: { windowSettingsTarget.preferences.autoHideToolbar }, set: { windowSettingsTarget.preferences.autoHideToolbar = $0 }))
                    .disabled(tabLayout == .horizontal)
                Button("Customize Toolbar…") { ChromeCustomization.customizeToolbar(in: windowSettingsTarget.browser?.window) }
            }
            Section("Sidebar") {
                Toggle("Automatically hide sidebar", isOn: Binding(get: { windowSettingsTarget.preferences.autoHideSidebar }, set: { windowSettingsTarget.preferences.autoHideSidebar = $0 })).disabled(tabLayout != .vertical)
                Toggle("Compact tabs", isOn: $usesCompactTabs)
                LabeledContent("Width") {
                    HStack {
                        Slider(value: $sidebarWidth, in: BrowserChrome.sidebarMinimumWidth...BrowserChrome.sidebarMaximumWidth, step: 4)
                            .accessibilityLabel("Sidebar width")
                        Text("\(Int(sidebarWidth)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }.frame(maxWidth: 230)
                }
            }
            Section("Split View") {
                Toggle("Dim inactive panes", isOn: $dimsInactivePanes)
                LabeledContent("Inactive pane opacity") {
                    HStack {
                        Slider(value: $inactivePaneOpacity, in: 0.5...1, step: 0.05).accessibilityLabel("Inactive pane opacity")
                        Text(inactivePaneOpacity, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }.frame(maxWidth: 230)
                }.disabled(!dimsInactivePanes)
            }
            Section("Web Content") {
                Toggle("Hide scrollbars", isOn: $hidesScrollbars)
            }
        }
        .onChange(of: hidesScrollbars) { _, isHidden in PageAppearance.shared.setScrollbarsHidden(isHidden) }
    }
}
