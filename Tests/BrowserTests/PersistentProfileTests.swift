import XCTest
import WebKit
@testable import Browser

@MainActor
final class PersistentProfileTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "Profiles-\(UUID())") }

    func testLegacyProfileAndSpaceMetadataKeepExistingStoreAndFiles() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = [BrowserSpace(id: BrowserSpaceStore.defaultSpaceID, title: "Default", profileID: BrowserProfile.defaultID)]
        let bytes = try JSONEncoder().encode(legacy)
        try bytes.write(to: root.appending(path: "Spaces.json"))
        let spaces = BrowserSpaceStore(directory: root)
        XCTAssertEqual(spaces.spaces, legacy)
        XCTAssertNil(spaces.profiles.profiles.first?.websiteDataStoreID)
        let existingStore = WKWebsiteDataStore.nonPersistent()
        let browser = BrowserModel(websiteDataStore: existingStore, spaces: spaces)
        let profile = try spaces.profiles.create(title: "Work")
        let work = try browser.createSpace(title: "Work", profileID: profile.id)
        XCTAssertNotEqual(work.profileID, BrowserProfile.defaultID)
        XCTAssertTrue(browser.selectSpace(BrowserSpaceStore.defaultSpaceID))
        XCTAssertTrue(browser.makeConfiguration().websiteDataStore === existingStore)
        XCTAssertEqual(spaces.savedPageDirectory(for: BrowserSpaceStore.defaultSpaceID), root)
        let reloaded = BrowserSpaceStore(directory: root)
        XCTAssertEqual(reloaded.profiles.profile(profile.id), profile)
        XCTAssertEqual(reloaded.space(work.id), work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "History.plist").path))
    }

    func testProfilesUseSeparateConfigurationsStoresAndPrivilegedControllers() throws {
        let spaces = BrowserSpaceStore(directory: root(), enabled: false)
        let profile = try spaces.profiles.create(title: "Work")
        let browser = BrowserModel(spaces: spaces)
        let existing = browser.makeConfiguration()
        _ = try browser.createSpace(title: "Work", profileID: profile.id)
        let isolated = browser.makeConfiguration()
        let next = browser.makeConfiguration()
        XCTAssertFalse(existing === isolated)
        XCTAssertFalse(existing.websiteDataStore === isolated.websiteDataStore)
        XCTAssertFalse(existing.userContentController === isolated.userContentController)
        XCTAssertFalse(next.userContentController === isolated.userContentController)
        XCTAssertTrue(next.websiteDataStore === isolated.websiteDataStore)
        XCTAssertNil(isolated.webExtensionController)
        XCTAssertNil(browser.passwords)
        XCTAssertFalse(isolated.userContentController.userScripts.contains { $0.source == PasswordAutofill.script })
        XCTAssertNil(browser.websiteDataStore(forProfileID: UUID()))
        XCTAssertFalse(browser.supportsExtensions)
        XCTAssertTrue(browser.extensionTabs.allSatisfy { $0.profileID == BrowserProfile.defaultID })
    }

    func testPublicNamedStoreIdentityIsStableAndPersistent() async throws {
        let identifier = UUID()
        let first = BrowserProfile.makeWebsiteDataStore(identifier: identifier, disposable: false)
        let second = BrowserProfile.makeWebsiteDataStore(identifier: identifier, disposable: false)
        XCTAssertTrue(first.isPersistent)
        XCTAssertEqual(first.identifier, identifier)
        XCTAssertEqual(second.identifier, identifier)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "profiles.invalid", .path: "/", .name: "identity", .value: "work", .secure: "TRUE"]))
        await first.httpCookieStore.setCookie(cookie)
        let cookies = await awaitCookies(second)
        XCTAssertEqual(cookies.map(\.value), ["work"])
        // Only remove the random test store, never the existing default store.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }

    private func awaitCookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies()
    }

    func testSameSitePagesHaveSeparateCookiesAndLocalStorageAndSharedProfileSpacesShareThem() async throws {
        let spaces = BrowserSpaceStore(directory: root(), enabled: false)
        let profile = try spaces.profiles.create(title: "Work")
        let browser = BrowserModel(spaces: spaces)
        let ordinary = try XCTUnwrap(browser.activeTab)
        ordinary.restore()
        let first = try XCTUnwrap(ordinary.webView)
        let url = URL(string: "https://profiles.invalid/same-site")!
        first.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>Ordinary</title>")
        try await waitUntil { ordinary.pageTitle == "Ordinary" }
        _ = try await first.evaluateJavaScript("localStorage.setItem('account', 'ordinary'); document.cookie = 'account=ordinary;path=/'")
        let work = try browser.createSpace(title: "Work", profileID: profile.id)
        let isolated = try XCTUnwrap(browser.activeTab)
        isolated.restore()
        let second = try XCTUnwrap(isolated.webView)
        second.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>Work</title>")
        try await waitUntil { isolated.pageTitle == "Work" }
        let initial = try await second.evaluateJavaScript("[localStorage.getItem('account') ?? '', document.cookie].join('|')") as? String
        XCTAssertEqual(initial, "|")
        _ = try await second.evaluateJavaScript("localStorage.setItem('account', 'work'); document.cookie = 'account=work;path=/'")
        let original = try await first.evaluateJavaScript("[localStorage.getItem('account'), document.cookie].join('|')") as? String
        XCTAssertEqual(original, "ordinary|account=ordinary")
        let store = second.configuration.websiteDataStore
        _ = try browser.createSpace(title: "Work Two", profileID: profile.id)
        XCTAssertTrue(browser.makeConfiguration().websiteDataStore === store)
        XCTAssertTrue(browser.selectSpace(work.id))
        XCTAssertTrue(browser.activeTab === isolated)
        XCTAssertTrue(isolated.webView === second)
        XCTAssertTrue(browser.selectSpace(BrowserSpaceStore.defaultSpaceID))
        XCTAssertTrue(browser.activeTab === ordinary)
        browser.allTabs.forEach { $0.stopLoading() }
    }

    func testDurableSettingsBookmarksAndHistoryAreProfileScoped() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = BrowserProfileStore(directory: root)
        let first = try profiles.create(title: "First")
        let second = try profiles.create(title: "Second")
        let resources = try XCTUnwrap(profiles.resources(for: first.id))
        let other = try XCTUnwrap(profiles.resources(for: second.id))
        await resources.history.waitUntilLoaded()
        await other.history.waitUntilLoaded()
        let url = URL(string: "https://profiles.invalid/")!
        resources.permissions.setDecision(true, for: .camera, on: url.absoluteString)
        resources.zoom.setLevel(1.5, for: url.host())
        resources.bookmarks.add(title: "First only", url: url)
        _ = resources.history.recordVisit(to: url, title: "First only")
        resources.history.saveNow()
        XCTAssertNil(other.permissions.decision(for: [.camera], on: url.absoluteString))
        XCTAssertEqual(other.zoom.level(for: url.host()), 1)
        XCTAssertTrue(other.bookmarks.bookmarks.isEmpty)
        XCTAssertTrue(other.history.visits.isEmpty)
        XCTAssertFalse(resources.downloads === other.downloads)
        let reloaded = BrowserProfileStore(directory: root)
        let restored = try XCTUnwrap(reloaded.resources(for: first.id))
        await restored.history.waitUntilLoaded()
        XCTAssertEqual(restored.permissions.decision(for: [.camera], on: url.absoluteString), true)
        XCTAssertEqual(restored.zoom.level(for: url.host()), 1.5)
        XCTAssertEqual(restored.bookmarks.bookmarks.map(\.title), ["First only"])
        XCTAssertEqual(restored.history.visits.map(\.title), ["First only"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "History.plist").path))
    }

    func testBackgroundCallbacksKeepTheirOwningProfileAndPopupsCannotBorrowConfiguration() async throws {
        let spaces = BrowserSpaceStore(directory: root(), enabled: false)
        let profile = try spaces.profiles.create(title: "Work")
        let defaultHistory = HistoryStore(file: nil)
        await defaultHistory.waitUntilLoaded()
        let browser = BrowserModel(history: defaultHistory, spaces: spaces)
        _ = try browser.createSpace(title: "Work", profileID: profile.id)
        let work = try XCTUnwrap(browser.activeTab)
        work.restore()
        let view = try XCTUnwrap(work.webView)
        let url = URL(string: "https://profiles.invalid/background")!
        view.loadSimulatedRequest(URLRequest(url: url), responseHTML: "<title>Work</title>")
        let workHistory = try XCTUnwrap(browser.history)
        try await waitUntil { workHistory.visits.count == 1 }
        XCTAssertTrue(browser.selectSpace(BrowserSpaceStore.defaultSpaceID))
        _ = try await view.evaluateJavaScript("document.title = 'Work updated'")
        try await waitUntil { workHistory.visits.first?.title == "Work updated" }
        XCTAssertTrue(defaultHistory.visits.isEmpty)
        work.setZoom(1.5)
        XCTAssertEqual(browser.zoomLevels.level(for: url.host()), 1)
        XCTAssertEqual(browser.zoom(for: profile.id).level(for: url.host()), 1.5)
        let foreignConfiguration = browser.makeConfiguration()
        foreignConfiguration.userContentController.addUserScript(WKUserScript(source: "window.borrowed = true", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let child = browser.openChildTab(of: work, configuration: foreignConfiguration, select: false)
        XCTAssertEqual(child.profileID, work.profileID)
        XCTAssertTrue(child.webView?.configuration.websiteDataStore === view.configuration.websiteDataStore)
        XCTAssertFalse(child.webView?.configuration.userContentController === foreignConfiguration.userContentController)
        XCTAssertNil(child.webView?.configuration.webExtensionController)
        XCTAssertFalse(browser.extensionTabs.contains { $0 === child || $0 === work })
        browser.allTabs.forEach { $0.stopLoading() }
    }

    func testSessionRestoresProfileOwnersLazilyAndKeepsUnknownOwnersRecoverable() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = BrowserSpaceStore(directory: root)
        let profile = try spaces.profiles.create(title: "Work")
        let browser = BrowserModel(spaces: spaces)
        let ordinary = try XCTUnwrap(browser.activeTab)
        let work = try browser.createSpace(title: "Work", profileID: profile.id)
        let owned = try XCTUnwrap(browser.activeTab)
        let unknown = SpaceSession(spaceID: UUID(), profileID: UUID(), tabs: [], selectedIndex: 0)
        var session = browser.windowSession()
        session.unavailableSpaceSessions = [unknown]
        let saved = try PropertyListDecoder().decode(WindowSession.self, from: PropertyListEncoder.binary.encode(session))
        let restored = BrowserModel(spaces: BrowserSpaceStore(directory: root))
        restored.restoreSession(saved)
        XCTAssertEqual(restored.activeSpaceID, work.id)
        XCTAssertEqual(restored.activeTab?.profileID, profile.id)
        XCTAssertEqual(restored.activeTabID, owned.id)
        XCTAssertEqual(restored.tabAcrossSpaces(withID: ordinary.id)?.profileID, BrowserProfile.defaultID)
        XCTAssertTrue(restored.allTabs.allSatisfy { $0.webView == nil })
        XCTAssertEqual(restored.windowSession().unavailableSpaceSessions, [unknown])
        XCTAssertTrue(restored.selectSpace(BrowserSpaceStore.defaultSpaceID))
        let restoredWork = try XCTUnwrap(restored.tabAcrossSpaces(withID: owned.id))
        restoredWork.restore()
        XCTAssertTrue(restoredWork.webView?.configuration.websiteDataStore === restored.websiteDataStore(forProfileID: profile.id))
        restoredWork.stopLoading()
    }

    func testUnknownProfileSpaceIsVisibleButCannotLoadOrFallBack() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ordinary = BrowserSpace(id: BrowserSpaceStore.defaultSpaceID, title: "Default", profileID: BrowserProfile.defaultID)
        let unknown = BrowserSpace(id: UUID(), title: "Unavailable", profileID: UUID())
        try JSONEncoder().encode([ordinary, unknown]).write(to: root.appending(path: "Spaces.json"))
        let spaces = BrowserSpaceStore(directory: root)
        XCTAssertEqual(spaces.space(unknown.id), unknown)
        let browser = BrowserModel(spaces: spaces)
        XCTAssertFalse(browser.selectSpace(unknown.id))
        XCTAssertNil(browser.websiteDataStore(forProfileID: unknown.profileID))
        let entry = TabSession(url: URL(string: "https://profiles.invalid/secret"), title: "Secret", interactionState: nil,
                               profileID: unknown.profileID)
        let session = SpaceSession(spaceID: unknown.id, profileID: unknown.profileID, tabs: [entry], selectedIndex: 0)
        browser.restoreSession(WindowSession(tabs: [], selectedIndex: 0, activeSpaceID: unknown.id, spaceSessions: [session]))
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil && $0.isNewTab })
        XCTAssertEqual(browser.windowSession().unavailableSpaceSessions, [session])
    }

    func testCorruptAndDuplicateProfileStoresFailClosedWithoutOverwritingMetadata() throws {
        for corrupt in [false, true] {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let existing = BrowserProfileDescriptor(id: BrowserProfile.defaultID, title: BrowserProfile.displayName, websiteDataStoreID: nil)
            let storeID = UUID()
            let bytes = corrupt ? Data("corrupt".utf8) : try JSONEncoder().encode([existing,
                BrowserProfileDescriptor(id: UUID(), title: "One", websiteDataStoreID: storeID),
                BrowserProfileDescriptor(id: UUID(), title: "Two", websiteDataStoreID: storeID)])
            let file = root.appending(path: "Profiles.json")
            try bytes.write(to: file)
            let profiles = BrowserProfileStore(directory: root)
            XCTAssertTrue(profiles.loadFailed)
            XCTAssertEqual(profiles.profiles, [existing])
            XCTAssertThrowsError(try profiles.create(title: "Replacement"))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testPrivateAndQAProfilesNeverUsePersistentOrOrdinaryResources() throws {
        let root = root()
        let profiles = BrowserProfileStore(directory: root, enabled: false, disposableWebsiteData: true)
        let profile = try profiles.create(title: "QA")
        let spaces = BrowserSpaceStore(directory: root, enabled: false, profiles: profiles)
        let browser = BrowserModel(spaces: spaces)
        let work = try browser.createSpace(title: "QA", profileID: profile.id)
        XCTAssertFalse(browser.websiteDataStore.isPersistent)
        XCTAssertNil(browser.websiteDataStore.identifier)
        XCTAssertNil(browser.passwords)
        let privateBrowser = BrowserModel(isPrivate: true, spaces: spaces)
        XCTAssertFalse(privateBrowser.selectSpace(work.id))
        XCTAssertNil(privateBrowser.websiteDataStore(forProfileID: profile.id))
        XCTAssertFalse(privateBrowser.websiteDataStore === browser.websiteDataStore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPeekPreservesProfileAndLiveViewWhenExpanded() throws {
        let spaces = BrowserSpaceStore(directory: root(), enabled: false)
        let profile = try spaces.profiles.create(title: "Work")
        let browser = BrowserModel(spaces: spaces)
        _ = try browser.createSpace(title: "Work", profileID: profile.id)
        let opener = try XCTUnwrap(browser.activeTab)
        let peek = browser.openPeek(from: opener)
        let view = try XCTUnwrap(peek.webView)
        XCTAssertEqual(peek.profileID, profile.id)
        XCTAssertTrue(view.configuration.websiteDataStore === browser.websiteDataStore)
        XCTAssertNil(view.configuration.webExtensionController)
        browser.expandPeek()
        XCTAssertTrue(browser.activeTab === peek)
        XCTAssertTrue(browser.activeTab?.webView === view)
    }
}
