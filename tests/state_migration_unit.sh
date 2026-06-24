#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/state_migration_unit.sh — Unit tests for _forge_state_migrate (v2→v3)
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ---------------------------------------------------------------------------
# Extract _forge_state_migrate from install.sh using awk (function-only).
# This avoids sourcing install.sh as a script (which would run its main body).
# The function only calls jq and uses $HOME — no other shell function deps.
# ---------------------------------------------------------------------------
_source_state_migrate() {
  local fn_body
  fn_body="$(awk '/^_forge_state_migrate\(\)/{found=1} found{print} found && /^\}$/{exit}' \
    "$FORGE_ROOT/install.sh")"
  eval "$fn_body"
}

_source_state_migrate

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
  rm -rf "$TMPDIR_BASE"/state-migrate-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/state-migrate-$$-XXXX")"
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
# Test cases
# =============================================================================

# T1 — _forge_state_migrate v2→v3: state_schema==3, components has 7 entries,
#       symlinks_objects present; idempotent (second call produces no diff)
test_state_migrate_v2_to_v3() {
  local tmp
  tmp="$(make_tmp)"
  local state_file="$tmp/.forge-state.json"
  local tgt_dir="$tmp/.claude"

  # Hand-crafted v2 state: state_schema=2, one targets_manifest entry without
  # components or symlinks_objects (simulating a v2 state before v3 migration).
  cat > "$state_file" <<STATEOF
{
  "version": "0.12.0",
  "installed_at": "2026-01-01T00:00:00Z",
  "state_schema": 2,
  "targets": ["claude"],
  "symlinks": [
    "${tgt_dir}/agents/senior.md",
    "${tgt_dir}/agents/tech.md"
  ],
  "targets_manifest": [
    {
      "name": "claude",
      "dir": "${tgt_dir}",
      "symlinks": ["agents/senior.md", "agents/tech.md"],
      "settings_merged": true,
      "settings_backup": null
    }
  ],
  "settings": {
    "managed_paths": [],
    "overlay_backup": {"claude": {}},
    "settings_json_backup": {"claude": ""}
  }
}
STATEOF

  # Run migration
  _forge_state_migrate "$state_file"

  # state_schema must be 3
  local schema
  schema="$(jq -r '.state_schema' "$state_file")"
  assert_eq "v2_to_v3: state_schema == 3" "3" "$schema"

  # components array must have 7 entries
  local comp_count
  comp_count="$(jq -r '.targets_manifest[0].components | length' "$state_file")"
  assert_eq "v2_to_v3: components has 7 entries" "7" "$comp_count"

  # symlinks_objects must be present (array type, not null)
  local symlinks_objects_type
  symlinks_objects_type="$(jq -r '.targets_manifest[0].symlinks_objects | type' "$state_file")"
  assert_eq "v2_to_v3: symlinks_objects is present (array)" "array" "$symlinks_objects_type"

  # Idempotency: capture state after first migration, run again, compare
  local before_second
  before_second="$(jq -cS '.' "$state_file")"
  _forge_state_migrate "$state_file"
  local after_second
  after_second="$(jq -cS '.' "$state_file")"
  assert_eq "v2_to_v3: idempotent (second call produces no diff)" "$before_second" "$after_second"
}

# T2 (P2-7) — v1→v2→v3 chain migration:
#   start from a v1 state (no state_schema, no targets_manifest);
#   assert state_schema==3, targets_manifest present, each entry has components.
test_state_migrate_v1_to_v3_chain() {
  local tmp
  tmp="$(make_tmp)"
  local state_file="$tmp/.forge-state.json"
  local claude_dir="$tmp/.claude"

  # Hand-crafted v1 state: no state_schema, no targets_manifest
  cat > "$state_file" <<STATEOF
{
  "version": "0.1.1",
  "installed_at": "2026-05-01T10:00:00Z",
  "targets": ["claude"],
  "symlinks": [
    "${claude_dir}/agents/senior.md",
    "${claude_dir}/agents/tech.md",
    "${claude_dir}/agents/applier.md",
    "${claude_dir}/commands/create-plan.md",
    "${claude_dir}/statusline.sh",
    "${claude_dir}/CLAUDE-shared.md"
  ],
  "settings": {
    "managed_paths": [],
    "overlay_backup": {"claude": {}},
    "settings_json_backup": {"claude": ""}
  },
  "rtk": {
    "pinned_version": "0.37.2",
    "detected_version": null,
    "installed_by_us": false,
    "install_failed": false,
    "version_mismatch": false
  }
}
STATEOF

  # Run the full v1→v2→v3 chain migration (single call handles both passes)
  _forge_state_migrate "$state_file"

  # state_schema must be 3 (chain completed)
  local schema
  schema="$(jq -r '.state_schema' "$state_file")"
  assert_eq "v1_to_v3_chain: state_schema == 3" "3" "$schema"

  # targets_manifest must be present and non-empty
  local manifest_len
  manifest_len="$(jq -r '.targets_manifest | length' "$state_file")"
  if [ "$manifest_len" -ge 1 ] 2>/dev/null; then
    pass "v1_to_v3_chain: targets_manifest present (length $manifest_len)"
  else
    fail "v1_to_v3_chain: targets_manifest missing or empty (got $manifest_len)"
  fi

  # Each entry must have components present (non-empty array)
  local entry_count comp_count
  entry_count="$(jq -r '.targets_manifest | length' "$state_file")"
  local i=0
  local all_have_components=1
  while [ "$i" -lt "$entry_count" ]; do
    comp_count="$(jq -r --argjson idx "$i" '.targets_manifest[$idx].components | length' "$state_file")"
    if [ "$comp_count" -lt 1 ] 2>/dev/null; then
      all_have_components=0
      break
    fi
    i=$((i + 1))
  done
  if [ "$all_have_components" -eq 1 ]; then
    pass "v1_to_v3_chain: every targets_manifest entry has components (non-empty)"
  else
    fail "v1_to_v3_chain: at least one targets_manifest entry is missing components"
  fi
}

# T3 (P2-8) — v3 state is idempotent: second call to _forge_state_migrate is a no-op.
test_state_migrate_v3_idempotent() {
  local tmp
  tmp="$(make_tmp)"
  local state_file="$tmp/.forge-state.json"
  local tgt_dir="$tmp/.claude"

  # Well-formed v3 state (state_schema=3, components present, symlinks_objects present)
  cat > "$state_file" <<STATEOF
{
  "version": "0.13.0",
  "installed_at": "2026-01-01T00:00:00Z",
  "state_schema": 3,
  "targets": ["claude"],
  "symlinks": ["${tgt_dir}/agents/senior.md"],
  "targets_manifest": [
    {
      "name": "claude",
      "dir": "${tgt_dir}",
      "symlinks": ["agents/senior.md"],
      "symlinks_objects": [{"src": "agents/senior.md", "dest": "agents/senior.md"}],
      "components": ["agents","statusline"],
      "settings_merged": true,
      "settings_backup": null
    }
  ],
  "settings": {
    "managed_paths": [],
    "overlay_backup": {"claude": {}},
    "settings_json_backup": {"claude": ""}
  },
  "rtk": {
    "pinned_version": "0.42.0",
    "detected_version": null,
    "installed_by_us": false,
    "install_failed": false,
    "version_mismatch": false
  }
}
STATEOF

  # Capture state before first migration call
  local before_first
  before_first="$(jq -cS '.' "$state_file")"

  # First call (should be a no-op since schema == 3)
  _forge_state_migrate "$state_file"
  local after_first
  after_first="$(jq -cS '.' "$state_file")"

  assert_eq "v3_idempotent: first call is no-op (state unchanged)" "$before_first" "$after_first"

  # Second call must also be a no-op
  _forge_state_migrate "$state_file"
  local after_second
  after_second="$(jq -cS '.' "$state_file")"

  assert_eq "v3_idempotent: second call is no-op (no diff)" "$after_first" "$after_second"
}

# T4 — v2→v3 migration: components list includes cost-report-skill
test_state_migrate_v2_to_v3_includes_cost_report_skill() {
  local tmp
  tmp="$(make_tmp)"
  local state_file="$tmp/.forge-state.json"
  local tgt_dir="$tmp/.claude"

  cat > "$state_file" <<STATEOF
{
  "version": "0.12.0",
  "installed_at": "2026-01-01T00:00:00Z",
  "state_schema": 2,
  "targets": ["claude"],
  "symlinks": [
    "${tgt_dir}/agents/senior.md"
  ],
  "targets_manifest": [
    {
      "name": "claude",
      "dir": "${tgt_dir}",
      "symlinks": ["agents/senior.md"],
      "settings_merged": true,
      "settings_backup": null
    }
  ],
  "settings": {
    "managed_paths": [],
    "overlay_backup": {"claude": {}},
    "settings_json_backup": {"claude": ""}
  }
}
STATEOF

  _forge_state_migrate "$state_file"

  # cost-report-skill must appear in the migrated components array
  local found
  found="$(jq -r '.targets_manifest[0].components | index("cost-report-skill")' "$state_file")"
  if [ "$found" != "null" ]; then
    pass "v2_to_v3_includes_cost_report_skill: cost-report-skill present in components"
  else
    fail "v2_to_v3_includes_cost_report_skill: cost-report-skill missing from migrated components"
  fi

  # cost-report (the script) must also still be present
  local found_cr
  found_cr="$(jq -r '.targets_manifest[0].components | index("cost-report")' "$state_file")"
  if [ "$found_cr" != "null" ]; then
    pass "v2_to_v3_includes_cost_report_skill: cost-report also present in components"
  else
    fail "v2_to_v3_includes_cost_report_skill: cost-report missing from migrated components"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== state_migration_unit.sh ==="

run_test test_state_migrate_v2_to_v3
run_test test_state_migrate_v1_to_v3_chain
run_test test_state_migrate_v3_idempotent
run_test test_state_migrate_v2_to_v3_includes_cost_report_skill

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
