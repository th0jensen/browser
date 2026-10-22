import XCTest
import WebKit
@testable import Browser

@MainActor
final class ProfileRecoveryOwnershipTests: XCTestCase {
    func testDefaultClearPreservesRawUnknownAndDescriptorMismatchedRecoveryAcrossReloadAndRestore() async throws {
        for pending in [false, true] { try await assertRecoverySurvivesClearing(named: false, pending: pending) }
    }

    func testNamedClearPreservesRawUnknownAndDescriptorMismatchedRecoveryAcrossReloadAndRestore() async throws {
        for pending in [false, true] { try await assertRecoverySurvivesClearing(named: true, pending: pending) }
    }

    func testIndependentLegacyAndUnavailableFieldsSurviveClearAttachSaveAndReloadWithoutNavigation() async throws {
        for clearFirst in [false, true] {
            let root = FileManager.default.temporaryDirectory.appending(path: "LegacyUnavailable-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let spaces = BrowserSpaceStore(directory: root, enabled: false)
            let opaque = Data([0x00, 0xff, 0x57, 0x4b, 0x80, 0x00, 0x01])
            let unknownTab = TabSession(url: URL(string: "http://127.0.0.1:9/unknown")!, title: "Keep exact unknown",
                                        interactionState: opaque, id: UUID(), spaceID: UUID(), profileID: UUID())
            let mismatchTab = TabSession(url: URL(string: "http://127.0.0.1:9/mismatch")!, title: "Keep exact mismatch",
                                         interactionState: opaque + Data([0xfe]), id: UUID())
            let unavailable = [
                SpaceSession(spaceID: UUID(), profileID: UUID(), tabs: [unknownTab], selectedIndex: 0),
                SpaceSession(spaceID: BrowserSpaceStore.defaultSpaceID, profileID: UUID(), tabs: [mismatchTab], selectedIndex: 0),
            ]
            let legacy = WindowSession(tabs: [
                TabSession(url: nil, title: "", interactionState: nil),
                TabSession(url: URL(string: "http://127.0.0.1:9/legacy")!, title: "Legacy background", interactionState: opaque),
            ], selectedIndex: 0, spaceSessions: nil, unavailableSpaceSessions: unavailable)
            let file = StoreFile(url: root.appending(path: "Session.plist"))
            file.writeNow(try PropertyListEncoder.binary.encode(SessionSnapshot(windows: [legacy])))
            let input = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
            XCTAssertNil(input.windows.first?.spaceSessions)
            XCTAssertEqual(input.windows.first?.unavailableSpaceSessions, unavailable)
            let service = SessionStore(file: file)
            if clearFirst {
                let data = BrowsingData(history: HistoryStore(file: nil), session: service, dataStore: .nonPersistent(),
                                        ownershipResolver: spaces.owns)
                await data.clear(.history, range: .all)
                XCTAssertNil(service.snapshot.windows.first?.spaceSessions)
                XCTAssertEqual(service.snapshot.windows.first?.unavailableSpaceSessions, unavailable)
                XCTAssertTrue(service.snapshot.windows.first?.tabs.isEmpty == true)
            }
            let browser = BrowserModel(spaces: spaces)
            _ = service.attach(browser)
            XCTAssertEqual(browser.windowSession().unavailableSpaceSessions, unavailable)
            XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil && $0.navigationRevision == 0 })
            service.saveBeforeQuitting()
            let saved = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
            XCTAssertEqual(saved.windows.first?.unavailableSpaceSessions, unavailable)
            XCTAssertEqual(saved.windows.first?.unavailableSpaceSessions?.flatMap(\.tabs).map(\.interactionState),
                           [opaque, opaque + Data([0xfe])])
            let reloaded = SessionStore(file: file)
            let next = BrowserModel(spaces: spaces)
            _ = reloaded.attach(next)
            XCTAssertEqual(next.windowSession().unavailableSpaceSessions, unavailable)
            XCTAssertTrue(next.allTabs.allSatisfy { $0.webView == nil && $0.navigationRevision == 0 })
            reloaded.saveBeforeQuitting()
            let final = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
            XCTAssertEqual(final.windows.first?.unavailableSpaceSessions, unavailable)
            // Compare every record field as well as the opaque interaction bytes; no recovery record is normalized.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            XCTAssertEqual(try encoder.encode(final.windows.first?.unavailableSpaceSessions), try encoder.encode(Optional(unavailable)))
        }
    }

    private func assertRecoverySurvivesClearing(named: Bool, pending: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RecoveryOwnership-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = BrowserSpaceStore(directory: root)
        let namedProfile = try spaces.profiles.create(title: "Work")
        let namedSpace = try spaces.createSpace(title: "Work", profileID: namedProfile.id)
        let defaultSpace = try XCTUnwrap(spaces.space(BrowserSpaceStore.defaultSpaceID))
        let target = named ? namedSpace : defaultSpace
        let other = named ? defaultSpace : namedSpace
        let mismatchedDescriptor = try spaces.createSpace(title: "Other ownership", profileID: other.profileID)
        func tab(_ name: String) -> TabSession {
            TabSession(url: URL(string: "http://127.0.0.1:9/\(name)")!, title: name,
                       interactionState: Data("opaque-\(name)-interaction".utf8), id: UUID())
        }
        // These records are self-consistent. Only the descriptor resolver exposes their unavailable ownership.
        let unknown = SpaceSession(spaceID: UUID(), profileID: target.profileID, tabs: [tab("unknown")], selectedIndex: 0)
        let mismatch = SpaceSession(spaceID: mismatchedDescriptor.id, profileID: target.profileID, tabs: [tab("mismatch")], selectedIndex: 0)
        let validTarget = SpaceSession(spaceID: target.id, profileID: target.profileID, tabs: [tab("clear")], selectedIndex: 0)
        let otherPage = tab("keep-background")
        let validOther = SpaceSession(spaceID: other.id, profileID: other.profileID,
                                      tabs: [TabSession(url: nil, title: "", interactionState: nil), otherPage], selectedIndex: 0)
        XCTAssertFalse(spaces.owns(unknown))
        XCTAssertFalse(spaces.owns(mismatch))
        XCTAssertTrue(spaces.owns(validTarget))
        let raw = WindowSession(tabs: unknown.tabs, selectedIndex: 0, activeSpaceID: unknown.spaceID,
                                spaceSessions: [unknown, mismatch, validTarget, validOther])
        let file = StoreFile(url: root.appending(path: "Session.plist"))
        file.writeNow(try PropertyListEncoder.binary.encode(SessionSnapshot(windows: pending ? [raw] : [],
                                                                          closedWindows: pending ? [] : [raw])))
        let service = SessionStore(file: file)
        let data = BrowsingData(history: HistoryStore(file: nil), session: service, dataStore: .nonPersistent(),
                                includesSharedState: false, profileID: target.profileID, ownershipResolver: spaces.owns)
        await data.clear(.history, range: .all)
        let retained = [unknown, mismatch, validOther]
        let cleared = pending ? service.snapshot.windows.first : service.reopenableWindows.first
        XCTAssertEqual(cleared?.spaceSessions, retained)
        XCTAssertEqual(cleared?.tabs, unknown.tabs)
        XCTAssertEqual(cleared?.activeSpaceID, unknown.spaceID)
        service.saveBeforeQuitting()

        let descriptors = BrowserSpaceStore(directory: root)
        let reloaded = SessionStore(file: file)
        let recovered = pending ? reloaded.snapshot.windows.first : reloaded.reopenableWindows.first
        XCTAssertEqual(recovered?.spaceSessions, retained)
        let browser = BrowserModel(spaces: descriptors)
        _ = reloaded.attach(browser)
        if !pending { XCTAssertEqual(reloaded.reopenLastSession(reusing: browser), 0) }
        assertUnloadedRecovery(browser, unknown: unknown, mismatch: mismatch, otherPage: otherPage)
        reloaded.saveBeforeQuitting()
        let persisted = try PropertyListDecoder().decode(SessionSnapshot.self, from: XCTUnwrap(file.readNow()))
        XCTAssertEqual(persisted.windows.first?.unavailableSpaceSessions, [unknown, mismatch])
        XCTAssertTrue(persisted.closedWindows.isEmpty)
    }

    private func assertUnloadedRecovery(_ browser: BrowserModel, unknown: SpaceSession, mismatch: SpaceSession,
                                       otherPage: TabSession, file: StaticString = #filePath, line: UInt = #line) {
        let recovery = browser.windowSession().unavailableSpaceSessions
        XCTAssertEqual(recovery, [unknown, mismatch], file: file, line: line)
        XCTAssertEqual(recovery?.flatMap(\.tabs).map(\.url), [unknown.tabs[0].url, mismatch.tabs[0].url], file: file, line: line)
        XCTAssertEqual(recovery?.flatMap(\.tabs).map(\.interactionState),
                       [unknown.tabs[0].interactionState, mismatch.tabs[0].interactionState], file: file, line: line)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil && $0.navigationRevision == 0 }, file: file, line: line)
        let background = browser.tabAcrossSpaces(withID: otherPage.id!)
        XCTAssertEqual(background?.url, otherPage.url, file: file, line: line)
        XCTAssertEqual(background?.interactionState as? Data, otherPage.interactionState, file: file, line: line)
    }
}
