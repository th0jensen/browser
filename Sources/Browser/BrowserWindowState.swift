import SwiftUI

/// Owns one scene's model. Session metadata and queued links are installed before its first view is built.
@MainActor
final class BrowserWindowState: ObservableObject {
    let browser: BrowserModel
    private let router: ExternalURLRouter?
    private let session: SessionStore?
    private var additionalWindows: Int

    init(browser: BrowserModel, session: SessionStore? = nil, router: ExternalURLRouter? = nil,
         restoresWindows: Bool = SessionPreferences.restoresWindows) {
        self.browser = browser
        self.router = router
        self.session = session
        additionalWindows = session?.attach(browser, restoringClosedWindows: restoresWindows) ?? 0
        if browser.tabs.isEmpty { browser.addTab() }
        // Restoration comes first so external links append after all saved tabs.
        router?.register(browser)
    }

    func appear(openWindow: OpenWindowAction) {
        browser.windowDidAppear()
        _ = session?.attach(browser, restoringPendingWindows: false)
        router?.register(browser, openWindow: openWindow)
        let count = additionalWindows
        additionalWindows = 0
        for _ in 0..<count { openWindow(id: BrowserApp.windowID) }
    }

    func close() {
        router?.unregister(browser)
        session?.detach(browser)
        browser.windowDidClose()
    }
}
