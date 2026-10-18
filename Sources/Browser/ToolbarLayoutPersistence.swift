import AppKit
import SwiftUI

/// A stable ordered layout, including temporarily unavailable extensions. Native
/// autosaving can discard those identifiers when the available catalog changes.
@MainActor
final class ToolbarLayoutPersistence {
    private struct Layout: Codable { var identifiers: [String] }
    private weak var toolbar: NSToolbar?
    private var saved: Layout?
    private var binding: Binding<Data>?
    var userIsEditing = false
    private var applying = false
    private var pendingWrite: Data?
    private var lastReadData: Data?

    func update(toolbar: NSToolbar, binding: Binding<Data>?) {
        guard let binding, !applying else { return }
        self.binding = binding
        if self.toolbar === toolbar, pendingWrite == nil, !userIsEditing, !toolbar.customizationPaletteIsRunning,
           lastReadData != binding.wrappedValue, let external = try? JSONDecoder().decode(Layout.self, from: binding.wrappedValue) {
            saved = external
            lastReadData = binding.wrappedValue
        }
        if self.toolbar !== toolbar {
            self.toolbar = toolbar
            lastReadData = binding.wrappedValue
            saved = try? JSONDecoder().decode(Layout.self, from: binding.wrappedValue)

        }
        guard toolbar.items.contains(where: { $0.itemIdentifier.rawValue == "address" }) else { return }
        if userIsEditing || toolbar.customizationPaletteIsRunning {
            capture(toolbar)
            userIsEditing = false
            return
        }
        guard let saved else { capture(toolbar); return }
        let allowed = Set(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar).map { $0.rawValue } ?? [])
        let available = saved.identifiers.filter { allowed.contains($0) }.map { NSToolbarItem.Identifier($0) }
        guard available.contains(.init("address")), available != toolbar.itemIdentifiers else { return }
        applying = true
        toolbar.itemIdentifiers = available
        applying = false
        write(saved)
    }

    func capture(_ toolbar: NSToolbar) {
        guard !applying else { return }
        let allowed = Set(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar).map { $0.rawValue } ?? [])
        var ids = Self.normalized(toolbar.itemIdentifiers.map(\.rawValue))
        guard ids.contains("address") else { return }
        // Preserve a disabled/missing extension at its previous relative location.
        for (index, id) in (saved?.identifiers ?? []).enumerated() where !allowed.contains(id) && !ids.contains(id) && id.hasPrefix("extension.") {
            let old = saved!.identifiers
            var insertion = ids.count
            for nextIndex in old.indices where nextIndex > index && ids.contains(old[nextIndex]) {
                let next = old[nextIndex]
                let occurrence = old[...nextIndex].filter { $0 == next }.count
                let matches = ids.indices.filter { ids[$0] == next }
                insertion = matches[min(occurrence - 1, matches.count - 1)]
                break
            }
            ids.insert(id, at: insertion)
        }
        let layout = Layout(identifiers: ids)
        saved = layout
        // Keep a native customization transaction in memory. Writing AppStorage
        // here rebuilds SwiftUI's dynamic extension items in the middle of a drag.
        if !toolbar.customizationPaletteIsRunning { write(layout) }
    }

    func finishCustomization() {
        userIsEditing = false
        if let saved { write(saved) }
    }

    private func write(_ layout: Layout) {
        guard let data = try? JSONEncoder().encode(layout), binding?.wrappedValue != data, pendingWrite != data else { return }
        pendingWrite = data
        let expectedToolbar = toolbar
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingWrite == data else { return }
            self.pendingWrite = nil
            guard self.toolbar === expectedToolbar else { return }
            self.lastReadData = data
            self.binding?.wrappedValue = data
        }
    }

    /// Give SwiftUI and AppKit the saved order before either creates its item
    /// list. Applying it afterward leaves SwiftUI's customization order stale.
    static func prepareNativeConfiguration(identifier: String, data: Data, defaults: UserDefaults = .standard) {
        let key = "NSToolbar Configuration " + identifier
        guard defaults.object(forKey: key) == nil,
              let layout = try? JSONDecoder().decode(Layout.self, from: data),
              layout.identifiers.contains("address") else { return }
        defaults.set(["TB Item Identifiers": normalized(layout.identifiers)], forKey: key)
    }

    static func legacyData(for layout: TabLayout, defaults: UserDefaults = .standard) -> Data {
        guard !BrowserProfile.isTesting else { return Data() }
        for name in ["BrowserToolbar.v5.\(layout.rawValue)", "BrowserToolbar.v4.\(layout.rawValue)",
                     "BrowserToolbar.v3.\(layout.rawValue)", "BrowserToolbar"] {
            if let config = defaults.dictionary(forKey: "NSToolbar Configuration " + name),
               let ids = config["TB Item Identifiers"] as? [String], !ids.isEmpty,
               let data = try? JSONEncoder().encode(Layout(identifiers: normalized(ids))) { return data }
        }
        return Data()
    }

    static func normalized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.compactMap { id in
            let canonical = id.hasPrefix("divider") ? "divider0" : id
            if canonical == "divider0" || canonical == NSToolbarItem.Identifier.space.rawValue
                || canonical == NSToolbarItem.Identifier.flexibleSpace.rawValue { return canonical }
            return seen.insert(canonical).inserted ? canonical : nil
        }
    }
}
