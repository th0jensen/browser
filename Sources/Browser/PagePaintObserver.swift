import WebKit

/// A one-shot, main-document FCP signal in an isolated script world. No polling,
/// page DOM access, or persistent performance recording is needed.
@MainActor
final class PagePaintObserver: NSObject, WKScriptMessageHandler {
    static let shared = PagePaintObserver()
    private static let messageName = "browserFirstContentfulPaint"
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let pages = NSMapTable<WKWebView, PaintState>.weakToStrongObjects()

    private final class PaintState: NSObject {
        weak var tab: BrowserTab?
        var documentID: String?
        var supportsPaint = true
        var committed = false
        var painted = false
        var reported = false
        init(tab: BrowserTab) { self.tab = tab }
    }

    func install(in webView: WKWebView, tab: BrowserTab) {
        pages.setObject(PaintState(tab: tab), forKey: webView)
        let controller = webView.configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.add(self, contentWorld: .defaultClient, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: .defaultClient))
    }

    func navigationStarted(in webView: WKWebView) {
        guard let tab = pages.object(forKey: webView)?.tab else { return }
        pages.setObject(PaintState(tab: tab), forKey: webView)
    }

    func navigationCommitted(in webView: WKWebView) {
        guard let state = pages.object(forKey: webView) else { return }
        state.committed = true
        if state.painted { report(state) }
    }

    func navigationFinished(in webView: WKWebView) {
        guard let state = pages.object(forKey: webView), !state.supportsPaint || state.documentID == nil else { return }
        // A document that cannot run the paint observer keeps the previous load-completion fallback.
        report(state)
    }

    func hasPainted(in webView: WKWebView) -> Bool {
        guard let state = pages.object(forKey: webView) else { return false }
        return state.painted || state.reported
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let state = pages.object(forKey: webView),
              let body = message.body as? [String: Any], let documentID = body["documentID"] as? String,
              let kind = body["kind"] as? String else { return }
        if kind == "document" {
            state.documentID = documentID
            state.supportsPaint = body["supportsPaint"] as? Bool ?? false
        } else if kind == "paint", documentID == state.documentID {
            state.painted = true
            if state.committed { report(state) }
        }
    }

    private func report(_ state: PaintState) {
        guard !state.reported else { return }
        state.reported = true
        guard let tab = state.tab, let browser = tab.browser, browser.activeTabID == tab.id else { return }
        browser.chromeHover?.navigationSucceeded(in: tab.id)
    }

    private static let script = """
    (() => {
        const documentID = String(performance.timeOrigin) + ':' + Math.random();
        const supportsPaint = typeof PerformanceObserver !== 'undefined' &&
            PerformanceObserver.supportedEntryTypes.includes('paint');
        const send = (kind) => window.webkit.messageHandlers.browserFirstContentfulPaint
            .postMessage({kind, documentID, supportsPaint});
        send('document');
        addEventListener('pageshow', event => {
            if (event.persisted) { send('document'); send('paint'); }
        });
        if (!supportsPaint) return;
        const observer = new PerformanceObserver(list => {
            if (list.getEntries().some(entry => entry.name === 'first-contentful-paint')) {
                observer.disconnect();
                send('paint');
            }
        });
        observer.observe({type: 'paint', buffered: true});
    })();
    """
}
