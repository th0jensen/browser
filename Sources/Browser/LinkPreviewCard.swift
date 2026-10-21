import AppKit
import SwiftUI

struct LinkPreviewCard: View {
    let preview: LinkPreviewPresentation
    private var state: LinkPreviewState { preview.state }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let headerHeight: CGFloat = state.isKept ? 36 : 0
        return VStack(spacing: 0) {
            if state.isKept {
                HStack(spacing: 2) {
                    PreviewDragArea(preview: preview)
                        .overlay(alignment: .leading) {
                            HStack(spacing: 5) {
                                if state.isKept { Image(systemName: "pin.fill").font(.system(size: 9)) }
                                Text(state.url.host()?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? "Preview")
                                    .font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            }.foregroundStyle(.secondary).padding(.leading, 12).allowsHitTesting(false)
                        }
                    PreviewActionsControl(preview: preview).frame(width: 24, height: 24)
                    Button { preview.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(ChromeCloseButtonStyle())
                    .accessibilityLabel(state.isKept ? "Close preview note" : "Close preview")
                }.frame(height: headerHeight).padding(.trailing, 6)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let image = state.image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: state.cardWidth, height: 100).clipped().accessibilityHidden(true)
                            .overlay { if state.isKept { PreviewDragArea(preview: preview) } }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        if let result = state.result {
                            Text(result.summary).font(.system(size: 12, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).allowsHitTesting(state.isKept)
                            ForEach(Array(result.keyPoints.prefix(3).enumerated()), id: \.offset) { _, point in
                                HStack(alignment: .top, spacing: 9) {
                                    Circle().fill(.secondary.opacity(0.55)).frame(width: 4, height: 4).padding(.top, 6)
                                    Text(point).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled).allowsHitTesting(state.isKept)
                                }
                            }
                        }
                        if let error = state.error {
                            Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if state.isLoading && state.result == nil {
                            VStack(alignment: .leading, spacing: 9) {
                                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.12)).frame(height: 11)
                                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08))
                                    .frame(width: min(235, state.cardWidth - 28), height: 11)
                                RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08))
                                    .frame(width: min(170, state.cardWidth - 28), height: 11)
                            }
                            .padding(.vertical, 6)
                            .modifier(IntelligenceShimmer(active: !reduceMotion))
                            .accessibilityLabel("Loading link preview")
                        }
                        Text(state.url.absoluteString)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle)
                            .textSelection(.enabled).allowsHitTesting(state.isKept)
                            .accessibilityLabel("Source: \(state.url.absoluteString)")
                        HStack {
                            if state.isLoading { ProgressView().controlSize(.mini) }
                            Spacer()
                            Button { preview.open() } label: {
                                Label("Open Page", systemImage: "arrow.up.right").font(.system(size: 10))
                            }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }.padding(14)
                }
                .frame(width: state.cardWidth, alignment: .leading)
                .overlay(alignment: .top) {
                    if !state.isKept { PreviewDragArea(preview: preview, excludingFooter: true) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height + headerHeight } action: {
                    state.contentHeight = $0
                    preview.resize(height: $0)
                }
            }.scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(.primary)
        .frame(width: state.cardWidth, height: min(max(state.contentHeight, 106), state.maximumHeight))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .focusEffectDisabled()
        .onHover { preview.hover($0) }
    }
}

/// Transient text and padding are drag targets; kept notes allow text selection.
private struct PreviewDragArea: NSViewRepresentable {
    let preview: LinkPreviewPresentation
    var excludingFooter = false
    func makeNSView(context: Context) -> PreviewDragView {
        let view = PreviewDragView(preview: preview)
        view.excludingFooter = excludingFooter
        return view
    }
    func updateNSView(_ view: PreviewDragView, context: Context) {
        view.preview = preview
        view.excludingFooter = excludingFooter
    }
}

final class PreviewDragView: NSView {
    weak var preview: LinkPreviewPresentation?
    private var press: NSEvent?
    var excludingFooter = false
    init(preview: LinkPreviewPresentation) {
        self.preview = preview
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Drag preview to keep as a note")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if excludingFooter && NSRect(x: bounds.maxX - 105, y: bounds.minY, width: 105, height: 40).contains(local) { return nil }
        return super.hitTest(point)
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { press = event }
    override func mouseUp(with event: NSEvent) { press = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let press, let sourceWindow = press.window, let preview else { return }
        let distance = hypot(event.locationInWindow.x - press.locationInWindow.x, event.locationInWindow.y - press.locationInWindow.y)
        guard distance >= 4 else { return }
        self.press = nil
        let pressPoint = sourceWindow.convertPoint(toScreen: press.locationInWindow)
        let origin = preview.frame.origin
        preview.beginDrag()
        guard preview.panel != nil else { return }
        NSCursor.closedHand.push()
        defer { NSCursor.pop(); preview.endDrag() }
        // The mouse-down belongs to the source window, even after the view is
        // reparented into a note. Track real local events in screen coordinates;
        // performDrag(with:) requires the original event in the same window.
        var next: NSEvent? = event
        var wasActive = NSApp.isActive
        while !preview.isClosed {
            if let next {
                if next.type == .keyDown {
                    // Consume keys while tracking rather than dispatching queued
                    // page commands after the drop. Escape closes this note.
                    if next.keyCode == 53 { preview.close(); break }
                } else {
                    let point = next.window?.convertPoint(toScreen: next.locationInWindow) ?? NSEvent.mouseLocation
                    preview.moveDuringDrag(to: NSPoint(x: origin.x + point.x - pressPoint.x, y: origin.y + point.y - pressPoint.y))
                    if next.type == .leftMouseUp { break }
                }
            }
            let active = NSApp.isActive
            if (wasActive && !active) || NSEvent.pressedMouseButtons & 1 == 0 { break }
            wasActive = active
            next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true)
        }
    }
}
