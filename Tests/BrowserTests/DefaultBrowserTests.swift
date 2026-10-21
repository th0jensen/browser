import XCTest
@testable import Browser

@MainActor
final class DefaultBrowserTests: XCTestCase {
    func testAppDeclaresWebLinksAndHTMLFiles() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let urlTypes = try XCTUnwrap(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(Set(schemes), ["http", "https"])

        let documentTypes = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let contentTypes = documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertEqual(Set(contentTypes), ["public.html", "public.xhtml"])
    }

    func testOnlyWebPagesAndFilesOpenFromOtherApps() {
        XCTAssertTrue(ExternalURLRouter.canOpen(URL(string: "https://swift.org/blog")!))
        XCTAssertTrue(ExternalURLRouter.canOpen(URL(string: "HTTP://example.com")!))
        XCTAssertTrue(ExternalURLRouter.canOpen(URL(filePath: "/tmp/page.html")))

        XCTAssertFalse(ExternalURLRouter.canOpen(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(ExternalURLRouter.canOpen(URL(string: "data:text/html,hi")!))
        XCTAssertFalse(ExternalURLRouter.canOpen(URL(string: "mailto:someone@example.com")!))
        XCTAssertFalse(ExternalURLRouter.canOpen(URL(string: "https:")!))
    }

    func testLinksOpenInTheFrontmostNormalWindow() {
        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager())
        let front = BrowserModel()
        let back = BrowserModel()

        XCTAssertTrue(ExternalURLRouter.destination(among: [privateWindow, front, back]) === front)
        XCTAssertNil(ExternalURLRouter.destination(among: [privateWindow]))
        XCTAssertNil(ExternalURLRouter.destination(among: []))

        let extensionWindow = BrowserModel()
        extensionWindow.isExtensionWindow = true
        XCTAssertTrue(ExternalURLRouter.destination(among: [extensionWindow, front]) === front)
        XCTAssertNil(ExternalURLRouter.destination(among: [extensionWindow]))
    }

    func testLinksUseABlankWindowsNewTabThenOpenNewTabs() throws {
        let browser = BrowserModel()
        browser.openInNewTabs([URL(string: "https://swift.org")!, URL(string: "https://webkit.org")!])

        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertTrue(browser.tabs.allSatisfy { !$0.isNewTab })
        XCTAssertTrue(browser.activeTab === browser.tabs.last)

        browser.openInNewTabs([URL(string: "https://example.com")!])
        XCTAssertEqual(browser.tabs.count, 3)
    }

    func testLinksWaitForANormalWindowToOpen() {
        let router = ExternalURLRouter(activate: { _ in })
        router.open([URL(string: "https://swift.org")!, URL(string: "javascript:void(0)")!])

        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager())
        router.register(privateWindow)
        XCTAssertTrue(privateWindow.isBlank)

        let browser = BrowserModel()
        router.register(browser)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertFalse(browser.isBlank)

        let later = BrowserModel()
        router.register(later)
        XCTAssertTrue(later.isBlank)
    }

    func testClosedWindowModelsAndExtensionWindowsDoNotTakeExternalLinks() {
        let router = ExternalURLRouter(activate: { _ in })
        let closed = BrowserModel()
        router.register(closed)
        router.unregister(closed)
        let extensionWindow = BrowserModel()
        extensionWindow.isExtensionWindow = true
        router.register(extensionWindow)

        router.open([URL(string: "https://swift.org")!])
        XCTAssertTrue(closed.isBlank)
        XCTAssertTrue(extensionWindow.isBlank)

        let normal = BrowserModel()
        router.register(normal)
        XCTAssertFalse(normal.isBlank)
    }

    func testExternalLinksAppendAfterExistingTabsRegardlessOfSelection() {
        let router = ExternalURLRouter(activate: { _ in })
        let browser = BrowserModel()
        let original = ["first", "second", "third"].map { URL(string: "https://routing-test.invalid/\($0)")! }
        browser.openInNewTabs(original)
        browser.activeTabID = browser.tabs[0].id
        router.register(browser)
        let incoming = ["external-a", "external-b"].map { URL(string: "https://routing-test.invalid/\($0)")! }

        router.open(incoming)

        XCTAssertEqual(browser.tabs.map(\.url), original + incoming)
        XCTAssertTrue(browser.activeTab === browser.tabs.last)
    }
}
