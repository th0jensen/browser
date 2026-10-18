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

struct SidebarResizeHandle: View {
    @Binding var width: Double
    @Binding var isResizing: Bool
    @State private var initialWidth: Double?
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .frame(width: 12)
            .contentShape(Rectangle())
            .overlay {
                Capsule().fill(.primary.opacity(isResizing ? 0.8 : (isHovered ? 0.6 : 0.1)))
                    .frame(width: 1, height: 44)
            }
            .onHover { hovering in
                guard isHovered != hovering else { return }
                isHovered = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if initialWidth == nil { initialWidth = width; isResizing = true }
                    let proposed = min(BrowserChrome.sidebarMaximumWidth,
                                       max(BrowserChrome.sidebarMinimumWidth, (initialWidth ?? width) + value.translation.width))
                    if width != proposed { width = proposed }
                }
                .onEnded { _ in initialWidth = nil; isResizing = false })
            .onDisappear {
                if isHovered { NSCursor.pop() }
                isHovered = false
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
