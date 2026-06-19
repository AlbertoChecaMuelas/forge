#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/readme_sync_unit.sh — Structural parity between README.md (EN, canonical)
# and README.es.md (ES). Both files must have the same number of headings per
# level, fenced code blocks and tables, so a change to one without syncing the
# other (see skills/sync-readme) fails CI.
# Compatible with bash 3.2+.
set -euo pipefail

ARSENAL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README_EN="$ARSENAL_ROOT/README.md"
README_ES="$ARSENAL_ROOT/README.es.md"

# Test harness
FAIL=0
PASS=0

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    EN: $expected"
    echo "    ES: $actual"
    FAIL=$((FAIL + 1))
  fi
}

run_test() {
  local name="$1"
  echo "--- $name"
  "$name"
}

# count_headings <file> <level>: headings of exactly that level, outside code fences
count_headings() {
  local file="$1"
  local level="$2"
  awk -v lvl="$level" '
    /^```/ { in_fence = !in_fence; next }
    !in_fence {
      prefix = substr($0, 1, lvl + 1)
      hashes = ""
      for (i = 0; i < lvl; i++) hashes = hashes "#"
      if (prefix == hashes " ") count++
    }
    END { print count + 0 }
  ' "$file"
}

count_fences() {
  local file="$1"
  local fences
  fences="$(grep -c '^```' "$file" || true)"
  echo $((fences / 2))
}

count_tables() {
  # Table separator rows (|---...) — one per table
  grep -cE '^\|[-: ]+\|' "$1" || true
}

test_both_readmes_exist() {
  if [ -f "$README_EN" ] && [ -f "$README_ES" ]; then
    echo "  PASS: both README.md and README.es.md exist"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: missing README.md or README.es.md"
    FAIL=$((FAIL + 1))
  fi
}

test_heading_parity() {
  local lvl
  for lvl in 1 2 3 4; do
    assert_eq "heading level $lvl count matches" \
      "$(count_headings "$README_EN" "$lvl")" \
      "$(count_headings "$README_ES" "$lvl")"
  done
}

test_code_fence_parity() {
  assert_eq "fenced code block count matches" \
    "$(count_fences "$README_EN")" "$(count_fences "$README_ES")"
}

test_table_parity() {
  assert_eq "table count matches" \
    "$(count_tables "$README_EN")" "$(count_tables "$README_ES")"
}

test_language_switcher() {
  if grep -qF '[Español](README.es.md)' "$README_EN"; then
    echo "  PASS: README.md links to README.es.md"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: README.md missing the language switcher link"
    FAIL=$((FAIL + 1))
  fi
  if grep -qF '[English](README.md)' "$README_ES"; then
    echo "  PASS: README.es.md links back to README.md"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: README.es.md missing the language switcher link"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== readme_sync_unit.sh ==="

run_test test_both_readmes_exist
run_test test_heading_parity
run_test test_code_fence_parity
run_test test_table_parity
run_test test_language_switcher

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
