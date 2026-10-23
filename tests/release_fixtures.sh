#!/usr/bin/env bash
# tests/release_fixtures.sh
#
# Shared fixtures and assertion helpers for the release-flow suites:
#   tests/bump_version_unit.sh
#   tests/release_skill_unit.sh
#   tests/release_flow_integration.sh
#
# This file is SOURCED, never executed. tests/run-all.sh only collects
# *_unit.sh and *_integration.sh, so it is not a suite of its own.
#
# Every sandbox repository is created under $FORGE_TEST_SANDBOX
# (default /tmp/opencode/forge-release-tests) and removed by the calling
# test's EXIT trap. No helper here ever mutates the real forge working
# tree: the release scripts are only read from it.
#
# Compatible with bash 3.2+. No associative arrays, no mapfile.

# shellcheck disable=SC2034  # file-wide: the script paths are consumed by the
#                             # suites that source this file, not here.
FORGE_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORGE_TEST_SANDBOX="${FORGE_TEST_SANDBOX:-/tmp/opencode/forge-release-tests}"

BUMP_VERSION="$FORGE_TEST_ROOT/tools/release/bump-version.sh"
UPDATE_CHANGELOG="$FORGE_TEST_ROOT/tools/release/update-changelog.sh"
COMMIT_RELEASE="$FORGE_TEST_ROOT/tools/release/commit-release.sh"

# ---------------------------------------------------------------------------
# Sandboxes and repositories
# ---------------------------------------------------------------------------

# forge_test_sandbox <prefix> -> path to a fresh empty directory
forge_test_sandbox() {
  mkdir -p "$FORGE_TEST_SANDBOX"
  mktemp -d "${FORGE_TEST_SANDBOX}/${1}.XXXXXX"
}

# forge_write_version <dir> <version>
# Rewrites install.sh + .claude-plugin/plugin.json to hold <version>.
forge_write_version() {
  printf '#!/usr/bin/env bash\n# Forge installer\nFORGE_VERSION="%s"\n' "$2" \
    > "$1/install.sh"
  printf '{\n  "name": "forge",\n  "version": "%s"\n}\n' "$2" \
    > "$1/.claude-plugin/plugin.json"
}

# forge_default_changelog <version> -> a realistic CHANGELOG body on stdout,
# with an [Unreleased] section and one closed historical release.
forge_default_changelog() {
  cat <<EOF
# Forge — Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [$1] - 2026-01-01

### Added
- initial release
EOF
}

# ---------------------------------------------------------------------------
# CHANGELOG baseline shapes
#
# forge_default_changelog always emits "## [Unreleased]", so on its own it can
# never reach the branch of update-changelog.sh that CREATES the section. The
# constructors below pin the other baseline shapes, and
# forge_new_repo_with_changelog feeds them to the sandbox repo.
# ---------------------------------------------------------------------------

# forge_changelog_no_unreleased <version> — preamble plus one closed release,
# and no "## [Unreleased]" heading at all.
forge_changelog_no_unreleased() {
  cat <<EOF
# Forge — Changelog

All notable changes to this project will be documented in this file.

## [$1] - 2026-01-01

### Added
- initial release
EOF
}

# forge_changelog_preamble_only — a document with a preamble and no "## ["
# section whatsoever, so there is no released section to insert before.
forge_changelog_preamble_only() {
  cat <<EOF
# Forge — Changelog

All notable changes to this project will be documented in this file.
EOF
}

# forge_changelog_without_trailing_newline <version> — one closed release whose
# LAST BYTE IS NOT a newline. printf, not a heredoc, so the missing newline
# survives the constructor.
forge_changelog_without_trailing_newline() {
  printf '# Forge — Changelog\n\n## [%s] - 2026-01-01\n\n### Added\n- initial release' "$1"
}

# forge_changelog_glued_unreleased <preamble-blank> — an [Unreleased] section
# whose heading is NOT followed by a blank line, optionally with an existing
# "### Fixed" subsection carrying curated content. Exercises the renderer
# branch that has to normalise the heading gap and close the merged
# subsection on a real blank line.
#   forge_changelog_glued_unreleased <version> empty|curated
forge_changelog_glued_unreleased() {
  case "${2:-empty}" in
    curated)
      cat <<EOF
# Forge — Changelog

## [Unreleased]
### Fixed
- curado previo

## [$1] - 2026-01-01

### Added
- initial release
EOF
      ;;
    *)
      cat <<EOF
# Forge — Changelog

## [Unreleased]
EOF
      ;;
  esac
}

# forge_changelog_existing_subsections <version> — an [Unreleased] block that
# already carries TWO managed subsections. A pending bullet for the FIRST one
# forces the renderer to flush that subsection in the middle of its scan (not
# at the end), which is the merge path for an already-populated kind.
forge_changelog_existing_subsections() {
  cat <<EOF
# Forge — Changelog

## [Unreleased]

### Added
- proveedor previo

### Fixed
- arreglo previo

## [$1] - 2026-01-01

### Added
- initial release
EOF
}

# forge_new_repo_with_changelog <dir> [version]
# Same as forge_new_repo but the CHANGELOG.md body is read from stdin, so a
# case can pin an exact baseline shape instead of the default one.
forge_new_repo_with_changelog() {
  local dir="$1"
  local version="${2:-0.7.1}"
  local changelog
  changelog="$(mktemp)"
  cat > "$changelog"

  mkdir -p "$dir/.claude-plugin"
  git init -q "$dir"
  git -C "$dir" symbolic-ref HEAD refs/heads/master
  git -C "$dir" config user.email "forge-tests@test.invalid"
  git -C "$dir" config user.name "Forge Tests"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config core.autocrlf false

  forge_write_version "$dir" "$version"
  cp "$changelog" "$dir/CHANGELOG.md"
  rm -f "$changelog"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "chore: base"
}

# forge_new_repo <dir> [version]
# Initialises a git repo on branch master holding the three release
# artifacts at <version> (default 0.7.1), committed as "chore: base".
forge_new_repo() {
  local dir="$1"
  local version="${2:-0.7.1}"
  forge_default_changelog "$version" | forge_new_repo_with_changelog "$dir" "$version"
}

# forge_write_manifest_version <dir> <version>
# Rewrites ONLY .claude-plugin/plugin.json, so a case can put the manifest in
# conflict while install.sh stays at a legal {CURRENT, NEXT} value.
forge_write_manifest_version() {
  printf '{\n  "name": "forge",\n  "version": "%s"\n}\n' "$2" \
    > "$1/.claude-plugin/plugin.json"
}

# forge_release_once <dir> <base> <bump> <next>
# One full release pass: bump-version.sh -> update-changelog.sh ->
# commit-release.sh. Used to land two releases on the same branch, which is
# what puts an already-populated "### <Kind>" subsection inside [Unreleased].
forge_release_once() {
  local dir="$1" base="${2:-master}" bump="$3" next="$4"
  (
    cd "$dir" \
      && "$BUMP_VERSION" --base "$base" >/dev/null \
      && "$UPDATE_CHANGELOG" --branch "$base" >/dev/null \
      && "$COMMIT_RELEASE" "$bump" "$next" >/dev/null
  )
}

# forge_release_section <file> <version> — the released section "## [<version>]"
# up to (but excluding) the next "## [" heading, i.e. exactly the block a tag
# publication ships for that release.
forge_release_section() {
  awk -v want="## [$2]" '
    index($0, want) == 1 { inside = 1; print; next }
    inside && /^## \[/    { inside = 0 }
    inside                 { print }
  ' "$1"
}

# forge_autotag_closure <changelog> <tag> — reproduces the transformation
# tools/release/auto-tag.sh:138 applies when a release is published: the
# heading "## [Unreleased]" is replaced by the heading, a blank line and the
# new released section, so whatever lived under [Unreleased] is swept into
# <tag> verbatim. Kept faithful to that sed expression on purpose: the point
# of the assertion is what auto-tag SHIPS, not what the renderer writes.
forge_autotag_closure() {
  local file="$1" tag="${2#v}"
  sed "s|^## \\[Unreleased\\]$|## [Unreleased]\n\n## [${tag}] - 2026-02-01|" "$file"
}

# forge_new_branch <dir> <name>
forge_new_branch() {
  git -C "$1" checkout -q -b "$2"
}

# forge_commit <dir> <subject>   (empty commit, no path rewriting)
forge_commit() {
  git -C "$1" commit -q --allow-empty -m "$2"
}

# forge_touch <dir> <path> <body>
forge_touch() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
}

# forge_checkpoint <dir> <version>
# Bumps the artifacts to <version> and commits them with the canonical
# checkpoint subject, i.e. exactly what commit-release.sh produces.
forge_checkpoint() {
  forge_write_version "$1" "$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "chore(release): bump version to v$2"
}

# forge_install_failing_hook <dir>
# A pre-commit hook that always refuses, to simulate a failing commit.
forge_install_failing_hook() {
  printf '#!/usr/bin/env bash\necho "pre-commit hook refuses" >&2\nexit 1\n' \
    > "$1/.git/hooks/pre-commit"
  chmod +x "$1/.git/hooks/pre-commit"
}

# forge_remove_hook <dir>
forge_remove_hook() {
  rm -f "$1/.git/hooks/pre-commit"
}

# forge_release_field <output-line> <FIELD>
# Extracts BUMP / CURRENT / NEXT / FEATS / FIXES / OTHERS from a
# bump-version.sh stdout line.
forge_release_field() {
  printf '%s\n' "$1" | sed -n "s/.*[[:space:]]\{0,1\}$2=\([^[:space:]]*\).*/\1/p"
}

# forge_files_in_commit <dir> [rev] -> changed paths, one per line
forge_files_in_commit() {
  git -C "$1" show --pretty=format: --name-only "${2:-HEAD}" | sed '/^$/d' | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# Assertions (usable inside a subshell test: tf_fail exits that subshell)
# ---------------------------------------------------------------------------

tf_fail() {
  echo "  FAIL: $*"
  exit 1
}

tf_eq() {
  [ "$1" = "$2" ] || tf_fail "$3 — expected '$2', got '$1'"
}

tf_contains() {
  grep -qF -- "$2" <<< "$1" || tf_fail "$3 — missing '$2'"
}

tf_not_contains() {
  if grep -qF -- "$2" <<< "$1"; then
    tf_fail "$3 — unexpected '$2'"
  fi
}

# tf_count <file> <fixed-string> <expected-count> <message>
tf_count() {
  local n
  n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"
  [ "${n:-0}" = "$3" ] || \
    tf_fail "$4 — expected $3 occurrence(s) of '$2' in $(basename "$1"), got ${n:-0}"
}

# ---------------------------------------------------------------------------
# Structural assertions
#
# The content assertions above cannot tell "one ### Added with two bullets"
# from "two ### Added with one bullet each", which is exactly the regression
# these helpers exist to catch: auto-tag.sh sweeps the whole [Unreleased]
# block into the tag at publication time, so a duplicated heading ships a
# malformed release section.
# ---------------------------------------------------------------------------

# forge_unreleased_block <file> — every line from the "## [Unreleased]"
# heading up to (but excluding) the next "## [" section. Scoping structural
# assertions to this block stops an identically named heading inside a
# closed release from making them pass by accident.
forge_unreleased_block() {
  awk '
    /^## \[Unreleased\]/          { inside = 1 }
    inside && /^## \[/ && !/^## \[Unreleased\]/ { inside = 0 }
    inside                         { print }
  ' "$1"
}

# tf_count_unreleased <file> <fixed-string> <expected-count> <message>
tf_count_unreleased() {
  local n
  n="$(forge_unreleased_block "$1" | grep -cF -- "$2" || true)"
  [ "${n:-0}" = "$3" ] || \
    tf_fail "$4 — expected $3 occurrence(s) of '$2' inside [Unreleased], got ${n:-0}"
}

# tf_appears_before <file> <first> <second> <message>
tf_appears_before() {
  local a b
  a="$(grep -nF -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
  b="$(grep -nF -- "$3" "$1" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
  [ -n "$a" ] || tf_fail "$4 — '$2' is missing from $(basename "$1")"
  [ -n "$b" ] || tf_fail "$4 — '$3' is missing from $(basename "$1")"
  [ "$a" -lt "$b" ] || \
    tf_fail "$4 — '$2' (line $a) must precede '$3' (line $b)"
}

# tf_unreleased_order <file> <first> <second> <message>
# Asserts the two headings appear inside [Unreleased] in this order.
tf_unreleased_order() {
  local tmp
  tmp="$(mktemp)"
  forge_unreleased_block "$1" > "$tmp"
  tf_appears_before "$tmp" "$2" "$3" "$4 (inside [Unreleased])"
  rm -f "$tmp"
}

# tf_blank_line_follows <file> <fixed-string> <message>
# Asserts the line right after the LAST line holding <fixed-string> is a real
# blank line. Without it the last bullet of a managed subsection is glued to
# whatever content follows the block.
tf_blank_line_follows() {
  local n total next
  n="$(grep -nF -- "$2" "$1" 2>/dev/null | tail -n 1 | cut -d: -f1 || true)"
  [ -n "$n" ] || tf_fail "$3 — '$2' is not present in $(basename "$1")"
  total="$(wc -l < "$1" | tr -d ' ')"
  [ "${n}" -lt "${total}" ] || \
    tf_fail "$3 — '$2' is the last line of $(basename "$1"); nothing closes the block"
  next="$(sed -n "$((n + 1))p" "$1")"
  [ -z "$next" ] || \
    tf_fail "$3 — line $((n + 1)) after '$2' is not blank: '$next'"
}

# tf_ends_with_newline <file> <message>
# A rendered CHANGELOG must be newline-terminated even when its baseline was
# not; otherwise the file is malformed and the idempotency comparison against
# the next render depends on a byte the renderer does not preserve.
tf_ends_with_newline() {
  local last
  last="$(tail -c 1 "$1" | od -An -c | tr -d ' \n')"
  [ "${last}" = '\n' ] || \
    tf_fail "$2 — $(basename "$1") does not end with a newline (last byte: ${last})"
}

# tf_nothing_staged <dir> <message>
tf_nothing_staged() {
  local staged
  staged="$(git -C "$1" diff --cached --name-only)"
  [ -z "${staged}" ] || \
    tf_fail "$2 — unexpected staged content: $(printf '%s' "$staged" | tr '\n' ' ')"
}

# tf_install_version <dir> — FORGE_VERSION literal in the working tree.
tf_install_version() {
  grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$1/install.sh" \
    | head -n 1 | sed -E 's/^FORGE_VERSION="([^"]+)"$/\1/'
}

# tf_clean_release_artifacts <dir> <message>
# No release artifact may be modified nor staged.
tf_clean_release_artifacts() {
  local dir="$1" msg="$2"
  git -C "$dir" diff --quiet -- install.sh CHANGELOG.md .claude-plugin/plugin.json \
    || tf_fail "$msg — release artifacts are modified in the working tree"
  [ -z "$(git -C "$dir" diff --cached --name-only)" ] \
    || tf_fail "$msg — unexpected staged content: $(git -C "$dir" diff --cached --name-only | tr '\n' ' ')"
}

tf_has_jq() {
  command -v jq >/dev/null 2>&1
}