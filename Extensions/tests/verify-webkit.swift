import AppKit
import WebKit

// Regression for YouTube's CSP blocking the old DOM-inserted page helper.
// Run with a folder or ZIP. Uses an isolated profile and makes no website request.
@main
struct VerifyWebKit {
    @MainActor static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        Task { @MainActor in
            do {
                try await verify()
                app.terminate(nil)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func verify() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw failure("Pass the absolute path to an extension folder or ZIP")
        }
        let resource = URL(fileURLWithPath: CommandLine.arguments[1]).absoluteURL
        let ext = try await WKWebExtension(resourceBaseURL: resource)
        guard ext.errors.isEmpty else { throw ext.errors[0] }
        let config = WKWebExtensionController.Configuration.nonPersistent()
        config.defaultWebsiteDataStore = .nonPersistent()
        let controller = WKWebExtensionController(configuration: config)
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = UUID().uuidString
        for permission in ext.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in ext.allRequestedMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        try controller.load(context)
        defer { try? controller.unload(context) }
        try await context.loadBackgroundContent()
        guard context.errors.isEmpty else { throw context.errors[0] }

        let webConfig = WKWebViewConfiguration()
        webConfig.webExtensionController = controller
        webConfig.websiteDataStore = config.defaultWebsiteDataStore
        let page = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: webConfig)
        page.loadHTMLString("""
        <!doctype html><html><head>
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'">
        </head><body><ytd-app></ytd-app></body></html>
        """, baseURL: URL(string: "https://www.youtube.com/")!)

        var passed = false
        for _ in 0..<100 {
            passed = (try? await page.evaluateJavaScript("""
                document.dispatchEvent(new CustomEvent('ytal-message', { detail: JSON.stringify({
                    contentScript: 'youtube-ambient-light-extension', type: 'update-theme', message: true
                }) }));
                document.documentElement.hasAttribute('dark')
                """)) as? Bool == true
            if passed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard passed else { throw failure("Page-world helper failed under strict CSP") }
        let scriptCount = try await page.evaluateJavaScript("document.scripts.length") as? Int
        guard scriptCount == 0 else { throw failure("The extension inserted a script tag into the page") }
        print("PASS: WebKit import, background load and page-world messaging under strict CSP")

        let extensions = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let blurSource = try String(contentsOf: extensions.appending(path: "compatibility/canvas-blur.js"), encoding: .utf8)
            .replacingOccurrences(of: "export default class CanvasBlur", with: "window.CanvasBlur = class CanvasBlur")
        _ = try await page.evaluateJavaScript(blurSource + ";void 0")
        let tests = try String(contentsOf: extensions.appending(path: "tests/canvas-blur-test.js"), encoding: .utf8)
        let result = try await page.evaluateJavaScript("JSON.stringify(" + tests + ")")
        print("PASS: Gaussian blur pixels match the reference: \(result ?? "")")
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "AmbientLightVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
