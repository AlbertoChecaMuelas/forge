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

# ---------------------------------------------------------------------------
# Frontmatter report (test oracle).
#
# The generated OpenCode agents follow the OpenCode 2 contract: no `name`
# key, no V1 `permission` map, and a `permissions` RULESET: an ordered list of
# {action, resource, effect} mappings where the LAST matching rule wins.
#
# The parser is intentionally dependency-free (no PyYAML): the frontmatter is
# machine generated with a fixed shape, so a line based reader is enough and
# the suite keeps running on a bare python3.
# ---------------------------------------------------------------------------
agent_frontmatter_report() {
  python3 - "$FORGE_ROOT/open-code/agents" <<'PY'
import json
import os
import sys

AGENTS_DIR = sys.argv[1]
ROLES = ["applier", "senior", "tech", "tester", "orchestrator"]


def parse_frontmatter(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().splitlines()

    if not lines or lines[0].strip() != "---":
        return None

    end = None
    for index in range(1, len(lines)):
        if lines[index].strip() == "---":
            end = index
            break
    if end is None:
        return None

    data = {}
    rules = []
    current = None
    in_rules = False

    for line in lines[1:end]:
        if not line.strip() or line.lstrip().startswith("#"):
            continue

        if not line.startswith(" "):
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip()
            in_rules = False
            current = None
            if key == "permissions":
                in_rules = True
                data[key] = rules
            else:
                data[key] = value
            continue

        if not in_rules:
            continue

        entry = line.strip()
        if entry.startswith("- "):
            current = {}
            rules.append(current)
            entry = entry[2:].strip()
        if current is None or ":" not in entry:
            continue
        rule_key, _, rule_value = entry.partition(":")
        current[rule_key.strip()] = rule_value.strip().strip('"')

    return data


report = {}
for role in ROLES:
    path = os.path.join(AGENTS_DIR, role + ".md")
    frontmatter = parse_frontmatter(path)
    if frontmatter is None:
        report[role] = {"error": "the frontmatter could not be parsed"}
        continue

    rules = frontmatter.get("permissions")
    report[role] = {
        "model": frontmatter.get("model", ""),
        "mode": frontmatter.get("mode", ""),
        "keys": sorted(frontmatter.keys()),
        "has_name": "name" in frontmatter,
        "has_permission_v1": "permission" in frontmatter,
        "permissions_is_ruleset": isinstance(rules, list),
        "rules": rules if isinstance(rules, list) else [],
        "rule_keys": sorted({key for rule in (rules or []) for key in rule}),
        "actions": [rule.get("action", "") for rule in (rules or [])],
        "v1_actions": [
            rule.get("action", "")
            for rule in (rules or [])
            if rule.get("action", "") in ("bash", "task")
        ],
    }

print(json.dumps(report, sort_keys=True))
PY
}

# jsonc_read <file>
# Prints a JSONC file as plain JSON on stdout. The reader is string aware
# (a "//" inside a string is not a comment) and drops the trailing commas.
jsonc_read() {
  python3 - "$1" <<'PY'
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()

out = []
index = 0
length = len(text)
in_string = False

while index < length:
    char = text[index]

    if in_string:
        out.append(char)
        if char == "\\" and index + 1 < length:
            out.append(text[index + 1])
            index += 2
            continue
        if char == '"':
            in_string = False
        index += 1
        continue

    if char == '"':
        in_string = True
        out.append(char)
        index += 1
        continue

    if text.startswith("//", index):
        newline = text.find("\n", index)
        if newline == -1:
            break
        index = newline
        continue

    if text.startswith("/*", index):
        end = text.find("*/", index + 2)
        if end == -1:
            raise SystemExit("unterminated block comment")
        index = end + 2
        continue

    if char in "}]":
        previous = len(out) - 1
        while previous >= 0 and out[previous] in " \t\r\n":
            previous -= 1
        if previous >= 0 and out[previous] == ",":
            del out[previous]

    out.append(char)
    index += 1

sys.stdout.write("".join(out))
PY
}

# rule_index <report> <role> <action> <resource>
# Index of the rule that matches an action/resource pair (-1 when absent).
rule_index() {
  local report="$1" role="$2" action="$3" resource="$4"

  printf '%s' "$report" | python3 -c '
import json
import sys

report = json.loads(sys.stdin.read())
rules = report.get(sys.argv[1], {}).get("rules", [])
action = sys.argv[2]
resource = sys.argv[3]
index = -1
for position, rule in enumerate(rules):
    if rule.get("action") == action and rule.get("resource") == resource:
        index = position
print(index)
' "$role" "$action" "$resource"
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
  # OpenCode 2 replaced the V1 `permission` map with the `permissions`
  # ruleset: an ORDERED list of {action, resource, effect} rules where the
  # LAST matching rule wins.
  local report
  report="$(agent_frontmatter_report)" || {
    fail "could not parse the generated frontmatter"
    return
  }

  local role
  for role in applier senior tech tester orchestrator; do
    if printf '%s' "$report" | jq -e --arg role "$role" \
      '.[$role].permissions_is_ruleset' >/dev/null; then
      pass "open-code/agents/${role}.md declares an ordered permissions ruleset"
    else
      fail "open-code/agents/${role}.md does not declare a permissions ruleset"
    fi

    if printf '%s' "$report" | jq -e --arg role "$role" \
      '.[$role].has_permission_v1 | not' >/dev/null; then
      pass "open-code/agents/${role}.md does not use the V1 permission map"
    else
      fail "open-code/agents/${role}.md still uses the V1 permission map"
    fi

    if printf '%s' "$report" | jq -e --arg role "$role" \
      '.[$role].has_name | not' >/dev/null; then
      pass "open-code/agents/${role}.md has no name key (OpenCode 2 contract)"
    else
      fail "open-code/agents/${role}.md still declares a name key"
    fi

    if printf '%s' "$report" | jq -e --arg role "$role" \
      '.[$role].rule_keys == ["action","effect","resource"]' >/dev/null; then
      pass "open-code/agents/${role}.md rules only use action/resource/effect"
    else
      fail "open-code/agents/${role}.md rules use unexpected keys: $(printf '%s' "$report" | jq -c --arg role "$role" '.[$role].rule_keys')"
    fi

    if printf '%s' "$report" | jq -e --arg role "$role" \
      '.[$role].v1_actions | length == 0' >/dev/null; then
      pass "open-code/agents/${role}.md uses no V1 tool name (bash/task)"
    else
      fail "open-code/agents/${role}.md still uses a V1 tool name: $(printf '%s' "$report" | jq -c --arg role "$role" '.[$role].v1_actions')"
    fi
  done

  # The broad `shell: *` allow must come FIRST so the specific asks win.
  local orchestrator_broad orchestrator_push orchestrator_rm
  orchestrator_broad="$(rule_index "$report" orchestrator shell '*')"
  orchestrator_push="$(rule_index "$report" orchestrator shell 'git push*')"
  orchestrator_rm="$(rule_index "$report" orchestrator shell 'rm -rf*')"

  if [ "$orchestrator_broad" -ge 0 ] \
    && [ "$orchestrator_push" -gt "$orchestrator_broad" ] \
    && [ "$orchestrator_rm" -gt "$orchestrator_broad" ]; then
    pass "orchestrator declares the specific shell asks AFTER the broad allow (last match wins)"
  else
    fail "orchestrator does not order the specific shell asks after the broad allow (broad=$orchestrator_broad push=$orchestrator_push rm=$orchestrator_rm)"
  fi

  # Effect of the concrete rules.
  local effect
  effect="$(printf '%s' "$report" | jq -r '.orchestrator.rules[] | select(.action == "shell" and .resource == "git push*") | .effect')"
  if [ "$effect" = "ask" ]; then
    pass "orchestrator asks before running 'git push*'"
  else
    fail "orchestrator does not ask before running 'git push*' (effect=$effect)"
  fi

  effect="$(printf '%s' "$report" | jq -r '.orchestrator.rules[] | select(.action == "shell" and .resource == "rm -rf*") | .effect')"
  if [ "$effect" = "ask" ]; then
    pass "orchestrator asks before running 'rm -rf*'"
  else
    fail "orchestrator does not ask before running 'rm -rf*' (effect=$effect)"
  fi

  for role in applier senior tech tester orchestrator; do
    effect="$(printf '%s' "$report" | jq -r --arg role "$role" '.[$role].rules[] | select(.action == "grep" and .resource == "*") | .effect')"
    if [ "$effect" = "allow" ]; then
      pass "open-code/agents/${role}.md allows grep"
    else
      fail "open-code/agents/${role}.md does not allow grep (effect=$effect)"
    fi
  done

  for role in applier tech tester orchestrator; do
    effect="$(printf '%s' "$report" | jq -r --arg role "$role" '.[$role].rules[] | select(.action == "webfetch" and .resource == "*") | .effect')"
    if [ "$effect" = "deny" ]; then
      pass "open-code/agents/${role}.md denies webfetch"
    else
      fail "open-code/agents/${role}.md does not deny webfetch (effect=$effect)"
    fi
  done

  effect="$(printf '%s' "$report" | jq -r '.senior.rules[] | select(.action == "webfetch" and .resource == "*") | .effect')"
  if [ "$effect" = "allow" ]; then
    pass "open-code/agents/senior.md allows webfetch"
  else
    fail "open-code/agents/senior.md does not allow webfetch (effect=$effect)"
  fi

  # The OpenCode 2 tool names: `shell` for the terminal, `subagent` for the
  # delegation. The orchestrator is the only role that delegates.
  if printf '%s' "$report" | jq -e '.orchestrator.actions | index("subagent")' >/dev/null; then
    pass "orchestrator delegates through the OpenCode 2 subagent action"
  else
    fail "orchestrator does not use the OpenCode 2 subagent action"
  fi

  if printf '%s' "$report" | jq -e '.orchestrator.actions | index("shell")' >/dev/null; then
    pass "orchestrator uses the OpenCode 2 shell action"
  else
    fail "orchestrator does not use the OpenCode 2 shell action"
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
  # OpenCode 2 expresses the reasoning effort as a model VARIANT:
  # `provider/model#variant`. The variant must be one of the variants
  # declared for that model in the openai provider block of the config.
  local expected_applier='model: minimax-coding-plan/MiniMax-M3.1-Flash'
  local expected_worker='model: minimax-coding-plan/MiniMax-M3.1-Flash'
  local expected_tech='model: openai/gpt-6-luna#xhigh'
  local expected_senior='model: openai/gpt-6.1-sol#high'

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
    pass "tech model matches openai/gpt-6-luna#xhigh mapping"
  else
    fail "tech model does not match openai/gpt-6-luna#xhigh mapping"
  fi

  if grep -qxF "${expected_senior}" "$FORGE_ROOT/open-code/agents/senior.md"; then
    pass "senior model matches openai/gpt-6.1-sol#high mapping"
  else
    fail "senior model does not match openai/gpt-6.1-sol#high mapping"
  fi
}

test_generated_model_variants_are_declared_in_the_config() {
  # Every `provider/model#variant` used by an agent must be declared in the
  # providers block of opencode.jsonc: an undeclared variant is ignored by
  # OpenCode and the agent silently runs with another effort.
  local jsonc="$FORGE_ROOT/open-code/opencode.jsonc"

  local role model variant declared
  for role in tech senior; do
    model="$(grep '^model: ' "$FORGE_ROOT/open-code/agents/${role}.md" | head -n 1 | sed 's/^model: //')"
    variant="${model##*#}"

    if [ "$model" = "$variant" ]; then
      fail "${role} does not declare a model variant (model=$model)"
      continue
    fi

    declared="$(jsonc_read "$jsonc" | python3 -c '
import json
import sys

config = json.loads(sys.stdin.read())
model = sys.argv[1]
variant = sys.argv[2]
provider, _, name = model.partition("/")
name = name.split("#")[0]
models = (config.get("providers", {}).get(provider, {}) or {}).get("models", {}) or {}
variants = models.get(name, {}).get("variants", []) or []
print("yes" if any(item.get("id") == variant for item in variants) else "no")
' "$model" "$variant")"

    if [ "$declared" = "yes" ]; then
      pass "${role} model variant ${variant} is declared for ${model}"
    else
      fail "${role} model variant ${variant} is NOT declared for ${model}"
    fi
  done
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

  # OpenCode 2 removed `small_model`: the fallback model is the root `model`
  # and the per agent effort is a declared variant of the provider models.
  if grep -qE '"small_model"' "$jsonc"; then
    fail "opencode.jsonc still declares the V1 small_model key"
  else
    pass "opencode.jsonc does not declare the V1 small_model key"
  fi

  if grep -qE '"(autoupdate|plugin|permission)"[[:space:]]*:' "$jsonc"; then
    fail "opencode.jsonc still declares a V1 key (autoupdate/plugin/permission)"
  else
    pass "opencode.jsonc does not declare any V1 key (autoupdate/plugin/permission)"
  fi

  if grep -qE '"plugins"[[:space:]]*:' "$jsonc" \
    && grep -qE '"providers"[[:space:]]*:' "$jsonc" \
    && grep -qE '"mcp"[[:space:]]*:' "$jsonc" \
    && grep -qE '"servers"[[:space:]]*:' "$jsonc"; then
    pass "opencode.jsonc declares the OpenCode 2 keys (plugins/providers/mcp.servers)"
  else
    fail "opencode.jsonc does not declare the OpenCode 2 keys (plugins/providers/mcp.servers)"
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

  # OpenCode 2 declares the reasoning effort as a VARIANT of the model:
  # every model declares a `variants` list whose entries carry the id and
  # the settings. Both models used by Forge must expose the variant its
  # agent asks for.
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

  if grep -q '"gpt-6-luna":' "$jsonc" \
     && grep -A 3 '"gpt-6-luna":' "$jsonc" | grep -qF '"id": "xhigh"'; then
    pass "opencode.jsonc declares the xhigh variant of gpt-6-luna"
  else
    fail "opencode.jsonc does not declare the xhigh variant of gpt-6-luna"
  fi

  if grep -q '"gpt-6.1-sol":' "$jsonc" \
     && grep -A 3 '"gpt-6.1-sol":' "$jsonc" | grep -qF '"id": "high"'; then
    pass "opencode.jsonc declares the high variant of gpt-6.1-sol"
  else
    fail "opencode.jsonc does not declare the high variant of gpt-6.1-sol"
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
test_generated_model_variants_are_declared_in_the_config
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
