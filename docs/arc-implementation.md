# Arc implementation queue

## 1. Working rules

Use the [approved research](arc-research/00-index.md) and [HTML report](arc-research/arc-study.html) as the evidence baseline. The report describes commit `6088fe5`. Implementation starts from fork `main` at `3d91d22`, which includes the newer preview-loading fix.

Each feature has a separate `pi-agent/` branch and worktree. Independent work runs in parallel. Dependent work starts from its reviewed parent branch. Each PR uses the shared template and Simplified Technical English. A reviewer checks each implementation separately from its author. PRs are not merged automatically.

The shared workflow PR allows the existing Debug test job to run on stacked PRs. Initial feature PRs use that shared branch as their base. This keeps feature diffs focused.

## 2. Queue

| Section | Branch | Dependency | State / PR |
| --- | --- | --- | --- |
| PR template and stacked validation | `pi-agent/arc-pr-workflow` | main | [PR #22](https://github.com/th0jensen/browser/pull/22) |
| Research and review baseline | `pi-agent/arc-research-report` | PR workflow | Preparing |
| Local naming prompts and validation | `pi-agent/arc-ai-naming` | PR workflow | Active |
| Reversible Tidy Tabs | `pi-agent/arc-tidy-undo` | PR workflow | Active |
| Preview extraction and failure states | `pi-agent/arc-preview-safety` | PR workflow | Active |
| Tab suspension eligibility | `pi-agent/arc-tab-lifecycle` | PR workflow | Active |
| Explicit Shift-click Peek | `pi-agent/arc-peek-gesture` | PR workflow | Active |
| Spaces and ownership foundation | `pi-agent/arc-spaces` | PR workflow | Active |
| Unified local command results | `pi-agent/arc-command-bar` | Spaces | Waiting for the Space contract implementation |
| Reversible temporary-tab archive | `pi-agent/arc-tab-archive` | Spaces | Waiting for the Space contract implementation |
| Local page questions and citations | `pi-agent/arc-page-answers` | Naming | Waiting for the shared inference contract |
| Deterministic link routing | `pi-agent/arc-link-routing` | Spaces | Waiting for the Space contract implementation |
| Separate persistent profiles | `pi-agent/arc-profiles` | Spaces | Waiting for the ownership foundation |

## 3. Prompt rules

P01 and P02 provide title and download naming evidence. P05 and P06 provide page-summary and page-question evidence. New local prompts can reconstruct their useful intent. They must not be described as exact recovered Arc prompts. The Tidy Tabs prompt and active server-side additions remain unknown. Keep the original literal appendix unchanged.

All inference stays on device. Model output cannot authorize file movement, choose an authentication profile, execute scripts, or remove a tab. The app validates model output and stale state before applying it.

## 4. Review and validation gates

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
