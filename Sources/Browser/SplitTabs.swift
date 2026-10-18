import AppKit
import SwiftUI

enum SplitOrientation: String, Codable, Sendable {
    case horizontal, vertical
    var symbol: String { self == .horizontal ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

struct SplitTabGroup: Identifiable, Equatable, Sendable {
    static let limit = 2
    let id: UUID
    var tabIDs: [UUID]
    var anchorID: UUID
    var focusedID: UUID
    var orientation: SplitOrientation
    var weights: [Double]

    static func normalizedWeights(_ weights: [Double], count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard weights.count == count, weights.allSatisfy({ $0.isFinite && $0 > 0 }),
              weights.reduce(0, +).isFinite else { return Array(repeating: 1 / Double(count), count: count) }
        let total = weights.reduce(0, +)
        // Corrupt or extreme saved sizes must never make a pane disappear.
        guard weights.allSatisfy({ $0 / total >= 0.05 }) else { return Array(repeating: 1 / Double(count), count: count) }
        return weights.map { $0 / total }
    }
}

extension BrowserModel {
    func restoreSplits(_ saved: [BrowserSessionSnapshot.Split]) {
        var used = Set<Int>()
        var groupIDs = Set<UUID>()
        splits = saved.compactMap { entry in
            let savedIndices = entry.tabIndices
            guard (2...4).contains(savedIndices.count), Set(savedIndices).count == savedIndices.count,
                  savedIndices.allSatisfy({ tabs.indices.contains($0) && !used.contains($0) }),
                  savedIndices.contains(entry.anchorIndex), savedIndices.contains(entry.focusedIndex),
                  groupIDs.insert(entry.id).inserted else { return nil }
            // Older sessions may contain four panes. Keep the anchor and focused
            // page together, returning the others to individual tab items.
            let companion = entry.focusedIndex != entry.anchorIndex ? entry.focusedIndex : savedIndices.first { $0 != entry.anchorIndex }!
            let indices = savedIndices.filter { $0 == entry.anchorIndex || $0 == companion }
            let weights = savedIndices.enumerated().filter { indices.contains($0.element) }.map {
                entry.weights.indices.contains($0.offset) ? entry.weights[$0.offset] : 1
            }
            used.formUnion(indices)
            return SplitTabGroup(id: entry.id, tabIDs: indices.map { tabs[$0].id }, anchorID: tabs[entry.anchorIndex].id,
                                 focusedID: tabs[entry.focusedIndex].id, orientation: entry.orientation,
                                 weights: SplitTabGroup.normalizedWeights(weights, count: indices.count))
        }
    }

    var activeSplit: SplitTabGroup? { split(containing: activeTabID) }
    var visibleTabIDs: Set<UUID> { Set(activeSplit?.tabIDs ?? activeTabID.map { [$0] } ?? []) }

    func split(containing id: UUID?) -> SplitTabGroup? {
        guard let id else { return nil }
        return splits.first { $0.tabIDs.contains(id) }
    }

    func isSplitCompanion(_ tab: BrowserTab) -> Bool {
        split(containing: tab.id).map { $0.anchorID != tab.id } ?? false
    }

    func splitIsActive(_ tab: BrowserTab) -> Bool {
        activeTabID == tab.id || activeSplit?.tabIDs.contains(tab.id) == true
    }

    func selectRepresentedTab(_ tab: BrowserTab) {
        activeTabID = split(containing: tab.id)?.focusedID ?? tab.id
    }

    func closeRepresentedTab(_ tab: BrowserTab) {
        closeTab(split(containing: tab.id)?.focusedID ?? tab.id)
    }

    @discardableResult
    func makeSplit(_ sourceID: UUID, with targetID: UUID, orientation: SplitOrientation = .horizontal, placement: SplitEdge? = nil) -> Bool {
        guard sourceID != targetID, tab(withID: sourceID) != nil, tab(withID: targetID) != nil else { return false }
        let source = split(containing: sourceID)
        let target = split(containing: targetID)
        guard source == nil || source?.id != target?.id else { return false }
        let sourceIDs = source?.tabIDs ?? [sourceID]
        let targetIDs = target?.tabIDs ?? [targetID]
        let ids = placement?.leading == true ? sourceIDs + targetIDs : targetIDs + sourceIDs
        guard ids.count <= SplitTabGroup.limit, Set(ids).count == ids.count else { return false }
        let replaced = Set([source?.id, target?.id].compactMap { $0 })
        splits.removeAll { replaced.contains($0.id) }
        let sourceWeights = (source?.weights ?? [1]).map { $0 / 2 }
        let targetWeights = (target?.weights ?? [1]).map { $0 / 2 }
        let weights = placement == nil ? Array(repeating: 1 / Double(ids.count), count: ids.count)
            : placement?.leading == true ? sourceWeights + targetWeights : targetWeights + sourceWeights
        let group = SplitTabGroup(id: target?.id ?? UUID(), tabIDs: ids, anchorID: target?.anchorID ?? targetID,
                                  focusedID: targetID, orientation: placement?.orientation ?? target?.orientation ?? orientation,
                                  weights: weights)
        splits.append(group)
        activeTabID = targetID
        restoreVisibleSplit()
        BrowserSessionStore.shared.save(self)
        return true
    }

    func restoreVisibleSplit() {
        guard let group = activeSplit else { return }
        if let index = splits.firstIndex(where: { $0.id == group.id }), let activeTabID {
            splits[index].focusedID = activeTabID
        }
        for id in group.tabIDs { tab(withID: id)?.restore() }
    }

    func separateSplit(_ id: UUID) {
        splits.removeAll { $0.id == id }
        BrowserSessionStore.shared.save(self)
    }

    func removeSplitPane(_ tabID: UUID) {
        guard let group = split(containing: tabID), let index = splits.firstIndex(where: { $0.id == group.id }) else { return }
        if let paneIndex = splits[index].tabIDs.firstIndex(of: tabID), splits[index].weights.indices.contains(paneIndex) {
            splits[index].weights.remove(at: paneIndex)
        }
        splits[index].tabIDs.removeAll { $0 == tabID }
        pruneSplits()
        if activeTabID == tabID { activeTabID = group.tabIDs.first { $0 != tabID } }
        BrowserSessionStore.shared.save(self)
    }

    func pruneSplits() {
        let live = Set(tabs.map(\.id))
        splits = splits.compactMap { original in
            var group = original
            let retained = group.tabIDs.enumerated().filter { live.contains($0.element) }
            group.tabIDs = retained.map(\.element)
            guard group.tabIDs.count >= 2 else { return nil }
            if !group.tabIDs.contains(group.anchorID) { group.anchorID = group.tabIDs[0] }
            if !group.tabIDs.contains(group.focusedID) { group.focusedID = group.tabIDs[0] }
            group.weights = SplitTabGroup.normalizedWeights(retained.map { original.weights.indices.contains($0.offset) ? original.weights[$0.offset] : 1 }, count: group.tabIDs.count)
            return group
        }
    }

    func setSplitOrientation(_ id: UUID, _ orientation: SplitOrientation) {
        guard let index = splits.firstIndex(where: { $0.id == id }) else { return }
        splits[index].orientation = orientation
    }

    func setSplitWeights(_ id: UUID, _ weights: [Double]) {
        guard let index = splits.firstIndex(where: { $0.id == id }) else { return }
        splits[index].weights = SplitTabGroup.normalizedWeights(weights, count: splits[index].tabIDs.count)
    }

    func reverseSplit(_ id: UUID) {
        guard let index = splits.firstIndex(where: { $0.id == id }) else { return }
        splits[index].tabIDs.reverse()
        splits[index].weights.reverse()
    }

    func canSplitDrag(_ source: String, with target: String) -> Bool {
        guard source != target, let a = SidebarDragItem(source), let b = SidebarDragItem(target),
              isPageDrag(a), isPageDrag(b) else { return false }
        let sourceTab = existingDragTab(a)
        let targetTab = existingDragTab(b)
        if let sourceTab, let targetTab, sourceTab.id == targetTab.id { return false }
        let first = sourceTab.flatMap { split(containing: $0.id) }
        let second = targetTab.flatMap { split(containing: $0.id) }
        if let first, first.id == second?.id { return false }
        return (first?.tabIDs.count ?? 1) + (second?.tabIDs.count ?? 1) <= SplitTabGroup.limit
    }

    private func isPageDrag(_ item: SidebarDragItem) -> Bool {
        switch item {
        case .tab(let id): return tab(withID: id) != nil
        case .pinned(let id): return folders.item(id)?.kind == .page
        case .essential(let id): return pinnedPages.items.contains { $0.id == id }
        default: return false
        }
    }

    func existingDragTab(_ item: SidebarDragItem) -> BrowserTab? {
        switch item {
        case .tab(let id): tab(withID: id)
        case .pinned(let id): tabs.first { $0.folderPageID == id }
        case .essential(let id): tabs.first { $0.pinnedPageID == id }
        default: nil
        }
    }
}

/// The combined sidebar item follows Arc's compact icon/title | icon/title layout.
struct SplitTabLabel: View {
    let browser: BrowserModel
    let split: SplitTabGroup
    var showsCloseButtons = false
    @AppStorage(AppearancePreferences.dimInactiveSplitsKey) private var dimInactive = true
    @AppStorage(AppearancePreferences.inactiveSplitOpacityKey) private var inactiveOpacity = 0.85
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(split.tabIDs.enumerated()), id: \.element) { index, id in
                if index > 0 { Rectangle().fill(.primary.opacity(0.16)).frame(width: 1, height: 14) }
                if let tab = browser.tab(withID: id) {
                    HStack(spacing: 5) {
                        Button {
                            browser.activeTabID = id
                            browser.window?.makeFirstResponder(tab.webView)
                        } label: {
                            HStack(spacing: 5) {
                                SplitSiteIcon(url: tab.url, size: 13)
                                Text(tab.title).font(.system(size: 12.5, weight: browser.activeTabID == id ? .medium : .regular))
                                    .tracking(-0.1).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if showsCloseButtons {
                            TabDismissButton(tab: tab) { browser.closeTab(id) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(browser.activeSplit?.id == split.id && browser.activeTabID != id
                             ? AppearancePreferences.splitOpacity(inactiveOpacity, dimmed: dimInactive) : 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split View: " + split.tabIDs.compactMap { browser.tab(withID: $0)?.title }.joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if let tab = browser.tab(withID: split.anchorID) { browser.selectRepresentedTab(tab) } }
    }
}

struct SplitSiteIcon: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        if let url { SiteIcon(url: url, size: size) }
        else { Image(systemName: "globe").resizable().scaledToFit().frame(width: size, height: size) }
    }
}

struct SplitTabMenu: View {
    let browser: BrowserModel
    let tab: BrowserTab
    var body: some View {
        if let split = browser.split(containing: tab.id) {
            Button("Separate All Tabs") { browser.separateSplit(split.id) }
            Menu("Remove from Split View") {
                ForEach(split.tabIDs, id: \.self) { id in
                    if let page = browser.tab(withID: id) {
                        Button(page.title) { browser.removeSplitPane(id) }
                    }
                }
            }
            Menu("Split Layout") {
                Button("Side by Side", systemImage: SplitOrientation.horizontal.symbol) { browser.setSplitOrientation(split.id, .horizontal) }
                Button("Top and Bottom", systemImage: SplitOrientation.vertical.symbol) { browser.setSplitOrientation(split.id, .vertical) }
                Divider()
                Button("Swap Panels") { browser.reverseSplit(split.id) }
                Button("Balance Panels") { browser.setSplitWeights(split.id, Array(repeating: 1, count: split.tabIDs.count)) }
            }
            Divider()
        } else if browser.tabs.contains(where: { $0.id != tab.id }) {
            Menu("Split View with") {
                ForEach(browser.tabs.filter { $0.id != tab.id && !browser.isSplitCompanion($0) }) { other in
                    Button(other.title) { browser.makeSplit(other.id, with: tab.id) }
                        .disabled(!browser.canSplitDrag(other.id.uuidString, with: tab.id.uuidString))
                }
            }
            Divider()
        }
    }
}

/// Only the center of a row combines tabs, leaving its edges for reordering.
struct TabSplitTarget: ViewModifier {
    let browser: BrowserModel
    let payload: String
    var axis = TabReorderController.Axis.vertical
    var enabled = true
    @State private var owner = UUID()
    private var target: String { TabReorderController.splitPrefix + payload }
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                guard enabled else { return }
                let middle = axis == .vertical ? frame.insetBy(dx: 0, dy: frame.height * 0.27)
                    : frame.insetBy(dx: frame.width * 0.27, dy: 0)
                browser.tabDrag.register(target, frame: middle, axis: axis, priority: 3, owner: owner)
            }
            .overlay {
                if browser.tabDrag.splitTarget == target {
                    RoundedRectangle(cornerRadius: BrowserChrome.contentCornerRadius)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onDisappear { browser.tabDrag.unregister(target, owner: owner) }
    }
}

/// Paint after every row and drag source, independent of row ordering or nesting.
struct SplitDropBadge: ViewModifier {
    let controller: TabReorderController
    var enabled = true
    func body(content: Content) -> some View {
        content.overlay {
            GeometryReader { geometry in
                let bounds = geometry.frame(in: .global)
                if enabled, let target = controller.splitTargetFrame, bounds.contains(CGPoint(x: target.midX, y: target.midY)) {
                    Label("Split", systemImage: "rectangle.split.2x1")
                        .font(.system(size: 10, weight: .semibold)).padding(5)
                        .background(.regularMaterial, in: Capsule())
                        .position(x: target.maxX - bounds.minX - 30, y: target.midY - bounds.minY)
                }
            }.allowsHitTesting(false)
        }
    }
}
