import AppKit
import SwiftUI
import WebKit

@MainActor
final class ExtensionWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) { onClose?() }
}

extension BrowserExtensions {
    @discardableResult
    func openWindow(configuration: WKWebViewConfiguration, urls: [URL] = [],
                    frame: CGRect = .null, focus: Bool = true, opener: BrowserTab? = nil) -> BrowserModel {
        let browser = BrowserModel(downloads: opener?.browser?.downloads ?? DownloadManager(), configuration: configuration)
        browser.isExtensionWindow = true
        browser.activeTab?.extensionOrigin = urls.first
            .flatMap { BrowserExtensions.shared.controller.extensionContext(for: $0) }?.baseURL
        if let tab = browser.activeTab, let opener {
            tab.isNewTab = false
            tab.isPopUp = true
            tab.openerID = opener.id
        }
        for (index, url) in urls.enumerated() {
            if index == 0 { browser.activeTab?.load(url) }
            else { browser.open(url, inNewTab: true) }
        }
        if !urls.isEmpty { browser.selectTab(at: 0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Browser"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 440)
        window.toolbarStyle = .unifiedCompact
        let host = NSHostingController(rootView: BrowserWindow(bookmarks: BookmarkStore(), browser: browser))
        host.sizingOptions = .minSize
        window.contentViewController = host
        window.center()
        var requestedFrame = window.frame
        if frame.width.isFinite && frame.width > 0 { requestedFrame.size.width = max(680, frame.width) }
        if frame.height.isFinite && frame.height > 0 { requestedFrame.size.height = max(440, frame.height) }
        if frame.origin.x.isFinite { requestedFrame.origin.x = frame.origin.x }
        if frame.origin.y.isFinite { requestedFrame.origin.y = frame.origin.y }
        window.setFrame(requestedFrame, display: false)
        browser.window = window
        retainWindow(window, browser: browser)
        register(browser)
        if focus { window.makeKeyAndOrderFront(nil) } else { window.orderBack(nil) }
        return browser
    }
}
