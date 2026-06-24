#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/components_catalog_unit.sh — Unit tests for component JSON manifests.
# Verifies that known entries exist in agents.json and statusline.json.
# No install required — queries the JSON files directly with jq.
# Compatible with bash 3.2+.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_JSON="$FORGE_ROOT/shared/components/agents.json"
STATUSLINE_JSON="$FORGE_ROOT/shared/components/statusline.json"
CORE_JSON="$FORGE_ROOT/shared/components/core.json"
COST_REPORT_SKILL_JSON="$FORGE_ROOT/shared/components/cost-report-skill.json"
COST_REPORT_JSON="$FORGE_ROOT/shared/components/cost-report.json"

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

# =============================================================================
# T1 — agents.json symlinks contains entry with src ending in rules/commit-conventions.md
# =============================================================================
test_agents_json_has_commit_conventions() {
  local found
  found="$(jq -r '.symlinks[].src' "$AGENTS_JSON" | grep -c 'rules/commit-conventions\.md' || true)"
  if [ "${found:-0}" -ge 1 ]; then
    pass "agents.json: symlinks contains src ending in 'rules/commit-conventions.md'"
  else
    fail "agents.json: no symlink src ending in 'rules/commit-conventions.md' found"
  fi
}

# =============================================================================
# T2 — agents.json symlinks contains entry with src ending in rules/language-policy.md
# =============================================================================
test_agents_json_has_language_policy() {
  local found
  found="$(jq -r '.symlinks[].src' "$AGENTS_JSON" | grep -c 'rules/language-policy\.md' || true)"
  if [ "${found:-0}" -ge 1 ]; then
    pass "agents.json: symlinks contains src ending in 'rules/language-policy.md'"
  else
    fail "agents.json: no symlink src ending in 'rules/language-policy.md' found"
  fi
}

# =============================================================================
# T3 — statusline.json symlinks contains entry with src ending in subagent-statusline.sh
# =============================================================================
test_statusline_json_has_subagent_statusline() {
  local found
  found="$(jq -r '.symlinks[].src' "$STATUSLINE_JSON" | grep -c 'subagent-statusline\.sh' || true)"
  if [ "${found:-0}" -ge 1 ]; then
    pass "statusline.json: symlinks contains src ending in 'subagent-statusline.sh'"
  else
    fail "statusline.json: no symlink src ending in 'subagent-statusline.sh' found"
  fi
}

# =============================================================================
# T4 — statusline.json manages both statusLine and subagentStatusLine
# =============================================================================
test_statusline_json_manages_subagent_statusline() {
  local managed
  managed="$(jq -c '.managed_paths' "$STATUSLINE_JSON")"
  assert_eq "statusline.json: managed_paths includes statusLine and subagentStatusLine" \
    '["statusLine","subagentStatusLine"]' "$managed"
}

# =============================================================================
# T5 — core.json: plugin companion shape
# =============================================================================
test_core_json_is_plugin_companion() {
  assert_eq "core.json: default is false (opt-in only)" \
    "false" "$(jq -r '.default' "$CORE_JSON")"
  assert_eq "core.json: conflicts with agents, commands and cost-report" \
    '["agents","commands","cost-report"]' "$(jq -c '.conflicts_with' "$CORE_JSON")"
  assert_eq "core.json: claude_md_ref is @CLAUDE-shared.md" \
    "@CLAUDE-shared.md" "$(jq -r '.claude_md_ref' "$CORE_JSON")"
  assert_eq "core.json: target_root_files ships CLAUDE-shared.md" \
    "CLAUDE-shared.md" "$(jq -r '.target_root_files[0].dest' "$CORE_JSON")"
  assert_eq "core.json: settings_key is null (Case A managed_paths merge)" \
    "null" "$(jq -r '.settings_key' "$CORE_JSON")"
}

# =============================================================================
# T6 — core.json managed_paths match agents.json (same settings ownership)
# =============================================================================
test_core_json_managed_paths_match_agents() {
  assert_eq "core.json: managed_paths identical to agents.json" \
    "$(jq -cS '.managed_paths' "$AGENTS_JSON")" \
    "$(jq -cS '.managed_paths' "$CORE_JSON")"
}

# =============================================================================
# T7 — core.json symlink dests reuse the exact paths skills reference
# =============================================================================
test_core_json_symlink_dests() {
  local dests
  dests="$(jq -r '.symlinks[].dest' "$CORE_JSON" | sort | tr '\n' ' ')"
  assert_eq "core.json: symlinks cover only cost-report.sh" \
    "cost-report.sh " \
    "$dests"
}

# =============================================================================
# T8 — cost-report-skill.json: manifest shape
# =============================================================================
test_cost_report_skill_json_shape() {
  # Must exist
  if [ ! -f "$COST_REPORT_SKILL_JSON" ]; then
    fail "cost-report-skill.json: manifest file not found"
    return
  fi

  # Must not have "default": false (so it is a default component)
  local is_opt_in
  is_opt_in="$(jq 'if .default == false then "opt-in" else "default" end' "$COST_REPORT_SKILL_JSON")"
  assert_eq "cost-report-skill.json: is a default component (no default:false)" \
    '"default"' "$is_opt_in"

  # settings_key must be null (no settings overlay)
  assert_eq "cost-report-skill.json: settings_key is null" \
    "null" "$(jq -r '.settings_key' "$COST_REPORT_SKILL_JSON")"

  # claude_md_ref must be null
  assert_eq "cost-report-skill.json: claude_md_ref is null" \
    "null" "$(jq -r '.claude_md_ref' "$COST_REPORT_SKILL_JSON")"

  # managed_paths must be empty
  assert_eq "cost-report-skill.json: managed_paths is empty" \
    "0" "$(jq -r '.managed_paths | length' "$COST_REPORT_SKILL_JSON")"

  # target_root_files must be empty
  assert_eq "cost-report-skill.json: target_root_files is empty" \
    "0" "$(jq -r '.target_root_files | length' "$COST_REPORT_SKILL_JSON")"

  # symlinks must have exactly 1 entry
  assert_eq "cost-report-skill.json: symlinks has exactly 1 entry" \
    "1" "$(jq -r '.symlinks | length' "$COST_REPORT_SKILL_JSON")"
}

# =============================================================================
# T9 — cost-report-skill.json: symlink points to skills/cost-report/SKILL.md
# =============================================================================
test_cost_report_skill_symlink_target() {
  local src dest
  src="$(jq -r '.symlinks[0].src' "$COST_REPORT_SKILL_JSON")"
  dest="$(jq -r '.symlinks[0].dest' "$COST_REPORT_SKILL_JSON")"

  assert_eq "cost-report-skill.json: symlink src is skills/cost-report/SKILL.md" \
    "skills/cost-report/SKILL.md" "$src"
  assert_eq "cost-report-skill.json: symlink dest is skills/cost-report/SKILL.md" \
    "skills/cost-report/SKILL.md" "$dest"

  # The source file must actually exist under FORGE_ROOT
  if [ -f "$FORGE_ROOT/$src" ]; then
    pass "cost-report-skill.json: symlink src file exists at $FORGE_ROOT/$src"
  else
    fail "cost-report-skill.json: symlink src file missing at $FORGE_ROOT/$src"
  fi
}

# =============================================================================
# T10 — cost-report.json: conflicts_with is empty (no longer conflicts with skill)
# =============================================================================
test_cost_report_json_no_conflicts() {
  local conflicts_len
  conflicts_len="$(jq -r '.conflicts_with | length' "$COST_REPORT_JSON")"
  assert_eq "cost-report.json: conflicts_with is empty ([])" \
    "0" "$conflicts_len"
}

# =============================================================================
# T11 — cost-report.json: does NOT contain the skill symlink (split out)
# =============================================================================
test_cost_report_json_has_no_skill_symlink() {
  local skill_count
  skill_count="$(jq -r '[.symlinks[].src | select(test("SKILL\\.md"))] | length' "$COST_REPORT_JSON")"
  assert_eq "cost-report.json: SKILL.md symlink moved to cost-report-skill component" \
    "0" "$skill_count"
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== components_catalog_unit.sh ==="

run_test test_agents_json_has_commit_conventions
run_test test_agents_json_has_language_policy
run_test test_statusline_json_has_subagent_statusline
run_test test_statusline_json_manages_subagent_statusline
run_test test_core_json_is_plugin_companion
run_test test_core_json_managed_paths_match_agents
run_test test_core_json_symlink_dests
run_test test_cost_report_skill_json_shape
run_test test_cost_report_skill_symlink_target
run_test test_cost_report_json_no_conflicts
run_test test_cost_report_json_has_no_skill_symlink

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
