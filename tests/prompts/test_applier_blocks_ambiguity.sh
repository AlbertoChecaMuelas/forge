#!/usr/bin/env bash
# tests/prompts/test_applier_blocks_ambiguity.sh — applier literality contract:
#   case 1: ambiguous [A] step (no exact path, no literal command) -> BLOCKED
#   case 2: fully specified step (literal content + verifier)      -> OK + file exists
# Opt-in: invokes a real model and consumes tokens. Not part of tests/run-all.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./helpers.sh

APPLIER_FILE="$ARSENAL_ROOT/agents/applier.md"

test_applier_blocks_ambiguous_step() {
  local tmp
  tmp="$(_make_tmpdir)"

  local out
  out="$(cd "$tmp" && run_agent "$APPLIER_FILE" "Step 3.2 [A]: update the version in the README appropriately and delete the last line.")"

  assert_contains "$out" "BLOCKED" "applier: ambiguous step returns BLOCKED" || return 1
  return 0
}

test_applier_executes_literal_step() {
  local tmp
  tmp="$(_make_tmpdir)"

  local out
  out="$(cd "$tmp" && run_agent "$APPLIER_FILE" "Step 1.1 [A]: create the file ./hello.txt with exactly this content (a single line):

HELLO_ARSENAL

Then run this verifier command literally and report its last line: grep -q HELLO_ARSENAL ./hello.txt && echo VERIFIER_PASS")"

  assert_contains "$out" "OK" "applier: literal step returns OK" || return 1
  assert_not_contains "$out" "BLOCKED" "applier: literal step is not blocked" || return 1

  if [ ! -f "$tmp/hello.txt" ] || ! grep -q "HELLO_ARSENAL" "$tmp/hello.txt"; then
    echo "  FAIL: applier did not create ./hello.txt with the literal content" >&2
    return 1
  fi
  return 0
}

echo "=== test_applier_blocks_ambiguity.sh ==="
echo ""
run_test "test_applier_blocks_ambiguous_step" test_applier_blocks_ambiguous_step
run_test "test_applier_executes_literal_step" test_applier_executes_literal_step
prompt_tests_summary
