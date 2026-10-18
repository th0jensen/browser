import AppKit
import SwiftUI

struct FolderMoveMenu: View {
    let browser: BrowserModel
    var item: TabFolderItem?
    var tab: BrowserTab?

    var body: some View {
        Menu("Move to Folder") {
            Button(item == nil ? "Pin tab" : "Pinned Tabs") { move(to: nil) }
                .disabled(item.map { $0.parentID == nil } ?? false)
            ForEach(browser.folders.folders.filter { row in item.map { browser.folders.canMove($0.id, to: row.id) } ?? true }) { row in
                Button(browser.folders.path(for: row.item)) { move(to: row.id) }
                    .disabled((item?.parentID ?? tab.flatMap { browser.folders.item($0.folderPageID)?.parentID }) == row.id)
            }
            if let tab {
                Divider()
                Button("New Folder…") { browser.requestNewFolder(containing: tab) }
            }
        }
        .disabled(tab.map { $0.url.map(PinnedPageStore.valid) != true } ?? false)
        .disabled(item.map { item in
            item.parentID == nil && !browser.folders.folders.contains {
                $0.id != item.parentID && browser.folders.canMove(item.id, to: $0.id)
            }
        } ?? false)
    }

    private func move(to parent: UUID?) {
        if let item { browser.changeFolders { try browser.folders.move(item.id, to: parent) } }
        else if let tab { browser.moveToFolder(tab, parentID: parent) }
    }
}

struct FolderSidebar: View {
    let browser: BrowserModel
    let rowHeight: CGFloat
    var onDropAccepted: @MainActor @Sendable () -> Void = {}
    var rootDropTargetInSpacing = false
    @State private var rootIsTargeted = false

    var body: some View {
        VStack(spacing: BrowserChrome.smallGap) {
            ForEach(browser.sidebarFolderRows) { row in
                FolderSidebarRow(browser: browser, row: row, rowHeight: rowHeight, onDropAccepted: onDropAccepted)
                    .padding(.leading, CGFloat(min(row.depth, 8)) * 14)
                    .id(row.id)
            }
            if !browser.folders.items.isEmpty && !rootDropTargetInSpacing {
                rootDropTarget
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SplitDropBadge(controller: browser.tabDrag, enabled: !rootDropTargetInSpacing))
        .overlay(alignment: .bottom) {
            if !browser.folders.items.isEmpty && rootDropTargetInSpacing {
                // Reuse the gap before the divider without adding uneven space above it.
                rootDropTarget.offset(y: BrowserChrome.smallGap)
            }
        }
    }

    private var rootDropTarget: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill((rootIsTargeted || browser.tabDrag.isOver("browser-pinned-end")) ? Color.accentColor.opacity(0.5) : .clear)
            .frame(height: BrowserChrome.smallGap)
            .contentShape(Rectangle())
            .onDrop(of: [.text], delegate: FolderDropDelegate(browser: browser, target: nil,
                                                              isTargeted: $rootIsTargeted, didAccept: onDropAccepted))
            .modifier(TabReorderTarget(controller: browser.tabDrag, payload: "browser-pinned-end"))
            .help("Drop here to move to the sidebar")
    }
}

private struct FolderSidebarRow: View {
    let browser: BrowserModel
    let row: TabFolderStore.Row
    let rowHeight: CGFloat
    let onDropAccepted: @MainActor @Sendable () -> Void
    @State private var isHovered = false
    @State private var isTargeted = false

    private var item: TabFolderItem { row.item }
    private var tab: BrowserTab? { browser.tabs.first { $0.folderPageID == item.id } }
    private var active: Bool { tab.map { browser.splitIsActive($0) } ?? false }
    private var expanded: Bool { item.isExpanded && browser.tabDrag.payload != SidebarDragItem.pinned(item.id).payload }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: browser.tabDrag.payload == "browser-folder:\(item.id.uuidString)" ? rowHeight / 2 : BrowserChrome.contentCornerRadius)
    }

    var body: some View {
        HStack(spacing: 7) {
            if item.kind == .folder {
                FolderIcon(item: item).frame(width: 14, height: 14)
                Text(item.title).font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary).opacity(isHovered || !expanded ? 1 : 0.4)
                    .frame(width: 12)
            } else {
                if let tab, let split = browser.split(containing: tab.id) {
                    SplitTabLabel(browser: browser, split: split, showsCloseButtons: isHovered || active)
                } else {
                    if let url = item.url { SiteIcon(url: url, size: 14) }
                    SavedTabTitle(browser: browser, page: item, isActive: active)
                }
                if isHovered || active, let tab, browser.split(containing: tab.id) == nil {
                    TabDismissButton(tab: tab) { browser.closeTab(tab.id) }
                }
            }
        }
        .padding(.horizontal, BrowserChrome.edgeInset)
        .opacity(browser.tabDrag.payload == "browser-folder:\(item.id.uuidString)" || item.kind == .folder || browser.renamingSavedPageID == item.id ? 1 : BrowserChrome.tabContentOpacity(active: active, hovered: isHovered,
                                                                          loaded: tab.map { !$0.isSuspended } ?? false))
        .frame(height: rowHeight).frame(maxWidth: .infinity)
        .background(shape.fill((isTargeted || browser.tabDrag.isOver("browser-folder:\(item.id.uuidString)")) ? Color.accentColor.opacity(0.18) : isHovered ? Color.primary.opacity(0.055) : .clear))
        .modifier(ActiveTabGlass(isActive: active || browser.tabDrag.payload == "browser-folder:\(item.id.uuidString)", shape: shape))
        .contentShape(shape)
        .onTapGesture {
            if item.kind == .folder { browser.changeFolders { try browser.folders.toggleExpanded(item.id) } }
            else if let tab { browser.selectRepresentedTab(tab) }
            else { browser.openFolderPage(item) }
        }
        .onHover { isHovered = $0 }
        .onChange(of: browser.tabDrag.isOver(SidebarDragItem.pinned(item.id).payload)) { _, isOver in
            if isOver { browser.didEnterFolderRowDropTarget(item.id) }
        }
        .modifier(TabDragSource(controller: browser.tabDrag, payload: "browser-folder:\(item.id.uuidString)",
                                enabled: browser.renamingSavedPageID == nil, began: {
            browser.chromeHover?.sidebarIsReordering = true
        }, ended: { target in
            browser.finishDraggedTab("browser-folder:\(item.id.uuidString)", over: target)
            browser.chromeHover?.sidebarIsReordering = false
        }, crossed: { target, direction in
            browser.crossDraggedTab("browser-folder:\(item.id.uuidString)", past: target, direction: direction)
        }))
        .modifier(TabSplitTarget(browser: browser, payload: "browser-folder:\(item.id.uuidString)", enabled: item.kind == .page))
        .onDrop(of: [.text], delegate: FolderDropDelegate(browser: browser, target: item,
                                                          isTargeted: $isTargeted, didAccept: onDropAccepted))
        .contextMenu { contextMenu }
        .modifier(SavedPageRenameIfNeeded(browser: browser, page: item))
        .folderEditorAnchor(.folder(item.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.kind == .folder ? "\(item.title), \(expanded ? "expanded" : "collapsed") folder" : (tab?.title ?? item.title))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            if item.kind == .folder { browser.changeFolders { try browser.folders.toggleExpanded(item.id) } }
            else { browser.openFolderPage(item) }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        if item.kind == .folder {
            Button(item.isExpanded ? "Collapse Folder" : "Expand Folder") {
                browser.changeFolders { try browser.folders.toggleExpanded(item.id) }
            }
            Divider()
            Button("New Nested Folder…") { browser.requestNewFolder(parentID: item.id) }
            Button("Add Current Page") {
                if let tab = browser.activeTab { browser.moveToFolder(tab, parentID: item.id) }
            }.disabled(browser.activeTab?.url.map(PinnedPageStore.valid) != true)
            Divider()
            Button("Edit Name and Icon…") { browser.folderEditorRequest = FolderEditorRequest(folderID: item.id) }
            FolderMoveMenu(browser: browser, item: item)
            Divider()
            Button("Remove Folder, Keep Contents", role: .destructive) {
                browser.changeFolders { try browser.folders.removeFolder(item.id) }
            }
        } else {
            if let tab { SplitTabMenu(browser: browser, tab: tab) }
            Button("Open") { browser.openFolderPage(item) }
            Button("Open Copy in New Tab") { if let url = item.url { browser.open(url, inNewTab: true) } }
            if let tab { Button("Reload") { browser.reloadTab(tab.id) } }
            Button("Copy Link") {
                if let url = item.url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
            }
            Divider()
            Button("Rename…") { browser.renamingSavedPageID = item.id }
            if item.nameSource == .manual || item.nameSource == .automatic {
                Button("Use Original Title") { browser.changeFolders { try browser.folders.resetPageName(item.id) } }
            }
            Divider()
            FolderMoveMenu(browser: browser, item: item)
            Button("Add to Essential Tabs") { browser.pinSavedPageToEssentials(item) }
                .disabled(browser.pinnedPages.items.count >= PinnedPageStore.limit && !browser.pinnedPages.items.contains { $0.url == item.url })
            Button("Unpin tab") { browser.moveFolderPageToTemporaryTabs(item) }
            if let tab {
                Divider()
                Button("Close Page") { browser.closeTab(tab.id) }
            }
        }
    }
}

/// External text drops are separate from live in-sidebar reordering.
/// Decode the immutable payload before returning to the main actor.
@MainActor
private struct FolderDropDelegate: DropDelegate {
    let browser: BrowserModel
    let target: TabFolderItem?
    @Binding var isTargeted: Bool
    let didAccept: @MainActor @Sendable () -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }
    func dropEntered(info: DropInfo) { isTargeted = true }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let intoFolder = target?.kind == .folder && info.location.y > 6
        let parent = intoFolder ? target?.id : target?.parentID
        let before = intoFolder ? nil : target?.id
        let browser = browser, didAccept = didAccept
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let payload = value as? String else { return }
            Task { @MainActor in
                if browser.acceptFolderDrop(payload, parentID: parent, before: before) { didAccept() }
            }
        }
        return true
    }
}

struct FolderToolbarButton: View {
    let browser: BrowserModel
    @State private var isPresented = false
    @Environment(\.chromeHoverController) private var chromeHover

    var body: some View {
        Button { isPresented.toggle() } label: { Label("Folders", systemImage: "folder") }
            .labelStyle(ChromeToolbarLabelStyle()).font(.system(size: BrowserChrome.toolbarSymbolSize))
            .chromeToolbarButtonStyle().controlSize(.regular)
            .help("Saved folders").accessibilityLabel("Folders")
            .popover(isPresented: $isPresented) {
                VStack(alignment: .leading, spacing: BrowserChrome.edgeInset) {
                    Text("Folders").font(.headline)
                    if browser.folders.items.isEmpty { Text("Save pages here to keep them organized.").font(.caption).foregroundStyle(.secondary) }
                    ScrollView { FolderSidebar(browser: browser, rowHeight: BrowserChrome.sidebarTabHeight) }
                        .frame(maxHeight: 360)
                    Button("New Folder…") { isPresented = false; browser.requestNewFolder() }
                }.padding(12).frame(width: 280)
            }
            .chromePresentation(isPresented: isPresented, controller: chromeHover)
    }
}

struct SavedPageRenameIfNeeded: ViewModifier {
    let browser: BrowserModel
    let page: TabFolderItem
    @ViewBuilder func body(content: Content) -> some View {
        if page.kind == .page { content.modifier(SavedTabRename(browser: browser, page: page)) }
        else { content }
    }
}
