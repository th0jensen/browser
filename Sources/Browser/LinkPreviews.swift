import AppKit
import Darwin
import ImageIO
import Observation
import SwiftUI
import WebKit

/// Fetches a single public document. No browser cookies, HTTP credentials, script
/// execution, or disk cache. Only the document’s declared preview image is fetched.
actor LinkPreviewFetcher {
    static let shared = LinkPreviewFetcher()
    private let session: URLSession
    private let redirects = PreviewRedirectPolicy()
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
    }

    struct Document: Sendable {
        let text: String
        let imageURL: URL?
    }

    func document(at url: URL) async throws -> Document {
        guard await Self.hasPublicDestination(url) else { throw IntelligenceError.message("This link cannot be previewed.") }
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("text/html,application/xhtml+xml,text/plain;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = response.url, Self.isPublicWebURL(finalURL),
              ["text/html", "application/xhtml+xml", "text/plain"].contains(response.mimeType?.lowercased() ?? "") else {
            throw IntelligenceError.message("The page did not provide readable text. Open the link to view it.")
        }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            if data.count >= 128 * 1024 { break }
            data.append(byte)
        }
        try Task.checkCancellation()
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let text = Self.readableText(html)
        guard text.count >= 100 else { throw IntelligenceError.message("There isn’t enough readable text to preview this page.") }
        return Document(text: String(text.prefix(6500)), imageURL: Self.previewImage(in: html, relativeTo: finalURL))
    }

    /// Decode a bounded thumbnail, never an unbounded full-resolution webpage image.
    func imageData(at url: URL) async throws -> Data? {
        guard await Self.hasPublicDestination(url) else { return nil }
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("image/avif,image/webp,image/*;q=0.8", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = response.url, Self.isPublicWebURL(finalURL),
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= 2 * 1024 * 1024 else { return nil }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2 * 1024 * 1024 else { return nil }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
              ] as CFDictionary), thumbnail.width >= 120, thumbnail.height >= 60 else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    nonisolated static func previewImage(in html: String, relativeTo page: URL) -> URL? {
        // Attribute order and quoting differ across publishers. Never execute HTML.
        guard let tags = try? NSRegularExpression(pattern: "(?is)<meta\\b[^>]*>"),
              let attributes = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return nil }
        var values: [String: String] = [:]
        for match in tags.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            let tag = (html as NSString).substring(with: match.range)
            var attrs: [String: String] = [:]
            for item in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                let key = (tag as NSString).substring(with: item.range(at: 1)).lowercased()
                if let range = (2...4).map({ item.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                    attrs[key] = (tag as NSString).substring(with: range)
                }
            }
            if let key = attrs["property"] ?? attrs["name"], let content = attrs["content"] {
                values[key.lowercased()] = content
            }
        }
        for key in ["og:image:secure_url", "og:image", "twitter:image", "twitter:image:src"] {
            guard let value = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  let url = URL(string: value.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: page)?.absoluteURL,
                  isPublicWebURL(url) else { continue }
            return url
        }
        return nil
    }

    nonisolated static func isPublicWebURL(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".test") else { return false }
        // Avoid local services and numeric/encoded IP hosts on incidental hover.
        if host.contains(":") || host.split(separator: ".").allSatisfy({ UInt($0) != nil }) { return false }
        return host != "localhost"
    }

    /// Hostname syntax alone cannot exclude local services behind a public DNS name.
    /// Resolve off the main actor and check every address before requesting a document,
    /// image, or redirect. URLSession still performs its own DNS lookup for TLS/HTTP.
    nonisolated static func hasPublicDestination(_ url: URL) async -> Bool {
        guard isPublicWebURL(url), let host = url.host() else { return false }
        return await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var addresses: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else { return false }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let address = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address.pointee.ai_addr, address.pointee.ai_addrlen,
                                  &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0,
                      isPublicAddress(String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)) else { return false }
                cursor = address.pointee.ai_next
            }
            return true
        }.value
    }

    nonisolated static func isPublicAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, value, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            let firstByte = bytes[0], secondByte = bytes[1]
            return !(firstByte == 0 || firstByte == 10 || firstByte == 127 || firstByte >= 224 ||
                     (firstByte == 100 && (64...127).contains(secondByte)) ||
                     (firstByte == 169 && secondByte == 254) || (firstByte == 172 && (16...31).contains(secondByte)) ||
                     (firstByte == 192 && (secondByte == 168 || secondByte == 0)) ||
                     (firstByte == 198 && (18...19).contains(secondByte)))
        }
        var ipv6 = in6_addr()
        guard inet_pton(AF_INET6, value, &ipv6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        // Public global unicast only; mapped IPv4, loopback, link-local, ULA and
        // multicast are excluded. Also exclude the documentation prefix.
        return bytes[0] & 0xe0 == 0x20 && Array(bytes.prefix(4)) != [0x20, 0x01, 0x0d, 0xb8]
    }

    nonisolated static func readableText(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "form", "header"] {
            text = text.replacingOccurrences(of: "(?is)<\(tag)\\b[^>]*>.*?</\(tag)\\s*>", with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

private final class PreviewRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        Task {
            let allowed = if let url = request.url { await LinkPreviewFetcher.hasPublicDestination(url) } else { false }
            completionHandler(allowed ? request : nil)
        }
    }
}

@MainActor @Observable
final class LinkPreviewState {
    let id = UUID()
    let url: URL
    var result: LinkSummary?
    var image: NSImage?
    var isKept = false
    var cardWidth: CGFloat = 300
    var contentHeight: CGFloat = 150
    var maximumHeight: CGFloat = 420
    init(url: URL) { self.url = url }

    var contextText: String {
        var parts = [result?.title, result?.summary].compactMap { $0 }.filter { !$0.isEmpty }
        if let points = result?.keyPoints, !points.isEmpty { parts.append(points.map { "• " + $0 }.joined(separator: "\n")) }
        parts.append(url.absoluteString)
        return parts.joined(separator: "\n\n")
    }
}

/// Only detached notes need a window; hover glass lives above the webpage in the
/// source window so the native effect can sample the page without taking focus.
final class LinkPreviewPanel: NSPanel {
    var kept = false
    var closePreview: (() -> Void)?
    var showPreviewMenu: ((NSEvent) -> Void)?
    override var canBecomeKey: Bool { kept }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let showPreviewMenu { showPreviewMenu(event); return }
        super.sendEvent(event)
    }
    override func performClose(_ sender: Any?) { closePreview?() }
    override func cancelOperation(_ sender: Any?) { closePreview?() }
}

/// Each card owns its work and native events. Detaching never transfers a running
/// task to another card, so navigation and subsequent hovers cannot erase a note.
@MainActor
final class LinkPreviewPresentation {
    let state: LinkPreviewState
    private(set) var panel: LinkPreviewPanel?
    private(set) var glass: NSGlassEffectView?
    private(set) var content: NSHostingView<LinkPreviewCard>?
    private(set) var frame = NSRect.zero // Screen coordinates, for either presentation.
    private(set) var isClosed = false
    weak var sourceView: WKWebView?
    private weak var sourceWindow: NSWindow?
    private let anchor: NSRect
    private let openPage: () -> Void
    private let didKeep: (LinkPreviewPresentation) -> Void
    private let didClose: (LinkPreviewPresentation) -> Void
    private let focusNote: (LinkPreviewPanel) -> Void
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var dismissTask: Task<Void, Never>?
    private var pointerInside = false
    private var interactionDepth = 0
    private var isDragging = false
    lazy var actions = PreviewNoteMenuPresenter(preview: self)
    var task: Task<Void, Never>?
    var imageTask: Task<Void, Never>?
    var preparationTimeoutTask: Task<Void, Never>?
    var isPresented: Bool { glass != nil || panel != nil }

    init(url: URL, sourceView: WKWebView, anchor: NSRect, open: @escaping () -> Void,
         didKeep: @escaping (LinkPreviewPresentation) -> Void, didClose: @escaping (LinkPreviewPresentation) -> Void,
         focusNote: @escaping (LinkPreviewPanel) -> Void = { $0.makeKeyAndOrderFront(nil) }) {
        state = LinkPreviewState(url: url)
        self.sourceView = sourceView
        sourceWindow = sourceView.window
        self.anchor = anchor
        openPage = open
        self.didKeep = didKeep
        self.didClose = didClose
        self.focusNote = focusNote
    }

    func beginPreparing() {
        guard !isClosed, observers.isEmpty, let window = sourceWindow else { return }
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSWindow.willMoveNotification, window as AnyObject),
                               (NSWindow.didResizeNotification, window as AnyObject),
                               (NSWindow.willCloseNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            let observer = NotificationCenter.default.addObserver(
                forName: name, object: object, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissIfTransient() }
            }
            observers.append(observer)
        }
    }

    func isAttached(to view: WKWebView) -> Bool {
        sourceView === view && sourceWindow === view.window
    }

    func show() {
        guard !isClosed, !isPresented else { return }
        preparationTimeoutTask?.cancel()
        preparationTimeoutTask = nil
        guard let window = sourceWindow, let root = window.contentView else { close(); return }
        beginPreparing()
        let content = NSHostingView(rootView: LinkPreviewCard(preview: self))
        content.focusRingType = .none
        self.content = content
        let glass = NSGlassEffectView()
        // Regular glass adapts the hosted semantic text and background together.
        // Clear glass has no adaptive legibility treatment over busy webpages.
        glass.style = .regular
        glass.tintColor = NSColor.black.withAlphaComponent(0.24)
        glass.cornerRadius = 16
        glass.focusRingType = .none
        glass.contentView = content
        self.glass = glass
        // A separate NSPanel cannot reliably refract pixels from WKWebView in
        // another window. Keep the transient effect in the page's view hierarchy.
        root.addSubview(glass, positioned: .above, relativeTo: nil)
        resize(height: state.contentHeight)
        guard !isClosed else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self, !self.isClosed else { return event }
            if event.type == .keyDown,
               event.window === self.panel || (!self.state.isKept && event.window === self.sourceWindow),
               event.keyCode == 53 || (self.state.isKept && event.window === self.panel && event.charactersIgnoringModifiers == "w" && event.modifierFlags.contains(.command)) {
                self.close(); return nil
            }
            let screenPoint = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            let inCard = event.window === self.glass?.window && self.frame.contains(screenPoint)
            if event.type == .rightMouseDown, inCard {
                self.actions.present(with: event)
                return nil
            }
            guard !self.state.isKept, self.interactionDepth == 0 else { return event }
            if event.type == .mouseMoved {
                if self.containsHoverPoint(NSEvent.mouseLocation) {
                    self.cancelDismiss()
                } else { self.scheduleDismiss() }
            } else if !inCard { self.close() }
            return event
        }
    }

    func open() {
        if !state.isKept { close() }
        openPage()
    }

    func hover(_ inside: Bool) {
        pointerInside = inside
        if inside { cancelDismiss() } else { scheduleDismiss() }
    }

    func cancelDismiss() { dismissTask?.cancel(); dismissTask = nil }

    func scheduleDismiss() {
        guard !state.isKept, interactionDepth == 0, dismissTask == nil else { return }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, let self else { return }
            self.dismissTask = nil
            guard !self.pointerInside, !self.containsHoverPoint(NSEvent.mouseLocation) else { return }
            self.dismissIfTransient()
        }
    }

    /// A small buffer around the link/card and a bridge across the gap let the
    /// pointer travel naturally without keeping unrelated page areas alive.
    func containsHoverPoint(_ point: NSPoint) -> Bool {
        guard !isClosed else { return false }
        if anchor.insetBy(dx: -24, dy: -14).contains(point) || frame.insetBy(dx: -12, dy: -12).contains(point) { return true }
        let left = max(anchor.minX, frame.minX) - 12
        let right = min(anchor.maxX, frame.maxX) + 12
        guard right > left else { return false }
        let bottom = min(anchor.maxY, frame.maxY)
        let top = max(anchor.minY, frame.minY)
        return NSRect(x: left, y: bottom - 12, width: right - left, height: max(0, top - bottom) + 24).contains(point)
    }

    func beginInteraction() { interactionDepth += 1; cancelDismiss() }
    func endInteraction() {
        interactionDepth = max(0, interactionDepth - 1)
        if !state.isKept && sourceWindow?.isKeyWindow != true { dismissIfTransient() }
        else { scheduleDismiss() }
    }
    private func dismissIfTransient() { if !state.isKept && interactionDepth == 0 { close() } }

    /// Called only after a real drag crosses the movement threshold, or explicitly
    /// through Keep as Note. A simple press does not convert a hover into a note.
    func keep() {
        guard !isClosed, !state.isKept, let glass else { return }
        let appearance = glass.effectiveAppearance
        glass.removeFromSuperview()
        let panel = LinkPreviewPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.appearance = appearance
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // Keep the window's alpha shape separate from the glass effect's layer
        // tree. A glass root can leave a square outer edge after becoming key.
        let surface = NSView(frame: NSRect(origin: .zero, size: frame.size))
        surface.focusRingType = .none
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.clear.cgColor
        surface.layer?.cornerRadius = glass.cornerRadius
        surface.layer?.masksToBounds = true
        glass.frame = surface.bounds
        glass.autoresizingMask = [.width, .height]
        surface.addSubview(glass)
        panel.contentView = surface
        panel.closePreview = { [weak self] in self?.close() }
        panel.showPreviewMenu = { [weak self] event in self?.actions.present(with: event) }
        state.isKept = true
        panel.kept = true
        panel.title = state.result?.title ?? state.url.host() ?? "Preview Note"
        cancelDismiss()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.orderFront(nil)
        surface.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        didKeep(self)
        if !isDragging { resize(height: state.contentHeight) }
    }

    func beginDrag() {
        guard !isClosed else { return }
        isDragging = true
        keep()
        guard let panel else { return }
        // The new panel must be key before tracking starts; otherwise glass is
        // rendered with its inactive treatment until the mouse is released.
        focusNote(panel)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    func moveDuringDrag(to origin: NSPoint) {
        guard isDragging, let panel else { return }
        panel.setFrameOrigin(origin)
        frame = panel.frame
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel(); task = nil
        imageTask?.cancel(); imageTask = nil
        preparationTimeoutTask?.cancel(); preparationTimeoutTask = nil
        cancelDismiss()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        glass?.removeFromSuperview()
        glass = nil
        content = nil
        if let previous = panel {
            panel = nil
            previous.parent?.removeChildWindow(previous)
            previous.orderOut(nil)
        }
        didClose(self)
    }

    func resize(height: CGFloat) {
        guard !isClosed, !isDragging, let glass else { return }
        if state.isKept, let panel {
            let visible = (panel.screen?.visibleFrame ?? sourceWindow?.screen?.visibleFrame ?? panel.frame).insetBy(dx: 8, dy: 8)
            state.maximumHeight = min(520, visible.height)
            let height = min(max(height, 106), state.maximumHeight)
            let originX = min(max(panel.frame.minX, visible.minX), visible.maxX - state.cardWidth)
            let originY = min(max(panel.frame.maxY - height, visible.minY), visible.maxY - height)
            panel.setFrame(NSRect(x: originX, y: originY, width: state.cardWidth, height: height), display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.invalidateShadow()
            frame = panel.frame
            return
        }
        guard let sourceView, let window = sourceWindow else { close(); return }
        let visible = window.convertToScreen(sourceView.convert(sourceView.bounds, to: nil))
            .intersection(window.screen?.visibleFrame ?? window.frame).insetBy(dx: 8, dy: 8)
        guard visible.width >= 120, visible.height >= 106 else { close(); return }
        let width = min(300, visible.width)
        let below = max(0, anchor.minY - visible.minY - 24)
        let above = max(0, visible.maxY - anchor.maxY - 24)
        let placeBelow = height <= below || below >= above
        let maximumHeight = max(106, placeBelow ? below : above)
        state.cardWidth = width
        state.maximumHeight = maximumHeight
        let height = min(max(height, 106), maximumHeight)
        let originX = min(max(anchor.minX, visible.minX), visible.maxX - width)
        let preferredY = placeBelow ? anchor.minY - height - 24 : anchor.maxY + 24
        let originY = min(max(preferredY, visible.minY), visible.maxY - height)
        frame = NSRect(x: originX, y: originY, width: width, height: height)
        if let root = glass.superview {
            glass.frame = root.convert(window.convertFromScreen(frame), from: nil)
        }
    }

    func endDrag() {
        isDragging = false
        if let panel { frame = panel.frame }
        resize(height: state.contentHeight)
    }
}

/// Event-driven isolated-world tracking. Kept notes own independent lifetimes;
/// only the current transient preview follows source-page hover/navigation events.
@MainActor
final class LinkPreviewController: NSObject, WKScriptMessageHandler {
    typealias SummaryUpdate = @Sendable (LinkSummary) async -> Void
    typealias StreamingSummaryProvider = @Sendable (URL, SummaryUpdate) async throws -> LinkSummary

    static let shared = LinkPreviewController()
    private static let messageName = "browserLinkPreview"
    private static let world = WKContentWorld.world(name: "BrowserLinkPreviews")
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private let views = NSHashTable<WKWebView>.weakObjects()
    private let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()
    private var enabled = UserDefaults.standard.bool(forKey: BrowserIntelligence.fiveSecondPreviewsKey)
    private let modifierFlags: () -> NSEvent.ModifierFlags
    private let summaryProvider: (@Sendable (URL) async throws -> LinkSummary)?
    private let streamingSummaryProvider: StreamingSummaryProvider?
    private let waitForPreparationDeadline: @Sendable () async throws -> Void
    private var settingsObserver: NSObjectProtocol?
    private(set) var current: LinkPreviewPresentation?
    private var notes: [UUID: LinkPreviewPresentation] = [:]
    private var cache: [URL: (Date, LinkSummary, NSImage?)] = [:]
    var presentedPreview: LinkPreviewState? { current?.isPresented == true ? current?.state : nil }
    var keptNotes: [LinkPreviewState] { notes.values.map(\.state) }

    init(observesSettings: Bool = true,
         modifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
         summaryProvider: (@Sendable (URL) async throws -> LinkSummary)? = nil,
         streamingSummaryProvider: StreamingSummaryProvider? = nil,
         waitForPreparationDeadline: @escaping @Sendable () async throws -> Void = {
             try await Task.sleep(for: .seconds(5))
         }) {
        self.modifierFlags = modifierFlags
        self.summaryProvider = summaryProvider
        self.streamingSummaryProvider = streamingSummaryProvider
        self.waitForPreparationDeadline = waitForPreparationDeadline
        super.init()
        guard observesSettings else { return }
        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setEnabled(UserDefaults.standard.bool(forKey: BrowserIntelligence.fiveSecondPreviewsKey)) }
        }
    }

    func install(in view: WKWebView, tab: BrowserTab) {
        tabs.setObject(tab, forKey: view)
        views.add(view)
        let controller = view.configuration.userContentController
        guard !controllers.contains(controller) else { return }
        controllers.add(controller)
        controller.add(self, contentWorld: Self.world, name: Self.messageName)
        controller.addUserScript(WKUserScript(source: Self.script + "\nwindow.browserSetLinkPreviews(\(enabled));",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
    }

    func setEnabled(_ next: Bool) {
        guard next != enabled else { return }
        enabled = next
        if !next { current?.close(); Array(notes.values).forEach { $0.close() } }
        for controller in controllers.allObjects {
            let others = controller.userScripts.filter { !$0.source.hasPrefix(Self.script) }
            controller.removeAllUserScripts()
            others.forEach { controller.addUserScript($0) }
            controller.addUserScript(WKUserScript(source: Self.script + "\nwindow.browserSetLinkPreviews(\(next));",
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        }
        for view in views.allObjects {
            view.evaluateJavaScript("window.browserSetLinkPreviews?.(\(next))", in: nil, in: Self.world) { _ in }
        }
    }

    func dismiss(for view: WKWebView) { if current?.sourceView === view { current?.close() } }
    func keepPreview() { current?.keep() }
    func closeNote(id: UUID) { notes[id]?.close() }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard enabled, message.frameInfo.isMainFrame, let view = message.webView,
              let body = message.body as? [String: Any] else { return }
        if body["leave"] as? Bool == true {
            if let current, current.sourceView === view {
                if current.isPresented { current.scheduleDismiss() }
                else { current.close() }
            }
            return
        }
        guard modifierFlags().contains(.shift), view.window?.isKeyWindow == true,
              !view.isHiddenOrHasHiddenAncestor,
              summaryProvider != nil || streamingSummaryProvider != nil || BrowserIntelligence.unavailableReason == nil,
              let request = previewRequest(from: body, in: view) else { return }
        present(request, from: view)
    }

    private struct PreviewRequest {
        let url: URL
        let anchor: NSRect
    }

    private func previewRequest(from body: [String: Any], in view: WKWebView) -> PreviewRequest? {
        guard let href = body["url"] as? String, let url = URL(string: href),
              LinkPreviewFetcher.isPublicWebURL(url) else { return nil }
        guard let originX = body["x"] as? Double, let originY = body["y"] as? Double,
              let width = body["width"] as? Double, let height = body["height"] as? Double else { return nil }
        guard [originX, originY, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let localY = view.isFlipped ? originY : view.bounds.height - originY - height
        let anchor = NSRect(x: originX, y: localY, width: width, height: height).intersection(view.bounds)
        return anchor.isEmpty ? nil : PreviewRequest(url: url, anchor: anchor)
    }

    private func present(_ request: PreviewRequest, from view: WKWebView) {
        if current?.state.url == request.url && current?.sourceView === view {
            current?.cancelDismiss()
            return
        }
        current?.close()
        guard let window = view.window else { return }
        let screenAnchor = window.convertToScreen(view.convert(request.anchor, to: nil))
        let tab = tabs.object(forKey: view)
        let preview = LinkPreviewPresentation(url: request.url, sourceView: view, anchor: screenAnchor,
                                              open: { [weak tab] in
            PreviewNoteActions.openPage(request.url, from: tab)
        }, didKeep: { [weak self] note in
            self?.notes[note.state.id] = note
            if self?.current === note { self?.current = nil }
        }, didClose: { [weak self] preview in
            if self?.current === preview { self?.current = nil }
            self?.notes[preview.state.id] = nil
        })
        current = preview
        preview.beginPreparing()
        if let (date, result, image) = cache[request.url], Date().timeIntervalSince(date) < 300 {
            preview.state.result = result
            preview.state.image = image
            preview.show()
        } else {
            startLoading(preview, from: request.url)
        }
    }

    private func startLoading(_ preview: LinkPreviewPresentation, from url: URL) {
        let summarize = summaryProvider
        let streamSummary = streamingSummaryProvider
        let waitForDeadline = waitForPreparationDeadline
        preview.task = Task { [weak self, weak preview] in
            guard let self, let preview, !Task.isCancelled, !preview.isClosed else { return }
            await self.load(preview, from: url, summarize: summarize, streamSummary: streamSummary)
        }
        preview.preparationTimeoutTask = Task { [weak preview] in
            do { try await waitForDeadline() }
            catch { return }
            guard !Task.isCancelled, let preview, !preview.isClosed, !preview.isPresented else { return }
            preview.close()
        }
    }

    private func load(_ preview: LinkPreviewPresentation, from url: URL,
                      summarize: (@Sendable (URL) async throws -> LinkSummary)?,
                      streamSummary: StreamingSummaryProvider?) async {
        defer { preview.task = nil }
        let state = preview.state
        do {
            let result = try await summary(for: preview, url: url, summarize: summarize,
                                           streamSummary: streamSummary) { [weak self, weak preview] partial in
                guard let self, let preview else { return }
                await self.publish(partial, to: preview)
            }
            guard !Task.isCancelled, !preview.isClosed else { return }
            guard isUsable(result) else {
                if !preview.isPresented { preview.close() }
                return
            }
            cacheResult(result, image: state.image, for: url)
            if preview.isPresented {
                state.result = result
                return
            }
            guard await canReveal(preview) else {
                preview.close()
                return
            }
            state.result = result
            preview.show()
        } catch {
            guard !preview.isClosed, !preview.isPresented else { return }
            preview.close()
        }
    }

    private func summary(for preview: LinkPreviewPresentation, url: URL,
                         summarize: (@Sendable (URL) async throws -> LinkSummary)?,
                         streamSummary: StreamingSummaryProvider?,
                         onUpdate: @escaping SummaryUpdate) async throws -> LinkSummary {
        if let streamSummary { return try await streamSummary(url, onUpdate) }
        if let summarize { return try await summarize(url) }
        await LocalIntelligence.shared.prepare(.preview)
        let document = try await LinkPreviewFetcher.shared.document(at: url)
        guard !Task.isCancelled, !preview.isClosed else { throw CancellationError() }
        if let imageURL = document.imageURL { loadImage(imageURL, for: preview, url: url) }
        return try await LocalIntelligence.shared.summarize(text: document.text, url: url, onUpdate: onUpdate)
    }

    private func publish(_ partial: LinkSummary, to preview: LinkPreviewPresentation) async {
        guard !Task.isCancelled, !preview.isClosed, isUsable(partial) else { return }
        if preview.isPresented {
            preview.state.result = partial
            return
        }
        guard await canReveal(preview), !Task.isCancelled, !preview.isClosed else {
            preview.close()
            return
        }
        preview.state.result = partial
        preview.show()
    }

    private func canReveal(_ preview: LinkPreviewPresentation) async -> Bool {
        guard enabled, current === preview, modifierFlags().contains(.shift),
              let view = preview.sourceView, preview.isAttached(to: view), view.window?.isKeyWindow == true,
              !view.isHiddenOrHasHiddenAncestor else { return false }
        // Injected providers are test seams. Production asks the isolated hover
        // tracker again so a queued leave cannot race a completed summary onto screen.
        guard summaryProvider == nil, streamingSummaryProvider == nil else { return true }
        let url = preview.state.url.absoluteString
        guard let encoded = try? JSONSerialization.data(withJSONObject: url, options: .fragmentsAllowed),
              let literal = String(data: encoded, encoding: .utf8) else { return false }
        let active = await withCheckedContinuation { continuation in
            view.evaluateJavaScript("window.browserLinkPreviewIsActive?.(\(literal)) === true",
                                    in: nil, in: Self.world) { result in
                continuation.resume(returning: (try? result.get()) as? Bool == true)
            }
        }
        return active && enabled && current === preview && !preview.isClosed && modifierFlags().contains(.shift)
            && preview.isAttached(to: view) && view.window?.isKeyWindow == true && !view.isHiddenOrHasHiddenAncestor
    }

    private func isUsable(_ result: LinkSummary) -> Bool {
        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary.count >= 20 else { return false }
        let lowercased = summary.lowercased()
        return !["i can't", "i can’t", "i cannot", "i'm unable", "i’m unable",
                  "unable to summarize", "cannot summarize", "not enough information"]
            .contains { lowercased.contains($0) }
    }

    private func loadImage(_ imageURL: URL, for preview: LinkPreviewPresentation, url: URL) {
        preview.imageTask = Task { [weak self, weak preview] in
            guard let preview else { return }
            defer { preview.imageTask = nil }
            guard let data = try? await LinkPreviewFetcher.shared.imageData(at: imageURL),
                  !Task.isCancelled, !preview.isClosed, let image = NSImage(data: data) else { return }
            if !preview.isPresented { preview.state.image = image }
            if let cached = self?.cache[url] { self?.cache[url] = (cached.0, cached.1, image) }
        }
    }

    private func cacheResult(_ result: LinkSummary, image: NSImage?, for url: URL) {
        if cache.count >= 16, let oldest = cache.min(by: { $0.value.0 < $1.value.0 })?.key { cache[oldest] = nil }
        cache[url] = (Date(), result, image)
    }

}

private extension LinkPreviewController {
    static let script = """
    (() => {
      if (window.browserSetLinkPreviews) return;
      let enabled = false, link = null, timer = null, sent = false;
      const post = data => window.webkit.messageHandlers.browserLinkPreview.postMessage(data);
      window.browserLinkPreviewIsActive = href => enabled && sent && !document.hidden && link?.href === href;
      function clear() { clearTimeout(timer); if (sent) post({leave: true}); sent = false; }
      function contentLink(target) {
        const candidate = target.closest?.('a[href]');
        if (!candidate || !candidate.innerText?.trim() || target.closest?.('img,picture,video,canvas,svg')) return null;
        try { return /^https?:$/.test(new URL(candidate.href, location.href).protocol) ? candidate : null; }
        catch { return null; }
      }
      function start() {
        clear(); if (!link) return;
        const candidate = link;
        timer = setTimeout(() => {
          if (link !== candidate || document.hidden) return;
          const r = candidate.getBoundingClientRect();
          post({url: candidate.href, x: r.x, y: r.y, width: r.width, height: r.height}); sent = true;
        }, 450);
      }
      function over(e) {
        if (!e.isTrusted) return;
        const next = contentLink(e.target);
        if (next === link) return;
        clear(); link = next;
        if (link && e.shiftKey) start();
      }
      function out(e) {
        if (!e.isTrusted || !link) return;
        if (!e.relatedTarget || !link.contains(e.relatedTarget)) { clear(); link = null; }
      }
      function key(e) {
        if (e.isTrusted && e.key === 'Escape') { stop(); return; }
        if (e.isTrusted && e.key === 'Shift') {
          if (e.type === 'keydown' && !e.repeat) start(); else if (e.type === 'keyup') clear();
        }
      }
      function stop() { clear(); link = null; }
      window.browserSetLinkPreviews = value => {
        if (enabled === value) return;
        enabled = value;
        const action = value ? 'addEventListener' : 'removeEventListener';
        document[action]('mouseover', over, true); document[action]('mouseout', out, true);
        document[action]('keydown', key, true); document[action]('keyup', key, true);
        document[action]('scroll', stop, true); document[action]('mousedown', stop, true);
        window[action]('blur', stop, true); document[action]('visibilitychange', stop, true);
        if (!value) stop();
      };
    })();
    """
}
