import AppKit
import XCTest
import WebKit
@testable import Browser

@MainActor
final class TabArchiveTests: XCTestCase {
    private let spaceID = BrowserSpaceStore.defaultSpaceID
    private let url = URL(string: "https://archive.invalid/page")!

    @MainActor private final class WriteGate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        var fail = false
        var failWrites: Set<Int> = []
        var gatesFirst = true
        var writer: ((Data) async throws -> Void)?
        var writes = 0
        func write(_ data: Data) async throws {
            writes += 1
            if writes == 1 && gatesFirst {
                started = true
                await withCheckedContinuation { continuation = $0 }
            }
            if fail || failWrites.contains(writes) { throw CocoaError(.fileWriteNoPermission) }
            try await writer?(data)
        }
        func wait() async {
            for _ in 0..<2000 {
                if started { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("Archive did not reach the write boundary")
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func browser(store: TabArchiveStore = TabArchiveStore()) -> BrowserModel {
        let browser = BrowserModel(tabArchive: store)
        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: url, title: "Original title", interactionState: nil),
            TabSession(url: URL(string: "https://archive.invalid/other"), title: "Other", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil)
        ], selectedIndex: 2))
        return browser
    }

    private func record(tabID: UUID = UUID(), space: UUID? = nil, profile: UUID = BrowserProfile.defaultID,
                        state: Data? = nil) -> ArchivedTab {
        ArchivedTab(id: UUID(), tabID: tabID, spaceID: space ?? spaceID, profileID: profile, url: url,
                    title: "Original title", archivedAt: Date(), lastUsedAt: Date(timeIntervalSince1970: 1234),
                    interactionState: state, originalIndex: 0)
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "TabArchiveTests-\(UUID())")
    }

    func testWriteFailureLeavesEveryLiveDescriptorAndNoArchiveEntry() async throws {
        let gate = WriteGate()
        let store = TabArchiveStore(persist: gate.write)
        let browser = browser(store: store)
        let originals = browser.tabs
        let operation = Task { await browser.archiveTab(originals[0].id) }
        await gate.wait()
        XCTAssertEqual(browser.tabs.map(\.id), originals.map(\.id))
        XCTAssertTrue(store.snapshot.records.isEmpty)
        gate.fail = true
        gate.release()
        let archived = await operation.value
        XCTAssertFalse(archived)
        XCTAssertEqual(browser.tabs.map(\.id), originals.map(\.id))
        XCTAssertTrue(browser.tabs[0] === originals[0])
        XCTAssertTrue(store.snapshot.records.isEmpty)
        XCTAssertNotNil(browser.archiveError)
    }

    func testPendingWriteRechecksSelectionNavigationSavedMembershipSpaceAndCurrentWork() async throws {
        let changes: [(String, (BrowserModel, BrowserTab) throws -> Void)] = [
            ("selection", { b, t in b.activeTabID = t.id }),
            ("selection then back", { b, t in let old = b.activeTabID; b.activeTabID = t.id; b.activeTabID = old }),
            ("navigation revision", { _, t in t.invalidateNavigation() }),
            ("URL", { _, t in t.load(URL(string: "https://archive.invalid/new")!) }),
            ("saved", { _, t in t.folderPageID = UUID() }),
            ("saved then unsaved", { _, t in t.pinnedPageID = UUID(); t.pinnedPageID = nil }),
            ("move to folder", { b, t in b.moveToFolder(t, parentID: nil) }),
            ("Space switch", { b, _ in _ = try b.createSpace(title: "Work") }),
            ("dirty", { _, t in t.archivePageWork = .protected }),
            ("transfer", { _, t in t.hasArchiveTransferWork = true }),
            ("popup", { _, t in t.isPopUp = true }),
            ("split", { b, t in _ = b.makeSplit(t.id, with: b.tabs[1].id) }),
            ("reorder", { b, t in _ = b.moveTab(t.id, to: 1) }),
            ("tab list changed", { b, _ in b.addTab(focusAddress: false) })
        ]
        for (name, change) in changes {
            let gate = WriteGate()
            let store = TabArchiveStore(persist: gate.write)
            let browser = browser(store: store)
            let original = browser.tabs[0]
            let other = browser.tabs[1]
            let operation = Task { await browser.archiveTab(original.id) }
            await gate.wait()
            try change(browser, original)
            gate.release()
            let archived = await operation.value
            XCTAssertFalse(archived, name)
            XCTAssertTrue(browser.tabAcrossSpaces(withID: original.id) === original, name)
            XCTAssertTrue(browser.tabAcrossSpaces(withID: other.id) === other, name)
            XCTAssertEqual(store.snapshot.records.count, 1, name)
            XCTAssertTrue(store.visibleRecords(spaceID: spaceID, profileID: browser.profileID).isEmpty, name)
            browser.windowDidClose()
        }
    }

    func testCloseAndCancellationDuringWriteCannotLoseOtherTabs() async {
        for close in [false, true] {
            let gate = WriteGate()
            let store = TabArchiveStore(persist: gate.write)
            let browser = browser(store: store)
            let original = browser.tabs[0]
            let retained = Array(browser.tabs.dropFirst()).map(\.id)
            let operation = Task { await browser.archiveTab(original.id) }
            await gate.wait()
            if close { browser.closeTab(original.id) } else { operation.cancel() }
            gate.release()
            let archived = await operation.value
            XCTAssertFalse(archived)
            XCTAssertTrue(retained.allSatisfy { browser.tabAcrossSpaces(withID: $0) != nil })
            XCTAssertEqual(store.snapshot.records.count, 1)
            if !close { XCTAssertTrue(browser.tabs[0] === original) }
        }
    }

    func testArchiveSearchRestoreAndUndoKeepStableIDsOrderAndLazyViews() async throws {
        let store = TabArchiveStore()
        let browser = browser(store: store)
        let originals = browser.tabs.map(\.id)
        let first = browser.tabs[0]
        let archived = await browser.archiveTab(first.id)
        XCTAssertTrue(archived)
        XCTAssertEqual(browser.tabs.map(\.id), Array(originals.dropFirst()))
        let archivedRecord = try XCTUnwrap(store.snapshot.records.first)
        XCTAssertEqual(browser.lastArchivedRecordID, archivedRecord.id)
        XCTAssertEqual(archivedRecord.tabID, first.id)
        XCTAssertEqual(archivedRecord.title, "Original title")
        XCTAssertEqual(archivedRecord.url, url)
        XCTAssertEqual(store.visibleRecords(spaceID: spaceID, profileID: browser.profileID, search: "ORIGINAL").count, 1)
        XCTAssertEqual(store.visibleRecords(spaceID: spaceID, profileID: browser.profileID, search: "archive.invalid").count, 1)
        XCTAssertTrue(store.visibleRecords(spaceID: spaceID, profileID: browser.profileID, search: "missing").isEmpty)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
        let restored = await browser.restoreArchivedTab(archivedRecord.id, select: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(browser.tabs.map(\.id), originals)
        XCTAssertEqual(browser.tabs[0].title, "Original title")
        XCTAssertEqual(browser.tabs[0].spaceID, spaceID)
        XCTAssertEqual(browser.tabs[0].profileID, browser.profileID)
        XCTAssertNil(browser.tabs[0].webView)
        XCTAssertNil(browser.lastArchivedRecordID)
        let repeated = await browser.restoreArchivedTab(archivedRecord.id, select: false)
        XCTAssertTrue(repeated)
        XCTAssertEqual(browser.tabs.map(\.id), originals)
        XCTAssertTrue(store.visibleRecords(spaceID: spaceID, profileID: browser.profileID).isEmpty)
    }

    func testUndoActionRestoresExactlyOnceWithoutReplacingTabsOpenedLater() async throws {
        let browser = browser()
        let first = browser.tabs[0]
        let archived = await browser.archiveTab(first.id)
        XCTAssertTrue(archived)
        browser.addTab(focusAddress: false)
        let newID = try XCTUnwrap(browser.activeTabID)
        browser.undoArchive()
        for _ in 0..<1000 {
            if browser.tabAcrossSpaces(withID: first.id) != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(browser.tabs.filter { $0.id == first.id }.count, 1)
        XCTAssertNotNil(browser.tabAcrossSpaces(withID: newID))
        browser.windowDidClose()
    }

    func testRestoreUsesOriginalSpaceAndRejectsMissingOrMismatchedOwners() async throws {
        let store = TabArchiveStore()
        let browser = browser(store: store)
        let archived = await browser.archiveTab(browser.tabs[0].id)
        XCTAssertTrue(archived)
        let saved = try XCTUnwrap(store.snapshot.records.first)
        _ = try browser.createSpace(title: "Other")
        let otherTabs = browser.tabs.map(\.id)
        let restored = await browser.restoreArchivedTab(saved.id, select: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(browser.activeSpaceID, spaceID)
        XCTAssertEqual(browser.tabAcrossSpaces(withID: saved.tabID)?.profileID, browser.profileID)
        XCTAssertTrue(otherTabs.allSatisfy { browser.tabAcrossSpaces(withID: $0) != nil })
        for invalid in [record(space: UUID()), record(profile: UUID())] {
            try await store.insert(invalid)
            let before = browser.allTabs.map(\.id)
            let accepted = await browser.restoreArchivedTab(invalid.id)
            XCTAssertFalse(accepted)
            XCTAssertEqual(browser.allTabs.map(\.id), before)
            XCTAssertNotNil(browser.archiveError)
        }
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testRestoreAndStaleSessionRecoveryCannotDuplicateLiveIdentityInAnotherWindow() async throws {
        let store = TabArchiveStore()
        let first = browser(store: store)
        let live = first.tabs[0]
        let recovery = record(tabID: live.id)
        try await store.insert(recovery)
        let second = BrowserModel(tabArchive: store)
        let secondIDs = second.tabs.map(\.id)
        XCTAssertTrue(store.visibleRecords(spaceID: spaceID, profileID: first.profileID).isEmpty)
        let restored = await second.restoreArchivedTab(recovery.id, select: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(second.tabs.map(\.id), secondIDs)
        XCTAssertTrue(first.tabs[0] === live)
        XCTAssertNil(live.webView)
    }

    func testRestorePersistsLiveSessionBeforeDeletingRecoveryRecord() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TabArchiveStore(url: root.appending(path: "Archive.plist"))
        let browser = browser(store: store)
        let sessionFile = StoreFile(url: root.appending(path: "Session.plist"))
        let sessions = SessionStore(file: sessionFile, saveDelay: .seconds(60))
        _ = sessions.attach(browser, restoringPendingWindows: false)
        let originalID = browser.tabs[0].id
        let archived = await browser.archiveTab(originalID)
        XCTAssertTrue(archived)
        let saved = try XCTUnwrap(store.snapshot.records.first)
        let removedSession = try PropertyListDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: sessionFile.url))
        XCTAssertFalse(removedSession.windows[0].tabs.contains { $0.id == originalID })
        let restored = await browser.restoreArchivedTab(saved.id, select: false)
        XCTAssertTrue(restored)
        XCTAssertTrue(store.snapshot.records.isEmpty)
        let disk = try PropertyListDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: sessionFile.url))
        XCTAssertEqual(disk.windows[0].tabs.filter { $0.id == originalID }.count, 1)
        let reloaded = TabArchiveStore(url: root.appending(path: "Archive.plist"))
        XCTAssertTrue(reloaded.snapshot.records.isEmpty)
    }

    func testRestoreKeepsRecoveryWhenSessionCannotBeSaved() async throws {
        let store = TabArchiveStore()
        let browser = browser(store: store)
        let sessions = SessionStore(file: nil)
        _ = sessions.attach(browser)
        let originalID = browser.tabs[0].id
        let archived = await browser.archiveTab(originalID)
        XCTAssertTrue(archived)
        let saved = try XCTUnwrap(store.snapshot.records.first)
        let restored = await browser.restoreArchivedTab(saved.id, select: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(store.snapshot.records.count, 1)
        XCTAssertEqual(browser.tabs.filter { $0.id == originalID }.count, 1)
        XCTAssertNotNil(browser.archiveError)
    }

    func testEligibilityProtectsUnknownDirtyTransferPopupSplitsMediaAndPrivateWindows() async throws {
        let browser = browser()
        let tab = browser.tabs[0]
        XCTAssertTrue(browser.canArchive(tab)) // Explicit URL/history action for a lazy descriptor.
        XCTAssertFalse(browser.canArchive(tab, automatically: true))
        tab.archivePageWork = .protected
        XCTAssertFalse(browser.canArchive(tab))
        tab.archivePageWork = .readOnly
        XCTAssertFalse(browser.canArchive(tab, automatically: true))
        try await browser.tabArchive.setPolicy(.init(automaticEnabled: true), forProfileID: tab.profileID)
        XCTAssertTrue(browser.canArchive(tab, automatically: true))
        tab.hasArchiveTransferWork = true
        XCTAssertFalse(browser.canArchive(tab))
        tab.hasArchiveTransferWork = false
        tab.openerID = browser.tabs[1].id
        XCTAssertFalse(browser.canArchive(tab))
        tab.openerID = nil
        XCTAssertTrue(browser.makeSplit(tab.id, with: browser.tabs[1].id))
        XCTAssertFalse(browser.canArchive(tab))
        browser.splits = []
        browser.archiveMediaCheck = { _ in true }
        let mediaArchived = await browser.archiveTab(tab.id)
        XCTAssertFalse(mediaArchived)
        XCTAssertNotNil(browser.tabAcrossSpaces(withID: tab.id))
        browser.isExtensionWindow = true
        XCTAssertFalse(browser.canArchive(tab))
        let ordinaryStore = TabArchiveStore()
        let privateBrowser = BrowserModel(isPrivate: true, tabArchive: ordinaryStore)
        XCTAssertFalse(privateBrowser.tabArchive === ordinaryStore)
        let privateResult = await privateBrowser.archiveTab(try XCTUnwrap(privateBrowser.activeTabID))
        XCTAssertFalse(privateResult)
        await privateBrowser.archiveIdleTabs()
        XCTAssertTrue(ordinaryStore.snapshot.records.isEmpty)
    }

    func testActiveDownloadProtectsOtherTabsAndSourceKeepsTransferProtection() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var choose: CheckedContinuation<URL?, Never>?
        let downloads = DownloadManager(directory: root, asksWhereToSave: { true }, destinationChooser: { _, _ in
            await withCheckedContinuation { choose = $0 }
        })
        let browser = BrowserModel(downloads: downloads)
        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: url, title: "Source", interactionState: nil),
            TabSession(url: url.appending(path: "other"), title: "Other", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil)
        ], selectedIndex: 2))
        let source = browser.tabs[0], other = browser.tabs[1]
        browser.activeTabID = source.id
        let view = try XCTUnwrap(source.webView)
        view.loadHTMLString("<title>Files</title><a id='file' download='archive.txt' href='data:text/plain,hello'>Get</a>", baseURL: url)
        try await waitForDocument(view)
        _ = try await view.evaluateJavaScript("document.getElementById('file').click(); 0")
        for _ in 0..<200 {
            if choose != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(choose)
        XCTAssertTrue(downloads.isDownloading)
        XCTAssertTrue(source.hasArchiveTransferWork)
        XCTAssertFalse(browser.canArchive(other))
        let archived = await browser.archiveTab(other.id)
        XCTAssertFalse(archived)
        XCTAssertTrue(browser.tabAcrossSpaces(withID: other.id) === other)
        choose?.resume(returning: nil)
        choose = nil
        for _ in 0..<200 {
            if !downloads.isDownloading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(downloads.isDownloading)
        browser.activeTabID = browser.tabs.last?.id
        XCTAssertFalse(browser.canArchive(source))
        XCTAssertTrue(browser.canArchive(other))
        browser.windowDidClose()
    }

    func testMissingObserverAndNewNavigationDoNotTreatUnknownWorkAsReadOnly() async throws {
        let tab = try await loadedTab("<p>Article</p>")
        let observer = ArchivePageWorkObserver.shared
        let clean = await observer.confirm(tab)
        XCTAssertTrue(clean)
        let view = try XCTUnwrap(tab.webView)
        _ = try await view.evaluateJavaScript("delete globalThis.__browserArchiveWork; 0", contentWorld: .world(name: "BrowserArchiveWork"))
        let missing = await observer.confirm(tab)
        XCTAssertFalse(missing)
        XCTAssertEqual(tab.archivePageWork, .unknown)
        observer.navigationStarted(in: view)
        XCTAssertNil(observer.documentID(in: view))
        XCTAssertEqual(tab.archivePageWork, .unknown)
    }

    func testPendingPanelsLoadErrorsVisibleSplitPanesAndOpenerLinksAreProtected() async throws {
        let browser = browser()
        let first = browser.tabs[0], second = browser.tabs[1]
        let waiter = Task { await first.waitUntilSelected() }
        await Task.yield()
        XCTAssertFalse(browser.canArchive(first))
        first.stopWaitingForSelection()
        let panelResult = await waiter.value
        XCTAssertFalse(panelResult)
        let error = try XCTUnwrap(PageLoadError(URLError(.timedOut), url: url))
        first.showLoadError(error, coversPreviousPage: false)
        XCTAssertFalse(browser.canArchive(first))
        first.clearLoadError()
        XCTAssertTrue(browser.makeSplit(first.id, with: second.id))
        browser.activeTabID = first.id
        XCTAssertEqual(browser.visibleTabIDs, Set([first.id, second.id]))
        XCTAssertFalse(browser.canArchive(first))
        XCTAssertFalse(browser.canArchive(second))
        browser.splits = []
        browser.activeTabID = browser.tabs.last?.id
        second.openerID = first.id
        second.isPopUp = true
        XCTAssertFalse(browser.canArchive(first))
        XCTAssertFalse(browser.canArchive(second))
        browser.windowDidClose()
    }

    func testPlayingMediaAfterAcknowledgedWriteStillKeepsLiveTab() async throws {
        let gate = WriteGate()
        let store = TabArchiveStore(persist: gate.write)
        let browser = browser(store: store)
        let tab = browser.tabs[0]
        var playing = false
        browser.archiveMediaCheck = { _ in playing }
        let operation = Task { await browser.archiveTab(tab.id) }
        await gate.wait()
        playing = true
        gate.release()
        let archived = await operation.value
        XCTAssertFalse(archived)
        XCTAssertTrue(browser.tabs[0] === tab)
        XCTAssertEqual(store.snapshot.records.count, 1)
    }

    func testWallClockLastUseDecodesLegacySessionsAndRoundTripsWithoutLoadingBackgroundTabs() throws {
        let legacy = Data("{\"url\":\"https://archive.invalid/page\",\"title\":\"Legacy\"}".utf8)
        let entry = try JSONDecoder().decode(TabSession.self, from: legacy)
        XCTAssertNil(entry.lastUsedAt)
        let browser = browser()
        let lastUse = Date(timeIntervalSince1970: 12345)
        browser.tabs[0].lastUsedAt = lastUse
        let encoded = try PropertyListEncoder().encode(browser.windowSession())
        let saved = try PropertyListDecoder().decode(WindowSession.self, from: encoded)
        let restored = BrowserModel()
        restored.restoreSession(saved)
        XCTAssertEqual(restored.tabs[0].lastUsedAt, lastUse)
        XCTAssertNil(restored.tabs[0].webView)
        restored.restoreSession(WindowSession(tabs: [entry, TabSession(url: nil, title: "", interactionState: nil)], selectedIndex: 1))
        XCTAssertLessThan(abs(restored.tabs[0].lastUsedAt.timeIntervalSinceNow), 5)
        XCTAssertNil(restored.tabs[0].webView)
    }

    func testIdlePolicyRejectsClockJumpsSleepWakeAndRestartAndBoundsAutomaticPasses() async throws {
        let start = ContinuousClock.now
        let wall = Date(timeIntervalSince1970: 100000)
        var policy = TabArchiveIdlePolicy()
        XCTAssertFalse(policy.permitsPass(now: wall, instant: start))
        for minute in 1..<30 {
            XCTAssertFalse(policy.permitsPass(now: wall.addingTimeInterval(Double(minute * 60)), instant: start + .seconds(minute * 60)))
        }
        XCTAssertTrue(policy.permitsPass(now: wall.addingTimeInterval(1800), instant: start + .seconds(1800)))
        XCTAssertFalse(policy.permitsPass(now: wall.addingTimeInterval(-90000), instant: start + .seconds(1860)))
        XCTAssertFalse(policy.permitsPass(now: wall.addingTimeInterval(900000), instant: start + .seconds(1920)))
        XCTAssertFalse(policy.permitsPass(now: wall.addingTimeInterval(910000), instant: start + .seconds(11920)))
        XCTAssertFalse(TabArchiveIdlePolicy.isIdle(lastUsed: wall.addingTimeInterval(100), lastActive: start - .seconds(10000), now: wall, instant: start, policy: .init(automaticEnabled: true)))
        XCTAssertFalse(TabArchiveIdlePolicy.isIdle(lastUsed: wall.addingTimeInterval(-100000), lastActive: start, now: wall, instant: start, policy: .init(automaticEnabled: true)))

        let store = TabArchiveStore()
        let browser = browser(store: store)
        XCTAssertFalse(store.policy(forProfileID: browser.tabs[0].profileID).automaticEnabled)
        try await store.setPolicy(.init(automaticEnabled: true), forProfileID: browser.tabs[0].profileID)
        for tab in browser.tabs.prefix(2) {
            tab.archivePageWork = .readOnly
            tab.lastUsedAt = wall.addingTimeInterval(-100000)
            tab.lastActive = start - .seconds(10000)
        }
        await browser.archiveIdleTabs(now: wall, instant: start)
        XCTAssertTrue(store.snapshot.records.isEmpty)
        for minute in 1...30 {
            await browser.archiveIdleTabs(now: wall.addingTimeInterval(Double(minute * 60)), instant: start + .seconds(minute * 60))
        }
        XCTAssertEqual(store.snapshot.records.count, 1)
        XCTAssertEqual(browser.tabs.count, 2)
        browser.resetArchiveIdleGrace()
        await browser.archiveIdleTabs(now: wall.addingTimeInterval(1860), instant: start + .seconds(1860))
        XCTAssertEqual(store.snapshot.records.count, 1, "A wake notification resets grace even after a short sleep")
    }

    func testAtomicPersistenceRecoveryPermissionsAndBounds() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Archive.plist")
        let store = TabArchiveStore(url: file)
        let first = record(state: Data([1, 2, 3]))
        try await store.insert(first)
        try await store.setPolicy(.init(automaticEnabled: true), forProfileID: first.profileID)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let reloaded = TabArchiveStore(url: file)
        XCTAssertEqual(reloaded.snapshot.records, [first])
        XCTAssertTrue(reloaded.policy(forProfileID: first.profileID).automaticEnabled)
        try Data("broken".utf8).write(to: file)
        let recovered = TabArchiveStore(url: file)
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.snapshot.records, [first])
        var oversized = TabArchiveSnapshot()
        oversized.records = [record(state: Data(count: TabArchiveStore.maximumStateBytes + 1))]
        XCTAssertFalse(TabArchiveStore.valid(oversized))
        oversized.records = [first, first]
        XCTAssertFalse(TabArchiveStore.valid(oversized))
        let corrupt = root.appending(path: "Corrupt.plist")
        try Data("not recoverable".utf8).write(to: corrupt)
        let unavailable = TabArchiveStore(url: corrupt)
        do { try await unavailable.insert(record()); XCTFail("Must preserve unreadable archive") }
        catch { XCTAssertEqual(try Data(contentsOf: corrupt), Data("not recoverable".utf8)) }
    }

    func testFailedRollbackCanReplaceFreshCaptureWithoutBusyOrDuplicateRecords() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WriteGate()
        gate.failWrites = [2, 3]
        let archiveURL = root.appending(path: "Archive.plist")
        let file = TabArchiveFile(url: archiveURL)
        gate.writer = { try await file.write($0) }
        let store = TabArchiveStore(url: archiveURL, persist: gate.write)
        let browser = browser(store: store)
        let sessions = SessionStore(file: StoreFile(url: root.appending(path: "Session.plist")), saveDelay: .seconds(60))
        _ = sessions.attach(browser, restoringPendingWindows: false)
        let original = browser.tabs[0]
        let operation = Task { await browser.archiveTab(original.id) }
        await gate.wait()
        original.invalidateNavigation()
        gate.release()
        let stale = await operation.value
        XCTAssertFalse(stale)
        XCTAssertTrue(browser.tabs[0] === original)
        let recovery = try XCTUnwrap(store.snapshot.records.first)
        XCTAssertEqual(gate.writes, 2) // Durable insert, then failed rollback cleanup.
        XCTAssertEqual(TabArchiveStore(url: archiveURL).snapshot.records, [recovery])
        let retryFailure = await browser.archiveTab(original.id)
        XCTAssertFalse(retryFailure)
        XCTAssertEqual(store.snapshot.records, [recovery]) // Failed replacement keeps the last recovery copy.
        XCTAssertEqual(TabArchiveStore(url: archiveURL).snapshot.records, [recovery])
        XCTAssertTrue(browser.tabs[0] === original)
        let retry = await browser.archiveTab(original.id)
        XCTAssertTrue(retry)
        XCTAssertEqual(store.snapshot.records.count, 1)
        XCTAssertNotEqual(store.snapshot.records.first?.id, recovery.id)
        XCTAssertEqual(store.snapshot.records.first?.tabID, original.id)
        XCTAssertNil(browser.tabAcrossSpaces(withID: original.id))
        let reloaded = TabArchiveStore(url: archiveURL)
        XCTAssertEqual(reloaded.snapshot.records, store.snapshot.records)
        XCTAssertEqual(reloaded.snapshot.records.filter { $0.tabID == original.id }.count, 1)
    }

    func testFailedRestoreCleanupRetriesOnlyAfterLiveSessionIsDurable() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appending(path: "blocked")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("a file, not a directory".utf8).write(to: blocked)
        let sessionFile = StoreFile(url: blocked.appending(path: "Session.plist"))
        let sessions = SessionStore(file: sessionFile, saveDelay: .seconds(60))
        let gate = WriteGate()
        gate.gatesFirst = false
        let store = TabArchiveStore(persist: gate.write)
        let browser = browser(store: store)
        _ = sessions.attach(browser, restoringPendingWindows: false)
        let original = browser.tabs[0]
        let archived = await browser.archiveTab(original.id)
        XCTAssertTrue(archived)
        let copy = try XCTUnwrap(store.snapshot.records.first)
        let restored = await browser.restoreArchivedTab(copy.id, select: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(store.snapshot.records, [copy])
        XCTAssertEqual(gate.writes, 1) // Failed live-session save must not attempt to delete recovery.
        try FileManager.default.removeItem(at: blocked)
        gate.failWrites = [2]
        await browser.reconcileArchiveRecovery()
        XCTAssertEqual(store.snapshot.records, [copy]) // Live saved, but archive cleanup failed.
        let liveDisk = try PropertyListDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: sessionFile.url))
        XCTAssertEqual(liveDisk.windows[0].tabs.filter { $0.id == original.id }.count, 1)
        await browser.reconcileArchiveRecovery()
        XCTAssertTrue(store.snapshot.records.isEmpty)
        XCTAssertEqual(browser.tabs.filter { $0.id == original.id }.count, 1)
    }

    func testRestartReconcilesDuplicateAndPendingWindowCannotRestoreAnotherCopy() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "Archive.plist")
        let previous = TabArchiveStore(url: file)
        let copy = record()
        try await previous.insert(copy)
        let pending = WindowSession(tabs: [TabSession(url: url, title: copy.title, interactionState: nil,
            id: copy.tabID, spaceID: spaceID, profileID: copy.profileID),
            TabSession(url: nil, title: "", interactionState: nil)], selectedIndex: 1)
        let first = WindowSession(tabs: [TabSession(url: nil, title: "", interactionState: nil)], selectedIndex: 0)
        let sessionURL = root.appending(path: "Session.plist")
        try PropertyListEncoder().encode(SessionSnapshot(windows: [first, pending])).write(to: sessionURL)
        let sessions = SessionStore(file: StoreFile(url: sessionURL), saveDelay: .seconds(60))
        let store = TabArchiveStore(url: file)
        let browser = BrowserModel(tabArchive: store)
        XCTAssertEqual(sessions.attach(browser), 1)
        XCTAssertTrue(store.hasPendingSessionTab(copy))
        XCTAssertTrue(store.visibleRecords(spaceID: spaceID, profileID: copy.profileID).isEmpty)
        let duplicate = await browser.restoreArchivedTab(copy.id, select: false)
        XCTAssertFalse(duplicate)
        XCTAssertNil(browser.tabAcrossSpaces(withID: copy.tabID))
        let second = BrowserModel(tabArchive: store)
        _ = sessions.attach(second)
        for _ in 0..<100 {
            if store.snapshot.records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.hasPendingSessionTab(copy))
        XCTAssertTrue(store.snapshot.records.isEmpty)
        XCTAssertEqual((browser.allTabs + second.allTabs).filter { $0.id == copy.tabID }.count, 1)
        XCTAssertNil(second.tabAcrossSpaces(withID: copy.tabID)?.webView)
        let reloaded = TabArchiveStore(url: file)
        XCTAssertTrue(reloaded.snapshot.records.isEmpty)
        let saved = try PropertyListDecoder().decode(SessionSnapshot.self, from: Data(contentsOf: sessionURL))
        XCTAssertEqual(saved.windows.flatMap(\.tabs).filter { $0.id == copy.tabID }.count, 1)
    }

    func testRealSwiftEncodedBudgetRejectsBeforeWriteAndLiveRemovalAndReloadsBoundaryCopies() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Archive.plist")
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let count = TabArchiveStore.maximumRecords - 1
        var states = (0..<count).map { index -> Data in
            let size = TabArchiveStore.maximumTotalStateBytes / count
                + (index < TabArchiveStore.maximumTotalStateBytes % count ? 1 : 0)
            var data = Data(repeating: UInt8(index % 251), count: size)
            data.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(index).littleEndian) { Data($0) })
            return data
        }
        func fixture() -> TabArchiveSnapshot {
            var snapshot = TabArchiveSnapshot()
            snapshot.records = (0..<count).map { index in
                ArchivedTab(id: UUID(), tabID: UUID(), spaceID: spaceID, profileID: BrowserProfile.defaultID,
                    url: URL(string: "https://archive.invalid/\(index)/" + String(repeating: "u", count: 16300))!,
                    title: "\(index)" + String(repeating: "t", count: 4000), archivedAt: Date(timeIntervalSince1970: 1234),
                    lastUsedAt: Date(timeIntervalSince1970: 1234), interactionState: states[index], originalIndex: index)
            }
            return snapshot
        }
        let oversizedInitial = try encoder.encode(fixture())
        XCTAssertGreaterThan(oversizedInitial.count, TabArchiveStore.maximumEncodedBytes)
        var trim = oversizedInitial.count - TabArchiveStore.maximumEncodedBytes + 2048
        for index in states.indices where trim > 0 {
            let remove = min(trim, states[index].count - 8)
            states[index].removeLast(remove)
            trim -= remove
        }
        let boundary = fixture()
        let encoded = try encoder.encode(boundary)
        XCTAssertTrue(TabArchiveStore.valid(boundary))
        XCTAssertLessThanOrEqual(encoded.count, TabArchiveStore.maximumEncodedBytes)
        XCTAssertGreaterThan(encoded.count, TabArchiveStore.maximumEncodedBytes - 16_384)
        try encoded.write(to: file)
        let store = TabArchiveStore(url: file)
        XCTAssertEqual(store.snapshot.records.count, count)
        try await store.setPolicy(.init(automaticEnabled: true), forProfileID: BrowserProfile.defaultID) // Creates a boundary-sized recovery file.
        XCTAssertEqual(TabArchiveStore(url: file).snapshot.records.count, count)
        XCTAssertEqual(TabArchiveStore(url: file.appendingPathExtension("recovery")).snapshot.records.count, count)
        var writes = 0
        let injected = TabArchiveStore(url: file, persist: { _ in writes += 1 })
        let browser = BrowserModel(tabArchive: injected)
        let longURL = URL(string: "https://archive.invalid/extra/" + String(repeating: "v", count: 16300))!
        browser.restoreSession(WindowSession(tabs: [TabSession(url: longURL, title: String(repeating: "x", count: 1024), interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil)], selectedIndex: 1))
        let original = browser.tabs[0]
        let archived = await browser.archiveTab(original.id)
        XCTAssertFalse(archived)
        XCTAssertEqual(writes, 0)
        XCTAssertTrue(browser.tabs[0] === original)
        XCTAssertEqual(injected.snapshot.records.count, count)
        var oversized = boundary
        oversized.records.append(ArchivedTab(id: UUID(), tabID: UUID(), spaceID: spaceID, profileID: BrowserProfile.defaultID,
            url: longURL, title: String(repeating: "x", count: 1024), archivedAt: Date(), lastUsedAt: Date(),
            interactionState: nil, originalIndex: 0))
        let rejected = try encoder.encode(oversized)
        XCTAssertTrue(TabArchiveStore.valid(oversized))
        XCTAssertGreaterThan(rejected.count, TabArchiveStore.maximumEncodedBytes)
        try rejected.write(to: file)
        let recovered = TabArchiveStore(url: file)
        XCTAssertTrue(recovered.recovered)
        XCTAssertEqual(recovered.snapshot.records.count, count)
    }

    func testPointerOnlyDrawingAndCustomShadowEditorCannotRemoveLiveDescriptor() async throws {
        let browser = browser()
        let drawing = browser.tabs[0]
        drawing.restore()
        let view = try XCTUnwrap(drawing.webView)
        view.loadHTMLString("""
            <canvas width="40" height="40"></canvas>
            <script>
            const canvas = document.querySelector('canvas');
            canvas.addEventListener('pointerdown', event => {
                canvas.getContext('2d').fillRect(0, 0, 10, 10);
                window.unsavedStrokes = (window.unsavedStrokes || 0) + 1;
            });
            </script>
            """, baseURL: url)
        try await waitForDocument(view)
        _ = try await view.evaluateJavaScript("document.querySelector('canvas').dispatchEvent(new PointerEvent('pointerdown', {bubbles:true}))")
        let strokes = try await view.evaluateJavaScript("window.unsavedStrokes") as? Int
        XCTAssertEqual(strokes, 1)
        let archived = await browser.archiveTab(drawing.id)
        XCTAssertFalse(archived)
        XCTAssertTrue(browser.tabs[0] === drawing)
        XCTAssertTrue(drawing.webView === view)
        XCTAssertTrue(browser.tabArchive.snapshot.records.isEmpty)
        for fixture in ["<drawing-editor></drawing-editor>", "<div role='application'></div>",
                        "<div id='host'></div><script>host.attachShadow({mode:'closed'}).innerHTML='<textarea></textarea>'</script>"] {
            let tab = try await loadedTab(fixture)
            let safe = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertFalse(safe)
        }
        let custom = try await loadedTab("<div>Pointer editor without standard semantics</div>")
        let before = await ArchivePageWorkObserver.shared.confirm(custom)
        XCTAssertTrue(before)
        _ = try await custom.webView?.evaluateJavaScript("document.body.dispatchEvent(new PointerEvent('pointerdown', {bubbles:true}))")
        let after = await ArchivePageWorkObserver.shared.confirm(custom)
        XCTAssertFalse(after)
    }

    func testInlineSVGKeyboardAndWheelEditorsKeepNativeProtectionAndOriginalDescriptor() async throws {
        let fixtures: [(String, String)] = [
            ("""
             <svg id="editor" tabindex="0" onkeydown="if(event.key==='ArrowRight'){window.unsavedX=(window.unsavedX||0)+1;this.querySelector('rect').setAttribute('x',window.unsavedX)}">
               <rect width="10" height="10"/>
             </svg>
             """, "new KeyboardEvent('keydown', {key:'ArrowRight', bubbles:true})"),
            ("""
             <svg id="editor" tabindex="0" ONWHEEL="window.unsavedX=(window.unsavedX||0)+1;this.querySelector('rect').setAttribute('x',window.unsavedX)">
               <rect width="10" height="10"/>
             </svg>
             """, "new WheelEvent('wheel', {deltaY:1, bubbles:true})")
        ]
        for (html, event) in fixtures {
            let (browser, original, view) = try await backgroundDocument(html)
            defer { browser.windowDidClose() }
            let ids = browser.tabs.map(\.id)
            // Handler inspection must block even before an editing event happens.
            let before = await ArchivePageWorkObserver.shared.confirm(original)
            XCTAssertFalse(before)
            XCTAssertEqual(original.archivePageWork, .protected)
            _ = try await view.evaluateJavaScript("document.getElementById('editor').focus(); document.getElementById('editor').dispatchEvent(\(event)); 0")
            let edits = try await view.evaluateJavaScript("window.unsavedX") as? Int
            let position = try await view.evaluateJavaScript("document.querySelector('rect').getAttribute('x')") as? String
            XCTAssertEqual(edits, 1)
            XCTAssertEqual(position, "1")
            let after = await ArchivePageWorkObserver.shared.confirm(original)
            XCTAssertFalse(after)
            let archived = await browser.archiveTab(original.id)
            XCTAssertFalse(archived)
            XCTAssertEqual(browser.tabs.map(\.id), ids)
            XCTAssertTrue(browser.tabs[0] === original)
            XCTAssertTrue(original.webView === view)
            XCTAssertTrue(browser.tabArchive.snapshot.records.isEmpty)
        }
    }

    func testAllHandlerNamesIncludingAddedDynamicAndRemovedAttributesFailClosed() async throws {
        for html in ["<p onfutureeditingevent='work()'>Article</p>",
                     "<svg><g oNsAfEtYeVeNt='work()'></g></svg>"] {
            let tab = try await loadedTab(html)
            let safe = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertFalse(safe, html)
        }
        let installations = [
            "document.getElementById('editor').setAttribute('onkeydown', \"if(event.key==='ArrowRight')window.unsavedX=1\");",
            "document.getElementById('editor').setAttribute('oNsAfEtYeVeNt', 'work()');",
            "const node=document.createElementNS('http://www.w3.org/2000/svg','g'); node.setAttribute('ONWHEEL','work()'); document.querySelector('svg').appendChild(node);",
            "const node=document.getElementById('editor'); node.setAttribute('onfutureeditingevent','work()'); node.removeAttribute('onfutureeditingevent');"
        ]
        for installation in installations {
            let (browser, original, view) = try await backgroundDocument("<svg id='editor' tabindex='0'><rect width='10' height='10'/></svg>")
            defer { browser.windowDidClose() }
            let clean = await ArchivePageWorkObserver.shared.confirm(original)
            XCTAssertTrue(clean)
            _ = try await view.evaluateJavaScript(installation + " 0")
            try await waitForProtection(original)
            XCTAssertEqual(original.archivePageWork, .protected)
            let safe = await ArchivePageWorkObserver.shared.confirm(original)
            XCTAssertFalse(safe, installation)
            let archived = await browser.archiveTab(original.id)
            XCTAssertFalse(archived)
            XCTAssertTrue(browser.tabs[0] === original)
            XCTAssertTrue(original.webView === view)
        }
    }

    func testExecutableURIAttributesAndRemovedScriptEvidenceFailClosed() async throws {
        let (browser, original, view) = try await backgroundDocument("""
            <a id="action" tabindex="0" href="&#x09;jAvA&#x0a;ScRiPt:window.unsavedURI=(window.unsavedURI||0)+1;void(0)">Keyboard action</a>
            """)
        defer { browser.windowDidClose() }
        let safe = await ArchivePageWorkObserver.shared.confirm(original)
        XCTAssertFalse(safe)
        _ = try await view.evaluateJavaScript("document.getElementById('action').click(); 0")
        var edits: Int?
        for _ in 0..<200 {
            edits = try? await view.evaluateJavaScript("window.unsavedURI ?? 0") as? Int
            if edits == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(edits, 1)
        let archived = await browser.archiveTab(original.id)
        XCTAssertFalse(archived)
        XCTAssertTrue(browser.tabs[0] === original)
        XCTAssertTrue(original.webView === view)
        for html in ["<svg><a xlink:href='javascript:work()'>Action</a></svg>",
                     "<a href='data:text/html,work'>Action</a>", "<a href='blob:https://archive.invalid/id'>Action</a>"] {
            let tab = try await loadedTab(html)
            let clean = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertFalse(clean, html)
        }
        let mutations = [
            "const link=document.getElementById('link'); link.setAttribute('href','java\\tscript:work()'); link.removeAttribute('href');",
            "const node=document.createElementNS('http://www.w3.org/2000/svg','a'); node.setAttributeNS('http://www.w3.org/1999/xlink','xlink:href','javascript:work()'); document.body.appendChild(node);",
            "const script=document.createElement('script'); script.textContent='window.unsavedTransient=1'; document.body.appendChild(script); script.remove();"
        ]
        for mutation in mutations {
            let tab = try await loadedTab("<a id='link'>Read-only</a>")
            let clean = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertTrue(clean)
            _ = try await tab.webView?.evaluateJavaScript(mutation + " 0")
            try await waitForProtection(tab)
            let after = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertFalse(after, mutation)
            if mutation.contains("script.textContent") {
                let ran = try await tab.webView?.evaluateJavaScript("window.unsavedTransient") as? Int
                XCTAssertEqual(ran, 1)
                let removed = try await tab.webView?.evaluateJavaScript("document.querySelector('script') === null") as? Bool
                XCTAssertEqual(removed, true)
            }
        }
    }

    func testInspectionBudgetAndUnknownKeyboardWheelActionsFailClosed() async throws {
        for html in [String(repeating: "<span></span>", count: 5000),
                     "<p data-long='" + String(repeating: "x", count: 8193) + "'>Article</p>"] {
            let tab = try await loadedTab(html)
            let clean = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertFalse(clean)
        }
        for event in ["new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true})", "new WheelEvent('wheel',{bubbles:true})"] {
            let tab = try await loadedTab("<svg><rect width='10' height='10'/></svg>")
            let clean = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertTrue(clean)
            _ = try await tab.webView?.evaluateJavaScript("document.body.dispatchEvent(\(event)); 0")
            try await waitForProtection(tab)
            let after = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertFalse(after)
        }
    }

    func testSameURLDocumentReloadDuringPendingWriteKeepsOriginalDescriptor() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appending(path: "Archive.plist")
        let file = TabArchiveFile(url: archiveURL)
        let gate = WriteGate()
        gate.writer = { try await file.write($0) }
        let store = TabArchiveStore(url: archiveURL, persist: gate.write)
        let (browser, original, view) = try await backgroundDocument("<title>Before reload</title><p>Article</p>", store: store)
        defer { gate.release(); browser.windowDidClose() }
        let clean = await ArchivePageWorkObserver.shared.confirm(original)
        XCTAssertTrue(clean)
        let revision = original.navigationRevision
        let token = try XCTUnwrap(ArchivePageWorkObserver.shared.documentID(in: view))
        let address = try XCTUnwrap(original.url)
        let operation = Task { await browser.archiveTab(original.id) }
        await gate.wait()
        original.reload()
        // Supply a local replacement document at the exact same URL, without a network server.
        view.loadHTMLString("<title>After reload</title><p>Replacement article</p>", baseURL: address)
        try await waitForDocument(view)
        let reloadedClean = await ArchivePageWorkObserver.shared.confirm(original)
        XCTAssertTrue(reloadedClean)
        XCTAssertEqual(original.url, address)
        XCTAssertNotEqual(original.navigationRevision, revision)
        XCTAssertNotEqual(ArchivePageWorkObserver.shared.documentID(in: view), token)
        gate.release()
        let archived = await operation.value
        XCTAssertFalse(archived)
        XCTAssertTrue(browser.tabs[0] === original)
        XCTAssertTrue(original.webView === view)
        XCTAssertEqual(TabArchiveStore(url: archiveURL).snapshot.records.first?.tabID, original.id)
    }

    func testDirtyNotificationDuringFinalMediaAwaitKeepsOriginalDescriptor() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appending(path: "Archive.plist")
        let store = TabArchiveStore(url: archiveURL)
        let (browser, original, view) = try await backgroundDocument("<p>Read-only article</p>", store: store)
        let finalMedia = WriteGate()
        defer { finalMedia.release(); browser.windowDidClose() }
        var mediaCalls = 0
        browser.archiveMediaCheck = { _ in
            mediaCalls += 1
            if mediaCalls == 2 { try? await finalMedia.write(Data()) }
            return false
        }
        let revision = original.navigationRevision
        let operation = Task { await browser.archiveTab(original.id) }
        await finalMedia.wait()
        XCTAssertEqual(mediaCalls, 2)
        XCTAssertEqual(store.snapshot.records.first?.tabID, original.id)
        _ = try await view.evaluateJavaScript("document.body.dispatchEvent(new WheelEvent('wheel',{bubbles:true})); 0")
        try await waitForProtection(original) // Actual isolated-world notification, not direct native injection.
        XCTAssertEqual(original.navigationRevision, revision)
        finalMedia.release()
        let archived = await operation.value
        XCTAssertFalse(archived)
        XCTAssertEqual(original.archivePageWork, .protected)
        XCTAssertTrue(browser.tabs[0] === original)
        XCTAssertTrue(original.webView === view)
        XCTAssertEqual(TabArchiveStore(url: archiveURL).snapshot.records.first?.tabID, original.id)
    }

    private func backgroundDocument(_ html: String, store: TabArchiveStore = TabArchiveStore()) async throws -> (BrowserModel, BrowserTab, WKWebView) {
        let browser = browser(store: store)
        let original = browser.tabs[0]
        original.restore()
        let view = try XCTUnwrap(original.webView)
        view.loadHTMLString(html, baseURL: url)
        try await waitForDocument(view)
        return (browser, original, view)
    }

    private func waitForProtection(_ tab: BrowserTab) async throws {
        for _ in 0..<200 {
            if tab.archivePageWork == .protected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The isolated observer did not protect the live document")
    }

    func testDocumentTokensRejectLateMessagesAndSharedControllerRoutesByWebView() async throws {
        let first = try await loadedTab("<p>First document</p>")
        let view = try XCTUnwrap(first.webView)
        let observer = ArchivePageWorkObserver.shared
        let safe = await observer.confirm(first)
        XCTAssertTrue(safe)
        let oldID = try XCTUnwrap(observer.documentID(in: view))
        view.loadHTMLString("<p>Second document</p>", baseURL: url)
        try await waitForDocument(view)
        let clean = await observer.confirm(first)
        XCTAssertTrue(clean)
        let currentID = try XCTUnwrap(observer.documentID(in: view))
        XCTAssertNotEqual(oldID, currentID)
        observer.receive(in: view, documentID: oldID, blocked: true)
        XCTAssertEqual(first.archivePageWork, .readOnly)
        observer.receive(in: view, documentID: currentID, blocked: true)
        XCTAssertEqual(first.archivePageWork, .protected)
        let configuration = BrowserTab.makeConfiguration(includingExtensions: false)
        let one = BrowserTab(configuration: configuration)
        let two = BrowserTab(configuration: configuration.copy() as! WKWebViewConfiguration)
        let oneView = try XCTUnwrap(one.webView), twoView = try XCTUnwrap(two.webView)
        XCTAssertTrue(oneView.configuration.userContentController === twoView.configuration.userContentController)
        oneView.loadHTMLString("<p>One</p>", baseURL: url)
        twoView.loadHTMLString("<p>Two</p>", baseURL: url)
        try await waitForDocument(oneView)
        try await waitForDocument(twoView)
        _ = await observer.confirm(one)
        _ = await observer.confirm(two)
        let token = try XCTUnwrap(observer.documentID(in: twoView))
        observer.receive(in: twoView, documentID: token, blocked: true)
        XCTAssertEqual(two.archivePageWork, .protected)
        XCTAssertEqual(one.archivePageWork, .readOnly)
    }

    private func waitForDocument(_ view: WKWebView) async throws {
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<200 {
            if !view.isLoading, view.url?.host() == "archive.invalid",
               let ready = try? await view.evaluateJavaScript("document.readyState"), ready as? String == "complete" { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture did not load")
    }

    private func loadedTab(_ html: String) async throws -> BrowserTab {
        let tab = BrowserTab(configuration: BrowserTab.makeConfiguration(includingExtensions: false))
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString(html, baseURL: URL(string: "https://archive.invalid/fixture"))
        try await Task.sleep(for: .milliseconds(20))
        for _ in 0..<200 {
            if !view.isLoading, view.url?.host() == "archive.invalid",
               let ready = try? await view.evaluateJavaScript("document.readyState"), ready as? String == "complete" {
                return tab
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Fixture did not load")
        return tab
    }

    func testIsolatedDirtySignalProtectsEditorsFramesScriptsAndEventDrivenChanges() async throws {
        for html in ["<input>", "<textarea></textarea>", "<div contenteditable>Editor</div>",
                     "<div role='textbox'>Editor</div>", "<iframe src='about:blank'></iframe>",
                     "<input type='file'>", "<canvas></canvas>", "<script>globalThis.work = true</script>"] {
            let tab = try await loadedTab(html)
            let safe = await ArchivePageWorkObserver.shared.confirm(tab)
            XCTAssertFalse(safe, html)
            XCTAssertEqual(tab.archivePageWork, .protected, html)
        }
        let tab = try await loadedTab("<p>Read-only article</p>")
        let clean = await ArchivePageWorkObserver.shared.confirm(tab)
        XCTAssertTrue(clean)
        _ = try await tab.webView?.evaluateJavaScript("document.body.dispatchEvent(new Event('input', {bubbles:true}))", contentWorld: .defaultClient)
        let dirty = await ArchivePageWorkObserver.shared.confirm(tab)
        XCTAssertFalse(dirty)
        _ = try await tab.webView?.evaluateJavaScript("document.body.dispatchEvent(new Event('reset', {bubbles:true}))", contentWorld: .defaultClient)
        let afterReset = await ArchivePageWorkObserver.shared.confirm(tab)
        XCTAssertFalse(afterReset)
        let dynamic = try await loadedTab("<p>Article</p>")
        _ = try await dynamic.webView?.evaluateJavaScript("document.body.appendChild(document.createElement('textarea')); 0", contentWorld: .defaultClient)
        let editor = await ArchivePageWorkObserver.shared.confirm(dynamic)
        XCTAssertFalse(editor)
    }
}
