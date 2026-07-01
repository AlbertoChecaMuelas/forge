#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/rtk_unit.sh — Unit tests for lib/rtk.sh
# Compatible with bash 3.2+. Uses shims in PATH for rtk, brew, etc.
# Log prefix: [rtk]
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

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

# assert_ne <not_expected> <actual> <message>
assert_ne() {
  local not_expected="$1"
  local actual="$2"
  local msg="$3"
  if [ "$not_expected" = "$actual" ]; then
    echo "  FAIL: $msg (expected NOT '$not_expected', but got it)" >&2
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
# Helper: load rtk.sh into a fresh subshell environment with a given PATH.
# We source rtk.sh in a script fragment that also sets FORGE_ROOT.
# Since we need to test functions that modify global vars, we run them in
# the same shell process (not a subshell) using a temp script + eval trick.
#
# Strategy: each test sources rtk.sh with a controlled PATH, optionally
# overrides forge_rtk_adjust_via_tarball, then calls forge_rtk_decide.
# We use a wrapper script pattern: write a mini-script and run it in a
# controlled env, capturing stdout/stderr and exit code. For state vars,
# we print them from within the script and parse the output.
# ---------------------------------------------------------------------------

# _run_decide_script <tmpdir_bin_path> <env_overrides> <extra_bash_code>
# Runs forge_rtk_decide in a fresh bash invocation with shims in PATH.
# The script prints state vars at the end as KEY=VALUE lines.
# Returns the output via stdout.
_run_decide_script() {
  local bin_dir="$1"     # directory with shims (added to front of PATH)
  local extra_code="$2"  # bash code inserted BEFORE forge_rtk_decide (for overrides)
  local env_vars="$3"    # additional env vars as "VAR=val VAR2=val2" space-separated

  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# Use restricted PATH: only bin_dir + minimal system dirs.
# This prevents the real rtk at /opt/homebrew/bin from leaking into tests.
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
# Load rtk.sh
source "$FORGE_ROOT/lib/rtk.sh"
# Extra code (overrides, etc.)
$extra_code
# Run decide
forge_rtk_decide 2>/dev/null || true
# Print state vars
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
echo "_RTK_DETECTED_VERSION=\${_RTK_DETECTED_VERSION:-}"
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
echo "_RTK_VERSION_MISMATCH=\${_RTK_VERSION_MISMATCH:-}"
EOF
  chmod +x "$script"

  local env_cmd=""
  if [ -n "$env_vars" ]; then
    env_cmd="env $env_vars"
  fi

  local output
  if [ -n "$env_cmd" ]; then
    output="$($env_cmd bash "$script")" || true
  else
    output="$(bash "$script")" || true
  fi

  rm -f "$script"
  echo "$output"
}

# Parse a specific var from decide output
_get_var() {
  local output="$1"
  local varname="$2"
  printf '%s\n' "$output" | grep "^${varname}=" | head -1 | cut -d= -f2-
}

# ---------------------------------------------------------------------------
# Test 1: forge_rtk_detect when rtk is absent
# ---------------------------------------------------------------------------
test_detect_absent() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"
  # Restricted PATH — no homebrew, no rtk shim → command -v rtk should fail

  local result
  result="$(HOME="$tmpdir" PATH="$bin_dir:/usr/bin:/bin" bash -c "
    export FORGE_ROOT=\"$FORGE_ROOT\"
    source \"$FORGE_ROOT/lib/rtk.sh\"
    forge_rtk_detect
  ")"

  assert_eq "absent" "$result" "detect absent: should print 'absent'"
}

# ---------------------------------------------------------------------------
# Test 2: detect eq — stub rtk that prints "rtk 0.37.2"
# ---------------------------------------------------------------------------
test_detect_eq() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  # Create rtk shim
  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.37.2"
SHIM
  chmod +x "$bin_dir/rtk"

  local det_result
  det_result="$(PATH="$bin_dir:/usr/bin:/bin" bash -c "
    export FORGE_ROOT=\"$FORGE_ROOT\"
    source \"$FORGE_ROOT/lib/rtk.sh\"
    forge_rtk_detect
  ")"
  assert_eq "0.37.2" "$det_result" "detect eq: should return version 0.37.2" || return 1

  local cmp_result
  cmp_result="$(PATH="$bin_dir:/usr/bin:/bin" bash -c "
    export FORGE_ROOT=\"$FORGE_ROOT\"
    source \"$FORGE_ROOT/lib/rtk.sh\"
    forge_rtk_compare '0.37.2' '0.37.2'
  ")"
  assert_eq "eq" "$cmp_result" "compare eq: 0.37.2 vs 0.37.2 should be eq"
}

# ---------------------------------------------------------------------------
# Test 3: detect lt — stub rtk 0.36.0
# ---------------------------------------------------------------------------
test_detect_lt() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.36.0"
SHIM
  chmod +x "$bin_dir/rtk"

  local cmp_result
  cmp_result="$(PATH="$bin_dir:/usr/bin:/bin" bash -c "
    export FORGE_ROOT=\"$FORGE_ROOT\"
    source \"$FORGE_ROOT/lib/rtk.sh\"
    forge_rtk_compare '0.36.0' '0.37.2'
  ")"
  assert_eq "lt" "$cmp_result" "compare lt: 0.36.0 vs 0.37.2 should be lt"
}

# ---------------------------------------------------------------------------
# Test 4: detect gt — stub rtk 0.38.0
# ---------------------------------------------------------------------------
test_detect_gt() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.38.0"
SHIM
  chmod +x "$bin_dir/rtk"

  local cmp_result
  cmp_result="$(PATH="$bin_dir:/usr/bin:/bin" bash -c "
    export FORGE_ROOT=\"$FORGE_ROOT\"
    source \"$FORGE_ROOT/lib/rtk.sh\"
    forge_rtk_compare '0.38.0' '0.37.2'
  ")"
  assert_eq "gt" "$cmp_result" "compare gt: 0.38.0 vs 0.37.2 should be gt"
}

# ---------------------------------------------------------------------------
# Test 5: detect collision — stub rtk that prints "Rust Type Kit v1.2.3"
# ---------------------------------------------------------------------------
test_detect_collision() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "Rust Type Kit v1.2.3"
SHIM
  chmod +x "$bin_dir/rtk"

  local result
  result="$(PATH="$bin_dir:/usr/bin:/bin" bash -c "
    export FORGE_ROOT=\"$FORGE_ROOT\"
    source \"$FORGE_ROOT/lib/rtk.sh\"
    forge_rtk_detect
  ")"
  assert_eq "collision" "$result" "detect collision: non-rtk binary should produce 'collision'"
}

# ---------------------------------------------------------------------------
# Test 6: decide absent, no-tty → _RTK_VERSION_MISMATCH=1, _RTK_INSTALL_FAILED empty.
# The absent branch now calls _forge_rtk_prompt_adjust, which sets
# _RTK_VERSION_MISMATCH=1 in a no-tty environment (stdin from command substitution).
# OLD assertion: _RTK_INSTALL_FAILED=1 (removed — absent no longer sets this directly).
# NEW assertion: _RTK_VERSION_MISMATCH=1, _RTK_INSTALL_FAILED empty.
# ---------------------------------------------------------------------------
test_decide_absent_invokes_install() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"
  # No rtk shim → absent; _run_decide_script runs via command substitution (no-tty)
  # Override HOME so that forge_rtk_detect's on-disk fallback (~/.forge/bin/rtk)
  # does not find a real binary already installed in the system HOME.

  local output
  output="$(_run_decide_script "$bin_dir" "" "HOME=$tmpdir")"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "1" "$mismatch" "decide absent no-tty: _RTK_VERSION_MISMATCH should be 1" || return 1

  local install_failed
  install_failed="$(_get_var "$output" "_RTK_INSTALL_FAILED")"
  assert_eq "" "$install_failed" "decide absent no-tty: _RTK_INSTALL_FAILED should be empty" || return 1

  local installed
  installed="$(_get_var "$output" "_RTK_INSTALLED_BY_US")"
  assert_eq "" "$installed" "decide absent no-tty: _RTK_INSTALLED_BY_US should be empty (no install)"
}

# ---------------------------------------------------------------------------
# Test 7: decide gt, no tty → _RTK_VERSION_MISMATCH=1, no prompt
# rtk shim returns 0.38.0; stdin redirected from /dev/null (non-tty).
# RTK_FORCE_TTY must NOT be set.
# ---------------------------------------------------------------------------
test_decide_gt_no_tty_sets_mismatch() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.38.0"
SHIM
  chmod +x "$bin_dir/rtk"

  # Run with stdin from /dev/null to simulate non-tty and without RTK_FORCE_TTY
  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
unset RTK_FORCE_TTY 2>/dev/null || true
source "$FORGE_ROOT/lib/rtk.sh"
forge_rtk_decide 2>/dev/null || true
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
echo "_RTK_DETECTED_VERSION=\${_RTK_DETECTED_VERSION:-}"
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
echo "_RTK_VERSION_MISMATCH=\${_RTK_VERSION_MISMATCH:-}"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script" < /dev/null)" || true
  rm -f "$script"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "1" "$mismatch" "decide gt no-tty: _RTK_VERSION_MISMATCH should be 1"

  local install_failed
  install_failed="$(_get_var "$output" "_RTK_INSTALL_FAILED")"
  assert_eq "" "$install_failed" "decide gt no-tty: _RTK_INSTALL_FAILED should be empty"
}

# ---------------------------------------------------------------------------
# Test 8: decide gt, tty forced, answer "y" → invokes adjust stub
# Use RTK_FORCE_TTY=1 and pipe "y" as stdin.
# Override forge_rtk_adjust_via_tarball to succeed.
# ---------------------------------------------------------------------------
test_decide_gt_tty_yes_downgrades() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.38.0"
SHIM
  chmod +x "$bin_dir/rtk"

  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
export RTK_FORCE_TTY=1
source "$FORGE_ROOT/lib/rtk.sh"
# Override adjust to succeed without running brew
forge_rtk_adjust_via_tarball() {
  echo "[rtk-stub] adjust_via_tarball called (stub success)"
  return 0
}
forge_rtk_decide 2>/dev/null || true
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
echo "_RTK_DETECTED_VERSION=\${_RTK_DETECTED_VERSION:-}"
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
echo "_RTK_VERSION_MISMATCH=\${_RTK_VERSION_MISMATCH:-}"
SCRIPTEOF
  chmod +x "$script"

  # Pipe "y" as stdin for the read prompt
  local output
  output="$(echo 'y' | bash "$script")" || true
  rm -f "$script"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "" "$mismatch" "decide gt tty yes: _RTK_VERSION_MISMATCH should be empty (downgrade accepted)"

  # After downgrade, detected version should be pinned
  local det_ver
  det_ver="$(_get_var "$output" "_RTK_DETECTED_VERSION")"
  local pinned
  pinned="$(cat "$FORGE_ROOT/rtk/VERSION")"
  assert_eq "$pinned" "$det_ver" "decide gt tty yes: _RTK_DETECTED_VERSION should be pinned after downgrade"
}

# ---------------------------------------------------------------------------
# Test 9: decide collision → install_failed=1, return 0 (no exit)
# ---------------------------------------------------------------------------
test_decide_collision_aborts_rtk_continues_install() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "Rust Type Kit v1.2.3"
SHIM
  chmod +x "$bin_dir/rtk"

  local output
  output="$(_run_decide_script "$bin_dir" "" "")"

  local install_failed
  install_failed="$(_get_var "$output" "_RTK_INSTALL_FAILED")"
  assert_eq "1" "$install_failed" "decide collision: _RTK_INSTALL_FAILED should be 1" || return 1

  # Verify the script itself returned 0 (no exit call from decide)
  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
source "$FORGE_ROOT/lib/rtk.sh"
forge_rtk_decide 2>/dev/null
echo "AFTER_DECIDE_OK"
SCRIPTEOF
  chmod +x "$script"

  local after_output
  after_output="$(bash "$script")" || true
  rm -f "$script"

  if printf '%s\n' "$after_output" | grep -q "AFTER_DECIDE_OK"; then
    : # good
  else
    assert_eq "AFTER_DECIDE_OK present" "not found" "decide collision: execution should continue after decide"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 10: decide absent, no-tty → _RTK_VERSION_MISMATCH=1, execution continues (return 0).
# The absent branch calls _forge_rtk_prompt_adjust, which sets _RTK_VERSION_MISMATCH=1
# in a no-tty context. decide always returns 0 (soft failure contract).
# OLD assertion: _RTK_INSTALL_FAILED=1 (removed — absent no longer sets this directly).
# NEW assertion: _RTK_VERSION_MISMATCH=1, _RTK_INSTALLED_BY_US empty, execution continues.
# ---------------------------------------------------------------------------
test_decide_install_failure_marked() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"
  # No rtk shim → absent; no-tty → _RTK_VERSION_MISMATCH=1
  # Override HOME so that forge_rtk_detect's on-disk fallback (~/.forge/bin/rtk)
  # does not find a real binary already installed in the system HOME.

  local output
  output="$(_run_decide_script "$bin_dir" "" "HOME=$tmpdir")"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "1" "$mismatch" "decide install failure: _RTK_VERSION_MISMATCH should be 1" || return 1

  local install_failed
  install_failed="$(_get_var "$output" "_RTK_INSTALL_FAILED")"
  assert_eq "" "$install_failed" "decide install failure: _RTK_INSTALL_FAILED should be empty" || return 1

  local installed_by_us
  installed_by_us="$(_get_var "$output" "_RTK_INSTALLED_BY_US")"
  assert_eq "" "$installed_by_us" "decide install failure: _RTK_INSTALLED_BY_US should be empty" || return 1

  # Verify execution continues after decide (return 0 contract)
  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
source "$FORGE_ROOT/lib/rtk.sh"
forge_rtk_decide 2>/dev/null
echo "AFTER_DECIDE_OK"
SCRIPTEOF
  chmod +x "$script"

  local after_output
  after_output="$(bash "$script")" || true
  rm -f "$script"

  if printf '%s\n' "$after_output" | grep -q "AFTER_DECIDE_OK"; then
    : # good
  else
    assert_eq "AFTER_DECIDE_OK present" "not found" "decide install failure: execution should continue after decide"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test 11: decide gt, FORGE_RTK_ADJUST=yes → downgrade called, mismatch empty
# ---------------------------------------------------------------------------
test_decide_gt_env_yes_downgrades() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.38.0"
SHIM
  chmod +x "$bin_dir/rtk"

  local pinned
  pinned="$(cat "$FORGE_ROOT/rtk/VERSION")"

  local extra_code
  # shellcheck disable=SC2016  # single-quoted code fragment injected into subprocess; no expansion intended here
  extra_code='
# Override adjust to succeed and set the detected version to pinned
forge_rtk_adjust_via_tarball() {
  local p
  p="$(cat "$FORGE_ROOT/rtk/VERSION")"
  _RTK_DETECTED_VERSION="$p"
  return 0
}
'

  local output
  output="$(_run_decide_script "$bin_dir" "$extra_code" "FORGE_RTK_ADJUST=yes")"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "" "$mismatch" "decide gt env yes: _RTK_VERSION_MISMATCH should be empty" || return 1

  local det_ver
  det_ver="$(_get_var "$output" "_RTK_DETECTED_VERSION")"
  assert_eq "$pinned" "$det_ver" "decide gt env yes: _RTK_DETECTED_VERSION should equal pinned version"
}

# ---------------------------------------------------------------------------
# Test 12: decide gt, FORGE_RTK_ADJUST=no → mismatch=1, downgrade NOT called
# ---------------------------------------------------------------------------
test_decide_gt_env_no_skips() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.38.0"
SHIM
  chmod +x "$bin_dir/rtk"

  local sentinel_file="$tmpdir/downgrade_called_sentinel"

  local extra_code
  extra_code="
# Override adjust to touch a sentinel file
forge_rtk_adjust_via_tarball() {
  touch \"$sentinel_file\"
  return 0
}
"

  local output
  output="$(_run_decide_script "$bin_dir" "$extra_code" "FORGE_RTK_ADJUST=no")"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "1" "$mismatch" "decide gt env no: _RTK_VERSION_MISMATCH should be 1" || return 1

  if [ -f "$sentinel_file" ]; then
    assert_eq "sentinel_absent" "sentinel_present" "decide gt env no: downgrade should NOT have been called"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Test 13: decide gt, FORGE_RTK_ADJUST=maybe → falls back to no-tty → mismatch=1
# ---------------------------------------------------------------------------
test_decide_gt_env_invalid_falls_back() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.38.0"
SHIM
  chmod +x "$bin_dir/rtk"

  # Run with stdin from /dev/null (no tty) and invalid env var
  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
export FORGE_RTK_ADJUST=maybe
unset RTK_FORCE_TTY 2>/dev/null || true
source "$FORGE_ROOT/lib/rtk.sh"
forge_rtk_decide 2>/dev/null || true
echo "_RTK_VERSION_MISMATCH=\${_RTK_VERSION_MISMATCH:-}"
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script" < /dev/null)" || true
  rm -f "$script"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "1" "$mismatch" "decide gt env invalid: fallback no-tty should set _RTK_VERSION_MISMATCH=1"
}

# ---------------------------------------------------------------------------
# Test 13b: decide gt, FORGE_RTK_DOWNGRADE=yes (deprecated alias)
#           → downgrade called, mismatch empty, deprecation warning emitted
# ---------------------------------------------------------------------------
test_decide_gt_env_legacy_alias_works() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.38.0"
SHIM
  chmod +x "$bin_dir/rtk"

  local pinned
  pinned="$(cat "$FORGE_ROOT/rtk/VERSION")"

  # shellcheck disable=SC2016
  local extra_code='
forge_rtk_adjust_via_tarball() {
  local p
  p="$(cat "$FORGE_ROOT/rtk/VERSION")"
  _RTK_DETECTED_VERSION="$p"
  return 0
}
'

  local output
  output="$(_run_decide_script "$bin_dir" "$extra_code" "FORGE_RTK_DOWNGRADE=yes")"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "" "$mismatch" "decide gt legacy alias: _RTK_VERSION_MISMATCH should be empty" || return 1

  local det_ver
  det_ver="$(_get_var "$output" "_RTK_DETECTED_VERSION")"
  assert_eq "$pinned" "$det_ver" "decide gt legacy alias: _RTK_DETECTED_VERSION should equal pinned" || return 1

  return 0
}

# ---------------------------------------------------------------------------
# Test 14: decide lt, no tty — installed version 0.36.0 < pinned → _RTK_VERSION_MISMATCH=1
# The lt branch is now symmetric with gt: calls _forge_rtk_prompt_adjust,
# which sets _RTK_VERSION_MISMATCH=1 when there is no tty and no env var.
# Both FORGE_RTK_ADJUST and FORGE_RTK_DOWNGRADE are unset.
# ---------------------------------------------------------------------------
test_decide_lt_no_tty_sets_mismatch() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/rtk" <<'SHIM'
#!/bin/sh
echo "rtk 0.36.0"
SHIM
  chmod +x "$bin_dir/rtk"

  # Run with stdin from /dev/null (no tty) and no FORGE_RTK_ADJUST / FORGE_RTK_DOWNGRADE env var
  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
unset RTK_FORCE_TTY 2>/dev/null || true
unset FORGE_RTK_ADJUST 2>/dev/null || true
unset FORGE_RTK_DOWNGRADE 2>/dev/null || true
source "$FORGE_ROOT/lib/rtk.sh"
forge_rtk_decide 2>/dev/null || true
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
echo "_RTK_VERSION_MISMATCH=\${_RTK_VERSION_MISMATCH:-}"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script" < /dev/null)" || true
  rm -f "$script"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "1" "$mismatch" "decide lt no-tty: _RTK_VERSION_MISMATCH should be 1" || return 1

  local install_failed
  install_failed="$(_get_var "$output" "_RTK_INSTALL_FAILED")"
  assert_eq "" "$install_failed" "decide lt no-tty: _RTK_INSTALL_FAILED should be empty" || return 1

  local installed
  installed="$(_get_var "$output" "_RTK_INSTALLED_BY_US")"
  assert_eq "" "$installed" "decide lt no-tty: _RTK_INSTALLED_BY_US should be empty"
}

# ---------------------------------------------------------------------------
# Test 15: decide eq — installed version equals pinned → no-op
# ---------------------------------------------------------------------------
test_decide_eq_noop() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  local pinned
  pinned="$(cat "$FORGE_ROOT/rtk/VERSION")"
  printf '#!/bin/sh\necho "rtk %s"\n' "$pinned" > "$bin_dir/rtk"
  chmod +x "$bin_dir/rtk"

  local output
  output="$(_run_decide_script "$bin_dir" "" "")"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "" "$mismatch" "decide eq: _RTK_VERSION_MISMATCH should be empty" || return 1

  local installed
  installed="$(_get_var "$output" "_RTK_INSTALLED_BY_US")"
  assert_ne "true" "$installed" "decide eq: _RTK_INSTALLED_BY_US should not be 'true' (no install triggered)"
}

# ---------------------------------------------------------------------------
# Test B1: decide absent, no-tty → _RTK_VERSION_MISMATCH=1, _RTK_INSTALL_FAILED empty,
#          execution continues after decide.
# No rtk shim (absent from PATH), no FORGE_RTK_ADJUST, stdin from /dev/null (no-tty).
# ---------------------------------------------------------------------------
test_decide_absent_no_tty_mismatch() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"
  # No rtk shim → absent

  local script
  script="$(mktemp /tmp/rtk_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$FORGE_ROOT"
# Override HOME so that forge_rtk_detect's on-disk fallback (~/.forge/bin/rtk)
# does not find a real binary already installed in the system HOME.
export HOME="$tmpdir"
unset FORGE_RTK_ADJUST 2>/dev/null || true
unset RTK_FORCE_TTY 2>/dev/null || true
source "$FORGE_ROOT/lib/rtk.sh"
forge_rtk_decide 2>/dev/null || true
echo "_RTK_VERSION_MISMATCH=\${_RTK_VERSION_MISMATCH:-}"
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
echo "AFTER_DECIDE_OK"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script" < /dev/null)" || true
  rm -f "$script"

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "1" "$mismatch" "decide absent no-tty (B1): _RTK_VERSION_MISMATCH should be 1" || return 1

  local install_failed
  install_failed="$(_get_var "$output" "_RTK_INSTALL_FAILED")"
  assert_eq "" "$install_failed" "decide absent no-tty (B1): _RTK_INSTALL_FAILED should be empty" || return 1

  if printf '%s\n' "$output" | grep -q "AFTER_DECIDE_OK"; then
    : # good — execution continued
  else
    assert_eq "AFTER_DECIDE_OK present" "not found" "decide absent no-tty (B1): execution should continue after decide"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Test B2: decide absent, FORGE_RTK_ADJUST=yes → calls adjust stub,
#          sets _RTK_INSTALLED_BY_US="true", _RTK_VERSION_MISMATCH empty.
# ---------------------------------------------------------------------------
test_decide_absent_env_yes_installs() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"
  # No rtk shim → absent

  local pinned
  pinned="$(cat "$FORGE_ROOT/rtk/VERSION")"

  # Override forge_rtk_adjust_via_tarball to succeed and report pinned version
  # shellcheck disable=SC2016
  local extra_code='
forge_rtk_adjust_via_tarball() {
  local p
  p="$(cat "$FORGE_ROOT/rtk/VERSION")"
  _RTK_DETECTED_VERSION="$p"
  return 0
}
'

  local output
  output="$(_run_decide_script "$bin_dir" "$extra_code" "FORGE_RTK_ADJUST=yes")"

  local installed_by_us
  installed_by_us="$(_get_var "$output" "_RTK_INSTALLED_BY_US")"
  assert_eq "true" "$installed_by_us" "decide absent env yes (B2): _RTK_INSTALLED_BY_US should be 'true'" || return 1

  local mismatch
  mismatch="$(_get_var "$output" "_RTK_VERSION_MISMATCH")"
  assert_eq "" "$mismatch" "decide absent env yes (B2): _RTK_VERSION_MISMATCH should be empty" || return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== rtk_unit.sh ==="
echo ""

run_test "test_detect_absent" test_detect_absent
run_test "test_detect_eq" test_detect_eq
run_test "test_detect_lt" test_detect_lt
run_test "test_detect_gt" test_detect_gt
run_test "test_detect_collision" test_detect_collision
run_test "test_decide_absent_invokes_install" test_decide_absent_invokes_install
run_test "test_decide_gt_no_tty_sets_mismatch" test_decide_gt_no_tty_sets_mismatch
run_test "test_decide_gt_tty_yes_downgrades" test_decide_gt_tty_yes_downgrades
run_test "test_decide_collision_aborts_rtk_continues_install" test_decide_collision_aborts_rtk_continues_install
run_test "test_decide_install_failure_marked" test_decide_install_failure_marked
run_test "test_decide_gt_env_yes_downgrades" test_decide_gt_env_yes_downgrades
run_test "test_decide_gt_env_no_skips" test_decide_gt_env_no_skips
run_test "test_decide_gt_env_invalid_falls_back" test_decide_gt_env_invalid_falls_back
run_test "test_decide_gt_env_legacy_alias_works" test_decide_gt_env_legacy_alias_works
run_test "test_decide_lt_no_tty_sets_mismatch" test_decide_lt_no_tty_sets_mismatch
run_test "test_decide_eq_noop" test_decide_eq_noop
run_test "test_decide_absent_no_tty_mismatch" test_decide_absent_no_tty_mismatch
run_test "test_decide_absent_env_yes_installs" test_decide_absent_env_yes_installs

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "ALL PASS"
  exit 0
fi
