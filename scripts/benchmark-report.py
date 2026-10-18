#!/usr/bin/env python3
"""Read raw benchmark JSON or recursively discover exported XCTest attachments.

Usage: benchmark-report.py BASELINE_JSON_OR_DIR CANDIDATE_JSON_OR_DIR
       benchmark-report.py --verify-fixture
No measurements are synthesized: incomplete records and missing metrics are explicit.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import platform
import plistlib


ROOT = Path(__file__).resolve().parent.parent


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def digest_files(files):
    """Hash paths as well as bytes, with lengths delimiting every input."""
    digest = hashlib.sha256()
    for file in sorted(files):
        relative = str(file.relative_to(ROOT)).encode()
        data = file.read_bytes()
        for value in (relative, data):
            digest.update(len(value).to_bytes(8, "big"))
            digest.update(value)
    return digest.hexdigest()


def start_run(path, label, derived):
    sources = [p for p in (ROOT / "Sources").rglob("*") if p.is_file()]
    # Keep harness identity separate: baseline and candidate must use the same harness.
    harness = [ROOT / p for p in ("scripts/benchmark.sh", "scripts/benchmark-report.py",
               "Tests/BrowserTests/BrowserPerformanceTests.swift", "Tests/Performance/colorful.html",
               "project.yml", "justfile", "scripts/benchmark-cohort.py")]
    manifest = {"schema": "browser-benchmark-run-v1", "started_at": timestamp(),
                "label": label, "status": "running", "source_root": str(ROOT),
                "derived_data": str(Path(derived).resolve()),
                "source_tree_sha256": digest_files(sources),
                "harness_sha256": digest_files(harness),
                "platform": platform.platform(), "machine": platform.machine()}
    (Path(path) / "run.json").write_text(json.dumps(manifest, indent=2) + "\n")


def finish_run(path, exit_status):
    file = Path(path) / "run.json"
    manifest = json.loads(file.read_text())
    manifest.update({"finished_at": timestamp(), "xcodebuild_exit_status": exit_status,
                     "status": "passed" if exit_status == 0 else "failed"})
    app = Path(manifest["derived_data"]) / "Build/Products/Benchmark/Browser-Benchmark.app"
    try:
        with (app / "Contents/Info.plist").open("rb") as handle:
            executable_name = plistlib.load(handle)["CFBundleExecutable"]
        if Path(executable_name).name != executable_name:
            raise ValueError("CFBundleExecutable must be a file name")
        binary = app / "Contents/MacOS" / executable_name
        manifest["executable_path"] = str(binary)
        manifest["executable_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
        manifest["executable_identity_limit"] = "Build product observed after xcodebuild; a failed build may leave a previous product."
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        manifest["executable_identity_error"] = str(error)
    file.write_text(json.dumps(manifest, indent=2) + "\n")


def verify_fixture():
    root = Path(__file__).resolve().parent.parent
    swift = (root / "Tests/BrowserTests/BrowserPerformanceTests.swift").read_text()
    embedded = swift.split('private static let fixture = #"""\n', 1)[1].split('\n"""# + "\\n"', 1)[0] + "\n"
    expected = (root / "Tests/Performance/colorful.html").read_text()
    if embedded != expected:
        raise SystemExit("Embedded Swift fixture differs from Tests/Performance/colorful.html")
    print("Fixture verified: embedded HTML and source fixture are identical.")


def read_result(path):
    source = Path(path)
    files = [source] if source.is_file() else sorted(source.rglob("*"))
    records = []
    manifests = []
    for file in files:
        if not file.is_file():
            continue
        # XCTest may export an attachment with a UUID name and a non-JSON suffix.
        if file.stat().st_size > 2_000_000:
            continue
        try:
            value = json.loads(file.read_text())
        except (OSError, UnicodeError, json.JSONDecodeError):
            continue
        if isinstance(value, dict) and value.get("schema") == "browser-performance-v1":
            records.append((value, file))
        elif isinstance(value, dict) and value.get("schema") == "browser-benchmark-run-v1":
            manifests.append((value, file))
    if manifests:
        manifest, manifest_file = max(manifests, key=lambda item: item[0]["started_at"])
        print(f"Latest run: {manifest_file} ({manifest['status']})")
        print(f"Source SHA-256: {manifest['source_tree_sha256']}; harness SHA-256: {manifest['harness_sha256']}")
        print(f"Executable SHA-256: {manifest.get('executable_sha256', 'unavailable')}")
        if manifest["status"] != "passed":
            raise SystemExit("Latest benchmark run did not pass; refusing to substitute an older successful run.")
        records = [(v, p) for v, p in records if p.is_relative_to(manifest_file.parent)]
    if not records:
        raise SystemExit(f"No browser-performance-v1 records found: {path}")
    # Legacy/export-only directories have no manifest. Select the newest run first,
    # then its final incremental record; never prefer an older completed run.
    runs = {}
    for value, file in records:
        identity = value.get("output_directory") or (str(file.parent), value.get("pid"))
        runs.setdefault(identity, []).append((value, file))
    latest_timestamp = max(v.get("timestamp", "") for v, _ in records)
    newest_runs = [rows for rows in runs.values()
                   if max(v.get("timestamp", "") for v, _ in rows) == latest_timestamp]
    if len(newest_runs) != 1:
        raise SystemExit("Newest legacy runs have ambiguous timestamps; supply a single run directory or JSON file.")
    selected = newest_runs[0]
    def record_order(item):
        value, _ = item
        status = value.get("status", "")
        terminal = 2 if status.startswith("failed") else 1 if status == "complete" else 0
        return value.get("timestamp", ""), terminal, len(value.get("metrics", []))
    value, file = max(selected, key=record_order)
    print(f"{value['label']}: {file} ({value['status']})")
    if value.get("status") != "complete":
        raise SystemExit("Latest benchmark record is incomplete; refusing to report a completed comparison.")
    if manifests:
        value["run_provenance"] = manifest
    return value


def number(value):
    return "—" if value is None else f"{value:.3f}"


def report(baseline, candidate):
    left_provenance, right_provenance = baseline.get("run_provenance"), candidate.get("run_provenance")
    if left_provenance and right_provenance and left_provenance["harness_sha256"] != right_provenance["harness_sha256"]:
        raise SystemExit("Baseline and candidate harness hashes differ; comparison requires an identical harness.")
    left = {m["name"]: m for m in baseline.get("metrics", [])}
    right = {m["name"]: m for m in candidate.get("metrics", [])}
    print("\n| Latency (ms) | Baseline median | Candidate median | Baseline p90 | Candidate p90 | Median change |")
    print("|---|---:|---:|---:|---:|---:|")
    for name in dict.fromkeys([*left, *right]):
        a, b = left.get(name, {}), right.get(name, {})
        delta = ((b["median"] / a["median"]) - 1) * 100 if a.get("median") and b.get("median") is not None else None
        change = "—" if delta is None else f"{delta:+.1f}%"
        print(f"| {name} | {number(a.get('median'))} | {number(b.get('median'))} | {number(a.get('p90'))} | {number(b.get('p90'))} | {change} |")
    print("\n| Host-only idle state | Baseline CPU % (one core) | Candidate CPU % (one core) | Baseline RSS after (MiB) | Candidate RSS after (MiB) |")
    print("|---|---:|---:|---:|---:|")
    left = {m["name"]: m for m in baseline.get("resource_windows", [])}
    right = {m["name"]: m for m in candidate.get("resource_windows", [])}
    for name in dict.fromkeys([*left, *right]):
        a, b = left.get(name, {}), right.get(name, {})
        rss_a, rss_b = a.get("rss_after_bytes"), b.get("rss_after_bytes")
        print(f"| {name} | {number(a.get('cpu_percent_one_core'))} | {number(b.get('cpu_percent_one_core'))} | {number(rss_a / 2**20 if rss_a is not None else None)} | {number(rss_b / 2**20 if rss_b is not None else None)} |")
    print("\nCPU/RSS above include the application XCTest host; other normal host windows were closed before measurement. WebKit subprocesses are excluded. Host idle results use one 30-second window per state after 1 second quiet; RSS values are endpoints, not peaks. External host-plus-registered-WebKit-service cohort samples, when collected, use a separate 10-second window within each idle phase and are not included in this table. Latencies use 30 samples after 3 discarded warmups. Native frame, view attachment, run-loop focus, and DOM/rAF acknowledgements have distinct completion definitions; none proves final display presentation. See raw JSON for actual durations, window/screen inventories, precise definitions, and limitations.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", nargs="?")
    parser.add_argument("candidate", nargs="?")
    parser.add_argument("--verify-fixture", action="store_true")
    parser.add_argument("--start-run")
    parser.add_argument("--finish-run")
    parser.add_argument("--label")
    parser.add_argument("--derived-data")
    parser.add_argument("--exit-status", type=int)
    args = parser.parse_args()
    if args.start_run:
        if args.label is None or args.derived_data is None:
            parser.error("--start-run requires --label and --derived-data")
        start_run(args.start_run, args.label, args.derived_data)
        return
    if args.finish_run:
        if args.exit_status is None:
            parser.error("--finish-run requires --exit-status")
        finish_run(args.finish_run, args.exit_status)
        return
    if args.verify_fixture:
        verify_fixture()
    if args.baseline and args.candidate:
        report(read_result(args.baseline), read_result(args.candidate))
    elif not args.verify_fixture:
        parser.error("Supply both baseline and candidate JSON files/directories")


if __name__ == "__main__":
    main()
