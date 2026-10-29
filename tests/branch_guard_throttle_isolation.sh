#!/usr/bin/env bash
# tests/branch_guard_throttle_isolation.sh — DETECTOR of a REPORTED defect of
# the PRODUCT (shared/branch-guard.sh), NOT part of the battery.
#
# WHY THIS FILE EXISTS
# --------------------
# The guard declares its throttle as "una advertencia por sesion/repo": the
# touchfile that records that the warning was already shown is keyed by the
# IDENTITY of the repository (a hash of its path).
#
# The OLD implementation of shared/branch-guard.sh computed that hash with a
# chain of three alternatives:
#
#   repo_hash=$(printf '%s' "$repo_root" | shasum -a 1 2>/dev/null | cut -d' ' -f1 \
#     || printf '%s' "$repo_root" | md5sum 2>/dev/null | cut -d' ' -f1 \
#     || printf '%s' "$repo_root" | tr '/' '_' | tr -d ' ')
#
# The script did NOT use `set -o pipefail`, so the status of each pipeline
# was the status of its LAST command (`cut`), which always succeeds. The
# alternatives after the first one were therefore DEAD CODE: they could never
# run. When `shasum` is not in the PATH (it is a perl script that Arch
# installs in /usr/bin/core_perl and that a minimal PATH does not include),
# the hash was the EMPTY STRING and EVERY repository of the session shared
# the same touchfile ("<TMPDIR>/forge-branch-guard/.shown"). The second
# merged repository of the session was then silently throttled: the warning
# it deserves was never shown.
#
# That is a defect of the PRODUCT (the guard), not of a test: the behaviour
# of the guard depends on whether a non-standard tool happens to be in the
# PATH. This file is the REPRODUCER of that defect and it is deliberately
# NOT collected by tests/run-all.sh:
#
#   * it FAILS while the defect is open, and that failure is a real one;
#   * it must not be confused with a regression of the battery, so it is not
#     part of the battery;
#   * its real result is recorded in the acceptance report of the lot.
#
# The battery of the guard (tests/branch_guard_unit.sh) does NOT depend on
# this property: it exercises the throttle of ONE repository with a private
# TMPDIR, so it never depends on the internal hash of the guard.
#
# THE PATH IS FIXED (2026-10-28)
# -------------------------------
# The detector used to INHERIT the PATH of its caller, and that made the
# result of the detector depend on the HOST:
#
#   * with the full PATH of the session, `shasum` was reachable, so even the
#     OLD implementation distinguished the two repositories and the detector
#     reported "ALL PASS" WITHOUT reproducing the defect;
#   * the NEW implementation of the guard can also FAIL with an ERROR when
#     NO hasher is reachable ("[branch-guard] ERROR: unable to compute a
#     non-empty repository throttle hash"). That error line carries the
#     "[branch-guard]" prefix, so a detector that only looks for that prefix
#     reads TWO ERRORS as two WARNINGS and reports "ALL PASS" on a guard
#     that never warned about anything.
#
# The detector therefore builds its OWN PATH, with the exact set of tools it
# needs, and that PATH:
#
#   * does NOT contain `shasum` (the hasher the OLD implementation used), so
#     the OLD implementation fails REPRODUCIBLY: the defect is no longer a
#     property of the host;
#   * does contain `md5sum` (the fallback of the NEW implementation), so the
#     NEW implementation computes a per-repository hash.
#
# The verdict of the detector is built from THREE facts and not from one
# prefix: the guard must WARN (the real "already merged" warning), it must
# not ERROR, and it must EXIT with 0. A missing warning, an error and a
# non-zero exit are three DIFFERENT failures.
#
# Compatible with bash 3.2+.
set -uo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The guard under test can be OVERRIDDEN, so that the SENSITIVITY of this
# detector can be measured against a COPY of the guard (the OLD
# implementation, or a copy that errors) that lives OUTSIDE the repository.
BRANCH_GUARD="${FORGE_BRANCH_GUARD_PATH:-$FORGE_ROOT/shared/branch-guard.sh}"

FAIL=0
PASS=0

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/branch-guard-throttle.XXXXXX")" || exit 1
cleanup() {
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

# The FIXED PATH of the detector.
#
# It is a directory of symlinks built by the detector itself: the set of
# tools is EXACT, it does not depend on the PATH of the caller, and it does
# not contain `shasum`. The precondition is ASSERTED below: a detector that
# could not build its PATH would report a precondition failure, never an
# "ALL PASS".
FIXED_PATH_DIR="$WORKDIR/path"
build_fixed_path() {
  local tool source
  mkdir -p "$FIXED_PATH_DIR" || return 1
  for tool in bash sh git cut sed tr grep md5sum mkdir touch mktemp rm ls cat head wc env uname sort; do
    source="$(command -v "$tool" 2>/dev/null)" || continue
    [ -x "$source" ] || continue
    ln -sf "$source" "$FIXED_PATH_DIR/$tool" || return 1
  done
  return 0
}

if ! build_fixed_path; then
  echo "  FAIL: no se pudo construir el PATH fijo del detector" >&2
  exit 1
fi

FIXED_PATH="$FIXED_PATH_DIR"

# The precondition of the detector: the PATH is fixed, `shasum` is NOT
# reachable through it and `md5sum` IS. Without that, the result of the
# detector would be a property of the host and not of the guard.
if PATH="$FIXED_PATH" command -v shasum >/dev/null 2>&1; then
  echo "  FAIL: el PATH fijo del detectorTodavia alcanza 'shasum': el defecto no seria reproducible" >&2
  exit 1
fi
if ! PATH="$FIXED_PATH" command -v md5sum >/dev/null 2>&1; then
  echo "  FAIL: el PATH fijo del detector no alcanza 'md5sum': el detector no puede medir el defecto" >&2
  exit 1
fi

# The real WARNING of the guard and its ERROR are DIFFERENT messages, and
# the verdict of the detector is built from the difference.
WARNING_MARKER='mergeada en origin/'
ERROR_MARKER='[branch-guard] ERROR:'

# make_merged_repo <dir>
#
# Creates a repository with a feature branch that is ALREADY merged in
# origin/master, so the guard has something to warn about.
make_merged_repo() {
  local dir="$1" remote="$2"
  mkdir -p "$remote"
  (
    cd "$remote" || exit 1
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    printf 'init\n' > README.md
    git add README.md
    git commit -q -m init
  ) || return 1
  git clone -q "$remote" "$dir" 2>/dev/null || return 1
  (
    cd "$dir" || exit 1
    git config user.email "test@test.com"
    git config user.name "Test"
    git checkout -q -b feature/merged
    printf 'more\n' >> README.md
    git add README.md
    git commit -q -m "feature"
    git push -q origin feature/merged
    cd "$remote" || exit 1
    git merge -q --no-ff feature/merged
    cd "$dir" || exit 1
    git fetch -q origin
  ) >/dev/null 2>&1 || return 1
  return 0
}

# warn_of <repo> <tmpdir>
#
# Runs the guard in <repo> with <tmpdir> as its TMPDIR and with the FIXED
# PATH, and leaves its stderr in $WORKDIR/guard-output.txt. The exit status
# of the guard is published in the global GUARD_RC: the result of the
# EXECUTION is part of the verdict.
#
# The output is NOT captured with a command substitution: a substitution
# runs in a SUBSHELL, so the status of the guard would be published in that
# subshell and the parent would always read a zero. The status is taken here,
# in the parent, from the subshell that runs the guard.
GUARD_RC=0
warn_of() {
  local repo="$1" tmpdir="$2"
  (
    cd "$repo" || exit 1
    printf '{"tool_name":"Read","tool_input":{}}' \
      | env -i PATH="$FIXED_PATH" TMPDIR="$tmpdir" HOME="$tmpdir" \
          LC_ALL=C TZ=UTC /bin/bash "$BRANCH_GUARD" 2>&1 1>/dev/null
  ) > "$WORKDIR/guard-output.txt" 2>/dev/null
  GUARD_RC=$?
  return 0
}

# describe_guard_output <output>
#
# The diagnosis of the output of the guard: it says whether the guard WARNED
# (the real warning), whether it ERRORED and what its exit status was.
describe_guard_output() {
  local output="$1"
  if printf '%s' "$output" | grep -qF "$ERROR_MARKER"; then
    printf 'ERROR del guard: %s' "$output"
    return
  fi
  if printf '%s' "$output" | grep -qF "$WARNING_MARKER"; then
    printf 'ADVERTENCIA real'
    return
  fi
  printf 'SIN ADVERTENCIA'
}

echo "================================"
echo " branch_guard_throttle_isolation.sh"
echo " detector of a REPORTED defect of shared/branch-guard.sh"
echo "================================"
echo "  (PATH fijo del detector: sin 'shasum'; la implementacion antigua falla de forma reproducible)"

# The two repositories live in DIFFERENT paths and share the SAME TMPDIR:
# the only thing that can tell their throttle files apart is the identity
# of the repository.
SHARED_TMP="$WORKDIR/tmp"
mkdir -p "$SHARED_TMP"

REPO_A="$WORKDIR/repo-a"
REPO_B="$WORKDIR/repo-b"
if ! make_merged_repo "$REPO_A" "$WORKDIR/remote-a"; then
  fail "no se pudo preparar el primer repositorio"
  exit 1
fi
if ! make_merged_repo "$REPO_B" "$WORKDIR/remote-b"; then
  fail "no se pudo preparar el segundo repositorio"
  exit 1
fi

warn_of "$REPO_A" "$SHARED_TMP"
FIRST_RC="$GUARD_RC"
FIRST="$(cat "$WORKDIR/guard-output.txt" 2>/dev/null)"
warn_of "$REPO_B" "$SHARED_TMP"
SECOND_RC="$GUARD_RC"
SECOND="$(cat "$WORKDIR/guard-output.txt" 2>/dev/null)"

# The verdict of each invocation has THREE parts: the guard has to WARN with
# the real warning, it must NOT report an ERROR and it must EXIT with 0.
check_invocation() {
  local label="$1" output="$2" rc="$3"
  if printf '%s' "$output" | grep -qF "$ERROR_MARKER"; then
    fail "$label: el guard emitio un ERROR en vez de la advertencia (rc=$rc; $(describe_guard_output "$output"))"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    fail "$label: el guard no termino con exito (rc=$rc; $(describe_guard_output "$output"))"
    return 1
  fi
  if ! printf '%s' "$output" | grep -qF "$WARNING_MARKER"; then
    fail "$label: el guard NO emitio la advertencia real de rama ya mergeada (rc=$rc; $(describe_guard_output "$output"))"
    return 1
  fi
  pass "$label: el guard emitio la ADVERTENCIA real y termino con rc=0"
  return 0
}

check_invocation "el primer repositorio mergeado" "$FIRST" "$FIRST_RC"

if check_invocation "el segundo repositorio mergeado" "$SECOND" "$SECOND_RC"; then
  pass "el segundo repositorio mergeado recibe SU PROPIA advertencia: el throttle es por repositorio"
else
  fail "el segundo repositorio mergeado NO recibio SU PROPIA advertencia: el throttle se compartio entre repositorios"
  printf '%s\n' "  (el touchfile compartido del throttle es: $(ls -A "$SHARED_TMP/forge-branch-guard" 2>/dev/null | tr '\n' ' '))" >&2
  printf '%s\n' "  (la causa es la cadena muerta de sumas de shared/branch-guard.sh: sin 'set -o pipefail' el estado del pipeline es el de 'cut', y el hash queda vacio cuando 'shasum' no esta en el PATH)" >&2
fi

echo ""
echo "================================"
echo " Passed: $PASS"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
fi
echo " ALL PASS"
