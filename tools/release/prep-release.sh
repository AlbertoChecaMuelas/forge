#!/usr/bin/env bash
#
# tools/release/prep-release.sh
#
# Prepare a release by bumping FORGE_VERSION, .claude-plugin/plugin.json
# version, and closing the [Unreleased] section in CHANGELOG.md.
# Opens a PR with auto-merge; once merged, the existing auto-tag.sh takes
# over to create the tag.
#
# Triggers:
#   - workflow_dispatch (manual button)  — see .github/workflows/release-prep.yml
#   - schedule (cron weekly)             — same workflow
#
# Inputs (env, all optional):
#   BUMP_TYPE   auto | patch | minor   (default: auto)
#               auto  = derived from conventional-commit prefixes of
#                       commits in master..HEAD (uses bump-version.sh logic)
#               patch = bump only the patch component (e.g. 0.3.1 -> 0.3.2)
#               minor = bump the minor component, reset patch to 0
#                       (e.g. 0.3.1 -> 0.4.0)
#
# Required environment when running in CI (provided by GitHub Actions):
#   - GITHUB_TOKEN      : used for `gh pr create` / `gh pr merge --auto`
#                         and remote URL auth (must have contents:write +
#                         pull-requests:write at the workflow level)
#   - GITHUB_REPOSITORY : owner/repo
#
# Idempotency:
#   - If tag v<NEXT> already exists locally or on origin: exit 0
#   - If branch release/v<NEXT>-prep already exists on origin: exit 0
#   - If [Unreleased] in CHANGELOG.md is empty: exit 0
#
# Exit codes:
#   0  Success (or no-op due to idempotency)
#   2  Invalid input or pre-condition failure
#   3  git push of the prep branch failed
#   4  gh pr merge --auto failed
#
set -euo pipefail

BUMP_TYPE="${BUMP_TYPE:-auto}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
INSTALL_SH="${REPO_ROOT}/install.sh"
CHANGELOG="${REPO_ROOT}/CHANGELOG.md"
PLUGIN_JSON="${REPO_ROOT}/.claude-plugin/plugin.json"

# Configure remote URL with token so push works in CI without a helper.
if [[ -n "${GITHUB_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
  git remote set-url origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
fi

# Parse current version.
CURRENT="$(
  grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "${INSTALL_SH}" \
    | head -n 1 \
    | sed -E 's/^FORGE_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/'
)"

if [[ -z "${CURRENT}" || ! "${CURRENT}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "prep-release: could not parse FORGE_VERSION from install.sh" >&2
  exit 2
fi

CUR_MAJOR="${CURRENT%%.*}"
CUR_REST="${CURRENT#*.}"
CUR_MINOR="${CUR_REST%%.*}"
CUR_PATCH="${CUR_REST#*.}"

# Compute next version per BUMP_TYPE.
case "${BUMP_TYPE}" in
  auto)
    RESULT="$(bash "${REPO_ROOT}/tools/release/bump-version.sh" --base master --dry-run)"
    BUMP_DETECTED="$(echo "${RESULT}" | awk '{print $1}' | cut -d= -f2)"
    NEXT="$(echo "${RESULT}" | awk '{print $3}' | cut -d= -f2)"
    if [[ "${BUMP_DETECTED}" == "none" || "${NEXT}" == "${CURRENT}" ]]; then
      echo "prep-release: bump-version detected no bump (BUMP=none); nothing to do"
      exit 0
    fi
    echo "prep-release: bump-version detected BUMP=${BUMP_DETECTED}  CURRENT=${CURRENT}  NEXT=${NEXT}"
    ;;
  patch)
    NEXT="${CUR_MAJOR}.${CUR_MINOR}.$((CUR_PATCH + 1))"
    ;;
  minor)
    NEXT="${CUR_MAJOR}.$((CUR_MINOR + 1)).0"
    ;;
  *)
    echo "prep-release: invalid BUMP_TYPE: ${BUMP_TYPE} (expected: auto|patch|minor)" >&2
    exit 2
    ;;
esac

TAG="v${NEXT}"
BRANCH_NAME="release/${TAG}-prep"

echo "prep-release: preparing release ${TAG} on branch ${BRANCH_NAME}"

# Idempotency 1: tag already exists (locally or on origin).
if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null \
   || git ls-remote --tags --exit-code origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  echo "prep-release: tag ${TAG} already exists; nothing to do"
  exit 0
fi

# Idempotency 2: branch already exists on origin.
if git ls-remote --heads origin "refs/heads/${BRANCH_NAME}" 2>/dev/null | grep -q .; then
  echo "prep-release: branch ${BRANCH_NAME} already exists on origin; nothing to do"
  exit 0
fi

# Idempotency 3: [Unreleased] section has no content.
UNRELEASED_BODY="$(
  awk '
    /^## \[Unreleased\]/ { inside = 1; next }
    inside && /^## \[/   { inside = 0 }
    inside               { print }
  ' "${CHANGELOG}"
)"

if [[ -z "$(printf '%s' "${UNRELEASED_BODY}" | tr -d '[:space:]')" ]]; then
  echo "prep-release: [Unreleased] section is empty; nothing to do"
  exit 0
fi

# Create the prep branch from master.
git checkout -b "${BRANCH_NAME}"

# Bump install.sh.
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

sed -E "s/^FORGE_VERSION=\"${CURRENT//./\\.}\"\$/FORGE_VERSION=\"${NEXT}\"/" \
  "${INSTALL_SH}" > "${TMP}"

if ! grep -qE "^FORGE_VERSION=\"${NEXT//./\\.}\"\$" "${TMP}"; then
  echo "prep-release: install.sh edit verification failed (NEXT=${NEXT} not present)" >&2
  exit 2
fi
mv "${TMP}" "${INSTALL_SH}"
trap - EXIT

# Bump .claude-plugin/plugin.json.
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

if jq --arg v "${NEXT}" '.version = $v' "${PLUGIN_JSON}" > "${TMP}" 2>/dev/null \
   && jq -e --arg v "${NEXT}" '.version == $v' "${TMP}" >/dev/null 2>&1; then
  mv "${TMP}" "${PLUGIN_JSON}"
  trap - EXIT
else
  rm -f "${TMP}"
  echo "prep-release: plugin.json edit failed" >&2
  exit 2
fi

# Rewrite CHANGELOG.md: insert empty [Unreleased] above existing [Unreleased],
# rename existing [Unreleased] to [NEXT] - DATE.
RELEASE_DATE="$(date +%Y-%m-%d)"
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT

awk -v nver="${NEXT}" -v date="${RELEASE_DATE}" '
  /^## \[Unreleased\]/ && !done {
    print "## [Unreleased]"
    print ""
    print ""
    print "## [" nver "] - " date
    done = 1
    next
  }
  { print }
' "${CHANGELOG}" > "${TMP}"

if grep -qF "## [${NEXT}] - ${RELEASE_DATE}" "${TMP}"; then
  mv "${TMP}" "${CHANGELOG}"
  trap - EXIT
else
  rm -f "${TMP}"
  echo "prep-release: CHANGELOG.md rewrite verification failed" >&2
  exit 2
fi

git config --local user.email "ci-bot@forge"
git config --local user.name "forge-ci-bot"

git add "${INSTALL_SH}" "${PLUGIN_JSON}" "${CHANGELOG}"
git commit -m "chore(release): v${NEXT}"

if ! git push origin "${BRANCH_NAME}"; then
  echo "prep-release: git push of ${BRANCH_NAME} failed" >&2
  exit 3
fi

PR_TITLE="chore(release): v${NEXT}"
PR_BODY="Auto-generated by release-prep workflow.

Bumps:
- \`FORGE_VERSION\` in install.sh to ${NEXT}
- plugin.json version to ${NEXT}
- Closes [Unreleased] in CHANGELOG.md as [${NEXT}] - ${RELEASE_DATE}

Auto-merges once \`test\` passes. The existing auto-tag.sh will then create tag ${TAG} on the merged commit."

echo "prep-release: opening PR ${BRANCH_NAME} -> master"
if ! gh pr create \
    --base master \
    --head "${BRANCH_NAME}" \
    --title "${PR_TITLE}" \
    --body "${PR_BODY}" 2>&1; then
  echo "prep-release: gh pr create returned non-zero (PR may already exist); continuing"
fi

echo "prep-release: enabling auto-merge (squash) on PR for ${BRANCH_NAME}"
if ! gh pr merge --auto --squash "${BRANCH_NAME}" 2>&1; then
  echo "prep-release: gh pr merge --auto failed" >&2
  exit 4
fi

echo "prep-release: PR ${BRANCH_NAME} will auto-merge once 'test' check passes"