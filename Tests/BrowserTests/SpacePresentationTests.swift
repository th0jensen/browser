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
