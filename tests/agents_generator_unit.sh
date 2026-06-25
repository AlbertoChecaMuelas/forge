#!/usr/bin/env bash
# tests/agents_generator_unit.sh — Unit tests for generate-agents.sh
# Covers Claude target generation; OpenCode has its own dedicated unit test.
# Compatible with bash 3.2+.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"
GENERATOR="$FORGE_ROOT/shared/scripts/generate-agents.sh"

# Test harness
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

# =============================================================================
# Helper: run generator --check for a given target; echoes output, returns exit code
# =============================================================================

run_check() {
  local target="$1"
  local output exit_code=0
  output=$(bash "$GENERATOR" "--target=$target" --check 2>&1) || exit_code=$?
  echo "$output"
  return $exit_code
}

# =============================================================================
# Group 1: generator script exists
# =============================================================================

test_generator_exists() {
  if [ -f "$GENERATOR" ]; then
    pass "generate-agents.sh is present"
  else
    fail "generate-agents.sh not found: $GENERATOR"
  fi
}

# =============================================================================
# Group 2: no drift (check mode) — claude only
# =============================================================================

test_claude_no_drift() {
  local output exit_code=0
  output=$(run_check "claude" 2>&1) || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "generate-agents.sh --target=claude --check exits 0 (no drift)"
  else
    fail "generate-agents.sh --target=claude --check exits $exit_code (drift detected)"
    echo "$output"
  fi
}

# =============================================================================
# Group 3: idempotency — running generate twice leaves no diff
# =============================================================================

test_claude_idempotency() {
  local exit_code=0
  bash "$GENERATOR" --target=claude > /dev/null 2>&1
  bash "$GENERATOR" --target=claude > /dev/null 2>&1
  run_check "claude" > /dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "generate-agents.sh --target=claude is idempotent (two runs produce no diff)"
  else
    fail "generate-agents.sh --target=claude is not idempotent (diff after two runs)"
  fi
}

# =============================================================================
# Group 4: --check detects mutation — claude only
# =============================================================================

test_claude_check_detects_mutation() {
  local frontmatter_dir="$FORGE_ROOT/shared/scripts/claude-frontmatter"
  local role="applier"
  local fm_file="$frontmatter_dir/${role}.yaml"

  # Back up the frontmatter file
  local backup
  backup=$(cat "$fm_file")

  # Mutate
  printf '%s\n# mutation\n' "$backup" > "$fm_file"

  local exit_code=0
  run_check "claude" > /dev/null 2>&1 || exit_code=$?

  # Restore
  printf '%s\n' "$backup" > "$fm_file"

  if [ "$exit_code" -ne 0 ]; then
    pass "--target=claude --check detects mutation in claude-frontmatter/${role}.yaml (exit $exit_code)"
  else
    fail "--target=claude --check did NOT detect mutation in claude-frontmatter/${role}.yaml (expected non-zero)"
  fi
}

# =============================================================================
# Group 5: frontmatter well-formed — generated agents/<role>.md
# =============================================================================

test_claude_frontmatter_well_formed() {
  local agents_dir="$FORGE_ROOT/agents"
  local roles="applier tech senior tester"

  for role in $roles; do
    local f="$agents_dir/${role}.md"

    if [ ! -f "$f" ]; then
      fail "agents/${role}.md not found"
      continue
    fi

    # Must start with ---
    local first_line
    first_line=$(head -1 "$f")
    if [ "$first_line" != "---" ]; then
      fail "agents/${role}.md does not start with '---' (got: '$first_line')"
      continue
    fi

    # Must contain name: field
    if ! grep -q "^name:" "$f"; then
      fail "agents/${role}.md missing 'name:' field"
      continue
    fi

    # Must contain model: field
    if ! grep -q "^model:" "$f"; then
      fail "agents/${role}.md missing 'model:' field"
      continue
    fi

    pass "agents/${role}.md is well-formed (starts with ---, has name: and model:)"
  done
}

# =============================================================================
# Group 6: disallowedTools and skills fields in generated agents/<role>.md
# =============================================================================

test_claude_frontmatter_disallowed_and_skills() {
  local agents_dir="$FORGE_ROOT/agents"

  # senior must have disallowedTools: [Write, Edit, NotebookEdit]
  local role="senior"
  local f="$agents_dir/${role}.md"
  if [ ! -f "$f" ]; then
    fail "agents/${role}.md not found"
  elif grep -qF "disallowedTools: [Write, Edit, NotebookEdit]" "$f"; then
    pass "agents/${role}.md has disallowedTools: [Write, Edit, NotebookEdit]"
  else
    fail "agents/${role}.md missing disallowedTools: [Write, Edit, NotebookEdit]"
  fi

  # tech and applier must have skills: [plan-format]
  for role in tech applier; do
    local f="$agents_dir/${role}.md"
    if [ ! -f "$f" ]; then
      fail "agents/${role}.md not found"
      continue
    fi
    if grep -qF "skills: [plan-format]" "$f"; then
      pass "agents/${role}.md has skills: [plan-format]"
    else
      fail "agents/${role}.md missing skills: [plan-format]"
    fi
  done

  # tester must NOT have disallowedTools or skills fields
  local tester_f="$agents_dir/tester.md"
  if [ -f "$tester_f" ]; then
    if grep -qF "disallowedTools:" "$tester_f"; then
      fail "agents/tester.md should NOT have disallowedTools field"
    else
      pass "agents/tester.md does NOT have disallowedTools field"
    fi
    if grep -qF "skills:" "$tester_f"; then
      fail "agents/tester.md should NOT have skills field"
    else
      pass "agents/tester.md does NOT have skills field"
    fi
  fi
}

# =============================================================================
# Group 7: plan-format skill front-matter structure
# =============================================================================

test_plan_format_skill_frontmatter() {
  local skill_file="$FORGE_ROOT/skills/plan-format/SKILL.md"

  if [ ! -f "$skill_file" ]; then
    fail "skills/plan-format/SKILL.md not found"
    return
  fi
  pass "skills/plan-format/SKILL.md exists"

  if grep -qF "name: plan-format" "$skill_file"; then
    pass "skills/plan-format/SKILL.md contains 'name: plan-format'"
  else
    fail "skills/plan-format/SKILL.md missing 'name: plan-format'"
  fi

  if grep -qF "disable-model-invocation: true" "$skill_file"; then
    pass "skills/plan-format/SKILL.md contains 'disable-model-invocation: true'"
  else
    fail "skills/plan-format/SKILL.md missing 'disable-model-invocation: true'"
  fi

  # Front-matter must open and close with --- within the first 10 lines
  local first_line
  first_line=$(head -1 "$skill_file")
  if [ "$first_line" = "---" ]; then
    pass "skills/plan-format/SKILL.md opens with '---'"
  else
    fail "skills/plan-format/SKILL.md does not open with '---' (got: '$first_line')"
  fi

  # Check that a closing --- appears within the first 10 lines (lines 2-10)
  local closing_line
  closing_line=$(head -10 "$skill_file" | tail -n +2 | grep -n "^---$" | head -1 | cut -d: -f1)
  if [ -n "$closing_line" ]; then
    pass "skills/plan-format/SKILL.md front-matter closes with '---' within first 10 lines"
  else
    fail "skills/plan-format/SKILL.md front-matter closing '---' not found in lines 2-10"
  fi
}

# =============================================================================
# Group 8: tester body does NOT contain stack-specific commands and DOES
#          contain the dispatch block heading
# =============================================================================

test_tester_body_no_stack_specific_commands() {
  local agents_dir="$FORGE_ROOT/agents"

  # Sentinel strings that must NOT appear in tester output.
  # One sentinel per stack is enough to detect a regression that embeds
  # framework-specific content back into the tester body instead of keeping
  # it in the dedicated skill files.
  local banned_strings=("mvn clean verify" "ChromeHeadlessCI" "pytest-cov")

  local tester_file="$agents_dir/tester.md"
  local target_label="agents/tester.md"

  if [ ! -f "$tester_file" ]; then
    fail "$target_label not found"
    return
  fi

  for sentinel in "${banned_strings[@]}"; do
    if grep -qF "$sentinel" "$tester_file"; then
      fail "$target_label contains banned string '$sentinel' (stack-specific content must live in skill files)"
    else
      pass "$target_label does NOT contain banned string '$sentinel'"
    fi
  done

  # The dispatch heading must be present — it is the on-demand loading mechanism.
  if grep -qF "Framework test-command cookbook (loaded on-demand)" "$tester_file"; then
    pass "$target_label contains dispatch block heading 'Framework test-command cookbook (loaded on-demand)'"
  else
    fail "$target_label missing dispatch block heading 'Framework test-command cookbook (loaded on-demand)'"
  fi
}

# =============================================================================
# Group 9: tester body <-> skills — three-way invariant
#   For every Skill(testing-X) reference in tester.body.md:
#     1. skills/testing-X/SKILL.md must exist on disk.
#     2. skills/testing-X/SKILL.md must appear in commands.json symlinks[].src.
# =============================================================================

test_tester_skills_three_way_invariant() {
  local tester_body="$FORGE_ROOT/shared/agents/tester.body.md"
  local commands_json="$FORGE_ROOT/shared/components/commands.json"

  if [ ! -f "$tester_body" ]; then
    fail "shared/agents/tester.body.md not found — cannot verify skill invariant"
    return
  fi

  if [ ! -f "$commands_json" ]; then
    fail "shared/components/commands.json not found — cannot verify skill invariant"
    return
  fi

  # Extract unique skill names from Skill(testing-<name>) occurrences.
  local skill_names
  skill_names=$(grep -oE "Skill\(testing-[a-z-]+\)" "$tester_body" \
    | sed 's/Skill(testing-//;s/)//' \
    | sort -u)

  if [ -z "$skill_names" ]; then
    fail "No Skill(testing-*) references found in tester.body.md — expected at least one"
    return
  fi

  for skill in $skill_names; do
    local skill_path="skills/testing-${skill}/SKILL.md"
    local full_path="$FORGE_ROOT/$skill_path"

    # Check 1: file exists on disk
    if [ -f "$full_path" ]; then
      pass "Skill(testing-$skill): $skill_path exists on disk"
    else
      fail "Skill(testing-$skill): $skill_path NOT found on disk"
    fi

    # Check 2: path appears in commands.json symlinks[].src
    if grep -qF "\"$skill_path\"" "$commands_json"; then
      pass "Skill(testing-$skill): $skill_path is registered in commands.json symlinks"
    else
      fail "Skill(testing-$skill): $skill_path NOT found in commands.json symlinks"
    fi
  done
}

# =============================================================================
# Group 10: tools propagation — every tool declared in claude-frontmatter YAML
#           must appear in the generated agents/<role>.md frontmatter tools: line
# =============================================================================

test_claude_tools_propagation() {
  local frontmatter_dir="$FORGE_ROOT/shared/scripts/claude-frontmatter"
  local agents_dir="$FORGE_ROOT/agents"

  for yaml_file in "$frontmatter_dir"/*.yaml; do
    local role
    role=$(basename "$yaml_file" .yaml)
    local agent_file="$agents_dir/${role}.md"

    local yaml_tools_line
    yaml_tools_line=$(grep "^tools:" "$yaml_file" || true)

    if [ -z "$yaml_tools_line" ]; then
      pass "claude-frontmatter/${role}.yaml has no tools: field — skip propagation check"
      continue
    fi

    local tools_value
    tools_value="${yaml_tools_line#tools: }"

    if [ ! -f "$agent_file" ]; then
      fail "agents/${role}.md not found — cannot verify tools propagation"
      continue
    fi

    local md_tools_line
    md_tools_line=$(grep "^tools:" "$agent_file" || true)

    if [ -z "$md_tools_line" ]; then
      fail "agents/${role}.md missing tools: line — propagation failed"
      continue
    fi

    local old_ifs="$IFS"
    IFS=','
    for token in $tools_value; do
      token="${token# }"
      token="${token% }"
      if [ -z "$token" ]; then
        continue
      fi
      if echo "$md_tools_line" | grep -qF "$token"; then
        pass "agents/${role}.md tools: contains '$token' (from claude-frontmatter/${role}.yaml)"
      else
        fail "agents/${role}.md tools: MISSING '$token' (declared in claude-frontmatter/${role}.yaml)"
      fi
    done
    IFS="$old_ifs"
  done
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== agents_generator_unit.sh ==="

echo ""
echo "-- Group 1: generator script exists"
test_generator_exists

echo ""
echo "-- Group 2: no drift (check mode)"
test_claude_no_drift

echo ""
echo "-- Group 3: idempotency"
test_claude_idempotency

echo ""
echo "-- Group 4: check detects mutation"
test_claude_check_detects_mutation

echo ""
echo "-- Group 5: claude frontmatter well-formed"
test_claude_frontmatter_well_formed

echo ""
echo "-- Group 6: disallowedTools and skills fields"
test_claude_frontmatter_disallowed_and_skills

echo ""
echo "-- Group 7: plan-format skill front-matter structure"
test_plan_format_skill_frontmatter

echo ""
echo "-- Group 8: tester body — no stack-specific commands, dispatch heading present"
test_tester_body_no_stack_specific_commands

echo ""
echo "-- Group 9: tester body <-> skills — three-way invariant (disk + commands.json)"
test_tester_skills_three_way_invariant

echo ""
echo "-- Group 10: tools propagation — claude-frontmatter -> agents/<role>.md"
test_claude_tools_propagation

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
