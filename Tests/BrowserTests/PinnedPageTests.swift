import AppKit
import XCTest
@testable import Browser

@MainActor
final class PinnedPageTests: XCTestCase {
    func testBentoRowsUseTheWholeWidthAndNeverExceedThreeByThree() {
        XCTAssertEqual(PinnedPagesGrid.rowCounts(for: 1), [1])
        XCTAssertEqual(PinnedPagesGrid.rowCounts(for: 2), [2])
        XCTAssertEqual(PinnedPagesGrid.rowCounts(for: 4), [2, 2])
        XCTAssertEqual(PinnedPagesGrid.rowCounts(for: 7), [3, 2, 2])
        for count in 0...9 {
            let rows = PinnedPagesGrid.rowCounts(for: count)
            XCTAssertEqual(rows.reduce(0, +), count)
            XCTAssertLessThanOrEqual(rows.count, 3)
            XCTAssertTrue(rows.allSatisfy { (1...3).contains($0) })
        }
    }
    func testPinsAreDurableWithoutSavingAWindowSession() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinnedPageStore(directory: directory)
        let page = try store.pin(url: XCTUnwrap(URL(string: "https://youtube.com/")), title: "YouTube")
        let reopened = PinnedPageStore(directory: directory)
        XCTAssertEqual(reopened.items, [page])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "PinnedPages.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "Session.json").path))
        try reopened.remove(page.id)
        XCTAssertTrue(PinnedPageStore(directory: directory).items.isEmpty)
    }

    func testNinePinLimitDeduplicatesAndRejectsNonWebURLs() throws {
        let store = PinnedPageStore(directory: .temporaryDirectory, enabled: false)
        for index in 0..<9 {
            try store.pin(url: XCTUnwrap(URL(string: "https://example.com/\(index)")), title: "Page \(index)")
        }
        let first = try XCTUnwrap(store.items.first)
        XCTAssertEqual(try store.pin(url: first.url, title: "Again"), first)
        XCTAssertThrowsError(try store.pin(url: XCTUnwrap(URL(string: "https://example.com/ten")), title: "Ten"))
        XCTAssertThrowsError(try store.pin(url: XCTUnwrap(URL(string: "file:///tmp/test")), title: "File"))
        XCTAssertEqual(store.items.count, 9)
    }

    func testPinRestoresLazilyAndClosingItsTabDoesNotUnpin() throws {
        let store = PinnedPageStore(directory: .temporaryDirectory, enabled: false)
        let page = try store.pin(url: XCTUnwrap(URL(string: "https://example.com/pinned")), title: "Pinned")
        let browser = BrowserModel(pinnedPages: store)
        XCTAssertEqual(browser.tabs.count, 1, "Restoring descriptors must not open their websites")
        browser.openPinned(page)
        let id = try XCTUnwrap(browser.activeTabID)
        XCTAssertEqual(browser.activeTab?.pinnedPageID, page.id)
        XCTAssertEqual(browser.activeTab?.url, page.url)
        XCTAssertEqual(browser.regularTabs.count, 1)
        browser.openPinned(page)
        XCTAssertEqual(browser.activeTabID, id)
        XCTAssertEqual(browser.tabs.count, 2)
        browser.closeTab(id)
        XCTAssertEqual(store.items, [page])
        browser.openPinned(page)
        XCTAssertNotEqual(browser.activeTabID, id)
        browser.unpin(page)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(browser.regularTabs.count, 2)
    }

    func testOldSessionAdoptsPinAfterCrashWithoutHidingDuplicateTabs() throws {
        let store = PinnedPageStore(directory: .temporaryDirectory, enabled: false)
        let page = try store.pin(url: XCTUnwrap(URL(string: "https://example.com/pinned")), title: "Pinned")
        let browser = BrowserModel(pinnedPages: store)
        browser.restoreSession(.init(tabs: [
            .init(url: page.url, title: page.title),
            .init(url: page.url, title: "Duplicate"),
            .init(url: nil, title: "")
        ], selectedIndex: 2))
        XCTAssertEqual(browser.tabs[0].pinnedPageID, page.id)
        XCTAssertTrue(browser.tabs[0].isSuspended)
        XCTAssertNil(browser.tabs[1].pinnedPageID)
        XCTAssertEqual(browser.regularTabs.count, 2)
        let snapshot = BrowserSessionSnapshot(browser: browser)
        XCTAssertEqual(try JSONDecoder().decode(BrowserSessionSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        let restored = BrowserModel(pinnedPages: store)
        restored.restoreSession(snapshot)
        XCTAssertEqual(restored.tabs[0].pinnedPageID, page.id)
    }

    func testFailedPinWriteDoesNotPublishAnUndurableItem() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)
        let store = PinnedPageStore(directory: file)
        XCTAssertThrowsError(try store.pin(url: XCTUnwrap(URL(string: "https://example.com")), title: "Example"))
        XCTAssertTrue(store.items.isEmpty)
    }

    func testWebsiteTintIgnoresWhiteBackground() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                             bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 4, y: 4, width: 8, height: 8))
        let color = NSColor(try XCTUnwrap(WebsiteTint.dominant(in: XCTUnwrap(context.makeImage())))).usingColorSpace(.deviceRGB)
        XCTAssertGreaterThan(try XCTUnwrap(color).redComponent, 0.9)
        XCTAssertLessThan(try XCTUnwrap(color).greenComponent, 0.1)
        XCTAssertNotNil(WebsiteTint.brand(for: try XCTUnwrap(URL(string: "https://www.youtube.com"))))
        XCTAssertNil(WebsiteTint.brand(for: try XCTUnwrap(URL(string: "https://youtube.com.evil.example"))))
    }
}
