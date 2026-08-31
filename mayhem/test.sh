#!/usr/bin/env bash
#
# mayhem/test.sh — RUN tz-rs's functional oracle (already built by mayhem/build.sh). Does NOT
# build anything (a missing binary is a build.sh bug, so we fail loudly rather than rebuild).
#
# Two layers, deliberately NOT relying on `cargo test` alone as the oracle (a suite driven purely
# by a runner's exit code, or a test binary the fleet's LD_PRELOAD sabotage shim cannot intercept,
# would "pass" even when the program is neutered to a no-op — see netnew-worker-prompt.md §4):
#
#   1. PRIMARY oracle — mayhem/kat_probe: a small, DYNAMICALLY LINKED known-answer-test binary
#      (mayhem/kat) that asserts EXACT values from tz-rs's own public API and doctest (localtime/
#      gmtime/mktime-equivalent surface: TimeZone lookups, TZif parsing, POSIX TZ parsing,
#      calendar<->Unix-time conversion). We assert its exact summary line AND a handful of its
#      exact per-check output lines, not just its exit code — so a neutered binary (empty stdout,
#      because the sabotage shim _exit(0)s it before main() ever prints anything) fails here.
#   2. SECONDARY signal — the project's own precompiled `cargo test` binary (unit tests embedded
#      in src/**/*.rs), folded into the same CTRF summary for extra coverage.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

overall_failed=0
total_passed=0
total_failed=0

# ── 1) PRIMARY: the KAT probe ────────────────────────────────────────────────────────────────
KAT_BIN="/mayhem/kat_probe"
if [ ! -x "$KAT_BIN" ]; then
  echo "FAIL: $KAT_BIN missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "tz-rs-kat" 0 1
  exit 1
fi

kat_out="$("$KAT_BIN" 2>&1)"
kat_rc=$?
printf '%s\n' "$kat_out"

# Exact known-answer assertions (a subset of kat_probe's own per-check lines) — lifted from
# tz-rs's own published doctest / unit-test fixtures, so a neutered binary that prints nothing (or
# wrong values) fails these greps deterministically.
kat_assert_failed=0
assert_line() {
  if ! grep -qF "$1" <<<"$kat_out"; then
    echo "FAIL: KAT probe did not print expected line: $1" >&2
    kat_assert_failed=1
  fi
}
assert_line 'ok   UtcDateTime.unix_time: 946684800'
assert_line 'ok   TimeZone::utc().ut_offset: 0'
assert_line 'ok   TimeZone::fixed(-3600).ut_offset: -3600'
assert_line 'ok   from_posix_tz(HST10).ut_offset: -36000'
assert_line 'ok   America/New_York@2000-01-01T00:00:00Z.ut_offset: -18000'
assert_line 'ok   v1_leap_seconds.leap_second_count: 27'
assert_line 'ok   DateTime::find(UTC-1).unix_time: 946688400'

# The probe's own summary line: EXACT expected count (18 checks in the healthy path — see
# mayhem/kat/src/main.rs), 0 failed.
kat_summary="$(grep -oE 'kat_probe: [0-9]+ passed, [0-9]+ failed' <<<"$kat_out" || true)"
if [ "$kat_summary" != "kat_probe: 18 passed, 0 failed" ]; then
  echo "FAIL: KAT probe summary was '$kat_summary', expected 'kat_probe: 18 passed, 0 failed'" >&2
  kat_assert_failed=1
fi
[ "$kat_rc" -eq 0 ] || { echo "FAIL: KAT probe exited $kat_rc" >&2; kat_assert_failed=1; }

if [ "$kat_assert_failed" -eq 0 ]; then
  echo "PASS: KAT probe — 18/18 known-answer assertions correct"
  total_passed=$((total_passed + 18))
else
  echo "FAIL: KAT probe did not produce the expected known-answer output"
  overall_failed=1
  total_failed=$((total_failed + 18))
fi

# ── 2) SECONDARY: the project's own precompiled unit-test binary ────────────────────────────
test_bin="$(find "$SRC/mayhem/test-target/debug/deps" -maxdepth 1 -type f -executable -name 'tz-*' 2>/dev/null | head -1)"
if [ -z "$test_bin" ]; then
  echo "FAIL: no precompiled cargo-test binary found under mayhem/test-target/debug/deps (build.sh should have produced one)" >&2
  overall_failed=1
  total_failed=$((total_failed + 1))
else
  echo "=== running project unit tests: $test_bin ==="
  json_out="$("$test_bin" --test-threads=1 -Z unstable-options --format json 2>&1)" && test_rc=0 || test_rc=$?
  printf '%s\n' "$json_out"
  # `"type": "suite"` — note the SPACE after the colon in cargo/libtest's own JSON emitter; a
  # naive no-space grep silently matches zero lines and reports a false 0/0 pass.
  suite_line="$(grep -E '"type": *"suite"' <<<"$json_out" | grep -E '"event": *"(ok|failed)"' | tail -1)"
  if [ -z "$suite_line" ]; then
    echo "FAIL: could not find a libtest suite summary line in cargo-test JSON output" >&2
    overall_failed=1
    total_failed=$((total_failed + 1))
  else
    proj_passed="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['passed'])" "$suite_line")"
    proj_failed="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['failed'])" "$suite_line")"
    echo "project unit tests: $proj_passed passed, $proj_failed failed"
    total_passed=$((total_passed + proj_passed))
    total_failed=$((total_failed + proj_failed))
    [ "$proj_failed" -eq 0 ] && [ "$test_rc" -eq 0 ] || overall_failed=1
  fi
fi

emit_ctrf "tz-rs-kat+cargo-test" "$total_passed" "$total_failed"
[ "$overall_failed" -eq 0 ] && [ "$total_failed" -eq 0 ]
