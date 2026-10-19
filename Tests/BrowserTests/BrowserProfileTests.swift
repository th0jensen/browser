import XCTest
@testable import Browser

#if DEBUG
@MainActor
final class BrowserProfileTests: XCTestCase {
    func testDebugUsesItsOwnApplicationIdentityAndNonpersistentWebsiteData() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.athas.browser.debug")
        XCTAssertEqual(BrowserProfile.bundleIdentifier, "dev.athas.browser.debug")
        XCTAssertFalse(BrowserProfile.websiteDataStore.isPersistent)
    }

    func testDirectDebugLaunchCreatesANewProfileInsteadOfRestoringAnExistingOne() {
        let support = URL(filePath: "/tmp/debug-container/Application Support", directoryHint: .isDirectory)
        let first = BrowserProfile.debugDirectory(arguments: ["Browser-Debug"], applicationSupport: support)
        let second = BrowserProfile.debugDirectory(arguments: ["Browser-Debug"], applicationSupport: support)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "dev.athas.browser.debug")
        XCTAssertTrue(first.lastPathComponent.hasPrefix("QA-"))
    }

    func testExplicitQAProfileMustBeInsideTheDebugSandbox() {
        let support = URL(filePath: "/tmp/debug-container/Application Support", directoryHint: .isDirectory)
        let requested = support.appending(path: "QA-explicit", directoryHint: .isDirectory)
        XCTAssertEqual(BrowserProfile.debugDirectory(arguments: ["Browser-Debug", "--qa-profile", requested.path],
                                                     applicationSupport: support), requested.resolvingSymlinksInPath())
        let rejected = BrowserProfile.debugDirectory(arguments: ["Browser-Debug", "--qa-profile", "/tmp/release-container/profile"],
                                                      applicationSupport: support)
        XCTAssertTrue(rejected.path.hasPrefix(support.path + "/"))
        XCTAssertNotEqual(rejected.path, "/tmp/release-container/profile")
    }
}
#endif
