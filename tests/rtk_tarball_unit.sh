#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/rtk_tarball_unit.sh — Unit tests for forge_rtk_adjust_via_tarball in lib/rtk.sh
# No network access: curl is stubbed with a local shim.
# Compatible with bash 3.2+.
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

# assert_contains <substring> <string> <message>
assert_contains() {
  local substring="$1"
  local string="$2"
  local msg="$3"
  if ! printf '%s\n' "$string" | grep -qF "$substring"; then
    echo "  FAIL: $msg" >&2
    echo "    expected substring: '$substring'" >&2
    echo "    actual string:      '$string'" >&2
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
# Shared harness helpers
# ---------------------------------------------------------------------------

# _make_controlled_home <FORGE_ROOT_DIR>
# Creates a temp dir for HOME, creates <FORGE_ROOT_DIR>/rtk/VERSION containing
# 0.43.0, and returns the temp HOME path via stdout.
_make_controlled_home() {
  local forge_root_dir="$1"
  local tmphome
  tmphome="$(_make_tmpdir)"
  mkdir -p "$forge_root_dir/rtk"
  printf '%s' "$(cat "$FORGE_ROOT/rtk/VERSION")" > "$forge_root_dir/rtk/VERSION"
  echo "$tmphome"
}

# _make_fake_tarball <DIR>
# Creates a minimal .tar.gz in DIR containing a single executable `rtk` script
# that prints "rtk 0.43.0". Computes the real SHA256 and writes checksums.txt.
# Sets globals: FAKE_ASSET_PATH, FAKE_CHECKSUMS_PATH.
FAKE_ASSET_PATH=""
FAKE_CHECKSUMS_PATH=""
_make_fake_tarball() {
  local dir="$1"
  local build_dir
  build_dir="$(mktemp -d)"
  TMPDIR_LIST="$TMPDIR_LIST $build_dir"

  # Create a minimal rtk binary stub that echoes the real pinned version
  local pinned_version
  pinned_version="$(cat "$FORGE_ROOT/rtk/VERSION")"
  printf '#!/bin/sh\necho "rtk %s"\n' "$pinned_version" > "$build_dir/rtk"
  chmod +x "$build_dir/rtk"

  # Pack it into a tarball
  local asset_name="rtk-aarch64-apple-darwin.tar.gz"
  local asset_path="$dir/$asset_name"
  tar -czf "$asset_path" -C "$build_dir" rtk

  # Compute real SHA256
  local sha256
  if command -v shasum >/dev/null 2>&1; then
    sha256="$(shasum -a 256 "$asset_path" | awk '{print $1}')"
  else
    sha256="$(sha256sum "$asset_path" | awk '{print $1}')"
  fi

  # Write checksums.txt
  local checksums_path="$dir/checksums.txt"
  printf '%s  %s\n' "$sha256" "$asset_name" > "$checksums_path"

  FAKE_ASSET_PATH="$asset_path"
  FAKE_CHECKSUMS_PATH="$checksums_path"
}

# _make_curl_shim <BIN_DIR> <ASSET_PATH> <CHECKSUMS_PATH>
# Writes a curl shim that serves local fake files instead of hitting the network.
# Parses -o <dest> from args; copies ASSET_PATH or CHECKSUMS_PATH based on URL suffix.
# Uses a Python-style printf approach to avoid heredoc variable expansion conflicts.
_make_curl_shim() {
  local bin_dir="$1"
  local asset_path="$2"
  local checksums_path="$3"
  local shim="$bin_dir/curl"

  # Write header with embedded paths (interpolated now), then body (single-quoted)
  printf '#!/bin/sh\n' > "$shim"
  printf '_ASSET_PATH=%s\n' "$asset_path" >> "$shim"
  printf '_CHECKSUMS_PATH=%s\n' "$checksums_path" >> "$shim"
  cat >> "$shim" <<'CURLBODY'
# Parse -o <dest> and URL from args
_dest=""
_url=""
_skip_next=0
for _arg in "$@"; do
  if [ "$_skip_next" = "1" ]; then
    _dest="$_arg"
    _skip_next=0
    continue
  fi
  case "$_arg" in
    -o) _skip_next=1 ;;
    http://*|https://*) _url="$_arg" ;;
  esac
done
if [ -z "$_dest" ]; then
  exit 1
fi
case "$_url" in
  *.tar.gz) cp "$_ASSET_PATH" "$_dest" ;;
  *checksums.txt) cp "$_CHECKSUMS_PATH" "$_dest" ;;
  *) exit 1 ;;
esac
exit 0
CURLBODY
  chmod +x "$shim"
}

# _make_uname_shims <BIN_DIR> <OS> <ARCH>
# Writes a uname shim that responds to -s with OS and -m with ARCH.
_make_uname_shims() {
  local bin_dir="$1"
  local os="$2"
  local arch="$3"
  local shim="$bin_dir/uname"

  printf '#!/bin/sh\n' > "$shim"
  printf '_OS=%s\n' "$os" >> "$shim"
  printf '_ARCH=%s\n' "$arch" >> "$shim"
  cat >> "$shim" <<'UNAMEBODY'
case "$1" in
  -s) echo "$_OS" ;;
  -m) echo "$_ARCH" ;;
  *)  echo "$_OS" ;;
esac
UNAMEBODY
  chmod +x "$shim"
}

# _make_shasum_shim <BIN_DIR>
# Writes a shasum shim that delegates to the real shasum -a 256 or sha256sum.
_make_shasum_shim() {
  local bin_dir="$1"
  local shim="$bin_dir/shasum"

  # Find real shasum or sha256sum outside our shim dir
  local real_shasum
  real_shasum="$(PATH="/usr/bin:/bin:/usr/local/bin" command -v shasum 2>/dev/null || true)"
  local real_sha256sum
  real_sha256sum="$(PATH="/usr/bin:/bin:/usr/local/bin" command -v sha256sum 2>/dev/null || true)"

  printf '#!/bin/sh\n' > "$shim"
  if [ -n "$real_shasum" ]; then
    printf 'exec %s "$@"\n' "$real_shasum" >> "$shim"
  elif [ -n "$real_sha256sum" ]; then
    # sha256sum doesn't support -a flag; strip it and delegate
    printf '# strip -a <algo> flags\n' >> "$shim"
    cat >> "$shim" <<'SHASUMBODY'
_args=""
_skip=0
for _a in "$@"; do
  if [ "$_skip" = "1" ]; then _skip=0; continue; fi
  case "$_a" in
    -a) _skip=1 ;;
    *) _args="$_args $_a" ;;
  esac
done
SHASUMBODY
    printf 'exec %s $_args\n' "$real_sha256sum" >> "$shim"
  else
    printf 'echo "shasum: not available" >&2; exit 1\n' >> "$shim"
  fi
  chmod +x "$shim"
}

# _make_nocurl_bin_dir <BIN_DIR>
# Creates a symlink farm of essential tools that the function under test needs,
# explicitly EXCLUDING curl so that `command -v curl` fails.
# Needed for test 2 where we want curl to be absent.
_make_nocurl_bin_dir() {
  local bin_dir="$1"
  # Tools needed by forge_rtk_adjust_via_tarball (not curl, not uname, not shasum — caller adds those)
  local tools="cat tr grep awk mktemp tar find mkdir mv chmod rm sh bash"
  local tool real
  for tool in $tools; do
    real="$(PATH="/usr/bin:/bin:/usr/local/bin" command -v "$tool" 2>/dev/null || true)"
    if [ -n "$real" ]; then
      ln -sf "$real" "$bin_dir/$tool" 2>/dev/null || true
    fi
  done
}

# ---------------------------------------------------------------------------
# Test 1 — Unsupported platform → soft-fail
# ---------------------------------------------------------------------------
test_tarball_unsupported_platform() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  _make_uname_shims "$bin_dir" "FreeBSD" "x86_64"
  _make_shasum_shim "$bin_dir"

  local script
  script="$(mktemp /tmp/rtk_tarball_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$forge_root_fake"
export HOME="$tmphome"
source "$FORGE_ROOT/lib/rtk.sh"
_RTK_INSTALL_FAILED=""
_RTK_INSTALLED_BY_US=""
forge_rtk_adjust_via_tarball 2>/dev/null || true
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
echo "RTK_BIN_EXISTS=\$([ -x "\$HOME/.forge/bin/rtk" ] && echo yes || echo no)"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script")" || true
  rm -f "$script"

  local install_failed bin_exists
  install_failed="$(printf '%s\n' "$output" | grep '^_RTK_INSTALL_FAILED=' | cut -d= -f2-)"
  bin_exists="$(printf '%s\n' "$output" | grep '^RTK_BIN_EXISTS=' | cut -d= -f2-)"

  assert_eq "1" "$install_failed" "unsupported platform: _RTK_INSTALL_FAILED should be 1" || return 1
  assert_eq "no" "$bin_exists" "unsupported platform: ~/.forge/bin/rtk should not exist" || return 1
}

# ---------------------------------------------------------------------------
# Test 2 — curl missing → soft-fail
# ---------------------------------------------------------------------------
test_tarball_curl_missing() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  # Valid uname shims for Darwin/aarch64 — NO curl shim
  # Build a symlink farm of needed tools excluding curl so command -v curl fails
  _make_nocurl_bin_dir "$bin_dir"
  _make_uname_shims "$bin_dir" "Darwin" "aarch64"
  _make_shasum_shim "$bin_dir"
  # Explicitly ensure no curl in our bin_dir
  rm -f "$bin_dir/curl"

  local script
  script="$(mktemp /tmp/rtk_tarball_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir"
export FORGE_ROOT="$forge_root_fake"
export HOME="$tmphome"
source "$FORGE_ROOT/lib/rtk.sh"
_RTK_INSTALL_FAILED=""
_RTK_INSTALLED_BY_US=""
forge_rtk_adjust_via_tarball 2>/dev/null || true
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script")" || true
  rm -f "$script"

  local install_failed
  install_failed="$(printf '%s\n' "$output" | grep '^_RTK_INSTALL_FAILED=' | cut -d= -f2-)"

  assert_eq "1" "$install_failed" "curl missing: _RTK_INSTALL_FAILED should be 1"
}

# ---------------------------------------------------------------------------
# Test 3 — Idempotency (binary already at pinned version)
# ---------------------------------------------------------------------------
test_tarball_idempotent_already_pinned() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  mkdir -p "$bin_dir"

  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  # Pre-create the rtk binary at the pinned version
  mkdir -p "$tmphome/.forge/bin"
  local pinned_version
  pinned_version="$(cat "$FORGE_ROOT/rtk/VERSION")"
  printf '#!/bin/sh\necho "rtk %s"\n' "$pinned_version" > "$tmphome/.forge/bin/rtk"
  chmod +x "$tmphome/.forge/bin/rtk"

  # Sentinel file to detect if curl is called
  local curl_sentinel="$tmpdir/curl_was_called"

  _make_uname_shims "$bin_dir" "Darwin" "aarch64"

  # curl shim that touches a sentinel if invoked
  local shim_curl="$bin_dir/curl"
  printf '#!/bin/sh\ntouch "%s"\nexit 1\n' "$curl_sentinel" > "$shim_curl"
  chmod +x "$shim_curl"

  _make_shasum_shim "$bin_dir"

  local script
  script="$(mktemp /tmp/rtk_tarball_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$forge_root_fake"
export HOME="$tmphome"
source "$FORGE_ROOT/lib/rtk.sh"
_RTK_INSTALL_FAILED=""
_RTK_INSTALLED_BY_US=""
forge_rtk_adjust_via_tarball 2>/dev/null
echo "EC=\$?"
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script")" || true
  rm -f "$script"

  local exit_code installed_by_us
  exit_code="$(printf '%s\n' "$output" | grep '^EC=' | cut -d= -f2-)"
  installed_by_us="$(printf '%s\n' "$output" | grep '^_RTK_INSTALLED_BY_US=' | cut -d= -f2-)"

  assert_eq "0" "$exit_code" "idempotent: exit code should be 0" || return 1
  assert_eq "true" "$installed_by_us" "idempotent: _RTK_INSTALLED_BY_US should be 'true'" || return 1

  if [ -f "$curl_sentinel" ]; then
    assert_eq "curl_not_called" "curl_was_called" "idempotent: curl should NOT be called when already at pinned version"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Test 4 — SHA256 mismatch → abort, no install
# ---------------------------------------------------------------------------
test_tarball_sha256_mismatch() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  local asset_dir="$tmpdir/assets"
  mkdir -p "$bin_dir" "$asset_dir"

  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  # Build a real fake tarball to get a valid asset
  _make_fake_tarball "$asset_dir"
  local real_asset_path="$FAKE_ASSET_PATH"

  # Create a tampered checksums.txt with a bogus hash (64 hex chars)
  local tampered_checksums="$asset_dir/tampered_checksums.txt"
  printf '%s  %s\n' \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "rtk-aarch64-apple-darwin.tar.gz" > "$tampered_checksums"

  _make_uname_shims "$bin_dir" "Darwin" "aarch64"
  _make_curl_shim "$bin_dir" "$real_asset_path" "$tampered_checksums"
  _make_shasum_shim "$bin_dir"

  local script
  script="$(mktemp /tmp/rtk_tarball_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$forge_root_fake"
export HOME="$tmphome"
source "$FORGE_ROOT/lib/rtk.sh"
_RTK_INSTALL_FAILED=""
_RTK_INSTALLED_BY_US=""
forge_rtk_adjust_via_tarball 2>/dev/null || true
echo "_RTK_INSTALL_FAILED=\${_RTK_INSTALL_FAILED:-}"
echo "RTK_BIN_EXISTS=\$([ -x "\$HOME/.forge/bin/rtk" ] && echo yes || echo no)"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script")" || true
  rm -f "$script"

  local install_failed bin_exists
  install_failed="$(printf '%s\n' "$output" | grep '^_RTK_INSTALL_FAILED=' | cut -d= -f2-)"
  bin_exists="$(printf '%s\n' "$output" | grep '^RTK_BIN_EXISTS=' | cut -d= -f2-)"

  assert_eq "1" "$install_failed" "sha256 mismatch: _RTK_INSTALL_FAILED should be 1" || return 1
  assert_eq "no" "$bin_exists" "sha256 mismatch: ~/.forge/bin/rtk should NOT exist" || return 1
}

# ---------------------------------------------------------------------------
# Test 5 — Successful install
# ---------------------------------------------------------------------------
test_tarball_success() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  local asset_dir="$tmpdir/assets"
  mkdir -p "$bin_dir" "$asset_dir"

  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  _make_fake_tarball "$asset_dir"
  _make_uname_shims "$bin_dir" "Darwin" "aarch64"
  _make_curl_shim "$bin_dir" "$FAKE_ASSET_PATH" "$FAKE_CHECKSUMS_PATH"
  _make_shasum_shim "$bin_dir"

  local script
  script="$(mktemp /tmp/rtk_tarball_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$forge_root_fake"
export HOME="$tmphome"
source "$FORGE_ROOT/lib/rtk.sh"
_RTK_INSTALL_FAILED=""
_RTK_INSTALLED_BY_US=""
forge_rtk_adjust_via_tarball 2>/dev/null
echo "EC=\$?"
echo "_RTK_INSTALLED_BY_US=\${_RTK_INSTALLED_BY_US:-}"
echo "RTK_BIN_EXISTS=\$([ -x "\$HOME/.forge/bin/rtk" ] && echo yes || echo no)"
SCRIPTEOF
  chmod +x "$script"

  local output
  output="$(bash "$script")" || true
  rm -f "$script"

  local exit_code installed_by_us bin_exists
  exit_code="$(printf '%s\n' "$output" | grep '^EC=' | cut -d= -f2-)"
  installed_by_us="$(printf '%s\n' "$output" | grep '^_RTK_INSTALLED_BY_US=' | cut -d= -f2-)"
  bin_exists="$(printf '%s\n' "$output" | grep '^RTK_BIN_EXISTS=' | cut -d= -f2-)"

  assert_eq "0" "$exit_code" "successful install: exit code should be 0" || return 1
  # Note: _RTK_INSTALLED_BY_US is only set by the idempotency branch (already pinned).
  # On a fresh install the function returns 0 and the binary is placed; the caller
  # (_forge_rtk_prompt_adjust) sets _RTK_INSTALLED_BY_US="true" after the call.
  # So we assert the observable side-effect: binary exists and is executable.
  assert_eq "yes" "$bin_exists" "successful install: ~/.forge/bin/rtk should exist and be executable" || return 1
}

# ---------------------------------------------------------------------------
# Test 6 — PATH warning when ~/.forge/bin not in PATH
# ---------------------------------------------------------------------------
test_tarball_path_warning() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local bin_dir="$tmpdir/bin"
  local asset_dir="$tmpdir/assets"
  mkdir -p "$bin_dir" "$asset_dir"

  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  _make_fake_tarball "$asset_dir"
  _make_uname_shims "$bin_dir" "Darwin" "aarch64"
  _make_curl_shim "$bin_dir" "$FAKE_ASSET_PATH" "$FAKE_CHECKSUMS_PATH"
  _make_shasum_shim "$bin_dir"

  # Capture stdout and stderr separately using process substitution + temp files
  local stdout_file stderr_file
  stdout_file="$(mktemp /tmp/rtk_tarball_stdout_XXXX.txt)"
  stderr_file="$(mktemp /tmp/rtk_tarball_stderr_XXXX.txt)"
  TMPDIR_LIST="$TMPDIR_LIST $stdout_file $stderr_file"

  local script
  script="$(mktemp /tmp/rtk_tarball_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
# PATH does NOT include \$HOME/.forge/bin — that's the point of this test
export PATH="$bin_dir:/usr/bin:/bin"
export FORGE_ROOT="$forge_root_fake"
export HOME="$tmphome"
source "$FORGE_ROOT/lib/rtk.sh"
_RTK_INSTALL_FAILED=""
_RTK_INSTALLED_BY_US=""
forge_rtk_adjust_via_tarball
echo "EC=\$?"
SCRIPTEOF
  chmod +x "$script"

  bash "$script" > "$stdout_file" 2> "$stderr_file" || true
  rm -f "$script"

  local exit_code stderr_content
  exit_code="$(grep '^EC=' "$stdout_file" | cut -d= -f2- || echo "")"
  stderr_content="$(cat "$stderr_file")"

  assert_eq "0" "$exit_code" "path warning: exit code should be 0 (non-fatal)" || return 1
  assert_contains "$tmphome/.forge/bin" "$stderr_content" "path warning: stderr should mention ~/.forge/bin path" || return 1
  assert_contains "PATH" "$stderr_content" "path warning: stderr should mention PATH" || return 1
}

# ---------------------------------------------------------------------------
# Test A1 — _forge_rtk_inject_path_snippet: existing profiles get marker block appended
# ---------------------------------------------------------------------------
test_inject_path_snippet_appends_to_existing_profiles() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local forge_root_fake="$tmpdir/forge_root"
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  # Create all 4 profile files empty
  touch "$tmphome/.zshrc"
  touch "$tmphome/.bashrc"
  touch "$tmphome/.zprofile"
  touch "$tmphome/.bash_profile"

  local script
  script="$(mktemp /tmp/rtk_inject_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="$tmphome"
export FORGE_ROOT="$forge_root_fake"
source "$FORGE_ROOT/lib/rtk.sh"
_forge_rtk_inject_path_snippet
SCRIPTEOF
  chmod +x "$script"
  bash "$script" >/dev/null 2>&1 || true
  rm -f "$script"

  local profile
  for profile in "$tmphome/.zshrc" "$tmphome/.bashrc" "$tmphome/.zprofile" "$tmphome/.bash_profile"; do
    if ! grep -qF "# >>> forge rtk path >>>" "$profile"; then
      assert_eq "marker present" "marker absent" "A1: $profile should contain open marker" || return 1
    fi
  done

  # At least one should contain the snippet body
  local body_found=0
  for profile in "$tmphome/.zshrc" "$tmphome/.bashrc" "$tmphome/.zprofile" "$tmphome/.bash_profile"; do
    if grep -qF 'case ":$PATH:"' "$profile"; then
      body_found=1
      break
    fi
  done
  assert_eq "1" "$body_found" "A1: at least one profile should contain snippet body (case \":$PATH:\")" || return 1
}

# ---------------------------------------------------------------------------
# Test A2 — Idempotency: calling twice produces exactly one marker block per profile
# ---------------------------------------------------------------------------
test_inject_path_snippet_idempotent() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  touch "$tmphome/.zshrc"
  touch "$tmphome/.bashrc"
  touch "$tmphome/.zprofile"
  touch "$tmphome/.bash_profile"

  local script
  script="$(mktemp /tmp/rtk_inject_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="$tmphome"
export FORGE_ROOT="$forge_root_fake"
source "$FORGE_ROOT/lib/rtk.sh"
_forge_rtk_inject_path_snippet
_forge_rtk_inject_path_snippet
SCRIPTEOF
  chmod +x "$script"
  bash "$script" >/dev/null 2>&1 || true
  rm -f "$script"

  local profile count
  for profile in "$tmphome/.zshrc" "$tmphome/.bashrc" "$tmphome/.zprofile" "$tmphome/.bash_profile"; do
    count="$(grep -c "# >>> forge rtk path >>>" "$profile" 2>/dev/null || echo "0")"
    assert_eq "1" "$count" "A2: $profile should have exactly 1 marker block after 2 calls" || return 1
  done
}

# ---------------------------------------------------------------------------
# Test A3 — Does not create profiles that don't exist
# ---------------------------------------------------------------------------
test_inject_path_snippet_no_create() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"
  # No profile files created in tmphome

  local script
  script="$(mktemp /tmp/rtk_inject_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="$tmphome"
export FORGE_ROOT="$forge_root_fake"
source "$FORGE_ROOT/lib/rtk.sh"
_forge_rtk_inject_path_snippet
SCRIPTEOF
  chmod +x "$script"
  bash "$script" >/dev/null 2>&1 || true
  rm -f "$script"

  local profile
  for profile in "$tmphome/.zshrc" "$tmphome/.bashrc" "$tmphome/.zprofile" "$tmphome/.bash_profile"; do
    if [ -e "$profile" ]; then
      assert_eq "file absent" "file present" "A3: $profile should NOT be created when it did not exist" || return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Test A4 — Logs one line per modified profile; no log on second (idempotent) call
# ---------------------------------------------------------------------------
test_inject_path_snippet_logs() {
  local tmpdir
  tmpdir="$(_make_tmpdir)"
  local forge_root_fake="$tmpdir/forge_root"
  local tmphome
  tmphome="$(_make_controlled_home "$forge_root_fake")"

  # Only .zshrc exists
  touch "$tmphome/.zshrc"

  # First call — run in a subprocess and capture stdout
  local script stdout_first
  script="$(mktemp /tmp/rtk_inject_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="$tmphome"
export FORGE_ROOT="$forge_root_fake"
source "$FORGE_ROOT/lib/rtk.sh"
_forge_rtk_inject_path_snippet
SCRIPTEOF
  chmod +x "$script"
  stdout_first="$(bash "$script" 2>/dev/null)" || true
  rm -f "$script"

  if ! printf '%s\n' "$stdout_first" | grep -qF "[rtk] PATH snippet añadido a"; then
    assert_eq "log line present" "log line absent" "A4: first call should log '[rtk] PATH snippet añadido a'" || return 1
  fi

  # Second call — same subprocess, same HOME; marker already present → no log
  script="$(mktemp /tmp/rtk_inject_test_XXXX.sh)"
  cat > "$script" <<SCRIPTEOF
#!/usr/bin/env bash
set -euo pipefail
export HOME="$tmphome"
export FORGE_ROOT="$forge_root_fake"
source "$FORGE_ROOT/lib/rtk.sh"
_forge_rtk_inject_path_snippet
SCRIPTEOF
  chmod +x "$script"
  local stdout_second
  stdout_second="$(bash "$script" 2>/dev/null)" || true
  rm -f "$script"

  if printf '%s\n' "$stdout_second" | grep -qF "añadido a"; then
    assert_eq "no log on second call" "log present on second call" "A4: second call should NOT log 'añadido a'" || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "=== rtk_tarball_unit.sh ==="
echo ""

run_test "test_tarball_unsupported_platform" test_tarball_unsupported_platform
run_test "test_tarball_curl_missing" test_tarball_curl_missing
run_test "test_tarball_idempotent_already_pinned" test_tarball_idempotent_already_pinned
run_test "test_tarball_sha256_mismatch" test_tarball_sha256_mismatch
run_test "test_tarball_success" test_tarball_success
run_test "test_tarball_path_warning" test_tarball_path_warning
run_test "test_inject_path_snippet_appends_to_existing_profiles" test_inject_path_snippet_appends_to_existing_profiles
run_test "test_inject_path_snippet_idempotent" test_inject_path_snippet_idempotent
run_test "test_inject_path_snippet_no_create" test_inject_path_snippet_no_create
run_test "test_inject_path_snippet_logs" test_inject_path_snippet_logs

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"

if [ "$FAIL" -ne 0 ]; then
  echo "FAIL"
  exit 1
else
  echo "ALL PASS"
  exit 0
fi
