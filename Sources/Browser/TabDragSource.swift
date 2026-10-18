import AppKit
import Observation
import SwiftUI

/// Stable wire names keep existing drag payloads and saved identifiers compatible.
enum SidebarDragItem: Equatable {
    case tab(UUID), pinned(UUID), essential(UUID), section(UUID)
    case essentials, pinnedRoot, temporaryRoot

    init?(_ value: String) {
        if let id = UUID(uuidString: value) { self = .tab(id); return }
        switch value {
        case "browser-essentials": self = .essentials
        case "browser-sidebar-root", "browser-pinned-end": self = .pinnedRoot
        case "browser-temporary-root", "browser-temporary-end", "browser-temporary-actions": self = .temporaryRoot
        default:
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
            switch parts[0] {
            case "browser-folder": self = .pinned(id)
            case "browser-essential": self = .essential(id)
            case "browser-section": self = .section(id)
            default: return nil
            }
        }
    }
    var payload: String {
        switch self {
        case .tab(let id): id.uuidString
        case .pinned(let id): "browser-folder:\(id.uuidString)"
        case .essential(let id): "browser-essential:\(id.uuidString)"
        case .section(let id): "browser-section:\(id.uuidString)"
        case .essentials: "browser-essentials"
        case .pinnedRoot: "browser-sidebar-root"
        case .temporaryRoot: "browser-temporary-root"
        }
    }
}

/// Reordering moves the live SwiftUI row. No window snapshot or system drag
/// image is involved. Sidebar reordering stays on its axis; a page split drag
/// follows the pointer once it leaves the tab list.
@MainActor @Observable
final class TabReorderController {
    static let splitPrefix = "browser-split:"
    static let pageSplitPrefix = "browser-page-split:"
    enum Axis { case vertical, horizontal }
    private(set) var payload: String?
    private(set) var axis = Axis.vertical
    private(set) var center: CGFloat = 0
    private(set) var splitTarget: String?
    private(set) var pageSplitEdge: SplitEdge?
    var splitTargetFrame: CGRect? { splitTarget.flatMap { frames[$0]?.frame } }
    @ObservationIgnored private var pageTarget: (frame: CGRect, payload: String, owner: UUID)?
    @ObservationIgnored private var pageDestination: String?
    @ObservationIgnored private var startPoint = CGPoint.zero
    private var pointerCenter = CGPoint.zero
    @ObservationIgnored var canSplit: ((String, String) -> Bool)?
    @ObservationIgnored private var startCenter: CGFloat = 0
    @ObservationIgnored private var frames: [String: (frame: CGRect, axis: Axis, priority: Int, owner: UUID?)] = [:]
    @ObservationIgnored private var crossing: ((String, Int) -> Void)?
    @ObservationIgnored private var completion: ((String?) -> Void)?
    @ObservationIgnored private var escapeMonitor: Any?
    @ObservationIgnored private var cancelledPayload: String?

    func register(_ payload: String, frame: CGRect, axis: Axis, priority: Int = 0, owner: UUID? = nil) {
        frames[payload] = (frame, axis, priority, owner)
    }
    func unregister(_ payload: String, owner: UUID? = nil) {
        // A reparented row can mount before its former view disappears.
        guard frames[payload]?.owner == owner else { return }
        frames.removeValue(forKey: payload)
    }
    func registerPage(frame: CGRect, payload: String, owner: UUID) { pageTarget = (frame, payload, owner) }
    func unregisterPage(owner: UUID) { if pageTarget?.owner == owner { pageTarget = nil } }
    @discardableResult
    func begin(_ payload: String, frame: CGRect, axis: Axis,
               crossing: @escaping (String, Int) -> Void, completion: @escaping (String?) -> Void) -> Bool {
        guard self.payload == nil, cancelledPayload == nil else { return false }
        self.payload = payload
        self.axis = axis
        startCenter = axis == .vertical ? frame.midY : frame.midX
        center = startCenter
        splitTarget = nil
        pageSplitEdge = nil
        pageDestination = nil
        startPoint = CGPoint(x: frame.midX, y: frame.midY)
        self.crossing = crossing
        self.completion = completion
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown, event.keyCode == 53 { self.finish(cancelled: true); return true }
                // SwiftUI normally ends the gesture first. This also cleans up
                // when a window loses focus or a row disappears during a drag.
                if event.type == .leftMouseUp {
                    DispatchQueue.main.async { [weak self] in self?.endGesture() }
                }
                return false
            }
            return consumed ? nil : event
        }
        return true
    }
    func endGesture() {
        finish()
        cancelledPayload = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
    }
    func update(translation: CGSize, pointer: CGPoint? = nil) {
        guard let payload else { return }
        pointerCenter = CGPoint(x: startPoint.x + translation.width, y: startPoint.y + translation.height)
        if let point = pointer, let pageTarget, pageTarget.frame.contains(point), canSplit?(payload, pageTarget.payload) == true {
            let edge = SplitEdge.destination(at: point, in: pageTarget.frame)
            pageSplitEdge = edge
            pageDestination = Self.pageSplitPrefix + edge.rawValue + ":" + pageTarget.payload
            splitTarget = nil
            return
        }
        pageSplitEdge = nil
        pageDestination = nil
        let entries = frames.filter { $0.value.1 == axis }
        func middle(_ frame: CGRect) -> CGFloat { axis == .vertical ? frame.midY : frame.midX }
        let centers = entries.values.map { middle($0.0) }
        let desired = startCenter + (axis == .vertical ? translation.height : translation.width)
        let hasSplitTargets = entries.keys.contains { $0.hasPrefix(Self.splitPrefix) }
        let minimum = hasSplitTargets ? entries.values.map { axis == .vertical ? $0.0.minY : $0.0.minX }.min() : centers.min()
        let maximum = hasSplitTargets ? entries.values.map { axis == .vertical ? $0.0.maxY : $0.0.maxX }.max() : centers.max()
        center = min(maximum ?? desired, max(minimum ?? desired, desired))
        splitTarget = entries.first { key, value in
            guard key.hasPrefix(Self.splitPrefix) else { return false }
            let contains = axis == .vertical ? center >= value.0.minY && center <= value.0.maxY
                : center >= value.0.minX && center <= value.0.maxX
            return contains && canSplit?(payload, String(key.dropFirst(Self.splitPrefix.count))) == true
        }?.key
        // A tab's middle is a split target; passing its edge still reorders.
        if splitTarget != nil { return }
        guard let source = frames[payload]?.0 else { return }
        let sourceCenter = middle(source)
        let direction = center >= sourceCenter ? 1 : -1
        let passed = entries.filter { key, value in
            let target = middle(value.0)
            return key != payload && !key.hasPrefix(Self.splitPrefix) && (direction > 0 ? target > sourceCenter && target <= center : target < sourceCenter && target >= center)
        }.sorted { direction > 0 ? middle($0.value.0) < middle($1.value.0) : middle($0.value.0) > middle($1.value.0) }
        for entry in passed { crossing?(entry.key, direction) }
    }
    func offset(for payload: String, frame: CGRect) -> CGSize {
        guard self.payload == payload else { return .zero }
        if pageSplitEdge != nil { return CGSize(width: pointerCenter.x - frame.midX, height: pointerCenter.y - frame.midY) }
        return axis == .vertical ? CGSize(width: 0, height: center - frame.midY)
            : CGSize(width: center - frame.midX, height: 0)
    }
    func isOver(_ target: String) -> Bool {
        guard let payload, payload != target, let entry = frames[target], entry.1 == axis else { return false }
        return axis == .vertical ? center >= entry.0.minY && center <= entry.0.maxY
            : center >= entry.0.minX && center <= entry.0.maxX
    }
    func finish(cancelled: Bool = false) {
        guard let payload else { return }
        let destination = pageDestination ?? frames.filter { key, value in
            guard key != payload, value.1 == axis else { return false }
            let contains = axis == .vertical ? center >= value.0.minY && center <= value.0.maxY
                : center >= value.0.minX && center <= value.0.maxX
            guard contains else { return false }
            return !key.hasPrefix(Self.splitPrefix) || canSplit?(payload, String(key.dropFirst(Self.splitPrefix.count))) == true
        }.min { lhs, rhs in
            if lhs.value.priority != rhs.value.priority { return lhs.value.priority > rhs.value.priority }
            let a = axis == .vertical ? lhs.value.0.midY : lhs.value.0.midX
            let b = axis == .vertical ? rhs.value.0.midY : rhs.value.0.midX
            return abs(a - center) < abs(b - center)
        }?.key
        let callback = completion
        self.payload = nil
        splitTarget = nil
        pageSplitEdge = nil
        pageDestination = nil
        crossing = nil
        completion = nil
        if cancelled { cancelledPayload = payload }
        else if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        callback?(cancelled ? nil : destination)
    }
    isolated deinit { if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) } }
}

private struct TabReorderViewportKey: EnvironmentKey { static let defaultValue: CGRect? = nil }
extension EnvironmentValues {
    var tabReorderViewport: CGRect? {
        get { self[TabReorderViewportKey.self] }
        set { self[TabReorderViewportKey.self] = newValue }
    }
}

/// Keep ordinary rows clipped while allowing the live dragged row to cross
/// from the scrolling list into the fixed Essential Tabs grid.
private struct TabReorderClip: ViewModifier {
    let frame: CGRect
    let viewport: CGRect?
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled, let viewport {
            let visible = frame.intersection(viewport)
            content.mask(alignment: .topLeading) {
                if !visible.isNull {
                    Rectangle().frame(width: visible.width, height: visible.height)
                        .offset(x: visible.minX - frame.minX, y: visible.minY - frame.minY)
                } else { Color.clear }
            }
        } else { content }
    }
}

struct TabDragSource: ViewModifier {
    let controller: TabReorderController
    let payload: String
    var axis = TabReorderController.Axis.vertical
    var enabled = true
    let began: () -> Void
    let ended: (String?) -> Void
    let crossed: (String, Int) -> Void
    @State private var frame = CGRect.zero
    @State private var targetOwner = UUID()
    @Environment(\.tabReorderViewport) private var viewport

    func body(content: Content) -> some View {
        let dragging = controller.payload == payload
        ZStack {
            content
                .offset(controller.offset(for: payload, frame: frame))
                .transaction { if dragging { $0.animation = nil } }
        }
        .background {
            GeometryReader { _ in
                Color.clear.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { value in
                    frame = value
                    controller.register(payload, frame: value, axis: axis, owner: targetOwner)
                }
            }
        }
        .modifier(TabReorderClip(frame: frame, viewport: viewport, enabled: controller.payload != nil && !dragging))
        .zIndex(dragging ? 100 : 0)
        .transaction { if dragging { $0.animation = nil } }
        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                guard enabled else { return }
                if controller.begin(payload, frame: frame, axis: axis, crossing: crossed, completion: ended) { began() }
                guard controller.payload == payload else { return }
                controller.update(translation: value.translation, pointer: value.location)
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.16)) { controller.endGesture() }
            }, including: enabled ? .all : .none)
        .onDisappear {
            controller.unregister(payload, owner: targetOwner)
            if controller.payload == payload { controller.finish(cancelled: true) }
        }
    }
}

/// Folder/group headers remain stationary targets for moving tabs between groups.
struct TabReorderTarget: ViewModifier {
    let controller: TabReorderController
    let payload: String
    var axis = TabReorderController.Axis.vertical
    var priority = 0
    @State private var frame = CGRect.zero
    @State private var targetOwner = UUID()
    @Environment(\.tabReorderViewport) private var viewport
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            frame = $0
            controller.register(payload, frame: $0, axis: axis, priority: priority, owner: targetOwner)
        }
        .modifier(TabReorderClip(frame: frame, viewport: viewport, enabled: controller.payload != nil))
        .onDisappear { controller.unregister(payload, owner: targetOwner) }
    }
}
