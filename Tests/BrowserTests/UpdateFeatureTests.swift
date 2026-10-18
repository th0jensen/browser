import XCTest
@testable import Browser

final class UpdateFeatureTests: XCTestCase {
    /// 32 bytes shaped like an Ed25519 public key. Not a real key.
    private let wellFormedKey = Data(repeating: 7, count: 32).base64EncodedString()
    private let feed = "https://github.com/th0jensen/browser/releases/latest/download/appcast.xml"

    func testUpdatesNeedAnHTTPSFeedAndARealPublicKey() {
        XCTAssertTrue(UpdateFeature.isEnabled(info: ["SUFeedURL": feed, "SUPublicEDKey": wellFormedKey],
                                              isAppStoreBuild: false))

        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUFeedURL": feed,
                                                      "SUPublicEDKey": UpdateFeature.publicKeyPlaceholder],
                                               isAppStoreBuild: false))
        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUFeedURL": feed, "SUPublicEDKey": ""], isAppStoreBuild: false))
        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUFeedURL": feed, "SUPublicEDKey": "c2hvcnQ="],
                                               isAppStoreBuild: false))
        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUFeedURL": "http://example.com/appcast.xml",
                                                      "SUPublicEDKey": wellFormedKey], isAppStoreBuild: false))
        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUPublicEDKey": wellFormedKey], isAppStoreBuild: false))
        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUFeedURL": "", "SUPublicEDKey": wellFormedKey],
                                               isAppStoreBuild: false))
        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUFeedURL": "https:/appcast.xml", "SUPublicEDKey": wellFormedKey],
                                               isAppStoreBuild: false))
        XCTAssertFalse(UpdateFeature.isEnabled(info: nil, isAppStoreBuild: false))
    }

    func testTheAppStoreBuildNeverUpdatesItself() {
        XCTAssertFalse(UpdateFeature.isEnabled(info: ["SUFeedURL": feed, "SUPublicEDKey": wellFormedKey],
                                               isAppStoreBuild: true))
    }

    func testTheDirectBuildDeclaresSparklesFeedAndInstaller() throws {
        XCTAssertFalse(UpdateFeature.isAppStoreBuild)
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let feed = try XCTUnwrap(info["SUFeedURL"] as? String)
        if !feed.isEmpty {
            XCTAssertEqual(URL(string: feed)?.scheme, "https")
            XCTAssertNotNil(URL(string: feed)?.host)
        }
        XCTAssertEqual(info["SUEnableInstallerLauncherService"] as? Bool, true)
        XCTAssertNotNil(info["SUPublicEDKey"] as? String)
    }

    @MainActor
    func testUpdatesStayOffWhileTesting() {
        XCTAssertFalse(AppUpdater().isAvailable)
    }
}
