import AppKit
import XCTest
@testable import Browser

@MainActor
final class ChromePresentationTests: XCTestCase {
    func testRepeatedUpdatesAndDismissalsBalanceOneHold() {
        let controller = PresentationCounter()
        let hold = ChromePresentationHold()
        hold.setPresented(true, controller: controller)
        hold.setPresented(true, controller: controller)
        XCTAssertEqual(controller.begins, 1)
        hold.setPresented(false, controller: controller)
        hold.end()
        XCTAssertEqual(controller.ends, 1)
    }

    func testChangingWindowTransfersHoldAndTeardownReleasesIt() {
        let first = PresentationCounter()
        let second = PresentationCounter()
        var hold: ChromePresentationHold? = ChromePresentationHold()
        hold?.setPresented(true, controller: first)
        hold?.setPresented(true, controller: second)
        XCTAssertEqual(first.ends, 1)
        XCTAssertEqual(second.begins, 1)
        hold = nil
        XCTAssertEqual(second.ends, 1)
    }

    func testConcurrentPresentationsReleaseIndependently() {
        let controller = PresentationCounter()
        let first = ChromePresentationHold()
        let second = ChromePresentationHold()
        first.setPresented(true, controller: controller)
        second.setPresented(true, controller: controller)
        first.end()
        XCTAssertEqual(controller.begins - controller.ends, 1)
        second.end()
        XCTAssertEqual(controller.begins, controller.ends)
    }

    func testMovingAHoldBetweenToolbarAndSidebarBalancesBothRegions() {
        let controller = PresentationCounter()
        let hold = ChromePresentationHold()
        hold.setPresented(true, controller: controller)
        hold.setPresented(true, controller: controller, region: .sidebar)
        hold.setPresented(true, controller: controller, region: .sidebar)
        XCTAssertEqual(controller.begins, 1)
        XCTAssertEqual(controller.ends, 1)
        XCTAssertEqual(controller.sidebarBegins, 1)
        hold.end()
        XCTAssertEqual(controller.sidebarEnds, 1)
    }

    func testSidebarHoldsCancelPendingHideWithoutRevealingToolbarAndResumeAfterLastRelease() async throws {
        // Return even when cancelled to exercise the delayed callback's hold guard too.
        let controller = ChromeHoverController(sleep: { _ in try? await Task.sleep(for: .milliseconds(80)) })
        controller.verticalTabs = true
        controller.autoHideSidebar = true
        controller.compactToolbar = true
        controller.pointerMoved(to: CGPoint(x: 1, y: 120))
        controller.pointerMoved(to: CGPoint(x: 700, y: 200))
        let first = ChromePresentationHold()
        let second = ChromePresentationHold()
        first.setPresented(true, controller: controller, region: .sidebar)
        second.setPresented(true, controller: controller, region: .sidebar)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(controller.sidebarIsRevealed)
        XCTAssertFalse(controller.toolbarIsRevealed)
        XCTAssertEqual(controller.sidebarPresentationCount, 2)
        first.end()
        controller.pointerMoved(to: nil)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertTrue(controller.sidebarIsRevealed)
        XCTAssertEqual(controller.sidebarPresentationCount, 1)
        second.end()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertFalse(controller.sidebarIsRevealed)
        XCTAssertEqual(controller.sidebarPresentationCount, 0)
        XCTAssertEqual(controller.presentationCount, 0)
    }

    func testNativePopoverOnlyRespondsToItsOwnCloseAndCleansUpOnce() {
        let controller = PresentationCounter()
        let popover = NSPopover()
        var closes = 0
        let presentation = ChromePopoverPresentation(popover: popover, owner: nil, controller: controller) { _ in closes += 1 }
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: NSPopover())
        XCTAssertEqual(controller.ends, 0)
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        presentation.close()
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        XCTAssertEqual(controller.ends, 1)
        XCTAssertEqual(closes, 1)
    }

    func testClosingOwnerWindowReleasesPopoverHold() {
        let controller = PresentationCounter()
        let owner = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        var closes = 0
        let presentation = ChromePopoverPresentation(popover: NSPopover(), owner: owner, controller: controller) { _ in closes += 1 }
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: other)
        XCTAssertEqual(controller.ends, 0)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: owner)
        presentation.close()
        XCTAssertEqual(controller.ends, 1)
        XCTAssertEqual(closes, 1)
    }

    func testNativeTeardownReleasesHoldAndRemovesObservers() {
        let controller = PresentationCounter()
        let popover = NSPopover()
        var closes = 0
        var presentation: ChromePopoverPresentation? = ChromePopoverPresentation(popover: popover, owner: nil, controller: controller) { _ in closes += 1 }
        weak var weakPresentation = presentation
        presentation = nil
        XCTAssertNil(weakPresentation)
        XCTAssertEqual(controller.ends, 1)
        NotificationCenter.default.post(name: NSPopover.didCloseNotification, object: popover)
        XCTAssertEqual(closes, 0)
    }
}

@MainActor
private final class PresentationCounter: ChromePresentationControlling {
    private(set) var begins = 0
    private(set) var ends = 0
    private(set) var sidebarBegins = 0
    private(set) var sidebarEnds = 0
    func beginPresentation(in region: ChromePresentationRegion) {
        if region == .toolbar { begins += 1 } else { sidebarBegins += 1 }
    }
    func endPresentation(in region: ChromePresentationRegion) {
        if region == .toolbar { ends += 1 } else { sidebarEnds += 1 }
    }
}
