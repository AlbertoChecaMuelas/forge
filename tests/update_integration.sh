#!/usr/bin/env bash
# tests/update_integration.sh — integration tests for cmd_update (forge)
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$FORGE_ROOT/install.sh"

# Shared isolation helpers: the isolated environment, the fingerprint of the
# real user files and the fake toolchain.
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

assert_file_exists() {
  local f="$1"
  local desc="$2"
  if [ -f "$f" ]; then
    pass "$desc"
  else
    fail "$desc (file missing: $f)"
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
# The EXIT trap of the sandbox.
#
# The directory that the trap has to remove is kept in a GLOBAL and NOT in
# the `local` of the function that installs the trap. An EXIT trap that reads
# a `local` of a function that ALREADY RETURNED fails with "unbound
# variable", and that failure is surfaced AFTER the real diagnostic: the
# reader would see the message of the trap instead of the message of the test
# that failed, and the CAUSE would be masked by an error that says nothing
# about the cause.
#
# The trap never fails either: it ignores an empty slot and it never changes
# the exit status of the suite.
# ---------------------------------------------------------------------------
EXIT_CLEANUP_DIR=""

# install_exit_cleanup <dir>
#
# Installs the EXIT trap that removes <dir>.
install_exit_cleanup() {
  EXIT_CLEANUP_DIR="$1"
  trap 'rm -rf -- "${EXIT_CLEANUP_DIR:-}" 2>/dev/null || true' EXIT
}

# ---------------------------------------------------------------------------
# Isolated runner for the installer.
#
# HOME, the XDG directories and the Forge-owned OpenCode prefix are redirected
# into the sandbox, and the OpenCode config overrides are removed on purpose:
# the overlay installer gives them precedence over HOME, so an inherited
# real-user config would be rewritten by any command that reaches the OpenCode
# target.
#
# FORGE_OPENCODE_BIN_DIR matters as much: the pinned OpenCode build is
# installed there, and without this isolation the installer would download
# @opencode/cli@2.1.4 into the REAL ~/.local/share/forge/opencode-v2.
#
# The fake toolchain is first in PATH so the suite never downloads anything.
# ---------------------------------------------------------------------------
run_install() {
  local home="$1"
  shift

  forge_make_toolchain "$home/fakebin"

  forge_isolated_env "$home" PATH="$home/fakebin:$PATH" "$@"
}

# ---------------------------------------------------------------------------
# Test 1: update --show-cost creates .forge-show-cost sentinel
# ---------------------------------------------------------------------------
test_update_show_cost_creates_sentinel() {
  echo ""
  echo "--- test_update_show_cost_creates_sentinel"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  install_exit_cleanup "$TMPHOME"

  mkdir -p "$TMPHOME/.claude"

  # Step 1: install without --show-cost
  run_install "$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Verify sentinel is NOT present after plain install
  assert_file_not_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel ausente tras install sin --show-cost"

  # Step 2: update with --show-cost
  run_install "$TMPHOME" bash "$INSTALL_SH" update --show-cost >/dev/null 2>&1

  # Sentinel must now exist
  assert_file_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel creado por update --show-cost"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 2: update without --show-cost removes sentinel if previously present
# ---------------------------------------------------------------------------
test_update_no_show_cost_removes_sentinel() {
  echo ""
  echo "--- test_update_no_show_cost_removes_sentinel"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  install_exit_cleanup "$TMPHOME"

  mkdir -p "$TMPHOME/.claude"

  # Install with --show-cost so sentinel is created
  run_install "$TMPHOME" bash "$INSTALL_SH" install --target=claude --show-cost >/dev/null 2>&1

  assert_file_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel presente tras install --show-cost"

  # Update WITHOUT --show-cost: sentinel must be removed
  run_install "$TMPHOME" bash "$INSTALL_SH" update >/dev/null 2>&1

  assert_file_not_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel eliminado por update sin --show-cost"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 3: update --show-cost with both targets creates sentinel in each
# ---------------------------------------------------------------------------
test_update_show_cost_both_targets() {
  echo ""
  echo "--- test_update_show_cost_both_targets"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  install_exit_cleanup "$TMPHOME"

  mkdir -p "$TMPHOME/.claude"

  # Install targeting both; OpenCode uses its own isolated overlay target.
  run_install "$TMPHOME" OPENAI_API_KEY=test-openai-key bash "$INSTALL_SH" install --target=both >/dev/null 2>&1

  # Update with --show-cost
  run_install "$TMPHOME" OPENAI_API_KEY=test-openai-key bash "$INSTALL_SH" update --show-cost >/dev/null 2>&1

  assert_file_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel creado en target claude por update --show-cost"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 4: update --show-cost skips opencode overlay target (no sentinel created)
# ---------------------------------------------------------------------------
test_update_show_cost_skips_opencode() {
  echo ""
  echo "--- test_update_show_cost_skips_opencode"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  install_exit_cleanup "$TMPHOME"

  # Directories for a claude target and a fake opencode overlay dir
  local claude_dir="$TMPHOME/.claude"
  local opencode_dir="$TMPHOME/.config/opencode-forge"
  mkdir -p "$claude_dir" "$opencode_dir"

  # Build a schema-2 state file that includes both a claude entry and an
  # opencode entry, without actually running a full install (avoids gcloud auth
  # or other requirements for the opencode installer).
  local state_file="$TMPHOME/.forge-state.json"
  jq -n \
    --arg claude_dir "$claude_dir" \
    --arg opencode_dir "$opencode_dir" \
    '{
      state_schema: 2,
      targets: ["claude", "opencode"],
      targets_manifest: [
        {name: "claude",   dir: $claude_dir,   symlinks: [], settings_merged: true, settings_backup: null},
        {name: "opencode", dir: $opencode_dir, symlinks: [], settings_merged: true, settings_backup: null}
      ]
    }' > "$state_file"

  # Run update --show-cost; redirect all output to /dev/null
  local exit_code=0
  run_install "$TMPHOME" OPENAI_API_KEY=test-openai-key bash "$INSTALL_SH" update --show-cost >/dev/null 2>&1 || exit_code=$?

  assert_true "update --show-cost exits 0 with opencode in manifest" \
    test "$exit_code" -eq 0

  assert_file_exists "$claude_dir/.forge-show-cost" \
    "sentinel creado en target claude por update --show-cost"

  assert_file_not_exists "$opencode_dir/.forge-show-cost" \
    "sentinel NO creado en target opencode por update --show-cost (skip logic)"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "================================"
echo " update_integration.sh"
echo "================================"

test_update_show_cost_creates_sentinel
test_update_no_show_cost_removes_sentinel
test_update_show_cost_both_targets
test_update_show_cost_skips_opencode

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
echo "================================"
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
