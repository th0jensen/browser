import AppKit
import SwiftUI

struct SidebarResizeHandle: View {
    @Binding var width: Double
    @Binding var isResizing: Bool
    @State private var initialWidth: Double?
    @State private var isHovered = false

    var body: some View {
        Color.clear
            .frame(width: BrowserChrome.edgeInset)
            .contentShape(Rectangle())
            .overlay {
                Capsule().fill(.secondary.opacity(isHovered || isResizing ? 0.35 : 0))
                    .frame(width: 2, height: 32)
            }
            .onHover { hovering in
                guard isHovered != hovering else { return }
                isHovered = hovering
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if initialWidth == nil { initialWidth = width }
                    isResizing = true
                    width = min(BrowserChrome.sidebarMaximumWidth,
                                max(BrowserChrome.sidebarMinimumWidth, (initialWidth ?? width) + value.translation.width))
                }
                .onEnded { _ in initialWidth = nil; isResizing = false })
            .onDisappear {
                if isHovered { NSCursor.pop() }
                isHovered = false
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
