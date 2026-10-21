import AppKit
import XCTest
@testable import Browser

@MainActor
final class CommandPaletteMotionTests: XCTestCase {
    func testOneGlassAndReturnRetargetRapidSelectionWithoutChangingPageOrFocus() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        let table = palette.table
        table.reduceSelectionMotion = { false }
        let glass = table.selectionGlass
        let page = fixture.source.webView
        let revision = fixture.source.navigationRevision
        let ids = fixture.browser.allTabs.map(\.id)
        let first = try XCTUnwrap(table.selectionTargetFrame)
        XCTAssertFalse(table.isSelectionAnimating, "Initial selection snaps into place")
        palette.perform(.moveDown)
        XCTAssertTrue(table.isSelectionAnimating)
        let second = try XCTUnwrap(table.selectionTargetFrame)
        try await Task.sleep(for: .milliseconds(35))
        let visibleBeforeRetarget = try XCTUnwrap(glass.layer?.presentation()).frame
        palette.perform(.moveDown)
        XCTAssertTrue(table.isSelectionAnimating)
        let visibleAfterRetarget = try XCTUnwrap(glass.layer?.presentation()).frame
        XCTAssertLessThan(abs(visibleAfterRetarget.midY - visibleBeforeRetarget.midY), table.rowHeight / 3,
                          "A retarget starts from the displayed capsule, not the previous destination")
        let third = try XCTUnwrap(table.selectionTargetFrame)
        XCTAssertGreaterThan(second.minY, first.minY)
        XCTAssertGreaterThan(third.minY, second.minY)
        XCTAssertEqual(table.selectedRow, 2)
        XCTAssertTrue(table.selectionGlass === glass)
        XCTAssertEqual(table.subviews.compactMap { $0 as? NSGlassEffectView }.count, 1)
        XCTAssertTrue(glass.returnSymbol.isDescendant(of: glass))
        try await waitFor("latest glide finishes") { !table.isSelectionAnimating }
        XCTAssertEqual(glass.frame, third)
        XCTAssertTrue(fixture.window.firstResponder === palette.field.currentEditor())
        XCTAssertTrue(fixture.source.webView === page)
        XCTAssertEqual(fixture.source.navigationRevision, revision)
        XCTAssertEqual(fixture.browser.allTabs.map(\.id), ids)
    }

    func testReduceMotionSettlesFlightAndReloadOrDismissCannotResurrectIt() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        let table = palette.table
        table.reduceSelectionMotion = { false }
        palette.perform(.moveDown)
        XCTAssertTrue(table.isSelectionAnimating)
        table.reduceSelectionMotion = { true }
        table.updateSelection(animated: false)
        XCTAssertFalse(table.isSelectionAnimating)
        XCTAssertEqual(table.selectionGlass.frame, table.selectionTargetFrame)
        palette.perform(.moveUp)
        XCTAssertFalse(table.isSelectionAnimating)
        XCTAssertEqual(table.selectionGlass.frame, table.selectionTargetFrame)
        table.reduceSelectionMotion = { false }
        palette.perform(.moveDown)
        try await type("Motion 4", in: palette)
        XCTAssertFalse(table.isSelectionAnimating, "Changed results snap; old rows do not glide through new content")
        XCTAssertEqual(table.selectedRow, 0)
        palette.perform(.moveDown)
        palette.dismiss()
        XCTAssertFalse(table.isSelectionAnimating)
        XCTAssertTrue(table.selectionGlass.isHidden)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(table.selectionGlass.isHidden, "An obsolete completion cannot show the selection again")
        XCTAssertNil(table.selectionTargetFrame)
    }

    func testSharedCapsuleKeepsPaddingAndHeightWhenPartiallyScrolledOrResized() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        let table = palette.table
        table.reduceSelectionMotion = { true }
        let glass = table.selectionGlass
        let scroll = try XCTUnwrap(table.enclosingScrollView as? CommandPaletteResultsScrollView)
        scroll.setFrameSize(NSSize(width: scroll.frame.width, height: 100))
        scroll.tile()
        table.updateSelection(animated: false)
        let initial = glass.frame
        XCTAssertEqual(initial.height, CommandPaletteLayout.rowHeight - 2 * CommandPaletteLayout.selectionVerticalInset)
        let outerContent = try XCTUnwrap(palette.glass?.contentView)
        let frame = outerContent.convert(glass.bounds, from: glass)
        XCTAssertEqual(frame.minX + frame.height / 2, CommandPaletteLayout.iconCenterX, accuracy: 0.5,
                       "The leading icon sits in the capsule cap, not against its edge")
        XCTAssertEqual(CommandPaletteLayout.textX - CommandPaletteLayout.iconCenterX, CommandPaletteLayout.iconToText)
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: 18))
        scroll.reflectScrolledClipView(scroll.contentView)
        table.updateSelection(animated: false)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, table.rect(ofRow: 0).minY)
        XCTAssertEqual(glass.frame, initial, "Clip partial rows; do not squash their glass shape")
        XCTAssertEqual(glass.cornerRadius, initial.height / 2)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertFalse(table.isSelectionAnimating)
        for width: CGFloat in [420, 680] {
            scroll.setFrameSize(NSSize(width: width, height: 100))
            scroll.tile()
            table.layoutSubtreeIfNeeded()
            table.updateSelection(animated: false)
            XCTAssertFalse(table.isSelectionAnimating, "Geometry changes snap, not sweep sideways")
            XCTAssertEqual(glass.frame.height, initial.height)
            XCTAssertEqual(glass.frame, table.selectionTargetFrame)
            let readable = table.convert(scroll.readableContentBounds, from: scroll.contentView)
            XCTAssertGreaterThanOrEqual(glass.frame.minX, readable.minX)
            XCTAssertLessThanOrEqual(glass.frame.maxX, readable.maxX)
        }
    }

    func testHeightAndWidthResizeCancelActiveMotionWithoutManualRepair() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        let table = palette.table
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        table.reduceSelectionMotion = { false }
        palette.perform(.moveDown)
        XCTAssertTrue(table.isSelectionAnimating)
        scroll.setFrameSize(NSSize(width: scroll.frame.width, height: scroll.frame.height - 20))
        scroll.tile()
        XCTAssertFalse(table.isSelectionAnimating, "Height-only resize cancels even an unchanged document target")
        XCTAssertEqual(table.selectionGlass.frame, table.selectionTargetFrame)
        palette.perform(.moveDown)
        XCTAssertTrue(table.isSelectionAnimating)
        scroll.setFrameSize(NSSize(width: scroll.frame.width - 40, height: scroll.frame.height))
        scroll.tile()
        XCTAssertFalse(table.isSelectionAnimating)
        XCTAssertEqual(table.selectionGlass.frame, table.selectionTargetFrame)
    }

    func testDismissReopenDoesNotLetOldCompletionStopNewMotion() async throws {
        let fixture = try await fixture()
        defer { fixture.close() }
        let palette = try await open(fixture)
        let glass = palette.table.selectionGlass
        palette.table.reduceSelectionMotion = { false }
        palette.perform(.moveDown)
        try await Task.sleep(for: .milliseconds(35))
        palette.dismiss()
        XCTAssertTrue(glass.isHidden)
        let reopened = try await open(fixture)
        XCTAssertTrue(reopened.table.selectionGlass === glass)
        reopened.perform(.moveDown)
        XCTAssertTrue(reopened.table.isSelectionAnimating)
        try await Task.sleep(for: .milliseconds(35))
        XCTAssertFalse(glass.isHidden)
        XCTAssertTrue(reopened.table.isSelectionAnimating, "Cancelled completion must not finish the new transition")
        try await waitFor("new animation finishes") { !reopened.table.isSelectionAnimating }
        XCTAssertEqual(glass.frame, reopened.table.selectionTargetFrame)
    }

    private func fixture() async throws -> MotionFixture {
        let fixture = try MotionFixture()
        do {
            try await waitFor("hosted palette source") {
                fixture.source.pageTitle == "Motion Source" && fixture.source.webView?.window === fixture.window
                    && fixture.browser.commandPalette?.anchor?.window === fixture.window
            }
            for index in 0..<5 {
                fixture.browser.history?.recordVisit(to: URL(string: "http://motion.invalid/\(index)")!, title: "Motion \(index)")
            }
            return fixture
        } catch { fixture.close(); throw error }
    }

    private func open(_ fixture: MotionFixture) async throws -> CommandPaletteController {
        fixture.browser.showCommandPalette()
        fixture.anchor.update()
        try await waitFor("native command bar") {
            fixture.browser.commandPalette?.isPresented == true && fixture.browser.commandPalette?.field.currentEditor() != nil
        }
        let palette = try XCTUnwrap(fixture.browser.commandPalette)
        try await type("Motion", in: palette)
        return palette
    }

    private func type(_ text: String, in palette: CommandPaletteController) async throws {
        let editor = try XCTUnwrap(palette.field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await waitFor("committed native query") { palette.typedText == text }
    }

    private func waitFor(_ name: String, _ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out: \(name)"); throw MotionFailure.timeout }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private enum MotionFailure: Error { case timeout }

/// Stable native geometry isolates animation timing from SwiftUI's separate
/// window minimum-size negotiation, already covered by the full geometry suite.
@MainActor
private final class MotionFixture {
    let suite = "CommandMotion-\(UUID())"
    let defaults: UserDefaults
    let browser: BrowserModel
    let source: BrowserTab
    let window: NSWindow
    let anchor: CommandPaletteAnchor

    init() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let spaces = BrowserSpaceStore(directory: .temporaryDirectory.appending(path: UUID().uuidString), enabled: false)
        browser = BrowserModel(sitePermissions: SitePermissions(), chromePreferences: WindowChromePreferences(defaults: defaults),
                               history: HistoryStore(file: nil), websiteDataStore: .nonPersistent(), spaces: spaces)
        source = try XCTUnwrap(browser.activeTab)
        source.load(URL(string: "data:text/html,<title>Motion Source</title><p>Unchanged page</p>")!)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        window.contentView = root
        let page = try XCTUnwrap(source.webView)
        page.frame = root.bounds
        page.autoresizingMask = [.width, .height]
        root.addSubview(page)
        anchor = CommandPaletteAnchor(browser: browser, bookmarks: BookmarkStore(defaults: defaults))
        anchor.frame = root.bounds
        anchor.autoresizingMask = [.width, .height]
        root.addSubview(anchor)
        browser.window = window
        window.orderBack(nil)
    }

    func close() {
        browser.commandPalette?.dismiss(restoreFocus: false)
        source.stopLoading()
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }
}
