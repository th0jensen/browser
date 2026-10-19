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
    weak var visibilityToolbar: NSToolbar?
    private var command: NativeToolbarCommand
    private var updatingCommand = false
    private(set) var symbol: String?
    private(set) var displayMode = NSToolbar.DisplayMode.iconOnly

    init(command: NativeToolbarCommand, displayMode: NSToolbar.DisplayMode = .iconOnly) {
        self.command = command
        super.init(frame: NSRect(x: 0, y: 0, width: BrowserChrome.toolbarHeight, height: BrowserChrome.toolbarHeight))
        cell = CenteredToolbarButtonCell()
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
        let previousSize = intrinsicContentSize
        let wasUpdating = updatingCommand
        updatingCommand = true
        defer {
            updatingCommand = wasUpdating
            if !wasUpdating && intrinsicContentSize != previousSize { super.invalidateIntrinsicContentSize() }
        }
        self.displayMode = displayMode
        self.command = command
        (cell as? CenteredToolbarButtonCell)?.horizontalOffset = command.identifier == "back" ? 2 : command.identifier == "forward" ? -2 : 0
        let commandID = NSUserInterfaceItemIdentifier(command.identifier)
        if identifier != commandID { identifier = commandID }
        // An invisible icon-only cell title still makes AppKit reallocate the
        // whole toolbar. Keep spoken semantics current without touching layout.
        if displayMode == .labelOnly || displayMode == .iconAndLabel {
            if title != command.title {
                cell?.title = command.title
                needsDisplay = true
            }
        }
        setAccessibilityLabel(command.title)
        if toolTip != command.help { toolTip = command.help }
        if isEnabled != command.isEnabled { isEnabled = command.isEnabled }
        if symbol != command.symbol {
            symbol = command.symbol
            cell?.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)?
                .withSymbolConfiguration(.init(pointSize: BrowserChrome.toolbarSymbolSize, weight: .regular))
            needsDisplay = true
        }
        // Update the owned cell directly: NSButton's title/image setters can
        // change its presentation and synchronously reallocate the native toolbar.
        // Text display modes still publish their final intrinsic size below.
        let position: NSControl.ImagePosition = switch displayMode {
        case .labelOnly: .noImage
        case .iconAndLabel: .imageAbove
        default: .imageOnly
        }
        if imagePosition != position { imagePosition = position }

    }

    override func invalidateIntrinsicContentSize() {
        // NSButton's title/image setters invalidate as well. Reload/Stop has the
        // same icon-only dimensions, so preserve the toolbar's native allocation.
        guard !updatingCommand else { return }
        super.invalidateIntrinsicContentSize()
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
        guard isEnabled, window != nil, visibilityToolbar?.isVisible != false, !isHiddenOrHasHiddenAncestor else { return false }
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

/// AppKit's accessory cell rounds the image canvas and applies baseline offsets.
/// Center the symbol's alignment bounds instead, consistently across glyphs.
@MainActor
final class CenteredToolbarButtonCell: NSButtonCell {
    var horizontalOffset: CGFloat = 0
    override func imageRect(forBounds bounds: NSRect) -> NSRect {
        guard imagePosition == .imageOnly, let image else { return super.imageRect(forBounds: bounds) }
        let alignment = image.alignmentRect
        let centerY = controlView?.isFlipped == true ? image.size.height - alignment.midY : alignment.midY
        return NSRect(x: bounds.midX + horizontalOffset - alignment.midX, y: bounds.midY - centerY,
                      width: image.size.width, height: image.size.height)
    }

    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        // Accessory cells calculate their drawing frame internally, bypassing
        // imageRect(forBounds:). Keep the native tint and disabled rendering.
        guard imagePosition == .imageOnly else {
            super.drawImage(image, withFrame: frame, in: controlView)
            return
        }
        let alignment = image.alignmentRect
        let scaleX = frame.width / image.size.width
        let scaleY = frame.height / image.size.height
        let centerY = controlView.isFlipped ? image.size.height - alignment.midY : alignment.midY
        let centered = NSRect(x: controlView.bounds.midX + horizontalOffset - alignment.midX * scaleX,
                              y: controlView.bounds.midY - centerY * scaleY,
                              width: frame.width, height: frame.height)
        super.drawImage(image, withFrame: centered, in: controlView)
    }
}
