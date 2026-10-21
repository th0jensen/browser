import WebKit

/// A conservative archive-only signal. This does not claim that WebKit history saves page-local work.
enum ArchivePageWork: Equatable {
    case unknown, readOnly, protected
}

@MainActor
final class ArchivePageWorkObserver: NSObject, WKScriptMessageHandler {
    static let shared = ArchivePageWorkObserver()
    private static let world = WKContentWorld.world(name: "BrowserArchiveWork")
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let pages = NSMapTable<WKWebView, WorkState>.weakToStrongObjects()
    private final class WorkState: NSObject {
        weak var tab: BrowserTab?
        var documentID: String?
        var protected = false
        init(tab: BrowserTab) { self.tab = tab }
    }

    func install(in webView: WKWebView, tab: BrowserTab) {
        pages.setObject(WorkState(tab: tab), forKey: webView)
        let controller = webView.configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.add(self, contentWorld: Self.world, name: "browserArchiveWork")
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: Self.world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let view = message.webView,
              let body = message.body as? [String: Any], let token = body["documentID"] as? String,
              let blocked = body["blocked"] as? Bool else { return }
        receive(in: view, documentID: token, blocked: blocked)
    }

    func navigationStarted(in view: WKWebView) {
        guard let state = pages.object(forKey: view) else { return }
        state.documentID = nil
        state.protected = false
        state.tab?.archivePageWork = .unknown
    }

    /// Only a probe can bind a new document. Late messages from the previous one cannot poison it.
    func receive(in view: WKWebView, documentID: String, blocked: Bool) {
        guard let state = pages.object(forKey: view), let tab = state.tab, tab.webView === view,
              state.documentID == documentID, blocked else { return }
        state.protected = true
        tab.archivePageWork = .protected
    }

    func documentID(in view: WKWebView) -> String? { pages.object(forKey: view)?.documentID }

    /// Re-read the event-driven state, not page text. No polling, frame traversal, or page-world hooks.
    func confirm(_ tab: BrowserTab) async -> Bool {
        guard let view = tab.webView else { return true }
        guard let state = pages.object(forKey: view), state.tab === tab else { return false }
        let revision = tab.navigationRevision
        let result = try? await view.evaluateJavaScript(
            "globalThis.__browserArchiveWork ?? null", contentWorld: Self.world) as? [String: Any]
        guard tab.webView === view, tab.navigationRevision == revision else { return false }
        guard let result, let token = result["documentID"] as? String, let blocked = result["blocked"] as? Bool else {
            tab.archivePageWork = .unknown
            return false
        }
        if state.documentID != token { state.documentID = token; state.protected = blocked }
        else { state.protected = state.protected || blocked }
        tab.archivePageWork = state.protected ? .protected : .readOnly
        return !state.protected
    }

    static let script = """
    (() => {
        const state = { blocked: true, documentID: String(performance.timeOrigin) + ':' + Math.random() };
        globalThis.__browserArchiveWork = state;
        let changed = false;
        const send = () => window.webkit.messageHandlers.browserArchiveWork.postMessage(state);
        const protect = () => {
            if (changed) return;
            changed = true; state.blocked = true; observer.disconnect(); send();
        };
        // Cumulative, fail-closed work budgets. Never allocate a page-wide array, read page text,
        // traverse frames/shadow trees, or hook page-world code. Exhaustion means unknown work.
        let nodesLeft = 8192, elementsLeft = 4096, attributesLeft = 16384, charactersLeft = 262144, recordsLeft = 2048;
        const selector = 'script,canvas,input,textarea,select,form,[contenteditable]:not([contenteditable="false"]),[role="textbox"],[role="application"],iframe,frame,object,embed,animate,animateTransform,animateMotion,set';
        const inspectAttribute = (name, value) => {
            if (changed) return;
            if (--attributesLeft < 0 || name.length > 256 || (value?.length ?? 0) > 8192) { protect(); return; }
            charactersLeft -= name.length + (value?.length ?? 0);
            if (charactersLeft < 0) { protect(); return; }
            // Inspect every handler name, including SVG/XML case variants and future event types.
            if (name.toLowerCase().startsWith('on')) { protect(); return; }
            // Inspect values regardless of attribute/namespace: href, xlink:href, SVG animation targets,
            // and future URI-bearing attributes must not silently introduce executable documents/code.
            const normalized = (value ?? '').replace(/[\\u0000-\\u0020\\u007f]/g, '').toLowerCase();
            if (/^(javascript|vbscript|data|blob):/.test(normalized)) protect();
        };
        const inspectElement = element => {
            if (changed) return;
            if (--elementsLeft < 0 || element.localName.length > 256 ||
                element.attributes.length > attributesLeft) { protect(); return; }
            if (element.localName.toLowerCase() === 'script' || element.matches(selector) ||
                element.localName.includes('-') || element.shadowRoot !== null) { protect(); return; }
            for (let index = 0; index < element.attributes.length && !changed; index++) {
                const attribute = element.attributes[index];
                inspectAttribute(attribute.name, attribute.value);
            }
        };
        const inspect = root => {
            if (changed) return;
            if (--nodesLeft < 0) { protect(); return; }
            if (root.nodeType === Node.ELEMENT_NODE) inspectElement(root);
            const walker = document.createTreeWalker(root, NodeFilter.SHOW_ALL);
            let node;
            while (!changed && (node = walker.nextNode())) {
                if (--nodesLeft < 0) { protect(); break; }
                if (node.nodeType === Node.ELEMENT_NODE) inspectElement(node);
            }
        };
        const observer = new MutationObserver(records => {
            if (changed) return;
            recordsLeft -= records.length;
            if (recordsLeft < 0) { protect(); return; }
            for (const record of records) {
                if (changed) break;
                if (record.type === 'attributes') {
                    // No attributeFilter: a handler installed then removed in the same turn still protects.
                    inspectAttribute(record.attributeName, record.oldValue);
                    inspectElement(record.target);
                } else {
                    // Removed nodes retain evidence of scripts executed and removed before this callback.
                    for (const nodes of [record.addedNodes, record.removedNodes]) {
                        for (const node of nodes) {
                            if (changed) break;
                            inspect(node);
                        }
                    }
                }
            }
        });
        observer.observe(document, {subtree: true, childList: true, attributes: true, attributeOldValue: true});
        // Arrow keys, wheel, composition, and other non-text editing do not necessarily emit input events.
        for (const name of ['beforeinput', 'input', 'change', 'paste', 'cut', 'drop', 'submit', 'reset',
                            'pointerdown', 'mousedown', 'touchstart', 'keydown', 'wheel', 'compositionstart']) {
            addEventListener(name, protect, true);
        }
        addEventListener('DOMContentLoaded', () => {
            inspect(document);
            if (!changed) state.blocked = false;
            send();
        }, {once: true});
        addEventListener('pageshow', e => { if (e.persisted) protect(); });
    })();
    """
}
