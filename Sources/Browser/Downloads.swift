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
    fileprivate(set) var hasRecoverableFile = false
    @ObservationIgnored fileprivate var allowsIntelligence = true
    @ObservationIgnored fileprivate var sourceTitle = ""
    @ObservationIgnored fileprivate var sourceURL: URL?
    @ObservationIgnored fileprivate var namingTask: Task<Void, Never>?
    /// A chosen destination is published only after the complete file is available.
    @ObservationIgnored fileprivate var chosenDestination: DownloadDestination?
    @ObservationIgnored fileprivate let download: WKDownload
    @ObservationIgnored fileprivate var progressObservation: NSKeyValueObservation?
    /// Asks whether a download the page started on its own may go ahead, or `nil` when the user started it.
    @ObservationIgnored fileprivate var confirmation: (@MainActor () async -> Bool)?
    /// The window the save panel opens on, when Settings ▸ Downloads asks where to save each file.
    @ObservationIgnored fileprivate weak var window: NSWindow?

    fileprivate init(download: WKDownload) {
        self.download = download
        name = download.originalRequest?.url?.lastPathComponent ?? "Download"
    }
}

/// Downloads from every window, saved to the Downloads folder or where the user chooses.
@MainActor
@Observable
final class DownloadManager: NSObject, WKDownloadDelegate {
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored let directory: URL
    @ObservationIgnored private let asksWhereToSave: @MainActor () -> Bool
    @ObservationIgnored private let destinationChooser: (@MainActor (String, NSWindow?) async -> URL?)?
    @ObservationIgnored private let shouldTidyDownloads: @MainActor () -> Bool
    @ObservationIgnored private let suggestName: @Sendable (String, String, URL?) async throws -> String

    init(directory: URL = .downloadsDirectory,
         asksWhereToSave: @escaping @MainActor () -> Bool = {
             !BrowserProfile.isTesting && DownloadPreferences.asksWhereToSave
         },
         destinationChooser: (@MainActor (String, NSWindow?) async -> URL?)? = nil,
         shouldTidyDownloads: @escaping @MainActor () -> Bool = {
             !BrowserProfile.isTesting && UserDefaults.standard.bool(forKey: BrowserIntelligence.tidyDownloadsKey)
                 && BrowserIntelligence.unavailableReason == nil
         },
         suggestName: @escaping @Sendable (String, String, URL?) async throws -> String = {
             try await LocalIntelligence.shared.downloadName(filename: $0, sourceTitle: $1, sourceURL: $2)
         }) {
        self.directory = directory
        self.asksWhereToSave = asksWhereToSave
        self.destinationChooser = destinationChooser
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
    func track(_ download: WKDownload, in window: NSWindow? = nil,
               sourceTitle: String = "", sourceURL: URL? = nil, allowsIntelligence: Bool = true,
               confirmation: (@MainActor () async -> Bool)? = nil) {
        let item = DownloadItem(download: download)
        item.allowsIntelligence = allowsIntelligence
        if allowsIntelligence, shouldTidyDownloads() { Task { await LocalIntelligence.shared.prepare(.download) } }
        item.sourceTitle = allowsIntelligence ? sourceTitle : ""
        item.sourceURL = allowsIntelligence ? sourceURL : nil
        item.confirmation = confirmation
        item.window = window
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
        let chosenDestination = item.chosenDestination
        item.download.cancel { _ in
            if let chosenDestination { chosenDestination.discardTransfer() }
            else { partialFile.map { try? FileManager.default.removeItem(at: $0) } }
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
        items.filter { $0.state != .downloading }.forEach {
            $0.namingTask?.cancel()
            $0.chosenDestination?.discardTransfer()
        }
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
        if asksWhereToSave() {
            return await chooseDestination(for: item, suggestedFilename: suggestedFilename)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Downloads that are still running haven't necessarily created their files yet.
        let reserved = Set(items.filter { $0.state == .downloading }.flatMap { item in
            [item.destinationURL, item.chosenDestination?.selectedURL].compactMap { $0?.standardizedFileURL }
        })
        let url = Self.uniqueURL(for: suggestedFilename, in: directory) {
            reserved.contains($0) || FileManager.default.fileExists(atPath: $0.path)
        }
        item.name = url.lastPathComponent
        item.destinationURL = url
        return url
    }

    /// Asks where to save the file. Cancelling the panel cancels the download.
    private func chooseDestination(for item: DownloadItem, suggestedFilename: String) async -> URL? {
        let chosenURL: URL?
        if let destinationChooser {
            chosenURL = await destinationChooser(suggestedFilename, item.window)
        } else {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (suggestedFilename as NSString).lastPathComponent
            panel.directoryURL = directory
            panel.canCreateDirectories = true
            let response = if let window = item.window {
                await panel.beginSheetModal(for: window)
            } else {
                await panel.begin()
            }
            chosenURL = response == .OK ? panel.url : nil
        }
        guard let url = chosenURL, item.state == .downloading else {
            items.removeAll { $0 === item }
            return nil
        }
        // Another running transfer must retain its destination even before it creates a file.
        guard !items.contains(where: { other in
            other !== item && other.state == .downloading
                && (other.chosenDestination?.selectedURL ?? other.destinationURL)?.standardizedFileURL == url.standardizedFileURL
        }) else {
            item.state = .failed
            item.namingError = "Another download is saving to this file."
            return nil
        }
        do {
            let destination = try DownloadDestination(selectedURL: url)
            item.chosenDestination = destination
            item.name = url.lastPathComponent
            item.destinationURL = destination.transferURL
            return destination.transferURL
        } catch {
            item.state = .failed
            item.namingError = "Could not prepare the chosen destination. " + error.localizedDescription
            return nil
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download) else { return }
        if let destination = item.chosenDestination {
            do {
                // Quarantine the staged file before publishing it at the chosen address.
                quarantine(destination.transferURL, from: download.originalRequest?.url)
                try destination.publish()
                item.destinationURL = destination.selectedURL
            } catch {
                item.state = .failed
                item.hasRecoverableFile = true
                item.namingError = "Could not save the file. The complete download is available using Show in Finder. "
                    + error.localizedDescription
                return
            }
        }
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
        if let destination = item.chosenDestination { destination.discardTransfer() }
        else if let url = item.destinationURL { try? FileManager.default.removeItem(at: url) }
    }

    private func tidyDownload(_ item: DownloadItem) {
        guard item.allowsIntelligence, item.chosenDestination == nil, shouldTidyDownloads(), let originalURL = item.destinationURL else { return }
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


/// Keeps a replacement separate from the existing file until WebKit finishes. The
/// replacement directory is on the destination's volume so final publication is atomic.
struct DownloadDestination: Sendable {
    let selectedURL: URL
    let transferURL: URL
    private let replacementDirectory: URL
    private let replacesExistingFile: Bool

    init(selectedURL: URL) throws {
        self.selectedURL = selectedURL
        replacesExistingFile = FileManager.default.fileExists(atPath: selectedURL.path)
        replacementDirectory = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                            appropriateFor: selectedURL, create: true)
        transferURL = replacementDirectory.appending(path: selectedURL.lastPathComponent)
    }

    func publish() throws {
        if replacesExistingFile {
            _ = try FileManager.default.replaceItemAt(selectedURL, withItemAt: transferURL, options: .usingNewMetadataOnly)
        } else {
            // A file that appeared after the panel was accepted must not be overwritten.
            try FileManager.default.moveItem(at: transferURL, to: selectedURL)
        }
        try? FileManager.default.removeItem(at: replacementDirectory)
    }

    func discardTransfer() {
        try? FileManager.default.removeItem(at: replacementDirectory)
    }
}
