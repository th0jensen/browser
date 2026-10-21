# Arc implementation study

## 1. Purpose

Use Arc as a reference for Browser. Select useful behavior. Do not copy its full product or its browser engine.

The project README sets four goals: an Arc-like experience, Arc Max features, local inference, and low resource use. These goals control the recommendations below. The README was read. It was not changed.

This is a research change. It does not change application code. Code blocks show current code, recovered text, or a proposed design. Each block has a label. The initial research pass made no commit. This report preserves that research snapshot. Implementation changes are reviewed in separate PRs.

## 2. Read order

[Open the complete HTML report](arc-study.html). It includes all eight documents, direct code comparisons, search, syntax highlighting, and print support. It needs no external assets.

| File | Content |
| --- | --- |
| [01-feature-decisions.md](01-feature-decisions.md) | Feature decisions, evidence, differences, and priority |
| [02-interaction-and-state.md](02-interaction-and-state.md) | Spaces, saved tabs, archive, command bar, Peek, and link routing |
| [03-ai-features-and-prompts.md](03-ai-features-and-prompts.md) | Recovered prompt contracts and local model designs |
| [04-performance-and-safety.md](04-performance-and-safety.md) | Source-level costs, expected improvements, and safety limits |
| [05-delivery-and-validation.md](05-delivery-and-validation.md) | Implementation order, acceptance tests, and open questions |
| [06-artifact-evidence.md](06-artifact-evidence.md) | Artifact identities, REA Evidence IDs, literal locations, and source snapshot |
| [07-prompt-literals.md](07-prompt-literals.md) | Exact prompt literals and fragments from the Arc executable |

## 3. Target and scope

- Report branch: `pi-agent/arc-research-report`.
- Browser base: commit `6088fe5`.
- Arc: macOS version `1.169.0`, build `88758`.
- Input: existing `/tmp/arc-rea/arc-latest.dmg`.
- Scope: package inventory, metadata, selected ARM64 literal sections, prompt candidates, and relevant Browser source.
- No Arc account, personal browser profile, history database, or network credentials were inspected.
- Arc was not launched. No Arc AI request was sent.

The input DMG was already present. Its download origin was not established in this run. A request to the official download URL returned HTTP 403. REA recorded the app's signing identity, but this is not a full trust or notarization check. Use the hashes in the evidence file to identify the exact input.

## 4. Evidence rules

**Observed artifact fact:** bytes, metadata, a packaged name, or a prompt literal exist in this exact build.

**Observed source fact:** a statement follows from the inspected Browser source at the recorded commit.

**Inference:** the evidence suggests a feature relationship. The active call path was not verified.

**Proposal:** a design choice for Browser. It is not a claim about Arc's source code.

A feature flag, type name, prompt, or telemetry key does not prove that a feature is enabled. A prompt does not prove that the service received that prompt. A missing match does not prove that a feature or a server-side prompt is absent.

`R01`–`R05` identify REA records. `A01`–`A08` identify literal groups in the evidence appendix. `P01`–`P07` identify prompt groups. The `A` and `P` groups are local byte inspection, not REA decompiler output.

## 5. REA connection and limits

REA MCP is connected to pi. The live server is `rea-agents 6.7.0`. It advertises 207 tools. The package, plist, signature, and Mach-O tools ran successfully. A session refresh is not needed for tool discovery.

Native decompilation did not succeed:

1. The configured Hopper helper reported that it could not find Hopper through Spotlight.
2. A separate REA CLI attempt used the installed Hopper application executable through a process-local `HOPPER_LAUNCHER_PATH`. No persistent configuration was changed.
3. This attempt reached Hopper but did not establish its bridge. A demo/loader dialog and a `Python is Unavailable` status were visible. REA returned a startup timeout and an incomplete cleanup diagnostic. The launched CLI and its Hopper process later exited. The private REA runtime was not used as analysis evidence.
4. Ghidra was not configured. No new analysis engine, Python runtime, license, or system indexing setting was installed or changed.

There is no verified Arc pseudocode or function-level reference graph in this report. The exact prompt bytes are still useful evidence. They are not evidence of execution.

Direct requests to the Arc help pages also returned HTTP 403. Help links are provided for later checks, not as pages verified during this run.

## 6. Main decisions

1. Add Spaces and explicit profile ownership before adding automatic link routing.
2. Add a reversible archive for temporary tabs. Keep archive separate from memory suspension.
3. Add one command surface for open tabs, history, bookmarks, and commands. Keep ordinary typing deterministic.
4. Improve local naming with the recovered prompt constraints. Keep validation and manual names authoritative.
5. Add page questions only with source excerpts, an abstain result, and a visible scope.
6. Keep current lazy WebKit allocation, inference queue, safe download rename, and Peek view reuse.
7. Defer cloud-style research, automatic multi-tab search, and script-based Boosts.

No Arc-versus-Browser speed comparison was made. Expected performance effects are design hypotheses, not measured results.

## 7. Completion checklist

| Question | Status | Result |
| --- | --- | --- |
| Is REA connected? | Answered | MCP calls worked; native provider startup has separate faults. |
| What does the README require? | Answered | Arc-like behavior, local AI, minimal design, and efficiency. |
| Which Arc artifact was inspected? | Answered | Version, build, hashes, slice coordinates, and signing metadata recorded. |
| Which Arc behaviors should Browser adopt? | Partly answered | Priorities are supported by artifact evidence and Browser source. Live interaction is not verified. |
| How does current Browser code differ? | Answered within reviewed modules | Current code and proposed changes are shown separately. |
| Can Arc improve interaction or performance? | Partly answered | State and interaction designs are proposed. No Arc performance measurement exists. |
| What are the exact AI prompts? | Partly answered | Several templates and fragments were recovered. Dynamic values, active model settings, and Tidy Tabs prompt remain unknown. |
| Is Arc's internal implementation traced? | Unresolved | Hopper startup blocked decompilation and cross-references. |
| Were product code or README changed? | Answered | No. Documentation only. |
