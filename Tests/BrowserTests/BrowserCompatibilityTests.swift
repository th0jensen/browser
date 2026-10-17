import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserCompatibilityTests: XCTestCase {
    func testTabsAdvertiseSafariCompatibleUserAgent() async throws {
        let webView = try XCTUnwrap(BrowserTab().webView)
        webView.loadHTMLString("<html><body>Ready</body></html>", baseURL: URL(string: "https://example.com")!)

        let userAgent = try await webView.evaluateJavaScript("navigator.userAgent") as? String

        XCTAssertTrue(userAgent?.contains("Version/") == true)
        XCTAssertTrue(userAgent?.contains("Safari/605.1.15") == true)
    }

    func testProvidedExtensionAndPopupConfigurationsKeepBrowserIdentity() async throws {
        let supplied = WKWebViewConfiguration()
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        supplied.webExtensionController = controller
        let tab = BrowserTab(configuration: supplied)
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertTrue(webView.configuration.webExtensionController === controller)
        webView.loadHTMLString("<html><body>Ready</body></html>", baseURL: URL(string: "https://example.com")!)
        let userAgent = try await webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertTrue(userAgent?.contains("Version/") == true)
        XCTAssertTrue(userAgent?.contains("Safari/605.1.15") == true)
    }

    func testExtensionBackgroundAndBrowsingConfigurationsUseSameUserAgent() throws {
        let background = try XCTUnwrap(BrowserExtensions.shared.controller.configuration.webViewConfiguration)
        let browsing = BrowserTab.makeConfiguration()
        XCTAssertEqual(background.applicationNameForUserAgent, browsing.applicationNameForUserAgent)
        XCTAssertTrue(background.applicationNameForUserAgent?.contains("Safari/605.1.15") == true)
    }
}
