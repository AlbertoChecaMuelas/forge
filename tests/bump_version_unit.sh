#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/bump_version_unit.sh — Behaviour tests for tools/release/bump-version.sh
# under the checkpoint-walk design.
#
# Covers the success criteria of Step 1.2 of
# .plans/release-flow-checkpoint-idempotency.md:
#   * a valid release checkpoint becomes the anchor (CURRENT / range);
#   * re-running right after a release is BUMP=none and mutates nothing;
#   * a working tree already bumped to NEXT is resumed, never re-incremented
#     (CURRENT always comes from the anchor tree, never from the WT);
#   * functional commits added AFTER the checkpoint are re-classified and can
#     produce a legitimate new bump;
#   * a stale base, a non-ancestor base, an unexpected third WT version and an
#     inconsistent checkpoint fail explicitly (exit 2) without mutating.
#
# Added after the release-flow fix, for the paths no earlier case reached:
#   BV9 --dry-run runs the working-tree preflight, so a dry run exits 2 with
#     exactly the diagnostic the real run emits, and mutates nothing
#   BV10 the {CURRENT, NEXT} guard of the MANIFEST also holds on the BUMP=none
#     early exit (NEXT == CURRENT there, so nothing is written at all)
#   BV11 ...and on the resume path, where a third manifest version must not be
#     overwritten while a merely lagging one is still synced
#
# Every case runs in its own throwaway git repository under
# $FORGE_TEST_SANDBOX (default /tmp/opencode/forge-release-tests).
# Compatible with bash 3.2+. No associative arrays, no mapfile.
set -euo pipefail

# shellcheck source=tests/release_fixtures.sh
. "$(dirname "$0")/release_fixtures.sh"

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

# step <fn> — run one subshell as a step of a multi-part test. run_test
# disables errexit around the test body, so a subshell that aborts via
# tf_fail would otherwise be swallowed by the next statement.
step() {
  local rc=0
  ( "$@" ) || rc=$?
  [ "$rc" -eq 0 ] || exit 1
}

# Skip bump-version cases that need the manifest when jq is unavailable.
require_jq() {
  if ! tf_has_jq; then
    echo "  SKIP: jq is not available"
    exit 0
  fi
}

# =============================================================================
# BV1 — a valid checkpoint is used as the anchor
# =============================================================================
test_bv1_valid_checkpoint_is_anchor() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv1)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo pinned"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"
    forge_checkpoint "$dir" 0.7.2
    forge_touch "$dir" tools/release/bump-version.sh "# rewritten"
    git -C "$dir" commit -q -m "chore(release): make PR preparation resumable"

    cd "$dir"
    out="$("$BUMP_VERSION" --base master --dry-run)"

    tf_eq "$out" "BUMP=none  CURRENT=0.7.2  NEXT=0.7.2  FEATS=0  FIXES=0  OTHERS=1" \
      "BV1 — CURRENT/range must come from the validated checkpoint, not from master"

    # --dry-run is strictly non-mutating.
    tf_clean_release_artifacts "$dir" "BV1 — --dry-run"
    echo "  BV1 PASS: last valid checkpoint anchors CURRENT=0.7.2; trailing chore counted as OTHERS"
  )
}

# =============================================================================
# BV2 — re-run right after the release commit is a BUMP=none no-op
# =============================================================================
test_bv2_rerun_after_release_is_noop() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv2)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"
    forge_checkpoint "$dir" 0.7.2

    cd "$dir"
    out="$("$BUMP_VERSION" --base master)"   # no --dry-run: must not mutate
    rc=$?

    tf_eq "$rc" "0" "BV2 — exit code"
    tf_eq "$out" "BUMP=none  CURRENT=0.7.2  NEXT=0.7.2  FEATS=0  FIXES=0  OTHERS=0" \
      "BV2 — post-release re-run"
    tf_clean_release_artifacts "$dir" "BV2 — BUMP=none run"
    tf_eq "$(grep -E '^FORGE_VERSION=' "$dir/install.sh")" 'FORGE_VERSION="0.7.2"' \
      "BV2 — install.sh version"
    echo "  BV2 PASS: re-run after release is BUMP=none and touches nothing"
  )
}

# =============================================================================
# BV3 — resume a working tree already bumped to NEXT, before the checkpoint
# =============================================================================
test_bv3_resume_pre_committed_version() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv3)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"

    # Simulate a previous run that wrote the artifacts but died before
    # creating the checkpoint commit.
    forge_write_version "$dir" 0.7.2

    cd "$dir"
    out="$("$BUMP_VERSION" --base master)"
    rc=$?

    tf_eq "$rc" "0" "BV3 — exit code"
    tf_eq "$out" "BUMP=patch  CURRENT=0.7.1  NEXT=0.7.2  FEATS=0  FIXES=1  OTHERS=0" \
      "BV3 — CURRENT must be read from the anchor tree (0.7.1), never from the bumped WT"
    tf_eq "$(grep -E '^FORGE_VERSION=' "$dir/install.sh")" 'FORGE_VERSION="0.7.2"' \
      "BV3 — install.sh must stay at NEXT, never reach 0.7.3"
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "0.7.2" \
      "BV3 — manifest stays at NEXT"
    echo "  BV3 PASS: partially bumped tree resumed at 0.7.2 without double increment"
  )
}

# =============================================================================
# BV4 — functional commits added after the checkpoint are re-classified
# =============================================================================
test_bv4_post_checkpoint_commits_reclassified() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv4)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"
    forge_checkpoint "$dir" 0.7.2

    forge_touch "$dir" src/agents.sh "echo feat"
    git -C "$dir" commit -q -m "feat(agents): nuevo proveedor"

    cd "$dir"
    dry="$("$BUMP_VERSION" --base master --dry-run)"
    tf_eq "$dry" "BUMP=minor  CURRENT=0.7.2  NEXT=0.8.0  FEATS=1  FIXES=0  OTHERS=0" \
      "BV4 — a post-checkpoint feat must be classified from the checkpoint, not dropped"
    tf_clean_release_artifacts "$dir" "BV4 — --dry-run"

    out="$("$BUMP_VERSION" --base master)"
    tf_eq "$out" "BUMP=minor  CURRENT=0.7.2  NEXT=0.8.0  FEATS=1  FIXES=0  OTHERS=0" \
      "BV4 — real run must agree with --dry-run"
    tf_eq "$(grep -E '^FORGE_VERSION=' "$dir/install.sh")" 'FORGE_VERSION="0.8.0"' \
      "BV4 — install.sh bumped"
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "0.8.0" \
      "BV4 — manifest bumped"

    # Re-running after the bump is itself idempotent.
    out2="$("$BUMP_VERSION" --base master)"
    tf_eq "$out2" "BUMP=minor  CURRENT=0.7.2  NEXT=0.8.0  FEATS=1  FIXES=0  OTHERS=0" \
      "BV4 — second run must be stable"
    tf_eq "$(grep -E '^FORGE_VERSION=' "$dir/install.sh")" 'FORGE_VERSION="0.8.0"' \
      "BV4 — second run must not double increment"
    echo "  BV4 PASS: post-checkpoint feat yields minor 0.7.2 -> 0.8.0 and is idempotent"
  )
}

# =============================================================================
# BV5 — stale base (local master diverged from origin/master)
# =============================================================================
test_bv5_stale_base_is_rejected() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv5)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"

    # origin/master exists but points somewhere else than local master.
    git -C "$dir" update-ref refs/remotes/origin/master "$(git -C "$dir" rev-parse HEAD)"

    cd "$dir"
    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV5 — a stale base must exit 2, got output: $err"
    tf_contains "$err" "origin/master" "BV5 — diagnostic must name the diverged remote ref"
    tf_clean_release_artifacts "$dir" "BV5 — rejected run"
    echo "  BV5 PASS: local base diverged from origin/master exits 2 without mutating"
  )
}

# =============================================================================
# BV6 — base is not an ancestor of HEAD
# =============================================================================
test_bv6_non_ancestor_base_is_rejected() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv6)"
    trap 'rm -rf "$dir"' EXIT

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"

    # master moves forward on a disjoint line.
    git -C "$dir" checkout -q master
    forge_touch "$dir" other.txt "otra linea"
    git -C "$dir" commit -q -m "chore: linea divergente"
    git -C "$dir" checkout -q feature

    cd "$dir"
    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV6 — non-ancestor base must exit 2, got output: $err"
    tf_contains "$err" "not an ancestor" "BV6 — diagnostic must explain the precondition"
    tf_clean_release_artifacts "$dir" "BV6 — rejected run"
    echo "  BV6 PASS: base that is not an ancestor of HEAD exits 2"
  )
}

# =============================================================================
# BV7 — a third version in the working tree is a conflict, not an overwrite
# =============================================================================
test_bv7_third_version_is_rejected() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv7)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"
    forge_write_version "$dir" 9.9.9

    cd "$dir"
    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV7 — third version must exit 2, got output: $err"
    tf_contains "$err" "9.9.9" "BV7 — diagnostic must name the conflicting version"
    tf_eq "$(grep -E '^FORGE_VERSION=' "$dir/install.sh")" 'FORGE_VERSION="9.9.9"' \
      "BV7 — the conflicting working tree value must be preserved"
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "9.9.9" \
      "BV7 — the conflicting manifest must be preserved"
    echo "  BV7 PASS: unexpected third version rejected without overwriting"
  )
}

# =============================================================================
# BV8 — an inconsistent checkpoint aborts instead of being skipped
# =============================================================================
test_bv8_inconsistent_checkpoint_is_rejected() {
  (
    # 8a: the checkpoint subject does not match the sequential bump.
    dir="$(forge_test_sandbox bump_version_unit.bv8a)"
    trap 'rm -rf "$dir"' EXIT
    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"
    forge_write_version "$dir" 0.7.3        # subject and tree agree...
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "chore(release): bump version to v0.7.3"
    # ...but a single fix commit from 0.7.1 can only yield 0.7.2.

    cd "$dir"
    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV8a — non-sequential checkpoint must exit 2, got output: $err"
    tf_contains "$err" "yields 0.7.2" "BV8a — diagnostic must show the expected sequential bump"
  )

  (
    # 8b: the checkpoint tree disagrees with its own subject.
    dir="$(forge_test_sandbox bump_version_unit.bv8b)"
    trap 'rm -rf "$dir"' EXIT
    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"
    forge_write_version "$dir" 0.7.9        # tree drifted...
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "chore(release): bump version to v0.7.2"   # ...subject does not

    cd "$dir"
    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV8b — tree/subject mismatch must exit 2, got output: $err"
    tf_contains "$err" "0.7.9" "BV8b — diagnostic must name the version found in the tree"
  )

  (
    # 8c: a checkpoint that carries a path outside the release artifacts.
    dir="$(forge_test_sandbox bump_version_unit.bv8c)"
    trap 'rm -rf "$dir"' EXIT
    forge_new_repo "$dir" 0.7.1
    forge_new_branch "$dir" feature
    forge_touch "$dir" src/opencode.sh "echo fix"
    git -C "$dir" commit -q -m "fix(opencode): ajustar pin"
    forge_write_version "$dir" 0.7.2
    forge_touch "$dir" stray.txt "no es un artefacto de release"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "chore(release): bump version to v0.7.2"

    cd "$dir"
    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV8c — checkpoint with a foreign path must exit 2, got output: $err"
    tf_contains "$err" "stray.txt" "BV8c — diagnostic must name the offending path"
  )

  echo "  BV8 PASS: inconsistent checkpoints (version, sequence, foreign path) all exit 2"
}

# =============================================================================
# BV9 — --dry-run runs the working-tree preflight
#
# The preflight used to sit BELOW the --dry-run exit, so a dry run reported a
# bump for a tree the real run refused to touch. A dry run must now answer the
# only question that matters: would this release succeed at all?
# =============================================================================
bv9_conflict_setup() {
  local dir="$1" conflict="$2" commit_subject="${3:-fix(cli): ajustar pin}"
  forge_new_repo "$dir" 0.7.1
  forge_new_branch "$dir" feature
  forge_touch "$dir" src/opencode.sh "echo fix"
  git -C "$dir" commit -q -m "$commit_subject"
  case "$conflict" in
    manifest) forge_write_manifest_version "$dir" 9.9.9 ;;
    install)  printf '#!/usr/bin/env bash\nFORGE_VERSION="9.9.9"\n' > "$dir/install.sh" ;;
  esac
}

# Asserts --dry-run refuses a conflicted tree with the real run's diagnostic
# and without touching a single byte.
#   bv9_assert_conflict <dir> <who> <needle> <install-before> <manifest-before>
bv9_assert_conflict() {
  local dir="$1" who="$2" needle="$3" install_before="$4" manifest_before="$5"
  local dry_rc real_rc dry_out real_out
  cd "$dir"

  dry_out="$("$BUMP_VERSION" --base master --dry-run 2>&1)" && dry_rc=0 || dry_rc=$?
  tf_eq "$dry_rc" "2" "${who} — --dry-run must exit 2 on a conflicted tree (got: $dry_out)"

  # The preflight is read-only: the tree is exactly as it was found.
  tf_eq "$(tf_install_version "$dir")" "$install_before" \
    "${who} — --dry-run must not touch install.sh"
  tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "$manifest_before" \
    "${who} — --dry-run must not touch the manifest"
  tf_nothing_staged "$dir" "${who} — --dry-run"
  tf_contains "$dry_out" "$needle" "${who} — the dry run must name the conflict"

  # The real run must refuse identically: same exit code, same diagnostic.
  real_out="$("$BUMP_VERSION" --base master 2>&1)" && real_rc=0 || real_rc=$?
  tf_eq "$real_rc" "$dry_rc" "${who} — the real run must exit like --dry-run"
  tf_eq "$real_out" "$dry_out" \
    "${who} — the real run must produce the same diagnostic as --dry-run"
  tf_eq "$(tf_install_version "$dir")" "$install_before" \
    "${who} — the refusing real run must leave install.sh intact"
  tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "$manifest_before" \
    "${who} — the refusing real run must leave the manifest intact"
  tf_nothing_staged "$dir" "${who} — refused real run"
}

bv9_manifest_conflict_body() {
  # The manifest is in conflict while install.sh is legal.
  dir="$(forge_test_sandbox bump_version_unit.bv9a)"
  trap 'rm -rf "$dir"' EXIT
  require_jq
  bv9_conflict_setup "$dir" manifest

  bv9_assert_conflict "$dir" "BV9a" \
    '.claude-plugin/plugin.json working tree has unexpected version' 0.7.1 9.9.9

  # Once the conflict is resolved the dry run succeeds.
  forge_write_manifest_version "$dir" 0.7.1
  dry="$("$BUMP_VERSION" --base master --dry-run)"
  tf_eq "$dry" "BUMP=patch  CURRENT=0.7.1  NEXT=0.7.2  FEATS=0  FIXES=1  OTHERS=0" \
    "BV9a — a resolved tree dry-runs normally"
  tf_clean_release_artifacts "$dir" "BV9a — resolved dry run"
}

bv9_install_conflict_body() {
  # install.sh itself is in conflict.
  dir="$(forge_test_sandbox bump_version_unit.bv9b)"
  trap 'rm -rf "$dir"' EXIT
  require_jq
  bv9_conflict_setup "$dir" install

  bv9_assert_conflict "$dir" "BV9b" \
    'install.sh working tree has unexpected version' 9.9.9 0.7.1
}

test_bv9_dry_run_runs_the_preflight() {
  step bv9_manifest_conflict_body
  step bv9_install_conflict_body
  echo "  BV9 PASS: --dry-run exits 2 with the real run's diagnostic and mutates nothing"
}

# =============================================================================
# BV10 — the {CURRENT, NEXT} guard also covers BUMP=none
#
# When BUMP=none, NEXT == CURRENT and nothing is written at all. That early
# exit must not become a blind spot for the manifest conflict.
# =============================================================================
test_bv10_manifest_conflict_rejected_on_bump_none() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv10)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    bv9_conflict_setup "$dir" manifest "chore(docs): solo documentacion"
    cd "$dir"

    # Confirm the path really is BUMP=none before asserting on it.
    probe="$("$BUMP_VERSION" --base master --dry-run 2>/dev/null || true)"
    tf_contains "$probe" 'BUMP=none' "BV10 — the case must exercise the BUMP=none path"
    tf_contains "$probe" 'CURRENT=0.7.1  NEXT=0.7.1' \
      "BV10 — BUMP=none must collapse NEXT onto CURRENT"

    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV10 — a manifest conflict must exit 2 on the BUMP=none path (got: $err)"
    tf_contains "$err" '.claude-plugin/plugin.json working tree has unexpected version' \
      "BV10 — the diagnostic must name the manifest"
    tf_contains "$err" "9.9.9" "BV10 — the diagnostic must name the conflicting version"
    tf_contains "$err" "expected '0.7.1'" \
      "BV10 — with BUMP=none the only legal version is the anchor"

    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "9.9.9" \
      "BV10 — the conflicting manifest must be preserved"
    tf_eq "$(tf_install_version "$dir")" "0.7.1" \
      "BV10 — install.sh must stay at the anchor"
    tf_nothing_staged "$dir" "BV10 — rejected run"

    # Resolving the conflict converges to the plain BUMP=none no-op.
    forge_write_manifest_version "$dir" 0.7.1
    out="$("$BUMP_VERSION" --base master)"
    tf_eq "$out" "BUMP=none  CURRENT=0.7.1  NEXT=0.7.1  FEATS=0  FIXES=0  OTHERS=1" \
      "BV10 — after resolving the conflict the run is a no-op"
    tf_clean_release_artifacts "$dir" "BV10 — resolved run"

    echo "  BV10 PASS: the manifest guard is not bypassed by the BUMP=none early exit"
  )
}

# =============================================================================
# BV11 — the {CURRENT, NEXT} guard also covers the resume path
#
# The resume path skips the install.sh re-edit and syncs a lagging manifest to
# NEXT. That sync must never turn into an overwrite of a third version.
# =============================================================================
test_bv11_manifest_conflict_rejected_on_resume_path() {
  (
    dir="$(forge_test_sandbox bump_version_unit.bv11)"
    trap 'rm -rf "$dir"' EXIT
    require_jq

    bv9_conflict_setup "$dir" none
    # A previous run already bumped install.sh to NEXT; the manifest is in a
    # third, illegal version.
    printf '#!/usr/bin/env bash\nFORGE_VERSION="0.7.2"\n' > "$dir/install.sh"
    forge_write_manifest_version "$dir" 9.9.9
    cd "$dir"

    err="$("$BUMP_VERSION" --base master 2>&1)" && rc=0 || rc=$?
    tf_eq "$rc" "2" "BV11 — a manifest conflict must exit 2 on the resume path (got: $err)"
    tf_contains "$err" '.claude-plugin/plugin.json working tree has unexpected version' \
      "BV11 — the diagnostic must name the manifest, not install.sh"
    tf_contains "$err" "9.9.9" "BV11 — the diagnostic must name the conflicting version"
    tf_contains "$err" "expected '0.7.1' (anchor) or '0.7.2' (target)" \
      "BV11 — the diagnostic must describe the legal {CURRENT, NEXT} set"

    # Nothing is overwritten: not the manifest, not install.sh.
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "9.9.9" \
      "BV11 — the resume path must not overwrite the manifest"
    tf_eq "$(tf_install_version "$dir")" "0.7.2" \
      "BV11 — install.sh must stay at NEXT"
    tf_nothing_staged "$dir" "BV11 — rejected run"

    # A merely LAGGING manifest (at CURRENT) is still synced: the guard
    # rejects a third version, not a resume.
    forge_write_manifest_version "$dir" 0.7.1
    out="$("$BUMP_VERSION" --base master)"
    tf_eq "$out" "BUMP=patch  CURRENT=0.7.1  NEXT=0.7.2  FEATS=0  FIXES=1  OTHERS=0" \
      "BV11 — a lagging manifest is a valid resume"
    tf_eq "$(jq -r '.version' "$dir/.claude-plugin/plugin.json")" "0.7.2" \
      "BV11 — the lagging manifest is synced to NEXT"
    tf_eq "$(tf_install_version "$dir")" "0.7.2" \
      "BV11 — install.sh must not be incremented again"

    echo "  BV11 PASS: the resume path refuses a third manifest version and still syncs a lagging one"
  )
}

# =============================================================================
# Run all
# =============================================================================
echo "=== bump_version_unit.sh ==="

run_test test_bv1_valid_checkpoint_is_anchor
run_test test_bv2_rerun_after_release_is_noop
run_test test_bv3_resume_pre_committed_version
run_test test_bv4_post_checkpoint_commits_reclassified
run_test test_bv5_stale_base_is_rejected
run_test test_bv6_non_ancestor_base_is_rejected
run_test test_bv7_third_version_is_rejected
run_test test_bv8_inconsistent_checkpoint_is_rejected
run_test test_bv9_dry_run_runs_the_preflight
run_test test_bv10_manifest_conflict_rejected_on_bump_none
run_test test_bv11_manifest_conflict_rejected_on_resume_path

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

[ "$FAIL" -gt 0 ] && exit 1
exit 0