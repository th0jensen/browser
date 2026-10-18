import AppKit
import Observation
import XCTest
@testable import Browser

@MainActor
final class ChromeHoverTests: XCTestCase {
    private let outside = CGPoint(x: 800, y: 400)

    private func fixture() -> (ChromeHoverController, HoverTestClock) {
        let clock = HoverTestClock()
        let controller = ChromeHoverController { try await clock.sleep(for: $0) }
        controller.compactToolbar = true
        controller.verticalTabs = true
        controller.autoHideSidebar = true
        return (controller, clock)
    }

    private func requests(_ count: Int, on clock: HoverTestClock) async {
        await fulfillment(of: [await clock.requestExpectation(count)], timeout: 1)
    }

    private func cancellations(_ count: Int, on clock: HoverTestClock) async {
        await fulfillment(of: [await clock.cancellationExpectation(count)], timeout: 1)
    }

    /// Observe the real controller's mutations before advancing its injected clock.
    private func expire(_ controller: ChromeHoverController, clock: HoverTestClock,
                        toolbar: Bool = false, sidebar: Bool = false, by duration: Duration = .milliseconds(120)) async {
        var changes: [XCTestExpectation] = []
        if toolbar {
            let changed = expectation(description: "Toolbar hide completes")
            withObservationTracking { _ = controller.toolbarIsRevealed } onChange: { changed.fulfill() }
            changes.append(changed)
        }
        if sidebar {
            let changed = expectation(description: "Sidebar hide completes")
            withObservationTracking { _ = controller.sidebarIsRevealed } onChange: { changed.fulfill() }
            changes.append(changed)
        }
        await clock.advance(by: duration)
        await fulfillment(of: changes, timeout: 1)
        if toolbar { XCTAssertFalse(controller.toolbarIsRevealed) }
        if sidebar { XCTAssertFalse(controller.sidebarIsRevealed) }
    }

    func testSidebarDragKeepsSidebarOpenWithoutRevealingToolbar() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.revealSidebar()
        controller.sidebarIsReordering = true
        controller.pointerMoved(to: outside)
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.sidebarIsRevealed)
        XCTAssertFalse(controller.toolbarIsRevealed)
        controller.sidebarIsReordering = false
        await requests(1, on: clock)
        await expire(controller, clock: clock, sidebar: true)
    }

    func testTopAndLeftEdgesRevealImmediatelyAndIndependently() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.pointerMoved(to: CGPoint(x: 1, y: 0))
        XCTAssertTrue(controller.toolbarIsRevealed, "The top-left corner belongs to the toolbar")
        XCTAssertFalse(controller.sidebarIsRevealed)
        controller.pointerMoved(to: CGPoint(x: 1, y: controller.headerHeight / 2))
        XCTAssertTrue(controller.toolbarIsRevealed)
        XCTAssertFalse(controller.sidebarIsRevealed, "Moving within the header must not open the sidebar")

        controller.pointerMoved(to: outside)
        await requests(1, on: clock)
        await expire(controller, clock: clock, toolbar: true)
        controller.pointerMoved(to: CGPoint(x: 1, y: 200))
        XCTAssertTrue(controller.sidebarIsRevealed)
        XCTAssertFalse(controller.toolbarIsRevealed, "The left edge must not reveal the toolbar")
    }

    func testFolderPopoverKeepsItsSidebarOpenWithoutRevealingTheToolbar() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.revealSidebar()
        controller.folderEditorIsPresented = true
        controller.pointerMoved(to: outside)
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.sidebarIsRevealed)
        XCTAssertFalse(controller.toolbarIsRevealed)

        controller.revealToolbar()
        controller.pointerMoved(to: outside)
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.toolbarIsRevealed)
        controller.folderEditorIsPresented = false
        await requests(2, on: clock)
        await expire(controller, clock: clock, toolbar: true, sidebar: true)
    }

    func testRepeatedMovementDoesNotPostponeEither120MillisecondHide() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.revealToolbar()
        controller.revealSidebar()
        controller.pointerMoved(to: outside)
        await requests(2, on: clock)
        let delays = await clock.requestedDurations
        XCTAssertEqual(delays, [.milliseconds(120), .milliseconds(120)])

        await clock.advance(by: .milliseconds(119))
        XCTAssertTrue(controller.toolbarIsRevealed)
        XCTAssertTrue(controller.sidebarIsRevealed)
        for offset in 0..<20 {
            controller.pointerMoved(to: CGPoint(x: 600 + offset, y: 300))
        }
        await expire(controller, clock: clock, toolbar: true, sidebar: true, by: .milliseconds(1))
        let requestCount = await clock.requestedDurations.count
        XCTAssertEqual(requestCount, 2, "Movement must reuse the original deadlines")
    }

    func testReenteringEachRegionCancelsItsPendingHide() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.revealToolbar()
        controller.pointerMoved(to: outside)
        await requests(1, on: clock)
        controller.pointerMoved(to: CGPoint(x: 500, y: 20))
        await cancellations(1, on: clock)
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.toolbarIsRevealed)

        controller.compactToolbar = false
        controller.pointerMoved(to: CGPoint(x: 1, y: 200))
        controller.pointerMoved(to: outside)
        await requests(2, on: clock)
        controller.pointerMoved(to: CGPoint(x: controller.sidebarWidth / 2, y: 200))
        await cancellations(2, on: clock)
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.sidebarIsRevealed)
    }

    func testAddressFocusRevealsAndLatchesUntilFocusEndsWithoutAnotherMove() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.pointerMoved(to: outside)
        controller.addressIsFocused = true
        XCTAssertTrue(controller.toolbarIsRevealed)
        controller.pointerMoved(to: nil)
        let pending = await clock.pendingCount
        XCTAssertEqual(pending, 0)

        controller.addressIsFocused = false
        XCTAssertFalse(controller.toolbarIsRevealed, "Losing address focus must dismiss editing chrome immediately")
        let afterFocusLoss = await clock.pendingCount
        XCTAssertEqual(afterFocusLoss, 0)
    }

    func testFocusAcquiredDuringHideCancelsTheOldDeadline() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.revealToolbar()
        controller.pointerMoved(to: outside)
        await requests(1, on: clock)
        controller.addressIsFocused = true
        await cancellations(1, on: clock)
        await clock.advance(by: .milliseconds(120))
        XCTAssertTrue(controller.toolbarIsRevealed)
        controller.addressIsFocused = false
        XCTAssertFalse(controller.toolbarIsRevealed, "The canceled old deadline must not delay focus-loss dismissal")
        let afterFocusLoss = await clock.pendingCount
        XCTAssertEqual(afterFocusLoss, 0)
        await clock.advance(by: .seconds(1))
        XCTAssertFalse(controller.toolbarIsRevealed)
    }

    func testCustomizationRevealsToolbarAndResumesHideWhenItEnds() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.pointerMoved(to: outside)
        controller.customizationIsRunning = true
        XCTAssertTrue(controller.toolbarIsRevealed)
        controller.pointerMoved(to: outside)
        let pending = await clock.pendingCount
        XCTAssertEqual(pending, 0)
        controller.customizationIsRunning = false
        await requests(1, on: clock)
        await expire(controller, clock: clock, toolbar: true)
    }

    func testMenuTrackingCancelsBothHidesAndResumesAfterMenuCloses() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.revealToolbar()
        controller.revealSidebar()
        controller.pointerMoved(to: outside)
        await requests(2, on: clock)
        controller.menuIsTracking = true
        await cancellations(2, on: clock)
        controller.pointerMoved(to: nil)
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.toolbarIsRevealed)
        XCTAssertTrue(controller.sidebarIsRevealed)

        controller.menuIsTracking = false
        await requests(4, on: clock)
        await expire(controller, clock: clock, toolbar: true, sidebar: true)
    }

    func testSidebarResizeLatchesAndUsesTheUpdatedWidth() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.pointerMoved(to: CGPoint(x: 1, y: 200))
        controller.pointerMoved(to: outside)
        await requests(1, on: clock)
        controller.sidebarIsResizing = true
        await cancellations(1, on: clock)
        controller.sidebarWidth = 400
        controller.pointerMoved(to: CGPoint(x: 390, y: 200))
        controller.sidebarIsResizing = false
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.sidebarIsRevealed, "Releasing a resize inside the new width keeps the sidebar open")

        controller.pointerMoved(to: CGPoint(x: 400 + BrowserChrome.edgeInset + 1, y: 200))
        await requests(2, on: clock)
        controller.sidebarIsResizing = true
        await cancellations(2, on: clock)
        controller.sidebarIsResizing = false
        await requests(3, on: clock)
        await expire(controller, clock: clock, sidebar: true)
    }

    func testModeChangesResetTheirRegionAndCancelPendingWork() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.revealToolbar()
        controller.revealSidebar()
        controller.pointerMoved(to: outside)
        await requests(2, on: clock)
        controller.compactToolbar = false
        XCTAssertFalse(controller.toolbarIsRevealed)
        XCTAssertTrue(controller.sidebarIsRevealed, "The sidebar has its own visibility mode")
        controller.autoHideSidebar = false
        XCTAssertFalse(controller.sidebarIsRevealed)
        await cancellations(2, on: clock)

        controller.autoHideSidebar = true
        controller.pointerMoved(to: CGPoint(x: 1, y: 200))
        XCTAssertTrue(controller.sidebarIsRevealed)
        controller.pointerMoved(to: outside)
        await requests(3, on: clock)
        controller.verticalTabs = false
        XCTAssertFalse(controller.sidebarIsRevealed)
        await cancellations(3, on: clock)
        await clock.advance(by: .seconds(1))
        let pending = await clock.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testStopCancelsDeferredHidesWhenTheWindowDisappears() async {
        let (controller, clock) = fixture()
        controller.revealToolbar()
        controller.revealSidebar()
        controller.pointerMoved(to: outside)
        await requests(2, on: clock)
        controller.stop()
        await cancellations(2, on: clock)
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(controller.toolbarIsRevealed, "Stopped work cannot mutate the detached window")
        XCTAssertTrue(controller.sidebarIsRevealed)
        let pending = await clock.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testFloatingSidebarTopRemainsHoveredWhileToolbarIsHidden() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.pointerMoved(to: CGPoint(x: 1, y: 200))
        controller.pointerMoved(to: CGPoint(x: controller.sidebarWidth / 2, y: BrowserChrome.edgeInset + 1))
        XCTAssertTrue(controller.sidebarIsRevealed)
        XCTAssertFalse(controller.toolbarIsRevealed)
        let pending = await clock.pendingCount
        XCTAssertEqual(pending, 0, "The floating panel occupies the header while the toolbar is hidden")

        controller.pointerMoved(to: CGPoint(x: 1, y: 0))
        XCTAssertTrue(controller.toolbarIsRevealed, "The top activation edge must remain reachable above the panel")
        await requests(1, on: clock)
        await expire(controller, clock: clock, sidebar: true)
        XCTAssertTrue(controller.toolbarIsRevealed)
    }

    func testToolbarSidebarButtonStaysOpenUntilThePointerEntersContent() async {
        let (controller, clock) = fixture()
        defer { controller.stop() }
        controller.pointerMoved(to: CGPoint(x: 500, y: 0))
        controller.toggleSidebarFromToolbar()
        XCTAssertTrue(controller.sidebarIsRevealed)
        controller.pointerMoved(to: CGPoint(x: 500, y: 20))
        controller.pointerMoved(to: nil)
        await requests(1, on: clock)
        let pending = await clock.pendingCount
        XCTAssertEqual(pending, 1, "Only the toolbar may hide while the sidebar button holds its panel open")
        await expire(controller, clock: clock, toolbar: true)
        XCTAssertTrue(controller.sidebarIsRevealed)

        controller.pointerMoved(to: CGPoint(x: controller.sidebarWidth / 2, y: 200))
        controller.pointerMoved(to: outside)
        await requests(2, on: clock)
        await expire(controller, clock: clock, sidebar: true)
        controller.toggleSidebarFromToolbar()
        XCTAssertTrue(controller.sidebarIsRevealed)
        controller.toggleSidebarFromToolbar()
        XCTAssertFalse(controller.sidebarIsRevealed)
    }
}

/// A clock for the controller's actual sleep operations. Tests advance time explicitly;
/// XCTest's timeout only bounds failures to start or finish an operation.
private actor HoverTestClock {
    private struct Pending {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var now: Duration = .zero
    private var pending: [UUID: Pending] = [:]
    private var requestWaiters: [(Int, XCTestExpectation)] = []
    private var cancellationWaiters: [(Int, XCTestExpectation)] = []
    private var cancellationCount = 0
    private(set) var requestedDurations: [Duration] = []
    var pendingCount: Int { pending.count }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pending[id] = Pending(deadline: now + duration, continuation: continuation)
                requestedDurations.append(duration)
                fulfillRequestWaiters()
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance(by duration: Duration) {
        now += duration
        let due = pending.filter { $0.value.deadline <= now }
        for (id, request) in due {
            pending.removeValue(forKey: id)
            request.continuation.resume()
        }
    }

    func requestExpectation(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Started \(count) hover sleeps")
        requestWaiters.append((count, expectation))
        fulfillRequestWaiters()
        return expectation
    }

    func cancellationExpectation(_ count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "Cancelled \(count) hover sleeps")
        cancellationWaiters.append((count, expectation))
        fulfillCancellationWaiters()
        return expectation
    }

    private func cancel(_ id: UUID) {
        guard let request = pending.removeValue(forKey: id) else { return }
        cancellationCount += 1
        request.continuation.resume(throwing: CancellationError())
        fulfillCancellationWaiters()
    }

    private func fulfillRequestWaiters() {
        let ready = requestWaiters.filter { $0.0 <= requestedDurations.count }
        requestWaiters.removeAll { $0.0 <= requestedDurations.count }
        ready.forEach { $0.1.fulfill() }
    }

    private func fulfillCancellationWaiters() {
        let ready = cancellationWaiters.filter { $0.0 <= cancellationCount }
        cancellationWaiters.removeAll { $0.0 <= cancellationCount }
        ready.forEach { $0.1.fulfill() }
    }
}
