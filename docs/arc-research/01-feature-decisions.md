# Feature decisions

## 1. Decision method

Each decision uses two inputs: Arc artifact evidence and current Browser source. Artifact evidence identifies product concepts and prompt contracts. It does not establish the complete runtime algorithm.

Priority means implementation order, not an estimate of development time. `P0` protects current behavior. `P1` is the first new feature group. `P2` follows the state work. `Later` needs more evidence or has a high cost.

## 2. Feature matrix

| Feature | Arc evidence | Current Browser | Decision and reason |
| --- | --- | --- | --- |
| Spaces | A01: space state, controls, and separate-sidebar text | One tab list per `BrowserModel`; folders and Essentials use shared stores | **P1: add.** Separate project context without creating another window. Add explicit scope to state first. |
| Profiles per context | A01: profile and space-related names | `BrowserProfile.websiteDataStore` supplies one ordinary data store; private mode uses a separate store | **P1: design with Spaces.** A visual Space must not imply a separate login identity. |
| Temporary tab archive | A02: archive threshold, per-profile settings, timer, and education names | `TabSuspender` releases inactive views but keeps tabs in the list | **P1: add, opt-in first.** Reduce sidebar clutter. Add persistent restore and undo before automatic removal. |
| Pinned rows and Favorites | A01: pinned/favorite names and preview text | Saved rows in `TabFolderStore`; favicon grid in `PinnedPageStore` | **P0: keep.** Browser already separates a saved descriptor from a live page. Use clear terms: Pinned Tabs and Essential Tabs. |
| Unified command bar | A06: command-bar and tab-switcher names; P03/P04: search-intent templates | Address suggestions rank history and bookmarks; commands use menus | **P1: add local results first.** Switch to a live tab instead of opening a duplicate page. Do not run AI on every keystroke. |
| Tidy Tab Titles | P01: specific-name rules; `filtered` and `rewritten` outputs | Local typed `TidyName`, 2–5 words, stale-result checks | **P0: refine.** Preserve proper nouns. Test a short candidate and a longer safe fallback. Do not replace manual names. |
| Tidy Downloads | P02: metadata-based naming instructions and examples | Local naming after completion; preserved extension, quarantine, collision-safe move, undo | **P0: refine prompt and tests.** Keep the stronger file-operation safeguards already present. |
| Tidy Tabs | A05: tidy controls, settings, and sidebar button names | Subject groups, batches of 18, stable tab IDs, validation, cancel | **P0: keep and add undo.** Exact Arc grouping prompt was not recovered. Do not replace a working subject-based policy with a guessed prompt. |
| Link answer cards | P05: glanceable answer-card text and blocked-page schema fragment | Shift-hover, bounded public fetch, local summary, native glass, detached notes | **P0: improve extraction and failure states.** The basic feature already exists. Do not add automatic hover inference without a separate setting. |
| Ask on Page | P06: webpage-only questions, exact excerpts, concise answers | Native find exists; no page-question flow was found in reviewed modules | **P2: add.** Use excerpts checked against page text. Refuse unsupported answers. |
| Ask ChatGPT shortcut | ChatGPT/OpenAI-related literals in A05 are candidates, not a verified shortcut path | README requires on-device inference | **Do not copy a remote dependency.** A local page action can satisfy the useful need. A remote handoff would need a separate, explicit product decision. |
| Instant Links / intent routing | P03: typed action plan; P04: navigate-versus-search classifier | `BrowserAddress.url` resolves URLs or uses selected search engine | **Later, explicit action only.** Show proposed destinations before navigation. Keep normal Return behavior predictable. |
| Peek | A04/A07: preview, external-link, and split-related implementation names; active trigger rules remain unknown | Pinned cross-site links can open a temporary page; expanding adopts the same tab/view | **P0: keep and add an explicit Peek gesture.** The artifact includes Shift-click Peek text. Verify close, expand, focus, and navigation races. Do not rebuild the page when expanding. |
| Little Arc | A04: Little Arc window and archive names | External links open tabs in the front ordinary window | **P2: optional lightweight link window.** Add explicit promotion to a Space. Do not silently change all external-link behavior. |
| Air Traffic Control | A04: routing control and configuration names | `ExternalURLRouter` has no rule-to-Space model | **P2, after Spaces.** Use deterministic host/source rules and a visible destination. No model is needed. |
| Split View | A07: split controllers, dragger, and pane names | Two-pane limit; persistent orientation, weights, and focused pane | **P0: improve existing controls.** Do not infer Arc's pane limit from names. Add more panes only after a separate design test. |
| Boosts | A08: editor, storage, and installation-dialog names | Built-in Forced Dark extension and extension infrastructure | **Later.** Prefer safe per-site appearance settings. Script injection and sync need a separate threat model. |
| Browser engine replacement | R03/R05: native app plus large ArcCore framework; Chromium-related literals in ArcCore | Public WebKit APIs and native views | **Reject for this task.** A product interaction does not require Chromium. No evidence shows an engine replacement would meet the efficiency goal. |
| Cloud research / answer documents | P07: report/listing schema, query expansion, exact citation instruction | No multi-page research subsystem | **Defer.** Search acquisition, model context, source attribution, and latency are new product costs. Reuse only the citation discipline in page questions. |

## 3. Work that is already implemented

Do not treat feature names as a missing-feature list. Current Browser already has:

- saved sidebar pages, nested folders, manual names, and original-name state;
- a separate Essential Tabs grid;
- temporary topic groups and explicit promotion to a saved folder;
- two-page split groups and persistent split layout;
- live Peek pages that can become ordinary tabs;
- local tab-title naming and reversible download naming;
- local Shift-hover link summaries and session-only floating notes;
- lazy restored tabs, memory-pressure suspension, and media checks;
- a shared priority queue for local inference;
- multi-window session persistence.

Sources: [BrowserModel.swift](../../Sources/Browser/BrowserModel.swift), [TabFolders.swift](../../Sources/Browser/TabFolders.swift), [SplitTabs.swift](../../Sources/Browser/SplitTabs.swift), [BrowserIntelligence.swift](../../Sources/Browser/BrowserIntelligence.swift), [LinkPreviews.swift](../../Sources/Browser/LinkPreviews.swift), and [Session.swift](../../Sources/Browser/Session.swift).

## 4. What not to copy

### 4.1 Do not copy remote inference as an implementation requirement

The artifact contains provider-related names and prompt templates. They do not establish the current endpoint, model, routing policy, or retention policy. Browser has a clear local-inference contract. Preserve it.

### 4.2 Do not copy hidden automatic actions

A model can suggest a name or a group. It must not choose a profile, delete a tab, overwrite a file, or execute page code. These operations need deterministic checks in application code.

### 4.3 Do not copy all visual features

Spaces and a command bar solve direct navigation problems. A full Boosts editor or multi-page research product adds substantial state and security work. Ship the small, useful interaction first.

## 5. Evidence gaps that affect priority

Arc was not run. Exact keyboard behavior, gesture thresholds, animation timing, automatic-archive exclusions, renderer discard policy, and the active AI service are not verified. These limits prevent a claim of full Arc parity.

Before implementing an exact Arc interaction, repeat that interaction in an isolated Arc profile and record its state changes. Before claiming a performance improvement over Arc, measure both products under the same conditions. Neither step was completed in this study.
