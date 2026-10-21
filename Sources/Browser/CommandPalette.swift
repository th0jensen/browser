import AppKit
import SwiftUI

enum CommandPaletteMode: Equatable, Sendable {
    case newDestination
    case editCurrentDestination

    var menuTitle: String {
        switch self {
        case .newDestination: "New Tab"
        case .editCurrentDestination: "Toggle Command Bar"
        }
    }
}

/// A page-area native container, not a second window. SwiftUI owns its placement;
/// this representable owns every overlay child so glass can sample the source page.
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
        view.update()
    }

    static func dismantleNSView(_ view: CommandPaletteAnchor, coordinator: ()) {
        view.palette.dismiss(restoreFocus: false)
    }
}

final class CommandPaletteAnchor: NSView {
    let palette: CommandPaletteController
    private weak var browser: BrowserModel?
    private(set) var applied = 0

    init(browser: BrowserModel, bookmarks: BookmarkStore) {
        self.browser = browser
        palette = CommandPaletteController(browser: browser, bookmarks: bookmarks)
        super.init(frame: .zero)
        palette.anchor = self
        browser.commandPalette = palette
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        palette.isPresented ? super.hitTest(point) : nil
    }

    func update() {
        DispatchQueue.main.async { [weak self] in self?.applyRequest() }
    }

    func applyRequest() {
        // Read the live window intent. An earlier queued SwiftUI update must not
        // reopen a bar that a second Cmd-G has already cancelled.
        guard let browser else { return }
        if palette.isPresented, !palette.contextIsValid, browser.commandPaletteRequest == applied {
            palette.dismiss(restoreFocus: false)
        }
        guard browser.commandPaletteRequest != applied else { return }
        let request = browser.commandPaletteRequest
        if !browser.commandPaletteWantsPresentation {
            // A completed acceptance may already own a destination focus task.
            // Consuming its closed request must not cancel that handoff.
            if palette.isPresented { palette.dismiss() }
            applied = request
        } else if palette.present(mode: browser.commandPaletteMode) { applied = request }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { palette.dismiss(restoreFocus: false) }
        else { DispatchQueue.main.async { [weak self] in self?.applyRequest() } }
    }

    override func layout() {
        super.layout()
        if browser?.commandPaletteRequest != applied { DispatchQueue.main.async { [weak self] in self?.applyRequest() } }
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
    private let scroll = CommandPaletteResultsScrollView()
    private let content = CommandPaletteContent()
    private let separator = NSBox()
    private let symbol = NSImageView()
    private(set) var glass: NSGlassEffectView?
    private var overlay: CommandPaletteOverlay?
    private(set) var results: [AddressResult] = []
    private(set) var typedText = ""
    private var prefilledSourceURL: URL?
    private var currentSourceResultID: AddressResult.Action?
    private var inputWasEdited = false
    private var inputLeadingInset: CGFloat?
    private(set) var completionStart: Int?
    private weak var previousResponder: NSResponder?
    private weak var sourceTab: BrowserTab?
    private var sourceSpaceID: UUID?
    private var sourceRevision = 0
    private weak var sourceFocusedPage: BrowserTab?
    private var focusedPageRevision = 0
    private var sourcePeekID: UUID?
    private(set) var mode: CommandPaletteMode = .newDestination
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var pendingMouseUp: NSEvent.EventType?
    private var focusTask: Task<Void, Never>?

    var isPresented: Bool { overlay != nil }
    var contextIsValid: Bool {
        guard let browser, !browser.isClosed else { return false }
        return browser.activeTab === sourceTab && browser.activeSpaceID == sourceSpaceID
            && (sourceTab?.navigationRevision ?? 0) == sourceRevision && browser.peek?.id == sourcePeekID
            && browser.focusedPage === sourceFocusedPage
            && (sourceFocusedPage?.navigationRevision ?? 0) == focusedPageRevision
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
        field.alignment = .left
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
        symbol.image = CommandPaletteLayout.image("magnifyingglass")
        symbol.identifier = .init("CommandPalette.icon")
        symbol.imageScaling = .scaleNone
        symbol.contentTintColor = .secondaryLabelColor
        symbol.setAccessibilityElement(false)
        separator.boxType = .separator
        let column = NSTableColumn(identifier: .init("result"))
        table.addTableColumn(column)
        table.headerView = nil
        // The palette supplies its own margins and fixed two-line rows. Inferred
        // inset styles can add padding outside the manually sized viewport.
        table.style = .plain
        table.rowSizeStyle = .custom
        table.rowHeight = 42
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none // The selected row owns its native glass pill.
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
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
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        for view in [symbol, field, separator, scroll] { content.addSubview(view) }
    }

    isolated deinit {
        focusTask?.cancel()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    @discardableResult
    func present(mode: CommandPaletteMode = .newDestination) -> Bool {
        guard let browser, !browser.isClosed, let anchor, let window = anchor.window,
              anchor.bounds.width > 0, anchor.bounds.height > 0,
              window.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        focusTask?.cancel()
        if isPresented, contextIsValid {
            if mode == .newDestination, self.mode == .newDestination {
                window.makeFirstResponder(field)
                field.selectText(nil)
                layoutPresentation()
            } else {
                resetInput(mode: mode)
                focusInput(in: window)
            }
            return true
        }
        if isPresented { dismiss(restoreFocus: false, updatesRequest: false) }
        removeEventMonitor()
        if let peek = browser.peek { previousResponder = peek.tab.webView }
        else { previousResponder = ((window.firstResponder as? NSTextView)?.delegate as? NSResponder) ?? window.firstResponder }
        sourceTab = browser.activeTab
        sourceSpaceID = browser.activeSpaceID
        sourceRevision = sourceTab?.navigationRevision ?? 0
        sourceFocusedPage = browser.focusedPage
        focusedPageRevision = sourceFocusedPage?.navigationRevision ?? 0
        sourcePeekID = browser.peek?.id
        field.browserWindow = window
        resetInput(mode: mode)
        let overlay = CommandPaletteOverlay(frame: anchor.bounds)
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
        // Do not mutate NSHostingController.view's SwiftUI-managed subviews.
        // The actual representable owns this native presentation subtree.
        anchor.addSubview(overlay)
        self.overlay = overlay
        self.glass = glass
        layoutPresentation()
        installEvents(in: window)
        focusInput(in: window)
        NSAccessibility.post(element: field, notification: .focusedUIElementChanged)
        return true
    }

    private func focusInput(in window: NSWindow) {
        window.makeFirstResponder(field)
        field.selectText(nil)
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = typedText
            editor.setSelectedRange(NSRange(location: 0, length: typedText.utf16.count))
            editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            // Keep the native unscrolled drawing inset, not the document's
            // changing position while the user scrolls a long URL horizontally.
            inputLeadingInset = CommandPaletteLayout.leadingPoint(field).x
        }
        layoutPresentation()
    }

    private func resetInput(mode: CommandPaletteMode) {
        (field.currentEditor() as? NSTextView)?.unmarkText()
        self.mode = mode
        prefilledSourceURL = mode == .editCurrentDestination ? sourceFocusedPage?.url : nil
        typedText = prefilledSourceURL?.absoluteString ?? ""
        inputWasEdited = false
        completionStart = nil
        field.updatePresentation(text: typedText, url: nil, title: "")
        refreshResults()
    }

    func dismiss(restoreFocus: Bool = true, updatesRequest: Bool = true) {
        focusTask?.cancel()
        if updatesRequest { browser?.commandPaletteDidDismiss(self) }
        guard let overlay else { return }
        let window = overlay.window
        if let editor = field.currentEditor() as? NSTextView { editor.unmarkText() }
        if field.currentEditor() != nil || window?.firstResponder === table { window?.makeFirstResponder(nil) }
        overlay.removeFromSuperview()
        self.overlay = nil
        glass = nil
        results = []
        table.deselectAll(nil)
        table.reloadData()
        typedText = ""
        prefilledSourceURL = nil
        currentSourceResultID = nil
        inputLeadingInset = nil
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
        let rowsHeight = table.rowsHeight
        let resultHeight = results.isEmpty ? 0 : min(rowsHeight, min(336, max(table.rowHeight, area.height - 160)))
        let height = results.isEmpty ? 64 : 80 + resultHeight
        let centerY = area.midY + min(60, area.height * 0.08)
        let y = max(area.minY + 16, min(centerY - height / 2, area.maxY - height - 16))
        glass.frame = NSRect(x: area.midX - width / 2, y: y, width: width, height: height)
        content.frame = NSRect(origin: .zero, size: glass.bounds.size)
        separator.frame = NSRect(x: 12, y: 64, width: max(0, width - 24), height: 1)
        scroll.frame = NSRect(x: 8, y: 72, width: max(0, width - 16), height: resultHeight)
        table.setFrameSize(NSSize(width: table.frame.width, height: rowsHeight))
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        content.leadingAdjustment = max(0, scroll.readableContentBounds.minX - scroll.contentView.bounds.minX)
        CommandPaletteLayout.place(symbol, center: NSPoint(x: CommandPaletteLayout.iconCenterX + content.leadingAdjustment, y: 32))
        let textX = CommandPaletteLayout.textX + content.leadingAdjustment
        CommandPaletteLayout.place(field, textX: textX,
                                   baselineY: 32 + (field.font?.capHeight ?? 0) / 2,
                                   width: max(0, width - textX - CommandPaletteLayout.inset), leadingInset: inputLeadingInset)
        separator.isHidden = results.isEmpty
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
        if text != typedText { inputWasEdited = true }
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
        currentSourceResultID = nil
        if !inputWasEdited, let url = prefilledSourceURL, typedText == url.absoluteString, let source = sourceFocusedPage {
            // This is a checked current-source intent, not permission to parse
            // arbitrary typed schemes. It also outranks matching *other* tabs.
            let current = AddressResult(owner: ObjectIdentifier(browser), action: .navigate(url), title: source.title,
                                        detail: url.absoluteString,
                                        destinationSpace: browser.isPrivate ? "Private Window" : browser.spaces.space(browser.activeSpaceID)?.title)
            currentSourceResultID = current.id
            results.removeAll { $0.id == current.id }
            results.insert(current, at: 0)
            if results.count > 8, let index = results.lastIndex(where: {
                if case .search = $0.action { return false }
                return true
            }) {
                // The shared builder reserves explicit Search. Keep that slot
                // when current-source intent displaces a lower-ranked match.
                results.remove(at: index)
            }
        }
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
            guard !results.isEmpty else { return true }
            let offset = command == .moveDown ? 1 : -1
            let row = min(max(0, table.selectedRow + offset), results.count - 1)
            if row != table.selectedRow { completionStart = nil }
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
        let displayedText = field.currentEditor()?.string ?? field.stringValue
        if !inputWasEdited, result.id == currentSourceResultID, let url = prefilledSourceURL,
           displayedText == url.absoluteString, let source = sourceFocusedPage, source.url == url {
            guard source.browser === browser, source.spaceID == sourceSpaceID,
                  browser.spaces.space(source.spaceID)?.profileID == source.profileID,
                  (browser.tabAcrossSpaces(withID: source.id) === source || browser.peek?.tab === source),
                  browser.websiteDataStore(forProfileID: source.profileID) != nil else {
                dismiss(restoreFocus: false)
                return
            }
            // The unchanged current URL means return to this exact live page.
            // Retain its document/form state, for HTTP and unsupported schemes
            // alike. No reload, search, tab switch, or broad scheme allowance.
            dismiss()
            return
        }
        // Other selected rows are explicit actions, even without a text edit.
        // A completion's visible host may be shorter than its history resource.
        // Return accepts that exact completion; explicit row clicks accept the row.
        var accepted = result
        if acceptCompletion, completionStart != nil, table.selectedRow == 0,
           let url = AddressSuggestions.completedURL(for: displayedText, with: result.completionSuggestion) {
            accepted = AddressResult(owner: result.owner, action: .navigate(url), title: result.title,
                                     detail: result.detail, destinationSpace: result.destinationSpace)
        }
        guard AddressResults.execute(accepted, in: browser, inNewTab: mode == .newDestination,
                                     navigationSource: mode == .editCurrentDestination ? sourceFocusedPage : nil) else {
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
        cell.update(results[row], selected: tableView.isRowSelected(row), reference: content)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CommandPaletteResultRow()
        view.isSelected = tableView.isRowSelected(row)
        return view
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

/// Palette-only guides. Native cell insets and the live field-editor baseline
/// are measured rather than treating different controls' outer frames as text.
@MainActor
enum CommandPaletteLayout {
    static let inset: CGFloat = 18
    static let iconCenterX: CGFloat = 26
    static let textX: CGFloat = 44

    static func image(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
    }

    static func leadingPoint(_ field: NSTextField) -> NSPoint {
        if let editor = field.currentEditor() as? NSTextView {
            let x = editor.bounds.minX + editor.textContainerOrigin.x + (editor.textContainer?.lineFragmentPadding ?? 0)
            return field.convert(NSPoint(x: x, y: editor.bounds.minY), from: editor)
        }
        let rect = field.cell?.titleRect(forBounds: field.bounds) ?? field.bounds
        return NSPoint(x: rect.minX, y: rect.minY)
    }

    static func baselinePoint(_ field: NSTextField) -> NSPoint {
        if let editor = field.currentEditor() as? NSTextView,
           let layout = editor.layoutManager, let container = editor.textContainer {
            layout.ensureLayout(for: container)
            let range = layout.glyphRange(for: container)
            if range.length > 0 {
                let fragment = layout.lineFragmentRect(forGlyphAt: range.location, effectiveRange: nil)
                let location = layout.location(forGlyphAt: range.location)
                return field.convert(NSPoint(x: editor.textContainerOrigin.x + fragment.minX + location.x,
                                             y: editor.textContainerOrigin.y + fragment.minY + location.y), from: editor)
            }
        }
        let y = field.isFlipped ? field.bounds.minY + field.firstBaselineOffsetFromTop
            : field.bounds.maxY - field.firstBaselineOffsetFromTop
        return NSPoint(x: field.bounds.minX, y: y)
    }

    static func place(_ field: NSTextField, textX: CGFloat, baselineY: CGFloat, width: CGFloat, leadingInset: CGFloat? = nil) {
        let height = ceil(max(field.intrinsicContentSize.height, field.cell?.cellSize.height ?? 0))
        field.setFrameSize(NSSize(width: max(0, width), height: max(1, height)))
        let cellRect = field.cell?.titleRect(forBounds: field.bounds) ?? field.bounds
        let extraWidth = cellRect.minX - field.bounds.minX + field.bounds.maxX - cellRect.maxX
        field.setFrameSize(NSSize(width: max(0, width + extraWidth), height: field.frame.height))
        guard let parent = field.superview else { return }
        let leading = parent.convert(leadingInset.map { NSPoint(x: $0, y: 0) } ?? leadingPoint(field), from: field)
        let baseline = parent.convert(baselinePoint(field), from: field)
        field.setFrameOrigin(NSPoint(x: field.frame.minX + textX - leading.x,
                                     y: field.frame.minY + baselineY - baseline.y))
    }

    static func place(_ view: NSImageView, center: NSPoint) {
        guard let image = view.image else { view.frame = .zero; return }
        let alignment = image.alignmentRect
        let y = view.superview?.isFlipped == true ? image.size.height - alignment.midY : alignment.midY
        view.frame = NSRect(x: center.x - alignment.midX, y: center.y - y,
                            width: image.size.width, height: image.size.height)
    }
}

private final class CommandPaletteContent: NSView {
    var leadingAdjustment: CGFloat = 0
    override var isFlipped: Bool { true }
}

private final class CommandPaletteOverlay: NSView {
    var onDismiss: (() -> Void)?
    var onLayout: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
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

/// Size against the laid-out clip view, not the scroll view's nominal content
/// size. Overlay scrollers occupy real pixels too; reserve their measured overlap
/// only when the list actually overflows. Legacy scrollers already reduce the clip.
final class CommandPaletteResultsScrollView: NSScrollView {
    override func tile() {
        super.tile()
        fitResultColumn()
    }

    override func layout() {
        super.layout()
        fitResultColumn()
    }

    var readableContentBounds: NSRect {
        var rect = contentView.bounds
        if let table = documentView as? CommandPaletteTable, table.rowsHeight > rect.height,
           let scroller = verticalScroller, !scroller.isHidden {
            let overlap = contentView.convert(scroller.bounds, from: scroller).intersection(rect)
            if !overlap.isNull, overlap.width > 0 {
                if overlap.midX > rect.midX { rect.size.width = max(0, overlap.minX - rect.minX) }
                else {
                    let end = rect.maxX
                    rect.origin.x = overlap.maxX
                    rect.size.width = max(0, end - rect.minX)
                }
            }
        }
        return rect
    }

    private func fitResultColumn() {
        guard let table = documentView as? CommandPaletteTable else { return }
        let canvasWidth = contentView.bounds.width
        let columnWidth = readableContentBounds.width
        // NSTableView's document canvas fills the clip even when its single
        // column is narrower. Keep the measured overlay-scroller gutter in the
        // column, rather than fighting AppKit's minimum document width.
        if table.frame.width != canvasWidth { table.setFrameSize(NSSize(width: canvasWidth, height: table.frame.height)) }
        let width = max(0, columnWidth)
        if table.tableColumns.first?.width != width { table.tableColumns.first?.width = width }
    }
}

final class CommandPaletteTable: NSTableView {
    /// Includes native row origins and intercell spacing; do not approximate
    /// this with result count times a separate row-height constant.
    var rowsHeight: CGFloat { numberOfRows == 0 ? 0 : rect(ofRow: numberOfRows - 1).maxY }

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

private final class CommandPaletteSelectionGlass: NSGlassEffectView {
    // A decorative selection background must not take clicks from the row.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CommandPaletteResultRow: NSTableRowView {
    private let selectionGlass = CommandPaletteSelectionGlass()
    override var isSelected: Bool { didSet { updateCells() } }
    // Glass uses semantic foregrounds, not the flat highlight's white-text mode.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        selectionGlass.style = .regular
        selectionGlass.identifier = .init("CommandResult.selectionGlass")
        selectionGlass.setAccessibilityElement(false)
        selectionGlass.isHidden = true
        addSubview(selectionGlass, positioned: .below, relativeTo: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawSelection(in dirtyRect: NSRect) {} // No square AppKit fill behind the glass.

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateCells()
    }

    override func layout() {
        super.layout()
        let readable = (enclosingScrollView as? CommandPaletteResultsScrollView)
            .map { convert($0.readableContentBounds, from: $0.contentView) } ?? bounds
        // Only inset the horizontal readable region. The clip view clips vertical
        // scrolling; intersecting it here would reshape partially visible pills.
        let left = max(bounds.minX, readable.minX)
        let right = min(bounds.maxX, readable.maxX)
        selectionGlass.frame = NSRect(x: left + 4, y: bounds.minY + 1,
                                     width: max(0, right - left - 8), height: max(0, bounds.height - 2))
        selectionGlass.cornerRadius = selectionGlass.bounds.height / 2
    }

    private func updateCells() {
        let selected = superview != nil && isSelected
        selectionGlass.isHidden = !selected
        needsLayout = true
        for cell in subviews.compactMap({ $0 as? CommandPaletteResultCell }) {
            cell.setSelected(selected)
        }
    }
}

final class CommandPaletteResultCell: NSTableCellView {
    let symbol = NSImageView()
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    let returnSymbol = NSImageView()
    private weak var reference: NSView?
    private(set) var isResultSelected = false
    override var isFlipped: Bool { true }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }

    init() {
        super.init(frame: .zero)
        identifier = .init("CommandResult")
        for (label, name) in [(title, "title"), (detail, "detail")] {
            label.identifier = .init("CommandResult.\(name)")
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
            label.font = .systemFont(ofSize: label === title ? 13 : 11)
            addSubview(label)
        }
        symbol.identifier = .init("CommandResult.icon")
        returnSymbol.identifier = .init("CommandResult.return")
        returnSymbol.image = CommandPaletteLayout.image("return")
        for image in [symbol, returnSymbol] {
            image.imageScaling = .scaleNone
            image.setAccessibilityElement(false)
            addSubview(image)
        }
        returnSymbol.isHidden = true
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ result: AddressResult, selected: Bool, reference: NSView) {
        self.reference = reference
        userInterfaceLayoutDirection = reference.userInterfaceLayoutDirection
        for view in [title, detail, symbol, returnSymbol] { view.userInterfaceLayoutDirection = userInterfaceLayoutDirection }
        title.stringValue = result.title
        switch result.action {
        case .search, .command, .switchSpace: detail.stringValue = ""
        default: detail.stringValue = result.detail == result.title ? "" : result.detail
        }
        detail.isHidden = detail.stringValue.isEmpty
        symbol.image = CommandPaletteLayout.image(result.symbol)
        for label in [title, detail] { label.toolTip = label.stringValue }
        var context = [result.title, detail.stringValue, result.actionLabel]
        if let space = result.destinationSpace, space != result.title { context.append(space) }
        let accessible = context.filter { !$0.isEmpty }.joined(separator: ", ")
        setAccessibilityLabel(accessible)
        toolTip = accessible
        setSelected(selected)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        setSelected((superview as? NSTableRowView)?.isSelected == true)
    }

    func setSelected(_ selected: Bool) {
        isResultSelected = selected
        returnSymbol.isHidden = !selected
        needsLayout = true
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        detail.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
        symbol.contentTintColor = title.textColor
        returnSymbol.contentTintColor = title.textColor
    }

    override func layout() {
        super.layout()
        guard let reference, let titleFont = title.font, let detailFont = detail.font else { return }
        let adjustment = (reference as? CommandPaletteContent)?.leadingAdjustment ?? 0
        let textX = convert(NSPoint(x: CommandPaletteLayout.textX + adjustment, y: 0), from: reference).x
        let iconX = convert(NSPoint(x: CommandPaletteLayout.iconCenterX + adjustment, y: 0), from: reference).x
        let readable = enclosingScrollView.flatMap { $0 as? CommandPaletteResultsScrollView }
            .map { convert($0.readableContentBounds, from: $0.contentView).intersection(bounds) } ?? bounds
        let trailing = readable.maxX - 10
        let textWidth = max(0, trailing - textX - (isResultSelected ? 26 : 0))
        let firstInkHeight = titleFont.capHeight - titleFont.descender
        let secondInkHeight = detail.isHidden ? 0 : detailFont.capHeight - detailFont.descender
        let groupHeight = firstInkHeight + (detail.isHidden ? 0 : 2 + secondInkHeight)
        let firstBaseline = bounds.midY - groupHeight / 2 + titleFont.capHeight
        CommandPaletteLayout.place(title, textX: textX, baselineY: firstBaseline, width: textWidth)
        if !detail.isHidden {
            let secondBaseline = firstBaseline - titleFont.descender + 2 + detailFont.capHeight
            CommandPaletteLayout.place(detail, textX: textX, baselineY: secondBaseline, width: textWidth)
        }
        CommandPaletteLayout.place(symbol, center: NSPoint(x: iconX, y: bounds.midY))
        CommandPaletteLayout.place(returnSymbol, center: NSPoint(x: trailing - 7, y: bounds.midY))
    }
}
