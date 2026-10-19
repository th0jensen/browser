import WebKit
import XCTest
@testable import Browser

@MainActor
final class PrivacyTests: XCTestCase {
    func testPrivateWindowsRememberNothing() throws {
        let browser = BrowserModel.makePrivate(downloads: DownloadManager())

        XCTAssertTrue(browser.isPrivate)
        XCTAssertNil(browser.history)
        XCTAssertFalse(browser.websiteDataStore.isPersistent)
        XCTAssertFalse(browser.sitePermissions === SitePermissions.shared)
        XCTAssertFalse(browser.zoomLevels === ZoomStore.shared)
        XCTAssertFalse(BrowserModel().isPrivate)
    }

    func testPrivateTabsShareTheirWindowsDataStoreOnly() throws {
        let first = BrowserModel.makePrivate(downloads: DownloadManager())
        let second = BrowserModel.makePrivate(downloads: DownloadManager())
        first.addTab()

        first.tabs.forEach { $0.restore() }
        let stores = first.tabs.compactMap { $0.webView?.configuration.websiteDataStore }
        XCTAssertEqual(stores.count, 2)
        XCTAssertTrue(stores.allSatisfy { $0 === first.websiteDataStore })
        XCTAssertFalse(first.websiteDataStore === second.websiteDataStore)
        XCTAssertFalse(first.websiteDataStore === WKWebsiteDataStore.default())
    }

    func testPrivatePopUpsAndRestoredTabsStayPrivate() throws {
        let browser = BrowserModel.makePrivate(downloads: DownloadManager())
        let opener = try XCTUnwrap(browser.activeTab)
        opener.restore()
        let configuration = try XCTUnwrap(opener.webView?.configuration)

        let popUp = browser.openChildTab(of: opener, configuration: configuration, select: false)
        XCTAssertTrue(popUp.webView?.configuration.websiteDataStore === browser.websiteDataStore)

        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: URL(string: "http://127.0.0.1:9/private-a")!, title: "A", interactionState: nil),
            TabSession(url: URL(string: "http://127.0.0.1:9/private-b")!, title: "B", interactionState: nil),
        ], selectedIndex: 0))
        browser.selectTab(at: 1)

        XCTAssertTrue(browser.activeTab?.webView?.configuration.websiteDataStore === browser.websiteDataStore)
    }

    func testPrivateZoomLevelsAreForgotten() throws {
        let browser = BrowserModel.makePrivate(downloads: DownloadManager())
        browser.zoomLevels.setLevel(1.5, for: "private.example")

        XCTAssertEqual(browser.zoomLevels.level(for: "private.example"), 1.5)
        XCTAssertEqual(ZoomStore.shared.level(for: "private.example"), 1)
        XCTAssertEqual(BrowserModel.makePrivate(downloads: DownloadManager()).zoomLevels.level(for: "private.example"), 1)
    }

    func testBrowsingDataDefaultsToTheProfileDataStore() {
        let data = BrowsingData(history: HistoryStore(file: nil), session: SessionStore(file: nil))
        XCTAssertTrue(data.dataStore === BrowserProfile.websiteDataStore)
        XCTAssertFalse(data.dataStore.isPersistent)
    }

    func testClearingSiteDataLeavesTheCacheAndTheOtherWayAround() {
        let allTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        let siteData = ClearDataOptions.siteData.websiteDataTypes(from: allTypes)
        XCTAssertTrue(siteData.contains(WKWebsiteDataTypeCookies))
        XCTAssertTrue(siteData.contains(WKWebsiteDataTypeLocalStorage))
        XCTAssertTrue(siteData.isDisjoint(with: ClearDataOptions.cacheTypes))

        let cache = ClearDataOptions.cache.websiteDataTypes(from: allTypes)
        XCTAssertTrue(cache.contains(WKWebsiteDataTypeDiskCache))
        XCTAssertFalse(cache.contains(WKWebsiteDataTypeCookies))

        XCTAssertEqual(ClearDataOptions.all.websiteDataTypes(from: allTypes), allTypes)
        XCTAssertTrue(ClearDataOptions([.history, .favicons]).websiteDataTypes(from: allTypes).isEmpty)
    }

    func testSiteRecordsKeepTheNewestCompletedLoadWhenAnOlderRequestFinishesLast() async throws {
        let olderRecords = try await websiteRecords(for: "older.example.org")
        let newerRecords = try await websiteRecords(for: "newer.example.net")
        let operations = ControlledWebsiteData()
        let data = browsingData(using: operations)
        let olderStarted = expectation(description: "Older load started")
        let newerStarted = expectation(description: "Newer load started")
        operations.onLoad = { index in (index == 0 ? olderStarted : newerStarted).fulfill() }
        let older = Task { await data.loadSiteRecords() }
        await fulfillment(of: [olderStarted], timeout: 2)
        let newer = Task { await data.loadSiteRecords() }
        await fulfillment(of: [newerStarted], timeout: 2)

        operations.finishLoad(1, with: newerRecords)
        await newer.value
        operations.finishLoad(0, with: olderRecords)
        await older.value

        XCTAssertEqual(data.siteRecords.map(\.displayName), newerRecords.map(\.displayName))
        XCTAssertTrue(data.hasLoadedSiteRecords)
    }

    func testCancelledNewerLoadDoesNotPublishOrSuppressAValidOlderLoad() async throws {
        let records = try await websiteRecords(for: "kept.example.org")
        let operations = ControlledWebsiteData()
        let data = browsingData(using: operations)
        let olderStarted = expectation(description: "Valid load started")
        let newerStarted = expectation(description: "Cancelled load started")
        operations.onLoad = { index in (index == 0 ? olderStarted : newerStarted).fulfill() }
        let older = Task { await data.loadSiteRecords() }
        await fulfillment(of: [olderStarted], timeout: 2)
        let newer = Task { await data.loadSiteRecords() }
        await fulfillment(of: [newerStarted], timeout: 2)
        newer.cancel()
        operations.finishLoad(1, with: [])
        await newer.value
        XCTAssertFalse(data.hasLoadedSiteRecords)
        operations.finishLoad(0, with: records)
        await older.value

        XCTAssertEqual(data.siteRecords.map(\.displayName), records.map(\.displayName))
        XCTAssertTrue(data.hasLoadedSiteRecords)
    }

    func testRemovingWebsiteDataInvalidatesAnInitialReadAndCancelledWaitingReads() async throws {
        let staleRecords = try await websiteRecords(for: "removed.example.org")
        let operations = ControlledWebsiteData()
        let data = browsingData(using: operations)
        let oldReadStarted = expectation(description: "Initial read started")
        let freshReadStarted = expectation(description: "Post-removal refresh started")
        let removalStarted = expectation(description: "Removal started")
        operations.onLoad = { index in (index == 0 ? oldReadStarted : freshReadStarted).fulfill() }
        operations.onMutation = { removalStarted.fulfill() }
        let oldRead = Task { await data.loadSiteRecords() }
        await fulfillment(of: [oldReadStarted], timeout: 2)
        let removal = Task { await data.removeData(for: staleRecords) }
        await fulfillment(of: [removalStarted], timeout: 2)
        let waitingStarted = expectation(description: "Load requested during removal")
        let waitingRead = Task {
            waitingStarted.fulfill()
            await data.loadSiteRecords()
        }
        await fulfillment(of: [waitingStarted], timeout: 2)
        waitingRead.cancel()
        await waitingRead.value
        XCTAssertEqual(operations.loadCount, 1, "No read should run against data that is being deleted")

        operations.finishLoad(0, with: staleRecords)
        await oldRead.value
        XCTAssertFalse(data.hasLoadedSiteRecords, "The initial snapshot predates the removal")
        operations.finishMutation(0)
        await fulfillment(of: [freshReadStarted], timeout: 2)
        operations.finishLoad(1, with: [])
        await removal.value

        XCTAssertTrue(data.hasLoadedSiteRecords)
        XCTAssertTrue(data.siteRecords.isEmpty)
    }

    func testAcceptedClearCompletesAndRefreshesAfterItsCallerIsCancelled() async throws {
        let staleRecords = try await websiteRecords(for: "cleared.example.org")
        let operations = ControlledWebsiteData()
        let data = browsingData(using: operations)
        let initialStarted = expectation(description: "Initial website list started")
        let refreshStarted = expectation(description: "Clear refresh started")
        let clearStarted = expectation(description: "WebKit accepted clearing")
        operations.onLoad = { index in (index == 0 ? initialStarted : refreshStarted).fulfill() }
        operations.onMutation = { clearStarted.fulfill() }
        let initial = Task { await data.loadSiteRecords() }
        await fulfillment(of: [initialStarted], timeout: 2)
        operations.finishLoad(0, with: staleRecords)
        await initial.value
        let clearing = Task { await data.clear(.siteData, range: .all) }
        await fulfillment(of: [clearStarted], timeout: 2)
        clearing.cancel()
        operations.finishMutation(0)
        await fulfillment(of: [refreshStarted], timeout: 2)
        operations.finishLoad(1, with: [])
        await clearing.value

        XCTAssertTrue(data.hasLoadedSiteRecords)
        XCTAssertTrue(data.siteRecords.isEmpty)
    }

    private func browsingData(using operations: ControlledWebsiteData) -> BrowsingData {
        BrowsingData(history: HistoryStore(file: nil), session: SessionStore(file: nil),
                     dataStore: .nonPersistent(), websiteDataOperations: operations.operations)
    }

    /// Real WebKit records from an isolated cookie store; no network access or shared profile data is needed.
    private func websiteRecords(for host: String) async throws -> [WKWebsiteDataRecord] {
        let store = WKWebsiteDataStore.nonPersistent()
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: host, .path: "/", .name: "privacy-test", .value: "1"]))
        await store.httpCookieStore.setCookie(cookie)
        let records = await store.dataRecords(ofTypes: [WKWebsiteDataTypeCookies])
        XCTAssertFalse(records.isEmpty)
        return records
    }

    func testClearingAllHistoryForgetsClosedWindows() async {
        let history = HistoryStore(file: nil)
        let session = SessionStore(file: nil)
        let closing = BrowserModel()
        closing.restoreSession(WindowSession(tabs: [
            TabSession(url: URL(string: "https://swift.org")!, title: "Swift", interactionState: nil),
        ], selectedIndex: 0))
        _ = session.attach(closing)
        session.detach(closing)
        history.recordVisit(to: URL(string: "https://swift.org")!, title: "Swift")
        let data = BrowsingData(history: history, session: session, dataStore: .nonPersistent())

        await data.clear(.history, range: .lastHour)
        XCTAssertTrue(history.visits.isEmpty)
        XCTAssertFalse(session.reopenableWindows.isEmpty)

        await data.clear(.history, range: .all)
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }
}

@MainActor
private final class ControlledWebsiteData {
    var onLoad: ((Int) -> Void)?
    var onMutation: (() -> Void)?
    private(set) var loadCount = 0
    private var mutationCount = 0
    private var loads: [Int: CheckedContinuation<[WKWebsiteDataRecord], Never>] = [:]
    private var mutations: [Int: CheckedContinuation<Void, Never>] = [:]

    var operations: BrowsingData.WebsiteDataOperations {
        .init(loadRecords: { await self.load() }, removeRecords: { _ in await self.mutate() },
              removeModifiedSince: { _, _ in await self.mutate() })
    }

    private func load() async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            let index = loadCount
            loadCount += 1
            loads[index] = continuation
            onLoad?(index)
        }
    }

    private func mutate() async {
        await withCheckedContinuation { continuation in
            let index = mutationCount
            mutationCount += 1
            mutations[index] = continuation
            onMutation?()
        }
    }

    func finishLoad(_ index: Int, with records: [WKWebsiteDataRecord]) {
        loads.removeValue(forKey: index)?.resume(returning: records)
    }

    func finishMutation(_ index: Int) {
        mutations.removeValue(forKey: index)?.resume()
    }
}
