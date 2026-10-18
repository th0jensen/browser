import AppKit
import CoreServices
import Observation
import WebKit

@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State {
        case downloading
        case finished
        case failed
        case cancelled
    }

    let id = UUID()
    fileprivate(set) var name: String
    fileprivate(set) var state = State.downloading
    fileprivate(set) var progress = 0.0
    fileprivate(set) var completedBytes: Int64 = 0
    /// Negative while the server hasn't said how large the file is.
    fileprivate(set) var totalBytes: Int64 = -1
    fileprivate(set) var destinationURL: URL?
    fileprivate(set) var originalName: String?
    fileprivate(set) var namingError: String?
    fileprivate(set) var isNaming = false
    @ObservationIgnored fileprivate var sourceTitle = ""
    @ObservationIgnored fileprivate var sourceURL: URL?
    @ObservationIgnored fileprivate var namingTask: Task<Void, Never>?
    @ObservationIgnored fileprivate let download: WKDownload
    @ObservationIgnored fileprivate var progressObservation: NSKeyValueObservation?
    /// Asks whether a download the page started on its own may go ahead, or `nil` when the user started it.
    @ObservationIgnored fileprivate var confirmation: (@MainActor () async -> Bool)?

    fileprivate init(download: WKDownload) {
        self.download = download
        name = download.originalRequest?.url?.lastPathComponent ?? "Download"
    }
}

/// Downloads from every window, saved to the Downloads folder.
@MainActor
@Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let shouldTidyDownloads: @MainActor () -> Bool
    @ObservationIgnored private let suggestName: @Sendable (String, String, URL?) async throws -> String

    init(directory: URL = .downloadsDirectory,
         shouldTidyDownloads: @escaping @MainActor () -> Bool = {
             !BrowserProfile.isTesting && UserDefaults.standard.bool(forKey: BrowserIntelligence.downloadsKey)
                 && BrowserIntelligence.unavailableReason == nil
         },
         suggestName: @escaping @Sendable (String, String, URL?) async throws -> String = {
             try await LocalIntelligence.shared.downloadName(filename: $0, sourceTitle: $1, sourceURL: $2)
         }) {
        self.directory = directory
        self.shouldTidyDownloads = shouldTidyDownloads
        self.suggestName = suggestName
    }

    var isDownloading: Bool {
        items.contains { $0.state == .downloading }
    }

    /// Combined progress of the downloads still running.
    var progress: Double {
        let running = items.filter { $0.state == .downloading }
        guard !running.isEmpty else { return 0 }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    /// Pass a confirmation for a download the user didn't start. It's asked before anything is saved,
    /// and the download disappears if it's refused.
    func track(_ download: WKDownload, sourceTitle: String = "", sourceURL: URL? = nil, confirmation: (@MainActor () async -> Bool)? = nil) {
        let item = DownloadItem(download: download)
        if shouldTidyDownloads() { Task { await LocalIntelligence.shared.prepare(.download) } }
        item.sourceTitle = sourceTitle
        item.sourceURL = sourceURL
        item.confirmation = confirmation
        download.delegate = self
        item.progressObservation = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            let (fraction, completed, total) = (progress.fractionCompleted, progress.completedUnitCount,
                                                progress.totalUnitCount)
            Task { @MainActor [item] in
                item?.progress = fraction
                item?.completedBytes = completed
                item?.totalBytes = total
            }
        }
        items.insert(item, at: 0)
    }

    func cancel(_ item: DownloadItem) {
        guard item.state == .downloading else { return }
        item.state = .cancelled
        let partialFile = item.destinationURL
        item.download.cancel { _ in
            partialFile.map { try? FileManager.default.removeItem(at: $0) }
        }
    }

    func open(_ item: DownloadItem) {
        guard item.state == .finished, let url = item.destinationURL else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ item: DownloadItem) {
        guard let url = item.destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() {
        items.filter { $0.state != .downloading }.forEach { $0.namingTask?.cancel() }
        items.removeAll { $0.state != .downloading }
    }

    /// A file in `directory` named after `filename` that isn't taken yet, numbered like Finder does: "file 2.pdf".
    nonisolated static func uniqueURL(for filename: String, in directory: URL,
                                      isTaken: (URL) -> Bool) -> URL {
        // Keep only the last path component so a name can't point outside the folder.
        let name = (filename as NSString).lastPathComponent
        let safeName = name.isEmpty || name == "." || name == ".." ? "Download" : name
        let base = (safeName as NSString).deletingPathExtension
        let pathExtension = (safeName as NSString).pathExtension

        var candidate = directory.appending(path: safeName)
        var number = 2
        while isTaken(candidate) {
            let numbered = pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)"
            candidate = directory.appending(path: numbered)
            number += 1
        }
        return candidate
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        guard let item = item(for: download), item.state == .downloading else { return nil }
        if let confirmation = item.confirmation {
            item.confirmation = nil
            guard await confirmation() else {
                items.removeAll { $0 === item }
                return nil
            }
            // It might have been cancelled while the user was asked.
            guard item.state == .downloading else { return nil }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Downloads that are still running haven't necessarily created their files yet.
        let reserved = Set(items.filter { $0.state == .downloading }.compactMap(\.destinationURL))
        let url = Self.uniqueURL(for: suggestedFilename, in: directory) {
            reserved.contains($0) || FileManager.default.fileExists(atPath: $0.path)
        }
        item.name = url.lastPathComponent
        item.destinationURL = url
        return url
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        item.state = .finished
        item.progress = 1
        if let url = item.destinationURL {
            quarantine(url, from: download.originalRequest?.url)
            tidyDownload(item)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.state == .downloading else { return }
        item.state = .failed
        // Without resume support, a partial file is of no use.
        if let url = item.destinationURL { try? FileManager.default.removeItem(at: url) }
    }

    private func tidyDownload(_ item: DownloadItem) {
        guard shouldTidyDownloads(), let originalURL = item.destinationURL else { return }
        let originalName = item.name
        let suggest = suggestName
        item.isNaming = true
        item.namingTask = Task { [weak self, weak item] in
            defer { item?.namingTask = nil; item?.isNaming = false }
            do {
                let stem = try await suggest(originalName, item?.sourceTitle ?? "", item?.sourceURL)
                guard let self, let item, !Task.isCancelled, item.state == .finished,
                      item.destinationURL == originalURL, self.items.contains(where: { $0 === item }),
                      self.shouldTidyDownloads() else { return }
                let name = Self.tidyFilename(stem: stem, original: originalName)
                guard name.caseInsensitiveCompare(originalName) != .orderedSame else { return }
                try self.renameDownloadedFile(item, to: name)
                item.originalName = originalName
            } catch is CancellationError { }
            catch { item?.namingError = "Kept the original filename. " + error.localizedDescription }
        }
    }

    func undoTidyName(_ item: DownloadItem) {
        guard item.state == .finished, let original = item.originalName else { return }
        do {
            try renameDownloadedFile(item, to: original)
            item.originalName = nil
            item.namingError = nil
        } catch { item.namingError = error.localizedDescription }
    }

    private func renameDownloadedFile(_ item: DownloadItem, to name: String) throws {
        guard let source = item.destinationURL, source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        let destination = Self.uniqueURL(for: name, in: directory) { FileManager.default.fileExists(atPath: $0.path) }
        // moveItem refuses to overwrite an existing file, even if it appeared after
        // the name check. Moving within the directory preserves quarantine metadata.
        try FileManager.default.moveItem(at: source, to: destination)
        item.destinationURL = destination
        item.name = destination.lastPathComponent
    }

    nonisolated static func tidyFilename(stem: String, original: String) -> String {
        let compounds = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]
        let suffix = compounds.first { original.lowercased().hasSuffix("." + $0) }
            .map { String(original.suffix($0.count)) } ?? (original as NSString).pathExtension
        var clean = stem.components(separatedBy: CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\")))
            .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if !suffix.isEmpty, clean.lowercased().hasSuffix("." + suffix.lowercased()) { clean.removeLast(suffix.count + 1) }
        clean = String(clean.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !clean.isEmpty else { return original }
        return suffix.isEmpty ? clean : clean + "." + suffix
    }

    /// Marks the file as downloaded from the web, so Gatekeeper checks it before it's opened.
    private func quarantine(_ url: URL, from sourceURL: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") ?? "Browser",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let sourceURL { properties[kLSQuarantineDataURLKey as String] = sourceURL }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var url = url
        try? url.setResourceValues(values)
    }
}
