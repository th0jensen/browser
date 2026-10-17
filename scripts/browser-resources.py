#!/usr/bin/env python3
"""Read-only bundle sizes and explicitly scoped macOS process resource samples.

No applications are launched and no process ownership is inferred. JSON goes to
stdout; redirect it to preserve the raw measurements. See docs/resources.md.
"""

import argparse
import ctypes
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import sys
import time


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def bundle_sizes(app):
    app = Path(app).absolute()
    if not app.is_dir() or app.is_symlink():
        raise ValueError(f"Expected a real app bundle directory: {app}")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    executable_name = info["CFBundleExecutable"]
    if Path(executable_name).name != executable_name:
        raise ValueError("CFBundleExecutable must be a file name")
    executable = app / "Contents/MacOS" / executable_name
    seen = set()
    logical = allocated = regular_files = directories = symlinks = duplicates = 0
    pending = [app]
    while pending:
        path = pending.pop()
        entry = path.lstat()
        identity = (entry.st_dev, entry.st_ino)
        if identity in seen:
            duplicates += 1
            continue
        seen.add(identity)
        allocated += entry.st_blocks * 512
        if stat.S_ISDIR(entry.st_mode):
            directories += 1
            pending.extend(path.iterdir())
        elif stat.S_ISREG(entry.st_mode):
            regular_files += 1
            logical += entry.st_size
        elif stat.S_ISLNK(entry.st_mode):
            symlinks += 1
            logical += entry.st_size
        else:
            raise ValueError(f"Unsupported special file in bundle: {path}")
    entry = executable.stat()
    with executable.open("rb") as handle:
        digest = hashlib.file_digest(handle, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else None
        if digest is None:
            handle.seek(0)
            sha = hashlib.sha256()
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                sha.update(chunk)
            digest = sha.hexdigest()
    return {
        "app": str(app),
        "bundle_identifier": info.get("CFBundleIdentifier"),
        "bundle_version": info.get("CFBundleVersion"),
        "bundle_short_version": info.get("CFBundleShortVersionString"),
        "bundle_logical_bytes": logical,
        "bundle_allocated_bytes": allocated,
        "regular_file_count": regular_files,
        "directory_count": directories,
        "symlink_count": symlinks,
        "duplicate_hardlink_entries_skipped": duplicates,
        "executable": str(executable),
        "executable_logical_bytes": entry.st_size,
        "executable_allocated_bytes": entry.st_blocks * 512,
        "executable_sha256": digest,
    }


# Public SDK layout: <sys/resource.h>, struct rusage_info_v0 (10 uint64s).
class RUsageV0(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups",
            "pageins", "wired_size", "resident_size", "phys_footprint",
            "proc_start_abstime", "proc_exit_abstime",
        )
    ]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


class DarwinReader:
    def __init__(self):
        if sys.platform != "darwin":
            raise ValueError("Process sampling requires macOS")
        self.libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.libproc.proc_pid_rusage.restype = ctypes.c_int
        self.libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        self.libproc.proc_pidpath.restype = ctypes.c_int
        system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
        system.mach_timebase_info.restype = ctypes.c_int
        self.timebase = Timebase()
        if system.mach_timebase_info(ctypes.byref(self.timebase)) != 0 or not self.timebase.denom:
            raise ValueError("mach_timebase_info failed")

    def read(self, pid):
        start = time.monotonic_ns()
        usage = RUsageV0()
        ctypes.set_errno(0)
        result = self.libproc.proc_pid_rusage(pid, 0, ctypes.byref(usage))
        end = time.monotonic_ns()
        row = {"pid": pid, "monotonic_ns": (start + end) // 2}
        if result != 0:
            code = ctypes.get_errno()
            row["error"] = {"operation": "proc_pid_rusage", "errno": code, "message": os.strerror(code)}
            return row
        path = ctypes.create_string_buffer(4096)
        path_result = self.libproc.proc_pidpath(pid, path, len(path))
        row.update({
            "executable_path": os.fsdecode(path.value) if path_result > 0 else None,
            "executable_uuid_hex": bytes(usage.uuid).hex(),
            "process_start_mach_ticks": usage.proc_start_abstime,
            "user_cpu_mach_ticks": usage.user_time,
            "system_cpu_mach_ticks": usage.system_time,
            "rss_bytes": usage.resident_size,
            "physical_footprint_bytes": usage.phys_footprint,
        })
        return row


def identity(row):
    return {key: row[key] for key in ("pid", "executable_path", "executable_uuid_hex", "process_start_mach_ticks")}


def launchctl_print(target):
    result = subprocess.run(["/bin/launchctl", "print", target], capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise ValueError(f"launchctl print {target} failed: {result.stderr.strip()}")
    return result.stdout


def parse_pid_domain(report, pid):
    """Fail closed on unrecognized diagnostic output; never retain environments."""
    if not report.startswith(f"pid/{pid} = {{\n") or "\n\ttype = pid\n" not in report:
        raise ValueError("Unrecognized launchctl PID-domain report")
    creator = re.search(r"^\tcreator = (.+)\[(\d+)\]$", report, re.MULTILINE)
    block = re.search(r"^\tservices = \{\n(.*?)^\t\}", report, re.MULTILINE | re.DOTALL)
    if creator is None or int(creator[2]) != pid or block is None:
        raise ValueError("launchctl PID-domain creator/services could not be verified")
    services = []
    for line in block[1].splitlines():
        if not line.strip():
            continue
        row = re.fullmatch(r"\s+(\d+)\s+(-|-?\d+)\s+([A-Za-z0-9_.-]+)\s*", line)
        if row is None:
            raise ValueError("Unrecognized launchctl service-table row")
        if row[3].startswith("com.apple.WebKit.") and int(row[1]) > 0:
            services.append({"pid": int(row[1]), "service": row[3], "table_row": line.strip()})
    return creator[1], services


def discover_webkit(reader, pid):
    """A diagnostic PID-domain cohort, not a public ownership API/coalition."""
    host_before = reader.read(pid)
    if "error" in host_before:
        raise ValueError(f"Cannot read host process {pid}: {host_before['error']}")
    target = f"pid/{pid}"
    creator, services = parse_pid_domain(launchctl_print(target), pid)
    verified = []
    for service in services:
        service_target = f"{target}/{service['service']}"
        report = launchctl_print(service_target)
        fields = dict(re.findall(r"^\t([a-z ]+) = ([^\n{]+)$", report, re.MULTILINE))
        if (not report.startswith(f"{service_target} = {{\n") or fields.get("type") != "XPCService"
                or fields.get("state") != "running" or fields.get("pid") != str(service["pid"])
                or not fields.get("domain", "").startswith(f"{target} [")):
            raise ValueError(f"WebKit service identity/domain not verified: {service_target}")
        row = reader.read(service["pid"])
        executable = row.get("executable_path")
        program = fields.get("program")
        if ("error" in row or not executable or not program
                or "/WebKit.framework/" not in executable
                or ".xpc/Contents/MacOS/com.apple.WebKit." not in executable
                or os.path.realpath(program) != os.path.realpath(executable)):
            raise ValueError(f"WebKit executable not verified: {service_target}")
        verified.append({**service, "service_target": service_target,
                         "domain": fields["domain"], "program": program, "identity": identity(row)})
    host_after = reader.read(pid)
    if "error" in host_after or identity(host_before) != identity(host_after):
        raise ValueError("Host identity changed during WebKit discovery")
    return {"timestamp": timestamp(), "method": "launchctl-pid-domain-services-diagnostic-v1",
            "host_identity": identity(host_after), "creator_name": creator,
            "domain_target": target, "services": sorted(verified, key=lambda value: (value["pid"], value["service"])),
            "format_contract": "Diagnostic text, no Apple compatibility guarantee; strict parser rejects unknown layouts.",
            "environment_policy": "Only allowlisted service/identity fields retained; environment blocks omitted."}


def cohort_identity(capture):
    return (capture["host_identity"], [(row["service"], row["identity"]) for row in capture["services"]])


def summarize(samples, pids, timebase):
    processes = []
    for pid in pids:
        rows = [next(row for row in sample["processes"] if row["pid"] == pid) for sample in samples]
        valid = all("error" not in row for row in rows)
        identities = {(row["process_start_mach_ticks"], row["executable_uuid_hex"]) for row in rows if "error" not in row}
        valid = valid and len(identities) == 1
        first, last = rows[0], rows[-1]
        delta = None
        if valid:
            delta = last["user_cpu_mach_ticks"] + last["system_cpu_mach_ticks"] - first["user_cpu_mach_ticks"] - first["system_cpu_mach_ticks"]
            valid = delta >= 0
        seconds = (last["monotonic_ns"] - first["monotonic_ns"]) / 1e9
        cpu_seconds = delta * timebase.numer / timebase.denom / 1e9 if valid else None
        processes.append({
            "pid": pid, "status": "complete" if valid else "incomplete",
            "executable_path": first.get("executable_path"),
            "observed_duration_seconds": seconds,
            "cpu_seconds": cpu_seconds,
            "cpu_percent_one_core": cpu_seconds / seconds * 100 if valid and seconds > 0 else None,
            "rss_before_bytes": first.get("rss_bytes"),
            "rss_after_bytes": last.get("rss_bytes"),
            "rss_sampled_peak_bytes": max(row["rss_bytes"] for row in rows) if valid else None,
            "physical_footprint_before_bytes": first.get("physical_footprint_bytes"),
            "physical_footprint_after_bytes": last.get("physical_footprint_bytes"),
            "physical_footprint_sampled_peak_bytes": max(row["physical_footprint_bytes"] for row in rows) if valid else None,
        })
    complete = all(row["status"] == "complete" for row in processes)
    duration = (samples[-1]["monotonic_ns"] - samples[0]["monotonic_ns"]) / 1e9
    def total(sample, metric):
        return sum(row[metric] for row in sample["processes"]) if complete else None
    cpu = sum(row["cpu_seconds"] for row in processes) if complete else None
    return {
        "status": "complete" if complete else "incomplete",
        "observed_duration_seconds": duration,
        "cpu_seconds": cpu,
        "cpu_percent_one_core": cpu / duration * 100 if complete and duration > 0 else None,
        "sum_rss_before_bytes": total(samples[0], "rss_bytes"),
        "sum_rss_after_bytes": total(samples[-1], "rss_bytes"),
        "sum_rss_sampled_peak_bytes": max(total(s, "rss_bytes") for s in samples) if complete else None,
        "sum_physical_footprint_before_bytes": total(samples[0], "physical_footprint_bytes"),
        "sum_physical_footprint_after_bytes": total(samples[-1], "physical_footprint_bytes"),
        "sum_physical_footprint_sampled_peak_bytes": max(total(s, "physical_footprint_bytes") for s in samples) if complete else None,
        "processes": processes,
    }


def sample_processes(args):
    reader = DarwinReader()
    discovery_before = discover_webkit(reader, args.pid) if args.discover_webkit else None
    related = [row["pid"] for row in discovery_before["services"]] if discovery_before else args.related_pid
    pids = list(dict.fromkeys([args.pid, *related]))
    samples = []
    started = time.monotonic()
    while True:
        before = time.monotonic_ns()
        rows = [reader.read(pid) for pid in pids]
        after = time.monotonic_ns()
        samples.append({"monotonic_ns": (before + after) // 2, "read_duration_ns": after - before, "processes": rows})
        elapsed = time.monotonic() - started
        if elapsed >= args.duration:
            break
        time.sleep(min(args.interval, args.duration - elapsed))
    summary = summarize(samples, pids, reader.timebase)
    related_pids = [pid for pid in pids if pid != args.pid]
    related_summary = summarize(
        [{**sample, "processes": [row for row in sample["processes"] if row["pid"] in related_pids]} for sample in samples],
        related_pids, reader.timebase) if related_pids else None
    discovery_after = None
    discovery_error = None
    if discovery_before:
        try:
            discovery_after = discover_webkit(reader, args.pid)
            if cohort_identity(discovery_before) != cohort_identity(discovery_after):
                discovery_error = "Host or registered WebKit cohort changed between discovery snapshots"
            first_identities = {row["pid"]: identity(row) for row in samples[0]["processes"] if "error" not in row}
            expected = [discovery_before["host_identity"], *[row["identity"] for row in discovery_before["services"]]]
            if any(first_identities.get(row["pid"]) != row for row in expected):
                discovery_error = "A process identity changed between discovery and resource sampling"
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            discovery_error = str(error)
        if discovery_error:
            for aggregate in [summary, related_summary]:
                if aggregate is None:
                    continue
                aggregate["status"] = "incomplete"
                aggregate["attribution_error"] = discovery_error
                for key in list(aggregate):
                    if key.startswith("sum_") or key in ("cpu_seconds", "cpu_percent_one_core"):
                        aggregate[key] = None
    return {
        "host_pid": args.pid,
        "scope": "host-and-webkit-pid-domain-services" if discovery_before else "explicit-host-and-related-pids" if args.related_pid else "host-process-only",
        "selected_pids": pids,
        "attribution_evidence": args.attribution_evidence,
        "attribution_complete": False if related or discovery_before else None,
        "discovery_before": discovery_before,
        "discovery_after": discovery_after,
        "discovery_error": discovery_error,
        "host_summary": summarize(
            [{**sample, "processes": [row for row in sample["processes"] if row["pid"] == args.pid]} for sample in samples],
            [args.pid], reader.timebase),
        "related_processes_summary": related_summary,
        "state": args.state,
        "requested_duration_seconds": args.duration,
        "requested_interval_seconds": args.interval,
        "mach_timebase": {"numer": reader.timebase.numer, "denom": reader.timebase.denom},
        "summary": summary,
        "samples": samples,
        "limitations": [
            "No automatic WebKit/XPC ownership attribution; only selected PIDs are included.",
            "Optional launchctl discovery identifies registered WebKit services in the host PID domain, not exclusive responsibility or all services acting on its behalf.",
            "Matching discovery snapshots cannot detect processes that both start and exit between the snapshots.",
            "Fixed PID set excludes processes created after selection; exits/read failures make summaries incomplete.",
            "RSS sums can double-count shared pages; physical-footprint sums are process-ledger sums, not a deduplicated system total.",
            "Sampled peaks can miss between-sample peaks; sequential process reads are not atomic.",
            "CPU is counter delta over elapsed monotonic time; 100 percent means one fully occupied CPU core.",
        ],
    }


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return number


def positive_pid(value):
    number = int(value)
    if number <= 0 or number > 2**31 - 1:
        raise argparse.ArgumentTypeError("must be a positive PID")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="mode", required=True)
    sizes = commands.add_parser("sizes", help="Measure existing app bundles; does not launch them")
    sizes.add_argument("apps", nargs="+")
    sample = commands.add_parser("sample", help="Read counters from existing macOS processes")
    sample.add_argument("pid", type=positive_pid)
    sample.add_argument("--duration", type=positive, default=10.0)
    sample.add_argument("--interval", type=positive, default=1.0)
    sample.add_argument("--state", required=True, help="Describe the already-prepared app/page/tab state")
    sample.add_argument("--related-pid", type=positive_pid, action="append", default=[])
    sample.add_argument("--discover-webkit", action="store_true", help="Opt in to version-sensitive launchctl PID-domain WebKit service discovery")
    sample.add_argument("--attribution-evidence", help="Saved trace/report or reasoning supporting every related PID")
    args = parser.parse_args()
    if args.mode == "sample" and args.related_pid and not args.attribution_evidence:
        parser.error("--related-pid requires --attribution-evidence; PID/name/parent matches alone are insufficient")
    if args.mode == "sample" and args.discover_webkit and args.related_pid:
        parser.error("Choose either --discover-webkit or explicit --related-pid")
    record = {"schema": "browser-resources-v1", "timestamp": timestamp(), "mode": args.mode,
              "platform": platform.platform(), "os_kernel_version": platform.version(),
              "machine": platform.machine(), "python": platform.python_version()}
    try:
        if args.mode == "sizes":
            record["bundles"] = [bundle_sizes(app) for app in args.apps]
            record["limitations"] = [
                "Logical size sums regular files and symlink text; directory logical sizes are excluded.",
                "Allocated size sums st_blocks times 512 including directories; hardlinked inodes count once and symlinks are not followed.",
                "Allocated size is filesystem-reported allocation, not unique physical APFS storage; clones/compression may affect it.",
                "Sizes exclude user profile, caches, operating-system WebKit frameworks and processes, and dSYM bundles outside the app.",
            ]
        else:
            record.update(sample_processes(args))
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"{error}\n")
    json.dump(record, sys.stdout, indent=2, allow_nan=False)
    print()


if __name__ == "__main__":
    main()
