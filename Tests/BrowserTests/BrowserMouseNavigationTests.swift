import AppKit
import XCTest
@testable import Browser

@MainActor
final class BrowserMouseNavigationTests: XCTestCase {
    func testSideButtonsNavigateExactlyOnceAndConsumeRelease() {
        var back = 0
        var forward = 0
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            XCTAssertTrue(BrowserMouseNavigation.handle(type: type, button: 3, back: { back += 1 }, forward: { forward += 1 }))
            XCTAssertTrue(BrowserMouseNavigation.handle(type: type, button: 4, back: { back += 1 }, forward: { forward += 1 }))
        }
        XCTAssertEqual(back, 1)
        XCTAssertEqual(forward, 1)
    }

    func testMiddleClickAndOtherEventsStayWithWebKit() {
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp, .otherMouseDragged, .keyDown] {
            for button in [0, 1, 2, 5] {
                XCTAssertFalse(BrowserMouseNavigation.handle(type: type, button: button,
                    back: { XCTFail("Unexpected Back") }, forward: { XCTFail("Unexpected Forward") }))
            }
        }
    }

    func testTidyWaveHasStationaryTipsMovingTapersAndTravelsRight() {
        let width: CGFloat = 160
        for phase in stride(from: 0.0, through: Double.pi * 2, by: 0.1) {
            for x: CGFloat in [0, width] {
                XCTAssertEqual(TidyActivityDivider.waveOffset(at: x, width: width, phase: phase), 0)
            }
        }
        func motion(at x: CGFloat) -> CGFloat {
            hypot(TidyActivityDivider.waveOffset(at: x, width: width, phase: 0),
                  TidyActivityDivider.waveOffset(at: x, width: width, phase: .pi / 2))
        }
        var previous: CGFloat = 0
        for x in stride(from: CGFloat(1), through: 24, by: 1) {
            let amount = motion(at: x)
            XCTAssertGreaterThan(amount, previous, "Motion must taper progressively, without a stationary stub")
            XCTAssertEqual(amount, motion(at: width - x), accuracy: 0.0001, "Both ends need the same taper")
            previous = amount
        }
        for x in stride(from: CGFloat(32), through: 120, by: 4) {
            XCTAssertEqual(TidyActivityDivider.waveOffset(at: x, width: width, phase: 0),
                           TidyActivityDivider.waveOffset(at: x + 4, width: width, phase: .pi / 4), accuracy: 0.0001)
        }
    }
}
