import SwiftUI

extension FolderColor {
    var tint: Color {
        switch self {
        case .primary: .primary
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        }
    }
}

struct FolderIcon: View {
    let item: TabFolderItem
    var body: some View {
        Group {
            if item.emoji.isEmpty { Image(systemName: item.symbol).foregroundStyle(item.color.tint) }
            else { Text(item.emoji) }
        }
    }
}

struct FolderEditor: View {
    let browser: BrowserModel
    let request: FolderEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var parentID: UUID?
    @State private var symbol: String
    @State private var emoji: String
    @State private var color: FolderColor
    @State private var error: String?
    @FocusState private var nameIsFocused: Bool

    init(browser: BrowserModel, request: FolderEditorRequest) {
        self.browser = browser
        self.request = request
        let item = browser.folders.item(request.folderID)
        _title = State(initialValue: item?.title ?? "")
        _parentID = State(initialValue: item?.parentID ?? request.parentID)
        _symbol = State(initialValue: item?.symbol ?? "folder")
        _emoji = State(initialValue: item?.emoji ?? "")
        _color = State(initialValue: item?.color ?? .primary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.folderID == nil ? "New Folder" : "Edit Folder").font(.headline)
            TextField("Folder name", text: $title).textFieldStyle(.roundedBorder).focused($nameIsFocused)
                .accessibilityLabel("Folder name")
            Picker("Location", selection: $parentID) {
                Text("Sidebar").tag(UUID?.none)
                ForEach(browser.folders.folders.filter { browser.folders.canMove(request.folderID ?? request.id, to: $0.id) }) { row in
                    Text(browser.folders.path(for: row.item)).tag(Optional(row.id))
                }
            }
            SavedItemIconPicker(symbol: $symbol, emoji: $emoji, color: $color, emojiAccessibilityLabel: "Folder emoji")
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.folderID == nil ? "Create Folder" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 390)
        .background(ChromePresentationMarker(identifier: "BrowserFolderEditorPopover"))
        .onAppear { nameIsFocused = true }
    }

    private func save() {
        do {
            try browser.saveFolder(request, title: title, parentID: parentID, symbol: symbol, emoji: emoji, color: color)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Geometry stays with the clicked row, while one window-owned presenter avoids
/// competing popovers when a folder is also visible in the toolbar's saved list.
enum FolderEditorAnchor: Hashable {
    case sidebar
    case folder(UUID)
    case tab(UUID)
}

private struct FolderEditorAnchorKey: PreferenceKey {
    static let defaultValue: [FolderEditorAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [FolderEditorAnchor: Anchor<CGRect>], nextValue: () -> [FolderEditorAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func folderEditorAnchor(_ anchor: FolderEditorAnchor) -> some View {
        anchorPreference(key: FolderEditorAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

struct FolderEditorPresentation: ViewModifier {
    @Bindable var browser: BrowserModel
    let controller: ChromeHoverController
    let verticalTabs: Bool

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(FolderEditorAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    let point = attachment(in: geometry, anchors: anchors)
                    Color.clear.frame(width: 1, height: 1)
                        .popover(item: $browser.folderEditorRequest, attachmentAnchor: .point(.center),
                                 arrowEdge: verticalTabs ? .trailing : .bottom) { request in
                            FolderEditor(browser: browser, request: request)
                        }
                        .position(point)
                }
            }
            .onChange(of: browser.folderEditorRequest?.id) { _, id in
                controller.folderEditorIsPresented = id != nil
                if id != nil {
                    if verticalTabs { controller.revealSidebar() }
                    else { controller.revealToolbar() }
                }
            }
            .onDisappear { controller.folderEditorIsPresented = false }
    }

    private func attachment(in geometry: GeometryProxy, anchors: [FolderEditorAnchor: Anchor<CGRect>]) -> CGPoint {
        let request = browser.folderEditorRequest
        let folderID = request?.folderID ?? request?.parentID
        let target: FolderEditorAnchor = folderID.map { .folder($0) } ?? request?.tabID.map { .tab($0) } ?? .sidebar
        if let anchor = anchors[target] ?? (verticalTabs ? anchors[.sidebar] : nil) {
            let rect = geometry[anchor]
            return CGPoint(x: rect.maxX, y: rect.midY)
        }
        // Horizontal tabs live in AppKit's titlebar, outside this preference tree.
        // The native Folders control is the stable anchor for menu-bar commands too.
        if let window = browser.window,
           let view = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "folders" })?.view,
           !view.isHiddenOrHasHiddenAncestor, let content = window.contentView {
            let rect = view.convert(view.bounds, to: content)
            return CGPoint(x: rect.midX, y: max(8, content.bounds.height - rect.minY - geometry.frame(in: .global).minY))
        }
        return CGPoint(x: min(110, geometry.size.width / 2), y: BrowserChrome.edgeInset)
    }
}
