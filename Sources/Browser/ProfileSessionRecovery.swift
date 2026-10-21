import Foundation

typealias SpaceSessionOwnershipResolver = @MainActor (SpaceSession) -> Bool

extension WindowSession {
    /// The top-level tabs/splits are a compatibility copy of the selected Space, not another owner.
    @MainActor
    func removingRecovery(for profileID: UUID,
                          ownershipResolver: SpaceSessionOwnershipResolver = BrowserSpaceStore.shared.owns) -> WindowSession? {
        var result = self
        if let spaceSessions {
            let retained = spaceSessions.filter { space in
                // Unknown or descriptor-mismatched records remain recovery data, even before restore.
                !(space.profileID == profileID && ownershipResolver(space))
            }
            result.spaceSessions = retained
            let active = retained.first { $0.spaceID == activeSpaceID } ?? retained.first
            result.activeSpaceID = active?.spaceID
            result.tabs = active?.tabs ?? []
            result.selectedIndex = active?.selectedIndex ?? 0
            result.splits = active?.splits
            return retained.isEmpty && (unavailableSpaceSessions ?? []).isEmpty ? nil : result
        }

        // Legacy windows implicitly belong to Default only when no explicit owner contradicts that fact.
        let retainedIndices = tabs.indices.filter { index in
            let tab = tabs[index]
            let owner = tab.profileID ?? BrowserProfile.defaultID
            let record = SpaceSession(spaceID: tab.spaceID ?? BrowserSpaceStore.defaultSpaceID,
                                      profileID: owner, tabs: [tab], selectedIndex: 0)
            return owner != profileID || !ownershipResolver(record)
        }
        guard !retainedIndices.isEmpty || !(unavailableSpaceSessions ?? []).isEmpty else { return nil }
        let indices = Dictionary(uniqueKeysWithValues: retainedIndices.enumerated().map { ($0.element, $0.offset) })
        result.tabs = retainedIndices.map { tabs[$0] }
        result.selectedIndex = indices[selectedIndex] ?? 0
        result.splits = splits?.compactMap { split in
            guard let anchor = indices[split.anchorIndex], let focused = indices[split.focusedIndex],
                  split.tabIndices.allSatisfy({ indices[$0] != nil }) else { return nil }
            return .init(id: split.id, tabIndices: split.tabIndices.compactMap { indices[$0] }, anchorIndex: anchor,
                         focusedIndex: focused, orientation: split.orientation, weights: split.weights)
        }
        if result.splits?.isEmpty == true { result.splits = nil }
        return result
    }
}
