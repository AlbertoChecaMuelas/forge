#!/usr/bin/env bash
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

FAIL=0
PASS_COUNT=0
TMP_TEST_HOME=""
TEST_TMP_ROOT="/tmp/opencode/opencode-install-integration.$$"

pass() { echo "  PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=1; }

cleanup() {
  if [ -n "${TMP_TEST_HOME:-}" ]; then
    rm -rf "$TMP_TEST_HOME"
  fi
  if [ -n "${TEST_TMP_ROOT:-}" ]; then
    rm -rf "$TEST_TMP_ROOT"
  fi
}

mkdir -p "$TEST_TMP_ROOT"
trap cleanup EXIT

# The production installer gives OPENCODE_CONFIG_DIR / OPENCODE_CONFIG
# precedence over HOME. Always remove both so an inherited real-user config can
# never be read or modified by this suite.
run_isolated() {
  local isolated_home="$1"
  shift
  mkdir -p "$isolated_home/.config" "$isolated_home/.cache" \
    "$isolated_home/.local/share" "$isolated_home/.local/state"
  env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
    HOME="$isolated_home" \
    XDG_CONFIG_HOME="$isolated_home/.config" \
    XDG_CACHE_HOME="$isolated_home/.cache" \
    XDG_DATA_HOME="$isolated_home/.local/share" \
    XDG_STATE_HOME="$isolated_home/.local/state" \
    "$@"
}

# Copy the production overlay into a disposable repository. The installer
# regenerates agents, so running it against the checkout would modify tracked
# files outside /tmp.
create_repo_fixture() {
  local destination="$1"
  local item

  mkdir -p "$destination"
  cp "$FORGE_ROOT/install.sh" "$destination/install.sh"
  for item in lib open-code shared agents skills rtk; do
    cp -R "$FORGE_ROOT/$item" "$destination/"
  done

  printf '%s\n' "$destination"
}

# Independent JSONC reader used as the test oracle. It intentionally does not
# import the production plugin-sync helper, so a parser regression cannot make
# both the expectation and the observed installation agree.
plugin_inventory() {
  python3 - "$1" "${2:-}" <<'PY'
import json
import os
import sys


def strip_jsonc(text):
    out = []
    index = 0
    in_string = False

    while index < len(text):
        char = text[index]
        if in_string:
            out.append(char)
            if char == "\\" and index + 1 < len(text):
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
                raise ValueError("unterminated block comment")
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

    return "".join(out)


config_path = sys.argv[1]
plugin_dir = sys.argv[2] or None
with open(config_path, encoding="utf-8") as handle:
    config = json.loads(strip_jsonc(handle.read()))

declared = config.get("plugin", [])
if isinstance(declared, str):
    declared = [declared]
if not isinstance(declared, list) or not all(isinstance(item, str) for item in declared):
    raise ValueError("'plugin' must be an array of strings")

config_root = os.path.dirname(os.path.abspath(config_path))
local = [entry for entry in declared if entry.startswith("./")]
missing = []
expected_plugin_files = set()
for entry in local:
    relative = entry[2:]
    if not os.path.isfile(os.path.join(config_root, relative)):
        missing.append(entry)
    if relative.startswith("plugins/"):
        expected_plugin_files.add(relative[len("plugins/"):])

actual_plugin_files = set()
if plugin_dir and os.path.isdir(plugin_dir):
    for root, _directories, files in os.walk(plugin_dir):
        for name in files:
            path = os.path.join(root, name)
            if os.path.isfile(path) or os.path.islink(path):
                actual_plugin_files.add(os.path.relpath(path, plugin_dir))

print(json.dumps({
    "declared": declared,
    "local": local,
    "missing": sorted(missing),
    "expected_plugin_files": sorted(expected_plugin_files),
    "actual_plugin_files": sorted(actual_plugin_files),
    "orphans": sorted(actual_plugin_files - expected_plugin_files),
}, sort_keys=True))
PY
}

# Compare exact filename sets, not only counts: equal-sized but different sets
# are precisely the latent hardcoded-list drift this audit must catch.
audit_component_sets() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json
import os
import sys


def markdown_names(directory):
    if not os.path.isdir(directory):
        return []
    return sorted(
        name
        for name in os.listdir(directory)
        if name.endswith(".md") and os.path.isfile(os.path.join(directory, name))
    )


installed_agents, repo_agents, generated_agents, installed_commands, repo_commands = (
    markdown_names(path) for path in sys.argv[1:]
)
agent_sets = [installed_agents, repo_agents, generated_agents]
command_sets = [installed_commands, repo_commands]
print(json.dumps({
    "agent_counts": [len(names) for names in agent_sets],
    "agent_sets_equal": all(names == agent_sets[0] for names in agent_sets),
    "command_counts": [len(names) for names in command_sets],
    "command_sets_equal": all(names == command_sets[0] for names in command_sets),
}, sort_keys=True))
PY
}

test_isolated_install_and_launcher() {
  echo ""
  echo "--- test_isolated_install_and_launcher"

  local tmp_home
  tmp_home="$(mktemp -d "$TEST_TMP_ROOT/install.XXXXXX")"
  TMP_TEST_HOME="$tmp_home"

  local fixture_repo installer uninstaller installed_config plugins_dir
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  installer="$fixture_repo/open-code/install-opencode.sh"
  uninstaller="$fixture_repo/open-code/uninstall-opencode.sh"
  installed_config="$tmp_home/.config/opencode-forge/opencode.jsonc"
  plugins_dir="$tmp_home/.config/opencode-forge/plugins"

  run_isolated "$tmp_home" OPENAI_API_KEY=test-openai-key bash "$installer" >/dev/null 2>&1

  if [ -f "$tmp_home/.config/opencode-forge/agents/orchestrator.md" ] \
    && [ ! -L "$tmp_home/.config/opencode-forge/agents/orchestrator.md" ] \
    && diff -q "$fixture_repo/open-code/agents/orchestrator.md" "$tmp_home/.config/opencode-forge/agents/orchestrator.md" >/dev/null 2>&1; then
    pass "overlay isolated agent copy created"
  else
    fail "overlay isolated agent copy missing/mismatched"
  fi

  if [ -f "$installed_config" ]; then
    pass "overlay config file created"
  else
    fail "overlay config file missing"
  fi

  local cmd
  for cmd in create-plan execute-plan review create-pr pr-description update-changelog; do
    local dest="$tmp_home/.config/opencode-forge/commands/${cmd}.md"
    local src="$FORGE_ROOT/open-code/commands/${cmd}.md"
    if [ -f "$dest" ] && [ ! -L "$dest" ] && diff -q "$src" "$dest" >/dev/null 2>&1; then
      pass "overlay command copy created for ${cmd}.md"
    else
      fail "overlay command copy missing/mismatched for ${cmd}.md"
    fi
  done

  # Compare the semantic plugin field and both sides of the disk/config
  # relationship. This is the assertion that the old installer missed: it
  # checked forge-guard.js only, allowing forge-task-observer.js to vanish.
  local source_inventory installed_inventory
  if source_inventory="$(plugin_inventory "$FORGE_ROOT/open-code/opencode.jsonc")" \
    && installed_inventory="$(plugin_inventory "$installed_config" "$plugins_dir")"; then
    local source_declared installed_declared missing_count orphan_count expected_count actual_count
    source_declared="$(printf '%s' "$source_inventory" | jq -c '.declared')"
    installed_declared="$(printf '%s' "$installed_inventory" | jq -c '.declared')"
    missing_count="$(printf '%s' "$installed_inventory" | jq -r '.missing | length')"
    orphan_count="$(printf '%s' "$installed_inventory" | jq -r '.orphans | length')"
    expected_count="$(printf '%s' "$installed_inventory" | jq -r '.expected_plugin_files | length')"
    actual_count="$(printf '%s' "$installed_inventory" | jq -r '.actual_plugin_files | length')"

    if [ "$source_declared" = "$installed_declared" ]; then
      pass "installed config plugin field matches repository opencode.jsonc"
    else
      fail "installed config plugin field diverges from repository opencode.jsonc (repo=$source_declared installed=$installed_declared)"
    fi

    if [ "$missing_count" -eq 0 ]; then
      pass "every plugin declared by installed config is present on disk"
    else
      fail "installed config declares missing plugins: $(printf '%s' "$installed_inventory" | jq -r '.missing | join(", ")')"
    fi

    if [ "$orphan_count" -eq 0 ]; then
      pass "every plugin present on disk is declared by installed config"
    else
      fail "installed plugins directory contains orphan plugins: $(printf '%s' "$installed_inventory" | jq -r '.orphans | join(", ")')"
    fi

    if [ "$missing_count" -eq 0 ] && [ "$orphan_count" -eq 0 ] \
      && [ "$expected_count" -eq "$actual_count" ]; then
      pass "installed plugins directory contains exactly the declared plugins (${actual_count} files)"
    else
      fail "installed plugins directory is not an exact match (expected=$expected_count actual=$actual_count missing=$missing_count orphans=$orphan_count)"
    fi

    if [ -f "$plugins_dir/forge-task-observer.js" ]; then
      pass "forge-task-observer.js is installed alongside forge-guard.js"
    else
      fail "forge-task-observer.js is missing from installed plugins directory"
    fi
  else
    fail "could not inspect installed plugin declaration/inventory"
  fi

  if [ ! -e "$tmp_home/.config/opencode/opencode.jsonc" ]; then
    pass "global opencode config untouched"
  else
    fail "global opencode config was touched"
  fi

  run_isolated "$tmp_home" "$tmp_home/.local/bin/forge-opencode" debug config > "$tmp_home/debug-config.out"

  if grep -q 'opencode-forge/plugins/forge-guard.js' "$tmp_home/debug-config.out" \
    && grep -q 'opencode-forge/plugins/forge-task-observer.js' "$tmp_home/debug-config.out" \
    && grep -q '"default_agent": "orchestrator"' "$tmp_home/debug-config.out"; then
    pass "launcher resolves through symlink and loads isolated config with both plugins"
  else
    fail "launcher did not load isolated config through symlink with both plugins"
  fi

  mkdir -p "$tmp_home/fakebin"
  printf 'OPENAI_API_KEY=file-token\n' > "$tmp_home/.opencode-tokens"
  cat > "$tmp_home/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "${OPENAI_API_KEY:-missing}"
EOF
  chmod +x "$tmp_home/fakebin/opencode"

  run_isolated "$tmp_home" PATH="$tmp_home/fakebin:$PATH" "$tmp_home/.local/bin/forge-opencode" > "$tmp_home/launcher-env.out"

  if grep -q '^file-token$' "$tmp_home/launcher-env.out"; then
    pass "launcher loads OPENAI_API_KEY from ~/.opencode-tokens via env.sh"
  else
    fail "launcher did not load OPENAI_API_KEY from ~/.opencode-tokens"
  fi

  # Audit the other hardcoded overlay lists. The generator runs against a fresh
  # fixture so its output set can be observed without touching the checkout.
  local generator_repo generator_exit=0 audit
  generator_repo="$(create_repo_fixture "$tmp_home/generator-repo")"
  rm -rf "$generator_repo/open-code/agents"
  mkdir -p "$generator_repo/open-code/agents"
  bash "$generator_repo/shared/scripts/generate-agents.sh" --target=opencode > "$tmp_home/generate-agents.out" 2>&1 || generator_exit=$?

  if audit="$(audit_component_sets \
    "$tmp_home/.config/opencode-forge/agents" \
    "$FORGE_ROOT/open-code/agents" \
    "$generator_repo/open-code/agents" \
    "$tmp_home/.config/opencode-forge/commands" \
    "$FORGE_ROOT/open-code/commands")"; then
    if [ "$generator_exit" -eq 0 ] && printf '%s' "$audit" | jq -e '.agent_sets_equal' >/dev/null; then
      pass "installed agents match repository and isolated generator output ($(printf '%s' "$audit" | jq -r '.agent_counts[0]') files)"
    else
      fail "installed/repository/generated agent sets diverged: $audit"
    fi

    if printf '%s' "$audit" | jq -e '.command_sets_equal' >/dev/null; then
      pass "installed commands match repository ($(printf '%s' "$audit" | jq -r '.command_counts[0]') files)"
    else
      fail "installed/repository command sets diverged: $audit"
    fi
  else
    fail "could not audit installed agent/command sets"
  fi

  run_isolated "$tmp_home" bash "$uninstaller" >/dev/null 2>&1

  if [ ! -e "$installed_config" ] && [ ! -e "$tmp_home/.local/bin/forge-opencode" ]; then
    pass "uninstall removes isolated overlay and launcher"
  else
    fail "uninstall did not remove isolated overlay and launcher"
  fi

  for cmd in create-plan execute-plan review create-pr pr-description update-changelog; do
    if [ ! -e "$tmp_home/.config/opencode-forge/commands/${cmd}.md" ]; then
      pass "uninstall removes command symlink for ${cmd}.md"
    else
      fail "uninstall did not remove command symlink for ${cmd}.md"
    fi
  done

  if [ ! -d "$tmp_home/.config/opencode-forge/commands" ]; then
    pass "uninstall leaves \$COMMANDS_DIR clean (directory removed)"
  else
    local leftover
    leftover="$(find "$tmp_home/.config/opencode-forge/commands" -mindepth 1 2>/dev/null)"
    if [ -z "$leftover" ]; then
      pass "uninstall leaves \$COMMANDS_DIR clean (empty directory)"
    else
      fail "uninstall left leftover entries in \$COMMANDS_DIR: $leftover"
    fi
  fi

  local plugin_leftovers=""
  if [ -d "$plugins_dir" ]; then
    plugin_leftovers="$(find "$plugins_dir" -mindepth 1 -print 2>/dev/null)"
  fi
  if [ -z "$plugin_leftovers" ]; then
    pass "uninstall leaves no Forge plugin in the plugins directory"
  else
    fail "uninstall left plugin entries behind: $plugin_leftovers"
  fi

  if [ ! -e "$plugins_dir/forge-task-observer.js" ]; then
    pass "uninstall does not leave forge-task-observer.js orphaned"
  else
    fail "uninstall left forge-task-observer.js orphaned"
  fi

  if [ ! -d "$tmp_home/.config/opencode-forge/agents" ]; then
    pass "uninstall leaves \$AGENTS_DIR clean (directory removed)"
  else
    local agent_leftovers
    agent_leftovers="$(find "$tmp_home/.config/opencode-forge/agents" -mindepth 1 2>/dev/null)"
    if [ -z "$agent_leftovers" ]; then
      pass "uninstall leaves \$AGENTS_DIR clean (empty directory)"
    else
      fail "uninstall left leftover entries in \$AGENTS_DIR: $agent_leftovers"
    fi
  fi

  TMP_TEST_HOME=""
  rm -rf "$tmp_home"
}

test_failed_install_does_not_persist_state() {
  echo ""
  echo "--- test_failed_install_does_not_persist_state"

  local tmp_home
  tmp_home="$(mktemp -d "$TEST_TMP_ROOT/failed-install.XXXXXX")"
  TMP_TEST_HOME="$tmp_home"

  local fixture_repo root_installer
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  root_installer="$fixture_repo/install.sh"

  local exit_code=0
  run_isolated "$tmp_home" PATH="/usr/bin:/bin" bash "$root_installer" install --target=opencode >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "install --target=opencode fails cleanly when opencode is unavailable"
  else
    fail "install --target=opencode unexpectedly succeeded without opencode"
  fi

  if [ ! -e "$tmp_home/.forge-state.json" ]; then
    pass "failed OpenCode install does not persist forge state"
  else
    fail "failed OpenCode install persisted forge state"
  fi

  TMP_TEST_HOME=""
  rm -rf "$tmp_home"
}

test_both_target_opencode_failure_leaves_claude_installed() {
  echo ""
  echo "--- test_both_target_opencode_failure_leaves_claude_installed"

  local tmp_home
  tmp_home="$(mktemp -d "$TEST_TMP_ROOT/both-target.XXXXXX")"
  TMP_TEST_HOME="$tmp_home"

  local fixture_repo root_installer
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  root_installer="$fixture_repo/install.sh"

  local exit_code=0
  run_isolated "$tmp_home" PATH="/usr/bin:/bin" bash "$root_installer" install --target=both >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "install --target=both fails non-zero when opencode is unavailable"
  else
    fail "install --target=both unexpectedly succeeded without opencode"
  fi

  # The claude target must be installed even though opencode failed
  if [ -L "$tmp_home/.claude/agents/senior.md" ]; then
    pass "install --target=both installs claude target before opencode failure"
  else
    fail "install --target=both did not install claude target before opencode failure"
  fi

  # State file must exist and record claude but not opencode (rollback of opencode target)
  if [ -f "$tmp_home/.forge-state.json" ]; then
    local has_claude has_opencode
    has_claude="$(jq -r '[.targets_manifest[]?.name] | index("claude") != null' "$tmp_home/.forge-state.json" 2>/dev/null || echo "false")"
    has_opencode="$(jq -r '[.targets_manifest[]?.name] | index("opencode") != null' "$tmp_home/.forge-state.json" 2>/dev/null || echo "true")"
    if [ "$has_claude" = "true" ] && [ "$has_opencode" = "false" ]; then
      pass "state records claude but not opencode after --target=both partial failure"
    else
      fail "state does not correctly reflect partial --target=both install (has_claude=$has_claude, has_opencode=$has_opencode)"
    fi
  else
    fail "state file missing after --target=both partial install"
  fi

  TMP_TEST_HOME=""
  rm -rf "$tmp_home"
}

test_api_key_setup_skip() {
  echo ""
  echo "--- test_api_key_setup_skip"

  local tmp_home
  tmp_home="$(mktemp -d "$TEST_TMP_ROOT/api-skip.XXXXXX")"
  TMP_TEST_HOME="$tmp_home"

  local fixture_repo installer
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  installer="$fixture_repo/open-code/install-opencode.sh"

  printf 'N\n' | run_isolated "$tmp_home" OPENAI_API_KEY=test-openai-key bash "$installer" >/dev/null 2>&1

  if [ ! -e "$tmp_home/.opencode-tokens" ]; then
    pass "skip key setup: ~/.opencode-tokens not created"
  else
    fail "skip key setup: ~/.opencode-tokens was unexpectedly created"
  fi

  TMP_TEST_HOME=""
  rm -rf "$tmp_home"
}

test_api_key_setup_add_one_key() {
  echo ""
  echo "--- test_api_key_setup_add_one_key"

  local tmp_home
  tmp_home="$(mktemp -d "$TEST_TMP_ROOT/api-add.XXXXXX")"
  TMP_TEST_HOME="$tmp_home"

  local fixture_repo installer
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  installer="$fixture_repo/open-code/install-opencode.sh"

  local exit_code=0
  printf 's\n1\ntest-key-value\nN\n' | run_isolated "$tmp_home" OPENAI_API_KEY=test-openai-key bash "$installer" >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "add one key: installer exits 0"
  else
    fail "add one key: installer exited $exit_code (expected 0)"
  fi

  local tokens_file="$tmp_home/.opencode-tokens"

  if [ -f "$tokens_file" ]; then
    pass "add one key: ~/.opencode-tokens created"
  else
    fail "add one key: ~/.opencode-tokens not created"
    TMP_TEST_HOME=""
    rm -rf "$tmp_home"
    return
  fi

  if grep -q '^MINIMAX_API_KEY=test-key-value$' "$tokens_file"; then
    pass "add one key: MINIMAX_API_KEY=test-key-value written correctly"
  else
    fail "add one key: MINIMAX_API_KEY=test-key-value not found in ~/.opencode-tokens"
  fi

  local perms
  perms="$(stat -c '%a' "$tokens_file")"
  if [ "$perms" = "600" ]; then
    pass "add one key: ~/.opencode-tokens has permissions 600"
  else
    fail "add one key: ~/.opencode-tokens has wrong permissions ($perms, expected 600)"
  fi

  TMP_TEST_HOME=""
  rm -rf "$tmp_home"
}

test_api_key_setup_replace_existing_key() {
  echo ""
  echo "--- test_api_key_setup_replace_existing_key"

  local tmp_home
  tmp_home="$(mktemp -d "$TEST_TMP_ROOT/api-replace.XXXXXX")"
  TMP_TEST_HOME="$tmp_home"

  local fixture_repo installer
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  installer="$fixture_repo/open-code/install-opencode.sh"

  local tokens_file="$tmp_home/.opencode-tokens"
  install -m 600 /dev/null "$tokens_file"
  printf 'MINIMAX_API_KEY=old-value\n' >> "$tokens_file"

  local exit_code=0
  printf 's\n1\nnew-value\nN\n' | run_isolated "$tmp_home" OPENAI_API_KEY=test-openai-key bash "$installer" >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    pass "replace key: installer exits 0"
  else
    fail "replace key: installer exited $exit_code (expected 0)"
  fi

  if grep -q '^MINIMAX_API_KEY=new-value$' "$tokens_file"; then
    pass "replace key: MINIMAX_API_KEY updated to new-value"
  else
    fail "replace key: MINIMAX_API_KEY not updated in ~/.opencode-tokens"
  fi

  if ! grep -q '^MINIMAX_API_KEY=old-value$' "$tokens_file"; then
    pass "replace key: old value removed"
  else
    fail "replace key: old value still present in ~/.opencode-tokens"
  fi

  TMP_TEST_HOME=""
  rm -rf "$tmp_home"
}

test_missing_plugin_source_aborts_install() {
  echo ""
  echo "--- test_missing_plugin_source_aborts_install"

  local tmp_home
  tmp_home="$(mktemp -d "$TEST_TMP_ROOT/missing-plugin.XXXXXX")"
  TMP_TEST_HOME="$tmp_home"

  local fixture_repo installer installed_config
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  installer="$fixture_repo/open-code/install-opencode.sh"
  installed_config="$tmp_home/.config/opencode-forge/opencode.jsonc"

  # Simulate a broken/incomplete source overlay without touching the checkout:
  # the config still declares forge-task-observer.js, but its source file does
  # not exist.
  rm -f "$fixture_repo/open-code/plugins/forge-task-observer.js"

  mkdir -p "$tmp_home/fakebin"
  cat > "$tmp_home/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
  chmod +x "$tmp_home/fakebin/opencode"

  local exit_code=0
  if printf 'N\n' | run_isolated "$tmp_home" \
    PATH="$tmp_home/fakebin:$PATH" \
    OPENAI_API_KEY=test-openai-key \
    bash "$installer" > "$tmp_home/install.out" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  if [ "$exit_code" -eq 1 ]; then
    pass "installer aborts with exit 1 when a declared plugin has no source file"
  else
    fail "installer exit code was $exit_code (expected 1 for a missing plugin source)"
  fi

  if grep -q 'has no source file in the overlay' "$tmp_home/install.out"; then
    pass "installer reports the missing declared plugin source"
  else
    fail "installer did not report the missing declared plugin source"
  fi

  if [ ! -e "$installed_config" ]; then
    pass "failed install leaves no installed config referencing the absent plugin"
  else
    local installed_inventory
    if installed_inventory="$(plugin_inventory "$installed_config" "$tmp_home/.config/opencode-forge/plugins")" \
      && [ "$(printf '%s' "$installed_inventory" | jq -r '.missing | length')" -eq 0 ]; then
      pass "failed install leaves no installed config referencing the absent plugin"
    else
      fail "failed install left an installed config that references an absent plugin"
    fi
  fi

  # Exercise the helper's explicit verification mode with the same broken
  # fixture. It must independently detect the missing on-disk plugin.
  local verify_code=0
  python3 "$fixture_repo/open-code/lib/plugin-sync.py" verify \
    --config "$fixture_repo/open-code/opencode.jsonc" > "$tmp_home/verify.out" 2>&1 || verify_code=$?

  if [ "$verify_code" -eq 1 ]; then
    pass "plugin-sync verify exits 1 for a config with a missing plugin"
  else
    fail "plugin-sync verify exit code was $verify_code (expected 1)"
  fi

  TMP_TEST_HOME=""
  rm -rf "$tmp_home"
}

echo "================================"
echo " opencode_install_integration.sh"
echo "================================"

test_isolated_install_and_launcher
test_missing_plugin_source_aborts_install
test_failed_install_does_not_persist_state
test_both_target_opencode_failure_leaves_claude_installed
test_api_key_setup_skip
test_api_key_setup_add_one_key
test_api_key_setup_replace_existing_key

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
