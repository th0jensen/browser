import AppKit
import SwiftUI

/// Allows the native address item to expand and compress without increasing the window minimum size.
struct ToolbarAlignment: NSViewRepresentable {
    let browserWindow: NSWindow?

    func makeNSView(context: Context) -> ToolbarAlignmentView { ToolbarAlignmentView() }
    func updateNSView(_ view: ToolbarAlignmentView, context: Context) {
        if view.browserWindow !== browserWindow {
            view.browserWindow = browserWindow
            view.observeLayout()
        }
        view.scheduleUpdate()
    }
}

final class ToolbarAlignmentView: NSView {
    weak var browserWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var updateIsScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeLayout()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeLayout()
    }

    func observeLayout() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window = browserWindow else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.didUpdateNotification, NSToolbar.willAddItemNotification, NSToolbar.didRemoveItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: (name == NSWindow.didResizeNotification || name == NSWindow.didUpdateNotification) ? window : nil,
                                                                     queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate() }
            })
        }
        var ancestor: NSView? = self
        while let view = ancestor {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                })
            }
            ancestor = view.superview
        }
        scheduleUpdate()
    }

    override func layout() { super.layout(); scheduleUpdate() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func scheduleUpdate() {
        // Hidden chrome still needs its sizing constraints prepared when the
        // sidebar configuration or window size changes, before the next reveal.
        guard !updateIsScheduled, browserWindow?.toolbar != nil else { return }
        updateIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateIsScheduled = false
            guard let window = browserWindow else { return }
            ToolbarAddressAllocation.update(in: window)
        }
    }
}


/// The current native toolbar item owns its allocation. SwiftUI may move or replace the background marker,
/// so both its layout notifications and the window chrome update the same allocator for this window.
@MainActor
final class ToolbarAddressAllocation {
    private static let allocations = NSMapTable<NSWindow, ToolbarAddressAllocation>.weakToStrongObjects()
    private weak var sizedHost: NSView?
    private weak var minimumWidth: NSLayoutConstraint?
    private weak var maximumWidth: NSLayoutConstraint?

    static func update(in window: NSWindow) {
        let allocation = allocations.object(forKey: window) ?? ToolbarAddressAllocation()
        allocations.setObject(allocation, forKey: window)
        allocation.apply(in: window)
    }

    private func apply(in window: NSWindow) {
        guard let toolbar = window.toolbar,
              let item = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "address" }),
              let host = item.view,
              (!toolbar.isVisible || (host.window === window && toolbar.visibleItems?.contains(item) == true)) else { return }
        if sizedHost !== host {
            [minimumWidth, maximumWidth].compactMap { $0 }.forEach { $0.isActive = false }
            host.translatesAutoresizingMaskIntoConstraints = false
            host.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
            host.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let minimum = host.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
            let maximum = host.widthAnchor.constraint(lessThanOrEqualToConstant: 100_000)
            NSLayoutConstraint.activate([minimum, maximum])
            minimumWidth = minimum
            maximumWidth = maximum
            sizedHost = host
        }
        let items = toolbar.items
        let flexibleCount = items.filter { $0.itemIdentifier == .flexibleSpace }.count
        let maximum: CGFloat
        if flexibleCount > 0 {
            let fixedWidth = items.filter { $0 !== item && $0.itemIdentifier != .flexibleSpace }.reduce(CGFloat.zero) { width, item in
                width + (item.itemIdentifier == .space ? 20 : (item.view?.fittingSize.width ?? 24))
            }
            // A leading flexible item's allocated position cannot feed its own next allocation.
            let leading: CGFloat
            if window.toolbarStyle != .expanded, let zoom = window.standardWindowButton(.zoomButton) {
                leading = zoom.convert(zoom.bounds, to: nil).maxX + BrowserChrome.edgeInset
            } else { leading = BrowserChrome.edgeInset }
            let gutters = CGFloat(max(0, items.count - 1)) * BrowserChrome.edgeInset
            let available = max(160, window.frame.width - leading - fixedWidth - gutters - BrowserChrome.edgeInset)
            maximum = max(160, available / CGFloat(flexibleCount + 1))
        } else {
            maximum = 100_000
        }
        if maximumWidth?.constant != maximum { maximumWidth?.constant = maximum }
    }
}

/// Marks the rendered glass field for native geometry verification.
struct ToolbarFieldAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarFieldAnchorView { ToolbarFieldAnchorView() }
    func updateNSView(_ view: ToolbarFieldAnchorView, context: Context) {}
}

final class ToolbarFieldAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
