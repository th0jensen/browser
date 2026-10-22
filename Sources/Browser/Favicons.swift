import AppKit
import Darwin
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// An icon a page declares with `<link rel="icon">` or `<link rel="apple-touch-icon">`.
struct FaviconCandidate: Equatable, Sendable {
    let url: URL
    /// Widths from the `sizes` attribute, empty when the page doesn't say.
    let sizes: [Int]
    let isScalable: Bool
    let isTouchIcon: Bool

    init(url: URL, sizes: [Int] = [], isScalable: Bool = false, isTouchIcon: Bool = false) {
        self.url = url
        self.sizes = sizes
        self.isScalable = isScalable
        self.isTouchIcon = isTouchIcon
    }

    /// Reads a `<link>` element's attributes. `mask-icon` is left out because it's a monochrome template,
    /// and SVG icons because decoding them would run an SVG parser outside WebKit's sandbox.
    init?(rel: String, href: String, sizes: String = "", type: String = "", baseURL: URL) {
        let rels = Set(rel.lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        let isTouchIcon = !rels.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"])
        let href = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rels.contains("icon") || isTouchIcon, !href.isEmpty,
              let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https", "data"].contains(scheme),
              url.absoluteString.utf8.count <= (scheme == "data" ? FaviconData.maxDataURLCharacters : FaviconData.maxURLCharacters),
              type.lowercased() != "image/svg+xml", url.pathExtension.lowercased() != "svg",
              !url.absoluteString.lowercased().hasPrefix("data:image/svg") else { return nil }
        let sizeTokens = sizes.lowercased().split(whereSeparator: \.isWhitespace)
        self.init(url: url,
                  sizes: sizeTokens.compactMap { $0.split(separator: "x").first.flatMap { Int($0) } },
                  isScalable: sizeTokens.contains("any"),
                  isTouchIcon: isTouchIcon)
    }

    /// Icon addresses to try, best first, for a 16–32 pt icon on a 2x display, ending with the site's `/favicon.ico`.
    static func ranked(_ candidates: [FaviconCandidate], pageURL: URL) -> [URL] {
        let sorted = candidates.enumerated().sorted { first, second in
            let (a, b) = (first.element.rank, second.element.rank)
            return (a.tier, a.distance, first.offset) < (b.tier, b.distance, second.offset)
        }
        var urls: [URL] = []
        for url in sorted.map(\.element.url) + [defaultIconURL(for: pageURL)].compactMap({ $0 })
        where !urls.contains(url) {
            urls.append(url)
        }
        return urls
    }

    static func defaultIconURL(for pageURL: URL) -> URL? {
        guard ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return nil }
        return URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
    }

    /// Known sizes of at least 32 px come first, closest to 64 px. A scalable icon beats one of unknown or small size,
    /// and touch icons, which are usually opaque squares, come last.
    private var rank: (tier: Int, distance: Int) {
        if isTouchIcon { return (4, abs((sizes.max() ?? 180) - 64)) }
        if let size = sizes.filter({ $0 >= 32 }).min(by: { abs($0 - 64) < abs($1 - 64) }) { return (0, abs(size - 64)) }
        if isScalable { return (1, 0) }
        if sizes.isEmpty { return (2, 0) }
        return (3, -(sizes.max() ?? 0))
    }
}

/// Incidental icon traffic must not consume a native application's one-shot OAuth listener.
/// Only the site's conventional icon is probed; arbitrary page URLs can contain single-use actions.
enum FaviconRequests {
    static func siteIcon<Value: Sendable>(for pageURL: URL,
                                         using request: @Sendable (URL) async -> Value?) async -> Value? {
        guard allowsNetworkRequest(to: pageURL), let iconURL = FaviconCandidate.defaultIconURL(for: pageURL) else { return nil }
        return await request(iconURL)
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func allowsNetworkRequest(to url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil,
              let rawHost = url.host()?.lowercased() else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host != "localhost", !host.hasSuffix(".localhost") else { return false }
        // inet_aton also recognizes shortened, integer, hexadecimal and octal IPv4 forms.
        var ipv4 = in_addr()
        if inet_aton(host, &ipv4) == 1 {
            let firstByte = UInt32(bigEndian: ipv4.s_addr) >> 24
            return firstByte != 127 && firstByte != 0
        }
        var ipv6 = in6_addr()
        let address = String(host.split(separator: "%", maxSplits: 1).first ?? "")
        if inet_pton(AF_INET6, address, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 0 || bytes.last == 1 { return false }
            let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255
            if mapped && (bytes[12] == 127 || bytes[12] == 0) { return false }
        }
        return !host.isEmpty
    }
}

/// Enforce the same boundary for redirects, rather than checking only the initial icon URL.
final class FaviconRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url.map(FaviconRequests.allowsNetworkRequest) == true else { completionHandler(nil); return }
        var anonymous = request
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        anonymous.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        completionHandler(anonymous)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Keep normal TLS trust evaluation, but never offer account or proxy credentials.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// Icon files kept in Caches, one per host, so icons show without the network after a relaunch.
struct FaviconCache: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let source: URL
        let data: Data
    }

    let directory: URL
    var maxAge: Duration
    private let mutations = FaviconCacheMutations()

    init(directory: URL, maxAge: Duration = .seconds(7 * 24 * 60 * 60)) {
        self.directory = directory
        self.maxAge = maxAge
    }

    var writeGeneration: Int { mutations.lock.withLock { mutations.generation } }

    func invalidatePendingWrites() {
        mutations.lock.withLock { mutations.generation += 1 }
    }

    func entry(forHost host: String, now: Date = .now) -> Entry? {
        let file = fileURL(forHost: host)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              now.timeIntervalSince(modified) < TimeInterval(maxAge.components.seconds),
              let data = try? Data(contentsOf: file) else { return nil }
        return try? PropertyListDecoder().decode(Entry.self, from: data)
    }

    func save(_ entry: Entry, forHost host: String, generation: Int? = nil) {
        guard let data = try? PropertyListEncoder().encode(entry) else { return }
        mutations.lock.withLock {
            guard generation == nil || generation == mutations.generation else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: fileURL(forHost: host), options: .atomic)
        }
    }

    func removeEntries(since date: Date) {
        mutations.lock.lock()
        defer { mutations.lock.unlock() }
        mutations.generation += 1
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantFuture) >= date { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func fileURL(forHost host: String) -> URL {
        directory.appending(path: host.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? host)
    }
}

/// Shared by cache copies so clearing also invalidates writes from downloads in flight.
private final class FaviconCacheMutations: @unchecked Sendable {
    let lock = NSLock()
    var generation = 0
}

/// Only the Existing Profile can use the legacy durable icon cache. Other contexts use anonymous, uncached requests.
enum FaviconContext: Hashable {
    case existingProfile
    case transient(UUID)
    var remembersIcons: Bool { self == .existingProfile }
}

struct FaviconRequest: Hashable {
    let url: URL
    let context: FaviconContext
}

private struct FaviconContextKey: EnvironmentKey {
    static let defaultValue = FaviconContext.transient(UUID())
}

extension EnvironmentValues {
    var faviconContext: FaviconContext {
        get { self[FaviconContextKey.self] }
        set { self[FaviconContextKey.self] = newValue }
    }
}

/// Site icons shared by tabs, the bookmarks bar, and the new tab page.
@MainActor
enum FaviconStore {
    private struct Icon: Sendable {
        let source: URL
        let image: Image
    }

    static var cache = FaviconCache(directory: BrowserProfile.isTesting || BrowserProfile.qaDirectory != nil
        ? BrowserProfile.directory.appending(path: "Favicons")
        : URL.cachesDirectory.appending(path: BrowserProfile.bundleIdentifier).appending(path: "Favicons"))
    static let maximumPageCandidates = 32
    static let maximumPageCandidateElements = 256
    static let maximumPageLinkElements = 512
    static let maximumMemoryIcons = 120
    static let maximumMemoryIconCost = 8 * 1024 * 1024
    static let maximumMissingHosts = 256
    static let maximumFailedSources = 512

    private static var icons: [String: Icon] = [:]
    private static var iconCosts: [String: Int] = [:]
    private static var iconRecency: [String: Int] = [:]
    private static var totalIconCost = 0
    private static var recency = 0
    private static var requests: [String: Task<Icon?, Never>] = [:]
    /// When a host's icon couldn't be found, so a slow network doesn't leave it without one for long.
    private static var missingHosts: [String: ContinuousClock.Instant] = [:]
    private static var failedSourceKeys: Set<UInt64> = []
    private static var generation = 0
    private static var clearTask: Task<Void, Never>?

    nonisolated private static let session: URLSession = {
        URLSession(configuration: FaviconRequests.sessionConfiguration(), delegate: FaviconRedirectPolicy(), delegateQueue: nil)
    }()

    /// Forgets the icons kept in memory, and removes the ones saved to disk since `date`.
    static func clear(since date: Date) async {
        generation += 1
        requests.values.forEach { $0.cancel() }
        requests = [:]
        cache.invalidatePendingWrites()
        icons = [:]
        iconCosts = [:]
        iconRecency = [:]
        totalIconCost = 0
        recency = 0
        missingHosts = [:]
        failedSourceKeys = []
        let currentGeneration = generation
        let previousClear = clearTask
        let requestCache = cache
        let deletion = Task {
            await previousClear?.value
            await removeFiles(in: requestCache, since: date)
        }
        clearTask = deletion
        await deletion.value
        if currentGeneration == generation { clearTask = nil }
    }

    @concurrent
    nonisolated private static func removeFiles(in cache: FaviconCache, since date: Date) async {
        cache.removeEntries(since: date)
    }

    static func cachedIcon(for url: URL?, context: FaviconContext) -> Image? {
        context.remembersIcons ? cachedIcon(for: url) : nil
    }

    static func icon(for url: URL, context: FaviconContext) async -> Image? {
        await icon(for: url, remember: context.remembersIcons)
    }

    static func cachedIcon(for url: URL?) -> Image? {
        guard let host = url?.host(), let icon = icons[host] else { return nil }
        touch(host)
        return icon.image
    }

    struct MemoryUsage: Equatable {
        let icons: Int
        let iconCost: Int
        let missingHosts: Int
        let failedSources: Int
    }

    static var memoryUsage: MemoryUsage {
        MemoryUsage(icons: icons.count, iconCost: totalIconCost,
                    missingHosts: missingHosts.count, failedSources: failedSourceKeys.count)
    }

    /// An icon for a site that isn't open: the cached one or its conventional `/favicon.ico`.
    /// Declared icons are discovered from the live document after it loads.
    static func icon(for url: URL, remember: Bool = true) async -> Image? {
        guard let host = url.host() else { return nil }
        guard remember else {
            return await loadSiteIcon(for: url, host: host, in: nil)?.image
        }
        await clearTask?.value
        guard !Task.isCancelled else { return nil }
        if let icon = icons[host] {
            touch(host)
            return icon.image
        }
        if let missing = missingHosts[host], ContinuousClock.now - missing < .seconds(300) { return nil }

        let currentGeneration = generation
        let requestCache = cache
        let icon = await deduplicated(host, host: host) {
            await loadSiteIcon(for: url, host: host, in: requestCache)
        }
        guard currentGeneration == generation, !Task.isCancelled else { return nil }
        rememberMissingHost(host, at: icon == nil ? .now : nil)
        return icon?.image
    }

    private static func loadSiteIcon(for url: URL, host: String, in cache: FaviconCache?) async -> Icon? {
        if let cache, let icon = await diskIcon(forHost: host, in: cache) { return icon }
        guard !Task.isCancelled else { return nil }
        return await FaviconRequests.siteIcon(for: url) { source in
            await download(source, forHost: host, into: cache)
        }
    }

    /// The best of the icons an open page declares, downloaded only when it isn't the one already cached.
    /// A private window's icons aren't kept, in memory or on disk.
    static func icon(forPage url: URL, candidates: [FaviconCandidate], remember: Bool = true) async -> Image? {
        guard let host = url.host() else { return nil }
        let sources = rankedSources(candidates, pageURL: url, remember: remember)
        guard let best = sources.first else { return nil }
        guard remember else {
            for source in sources {
                if let icon = await download(source, forHost: host, into: nil) { return icon.image }
            }
            return nil
        }

        await clearTask?.value
        guard !Task.isCancelled else { return nil }
        if let icon = icons[host], icon.source == best {
            touch(host)
            return icon.image
        }
        let currentGeneration = generation
        let requestCache = cache
        let icon = await deduplicated(best.absoluteString, host: host) {
            if let icon = await diskIcon(forHost: host, in: requestCache), icon.source == best { return icon }
            for source in sources {
                guard !Task.isCancelled, currentGeneration == generation else { return nil }
                if let icon = await download(source, forHost: host, into: requestCache) { return icon }
                guard !Task.isCancelled, currentGeneration == generation else { return nil }
                rememberFailedSource(source)
            }
            return nil
        }
        guard currentGeneration == generation, !Task.isCancelled else { return nil }
        if icon != nil { rememberMissingHost(host, at: nil) }
        return icon?.image
    }

    private static func rankedSources(_ candidates: [FaviconCandidate], pageURL: URL,
                                      remember: Bool) -> ArraySlice<URL> {
        FaviconCandidate.ranked(candidates, pageURL: pageURL)
            .filter { !remember || !failedSourceKeys.contains(failureKey(for: $0)) }
            .prefix(4)
    }

    /// Reads the icon links of the page a web view shows, in a content world the page's scripts can't reach.
    static func candidates(in webView: WKWebView) async -> [FaviconCandidate] {
        let script = """
            (() => {
              const candidates = [];
              let scanned = 0, examined = 0, order = 0;
              for (const link of document.getElementsByTagName('link')) {
                if (++scanned > \(maximumPageLinkElements)) break;
                if (!link.hasAttribute('href')) continue;
                const rel = new Set(link.rel.toLowerCase().split(/\\s+/));
                const touch = rel.has('apple-touch-icon') || rel.has('apple-touch-icon-precomposed');
                if (!rel.has('icon') && !touch) continue;
                if (++examined > \(maximumPageCandidateElements)) break;
                const href = link.href;
                if (href.length > (href.startsWith('data:')
                    ? \(FaviconData.maxDataURLCharacters) : \(FaviconData.maxURLCharacters))) continue;
                const type = link.type.slice(0, 128).toLowerCase();
                if (type === 'image/svg+xml' || href.toLowerCase().startsWith('data:image/svg')) continue;
                const sizeText = (link.getAttribute('sizes') || '').slice(0, 256).toLowerCase();
                const sizes = sizeText.split(/\\s+/).map(value => parseInt(value, 10)).filter(Number.isFinite);
                const usable = sizes.filter(value => value >= 32).sort((a, b) => Math.abs(a - 64) - Math.abs(b - 64));
                let tier, distance;
                if (touch) [tier, distance] = [4, Math.abs((sizes.length ? Math.max(...sizes) : 180) - 64)];
                else if (usable.length) [tier, distance] = [0, Math.abs(usable[0] - 64)];
                else if (sizeText.split(/\\s+/).includes('any')) [tier, distance] = [1, 0];
                else if (!sizes.length) [tier, distance] = [2, 0];
                else [tier, distance] = [3, -Math.max(...sizes)];
                candidates.push({
                  rel: link.rel.slice(0, 128), href, sizes: sizeText, type,
                  __tier: tier, __distance: distance, __order: order++
                });
              }
              candidates.sort((a, b) => a.__tier - b.__tier
                || a.__distance - b.__distance || a.__order - b.__order);
              return candidates.slice(0, \(maximumPageCandidates))
                .map(({__tier, __distance, __order, ...value}) => value);
            })()
            """
        guard let pageURL = webView.url,
              let links = try? await webView.evaluateJavaScript(script, contentWorld: .defaultClient) as? [[String: String]]
        else { return [] }
        return links.compactMap {
            FaviconCandidate(rel: $0["rel"] ?? "", href: $0["href"] ?? "", sizes: $0["sizes"] ?? "",
                             type: $0["type"] ?? "", baseURL: pageURL)
        }
    }

    /// Shares one load between everything asking for the same icon, and keeps the result for the host.
    private static func deduplicated(_ key: String, host: String,
                                     _ load: @escaping @MainActor () async -> Icon?) async -> Icon? {
        if let request = requests[key] { return await request.value }
        let currentGeneration = generation
        let request = Task(operation: load)
        requests[key] = request
        let icon = await request.value
        guard generation == currentGeneration, !request.isCancelled else { return nil }
        requests[key] = nil
        if let icon { store(icon, forHost: host) }
        return icon
    }

    private static func touch(_ host: String) {
        recency += 1
        iconRecency[host] = recency
    }

    private static func store(_ icon: Icon, forHost host: String) {
        if let previous = iconCosts[host] { totalIconCost -= previous }
        let cost = FaviconData.maxPixelSize * FaviconData.maxPixelSize * 4
            + icon.source.absoluteString.utf8.count
        icons[host] = icon
        iconCosts[host] = cost
        totalIconCost += cost
        touch(host)
        while icons.count > maximumMemoryIcons || totalIconCost > maximumMemoryIconCost {
            guard let victim = iconRecency.min(by: { $0.value < $1.value })?.key else { break }
            icons[victim] = nil
            totalIconCost -= iconCosts.removeValue(forKey: victim) ?? 0
            iconRecency[victim] = nil
        }
    }

    private static func rememberMissingHost(_ host: String, at instant: ContinuousClock.Instant?) {
        missingHosts[host] = instant
        while missingHosts.count > maximumMissingHosts,
              let oldest = missingHosts.min(by: { $0.value < $1.value })?.key {
            missingHosts[oldest] = nil
        }
    }

    private static func rememberFailedSource(_ source: URL) {
        failedSourceKeys.insert(failureKey(for: source))
        while failedSourceKeys.count > maximumFailedSources, let victim = failedSourceKeys.first {
            failedSourceKeys.remove(victim)
        }
    }

    private static func failureKey(for source: URL) -> UInt64 {
        source.absoluteString.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    @concurrent
    nonisolated private static func diskIcon(forHost host: String, in cache: FaviconCache) async -> Icon? {
        guard let entry = cache.entry(forHost: host), let image = image(from: entry.data) else { return nil }
        return Icon(source: entry.source, image: image)
    }

    @concurrent
    nonisolated private static func download(_ source: URL, forHost host: String,
                                             into cache: FaviconCache?) async -> Icon? {
        guard !Task.isCancelled else { return nil }
        let writeGeneration = cache?.writeGeneration
        guard let (data, _) = await fetch(source, limit: FaviconData.maxIconBytes,
                                          accepting: FaviconData.isIconMIMEType),
              !Task.isCancelled, !data.isTruncated, let image = image(from: data.bytes) else { return nil }
        cache?.save(FaviconCache.Entry(source: source, data: data.bytes), forHost: host,
                    generation: writeGeneration)
        return Icon(source: source, image: image)
    }

    /// Stops reading once the response is larger than `limit`, so a huge or endless file can't fill memory.
    nonisolated private static func fetch(_ url: URL, limit: Int,
                                          accepting isAccepted: (String?) -> Bool) async -> (FaviconData.Read, URL)? {
        guard url.scheme?.lowercased() == "data" || FaviconRequests.allowsNetworkRequest(to: url),
              let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              isAccepted(response.mimeType),
              let data = try? await FaviconData.read(bytes, limit: limit), !data.bytes.isEmpty
        else { return nil }
        return (data, response.url ?? url)
    }

    nonisolated private static func image(from data: Data) -> Image? {
        guard let image = FaviconData.image(from: data) else { return nil }
        return Image(nsImage: NSImage(cgImage: image, size: .zero))
    }
}

/// Limits on icon downloads. Icons are decoded in the app's own process,
/// outside WebKit's sandbox, so only small files in a few raster formats are accepted.
enum FaviconData {
    static let maxIconBytes = 512 * 1024
    static let maxDataURLCharacters = 128 * 1024
    static let maxURLCharacters = 2 * 1024
    /// Icons show at 14–32 pt, so larger images are scaled down as they're decoded.
    static let maxPixelSize = 128

    struct Read: Equatable {
        let bytes: Data
        /// Whether the response had more bytes than the limit, which were left unread.
        let isTruncated: Bool
    }

    /// Reads up to `limit` bytes, stopping at the first byte past it.
    static func read<Bytes: AsyncSequence>(_ bytes: Bytes, limit: Int) async throws -> Read
    where Bytes.Element == UInt8 {
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { return Read(bytes: data, isTruncated: true) }
            data.append(byte)
        }
        return Read(bytes: data, isTruncated: false)
    }

    /// Servers often send `.ico` files as untyped binary data, so that's accepted too. The file's
    /// first bytes decide whether it's decoded.
    static func isIconMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return true }
        return (mimeType.hasPrefix("image/") && mimeType != "image/svg+xml") || mimeType == "application/octet-stream"
    }

    /// The format a file's first bytes identify, among PNG, ICO, JPEG, GIF, and WebP.
    static func imageType(of data: Data) -> UTType? {
        let header = [UInt8](data.prefix(12))
        func starts(with prefix: String) -> Bool { header.starts(with: Array(prefix.utf8)) }
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if header.starts(with: [0x00, 0x00, 0x01, 0x00]) { return .ico }
        if header.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if starts(with: "GIF87a") || starts(with: "GIF89a") { return .gif }
        if starts(with: "RIFF"), header.count == 12, header[8...].elementsEqual("WEBP".utf8) { return .webP }
        return nil
    }

    /// Decodes an icon whose bytes match one of the accepted formats, picking the size closest to 64 px
    /// from an `.ico` file and scaling it down to `maxPixelSize`.
    static func image(from data: Data) -> CGImage? {
        guard data.count <= maxIconBytes, let type = imageType(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceTypeIdentifierHint: type.identifier,
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetType(source) as String? == type.identifier else { return nil }
        func width(at index: Int) -> Int {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            return properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        }
        guard let index = (0..<min(CGImageSourceGetCount(source), 16))
            .min(by: { abs(width(at: $0) - 64) < abs(width(at: $1) - 64) }) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}
