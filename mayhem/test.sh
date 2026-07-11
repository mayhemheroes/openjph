#!/usr/bin/env bash
#
# openjph/mayhem/test.sh — RUN the self-contained encode->decode->compare oracle (built by
# mayhem/build.sh as /mayhem/ojph_oracle) and emit a CTRF (ctrf.io) summary. exit 0 iff it passes.
#
# WHY an oracle and not OpenJPH's gtest suite: the upstream tests/ suite FetchContent's googletest
# AND the external aous72/jp2k_test_codestreams reference-image repo at configure time (network +
# large data), then shells out to ojph_compress/ojph_expand over those images. That is not hermetic
# and not appropriate for a build-time PATCH oracle. mayhem/oracle.cpp instead drives the REAL codec
# round-trip in-process: it encodes synthetic images with the REVERSIBLE (lossless 5/3) path and
# asserts the decode is BIT-EXACT. Lossless => any encoder/decoder/transform regression (or a no-op
# "return success" patch) breaks the round-trip and fails. This script only RUNS the pre-built
# binary; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

OUT="/mayhem"
ORACLE="$OUT/ojph_oracle"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
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

if [ ! -x "$ORACLE" ]; then
  echo "missing $ORACLE — run mayhem/build.sh first" >&2
  emit_ctrf "openjph-roundtrip-oracle" 0 1 0; exit 2
fi

echo "=== running OpenJPH encode->decode round-trip oracle ==="
out="$("$ORACLE" 2>&1)"; rc=$?
echo "$out"

# Parse the oracle's own summary line: "ORACLE_SUMMARY passed=N failed=N total=N"
PASSED=$(printf '%s\n' "$out" | sed -n 's/.*ORACLE_SUMMARY passed=\([0-9][0-9]*\).*/\1/p' | tail -1)
FAILED=$(printf '%s\n' "$out" | sed -n 's/.*ORACLE_SUMMARY .*failed=\([0-9][0-9]*\).*/\1/p' | tail -1)

if [ -z "$PASSED" ] || [ -z "$FAILED" ]; then
  echo "could not parse oracle summary; using exit code $rc" >&2
  if [ "$rc" -eq 0 ]; then emit_ctrf "openjph-roundtrip-oracle" 1 0 0; exit 0; fi
  emit_ctrf "openjph-roundtrip-oracle" 0 1 0; exit 1
fi

emit_ctrf "openjph-roundtrip-oracle" "$PASSED" "$FAILED" 0
