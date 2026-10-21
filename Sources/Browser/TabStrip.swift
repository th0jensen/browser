import AppKit
import SwiftUI

struct TabFrameKey: PreferenceKey {
    static let defaultValue: [UUID: Anchor<CGRect>] = [:]

    static func reduce(value: inout [UUID: Anchor<CGRect>], nextValue: () -> [UUID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Native horizontal popovers position themselves; only the in-window sidebar
/// hover card needs to send changing row geometry through the window tree.
private struct TabFrameReporter: ViewModifier {
    let id: UUID
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.anchorPreference(key: TabFrameKey.self, value: .bounds) { [id: $0] }
        } else {
            content
        }
    }
}

struct TabStrip: View {
    let browser: BrowserModel
    let layout: TabLayout
    let isFullScreen: Bool
    @Binding var hoverCardTabID: UUID?
    var usesNativeHoverPopover = false
    var floating = false
    @AppStorage(ChromeCustomization.compactKey) private var compactTabs = true
    @AppStorage(BrowserIntelligence.showsTidyTabsKey) private var showsTidyTabs = true

    @State private var hoveredTabID: UUID?
    @State private var suppressedHoverCardTabID: UUID?
    @State private var sidebarViewport: CGRect?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let spacing: CGFloat = 4
    private let maxTabWidth: CGFloat = 220
    private let minTabWidth: CGFloat = 56
    /// Always leave some empty strip to drag the window by.
    private let minDragAreaWidth: CGFloat = 40

    var body: some View {
        Group {
            switch layout {
            case .horizontal: horizontalStrip
            case .vertical: sidebar
            }
        }
        .modifier(SplitDropBadge(controller: browser.tabDrag))
        .task(id: hoveredTabID) { await updateHoverCard() }
        .onChange(of: browser.tabDrag.payload) { _, value in if value != nil { hoverCardTabID = nil } }
        .onChange(of: browser.activeSpaceID) { _, _ in
            hoveredTabID = nil
            hoverCardTabID = nil
            suppressedHoverCardTabID = nil
        }
        .alert("On-device Intelligence", isPresented: Binding(get: { browser.intelligenceError != nil }, set: { if !$0 { browser.intelligenceError = nil } })) {
            Button("OK") { browser.intelligenceError = nil }
        } message: { Text(browser.intelligenceError ?? "") }
    }

    private var horizontalStrip: some View {
        GeometryReader { geometry in
            let regularTabs = browser.unpinnedTabs.filter { !browser.isSplitCompanion($0) }
            let visibleCount = regularTabs.filter { browser.sectionIsExpanded($0.temporarySection) }.count
            let count = CGFloat(max(1, visibleCount))
            let availableWidth = max(minTabWidth, geometry.size.width - BrowserChrome.edgeInset
                                     - minDragAreaWidth - (browser.isPrivate || browser.isExtensionWindow ? 0 : 130))
            let sectionCount = regularTabs.enumerated().filter { index, tab in
                tab.temporarySection != nil && (index == 0 || regularTabs[index - 1].temporarySection?.id != tab.temporarySection?.id)
            }.count
            let headerSpace = CGFloat(sectionCount) * (100 + spacing)
            let tabWidth = min(maxTabWidth,
                               max(minTabWidth, ((availableWidth - headerSpace - spacing * (count - 1)) / count).rounded(.down)))
            let isEditing = regularTabs.contains { $0.folderPageID != nil && $0.folderPageID == browser.renamingSavedPageID }
            let editingExtra = isEditing ? max(0, 160 - tabWidth) : 0
            let tabsWidth = tabWidth * CGFloat(visibleCount) + spacing * CGFloat(max(0, visibleCount - 1)) + headerSpace + editingExtra

            HStack(spacing: spacing) {
                if !browser.isPrivate && !browser.isExtensionWindow {
                    SpaceSwitcher(browser: browser).frame(width: 130)
                }
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: spacing) {
                            ForEach(Array(regularTabs.enumerated()), id: \.element.id) { index, tab in
                                if let section = tab.temporarySection,
                                   index == 0 || regularTabs[index - 1].temporarySection?.id != section.id {
                                    TemporarySectionRow(browser: browser, section: section, height: BrowserChrome.tabHeight,
                                                        horizontal: true)
                                        .frame(width: 100).id(section.id)
                                }
                                if browser.sectionIsExpanded(tab.temporarySection) {
                                    tabItem(for: tab, at: index,
                                            nextTab: regularTabs.indices.contains(index + 1) ? regularTabs[index + 1] : nil,
                                            width: tab.folderPageID != nil && tab.folderPageID == browser.renamingSavedPageID ? max(160, tabWidth) : tabWidth)
                                        .id(tab.id)
                                }
                            }
                        }
                        .frame(height: BrowserChrome.tabRowHeight)
                    }
                    .modifier(ScrollbarVisibility())
                    .scrollDisabled(tabsWidth <= availableWidth)
                    .onAppear {
                        if tabsWidth > availableWidth, let id = browser.activeSplit?.anchorID ?? browser.activeTabID { scrollProxy.scrollTo(id) }
                    }
                    .onChange(of: geometry.size.width) { _, _ in
                        // Fitting tabs are already visible. Scrolling them on every window-size update
                        // adds a second scroll/layout transaction to the native resize path.
                        if tabsWidth > availableWidth, let id = browser.activeSplit?.anchorID ?? browser.activeTabID { scrollProxy.scrollTo(id) }
                    }
                    .onChange(of: browser.renamingSavedPageID) { _, pageID in
                        if let pageID, let tab = regularTabs.first(where: { $0.folderPageID == pageID }) { scrollProxy.scrollTo(tab.id) }
                    }
                    .onChange(of: browser.activeTabID) { _, activeTabID in
                        guard tabsWidth > availableWidth, let activeTabID else { return }
                        scrollProxy.scrollTo(browser.activeSplit?.anchorID ?? activeTabID)
                    }
                }
                .frame(width: min(tabsWidth, availableWidth))

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .contextMenu { stripMenu }
            }
            // The native titlebar container owns the gap after the traffic lights.
            .padding(.trailing, BrowserChrome.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: BrowserChrome.tabRowHeight)
        .background(HorizontalTabAnchor())
    }

    private var sidebar: some View {
        GeometryReader { geometry in
            let rowHeight = compactTabs ? BrowserChrome.sidebarTabHeight : 42
            let regularTabs = browser.regularTabs
            let groups = browser.temporaryTabGroups
            let count = browser.sidebarFolderRows.count + groups.reduce(0) { count, group in
                count + (group.section == nil ? 0 : 1) + (browser.sectionIsExpanded(group.section) ? group.tabs.count : 0)
            }
            let tabsHeight = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * BrowserChrome.smallGap
            let pinRows = CGFloat(max(1, (browser.pinnedPages.items.count + 2) / 3))
            let pinHeight = pinRows * PinnedPagesGrid.tileHeight + (pinRows - 1) * BrowserChrome.edgeInset + BrowserChrome.edgeInset + 16
            let dropGapHeight = sidebarDividerHeight + BrowserChrome.smallGap * 3
            let spaceControlHeight: CGFloat = browser.isPrivate || browser.isExtensionWindow ? 0 : 64 + BrowserChrome.edgeInset * 2
            let newTabFits = spaceControlHeight + dropGapHeight + tabsHeight + (count > 0 ? BrowserChrome.smallGap : 0) + rowHeight + BrowserChrome.edgeInset + pinHeight <= geometry.size.height

            VStack(spacing: BrowserChrome.edgeInset) {
                PinnedPagesGrid(browser: browser)
                    .padding(.horizontal, BrowserChrome.edgeInset)
                    .zIndex(browser.tabDrag.payload?.hasPrefix("browser-essential:") == true ? 200 : 0)
                BrowserSpaceHeading(browser: browser)
                    .padding(.horizontal, BrowserChrome.edgeInset)
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        VStack(spacing: BrowserChrome.smallGap) {
                            sidebarDropGap(.pinnedRoot)
                            if !browser.folders.items.isEmpty {
                                FolderSidebar(browser: browser, rowHeight: rowHeight, onDropAccepted: { hoverCardTabID = nil },
                                              rootDropTargetInSpacing: true)
                                    .zIndex(browser.tabDrag.payload?.hasPrefix("browser-folder:") == true ? 100 : 0)
                            }
                            sidebarDivider
                            ForEach(groups) { group in
                                if let section = group.section {
                                    TemporarySectionRow(browser: browser, section: section, height: rowHeight,
                                                        horizontal: false).id(section.id)
                                }
                                if browser.sectionIsExpanded(group.section) {
                                    ForEach(group.tabs) { tab in
                                        tabItem(for: tab, at: regularTabs.firstIndex { $0.id == tab.id } ?? 0, width: nil)
                                            .padding(.leading, group.section == nil ? 0 : 14).id(tab.id)
                                    }
                                }
                            }
                            if newTabFits { newTabRow(height: rowHeight) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.tabReorderViewport, sidebarViewport)
                        .padding(.horizontal, BrowserChrome.edgeInset)

                        .padding(.bottom, newTabFits ? BrowserChrome.edgeInset : 0)
                    }
                    .modifier(ScrollbarVisibility())
                    .scrollClipDisabled(browser.tabDrag.payload != nil)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sidebarViewport = $0 }
                    .onChange(of: browser.activeTabID) { _, activeTabID in
                        guard let activeTabID else { return }
                        let representedTab = browser.tab(withID: browser.activeSplit?.anchorID ?? activeTabID)
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            scrollProxy.scrollTo(representedTab?.folderPageID ?? representedTab?.id ?? activeTabID)
                        }
                    }
                }
                if !newTabFits {
                    newTabRow(height: rowHeight)
                        .padding(.horizontal, BrowserChrome.edgeInset)
                        .padding(.bottom, BrowserChrome.edgeInset)
                }
                if !browser.isPrivate && !browser.isExtensionWindow {
                    // Persistent navigation, outside both the tab scroller and its New Tab row.
                    SpaceSwitcher(browser: browser, style: .sidebar)
                        .padding(.horizontal, BrowserChrome.edgeInset)
                        .padding(.bottom, BrowserChrome.edgeInset)
                }
            }
            .background {
                if !browser.isPrivate && !browser.isExtensionWindow {
                    (browser.spaces.space(browser.activeSpaceID)?.theme.color ?? .accentColor).opacity(0.035)
                }
            }
            .contextMenu { stripMenu }
        }
        .padding(.top, BrowserChrome.edgeInset)
    }

    private func sidebarDropGap(_ item: SidebarDragItem) -> some View {
        RoundedRectangle(cornerRadius: BrowserChrome.smallGap / 2)
            .fill(browser.tabDrag.isOver(item.payload) ? Color.accentColor.opacity(0.5) : .clear)
            .frame(height: BrowserChrome.smallGap)
            .modifier(TabReorderTarget(controller: browser.tabDrag, payload: item.payload, priority: 2))
    }

    private var showsTidyDivider: Bool {
        showsTidyTabs && (browser.regularTabs.count > 6 || browser.isTidyingTabs
            || browser.regularTabs.contains { $0.temporarySection != nil })
    }

    private var sidebarDividerHeight: CGFloat {
        showsTidyDivider ? 32 : BrowserChrome.smallGap + BrowserChrome.edgeInset * 2
    }

    private var sidebarDivider: some View {
        Group {
            if showsTidyDivider {
                tidyButton
            } else {
                Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: sidebarDividerHeight)
        .background(browser.tabDrag.isOver(SidebarDragItem.temporaryRoot.payload)
                    ? Color.accentColor.opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: BrowserChrome.smallGap / 2))
        .modifier(TabReorderTarget(controller: browser.tabDrag, payload: SidebarDragItem.temporaryRoot.payload, priority: 2))
    }

    private var tidyButton: some View {
        HStack {
            Button {
                if browser.isTidyingTabs { browser.cancelTidyingTabs() } else { browser.tidyTemporaryTabs() }
            } label: {
                Label("Tidy Tabs", systemImage: "sparkles")
            }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .disabled(!browser.isTidyingTabs && (!browser.canTidyTabs || BrowserIntelligence.unavailableReason != nil))
            .help(BrowserIntelligence.unavailableReason ?? "Group temporary tabs by topic on this Mac")
            .accessibilityLabel(browser.isTidyingTabs ? "Cancel Tidy Tabs" : "Tidy Tabs")
            .onHover { value in if value { Task { await LocalIntelligence.shared.prepare(.tidy) } } }
            TidyActivityDivider(isLoading: browser.isTidyingTabs)
        }.frame(maxWidth: .infinity).padding(.leading, BrowserChrome.edgeInset)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Remove All Temporary Groups") { browser.removeTemporarySections() }
                    .disabled(!browser.regularTabs.contains { $0.temporarySection != nil })
            }
    }

    private func newTabRow(height: CGFloat) -> some View {
        Button { browser.addTab() } label: {
            Label("New Tab", systemImage: "plus")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
                .padding(.leading, BrowserChrome.edgeInset)
                .contentShape(RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius))
        }
        .folderEditorAnchor(.sidebar)
        .buttonStyle(NewTabRowButtonStyle())
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
        .modifier(TabReorderTarget(controller: browser.tabDrag, payload: "browser-temporary-end"))
    }

    private func tabItem(for tab: BrowserTab, at index: Int, nextTab: BrowserTab? = nil, width: CGFloat?) -> some View {
        let isActive = browser.splitIsActive(tab)
        let isHovered = hoveredTabID == tab.id
        let showsSeparator = layout == .horizontal && nextTab.map { next in
            !isActive && !isHovered && browser.activeTabID != next.id && hoveredTabID != next.id
        } ?? false

        return TabItem(browser: browser, tab: tab,
                       isActive: isActive,
                       isHovered: isHovered,
                       floating: floating,
                       width: width,
                       height: layout == .vertical ? (compactTabs ? BrowserChrome.sidebarTabHeight : 42) : BrowserChrome.tabHeight,
                       select: {
                           suppressedHoverCardTabID = tab.id
                           hoverCardTabID = nil
                           browser.selectRepresentedTab(tab)
                       },
                       close: {
                           hoverCardTabID = nil
                           browser.closeRepresentedTab(tab)
                       })
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 14)
                    .offset(x: (spacing + 1) / 2)
                    .opacity(showsSeparator ? 1 : 0)
            }
            .modifier(TabFrameReporter(id: tab.id, enabled: !usesNativeHoverPopover))
            .onHover { isHovering in
                if isHovering {
                    hoveredTabID = tab.id
                } else if hoveredTabID == tab.id {
                    hoveredTabID = nil
                }
            }
            .modifier(TabDragSource(controller: browser.tabDrag, payload: tab.id.uuidString,
                                    axis: layout == .vertical ? .vertical : .horizontal,
                                    enabled: browser.renamingSavedPageID == nil, began: {
                hoverCardTabID = nil
                suppressedHoverCardTabID = tab.id
                if layout == .vertical { browser.chromeHover?.sidebarIsReordering = true }
            }, ended: { target in
                browser.finishDraggedTab(tab.id.uuidString, over: target)
                browser.chromeHover?.sidebarIsReordering = false
            }, crossed: { target, direction in
                browser.crossDraggedTab(tab.id.uuidString, past: target, direction: direction)
            }))
            .modifier(TabSplitTarget(browser: browser, payload: tab.id.uuidString,
                                     axis: layout == .vertical ? .vertical : .horizontal))
            .contextMenu { tabMenu(for: tab, at: index) }
            .modifier(TabSavedRename(browser: browser, tab: tab))
            .folderEditorAnchor(.tab(tab.id))
            .popover(isPresented: Binding(get: { usesNativeHoverPopover && hoverCardTabID == tab.id },
                                           set: { if !$0 { hoverCardTabID = nil } }), arrowEdge: .top) {
                TabHoverCard(tab: tab, isActive: isActive).padding(8)
            }
    }

    /// Shows the card after a short delay, then follows the pointer between tabs without waiting again.
    private func updateHoverCard() async {
        guard browser.tabDrag.payload == nil else { hoverCardTabID = nil; return }
        guard let hoveredTabID else {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            hoverCardTabID = nil
            suppressedHoverCardTabID = nil
            return
        }
        guard hoveredTabID != suppressedHoverCardTabID else { return }
        if hoverCardTabID != nil {
            hoverCardTabID = hoveredTabID
            return
        }
        try? await Task.sleep(for: .milliseconds(550))
        guard !Task.isCancelled, browser.tabDrag.payload == nil else { return }
        hoverCardTabID = hoveredTabID
    }

    @ViewBuilder
    private func tabMenu(for tab: BrowserTab, at index: Int) -> some View {
        SplitTabMenu(browser: browser, tab: tab)
        Button("Reload") { browser.reloadTab(tab.id) }
            .disabled(tab.isNewTab)
        Button("Duplicate") { browser.duplicateTab(tab.id) }
        Button("Copy Link") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        .disabled(tab.url == nil)
        Divider()
        if let page = browser.folders.item(tab.folderPageID) {
            Button("Rename…") { browser.renamingSavedPageID = page.id }
            if page.nameSource == .manual || page.nameSource == .automatic {
                Button("Use Original Title") { browser.changeFolders { try browser.folders.resetPageName(page.id) } }
            }
            Divider()
        }
        FolderMoveMenu(browser: browser, tab: tab)
        TabPinActions(browser: browser, tab: tab)
        Divider()
        Button("Close Tab") { browser.closeRepresentedTab(tab) }
        Button("Close Other Tabs") { browser.closeOtherTabs(than: tab.id) }
            .disabled(browser.tabs.count < 2)
        Button(layout == .vertical ? "Close Tabs Below" : "Close Tabs to the Right") { browser.closeTabs(after: tab.id) }
            .disabled(browser.tabs.last?.id == tab.id)
        Divider()
        Button("Reopen Closed Tab") { browser.reopenClosedTab() }
            .disabled(!browser.canReopenClosedTab)
    }

    @ViewBuilder
    private var stripMenu: some View {
        Button("New Tab") { browser.addTab() }
        Button("New Folder…") { browser.requestNewFolder() }
        Button("Reopen Closed Tab") { browser.reopenClosedTab() }
            .disabled(!browser.canReopenClosedTab)
        Divider()
        Button(browser.isTidyingTabs ? "Cancel Tidy Tabs" : "Tidy Tabs") {
            if browser.isTidyingTabs { browser.cancelTidyingTabs() } else { browser.tidyTemporaryTabs() }
        }.disabled(!browser.isTidyingTabs && (!browser.canTidyTabs || BrowserIntelligence.unavailableReason != nil))
        if browser.regularTabs.contains(where: { $0.temporarySection != nil }) {
            Button("Remove All Temporary Groups") { browser.removeTemporarySections() }
        }
        Divider()
        TabLayoutMenu(preferences: browser.chromePreferences)
        if layout == .vertical { SidebarBehaviorMenu() }
    }
}

private struct NewTabRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.09)
                        : isHovered ? Color.primary.opacity(0.045) : Color.clear,
                        in: RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius, style: .continuous))
            .onHover { isHovered = $0 }
    }
}

private struct TabItem: View {
    let browser: BrowserModel
    let tab: BrowserTab
    let isActive: Bool
    let isHovered: Bool
    let floating: Bool
    /// A fixed width in the tab strip, or `nil` to fill the sidebar.
    let width: CGFloat?
    let height: CGFloat
    let select: () -> Void
    let close: () -> Void

    private var isCompact: Bool { (width ?? .infinity) < 100 }
    /// Narrow tabs keep their icon visible and only swap in the close button while hovered.
    private var showsCloseButton: Bool { isHovered || (isActive && !isCompact) }

    var body: some View {
        let dragging = browser.tabDrag.payload == tab.id.uuidString
        let shape = RoundedRectangle(cornerRadius: dragging ? height / 2 : BrowserChrome.contentCornerRadius, style: .continuous)

        HStack(spacing: 7) {
            if browser.split(containing: tab.id) == nil && !(isCompact && showsCloseButton) {
                TabIcon(tab: tab)
            }
            if !isCompact {
                title
            }
            if browser.split(containing: tab.id) == nil && (showsCloseButton || (width != nil && !isCompact)) {
                closeButton
                    .opacity(showsCloseButton ? 1 : 0)
                    .allowsHitTesting(showsCloseButton)
            }
        }
        .padding(.leading, isCompact ? 0 : BrowserChrome.edgeInset)
        .padding(.trailing, isCompact ? 0 : (width == nil ? BrowserChrome.edgeInset : 4))
        .opacity(dragging || (tab.folderPageID != nil && browser.renamingSavedPageID == tab.folderPageID) ? 1 : BrowserChrome.tabContentOpacity(active: isActive, hovered: isHovered, loaded: !tab.isSuspended))
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(shape.fill(isHovered && !isActive && !dragging ? Color.primary.opacity(0.055) : Color.clear))
        .modifier(ActiveTabGlass(isActive: isActive || dragging, shape: shape))
        .overlay {
            shape.strokeBorder(Color.primary.opacity(isActive ? 0.07 : 0), lineWidth: 1)
        }
        .contentShape(shape)
        .onTapGesture(perform: select)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var title: some View {
        if let split = browser.split(containing: tab.id) {
            SplitTabLabel(browser: browser, split: split, showsCloseButtons: isHovered || isActive)
        } else if let page = browser.folders.item(tab.folderPageID) {
            SavedTabTitle(browser: browser, page: page, isActive: isActive, fades: true)
        } else { ordinaryTitle }
    }

    private var ordinaryTitle: some View {
        // The title lives in an overlay so its natural width never widens the tab.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Text(tab.title)
                    .font(.system(size: 12.5, weight: isActive ? .medium : .regular))
                    .tracking(-0.1)
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            // Fade long titles instead of truncating them with an ellipsis.
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 16)
                }
            }
            .clipped()
            .accessibilityElement()
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }

    private var closeButton: some View {
        TabDismissButton(tab: tab, close: close)
    }
}

private struct TabIcon: View {
    let tab: BrowserTab

    var body: some View {
        Group {
            if tab.isLoading && !tab.isNewTab {
                ProgressView()
                    .controlSize(.mini)
            } else if let favicon = tab.favicon {
                favicon
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.light)
                    .foregroundStyle(Color.primary)
            }
        }
        .frame(width: 14, height: 14)
    }
}

struct TabHoverCard: View {
    let tab: BrowserTab
    let isActive: Bool

    static let width: CGFloat = 280
    static let previewHeight: CGFloat = 156

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            if !isActive, !tab.isNewTab, let thumbnail = tab.thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: Self.previewHeight, alignment: .top)
                    .clipped()
                Divider()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if tab.isSecure {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8.5, weight: .semibold))
                    }
                    Text(subtitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: Self.width, alignment: .leading)
        .glassEffect(.regular, in: shape)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var subtitle: String {
        if tab.isNewTab { return "Start page" }
        let host = tab.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
            ?? tab.url?.absoluteString ?? ""
        return tab.isLoading ? "\(host) · Loading…" : host
    }
}

struct ActiveTabGlass: ViewModifier {
    let isActive: Bool
    let shape: RoundedRectangle

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
        }
    }
}

struct ChromeIconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary.opacity(0.5))
            .frame(width: size, height: size)
            .background(!isEnabled ? Color.clear :
                        configuration.isPressed ? Color.primary.opacity(0.12) :
                        isHovered ? Color.primary.opacity(0.07) : Color.clear,
                        in: RoundedRectangle(cornerRadius: size <= 28 ? 8 : 10, style: .continuous))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

struct ChromeCloseButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .background(configuration.isPressed ? Color.primary.opacity(0.14) :
                        isHovered ? Color.primary.opacity(0.09) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { isHovered = $0 }
    }
}

private struct TabSavedRename: ViewModifier {
    let browser: BrowserModel
    let tab: BrowserTab
    @ViewBuilder func body(content: Content) -> some View {
        if let page = browser.folders.item(tab.folderPageID) { content.modifier(SavedTabRename(browser: browser, page: page)) }
        else { content }
    }
}
