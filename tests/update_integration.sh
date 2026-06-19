#!/usr/bin/env bash
# tests/update_integration.sh — integration tests for cmd_update (forge)
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
set -euo pipefail

ARSENAL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$ARSENAL_ROOT/install.sh"

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
# Test 1: update --show-cost creates .forge-show-cost sentinel
# ---------------------------------------------------------------------------
test_update_show_cost_creates_sentinel() {
  echo ""
  echo "--- test_update_show_cost_creates_sentinel"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Step 1: install without --show-cost
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude >/dev/null 2>&1

  # Verify sentinel is NOT present after plain install
  assert_file_not_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel ausente tras install sin --show-cost"

  # Step 2: update with --show-cost
  HOME="$TMPHOME" bash "$INSTALL_SH" update --show-cost >/dev/null 2>&1

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
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Install with --show-cost so sentinel is created
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=claude --show-cost >/dev/null 2>&1

  assert_file_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel presente tras install --show-cost"

  # Update WITHOUT --show-cost: sentinel must be removed
  HOME="$TMPHOME" bash "$INSTALL_SH" update >/dev/null 2>&1

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
  trap 'rm -rf "$TMPHOME"' EXIT

  mkdir -p "$TMPHOME/.claude"

  # Install targeting both (both == claude in forge)
  HOME="$TMPHOME" bash "$INSTALL_SH" install --target=both >/dev/null 2>&1

  # Update with --show-cost
  HOME="$TMPHOME" bash "$INSTALL_SH" update --show-cost >/dev/null 2>&1

  assert_file_exists "$TMPHOME/.claude/.forge-show-cost" \
    "sentinel creado en target claude por update --show-cost"

  trap - EXIT
  rm -rf "$TMPHOME"
}

# ---------------------------------------------------------------------------
# Test 4: update --show-cost skips opencode target (no sentinel created)
# ---------------------------------------------------------------------------
test_update_show_cost_skips_opencode() {
  echo ""
  echo "--- test_update_show_cost_skips_opencode"
  local TMPHOME
  TMPHOME="$(mktemp -d)"
  trap 'rm -rf "$TMPHOME"' EXIT

  # Directories for a claude target and a fake opencode config dir
  local claude_dir="$TMPHOME/.claude"
  local opencode_dir="$TMPHOME/.config/opencode"
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
  HOME="$TMPHOME" bash "$INSTALL_SH" update --show-cost >/dev/null 2>&1 || exit_code=$?

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

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
