import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class NativeToolbarCommandTests: XCTestCase {
    func testAdapterRestoresLatestCanonicalHostAndUpdatesActionWithoutReplacingButton() {
        let item = NSToolbarItem(itemIdentifier: .init("reload"))
        let original = NSView()
        item.view = original
        var actions = 0
        let adapter = NativeToolbarCommandAdapter(item: item, command: .init(identifier: "reload", title: "Reload", symbol: "arrow.clockwise", action: { actions += 1 }))
        XCTAssertTrue(item.view === adapter.button)
        let buttonWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        buttonWindow.isReleasedWhenClosed = false
        buttonWindow.contentView = adapter.button
        defer { buttonWindow.close() }
        XCTAssertEqual(adapter.button.intrinsicContentSize, NSSize(width: 24, height: 24))
        XCTAssertTrue(adapter.button.isBordered)
        XCTAssertEqual(adapter.button.bezelStyle, .accessoryBarAction)
        adapter.button.performClick(nil)
        XCTAssertTrue(adapter.button.accessibilityPerformPress())
        XCTAssertEqual(actions, 2)
        let menu = NSMenu(title: "History")
        menu.addItem(withTitle: "Previous Page", action: nil, keyEquivalent: "")
        adapter.update(.init(identifier: "reload", title: "Stop Loading", symbol: "xmark", isEnabled: false,
                             action: { actions += 10 }, menu: { menu }))
        XCTAssertEqual(adapter.button.title, "Stop Loading")
        XCTAssertEqual(adapter.button.imagePosition, .imageOnly)
        XCTAssertNotNil(adapter.button.image)
        XCTAssertEqual(adapter.button.symbol, "xmark")
        XCTAssertTrue(adapter.button.commandMenu() === menu)
        adapter.button.performClick(nil)
        XCTAssertFalse(adapter.button.accessibilityPerformPress())
        XCTAssertEqual(actions, 2)
        let replacementHost = NSView()
        item.view = replacementHost
        adapter.update(.init(identifier: "reload", title: "Reload", symbol: "arrow.clockwise", action: { actions += 10 }))
        XCTAssertTrue(item.view === adapter.button)
        XCTAssertTrue(adapter.originalView === replacementHost)
        adapter.button.performClick(nil)
        XCTAssertEqual(actions, 12)
        adapter.restore()
        XCTAssertTrue(item.view === replacementHost)
    }

    func testSymbolsAreCenteredByTheirAlignmentBounds() throws {
        for symbol in ["chevron.left", "chevron.right", "arrow.clockwise", "plus", "arrow.down.circle"] {
            let button = NativeToolbarCommandButton(command: .init(identifier: symbol, title: symbol, symbol: symbol, action: {}))
            let image = try XCTUnwrap(button.image)
            let rect = try XCTUnwrap(button.cell).imageRect(forBounds: button.bounds)
            XCTAssertEqual(rect.minX + image.alignmentRect.midX, button.bounds.midX, accuracy: 0.001, symbol)
            let centerY = button.isFlipped ? image.size.height - image.alignmentRect.midY : image.alignmentRect.midY
            XCTAssertEqual(rect.minY + centerY, button.bounds.midY, accuracy: 0.001, symbol)
        }
    }

    func testDisplayModesReserveSpaceForTextAndKeepSymbolsInIconMode() {
        let command = NativeToolbarCommand(identifier: "forward", title: "Forward", symbol: "chevron.right", action: {})
        let button = NativeToolbarCommandButton(command: command)
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.intrinsicContentSize, NSSize(width: 24, height: 24))
        button.update(command, displayMode: .labelOnly)
        XCTAssertEqual(button.imagePosition, .noImage)
        XCTAssertGreaterThan(button.intrinsicContentSize.width, 24)
        button.update(command, displayMode: .iconAndLabel)
        XCTAssertEqual(button.imagePosition, .imageAbove)
        XCTAssertGreaterThan(button.intrinsicContentSize.width, 24)
        XCTAssertEqual(button.intrinsicContentSize.height, 42)
        button.update(command, displayMode: .iconOnly)
        XCTAssertEqual(button.imagePosition, .imageOnly)
        XCTAssertEqual(button.intrinsicContentSize, NSSize(width: 24, height: 24))
    }

    func testChromeRestoresCanonicalItemWhenCommandIsRemoved() {
        let delegate = CommandTestToolbarDelegate()
        let toolbar = NSToolbar(identifier: "CommandAdapterTest")
        toolbar.delegate = delegate
        toolbar.insertItem(withItemIdentifier: .init("newTab"), at: 0)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = toolbar
        let chrome = WindowChromeView()
        window.contentView = chrome
        defer { window.close() }
        let item = toolbar.items[0]
        let canonical = item.view
        chrome.setNativeCommands([.init(identifier: "newTab", title: "New Tab", symbol: "plus", action: {})])
        XCTAssertTrue(item.view is NativeToolbarCommandButton)
        XCTAssertTrue(toolbar.delegate === delegate)
        chrome.setNativeCommands([])
        XCTAssertTrue(item.view === canonical)
        XCTAssertTrue(toolbar.delegate === delegate)
        chrome.setNativeCommands([.init(identifier: "newTab", title: "New Tab", symbol: "plus", action: {})])
        XCTAssertTrue(item.view is NativeToolbarCommandButton)
        chrome.detachNativeCommands()
        chrome.refresh()
        XCTAssertTrue(item.view === canonical, "Teardown must release commands and restore the canonical view")
    }

    func testToolbarContextMenuRoutingPreservesPageHistoryAndTextEditing() async throws {
        let suite = "ToolbarContextMenu-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(TabLayout.vertical.rawValue, forKey: TabLayout.storageKey)
        defaults.set(false, forKey: CompactToolbar.storageKey)
        let browser = BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser).defaultAppStorage(defaults))
        defer { window.close(); defaults.removePersistentDomain(forName: suite) }
        window.makeKeyAndOrderFront(nil)
        func findChrome(in view: NSView) -> WindowChromeView? {
            if let chrome = view as? WindowChromeView { return chrome }
            return view.subviews.lazy.compactMap { findChrome(in: $0) }.first
        }
        try await waitUntil { window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "sidebar" && $0.view != nil } == true }
        let chrome = try XCTUnwrap(window.contentView.flatMap { findChrome(in: $0) })
        let toolbar = try XCTUnwrap(window.toolbar)
        let marker = NSMenu(title: "Toolbar behaviors")
        chrome.toolbarContextMenu = { marker }
        func point(_ identifier: String) throws -> NSPoint {
            let view = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == identifier }?.view)
            return view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
        func event(at point: NSPoint, type: NSEvent.EventType = .rightMouseDown,
                   flags: NSEvent.ModifierFlags = [], windowNumber: Int? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                                             timestamp: 0, windowNumber: windowNumber ?? window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        }
        let commandPoint = try point("sidebar")
        XCTAssertTrue(chrome.contextMenu(for: try event(at: commandPoint)) === marker)
        XCTAssertTrue(chrome.contextMenu(for: try event(at: commandPoint, type: .leftMouseDown, flags: .control)) === marker)
        XCTAssertNil(chrome.contextMenu(for: try event(at: commandPoint, type: .leftMouseDown)))
        XCTAssertNil(chrome.contextMenu(for: try event(at: NSPoint(x: 600, y: 200))), "Web content keeps its own menu")
        XCTAssertNil(chrome.contextMenu(for: try event(at: point("back"))), "Navigation keeps its history menu")
        let other = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: .titled, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertNil(chrome.contextMenu(for: try event(at: commandPoint, windowNumber: other.windowNumber)))
        browser.requestAddressFocus()
        try await waitUntil { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        let textPoint = editor.convert(NSPoint(x: editor.visibleRect.midX, y: editor.visibleRect.midY), to: nil)
        XCTAssertNil(chrome.contextMenu(for: try event(at: textPoint)), "Address selection keeps Cut, Copy and Paste")
        chrome.detachNativeCommands()
        XCTAssertNil(chrome.contextMenu(for: try event(at: commandPoint)))
    }

    func testNativeToolbarControlsKeepCustomizationLabels() async throws {
        let suite = "NativeToolbarSymbols-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(TabLayout.horizontal.rawValue, forKey: TabLayout.storageKey)
        defaults.set(false, forKey: CompactToolbar.storageKey)
        let browser = BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser).defaultAppStorage(defaults))
        defer { window.close(); defaults.removePersistentDomain(forName: suite) }
        window.orderBack(nil)
        try await waitUntil { window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "newTab" && $0.label == "New Tab" } == true }
        let originalDelegate = window.toolbar?.delegate
        for (identifier, label) in ["layout": "Tab Layout", "back": "Back", "forward": "Forward",
                                    "reload": "Reload", "newTab": "New Tab", "pins": "Essential Tabs"] {
            let item = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == identifier })
            XCTAssertEqual(item.label, label, "Toolbar label for \(identifier)")
            XCTAssertEqual(item.paletteLabel, label, "Customization palette label for \(identifier)")
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let delegate = try XCTUnwrap(toolbar.delegate)
        XCTAssertTrue(delegate === originalDelegate)
        let reloadItem = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "reload" })
        let reloadButton = try XCTUnwrap(reloadItem.view as? NativeToolbarCommandButton)
        XCTAssertFalse(reloadButton.isEnabled)
        XCTAssertEqual(reloadButton.imagePosition, .imageOnly)
        XCTAssertNotNil(reloadButton.image)
        XCTAssertEqual(reloadButton.bounds.size, NSSize(width: 24, height: 24))
        for item in toolbar.items {
            guard let button = item.view as? NativeToolbarCommandButton else { continue }
            XCTAssertEqual(button.imagePosition, .imageOnly, "The native \(item.itemIdentifier.rawValue) command must not clip text into a symbol-sized view")
            XCTAssertNotNil(button.image)
        }
        let labelPreference = AppStorage(wrappedValue: ToolbarLabelStyle.iconOnly, ChromeCustomization.toolbarLabelStyleKey, store: defaults)
        for style in [ToolbarLabelStyle.titleOnly, .titleAndIcon, .iconOnly] {
            labelPreference.wrappedValue = style
            let mode = style.nativeDisplayMode
            try await waitUntil { reloadButton.displayMode == mode && reloadButton.bounds.width >= reloadButton.intrinsicContentSize.width - 1 }
            XCTAssertTrue(reloadItem.view === reloadButton)
            XCTAssertEqual(reloadButton.imagePosition, mode == .labelOnly ? .noImage : (mode == .iconAndLabel ? .imageAbove : .imageOnly))
        }
        browser.activeTab?.isNewTab = false
        browser.activeTab?.restore()
        browser.activeTab?.webView?.loadHTMLString("<title>Toolbar State</title><p>Loaded</p>", baseURL: URL(string: "https://example.invalid"))
        try await waitUntil { reloadButton.isEnabled }
        XCTAssertTrue(reloadItem.view === reloadButton)
        browser.chromePreferences.tabLayout = .vertical
        try await waitUntil { window.toolbarStyle == .unifiedCompact }
        browser.chromePreferences.tabLayout = .horizontal
        try await waitUntil { window.toolbarStyle == .expanded }
        try await waitUntil { window.toolbar?.items.first { $0.itemIdentifier.rawValue == "reload" }?.view is NativeToolbarCommandButton }
        try await waitUntil {
            window.toolbar?.delegate is ToolbarCustomizationAdapter
                && window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "layout" } == true
                && window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "sidebar" } == false
        }
        let currentToolbar = try XCTUnwrap(window.toolbar)
        let currentDelegate = try XCTUnwrap(currentToolbar.delegate)

        for (identifier, label) in ["sidebar": "Sidebar", "pinSidebar": "Pin Sidebar"] {
            XCTAssertFalse(currentToolbar.items.contains { $0.itemIdentifier.rawValue == identifier })
            let item = try XCTUnwrap(currentDelegate.toolbar?(currentToolbar, itemForItemIdentifier: .init(identifier),
                                                      willBeInsertedIntoToolbar: false))
            XCTAssertEqual(item.label, label, "Hidden customization item label for \(identifier)")
            XCTAssertEqual(item.paletteLabel, label, "Hidden customization palette label for \(identifier)")
        }
    }

}

@MainActor private final class CommandTestToolbarDelegate: NSObject, NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("newTab")] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("newTab")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.view = NSView(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        return item
    }
}
