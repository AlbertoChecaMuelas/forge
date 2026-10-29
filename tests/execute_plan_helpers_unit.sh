#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/execute_plan_helpers_unit.sh — Self-check of the execute-plan
# front-matter helpers, extracted from the REAL executable blocks of both
# variants.
#
# The helpers are NOT copied into this suite: they are extracted verbatim from
#   - open-code/commands/execute-plan.md  (OpenCode command variant)
#   - skills/execute-plan/SKILL.md         (Claude skill variant)
# and executed against throw-away documents inside a private temporary
# directory. The active plan (.plans/current) and the plan repository are
# never touched.
#
# Both variants must behave IDENTICALLY: every case records a normalised
# signature line and the two signatures are compared with cmp. That is the
# semantic parity proof of the helpers.
#
# Compatible with bash 3.2+.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"

OPENCODE_VARIANT="$FORGE_ROOT/open-code/commands/execute-plan.md"
CLAUDE_VARIANT="$FORGE_ROOT/skills/execute-plan/SKILL.md"

FAIL=0
PASS=0

TMPDIR_BASE="$FORGE_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

WORKDIR=""
PLAN_TOOL=""

cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
  rm -rf "$TMPDIR_BASE"/helpers-$$-* 2>/dev/null || true
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

run_test() {
  local name="$1"
  echo "--- $name"
  "$name"
}

# ---------------------------------------------------------------------------
# Oracle: a dependency-free front-matter reader used by the suite to inspect
# the documents produced by the extracted helpers. It never imports the
# helpers: it re-implements the same fence rule so a wrong helper cannot
# silently agree with a wrong oracle.
# ---------------------------------------------------------------------------
write_plan_tool() {
  PLAN_TOOL="$1"
  cat > "$PLAN_TOOL" <<'PY'
#!/usr/bin/env python3
"""plan_tool.py — minimal front-matter reader for the execute-plan suite.

Commands:
  split <file> <body_out>  writes the bytes that follow the closing
                            front-matter fence and prints the index of that
                            fence (-1 when the front-matter is absent or
                            incomplete).
  value <file> <key>       prints the decoded value of <key> inside the
                            front-matter (empty when absent, rc 1).
  count <file> <key>       prints the number of front-matter lines that
                            DECLARE <key>, in any of its three YAML
                            representations (plain, single quoted and
                            double quoted).
"""
import json
import sys


def key_prefixes(key):
    """The three YAML representations of a key.

    The helper under test must recognise all of them: a key that is written
    between single quotes is still the SAME key, and updating it must not
    duplicate it.
    """
    raw = key.encode("utf-8")
    quoted = json.dumps(key, ensure_ascii=False).encode("utf-8")
    single = b"'" + key.replace("'", "''").encode("utf-8") + b"'"
    return (raw + b":", quoted + b":", single + b":")


def split_lines(data):
    if not data:
        return []
    chunks = data.split(b"\n")
    lines = [chunk + b"\n" for chunk in chunks[:-1]]
    if chunks[-1]:
        lines.append(chunks[-1])
    return lines


def content(line):
    if line.endswith(b"\n"):
        line = line[:-1]
        if line.endswith(b"\r"):
            line = line[:-1]
    return line


def frontmatter_end(lines):
    if not lines or content(lines[0]) != b"---":
        return -1
    for index in range(1, len(lines)):
        if content(lines[index]) == b"---":
            return index
    return -1


def cmd_split(path, body_out):
    with open(path, "rb") as handle:
        data = handle.read()
    lines = split_lines(data)
    closing = frontmatter_end(lines)
    if closing < 0:
        sys.stderr.write("no front-matter\n")
        return 2
    with open(body_out, "wb") as handle:
        handle.write(b"".join(lines[closing + 1:]))
    print(closing)
    return 0


def cmd_value(path, key):
    with open(path, "rb") as handle:
        data = handle.read()
    lines = split_lines(data)
    closing = frontmatter_end(lines)
    if closing < 0:
        return 2
    for prefix in key_prefixes(key):
        prefix_text = prefix.decode("utf-8")
        for index in range(1, closing):
            text = content(lines[index]).decode("utf-8", "replace")
            if not text.startswith(prefix_text):
                continue
            raw = text[len(prefix_text):].strip()
            if raw.startswith('"'):
                try:
                    print(json.loads(raw))
                except ValueError:
                    print(raw)
            elif raw.startswith("'") and len(raw) >= 2 and raw.endswith("'"):
                print(raw[1:-1].replace("''", "'"))
            else:
                print(raw)
            return 0
    return 1


def cmd_count(path, key):
    with open(path, "rb") as handle:
        data = handle.read()
    lines = split_lines(data)
    closing = frontmatter_end(lines)
    if closing < 0:
        return 2
    prefixes = key_prefixes(key)
    count = 0
    for index in range(1, closing):
        text = content(lines[index]).lstrip(b" \t")
        if text.startswith(prefixes):
            count += 1
    print(count)
    return 0


def main(argv):
    if len(argv) == 4 and argv[1] == "split":
        return cmd_split(argv[2], argv[3])
    if len(argv) == 4 and argv[1] == "value":
        return cmd_value(argv[2], argv[3])
    if len(argv) == 4 and argv[1] == "count":
        return cmd_count(argv[2], argv[3])
    sys.stderr.write("usage: plan_tool.py split|value|count ...\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY
  chmod +x "$PLAN_TOOL"
}

# ---------------------------------------------------------------------------
# Extraction of the real helper blocks.
#
# extract_helper_block <source-file> <marker> <out-file>
#
# Copies the fenced block that contains <marker> verbatim. Nothing is
# retyped here: the block that runs the test is the block that ships.
# ---------------------------------------------------------------------------
extract_helper_block() {
  local source="$1" marker="$2" out="$3"
  awk -v marker="$marker" '
    /^```/ {
      if (capturing) {
        if (found) { printf "%s", block; exit }
        capturing = 0; block = ""; found = 0
        next
      }
      capturing = 1; block = ""; found = 0
      next
    }
    capturing {
      block = block $0 "\n"
      if (index($0, marker) > 0) found = 1
    }
  ' "$source" > "$out"
}

# set_frontmatter_via <helpers> <plan> <key> <value> <stderr-file>
# Runs the EXTRACTED helper in a clean bash and returns its exit code.
set_frontmatter_via() {
  local helpers="$1" plan="$2" key="$3" value="$4" err="$5"
  bash -c 'source "$1"; shift; set_frontmatter "$@"' \
    _ "$helpers" "$plan" "$key" "$value" 2>"$err"
}

# flip_step_via <helpers> <plan> <step-id>
flip_step_via() {
  local helpers="$1" plan="$2" step="$3"
  bash -c 'source "$1"; shift; flip_step "$@"' _ "$helpers" "$plan" "$step"
}

# The optional mutation applied to the EXTRACTED bundles (copies outside
# the repository). It exists so that the sensitivity of the battery can be
# reproduced from outside the suite.
FORGE_TEST_HELPER_MUTATION="${FORGE_TEST_HELPER_MUTATION:-}"

# build_helper_mutant <name> <destination>
#
# Builds the deliberately broken copy of the extracted bundle. The three
# mutants are the ones of the sensitivity of this suite:
#
#   drop-single-quoted-prefix  — the key between single quotes is not
#                                 recognised (it would be DUPLICATED);
#   drop-double-quoted-prefix  — the key between double quotes is not
#                                 recognised;
#   drop-concurrency-guard     — the optimistic guard before the publication
#                                 is removed (a concurrent write would be
#                                 OVERWRITTEN).
build_helper_mutant() {
  local name="$1" destination="$2"

  case "$name" in
    drop-single-quoted-prefix)
      mutate_bundle "$CMD_BUNDLE" "$destination" \
        'prefixes = (raw_key + b":", quoted_key + b":", single_quoted_key + b":")' \
        'prefixes = (raw_key + b":", quoted_key + b":")'
      ;;
    drop-double-quoted-prefix)
      mutate_bundle "$CMD_BUNDLE" "$destination" \
        'prefixes = (raw_key + b":", quoted_key + b":", single_quoted_key + b":")' \
        'prefixes = (raw_key + b":", single_quoted_key + b":")'
      ;;
    drop-concurrency-guard)
      mutate_bundle_files "$CMD_BUNDLE" "$destination" \
        "$WORKDIR/guard.old" "$WORKDIR/guard.new"
      ;;
    *)
      echo "unknown mutation: $name" >&2
      return 1
      ;;
  esac
}

# mutate_bundle <src> <dst> <old> <new>
# Produces a deliberately broken copy of an extracted helper block. The suite
# uses it to prove that the battery is sensitive: a helper that misbehaves
# MUST make the battery fail.
mutate_bundle() {
  local src="$1" dst="$2" old="$3" new="$4"
  python3 - "$src" "$dst" "$old" "$new" <<'PY'
import sys

src, dst, old, new = sys.argv[1:5]
with open(src, encoding="utf-8") as handle:
    text = handle.read()
if old not in text:
    sys.stderr.write("mutation target not found: %s\n" % old)
    sys.exit(3)
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
PY
}

# mutate_bundle_files <src> <dst> <old-file> <new-file>
# The same, with the fragments read from files: the fragments of these
# mutations span several lines and one of them ends with a continuation.
mutate_bundle_files() {
  local src="$1" dst="$2" old_file="$3" new_file="$4"
  python3 - "$src" "$dst" "$old_file" "$new_file" <<'PY'
import sys

src, dst, old_file, new_file = sys.argv[1:5]
with open(src, encoding="utf-8") as handle:
    text = handle.read()
with open(old_file, encoding="utf-8") as handle:
    old = handle.read()
with open(new_file, encoding="utf-8") as handle:
    new = handle.read()
if text.count(old) != 1:
    sys.stderr.write("mutation target not found or ambiguous\n")
    sys.exit(3)
with open(dst, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
PY
}

# last_frontmatter_line <file> — the line right before the closing fence.
last_frontmatter_line() {
  awk 'NR == 1 { next } /^---$/ { print previous; exit } { previous = $0 }' "$1"
}

sig_line() {
  printf '%s\n' "$2" >> "$1"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

write_base_document() {
  local path="$1"
  printf -- '---\nslug: demo\nstatus: pending\n---\n\n# Title\n\nSome body text.\n' > "$path"
}

# ---------------------------------------------------------------------------
# Case 1 — a new key is inserted INSIDE the front-matter, immediately before
# the closing fence. The whole document is compared byte a byte with cmp.
# ---------------------------------------------------------------------------
case_insert_new_key() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-insert"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  write_base_document "$plan"

  printf -- '---\nslug: demo\nstatus: pending\ncurrent_step: 2.4\n---\n\n# Title\n\nSome body text.\n' \
    > "$dir/expected.md"
  printf -- '\n# Title\n\nSome body text.\n' > "$dir/expected.body"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "current_step" "2.4" "$err" || rc=$?

  # `leftovers` says whether a temporary file SURVIVED the run: it starts at
  # "yes" (the pessimistic value) and is cleared only when the observable
  # state proves that no temporary file was left behind. The verdict is
  # derived from that value, never from a constant.
  local exact=no key_line=no body_identical=no leftovers=yes
  if [ "$rc" -eq 0 ] && cmp -s "$plan" "$dir/expected.md"; then exact=yes; fi
  if [ "$(last_frontmatter_line "$plan")" = "current_step: 2.4" ]; then key_line=yes; fi
  if python3 "$PLAN_TOOL" split "$plan" "$dir/body.out" >/dev/null 2>&1 \
    && cmp -s "$dir/body.out" "$dir/expected.body"; then body_identical=yes; fi
  if [ -z "$(find "$dir" -maxdepth 1 -name '.set_frontmatter.*' -print -quit)" ]; then
    leftovers=no
  fi

  if [ "$rc" -eq 0 ]; then
    pass "insert_new_key: rc 0"
  else
    fail "insert_new_key: expected rc 0, got $rc"
  fi
  if [ "$exact" = yes ]; then
    pass "insert_new_key: document matches the expected bytes (cmp)"
  else
    fail "insert_new_key: document differs from the expected bytes"
    diff -u "$dir/expected.md" "$plan" 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
  if [ "$key_line" = yes ]; then
    pass "insert_new_key: the new key sits immediately before the closing fence"
  else
    fail "insert_new_key: the new key is not the last front-matter line"
  fi
  if [ "$body_identical" = yes ]; then
    pass "insert_new_key: body preserved byte a byte (cmp)"
  else
    fail "insert_new_key: body changed"
  fi
  if [ "$leftovers" = no ]; then
    pass "insert_new_key: no temporary file left behind"
  else
    fail "insert_new_key: a temporary file survived the run"
  fi

  sig_line "$sig" "insert_new_key rc=$rc exact=$exact key_line=$key_line body_identical=$body_identical leftovers=$leftovers"
}

# ---------------------------------------------------------------------------
# Case 2 — an existing key inside the front-matter is updated in place; the
# document is neither moved nor truncated.
# ---------------------------------------------------------------------------
case_update_existing_key() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-update"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  write_base_document "$plan"

  printf -- '---\nslug: demo\nstatus: in_progress\n---\n\n# Title\n\nSome body text.\n' \
    > "$dir/expected.md"
  printf -- '\n# Title\n\nSome body text.\n' > "$dir/expected.body"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" || rc=$?

  local exact=no value_ok=no occurrences=0 body_identical=no
  if [ "$rc" -eq 0 ] && cmp -s "$plan" "$dir/expected.md"; then exact=yes; fi
  if [ "$(python3 "$PLAN_TOOL" value "$plan" status 2>/dev/null || true)" = "in_progress" ]; then
    value_ok=yes
  fi
  occurrences="$(awk 'NR == 1 { next } /^---$/ { exit } /^status:/ { count++ } END { print count + 0 }' "$plan")"
  if python3 "$PLAN_TOOL" split "$plan" "$dir/body.out" >/dev/null 2>&1 \
    && cmp -s "$dir/body.out" "$dir/expected.body"; then body_identical=yes; fi

  if [ "$rc" -eq 0 ]; then pass "update_existing_key: rc 0"
  else fail "update_existing_key: expected rc 0, got $rc"; fi
  if [ "$exact" = yes ]; then pass "update_existing_key: document matches the expected bytes (cmp)"
  else
    fail "update_existing_key: document differs from the expected bytes"
    diff -u "$dir/expected.md" "$plan" 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
  if [ "$value_ok" = yes ]; then pass "update_existing_key: the value was updated"
  else fail "update_existing_key: the value was not updated"; fi
  if [ "$occurrences" = "1" ]; then pass "update_existing_key: exactly one key line remains"
  else fail "update_existing_key: expected 1 key line, got $occurrences"; fi
  if [ "$body_identical" = yes ]; then pass "update_existing_key: body preserved byte a byte (cmp)"
  else fail "update_existing_key: body changed"; fi

  sig_line "$sig" "update_existing_key rc=$rc exact=$exact value_ok=$value_ok occurrences=$occurrences body_identical=$body_identical"
}

# ---------------------------------------------------------------------------
# Case 3 — a homonymous key that only exists in the BODY is not a front-matter
# key: the helper must insert the key inside the front-matter AND keep the
# body line untouched.
# ---------------------------------------------------------------------------
case_homonym_in_body() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-homonym"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  printf -- '---\nslug: demo\n---\n\n# Title\n\nstatus: this-stays-in-the-body\n' > "$plan"

  printf -- '---\nslug: demo\nstatus: in_progress\n---\n\n# Title\n\nstatus: this-stays-in-the-body\n' \
    > "$dir/expected.md"
  printf -- '\n# Title\n\nstatus: this-stays-in-the-body\n' > "$dir/expected.body"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" || rc=$?

  local exact=no key_line=no body_identical=no body_kept=no
  if [ "$rc" -eq 0 ] && cmp -s "$plan" "$dir/expected.md"; then exact=yes; fi
  if [ "$(last_frontmatter_line "$plan")" = "status: in_progress" ]; then key_line=yes; fi
  if python3 "$PLAN_TOOL" split "$plan" "$dir/body.out" >/dev/null 2>&1 \
    && cmp -s "$dir/body.out" "$dir/expected.body"; then body_identical=yes; fi
  if grep -q '^status: this-stays-in-the-body$' "$plan"; then body_kept=yes; fi

  if [ "$rc" -eq 0 ]; then pass "homonym_in_body: rc 0"
  else fail "homonym_in_body: expected rc 0, got $rc"; fi
  if [ "$exact" = yes ]; then pass "homonym_in_body: key inserted and body line kept (cmp)"
  else
    fail "homonym_in_body: the document is not the expected one"
    diff -u "$dir/expected.md" "$plan" 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
  if [ "$key_line" = yes ]; then pass "homonym_in_body: the key was inserted inside the front-matter"
  else fail "homonym_in_body: the key was not inserted inside the front-matter"; fi
  if [ "$body_kept" = yes ]; then pass "homonym_in_body: the body occurrence was preserved"
  else fail "homonym_in_body: the body occurrence was lost"; fi
  if [ "$body_identical" = yes ]; then pass "homonym_in_body: body preserved byte a byte (cmp)"
  else fail "homonym_in_body: body changed"; fi

  sig_line "$sig" "homonym_in_body rc=$rc exact=$exact key_line=$key_line body_kept=$body_kept body_identical=$body_identical"
}

# ---------------------------------------------------------------------------
# Case 4 — a document without an opening front-matter fence is rejected: rc
# != 0, a diagnostic on stderr and the original file byte a byte intact.
# ---------------------------------------------------------------------------
case_missing_opening_fence() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-no-opening"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  printf -- '# Title\n\nstatus: pending\n' > "$plan"
  cp -p "$plan" "$dir/original.md"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" || rc=$?

  # `leftovers` says whether a temporary file SURVIVED the run: it starts at
  # "yes" and is cleared only when the observable state proves that no
  # temporary file was left behind.
  local intact=no diagnostic=no leftovers=yes
  if cmp -s "$plan" "$dir/original.md"; then intact=yes; fi
  if [ -s "$err" ] && grep -q 'set_frontmatter' "$err"; then diagnostic=yes; fi
  if [ -z "$(find "$dir" -maxdepth 1 -name '.set_frontmatter.*' -print -quit)" ]; then
    leftovers=no
  fi

  if [ "$rc" -ne 0 ]; then pass "missing_opening_fence: rc != 0 (got $rc)"
  else fail "missing_opening_fence: expected rc != 0, got 0"; fi
  if [ "$diagnostic" = yes ]; then pass "missing_opening_fence: a diagnostic was written to stderr"
  else fail "missing_opening_fence: no diagnostic on stderr"; fi
  if [ "$intact" = yes ]; then pass "missing_opening_fence: the original file is intact (cmp)"
  else fail "missing_opening_fence: the original file was modified"; fi
  if [ "$leftovers" = no ]; then pass "missing_opening_fence: no temporary file left behind"
  else fail "missing_opening_fence: a temporary file survived the run"; fi

  sig_line "$sig" "missing_opening_fence rc=$rc intact=$intact diagnostic=$diagnostic leftovers=$leftovers"
}

# ---------------------------------------------------------------------------
# Case 5 — a document with a single fence is rejected the same way.
# ---------------------------------------------------------------------------
case_single_fence() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-single-fence"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  printf -- '---\nslug: demo\n\n# Title\n' > "$plan"
  cp -p "$plan" "$dir/original.md"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" || rc=$?

  local intact=no diagnostic=no
  if cmp -s "$plan" "$dir/original.md"; then intact=yes; fi
  if [ -s "$err" ] && grep -q 'set_frontmatter' "$err"; then diagnostic=yes; fi

  if [ "$rc" -ne 0 ]; then pass "single_fence: rc != 0 (got $rc)"
  else fail "single_fence: expected rc != 0, got 0"; fi
  if [ "$diagnostic" = yes ]; then pass "single_fence: a diagnostic was written to stderr"
  else fail "single_fence: no diagnostic on stderr"; fi
  if [ "$intact" = yes ]; then pass "single_fence: the original file is intact (cmp)"
  else fail "single_fence: the original file was modified"; fi

  sig_line "$sig" "single_fence rc=$rc intact=$intact diagnostic=$diagnostic"
}

# ---------------------------------------------------------------------------
# Case 6 — a document without a final newline keeps its bytes: the helper
# must not append a newline to the body.
# ---------------------------------------------------------------------------
case_no_final_newline() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-no-newline"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  printf -- '---\nslug: demo\nstatus: pending\n---\n# Title' > "$plan"

  printf -- '---\nslug: demo\nstatus: pending\ncurrent_step: 2.4\n---\n# Title' \
    > "$dir/expected.md"
  printf -- '# Title' > "$dir/expected.body"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "current_step" "2.4" "$err" || rc=$?

  local exact=no body_identical=no
  if [ "$rc" -eq 0 ] && cmp -s "$plan" "$dir/expected.md"; then exact=yes; fi
  if python3 "$PLAN_TOOL" split "$plan" "$dir/body.out" >/dev/null 2>&1 \
    && cmp -s "$dir/body.out" "$dir/expected.body"; then body_identical=yes; fi

  if [ "$rc" -eq 0 ]; then pass "no_final_newline: rc 0"
  else fail "no_final_newline: expected rc 0, got $rc"; fi
  if [ "$exact" = yes ]; then pass "no_final_newline: no newline was appended (cmp)"
  else
    fail "no_final_newline: the document differs from the expected bytes"
    diff -u "$dir/expected.md" "$plan" 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
  if [ "$body_identical" = yes ]; then pass "no_final_newline: body bytes preserved (cmp)"
  else fail "no_final_newline: body bytes changed"; fi

  sig_line "$sig" "no_final_newline rc=$rc exact=$exact body_identical=$body_identical"
}

# ---------------------------------------------------------------------------
# Case 7 — a value with special characters (`:`, `&`, `/`, spaces) and a
# non-trivial key is written correctly.
# ---------------------------------------------------------------------------
case_special_characters() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-special"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  write_base_document "$plan"

  local value="phase 2: step 4 & more/weird"
  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "current_step" "$value" "$err" || rc=$?

  local value_ok=no key_line=no body_identical=no
  if [ "$(python3 "$PLAN_TOOL" value "$plan" current_step 2>/dev/null || true)" = "$value" ]; then
    value_ok=yes
  fi
  if [ "$(last_frontmatter_line "$plan")" = 'current_step: "phase 2: step 4 & more/weird"' ]; then
    key_line=yes
  fi
  printf -- '\n# Title\n\nSome body text.\n' > "$dir/expected.body"
  if python3 "$PLAN_TOOL" split "$plan" "$dir/body.out" >/dev/null 2>&1 \
    && cmp -s "$dir/body.out" "$dir/expected.body"; then body_identical=yes; fi

  if [ "$rc" -eq 0 ]; then pass "special_characters: rc 0"
  else fail "special_characters: expected rc 0, got $rc"; fi
  if [ "$value_ok" = yes ]; then pass "special_characters: the value was written correctly"
  else fail "special_characters: the value was not written correctly"; fi
  if [ "$key_line" = yes ]; then pass "special_characters: the value is quoted inside the front-matter"
  else fail "special_characters: unexpected rendering of the value"; fi
  if [ "$body_identical" = yes ]; then pass "special_characters: body preserved byte a byte (cmp)"
  else fail "special_characters: body changed"; fi

  sig_line "$sig" "special_characters rc=$rc value_ok=$value_ok key_line=$key_line body_identical=$body_identical"
}

# ---------------------------------------------------------------------------
# Case 8 — a missing file is rejected with a diagnostic and is not created.
# ---------------------------------------------------------------------------
case_missing_file() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-missing-file"
  mkdir -p "$dir"
  local plan="$dir/does-not-exist.md"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" || rc=$?

  # `not_created` says whether the file the helper had to reject stayed
  # absent: it starts at "no" and becomes "yes" only when the observable
  # state proves that the helper did NOT create it.
  local diagnostic=no not_created=no
  if [ -s "$err" ] && grep -q 'set_frontmatter' "$err"; then diagnostic=yes; fi
  if [ ! -e "$plan" ]; then not_created=yes; fi

  if [ "$rc" -ne 0 ]; then pass "missing_file: rc != 0 (got $rc)"
  else fail "missing_file: expected rc != 0, got 0"; fi
  if [ "$diagnostic" = yes ]; then pass "missing_file: a diagnostic was written to stderr"
  else fail "missing_file: no diagnostic on stderr"; fi
  if [ "$not_created" = yes ]; then pass "missing_file: the file was not created"
  else fail "missing_file: the file was created"; fi

  sig_line "$sig" "missing_file rc=$rc diagnostic=$diagnostic not_created=$not_created"
}

# ---------------------------------------------------------------------------
# Case 9 — flip_step flips only the exact step-id prefix.
# ---------------------------------------------------------------------------
case_flip_step() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-flip"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  printf -- '# Plan\n\n- [ ] Step 1.2 do something\n- [ ] Step 1.20 do something else\n- [x] Step 1.3 done\n' \
    > "$plan"

  local rc=0
  flip_step_via "$helpers" "$plan" "1.2" || rc=$?

  # `untouched` says whether the steps that had to stay untouched really
  # did: it starts at "no" and becomes "yes" only when BOTH other steps are
  # observed unchanged.
  local flipped=no untouched=no
  if grep -q '^- \[x\] Step 1.2 do something$' "$plan"; then flipped=yes; fi
  if grep -q '^- \[ \] Step 1.20 do something else$' "$plan" \
    && grep -q '^- \[x\] Step 1.3 done$' "$plan"; then untouched=yes; fi

  if [ "$rc" -eq 0 ]; then pass "flip_step: rc 0"
  else fail "flip_step: expected rc 0, got $rc"; fi
  if [ "$flipped" = yes ]; then pass "flip_step: the requested step was flipped"
  else fail "flip_step: the requested step was not flipped"; fi
  if [ "$untouched" = yes ]; then pass "flip_step: the other steps were not touched"
  else fail "flip_step: other steps were modified"; fi

  sig_line "$sig" "flip_step rc=$rc flipped=$flipped untouched=$untouched"
}

# ---------------------------------------------------------------------------
# Case 10 — a key written BETWEEN SINGLE QUOTES is the same key: it is
# updated IN PLACE and it is never duplicated.
# ---------------------------------------------------------------------------
case_update_single_quoted_key() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-single-quoted"
  rm -rf "$dir"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  printf -- "---\nslug: demo\n'status': pending\n---\n\n# Title\n\nSome body text.\n" > "$plan"

  printf -- '---\nslug: demo\nstatus: in_progress\n---\n\n# Title\n\nSome body text.\n' \
    > "$dir/expected.md"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" || rc=$?

  local exact=no value_ok=no occurrences=0 body_identical=no
  if [ "$rc" -eq 0 ] && cmp -s "$plan" "$dir/expected.md"; then exact=yes; fi
  if [ "$(python3 "$PLAN_TOOL" value "$plan" status 2>/dev/null || true)" = "in_progress" ]; then
    value_ok=yes
  fi
  occurrences="$(python3 "$PLAN_TOOL" count "$plan" status 2>/dev/null || echo 0)"
  printf -- '\n# Title\n\nSome body text.\n' > "$dir/expected.body"
  if python3 "$PLAN_TOOL" split "$plan" "$dir/body.out" >/dev/null 2>&1 \
    && cmp -s "$dir/body.out" "$dir/expected.body"; then body_identical=yes; fi

  if [ "$rc" -eq 0 ]; then pass "update_single_quoted_key: rc 0"
  else fail "update_single_quoted_key: expected rc 0, got $rc"; fi
  if [ "$exact" = yes ]; then pass "update_single_quoted_key: the key was updated in place (cmp)"
  else
    fail "update_single_quoted_key: the document differs from the expected bytes"
    diff -u "$dir/expected.md" "$plan" 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
  if [ "$value_ok" = yes ]; then pass "update_single_quoted_key: the value was updated"
  else fail "update_single_quoted_key: the value was not updated"; fi
  if [ "$occurrences" = "1" ]; then pass "update_single_quoted_key: the key was NOT duplicated"
  else fail "update_single_quoted_key: expected 1 key declaration, got $occurrences"; fi
  if [ "$body_identical" = yes ]; then pass "update_single_quoted_key: body preserved byte a byte (cmp)"
  else fail "update_single_quoted_key: body changed"; fi

  sig_line "$sig" "update_single_quoted_key rc=$rc exact=$exact value_ok=$value_ok occurrences=$occurrences body_identical=$body_identical"
}

# ---------------------------------------------------------------------------
# Case 11 — the same for a key written BETWEEN DOUBLE QUOTES.
# ---------------------------------------------------------------------------
case_update_double_quoted_key() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-double-quoted"
  rm -rf "$dir"
  mkdir -p "$dir"
  local plan="$dir/plan.md"
  printf -- '---\nslug: demo\n"status": pending\n---\n\n# Title\n\nSome body text.\n' > "$plan"

  printf -- '---\nslug: demo\nstatus: in_progress\n---\n\n# Title\n\nSome body text.\n' \
    > "$dir/expected.md"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" || rc=$?

  local exact=no value_ok=no occurrences=0 body_identical=no
  if [ "$rc" -eq 0 ] && cmp -s "$plan" "$dir/expected.md"; then exact=yes; fi
  if [ "$(python3 "$PLAN_TOOL" value "$plan" status 2>/dev/null || true)" = "in_progress" ]; then
    value_ok=yes
  fi
  occurrences="$(python3 "$PLAN_TOOL" count "$plan" status 2>/dev/null || echo 0)"
  printf -- '\n# Title\n\nSome body text.\n' > "$dir/expected.body"
  if python3 "$PLAN_TOOL" split "$plan" "$dir/body.out" >/dev/null 2>&1 \
    && cmp -s "$dir/body.out" "$dir/expected.body"; then body_identical=yes; fi

  if [ "$rc" -eq 0 ]; then pass "update_double_quoted_key: rc 0"
  else fail "update_double_quoted_key: expected rc 0, got $rc"; fi
  if [ "$exact" = yes ]; then pass "update_double_quoted_key: the key was updated in place (cmp)"
  else
    fail "update_double_quoted_key: the document differs from the expected bytes"
    diff -u "$dir/expected.md" "$plan" 2>/dev/null | sed 's/^/      /' >&2 || true
  fi
  if [ "$value_ok" = yes ]; then pass "update_double_quoted_key: the value was updated"
  else fail "update_double_quoted_key: the value was not updated"; fi
  if [ "$occurrences" = "1" ]; then pass "update_double_quoted_key: the key was NOT duplicated"
  else fail "update_double_quoted_key: expected 1 key declaration, got $occurrences"; fi
  if [ "$body_identical" = yes ]; then pass "update_double_quoted_key: body preserved byte a byte (cmp)"
  else fail "update_double_quoted_key: body changed"; fi

  sig_line "$sig" "update_double_quoted_key rc=$rc exact=$exact value_ok=$value_ok occurrences=$occurrences body_identical=$body_identical"
}

# ---------------------------------------------------------------------------
# Case 12 — a CONCURRENT write: the plan changes between the moment the
# helper reads it and the moment it publishes its own version. The helper
# must ABORT (rc != 0) instead of overwriting the change of the other
# writer, and it must not leave a temporary file behind.
#
# The interleaving is OBSERVED, not assumed: the helper creates its
# temporary file strictly AFTER it has read the plan, so the appearance of
# that temporary file is the signal that the plan can be changed safely.
# The document is big enough to make that window observable from outside.
# ---------------------------------------------------------------------------
case_concurrent_write_is_aborted() {
  local helpers="$1" sig="$2"
  local dir="$WORKDIR/case-concurrent"
  rm -rf "$dir"
  mkdir -p "$dir"
  local plan="$dir/plan.md"

  {
    printf -- '---\nslug: demo\nstatus: pending\n---\n\n# Title\n\n'
    python3 -c '
import sys
chunk = b"body line for the concurrency window\n" * 1000
with open(sys.argv[1], "wb") as handle:
    for _ in range(400):
        handle.write(chunk)
' "$dir/body.bin"
    cat "$dir/body.bin"
  } > "$plan"

  local err="$dir/stderr.txt" rc=0
  set_frontmatter_via "$helpers" "$plan" "status" "in_progress" "$err" &
  local helper_pid=$!

  # The window: wait for the temporary file of the helper (it appears after
  # the read of the plan) and publish the change of the OTHER writer.
  local observed=no candidate deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    for candidate in "$dir"/.set_frontmatter.*; do
      if [ -e "$candidate" ]; then
        observed=yes
        break
      fi
    done
    [ "$observed" = yes ] && break
  done

  if [ "$observed" = yes ]; then
    printf -- '---\nslug: demo\nstatus: written_by_the_other_writer\n---\n\n# Title\n\n' \
      > "$dir/other-writer.md"
    cat "$dir/body.bin" >> "$dir/other-writer.md"
    mv -f "$dir/other-writer.md" "$plan"
  fi

  wait "$helper_pid" || rc=$?

  local aborted=no preserved=no leftovers=yes diagnostic=no
  if [ "$rc" -ne 0 ]; then aborted=yes; fi
  if grep -qF "plan changed since it was read" "$err" 2>/dev/null; then diagnostic=yes; fi
  if grep -qF "status: written_by_the_other_writer" "$plan" 2>/dev/null; then preserved=yes; fi
  if [ -z "$(find "$dir" -maxdepth 1 -name '.set_frontmatter.*' -print -quit)" ]; then
    leftovers=no
  fi

  if [ "$observed" = yes ]; then
    pass "concurrent_write: the window of the concurrent write was observed"
  else
    fail "concurrent_write: the window of the concurrent write was NOT observed"
  fi
  if [ "$aborted" = yes ]; then pass "concurrent_write: the helper ABORTED (rc != 0, got $rc)"
  else fail "concurrent_write: expected rc != 0, got 0"; fi
  if [ "$diagnostic" = yes ]; then pass "concurrent_write: the diagnostic explains the abort"
  else fail "concurrent_write: the diagnostic does not explain the abort"; fi
  if [ "$preserved" = yes ]; then pass "concurrent_write: the change of the other writer was preserved"
  else fail "concurrent_write: the change of the other writer was LOST"; fi
  if [ "$leftovers" = no ]; then pass "concurrent_write: no temporary file left behind"
  else fail "concurrent_write: a temporary file survived the run"; fi

  sig_line "$sig" "concurrent_write rc=$rc observed=$observed aborted=$aborted diagnostic=$diagnostic preserved=$preserved leftovers=$leftovers"
}

run_battery() {
  local helpers="$1" sig="$2"
  : > "$sig"
  case_insert_new_key "$helpers" "$sig"
  case_update_existing_key "$helpers" "$sig"
  case_homonym_in_body "$helpers" "$sig"
  case_missing_opening_fence "$helpers" "$sig"
  case_single_fence "$helpers" "$sig"
  case_no_final_newline "$helpers" "$sig"
  case_special_characters "$helpers" "$sig"
  case_missing_file "$helpers" "$sig"
  case_flip_step "$helpers" "$sig"
  case_update_single_quoted_key "$helpers" "$sig"
  case_update_double_quoted_key "$helpers" "$sig"
  case_concurrent_write_is_aborted "$helpers" "$sig"
}

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

echo "=== execute_plan_helpers_unit.sh ==="

WORKDIR="$(mktemp -d "$TMPDIR_BASE/helpers-$$-XXXXXX")"
write_plan_tool "$WORKDIR/plan_tool.py"

# The fragments of the mutation of the optimistic guard: they are written
# BEFORE anything, so the mutation can be built from outside the suite too.
cat > "$WORKDIR/guard.old" <<'GUARD_OLD'
        if (current_stat.st_dev, current_stat.st_ino) != (source_stat.st_dev, source_stat.st_ino) \
            or current_data != original:
            fail("plan changed since it was read; refusing to overwrite concurrent updates")
GUARD_OLD
cat > "$WORKDIR/guard.new" <<'GUARD_NEW'
        if False:
            fail("plan changed since it was read; refusing to overwrite concurrent updates")
GUARD_NEW

CMD_HELPERS="$WORKDIR/helpers-opencode.sh"
CMD_HELPERS_FLIP="$WORKDIR/helpers-opencode.flip.sh"
SKILL_HELPERS="$WORKDIR/helpers-claude.sh"
SKILL_HELPERS_FLIP="$WORKDIR/helpers-claude.flip.sh"
CMD_BUNDLE="$WORKDIR/bundle-opencode.sh"
SKILL_BUNDLE="$WORKDIR/bundle-claude.sh"

test_extract_helpers_from_both_variants() {
  extract_helper_block "$OPENCODE_VARIANT" "set_frontmatter() {" "$CMD_HELPERS"
  extract_helper_block "$OPENCODE_VARIANT" "flip_step() {" "$CMD_HELPERS_FLIP"

  extract_helper_block "$CLAUDE_VARIANT" "set_frontmatter() {" "$SKILL_HELPERS"
  extract_helper_block "$CLAUDE_VARIANT" "flip_step() {" "$SKILL_HELPERS_FLIP"

  local file
  for file in "$CMD_HELPERS" "$SKILL_HELPERS" "$CMD_HELPERS_FLIP" "$SKILL_HELPERS_FLIP"; do
    if [ -s "$file" ]; then
      pass "extract: $(basename "$file") is not empty"
    else
      fail "extract: $(basename "$file") is empty — the helper block was not found"
    fi
  done

  if grep -q '^set_frontmatter() {' "$CMD_HELPERS" && grep -q '^flip_step() {' "$CMD_HELPERS_FLIP"; then
    pass "extract: the OpenCode variant exposes both helpers"
  else
    fail "extract: the OpenCode variant does not expose both helpers"
  fi
  if grep -q '^set_frontmatter() {' "$SKILL_HELPERS" && grep -q '^flip_step() {' "$SKILL_HELPERS_FLIP"; then
    pass "extract: the Claude variant exposes both helpers"
  else
    fail "extract: the Claude variant does not expose both helpers"
  fi

  # The bundle is the concatenation of the two EXTRACTED blocks: the suite
  # never retypes a helper.
  cat "$CMD_HELPERS" "$CMD_HELPERS_FLIP" > "$CMD_BUNDLE"
  cat "$SKILL_HELPERS" "$SKILL_HELPERS_FLIP" > "$SKILL_BUNDLE"

  # The optional mutation is applied to BOTH bundles (they are copies
  # outside the repository), so the parity of the two variants survives it
  # and the battery observes the defect of the rule, not a divergence.
  if [ -n "$FORGE_TEST_HELPER_MUTATION" ]; then
    local mutated_cmd="$WORKDIR/bundle-opencode.mutated.sh"
    local mutated_skill="$WORKDIR/bundle-claude.mutated.sh"
    if ! build_helper_mutant "$FORGE_TEST_HELPER_MUTATION" "$mutated_cmd"; then
      echo "  FAIL: the mutation '$FORGE_TEST_HELPER_MUTATION' could not be applied" >&2
      return 1
    fi
    cp "$mutated_cmd" "$mutated_skill"
    CMD_BUNDLE="$mutated_cmd"
    SKILL_BUNDLE="$mutated_skill"
  fi

  if bash -n "$CMD_BUNDLE" 2>/dev/null && bash -n "$SKILL_BUNDLE" 2>/dev/null; then
    pass "extract: both bundles are syntactically valid bash"
  else
    fail "extract: a bundle is not valid bash"
  fi
}

test_battery_on_opencode_variant() {
  run_battery "$CMD_BUNDLE" "$WORKDIR/signature-opencode.txt"
}

test_battery_on_claude_variant() {
  run_battery "$SKILL_BUNDLE" "$WORKDIR/signature-claude.txt"
}

test_signatures_are_identical() {
  local cmd_sig="$WORKDIR/signature-opencode.txt"
  local skill_sig="$WORKDIR/signature-claude.txt"

  if cmp -s "$cmd_sig" "$skill_sig"; then
    pass "parity: both variants produce the same signature for the whole battery"
  else
    fail "parity: the two variants disagree"
    diff -u "$cmd_sig" "$skill_sig" | sed 's/^/      /' >&2 || true
  fi

  echo "  --- signature (identical for both variants):"
  sed 's/^/      /' "$cmd_sig"
}

# ---------------------------------------------------------------------------
# Sensitivity of the battery: a helper that writes the key OUTSIDE the
# front-matter, or that truncates the document, must make the battery fail.
# Without this the battery could be vacuously green.
# ---------------------------------------------------------------------------
test_battery_detects_a_broken_helper() {
  local broken_insert="$WORKDIR/helpers-broken-insert.sh"
  local broken_truncate="$WORKDIR/helpers-broken-truncate.sh"

  if ! mutate_bundle "$CMD_BUNDLE" "$broken_insert" \
    'updated.insert(closing, rendered + ending)' \
    'updated.insert(closing + 1, rendered + ending)'; then
    fail "mutation: could not build the 'writes outside the front-matter' helper"
    return
  fi
  if ! mutate_bundle "$CMD_BUNDLE" "$broken_truncate" \
    'result = b"".join(updated)' \
    'result = b"".join(updated[:closing + 1])'; then
    fail "mutation: could not build the 'truncates the document' helper"
    return
  fi

  local output
  # Every mutation runs in its OWN working directory: the fixtures of one
  # mutation must not be seen by the next one.
  output="$(
    export WORKDIR="$WORKDIR/mutation-insert"
    mkdir -p "$WORKDIR"
    run_battery "$broken_insert" "$WORKDIR/signature-broken-insert.txt" 2>&1
  )" || true
  if grep -q '^  FAIL:' <<< "$output"; then
    pass "mutation: the battery detects a helper that writes the key outside the front-matter"
  else
    fail "mutation: the battery did NOT detect the broken helper"
    printf '%s\n' "$output" | sed 's/^/      /' >&2
  fi

  output="$(
    export WORKDIR="$WORKDIR/mutation-truncate"
    mkdir -p "$WORKDIR"
    run_battery "$broken_truncate" "$WORKDIR/signature-broken-truncate.txt" 2>&1
  )" || true
  if grep -q '^  FAIL:' <<< "$output"; then
    pass "mutation: the battery detects a helper that truncates the document"
  else
    fail "mutation: the battery did NOT detect the truncating helper"
    printf '%s\n' "$output" | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# Sensitivity of the three indicators that the checkpoint review found
# VACUOUS: `leftovers`, `not_created` and `untouched`.
#
# Each mutation breaks exactly ONE of them and the suite asserts that BOTH
# the FAIL message and the recorded signature come from THAT indicator. A
# battery that failed for another reason would not prove that the indicator
# works, so both are required.
#
# The mutations are applied to a COPY of the extracted bundle inside the
# private WORKDIR. The repository is never modified.
# ---------------------------------------------------------------------------
test_battery_detects_each_indicator() {
  local broken_leftover="$WORKDIR/helpers-broken-leftover.sh"
  local broken_create="$WORKDIR/helpers-broken-create.sh"
  local broken_touch="$WORKDIR/helpers-broken-touch.sh"
  local output signature

  # (1) `leftovers`: the helper succeeds but leaves a temporary file behind.
  if ! mutate_bundle "$CMD_BUNDLE" "$broken_leftover" \
    '        os.replace(temp_path, plan)
        temp_path = None' \
    '        os.replace(temp_path, plan)
        temp_path = None
        open(os.path.join(directory, ".set_frontmatter.leaked"), "wb").write(result)'; then
    fail "mutation: could not build the 'leaves a temporary file behind' helper"
    return
  fi

  # (2) `not_created`: the helper creates the file it had to reject.
  if ! mutate_bundle "$CMD_BUNDLE" "$broken_create" \
    '    if not os.path.isfile(plan):
        fail(f"plan is not a regular file: {plan}")' \
    '    if not os.path.isfile(plan):
        open(plan, "wb").write(b"---\nslug: demo\n---\n")
        fail(f"plan is not a regular file: {plan}")'; then
    fail "mutation: could not build the 'creates the file it must not create' helper"
    return
  fi

  # (3) `untouched`: the helper also flips the steps it had to leave alone.
  if ! mutate_bundle "$CMD_BUNDLE" "$broken_touch" \
    '  sed -i "s|^- \[ \] Step ${step_id} |- [x] Step ${step_id} |" "$plan"' \
    '  sed -i "s|^- \[ \] Step |- [x] Step |" "$plan"'; then
    fail "mutation: could not build the 'modifies the steps it must not touch' helper"
    return
  fi

  output="$(
    export WORKDIR="$WORKDIR/mutation-leftover"
    mkdir -p "$WORKDIR"
    run_battery "$broken_leftover" "$WORKDIR/signature-leftover.txt" 2>&1
  )" || true
  signature="$WORKDIR/mutation-leftover/signature-leftover.txt"
  if grep -q '^  FAIL: insert_new_key: a temporary file survived the run$' <<< "$output" \
    && grep -q '^insert_new_key .*leftovers=yes$' "$signature"; then
    pass "sensitivity: the battery detects a helper that leaves a temporary file behind (leftovers)"
  else
    fail "sensitivity: the battery did NOT detect the leftover temporary file (leftovers)"
    printf '%s\n' "$output" | sed 's/^/      /' >&2
    if [ -f "$signature" ]; then sed 's/^/      /' "$signature" >&2; fi
  fi

  output="$(
    export WORKDIR="$WORKDIR/mutation-create"
    mkdir -p "$WORKDIR"
    run_battery "$broken_create" "$WORKDIR/signature-create.txt" 2>&1
  )" || true
  signature="$WORKDIR/mutation-create/signature-create.txt"
  if grep -q '^  FAIL: missing_file: the file was created$' <<< "$output" \
    && grep -q '^missing_file .*not_created=no$' "$signature"; then
    pass "sensitivity: the battery detects a helper that creates the file it must not create (not_created)"
  else
    fail "sensitivity: the battery did NOT detect the creation of the rejected file (not_created)"
    printf '%s\n' "$output" | sed 's/^/      /' >&2
    if [ -f "$signature" ]; then sed 's/^/      /' "$signature" >&2; fi
  fi

  output="$(
    export WORKDIR="$WORKDIR/mutation-touch"
    mkdir -p "$WORKDIR"
    run_battery "$broken_touch" "$WORKDIR/signature-touch.txt" 2>&1
  )" || true
  signature="$WORKDIR/mutation-touch/signature-touch.txt"
  if grep -q '^  FAIL: flip_step: other steps were modified$' <<< "$output" \
    && grep -q '^flip_step .*untouched=no$' "$signature"; then
    pass "sensitivity: the battery detects a helper that modifies the steps it must not touch (untouched)"
  else
    fail "sensitivity: the battery did NOT detect the modification of the other steps (untouched)"
    printf '%s\n' "$output" | sed 's/^/      /' >&2
    if [ -f "$signature" ]; then sed 's/^/      /' "$signature" >&2; fi
  fi
}

# ---------------------------------------------------------------------------
# Sensitivity of the three NEW rules: the recognition of the QUOTED keys and
# the ABORT on a concurrent write.
#
# Each mutation breaks exactly ONE rule and the suite asserts that BOTH the
# FAIL message and the recorded signature come from THAT rule. A battery
# that failed for another reason would not prove that the rule works.
#
# The mutations are applied to a COPY of the extracted bundle inside the
# private WORKDIR. The repository is never modified.
# ---------------------------------------------------------------------------
test_battery_detects_each_new_rule() {
  local output signature
  local broken_single="$WORKDIR/helpers-broken-single-quoted.sh"
  local broken_double="$WORKDIR/helpers-broken-double-quoted.sh"
  local broken_guard="$WORKDIR/helpers-broken-guard.sh"

  # (1) the key between single quotes is not recognised: it would be
  # DUPLICATED instead of updated.
  if ! build_helper_mutant drop-single-quoted-prefix "$broken_single"; then
    fail "mutation: could not build the 'does not recognise the single-quoted key' helper"
    return
  fi

  # (2) the key between double quotes is not recognised.
  if ! build_helper_mutant drop-double-quoted-prefix "$broken_double"; then
    fail "mutation: could not build the 'does not recognise the double-quoted key' helper"
    return
  fi

  # (3) the optimistic guard before the publication is removed: a concurrent
  # write would be OVERWRITTEN.
  if ! build_helper_mutant drop-concurrency-guard "$broken_guard"; then
    fail "mutation: could not build the 'overwrites the concurrent write' helper"
    return
  fi

  output="$(
    export WORKDIR="$WORKDIR/mutation-single-quoted"
    mkdir -p "$WORKDIR"
    run_battery "$broken_single" "$WORKDIR/signature-single-quoted.txt" 2>&1
  )" || true
  signature="$WORKDIR/mutation-single-quoted/signature-single-quoted.txt"
  if grep -q '^  FAIL: update_single_quoted_key: expected 1 key declaration, got 2$' <<< "$output" \
    && grep -q '^update_single_quoted_key .*occurrences=2' "$signature"; then
    pass "sensitivity: the battery detects a helper that does not recognise the single-quoted key"
  else
    fail "sensitivity: the battery did NOT detect the duplicated single-quoted key"
    printf '%s\n' "$output" | grep -F "FAIL:" | sed 's/^/      /' >&2 || true
    if [ -f "$signature" ]; then sed 's/^/      /' "$signature" >&2; fi
  fi

  output="$(
    export WORKDIR="$WORKDIR/mutation-double-quoted"
    mkdir -p "$WORKDIR"
    run_battery "$broken_double" "$WORKDIR/signature-double-quoted.txt" 2>&1
  )" || true
  signature="$WORKDIR/mutation-double-quoted/signature-double-quoted.txt"
  if grep -q '^  FAIL: update_double_quoted_key: expected 1 key declaration, got 2$' <<< "$output" \
    && grep -q '^update_double_quoted_key .*occurrences=2' "$signature"; then
    pass "sensitivity: the battery detects a helper that does not recognise the double-quoted key"
  else
    fail "sensitivity: the battery did NOT detect the duplicated double-quoted key"
    printf '%s\n' "$output" | grep -F "FAIL:" | sed 's/^/      /' >&2 || true
    if [ -f "$signature" ]; then sed 's/^/      /' "$signature" >&2; fi
  fi

  output="$(
    export WORKDIR="$WORKDIR/mutation-guard"
    mkdir -p "$WORKDIR"
    run_battery "$broken_guard" "$WORKDIR/signature-guard.txt" 2>&1
  )" || true
  signature="$WORKDIR/mutation-guard/signature-guard.txt"
  if grep -q '^  FAIL: concurrent_write: expected rc != 0, got 0$' <<< "$output" \
    && grep -q '^concurrent_write .*aborted=no' "$signature" \
    && grep -q '^concurrent_write .*preserved=no' "$signature"; then
    pass "sensitivity: the battery detects a helper that overwrites a concurrent write"
  else
    fail "sensitivity: the battery did NOT detect the overwritten concurrent write"
    printf '%s\n' "$output" | grep -F "FAIL:" | sed 's/^/      /' >&2 || true
    if [ -f "$signature" ]; then sed 's/^/      /' "$signature" >&2; fi
  fi
}

run_test test_extract_helpers_from_both_variants
run_test test_battery_on_opencode_variant
run_test test_battery_on_claude_variant
run_test test_signatures_are_identical
run_test test_battery_detects_a_broken_helper
run_test test_battery_detects_each_indicator
run_test test_battery_detects_each_new_rule
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
