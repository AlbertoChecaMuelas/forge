#!/usr/bin/env bash
# tests/prompts/helpers.sh — Headless agent invocation for prompt behaviour tests.
# Loads agents straight from agents/*.md in this repo: tests work WITHOUT
# forge installed in ~/.claude (isolation via --setting-sources "").
# Compatible with bash 3.2+. Same harness style as tests/rtk_unit.sh.
#
# Exposes:
#   run_agent <agent-file> <prompt> [model]   -> prints the agent's final text
#   assert_contains <haystack> <needle> <msg>
#   assert_not_contains <haystack> <needle> <msg>
#   run_test <name> <function> / prompt_tests_summary
#
# Cost note: every run_agent call hits a real model. Default model is haiku to
# keep assertions cheap when the behaviour under test is model-independent;
# override per call (3rd arg) or via RUN_AGENT_MODEL.

set -euo pipefail

PROMPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_ROOT="$(cd "$PROMPTS_DIR/../.." && pwd)"
export FORGE_ROOT

FAIL=0
TESTS_RUN=0
TESTS_PASSED=0

# Temporary directories cleaned up on exit
TMPDIR_LIST=""
trap '_cleanup_all' EXIT

_cleanup_all() {
  for d in $TMPDIR_LIST; do
    rm -rf "$d" 2>/dev/null || true
  done
}

_make_tmpdir() {
  local d
  d="$(mktemp -d)"
  TMPDIR_LIST="$TMPDIR_LIST $d"
  echo "$d"
}

# ---------------------------------------------------------------------------
# Agent file parsing (YAML frontmatter between the first two '---' lines)
# ---------------------------------------------------------------------------

# _agent_body <agent-file> — prints the markdown body (everything after the
# closing '---' of the frontmatter). Files that do not START with a '---'
# line have no frontmatter: the whole file is the body (e.g. the review
# template, which contains a lone '---' separator mid-document).
_agent_body() {
  awk '
    NR == 1 && $0 !~ /^---[[:space:]]*$/ { nofm = 1 }
    nofm { print; next }
    {
      if (fm < 2) {
        if ($0 ~ /^---[[:space:]]*$/) fm++
        next
      }
      print
    }
  ' "$1"
}

# _agent_field <agent-file> <key> — prints the scalar value of a top-level
# frontmatter key (e.g. tools, model, name). Empty if absent.
_agent_field() {
  awk -v key="$2" '
    NR > 1 && /^---[[:space:]]*$/ { exit }
    $0 ~ "^" key ":" {
      sub("^" key ":[[:space:]]*", "")
      print
      exit
    }
  ' "$1"
}

# ---------------------------------------------------------------------------
# run_agent <agent-file> <prompt> [model]
#
# Invokes `claude -p` with:
#   --system-prompt        agent body (replaces the default system prompt,
#                          same role it has as a subagent system prompt)
#   --tools/--allowedTools derived from the agent frontmatter `tools:` line
#   --setting-sources ""   no user/project/local settings (repo-only run)
#   --settings             minimal isolated settings (fixtures/)
# Note: --strict-mcp-config is NOT used — it conflicts with enterprise
# (managed) MCP configs, which are present on corporate machines.
# Prints the agent's final text on stdout. Returns claude's exit code.
# ---------------------------------------------------------------------------
run_agent() {
  local agent_file="$1"
  local prompt="$2"
  local model="${3:-${RUN_AGENT_MODEL:-haiku}}"

  if [ ! -f "$agent_file" ]; then
    echo "run_agent: agent file not found: $agent_file" >&2
    return 2
  fi

  local body tools
  body="$(_agent_body "$agent_file")"
  tools="$(_agent_field "$agent_file" tools)"
  [ -n "$tools" ] || tools="Bash, Read, Edit, Write, Glob, Grep"
  tools="$(printf '%s' "$tools" | tr -d ' ')"

  claude -p "$prompt" \
    --system-prompt "$body" \
    --model "$model" \
    --setting-sources "" \
    --settings "$PROMPTS_DIR/fixtures/minimal-settings.json" \
    --no-session-persistence \
    --disable-slash-commands \
    --tools "$tools" \
    --allowedTools "$tools" \
    2>/dev/null
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# assert_contains <haystack> <needle> <message>
assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    return 0
  fi
  echo "  FAIL: $msg" >&2
  echo "    expected to contain: '$needle'" >&2
  echo "    output (truncated): '$(printf '%.500s' "$haystack")'" >&2
  FAIL=1
  return 1
}

# assert_not_contains <haystack> <needle> <message>
assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "  FAIL: $msg" >&2
    echo "    expected NOT to contain: '$needle'" >&2
    echo "    output (truncated): '$(printf '%.500s' "$haystack")'" >&2
    FAIL=1
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Test harness (same contract as tests/rtk_unit.sh)
# ---------------------------------------------------------------------------

# run_test <name> <function>
run_test() {
  local name="$1"
  local fn="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  local before_fail=$FAIL
  printf '  %-60s' "$name"
  if "$fn"; then
    if [ "$FAIL" = "$before_fail" ]; then
      TESTS_PASSED=$((TESTS_PASSED + 1))
      echo "OK"
    else
      echo "FAIL"
    fi
  else
    FAIL=1
    echo "FAIL (exception)"
  fi
}

# prompt_tests_summary — print results and exit accordingly
prompt_tests_summary() {
  echo ""
  echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
  if [ "$FAIL" -ne 0 ]; then
    echo "FAIL"
    exit 1
  else
    echo "ALL PASS"
    exit 0
  fi
}
