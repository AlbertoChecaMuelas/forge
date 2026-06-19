#!/usr/bin/env bash
# tests/run-all.sh — Run all test suites in the arsenal test directory.
# Compatible with bash 3.2+. No associative arrays, no mapfile.
#
# Usage:
#   bash tests/run-all.sh
#   ARSENAL_TEST_FILTER=rtk bash tests/run-all.sh   # only tests whose basename contains "rtk"
#
# Exit code: 0 if all tests pass, 1 if any fail.
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root from this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # REPO_ROOT available to sourced test files if needed
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Collect test files in deterministic (sorted) order.
# Patterns: tests/*_unit.sh, tests/*_integration.sh
# Non-standard files that don't match these patterns are listed explicitly.
# ---------------------------------------------------------------------------
EXTRA_TESTS="$SCRIPT_DIR/test-install-summary.sh"

collect_tests() {
  # Use find and sort for bash 3.2+ compatibility (no glob expansion ordering)
  find "$SCRIPT_DIR" -maxdepth 1 \( -name '*_unit.sh' -o -name '*_integration.sh' \) \
    | sort

  # Explicit extras (non-standard naming)
  local f
  for f in $EXTRA_TESTS; do
    if [ -f "$f" ]; then
      echo "$f"
    fi
  done
}

# ---------------------------------------------------------------------------
# Apply ARSENAL_TEST_FILTER if set
# ---------------------------------------------------------------------------
FILTER="${ARSENAL_TEST_FILTER:-}"

filtered_tests() {
  local f
  while IFS= read -r f; do
    local base
    base="$(basename "$f")"
    if [ -z "$FILTER" ] || [ "${base#*"${FILTER}"}" != "$base" ]; then
      echo "$f"
    fi
  done
}

TESTS="$(collect_tests | filtered_tests)"

if [ -z "$TESTS" ]; then
  if [ -n "$FILTER" ]; then
    echo "No test files match filter: '$FILTER'"
  else
    echo "No test files found in $SCRIPT_DIR"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Run each test
# ---------------------------------------------------------------------------
TOTAL=0
PASSED=0
FAILED=0
SUITE_START=$SECONDS

while IFS= read -r test_file; do
  base="$(basename "$test_file")"
  echo ""
  echo "=== $base ==="

  test_start=$SECONDS
  set +e
  bash "$test_file"
  exit_code=$?
  set -e
  elapsed=$(( SECONDS - test_start ))

  TOTAL=$(( TOTAL + 1 ))
  if [ "$exit_code" -eq 0 ]; then
    PASSED=$(( PASSED + 1 ))
    echo "PASS  $base  (${elapsed}s)"
  else
    FAILED=$(( FAILED + 1 ))
    echo "FAIL  $base  (${elapsed}s, exit=$exit_code)"
  fi
done <<EOF
$TESTS
EOF

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total_elapsed=$(( SECONDS - SUITE_START ))
echo ""
echo "============================================================"
echo " Tests run:  $TOTAL"
echo " Passed:     $PASSED"
echo " Failed:     $FAILED"
echo " Duration:   ${total_elapsed}s"
echo "============================================================"

# Sweep tests/.tmp: suites clean their own artifacts on exit, but aborted or
# killed runs can leave residue behind, and a directory-based plugin install
# copies the whole working tree — stale fixtures once accumulated 285 MB here.
rm -rf "$SCRIPT_DIR/.tmp"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
