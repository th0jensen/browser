#!/usr/bin/env python3
"""Capture registered WebKit services only inside named quiet benchmark windows."""
import argparse
import ctypes
import json
from pathlib import Path
import re
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--log", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--duration", type=float, default=10)
parser.add_argument("--timeout", type=float, default=400)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
expected = {"new_tab", "static_color_page"}
captured = {}
directory = None
offset = 0
pending_line = ""
deadline = time.monotonic() + args.timeout
sampler = Path(__file__).with_name("browser-resources.py")

class MachTimebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

# Python's monotonic epoch is unspecified and differs from systemUptime on this host.
system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
system.mach_absolute_time.restype = ctypes.c_uint64
timebase = MachTimebase()
if system.mach_timebase_info(ctypes.byref(timebase)) != 0 or not timebase.denom:
    raise SystemExit("Could not read Mach uptime timebase")

def uptime():
    return system.mach_absolute_time() * timebase.numer / timebase.denom / 1e9

while time.monotonic() < deadline:
    if directory is None and args.log.exists():
        with args.log.open(errors="replace") as stream:
            stream.seek(offset)
            text = stream.read()
            offset = stream.tell()
        lines = (pending_line + text).splitlines(keepends=True)
        pending_line = ""
        if lines and not lines[-1].endswith(("\n", "\r")):
            pending_line = lines.pop()
        match = re.search(r"BROWSER_BENCHMARK_OUTPUT=([^\r\n]+)", "".join(lines))
        if match:
            directory = Path(match.group(1).strip())
            print(f"Following quiet windows in {directory}", flush=True)
    if directory is not None:
        try:
            phase = json.loads((directory / "resource-phase.json").read_text())
        except (OSError, ValueError):
            phase = {}
        name = phase.get("name")
        if name in expected and name not in captured and phase.get("status") == "sampling":
            elapsed = uptime() - phase["startedUptime"]
            remaining = phase["duration"] - elapsed
            if elapsed >= 5 and remaining >= args.duration + 2:
                print(f"Sampling {name}, PID {phase['pid']}, {remaining:.1f}s remaining", flush=True)
                result = subprocess.run([
                    sys.executable, str(sampler), "sample", str(phase["pid"]), "--discover-webkit",
                    "--state", f"Release XCTest fixture: {name}; registered PID-domain WebKit services",
                    "--duration", str(args.duration), "--interval", "1",
                ], text=True, capture_output=True)
                (args.output / f"{name}.json").write_text(result.stdout)
                (args.output / f"{name}.stderr.txt").write_text(result.stderr)
                captured[name] = {"exit_status": result.returncode, "phase": phase,
                                  "sampling_started_after_phase_seconds": elapsed}
                print(f"Finished {name}: exit {result.returncode}", flush=True)
        try:
            status = json.loads((directory / "results.json").read_text()).get("status", "running")
        except (OSError, ValueError):
            status = "running"
        if status != "running" or expected <= captured.keys():
            break
    time.sleep(0.1)

complete = expected <= captured.keys() and all(value["exit_status"] == 0 for value in captured.values())
manifest = {"status": "complete" if complete else "incomplete", "captures": captured,
            "missing": sorted(expected - captured.keys()), "benchmark_output": str(directory) if directory else None,
            "scope": "Host and WebKit services registered in its PID domain. See each JSON's attribution and identity checks."}
(args.output / "manifest.json").write_text(json.dumps(manifest, indent=2))
raise SystemExit(0 if complete else 1)
