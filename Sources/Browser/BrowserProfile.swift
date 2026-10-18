import Foundation
import WebKit

/// Debug has its own sandbox and always uses disposable browsing data, including direct app launches.
@MainActor
enum BrowserProfile {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.athas.browser"
    static let isTesting = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let qaDirectory: URL? = {
        #if DEBUG
        guard !isTesting else { return nil }
        return debugDirectory(arguments: CommandLine.arguments, applicationSupport: .applicationSupportDirectory)
        #else
        return nil
        #endif
    }()

    #if DEBUG
    static func debugDirectory(arguments: [String], applicationSupport: URL) -> URL {
        if let index = arguments.firstIndex(of: "--qa-profile"), arguments.indices.contains(index + 1) {
            let requested = URL(fileURLWithPath: arguments[index + 1], isDirectory: true).resolvingSymlinksInPath()
            let root = applicationSupport.resolvingSymlinksInPath().path + "/"
            if requested.path.hasPrefix(root) { return requested }
        }
        return applicationSupport.appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "QA-\(UUID())", directoryHint: .isDirectory)
    }
    #endif
    static let directory = qaDirectory ?? (isTesting
        ? FileManager.default.temporaryDirectory.appending(path: "BrowserTests-\(ProcessInfo.processInfo.processIdentifier)")
        : URL.applicationSupportDirectory.appending(path: bundleIdentifier, directoryHint: .isDirectory))
    static let websiteDataStore: WKWebsiteDataStore = isTesting || qaDirectory != nil ? .nonPersistent() : .default()

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
