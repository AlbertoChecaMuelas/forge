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
  # /create-plan, /execute-plan and /review are legitimate cross-platform
  # commands: OpenCode has its own
  # open-code/commands/{create-plan,execute-plan,review}.md, wired via
  # install-opencode.sh/uninstall-opencode.sh COMMANDS_DIR, so they are
  # intentionally excluded from this Claude-only sentinel list.
  if grep -R 'Task tool\|AskUserQuestion\|NotebookEdit\|Edit/Write' "$FORGE_ROOT/open-code/agents" >/dev/null 2>&1; then
    fail "generated OpenCode agents still contain Claude-only workflow/tool references"
  else
    pass "generated OpenCode agents do not contain Claude-only workflow/tool references"
  fi
}

test_opencode_commands_exist() {
  local cmd
  for cmd in create-plan execute-plan review create-pr pr-description update-changelog; do
    if [ -f "$FORGE_ROOT/open-code/commands/${cmd}.md" ]; then
      pass "open-code/commands/${cmd}.md exists"
    else
      fail "open-code/commands/${cmd}.md missing"
    fi
  done
}

test_opencode_permission_block_flips() {
  local applier_file="$FORGE_ROOT/open-code/agents/applier.md"
  local orchestrator_file="$FORGE_ROOT/open-code/agents/orchestrator.md"

  if grep -qE '^\s*grep:\s*allow$' "$applier_file"; then
    pass "open-code/agents/applier.md permission block has grep: allow"
  else
    fail "open-code/agents/applier.md permission block missing grep: allow"
  fi

  if grep -qE '^\s*webfetch:\s*deny$' "$orchestrator_file"; then
    pass "open-code/agents/orchestrator.md permission block has webfetch: deny"
  else
    fail "open-code/agents/orchestrator.md permission block missing webfetch: deny"
  fi
}

test_opencode_escalation_codes_present() {
  local orchestrator_file="$FORGE_ROOT/open-code/agents/orchestrator.md"
  local token
  for token in 'OK_BATCH:' 'BLOCKED_BATCH:' 'BLOCKED_TECH:' 'TESTING_PLAN:' 'BLOCKED_TESTER:' 'BLOCKED_REVIEW:'; do
    if grep -qF "$token" "$orchestrator_file"; then
      pass "open-code/agents/orchestrator.md references escalation code ${token}"
    else
      fail "open-code/agents/orchestrator.md missing escalation code ${token}"
    fi
  done
}

test_generated_models_match_expected_mapping() {
  local expected_applier='model: minimax-coding-plan/MiniMax-M3.1-Flash'
  local expected_worker='model: minimax-coding-plan/MiniMax-M3.1-Flash'
  local expected_tech='model: openai/gpt-6-luna'
  local expected_senior='model: openai/gpt-6.1-sol'

  if grep -qxF "${expected_applier}" "$FORGE_ROOT/open-code/agents/applier.md"; then
    pass "applier model matches MiniMax M3.1 Flash mapping"
  else
    fail "applier model does not match MiniMax M3.1 Flash mapping"
  fi

  local role
  for role in tester orchestrator; do
    if grep -qxF "${expected_worker}" "$FORGE_ROOT/open-code/agents/${role}.md"; then
      pass "${role} model matches MiniMax M3.1 Flash mapping"
    else
      fail "${role} model does not match MiniMax M3.1 Flash mapping"
    fi
  done

  if grep -qxF "${expected_tech}" "$FORGE_ROOT/open-code/agents/tech.md"; then
    pass "tech model matches openai/gpt-6-luna mapping"
  else
    fail "tech model does not match openai/gpt-6-luna mapping"
  fi

  if grep -qxF "${expected_senior}" "$FORGE_ROOT/open-code/agents/senior.md"; then
    pass "senior model matches GPT-6.1 Sol mapping"
  else
    fail "senior model does not match GPT-6.1 Sol mapping"
  fi
}

test_no_custom_minimax_provider_block() {
  local jsonc="$FORGE_ROOT/open-code/opencode.jsonc"

  if grep -qF '"minimax":' "$jsonc"; then
    fail "opencode.jsonc still contains custom \"minimax\": provider key"
  else
    pass "opencode.jsonc does not contain custom \"minimax\": provider key"
  fi

  if grep -qF 'api.minimax.io' "$jsonc"; then
    fail "opencode.jsonc still contains custom minimax baseURL api.minimax.io"
  else
    pass "opencode.jsonc does not contain custom minimax baseURL api.minimax.io"
  fi

  if grep -qF '@ai-sdk/openai-compatible' "$jsonc"; then
    fail "opencode.jsonc still contains @ai-sdk/openai-compatible npm provider"
  else
    pass "opencode.jsonc does not contain @ai-sdk/openai-compatible npm provider"
  fi
}

test_root_level_models_use_minimax_coding_plan() {
  local jsonc="$FORGE_ROOT/open-code/opencode.jsonc"

  if grep -qxF '  "model": "minimax-coding-plan/MiniMax-M3.1-Flash",' "$jsonc"; then
    pass "opencode.jsonc root model uses minimax-coding-plan/MiniMax-M3.1-Flash"
  else
    fail "opencode.jsonc root model does not use minimax-coding-plan/MiniMax-M3.1-Flash"
  fi

  if grep -qxF '  "small_model": "minimax-coding-plan/MiniMax-M3.1-Flash",' "$jsonc"; then
    pass "opencode.jsonc root small_model uses minimax-coding-plan/MiniMax-M3.1-Flash"
  else
    fail "opencode.jsonc root small_model does not use minimax-coding-plan/MiniMax-M3.1-Flash"
  fi
}

test_no_deprecated_minimax_model_ids() {
  # The active id is MiniMax-M3.1-Flash. The "-Preview" build is deprecated and
  # must not survive in the model mapping, the OpenCode config or the
  # generated agents.
  local active_model='MiniMax-M3.1-Flash'
  local deprecated_model="${active_model}-Preview"
  local target

  for target in "$FORGE_ROOT/shared/models.yaml" \
                "$FORGE_ROOT/open-code/opencode.jsonc" \
                "$FORGE_ROOT/open-code/agents"; do
    if [ ! -e "$target" ]; then
      fail "cannot check deprecated model id ${deprecated_model}: ${target#"$FORGE_ROOT"/} missing"
    elif grep -rqF "$deprecated_model" "$target"; then
      fail "deprecated model id ${deprecated_model} still present in ${target#"$FORGE_ROOT"/}"
    else
      pass "no deprecated model id ${deprecated_model} in ${target#"$FORGE_ROOT"/}"
    fi
  done
}

test_openai_provider_models_have_expected_efforts() {
  local jsonc="$FORGE_ROOT/open-code/opencode.jsonc"

  # Both gpt-6.1-sol and gpt-6-luna must be declared under provider.openai.models
  # with their expected reasoningEffort values (senior/tech, respectively).
  # The jsonc is pretty-printed, so reasoningEffort sits ~2 lines below the model id.
  if grep -q '"gpt-6.1-sol":' "$jsonc" \
     && grep -A 3 '"gpt-6.1-sol":' "$jsonc" | grep -qF '"reasoningEffort": "high"'; then
    pass "opencode.jsonc declares gpt-6.1-sol with reasoningEffort=high"
  else
    fail "opencode.jsonc missing gpt-6.1-sol with reasoningEffort=high"
  fi

  if grep -q '"gpt-6-luna":' "$jsonc" \
     && grep -A 3 '"gpt-6-luna":' "$jsonc" | grep -qF '"reasoningEffort": "xhigh"'; then
    pass "opencode.jsonc declares gpt-6-luna with reasoningEffort=xhigh"
  else
    fail "opencode.jsonc missing gpt-6-luna with reasoningEffort=xhigh"
  fi

  # Stale gpt-5.6-sol entry must be gone (it was replaced by gpt-6.1-sol).
  if grep -qF '"gpt-5.6-sol":' "$jsonc"; then
    fail "opencode.jsonc still declares stale gpt-5.6-sol provider model"
  else
    pass "opencode.jsonc no longer declares stale gpt-5.6-sol provider model"
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
test_opencode_commands_exist
test_opencode_permission_block_flips
test_opencode_escalation_codes_present
test_generated_models_match_expected_mapping
test_no_custom_minimax_provider_block
test_root_level_models_use_minimax_coding_plan
test_no_deprecated_minimax_model_ids
test_openai_provider_models_have_expected_efforts
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
