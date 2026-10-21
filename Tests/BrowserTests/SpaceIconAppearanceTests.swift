import AppKit
import XCTest
@testable import Browser

@MainActor
final class SpaceIconAppearanceTests: XCTestCase {
    func testLegacyAndMalformedAppearanceKeepSpaceIdentityAndLegacyIcon() throws {
        let id = UUID()
        for extra: [String: Any] in [[:], ["symbol": ["bad": true], "emoji": 42, "color": false],
                                     ["symbol": "unknown.symbol", "emoji": "\n", "color": "unknown"]] {
            var json: [String: Any] = ["id": id.uuidString, "title": "Work", "profileID": BrowserProfile.defaultID.uuidString,
                                       "icon": "work", "theme": "blue"]
            json.merge(extra) { _, value in value }
            let space = try JSONDecoder().decode(BrowserSpace.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(space.id, id)
            XCTAssertEqual(space.profileID, BrowserProfile.defaultID)
            XCTAssertEqual(space.icon, .work)
            XCTAssertEqual(space.theme, .blue)
            XCTAssertEqual(space.displaySymbol, BrowserSpaceIcon.work.symbol)
            XCTAssertNil(space.symbol)
            XCTAssertEqual(space.emoji, "")
            XCTAssertEqual(space.color, .primary)
        }
    }

    func testEmojiSymbolsAndIconColorsRoundTripWithoutChangingOwnershipOrOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SpaceEmoji-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserSpaceStore(directory: root)
        for emoji in ["👩🏽‍💻", "🇮🇱", "👨‍👩‍👧‍👦"] {
            let created = try store.createSpace(title: emoji, icon: .work, theme: .green, symbol: "terminal", emoji: emoji, color: .blue)
            XCTAssertEqual(created.emoji, emoji, "A whole composed emoji must survive, including ZWJ and modifiers")
            let before = store.spaces.map(\.id)
            try store.updateSpace(created.id, title: "Renamed", icon: .work, theme: .green)
            let reopened = BrowserSpaceStore(directory: root)
            XCTAssertEqual(reopened.spaces.map(\.id), before)
            let saved = try XCTUnwrap(reopened.space(created.id))
            XCTAssertEqual(saved.profileID, BrowserProfile.defaultID)
            XCTAssertEqual(saved.emoji, emoji)
            XCTAssertEqual(saved.displaySymbol, "terminal")
            XCTAssertEqual(saved.color, .blue)
            try store.updateSpace(created.id, title: "Symbol again", icon: .work, theme: .green, symbol: "house", emoji: "", color: .pink)
            let cleared = try XCTUnwrap(BrowserSpaceStore(directory: root).space(created.id))
            XCTAssertEqual(cleared.emoji, "")
            XCTAssertEqual(cleared.displaySymbol, "house")
            XCTAssertEqual(cleared.color, .pink)
        }
    }

    func testOnlySelectedSpaceRendersItsEmojiAndSwitchingBackToSymbolClearsText() throws {
        let space = BrowserSpace(id: UUID(), title: "Work", profileID: BrowserProfile.defaultID,
                                 symbol: "terminal", emoji: "👩🏽‍💻", color: .blue)
        let button = SpaceChoiceButton(spaceID: space.id)
        button.configure(space, selected: true, compact: false)
        XCTAssertEqual(button.title, space.emoji)
        XCTAssertEqual(button.displayedEmoji, space.emoji)
        XCTAssertNil(button.image)
        XCTAssertNil(button.displayedSymbol)
        XCTAssertEqual(button.imagePosition, .noImage)
        button.configure(space, selected: false, compact: false)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.displayedEmoji, "")
        XCTAssertNil(button.image)
        XCTAssertNil(button.displayedSymbol)
        var symbol = space
        symbol.emoji = ""
        button.configure(symbol, selected: true, compact: false)
        XCTAssertEqual(button.title, "")
        XCTAssertEqual(button.displayedSymbol, "terminal")
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertNotNil(button.image)
        for candidate in SavedItemIconSymbols.all { XCTAssertNotNil(NSImage(systemSymbolName: candidate, accessibilityDescription: nil)) }
    }

    func testEmojiNormalizationIsBoundedWithoutSplittingComposedCharacters() {
        XCTAssertEqual(BrowserSpace.cleanEmoji("🦊🐻"), "🦊")
        XCTAssertEqual(BrowserSpace.cleanEmoji("🏳️‍🌈"), "🏳️‍🌈")
        XCTAssertEqual(BrowserSpace.cleanEmoji(String(repeating: "a", count: 1000)), "")
        XCTAssertEqual(BrowserSpace.cleanEmoji("\u{0}"), "")
    }

    func testFailedEmojiPublicationRetainsOriginalBytesAndLiveMetadata() throws {
        enum Failure: Error { case stopped }
        let root = FileManager.default.temporaryDirectory.appending(path: "SpaceEmojiFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserSpaceStore(directory: root)
        let saved = try store.createSpace(title: "Work", icon: .work, theme: .blue, symbol: "book", emoji: "📚", color: .purple)
        let file = root.appending(path: "Spaces.json")
        let original = try Data(contentsOf: file)
        let fault = BrowserSpaceStore(directory: root, writeCheckpoint: { checkpoint, _ in
            if checkpoint == .beforePublication { throw Failure.stopped }
        })
        let metadata = fault.spaces
        XCTAssertThrowsError(try fault.updateSpace(saved.id, title: "Changed", icon: .home, theme: .pink,
                                                  symbol: "house", emoji: "🏡", color: .green))
        XCTAssertEqual(fault.spaces, metadata)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(BrowserSpaceStore(directory: root).space(saved.id), saved)
    }
}
