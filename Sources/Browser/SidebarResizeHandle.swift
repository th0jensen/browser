import AppKit
import SwiftUI

/// Separates the live drag from the shared preference without delaying the sidebar's geometry.
struct SidebarWidthState {
    private var liveWidth: Double?

    func width(saved: Double) -> Double { liveWidth ?? saved }

    /// A non-drag adjustment, such as accessibility, is ready to persist immediately.
    mutating func update(_ width: Double, isResizing: Bool) -> Double? {
        liveWidth = isResizing ? width : nil
        return isResizing ? nil : width
    }

    mutating func finish() -> Double? {
        defer { liveWidth = nil }
        return liveWidth
    }
}

/// Shared grip and full-size pointer target for sidebar and page dividers.
struct ChromeResizeHandle: View {
    let isResizing: Bool
    var axis: Axis = .horizontal
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .frame(width: axis == .horizontal ? 12 : nil, height: axis == .vertical ? 12 : nil)
            .contentShape(Rectangle())
            .overlay {
                Capsule().fill(.primary.opacity(isResizing ? 0.18 : (isHovered ? 0.32 : 0.24)))
                    .frame(width: axis == .horizontal ? 2 : 40, height: axis == .horizontal ? 40 : 2)
                    .allowsHitTesting(false)
            }
            .onHover { hovering in
                guard isHovered != hovering else { return }
                isHovered = hovering
                if hovering { (axis == .horizontal ? NSCursor.resizeLeftRight : .resizeUpDown).push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHovered { NSCursor.pop() }
                isHovered = false
            }
    }
}

struct SidebarResizeHandle: View {
    @Binding var width: Double
    @Binding var isResizing: Bool
    @State private var initialWidth: Double?

    var body: some View {
        ChromeResizeHandle(isResizing: isResizing)
            .offset(x: 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if initialWidth == nil { initialWidth = width; isResizing = true }
                    let proposed = min(BrowserChrome.sidebarMaximumWidth,
                                       max(BrowserChrome.sidebarMinimumWidth, (initialWidth ?? width) + value.translation.width))
                    if width != proposed { width = proposed }
                }
                .onEnded { _ in initialWidth = nil; isResizing = false })
            .onDisappear {
                initialWidth = nil
                isResizing = false
            }
            .help("Drag to resize the sidebar")
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(BrowserChrome.sidebarMaximumWidth, width + BrowserChrome.edgeInset)
                case .decrement: width = max(BrowserChrome.sidebarMinimumWidth, width - BrowserChrome.edgeInset)
                @unknown default: break
                }
            }
    }
}
