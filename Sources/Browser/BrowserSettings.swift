import SwiftUI
import WebKit

struct BrowserSettings: View {
    let browsingData: BrowsingData
    private enum Category: String, CaseIterable, Identifiable {
        case general = "General", appearance = "Appearance", privacy = "Privacy", passwords = "Passwords", sites = "Site Settings", downloads = "Downloads", extensions = "Extensions", intelligence = "Intelligence"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .appearance: "paintpalette"
            case .privacy: "hand.raised"
            case .passwords: "key"
            case .sites: "globe"
            case .downloads: "arrow.down.circle"
            case .extensions: "puzzlepiece.extension"
            case .intelligence: "sparkles"
            }
        }
    }
    @State private var selection: Category? = .general
    @State private var extensions = BrowserExtensions.shared
    @State private var passkeys = PasskeyAccess.shared
    @AppStorage(ChromeCustomization.widthKey) private var sidebarWidth = Double(BrowserChrome.sidebarWidth)
    @AppStorage(ChromeCustomization.compactKey) private var compactTabs = true
    private var tabLayout: TabLayout { chromeTarget.preferences.tabLayout }
    @State private var chromeTarget = WindowChromeSettingsTarget.shared
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBar = BookmarksBarVisibility.always
    @AppStorage(ChromeCustomization.bookmarkButtonKey) private var showsBookmarkButton = true
    @AppStorage(AppearancePreferences.hideScrollbarsKey) private var hideScrollbars = false
    @AppStorage(AppearancePreferences.dimInactiveSplitsKey) private var dimInactive = true
    @AppStorage(AppearancePreferences.inactiveSplitOpacityKey) private var inactiveOpacity = 0.85
    @AppStorage(BrowserIntelligence.titlesKey) private var tidyTitles = false
    @AppStorage(BrowserIntelligence.downloadsKey) private var tidyDownloads = false
    @AppStorage(BrowserIntelligence.previewsKey) private var linkPreviews = false
    @AppStorage(PinnedNavigation.peekEnabledKey) private var peekLinks = true

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Browser") { category(.general); category(.appearance); category(.downloads) }
                Section("Privacy and Security") { category(.privacy); category(.passwords); category(.sites) }
                Section("Features") { category(.extensions); category(.intelligence) }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text((selection ?? .general).rawValue)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 4)
                Group {
                    switch selection ?? .general {
                    case .general: GeneralSettings(updater: .shared, additionalSettings: AnyView(general))
                    case .appearance: Form { appearance }
                    case .privacy: PrivacySettings(browsingData: browsingData, contentBlocker: .shared)
                    case .passwords: PasswordSettings(passwords: .shared, passkeys: passkeys)
                    case .sites: SiteSettings(contentBlocker: .shared, sitePermissions: .shared, zoomLevels: .shared)
                    case .downloads: DownloadSettings()
                    case .extensions: Form { installedExtensions }
                    case .intelligence: Form { intelligence }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .modifier(ScrollbarVisibility())
        .frame(minWidth: 730, idealWidth: 780, minHeight: selection == .appearance ? 620 : 520, idealHeight: 620)
        .onChange(of: linkPreviews) { _, value in LinkPreviewController.shared.setEnabled(value) }
        .onChange(of: hideScrollbars) { _, value in PageAppearance.shared.setScrollbarsHidden(value) }
        .task { await extensions.restore(); passkeys.refresh() }
    }

    private func category(_ value: Category) -> some View { Label(value.rawValue, systemImage: value.symbol).tag(value) }

    private var general: some View {
        Group {
            Section("Tabs") {
                Picker("Tab layout", selection: Binding(get: { chromeTarget.preferences.tabLayout }, set: { chromeTarget.preferences.tabLayout = $0 })) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical").tag(TabLayout.vertical)
                }
            }
            Section("Bookmarks") {
                Picker("Bookmarks bar", selection: $bookmarksBar) {
                    ForEach(BookmarksBarVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
                }
                Toggle("Show bookmark button", isOn: $showsBookmarkButton)
            }
            Section("Links") {
                Toggle("Open external links from pinned tabs in Peek", isOn: $peekLinks)
            }
        }
    }

    private var appearance: some View {
        Group {
            Section("Toolbar") {
                Toggle("Automatically hide toolbar", isOn: Binding(get: { chromeTarget.preferences.autoHideToolbar }, set: { chromeTarget.preferences.autoHideToolbar = $0 }))
                    .disabled(tabLayout == .horizontal)
                Button("Customize Toolbar…") { ChromeCustomization.customizeToolbar(in: chromeTarget.browser?.window) }
            }
            Section("Sidebar") {
                Toggle("Automatically hide sidebar", isOn: Binding(get: { chromeTarget.preferences.autoHideSidebar }, set: { chromeTarget.preferences.autoHideSidebar = $0 })).disabled(tabLayout != .vertical)
                Toggle("Compact tabs", isOn: $compactTabs)
                LabeledContent("Width") {
                    HStack {
                        Slider(value: $sidebarWidth, in: BrowserChrome.sidebarMinimumWidth...BrowserChrome.sidebarMaximumWidth, step: 4)
                            .accessibilityLabel("Sidebar width")
                        Text("\(Int(sidebarWidth)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                    }.frame(maxWidth: 230)
                }
            }
            Section("Split View") {
                Toggle("Dim inactive panes", isOn: $dimInactive)
                LabeledContent("Inactive pane opacity") {
                    HStack {
                        Slider(value: $inactiveOpacity, in: 0.5...1, step: 0.05).accessibilityLabel("Inactive pane opacity")
                        Text(inactiveOpacity, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }.frame(maxWidth: 230)
                }.disabled(!dimInactive)
            }
            Section("Web Content") {
                Toggle("Hide scrollbars", isOn: $hideScrollbars)
            }
        }
    }

    private var intelligence: some View {
        Section("On-device Intelligence") {
            Toggle("Tidy pinned tab titles", isOn: $tidyTitles)
            Toggle("Tidy download names", isOn: $tidyDownloads)
            Toggle("5-second link previews", isOn: $linkPreviews)
            Text(BrowserIntelligence.modelDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var installedExtensions: some View {
        Group {
            Section("Installed Extensions") {
                if extensions.installed.isEmpty { Text("No extensions found").foregroundStyle(.secondary) }
                ForEach(extensions.installed) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Toggle(item.name, isOn: Binding(get: { item.isEnabled }, set: { enabled in
                                Task { await extensions.setEnabled(item, enabled) }
                            }))
                            .disabled(extensions.isBusy || item.needsNativeMessaging || (item.ruleCount == 0 && !item.isEnabled))
                            if item.sourceAppName == nil {
                                Button("Remove", role: .destructive) { extensions.remove(item) }.disabled(extensions.isBusy)
                            }
                        }
                        if item.needsNativeMessaging {
                            Text("Requires Safari’s companion app support").font(.caption).foregroundStyle(.secondary)
                        } else if item.kind == .contentBlocker {
                            Text(extensions.activeRuleCounts[item.id].map { "\($0.formatted()) active rules" }
                                 ?? (item.ruleCount == 0 ? "No usable content-blocking rules" : "Content blocker"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = extensions.errors[item.id] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }
                }
                Button("Refresh Extensions") { Task { await extensions.refreshInstalledApplications() } }.disabled(extensions.isBusy)
                if let error = extensions.lastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Development") {
                DisclosureGroup("Developer tools") {
                    Button("Import Extension…") { Task { await extensions.chooseImport() } }.disabled(extensions.isBusy)
                }
            }
        }
    }
}

struct ExtensionButton: View {
    let item: InstalledExtension
    let browser: BrowserModel
    @State private var extensions = BrowserExtensions.shared

    var body: some View {
        let _ = extensions.actionRevision
        if item.kind == .contentBlocker {
            ContentBlockerButton(item: item, browser: browser)
        } else {
            let context = extensions.context(for: item)
            let action = context?.action(for: browser.focusedPage)
            Button {
                guard let tab = browser.focusedPage else { return }
                Task { @MainActor in
                    await extensions.restore()
                    guard browser.tab(withID: tab.id) != nil, let readyContext = extensions.context(for: item),
                          readyContext.action(for: tab)?.isEnabled == true else { return }
                    extensions.focus(browser)
                    readyContext.userGesturePerformed(in: tab)
                    readyContext.performAction(for: tab)
                }
            } label: {
                Label {
                    Text(item.name)
                } icon: {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let icon = action?.icon(for: CGSize(width: 16, height: 16)) ?? extensions.toolbarIcon(for: item) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else { Image(systemName: "puzzlepiece.extension") }
                        }
                        .frame(width: 16, height: 16)
                        if let badge = action?.badgeText, !badge.isEmpty {
                            Text(badge).font(.system(size: 8, weight: .bold))
                                .padding(2).background(.tint, in: Capsule()).offset(x: 7, y: -7)
                        }
                    }
                }
            }
            .labelStyle(ChromeToolbarLabelStyle())
            .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
        .chromeToolbarButtonStyle()
        .controlSize(.regular)
            .disabled(!item.isEnabled || action?.isEnabled == false || extensions.errors[item.id] != nil || browser.focusedPage == nil)
            .help(action?.label.isEmpty == false ? action!.label : item.toolbarActionLabel ?? item.name)
            .accessibilityLabel(item.name)
        }
    }
}
