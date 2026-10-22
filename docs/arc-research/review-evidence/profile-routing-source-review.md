# Automated independent source review

This is the final response from a separate read-only assistant invocation. It is not human GitHub review, native acceptance or release approval. See the [validation receipt](profile-routing.json) for the separate compiler/XCTest results and exact shared-file scope.

Source review of frozen candidate 99a48e4f (arc-link-routing worktree). Scope: `LinkRouteRules.swift`, `ExternalURLRouter.swift`, `BrowserModel.swift` (selectable/profile/space sections), `BrowserSpaces.swift`, `SpaceSwitcher.swift`, `SpaceSelectorProfileContext.swift`, `TabStrip.swift`, `BrowserApp.swift`, and both named presentation/routing tests. No files changed, no builds/tests run.

Severity summary: no concrete compilation or source-level correctness/safety blocker established. The reviewed invariants are represented coherently. Native deployment, actual WebKit/profile-resource loading, and cross-window desktop behavior remain unverified by source review and injected-test coverage.

Concrete checks:

- Link routing (`LinkRouteRules.swift`, `ExternalURLRouter.swift:93`):
  - `LinkRouteDestination` is descriptor-only: it reads `spaces.loadFailed`, `spaces.space`, `spaces.profiles.loadFailed`, and `spaces.profiles.profile`; it never requests resources. `all(in:)` returns no destinations when Spaces loading failed.
  - `LinkRouteRuleStore.firstMatch` remains first-match only; unavailable destinations fall back instead of advancing to later rules. `drain` records each ordinary window’s original `activeSpaceID` before routing and restores fallback only when `selectedRule` is false, so mixed unmatched/file links do not inherit a prior rule’s selected Space.
  - URLs are filtered through `canOpen`, stored in `pendingURLs`, removed before `openTabs`, and not replayed by late `register`/`unregister`; URL strings are passed through unchanged.
  - The `target.selectSpace(rule.destinationSpaceID)` gate plus `LinkRouteDestination.isAvailable` check preserves immutable Space/profile ownership and lazy profile pages.

- Browser model (`BrowserModel.swift:601-636`):
  - `selectableSpaces` applies one Space-filtering definition, based on profile existence, to sidebar, settings counting, and command-menu indexing. `selectSpace(at:)` uses that same list; `selectSpace(_:)` revalidates both Space existence and profile existence before side effects.
  - `createSpace` remains profile-gated and selects only after successful store creation. Existing tab ownership is not mutated during Space switches.

- Space selector (`SpaceSwitcher.swift`, `SpaceSelectorProfileContext.swift`):
  - Default-only context semantics match the intended compatibility behavior: `hasNamedProfiles` is false, so profile titles are omitted and a single `Edit Space…` item remains (`testDefaultOnlyContextKeepsExistingLabelsAndSingleEditAction`).
  - Named-profile actions are appended only for the active Space, current profile, non-default owner. `profileActionOwner` rejects stale retained/hidden/disabled menus by checking `enabled`, `showsIndicator`, represented UUID, active ID, owner equality, and non-default profile; clear actions additionally recheck `canClearData`.
  - Exact-owner callback gating is implemented in `SpaceSelectorProfileContext`: captured `owner`, active profile and active Space ID, non-closed/non-private/non-extension window, and positive profile lookup. Tests confirm selection or close prevents retargeting.
  - Profile settings are instantiated in `requestProfileSettings` before sheet presentation and sheet presentation is cleared in `onChange(of: browser.activeSpaceID)`. This is correct as written; no separate cleanup found for the stale optional view variable, but it is not active while dismissed.
  - Native `SpaceSelectorView` keeps independent button hit targets and detaches stale choice buttons during layout. No capsule/theme wash is present in `SpaceChoiceButton`.

- BrowserApp command menu (`BrowserApp.swift:249`):
  - Explicitly verified: the Spaces command range computes `choices = model.selectableSpaces`, binds `space = choices[number - 1]` when in range, and calls `browser?.selectSpace(space.id)`. Thus the displayed Space and invoked action use the same captured `BrowserSpace`/UUID rather than an index-only lookup. Missing-space entries are labeled `"Select Space \(number)"` and disabled.

- TabStrip (`TabStrip.swift:55`):
  - Sidebar visibility/counting uses `browser.selectableSpaces.count`, so unavailable owners do not inflate visibility. The presentation test checks the resulting count behavior.

Tests and remaining gaps:

- `ProfileLinkRoutingTests` and `ProfileSpacePresentationTests` are meaningful and cover descriptor-only labels, injected-store mismatch, missing/unreadable metadata, default-only compatibility, stale-owner rejection, hidden/disabled/dismantled menus, and owner-callback invalidation. They do not take over the desktop in reviewed paths; SwiftUI/native menu tests use `NSApp.sendAction` and could depend on a host environment, which I did not validate.
- Missing/weak coverage to note:
  - No source-level test for `SpaceSwitcher` sheet capture/dismissal across active-Space changes outside injected context behavior.
  - No coverage that BrowserApp’s command-menu action is bound to the same focused `BrowserModel` that produced its label, only to the same Space UUID.
  - No test exercises actual resource loading/non-loading when a route lands on an unavailable first rule and then fallback; tests use stores and callbacks.
  - `ExternalURLRouter` outer reentrancy and pending-state race behavior is inferred from implementation, not directly exercised beyond supplied scenarios.
  - UI/native acceptance remains outside static source review.

Assessment: no concrete blocker identified from source for the stated integration goal. Scope is limited to reviewed files and static behavior; actual native, model, and physical acceptance remain separately required.
