import WebKit
import XCTest
@testable import Browser

@MainActor
final class AppearanceTests: XCTestCase {
    private final class Loader: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }

    func testScrollbarToggleWorksWithCSPAndPreservesPageAndScrolling() async throws {
        let suite = "Browser.AppearanceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = PageAppearance(defaults: defaults)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 220), configuration: configuration)
        appearance.install(in: view)
        let loaded = expectation(description: "Page loaded")
        let loader = Loader(loaded)
        view.navigationDelegate = loader
        view.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'none'\"><title>Scroll Test</title>" + String(repeating: "<p>Scrollable content</p>", count: 150), baseURL: URL(string: "https://example.com"))
        await fulfillment(of: [loaded], timeout: 5)
        try await view.evaluateJavaScript("window.keepMe = 42")
        appearance.setScrollbarsHidden(true)
        for _ in 0..<100 {
            if (try await view.evaluateJavaScript("getComputedStyle(document.documentElement).scrollbarWidth") as? String) == "none" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let hidden = try await view.evaluateJavaScript("getComputedStyle(document.documentElement).scrollbarWidth") as? String
        XCTAssertEqual(hidden, "none")
        let position = try await view.evaluateJavaScript("window.scrollTo(0, 200); window.scrollY") as? Double
        XCTAssertGreaterThan(position ?? 0, 0)
        appearance.setScrollbarsHidden(false)
        for _ in 0..<100 {
            if (try await view.evaluateJavaScript("getComputedStyle(document.documentElement).scrollbarWidth") as? String) != "none" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let restored = try await view.evaluateJavaScript("getComputedStyle(document.documentElement).scrollbarWidth") as? String
        XCTAssertNotEqual(restored, "none")
        let retained = try await view.evaluateJavaScript("window.keepMe") as? Int
        XCTAssertEqual(retained, 42)
        XCTAssertEqual(view.title, "Scroll Test")
    }

    func testSettingIsInstalledInEveryNewDocumentAndDoesNotDuplicateScripts() {
        let suite = "Browser.AppearanceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppearancePreferences.hideScrollbarsKey)
        let appearance = PageAppearance(defaults: defaults)
        let view = WKWebView()
        appearance.install(in: view)
        appearance.install(in: view)
        for value in [false, true, false, true] { appearance.setScrollbarsHidden(value) }
        let scripts = view.configuration.userContentController.userScripts.filter { $0.source.hasPrefix(PageAppearance.script) }
        XCTAssertEqual(scripts.count, 1)
        XCTAssertFalse(scripts[0].isForMainFrameOnly)
        XCTAssertTrue(scripts[0].source.hasSuffix("window.browserSetScrollbarsHidden(true);"))
    }

    func testSplitOpacityHonorsToggleAndRejectsInvalidValues() {
        XCTAssertEqual(AppearancePreferences.splitOpacity(0.85, dimmed: true), 0.85)
        XCTAssertEqual(AppearancePreferences.splitOpacity(0.85, dimmed: false), 1)
        XCTAssertEqual(AppearancePreferences.splitOpacity(.nan, dimmed: true), 0.85)
        XCTAssertEqual(AppearancePreferences.splitOpacity(-3, dimmed: true), 0.5)
        XCTAssertEqual(AppearancePreferences.splitOpacity(3, dimmed: true), 1)
    }
}
