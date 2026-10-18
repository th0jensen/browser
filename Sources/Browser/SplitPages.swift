import AppKit
import SwiftUI

struct SplitPages<Page: View>: View {
    let browser: BrowserModel
    let split: SplitTabGroup
    @ViewBuilder let page: (BrowserTab) -> Page
    @AppStorage(AppearancePreferences.dimInactiveSplitsKey) private var dimInactive = true
    @AppStorage(AppearancePreferences.inactiveSplitOpacityKey) private var inactiveOpacity = 0.85

    var body: some View {
        GeometryReader { geometry in
            let horizontal = split.orientation == .horizontal
            let length = horizontal ? geometry.size.width : geometry.size.height
            let available = max(1, length - BrowserChrome.edgeInset * CGFloat(split.tabIDs.count - 1))
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(split.tabIDs.enumerated()), id: \.element) { index, id in
                    if index > 0 {
                        SplitPaneDivider(browser: browser, split: split, boundary: index - 1, available: available)
                    }
                    if let tab = browser.tab(withID: id) {
                        pane(tab)
                            .frame(width: horizontal ? available * split.weights[index] : nil,
                                   height: horizontal ? nil : available * split.weights[index])
                            .frame(maxWidth: horizontal ? nil : .infinity, maxHeight: horizontal ? .infinity : nil)
                    }
                }
            }
        }
    }

    private func pane(_ tab: BrowserTab) -> some View {
        let active = browser.activeTabID == tab.id
        let shape = RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius, style: .continuous)
        return page(tab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(shape)
        .opacity(active ? 1 : AppearancePreferences.splitOpacity(inactiveOpacity, dimmed: dimInactive))
        .overlay { shape.strokeBorder(Color.primary.opacity(active ? 0.18 : 0.07), lineWidth: 1).allowsHitTesting(false) }
        .background(SplitPaneFocusObserver(browser: browser, tabID: tab.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split panel: \(tab.title)")
    }
}

private struct SplitPaneDivider: View {
    let browser: BrowserModel
    let split: SplitTabGroup
    let boundary: Int
    let available: CGFloat
    @State private var initialWeights: [Double]?

    var body: some View {
        let horizontal = split.orientation == .horizontal
        Color.clear
            .frame(width: horizontal ? BrowserChrome.edgeInset : nil,
                   height: horizontal ? nil : BrowserChrome.edgeInset)
            .overlay {
                ChromeResizeHandle(isResizing: initialWeights != nil, axis: horizontal ? .horizontal : .vertical)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if initialWeights == nil { initialWeights = split.weights }
                            adjust(by: (horizontal ? value.translation.width : value.translation.height) / available,
                                   from: initialWeights ?? split.weights)
                        }
                        .onEnded { _ in initialWeights = nil })
                    .onDisappear { initialWeights = nil }
                    .onTapGesture(count: 2) { browser.setSplitWeights(split.id, Array(repeating: 1, count: split.tabIDs.count)) }
                    .help("Drag to resize split panes")
                    .accessibilityLabel("Split panel sizes")
                    .accessibilityValue("\(Int(split.weights[boundary] * 100)) percent")
                    .accessibilityAdjustableAction { direction in
                        adjust(by: direction == .increment ? 0.025 : -0.025, from: split.weights)
                    }
            }
            .zIndex(1)
    }

    private func adjust(by delta: Double, from weights: [Double]) {
        let total = weights[boundary] + weights[boundary + 1]
        let minimum = min(140 / available, total / 3)
        let leading = min(total - minimum, max(minimum, weights[boundary] + delta))
        var updated = weights
        updated[boundary] = leading
        updated[boundary + 1] = total - leading
        browser.setSplitWeights(split.id, updated)
    }
}

/// Observe the original mouse event without intercepting links, text selection,
/// scrolling or WebKit's first-responder behavior in either panel.
private struct SplitPaneFocusObserver: NSViewRepresentable {
    let browser: BrowserModel
    let tabID: UUID
    func makeNSView(context: Context) -> SplitFocusView { SplitFocusView() }
    func updateNSView(_ view: SplitFocusView, context: Context) { view.browser = browser; view.tabID = tabID }
}

private final class SplitFocusView: NSView {
    weak var browser: BrowserModel?
    var tabID: UUID?
    private var monitor: Any?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.window === event.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)), let id = self.tabID else { return }
                self.browser?.activeTabID = id
            }
            return event
        }
    }
    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
