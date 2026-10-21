import AppKit
import SwiftUI

/// A page-area anchor, not a second window. The presentation is owned by this
/// window's native view tree so Regular glass can sample the visible source page.
struct CommandPaletteHost: NSViewRepresentable {
    let browser: BrowserModel
    let bookmarks: BookmarkStore
    let request: Int
    let spaceID: UUID
    let tabID: UUID?

    func makeNSView(context: Context) -> CommandPaletteAnchor {
        CommandPaletteAnchor(browser: browser, bookmarks: bookmarks)
    }

    func updateNSView(_ view: CommandPaletteAnchor, context: Context) {
        view.update(request: request)
    }

    static func dismantleNSView(_ view: CommandPaletteAnchor, coordinator: ()) {
        view.palette.dismiss(restoreFocus: false)
    }
}

final class CommandPaletteAnchor: NSView {
    let palette: CommandPaletteController
    private var requested = 0
    private var applied = 0

    init(browser: BrowserModel, bookmarks: BookmarkStore) {
        palette = CommandPaletteController(browser: browser, bookmarks: bookmarks)
        super.init(frame: .zero)
        palette.anchor = self
        browser.commandPalette = palette
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(request: Int) {
        requested = request
        if palette.isPresented, !palette.contextIsValid { palette.dismiss(restoreFocus: false) }
        DispatchQueue.main.async { [weak self] in self?.applyRequest() }
    }

    private func applyRequest() {
        if requested != applied, palette.present() { applied = requested }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { palette.dismiss(restoreFocus: false) }
        else { DispatchQueue.main.async { [weak self] in self?.applyRequest() } }
    }

    override func layout() {
        super.layout()
        if requested != applied { DispatchQueue.main.async { [weak self] in self?.applyRequest() } }
        palette.layoutPresentation()
    }
}

/// Local, synchronous results and a native field editor. Opening is side-effect
/// free: a new tab is created only when a navigation/search action is accepted.
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    weak var anchor: NSView?
    private weak var browser: BrowserModel?
    private let bookmarks: BookmarkStore
    let field = AddressField()
    let table = CommandPaletteTable()
    private let scroll = NSScrollView()
    private let content = CommandPaletteContent()
    private let hint = NSTextField(labelWithString: "Search tabs, Spaces, saved pages, or commands")
    private let separator = NSBox()
    private let symbol = NSImageView()
    private(set) var glass: NSGlassEffectView?
    private var overlay: CommandPaletteOverlay?
    private(set) var results: [AddressResult] = []
    private(set) var typedText = ""
    private(set) var completionStart: Int?
    private weak var previousResponder: NSResponder?
    private weak var sourceTab: BrowserTab?
    private var sourceSpaceID: UUID?
    private var sourceRevision = 0
    private var sourcePeekID: UUID?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pendingMouseUp: NSEvent.EventType?
    private var focusTask: Task<Void, Never>?

    var isPresented: Bool { overlay != nil }
    var contextIsValid: Bool {
        guard let browser, !browser.isClosed else { return false }
        return browser.activeTab === sourceTab && browser.activeSpaceID == sourceSpaceID
            && (sourceTab?.navigationRevision ?? 0) == sourceRevision && browser.peek?.id == sourcePeekID
    }

    init(browser: BrowserModel, bookmarks: BookmarkStore) {
        self.browser = browser
        self.bookmarks = bookmarks
        super.init()
        field.requiresVisibleToolbar = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22)
        field.textColor = .labelColor
        field.placeholderString = "Search or enter address"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.identifier = .init("BrowserCommandPaletteInput")
        field.setAccessibilityLabel("Command Bar, search or enter address")
        field.target = self
        field.action = #selector(submit)
        symbol.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        symbol.contentTintColor = .secondaryLabelColor
        symbol.setAccessibilityElement(false)
        separator.boxType = .separator
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        let column = NSTableColumn(identifier: .init("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClickedRow)
        table.performCommand = { [weak self] in self?.perform($0) ?? false }
        field.nextKeyView = table
        table.nextKeyView = field
        table.inputField = field
        table.setAccessibilityLabel("Command Bar results")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        for view in [symbol, field, separator, scroll, hint] { content.addSubview(view) }
    }

    isolated deinit {
        focusTask?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    @discardableResult
    func present() -> Bool {
        guard let browser, !browser.isClosed, let anchor, let window = anchor.window,
              let root = window.contentView, anchor.bounds.width > 0, anchor.bounds.height > 0,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        focusTask?.cancel()
        if isPresented {
            window.makeFirstResponder(field)
            field.selectText(nil)
            return true
        }
        removeEventMonitor()
        if let peek = browser.peek { previousResponder = peek.tab.webView }
        else { previousResponder = ((window.firstResponder as? NSTextView)?.delegate as? NSResponder) ?? window.firstResponder }
        sourceTab = browser.activeTab
        sourceSpaceID = browser.activeSpaceID
        sourceRevision = sourceTab?.navigationRevision ?? 0
        sourcePeekID = browser.peek?.id
        typedText = ""
        completionStart = nil
        results = []
        field.browserWindow = window
        field.updatePresentation(text: "", url: nil, title: "")
        table.reloadData()
        table.deselectAll(nil)
        let overlay = CommandPaletteOverlay(frame: root.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onLayout = { [weak self] in self?.layoutPresentation() }
        overlay.onDismiss = { [weak self] in self?.dismiss() }
        overlay.setAccessibilityRole(.group)
        overlay.setAccessibilitySubrole(.dialog)
        overlay.setAccessibilityLabel("Command Bar")
        overlay.setAccessibilityModal(true)
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 14
        glass.contentView = content
        glass.identifier = .init("BrowserCommandPaletteGlass")
        overlay.addSubview(glass)
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        self.glass = glass
        layoutPresentation()
        installEvents(in: window)
        window.makeFirstResponder(field)
        field.selectText(nil)
        NSAccessibility.post(element: field, notification: .focusedUIElementChanged)
        return true
    }

    func dismiss(restoreFocus: Bool = true) {
        focusTask?.cancel()
        guard let overlay else { return }
        let window = overlay.window
        if field.currentEditor() != nil || window?.firstResponder === table { window?.makeFirstResponder(nil) }
        overlay.removeFromSuperview()
        self.overlay = nil
        glass = nil
        results = []
        typedText = ""
        completionStart = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if pendingMouseUp == nil { removeEventMonitor() }
        guard restoreFocus, contextIsValid, let window else { return }
        if let view = previousResponder as? NSView, view.window === window {
            window.makeFirstResponder(view)
        } else if let browser { focusTask = AddressResults.focusDestination(in: browser) }
        previousResponder = nil
    }

    /// The reference centers the palette horizontally, slightly above the page's
    /// midpoint. Its input dominates; results scroll rather than growing offscreen.
    func layoutPresentation() {
        guard let anchor, let overlay, let glass, let root = overlay.superview else { return }
        if overlay.frame != root.bounds { overlay.frame = root.bounds }
        let area = overlay.convert(anchor.bounds, from: anchor).intersection(overlay.bounds)
        guard area.width > 0, area.height > 0 else { return }
        let width = min(720, min(max(280, area.width * 0.78), max(0, area.width - 32)))
        let resultHeight = results.isEmpty ? 36 : min(CGFloat(results.count * 43), min(336, max(42, area.height - 160)))
        let height = 80 + resultHeight
        let centerY = area.midY + min(60, area.height * 0.08)
        let y = max(area.minY + 16, min(centerY - height / 2, area.maxY - height - 16))
        glass.frame = NSRect(x: area.midX - width / 2, y: y, width: width, height: height)
        content.frame = NSRect(origin: .zero, size: glass.bounds.size)
        symbol.frame = NSRect(x: 18, y: 24, width: 18, height: 18)
        field.frame = NSRect(x: 48, y: 14, width: max(0, width - 66), height: 36)
        separator.frame = NSRect(x: 12, y: 64, width: max(0, width - 24), height: 1)
        scroll.frame = NSRect(x: 8, y: 72, width: max(0, width - 16), height: resultHeight)
        table.frame.size = NSSize(width: scroll.contentSize.width, height: CGFloat(results.count * 43))
        table.tableColumns.first?.width = scroll.contentSize.width
        hint.frame = NSRect(x: 18, y: 80, width: max(0, width - 36), height: 20)
        hint.isHidden = !results.isEmpty
        scroll.isHidden = results.isEmpty
    }

    func controlTextDidChange(_ notification: Notification) {
        guard isPresented, notification.object as? NSTextField === field else { return }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        if editor.hasMarkedText() {
            results = []
            table.reloadData()
            layoutPresentation()
            return
        }
        let text = editor.string
        let appending = text.count > typedText.count && text.hasPrefix(typedText)
        typedText = text
        refreshResults()
        if appending, let completion = AddressSuggestions.inlineCompletion(of: text, with: results.first?.completionSuggestion) {
            completionStart = text.utf16.count
            field.updatePresentation(text: completion, url: nil, title: "", completionStart: completionStart)
        } else {
            completionStart = nil
            field.updatePresentation(text: text, url: nil, title: "")
        }
    }

    private func refreshResults() {
        guard let browser else { return }
        results = AddressResults.results(for: typedText, browser: browser, bookmarks: bookmarks.bookmarks, includesTypedAddress: true)
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        layoutPresentation()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return field.window?.makeFirstResponder(table) ?? false
        case #selector(NSResponder.moveDown(_:)): return perform(.moveDown)
        case #selector(NSResponder.moveUp(_:)): return perform(.moveUp)
        case #selector(NSResponder.insertNewline(_:)): return perform(.submit)
        case #selector(NSResponder.cancelOperation(_:)): return perform(.cancel)
        default: return false
        }
    }

    @discardableResult
    func perform(_ command: SuggestionAddressField.Command) -> Bool {
        guard isPresented else { return false }
        switch command {
        case .cancel: dismiss()
        case .submit: acceptSelectedResult()
        case .moveDown, .moveUp:
            completionStart = nil
            guard !results.isEmpty else { return true }
            let offset = command == .moveDown ? 1 : -1
            let row = min(max(0, table.selectedRow + offset), results.count - 1)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        return true
    }

    @objc private func submit() { acceptSelectedResult() }
    @objc private func chooseClickedRow() {
        guard table.clickedRow >= 0 else { return }
        acceptSelectedResult(acceptCompletion: false)
    }

    func acceptSelectedResult(acceptCompletion: Bool = true) {
        guard isPresented, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        guard contextIsValid, let browser else { dismiss(restoreFocus: false); return }
        guard results.indices.contains(table.selectedRow) else { return }
        let result = results[table.selectedRow]
        // A completion's visible host may be shorter than its history resource.
        // Return accepts that exact completion; explicit row clicks accept the row.
        var accepted = result
        if acceptCompletion, completionStart != nil, table.selectedRow == 0,
           let text = field.currentEditor()?.string,
           let url = AddressSuggestions.completedURL(for: text, with: result.completionSuggestion) {
            accepted = AddressResult(owner: result.owner, action: .navigate(url), title: result.title,
                                     detail: result.detail, destinationSpace: result.destinationSpace)
        }
        guard AddressResults.execute(accepted, in: browser, inNewTab: true) else {
            completionStart = nil
            refreshResults()
            return
        }
        dismiss(restoreFocus: false)
        focusTask = AddressResults.focusDestination(in: browser)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: .init("CommandResult"), owner: nil) as? CommandPaletteResultCell)
            ?? CommandPaletteResultCell()
        cell.update(results[row])
        return cell
    }

    private func installEvents(in window: NSWindow) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                                                  .otherMouseDown, .otherMouseUp, .scrollWheel, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.handle(event) == nil
            }
            return consumed ? nil : event
        }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSWindow.willCloseNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss(restoreFocus: false) }
            })
        }
    }

    /// Consume both edges of an outside click. Removing the overlay on mouse-down
    /// must not deliver the matching mouse-up to the source webpage or toolbar.
    func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == pendingMouseUp {
            pendingMouseUp = nil
            if !isPresented { removeEventMonitor() }
            return nil
        }
        guard isPresented, let window = overlay?.window else { return event }
        let isToolbar = window.toolbar?.items.contains { $0.view?.window === event.window } == true
        guard event.window === window || isToolbar else { return event }
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.charactersIgnoringModifiers == "w", modifiers == .command { dismiss(); return nil }
            return event // Native marked-text and result-key handling stays with the field editor.
        }
        guard let glass, let sourceWindow = event.window else { return event }
        let point = window.convertPoint(fromScreen: sourceWindow.convertPoint(toScreen: event.locationInWindow))
        guard !glass.bounds.contains(glass.convert(point, from: nil)) else { return event }
        switch event.type {
        case .leftMouseDown: pendingMouseUp = .leftMouseUp
        case .rightMouseDown: pendingMouseUp = .rightMouseUp
        case .otherMouseDown: pendingMouseUp = .otherMouseUp
        case .scrollWheel: return nil
        default: return event
        }
        dismiss()
        return nil
    }

    private func removeEventMonitor() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        pendingMouseUp = nil
    }
}

private final class CommandPaletteContent: NSView {
    override var isFlipped: Bool { true }
}

private final class CommandPaletteOverlay: NSView {
    var onDismiss: (() -> Void)?
    var onLayout: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); onLayout?() }
    private func dismissOutside(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !subviews.contains(where: { $0.frame.contains(point) }) { onDismiss?() }
    }
    override func mouseDown(with event: NSEvent) { dismissOutside(event) }
    override func rightMouseDown(with event: NSEvent) { dismissOutside(event) }
    override func otherMouseDown(with event: NSEvent) { dismissOutside(event) }
    override func scrollWheel(with event: NSEvent) {}
}

final class CommandPaletteTable: NSTableView {
    var performCommand: ((SuggestionAddressField.Command) -> Bool)?
    weak var inputField: NSTextField?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { window?.makeFirstResponder(inputField); return }
        let command: SuggestionAddressField.Command? = switch event.keyCode {
        case 125: .moveDown
        case 126: .moveUp
        case 36, 76: .submit
        case 53: .cancel
        default: nil
        }
        if let command, performCommand?(command) == true { return }
        super.keyDown(with: event)
    }
}

private final class CommandPaletteResultCell: NSTableCellView {
    private let symbol = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let action = NSTextField(labelWithString: "")
    private let space = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }

    init() {
        super.init(frame: .zero)
        identifier = .init("CommandResult")
        for label in [title, detail, action, space] {
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: label === title ? 13 : 11)
            addSubview(label)
        }
        action.alignment = .right
        space.alignment = .right
        addSubview(symbol)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ result: AddressResult) {
        title.stringValue = result.title
        detail.stringValue = result.detail
        action.stringValue = result.actionLabel
        space.stringValue = result.destinationSpace.map { "In \($0)" } ?? ""
        symbol.image = NSImage(systemSymbolName: result.symbol, accessibilityDescription: nil)
        setAccessibilityLabel([result.title, result.detail, result.actionLabel, result.destinationSpace].compactMap { $0 }.joined(separator: ", "))
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        for label in [detail, action, space] { label.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor }
        symbol.contentTintColor = title.textColor
    }

    override func layout() {
        super.layout()
        let contextWidth = min(170, bounds.width * 0.35)
        let textWidth = max(0, bounds.width - contextWidth - 56)
        symbol.frame = NSRect(x: 10, y: 13, width: 16, height: 16)
        title.frame = NSRect(x: 36, y: 5, width: textWidth, height: 17)
        detail.frame = NSRect(x: 36, y: 23, width: textWidth, height: 15)
        action.frame = NSRect(x: bounds.width - contextWidth - 10, y: 5, width: contextWidth, height: 17)
        space.frame = NSRect(x: action.frame.minX, y: 23, width: contextWidth, height: 15)
    }
}
