#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/clean_target_unit.sh — Unit tests for _forge_clean_target in install.sh
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Test harness
FAIL=0
PASS=0
TMPDIR_BASE="$FORGE_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

# Pattern-based cleanup: the make_* helpers run inside command substitutions
# (subshells), so accumulating paths in a parent-shell variable never works
# (the list stays empty and nothing was removed — tests/.tmp grew unbounded).
# The mktemp template embeds $$ (parent PID even inside subshells), so this
# glob removes exactly this run's artifacts.
cleanup() {
  rm -rf "$TMPDIR_BASE"/clean-target-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/clean-target-$$-XXXX")"
  echo "$dir"
}

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
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

# ---------------------------------------------------------------------------
# Source _forge_clean_target from install.sh.
# We only want the function definition, not the full script execution.
# We source install.sh in a controlled way: the script guards its main body
# with a function-only source pattern.
# ---------------------------------------------------------------------------
# Extract and source only the function + its helpers by temporarily setting
# FORGE_SOURCED_FOR_TESTS so install.sh main body is skipped.
# Since install.sh does not have a guard, we source it with a temporary
# override of the sentinel that prevents re-execution of top-level code.
# install.sh is a script, not a library; we extract the function directly.

_source_clean_target() {
  # Use awk to extract the function body from install.sh and source it.
  # We also need FORGE_ROOT set to the fake value inside each test, so we
  # define a thin wrapper that sets FORGE_ROOT before calling the real fn.
  local fn_body
  fn_body="$(awk '/^_forge_clean_target\(\)/{found=1} found{print} found && /^\}$/{exit}' \
    "$FORGE_ROOT/install.sh")"
  eval "$fn_body"
}

_source_clean_target

# =============================================================================
# Test cases
# =============================================================================

# 1. Symlink pointing into ${FORGE_ROOT}-other/ must NOT be removed (prefix collision)
test_prefix_collision_not_removed() {
  local tmp
  tmp="$(make_tmp)"

  # fake FORGE_ROOT and sibling directory
  local fake_root="$tmp/forge"
  local fake_sibling="$tmp/forge-other"
  mkdir -p "$fake_root"
  mkdir -p "$fake_sibling"

  # File inside the sibling (not owned by forge)
  printf 'data' > "$fake_sibling/x"

  # Simulated HOME (tgt_dir)
  local fake_home="$tmp/home"
  mkdir -p "$fake_home/agents"

  # Symlink inside tgt_dir pointing to the sibling file
  ln -s "$fake_sibling/x" "$fake_home/agents/x"

  # Run with FORGE_ROOT overridden to the fake path
  FORGE_ROOT="$fake_root" _forge_clean_target "$fake_home" >/dev/null 2>&1

  if [ -L "$fake_home/agents/x" ]; then
    pass "prefix_collision_not_removed: symlink to sibling dir preserved"
  else
    fail "prefix_collision_not_removed: symlink to sibling dir was incorrectly removed"
  fi
}

# 2. Symlink pointing into ${FORGE_ROOT}/... MUST be removed (owned by forge)
test_owned_symlink_removed() {
  local tmp
  tmp="$(make_tmp)"

  local fake_root="$tmp/forge"
  mkdir -p "$fake_root"
  printf 'data' > "$fake_root/agent.md"

  local fake_home="$tmp/home"
  mkdir -p "$fake_home/agents"

  ln -s "$fake_root/agent.md" "$fake_home/agents/agent.md"

  FORGE_ROOT="$fake_root" _forge_clean_target "$fake_home" >/dev/null 2>&1

  if [ ! -L "$fake_home/agents/agent.md" ]; then
    pass "owned_symlink_removed: symlink to forge root was removed"
  else
    fail "owned_symlink_removed: symlink to forge root was NOT removed"
  fi
}

# 3. Symlink pointing to an unrelated path must NOT be removed
test_unrelated_symlink_not_removed() {
  local tmp
  tmp="$(make_tmp)"

  local fake_root="$tmp/forge"
  mkdir -p "$fake_root"

  local unrelated="$tmp/unrelated"
  mkdir -p "$unrelated"
  printf 'data' > "$unrelated/file.txt"

  local fake_home="$tmp/home"
  mkdir -p "$fake_home/agents"

  ln -s "$unrelated/file.txt" "$fake_home/agents/file.txt"

  FORGE_ROOT="$fake_root" _forge_clean_target "$fake_home" >/dev/null 2>&1

  if [ -L "$fake_home/agents/file.txt" ]; then
    pass "unrelated_symlink_not_removed: unrelated symlink preserved"
  else
    fail "unrelated_symlink_not_removed: unrelated symlink was incorrectly removed"
  fi
}

# 4. Both owned and sibling symlinks coexist — only owned is removed
test_mixed_symlinks_selective_removal() {
  local tmp
  tmp="$(make_tmp)"

  local fake_root="$tmp/forge"
  local fake_sibling="$tmp/forge-other"
  mkdir -p "$fake_root"
  mkdir -p "$fake_sibling"
  printf 'owned' > "$fake_root/owned.md"
  printf 'sibling' > "$fake_sibling/sibling.md"

  local fake_home="$tmp/home"
  mkdir -p "$fake_home/agents"

  ln -s "$fake_root/owned.md"    "$fake_home/agents/owned.md"
  ln -s "$fake_sibling/sibling.md" "$fake_home/agents/sibling.md"

  FORGE_ROOT="$fake_root" _forge_clean_target "$fake_home" >/dev/null 2>&1

  if [ ! -L "$fake_home/agents/owned.md" ]; then
    pass "mixed_selective: owned symlink removed"
  else
    fail "mixed_selective: owned symlink was NOT removed"
  fi

  if [ -L "$fake_home/agents/sibling.md" ]; then
    pass "mixed_selective: sibling symlink preserved"
  else
    fail "mixed_selective: sibling symlink was incorrectly removed"
  fi
}

# 5. skills/<name>/SKILL.md symlink pointing into FORGE_ROOT MUST be removed
test_skills_subdir_owned_symlink_removed() {
  local tmp
  tmp="$(make_tmp)"

  local fake_root="$tmp/forge"
  mkdir -p "$fake_root/skills/create-plan"
  printf 'data' > "$fake_root/skills/create-plan/SKILL.md"

  local fake_home="$tmp/home"
  mkdir -p "$fake_home/skills/create-plan"

  ln -s "$fake_root/skills/create-plan/SKILL.md" "$fake_home/skills/create-plan/SKILL.md"

  FORGE_ROOT="$fake_root" _forge_clean_target "$fake_home" >/dev/null 2>&1

  if [ ! -L "$fake_home/skills/create-plan/SKILL.md" ]; then
    pass "skills_subdir_owned_symlink_removed: owned symlink inside skills/<name>/ was removed"
  else
    fail "skills_subdir_owned_symlink_removed: owned symlink inside skills/<name>/ was NOT removed"
  fi
}

# 6. skills/<name>/SKILL.md symlink pointing to unrelated path must NOT be removed
test_skills_subdir_non_owned_symlink_preserved() {
  local tmp
  tmp="$(make_tmp)"

  local fake_root="$tmp/forge"
  mkdir -p "$fake_root"

  local unrelated="$tmp/unrelated"
  mkdir -p "$unrelated"
  printf 'data' > "$unrelated/SKILL.md"

  local fake_home="$tmp/home"
  mkdir -p "$fake_home/skills/create-plan"

  ln -s "$unrelated/SKILL.md" "$fake_home/skills/create-plan/SKILL.md"

  FORGE_ROOT="$fake_root" _forge_clean_target "$fake_home" >/dev/null 2>&1

  if [ -L "$fake_home/skills/create-plan/SKILL.md" ]; then
    pass "skills_subdir_non_owned_symlink_preserved: non-owned symlink inside skills/<name>/ preserved"
  else
    fail "skills_subdir_non_owned_symlink_preserved: non-owned symlink inside skills/<name>/ was incorrectly removed"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== clean_target_unit.sh ==="

run_test test_prefix_collision_not_removed
run_test test_owned_symlink_removed
run_test test_unrelated_symlink_not_removed
run_test test_mixed_symlinks_selective_removal
run_test test_skills_subdir_owned_symlink_removed
run_test test_skills_subdir_non_owned_symlink_preserved

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
