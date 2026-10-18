import AppKit
import Observation
import SwiftUI
import WebKit

/// Fetches a single public document. No browser cookies, HTTP credentials, script
/// execution, subresources, or disk cache are involved in preview generation.
actor LinkPreviewFetcher {
    static let shared = LinkPreviewFetcher()
    private let session: URLSession
    private let redirects = PreviewRedirectPolicy()
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }

    func text(at url: URL) async throws -> String {
        guard Self.isPublicWebURL(url) else { throw IntelligenceError.message("This link cannot be previewed.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = response.url, Self.isPublicWebURL(finalURL),
              ["text/html", "application/xhtml+xml", "text/plain"].contains(response.mimeType?.lowercased() ?? "") else {
            throw IntelligenceError.message("The page did not provide readable text. Open the link to view it.")
        }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            if data.count >= 128 * 1024 { break }
            data.append(byte)
        }
        try Task.checkCancellation()
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let text = Self.readableText(html)
        guard text.count >= 100 else { throw IntelligenceError.message("There isn’t enough readable text to preview this page.") }
        return String(text.prefix(6500))
    }

    nonisolated static func isPublicWebURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".test") else { return false }
        // Avoid local services and numeric/encoded IP hosts on incidental hover.
        if host.contains(":") || host.split(separator: ".").allSatisfy({ UInt($0) != nil }) { return false }
        return host != "localhost"
    }

    nonisolated static func readableText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "form", "header"] {
            text = text.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class PreviewRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(LinkPreviewFetcher.isPublicWebURL) == true ? request : nil)
    }
}

@MainActor @Observable
final class LinkPreviewState {
    let url: URL
    var result: LinkSummary?
    var error: String?
    init(url: URL) { self.url = url }
}

private struct LinkPreviewCard: View {
    let state: LinkPreviewState
    let open: () -> Void
    let hover: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text("5-second Preview").font(.system(size: 11, weight: .medium))
                Spacer()
                Text("On-device").font(.system(size: 10))
            }.foregroundStyle(.secondary)
            if let result = state.result {
                Text(result.title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                Text(result.summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            } else if let error = state.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.12)).frame(width: 185, height: 14)
                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08)).frame(height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08)).frame(width: 235, height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08)).frame(width: 155, height: 10)
                }.padding(.vertical, 8).modifier(IntelligenceShimmer(active: true))
                    .accessibilityLabel("Loading link preview")
            }
            Button(action: open) {
                HStack {
                    Text(state.url.host() ?? "Open page").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
        }.padding(16).frame(width: 320, alignment: .leading).onHover(perform: hover)
    }
}

/// Event-driven, isolated-world link tracking: no polling or model work until an
/// enabled, intentional hover. One popover and a small memory-only cache per app.
@MainActor
final class LinkPreviewController: NSObject, WKScriptMessageHandler, NSPopoverDelegate {
    static let shared = LinkPreviewController()
    private static let messageName = "browserLinkPreview"
    private static let world = WKContentWorld.world(name: "BrowserLinkPreviews")
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let views = NSHashTable<WKWebView>.weakObjects()
    private let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()
    private var enabled = UserDefaults.standard.bool(forKey: BrowserIntelligence.fiveSecondPreviewsKey)
    private(set) var presentedPreview: LinkPreviewState?
    private let summaryProvider: @Sendable (URL) async throws -> LinkSummary
    private var settingsObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var popover: NSPopover?
    private weak var sourceView: WKWebView?
    private var currentURL: URL?
    private var pointerInsideCard = false
    private var generation = UUID()
    private var cache: [URL: (Date, LinkSummary)] = [:]

    init(observesSettings: Bool = true, summaryProvider: @escaping @Sendable (URL) async throws -> LinkSummary = { url in
        await LocalIntelligence.shared.prepare(.preview)
        let text = try await LinkPreviewFetcher.shared.text(at: url)
        try Task.checkCancellation()
        return try await LocalIntelligence.shared.summarize(text: text, url: url)
    }) {
        self.summaryProvider = summaryProvider
        super.init()
        guard observesSettings else { return }
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshSetting() }
        }
    }

    func install(in view: WKWebView, tab: BrowserTab) {
        tabs.setObject(tab, forKey: view)
        views.add(view)
        let controller = view.configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.add(self, contentWorld: Self.world, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.script + "\nwindow.browserSetLinkPreviews(\(enabled));",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    }

    private func refreshSetting() {
        setEnabled(UserDefaults.standard.bool(forKey: BrowserIntelligence.fiveSecondPreviewsKey))
    }

    func setEnabled(_ next: Bool) {
        guard next != enabled else { return }
        enabled = next
        if !next { dismiss() }
        for controller in controllers.allObjects {
            let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.script) }
            controller.removeAllUserScripts()
            others.forEach { controller.addUserScript($0) }
            controller.addUserScript(WKUserScript(source: Self.script + "\nwindow.browserSetLinkPreviews(\(next));",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        }
        for view in views.allObjects {
            view.evaluateJavaScript("window.browserSetLinkPreviews?.(\(next))", in: nil, in: Self.world) { _ in }
        }
    }

    func dismiss(for view: WKWebView) { if sourceView === view { dismiss() } }
    private func dismiss() {
        generation = UUID()
        task?.cancel(); task = nil
        dismissTask?.cancel(); dismissTask = nil
        currentURL = nil
        presentedPreview = nil
        sourceView = nil
        pointerInsideCard = false
        let previous = popover; popover = nil
        previous?.close()
    }
    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === popover { dismiss() }
    }
    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, self?.pointerInsideCard == false else { return }
            self?.dismiss()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard enabled, message.frameInfo.isMainFrame, let view = message.webView,
              view.window?.isKeyWindow == true, !view.isHiddenOrHasHiddenAncestor,
              let body = message.body as? [String: Any] else { return }
        if body["leave"] as? Bool == true {
            if sourceView === view { scheduleDismiss() }
            return
        }
        guard BrowserIntelligence.unavailableReason == nil,
              let href = body["url"] as? String, let url = URL(string: href), LinkPreviewFetcher.isPublicWebURL(url),
              let x = body["x"] as? Double, let y = body["y"] as? Double,
              let width = body["width"] as? Double, let height = body["height"] as? Double,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return }
        dismissTask?.cancel()
        if currentURL == url && sourceView === view { return }
        dismiss()
        currentURL = url; sourceView = view
        let state = LinkPreviewState(url: url)
        presentedPreview = state
        let native = NSPopover()
        native.behavior = .semitransient
        native.animates = false
        native.delegate = self
        let tab = tabs.object(forKey: view)
        native.contentViewController = NSHostingController(rootView: LinkPreviewCard(state: state, open: { [weak self, weak tab] in
            self?.dismiss()
            tab?.load(url)
        }, hover: { [weak self] inside in
            self?.pointerInsideCard = inside
            if inside { self?.dismissTask?.cancel() } else { self?.scheduleDismiss() }
        }))
        popover = native
        let localY = view.isFlipped ? y : view.bounds.height - y - height
        let anchor = NSRect(x: x, y: localY, width: min(width, 300), height: height).intersection(view.bounds)
        guard !anchor.isEmpty else { dismiss(); return }
        native.show(relativeTo: anchor, of: view, preferredEdge: .maxY)
        if let (date, result) = cache[url], Date().timeIntervalSince(date) < 300 { state.result = result; return }
        let token = generation
        let summarize = summaryProvider
        task = Task { [weak self] in
            do {
                let result = try await summarize(url)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                if self.cache.count >= 16, let oldest = self.cache.min(by: { $0.value.0 < $1.value.0 })?.key { self.cache[oldest] = nil }
                self.cache[url] = (Date(), result)
                state.result = result
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self?.generation == token { state.error = "Preview unavailable. " + error.localizedDescription } }
        }
    }

    private static let script = """
    (() => {
      if (window.browserSetLinkPreviews) return;
      let enabled = false, link = null, timer = null, sent = false;
      const autoHosts = ['google.com', 'duckduckgo.com', 'bing.com', 'x.com', 'twitter.com', 'threads.net', 'threads.com', 'news.ycombinator.com'];
      const host = location.hostname.replace(/^www\\./, '');
      const automatic = autoHosts.some(h => host === h || host.endsWith('.' + h)) || /^google\\.[a-z.]+$/.test(host);
      const post = data => window.webkit.messageHandlers.browserLinkPreview.postMessage(data);
      function clear() { clearTimeout(timer); if (sent) post({leave: true}); sent = false; }
      function start(shift) {
        clear(); if (!link || (!shift && !automatic)) return;
        const candidate = link;
        timer = setTimeout(() => {
          if (link !== candidate || document.hidden) return;
          const r = candidate.getBoundingClientRect();
          post({url: candidate.href, x: r.x, y: r.y, width: r.width, height: r.height}); sent = true;
        }, 450);
      }
      function over(e) {
        if (!e.isTrusted) return;
        const next = e.target.closest?.('a[href]');
        if (next === link) return;
        clear(); link = next;
        if (link && /^https?:$/.test(new URL(link.href, location.href).protocol)) start(e.shiftKey);
      }
      function out(e) {
        if (!e.isTrusted || !link) return;
        if (!e.relatedTarget || !link.contains(e.relatedTarget)) { clear(); link = null; }
      }
      function key(e) { if (e.isTrusted && e.key === 'Shift') { if (e.type === 'keydown' && !e.repeat) start(true); else if (e.type === 'keyup' && !automatic) clear(); } }
      function stop() { clear(); link = null; }
      window.browserSetLinkPreviews = value => {
        if (enabled === value) return;
        enabled = value;
        const action = value ? 'addEventListener' : 'removeEventListener';
        document[action]('mouseover', over, true); document[action]('mouseout', out, true);
        document[action]('keydown', key, true); document[action]('keyup', key, true);
        document[action]('scroll', stop, true); document[action]('mousedown', stop, true);
        window[action]('blur', stop, true);
        if (!value) stop();
      };
    })();
    """
}
