import Foundation
import Observation
import WebKit

/// A durable identity, not a visual Space. The default descriptor never names a new WebKit store.
struct BrowserProfileDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    let websiteDataStoreID: UUID?
}

@MainActor
final class IsolatedProfileResources {
    let websiteDataStore: WKWebsiteDataStore
    let history: HistoryStore
    let permissions: SitePermissions
    let zoom: ZoomStore
    let downloads = DownloadManager()
    let bookmarks: BookmarkStore

    init(descriptor: BrowserProfileDescriptor, directory: URL, durable: Bool, disposableWebsiteData: Bool) {
        precondition(descriptor.id != BrowserProfile.defaultID && descriptor.websiteDataStoreID != nil)
        websiteDataStore = BrowserProfile.makeWebsiteDataStore(identifier: descriptor.websiteDataStoreID!, disposable: disposableWebsiteData)
        func file(_ name: String) -> StoreFile? { durable ? StoreFile(url: directory.appending(path: name)) : nil }
        history = HistoryStore(file: file("History.plist"))
        permissions = SitePermissions(file: file("Permissions.json"))
        zoom = ZoomStore(defaults: nil, file: file("Zoom.json"))
        bookmarks = BookmarkStore(file: file("Bookmarks.json"))
    }
}

@MainActor @Observable
final class BrowserProfileStore {
    private(set) var profiles: [BrowserProfileDescriptor]
    private(set) var loadFailed = false
    let directory: URL
    private let enabled: Bool
    private let disposableWebsiteData: Bool
    @ObservationIgnored private var resourcesByID: [UUID: IsolatedProfileResources] = [:]

    enum Failure: LocalizedError {
        case unavailable, invalidName, unknownProfile
        var errorDescription: String? {
            switch self {
            case .unavailable: "The Profiles file could not be read. Keep it for recovery before creating a profile."
            case .invalidName: "Enter a profile name."
            case .unknownProfile: "This profile is not available. Its pages were not opened."
            }
        }
    }

    init(directory: URL, enabled: Bool = true, disposableWebsiteData: Bool = BrowserProfile.usesDisposableWebsiteData) {
        self.directory = directory
        self.enabled = enabled
        self.disposableWebsiteData = disposableWebsiteData
        let existing = BrowserProfileDescriptor(id: BrowserProfile.defaultID, title: BrowserProfile.displayName, websiteDataStoreID: nil)
        profiles = [existing]
        let file = directory.appending(path: "Profiles.json")
        guard enabled, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let saved = try JSONDecoder().decode([BrowserProfileDescriptor].self, from: Data(contentsOf: file))
            var ids = Set<UUID>(), stores = Set<UUID>()
            guard saved.filter({ $0.id == existing.id }) == [existing], saved.allSatisfy({ profile in
                guard ids.insert(profile.id).inserted, !profile.title.isEmpty else { return false }
                if profile.id == existing.id { return profile.websiteDataStoreID == nil }
                guard let store = profile.websiteDataStoreID, store != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else { return false }
                return stores.insert(store).inserted
            }) else { throw Failure.unavailable }
            profiles = saved
        } catch { loadFailed = true }
    }

    func profile(_ id: UUID) -> BrowserProfileDescriptor? { profiles.first { $0.id == id } }

    @discardableResult
    func create(title: String) throws -> BrowserProfileDescriptor {
        guard !loadFailed else { throw Failure.unavailable }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { throw Failure.invalidName }
        let descriptor = BrowserProfileDescriptor(id: UUID(), title: title, websiteDataStoreID: UUID())
        let next = profiles + [descriptor]
        if enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "Profiles.json")
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        profiles = next
        return descriptor
    }

    func profileDirectory(_ id: UUID) -> URL {
        id == BrowserProfile.defaultID ? directory : directory.appending(path: "Profiles/\(id.uuidString)", directoryHint: .isDirectory)
    }

    func resources(for id: UUID) -> IsolatedProfileResources? {
        guard id != BrowserProfile.defaultID, let descriptor = profile(id) else { return nil }
        if let existing = resourcesByID[id] { return existing }
        let resources = IsolatedProfileResources(descriptor: descriptor, directory: profileDirectory(id),
                                                  durable: enabled, disposableWebsiteData: disposableWebsiteData)
        resourcesByID[id] = resources
        return resources
    }
}
