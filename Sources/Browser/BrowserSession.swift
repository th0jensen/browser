import Foundation

struct BrowserSessionSnapshot: Codable, Equatable {
    struct Tab: Codable, Equatable {
        let url: URL?
        let title: String
        var pinnedPageID: UUID? = nil
    }
    let tabs: [Tab]
    let selectedIndex: Int

    @MainActor init(browser: BrowserModel) {
        tabs = browser.tabs.map { Tab(url: $0.isNewTab ? nil : $0.url, title: $0.pageTitle, pinnedPageID: $0.pinnedPageID) }
        selectedIndex = browser.tabs.firstIndex { $0.id == browser.activeTabID } ?? 0
    }

    init(tabs: [Tab], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }
}

/// Saves only the last focused window's tab addresses and selection. WebKit owns all authentication data.
@MainActor
final class BrowserSessionStore {
    static let shared = BrowserSessionStore(directory: BrowserProfile.directory, enabled: !BrowserProfile.isTesting)
    private let file: URL
    private let enabled: Bool
    private var hasRestored = false

    init(directory: URL, enabled: Bool = true) {
        file = directory.appending(path: "Session.json")
        self.enabled = enabled
    }

    func restore(in browser: BrowserModel) {
        guard enabled, !hasRestored, !browser.isExtensionWindow else { return }
        defer { hasRestored = true }
        if let data = try? Data(contentsOf: file), let session = try? JSONDecoder().decode(BrowserSessionSnapshot.self, from: data) {
            browser.restoreSession(session)
        }
    }

    func save(_ browser: BrowserModel) {
        guard enabled, hasRestored, !browser.isExtensionWindow,
              browser.window == nil || browser.window?.isKeyWindow == true else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(BrowserSessionSnapshot(browser: browser)).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { NSLog("Could not save Browser session: %@", error.localizedDescription) }
    }
}
