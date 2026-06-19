#!/usr/bin/env bash
# tests/install_integration.sh — e2e integration tests for forge
# Runs end-to-end cases in isolated sandbox HOME directories.
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$FORGE_ROOT/install.sh"

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
FAIL=0
PASS_COUNT=0

pass() { echo "  PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=1; }

assert_true() {
  local desc="$1"
  shift
  if "$@" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

assert_file_valid_json() {
  local f="$1"
  local desc="$2"
  if [ -f "$f" ] && jq empty "$f" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc (file=$f)"
  fi
}

assert_is_symlink_to() {
  local link="$1"
  local expected_target="$2"
  local desc="$3"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$expected_target" ]; then
    pass "$desc"
  else
    fail "$desc (link=$link, readlink=$(readlink "$link" 2>/dev/null || echo MISSING))"
  fi
}

assert_files_identical() {
  local f1="$1"
  local f2="$2"
  local desc="$3"
  if diff -q "$f1" "$f2" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
    echo "    diff:" >&2
    diff "$f1" "$f2" >&2 || true
  fi
}

assert_exit_nonzero() {
  local desc="$1"
  shift
  if "$@" 2>/dev/null; then
    fail "$desc (expected non-zero exit)"
  else
    pass "$desc"
  fi
}

assert_file_not_exists() {
  local f="$1"
  local desc="$2"
  if [ ! -e "$f" ]; then
    pass "$desc"
  else
    fail "$desc (file exists: $f)"
  fi
}

# ---------------------------------------------------------------------------
# Test 1: e2e install → uninstall roundtrip (settings byte-a-byte identical)
# ---------------------------------------------------------------------------
test_e2e_install_uninstall_roundtrip() {
  echo ""
  echo "--- test_e2e_install_uninstall_roundtrip"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  # Seed claude target with settings that have "no-touch" keys + custom managed keys
  mkdir -p "$TMPHOME/.claude"

  local claude_orig="$TMPHOME/.claude/settings.json"

  printf '{"companyAnnouncements":["Acme"],"appendSystemPrompt":"ROLE: Dev","cli":"x","permissions":{"allow":["Bash(ls)"]}}' \
    > "$claude_orig"

  # Capture original
  local orig_claude
  orig_claude="$(cat "$claude_orig")"

  # Install
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude

  # After install: check managed keys applied
  assert_true "claude: permissions.allow overwritten by shared" \
    bash -c "[ \"\$(jq -r '.permissions.allow | length' '$claude_orig')\" -gt 1 ]"

  assert_true "claude: companyAnnouncements preserved" \
    bash -c "[ \"\$(jq -r '.companyAnnouncements[0]' '$claude_orig')\" = 'Acme' ]"

  assert_true "claude: appendSystemPrompt preserved" \
    bash -c "[ \"\$(jq -r '.appendSystemPrompt' '$claude_orig')\" = 'ROLE: Dev' ]"

  assert_true "symlinks created in claude" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  assert_file_valid_json "$TMPHOME/.forge-state.json" "state file valid after install"

  # Uninstall
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall

  # After uninstall: settings must be byte-a-byte identical to original
  local after_claude
  after_claude="$(cat "$claude_orig")"

  if [ "$orig_claude" = "$after_claude" ]; then
    pass "claude settings.json byte-a-byte idéntico al original (roundtrip)"
  else
    fail "claude settings.json roundtrip FALLO"
    echo "  ORIG  : $orig_claude" >&2
    echo "  AFTER : $after_claude" >&2
  fi

  assert_file_not_exists "$TMPHOME/.forge-state.json" "state file eliminado tras uninstall"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 2: repair recreates broken symlinks
# ---------------------------------------------------------------------------
test_e2e_repair_recreates_broken_symlinks() {
  echo ""
  echo "--- test_e2e_repair_recreates_broken_symlinks"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Install
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude

  # Verify symlink exists
  assert_true "senior.md symlink created" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  # Break the symlink
  rm "$TMPHOME/.claude/agents/senior.md"
  assert_true "symlink removed (simulating break)" \
    test ! -e "$TMPHOME/.claude/agents/senior.md"

  # Repair
  HOME="$TMPHOME" bash "$INSTALL_SH" repair

  # Verify recreated
  assert_is_symlink_to \
    "$TMPHOME/.claude/agents/senior.md" \
    "$FORGE_ROOT/agents/senior.md" \
    "senior.md recreado por repair"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 3: status reports broken symlink, exits != 0
# ---------------------------------------------------------------------------
test_e2e_status_reports_broken() {
  echo ""
  echo "--- test_e2e_status_reports_broken"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Install
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude

  # Break a symlink by pointing it to /nonexistent
  rm "$TMPHOME/.claude/agents/senior.md"
  ln -s "/nonexistent/path" "$TMPHOME/.claude/agents/senior.md"

  # Status should exit != 0 and mention BROKEN or MISMATCH
  local status_out
  status_out="$(HOME="$TMPHOME" bash "$INSTALL_SH" status 2>&1 || true)"
  local status_exit=0
  HOME="$TMPHOME" bash "$INSTALL_SH" status >/dev/null 2>&1 || status_exit=$?

  if [ "$status_exit" -ne 0 ]; then
    pass "status exits non-zero con symlink roto"
  else
    fail "status debería salir != 0 con symlink roto (got 0)"
  fi

  if printf '%s' "$status_out" | grep -q -i "broken\|mismatch"; then
    pass "status menciona BROKEN o MISMATCH en output"
  else
    fail "status no menciona symlink roto en output"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 5: rtk binary is not created without explicit confirmation
# ---------------------------------------------------------------------------
test_e2e_rtk_no_binary_without_confirmation() {
  echo ""
  echo "--- test_e2e_rtk_no_binary_without_confirmation"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  assert_file_not_exists "$TMPHOME/.forge/bin/rtk" "rtk binary absent before install"

  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  assert_file_not_exists "$TMPHOME/.forge/bin/rtk" "rtk binary not created without explicit confirmation"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 6: state_schema v2 shape after install
# ---------------------------------------------------------------------------
test_state_schema_v2_shape() {
  echo ""
  echo "--- test_state_schema_v2_shape"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  local state="$TMPHOME/.forge-state.json"

  assert_file_valid_json "$state" "state file válido tras install"

  local schema
  schema="$(jq -r '.state_schema' "$state" 2>/dev/null || echo "null")"
  if [ "$schema" -ge "2" ] 2>/dev/null; then
    pass "state_schema >= 2 (got $schema)"
  else
    fail "state_schema esperado >= 2, got $schema"
  fi

  local manifest_len
  manifest_len="$(jq -r '.targets_manifest | length' "$state" 2>/dev/null || echo "0")"
  if [ "$manifest_len" -ge 1 ]; then
    pass "targets_manifest length >= 1 (got $manifest_len)"
  else
    fail "targets_manifest vacío (got $manifest_len)"
  fi

  local first_symlinks_len
  first_symlinks_len="$(jq -r '.targets_manifest[0].symlinks | length' "$state" 2>/dev/null || echo "0")"
  if [ "$first_symlinks_len" -ge 4 ]; then
    pass "targets_manifest[0].symlinks length >= 4 (got $first_symlinks_len)"
  else
    fail "targets_manifest[0].symlinks demasiado corto (got $first_symlinks_len)"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 7: repair uses state (targets_manifest), not hardcoded list
# ---------------------------------------------------------------------------
test_repair_uses_state_not_hardcoded() {
  echo ""
  echo "--- test_repair_uses_state_not_hardcoded"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Break a symlink
  rm "$TMPHOME/.claude/agents/senior.md"
  assert_true "symlink roto (setup)" test ! -e "$TMPHOME/.claude/agents/senior.md"

  # Repair using state-driven logic
  HOME="$TMPHOME" bash "$INSTALL_SH" repair >/dev/null 2>&1

  assert_is_symlink_to \
    "$TMPHOME/.claude/agents/senior.md" \
    "$FORGE_ROOT/agents/senior.md" \
    "repair con state v2: symlink recreado"

  # Now simulate state v1 (remove targets_manifest) and repair again
  local state="$TMPHOME/.forge-state.json"
  local tmp_state
  tmp_state="$(mktemp)"
  jq 'del(.targets_manifest) | del(.state_schema)' "$state" > "$tmp_state"
  mv "$tmp_state" "$state"

  # Verify schema was removed (v1-like state)
  local schema_after
  schema_after="$(jq -r '.state_schema // "absent"' "$state")"
  if [ "$schema_after" = "absent" ]; then
    pass "state degradado a v1 (sin state_schema)"
  else
    fail "state_schema debería estar ausente en v1 simulado, got $schema_after"
  fi

  # Break again
  rm "$TMPHOME/.claude/agents/senior.md"

  # Repair should auto-migrate v1→v2 and recreate symlink
  HOME="$TMPHOME" bash "$INSTALL_SH" repair >/dev/null 2>&1

  assert_is_symlink_to \
    "$TMPHOME/.claude/agents/senior.md" \
    "$FORGE_ROOT/agents/senior.md" \
    "repair tras migración v1→v2: symlink recreado"

  # State should now have state_schema >= 2 (migration bumps to latest schema)
  local schema_migrated
  schema_migrated="$(jq -r '.state_schema // 0' "$state")"
  if [ "$schema_migrated" -ge "2" ] 2>/dev/null; then
    pass "state migrado a schema >= 2 tras repair (got $schema_migrated)"
  else
    fail "state_schema esperado >= 2 tras migración, got $schema_migrated"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 8: state v1 migrates to v2 on status
# ---------------------------------------------------------------------------
test_state_v1_migrates_to_v2() {
  echo ""
  echo "--- test_state_v1_migrates_to_v2"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude/agents"

  local state="$TMPHOME/.forge-state.json"
  local claude_dir="$TMPHOME/.claude"

  # Write a hardcoded v1 state (no state_schema, no targets_manifest)
  cat > "$state" <<STATEOF
{
  "version": "0.1.1",
  "installed_at": "2026-05-01T10:00:00Z",
  "targets": ["claude"],
  "symlinks": [
    "${claude_dir}/agents/senior.md",
    "${claude_dir}/agents/tech.md",
    "${claude_dir}/agents/applier.md",
    "${claude_dir}/skills/pr-description/SKILL.md",
    "${claude_dir}/statusline-command.sh",
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

  # Run status — triggers _forge_state_migrate
  HOME="$TMPHOME" bash "$INSTALL_SH" status >/dev/null 2>&1 || true

  local schema
  schema="$(jq -r '.state_schema // 0' "$state")"
  if [ "$schema" -ge "2" ] 2>/dev/null; then
    pass "state migrado a schema >= 2 tras status (got $schema)"
  else
    fail "state_schema esperado >= 2 tras migración por status, got $schema"
  fi

  local manifest_len
  manifest_len="$(jq -r '.targets_manifest | length' "$state" 2>/dev/null || echo "0")"
  if [ "$manifest_len" -ge 1 ]; then
    pass "targets_manifest generado por migración (length $manifest_len)"
  else
    fail "targets_manifest vacío tras migración (got $manifest_len)"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 9: skills (cost-report, create-plan, execute-plan, pr-description,
#          update-changelog) distributed correctly under ~/.claude/skills/
# ---------------------------------------------------------------------------
test_e2e_new_commands_distributed() {
  echo ""
  echo "--- test_e2e_new_commands_distributed"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  # Install
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Verify SKILL.md symlinks for all five skills
  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/cost-report/SKILL.md" \
    "$FORGE_ROOT/skills/cost-report/SKILL.md" \
    "cost-report/SKILL.md symlink apunta a skills/cost-report/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/create-plan/SKILL.md" \
    "$FORGE_ROOT/skills/create-plan/SKILL.md" \
    "create-plan/SKILL.md symlink apunta a skills/create-plan/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/execute-plan/SKILL.md" \
    "$FORGE_ROOT/skills/execute-plan/SKILL.md" \
    "execute-plan/SKILL.md symlink apunta a skills/execute-plan/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/pr-description/SKILL.md" \
    "$FORGE_ROOT/skills/pr-description/SKILL.md" \
    "pr-description/SKILL.md symlink apunta a skills/pr-description/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/update-changelog/SKILL.md" \
    "$FORGE_ROOT/skills/update-changelog/SKILL.md" \
    "update-changelog/SKILL.md symlink apunta a skills/update-changelog/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/plan-format/SKILL.md" \
    "$FORGE_ROOT/skills/plan-format/SKILL.md" \
    "plan-format/SKILL.md symlink apunta a skills/plan-format/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/testing-angular/SKILL.md" \
    "$FORGE_ROOT/skills/testing-angular/SKILL.md" \
    "testing-angular/SKILL.md symlink apunta a skills/testing-angular/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/testing-spring-boot/SKILL.md" \
    "$FORGE_ROOT/skills/testing-spring-boot/SKILL.md" \
    "testing-spring-boot/SKILL.md symlink apunta a skills/testing-spring-boot/SKILL.md"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/testing-pytest/SKILL.md" \
    "$FORGE_ROOT/skills/testing-pytest/SKILL.md" \
    "testing-pytest/SKILL.md symlink apunta a skills/testing-pytest/SKILL.md"

  # Verify reference file symlinks for create-plan and execute-plan
  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/create-plan/reference/plan-format.md" \
    "$FORGE_ROOT/skills/create-plan/reference/plan-format.md" \
    "create-plan/reference/plan-format.md symlink correcto"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/create-plan/reference/constraints.md" \
    "$FORGE_ROOT/skills/create-plan/reference/constraints.md" \
    "create-plan/reference/constraints.md symlink correcto"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/execute-plan/reference/batch-algorithm.md" \
    "$FORGE_ROOT/skills/execute-plan/reference/batch-algorithm.md" \
    "execute-plan/reference/batch-algorithm.md symlink correcto"

  assert_is_symlink_to \
    "$TMPHOME/.claude/skills/execute-plan/reference/reviewer-and-close.md" \
    "$FORGE_ROOT/skills/execute-plan/reference/reviewer-and-close.md" \
    "execute-plan/reference/reviewer-and-close.md symlink correcto"

  # Verify all five SKILL.md entries appear in state.symlinks
  local state="$TMPHOME/.forge-state.json"
  assert_file_valid_json "$state" "state file válido"

  for skill in cost-report create-plan execute-plan pr-description update-changelog plan-format testing-angular testing-spring-boot testing-pytest; do
    if jq -e --arg s "$skill" '.symlinks[] | select(endswith($s + "/SKILL.md"))' "$state" >/dev/null 2>&1; then
      pass "${skill}/SKILL.md en state.symlinks"
    else
      fail "${skill}/SKILL.md ausente en state.symlinks"
    fi
  done

  # Verify reference files appear in state.symlinks
  for ref_path in \
    "skills/create-plan/reference/plan-format.md" \
    "skills/create-plan/reference/constraints.md" \
    "skills/execute-plan/reference/batch-algorithm.md" \
    "skills/execute-plan/reference/reviewer-and-close.md"; do
    if jq -e --arg p "$ref_path" '.symlinks[] | select(endswith($p))' "$state" >/dev/null 2>&1; then
      pass "${ref_path} en state.symlinks"
    else
      fail "${ref_path} ausente en state.symlinks"
    fi
  done

  # Idempotence: second install should not create backups
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  local backup_count
  backup_count=$(find "$TMPHOME/.claude/skills" -name "*.forge-bak-*" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$backup_count" = "0" ]; then
    pass "No debe haber backups tras segundo install"
  else
    fail "No debe haber backups tras segundo install (found $backup_count)"
  fi

  # Uninstall removes all five skill directories
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

  assert_file_not_exists "$TMPHOME/.claude/skills/cost-report/SKILL.md" \
    "skills/cost-report/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/create-plan/SKILL.md" \
    "skills/create-plan/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/execute-plan/SKILL.md" \
    "skills/execute-plan/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/pr-description/SKILL.md" \
    "skills/pr-description/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/update-changelog/SKILL.md" \
    "skills/update-changelog/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/plan-format/SKILL.md" \
    "skills/plan-format/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/testing-angular/SKILL.md" \
    "skills/testing-angular/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/testing-spring-boot/SKILL.md" \
    "skills/testing-spring-boot/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/testing-pytest/SKILL.md" \
    "skills/testing-pytest/SKILL.md eliminado tras uninstall"

  # Reference dirs must be absent or empty after uninstall
  for ref_dir in \
    "$TMPHOME/.claude/skills/create-plan/reference" \
    "$TMPHOME/.claude/skills/execute-plan/reference"; do
    local skill_ref_name
    skill_ref_name="$(basename "$(dirname "$ref_dir")")/reference"
    if [ ! -d "$ref_dir" ]; then
      pass "${skill_ref_name} dir ausente tras uninstall"
    else
      local ref_symlinks
      ref_symlinks="$(find "$ref_dir" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$ref_symlinks" = "0" ]; then
        pass "${skill_ref_name} dir vacío tras uninstall (sin symlinks forge)"
      else
        fail "${skill_ref_name} dir contiene $ref_symlinks symlinks tras uninstall"
      fi
    fi
  done

  # Entire skill subdirectories must be absent or empty after uninstall
  for skill in cost-report create-plan execute-plan pr-description update-changelog plan-format testing-angular testing-spring-boot testing-pytest; do
    local skill_dir="$TMPHOME/.claude/skills/${skill}"
    if [ ! -d "$skill_dir" ]; then
      pass "skills/${skill}/ dir ausente tras uninstall"
    else
      local skill_symlinks
      skill_symlinks="$(find "$skill_dir" -maxdepth 2 -type l 2>/dev/null | wc -l | tr -d ' ')"
      if [ "$skill_symlinks" = "0" ]; then
        pass "skills/${skill}/ dir vacío tras uninstall (sin symlinks forge)"
      else
        fail "skills/${skill}/ dir contiene $skill_symlinks symlinks tras uninstall"
      fi
    fi
  done

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 9b: legacy commands/*.md symlinks are cleaned up on install
# ---------------------------------------------------------------------------
test_e2e_legacy_commands_cleanup() {
  echo ""
  echo "--- test_e2e_legacy_commands_cleanup"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude/commands"

  # Set up five forge-owned legacy commands/*.md symlinks
  for cmd in cost-report create-plan execute-plan pr-description update-changelog; do
    ln -s "$FORGE_ROOT/skills/${cmd}/SKILL.md" "$TMPHOME/.claude/commands/${cmd}.md"
  done

  # One unrelated symlink that must NOT be removed
  ln -s "/tmp/something_unrelated" "$TMPHOME/.claude/commands/unrelated.md"

  # Run install — this should clean up legacy commands/*.md symlinks pointing to FORGE_ROOT
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Each of the five forge-owned symlinks must be gone
  for cmd in cost-report create-plan execute-plan pr-description update-changelog; do
    assert_file_not_exists "$TMPHOME/.claude/commands/${cmd}.md" \
      "legacy commands/${cmd}.md eliminado tras install"
  done

  # The unrelated symlink must still be present
  assert_true "symlink no relacionado preservado" \
    test -L "$TMPHOME/.claude/commands/unrelated.md"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 10: install --only=statusline installs only statusline
# ---------------------------------------------------------------------------
test_install_only_statusline() {
  echo ""
  echo "--- test_install_only_statusline"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Install with --only=statusline
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  # statusline symlink must be present
  assert_true "statusline.sh symlink present" \
    test -L "$TMPHOME/.claude/statusline.sh"

  # agents must NOT be installed (senior.md should not exist)
  assert_file_not_exists "$TMPHOME/.claude/agents/senior.md" \
    "agents/senior.md NOT installed when --only=statusline"

  local state="$TMPHOME/.forge-state.json"
  assert_file_valid_json "$state" "state file valid after --only=statusline install"

  # state_schema must be 3
  local schema
  schema="$(jq -r '.state_schema // 0' "$state" 2>/dev/null || echo "0")"
  if [ "$schema" -eq 3 ] 2>/dev/null; then
    pass "state_schema == 3 after --only=statusline"
  else
    fail "state_schema expected 3, got $schema"
  fi

  # targets_manifest[0].components must be ["statusline"]
  assert_true "targets_manifest[0].components == [\"statusline\"]" \
    bash -c "[ \"\$(jq -c '.targets_manifest[0].components' '$state' 2>/dev/null)\" = '[\"statusline\"]' ]"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-1: install --only=unknown-name exits non-zero
# ---------------------------------------------------------------------------
test_p2_1_only_unknown_component_exits_nonzero() {
  echo ""
  echo "--- test_p2_1_only_unknown_component_exits_nonzero"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  local stderr_out
  local exit_code=0
  stderr_out="$(HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=bogus-component 2>&1 >/dev/null)" || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "install --only=bogus-component exits non-zero"
  else
    fail "install --only=bogus-component should exit non-zero, got 0"
  fi

  if printf '%s' "$stderr_out" | grep -qi "unknown\|desconocido\|bogus-component"; then
    pass "stderr mentions unknown component name"
  else
    fail "stderr should mention unknown component name (got: $stderr_out)"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-2: install --only=commands emits warning about missing agents
# ---------------------------------------------------------------------------
test_p2_2_only_commands_warns_no_agents() {
  echo ""
  echo "--- test_p2_2_only_commands_warns_no_agents"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  local combined_out exit_code=0
  combined_out="$(HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=commands 2>&1)" || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "install --only=commands exits 0"
  else
    fail "install --only=commands should exit 0, got $exit_code"
  fi

  if printf '%s' "$combined_out" | grep -qi "commands\|agents\|warn"; then
    pass "output contains warning about commands without agents"
  else
    fail "output should contain warning about commands without agents (got: $combined_out)"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-3: sequential partial installs union components in state
# ---------------------------------------------------------------------------
test_p2_3_sequential_install_unions_components() {
  echo ""
  echo "--- test_p2_3_sequential_install_unions_components"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # First install: statusline only
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  # Second install: agents only
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=agents >/dev/null 2>&1

  local state="$TMPHOME/.forge-state.json"
  assert_file_valid_json "$state" "state file valid after two sequential partial installs"

  # components must be sorted union: ["agents","statusline"]
  local components_val
  components_val="$(jq -c '.targets_manifest[0].components' "$state" 2>/dev/null || echo "null")"
  if [ "$components_val" = '["agents","statusline"]' ]; then
    pass "components sorted union == [\"agents\",\"statusline\"]"
  else
    fail "components expected [\"agents\",\"statusline\"], got $components_val"
  fi

  # statusline.sh symlink must be present
  assert_true "statusline.sh symlink present after union" \
    test -L "$TMPHOME/.claude/statusline.sh"

  # agents/senior.md symlink must be present
  assert_true "agents/senior.md symlink present after union" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-4: uninstall --component=statusline leaves agents intact
# ---------------------------------------------------------------------------
test_p2_4_uninstall_component_statusline_leaves_agents() {
  echo ""
  echo "--- test_p2_4_uninstall_component_statusline_leaves_agents"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Full install
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Selective uninstall of statusline
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall --component=statusline >/dev/null 2>&1

  local state="$TMPHOME/.forge-state.json"

  # statusline.sh symlink must be gone
  assert_file_not_exists "$TMPHOME/.claude/statusline.sh" \
    "statusline.sh symlink removed after uninstall --component=statusline"

  # settings must not have statusLine key
  local settings_file="$TMPHOME/.claude/settings.json"
  if [ -f "$settings_file" ] && ! jq -e 'has("statusLine")' "$settings_file" >/dev/null 2>&1; then
    pass "settings.json does not have statusLine key after uninstall"
  else
    fail "settings.json should not have statusLine key after uninstall (statusline unmerged)"
  fi

  # agents/senior.md symlink must still be present
  assert_true "agents/senior.md symlink still present" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  # State must not contain statusline in components
  assert_file_valid_json "$state" "state file valid after selective uninstall"

  local components_have_statusline
  components_have_statusline="$(jq -r \
    '[.targets_manifest[]?.components[]? | select(. == "statusline")] | length' \
    "$state" 2>/dev/null || echo "0")"
  if [ "$components_have_statusline" = "0" ]; then
    pass "state components does NOT contain statusline"
  else
    fail "state components should not contain statusline after uninstall"
  fi

  # State must still contain agents in components
  local components_have_agents
  components_have_agents="$(jq -r \
    '[.targets_manifest[]?.components[]? | select(. == "agents")] | length' \
    "$state" 2>/dev/null || echo "0")"
  if [ "$components_have_agents" -gt 0 ] 2>/dev/null; then
    pass "state components still contains agents"
  else
    fail "state components should still contain agents after selective uninstall"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-5: uninstall --component=bogus exits non-zero
# ---------------------------------------------------------------------------
test_p2_5_uninstall_unknown_component_exits_nonzero() {
  echo ""
  echo "--- test_p2_5_uninstall_unknown_component_exits_nonzero"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Full install to create state
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  local exit_code=0
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall --component=bogus-component >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "uninstall --component=bogus-component exits non-zero"
  else
    fail "uninstall --component=bogus-component should exit non-zero, got 0"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-6: uninstall --component=<not-installed> exits non-zero
# ---------------------------------------------------------------------------
test_p2_6_uninstall_not_installed_component_exits_nonzero() {
  echo ""
  echo "--- test_p2_6_uninstall_not_installed_component_exits_nonzero"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Install agents only (statusline NOT installed)
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=agents >/dev/null 2>&1

  local stderr_out exit_code=0
  stderr_out="$(HOME="$TMPHOME" bash "$INSTALL_SH" uninstall --component=statusline 2>&1 >/dev/null)" || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "uninstall --component=statusline (not installed) exits non-zero"
  else
    fail "uninstall --component=statusline should exit non-zero when not installed, got 0"
  fi

  if printf '%s' "$stderr_out" | grep -qi "no está instalado\|not installed\|statusline"; then
    pass "stderr mentions statusline is not installed"
  else
    fail "stderr should indicate statusline is not installed (got: $stderr_out)"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-9: cmd_status with --only=statusline install does NOT flag missing agents
# ---------------------------------------------------------------------------
test_p2_9_status_only_statusline_no_missing_agents() {
  echo ""
  echo "--- test_p2_9_status_only_statusline_no_missing_agents"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Install statusline only
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  # Run status and capture all output
  local status_out exit_code=0
  status_out="$(HOME="$TMPHOME" bash "$INSTALL_SH" status 2>&1)" || exit_code=$?

  # Status should NOT mention MISSING for agents/senior.md
  if printf '%s' "$status_out" | grep -qi "MISSING.*senior\|senior.*MISSING\|BROKEN.*senior\|senior.*BROKEN"; then
    fail "status should NOT report MISSING/BROKEN for agents/senior.md when only statusline installed"
  else
    pass "status does NOT report MISSING or BROKEN for agents/senior.md"
  fi

  # Status should mention statusline as OK
  if printf '%s' "$status_out" | grep -qi "statusline\|statusline\.sh"; then
    pass "status mentions statusline in output"
  else
    fail "status output should mention statusline (got: $status_out)"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test P2-10: uninstall --component unit test with two targets in state
# ---------------------------------------------------------------------------
test_p2_10_uninstall_component_multi_target_unit() {
  echo ""
  echo "--- test_p2_10_uninstall_component_multi_target_unit"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  # Create two fake target directories representing two independent ~/.claude installs
  local target_a="$TMPHOME/target_a"
  local target_b="$TMPHOME/target_b"
  mkdir -p "$target_a" "$target_b"

  # Create fake statusline symlinks in both targets so the clean step doesn't fail
  mkdir -p "$target_a" "$target_b"
  ln -s "$FORGE_ROOT/shared/statusline.sh" "$target_a/statusline.sh"
  ln -s "$FORGE_ROOT/shared/total-usage.sh" "$target_a/total-usage.sh"
  ln -s "$FORGE_ROOT/shared/statusline.sh" "$target_b/statusline.sh"
  ln -s "$FORGE_ROOT/shared/total-usage.sh" "$target_b/total-usage.sh"

  # Create a fake settings.json in both targets (required by unmerge logic)
  printf '{"statusLine": {"enabled": true}}' > "$target_a/settings.json"
  printf '{"statusLine": {"enabled": true}}' > "$target_b/settings.json"

  # Hand-craft a v3 state with two targets_manifest entries, both having statusline
  local state_file="$TMPHOME/.forge-state.json"
  jq -n \
    --arg version "0.13.0" \
    --arg installed_at "2026-01-01T00:00:00Z" \
    --arg dir_a "$target_a" \
    --arg dir_b "$target_b" \
    '{
      version: $version,
      installed_at: $installed_at,
      state_schema: 3,
      targets: ["target_a", "target_b"],
      symlinks: [($dir_a + "/statusline.sh"), ($dir_b + "/statusline.sh")],
      targets_manifest: [
        {
          name: "target_a",
          dir: $dir_a,
          symlinks: ["statusline.sh", "total-usage.sh"],
          symlinks_objects: [
            {"src": "shared/statusline.sh", "dest": "statusline.sh"},
            {"src": "shared/total-usage.sh", "dest": "total-usage.sh"}
          ],
          components: ["statusline"],
          settings_merged: true,
          settings_backup: null
        },
        {
          name: "target_b",
          dir: $dir_b,
          symlinks: ["statusline.sh", "total-usage.sh"],
          symlinks_objects: [
            {"src": "shared/statusline.sh", "dest": "statusline.sh"},
            {"src": "shared/total-usage.sh", "dest": "total-usage.sh"}
          ],
          components: ["statusline"],
          settings_merged: true,
          settings_backup: null
        }
      ],
      settings: {
        managed_paths: [],
        overlay_backup: {},
        settings_json_backup: {}
      },
      rtk: {
        pinned_version: "0.42.0",
        detected_version: null,
        installed_by_us: false,
        install_failed: false,
        version_mismatch: false
      }
    }' > "$state_file"

  # Run uninstall --component=statusline against this crafted state
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall --component=statusline >/dev/null 2>&1

  # After uninstall: state file should be gone (all components removed from both targets)
  # OR if state remains, neither target should have statusline in components
  if [ ! -f "$state_file" ]; then
    pass "state file removed after uninstalling all components from both targets"
  else
    local remaining_statusline
    remaining_statusline="$(jq -r \
      '[.targets_manifest[]?.components[]? | select(. == "statusline")] | length' \
      "$state_file" 2>/dev/null || echo "0")"
    if [ "$remaining_statusline" = "0" ]; then
      pass "statusline removed from components in both targets (state file kept but empty components)"
    else
      fail "statusline still in state components after uninstall --component=statusline (count=$remaining_statusline)"
    fi
  fi

  # Verify symlinks removed in both targets
  assert_file_not_exists "$target_a/statusline.sh" \
    "statusline.sh removed from target_a"
  assert_file_not_exists "$target_b/statusline.sh" \
    "statusline.sh removed from target_b"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test NEW-1: partial-to-full upgrade installs all components
# ---------------------------------------------------------------------------
test_partial_to_full_upgrade_installs_all_components() {
  echo ""
  echo "--- test_partial_to_full_upgrade_installs_all_components"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Step 1: partial install — statusline only
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  # After step 1: agents/senior.md must NOT be present
  assert_file_not_exists "$TMPHOME/.claude/agents/senior.md" \
    "agents/senior.md absent after --only=statusline"

  # Statusline must be present after step 1
  assert_true "statusline.sh present after step 1" \
    test -L "$TMPHOME/.claude/statusline.sh"

  # Step 2: full install (no --only)
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # After step 2: agents/senior.md must be present (newly deployed)
  assert_true "agents/senior.md present after full install" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  # Statusline must still be present (not removed by full install)
  assert_true "statusline.sh still present after full install" \
    test -L "$TMPHOME/.claude/statusline.sh"

  # State must contain both components
  local state="$TMPHOME/.forge-state.json"
  assert_file_valid_json "$state" "state file valid after full install"

  local has_agents
  has_agents="$(jq -r '[.targets_manifest[]?.components[]? | select(. == "agents")] | length' \
    "$state" 2>/dev/null || echo "0")"
  if [ "${has_agents:-0}" -gt 0 ] 2>/dev/null; then
    pass "state contains agents component after full install"
  else
    fail "state should contain agents component after full install"
  fi

  local has_statusline
  has_statusline="$(jq -r '[.targets_manifest[]?.components[]? | select(. == "statusline")] | length' \
    "$state" 2>/dev/null || echo "0")"
  if [ "${has_statusline:-0}" -gt 0 ] 2>/dev/null; then
    pass "state contains statusline component after full install"
  else
    fail "state should contain statusline component after full install"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test NEW-3: no orphaned parent dirs after --component uninstall
# ---------------------------------------------------------------------------
test_uninstall_component_leaves_no_orphan_parent_dirs() {
  echo ""
  echo "--- test_uninstall_component_leaves_no_orphan_parent_dirs"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Step 1: install agents only
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=agents >/dev/null 2>&1

  # Verify agents/senior.md symlink is present before uninstall
  assert_true "agents/senior.md present before uninstall" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  # Step 2: selective uninstall of agents component
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall --component=agents >/dev/null 2>&1

  # Step 3: agents/senior.md symlink must be gone
  assert_file_not_exists "$TMPHOME/.claude/agents/senior.md" \
    "agents/senior.md symlink removed after uninstall --component=agents"

  # Step 4: _forge_clean_target removes individual symlinks but does NOT rmdir
  # the parent directory. Design intent: leave the empty agents/ dir as-is.
  # Assert the parent dir is empty (no forge-owned symlinks remain in it).
  # If the dir was removed, that's also acceptable — assert whichever is true.
  if [ ! -d "$TMPHOME/.claude/agents" ]; then
    pass "agents/ directory does not exist after component uninstall (removed by OS or design)"
  else
    # Directory exists — it must be empty (no symlinks pointing to FORGE_ROOT)
    local remaining_symlinks
    remaining_symlinks="$(find "$TMPHOME/.claude/agents" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$remaining_symlinks" = "0" ]; then
      pass "agents/ directory is empty after component uninstall (no orphaned symlinks)"
    else
      fail "agents/ directory has $remaining_symlinks remaining symlinks after uninstall --component=agents"
    fi
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test rules_symlinks_created: after install, rules/ symlinks and
# subagent-statusline.sh symlink are present and resolve correctly.
# ---------------------------------------------------------------------------
test_rules_symlinks_created() {
  echo ""
  echo "--- test_rules_symlinks_created"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  local link
  for link in \
    "$TMPHOME/.claude/rules/commit-conventions.md" \
    "$TMPHOME/.claude/rules/language-policy.md" \
    "$TMPHOME/.claude/subagent-statusline.sh"; do
    local name
    name="$(basename "$link")"
    if [ -L "$link" ] && [ -e "$link" ]; then
      pass "rules_symlinks_created: $name is a symlink that resolves"
    elif [ -L "$link" ]; then
      fail "rules_symlinks_created: $name is a symlink but target does not exist (dangling)"
    else
      fail "rules_symlinks_created: $name is not a symlink (or missing)"
    fi
  done

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test core_1: default install excludes the opt-in core component
# ---------------------------------------------------------------------------
test_install_default_excludes_core() {
  echo ""
  echo "--- test_install_default_excludes_core"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  local has_core
  has_core="$(jq -r '[.targets_manifest[].components[] | select(. == "core")] | length' "$TMPHOME/.forge-state.json")"
  if [ "$has_core" = "0" ]; then
    pass "default_excludes_core: core not in state after default install"
  else
    fail "default_excludes_core: core was installed by default"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test core_2: --only=core installs the plugin companion (CLAUDE-shared.md,
# @ref, managed settings, support symlinks) and nothing of the agents pipeline
# ---------------------------------------------------------------------------
test_install_only_core() {
  echo ""
  echo "--- test_install_only_core"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"
  printf '@RTK.md\n' > "$TMPHOME/.claude/CLAUDE.md"
  HOME="$TMPHOME" bash "$INSTALL_SH" install --only=core --target=claude >/dev/null 2>&1

  assert_is_symlink_to "$TMPHOME/.claude/CLAUDE-shared.md" \
    "$FORGE_ROOT/shared/CLAUDE-shared.md" \
    "only_core: CLAUDE-shared.md symlinked"
  assert_is_symlink_to "$TMPHOME/.claude/tools/release/bump-version.sh" \
    "$FORGE_ROOT/tools/release/bump-version.sh" \
    "only_core: tools/release/bump-version.sh symlinked"
  assert_is_symlink_to "$TMPHOME/.claude/cost-report.sh" \
    "$FORGE_ROOT/shared/cost-report.sh" \
    "only_core: cost-report.sh symlinked"
  assert_file_not_exists "$TMPHOME/.claude/agents/senior.md" \
    "only_core: agents/senior.md NOT installed"
  assert_file_not_exists "$TMPHOME/.claude/skills/create-plan/SKILL.md" \
    "only_core: skills NOT installed (the plugin ships them)"

  if grep -qF '@CLAUDE-shared.md' "$TMPHOME/.claude/CLAUDE.md"; then
    pass "only_core: @CLAUDE-shared.md referenced in CLAUDE.md"
  else
    fail "only_core: @CLAUDE-shared.md missing from CLAUDE.md"
  fi

  local model hooks
  model="$(jq -r '.model' "$TMPHOME/.claude/settings.json")"
  hooks="$(jq -r '.hooks // "absent"' "$TMPHOME/.claude/settings.json")"
  if [ "$model" = "sonnet" ]; then
    pass "only_core: settings model=sonnet merged"
  else
    fail "only_core: settings model expected sonnet, got '$model'"
  fi
  if [ "$hooks" = "absent" ]; then
    pass "only_core: no hooks merged (the plugin ships them)"
  else
    fail "only_core: hooks unexpectedly merged: $hooks"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test core_3: mutual exclusion core ⟷ agents (selected×selected and
# selected×installed in both directions)
# ---------------------------------------------------------------------------
test_core_conflicts() {
  echo ""
  echo "--- test_core_conflicts"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"
  assert_exit_nonzero "core_conflicts: --only=core,agents exits non-zero" \
    env HOME="$TMPHOME" bash "$INSTALL_SH" install --only=core,agents --target=claude

  HOME="$TMPHOME" bash "$INSTALL_SH" install --only=core --target=claude >/dev/null 2>&1
  assert_exit_nonzero "core_conflicts: --only=agents over installed core exits non-zero" \
    env HOME="$TMPHOME" bash "$INSTALL_SH" install --only=agents --target=claude
  assert_exit_nonzero "core_conflicts: default install over installed core exits non-zero" \
    env HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude
  if HOME="$TMPHOME" bash "$INSTALL_SH" install --only=core --target=claude >/dev/null 2>&1; then
    pass "core_conflicts: re-installing core is idempotent (no self-conflict)"
  else
    fail "core_conflicts: re-installing core failed"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test fu_1: full uninstall strips @CLAUDE-shared.md from CLAUDE.md, keeps the
# user's own content, and sweeps the empty skills/tools/agents/rules dirs
# ---------------------------------------------------------------------------
test_full_uninstall_strips_claude_md_ref_and_dirs() {
  echo ""
  echo "--- test_full_uninstall_strips_claude_md_ref_and_dirs"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"
  printf '@RTK.md\nuser content line\n' > "$TMPHOME/.claude/CLAUDE.md"
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

  if grep -qF '@CLAUDE-shared.md' "$TMPHOME/.claude/CLAUDE.md"; then
    fail "full_uninstall: @CLAUDE-shared.md still dangling in CLAUDE.md"
  else
    pass "full_uninstall: @CLAUDE-shared.md stripped from CLAUDE.md"
  fi
  if grep -qF 'user content line' "$TMPHOME/.claude/CLAUDE.md" && grep -qF '@RTK.md' "$TMPHOME/.claude/CLAUDE.md"; then
    pass "full_uninstall: user content in CLAUDE.md preserved"
  else
    fail "full_uninstall: user content in CLAUDE.md lost"
  fi

  local d
  for d in skills tools agents rules; do
    assert_file_not_exists "$TMPHOME/.claude/$d" "full_uninstall: empty $d/ swept"
  done

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test fu_2: full uninstall removes the pinned RTK binary + PATH snippet by
# default; --keep-rtk preserves both
# ---------------------------------------------------------------------------
test_full_uninstall_rtk_default_and_keep() {
  echo ""
  echo "--- test_full_uninstall_rtk_default_and_keep"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  local snippet
  snippet='# >>> forge rtk path >>>
case ":$PATH:" in *":$HOME/.forge/bin:"*) ;; *) export PATH="$HOME/.forge/bin:$PATH" ;; esac
# <<< forge rtk path <<<'

  # --- default: binary + snippet removed
  mkdir -p "$TMPHOME/.claude" "$TMPHOME/.forge/bin"
  printf '#!/bin/sh\necho rtk 0.0.0\n' > "$TMPHOME/.forge/bin/rtk"
  chmod +x "$TMPHOME/.forge/bin/rtk"
  printf 'export USER_LINE=1\n%s\n' "$snippet" > "$TMPHOME/.zshrc"
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

  assert_file_not_exists "$TMPHOME/.forge/bin/rtk" "full_uninstall_rtk: binary removed by default"
  assert_file_not_exists "$TMPHOME/.forge" "full_uninstall_rtk: empty ~/.forge pruned"
  if grep -qF 'forge rtk path' "$TMPHOME/.zshrc"; then
    fail "full_uninstall_rtk: PATH snippet still in .zshrc"
  else
    pass "full_uninstall_rtk: PATH snippet stripped from .zshrc"
  fi
  if grep -qF 'export USER_LINE=1' "$TMPHOME/.zshrc"; then
    pass "full_uninstall_rtk: user lines in .zshrc preserved"
  else
    fail "full_uninstall_rtk: user lines in .zshrc lost"
  fi

  # --- --keep-rtk: binary + snippet preserved
  mkdir -p "$TMPHOME/.forge/bin"
  printf '#!/bin/sh\necho rtk 0.0.0\n' > "$TMPHOME/.forge/bin/rtk"
  chmod +x "$TMPHOME/.forge/bin/rtk"
  printf 'export USER_LINE=1\n%s\n' "$snippet" > "$TMPHOME/.zshrc"
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall --keep-rtk >/dev/null 2>&1

  if [ -x "$TMPHOME/.forge/bin/rtk" ]; then
    pass "full_uninstall_rtk: --keep-rtk preserves the binary"
  else
    fail "full_uninstall_rtk: --keep-rtk removed the binary"
  fi
  if grep -qF 'forge rtk path' "$TMPHOME/.zshrc"; then
    pass "full_uninstall_rtk: --keep-rtk preserves the PATH snippet"
  else
    fail "full_uninstall_rtk: --keep-rtk stripped the PATH snippet"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test fu_3: restored pre-forge settings are sanitized — dead rtk hook and
# statusLine/subagentStatusLine pointing at removed scripts are dropped, user
# keys are preserved, and .pre-forge stays on disk (without --purge)
# ---------------------------------------------------------------------------
test_uninstall_sanitizes_restored_broken_settings() {
  echo ""
  echo "--- test_uninstall_sanitizes_restored_broken_settings"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude" "$TMPHOME/.forge/bin"
  printf '#!/bin/sh\necho rtk 0.0.0\n' > "$TMPHOME/.forge/bin/rtk"
  chmod +x "$TMPHOME/.forge/bin/rtk"

  cat > "$TMPHOME/.claude/settings.json" <<EOF
{
  "model": "fable",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "rtk hook claude --ultra-compact" } ] }
    ]
  },
  "statusLine": { "type": "command", "command": "bash $TMPHOME/.claude/statusline.sh" },
  "subagentStatusLine": { "type": "command", "command": "bash ~/.claude/subagent-statusline.sh" }
}
EOF

  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

  local model hooks statusline subagent
  model="$(jq -r '.model' "$TMPHOME/.claude/settings.json")"
  hooks="$(jq -r '.hooks // "absent"' "$TMPHOME/.claude/settings.json")"
  statusline="$(jq -r '.statusLine // "absent"' "$TMPHOME/.claude/settings.json")"
  subagent="$(jq -r '.subagentStatusLine // "absent"' "$TMPHOME/.claude/settings.json")"

  if [ "$model" = "fable" ]; then
    pass "sanitize: user model preserved"
  else
    fail "sanitize: user model lost (got '$model')"
  fi
  if [ "$hooks" = "absent" ]; then
    pass "sanitize: dead bare-rtk hook dropped"
  else
    fail "sanitize: dead bare-rtk hook still present: $hooks"
  fi
  if [ "$statusline" = "absent" ]; then
    pass "sanitize: statusLine pointing at removed script dropped"
  else
    fail "sanitize: broken statusLine still present"
  fi
  if [ "$subagent" = "absent" ]; then
    pass "sanitize: subagentStatusLine pointing at removed script dropped"
  else
    fail "sanitize: broken subagentStatusLine still present"
  fi
  if [ -f "$TMPHOME/.claude/settings.json.pre-forge" ]; then
    pass "sanitize: .pre-forge retained on disk (no --purge)"
  else
    fail "sanitize: .pre-forge missing"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test fu_4: uninstall --purge also deletes settings.json.pre-forge
# ---------------------------------------------------------------------------
test_purge_removes_pre_forge() {
  echo ""
  echo "--- test_purge_removes_pre_forge"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"
  printf '{"model": "fable"}\n' > "$TMPHOME/.claude/settings.json"
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  HOME="$TMPHOME" bash "$INSTALL_SH" uninstall --purge >/dev/null 2>&1

  assert_file_not_exists "$TMPHOME/.claude/settings.json.pre-forge" \
    "purge: settings.json.pre-forge deleted with --purge"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "=============================="
echo " install_integration.sh (e2e)"
echo "=============================="

test_e2e_install_uninstall_roundtrip
test_e2e_repair_recreates_broken_symlinks
test_e2e_status_reports_broken
test_e2e_rtk_no_binary_without_confirmation
test_state_schema_v2_shape
test_repair_uses_state_not_hardcoded
test_state_v1_migrates_to_v2
test_e2e_new_commands_distributed
test_e2e_legacy_commands_cleanup
test_install_only_statusline
test_p2_1_only_unknown_component_exits_nonzero
test_p2_2_only_commands_warns_no_agents
test_p2_3_sequential_install_unions_components
test_p2_4_uninstall_component_statusline_leaves_agents
test_p2_5_uninstall_unknown_component_exits_nonzero
test_p2_6_uninstall_not_installed_component_exits_nonzero
test_p2_9_status_only_statusline_no_missing_agents
test_p2_10_uninstall_component_multi_target_unit
test_partial_to_full_upgrade_installs_all_components
test_uninstall_component_leaves_no_orphan_parent_dirs
test_rules_symlinks_created
test_install_default_excludes_core
test_install_only_core
test_core_conflicts
test_full_uninstall_strips_claude_md_ref_and_dirs
test_full_uninstall_rtk_default_and_keep
test_uninstall_sanitizes_restored_broken_settings
test_purge_removes_pre_forge

echo ""
echo "=============================="
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
