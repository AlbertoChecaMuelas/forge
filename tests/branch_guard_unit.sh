#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/branch_guard_unit.sh — Unit tests for shared/branch-guard.sh
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH_GUARD="$FORGE_ROOT/shared/branch-guard.sh"

# Test harness
FAIL=0
PASS=0
TMPDIR_BASE="$FORGE_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

# Cleanup all temp dirs on exit
# Pattern-based cleanup: the make_* helpers run inside command substitutions
# (subshells), so accumulating paths in a parent-shell variable never works
# (the list stays empty and nothing was removed — tests/.tmp grew unbounded).
# The mktemp template embeds $$ (parent PID even inside subshells), so this
# glob removes exactly this run's artifacts.
cleanup() {
  rm -rf "$TMPDIR_BASE"/bg-$$-* /tmp/bg-$$-* 2>/dev/null || true
  rm -rf "${TMPDIR:-/tmp}/forge-branch-guard/" 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/bg-$$-XXXX")"
  echo "$dir"
}

# Create a temp dir outside any git repo (in system /tmp) for test (d)
make_tmp_outside() {
  local dir
  dir="$(mktemp -d "/tmp/bg-$$-XXXX")"
  echo "$dir"
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

# Helper: run branch-guard from a given directory and capture output
# Usage: run_guard <cwd> [env_var=value ...]
# Returns: exit code in $GUARD_EXIT, stderr in $GUARD_STDERR
GUARD_EXIT=0
GUARD_STDERR=""
run_guard() {
  local cwd="$1"
  shift
  GUARD_EXIT=0
  # Feed a minimal PreToolUse JSON payload via stdin so branch-guard does not
  # fail-open on empty stdin. Using tool_name="Read" makes the script skip the
  # commit guard branch and exercise the already-merged warning logic that
  # these tests validate. See shared/branch-guard.sh lines 35-77.
  local stdin_payload='{"tool_name":"Read","tool_input":{}}'
  if [ $# -gt 0 ]; then
    GUARD_STDERR="$( cd "$cwd" && env "$@" bash "$BRANCH_GUARD" 2>&1 1>/dev/null <<<"$stdin_payload" )" || GUARD_EXIT=$?
  else
    GUARD_STDERR="$( cd "$cwd" && bash "$BRANCH_GUARD" 2>&1 1>/dev/null <<<"$stdin_payload" )" || GUARD_EXIT=$?
  fi
}

# Helper: create a minimal git repo with one commit
# Usage: make_git_repo <dir>
make_git_repo() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  # Ensure master as the default branch
  git -C "$dir" symbolic-ref HEAD refs/heads/master
  printf 'init\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit -q -m "init"
}

# =============================================================================
# Test cases
# =============================================================================

# (a) Rama no mergeada → exit 0, STDERR vacío
test_unmerged_branch() {
  local tmp
  tmp="$(make_tmp)"

  # Create remote repo
  local remote="$tmp/remote"
  mkdir -p "$remote"
  make_git_repo "$remote"

  # Clone into local repo
  local local_repo="$tmp/local"
  git clone -q "$remote" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Create feature branch with a NEW commit not in origin/master
  git -C "$local_repo" checkout -q -b feature/unmerged
  printf 'new\n' >> "$local_repo/README.md"
  git -C "$local_repo" add README.md
  git -C "$local_repo" commit -q -m "feature commit"

  run_guard "$local_repo"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "unmerged_branch: exit 0"
  else
    fail "unmerged_branch: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "unmerged_branch: STDERR vacío"
  else
    fail "unmerged_branch: STDERR no vacío (got: $GUARD_STDERR)"
  fi
}

# (b) HEAD mergeada en origin/master → exit 0, STDERR contiene [branch-guard] y el nombre de la rama
test_merged_branch() {
  local tmp
  tmp="$(make_tmp)"

  # Create remote repo
  local remote="$tmp/remote"
  mkdir -p "$remote"
  make_git_repo "$remote"

  # Clone into local repo
  local local_repo="$tmp/local"
  git clone -q "$remote" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Create feature branch with a commit
  git -C "$local_repo" checkout -q -b feature/merged-branch
  printf 'feature\n' >> "$local_repo/README.md"
  git -C "$local_repo" add README.md
  git -C "$local_repo" commit -q -m "feature commit"

  # Merge into remote master (simulating merge via remote)
  git -C "$remote" config user.email "test@test.com"
  git -C "$remote" config user.name "Test"
  # Push the feature branch to remote, then merge it there
  git -C "$local_repo" push -q origin feature/merged-branch
  git -C "$remote" merge -q --no-ff origin/feature/merged-branch 2>/dev/null || \
    git -C "$remote" merge -q --no-ff feature/merged-branch 2>/dev/null || \
    { fail "setup: no se pudo simular merge en remote"; return 1; }

  # Fetch so local knows about the updated origin/master
  git -C "$local_repo" fetch -q origin

  # Clear any leftover touchfile for this repo to avoid inter-run contamination
  local repo_hash
  repo_hash=$(git -C "$local_repo" rev-parse --show-toplevel | shasum -a 1 2>/dev/null | cut -d' ' -f1 || git -C "$local_repo" rev-parse --show-toplevel | md5sum 2>/dev/null | cut -d' ' -f1 || git -C "$local_repo" rev-parse --show-toplevel | tr '/' '_' | tr -d ' ')
  rm -f "${TMPDIR:-/tmp}/forge-branch-guard/${repo_hash}.shown"

  # Stay on feature/merged-branch — its HEAD is now ancestor of origin/master
  run_guard "$local_repo"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "merged_branch: exit 0"
  else
    fail "merged_branch: expected exit 0, got $GUARD_EXIT"
  fi

  if echo "$GUARD_STDERR" | grep -q "\[branch-guard\]"; then
    pass "merged_branch: STDERR contiene [branch-guard]"
  else
    fail "merged_branch: STDERR no contiene [branch-guard] (got: $GUARD_STDERR)"
  fi

  if echo "$GUARD_STDERR" | grep -q "feature/merged-branch"; then
    pass "merged_branch: STDERR contiene el nombre de la rama"
  else
    fail "merged_branch: STDERR no contiene el nombre de la rama (got: $GUARD_STDERR)"
  fi
}

# (c) HEAD == default branch → exit 0, sin output
test_on_default_branch() {
  local tmp
  tmp="$(make_tmp)"

  local remote="$tmp/remote"
  mkdir -p "$remote"
  make_git_repo "$remote"

  local local_repo="$tmp/local"
  git clone -q "$remote" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"
  # Already on master after clone

  run_guard "$local_repo"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "on_default_branch: exit 0"
  else
    fail "on_default_branch: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "on_default_branch: sin output"
  else
    fail "on_default_branch: output inesperado (got: $GUARD_STDERR)"
  fi
}

# (d) cwd no es repo git → exit 0, sin output
test_not_a_git_repo() {
  local tmp
  # Must be outside any git repo tree; tests/.tmp/ is inside forge repo
  tmp="$(make_tmp_outside)"

  run_guard "$tmp"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "not_a_git_repo: exit 0"
  else
    fail "not_a_git_repo: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "not_a_git_repo: sin output"
  else
    fail "not_a_git_repo: output inesperado (got: $GUARD_STDERR)"
  fi
}

# (e) Touchfile presente → exit 0, sin output (throttle: segunda invocación silenciosa)
test_touchfile_throttle() {
  local tmp
  tmp="$(make_tmp)"

  local remote="$tmp/remote"
  mkdir -p "$remote"
  make_git_repo "$remote"

  local local_repo="$tmp/local"
  git clone -q "$remote" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Create a feature branch merged into origin/master (same setup as case b)
  git -C "$local_repo" checkout -q -b feature/throttle-test
  printf 'throttle\n' >> "$local_repo/README.md"
  git -C "$local_repo" add README.md
  git -C "$local_repo" commit -q -m "throttle commit"

  git -C "$remote" config user.email "test@test.com"
  git -C "$remote" config user.name "Test"
  git -C "$local_repo" push -q origin feature/throttle-test
  git -C "$remote" merge -q --no-ff feature/throttle-test 2>/dev/null || \
    { fail "setup: no se pudo simular merge en remote"; return 1; }
  git -C "$local_repo" fetch -q origin

  # Clear any leftover touchfile for this repo to avoid inter-run contamination
  local repo_hash
  repo_hash=$(git -C "$local_repo" rev-parse --show-toplevel | shasum -a 1 2>/dev/null | cut -d' ' -f1 || git -C "$local_repo" rev-parse --show-toplevel | md5sum 2>/dev/null | cut -d' ' -f1 || git -C "$local_repo" rev-parse --show-toplevel | tr '/' '_' | tr -d ' ')
  rm -f "${TMPDIR:-/tmp}/forge-branch-guard/${repo_hash}.shown"

  # First invocation: should print the warning
  run_guard "$local_repo"
  local first_stderr="$GUARD_STDERR"

  if echo "$first_stderr" | grep -q "\[branch-guard\]"; then
    pass "touchfile_throttle: primera invocación emite advertencia"
  else
    fail "touchfile_throttle: primera invocación no emitió advertencia (got: $first_stderr)"
  fi

  # Second invocation: touchfile is present, should be silent
  run_guard "$local_repo"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "touchfile_throttle: segunda invocación exit 0"
  else
    fail "touchfile_throttle: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "touchfile_throttle: segunda invocación silenciosa"
  else
    fail "touchfile_throttle: segunda invocación no fue silenciosa (got: $GUARD_STDERR)"
  fi
}

# (f) origin/<default> no existe → exit 0, sin output
test_no_origin_default() {
  local tmp
  tmp="$(make_tmp)"

  local remote="$tmp/remote"
  mkdir -p "$remote"
  make_git_repo "$remote"

  local local_repo="$tmp/local"
  git clone -q "$remote" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Create a feature branch
  git -C "$local_repo" checkout -q -b feature/no-origin-default

  # Remove origin/master reference by deleting origin remote refs
  # We do this by removing the remote tracking branch for master
  git -C "$local_repo" remote remove origin

  # Re-add origin but don't fetch, so origin/<default> won't exist
  git -C "$local_repo" remote add origin "$remote"
  # Do NOT fetch — so origin/master won't be in refs

  run_guard "$local_repo"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "no_origin_default: exit 0"
  else
    fail "no_origin_default: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "no_origin_default: sin output"
  else
    fail "no_origin_default: output inesperado (got: $GUARD_STDERR)"
  fi
}

# (g) FORGE_BRANCH_GUARD_DISABLE=1 → exit 0, sin output
test_disable_env_var() {
  local tmp
  tmp="$(make_tmp)"

  local remote="$tmp/remote"
  mkdir -p "$remote"
  make_git_repo "$remote"

  local local_repo="$tmp/local"
  git clone -q "$remote" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Create a merged branch scenario so guard would normally fire
  git -C "$local_repo" checkout -q -b feature/disabled-test
  printf 'disabled\n' >> "$local_repo/README.md"
  git -C "$local_repo" add README.md
  git -C "$local_repo" commit -q -m "disabled commit"

  git -C "$remote" config user.email "test@test.com"
  git -C "$remote" config user.name "Test"
  git -C "$local_repo" push -q origin feature/disabled-test
  git -C "$remote" merge -q --no-ff feature/disabled-test 2>/dev/null || \
    { fail "setup: no se pudo simular merge en remote"; return 1; }
  git -C "$local_repo" fetch -q origin

  # Clear any leftover touchfile for this repo to avoid inter-run contamination
  local repo_hash
  repo_hash=$(git -C "$local_repo" rev-parse --show-toplevel | shasum -a 1 2>/dev/null | cut -d' ' -f1 || git -C "$local_repo" rev-parse --show-toplevel | md5sum 2>/dev/null | cut -d' ' -f1 || git -C "$local_repo" rev-parse --show-toplevel | tr '/' '_' | tr -d ' ')
  rm -f "${TMPDIR:-/tmp}/forge-branch-guard/${repo_hash}.shown"

  run_guard "$local_repo" "FORGE_BRANCH_GUARD_DISABLE=1"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "disable_env_var: exit 0"
  else
    fail "disable_env_var: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "disable_env_var: sin output"
  else
    fail "disable_env_var: output inesperado (got: $GUARD_STDERR)"
  fi
}

# (h) Detached HEAD → exit 0, sin output
test_detached_head() {
  local tmp
  tmp="$(make_tmp)"

  make_git_repo "$tmp"

  # Grab the commit hash and enter detached HEAD state
  local commit_hash
  commit_hash=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" checkout -q --detach "$commit_hash"

  run_guard "$tmp"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "detached_head: exit 0"
  else
    fail "detached_head: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "detached_head: sin output"
  else
    fail "detached_head: output inesperado (got: $GUARD_STDERR)"
  fi
}

# (i) init.defaultBranch fallback → no warning para rama feature no mergeada
test_init_default_branch_fallback() {
  local tmp
  tmp="$(make_tmp)"

  # Create remote repo with 'main' as default branch
  local remote="$tmp/remote"
  mkdir -p "$remote"
  git -C "$remote" init -q
  git -C "$remote" config user.email "test@test.com"
  git -C "$remote" config user.name "Test"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  printf 'init\n' > "$remote/README.md"
  git -C "$remote" add README.md
  git -C "$remote" commit -q -m "init"

  # Clone the repo; by default git sets origin/HEAD → origin/main
  local local_repo="$tmp/local"
  git clone -q "$remote" "$local_repo"
  git -C "$local_repo" config user.email "test@test.com"
  git -C "$local_repo" config user.name "Test"

  # Remove origin/HEAD so that git symbolic-ref refs/remotes/origin/HEAD fails,
  # forcing the guard to fall through to init.defaultBranch config
  git -C "$local_repo" remote set-head origin --delete 2>/dev/null || true

  # Configure init.defaultBranch = main in the local repo
  git -C "$local_repo" config init.defaultBranch main

  # Create a feature branch with a new commit (not merged into origin/main)
  git -C "$local_repo" checkout -q -b feature/fallback-test
  printf 'feature\n' >> "$local_repo/README.md"
  git -C "$local_repo" add README.md
  git -C "$local_repo" commit -q -m "feature commit"

  run_guard "$local_repo"

  if [ "$GUARD_EXIT" -eq 0 ]; then
    pass "init_default_branch_fallback: exit 0"
  else
    fail "init_default_branch_fallback: expected exit 0, got $GUARD_EXIT"
  fi

  if [ -z "$GUARD_STDERR" ]; then
    pass "init_default_branch_fallback: sin output (rama no mergeada, sin warning)"
  else
    fail "init_default_branch_fallback: output inesperado (got: $GUARD_STDERR)"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== branch_guard_unit.sh ==="

run_test test_unmerged_branch
run_test test_merged_branch
run_test test_on_default_branch
run_test test_not_a_git_repo
run_test test_touchfile_throttle
run_test test_no_origin_default
run_test test_disable_env_var
run_test test_detached_head
run_test test_init_default_branch_fallback

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
