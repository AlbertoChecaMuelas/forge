#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/settings_integration.sh — Integration tests for forge_install_settings
# (Fase 4, Paso 13). Each test runs a full install in an isolated HOME.
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$FORGE_ROOT/install.sh"
SHARED_SETTINGS="$FORGE_ROOT/shared/settings.shared.json"

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
  rm -rf "$TMPDIR_BASE"/sit-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_home() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/sit-$$-XXXX")"
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
# Helper: run install silently with given target and flags
# =============================================================================
do_install() {
  local home_dir="$1"
  shift
  HOME="$home_dir" bash "$INSTALL_SH" install "$@" >/dev/null 2>&1
}

# =============================================================================
# Test 1 — target sin settings.json -> se crea, pasa jq empty, contiene managed_paths
# =============================================================================
test_install_creates_settings_when_missing() {
  local h
  h="$(make_home)"
  # No settings.json in .claude

  do_install "$h" --target=claude

  local sf="$h/.claude/settings.json"
  if [ ! -f "$sf" ]; then
    fail "creates_settings_when_missing: settings.json not created"
    return
  fi

  if jq empty "$sf" 2>/dev/null; then
    pass "creates_settings_when_missing: settings.json is valid JSON"
  else
    fail "creates_settings_when_missing: settings.json is invalid JSON"
    return
  fi

  # Verify a known managed key (model) is present from shared
  local model_val
  model_val="$(jq -r '.model // "null"' "$sf")"
  if [ "$model_val" != "null" ] && [ -n "$model_val" ]; then
    pass "creates_settings_when_missing: model key present from shared"
  else
    fail "creates_settings_when_missing: model key not found in settings.json"
  fi
}

# =============================================================================
# Test 2 — managed keys overwritten
# =============================================================================
test_install_overwrites_managed_keys() {
  local h
  h="$(make_home)"

  local sf="$h/.claude/settings.json"
  mkdir -p "$(dirname "$sf")"
  printf '{"permissions":{"allow":["Bash(ls)"]}}' > "$sf"

  do_install "$h" --target=claude

  local actual_allow expected_allow
  actual_allow="$(jq -c '.permissions.allow' "$sf")"
  expected_allow="$(jq -c '.permissions.allow' "$SHARED_SETTINGS")"
  assert_eq "overwrites_managed_keys: permissions.allow from shared" "$expected_allow" "$actual_allow"
}

# =============================================================================
# Test 4 — .pre-forge backup created with original content
# =============================================================================
test_install_creates_pre_forge_backup() {
  local h
  h="$(make_home)"

  local sf="$h/.claude/settings.json"
  local original='{"original_key":"original_value"}'
  mkdir -p "$(dirname "$sf")"
  printf '%s' "$original" > "$sf"

  do_install "$h" --target=claude

  local pre="${sf}.pre-forge"
  if [ ! -f "$pre" ]; then
    fail "creates_pre_forge_backup: .pre-forge not created"
    return
  fi
  pass "creates_pre_forge_backup: .pre-forge exists"

  # Content must match original byte-for-byte (using diff -q for reliability)
  local orig_tmp
  orig_tmp="$(mktemp)"
  printf '%s' "$original" > "$orig_tmp"
  if diff -q "$orig_tmp" "$pre" >/dev/null 2>&1; then
    pass "creates_pre_forge_backup: .pre-forge content matches original"
  else
    fail "creates_pre_forge_backup: .pre-forge content does NOT match original"
  fi
  rm -f "$orig_tmp"
}

# =============================================================================
# Test 6 — idempotent: 2 installs -> 1 .pre-forge, 0 .forge-bak (no change)
# Decision: second idempotent pass produces same result -> no backup needed.
# =============================================================================
test_install_idempotent_no_double_backup() {
  local h
  h="$(make_home)"

  # First install (no pre-existing settings)
  do_install "$h" --target=claude

  # Second install (settings already merged, should be no-op)
  do_install "$h" --target=claude

  local pre_count bak_count
  pre_count="$(find "$h/.claude" -name "settings.json.pre-forge" 2>/dev/null | wc -l | tr -d ' ')"
  bak_count="$(find "$h/.claude" -name "settings.json.forge-bak-*" 2>/dev/null | wc -l | tr -d ' ')"

  assert_eq "idempotent_no_double_backup: exactly 1 .pre-forge" "1" "$pre_count"
  assert_eq "idempotent_no_double_backup: 0 .forge-bak files (idempotent)" "0" "$bak_count"
}

# =============================================================================
# Test 7 — state file is valid JSON after install
# =============================================================================
test_state_file_has_overlay_backup() {
  local h
  h="$(make_home)"

  do_install "$h" --target=claude

  local state="$h/.forge-state.json"
  if [ ! -f "$state" ]; then
    fail "state_file_valid: state file not found"
    return
  fi

  if ! jq empty "$state" 2>/dev/null; then
    fail "state_file_valid: state file is invalid JSON"
    return
  fi
  pass "state_file_valid: state file is valid JSON"

  # State file must have settings_json_backup.claude entry pointing to .pre-forge
  local bak_path
  bak_path="$(jq -r '.settings.settings_json_backup.claude // empty' "$state")"
  if [ -n "$bak_path" ]; then
    pass "state_file_valid: settings_json_backup.claude present"
  else
    fail "state_file_valid: settings_json_backup.claude missing"
  fi
}

# =============================================================================
# Test 9 — install aborts on corrupt settings.json with no .pre-forge (Bug 2 fix)
# settings.json invalid + no .pre-forge => exit != 0, no new files created.
# =============================================================================
test_install_aborts_on_corrupt_existing_settings_no_pre_forge() {
  local h
  h="$(make_home)"

  local sf="$h/.claude/settings.json"
  mkdir -p "$(dirname "$sf")"
  # Write deliberately invalid JSON (no .pre-forge exists)
  printf 'THIS IS NOT JSON {{{' > "$sf"

  local exit_code=0
  HOME="$h" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "corrupt_no_pre_forge: exit != 0 as expected"
  else
    fail "corrupt_no_pre_forge: expected exit != 0 but got 0"
  fi

  # State file must NOT have been created (install was aborted)
  if [ ! -f "$h/.forge-state.json" ]; then
    pass "corrupt_no_pre_forge: state file not created"
  else
    fail "corrupt_no_pre_forge: state file was created despite abort"
  fi
}

# =============================================================================
# Test 10 — install restores from .pre-forge when target is corrupt (Bug 2 fix)
# Pre-condition: valid .pre-forge exists + settings.json is corrupted manually.
# Expected: install restores settings from .pre-forge, merge completes (exit 0),
# resulting settings.json is valid JSON.
# =============================================================================
test_install_restores_from_pre_forge_when_target_corrupt() {
  local h
  h="$(make_home)"

  local sf="$h/.claude/settings.json"
  mkdir -p "$(dirname "$sf")"
  local original='{"original_key":"original_value"}'
  printf '%s' "$original" > "$sf"

  # First install — this creates .pre-forge and a valid merged settings.json
  do_install "$h" --target=claude

  local pre="${sf}.pre-forge"
  if [ ! -f "$pre" ]; then
    fail "restore_from_pre_forge: .pre-forge not created by first install (precondition)"
    return
  fi

  # Now corrupt settings.json manually (simulates external corruption)
  printf 'CORRUPT {{{' > "$sf"

  # Second install — should detect corruption, restore from .pre-forge, and succeed
  local exit_code=0
  HOME="$h" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "restore_from_pre_forge: exit 0 after restoring from .pre-forge"
  else
    fail "restore_from_pre_forge: exit $exit_code, expected 0"
    return
  fi

  # Result must be valid JSON
  if jq empty "$sf" 2>/dev/null; then
    pass "restore_from_pre_forge: settings.json is valid JSON after restore+merge"
  else
    fail "restore_from_pre_forge: settings.json is invalid JSON after restore+merge"
  fi
}

# =============================================================================
# Test 11 — PreToolUse[0].hooks has exactly 2 hooks (RTK + branch-guard)
# =============================================================================
test_install_hooks_count_and_branch_guard() {
  local h
  h="$(make_home)"

  do_install "$h" --target=claude

  local sf="$h/.claude/settings.json"

  # Assert exactly 2 hooks in PreToolUse[0].hooks
  local hooks_len
  hooks_len="$(jq -r '.hooks.PreToolUse[0].hooks | length' "$sf" 2>/dev/null || echo "ERROR")"
  assert_eq "hooks_count_and_branch_guard: PreToolUse[0].hooks has 2 entries" "2" "$hooks_len"

  # Assert first hook ([0]) contains rtk in its command
  local first_hook_cmd
  first_hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$sf" 2>/dev/null || echo "")"
  if printf '%s' "$first_hook_cmd" | grep -q "rtk"; then
    pass "hooks_count_and_branch_guard: hooks[0].command contains rtk"
  else
    fail "hooks_count_and_branch_guard: hooks[0].command does not contain rtk (got: $first_hook_cmd)"
  fi

  # Assert second hook ([1]) contains branch-guard.sh in its command
  local second_hook_cmd
  second_hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[1].command // empty' "$sf" 2>/dev/null || echo "")"
  if printf '%s' "$second_hook_cmd" | grep -q "branch-guard.sh"; then
    pass "hooks_count_and_branch_guard: hooks[1].command contains branch-guard.sh"
  else
    fail "hooks_count_and_branch_guard: hooks[1].command does not contain branch-guard.sh (got: $second_hook_cmd)"
  fi
}

# =============================================================================
# Test 12 — permissions.deny has the expected "Agent(*)" deny entries
# =============================================================================
test_install_deny_entries_present() {
  local h
  h="$(make_home)"

  do_install "$h" --target=claude

  local sf="$h/.claude/settings.json"
  if [ ! -f "$sf" ]; then
    fail "deny_entries_present: settings.json not found"
    return
  fi

  for entry in "Agent(Explore)" "Agent(Plan)"; do
    local found
    found="$(jq -r --arg e "$entry" '.permissions.deny // [] | index($e) != null' "$sf" 2>/dev/null || echo "false")"
    if [ "$found" = "true" ]; then
      pass "deny_entries_present: permissions.deny contains \"$entry\""
    else
      fail "deny_entries_present: permissions.deny missing \"$entry\""
    fi
  done
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== settings_integration.sh ==="

run_test test_install_creates_settings_when_missing
run_test test_install_overwrites_managed_keys
run_test test_install_creates_pre_forge_backup
run_test test_install_idempotent_no_double_backup
run_test test_state_file_has_overlay_backup
run_test test_install_aborts_on_corrupt_existing_settings_no_pre_forge
run_test test_install_restores_from_pre_forge_when_target_corrupt
run_test test_install_hooks_count_and_branch_guard
run_test test_install_deny_entries_present

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
