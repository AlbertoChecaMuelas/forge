#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/subagent_statusline_unit.sh — Unit tests for shared/subagent-statusline.sh
# Compatible with bash 3.2+.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$FORGE_ROOT/shared/subagent-statusline.sh"

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

# =============================================================================
# T1 — Minimal input (model only): exits 0, stdout contains model name
# =============================================================================
test_minimal_input_exits_zero_contains_model() {
  local output
  local exit_code=0
  output=$(printf '{"model":{"id":"claude-haiku"}}' | bash "$SCRIPT") || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "minimal_input: exits 0"
  else
    fail "minimal_input: expected exit 0, got $exit_code"
  fi

  local plain
  plain=$(printf '%s' "$output" | strip_ansi)
  if printf '%s' "$plain" | grep -q "claude-haiku"; then
    pass "minimal_input: output contains model name"
  else
    fail "minimal_input: output does not contain 'claude-haiku' (got: $plain)"
  fi
}

# =============================================================================
# T2 — Full input with agent.name: output contains bracketed prefix (dim + name)
# =============================================================================
test_agent_name_present_shows_prefix() {
  local output
  output=$(printf '{"model":{"id":"claude-haiku"},"agent":{"name":"senior"}}' | bash "$SCRIPT")

  local plain
  plain=$(printf '%s' "$output" | strip_ansi)
  if printf '%s' "$plain" | grep -q "\[senior\]"; then
    pass "agent_name_present: output contains [senior] prefix"
  else
    fail "agent_name_present: output does not contain '[senior]' (got: $plain)"
  fi
}

# =============================================================================
# T3 — Full input without agent.name: output does NOT contain bracketed prefix
# =============================================================================
test_no_agent_name_no_prefix() {
  local output
  output=$(printf '{"model":{"id":"claude-haiku"},"context_window":{"used_percentage":45}}' | bash "$SCRIPT")

  local plain
  plain=$(printf '%s' "$output" | strip_ansi)
  if printf '%s' "$plain" | grep -qE '\[[a-z]'; then
    fail "no_agent_name: output unexpectedly contains a bracketed prefix (got: $plain)"
  else
    pass "no_agent_name: output does not contain a bracketed prefix"
  fi
}

# =============================================================================
# T4 — used_percentage=45 (green <70): no red \033[31m or yellow \033[33m before %
# =============================================================================
test_green_zone_no_red_yellow_before_pct() {
  local raw_output
  raw_output=$(printf '{"model":{"id":"claude-haiku"},"context_window":{"used_percentage":45}}' | bash "$SCRIPT")

  # Check the raw bytes: neither red (31m) nor yellow (33m) should precede "45%"
  # Strategy: split at "45%" — everything before should not end with red/yellow codes
  local before_pct
  before_pct=$(printf '%s' "$raw_output" | sed 's/45%.*//')

  if printf '%s' "$before_pct" | grep -qP '\033\[31m|\033\[33m' 2>/dev/null || \
     printf '%s' "$before_pct" | grep -q $'\033\[31m' || \
     printf '%s' "$before_pct" | grep -q $'\033\[33m'; then
    fail "green_zone: red or yellow color code found before 45%"
  else
    pass "green_zone: no red or yellow color code before 45%"
  fi
}

# =============================================================================
# T5 — used_percentage=75 (yellow 70-90): yellow color code appears before 75%
# =============================================================================
test_yellow_zone_color_before_pct() {
  local raw_output
  raw_output=$(printf '{"model":{"id":"claude-haiku"},"context_window":{"used_percentage":75}}' | bash "$SCRIPT")

  local before_pct
  before_pct=$(printf '%s' "$raw_output" | sed 's/75%.*//')

  if printf '%s' "$before_pct" | grep -q $'\033\[33m'; then
    pass "yellow_zone: yellow color code found before 75%"
  else
    fail "yellow_zone: yellow color code NOT found before 75%"
  fi
}

# =============================================================================
# T6 — used_percentage=92 (red >=90): red color code appears before 92%
# =============================================================================
test_red_zone_color_before_pct() {
  local raw_output
  raw_output=$(printf '{"model":{"id":"claude-haiku"},"context_window":{"used_percentage":92}}' | bash "$SCRIPT")

  local before_pct
  before_pct=$(printf '%s' "$raw_output" | sed 's/92%.*//')

  if printf '%s' "$before_pct" | grep -q $'\033\[31m'; then
    pass "red_zone: red color code found before 92%"
  else
    fail "red_zone: red color code NOT found before 92%"
  fi
}

# =============================================================================
# T7 — ctx_size=200000: output contains /200k
# =============================================================================
test_ctx_size_200k_shown() {
  local output
  output=$(printf '{"model":{"id":"claude-haiku"},"context_window":{"used_percentage":50,"context_window_size":200000}}' | bash "$SCRIPT")

  local plain
  plain=$(printf '%s' "$output" | strip_ansi)
  if printf '%s' "$plain" | grep -q "/200k"; then
    pass "ctx_size_200k: output contains /200k"
  else
    fail "ctx_size_200k: output does not contain '/200k' (got: $plain)"
  fi
}

# =============================================================================
# T8 — All fields null/empty: exits 0, non-empty output
# =============================================================================
test_all_fields_null_exits_zero_non_empty() {
  local output
  local exit_code=0
  output=$(printf '{}' | bash "$SCRIPT") || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "all_null: exits 0"
  else
    fail "all_null: expected exit 0, got $exit_code"
  fi

  if [ -n "$output" ]; then
    pass "all_null: output is non-empty"
  else
    fail "all_null: output is empty"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== subagent_statusline_unit.sh ==="

run_test test_minimal_input_exits_zero_contains_model
run_test test_agent_name_present_shows_prefix
run_test test_no_agent_name_no_prefix
run_test test_green_zone_no_red_yellow_before_pct
run_test test_yellow_zone_color_before_pct
run_test test_red_zone_color_before_pct
run_test test_ctx_size_200k_shown
run_test test_all_fields_null_exits_zero_non_empty

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
