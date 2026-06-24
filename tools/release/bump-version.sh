#!/usr/bin/env bash
#
# tools/release/bump-version.sh
#
# Computes the next semver for forge based on conventional-commit
# prefixes of commits on the current branch vs a base branch (default: master),
# and (unless --dry-run) bumps the FORGE_VERSION literal in install.sh.
#
# Versioning policy:
#   feat(...)                                  -> minor bump (x.Y.z -> x.(Y+1).0)
#   fix(...) | refactor(...) | perf(...)       -> patch bump (x.y.Z -> x.y.(Z+1))
#   chore/docs/test/build/ci/style/...         -> no bump
#   Highest category wins (any feat => minor; only patch-worthy => patch; else none).
#
# Flags:
#   --base <branch>   Base branch for the commit range (default: master).
#   --dry-run         Print the computed bump information; do NOT edit install.sh.
#   -h | --help       Show this help text.
#
# Output on stdout (single line, always, machine-parseable):
#   BUMP=<none|patch|minor>  CURRENT=<x.y.z>  NEXT=<x.y.z>  FEATS=<n>  FIXES=<n>  OTHERS=<n>
#
# Exit codes:
#   0  Success (including BUMP=none).
#   2  Precondition failure (not a git repo, install.sh missing, malformed version, invalid base).
#   3  install.sh edit failed.
#
set -euo pipefail

BASE_BRANCH="master"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)     BASE_BRANCH="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
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
  echo "BUMP=none  CURRENT=unknown  NEXT=unknown  FEATS=0  FIXES=0  OTHERS=0"
  exit 0
fi

if ! git rev-parse --verify --quiet "${BASE_BRANCH}" >/dev/null; then
  echo "bump-version: base branch '${BASE_BRANCH}' does not exist" >&2
  exit 2
fi

CURRENT="$(grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "${INSTALL_SH}" \
  | head -n 1 \
  | sed -E 's/^FORGE_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/\1/')"

if [[ -z "${CURRENT}" ]]; then
  echo "BUMP=none  CURRENT=unknown  NEXT=unknown  FEATS=0  FIXES=0  OTHERS=0"
  exit 0
fi

CUR_MAJOR="${CURRENT%%.*}"
CUR_REST="${CURRENT#*.}"
CUR_MINOR="${CUR_REST%%.*}"
CUR_PATCH="${CUR_REST#*.}"

FEATS=0
FIXES=0
OTHERS=0

while IFS= read -r SUBJECT; do
  [[ -z "${SUBJECT}" ]] && continue
  case "${SUBJECT}" in
    feat:*|feat\(*\):*|feature:*|feature\(*\):*)
      FEATS=$((FEATS + 1)) ;;
    fix:*|fix\(*\):*|refactor:*|refactor\(*\):*|perf:*|perf\(*\):*)
      FIXES=$((FIXES + 1)) ;;
    *)
      OTHERS=$((OTHERS + 1)) ;;
  esac
done < <(git log "${BASE_BRANCH}..HEAD" --no-merges --format='%s' 2>/dev/null)

if   (( FEATS > 0 )); then BUMP="minor"
elif (( FIXES > 0 )); then BUMP="patch"
else                       BUMP="none"
fi

case "${BUMP}" in
  minor) NEXT="${CUR_MAJOR}.$((CUR_MINOR + 1)).0" ;;
  patch) NEXT="${CUR_MAJOR}.${CUR_MINOR}.$((CUR_PATCH + 1))" ;;
  none)  NEXT="${CURRENT}" ;;
esac

echo "BUMP=${BUMP}  CURRENT=${CURRENT}  NEXT=${NEXT}  FEATS=${FEATS}  FIXES=${FIXES}  OTHERS=${OTHERS}"

# Keep the Claude Code plugin manifest version in lockstep with FORGE_VERSION.
# Runs even when BUMP=none (re-syncs a manually desynced plugin.json); never on --dry-run.
_sync_plugin_version() {
  local want="$1"
  local plugin_json="${REPO_ROOT}/.claude-plugin/plugin.json"
  [ -f "${plugin_json}" ] || return 0
  local have
  have="$(jq -r .version "${plugin_json}" 2>/dev/null || echo "")"
  [ "${have}" = "${want}" ] && return 0
  local tmp_plugin
  tmp_plugin="$(mktemp)"
  if jq --arg v "${want}" '.version = $v' "${plugin_json}" > "${tmp_plugin}" 2>/dev/null \
     && jq -e --arg v "${want}" '.version == $v' "${tmp_plugin}" >/dev/null 2>&1; then
    mv "${tmp_plugin}" "${plugin_json}"
    echo "bump-version: .claude-plugin/plugin.json version synced to ${want}" >&2
  else
    rm -f "${tmp_plugin}"
    echo "bump-version: failed to sync .claude-plugin/plugin.json version" >&2
    exit 3
  fi
}

if [[ "${BUMP}" == "none" ]]; then
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    _sync_plugin_version "${CURRENT}"
  fi
  exit 0
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  exit 0
fi

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

_sync_plugin_version "${NEXT}"

exit 0
