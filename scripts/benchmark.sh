#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Run baseline and candidate serially with this exact harness and the same display.
# Use just benchmark baseline [core|full|reveal|google]. Results stay in ignored DerivedData.
label="${1:-candidate}"
derived="$PWD/DerivedData"
mode="${2:-core}"
case "$mode" in core|full|reveal|google) ;; *) echo "Expected mode core, full, reveal, or google" >&2; exit 1 ;; esac
run="$derived/Benchmarks/Benchmark-$(date -u +%Y%m%d-%H%M%S)-$(uuidgen)"
results="$run/Results.xcresult"
mkdir -p "$run"
python3 scripts/benchmark-report.py --start-run "$run" --label "$label" --derived-data "$derived"
python3 scripts/benchmark-report.py --verify-fixture
xcodegen generate

# Sample the benchmark host and every WebKit service registered in its PID domain
# during the named quiet windows. The sampler follows the test's phase marker and
# never launches, discovers, or stops an installed Browser application.
cohort_pid=""
cohort_status=0
if [[ "$mode" != "reveal" ]]; then
  workload="core"
  [[ "$mode" == "google" ]] && workload="google"
  python3 scripts/benchmark-cohort.py --log "$run/benchmark.log" --output "$run/cohort" --workload "$workload" &
  cohort_pid=$!
fi
cleanup() {
  if [[ -n "$cohort_pid" ]] && kill -0 "$cohort_pid" 2>/dev/null; then kill "$cohort_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM

# TEST_RUNNER_ forwards variables through xcodebuild to the test host.
# Benchmark inherits Release optimization, with a separate identity and no installation or deployment.
set +e
BROWSER_BENCHMARK=1 BROWSER_BENCHMARK_LABEL="$label" BROWSER_BENCHMARK_MODE="$mode" \
TEST_RUNNER_BROWSER_BENCHMARK=1 TEST_RUNNER_BROWSER_BENCHMARK_LABEL="$label" TEST_RUNNER_BROWSER_BENCHMARK_MODE="$mode" \
xcodebuild -project Browser.xcodeproj -scheme Browser -configuration Benchmark \
  -destination 'platform=macOS,arch=arm64' ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES \
  -derivedDataPath "$derived" -resultBundlePath "$results" \
  -only-testing:BrowserTests/BrowserPerformanceTests/testBrowserBenchmarks \
  -parallel-testing-enabled NO ENABLE_TESTABILITY=YES \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--options=0 test \
  > >(tee "$run/benchmark.log" "$derived/benchmark.log") 2>&1
status=$?
set -e
if [[ -n "$cohort_pid" ]]; then
  set +e
  wait "$cohort_pid"
  cohort_status=$?
  set -e
  cohort_pid=""
fi
overall_status=$status
if [[ "$overall_status" -eq 0 && "$cohort_status" -ne 0 ]]; then overall_status=$cohort_status; fi
python3 scripts/benchmark-report.py --finish-run "$run" --exit-status "$overall_status"
if [[ -d "$results" ]]; then
  mkdir -p "$run/attachments"
  xcrun xcresulttool export attachments --path "$results" --output-path "$run/attachments" || true
fi
echo "XCTest result bundle: $results"
echo "Raw JSON, provenance, and screenshot recovery: $run"
echo "The BROWSER_BENCHMARK_OUTPUT line in $run/benchmark.log names the host-writable temporary directory."
exit "$overall_status"
