import AppKit

/// SwiftUI owns the controls. AppKit owns repeatable spacing and the single
/// divider entry in its native palette; no extra fake spacer views are installed.
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
        if Self.canonical(identifier).rawValue == "divider0" { return ToolbarDividerItem(itemIdentifier: .init("divider0")) }
        return source.toolbar?(toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: inserted)
    }

    /// SwiftUI may have made a nonrepeatable divider before this delegate was installed. AppKit checks
    /// existing items before asking the delegate for another copy, so replace those items before restoring
    /// a saved layout with repeated dividers. Remove them all first to avoid collisions between legacy IDs.
    func replaceNonrepeatableDividers(in toolbar: NSToolbar) {
        guard toolbar.delegate === self else { return }
        let indices = toolbar.items.indices.filter {
            Self.canonical(toolbar.items[$0].itemIdentifier).rawValue == "divider0"
                && !toolbar.items[$0].allowsDuplicatesInToolbar
        }
        for index in indices.reversed() { toolbar.removeItem(at: index) }
        for index in indices { toolbar.insertItem(withItemIdentifier: .init("divider0"), at: index) }
    }

    static func canonical(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem.Identifier {
        identifier.rawValue.hasPrefix("divider") ? .init("divider0") : identifier
    }
}

@MainActor
final class ToolbarDividerItem: NSToolbarItem {
    override var allowsDuplicatesInToolbar: Bool { true }
    override init(itemIdentifier: NSToolbarItem.Identifier) {
        super.init(itemIdentifier: itemIdentifier)
        label = "Divider"
        paletteLabel = "Divider"
        let line = ToolbarDividerView(frame: NSRect(x: 0, y: 0, width: 1, height: 20))
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([line.widthAnchor.constraint(equalToConstant: 1), line.heightAnchor.constraint(equalToConstant: 20)])
        view = line
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ToolbarDividerView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 1, height: 20) }
    override func draw(_ dirtyRect: NSRect) { NSColor.separatorColor.setFill(); bounds.fill() }
}
