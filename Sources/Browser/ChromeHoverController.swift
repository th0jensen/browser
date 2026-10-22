import AppKit
import Observation
import SwiftUI

enum CompactToolbar {
    static let storageKey = "compactToolbar"
}

/// Window-scoped, independent hover regions. Moving the pointer never starts another hide timer.
@MainActor @Observable
final class ChromeHoverController {
    var toolbarIsRevealed = false {
        didSet {
            if toolbarIsRevealed != oldValue {
                nativeToolbarPresenter?.setToolbarRevealed(toolbarIsRevealed)
            }
        }
    }
    var sidebarIsRevealed = false
    var compactToolbar = false {
        didSet {
            if compactToolbar != oldValue {
                toolbarIsRevealed = false; cancelToolbarHide()
            }
        }
    }
    var autoHideSidebar = false {
        didSet {
            if autoHideSidebar != oldValue {
                resetSidebar()
            }
        }
    }
    var verticalTabs = false {
        didSet {
            if verticalTabs != oldValue {
                resetSidebar()
            }
        }
    }
    var sidebarWidth: CGFloat = BrowserChrome.sidebarWidth
    var headerHeight: CGFloat = 40
    var addressIsFocused = false {
        didSet {
            guard addressIsFocused != oldValue else { return }
            if addressIsFocused { addressFocusRequested() }
            else if navigationAwaitingSuccess == nil { dismissToolbarAfterInteraction() }
        }
    }
    var menuIsTracking = false {
        didSet { if menuIsTracking { stop() } else { pointerMoved(to: lastPointer) } }
    }
    var customizationIsRunning = false {
        didSet { if customizationIsRunning { revealToolbar() } else { pointerMoved(to: lastPointer) } }
    }
    var sidebarIsResizing = false {
        didSet { if sidebarIsResizing { cancelSidebarHide() } else { pointerMoved(to: lastPointer) } }
    }
    var sidebarIsReordering = false {
        didSet { if sidebarIsReordering { cancelSidebarHide() } else { reevaluatePointer() } }
    }
    @ObservationIgnored private var lastPointer: CGPoint?
    @ObservationIgnored var sidebarBoundsProvider: (() -> CGRect?)?
    @ObservationIgnored private var navigationAwaitingSuccess: UUID?
    @ObservationIgnored private var toolbarNeedsEdgeExit = false
    @ObservationIgnored private var addressKeepsSidebarRevealed = false
    @ObservationIgnored weak var nativeToolbarPresenter: WindowChromeView?
    @ObservationIgnored var canHideToolbar: @MainActor () -> Bool = { true }
    var folderEditorIsPresented = false {
        didSet {
            if folderEditorIsPresented { cancelToolbarHide(); cancelSidebarHide() }
            else if oldValue { reevaluatePointer() }
        }
    }
    private(set) var presentationCount = 0
    private(set) var sidebarPresentationCount = 0
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var sidebarOpenedFromToolbar = false
    @ObservationIgnored private var toolbarHideTask: Task<Void, Never>?
    @ObservationIgnored private var sidebarHideTask: Task<Void, Never>?
    static let hideDelay: Duration = .milliseconds(120)

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    func pointerMoved(to point: CGPoint?) {
        lastPointer = point
        guard let point else {
            toolbarNeedsEdgeExit = false
            scheduleToolbarHide(); scheduleSidebarHide(); return
        }
        let inHeader = point.y >= 0 && point.y <= headerHeight + BrowserChrome.edgeInset
        if !inHeader { toolbarNeedsEdgeExit = false }
        let sidebarRegion = sidebarBoundsProvider?() ?? CGRect(x: BrowserChrome.edgeInset, y: BrowserChrome.edgeInset,
                                                     width: sidebarWidth, height: .greatestFiniteMagnitude)
        let insideFloatingSidebar = sidebarIsRevealed && sidebarRegion.contains(point)
        if inHeader && !insideFloatingSidebar {
            if compactToolbar, !toolbarNeedsEdgeExit, point.y <= BrowserChrome.edgeInset { revealToolbar() }
            if toolbarIsRevealed { cancelToolbarHide() }
            // The toolbar edge never triggers the sidebar, including at the top-left corner.
            scheduleSidebarHide()
            return
        }
        scheduleToolbarHide()
        guard verticalTabs, autoHideSidebar, !sidebarIsResizing else { return }
        sidebarOpenedFromToolbar = false
        if point.x <= 10 {
            revealSidebar()
        } else if insideFloatingSidebar {
            cancelSidebarHide()
        } else {
            scheduleSidebarHide()
        }
    }

    func revealToolbar() { cancelToolbarHide(); if compactToolbar { toolbarIsRevealed = true } }
    /// Address editing can keep an already visible sidebar open, but never opens
    /// a hidden sidebar or couples the two hover reveal targets.
    func addressFocusRequested() {
        if verticalTabs && autoHideSidebar && sidebarIsRevealed {
            addressKeepsSidebarRevealed = true
            cancelSidebarHide()
        }
        revealToolbar()
    }
    /// Submission holds the editor's reveal until the main document first paints content.
    func addressNavigationSubmitted(in tabID: UUID) {
        navigationAwaitingSuccess = tabID
        revealToolbar()
    }
    func navigationSucceeded(in tabID: UUID) {
        if navigationAwaitingSuccess == tabID { navigationAwaitingSuccess = nil }
        guard navigationAwaitingSuccess == nil, !addressIsFocused else { return }
        dismissToolbarAfterInteraction()
    }
    func navigationFailed(in tabID: UUID) {
        if navigationAwaitingSuccess == tabID { navigationAwaitingSuccess = nil }
        if !addressIsFocused && navigationAwaitingSuccess == nil {
            addressKeepsSidebarRevealed = false
            reevaluatePointer()
        }
    }
    func activeTabChanged() { navigationAwaitingSuccess = nil }
    /// An explicit shortcut dismissal ends editing and its temporary reveal in one action.
    func dismissAddressFocus() {
        navigationAwaitingSuccess = nil
        addressIsFocused = false
        dismissToolbarAfterInteraction()
    }
    func dismissToolbarAfterInteraction() {
        guard !addressIsFocused, navigationAwaitingSuccess == nil,
              !menuIsTracking, !customizationIsRunning, !folderEditorIsPresented, presentationCount == 0 else { return }
        addressKeepsSidebarRevealed = false
        if compactToolbar {
            cancelToolbarHide()
            toolbarNeedsEdgeExit = true
            toolbarIsRevealed = false
        }
        reevaluatePointer()
    }
    func revealSidebar() { cancelSidebarHide(); sidebarIsRevealed = true }
    func toggleSidebarFromToolbar() {
        if sidebarIsRevealed { resetSidebar() }
        else { sidebarOpenedFromToolbar = true; revealSidebar() }
    }
    func cancelToolbarHide() { toolbarHideTask?.cancel(); toolbarHideTask = nil }
    func cancelSidebarHide() { sidebarHideTask?.cancel(); sidebarHideTask = nil }
    func resetSidebar() {
        cancelSidebarHide()
        sidebarIsRevealed = false
        sidebarOpenedFromToolbar = false
        addressKeepsSidebarRevealed = false
    }
    func stop() { cancelToolbarHide(); cancelSidebarHide() }
    func beginPresentation() { presentationCount += 1; revealToolbar(); cancelToolbarHide() }
    func endPresentation() {
        guard presentationCount > 0 else { return }
        presentationCount -= 1
        if presentationCount == 0 { reevaluatePointer() }
    }

    func beginSidebarPresentation() { sidebarPresentationCount += 1; revealSidebar() }
    func endSidebarPresentation() {
        guard sidebarPresentationCount > 0 else { return }
        sidebarPresentationCount -= 1
        if sidebarPresentationCount == 0 { reevaluatePointer() }
    }

    func scheduleToolbarHide() {
        guard compactToolbar, toolbarIsRevealed, toolbarHideTask == nil,
              !addressIsFocused, navigationAwaitingSuccess == nil, !menuIsTracking, !customizationIsRunning, !folderEditorIsPresented, presentationCount == 0, canHideToolbar() else { return }
        toolbarHideTask = Task { @MainActor [weak self, sleep] in
            do { try await sleep(Self.hideDelay) } catch { return }
            guard let self else { return }
            toolbarHideTask = nil
            guard !addressIsFocused, navigationAwaitingSuccess == nil, !menuIsTracking, !customizationIsRunning, !folderEditorIsPresented, presentationCount == 0, canHideToolbar() else { return }
            toolbarIsRevealed = false
        }
    }

    func reevaluatePointer() { pointerMoved(to: lastPointer) }

    func scheduleSidebarHide() {
        guard sidebarIsRevealed, sidebarHideTask == nil, !sidebarOpenedFromToolbar, !addressKeepsSidebarRevealed,
              !menuIsTracking, !folderEditorIsPresented, !sidebarIsResizing, !sidebarIsReordering,
              sidebarPresentationCount == 0 else { return }
        sidebarHideTask = Task { @MainActor [weak self, sleep] in
            do { try await sleep(Self.hideDelay) } catch { return }
            guard let self else { return }
            sidebarHideTask = nil
            guard !menuIsTracking, !folderEditorIsPresented, !sidebarIsResizing, !sidebarIsReordering,
                  !sidebarOpenedFromToolbar, !addressKeepsSidebarRevealed, sidebarPresentationCount == 0 else { return }
            sidebarIsRevealed = false
        }
    }
}

/// Observes native pointer events even when WKWebView or the titlebar owns hit testing.
final class ChromePointerTracker: NSView {
    var onMove: ((CGPoint?) -> Void)?
    var onReevaluate: (() -> Void)?
    private var monitor: Any?
    private var exitArea: NSTrackingArea?
    private weak var trackedContent: NSView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window, let content = window.contentView else { return }
        window.acceptsMouseMovedEvents = true
        trackedContent = content
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        content.addTrackingArea(area)
        exitArea = area
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyUp]) { [weak self, weak window] event in
            guard let self, let window, let source = event.window else { return event }
            let isToolbarWindow = window.toolbar?.items.contains { $0.view?.window === source } == true
            guard source === window || isToolbarWindow else { return event }
            if event.type == .keyUp { self.onReevaluate?(); return event }
            let point = window.convertPoint(fromScreen: source.convertPoint(toScreen: event.locationInWindow))
            self.onMove?(CGPoint(x: point.x, y: window.frame.height - point.y))
            return event
        }
    }

    override func mouseExited(with event: NSEvent) { onMove?(nil) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let exitArea { trackedContent?.removeTrackingArea(exitArea) }; exitArea = nil
    }
}

struct ChromePointerObserver: NSViewRepresentable {
    let controller: ChromeHoverController
    func makeNSView(context: Context) -> ChromePointerTracker { ChromePointerTracker() }
    func updateNSView(_ view: ChromePointerTracker, context: Context) {
        view.onMove = { controller.pointerMoved(to: $0) }
        view.onReevaluate = { controller.reevaluatePointer() }
    }
    static func dismantleNSView(_ view: ChromePointerTracker, coordinator: ()) { view.stop() }
}
