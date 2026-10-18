import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class ToolbarPolishTests: XCTestCase {
    func testExtensionStaysOnRightAfterNativeCustomizationDone() async throws {
        let suite = "ExtensionToolbarPlacement-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(TabLayout.vertical.rawValue, forKey: TabLayout.storageKey)
        let resource = URL.temporaryDirectory.appending(path: "Toolbar Test Extension-\(UUID()).json")
        try Data("[{\"trigger\":{\"url-filter\":\"example.invalid\"},\"action\":{\"type\":\"block\"}}]".utf8).write(to: resource)
        let extensions = BrowserExtensions.shared
        try await extensions.importResources(from: resource)
        let item = try XCTUnwrap(extensions.installed.last)
        let extensionID = NSToolbarItem.Identifier("extension.\(item.id.uuidString)")
        defaults.set(try JSONSerialization.data(withJSONObject: ["identifiers": [extensionID.rawValue, "back", "forward", "address", "downloads"]]), forKey: "toolbarLayout.vertical")
        defer { extensions.remove(item); try? FileManager.default.removeItem(at: resource); defaults.removePersistentDomain(forName: suite) }
        let browser = BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))
        browser.chromePreferences.autoHideToolbar = false
        let window = ToolbarPolishWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                                        styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser, persistsToolbarLayout: true).defaultAppStorage(defaults))
        host.sizingOptions = .minSize
        window.contentViewController = host
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        try await waitUntil {
            window.toolbar?.delegate is ToolbarCustomizationAdapter && window.toolbar?.identifier.hasSuffix(".vertical") == true
                && window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "address" } == true
                && window.toolbar?.itemIdentifiers.first == extensionID
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let beforeEditing = defaults.data(forKey: "toolbarLayout.vertical")
        window.runToolbarCustomizationPalette(nil)
        try await waitUntil { toolbar.customizationPaletteIsRunning }
        // Use AppKit's own reorder action, which updates its customization
        // configuration as a drag does, rather than just changing the item array.
        for expectedIndex in 1..<toolbar.items.count {
            var view = toolbar.items.first(where: { $0.itemIdentifier == extensionID })?.view
            var move: NSAccessibilityCustomAction?
            while let candidate = view, move == nil {
                move = candidate.accessibilityCustomActions()?.first { $0.name == "Move next" }
                view = candidate.superview
            }
            let action = try XCTUnwrap(move)
            if let handler = action.handler { XCTAssertTrue(handler()) }
            else { XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.selector), to: action.target, from: action)) }
            try await waitUntil { toolbar.itemIdentifiers.firstIndex(of: extensionID) == expectedIndex }
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(toolbar.itemIdentifiers.last, extensionID)
        XCTAssertEqual(defaults.data(forKey: "toolbarLayout.vertical"), beforeEditing,
                       "Live customization must not feed AppStorage changes back into SwiftUI")
        func doneButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Done" { return button }
            return view.subviews.lazy.compactMap { doneButton(in: $0) }.first
        }
        let done = try XCTUnwrap(window.attachedSheet?.contentView.flatMap { doneButton(in: $0) })
        done.performClick(nil)
        try await waitUntil { !toolbar.customizationPaletteIsRunning }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(toolbar.itemIdentifiers.last, extensionID)
        XCTAssertGreaterThan(try XCTUnwrap(toolbar.itemIdentifiers.firstIndex(of: extensionID)),
                             try XCTUnwrap(toolbar.itemIdentifiers.firstIndex(of: .init("address"))))
        let stored = try XCTUnwrap(defaults.data(forKey: "toolbarLayout.vertical"))
        let identifiers = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: [String]])["identifiers"]
        XCTAssertEqual(identifiers?.last, extensionID.rawValue)
    }

    func testSavedNativeLayoutSettlesAndWindowVisibilityStaysIndependent() async throws {
        let suite = "PersistedNativeToolbar-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TabLayout.vertical.rawValue, forKey: TabLayout.storageKey)
        let chosen = ["back", "forward", "address", "downloads"]
        defaults.set(try JSONSerialization.data(withJSONObject: ["identifiers": chosen]), forKey: "toolbarLayout.vertical")
        var windows: [NSWindow] = []
        var models: [BrowserModel] = []
        defer { windows.forEach { $0.close() } }
        for _ in 0..<2 {
            let browser = BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))
            browser.chromePreferences.autoHideToolbar = false
            let window = ToolbarPolishWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser, persistsToolbarLayout: true).defaultAppStorage(defaults))
            windows.append(window)
            models.append(browser)
            window.orderBack(nil)
        }
        try await waitUntil { windows.allSatisfy { $0.toolbar?.itemIdentifiers.map(\.rawValue) == chosen } }
        let firstToolbar = try XCTUnwrap(windows[0].toolbar)
        let secondToolbar = try XCTUnwrap(windows[1].toolbar)
        XCTAssertNotEqual(firstToolbar.identifier, secondToolbar.identifier)
        models[0].chromePreferences.autoHideToolbar = true
        try await waitUntil { !firstToolbar.isVisible }
        XCTAssertTrue(secondToolbar.isVisible)
        windows[1].setContentSize(.init(width: 1200, height: 700))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(firstToolbar.itemIdentifiers.map(\.rawValue), chosen)
        XCTAssertEqual(secondToolbar.itemIdentifiers.map(\.rawValue), chosen)
        models[0].chromePreferences.tabLayout = .horizontal
        try await waitUntil { windows[0].toolbarStyle == .expanded && windows[0].toolbar?.isVisible == true }
        XCTAssertEqual(models[1].chromePreferences.tabLayout, .vertical)
        XCTAssertEqual(windows[1].toolbarStyle, .unifiedCompact)
    }

    func testVisibilityIsIndependentBetweenWindowsAndBuildVariants() throws {
        let suite = "ChromeVisibility-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WindowChromePreferences(defaults: defaults, variant: .debug)
        let second = WindowChromePreferences(defaults: defaults, variant: .debug)
        let release = WindowChromePreferences(defaults: defaults, variant: .release)
        first.tabLayout = .vertical
        second.tabLayout = .vertical
        release.tabLayout = .vertical
        first.autoHideToolbar = true
        first.autoHideSidebar = true
        XCTAssertFalse(second.autoHideToolbar)
        XCTAssertFalse(second.autoHideSidebar)
        XCTAssertFalse(release.autoHideToolbar)
        XCTAssertFalse(release.autoHideSidebar)
        XCTAssertTrue(WindowChromePreferences(defaults: defaults, variant: .debug).autoHideToolbar)
        XCTAssertFalse(WindowChromePreferences(defaults: defaults, variant: .release).autoHideToolbar)
        release.autoHideSidebar = true
        second.autoHideToolbar = false
        XCTAssertTrue(first.autoHideToolbar)
        XCTAssertFalse(WindowChromePreferences(defaults: defaults, variant: .debug).autoHideToolbar)
    }

    func testLayoutIsWindowAndBuildSpecificAndHorizontalPreventsAutoHide() throws {
        let suite = "WindowTabLayout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WindowChromePreferences(defaults: defaults, variant: .debug)
        let second = WindowChromePreferences(defaults: defaults, variant: .debug)
        let release = WindowChromePreferences(defaults: defaults, variant: .release)
        first.tabLayout = .vertical
        first.autoHideToolbar = true
        first.autoHideSidebar = true
        XCTAssertEqual(second.tabLayout, .horizontal)
        XCTAssertEqual(release.tabLayout, .horizontal)
        XCTAssertEqual(WindowChromePreferences(defaults: defaults, variant: .debug).tabLayout, .vertical)
        XCTAssertEqual(WindowChromePreferences(defaults: defaults, variant: .release).tabLayout, .horizontal)
        first.tabLayout = .horizontal
        XCTAssertFalse(first.autoHideToolbar)
        XCTAssertFalse(first.autoHideSidebar)
        first.tabLayout = .vertical
        XCTAssertTrue(first.autoHideToolbar)
        XCTAssertTrue(first.autoHideSidebar)
    }

    func testExtensionMetadataExistsBeforeRuntimeLoadsOrFails() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var item = InstalledExtension(id: UUID(), name: "Saved Extension", kind: .webExtension,
                                      filename: "missing-resources", needsNativeMessaging: false)
        item.isEnabled = true
        item.hasToolbarAction = true
        item.toolbarActionLabel = "Open Saved Extension"
        try JSONEncoder().encode([item]).write(to: root.appending(path: "extensions.json"))
        let folder = root.appending(path: item.id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "key", accessibilityDescription: nil))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(icon.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appending(path: "toolbar-icon.png"))
        let store = BrowserExtensions(directory: root, persistent: false)
        XCTAssertEqual(store.toolbarExtensions.map(\.id), [item.id])
        XCTAssertEqual(store.toolbarExtensions.first?.toolbarActionLabel, "Open Saved Extension")
        XCTAssertNotNil(store.toolbarIcon(for: item))
        XCTAssertNil(store.context(for: item))
        await store.restore()
        XCTAssertNotNil(store.errors[item.id])
        XCTAssertEqual(store.toolbarExtensions.map(\.id), [item.id], "Runtime failure must not remove the user's toolbar item")
        XCTAssertNotNil(store.toolbarIcon(for: item))
    }

    func testLayoutSurvivesNewDefaultsAndMissingReturningExtensions() async throws {
        let box = ToolbarDataBox()
        let binding = Binding(get: { box.data }, set: { box.data = $0 })
        let source = PolishToolbarDelegate()
        let toolbar = NSToolbar(identifier: "BrowserToolbar.tests.Polish.\(UUID())")
        let adapter = ToolbarCustomizationAdapter(source: source)
        toolbar.delegate = adapter
        toolbar.itemIdentifiers = [.init("back"), .init("address"), .init("settings"), .init("extension.saved")]
        let persistence = ToolbarLayoutPersistence()
        persistence.update(toolbar: toolbar, binding: binding)
        await Task.yield()
        let chosen: [NSToolbarItem.Identifier] = [.init("back"), .init("divider0"), .space, .init("address"), .flexibleSpace, .init("extension.saved"), .init("divider0")]
        toolbar.itemIdentifiers = chosen
        persistence.userIsEditing = true
        persistence.update(toolbar: toolbar, binding: binding)
        await Task.yield()
        XCTAssertEqual(toolbar.itemIdentifiers, chosen)
        // Dismissing the palette may cause SwiftUI to reconstruct controls in
        // declaration order. That reconstruction must not replace the edit.
        toolbar.itemIdentifiers = [.init("back"), .init("extension.saved"), .init("address"), .init("settings")]
        persistence.update(toolbar: toolbar, binding: binding)
        XCTAssertEqual(toolbar.itemIdentifiers, chosen)
        source.extensionsAvailable = false
        persistence.userIsEditing = true
        persistence.update(toolbar: toolbar, binding: binding)
        await Task.yield()
        let transitionalIDs = try XCTUnwrap(JSONSerialization.jsonObject(with: box.data) as? [String: [String]])["identifiers"]
        XCTAssertEqual(transitionalIDs?.filter { $0 == "extension.saved" }.count, 1)
        toolbar.itemIdentifiers = [.init("back"), .init("address"), .init("settings")]
        persistence.update(toolbar: toolbar, binding: binding)
        XCTAssertEqual(toolbar.itemIdentifiers, chosen.filter { $0.rawValue != "extension.saved" })
        persistence.userIsEditing = true
        persistence.update(toolbar: toolbar, binding: binding)
        await Task.yield()
        source.extensionsAvailable = true
        // A fresh process/window starts from changed application defaults.
        let next = NSToolbar(identifier: "BrowserToolbar.tests.Next.\(UUID())")
        next.delegate = adapter
        next.itemIdentifiers = [.init("settings"), .init("address"), .init("extension.saved")]
        let reopened = ToolbarLayoutPersistence()
        reopened.update(toolbar: next, binding: binding)
        XCTAssertEqual(next.itemIdentifiers, chosen)
        XCTAssertFalse(next.itemIdentifiers.contains(.init("settings")), "Removed defaults must stay removed")
        XCTAssertEqual(adapter.toolbarAllowedItemIdentifiers(next).filter { $0.rawValue.hasPrefix("divider") }.count, 1)
    }

    func testNativePaletteUsesRealSpacesAndOneRepeatableThinDivider() async throws {
        let suite = "ToolbarSpaces-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(TabLayout.vertical.rawValue, forKey: TabLayout.storageKey)
        let browser = BrowserModel(chromePreferences: WindowChromePreferences(defaults: defaults))
        browser.chromePreferences.autoHideToolbar = false
        let window = ToolbarPolishWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser).defaultAppStorage(defaults))
        host.sizingOptions = .minSize
        window.contentViewController = host
        defer { window.close(); defaults.removePersistentDomain(forName: suite) }
        window.orderBack(nil)
        try await waitUntil { window.toolbar?.delegate is ToolbarCustomizationAdapter }
        let toolbar = try XCTUnwrap(window.toolbar)
        let allowed = try XCTUnwrap(toolbar.delegate?.toolbarAllowedItemIdentifiers?(toolbar))
        XCTAssertEqual(allowed.filter { $0 == .space }.count, 1)
        XCTAssertEqual(allowed.filter { $0 == .flexibleSpace }.count, 1)
        XCTAssertEqual(allowed.filter { $0.rawValue.hasPrefix("divider") }.count, 1)
        toolbar.itemIdentifiers = [.init("back"), .space, .init("divider0"), .init("address"), .flexibleSpace, .init("settings"), .init("divider0")]
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(toolbar.itemIdentifiers.filter { $0.rawValue == "divider0" }.count, 2)
        XCTAssertTrue(toolbar.items.filter { $0.itemIdentifier.rawValue == "divider0" }.allSatisfy { $0.view?.fittingSize.width == 1 })
        XCTAssertNil(toolbar.items.first { $0.itemIdentifier == .space }?.view)
        XCTAssertNil(toolbar.items.first { $0.itemIdentifier == .flexibleSpace }?.view)
        let address = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "address" }?.view)
        let settings = try XCTUnwrap(toolbar.items.first { $0.itemIdentifier.rawValue == "settings" }?.view)
        func gap() -> CGFloat { settings.convert(settings.bounds, to: nil).minX - address.convert(address.bounds, to: nil).maxX }
        let narrowGap = gap()
        window.setContentSize(NSSize(width: 1400, height: 700))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(gap(), narrowGap + 50, "Flexible space must grow when the window grows")
        toolbar.itemIdentifiers = [.flexibleSpace, .init("address"), .init("settings")]
        func addressWidth() -> CGFloat { toolbar.items.first { $0.itemIdentifier.rawValue == "address" }?.view?.bounds.width ?? 0 }
        func settledAddressWidth() async throws -> CGFloat {
            var previous: CGFloat = -1
            var stableSamples = 0
            for _ in 0..<50 {
                let width = addressWidth()
                stableSamples = abs(width - previous) < 0.01 ? stableSamples + 1 : 0
                if stableSamples >= 3 { return width }
                previous = width
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Address allocation did not settle")
            return previous
        }
        window.setContentSize(NSSize(width: 1000, height: 700))
        try await waitUntil {
            window.frame.width == 1000 && addressWidth() > 0 && addressWidth() < 480
        }
        let before = try await settledAddressWidth()
        window.setContentSize(NSSize(width: 1400, height: 700))
        try await waitUntil { window.frame.width == 1400 && addressWidth() > before + 80 }
        let expanded = try await settledAddressWidth()
        XCTAssertGreaterThan(expanded, before + 80, "Leading flexible space must not collapse the address field")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(addressWidth(), expanded, accuracy: 1, "Spacing must settle without allocation feedback")
    }
}

@MainActor private final class ToolbarDataBox { var data = Data() }
@MainActor private final class ToolbarPolishWindow: NSWindow {
    override func setAccessibilityFrame(_ accessibilityFrame: NSRect) {}
    @available(macOS, deprecated: 10.10)
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {
        guard attribute != .size, attribute != .position else { return }
        super.accessibilitySetValue(value, forAttribute: attribute)
    }
    @available(macOS, deprecated: 10.10)
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        guard attribute != .size, attribute != .position else { return false }
        return super.accessibilityIsAttributeSettable(attribute)
    }
}
@MainActor private final class PolishToolbarDelegate: NSObject, NSToolbarDelegate {
    var extensionsAvailable = true
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("back"), .init("address"), .init("settings"), .init("divider0"), .init("divider1"), .space, .space, .flexibleSpace]
            + (extensionsAvailable ? [.init("extension.saved")] : [])
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.init("back"), .init("address"), .init("settings")] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = NSView(frame: .init(x: 0, y: 0, width: 24, height: 24))
        return item
    }
}
