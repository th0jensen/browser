import Foundation
import Observation

struct PinnedPage: Codable, Equatable, Identifiable {
    let id: UUID
    let url: URL
    let title: String
}

/// Independent of window snapshots: a successful pin is durable before it appears in the UI.
@MainActor @Observable
final class PinnedPageStore {
    static let shared = PinnedPageStore(directory: BrowserProfile.directory, enabled: !BrowserProfile.isTesting)
    static let limit = 9
    private(set) var items: [PinnedPage] = []
    var errorMessage: String?
    private let file: URL
    private let enabled: Bool

    enum Failure: LocalizedError {
        case invalidURL, full
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Only HTTP and HTTPS webpages can be added to Essential Tabs."
            case .full: "Essential Tabs holds up to nine webpages. Remove an Essential Tab to make room."
            }
        }
    }

    init(directory: URL, enabled: Bool = true) {
        file = directory.appending(path: "PinnedPages.json")
        self.enabled = enabled
        if enabled, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([PinnedPage].self, from: data) {
            var ids = Set<UUID>(), urls = Set<URL>()
            items = Array(saved.filter {
                Self.valid($0.url) && ids.insert($0.id).inserted && urls.insert($0.url).inserted
            }.prefix(Self.limit))
        }
    }

    static func valid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }

    @discardableResult
    func pin(url: URL, title: String) throws -> PinnedPage {
        guard Self.valid(url) else { throw Failure.invalidURL }
        if let existing = items.first(where: { $0.url == url }) { return existing }
        guard items.count < Self.limit else { throw Failure.full }
        let page = PinnedPage(id: UUID(), url: url, title: title)
        try commit(items + [page])
        return page
    }

    func remove(_ id: UUID) throws { try commit(items.filter { $0.id != id }) }

    private func commit(_ next: [PinnedPage]) throws {
        if enabled {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic replacement uses the destination's permissions; also protect the initial file.
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        items = next
    }
}
