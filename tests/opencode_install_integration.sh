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

# ---------------------------------------------------------------------------
# status / doctor contract for the OpenCode target
# ---------------------------------------------------------------------------
# `status` and `doctor` diagnose every target against the contract of its own
# installer. For the OpenCode target that contract is the overlay: regular
# file copies of the agents and the commands, AGENTS.md, the JSONC config, the
# plugins declared by that config and the global launcher. The Claude
# catalogue must never be projected onto it: that projection was the source of
# the permanent false DEGRADADO.
#
# Both commands are strictly read-only: they never write the state file and
# never touch the installed overlay.
# ---------------------------------------------------------------------------

# Tokens that must never show up in the OpenCode diagnostics: they belong to
# the Claude contract (CLAUDE.md refs, settings.json and the Claude component
# catalogue).
OPENCODE_CLAUDE_TOKENS="CLAUDE.md settings.json CLAUDE-shared.md Componentes: managed key statusline branch-guard rtk-hook cost-report"

# Sandbox of the current status/doctor test. Filled by prepare_overlay_sandbox.
SD_HOME=""
SD_REPO=""
SD_OVERLAY=""

# prepare_overlay_sandbox <sandbox_dir>
# Creates an isolated HOME plus a disposable checkout of forge and installs
# the OpenCode overlay through the root installer (so the state file records
# the opencode target and the launcher points to the disposable checkout).
prepare_overlay_sandbox() {
  local sandbox="$1"

  SD_HOME="$sandbox/home"
  SD_REPO="$sandbox/repo"
  SD_OVERLAY="$SD_HOME/.config/opencode-forge"

  mkdir -p "$SD_HOME"
  create_repo_fixture "$SD_REPO" >/dev/null

  # The overlay installer only requires an `opencode` binary in PATH.
  mkdir -p "$SD_HOME/fakebin"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$SD_HOME/fakebin/opencode"
  chmod +x "$SD_HOME/fakebin/opencode"

  if ! run_isolated "$SD_HOME" PATH="$SD_HOME/fakebin:$PATH" OPENAI_API_KEY=test-openai-key \
    bash "$SD_REPO/install.sh" install --target=opencode \
    > "$sandbox/install.log" 2>&1 < /dev/null; then
    return 1
  fi
  return 0
}

# snapshot_overlay <sandbox_dir>
# Freezes the healthy installation so every breakage case starts from the very
# same state (mtimes included: cp -a keeps them).
snapshot_overlay() {
  local sandbox="$1"

  rm -rf "$sandbox/healthy"
  mkdir -p "$sandbox/healthy"
  cp -a "$SD_OVERLAY" "$sandbox/healthy/opencode-forge"
  cp -a "$SD_HOME/.forge-state.json" "$sandbox/healthy/forge-state.json"
  cp -a "$SD_HOME/.local/bin" "$sandbox/healthy/local-bin"
}

restore_overlay() {
  local sandbox="$1"

  rm -rf "$SD_OVERLAY" "$SD_HOME/.local/bin" "$SD_HOME/.forge-state.json"
  cp -a "$sandbox/healthy/opencode-forge" "$SD_OVERLAY"
  cp -a "$sandbox/healthy/local-bin" "$SD_HOME/.local/bin"
  cp -a "$sandbox/healthy/forge-state.json" "$SD_HOME/.forge-state.json"
}

# snapshot_tree <root>
# Canonical listing of every regular file (sha256) and symlink (raw target)
# below <root>. Used to prove that a command writes nothing.
snapshot_tree() {
  local root="$1"

  (
    cd "$root" 2>/dev/null || exit 0
    find . -mindepth 1 \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort |
      while IFS= read -r path; do
        if [ -L "$path" ]; then
          printf 'L\t%s\t%s\n' "$path" "$(readlink "$path")"
        else
          printf 'F\t%s\t%s\n' "$path" "$(sha256sum "$path" 2>/dev/null | cut -d' ' -f1)"
        fi
      done
  )
}

# apply_opencode_break <case_name>
# Breaks exactly one artifact of the healthy overlay.
apply_opencode_break() {
  local case_name="$1"

  case "$case_name" in
    plugin_deleted)
      rm -f "$SD_OVERLAY/plugins/forge-guard.js"
      ;;
    agent_deleted)
      rm -f "$SD_OVERLAY/agents/senior.md"
      ;;
    config_deleted)
      rm -f "$SD_OVERLAY/opencode.jsonc"
      ;;
    config_corrupt)
      printf '{\n  "plugin": [ "./plugins/forge-guard.js",\n}\n' > "$SD_OVERLAY/opencode.jsonc"
      ;;
    agent_content_diff)
      printf 'contenido que diverge del origen\n' > "$SD_OVERLAY/agents/tech.md"
      ;;
    agents_md_deleted)
      rm -f "$SD_OVERLAY/AGENTS.md"
      ;;
    launcher_repointed)
      ln -sfn "$SD_REPO/open-code/forge-opencode.sh.renamed" "$SD_HOME/.local/bin/forge-opencode"
      ;;
    unexpected_file)
      printf 'fichero no previsto\n' > "$SD_OVERLAY/agents/ghost.md"
      ;;
    inventory_broken)
      rm -rf "$SD_REPO/open-code/agents"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# opencode_break_expectations <case_name>
# Fills EXPECT_TOKEN (status token), EXPECT_NEEDLE (the artifact that must be
# reported exactly once) and EXPECT_HINT (the action hint).
opencode_break_expectations() {
  local case_name="$1"

  EXPECT_TOKEN=""
  EXPECT_NEEDLE=""
  EXPECT_HINT="bash install.sh install --target=opencode"

  case "$case_name" in
    plugin_deleted)
      EXPECT_TOKEN="MISSING"
      EXPECT_NEEDLE="plugins/forge-guard.js"
      ;;
    agent_deleted)
      EXPECT_TOKEN="MISSING"
      EXPECT_NEEDLE="agents/senior.md"
      ;;
    config_deleted)
      EXPECT_TOKEN="MISSING"
      EXPECT_NEEDLE="opencode.jsonc"
      ;;
    config_corrupt)
      EXPECT_TOKEN="INVALID"
      EXPECT_NEEDLE="opencode.jsonc"
      ;;
    agent_content_diff)
      EXPECT_TOKEN="MISMATCH"
      EXPECT_NEEDLE="agents/tech.md"
      ;;
    agents_md_deleted)
      EXPECT_TOKEN="MISSING"
      EXPECT_NEEDLE="AGENTS.md"
      ;;
    launcher_repointed)
      EXPECT_TOKEN="MISMATCH"
      EXPECT_NEEDLE="forge-opencode"
      ;;
    unexpected_file)
      EXPECT_TOKEN="UNEXPECTED"
      EXPECT_NEEDLE="agents/ghost.md"
      ;;
    inventory_broken)
      EXPECT_TOKEN="INVENTORY ERROR"
      EXPECT_NEEDLE="no se pudo inventariar el origen"
      EXPECT_HINT="revisa open-code/ en el repositorio"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

# count_lines_with <needle> <file>
count_lines_with() {
  local needle="$1"
  local file="$2"

  grep -c -F -- "$needle" "$file" 2>/dev/null || true
}

# assert_no_claude_contract <file> <label>
# The OpenCode diagnostics must never mention the Claude contract.
assert_no_claude_contract() {
  local file="$1"
  local label="$2"
  local token offender=""

  for token in $OPENCODE_CLAUDE_TOKENS; do
    if grep -q -F -- "$token" "$file" 2>/dev/null; then
      offender="$token"
      break
    fi
  done

  if [ -z "$offender" ]; then
    pass "$label"
  else
    fail "$label (menciona '$offender')"
  fi
}

test_status_doctor_healthy_overlay() {
  echo ""
  echo "--- test_status_doctor_healthy_overlay"

  local sandbox
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/diag-healthy.XXXXXX")"
  TMP_TEST_HOME="$sandbox/home"

  if ! prepare_overlay_sandbox "$sandbox"; then
    fail "no se pudo instalar el overlay aislado para el diagnóstico"
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  local status_rc=0 doctor_rc=0
  run_isolated "$SD_HOME" bash "$SD_REPO/install.sh" status \
    > "$sandbox/status.out" 2>&1 || status_rc=$?
  run_isolated "$SD_HOME" bash "$SD_REPO/install.sh" doctor \
    > "$sandbox/doctor.out" 2>&1 || doctor_rc=$?

  if [ "$status_rc" -eq 0 ]; then
    pass "status sale 0 con el overlay sano"
  else
    fail "status debería salir 0 con el overlay sano (got $status_rc)"
  fi

  if grep -q "Estado general: OK" "$sandbox/status.out"; then
    pass "status informa de Estado general: OK con el overlay sano"
  else
    fail "status no informó de Estado general: OK con el overlay sano"
  fi

  if grep -q "OpenCode overlay (" "$sandbox/status.out"; then
    pass "status muestra la sección del overlay OpenCode"
  else
    fail "status no mostró la sección del overlay OpenCode"
  fi

  if [ "$doctor_rc" -eq 0 ]; then
    pass "doctor sale 0 con el overlay sano"
  else
    fail "doctor debería salir 0 con el overlay sano (got $doctor_rc)"
  fi

  if grep -q "OpenCode overlay (" "$sandbox/doctor.out"; then
    pass "doctor muestra la sección del overlay OpenCode"
  else
    fail "doctor no mostró la sección del overlay OpenCode"
  fi

  if grep -q "Resumen: FAILs=0" "$sandbox/doctor.out"; then
    pass "doctor no reporta FAILs con el overlay sano"
  else
    fail "doctor reportó FAILs con el overlay sano"
  fi

  assert_no_claude_contract "$sandbox/status.out" \
    "status del overlay sano no menciona el contrato Claude"
  assert_no_claude_contract "$sandbox/doctor.out" \
    "doctor del overlay sano no menciona el contrato Claude"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_status_doctor_do_not_write() {
  echo ""
  echo "--- test_status_doctor_do_not_write"

  local sandbox
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/diag-readonly.XXXXXX")"
  TMP_TEST_HOME="$sandbox/home"

  if ! prepare_overlay_sandbox "$sandbox"; then
    fail "no se pudo instalar el overlay aislado para el test de solo lectura"
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  local state="$SD_HOME/.forge-state.json"
  local sha_before mtime_before home_before repo_before
  sha_before="$(sha256sum "$state" | cut -d' ' -f1)"
  mtime_before="$(stat -c '%y' "$state")"
  home_before="$(snapshot_tree "$SD_HOME")"
  repo_before="$(snapshot_tree "$SD_REPO")"

  local status_rc=0 doctor_rc=0
  run_isolated "$SD_HOME" bash "$SD_REPO/install.sh" status \
    > "$sandbox/status.out" 2>&1 </dev/null || status_rc=$?
  run_isolated "$SD_HOME" bash "$SD_REPO/install.sh" doctor \
    > "$sandbox/doctor.out" 2>&1 </dev/null || doctor_rc=$?

  if [ "$status_rc" -eq 0 ] && [ "$doctor_rc" -eq 0 ]; then
    pass "status/doctor salen 0 con el overlay sano"
  else
    fail "status/doctor deberían salir 0 con el overlay sano (status=$status_rc doctor=$doctor_rc)"
  fi

  local sha_after mtime_after home_after repo_after
  sha_after="$(sha256sum "$state" | cut -d' ' -f1)"
  mtime_after="$(stat -c '%y' "$state")"
  home_after="$(snapshot_tree "$SD_HOME")"
  repo_after="$(snapshot_tree "$SD_REPO")"

  if [ "$sha_before" = "$sha_after" ]; then
    pass "status/doctor no cambian el sha256 del state file"
  else
    fail "status/doctor cambiaron el sha256 del state file ($sha_before -> $sha_after)"
  fi

  if [ "$mtime_before" = "$mtime_after" ]; then
    pass "status/doctor no cambian el mtime del state file"
  else
    fail "status/doctor cambiaron el mtime del state file ($mtime_before -> $mtime_after)"
  fi

  if [ "$home_before" = "$home_after" ]; then
    pass "status/doctor no modifican nada del HOME aislado"
  else
    fail "status/doctor modificaron el HOME aislado"
    diff <(printf '%s\n' "$home_before") <(printf '%s\n' "$home_after") | head -20 >&2 || true
  fi

  if [ "$repo_before" = "$repo_after" ]; then
    pass "status/doctor no modifican el checkout desechable"
  else
    fail "status/doctor modificaron el checkout desechable"
    diff <(printf '%s\n' "$repo_before") <(printf '%s\n' "$repo_after") | head -20 >&2 || true
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_status_doctor_report_each_opencode_break() {
  echo ""
  echo "--- test_status_doctor_report_each_opencode_break"

  local sandbox
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/diag-break.XXXXXX")"
  TMP_TEST_HOME="$sandbox/home"

  if ! prepare_overlay_sandbox "$sandbox"; then
    fail "no se pudo instalar el overlay aislado para los casos de rotura"
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi
  snapshot_overlay "$sandbox"

  local case_name
  for case_name in plugin_deleted agent_deleted config_deleted config_corrupt \
    agent_content_diff agents_md_deleted launcher_repointed unexpected_file \
    inventory_broken; do
    restore_overlay "$sandbox"

    if ! apply_opencode_break "$case_name"; then
      fail "caso de rotura desconocido: $case_name"
      continue
    fi
    opencode_break_expectations "$case_name"

    local status_rc=0 doctor_rc=0
    run_isolated "$SD_HOME" bash "$SD_REPO/install.sh" status \
      > "$sandbox/status.out" 2>&1 || status_rc=$?
    run_isolated "$SD_HOME" bash "$SD_REPO/install.sh" doctor \
      > "$sandbox/doctor.out" 2>&1 || doctor_rc=$?

    if [ "$status_rc" -eq 1 ]; then
      pass "[$case_name] status sale 1"
    else
      fail "[$case_name] status debería salir 1 (got $status_rc)"
    fi

    if grep -qE "^[[:space:]]+${EXPECT_TOKEN}[[:space:]]" "$sandbox/status.out"; then
      pass "[$case_name] status reporta el estado $EXPECT_TOKEN"
    else
      fail "[$case_name] status no reportó el estado $EXPECT_TOKEN"
    fi

    local status_mentions
    status_mentions="$(count_lines_with "$EXPECT_NEEDLE" "$sandbox/status.out")"
    if [ "$status_mentions" = "1" ]; then
      pass "[$case_name] status menciona el artefacto roto exactamente una vez"
    else
      fail "[$case_name] status mencionó el artefacto roto $status_mentions veces (esperado 1)"
    fi

    if grep -qF -- "$EXPECT_HINT" "$sandbox/status.out"; then
      pass "[$case_name] status muestra el hint de acción"
    else
      fail "[$case_name] status no mostró el hint de acción"
    fi

    if [ "$doctor_rc" -eq 1 ]; then
      pass "[$case_name] doctor sale 1"
    else
      fail "[$case_name] doctor debería salir 1 (got $doctor_rc)"
    fi

    if grep -qE "^  FAIL  ${EXPECT_TOKEN}:" "$sandbox/doctor.out"; then
      pass "[$case_name] doctor reporta FAIL con el estado $EXPECT_TOKEN"
    else
      fail "[$case_name] doctor no reportó FAIL con el estado $EXPECT_TOKEN"
    fi

    local doctor_mentions
    doctor_mentions="$(count_lines_with "$EXPECT_NEEDLE" "$sandbox/doctor.out")"
    if [ "$doctor_mentions" = "1" ]; then
      pass "[$case_name] doctor menciona el artefacto roto exactamente una vez"
    else
      fail "[$case_name] doctor mencionó el artefacto roto $doctor_mentions veces (esperado 1)"
    fi

    if grep -qF -- "$EXPECT_HINT" "$sandbox/doctor.out"; then
      pass "[$case_name] doctor muestra el hint de acción"
    else
      fail "[$case_name] doctor no mostró el hint de acción"
    fi

    assert_no_claude_contract "$sandbox/status.out" \
      "[$case_name] status no menciona el contrato Claude"
    assert_no_claude_contract "$sandbox/doctor.out" \
      "[$case_name] doctor no menciona el contrato Claude"
  done

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
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
test_status_doctor_healthy_overlay
test_status_doctor_do_not_write
test_status_doctor_report_each_opencode_break

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
