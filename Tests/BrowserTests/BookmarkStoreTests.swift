import XCTest
@testable import Browser

@MainActor
final class BookmarkStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "dev.athas.browser.tests.bookmarks"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testToggleAddsThenRemovesAPage() {
        let store = BookmarkStore(defaults: makeDefaults())
        let url = URL(string: "https://swift.org")!

        store.toggle(title: "Swift", url: url)
        XCTAssertTrue(store.isBookmarked(url))

        store.toggle(title: "Swift", url: url)
        XCTAssertFalse(store.isBookmarked(url))
    }

    func testBookmarksPersistAcrossStores() {
        let defaults = makeDefaults()
        let store = BookmarkStore(defaults: defaults)
        store.add(title: "Swift", url: URL(string: "https://swift.org")!)
        store.add(title: "", url: URL(string: "https://www.apple.com")!)
        store.rename(store.bookmarks[0].id, to: "  Swift.org  ")

        let reloaded = BookmarkStore(defaults: defaults)

        XCTAssertEqual(reloaded.bookmarks.map(\.displayTitle), ["Swift.org", "apple.com"])
    }

    func testMoveReordersBookmarks() {
        let store = BookmarkStore(defaults: makeDefaults())
        for site in ["a.com", "b.com", "c.com"] {
            store.add(title: site, url: URL(string: "https://\(site)")!)
        }

        store.move(store.bookmarks[0].id, to: 2)

        XCTAssertEqual(store.bookmarks.map(\.title), ["b.com", "c.com", "a.com"])
    }

    func testBookmarksBarVisibility() {
        XCTAssertTrue(BookmarksBarVisibility.always.isVisible(onNewTab: false))
        XCTAssertTrue(BookmarksBarVisibility.newTabOnly.isVisible(onNewTab: true))
        XCTAssertFalse(BookmarksBarVisibility.newTabOnly.isVisible(onNewTab: false))
        XCTAssertFalse(BookmarksBarVisibility.never.isVisible(onNewTab: true))
    }

    func testTabLayoutToggles() {
        XCTAssertEqual(TabLayout.horizontal.toggled, .vertical)
        XCTAssertEqual(TabLayout.vertical.toggled, .horizontal)
    }
}
