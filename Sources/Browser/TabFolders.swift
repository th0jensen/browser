import Foundation
import Observation

enum FolderColor: String, Codable, CaseIterable {
    case primary, blue, purple, pink, red, orange, yellow, green
}

struct TabFolderItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case folder, page }
    let id: UUID
    let kind: Kind
    var parentID: UUID?
    var title: String
    var url: URL?
    var symbol = "folder"
    var emoji = ""
    var color = FolderColor.primary
    var isExpanded = true
}

struct FolderEditorRequest: Identifiable {
    let id = UUID()
    var folderID: UUID?
    var parentID: UUID?
    var tabID: UUID?
}

/// Saved sidebar descriptors are independent of window sessions and live web views.
@MainActor @Observable
final class TabFolderStore {
    static let shared = TabFolderStore(directory: BrowserProfile.directory, enabled: !BrowserProfile.isTesting)
    struct Row: Identifiable {
        let item: TabFolderItem
        let depth: Int
        var id: UUID { item.id }
    }

    private(set) var items: [TabFolderItem] = []
    private let file: URL
    private let enabled: Bool

    enum Failure: LocalizedError {
        case invalidLocation, invalidPage
        var errorDescription: String? {
            switch self {
            case .invalidLocation: "A folder cannot be moved inside itself or one of its nested folders."
            case .invalidPage: "Only HTTP and HTTPS webpages can be saved in folders."
            }
        }
    }

    init(directory: URL, enabled: Bool = true) {
        file = directory.appending(path: "TabFolders.json")
        self.enabled = enabled
        guard enabled, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([TabFolderItem].self, from: data) else { return }
        var seen = Set<UUID>()
        items = saved.filter {
            seen.insert($0.id).inserted && ($0.kind == .folder || $0.url.map(PinnedPageStore.valid) == true)
        }
        // Recover orphaned or cyclic nodes at the root instead of hiding their pages.
        for index in items.indices {
            if !canMove(items[index].id, to: items[index].parentID) { items[index].parentID = nil }
        }
    }

    var visibleRows: [Row] { rows(includeCollapsed: false) }
    var folders: [Row] { rows(includeCollapsed: true).filter { $0.item.kind == .folder } }
    var pages: [TabFolderItem] { items.filter { $0.kind == .page } }
    func item(_ id: UUID?) -> TabFolderItem? { items.first { $0.id == id } }

    private func rows(includeCollapsed: Bool) -> [Row] {
        let children = Dictionary(grouping: items, by: \.parentID)
        var result: [Row] = []
        var visited = Set<UUID>()
        func append(_ parent: UUID?, depth: Int) {
            for item in children[parent] ?? [] where visited.insert(item.id).inserted {
                result.append(Row(item: item, depth: depth))
                if item.kind == .folder && (includeCollapsed || item.isExpanded) { append(item.id, depth: depth + 1) }
            }
        }
        append(nil, depth: 0)
        return result
    }

    func path(for folder: TabFolderItem) -> String {
        var names = [folder.title], parent = folder.parentID, seen: Set<UUID> = [folder.id]
        while let node = item(parent), seen.insert(node.id).inserted {
            names.insert(node.title, at: 0)
            parent = node.parentID
        }
        return names.joined(separator: " / ")
    }

    func canMove(_ id: UUID, to parent: UUID?) -> Bool {
        var parent = parent, visited: Set<UUID> = [id]
        while let next = parent {
            guard visited.insert(next).inserted, let node = item(next), node.kind == .folder else { return false }
            parent = node.parentID
        }
        return true
    }

    @discardableResult
    func createFolder(title: String, parentID: UUID? = nil, symbol: String = "folder", emoji: String = "",
                      color: FolderColor = .primary, initialPage: (url: URL, title: String)? = nil) throws -> TabFolderItem {
        let folder = TabFolderItem(id: UUID(), kind: .folder, parentID: parentID, title: clean(title),
                                   symbol: symbol, emoji: String(emoji.prefix(1)), color: color)
        guard canMove(folder.id, to: parentID) else { throw Failure.invalidLocation }
        var next = items + [folder]
        if let initialPage {
            guard PinnedPageStore.valid(initialPage.url) else { throw Failure.invalidPage }
            next.append(TabFolderItem(id: UUID(), kind: .page, parentID: folder.id,
                                      title: initialPage.title, url: initialPage.url))
        }
        expandAncestors(of: parentID, in: &next)
        try commit(next)
        return folder
    }

    func updateFolder(_ id: UUID, title: String, parentID: UUID?, symbol: String, emoji: String, color: FolderColor) throws {
        guard let index = items.firstIndex(where: { $0.id == id && $0.kind == .folder }) else { return }
        guard canMove(id, to: parentID) else { throw Failure.invalidLocation }
        var next = items
        next[index].title = clean(title)
        next[index].parentID = parentID
        next[index].symbol = symbol
        next[index].emoji = String(emoji.prefix(1))
        next[index].color = color
        expandAncestors(of: parentID, in: &next)
        try commit(next)
    }

    @discardableResult
    func savePage(url: URL, title: String, in parentID: UUID?) throws -> TabFolderItem {
        guard PinnedPageStore.valid(url) else { throw Failure.invalidPage }
        let page = TabFolderItem(id: UUID(), kind: .page, parentID: parentID, title: title, url: url)
        guard canMove(page.id, to: parentID) else { throw Failure.invalidLocation }
        var next = items + [page]
        expandAncestors(of: parentID, in: &next)
        try commit(next)
        return page
    }

    func move(_ id: UUID, to parentID: UUID?, before siblingID: UUID? = nil) throws {
        guard var node = item(id), id != siblingID else { return }
        guard canMove(id, to: parentID) else { throw Failure.invalidLocation }
        node.parentID = parentID
        var next = items.filter { $0.id != id }
        let index = siblingID.flatMap { sibling in next.firstIndex { $0.id == sibling && $0.parentID == parentID } } ?? next.count
        next.insert(node, at: index)
        expandAncestors(of: parentID, in: &next)
        try commit(next)
    }

    func toggleExpanded(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id && $0.kind == .folder }) else { return }
        var next = items
        next[index].isExpanded.toggle()
        try commit(next)
    }

    func reveal(_ id: UUID) throws {
        guard let node = item(id) else { return }
        var next = items
        expandAncestors(of: node.parentID, in: &next)
        if next != items { try commit(next) }
    }

    /// Removing a folder keeps its children, including nested folders, at its former location.
    func removeFolder(_ id: UUID) throws {
        guard let folder = item(id), folder.kind == .folder else { return }
        let children = items.filter { $0.parentID == id }.map { child in
            var child = child; child.parentID = folder.parentID; return child
        }
        let index = items.prefix { $0.id != id }.filter { $0.parentID != id }.count
        var next = items.filter { $0.id != id && $0.parentID != id }
        next.insert(contentsOf: children, at: min(index, next.count))
        try commit(next)
    }

    func removePage(_ id: UUID) throws { try commit(items.filter { !($0.id == id && $0.kind == .page) }) }

    private func expandAncestors(of parent: UUID?, in nodes: inout [TabFolderItem]) {
        var parent = parent, seen = Set<UUID>()
        while let id = parent, seen.insert(id).inserted, let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes[index].isExpanded = true
            parent = nodes[index].parentID
        }
    }

    private func clean(_ title: String) -> String {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "New Folder" : text
    }

    private func commit(_ next: [TabFolderItem]) throws {
        if enabled {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        items = next
    }
}
