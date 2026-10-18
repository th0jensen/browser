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

    @State private var hoveredTabID: UUID?
    @State private var suppressedHoverCardTabID: UUID?
    @State private var draggedTabID: UUID?

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
        .task(id: hoveredTabID) { await updateHoverCard() }
    }

    private var horizontalStrip: some View {
        GeometryReader { geometry in
            let regularTabs = browser.unpinnedTabs
            let count = CGFloat(max(1, regularTabs.count))
            let availableWidth = max(minTabWidth, geometry.size.width - BrowserChrome.edgeInset
                                     - minDragAreaWidth)
            let tabWidth = min(maxTabWidth,
                               max(minTabWidth, ((availableWidth - spacing * (count - 1)) / count).rounded(.down)))
            let tabsWidth = tabWidth * count + spacing * (count - 1)

            HStack(spacing: spacing) {
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: spacing) {
                            ForEach(Array(regularTabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index,
                                        nextTab: regularTabs.indices.contains(index + 1) ? regularTabs[index + 1] : nil,
                                        width: tabWidth)
                                    .id(tab.id)
                            }
                        }
                        .frame(height: BrowserChrome.tabRowHeight)
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(tabsWidth <= availableWidth)
                    .onAppear {
                        if tabsWidth > availableWidth, let id = browser.activeTabID { scrollProxy.scrollTo(id) }
                    }
                    .onChange(of: geometry.size.width) { _, _ in
                        // Fitting tabs are already visible. Scrolling them on every window-size update
                        // adds a second scroll/layout transaction to the native resize path.
                        if tabsWidth > availableWidth, let id = browser.activeTabID { scrollProxy.scrollTo(id) }
                    }
                    .onChange(of: browser.activeTabID) { _, activeTabID in
                        guard tabsWidth > availableWidth, let activeTabID else { return }
                        scrollProxy.scrollTo(activeTabID)
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
            let count = regularTabs.count + browser.folders.visibleRows.count
            let tabsHeight = CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * BrowserChrome.smallGap
            let folderSpacing = browser.folders.items.isEmpty ? 0 : BrowserChrome.edgeInset + BrowserChrome.smallGap
            let pinRows = CGFloat((browser.pinnedPages.items.count + 2) / 3)
            let pinHeight = pinRows == 0 ? 0 : pinRows * PinnedPagesGrid.tileHeight + (pinRows - 1) * BrowserChrome.edgeInset + BrowserChrome.edgeInset
            let newTabFits = tabsHeight + folderSpacing + (count > 0 ? BrowserChrome.smallGap : 0) + rowHeight + BrowserChrome.edgeInset + pinHeight <= geometry.size.height

            VStack(spacing: BrowserChrome.edgeInset) {
                if !browser.pinnedPages.items.isEmpty {
                    PinnedPagesGrid(browser: browser)
                        .padding(.horizontal, BrowserChrome.edgeInset)
                }
                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        VStack(spacing: BrowserChrome.smallGap) {
                            if !browser.folders.items.isEmpty {
                                FolderSidebar(browser: browser, rowHeight: rowHeight, onDropAccepted: { draggedTabID = nil })
                            }
                            ForEach(Array(regularTabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index, width: nil).id(tab.id)
                            }
                            if newTabFits { newTabRow(height: rowHeight) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, BrowserChrome.edgeInset)

                        .padding(.bottom, newTabFits ? BrowserChrome.edgeInset : 0)
                    }
                    .scrollIndicators(.never)
                    .onChange(of: browser.activeTabID) { _, activeTabID in
                        guard let activeTabID else { return }
                        withAnimation(.easeOut(duration: 0.2)) { scrollProxy.scrollTo(browser.activeTab?.folderPageID ?? activeTabID) }
                    }
                }
                if !newTabFits {
                    newTabRow(height: rowHeight)
                        .padding(.horizontal, BrowserChrome.edgeInset)
                        .padding(.bottom, BrowserChrome.edgeInset)
                }
            }
            .contextMenu { stripMenu }
        }
        .padding(.top, BrowserChrome.edgeInset)
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
    }

    private func tabItem(for tab: BrowserTab, at index: Int, nextTab: BrowserTab? = nil, width: CGFloat?) -> some View {
        let isActive = browser.activeTabID == tab.id
        let isHovered = hoveredTabID == tab.id
        let showsSeparator = layout == .horizontal && nextTab.map { next in
            !isActive && !isHovered && browser.activeTabID != next.id && hoveredTabID != next.id
        } ?? false

        return TabItem(tab: tab,
                       isActive: isActive,
                       isHovered: isHovered,
                       floating: floating,
                       width: width,
                       height: layout == .vertical ? (compactTabs ? BrowserChrome.sidebarTabHeight : 42) : BrowserChrome.tabHeight,
                       select: {
                           suppressedHoverCardTabID = tab.id
                           hoverCardTabID = nil
                           browser.activeTabID = tab.id
                       },
                       close: {
                           hoverCardTabID = nil
                           browser.closeTab(tab.id)
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
            .onDrag {
                draggedTabID = tab.id
                hoverCardTabID = nil
                suppressedHoverCardTabID = tab.id
                return NSItemProvider(object: tab.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: TabDropDelegate(targetTabID: tab.id,
                                                           browser: browser,
                                                           draggedTabID: $draggedTabID))
            .contextMenu { tabMenu(for: tab, at: index) }
            .folderEditorAnchor(.tab(tab.id))
            .popover(isPresented: Binding(get: { usesNativeHoverPopover && hoverCardTabID == tab.id },
                                           set: { if !$0 { hoverCardTabID = nil } }), arrowEdge: .top) {
                TabHoverCard(tab: tab, isActive: isActive).padding(8)
            }
    }

    /// Shows the card after a short delay, then follows the pointer between tabs without waiting again.
    private func updateHoverCard() async {
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
        guard !Task.isCancelled else { return }
        hoverCardTabID = hoveredTabID
    }

    @ViewBuilder
    private func tabMenu(for tab: BrowserTab, at index: Int) -> some View {
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
        FolderMoveMenu(browser: browser, tab: tab)
        Button("Pin Page") { browser.pin(tab) }
            .disabled(!browser.canPin(tab))
        Divider()
        Button("Close Tab") { browser.closeTab(tab.id) }
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
        TabLayoutMenu()
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
        let shape = RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius, style: .continuous)

        HStack(spacing: 7) {
            if !(isCompact && showsCloseButton) {
                TabIcon(tab: tab)
            }
            if !isCompact {
                title
            }
            if showsCloseButton || (width != nil && !isCompact) {
                closeButton
                    .opacity(showsCloseButton ? 1 : 0)
                    .allowsHitTesting(showsCloseButton)
            }
        }
        .padding(.leading, isCompact ? 0 : BrowserChrome.edgeInset)
        .padding(.trailing, isCompact ? 0 : (width == nil ? BrowserChrome.edgeInset : 4))
        .opacity(BrowserChrome.tabContentOpacity(active: isActive, hovered: isHovered, loaded: !tab.isSuspended))
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(shape.fill(isHovered && !isActive ? Color.primary.opacity(0.055) : Color.clear))
        .modifier(ActiveTabGlass(isActive: isActive, shape: shape))
        .overlay {
            shape.strokeBorder(Color.primary.opacity(isActive ? 0.07 : 0), lineWidth: 1)
        }
        .contentShape(shape)
        .onTapGesture(perform: select)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
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
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeCloseButtonStyle())
        .help("Close Tab (⌘W)")
        .accessibilityLabel("Close \(tab.title)")
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

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        VStack(alignment: .leading, spacing: 0) {
            if !isActive, !tab.isNewTab, let thumbnail = tab.thumbnail {
                thumbnail
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.width, height: 156, alignment: .top)
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

private struct TabDropDelegate: DropDelegate {
    let targetTabID: UUID
    let browser: BrowserModel
    @Binding var draggedTabID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedTabID, draggedTabID != targetTabID,
              let destinationIndex = browser.tabs.firstIndex(where: { $0.id == targetTabID }) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            browser.moveTab(draggedTabID, to: destinationIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTabID = nil
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedTabID != nil
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
