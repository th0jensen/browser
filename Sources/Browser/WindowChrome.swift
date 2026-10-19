import AppKit
import SwiftUI

enum BrowserChrome {
    /// Horizontal tabs occupy the native titlebar above the navigation toolbar.
    static let tabRowHeight: CGFloat = 32
    static let tabHeight: CGFloat = 30
    static let sidebarWidth: CGFloat = 236
    static let sidebarMinimumWidth = 180.0
    static let sidebarMaximumWidth = 420.0
    static let sidebarTabHeight: CGFloat = 32
    /// Inset shared by the navigation bar and the page, so their edges line up.
    static let edgeInset: CGFloat = 8
    /// One chrome-width inside the page's existing outer chrome-width.
    static let revealInset: CGFloat = edgeInset * 2

    static func tabContentOpacity(active: Bool, hovered: Bool, loaded: Bool) -> Double {
        if active { return 1 }
        if hovered { return loaded ? 1 : 0.82 }
        return loaded ? 0.88 : 0.6
    }
    /// Shared by both tab layouts; based on the vertical header's balanced margin.
    static func windowControlsLeadingInset(controlHeight: CGFloat) -> CGFloat {
        (toolbarHeight + edgeInset * 3 - controlHeight) / 2
    }
    static let sidebarCornerRadius: CGFloat = 20
    static let contentCornerRadius: CGFloat = 12
    static let toolbarHeight: CGFloat = 24
    static let toolbarSymbolSize: CGFloat = 14
    static let pinHeight: CGFloat = 40
    static let pinIconSize: CGFloat = 20
    static let smallGap: CGFloat = 4
}

enum TabLayout: String, CaseIterable, Identifiable {
    case horizontal
    case vertical

    static let storageKey = "tabLayout"

    var id: Self { self }

    var title: String {
        switch self {
        case .horizontal: "Horizontal"
        case .vertical: "Vertical"
        }
    }

    var toggled: TabLayout { self == .vertical ? .horizontal : .vertical }
}

enum SidebarVisibility {
    static let autoHideKey = "automaticallyHideSidebar"
}

/// Hosts horizontal tabs above the native toolbar, while AppKit owns toolbar customization and window controls.
struct WindowChromeConfigurator: NSViewRepresentable {
    let tabLayout: TabLayout
    let horizontalTabs: AnyView
    @Binding var isFullScreen: Bool
    var compactToolbar = false
    var insetRevealedToolbar = false
    var toolbarIsRevealed = true
    var hoverController: ChromeHoverController?
    var savedToolbarConfiguration: Binding<Data>?
    var nativeCommands: [NativeToolbarCommand] = []
    var toolbarDisplayMode: NSToolbar.DisplayMode? = nil
    var toolbarContextMenu: (@MainActor () -> NSMenu)?
    var onCustomizationChange: ((Bool) -> Void)?
    var onToolbarItemsChange: (([String]) -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?
    var onToolbarRegionHeight: ((CGFloat) -> Void)?

    static func dismantleNSView(_ view: WindowChromeView, coordinator: ()) {
        view.detachNativeCommands()
    }

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.onFullScreenChange = { if isFullScreen != $0 { isFullScreen = $0 } }
        view.onWindowChange = onWindowChange
        view.onToolbarRegionHeight = onToolbarRegionHeight
        view.onCustomizationChange = onCustomizationChange
        view.onToolbarItemsChange = onToolbarItemsChange
        view.toolbarContextMenu = toolbarContextMenu
        view.savedToolbarConfiguration = savedToolbarConfiguration
        view.insetRevealedToolbar = insetRevealedToolbar
        view.setNativeCommands(nativeCommands, displayMode: toolbarDisplayMode, applyImmediately: false)
        hoverController?.nativeToolbarPresenter = view
        view.update(layout: tabLayout, tabs: horizontalTabs, compactToolbar: compactToolbar,
                    toolbarIsRevealed: hoverController?.toolbarIsRevealed ?? toolbarIsRevealed)
    }
}

final class WindowChromeView: NSView {
    var insetRevealedToolbar = false
    var onFullScreenChange: ((Bool) -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?
    var onToolbarRegionHeight: ((CGFloat) -> Void)?
    private(set) var measuredToolbarRegionHeight: CGFloat?
    var onCustomizationChange: ((Bool) -> Void)?
    var onToolbarItemsChange: (([String]) -> Void)?
    private var observers: [NSObjectProtocol] = []
    var savedToolbarConfiguration: Binding<Data>?
    private let layoutPersistence = ToolbarLayoutPersistence()
    private var customizationAdapter: ToolbarCustomizationAdapter?
    private weak var customizationToolbar: NSToolbar?
    private var nativeConfigurationKeys = Set<String>()
    private var tabLayout = TabLayout.horizontal
    private let tabAccessory = NSTitlebarAccessoryViewController()
    private let trailingAccessory = NSTitlebarAccessoryViewController()
    private let trailingReservation = NSView(frame: NSRect(x: 0, y: 0, width: BrowserChrome.edgeInset, height: 1))
    private let tabs = TitlebarTabHostingView(rootView: AnyView(EmptyView()))
    private let tabContainer = TitlebarTabContainer()
    private let tabReservation = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: BrowserChrome.tabRowHeight))
    private var hasInstalledTabs = false
    private weak var shiftedToolbar: NSView?
    private var chromeWasVisible = true
    private var originalToolbarOrigin = NSPoint.zero
    private var alignmentIsScheduled = false
    private var centeringTitlebarControls = false
    private var toolbarSeparators: [ObjectIdentifier: ToolbarSeparatorView] = [:]
    private var compactToolbar = false
    private var toolbarIsRevealed = true
    private weak var observedToolbar: NSToolbar?
    private var toolbarObservations: [NSKeyValueObservation] = []
    private var toolbarItemObservers: [NSObjectProtocol] = []
    private var lastToolbarItemIdentifiers: [String] = []
    private var lastCustomizationState = false
    private var windowControlOffsets: [NSWindow.ButtonType: CGFloat] = [:]
    private var controlObservers: [NSObjectProtocol] = []
    private var observedControlViews: [ObjectIdentifier] = []
    private var nativeCommands: [String: NativeToolbarCommand] = [:]
    private var nativeCommandsRevision: UInt64 = 0
    private var appliedNativeCommandsRevision: UInt64?
    private var toolbarDisplayMode: NSToolbar.DisplayMode?
    private var nativeAdapters: [ObjectIdentifier: NativeToolbarCommandAdapter] = [:]
    var toolbarContextMenu: (@MainActor () -> NSMenu)?
    private var contextMenuMonitor: Any?

    isolated deinit {
        if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
        nativeAdapters.values.forEach { $0.restore() }
        toolbarSeparators.values.forEach { $0.removeFromSuperview() }
        observers.forEach(NotificationCenter.default.removeObserver)
        controlObservers.forEach(NotificationCenter.default.removeObserver)
        toolbarItemObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func refresh() { updateWindowState() }

    func setNativeCommands(_ commands: [NativeToolbarCommand], displayMode: NSToolbar.DisplayMode? = nil,
                           applyImmediately: Bool = true) {
        toolbarDisplayMode = displayMode
        nativeCommands = Dictionary(commands.map { ($0.identifier, $0) }, uniquingKeysWith: { _, new in new })
        nativeCommandsRevision &+= 1
        // The representable configures the window next; apply there after any native
        // toolbar changes. Direct callers still receive an immediate command update.
        if applyImmediately { applyNativeCommands() }
    }

    func detachNativeCommands() {
        clearToolbarSeparators()
        nativeCommands.removeAll()
        restoreNativeCommands()
        toolbarContextMenu = nil
        if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
        contextMenuMonitor = nil
        if let toolbar = customizationToolbar, toolbar.delegate === customizationAdapter { toolbar.delegate = customizationAdapter?.source }
        customizationAdapter = nil
        customizationToolbar = nil
        for key in nativeConfigurationKeys { UserDefaults.standard.removeObject(forKey: key) }
        nativeConfigurationKeys.removeAll()
        if let window, let index = window.titlebarAccessoryViewControllers.firstIndex(of: trailingAccessory) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    private func restoreNativeCommands() {
        nativeAdapters.values.forEach { $0.restore() }
        nativeAdapters.removeAll()
    }

    private func applyNativeCommands() {
        let items = window?.toolbar?.items ?? []
        let commandsChanged = appliedNativeCommandsRevision != nativeCommandsRevision
        let current = Set(items.filter { nativeCommands[$0.itemIdentifier.rawValue] != nil }.map(ObjectIdentifier.init))
        for key in Array(nativeAdapters.keys) where !current.contains(key) {
            nativeAdapters.removeValue(forKey: key)?.restore()
        }
        for item in items {
            guard let command = nativeCommands[item.itemIdentifier.rawValue] else { continue }
            let key = ObjectIdentifier(item)
            let mode = toolbarDisplayMode ?? window?.toolbar?.displayMode ?? .iconOnly
            if let adapter = nativeAdapters[key] {
                // AppKit update/resize notifications may follow the synchronous
                // configuration pass. Repair a replacement SwiftUI host, but avoid
                // reapplying every command when its native button is already current.
                if commandsChanged || item.view !== adapter.button || adapter.button.displayMode != mode {
                    adapter.update(command, displayMode: mode)
                }
            }
            else { nativeAdapters[key] = NativeToolbarCommandAdapter(item: item, command: command, displayMode: mode) }
            nativeAdapters[key]?.button.visibilityToolbar = window?.toolbar
        }
        appliedNativeCommandsRevision = nativeCommandsRevision
    }

    /// The native pointer callback can reveal existing toolbar views immediately,
    /// without waiting for a SwiftUI update of the page and the rest of the window.
    func setToolbarRevealed(_ revealed: Bool) {
        guard toolbarIsRevealed != revealed else { return }
        toolbarIsRevealed = revealed
        guard let window else { return }
        // Geometry belongs to the chrome configuration, not each hover reveal.
        applyToolbarVisibility(in: window)
        centerTitlebarControls()
    }

    func update(layout: TabLayout, tabs content: AnyView, compactToolbar: Bool = false, toolbarIsRevealed: Bool = true) {
        if tabLayout != layout { measuredToolbarRegionHeight = nil }
        tabLayout = layout
        if self.compactToolbar && !compactToolbar { window?.toolbar?.isVisible = true }
        self.compactToolbar = compactToolbar
        self.toolbarIsRevealed = toolbarIsRevealed
        // Keep the hosted strip's identity stable; it observes BrowserModel itself.
        if !hasInstalledTabs {
            tabs.rootView = content
            tabs.sizingOptions = []
            tabs.safeAreaRegions = []
            tabs.sceneBridgingOptions = []
            tabs.setContentHuggingPriority(.defaultLow, for: .horizontal)
            tabs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            tabs.autoresizingMask = [.width, .height]
            tabContainer.addSubview(tabs)
            hasInstalledTabs = true
        }
        updateWindowState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clearToolbarSeparators()
        if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
        contextMenuMonitor = nil
        restoreNativeCommands()
        measuredToolbarRegionHeight = nil
        restoreToolbarOrigin()
        chromeWasVisible = true
        windowControlOffsets.removeAll()
        controlObservers.forEach(NotificationCenter.default.removeObserver)
        controlObservers.removeAll()
        observedControlViews.removeAll()
        onWindowChange?(window)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        observeToolbar(in: window)
        // AppKit owns empty toolbar space and its default context menu. Route only
        // secondary clicks in that native branch so every item gets our behavior
        // controls, including extension buttons and flexible spaces. Text editing
        // and the navigation buttons retain their own contextual actions.
        contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let menu = self.contextMenu(for: event), let window = self.window,
                      let branch = self.toolbarBranch(in: window) else { return false }
                // Finish routing the input before entering AppKit's menu tracking
                // loop; otherwise accessibility clicks wait for the menu to close.
                DispatchQueue.main.async { NSMenu.popUpContextMenu(menu, with: event, for: branch) }
                return true
            }
            return handled ? nil : event
        }

        let names: [Notification.Name] = [
            NSWindow.willCloseNotification,
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didUpdateNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == NSWindow.willCloseNotification { self?.detachNativeCommands() }
                    else if name == NSWindow.didUpdateNotification || name == NSWindow.didResizeNotification {
                        // A resize changes geometry, not window configuration. Its native controls and
                        // tab row already share one coalesced alignment pass with AppKit's layout updates.
                        self?.scheduleAlignment()
                    }
                    else {
                        if name == NSWindow.didEnterFullScreenNotification || name == NSWindow.didExitFullScreenNotification {
                            self?.measuredToolbarRegionHeight = nil
                        }
                        self?.updateWindowState()
                    }
                }
            }
        }
        observeWindowControls(in: window)
        DispatchQueue.main.async { [weak self] in self?.updateWindowState() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func contextMenu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              let window, event.window === window, window.attachedSheet == nil,
              let toolbar = window.toolbar, toolbar.isVisible, !toolbar.customizationPaletteIsRunning,
              let branch = toolbarBranch(in: window), !branch.isHiddenOrHasHiddenAncestor,
              branch.bounds.contains(branch.convert(event.locationInWindow, from: nil)) else { return nil }
        for item in toolbar.items where ["back", "forward"].contains(item.itemIdentifier.rawValue) {
            if let view = item.view, !view.isHiddenOrHasHiddenAncestor,
               view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { return nil }
        }
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           editor.visibleRect.contains(editor.convert(event.locationInWindow, from: nil)) { return nil }
        return toolbarContextMenu?()
    }

    private func updateWindowState() {
        guard let window else { return }
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.contains("address") }) {
            if item.visibilityPriority != .high { item.visibilityPriority = .high }
        }
        // AppKit can reshape the toolbar even when a setter receives its current value.
        // Refreshes are frequent during page and address updates, so only apply real changes.
        let transparentTitlebar = tabLayout != .horizontal
        if window.titlebarAppearsTransparent != transparentTitlebar {
            window.titlebarAppearsTransparent = transparentTitlebar
        }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
        if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
        let style: NSWindow.ToolbarStyle = tabLayout == .horizontal ? .expanded : .unifiedCompact
        if window.toolbarStyle != style { window.toolbarStyle = style }
        // Reserve the floating row's outer inset through AppKit's layout, so
        // the address field yields width instead of pushing the last group out.
        let needsTrailingInset = (insetRevealedToolbar || compactToolbar) && tabLayout == .vertical && !window.styleMask.contains(.fullScreen)
        if needsTrailingInset {
            if !window.titlebarAccessoryViewControllers.contains(trailingAccessory) {
                trailingAccessory.layoutAttribute = .right
                trailingAccessory.view = trailingReservation
                window.addTitlebarAccessoryViewController(trailingAccessory)
            }
        } else if let index = window.titlebarAccessoryViewControllers.firstIndex(of: trailingAccessory) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        applyToolbarVisibility(in: window)
        applyNativeCommands()
        if tabLayout == .horizontal && (!compactToolbar || window.toolbar?.isVisible == true) {
            if !window.titlebarAccessoryViewControllers.contains(tabAccessory) {
                tabAccessory.layoutAttribute = .right
                tabAccessory.view = tabReservation
                window.addTitlebarAccessoryViewController(tabAccessory)
            }
            var ancestor = tabReservation.superview
            while let view = ancestor, view.bounds.width < window.frame.width - 1 { ancestor = view.superview }
            if let header = ancestor {
                if tabContainer.superview !== header { header.addSubview(tabContainer) }
                layoutHorizontalTabs(in: window, header: header)
            }
        } else {
            tabContainer.removeFromSuperview()
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: tabAccessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
        }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        centerTitlebarControls()
        scheduleAlignment()
        if let onFullScreenChange {
            DispatchQueue.main.async { onFullScreenChange(isFullScreen) }
        }
    }

    private func scheduleAlignment() {
        guard !alignmentIsScheduled else { return }
        alignmentIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.alignmentIsScheduled = false
            if let window = self.window {
                self.observeToolbar(in: window)
                self.applyToolbarVisibility(in: window)
                self.publishToolbarItems(in: window)
                self.applyNativeCommands()
                ToolbarAddressAllocation.update(in: window)
            }
            self.centerTitlebarControls()
        }
    }

    /// Center native glass and hit regions together, including the page's top inset in the header.
    private func centerTitlebarControls() {
        guard !centeringTitlebarControls else { return }
        centeringTitlebarControls = true
        defer { centeringTitlebarControls = false }
        guard let window else { clearToolbarSeparators(); restoreToolbarOrigin(); return }
        observeWindowControls(in: window)
        guard !window.styleMask.contains(.fullScreen) else { clearToolbarSeparators(); restoreToolbarOrigin(); return }
        guard window.toolbar?.isVisible == true else { clearToolbarSeparators(); return }
        positionWindowControls(in: window)
        guard let branch = toolbarBranch(in: window) else { clearToolbarSeparators(); return }
        if shiftedToolbar !== branch {
            restoreToolbarOrigin()
            shiftedToolbar = branch
            originalToolbarOrigin = branch.bounds.origin
        }
        let offset = tabLayout == .vertical
            ? BrowserChrome.edgeInset / 2 + ((compactToolbar || insetRevealedToolbar) ? BrowserChrome.edgeInset / 2 : 0)
            : BrowserChrome.edgeInset
        let origin = NSPoint(x: originalToolbarOrigin.x,
                             y: originalToolbarOrigin.y + (branch.isFlipped ? -offset : offset))
        if branch.bounds.origin != origin { branch.setBoundsOrigin(origin) }

        // Moving the toolbar branch can also move its sibling controls on native relayout.
        positionWindowControls(in: window)
        layoutToolbarSeparators(in: window, branch: branch)
        reportToolbarRegionHeight(in: window, branch: branch)
    }

    private func clearToolbarSeparators() {
        toolbarSeparators.values.forEach { $0.removeFromSuperview() }
        toolbarSeparators.removeAll()
    }

    /// System fixed spaces end glass groups but expose no custom view. Draw stock
    /// separators between their neighboring controls without replacing AppKit's space views.
    private func layoutToolbarSeparators(in window: NSWindow, branch: NSView) {
        let items = window.toolbar?.visibleItems ?? []
        var current = Set<ObjectIdentifier>()
        for (index, item) in items.enumerated() where item.itemIdentifier == .space {
            guard let left = items[..<index].lastIndex(where: { $0.view?.window === window }),
                  let right = items[(index + 1)...].firstIndex(where: { $0.view?.window === window }),
                  let leftView = items[left].view, let rightView = items[right].view else { continue }
            let leading = leftView.convert(leftView.bounds, to: branch)
            let trailing = rightView.convert(rightView.bounds, to: branch)
            let spaceIndices = ((left + 1)..<right).filter {
                items[$0].itemIdentifier == .space || items[$0].itemIdentifier == .flexibleSpace
            }
            guard let ordinal = spaceIndices.firstIndex(of: index), trailing.minX > leading.maxX else { continue }
            let span = trailing.minX - leading.maxX
            let flexibleCount = spaceIndices.filter { items[$0].itemIdentifier == .flexibleSpace }.count
            let fixedWidth = flexibleCount == 0 ? span / CGFloat(spaceIndices.count) : min(20, span / CGFloat(spaceIndices.count))
            let flexibleWidth = flexibleCount == 0 ? 0 : max(0, span - fixedWidth * CGFloat(spaceIndices.count - flexibleCount)) / CGFloat(flexibleCount)
            let precedingWidth = spaceIndices.prefix(ordinal).reduce(CGFloat.zero) {
                $0 + (items[$1].itemIdentifier == .flexibleSpace ? flexibleWidth : fixedWidth)
            }
            let key = ObjectIdentifier(item)
            current.insert(key)
            let separator = toolbarSeparators[key] ?? ToolbarSeparatorView()
            toolbarSeparators[key] = separator
            if separator.superview !== branch { branch.addSubview(separator) }
            let frame = NSRect(x: leading.maxX + precedingWidth + fixedWidth / 2 - 0.5,
                               y: (leading.midY + trailing.midY) / 2 - 10, width: 1, height: 20)
            if separator.frame != frame { separator.frame = frame }
        }
        for key in Array(toolbarSeparators.keys) where !current.contains(key) {
            toolbarSeparators.removeValue(forKey: key)?.removeFromSuperview()
        }
    }

    private func reportToolbarRegionHeight(in window: NSWindow, branch: NSView) {
        var views = [branch] + (window.toolbar?.items.compactMap(\.view) ?? [])
        if tabLayout == .horizontal, tabContainer.window === window { views.append(tabContainer) }
        views += [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        let bottom = views.filter { $0.window === window }.map { $0.convert($0.bounds, to: nil).minY }.min()
        guard let bottom else { return }
        let height = max(0, window.frame.height - bottom)
        guard height.isFinite, height > 0,
              measuredToolbarRegionHeight.map({ abs($0 - height) > 0.01 }) ?? true else { return }
        measuredToolbarRegionHeight = height
        onToolbarRegionHeight?(height)
    }

    private func positionWindowControls(in window: NSWindow) {
        guard let close = window.standardWindowButton(.closeButton) else { return }
        // Horizontal traffic lights belong to the tab row; vertical lights share the navigation row.
        let center = tabLayout == .vertical
            ? (window.frame.height + window.contentLayoutRect.maxY - BrowserChrome.edgeInset) / 2
                - ((compactToolbar || insetRevealedToolbar) ? BrowserChrome.edgeInset / 2 : 0)
            : window.frame.height - BrowserChrome.tabRowHeight / 2
        let closeFrame = close.convert(close.bounds, to: nil)
        if windowControlOffsets.isEmpty {
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                windowControlOffsets[type] = button.convert(button.bounds, to: nil).minX - closeFrame.minX
            }
        }
        // Keep the same left edge when switching layouts, despite their different row heights.
        let leadingInset = BrowserChrome.windowControlsLeadingInset(controlHeight: closeFrame.height)
            + ((compactToolbar || insetRevealedToolbar) && tabLayout == .vertical ? BrowserChrome.edgeInset / 2 : 0)
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let parent = button.superview,
                  let offset = windowControlOffsets[type] else { continue }
            let target = parent.convert(NSPoint(x: 0, y: center), from: nil).y
            var frame = button.frame
            frame.origin.x = parent.convert(NSPoint(x: leadingInset + offset, y: 0), from: nil).x
            frame.origin.y = target - frame.height / 2
            if abs(button.frame.minX - frame.minX) > 0.01 || abs(button.frame.minY - frame.minY) > 0.01 {
                button.frame = frame
            }
        }
        if tabLayout == .horizontal, let header = tabContainer.superview {
            layoutHorizontalTabs(in: window, header: header)
        }
    }

    private func observeWindowControls(in window: NSWindow) {
        var views: [NSView] = []
        var identities: Set<ObjectIdentifier> = []
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            var ancestor: NSView? = window.standardWindowButton(type)
            while let view = ancestor, view !== window.contentView?.superview {
                if identities.insert(ObjectIdentifier(view)).inserted { views.append(view) }
                ancestor = view.superview
            }
        }
        let signature = views.map(ObjectIdentifier.init)
        guard signature != observedControlViews else { return }
        controlObservers.forEach(NotificationCenter.default.removeObserver)
        controlObservers.removeAll()
        observedControlViews = signature
        for view in views {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                controlObservers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // Native layout may reset these frames while a reload/stop
                        // update is being drawn. Repair geometry before that paint.
                        self?.centerTitlebarControls()
                        self?.scheduleAlignment()
                    }
                })
            }
        }
    }

    private func observeToolbar(in window: NSWindow) {
        if let toolbar = window.toolbar, let delegate = toolbar.delegate {
            if customizationToolbar !== toolbar {
                if let old = customizationToolbar, old.delegate === customizationAdapter { old.delegate = customizationAdapter?.source }
                customizationAdapter = nil
                customizationToolbar = toolbar
            }
            if delegate !== customizationAdapter,
               delegate.toolbarAllowedItemIdentifiers?(toolbar).contains(.init("address")) == true {
                customizationAdapter = ToolbarCustomizationAdapter(source: delegate)
                toolbar.delegate = customizationAdapter
            }
        }
        guard observedToolbar !== window.toolbar else { return }
        toolbarObservations.removeAll()
        toolbarItemObservers.forEach(NotificationCenter.default.removeObserver)
        toolbarItemObservers.removeAll()
        observedToolbar = window.toolbar
        measuredToolbarRegionHeight = nil
        guard let toolbar = window.toolbar else { return }
        // SwiftUI reads AppKit's live configuration when its toolbar content
        // changes. Keep that local configuration current; the shared ordered
        // layout is persisted separately and each window has its own identifier.
        if savedToolbarConfiguration != nil {
            toolbar.autosavesConfiguration = true
            nativeConfigurationKeys.insert("NSToolbar Configuration " + toolbar.identifier)
        }
        if toolbar.displayMode == .default { toolbar.displayMode = .iconOnly }
        toolbarItemObservers = [NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: toolbar, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if toolbar.customizationPaletteIsRunning || (NSApp.currentEvent?.modifierFlags.contains(.command) == true
                        && [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(NSApp.currentEvent?.type)) {
                        self?.layoutPersistence.userIsEditing = true
                    }
                    self?.scheduleAlignment()
                }
            }
        }
        toolbarObservations = [
            toolbar.observe(\.itemIdentifiers) { [weak self] toolbar, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Record the final order while the palette still owns the
                    // edit. SwiftUI can rebuild its items as Done dismisses it.
                    if toolbar.customizationPaletteIsRunning {
                        self.layoutPersistence.capture(toolbar)
                        self.layoutPersistence.userIsEditing = false
                    }
                    self.scheduleAlignment()
                }
            },
            toolbar.observe(\.displayMode) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.measuredToolbarRegionHeight = nil
                    self?.scheduleAlignment()
                }
            },
            toolbar.observe(\.isVisible) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleAlignment() }
            },
            toolbar.observe(\.customizationPaletteIsRunning, options: [.initial, .new]) { [weak self] toolbar, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let running = toolbar.customizationPaletteIsRunning
                    guard running != self.lastCustomizationState else { return }
                    if !running { self.layoutPersistence.finishCustomization() }
                    self.lastCustomizationState = running
                    DispatchQueue.main.async { [weak self] in self?.onCustomizationChange?(running) }
                    self.scheduleAlignment()
                }
            }
        ]
    }

    private func applyToolbarVisibility(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        // Fullscreen compact chrome is a glass overlay inside the page's window. The
        // attached native toolbar still owns configuration and the customization palette.
        let fullscreenOverlay = compactToolbar && window.styleMask.contains(.fullScreen)
        let chromeVisible = toolbar.customizationPaletteIsRunning || !compactToolbar || toolbarIsRevealed
        // Reveal the real toolbar and its system material together. Hiding only its
        // controls leaves AppKit's header background visible without any controls.
        let visible = toolbar.customizationPaletteIsRunning || (!fullscreenOverlay && chromeVisible)
        let visibilityChanged = toolbar.isVisible != visible
        // Restore the controls' reserved space before AppKit lays out a newly
        // visible toolbar; otherwise the address field first uses that space.
        tabContainer.isHidden = fullscreenOverlay || !chromeVisible
        if !window.styleMask.contains(.fullScreen) {
            if chromeVisible && visibilityChanged { positionWindowControls(in: window) }
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(type), button.isHidden != !chromeVisible {
                    button.isHidden = !chromeVisible
                }
            }
        }
        if visibilityChanged {
            // Hidden item views may be detached; prepare their current native allocation before revealing them.
            if visible { ToolbarAddressAllocation.update(in: window) }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                toolbar.isVisible = visible
                // AppKit defers its hidden titlebar's native layout. Complete
                // that pass in this transaction, before the revealed row draws.
                if visible { window.contentView?.superview?.layoutSubtreeIfNeeded() }
            }
        }
        let didReveal = chromeVisible && !chromeWasVisible
        chromeWasVisible = chromeVisible
        if (visibilityChanged || didReveal) && visible && chromeVisible {
            DispatchQueue.main.async { [weak toolbar] in
                guard toolbar?.isVisible == true,
                      let view = toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "address" })?.view else { return }
                Self.applyPendingAddressFocus(in: view)
            }
        }
    }

    /// Locate the toolbar branch beside the native window controls through public
    /// view relationships; this works without the address item in a customized bar.
    private func toolbarBranch(in window: NSWindow) -> NSView? {
        guard let toolbar = window.toolbar, let close = window.standardWindowButton(.closeButton),
              let itemView = toolbar.items.first(where: { $0.itemIdentifier.rawValue.contains("address") })?.view
                ?? toolbar.items.compactMap(\.view).first else { return nil }
        var branch = itemView
        while let parent = branch.superview, !close.isDescendant(of: parent) { branch = parent }
        guard branch.superview != nil, branch !== close,
              branch !== window.contentView?.superview else { return nil }
        return branch
    }

    private func publishToolbarItems(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }
        // Native control leaves have explicit metadata instead of relying on
        // SwiftUI to infer palette captions from a rendered Button/Label tree.
        for item in toolbar.items {
            guard let label = nativeCommands[item.itemIdentifier.rawValue]?.title ?? Self.toolbarLabels[item.itemIdentifier.rawValue] else { continue }
            if item.label != label { item.label = label }
            if item.paletteLabel != label { item.paletteLabel = label }
        }
        layoutPersistence.update(toolbar: toolbar, binding: savedToolbarConfiguration)
        // Native customization owns its live item order until Done. Publishing
        // that order back into SwiftUI while dragging can reconstruct ForEach items.
        guard !toolbar.customizationPaletteIsRunning else { return }
        let identifiers = toolbar.items.map { $0.itemIdentifier.rawValue }
        guard identifiers != lastToolbarItemIdentifiers else { return }
        lastToolbarItemIdentifiers = identifiers
        DispatchQueue.main.async { [weak self] in self?.onToolbarItemsChange?(identifiers) }
    }

    private static let toolbarLabels: [String: String] = [
        "sidebar": "Sidebar", "layout": "Tab Layout", "pinSidebar": "Pin Sidebar",
        "back": "Back", "forward": "Forward", "reload": "Reload", "address": "Address and Search", "folders": "Folders",
        "downloads": "Downloads", "pins": "Essential Tabs", "settings": "Settings", "newTab": "New Tab",
    ]

    private static func applyPendingAddressFocus(in view: NSView) {
        if let field = view as? AddressField { field.applyPendingFocus() }
        else { view.subviews.forEach { applyPendingAddressFocus(in: $0) } }
    }

    private func layoutHorizontalTabs(in window: NSWindow, header: NSView) {
        guard let zoom = window.standardWindowButton(.zoomButton), let controlsWindow = zoom.window,
              let headerWindow = header.window else { return }
        let controlsFrame = headerWindow.convertFromScreen(controlsWindow.convertToScreen(zoom.convert(zoom.bounds, to: nil)))
        let leading = header.convert(controlsFrame, from: nil).maxX + BrowserChrome.edgeInset
        let row = tabReservation.convert(tabReservation.bounds, to: header)
        let frame = NSRect(x: leading, y: row.minY, width: max(0, header.bounds.width - leading), height: BrowserChrome.tabRowHeight)
        if tabContainer.frame != frame { tabContainer.frame = frame }
        if tabs.frame != tabContainer.bounds { tabs.frame = tabContainer.bounds }
    }

    private func restoreToolbarOrigin() {
        if let shiftedToolbar, shiftedToolbar.bounds.origin != originalToolbarOrigin {
            shiftedToolbar.setBoundsOrigin(originalToolbarOrigin)
        }
        shiftedToolbar = nil
    }
}

/// The strip clips and scrolls; its current width must never become the window's minimum width.
private final class TitlebarTabContainer: NSView {
    override var fittingSize: NSSize { NSSize(width: 0, height: BrowserChrome.tabRowHeight) }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: BrowserChrome.tabRowHeight) }
}


struct BrowserWindowReference {
    weak var window: NSWindow?
}

struct HorizontalTabAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalTabAnchorView { HorizontalTabAnchorView() }
    func updateNSView(_ view: HorizontalTabAnchorView, context: Context) {}
}

final class HorizontalTabAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TitlebarTabHostingView: NSHostingView<AnyView> {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
    override var fittingSize: NSSize { NSSize(width: 0, height: BrowserChrome.tabRowHeight) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(superview?.bounds.size ?? newSize)
    }
}

extension BrowserChrome {
    /// Laid over the window's glass in a private window, so it reads as different at a glance.
    static let privateTint = Color(red: 0.11, green: 0.08, blue: 0.20).opacity(0.72)
}

extension View {
    /// A private window's tabs, toolbar, and new tab page are always dark. Its pages keep the system appearance.
    @ViewBuilder
    func privateChrome(_ isPrivate: Bool) -> some View {
        if isPrivate {
            environment(\.colorScheme, .dark)
        } else {
            self
        }
    }
}
