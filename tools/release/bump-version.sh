#!/usr/bin/env bash
#
# tools/release/bump-version.sh
#
# Computes the next semver for forge based on conventional-commit
# subjects (no merges) on the current branch between the highest
# validated release checkpoint (or the base branch when no checkpoint
# exists) and HEAD. By default rewrites FORGE_VERSION in install.sh and
# .claude-plugin/plugin.json to match; --dry-run prints the result
# without mutating either file.
#
# Designed to be idempotent and resumable. Re-running this script over
# the same HEAD always produces the same BUMP/CURRENT/NEXT triple. A
# working tree that has been partially bumped to NEXT is recognised and
# left untouched (resume). A working tree holding an unexpected third
# version aborts — in install.sh AND in .claude-plugin/plugin.json — so
# the caller can resolve the conflict instead of silently overwriting it.
# This preflight is read-only and runs before --dry-run exits.
#
# Versioning policy (no merges):
#   feat(...) / feature(...)                -> minor
#   fix(...) | refactor(...) | perf(...)    -> patch
#   chore / docs / test / build / ci / ...  -> none
#   Highest category wins.
#
# Checkpoint policy:
#   A release checkpoint is a commit whose subject matches EXACTLY
#     ^chore\(release\): bump version to v[0-9]+\.[0-9]+\.[0-9]+$
#   Starting at the base version, walk checkpoints chronologically
#   (oldest first). For each candidate: classify the non-merge range
#   from the current anchor up to (but not including) the candidate,
#   derive the expected BUMP and NEXT, then verify (a) the declared
#   version matches EXPECTED_NEXT, (b) the commit tree has the same
#   FORGE_VERSION in install.sh and (when .claude-plugin/plugin.json
#   is present in that tree) the same version in the manifest, and
#   (c) the committed files are a subset of the release artifacts
#   permitted for that BUMP. The first inconsistency aborts.
#
# Flags:
#   --base <branch>   Base branch (default: master).
#   --dry-run         Print the computed values only; do not edit. The
#                     read-only working-tree preflight still runs, so the
#                     output tells you whether a real run would succeed.
#   -h | --help       Show this help text.
#
# Stdout (one line, machine-parseable):
#   BUMP=<none|patch|minor>  CURRENT=<x.y.z>  NEXT=<x.y.z>  FEATS=<n>  FIXES=<n>  OTHERS=<n>
#
# Exit codes:
#   0  Success (includes BUMP=none and idempotent resume).
#   2  Argument / precondition failure (not a git repo, install.sh
#      missing or malformed, invalid base, base not ancestor of HEAD,
#      base diverged from origin/<base>, jq missing but manifest
#      present, malformed checkpoint subject, checkpoint inconsistent
#      with its declared version, install.sh or .claude-plugin/plugin.json
#      working-tree version outside the {CURRENT, NEXT} set).
#   3  install.sh / plugin.json edit failed.
#
set -euo pipefail

BASE_BRANCH="master"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      if [[ $# -lt 2 ]]; then
        echo "bump-version: --base requires an argument" >&2
        exit 2
      fi
      BASE_BRANCH="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '/^# tools\/release\/bump-version/,/^# Exit codes:/p' "$0"
      exit 0
      ;;
    *)
      echo "bump-version: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  echo "bump-version: not inside a git repository" >&2
  exit 2
fi

INSTALL_SH="${REPO_ROOT}/install.sh"
if [[ ! -f "${INSTALL_SH}" ]]; then
  echo "bump-version: install.sh not found at repo root" >&2
  exit 2
fi

# jq is required only when the manifest is present, so we can read /
# patch .version consistently.
HAVE_PLUGIN_JSON=0
if [[ -f "${REPO_ROOT}/.claude-plugin/plugin.json" ]]; then
  HAVE_PLUGIN_JSON=1
  if ! command -v jq >/dev/null 2>&1; then
    echo "bump-version: jq is required because .claude-plugin/plugin.json exists" >&2
    exit 2
  fi
fi

# Base must exist, be an ancestor of HEAD, and (when origin/<base>
# exists) be in lockstep with the remote so we never derive a version
# from a stale local snapshot.
if ! git rev-parse --verify --quiet "${BASE_BRANCH}" >/dev/null; then
  echo "bump-version: base branch '${BASE_BRANCH}' does not exist" >&2
  exit 2
fi
BASE_SHA="$(git rev-parse "${BASE_BRANCH}")"
HEAD_SHA="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "${BASE_SHA}" "${HEAD_SHA}"; then
  echo "bump-version: base '${BASE_BRANCH}' (${BASE_SHA}) is not an ancestor of HEAD (${HEAD_SHA})" >&2
  exit 2
fi
if git rev-parse --verify --quiet "origin/${BASE_BRANCH}" >/dev/null; then
  ORIGIN_BASE_SHA="$(git rev-parse "origin/${BASE_BRANCH}")"
  if [[ "${ORIGIN_BASE_SHA}" != "${BASE_SHA}" ]]; then
    echo "bump-version: base '${BASE_BRANCH}' (${BASE_SHA}) differs from origin/${BASE_BRANCH} (${ORIGIN_BASE_SHA}); resync before bumping" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Helpers (all read-only against the filesystem + git)
# ---------------------------------------------------------------------------
_validate_semver() {
  local v="$1"
  if ! printf '%s' "${v}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "bump-version: invalid semver '${v}'" >&2
    exit 2
  fi
}

# Reads FORGE_VERSION from a git blob when <sha> is non-empty, otherwise
# from the working tree file.
_read_install_version() {
  local sha="$1"
  if [[ -n "${sha}" ]]; then
    git show "${sha}:install.sh" 2>/dev/null \
      | grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' \
      | head -n 1 \
      | sed -E 's/^FORGE_VERSION="([^"]+)"$/\1/'
  else
    grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "${INSTALL_SH}" \
      | head -n 1 \
      | sed -E 's/^FORGE_VERSION="([^"]+)"$/\1/'
  fi
}

_read_plugin_version() {
  local sha="$1"
  if [[ -n "${sha}" ]]; then
    if ! git cat-file -e "${sha}:.claude-plugin/plugin.json" 2>/dev/null; then
      return 0
    fi
    git show "${sha}:.claude-plugin/plugin.json" 2>/dev/null \
      | jq -r '.version // empty'
  else
    jq -r '.version // empty' "${REPO_ROOT}/.claude-plugin/plugin.json" 2>/dev/null \
      || true
  fi
}

# Classifies commits in <range> (no merges) into feats/fixes/others via
# globals FEATS/FIXES/OTHERS.
_classify_range() {
  local range="$1"
  local feats=0 fixes=0 others=0
  local subjects
  subjects="$(git log "${range}" --no-merges --format='%s' 2>/dev/null || true)"
  while IFS= read -r SUBJECT; do
    [[ -z "${SUBJECT}" ]] && continue
    case "${SUBJECT}" in
      feat:*|feat\(*\):*|feature:*|feature\(*\):*)
        feats=$((feats + 1)) ;;
      fix:*|fix\(*\):*|refactor:*|refactor\(*\):*|perf:*|perf\(*\):*)
        fixes=$((fixes + 1)) ;;
      *)
        others=$((others + 1)) ;;
    esac
  done <<EOF
${subjects}
EOF
  FEATS="${feats}"
  FIXES="${fixes}"
  OTHERS="${others}"
}

_bump_from_counts() {
  if   (( FEATS > 0 )); then echo "minor"
  elif (( FIXES > 0 )); then echo "patch"
  else                       echo "none"
  fi
}

# Human form of the {CURRENT, NEXT} set the working tree may hold, used in
# the preflight diagnostics.
_describe_expected_versions() {
  if [[ "${CURRENT}" == "${NEXT}" ]]; then
    printf "'%s'" "${CURRENT}"
  else
    printf "'%s' (anchor) or '%s' (target)" "${CURRENT}" "${NEXT}"
  fi
}

_compute_next() {
  local v="$1" bump="$2"
  local major rest minor patch
  major="${v%%.*}"
  rest="${v#*.}"
  minor="${rest%%.*}"
  patch="${rest#*.}"
  case "${bump}" in
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    none)  echo "${v}" ;;
    *)
      echo "bump-version: internal error: unknown bump '${bump}'" >&2
      exit 2
      ;;
  esac
}

CHECKPOINT_REGEX='^chore\(release\): bump version to v[0-9]+\.[0-9]+\.[0-9]+$'

_extract_declared_version() {
  printf '%s' "$1" | sed -E 's/^chore\(release\): bump version to v([0-9]+\.[0-9]+\.[0-9]+)$/\1/'
}

# Permitted release-artifact paths for a given BUMP. The manifest is
# only required when it already exists in the target blob/tree.
_permitted_paths_for() {
  local bump="$1" sha="$2"
  case "${bump}" in
    patch|minor)
      printf 'install.sh CHANGELOG.md'
      if [[ -n "${sha}" ]] && git cat-file -e "${sha}:.claude-plugin/plugin.json" 2>/dev/null; then
        printf ' .claude-plugin/plugin.json'
      elif [[ -z "${sha}" ]] && [[ -f "${REPO_ROOT}/.claude-plugin/plugin.json" ]]; then
        printf ' .claude-plugin/plugin.json'
      fi
      ;;
    none)
      printf 'CHANGELOG.md'
      if [[ -n "${sha}" ]] && git cat-file -e "${sha}:.claude-plugin/plugin.json" 2>/dev/null; then
        printf ' .claude-plugin/plugin.json'
      elif [[ -z "${sha}" ]] && [[ -f "${REPO_ROOT}/.claude-plugin/plugin.json" ]]; then
        printf ' .claude-plugin/plugin.json'
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Walk release checkpoints from oldest to newest starting at the base.
# Each iteration classifies the non-merge range from the current anchor
# up to (but not including) the candidate and validates the candidate.
# The first inconsistency aborts.
# ---------------------------------------------------------------------------
ANCHOR_SHA="${BASE_SHA}"
ANCHOR_VERSION="$(_read_install_version "${BASE_SHA}")"
if [[ -z "${ANCHOR_VERSION}" ]]; then
  echo "bump-version: cannot read FORGE_VERSION at base '${BASE_BRANCH}' (${BASE_SHA})" >&2
  exit 2
fi
_validate_semver "${ANCHOR_VERSION}"

# Chronological order (oldest first) so we advance the anchor correctly.
PAIRS="$(git log "${BASE_BRANCH}..HEAD" --reverse --no-merges --format='%H %s' 2>/dev/null || true)"

while IFS= read -r LINE; do
  [[ -z "${LINE}" ]] && continue
  SHA="${LINE%% *}"
  SUBJ="${LINE#* }"
  if ! [[ "${SUBJ}" =~ ${CHECKPOINT_REGEX} ]]; then
    continue
  fi

  DECLARED="$(_extract_declared_version "${SUBJ}")"
  if [[ -z "${DECLARED}" || "${DECLARED}" = "${SUBJ}" ]]; then
    echo "bump-version: malformed checkpoint subject at ${SHA}: ${SUBJ}" >&2
    exit 2
  fi
  _validate_semver "${DECLARED}"

  # Classify the range up to (but not including) this checkpoint.
  _classify_range "${ANCHOR_SHA}..${SHA}^"
  CK_BUMP="$(_bump_from_counts)"
  EXPECTED_NEXT="$(_compute_next "${ANCHOR_VERSION}" "${CK_BUMP}")"
  if [[ "${DECLARED}" != "${EXPECTED_NEXT}" ]]; then
    echo "bump-version: checkpoint at ${SHA} declares ${DECLARED} but range ${ANCHOR_SHA}..${SHA}^ yields ${EXPECTED_NEXT} (CURRENT=${ANCHOR_VERSION}, BUMP=${CK_BUMP})" >&2
    exit 2
  fi

  # Validate FORGE_VERSION in the commit tree.
  TREE_VERSION="$(_read_install_version "${SHA}")"
  if [[ -z "${TREE_VERSION}" ]]; then
    echo "bump-version: cannot read FORGE_VERSION in tree of ${SHA}" >&2
    exit 2
  fi
  if [[ "${TREE_VERSION}" != "${DECLARED}" ]]; then
    echo "bump-version: tree of ${SHA} has FORGE_VERSION=${TREE_VERSION} but subject declares ${DECLARED}" >&2
    exit 2
  fi

  # Validate plugin.json when it exists in that tree.
  if git cat-file -e "${SHA}:.claude-plugin/plugin.json" 2>/dev/null; then
    PLUGIN_V="$(_read_plugin_version "${SHA}")"
    if [[ -z "${PLUGIN_V}" || "${PLUGIN_V}" != "${DECLARED}" ]]; then
      echo "bump-version: plugin.json of ${SHA} has version='${PLUGIN_V}' but checkpoint declares ${DECLARED}" >&2
      exit 2
    fi
  fi

  # Validate the committed-file set: every touched path must be permitted
  # for that BUMP (release artifacts only).
  PERMITTED="$(_permitted_paths_for "${CK_BUMP}" "${SHA}")"
  ACTUAL_FILES="$(git show --pretty=format: --name-only "${SHA}" 2>/dev/null | sed '/^$/d' | sort -u || true)"
  while IFS= read -r F; do
    [[ -z "${F}" ]] && continue
    if [[ " ${PERMITTED} " != *" ${F} "* ]]; then
      echo "bump-version: checkpoint at ${SHA} contains unexpected path '${F}' (allowed: ${PERMITTED})" >&2
      exit 2
    fi
  done <<EOF
${ACTUAL_FILES}
EOF

  # Advance anchor.
  ANCHOR_SHA="${SHA}"
  ANCHOR_VERSION="${DECLARED}"
done <<EOF
${PAIRS}
EOF

# ---------------------------------------------------------------------------
# Final range (anchor..HEAD) classification drives the output line.
# ---------------------------------------------------------------------------
CURRENT="${ANCHOR_VERSION}"
_classify_range "${ANCHOR_SHA}..HEAD"
BUMP="$(_bump_from_counts)"
NEXT="$(_compute_next "${CURRENT}" "${BUMP}")"

echo "BUMP=${BUMP}  CURRENT=${CURRENT}  NEXT=${NEXT}  FEATS=${FEATS}  FIXES=${FIXES}  OTHERS=${OTHERS}"

# ---------------------------------------------------------------------------
# Working-tree preflight (read-only). It runs BEFORE the --dry-run exit so a
# dry run answers "could this release run at all?" instead of reporting a
# bump for a tree a real run would refuse to touch. Nothing above this
# point writes to the working tree.
#
# install.sh and .claude-plugin/plugin.json may be at CURRENT (the bump has
# not happened yet) or at NEXT (a prior run already bumped it but
# commit-release hasn't run yet); any other value is a conflict and must
# abort without overwriting.
# ---------------------------------------------------------------------------
EXPECTED_VERS="$(_describe_expected_versions)"

WT_INSTALL_V="$(_read_install_version "")"
if [[ -z "${WT_INSTALL_V}" ]]; then
  echo "bump-version: cannot read FORGE_VERSION from working tree" >&2
  exit 2
fi
if [[ "${WT_INSTALL_V}" != "${CURRENT}" && "${WT_INSTALL_V}" != "${NEXT}" ]]; then
  echo "bump-version: install.sh working tree has unexpected version '${WT_INSTALL_V}'; expected ${EXPECTED_VERS}" >&2
  exit 2
fi

WT_PLUGIN_V=""
if [[ "${HAVE_PLUGIN_JSON}" -eq 1 ]]; then
  WT_PLUGIN_V="$(_read_plugin_version "")"
  if [[ -n "${WT_PLUGIN_V}" && "${WT_PLUGIN_V}" != "${CURRENT}" && "${WT_PLUGIN_V}" != "${NEXT}" ]]; then
    echo "bump-version: .claude-plugin/plugin.json working tree has unexpected version '${WT_PLUGIN_V}'; expected ${EXPECTED_VERS}" >&2
    exit 2
  fi
fi

# BUMP=none: nothing to write. NEXT == CURRENT in this path, so the
# preflight above already proved that both artifacts hold the anchor
# version.
if [[ "${BUMP}" == "none" ]]; then
  exit 0
fi

# Dry-run: past the preflight, before any write.
if [[ "${DRY_RUN}" -eq 1 ]]; then
  exit 0
fi

# Resume path: WT already at NEXT (a prior run bumped it but commit-release
# hasn't run yet). Skip install.sh re-edit; still sync the manifest if it
# lagged behind.
if [[ "${WT_INSTALL_V}" == "${NEXT}" ]]; then
  if [[ "${HAVE_PLUGIN_JSON}" -eq 1 ]]; then
    WT_PLUGIN_V="$(_read_plugin_version "")"
    if [[ "${WT_PLUGIN_V}" != "${NEXT}" ]]; then
      TMP_PLUGIN="$(mktemp)"
      if ! jq --arg v "${NEXT}" '.version = $v' "${REPO_ROOT}/.claude-plugin/plugin.json" > "${TMP_PLUGIN}" \
         || ! jq -e --arg v "${NEXT}" '.version == $v' "${TMP_PLUGIN}" >/dev/null 2>&1; then
        rm -f "${TMP_PLUGIN}"
        echo "bump-version: failed to sync .claude-plugin/plugin.json to ${NEXT}" >&2
        exit 3
      fi
      mv "${TMP_PLUGIN}" "${REPO_ROOT}/.claude-plugin/plugin.json"
    fi
  fi
  exit 0
fi

# Normal bump path: WT is at CURRENT, rewrite install.sh CURRENT -> NEXT.
TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
if ! sed -E "s/^FORGE_VERSION=\"${CURRENT//./\\.}\"\$/FORGE_VERSION=\"${NEXT}\"/" \
      "${INSTALL_SH}" > "${TMP}"; then
  echo "bump-version: sed substitution failed" >&2
  exit 3
fi
if ! grep -qE "^FORGE_VERSION=\"${NEXT//./\\.}\"\$" "${TMP}"; then
  echo "bump-version: post-edit verification failed (NEXT=${NEXT} not present)" >&2
  exit 3
fi
if grep -qE "^FORGE_VERSION=\"${CURRENT//./\\.}\"\$" "${TMP}"; then
  echo "bump-version: post-edit verification failed (CURRENT=${CURRENT} still present)" >&2
  exit 3
fi
mv "${TMP}" "${INSTALL_SH}"
trap - EXIT

if [[ "${HAVE_PLUGIN_JSON}" -eq 1 ]]; then
  TMP_PLUGIN="$(mktemp)"
  trap 'rm -f "${TMP_PLUGIN}"' EXIT
  if ! jq --arg v "${NEXT}" '.version = $v' "${REPO_ROOT}/.claude-plugin/plugin.json" > "${TMP_PLUGIN}" \
     || ! jq -e --arg v "${NEXT}" '.version == $v' "${TMP_PLUGIN}" >/dev/null 2>&1; then
    rm -f "${TMP_PLUGIN}"
    echo "bump-version: failed to sync .claude-plugin/plugin.json to ${NEXT}" >&2
    exit 3
  fi
  mv "${TMP_PLUGIN}" "${REPO_ROOT}/.claude-plugin/plugin.json"
  trap - EXIT
fi

exit 0
