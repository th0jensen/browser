import WebKit
import XCTest
@testable import Browser

@MainActor
final class BundledDarkExtensionTests: XCTestCase {
    func testBundledRegistrationPreservesIdentityAndEnablement() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let store = BrowserExtensions(directory: directory, persistent: false, bundledDirectory: resources)
        let item = try XCTUnwrap(store.installed.first)
        XCTAssertEqual(item.bundledResource, "ForcedDark")
        XCTAssertFalse(item.isEnabled, "Bundled extensions use the normal permission and enablement flow")
        try await store.load(item, askPermission: false)
        XCTAssertTrue(store.context(for: item)?.isLoaded == true)
        var enabled = try XCTUnwrap(store.installed.first)
        enabled.isEnabled = true
        try JSONEncoder().encode([enabled]).write(to: directory.appending(path: "extensions.json"))
        let reopened = BrowserExtensions(directory: directory, persistent: false, bundledDirectory: resources)
        XCTAssertEqual(reopened.installed.count, 1)
        XCTAssertEqual(reopened.installed.first?.id, item.id)
        XCTAssertEqual(reopened.installed.first?.isEnabled, true)
    }

    func testDarkSurfacesDynamicContentImagesAndLivePreferences() async throws {
        let store = BrowserExtensions.shared
        let source = try XCTUnwrap(Bundle.main.resourceURL).appending(path: "ForcedDark", directoryHint: .isDirectory)
        try await store.importResources(from: source)
        let item = try XCTUnwrap(store.installed.last)
        defer { store.remove(item) }
        try await store.load(item, askPermission: false)
        let context = try XCTUnwrap(store.context(for: item))
        let browser = BrowserModel(configuration: try XCTUnwrap(context.webViewConfiguration))
        store.register(browser)
        defer { store.unregister(browser) }
        let menu = try XCTUnwrap(browser.activeTab)
        menu.load(context.baseURL.appending(path: "popup.html"))
        let menuView = try XCTUnwrap(menu.webView)
        try await waitFor(menuView, "document.querySelector('#enabled')?.disabled === false")
        browser.addTab()
        let page = try XCTUnwrap(browser.activeTab)
        page.isNewTab = false
        page.restore()
        let webView = try XCTUnwrap(page.webView)
        webView.loadHTMLString("""
        <html><head><style>
          body { background:white; color:#222; }
          #dark { background:#102020; color:white; }
          #pseudo::before { content:'Generated'; background:white; color:black; }
          #gradient { background:linear-gradient(white, #eee); }
          #decoration { background:white url(icon.svg) no-repeat right center; color:#222; }
          #photoText { background:white url(photo.jpg) center / cover; color:white; }
        </style></head><body><p id="text">Readable</p><div id="dark">Already dark</div>
        <div id="decoration">Decorated card</div><div id="photoText">On a photo</div>
        <div id="pseudo"></div><div id="gradient">Gradient</div>
        <img id="photo" src="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'/%3E">
        <div id="shadow"></div>
        <script>document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<p style="background:white;color:black">Shadow</p>';</script>
        </body></html>
        """, baseURL: URL(string: "https://example.com/")!)
        try await waitFor(webView, "getComputedStyle(document.body).backgroundColor === 'rgb(18, 18, 18)'")
        try await check(webView, "getComputedStyle(document.querySelector('#text')).color !== 'rgb(34, 34, 34)'")
        try await check(webView, "getComputedStyle(document.querySelector('#dark')).color === 'rgb(255, 255, 255)'")
        try await check(webView, "getComputedStyle(document.querySelector('#dark')).backgroundColor === 'rgb(16, 32, 32)'")
        try await check(webView, "getComputedStyle(document.querySelector('#photo')).filter === 'none'")
        try await check(webView, "getComputedStyle(document.querySelector('#pseudo'),'::before').backgroundColor === 'rgb(18, 18, 18)'")
        try await check(webView, "!getComputedStyle(document.querySelector('#gradient')).backgroundImage.includes('255, 255, 255')")
        try await check(webView, "getComputedStyle(document.querySelector('#shadow').shadowRoot.querySelector('p')).backgroundColor === 'rgb(18, 18, 18)'")
        _ = try await webView.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend','<div id=dynamic style=background:white>New</div>'); 0")
        try await waitFor(webView, "getComputedStyle(document.querySelector('#dynamic')).backgroundColor === 'rgb(18, 18, 18)'")
        try await check(webView, "getComputedStyle(document.querySelector('#decoration')).color !== 'rgb(34, 34, 34)'")
        try await check(webView, "getComputedStyle(document.querySelector('#photoText')).color === 'rgb(255, 255, 255)'")
        _ = try await webView.evaluateJavaScript("document.querySelector('#text').removeAttribute('data-browser-forced-dark'); 0")
        try await waitFor(webView, "document.querySelector('#text').hasAttribute('data-browser-forced-dark')")
        _ = try await menuView.evaluateJavaScript("document.querySelector('[data-color=\"#181c20\"]').click(); 0")
        try await waitFor(webView, "getComputedStyle(document.body).backgroundColor === 'rgb(24, 28, 32)'")
        _ = try await menuView.evaluateJavaScript("document.querySelector('#enabled').click(); 0")
        try await waitFor(webView, "getComputedStyle(document.body).backgroundColor === 'rgb(255, 255, 255)'")
        try await check(webView, "document.querySelector('#dynamic').getAttribute('style') === 'background:white'")
        _ = try await menuView.evaluateJavaScript("document.querySelector('#enabled').click(); 0")
        try await waitFor(webView, "getComputedStyle(document.body).backgroundColor === 'rgb(24, 28, 32)'")
        _ = try await webView.evaluateJavaScript("document.body.style.backgroundColor = 'lab(97.194298 1.38536 0.498641)'; document.body.style.color = 'lab(2.33353 10.3966 3.72023)'; 0")
        try await waitFor(webView, "getComputedStyle(document.body).backgroundColor.startsWith('rgb(')")
        try await check(webView, "getComputedStyle(document.body).color !== 'lab(2.33353 10.3966 3.72023)'")
        try await check(webView, "getComputedStyle(document.body).scrollbarColor !== 'auto'")
        webView.loadHTMLString("""
        <html><head><meta http-equiv="Content-Security-Policy" content="style-src 'nonce-fixture'">
        <style nonce="fixture">body { background:white; color:black; }</style></head>
        <body><p>Strict CSP fixture</p></body></html>
        """, baseURL: URL(string: "https://example.com/csp")!)
        try await waitFor(webView, "document.body?.textContent.includes('Strict CSP fixture') && getComputedStyle(document.body).backgroundColor === 'rgb(24, 28, 32)'")
    }

    private func check(_ view: WKWebView, _ script: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await view.evaluateJavaScript(script) as? Bool
        XCTAssertEqual(result, true, script, file: file, line: line)
    }

    private func waitFor(_ view: WKWebView, _ script: String) async throws {
        for _ in 0..<150 {
            if (try? await view.evaluateJavaScript(script) as? Bool) == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for: \(script)")
    }
}
