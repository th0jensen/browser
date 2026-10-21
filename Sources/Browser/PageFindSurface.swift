import AppKit
import Observation
import SwiftUI

/// Local presentation inspired by the historical official Ask on Page GIF.
/// Keep the page visible and expand the existing Find surface in place. This is
/// a native Regular glass adaptation, not a claim of current Arc availability.
struct PageFindGeometry: Equatable {
    static let inset: CGFloat = 10
    static let preferredWidth: CGFloat = 400
    static let headerHeight: CGFloat = 34
    let frame: CGRect
    let maximumHeight: CGFloat

    init(available: CGSize, contentHeight: CGFloat) {
        // Retain readable source beside the card in ordinary page panes, and
        // below it in very narrow panes. These are Browser layout bounds, not
        // recovered Arc dimensions.
        let readableWidth = max(240, available.width * 0.55)
        let width = min(min(Self.preferredWidth, readableWidth), max(0, available.width - Self.inset * 2))
        maximumHeight = min(480, max(0, min(available.height - Self.inset * 2, available.height * 0.65)))
        let height = min(maximumHeight, max(Self.headerHeight, contentHeight))
        frame = CGRect(x: max(0, available.width - Self.inset - width),
                       y: min(Self.inset, max(0, available.height - height)), width: width, height: height)
    }
}

@MainActor @Observable
private final class PageFindMetrics {
    var width = PageFindGeometry.preferredWidth
    var bodyLimit: CGFloat = 446
}

struct PageFindSurface: NSViewRepresentable {
    let tab: BrowserTab
    let browser: BrowserModel

    func makeNSView(context: Context) -> PageFindSurfaceView { PageFindSurfaceView(tab: tab, browser: browser) }
    func updateNSView(_ view: PageFindSurfaceView, context: Context) { view.update(tab: tab, browser: browser) }
    static func dismantleNSView(_ view: PageFindSurfaceView, coordinator: ()) { view.stop() }
}

/// No panel, modal session, or window activation. Only the glass card receives
/// pointer events; the rest of this full-page overlay passes through to WebKit.
@MainActor
final class PageFindSurfaceView: NSView {
    let glass = NSGlassEffectView()
    private var host: NSHostingView<PageFindCard>?
    private let metrics = PageFindMetrics()
    private weak var tab: BrowserTab?
    private weak var browser: BrowserModel?
    private var monitor: Any?
    private(set) var contentHeight = PageFindGeometry.headerHeight
    override var isFlipped: Bool { true }

    init(tab: BrowserTab, browser: BrowserModel) {
        super.init(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = 12
        glass.focusRingType = .none
        glass.identifier = NSUserInterfaceItemIdentifier("PageFindRegularGlass")
        addSubview(glass)
        update(tab: tab, browser: browser)
    }

    required init?(coder: NSCoder) { return nil }
    isolated deinit { stop() }

    func update(tab: BrowserTab, browser: BrowserModel) {
        guard self.tab !== tab || self.browser !== browser else { return }
        self.tab = tab
        self.browser = browser
        let root = PageFindCard(tab: tab, browser: browser, metrics: metrics) { [weak self] height in
            guard let self, height.isFinite, abs(height - self.contentHeight) > 0.5 else { return }
            self.contentHeight = height
            self.needsLayout = true
        }
        if let host { host.rootView = root }
        else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.focusRingType = .none
            host.autoresizingMask = [.width, .height]
            glass.contentView = host
            self.host = host
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let geometry = PageFindGeometry(available: bounds.size, contentHeight: contentHeight)
        metrics.width = geometry.frame.width
        metrics.bodyLimit = max(0, geometry.maximumHeight - PageFindGeometry.headerHeight)
        glass.frame = geometry.frame
        glass.isHidden = geometry.frame.isEmpty
        host?.frame = glass.bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard !glass.isHidden, glass.frame.contains(local) else { return nil }
        return glass.hitTest(local)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleEscape(event) == true }
            return handled ? nil : event
        }
    }

    func handleEscape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
              !isHiddenOrHasHiddenAncestor, let tab, let browser,
              browser.focusedPage === tab, tab.isFindBarVisible else { return false }
        let responder = window.firstResponder
        guard !FocusedTextInput.hasMarkedText(responder) else { return false }
        let pageHasFocus = responder === tab.webView
            || (responder as? NSView).map { view in tab.webView.map { view.isDescendant(of: $0) } ?? false } == true
        guard ownsFocus(responder) || pageHasFocus else { return false }
        browser.closeFindBar()
        return true
    }

    func ownsFocus(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView, view.isDescendant(of: self) { return true }
        // A native field editor belongs to its window, not the hosted subtree.
        func containsEditor(_ view: NSView) -> Bool {
            if let field = view as? NSTextField, field.currentEditor() === responder, responder != nil { return true }
            return view.subviews.contains(where: containsEditor)
        }
        return containsEditor(glass)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

private struct PageFindCard: View {
    @Bindable var tab: BrowserTab
    @Bindable var browser: BrowserModel
    let metrics: PageFindMetrics
    let measured: (CGFloat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            FindBar(tab: tab, browser: browser, compact: metrics.width < 340)
                .id(tab.id)
            if let controller = browser.pageQuestion, controller.sourceTabID == tab.id {
                Divider().padding(.horizontal, 8)
                PageQuestionView(controller: controller, browser: browser, maximumHeight: max(0, metrics.bodyLimit - 1))
            }
        }
        .frame(width: metrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured($0) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find and Ask on Page")
        .transaction { $0.animation = nil }
    }
}

/// The sole native Find field above is also the question editor. Return keeps its
/// normal Find meaning. Only the visible Ask button starts a local request.
struct PageQuestionView: View {
    @Bindable var controller: PageQuestionController
    let browser: BrowserModel
    let maximumHeight: CGFloat
    @State private var bodyHeight: CGFloat = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ask on Page · On this Mac").font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Limited page text. Captured text and answers are not saved. Answers can be wrong. Type in Find, then choose Ask.")
                    .font(.caption).foregroundStyle(.secondary)
                if let reason = BrowserIntelligence.unavailableReason {
                    Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
                }
                if controller.isWorking {
                    HStack {
                        ProgressView().controlSize(.small).accessibilityLabel("Reading this page locally")
                        Text("Reading this page…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { controller.cancel() }
                    }
                }
                if let message = controller.message { Text(verbatim: message).foregroundStyle(.secondary) }
                if let answer = controller.answer {
                    Text("Generated answer").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(verbatim: answer).textSelection(.enabled)
                }
                if !controller.excerpts.isEmpty {
                    Divider()
                    Text("Source excerpts").font(.headline).accessibilityAddTraits(.isHeader)
                    ForEach(controller.excerpts) { block in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: block.text).textSelection(.enabled)
                            Button("Show source \(block.id) on page") {
                                // The checked completion never dismisses or moves focus.
                                Task { _ = await controller.reveal(block) }
                            }
                        }
                    }
                }
                Button("Return to Page") { browser.returnToPageFromQuestion(controller) }
                    .help("Keep this answer open. Command-F returns to Find.")
            }
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
        }
        .frame(height: min(bodyHeight, maximumHeight))
    }
}
