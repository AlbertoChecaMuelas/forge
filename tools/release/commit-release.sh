#!/usr/bin/env bash
#
# tools/release/commit-release.sh
#
# Stages the release artifacts and creates the chore(release) commit.
# The commit is strictly limited to the artifacts permitted for the
# requested BUMP; any other staged or untracked content is reported and
# left untouched.
#
# Usage: commit-release.sh <BUMP> <NEXT>
#   BUMP: patch | minor | none
#   NEXT: semver, e.g. v1.2.3 or 1.2.3
#
# Permitted release artifacts (paths relative to the repo root):
#   patch | minor -> install.sh, CHANGELOG.md, .claude-plugin/plugin.json (if present)
#   none          -> CHANGELOG.md, .claude-plugin/plugin.json (if present)
#
# Index policy:
#   1. Reject (exit 2) if any path already staged is outside the
#      permitted set. The foreign paths are listed; the index is NOT
#      un-staged or hidden.
#   2. Add only the permitted artifacts.
#   3. Exit 3 if none of the permitted artifacts has a staged change
#      (no-op / resume path).
#   4. Commit with an explicit pathspec over the permitted set so we
#      never sweep in anything else. Unstaged and untracked content
#      stays intact.
#   5. If `git commit` (or a hook) fails, exit 4 without touching the
#      rest of the index, so the next invocation can resume from the
#      same staged set.
#
# Version coherence:
#   For BUMP=patch|minor, install.sh must hold NEXT (a missing
#   install.sh is also rejected). The manifest is only checked when it
#   exists locally and jq is available. For BUMP=none, install.sh is
#   not part of the permitted set, so its value is not enforced here.
#
# Exit codes:
#   0  Success: a new release commit was created.
#   2  Bad args, missing required file, foreign staged content, or
#      release artifact version mismatches NEXT.
#   3  Nothing to commit (no permitted artifact has a staged change).
#   4  `git commit` failed.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '1,/^set -euo pipefail/p' "$0"
  exit 0
fi

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
BUMP="${1:-}"
NEXT="${2:-}"

case "$BUMP" in
  patch|minor|none) ;;
  *)
    echo "commit-release: BUMP must be patch|minor|none (got '${BUMP}')" >&2
    exit 2
    ;;
esac

if [ -z "$NEXT" ] || ! echo "$NEXT" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "commit-release: NEXT must be a semver like v1.2.3 (got '${NEXT}')" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Normalise version: strip leading v, then re-add it.
# ---------------------------------------------------------------------------
VER="${NEXT#v}"
TAG="v${VER}"

ROOT="$(git rev-parse --show-toplevel)"

if [ ! -f "${ROOT}/CHANGELOG.md" ]; then
  echo "commit-release: CHANGELOG.md not found at repo root" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Resolve the permitted artifact set for this BUMP.
# ---------------------------------------------------------------------------
PERMITTED=""
case "$BUMP" in
  patch|minor)
    if [ ! -f "${ROOT}/install.sh" ]; then
      echo "commit-release: install.sh not found but BUMP=${BUMP} requires it" >&2
      exit 2
    fi
    PERMITTED="install.sh CHANGELOG.md"
    if [ -f "${ROOT}/.claude-plugin/plugin.json" ]; then
      PERMITTED="${PERMITTED} .claude-plugin/plugin.json"
    fi
    ;;
  none)
    PERMITTED="CHANGELOG.md"
    if [ -f "${ROOT}/.claude-plugin/plugin.json" ]; then
      PERMITTED="${PERMITTED} .claude-plugin/plugin.json"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Inspect the index BEFORE we mutate it: any path staged outside the
# permitted set is a foreign change the release commit must not sweep
# in. List the offenders and refuse; do not un-stage or stash.
# ---------------------------------------------------------------------------
STAGED_ALL="$(git -C "$ROOT" diff --cached --name-only --diff-filter=ACMRD 2>/dev/null || true)"
FOREIGN=""
if [[ -n "${STAGED_ALL}" ]]; then
  while IFS= read -r P; do
    [[ -z "${P}" ]] && continue
    OK=false
    for ok in ${PERMITTED}; do
      if [[ "${ok}" = "${P}" ]]; then
        OK=true
        break
      fi
    done
    if [[ "${OK}" == "false" ]]; then
      FOREIGN="${FOREIGN} ${P}"
    fi
  done <<EOF
${STAGED_ALL}
EOF
fi
if [[ -n "${FOREIGN// /}" ]]; then
  echo "commit-release: foreign paths already staged; refusing to include them in the release commit:" >&2
  for f in ${FOREIGN}; do
    echo "  $f" >&2
  done
  echo "commit-release: reset the index for those paths (e.g. 'git restore --staged <path>') and re-run" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Add only the permitted artifacts (idempotent on already-staged paths
# whose content already matches the index).
# ---------------------------------------------------------------------------
for p in ${PERMITTED}; do
  git -C "$ROOT" add -- "$p"
done

# ---------------------------------------------------------------------------
# Pre-commit coherence: for BUMP=patch|minor the staged install.sh (and
# the manifest when present) must already hold NEXT.
# ---------------------------------------------------------------------------
case "${BUMP}" in
  patch|minor)
    INSTALL_V="$(grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "${ROOT}/install.sh" \
      | head -n 1 \
      | sed -E 's/^FORGE_VERSION="([^"]+)"$/\1/' || true)"
    if [[ "${INSTALL_V}" != "${VER}" ]]; then
      echo "commit-release: install.sh FORGE_VERSION='${INSTALL_V}' does not match NEXT=${VER}" >&2
      exit 2
    fi
    if [[ -f "${ROOT}/.claude-plugin/plugin.json" ]] && command -v jq >/dev/null 2>&1; then
      PLUGIN_V="$(jq -r .version "${ROOT}/.claude-plugin/plugin.json" 2>/dev/null || echo "")"
      if [[ -n "${PLUGIN_V}" && "${PLUGIN_V}" != "${VER}" ]]; then
        echo "commit-release: .claude-plugin/plugin.json version='${PLUGIN_V}' does not match NEXT=${VER}" >&2
        exit 2
      fi
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Decide exit 3 by inspecting ONLY the permitted paths' staged diff. If
# no permitted artifact has a cached change, there is nothing to release.
# ---------------------------------------------------------------------------
ANY_DIFF=0
for p in ${PERMITTED}; do
  if ! git -C "$ROOT" diff --cached --quiet -- "${p}"; then
    ANY_DIFF=1
    break
  fi
done

if [[ "${ANY_DIFF}" -eq 0 ]]; then
  echo "commit-release: no release artifact has a staged change (BUMP=${BUMP}, NEXT=${TAG}); already committed?" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Create the commit with explicit pathspec so foreign content cannot be
# swept in even if a hook or sub-process were to touch the index.
# ---------------------------------------------------------------------------
COMMIT_MSG="chore(release): bump version to ${TAG}"
COMMIT_PATHSPEC=()
for p in ${PERMITTED}; do
  COMMIT_PATHSPEC+=("$p")
done

if ! git -C "$ROOT" commit -m "${COMMIT_MSG}" -- "${COMMIT_PATHSPEC[@]}"; then
  echo "commit-release: git commit failed; index left intact for resume" >&2
  exit 4
fi

echo "commit-release: committed ${TAG} (BUMP=${BUMP})"
