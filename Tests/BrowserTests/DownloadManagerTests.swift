import WebKit
import XCTest
@testable import Browser

@MainActor
final class DownloadManagerTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testUniqueNamesNumberTakenFiles() {
        let directory = URL(filePath: "/Downloads")
        let taken: Set<String> = ["report.pdf", "report 2.pdf", "notes", ".env"]
        func name(_ filename: String) -> String {
            DownloadManager.uniqueURL(for: filename, in: directory) { taken.contains($0.lastPathComponent) }
                .lastPathComponent
        }

        XCTAssertEqual(name("report.pdf"), "report 3.pdf")
        XCTAssertEqual(name("notes"), "notes 2")
        XCTAssertEqual(name(".env"), ".env 2")
        XCTAssertEqual(name("photo.jpg"), "photo.jpg")
        XCTAssertEqual(name(""), "Download")
    }

    func testNamesCannotLeaveTheDownloadsFolder() {
        let directory = URL(filePath: "/Downloads")
        let url = DownloadManager.uniqueURL(for: "../../etc/passwd", in: directory) { _ in false }
        XCTAssertEqual(url.path, "/Downloads/passwd")
        XCTAssertEqual(DownloadManager.uniqueURL(for: "..", in: directory) { _ in false }.lastPathComponent,
                       "Download")
    }

    func testDownloadFailuresUseFriendlyDescriptions() {
        XCTAssertEqual(DownloadManager.failureDescription(for: URLError(.notConnectedToInternet)),
                       "No internet connection.")
        XCTAssertEqual(DownloadManager.failureDescription(for: URLError(.timedOut)),
                       "The download timed out.")
        XCTAssertEqual(DownloadManager.failureDescription(for: URLError(.serverCertificateUntrusted)),
                       "The secure connection failed.")
    }

    func testDownloadLinkSavesBesideExistingFile() async throws {
        let directory = try makeDirectory()
        try "old".write(to: directory.appending(path: "note.txt"), atomically: true, encoding: .utf8)
        let downloads = DownloadManager(directory: directory)
        let browser = BrowserModel(downloads: downloads)
        let tab = try XCTUnwrap(browser.activeTab)
        tab.restore()
        let webView = try XCTUnwrap(tab.webView)
        webView.loadHTMLString("<title>Files</title><a id=file download=note.txt href='data:text/plain,hello'>Get</a>",
                               baseURL: URL(string: "https://example.com")!)
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Files" }

        _ = try await webView.evaluateJavaScript("document.getElementById('file').click(); 0")

        try await waitUntil { downloads.items.first?.state == .finished }
        let item = try XCTUnwrap(downloads.items.first)
        XCTAssertEqual(item.name, "note 2.txt")
        XCTAssertEqual(item.progress, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(item.destinationURL), encoding: .utf8), "hello")
        XCTAssertEqual(try String(contentsOf: directory.appending(path: "note.txt"), encoding: .utf8), "old")
        XCTAssertFalse(downloads.isDownloading)
        XCTAssertFalse(item.hasActiveTransferResources)

        downloads.clearFinished()
        XCTAssertTrue(downloads.items.isEmpty)
    }
}


extension DownloadManagerTests {
    func testChosenReplacementKeepsOriginalUntilSuccessfulPublication() throws {
        let directory = try makeDirectory()
        let selected = directory.appending(path: "report.txt")
        try Data("original".utf8).write(to: selected)
        let destination = try DownloadDestination(selectedURL: selected)
        defer { destination.discardTransfer() }
        try Data("complete download".utf8).write(to: destination.transferURL)
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "original")
        try destination.publish()
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "complete download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.transferURL.path))
    }

    func testCancellingChosenReplacementNeverDeletesOriginal() throws {
        let directory = try makeDirectory()
        let selected = directory.appending(path: "report.txt")
        try Data("original".utf8).write(to: selected)
        let destination = try DownloadDestination(selectedURL: selected)
        try Data("partial".utf8).write(to: destination.transferURL)
        destination.discardTransfer()
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.transferURL.path))
    }

    func testNewChosenDestinationDoesNotOverwriteFileCreatedDuringTransfer() throws {
        let directory = try makeDirectory()
        let selected = directory.appending(path: "report.txt")
        let destination = try DownloadDestination(selectedURL: selected)
        defer { destination.discardTransfer() }
        try Data("download".utf8).write(to: destination.transferURL)
        try Data("another file".utf8).write(to: selected)
        XCTAssertThrowsError(try destination.publish())
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "another file")
        XCTAssertEqual(try String(contentsOf: destination.transferURL, encoding: .utf8), "download")
    }
}


private actor DownloadNameRecorder {
    private(set) var calls = 0
    func record() { calls += 1 }
}

extension DownloadManagerTests {
    private func startDownload(in browser: BrowserModel) async throws {
        browser.sitePermissions.setDecision(true, for: .downloads, on: "example.com")
        let tab = try XCTUnwrap(browser.activeTab)
        tab.restore()
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString("<title>Private source</title><a id=file download=original.txt href='data:text/plain,hello'>Get</a>",
                            baseURL: URL(string: "https://example.com")!)
        try await waitUntil { !tab.isLoading && tab.pageTitle == "Private source" }
        _ = try await view.evaluateJavaScript("document.getElementById('file').click(); 0")
        try await waitUntil { browser.downloads.items.first?.state == .finished }
    }

    func testPrivateDownloadNeverCallsIntelligenceEvenWhenNamingIsEnabled() async throws {
        let directory = try makeDirectory()
        let recorder = DownloadNameRecorder()
        let downloads = DownloadManager(directory: directory, shouldTidyDownloads: { true }, suggestName: { _, _, _ in
            await recorder.record()
            return "Changed Name"
        })
        let browser = BrowserModel.makePrivate(downloads: downloads)
        try await startDownload(in: browser)
        let calls = await recorder.calls
        XCTAssertEqual(calls, 0)
        let item = try XCTUnwrap(downloads.items.first)
        XCTAssertEqual(item.name, "original.txt")
        XCTAssertNil(item.originalName)
        XCTAssertFalse(item.isNaming)
    }

    func testNamingFailureKeepsOriginalWithoutShowingAnOperationalError() async throws {
        let directory = try makeDirectory()
        let downloads = DownloadManager(directory: directory, shouldTidyDownloads: { true },
                                        suggestName: { _, _, _ in
            throw IntelligenceError.message("Model refused the filename request")
        })
        let browser = BrowserModel(downloads: downloads)
        try await startDownload(in: browser)
        try await waitUntil { downloads.items.first?.isNaming == false }
        let item = try XCTUnwrap(downloads.items.first)
        XCTAssertEqual(item.name, "original.txt")
        XCTAssertNil(item.originalName)
        XCTAssertNil(item.failureDescription)
        XCTAssertFalse(item.hasActiveTransferResources)
    }

    func testChosenFilenameIsNotChangedByAutomaticNaming() async throws {
        let directory = try makeDirectory()
        let selected = directory.appending(path: "My Exact Name.txt")
        let recorder = DownloadNameRecorder()
        let downloads = DownloadManager(directory: directory, asksWhereToSave: { true },
                                        destinationChooser: { _, _ in selected },
                                        shouldTidyDownloads: { true }, suggestName: { _, _, _ in
            await recorder.record()
            return "Changed Name"
        })
        let browser = BrowserModel(downloads: downloads)
        try await startDownload(in: browser)
        let calls = await recorder.calls
        XCTAssertEqual(calls, 0)
        let item = try XCTUnwrap(downloads.items.first)
        XCTAssertEqual(item.name, "My Exact Name.txt")
        XCTAssertEqual(item.destinationURL, selected)
        XCTAssertNil(item.originalName)
        XCTAssertFalse(item.isNaming)
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "hello")
    }
}
