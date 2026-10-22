import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class SpaceVisibilityPreferencesTests: XCTestCase {
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "SpaceVisibility-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testIndicatorHidingPoliciesCoverEmptySingleAndMultipleSpaces() {
        for count in [0, 1, 2, 20] {
            XCTAssertFalse(SpaceIndicatorHiding.always.showsIndicator(spaceCount: count))
            XCTAssertEqual(SpaceIndicatorHiding.whenSingleSpace.showsIndicator(spaceCount: count), count > 1)
            XCTAssertEqual(SpaceIndicatorHiding.never.showsIndicator(spaceCount: count), count > 0)
        }
        XCTAssertEqual(SpaceIndicatorHiding.allCases.map(\.title), ["Always", "When only one Space", "Never"])
    }

    func testPreferencesPreserveDefaultsPersistAndStayWindowAndVariantLocal() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WindowChromePreferences(defaults: defaults, variant: .debug)
        let second = WindowChromePreferences(defaults: defaults, variant: .debug)
        let release = WindowChromePreferences(defaults: defaults, variant: .release)
        XCTAssertTrue(first.showsNewSpaceButton)
        XCTAssertEqual(first.spaceIndicatorHiding, .never)
        let target = WindowChromeSettingsTarget()
        let browser = model(preferences: first)
        target.browser = browser
        target.preferences.showsNewSpaceButton = false
        target.preferences.spaceIndicatorHiding = .whenSingleSpace
        XCTAssertTrue(second.showsNewSpaceButton)
        XCTAssertEqual(second.spaceIndicatorHiding, .never)
        XCTAssertTrue(release.showsNewSpaceButton)
        XCTAssertEqual(release.spaceIndicatorHiding, .never)
        let future = WindowChromePreferences(defaults: defaults, variant: .debug)
        XCTAssertFalse(future.showsNewSpaceButton)
        XCTAssertEqual(future.spaceIndicatorHiding, .whenSingleSpace)
        for mode in SpaceIndicatorHiding.allCases {
            first.spaceIndicatorHiding = mode
            XCTAssertEqual(WindowChromePreferences(defaults: defaults, variant: .debug).spaceIndicatorHiding, mode)
        }
        defaults.set("future-unknown-mode", forKey: "windowChrome.debug.spaceIndicatorHiding")
        XCTAssertEqual(WindowChromePreferences(defaults: defaults, variant: .debug).spaceIndicatorHiding, .never)
    }

    func testFooterHeightAndTitleAreIndependentWithoutMutatingSpacesOrTabs() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WindowChromePreferences(defaults: defaults)
        preferences.tabLayout = .vertical
        let browser = model(preferences: preferences)
        let strip = TabStrip(browser: browser, layout: .vertical, isFullScreen: false, hoverCardTabID: .constant(nil))
        let spaces = browser.spaces.spaces
        let tabs = browser.allTabs.map(ObjectIdentifier.init)
        let selectedSpace = browser.activeSpaceID
        let selectedTab = browser.activeTabID
        for title in [false, true] {
            preferences.showsSpaceTitle = title
            for plus in [false, true] {
                preferences.showsNewSpaceButton = plus
                for mode in SpaceIndicatorHiding.allCases {
                    preferences.spaceIndicatorHiding = mode
                    let footer = plus || mode.showsIndicator(spaceCount: spaces.count)
                    XCTAssertEqual(strip.showsSpaceSelector, footer)
                    XCTAssertEqual(strip.showsSpaceTitle, title)
                    let expected: CGFloat = (footer ? 36 + BrowserChrome.edgeInset * 2 : 0)
                        + (title ? 24 + BrowserChrome.edgeInset : 0)
                    XCTAssertEqual(strip.sidebarSpaceControlsHeight, expected)
                }
            }
        }
        XCTAssertEqual(browser.spaces.spaces, spaces)
        XCTAssertEqual(browser.allTabs.map(ObjectIdentifier.init), tabs)
        XCTAssertEqual(browser.activeSpaceID, selectedSpace)
        XCTAssertEqual(browser.activeTabID, selectedTab)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
        let horizontal = TabStrip(browser: browser, layout: .horizontal, isFullScreen: false, hoverCardTabID: .constant(nil))
        XCTAssertFalse(horizontal.showsSpaceSelector)
        XCTAssertEqual(horizontal.sidebarSpaceControlsHeight, 0)
        browser.isExtensionWindow = true
        XCTAssertFalse(strip.showsSpaceSelector)
        XCTAssertEqual(strip.sidebarSpaceControlsHeight, 0)
    }

    func testNativeVisibilityPreservesCenteringAndRemovesHiddenActionsFocusAndAccessibility() throws {
        let spaces = (0..<20).map { BrowserSpace(id: UUID(), title: "Space \($0)", profileID: BrowserProfile.defaultID) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 164, height: 36), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = SpaceSelectorView(frame: .init(x: 0, y: 0, width: 164, height: 36))
        window.contentView = view
        var creates = 0
        var selections = 0
        func update(indicator: Bool, plus: Bool, rtl: Bool) {
            view.update(spaces: spaces, activeID: spaces[19].id, enabled: true, rightToLeft: rtl,
                        showsIndicator: indicator, showsNewSpaceButton: plus,
                        select: { _ in selections += 1 }, edit: { _ in }, create: { creates += 1 })
            view.layoutSubtreeIfNeeded()
        }
        for rtl in [false, true] {
            update(indicator: true, plus: true, rtl: rtl)
            let group = view.selectorGroup.frame
            let oldChoice = try XCTUnwrap(view.choiceButtons.first)
            XCTAssertTrue(window.makeFirstResponder(view.plusButton))
            update(indicator: true, plus: false, rtl: rtl)
            XCTAssertEqual(view.selectorGroup.frame, group, "Hiding plus must not shift the indicator")
            XCTAssertTrue(view.plusButton.isHidden)
            XCTAssertFalse(view.plusButton.canBecomeKeyView)
            XCTAssertFalse(window.firstResponder === view.plusButton)
            XCTAssertFalse(view.plusButton.accessibilityPerformPress())
            XCTAssertFalse((view.accessibilityChildren() ?? []).contains { ($0 as? NSView) === view.plusButton })
            XCTAssertFalse(view.overflowButton.isHidden)
            update(indicator: false, plus: true, rtl: rtl)
            XCTAssertTrue(view.selectorGroup.isHidden)
            XCTAssertTrue(view.choiceButtons.isEmpty)
            XCTAssertTrue(view.overflowButton.isHidden)
            XCTAssertFalse(oldChoice.accessibilityPerformPress(), "Removed choices must not retain active actions")
            XCTAssertEqual(view.accessibilityChildren()?.count, 1)
            view.spaceMenu.performActionForItem(at: 0)
            XCTAssertEqual(selections, 0, "A stale menu cannot select a hidden indicator")
            XCTAssertTrue(view.plusButton.accessibilityPerformPress())
            update(indicator: false, plus: false, rtl: rtl)
            XCTAssertEqual(view.accessibilityChildren()?.count, 0)
            XCTAssertFalse(view.plusButton.accessibilityPerformPress())
        }
        XCTAssertEqual(creates, 2)
    }

    func testHostedSingleSpaceHidesIndicatorButKeepsPlusAndUpdatesAfterCreatingSpace() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WindowChromePreferences(defaults: defaults)
        preferences.tabLayout = .vertical
        preferences.showsSpaceTitle = false
        preferences.spaceIndicatorHiding = .whenSingleSpace
        let browser = model(preferences: preferences)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 220, height: 500), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        browser.window = window
        let strip = TabStrip(browser: browser, layout: .vertical, isFullScreen: false, hoverCardTabID: .constant(nil))
        let host = NSHostingView(rootView: strip.defaultAppStorage(defaults))
        window.contentView = host
        func selector() -> SpaceSelectorView? { findSelector(host) }
        try await waitFor { selector()?.plusButton.isHidden == false && selector()?.choiceButtons.isEmpty == true }
        XCTAssertTrue(strip.showsSpaceSelector)
        preferences.showsNewSpaceButton = false
        try await waitFor { selector() == nil }
        XCTAssertFalse(strip.showsSpaceSelector)
        XCTAssertEqual(strip.sidebarSpaceControlsHeight, 0)
        _ = try browser.spaces.createSpace(title: "Work")
        try await waitFor { selector()?.choiceButtons.count == 2 }
        XCTAssertTrue(strip.showsSpaceSelector)
        XCTAssertTrue(try XCTUnwrap(selector()).plusButton.isHidden)
        preferences.spaceIndicatorHiding = .always
        try await waitFor { selector() == nil }
        preferences.spaceIndicatorHiding = .never
        try await waitFor { selector()?.choiceButtons.count == 2 }
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testPrivateWindowNeverShowsSpaceControlsRegardlessOfPreferences() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = WindowChromePreferences(defaults: defaults)
        preferences.showsNewSpaceButton = true
        preferences.spaceIndicatorHiding = .never
        let browser = BrowserModel(chromePreferences: preferences, history: HistoryStore(file: nil),
                                   websiteDataStore: .nonPersistent(), isPrivate: true)
        let strip = TabStrip(browser: browser, layout: .vertical, isFullScreen: false, hoverCardTabID: .constant(nil))
        XCTAssertFalse(strip.showsSpaceSelector)
        XCTAssertEqual(strip.sidebarSpaceControlsHeight, 0)
    }

    private func model(preferences: WindowChromePreferences) -> BrowserModel {
        BrowserModel(chromePreferences: preferences, history: HistoryStore(file: nil), websiteDataStore: .nonPersistent(),
                     spaces: BrowserSpaceStore(directory: .temporaryDirectory.appending(path: UUID().uuidString), enabled: false))
    }
    private func findSelector(_ root: NSView) -> SpaceSelectorView? {
        (root as? SpaceSelectorView) ?? root.subviews.lazy.compactMap { self.findSelector($0) }.first
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < end else { XCTFail("Space visibility did not update"); throw WaitFailure.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private enum WaitFailure: Error { case timeout }
}
