import Foundation
import WebKit

/// Both app variants use one sandbox identity; WebKit owns cookies, IndexedDB and credential storage.
@MainActor
enum BrowserProfile {
    static let bundleIdentifier = "dev.athas.browser"
    static let isTesting = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let directory = isTesting
        ? FileManager.default.temporaryDirectory.appending(path: "BrowserTests-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory)
    static let websiteDataStore: WKWebsiteDataStore = isTesting ? .nonPersistent() : .default()

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
