import Foundation
import Synchronization
import WebKit
import XCTest
@testable import Browser

@MainActor
final class ProfileIsolationRegressionTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appending(path: "ProfileRegression-\(UUID())") }
    private func entry(_ title: String, profile: UUID? = nil, space: UUID? = nil) -> TabSession {
        TabSession(url: URL(string: "https://profiles.invalid/\(title)")!, title: title, interactionState: nil,
                   profileID: profile).withSpace(space)
    }

    func testAnonymousFaviconSessionDoesNotKeepSameHostCookiesOrCredentials() async throws {
        let configuration = FaviconRequests.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        configuration.protocolClasses = [ProfileIconProtocol.self]
        let session = URLSession(configuration: configuration, delegate: FaviconRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        ProfileIconProtocol.requests.withLock { $0 = [] }
        let host = "https://same-host.profiles.invalid/favicon.ico"
        // The same anonymous transport is used for Existing, named, and private icon requests.
        for context in [FaviconContext.existingProfile, .transient(UUID()), .transient(UUID())] {
            _ = context
            _ = try await session.data(from: URL(string: host)!)
        }
        let requests = ProfileIconProtocol.requests.withLock { $0 }
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil
            && $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertFalse(FaviconRequests.allowsNetworkRequest(to: URL(string: "https://user:secret@profiles.invalid/favicon.ico")!))
    }

    func testNamedAndPrivateIconConsumersCannotReadOrWriteDefaultCacheAndClearingIsScoped() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = FaviconStore.cache
        await FaviconStore.clear(since: .distantFuture)
        FaviconStore.cache = FaviconCache(directory: root)
        let url = URL(string: "http://127.0.0.1/icons")! // No auxiliary network request is permitted.
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="))
        let cacheEntry = FaviconCache.Entry(source: url, data: png)
        FaviconStore.cache.save(cacheEntry, forHost: "127.0.0.1")
        let ordinaryIcon = await FaviconStore.icon(for: url, context: .existingProfile)
        XCTAssertNotNil(ordinaryIcon)
        for context in [FaviconContext.transient(UUID()), .transient(UUID())] {
            XCTAssertNil(FaviconStore.cachedIcon(for: url, context: context))
            let icon = await FaviconStore.icon(for: url, context: context)
            XCTAssertNil(icon)
        }
        let usage = FaviconStore.memoryUsage
        let namedData = BrowsingData(history: HistoryStore(file: nil), session: SessionStore(file: nil),
                                     dataStore: .nonPersistent(), includesSharedState: false, profileID: UUID())
        await namedData.clear(.favicons, range: .all)
        XCTAssertEqual(FaviconStore.memoryUsage, usage)
        XCTAssertEqual(FaviconStore.cache.entry(forHost: "127.0.0.1"), cacheEntry)
        await FaviconStore.clear(since: .distantPast)
        XCTAssertNil(FaviconStore.cache.entry(forHost: "127.0.0.1"))
        XCTAssertNil(FaviconStore.cachedIcon(for: url, context: .existingProfile))
        FaviconStore.cache = previous
    }

    func testBackgroundExtensionWindowModelUsesOpenerDependenciesWithoutOpeningAWindow() throws {
        let spaces = BrowserSpaceStore(directory: root(), enabled: false)
        let profile = try spaces.profiles.create(title: "Work")
        let downloads = DownloadManager()
        let permissions = SitePermissions()
        let history = HistoryStore(file: nil)
        let zoom = ZoomStore(defaults: nil)
        let browser = BrowserModel(downloads: downloads, sitePermissions: permissions, history: history,
                                   zoomLevels: zoom, spaces: spaces)
        let opener = try XCTUnwrap(browser.activeTab)
        let configuration = browser.makeConfiguration()
        let originalStore = browser.websiteDataStore
        _ = try browser.createSpace(title: "Work", profileID: profile.id)
        let workDownloads = browser.downloads
        let popup = BrowserExtensions.shared.makeWindowModel(configuration: configuration, opener: opener)
        XCTAssertNil(popup.window)
        XCTAssertTrue(popup.downloads === downloads)
        XCTAssertFalse(popup.downloads === workDownloads)
        XCTAssertTrue(popup.sitePermissions === permissions)
        XCTAssertTrue(popup.history === history)
        XCTAssertTrue(popup.zoomLevels === zoom)
        XCTAssertTrue(popup.websiteDataStore === originalStore)
        XCTAssertEqual(popup.activeTab?.profileID, BrowserProfile.defaultID)
    }

    func testAllHistoryClearingPreservesOtherProfilesAndUnknownRecoveryAndSynchronizesLegacyCopy() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = BrowserSpaceStore(directory: root, enabled: false)
        let profile = try spaces.profiles.create(title: "Work").id
        let space = try spaces.createSpace(title: "Work", profileID: profile).id
        let defaultSpace = BrowserSpaceStore.defaultSpaceID
        let ordinary = SpaceSession(spaceID: defaultSpace, profileID: BrowserProfile.defaultID,
                                    tabs: [entry("ordinary")], selectedIndex: 0)
        let split = BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [0, 1], anchorIndex: 0,
                                                focusedIndex: 1, orientation: .vertical, weights: [0.4, 0.6])
        let named = SpaceSession(spaceID: space, profileID: profile,
                                tabs: [entry("work1", profile: profile, space: space), entry("work2", profile: profile, space: space)],
                                selectedIndex: 1, splits: [split])
        let unknown = SpaceSession(spaceID: UUID(), profileID: UUID(), tabs: [entry("recover")], selectedIndex: 0)
        let mixed = WindowSession(tabs: ordinary.tabs, selectedIndex: 0, activeSpaceID: defaultSpace,
                                  spaceSessions: [ordinary, named], unavailableSpaceSessions: [unknown])
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        file.writeNow(try PropertyListEncoder.binary.encode(SessionSnapshot(closedWindows: [mixed])))
        let session = SessionStore(file: file)
        let defaultData = BrowsingData(history: HistoryStore(file: nil), session: session, dataStore: .nonPersistent(),
                                       ownershipResolver: spaces.owns)
        await defaultData.clear(.history, range: .all)
        let retained = try XCTUnwrap(session.reopenableWindows.first)
        XCTAssertEqual(retained.spaceSessions, [named])
        XCTAssertEqual(retained.unavailableSpaceSessions, [unknown])
        XCTAssertEqual(retained.tabs, named.tabs)
        XCTAssertEqual(retained.splits, named.splits)
        XCTAssertEqual(retained.selectedIndex, 1)
        XCTAssertEqual(retained.activeSpaceID, space)
        let namedData = BrowsingData(history: HistoryStore(file: nil), session: session, dataStore: .nonPersistent(),
                                     includesSharedState: false, profileID: profile, ownershipResolver: spaces.owns)
        await namedData.clear(.history, range: .all)
        let recoveryOnly = try XCTUnwrap(session.reopenableWindows.first)
        XCTAssertEqual(recoveryOnly.unavailableSpaceSessions, [unknown])
        XCTAssertEqual(recoveryOnly.spaceSessions, [])
        XCTAssertTrue(recoveryOnly.tabs.isEmpty)
        XCTAssertEqual(recoveryOnly.selectedIndex, 0)
        XCTAssertNil(recoveryOnly.splits)
        XCTAssertNil(recoveryOnly.activeSpaceID)
        session.saveBeforeQuitting()
        let disk = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
        XCTAssertEqual(disk.closedWindows, [recoveryOnly])
    }

    func testNamedHistoryClearKeepsDefaultRecoveryAndPendingWindowsAndLegacyIndicesRemainCoherent() throws {
        let spaces = BrowserSpaceStore(directory: root(), enabled: false)
        let profile = try spaces.profiles.create(title: "Work").id
        let other = UUID(), space = UUID()
        let namedSpace = try spaces.createSpace(title: "Work", profileID: profile)
        let split = BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [1, 2], anchorIndex: 1,
                                                focusedIndex: 2, orientation: .horizontal, weights: [0.25, 0.75])
        let legacy = WindowSession(tabs: [entry("remove"), entry("keep1", profile: profile), entry("keep2", profile: profile)],
                                   selectedIndex: 2, splits: [split])
        let retained = try XCTUnwrap(legacy.removingRecovery(for: BrowserProfile.defaultID))
        XCTAssertEqual(retained.tabs.map(\.title), ["keep1", "keep2"])
        XCTAssertEqual(retained.selectedIndex, 1)
        XCTAssertEqual(retained.splits?.first?.tabIndices, [0, 1])
        XCTAssertEqual(retained.splits?.first?.anchorIndex, 0)
        XCTAssertEqual(retained.splits?.first?.focusedIndex, 1)
        XCTAssertEqual(retained.splits?.first?.weights, split.weights)
        let mismatch = SpaceSession(spaceID: space, profileID: profile, tabs: [entry("unknown", profile: other)], selectedIndex: 0)
        let ordinary = SpaceSession(spaceID: BrowserSpaceStore.defaultSpaceID, profileID: BrowserProfile.defaultID,
                                    tabs: [entry("default")], selectedIndex: 0)
        let named = SpaceSession(spaceID: namedSpace.id, profileID: profile, tabs: [entry("named", profile: profile)], selectedIndex: 0)
        let mixed = WindowSession(tabs: named.tabs, selectedIndex: 0, activeSpaceID: named.spaceID, spaceSessions: [ordinary, named, mismatch])
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        file.writeNow(try PropertyListEncoder.binary.encode(SessionSnapshot(windows: [mixed], closedWindows: [mixed])))
        let session = SessionStore(file: file)
        session.forgetClosedWindows(forProfileID: profile, ownershipResolver: spaces.owns)
        for window in session.snapshot.windows + session.reopenableWindows {
            XCTAssertEqual(window.spaceSessions, [ordinary, mismatch])
            XCTAssertEqual(window.tabs, ordinary.tabs)
            XCTAssertEqual(window.activeSpaceID, ordinary.spaceID)
        }
    }

    func testDelayedPermissionAnswerAndAutofillEligibilityUseImmutableTabOwnership() async throws {
        let spaces = BrowserSpaceStore(directory: root(), enabled: false)
        let profile = try spaces.profiles.create(title: "Work")
        let browser = BrowserModel(spaces: spaces)
        let source = try XCTUnwrap(browser.activeTab)
        let ordinaryPermissions = browser.permissions(for: source.profileID)
        var answer: CheckedContinuation<Bool?, Never>?
        let decision = Task { await ordinaryPermissions.decide([.camera], on: "https://profiles.invalid") {
            await withCheckedContinuation { answer = $0 }
        } }
        try await waitUntil { answer != nil }
        _ = try browser.createSpace(title: "Work", profileID: profile.id)
        let named = try XCTUnwrap(browser.activeTab)
        answer?.resume(returning: true)
        let allowed = await decision.value
        XCTAssertTrue(allowed)
        XCTAssertEqual(ordinaryPermissions.decision(for: [.camera], on: "https://profiles.invalid"), true)
        XCTAssertNil(browser.sitePermissions.decision(for: [.camera], on: "https://profiles.invalid"))
        XCTAssertTrue(PasswordAutofill.supports(source))
        XCTAssertFalse(PasswordAutofill.supports(named))
        let privateBrowser = BrowserModel.makePrivate(downloads: DownloadManager())
        XCTAssertFalse(PasswordAutofill.supports(try XCTUnwrap(privateBrowser.activeTab)))
        XCTAssertNotEqual(privateBrowser.faviconContext, browser.faviconContext)
        XCTAssertFalse(privateBrowser.faviconContext.remembersIcons)
    }
}

private extension TabSession {
    func withSpace(_ id: UUID?) -> Self { var value = self; value.spaceID = id; return value }
}

private final class ProfileIconProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Set-Cookie": "account=first-profile; Path=/; Secure", "Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([1]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
