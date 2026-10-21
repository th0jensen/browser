import XCTest
@testable import Browser

@MainActor
final class TabArchiveProfilePolicyTests: XCTestCase {
    private let existing = BrowserProfile.defaultID
    private let named = UUID()
    private let enabled = TabArchiveProfilePolicy(automaticEnabled: true)

    private struct LegacySnapshot: Encodable {
        var version = 1
        var automaticEnabled: Bool?
        var records: [ArchivedTab]
    }

    @MainActor private final class WriteGate {
        var calls = 0
        var heldCall: Int?
        var failCalls: Set<Int> = []
        var continuation: CheckedContinuation<Void, Never>?
        var writer: ((Data) async throws -> Void)?

        func write(_ data: Data) async throws {
            calls += 1
            let call = calls
            if call == heldCall { await withCheckedContinuation { continuation = $0 } }
            if failCalls.contains(call) { throw CocoaError(.fileWriteNoPermission) }
            try await writer?(data)
        }
        func holdNext() { heldCall = calls + 1 }
        func wait() async {
            for _ in 0..<2000 {
                if continuation != nil { return }
                try? await Task.sleep(for: .milliseconds(1))
            }
            XCTFail("The policy write did not reach the acknowledgement boundary")
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ArchiveProfilePolicy-\(UUID())")
    }

    private func record(profileID: UUID) -> ArchivedTab {
        ArchivedTab(id: UUID(), tabID: UUID(), spaceID: BrowserSpaceStore.defaultSpaceID,
                    profileID: profileID, url: URL(string: "https://archive.invalid/policy")!, title: "Keep owner",
                    archivedAt: Date(), lastUsedAt: Date(), interactionState: Data([1, 2]), originalIndex: 0)
    }

    private func browser(store: TabArchiveStore) -> BrowserModel {
        let model = BrowserModel(tabArchive: store)
        model.restoreSession(WindowSession(tabs: [
            TabSession(url: URL(string: "https://archive.invalid/idle"), title: "Idle", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil)
        ], selectedIndex: 1))
        return model
    }

    func testTwoPoliciesStayIndependentAndNewUnknownAndDefaultProfilesStartOff() async throws {
        let store = TabArchiveStore()
        let newProfile = UUID()
        for id in [existing, named, newProfile] {
            XCTAssertFalse(store.policy(forProfileID: id).automaticEnabled)
            XCTAssertEqual(store.policy(forProfileID: id).idleInterval, .oneDay)
        }
        let owned = record(profileID: named)
        try await store.insert(owned)
        try await store.setPolicy(enabled, forProfileID: existing)
        XCTAssertTrue(store.policy(forProfileID: existing).automaticEnabled)
        XCTAssertFalse(store.policy(forProfileID: named).automaticEnabled)
        try await store.setPolicy(enabled, forProfileID: named)
        try await store.setPolicy(.init(), forProfileID: existing)
        XCTAssertFalse(store.policy(forProfileID: existing).automaticEnabled)
        XCTAssertTrue(store.policy(forProfileID: named).automaticEnabled)
        XCTAssertFalse(store.policy(forProfileID: newProfile).automaticEnabled)
        XCTAssertEqual(store.snapshot.profilePolicies.count, 2)
        XCTAssertEqual(store.snapshot.records, [owned])
        let roundTrip = try PropertyListDecoder().decode(TabArchiveSnapshot.self, from: PropertyListEncoder().encode(store.snapshot))
        XCTAssertEqual(roundTrip.profilePolicies, store.snapshot.profilePolicies)
        XCTAssertEqual(roundTrip.records, [owned])
    }

    func testLegacyGlobalConsentMigratesOnlyToExistingProfileAndPreservesRecoveryBytes() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owned = [record(profileID: existing), record(profileID: named)]
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        for choice: Bool? in [true, false, nil] {
            let file = root.appending(path: "Archive-\(String(describing: choice)).plist")
            let legacy = try encoder.encode(LegacySnapshot(automaticEnabled: choice, records: owned))
            try legacy.write(to: file)
            let store = TabArchiveStore(url: file)
            XCTAssertEqual(store.snapshot.version, 2)
            XCTAssertEqual(store.snapshot.records, owned)
            XCTAssertEqual(store.snapshot.profilePolicies.count, 1)
            XCTAssertEqual(store.policy(forProfileID: existing).automaticEnabled, choice ?? false)
            XCTAssertFalse(store.policy(forProfileID: named).automaticEnabled)
            XCTAssertFalse(store.policy(forProfileID: UUID()).automaticEnabled)
            XCTAssertEqual(try Data(contentsOf: file), legacy, "Loading must not silently replace the old file")
            try await store.setPolicy(.init(), forProfileID: named)
            let current = try Data(contentsOf: file)
            let keys = try XCTUnwrap(PropertyListSerialization.propertyList(from: current, format: nil) as? [String: Any])
            XCTAssertEqual(keys["version"] as? Int, 2)
            XCTAssertNil(keys["automaticEnabled"])
            XCTAssertNotNil(keys["profilePolicies"])
            XCTAssertEqual(try Data(contentsOf: file.appendingPathExtension("recovery")), legacy)
            let reloaded = TabArchiveStore(url: file)
            XCTAssertEqual(reloaded.snapshot.records, owned)
            XCTAssertEqual(reloaded.policy(forProfileID: existing).automaticEnabled, choice ?? false)
            XCTAssertFalse(reloaded.policy(forProfileID: named).automaticEnabled)
            try Data("corrupt".utf8).write(to: file)
            let recovered = TabArchiveStore(url: file)
            XCTAssertTrue(recovered.recovered)
            XCTAssertEqual(recovered.snapshot.records, owned)
            XCTAssertEqual(recovered.policy(forProfileID: existing).automaticEnabled, choice ?? false)
            XCTAssertFalse(recovered.policy(forProfileID: named).automaticEnabled)
        }
    }

    func testVersionTwoNeverInheritsAnObsoleteGlobalToggleOrConsentFromRecords() throws {
        let bytes = try PropertyListEncoder().encode(LegacySnapshot(version: 2, automaticEnabled: true,
                                                                   records: [record(profileID: existing), record(profileID: named)]))
        let snapshot = try PropertyListDecoder().decode(TabArchiveSnapshot.self, from: bytes)
        XCTAssertTrue(snapshot.profilePolicies.isEmpty)
        XCTAssertFalse(snapshot.policy(forProfileID: existing).automaticEnabled)
        XCTAssertFalse(snapshot.policy(forProfileID: named).automaticEnabled)
        XCTAssertEqual(snapshot.records.count, 2)
    }

    func testPolicyAcknowledgementAndFailureKeepOtherPoliciesAndArchiveRecordsDurable() async throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "Archive.plist")
        let file = TabArchiveFile(url: url)
        let gate = WriteGate()
        gate.writer = { try await file.write($0) }
        let store = TabArchiveStore(url: url, persist: gate.write)
        let owned = [record(profileID: existing), record(profileID: named)]
        for record in owned { try await store.insert(record) }
        try await store.setPolicy(enabled, forProfileID: existing)
        gate.holdNext()
        gate.failCalls = [gate.calls + 1]
        let operation = Task { try await store.setPolicy(enabled, forProfileID: named) }
        await gate.wait()
        defer { gate.release() }
        XCTAssertFalse(store.policy(forProfileID: named).automaticEnabled)
        XCTAssertFalse(TabArchiveStore(url: url).policy(forProfileID: named).automaticEnabled)
        gate.release()
        do { try await operation.value; XCTFail("A failed snapshot cannot acknowledge the new policy") }
        catch { }
        XCTAssertEqual(store.snapshot.records, owned)
        XCTAssertTrue(store.policy(forProfileID: existing).automaticEnabled)
        XCTAssertFalse(store.policy(forProfileID: named).automaticEnabled)
        XCTAssertEqual(TabArchiveStore(url: url).snapshot.records, owned)
        try await store.setPolicy(enabled, forProfileID: named)
        let reloaded = TabArchiveStore(url: url)
        XCTAssertEqual(reloaded.snapshot.records, owned)
        XCTAssertTrue(reloaded.policy(forProfileID: existing).automaticEnabled)
        XCTAssertTrue(reloaded.policy(forProfileID: named).automaticEnabled)
        XCTAssertFalse(TabArchiveStore(url: url.appendingPathExtension("recovery")).policy(forProfileID: named).automaticEnabled)
    }

    func testPolicyTableRemainsBoundedWithoutDroppingRecords() {
        var snapshot = TabArchiveSnapshot()
        snapshot.records = [record(profileID: named)]
        for _ in 0..<TabArchiveStore.maximumProfilePolicies { snapshot.profilePolicies[UUID()] = enabled }
        XCTAssertTrue(TabArchiveStore.valid(snapshot))
        snapshot.profilePolicies[UUID()] = enabled
        XCTAssertFalse(TabArchiveStore.valid(snapshot))
        XCTAssertEqual(snapshot.records.count, 1)
    }

    func testCapturedSheetScopeRejectsChangedSpaceUnknownOwnerPrivateAndExtensionEdits() async throws {
        let gate = WriteGate()
        let store = TabArchiveStore(persist: gate.write)
        let browser = browser(store: store)
        let original = try XCTUnwrap(browser.archivePolicyScope())
        XCTAssertEqual(original.profileID, existing)
        XCTAssertEqual(original.profileLabel, "Existing Profile")
        _ = try browser.createSpace(title: "Another Space")
        XCTAssertFalse(original.isCurrent(in: browser))
        do { _ = try await browser.setArchivePolicy(enabled, for: original); XCTFail("Do not retarget an old sheet") }
        catch { }
        let foreign = TabArchivePolicyScope(spaceID: browser.activeSpaceID, profileID: named, spaceTitle: "Unknown owner")
        XCTAssertFalse(foreign.isCurrent(in: browser))
        do { _ = try await browser.setArchivePolicy(enabled, for: foreign); XCTFail("Unknown profiles cannot opt in") }
        catch { }
        XCTAssertEqual(gate.calls, 0)
        XCTAssertTrue(store.snapshot.profilePolicies.isEmpty)
        XCTAssertTrue(browser.selectSpace(original.spaceID))
        let saved = try await browser.setArchivePolicy(enabled, for: original)
        XCTAssertTrue(saved)
        XCTAssertTrue(store.policy(forProfileID: existing).automaticEnabled)
        XCTAssertFalse(store.policy(forProfileID: named).automaticEnabled)
        let privateBrowser = BrowserModel(isPrivate: true, tabArchive: store)
        XCTAssertNil(privateBrowser.archivePolicyScope())
        browser.isExtensionWindow = true
        XCTAssertNil(browser.archivePolicyScope())
        browser.isExtensionWindow = false
        browser.windowDidClose()
        XCTAssertNil(browser.archivePolicyScope())
    }

    func testPendingSheetEditSavesOnlyCapturedOwnerAndReportsExternalSpaceSwitch() async throws {
        let gate = WriteGate()
        let store = TabArchiveStore(persist: gate.write)
        try await store.setPolicy(.init(), forProfileID: named)
        let browser = browser(store: store)
        let scope = try XCTUnwrap(browser.archivePolicyScope())
        gate.holdNext()
        let operation = Task { try await browser.setArchivePolicy(enabled, for: scope) }
        await gate.wait()
        defer { gate.release() }
        _ = try browser.createSpace(title: "Switched externally")
        gate.release()
        let stillCurrent = try await operation.value
        XCTAssertFalse(stillCurrent)
        XCTAssertTrue(store.policy(forProfileID: scope.profileID).automaticEnabled)
        XCTAssertFalse(store.policy(forProfileID: named).automaticEnabled)
        XCTAssertNotEqual(browser.activeSpaceID, scope.spaceID)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testCapturedProfileWriteCannotRetargetWhenProfileContextChangesDuringPersistence() async throws {
        let gate = WriteGate()
        let store = TabArchiveStore(persist: gate.write)
        var activeProfileID = existing
        let capturedProfileID = activeProfileID
        gate.holdNext()
        let operation = Task {
            try await store.setPolicy(enabled, forProfileID: capturedProfileID,
                                      isCurrent: { activeProfileID == capturedProfileID })
        }
        await gate.wait()
        defer { gate.release() }
        activeProfileID = named
        gate.release()
        try await operation.value
        XCTAssertTrue(store.policy(forProfileID: capturedProfileID).automaticEnabled)
        XCTAssertFalse(store.policy(forProfileID: activeProfileID).automaticEnabled)
        XCTAssertEqual(store.snapshot.profilePolicies.count, 1)
    }

    func testAutomaticEligibilityNeverBorrowsAnotherProfilesConsent() async throws {
        let store = TabArchiveStore()
        let browser = browser(store: store)
        let tab = browser.tabs[0]
        tab.archivePageWork = .readOnly
        try await store.setPolicy(enabled, forProfileID: named)
        XCTAssertNotEqual(tab.profileID, named)
        XCTAssertFalse(browser.canArchive(tab, automatically: true))
        XCTAssertTrue(browser.canArchive(tab))
        let rejected = await browser.archiveTab(tab.id, automatically: true)
        XCTAssertFalse(rejected)
        XCTAssertTrue(browser.tabs[0] === tab)
        try await store.setPolicy(enabled, forProfileID: tab.profileID)
        XCTAssertTrue(browser.canArchive(tab, automatically: true))
        XCTAssertEqual(store.policy(forProfileID: tab.profileID).idleInterval.seconds, 24 * 60 * 60)
    }

    func testAutomaticRemovalRechecksOwnedPolicyAfterFinalMediaAwait() async throws {
        let store = TabArchiveStore()
        let browser = browser(store: store)
        let tab = browser.tabs[0]
        tab.archivePageWork = .readOnly
        try await store.setPolicy(enabled, forProfileID: tab.profileID)
        try await store.setPolicy(enabled, forProfileID: named)
        let finalMedia = WriteGate()
        finalMedia.holdNext()
        defer { finalMedia.release() }
        var calls = 0
        browser.archiveMediaCheck = { _ in
            calls += 1
            if calls == 2 { try? await finalMedia.write(Data()) }
            return false
        }
        let operation = Task { await browser.archiveTab(tab.id, automatically: true) }
        await finalMedia.wait()
        try await store.setPolicy(.init(), forProfileID: tab.profileID)
        finalMedia.release()
        let archived = await operation.value
        XCTAssertFalse(archived)
        XCTAssertTrue(browser.tabs[0] === tab)
        XCTAssertFalse(store.policy(forProfileID: tab.profileID).automaticEnabled)
        XCTAssertTrue(store.policy(forProfileID: named).automaticEnabled)
        XCTAssertEqual(store.snapshot.records.first?.tabID, tab.id)
    }
}
