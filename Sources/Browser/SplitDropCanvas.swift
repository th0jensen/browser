import SwiftUI

enum SplitEdge: String, CaseIterable {
    case left, right, top, bottom
    var orientation: SplitOrientation { self == .left || self == .right ? .horizontal : .vertical }
    var leading: Bool { self == .left || self == .top }

    static func destination(at point: CGPoint, in frame: CGRect) -> SplitEdge {
        let x = (point.x - frame.minX) / max(1, frame.width)
        let y = (point.y - frame.minY) / max(1, frame.height)
        // The center makes a right split; edge regions allow all four placements.
        if y < 0.22 && y < min(x, 1 - x) { return .top }
        if y > 0.78 && 1 - y < min(x, 1 - x) { return .bottom }
        return x < 0.4 ? .left : .right
    }
}

/// The real current page resizes in place. The empty half previews the dragged
/// tab without loading a suspended page or taking focus before the drop.
struct SplitDropCanvas<Content: View>: View {
    let browser: BrowserModel
    @ViewBuilder let content: () -> Content
    @State private var frame = CGRect.zero
    @State private var owner = UUID()

    var body: some View {
        GeometryReader { geometry in
            let edge = browser.tabDrag.pageSplitEdge
            let horizontal = edge?.orientation == .horizontal
            let gap = edge == nil ? 0 : BrowserChrome.edgeInset
            let paneWidth = edge == nil || !horizontal ? geometry.size.width : (geometry.size.width - gap) / 2
            let paneHeight = edge == nil || horizontal ? geometry.size.height : (geometry.size.height - gap) / 2
            let x: CGFloat = edge == .left ? paneWidth + gap : 0
            let y: CGFloat = edge == .top ? paneHeight + gap : 0
            ZStack(alignment: .topLeading) {
                content()
                    .frame(width: paneWidth, height: paneHeight)
                    .offset(x: x, y: y)
                if let edge {
                    preview(edge)
                        .frame(width: paneWidth, height: paneHeight)
                        .offset(x: edge == .right ? paneWidth + gap : 0,
                                y: edge == .bottom ? paneHeight + gap : 0)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: edge)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { value in
            frame = value
            register()
        }
        .onChange(of: browser.activeTabID) { _, _ in register() }
        .onDisappear { browser.tabDrag.unregisterPage(owner: owner) }
    }

    private func register() {
        guard let id = browser.activeTabID else { return }
        browser.tabDrag.registerPage(frame: frame, payload: id.uuidString, owner: owner)
    }

    private func preview(_ edge: SplitEdge) -> some View {
        let source = browser.tabDrag.payload.flatMap(SidebarDragItem.init)
        let tab = source.flatMap(browser.existingDragTab)
        let url: URL? = tab?.url ?? {
            switch source {
            case .pinned(let id): return browser.folders.item(id)?.url
            case .essential(let id): return browser.pinnedPages.items.first { $0.id == id }?.url
            default: return nil
            }
        }()
        let title = tab?.title ?? url?.host() ?? "Tab"
        let shape = RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius, style: .continuous)
        return VStack(spacing: 10) {
            SplitSiteIcon(url: url, size: 28)
            Text(title).font(.system(size: 14, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
            Label("Drop to Split", systemImage: edge.orientation.symbol)
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.06))
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
    }
}
