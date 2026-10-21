import AppKit
import SwiftUI

/// A phased trackpad scroll recognizer, not a mouse drag or a physical-input simulator.
/// Commit only on a deliberate, completed horizontal gesture. Momentum never selects a Space.
struct SidebarSpaceSwipeRecognizer {
    enum Phase { case began, changed, ended, cancelled, other }
    struct Sample {
        var phase: Phase
        var x: Double = 0
        var y: Double = 0
        var isPrecise = true
        var hasMomentum = false
    }
    struct Result: Equatable {
        var consumesEvent = false
        var offset: Int?
    }
    private enum Mode { case idle, pending, horizontal, rejected }
    private var mode = Mode.idle
    private var x = 0.0
    private var y = 0.0
    private var direction = 0
    private var claimed = false

    mutating func cancel() { self = Self() }

    mutating func reduce(_ sample: Sample, eligible: Bool = true) -> Result {
        guard eligible, sample.isPrecise, !sample.hasMomentum, sample.x.isFinite, sample.y.isFinite else {
            cancel()
            return Result()
        }
        if sample.phase == .cancelled {
            let result = Result(consumesEvent: claimed)
            cancel()
            return result
        }
        if sample.phase == .other {
            cancel()
            return Result()
        }
        if sample.phase == .began {
            cancel()
            mode = .pending
        }
        guard mode != .idle else { return Result() }
        x += sample.x
        y += sample.y
        guard x.isFinite, y.isFinite else { cancel(); return Result() }
        if mode == .pending, sample.phase != .ended {
            if abs(x) >= 8 && abs(x) >= abs(y) * 2 {
                mode = .horizontal
                claimed = true
                direction = x < 0 ? 1 : -1
            } else if abs(y) >= 8 {
                mode = .rejected
            }
        } else if mode == .horizontal, x * Double(-direction) <= 0 || abs(y) * 2 > abs(x) {
            // Do not reinterpret a reversal or a vertical turn as a second gesture.
            mode = .rejected
        }
        var result = Result(consumesEvent: claimed)
        if sample.phase == .ended {
            if mode == .horizontal, abs(x) >= 60 { result.offset = direction }
            cancel()
        }
        return result
    }

    /// Descriptor-only lookup. A foreign immediate neighbor is not skipped or loaded.
    static func destination(in spaces: [BrowserSpace], activeID: UUID, profileID: UUID, offset: Int) -> UUID? {
        guard offset == -1 || offset == 1,
              let index = spaces.firstIndex(where: { $0.id == activeID && $0.profileID == profileID }) else { return nil }
        let destination = index + offset
        guard spaces.indices.contains(destination), spaces[destination].profileID == profileID else { return nil }
        return spaces[destination].id
    }
}

/// Installed only behind the vertical sidebar's tab viewport, not its footer, title editor or tiles.
struct SidebarSpaceSwipeRegion: NSViewRepresentable {
    let browser: BrowserModel
    func makeNSView(context: Context) -> SidebarSpaceSwipeView {
        let view = SidebarSpaceSwipeView()
        view.identifier = NSUserInterfaceItemIdentifier("BrowserSpaceSwipeViewport")
        view.browser = browser
        return view
    }
    func updateNSView(_ view: SidebarSpaceSwipeView, context: Context) {
        view.browser = browser
        view.refresh()
    }
    static func dismantleNSView(_ view: SidebarSpaceSwipeView, coordinator: ()) { view.stop() }
}

/// The local monitor exists only while this passive region has a window. It never observes global input.
final class SidebarSpaceSwipeView: NSView {
    weak var browser: BrowserModel? {
        didSet { if browser !== oldValue { stop(); start() } }
    }
    private var monitor: Any?
    private var notifications: [NSObjectProtocol] = []
    private weak var ownerWindow: NSWindow?
    private weak var closedWindow: NSWindow?
    private var menuTrackingDepth = 0
    private var recognizer = SidebarSpaceSwipeRecognizer()
    private var origin: Origin?
    var isMonitoring: Bool { monitor != nil }

    private struct Origin {
        var spaceID: UUID
        var tabID: UUID?
        var order: [UUID]
    }

    isolated deinit { stop() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        closedWindow = nil
        start()
    }

    func refresh() {
        if monitor == nil { start() }
        if !allowsInteraction { cancel() }
    }

    private func start() {
        guard monitor == nil, let window, window !== closedWindow, let browser,
              !browser.isClosed, !browser.isPrivate, !browser.isExtensionWindow else { return }
        ownerWindow = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard event.type == .scrollWheel else { self.cancel(); return event }
            let phase: SidebarSpaceSwipeRecognizer.Phase
            if event.phase.contains(.cancelled) { phase = .cancelled }
            else if event.phase.contains(.ended) { phase = .ended }
            else if event.phase.contains(.began) { phase = .began }
            else if event.phase.contains(.changed) { phase = .changed }
            else { phase = .other }
            let sample = SidebarSpaceSwipeRecognizer.Sample(phase: phase,
                x: Double(event.scrollingDeltaX), y: Double(event.scrollingDeltaY),
                isPrecise: event.hasPreciseScrollingDeltas, hasMomentum: !event.momentumPhase.isEmpty)
            // AppKit already applies the user's natural-scroll direction to scrollingDeltaX/Y.
            return self.handle(sample, from: event.window, location: event.locationInWindow,
                modifiers: event.modifierFlags, applicationIsActive: NSApp.isActive,
                swipeTrackingEnabled: NSEvent.isSwipeTrackingFromScrollEventsEnabled) ? nil : event
        }
        observe(NSWindow.didResignKeyNotification, object: window)
        observe(NSWindow.willCloseNotification, object: window, stopOnNotification: true)
        observe(NSApplication.didResignActiveNotification, object: NSApp)
        observe(NSMenu.didBeginTrackingNotification, object: nil, menuTracking: true)
        observe(NSMenu.didEndTrackingNotification, object: nil, menuTracking: false)
    }

    private func observe(_ name: Notification.Name, object: Any?, menuTracking: Bool? = nil, stopOnNotification: Bool = false) {
        notifications.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if stopOnNotification {
                    self.closedWindow = self.ownerWindow
                    self.stop()
                    return
                }
                if let menuTracking {
                    self.menuTrackingDepth = menuTracking ? self.menuTrackingDepth + 1 : max(0, self.menuTrackingDepth - 1)
                }
                self.cancel()
            }
        })
    }

    private var allowsInteraction: Bool {
        guard let browser, !browser.isPrivate, !browser.isExtensionWindow, !browser.isClosed,
              browser.chromePreferences.tabLayout == .vertical,
              browser.folderEditorRequest == nil, browser.renamingSavedPageID == nil,
              browser.tabDrag.payload == nil, browser.chromeHover?.sidebarIsReordering != true,
              browser.chromeHover?.sidebarIsResizing != true, browser.chromeHover?.addressIsFocused != true,
              browser.chromeHover?.menuIsTracking != true, browser.chromeHover?.customizationIsRunning != true,
              browser.chromeHover?.folderEditorIsPresented != true, (browser.chromeHover?.presentationCount ?? 0) == 0,
              browser.addressFocusRequest == browser.consumedAddressFocusRequest,
              let window = ownerWindow, window === self.window, browser.window === window,
              browser.spaces.space(browser.activeSpaceID)?.profileID == browser.profileID,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              window.toolbar?.customizationPaletteIsRunning != true,
              !(window.firstResponder is NSText), !(window.firstResponder is NSTextField),
              menuTrackingDepth == 0 else { return false }
        return true
    }

    /// Structured input permits ownership/layout tests without synthesizing physical trackpad events.
    @discardableResult
    func handle(_ sample: SidebarSpaceSwipeRecognizer.Sample, from source: NSWindow?, location: NSPoint,
                modifiers: NSEvent.ModifierFlags = [], applicationIsActive: Bool, swipeTrackingEnabled: Bool) -> Bool {
        guard monitor != nil, let window = ownerWindow, source === window, window.isKeyWindow,
              applicationIsActive, swipeTrackingEnabled, allowsInteraction,
              modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              !isHiddenOrHasHiddenAncestor, bounds.contains(convert(location, from: nil)),
              visibleRect.contains(convert(location, from: nil)),
              !controlAtPoint(location, in: window), let browser else {
            cancel()
            return false
        }
        if sample.phase == .began {
            origin = Origin(spaceID: browser.activeSpaceID, tabID: browser.activeTabID, order: browser.spaces.spaces.map(\.id))
        }
        guard let origin, origin.spaceID == browser.activeSpaceID, origin.tabID == browser.activeTabID,
              origin.order == browser.spaces.spaces.map(\.id) else { cancel(); return false }
        let result = recognizer.reduce(sample)
        if sample.phase == .ended || sample.phase == .cancelled || sample.phase == .other || sample.hasMomentum || !sample.isPrecise {
            self.origin = nil
        }
        if let offset = result.offset,
           let destination = SidebarSpaceSwipeRecognizer.destination(in: browser.spaces.spaces,
                activeID: origin.spaceID, profileID: browser.profileID, offset: offset) {
            // No asynchronous completion can replay after deactivation, cancellation or another selection.
            browser.selectSpace(destination)
        }
        return result.consumesEvent
    }

    private func controlAtPoint(_ point: NSPoint, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return true }
        var target = content.hitTest(content.convert(point, from: nil))
        while let view = target {
            if view is NSControl || view is NSText { return true }
            target = view.superview
        }
        return false
    }

    func cancel() { recognizer.cancel(); origin = nil }

    func stop() {
        cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications = []
        ownerWindow = nil
        menuTrackingDepth = 0
    }
}
