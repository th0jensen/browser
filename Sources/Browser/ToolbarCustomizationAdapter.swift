import AppKit

/// SwiftUI owns the controls; AppKit's standard spaces separate native glass groups
/// and remain repeatable in the customization palette.
@MainActor
final class ToolbarCustomizationAdapter: NSObject, NSToolbarDelegate {
    // Immutable Objective-C forwarding target; introspection itself is nonisolated.
    nonisolated(unsafe) let source: any NSToolbarDelegate
    init(source: any NSToolbarDelegate) { self.source = source }

    override func responds(to selector: Selector!) -> Bool {
        if super.responds(to: selector) { return true }
        return source.responds(to: selector)
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { source }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var seen = Set<NSToolbarItem.Identifier>()
        return ((source.toolbarAllowedItemIdentifiers?(toolbar) ?? []) + [.space, .flexibleSpace]).map(Self.canonical).filter { seen.insert($0).inserted }
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        (source.toolbarDefaultItemIdentifiers?(toolbar) ?? []).map(Self.canonical)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        source.toolbarSelectableItemIdentifiers?(toolbar) ?? []
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar inserted: Bool) -> NSToolbarItem? {
        return source.toolbar?(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: inserted)
    }

    static func canonical(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem.Identifier {
        identifier.rawValue.hasPrefix("divider") ? .space : identifier
    }
}

@MainActor
final class ToolbarSeparatorView: NSBox {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 20))
        boxType = .separator
        identifier = NSUserInterfaceItemIdentifier("BrowserToolbarSeparator")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
