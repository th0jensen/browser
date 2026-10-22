import Darwin
import Foundation
import Observation

enum BrowserSpaceIcon: String, Codable, CaseIterable, Identifiable, Sendable {
    case circle, home, work, book, code, leaf, heart, lightbulb, travel, music
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .circle: "circle.grid.2x2.fill"
        case .home: "house.fill"
        case .work: "briefcase.fill"
        case .book: "book.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .leaf: "leaf.fill"
        case .heart: "heart.fill"
        case .lightbulb: "lightbulb.fill"
        case .travel: "airplane"
        case .music: "music.note"
        }
    }
    var title: String { rawValue.capitalized }
}

enum BrowserSpaceTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, blue, purple, pink, orange, green, gray
    var id: String { rawValue }
    var title: String { self == .system ? "System Accent" : rawValue.capitalized }
}

/// A visual navigation context. Spaces with the same profile share website data.
struct BrowserSpace: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    let profileID: UUID
    var icon: BrowserSpaceIcon = .circle
    var theme: BrowserSpaceTheme = .system
    var symbol: String?
    var emoji = ""
    var color = FolderColor.primary

    var displaySymbol: String { Self.cleanSymbol(symbol) ?? icon.symbol }

    static func cleanSymbol(_ symbol: String?) -> String? {
        guard let symbol, symbol.utf8.count <= 100,
              SavedItemIconSymbols.all.contains(symbol) || BrowserSpaceIcon.allCases.contains(where: { $0.symbol == symbol }) else { return nil }
        return symbol
    }

    static func cleanEmoji(_ emoji: String) -> String {
        guard emoji.utf8.count <= 64, !emoji.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return "" }
        return String(emoji.prefix(1))
    }
}

extension BrowserSpace {
    private enum CodingKeys: String, CodingKey { case id, title, profileID, icon, theme, symbol, emoji, color }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        // Appearance is optional metadata. Unknown future palette values must not hide saved tabs.
        icon = (try? values.decode(String.self, forKey: .icon)).flatMap(BrowserSpaceIcon.init(rawValue:)) ?? .circle
        theme = (try? values.decode(String.self, forKey: .theme)).flatMap(BrowserSpaceTheme.init(rawValue:)) ?? .system
        symbol = Self.cleanSymbol(try? values.decode(String.self, forKey: .symbol))
        emoji = Self.cleanEmoji((try? values.decode(String.self, forKey: .emoji)) ?? "")
        color = (try? values.decode(String.self, forKey: .color)).flatMap(FolderColor.init(rawValue:)) ?? .primary
    }
}

@MainActor @Observable
final class BrowserSpaceStore {
    static let defaultSpaceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let shared = BrowserSpaceStore(directory: BrowserProfile.directory, enabled: !BrowserProfile.isTesting)
    private(set) var spaces: [BrowserSpace]
    let profiles: BrowserProfileStore
    private let directory: URL
    private let enabled: Bool
    /// Descriptor clients must not treat the recovery Default value as loaded metadata.
    private(set) var loadFailed = false
    private var needsAppearanceBackup = false
    @ObservationIgnored private var folderStores: [UUID: TabFolderStore] = [:]
    @ObservationIgnored private var pinnedStores: [UUID: PinnedPageStore] = [:]
    /// Narrow synchronous fault seam for metadata staging tests. Ordinary writes use no hook.
    @ObservationIgnored private let writeCheckpoint: ((WriteCheckpoint, URL) throws -> Void)?
    enum WriteCheckpoint { case partialStagingWrite, beforePublication }

    enum Failure: LocalizedError {
        case unavailable, invalidName, unsupportedProfile
        var errorDescription: String? {
            switch self {
            case .unavailable: "The Spaces file could not be read. Keep the file for recovery before creating a Space."
            case .invalidName: "Enter a Space name."
            case .unsupportedProfile: "The profile for this Space is not available. Its pages were not opened."
            }
        }
    }

    init(directory: URL, enabled: Bool = true, profiles: BrowserProfileStore? = nil,
         writeCheckpoint: ((WriteCheckpoint, URL) throws -> Void)? = nil) {
        self.profiles = profiles ?? BrowserProfileStore(directory: directory, enabled: enabled)
        self.directory = directory
        self.enabled = enabled
        self.writeCheckpoint = writeCheckpoint
        let initial = BrowserSpace(id: Self.defaultSpaceID, title: "Default", profileID: BrowserProfile.defaultID)
        spaces = [initial]
        let file = directory.appending(path: "Spaces.json")
        guard enabled, FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let saved = try JSONDecoder().decode([BrowserSpace].self, from: data)
            if let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                needsAppearanceBackup = records.contains { $0["icon"] == nil || $0["theme"] == nil }
            }
            var ids = Set<UUID>()
            // Do not reinterpret a foreign profile as the existing profile.
            guard saved.allSatisfy({ ids.insert($0.id).inserted }),
                  saved.contains(where: { $0.id == Self.defaultSpaceID && $0.profileID == BrowserProfile.defaultID }) else { throw Failure.unsupportedProfile }
            spaces = saved
        } catch { loadFailed = true }
    }

    func space(_ id: UUID) -> BrowserSpace? { spaces.first { $0.id == id } }

    /// Shared by restore and recovery deletion. A record cannot prove its own ownership.
    func owns(_ session: SpaceSession) -> Bool {
        profiles.profile(session.profileID) != nil && space(session.spaceID)?.profileID == session.profileID
            && session.tabs.allSatisfy {
                ($0.profileID == nil || $0.profileID == session.profileID)
                    && ($0.spaceID == nil || $0.spaceID == session.spaceID)
            }
    }

    @discardableResult
    func createSpace(title: String, profileID: UUID = BrowserProfile.defaultID,
                     icon: BrowserSpaceIcon = .circle, theme: BrowserSpaceTheme = .system,
                     symbol: String? = nil, emoji: String = "", color: FolderColor = .primary) throws -> BrowserSpace {
        guard !loadFailed else { throw Failure.unavailable }
        guard profiles.profile(profileID) != nil else { throw Failure.unsupportedProfile }
        let space = BrowserSpace(id: UUID(), title: try cleanTitle(title), profileID: profileID, icon: icon, theme: theme,
                                 symbol: BrowserSpace.cleanSymbol(symbol), emoji: BrowserSpace.cleanEmoji(emoji), color: color)
        try commit(spaces + [space])
        return space
    }

    func updateSpace(_ id: UUID, title: String, icon: BrowserSpaceIcon, theme: BrowserSpaceTheme,
                     symbol: String? = nil, emoji: String? = nil, color: FolderColor? = nil) throws {
        guard let index = spaces.firstIndex(where: { $0.id == id }) else { throw Failure.unavailable }
        var next = spaces
        next[index].title = try cleanTitle(title)
        next[index].icon = icon
        next[index].theme = theme
        if let symbol { next[index].symbol = BrowserSpace.cleanSymbol(symbol) }
        if let emoji { next[index].emoji = BrowserSpace.cleanEmoji(emoji) }
        if let color { next[index].color = color }
        try commit(next)
    }

    private func cleanTitle(_ title: String) throws -> String {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty else { throw Failure.invalidName }
        return title
    }

    private func commit(_ next: [BrowserSpace]) throws {
        guard !loadFailed else { throw Failure.unavailable }
        if enabled {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "Spaces.json")
            if needsAppearanceBackup {
                let backup = directory.appending(path: "Spaces.before-appearance.json")
                if FileManager.default.fileExists(atPath: backup.path) {
                    _ = try JSONDecoder().decode([BrowserSpace].self, from: Data(contentsOf: backup))
                } else {
                    // An atomic hard link retains the original bytes before replacing the live file.
                    try FileManager.default.linkItem(at: file, to: backup)
                }
            }
            try writeMetadata(JSONEncoder().encode(next), to: file)
            needsAppearanceBackup = false
        }
        spaces = next
    }

    /// Never create an empty canonical file. Until rename succeeds, only this private staging file changes.
    private func writeMetadata(_ data: Data, to file: URL) throws {
        let temporary = directory.appending(path: ".Spaces-\(UUID()).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if let writeCheckpoint {
            let midpoint = data.count / 2
            try handle.write(contentsOf: data.prefix(midpoint))
            try writeCheckpoint(.partialStagingWrite, temporary)
            try handle.write(contentsOf: data.dropFirst(midpoint))
        } else {
            try handle.write(contentsOf: data)
        }
        try handle.synchronize()
        try handle.close()
        try writeCheckpoint?(.beforePublication, temporary)
        // Same-directory rename publishes all bytes and mode together, for initial creation and replacement.
        guard Darwin.rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
