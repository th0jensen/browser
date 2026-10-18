import XCTest
@testable import Browser

final class SidebarWidthTests: XCTestCase {
    func testSavedWidthSuppliesInitialGeometryAndExternalChangesWhileIdle() {
        let state = SidebarWidthState()
        XCTAssertEqual(state.width(saved: 310), 310)
        XCTAssertEqual(state.width(saved: 220), 220)
    }

    func testDragUpdatesGeometryImmediatelyAndSavesOnlyFinalWidth() {
        var state = SidebarWidthState()
        for width in stride(from: 220.0, through: 310.0, by: 1) {
            XCTAssertNil(state.update(width, isResizing: true))
            XCTAssertEqual(state.width(saved: 200), width)
        }
        XCTAssertEqual(state.finish(), 310)
        XCTAssertNil(state.finish(), "Ending or disappearing twice must not repeat a preference write")
        XCTAssertEqual(state.width(saved: 310), 310)
        XCTAssertEqual(state.width(saved: 240), 240)
    }

    func testAccessibilityAdjustmentCanPersistWithoutADrag() {
        var state = SidebarWidthState()
        XCTAssertEqual(state.update(260, isResizing: false), 260)
        XCTAssertNil(state.finish())
        XCTAssertEqual(state.width(saved: 260), 260)
    }

    func testExternalPreferenceDoesNotMoveAnActiveDrag() {
        var state = SidebarWidthState()
        XCTAssertNil(state.update(280, isResizing: true))
        XCTAssertEqual(state.width(saved: 190), 280)
        XCTAssertEqual(state.finish(), 280)
        XCTAssertEqual(state.width(saved: 280), 280)
    }
}
