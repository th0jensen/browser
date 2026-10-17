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
    func beginPresentation() { begins += 1 }
    func endPresentation() { ends += 1 }
}
