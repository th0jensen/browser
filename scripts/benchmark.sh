#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Run baseline and candidate serially with this exact harness and the same display.
# Use just benchmark baseline [core|full|reveal]. Results stay in ignored DerivedData.
label="${1:-candidate}"
derived="$PWD/DerivedData"
mode="${2:-core}"
case "$mode" in core|full|reveal) ;; *) echo "Expected mode core, full, or reveal" >&2; exit 1 ;; esac
run="$derived/Benchmarks/Benchmark-$(date -u +%Y%m%d-%H%M%S)-$(uuidgen)"
results="$run/Results.xcresult"
mkdir -p "$run"
python3 scripts/benchmark-report.py --start-run "$run" --label "$label" --derived-data "$derived"
python3 scripts/benchmark-report.py --verify-fixture
xcodegen generate

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
python3 scripts/benchmark-report.py --finish-run "$run" --exit-status "$status"
if [[ -d "$results" ]]; then
  mkdir -p "$run/attachments"
  xcrun xcresulttool export attachments --path "$results" --output-path "$run/attachments" || true
fi
echo "XCTest result bundle: $results"
echo "Raw JSON, provenance, and screenshot recovery: $run"
echo "The BROWSER_BENCHMARK_OUTPUT line in $run/benchmark.log names the host-writable temporary directory."
exit "$status"
