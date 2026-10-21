import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class CommandPaletteFaviconTests: XCTestCase {
    private let url = URL(string: "https://palette-icons.invalid/Guide")!

    func testCachedPagesBookmarksAndSavedResultsUseColourWithoutLoadingTabs() async throws {
        let browser = browser()
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let originalCache = FaviconStore.cache
        FaviconStore.cache = FaviconCache(directory: directory)
        await FaviconStore.clear(since: .distantPast)
        addTeardownBlock {
            await FaviconStore.clear(since: .distantPast)
            await MainActor.run { FaviconStore.cache = originalCache }
            try? FileManager.default.removeItem(at: directory)
        }
        let data = try png()
        let candidate = FaviconCandidate(url: try XCTUnwrap(URL(string: "data:image/png;base64,\(data.base64EncodedString())")))
        let loaded = await FaviconStore.icon(forPage: url, candidates: [candidate])
        XCTAssertNotNil(loaded)
        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: url, title: "Guide Tab", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil)
        ], selectedIndex: 1))
        let tab = try XCTUnwrap(browser.tabs.first)
        let saved = try browser.folders.savePage(url: url, title: "Guide Saved", in: nil)
        let pinned = try browser.pinnedPages.pin(url: url, title: "Guide Essential")
        let actions: [AddressResult.Action] = [
            .navigate(url), .openURL(AddressSuggestion(url: url, title: "Guide History", isBookmarked: false)),
            .openURL(AddressSuggestion(url: url, title: "Guide Bookmark", isBookmarked: true)),
            .openSavedPage(id: saved.id, spaceID: browser.activeSpaceID, kind: .folderPage, url: url),
            .openSavedPage(id: pinned.id, spaceID: browser.activeSpaceID, kind: .essential, url: url),
            tabAction(tab)
        ]
        for action in actions {
            let image = try XCTUnwrap(CommandPaletteFavicon.image(for: result(action, browser), in: browser, source: nil))
            try assertRed(image)
        }
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil }, "Icon display never restores a page")
        XCTAssertEqual(browser.allTabs.count, 2)
        let cached = result(.navigate(url), browser)
        tab.favicon = nil
        await FaviconStore.clear(since: .distantPast)
        XCTAssertNil(CommandPaletteFavicon.image(for: cached, in: browser, source: nil), "A new snapshot respects cache clearing")
    }

    func testPrivateAndExtensionUseOnlyTheirOwnLiveIconAndNeverReadNormalCache() throws {
        for isPrivate in [true, false] {
            let browser = browser(isPrivate: isPrivate)
            browser.isExtensionWindow = !isPrivate
            browser.restoreSession(WindowSession(tabs: [
                TabSession(url: url, title: "Own Page", interactionState: nil),
                TabSession(url: nil, title: "", interactionState: nil)
            ], selectedIndex: 1))
            let tab = try XCTUnwrap(browser.tabs.first)
            var cacheReads = 0
            func snapshot(_ action: AddressResult.Action, source: BrowserTab? = nil) -> Image? {
                CommandPaletteFavicon.snapshot(for: result(action, browser), in: browser, source: source) { _ in
                    cacheReads += 1
                    return Image(nsImage: redImage())
                }
            }
            XCTAssertNil(snapshot(.navigate(url)))
            XCTAssertNil(snapshot(tabAction(tab)))
            tab.favicon = Image(nsImage: redImage())
            XCTAssertNotNil(snapshot(tabAction(tab)))
            XCTAssertNotNil(snapshot(.navigate(url), source: tab))
            XCTAssertNil(snapshot(.openURL(AddressSuggestion(url: url, title: "Normal History", isBookmarked: false))))
            let other = self.browser(isPrivate: isPrivate)
            let foreign = BrowserTab(url: url, title: "Foreign", interactionState: nil, browser: other)
            foreign.favicon = Image(nsImage: redImage())
            tab.favicon = nil
            XCTAssertNil(snapshot(.navigate(url), source: foreign))
            XCTAssertEqual(cacheReads, 0)
            XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
        }
    }

    func testOwnerProfileInstanceAndDeletedSavedResultsFailBeforeCacheLookup() throws {
        let browser = browser()
        browser.restoreSession(WindowSession(tabs: [
            TabSession(url: url, title: "Guide", interactionState: nil),
            TabSession(url: nil, title: "", interactionState: nil)
        ], selectedIndex: 1))
        let tab = try XCTUnwrap(browser.tabs.first)
        let other = self.browser()
        let saved = try browser.folders.savePage(url: url, title: "Guide", in: nil)
        let actions: [AddressResult.Action] = [
            .switchTab(.init(id: tab.id, instance: ObjectIdentifier(tab), spaceID: tab.spaceID, profileID: UUID())),
            .switchTab(.init(id: tab.id, instance: ObjectIdentifier(other), spaceID: tab.spaceID, profileID: tab.profileID)),
            .switchTab(.init(id: tab.id, instance: ObjectIdentifier(tab), spaceID: UUID(), profileID: tab.profileID)),
            .openSavedPage(id: UUID(), spaceID: browser.activeSpaceID, kind: .folderPage, url: url),
            .openSavedPage(id: saved.id, spaceID: UUID(), kind: .folderPage, url: url)
        ]
        var reads = 0
        let cache: (URL?) -> Image? = { _ in reads += 1; return Image(nsImage: self.redImage()) }
        for action in actions {
            XCTAssertNil(CommandPaletteFavicon.snapshot(for: result(action, browser), in: browser, cachedIcon: cache))
        }
        XCTAssertNil(CommandPaletteFavicon.snapshot(for: result(.navigate(url), other), in: browser, cachedIcon: cache))
        let stale = result(tabAction(tab), browser)
        browser.closeTab(tab.id)
        XCTAssertNil(CommandPaletteFavicon.snapshot(for: stale, in: browser, cachedIcon: cache))
        browser.windowDidClose()
        XCTAssertNil(CommandPaletteFavicon.snapshot(for: result(.navigate(url), browser), in: browser, cachedIcon: cache))
        XCTAssertEqual(reads, 0)
    }

    func testFallbackSymbolsTintAndImageResetOnCellReuse() throws {
        let browser = browser()
        let reference = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 400))
        let cell = CommandPaletteResultCell()
        let page = result(.navigate(url), browser)
        cell.update(page, selected: true, reference: reference, favicon: redImage())
        XCTAssertTrue(cell.showsFavicon)
        XCTAssertNil(cell.symbol.contentTintColor)
        cell.backgroundStyle = .emphasized
        XCTAssertNil(cell.symbol.contentTintColor, "Selected bitmaps remain untinted")
        try assertRed(try XCTUnwrap(cell.symbol.image))
        let actions: [AddressResult.Action] = [
            .command(.newTab), .switchSpace(.init(id: browser.activeSpaceID, profileID: browser.profileID)),
            .search("Guide"), .navigate(url), .navigate(URL(string: "file:///tmp/page")!)
        ]
        for action in actions {
            let result = result(action, browser)
            if case .navigate(let url) = action, url.scheme == "https" {
                XCTAssertNil(CommandPaletteFavicon.snapshot(for: result, in: browser, cachedIcon: { _ in nil }))
            } else {
                XCTAssertNil(CommandPaletteFavicon.snapshot(for: result, in: browser, cachedIcon: { _ in
                    XCTFail("Non-page icons must not read favicon cache")
                    return nil
                }))
            }
            cell.update(result, selected: false, reference: reference)
            XCTAssertFalse(cell.showsFavicon)
            XCTAssertNotNil(cell.symbol.image)
            XCTAssertNotNil(cell.symbol.contentTintColor)
            XCTAssertEqual(result.symbol, expectedSymbol(action))
        }
        cell.backgroundStyle = .normal
        cell.update(page, selected: false, reference: reference, favicon: redImage())
        XCTAssertNil(cell.symbol.contentTintColor)
        XCTAssertFalse(try XCTUnwrap(cell.symbol.image).isTemplate)
    }

    private func expectedSymbol(_ action: AddressResult.Action) -> String {
        switch action {
        case .command: "command"
        case .switchSpace: "square.grid.2x2"
        case .search: "magnifyingglass"
        default: "globe"
        }
    }

    private func browser(isPrivate: Bool = false) -> BrowserModel {
        BrowserModel(history: HistoryStore(file: nil), websiteDataStore: .nonPersistent(), isPrivate: isPrivate,
                     spaces: BrowserSpaceStore(directory: .temporaryDirectory.appending(path: UUID().uuidString), enabled: false))
    }
    private func result(_ action: AddressResult.Action, _ browser: BrowserModel) -> AddressResult {
        AddressResult(owner: ObjectIdentifier(browser), action: action, title: "Guide", detail: url.absoluteString, destinationSpace: nil)
    }
    private func tabAction(_ tab: BrowserTab) -> AddressResult.Action {
        .switchTab(.init(id: tab.id, instance: ObjectIdentifier(tab), spaceID: tab.spaceID, profileID: tab.profileID))
    }
    private func redImage() -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
    }
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(redImage().tiffRepresentation)))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    private func assertRed(_ image: NSImage) throws {
        XCTAssertFalse(image.isTemplate)
        func sample(_ image: NSImage) throws -> NSColor {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        let color = try sample(image)
        let reference = try sample(redImage())
        XCTAssertGreaterThan(color.redComponent, 0.9)
        // Compare source and output in the same standard space. NSColor.red's
        // colour-managed channels need not be the literal device-RGB (1,0,0).
        XCTAssertEqual(color.redComponent, reference.redComponent, accuracy: 2 / 255)
        XCTAssertEqual(color.greenComponent, reference.greenComponent, accuracy: 2 / 255)
        XCTAssertEqual(color.blueComponent, reference.blueComponent, accuracy: 2 / 255)
        XCTAssertEqual(color.alphaComponent, reference.alphaComponent, accuracy: 2 / 255)
    }
}
