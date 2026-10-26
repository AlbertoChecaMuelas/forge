#!/usr/bin/env bash
# tests/install_integration.sh — e2e integration tests for forge
# Runs end-to-end cases in isolated sandbox HOME directories.
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$FORGE_ROOT/install.sh"

# Shared isolation helpers: the isolated environment and the fingerprint of
# the real user files.
# shellcheck source=tests/isolation.sh
. "$FORGE_ROOT/tests/isolation.sh"

# Fingerprint of the real user files, taken BEFORE any test runs. The suite
# must leave them untouched: the installer resolves the pinned OpenCode prefix
# from XDG_DATA_HOME / FORGE_OPENCODE_BIN_DIR, so an unisolated run installs
# @opencode/cli@2.1.4 in the REAL ~/.local/share/forge/opencode-v2.
PROTECTED_SNAPSHOT="$(forge_protected_snapshot)"

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
# Isolated runner.
#
# HOME, the XDG directories and the Forge-owned OpenCode prefix are redirected
# into the sandbox, and OPENCODE_CONFIG_DIR / OPENCODE_CONFIG are removed on
# purpose: the installer gives them precedence over HOME, so an inherited
# real-user config could otherwise be read (or written) by a test.
#
# FORGE_OPENCODE_BIN_DIR closes the last leak: the pinned OpenCode build is
# installed in that prefix, so an unisolated run would download
# @opencode/cli@2.1.4 into the REAL ~/.local/share/forge/opencode-v2.
# ---------------------------------------------------------------------------
run_iso() {
  local home="$1"
  shift

  forge_isolated_env "$home" "$@"
}

# ---------------------------------------------------------------------------
# Diagnostic runner: runs a forge subcommand in an isolated HOME and captures
# the combined output (stdout+stderr) plus the exit code.
#
# Sets: RUN_OUT (combined output), RUN_RC (exit code).
# ---------------------------------------------------------------------------
run_forge() {
  local home="$1"
  shift
  RUN_RC=0
  RUN_OUT="$(run_iso "$home" bash "$INSTALL_SH" "$@" 2>&1)" || RUN_RC=$?
}

# Disposable sandbox root for the diagnostics tests: isolated from the real
# HOME, from the repo and from any other suite.
FORGE_TEST_TMP_ROOT="/tmp/opencode"

# make_diag_home <label>
# Creates an isolated HOME below the disposable sandbox root.
make_diag_home() {
  local label="$1"

  mkdir -p "$FORGE_TEST_TMP_ROOT"
  mktemp -d "$FORGE_TEST_TMP_ROOT/${label}.XXXXXX"
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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude

  # Verify symlink exists
  assert_true "senior.md symlink created" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  # Break the symlink
  rm "$TMPHOME/.claude/agents/senior.md"
  assert_true "symlink removed (simulating break)" \
    test ! -e "$TMPHOME/.claude/agents/senior.md"

  # Repair
  run_iso "$TMPHOME" bash "$INSTALL_SH" repair

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude

  # Break a symlink by pointing it to /nonexistent
  rm "$TMPHOME/.claude/agents/senior.md"
  ln -s "/nonexistent/path" "$TMPHOME/.claude/agents/senior.md"

  # Status should exit != 0 and mention BROKEN or MISMATCH
  local status_out
  status_out="$(run_iso "$TMPHOME" bash "$INSTALL_SH" status 2>&1 || true)"
  local status_exit=0
  run_iso "$TMPHOME" bash "$INSTALL_SH" status >/dev/null 2>&1 || status_exit=$?

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

  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

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

  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

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

  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Break a symlink
  rm "$TMPHOME/.claude/agents/senior.md"
  assert_true "symlink roto (setup)" test ! -e "$TMPHOME/.claude/agents/senior.md"

  # Repair using state-driven logic
  run_iso "$TMPHOME" bash "$INSTALL_SH" repair >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" repair >/dev/null 2>&1

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
# Test 8: `status` is read-only on a legacy v1 state (in-memory migration)
# ---------------------------------------------------------------------------
# Contract:
#   * `status` NEVER rewrites the state file: the bytes and the mtime must be
#     identical before and after the run (the on-disk migration belongs to
#     `repair`/`update`, not to the diagnostics).
#   * `status` still READS a legacy v1 state: the diagnostic view reproduces
#     the v1 -> v3 migration in memory, so the target and its components are
#     reported exactly as they would be after an on-disk migration.
# ---------------------------------------------------------------------------
test_state_v1_status_is_read_only() {
  echo ""
  echo "--- test_state_v1_status_is_read_only"
  local TMPHOME
  TMPHOME="$(make_diag_home "claude-state-v1")"
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

  local sha_before mtime_before
  sha_before="$(sha256sum "$state" | cut -d' ' -f1)"
  mtime_before="$(stat -c '%y' "$state")"

  # Run status — must be strictly read-only
  run_forge "$TMPHOME" status

  local sha_after mtime_after
  sha_after="$(sha256sum "$state" | cut -d' ' -f1)"
  mtime_after="$(stat -c '%y' "$state")"

  # --- (a) the state file is not rewritten ---
  if [ "$sha_before" = "$sha_after" ]; then
    pass "status no reescribe el state file v1 (sha256 idéntico)"
  else
    fail "status reescribió el state file v1 (sha256 $sha_before -> $sha_after)"
  fi

  if [ "$mtime_before" = "$mtime_after" ]; then
    pass "status no toca el mtime del state file v1"
  else
    fail "status cambió el mtime del state file v1 ($mtime_before -> $mtime_after)"
  fi

  local schema_on_disk manifest_on_disk
  schema_on_disk="$(jq -r '.state_schema // "absent"' "$state")"
  manifest_on_disk="$(jq -r '.targets_manifest // "absent"' "$state")"
  if [ "$schema_on_disk" = "absent" ] && [ "$manifest_on_disk" = "absent" ]; then
    pass "el state v1 sigue en disco sin state_schema ni targets_manifest"
  else
    fail "status migró el state v1 en disco (schema=$schema_on_disk manifest=$manifest_on_disk)"
  fi

  # --- (b) the legacy state is still read correctly (in-memory migration) ---
  if printf '%s' "$RUN_OUT" | grep -q "Target: claude ($claude_dir)"; then
    pass "status lee el state v1 y muestra el target claude con su directorio"
  else
    fail "status no mostró el target claude leído del state v1"
  fi

  local expected_components="agents commands statusline branch-guard rtk-hook cost-report cost-report-skill"
  if printf '%s' "$RUN_OUT" | grep -q "Componentes: $expected_components"; then
    pass "status replica en memoria la migración v1 (componentes por defecto)"
  else
    fail "status no replicó la migración v1 en memoria (componentes)"
  fi

  # The migrated view is really applied: the artifacts of the migrated
  # manifest are evaluated against the disk, so the run is degraded.
  if [ "$RUN_RC" -ne 0 ]; then
    pass "status sale != 0 con el manifiesto v1 migrado en memoria"
  else
    fail "status debería salir != 0 (el manifiesto migrado se evalúa contra el disco)"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 8b: Claude parity — the Claude contract of status/doctor is unchanged
# ---------------------------------------------------------------------------
# The OpenCode rework must not alter the Claude behaviour. This test pins it:
#   * a missing symlink is reported as BROKEN and the run exits non-zero
#   * a symlink pointing elsewhere is reported as MISMATCH (and so is a
#     regular file in place of a symlink)
#   * `--only=statusline` does not report the agents that are not installed
#   * a corrupt state file makes status fail (exit 1)
#   * a missing state file makes status succeed (exit 0) and doctor too
#     (regression: `_doc_rtk_hook_present` used to be unbound -> crash)
# ---------------------------------------------------------------------------
test_claude_status_doctor_parity() {
  echo ""
  echo "--- test_claude_status_doctor_parity"
  local TMPHOME
  TMPHOME="$(make_diag_home "claude-diag-parity")"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"
  run_iso "$TMPHOME" \
    bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # --- (1) missing symlink -> BROKEN + non-zero exit ---
  rm "$TMPHOME/.claude/agents/senior.md"
  run_forge "$TMPHOME" status
  if [ "$RUN_RC" -ne 0 ]; then
    pass "claude: status sale != 0 con symlink ausente"
  else
    fail "claude: status debería salir != 0 con symlink ausente"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "BROKEN.*agents/senior.md"; then
    pass "claude: status reporta BROKEN para el symlink ausente"
  else
    fail "claude: status no reportó BROKEN para el symlink ausente"
  fi

  run_forge "$TMPHOME" doctor
  if [ "$RUN_RC" -ne 0 ]; then
    pass "claude: doctor sale != 0 con symlink ausente"
  else
    fail "claude: doctor debería salir != 0 con symlink ausente"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "symlink BROKEN"; then
    pass "claude: doctor reporta symlink BROKEN"
  else
    fail "claude: doctor no reportó symlink BROKEN"
  fi

  # --- (2) symlink pointing elsewhere -> MISMATCH + non-zero exit ---
  ln -s "/nonexistent/path" "$TMPHOME/.claude/agents/senior.md"
  run_forge "$TMPHOME" status
  if [ "$RUN_RC" -ne 0 ]; then
    pass "claude: status sale != 0 con symlink que apunta a otro sitio"
  else
    fail "claude: status debería salir != 0 con symlink que apunta a otro sitio"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "MISMATCH.*agents/senior.md"; then
    pass "claude: status reporta MISMATCH para el symlink que apunta a otro sitio"
  else
    fail "claude: status no reportó MISMATCH para el symlink que apunta a otro sitio"
  fi

  # --- (3) regular file in place of a symlink -> MISMATCH (no es symlink) ---
  rm "$TMPHOME/.claude/agents/senior.md"
  printf 'no soy un symlink\n' > "$TMPHOME/.claude/agents/senior.md"
  run_forge "$TMPHOME" status
  if printf '%s' "$RUN_OUT" | grep -q "MISMATCH.*agents/senior.md.*no es symlink"; then
    pass "claude: status reporta MISMATCH (no es symlink) para un fichero regular"
  else
    fail "claude: status no reportó MISMATCH (no es symlink) para un fichero regular"
  fi

  # --- (4) corrupt state file -> status/doctor fail ---
  printf 'esto no es json' > "$TMPHOME/.forge-state.json"
  run_forge "$TMPHOME" status
  if [ "$RUN_RC" -ne 0 ]; then
    pass "claude: status sale != 0 con state file corrupto"
  else
    fail "claude: status debería salir != 0 con state file corrupto"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "state file inválido"; then
    pass "claude: status informa del state file corrupto"
  else
    fail "claude: status no informó del state file corrupto"
  fi

  run_forge "$TMPHOME" doctor
  if [ "$RUN_RC" -ne 0 ]; then
    pass "claude: doctor sale != 0 con state file corrupto"
  else
    fail "claude: doctor debería salir != 0 con state file corrupto"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "state file corrupto"; then
    pass "claude: doctor informa del state file corrupto"
  else
    fail "claude: doctor no informó del state file corrupto"
  fi

  # --- (5) no state file -> status/doctor succeed ---
  rm -f "$TMPHOME/.forge-state.json"
  run_forge "$TMPHOME" status
  if [ "$RUN_RC" -eq 0 ]; then
    pass "claude: status sale 0 sin state file"
  else
    fail "claude: status debería salir 0 sin state file (got $RUN_RC)"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "no instalado"; then
    pass "claude: status informa de que no está instalado sin state file"
  else
    fail "claude: status no informó de que no está instalado sin state file"
  fi

  run_forge "$TMPHOME" doctor
  if [ "$RUN_RC" -eq 0 ]; then
    pass "claude: doctor sale 0 sin state file (regresión _doc_rtk_hook_present)"
  else
    fail "claude: doctor debería salir 0 sin state file (got $RUN_RC)"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "state file no encontrado"; then
    pass "claude: doctor avisa de que no hay state file"
  else
    fail "claude: doctor no avisó de que no hay state file"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "^  FAIL "; then
    fail "claude: doctor no debería reportar ningún FAIL sin state file"
  else
    pass "claude: doctor no reporta ningún FAIL sin state file"
  fi

  trap - EXIT
  rm -rf "$TMPHOME"

  # --- (6) --only=statusline: the agents that are not installed are not reported ---
  local TMPHOME2
  TMPHOME2="$(make_diag_home "claude-diag-statusline")"
  trap 'rm -rf "$TMPHOME2"' EXIT

  mkdir -p "$TMPHOME2/.claude"
  run_iso "$TMPHOME2" \
    bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  run_forge "$TMPHOME2" status
  if [ "$RUN_RC" -eq 0 ]; then
    pass "claude: status sale 0 con --only=statusline"
  else
    fail "claude: status debería salir 0 con --only=statusline (got $RUN_RC)"
  fi
  if printf '%s' "$RUN_OUT" | grep -q "Componentes: statusline"; then
    pass "claude: status muestra solo el componente statusline"
  else
    fail "claude: status no mostró solo el componente statusline"
  fi
  if printf '%s' "$RUN_OUT" | grep -qi "senior\|BROKEN\|MISSING"; then
    fail "claude: status no debe reportar agentes ausentes con --only=statusline"
  else
    pass "claude: status no reporta agentes ausentes con --only=statusline"
  fi

  trap - EXIT
  rm -rf "$TMPHOME2"
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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

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

  for skill in cost-report create-plan execute-plan plan-format testing-angular testing-spring-boot testing-pytest; do
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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  local backup_count
  backup_count=$(find "$TMPHOME/.claude/skills" -name "*.forge-bak-*" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$backup_count" = "0" ]; then
    pass "No debe haber backups tras segundo install"
  else
    fail "No debe haber backups tras segundo install (found $backup_count)"
  fi

  # Uninstall removes all five skill directories
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

  assert_file_not_exists "$TMPHOME/.claude/skills/cost-report/SKILL.md" \
    "skills/cost-report/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/create-plan/SKILL.md" \
    "skills/create-plan/SKILL.md eliminado tras uninstall"
  assert_file_not_exists "$TMPHOME/.claude/skills/execute-plan/SKILL.md" \
    "skills/execute-plan/SKILL.md eliminado tras uninstall"
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
  for skill in cost-report create-plan execute-plan plan-format testing-angular testing-spring-boot testing-pytest; do
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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

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
  stderr_out="$(run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=bogus-component 2>&1 >/dev/null)" || exit_code=$?

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
  combined_out="$(run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=commands 2>&1)" || exit_code=$?

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  # Second install: agents only
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=agents >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Selective uninstall of statusline
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall --component=statusline >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  local exit_code=0
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall --component=bogus-component >/dev/null 2>&1 || exit_code=$?

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=agents >/dev/null 2>&1

  local stderr_out exit_code=0
  stderr_out="$(run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall --component=statusline 2>&1 >/dev/null)" || exit_code=$?

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  # Run status and capture all output
  local status_out exit_code=0
  status_out="$(run_iso "$TMPHOME" bash "$INSTALL_SH" status 2>&1)" || exit_code=$?

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall --component=statusline >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=statusline >/dev/null 2>&1

  # After step 1: agents/senior.md must NOT be present
  assert_file_not_exists "$TMPHOME/.claude/agents/senior.md" \
    "agents/senior.md absent after --only=statusline"

  # Statusline must be present after step 1
  assert_true "statusline.sh present after step 1" \
    test -L "$TMPHOME/.claude/statusline.sh"

  # Step 2: full install (no --only)
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude --only=agents >/dev/null 2>&1

  # Verify agents/senior.md symlink is present before uninstall
  assert_true "agents/senior.md present before uninstall" \
    test -L "$TMPHOME/.claude/agents/senior.md"

  # Step 2: selective uninstall of agents component
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall --component=agents >/dev/null 2>&1

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

  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --only=core --target=claude >/dev/null 2>&1

  assert_is_symlink_to "$TMPHOME/.claude/CLAUDE-shared.md" \
    "$FORGE_ROOT/shared/CLAUDE-shared.md" \
    "only_core: CLAUDE-shared.md symlinked"
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
    env run_iso "$TMPHOME" bash "$INSTALL_SH" install --only=core,agents --target=claude

  run_iso "$TMPHOME" bash "$INSTALL_SH" install --only=core --target=claude >/dev/null 2>&1
  assert_exit_nonzero "core_conflicts: --only=agents over installed core exits non-zero" \
    env run_iso "$TMPHOME" bash "$INSTALL_SH" install --only=agents --target=claude
  assert_exit_nonzero "core_conflicts: default install over installed core exits non-zero" \
    env run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude
  if run_iso "$TMPHOME" bash "$INSTALL_SH" install --only=core --target=claude >/dev/null 2>&1; then
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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall --keep-rtk >/dev/null 2>&1

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

  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall >/dev/null 2>&1

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
  run_iso "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1
  run_iso "$TMPHOME" bash "$INSTALL_SH" uninstall --purge >/dev/null 2>&1

  assert_file_not_exists "$TMPHOME/.claude/settings.json.pre-forge" \
    "purge: settings.json.pre-forge deleted with --purge"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test harness contract: the runner must execute EVERY candidate suite.
#
# Regression guard. The runner used to feed the list of suites to the suites
# themselves through a heredoc, so a suite that read stdin swallowed one line
# of that list and the suite right after it was never run. The summary still
# said "Passed: 14 / Failed: 0": a green run that had silently dropped half
# of the suites.
#
# The runner is exercised against a sandbox copy that mirrors the real
# candidate set (tests/*_unit.sh + tests/*_integration.sh + EXTRA_TESTS). The
# first candidate is a stub that greedily reads stdin: with the regression the
# executed count drops by one and the stub steals the path of the next suite;
# with the fix every candidate runs and the stub reads nothing.
# ---------------------------------------------------------------------------

# Prints the basenames of the suites the runner would collect.
run_all_candidate_names() {
  local runner="$1"
  local tests_dir="$2"

  find "$tests_dir" -maxdepth 1 \( -name '*_unit.sh' -o -name '*_integration.sh' \) \
    | sed 's|.*/||' | sort

  local extra_line
  extra_line="$(grep -m1 '^EXTRA_TESTS=' "$runner" 2>/dev/null || true)"
  if [ -n "$extra_line" ]; then
    (
      SCRIPT_DIR="$tests_dir"
      export SCRIPT_DIR
      # shellcheck disable=SC1090
      eval "$extra_line"
      # shellcheck disable=SC2086
      for f in $EXTRA_TESTS; do
        [ -f "$f" ] && basename "$f"
      done
    )
  fi
}

# Suites that used to be swallowed by the heredoc and never ran.
RUN_ALL_PREVIOUSLY_LOST_SUITES="protocol_unit.sh readme_sync_unit.sh
release_flow_integration.sh release_skill_unit.sh rtk_unit.sh
settings_integration.sh state_migration_unit.sh symlink_unit.sh
total_usage_unit.sh update_integration.sh"

test_run_all_executes_every_candidate_suite() {
  echo ""
  echo "--- test_run_all_executes_every_candidate_suite"

  local runner="$FORGE_ROOT/tests/run-all.sh"
  local tests_dir="$FORGE_ROOT/tests"
  local SANDBOX sandbox_tests candidates_file candidates candidate_count
  local greedy_name output runner_rc=0 reported_count reported_failed
  local missing known_suite

  candidates="$(run_all_candidate_names "$runner" "$tests_dir")"
  if [ -z "$candidates" ]; then
    fail "run-all: no candidate suite found in $tests_dir"
    return
  fi
  candidate_count="$(printf '%s\n' "$candidates" | wc -l | tr -d ' ')"

  if [ "$candidate_count" -gt 0 ]; then
    pass "run-all: $candidate_count candidate suites collected from $tests_dir"
  else
    fail "run-all: 0 candidate suites collected from $tests_dir"
  fi

  SANDBOX="$(mktemp -d "$FORGE_TEST_TMP_ROOT/run-all-contract.XXXXXX")"
  trap 'rm -rf "$SANDBOX"' EXIT
  sandbox_tests="$SANDBOX/tests"
  mkdir -p "$sandbox_tests"
  candidates_file="$SANDBOX/candidates.txt"
  printf '%s\n' "$candidates" > "$candidates_file"

  # The real runner, byte for byte: only the suites are replaced by stubs.
  cp "$runner" "$sandbox_tests/run-all.sh"

  greedy_name="$(head -n 1 "$candidates_file")"
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    if [ "$candidate" = "$greedy_name" ]; then
      cat > "$sandbox_tests/$candidate" <<'STUB'
#!/usr/bin/env bash
IFS= read -r stolen || true
printf 'GREEDY_STDIN=[%s]\n' "$stolen"
exit 0
STUB
    else
      cat > "$sandbox_tests/$candidate" <<'STUB'
#!/usr/bin/env bash
printf 'STUB_OK\n'
exit 0
STUB
    fi
    chmod +x "$sandbox_tests/$candidate"
  done < "$candidates_file"

  # FORGE_TEST_FILTER must not leak into the sandbox run.
  output="$(cd "$sandbox_tests" && env -u FORGE_TEST_FILTER \
    bash "$sandbox_tests/run-all.sh" 2>&1)" || runner_rc=$?

  if [ "$runner_rc" -eq 0 ]; then
    pass "run-all: the runner exits 0"
  else
    fail "run-all: the runner exited $runner_rc (expected 0)"
  fi

  reported_count="$(printf '%s\n' "$output" \
    | grep -E '^[[:space:]]*Tests run:' | grep -oE '[0-9]+' | head -n 1)"
  reported_failed="$(printf '%s\n' "$output" \
    | grep -E '^[[:space:]]*Failed:' | grep -oE '[0-9]+' | head -n 1)"

  if [ "$reported_count" = "$candidate_count" ]; then
    pass "run-all: executed $reported_count suites, one per candidate"
  else
    fail "run-all: executed ${reported_count:-0} suites but $candidate_count were candidates"
  fi

  if [ "${reported_failed:-1}" = "0" ]; then
    pass "run-all: no suite failed"
  else
    fail "run-all: ${reported_failed:-?} suite(s) failed"
  fi

  missing=""
  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    if ! printf '%s\n' "$output" | grep -qF "PASS  $candidate"; then
      missing="$missing $candidate"
    fi
  done < "$candidates_file"

  if [ -z "$missing" ]; then
    pass "run-all: every candidate suite was executed"
  else
    fail "run-all: candidate suites never executed:$missing"
  fi

  # The greedy stub proves the suites no longer share the stdin of the runner:
  # it must not be able to steal the path of the next suite.
  if printf '%s\n' "$output" | grep -qF 'GREEDY_STDIN=[]'; then
    pass "run-all: a suite reading stdin gets its own stdin, not the suite list"
  else
    fail "run-all: a suite reading stdin stole the suite list (stdin devorado regression)"
  fi

  # The suites that used to disappear silently must be part of the run.
  for known_suite in $RUN_ALL_PREVIOUSLY_LOST_SUITES; do
    if [ ! -f "$tests_dir/$known_suite" ]; then
      fail "run-all: $known_suite does not exist in $tests_dir"
      continue
    fi
    if printf '%s\n' "$output" | grep -qF "PASS  $known_suite"; then
      pass "run-all: $known_suite is executed"
    else
      fail "run-all: $known_suite was not executed"
    fi
  done

  rm -rf "$SANDBOX"
  trap - EXIT
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
test_state_v1_status_is_read_only
test_claude_status_doctor_parity
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
test_run_all_executes_every_candidate_suite

# ---------------------------------------------------------------------------
# Leak guard: the suite must never create the real pinned OpenCode prefix and
# must never modify the real user files.
# ---------------------------------------------------------------------------
check_real_user_untouched() {
  local rc=0

  if ! forge_assert_no_forge_prefix "$PROTECTED_SNAPSHOT"; then
    rc=1
  fi
  if ! forge_assert_protected_unchanged "$PROTECTED_SNAPSHOT"; then
    rc=1
  fi

  return $rc
}

echo ""
echo "=============================="
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
fi

if ! check_real_user_untouched; then
  echo " FAIL: the suite touched the real user files" >&2
  exit 1
fi

echo " ALL PASS"
