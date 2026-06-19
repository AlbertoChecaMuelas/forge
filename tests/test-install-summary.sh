#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/test-install-summary.sh — Unit tests for the summary accumulator block in install.sh
# Compatible with bash 3.2+.
set -euo pipefail

ARSENAL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
TESTS_RUN=0
TESTS_PASSED=0

# Temporary files cleaned up on exit
TMPFILE_LIST=""
trap '_cleanup_all' EXIT

_cleanup_all() {
  for f in $TMPFILE_LIST; do
    rm -f "$f" 2>/dev/null || true
  done
}

_make_tmpfile() {
  local f
  f="$(mktemp)"
  TMPFILE_LIST="$TMPFILE_LIST $f"
  echo "$f"
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

# assert_contains <needle> <haystack> <message>
assert_contains() {
  local needle="$1"
  local haystack="$2"
  local msg="$3"
  if ! printf '%s\n' "$haystack" | grep -qF "$needle"; then
    echo "  FAIL: $msg" >&2
    echo "    expected to contain: '$needle'" >&2
    echo "    actual output: '$haystack'" >&2
    FAIL=1
    return 1
  fi
  return 0
}

# assert_empty <actual> <message>
assert_empty() {
  local actual="$1"
  local msg="$2"
  if [ -n "$actual" ]; then
    echo "  FAIL: $msg" >&2
    echo "    expected empty, got: '$actual'" >&2
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
# Helper: extract and source the summary accumulator block from install.sh
# into a subshell script. Returns path to a temp script that sources it.
# We write inline scripts and run them in fresh bash invocations to avoid
# contaminating the test process state.
# ---------------------------------------------------------------------------

# _source_block_script <extra_code>
# Writes a temp script that:
#   1. Extracts summary accumulator block from install.sh into another temp file
#   2. Sources it
#   3. Runs <extra_code>
# Prints the output of the script.
_run_summary_script() {
  local extra_code="$1"

  local script
  script="$(mktemp /tmp/summary_test_XXXXXX)"
  TMPFILE_LIST="$TMPFILE_LIST $script"

  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
ARSENAL_ROOT="$ARSENAL_ROOT"
# Extract only the summary accumulator block
_blk="\$(mktemp)"
sed -n '/^# --- summary accumulator ---/,/^# --- end summary accumulator ---/p' \
  "\$ARSENAL_ROOT/install.sh" > "\$_blk"
# shellcheck disable=SC1090
. "\$_blk"
rm -f "\$_blk"
# Extra test code
$extra_code
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script" 2>&1)" || true
  echo "$output"
}

# ---------------------------------------------------------------------------
# Case A — API básica: funciones y contadores
# ---------------------------------------------------------------------------
test_case_a_api_basics() {
  # shellcheck disable=SC2016  # single-quoted code fragment injected into subprocess; variables expand in child shell
  local extra_code='
# Call forge_warn once
forge_warn "test msg" "hint text" 2>/dev/null
echo "WARN_COUNT=$_ARSENAL_WARN_COUNT"

# Call forge_err once
forge_err "err msg" 2>/dev/null
echo "ERR_COUNT=$_ARSENAL_ERR_COUNT"

# Reset and verify
_forge_reset_summary
echo "WARN_AFTER_RESET=$_ARSENAL_WARN_COUNT"
echo "ERR_AFTER_RESET=$_ARSENAL_ERR_COUNT"
'
  local output
  output="$(_run_summary_script "$extra_code")"

  local warn_count err_count warn_after err_after
  warn_count="$(printf '%s\n' "$output" | grep '^WARN_COUNT=' | cut -d= -f2)"
  err_count="$(printf '%s\n' "$output" | grep '^ERR_COUNT=' | cut -d= -f2)"
  warn_after="$(printf '%s\n' "$output" | grep '^WARN_AFTER_RESET=' | cut -d= -f2)"
  err_after="$(printf '%s\n' "$output" | grep '^ERR_AFTER_RESET=' | cut -d= -f2)"

  assert_eq "1" "$warn_count" "Case A: _ARSENAL_WARN_COUNT should be 1 after forge_warn" || return 1
  assert_eq "1" "$err_count" "Case A: _ARSENAL_ERR_COUNT should be 1 after forge_err" || return 1
  assert_eq "0" "$warn_after" "Case A: _ARSENAL_WARN_COUNT should be 0 after reset" || return 1
  assert_eq "0" "$err_after" "Case A: _ARSENAL_ERR_COUNT should be 0 after reset" || return 1
}

# ---------------------------------------------------------------------------
# Case B — RTK ausente: state file con install_failed=true
# ---------------------------------------------------------------------------
test_case_b_rtk_absent() {
  local state_file
  state_file="$(_make_tmpfile)"
  printf '%s\n' '{"rtk":{"install_failed":true,"version_mismatch":false,"detected_version":null,"pinned_version":"0.37.2"},"targets_manifest":[{"name":"claude","dir":"/tmp","components":["rtk-hook"]}]}' \
    > "$state_file"

  local extra_code
  extra_code="
ARSENAL_STATE_FILE=\"$state_file\"
# Inject a mock forge_rtk_detect that returns 'absent' (RTK not installed)
forge_rtk_detect() { echo 'absent'; }
output=\"\$(_forge_summarize_rtk 2>/dev/null)\"
printf '%s\n' \"\$output\"
"
  local output
  output="$(_run_summary_script "$extra_code")"

  assert_contains "bash install.sh rtk install" "$output" \
    "Case B: output should contain bash install.sh rtk install command" || return 1
}

# ---------------------------------------------------------------------------
# Case C — RTK version_mismatch
# ---------------------------------------------------------------------------
test_case_c_rtk_version_mismatch() {
  local state_file
  state_file="$(_make_tmpfile)"
  printf '%s\n' '{"rtk":{"install_failed":false,"version_mismatch":true,"detected_version":"0.42.0","pinned_version":"0.42.4"},"targets_manifest":[{"name":"claude","dir":"/tmp","components":["rtk-hook"]}]}' \
    > "$state_file"

  local extra_code
  extra_code="
ARSENAL_STATE_FILE=\"$state_file\"
# Inject a mock forge_rtk_detect that returns the stale detected version
forge_rtk_detect() { echo '0.42.0'; }
output=\"\$(_forge_summarize_rtk 2>/dev/null)\"
printf '%s\n' \"\$output\"
"
  local output
  output="$(_run_summary_script "$extra_code")"

  assert_contains "0.42.0" "$output" \
    "Case C: output should contain detected version 0.42.0" || return 1
  assert_contains "0.42.4" "$output" \
    "Case C: output should contain pinned version 0.42.4" || return 1
}

# ---------------------------------------------------------------------------
# Case D — RTK OK: sin mismatch ni fallo → silencio
# ---------------------------------------------------------------------------
test_case_d_rtk_ok_silent() {
  local state_file
  state_file="$(_make_tmpfile)"
  printf '%s\n' '{"rtk":{"install_failed":false,"version_mismatch":false,"detected_version":"0.42.4","pinned_version":"0.42.4"},"targets_manifest":[{"name":"claude","dir":"/tmp","components":["rtk-hook"]}]}' \
    > "$state_file"

  local extra_code
  extra_code="
ARSENAL_STATE_FILE=\"$state_file\"
# Inject a mock forge_rtk_detect that returns the pinned version (OK scenario)
forge_rtk_detect() { echo '0.42.4'; }
output=\"\$(_forge_summarize_rtk 2>/dev/null)\"
printf '%s' \"\$output\"
"
  local output
  output="$(_run_summary_script "$extra_code")"

  assert_empty "$output" "Case D: _forge_summarize_rtk should produce no output when RTK is OK" || return 1
}

# ---------------------------------------------------------------------------
# Case E — print_summary Todo OK cuando no hay warnings ni errores
# ---------------------------------------------------------------------------
test_case_e_print_summary_todo_ok() {
  local state_file
  state_file="$(_make_tmpfile)"
  printf '%s\n' '{"rtk":{"install_failed":false,"version_mismatch":false,"detected_version":"0.42.4","pinned_version":"0.42.4"},"targets_manifest":[{"name":"claude","dir":"/tmp","components":["rtk-hook"]}]}' \
    > "$state_file"

  local extra_code
  extra_code="
ARSENAL_STATE_FILE=\"$state_file\"
# Inject a mock forge_rtk_detect that returns the pinned version (OK scenario)
forge_rtk_detect() { echo '0.42.4'; }
_ARSENAL_WARN_COUNT=0
_ARSENAL_ERR_COUNT=0
forge_print_summary \"test\" 2>/dev/null
"
  local output
  output="$(_run_summary_script "$extra_code")"

  assert_contains "Todo OK" "$output" \
    "Case E: forge_print_summary should print 'Todo OK' when no errors or warnings" || return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== test-install-summary.sh ==="
echo ""

run_test "Case A: API básica (funciones y contadores)" test_case_a_api_basics
run_test "Case B: RTK ausente (install_failed=true)"  test_case_b_rtk_absent
run_test "Case C: RTK version_mismatch"               test_case_c_rtk_version_mismatch
run_test "Case D: RTK OK (silencio)"                  test_case_d_rtk_ok_silent
run_test "Case E: print_summary Todo OK"              test_case_e_print_summary_todo_ok

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "ALL PASS"
  exit 0
fi
