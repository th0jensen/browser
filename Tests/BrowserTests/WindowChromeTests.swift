import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class WindowChromeTests: XCTestCase {
    func testTrafficLightInsetsDoNotDependOnAddressHost() async throws {
        let window = ChromeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "InsetsWithoutAddress")
        toolbar.isVisible = true
        window.toolbar = toolbar
        let chrome = WindowChromeView()
        window.contentView = chrome
        defer { window.close() }
        window.orderBack(nil)
        var positions: [NSWindow.ButtonType: CGFloat] = [:]
        for layout in [TabLayout.vertical, .horizontal, .vertical, .horizontal] {
            chrome.update(layout: layout, tabs: AnyView(EmptyView()))
            try await Task.sleep(for: .milliseconds(100))
            // Simulate AppKit restoring its standard inset while toolbar hosts are rebuilt.
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                button.frame.origin.x -= 8
            }
            chrome.refresh()
            try await Task.sleep(for: .milliseconds(100))
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                let frame = button.convert(button.bounds, to: nil)
                if let previous = positions[type] {
                    XCTAssertEqual(frame.minX, previous, accuracy: 0.5,
                                   "Traffic lights must preserve their inset without an address host")
                }
                positions[type] = frame.minX
                if type == .closeButton {
                    XCTAssertEqual(frame.minX, BrowserChrome.windowControlsLeadingInset(controlHeight: frame.height), accuracy: 0.5)
                }
            }
            // A native relayout can move one control independently of the close button.
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            zoom.frame.origin.x -= 8
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(zoom.convert(zoom.bounds, to: nil).minX, try XCTUnwrap(positions[.zoomButton]), accuracy: 0.5)
            let parent = try XCTUnwrap(zoom.superview)
            parent.setBoundsOrigin(NSPoint(x: parent.bounds.minX + 8, y: parent.bounds.minY))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(zoom.convert(zoom.bounds, to: nil).minX, try XCTUnwrap(positions[.zoomButton]), accuracy: 0.5,
                           "Ancestor movement must also preserve the shared window inset")
        }
    }

    private func assertToolbarCenters(in window: NSWindow, at center: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        for item in window.toolbar?.visibleItems ?? [] {
            guard ![NSToolbarItem.Identifier.space, .flexibleSpace].contains(item.itemIdentifier),
                  !item.itemIdentifier.rawValue.contains("divider"), let view = item.view, let owner = view.window else { continue }
            let frame = window.convertFromScreen(owner.convertToScreen(view.convert(view.bounds, to: nil)))
            XCTAssertEqual(frame.midY, center, accuracy: 1, "Toolbar item \(item.itemIdentifier.rawValue) must share the address field's center",
                           file: file, line: line)
        }
    }

    func testHorizontalTabsStayAboveNativeAddressToolbar() async throws {
        let suite = "BrowserChromeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(TabLayout.horizontal.rawValue, forKey: TabLayout.storageKey)
        let window = ChromeTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        let browser = BrowserModel()
        let host = NSHostingController(rootView:
            BrowserWindow(bookmarks: BookmarkStore(), browser: browser).defaultAppStorage(defaults))
        host.sizingOptions = .minSize
        window.contentViewController = host
        defer { window.close() }
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(300))
        let accessory = try XCTUnwrap(window.titlebarAccessoryViewControllers.first { $0.layoutAttribute == .right })
        let toolbar = try XCTUnwrap(window.toolbar)
        toolbar.autosavesConfiguration = false
        let delegate = try XCTUnwrap(toolbar.delegate)
        let defaultItems = try XCTUnwrap(delegate.toolbarDefaultItemIdentifiers?(toolbar))
        let allowedItems = try XCTUnwrap(delegate.toolbarAllowedItemIdentifiers?(toolbar))
        XCTAssertTrue(allowedItems.contains(.space), "Native palette: \(allowedItems)")
        XCTAssertTrue(allowedItems.contains(.flexibleSpace))
        XCTAssertTrue(allowedItems.contains { $0.rawValue.contains("divider") })
        XCTAssertFalse(defaultItems.contains(.space))
        XCTAssertFalse(defaultItems.contains(.flexibleSpace), "The default must let the address field use spare width")
        XCTAssertFalse(defaultItems.contains { $0.rawValue.contains("divider") })
        let order = toolbar.items.map { $0.itemIdentifier.rawValue }
        for navigation in ["back", "forward", "reload"] {
            XCTAssertLessThan(try XCTUnwrap(order.firstIndex { $0.contains(navigation) }),
                              try XCTUnwrap(order.firstIndex { $0.contains("address") }))
        }
        func alignment(in view: NSView) -> ToolbarFieldAnchorView? {
            (view as? ToolbarFieldAnchorView) ?? view.subviews.lazy.compactMap { alignment(in: $0) }.first
        }
        func tabAnchor(in view: NSView) -> HorizontalTabAnchorView? {
            (view as? HorizontalTabAnchorView) ?? view.subviews.lazy.compactMap { tabAnchor(in: $0) }.first
        }
        var fieldWidths: [CGFloat: CGFloat] = [:]
        var horizontalControlPositions: [NSWindow.ButtonType: CGFloat] = [:]
        for width: CGFloat in [1000, 680, 1400] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(window.frame.width, width, accuracy: 1,
                           "Frame \(window.frame), min \(window.minSize), contentMin \(window.contentMinSize), root fitting \(host.view.fittingSize), accessory \(accessory.view.frame)")
            XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier.rawValue.contains("address") } == true,
                          "The address field must remain visible at width \(width)")
            if width >= 1000 {
                for identifier in ["back", "forward", "reload", "downloads", "settings", "newTab"] {
                    XCTAssertTrue(toolbar.visibleItems?.contains { $0.itemIdentifier.rawValue.contains(identifier) } == true,
                                  "Default control \(identifier) must remain visible at width \(width)")
                }
            }
            let currentAddressItem = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "address" }?.view)
            let address = try XCTUnwrap(alignment(in: currentAddressItem))
            let actualTabs = try XCTUnwrap(tabAnchor(in: XCTUnwrap(window.contentView?.superview)))
            let tabWindow = try XCTUnwrap(actualTabs.window)
            let tabFrame = window.convertFromScreen(tabWindow.convertToScreen(actualTabs.convert(actualTabs.bounds, to: nil)))
            XCTAssertEqual(tabFrame.height, BrowserChrome.tabRowHeight, accuracy: 1)
            XCTAssertLessThanOrEqual(tabFrame.maxY, window.frame.height, "The actual tab strip must not clip at the window's top")
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            let closeFrame = close.convert(close.bounds, to: nil)
            XCTAssertEqual(closeFrame.midY, tabFrame.midY, accuracy: 1)
            XCTAssertEqual(closeFrame.minX, BrowserChrome.windowControlsLeadingInset(controlHeight: closeFrame.height), accuracy: 0.5)
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                let frame = button.convert(button.bounds, to: nil)
                if let previous = horizontalControlPositions[type] { XCTAssertEqual(frame.minX, previous, accuracy: 0.5) }
                horizontalControlPositions[type] = frame.minX
            }
            let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
            XCTAssertEqual(tabFrame.minX - zoom.convert(zoom.bounds, to: nil).maxX, BrowserChrome.edgeInset, accuracy: 0.5)
            let addressFrame = window.convertFromScreen(try XCTUnwrap(address.window).convertToScreen(address.convert(address.bounds, to: nil)))
            fieldWidths[width] = addressFrame.width
            assertToolbarCenters(in: window, at: addressFrame.midY)
            XCTAssertEqual(addressFrame.midY, (tabFrame.minY + window.contentLayoutRect.maxY - BrowserChrome.edgeInset) / 2,
                           accuracy: 1, "The navigation row must have balanced space above and below its glass")
            XCTAssertGreaterThanOrEqual(tabFrame.minY, addressFrame.maxY, "Horizontal tabs must remain above the address field at width \(width)")
            XCTAssertGreaterThan(addressFrame.minX, 0)
            XCTAssertLessThan(addressFrame.maxX, window.frame.width)
        }
        XCTAssertEqual(try XCTUnwrap(fieldWidths[1400]) - XCTUnwrap(fieldWidths[1000]), 400, accuracy: 2,
                       "Address widths \(fieldWidths)")
        window.setContentSize(NSSize(width: 680, height: 700))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(window.frame.width, 680, accuracy: 1,
                       "Resizing must settle; minimum \(window.minSize), content minimum \(window.contentMinSize), accessory \(accessory.view.frame)")
        for _ in 0..<20 { browser.addTab() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(window.frame.width, 680, accuracy: 1, "Opening tabs must not expand a resized window")
        func addressField(in view: NSView) -> AddressField? {
            (view as? AddressField) ?? view.subviews.lazy.compactMap { addressField(in: $0) }.first
        }
        let nativeField = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "address" }?.view.flatMap { addressField(in: $0) })
        let editor = try XCTUnwrap(nativeField.currentEditor(), "New tabs must focus the native address editor")
        XCTAssertTrue(window.firstResponder === editor)
        window.makeFirstResponder(nil)
        browser.requestAddressFocus()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === nativeField.currentEditor(), "Repeated location requests must restore focus")
        defaults.set(TabLayout.vertical.rawValue, forKey: TabLayout.storageKey)
        for autoHide in [false, true] {
            defaults.set(autoHide, forKey: SidebarVisibility.autoHideKey)
            try await Task.sleep(for: .milliseconds(300))
            let currentToolbar = try XCTUnwrap(window.toolbar)
            let item = try XCTUnwrap(currentToolbar.items.first { $0.itemIdentifier.rawValue.contains("address") }?.view)
            let field = try XCTUnwrap(alignment(in: item))
            let frame = window.convertFromScreen(try XCTUnwrap(field.window).convertToScreen(field.convert(field.bounds, to: nil)))
            let expectedCenter = (window.frame.height + window.contentLayoutRect.maxY - BrowserChrome.edgeInset) / 2
            assertToolbarCenters(in: window, at: frame.midY)
            XCTAssertEqual(frame.midY, expectedCenter, accuracy: 1)
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                let button = try XCTUnwrap(window.standardWindowButton(type))
                XCTAssertEqual(button.convert(button.bounds, to: nil).midY, expectedCenter, accuracy: 1,
                               "Window controls must share the navigation row's center")
                XCTAssertEqual(button.convert(button.bounds, to: nil).minX, try XCTUnwrap(horizontalControlPositions[type]), accuracy: 0.5,
                               "Each traffic light must keep its left position in both tab layouts")
            }
            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            let closeFrame = close.convert(close.bounds, to: nil)
            XCTAssertEqual(closeFrame.minX, window.frame.height - closeFrame.maxY, accuracy: 0.5,
                           "Traffic lights must have equal top and leading insets")
            XCTAssertGreaterThan(frame.minX, 0)
            XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
            XCTAssertFalse(window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right })
        }

        defaults.set(TabLayout.horizontal.rawValue, forKey: TabLayout.storageKey)
        try await Task.sleep(for: .milliseconds(300))
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(type))
            XCTAssertEqual(button.convert(button.bounds, to: nil).minX, try XCTUnwrap(horizontalControlPositions[type]), accuracy: 0.5,
                           "Switching back to horizontal tabs must preserve every traffic light's left inset")
        }
        let customizedToolbar = try XCTUnwrap(window.toolbar)
        let source = try XCTUnwrap(customizedToolbar.delegate)
        let originalDefaults = try XCTUnwrap(source.toolbarDefaultItemIdentifiers?(customizedToolbar))
        let divider = try XCTUnwrap(source.toolbarAllowedItemIdentifiers?(customizedToolbar).first { $0.rawValue.contains("divider") })
        customizedToolbar.insertItem(withItemIdentifier: divider, at: customizedToolbar.items.count)
        XCTAssertEqual(source.toolbarDefaultItemIdentifiers?(customizedToolbar), originalDefaults,
                       "Customization must not redefine the app's default set")
        customizedToolbar.itemIdentifiers = originalDefaults
        XCTAssertEqual(customizedToolbar.itemIdentifiers, originalDefaults)
        customizedToolbar.insertItem(withItemIdentifier: .space, at: customizedToolbar.items.count)
        XCTAssertTrue(customizedToolbar.itemIdentifiers.contains(.space))
        customizedToolbar.itemIdentifiers = originalDefaults

    }
}

/// External window managers must not resize this isolated geometry fixture through AX.
@MainActor private final class ChromeTestWindow: NSWindow {
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
