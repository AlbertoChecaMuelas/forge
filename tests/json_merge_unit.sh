#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/json_merge_unit.sh — Unit tests for lib/json-merge.sh
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$FORGE_ROOT/lib/json-merge.sh"

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
  rm -rf "$TMPDIR_BASE"/json-merge-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/json-merge-$$-XXXX")"
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

# =============================================================================
# Shared files for tests
# =============================================================================


# =============================================================================
# Test cases
# =============================================================================

# 1. forge_json_set_path produces valid JSON
test_set_path_atomic() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{"foo":"bar"}' > "$target"

  forge_json_set_path "$target" ".baz" '"qux"' >/dev/null 2>&1

  if jq empty "$target" 2>/dev/null; then
    pass "set_path_atomic: result is valid JSON"
  else
    fail "set_path_atomic: result is not valid JSON"
  fi

  local val
  val="$(jq -r '.baz' "$target")"
  assert_eq "set_path_atomic: value set correctly" "qux" "$val"
}

# 2. forge_merge_component_settings with null settings_key applies managed_paths (agents)
test_merge_component_null_settings_key_applies_managed_paths() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings agents "$target" >/dev/null 2>&1

  # model key must be present (read from shared/settings.shared.json via managed_paths)
  local model
  model="$(jq -r '.model // "absent"' "$target")"
  local expected_model
  expected_model="$(jq -r '.model' "$FORGE_ROOT/shared/settings.shared.json")"
  assert_eq "merge_component_null_key: model key set from shared" "$expected_model" "$model"

  # permissions.allow must be a non-empty array
  local allow_len
  allow_len="$(jq '.permissions.allow | length' "$target" 2>/dev/null || echo "0")"
  if [ "${allow_len:-0}" -gt 0 ]; then
    pass "merge_component_null_key: permissions.allow is non-empty array"
  else
    fail "merge_component_null_key: permissions.allow should be non-empty (got $allow_len)"
  fi
}

# 12. forge_merge_component_settings hook entry is idempotent (branch-guard)
test_merge_component_hook_idempotent() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings branch-guard "$target" "--target-dir=$tmp" >/dev/null 2>&1
  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings branch-guard "$target" "--target-dir=$tmp" >/dev/null 2>&1

  # Exactly 1 PreToolUse container matching "branch-guard"
  local bg_count
  bg_count="$(jq '[.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command | test("branch-guard"))] | length' "$target" 2>/dev/null || echo "0")"
  assert_eq "merge_component_hook_idempotent: exactly 1 branch-guard hook entry" "1" "$bg_count"
}

# 13. forge_merge_component_settings {TARGET_DIR} substitution
test_merge_component_target_dir_substitution() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings branch-guard "$target" "--target-dir=/test/sentinel" >/dev/null 2>&1

  # File must NOT contain literal {TARGET_DIR}
  if grep -q '{TARGET_DIR}' "$target"; then
    fail "merge_component_target_dir: literal {TARGET_DIR} still present in merged file"
  else
    pass "merge_component_target_dir: no literal {TARGET_DIR} in merged file"
  fi

  # File MUST contain /test/sentinel somewhere in a hook command
  if grep -q '/test/sentinel' "$target"; then
    pass "merge_component_target_dir: /test/sentinel substituted correctly"
  else
    fail "merge_component_target_dir: /test/sentinel not found in merged file"
  fi
}

# 14. forge_unmerge_component_settings removes hook entry and is idempotent
test_unmerge_component_hook_idempotent() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  # Merge first
  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings branch-guard "$target" "--target-dir=$tmp" >/dev/null 2>&1

  # Sanity: hook present after merge
  local bg_count_before
  bg_count_before="$(jq '[.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command | test("branch-guard"))] | length' "$target" 2>/dev/null || echo "0")"
  if [ "$bg_count_before" -gt 0 ]; then
    pass "unmerge_hook: hook present after merge (sanity)"
  else
    fail "unmerge_hook: hook should be present after merge (sanity, got $bg_count_before)"
  fi

  # First unmerge
  local result1=0
  FORGE_ROOT="$FORGE_ROOT" forge_unmerge_component_settings branch-guard "$target" >/dev/null 2>&1 || result1=$?
  assert_eq "unmerge_hook: first unmerge exits 0" "0" "$result1"

  local bg_count_after1
  bg_count_after1="$(jq '[.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command | test("branch-guard"))] | length' "$target" 2>/dev/null || echo "0")"
  assert_eq "unmerge_hook: hook count == 0 after first unmerge" "0" "$bg_count_after1"

  # Second unmerge (idempotent)
  local result2=0
  FORGE_ROOT="$FORGE_ROOT" forge_unmerge_component_settings branch-guard "$target" >/dev/null 2>&1 || result2=$?
  assert_eq "unmerge_hook: second unmerge exits 0" "0" "$result2"

  local bg_count_after2
  bg_count_after2="$(jq '[.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | select(.command | test("branch-guard"))] | length' "$target" 2>/dev/null || echo "0")"
  assert_eq "unmerge_hook: hook count still 0 after second unmerge" "0" "$bg_count_after2"
}

# 16. forge_merge_component_settings with real {TARGET_DIR} data from shared/settings.shared.json
test_merge_component_target_dir_real_data_substitution() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  # Use branch-guard which has the hook entry with {TARGET_DIR} placeholder
  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings branch-guard "$target" "--target-dir=/tmp/test-home/.claude" >/dev/null 2>&1

  # The substituted command must appear verbatim in the output
  if grep -q 'bash /tmp/test-home/.claude/branch-guard.sh' "$target"; then
    pass "merge_component_real_data: bash /tmp/test-home/.claude/branch-guard.sh present in merged file"
  else
    fail "merge_component_real_data: expected 'bash /tmp/test-home/.claude/branch-guard.sh' not found in merged file"
  fi

  # No literal {TARGET_DIR} must remain
  if grep -q '{TARGET_DIR}' "$target"; then
    fail "merge_component_real_data: literal {TARGET_DIR} still present in merged file"
  else
    pass "merge_component_real_data: no literal {TARGET_DIR} remains in merged file"
  fi
}

# 17. forge_merge_component_settings SessionStart hook entry is idempotent (session-start)
test_merge_component_session_start_hook_idempotent() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings session-start "$target" "--target-dir=$tmp" >/dev/null 2>&1
  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings session-start "$target" "--target-dir=$tmp" >/dev/null 2>&1

  # Exactly 1 SessionStart container matching "session-start"
  local ss_count
  ss_count="$(jq '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | select(.command | test("session-start"))] | length' "$target" 2>/dev/null || echo "0")"
  assert_eq "merge_component_session_start_hook_idempotent: exactly 1 session-start hook entry" "1" "$ss_count"
}

# 18. forge_merge_component_settings SessionStart {TARGET_DIR} substitution
test_merge_component_session_start_target_dir_substitution() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings session-start "$target" "--target-dir=/test/sentinel" >/dev/null 2>&1

  # File must NOT contain literal {TARGET_DIR}
  if grep -q '{TARGET_DIR}' "$target"; then
    fail "merge_component_session_start_target_dir: literal {TARGET_DIR} still present in merged file"
  else
    pass "merge_component_session_start_target_dir: no literal {TARGET_DIR} in merged file"
  fi

  # File MUST contain /test/sentinel somewhere in a hook command
  if grep -q '/test/sentinel' "$target"; then
    pass "merge_component_session_start_target_dir: /test/sentinel substituted correctly"
  else
    fail "merge_component_session_start_target_dir: /test/sentinel not found in merged file"
  fi
}

# 19. forge_unmerge_component_settings removes SessionStart hook entry and is idempotent
test_unmerge_component_session_start_hook_idempotent() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  # Merge first
  FORGE_ROOT="$FORGE_ROOT" forge_merge_component_settings session-start "$target" "--target-dir=$tmp" >/dev/null 2>&1

  # Sanity: hook present after merge
  local ss_count_before
  ss_count_before="$(jq '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | select(.command | test("session-start"))] | length' "$target" 2>/dev/null || echo "0")"
  if [ "$ss_count_before" -gt 0 ]; then
    pass "unmerge_session_start_hook: hook present after merge (sanity)"
  else
    fail "unmerge_session_start_hook: hook should be present after merge (sanity, got $ss_count_before)"
  fi

  # First unmerge
  local result1=0
  FORGE_ROOT="$FORGE_ROOT" forge_unmerge_component_settings session-start "$target" >/dev/null 2>&1 || result1=$?
  assert_eq "unmerge_session_start_hook: first unmerge exits 0" "0" "$result1"

  local ss_count_after1
  ss_count_after1="$(jq '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | select(.command | test("session-start"))] | length' "$target" 2>/dev/null || echo "0")"
  assert_eq "unmerge_session_start_hook: hook count == 0 after first unmerge" "0" "$ss_count_after1"

  # Second unmerge (idempotent)
  local result2=0
  FORGE_ROOT="$FORGE_ROOT" forge_unmerge_component_settings session-start "$target" >/dev/null 2>&1 || result2=$?
  assert_eq "unmerge_session_start_hook: second unmerge exits 0" "0" "$result2"

  local ss_count_after2
  ss_count_after2="$(jq '[.hooks.SessionStart // [] | .[] | .hooks // [] | .[] | select(.command | test("session-start"))] | length' "$target" 2>/dev/null || echo "0")"
  assert_eq "unmerge_session_start_hook: hook count still 0 after second unmerge" "0" "$ss_count_after2"
}

# 15. forge_unmerge_component_settings does not create parent on empty target (statusline)
test_unmerge_component_no_parent_on_empty() {
  local tmp
  tmp="$(make_tmp)"
  local target="$tmp/settings.json"
  printf '{}' > "$target"

  local result=0
  FORGE_ROOT="$FORGE_ROOT" forge_unmerge_component_settings statusline "$target" >/dev/null 2>&1 || result=$?
  assert_eq "unmerge_no_parent: exits 0 on empty target" "0" "$result"

  local has_status_line
  has_status_line="$(jq 'has("statusLine")' "$target" 2>/dev/null || echo "false")"
  assert_eq "unmerge_no_parent: statusLine key not created on empty target" "false" "$has_status_line"
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== json_merge_unit.sh ==="

run_test test_set_path_atomic
run_test test_merge_component_null_settings_key_applies_managed_paths
run_test test_merge_component_hook_idempotent
run_test test_merge_component_target_dir_substitution
run_test test_unmerge_component_hook_idempotent
run_test test_unmerge_component_no_parent_on_empty
run_test test_merge_component_target_dir_real_data_substitution
run_test test_merge_component_session_start_hook_idempotent
run_test test_merge_component_session_start_target_dir_substitution
run_test test_unmerge_component_session_start_hook_idempotent

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
