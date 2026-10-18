import Foundation
import SwiftUI
import WebKit

enum AppearancePreferences {
    static let hideScrollbarsKey = "hideScrollbars"
    static let dimInactiveSplitsKey = "dimInactiveSplitPanes"
    static let inactiveSplitOpacityKey = "inactiveSplitOpacity"

    static func splitOpacity(_ value: Double, dimmed: Bool) -> Double {
        guard dimmed else { return 1 }
        return value.isFinite ? min(1, max(0.5, value)) : 0.85
    }
}

struct ScrollbarVisibility: ViewModifier {
    @AppStorage(AppearancePreferences.hideScrollbarsKey) private var hidden = false
    func body(content: Content) -> some View { content.scrollIndicators(hidden ? .never : .automatic) }
}

/// One lightweight stylesheet per document, including cross-origin frames.
/// Settings update open pages without navigation or changes to scrolling itself.
@MainActor
final class PageAppearance {
    static let shared = PageAppearance()
    static let world = WKContentWorld.world(name: "BrowserAppearance")
    private let defaults: UserDefaults
    private let views = NSHashTable<WKWebView>.weakObjects()
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var observer: Any?
    private(set) var hidesScrollbars: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidesScrollbars = defaults.bool(forKey: AppearancePreferences.hideScrollbarsKey)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setScrollbarsHidden(self?.defaults.bool(forKey: AppearancePreferences.hideScrollbarsKey) ?? false) }
        }
    }

    isolated deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func install(in view: WKWebView) {
        views.add(view)
        let controller = view.configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.addUserScript(userScript())
    }

    func setScrollbarsHidden(_ hidden: Bool) {
        guard hidden != hidesScrollbars else { return }
        hidesScrollbars = hidden
        for controller in controllers.allObjects {
            let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.script) }
            controller.removeAllUserScripts()
            others.forEach(controller.addUserScript)
            controller.addUserScript(userScript())
        }
        for view in views.allObjects {
            view.evaluateJavaScript("window.browserSetScrollbarsHidden?.(\(hidden));", in: nil, in: Self.world) { _ in }
        }
    }

    private func userScript() -> WKUserScript {
        WKUserScript(source: Self.script + "\nwindow.browserSetScrollbarsHidden(\(hidesScrollbars));",
                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world)
    }

    static let script = #"""
    (() => {
      if (window.browserSetScrollbarsHidden) return;
      let sheet;
      window.browserSetScrollbarsHidden = hidden => {
        if (hidden) {
          if (!sheet) {
            sheet = new CSSStyleSheet();
            sheet.replaceSync('* { scrollbar-width: none !important; } *::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }');
          }
          if (!document.adoptedStyleSheets.includes(sheet)) document.adoptedStyleSheets.push(sheet);
        } else if (sheet) {
          document.adoptedStyleSheets = document.adoptedStyleSheets.filter(value => value !== sheet);
        }
        for (let i = 0; i < window.frames.length; i++) {
          window.frames[i].postMessage({ browserScrollbarsHidden: Boolean(hidden) }, '*');
        }
      };
      window.addEventListener('message', event => {
        if (event.source === window.parent && typeof event.data?.browserScrollbarsHidden === 'boolean') {
          window.browserSetScrollbarsHidden(event.data.browserScrollbarsHidden);
        }
      });
    })();
    """#
}
