import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class SidebarSpaceSwipeTests: XCTestCase {
    private typealias Sample = SidebarSpaceSwipeRecognizer.Sample

    func testOneHorizontalGestureCommitsOnlyAtEndAndNeverReplays() {
        var reducer = SidebarSpaceSwipeRecognizer()
        XCTAssertEqual(reducer.reduce(Sample(phase: .began, x: -12)), .init(consumesEvent: true))
        for _ in 0..<10 {
            XCTAssertNil(reducer.reduce(Sample(phase: .changed, x: -20)).offset)
        }
        XCTAssertEqual(reducer.reduce(Sample(phase: .ended)), .init(consumesEvent: true, offset: 1))
        XCTAssertNil(reducer.reduce(Sample(phase: .ended)).offset)
        XCTAssertNil(reducer.reduce(Sample(phase: .changed, x: -100)).offset)
        XCTAssertNil(reducer.reduce(Sample(phase: .other, x: -100, hasMomentum: true)).offset)
    }

    func testBothDirectionsFollowNativeScrollingDeltaSign() {
        for (delta, offset) in [(-80.0, 1), (80.0, -1)] {
            var reducer = SidebarSpaceSwipeRecognizer()
            _ = reducer.reduce(Sample(phase: .began, x: delta))
            XCTAssertEqual(reducer.reduce(Sample(phase: .ended)).offset, offset)
        }
    }

    func testVerticalScrollingPassesThroughAndCannotTurnIntoASpaceSwipe() {
        var reducer = SidebarSpaceSwipeRecognizer()
        XCTAssertFalse(reducer.reduce(Sample(phase: .began, x: 2, y: 12)).consumesEvent)
        XCTAssertFalse(reducer.reduce(Sample(phase: .changed, x: -100, y: 1)).consumesEvent)
        XCTAssertEqual(reducer.reduce(Sample(phase: .ended)), .init())
    }

    func testDiagonalShortAndReversingGesturesDoNotCommit() {
        let sequences: [[Sample]] = [
            [.init(phase: .began, x: -20, y: 15), .init(phase: .changed, x: -80)],
            [.init(phase: .began, x: -10), .init(phase: .changed, x: -20)],
            [.init(phase: .began, x: -80), .init(phase: .changed, x: 100)],
            [.init(phase: .began, x: -80), .init(phase: .changed, y: 100)],
            [.init(phase: .began), .init(phase: .ended, x: -100)],
        ]
        for samples in sequences {
            var reducer = SidebarSpaceSwipeRecognizer()
            for sample in samples { XCTAssertNil(reducer.reduce(sample).offset) }
            XCTAssertNil(reducer.reduce(Sample(phase: .ended)).offset)
        }
    }

    func testCancellationMomentumAndLossOfEligibilityInvalidateTheWholeGesture() {
        let interruptions: [Sample] = [
            .init(phase: .cancelled), .init(phase: .other),
            .init(phase: .changed, x: -100, hasMomentum: true),
            .init(phase: .changed, x: -100, isPrecise: false),
            .init(phase: .changed, x: .nan), .init(phase: .changed, x: .infinity),
        ]
        for interruption in interruptions {
            var reducer = SidebarSpaceSwipeRecognizer()
            _ = reducer.reduce(Sample(phase: .began, x: -100))
            XCTAssertNil(reducer.reduce(interruption).offset)
            XCTAssertNil(reducer.reduce(Sample(phase: .changed, x: -100)).offset)
            XCTAssertNil(reducer.reduce(Sample(phase: .ended)).offset)
        }
        var reducer = SidebarSpaceSwipeRecognizer()
        _ = reducer.reduce(Sample(phase: .began, x: -100))
        _ = reducer.reduce(Sample(phase: .changed), eligible: false)
        XCTAssertNil(reducer.reduce(Sample(phase: .ended)).offset)
    }

    func testLegacyWheelUnbegunAndMomentumEventsCannotStartAGesture() {
        for sample in [Sample(phase: .other, x: -100), .init(phase: .changed, x: -100),
                       .init(phase: .began, x: -100, isPrecise: false),
                       .init(phase: .began, x: -100, hasMomentum: true)] {
            var reducer = SidebarSpaceSwipeRecognizer()
            XCTAssertEqual(reducer.reduce(sample), .init())
            XCTAssertEqual(reducer.reduce(Sample(phase: .ended)), .init())
        }
    }

    func testDescriptorDestinationDoesNotWrapSkipForeignOwnersOrAcceptUnknownIDs() {
        let profile = BrowserProfile.defaultID
        let a = BrowserSpace(id: UUID(), title: "A", profileID: profile)
        let b = BrowserSpace(id: UUID(), title: "B", profileID: profile)
        let foreign = BrowserSpace(id: UUID(), title: "Foreign", profileID: UUID())
        let items = [a, b, foreign, BrowserSpace(id: UUID(), title: "Last", profileID: profile)]
        XCTAssertEqual(SidebarSpaceSwipeRecognizer.destination(in: items, activeID: a.id, profileID: profile, offset: 1), b.id)
        XCTAssertNil(SidebarSpaceSwipeRecognizer.destination(in: items, activeID: a.id, profileID: profile, offset: -1))
        XCTAssertNil(SidebarSpaceSwipeRecognizer.destination(in: items, activeID: b.id, profileID: profile, offset: 1))
        XCTAssertNil(SidebarSpaceSwipeRecognizer.destination(in: items, activeID: UUID(), profileID: profile, offset: 1))
        XCTAssertNil(SidebarSpaceSwipeRecognizer.destination(in: items, activeID: foreign.id, profileID: profile, offset: -1))
        XCTAssertNil(SidebarSpaceSwipeRecognizer.destination(in: items, activeID: a.id, profileID: profile, offset: 2))
        XCTAssertNil(SidebarSpaceSwipeRecognizer.destination(in: [], activeID: a.id, profileID: profile, offset: 1))
    }

    func testNativeRegionSelectsOnlyItsOwningWindowAndKeepsViewsLazy() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.close(); second.close() }
        XCTAssertTrue(first.region.isMonitoring)
        let before = first.browser.allTabs.map(\.id)
        XCTAssertTrue(first.send(.init(phase: .began, x: -100)))
        XCTAssertEqual(first.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        XCTAssertEqual(first.browser.allTabs.map(\.id), before, "Eligibility must not materialize inactive tabs")
        XCTAssertTrue(first.send(.init(phase: .ended)))
        XCTAssertEqual(first.browser.activeSpaceID, first.browser.spaces.spaces[1].id)
        XCTAssertEqual(second.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        XCTAssertTrue((first.browser.allTabs + second.browser.allTabs).allSatisfy { $0.webView == nil })
        let selected = first.browser.activeSpaceID
        first.send(.init(phase: .ended))
        first.send(.init(phase: .changed, x: -100))
        XCTAssertEqual(first.browser.activeSpaceID, selected)
    }

    func testPointerMustStayInViewportNotFooterPageHeaderOrNativeControls() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for point in [NSPoint(x: 100, y: 20), NSPoint(x: 250, y: 200), NSPoint(x: 100, y: 490)] {
            XCTAssertFalse(fixture.send(.init(phase: .began, x: -100), point: point))
            fixture.send(.init(phase: .ended), point: point)
            XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        }
        let control = NSButton(frame: .init(x: 50, y: 200, width: 80, height: 28))
        fixture.window.contentView?.addSubview(control)
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100), point: .init(x: 60, y: 210)))
        fixture.send(.init(phase: .ended), point: .init(x: 60, y: 210))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        control.removeFromSuperview()
        fixture.send(.init(phase: .began, x: -100))
        fixture.send(.init(phase: .ended), point: .init(x: 100, y: 20))
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID, "Leaving the viewport cancels, not defers, selection")
    }

    func testNativeScopeRequiresPreferenceActiveKeyWindowAndNoModifiers() throws {
        let fixture = try Fixture()
        let other = try Fixture()
        defer { fixture.close(); other.close() }
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100), swipeEnabled: false))
        fixture.send(.init(phase: .ended))
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100), active: false))
        fixture.send(.init(phase: .ended))
        fixture.window.pretendsKey = false
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.window.pretendsKey = true
        fixture.send(.init(phase: .ended))
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100), source: other.window))
        fixture.send(.init(phase: .ended))
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100), modifiers: .option))
        fixture.send(.init(phase: .ended))
        fixture.browser.window = other.window
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.browser.window = fixture.window
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
    }

    func testNativeTextEditingSheetRenameAndDragBlockAndCancelSelection() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let editor = NSTextView(frame: .init(x: 230, y: 100, width: 60, height: 40))
        fixture.window.contentView?.addSubview(editor)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.send(.init(phase: .ended))
        fixture.window.makeFirstResponder(nil)
        editor.removeFromSuperview()
        let sheet = NSWindow(contentRect: .zero, styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { sheet.close() }
        fixture.window.testSheet = sheet
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.window.testSheet = nil
        fixture.send(.init(phase: .ended))
        fixture.send(.init(phase: .began, x: -100))
        fixture.browser.renamingSavedPageID = UUID()
        XCTAssertFalse(fixture.send(.init(phase: .changed)))
        fixture.browser.renamingSavedPageID = nil
        fixture.send(.init(phase: .ended))
        fixture.browser.folderEditorRequest = FolderEditorRequest()
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.browser.folderEditorRequest = nil
        fixture.send(.init(phase: .ended))
        fixture.browser.tabDrag.begin("test-tab", frame: .zero, axis: .vertical, crossing: { _, _ in }, completion: { _ in })
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.browser.tabDrag.finish(cancelled: true)
        fixture.browser.tabDrag.endGesture()
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
    }

    func testNativeNotificationsAndOwnershipChangesCancelWithoutReplay() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification, NSMenu.didBeginTrackingNotification] {
            fixture.send(.init(phase: .began, x: -100))
            let object: Any = name == NSWindow.didResignKeyNotification ? fixture.window : name == NSApplication.didResignActiveNotification ? NSApp! : NSMenu()
            NotificationCenter.default.post(name: name, object: object)
            if name == NSMenu.didBeginTrackingNotification { NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: object) }
            fixture.send(.init(phase: .ended))
            XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        }
        fixture.send(.init(phase: .began, x: -100))
        fixture.browser.addTab(focusAddress: false)
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        fixture.send(.init(phase: .began, x: -100))
        _ = try fixture.browser.spaces.createSpace(title: "Later")
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        fixture.send(.init(phase: .began, x: -100))
        fixture.browser.selectSpace(at: 1)
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, fixture.browser.spaces.spaces[1].id)
    }

    func testNestedNativeMenusBlockUntilAllTrackingHasEnded() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let parent = NSMenu()
        let child = NSMenu()
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: parent)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: child)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: child)
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: parent)
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        XCTAssertTrue(fixture.send(.init(phase: .began, x: -100)))
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, fixture.browser.spaces.spaces[1].id)
    }

    func testClosingDetachingAndDismantlingRemoveLocalMonitorAndCancel() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.send(.init(phase: .began, x: -100))
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: fixture.window)
        XCTAssertFalse(fixture.region.isMonitoring)
        fixture.region.refresh()
        XCTAssertFalse(fixture.region.isMonitoring, "A closed window must not reinstall on a late SwiftUI update")
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        fixture.region.removeFromSuperview()
        fixture.window.contentView?.addSubview(fixture.region)
        XCTAssertTrue(fixture.region.isMonitoring)
        fixture.send(.init(phase: .began, x: -100))
        fixture.region.removeFromSuperview()
        XCTAssertFalse(fixture.region.isMonitoring)
        fixture.window.contentView?.addSubview(fixture.region)
        fixture.send(.init(phase: .ended))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        SidebarSpaceSwipeRegion.dismantleNSView(fixture.region, coordinator: ())
        XCTAssertFalse(fixture.region.isMonitoring)
    }

    func testHiddenHorizontalPrivateExtensionAndClosedContextsNeverSelect() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.region.isHidden = true
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.region.isHidden = false
        fixture.send(.init(phase: .ended))
        fixture.browser.chromePreferences.tabLayout = .horizontal
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.browser.chromePreferences.tabLayout = .vertical
        fixture.send(.init(phase: .ended))
        fixture.browser.isExtensionWindow = true
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        fixture.browser.isExtensionWindow = false
        fixture.send(.init(phase: .ended))
        fixture.browser.windowDidClose()
        XCTAssertFalse(fixture.send(.init(phase: .began, x: -100)))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        let privateBrowser = BrowserModel(isPrivate: true)
        let region = SidebarSpaceSwipeView()
        region.browser = privateBrowser
        fixture.window.contentView?.addSubview(region)
        XCTAssertFalse(region.isMonitoring)
        region.removeFromSuperview()
    }

    func testActualSidebarLayoutInstallsRegionAbovePersistentFooter() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.region.removeFromSuperview()
        let host = NSHostingView(rootView: TabStrip(browser: fixture.browser, layout: .vertical,
            isFullScreen: false, hoverCardTabID: .constant(nil)).defaultAppStorage(fixture.defaults))
        host.frame = .init(x: 0, y: 0, width: 220, height: 500)
        fixture.window.contentView = host
        func region(in view: NSView) -> SidebarSpaceSwipeView? {
            if let region = view as? SidebarSpaceSwipeView { return region }
            return view.subviews.lazy.compactMap { region(in: $0) }.first
        }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { region(in: host)?.bounds.height ?? 0 > 0 }
        let viewport = try XCTUnwrap(region(in: host))
        XCTAssertTrue(viewport.isMonitoring)
        let frame = viewport.convert(viewport.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(frame.minY, 36, "The persistent footer must not belong to the swipe viewport")
        XCTAssertLessThan(frame.maxY, 500, "Tiles/title controls are outside the swipe viewport")
        XCTAssertFalse(viewport.handle(.init(phase: .began, x: -100), from: fixture.window,
            location: .init(x: 110, y: 10), applicationIsActive: true, swipeTrackingEnabled: true))
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
    }
}

/// These tests supply structured phase/ownership contexts. They do not synthesize or verify trackpad hardware.
@MainActor
private final class Fixture {
    let suite = "SidebarSpaceSwipe-\(UUID())"
    let defaults: UserDefaults
    let browser: BrowserModel
    let window: SwipeTestWindow
    let region = SidebarSpaceSwipeView(frame: .init(x: 0, y: 80, width: 220, height: 400))

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let chrome = WindowChromePreferences(defaults: defaults)
        chrome.tabLayout = .vertical
        let spaces = BrowserSpaceStore(directory: .temporaryDirectory, enabled: false)
        _ = try spaces.createSpace(title: "Work")
        _ = try spaces.createSpace(title: "Personal")
        browser = BrowserModel(chromePreferences: chrome, spaces: spaces)
        browser.consumedAddressFocusRequest = browser.addressFocusRequest
        window = SwipeTestWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        window.contentView = NSView(frame: .init(x: 0, y: 0, width: 300, height: 500))
        region.browser = browser
        window.contentView?.addSubview(region)
    }

    @discardableResult
    func send(_ sample: SidebarSpaceSwipeRecognizer.Sample, point: NSPoint = .init(x: 100, y: 200),
              source: NSWindow? = nil, modifiers: NSEvent.ModifierFlags = [], active: Bool = true, swipeEnabled: Bool = true) -> Bool {
        region.handle(sample, from: source ?? window, location: point, modifiers: modifiers,
                      applicationIsActive: active, swipeTrackingEnabled: swipeEnabled)
    }

    func close() {
        region.stop()
        window.testSheet = nil
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class SwipeTestWindow: NSWindow {
    var pretendsKey = true
    var testSheet: NSWindow?
    override var isKeyWindow: Bool { pretendsKey }
    override var attachedSheet: NSWindow? { testSheet ?? super.attachedSheet }
    override func makeKeyAndOrderFront(_ sender: Any?) { }
}
