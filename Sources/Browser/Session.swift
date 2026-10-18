import AppKit
import Foundation
import Observation

struct TabSession: Codable, Equatable, Sendable {
    /// `nil` for a new tab.
    var url: URL?
    var title: String
    /// The archived back-forward history and scroll position. WebKit's interaction state is an `NSData`.
    var interactionState: Data?
    var pinnedPageID: UUID? = nil
    var folderPageID: UUID? = nil
    var temporarySection: TemporaryTabSection? = nil
}

struct WindowSession: Codable, Equatable, Sendable {
    var tabs: [TabSession]
    var selectedIndex: Int
    var splits: [BrowserSessionSnapshot.Split]? = nil

    init(tabs: [TabSession], selectedIndex: Int, splits: [BrowserSessionSnapshot.Split]? = nil) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
        self.splits = splits
    }

    init(legacy: BrowserSessionSnapshot) {
        tabs = legacy.tabs.map {
            TabSession(url: $0.url, title: $0.title, interactionState: nil,
                       pinnedPageID: $0.pinnedPageID, folderPageID: $0.folderPageID,
                       temporarySection: $0.temporarySection)
        }
        selectedIndex = legacy.selectedIndex
        splits = legacy.splits
    }
}

struct SessionSnapshot: Codable, Equatable, Sendable {
    /// The windows open when the app last quit, reopened on launch.
    var windows: [WindowSession] = []
    /// The windows that were open before the last one closed, for Reopen All Windows from Last Session.
    var closedWindows: [WindowSession] = []
}

/// Saves the open windows and their tabs, and reopens them on launch. Windows join with `attach(_:)`; a window
/// that shouldn't be remembered, such as a private one, just doesn't.
@MainActor
@Observable
final class SessionStore {
    private let saveDelay: Duration

    /// What History ▸ Reopen All Windows from Last Session opens.
    private(set) var reopenableWindows: [WindowSession]
    @ObservationIgnored private let file: StoreFile?
    @ObservationIgnored private var browsers: [WeakBrowser] = []
    /// Saved windows waiting for a window to restore them into.
    @ObservationIgnored private var pendingWindows: [WindowSession]
    /// Windows already asked to open for `pendingWindows`, which shouldn't ask for more.
    @ObservationIgnored private var windowsBeingOpened = 0
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var observation = 0

    private struct WeakBrowser {
        weak var browser: BrowserModel?
    }

    /// Pass `nil` to keep nothing between launches. Without `restoresWindows`, the windows open when the app quit
    /// wait to be reopened from the History menu instead of reopening on launch.
    init(file: StoreFile? = .applicationSupport(named: "Session.plist"), restoresWindows: Bool = true,
         saveDelay: Duration = .milliseconds(150)) {
        self.file = file
        self.saveDelay = saveDelay
        // Read right away, since the first window restores the session as soon as it appears.
        let saved: SessionSnapshot
        if let data = file?.readNow(), let snapshot = try? PropertyListDecoder().decode(SessionSnapshot.self, from: data) {
            saved = snapshot
        } else if let file, !FileManager.default.fileExists(atPath: file.url.path),
                  let data = try? Data(contentsOf: file.url.deletingLastPathComponent().appending(path: "Session.json")),
                  let legacy = try? JSONDecoder().decode(BrowserSessionSnapshot.self, from: data) {
            // Preserve the old file so migrating does not destroy the only recovery copy.
            saved = SessionSnapshot(windows: [WindowSession(legacy: legacy)])
        } else {
            saved = SessionSnapshot()
        }
        pendingWindows = restoresWindows ? saved.windows : []
        reopenableWindows = !restoresWindows && !saved.windows.isEmpty ? saved.windows
            : saved.windows.isEmpty ? saved.closedWindows : []
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                   queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveBeforeQuitting() }
        }
    }

    private var openBrowsers: [BrowserModel] {
        browsers.compactMap(\.browser)
    }

    var snapshot: SessionSnapshot {
        // Startup work and opening the remaining windows are asynchronous. Saved
        // windows still waiting to attach must survive any intervening save or quit.
        SessionSnapshot(windows: openBrowsers.map { $0.windowSession() } + pendingWindows,
                        closedWindows: reopenableWindows)
    }

    /// Remembers a window from now on. A window that opens while saved windows are waiting restores the next one.
    /// Returns how many more windows to open for the rest.
    func attach(_ browser: BrowserModel) -> Int {
        guard !browser.isPrivate, !browser.isExtensionWindow,
              !openBrowsers.contains(where: { $0 === browser }) else { return 0 }
        browser.sessionStore = self
        browsers.removeAll { $0.browser == nil }
        browsers.append(WeakBrowser(browser: browser))
        defer {
            observeBrowsers()
            scheduleSave()
        }
        guard !pendingWindows.isEmpty else { return 0 }
        browser.restoreSession(pendingWindows.removeFirst())
        if windowsBeingOpened > 0 {
            windowsBeingOpened -= 1
            return 0
        }
        windowsBeingOpened = pendingWindows.count
        return pendingWindows.count
    }

    /// Forgets a window the user closed. Closing the last one keeps the windows for reopening later.
    func detach(_ browser: BrowserModel) {
        guard !isTerminating, openBrowsers.contains(where: { $0 === browser }) else { return }
        if openBrowsers.count == 1 {
            reopenableWindows = [browser.windowSession()]
        }
        browsers.removeAll { $0.browser == nil || $0.browser === browser }
        browser.sessionStore = nil
        observeBrowsers()
        // Window closure can be followed immediately by process termination.
        saveTask?.cancel()
        saveTask = nil
        file?.writeNow(try? PropertyListEncoder.binary.encode(snapshot))
    }

    /// Restores the first window into `browser` when it only has a new tab, and returns how many windows to open
    /// for the rest.
    func reopenLastSession(reusing browser: BrowserModel?) -> Int {
        var windows = reopenableWindows
        reopenableWindows = []
        if let browser, !browser.isPrivate, !browser.isExtensionWindow, browser.isBlank, !windows.isEmpty {
            browser.restoreSession(windows.removeFirst())
        }
        pendingWindows += windows
        windowsBeingOpened += windows.count
        scheduleSave()
        return windows.count
    }

    /// Forgets the windows waiting to be reopened, for when all history is cleared.
    func forgetClosedWindows() {
        reopenableWindows = []
        scheduleSave()
    }

    /// Saves again whenever a window's tabs, their addresses or titles, or its selected tab change.
    private func observeBrowsers() {
        observation += 1
        let current = observation
        withObservationTracking {
            for browser in openBrowsers {
                _ = browser.activeTabID
                _ = browser.splits
                for tab in browser.tabs {
                    _ = tab.url
                    _ = tab.pageTitle
                    _ = tab.isNewTab
                    _ = tab.pinnedPageID
                    _ = tab.folderPageID
                    _ = tab.temporarySection
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observation == current else { return }
                self.observeBrowsers()
                self.scheduleSave()
            }
        }
    }

    /// Explicit saves cover metadata changes initiated outside observation callbacks.
    func requestSave() {
        scheduleSave()
    }

    private func scheduleSave() {
        guard let file, !isTerminating else { return }
        // Continuous title/URL updates must not defer persistence indefinitely.
        guard saveTask == nil else { return }
        saveTask = Task { [weak self, saveDelay] in
            do { try await Task.sleep(for: saveDelay) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            let snapshot = snapshot
            file.write { try? PropertyListEncoder.binary.encode(snapshot) }
        }
    }

    /// Saves the windows as they are, and ignores them closing as the app quits.
    func saveBeforeQuitting() {
        isTerminating = true
        saveTask?.cancel()
        file?.writeNow(try? PropertyListEncoder.binary.encode(snapshot))
    }
}
