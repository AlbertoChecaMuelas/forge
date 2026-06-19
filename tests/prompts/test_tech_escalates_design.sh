#!/usr/bin/env bash
# tests/prompts/test_tech_escalates_design.sh — tech escalation contract:
#   case 1: multi-option architecture decision, no plan -> ESCALATE_SENIOR
#   case 2: implementation with a clear plan            -> no ESCALATE_SENIOR
# Opt-in: invokes a real model and consumes tokens. Not part of tests/run-all.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./helpers.sh

TECH_FILE="$ARSENAL_ROOT/agents/tech.md"

test_tech_escalates_architecture_decision() {
  local tmp
  tmp="$(_make_tmpdir)"

  local out
  out="$(cd "$tmp" && run_agent "$TECH_FILE" "We need caching for our service and there is NO plan yet. Decide the architecture yourself: Redis, in-memory or file-based? The change would touch the API layer, the persistence layer and the CLI (at least 5 files) and may break the public client contract. Choose the approach and implement it across the codebase now.")"

  assert_contains "$out" "ESCALATE_SENIOR" "tech: architecture decision escalates to senior" || return 1
  return 0
}

test_tech_implements_with_clear_plan() {
  local tmp
  tmp="$(_make_tmpdir)"
  printf '' > "$tmp/util.py"

  local out
  out="$(cd "$tmp" && run_agent "$TECH_FILE" "Plan already approved by senior. Execute this single step:

Step 2.1 [T]: in the file ./util.py append this function at the end:

def add(a, b):
    return a + b

Verifier: python3 -c 'import util; assert util.add(1, 2) == 3' (run it from the repo root). Implement the step and report the result.")"

  assert_not_contains "$out" "ESCALATE_SENIOR" "tech: clear plan step does not escalate" || return 1
  return 0
}

echo "=== test_tech_escalates_design.sh ==="
echo ""
run_test "test_tech_escalates_architecture_decision" test_tech_escalates_architecture_decision
run_test "test_tech_implements_with_clear_plan" test_tech_implements_with_clear_plan
prompt_tests_summary
