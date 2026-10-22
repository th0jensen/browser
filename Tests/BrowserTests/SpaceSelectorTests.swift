import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class SpaceSelectorTests: XCTestCase {
    private func assertCenteredControls(_ view: SpaceSelectorView, in host: NSView,
                                        file: StaticString = #filePath, line: UInt = #line) {
        view.layoutSubtreeIfNeeded()
        let group = view.selectorGroup.convert(view.selectorGroup.bounds, to: host)
        XCTAssertEqual(group.midX, host.bounds.midX, accuracy: 0.01, "Center belongs to the selector, not selector plus utilities", file: file, line: line)
        XCTAssertGreaterThanOrEqual(view.selectorGroup.frame.minX, view.bounds.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(view.selectorGroup.frame.maxX, view.bounds.maxX, file: file, line: line)
        XCTAssertFalse(view.selectorGroup.frame.intersects(view.plusButton.frame), file: file, line: line)
        XCTAssertTrue(view.bounds.contains(view.plusButton.frame), file: file, line: line)
        if !view.overflowButton.isHidden {
            XCTAssertFalse(view.selectorGroup.frame.intersects(view.overflowButton.frame), file: file, line: line)
            XCTAssertFalse(view.overflowButton.frame.intersects(view.plusButton.frame), file: file, line: line)
            XCTAssertTrue(view.bounds.contains(view.overflowButton.frame), file: file, line: line)
        }
        let frames = view.choiceButtons.map { $0.convert($0.bounds, to: view) }
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(view.selectorGroup.frame.contains(frame), file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.width, 24, file: file, line: line)
            for other in frames.dropFirst(index + 1) { XCTAssertFalse(frame.intersects(other), file: file, line: line) }
        }
        XCTAssertEqual(view.choiceButtons.filter(\.isSelectedSpace).count, 1, file: file, line: line)
        XCTAssertTrue(view.choiceButtons.allSatisfy { !$0.isBordered }, file: file, line: line)
    }

    func testHostedSelectorIsCenteredForFirstLastManyNarrowAndFractionalWidths() async throws {
        for width: CGFloat in [72, 100, 164, 220, 240.5, 404] {
            for (count, selected) in [(1, 0), (3, 0), (3, 2), (20, 0), (20, 10), (20, 19)] {
                let fixture = try Fixture(width: width, count: count, selected: selected)
                defer { fixture.close() }
                let view = try await fixture.selector()
                assertCenteredControls(view, in: fixture.host)
                XCTAssertTrue(view.choiceButtons.contains { $0.spaceID == fixture.browser.activeSpaceID })
                XCTAssertEqual(view.plusButton.frame.maxX, view.bounds.maxX - (width >= 88 ? 4 : 0), accuracy: 0.01)
                XCTAssertEqual(view.spaceMenu.items.count, count)
                if count > 1 && view.choiceButtons.count == 1 {
                    XCTAssertTrue(view.overflowButton.isHidden)
                    XCTAssertTrue(view.choiceButtons[0].accessibilityLabel()?.hasPrefix("All Spaces, current Space ") == true)
                    XCTAssertTrue(view.choiceButtons[0].toolTip?.hasPrefix("All Spaces — ") == true)
                    XCTAssertEqual(view.choiceButtons[0].menu?.items.first?.title, "Edit Space…")
                }
                XCTAssertTrue(fixture.browser.allTabs.allSatisfy { $0.webView == nil })
            }
        }
    }

    func testActualSidebarFooterCentersTheSelectorNotTheTrailingPlus() async throws {
        let fixture = try Fixture(width: 180, count: 15, selected: 14, wholeSidebar: true)
        defer { fixture.close() }
        let view = try await fixture.selector()
        assertCenteredControls(view, in: fixture.host)
        XCTAssertFalse(view.overflowButton.isHidden)
        XCTAssertTrue(view.choiceButtons.last?.isSelectedSpace == true)
        XCTAssertTrue(view.selectorGroup.frame.maxX < view.plusButton.frame.minX)
    }

    func testResizingAndSelectionKeepGroupCenteredWhenOverflowAppearsAndDisappears() async throws {
        let fixture = try Fixture(width: 404, count: 10, selected: 0)
        defer { fixture.close() }
        let view = try await fixture.selector()
        XCTAssertTrue(view.overflowButton.isHidden)
        assertCenteredControls(view, in: fixture.host)
        fixture.resize(width: 164)
        try await waitUntil { abs(view.bounds.width - 164) < 0.01 }
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.overflowButton.isHidden)
        assertCenteredControls(view, in: fixture.host)
        fixture.browser.selectSpace(at: 9)
        try await waitUntil { view.choiceButtons.contains { $0.spaceID == fixture.browser.activeSpaceID && $0.isSelectedSpace } }
        assertCenteredControls(view, in: fixture.host)
        XCTAssertEqual(view.choiceButtons.last?.spaceID, fixture.browser.spaces.spaces[9].id)
        fixture.resize(width: 404)
        try await waitUntil { abs(view.bounds.width - 404) < 0.01 }
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.overflowButton.isHidden)
        assertCenteredControls(view, in: fixture.host)
    }

    func testInactiveNativeRenderingIsOnlyADotAndSelectedRendersConfiguredIcon() async throws {
        let fixture = try Fixture(width: 220, count: 3, selected: 1)
        defer { fixture.close() }
        let view = try await fixture.selector()
        let inactive = try XCTUnwrap(view.choiceButtons.first { !$0.isSelectedSpace })
        let selected = try XCTUnwrap(view.choiceButtons.first { $0.isSelectedSpace })
        XCTAssertNil(inactive.image, "Inactive Spaces must not retain a configured icon")
        XCTAssertNil(inactive.displayedSymbol)
        XCTAssertEqual(inactive.title, "")
        XCTAssertNotNil(selected.image)
        XCTAssertEqual(selected.displayedSymbol, fixture.browser.spaces.spaces[1].icon.symbol)
        XCTAssertFalse(selected.isBordered)
        let dotInk = try renderedInk(inactive)
        XCTAssertGreaterThan(dotInk.count, 0)
        XCTAssertLessThanOrEqual(dotInk.bounds.width, 6)
        XCTAssertLessThanOrEqual(dotInk.bounds.height, 6)
        XCTAssertEqual(dotInk.bounds.midX, inactive.bounds.midX, accuracy: 1)
        XCTAssertEqual(dotInk.bounds.midY, inactive.bounds.midY, accuracy: 1)
        let iconInk = try renderedInk(selected)
        XCTAssertGreaterThan(iconInk.count, dotInk.count)
        XCTAssertGreaterThan(max(iconInk.bounds.width, iconInk.bounds.height), 6)
        XCTAssertLessThan(max(iconInk.bounds.width, iconInk.bounds.height), selected.bounds.width, "No persistent box surrounds selection")
        func containsGlass(_ root: NSView) -> Bool {
            root is NSGlassEffectView || root.subviews.contains(where: containsGlass)
        }
        XCTAssertFalse(containsGlass(view), "The selector is not a full-width glass dock")
    }

    func testNativeDirectSelectionUpdatesDotIconAndAccessibilityWithoutCreatingWebViews() async throws {
        let fixture = try Fixture(width: 220, count: 3, selected: 0)
        defer { fixture.close() }
        let view = try await fixture.selector()
        let original = try XCTUnwrap(view.choiceButtons.first)
        let destination = try XCTUnwrap(view.choiceButtons.last)
        XCTAssertTrue(original.isAccessibilitySelected())
        XCTAssertEqual(original.accessibilityValue() as? String, "Selected")
        XCTAssertEqual(destination.accessibilityLabel(), "Switch to Space \(fixture.browser.spaces.spaces.last!.title)")
        XCTAssertEqual(destination.toolTip, fixture.browser.spaces.spaces.last?.title)
        XCTAssertTrue(destination.acceptsFirstResponder)
        XCTAssertTrue(fixture.window.makeFirstResponder(destination))
        XCTAssertTrue(fixture.window.firstResponder === destination)
        XCTAssertEqual(destination.focusRingType, .exterior)
        XCTAssertGreaterThan(destination.focusRingMaskBounds.width, 0)
        XCTAssertTrue(destination.accessibilityPerformPress())
        try await waitUntil { fixture.browser.activeSpaceID == destination.spaceID && destination.isSelectedSpace }
        XCTAssertTrue(view.choiceButtons.first === original)
        XCTAssertNil(original.image)
        XCTAssertFalse(original.isAccessibilitySelected())
        XCTAssertNotNil(destination.image)
        XCTAssertTrue(destination.isAccessibilitySelected())
        XCTAssertEqual(destination.displayedSymbol, fixture.browser.spaces.spaces.last?.icon.symbol)
        XCTAssertEqual(view.plusButton.accessibilityLabel(), "New Space")
        XCTAssertEqual(view.accessibilityIdentifier(), "BrowserSpaceIconStrip")
        XCTAssertTrue(fixture.browser.allTabs.allSatisfy { $0.webView == nil })
        assertCenteredControls(view, in: fixture.host)
    }

    func testNativeOverflowMenuRetainsAllNamesAndSelectsHiddenSpace() async throws {
        let fixture = try Fixture(width: 164, count: 20, selected: 19)
        defer { fixture.close() }
        let view = try await fixture.selector()
        let hidden = fixture.browser.spaces.spaces[0]
        XCTAssertFalse(view.choiceButtons.contains { $0.spaceID == hidden.id })
        XCTAssertEqual(view.spaceMenu.items.map(\.title), fixture.browser.spaces.spaces.map(\.title))
        XCTAssertEqual(view.spaceMenu.items.filter { $0.state == .on }.count, 1)
        XCTAssertEqual(view.overflowButton.accessibilityLabel(), "All Spaces")
        view.spaceMenu.performActionForItem(at: 0)
        try await waitUntil { fixture.browser.activeSpaceID == hidden.id && view.choiceButtons.first?.isSelectedSpace == true }
        XCTAssertEqual(view.choiceButtons.first?.spaceID, hidden.id)
        assertCenteredControls(view, in: fixture.host)
        XCTAssertTrue(fixture.browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testNativeUtilitiesAndContextEditHaveRealActionsAndDisabledControlsStayAccessible() {
        let spaces = [BrowserSpace(id: UUID(), title: "Home", profileID: BrowserProfile.defaultID),
                      BrowserSpace(id: UUID(), title: "Work", profileID: BrowserProfile.defaultID, icon: .work)]
        let view = SpaceSelectorView(frame: .init(x: 0, y: 0, width: 220, height: 36))
        var selected: [UUID] = []
        var edited: [UUID] = []
        var creates = 0
        func update(enabled: Bool) {
            view.update(spaces: spaces, activeID: spaces[0].id, enabled: enabled,
                select: { selected.append($0) }, edit: { edited.append($0.id) }, create: { creates += 1 })
            view.layoutSubtreeIfNeeded()
        }
        update(enabled: true)
        view.plusButton.performClick(nil)
        XCTAssertEqual(creates, 1)
        view.choiceButtons[1].menu?.performActionForItem(at: 0)
        XCTAssertEqual(edited, [spaces[1].id])
        view.choiceButtons[1].performClick(nil)
        XCTAssertEqual(selected, [spaces[1].id])
        update(enabled: false)
        XCTAssertEqual(view.choiceButtons.count, 2)
        XCTAssertEqual(view.choiceButtons[1].accessibilityLabel(), "Switch to Space Work")
        XCTAssertFalse(view.choiceButtons[1].accessibilityPerformPress())
        XCTAssertFalse(view.plusButton.accessibilityPerformPress())
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(selected, [spaces[1].id])
        view.clearActions()
        XCTAssertFalse(view.plusButton.isEnabled)
    }

    func testHostedDragDisablesSelectorAndPrivateExtensionWindowsHaveNoSelector() async throws {
        let fixture = try Fixture(width: 220, count: 3, selected: 0)
        defer { fixture.close() }
        let view = try await fixture.selector()
        fixture.browser.tabDrag.begin("test-space", frame: .zero, axis: .vertical, crossing: { _, _ in }, completion: { _ in })
        try await waitUntil { !view.plusButton.isEnabled }
        XCTAssertFalse(view.choiceButtons.last!.accessibilityPerformPress())
        XCTAssertEqual(fixture.browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        fixture.browser.tabDrag.finish(cancelled: true)
        fixture.browser.tabDrag.endGesture()
        try await waitUntil { view.plusButton.isEnabled }
        for model in [BrowserModel(isPrivate: true), BrowserModel()] {
            if !model.isPrivate { model.isExtensionWindow = true }
            let host = NSHostingView(rootView: SpaceSwitcher(browser: model, style: .sidebar))
            host.frame = .init(x: 0, y: 0, width: 220, height: 36)
            host.layoutSubtreeIfNeeded()
            for _ in 0..<3 { await Task.yield() }
            XCTAssertNil(findSelector(in: host))
            XCTAssertTrue(model.allTabs.allSatisfy { $0.webView == nil })
        }
    }

    func testHostedKeyboardTraversalEntersAndExitsBothBoundariesAfterUpdates() async throws {
        let fixture = try Fixture(width: 220, count: 12, selected: 0)
        defer { fixture.close() }
        let view = try await fixture.selector()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        let before = NSTextField(frame: NSRect(x: 8, y: 90, width: 180, height: 22))
        let after = NSTextField(frame: NSRect(x: 8, y: 8, width: 180, height: 22))
        fixture.host.removeFromSuperview()
        fixture.host.frame = NSRect(x: 0, y: 44, width: 220, height: 36)
        container.addSubview(before)
        container.addSubview(fixture.host)
        container.addSubview(after)
        fixture.window.setContentSize(container.frame.size)
        fixture.window.contentView = container
        fixture.window.initialFirstResponder = before
        fixture.window.orderBack(nil)
        fixture.window.autorecalculatesKeyViewLoop = false
        fixture.host.layoutSubtreeIfNeeded()
        fixture.window.recalculateKeyViewLoop()

        func isFocused(_ field: NSTextField) -> Bool {
            fixture.window.firstResponder === field ||
                (field.currentEditor().map { fixture.window.firstResponder === $0 } ?? false)
        }
        func traverse(forward: Bool, includesSelector: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) {
            let start = forward ? before : after
            let destination = forward ? after : before
            XCTAssertTrue(fixture.window.makeFirstResponder(start), file: file, line: line)
            var enteredSelector = false
            var exited = false
            var path: [String] = []
            for _ in 0..<40 {
                // A text field's first responder is its shared field editor;
                // traverse from the owning control, as native Tab handling does.
                let responder = fixture.window.firstResponder
                let current = ((responder as? NSTextView)?.delegate as? NSView) ?? (responder as? NSView)
                guard let current else { break }
                if forward { fixture.window.selectKeyView(following: current) }
                else { fixture.window.selectKeyView(preceding: current) }
                path.append(fixture.window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")
                if let control = fixture.window.firstResponder as? SpaceSelectorButton,
                   control.isDescendant(of: view) { enteredSelector = true }
                if isFocused(destination) { exited = true; break }
            }
            XCTAssertTrue(exited, "Traversal must reach the external destination: \(path)", file: file, line: line)
            let eligibility = view.choiceButtons.map { "\($0.canBecomeKeyView)/\($0.acceptsFirstResponder)/\($0.isHiddenOrHasHiddenAncestor)" }
            XCTAssertEqual(enteredSelector, includesSelector,
                "Keyboard mode \(NSApp.isFullKeyboardAccessEnabled); eligibility \(eligibility); next \(String(describing: before.nextKeyView)); path \(path)", file: file, line: line)
        }
        func checkBoundaryAfterRelayout(file: StaticString = #filePath, line: UInt = #line) {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            traverse(forward: true, file: file, line: line)
            traverse(forward: false, file: file, line: line)
        }
        checkBoundaryAfterRelayout()
        checkBoundaryAfterRelayout()
        fixture.browser.selectSpace(at: 11)
        try await waitUntil { view.choiceButtons.last?.spaceID == fixture.browser.activeSpaceID && view.choiceButtons.last?.isSelectedSpace == true }
        checkBoundaryAfterRelayout()
        fixture.window.setContentSize(NSSize(width: 404, height: 120))
        container.frame.size.width = 404
        fixture.host.frame.size.width = 404
        fixture.host.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(view.overflowButton.isHidden)
        checkBoundaryAfterRelayout()
        fixture.browser.tabDrag.begin("test-boundary", frame: .zero, axis: .vertical, crossing: { _, _ in }, completion: { _ in })
        try await waitUntil { !view.plusButton.isEnabled }
        traverse(forward: true, includesSelector: false)
        traverse(forward: false, includesSelector: false)
        fixture.browser.tabDrag.finish(cancelled: true)
        fixture.browser.tabDrag.endGesture()
        try await waitUntil { view.plusButton.isEnabled }
        checkBoundaryAfterRelayout()
        XCTAssertTrue(fixture.browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testRightToLeftKeepsGroupCenteredWithPlusOnItsTrailingEdge() async throws {
        let fixture = try Fixture(width: 164, count: 20, selected: 19, rightToLeft: true)
        defer { fixture.close() }
        let view = try await fixture.selector()
        assertCenteredControls(view, in: fixture.host)
        XCTAssertEqual(view.plusButton.frame.minX, 4, accuracy: 0.01)
        XCTAssertGreaterThan(view.overflowButton.frame.minX, view.selectorGroup.frame.maxX)
    }

    private func renderedInk(_ button: NSButton) throws -> (count: Int, bounds: CGRect) {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.clear(CGRect(x: 0, y: 0, width: 24, height: 24))
        button.draw(button.bounds)
        var points: [CGPoint] = []
        for y in 0..<24 {
            for x in 0..<24 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
            }
        }
        let minX = points.map(\.x).min() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return (points.count, CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

@MainActor
private func findSelector(in view: NSView) -> SpaceSelectorView? {
    if let selector = view as? SpaceSelectorView { return selector }
    return view.subviews.lazy.compactMap { findSelector(in: $0) }.first
}

/// Hosts the production selector without ordering or activating a desktop window.
@MainActor
private final class Fixture {
    let suite = "SpaceSelector-\(UUID())"
    let defaults: UserDefaults
    let browser: BrowserModel
    let window: SelectorTestWindow
    let host: NSHostingView<AnyView>

    init(width: CGFloat, count: Int, selected: Int, wholeSidebar: Bool = false, rightToLeft: Bool = false) throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let chrome = WindowChromePreferences(defaults: defaults)
        chrome.tabLayout = .vertical
        let store = BrowserSpaceStore(directory: .temporaryDirectory, enabled: false)
        try store.updateSpace(BrowserSpaceStore.defaultSpaceID, title: "Home", icon: .home, theme: .system)
        for index in 1..<max(1, count) {
            _ = try store.createSpace(title: "Space \(index)", icon: index == 1 ? .work : .book, theme: .blue)
        }
        browser = BrowserModel(chromePreferences: chrome, spaces: store)
        browser.selectSpace(at: selected)
        browser.consumedAddressFocusRequest = browser.addressFocusRequest
        let height: CGFloat = wholeSidebar ? 500 : 36
        window = SelectorTestWindow(contentRect: .init(x: 0, y: 0, width: width, height: height),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let root: AnyView
        if wholeSidebar {
            root = AnyView(TabStrip(browser: browser, layout: .vertical, isFullScreen: false, hoverCardTabID: .constant(nil)))
        } else {
            root = AnyView(SpaceSwitcher(browser: browser, style: .sidebar))
        }
        host = NSHostingView(rootView: AnyView(root.defaultAppStorage(defaults).environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)))
        host.frame = .init(x: 0, y: 0, width: width, height: height)
        window.contentView = host
    }

    func selector() async throws -> SpaceSelectorView {
        host.layoutSubtreeIfNeeded()
        try await waitUntil { findSelector(in: self.host)?.choiceButtons.isEmpty == false }
        let view = try XCTUnwrap(findSelector(in: host))
        view.layoutSubtreeIfNeeded()
        return view
    }

    func resize(width: CGFloat) {
        window.setContentSize(.init(width: width, height: 36))
        host.frame.size.width = width
        host.layoutSubtreeIfNeeded()
    }

    func close() { window.close(); defaults.removePersistentDomain(forName: suite) }
}

@MainActor
private final class SelectorTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) { }
}
