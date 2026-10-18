import AppKit

/// The canonical SwiftUI toolbar item continues to own customization, grouping and palette metadata.
/// Fixed commands replace only its documented custom view to avoid hosted layout on every resize.
@MainActor
struct NativeToolbarCommand {
    let identifier: String
    let title: String
    let symbol: String
    let help: String?
    let isEnabled: Bool
    let action: @MainActor () -> Void
    let menu: (@MainActor () -> NSMenu)?

    init(identifier: String, title: String, symbol: String, help: String? = nil,
         isEnabled: Bool = true, action: @escaping @MainActor () -> Void,
         menu: (@MainActor () -> NSMenu)? = nil) {
        self.identifier = identifier
        self.title = title
        self.symbol = symbol
        self.help = help
        self.isEnabled = isEnabled
        self.action = action
        self.menu = menu
    }
}

@MainActor
final class NativeToolbarCommandButton: NSButton {
    private var command: NativeToolbarCommand
    private(set) var symbol: String?
    private(set) var displayMode = NSToolbar.DisplayMode.iconOnly

    init(command: NativeToolbarCommand, displayMode: NSToolbar.DisplayMode = .iconOnly) {
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: BrowserChrome.toolbarHeight, height: BrowserChrome.toolbarHeight))
        setButtonType(.momentaryPushIn)
        bezelStyle = .accessoryBarAction
        isBordered = true
        controlSize = .regular
        imagePosition = .imageOnly
        target = self
        action = #selector(activate)
        update(command, displayMode: displayMode)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ command: NativeToolbarCommand, displayMode: NSToolbar.DisplayMode = .iconOnly) {
        let sizeChanged = title != command.title || self.displayMode != displayMode
        self.displayMode = displayMode
        self.command = command
        let commandID = NSUserInterfaceItemIdentifier(command.identifier)
        if identifier != commandID { identifier = commandID }
        if title != command.title {
            title = command.title
            setAccessibilityLabel(command.title)
        }
        if toolTip != command.help { toolTip = command.help }
        if isEnabled != command.isEnabled { isEnabled = command.isEnabled }
        if symbol != command.symbol {
            symbol = command.symbol
            image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)?
                .withSymbolConfiguration(.init(pointSize: BrowserChrome.toolbarSymbolSize, weight: .regular))
        }
        // AppKit's title/image setters can choose a text position while constructing
        // a toolbar item. Apply the requested presentation after both have changed.
        let position: NSControl.ImagePosition = switch displayMode {
        case .labelOnly: .noImage
        case .iconAndLabel: .imageAbove
        default: .imageOnly
        }
        if imagePosition != position { imagePosition = position }
        if sizeChanged { invalidateIntrinsicContentSize() }
    }

    @objc private func activate() { guard isEnabled else { return }; command.action() }
    override func menu(for event: NSEvent) -> NSMenu? { command.menu?() ?? super.menu(for: event) }
    func commandMenu() -> NSMenu? { command.menu?() }
    override var intrinsicContentSize: NSSize {
        guard displayMode == .labelOnly || displayMode == .iconAndLabel else {
            return NSSize(width: BrowserChrome.toolbarHeight, height: BrowserChrome.toolbarHeight)
        }
        let labelWidth = ceil((title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width) + 8
        return NSSize(width: max(BrowserChrome.toolbarHeight, labelWidth),
                      height: displayMode == .iconAndLabel ? 42 : BrowserChrome.toolbarHeight)
    }
    override var fittingSize: NSSize { intrinsicContentSize }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return false }
        performClick(nil)
        return true
    }
}

/// Retains the canonical host without changing SwiftUI's toolbar delegate or view hierarchy.
@MainActor
final class NativeToolbarCommandAdapter {
    let item: NSToolbarItem
    let button: NativeToolbarCommandButton
    private(set) var originalView: NSView?

    init(item: NSToolbarItem, command: NativeToolbarCommand, displayMode: NSToolbar.DisplayMode = .iconOnly) {
        self.item = item
        originalView = item.view
        button = NativeToolbarCommandButton(command: command, displayMode: displayMode)
        item.view = button
    }

    func update(_ command: NativeToolbarCommand, displayMode: NSToolbar.DisplayMode = .iconOnly) {
        button.update(command, displayMode: displayMode)
        // SwiftUI may recreate its host following customization or a structural update.
        // Keep that newest canonical host for restoration, then reapply our owned view.
        if item.view !== button {
            originalView = item.view
            item.view = button
        }
    }

    func restore() {
        if item.view === button { item.view = originalView }
    }
}
