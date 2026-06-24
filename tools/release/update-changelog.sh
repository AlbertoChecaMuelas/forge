#!/usr/bin/env bash
#
# tools/release/update-changelog.sh
#
# Prepends a structured [Unreleased] block into CHANGELOG.md based on
# conventional-commit subjects between a base branch and HEAD.
#
# Commit classification (by subject prefix):
#   feat / feature                     -> ### Added
#   fix                                -> ### Fixed
#   refactor / perf / docs             -> ### Changed
#   chore / build / ci / style / test  -> omitted (not user-facing)
#
# Flags:
#   --branch <base>   Base branch / ref for the commit range (required).
#   -h | --help       Show this help text and exit 0.
#
# Output on stdout:
#   update-changelog: prepended N entries to [Unreleased] (branch vs <base>)
#
# Exit codes:
#   0  Success (including no-op cases: no new commits, or no user-facing commits).
#   2  Bad arguments or base ref does not exist.
#
set -euo pipefail

BASE_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)
      if [[ $# -lt 2 ]]; then
        echo "update-changelog: --branch requires an argument" >&2
        exit 2
      fi
      BASE_BRANCH="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '/^# tools\/release\/update-changelog/,/^# Exit codes:/{ /^# Exit codes:/{ p; q }; p }' "$0"
      exit 0
      ;;
    *)
      echo "update-changelog: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${BASE_BRANCH}" ]]; then
  echo "update-changelog: --branch <base> is required" >&2
  exit 2
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  echo "update-changelog: not inside a git repository" >&2
  exit 2
fi

# Validate base ref exists.
if ! git rev-parse --verify --quiet "${BASE_BRANCH}" >/dev/null 2>&1; then
  echo "update-changelog: base '${BASE_BRANCH}' does not exist" >&2
  exit 2
fi

CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

if [[ ! -f "${CHANGELOG}" ]]; then
  echo "update-changelog: no CHANGELOG.md at repo root; nothing to do" >&2
  exit 0
fi

# Collect commit subjects (newest first, no merges).
SUBJECTS="$(git log "${BASE_BRANCH}..HEAD" --no-merges --format='%s' 2>/dev/null || true)"

if [[ -z "${SUBJECTS}" ]]; then
  echo "update-changelog: no new commits vs ${BASE_BRANCH}; CHANGELOG unchanged"
  exit 0
fi

# Classify subjects into three buckets (newline-separated lists).
ADDED=""
CHANGED=""
FIXED=""

while IFS= read -r SUBJECT; do
  [[ -z "${SUBJECT}" ]] && continue

  case "${SUBJECT}" in
    feat:*|feat\(*\):*|feature:*|feature\(*\):*)
      STRIPPED="$(printf '%s' "${SUBJECT}" | sed 's/^[a-z]*([^)]*): *//' | sed 's/^[a-z]*: *//')"
      if [[ -n "${ADDED}" ]]; then
        ADDED="${ADDED}
- ${STRIPPED}"
      else
        ADDED="- ${STRIPPED}"
      fi
      ;;
    fix:*|fix\(*\):*)
      STRIPPED="$(printf '%s' "${SUBJECT}" | sed 's/^[a-z]*([^)]*): *//' | sed 's/^[a-z]*: *//')"
      if [[ -n "${FIXED}" ]]; then
        FIXED="${FIXED}
- ${STRIPPED}"
      else
        FIXED="- ${STRIPPED}"
      fi
      ;;
    refactor:*|refactor\(*\):*|perf:*|perf\(*\):*|docs:*|docs\(*\):*)
      STRIPPED="$(printf '%s' "${SUBJECT}" | sed 's/^[a-z]*([^)]*): *//' | sed 's/^[a-z]*: *//')"
      if [[ -n "${CHANGED}" ]]; then
        CHANGED="${CHANGED}
- ${STRIPPED}"
      else
        CHANGED="- ${STRIPPED}"
      fi
      ;;
    *)
      # chore, build, ci, style, test, prefixless — omitted
      ;;
  esac
done <<EOF
${SUBJECTS}
EOF

# If all buckets are empty, nothing user-facing.
if [[ -z "${ADDED}" && -z "${CHANGED}" && -z "${FIXED}" ]]; then
  echo "update-changelog: no user-facing commits vs ${BASE_BRANCH}; CHANGELOG unchanged"
  exit 0
fi

# Build the new block (subsections: Added, Changed, Fixed — only non-empty).
# Each subsection is separated by a blank line; the block ends with a blank line
# so that pre-existing changelog content is not run together with the new block.
NEW_BLOCK=""

if [[ -n "${ADDED}" ]]; then
  NEW_BLOCK="${NEW_BLOCK}### Added
${ADDED}
"
fi

if [[ -n "${CHANGED}" ]]; then
  if [[ -n "${NEW_BLOCK}" ]]; then
    NEW_BLOCK="${NEW_BLOCK}
"
  fi
  NEW_BLOCK="${NEW_BLOCK}### Changed
${CHANGED}
"
fi

if [[ -n "${FIXED}" ]]; then
  if [[ -n "${NEW_BLOCK}" ]]; then
    NEW_BLOCK="${NEW_BLOCK}
"
  fi
  NEW_BLOCK="${NEW_BLOCK}### Fixed
${FIXED}
"
fi

# Count total bullets (lines starting with "- ").
N_ENTRIES=0
while IFS= read -r LINE; do
  case "${LINE}" in
    "- "*) N_ENTRIES=$((N_ENTRIES + 1)) ;;
  esac
done <<EOF
${NEW_BLOCK}
EOF

# Write the block to a temp file so awk can read it safely.
TMP_BLOCK="$(mktemp)"
TMP_CL="$(mktemp)"
trap 'rm -f "${TMP_BLOCK}" "${TMP_CL}"' EXIT

printf '%s\n' "${NEW_BLOCK}" > "${TMP_BLOCK}"

# Detect whether [Unreleased] already exists.
if grep -q '^## \[Unreleased\]' "${CHANGELOG}"; then
  # Insert new block immediately after the ## [Unreleased] heading line.
  awk -v blockfile="${TMP_BLOCK}" '
    /^## \[Unreleased\]/ {
      print
      print ""
      while ((getline line < blockfile) > 0) {
        print line
      }
      close(blockfile)
      # Skip any immediately following blank line(s) to avoid double-blank
      # between new block and old content — but we actually want to keep them,
      # so just print whatever comes next verbatim.
      next
    }
    { print }
  ' "${CHANGELOG}" > "${TMP_CL}"
else
  # No [Unreleased] section. Insert after the first "# " title line.
  awk -v blockfile="${TMP_BLOCK}" '
    !inserted && /^# / {
      print
      print ""
      print "## [Unreleased]"
      print ""
      while ((getline line < blockfile) > 0) {
        print line
      }
      close(blockfile)
      inserted = 1
      next
    }
    { print }
  ' "${CHANGELOG}" > "${TMP_CL}"
fi

# Post-edit verification: must contain [Unreleased] and at least the first bullet.
FIRST_BULLET="$(printf '%s' "${NEW_BLOCK}" | grep '^- ' | head -n 1)"

if ! grep -q '^## \[Unreleased\]' "${TMP_CL}"; then
  echo "update-changelog: post-edit verification failed (## [Unreleased] not found in output)" >&2
  exit 2
fi

if [[ -n "${FIRST_BULLET}" ]] && ! grep -qF -- "${FIRST_BULLET}" "${TMP_CL}"; then
  echo "update-changelog: post-edit verification failed (first bullet not found in output)" >&2
  exit 2
fi

mv "${TMP_CL}" "${CHANGELOG}"
trap - EXIT

echo "update-changelog: prepended ${N_ENTRIES} entries to [Unreleased] (branch vs ${BASE_BRANCH})"
