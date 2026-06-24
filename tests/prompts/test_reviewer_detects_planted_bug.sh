#!/usr/bin/env bash
# tests/prompts/test_reviewer_detects_planted_bug.sh — a planted SQL injection
# + cleartext password must produce FINDINGS naming the offending file.
# Opt-in: invokes a real model and consumes tokens. Not part of tests/run-all.sh.
#
# REVIEWER_PROMPT_FILE parametrizes the review prompt source (default:
# the review template). If the file contains {BASE_SHA}/{HEAD_SHA}/{PLAN_STEP}/
# {SCOPE} placeholders (review template), they are filled before invocation,
# so the same test works against skills/execute-plan/reference/review-template.md.
set -euo pipefail
cd "$(dirname "$0")"
source ./helpers.sh

REVIEWER_PROMPT_FILE="${REVIEWER_PROMPT_FILE:-$FORGE_ROOT/skills/execute-plan/reference/review-template.md}"

test_reviewer_detects_planted_bug() {
  local repo
  repo="$(_make_tmpdir)"

  (
    cd "$repo"
    git init -q
    git config user.email "prompt-test@example.com"
    git config user.name "Prompt Test"
    cat > app.py <<'PY'
def get_user(conn, username):
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM users WHERE name = %s", (username,))
    return cursor.fetchone()
PY
    git add app.py
    git commit -qm "base: parameterized user lookup"
    cat > app.py <<'PY'
DB_PASSWORD = "SuperSecret123!"

def get_user(conn, username):
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM users WHERE name = '" + username + "'")
    return cursor.fetchone()
PY
    git add app.py
    git commit -qm "feat: simplify user lookup"
  )

  local base_sha head_sha
  base_sha="$(cd "$repo" && git rev-parse HEAD~1)"
  head_sha="$(cd "$repo" && git rev-parse HEAD)"

  # Fill template placeholders if the prompt source uses them (Phase 6).
  # In template mode the filled template IS the full prompt (real dispatch uses
  # model opus; sonnet keeps the test representative at lower cost — override
  # with REVIEWER_TEST_MODEL).
  local prompt_file="$REVIEWER_PROMPT_FILE"
  local user_prompt="Review the change introduced by the last commit of this repository: audit the range $base_sha..$head_sha (use git diff $base_sha..$head_sha). Produce your structured verdict with the final return code on the last line."
  local model="${REVIEWER_TEST_MODEL:-haiku}"
  if grep -q "{BASE_SHA}" "$prompt_file" 2>/dev/null; then
    local filled
    filled="$(_make_tmpdir)/review-prompt.md"
    sed -e "s/{BASE_SHA}/$base_sha/g" \
        -e "s/{HEAD_SHA}/$head_sha/g" \
        -e "s/{PLAN_STEP}/ad-hoc audit (prompt test)/g" \
        -e "s|{SCOPE}|full diff of the range|g" \
        "$prompt_file" > "$filled"
    prompt_file="$filled"
    user_prompt="Begin the audit now, following your instructions exactly."
    model="${REVIEWER_TEST_MODEL:-sonnet}"
  fi

  local out
  out="$(cd "$repo" && run_agent "$prompt_file" "$user_prompt" "$model")"

  assert_contains "$out" "FINDINGS" "reviewer: verdict contains FINDINGS" || return 1
  assert_contains "$out" "app.py" "reviewer: findings mention app.py" || return 1

  local last_line
  last_line="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
  case "$last_line" in
    OK:*)
      echo "  FAIL: reviewer returned OK on a planted bug: $last_line" >&2
      return 1
      ;;
  esac
  return 0
}

echo "=== test_reviewer_detects_planted_bug.sh ==="
echo ""
run_test "test_reviewer_detects_planted_bug" test_reviewer_detects_planted_bug
prompt_tests_summary
