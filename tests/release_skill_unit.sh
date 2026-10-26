#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/release_skill_unit.sh — Behaviour tests for tools/release/update-changelog.sh
# and tools/release/commit-release.sh under the checkpoint / desired-state design.
#
# Kept from the previous revision (adapted to the new preconditions):
#   UC1 classification, UC2 scope stripping, UC3 preservation of pre-existing
#   content, UC4 no-op with an empty range, UC5 patch staging, UC6 none staging,
#   UC7 argument validation, T4-T6 PR-DESCRIPTION.md gitignore contract.
#
# Added as regression coverage for .plans/release-flow-checkpoint-idempotency.md:
#   R1 a second update-changelog run is a byte-identical no-op
#   R2 commit-release recovery after a failed commit (exit 4, index preserved)
#   R3 commit-release isolation from foreign staged content (exit 2, index intact)
#   R4 update-changelog refuses an unexpected third working-tree state (exit 2)
#
# Regression coverage added for the semantics that no suite asserted after the
# release-flow fix (each one was a dead branch before):
#   UR1 [Unreleased] is CREATED when the baseline has no such heading, after
#       the preamble and before the first released section
#   UR2 ...and when the baseline has no section at all
#   UR3 ...and when the baseline's last byte is not a newline
#   UR4 two releases on one branch merge into ONE '### <Kind>' per kind, in
#       canonical order — the case auto-tag.sh:138 sweeps into the tag
#   UR5 the same kind released twice appends instead of duplicating its heading
#   UR6 the superseded working-tree state is named as such (with the recovery
#       command) and stays distinct from a genuine hand edit
#   UR7 a merged subsection always closes on a real blank line
#
# Every case runs in its own throwaway git repository under
# $FORGE_TEST_SANDBOX (default /tmp/opencode/forge-release-tests). Nothing here
# touches the real forge working tree.
# Compatible with bash 3.2+. No associative arrays, no mapfile.
set -euo pipefail

# shellcheck source=tests/release_fixtures.sh
. "$(dirname "$0")/release_fixtures.sh"

FORGE_ROOT="$FORGE_TEST_ROOT"
SKILL_MD="$FORGE_ROOT/.claude/skills/create-pr/SKILL.md"

# Harness -------------------------------------------------------------------
FAIL=0
PASS=0

fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }

# Each test runs in a subshell and signals success with exit 0.
# The subshell is what keeps a stray `exit` inside a test body (see step)
# from tearing down the whole suite.
run_test() {
  local name="$1"
  echo "--- $name"
  set +e
  ( "$name" )
  local ec=$?
  set -e
  if [ "$ec" -ne 0 ]; then
    FAIL=$((FAIL + 1))
  else
    PASS=$((PASS + 1))
  fi
}

# Skip cases that drive commit-release.sh when jq is unavailable.
require_jq() {
  if ! tf_has_jq; then
    echo "  SKIP: jq is not available"
    exit 0
  fi
}

# step <fn> — run one subshell as a step of a multi-part test.
# run_test disables errexit around the test body, so a subshell that aborts
# via tf_fail would otherwise be swallowed by the next statement and the
# case would report PASS. Propagate the failure instead.
step() {
  local rc=0
  ( "$@" ) || rc=$?
  [ "$rc" -eq 0 ] || exit 1
}

# The closed release section, used to prove byte-for-byte preservation.
changelog_tail() {
  sed -n '/^## \[0\.7\.1\]/,$p' "$1"
}

# =============================================================================
# UC1 — update-changelog classification
# =============================================================================
test_uc1_classification() {
  (
    dir="$(forge_test_sandbox release_skill_unit.uc1)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat: add alpha"
    forge_commit "$dir" "fix: patch beta"
    forge_commit "$dir" "refactor: tidy gamma"
    forge_commit "$dir" "chore: bump dep"

    cd "$dir"
    "$UPDATE_CHANGELOG" --branch master || tf_fail "UC1 — update-changelog exited $?, expected 0"

    CL="$(cat CHANGELOG.md)"

    tf_contains "$CL" '### Added'   "UC1 — Added section"
    tf_contains "$CL" '- add alpha' "UC1 — Added entry"
    tf_contains "$CL" '### Fixed'   "UC1 — Fixed section"
    tf_contains "$CL" '- patch beta' "UC1 — Fixed entry"
    tf_contains "$CL" '### Changed' "UC1 — Changed section"
    tf_contains "$CL" '- tidy gamma' "UC1 — Changed entry"
    tf_not_contains "$CL" 'bump dep' "UC1 — chore commits are not user-facing"

    # Regression: exactly one block, one entry per commit, one heading.
    tf_count "$dir/CHANGELOG.md" '- add alpha'  1 "UC1 — one Added bullet per commit"
    tf_count "$dir/CHANGELOG.md" '- patch beta' 1 "UC1 — one Fixed bullet per commit"
    tf_count "$dir/CHANGELOG.md" '- tidy gamma' 1 "UC1 — one Changed bullet per commit"
    tf_count "$dir/CHANGELOG.md" '## [Unreleased]' 1 "UC1 — single [Unreleased] heading"

    echo "  UC1 PASS: classification (Added/Fixed/Changed present, chore omitted, single insertion)"
  )
}

# =============================================================================
# UC2 — update-changelog scope stripping
# =============================================================================
test_uc2_scope_stripping() {
  (
    dir="$(forge_test_sandbox release_skill_unit.uc2)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat(release): add delta"

    cd "$dir"
    "$UPDATE_CHANGELOG" --branch master || tf_fail "UC2 — update-changelog exited $?, expected 0"

    CL="$(cat CHANGELOG.md)"
    tf_contains "$CL" '- add delta' "UC2 — scoped subject is recorded"
    tf_not_contains "$CL" 'feat(release):' "UC2 — scope prefix must be stripped"

    echo "  UC2 PASS: scope stripped, entry preserved"
  )
}

# =============================================================================
# UC3 — update-changelog preserves everything that is not the insertion point
# =============================================================================
test_uc3_additive() {
  (
    dir="$(forge_test_sandbox release_skill_unit.uc3)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1
    # Curated, already-reviewed content inside [Unreleased].
    cat > "$dir/CHANGELOG.md" <<'EOF'
# Forge — Changelog

## [Unreleased]

- pre-existing curated entry

## [0.7.1] - 2026-01-01

### Added
- initial release
EOF
    git -C "$dir" add CHANGELOG.md
    git -C "$dir" commit -q --amend --no-edit
    original_tail="$(changelog_tail "$dir/CHANGELOG.md")"

    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat: new thing"

    cd "$dir"
    "$UPDATE_CHANGELOG" --branch master || tf_fail "UC3 — update-changelog exited $?, expected 0"

    CL="$(cat CHANGELOG.md)"
    tf_count "$dir/CHANGELOG.md" '- pre-existing curated entry' 1 "UC3 — curated entry preserved once"
    tf_count "$dir/CHANGELOG.md" '- new thing' 1 "UC3 — new entry added once"
    tf_eq "$(changelog_tail "$dir/CHANGELOG.md")" "$original_tail" \
      "UC3 — historical section must be preserved byte for byte"

    echo "  UC3 PASS: pre-existing entry preserved, new entry added, history untouched"
  )
}

# =============================================================================
# UC4 — update-changelog no-op (no commits beyond base)
# =============================================================================
test_uc4_noop() {
  (
    dir="$(forge_test_sandbox release_skill_unit.uc4)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1

    cd "$dir"
    before="$(git show HEAD:CHANGELOG.md)"

    "$UPDATE_CHANGELOG" --branch master || tf_fail "UC4 — update-changelog exited $?, expected 0"

    tf_eq "$(cat CHANGELOG.md)" "$before" "UC4 — CHANGELOG.md must be untouched"
    tf_eq "$(git status --porcelain -- CHANGELOG.md)" "" "UC4 — CHANGELOG.md must stay clean"

    echo "  UC4 PASS: CHANGELOG.md unchanged on empty commit range"
  )
}

# =============================================================================
# UC5 — commit-release patch staging
# =============================================================================
test_uc5_patch_staging() {
  (
    dir="$(forge_test_sandbox release_skill_unit.uc5)"
    trap 'rm -rf "$dir"' EXIT
    if ! tf_has_jq; then echo "  SKIP: jq is not available"; exit 0; fi

    forge_new_repo "$dir" 1.0.0
    forge_new_branch "$dir" feature

    forge_write_version "$dir" 1.2.3
    cat > "$dir/CHANGELOG.md" <<'EOF'
# Forge — Changelog

## [Unreleased]

### Fixed
- repair the other
EOF

    cd "$dir"
    "$COMMIT_RELEASE" patch v1.2.3 || tf_fail "UC5 — commit-release exited $?, expected 0"

    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v1.2.3" "UC5 — commit subject"
    tf_eq "$(forge_files_in_commit "$dir")" "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md\ninstall.sh')" \
      "UC5 — commit must contain exactly the release artifacts"

    echo "  UC5 PASS: CHANGELOG.md, install.sh, .claude-plugin/plugin.json committed for patch"
  )
}

# =============================================================================
# UC6 — commit-release none staging (no install.sh)
# =============================================================================
test_uc6_none_staging() {
  (
    dir="$(forge_test_sandbox release_skill_unit.uc6)"
    trap 'rm -rf "$dir"' EXIT
    if ! tf_has_jq; then echo "  SKIP: jq is not available"; exit 0; fi

    mkdir -p "$dir/.claude-plugin"
    git init -q "$dir"
    git -C "$dir" symbolic-ref HEAD refs/heads/master
    git -C "$dir" config user.email "forge-tests@test.invalid"
    git -C "$dir" config user.name "Forge Tests"
    printf '# Forge — Changelog\n\n## [Unreleased]\n' > "$dir/CHANGELOG.md"
    printf '{\n  "name": "forge",\n  "version": "1.0.0"\n}\n' > "$dir/.claude-plugin/plugin.json"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "chore: base"

    printf '# Forge — Changelog\n\n## [Unreleased]\n\n### Fixed\n- repair the other\n' > "$dir/CHANGELOG.md"
    printf '{\n  "name": "forge",\n  "version": "1.2.3"\n}\n' > "$dir/.claude-plugin/plugin.json"

    cd "$dir"
    # no v prefix — normalised by the script
    "$COMMIT_RELEASE" none 1.2.3 || tf_fail "UC6 — commit-release exited $?, expected 0"

    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v1.2.3" "UC6 — commit subject"
    tf_eq "$(forge_files_in_commit "$dir")" "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md')" \
      "UC6 — install.sh must not be part of a BUMP=none commit"

    echo "  UC6 PASS: CHANGELOG.md and .claude-plugin/plugin.json committed, install.sh absent"
  )
}

# =============================================================================
# UC7 — commit-release arg validation
# =============================================================================
test_uc7_arg_validation() {
  (
    dir="$(forge_test_sandbox release_skill_unit.uc7)"
    trap 'rm -rf "$dir"' EXIT
    forge_new_repo "$dir" 0.7.1
    cd "$dir"

    # Bad BUMP value -> exit 2
    "$COMMIT_RELEASE" bogus v1.2.3 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "2" "UC7a — commit-release bogus BUMP exits 2"

    # Bad version format -> exit 2
    "$COMMIT_RELEASE" patch not-a-version 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "2" "UC7b — commit-release bad version exits 2"

    # Missing version -> exit 2
    "$COMMIT_RELEASE" patch 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "2" "UC7c — commit-release without NEXT exits 2"

    tf_eq "$(git log -1 --format=%s)" "chore: base" "UC7 — no commit may be created"
    tf_clean_release_artifacts "$dir" "UC7 — rejected args"

    echo "  UC7 PASS: bad BUMP, bad version and missing version all exit 2"
  )
}

# =============================================================================
# R1 — a second update-changelog run is a byte-identical no-op
# =============================================================================
test_r1_changelog_second_run_is_noop() {
  (
    dir="$(forge_test_sandbox release_skill_unit.r1)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat: add alpha"
    forge_commit "$dir" "fix: patch beta"

    cd "$dir"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "R1 — first run exited $?, expected 0"
    first="$(git hash-object CHANGELOG.md)"

    out="$("$UPDATE_CHANGELOG" --branch master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "0" "R1 — second run must succeed (resume no-op)"
    tf_contains "$out" "no-op" "R1 — second run must report the no-op path"
    tf_eq "$(git hash-object CHANGELOG.md)" "$first" "R1 — bytes must be identical"

    # A third run, with an unrelated artifact touched meanwhile, is still a no-op.
    forge_touch "$dir" src/unrelated.txt "no toca el changelog"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "R1 — third run exited $?, expected 0"
    tf_eq "$(git hash-object CHANGELOG.md)" "$first" "R1 — bytes still identical"
    tf_count "$dir/CHANGELOG.md" '- add alpha' 1 "R1 — Added bullet not duplicated"

    echo "  R1 PASS: repeated update-changelog runs converge to the same bytes"
  )
}

# =============================================================================
# R2 — commit-release recovery after a failed commit
# =============================================================================
test_r2_recovery_after_failed_commit() {
  (
    dir="$(forge_test_sandbox release_skill_unit.r2)"
    trap 'rm -rf "$dir"' EXIT
    if ! tf_has_jq; then echo "  SKIP: jq is not available"; exit 0; fi

    forge_new_repo "$dir" 1.0.0
    forge_new_branch "$dir" feature
    forge_write_version "$dir" 1.0.1
    cat > "$dir/CHANGELOG.md" <<'EOF'
# Forge — Changelog

## [Unreleased]

### Fixed
- repair the other
EOF

    cd "$dir"
    forge_install_failing_hook "$dir"
    "$COMMIT_RELEASE" patch v1.0.1 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "4" "R2 — a failing hook must yield exit 4"

    tf_eq "$(git log -1 --format=%s)" "chore: base" "R2 — HEAD must not move"
    staged="$(git diff --cached --name-only | LC_ALL=C sort | tr '\n' ' ')"
    tf_eq "$staged" ".claude-plugin/plugin.json CHANGELOG.md install.sh " \
      "R2 — the index must stay reusable for the next run"

    # Same state, hook removed: the retry commits exactly the same artifacts.
    forge_remove_hook "$dir"
    "$COMMIT_RELEASE" patch v1.0.1 >/dev/null \
      || tf_fail "R2 — retry exited $?, expected 0"
    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v1.0.1" "R2 — retry subject"
    tf_eq "$(forge_files_in_commit "$dir")" "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md\ninstall.sh')" \
      "R2 — retry commits exactly the release artifacts"
    tf_count "$dir/CHANGELOG.md" '- repair the other' 1 "R2 — changelog block not duplicated"

    echo "  R2 PASS: exit 4 keeps the index; the retry commits the same artifacts"
  )
}

# =============================================================================
# R3 — commit-release refuses foreign staged content and leaves the index alone
# =============================================================================
test_r3_foreign_staged_isolation() {
  (
    dir="$(forge_test_sandbox release_skill_unit.r3)"
    trap 'rm -rf "$dir"' EXIT
    if ! tf_has_jq; then echo "  SKIP: jq is not available"; exit 0; fi

    forge_new_repo "$dir" 1.0.0
    forge_new_branch "$dir" feature
    forge_write_version "$dir" 1.0.1
    cat > "$dir/CHANGELOG.md" <<'EOF'
# Forge — Changelog

## [Unreleased]

### Fixed
- repair the other
EOF
    # Unrelated work already staged by the caller.
    forge_touch "$dir" docs/notes.md "not a release artifact"
    # Untracked noise must be tolerated and never swept in.
    printf 'scratch\n' > "$dir/untracked.txt"

    cd "$dir"
    err="$("$COMMIT_RELEASE" patch v1.0.1 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "R3 — foreign staged content must exit 2 (got: $err)"
    tf_contains "$err" 'docs/notes.md' "R3 — diagnostic must list the foreign path"

    tf_eq "$(git log -1 --format=%s)" "chore: base" "R3 — HEAD must not move"
    tf_eq "$(git diff --cached --name-only)" "docs/notes.md" \
      "R3 — the index must be left exactly as it was found"
    tf_eq "$(git status --porcelain -- untracked.txt)" "?? untracked.txt" \
      "R3 — untracked content stays untracked"
    [ -f "$dir/untracked.txt" ] || tf_fail "R3 — untracked file was removed"

    # Once the caller unstages it, the flow completes.
    git restore --staged -- docs/notes.md
    "$COMMIT_RELEASE" patch v1.0.1 >/dev/null \
      || tf_fail "R3 — release after unstaging exited $?, expected 0"
    tf_eq "$(forge_files_in_commit "$dir")" "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md\ninstall.sh')" \
      "R3 — the foreign path must not travel in the release commit"

    echo "  R3 PASS: foreign staged content rejected, index untouched, commit stays isolated"
  )
}

# =============================================================================
# R4 — update-changelog refuses an unexpected third state
# =============================================================================
test_r4_unexpected_changelog_state_is_rejected() {
  (
    dir="$(forge_test_sandbox release_skill_unit.r4)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat: add alpha"

    cd "$dir"
    # A hand edit that is neither the HEAD baseline nor the desired state.
    cat >> CHANGELOG.md <<'EOF'

## [WIP] notas manuales
EOF
    before="$(git hash-object CHANGELOG.md)"

    err="$("$UPDATE_CHANGELOG" --branch master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "R4 — an unexpected working tree state must exit 2 (got: $err)"
    tf_contains "$err" "refusing to overwrite" "R4 — diagnostic must explain the refusal"
    tf_eq "$(git hash-object CHANGELOG.md)" "$before" "R4 — the manual edit must survive"

    echo "  R4 PASS: manual CHANGELOG.md edits are rejected, never silently overwritten"
  )
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
# UR1 — the baseline has no [Unreleased] heading: it is CREATED
#
# Every fixture built by forge_default_changelog already carries the heading,
# so without this case the create_unreleased branch of the renderer is dead
# code. The new section must land AFTER the document preamble and BEFORE the
# first released section, and the history must survive byte for byte.
# =============================================================================
test_ur1_create_unreleased_before_first_release() {
  (
    dir="$(forge_test_sandbox release_skill_unit.ur1)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo_with_changelog "$dir" 0.7.1 < <(forge_changelog_no_unreleased 0.7.1)
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat(pin): primer proveedor"
    forge_commit "$dir" "fix(cli): segundo arreglo"

    history_tail="$(sed -n '/^## \[0\.7\.1\]/,$p' "$dir/CHANGELOG.md")"
    cd "$dir"

    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR1 — update-changelog exited $?, expected 0"

    tf_count "$dir/CHANGELOG.md" '## [Unreleased]' 1 \
      "UR1 — exactly one [Unreleased] heading is created"
    tf_count "$dir/CHANGELOG.md" '### Added' 2 \
      "UR1 — the created [Unreleased] adds one '### Added' next to the historical one"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 \
      "UR1 — the created section owns a single '### Added'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 \
      "UR1 — the created section owns a single '### Fixed'"
    tf_unreleased_order "$dir/CHANGELOG.md" '### Added' '### Fixed' \
      "UR1 — canonical order inside the created section"

    # Structural: preamble < [Unreleased] < first released section.
    tf_appears_before "$dir/CHANGELOG.md" \
      'All notable changes to this project' '## [Unreleased]' \
      "UR1 — the new section must not swallow the preamble"
    tf_appears_before "$dir/CHANGELOG.md" \
      '## [Unreleased]' '## [0.7.1]' \
      "UR1 — the new section must come before the first released section"

    tf_contains "$(cat "$dir/CHANGELOG.md")" '- primer proveedor' "UR1 — Added bullet"
    tf_contains "$(cat "$dir/CHANGELOG.md")" '- segundo arreglo'   "UR1 — Fixed bullet"
    tf_blank_line_follows "$dir/CHANGELOG.md" '- segundo arreglo' \
      "UR1 — the created block must close on a real blank line"
    tf_eq "$(sed -n '/^## \[0\.7\.1\]/,$p' "$dir/CHANGELOG.md")" "$history_tail" \
      "UR1 — the historical section must survive byte for byte"

    # Re-running must converge: the created section is now an ordinary one.
    first="$(git hash-object CHANGELOG.md)"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR1 — second run exited $?, expected 0"
    tf_eq "$(git hash-object CHANGELOG.md)" "$first" \
      "UR1 — re-running over the created section must change no byte"

    echo "  UR1 PASS: [Unreleased] is created after the preamble, before the history"
  )
}

# =============================================================================
# UR2 — the baseline is a preamble with no section at all
# =============================================================================
test_ur2_create_unreleased_with_preamble_only() {
  (
    dir="$(forge_test_sandbox release_skill_unit.ur2)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo_with_changelog "$dir" 0.7.1 < <(forge_changelog_preamble_only)
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat(pin): primer proveedor"
    forge_commit "$dir" "fix(cli): segundo arreglo"

    cd "$dir"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR2 — update-changelog exited $?, expected 0"

    tf_count "$dir/CHANGELOG.md" '## [Unreleased]' 1 \
      "UR2 — exactly one [Unreleased] heading"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 "UR2 — single '### Added'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 "UR2 — single '### Fixed'"
    tf_unreleased_order "$dir/CHANGELOG.md" '### Added' '### Fixed' \
      "UR2 — canonical order inside the created section"
    tf_appears_before "$dir/CHANGELOG.md" \
      'All notable changes to this project' '## [Unreleased]' \
      "UR2 — the preamble must stay above the created section"
    tf_contains "$(cat "$dir/CHANGELOG.md")" '- primer proveedor' "UR2 — Added bullet"
    tf_contains "$(cat "$dir/CHANGELOG.md")" '- segundo arreglo'   "UR2 — Fixed bullet"
    tf_ends_with_newline "$dir/CHANGELOG.md" \
      "UR2 — a sectionless document must still render newline-terminated"

    first="$(git hash-object CHANGELOG.md)"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR2 — second run exited $?, expected 0"
    tf_eq "$(git hash-object CHANGELOG.md)" "$first" \
      "UR2 — re-running must change no byte"

    echo "  UR2 PASS: [Unreleased] is created on a document that had no section"
  )
}

# =============================================================================
# UR3 — the baseline's last section has NO trailing newline
# =============================================================================
test_ur3_baseline_without_trailing_newline() {
  (
    dir="$(forge_test_sandbox release_skill_unit.ur3)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo_with_changelog "$dir" 0.7.1 \
      < <(forge_changelog_without_trailing_newline 0.7.1)
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat(pin): primer proveedor"

    cd "$dir"
    [ "$(tail -c 1 CHANGELOG.md)" != "" ] \
      || tf_fail "UR3 — the baseline fixture must lack a trailing newline"

    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR3 — update-changelog exited $?, expected 0"

    tf_count "$dir/CHANGELOG.md" '## [Unreleased]' 1 "UR3 — one [Unreleased] heading"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 "UR3 — single '### Added'"
    tf_contains "$(cat "$dir/CHANGELOG.md")" '- primer proveedor' "UR3 — Added bullet"
    tf_count "$dir/CHANGELOG.md" '- initial release' 1 "UR3 — the historical bullet"
    tf_blank_line_follows "$dir/CHANGELOG.md" '- primer proveedor' \
      "UR3 — the inserted block must close on a real blank line"
    tf_ends_with_newline "$dir/CHANGELOG.md" \
      "UR3 — the rendered document must be newline-terminated"

    # The historical tail keeps its content; only the EOF newline is added.
    tf_eq "$(sed -n '/^## \[0\.7\.1\]/,$p' "$dir/CHANGELOG.md")" \
      "$(printf '## [0.7.1] - 2026-01-01\n\n### Added\n- initial release')" \
      "UR3 — the historical section content must be preserved"

    first="$(git hash-object CHANGELOG.md)"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR3 — second run exited $?, expected 0"
    tf_eq "$(git hash-object CHANGELOG.md)" "$first" \
      "UR3 — re-running must change no byte"

    echo "  UR3 PASS: a baseline without a trailing newline renders and converges"
  )
}

# =============================================================================
# UR4 — two releases on the same branch merge into ONE subsection per kind
#
# This is the highest-risk case of the whole flow: auto-tag.sh:138 sweeps the
# whole [Unreleased] block into the tag when the release is published, so a
# duplicated "### <Kind>" heading ships a malformed release section. The
# assertions are structural (heading counts and order inside the block), not
# just about bullet content.
# =============================================================================
ur4_added_then_fixed_body() {
  (
    dir="$(forge_test_sandbox release_skill_unit.ur4a)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat(pin): primer proveedor"
    forge_release_once "$dir" master minor v0.8.0 \
      || tf_fail "UR4 — the first release pass failed"

    # The first release leaves [Unreleased] populated (the tag has not been
    # published yet), which is exactly what the second run must merge into.
    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 \
      "UR4 — after the first release [Unreleased] holds one '### Added'"

    forge_commit "$dir" "fix(cli): segundo arreglo"
    forge_release_once "$dir" master patch v0.8.1 \
      || tf_fail "UR4 — the second release pass failed"

    tf_count "$dir/CHANGELOG.md" '## [Unreleased]' 1 \
      "UR4 — two releases must leave a single [Unreleased] heading"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 \
      "UR4 — the second release must NOT create a second '### Added'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 \
      "UR4 — the second release must create exactly one '### Fixed'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Changed' 0 \
      "UR4 — no '### Changed' may appear for a feat+fix pair"
    tf_unreleased_order "$dir/CHANGELOG.md" '### Added' '### Fixed' \
      "UR4 — canonical order Added -> Fixed inside [Unreleased]"

    CL="$(cat "$dir/CHANGELOG.md")"
    tf_contains "$CL" '- primer proveedor' "UR4 — the first release bullet survives"
    tf_contains "$CL" '- segundo arreglo'   "UR4 — the second release bullet is added"
    tf_count "$dir/CHANGELOG.md" '- primer proveedor' 1 "UR4 — first bullet once"
    tf_count "$dir/CHANGELOG.md" '- segundo arreglo'   1 "UR4 — second bullet once"

    # The whole file carries one more '### Added' than the block does: the one
    # inside the closed 0.7.1 release. Any extra one would be a duplicated
    # heading created by the merge.
    tf_count "$dir/CHANGELOG.md" '### Added' 2 \
      "UR4 — exactly one '### Added' inside [Unreleased] plus the historical one"
    tf_blank_line_follows "$dir/CHANGELOG.md" '- segundo arreglo' \
      "UR4 — the merged block must close on a real blank line"

    # The reason this case matters: at publication time auto-tag.sh:138
    # sweeps the whole [Unreleased] block into the tag verbatim, so a
    # duplicated heading here ships a malformed release section.
    tagged="$(mktemp)"
    swept="$(mktemp)"
    forge_autotag_closure "$dir/CHANGELOG.md" v0.8.2 > "$tagged"
    tf_eq "$(forge_unreleased_block "$tagged" | sed '1d' | tr -d '[:space:]')" "" \
      "UR4 — the closure must leave [Unreleased] empty (auto-tag skips on an empty one)"
    tf_count "$tagged" '## [0.8.2]' 1 "UR4 — exactly one new release heading"
    forge_release_section "$tagged" 0.8.2 > "$swept"
    tf_count "$swept" '### Added' 1 \
      "UR4 — the swept release section must carry one '### Added'"
    tf_count "$swept" '### Fixed' 1 \
      "UR4 — the swept release section must carry one '### Fixed'"
    tf_count "$swept" '- primer proveedor' 1 "UR4 — first bullet swept once"
    tf_count "$swept" '- segundo arreglo' 1 "UR4 — second bullet swept once"
    rm -f "$tagged" "$swept"
  )
}

# The mirror order: the first release lands a '### Fixed', the second one a
# '### Added'. The new heading has a LOWER canonical rank than the one already
# present, so it must be inserted BEFORE it instead of appended at the end.
ur4_fixed_then_added_body() {
  (
    dir="$(forge_test_sandbox release_skill_unit.ur4b)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_commit "$dir" "fix(cli): primer arreglo"
    forge_release_once "$dir" master patch v0.7.2 \
      || tf_fail "UR4b — the first release pass failed"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 \
      "UR4b — after the first release [Unreleased] holds one '### Fixed'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 0 \
      "UR4b — and no '### Added' yet"

    forge_commit "$dir" "feat(pin): segundo proveedor"
    forge_release_once "$dir" master minor v0.8.0 \
      || tf_fail "UR4b — the second release pass failed"

    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 \
      "UR4b — the second release creates exactly one '### Added'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 \
      "UR4b — the existing '### Fixed' is neither dropped nor duplicated"
    tf_unreleased_order "$dir/CHANGELOG.md" '### Added' '### Fixed' \
      "UR4b — a lower-rank heading must be inserted before the existing one"
    tf_count "$dir/CHANGELOG.md" '- primer arreglo' 1 "UR4b — first bullet preserved"
    tf_count "$dir/CHANGELOG.md" '- segundo proveedor' 1 "UR4b — second bullet added"

    # Same publication contract as UR4a.
    tagged="$(mktemp)"
    swept="$(mktemp)"
    forge_autotag_closure "$dir/CHANGELOG.md" v0.8.0 > "$tagged"
    forge_release_section "$tagged" 0.8.0 > "$swept"
    tf_count "$swept" '### Added' 1 "UR4b — swept section carries one '### Added'"
    tf_count "$swept" '### Fixed' 1 "UR4b — swept section carries one '### Fixed'"
    rm -f "$tagged" "$swept"
  )
}

test_ur4_two_releases_merge_into_one_subsection_each() {
  step ur4_added_then_fixed_body
  step ur4_fixed_then_added_body
  step ur4_merge_into_two_existing_subsections_body
  echo "  UR4 PASS: two releases on one branch yield one '### <Kind>' per kind, in canonical order"
}

# A pending bullet for a subsection that is NOT the last one forces the
# renderer to close that subsection mid-scan and append to it there.
ur4_merge_into_two_existing_subsections_body() {
  (
    dir="$(forge_test_sandbox release_skill_unit.ur4c)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo_with_changelog "$dir" 0.7.1 \
      < <(forge_changelog_existing_subsections 0.7.1)
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat(pin): proveedor nuevo"

    cd "$dir"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR4c — update-changelog exited $?, expected 0"

    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 "UR4c — one '### Added'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 "UR4c — one '### Fixed'"
    tf_unreleased_order "$dir/CHANGELOG.md" '### Added' '### Fixed' \
      "UR4c — canonical order is preserved"
    tf_appears_before "$dir/CHANGELOG.md" '- proveedor previo' '- proveedor nuevo' \
      "UR4c — the pending bullet is appended inside '### Added', not after '### Fixed'"
    tf_appears_before "$dir/CHANGELOG.md" '- proveedor nuevo' '- arreglo previo' \
      "UR4c — '### Fixed' keeps its own content after the merge"
    tf_count "$dir/CHANGELOG.md" '- proveedor previo' 1 "UR4c — curated Added bullet once"
    tf_count "$dir/CHANGELOG.md" '- proveedor nuevo'  1 "UR4c — pending Added bullet once"
    tf_count "$dir/CHANGELOG.md" '- arreglo previo'   1 "UR4c — curated Fixed bullet once"
    tf_blank_line_follows "$dir/CHANGELOG.md" '- arreglo previo' \
      "UR4c — the last subsection still closes on a real blank line"

    first="$(git hash-object CHANGELOG.md)"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "UR4c — second run exited $?, expected 0"
    tf_eq "$(git hash-object CHANGELOG.md)" "$first" "UR4c — re-run changes no byte"
  )
}

# =============================================================================
# UR5 — the same kind released twice must not duplicate its heading
#
# The sharpest form of the UR4 regression: both releases produce '### Added',
# so a renderer that appends a fresh heading instead of merging yields two
# identically named subsections under one [Unreleased].
# =============================================================================
test_ur5_repeated_kind_does_not_duplicate_heading() {
  (
    dir="$(forge_test_sandbox release_skill_unit.ur5)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_commit "$dir" "feat(pin): primer proveedor"
    forge_release_once "$dir" master minor v0.8.0 \
      || tf_fail "UR5 — the first release pass failed"

    forge_commit "$dir" "feat(cli): segundo proveedor"
    forge_release_once "$dir" master minor v0.9.0 \
      || tf_fail "UR5 — the second release pass failed"

    tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 \
      "UR5 — two feat releases must yield exactly one '### Added'"
    tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 0 \
      "UR5 — no '### Fixed' may appear for two feat releases"
    tf_count "$dir/CHANGELOG.md" '- primer proveedor' 1 "UR5 — first bullet once"
    tf_count "$dir/CHANGELOG.md" '- segundo proveedor' 1 "UR5 — second bullet once"

    # Both bullets live in the SAME subsection, oldest first.
    tf_unreleased_order "$dir/CHANGELOG.md" '- primer proveedor' '- segundo proveedor' \
      "UR5 — the merged bullets must be appended in commit order"

    echo "  UR5 PASS: a second feat appends to the existing '### Added' instead of duplicating it"
  )
}

# =============================================================================
# UR6 — the SUPERSEDED state is diagnosed as such, not as a manual edit
#
# Fourth state of the machine: the working tree holds exactly what a previous
# run wrote for an earlier point of the branch while new commits arrived since.
# The diagnostic must name that real cause and print the recovery command, and
# it must stay distinguishable from a genuine hand edit, which keeps the
# "refusing to overwrite" wording and is reported as a manual edit.
# =============================================================================
ur6_superseded_body() {
  dir="$(forge_test_sandbox release_skill_unit.ur6)"
  trap 'rm -rf "$dir"' EXIT

  forge_new_repo "$dir" 0.7.1
  forge_new_branch "$dir" feature
  forge_commit "$dir" "feat(pin): primer proveedor"

  cd "$dir"
  # Run 1 writes the block; the flow then dies before commit-release.
  "$UPDATE_CHANGELOG" --branch master >/dev/null \
    || tf_fail "UR6 — the first run exited $?, expected 0"
  superseded_hash="$(git hash-object CHANGELOG.md)"
  superseded_head="$(git rev-parse HEAD)"

  # A commit lands between the two runs: the pending set changed.
  forge_commit "$dir" "fix(cli): segundo arreglo"
  head_now="$(git rev-parse HEAD)"
  [ "$superseded_head" != "$head_now" ] || tf_fail "UR6 — the setup never moved HEAD"

  err="$("$UPDATE_CHANGELOG" --branch master 2>&1)" && rc=0 || rc=$?
  tf_eq "$rc" "2" "UR6 — a superseded state must exit 2 (got: $err)"

  # The real cause, not "manual edit".
  tf_contains "$err" "a previous run wrote" \
    "UR6 — the diagnostic must name the superseded state as the cause"
  tf_contains "$err" "is NOT a manual edit" \
    "UR6 — the diagnostic must explicitly deny a manual edit"
  tf_contains "$err" "commit(s) have arrived since that run" \
    "UR6 — the diagnostic must report how far the branch moved"
  tf_contains "$err" "valid resume" \
    "UR6 — the diagnostic must point at bump-version.sh's resume path"
  tf_not_contains "$err" "Treating it as a manual edit" \
    "UR6 — a superseded state must not be diagnosed as a manual edit"

  # The recovery command.
  tf_contains "$err" "recovery: git checkout -- CHANGELOG.md" \
    "UR6 — the diagnostic must print the recovery command"
  tf_contains "$err" "--branch master" \
    "UR6 — the recovery command must re-run this script against the base"

  # Nothing is ever overwritten, and nothing else moves.
  tf_eq "$(git hash-object CHANGELOG.md)" "$superseded_hash" \
    "UR6 — the superseded CHANGELOG must survive untouched"
  tf_count "$dir/CHANGELOG.md" '- primer proveedor' 1 "UR6 — first bullet untouched"
  tf_count "$dir/CHANGELOG.md" '- segundo arreglo' 0 "UR6 — the new bullet is not written"
  tf_eq "$(git rev-parse HEAD)" "$head_now" "UR6 — HEAD must not move"
  tf_nothing_staged "$dir" "UR6 — rejected run"

  # The advertised recovery is real, and it needs no further manual work.
  git checkout -- CHANGELOG.md
  "$UPDATE_CHANGELOG" --branch master >/dev/null \
    || tf_fail "UR6 — the advertised recovery exited $?, expected 0"
  tf_count_unreleased "$dir/CHANGELOG.md" '### Added' 1 "UR6 — recovered '### Added'"
  tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 "UR6 — recovered '### Fixed'"
  tf_count "$dir/CHANGELOG.md" '- segundo arreglo' 1 "UR6 — recovered the new bullet"
  tf_eq "$(git rev-parse HEAD)" "$head_now" \
    "UR6 — the recovery must not create a commit"
}

ur6_hand_edit_body() {
  dir="$(forge_test_sandbox release_skill_unit.ur6b)"
  trap 'rm -rf "$dir"' EXIT

  forge_new_repo "$dir" 0.7.1
  forge_new_branch "$dir" feature
  forge_commit "$dir" "feat(pin): primer proveedor"

  cd "$dir"
  printf '\n## [WIP] notas manuales\n' >> CHANGELOG.md
  hand_edit_hash="$(git hash-object CHANGELOG.md)"

  err="$("$UPDATE_CHANGELOG" --branch master 2>&1)" && rc=0 || rc=$?
  tf_eq "$rc" "2" "UR6 — a hand edit must still exit 2 (got: $err)"
  tf_contains "$err" "refusing to overwrite" \
    "UR6 — a hand edit keeps the 'refusing to overwrite' wording"
  tf_contains "$err" "Treating it as a manual edit" \
    "UR6 — a hand edit is reported as a manual edit"
  tf_contains "$err" "recovery: git checkout -- CHANGELOG.md" \
    "UR6 — a hand edit also prints the recovery command"
  tf_not_contains "$err" "a previous run wrote" \
    "UR6 — a hand edit must not claim a previous run wrote it"
  tf_eq "$(git hash-object CHANGELOG.md)" "$hand_edit_hash" \
    "UR6 — the hand edit must survive untouched"
  tf_nothing_staged "$dir" "UR6 — rejected run"
}

test_ur6_superseded_state_is_not_reported_as_manual_edit() {
  step ur6_superseded_body
  step ur6_hand_edit_body
  echo "  UR6 PASS: the superseded state is named as such and stays distinct from a hand edit"
}

# =============================================================================
# UR7 — a merged subsection closes on a REAL blank line
#
# Baseline shapes where '## [Unreleased]' is NOT followed by a blank line, so
# the renderer has to normalise the heading gap itself. The contract is that
# the last bullet of the block is never glued to the next content.
# =============================================================================
ur7_curated_body() {
  dir="$(forge_test_sandbox release_skill_unit.ur7a)"
  trap 'rm -rf "$dir"' EXIT

  # Glued heading, curated '### Fixed', a released section follows.
  forge_new_repo_with_changelog "$dir" 0.7.1 \
    < <(forge_changelog_glued_unreleased 0.7.1 curated)
  forge_new_branch "$dir" feature
  forge_commit "$dir" "fix(cli): arreglo nuevo"

  cd "$dir"
  # Guard the fixture itself: the whole point is the missing blank line.
  tf_eq "$(sed -n '3p' CHANGELOG.md)" '## [Unreleased]' \
    "UR7a — the fixture must place [Unreleased] on line 3"
  tf_eq "$(sed -n '4p' CHANGELOG.md)" '### Fixed' \
    "UR7a — the fixture must not have a blank line after the heading"

  "$UPDATE_CHANGELOG" --branch master >/dev/null \
    || tf_fail "UR7a — update-changelog exited $?, expected 0"

  tf_blank_line_follows "$dir/CHANGELOG.md" '## [Unreleased]' \
    "UR7a — the heading gap must be normalised with a blank line"
  tf_blank_line_follows "$dir/CHANGELOG.md" '- arreglo nuevo' \
    "UR7a — the merged bullet must not be glued to the next section"
  tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 \
    "UR7a — the curated '### Fixed' is merged, not duplicated"
  tf_count "$dir/CHANGELOG.md" '- curado previo' 1 "UR7a — curated bullet preserved"
  tf_count "$dir/CHANGELOG.md" '- arreglo nuevo' 1 "UR7a — new bullet appended"
  tf_appears_before "$dir/CHANGELOG.md" '- curado previo' '- arreglo nuevo' \
    "UR7a — the new bullet is appended after the curated one"
  tf_eq "$(sed -n '/^## \[0\.7\.1\]/,$p' "$dir/CHANGELOG.md")" \
    "$(printf '## [0.7.1] - 2026-01-01\n\n### Added\n- initial release')" \
    "UR7a — the historical section must survive byte for byte"

  first="$(git hash-object CHANGELOG.md)"
  "$UPDATE_CHANGELOG" --branch master >/dev/null \
    || tf_fail "UR7a — second run exited $?, expected 0"
  tf_eq "$(git hash-object CHANGELOG.md)" "$first" "UR7a — re-run changes no byte"
}

ur7_eof_body() {
  dir="$(forge_test_sandbox release_skill_unit.ur7b)"
  trap 'rm -rf "$dir"' EXIT

  # Glued heading, no managed subsection, nothing after it (EOF case).
  forge_new_repo_with_changelog "$dir" 0.7.1 \
    < <(forge_changelog_glued_unreleased 0.7.1 empty)
  forge_new_branch "$dir" feature
  forge_commit "$dir" "fix(cli): arreglo nuevo"

  cd "$dir"
  tf_eq "$(sed -n '4p' CHANGELOG.md)" '' \
    "UR7b — the fixture must be a heading with nothing after it"

  "$UPDATE_CHANGELOG" --branch master >/dev/null \
    || tf_fail "UR7b — update-changelog exited $?, expected 0"

  tf_blank_line_follows "$dir/CHANGELOG.md" '## [Unreleased]' \
    "UR7b — the heading gap must be normalised with a blank line"
  tf_count_unreleased "$dir/CHANGELOG.md" '### Fixed' 1 "UR7b — single '### Fixed'"
  tf_count "$dir/CHANGELOG.md" '- arreglo nuevo' 1 "UR7b — the bullet is written"
  tf_ends_with_newline "$dir/CHANGELOG.md" \
    "UR7b — the block must close on a blank line at EOF"

  first="$(git hash-object CHANGELOG.md)"
  "$UPDATE_CHANGELOG" --branch master >/dev/null \
    || tf_fail "UR7b — second run exited $?, expected 0"
  tf_eq "$(git hash-object CHANGELOG.md)" "$first" "UR7b — re-run changes no byte"
}

test_ur7_merged_block_closes_on_blank_line() {
  step ur7_curated_body
  step ur7_eof_body
  echo "  UR7 PASS: a glued baseline is normalised and every block closes on a real blank line"
}

# =============================================================================
# Run all
# =============================================================================
echo "=== release_skill_unit.sh ==="

run_test test_uc1_classification
run_test test_uc2_scope_stripping
run_test test_uc3_additive
run_test test_uc4_noop
run_test test_uc5_patch_staging
run_test test_uc6_none_staging
run_test test_uc7_arg_validation
run_test test_r1_changelog_second_run_is_noop
run_test test_r2_recovery_after_failed_commit
run_test test_r3_foreign_staged_isolation
run_test test_r4_unexpected_changelog_state_is_rejected
run_test test_ur1_create_unreleased_before_first_release
run_test test_ur2_create_unreleased_with_preamble_only
run_test test_ur3_baseline_without_trailing_newline
run_test test_ur4_two_releases_merge_into_one_subsection_each
run_test test_ur5_repeated_kind_does_not_duplicate_heading
run_test test_ur6_superseded_state_is_not_reported_as_manual_edit
run_test test_ur7_merged_block_closes_on_blank_line

echo "--- test_mr_description_gitignored"
test_mr_description_gitignored
echo "--- test_mr_description_not_tracked"
test_mr_description_not_tracked
echo "--- test_skill_ensures_gitignore"
test_skill_ensures_gitignore

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

[ "$FAIL" -gt 0 ] && exit 1
exit 0