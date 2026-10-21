import AppKit
import SwiftUI

/// Routes external web links with explicit host rules. Files and unmatched links keep ordinary-window behavior.
@MainActor
final class ExternalURLRouter {
    static let shared = ExternalURLRouter()

    private var browsers: [WeakBrowser] = []
    private var pendingURLs: [URL] = []
    private var isOpeningWindow = false
    private var isDraining = false
    private var requestWindow: (() -> Void)?
    private let rules: LinkRouteRuleStore
    private let orderBrowsers: ([BrowserModel]) -> [BrowserModel]
    private let activate: (BrowserModel) -> Void
    private let openTabs: (BrowserModel, [URL]) -> Void

    private struct WeakBrowser {
        weak var browser: BrowserModel?
    }

    init(rules: LinkRouteRuleStore = .shared, requestWindow: (() -> Void)? = nil,
         orderBrowsers: @escaping ([BrowserModel]) -> [BrowserModel] = { browsers in
             let windows = NSApp.orderedWindows
             return browsers.sorted { left, right in
                 (windows.firstIndex { $0 === left.window } ?? .max)
                     < (windows.firstIndex { $0 === right.window } ?? .max)
             }
         },
         activate: @escaping (BrowserModel) -> Void = { browser in
             if let window = browser.window {
                 if window.isMiniaturized { window.deminiaturize(nil) }
                 window.makeKeyAndOrderFront(nil)
             }
             NSApp.activate()
         },
         openTabs: @escaping (BrowserModel, [URL]) -> Void = { $0.openInNewTabs($1) }) {
        self.rules = rules
        self.requestWindow = requestWindow
        self.orderBrowsers = orderBrowsers
        self.activate = activate
        self.openTabs = openTabs
    }

    /// Web pages and local files open; other schemes, like `javascript:`, are ignored.
    static func canOpen(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "http", "https": url.host()?.isEmpty == false
        case "file": url.isFileURL
        default: false
        }
    }

    private static func isOrdinary(_ browser: BrowserModel) -> Bool {
        !browser.isPrivate && !browser.isExtensionWindow && !browser.isClosed
    }

    /// A private, extension, or closed window never takes links from other apps.
    static func destination(among browsers: [BrowserModel]) -> BrowserModel? {
        browsers.first(where: isOrdinary)
    }

    /// Restoration runs before registration. Repeated registration never opens a queued URL twice.
    func register(_ browser: BrowserModel, openWindow: OpenWindowAction? = nil) {
        if let openWindow { requestWindow = { openWindow(id: BrowserApp.windowID) } }
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
        guard Self.isOrdinary(browser) else {
            // A requested ordinary scene can close before its late appearance callback.
            if browser.isClosed { isOpeningWindow = false }
            openPendingWindowIfNeeded()
            return
        }
        browsers.append(WeakBrowser(browser: browser))
        isOpeningWindow = false
        drain(activating: false)
    }

    func unregister(_ browser: BrowserModel) {
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
        if !pendingURLs.isEmpty { drain(activating: false) }
    }

    func open(_ urls: [URL]) {
        pendingURLs += urls.filter(Self.canOpen)
        drain(activating: true)
    }

    private func orderedOrdinaryBrowsers() -> [BrowserModel] {
        orderBrowsers(browsers.compactMap(\.browser)).filter(Self.isOrdinary)
    }

    private func drain(activating: Bool) {
        guard !isDraining else { return }
        isDraining = true
        // In a mixed batch, an unmatched link must not inherit a previous rule's Space selection.
        var fallbackSpaces: [ObjectIdentifier: UUID] = [:]
        var lastDestination: BrowserModel?
        while let url = pendingURLs.first {
            let ordinary = orderedOrdinaryBrowsers()
            guard let fallback = ordinary.first else { break }
            for browser in ordinary where fallbackSpaces[ObjectIdentifier(browser)] == nil {
                fallbackSpaces[ObjectIdentifier(browser)] = browser.activeSpaceID
            }
            var destination = fallback
            var selectedRule = false
            if let rule = rules.firstMatch(for: url),
               let target = ordinary.first(where: { browser in
                   guard let space = browser.spaces.space(rule.destinationSpaceID) else { return false }
                   return space.profileID == browser.profileID && browser.websiteDataStore(forProfileID: space.profileID) != nil
               }), target.selectSpace(rule.destinationSpaceID) {
                destination = target
                selectedRule = true
            }
            if !selectedRule, let spaceID = fallbackSpaces[ObjectIdentifier(fallback)] {
                _ = fallback.selectSpace(spaceID)
            }
            // There is no suspension between validation and opening. Recheck after Space selection callbacks.
            guard Self.isOrdinary(destination) else { continue }
            // Remove before calling out, so registration or another open cannot replay this URL.
            pendingURLs.removeFirst()
            openTabs(destination, [url])
            lastDestination = destination
        }
        isDraining = false
        if activating, let lastDestination, Self.isOrdinary(lastDestination) { activate(lastDestination) }
        openPendingWindowIfNeeded()
    }

    private func openPendingWindowIfNeeded() {
        if !pendingURLs.isEmpty, let requestWindow, !isOpeningWindow {
            isOpeningWindow = true
            requestWindow()
        }
    }
}
