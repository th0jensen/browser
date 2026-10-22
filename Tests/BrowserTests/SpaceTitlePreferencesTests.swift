import AppKit
import Observation
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class SpaceTitlePreferencesTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "SpaceTitle-\(UUID())"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testTitleDefaultsToVisibleAndPersistsForFutureWindowsWithoutChangingOtherWindowsOrRelease() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WindowChromePreferences(defaults: defaults, variant: .debug)
        let second = WindowChromePreferences(defaults: defaults, variant: .debug)
        let release = WindowChromePreferences(defaults: defaults, variant: .release)
        XCTAssertTrue(first.showsSpaceTitle)
        first.showsSpaceTitle = false
        XCTAssertFalse(first.showsSpaceTitle)
        XCTAssertTrue(second.showsSpaceTitle, "Other existing windows keep their own chrome")
        XCTAssertTrue(release.showsSpaceTitle)
        XCTAssertFalse(WindowChromePreferences(defaults: defaults, variant: .debug).showsSpaceTitle)
        XCTAssertTrue(WindowChromePreferences(defaults: defaults, variant: .release).showsSpaceTitle)
        first.showsSpaceTitle = true
        XCTAssertTrue(WindowChromePreferences(defaults: defaults, variant: .debug).showsSpaceTitle)
    }

    func testProductionSidebarGatingRemovesTitleAndItsSpaceWithoutHidingSelector() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let chrome = WindowChromePreferences(defaults: defaults)
        chrome.tabLayout = .vertical
        let browser = BrowserModel(chromePreferences: chrome)
        let strip = TabStrip(browser: browser, layout: .vertical, isFullScreen: false, hoverCardTabID: .constant(nil))
        XCTAssertTrue(strip.showsSpaceTitle)
        let visibleHeight = strip.sidebarSpaceControlsHeight
        let changed = expectation(description: "Visible title observes its window preference")
        withObservationTracking { _ = strip.showsSpaceTitle } onChange: { changed.fulfill() }
        chrome.showsSpaceTitle = false
        wait(for: [changed], timeout: 1)
        XCTAssertFalse(strip.showsSpaceTitle)
        XCTAssertEqual(visibleHeight - strip.sidebarSpaceControlsHeight, 24 + BrowserChrome.edgeInset)
        XCTAssertGreaterThan(strip.sidebarSpaceControlsHeight, 0, "The bottom selector is not the title row")
        chrome.showsSpaceTitle = true
        XCTAssertTrue(strip.showsSpaceTitle)
        XCTAssertEqual(strip.sidebarSpaceControlsHeight, visibleHeight)
        let horizontal = TabStrip(browser: browser, layout: .horizontal, isFullScreen: false, hoverCardTabID: .constant(nil))
        XCTAssertFalse(horizontal.showsSpaceTitle)
        XCTAssertEqual(horizontal.sidebarSpaceControlsHeight, 0)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testTitlePreferenceDoesNotIntroduceAHeadingInPrivateOrExtensionWindows() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = [BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults), isPrivate: true),
                      BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))]
        models[1].isExtensionWindow = true
        for browser in models {
            browser.chromePreferences.showsSpaceTitle = true
            let strip = TabStrip(browser: browser, layout: .vertical, isFullScreen: false, hoverCardTabID: .constant(nil))
            XCTAssertFalse(strip.showsSpaceTitle)
            XCTAssertEqual(strip.sidebarSpaceControlsHeight, 0)
        }
    }

    func testChangingSettingsTargetOnlyChangesThatWindowsTitlePreference() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))
        let second = BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))
        let target = WindowChromeSettingsTarget()
        target.browser = first
        target.preferences.showsSpaceTitle = false
        XCTAssertFalse(first.chromePreferences.showsSpaceTitle)
        XCTAssertTrue(second.chromePreferences.showsSpaceTitle)
        target.browser = second
        XCTAssertTrue(target.preferences.showsSpaceTitle)
    }

    func testSpaceThemesDoNotPaintAFauxSidebarBackground() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let chrome = WindowChromePreferences(defaults: defaults)
        chrome.tabLayout = .vertical
        chrome.showsSpaceTitle = false
        let spaces = BrowserSpaceStore(directory: .temporaryDirectory, enabled: false)
        let browser = BrowserModel(chromePreferences: chrome, spaces: spaces)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        browser.window = window
        let host = NSHostingView(rootView: TabStrip(browser: browser, layout: .vertical, isFullScreen: false,
            hoverCardTabID: .constant(nil)).defaultAppStorage(defaults))
        host.frame = NSRect(x: 0, y: 0, width: 220, height: 500)
        window.contentView = host
        var samples: [[CGFloat]] = []
        for theme in [BrowserSpaceTheme.blue, .pink, .green] {
            try spaces.updateSpace(browser.activeSpaceID, title: "Default", icon: .circle, theme: theme)
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let color = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            samples.append([color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent])
        }
        for sample in samples.dropFirst() {
            for index in sample.indices {
                XCTAssertEqual(sample[index], samples[0][index], accuracy: 0.002,
                               "Space metadata must not add a colored backdrop over native sidebar material")
            }
        }
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testHidingAndShowingTitleDoesNotChangeFoldersSpacesSelectionOrLivePages() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let chrome = WindowChromePreferences(defaults: defaults)
        chrome.tabLayout = .vertical
        let spaces = BrowserSpaceStore(directory: .temporaryDirectory, enabled: false)
        let browser = BrowserModel(chromePreferences: chrome, spaces: spaces)
        let folders = browser.folders
        _ = try folders.createFolder(title: "Established folder", parentID: nil, symbol: "folder", emoji: "", color: .blue,
                                     initialPage: (URL(string: "https://fixture.invalid/saved")!, "Saved page"))
        let folderItems = folders.items
        _ = try browser.createSpace(title: "Work", icon: .work, theme: .system)
        let metadata = spaces.spaces
        let pages = browser.allTabs.map(ObjectIdentifier.init)
        let selection = browser.activeTabID
        let spaceID = browser.activeSpaceID
        for shown in [false, true, false] {
            chrome.showsSpaceTitle = shown
            XCTAssertEqual(folders.items, folderItems)
            XCTAssertEqual(spaces.spaces, metadata)
            XCTAssertEqual(browser.allTabs.map(ObjectIdentifier.init), pages)
            XCTAssertEqual(browser.activeTabID, selection)
            XCTAssertEqual(browser.activeSpaceID, spaceID)
            XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
        }
        chrome.tabLayout = .horizontal
        chrome.tabLayout = .vertical
        XCTAssertFalse(chrome.showsSpaceTitle)
    }
}
