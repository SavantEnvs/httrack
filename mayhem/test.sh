#!/usr/bin/env bash
#
# mayhem/test.sh — RUN httrack's own automake test suite (tests/*.test: engine and zlib/WARC self-checks
# via `httrack -#test=`, plus loopback-server crawl, cookie, proxy, htsserver and CLI behaviour tests, all
# asserting on parsed values, bytes and crawled output) against the normal-flags build that mayhem/build.sh
# left in mayhem/build-test. exit 0 = pass.
#
# Selection: every tests/*.test EXCEPT the exclusions below (the exclusion is a regex on the file name,
# so a test added upstream is run by default). Tests needing the network are not excluded: build.sh
# configures --disable-https --disable-online-unit-tests and each of them (crawl-*, crawl_https, the
# https/proxy/cookie ones) reports SKIP under that flag, which the CTRF counts as skipped.
# Excluded, with the reason:
#   *_install-*, *_configure-*, *_vcpkg-*, *_ci-*, *_lint-*  test the packaging/CI/lint tooling (staged
#       `make install`, reconfiguring with other flags, vcpkg manifests, CI workflows, shellcheck-style
#       lints), not httrack's behaviour; they need other toolchains and a writable install tree.
#   378_line-endings   scans every tracked file for CR line endings; our additive mayhem/fuzz-arc seeds
#       are .arc files that legitimately carry CRs, so it fails on the integration layer, not on httrack.
#   398_engine-build-features   compares the kernel's MPTCP support against config.h, so it depends on
#       the host kernel the container happens to run on (fails here: kernel says 1, config.h says 0).
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

TB="$SRC/mayhem/build-test"
[ -f "$TB/tests/Makefile" ] && [ -x "$TB/src/httrack" ] || { echo "mayhem/test.sh: $TB not built — mayhem/build.sh must run first" >&2; emit_ctrf "automake-check" 0 1 0; exit 1; }

EXCLUDE_RE='^[0-9]+_(install|configure|vcpkg|ci|lint)-|^(378_line-endings|398_engine-build-features)\.test$'
TESTS_LIST="$(cd "$SRC/tests" && ls ./*.test | sed 's|^\./||' | grep -vE "$EXCLUDE_RE" | tr '\n' ' ')"
LOG="$(mktemp)"
make -C "$TB/tests" -j"$MAYHEM_JOBS" check TESTS="$TESTS_LIST" >"$LOG" 2>&1
grep -E '^(FAIL|ERROR|XPASS):' "$LOG" || true

count() { sed -n "s/^# $1: *//p" "$LOG" | tail -1; }
pass="$(count PASS)"; xfail="$(count XFAIL)"; skip="$(count SKIP)"
fail="$(count FAIL)"; err="$(count ERROR)"; xpass="$(count XPASS)"
total="$(count TOTAL)"
if [ -z "$total" ] || [ "${total:-0}" -eq 0 ]; then
  tail -30 "$LOG" >&2
  echo "mayhem/test.sh: the automake harness reported no tests" >&2
  emit_ctrf "automake-check" 0 1 0; exit 1
fi
emit_ctrf "automake-check" $(( ${pass:-0} + ${xfail:-0} )) $(( ${fail:-0} + ${err:-0} + ${xpass:-0} )) "${skip:-0}"
