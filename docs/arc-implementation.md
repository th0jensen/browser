# Arc implementation queue

## 1. Working rules

Use the [approved research](arc-research/00-index.md) and [HTML report](arc-research/arc-study.html) as the evidence baseline. The report describes commit `6088fe5`. Implementation starts from fork `main` at `3d91d22`, which includes the newer preview-loading fix.

Each feature has a separate `pi-agent/` branch and worktree. Independent work runs in parallel. Dependent work starts from its reviewed parent branch. Each PR uses the shared template and Simplified Technical English. A reviewer checks each implementation separately from its author. PRs are not merged automatically.

The shared workflow PR allows the existing Debug test job to run on stacked PRs. Initial feature PRs use that shared branch as their base. This keeps feature diffs focused.

## 2. Queue

| Section | Branch | Dependency | State / PR |
| --- | --- | --- | --- |
| PR template and stacked validation | `pi-agent/arc-pr-workflow` | main | [PR #22](https://github.com/th0jensen/browser/pull/22) |
| Research and review baseline | `pi-agent/arc-research-report` | PR workflow | [PR #23](https://github.com/th0jensen/browser/pull/23); CI passed |
| Local naming prompts and validation | `pi-agent/arc-ai-naming` | PR workflow | [Draft PR #24](https://github.com/th0jensen/browser/pull/24); Debug tests passed |
| Reversible Tidy Tabs | `pi-agent/arc-tidy-undo` | PR workflow | [Draft PR #27](https://github.com/th0jensen/browser/pull/27); Debug tests passed |
| Preview extraction and failure states | `pi-agent/arc-preview-safety` | PR workflow | [Draft PR #29](https://github.com/th0jensen/browser/pull/29); Debug tests passed; visual comparison pending |
| Tab suspension eligibility | `pi-agent/arc-tab-lifecycle` | Spaces | [Draft PR #25](https://github.com/th0jensen/browser/pull/25); integrated Debug tests passed; latest Space parent inherited |
| Explicit Shift-click Peek | `pi-agent/arc-peek-gesture` | PR workflow | [Draft PR #28](https://github.com/th0jensen/browser/pull/28); source-owned Split action reviewed and tested; native visual/input checks pending |
| Spaces and ownership foundation | `pi-agent/arc-spaces` | PR workflow | [Draft PR #26](https://github.com/th0jensen/browser/pull/26); bottom strip, native swipe and atomic metadata tests passed; partial native QA, not full acceptance |
| Arc-like command palette and local results | `pi-agent/arc-command-bar` | Spaces | Local result engine reviewed; centered Liquid Glass presentation revision active |
| Reversible temporary-tab archive | `pi-agent/arc-tab-archive` | Spaces | [Draft PR #31](https://github.com/th0jensen/browser/pull/31); editor/durability/policy reviews and Debug tests passed; CI passed |
| Local page questions and citations | `pi-agent/arc-page-answers` | Naming | Find-linked glass surface tested; webpage-IME Escape correction active |
| Deterministic link routing | `pi-agent/arc-link-routing` | Spaces | [Draft PR #30](https://github.com/th0jensen/browser/pull/30); Debug tests passed; native visual/delivery checks pending |
| Separate persistent profiles | `pi-agent/arc-profiles` | Spaces | [Draft PR #32](https://github.com/th0jensen/browser/pull/32); privacy/recovery reviews passed; final footer/swipe/staging parent passed Debug tests |
| Profile-shared live Favorites | `pi-agent/arc-favorites` | Profiles and Spaces | Typed ownership/migration contract approved; implementation and validation active |

## 3. Prompt rules

P01 and P02 provide title and download naming evidence. P05 and P06 provide page-summary and page-question evidence. New local prompts can reconstruct their useful intent. They must not be described as exact recovered Arc prompts. The Tidy Tabs prompt and active server-side additions remain unknown. Keep the original literal appendix unchanged.

All inference stays on device. Model output cannot authorize file movement, choose an authentication profile, execute scripts, or remove a tab. The app validates model output and stale state before applying it.

## 4. Review and validation gates

The [Arc reference and visual acceptance contract](arc-visual-verification.md) is part of the user's requirements. Use official behavior references and inspect actual public images before accepting a UI section. Keep Arc's useful placement and hierarchy while using Browser's native Liquid Glass. The initial top Space menu and ordinary address suggestions did not meet that requirement. Bottom-strip and centered-palette revisions are implemented and tested; native acceptance remains separate. The [independent cross-feature reference audit](arc-reference-audit.md) records official behavior sources, inspected images, concrete design gaps, deliberate Browser adaptations, and required native comparison states. It is a source/reference snapshot, not a GUI pass. In particular, profile-shared Favorites and Find-linked answers need correction; the themed footer is now present in source and has passed Debug tests.

- Read current source before changing it. Keep cleanup inside the feature scope.
- Add deterministic regression tests for state, safety, cancellation, and migration.
- Run `just test` with Debug and the available Xcode toolchain. Report exact results.
- Keep build/test work serialized when the host is shared. Do not call syntax parsing a successful XCTest run.
- Keep benchmark results in the task thread, not PR descriptions or this file.
- Run `just qa` only from the normal checkout for integrated GUI QA. Confirm `--qa-profile`, use the installed Debug app, keep it on Built-in Retina Display, and leave it running.
- Keep unverified native UI changes in draft until the remaining checks are stated and reviewed.

## 5. Feature boundaries

The first Spaces PR can preserve one explicit existing profile while it establishes correct ownership and migration. It must not present shared cookies as profile isolation. A separate profile PR must use distinct website data and safe configuration routing before it claims independent logins.

Routing must use completed Space ownership. Archive must write durably before removing a live tab. Page answers must validate citations against captured source and reject stale navigation. Automatic multi-page research, cloud fallback, script-based Boosts, engine replacement, and larger split groups remain deferred as in the approved plan.
