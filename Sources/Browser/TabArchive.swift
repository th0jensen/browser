import Darwin
import Foundation
import Observation

/// Local Browser design. Arc's shipped names do not establish an idle duration.
struct ArchivedTab: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let tabID: UUID
    let spaceID: UUID
    let profileID: UUID
    let url: URL
    let title: String
    let archivedAt: Date
    let lastUsedAt: Date
    let interactionState: Data?
    let originalIndex: Int
}

struct TabArchiveSnapshot: Codable, Sendable {
    var version = 1
    var automaticEnabled = false
    var records: [ArchivedTab] = []
}

enum TabArchiveError: LocalizedError {
    case unavailable, busy, capacity, invalidOwner, stale
    var errorDescription: String? {
        switch self {
        case .unavailable: "The archive could not be saved. The live tab has not been removed."
        case .busy: "The archive is busy. Try again."
        case .capacity: "The archive is full. Restore some entries before archiving more tabs."
        case .invalidOwner: "The original Space or profile is not available. This page was not loaded."
        case .stale: "The tab changed. It has not been archived."
        }
    }
}

/// A separate serial writer: completion means the private temporary file and its directory were synced.
/// The previous valid snapshot is retained. Corrupt primary files can recover from that copy.
actor TabArchiveFile {
    let url: URL
    init(url: URL) { self.url = url }

    func write(_ data: Data) throws {
        guard data.count <= TabArchiveStore.maximumEncodedBytes else { throw TabArchiveError.capacity }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= TabArchiveStore.maximumEncodedBytes,
           let previous = try? Data(contentsOf: url), previous.count <= TabArchiveStore.maximumEncodedBytes,
           let snapshot = try? PropertyListDecoder().decode(TabArchiveSnapshot.self, from: previous),
           TabArchiveStore.valid(snapshot) {
            try Self.publish(previous, to: url.appendingPathExtension("recovery"))
        }
        try Self.publish(data, to: url)
    }

    private static func publish(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".archive-\(UUID()).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(.EIO) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(.EIO) }
        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw POSIXError(.EIO) }
    }
}

@MainActor @Observable
final class TabArchiveStore {
    static let shared = TabArchiveStore(url: BrowserProfile.directory.appending(path: "TabArchive.plist"))
    nonisolated static let maximumRecords = 500
    nonisolated static let maximumStateBytes = 2 * 1024 * 1024
    nonisolated static let maximumTotalStateBytes = 32 * 1024 * 1024
    nonisolated static let maximumEncodedBytes = 40 * 1024 * 1024
    private(set) var snapshot: TabArchiveSnapshot
    private(set) var isBusy = false
    private(set) var recovered = false
    private var writable = true
    @ObservationIgnored private let persist: @MainActor (Data) async throws -> Void
    @ObservationIgnored private var browsers: [WeakBrowser] = []
    private struct WeakBrowser { weak var value: BrowserModel? }
    @ObservationIgnored private var sessions: [WeakSession] = []
    private struct WeakSession { weak var value: SessionStore? }

    /// Tests inject the exact acknowledgement boundary, including delayed writes and failures.
    init(url: URL? = nil, persist: (@MainActor (Data) async throws -> Void)? = nil) {
        snapshot = TabArchiveSnapshot()
        if let url {
            var loaded: TabArchiveSnapshot?
            for candidate in [url, url.appendingPathExtension("recovery")] {
                guard let size = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= Self.maximumEncodedBytes,
                      let data = try? Data(contentsOf: candidate), data.count <= Self.maximumEncodedBytes,
                      let value = try? PropertyListDecoder().decode(TabArchiveSnapshot.self, from: data),
                      Self.valid(value) else { continue }
                loaded = value
                recovered = candidate != url
                break
            }
            if let loaded { snapshot = loaded }
            else if FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.appendingPathExtension("recovery").path) { writable = false }
        }
        if let persist { self.persist = persist }
        else if let url {
            let file = TabArchiveFile(url: url)
            self.persist = { data in try await file.write(data) }
        } else { self.persist = { _ in } }
    }

    nonisolated static func valid(_ snapshot: TabArchiveSnapshot) -> Bool {
        var ids = Set<UUID>(), tabs = Set<UUID>(), bytes = 0
        return snapshot.version == 1 && snapshot.records.count <= maximumRecords && snapshot.records.allSatisfy {
            bytes += $0.interactionState?.count ?? 0
            return ids.insert($0.id).inserted && tabs.insert($0.tabID).inserted
                && ["http", "https"].contains($0.url.scheme?.lowercased() ?? "")
                && $0.url.absoluteString.utf8.count <= 16_384 && $0.title.utf8.count <= 4096
                && $0.archivedAt.timeIntervalSince1970.isFinite && $0.lastUsedAt.timeIntervalSince1970.isFinite
                && ($0.interactionState?.count ?? 0) <= maximumStateBytes && bytes <= maximumTotalStateBytes
        }
    }

    func attach(_ browser: BrowserModel) {
        browsers.removeAll { $0.value == nil }
        browsers.append(WeakBrowser(value: browser))
    }

    func attach(_ session: SessionStore) {
        sessions.removeAll { $0.value == nil }
        if !sessions.contains(where: { $0.value === session }) { sessions.append(WeakSession(value: session)) }
    }

    func hasPendingSessionTab(_ record: ArchivedTab) -> Bool {
        sessions.contains { $0.value?.hasPendingArchiveTab(record) == true }
    }

    /// Live descriptors win after interruption between archive and session writes. Never show a second copy.
    func liveTab(_ id: UUID) -> BrowserTab? {
        browsers.compactMap(\.value).filter { !$0.isClosed }.compactMap { $0.tabAcrossSpaces(withID: id) }.first
    }

    func visibleRecords(spaceID: UUID, profileID: UUID, search: String = "") -> [ArchivedTab] {
        snapshot.records.filter {
            $0.spaceID == spaceID && $0.profileID == profileID && liveTab($0.tabID) == nil && !hasPendingSessionTab($0)
                && (search.isEmpty || $0.title.localizedStandardContains(search)
                    || $0.url.absoluteString.localizedStandardContains(search))
        }.sorted { $0.archivedAt > $1.archivedAt }
    }

    private func save(_ next: TabArchiveSnapshot) async throws {
        guard writable else { throw TabArchiveError.unavailable }
        guard !isBusy else { throw TabArchiveError.busy }
        guard Self.valid(next) else { throw TabArchiveError.capacity }
        isBusy = true
        defer { isBusy = false }
        let data = try await Task.detached(priority: .utility) {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(next)
            guard data.count <= Self.maximumEncodedBytes else { throw TabArchiveError.capacity }
            return data
        }.value
        try Task.checkCancellation()
        try await persist(data)
        snapshot = next
    }

    func insert(_ record: ArchivedTab) async throws {
        var next = snapshot
        if let index = next.records.firstIndex(where: { $0.tabID == record.tabID }) {
            let previous = next.records[index]
            guard previous.spaceID == record.spaceID, previous.profileID == record.profileID else {
                throw TabArchiveError.invalidOwner
            }
            // A fresh capture replaces a stale recovery copy only at the same acknowledged atomic boundary.
            // A failed replacement leaves the previous copy intact and does not consume another slot.
            next.records[index] = record
        } else { next.records.append(record) }
        try await save(next)
    }

    func remove(_ id: UUID) async throws {
        guard snapshot.records.contains(where: { $0.id == id }) else { return }
        var next = snapshot
        next.records.removeAll { $0.id == id }
        try await save(next)
    }

    func setAutomaticEnabled(_ enabled: Bool) async throws {
        var next = snapshot
        next.automaticEnabled = enabled
        try await save(next)
    }
}

/// One-day idle is an opt-in local policy, not a recovered Arc default. A launch/wake grace period and
/// bounded passes prevent a wall-clock jump or a restart from archiving every old descriptor at once.
struct TabArchiveIdlePolicy {
    static let idleSeconds: TimeInterval = 24 * 60 * 60
    static let grace: Duration = .seconds(30 * 60)
    private var graceStart: ContinuousClock.Instant = .now
    private var lastSample: (Date, ContinuousClock.Instant)?

    mutating func permitsPass(now: Date, instant: ContinuousClock.Instant) -> Bool {
        defer { lastSample = (now, instant) }
        guard let (wall, clock) = lastSample else {
            graceStart = instant
            return false
        }
        do {
            let elapsed = clock.duration(to: instant)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if seconds < 0 || seconds > 5 * 60 || abs(now.timeIntervalSince(wall) - seconds) > 60 {
                graceStart = instant
                return false
            }
        }
        return instant - graceStart >= Self.grace
    }

    static func isIdle(lastUsed: Date, lastActive: ContinuousClock.Instant,
                       now: Date, instant: ContinuousClock.Instant) -> Bool {
        let age = now.timeIntervalSince(lastUsed)
        return age.isFinite && age >= idleSeconds && instant - lastActive >= grace
    }
}
