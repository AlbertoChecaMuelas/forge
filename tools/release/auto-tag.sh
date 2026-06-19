#!/usr/bin/env bash
#
# tools/release/auto-tag.sh
#
# Idempotent auto-tag helper for forge.
#
# Reads FORGE_VERSION from install.sh, then:
#   - If the tag vX.Y.Z does not exist on origin, creates an annotated tag
#     on the current commit and pushes it.
#   - If the tag already exists on origin, exits 0 with no side effects.
#
# Designed to run inside GitHub Actions on the default branch, but is safe to
# run locally for verification: pass --dry-run to skip the push.
#
# Required environment when running in CI (all provided automatically by GitHub Actions):
#   - GITHUB_TOKEN      : provided by GitHub Actions (must have contents:write)
#   - GITHUB_REPOSITORY : provided by GitHub Actions (owner/repo)
#
# Exit codes:
#   0  success (tag created and pushed, or tag already existed; CHANGELOG
#      closure committed if applicable, or skipped silently)
#   2  FORGE_VERSION could not be parsed from install.sh
#   4  git push of the tag failed
#   5  git push of the CHANGELOG closure commit failed
#
set -euo pipefail

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
INSTALL_SH="${REPO_ROOT}/install.sh"

if [[ ! -f "${INSTALL_SH}" ]]; then
  echo "auto-tag: install.sh not found at ${INSTALL_SH}" >&2
  exit 2
fi

# Parse FORGE_VERSION="X.Y.Z" (also tolerates single quotes and no quotes).
VERSION="$(
  grep -E '^[[:space:]]*FORGE_VERSION[[:space:]]*=' "${INSTALL_SH}" \
    | head -n 1 \
    | sed -E 's/^[[:space:]]*FORGE_VERSION[[:space:]]*=[[:space:]]*["'"'"']?([0-9]+\.[0-9]+\.[0-9]+)["'"'"']?.*$/\1/'
)"

if [[ -z "${VERSION}" || ! "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "auto-tag: could not parse FORGE_VERSION from install.sh" >&2
  exit 2
fi

TAG="v${VERSION}"
echo "auto-tag: detected FORGE_VERSION=${VERSION} (tag ${TAG})"

# Idempotency check 1: local refs.
if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
  echo "auto-tag: tag ${TAG} already exists locally; nothing to do"
  exit 0
fi

# Idempotency check 2: remote refs (only when we actually have a remote).
if git ls-remote --tags --exit-code origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "auto-tag: tag ${TAG} already exists on origin; nothing to do"
  exit 0
fi

CURRENT_SHA="$(git rev-parse HEAD)"
echo "auto-tag: creating annotated tag ${TAG} on ${CURRENT_SHA}"
git config --local user.email "ci-bot@forge"
git config --local user.name "forge-ci-bot"

# Configure remote URL with token so push works in CI without relying on helper.
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

git tag -a "${TAG}" -m "Release ${TAG}" "${CURRENT_SHA}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "auto-tag: --dry-run set; skipping push"
  exit 0
fi

DEFAULT_BRANCH="${DEFAULT_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)}"
DEFAULT_BRANCH="${DEFAULT_BRANCH:-master}"

if ! git push origin "refs/tags/${TAG}"; then
  echo "auto-tag: git push failed" >&2
  exit 4
fi

echo "auto-tag: pushed ${TAG} to origin"

# -----------------------------------------------------------------------------
# CHANGELOG closure: rename [Unreleased] -> [${TAG}] - YYYY-MM-DD and push.
# Skipped silently if CHANGELOG.md is absent or [Unreleased] is empty.
# -----------------------------------------------------------------------------
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

if [[ ! -f "${CHANGELOG}" ]]; then
  echo "auto-tag: no CHANGELOG.md at repo root; skipping changelog closure"
  exit 0
fi

# Extract the body of the [Unreleased] section and check for non-blank content.
UNRELEASED_BODY="$(
  awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## \[/   { inside = 0 }
    inside               { print }
  ' "${CHANGELOG}"
)"

if [[ -z "$(printf '%s' "${UNRELEASED_BODY}" | tr -d '[:space:]')" ]]; then
  echo "auto-tag: [Unreleased] section is empty; skipping changelog closure"
  exit 0
fi

RELEASE_DATE="$(date +%Y-%m-%d)"
echo "auto-tag: closing [Unreleased] as [${TAG}] - ${RELEASE_DATE}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "auto-tag: --dry-run set; would rewrite ${CHANGELOG} and push closure to ${DEFAULT_BRANCH}"
  exit 0
fi

# Replace '## [Unreleased]' with '## [Unreleased]\n\n## [TAG] - DATE'.
# Test BusyBox sed compatibility: try \n first, fall back to a\ form if needed.
TMP_CL="$(mktemp)"
trap 'rm -f "${TMP_CL}"' EXIT

sed "s|^## \[Unreleased\]$|## [Unreleased]\n\n## [${TAG#v}] - ${RELEASE_DATE}|" "${CHANGELOG}" > "${TMP_CL}"

# Verify the replacement produced the expected header (handles BusyBox \n literal vs newline).
if grep -qF "## [${TAG#v}] - ${RELEASE_DATE}" "${TMP_CL}"; then
  mv "${TMP_CL}" "${CHANGELOG}"
  trap - EXIT
else
  # BusyBox sed may not expand \n — use awk as fallback.
  awk -v tag="${TAG#v}" -v date="${RELEASE_DATE}" '
    /^## \[Unreleased\]$/ {
      print "## [Unreleased]"
      print ""
      print "## [" tag "] - " date
      next
    }
    { print }
  ' "${CHANGELOG}" > "${TMP_CL}"
  mv "${TMP_CL}" "${CHANGELOG}"
  trap - EXIT
fi

git add "${CHANGELOG}"
git commit -m "docs(changelog): close [Unreleased] as ${TAG}"

if ! git push origin "HEAD:refs/heads/${DEFAULT_BRANCH}"; then
  echo "auto-tag: git push of CHANGELOG closure commit failed" >&2
  exit 5
fi

echo "auto-tag: pushed CHANGELOG closure to ${DEFAULT_BRANCH}"
