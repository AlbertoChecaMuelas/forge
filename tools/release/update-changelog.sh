#!/usr/bin/env bash
#
# tools/release/update-changelog.sh
#
# Idempotently inserts an [Unreleased] bullet block into CHANGELOG.md
# describing the user-facing commits (feat/feature, fix, refactor/perf/docs)
# between the highest validated release checkpoint (or the base branch if
# no checkpoint exists) and HEAD. Reads the baseline changelog from
# HEAD:CHANGELOG.md, computes the desired working-tree state, and writes
# only when the working tree matches the baseline (so a manual changelog
# edit is rejected instead of silently overwritten).
#
# Re-runs are safe and deterministic. Four working-tree states are
# recognised, checked in this order:
#   - WT already equals the DESIRED state
#       -> exit 0, nothing is modified (resume / no-op);
#   - WT equals the BASELINE (HEAD:CHANGELOG.md) and new user-facing commits
#     exist
#       -> write the desired state atomically (replacing the file);
#   - WT equals a SUPERSEDED desired state, i.e. exactly what a previous run
#     of this script wrote for an earlier point of the branch (the commit
#     set pending at that time) while new commits have arrived since
#       -> exit 2 WITHOUT touching the file, naming that real cause and
#          printing the recovery command;
#   - WT matches nothing this script can produce (a hand edit)
#       -> exit 2 WITHOUT touching the file, reporting a manual edit.
#
# The third state is expected in the normal release flow: bump and
# changelog run before commit-release, so a commit landing between two
# runs leaves the changelog written by the first run in the working tree.
# bump-version.sh recognises the same situation as a valid resume. The
# recovery for both exit-2 states is the same and is idempotent:
#
#   git checkout -- CHANGELOG.md
#   tools/release/update-changelog.sh --branch <base>
#
# Commit classification (no merges, conventional-commit prefix):
#   feat / feature                     -> ### Added
#   fix                                -> ### Fixed
#   refactor / perf / docs             -> ### Changed
#   chore / build / ci / style / test  -> omitted (not user-facing)
#
# The bullet text is the commit subject with the conventional prefix and the
# optional scope removed. Two rules keep the block clean:
#   - a commit that already curated its own entry in the [Unreleased] section
#     of CHANGELOG.md is NOT documented again (its reviewed entry is already
#     in the baseline; re-adding the raw subject duplicated the change);
#   - the derived text is normalised: an inline-code marker that is left
#     unpaired (an odd number of "`") is dropped, so a malformed bullet can
#     never ship.
#
# Entries are merged into the [Unreleased] subsection of the same name when
# the baseline already carries one (a second release on a branch that
# already published one must not duplicate the heading); the heading is
# only created when it is missing.
#
# Flags:
#   --branch <base>   Base branch / ref (required).
#   -h | --help       Show this help text and exit 0.
#
# Output on stdout:
#   update-changelog: prepended N entries to [Unreleased] (anchor=<SHA>)
#   update-changelog: no user-facing commits vs anchor <SHA>; CHANGELOG unchanged
#
# Exit codes:
#   0  Success (no-op, new entries written, baseline preserved as-is).
#   2  Bad arguments, base ref missing, invalid checkpoint (sequential or
#      tree mismatch), or a working tree that matches neither the baseline,
#      the desired state nor a superseded desired state (nothing is ever
#      overwritten in this case).
#
set -euo pipefail

BASE_BRANCH="master"

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

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${REPO_ROOT}" ]]; then
  echo "update-changelog: not inside a git repository" >&2
  exit 2
fi

if ! git rev-parse --verify --quiet "${BASE_BRANCH}" >/dev/null 2>&1; then
  echo "update-changelog: base '${BASE_BRANCH}' does not exist" >&2
  exit 2
fi
BASE_SHA="$(git rev-parse "${BASE_BRANCH}")"
HEAD_SHA="$(git rev-parse HEAD)"
if ! git merge-base --is-ancestor "${BASE_SHA}" "${HEAD_SHA}"; then
  echo "update-changelog: base '${BASE_BRANCH}' (${BASE_SHA}) is not an ancestor of HEAD (${HEAD_SHA})" >&2
  exit 2
fi

CHANGELOG="${REPO_ROOT}/CHANGELOG.md"

# How this script is invoked, printed in the recovery hints. Kept
# repo-relative when possible so the hint is copy-pasteable.
SELF="${BASH_SOURCE[0]}"
case "${SELF}" in
  "${REPO_ROOT}"/*) SELF="${SELF#"${REPO_ROOT}"/}" ;;
esac

# ---------------------------------------------------------------------------
# Anchor resolution: walk release checkpoints (oldest first) starting at
# the base. Each candidate must (a) declare a version equal to the result
# of applying the bump policy to the non-merge range from the previous
# anchor to the parent of the candidate, and (b) hold that same version
# in its install.sh. Any inconsistency aborts.
# ---------------------------------------------------------------------------
CHECKPOINT_REGEX='^chore\(release\): bump version to v[0-9]+\.[0-9]+\.[0-9]+$'

_validate_semver() {
  local v="$1"
  if ! printf '%s' "${v}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "update-changelog: invalid semver '${v}'" >&2
    exit 2
  fi
}

_read_install_version() {
  local sha="$1"
  git show "${sha}:install.sh" 2>/dev/null \
    | grep -E '^FORGE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' \
    | head -n 1 \
    | sed -E 's/^FORGE_VERSION="([^"]+)"$/\1/'
}

# Counts the user-facing commits of <range>. Only FEATS and FIXES are
# consumed here (they drive the bump policy of a checkpoint); commits that
# are neither feat nor fix/refactor/perf are not user-facing and are simply
# not counted. There is no OTHERS counter: nothing in this script reports
# it (unlike bump-version.sh, which prints it on its output line).
_classify_range() {
  local range="$1"
  local feats=0 fixes=0
  local subjects
  subjects="$(git log "${range}" --no-merges --format='%s' 2>/dev/null || true)"
  while IFS= read -r SUBJECT; do
    [[ -z "${SUBJECT}" ]] && continue
    case "${SUBJECT}" in
      feat:*|feat\(*\):*|feature:*|feature\(*\):*) feats=$((feats + 1)) ;;
      fix:*|fix\(*\):*|refactor:*|refactor\(*\):*|perf:*|perf\(*\):*) fixes=$((fixes + 1)) ;;
      *) ;;  # chore / build / ci / style / test / prefixless: not user-facing
    esac
  done <<EOF
${subjects}
EOF
  FEATS="${feats}"
  FIXES="${fixes}"
}

_bump_from_counts() {
  if   (( FEATS > 0 )); then echo "minor"
  elif (( FIXES > 0 )); then echo "patch"
  else                       echo "none"
  fi
}

_apply_bump() {
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
      echo "update-changelog: internal error: unknown bump '${bump}'" >&2
      exit 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Rendering helpers
#
# The script owns the body of the [Unreleased] section: every managed
# subsection (### Added / ### Changed / ### Fixed) holds the bullets of the
# same kind, in that canonical order. New entries are APPENDED to the
# subsection of the same name when the baseline already carries one; the
# heading is only created when it is missing, and it is then inserted
# before the first existing subsection of a higher rank so the section
# stays in canonical order. Every byte outside [Unreleased] is copied
# verbatim, so the historical sections stay byte-for-byte equal.
#
# Every emitted block is a sequence of lines that ends with a real blank
# line: the last bullet of a subsection is never glued to the next content.
# ---------------------------------------------------------------------------

MERGE_LAST=""

# Canonical rank of a subsection heading (9 = not managed by this script).
_heading_rank() {
  case "$1" in
    '### Added')   echo 1 ;;
    '### Changed') echo 2 ;;
    '### Fixed')   echo 3 ;;
    *)             echo 9 ;;
  esac
}

# Pending bullets of <kind>, one per line (empty when the kind has none).
_bullets_for_kind() {
  case "$1" in
    Added)   printf '%s\n' "${ADDED}" ;;
    Changed) printf '%s\n' "${CHANGED}" ;;
    Fixed)   printf '%s\n' "${FIXED}" ;;
    *)       return 0 ;;
  esac
}

# Number of "- " bullets in <text>.
_count_bullets() {
  local n=0 line
  while IFS= read -r line; do
    case "${line}" in
      "- "*) n=$((n + 1)) ;;
    esac
  done <<EOF
$1
EOF
  echo "${n}"
}

# Rewrites <file> without its trailing blank lines. Deterministic, so the
# rendered desired state stays byte-deterministic across runs.
_trim_trailing_blanks() {
  local file="$1"
  local tmp="${file}.trim"
  awk '{ line[NR] = $0 }
       END {
         last = NR
         while (last > 0 && line[last] ~ /^[[:space:]]*$/) last--
         for (i = 1; i <= last; i++) print line[i]
       }' "${file}" > "${tmp}"
  mv "${tmp}" "${file}"
}

_emit_line() {
  printf '%s\n' "$1" >> "$2"
  MERGE_LAST="$1"
}

# Emits a blank separator unless the previous emitted line already is one.
_emit_separator() {
  if [[ -n "${MERGE_LAST}" ]]; then
    printf '\n' >> "$1"
  fi
  MERGE_LAST=""
}

# _emit_new_subsection <kind> <out> — creates a managed subsection holding
# only the pending bullets of <kind>. It ends with a real blank line.
_emit_new_subsection() {
  local kind="$1" out="$2" line
  local bullets
  bullets="$(_bullets_for_kind "${kind}")"
  [[ -n "${bullets}" ]] || return 0
  _emit_separator "${out}"
  _emit_line "### ${kind}" "${out}"
  while IFS= read -r line; do
    _emit_line "${line}" "${out}"
  done <<EOF
${bullets}
EOF
  printf '\n' >> "${out}"
  MERGE_LAST=""   # subsection closed on a blank line
}

# _close_subsection <kind> <buffer> <out> — flushes a managed subsection
# that already existed in the baseline: its bytes are preserved, its
# trailing blank lines are dropped, the pending bullets of <kind> are
# appended at its end and it is closed with a real blank line.
_close_subsection() {
  local kind="$1" buf="$2" out="$3" line
  local bullets
  bullets="$(_bullets_for_kind "${kind}")"
  _trim_trailing_blanks "${buf}"
  if [[ -s "${buf}" ]]; then
    cat "${buf}" >> "${out}"
    MERGE_LAST="$(sed -ne '$p' "${buf}")"
  fi
  if [[ -n "${bullets}" ]]; then
    while IFS= read -r line; do
      _emit_line "${line}" "${out}"
    done <<EOF
${bullets}
EOF
  fi
  printf '\n' >> "${out}"
  MERGE_LAST=""   # subsection closed on a blank line
}

# ---------------------------------------------------------------------------
# Entry text helpers
#
# The bullet text is derived from the commit subject, i.e. from free-form
# prose written by a human. Two rules keep the rendered block clean and
# byte-deterministic:
#
#   - a commit that ALREADY curated its own entry in the [Unreleased]
#     section of CHANGELOG.md is not documented a second time. Its
#     reviewed entry is part of the baseline, and re-adding the raw subject
#     on top of it duplicates the very same change (this is what used to
#     leave a near-duplicate pair in the block);
#   - the derived text is normalised: an inline-code marker that is not
#     paired (an odd number of "`") is a typo in the subject and would ship
#     a malformed bullet, because Markdown renders an unmatched backtick as
#     a literal character.
# ---------------------------------------------------------------------------

# _strip_prefix <subject> — removes the conventional-commit prefix and the
# optional scope: "fix(opencode): texto" -> "texto".
_strip_prefix() {
  printf '%s' "$1" | sed 's/^[a-z]*([^)]*): *//' | sed 's/^[a-z]*: *//'
}

# _normalise_bullet <text> — drops a dangling inline-code marker.
#
# The markers that pair up are kept; only the LAST one, the one left
# unpaired, is removed. An even number of "`" leaves the text untouched.
_normalise_bullet() {
  local text="$1" n
  n="$(printf '%s' "${text}" | tr -cd '`' | wc -c | tr -d ' ')"
  n="${n:-0}"
  if (( n % 2 != 0 )); then
    text="$(printf '%s' "${text}" | awk '{
      s = $0
      for (i = length(s); i > 0; i--) {
        if (substr(s, i, 1) == "`") { s = substr(s, 1, i - 1) substr(s, i + 1); break }
      }
      print s
    }')"
  fi
  printf '%s' "${text}"
}

# _unreleased_block_of <rev> — the [Unreleased] section of <rev>:CHANGELOG.md
# (heading included). Empty when that revision has no CHANGELOG.md or no
# such section.
_unreleased_block_of() {
  { git show "${1}:CHANGELOG.md" 2>/dev/null || true; } | awk '
    /^## \[Unreleased\]/                        { inside = 1 }
    inside && /^## \[/ && !/^## \[Unreleased\]/ { inside = 0 }
    inside                                       { print }
  '
}

# _commit_curated_itself <sha> — true when <sha> added at least one bullet to
# the [Unreleased] section of CHANGELOG.md. Such a commit already documented
# itself with a reviewed entry, so the generator must not add the raw subject
# on top of it: that is the duplicate this rule removes.
_commit_curated_itself() {
  local sha="$1" before after added
  before="$(_unreleased_block_of "${sha}^")"
  after="$(_unreleased_block_of "${sha}")"
  [[ -n "${after}" ]] || return 1
  added="$(LC_ALL=C comm -13 \
    <(printf '%s\n' "${before}" | LC_ALL=C sort -u) \
    <(printf '%s\n' "${after}"  | LC_ALL=C sort -u) | grep -c '^- ' || true)"
  [[ "${added:-0}" -gt 0 ]]
}

# Classifies the "<sha> <subject>" lines read from stdin into the globals
# ADDED / CHANGED / FIXED (each one a "- " bullet list, empty when the range
# holds no commit of that kind) and counts the user-facing commits in
# USER_FACING.
_classify_commits() {
  local LINE SHA SUBJECT KIND STRIPPED
  ADDED=""
  CHANGED=""
  FIXED=""
  USER_FACING=0
  while IFS= read -r LINE; do
    [[ -z "${LINE}" ]] && continue
    SHA="${LINE%% *}"
    SUBJECT="${LINE#* }"
    [[ -n "${SUBJECT}" && "${SUBJECT}" != "${LINE}" ]] || continue
    case "${SUBJECT}" in
      feat:*|feat\(*\):*|feature:*|feature\(*\):*) KIND="Added" ;;
      fix:*|fix\(*\):*)                            KIND="Fixed" ;;
      refactor:*|refactor\(*\):*|perf:*|perf\(*\):*|docs:*|docs\(*\):*) KIND="Changed" ;;
      *)
        # chore / build / ci / style / test / prefixless: not user-facing
        continue
        ;;
    esac
    USER_FACING=$((USER_FACING + 1))
    # Already documented by the commit itself: do not duplicate it.
    _commit_curated_itself "${SHA}" && continue
    STRIPPED="$(_normalise_bullet "$(_strip_prefix "${SUBJECT}")")"
    case "${KIND}" in
      Added)
        if [[ -n "${ADDED}" ]]; then ADDED="${ADDED}
- ${STRIPPED}"; else ADDED="- ${STRIPPED}"; fi
        ;;
      Fixed)
        if [[ -n "${FIXED}" ]]; then FIXED="${FIXED}
- ${STRIPPED}"; else FIXED="- ${STRIPPED}"; fi
        ;;
      Changed)
        if [[ -n "${CHANGED}" ]]; then CHANGED="${CHANGED}
- ${STRIPPED}"; else CHANGED="- ${STRIPPED}"; fi
        ;;
    esac
  done
}

# _render_unreleased_body <body_file> <out_file> — rewrites the body of the
# [Unreleased] section (the lines between its heading and the next "## "
# section) so every managed subsection carries the pending bullets of its
# kind. Leading and trailing blank lines are normalised (the caller owns
# the blank line after the section heading and the one before the next
# section); every other line is copied.
_render_unreleased_body() {
  local body="$1" out="$2"
  local kind line cur="" started=0 p=0 rank pr
  local -a pend=()

  # Only create the heading of a kind whose subsection the baseline lacks.
  for kind in Added Changed Fixed; do
    if [[ -n "$(_bullets_for_kind "${kind}")" ]] && ! grep -qE "^###[[:space:]]+${kind}\$" "${body}"; then
      pend+=("${kind}")
    fi
  done

  MERGE_LAST=""
  : > "${out}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    if (( started == 0 )); then
      [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
      started=1
    fi
    if [[ "${line}" =~ ^###[[:space:]] ]]; then
      rank="$(_heading_rank "${line}")"
      # The open subsection ends here: flush it before anything else so its
      # bytes reach the output before the next heading.
      if [[ -n "${cur}" ]]; then
        _close_subsection "${cur}" "${TMP_SEC}" "${out}"
        cur=""
      fi
      # Create the missing managed subsections whose canonical rank is lower
      # than this heading's rank, keeping the section in canonical order.
      while (( p < ${#pend[@]} )); do
        pr="$(_heading_rank "### ${pend[p]}")"
        (( pr < rank )) || break
        _emit_new_subsection "${pend[p]}" "${out}"
        p=$((p + 1))
      done
      if (( rank < 9 )); then
        _emit_separator "${out}"
        printf '%s\n' "${line}" > "${TMP_SEC}"
        cur="${line#\#\#\# }"
      else
        _emit_line "${line}" "${out}"
      fi
      continue
    fi
    if [[ -n "${cur}" ]]; then
      printf '%s\n' "${line}" >> "${TMP_SEC}"
    else
      _emit_line "${line}" "${out}"
    fi
  done < "${body}"

  if [[ -n "${cur}" ]]; then
    _close_subsection "${cur}" "${TMP_SEC}" "${out}"
  fi
  while (( p < ${#pend[@]} )); do
    _emit_new_subsection "${pend[p]}" "${out}"
    p=$((p + 1))
  done

  _trim_trailing_blanks "${out}"
}

# _render_new_body <out_file> — body of a freshly created [Unreleased]
# section: only the pending managed subsections, in canonical order.
_render_new_body() {
  local out="$1" kind
  MERGE_LAST=""
  : > "${out}"
  for kind in Added Changed Fixed; do
    _emit_new_subsection "${kind}" "${out}"
  done
  _trim_trailing_blanks "${out}"
}

# _render_desired <baseline_file> <out_file> — renders the desired working
# tree state: the baseline with the pending entries merged into
# [Unreleased]. When the baseline has no [Unreleased] section the section
# is created immediately BEFORE the first released section, i.e. after the
# document preamble, so the preamble never ends up under the new block.
# CREATE_UNRELEASED (0/1) selects the branch; TMP_HEAD / TMP_BODY /
# TMP_TAIL hold the split baseline.
_render_desired() {
  local baseline="$1" out="$2"

  if (( CREATE_UNRELEASED == 0 )); then
    awk -v head="${TMP_HEAD}" -v body="${TMP_BODY}" -v tail="${TMP_TAIL}" '
      !done && /^## \[Unreleased\]/ { done = 1; mode = "body"; print > head; next }
      done == 1 && mode == "body" && /^## \[/ { mode = "tail"; print > tail; next }
      done == 1 && mode == "body"           { print > body; next }
      done == 0                             { print > head; next }
                                           { print > tail }
    ' "${baseline}"
    _render_unreleased_body "${TMP_BODY}" "${TMP_SECT}"
    cat "${TMP_HEAD}" > "${out}"
    printf '\n' >> "${out}"
    cat "${TMP_SECT}" >> "${out}"
    if [[ -s "${TMP_TAIL}" ]]; then
      printf '\n' >> "${out}"
      cat "${TMP_TAIL}" >> "${out}"
    fi
  else
    awk -v head="${TMP_HEAD}" -v tail="${TMP_TAIL}" '
      !done && /^## \[/ { done = 1; print > tail; next }
      done == 0          { print > head; next }
                       { print > tail }
    ' "${baseline}"
    _trim_trailing_blanks "${TMP_HEAD}"
    _render_new_body "${TMP_SECT}"
    cat "${TMP_HEAD}" > "${out}"
    if [[ -s "${TMP_HEAD}" ]]; then
      printf '\n' >> "${out}"
    fi
    printf '## [Unreleased]\n\n' >> "${out}"
    cat "${TMP_SECT}" >> "${out}"
    if [[ -s "${TMP_TAIL}" ]]; then
      printf '\n' >> "${out}"
      cat "${TMP_TAIL}" >> "${out}"
    fi
  fi

  _trim_trailing_blanks "${out}"
}

# _scan_superseded_state <working_tree_file>
# Recognises the state where the working tree holds exactly what a previous
# run wrote for an earlier point of the branch: re-render the desired state
# for every prefix of the pending commit list (oldest first) and compare.
# Returns 0 and fills SUPER_COMMIT / SUPER_ENTRIES when detected. The
# pending buckets are restored before returning in either case.
_scan_superseded_state() {
  local wt="$1" c
  local save_added="${ADDED}" save_changed="${CHANGED}" save_fixed="${FIXED}"
  local save_user_facing="${USER_FACING}"
  local subjects

  SUPER_COMMIT=""
  SUPER_ENTRIES=0

  while IFS= read -r c; do
    [[ -z "${c}" ]] && continue
    subjects="$(git log "${ANCHOR_SHA}..${c}" --no-merges --format='%H %s' 2>/dev/null || true)"
    [[ -z "${subjects}" ]] && continue
    _classify_commits <<EOF
${subjects}
EOF
    if [[ -z "${ADDED}" && -z "${CHANGED}" && -z "${FIXED}" ]]; then
      continue
    fi
    _render_desired "${TMP_BASELINE}" "${TMP_CAND}"
    if cmp -s "${wt}" "${TMP_CAND}"; then
      SUPER_COMMIT="${c}"
      SUPER_ENTRIES=$(( $(_count_bullets "${ADDED}") + $(_count_bullets "${CHANGED}") + $(_count_bullets "${FIXED}") ))
      ADDED="${save_added}"; CHANGED="${save_changed}"; FIXED="${save_fixed}"
      USER_FACING="${save_user_facing}"
      return 0
    fi
  done <<EOF
$(git log "${ANCHOR_SHA}..HEAD" --no-merges --reverse --format='%H' 2>/dev/null || true)
EOF

  ADDED="${save_added}"; CHANGED="${save_changed}"; FIXED="${save_fixed}"
  USER_FACING="${save_user_facing}"
  return 1
}

ANCHOR_SHA="${BASE_SHA}"
ANCHOR_VERSION="$(_read_install_version "${BASE_SHA}")"
if [[ -z "${ANCHOR_VERSION}" ]]; then
  echo "update-changelog: cannot read FORGE_VERSION at base '${BASE_BRANCH}' (${BASE_SHA})" >&2
  exit 2
fi
_validate_semver "${ANCHOR_VERSION}"

PAIRS="$(git log "${BASE_BRANCH}..HEAD" --reverse --no-merges --format='%H %s' 2>/dev/null || true)"
while IFS= read -r LINE; do
  [[ -z "${LINE}" ]] && continue
  SHA="${LINE%% *}"
  SUBJ="${LINE#* }"
  if ! [[ "${SUBJ}" =~ ${CHECKPOINT_REGEX} ]]; then
    continue
  fi

  DECLARED="$(printf '%s' "${SUBJ}" | sed -E 's/^chore\(release\): bump version to v([0-9]+\.[0-9]+\.[0-9]+)$/\1/')"
  if [[ -z "${DECLARED}" || "${DECLARED}" = "${SUBJ}" ]]; then
    echo "update-changelog: malformed checkpoint subject at ${SHA}: ${SUBJ}" >&2
    exit 2
  fi
  _validate_semver "${DECLARED}"

  # Sequential bump must match the declared version.
  _classify_range "${ANCHOR_SHA}..${SHA}^"
  CK_BUMP="$(_bump_from_counts)"
  EXPECTED_NEXT="$(_apply_bump "${ANCHOR_VERSION}" "${CK_BUMP}")"
  if [[ "${DECLARED}" != "${EXPECTED_NEXT}" ]]; then
    echo "update-changelog: checkpoint at ${SHA} declares ${DECLARED} but range ${ANCHOR_SHA}..${SHA}^ yields ${EXPECTED_NEXT} (CURRENT=${ANCHOR_VERSION}, BUMP=${CK_BUMP})" >&2
    exit 2
  fi

  # Tree must agree with declared version.
  TREE_VERSION="$(_read_install_version "${SHA}")"
  if [[ "${TREE_VERSION}" != "${DECLARED}" ]]; then
    echo "update-changelog: checkpoint at ${SHA} has FORGE_VERSION=${TREE_VERSION} but subject declares ${DECLARED}" >&2
    exit 2
  fi

  ANCHOR_SHA="${SHA}"
  ANCHOR_VERSION="${DECLARED}"
done <<EOF
${PAIRS}
EOF

# ---------------------------------------------------------------------------
# Classify anchor..HEAD commits into the three user-facing buckets.
# ---------------------------------------------------------------------------
SUBJECTS="$(git log "${ANCHOR_SHA}..HEAD" --no-merges --format='%H %s' 2>/dev/null || true)"
_classify_commits <<EOF
${SUBJECTS}
EOF

# ---------------------------------------------------------------------------
# Read baseline (HEAD:CHANGELOG.md) into a temp file.
# ---------------------------------------------------------------------------
TMP_BASELINE="$(mktemp)"
TMP_HEAD="$(mktemp)"
TMP_BODY="$(mktemp)"
TMP_TAIL="$(mktemp)"
TMP_SECT="$(mktemp)"
TMP_SEC="$(mktemp)"
TMP_DESIRED="$(mktemp)"
TMP_CAND="$(mktemp)"
trap 'rm -f "${TMP_BASELINE}" "${TMP_HEAD}" "${TMP_BODY}" "${TMP_TAIL}" "${TMP_SECT}" "${TMP_SEC}" "${TMP_DESIRED}" "${TMP_CAND}"' EXIT

if ! git show "${HEAD_SHA}:CHANGELOG.md" > "${TMP_BASELINE}" 2>/dev/null; then
  if [[ -z "${ADDED}" && -z "${CHANGED}" && -z "${FIXED}" ]]; then
    exit 0
  fi
  echo "update-changelog: HEAD has no CHANGELOG.md but there are pending user-facing entries; refusing to materialize one from scratch" >&2
  exit 2
fi

# No entry to add: either the range holds no user-facing commit, or every
# user-facing commit in it already curated its own entry in [Unreleased].
# In both cases desired == baseline exactly, so the WT must already be at
# baseline (otherwise reject the manual edit).
if [[ -z "${ADDED}" && -z "${CHANGED}" && -z "${FIXED}" ]]; then
  if [[ -f "${CHANGELOG}" ]] && cmp -s "${CHANGELOG}" "${TMP_BASELINE}"; then
    if [[ "${USER_FACING:-0}" -gt 0 ]]; then
      echo "update-changelog: ${USER_FACING} user-facing commit(s) vs anchor ${ANCHOR_SHA} are already documented in [Unreleased]; CHANGELOG unchanged"
    else
      echo "update-changelog: no user-facing commits vs anchor ${ANCHOR_SHA}; CHANGELOG unchanged"
    fi
    exit 0
  fi
  echo "update-changelog: working tree differs from baseline but no entries are pending; not overwriting manual changes" >&2
  echo "update-changelog: recovery: git checkout -- CHANGELOG.md" >&2
  exit 2
fi

# Pick the insertion site up front so the renderer never races two rules:
# merge into the existing [Unreleased] section, or create it before the
# first released section when the baseline has none.
CREATE_UNRELEASED=0
if ! grep -qE '^## \[Unreleased\]' "${TMP_BASELINE}"; then
  CREATE_UNRELEASED=1
fi

# Render the desired working-tree state: the baseline with the pending
# entries merged into [Unreleased]. Deterministic, so a re-run always
# yields the same bytes and the idempotency guarantee holds.
_render_desired "${TMP_BASELINE}" "${TMP_DESIRED}"

# Compare the working tree against the known-good states.
WT_EQ_DESIRED=false
WT_EQ_BASELINE=false
if [[ -f "${CHANGELOG}" ]]; then
  if cmp -s "${CHANGELOG}" "${TMP_DESIRED}"; then WT_EQ_DESIRED=true; fi
  if cmp -s "${CHANGELOG}" "${TMP_BASELINE}"; then WT_EQ_BASELINE=true; fi
fi

if [[ "${WT_EQ_DESIRED}" == "true" ]]; then
  echo "update-changelog: CHANGELOG already at desired state; no-op"
  exit 0
fi

if [[ "${WT_EQ_BASELINE}" == "true" ]]; then
  mv "${TMP_DESIRED}" "${CHANGELOG}"
  trap - EXIT
  N_ENTRIES=$(( $(_count_bullets "${ADDED}") + $(_count_bullets "${CHANGED}") + $(_count_bullets "${FIXED}") ))
  echo "update-changelog: prepended ${N_ENTRIES} entries to [Unreleased] (anchor=${ANCHOR_SHA})"
  exit 0
fi

# Neither state: either the working tree holds what a previous run wrote
# before new commits arrived (expected mid-flow, not a manual edit), or it
# holds an edit this script did not write. Name the real cause in both
# cases and never touch the file.
if [[ -f "${CHANGELOG}" ]] && _scan_superseded_state "${CHANGELOG}"; then
  NEW_COMMITS="$(git rev-list --count "${SUPER_COMMIT}..HEAD" 2>/dev/null || echo '?')"
  echo "update-changelog: CHANGELOG working tree holds the state a previous run wrote for ${SUPER_COMMIT} (${SUPER_ENTRIES} entries) and is NOT a manual edit." >&2
  echo "update-changelog: ${NEW_COMMITS} commit(s) have arrived since that run (now at ${HEAD_SHA}); bump-version.sh accepts this state as a valid resume." >&2
  echo "update-changelog: recovery: git checkout -- CHANGELOG.md && ${SELF} --branch ${BASE_BRANCH}" >&2
  echo "update-changelog: refusing to overwrite; review the pending entries before re-running." >&2
  exit 2
fi

echo "update-changelog: CHANGELOG working tree differs from both baseline and desired and matches no state this script can produce; refusing to overwrite. Treating it as a manual edit: review it, or discard it." >&2
echo "update-changelog: recovery: git checkout -- CHANGELOG.md && ${SELF} --branch ${BASE_BRANCH}" >&2
exit 2
