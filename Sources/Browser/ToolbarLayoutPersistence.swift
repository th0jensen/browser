import AppKit
import SwiftUI

/// A stable ordered layout, including temporarily unavailable extensions. Native
/// autosaving can discard those identifiers when the available catalog changes.
@MainActor
final class ToolbarLayoutPersistence {
    private struct Layout: Codable { var identifiers: [String] }
    private weak var toolbar: NSToolbar?
    private var saved: Layout?
    private var needsDefaultLayout = false
    private var binding: Binding<Data>?
    var userIsEditing = false
    private var applying = false
    private var pendingWrite: Data?
    private var lastReadData: Data?
    private var encodedIdentifiers: [String]?
    private var encodedData: Data?

    func update(toolbar: NSToolbar, binding: Binding<Data>?) {
        guard let binding, !applying else { return }
        self.binding = binding
        let data = binding.wrappedValue
        if self.toolbar !== toolbar || (pendingWrite == nil && !userIsEditing && !toolbar.customizationPaletteIsRunning
            && lastReadData != data) {
            self.toolbar = toolbar
            lastReadData = data
            saved = Self.decode(data)
            needsDefaultLayout = !data.isEmpty && saved == nil
        }
        guard toolbar.items.contains(where: { $0.itemIdentifier.rawValue == "address" }) else { return }
        let allowed = Set(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar).map { $0.rawValue } ?? [])
        if let saved, saved.identifiers.contains(where: { !allowed.contains($0) && !$0.hasPrefix("extension.") }) {
            self.saved = nil
            needsDefaultLayout = true
        }
        if needsDefaultLayout {
            guard !toolbar.customizationPaletteIsRunning,
                  let defaults = toolbar.delegate?.toolbarDefaultItemIdentifiers?(toolbar),
                  defaults.contains(.init("address")) else { return }
            applying = true
            toolbar.itemIdentifiers = defaults
            applying = false
            needsDefaultLayout = false
            userIsEditing = false
            capture(toolbar)
            return
        }
        if userIsEditing || toolbar.customizationPaletteIsRunning {
            capture(toolbar)
            userIsEditing = false
            return
        }
        guard let saved else { capture(toolbar); return }
        let available = saved.identifiers.filter { allowed.contains($0) }.map { NSToolbarItem.Identifier($0) }
        guard available.contains(.init("address")) else { return }
        if available != toolbar.itemIdentifiers {
            applying = true
            toolbar.itemIdentifiers = available
            applying = false
        }
        write(saved)
    }

    func capture(_ toolbar: NSToolbar) {
        guard !applying else { return }
        let allowed = Set(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar).map { $0.rawValue } ?? [])
        var ids = toolbar.itemIdentifiers.map(\.rawValue)
        guard Self.isValid(ids) else { return }
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
        guard let binding, binding.wrappedValue == lastReadData || binding.wrappedValue == pendingWrite else { return }
        if encodedIdentifiers != layout.identifiers {
            encodedData = try? JSONEncoder().encode(layout)
            encodedIdentifiers = encodedData == nil ? nil : layout.identifiers
        }
        guard let data = encodedData, binding.wrappedValue != data, pendingWrite != data else { return }
        let sourceData = binding.wrappedValue
        pendingWrite = data
        let expectedToolbar = toolbar
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingWrite == data else { return }
            self.pendingWrite = nil
            guard self.toolbar === expectedToolbar else { return }
            // A different window can publish a newer order before this callback.
            // Keep that external change instead of replacing it with an older edit.
            let currentData = binding.wrappedValue
            guard currentData == sourceData || currentData == data else { return }
            self.lastReadData = data
            if currentData != data { binding.wrappedValue = data }
        }
    }

    /// Give SwiftUI and AppKit the saved order before either creates its item
    /// list. Applying it afterward leaves SwiftUI's customization order stale.
    static func prepareNativeConfiguration(identifier: String, data: Data, defaults: UserDefaults = .standard) {
        let key = "NSToolbar Configuration " + identifier
        guard let layout = decode(data) else {
            if !data.isEmpty { defaults.removeObject(forKey: key) }
            return
        }
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(["TB Item Identifiers": layout.identifiers], forKey: key)
    }

    private static func isValid(_ identifiers: [String]) -> Bool {
        guard identifiers.contains("address") else { return false }
        var seen = Set<String>()
        return identifiers.allSatisfy { id in
            guard !id.isEmpty, !id.hasPrefix("divider") else { return false }
            return id == NSToolbarItem.Identifier.space.rawValue
                || id == NSToolbarItem.Identifier.flexibleSpace.rawValue
                || seen.insert(id).inserted
        }
    }

    private static func decode(_ data: Data) -> Layout? {
        guard let layout = try? JSONDecoder().decode(Layout.self, from: data),
              isValid(layout.identifiers) else { return nil }
        return layout
    }
}
