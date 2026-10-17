import XCTest
import WebKit
@testable import Browser

@MainActor
final class BrowserSessionTests: XCTestCase {
    func testSessionSurvivesStoreRecreationWithoutLoadingBackgroundTabs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = BrowserModel()
        let store = BrowserSessionStore(directory: directory)
        store.restore(in: first)
        first.restoreSession(BrowserSessionSnapshot(tabs: [
            .init(url: URL(string: "https://example.com/account"), title: "Account"),
            .init(url: nil, title: "")
        ], selectedIndex: 1))
        store.save(first)

        let second = BrowserModel()
        BrowserSessionStore(directory: directory).restore(in: second)
        XCTAssertEqual(BrowserSessionSnapshot(browser: second), BrowserSessionSnapshot(browser: first))
        XCTAssertTrue(second.tabs[0].isSuspended)
        XCTAssertTrue(second.activeTab?.isNewTab == true)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "Session.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testInvalidSessionFallsBackToNewTabAndSelectionIsClamped() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appending(path: "Session.json"))
        let browser = BrowserModel()
        BrowserSessionStore(directory: directory).restore(in: browser)
        XCTAssertTrue(browser.activeTab?.isNewTab == true)
        browser.restoreSession(.init(tabs: [.init(url: URL(string: "javascript:alert(1)"), title: "Unsafe")], selectedIndex: 999))
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertTrue(browser.activeTab?.isNewTab == true)
    }

    func testExtensionWindowsDoNotOverwriteTheMainSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSessionStore(directory: directory)
        let browser = BrowserModel()
        store.restore(in: browser)
        store.save(browser)
        let file = directory.appending(path: "Session.json")
        let original = try Data(contentsOf: file)
        let popup = BrowserModel()
        popup.isExtensionWindow = true
        popup.addTab()
        store.save(popup)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testPendingChangesCoalesceAndFlushCapturesTheLatestState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSessionStore(directory: directory, saveDelay: .seconds(60))
        let browser = BrowserModel()
        store.restore(in: browser)
        for index in 0..<20 {
            browser.restoreSession(.init(tabs: [
                .init(url: URL(string: "https://example.com/\(index)"), title: "Page \(index)")
            ], selectedIndex: 0))
            store.requestSave(browser)
        }
        let file = directory.appending(path: "Session.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // A final change need not have reached SwiftUI's observation callback at shutdown.
        browser.addTab()
        store.flush()
        let saved = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, BrowserSessionSnapshot(browser: browser))
        XCTAssertEqual(saved.tabs.count, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Session.json"])
    }

    func testDelayedSaveWritesWithoutFlushAndDeduplicatesUnchangedSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSessionStore(directory: directory, saveDelay: .milliseconds(10))
        let browser = BrowserModel()
        store.restore(in: browser)
        browser.addTab()
        store.requestSave(browser)
        let file = directory.appending(path: "Session.json")
        // Poll only the file so this verifies the automatic background path.
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, BrowserSessionSnapshot(browser: browser))
        let marker = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: file.path)
        store.requestSave(browser)
        try await Task.sleep(for: .milliseconds(50))
        store.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(try XCTUnwrap(attributes[.modificationDate] as? Date).timeIntervalSince1970,
                       marker.timeIntervalSince1970, accuracy: 0.001)
    }

    func testFocusChangeRejectsOldWindowRequestsAndDetachFlushes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSessionStore(directory: directory, saveDelay: .seconds(60))
        let first = BrowserModel()
        store.restore(in: first)
        first.addTab()
        store.requestSave(first)
        let second = BrowserModel()
        second.restoreSession(.init(tabs: [
            .init(url: URL(string: "https://example.com/second"), title: "Second")
        ], selectedIndex: 0))
        store.didFocus(second)
        first.addTab()
        store.requestSave(first)
        store.flush(first)
        let file = directory.appending(path: "Session.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        store.flush(second)
        let saved = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, BrowserSessionSnapshot(browser: second))
        // Popup focus does not revoke the last ordinary window's ownership.
        let popup = BrowserModel()
        popup.isExtensionWindow = true
        store.didFocus(popup)
        second.addTab()
        store.requestSave(second)
        store.flush()
        let afterPopup = try JSONDecoder().decode(BrowserSessionSnapshot.self, from: Data(contentsOf: file))
        XCTAssertEqual(afterPopup, BrowserSessionSnapshot(browser: second))
    }

    func testWriterRejectsAnOldOwnersAlreadyQueuedSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "Session.json")
        let queue = DispatchQueue(label: "BrowserSessionTests.writer")
        let writer = SessionWriter(file: file, queue: queue)
        let oldOwner = UUID()
        let newOwner = UUID()
        let snapshot = BrowserSessionSnapshot(tabs: [.init(url: nil, title: "")], selectedIndex: 0)
        queue.suspend()
        writer.setOwnership(oldOwner)
        writer.submit(snapshot, ownership: oldOwner)
        writer.setOwnership(newOwner)
        queue.resume()
        writer.flush(nil, ownership: newOwner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        writer.submit(snapshot, ownership: newOwner)
        writer.flush(nil, ownership: newOwner)
        XCTAssertEqual(try JSONDecoder().decode(BrowserSessionSnapshot.self, from: Data(contentsOf: file)), snapshot)
    }

    func testContinuousSnapshotChangesStillPersistBeforeUpdatesStop() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserSessionStore(directory: directory, saveDelay: .milliseconds(40))
        let browser = BrowserModel()
        store.restore(in: browser)
        let file = directory.appending(path: "Session.json")
        var persistedWhileChanging = false
        for index in 0..<15 {
            let snapshot = BrowserSessionSnapshot(tabs: [.init(url: URL(string: "https://example.com/"), title: "Update \(index)")], selectedIndex: 0)
            store.requestSave(snapshot, from: browser)
            try await Task.sleep(for: .milliseconds(10))
            if FileManager.default.fileExists(atPath: file.path) { persistedWhileChanging = true }
        }
        XCTAssertTrue(persistedWhileChanging, "Continuous title changes must not starve session persistence")
        store.flush()
    }

    func testBrowsingAndExtensionsUseTheSameIsolatedProfileInTests() throws {
        XCTAssertTrue(BrowserProfile.isTesting)
        XCTAssertFalse(BrowserProfile.websiteDataStore.isPersistent)
        let browsing = BrowserTab.makeConfiguration()
        let background = try XCTUnwrap(BrowserExtensions.shared.controller.configuration.webViewConfiguration)
        XCTAssertTrue(browsing.websiteDataStore === BrowserProfile.websiteDataStore)
        XCTAssertTrue(background.websiteDataStore === BrowserProfile.websiteDataStore)
        XCTAssertTrue(BrowserExtensions.shared.controller.configuration.defaultWebsiteDataStore === BrowserProfile.websiteDataStore)
    }
}
