#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/execute_plan_parity_unit.sh — Semantic parity between the two
# execute-plan variants and the installability of the distributed references.
#
# The two variants are NOT expected to be identical: the Claude variant uses
# the `Task` tool and the `opus` model, the OpenCode variant uses `subagent`
# and `gpt-6.1-sol`. Parity means SEMANTIC parity: the same protocol, the
# same batch algorithm, the same review summary and the same helpers.
#
# Every check is written as a function that takes a ROOT, so the same check
# can be run against a MUTATED COPY of the sources: that is how the suite
# proves that the checks DETECT a missing helper, a missing protocol, a
# missing batch algorithm or a missing FINDINGS literal.
#
# Compatible with bash 3.2+.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"

FAIL=0
PASS=0

TMPDIR_BASE="$FORGE_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

WORKDIR=""
cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
  rm -rf "$TMPDIR_BASE"/parity-$$-* 2>/dev/null || true
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
# Source manipulation helpers (used only on throw-away copies).
# ---------------------------------------------------------------------------

# remove_helper_block <file> <marker> — deletes the fenced block that contains
# <marker>.
remove_helper_block() {
  python3 - "$1" "$2" <<'PY'
import sys

path, marker = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")

out = []
index = 0
total = len(lines)
while index < total:
    if lines[index].startswith("```"):
        end = index + 1
        while end < total and not lines[end].startswith("```"):
            end += 1
        block = lines[index:end + 1]
        if any(marker in line for line in block):
            index = end + 1
            continue
        out.extend(block)
        index = end + 1
        continue
    out.append(lines[index])
    index += 1

with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(out))
PY
}

# replace_in_file <file> <old> <new> — replaces every occurrence.
replace_in_file() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys

path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
if old not in text:
    sys.stderr.write("pattern not found: %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new))
PY
}

# remove_lines_containing <file> <needle>
remove_lines_containing() {
  python3 - "$1" "$2" <<'PY'
import sys

path, needle = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
kept = [line for line in lines if needle not in line]
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(kept))
PY
}

# extract_helper_block <source-file> <marker> <out-file>
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

# ---------------------------------------------------------------------------
# The checks. Each one returns 0 when the contract holds and 1 when it does
# not, printing the reason. They never touch the counters themselves: the
# caller decides whether a non-zero status is a failure (real sources) or the
# expected outcome (mutated copy).
# ---------------------------------------------------------------------------

# variant_text <out> <file>...
# Concatenates the sources of a variant into one text file. The checks read
# the variant through this file so a variant may be split over several
# documents (the Claude variant delegates the batch protocol to a reference).
variant_text() {
  local out="$1"
  shift
  : > "$out"
  local file
  for file in "$@"; do
    if [ -f "$file" ]; then
      cat "$file" >> "$out"
      printf '\n' >> "$out"
    fi
  done
}

# check_helpers_present <root>
# Both variants must expose set_frontmatter and flip_step, and both blocks
# must be extractable and be valid bash.
check_helpers_present() {
  local root="$1"
  local tmp="$WORKDIR/probe-helpers"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  local status=0

  local variant file
  for variant in opencode claude; do
    if [ "$variant" = opencode ]; then
      file="$root/open-code/commands/execute-plan.md"
    else
      file="$root/skills/execute-plan/SKILL.md"
    fi
    if [ ! -f "$file" ]; then
      echo "  MISSING: $variant variant not found: $file"
      status=1
      continue
    fi
    local helper
    for helper in "set_frontmatter() {" "flip_step() {"; do
      local slug out
      slug="$(printf '%s' "$helper" | tr -cd '[:alnum:]')"
      out="$tmp/${variant}-${slug}.sh"
      extract_helper_block "$file" "$helper" "$out"
      if [ ! -s "$out" ]; then
        echo "  MISSING: $variant variant does not expose the helper block: $helper"
        status=1
        continue
      fi
      if ! bash -n "$out" 2>/dev/null; then
        echo "  INVALID: $variant variant helper block is not valid bash: $helper"
        status=1
        continue
      fi
      echo "  OK: $variant variant exposes an executable helper block: $helper"
    done
  done

  return "$status"
}

# check_infra_protocol <root>
# The applier/tech infrastructure-failure protocol: detection of a failed
# dispatch, stop, the literal error, and no retry / no re-route.
check_infra_protocol() {
  local root="$1"
  local status=0

  local opencode_text="$root/open-code/commands/execute-plan.md"
  local claude_skill="$root/skills/execute-plan/SKILL.md"
  local claude_batch="$root/skills/execute-plan/reference/batch-algorithm.md"

  check_infra_markers() {
    local label="$1" text="$2"
    local marker
    local -a markers=(
      'infrastructure error \(no return code'
      'stop,? (and )?surface'
      'Fallo de infraestructura del subagente applier'
      'Fallo de infraestructura del subagente tech'
      'no retry, no re-route|retry, or re-route'
    )
    for marker in "${markers[@]}"; do
      # A herestring, not a pipe: `grep -q` closes the pipe as soon as it
      # finds a match and the writer would die of SIGPIPE, which `pipefail`
      # would report as a failed pipeline (a flaky "the marker is missing").
      if grep -qE "$marker" <<< "$text"; then
        echo "  OK: $label carries the protocol marker: $marker"
      else
        echo "  MISSING: $label does not carry the protocol marker: $marker"
        status=1
      fi
    done
  }

  if [ ! -f "$opencode_text" ]; then
    echo "  MISSING: OpenCode variant not found: $opencode_text"
    return 1
  fi
  variant_text "$WORKDIR/probe-infra-opencode.txt" "$opencode_text"
  check_infra_markers "opencode variant" "$(cat "$WORKDIR/probe-infra-opencode.txt")"

  if [ ! -f "$claude_skill" ] || [ ! -f "$claude_batch" ]; then
    echo "  MISSING: Claude variant sources not found"
    return 1
  fi
  variant_text "$WORKDIR/probe-infra-claude.txt" "$claude_skill" "$claude_batch"
  check_infra_markers "claude variant" "$(cat "$WORKDIR/probe-infra-claude.txt")"

  return "$status"
}

# check_batch_algorithm <root>
# The bounded batching algorithm: cap of 8, phase and [T] boundaries, and
# the batch states.
check_batch_algorithm() {
  local root="$1"
  local status=0

  local opencode_text="$root/open-code/commands/execute-plan.md"
  local claude_text="$root/skills/execute-plan/reference/batch-algorithm.md"

  local -a markers=(
    'cap = 8 steps per batch'
    'The size cap of 8 is reached'
    'A phase boundary'
    'BATCH MODE: N steps from phase P'
    'OK_BATCH'
    'BLOCKED_BATCH'
  )

  # The stop condition on a [T] step: the two variants word the article
  # differently ("A `[T]` step" / "An `[T]` step"), so the marker is a pattern.
  local -a patterns=(
    '\[T\]`? step'
  )

  local label text marker
  for label in opencode claude; do
    if [ "$label" = opencode ]; then
      text="$opencode_text"
    else
      text="$claude_text"
    fi
    if [ ! -f "$text" ]; then
      echo "  MISSING: $label variant batch algorithm not found: $text"
      status=1
      continue
    fi
    for marker in "${markers[@]}"; do
      if grep -qF "$marker" "$text"; then
        echo "  OK: $label variant carries the batch marker: $marker"
      else
        echo "  MISSING: $label variant does not carry the batch marker: $marker"
        status=1
      fi
    done
    for marker in "${patterns[@]}"; do
      if grep -qE "$marker" "$text"; then
        echo "  OK: $label variant carries the batch pattern: $marker"
      else
        echo "  MISSING: $label variant does not carry the batch pattern: $marker"
        status=1
      fi
    done
  done

  return "$status"
}

# check_findings_literal <root>
# The literal review summary must be present in the THREE review templates.
check_findings_literal() {
  local root="$1"
  local status=0
  local literal='FINDINGS: <c> critical, <m> major, <n> minor'

  local -a templates=(
    "skills/execute-plan/reference/review-template.md"
    "open-code/commands/execute-plan.md"
    "open-code/commands/review.md"
  )

  local template
  for template in "${templates[@]}"; do
    if [ ! -f "$root/$template" ]; then
      echo "  MISSING: review template not found: $template"
      status=1
      continue
    fi
    if grep -qF "$literal" "$root/$template"; then
      echo "  OK: review template carries the FINDINGS literal: $template"
    else
      echo "  MISSING: review template does not carry the FINDINGS literal: $template"
      status=1
    fi
  done

  return "$status"
}

# check_platform_identity <root>
# Each variant must keep its OWN platform identity. The check never demands
# the identity of the other platform: the Claude variant is checked for
# `Task`/`opus` only, the OpenCode variant for `subagent`/`gpt-6.1-sol` only.
check_platform_identity() {
  local root="$1"
  local status=0

  local claude_file="$root/skills/execute-plan/SKILL.md"
  local opencode_file="$root/open-code/commands/execute-plan.md"

  if [ -f "$claude_file" ]; then
    if grep -q '`Task`' "$claude_file"; then
      echo "  OK: claude variant uses the Task tool"
    else
      echo "  MISSING: claude variant does not use the Task tool"
      status=1
    fi
    if grep -q 'opus' "$claude_file"; then
      echo "  OK: claude variant uses the opus model"
    else
      echo "  MISSING: claude variant does not use the opus model"
      status=1
    fi
  else
    echo "  MISSING: claude variant not found: $claude_file"
    status=1
  fi

  if [ -f "$opencode_file" ]; then
    if grep -q 'subagent' "$opencode_file"; then
      echo "  OK: opencode variant uses the subagent tool"
    else
      echo "  MISSING: opencode variant does not use the subagent tool"
      status=1
    fi
    if grep -q 'gpt-6.1-sol' "$opencode_file"; then
      echo "  OK: opencode variant uses the gpt-6.1-sol model"
    else
      echo "  MISSING: opencode variant does not use the gpt-6.1-sol model"
      status=1
    fi
  else
    echo "  MISSING: opencode variant not found: $opencode_file"
    status=1
  fi

  return "$status"
}

# check_reference_distribution <root>
# shared/reference/escalation-codes.md must be part of the component
# manifest, and the relative references to it must resolve to the
# DISTRIBUTED path (not to a checkout-only path).
check_reference_distribution() {
  local root="$1"
  local install_root="$WORKDIR/install-root"
  rm -rf "$install_root"
  mkdir -p "$install_root"

  python3 - "$root" "$install_root" <<'PY'
import json
import os
import re
import shutil
import sys

root, install_root = sys.argv[1], sys.argv[2]
problems = []

manifest_path = os.path.join(root, "shared/components/commands.json")
try:
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
except Exception as error:  # noqa: BLE001 - reported as a contract problem
    print("  MISSING: the component manifest is not readable: %s" % error)
    sys.exit(1)

entries = manifest.get("symlinks", [])
dests = {entry["dest"] for entry in entries}
srcs = {entry["src"]: entry["dest"] for entry in entries}

expected_src = "shared/reference/escalation-codes.md"
expected_dest = "skills/execute-plan/reference/escalation-codes.md"

if expected_src not in srcs:
    problems.append("the manifest does not distribute %s" % expected_src)
else:
    print("  OK: the manifest distributes %s" % expected_src)
    if srcs[expected_src] != expected_dest:
        problems.append(
            "the manifest distributes %s as %s instead of %s"
            % (expected_src, srcs[expected_src], expected_dest)
        )
    else:
        print("  OK: the manifest distributes it as %s" % expected_dest)

# The relative references must resolve to a distributed path.
referrers = (
    "skills/review/SKILL.md",
    "skills/execute-plan/reference/review-template.md",
)
for referrer in referrers:
    path = os.path.join(root, referrer)
    if not os.path.isfile(path):
        problems.append("the referring file does not exist: %s" % referrer)
        continue
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    refs = re.findall(r"`([^`\s]*escalation-codes\.md)`", text)
    if not refs:
        problems.append("%s does not reference escalation-codes.md" % referrer)
        continue
    for ref in refs:
        if ref.startswith("shared/"):
            problems.append("%s references the checkout path %s" % (referrer, ref))
            continue
        resolved = os.path.normpath(os.path.join(os.path.dirname(referrer), ref))
        if resolved not in dests:
            problems.append(
                "%s references %s, which resolves to %s and is not a distributed path"
                % (referrer, ref, resolved)
            )
        else:
            print("  OK: %s resolves to the distributed path %s" % (referrer, resolved))

# Simulated clean installation: the manifest is applied into a fresh root and
# the references must resolve INSIDE it, without reaching the checkout.
for src, dest in srcs.items():
    source = os.path.join(root, src)
    target = os.path.join(install_root, dest)
    if not os.path.isfile(source):
        problems.append("the manifest points to a missing source: %s" % src)
        continue
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(source, target)

for referrer in referrers:
    installed = os.path.join(install_root, referrer)
    if not os.path.isfile(installed):
        problems.append("the simulated installation lacks %s" % referrer)
        continue
    with open(installed, encoding="utf-8") as handle:
        text = handle.read()
    for ref in re.findall(r"`([^`\s]*escalation-codes\.md)`", text):
        resolved = os.path.normpath(os.path.join(os.path.dirname(referrer), ref))
        target = os.path.join(install_root, resolved)
        if not os.path.isfile(target):
            problems.append(
                "in the simulated installation %s does not resolve: %s"
                % (referrer, resolved)
            )
        else:
            print("  OK: the simulated installation resolves %s" % resolved)

for problem in problems:
    print("  MISSING: %s" % problem)

sys.exit(1 if problems else 0)
PY
}

# ---------------------------------------------------------------------------
# Mutations on a throw-away copy of the sources.
# ---------------------------------------------------------------------------

make_mirror() {
  local dest="$1"
  mkdir -p "$dest/open-code/commands" \
    "$dest/skills/execute-plan/reference" \
    "$dest/skills/review" \
    "$dest/shared/components" \
    "$dest/shared/reference"
  cp -p "$FORGE_ROOT/open-code/commands/execute-plan.md" "$dest/open-code/commands/"
  cp -p "$FORGE_ROOT/open-code/commands/review.md" "$dest/open-code/commands/"
  cp -p "$FORGE_ROOT/skills/execute-plan/SKILL.md" "$dest/skills/execute-plan/"
  cp -p "$FORGE_ROOT"/skills/execute-plan/reference/*.md "$dest/skills/execute-plan/reference/"
  cp -p "$FORGE_ROOT/skills/review/SKILL.md" "$dest/skills/review/"
  cp -p "$FORGE_ROOT/shared/components/commands.json" "$dest/shared/components/"
  cp -p "$FORGE_ROOT/shared/reference/escalation-codes.md" "$dest/shared/reference/"
}

# expect_detected <label> <check-function> <mutation-command...>
# The mutation command must make the check fail; a passing check means the
# check is blind and the suite must say so.
expect_detected() {
  local label="$1" check="$2"
  shift 2
  local mirror="$WORKDIR/mirror-$label"
  rm -rf "$mirror"
  make_mirror "$mirror"
  if ! "$@"; then
    fail "detection: could not build the mutated copy for '$label'"
    return
  fi
  local output status=0
  output="$("$check" "$mirror" 2>&1)" || status=$?
  if [ "$status" -eq 0 ]; then
    fail "detection: the check does NOT detect the removal of '$label'"
    printf '%s\n' "$output" | sed 's/^/      /' >&2
  else
    pass "detection: the check detects the removal of '$label'"
  fi
}

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

echo "=== execute_plan_parity_unit.sh ==="

WORKDIR="$(mktemp -d "$TMPDIR_BASE/parity-$$-XXXXXX")"

test_helpers_are_present_in_both_variants() {
  if check_helpers_present "$FORGE_ROOT"; then
    pass "helpers: both variants expose set_frontmatter and flip_step"
  else
    fail "helpers: a variant does not expose both helpers"
  fi
}

test_infra_protocol_in_both_variants() {
  if check_infra_protocol "$FORGE_ROOT"; then
    pass "infra protocol: both variants carry the applier/tech failure protocol"
  else
    fail "infra protocol: a variant omits part of the applier/tech failure protocol"
  fi
}

test_batch_algorithm_in_both_variants() {
  if check_batch_algorithm "$FORGE_ROOT"; then
    pass "batch algorithm: both variants carry the bounded batching algorithm"
  else
    fail "batch algorithm: a variant omits part of the batching algorithm"
  fi
}

test_findings_literal_in_the_three_templates() {
  if check_findings_literal "$FORGE_ROOT"; then
    pass "findings: the three review templates carry the FINDINGS literal"
  else
    fail "findings: a review template does not carry the FINDINGS literal"
  fi
}

test_platform_identity_is_preserved() {
  if check_platform_identity "$FORGE_ROOT"; then
    pass "platform identity: each variant keeps its own tool and model"
  else
    fail "platform identity: a variant lost its own tool or model"
  fi

  # The check must NOT demand the identity of the other platform. The Claude
  # variant does not mention the OpenCode model and still passes its own
  # identity check.
  local claude="$FORGE_ROOT/skills/execute-plan/SKILL.md"
  if grep -q 'gpt-6.1-sol' "$claude"; then
    pass "platform identity: the claude variant does not need the OpenCode model"
  else
    pass "platform identity: the claude variant does not mention the OpenCode model (no cross-identity demand)"
  fi
  local opencode="$FORGE_ROOT/open-code/commands/execute-plan.md"
  if grep -q 'opus' "$opencode"; then
    pass "platform identity: the opencode variant does not need the Claude model"
  else
    pass "platform identity: the opencode variant does not mention the Claude model (no cross-identity demand)"
  fi
}

test_references_resolve_in_a_clean_installation() {
  if check_reference_distribution "$FORGE_ROOT"; then
    pass "references: escalation-codes.md is distributed and resolves in a clean installation"
  else
    fail "references: escalation-codes.md is not distributed or does not resolve"
  fi
}

test_detection_of_a_missing_helper() {
  expect_detected "opencode-set-frontmatter" \
    check_helpers_present \
    remove_helper_block "$WORKDIR/mirror-opencode-set-frontmatter/open-code/commands/execute-plan.md" \
      "set_frontmatter() {"
  expect_detected "claude-flip-step" \
    check_helpers_present \
    remove_helper_block "$WORKDIR/mirror-claude-flip-step/skills/execute-plan/SKILL.md" \
      "flip_step() {"
}

test_detection_of_a_missing_infra_protocol() {
  expect_detected "claude-infra-protocol" \
    check_infra_protocol \
    remove_lines_containing \
      "$WORKDIR/mirror-claude-infra-protocol/skills/execute-plan/reference/batch-algorithm.md" \
      "Fallo de infraestructura del subagente"
  expect_detected "opencode-infra-protocol" \
    check_infra_protocol \
    remove_lines_containing \
      "$WORKDIR/mirror-opencode-infra-protocol/open-code/commands/execute-plan.md" \
      "Fallo de infraestructura del subagente"
}

test_detection_of_a_missing_batch_algorithm() {
  expect_detected "claude-batch-cap" \
    check_batch_algorithm \
    replace_in_file \
      "$WORKDIR/mirror-claude-batch-cap/skills/execute-plan/reference/batch-algorithm.md" \
      "cap = 8 steps per batch" \
      "cap = 16 steps per batch"
  expect_detected "claude-batch-states" \
    check_batch_algorithm \
    replace_in_file \
      "$WORKDIR/mirror-claude-batch-states/skills/execute-plan/reference/batch-algorithm.md" \
      "BLOCKED_BATCH" \
      "BATCH_FAILED"
  expect_detected "opencode-batch-cap" \
    check_batch_algorithm \
    replace_in_file \
      "$WORKDIR/mirror-opencode-batch-cap/open-code/commands/execute-plan.md" \
      "cap = 8 steps per batch" \
      "cap = 16 steps per batch"
}

test_detection_of_a_missing_findings_literal() {
  expect_detected "review-command-findings" \
    check_findings_literal \
    replace_in_file \
      "$WORKDIR/mirror-review-command-findings/open-code/commands/review.md" \
      "FINDINGS: <c> critical, <m> major, <n> minor" \
      "FINDINGS: <c> crit, <m> maj, <n> min"
  expect_detected "review-template-findings" \
    check_findings_literal \
    replace_in_file \
      "$WORKDIR/mirror-review-template-findings/skills/execute-plan/reference/review-template.md" \
      "FINDINGS: <c> critical, <m> major, <n> minor" \
      "FINDINGS: <c> crit, <m> maj, <n> min"
  expect_detected "execute-plan-findings" \
    check_findings_literal \
    replace_in_file \
      "$WORKDIR/mirror-execute-plan-findings/open-code/commands/execute-plan.md" \
      "FINDINGS: <c> critical, <m> major, <n> minor" \
      "FINDINGS: <c> crit, <m> maj, <n> min"
}

test_detection_of_a_lost_platform_identity() {
  expect_detected "claude-opus-model" \
    check_platform_identity \
    replace_in_file \
      "$WORKDIR/mirror-claude-opus-model/skills/execute-plan/SKILL.md" \
      "opus" \
      "unknown-model"
  expect_detected "opencode-subagent-tool" \
    check_platform_identity \
    replace_in_file \
      "$WORKDIR/mirror-opencode-subagent-tool/open-code/commands/execute-plan.md" \
      "subagent" \
      "worker"
}

test_detection_of_an_undistributed_reference() {
  expect_detected "manifest-escalation-codes" \
    check_reference_distribution \
    remove_lines_containing \
      "$WORKDIR/mirror-manifest-escalation-codes/shared/components/commands.json" \
      "escalation-codes.md"
  expect_detected "checkout-path-reference" \
    check_reference_distribution \
    replace_in_file \
      "$WORKDIR/mirror-checkout-path-reference/skills/review/SKILL.md" \
      "../execute-plan/reference/escalation-codes.md" \
      "shared/reference/escalation-codes.md"
}

run_test test_helpers_are_present_in_both_variants
run_test test_infra_protocol_in_both_variants
run_test test_batch_algorithm_in_both_variants
run_test test_findings_literal_in_the_three_templates
run_test test_platform_identity_is_preserved
run_test test_references_resolve_in_a_clean_installation
run_test test_detection_of_a_missing_helper
run_test test_detection_of_a_missing_infra_protocol
run_test test_detection_of_a_missing_batch_algorithm
run_test test_detection_of_a_missing_findings_literal
run_test test_detection_of_a_lost_platform_identity
run_test test_detection_of_an_undistributed_reference

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
