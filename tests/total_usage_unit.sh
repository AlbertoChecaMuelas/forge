#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/total_usage_unit.sh — Unit tests for shared/total-usage.sh
# Compatible with bash 3.2+.
# Log prefix: [total-usage]
set -euo pipefail

cd "$(dirname "$0")/.."

ARSENAL_ROOT="$(pwd)"
SCRIPT="$ARSENAL_ROOT/shared/total-usage.sh"

FAIL=0
TESTS_RUN=0
TESTS_PASSED=0

# Temporary directories cleaned up on exit
TMPDIR_LIST=""
trap '_cleanup_all' EXIT

_cleanup_all() {
  for d in $TMPDIR_LIST; do
    rm -rf "$d" 2>/dev/null || true
  done
}

_make_tmpdir() {
  local d
  d="$(mktemp -d)"
  TMPDIR_LIST="$TMPDIR_LIST $d"
  echo "$d"
}

# assert_eq <expected> <actual> <message>
assert_eq() {
  local expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$expected" != "$actual" ]; then
    echo "  FAIL: $msg" >&2
    echo "    expected: '$expected'" >&2
    echo "    actual:   '$actual'" >&2
    FAIL=1
    return 1
  fi
  return 0
}

# assert_contains <substring> <actual> <message>
assert_contains() {
  local substring="$1"
  local actual="$2"
  local msg="$3"
  if ! printf '%s' "$actual" | grep -qF "$substring"; then
    echo "  FAIL: $msg" >&2
    echo "    expected to contain: '$substring'" >&2
    echo "    actual:              '$actual'" >&2
    FAIL=1
    return 1
  fi
  return 0
}

# run_test <name> <function>
run_test() {
  local name="$1"
  local fn="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  local before_fail=$FAIL
  printf '  %-60s' "$name"
  if "$fn"; then
    if [ "$FAIL" = "$before_fail" ]; then
      TESTS_PASSED=$((TESTS_PASSED + 1))
      echo "OK"
    else
      echo "FAIL"
    fi
  else
    FAIL=1
    echo "FAIL (exception)"
  fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# _make_jsonl_record <session_id> <timestamp> <model> <input_tokens> <output_tokens>
# Writes a minimal assistant JSONL record to stdout.
_make_jsonl_record() {
  local session="$1"
  local ts="$2"
  local model="$3"
  local input_tok="$4"
  local output_tok="$5"
  printf '{"type":"assistant","sessionId":"%s","timestamp":"%s","message":{"model":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' \
    "$session" "$ts" "$model" "$input_tok" "$output_tok"
}

# _run_script <projects_dir> <cache_file> <ttl> [extra args...]
# Invokes total-usage.sh with isolated env vars, returns stdout.
_run_script() {
  local projects_dir="$1"
  local cache_file="$2"
  local ttl="$3"
  shift 3
  CLAUDE_PROJECTS_DIR="$projects_dir" \
  CLAUDE_USAGE_CACHE="$cache_file" \
  CLAUDE_USAGE_TTL="$ttl" \
    bash "$SCRIPT" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# T1 — Empty PROJECTS_DIR: no .jsonl files → fallback output
# ---------------------------------------------------------------------------
test_t1_empty_projects_dir() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  local cache_file="$tmpdir/cache.txt"
  mkdir -p "$projects_dir"

  local output
  output="$(_run_script "$projects_dir" "$cache_file" 30)"

  # Expect 6 tab-separated fields all zero
  assert_eq "0	0	0	0	0	0" "$output" "T1: empty dir should output all-zero TSV"
}

# ---------------------------------------------------------------------------
# T2 — Cache miss → compute: known tokens appear in output
# ---------------------------------------------------------------------------
test_t2_cache_miss_compute() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  local cache_file="$tmpdir/cache.txt"
  mkdir -p "$projects_dir/proj-abc"

  # claude-sonnet-4: $3/$15 per million input/output
  # input=1000, output=500 → cost = (1000*3 + 500*15)/1000000 = 0.0105 USD
  # total_tokens = 1000 + 500 = 1500
  _make_jsonl_record "sess-1" "2026-05-31T10:00:00.000Z" "claude-sonnet-4" 1000 500 \
    > "$projects_dir/proj-abc/session.jsonl"

  local output
  output="$(_run_script "$projects_dir" "$cache_file" 30)"

  # 6 fields: total_usd, today_usd, days, sessions, total_tokens, session_usd
  local total_tokens
  total_tokens="$(printf '%s' "$output" | cut -f5)"
  assert_eq "1500" "$total_tokens" "T2: total_tokens should be 1500 (1000 input + 500 output)"

  local sessions_count
  sessions_count="$(printf '%s' "$output" | cut -f4)"
  assert_eq "1" "$sessions_count" "T2: sessions_count should be 1"

  local days_count
  days_count="$(printf '%s' "$output" | cut -f3)"
  assert_eq "1" "$days_count" "T2: days_count should be 1"

  # total_usd should be > 0 (non-zero cost)
  local total_usd
  total_usd="$(printf '%s' "$output" | cut -f1)"
  assert_contains "0.0" "$total_usd" "T2: total_usd should be a non-zero decimal"
}

# ---------------------------------------------------------------------------
# T3 — Cache hit: pre-existing fresh cache → output comes from cache
# ---------------------------------------------------------------------------
test_t3_cache_hit() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  local cache_file="$tmpdir/cache.txt"
  mkdir -p "$projects_dir/proj-abc"

  # Write a real fixture (different tokens so we can detect if it recomputes)
  _make_jsonl_record "sess-2" "2026-05-31T11:00:00.000Z" "claude-sonnet-4" 9999 9999 \
    > "$projects_dir/proj-abc/session.jsonl"

  # Write a cache with known sentinel content (fresh: mtime = now)
  # Cache format matches what compute() produces: a TSV line
  printf '42.0\t10.0\t7\t3\t99999\t0\n' > "$cache_file"
  # touch to make it definitely newer than 1 second ago (already fresh)

  # TTL = 60 so cache is valid
  local output
  output="$(_run_script "$projects_dir" "$cache_file" 60)"

  # Should get the sentinel cache content, NOT the recomputed fixture tokens
  assert_eq "42.0	10.0	7	3	99999	0" "$output" "T3: output should come from cache (sentinel value)"
}

# ---------------------------------------------------------------------------
# T4 — refresh mode: cache is fresh but 'refresh' forces recompute
# ---------------------------------------------------------------------------
test_t4_refresh_mode() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  local cache_file="$tmpdir/cache.txt"
  mkdir -p "$projects_dir/proj-abc"

  # Fixture: 200 input + 100 output = 300 tokens
  _make_jsonl_record "sess-3" "2026-05-30T09:00:00.000Z" "claude-sonnet-4" 200 100 \
    > "$projects_dir/proj-abc/session.jsonl"

  # Write stale-looking sentinel cache that would give wrong answer
  printf '99.9\t50.0\t100\t50\t888888\t0\n' > "$cache_file"

  # Run with refresh mode — should ignore cache and recompute
  local output
  output="$(_run_script "$projects_dir" "$cache_file" 3600 refresh)"

  local total_tokens
  total_tokens="$(printf '%s' "$output" | cut -f5)"
  assert_eq "300" "$total_tokens" "T4: refresh should recompute — total_tokens must be 300, not the cached 888888"
}

# ---------------------------------------------------------------------------
# T5 — --session <id>: 6th field is per-session cost only
# ---------------------------------------------------------------------------
test_t5_session_filter() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  local cache_file="$tmpdir/cache.txt"
  mkdir -p "$projects_dir/proj-abc"

  # Two sessions in the same file:
  #   sess-A: 1000 input + 0 output (claude-sonnet-4 @ $3/$15/M) → cost = 0.003 USD
  #   sess-B: 0 input + 1000 output                              → cost = 0.015 USD
  {
    _make_jsonl_record "sess-A" "2026-05-31T08:00:00.000Z" "claude-sonnet-4" 1000 0
    _make_jsonl_record "sess-B" "2026-05-31T08:01:00.000Z" "claude-sonnet-4" 0 1000
  } > "$projects_dir/proj-abc/session.jsonl"

  local output
  output="$(_run_script "$projects_dir" "$cache_file" 30 --session "sess-A")"

  # 6 fields; field 6 = cost for sess-A only = 0.003
  local session_cost
  session_cost="$(printf '%s' "$output" | cut -f6)"

  # sess-A cost: 1000 * 3 / 1000000 = 0.003
  assert_eq "0.003" "$session_cost" "T5: 6th field should be sess-A cost (0.003), not sess-B cost"

  # Total tokens should be sum of both sessions: 1000 + 1000 = 2000
  local total_tokens
  total_tokens="$(printf '%s' "$output" | cut -f5)"
  assert_eq "2000" "$total_tokens" "T5: total_tokens should be 2000 (both sessions)"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== total_usage_unit.sh ==="
echo ""

run_test "T1 empty_projects_dir → zero fallback" test_t1_empty_projects_dir
run_test "T2 cache_miss → compute with known tokens" test_t2_cache_miss_compute
run_test "T3 cache_hit → output from cache sentinel" test_t3_cache_hit
run_test "T4 refresh mode → ignores cache, recomputes" test_t4_refresh_mode
run_test "T5 --session filter → 6th field is per-session cost" test_t5_session_filter

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "ALL PASS"
  exit 0
fi
