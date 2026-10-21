import WebKit
import XCTest
@testable import Browser

@MainActor
final class ClearDataPresentationTests: XCTestCase {
    func testNamedPresentationKeepsItsExactDestinationAfterSwitchToDefault() async throws {
        try await assertCapturedDestination(startNamed: true)
    }

    func testDefaultPresentationKeepsItsExistingServiceAfterSwitchToNamed() async throws {
        try await assertCapturedDestination(startNamed: false)
    }

    private func assertCapturedDestination(startNamed: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ClearPresentation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = BrowserSpaceStore(directory: root, enabled: false)
        let profile = try spaces.profiles.create(title: "Work Profile")
        let named = try spaces.createSpace(title: "Work", profileID: profile.id)
        let defaultSpace = BrowserSpaceStore.defaultSpaceID
        let defaultStore = WKWebsiteDataStore.nonPersistent()
        let defaultHistory = HistoryStore(file: nil)
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        func session(_ spaceID: UUID, _ profileID: UUID) -> SpaceSession {
            SpaceSession(spaceID: spaceID, profileID: profileID,
                         tabs: [TabSession(url: URL(string: "http://127.0.0.1:9/\(profileID)")!, title: "Recovery",
                                           interactionState: Data([0x00, 0xff, 0x57, 0x4b]))], selectedIndex: 0)
        }
        let defaultRecovery = session(defaultSpace, BrowserProfile.defaultID)
        let namedRecovery = session(named.id, profile.id)
        let unavailable = session(UUID(), UUID())
        let closed = WindowSession(tabs: defaultRecovery.tabs, selectedIndex: 0, activeSpaceID: defaultSpace,
                                   spaceSessions: [defaultRecovery, namedRecovery], unavailableSpaceSessions: [unavailable])
        file.writeNow(try PropertyListEncoder.binary.encode(SessionSnapshot(closedWindows: [closed])))
        let service = SessionStore(file: file)
        let defaultOperations = PresentationWebsiteOperations(store: defaultStore)
        let defaultData = BrowsingData(history: defaultHistory, session: service, dataStore: defaultStore,
                                       websiteDataOperations: defaultOperations.operations, ownershipResolver: spaces.owns)
        let browser = BrowserModel(history: defaultHistory, websiteDataStore: defaultStore, spaces: spaces, browsingData: defaultData)
        _ = service.attach(browser)
        let namedHistory = try XCTUnwrap(browser.history(for: profile.id))
        let namedStore = try XCTUnwrap(browser.websiteDataStore(forProfileID: profile.id))
        let namedOperations = PresentationWebsiteOperations(store: namedStore)
        await defaultHistory.waitUntilLoaded()
        await namedHistory.waitUntilLoaded()
        let url = URL(string: "https://captured-owner.invalid/")!
        defaultHistory.recordVisit(to: url, title: "Default history")
        namedHistory.recordVisit(to: url, title: "Named history")
        for (store, value) in [(defaultStore, "default"), (namedStore, "named")] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "captured-owner.invalid", .path: "/", .name: "owner", .value: value]))
            await store.httpCookieStore.setCookie(cookie)
        }
        if startNamed { XCTAssertTrue(browser.selectSpace(named.id)) }
        XCTAssertTrue(browser.requestClearData(websiteDataOperations: namedOperations.operations))
        let captured = try XCTUnwrap(browser.clearDataPresentation)
        let targetID = startNamed ? profile.id : BrowserProfile.defaultID
        let targetStore = startNamed ? namedStore : defaultStore
        let targetHistory = startNamed ? namedHistory : defaultHistory
        XCTAssertEqual(captured.profileID, targetID)
        XCTAssertEqual(captured.profileName, startNamed ? "Work Profile" : BrowserProfile.displayName)
        XCTAssertTrue(captured.data.history === targetHistory)
        XCTAssertTrue(captured.data.dataStore === targetStore)
        XCTAssertTrue(captured.data.session === service)
        if !startNamed { XCTAssertTrue(captured.data === defaultData, "Default uses its actual injected service, not a substitute") }

        // This is the same Space selection boundary used by an externally routed destination.
        // No GUI sheet or routing features from other branches are needed to exercise owner change.
        XCTAssertTrue(browser.selectSpace(startNamed ? defaultSpace : named.id))
        XCTAssertNotEqual(browser.profileID, targetID)
        XCTAssertFalse(browser.requestClearData(), "An existing presentation cannot be retargeted")
        let stillPresented = try XCTUnwrap(browser.clearDataPresentation)
        XCTAssertEqual(stillPresented.id, captured.id)
        XCTAssertEqual(stillPresented.profileName, captured.profileName)
        XCTAssertTrue(stillPresented.data === captured.data)
        await stillPresented.data.clear([.history, .siteData, .cache], range: .all)

        XCTAssertTrue(targetHistory.visits.isEmpty)
        XCTAssertEqual((startNamed ? defaultHistory : namedHistory).visits.count, 1)
        XCTAssertEqual(defaultOperations.removalCount, startNamed ? 0 : 1)
        XCTAssertEqual(namedOperations.removalCount, startNamed ? 1 : 0)
        let defaultCookies = await defaultStore.httpCookieStore.allCookies()
        let namedCookies = await namedStore.httpCookieStore.allCookies()
        XCTAssertEqual(defaultCookies.map(\.value), startNamed ? ["default"] : [])
        XCTAssertEqual(namedCookies.map(\.value), startNamed ? [] : ["named"])
        let retained = try XCTUnwrap(service.reopenableWindows.first)
        XCTAssertEqual(retained.spaceSessions, [startNamed ? defaultRecovery : namedRecovery])
        XCTAssertEqual(retained.unavailableSpaceSessions, [unavailable])
        service.saveBeforeQuitting()
        let disk = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
        XCTAssertEqual(disk.closedWindows, [retained])
        XCTAssertEqual(browser.clearDataPresentation?.id, captured.id)
        browser.dismissClearData()
        XCTAssertNil(browser.clearDataPresentation)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testPrivateAndMismatchedDefaultDependenciesCannotCaptureOrdinaryData() async {
        let store = WKWebsiteDataStore.nonPersistent()
        let history = HistoryStore(file: nil)
        let service = SessionStore(file: nil)
        let data = BrowsingData(history: history, session: service, dataStore: store)
        let privateBrowser = BrowserModel(history: history, websiteDataStore: store, isPrivate: true, browsingData: data)
        XCTAssertFalse(privateBrowser.requestClearData())
        XCTAssertNil(privateBrowser.clearDataPresentation)
        let wrongStore = BrowserModel(history: history, websiteDataStore: .nonPersistent(), browsingData: data)
        XCTAssertFalse(wrongStore.requestClearData(), "QA/isolated windows must not borrow another store's service")
        let wrongHistory = BrowserModel(history: HistoryStore(file: nil), websiteDataStore: store, browsingData: data)
        XCTAssertFalse(wrongHistory.requestClearData())
        let wrongSession = BrowserModel(history: history, websiteDataStore: store, browsingData: data)
        let otherService = SessionStore(file: nil)
        _ = otherService.attach(wrongSession)
        XCTAssertFalse(wrongSession.requestClearData())
        let extensionBrowser = BrowserModel(history: history, websiteDataStore: store, browsingData: data)
        extensionBrowser.isExtensionWindow = true
        XCTAssertFalse(extensionBrowser.requestClearData())
        XCTAssertTrue(BrowserProfile.usesDisposableWebsiteData)
        let persistentID = UUID()
        let persistentStore = BrowserProfile.makeWebsiteDataStore(identifier: persistentID, disposable: false)
        let persistentData = BrowsingData(history: history, session: service, dataStore: persistentStore)
        let disposableBrowser = BrowserModel(history: history, websiteDataStore: persistentStore, browsingData: persistentData)
        XCTAssertFalse(disposableBrowser.requestClearData(), "Debug/QA cannot capture persisted browsing services even when references match")
        XCTAssertNil(disposableBrowser.clearDataPresentation)
        // Delete only the random test store. The existing default persistent store is never opened.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: persistentID) { _ in continuation.resume() }
        }
    }
}

/// Injected operations retain one exact WebKit store and perform real isolated-cookie deletion.
@MainActor
private final class PresentationWebsiteOperations {
    let store: WKWebsiteDataStore
    private(set) var removalCount = 0
    init(store: WKWebsiteDataStore) { self.store = store }
    var operations: BrowsingData.WebsiteDataOperations {
        .init(loadRecords: { await self.store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) },
              removeRecords: { await self.store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: $0) },
              removeModifiedSince: { types, start in
                  self.removalCount += 1
                  await self.store.removeData(ofTypes: types, modifiedSince: start)
              })
    }
}
