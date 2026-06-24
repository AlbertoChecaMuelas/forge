#!/usr/bin/env bash
# tests/prompts/test_senior_requires_plan.sh — senior scope-gate contract:
#   senior must emit REQUIRES_PLAN on a multi-file + breaking change with no plan.
# Opt-in: invokes a real model and consumes tokens. Not part of tests/run-all.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./helpers.sh

SENIOR_FILE="$FORGE_ROOT/agents/senior.md"

test_senior_emits_requires_plan() {
  local tmp out
  tmp="$(_make_tmpdir)"
  out="$(cd "$tmp" && run_agent "$SENIOR_FILE" "We need to add OAuth2 login. It touches the auth module, the API gateway, the DB schema and the frontend client (6+ files) and changes the public token format. No plan exists. Analyze and decide the approach.")"
  assert_contains "$out" "REQUIRES_PLAN" "senior: multi-file scope trigger returns REQUIRES_PLAN" || return 1
  return 0
}

echo "=== test_senior_requires_plan.sh ==="
echo ""
run_test "test_senior_emits_requires_plan" test_senior_emits_requires_plan
prompt_tests_summary
