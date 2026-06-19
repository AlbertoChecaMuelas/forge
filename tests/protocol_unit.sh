#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/protocol_unit.sh — Unit tests for agent protocol after ES→EN migration
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

cd "$(dirname "$0")/.."

ARSENAL_ROOT="$(pwd)"

# Test harness
FAIL=0
PASS=0
TMPDIR_BASE="$ARSENAL_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

# Pattern-based cleanup: the make_* helpers run inside command substitutions
# (subshells), so accumulating paths in a parent-shell variable never works
# (the list stays empty and nothing was removed — tests/.tmp grew unbounded).
# The mktemp template embeds $$ (parent PID even inside subshells), so this
# glob removes exactly this run's artifacts.
cleanup() {
  rm -rf "$TMPDIR_BASE"/protocol-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local f
  f="$(mktemp "$TMPDIR_BASE/protocol-$$-XXXX")"
  echo "$f"
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

run_test() {
  local name="$1"
  echo "--- $name"
  "$name"
}

# The awk command extracted from commands/mr-description.md (line 33).
# Contract: extracts bullets from ## Risks verified by reviewer section.
# shellcheck disable=SC2034  # AWK_CMD documents the contract; run_awk_on_file uses it inline
AWK_CMD='awk '"'"'/^## Risks verified by reviewer/{f=1;next} /^## /{f=0} f && /^- /{print}'"'"

run_awk_on_file() {
  local file="$1"
  awk '/^## Risks verified by reviewer/{f=1;next} /^## /{f=0} f && /^- /{print}' "$file"
}

# =============================================================================
# Group 1 — Awk extractor for ## Risks verified by reviewer
# =============================================================================

# T1: happy path — 2 bullets followed by another heading
test_awk_happy_path() {
  local tmp
  tmp="$(make_tmp)"
  printf '## General objective\n\nSome goal.\n\n## Risks verified by reviewer\n\n- risk one\n- risk two\n\n## Another section\n\nMore text.\n' > "$tmp"

  local output
  output="$(run_awk_on_file "$tmp")"

  if [ "$output" = "- risk one
- risk two" ]; then
    pass "awk_happy_path: emits exactly 2 bullets"
  else
    fail "awk_happy_path: expected 2 bullets, got: $(printf '%s' "$output" | head -5)"
  fi
}

# T2: section absent — awk must emit empty output
test_awk_section_absent() {
  local tmp
  tmp="$(make_tmp)"
  printf '## General objective\n\nSome goal.\n\n## Another section\n\nNo risks here.\n' > "$tmp"

  local output
  output="$(run_awk_on_file "$tmp")"

  if [ -z "$output" ]; then
    pass "awk_section_absent: output is empty"
  else
    fail "awk_section_absent: expected empty output, got: $output"
  fi
}

# T3: section at end of file — no subsequent heading, all bullets must be emitted
test_awk_section_at_eof() {
  local tmp
  tmp="$(make_tmp)"
  printf '## General objective\n\nSome goal.\n\n## Risks verified by reviewer\n\n- risk alpha\n- risk beta\n- risk gamma\n' > "$tmp"

  local output
  output="$(run_awk_on_file "$tmp")"

  if [ "$output" = "- risk alpha
- risk beta
- risk gamma" ]; then
    pass "awk_section_at_eof: emits all 3 bullets when section is last"
  else
    fail "awk_section_at_eof: expected 3 bullets, got: $(printf '%s' "$output" | head -5)"
  fi
}

# T4: section exists but has no bullets before next heading
test_awk_section_empty() {
  local tmp
  tmp="$(make_tmp)"
  printf '## General objective\n\nSome goal.\n\n## Risks verified by reviewer\n\n## Next section\n\nContent.\n' > "$tmp"

  local output
  output="$(run_awk_on_file "$tmp")"

  if [ -z "$output" ]; then
    pass "awk_section_empty: output is empty when section has no bullets"
  else
    fail "awk_section_empty: expected empty output, got: $output"
  fi
}

# =============================================================================
# Group 2 — EN tokens present in agent files
# =============================================================================

test_token_requires_plan_senior() {
  if grep -qF 'REQUIRES_PLAN:' "$ARSENAL_ROOT/agents/senior.md"; then
    pass "token_requires_plan_senior: REQUIRES_PLAN: found in agents/senior.md"
  else
    fail "token_requires_plan_senior: REQUIRES_PLAN: NOT found in agents/senior.md"
  fi
}

test_token_blocked_senior_senior() {
  if grep -qF 'BLOCKED_SENIOR:' "$ARSENAL_ROOT/agents/senior.md"; then
    pass "token_blocked_senior_senior: BLOCKED_SENIOR: found in agents/senior.md"
  else
    fail "token_blocked_senior_senior: BLOCKED_SENIOR: NOT found in agents/senior.md"
  fi
}

test_token_blocked_applier() {
  if grep -qF 'BLOCKED:' "$ARSENAL_ROOT/agents/applier.md"; then
    pass "token_blocked_applier: BLOCKED: found in agents/applier.md"
  else
    fail "token_blocked_applier: BLOCKED: NOT found in agents/applier.md"
  fi
}

test_token_verifier_failed_applier() {
  if grep -qF 'VERIFIER_FAILED:' "$ARSENAL_ROOT/agents/applier.md"; then
    pass "token_verifier_failed_applier: VERIFIER_FAILED: found in agents/applier.md"
  else
    fail "token_verifier_failed_applier: VERIFIER_FAILED: NOT found in agents/applier.md"
  fi
}

test_token_escalate_senior_tech() {
  if grep -qF 'ESCALATE_SENIOR:' "$ARSENAL_ROOT/agents/tech.md"; then
    pass "token_escalate_senior_tech: ESCALATE_SENIOR: found in agents/tech.md"
  else
    fail "token_escalate_senior_tech: ESCALATE_SENIOR: NOT found in agents/tech.md"
  fi
}

test_token_findings_phase_reviewer() {
  if grep -qF 'FINDINGS_PHASE:' "$ARSENAL_ROOT/skills/execute-plan/reference/review-template.md"; then
    pass "token_findings_phase_reviewer: FINDINGS_PHASE: found in review-template.md"
  else
    fail "token_findings_phase_reviewer: FINDINGS_PHASE: NOT found in review-template.md"
  fi
}

test_token_ok_phase_reviewer() {
  if grep -qF 'OK_PHASE:' "$ARSENAL_ROOT/skills/execute-plan/reference/review-template.md"; then
    pass "token_ok_phase_reviewer: OK_PHASE: found in review-template.md"
  else
    fail "token_ok_phase_reviewer: OK_PHASE: NOT found in review-template.md"
  fi
}

test_token_verified_reviewer() {
  if grep -qF 'VERIFIED:' "$ARSENAL_ROOT/skills/execute-plan/reference/review-template.md"; then
    pass "token_verified_reviewer: VERIFIED: found in review-template.md"
  else
    fail "token_verified_reviewer: VERIFIED: NOT found in review-template.md"
  fi
}

# Gap 1 — STAGED: token present in senior agent
test_token_staged_senior() {
  local file1="$ARSENAL_ROOT/agents/senior.md"
  if grep -qF 'STAGED:' "$file1"; then
    pass "token_staged_senior: STAGED: found in agents/senior.md"
  else
    fail "token_staged_senior: STAGED: NOT found in agents/senior.md"
  fi
}

# Gap 2 — disallowedTools excludes Bash, includes Write/Edit/NotebookEdit (agents/senior.md)
test_disallowed_tools_senior() {
  local f1="$ARSENAL_ROOT/agents/senior.md"

  # agents/senior.md — disallowedTools: [Write, Edit, NotebookEdit]
  local dt_line
  dt_line="$(grep 'disallowedTools:' "$f1")"
  if printf '%s' "$dt_line" | grep -qF 'Bash'; then
    fail "disallowed_tools_senior: agents/senior.md disallowedTools: must NOT contain Bash"
  else
    pass "disallowed_tools_senior: agents/senior.md disallowedTools: does not contain Bash"
  fi
  for tool in Write Edit NotebookEdit; do
    if printf '%s' "$dt_line" | grep -qF "$tool"; then
      pass "disallowed_tools_senior: agents/senior.md disallowedTools: contains $tool"
    else
      fail "disallowed_tools_senior: agents/senior.md disallowedTools: does NOT contain $tool"
    fi
  done
}

# Gap 3 — Allowlist rejection variant present in senior agent
test_token_blocked_senior_allowlist() {
  local f1="$ARSENAL_ROOT/agents/senior.md"
  if grep -qF 'BLOCKED_SENIOR: write outside' "$f1"; then
    pass "token_blocked_senior_allowlist: BLOCKED_SENIOR: write outside found in agents/senior.md"
  else
    fail "token_blocked_senior_allowlist: BLOCKED_SENIOR: write outside NOT found in agents/senior.md"
  fi
}

# =============================================================================
# Group 3 — Structural plan labels in command files
# =============================================================================

test_label_phase_create_plan() {
  if grep -qF '# PHASE' "$ARSENAL_ROOT/skills/create-plan/reference/plan-format.md"; then
    pass "label_phase_create_plan: '# PHASE' found in skills/create-plan/reference/plan-format.md"
  else
    fail "label_phase_create_plan: '# PHASE' NOT found in skills/create-plan/reference/plan-format.md"
  fi
}

test_label_step_create_plan() {
  if grep -qF '## Step' "$ARSENAL_ROOT/skills/create-plan/reference/plan-format.md"; then
    pass "label_step_create_plan: '## Step' found in skills/create-plan/reference/plan-format.md"
  else
    fail "label_step_create_plan: '## Step' NOT found in skills/create-plan/reference/plan-format.md"
  fi
}

test_label_checkpoint_phase_create_plan() {
  if grep -qF '### CHECKPOINT PHASE' "$ARSENAL_ROOT/skills/create-plan/reference/plan-format.md"; then
    pass "label_checkpoint_phase_create_plan: '### CHECKPOINT PHASE' found in skills/create-plan/reference/plan-format.md"
  else
    fail "label_checkpoint_phase_create_plan: '### CHECKPOINT PHASE' NOT found in skills/create-plan/reference/plan-format.md"
  fi
}

test_label_global_verifier_create_plan() {
  if grep -qF '# GLOBAL VERIFIER' "$ARSENAL_ROOT/skills/create-plan/reference/plan-format.md"; then
    pass "label_global_verifier_create_plan: '# GLOBAL VERIFIER' found in skills/create-plan/reference/plan-format.md"
  else
    fail "label_global_verifier_create_plan: '# GLOBAL VERIFIER' NOT found in skills/create-plan/reference/plan-format.md"
  fi
}

test_label_rollback_create_plan() {
  if grep -qF '# ROLLBACK' "$ARSENAL_ROOT/skills/create-plan/reference/plan-format.md"; then
    pass "label_rollback_create_plan: '# ROLLBACK' found in skills/create-plan/reference/plan-format.md"
  else
    fail "label_rollback_create_plan: '# ROLLBACK' NOT found in skills/create-plan/reference/plan-format.md"
  fi
}

test_label_risks_verified_execute_plan() {
  if grep -qF '## Risks verified by reviewer' "$ARSENAL_ROOT/skills/execute-plan/SKILL.md"; then
    pass "label_risks_verified_execute_plan: '## Risks verified by reviewer' found in skills/execute-plan/SKILL.md"
  else
    fail "label_risks_verified_execute_plan: '## Risks verified by reviewer' NOT found in skills/execute-plan/SKILL.md"
  fi
}

# Gap 5 — Blocking tokens present in SKILL.md
test_blocked_staging_tokens_in_skill() {
  local skill="$ARSENAL_ROOT/skills/create-plan/SKILL.md"
  if grep -qF 'BLOCKED: staging plan missing YAML front-matter' "$skill"; then
    pass "blocked_staging_tokens_in_skill: 'BLOCKED: staging plan missing YAML front-matter' found in create-plan/SKILL.md"
  else
    fail "blocked_staging_tokens_in_skill: 'BLOCKED: staging plan missing YAML front-matter' NOT found in create-plan/SKILL.md"
  fi
  if grep -qF 'BLOCKED: plan contains placeholders after senior retry' "$skill"; then
    pass "blocked_staging_tokens_in_skill: 'BLOCKED: plan contains placeholders after senior retry' found in create-plan/SKILL.md"
  else
    fail "blocked_staging_tokens_in_skill: 'BLOCKED: plan contains placeholders after senior retry' NOT found in create-plan/SKILL.md"
  fi
}

# Gap 6 — mkdir -p .plans/ appears before ### Step 1 in SKILL.md
test_mkdir_plans_before_step1_in_skill() {
  if awk '/mkdir -p \.plans\//{mk=NR} /^### Step 1 /{s1=NR; exit} END{exit !(mk && s1 && mk < s1)}' \
      "$ARSENAL_ROOT/skills/create-plan/SKILL.md"; then
    pass "mkdir_plans_before_step1_in_skill: 'mkdir -p .plans/' appears before '### Step 1' in create-plan/SKILL.md"
  else
    fail "mkdir_plans_before_step1_in_skill: 'mkdir -p .plans/' does NOT appear before '### Step 1' in create-plan/SKILL.md"
  fi
}

# =============================================================================
# Group 4 — Role boundary validation section present in all agents
# =============================================================================

AGENTS_ROLE_BOUNDARY="tech senior"

test_role_boundary_agents() {
  local agent
  for agent in $AGENTS_ROLE_BOUNDARY; do
    local file="$ARSENAL_ROOT/agents/${agent}.md"
    if grep -qF '## Role boundary' "$file"; then
      pass "role_boundary_agents/${agent}: '## Role boundary' found in agents/${agent}.md"
    else
      fail "role_boundary_agents/${agent}: '## Role boundary' NOT found in agents/${agent}.md"
    fi
  done
}



# =============================================================================
# Group 5 — plan-format spec drift guard
# The spec body lives in two distributed copies by design (preload skill for
# tech/applier + create-plan reference for senior). They must stay identical.
# =============================================================================

test_plan_format_copies_in_sync() {
  local skill_file="skills/plan-format/SKILL.md"
  local ref_file="skills/create-plan/reference/plan-format.md"
  # Strip the YAML frontmatter from the skill copy, then compare bodies.
  local skill_body
  skill_body="$(awk 'BEGIN{fm=0} {if (fm<2) {if ($0 ~ /^---[[:space:]]*$/) fm++; next} print}' "$skill_file")"
  if [ "$skill_body" = "$(cat "$ref_file")" ]; then
    pass "plan_format_sync: skill body identical to create-plan reference"
  else
    fail "plan_format_sync: skills/plan-format/SKILL.md body differs from skills/create-plan/reference/plan-format.md — edit both copies"
  fi
}

# =============================================================================
# Group 6 — STAGED line parse contract
# Pure shell fixture tests — no file reads, no model execution.
# Contract (from skills/create-plan/SKILL.md):
#   path = everything between "STAGED: " and first " — "
#   remaining fields: split on ", ", parse as key=value
# =============================================================================

_parse_staged_path() {
  # Extract path: between "STAGED: " and first " — "
  local line="$1"
  printf '%s' "${line#STAGED: }" | awk -F' — ' '{print $1}'
}

_parse_staged_field() {
  # Extract a named field (slug, phases, steps) from the key=value pairs after " — "
  local line="$1" field="$2"
  local remainder
  remainder="$(printf '%s' "${line#STAGED: }" | awk -F' — ' '{print $2}')"
  printf '%s' "$remainder" | tr ', ' '\n' | grep "^${field}=" | cut -d= -f2-
}

test_staged_line_parse_contract() {
  # --- Fixture 1: canonical example from SKILL.md ---
  local line1="STAGED: /repo/.plans/.staging-my-feature.md — slug=my-feature, phases=3, steps=12"
  local path1 slug1 phases1 steps1
  path1="$(_parse_staged_path "$line1")"
  slug1="$(_parse_staged_field "$line1" slug)"
  phases1="$(_parse_staged_field "$line1" phases)"
  steps1="$(_parse_staged_field "$line1" steps)"

  if [ "$path1" = "/repo/.plans/.staging-my-feature.md" ]; then
    pass "staged_line_parse_contract/fixture1: path extracted correctly"
  else
    fail "staged_line_parse_contract/fixture1: expected path=/repo/.plans/.staging-my-feature.md, got: $path1"
  fi
  if [ "$slug1" = "my-feature" ]; then
    pass "staged_line_parse_contract/fixture1: slug extracted correctly"
  else
    fail "staged_line_parse_contract/fixture1: expected slug=my-feature, got: $slug1"
  fi
  if [ "$phases1" = "3" ]; then
    pass "staged_line_parse_contract/fixture1: phases extracted correctly"
  else
    fail "staged_line_parse_contract/fixture1: expected phases=3, got: $phases1"
  fi
  if [ "$steps1" = "12" ]; then
    pass "staged_line_parse_contract/fixture1: steps extracted correctly"
  else
    fail "staged_line_parse_contract/fixture1: expected steps=12, got: $steps1"
  fi

  # --- Fixture 2: path with a space ---
  local line2="STAGED: /home/user name/.plans/.staging-foo.md — slug=foo, phases=1, steps=2"
  local path2
  path2="$(_parse_staged_path "$line2")"
  if [ "$path2" = "/home/user name/.plans/.staging-foo.md" ]; then
    pass "staged_line_parse_contract/fixture2: path with space extracted correctly"
  else
    fail "staged_line_parse_contract/fixture2: expected '/home/user name/.plans/.staging-foo.md', got: $path2"
  fi

  # --- Fixture 3: slug with multiple hyphens ---
  local line3="STAGED: /repo/.plans/.staging-add-oauth-api.md — slug=add-oauth-api, phases=2, steps=8"
  local slug3
  slug3="$(_parse_staged_field "$line3" slug)"
  if [ "$slug3" = "add-oauth-api" ]; then
    pass "staged_line_parse_contract/fixture3: multi-hyphen slug extracted correctly"
  else
    fail "staged_line_parse_contract/fixture3: expected slug=add-oauth-api, got: $slug3"
  fi
}

# =============================================================================
# Group 7 — re-review loop doctrine (fix/reviewer-re-review-loop)
# Tests that the new review_rounds counter, batch-fix flow, one-re-review cap,
# and last_review_sha..HEAD incremental range are present in the canonical files.
# =============================================================================

REVIEWER_REF="$ARSENAL_ROOT/skills/execute-plan/reference/reviewer-and-close.md"
EXECUTE_SKILL="$ARSENAL_ROOT/skills/execute-plan/SKILL.md"
ESCALATION_CODES="$ARSENAL_ROOT/shared/reference/escalation-codes.md"

# T7.1 — review_rounds front-matter field declared in SKILL.md Step 1
test_review_rounds_declared_in_skill_frontmatter() {
  if grep -qF 'review_rounds' "$EXECUTE_SKILL"; then
    pass "review_rounds_declared_in_skill_frontmatter: 'review_rounds' found in skills/execute-plan/SKILL.md"
  else
    fail "review_rounds_declared_in_skill_frontmatter: 'review_rounds' NOT found in skills/execute-plan/SKILL.md"
  fi
}

# T7.2 — review_rounds hard constraint present in SKILL.md (the Spanish cap line)
test_review_rounds_hard_constraint_in_skill() {
  if grep -qF 'review_rounds' "$EXECUTE_SKILL" && grep -qF 'UNA re-review' "$EXECUTE_SKILL"; then
    pass "review_rounds_hard_constraint_in_skill: 'UNA re-review' + 'review_rounds' hard constraint found in SKILL.md"
  else
    fail "review_rounds_hard_constraint_in_skill: hard constraint ('UNA re-review' + 'review_rounds') NOT found in SKILL.md"
  fi
}

# T7.3 — review_rounds counter behaviour documented in reviewer-and-close.md
test_review_rounds_in_reviewer_ref() {
  if grep -qF 'review_rounds' "$REVIEWER_REF"; then
    pass "review_rounds_in_reviewer_ref: 'review_rounds' found in reviewer-and-close.md"
  else
    fail "review_rounds_in_reviewer_ref: 'review_rounds' NOT found in reviewer-and-close.md"
  fi
}

# T7.4 — batch-fix: ALL impl findings in one delegation (not per-finding)
test_batch_fix_single_delegation_in_reviewer_ref() {
  if grep -qF 'single batch delegation to tech' "$REVIEWER_REF"; then
    pass "batch_fix_single_delegation_in_reviewer_ref: 'single batch delegation to tech' found in reviewer-and-close.md"
  else
    fail "batch_fix_single_delegation_in_reviewer_ref: 'single batch delegation to tech' NOT found in reviewer-and-close.md"
  fi
}

# T7.5 — batch-fix design: ALL design findings in one delegation to senior
test_batch_fix_design_delegation_in_reviewer_ref() {
  if grep -qF 'single batch delegation to senior' "$REVIEWER_REF"; then
    pass "batch_fix_design_delegation_in_reviewer_ref: 'single batch delegation to senior' found in reviewer-and-close.md"
  else
    fail "batch_fix_design_delegation_in_reviewer_ref: 'single batch delegation to senior' NOT found in reviewer-and-close.md"
  fi
}

# T7.6 — one-re-review cap: EXACTLY ONE re-review per checkpoint
test_one_rereview_cap_in_reviewer_ref() {
  if grep -qF 'EXACTLY ONE re-review' "$REVIEWER_REF"; then
    pass "one_rereview_cap_in_reviewer_ref: 'EXACTLY ONE re-review' found in reviewer-and-close.md"
  else
    fail "one_rereview_cap_in_reviewer_ref: 'EXACTLY ONE re-review' NOT found in reviewer-and-close.md"
  fi
}

# T7.7 — incremental re-review reads last_review_sha..HEAD
test_incremental_range_last_review_sha_in_reviewer_ref() {
  if grep -qF 'last_review_sha..HEAD' "$REVIEWER_REF"; then
    pass "incremental_range_last_review_sha_in_reviewer_ref: 'last_review_sha..HEAD' found in reviewer-and-close.md"
  else
    fail "incremental_range_last_review_sha_in_reviewer_ref: 'last_review_sha..HEAD' NOT found in reviewer-and-close.md"
  fi
}

# T7.8 — re-review uses Sonnet (not Opus) for the small incremental diff
test_rereview_uses_sonnet_in_reviewer_ref() {
  if grep -qF 'Sonnet' "$REVIEWER_REF"; then
    pass "rereview_uses_sonnet_in_reviewer_ref: 'Sonnet' found in reviewer-and-close.md"
  else
    fail "rereview_uses_sonnet_in_reviewer_ref: 'Sonnet' NOT found in reviewer-and-close.md"
  fi
}

# T7.9 — review_rounds reset to 0 on checkpoint close documented
test_review_rounds_reset_on_checkpoint_close_in_reviewer_ref() {
  if grep -qF 'reset `review_rounds` to 0' "$REVIEWER_REF"; then
    pass "review_rounds_reset_on_checkpoint_close: 'reset \`review_rounds\` to 0' found in reviewer-and-close.md"
  else
    fail "review_rounds_reset_on_checkpoint_close: 'reset \`review_rounds\` to 0' NOT found in reviewer-and-close.md"
  fi
}

# T7.10 — escalation-codes.md FINDINGS_PHASE row contains batch-fix doctrine
test_findings_phase_batch_fix_in_escalation_codes() {
  if grep -qF 'batch-fix' "$ESCALATION_CODES"; then
    pass "findings_phase_batch_fix_in_escalation_codes: 'batch-fix' found in shared/reference/escalation-codes.md"
  else
    fail "findings_phase_batch_fix_in_escalation_codes: 'batch-fix' NOT found in shared/reference/escalation-codes.md"
  fi
}

# T7.11 — escalation-codes.md FINDINGS_PHASE row documents incremental re-review + review_rounds gate
test_findings_phase_rereview_gate_in_escalation_codes() {
  if grep -qF 'review_rounds' "$ESCALATION_CODES"; then
    pass "findings_phase_rereview_gate_in_escalation_codes: 'review_rounds' found in shared/reference/escalation-codes.md"
  else
    fail "findings_phase_rereview_gate_in_escalation_codes: 'review_rounds' NOT found in shared/reference/escalation-codes.md"
  fi
}

# T7.12 — escalation-codes.md specifies last_review_sha..HEAD for the incremental re-review
test_findings_phase_last_review_sha_in_escalation_codes() {
  if grep -qF 'last_review_sha..HEAD' "$ESCALATION_CODES"; then
    pass "findings_phase_last_review_sha_in_escalation_codes: 'last_review_sha..HEAD' found in shared/reference/escalation-codes.md"
  else
    fail "findings_phase_last_review_sha_in_escalation_codes: 'last_review_sha..HEAD' NOT found in shared/reference/escalation-codes.md"
  fi
}

# =============================================================================
# Group 8 — escalation-codes emitter/file cross-check
# Data-driven: parse escalation-codes.md table, verify every (token, emitter)
# pair against the canonical file(s), and check orchestrator routing coverage.
# =============================================================================

# T8.1 — table has at least 18 data rows (one per escalation code)
test_escalation_codes_table_parseable() {
  local rows
  rows="$(awk -F'|' 'NF>2 && $2 ~ /`[A-Z_]+:/' "$ARSENAL_ROOT/shared/reference/escalation-codes.md" | wc -l | tr -d ' ')"
  if [ "$rows" -ge 18 ]; then
    pass "escalation_codes_table_parseable: found $rows rows (>= 18) in escalation-codes.md"
  else
    fail "escalation_codes_table_parseable: expected >= 18 rows, got $rows"
  fi
}

# T8.2 — every token appears in the canonical file(s) for each of its emitters
test_escalation_codes_emitter_crosscheck() {
  local codes_file="$ARSENAL_ROOT/shared/reference/escalation-codes.md"

  # Extract "token<TAB>emitter_csv" lines from the table.
  # Field 2 = code cell (backtick-wrapped, may have params), field 3 = emitter cell.
  local pairs
  pairs="$(awk -F'|' '
    /^\| \`[A-Z_]+:/ {
      token_cell = $2
      emitter_cell = $3
      # strip backticks and extract code prefix: uppercase letters and underscore followed by colon
      gsub(/`/, "", token_cell)
      n = split(token_cell, a, " ")
      tok = a[1]
      # keep only the [A-Z_]+: prefix
      sub(/<.*/, "", tok)
      gsub(/[^A-Z_:]/, "", tok)
      # trim emitter cell
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", emitter_cell)
      print tok "\t" emitter_cell
    }
  ' "$codes_file")"

  while IFS="	" read -r token emitter_csv; do
    # Split emitter_csv on comma; trim each; lowercase; normalize "review" → "reviewer"
    local IFS_SAVE="$IFS"
    IFS=','
    local emitters_arr
    read -ra emitters_arr <<< "$emitter_csv"
    IFS="$IFS_SAVE"

    local emitter
    for emitter in "${emitters_arr[@]}"; do
      # trim whitespace and lowercase
      emitter="$(printf '%s' "$emitter" | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
      # normalize "review" → "reviewer"
      [ "$emitter" = "review" ] && emitter="reviewer"

      # resolve file list for this emitter
      local files=()
      case "$emitter" in
        applier)
          files=("$ARSENAL_ROOT/agents/applier.md") ;;
        tech)
          files=("$ARSENAL_ROOT/agents/tech.md") ;;
        tester)
          files=("$ARSENAL_ROOT/agents/tester.md") ;;
        senior)
          files=("$ARSENAL_ROOT/agents/senior.md") ;;
        reviewer)
          files=("$ARSENAL_ROOT/skills/execute-plan/reference/review-template.md") ;;
        *)
          fail "escalation_codes_emitter_crosscheck: unknown emitter '$emitter' for token '$token'"
          continue ;;
      esac

      local f
      for f in "${files[@]}"; do
        if grep -qF -- "$token" "$f"; then
          pass "escalation_codes_emitter_crosscheck: '$token' found in ${f#$ARSENAL_ROOT/}"
        else
          fail "escalation_codes_emitter_crosscheck: '$token' NOT found in ${f#$ARSENAL_ROOT/}"
        fi
      done
    done
  done <<< "$pairs"
}

# T8.3 — every token prefix appears in shared/CLAUDE-orchestrator.md
test_escalation_codes_orchestrator_routing_coverage() {
  local codes_file="$ARSENAL_ROOT/shared/reference/escalation-codes.md"
  local orch_file="$ARSENAL_ROOT/shared/CLAUDE-orchestrator.md"

  local tokens
  tokens="$(awk -F'|' '
    /^\| \`[A-Z_]+:/ {
      token_cell = $2
      gsub(/`/, "", token_cell)
      n = split(token_cell, a, " ")
      tok = a[1]
      sub(/<.*/, "", tok)
      gsub(/[^A-Z_:]/, "", tok)
      print tok
    }
  ' "$codes_file" | sort -u)"

  local token
  while IFS= read -r token; do
    if grep -qF -- "$token" "$orch_file"; then
      pass "escalation_codes_orchestrator_routing_coverage: '$token' found in shared/CLAUDE-orchestrator.md"
    else
      fail "escalation_codes_orchestrator_routing_coverage: '$token' NOT found in shared/CLAUDE-orchestrator.md"
    fi
  done <<< "$tokens"
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== protocol_unit.sh ==="

echo ""
echo "-- Group 1: Awk extractor (mr-description.md)"
run_test test_awk_happy_path
run_test test_awk_section_absent
run_test test_awk_section_at_eof
run_test test_awk_section_empty

echo ""
echo "-- Group 2: EN tokens in agent files"
run_test test_token_requires_plan_senior
run_test test_token_blocked_senior_senior
run_test test_token_blocked_applier
run_test test_token_verifier_failed_applier
run_test test_token_escalate_senior_tech
run_test test_token_findings_phase_reviewer
run_test test_token_ok_phase_reviewer
run_test test_token_verified_reviewer
run_test test_token_staged_senior
run_test test_disallowed_tools_senior
run_test test_token_blocked_senior_allowlist

echo ""
echo "-- Group 3: Structural plan labels"
run_test test_label_phase_create_plan
run_test test_label_step_create_plan
run_test test_label_checkpoint_phase_create_plan
run_test test_label_global_verifier_create_plan
run_test test_label_rollback_create_plan
run_test test_label_risks_verified_execute_plan
run_test test_blocked_staging_tokens_in_skill
run_test test_mkdir_plans_before_step1_in_skill

echo ""
echo "-- Group 4: Role boundary validation section in all agents"
run_test test_role_boundary_agents

echo ""
echo "-- Group 5: plan-format spec drift guard"
run_test test_plan_format_copies_in_sync

echo ""
echo "-- Group 6: STAGED line parse contract"
run_test test_staged_line_parse_contract

echo ""
echo "-- Group 7: re-review loop doctrine (review_rounds, batch-fix, one-cap, incremental range)"
run_test test_review_rounds_declared_in_skill_frontmatter
run_test test_review_rounds_hard_constraint_in_skill
run_test test_review_rounds_in_reviewer_ref
run_test test_batch_fix_single_delegation_in_reviewer_ref
run_test test_batch_fix_design_delegation_in_reviewer_ref
run_test test_one_rereview_cap_in_reviewer_ref
run_test test_incremental_range_last_review_sha_in_reviewer_ref
run_test test_rereview_uses_sonnet_in_reviewer_ref
run_test test_review_rounds_reset_on_checkpoint_close_in_reviewer_ref
run_test test_findings_phase_batch_fix_in_escalation_codes
run_test test_findings_phase_rereview_gate_in_escalation_codes
run_test test_findings_phase_last_review_sha_in_escalation_codes

echo ""
echo "-- Group 8: escalation-codes emitter/file cross-check"
run_test test_escalation_codes_table_parseable
run_test test_escalation_codes_emitter_crosscheck
run_test test_escalation_codes_orchestrator_routing_coverage

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
