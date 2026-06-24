#!/usr/bin/env bash
#
# tools/release/commit-release.sh
#
# Stages the release artifacts and creates the chore(release) commit.
#
# Usage: commit-release.sh <BUMP> <NEXT>
#   BUMP: patch | minor | none
#   NEXT: semver, e.g. v1.2.3 or 1.2.3
#
# Exit codes:
#   0  success
#   2  bad args / missing required file
#   3  nothing staged
#   4  git commit failed
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

# Validate BUMP
case "$BUMP" in
  patch|minor|none) ;;
  *)
    echo "commit-release: BUMP must be patch|minor|none (got '${BUMP}')" >&2
    exit 2
    ;;
esac

# Validate NEXT
if [ -z "$NEXT" ] || ! echo "$NEXT" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "commit-release: NEXT must be a semver like v1.2.3 (got '${NEXT}')" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Normalise version: strip leading v, then re-add it
# ---------------------------------------------------------------------------
VER="${NEXT#v}"
TAG="v${VER}"

# ---------------------------------------------------------------------------
# Resolve repo root
# ---------------------------------------------------------------------------
ROOT="$(git rev-parse --show-toplevel)"

# ---------------------------------------------------------------------------
# Require CHANGELOG.md
# ---------------------------------------------------------------------------
if [ ! -f "${ROOT}/CHANGELOG.md" ]; then
  echo "commit-release: CHANGELOG.md not found at repo root" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Determine files to stage
# ---------------------------------------------------------------------------
STAGED_FILES=""

case "$BUMP" in
  patch|minor)
    if [ ! -f "${ROOT}/install.sh" ]; then
      echo "commit-release: install.sh not found but BUMP=${BUMP} requires it" >&2
      exit 2
    fi
    git -C "$ROOT" add install.sh
    STAGED_FILES="install.sh"

    git -C "$ROOT" add CHANGELOG.md
    STAGED_FILES="${STAGED_FILES} CHANGELOG.md"

    if [ -f "${ROOT}/.claude-plugin/plugin.json" ]; then
      git -C "$ROOT" add .claude-plugin/plugin.json
      STAGED_FILES="${STAGED_FILES} .claude-plugin/plugin.json"
    fi
    ;;
  none)
    git -C "$ROOT" add CHANGELOG.md
    STAGED_FILES="CHANGELOG.md"

    if [ -f "${ROOT}/.claude-plugin/plugin.json" ]; then
      git -C "$ROOT" add .claude-plugin/plugin.json
      STAGED_FILES="${STAGED_FILES} .claude-plugin/plugin.json"
    fi
    ;;
esac

# ---------------------------------------------------------------------------
# Guard against empty commit
# ---------------------------------------------------------------------------
if git -C "$ROOT" diff --cached --quiet; then
  echo "commit-release: nothing staged; CHANGELOG/plugin.json already committed?" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Create the commit
# ---------------------------------------------------------------------------
if ! git -C "$ROOT" commit -m "chore(release): bump version to ${TAG}"; then
  echo "commit-release: git commit failed" >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Report success
# ---------------------------------------------------------------------------
echo "commit-release: committed ${TAG} (BUMP=${BUMP})"
echo "Staged files:${STAGED_FILES}"
