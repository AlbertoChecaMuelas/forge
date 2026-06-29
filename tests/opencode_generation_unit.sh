#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"
GENERATOR="$FORGE_ROOT/shared/scripts/generate-agents.sh"
FAIL=0
PASS=0

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

test_generate_opencode_agents() {
  local exit_code=0
  bash "$GENERATOR" --target=opencode >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "generate-agents.sh --target=opencode exits 0"
  else
    fail "generate-agents.sh --target=opencode exits $exit_code"
  fi
}

test_generated_files_exist() {
  local role
  for role in applier senior tech tester orchestrator; do
    if [ -f "$FORGE_ROOT/open-code/agents/${role}.md" ]; then
      pass "open-code/agents/${role}.md exists"
    else
      fail "open-code/agents/${role}.md missing"
    fi
  done
}

test_source_frontmatter_has_no_model_lines() {
  if grep -R '^model:' "$FORGE_ROOT/shared/scripts/opencode-frontmatter" >/dev/null 2>&1; then
    fail "opencode frontmatter source files still contain model:"
  else
    pass "opencode frontmatter source files do not contain model:"
  fi
}

test_generated_files_have_single_model_line() {
  local role count
  for role in applier senior tech tester orchestrator; do
    count=$(grep -c '^model:' "$FORGE_ROOT/open-code/agents/${role}.md")
    if [ "$count" -eq 1 ]; then
      pass "open-code/agents/${role}.md contains exactly one model: line"
    else
      fail "open-code/agents/${role}.md contains $count model: lines"
    fi
  done
}

test_generated_files_have_no_litellm() {
  if grep -R 'litellm/' "$FORGE_ROOT/open-code/agents" >/dev/null 2>&1; then
    fail "generated OpenCode agents still contain litellm/"
  else
    pass "generated OpenCode agents do not contain litellm/"
  fi
}

test_generated_modes() {
  if grep -q '^mode: primary$' "$FORGE_ROOT/open-code/agents/orchestrator.md"; then
    pass "orchestrator is mode: primary"
  else
    fail "orchestrator is not mode: primary"
  fi

  local role
  for role in applier senior tech tester; do
    if grep -q '^mode: subagent$' "$FORGE_ROOT/open-code/agents/${role}.md"; then
      pass "${role} is mode: subagent"
    else
      fail "${role} is not mode: subagent"
    fi
  done
}

test_generated_agents_are_platform_correct() {
  if grep -R 'Task tool\|/review\|/create-plan\|AskUserQuestion\|NotebookEdit\|Edit/Write' "$FORGE_ROOT/open-code/agents" >/dev/null 2>&1; then
    fail "generated OpenCode agents still contain Claude-only workflow/tool references"
  else
    pass "generated OpenCode agents do not contain Claude-only workflow/tool references"
  fi
}

test_generated_models_match_expected_mapping() {
  local expected_applier='model: minimax/MiniMax-M2.5-highspeed'
  local expected_worker='model: minimax/MiniMax-M3[1m]'
  local expected_senior='model: minimax/MiniMax-M3[1m]'

  if grep -qxF "${expected_applier}" "$FORGE_ROOT/open-code/agents/applier.md"; then
    pass "applier model matches MiniMax M2.5-highspeed mapping"
  else
    fail "applier model does not match MiniMax M2.5-highspeed mapping"
  fi

  local role
  for role in tech tester orchestrator; do
    if grep -qxF "${expected_worker}" "$FORGE_ROOT/open-code/agents/${role}.md"; then
      pass "${role} model matches MiniMax M3 mapping"
    else
      fail "${role} model does not match MiniMax M3 mapping"
    fi
  done

  if grep -qxF "${expected_senior}" "$FORGE_ROOT/open-code/agents/senior.md"; then
    pass "senior model matches MiniMax M3 mapping"
  else
    fail "senior model does not match MiniMax M3 mapping"
  fi
}

test_check_mode_and_drift_detection() {
  local exit_code=0
  local mutated_file="$FORGE_ROOT/open-code/agents/tech.md"
  local backup_file

  bash "$GENERATOR" --target=opencode --check >/dev/null 2>&1 || exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    pass "--target=opencode --check exits 0 after fresh generate"
  else
    fail "--target=opencode --check exits $exit_code after fresh generate"
  fi

  backup_file=$(mktemp)
  cp "$mutated_file" "$backup_file"
  printf '\n# drift\n' >> "$mutated_file"

  exit_code=0
  bash "$GENERATOR" --target=opencode --check >/dev/null 2>&1 || exit_code=$?
  mv "$backup_file" "$mutated_file"

  if [ "$exit_code" -ne 0 ]; then
    pass "--target=opencode --check detects drift"
  else
    fail "--target=opencode --check did not detect drift"
  fi
}

echo "================================"
echo " opencode_generation_unit.sh"
echo "================================"

test_generate_opencode_agents
test_generated_files_exist
test_source_frontmatter_has_no_model_lines
test_generated_files_have_single_model_line
test_generated_files_have_no_litellm
test_generated_modes
test_generated_agents_are_platform_correct
test_generated_models_match_expected_mapping
test_check_mode_and_drift_detection

echo ""
echo "================================"
echo " Passed: $PASS"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
