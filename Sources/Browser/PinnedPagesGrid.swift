import AppKit
import SwiftUI

struct PinnedPagesGrid: View {
    let browser: BrowserModel

    static let tileHeight = BrowserChrome.pinHeight
    static func rowCounts(for count: Int) -> [Int] {
        let count = min(PinnedPageStore.limit, max(0, count))
        guard count > 0 else { return [] }
        let rows = (count + 2) / 3
        return (0..<rows).map { count / rows + ($0 < count % rows ? 1 : 0) }
    }

    var body: some View {
        let counts = Self.rowCounts(for: browser.pinnedPages.items.count)
        VStack(spacing: 8) {
            ForEach(counts.indices, id: \.self) { row in
                let start = counts.prefix(row).reduce(0, +)
                HStack(spacing: 8) {
                    ForEach(Array(browser.pinnedPages.items.dropFirst(start).prefix(counts[row]))) { page in
                        PinnedPageTile(page: page, browser: browser)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }
}

struct PinnedPagesButton: View {
    let browser: BrowserModel
    @AppStorage(ChromeCustomization.widthKey) private var sidebarWidth = Double(BrowserChrome.sidebarWidth)
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label("Pinned Pages", systemImage: "square.grid.3x3")
        }
        .font(.system(size: BrowserChrome.toolbarSymbolSize, weight: .regular))
        .labelStyle(.iconOnly)
        .buttonStyle(ChromeToolbarButtonStyle())
        .controlSize(.regular)
        .disabled(browser.pinnedPages.items.isEmpty)
        .help("Pinned Pages")
        .popover(isPresented: $isPresented) {
            PinnedPagesGrid(browser: browser).padding(BrowserChrome.edgeInset).frame(width: sidebarWidth)
                .onChange(of: browser.activeTabID) { _, _ in isPresented = false }
        }
        .chromePresentation(isPresented: isPresented, controller: browser.chromeHover)
    }
}

private struct PinnedPageTile: View {
    let page: PinnedPage
    let browser: BrowserModel
    @State private var tint: Color = .accentColor

    var body: some View {
        let active = browser.activeTab?.pinnedPageID == page.id
        Button { browser.openPinned(page) } label: {
            Color.clear.frame(height: PinnedPagesGrid.tileHeight)
                .overlay { SiteIcon(url: page.url, size: BrowserChrome.pinIconSize) }
                .contentShape(RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(active ? .regular.tint(tint.opacity(0.45)).interactive() : .regular.interactive(),
                     in: RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius, style: .continuous))
        .help("\(page.title)\n\(page.url.absoluteString)")
        .accessibilityLabel("Pinned: \(page.title)")
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .contextMenu {
            Button("Open in New Tab") { browser.open(page.url, inNewTab: true) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(page.url.absoluteString, forType: .string)
            }
            Divider()
            Button("Unpin Webpage") { browser.unpin(page) }
        }
        .task(id: page.url) {
            if let brand = WebsiteTint.brand(for: page.url) {
                tint = brand
            } else {
                _ = await FaviconStore.icon(for: page.url)
                if let host = page.url.host(), let entry = FaviconStore.cache.entry(forHost: host),
                   let image = FaviconData.image(from: entry.data), let color = WebsiteTint.dominant(in: image) {
                    tint = color
                }
            }
        }
    }
}

enum WebsiteTint {
    static func brand(for url: URL) -> Color? {
        let host = url.host()?.lowercased() ?? ""
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix(".\(domain)") }
        if matches("youtube.com") || matches("youtu.be") { return Color(red: 1, green: 0.06, blue: 0.06) }
        if matches("snapchat.com") { return Color(red: 1, green: 0.94, blue: 0) }
        return nil
    }

    /// A small saturation-weighted histogram avoids tinting glass white from an icon's background.
    static func dominant(in image: CGImage) -> Color? {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16,
                                          bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            return true
        }
        guard drawn else { return nil }
        var bins: [Int: (weight: Double, r: Double, g: Double, b: Double)] = [:]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[offset]) / 255 / alpha
            let g = Double(pixels[offset + 1]) / 255 / alpha
            let b = Double(pixels[offset + 2]) / 255 / alpha
            let maximum = max(r, g, b), minimum = min(r, g, b)
            guard maximum > 0.15, maximum - minimum > 0.15 else { continue }
            let weight = (maximum - minimum) * alpha
            let key = min(7, Int(r * 8)) * 64 + min(7, Int(g * 8)) * 8 + min(7, Int(b * 8))
            let old = bins[key] ?? (0, 0, 0, 0)
            bins[key] = (old.weight + weight, old.r + r * weight, old.g + g * weight, old.b + b * weight)
        }
        guard let best = bins.values.max(by: { $0.weight < $1.weight }) else { return nil }
        return Color(red: best.r / best.weight, green: best.g / best.weight, blue: best.b / best.weight)
    }
}
