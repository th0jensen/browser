import AppKit
import WebKit

/// Handles what a tab's page asks of the browser: new windows, modifier-clicked links, downloads, load errors,
/// camera and microphone access, and JavaScript panels.
@MainActor
final class PageDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var tab: BrowserTab?
    /// Whether the main frame is loading an address the user opened from the browser, such as the address bar,
    /// rather than one the page navigated to on its own.
    var isLoadingFromBrowser = false
    private var dialogs = DialogLimiter()

    /// WebKit reports mouse buttons as a mask, like `NSEvent.pressedMouseButtons`, not as a button number.
    private static let middleButtonMask = 1 << 2

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if navigationAction.targetFrame?.isMainFrame == true {
            guard let tab else { return .cancel }
            let request = PageNavigationRequest(tab: tab, webView: webView)
            // The restored window can lay out immediately while its first navigation waits for protection.
            let protection = ContentBlocker.shared
            let extensions = tab.browser?.isPrivate == true ? nil : BrowserExtensions.shared
            let needsProtection = !protection.isPreparedForNavigation
            let needsExtensions = extensions?.isPreparedForNavigation == false
            if needsProtection && needsExtensions {
                async let rules: Void = protection.prepare()
                await extensions?.prepare()
                await rules
            } else if needsProtection {
                await protection.prepare()
            } else if needsExtensions {
                await extensions?.prepare()
            }
            guard request.isCurrent else { return .cancel }
            if tab.browser?.isPrivate != true { BrowserExtensions.shared.updateRules(in: webView) }
        }
        if navigationAction.shouldPerformDownload { return .download }
        if navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url,
           url.absoluteString != "about:blank" {
            let controller = BrowserExtensions.shared.controller
            let currentContext = tab?.extensionOrigin.flatMap { controller.extensionContext(for: $0) }
            let nextContext = controller.extensionContext(for: url)
            if currentContext !== nextContext {
                tab?.load(url)
                return .cancel
            }
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == Self.middleButtonMask,
           let tab, let browser = tab.browser {
            browser.openChildTab(of: tab, loading: navigationAction.request, select: false)
            return .cancel
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.targetFrame?.isMainFrame == true,
           let url = navigationAction.request.url, let tab, let browser = tab.browser,
           browser.shouldPeek(url, from: tab) {
            browser.openPeek(from: tab, request: navigationAction.request)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        if !navigationResponse.canShowMIMEType || disposition?.hasPrefix("attachment") == true {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        track(download, from: webView, isUserStarted: download.isUserInitiated)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        track(download, from: webView, isUserStarted: download.isUserInitiated || isLoadingFromBrowser)
        isLoadingFromBrowser = false
    }

    /// Downloads the user started with a click or from the browser go ahead. A page that starts one on its own
    /// needs the user's permission first, which is remembered for the site.
    private func track(_ download: WKDownload, from webView: WKWebView, isUserStarted: Bool) {
        guard let tab, let browser = tab.browser else { return }
        let site = webView.backForwardList.currentItem?.url.host() ?? download.originalRequest?.url?.host() ?? ""
        let permissions = browser.sitePermissions
        let confirmation: @MainActor () async -> Bool = { [weak self] in
            await permissions.decide([.downloads], on: site) {
                await self?.askToAllowDownloads(on: site, in: webView)
            }
        }
        browser.downloads.track(download, in: browser.window, sourceTitle: browser.isPrivate ? "" : tab.pageTitle, sourceURL: browser.isPrivate ? nil : tab.url, allowsIntelligence: !browser.isPrivate, confirmation: isUserStarted ? nil : confirmation)
        // A download typed into a new tab leaves no page behind, so show the new tab page again.
        if webView.backForwardList.currentItem == nil { tab.isNewTab = true }
    }

    /// `nil` when the tab closed before the user could answer.
    private func askToAllowDownloads(on site: String, in webView: WKWebView) async -> Bool? {
        let alert = NSAlert()
        alert.messageText = site.isEmpty ? "Allow this page to download files?" : "Allow “\(site)” to download files?"
        alert.informativeText = "The page is trying to download a file you didn’t click. If you allow it, "
            + "the site can download files until you quit Browser."
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        return await present(alert, in: webView).map { $0 == .alertSecondButtonReturn }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Document identity changes even when a page reload keeps the same URL.
        tab?.invalidateNavigation()
        if let tab { tab.browser?.savedTabBeganLoading(tab) }
        LinkPreviewController.shared.dismiss(for: webView)
        PagePaintObserver.shared.navigationStarted(in: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        isLoadingFromBrowser = false
        dialogs = DialogLimiter()
        tab?.clearLoadError()
        tab?.didCommitNavigation()
        PagePaintObserver.shared.navigationCommitted(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PagePaintObserver.shared.navigationFinished(in: webView)
        if let tab { tab.browser?.savedTabFinishedLoading(tab) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView, isProvisional: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView, isProvisional: false)
    }

    /// A load that fails before it commits leaves the previous page in place, so the error covers it.
    private func showLoadError(_ error: Error, in webView: WKWebView, isProvisional: Bool) {
        isLoadingFromBrowser = false
        if let tab { tab.browser?.chromeHover?.navigationFailed(in: tab.id) }
        guard let tab, let loadError = PageLoadError(error, url: webView.url) else { return }
        tab.showLoadError(loadError, coversPreviousPage: isProvisional && webView.backForwardList.currentItem != nil)
    }

    /// Asks before a page uses the camera or microphone, naming the site that wants them. The answer is kept for
    /// the site, and can be changed in Settings ▸ Site Settings.
    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let permissions: Set<SitePermissions.Permission> = switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: []
        }
        guard let browser = tab?.browser, !permissions.isEmpty, !origin.host.isEmpty else { return .deny }
        let site = origin.port == 0 ? origin.host : "\(origin.host):\(origin.port)"
        let topSite = frame.isMainFrame ? nil : webView.url?.host()
        let isAllowed = await browser.sitePermissions.decide(permissions, on: "\(origin.protocol)://\(site)") {
            [weak self] in
            await self?.askForMediaCapture(permissions, site: site, embeddedIn: topSite, in: webView)
        }
        return isAllowed ? .grant : .deny
    }

    private func askForMediaCapture(_ permissions: Set<SitePermissions.Permission>, site: String,
                                    embeddedIn topSite: String?, in webView: WKWebView) async -> Bool? {
        let devices = [permissions.contains(.camera) ? "camera" : nil,
                       permissions.contains(.microphone) ? "microphone" : nil].compactMap { $0 }
        let alert = NSAlert()
        alert.messageText = "Allow “\(site)” to use your \(devices.joined(separator: " and "))?"
        if let topSite, topSite != site {
            alert.informativeText = "It’s part of a page on “\(topSite)”."
        }
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        return await present(alert, in: webView).map { $0 == .alertSecondButtonReturn }
    }

    /// Opens pop-ups and `target="_blank"` links as tabs. WebKit loads the page into the returned
    /// web view, which must use the configuration it provides so `window.opener` keeps working.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let tab, let browser = tab.browser else { return nil }
        if webView.url?.scheme == "webkit-extension" {
            let popup = BrowserExtensions.shared.openWindow(configuration: configuration, opener: tab).activeTab
            popup?.extensionOrigin = tab.extensionOrigin
            return popup?.webView
        }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           browser.shouldPeek(url, from: tab) {
            return browser.openPeek(from: tab, configuration: configuration).webView
        }
        if navigationAction.navigationType == .linkActivated, let home = tab.pinnedHomeURL,
           let url = navigationAction.request.url, PinnedNavigation.isSameSite(url, as: home) {
            webView.load(navigationAction.request)
            return nil
        }
        return browser.openChildTab(of: tab, configuration: configuration, select: true).webView
    }

    /// Reloads the page being viewed when its web process crashes or is killed. A background page waits
    /// suspended, and loads again when it's selected.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab else { return }
        if tab.browser?.activeTabID == tab.id || tab.browser?.peek?.tab.id == tab.id {
            webView.reload()
        } else {
            tab.suspend()
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab, let browser = tab.browser else { return }
        if browser.peek?.tab.id == tab.id { browser.dismissPeek(); return }
        if tab.isPopUp, browser.tabs.count == 1, let window = browser.window {
            window.close()
        } else {
            browser.closeTab(tab.id)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        _ = await presentDialog(alert, in: webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = makeAlert(message: message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await presentDialog(alert, in: webView) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        let alert = makeAlert(message: prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return await presentDialog(alert, in: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        let response = if let window = webView.window {
            await panel.beginSheetModal(for: window)
        } else {
            panel.runModal()
        }
        return response == .OK ? panel.urls : nil
    }

    private func makeAlert(message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says:" : "\(host) says:"
        alert.informativeText = message
        return alert
    }

    /// Shows a page's JavaScript dialog, unless the user blocked the page's dialogs. From the second dialog on,
    /// the user can block the rest until the page changes.
    private func presentDialog(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse? {
        guard !dialogs.isBlocked else { return nil }
        if dialogs.offersBlocking {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Prevent this page from creating more dialogs"
        }
        let response = await present(alert, in: webView)
        dialogs.didShow(blockingMore: alert.showsSuppressionButton && alert.suppressionButton?.state == .on)
        return response
    }

    private func present(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse? {
        await tab?.present(alert, in: webView)
    }
}

/// Counts the JavaScript dialogs a page shows, so the user can block the rest once it has shown one, like Safari.
struct DialogLimiter {
    private(set) var count = 0
    private(set) var isBlocked = false

    var offersBlocking: Bool {
        count > 0
    }

    mutating func didShow(blockingMore: Bool) {
        count += 1
        if blockingMore { isBlocked = true }
    }
}
