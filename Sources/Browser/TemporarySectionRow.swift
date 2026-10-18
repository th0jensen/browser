import AppKit
import SwiftUI

/// Temporary groups use the same disclosure, row metrics and child indentation
/// as saved folders, while remaining ordinary session tabs.
struct TemporarySectionRow: View {
    let browser: BrowserModel
    let section: TemporaryTabSection
    let height: CGFloat
    let horizontal: Bool
    @State private var hovered = false
    private var expanded: Bool { browser.sectionIsExpanded(section) }
    private var dragging: Bool { browser.tabDrag.payload == SidebarDragItem.section(section.id).payload }
    private var targeted: Bool { browser.tabDrag.isOver("browser-section:\(section.id.uuidString)") }

    var body: some View {
        Button { browser.setTemporarySectionExpanded(section.id, expanded: !section.isExpanded) } label: {
            HStack(spacing: 7) {
                Image(systemName: section.symbol).frame(width: 14, height: 14)
                Text(section.title).font(.system(size: horizontal ? 10 : 12.5, weight: .medium))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(.secondary).opacity(hovered || !expanded ? 1 : 0.4)
                    .frame(width: horizontal ? 8 : 12)
            }
            .padding(.horizontal, horizontal ? 2 : BrowserChrome.edgeInset)
            .frame(height: height).frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius))
        }
        .buttonStyle(.plain)
        .background(targeted ? Color.accentColor.opacity(0.18) : hovered ? Color.primary.opacity(0.055) : .clear,
                    in: RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius))
        .modifier(ActiveTabGlass(isActive: dragging, shape: RoundedRectangle(cornerRadius: height / 2)))
        .onHover { hovered = $0 }
        .help(section.title)
        .accessibilityLabel("\(section.title), \(expanded ? "expanded" : "collapsed") tab group")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .contextMenu {
            Button(section.isExpanded ? "Collapse Group" : "Expand Group") {
                browser.setTemporarySectionExpanded(section.id, expanded: !section.isExpanded)
            }
            Divider()
            Button("Pin as Folder") { browser.pinTemporarySection(section.id) }
                .disabled(!browser.canPinTemporarySection(section.id))
            Button("Remove Group, Keep Tabs") { browser.removeTemporarySection(section.id) }
        }
        .modifier(TabDragSource(controller: browser.tabDrag, payload: SidebarDragItem.section(section.id).payload,
                                axis: horizontal ? .horizontal : .vertical, began: {
            if !horizontal { browser.chromeHover?.sidebarIsReordering = true }
        }, ended: { target in
            browser.finishDraggedTab(SidebarDragItem.section(section.id).payload, over: target)
            browser.chromeHover?.sidebarIsReordering = false
        }, crossed: { target, direction in
            browser.crossDraggedTab(SidebarDragItem.section(section.id).payload, past: target, direction: direction)
        }))
    }
}
