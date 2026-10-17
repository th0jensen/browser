import AppKit
import SwiftUI
import XCTest
@testable import Browser

@MainActor
final class WindowChromeRefreshTests: XCTestCase {
    func testUnchangedRefreshDoesNotRepeatNativeWindowAppearanceSetters() {
        let window = AppearanceCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let chrome = WindowChromeView()
        window.contentView = chrome
        defer { window.close() }
        chrome.update(layout: .vertical, tabs: AnyView(EmptyView()))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        let writes = window.appearanceWrites

        for _ in 0..<10 { chrome.refresh() }

        XCTAssertEqual(window.appearanceWrites, writes,
                       "Unchanged chrome refreshes must not trigger AppKit's toolbar reshaping setters")
    }
}

@MainActor private final class AppearanceCountingWindow: NSWindow {
    private var transparentWrites = 0
    private var titleWrites = 0
    private var tabbingWrites = 0
    private var separatorWrites = 0

    var appearanceWrites: [Int] { [transparentWrites, titleWrites, tabbingWrites, separatorWrites] }

    override var titlebarAppearsTransparent: Bool { didSet { transparentWrites += 1 } }
    override var titleVisibility: NSWindow.TitleVisibility { didSet { titleWrites += 1 } }
    override var tabbingMode: NSWindow.TabbingMode { didSet { tabbingWrites += 1 } }
    override var titlebarSeparatorStyle: NSTitlebarSeparatorStyle { didSet { separatorWrites += 1 } }
}
