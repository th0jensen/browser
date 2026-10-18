import Foundation
import WebKit

/// Both app variants use one sandbox identity; WebKit owns cookies, IndexedDB and credential storage.
@MainActor
enum BrowserProfile {
    static let bundleIdentifier = "dev.athas.browser"
    static let isTesting = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    // Debug QA may use a disposable session without touching the shared profile.
    static let qaDirectory: URL? = {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--qa-profile"),
           CommandLine.arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
        }
        #endif
        return nil
    }()
    static let directory = qaDirectory ?? (isTesting
        ? FileManager.default.temporaryDirectory.appending(path: "BrowserTests-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory))
    static let websiteDataStore: WKWebsiteDataStore = isTesting || qaDirectory != nil ? .nonPersistent() : .default()

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
