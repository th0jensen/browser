import XCTest
@testable import Browser

@MainActor
final class ZoomStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "dev.athas.browser.tests.zoom"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testZoomStepsStopAtTheEnds() {
        XCTAssertEqual(ZoomStore.level(after: 1), 1.1)
        XCTAssertEqual(ZoomStore.level(before: 1), 0.9)
        XCTAssertEqual(ZoomStore.level(after: 1.2), 1.25)
        XCTAssertEqual(ZoomStore.level(after: 3), 3)
        XCTAssertEqual(ZoomStore.level(before: 0.5), 0.5)
    }

    func testLevelsAreRememberedPerSite() {
        let defaults = makeDefaults()
        let zoom = ZoomStore(defaults: defaults)
        zoom.setLevel(1.25, for: "swift.org")
        zoom.setLevel(0.8, for: "apple.com")
        zoom.setLevel(1, for: "apple.com")

        let reloaded = ZoomStore(defaults: defaults)

        XCTAssertEqual(reloaded.level(for: "swift.org"), 1.25)
        XCTAssertEqual(reloaded.level(for: "apple.com"), 1)
        XCTAssertEqual(reloaded.level(for: nil), 1)
        XCTAssertEqual(defaults.dictionary(forKey: "pageZoomLevels") as? [String: Double], ["swift.org": 1.25])
    }

    func testResettingAllLevels() {
        let defaults = makeDefaults()
        let zoom = ZoomStore(defaults: defaults)
        zoom.setLevel(1.25, for: "swift.org")

        zoom.removeAll()

        XCTAssertTrue(zoom.levelsByHost.isEmpty)
        XCTAssertTrue(ZoomStore(defaults: defaults).levelsByHost.isEmpty)
    }

    func testWindowsThatArentRememberedKeepLevelsInMemory() {
        let zoom = ZoomStore(defaults: nil)
        zoom.setLevel(1.5, for: "swift.org")

        XCTAssertEqual(zoom.level(for: "swift.org"), 1.5)
    }
}
