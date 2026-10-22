# Arc reference and implementation audit

> Historical source/reference audit snapshot. Published by the coordinator after the read-only audit. Follow the [implementation queue](arc-implementation.md) for later fixes. This report does not establish native visual acceptance.


## Summary

Read-only audit of the plan and ten implementation worktrees. Source snapshot: 21 October 2026, about 01:39 UTC. Spaces and Command Bar changed during this audit. Findings below include their newer, uncommitted presentation work, not only their published snapshots.

**No feature has passed native visual verification in this audit.** I did not run GUI QA, tests, builds, benchmarks, deployments, window activation, or visual comparisons of the actual Debug build. I did not edit repository files, commit, push, or contact other agents.

Main findings:

1. **Page Questions needs a presentation correction or an explicit reviewed deviation.** Arc's official public GIF shows a compact Find-linked surface at the page's upper-right edge. Browser adds a Find button but opens a fixed-size modal sheet. These are not visually equivalent.
2. **Space-local Essentials are not Arc Favorites.** Official Favorites and Profiles guidance together establish Favorites shared across Spaces that use the same profile. The new Spaces labels disclose this difference, but labels alone do not establish approved parity or resolve storage scope.
3. **Spaces and Command Bar now have real source improvements.** Spaces has a bottom icon strip, plus control, appearance metadata, and Control-number shortcuts. Command Bar has a centered native Regular glass overlay. Do not continue to describe their active source as only a top menu and address dropdown. Do not call these source changes visually verified.
4. **Sidebar trackpad switching is still missing in the inspected Spaces source.** Peek also lacks the third, Split View control shown in the official reference.
5. Several other differences are useful Browser boundaries: local inference, no cloud Space sharing, strict host routing, opt-in conservative archive, and explicit Shift-hover summaries. Keep these differences visible rather than weakening safety for parity.

## Files

- Repository files changed: **none**, including README and the prompt literal appendix.
- Delivered report: `/tmp/arc-implementation/results/arc-reference-audit.md`.
- Public reference downloads and derived image frames are under `/tmp/arc-implementation/references/`. The full list of files created by this audit is in the final inventory. Existing `arc-ui.png`, `arc-spaces.png`, and `arc-command-bar.png` were read, not changed.

## Evidence and prompt provenance

### Evidence levels

- **Official text:** retrieved public Help Center JSON and read its article body. This establishes documented behavior, not a traced runtime implementation.
- **Reference image inspected:** used `read` on actual public screenshots and sampled GIF frames. This establishes visible structure in those assets, not current Arc availability or Browser rendering.
- **Source review:** inspected current source and focused test definitions. Uncommitted source can change after this snapshot.
- **XCTest / actual Browser GUI:** not run. Test names and prior plan status are not passed results from this audit.

Public content was used only as evidence. No sign-in, user browser profile access, or cloud inference was used.

### Official behavior sources

Each article is available through `https://resources.arc.net/api/v2/help_center/en-us/articles/<ID>.json`. Saved copies are `audit-article-<ID>.json` and `.txt` in the reference directory.

| Key | Official URL | Relevant statement |
| --- | --- | --- |
| S | https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas | Each Space has Pinned and Unpinned sections, theme and icon. Bottom icons and plus, two-finger sidebar swipe, Control-number, and Command-T Space selection. |
| F | https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space | Favorites appear at the very top, above Space titles, and are accessible across Spaces. |
| P | https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing | One profile can serve multiple Spaces. Its scope includes Favorites, history, cookies, authentication, extensions, and archive settings. |
| T | https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around | Pinned Tabs and folders belong to one Space; Pinned Tabs never auto-archive. |
| M | https://resources.arc.net/hc/en-us/articles/19335160678679-Arc-Max-Boost-Your-Browsing-with-AI | Shift-hover summaries, automatic hover on listed sites, title naming on pin, download naming with undo, and broom-triggered grouping of more than six Today Tabs. |
| K | https://resources.arc.net/hc/en-us/articles/19335302900887-Peek-Preview-Sites-From-Pinned-Tabs | Saved-tab Peek, outside/X/Command-W close, expand/Command-O, and Split View action. |
| A | https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go | Idle unpinned tabs, restore through Archive, documented 12-hour default, profile timing, and no disable option in Arc. |
| R | https://resources.arc.net/hc/en-us/articles/22932014625431-Air-Traffic-Control-Automate-Your-Link-Routing | Routes in Links settings, URL contains/equality controls, destination Space, default destination, and deletion. |
| C | https://resources.arc.net/hc/en-us/articles/20855018192791-Site-Search-Directly-Search-any-Website | Site search is an implemented Command-T mode, not a decorative chip. |
| Q | https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes | Historical Ask-on-Page updates; explicitly links the Max Ask prompt to CMD-F search/no-match handling. Also documents centered Command Bar in new windows. |

The current Max article body no longer includes an Ask-on-Page section. Its public attachment API still lists `Ask on Page.gif`: `https://resources.arc.net/api/v2/help_center/en-us/articles/19335160678679/attachments.json`. The retained official GIF and 2023 release notes support the historical design comparison. They do **not** prove that Ask on Page is currently enabled in Arc.

### Actual visual references inspected

Paths in this table are relative to `/tmp/arc-implementation/references/`.

| Key | Public image URL and local path | What is visibly established |
| --- | --- | --- |
| V1 | https://miro.medium.com/v2/resize:fit:1400/0*bOB5O74yq9BfWByt.png — `arc-ui.png` | Top icon tiles, saved rows above a divider, temporary rows below, source page dominant, bottom utility controls. Historical screenshot. |
| V2 | https://miro.medium.com/v2/resize:fit:1400/1*hCl6wa0lAZgqKiJuaoYpCQ.png — `arc-spaces.png` | Named, icon-marked, themed Space columns in the **overview**. It is not the sidebar footer switcher. |
| V3 | https://miro.medium.com/v2/resize:fit:1400/1*kn6wEaweuxJ6-jyqAkl1tA.png — `arc-command-bar.png` | One centered floating palette, dominant input, compact strongly selected row, and page visible behind it. The Maps chip belongs to real site search. |
| V4 | https://resources.arc.net/hc/article_attachments/25705829783575 — `audit-ask-on-page.gif`, `audit-ask-on-page-frames.jpg`, `audit-ask-on-page-detail.png` | Small upper-right question/Find field expands in place to an answer card. Page remains visible; Find on Page reveals an orange-highlighted passage while the card remains open. Sampled frames 0, 33, 66, 99, 132. |
| V5 | https://resources.arc.net/hc/article_attachments/25705842733975 — `audit-preview.gif`, `audit-preview-frames.jpg`, `audit-preview-detail.png` | Link-adjacent summary card with publisher image, short lead, and compact points; underlying search page stays visible. Frames 0, 31, 63, 94, 125. |
| V6 | https://resources.arc.net/hc/article_attachments/25705829788695 — `audit-tidy-titles.gif`, `audit-tidy-titles-frames.jpg`, `audit-tidy-titles-detail.png` | Tab moves into a saved folder, becomes a shorter specific title, and shows manual-rename guidance. Frames 0, 30, 61, 91, 121. |
| V7 | https://resources.arc.net/hc/article_attachments/25705842743191 — `audit-tidy-downloads.gif`, `audit-tidy-downloads-frames.jpg`, `audit-tidy-downloads-detail.png` | Bottom-sidebar rename notice shows new and original names with undo. **Also shows actual bottom Space dots and plus**, unlike V2. Frames 0, 23, 47, 70, 93. |
| V8 | https://resources.arc.net/hc/article_attachments/25705842753303 — `audit-tidy-tabs.gif`, `audit-tidy-tabs-frames.jpg`, `audit-tidy-tabs-detail.png` | Broom at temporary-section boundary; topic headings such as Vacuum Shopping, Movies, and San Diego Zoo above compact tab rows. Frames 0, 11, 22, 33, 43. |
| V9 | https://resources.arc.net/hc/article_attachments/25703046476567 — `audit-peek-open.gif`, `audit-peek-open-frames.jpg`, `audit-peek-open-detail.png`; https://resources.arc.net/hc/article_attachments/25703046480151 — `audit-peek-controls.png` | Inset live webpage over source, trailing round close/expand controls, and a reference close/expand/**split** control stack. The full view also shows the actual footer icon strip and plus. Frames 0, 19, 38, 57, 75. |
| V10 | https://resources.arc.net/hc/article_attachments/22932014616343 — `audit-routes.png`; https://resources.arc.net/hc/article_attachments/22931983079063 — `audit-routes-default.png` | Routes panel has condition, text, destination, New Route, delete, and Default control. The second image specifically shows deletion, despite its local basename. |
| V11 | https://resources.arc.net/hc/article_attachments/20678079725079 — `audit-archive.png` | Profile settings and archive timing, **not an archive results list**. |
| V12 | https://resources.arc.net/hc/article_attachments/20677900113815 — `audit-profile-menu.png`; https://resources.arc.net/hc/article_attachments/20677884325527 — `audit-profile-delete.png` | Profile assignment in the Space edit menu; deletion only when unassigned. No evidence here for Browser's creation-sheet layout. |
| V13 | https://resources.arc.net/hc/article_attachments/22108506665239 and https://resources.arc.net/hc/article_attachments/23320854863895 — `audit-archive-windows-menu-old-frames.jpg`, `audit-archive-clear-frames.jpg` | Windows archive menu/clear flows, not macOS restore-list design. These must not be used to certify Browser's archive sheet. |

The Medium article was also read through `https://r.jina.ai/https://medium.com/design-bootcamp/arc-your-space-on-internet-91f54771f245` (`audit-medium.txt`). Its 7 August 2023 date matters. It calls top cross-Space tiles “Pinned tabs” informally; official F/T/P guidance is more precise and controls the scope decision.

Prompt provenance: naming source labels its P01/P02-inspired contracts **reconstructed local contracts**, not exact recovered prompts. Page Questions labels its P06/P07-inspired design the same way. The Tidy grouping prompt remains Browser design; no exact Arc grouping prompt was recovered. Source validation of block IDs verifies excerpt membership, not that every generated sentence logically follows from the excerpts. Do not claim guaranteed factual answers. No literal appendix was modified.

## Behavior: per-feature matrix

Source paths below are relative to `/Users/thomas/opt/browser-worktrees/arc-<feature>/Sources/Browser/`. Branches are `pi-agent/arc-<feature>`. All native checks in the last column remain pending.

| Feature; official / visual evidence | Current branch/source | Matching source behavior/design | Concrete gaps | Deliberate Browser adaptation | Required native screenshot/interaction states |
| --- | --- | --- | --- | --- | --- |
| **Spaces**; S, V1/V2/V7/V9 | `spaces`: `SpaceSwitcher.swift` (`iconStrip`, `BrowserSpaceHeading`), `BrowserSpaces.swift`, `TabStrip.swift:158–225`, `BrowserApp.swift` Spaces commands | New bottom strip outside tab scroller; plus; selected outline; hover names; accessibility labels/selection; overflow menu; stable icon/theme with legacy defaults; Control-1…9. Existing switch retains tab objects and splits. | No sidebar two-finger swipe handler found. Space-only selection through Command-T is absent in the inspected command engine. Actual layout/focus/contrast unknown. | Restrained semantic tint and Regular glass; horizontal layout keeps menu fallback; one Existing Profile foundation is stated honestly. No Share Space placeholder. | Multiple themed Spaces; selected/hover/focused icons; many Spaces and narrow overflow; creation/edit; real trackpad swipe; Control-number from webpage; saved/temporary sections; split and form state after switching. |
| **Favorites / Essentials scope**; F/P/T, V1/V6/V7 | `spaces`: `BrowserModel.swift:32–42`, `BrowserSpaces.swift` `pinnedPages(for:)`, `PinnedPagesGrid.swift`; `profiles`: same store path and `docs/profiles.md` | Top tiles and Space-local saved folders match the visible hierarchy. New Spaces label says “Space Essentials” and help explicitly says these are not cross-Space Favorites. | Essentials still use `Spaces/<Space ID>/` stores. This is not Arc's profile-shared Favorites scope. Profile branch still carries older labels/UI. | Keeping Space Essentials is possible **only as an explicit reviewed product deviation**, not Favorites parity. Do not silently duplicate or move saved data. | Two Spaces in one profile, then another profile and private window; show tile membership and persistence. If profile Favorites are chosen, verify shared membership without cookie/profile leakage. |
| **Command Bar**; S/C/Q, V3 | `command-bar`: new `CommandPalette.swift`, `AddressResults.swift`, `BrowserModel.swift` `showCommandPalette`, `BrowserWindow.swift` `CommandPaletteHost`, `BrowserApp.swift:140` | Active revision has page-area-centered `NSGlassEffectView(.regular)`, 22-point native input, 42-point results, native selection, action/Space context, visible page, Escape/outside close. Command-T requests presentation without creating a tab. Exact tab identity and stale-action checks remain. | New presentation is untested here. Sidebar New Tab and strip context menu still call `addTab()` instead of palette. Commands are only New Tab/Reopen/Reload/History: no direct Space selection, View Archive, or Link Preferences action yet. | Command-L remains normal address editing. No fake Maps chip, typing inference, or cloud ChatGPT dependency. Explicit blank-tab command may create a tab; simply opening/dismissing palette must not. | Empty/open palette over a live page; URL/search/tab/saved/command rows; strong selection; IME; Return and arrows; Escape/outside-click focus; no phantom tab; stale row with Peek open; narrow layout, hidden toolbar, split page, private results. |
| **Peek gesture**; K, V9 | `peek-gesture`: `PageLinkIntent.swift`, `PageDelegate.swift`, `BrowserModel.swift`, existing `PeekPage.swift` | Shift-left-click live Peek, Command/middle-click precedence, new-window configuration path, inset page, round trailing close/expand, outside/Escape/Command-W, Command-O expansion. Expansion retains the page object. | Official reference shows Split View control; Browser has only close and expand. Do not call full controls parity. Shift-click trigger is local design supported by recovered copy, not a verified current Arc runtime rule. | Public WebKit configuration/profile ownership; two-pane limit; Regular glass controls rather than opaque legacy circles. | Trusted physical Shift-click for normal and target-blank links; Command-Shift/middle/Option-download; no duplicate load; close/outside/Escape; expansion preserving scroll/form/history; private-profile ownership; focus and Reduce Motion. |
| **Preview safety**; M, V5 | `preview-safety`: `LinkPreviewExtraction.swift`, `LinkPreviews.swift`, `LinkPreviewCard.swift` | Image-first link-adjacent summary and points; semantic foreground; actual native Regular glass; source URL and Open Page; bounded static extraction; blocked/login/short-text/error states; cancellation. | No reference screenshot certifies Browser's failure layout. Browser image is fixed at 100 points while Arc reference shows its own image ratio; density and cropping need comparison. No claim of identical automatic-site triggers. | Explicit Shift-hover only; cookie-free fetch and on-device summary; retained draggable session notes; visible source/failure rather than challenge bypass. | Same link loading → image → streaming text → success; blocked/login/short/timeout; long scrollable card; source-link hover bridge; source navigation/deactivation cancellation; drag to note; keyboard focus and native action menus. |
| **Tidy undo**; M, V8 | `tidy-undo`: `TabStrip.swift` tidy divider, `BrowserModel.swift` `TidyUndoSnapshot`/`undoTidyTabs`, `BrowserApp.swift` | Broom at temporary boundary, subject headings, more-than-six eligibility, cancellation, one-step visible Undo, no conversion to saved folders. Value snapshot preserves later edits and new tabs. | Browser New Tab row sits after temporary groups, while V8 puts New Tab above them. Group density, selection and Undo discoverability are unverified. | Reversible local subject grouping; no claim of recovered Arc grouping prompt or identical animation. | Seven-plus temporary tabs plus saved tabs; before/working/after/Undo; collapsed groups; new tab/manual rename/navigation/close after grouping; keyboard-only Undo; Reduce Motion. |
| **Archive**; A/P, V11/V13 (limited) | `tab-archive`: `TabArchiveView.swift`, `TabArchive.swift`, `ArchivePageWork.swift`, `BrowserModel.swift:1123+` | Searchable descriptor list, Restore, Undo, durable write before removal, owner checks, conservative active/unknown-work exclusions, lazy results. | Sheet is current-Space-only; timing toggle is one shared snapshot rather than per profile. No View Archive command result yet. **No comparable macOS archive-list image was found in retrieved references.** V11/V13 do not fill that gap. | Off by default; one idle day, grace period and bounded passes, not Arc's mandatory documented 12-hour default. Recovery cleanup is a real implemented action, not a placeholder. | Empty/searched/populated Archive; Restore and Undo; ownership context; save failure; read-only background tab eligible, visible/saved/media/editor/upload protected; private absence. Treat appearance as pending, not matched from a settings image. |
| **Page Questions**; Q and retained M attachment, V4 | `page-answers`: `FindBar.swift:45–50`, `BrowserWindow.swift:158`, `PageQuestions.swift:319+`, `BrowserIntelligence.swift` `answerPage` | Visible Find entry, explicit question, local typed answer, source excerpts, bounded memory-only capture, source-reveal action and stale-navigation cancellation. | A **540×480 modal sheet** replaces Arc's compact upper-right Find-linked card. Separate question editor does not reuse Find text. Reveal dismisses Browser's answer, while V4 keeps the card beside the highlighted source. Find bar uses `.regularMaterial`, not proof of Regular Liquid Glass. | Local-only inference, clear limits, insufficient-evidence refusal, checked block IDs, no unsupported guess. Keep these when changing presentation. | Find no-match → Ask; compact question/loading/answer; source highlight while answer stays available if revised; empty/unsupported/unavailable model; cancel/repeat; same-URL reload; tab/split change; Escape and restored native focus. |
| **Link routing**; R, V10 | `link-routing`: `SettingsLinkRouting.swift`, `LinkRouteRules.swift`, `ExternalURLRouter.swift` | Real host/destination editor, ordered rules, add/edit/delete, first-match policy, visible fallback explanation; skips private destinations and rejects substring attacks. | Native Form plus editor sheet, not Arc's inline panel; no Default destination picker or Little Arc; external-app links only. Profile destination support remains limited to Existing Profile. No visible per-open matched-rule indication found. | Exact normalized hosts and explicit subdomains instead of weak URL contains; no guessed source app; no model; preserve complete destination URL. Do not weaken matching to copy Arc. | Two ordered rules; add/edit/delete/reorder; subdomain on/off; invalid host; deleted/foreign destination fallback; one external delivery during launch; private window present; destination Space visibly selected. |
| **Profiles**; P/F, V12 and V11 | `profiles`: `PersistentProfiles.swift`, `BrowserProfile.swift`, `SpaceSwitcher.swift`, `ProfileDataViews.swift`, `docs/profiles.md` | New Space has existing/new profile picker; named website stores, per-profile resources, immutable page owner, lazy restore and fail-closed unknown owners. UI explains shared-profile logins and missing capabilities. | Profile assignment is only at creation; no profile rename/delete. Extensions/autofill stay Existing Profile; app preferences remain shared. Top menu is an older parent, not the new Spaces footer. Favorites and archive timing are not yet Arc-profile scoped. | WebKit stores instead of Chromium; no cross-profile live-tab transfer; Debug stores remain nonpersistent; no implied separate macOS account. | Two Spaces sharing one profile versus another profile; same-host cookies/storage/history; late background permissions; profile picker and unavailable owner; private mode; clear-data scope; new footer integration. Login claims need interaction evidence, not a menu screenshot. |
| **Title naming**; M, V6 | `ai-naming`: `NamingPolicy.swift`, `BrowserIntelligence.swift`, existing saved-row rename controls | Naming on saved tab, short/cleaned candidates, deterministic identity safeguards, manual/original names remain authoritative; safe fallback after model failure. | No visual comparison of selected/renamed saved row or Restore Original. Local validators may retain longer titles than Arc example; this is not a failure by itself. | Input language retained, bounded local prompt and queue, no forced translation or identity-losing word limit. | Long title → saved row → automatic label; manual rename during inference; original-name restore; unavailable/failing model; non-Latin and long proper nouns. |
| **Download naming**; M, V7 | `ai-naming`: `NamingPolicy.swift`, `BrowserIntelligence.swift`, `Downloads.swift`; existing `DownloadsButton.swift:95–112` | Completed download naming, original-name state, click-name undo, real Restore Original action, collision/extension/quarantine safeguards. | Browser uses a toolbar download popover, not Arc's bottom-sidebar rename notice. Do not call identical placement. Rename feedback may be less discoverable with popover closed. | Model supplies stem only; no file-content inference or destination authority; preserve informative names and versions. | Complete → naming → renamed row; click-name undo; original filename visible in help; collision/error; compound extension; cancellation/manual destination changes; closed versus open downloads popover. |

### Plan verification

The delivery sequence remains sound: ownership before routing/archive, durable restore before automatic removal, and bounded local inference. Official references do not justify changing these safety gates.

The plan needs these explicit decisions or additions before acceptance:

- Stage 2 must resolve **profile-shared Favorites versus Space Essentials**. The earlier `essentialPageIDs` per-Space sketch was not evidence of Arc scope. New labels make a deviation honest, but the coordinator must approve that deviation or plan a safe profile-level Favorite store.
- Stage 3 must retain the new centered surface requirement, not accept a tested local result engine as UI completion. Add direct Space selection and integrate real Archive/Link Preferences commands when their modules are available. Do not show dead rows in advance.
- Stage 5 should name the **Find-linked, page-visible question/answer surface**, not only an explicit page action. Keep all existing cancellation and citation checks during that presentation change.
- Arc's archive default is now documented publicly. The research's statement that its default was unknown can be narrowed to unknown runtime exclusions/algorithm. Browser's opt-in one-day policy is still a deliberate safety choice, not a recovered Arc default.
- Profiles should not inherit an older Spaces view at integration and erase the new footer, icon/theme metadata, or honest Essential labels.

## Highest-priority remaining design gaps

1. **Page Questions surface (high).** V4 directly shows the useful page/answer/source hierarchy that the modal sheet loses. Correct the presentation within the existing owner, or record an approved deviation. A Find button that opens an unrelated sheet does not satisfy the visual contract.
2. **Favorite scope decision (high).** F + P + T resolve the official relationship: profile-shared Favorites, Space-local Pinned Tabs. Do not endorse per-Space Essential tiles as Arc Favorites. The new disclosure is an improvement, not a scope migration or approval.
3. **Finish and verify active Spaces/Command Bar revisions (high).** New placement exists in source. Native selection, focus, glass contrast, overflow, and dismissal still need comparable screenshots and interactions. Spaces trackpad switching is absent; Command Bar entry points and commands are not yet unified.
4. **Prevent parent-branch presentation regressions (high integration risk).** Profiles still edits the old `SpaceSwitcher` and `BrowserSpaces` shapes; Archive and Routing also carry older Spaces parents. Merge by behavior and ownership contract, not by choosing an entire file from one branch.
5. **Peek Split action and secondary hierarchy differences (medium).** Either implement the real Split control safely or list the omission. Tidy's New Tab placement and download feedback location need explicit acceptance rather than false placement parity.

### Placeholder and false-parity check

No new fake Share Space link, fake site-search chip, or unimplemented route editor action was found in the inspected feature surfaces. The initial Space menu and address-results UI were real working controls, but were not visually adequate substitutes; active source now improves them.

Do not use these claims:

- “Spaces verified” from V2's overview image or a mouse drag.
- “Command Bar verified” from action-engine tests alone.
- “Favorites match Arc” for Space-local Essentials.
- “Ask on Page matches Arc” because both can answer questions.
- “Archive list matches Arc” from a profile timing screenshot or Windows Clear Archive GIF.
- “Profile parity” while named-profile extensions/autofill and profile Favorites/timing are absent.

These are scope limits, not requests to add unsafe cloud sharing, remote inference, fake controls, or URL-substring routing.

## Tests run and results

**No test command was run.** `just test`, `just qa`, builds, parsing/typechecking, and GUI tools were deliberately not invoked because this task is read-only. There is no new pass/fail result or actual Debug-build screenshot comparison from this audit.

Source checks used `read`, bounded `rg`, `git diff`, `git status --short`, `git branch --show-current`, and `git rev-parse --short HEAD`. Public retrieval used bounded Python `urllib.request.urlopen(..., timeout=20/25)` reads and `curl -L --max-time 25 --max-filesize 4000000`. Pillow extracted sampled public GIF frames; this was not app rendering or cloud inference.

Retrieval failures: the locale-specific search path `/api/v2/help_center/en-us/articles/search.json` returned HTTP 404. The public non-locale search path `/api/v2/help_center/articles/search.json` succeeded. `https://arc.net/blog/introducing-arc-max` returned HTTP 403. The official article and public attachment API provided the needed Ask evidence instead. No failed fetch was treated as successful evidence.

Focused tests found in source, **not executed here**, include:

- `SpacePresentationTests`: appearance migration, overflow layout, native symbols, Control-number recognition, lazy selection.
- `AddressResultsTests`: exact cross-Space tab selection, Peek preservation/rejection, stale identity, private results and delayed focus.
- `PageLinkIntentTests`: trusted modifier paths, target-blank configuration, download policy, private/extension boundaries.
- `LinkPreviewPresentationTests`: static failures, late timeout callbacks and detached-note failure.
- `TidyTabsUndoTests`: restoring order, later edits, navigation, pinning, closed/new tabs.
- `TabArchiveTests`: acknowledged write failure, races, restore identity, dirty/media protection and clock jumps.
- `PageQuestionTests`: captured excerpts, invalid IDs, untrusted input, same-URL reload cancellation and stale reveal.
- `LinkRoutingTests`: host label boundaries, absent source identity, order, stale destination and queued delivery.
- `PersistentProfileTests` / `ProfileIsolationRegressionTests`: store identity, same-host cookies/storage, late callbacks and scoped clearing.
- `NamingPolicyTests`: identity, language, versions and conservative fallback.

The coordinator must run `just test` for the final integrated source. After that, only the coordinator should run `just qa`, confirm installed `/Applications/Browser-Debug.app` and its `--qa-profile`, use Built-in Retina Display, capture the matrix states, and leave Debug running. Use light/dark, narrow layout, long names, increased contrast, Reduce Motion, native keyboard focus, and VoiceOver where relevant. Keep UI PRs in draft until missing checks are explicit.

## Risks

- Active uncommitted source can change immediately after this audit. No final compiled or integrated state was inspected.
- Reference media has dates and product/platform limits. Historical public GIFs establish design, not an active Arc call path or current feature availability.
- Regular glass API use in source does not prove legibility over actual web content. Actual selection treatment and contrast need native screenshots.
- Reference images cannot establish profile isolation, durable archive safety, cancellation, or model accuracy. Source/test review cannot replace those runtime checks.
- The archive list has no comparable macOS reference image in this audit. Its visual parity remains specifically unresolved.

## Integration contract

- No implementation ownership changed. Each existing worker keeps its feature. This report supplies evidence and acceptance gaps only.
- Preserve active Spaces footer/title/icon/theme work when integrating Profiles, Command Bar, Archive and Routing. Preserve profile and tab identity, saved IDs/order, split focus, lazy views and private boundaries.
- Do not silently migrate Essentials to Favorites. Approve scope and recovery behavior first.
- Keep Page Questions controller/capture/queue/cancellation checks when changing the sheet to a Find-linked surface. Preserve native editor behavior and focus return; do not execute model-supplied selectors or actions.
- Command-T presentation must remain side-effect free until an accepted action. Failed stale results must not dismiss valid work or alter Peek/selection. Keep native address editing separate and correct.
- Reconcile archive timing and routing destinations with named profiles explicitly. Do not silently borrow default-profile cookies or claim a shared archive toggle is profile-specific.
- No cloud inference, Share Space service, unsafe contains routing, or decorative dead controls are required for acceptance.

Reviewed HEADs, with active working changes included where present: `spaces e72fefd`, `command-bar e72fefd`, `peek-gesture b3bc9d6`, `preview-safety 172f43c`, `tidy-undo d6273f3`, `tab-archive e72fefd`, `page-answers a465ad6`, `link-routing c92743c`, `profiles ced1214`, `ai-naming a465ad6`.
