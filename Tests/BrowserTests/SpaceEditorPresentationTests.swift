import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class SpaceEditorPresentationTests: XCTestCase {
    func testNewAndEditSpaceUseNonmodalAnchoredPopoversAndReleaseChromeOnSpaceChange() async throws {
        for editing in [false, true] {
            let suite = "SpaceEditor-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = WindowChromePreferences(defaults: defaults)
            preferences.tabLayout = .vertical
            preferences.autoHideSidebar = true
            let spaces = BrowserSpaceStore(directory: .temporaryDirectory, enabled: false)
            let work = try spaces.createSpace(title: "Work")
            let browser = BrowserModel(chromePreferences: preferences, spaces: spaces)
            let controller = ChromeHoverController()
            controller.verticalTabs = true
            controller.autoHideSidebar = true
            controller.compactToolbar = true
            browser.chromeHover = controller
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 420),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            browser.window = window
            let host = NSHostingView(rootView: VStack {
                Spacer()
                SpaceSwitcher(browser: browser, style: .sidebar).frame(height: 36)
            }.defaultAppStorage(defaults))
            host.frame = NSRect(x: 0, y: 0, width: 220, height: 420)
            window.contentView = host
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            try await waitUntil { self.selector(in: host)?.choiceButtons.isEmpty == false }
            let selector = try XCTUnwrap(selector(in: host))
            let initialPages = browser.allTabs.map(ObjectIdentifier.init)
            let initialSpaces = spaces.spaces
            controller.pointerMoved(to: CGPoint(x: 1, y: 120))
            controller.pointerMoved(to: CGPoint(x: 700, y: 200))
            if editing {
                let menu = try XCTUnwrap(selector.choiceButtons.first?.menu)
                menu.performActionForItem(at: 0)
            } else {
                selector.plusButton.performClick(nil)
            }
            try await waitUntil { self.editorMarker() != nil && controller.sidebarPresentationCount == 1 }
            let marker = try XCTUnwrap(editorMarker())
            let popoverWindow = try XCTUnwrap(marker.window)
            XCTAssertTrue(popoverWindow !== window)
            XCTAssertNil(window.attachedSheet, "Space editing must not dim or block the source window with a sheet")
            XCTAssertFalse(popoverWindow.isSheet)
            XCTAssertLessThan(popoverWindow.frame.width, 500)
            controller.pointerMoved(to: CGPoint(x: 700, y: 200))
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertTrue(controller.sidebarIsRevealed, "Pointer travel into the popover must not hide its source")
            XCTAssertFalse(controller.toolbarIsRevealed, "A sidebar editor must not reveal unrelated toolbar chrome")
            XCTAssertEqual(controller.sidebarPresentationCount, 1)
            XCTAssertEqual(browser.allTabs.map(ObjectIdentifier.init), initialPages)
            XCTAssertEqual(spaces.spaces, initialSpaces)
            XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
            browser.selectSpace(work.id)
            try await waitUntil { self.editorMarker() == nil && controller.sidebarPresentationCount == 0 && !controller.sidebarIsRevealed }
            XCTAssertNil(window.attachedSheet)
            XCTAssertEqual(spaces.spaces, initialSpaces, "Dismissal must not commit editor changes")
        }
    }

    private func selector(in view: NSView) -> SpaceSelectorView? {
        if let selector = view as? SpaceSelectorView { return selector }
        return view.subviews.lazy.compactMap { self.selector(in: $0) }.first
    }

    private func editorMarker() -> NSView? {
        func find(in view: NSView) -> NSView? {
            if view.identifier?.rawValue == "BrowserSpaceEditorPopover" { return view }
            return view.subviews.lazy.compactMap { find(in: $0) }.first
        }
        return NSApp.windows.lazy.filter(\.isVisible).compactMap { $0.contentView.flatMap { find(in: $0) } }.first
    }
}
