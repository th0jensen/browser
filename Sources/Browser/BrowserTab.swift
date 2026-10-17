import AppKit
import Observation
import SwiftUI
import WebKit

@MainActor
@Observable
final class BrowserTab: NSObject, Identifiable {
    let id = UUID()
    /// The page's web view, or `nil` while the tab is suspended to free its memory.
    private(set) var webView: WKWebView?
    /// Hosts the web view, and the Web Inspector when it's docked, so both move together between windows and tabs.
    let contentView = NSView()
    var isNewTab = true
    var pinnedPageID: UUID?
    /// The tab whose page opened this one, so its links and pop-ups open next to each other.
    @ObservationIgnored var openerID: UUID?
    /// Whether another page's script opened this one, and can still reach it through `window.opener`.
    @ObservationIgnored var isPopUp = false
    @ObservationIgnored weak var browser: BrowserModel?
    /// Extension pages require a configuration restricted to that extension's origin.
    @ObservationIgnored var extensionOrigin: URL?
    /// When the tab was last selected, so the least recently used tabs are suspended first.
    @ObservationIgnored var lastActive = ContinuousClock.now
    var favicon: Image?
    var thumbnail: Image?

    private(set) var url: URL?
    private(set) var pageTitle = ""
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var hasOnlySecureContent = false
    private(set) var backList: [WKBackForwardListItem] = []
    private(set) var forwardList: [WKBackForwardListItem] = []
    /// Why the page couldn't load, shown in place of it until another page loads.
    private(set) var loadError: PageLoadError?
    /// Whether the failed load left the previous page behind the error, so going back shows that page.
    @ObservationIgnored private var loadErrorCoversPreviousPage = false

    @ObservationIgnored private let pageDelegate = PageDelegate()
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailCapture = ThumbnailCaptureState()
    @ObservationIgnored private var pendingThumbnail: (afterScreenUpdates: Bool, minimumAge: Duration)?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    /// The history and scroll position a suspended tab brings back when it's restored.
    @ObservationIgnored private var suspendedState: Any?
    private var faviconHost: String?
    /// Panels the page is waiting to show until the tab is selected.
    @ObservationIgnored private var selectionWaiters: [CheckedContinuation<Bool, Never>] = []

    /// Pass the configuration WebKit provides when a page opens a window, so the new page keeps its opener.
    init(configuration: WKWebViewConfiguration = BrowserTab.makeConfiguration()) {
        super.init()
        Self.prepareConfiguration(configuration)
        pageDelegate.tab = self
        install(WKWebView(frame: .zero, configuration: configuration))
    }

    /// A suspended tab for a page's saved history, such as a duplicated or reopened tab, which loads when it's selected.
    init(url: URL?, title: String, interactionState: Any?) {
        isNewTab = false
        self.url = url
        pageTitle = title
        suspendedState = interactionState
        favicon = FaviconStore.cachedIcon(for: url)
        faviconHost = url?.host()
        super.init()
        pageDelegate.tab = self
    }

    var isSuspended: Bool {
        webView == nil
    }

    /// The tab's history and scroll position, whether or not it's suspended.
    var interactionState: Any? {
        webView?.interactionState ?? suspendedState
    }

    /// Restoring keeps the suspended page's state until the new web view reports its own, which it only does
    /// once the page starts loading, so the tab's title and address don't flash blank.
    private func install(_ webView: WKWebView, isRestoring: Bool = false) {
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = true
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)
        webView.navigationDelegate = pageDelegate
        webView.uiDelegate = pageDelegate
        self.webView = webView
        BrowserExtensions.shared.updateRules(in: webView)

        let options: NSKeyValueObservingOptions = isRestoring ? [] : .initial
        observe(webView, \.url, options, updatesHistory: true) { tab, webView in
            tab.thumbnailCapture.invalidate()
            tab.url = tab.loadError?.url ?? webView.url
            BrowserExtensions.shared.didChange(.URL, for: tab)
            // Same-document navigations don't load, but can still change the icon.
            if !webView.isLoading { tab.updateFavicon() }
        }
        observe(webView, \.title, options) {
            $0.pageTitle = $1.title ?? ""
            BrowserExtensions.shared.didChange(.title, for: $0)
        }
        observe(webView, \.isLoading, options, updatesHistory: true) { tab, webView in
            let didFinish = tab.isLoading && !webView.isLoading
            if !tab.isLoading && webView.isLoading { tab.thumbnailCapture.invalidate() }
            tab.isLoading = webView.isLoading
            BrowserExtensions.shared.didChange(.loading, for: tab)
            if didFinish {
                tab.scheduleThumbnail()
                tab.updateFavicon()
            }
        }
        observe(webView, \.estimatedProgress, options) { $0.estimatedProgress = $1.estimatedProgress }
        observe(webView, \.canGoBack, options, updatesHistory: true) { $0.canGoBack = $1.canGoBack }
        observe(webView, \.canGoForward, options, updatesHistory: true) { $0.canGoForward = $1.canGoForward }
        observe(webView, \.hasOnlySecureContent, options) { $0.hasOnlySecureContent = $1.hasOnlySecureContent }
    }

    /// Releases the web view, and with it the page's memory, keeping what the tab strip shows and the state to restore.
    func suspend() {
        guard let webView, !isNewTab else { return }
        stopWaitingForSelection()
        suspendedState = webView.interactionState
        observations.forEach { $0.invalidate() }
        observations = []
        thumbnailTask?.cancel()
        thumbnailCapture.invalidate(cancelCapture: true)
        pendingThumbnail = nil
        faviconTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
        isLoading = false
    }

    /// Recreates a suspended tab's web view with its history and scroll position, or loads its address.
    /// A pop-up gets a fresh configuration too, since its tie to the opener can't be restored.
    func restore() {
        guard isSuspended else { return }
        let context = url.flatMap { BrowserExtensions.shared.controller.extensionContext(for: $0) }
        extensionOrigin = context?.baseURL
        let webView = WKWebView(frame: .zero, configuration: context?.webViewConfiguration ?? Self.makeConfiguration())
        install(webView, isRestoring: true)
        if let suspendedState {
            webView.interactionState = suspendedState
        } else if let url {
            webView.load(URLRequest(url: url))
        }
        suspendedState = nil
    }

    /// Whether suspending would lose nothing the page is doing: loading, showing an error or waiting to show a panel,
    /// using the camera or microphone, or being inspected. Pages with unsaved form input aren't detected, since WebKit
    /// has no cheap way to ask; their history still restores.
    var canSuspend: Bool {
        guard let webView, !isNewTab, !isLoading, loadError == nil, selectionWaiters.isEmpty else { return false }
        #if DEBUG
        if WebInspector.isOpen(for: webView) { return false }
        #endif
        return webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none
    }

    /// Waits until the tab is selected, so a background page's panel can't take over the window.
    /// Returns `false` if the tab is closed or suspended first.
    func waitUntilSelected() async -> Bool {
        guard let browser else { return false }
        if browser.activeTabID == id { return true }
        return await withCheckedContinuation { selectionWaiters.append($0) }
    }

    func didBecomeSelected() {
        resumeSelectionWaiters(true)
    }

    func stopWaitingForSelection() {
        resumeSelectionWaiters(false)
    }

    private func resumeSelectionWaiters(_ isSelected: Bool) {
        let waiters = selectionWaiters
        selectionWaiters = []
        waiters.forEach { $0.resume(returning: isSelected) }
    }

    /// WebKit only answers this asynchronously, so it's checked separately from `canSuspend`.
    func isPlayingMedia() async -> Bool {
        await webView?.requestMediaPlaybackState() == .playing
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        prepareConfiguration(configuration)
        return configuration
    }

    /// Apply browser settings to WebKit-provided pop-up and extension configurations as well as ordinary tabs.
    /// Keep the supplied process pool, data store and content controller so opener and extension messaging survive.
    private static func prepareConfiguration(_ configuration: WKWebViewConfiguration) {
        applyBrowserPreferences(to: configuration)
        BrowserExtensions.shared.configure(configuration)
    }

    /// Also used for extension background pages, so network requests keep the same browser identity.
    static func applyBrowserPreferences(to configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = BrowserProfile.websiteDataStore
        configuration.applicationNameForUserAgent = safariApplicationName
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isTextInteractionEnabled = true
        #if DEBUG
        WebInspector.enableDeveloperExtras(in: configuration)
        #endif
    }

    /// Safari's installed version is stable during a browser session; resolve its bundle once for every tab.
    private static let safariApplicationName: String = {
        let safariURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
        let safariVersion = safariURL.flatMap { Bundle(url: $0)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
            ?? "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
        return "Version/\(safariVersion) Safari/605.1.15"
    }()

    /// Mirrors a KVO-observable web view property into observable state.
    private func observe<Value>(_ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>,
                                _ options: NSKeyValueObservingOptions,
                                updatesHistory: Bool = false,
                                update: @escaping @MainActor (BrowserTab, WKWebView) -> Void) {
        observations.append(webView.observe(keyPath, options: options) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                update(self, webView)
                if updatesHistory { self.updateHistory() }
            }
        })
    }

    /// Navigation changes URL, loading or back/forward availability. Progress, title and secure-content updates
    /// don't change the list, so they don't need to copy its arrays on every notification.
    private func updateHistory() {
        guard let list = webView?.backForwardList else { return }
        let back = list.backList
        let forward = list.forwardList
        if backList != back { backList = back }
        if forwardList != forward { forwardList = forward }
    }

    var title: String {
        if !pageTitle.isEmpty { return pageTitle }
        return url?.host() ?? "New Tab"
    }

    var host: String? {
        url?.host()
    }

    var isSecure: Bool {
        url?.scheme == "https" && hasOnlySecureContent && loadError == nil
    }

    /// Going back from an error that covers the previous page shows that page, which is still the current history item.
    var canNavigateBack: Bool {
        canGoBack || (loadError != nil && loadErrorCoversPreviousPage)
    }

    func load(_ url: URL) {
        thumbnailCapture.invalidate()
        isNewTab = false
        restore()
        let controller = BrowserExtensions.shared.controller
        let oldContext = extensionOrigin.flatMap { controller.extensionContext(for: $0) }
        let newContext = controller.extensionContext(for: url)
        if oldContext !== newContext {
            // WebKit forbids ordinary web pages in an extension-owned configuration, and vice versa.
            suspend()
            suspendedState = nil
            install(WKWebView(frame: .zero, configuration: newContext?.webViewConfiguration ?? Self.makeConfiguration()))
        }
        extensionOrigin = newContext?.baseURL
        self.url = url
        pageDelegate.isLoadingFromBrowser = true
        webView?.load(URLRequest(url: url))
    }

    func reload() {
        if loadError != nil {
            retry()
        } else if let webView {
            pageDelegate.isLoadingFromBrowser = true
            webView.reload()
        } else {
            restore()
        }
    }

    func goBack() {
        if loadError != nil, loadErrorCoversPreviousPage {
            clearLoadError()
        } else {
            webView?.goBack()
        }
    }

    func showLoadError(_ error: PageLoadError, coversPreviousPage: Bool) {
        loadError = error
        loadErrorCoversPreviousPage = coversPreviousPage
        url = error.url ?? url
    }

    func clearLoadError() {
        guard loadError != nil else { return }
        loadError = nil
        loadErrorCoversPreviousPage = false
        url = webView?.url
    }

    /// Loads the address that failed again, keeping the error up until a page loads.
    func retry() {
        guard let webView else { return }
        pageDelegate.isLoadingFromBrowser = true
        if let url = loadError?.url {
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    /// Captures the visible page for hover cards. Only a web view that's on screen has anything to capture.
    func captureThumbnail(afterScreenUpdates: Bool = true, minimumAge: Duration = .zero) {
        guard !isNewTab, let webView, webView.window != nil,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        guard let request = thumbnailCapture.begin(minimumAge: minimumAge) else {
            if thumbnailCapture.isCapturing {
                pendingThumbnail = (afterScreenUpdates, minimumAge)
            }
            return
        }
        let capturedURL = webView.url
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = 520
        configuration.afterScreenUpdates = afterScreenUpdates
        webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, _ in
            guard let self else { return }
            let isCurrent = webView != nil && self.webView === webView && webView?.url == capturedURL
            if self.thumbnailCapture.complete(request, capturedImage: image != nil && isCurrent), let image {
                self.thumbnail = Image(nsImage: image)
            }
            if let pending = self.pendingThumbnail {
                self.pendingThumbnail = nil
                self.captureThumbnail(afterScreenUpdates: pending.afterScreenUpdates, minimumAge: pending.minimumAge)
            }
        }
    }

    private func scheduleThumbnail() {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.captureThumbnail()
        }
    }

    /// Reads the icon from the loaded page, showing the host's last known icon until then.
    private func updateFavicon() {
        faviconTask?.cancel()
        guard let url, let host = url.host(), url.scheme == "http" || url.scheme == "https" else {
            favicon = nil
            faviconHost = nil
            return
        }
        if faviconHost != host {
            faviconHost = host
            favicon = FaviconStore.cachedIcon(for: url)
        }
        faviconTask = Task { [weak self] in
            // Pages often set their icon from script just after loading or changing their URL.
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, let webView, !webView.isLoading, webView.url == url else { return }
            let candidates = await FaviconStore.candidates(in: webView)
            guard let icon = await FaviconStore.icon(forPage: url, candidates: candidates),
                  !Task.isCancelled, self.url == url else { return }
            favicon = icon
        }
    }
}

/// Keeps snapshots bounded and prevents an older navigation from replacing a newer page's preview.
struct ThumbnailCaptureState {
    struct Request: Equatable {
        fileprivate let id = UUID()
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var activeRequest: Request?
    private var lastCapture: ContinuousClock.Instant?

    var isCapturing: Bool { activeRequest != nil }

    mutating func invalidate(cancelCapture: Bool = false) {
        generation &+= 1
        lastCapture = nil
        if cancelCapture { activeRequest = nil }
    }

    mutating func begin(minimumAge: Duration, now: ContinuousClock.Instant = .now) -> Request? {
        guard activeRequest == nil else { return nil }
        if let lastCapture, now - lastCapture < minimumAge { return nil }
        let request = Request(generation: generation)
        activeRequest = request
        return request
    }

    mutating func complete(_ request: Request, capturedImage: Bool,
                           now: ContinuousClock.Instant = .now) -> Bool {
        guard activeRequest == request else { return false }
        activeRequest = nil
        guard request.generation == generation, capturedImage else { return false }
        lastCapture = now
        return true
    }
}

/// Shows one of several page views, such as the active tab's, inside a view this app owns.
/// Swapping the subview never reloads the page, and AppKit guarantees a view has only one superview.
struct PageHost: NSViewRepresentable {
    let content: NSView

    func makeNSView(context: Context) -> PageHostView {
        PageHostView()
    }

    func updateNSView(_ view: PageHostView, context: Context) {
        view.show(content)
    }
}

final class PageHostView: NSView {
    func show(_ content: NSView) {
        guard content.superview !== self else { return }
        subviews.forEach { $0.removeFromSuperview() }
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }
}
