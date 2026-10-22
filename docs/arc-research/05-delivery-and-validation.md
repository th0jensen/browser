# Delivery and validation plan

## 1. Change boundary

This branch contains research documentation only. It does not implement the proposals. It does not change README, application source, build settings, dependencies, or REA registration. The pre-existing untracked `TOOLBAR_INTERACTION_FAILURE.md` is outside this change.

The initial research pass made no commit. Implementation work is reviewed in separate PRs. No Browser build or automated test was required for the initial documentation-only change. Existing tests were inspected, not run. Arc was not launched and no Arc account was used.

## 2. Stage 1: preserve current behavior

### Work

- Add grouping undo without changing saved descriptors.
- Evaluate title and download prompt changes with synthetic fixtures.
- Add a safe blocked/insufficient-text result for previews.
- Keep original names and manual naming authoritative.
- Separate the suspension eligibility predicate from the LRU sort.

### Acceptance

- A bad group result cannot remove, duplicate, save, or close a tab.
- Undo restores order and section state while retaining tabs opened after the operation.
- Pinning, navigation, closing, preference changes, or manual edits invalidate late results.
- Download rename and undo never overwrite another file.
- Compound extensions and quarantine survive rename.
- A blocked page produces a clear source-linked failure state, not an invented summary.
- A selected or playing tab cannot be suspended after an awaited media check.

### Existing test anchors

In [BrowserIntelligenceTests.swift](../../Tests/BrowserTests/BrowserIntelligenceTests.swift):

- `testTidyPromptContainsEverySubjectAndExistingTopics`
- `testTidyCannotLoseDuplicateOrSaveTemporaryTabsAndRemovingGroupsPreservesTabs`
- `testTidyOnlyTouchesEligibleTemporaryTabs`
- `testSectionsSurviveSessionRestorationWithoutLoadingBackgroundPages`
- `testPreviewRejectsNonWebAndLocalLinksAndRemovesExecutableMarkup`
- `testRealDownloadTidyAndUndoNeverOverwriteFilesAndKeepQuarantine`
- `testOpenPreviewPreservesLiveSourcePeek`
- `testOpenPreviewRoutesElsewhereAfterSourceTabCloses`

These names identify existing tests. They are not evidence that all proposed behavior is already tested.

## 3. Stage 2: Spaces and profile ownership

### Work

- Define Space, profile, saved-page, live-tab, and split ownership.
- Choose the scope of Essential Tabs explicitly.
- Migrate existing ordinary state into one default Space.
- Add stable Space selection and a switch control.
- Preserve lazy background tabs and current multi-window persistence.

### Acceptance

- Existing sessions and saved folders migrate without losing IDs or order.
- Two Spaces using one profile can share login state by design.
- Two different profiles do not share website data by accident.
- Private windows do not write ordinary Space state.
- Switching Spaces preserves selected tab, split focus, and page state.
- The archive and saved stores use explicit Space/profile ownership.
- A crash or failed migration leaves a recoverable previous file.

Do not start Air Traffic Control until destination ownership is explicit.

## 4. Stage 3: unified local command surface

### Work

- Add typed results for live tabs, saved pages, history, commands, and search.
- Reuse the current native editor and completion rules.
- Avoid rebuilding and sorting the complete history set on every edit.
- Add result revision checks and cancellation for asynchronous work.

### Acceptance

- Selecting a live tab does not create a duplicate or navigate it again.
- Cross-Space results show their destination.
- Old query results cannot replace new query results.
- Up/Down, Return, Escape, deletion, paste, and input methods remain correct.
- URL scheme, host spelling, port, path case, and query are preserved on accepted completions.
- Ordinary typing does not start local inference or network requests for AI.

Keep the existing address-completion tests. Do not treat the command bar as a reason to replace working native field behavior.

## 5. Stage 4: reversible temporary-tab archive

### Work

- Add persistent last-use time and archive records.
- Add Archive search, restore, and undo before automatic operation.
- Add conservative dirty-page and active-work protection.
- Add an opt-in idle policy with visible settings.

### Acceptance

- Archive write failure leaves the live tab intact.
- A pending write cannot archive a newly selected, saved, or moved tab.
- Restore keeps title, URL, ownership, and available interaction state.
- Clock changes, sleep/wake, and restart do not archive all tabs unexpectedly.
- Visible splits, media, capture, popups, editors, uploads, and unknown dirty state are protected.
- Opening Archive does not allocate live views for all entries.

Arc's default duration and exception list require live verification. Do not copy an undocumented constant.

## 6. Stage 5: local page questions

### Work

- Add an explicit page action.
- Capture bounded source blocks with stable IDs.
- Generate a typed local answer.
- Check citations against the captured source.
- Add clear cancellation and insufficient-evidence states.

### Acceptance

- Every visible citation refers to captured source text.
- Page instructions cannot change the system task or execute an action.
- Navigation revision invalidates an old answer.
- An unsupported question does not produce a page-grounded guess.
- Answer text is distinguishable from original excerpts.
- Authenticated page text stays local.
- Keyboard focus returns to the initiating page control when the answer UI closes.

## 7. Stage 6: explicit routing and optional lightweight windows

### Work

- Add deterministic host/source rules after Spaces exist.
- Define rule precedence, fallback, and a visible destination.
- Add an optional small external-link window if product testing supports it.
- Promote its existing live tab instead of reloading the URL.

### Acceptance

- A domain suffix attack does not match another site's rule.
- Unknown source applications do not match source-specific rules.
- Invalid or deleted destinations use the ordinary fallback.
- A private window is never selected silently.
- A queued URL opens once, including during launch and window-close races.
- Promotion preserves the live page and focus.

## 8. Work to defer

- Automatic multi-tab AI search plans.
- Multi-page research documents.
- A cloud AI fallback.
- A complete Boosts script editor or sync service.
- Browser engine replacement.
- Larger split groups without an interaction test.

These are not blocked only by engineering time. They change the product's safety, privacy, or resource contract.

## 9. Required follow-up evidence

| Open question | Required evidence | Why current evidence is insufficient |
| --- | --- | --- |
| How is each prompt assembled? | Function pseudocode, string cross-references, and call sites | Nearby literals do not prove interpolation order or active use. |
| What is the Tidy Tabs prompt? | Client body, packaged resource, or an authorized request trace | No complete prompt was identified in selected sections. |
| Which model handles each feature? | Active request configuration or verified call path | SDK/tokenizer/provider names are not per-feature attribution. |
| What is private-content detection? | Complete template and callers | Static/dynamic prompt type names are only seeds. |
| Does Arc validate citations? | The runtime validator or traced implementation | P07 only says that a check will occur. |
| How do Spaces map to profiles? | Storage model and live login-isolation test | UI text and metadata do not establish isolation. |
| What can Arc auto-archive? | Active policy code and isolated interaction test | Threshold/timer names do not establish exclusions. |
| Does Arc have lower resource use? | Matched process-tree and interaction measurements | No comparative runtime test was run. |
| Are these templates enabled in this build? | Feature flags plus traced active entry points | Shipped code can be inactive or experimental. |

## 10. REA recovery for the next pass

The MCP registration itself works. Do not reinstall REA to repair a native-provider fault.

1. Resolve the installed Hopper helper's app-discovery fault with the operator. Do not enable system indexing without approval.
2. Resolve the visible demo/loader and Python availability state through supported Hopper setup. Do not bypass a license requirement.
3. Use the exact app hash from the evidence ledger.
4. Run `binary_session`, then open the main executable with the selected provider.
5. Search the recorded prompt addresses and related function names.
6. Trace callers and result-application paths. Mark each inference as confirmed or rejected.
7. Export complete Evidence before closing the session.

If Ghidra is selected instead, configure an existing supported installation or obtain approval for installation. Do not install unrelated tools as an implicit recovery step.

## 11. Browser QA rules for implementation work

Use `just test` for automated tests. Use `just qa` for GUI QA. Confirm `--qa-profile` before attaching UI tools. Use the installed `/Applications/Browser-Debug.app` copy and keep it on Built-in Retina Display. Do not launch Release or add command-line UserDefaults overrides. Leave Debug running when QA finishes.

No Browser QA launch was performed for this research-only change. Existing Browser processes were not stopped.

## 12. Research validation completed

- All eight report files were checked with the active Markdown language tools.
- Local report/source links and code-fence boundaries were checked.
- All 84 records in the prompt appendix were compared with the bytes at their recorded file offsets. Byte lengths and terminating zero bytes matched.
- The original prompt's spelling error was retained. Its spelling diagnostic was marked as an intentional quotation, not corrected.
- Application source and README were checked for changes. Neither was changed.

These checks validate the report and its quotations. They do not validate Arc runtime behavior or the proposed designs.

## 13. HTML edition

[The self-contained HTML report](arc-study.html) includes all eight documents and six direct comparisons. It preserves the distinction between Arc artifact text, current Browser source, and proposed Browser designs.

DOM-based checks verified source-document hashes, all 84 rendered literal records, internal links, JavaScript syntax, search, copy, wrapping, keyboard shortcuts, theme switching, print controls, and Markdown download. No external asset is needed. These checks do not verify visual layout in a browser engine.

`just qa` was attempted for native visual QA. It stopped because the active developer directory points to Command Line Tools and `xcodebuild` requires Xcode. No Browser QA app was launched. No system toolchain setting was changed.
