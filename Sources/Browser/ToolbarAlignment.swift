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
    private weak var sizedHost: NSView?
    private weak var minimumWidth: NSLayoutConstraint?
    private weak var maximumWidth: NSLayoutConstraint?

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
        guard !updateIsScheduled, browserWindow?.toolbar?.isVisible == true else { return }
        updateIsScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateIsScheduled = false
            guard let window = browserWindow,
                  let item = window.toolbar?.items.first(where: { item in
                      item.itemIdentifier.rawValue == "address" && item.view.map { isDescendant(of: $0) } == true
                  }), let host = item.view,
                  window.toolbar?.visibleItems?.contains(item) == true else { return }
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
            minimumWidth?.constant = 160
        }
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
