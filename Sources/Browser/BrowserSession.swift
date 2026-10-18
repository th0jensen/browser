import Darwin
import Foundation

struct BrowserSessionSnapshot: Codable, Equatable, Sendable {
    struct Tab: Codable, Equatable, Sendable {
        let url: URL?
        let title: String
        var pinnedPageID: UUID? = nil
        var folderPageID: UUID? = nil
        var temporarySection: TemporaryTabSection? = nil
    }
    struct Split: Codable, Equatable, Sendable {
        var id: UUID
        var tabIndices: [Int]
        var anchorIndex: Int
        var focusedIndex: Int
        var orientation: SplitOrientation
        var weights: [Double]
    }
    let tabs: [Tab]
    let selectedIndex: Int
    var splits: [Split]? = nil

    @MainActor init(browser: BrowserModel) {
        tabs = browser.tabs.map { Tab(url: $0.isNewTab ? nil : $0.url, title: $0.pageTitle,
                                     pinnedPageID: $0.pinnedPageID, folderPageID: $0.folderPageID, temporarySection: $0.temporarySection) }
        selectedIndex = browser.tabs.firstIndex { $0.id == browser.activeTabID } ?? 0
        let indices = Dictionary(uniqueKeysWithValues: browser.tabs.enumerated().map { ($0.element.id, $0.offset) })
        let groups = browser.splits.compactMap { group -> Split? in
            guard let anchor = indices[group.anchorID], let focused = indices[group.focusedID] else { return nil }
            let members = group.tabIDs.compactMap { indices[$0] }
            guard members.count == group.tabIDs.count, members.count >= 2 else { return nil }
            return Split(id: group.id, tabIndices: members, anchorIndex: anchor, focusedIndex: focused,
                         orientation: group.orientation, weights: group.weights)
        }
        splits = groups.isEmpty ? nil : groups
    }

    init(tabs: [Tab], selectedIndex: Int) {
        self.tabs = tabs
        self.selectedIndex = selectedIndex
    }
}

/// Saves only the last focused ordinary window. WebKit owns all authentication data.
@MainActor
final class BrowserSessionStore {
    static let shared = BrowserSessionStore(directory: BrowserProfile.directory, enabled: !BrowserProfile.isTesting)
    private let file: URL
    private let enabled: Bool
    private let saveDelay: Duration
    private let writer: SessionWriter
    private var hasRestored = false
    private weak var owner: BrowserModel?
    private var ownership = UUID()
    private var pendingSnapshot: BrowserSessionSnapshot?
    private var saveTask: Task<Void, Never>?

    init(directory: URL, enabled: Bool = true, saveDelay: Duration = .milliseconds(150)) {
        file = directory.appending(path: "Session.json")
        self.enabled = enabled
        self.saveDelay = saveDelay
        writer = SessionWriter(file: file)
        writer.setOwnership(ownership)
    }

    func restore(in browser: BrowserModel) {
        guard enabled, !hasRestored, !browser.isExtensionWindow && !browser.isPrivate else { return }
        hasRestored = true
        if let data = try? Data(contentsOf: file), let session = try? JSONDecoder().decode(BrowserSessionSnapshot.self, from: data) {
            browser.restoreSession(session)
        }
        if browser.window == nil || browser.window?.isKeyWindow == true { didFocus(browser) }
        else if let owner { requestSave(owner) }
    }

    /// Focus changes invalidate even snapshots already waiting on the writer queue.
    func didFocus(_ browser: BrowserModel) {
        guard enabled, !browser.isExtensionWindow && !browser.isPrivate,
              browser.window == nil || browser.window?.isKeyWindow == true else { return }
        if owner !== browser {
            saveTask?.cancel()
            saveTask = nil
            pendingSnapshot = nil
            owner = browser
            ownership = UUID()
            writer.setOwnership(ownership)
        }
        requestSave(BrowserSessionSnapshot(browser: browser), from: browser)
    }

    func requestSave(_ snapshot: BrowserSessionSnapshot, from browser: BrowserModel) {
        guard canSave(browser), pendingSnapshot != snapshot else { return }
        pendingSnapshot = snapshot
        // Bound the interval: continuous title/URL changes must not postpone persistence indefinitely.
        guard saveTask == nil else { return }
        let expectedOwnership = ownership
        saveTask = Task { [weak self, weak browser, saveDelay] in
            do { try await Task.sleep(for: saveDelay) }
            catch { return }
            guard let self, let browser, self.canSave(browser), self.ownership == expectedOwnership,
                  let snapshot = self.pendingSnapshot else { return }
            self.pendingSnapshot = nil
            self.saveTask = nil
            self.writer.submit(snapshot, ownership: expectedOwnership)
        }
    }

    func requestSave(_ browser: BrowserModel) {
        requestSave(BrowserSessionSnapshot(browser: browser), from: browser)
    }

    /// Immediate compatibility API for callers that need a durable result before returning.
    func save(_ browser: BrowserModel) {
        if owner == nil { didFocus(browser) }
        flush(browser)
    }

    /// Closing a window captures its final state even if its key-window status has already changed.
    func flush(_ browser: BrowserModel) {
        guard canSave(browser) else { return }
        saveTask?.cancel()
        saveTask = nil
        pendingSnapshot = nil
        writer.flush(BrowserSessionSnapshot(browser: browser), ownership: ownership)
    }

    /// Termination must drain the serial writer before the process exits.
    func flush() {
        if let owner { flush(owner) }
        else {
            saveTask?.cancel()
            saveTask = nil
            writer.flush(pendingSnapshot, ownership: ownership)
            pendingSnapshot = nil
        }
    }

    private func canSave(_ browser: BrowserModel) -> Bool {
        enabled && hasRestored && !browser.isExtensionWindow && !browser.isPrivate && owner === browser
    }
}

/// Only immutable values cross to this queue. The lock protects the ownership token;
/// file operations and the persisted-snapshot cache are confined to the serial queue.
final class SessionWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var ownership = UUID()
    private let file: URL
    private var persistedSnapshot: BrowserSessionSnapshot?

    init(file: URL, queue: DispatchQueue = DispatchQueue(label: "dev.athas.browser.session", qos: .utility)) {
        self.file = file
        self.queue = queue
    }

    func setOwnership(_ value: UUID) {
        lock.withLock { ownership = value }
    }

    func submit(_ snapshot: BrowserSessionSnapshot, ownership: UUID) {
        queue.async { self.persist(snapshot, ownership: ownership) }
    }

    func flush(_ snapshot: BrowserSessionSnapshot?, ownership: UUID) {
        queue.sync {
            if let snapshot { persist(snapshot, ownership: ownership) }
        }
    }

    private func persist(_ snapshot: BrowserSessionSnapshot, ownership expectedOwnership: UUID) {
        guard lock.withLock({ ownership == expectedOwnership }), persistedSnapshot != snapshot else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if try replaceAtomically(with: data, ownership: expectedOwnership) {
                persistedSnapshot = snapshot
            }
        } catch { NSLog("Could not save Browser session: %@", error.localizedDescription) }
    }

    private func replaceAtomically(with data: Data, ownership expectedOwnership: UUID) throws -> Bool {
        let temporary = file.deletingLastPathComponent().appending(path: ".Session-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        // Hold the ownership lock only across the atomic rename, never across encoding
        // or disk synchronization. A focus change cannot publish an older window's file.
        let replaced = try lock.withLock {
            guard ownership == expectedOwnership else { return false }
            guard Darwin.rename(temporary.path, file.path) == 0 else { throw posixError() }
            return true
        }
        guard replaced else { return false }
        // Persist the rename as well as the file's contents.
        let directory = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY)
        guard directory >= 0 else { throw posixError() }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw posixError() }
        return true
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
