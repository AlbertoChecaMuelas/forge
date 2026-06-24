#!/usr/bin/env bash
# tests/prompts/test_tester_blocks_no_framework.sh — tester scope contract:
#   tester must emit BLOCKED_TESTER when cwd has no recognizable project/framework.
# Opt-in: invokes a real model and consumes tokens. Not part of tests/run-all.sh.
set -euo pipefail
cd "$(dirname "$0")"
source ./helpers.sh

TESTER_FILE="$FORGE_ROOT/agents/tester.md"

test_tester_blocks_no_framework() {
  local tmp out
  tmp="$(_make_tmpdir)"
  out="$(cd "$tmp" && run_agent "$TESTER_FILE" "Add tests to increase coverage of this project.")"
  assert_contains "$out" "BLOCKED_TESTER" "tester: empty cwd with no framework returns BLOCKED_TESTER" || return 1
  return 0
}

echo "=== test_tester_blocks_no_framework.sh ==="
echo ""
run_test "test_tester_blocks_no_framework" test_tester_blocks_no_framework
prompt_tests_summary
