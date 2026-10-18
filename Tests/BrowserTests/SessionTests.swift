import XCTest
@testable import Browser

@MainActor
final class SessionTests: XCTestCase {
    private func page(titled title: String) -> URL {
        URL(string: "https://session-test.invalid/\(title)")!
    }

    private func makeFile() -> StoreFile {
        StoreFile(url: FileManager.default.temporaryDirectory
            .appending(path: "BrowserTests-\(UUID().uuidString)")
            .appending(path: "Session.plist"))
    }

    private func window(_ titles: [String], selected: Int = 0) -> WindowSession {
        WindowSession(tabs: titles.map { TabSession(url: page(titled: $0), title: $0, interactionState: nil) },
                      selectedIndex: selected)
    }

    func testSnapshotRoundTripsThroughAPropertyList() throws {
        let snapshot = SessionSnapshot(
            windows: [WindowSession(tabs: [
                TabSession(url: URL(string: "https://swift.org")!, title: "Swift", interactionState: Data([1, 2, 3])),
                TabSession(url: nil, title: "", interactionState: nil),
            ], selectedIndex: 1)],
            closedWindows: [window(["Closed"])])

        let data = try PropertyListEncoder.binary.encode(snapshot)

        XCTAssertEqual(try PropertyListDecoder().decode(SessionSnapshot.self, from: data), snapshot)
    }

    func testRestoredTabsAreSuspendedExceptTheSelectedOne() throws {
        let browser = BrowserModel()
        var session = window(["First", "Second", "Third"], selected: 2)
        session.tabs.insert(TabSession(url: nil, title: "", interactionState: nil), at: 1)

        browser.restoreSession(session)

        XCTAssertEqual(browser.tabs.count, 4)
        XCTAssertEqual(browser.activeTabID, browser.tabs[2].id)
        XCTAssertTrue(browser.tabs[0].isSuspended)
        XCTAssertEqual(browser.tabs[0].title, "First")
        XCTAssertTrue(browser.tabs[1].isNewTab)
        XCTAssertFalse(browser.tabs[2].isSuspended)
        XCTAssertTrue(browser.tabs[3].isSuspended)

        let saved = browser.windowSession()
        XCTAssertEqual(saved.selectedIndex, 2)
        XCTAssertEqual(saved.tabs.map(\.url), [page(titled: "First"), nil, page(titled: "Second"),
                                               page(titled: "Third")])
        XCTAssertEqual(saved.tabs.map(\.title), ["First", "", "Second", "Third"])
    }

    func testFirstWindowRestoresTheSessionAndAsksForTheOtherWindows() {
        let file = makeFile()
        file.writeNow(try? PropertyListEncoder.binary.encode(SessionSnapshot(windows: [
            window(["A"]), window(["B"]), window(["C1", "C2"], selected: 1),
        ])))
        let session = SessionStore(file: file)
        let browsers = (0..<4).map { _ in BrowserModel() }

        XCTAssertEqual(session.attach(browsers[0]), 2)
        XCTAssertEqual(session.attach(browsers[1]), 0)
        XCTAssertEqual(session.attach(browsers[2]), 0)
        XCTAssertEqual(session.attach(browsers[3]), 0)

        XCTAssertEqual(browsers.map(\.activeTab?.title), ["A", "B", "C2", "New Tab"])
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }

    func testClosingTheLastWindowKeepsItForReopening() {
        let session = SessionStore(file: nil)
        let closing = BrowserModel()
        closing.restoreSession(window(["One", "Two"], selected: 1))
        _ = session.attach(closing)

        session.detach(closing)
        XCTAssertEqual(session.reopenableWindows.map(\.tabs.count), [2])

        let blank = BrowserModel()
        _ = session.attach(blank)
        XCTAssertEqual(session.reopenLastSession(reusing: blank), 0)

        XCTAssertEqual(blank.tabs.map(\.title), ["One", "Two"])
        XCTAssertEqual(blank.activeTabID, blank.tabs[1].id)
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }

    func testWindowsWaitInTheHistoryMenuWhenNotRestoredOnLaunch() {
        let file = makeFile()
        file.writeNow(try? PropertyListEncoder.binary.encode(SessionSnapshot(windows: [window(["A"]), window(["B"])],
                                                                             closedWindows: [window(["Old"])])))
        let session = SessionStore(file: file, restoresWindows: false)
        let browser = BrowserModel()

        XCTAssertEqual(session.attach(browser), 0)
        XCTAssertTrue(browser.isBlank)
        XCTAssertEqual(session.reopenableWindows.map { $0.tabs.map(\.title) }, [["A"], ["B"]])

        session.forgetClosedWindows()
        XCTAssertTrue(session.reopenableWindows.isEmpty)
    }

    func testPrivateWindowsArentSaved() {
        let session = SessionStore(file: nil)
        let normal = BrowserModel()
        normal.restoreSession(window(["Normal"]))
        _ = session.attach(normal)
        // BrowserWindow never attaches a private window.
        let privateWindow = BrowserModel.makePrivate(downloads: DownloadManager())
        privateWindow.restoreSession(window(["Private"]))

        XCTAssertEqual(session.snapshot.windows.map { $0.tabs.map(\.title) }, [["Normal"]])
    }

    func testSessionSavedOnQuitIsRestoredByTheNextLaunch() {
        let file = makeFile()
        let session = SessionStore(file: file)
        let browser = BrowserModel()
        _ = session.attach(browser)
        browser.restoreSession(window(["Saved"]))

        session.saveBeforeQuitting()
        session.detach(browser)

        let relaunched = SessionStore(file: file)
        let restored = BrowserModel()
        XCTAssertEqual(relaunched.attach(restored), 0)
        XCTAssertEqual(restored.activeTab?.title, "Saved")
    }
}


extension SessionTests {
    func testMetadataAndWebKitStateRoundTripWithoutLosingSplitConfiguration() throws {
        let section = TemporaryTabSection(title: "Research", symbol: "book")
        let split = BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [0, 1], anchorIndex: 0,
                                                focusedIndex: 1, orientation: .horizontal, weights: [0.4, 0.6])
        let snapshot = SessionSnapshot(windows: [WindowSession(tabs: [
            TabSession(url: page(titled: "Pinned"), title: "Pinned", interactionState: Data([1, 2, 3]), pinnedPageID: UUID()),
            TabSession(url: page(titled: "Folder"), title: "Folder", interactionState: nil, folderPageID: UUID()),
            TabSession(url: page(titled: "Grouped"), title: "Grouped", interactionState: nil, temporarySection: section),
        ], selectedIndex: 1, splits: [split])])
        XCTAssertEqual(try PropertyListDecoder().decode(SessionSnapshot.self,
                       from: PropertyListEncoder.binary.encode(snapshot)), snapshot)
    }

    func testLegacyJSONSessionMigratesAndKeepsRecoveryFile() throws {
        let file = makeFile()
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var legacy = BrowserSessionSnapshot(tabs: [
            .init(url: page(titled: "Recovered"), title: "Recovered", temporarySection: TemporaryTabSection(title: "Group", symbol: "book")),
            .init(url: nil, title: ""),
        ], selectedIndex: 1)
        legacy.splits = [BrowserSessionSnapshot.Split(id: UUID(), tabIndices: [0, 1], anchorIndex: 0,
                                                     focusedIndex: 1, orientation: .horizontal, weights: [0.5, 0.5])]
        let legacyFile = directory.appending(path: "Session.json")
        let legacyData = try JSONEncoder().encode(legacy)
        try legacyData.write(to: legacyFile)
        let store = SessionStore(file: file, restoresWindows: false)
        XCTAssertEqual(store.reopenableWindows, [WindowSession(legacy: legacy)])
        store.saveBeforeQuitting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try Data(contentsOf: legacyFile), legacyData)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testContinuousUpdatesDoNotPostponeSessionSaveForever() async throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let store = SessionStore(file: file, saveDelay: .milliseconds(30))
        let browser = BrowserModel()
        _ = store.attach(browser)
        for _ in 0..<12 {
            store.requestSave()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(file.readNow())
    }
}


extension SessionTests {
    func testSavingBeforeAndDuringWindowRestorationPreservesPendingWindows() async throws {
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let original = SessionSnapshot(windows: [window(["A"]), window(["B"]), window(["C"])])
        file.writeNow(try PropertyListEncoder.binary.encode(original))
        // Force an observable publication marker even when the first save has the same contents.
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.url.path)
        let store = SessionStore(file: StoreFile(url: file.url), saveDelay: .milliseconds(10))

        store.requestSave()
        try await waitUntil {
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.url.path))?[.modificationDate] as? Date
            return modified.map { $0 != oldDate } ?? false
        }
        let beforeAttach = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
        XCTAssertEqual(beforeAttach, original)

        let first = BrowserModel()
        XCTAssertEqual(store.attach(first), 2)
        first.addTab()
        store.requestSave()
        try await waitUntil {
            guard let data = file.readNow(),
                  let saved = try? PropertyListDecoder().decode(SessionSnapshot.self, from: data) else { return false }
            return saved.windows.first?.tabs.count == 2
        }
        let partial = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
        XCTAssertEqual(partial.windows.count, 3)
        XCTAssertEqual(partial.windows.dropFirst(), original.windows.dropFirst())

        // Quitting before the remaining windows appear must preserve them too.
        store.saveBeforeQuitting()
        let relaunched = SessionStore(file: StoreFile(url: file.url))
        let recovered = BrowserModel()
        XCTAssertEqual(relaunched.attach(recovered), 2)
        XCTAssertEqual(relaunched.snapshot.windows.count, 3)
        XCTAssertEqual(relaunched.snapshot.windows.dropFirst(), original.windows.dropFirst())
    }
}
