import Foundation
import Observation

/// A navigation context, not a separate login. This release uses one existing profile.
struct BrowserSpace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    let profileID: UUID
}

@MainActor @Observable
final class BrowserSpaceStore {
    static let defaultSpaceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let shared = BrowserSpaceStore(directory: BrowserProfile.directory, enabled: !BrowserProfile.isTesting)
    private(set) var spaces: [BrowserSpace]
    private let directory: URL
    private let enabled: Bool
    private var loadFailed = false
    @ObservationIgnored private var folderStores: [UUID: TabFolderStore] = [:]
    @ObservationIgnored private var pinnedStores: [UUID: PinnedPageStore] = [:]

    enum Failure: LocalizedError {
        case unavailable, invalidName, unsupportedProfile
        var errorDescription: String? {
            switch self {
            case .unavailable: "The Spaces file could not be read. Keep the file for recovery before creating a Space."
            case .invalidName: "Enter a Space name."
            case .unsupportedProfile: "This browser supports only the Existing Profile. Spaces share its login state."
            }
        }
    }

    init(directory: URL, enabled: Bool = true) {
        self.directory = directory
        self.enabled = enabled
        let initial = BrowserSpace(id: Self.defaultSpaceID, title: "Default", profileID: BrowserProfile.defaultID)
        spaces = [initial]
        let file = directory.appending(path: "Spaces.json")
        guard enabled, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let saved = try JSONDecoder().decode([BrowserSpace].self, from: Data(contentsOf: file))
            var ids = Set<UUID>()
            // Do not reinterpret a foreign profile as the existing profile.
            guard saved.allSatisfy({ $0.profileID == BrowserProfile.defaultID && ids.insert($0.id).inserted }),
                  saved.contains(where: { $0.id == Self.defaultSpaceID }) else { throw Failure.unsupportedProfile }
            spaces = saved
        } catch { loadFailed = true }
    }

    func space(_ id: UUID) -> BrowserSpace? { spaces.first { $0.id == id } }

    @discardableResult
    func createSpace(title: String) throws -> BrowserSpace {
        guard !loadFailed else { throw Failure.unavailable }
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { throw Failure.invalidName }
        let space = BrowserSpace(id: UUID(), title: title, profileID: BrowserProfile.defaultID)
        let next = spaces + [space]
        if enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "Spaces.json")
            try JSONEncoder().encode(next).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        spaces = next
        return space
    }

    /// Legacy descriptors stay in place. Their identifiers and order do not change.
    func savedPageDirectory(for id: UUID) -> URL {
        id == Self.defaultSpaceID ? directory : directory.appending(path: "Spaces/\(id.uuidString)", directoryHint: .isDirectory)
    }

    func folders(for id: UUID) -> TabFolderStore {
        if let store = folderStores[id] { return store }
        let store = TabFolderStore(directory: savedPageDirectory(for: id), enabled: enabled)
        folderStores[id] = store
        return store
    }

    func pinnedPages(for id: UUID) -> PinnedPageStore {
        if let store = pinnedStores[id] { return store }
        let store = PinnedPageStore(directory: savedPageDirectory(for: id), enabled: enabled)
        pinnedStores[id] = store
        return store
    }
}

/// Window-local live state. Keeping objects here preserves forms and split focus on a Space switch.
struct BrowserSpaceState {
    var tabs: [BrowserTab]
    var selectedTabID: UUID?
    var splits: [SplitTabGroup]
}
