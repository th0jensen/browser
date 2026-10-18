import AppKit
import CoreFoundation
import Darwin
import QuartzCore
import SwiftUI
import WebKit
import XCTest
@testable import Browser

/// Run only with BROWSER_BENCHMARK=1, in Release, using scripts/benchmark.sh.
/// Keep this entire file and colorful.html identical in the baseline and candidate.
@MainActor
final class BrowserPerformanceTests: XCTestCase {
    private let warmups = 3
    private let repetitions = 30
    private var metrics: [[String: Any]] = []
    private var resourceWindows: [[String: Any]] = []
    private var windowInventoryBeforeClosure: [[String: Any]] = []
    private var closedHostWindowCount = 0
    private var outputDirectory: URL!

    func testReleaseBenchmarks() async throws {
        guard ProcessInfo.processInfo.environment["BROWSER_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in benchmark: use scripts/benchmark.sh")
        }
        #if DEBUG
        throw XCTSkip("Performance comparisons require Release configuration")
        #endif
        XCTAssertTrue(BrowserProfile.isTesting)
        XCTAssertFalse(BrowserProfile.websiteDataStore.isPersistent)
        outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserBenchmark-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        print("BROWSER_BENCHMARK_OUTPUT=\(outputDirectory.path)")
        // A partial result remains recoverable if a later phase times out.
        try writeResults(status: "running")
        let suite = "BrowserPerformance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(TabLayout.horizontal.rawValue, forKey: TabLayout.storageKey)
        defaults.set(false, forKey: SidebarVisibility.autoHideKey)
        let browser = BrowserModel(sitePermissions: SitePermissions(), chromePreferences: WindowChromePreferences(defaults: defaults))
        let window = PerformanceWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 760),
                                       styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                       backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // XCTest hosts are not guaranteed activation. Keep the real WebKit drawing area
        // visible above the coordinating app, including when that app uses another Space.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: BrowserWindow(bookmarks: BookmarkStore(defaults: defaults), browser: browser)
            .defaultAppStorage(defaults))
        host.sizingOptions = .minSize
        window.contentViewController = host
        // XCTest may create the app's ordinary SwiftUI window too. Its animated New Tab
        // view would contaminate this fixture's idle CPU, so close only this host's peers.
        windowInventoryBeforeClosure = Self.windowInventory()
        for other in NSApp.windows where other !== window && other.level == .normal {
            other.close()
            closedHostWindowCount += 1
        }
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        defer {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        }
        do {
            try await settle(window: window, browser: browser) {
                window.toolbar != nil && browser.window === window && window.occlusionState.contains(.visible)
            }
            print("BENCHMARK_WINDOW_PROTOCOL=floating/allSpaces/fullScreenAuxiliary level=\(window.level.rawValue) occlusion=\(window.occlusionState.rawValue) visible=\(window.occlusionState.contains(.visible)) key=\(window.isKeyWindow) appActive=\(NSApp.isActive) activationPolicy=\(NSApp.activationPolicy().rawValue) appRunning=\(NSApp.isRunning) onActiveSpace=\(window.isOnActiveSpace) windowNumber=\(window.windowNumber)")
            window.toolbar?.autosavesConfiguration = false
            window.makeFirstResponder(nil) // Stop the editor caret during idle windows.
            if ProcessInfo.processInfo.environment["BROWSER_BENCHMARK_MODE"] == "reveal" {
                let tab = try XCTUnwrap(browser.activeTab)
                let bridge = PerformanceScriptBridge()
                try await prepare(tab, bridge: bridge, window: window, browser: browser)
                try await loadFixture(tab, bridge: bridge, token: UUID().uuidString)
                try await benchmarkChromeReveal(window: window, browser: browser, defaults: defaults)
                try writeResults(status: "complete")
                return
            }
            resourceWindows.append(try await idleResources(name: "new_tab", seconds: 30))
            try writeResults(status: "running")

            print("BENCHMARK_PHASE=prepare_first")
            let first = try XCTUnwrap(browser.activeTab)
            let bridge = PerformanceScriptBridge()
            try await prepare(first, bridge: bridge, window: window, browser: browser)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.setContentSize(NSSize(width: 1100, height: 760))
            print("BENCHMARK_PHASE=load_first windowVisible=\(window.isVisible) occlusion=\(window.occlusionState.rawValue) appHidden=\(NSApp.isHidden) appActive=\(NSApp.isActive) frame=\(window.frame) webHidden=\(first.webView?.isHiddenOrHasHiddenAncestor == true)")
            try await loadFixture(first, bridge: bridge, token: UUID().uuidString)
            print("BENCHMARK_PHASE=static_idle")
            try await settle(window: window, browser: browser)
            window.makeFirstResponder(nil)
            resourceWindows.append(try await idleResources(name: "static_color_page", seconds: 30))
            try writeResults(status: "running")
            try await saveScreenshot(webView: XCTUnwrap(first.webView), name: "colorful-horizontal-page")

            try await sample("local_html_load", definition:
                "Host monotonic time from WKWebView.loadHTMLString to script-message delivery after window load and two requestAnimationFrame callbacks; warm WebKit process; local embedded HTML; no network.") {
                let start = Self.now()
                let end = try await self.loadFixture(first, bridge: bridge, token: UUID().uuidString)
                return end - start
            }

            for target in [TabLayout.vertical, .horizontal] {
                try await sample("layout_to_\(target.rawValue)", definition:
                    "Defaults mutation to requested native tab accessory state and selected native/presentation frames stable (0.25 pt quantization) for three display callbacks. Includes display-frame quantization; does not prove final GPU presentation.") {
                    browser.chromePreferences.tabLayout = target.toggled
                    try await self.settle(window: window, browser: browser) { Self.layoutInstalled(target.toggled, in: window) }
                    let start = Self.now()
                    browser.chromePreferences.tabLayout = target
                    try await self.settle(window: window, browser: browser) { Self.layoutInstalled(target, in: window) }
                    return Self.now() - start
                }
            }
            browser.chromePreferences.tabLayout = .vertical
            try await settle(window: window, browser: browser) { Self.layoutInstalled(.vertical, in: window) }
            try await saveScreenshot(webView: XCTUnwrap(first.webView), name: "colorful-vertical-page")
            browser.chromePreferences.tabLayout = .horizontal
            try await settle(window: window, browser: browser) { Self.layoutInstalled(.horizontal, in: window) }

            browser.addTab(focusAddress: false)
            let second = try XCTUnwrap(browser.activeTab)
            try await prepare(second, bridge: bridge, window: window, browser: browser)
            try await loadFixture(second, bridge: bridge, token: UUID().uuidString)
            try await settle(window: window, browser: browser)
            let probes = [first.id: PerformanceAttachmentProbe(), second.id: PerformanceAttachmentProbe()]
            for tab in [first, second] {
                let probe = try XCTUnwrap(probes[tab.id])
                probe.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
                probe.isHidden = true
                tab.contentView.addSubview(probe)
            }
            try await sample("warm_tab_attachment", definition:
                "activeTabID assignment to target page's test-only child viewDidMoveToWindow callback with target contentView attached to the benchmark window. Alternates two already-loaded live tabs; excludes later paint and thumbnail completion.") {
                let target = browser.activeTabID == first.id ? second : first
                let event = PerformanceEvent()
                let probe = try XCTUnwrap(probes[target.id])
                probe.moved = {
                    if probe.window === window && target.contentView.window === window { event.finish() }
                }
                let start = Self.now()
                browser.activeTabID = target.id
                let end = try await event.wait()
                probe.moved = nil
                try await self.settle(window: window, browser: browser)
                return end - start
            }

            try await sample("new_tab_address_focus", definition:
                "BrowserModel.addTab to the first CFRunLoopObserver.beforeWaiting event observing the new tab selected, a newer address-focus request, and native AddressField.currentEditor identical to window.firstResponder. Previous editing ended before the operation. No simulated input or timed polling; closes each new tab outside the measured interval.") {
                window.makeFirstResponder(nil)
                let previousField = try XCTUnwrap(Self.addressField(in: window))
                guard previousField.currentEditor() == nil else {
                    throw PerformanceFailure.system("Previous address editing did not end before the new-tab sample")
                }
                let previousID = browser.activeTabID
                let previousRequest = browser.addressFocusRequest
                var created: UUID?
                let monitor = PerformanceRunLoopMonitor {
                    guard let created, created != previousID, browser.activeTabID == created,
                          browser.activeTab?.isNewTab == true, browser.addressFocusRequest > previousRequest,
                          let field = Self.addressField(in: window), field.window === window,
                          let editor = field.currentEditor() else { return false }
                    return window.firstResponder === editor
                }
                defer { monitor.stop() }
                let start = Self.now()
                browser.addTab()
                created = try XCTUnwrap(browser.activeTabID)
                let end = try await monitor.event.wait()
                browser.closeTab(try XCTUnwrap(created))
                try await self.settle(window: window, browser: browser)
                return end - start
            }

            browser.activeTabID = first.id
            try await settle(window: window, browser: browser)
            let webView = try XCTUnwrap(first.webView)
            webView.postsFrameChangedNotifications = true
            var nativeResizeSamples: [Double] = []
            var resizeIndex = 0
            try await sample("resize_dom_ack", definition:
                "NSWindow.setContentSize to script-message delivery after DOM resize plus two requestAnimationFrame callbacks, with CSS viewport matching current native WKWebView bounds to within 1 pt. Alternates 1000x700 and 1180x780 content sizes; includes IPC and frame quantization.") {
                let token = UUID().uuidString
                _ = try await webView.evaluateJavaScript("window.__resizeToken = '\(token)'")
                let nativeEvent = PerformanceEvent()
                let domEvent = PerformanceEvent()
                bridge.callbacks[token] = { body in
                    guard body["kind"] as? String == "resize",
                          let width = body["width"] as? Double, let height = body["height"] as? Double,
                          abs(width - webView.bounds.width) <= 1, abs(height - webView.bounds.height) <= 1 else { return }
                    domEvent.finish()
                }
                let observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                                      object: webView, queue: .main) { _ in
                    MainActor.assumeIsolated { nativeEvent.finish() }
                }
                defer {
                    NotificationCenter.default.removeObserver(observer)
                    bridge.callbacks[token] = nil
                }
                let start = Self.now()
                window.setContentSize(resizeIndex.isMultiple(of: 2) ? NSSize(width: 1000, height: 700) : NSSize(width: 1180, height: 780))
                let nativeEnd = try await nativeEvent.wait()
                let domEnd = try await domEvent.wait()
                if resizeIndex >= self.warmups { nativeResizeSamples.append((nativeEnd - start) * 1000) }
                resizeIndex += 1
                return domEnd - start
            }
            appendMetric("resize_native_frame", definition:
                "Same resize operations as resize_dom_ack; NSWindow.setContentSize to first WKWebView NSView.frameDidChangeNotification. Native geometry acknowledgement only; no claim about web content paint.", samples: nativeResizeSamples)
            try await benchmarkChromeReveal(window: window, browser: browser, defaults: defaults)
            try writeResults(status: "complete")
        } catch {
            try? writeResults(status: "failed: \(error)")
            throw error
        }
    }

    private func prepare(_ tab: BrowserTab, bridge: PerformanceScriptBridge, window: NSWindow, browser: BrowserModel) async throws {
        tab.isNewTab = false
        tab.restore()
        let webView = try XCTUnwrap(tab.webView)
        XCTAssertFalse(webView.configuration.websiteDataStore.isPersistent)
        webView.configuration.userContentController.add(bridge, name: "browserBenchmark")
        try await settle(window: window, browser: browser) { tab.contentView.window === window && webView.bounds.width > 0 }
    }

    @discardableResult
    private func loadFixture(_ tab: BrowserTab, bridge: PerformanceScriptBridge, token: String) async throws -> Double {
        let event = PerformanceEvent()
        let webView = try XCTUnwrap(tab.webView)
        guard let window = webView.window, window.occlusionState.contains(.visible), !webView.isHiddenOrHasHiddenAncestor else {
            throw PerformanceFailure.system("Local HTML requires an unoccluded native WebKit view; no hidden-page timing fallback")
        }
        bridge.callbacks[token] = { body in
            if body["kind"] as? String == "ready" { event.finish() }
        }
        defer { bridge.callbacks[token] = nil }
        webView.loadHTMLString(Self.fixture.replacingOccurrences(of: "__BENCHMARK_TOKEN__", with: token),
                               baseURL: URL(string: "file:///browser-performance-fixture/"))
        let end: Double
        do { end = try await event.wait() }
        catch {
            let diagnostic = try? await webView.evaluateJavaScript("JSON.stringify({ ready: window.__benchmarkReady, state: document.readyState, visibility: document.visibilityState, width: innerWidth, height: innerHeight, token: typeof benchmarkToken === 'undefined' ? null : benchmarkToken, handlers: !!window.webkit?.messageHandlers?.browserBenchmark })")
            print("BENCHMARK_LOAD_TIMEOUT url=\(String(describing: webView.url)) loading=\(webView.isLoading) frame=\(webView.frame) diagnostic=\(String(describing: diagnostic))")
            throw error
        }
        let ready = try await webView.evaluateJavaScript("window.__benchmarkReady === true")
        XCTAssertEqual(ready as? Bool, true)
        return end
    }

    private func sample(_ name: String, definition: String, operation: () async throws -> Double) async throws {
        var values: [Double] = []
        for index in 0..<(warmups + repetitions) {
            let seconds = try await operation()
            if index >= warmups { values.append(seconds * 1000) }
        }
        appendMetric(name, definition: definition, samples: values)
        try writeResults(status: "running")
    }

    private func appendMetric(_ name: String, definition: String, samples: [Double]) {
        let sorted = samples.sorted()
        metrics.append(["name": name, "definition": definition, "unit": "ms", "samples": samples,
                        "count": samples.count, "warmups_discarded": warmups,
                        "median": (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2,
                        "p90": sorted[Int(ceil(Double(sorted.count) * 0.9)) - 1]])
    }

    private func settle(window: NSWindow, browser: BrowserModel, condition: @escaping @MainActor () -> Bool = { true }) async throws {
        let monitor = PerformanceDisplayMonitor(window: window) {
            guard condition(), let content = window.contentView else { return nil }
            var views = [content, browser.activeTab?.contentView].compactMap { $0 }
            views += window.toolbar?.items.compactMap(\.view) ?? []
            views += window.titlebarAccessoryViewControllers.map(\.view)
            return views.map { view in
                let rect = view.convert(view.bounds, to: nil)
                let presentation = view.layer?.presentation()?.frame ?? view.frame
                return [rect.minX, rect.minY, rect.width, rect.height,
                        presentation.minX, presentation.minY, presentation.width, presentation.height]
                    .map { Int(($0 * 4).rounded()) }.map(String.init).joined(separator: ",")
            }.joined(separator: ";")
        }
        defer { monitor.stop() }
        _ = try await monitor.event.wait()
    }

    private static func layoutInstalled(_ layout: TabLayout, in window: NSWindow) -> Bool {
        let hasTabs = window.titlebarAccessoryViewControllers.contains { $0.layoutAttribute == .right }
        return window.toolbar != nil && hasTabs == (layout == .horizontal)
    }

    private func idleResources(name: String, seconds: Double) async throws -> [String: Any] {
        // Delay is a fixed idle measurement window, never a latency completion detector.
        try await Task.sleep(for: .seconds(1))
        let before = try Self.resources()
        let start = Self.now()
        try writeResourcePhase(name: name, started: start, duration: seconds, status: "sampling")
        try await Task.sleep(for: .seconds(seconds))
        let end = Self.now()
        let after = try Self.resources()
        try writeResourcePhase(name: name, started: start, duration: seconds, status: "complete", ended: end)
        let cpu = after.cpu - before.cpu
        return ["name": name, "requested_wall_seconds": seconds, "actual_wall_seconds": end - start,
                "cpu_seconds": cpu, "cpu_percent_one_core": cpu / (end - start) * 100,
                "rss_before_bytes": before.rss, "rss_after_bytes": after.rss,
                "rss_delta_bytes": Int64(after.rss) - Int64(before.rss),
                "window_inventory": Self.windowInventory(), "screen_inventory": Self.screenInventory(),
                "definition": "Host process getrusage(RUSAGE_SELF) user+system CPU delta and task_info(MACH_TASK_BASIC_INFO) resident_size endpoints. 1 s quiet period, then 30 s idle. RSS endpoints are not peak memory. XCTest is included; other normal host windows were closed before measurement. WebKit subprocesses are excluded. A resource-phase.json marker supports a separate external registered-service cohort sample during the middle of this interval."]
    }

    private func benchmarkChromeReveal(window: NSWindow, browser: BrowserModel, defaults: UserDefaults) async throws {
        print("BENCHMARK_PHASE=chrome_reveal")
        window.makeFirstResponder(nil)
        browser.chromePreferences.tabLayout = .vertical
        browser.chromePreferences.autoHideSidebar = true
        browser.chromePreferences.autoHideToolbar = true
        window.setContentSize(NSSize(width: 1100, height: 760))
        try await settle(window: window, browser: browser) { Self.layoutInstalled(.vertical, in: window) }
        let root = try XCTUnwrap(window.contentView)
        let tracker = try XCTUnwrap(Self.firstView(in: root) { $0 is ChromePointerTracker } as? ChromePointerTracker)
        guard tracker.window === window, tracker.onMove != nil else { throw PerformanceFailure.system("Native pointer tracker is not attached") }
        // End any focus latch through the actual page responder, then use the production
        // tracker callback. Only the OS event queue preceding this callback is excluded.
        if let page = browser.activeTab?.webView { window.makeFirstResponder(page) }
        for region in ["toolbar", "sidebar"] {
            var firstVisible: [Double] = []
            var fullyVisible: [Double] = []
            for index in 0..<(warmups + repetitions) {
                tracker.onMove?(CGPoint(x: 800, y: 400))
                let hidden = PerformanceDisplayMonitor(window: window) {
                    guard Self.toolbarPresentation(in: window, requiringToolbarVisible: false) == nil,
                          Self.sidebarPresentation(in: window) == nil else { return nil }
                    return "both-native-regions-hidden"
                }
                do { _ = try await hidden.event.wait() }
                catch {
                    hidden.stop()
                    print("BENCHMARK_REVEAL_HIDE_TIMEOUT region=\(region) \(Self.revealDiagnostics(in: window))")
                    throw error
                }
                hidden.stop()
                let monitor = PerformanceRevealMonitor(window: window) {
                    region == "toolbar" ? Self.toolbarPresentation(in: window) : Self.sidebarPresentation(in: window)
                }
                let start = Self.now()
                tracker.onMove?(region == "toolbar" ? CGPoint(x: 500, y: 1) : CGPoint(x: 1, y: 200))
                let first: Double
                let full: Double
                do {
                    first = try await monitor.firstVisible.wait()
                    full = try await monitor.fullyVisible.wait()
                } catch {
                    monitor.stop()
                    print("BENCHMARK_REVEAL_VISIBLE_TIMEOUT region=\(region) \(Self.revealDiagnostics(in: window))")
                    throw error
                }
                monitor.stop()
                if index >= warmups {
                    firstVisible.append((first - start) * 1000)
                    fullyVisible.append((full - start) * 1000)
                }
                if region == "toolbar" {
                    XCTAssertNil(Self.sidebarPresentation(in: window), "The top edge must reveal only the toolbar")
                } else {
                    XCTAssertNil(Self.toolbarPresentation(in: window), "The left edge must reveal only the floating sidebar")
                }
            }
            appendMetric("\(region)_reveal_first_visible", definition:
                "Windowed compact chrome, vertical auto-hide sidebar, live local page. Host monotonic time from the attached production ChromePointerTracker.onMove edge callback to first display callback observing a committed presentation layer for the actual native address field (toolbar) or passive native floating-sidebar geometry anchor intersecting the benchmark window by >1 pt with inherited presentation opacity >0.01. Native toolbar visibility also required for toolbar. Excludes OS input dispatch before the production callback; includes display-frame quantization; does not prove GPU pixels presented. Each sample starts after outside-pointer handling and three display callbacks observing both native regions hidden; the toolbar hide probe ignores NSToolbar.isVisible and inspects actual native attachment/visibility/presentation geometry.", samples: firstVisible)
            appendMetric("\(region)_reveal_fully_visible", definition:
                "Same operations as first-visible reveal; completion requires inherited presentation opacity >=0.99, >=99% of native geometry inside the window, native/presentation geometry within 0.5 pt, and presentation frame stable at 0.25 pt quantization for three display callbacks. Fullscreen is not measured. No model visibility Boolean is used as completion.", samples: fullyVisible)
            try writeResults(status: "running")
        }
        tracker.onMove?(CGPoint(x: 800, y: 400))
    }

    private static func firstView(in view: NSView, matching condition: (NSView) -> Bool) -> NSView? {
        if condition(view) { return view }
        for child in view.subviews {
            if let match = firstView(in: child, matching: condition) { return match }
        }
        return nil
    }

    private static func revealDiagnostics(in window: NSWindow) -> String {
        let marker = window.contentView.flatMap { firstView(in: $0) { $0.identifier?.rawValue == "BrowserFloatingSidebarGeometry" } }
        return ["toolbarIsVisible=\(window.toolbar?.isVisible == true)", "occlusion=\(window.occlusionState.rawValue)",
                "field=\(String(describing: addressField(in: window)))", "fieldPresentation=\(addressField(in: window)?.layer?.presentation() != nil)",
                "marker=\(String(describing: marker))", "markerHidden=\(marker?.isHiddenOrHasHiddenAncestor == true)",
                "markerAlpha=\(String(describing: marker?.alphaValue))", "markerPresentation=\(marker?.layer?.presentation() != nil)",
                "rootPresentation=\(window.contentView?.superview?.layer?.presentation() != nil)"].joined(separator: " ")
    }

    private static func toolbarPresentation(in window: NSWindow, requiringToolbarVisible: Bool = true) -> PerformancePresentation? {
        if requiringToolbarVisible && window.toolbar?.isVisible != true { return nil }
        guard let field = addressField(in: window) else { return nil }
        return presentation(of: field, inside: window)
    }

    private static func sidebarPresentation(in window: NSWindow) -> PerformancePresentation? {
        guard let root = window.contentView,
              let anchor = firstView(in: root, matching: { $0.identifier?.rawValue == "BrowserFloatingSidebarGeometry" }) else { return nil }
        return presentation(of: anchor, inside: window)
    }

    private static func presentation(of view: NSView, inside window: NSWindow) -> PerformancePresentation? {
        guard let owner = view.window, owner.isVisible, owner.occlusionState.contains(.visible), !view.isHiddenOrHasHiddenAncestor,
              window.occlusionState.contains(.visible), view.bounds.width > 1, view.bounds.height > 1 else { return nil }
        let nativeRect = owner.convertToScreen(view.convert(view.bounds, to: nil))
        guard let root = owner.contentView?.superview,
              let shown = view.layer?.presentation(), let rootShown = root.layer?.presentation() else { return nil }
        let shownRect = owner.convertToScreen(root.convert(shown.convert(shown.bounds, to: rootShown), to: nil))
        var opacity: Float = 1
        var layer: CALayer? = shown
        while let current = layer { opacity *= current.opacity; layer = current.superlayer }
        let intersection = shownRect.intersection(window.frame)
        guard !intersection.isNull, intersection.width > 1, intersection.height > 1, opacity > 0.01 else { return nil }
        let full = opacity >= 0.99 && intersection.width >= shownRect.width * 0.99 && intersection.height >= shownRect.height * 0.99
            && abs(shownRect.minX - nativeRect.minX) <= 0.5 && abs(shownRect.minY - nativeRect.minY) <= 0.5
            && abs(shownRect.width - nativeRect.width) <= 0.5 && abs(shownRect.height - nativeRect.height) <= 0.5
        let signature = [shownRect.minX, shownRect.minY, shownRect.width, shownRect.height]
            .map { Int(($0 * 4).rounded()) }.map(String.init).joined(separator: ",")
        return PerformancePresentation(fullyVisible: full, signature: signature)
    }

    private func writeResourcePhase(name: String, started: Double, duration: Double, status: String, ended: Double? = nil) throws {
        var phase: [String: Any] = ["name": name, "pid": ProcessInfo.processInfo.processIdentifier,
                                    "startedUptime": started, "duration": duration, "status": status]
        if let ended { phase["endedUptime"] = ended }
        let data = try JSONSerialization.data(withJSONObject: phase, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("resource-phase.json"), options: .atomic)
        print("BENCHMARK_RESOURCE_PHASE=\(name) status=\(status) startedUptime=\(started) duration=\(duration)")
    }

    private static func addressField(in window: NSWindow) -> AddressField? {
        func find(_ view: NSView) -> AddressField? {
            (view as? AddressField) ?? view.subviews.lazy.compactMap { find($0) }.first
        }
        return window.toolbar?.items.lazy.compactMap { $0.view.flatMap { find($0) } }.first
    }

    private static func windowInventory() -> [[String: Any]] {
        NSApp.windows.map { window in
            ["class": String(describing: type(of: window)), "number": window.windowNumber,
             "level": window.level.rawValue, "frame": NSStringFromRect(window.frame),
             "visible": window.isVisible, "occlusion_state": window.occlusionState.rawValue,
             "unoccluded": window.occlusionState.contains(.visible), "key": window.isKeyWindow,
             "miniaturized": window.isMiniaturized, "on_active_space": window.isOnActiveSpace,
             "appearance": window.effectiveAppearance.name.rawValue,
             "backing_scale": window.backingScaleFactor,
             "screen_name": window.screen?.localizedName ?? "none"]
        }
    }

    private static func screenInventory() -> [[String: Any]] {
        NSScreen.screens.map { screen in
            ["name": screen.localizedName, "frame": NSStringFromRect(screen.frame),
             "visible_frame": NSStringFromRect(screen.visibleFrame), "backing_scale": screen.backingScaleFactor,
             "display_id": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
             "maximum_frames_per_second": screen.maximumFramesPerSecond,
             "minimum_refresh_interval_seconds": screen.minimumRefreshInterval,
             "maximum_refresh_interval_seconds": screen.maximumRefreshInterval]
        }
    }

    private static func resources() throws -> (cpu: Double, rss: UInt64) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw PerformanceFailure.system("getrusage") }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw PerformanceFailure.system("task_info: \(result)") }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return (seconds(usage.ru_utime) + seconds(usage.ru_stime), info.resident_size)
    }

    private func saveScreenshot(webView: WKWebView, name: String) async throws {
        // WebKit snapshots include its remote rendered content; NSView.cacheDisplay may omit those layers.
        // These attachments show the page fixture only. Full application chrome screenshots are external QA.
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "BrowserBenchmarkSnapshot", code: 1))
                }
            }
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = outputDirectory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func writeResults(status: String) throws {
        let result: [String: Any] = [
            "schema": "browser-performance-v1", "status": status,
            "label": ProcessInfo.processInfo.environment["BROWSER_BENCHMARK_LABEL"] ?? "unlabelled",
            "pid": ProcessInfo.processInfo.processIdentifier, "timestamp": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "logical_processor_count": ProcessInfo.processInfo.processorCount,
            "configuration": "Release required; opt-in XCTest host", "warmups": warmups, "repetitions": repetitions,
            "mode": ProcessInfo.processInfo.environment["BROWSER_BENCHMARK_MODE"] ?? "full",
            "window_protocol": "Real NSWindow at floating level; canJoinAllSpaces + fullScreenAuxiliary; orderFrontRegardless; initial and pre-load NSWindow.OcclusionState.visible gates. macOS cooperative app activation may remain false. Same visible-window protocol in baseline and candidate.",
            "window_inventory_before_peer_closure": windowInventoryBeforeClosure,
            "closed_normal_host_window_count": closedHostWindowCount,
            "window_inventory": Self.windowInventory(), "screen_inventory": Self.screenInventory(),
            "application_appearance": NSApp.effectiveAppearance.name.rawValue,
            "application_active": NSApp.isActive,
            "quantiles": "Median averages two middle values for even N; p90 uses nearest rank ceil(0.90*N).",
            "metrics": metrics, "resource_windows": resourceWindows,
            "output_directory": outputDirectory.path,
            "limitations": ["Window created inside the application XCTest host, not full app startup.",
                            "App-only CPU/RSS include XCTest; other normal application host windows were closed. WebKit content/network/GPU processes are excluded.",
                            "Readiness/rAF acknowledgements do not guarantee pixels reached the display; no full-app startup or WebKit memory attribution is claimed.",
                            "Latency observations add test-side notification/display-link/IPC overhead identically in baseline and candidate.",
                            "Floating benchmark window visibility is controlled independently of macOS cooperative app activation; address focus observes the actual native editor at a run-loop beforeWaiting event inside this window.",
                            "Idle windows are one 30-second sample per state, after 1 second quiet; repeat whole runs for confidence."]
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputDirectory.appendingPathComponent("results.json"), options: .atomic)
        try Data(Self.fixture.utf8).write(to: outputDirectory.appendingPathComponent("colorful.html"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "browser-benchmark-\(status == "complete" ? "complete" : "partial").json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    // Embedded so the app sandbox never needs to read the source checkout. Kept byte-identical to Tests/Performance/colorful.html.
    private static let fixture = #"""
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Browser deterministic color fixture</title>
<style>
  * { box-sizing: border-box; }
  html, body { margin: 0; min-height: 100%; font: 16px system-ui; color: #122332; background: #e6f4f5; }
  header { padding: 32px; color: white; background: #2449a4; }
  h1 { margin: 0 0 8px; font-size: 34px; }
  main { display: grid; grid-template-columns: repeat(3, 1fr); gap: 20px; padding: 28px; }
  article { min-height: 220px; padding: 24px; border-radius: 18px; }
  article:nth-child(1) { background: #ffbd59; }
  article:nth-child(2) { background: #ed6a82; }
  article:nth-child(3) { background: #6ed5b7; }
  .band { height: 110px; margin: 0 28px 28px; border-radius: 18px; background: linear-gradient(110deg,#7753c6,#29b6cf); }
  footer { padding: 24px 32px; background: #122332; color: white; }
</style>
<header><h1>Color, ready.</h1>Local content. No network, assets, timers, or animation.</header>
<main>
  <article><h2>Amber</h2><p>Native chrome and page bounds stay easy to distinguish.</p></article>
  <article><h2>Coral</h2><p>A fixed layout makes resize changes visible.</p></article>
  <article><h2>Mint</h2><p>System fonts avoid resource loading variability.</p></article>
</main>
<div class="band"></div>
<footer>Browser performance fixture · static pixels after readiness</footer>
<script>
  const benchmarkToken = "__BENCHMARK_TOKEN__";
  const acknowledge = kind => requestAnimationFrame(() => requestAnimationFrame(() => {
    window.__benchmarkReady = true;
    window.webkit?.messageHandlers?.browserBenchmark?.postMessage({
      kind, token: kind === "resize" ? window.__resizeToken : benchmarkToken,
      width: innerWidth, height: innerHeight
    });
  }));
  addEventListener("load", () => acknowledge("ready"), { once: true });
  addEventListener("resize", () => acknowledge("resize"));
</script>
</html>
"""# + "\n"
}

@MainActor private enum PerformanceFailure: Error {
    case timeout
    case system(String)
}

@MainActor private final class PerformanceEvent {
    private var timestamp: Double?
    private var continuation: CheckedContinuation<Double, Error>?
    func finish() {
        guard timestamp == nil else { return }
        let time = ProcessInfo.processInfo.systemUptime
        timestamp = time
        continuation?.resume(returning: time)
        continuation = nil
    }
    func wait() async throws -> Double {
        if let timestamp { return timestamp }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, let pending = self.continuation else { return }
                self.continuation = nil
                pending.resume(throwing: PerformanceFailure.timeout)
            }
        }
    }
}

@MainActor private final class PerformanceScriptBridge: NSObject, WKScriptMessageHandler {
    var callbacks: [String: ([String: Any]) -> Void] = [:]
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let token = body["token"] as? String else { return }
        callbacks[token]?(body)
    }
}

@MainActor private final class PerformanceAttachmentProbe: NSView {
    var moved: (() -> Void)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moved?() }
}

@MainActor private final class PerformanceRunLoopMonitor {
    let event = PerformanceEvent()
    private var observer: CFRunLoopObserver?
    private let condition: @MainActor () -> Bool
    init(condition: @escaping @MainActor () -> Bool) {
        self.condition = condition
        observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue,
                                                     true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.condition() else { return }
                self.event.finish()
                self.stop()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
    }
    func stop() {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes) }
        observer = nil
    }
}

@MainActor private final class PerformanceDisplayMonitor: NSObject {
    let event = PerformanceEvent()
    private var displayLink: CADisplayLink?
    private let signature: @MainActor () -> String?
    private var previous: String?
    private var stableFrames = 0
    init(window: NSWindow, signature: @escaping @MainActor () -> String?) {
        self.signature = signature
        super.init()
        displayLink = window.displayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }
    @objc private func tick() {
        guard let current = signature() else { stableFrames = 0; previous = nil; return }
        stableFrames = current == previous ? stableFrames + 1 : 1
        previous = current
        if stableFrames >= 3 { event.finish(); stop() }
    }
    func stop() { displayLink?.invalidate(); displayLink = nil }
}

private struct PerformancePresentation {
    let fullyVisible: Bool
    let signature: String
}

@MainActor private final class PerformanceRevealMonitor: NSObject {
    let firstVisible = PerformanceEvent()
    let fullyVisible = PerformanceEvent()
    private var displayLink: CADisplayLink?
    private let sample: @MainActor () -> PerformancePresentation?
    private var previous: String?
    private var stableFrames = 0
    init(window: NSWindow, sample: @escaping @MainActor () -> PerformancePresentation?) {
        self.sample = sample
        super.init()
        displayLink = window.displayLink(target: self, selector: #selector(tick))
        displayLink?.add(to: .main, forMode: .common)
    }
    @objc private func tick() {
        guard let current = sample() else { previous = nil; stableFrames = 0; return }
        firstVisible.finish()
        stableFrames = current.fullyVisible && previous == current.signature ? stableFrames + 1 : (current.fullyVisible ? 1 : 0)
        previous = current.signature
        if stableFrames >= 3 { fullyVisible.finish(); stop() }
    }
    func stop() { displayLink?.invalidate(); displayLink = nil }
}

/// Prevent unrelated external window managers from perturbing this geometry fixture through AX.
@MainActor private final class PerformanceWindow: NSWindow {
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
