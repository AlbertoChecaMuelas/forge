#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/release_flow_integration.sh — End-to-end coverage for the resumable
# release flow described in .plans/release-flow-checkpoint-idempotency.md:
#
#   bump-version.sh -> update-changelog.sh -> commit-release.sh
#
# Cases:
#   FL1 the whole sequence run twice in a row; the second run is a no-op
#       (BUMP=none, changelog bytes unchanged, commit-release exit 3, HEAD fixed)
#   FL2 an injected failure after the bump; the retry recomputes the same NEXT
#       and produces exactly one release commit
#   FL3 an injected failure after the changelog; the retry recognises the file
#       as already desired and never prepends a second block
#   FL4 an injected failure at the commit step (failing hook); the retry keeps
#       the index and the flow afterwards converges to a no-op
#   FL5 compatibility with a branch equivalent to 91b4229: a checkpoint commit
#       `chore(release): bump version to v0.7.2` followed by a non-versionable
#       tooling commit must yield BUMP=none CURRENT=0.7.2 NEXT=0.7.2 OTHERS=1
#
# Every case runs in its own throwaway git repository under $FORGE_TEST_SANDBOX
# (default /tmp/opencode/forge-release-tests). Nothing here touches the real
# forge working tree.
# Compatible with bash 3.2+. No associative arrays, no mapfile.
set -euo pipefail

# shellcheck source=release_fixtures.sh
. "$(dirname "$0")/release_fixtures.sh"

# Harness -------------------------------------------------------------------
FAIL=0
PASS=0

fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }

# Each test runs in a subshell and signals success with exit 0.
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

require_jq() {
  if ! tf_has_jq; then
    echo "  SKIP: jq is not available"
    exit 0
  fi
}

# forge_checkpoint_count <dir> -> how many release checkpoints the branch has
forge_checkpoint_count() {
  git -C "$1" log --format=%s \
    | grep -c '^chore(release): bump version to v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' \
    || true
}

# forge_install_version <dir>
forge_install_version() {
  grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$1/install.sh" \
    | head -n 1 | sed -E 's/^FORGE_VERSION="([^"]+)"$/\1/'
}

# forge_changelog_tail <file> — everything from the closed 0.1.0 release on
forge_changelog_tail() {
  sed -n '/^## \[0\.1\.0\]/,$p' "$1"
}

# run_release_flow — bump, changelog and commit in one go. Must be called with
# the sandbox repo as CWD. Leaves BUMP/NEXT in globals.
run_release_flow() {
  local base="${1:-master}"
  FLOW_OUT="$("$BUMP_VERSION" --base "$base")"
  FLOW_BUMP="$(forge_release_field "$FLOW_OUT" BUMP)"
  FLOW_NEXT="$(forge_release_field "$FLOW_OUT" NEXT)"
  "$UPDATE_CHANGELOG" --branch "$base" >/dev/null
  "$COMMIT_RELEASE" "$FLOW_BUMP" "v${FLOW_NEXT}" >/dev/null
}

# setup_standard_repo <dir> [version] — base plus a feat + fix on `feature`
setup_standard_repo() {
  forge_new_repo "$1" "${2:-0.1.0}"
  forge_new_branch "$1" feature
  forge_touch "$1" src/opencode.sh "echo pinned"
  git -C "$1" commit -q -m "feat(opencode): pin del proveedor"
  forge_commit "$1" "fix(opencode): regresión de pin"
}

# =============================================================================
# FL1 — the full sequence run twice in a row
# =============================================================================
test_fl1_flow_twice_second_is_noop() {
  (
    dir="$(forge_test_sandbox release_flow_integration.fl1)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    setup_standard_repo "$dir"
    history_tail="$(forge_changelog_tail "$dir/CHANGELOG.md")"

    cd "$dir"
    # --- first invocation -------------------------------------------------
    run_release_flow
    tf_eq "$FLOW_BUMP" "minor" "FL1 — first run bump policy"
    tf_eq "$FLOW_NEXT" "0.2.0" "FL1 — first run NEXT"

    first_head="$(git rev-parse HEAD)"
    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v0.2.0" \
      "FL1 — first run creates the checkpoint"
    tf_eq "$(forge_files_in_commit "$dir")" \
      "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md\ninstall.sh')" \
      "FL1 — the release commit is limited to the release artifacts"
    tf_eq "$(forge_install_version "$dir")" "0.2.0" "FL1 — install.sh"
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "0.2.0" "FL1 — manifest"
    tf_count "$dir/CHANGELOG.md" '- pin del proveedor' 1 "FL1 — Added bullet"
    tf_count "$dir/CHANGELOG.md" '- regresión de pin' 1 "FL1 — Fixed bullet"
    tf_eq "$(forge_changelog_tail "$dir/CHANGELOG.md")" "$history_tail" \
      "FL1 — historical changelog preserved byte for byte"

    changelog_hash="$(git hash-object CHANGELOG.md)"

    # --- second invocation, immediately, without any push ------------------
    out="$("$BUMP_VERSION" --base master)"
    tf_eq "$out" "BUMP=none  CURRENT=0.2.0  NEXT=0.2.0  FEATS=0  FIXES=0  OTHERS=0" \
      "FL1 — second run must find the checkpoint and bump nothing"

    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "FL1 — second update-changelog exited $?, expected 0"
    tf_eq "$(git hash-object CHANGELOG.md)" "$changelog_hash" \
      "FL1 — second update-changelog must not change any byte"

    "$COMMIT_RELEASE" none v0.2.0 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "3" "FL1 — second commit-release must report nothing to commit"

    tf_eq "$(git rev-parse HEAD)" "$first_head" "FL1 — HEAD must not move"
    tf_eq "$(forge_checkpoint_count "$dir")" "1" "FL1 — no second release commit"
    tf_clean_release_artifacts "$dir" "FL1 — after the second invocation"
    tf_count "$dir/CHANGELOG.md" '- pin del proveedor' 1 "FL1 — bullet still not duplicated"

    echo "  FL1 PASS: full flow is idempotent; the second invocation is a pure no-op"
  )
}

# =============================================================================
# FL2 — injected failure between the bump and the changelog
# =============================================================================
test_fl2_failure_after_bump_is_resumable() {
  (
    dir="$(forge_test_sandbox release_flow_integration.fl2)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    setup_standard_repo "$dir"
    head_before="$(git -C "$dir" rev-parse HEAD)"

    cd "$dir"
    # The flow dies right after bump-version wrote the artifacts.
    "$BUMP_VERSION" --base master >/dev/null \
      || tf_fail "FL2 — bump exited $?, expected 0"
    tf_eq "$(forge_install_version "$dir")" "0.2.0" "FL2 — artifacts bumped to NEXT"
    tf_eq "$(git rev-parse HEAD)" "$head_before" "FL2 — nothing committed yet"

    # Retry from scratch: the working tree already holds NEXT, so the value
    # must not be incremented again.
    out="$("$BUMP_VERSION" --base master)"
    tf_eq "$out" "BUMP=minor  CURRENT=0.1.0  NEXT=0.2.0  FEATS=1  FIXES=1  OTHERS=0" \
      "FL2 — the retry must recompute the same NEXT from the anchor"
    tf_eq "$(forge_install_version "$dir")" "0.2.0" "FL2 — install.sh must not reach 0.3.0"
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "0.2.0" \
      "FL2 — manifest must not reach 0.3.0"

    # Finish the flow.
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "FL2 — update-changelog exited $?, expected 0"
    "$COMMIT_RELEASE" minor v0.2.0 >/dev/null \
      || tf_fail "FL2 — commit-release exited $?, expected 0"

    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v0.2.0" \
      "FL2 — resumed flow creates the expected checkpoint"
    tf_eq "$(forge_checkpoint_count "$dir")" "1" "FL2 — exactly one release commit"
    tf_count "$dir/CHANGELOG.md" '- pin del proveedor' 1 "FL2 — Added bullet once"

    # And the flow is now stable.
    out="$("$BUMP_VERSION" --base master --dry-run)"
    tf_eq "$out" "BUMP=none  CURRENT=0.2.0  NEXT=0.2.0  FEATS=0  FIXES=0  OTHERS=0" \
      "FL2 — post-resume run is a no-op"
    echo "  FL2 PASS: failure after the bump resumes at the same version, one commit"
  )
}

# =============================================================================
# FL3 — injected failure between the changelog and the commit
# =============================================================================
test_fl3_failure_after_changelog_is_resumable() {
  (
    dir="$(forge_test_sandbox release_flow_integration.fl3)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    setup_standard_repo "$dir"
    history_tail="$(forge_changelog_tail "$dir/CHANGELOG.md")"

    cd "$dir"
    "$BUMP_VERSION" --base master >/dev/null \
      || tf_fail "FL3 — bump exited $?, expected 0"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "FL3 — update-changelog exited $?, expected 0"
    head_before="$(git rev-parse HEAD)"

    # The flow dies before the commit; everything is still uncommitted.
    prepared_hash="$(git hash-object CHANGELOG.md)"

    msg="$("$UPDATE_CHANGELOG" --branch master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "0" "FL3 — retrying update-changelog must succeed (got: $msg)"
    tf_eq "$(git hash-object CHANGELOG.md)" "$prepared_hash" \
      "FL3 — a second block must not be prepended"
    tf_count "$dir/CHANGELOG.md" '- pin del proveedor' 1 "FL3 — Added bullet still once"
    tf_count "$dir/CHANGELOG.md" '- regresión de pin' 1 "FL3 — Fixed bullet still once"
    tf_count "$dir/CHANGELOG.md" '## [Unreleased]' 1 "FL3 — still a single [Unreleased] heading"
    tf_eq "$(forge_changelog_tail "$dir/CHANGELOG.md")" "$history_tail" \
      "FL3 — historical changelog still preserved"

    "$COMMIT_RELEASE" minor v0.2.0 >/dev/null \
      || tf_fail "FL3 — commit-release exited $?, expected 0"
    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v0.2.0" \
      "FL3 — the resumed flow creates the checkpoint"
    tf_eq "$(forge_files_in_commit "$dir")" \
      "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md\ninstall.sh')" \
      "FL3 — the resumed commit holds exactly the release artifacts"
    [ "$(git rev-parse HEAD)" != "$head_before" ] || tf_fail "FL3 — HEAD must advance"
    tf_eq "$(forge_checkpoint_count "$dir")" "1" "FL3 — exactly one release commit"
    tf_count "$dir/CHANGELOG.md" '- pin del proveedor' 1 "FL3 — committed changelog has one bullet"

    echo "  FL3 PASS: failure after the changelog resumes without duplicating the block"
  )
}

# =============================================================================
# FL4 — injected failure at the commit step (hook rejects)
# =============================================================================
test_fl4_failure_at_commit_is_resumable() {
  (
    dir="$(forge_test_sandbox release_flow_integration.fl4)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    setup_standard_repo "$dir"

    cd "$dir"
    run_release_flow || tf_fail "FL4 — setup flow failed with $?"

    # Rebuild the release state and let the hook reject the commit.
    forge_touch "$dir" src/opencode.sh "echo pinned v2"
    git -C "$dir" commit -q -m "fix(opencode): segunda corrección"
    "$BUMP_VERSION" --base master >/dev/null \
      || tf_fail "FL4 — bump exited $?, expected 0"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "FL4 — update-changelog exited $?, expected 0"

    head_before="$(git rev-parse HEAD)"
    changelog_hash="$(git hash-object CHANGELOG.md)"

    forge_install_failing_hook "$dir"
    "$COMMIT_RELEASE" patch v0.2.1 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "4" "FL4 — a failing hook must yield exit 4"
    tf_eq "$(git rev-parse HEAD)" "$head_before" "FL4 — HEAD must not move"
    tf_eq "$(git diff --cached --name-only | LC_ALL=C sort | tr '\n' ' ')" \
      ".claude-plugin/plugin.json CHANGELOG.md install.sh " \
      "FL4 — the index is preserved for the resume"
    tf_eq "$(git hash-object CHANGELOG.md)" "$changelog_hash" \
      "FL4 — the changelog must not be regenerated"

    # Remove the hook and retry the very same commit.
    forge_remove_hook "$dir"
    "$COMMIT_RELEASE" patch v0.2.1 >/dev/null \
      || tf_fail "FL4 — retry exited $?, expected 0"
    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v0.2.1" \
      "FL4 — the retry creates the checkpoint"
    tf_eq "$(forge_files_in_commit "$dir")" \
      "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md\ninstall.sh')" \
      "FL4 — the retry does not widen the pathspec"
    tf_count "$dir/CHANGELOG.md" '- segunda corrección' 1 \
      "FL4 — the resumed changelog holds a single entry"

    # From here the flow is fully idempotent again.
    out="$("$BUMP_VERSION" --base master)"
    tf_eq "$out" "BUMP=none  CURRENT=0.2.1  NEXT=0.2.1  FEATS=0  FIXES=0  OTHERS=0" \
      "FL4 — bump after the resume is a no-op"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "FL4 — update-changelog after the resume exited $?"
    tf_eq "$(git hash-object CHANGELOG.md)" "$changelog_hash" \
      "FL4 — the changelog is not regenerated after the resume"
    "$COMMIT_RELEASE" none v0.2.1 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "3" "FL4 — commit-release after the resume exits 3"

    echo "  FL4 PASS: exit 4 preserves the index; the retry and the follow-up runs converge"
  )
}

# =============================================================================
# FL5 — compatibility with a branch equivalent to 91b4229
# =============================================================================
test_fl5_branch_equivalent_to_91b4229() {
  (
    dir="$(forge_test_sandbox release_flow_integration.fl5)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    # Mirror the real master CHANGELOG shape at v0.7.1.
    cat > "$dir/CHANGELOG.md" <<'EOF'
# Forge — Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.7.1] - 2026-08-18

### Fixed
- usar RELEASE_PAT en vez de GITHUB_TOKEN para el auto-merge de release

## [0.7.0] - 2026-08-18

### Added
- guiar la división de pasos [T] grandes en create-plan
EOF
    git -C "$dir" add CHANGELOG.md
    git -C "$dir" commit -q --amend --no-edit

    forge_new_branch "$dir" feature
    forge_touch "$dir" open-code/providers.sh "echo sol-luna"
    git -C "$dir" commit -q -m \
      "fix(opencode): modelos sol/luna, purga de highspeed y pin de opencode-ai@1.19.3"

    cd "$dir"
    run_release_flow
    tf_eq "$FLOW_NEXT" "0.7.2" "FL5 — the branch produces the v0.7.2 checkpoint"

    # The checkpoint must have the exact shape of 91b4229.
    tf_eq "$(git log -1 --format=%s)" "chore(release): bump version to v0.7.2" \
      "FL5 — checkpoint subject"
    tf_eq "$(forge_files_in_commit "$dir")" \
      "$(printf '.claude-plugin/plugin.json\nCHANGELOG.md\ninstall.sh')" \
      "FL5 — checkpoint must only touch the three release artifacts"

    # The non-versionable tooling commit that follows it (Step 4.1 of the plan).
    forge_touch "$dir" tools/release/bump-version.sh "#!/usr/bin/env bash"
    forge_touch "$dir" open-code/commands/create-pr.md "# /create-pr"
    git -C "$dir" commit -q -m "chore(release): make PR preparation resumable"

    # --- the second /create-pr master invocation ---------------------------
    out="$("$BUMP_VERSION" --base master --dry-run)"
    tf_eq "$out" "BUMP=none  CURRENT=0.7.2  NEXT=0.7.2  FEATS=0  FIXES=0  OTHERS=1" \
      "FL5 — the tooling commit must count as OTHERS and must not bump"

    tf_eq "$(forge_install_version "$dir")" "0.7.2" "FL5 — v0.7.2 is preserved"
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "0.7.2" \
      "FL5 — the manifest is preserved"
    tf_count "$dir/CHANGELOG.md" \
      '- modelos sol/luna, purga de highspeed y pin de opencode-ai@1.19.3' 1 \
      "FL5 — the branch entry appears exactly once"
    tf_eq "$(forge_checkpoint_count "$dir")" "1" "FL5 — no extra release commit"

    hash_before="$(git hash-object CHANGELOG.md)"
    "$UPDATE_CHANGELOG" --branch master >/dev/null \
      || tf_fail "FL5 — update-changelog exited $?, expected 0"
    tf_eq "$(git hash-object CHANGELOG.md)" "$hash_before" \
      "FL5 — update-changelog must not change any byte"

    "$COMMIT_RELEASE" none 0.7.2 2>/dev/null && rc=0 || rc=$?
    tf_eq "$rc" "3" "FL5 — commit-release must exit 3"
    tf_eq "$(git status --porcelain)" "" "FL5 — the working tree stays clean"
    tf_eq "$(git log -1 --format=%s)" "chore(release): make PR preparation resumable" \
      "FL5 — the last commit is the tooling commit, not a release commit"

    echo "  FL5 PASS: a 91b4229-equivalent branch re-runs as BUMP=none CURRENT=0.7.2 NEXT=0.7.2 OTHERS=1"
  )
}

# =============================================================================
# Run all
# =============================================================================
echo "=== release_flow_integration.sh ==="

run_test test_fl1_flow_twice_second_is_noop
run_test test_fl2_failure_after_bump_is_resumable
run_test test_fl3_failure_after_changelog_is_resumable
run_test test_fl4_failure_at_commit_is_resumable
run_test test_fl5_branch_equivalent_to_91b4229

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

[ "$FAIL" -gt 0 ] && exit 1
exit 0