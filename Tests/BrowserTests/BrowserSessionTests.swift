import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserSessionTests: XCTestCase {
    func testSessionSurvivesStoreRecreationWithoutLoadingBackgroundTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = BrowserModel()
        let store = BrowserSessionStore(directory: directory)
        store.restore(in: first)
        first.restoreSession(BrowserSessionSnapshot(tabs: [
            .init(url: URL(string: "https://example.com/account"), title: "Account"),
            .init(url: nil, title: "")
        ], selectedIndex: 1))
        store.save(first)

        let second = BrowserModel()
        BrowserSessionStore(directory: directory).restore(in: second)
        XCTAssertEqual(BrowserSessionSnapshot(browser: second), BrowserSessionSnapshot(browser: first))
        XCTAssertTrue(second.tabs[0].isSuspended)
        XCTAssertTrue(second.activeTab?.isNewTab == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "Session.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidSessionFallsBackToNewTabAndSelectionIsClamped() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appending(path: "Session.json"))
        let browser = BrowserModel()
        BrowserSessionStore(directory: directory).restore(in: browser)
        XCTAssertTrue(browser.activeTab?.isNewTab == true)
        browser.restoreSession(.init(tabs: [.init(url: URL(string: "javascript:alert(1)"), title: "Unsafe")], selectedIndex: 999))
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.activeTab?.isNewTab == true)
    }

    func testExtensionWindowsDoNotOverwriteTheMainSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSessionStore(directory: directory)
        let browser = BrowserModel()
        store.restore(in: browser)
        store.save(browser)
        let file = directory.appending(path: "Session.json")
        let original = try Data(contentsOf: file)
        let popup = BrowserModel()
        popup.isExtensionWindow = true
        popup.addTab()
        store.save(popup)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testBrowsingAndExtensionsUseTheSameIsolatedProfileInTests() throws {
        XCTAssertTrue(BrowserProfile.isTesting)
        XCTAssertFalse(BrowserProfile.websiteDataStore.isPersistent)
        let browsing = BrowserTab.makeConfiguration()
        let background = try XCTUnwrap(BrowserExtensions.shared.controller.configuration.webViewConfiguration)
        XCTAssertTrue(browsing.websiteDataStore === BrowserProfile.websiteDataStore)
        XCTAssertTrue(background.websiteDataStore === BrowserProfile.websiteDataStore)
        XCTAssertTrue(BrowserExtensions.shared.controller.configuration.defaultWebsiteDataStore === BrowserProfile.websiteDataStore)
    }
}
