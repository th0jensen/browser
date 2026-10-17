# Resource measurements

`scripts/browser-resources.py` measures existing files or running processes. It
does not launch, terminate, attach a debugger, or alter the app. Run resource
sampling separately from the latency benchmark: even read-only observers add
work to the machine. Use the same Release configuration, architecture, signing,
machine, fixture, tab state, warmup and sample duration for both revisions.

## Benchmark timing and reports

The Release XCTest harness uses a visible floating window on all Spaces, closes
other normal windows in its own host, and records window/screen inventories and
appearance. The application may remain inactive under macOS cooperative
activation; native editor ownership is observed inside the benchmark window.
Apply the same protocol to baseline and candidate.

Each host-only idle state (`new_tab` and `static_color_page`) has a one-second
quiet period followed by one **30-second** CPU/RSS measurement. Host measurements
include XCTest and exclude WebKit processes. RSS values are endpoints, not peaks.
Repeat whole runs to assess variability; one idle window is not a distribution.

A separate external resource sample can measure the host plus registered WebKit
services for **10 seconds during the middle of that 30-second idle phase**. The
harness writes `resource-phase.json` in its printed `BROWSER_BENCHMARK_OUTPUT`
directory with the phase name, host PID, status, start uptime, and duration.
Coordinate discovery and sampling so the entire external sample and its
discovery snapshots finish before the idle phase ends, and retain that phase
evidence. Keep these external results separate from the host-only 30-second
table: their process scopes and observation windows differ. Run external
sampling outside the latency phases.

Latency metrics use 30 measured operations after three discarded warmups:

| Metric | Completion measured |
|---|---|
| `local_html_load` | Local embedded HTML load to a script message after window load and two animation-frame callbacks, using a warm WebKit process. |
| `layout_to_vertical`, `layout_to_horizontal` | Defaults mutation to requested native tab accessory state and selected native/presentation frames stable for three display callbacks. |
| `warm_tab_attachment` | Active tab assignment to the target content view's child `viewDidMoveToWindow` callback; alternates two loaded tabs. |
| `new_tab_address_focus` | Tab creation to the first run-loop `beforeWaiting` event observing the new selection, a newer focus request, and the native address editor owning first responder. |
| `resize_native_frame` | Content-size mutation to the first WebKit view frame-change notification. |
| `resize_dom_ack` | The same resize to a DOM resize acknowledgement after two animation-frame callbacks, with viewport dimensions matching native bounds within one point. |

These events describe distinct stages; none establishes final pixels on the
display. Attachment timing excludes later paint and thumbnail completion. The
exact definitions, samples, medians, nearest-rank p90 values, and actual idle
durations are retained in the raw JSON. Page snapshots are fixture-only evidence;
full application chrome and color QA require separate screenshots.

`scripts/benchmark.sh` creates a unique `Benchmark-<UTC time>-<UUID>` directory
containing `Results.xcresult`, exported attachments, `benchmark.log`, and
`run.json`. The manifest records source/harness hashes, build exit status, and
the executable hash observed after the build. A failed build can leave an older
executable, which is explicitly identified as a provenance limitation.

Pass the two unique run directories to the report script:

```sh
python3 scripts/benchmark-report.py /absolute/baseline/run /absolute/candidate/run
```

Passing a parent directory selects its latest run. A failed, running, or
incomplete latest run prevents comparison; an earlier success is never used as
a substitute. Manifest-backed comparisons also reject differing harness hashes.
For legacy exports without manifests, selection uses the newest run's JSON
timestamps; ambiguous ties require a single run directory or JSON file.

## Bundle size

After both Release builds finish:

```sh
python3 scripts/browser-resources.py sizes \
  DerivedData/PerformanceBaseline/Build/Products/Release/Browser.app \
  DerivedData/PerformanceCandidate/Build/Products/Release/Browser.app \
  > DerivedData/browser-bundle-resources.json
```

Use the actual output bundle paths if the build directories differ. Logical
bytes sum regular files and symlink text, counting hardlinked inodes once.
Allocated bytes sum `st_blocks * 512`, including directories. Symlinks are not
followed during bundle traversal. Executable bytes and SHA-256 are also saved.
APFS clones and compression mean allocated bytes cannot establish unique storage
consumption. Bundle sizes exclude profile/cache data, separate dSYMs, and the
system WebKit frameworks. Do not compare a Debug bundle with a Release bundle.

## CPU, RSS and physical footprint

Prepare an identical page/tab state, let the app settle, and supply its existing
PID. Repeat separately for baseline and candidate; save each raw JSON:

```sh
python3 scripts/browser-resources.py sample 12345 \
  --state 'one colorful fixture tab, settled, visible window; activation recorded separately' \
  --duration 10 --interval 1 > DerivedData/baseline-idle-resources.json
```

The public `proc_pid_rusage` API supplies cumulative user/system CPU counters,
resident bytes and physical-footprint ledger bytes. CPU uses counter deltas,
converted from Mach ticks using `mach_timebase_info`, divided by observed
monotonic time. A value of 100% means one occupied core. This avoids `ps %cpu`,
which is a decaying average over up to a minute (`man ps`). Raw readings and
observed durations are retained. Process start time and executable UUID detect
PID reuse or executable replacement. Read errors, counter regression or identity
changes produce incomplete summaries; unavailable values are never zero-filled.
Peaks are sampled peaks, not guaranteed lifetime/window maxima.

Host-only mode explicitly excludes WebKit XPC processes. RSS includes clean and
shared pages, so it is not the same metric as physical footprint. Apple describes
the physical-footprint ledger and the difference from resident memory in
`man footprint`; it is also discussed in [Profile and optimize your game's
memory](https://developer.apple.com/videos/play/wwdc2022/10106/).
The source of the CPU counters is Apple's [XNU resource
collection](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c).

## WebKit attribution

Do not select every `com.apple.WebKit.*` process, or use PPID/PGID alone: XPC
services may be launched by launchd and other browser apps use the same service
names. The public SDK `sys/proc_info.h` exposes no coalition enumeration API.
`launchctl print pid/<PID>` can show services registered in that process's PID
domain even when their PPID is launchd. `launchctl procinfo <PID>` requires root
on the measured host. `man launchctl` explicitly says diagnostic output is not a
stable API and offers no compatibility guarantee.

The optional `--discover-webkit` mode uses this diagnostic PID-domain service
table as a narrowly defined cohort:

```sh
python3 scripts/browser-resources.py sample 12345 --discover-webkit \
  --state 'one colorful fixture tab, settled, visible window; activation recorded separately' \
  --duration 10 --interval 1 > DerivedData/baseline-registered-webkit-resources.json
```

It requires the domain's creator PID to match the host. Each running WebKit
service must have a matching service report with the same PID, host domain,
XPCService type and running state; its program path must match the live libproc
executable path inside WebKit.framework. Host and service identities include
process start time and executable UUID. Discovery happens before and after the
resource window; changed PIDs, services or identities invalidate aggregate
metrics. The JSON retains allowlisted provenance and service-table rows;
environment blocks are omitted. `host_summary` reports the host separately,
`related_processes_summary` reports the selected WebKit services, and `summary`
reports their combined totals.

This scope is **host plus WebKit services registered in its PID domain**. It does
not establish exclusive responsibility or complete attribution of every helper
acting on the app's behalf. Two matching snapshots also cannot detect a service
that starts and exits between them. The strict parser fails closed on unknown
output layouts. Discovery was exercised on macOS 27.2 (26B5091g); revalidate it
after OS/tool updates. It adds diagnostic work outside the timed resource window
and should be run separately from latency measurements.

Three one-second `sample` reports on that OS (Networking, GPU and WebContent;
Report Version 7) provided physical footprint and launch times but no
`Responsible` field. They therefore could not establish app ownership. `sample`
briefly suspends target threads and should not be run during latency or idle CPU
measurement windows (`man sample`).

If an Instruments capture or another independently checked process report
identifies relevant WebKit PIDs, pass them explicitly and save the evidence:

```sh
python3 scripts/browser-resources.py sample 12345 \
  --related-pid 12346 --related-pid 12347 \
  --attribution-evidence 'capture.trace; inspected ownership for PIDs 12346 and 12347' \
  --state 'one colorful fixture tab, settled, visible window; activation recorded separately' \
  --duration 10 --interval 1 > DerivedData/baseline-selected-processes.json
```

This reports a fixed selected-process set; it never claims complete automatic
app attribution. Newly spawned processes are excluded. A selected process that
exits or becomes unreadable invalidates the aggregate window. RSS sums may count
shared pages twice; physical-footprint sums are ledger sums, not a deduplicated
system-wide footprint. For independently verified PIDs, `footprint -p 12345 -p
12346 -p 12347 -j capture.json` provides a separate, heavier memory investigation
that deduplicates multiply mapped objects (`man footprint`). Run it outside timed
benchmark windows. Apple documents Instruments memory investigation in
[Gathering information about memory
use](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use).

## Startup scope

The existing harness measures operations after the XCTest host has launched.
Window/controller construction inside that process must not be called full app
startup. A reproducible additional metric needs the same external launch and
readiness definition for both revisions: elapsed time from starting a fresh app
process to an agreed first-window-ready signal. An explicit test-only readiness
hook applied identically to the frozen baseline and candidate is preferable to
polling for a process name or assuming that `open -a` returning means the UI is
ready. Record repeated warm launches separately from cold launches; filesystem
cache conditions and restored session state materially change the result.
