#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/release_skill_unit.sh — Behaviour tests for tools/release/update-changelog.sh
# and commit-release.sh.
# Verifies classification, scope stripping, additive behaviour, no-op handling,
# correct staging for patch/none bumps, argument validation, and the MR-DESCRIPTION.md
# gitignore contract.
# Compatible with bash 3.2+. No associative arrays, no mapfile, no $EPOCHSECONDS.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_MD="$FORGE_ROOT/.claude/skills/create-pr/SKILL.md"

UPDATE_CHANGELOG="$FORGE_ROOT/tools/release/update-changelog.sh"
COMMIT_RELEASE="$FORGE_ROOT/tools/release/commit-release.sh"

# Test harness
FAIL=0
PASS=0

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

# run_test captures exit code from each test; UC tests exit 0/1 from subshell.
# Simple tests (UC7, T4-T6) call pass/fail directly.
run_test() {
  local name="$1"
  echo "--- $name"
  set +e
  "$name"
  local ec=$?
  set -e
  if [ "$ec" -ne 0 ]; then
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
}

# =============================================================================
# UC1 — update-changelog classification
# =============================================================================
test_uc1_classification() {
  (
    TMPDIR_UC="$FORGE_ROOT/tests/.tmp/uc1_$$"
    mkdir -p "$TMPDIR_UC"
    trap 'rm -rf "$TMPDIR_UC"' EXIT
    cd "$TMPDIR_UC"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create initial commit on master with a CHANGELOG.md
    printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: init"

    # Create feature branch with 4 commits
    git checkout -q -b feature
    git commit -q --allow-empty -m "feat: add alpha"
    git commit -q --allow-empty -m "fix: patch beta"
    git commit -q --allow-empty -m "refactor: tidy gamma"
    git commit -q --allow-empty -m "chore: bump dep"

    set +e
    "$UPDATE_CHANGELOG" --branch master
    EC=$?
    set -e

    if [ "$EC" -ne 0 ]; then
      echo "  UC1 FAIL: update-changelog exited $EC, expected 0"
      exit 1
    fi

    CL="$(cat CHANGELOG.md)"

    # Assert Added section with alpha
    if ! printf '%s\n' "$CL" | grep -q -e '### Added'; then
      echo "  UC1 FAIL: ### Added section missing"
      exit 1
    fi
    if ! printf '%s\n' "$CL" | grep -q -e '- add alpha'; then
      echo "  UC1 FAIL: '- add alpha' missing"
      exit 1
    fi

    # Assert Fixed section with beta
    if ! printf '%s\n' "$CL" | grep -q -e '### Fixed'; then
      echo "  UC1 FAIL: ### Fixed section missing"
      exit 1
    fi
    if ! printf '%s\n' "$CL" | grep -q -e '- patch beta'; then
      echo "  UC1 FAIL: '- patch beta' missing"
      exit 1
    fi

    # Assert Changed section with gamma
    if ! printf '%s\n' "$CL" | grep -q -e '### Changed'; then
      echo "  UC1 FAIL: ### Changed section missing"
      exit 1
    fi
    if ! printf '%s\n' "$CL" | grep -q -e '- tidy gamma'; then
      echo "  UC1 FAIL: '- tidy gamma' missing"
      exit 1
    fi

    # Assert chore commit NOT included
    if printf '%s\n' "$CL" | grep -q 'bump dep'; then
      echo "  UC1 FAIL: 'bump dep' should be omitted (chore)"
      exit 1
    fi

    echo "  UC1 PASS: classification (Added/Fixed/Changed present, chore omitted)"
    exit 0
  )
}

# =============================================================================
# UC2 — update-changelog scope stripping
# =============================================================================
test_uc2_scope_stripping() {
  (
    TMPDIR_UC="$FORGE_ROOT/tests/.tmp/uc2_$$"
    mkdir -p "$TMPDIR_UC"
    trap 'rm -rf "$TMPDIR_UC"' EXIT
    cd "$TMPDIR_UC"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: init"

    git checkout -q -b feature
    git commit -q --allow-empty -m "feat(release): add delta"

    set +e
    "$UPDATE_CHANGELOG" --branch master
    EC=$?
    set -e

    if [ "$EC" -ne 0 ]; then
      echo "  UC2 FAIL: update-changelog exited $EC, expected 0"
      exit 1
    fi

    CL="$(cat CHANGELOG.md)"

    if ! printf '%s\n' "$CL" | grep -q -e '- add delta'; then
      echo "  UC2 FAIL: '- add delta' missing after scope stripping"
      exit 1
    fi

    if printf '%s\n' "$CL" | grep -q 'feat(release):'; then
      echo "  UC2 FAIL: 'feat(release):' prefix should be stripped"
      exit 1
    fi

    echo "  UC2 PASS: scope stripped, entry preserved"
    exit 0
  )
}

# =============================================================================
# UC3 — update-changelog additive (pre-existing content preserved)
# =============================================================================
test_uc3_additive() {
  (
    TMPDIR_UC="$FORGE_ROOT/tests/.tmp/uc3_$$"
    mkdir -p "$TMPDIR_UC"
    trap 'rm -rf "$TMPDIR_UC"' EXIT
    cd "$TMPDIR_UC"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    printf '# Changelog\n\n## [Unreleased]\n\n- pre-existing curated entry\n' > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: init"

    git checkout -q -b feature
    git commit -q --allow-empty -m "feat: new thing"

    set +e
    "$UPDATE_CHANGELOG" --branch master
    EC=$?
    set -e

    if [ "$EC" -ne 0 ]; then
      echo "  UC3 FAIL: update-changelog exited $EC, expected 0"
      exit 1
    fi

    CL="$(cat CHANGELOG.md)"

    if ! printf '%s\n' "$CL" | grep -q -e '- pre-existing curated entry'; then
      echo "  UC3 FAIL: pre-existing entry missing"
      exit 1
    fi

    if ! printf '%s\n' "$CL" | grep -q -e '- new thing'; then
      echo "  UC3 FAIL: new feat entry missing"
      exit 1
    fi

    echo "  UC3 PASS: pre-existing entry preserved, new entry added"
    exit 0
  )
}

# =============================================================================
# UC4 — update-changelog no-op (no commits beyond base)
# =============================================================================
test_uc4_noop() {
  (
    TMPDIR_UC="$FORGE_ROOT/tests/.tmp/uc4_$$"
    mkdir -p "$TMPDIR_UC"
    trap 'rm -rf "$TMPDIR_UC"' EXIT
    cd "$TMPDIR_UC"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    printf '# Changelog\n\n## [Unreleased]\n' > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "chore: init"

    ORIG="$(cat CHANGELOG.md)"

    # Stay on master — no extra commits, so range is empty
    set +e
    "$UPDATE_CHANGELOG" --branch master
    EC=$?
    set -e

    if [ "$EC" -ne 0 ]; then
      echo "  UC4 FAIL: update-changelog exited $EC, expected 0"
      exit 1
    fi

    AFTER="$(cat CHANGELOG.md)"
    if [ "$ORIG" != "$AFTER" ]; then
      echo "  UC4 FAIL: CHANGELOG.md was modified on no-op run"
      exit 1
    fi

    echo "  UC4 PASS: CHANGELOG.md unchanged on empty commit range"
    exit 0
  )
}

# =============================================================================
# UC5 — commit-release patch staging
# =============================================================================
test_uc5_patch_staging() {
  (
    TMPDIR_UC="$FORGE_ROOT/tests/.tmp/uc5_$$"
    mkdir -p "$TMPDIR_UC"
    trap 'rm -rf "$TMPDIR_UC"' EXIT
    cd "$TMPDIR_UC"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create initial tracked files
    printf '# Changelog\n' > CHANGELOG.md
    printf '#!/bin/bash\n# version 1.0.0\n' > install.sh
    mkdir -p .claude-plugin
    printf '{"version":"1.0.0"}\n' > .claude-plugin/plugin.json
    git add CHANGELOG.md install.sh .claude-plugin/plugin.json
    git commit -q -m "chore: init"

    # Modify the files (unstaged changes relative to HEAD)
    printf '# Changelog\n\n## [1.2.3]\n' > CHANGELOG.md
    printf '#!/bin/bash\n# version 1.2.3\n' > install.sh
    printf '{"version":"1.2.3"}\n' > .claude-plugin/plugin.json

    set +e
    "$COMMIT_RELEASE" patch v1.2.3
    EC=$?
    set -e

    if [ "$EC" -ne 0 ]; then
      echo "  UC5 FAIL: commit-release exited $EC, expected 0"
      exit 1
    fi

    SUBJ="$(git log --oneline -1 | cut -d' ' -f2-)"
    if [ "$SUBJ" != "chore(release): bump version to v1.2.3" ]; then
      echo "  UC5 FAIL: commit subject '$SUBJ' != 'chore(release): bump version to v1.2.3'"
      exit 1
    fi

    CHANGED_FILES="$(git diff-tree --no-commit-id --name-only -r HEAD)"

    if ! printf '%s\n' "$CHANGED_FILES" | grep -q 'CHANGELOG.md'; then
      echo "  UC5 FAIL: CHANGELOG.md not in commit"
      exit 1
    fi

    if ! printf '%s\n' "$CHANGED_FILES" | grep -q 'install.sh'; then
      echo "  UC5 FAIL: install.sh not in commit"
      exit 1
    fi

    if ! printf '%s\n' "$CHANGED_FILES" | grep -q '.claude-plugin/plugin.json'; then
      echo "  UC5 FAIL: .claude-plugin/plugin.json not in commit"
      exit 1
    fi

    echo "  UC5 PASS: CHANGELOG.md, install.sh, .claude-plugin/plugin.json staged for patch"
    exit 0
  )
}

# =============================================================================
# UC6 — commit-release none staging (no install.sh)
# =============================================================================
test_uc6_none_staging() {
  (
    TMPDIR_UC="$FORGE_ROOT/tests/.tmp/uc6_$$"
    mkdir -p "$TMPDIR_UC"
    trap 'rm -rf "$TMPDIR_UC"' EXIT
    cd "$TMPDIR_UC"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"

    printf '# Changelog\n' > CHANGELOG.md
    mkdir -p .claude-plugin
    printf '{"version":"1.0.0"}\n' > .claude-plugin/plugin.json
    git add CHANGELOG.md .claude-plugin/plugin.json
    git commit -q -m "chore: init"

    # Modify the files
    printf '# Changelog\n\n## [1.2.3]\n' > CHANGELOG.md
    printf '{"version":"1.2.3"}\n' > .claude-plugin/plugin.json

    # note: no v prefix — should be normalised by script
    set +e
    "$COMMIT_RELEASE" none 1.2.3
    EC=$?
    set -e

    if [ "$EC" -ne 0 ]; then
      echo "  UC6 FAIL: commit-release exited $EC, expected 0"
      exit 1
    fi

    SUBJ="$(git log --oneline -1 | cut -d' ' -f2-)"
    if [ "$SUBJ" != "chore(release): bump version to v1.2.3" ]; then
      echo "  UC6 FAIL: commit subject '$SUBJ' != 'chore(release): bump version to v1.2.3'"
      exit 1
    fi

    CHANGED_FILES="$(git diff-tree --no-commit-id --name-only -r HEAD)"

    if ! printf '%s\n' "$CHANGED_FILES" | grep -q 'CHANGELOG.md'; then
      echo "  UC6 FAIL: CHANGELOG.md not in commit"
      exit 1
    fi

    if ! printf '%s\n' "$CHANGED_FILES" | grep -q '.claude-plugin/plugin.json'; then
      echo "  UC6 FAIL: .claude-plugin/plugin.json not in commit"
      exit 1
    fi

    if printf '%s\n' "$CHANGED_FILES" | grep -q 'install.sh'; then
      echo "  UC6 FAIL: install.sh should NOT be in a BUMP=none commit"
      exit 1
    fi

    echo "  UC6 PASS: CHANGELOG.md and .claude-plugin/plugin.json staged, install.sh absent"
    exit 0
  )
}

# =============================================================================
# UC7 — commit-release arg validation
# =============================================================================
test_uc7_arg_validation() {
  # Bad BUMP value -> exit 2
  set +e
  "$COMMIT_RELEASE" bogus v1.2.3 2>/dev/null
  EC_BOGUS=$?
  set -e

  if [ "$EC_BOGUS" -eq 2 ]; then
    pass "UC7a — commit-release bogus BUMP exits 2"
  else
    fail "UC7a — commit-release bogus BUMP: expected exit 2, got $EC_BOGUS"
  fi

  # Bad version format -> exit 2
  set +e
  "$COMMIT_RELEASE" patch not-a-version 2>/dev/null
  EC_BADVER=$?
  set -e

  if [ "$EC_BADVER" -eq 2 ]; then
    pass "UC7b — commit-release bad version exits 2"
  else
    fail "UC7b — commit-release bad version: expected exit 2, got $EC_BADVER"
  fi
}

# =============================================================================
# T4 — PR-DESCRIPTION.md is a working artifact: gitignored and never tracked
# =============================================================================
test_mr_description_gitignored() {
  if grep -qxF 'PR-DESCRIPTION.md' "$FORGE_ROOT/.gitignore"; then
    pass ".gitignore contains PR-DESCRIPTION.md"
  else
    fail ".gitignore is missing the PR-DESCRIPTION.md entry"
  fi
}

test_mr_description_not_tracked() {
  if git -C "$FORGE_ROOT" ls-files --error-unmatch PR-DESCRIPTION.md >/dev/null 2>&1; then
    fail "PR-DESCRIPTION.md is tracked by git (it must never be committed)"
  else
    pass "PR-DESCRIPTION.md is not tracked by git"
  fi
}

test_skill_ensures_gitignore() {
  if grep -qF 'git rm --cached PR-DESCRIPTION.md' "$SKILL_MD"; then
    pass "create-pr skill ensures PR-DESCRIPTION.md stays untracked/gitignored"
  else
    fail "create-pr skill does not enforce the PR-DESCRIPTION.md gitignore contract"
  fi
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== release_skill_unit.sh ==="

# UC1-UC6: subshell tests — exit 0/1 used as pass/fail signal
run_test test_uc1_classification
run_test test_uc2_scope_stripping
run_test test_uc3_additive
run_test test_uc4_noop
run_test test_uc5_patch_staging
run_test test_uc6_none_staging

# UC7, T4-T6: simple tests — call pass/fail directly; run_test doesn't double-count them
echo "--- test_uc7_arg_validation"
test_uc7_arg_validation
echo "--- test_mr_description_gitignored"
test_mr_description_gitignored
echo "--- test_mr_description_not_tracked"
test_mr_description_not_tracked
echo "--- test_skill_ensures_gitignore"
test_skill_ensures_gitignore

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
