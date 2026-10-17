import SwiftUI
import WebKit

struct BrowserSettings: View {
    @State private var extensions = BrowserExtensions.shared
    @State private var passkeys = PasskeyAccess.shared
    @AppStorage(ChromeCustomization.widthKey) private var sidebarWidth = Double(BrowserChrome.sidebarWidth)
    @AppStorage(ChromeCustomization.compactKey) private var compactTabs = true
    @AppStorage(TabLayout.storageKey) private var tabLayout = TabLayout.horizontal
    @AppStorage(SidebarVisibility.autoHideKey) private var autoHideSidebar = false
    @AppStorage(BookmarksBarVisibility.storageKey) private var bookmarksBar = BookmarksBarVisibility.always
    @AppStorage(ChromeCustomization.bookmarkButtonKey) private var showsBookmarkButton = true

    var body: some View {
        Form {
            Section("Tabs") {
                Button("Customize Toolbar…") { ChromeCustomization.customizeToolbar() }
                Picker("Tab layout", selection: $tabLayout) {
                    Text("Horizontal").tag(TabLayout.horizontal)
                    Text("Vertical").tag(TabLayout.vertical)
                }
                Toggle("Automatically hide sidebar (⌘S)", isOn: $autoHideSidebar)
                    .disabled(tabLayout != .vertical)
                Toggle("Compact sidebar tabs", isOn: $compactTabs)
                LabeledContent("Sidebar width", value: "\(Int(sidebarWidth)) pt")
                Slider(value: $sidebarWidth, in: BrowserChrome.sidebarMinimumWidth...BrowserChrome.sidebarMaximumWidth, step: 4)
                Text("With auto-hide enabled, move the pointer to the left edge to reveal a floating sidebar. Press ⌘S to pin it. Save a webpage with ⇧⌘S.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Bookmarks") {
                Toggle("Show bookmarks bar", isOn: Binding(get: { bookmarksBar != .never }, set: { bookmarksBar = $0 ? .always : .never }))
                Toggle("Show bookmark button in address bar", isOn: $showsBookmarkButton)
                Picker("Bookmarks bar behavior", selection: $bookmarksBar) {
                    ForEach(BookmarksBarVisibility.allCases) { visibility in Text(visibility.title).tag(visibility) }
                }
            }
            Section("Extensions") {
                ForEach(extensions.installed) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Toggle(item.name, isOn: Binding(get: { item.isEnabled }, set: { enabled in
                                Task { await extensions.setEnabled(item, enabled) }
                            }))
                            .disabled(extensions.isBusy || item.needsNativeMessaging)
                            Spacer()
                            if item.sourceAppName == nil {
                                Button("Remove", role: .destructive) { extensions.remove(item) }
                                    .disabled(extensions.isBusy)
                            }
                        }
                        if let appName = item.sourceAppName {
                            Text("From \(appName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(item.kind == .contentBlocker ? "Content blocker · reload pages after changing rules" : "Web Extension")
                            .font(.caption).foregroundStyle(.secondary)
                        if item.needsNativeMessaging {
                            Text("Requires Safari’s native companion messaging. Browser can use bundled content-blocker rules separately.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let error = extensions.errors[item.id] {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                }
                Button("Check for Extensions") { Task { await extensions.refreshInstalledApplications() } }
                    .disabled(extensions.isBusy)
                Text("Safari Web Extensions in Applications appear automatically. Enable an extension to review its permissions. Native Safari App Extensions require Safari.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Development") {
                    Button("Import Extension…") { Task { await extensions.chooseImport() } }
                        .disabled(extensions.isBusy)
                    Text("Load an unpacked Web Extension, ZIP, Safari extension app, or content-blocker JSON.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Bundled 1Blocker rules are snapshots. Development → Import Extension can load updated rules. Safari’s live settings, custom rules, and companion features do not sync.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = extensions.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Section("Passkeys") {
                Text(passkeys.status.description).textSelection(.enabled)
                if passkeys.status == .notDetermined {
                    Button("Enable Passkeys…") { Task { await passkeys.requestAccess() } }
                        .disabled(passkeys.isRequesting)
                }
                Button("Refresh Passkey Access") { passkeys.refresh() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 620)
        .task { await extensions.restore(); passkeys.refresh() }
    }
}

struct ExtensionButton: View {
    let item: InstalledExtension
    let browser: BrowserModel
    @State private var extensions = BrowserExtensions.shared

    var body: some View {
        let _ = extensions.actionRevision
        if let context = extensions.context(for: item), let action = context.action(for: browser.activeTab) {
            Button {
                BrowserExtensions.shared.focus(browser)
                guard let tab = browser.activeTab else { return }
                context.userGesturePerformed(in: tab)
                context.performAction(for: browser.activeTab)
            } label: {
                Label {
                    Text(item.name)
                } icon: {
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let icon = action.icon(for: CGSize(width: 16, height: 16)) {
                                Image(nsImage: icon).resizable().scaledToFit()
                            } else { Image(systemName: "puzzlepiece.extension") }
                        }
                        .frame(width: 16, height: 16)
                        if !action.badgeText.isEmpty {
                            Text(action.badgeText).font(.system(size: 8, weight: .bold))
                                .padding(2).background(.tint, in: Capsule()).offset(x: 7, y: -7)
                        }
                    }
                }
            }
            .labelStyle(.iconOnly)
            .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
        .buttonStyle(.automatic)
        .controlSize(.regular)
            .disabled(!action.isEnabled || browser.activeTab == nil)
            .help(action.label.isEmpty ? item.name : action.label)
            .accessibilityLabel(item.name)
        }
    }
}
