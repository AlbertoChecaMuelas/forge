#!/usr/bin/env bash
#
# tools/release/mr-stamp.sh
#
# Emits to stdout two artefacts used by create-mr to populate PR-DESCRIPTION.md:
#
#   1. A "## Tipo de cambio" checkbox block (ten lines) with lines auto-checked
#      based on conventional-commit prefixes found in the range <base>..HEAD.
#   2. A blank line.
#   3. A machine-readable stamp comment:
#        <!-- forge:pr-description head=<SHA> base=<branch> generated=<ISO-UTC> -->
#
# The stamp HEAD is the full 40-hex SHA of HEAD at the time of invocation.
# create-mr.sh compares this stamp against `git rev-parse HEAD` to decide
# whether PR-DESCRIPTION.md is fresh or stale.
#
# Category -> checkbox mapping (flags set from commit subjects via case globs):
#   HAS_FEATURE  feat/feature prefixes      -> "feature" line checked
#   HAS_FIX      fix prefix                 -> "fix" line checked
#   HAS_REFACTOR refactor/perf prefixes     -> "refactor" line checked
#   HAS_DOCS     docs prefix                -> "docs" line checked
#   HAS_CHORE    chore/build/ci prefixes    -> "chore" line checked
#   ci, perf, style, test, breaking change  -> always unchecked
#
# Flags:
#   --base <branch>   Base branch for the commit range (default: master).
#   -h | --help       Show this help text.
#
# Exit codes:
#   0  Success.
#   2  Precondition failure (not a git repo, base branch missing, unknown flag).
#
set -euo pipefail

BASE_BRANCH="master"

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      BASE_BRANCH="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '/^# tools\/release\/mr-stamp/,/^# Exit codes:/p' "$0"
      exit 0
      ;;
    *)
      echo "mr-stamp: unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${REPO_ROOT}" ]; then
  echo "mr-stamp: not inside a git repository" >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "${BASE_BRANCH}" >/dev/null; then
  echo "mr-stamp: base branch '${BASE_BRANCH}' does not exist" >&2
  exit 2
fi

HEAD_SHA="$(git rev-parse HEAD)"
BASE="${BASE_BRANCH}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

HAS_FEATURE=0
HAS_FIX=0
HAS_REFACTOR=0
HAS_DOCS=0
HAS_CHORE=0

while IFS= read -r SUBJECT; do
  [ -z "${SUBJECT}" ] && continue
  case "${SUBJECT}" in
    feat:*|feat\(*\):*|feature:*|feature\(*\):*)
      HAS_FEATURE=1 ;;
    fix:*|fix\(*\):*)
      HAS_FIX=1 ;;
    refactor:*|refactor\(*\):*|perf:*|perf\(*\):*)
      HAS_REFACTOR=1 ;;
    docs:*|docs\(*\):*)
      HAS_DOCS=1 ;;
    chore:*|chore\(*\):*|build:*|build\(*\):*|ci:*|ci\(*\):*)
      HAS_CHORE=1 ;;
    *)
      ;;
  esac
done < <(git log "${BASE_BRANCH}..HEAD" --no-merges --format='%s' 2>/dev/null)

# Helper: emit a checkbox line.
# $1 = flag value (0 or 1), $2 = label text
_cb() {
  if [ "$1" -eq 1 ]; then
    printf '%s\n' "- [x] $2"
  else
    printf '%s\n' "- [ ] $2"
  fi
}

printf '## Tipo de cambio\n'
printf '\n'
_cb "${HAS_FIX}"      "\`fix\` (cambio no rupturista el cual corrige un problema)"
_cb "${HAS_FEATURE}"  "\`feature\` (cambio no rupturista el cual añade una funcionalidad)"
_cb "${HAS_REFACTOR}" "\`refactor\` (cambio no rupturista que no es un \`feature\` ni un \`fix\`)"
_cb "${HAS_DOCS}"     "\`docs\` (cambios de documentación)"
_cb "${HAS_CHORE}"    "\`chore\` (cambios que no modifican archivos internos de \`src\` o de \`test\`)"
_cb 0                 "\`ci\` (cambios para la configuración de CI)"
_cb 0                 "\`perf\` (cambios que mejoran el rendimiento)"
_cb 0                 "\`style\` (cambios que no afectan al resultado del código, por ejemplo corrección de espacios en blanco o saltos de línea)"
_cb 0                 "\`test\` (añade test o corrige existentes)"
_cb 0                 "\`breaking change\` (cambio rupturista para corregir o actualizar un comportamiento no esperado o antiguo)"
printf '\n'
printf '<!-- forge:pr-description head=%s base=%s generated=%s -->\n' \
  "${HEAD_SHA}" "${BASE}" "${TS}"

exit 0
