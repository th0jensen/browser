import AppKit
import XCTest
@testable import Browser

@MainActor
final class SpacePresentationTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "SpaceAppearance-\(UUID())", directoryHint: .isDirectory)
    }

    func testLegacyAppearanceDefaultsPreserveOwnershipAndDoNotWriteOnRead() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ids = [BrowserSpaceStore.defaultSpaceID, UUID()]
        let legacy = try JSONSerialization.data(withJSONObject: ids.enumerated().map { index, id in
            ["id": id.uuidString, "title": "Space \(index)", "profileID": BrowserProfile.defaultID.uuidString]
        })
        let file = root.appending(path: "Spaces.json")
        try legacy.write(to: file)
        let store = BrowserSpaceStore(directory: root)
        XCTAssertEqual(store.spaces.map(\.id), ids)
        XCTAssertTrue(store.spaces.allSatisfy { $0.icon == .circle && $0.theme == .system && $0.profileID == BrowserProfile.defaultID })
        XCTAssertEqual(try Data(contentsOf: file), legacy)

        try store.updateSpace(ids[1], title: "Work", icon: .work, theme: .purple)

        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Spaces.before-appearance.json")), legacy)
        let reopened = BrowserSpaceStore(directory: root)
        XCTAssertEqual(reopened.spaces.map(\.id), ids)
        XCTAssertEqual(reopened.spaces[1].title, "Work")
        XCTAssertEqual(reopened.spaces[1].icon, .work)
        XCTAssertEqual(reopened.spaces[1].theme, .purple)
        XCTAssertTrue(reopened.spaces.allSatisfy { $0.profileID == BrowserProfile.defaultID })
        try reopened.updateSpace(ids[1], title: "Work Again", icon: .book, theme: .green)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Spaces.before-appearance.json")), legacy)
    }

    private enum InjectedWriteFailure: Error { case stopped }

    private func assertOwnerOnly(_ file: URL, filePath: StaticString = #filePath, line: UInt = #line) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, file: filePath, line: line)
    }

    private func assertNoStagingFiles(in directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".Spaces-") && $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "Failed staging must be removed: \(leftovers)", file: file, line: line)
    }

    func testFailedFirstMetadataWriteNeverCreatesCanonicalAndFreshStoreCanRetry() throws {
        for failurePoint in [BrowserSpaceStore.WriteCheckpoint.partialStagingWrite, .beforePublication] {
            for creating in [true, false] {
                let root = directory()
                defer { try? FileManager.default.removeItem(at: root) }
                let canonical = root.appending(path: "Spaces.json")
                var stagedURL: URL?
                var reachedFailurePoint = false
                let store = BrowserSpaceStore(directory: root, writeCheckpoint: { checkpoint, temporary in
                    stagedURL = temporary
                    try self.assertOwnerOnly(temporary)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path), "Canonical must remain absent throughout staging")
                    let staged = try Data(contentsOf: temporary)
                    XCTAssertFalse(staged.isEmpty)
                    if checkpoint == .partialStagingWrite {
                        XCTAssertThrowsError(try JSONDecoder().decode([BrowserSpace].self, from: staged))
                    } else {
                        let records = try JSONDecoder().decode([BrowserSpace].self, from: staged)
                        XCTAssertEqual(records.count, creating ? 2 : 1)
                        XCTAssertTrue(records.allSatisfy { $0.profileID == BrowserProfile.defaultID })
                    }
                    if checkpoint == failurePoint {
                        reachedFailurePoint = true
                        throw InjectedWriteFailure.stopped
                    }
                })
                let original = store.spaces
                if creating {
                    XCTAssertThrowsError(try store.createSpace(title: "Unpublished", icon: .work, theme: .blue))
                } else {
                    XCTAssertThrowsError(try store.updateSpace(BrowserSpaceStore.defaultSpaceID, title: "Unpublished", icon: .work, theme: .blue))
                }
                XCTAssertTrue(reachedFailurePoint)
                XCTAssertEqual(store.spaces, original)
                XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(stagedURL).path))
                try assertNoStagingFiles(in: root)

                // A fresh launch has no corrupt canonical file and needs no repair after the fault is removed.
                let retry = BrowserSpaceStore(directory: root)
                let recoveredID: UUID
                if creating {
                    recoveredID = try retry.createSpace(title: "Recovered", icon: .book, theme: .green).id
                } else {
                    recoveredID = BrowserSpaceStore.defaultSpaceID
                    try retry.updateSpace(recoveredID, title: "Recovered", icon: .book, theme: .green)
                }
                try assertOwnerOnly(canonical)
                try assertNoStagingFiles(in: root)
                let reopened = BrowserSpaceStore(directory: root)
                XCTAssertEqual(reopened.spaces, retry.spaces)
                XCTAssertEqual(reopened.space(recoveredID)?.title, "Recovered")
                XCTAssertEqual(reopened.space(recoveredID)?.icon, .book)
                XCTAssertEqual(reopened.space(recoveredID)?.theme, .green)
                XCTAssertTrue(reopened.spaces.allSatisfy { $0.profileID == BrowserProfile.defaultID })
            }
        }
    }

    func testStagingFailuresPreserveExistingMetadataAndEveryOriginalRecoveryCopy() throws {
        for failurePoint in [BrowserSpaceStore.WriteCheckpoint.partialStagingWrite, .beforePublication] {
            // Modern metadata; legacy metadata without a backup; legacy metadata with an older recovery copy.
            for scenario in 0...2 {
                let root = directory()
                defer { try? FileManager.default.removeItem(at: root) }
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let ids = [BrowserSpaceStore.defaultSpaceID, UUID()]
                let records = ids.enumerated().map { index, id -> [String: Any] in
                    var record: [String: Any] = ["id": id.uuidString, "title": "Original \(index)", "profileID": BrowserProfile.defaultID.uuidString]
                    if scenario == 0 { record["icon"] = "work"; record["theme"] = "blue" }
                    return record
                }
                let original = try JSONSerialization.data(withJSONObject: records)
                let canonical = root.appending(path: "Spaces.json")
                try original.write(to: canonical)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: canonical.path)
                let backup = root.appending(path: "Spaces.before-appearance.json")
                let olderRecovery = try JSONEncoder().encode([BrowserSpace(id: BrowserSpaceStore.defaultSpaceID,
                    title: "Older Recovery", profileID: BrowserProfile.defaultID)])
                if scenario == 2 {
                    try olderRecovery.write(to: backup)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
                var reachedFailurePoint = false
                let store = BrowserSpaceStore(directory: root, writeCheckpoint: { checkpoint, temporary in
                    try self.assertOwnerOnly(temporary)
                    XCTAssertEqual(try Data(contentsOf: canonical), original)
                    if checkpoint == failurePoint {
                        reachedFailurePoint = true
                        throw InjectedWriteFailure.stopped
                    }
                })
                let published = store.spaces
                XCTAssertThrowsError(try store.updateSpace(ids[1], title: "Unpublished", icon: .heart, theme: .pink))
                XCTAssertTrue(reachedFailurePoint)
                XCTAssertEqual(store.spaces, published)
                XCTAssertEqual(try Data(contentsOf: canonical), original)
                try assertOwnerOnly(canonical)
                try assertNoStagingFiles(in: root)
                if scenario != 0 {
                    XCTAssertEqual(try Data(contentsOf: backup), scenario == 2 ? olderRecovery : original)
                    try assertOwnerOnly(backup)
                }

                let retry = BrowserSpaceStore(directory: root)
                try retry.updateSpace(ids[1], title: "Recovered", icon: .leaf, theme: .green)
                let reloaded = BrowserSpaceStore(directory: root)
                XCTAssertEqual(reloaded.spaces.map(\.id), ids)
                XCTAssertEqual(reloaded.spaces[1].title, "Recovered")
                XCTAssertEqual(reloaded.spaces[1].icon, .leaf)
                XCTAssertTrue(reloaded.spaces.allSatisfy { $0.profileID == BrowserProfile.defaultID })
                try assertOwnerOnly(canonical)
                try assertNoStagingFiles(in: root)
                if scenario != 0 {
                    XCTAssertEqual(try Data(contentsOf: backup), scenario == 2 ? olderRecovery : original)
                    try assertOwnerOnly(backup)
                }
            }
        }
    }

    func testNamedProfileFirstWriteFailureKeepsOwnershipRetryAndUnknownProfileRejection() throws {
        for failurePoint in [BrowserSpaceStore.WriteCheckpoint.partialStagingWrite, .beforePublication] {
            let root = directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let profiles = BrowserProfileStore(directory: root)
            let profile = try profiles.create(title: "Work")
            let profileFile = root.appending(path: "Profiles.json")
            let profileBytes = try Data(contentsOf: profileFile)
            let canonical = root.appending(path: "Spaces.json")
            var reachedFailurePoint = false
            let store = BrowserSpaceStore(directory: root, profiles: profiles, writeCheckpoint: { checkpoint, temporary in
                try self.assertOwnerOnly(temporary)
                XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
                if checkpoint == .beforePublication {
                    let records = try JSONDecoder().decode([BrowserSpace].self, from: Data(contentsOf: temporary))
                    XCTAssertEqual(records.map(\.profileID), [BrowserProfile.defaultID, profile.id])
                    XCTAssertEqual(records.last?.icon, .work)
                    XCTAssertEqual(records.last?.theme, .blue)
                }
                if checkpoint == failurePoint {
                    reachedFailurePoint = true
                    throw InjectedWriteFailure.stopped
                }
            })
            let original = store.spaces
            XCTAssertThrowsError(try store.createSpace(title: "Work", profileID: profile.id, icon: .work, theme: .blue))
            XCTAssertTrue(reachedFailurePoint)
            XCTAssertEqual(store.spaces, original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
            XCTAssertEqual(try Data(contentsOf: profileFile), profileBytes)
            XCTAssertFalse(profiles.hasLoadedResources(for: profile.id))
            try assertNoStagingFiles(in: root)
            let retry = BrowserSpaceStore(directory: root)
            let created = try retry.createSpace(title: "Recovered", profileID: profile.id, icon: .book, theme: .green)
            try assertOwnerOnly(canonical)
            let reloaded = BrowserSpaceStore(directory: root)
            XCTAssertEqual(reloaded.space(created.id), created)
            XCTAssertEqual(created.profileID, profile.id)
            XCTAssertTrue(reloaded.owns(SpaceSession(spaceID: created.id, profileID: profile.id, tabs: [], selectedIndex: 0)))
            let saved = try Data(contentsOf: canonical)
            var called = false
            let rejectsUnknown = BrowserSpaceStore(directory: root, writeCheckpoint: { _, _ in called = true })
            XCTAssertThrowsError(try rejectsUnknown.createSpace(title: "Unknown", profileID: UUID(), icon: .code, theme: .gray))
            XCTAssertFalse(called, "Unavailable profiles fail before any staging checkpoint")
            XCTAssertEqual(try Data(contentsOf: canonical), saved)
            try assertNoStagingFiles(in: root)
        }
    }

    func testNamedProfileLegacyAppearanceBackupSurvivesStagingFailureAndRetry() throws {
        for failurePoint in [BrowserSpaceStore.WriteCheckpoint.partialStagingWrite, .beforePublication] {
            let root = directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let profiles = BrowserProfileStore(directory: root)
            let profile = try profiles.create(title: "Work")
            let namedID = UUID()
            let legacy = try JSONSerialization.data(withJSONObject: [
                ["id": BrowserSpaceStore.defaultSpaceID.uuidString, "title": "Default", "profileID": BrowserProfile.defaultID.uuidString],
                ["id": namedID.uuidString, "title": "Work", "profileID": profile.id.uuidString],
            ])
            let canonical = root.appending(path: "Spaces.json")
            let backup = root.appending(path: "Spaces.before-appearance.json")
            try legacy.write(to: canonical)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: canonical.path)
            let store = BrowserSpaceStore(directory: root, profiles: profiles, writeCheckpoint: { checkpoint, temporary in
                try self.assertOwnerOnly(temporary)
                XCTAssertEqual(try Data(contentsOf: canonical), legacy)
                if checkpoint == failurePoint { throw InjectedWriteFailure.stopped }
            })
            XCTAssertThrowsError(try store.updateSpace(namedID, title: "Unpublished", icon: .heart, theme: .pink))
            XCTAssertEqual(store.space(namedID)?.profileID, profile.id)
            XCTAssertEqual(store.space(namedID)?.title, "Work")
            XCTAssertEqual(try Data(contentsOf: canonical), legacy)
            XCTAssertEqual(try Data(contentsOf: backup), legacy)
            try assertOwnerOnly(backup)
            try assertNoStagingFiles(in: root)
            let retry = BrowserSpaceStore(directory: root)
            try retry.updateSpace(namedID, title: "Recovered", icon: .leaf, theme: .green)
            let reloaded = BrowserSpaceStore(directory: root)
            XCTAssertEqual(reloaded.space(namedID)?.profileID, profile.id)
            XCTAssertEqual(reloaded.space(namedID)?.title, "Recovered")
            XCTAssertEqual(reloaded.space(namedID)?.icon, .leaf)
            XCTAssertEqual(reloaded.space(namedID)?.theme, .green)
            XCTAssertEqual(try Data(contentsOf: backup), legacy)
            try assertOwnerOnly(canonical)
            try assertNoStagingFiles(in: root)
        }
    }

    func testNullAndWrongTypeAppearanceFieldsKeepOwnershipAndDefaults() throws {
        let id = UUID()
        let fixtures: [[String: Any]] = [
            ["icon": NSNull(), "theme": NSNull()],
            ["icon": 42, "theme": ["unexpected": true]],
            ["icon": ["unexpected": true], "theme": [1, 2]],
            ["icon": true, "theme": false],
        ]
        for appearance in fixtures {
            var record: [String: Any] = ["id": id.uuidString, "title": "Original", "profileID": BrowserProfile.defaultID.uuidString]
            record.merge(appearance) { _, value in value }
            let space = try JSONDecoder().decode(BrowserSpace.self, from: JSONSerialization.data(withJSONObject: record))
            XCTAssertEqual(space.id, id)
            XCTAssertEqual(space.profileID, BrowserProfile.defaultID)
            XCTAssertEqual(space.title, "Original")
            XCTAssertEqual(space.icon, .circle)
            XCTAssertEqual(space.theme, .system)
        }
    }

    func testUnknownAppearanceMetadataDoesNotHideLegacySpaceRecords() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "title": "Future", "profileID": BrowserProfile.defaultID.uuidString,
            "icon": "future-icon", "theme": "future-theme"
        ])
        let space = try JSONDecoder().decode(BrowserSpace.self, from: data)
        XCTAssertEqual(space.title, "Future")
        XCTAssertEqual(space.icon, .circle)
        XCTAssertEqual(space.theme, .system)
        XCTAssertEqual(space.profileID, BrowserProfile.defaultID)
    }

    func testEveryAppearanceOptionRoundTripsAndHasAnAvailableNativeSymbol() throws {
        for icon in BrowserSpaceIcon.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: icon.symbol, accessibilityDescription: icon.title), icon.symbol)
            for theme in BrowserSpaceTheme.allCases {
                let space = BrowserSpace(id: UUID(), title: "Personal", profileID: BrowserProfile.defaultID, icon: icon, theme: theme)
                XCTAssertEqual(try JSONDecoder().decode(BrowserSpace.self, from: JSONEncoder().encode(space)), space)
            }
        }
    }

    func testFailedAppearanceBackupDoesNotChangeOriginalOrPublishedMetadata() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "Spaces.json")
        let legacy = try JSONSerialization.data(withJSONObject: [[
            "id": BrowserSpaceStore.defaultSpaceID.uuidString, "title": "Original", "profileID": BrowserProfile.defaultID.uuidString
        ]])
        try legacy.write(to: file)
        try FileManager.default.createDirectory(at: root.appending(path: "Spaces.before-appearance.json"), withIntermediateDirectories: true)
        let store = BrowserSpaceStore(directory: root)
        XCTAssertThrowsError(try store.updateSpace(BrowserSpaceStore.defaultSpaceID, title: "Changed", icon: .work, theme: .blue))
        XCTAssertEqual(store.spaces.first?.title, "Original")
        XCTAssertEqual(store.spaces.first?.icon, .circle)
        XCTAssertEqual(try Data(contentsOf: file), legacy)
    }

    func testAppearanceCreationAndEditingDoNotReplaceLiveTabsOrSavedDescriptors() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserSpaceStore(directory: root)
        let browser = BrowserModel(spaces: store)
        let page = try browser.folders.savePage(url: URL(string: "https://space.invalid/saved")!, title: "Manual name", in: nil)
        let savedBytes = try Data(contentsOf: root.appending(path: "TabFolders.json"))
        let original = try XCTUnwrap(browser.activeTab)
        let created = try browser.createSpace(title: "Work", icon: .work, theme: .blue)
        let selected = try XCTUnwrap(browser.activeTab)
        let ids = browser.allTabs.map(\.id)
        try store.updateSpace(created.id, title: "Research", icon: .book, theme: .purple)
        XCTAssertEqual(browser.activeSpaceID, created.id)
        XCTAssertTrue(browser.activeTab === selected)
        XCTAssertEqual(browser.allTabs.map(\.id), ids)
        XCTAssertTrue(browser.tabAcrossSpaces(withID: original.id) === original)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil && $0.profileID == BrowserProfile.defaultID })
        XCTAssertEqual(browser.folders(forSpaceID: BrowserSpaceStore.defaultSpaceID).pages.first?.id, page.id)
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "TabFolders.json")), savedBytes)
        let reloaded = BrowserSpaceStore(directory: root)
        XCTAssertEqual(reloaded.space(created.id)?.icon, .book)
        XCTAssertEqual(reloaded.space(created.id)?.theme, .purple)
    }

    func testNamedProfileAppearanceCreationAndEditingKeepImmutableOwnership() throws {
        let store = BrowserSpaceStore(directory: directory(), enabled: false)
        let profile = try store.profiles.create(title: "Work Profile")
        let browser = BrowserModel(spaces: store)
        let legacy = try browser.createSpace(title: "Legacy call")
        XCTAssertEqual(legacy.profileID, BrowserProfile.defaultID)
        let appearanceOnly = try browser.createSpace(title: "Appearance call", icon: .home, theme: .green)
        XCTAssertEqual(appearanceOnly.profileID, BrowserProfile.defaultID)
        let profileOnly = try browser.createSpace(title: "Profile call", profileID: profile.id)
        XCTAssertEqual(profileOnly.icon, .circle)
        XCTAssertEqual(profileOnly.theme, .system)
        let named = try browser.createSpace(title: "Named", profileID: profile.id, icon: .work, theme: .blue)
        let selected = try XCTUnwrap(browser.activeTab)
        try store.updateSpace(named.id, title: "Renamed", icon: .book, theme: .purple)
        let edited = try XCTUnwrap(store.space(named.id))
        XCTAssertEqual(edited.profileID, profile.id)
        XCTAssertEqual(edited.icon, .book)
        XCTAssertEqual(edited.theme, .purple)
        XCTAssertEqual(try JSONDecoder().decode(BrowserSpace.self, from: JSONEncoder().encode(edited)), edited)
        XCTAssertTrue(browser.activeTab === selected)
        XCTAssertEqual(selected.profileID, profile.id)
        XCTAssertEqual(selected.spaceID, named.id)
        XCTAssertNil(selected.webView)
        XCTAssertTrue(store.owns(SpaceSession(spaceID: named.id, profileID: profile.id, tabs: [], selectedIndex: 0)))
        XCTAssertFalse(store.owns(SpaceSession(spaceID: named.id, profileID: BrowserProfile.defaultID, tabs: [], selectedIndex: 0)))
        let count = store.spaces.count
        XCTAssertThrowsError(try browser.createSpace(title: "Unavailable", profileID: UUID(), icon: .code, theme: .gray))
        XCTAssertEqual(store.spaces.count, count)
        let index = try XCTUnwrap(store.spaces.firstIndex { $0.id == profileOnly.id })
        XCTAssertTrue(browser.selectSpace(at: index))
        XCTAssertEqual(browser.profileID, profile.id)
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testNarrowAndOverflowLayoutsRetainSelectedSpaceAndCreationCapacity() {
        let wide = SpaceStripLayout(count: 3, selectedIndex: 2, width: 300)
        XCTAssertEqual(wide.visibleIndices, 0..<3)
        XCTAssertFalse(wide.showsOverflow)
        XCTAssertFalse(wide.usesCompactMenu)
        for index in 0..<100 {
            let layout = SpaceStripLayout(count: 100, selectedIndex: index, width: 180)
            XCTAssertTrue(layout.visibleIndices.contains(index))
            XCTAssertLessThanOrEqual(layout.visibleIndices.count, 2)
            XCTAssertTrue(layout.showsOverflow)
            XCTAssertFalse(layout.usesCompactMenu)
        }
        for width: CGFloat in [0, 72, 100, .nan] {
            let compact = SpaceStripLayout(count: 100, selectedIndex: 80, width: width)
            XCTAssertEqual(compact.visibleIndices, 80..<81)
            XCTAssertTrue(compact.usesCompactMenu)
            XCTAssertTrue(compact.showsOverflow)
        }
        XCTAssertEqual(SpaceStripLayout(count: 0, selectedIndex: -1, width: 200).visibleIndices, 0..<0)
        XCTAssertEqual(SpaceStripLayout(count: 3, selectedIndex: 1000, width: 72).visibleIndices, 2..<3)
    }

    func testControlNumberRecognitionDoesNotCaptureOtherTextOrModifiedKeys() throws {
        func event(_ digit: String, modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: digit, charactersIgnoringModifiers: digit,
                isARepeat: false, keyCode: 0))
        }
        for number in 1...9 {
            XCTAssertTrue(BrowserShortcutView.isBrowserCommand(try event(String(number), modifiers: .control)))
            XCTAssertFalse(BrowserShortcutView.isBrowserCommand(try event(String(number), modifiers: [])))
            XCTAssertFalse(BrowserShortcutView.isBrowserCommand(try event(String(number), modifiers: [.control, .shift])))
        }
        XCTAssertFalse(BrowserShortcutView.isBrowserCommand(try event("0", modifiers: .control)))
    }

    func testNumberSelectionIsWindowLocalLazyAndRejectsUnavailableDestinations() throws {
        let store = BrowserSpaceStore(directory: directory(), enabled: false)
        let work = try store.createSpace(title: "Work", icon: .work, theme: .blue)
        let first = BrowserModel(spaces: store)
        let second = BrowserModel(spaces: store)
        XCTAssertTrue(first.selectSpace(at: 1))
        XCTAssertEqual(first.activeSpaceID, work.id)
        XCTAssertEqual(second.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        let selected = first.activeTabID
        XCTAssertFalse(first.selectSpace(at: -1))
        XCTAssertFalse(first.selectSpace(at: 9))
        XCTAssertEqual(first.activeTabID, selected)
        XCTAssertTrue((first.allTabs + second.allTabs).allSatisfy { $0.webView == nil })
        let privateWindow = BrowserModel(isPrivate: true)
        XCTAssertFalse(privateWindow.selectSpace(at: 0))
        let extensionWindow = BrowserModel(spaces: store)
        extensionWindow.isExtensionWindow = true
        XCTAssertFalse(extensionWindow.selectSpace(at: 1))
    }
}
