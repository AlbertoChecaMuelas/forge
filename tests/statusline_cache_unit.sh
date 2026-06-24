#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/statusline_cache_unit.sh — Unit tests for cache badge threshold in shared/statusline.sh
# Mocks external dependencies (total-usage.sh, git) by using a temp HOME without them
# and running from /tmp (non-git path).
# Compatible with bash 3.2+.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$FORGE_ROOT/shared/statusline.sh"

# Test harness
FAIL=0
PASS=0
TMPDIR_BASE="$FORGE_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

# Pattern-based cleanup: the make_* helpers run inside command substitutions
# (subshells), so accumulating paths in a parent-shell variable never works
# (the list stays empty and nothing was removed — tests/.tmp grew unbounded).
# The mktemp template embeds $$ (parent PID even inside subshells), so this
# glob removes exactly this run's artifacts.
cleanup() {
  rm -rf "$TMPDIR_BASE"/scu-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_home() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/scu-$$-XXXX")"
  echo "$dir"
}

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

run_test() {
  local name="$1"
  echo "--- $name"
  "$name"
}

# Helper: strip ANSI escape codes
strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g'
}

# Helper: build minimal JSON input for statusline.sh with cache fields
# Usage: make_cache_json <cache_read> <cache_create>
make_cache_json() {
  local cache_read="$1"
  local cache_create="$2"
  printf '{"model":{"display_name":"claude-haiku"},"context_window":{"used_percentage":10,"cache_read_tokens":%d,"cache_creation_tokens":%d},"cost":{"total_cost_usd":0},"workspace":{"current_dir":"/tmp"}}' \
    "$cache_read" "$cache_create"
}

# Run statusline.sh with a temp HOME (no total-usage.sh) from /tmp
run_statusline() {
  local json="$1"
  local tmp_home
  tmp_home="$(make_home)"
  # Do NOT create total-usage.sh → the stats block is skipped
  HOME="$tmp_home" bash "$SCRIPT" <<< "$json" 2>/dev/null
}

# =============================================================================
# T1 — cache_read=150, cache_create=60 → total=210 (>200): badge "cache:" IS present
# =============================================================================
test_cache_badge_above_threshold_present() {
  local output
  output=$(run_statusline "$(make_cache_json 150 60)")

  local plain
  plain=$(printf '%s' "$output" | strip_ansi)
  if printf '%s' "$plain" | grep -q "cache:"; then
    pass "cache_above_threshold: badge 'cache:' present (total=210)"
  else
    fail "cache_above_threshold: badge 'cache:' NOT found (total=210, got: $plain)"
  fi
}

# =============================================================================
# T2 — cache_read=100, cache_create=99 → total=199 (<=200): badge ABSENT
# =============================================================================
test_cache_badge_below_threshold_absent() {
  local output
  output=$(run_statusline "$(make_cache_json 100 99)")

  local plain
  plain=$(printf '%s' "$output" | strip_ansi)
  if printf '%s' "$plain" | grep -q "cache:"; then
    fail "cache_below_threshold: badge 'cache:' unexpectedly found (total=199, got: $plain)"
  else
    pass "cache_below_threshold: badge 'cache:' absent (total=199)"
  fi
}

# =============================================================================
# T3 — cache_read=100, cache_create=100 → total=200 (exactly 200, boundary): badge ABSENT
# (condition is > 200, not >= 200)
# =============================================================================
test_cache_badge_at_boundary_absent() {
  local output
  output=$(run_statusline "$(make_cache_json 100 100)")

  local plain
  plain=$(printf '%s' "$output" | strip_ansi)
  if printf '%s' "$plain" | grep -q "cache:"; then
    fail "cache_at_boundary: badge 'cache:' unexpectedly found (total=200 is not >200, got: $plain)"
  else
    pass "cache_at_boundary: badge 'cache:' absent (total=200, boundary)"
  fi
}

# =============================================================================
# T4 — cache_read=30, cache_create=270 → total=300, pct=10 (red zone):
#      badge present, red color code before percentage
# =============================================================================
test_cache_badge_red_zone_color() {
  local raw_output
  raw_output=$(run_statusline "$(make_cache_json 30 270)")

  # plain text: badge must be present
  local plain
  plain=$(printf '%s' "$raw_output" | strip_ansi)
  if ! printf '%s' "$plain" | grep -q "cache:"; then
    fail "cache_red_zone: badge 'cache:' NOT found (total=300, pct=10%)"
    return
  fi
  pass "cache_red_zone: badge 'cache:' present (total=300, pct=10%)"

  # raw: red color code (\033[31m) must appear before the percentage in the cache segment
  # Extract the portion from "cache:" onward from the raw output
  local cache_segment
  cache_segment=$(printf '%s' "$raw_output" | grep -oP 'cache:.*?%' 2>/dev/null || true)
  # Fallback for systems without grep -P
  if [ -z "$cache_segment" ]; then
    cache_segment=$(printf '%s' "$raw_output" | grep -o $'cache:.*%' | head -1 || true)
  fi

  if printf '%s' "$cache_segment" | grep -q $'\033\[31m'; then
    pass "cache_red_zone: red color code found in cache segment"
  else
    fail "cache_red_zone: red color code NOT found in cache segment (cache_segment: $cache_segment)"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== statusline_cache_unit.sh ==="

run_test test_cache_badge_above_threshold_present
run_test test_cache_badge_below_threshold_absent
run_test test_cache_badge_at_boundary_absent
run_test test_cache_badge_red_zone_color

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
