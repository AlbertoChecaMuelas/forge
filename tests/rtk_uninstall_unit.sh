#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/rtk_uninstall_unit.sh — unit tests for rtk/uninstall-rtk.sh
# Tests 6 scenarios in isolated sandbox HOME directories.
# T1, T2, T6: state-file edge cases.
# T3, T4, T5: filesystem-based uninstall scenarios (fake ~/.forge/bin/rtk).
# TC1, TC3: forge marker blocks are removed from shell profiles.
# Compatible with bash 3.2+.
set -euo pipefail

cd "$(dirname "$0")/.."
FORGE_ROOT="$(pwd)"
UNINSTALL_SH="$FORGE_ROOT/rtk/uninstall-rtk.sh"

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

assert_file_not_exists() {
  local f="$1"
  local desc="$2"
  if [ ! -e "$f" ]; then
    pass "$desc"
  else
    fail "$desc (file exists: $f)"
  fi
}

assert_exit_zero() {
  local desc="$1"
  local code="$2"
  if [ "$code" -eq 0 ]; then
    pass "$desc"
  else
    fail "$desc (expected exit 0, got $code)"
  fi
}

assert_exit_nonzero() {
  local desc="$1"
  local code="$2"
  if [ "$code" -ne 0 ]; then
    pass "$desc"
  else
    fail "$desc (expected non-zero exit, got 0)"
  fi
}

assert_json_field() {
  local file="$1"
  local jq_filter="$2"
  local expected="$3"
  local desc="$4"
  local actual
  actual="$(jq -r "$jq_filter" "$file" 2>/dev/null || echo "__jq_error__")"
  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (expected='$expected', got='$actual')"
  fi
}

# ---------------------------------------------------------------------------
# T1 — State file absent: no state file, script exits 0, does nothing
# ---------------------------------------------------------------------------
test_t1_state_file_absent() {
  echo ""
  echo "--- T1: state file absent"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  mkdir -p "$tmpdir/.local/bin"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "T1: exits 0 when no state file" "$exit_code"
  assert_file_not_exists "$tmpdir/.local/bin/rtk" "T1: no rtk binary created"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# T2 — installed_by_us: false: script exits 0, does not invoke brew
# ---------------------------------------------------------------------------
test_t2_installed_by_us_false() {
  echo ""
  echo "--- T2: installed_by_us false"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # State with installed_by_us: false (no brew shim needed — script exits early)
  printf '{"rtk":{"installed_by_us":false,"detected_version":null,"pinned_version":"0.37.2","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "T2: exits 0 when installed_by_us=false" "$exit_code"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# T3 — RTK present and installed_by_us=true: file removed, state updated
# ---------------------------------------------------------------------------
test_t3_rtk_present_installed_by_us_true() {
  echo ""
  echo "--- T3: RTK present, installed_by_us=true"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Create a fake ~/.forge/bin/rtk executable
  mkdir -p "$tmpdir/.forge/bin"
  printf '#!/bin/bash\necho fake-rtk\n' > "$tmpdir/.forge/bin/rtk"
  chmod +x "$tmpdir/.forge/bin/rtk"

  # State with installed_by_us: true
  printf '{"rtk":{"installed_by_us":true,"detected_version":"0.37.2","pinned_version":"0.37.2","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "T3: exits 0 after removing rtk binary" "$exit_code"
  assert_file_not_exists "$tmpdir/.forge/bin/rtk" "T3: rtk binary was removed"
  assert_json_field "$tmpdir/.forge-state.json" '.rtk.installed_by_us' "false" \
    "T3: state updated to installed_by_us=false"
  assert_json_field "$tmpdir/.forge-state.json" '.rtk.detected_version' "null" \
    "T3: state updated to detected_version=null"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# T4 — RTK absent and installed_by_us=true: idempotent no-op, state updated
# ---------------------------------------------------------------------------
test_t4_rtk_absent_installed_by_us_true() {
  echo ""
  echo "--- T4: RTK absent, installed_by_us=true (idempotent)"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Do NOT create ~/.forge/bin/rtk — binary is already gone

  # State with installed_by_us: true
  printf '{"rtk":{"installed_by_us":true,"detected_version":"0.37.2","pinned_version":"0.37.2","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "T4: exits 0 when rtk binary already absent (idempotent)" "$exit_code"
  assert_json_field "$tmpdir/.forge-state.json" '.rtk.installed_by_us' "false" \
    "T4: state updated to installed_by_us=false (idempotent)"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# T5 — RTK present but installed_by_us=false: file NOT removed, exits 0
# ---------------------------------------------------------------------------
test_t5_rtk_present_installed_by_us_false() {
  echo ""
  echo "--- T5: RTK present, installed_by_us=false"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Create a fake ~/.forge/bin/rtk executable
  mkdir -p "$tmpdir/.forge/bin"
  printf '#!/bin/bash\necho fake-rtk\n' > "$tmpdir/.forge/bin/rtk"
  chmod +x "$tmpdir/.forge/bin/rtk"

  # State with installed_by_us: false
  printf '{"rtk":{"installed_by_us":false,"detected_version":"0.37.2","pinned_version":"0.37.2","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "T5: exits 0 when installed_by_us=false" "$exit_code"
  assert_true "T5: rtk binary NOT removed when installed_by_us=false" \
    test -f "$tmpdir/.forge/bin/rtk"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# T6 — State file with invalid JSON: exits non-zero, does not crash
# ---------------------------------------------------------------------------
test_t6_invalid_json_state() {
  echo ""
  echo "--- T6: invalid JSON state file"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  mkdir -p "$tmpdir/.local/bin"

  # Write invalid JSON (use cat to avoid printf format-character interpretation)
  printf '%s' 'THIS IS NOT JSON { broken }' > "$tmpdir/.forge-state.json"

  # Create a real binary that should NOT be removed on parse error
  printf '#!/bin/bash\necho fake-rtk\n' > "$tmpdir/.local/bin/rtk"
  chmod +x "$tmpdir/.local/bin/rtk"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_nonzero "T6: exits non-zero on invalid JSON" "$exit_code"
  assert_true "T6: rtk binary untouched on parse error" test -f "$tmpdir/.local/bin/rtk"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# TC1 — Marker removal: removes block, preserves surrounding content
# ---------------------------------------------------------------------------
test_tc1_marker_block_removed_preserves_context() {
  echo ""
  echo "--- TC1: marker block removed, surrounding content preserved"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Create .zshrc with content before and after the marker block
  printf '%s\n' \
    '# pre-existing' \
    '# >>> forge rtk path >>>' \
    'case ":$PATH:" in *":$HOME/.forge/bin:"*) ;; *) export PATH="$HOME/.forge/bin:$PATH" ;; esac' \
    '# <<< forge rtk path <<<' \
    '# post-existing' \
    > "$tmpdir/.zshrc"

  mkdir -p "$tmpdir/.forge/bin"
  printf '#!/bin/sh\necho fake-rtk\n' > "$tmpdir/.forge/bin/rtk"
  chmod +x "$tmpdir/.forge/bin/rtk"
  printf '{"rtk":{"installed_by_us":true,"detected_version":"0.43.0","pinned_version":"0.43.0","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "TC1: exits 0 after removing marker block" "$exit_code"

  if grep -qF "# >>> forge rtk path >>>" "$tmpdir/.zshrc" 2>/dev/null; then
    fail "TC1: forge marker should be absent after uninstall"
  else
    pass "TC1: forge marker is absent after uninstall"
  fi

  assert_true "TC1: '# pre-existing' preserved" grep -qF '# pre-existing' "$tmpdir/.zshrc"
  assert_true "TC1: '# post-existing' preserved" grep -qF '# post-existing' "$tmpdir/.zshrc"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# TC2 — Profiles without marker are untouched
# ---------------------------------------------------------------------------
test_tc2_profile_without_marker_untouched() {
  echo ""
  echo "--- TC2: profile without marker is untouched"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  printf '%s\n' '# unrelated content only' > "$tmpdir/.bashrc"
  local content_before
  content_before="$(cat "$tmpdir/.bashrc")"

  # State: installed_by_us=true so uninstall proceeds to marker loop
  mkdir -p "$tmpdir/.forge/bin"
  printf '#!/bin/sh\necho fake-rtk\n' > "$tmpdir/.forge/bin/rtk"
  chmod +x "$tmpdir/.forge/bin/rtk"
  printf '{"rtk":{"installed_by_us":true,"detected_version":"0.43.0","pinned_version":"0.43.0","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "TC2: exits 0" "$exit_code"

  local content_after
  content_after="$(cat "$tmpdir/.bashrc")"
  if [ "$content_before" = "$content_after" ]; then
    pass "TC2: .bashrc content unchanged (no marker to remove)"
  else
    fail "TC2: .bashrc content changed unexpectedly"
  fi

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# TC3 — Idempotent: running uninstall twice leaves the same result
# ---------------------------------------------------------------------------
test_tc3_uninstall_idempotent() {
  echo ""
  echo "--- TC3: uninstall is idempotent (second run leaves same result)"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Set up .zshrc with marker block
  printf '%s\n' \
    '# >>> forge rtk path >>>' \
    'case ":$PATH:" in *":$HOME/.forge/bin:"*) ;; *) export PATH="$HOME/.forge/bin:$PATH" ;; esac' \
    '# <<< forge rtk path <<<' \
    > "$tmpdir/.zshrc"

  mkdir -p "$tmpdir/.forge/bin"
  printf '#!/bin/sh\necho fake-rtk\n' > "$tmpdir/.forge/bin/rtk"
  chmod +x "$tmpdir/.forge/bin/rtk"
  printf '{"rtk":{"installed_by_us":true,"detected_version":"0.43.0","pinned_version":"0.43.0","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  # First run
  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?
  assert_exit_zero "TC3: first uninstall exits 0" "$exit_code"

  if grep -qF "# >>> forge rtk path >>>" "$tmpdir/.zshrc" 2>/dev/null; then
    fail "TC3: forge marker should be absent after first uninstall"
  else
    pass "TC3: forge marker absent after first uninstall"
  fi

  local content_after_first
  content_after_first="$(cat "$tmpdir/.zshrc")"

  # Update state to installed_by_us=true again so the second run also enters the marker loop
  printf '{"rtk":{"installed_by_us":true,"detected_version":null,"pinned_version":"0.43.0","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  # Second run
  exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?
  assert_exit_zero "TC3: second uninstall exits 0" "$exit_code"

  local content_after_second
  content_after_second="$(cat "$tmpdir/.zshrc")"

  if [ "$content_after_first" = "$content_after_second" ]; then
    pass "TC3: .zshrc unchanged between first and second uninstall (idempotent)"
  else
    fail "TC3: .zshrc changed on second uninstall (expected idempotent)"
  fi

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# TC4 — New forge marker: uninstall removes the new >>> forge rtk path >>> block
# ---------------------------------------------------------------------------
test_tc4_new_forge_marker_removed() {
  echo ""
  echo "--- TC4: new forge marker block removed"
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT

  # Create .zshrc with the new forge marker block
  printf '%s\n' \
    '# pre-existing' \
    '# >>> forge rtk path >>>' \
    'case ":$PATH:" in *":$HOME/.forge/bin:"*) ;; *) export PATH="$HOME/.forge/bin:$PATH" ;; esac' \
    '# <<< forge rtk path <<<' \
    '# post-existing' \
    > "$tmpdir/.zshrc"

  mkdir -p "$tmpdir/.forge/bin"
  printf '#!/bin/sh\necho fake-rtk\n' > "$tmpdir/.forge/bin/rtk"
  chmod +x "$tmpdir/.forge/bin/rtk"
  printf '{"rtk":{"installed_by_us":true,"detected_version":"0.43.0","pinned_version":"0.43.0","install_failed":false,"version_mismatch":false}}' \
    > "$tmpdir/.forge-state.json"

  local exit_code=0
  HOME="$tmpdir" bash "$UNINSTALL_SH" >/dev/null 2>&1 || exit_code=$?

  assert_exit_zero "TC4: exits 0 after removing forge marker block" "$exit_code"

  if grep -qF "# >>> forge rtk path >>>" "$tmpdir/.zshrc" 2>/dev/null; then
    fail "TC4: new forge marker should be absent after uninstall"
  else
    pass "TC4: new forge marker is absent after uninstall"
  fi

  assert_true "TC4: '# pre-existing' preserved" grep -qF '# pre-existing' "$tmpdir/.zshrc"
  assert_true "TC4: '# post-existing' preserved" grep -qF '# post-existing' "$tmpdir/.zshrc"

  trap - EXIT
  rm -rf "$tmpdir"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
echo "======================================"
echo " rtk_uninstall_unit.sh (unit)"
echo "======================================"

test_t1_state_file_absent
test_t2_installed_by_us_false
test_t3_rtk_present_installed_by_us_true
test_t4_rtk_absent_installed_by_us_true
test_t5_rtk_present_installed_by_us_false
test_t6_invalid_json_state
test_tc1_marker_block_removed_preserves_context
test_tc2_profile_without_marker_untouched
test_tc3_uninstall_idempotent
test_tc4_new_forge_marker_removed

echo ""
echo "======================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
