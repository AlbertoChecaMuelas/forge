#!/usr/bin/env bash
#
# tools/release/create-pr.sh
#
# Creates a GitHub Pull Request from PR-DESCRIPTION.md at the repo root.
#
# Behaviour:
#   1. Verifies precondition: `gh` is on PATH, repo has a remote, current
#      branch is not a protected branch.
#   2. Verifies PR-DESCRIPTION.md exists and is fresh for the current HEAD:
#      - Reads the stamp `<!-- forge:pr-description head=<SHA> ... -->` at
#        the bottom of the file.
#      - If stamp HEAD matches `git rev-parse HEAD` -> file is fresh, proceed.
#      - If stamp HEAD differs, or the stamp is missing -> file is stale.
#        Exit 3 so the caller (orchestrator) can regenerate via /mr-description
#        and re-run, unless --no-regenerate is passed (then proceed anyway).
#   3. Extracts title (first non-empty, non-separator line) and body
#      (from the first `# ` heading onwards, stripping any leading `---`
#      or blank lines).
#   4. Calls `gh pr create` with the extracted title and body, targeting
#      the base branch (default: master, overridable via --base).
#      If a PR already exists for the current branch, falls back to
#      `gh pr edit` to update the existing PR (upsert behaviour).
#
# Flags:
#   --base <branch>      Base branch for the PR (default: master).
#   --no-regenerate      If PR-DESCRIPTION.md is stale, proceed anyway
#                        instead of exiting 3.
#   --draft              Create the PR as draft.
#   --dry-run            Print what would be sent to gh; do not call it.
#
# Exit codes:
#   0  PR created/updated successfully (or dry-run completed).
#   2  Precondition failed (no gh, no remote, protected branch, no file).
#   3  PR-DESCRIPTION.md is stale relative to HEAD; regenerate and retry.
#   4  `gh pr create` / `gh pr edit` failed.
#   5  Could not parse title or body from PR-DESCRIPTION.md.
#
set -euo pipefail

BASE_BRANCH="master"
NO_REGENERATE=0
DRAFT=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)           BASE_BRANCH="$2"; shift 2 ;;
    --no-regenerate)  NO_REGENERATE=1; shift ;;
    --draft)          DRAFT=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0
      ;;
    *)
      echo "create-pr: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  echo "create-pr: not inside a git repository" >&2
  exit 2
fi

PR_FILE="${REPO_ROOT}/PR-DESCRIPTION.md"

# --- Precondition 1: gh on PATH ---
if ! command -v gh >/dev/null 2>&1; then
  echo "create-pr: gh (GitHub CLI) is not installed; aborting" >&2
  exit 2
fi

# --- Precondition 2: repo has a remote ---
if ! git remote get-url origin >/dev/null 2>&1; then
  echo "create-pr: no 'origin' remote configured; aborting" >&2
  exit 2
fi

# --- Precondition 3: current branch is not protected ---
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
case "${CURRENT_BRANCH}" in
  master|main|dev)
    echo "create-pr: refusing to open PR from protected branch '${CURRENT_BRANCH}'" >&2
    exit 2
    ;;
esac

# --- Precondition 4: PR-DESCRIPTION.md exists ---
if [[ ! -f "${PR_FILE}" ]]; then
  echo "create-pr: ${PR_FILE} not found; run /pr-description first" >&2
  exit 2
fi

# --- Precondition 5: branch is pushed to origin ---
REMOTE_SHA="$(git rev-parse "origin/${CURRENT_BRANCH}" 2>/dev/null || true)"
LOCAL_SHA="$(git rev-parse HEAD)"
if [[ "${REMOTE_SHA}" != "${LOCAL_SHA}" ]]; then
  echo "create-pr: branch '${CURRENT_BRANCH}' has unpushed commits." >&2
  echo "create-pr: push first:  git push origin ${CURRENT_BRANCH}" >&2
  exit 2
fi

# --- Staleness check ---
CURRENT_SHA="$(git rev-parse HEAD)"
STAMP_LINE="$(grep -E '^<!-- forge:pr-description ' "${PR_FILE}" | tail -n 1 || true)"

if [[ -z "${STAMP_LINE}" ]]; then
  if [[ "${NO_REGENERATE}" -eq 0 ]]; then
    echo "create-pr: PR-DESCRIPTION.md has no stamp; cannot verify freshness." >&2
    echo "create-pr: regenerate with /pr-description or re-run with --no-regenerate." >&2
    exit 3
  fi
  echo "create-pr: stamp missing but --no-regenerate set; proceeding"
else
  STAMP_HEAD="$(printf '%s' "${STAMP_LINE}" | sed -E 's/.*head=([0-9a-f]+).*/\1/')"
  if [[ "${STAMP_HEAD}" != "${CURRENT_SHA}" ]]; then
    if [[ "${NO_REGENERATE}" -eq 0 ]]; then
      echo "create-pr: PR-DESCRIPTION.md is stale (stamp=${STAMP_HEAD}, head=${CURRENT_SHA})." >&2
      echo "create-pr: regenerate with /pr-description or re-run with --no-regenerate." >&2
      exit 3
    fi
    echo "create-pr: stamp stale but --no-regenerate set; proceeding"
  fi
fi

# --- Extract title and body ---
TITLE="$(awk '
  /^[[:space:]]*$/ { next }
  /^---[[:space:]]*$/ { next }
  { print; exit }
' "${PR_FILE}")"

if [[ -z "${TITLE}" ]]; then
  echo "create-pr: could not extract title from ${PR_FILE}" >&2
  exit 5
fi

BODY="$(awk '
  BEGIN { found = 0 }
  /^# / { found = 1 }
  found && !/^<!-- forge:pr-description / { print }
' "${PR_FILE}")"

if [[ -z "${BODY}" ]]; then
  echo "create-pr: could not extract body (no '"'"'# '"'"' heading) from ${PR_FILE}" >&2
  exit 5
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "--- create-pr: DRY RUN ---"
  echo "title : ${TITLE}"
  echo "base  : ${BASE_BRANCH}"
  echo "head  : ${CURRENT_BRANCH}"
  echo "draft : ${DRAFT}"
  echo "--- body ---"
  echo "${BODY}"
  echo "--- end ---"
  exit 0
fi

# --- Build gh pr create args ---
GH_ARGS=(
  pr create
  --title  "${TITLE}"
  --body   "${BODY}"
  --base   "${BASE_BRANCH}"
  --head   "${CURRENT_BRANCH}"
)

if [[ "${DRAFT}" -eq 1 ]]; then
  GH_ARGS+=( --draft )
fi

# --- Execute (upsert: create, fallback to edit if PR already exists) ---
CREATE_OUTPUT="$(gh "${GH_ARGS[@]}" 2>&1)" && CREATE_EXIT=0 || CREATE_EXIT=$?

if [[ "${CREATE_EXIT}" -eq 0 ]]; then
  echo "create-pr: pull request created from ${CURRENT_BRANCH} into ${BASE_BRANCH}"
  echo "${CREATE_OUTPUT}"
else
  # Check whether failure is "a pull request for this branch already exists"
  EXISTING_URL=""
  if printf '%s' "${CREATE_OUTPUT}" | grep -qiE 'already exists|already a pull request'; then
    EXISTING_URL="$(gh pr view --head "${CURRENT_BRANCH}" --json url --jq '.url' 2>/dev/null || true)"
  fi

  if [[ -z "${EXISTING_URL}" ]]; then
    echo "create-pr: gh pr create failed (exit ${CREATE_EXIT}):" >&2
    printf '%s\n' "${CREATE_OUTPUT}" >&2
    exit 4
  fi

  echo "create-pr: PR already exists for this branch (${EXISTING_URL}); updating instead"
  if ! gh pr edit "${EXISTING_URL}" \
        --title "${TITLE}" \
        --body  "${BODY}"; then
    echo "create-pr: gh pr edit ${EXISTING_URL} failed" >&2
    exit 4
  fi
  echo "create-pr: pull request updated (${CURRENT_BRANCH} -> ${BASE_BRANCH}): ${EXISTING_URL}"
fi
