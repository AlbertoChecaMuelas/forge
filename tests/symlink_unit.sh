#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/symlink_unit.sh — Unit tests for lib/symlink.sh
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$FORGE_ROOT/lib/symlink.sh"

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
  rm -rf "$TMPDIR_BASE"/symlink-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/symlink-$$-XXXX")"
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

# =============================================================================
# Test cases
# =============================================================================

# 1. dest missing -> create symlink
test_dest_missing() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/link.txt"
  printf 'hello' > "$src"

  forge_symlink "$src" "$dest" >/dev/null 2>&1

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    pass "dest_missing: symlink created correctly"
  else
    fail "dest_missing: symlink not created or wrong target"
  fi
}

# 2. dest already correct symlink -> no-op, no backup
test_dest_correct_symlink() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/link.txt"
  printf 'hello' > "$src"
  ln -s "$src" "$dest"

  forge_symlink "$src" "$dest" >/dev/null 2>&1

  # No backup should exist
  local bak_count
  bak_count="$(find "$tmp" -name "*.forge-bak-*" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "dest_correct_symlink: no backup created" "0" "$bak_count"
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    pass "dest_correct_symlink: still correct"
  else
    fail "dest_correct_symlink: symlink changed unexpectedly"
  fi
}

# 3. dest is wrong symlink -> backup created, symlink repointed
test_dest_wrong_symlink() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local other="$tmp/other.txt"
  local dest="$tmp/link.txt"
  printf 'hello' > "$src"
  printf 'other' > "$other"
  ln -s "$other" "$dest"

  forge_symlink "$src" "$dest" >/dev/null 2>&1

  # A backup should exist
  local bak_count
  bak_count="$(find "$tmp" -name "*.forge-bak-*" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$bak_count" -ge 1 ]; then
    pass "dest_wrong_symlink: backup created"
  else
    fail "dest_wrong_symlink: no backup found"
  fi

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    pass "dest_wrong_symlink: symlink repointed to src"
  else
    fail "dest_wrong_symlink: symlink not correctly updated"
  fi
}

# 4. dest is regular file -> backup preserves content, dest becomes symlink
test_dest_regular_file() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/dest.txt"
  printf 'hello' > "$src"
  printf 'original content' > "$dest"

  forge_symlink "$src" "$dest" >/dev/null 2>&1

  # dest is now a symlink
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    pass "dest_regular_file: dest is now symlink"
  else
    fail "dest_regular_file: dest is not the correct symlink"
  fi

  # backup exists and preserves original content
  local bak
  bak="$(find "$tmp" -name "*.forge-bak-*" 2>/dev/null | head -1)"
  if [ -n "$bak" ] && [ "$(cat "$bak")" = "original content" ]; then
    pass "dest_regular_file: backup preserves original content"
  else
    fail "dest_regular_file: backup missing or content lost"
  fi
}

# 5. dest is a directory -> backup as forge-bak-<ts>, symlink created
test_dest_directory() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/mydir"
  printf 'hello' > "$src"
  mkdir -p "$dest"

  forge_symlink "$src" "$dest" >/dev/null 2>&1

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    pass "dest_directory: dest is now symlink"
  else
    fail "dest_directory: dest is not the correct symlink"
  fi

  local bak_count
  bak_count="$(find "$tmp" -maxdepth 1 -name "mydir.forge-bak-*" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$bak_count" -ge 1 ]; then
    pass "dest_directory: backup created with forge-bak-<ts> naming"
  else
    fail "dest_directory: no backup found"
  fi
}

# 6. parent directory missing -> created with mkdir -p
test_parent_missing() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/a/b/c/link.txt"
  printf 'hello' > "$src"

  forge_symlink "$src" "$dest" >/dev/null 2>&1

  if [ -d "$tmp/a/b/c" ]; then
    pass "parent_missing: parent dirs created"
  else
    fail "parent_missing: parent dirs not created"
  fi

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
    pass "parent_missing: symlink created in new dirs"
  else
    fail "parent_missing: symlink not created correctly"
  fi
}

# 7. relative path rejected -> returns != 0
test_relative_path_rejected() {
  local result=0
  forge_symlink "relative/path" "/tmp/dest" >/dev/null 2>&1 || result=$?
  if [ "$result" -ne 0 ]; then
    pass "relative_path_rejected: relative source rejected with non-zero exit"
  else
    fail "relative_path_rejected: should have returned non-zero for relative source"
  fi

  result=0
  forge_symlink "/tmp/source" "relative/dest" >/dev/null 2>&1 || result=$?
  if [ "$result" -ne 0 ]; then
    pass "relative_path_rejected: relative dest rejected with non-zero exit"
  else
    fail "relative_path_rejected: should have returned non-zero for relative dest"
  fi
}

# 8. unlink removes symlink
test_unlink_removes_symlink() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/link.txt"
  printf 'hello' > "$src"
  ln -s "$src" "$dest"

  forge_unlink "$dest" >/dev/null 2>&1

  if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
    pass "unlink_removes_symlink: symlink removed"
  else
    fail "unlink_removes_symlink: symlink still exists"
  fi
}

# 9. unlink restores .pre-forge if it exists
test_unlink_restores_pre_forge() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/settings.json"
  printf 'hello' > "$src"
  printf 'original settings' > "${dest}.pre-forge"
  ln -s "$src" "$dest"

  forge_unlink "$dest" >/dev/null 2>&1

  if [ -f "$dest" ] && [ ! -L "$dest" ] && [ "$(cat "$dest")" = "original settings" ]; then
    pass "unlink_restores_pre_forge: original file restored"
  else
    fail "unlink_restores_pre_forge: original file not restored correctly"
  fi

  # .pre-forge should be gone (moved to dest)
  if [ ! -f "${dest}.pre-forge" ]; then
    pass "unlink_restores_pre_forge: .pre-forge consumed"
  else
    fail "unlink_restores_pre_forge: .pre-forge still exists after restore"
  fi
}

# 10. unlink on regular file -> no-op, log warning
test_unlink_noop_on_regular_file() {
  local tmp
  tmp="$(make_tmp)"
  local dest="$tmp/regular.txt"
  printf 'important content' > "$dest"

  local output
  output="$(forge_unlink "$dest" 2>&1 || true)"

  if [ -f "$dest" ] && [ "$(cat "$dest")" = "important content" ]; then
    pass "unlink_noop_on_regular_file: regular file untouched"
  else
    fail "unlink_noop_on_regular_file: regular file was modified or deleted"
  fi

  if echo "$output" | grep -qi "warning"; then
    pass "unlink_noop_on_regular_file: warning logged"
  else
    fail "unlink_noop_on_regular_file: no warning logged (got: $output)"
  fi
}

# 11. forge_symlink with dangling symlink at dest -> repoint to src
test_symlink_dangling_dest() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/source.txt"
  local dest="$tmp/link"
  echo "content" > "$src"
  # create dangling symlink: points to a path that does not exist
  ln -s "/nonexistent/path/$(date +%s)" "$dest"
  # verify preconditions
  if [ -e "$dest" ]; then
    fail "symlink_dangling_dest: precondition failed: dest should be dangling"
    return
  fi
  if [ ! -L "$dest" ]; then
    fail "symlink_dangling_dest: precondition failed: dest should be a symlink"
    return
  fi

  forge_symlink "$src" "$dest" >/dev/null 2>&1

  if [ -L "$dest" ]; then
    pass "symlink_dangling_dest: dest is a symlink after forge_symlink"
  else
    fail "symlink_dangling_dest: dest is not a symlink after forge_symlink"
  fi

  if [ "$(readlink "$dest")" = "$src" ]; then
    pass "symlink_dangling_dest: dest points to src"
  else
    fail "symlink_dangling_dest: dest points to wrong target (got: $(readlink "$dest"))"
  fi
}

# 12. forge_unlink when dest does not exist -> no-op, exit 0
test_unlink_nonexistent_dest() {
  local tmp
  tmp="$(make_tmp)"
  local dest="$tmp/nonexistent_link"
  # verify precondition: dest does not exist at all
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fail "unlink_nonexistent_dest: precondition failed: dest should not exist"
    return
  fi

  local result=0
  forge_unlink "$dest" >/dev/null 2>&1 || result=$?

  if [ "$result" -eq 0 ]; then
    pass "unlink_nonexistent_dest: forge_unlink returned 0 on nonexistent dest"
  else
    fail "unlink_nonexistent_dest: forge_unlink on nonexistent dest returned $result"
  fi
}

# 13. forge_unlink when dest is a symlink without .pre-forge backup -> remove symlink only
test_unlink_symlink_no_backup() {
  local tmp
  tmp="$(make_tmp)"
  local src="$tmp/original.txt"
  local dest="$tmp/link_no_backup"
  echo "content" > "$src"
  ln -s "$src" "$dest"
  # no .pre-forge backup created

  forge_unlink "$dest" >/dev/null 2>&1

  if [ ! -L "$dest" ]; then
    pass "unlink_symlink_no_backup: symlink removed after forge_unlink"
  else
    fail "unlink_symlink_no_backup: symlink still exists after forge_unlink"
  fi

  if [ ! -e "$dest" ]; then
    pass "unlink_symlink_no_backup: dest does not exist after forge_unlink"
  else
    fail "unlink_symlink_no_backup: dest still exists after forge_unlink"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== symlink_unit.sh ==="

run_test test_dest_missing
run_test test_dest_correct_symlink
run_test test_dest_wrong_symlink
run_test test_dest_regular_file
run_test test_dest_directory
run_test test_parent_missing
run_test test_relative_path_rejected
run_test test_unlink_removes_symlink
run_test test_unlink_restores_pre_forge
run_test test_unlink_noop_on_regular_file
run_test test_symlink_dangling_dest
run_test test_unlink_nonexistent_dest
run_test test_unlink_symlink_no_backup

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
