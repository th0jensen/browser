import AppKit
import SwiftUI
import WebKit

@MainActor
struct PeekPage: Identifiable {
    let id = UUID()
    let openerID: UUID
    let tab: BrowserTab
    private weak var source: BrowserTab?
    private weak var sourceView: WKWebView?
    private weak var peekView: WKWebView?
    private weak var owner: BrowserModel?
    private weak var sourceWindow: NSWindow?
    private let sourceRevision: Int?
    private let websiteDataStore: WKWebsiteDataStore?

    // Defaulted for existing callers; a Peek without captured ownership cannot split.
    init(openerID: UUID, tab: BrowserTab, source: BrowserTab? = nil) {
        self.openerID = openerID
        self.tab = tab
        self.source = source
        sourceView = source?.webView
        peekView = tab.webView
        owner = source?.browser
        sourceWindow = source?.browser?.window
        sourceRevision = source?.navigationRevision
        websiteDataStore = source?.webView?.configuration.websiteDataStore
    }

    /// Use captured page/store identity, never the browser's current profile defaults.
    func sourceForSplit(in browser: BrowserModel) -> BrowserTab? {
        guard owner === browser, !browser.isClosed, !browser.isExtensionWindow,
              let source, source.id == openerID, source !== tab,
              source.browser === browser, tab.browser === browser,
              browser.activeTab === source, browser.tabs.contains(where: { $0 === source }),
              !browser.tabs.contains(where: { $0 === tab }), tab.openerID == source.id,
              source.navigationRevision == sourceRevision,
              let sourceView, source.webView === sourceView,
              let peekView, tab.webView === peekView,
              let websiteDataStore,
              sourceView.configuration.websiteDataStore === websiteDataStore,
              peekView.configuration.websiteDataStore === websiteDataStore,
              browser.window === sourceWindow,
              sourceView.window == nil || sourceView.window === sourceWindow,
              peekView.window == nil || peekView.window === sourceWindow,
              source.extensionOrigin == nil, tab.extensionOrigin == nil,
              sourceView.url?.scheme != "webkit-extension", peekView.url?.scheme != "webkit-extension"
        else { return nil }
        return source
    }
}

enum PinnedNavigation {
    static let peekEnabledKey = "openExternalLinksInPeek"

    static func isWebURL(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// Keep a site's own subdomains together without guessing public suffixes
    /// (which would incorrectly equate unrelated sites on e.g. co.uk).
    static func isSameSite(_ url: URL, as home: URL) -> Bool {
        func host(_ url: URL) -> String {
            let host = (url.host() ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        let target = host(url), origin = host(home)
        guard isWebURL(url), isWebURL(home), !target.isEmpty, !origin.isEmpty else { return false }
        return target == origin || target.hasSuffix("." + origin)
    }

    static func isHome(_ url: URL?, home: URL) -> Bool {
        guard let url else { return true }
        func normalized(_ value: URL) -> URL? {
            var parts = URLComponents(url: value, resolvingAgainstBaseURL: true)
            parts?.fragment = nil
            if parts?.path.isEmpty == true { parts?.path = "/" }
            return parts?.url
        }
        return normalized(url) == normalized(home)
    }
}

extension BrowserTab {
    var pinnedHomeURL: URL? {
        if let page = browser?.folders.item(folderPageID) { return page.url }
        return browser?.pinnedPages.items.first { $0.id == pinnedPageID }?.url
    }
    var isAwayFromPinnedPage: Bool {
        pinnedHomeURL.map { !PinnedNavigation.isHome(url, home: $0) } ?? false
    }
    func returnToPinnedPage() {
        guard let home = pinnedHomeURL else { return }
        browser?.dismissPeek()
        load(home)
    }
}

/// The same trailing action in horizontal tabs, saved rows and split members.
struct TabDismissButton: View {
    let tab: BrowserTab
    let close: () -> Void
    var body: some View {
        Button {
            if tab.isAwayFromPinnedPage { tab.returnToPinnedPage() } else { close() }
        } label: {
            Image(systemName: tab.isAwayFromPinnedPage ? "minus" : "xmark")
                .font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChromeCloseButtonStyle())
        .help(tab.isAwayFromPinnedPage ? "Return to Pinned Page (⌘W)" : "Close Tab (⌘W)")
        .accessibilityLabel(tab.isAwayFromPinnedPage ? "Return to Pinned Page" : "Close \(tab.title)")
    }
}

struct PeekOverlay<Page: View>: View {
    let browser: BrowserModel
    let peek: PeekPage
    @ViewBuilder let page: (BrowserTab) -> Page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let margin = min(24.0, geometry.size.width / 12)
            let width = min(1200, max(1, (geometry.size.width - margin * 2 - 44) * 0.9))
            let height = max(1, geometry.size.height - margin * 2)
            ZStack {
                ZStack {
                    PeekBackdrop().allowsHitTesting(false)
                    Color.black.opacity(0.28)
                }.contentShape(Rectangle())
                    .onTapGesture { browser.dismissPeek() }.accessibilityHidden(true)
                HStack(alignment: .top, spacing: 12) {
                    page(peek.tab)
                        .frame(width: width, height: height)
                        .background(.background)
                        .clipShape(RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius))
                        .overlay { RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius).strokeBorder(.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
                        .shadow(color: .black.opacity(0.4), radius: 26, y: 10)
                    GlassEffectContainer(spacing: 0) {
                        VStack(spacing: 10) {
                            control("Close Peek", symbol: "xmark", action: browser.dismissPeek)
                            control("Open Peek in New Tab", symbol: "arrow.up.left.and.arrow.down.right", action: browser.expandPeek)
                            let splitReason = browser.peekSplitUnavailableReason(for: peek.id)
                            control("Open Peek in Split View", symbol: SplitOrientation.horizontal.symbol,
                                    help: splitReason, enabled: splitReason == nil) {
                                browser.splitPeek(id: peek.id)
                            }
                        }
                    }.padding(.top, 8)
                }
                .accessibilityElement(children: .contain).accessibilityLabel("Peek")
                .accessibilityAddTraits(.isModal)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PeekEscapeHandler(browser: browser))
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
    }

    private func control(_ title: String, symbol: String, help: String? = nil, enabled: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32) }
            .buttonStyle(.plain).glassEffect(.regular.interactive(), in: Circle())
            .disabled(!enabled)
            .help(help ?? title).accessibilityLabel(title).accessibilityHint(help ?? title)
    }
}

private struct PeekBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

private struct PeekEscapeHandler: NSViewRepresentable {
    let browser: BrowserModel
    func makeNSView(context: Context) -> EscapeView { EscapeView() }
    func updateNSView(_ view: EscapeView, context: Context) { view.browser = browser }
    final class EscapeView: NSView {
        weak var browser: BrowserModel?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            // The native page is attached after SwiftUI's onAppear callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, let tab = self.browser?.peek?.tab, !tab.isFindBarVisible,
                      let view = tab.webView, view.window === self.window else { return }
                self.window?.makeFirstResponder(view)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, self.window === event.window, self.window?.attachedSheet == nil,
                          self.browser?.peek != nil, event.keyCode == 53,
                          event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                    if self.browser?.peek?.tab.isFindBarVisible == true { self.browser?.closeFindBar() }
                    else { self.browser?.dismissPeek() }
                    return true
                }
                return handled ? nil : event
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
