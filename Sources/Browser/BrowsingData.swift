import Foundation
import Observation
import WebKit

/// What Clear History and Website Data removes.
struct ClearDataOptions: OptionSet, Hashable {
    let rawValue: Int

    static let history = ClearDataOptions(rawValue: 1 << 0)
    /// Cookies, storage, databases, and service workers.
    static let siteData = ClearDataOptions(rawValue: 1 << 1)
    static let cache = ClearDataOptions(rawValue: 1 << 2)
    static let favicons = ClearDataOptions(rawValue: 1 << 3)

    static let all: ClearDataOptions = [.history, .siteData, .cache, .favicons]

    static let cacheTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
    ]

    /// The WebKit data types to remove, out of `allTypes`.
    @MainActor
    func websiteDataTypes(from allTypes: Set<String> = WKWebsiteDataStore.allWebsiteDataTypes()) -> Set<String> {
        var types = Set<String>()
        if contains(.siteData) { types.formUnion(allTypes.subtracting(Self.cacheTypes)) }
        if contains(.cache) { types.formUnion(allTypes.intersection(Self.cacheTypes)) }
        return types
    }
}

/// The history and website data normal windows keep, which Settings ▸ Privacy and History ▸ Clear History and
/// Website Data remove. Private windows keep theirs apart, and lose it when they close.
@MainActor
@Observable
final class BrowsingData {
    let history: HistoryStore
    let session: SessionStore
    @ObservationIgnored let dataStore: WKWebsiteDataStore
    /// Sites with cookies, storage, or cache, sorted by name. Empty until `loadSiteRecords()`.
    private(set) var siteRecords: [WKWebsiteDataRecord] = []
    private(set) var hasLoadedSiteRecords = false
    @ObservationIgnored private let websiteDataOperations: WebsiteDataOperations
    @ObservationIgnored private var hasRequestedSiteRecords = false
    @ObservationIgnored private var siteDataGeneration: UInt = 0
    @ObservationIgnored private var nextLoadSequence: UInt = 0
    @ObservationIgnored private var appliedLoadSequence: UInt = 0
    @ObservationIgnored private var pendingMutations = 0
    @ObservationIgnored private var mutationWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// WebKit operations are injected together so tests can control completion order without using live sites.
    struct WebsiteDataOperations {
        let loadRecords: @MainActor () async -> [WKWebsiteDataRecord]
        let removeRecords: @MainActor ([WKWebsiteDataRecord]) async -> Void
        let removeModifiedSince: @MainActor (Set<String>, Date) async -> Void

        @MainActor
        static func live(in dataStore: WKWebsiteDataStore) -> Self {
            Self(loadRecords: {
                await dataStore.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
            }, removeRecords: { records in
                await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
            }, removeModifiedSince: { types, start in
                await dataStore.removeData(ofTypes: types, modifiedSince: start)
            })
        }
    }

    init(history: HistoryStore, session: SessionStore, dataStore: WKWebsiteDataStore = BrowserProfile.websiteDataStore,
         websiteDataOperations: WebsiteDataOperations? = nil) {
        self.history = history
        self.session = session
        self.dataStore = dataStore
        self.websiteDataOperations = websiteDataOperations ?? .live(in: dataStore)
    }

    /// Removes what the options name from the time range. Clearing all history also forgets the closed windows
    /// that History ▸ Reopen All Windows from Last Session would open.
    func clear(_ options: ClearDataOptions, range: HistoryClearRange, now: Date = .now) async {
        await performMutation {
            let start = range.start(now: now)
            if options.contains(.history) {
                self.history.clear(range, now: now)
                if range == .all { self.session.forgetClosedWindows() }
            }
            let types = options.websiteDataTypes()
            if !types.isEmpty {
                await self.websiteDataOperations.removeModifiedSince(types, start)
            }
            if options.contains(.favicons) {
                await FaviconStore.clear(since: start)
            }
        }
    }

    func loadSiteRecords() async {
        guard !Task.isCancelled else { return }
        hasRequestedSiteRecords = true
        await waitForMutations()
        guard !Task.isCancelled else { return }
        nextLoadSequence &+= 1
        let sequence = nextLoadSequence
        let generation = siteDataGeneration
        let records = await websiteDataOperations.loadRecords()
        guard !Task.isCancelled, pendingMutations == 0, generation == siteDataGeneration,
              sequence > appliedLoadSequence else { return }
        siteRecords = records.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        appliedLoadSequence = sequence
        hasLoadedSiteRecords = true
    }

    func removeData(for records: [WKWebsiteDataRecord]) async {
        await performMutation { await self.websiteDataOperations.removeRecords(records) }
    }

    /// Once WebKit starts deleting, cancellation cannot undo it. Finish the accepted operation and its refresh
    /// even if the view that requested it disappears. Reads taken before or during the deletion cannot publish.
    private func performMutation(_ operation: @escaping @MainActor () async -> Void) async {
        guard !Task.isCancelled else { return }
        pendingMutations += 1
        siteDataGeneration &+= 1
        let mutation = Task { @MainActor in
            await operation()
            self.pendingMutations -= 1
            self.siteDataGeneration &+= 1
            guard self.pendingMutations == 0 else { return }
            let waiters = Array(self.mutationWaiters.values)
            self.mutationWaiters.removeAll()
            waiters.forEach { $0.resume() }
            if self.hasRequestedSiteRecords { await self.loadSiteRecords() }
        }
        await mutation.value
    }

    private func waitForMutations() async {
        while pendingMutations > 0 && !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard self.pendingMutations > 0, !Task.isCancelled else {
                        continuation.resume()
                        return
                    }
                    self.mutationWaiters[id] = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.mutationWaiters.removeValue(forKey: id)?.resume()
                }
            }
        }
    }

    /// What a site has stored, for the site data list.
    static func summary(of record: WKWebsiteDataRecord) -> String {
        let types = record.dataTypes
        var parts: [String] = []
        if types.contains(WKWebsiteDataTypeCookies) { parts.append("Cookies") }
        if !types.isDisjoint(with: [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
                                    WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeWebSQLDatabases,
                                    WKWebsiteDataTypeFileSystem]) {
            parts.append("Local storage")
        }
        if types.contains(WKWebsiteDataTypeServiceWorkerRegistrations) { parts.append("Service workers") }
        if !types.isDisjoint(with: ClearDataOptions.cacheTypes) { parts.append("Cache") }
        return parts.isEmpty ? "Other data" : parts.joined(separator: ", ")
    }
}
