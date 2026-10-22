# User review: sidebar and command bar

## What the user reported

Source: the user-supplied `browser-review-checklist.md`, with snapshot `2026-10-22T00:52:34.015Z` and recorded code `c078b974dd59de8dd6a0f9976a2d70eaa8d4287f`.

The user marked **10 of 16 current-version checks Pass**. Six were **Not tried**. No failures or additional notes were reported. The 31 combined-version and engineering checks also remain Not tried.

This is a user-reported acceptance record for that code. It is not a new automated test run or approval of the complete feature stack. The exported reviewer, date, environment and input-method fields were blank. Do not infer which individual language, hardware or appearance variants were exercised from an aggregate Pass.

| Check | What was accepted |
| --- | --- |
| QA-01 | Correct Debug test setup |
| SP-01 | Docked/floating sidebar balance |
| SP-02 | Independent title and New Space visibility |
| SP-03 | Space indicator visibility policy |
| SP-05 | Space icon/emoji/colour editing |
| CB-01 | Command-G toggling |
| CB-02 | Unchanged Return keeps the exact source page |
| CB-03 | Current-page editing versus new destination |
| CB-05 | Typing, caret and focus behavior |
| CB-06 | Command bar presentation and selection |

## What remains untested

These are missing results, not reported defects and not waived requirements.

| Check | Remaining review |
| --- | --- |
| SP-04 | Draft/history retention across Space switches |
| SP-06 | Overflow and hidden-control keyboard focus |
| CB-04 | Correct-page results and stale-action rejection |
| CB-07 | Private suggestion and favicon isolation |
| UX-01 | Appearance, contrast, reduced motion and matched tint comparison |
| UX-02 | VoiceOver and the complete multiwindow flow |

The SP-02 Pass does not imply the broader UX-02 VoiceOver/multiwindow case passed. Likewise, CB-05 does not document each possible input method.

## Decision and next work

The user explicitly instructed development to continue despite the six missing results. Keep them open; do not demand that they be completed before engineering can proceed, and do not turn them into Pass or Not applicable.

Engineering should finish the remaining safety work, join the latest ownership fixes, and validate one exact combined version. In particular:

1. Complete current-parent profile/routing integration without losing the shared Space editor and optional controls. The source/automated portion is now complete as recorded below; real delivery and full-stack acceptance remain open.
2. Finish independent review and publication of the existing local Favorite move/recovery fixes.
3. Assemble and test the complete reviewed combination before presenting full-stack acceptance as available.

## Engineering follow-through

- **Profiles #32 — `db1fea6`:** inherits Spaces `15556c4`, retaining profile selection, shared appearance editing, optional controls, balanced sidebar geometry and owner-checked profile actions. Full Debug suite: 503 passed, zero failed, two skipped.
- **Routing #30 — `99a48e4`:** published on that Profiles parent. Destinations include their owning profile; descriptor listing stays lazy and unavailable owners fall back safely. Full Debug suite: 530 passed, zero failed, two skipped.
- **Review correction:** independent source review found a real Control-number menu mismatch around unavailable owners. Labels now use the eligible list and actions retain the displayed Space UUID. Fresh review found no concrete blocker in its scope. Six shared source/test files were checked byte-identical between the two branches.
- Both changes remain draft. These are separate engineering scopes, not additive counts, full-stack validation, native acceptance or GitHub approval. The user's ten passes do not transfer to these new revisions. The six missing results remain missing.

The [durable validation receipt](review-evidence/profile-routing.json) records exact code versions, commands, counts, scope and limitations. The [final automated source-review response](review-evidence/profile-routing-source-review.md) is preserved separately. Raw local XCTest bundles and the full assistant transcript are not bundled in Git. Reproduce validation with `just test` at each recorded branch/head; do not treat a receipt as the raw test evidence.

No browser interaction, refresh, deployment or relaunch was performed for this update. Do not interact with, refresh or relaunch the user's browser during this work. Automated/source validation and any remaining native acceptance must be reported separately. The original research HTML and the user's downloaded answers stay unchanged.

Source-file SHA-256: `6878694736cb00cd778b8a0931d4df7dbe2250513e6d00a8833cbc907bf7b225`.
