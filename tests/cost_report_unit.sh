#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/cost_report_unit.sh — Unit tests for shared/cost-report.sh
# Compatible with bash 3.2+.
# Log prefix: [cost-report]
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"
SCRIPT="$FORGE_ROOT/shared/cost-report.sh"

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

# assert_not_contains <substring> <actual> <message>
assert_not_contains() {
  local substring="$1"
  local actual="$2"
  local msg="$3"
  if printf '%s' "$actual" | grep -qiF "$substring"; then
    echo "  FAIL: $msg" >&2
    echo "    expected NOT to contain: '$substring'" >&2
    echo "    actual:                  '$actual'" >&2
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

# _run_script <projects_dir> [extra args...]
# Invokes cost-report.sh with isolated CLAUDE_PROJECTS_DIR, returns stdout.
_run_script() {
  local projects_dir="$1"
  shift
  CLAUDE_PROJECTS_DIR="$projects_dir" \
    bash "$SCRIPT" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# T1 — header contains `Estimated Cost` and `% Cost`, NOT `Cost USD`
# ---------------------------------------------------------------------------
test_t1_header_columns() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir/proj-test"

  _make_jsonl_record "sess-1" "2026-06-01T10:00:00.000Z" "claude-sonnet-4-6" 1000 500 \
    > "$projects_dir/proj-test/session.jsonl"

  local output
  output="$(_run_script "$projects_dir")"

  assert_contains "Estimated Cost" "$output" "T1: header should contain 'Estimated Cost'"
  assert_contains "% Cost"         "$output" "T1: header should contain '% Cost'"
  assert_not_contains "Cost USD"   "$output" "T1: header must NOT contain 'Cost USD'"
}

# ---------------------------------------------------------------------------
# T2 — cost cell is prefixed with `$`
# ---------------------------------------------------------------------------
test_t2_cost_dollar_prefix() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir/proj-test"

  _make_jsonl_record "sess-1" "2026-06-01T10:00:00.000Z" "claude-sonnet-4-6" 1000 500 \
    > "$projects_dir/proj-test/session.jsonl"

  local output
  output="$(_run_script "$projects_dir")"

  # The sonnet data row should contain a `$` prefix on the cost value
  assert_contains '$' "$output" "T2: sonnet data row should contain cost prefixed with '\$'"
}

# ---------------------------------------------------------------------------
# T3 — `agent_group` absent in text, present in JSON
# ---------------------------------------------------------------------------
test_t3_agent_group_visibility() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir/proj-test"

  _make_jsonl_record "sess-1" "2026-06-01T10:00:00.000Z" "claude-sonnet-4-6" 1000 500 \
    > "$projects_dir/proj-test/session.jsonl"

  local text_output
  text_output="$(_run_script "$projects_dir")"

  local json_output
  json_output="$(_run_script "$projects_dir" --format json)"

  assert_not_contains "agent_group" "$text_output" "T3: text output must NOT contain 'agent_group'"
  assert_contains '"agent_group"'   "$json_output"  "T3: JSON output must contain '\"agent_group\"'"
}

# ---------------------------------------------------------------------------
# T4 — `pct_cost` correct in JSON (two models, known costs)
# ---------------------------------------------------------------------------
test_t4_pct_cost_json() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir/proj-test"

  # Record A: claude-sonnet-4-6, 1,000,000 input, 0 output
  #   cost = 1000000 * 3 / 1000000 = $3.00
  # Record B: claude-haiku-4-5, 1,000,000 input, 0 output
  #   cost = 1000000 * 1 / 1000000 = $1.00
  # Total = $4.00 → sonnet pct ≈ 75, haiku pct ≈ 25
  {
    _make_jsonl_record "sess-A" "2026-06-01T10:00:00.000Z" "claude-sonnet-4-6" 1000000 0
    _make_jsonl_record "sess-B" "2026-06-01T10:01:00.000Z" "claude-haiku-4-5"  1000000 0
  } > "$projects_dir/proj-test/session.jsonl"

  local json_output
  json_output="$(_run_script "$projects_dir" --format json)"

  # Extract pct_cost for sonnet and haiku, round to nearest integer
  local sonnet_pct
  sonnet_pct="$(printf '%s' "$json_output" \
    | jq '[.by_model[] | select(.model_family == "sonnet") | .pct_cost] | add // 0 | round')"

  local haiku_pct
  haiku_pct="$(printf '%s' "$json_output" \
    | jq '[.by_model[] | select(.model_family == "haiku") | .pct_cost] | add // 0 | round')"

  assert_eq "75" "$sonnet_pct" "T4: sonnet pct_cost should round to 75"
  assert_eq "25" "$haiku_pct"  "T4: haiku pct_cost should round to 25"
}

# ---------------------------------------------------------------------------
# T5 — zero-total guard: empty dir produces valid JSON with empty `by_model`
# ---------------------------------------------------------------------------
test_t5_empty_dir_json() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir"

  local json_output
  # Capture exit code explicitly; script must exit 0
  local exit_code=0
  json_output="$(CLAUDE_PROJECTS_DIR="$projects_dir" bash "$SCRIPT" --format json 2>/dev/null)" \
    || exit_code=$?

  assert_eq "0" "$exit_code" "T5: exit code should be 0 for empty dir"
  assert_contains '"by_model"' "$json_output" "T5: JSON must contain '\"by_model\"' key"
  assert_contains '[]'         "$json_output" "T5: JSON must contain '[]' (empty by_model)"
}

# _make_aititle_record <session_id> <ai_title>
# Writes a minimal ai-title JSONL record to stdout.
_make_aititle_record() {
  local session_id="$1" ai_title="$2"
  printf '{"type":"ai-title","sessionId":"%s","aiTitle":"%s","timestamp":"%s"}\n' \
    "$session_id" "$ai_title" "2026-01-01T00:00:00.000Z"
}

# ---------------------------------------------------------------------------
# T6 — `--session` filters by sessionId substring
# ---------------------------------------------------------------------------
test_t6_session_filter_by_id() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir/proj-test"

  {
    _make_jsonl_record "sess-A" "2026-06-01T10:00:00.000Z" "claude-sonnet-4-6" 1000000 0
    _make_jsonl_record "sess-B" "2026-06-01T10:01:00.000Z" "claude-haiku-4-5"  1000000 0
  } > "$projects_dir/proj-test/session.jsonl"

  local json_output
  json_output="$(_run_script "$projects_dir" --session "sess-A" --format json)"

  local top_len
  top_len="$(printf '%s' "$json_output" | jq '.top_sessions | length')"
  assert_eq "1" "$top_len" "T6: top_sessions should have exactly 1 entry"

  local session_id
  session_id="$(printf '%s' "$json_output" | jq -r '.top_sessions[0].session_id')"
  assert_eq "sess-A" "$session_id" "T6: top_sessions[0].session_id should be 'sess-A'"

  local ai_title
  ai_title="$(printf '%s' "$json_output" | jq -r '.top_sessions[0].ai_title')"
  assert_eq "" "$ai_title" "T6: top_sessions[0].ai_title should be empty string"

  local by_model
  by_model="$(printf '%s' "$json_output" | jq -r '[.by_model[].model_family] | join(",")')"
  assert_contains "sonnet" "$by_model" "T6: by_model should contain sonnet"
  assert_not_contains "haiku" "$by_model" "T6: by_model should NOT contain haiku"
}

# ---------------------------------------------------------------------------
# T7 — `--session` filters by aiTitle substring (case-insensitive)
# ---------------------------------------------------------------------------
test_t7_session_filter_by_aititle() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir/proj-test"

  {
    _make_aititle_record "sess-X" "My Feature Branch"
    _make_jsonl_record   "sess-X" "2026-06-01T10:00:00.000Z" "claude-sonnet-4-6" 1000000 0
    _make_jsonl_record   "sess-Y" "2026-06-01T10:01:00.000Z" "claude-haiku-4-5"  1000000 0
  } > "$projects_dir/proj-test/session.jsonl"

  local json_output
  json_output="$(_run_script "$projects_dir" --session "feature" --format json)"

  local top_len
  top_len="$(printf '%s' "$json_output" | jq '.top_sessions | length')"
  assert_eq "1" "$top_len" "T7: top_sessions should have exactly 1 entry"

  local session_id
  session_id="$(printf '%s' "$json_output" | jq -r '.top_sessions[0].session_id')"
  assert_eq "sess-X" "$session_id" "T7: top_sessions[0].session_id should be 'sess-X'"

  local ai_title
  ai_title="$(printf '%s' "$json_output" | jq -r '.top_sessions[0].ai_title')"
  assert_eq "My Feature Branch" "$ai_title" "T7: top_sessions[0].ai_title should be 'My Feature Branch'"

  local by_model
  by_model="$(printf '%s' "$json_output" | jq -r '[.by_model[].model_family] | join(",")')"
  assert_contains "sonnet" "$by_model" "T7: by_model should contain sonnet"
  assert_not_contains "haiku" "$by_model" "T7: by_model should NOT contain haiku"
}

# ---------------------------------------------------------------------------
# T8 — top_sessions includes ai_title in both JSON and text output
# ---------------------------------------------------------------------------
test_t8_aititle_in_json_and_text() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local projects_dir="$tmpdir/projects"
  mkdir -p "$projects_dir/proj-test"

  # Two separate .jsonl files: one per session
  {
    _make_aititle_record "sess-titled"   "Alpha Task"
    _make_jsonl_record   "sess-titled"   "2026-06-01T10:00:00.000Z" "claude-sonnet-4-6" 500000 0
  } > "$projects_dir/proj-test/sess-titled.jsonl"

  {
    _make_jsonl_record   "sess-untitled" "2026-06-01T10:01:00.000Z" "claude-haiku-4-5"  500000 0
  } > "$projects_dir/proj-test/sess-untitled.jsonl"

  # JSON assertions
  local json_output
  json_output="$(_run_script "$projects_dir" --format json)"

  local titled_aititle
  titled_aititle="$(printf '%s' "$json_output" \
    | jq -r '.top_sessions[] | select(.session_id == "sess-titled") | .ai_title')"
  assert_eq "Alpha Task" "$titled_aititle" "T8 JSON: sess-titled ai_title should be 'Alpha Task'"

  local untitled_aititle
  untitled_aititle="$(printf '%s' "$json_output" \
    | jq -r '.top_sessions[] | select(.session_id == "sess-untitled") | .ai_title')"
  assert_eq "" "$untitled_aititle" "T8 JSON: sess-untitled ai_title should be empty string"

  # Text assertions
  local text_output
  text_output="$(_run_script "$projects_dir")"

  assert_contains "Alpha Task"  "$text_output" "T8 text: output should contain 'Alpha Task'"
  assert_contains "(no title)"  "$text_output" "T8 text: output should contain '(no title)'"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== cost_report_unit.sh ==="
echo ""

run_test "T1 header has 'Estimated Cost' and '% Cost', not 'Cost USD'" test_t1_header_columns
run_test "T2 cost cell prefixed with '\$'"                              test_t2_cost_dollar_prefix
run_test "T3 agent_group absent in text, present in JSON"               test_t3_agent_group_visibility
run_test "T4 pct_cost correct in JSON (sonnet=75%, haiku=25%)"         test_t4_pct_cost_json
run_test "T5 empty dir → valid JSON with empty by_model, exit 0"       test_t5_empty_dir_json
run_test "T6 --session filters by sessionId substring"                  test_t6_session_filter_by_id
run_test "T7 --session filters by aiTitle substring (case-insensitive)" test_t7_session_filter_by_aititle
run_test "T8 top_sessions has ai_title in JSON and text output"         test_t8_aititle_in_json_and_text

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "ALL PASS"
  exit 0
fi
