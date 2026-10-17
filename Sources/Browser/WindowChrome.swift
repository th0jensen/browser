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

enum TabLayout: String, CaseIterable {
    case horizontal
    case vertical

    static let storageKey = "tabLayout"

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
    var onWindowChange: ((NSWindow?) -> Void)?

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WindowChromeView, context: Context) {
        view.onFullScreenChange = { if isFullScreen != $0 { isFullScreen = $0 } }
        view.onWindowChange = onWindowChange
        view.update(layout: tabLayout, tabs: horizontalTabs)
        DispatchQueue.main.async { [weak view] in view?.refresh() }
    }
}

final class WindowChromeView: NSView {
    var onFullScreenChange: ((Bool) -> Void)?
    var onWindowChange: ((NSWindow?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var tabLayout = TabLayout.horizontal
    private let tabAccessory = NSTitlebarAccessoryViewController()
    private let tabs = TitlebarTabHostingView(rootView: AnyView(EmptyView()))
    private let tabContainer = TitlebarTabContainer()
    private let tabReservation = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: BrowserChrome.tabRowHeight))
    private var hasInstalledTabs = false
    private weak var shiftedToolbar: NSView?
    private var originalToolbarOrigin = NSPoint.zero
    private var alignmentIsScheduled = false

    func refresh() { updateWindowState() }

    func update(layout: TabLayout, tabs content: AnyView) {
        tabLayout = layout
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
        restoreToolbarOrigin()
        onWindowChange?(window)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }

        let names: [Notification.Name] = [
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
                    if name == NSWindow.didUpdateNotification { self?.scheduleAlignment() }
                    else { self?.updateWindowState() }
                }
            }
        }
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type) else { continue }
            button.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                    object: button, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleAlignment() }
            })
        }
        DispatchQueue.main.async { [weak self] in self?.updateWindowState() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func updateWindowState() {
        guard let window else { return }
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.contains("address") }) {
            item.visibilityPriority = .high
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
        window.tabbingMode = .disallowed
        window.titlebarSeparatorStyle = .none
        let style: NSWindow.ToolbarStyle = tabLayout == .horizontal ? .expanded : .unifiedCompact
        if window.toolbarStyle != style { window.toolbarStyle = style }
        if tabLayout == .horizontal {
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
            self.centerTitlebarControls()
        }
    }

    /// Center native glass and hit regions together, including the page's top inset in the header.
    private func centerTitlebarControls() {
        guard let window else { restoreToolbarOrigin(); return }
        guard !window.styleMask.contains(.fullScreen) else { restoreToolbarOrigin(); return }
        guard
              let address = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.contains("address") })?.view,
              let close = window.standardWindowButton(.closeButton) else { return }
        // Find the toolbar's branch beside the window controls without depending on AppKit class names.
        var branch = address
        while let parent = branch.superview, !close.isDescendant(of: parent) { branch = parent }
        guard branch.superview != nil, branch !== close, branch !== window.contentView?.superview else { return }
        if shiftedToolbar !== branch {
            restoreToolbarOrigin()
            shiftedToolbar = branch
            originalToolbarOrigin = branch.bounds.origin
        }
        let offset = tabLayout == .vertical ? BrowserChrome.edgeInset / 2 : BrowserChrome.edgeInset
        let origin = NSPoint(x: originalToolbarOrigin.x,
                             y: originalToolbarOrigin.y + (branch.isFlipped ? -offset : offset))
        if branch.bounds.origin != origin { branch.setBoundsOrigin(origin) }

        // Horizontal traffic lights belong to the tab row; vertical lights share the navigation row.
        let center = tabLayout == .vertical
            ? (window.frame.height + window.contentLayoutRect.maxY - BrowserChrome.edgeInset) / 2
            : window.frame.height - BrowserChrome.tabRowHeight / 2
        let closeFrame = close.convert(close.bounds, to: nil)
        // Keep the same left edge when switching layouts, despite their different row heights.
        let leadingInset = BrowserChrome.windowControlsLeadingInset(controlHeight: closeFrame.height)
        let horizontalOffset = leadingInset - closeFrame.minX
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
            let target = parent.convert(NSPoint(x: 0, y: center), from: nil).y
            var frame = button.frame
            let current = button.convert(button.bounds, to: nil)
            frame.origin.x = parent.convert(NSPoint(x: current.minX + horizontalOffset, y: 0), from: nil).x
            frame.origin.y = target - frame.height / 2
            if button.frame != frame { button.frame = frame }
        }
        if tabLayout == .horizontal, let header = tabContainer.superview {
            layoutHorizontalTabs(in: window, header: header)
        }
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
