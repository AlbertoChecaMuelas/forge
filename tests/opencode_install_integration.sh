#!/usr/bin/env bash
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Shared isolation helpers: the isolated environment, the fingerprint of the
# real user files and the fake toolchain.
# shellcheck source=tests/isolation.sh
. "$FORGE_ROOT/tests/isolation.sh"

FAIL=0
PASS_COUNT=0
TMP_TEST_HOME=""
TEST_TMP_ROOT="/tmp/opencode/opencode-install-integration.$$"
PTY_OUT=""
PTY_RC=0

# Fingerprint of the real user files, taken BEFORE any test runs.
#
# The installer resolves the pinned OpenCode prefix from XDG_DATA_HOME /
# FORGE_OPENCODE_BIN_DIR, so an unisolated run installs @opencode/cli@2.1.4
# in the REAL ~/.local/share/forge/opencode-v2. The suite must leave the real
# machine untouched: this snapshot is compared when the suite finishes.
PROTECTED_SNAPSHOT="$(forge_protected_snapshot)"

pass() { echo "  PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=1; }

cleanup() {
  local rc=$?

  if [ -n "${TMP_TEST_HOME:-}" ]; then
    rm -rf "$TMP_TEST_HOME"
  fi
  if [ -n "${TEST_TMP_ROOT:-}" ]; then
    rm -rf "$TEST_TMP_ROOT"
  fi

  # The leak guard: the suite must never create the real pinned prefix and
  # must never modify the real user files.
  if ! forge_assert_no_forge_prefix; then
    rc=1
  fi
  if ! forge_assert_protected_unchanged "$PROTECTED_SNAPSHOT"; then
    rc=1
  fi

  exit $rc
}

mkdir -p "$TEST_TMP_ROOT"
trap cleanup EXIT

# The production installer gives OPENCODE_CONFIG_DIR / OPENCODE_CONFIG
# precedence over HOME, and it resolves the pinned OpenCode prefix from
# XDG_DATA_HOME / FORGE_OPENCODE_BIN_DIR. All of them are neutralised here:
# HOME, the XDG directories and the pinned prefix point inside the sandbox.
#
# The fake toolchain is always first in PATH: the suite must never run a
# real `npm install` (that would download @opencode/cli@2.1.4) and must never
# use the OpenCode binary installed in the machine.
run_isolated() {
  local isolated_home="$1"
  shift

  forge_make_toolchain "$isolated_home/fakebin"

  forge_isolated_env "$isolated_home" PATH="$isolated_home/fakebin:$PATH" "$@"
}

# run_isolated_bare <home> <command> [args...]
# Same isolation, but WITHOUT the fake toolchain: the caller owns the PATH.
# It is used by the cases that must fail because the OpenCode toolchain is
# not available at all.
run_isolated_bare() {
  local isolated_home="$1"
  shift

  forge_isolated_env "$isolated_home" "$@"
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

# ---------------------------------------------------------------------------
# Interactive setup helpers.
#
# The overlay installer only offers the interactive API key setup when stdin is
# a terminal (the [ -t 0 ] guard in open-code/install-opencode.sh): with a pipe
# the read would swallow a line of whatever the caller piped in, so the setup is
# unreachable through a pipe by design. The suite therefore drives the
# installer through a real pty with script(1) (util-linux).
#
# If script(1) is missing the coverage would be lost silently, so the suite
# fails loudly instead of skipping the case.
# ---------------------------------------------------------------------------
require_pty_support() {
  if ! command -v script >/dev/null 2>&1; then
    fail "script(1) (util-linux) is required: the suite drives the interactive API key setup through a pty"
    return 1
  fi

  if ! script -qec 'true' /dev/null </dev/null >/dev/null 2>&1; then
    fail "script(1) cannot allocate a pty: the suite needs a working pty to exercise the interactive API key setup"
    return 1
  fi

  return 0
}

# run_installer_with_pty <installer> <keystrokes> <home> [env assignments...]
# Types the keystrokes into a pty attached to the installer.
# Sets PTY_OUT (combined output) and PTY_RC (installer exit code).
run_installer_with_pty() {
  local installer="$1"
  local keys="$2"
  local home="$3"
  shift 3

  PTY_RC=0
  PTY_OUT="$(printf '%b' "$keys" | run_isolated "$home" "$@" \
    script -qec "bash $(printf '%q' "$installer")" /dev/null 2>&1)" || PTY_RC=$?
}

# Independent JSONC reader used as the test oracle. It intentionally does not
# import the production plugin-sync helper, so a parser regression cannot make
# both the expectation and the observed installation agree.
#
# OpenCode 2 contract:
#   * the declared plugins live in the `plugins` field (the V1 `plugin` field
#     is gone) and every entry is a string or an object with a `package`,
#   * a declared local plugin is a PACKAGE DIRECTORY, so the inventory is
#     computed over package trees instead of over single files.
#
# The second argument is the overlay root (the directory that holds the
# installed config). The plugin packages are expected under its
# `plugin-packages/` directory.
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
overlay_root = sys.argv[2] or None

with open(config_path, encoding="utf-8") as handle:
    config = json.loads(strip_jsonc(handle.read()))

declared = config.get("plugins", [])
if isinstance(declared, str):
    declared = [declared]
if not isinstance(declared, list):
    raise ValueError("'plugins' must be an array of strings or objects")

packages = []
for entry in declared:
    if isinstance(entry, str):
        packages.append(entry)
    elif isinstance(entry, dict) and isinstance(entry.get("package"), str):
        packages.append(entry["package"])
    else:
        raise ValueError("'plugins' entries must be strings or objects with a 'package'")

config_root = os.path.dirname(os.path.abspath(config_path))
local = [entry for entry in packages if entry.startswith("./")]
relative = [entry[2:] for entry in local]

missing = []
expected_plugin_files = set()
for rel in relative:
    package_dir = os.path.join(config_root, rel)
    if not os.path.isdir(package_dir):
        missing.append(rel)
        continue
    for dirpath, _dirnames, filenames in os.walk(package_dir):
        for name in filenames:
            full = os.path.join(dirpath, name)
            expected_plugin_files.add(os.path.relpath(full, config_root))

# The OpenCode 2 plugin packages live under `plugin-packages/`: every
# directory below it is a package.
actual_plugin_files = set()
actual_plugin_dirs = set()
if overlay_root:
    plugins_root = os.path.join(overlay_root, "plugin-packages")
    if os.path.isdir(plugins_root):
        for name in sorted(os.listdir(plugins_root)):
            if os.path.isdir(os.path.join(plugins_root, name)):
                actual_plugin_dirs.add(os.path.join("plugin-packages", name))
        for dirpath, _dirnames, filenames in os.walk(plugins_root):
            for name in filenames:
                full = os.path.join(dirpath, name)
                actual_plugin_files.add(os.path.relpath(full, overlay_root))

print(json.dumps({
    "declared": packages,
    "local": local,
    "missing": sorted(missing),
    "expected_plugin_files": sorted(expected_plugin_files),
    "actual_plugin_files": sorted(actual_plugin_files),
    "expected_plugin_dirs": sorted(relative),
    "actual_plugin_dirs": sorted(actual_plugin_dirs),
    "orphans": sorted(actual_plugin_dirs - set(relative)),
    "orphan_files": sorted(actual_plugin_files - expected_plugin_files),
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

  local fixture_repo installer uninstaller installed_config overlay_root plugin_packages_dir
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  installer="$fixture_repo/open-code/install-opencode.sh"
  uninstaller="$fixture_repo/open-code/uninstall-opencode.sh"
  installed_config="$tmp_home/.config/opencode-forge/opencode.jsonc"
  overlay_root="$tmp_home/.config/opencode-forge"
  plugin_packages_dir="$overlay_root/plugin-packages"

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
  # relationship. OpenCode 2 declares the plugins in `plugins` and a declared
  # local plugin is a PACKAGE DIRECTORY, so the inventory is computed over
  # package trees: a package that vanishes (or an extra one that appears)
  # breaks the overlay silently.
  local source_inventory installed_inventory
  if source_inventory="$(plugin_inventory "$FORGE_ROOT/open-code/opencode.jsonc")" \
    && installed_inventory="$(plugin_inventory "$installed_config" "$overlay_root")"; then
    local source_declared installed_declared missing_count orphan_count expected_count actual_count
    source_declared="$(printf '%s' "$source_inventory" | jq -c '.declared')"
    installed_declared="$(printf '%s' "$installed_inventory" | jq -c '.declared')"
    missing_count="$(printf '%s' "$installed_inventory" | jq -r '.missing | length')"
    orphan_count="$(printf '%s' "$installed_inventory" | jq -r '.orphans | length')"
    expected_count="$(printf '%s' "$installed_inventory" | jq -r '.expected_plugin_files | length')"
    actual_count="$(printf '%s' "$installed_inventory" | jq -r '.actual_plugin_files | length')"

    if [ "$source_declared" = "$installed_declared" ]; then
      pass "installed config plugins field matches repository opencode.jsonc"
    else
      fail "installed config plugins field diverges from repository opencode.jsonc (repo=$source_declared installed=$installed_declared)"
    fi

    if [ "$missing_count" -eq 0 ]; then
      pass "every plugin declared by installed config is present on disk"
    else
      fail "installed config declares missing plugins: $(printf '%s' "$installed_inventory" | jq -r '.missing | join(", ")')"
    fi

    if [ "$orphan_count" -eq 0 ]; then
      pass "every plugin package present on disk is declared by installed config"
    else
      fail "installed plugin packages contain orphan packages: $(printf '%s' "$installed_inventory" | jq -r '.orphans | join(", ")')"
    fi

    if [ "$missing_count" -eq 0 ] && [ "$orphan_count" -eq 0 ] \
      && [ "$expected_count" -eq "$actual_count" ]; then
      pass "installed plugin packages contain exactly the declared plugins (${actual_count} files)"
    else
      fail "installed plugin packages are not an exact match (expected=$expected_count actual=$actual_count missing=$missing_count orphans=$orphan_count)"
    fi

    # The installed package must be a byte-identical copy of the source tree.
    local source_files installed_files
    source_files="$(printf '%s' "$source_inventory" | jq -c '.expected_plugin_files')"
    installed_files="$(printf '%s' "$installed_inventory" | jq -c '.actual_plugin_files')"
    if [ "$source_files" = "$installed_files" ]; then
      pass "installed plugin package tree matches the repository source tree"
    else
      fail "installed plugin package tree diverges from the source (source=$source_files installed=$installed_files)"
    fi

    # The OpenCode 2 layout: a package DIRECTORY, never a single .js file.
    if [ -f "$plugin_packages_dir/forge-guard/index.js" ] \
      && [ -f "$plugin_packages_dir/forge-guard/package.json" ] \
      && [ ! -e "$plugin_packages_dir/forge-guard.js" ]; then
      pass "forge-guard is installed as an OpenCode 2 plugin package directory"
    else
      fail "forge-guard is not installed as an OpenCode 2 plugin package directory"
    fi

    # The removed V1 observer must not be declared: the V1 layout was a `.js`
    # file, the V2 layout is a package directory.
    local declared_js_count
    declared_js_count="$(printf '%s' "$installed_inventory" | jq -r '[.declared[] | select(endswith(".js"))] | length')"
    if [ "$declared_js_count" -eq 0 ]; then
      pass "the installed config declares no OpenCode 1 plugin file (the observer was removed)"
    else
      fail "the installed config still declares OpenCode 1 plugin files"
    fi

    # The OpenCode 1 leftovers must not survive the migration.
    if [ ! -e "$overlay_root/plugins" ]; then
      pass "the overlay contains no OpenCode 1 plugins directory"
    else
      fail "the overlay still contains an OpenCode 1 plugins directory: $(find "$overlay_root/plugins" -mindepth 1 2>/dev/null | tr '\n' ' ')"
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

  # The launcher must resolve the isolated overlay and the OpenCode 2 plugin
  # package. The OpenCode 1 plugin files must not appear anywhere.
  if grep -qF "OPENCODE_CONFIG_DIR=$overlay_root" "$tmp_home/debug-config.out" \
    && grep -qF '"./plugin-packages/forge-guard"' "$tmp_home/debug-config.out" \
    && grep -q '"default_agent": "orchestrator"' "$tmp_home/debug-config.out"; then
    pass "launcher resolves through symlink and loads the isolated config with the V2 plugin package"
  else
    fail "launcher did not load the isolated config with the V2 plugin package"
  fi

  # The OpenCode 1 observer plugin must not come back: OpenCode 2 propagates
  # the failure of a subagent call to the parent session on its own, so no
  # parallel observer exists anymore. The V1 layout was a `.js` file under
  # `plugins/`; the V2 layout is a package directory under `plugin-packages/`.
  if grep -qF 'plugins/forge-' "$tmp_home/debug-config.out"; then
    fail "the installed config still declares an OpenCode 1 plugin file"
  else
    pass "the installed config does not declare any OpenCode 1 plugin file"
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
  if [ -d "$plugin_packages_dir" ]; then
    plugin_leftovers="$(find "$plugin_packages_dir" -mindepth 1 -print 2>/dev/null)"
  fi
  if [ -z "$plugin_leftovers" ]; then
    pass "uninstall removes the installed plugin package tree"
  else
    fail "uninstall left plugin entries behind: $plugin_leftovers"
  fi

  if [ ! -e "$overlay_root/plugins" ]; then
    pass "uninstall does not leave an OpenCode 1 plugins directory behind"
  else
    fail "uninstall left an OpenCode 1 plugins directory behind"
  fi

  # The pinned OpenCode build is Forge owned: uninstall removes its prefix.
  if [ ! -e "$tmp_home/.local/share/forge/opencode-v2" ]; then
    pass "uninstall removes the pinned OpenCode prefix"
  else
    fail "uninstall left the pinned OpenCode prefix behind"
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
  # The bare runner does not provide the fake toolchain: the OpenCode
  # toolchain (npm included) is not reachable, so the install must fail
  # without touching the machine.
  run_isolated_bare "$tmp_home" PATH="/usr/bin:/bin" bash "$root_installer" install --target=opencode >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "install --target=opencode fails cleanly when the OpenCode toolchain is unavailable"
  else
    fail "install --target=opencode unexpectedly succeeded without the OpenCode toolchain"
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
  run_isolated_bare "$tmp_home" PATH="/usr/bin:/bin" bash "$root_installer" install --target=both >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "install --target=both fails non-zero when the OpenCode toolchain is unavailable"
  else
    fail "install --target=both unexpectedly succeeded without the OpenCode toolchain"
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
  create_fake_opencode "$tmp_home"

  # stdin is a pipe here: the installer must not prompt at all (the [ -t 0 ]
  # guard) and must not swallow the piped line.
  local skip_out=""

  skip_out="$(printf 'N\n' | run_isolated "$tmp_home" \
    PATH="$tmp_home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key \
    bash "$installer" 2>&1)" || true

  if [ ! -e "$tmp_home/.opencode-tokens" ]; then
    pass "skip key setup: ~/.opencode-tokens not created"
  else
    fail "skip key setup: ~/.opencode-tokens was unexpectedly created"
  fi

  if printf '%s' "$skip_out" | grep -qF 'Deseas configurar API keys ahora'; then
    fail "skip key setup: the prompt was shown even though stdin is not a terminal"
  else
    pass "skip key setup: no prompt when stdin is not a terminal"
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
  create_fake_opencode "$tmp_home"

  if ! require_pty_support; then
    TMP_TEST_HOME=""
    rm -rf "$tmp_home"
    return
  fi

  run_installer_with_pty "$installer" 's\n1\ntest-key-value\nN\n' "$tmp_home" \
    PATH="$tmp_home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key

  if [ "$PTY_RC" -eq 0 ]; then
    pass "add one key: installer exits 0"
  else
    fail "add one key: installer exited $PTY_RC (expected 0)"
  fi

  if printf '%s' "$PTY_OUT" | grep -qF 'Deseas configurar API keys ahora'; then
    pass "add one key: the interactive prompt was reached through the pty"
  else
    fail "add one key: the interactive prompt was not shown (the setup was not exercised)"
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
  create_fake_opencode "$tmp_home"

  if ! require_pty_support; then
    TMP_TEST_HOME=""
    rm -rf "$tmp_home"
    return
  fi

  local tokens_file="$tmp_home/.opencode-tokens"
  install -m 600 /dev/null "$tokens_file"
  printf 'MINIMAX_API_KEY=old-value\n' >> "$tokens_file"

  run_installer_with_pty "$installer" 's\n1\nnew-value\nN\n' "$tmp_home" \
    PATH="$tmp_home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key

  if [ "$PTY_RC" -eq 0 ]; then
    pass "replace key: installer exits 0"
  else
    fail "replace key: installer exited $PTY_RC (expected 0)"
  fi

  if printf '%s' "$PTY_OUT" | grep -qF 'Deseas configurar API keys ahora'; then
    pass "replace key: the interactive prompt was reached through the pty"
  else
    fail "replace key: the interactive prompt was not shown (the setup was not exercised)"
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

# ---------------------------------------------------------------------------
# The installers must never eat the stdin of whoever invoked them.
#
# The interactive API key setup is guarded by [ -t 0 ], so a piped invocation
# must leave the caller's stdin untouched: the lines the caller piped in have
# to survive the installation and be readable afterwards.
# ---------------------------------------------------------------------------

test_overlay_installer_does_not_consume_caller_stdin() {
  echo ""
  echo "--- test_overlay_installer_does_not_consume_caller_stdin"

  local sandbox home fixture_repo installer leftover
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/stdin-overlay.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  installer="$fixture_repo/open-code/install-opencode.sh"
  create_fake_opencode "$home"

  leftover="$(printf 'L1\nL2\nL3\n' | run_isolated "$home" \
    PATH="$home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key \
    bash -c 'bash "$1" >/dev/null 2>&1; cat' _ "$installer")"

  if [ "$leftover" = "$(printf 'L1\nL2\nL3')" ]; then
    pass "overlay installer leaves the caller stdin untouched"
  else
    fail "overlay installer consumed the caller stdin (leftover='$leftover')"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_install_does_not_consume_caller_stdin() {
  echo ""
  echo "--- test_install_does_not_consume_caller_stdin"

  local sandbox home fixture_repo leftover
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/stdin-install.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"

  leftover="$(printf 'L1\nL2\nL3\n' | run_isolated "$home" \
    PATH="$home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key \
    bash -c 'bash "$1" install --target=opencode >/dev/null 2>&1; cat' _ \
    "$fixture_repo/install.sh")"

  if [ "$leftover" = "$(printf 'L1\nL2\nL3')" ]; then
    pass "install --target=opencode leaves the caller stdin untouched"
  else
    fail "install --target=opencode consumed the caller stdin (leftover='$leftover')"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
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
  # the config still declares the forge-guard package, but its source
  # directory does not exist.
  rm -rf "$fixture_repo/open-code/plugin-packages/forge-guard"

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
    pass "installer aborts with exit 1 when a declared plugin has no source package"
  else
    fail "installer exit code was $exit_code (expected 1 for a missing plugin source)"
  fi

  if grep -q 'has no source package in the overlay' "$tmp_home/install.out"; then
    pass "installer reports the missing declared plugin package"
  else
    fail "installer did not report the missing declared plugin package"
  fi

  if [ ! -e "$installed_config" ]; then
    pass "failed install leaves no installed config referencing the absent plugin"
  else
    local installed_inventory
    if installed_inventory="$(plugin_inventory "$installed_config" "$tmp_home/.config/opencode-forge")" \
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

  # The overlay installer needs a toolchain: the fake one keeps the suite
  # offline and prevents any real installation.
  create_fake_opencode "$SD_HOME"

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
      rm -rf "$SD_OVERLAY/plugin-packages/forge-guard"
      ;;
    agent_deleted)
      rm -f "$SD_OVERLAY/agents/senior.md"
      ;;
    config_deleted)
      rm -f "$SD_OVERLAY/opencode.jsonc"
      ;;
    config_corrupt)
      printf '{\n  "plugins": [ "./plugin-packages/forge-guard",\n}\n' > "$SD_OVERLAY/opencode.jsonc"
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
      EXPECT_NEEDLE="plugin-packages/forge-guard"
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
      # The V2 launcher check reports three records (the mismatch plus the
      # two contract checks), so the needle must identify the BROKEN
      # artefact and not the launcher family.
      EXPECT_NEEDLE="forge-opencode.sh.renamed"
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

assert_equal() {
  local desc="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" = "$expected" ]; then
    pass "$desc"
  else
    fail "$desc (esperado='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local desc="$1"
  local needle="$2"
  local file="$3"

  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    pass "$desc"
  else
    fail "$desc (no contiene '$needle')"
  fi
}

assert_not_contains() {
  local desc="$1"
  local needle="$2"
  local file="$3"

  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    fail "$desc (contiene '$needle')"
  else
    pass "$desc"
  fi
}

assert_no_route_warning() {
  local desc="$1"
  local file="$2"

  if grep -qE '(WARN.*OPENCODE_CONFIG(_DIR)?|OPENCODE_CONFIG(_DIR)?.*WARN)' "$file" 2>/dev/null; then
    fail "$desc"
  else
    pass "$desc"
  fi
}

manifest_opencode_value() {
  local state_file="$1"
  local field="$2"

  jq -r --arg field "$field" \
    '[.targets_manifest[]? | select(.name == "opencode")][0] | (.[$field] // empty)' \
    "$state_file" 2>/dev/null || true
}

# The fake toolchain: a fake npm (that materialises the pinned build instead
# of downloading it) and a fake OpenCode CLI. The suite never installs
# anything in the machine.
create_fake_opencode() {
  local home="$1"

  forge_make_toolchain "$home/fakebin"
}

install_opencode_fixture() {
  local home="$1"
  local repo="$2"
  shift 2

  run_isolated "$home" \
    PATH="$home/fakebin:$PATH" \
    OPENAI_API_KEY=test-openai-key \
    "$@" \
    bash "$repo/install.sh" install --target=opencode
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

# ---------------------------------------------------------------------------
# Durable coverage for the effective OpenCode paths recorded in the manifest.
# The manifest is the source of truth for status/doctor/launcher/uninstall;
# the environment can only produce an actionable warning when it diverges.
# ---------------------------------------------------------------------------

test_manifest_records_default_opencode_paths() {
  echo ""
  echo "--- test_manifest_records_default_opencode_paths"

  local sandbox home fixture_repo state default_dir default_config install_rc=0 status_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-default.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  default_dir="$home/.config/opencode-forge"
  default_config="$default_dir/opencode.jsonc"
  state="$home/.forge-state.json"

  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install opencode sin OPENCODE_CONFIG_DIR termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  assert_equal "manifest dir por defecto es el HOME aislado" \
    "$default_dir" "$(manifest_opencode_value "$state" dir)"
  assert_equal "manifest config_file por defecto apunta a opencode.jsonc" \
    "$default_config" "$(manifest_opencode_value "$state" config_file)"
  assert_equal "state_schema sigue siendo 3" "3" "$(jq -r '.state_schema' "$state")"

  run_isolated "$home" bash "$fixture_repo/install.sh" status \
    > "$sandbox/status.out" 2>&1 || status_rc=$?
  assert_equal "status sale 0 con el overlay por defecto" "0" "$status_rc"
  assert_contains "status diagnostica el overlay registrado por defecto" \
    "OpenCode overlay ($default_dir)" "$sandbox/status.out"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_manifest_records_custom_opencode_dir() {
  echo ""
  echo "--- test_manifest_records_custom_opencode_dir"

  local sandbox home fixture_repo state alt_dir default_dir install_rc=0
  local status_aligned_rc=0 status_unset_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-custom-dir.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/alt-overlay"
  default_dir="$home/.config/opencode-forge"
  state="$home/.forge-state.json"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install opencode con OPENCODE_CONFIG_DIR alternativo termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  assert_equal "manifest dir registra OPENCODE_CONFIG_DIR efectivo" \
    "$alt_dir" "$(manifest_opencode_value "$state" dir)"
  assert_equal "manifest config_file sigue al directorio alternativo" \
    "$alt_dir/opencode.jsonc" "$(manifest_opencode_value "$state" config_file)"

  run_isolated "$home" OPENCODE_CONFIG_DIR="$alt_dir" \
    bash "$fixture_repo/install.sh" status > "$sandbox/status-aligned.out" 2>&1 || status_aligned_rc=$?
  run_isolated "$home" bash "$fixture_repo/install.sh" status \
    > "$sandbox/status-unset.out" 2>&1 || status_unset_rc=$?

  assert_equal "status sale 0 con la variable alternativa exportada" "0" "$status_aligned_rc"
  assert_equal "status sale 0 sin la variable alternativa exportada" "0" "$status_unset_rc"
  assert_contains "status sigue diagnosticando el directorio alternativo" \
    "OpenCode overlay ($alt_dir)" "$sandbox/status-aligned.out"

  if [ ! -e "$default_dir" ]; then
    pass "install alternativo no crea el overlay por defecto"
  else
    fail "install alternativo creó el overlay por defecto ($default_dir)"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_manifest_records_external_opencode_config() {
  echo ""
  echo "--- test_manifest_records_external_opencode_config"

  local sandbox home fixture_repo state default_dir external_config external_root
  local install_rc=0 status_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-external-config.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  default_dir="$home/.config/opencode-forge"
  external_config="$sandbox/external-config/opencode.jsonc"
  external_root="$(dirname "$external_config")"
  state="$home/.forge-state.json"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG="$external_config" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install opencode con OPENCODE_CONFIG externo termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  assert_equal "manifest dir conserva CONFIG_DIR cuando la config es externa" \
    "$default_dir" "$(manifest_opencode_value "$state" dir)"
  assert_equal "manifest config_file registra la config externa real" \
    "$external_config" "$(manifest_opencode_value "$state" config_file)"

  if [ -f "$external_config" ] && [ -f "$external_root/plugin-packages/forge-guard/index.js" ]; then
    pass "config y el paquete de plugins se despliegan junto a OPENCODE_CONFIG"
  else
    fail "config/plugin package no se desplegaron junto a OPENCODE_CONFIG"
  fi

  if [ -f "$default_dir/agents/orchestrator.md" ] \
    && [ -f "$default_dir/commands/create-plan.md" ] \
    && [ -f "$default_dir/AGENTS.md" ]; then
    pass "agentes, comandos y AGENTS.md permanecen en CONFIG_DIR"
  else
    fail "el overlay no se repartió entre CONFIG_DIR y la config externa"
  fi

  if [ ! -e "$default_dir/opencode.jsonc" ]; then
    pass "no se crea una config duplicada en el directorio por defecto"
  else
    fail "se creó una config duplicada en $default_dir"
  fi

  run_isolated "$home" bash "$fixture_repo/install.sh" status \
    > "$sandbox/status.out" 2>&1 || status_rc=$?
  assert_equal "status sale 0 validando la config externa registrada" "0" "$status_rc"

  if grep -qF 'opencode.jsonc: JSONC valido' "$sandbox/status.out"; then
    pass "status valida la config en su ruta real"
  else
    fail "status no validó la config externa"
  fi

  if grep -qF 'plugin-packages/forge-guard: declarado por opencode.jsonc y presente en disco' \
    "$sandbox/status.out"; then
    pass "status valida el paquete de plugins junto a la config externa"
  else
    fail "status no validó el paquete de plugins de la config externa"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_status_and_doctor_warn_on_route_divergence() {
  echo ""
  echo "--- test_status_and_doctor_warn_on_route_divergence"

  local sandbox home fixture_repo alt_dir other_dir install_rc=0 status_rc=0 doctor_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-divergence.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  other_dir="$sandbox/environment-overlay"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para divergencia termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  run_isolated "$home" OPENCODE_CONFIG_DIR="$other_dir" \
    bash "$fixture_repo/install.sh" status > "$sandbox/status-dir.out" 2>&1 || status_rc=$?
  assert_equal "status sale 0 aunque OPENCODE_CONFIG_DIR contradiga el manifest" "0" "$status_rc"
  assert_contains "status WARN de divergencia menciona la ruta del entorno" \
    "OPENCODE_CONFIG_DIR apunta a $other_dir" "$sandbox/status-dir.out"
  assert_contains "status WARN de divergencia menciona la ruta registrada" \
    "el overlay está instalado en $alt_dir" "$sandbox/status-dir.out"
  assert_contains "status WARN incluye un hint accionable" \
    "desexporta OPENCODE_CONFIG_DIR" "$sandbox/status-dir.out"
  assert_contains "status diagnostica el overlay registrado" \
    "OpenCode overlay ($alt_dir)" "$sandbox/status-dir.out"
  assert_not_contains "status no diagnostica el overlay contradictorio" \
    "OpenCode overlay ($other_dir)" "$sandbox/status-dir.out"

  run_isolated "$home" OPENCODE_CONFIG="$other_dir/opencode.jsonc" \
    bash "$fixture_repo/install.sh" status > "$sandbox/status-config.out" 2>&1 || status_rc=$?
  assert_equal "status sale 0 aunque OPENCODE_CONFIG contradiga el manifest" "0" "$status_rc"
  assert_contains "status WARN de config menciona la ruta del entorno" \
    "OPENCODE_CONFIG apunta a $other_dir/opencode.jsonc" "$sandbox/status-config.out"
  assert_contains "status WARN de config menciona la config registrada" \
    "la config instalada está en $alt_dir/opencode.jsonc" "$sandbox/status-config.out"
  assert_contains "status WARN de config incluye un hint accionable" \
    "desexporta OPENCODE_CONFIG" "$sandbox/status-config.out"

  run_isolated "$home" OPENCODE_CONFIG_DIR="$other_dir" \
    bash "$fixture_repo/install.sh" doctor > "$sandbox/doctor.out" 2>&1 || doctor_rc=$?
  assert_equal "doctor sale 0 con una ruta divergente" "0" "$doctor_rc"
  assert_contains "doctor WARN de divergencia menciona la ruta del entorno" \
    "OPENCODE_CONFIG_DIR apunta a $other_dir" "$sandbox/doctor.out"
  assert_contains "doctor WARN de divergencia menciona la ruta registrada" \
    "el overlay está instalado en $alt_dir" "$sandbox/doctor.out"
  assert_contains "doctor WARN de divergencia incluye HINT" \
    "HINT  desexporta OPENCODE_CONFIG_DIR" "$sandbox/doctor.out"

  if grep -qE 'Resumen: FAILs=0[[:space:]]+WARNs=[1-9][0-9]*' "$sandbox/doctor.out"; then
    pass "doctor resume FAILs=0 y al menos un WARN"
  else
    fail "doctor no resume FAILs=0 con WARNs positivos"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_status_and_doctor_do_not_warn_without_route_divergence() {
  echo ""
  echo "--- test_status_and_doctor_do_not_warn_without_route_divergence"

  local sandbox home fixture_repo alt_dir install_rc=0
  local status_unset_rc=0 doctor_unset_rc=0 status_aligned_rc=0 doctor_aligned_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-no-divergence.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia sin divergencia termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  run_isolated "$home" bash "$fixture_repo/install.sh" status \
    > "$sandbox/status-unset.out" 2>&1 || status_unset_rc=$?
  run_isolated "$home" bash "$fixture_repo/install.sh" doctor \
    > "$sandbox/doctor-unset.out" 2>&1 || doctor_unset_rc=$?
  run_isolated "$home" OPENCODE_CONFIG_DIR="$alt_dir" OPENCODE_CONFIG="$alt_dir/opencode.jsonc" \
    bash "$fixture_repo/install.sh" status > "$sandbox/status-aligned.out" 2>&1 || status_aligned_rc=$?
  run_isolated "$home" OPENCODE_CONFIG_DIR="$alt_dir" OPENCODE_CONFIG="$alt_dir/opencode.jsonc" \
    bash "$fixture_repo/install.sh" doctor > "$sandbox/doctor-aligned.out" 2>&1 || doctor_aligned_rc=$?

  assert_equal "status sin variables exportadas sale 0" "0" "$status_unset_rc"
  assert_equal "doctor sin variables exportadas sale 0" "0" "$doctor_unset_rc"
  assert_equal "status con entorno alineado sale 0" "0" "$status_aligned_rc"
  assert_equal "doctor con entorno alineado sale 0" "0" "$doctor_aligned_rc"

  assert_no_route_warning "status sin variables exportadas no avisa de rutas" "$sandbox/status-unset.out"
  assert_no_route_warning "doctor sin variables exportadas no avisa de rutas" "$sandbox/doctor-unset.out"
  assert_no_route_warning "status con entorno alineado no avisa de rutas" "$sandbox/status-aligned.out"
  assert_no_route_warning "doctor con entorno alineado no avisa de rutas" "$sandbox/doctor-aligned.out"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_launcher_uses_manifest_paths() {
  echo ""
  echo "--- test_launcher_uses_manifest_paths"

  local sandbox home fixture_repo alt_dir other_dir launcher install_rc=0 launch_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-launcher.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  other_dir="$sandbox/environment-overlay"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para launcher termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  cat > "$home/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-}"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}"
EOF
  chmod +x "$home/fakebin/opencode"
  launcher="$home/.local/bin/forge-opencode"

  run_isolated "$home" PATH="$home/fakebin:$PATH" "$launcher" \
    > "$sandbox/launcher-unset.out" 2> "$sandbox/launcher-unset.err" || launch_rc=$?
  assert_equal "launcher sin entorno contradictorio sale 0" "0" "$launch_rc"
  assert_contains "launcher exporta el directorio registrado" \
    "OPENCODE_CONFIG_DIR=$alt_dir" "$sandbox/launcher-unset.out"
  assert_contains "launcher exporta la config registrada" \
    "OPENCODE_CONFIG=$alt_dir/opencode.jsonc" "$sandbox/launcher-unset.out"

  if [ ! -s "$sandbox/launcher-unset.err" ]; then
    pass "launcher sin divergencia no escribe avisos"
  else
    fail "launcher sin divergencia escribió avisos inesperados"
  fi

  launch_rc=0
  run_isolated "$home" PATH="$home/fakebin:$PATH" \
    OPENCODE_CONFIG_DIR="$other_dir" OPENCODE_CONFIG="$other_dir/opencode.jsonc" \
    "$launcher" > "$sandbox/launcher-divergent.out" 2> "$sandbox/launcher-divergent.err" || launch_rc=$?
  assert_equal "launcher con entorno contradictorio sale 0" "0" "$launch_rc"
  assert_contains "launcher sigue exportando el directorio registrado" \
    "OPENCODE_CONFIG_DIR=$alt_dir" "$sandbox/launcher-divergent.out"
  assert_contains "launcher sigue exportando la config registrada" \
    "OPENCODE_CONFIG=$alt_dir/opencode.jsonc" "$sandbox/launcher-divergent.out"
  assert_contains "launcher avisa por stderr de OPENCODE_CONFIG_DIR divergente" \
    "OPENCODE_CONFIG_DIR=$other_dir no coincide con el overlay instalado en $alt_dir" \
    "$sandbox/launcher-divergent.err"
  assert_contains "launcher avisa por stderr de OPENCODE_CONFIG divergente" \
    "OPENCODE_CONFIG=$other_dir/opencode.jsonc no coincide con la config instalada en $alt_dir/opencode.jsonc" \
    "$sandbox/launcher-divergent.err"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_uninstall_removes_registered_overlay() {
  echo ""
  echo "--- test_uninstall_removes_registered_overlay"

  local sandbox home fixture_repo alt_dir other_dir uninstall_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-uninstall.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  other_dir="$sandbox/environment-overlay"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || uninstall_rc=$?
  assert_equal "install de referencia para uninstall termina correctamente" "0" "$uninstall_rc"

  if [ "$uninstall_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  mkdir -p "$other_dir"
  printf 'do-not-delete\n' > "$other_dir/marker.txt"
  printf '{}\n' > "$other_dir/opencode.jsonc"

  uninstall_rc=0
  run_isolated "$home" OPENCODE_CONFIG_DIR="$other_dir" OPENCODE_CONFIG="$other_dir/opencode.jsonc" \
    bash "$fixture_repo/install.sh" uninstall > "$sandbox/uninstall.out" 2>&1 || uninstall_rc=$?
  assert_equal "uninstall con entorno divergente sale 0" "0" "$uninstall_rc"

  # Contract: the uninstaller removes EVERY Forge artefact of the overlay.
  # The OpenCode 2 plugin is a package DIRECTORY, so the whole
  # plugin-packages/forge-guard tree must be gone.
  local overlay_leftovers=""
  if [ -d "$alt_dir" ]; then
    overlay_leftovers="$(find "$alt_dir" -mindepth 1 2>/dev/null)"
  fi
  if [ -z "$overlay_leftovers" ]; then
    pass "uninstall no deja ningun artefacto de Forge en el overlay"
  else
    fail "uninstall dejo artefactos de Forge en el overlay: $(printf '%s' "$overlay_leftovers" | tr '\n' ' ')"
  fi

  if [ ! -e "$alt_dir/plugin-packages/forge-guard" ]; then
    pass "uninstall borra el arbol del paquete de plugins V2"
  else
    fail "uninstall dejo el arbol del paquete de plugins V2"
  fi

  if [ ! -e "$alt_dir" ]; then
    pass "uninstall borra el overlay registrado"
  else
    fail "uninstall no borró el overlay registrado ($alt_dir): quedan $(find "$alt_dir" -mindepth 1 2>/dev/null | tr '\n' ' ')"
  fi

  if [ -f "$other_dir/marker.txt" ] && [ -f "$other_dir/opencode.jsonc" ]; then
    pass "uninstall no toca el overlay señalado por el entorno"
  else
    fail "uninstall tocó el overlay contradictorio del entorno"
  fi

  if [ ! -e "$home/.forge-state.json" ]; then
    pass "uninstall borra el state file"
  else
    fail "uninstall no borró el state file"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_launcher_enforces_the_v2_isolation() {
  echo ""
  echo "--- test_launcher_enforces_the_v2_isolation"

  local sandbox home fixture_repo launcher install_rc=0 launch_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-launcher-v2.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"

  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para el launcher V2 termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  launcher="$home/.local/bin/forge-opencode"

  # OpenCode 2 shares a background server by default: the launcher must
  # always request a private one.
  run_isolated "$home" "$launcher" models > "$sandbox/launcher-models.out" 2>&1 || launch_rc=$?
  assert_equal "launcher con subcomando sale 0" "0" "$launch_rc"
  assert_contains "launcher pasa --standalone al CLI" \
    "ARGV=models --standalone" "$sandbox/launcher-models.out"

  launch_rc=0
  run_isolated "$home" "$launcher" > "$sandbox/launcher-bare.out" 2>&1 || launch_rc=$?
  assert_equal "launcher sin subcomando sale 0" "0" "$launch_rc"
  assert_contains "launcher sin subcomando pasa --standalone primero" \
    "ARGV=--standalone" "$sandbox/launcher-bare.out"

  # The leaf subcommands do not offer --standalone: they run inside the CLI
  # process and never attach to the shared server.
  run_isolated "$home" "$launcher" debug config > "$sandbox/launcher-debug.out" 2>&1 || launch_rc=$?
  assert_contains "launcher no pasa --standalone a los subcomandos hoja" \
    "ARGV=debug config" "$sandbox/launcher-debug.out"

  # Attaching to a shared server is exactly what the isolation forbids.
  launch_rc=0
  run_isolated "$home" "$launcher" --server http://127.0.0.1:1 models \
    > "$sandbox/launcher-server.out" 2>&1 || launch_rc=$?
  assert_equal "launcher rechaza --server con codigo 2" "2" "$launch_rc"
  assert_contains "launcher explica por que rechaza --server" \
    "--server no se admite" "$sandbox/launcher-server.out"

  launch_rc=0
  run_isolated "$home" "$launcher" --server=http://127.0.0.1:1 models \
    > "$sandbox/launcher-server-eq.out" 2>&1 || launch_rc=$?
  assert_equal "launcher rechaza --server=<url> con codigo 2" "2" "$launch_rc"
  assert_contains "launcher explica por que rechaza --server=<url>" \
    "--server no se admite" "$sandbox/launcher-server-eq.out"

  if grep -q 'ARGV=' "$sandbox/launcher-server.out" "$sandbox/launcher-server-eq.out"; then
    fail "el launcher ejecutó el binario de OpenCode pese a rechazar --server"
  else
    pass "el launcher no ejecuta el binario de OpenCode cuando se rechaza --server"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_pinned_binary_lives_in_the_isolated_prefix() {
  echo ""
  echo "--- test_pinned_binary_lives_in_the_isolated_prefix"

  local sandbox home fixture_repo state install_rc=0
  local expected_prefix expected_binary recorded_binary
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-pinned.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  state="$home/.forge-state.json"

  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para el binario pinado termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  expected_prefix="$home/.local/share/forge/opencode-v2"
  expected_binary="$expected_prefix/node_modules/.bin/opencode"
  recorded_binary="$(manifest_opencode_value "$state" binary)"

  assert_equal "el manifest registra la ruta del binario pinado aislado" \
    "$expected_binary" "$recorded_binary"

  if [ -x "$expected_binary" ]; then
    pass "el binario pinado se instala en el prefijo aislado de Forge"
  else
    fail "el binario pinado no se instaló en el prefijo aislado ($expected_binary)"
  fi

  local reported_version
  reported_version="$("$expected_binary" --version 2>/dev/null | tr -d ' \n' || true)"
  assert_equal "el binario pinado reporta la version fijada" \
    "opencodev2.1.4" "$reported_version"

  if [ ! -e "$home/.local/share/forge/opencode-v2/node_modules/@opencode" ]; then
    pass "el prefijo pinado no se instala fuera del sandbox"
  else
    fail "el prefijo pinado se instaló fuera del sandbox"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_manifest_records_opencode_paths_for_both_target() {
  echo ""
  echo "--- test_manifest_records_opencode_paths_for_both_target"

  local sandbox home fixture_repo state alt_dir install_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-both-target.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/alt-overlay"
  state="$home/.forge-state.json"

  run_isolated "$home" PATH="$home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key \
    OPENCODE_CONFIG_DIR="$alt_dir" bash "$fixture_repo/install.sh" install --target=both \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install --target=both termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  assert_equal "manifest opencode de target=both registra el dir efectivo" \
    "$alt_dir" "$(manifest_opencode_value "$state" dir)"
  assert_equal "manifest opencode de target=both registra config_file" \
    "$alt_dir/opencode.jsonc" "$(manifest_opencode_value "$state" config_file)"
  assert_equal "target=both conserva state_schema 3" "3" "$(jq -r '.state_schema' "$state")"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_legacy_manifest_without_config_file() {
  echo ""
  echo "--- test_legacy_manifest_without_config_file"

  local sandbox home fixture_repo state default_dir other_config install_rc=0 status_rc=0
  local state_sha_before state_mtime_before state_sha_after state_mtime_after
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-legacy.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  default_dir="$home/.config/opencode-forge"
  other_config="$sandbox/other/opencode.jsonc"
  state="$home/.forge-state.json"

  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia legacy termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  jq '(.targets_manifest[] | select(.name == "opencode")) |= del(.config_file)' \
    "$state" > "$sandbox/state.legacy.json"
  mv "$sandbox/state.legacy.json" "$state"

  assert_equal "el manifest legacy no contiene config_file" "" \
    "$(manifest_opencode_value "$state" config_file)"
  state_sha_before="$(sha256sum "$state" | cut -d' ' -f1)"
  state_mtime_before="$(stat -c '%y' "$state")"

  run_isolated "$home" OPENCODE_CONFIG="$other_config" \
    bash "$fixture_repo/install.sh" status > "$sandbox/status.out" 2>&1 || status_rc=$?
  assert_equal "status sale 0 con manifest legacy sin config_file" "0" "$status_rc"
  assert_contains "status usa el fallback de config del overlay registrado" \
    "OpenCode overlay ($default_dir)" "$sandbox/status.out"
  assert_no_route_warning "status legacy no inventa un WARN de config" "$sandbox/status.out"

  if grep -qF 'opencode.jsonc: JSONC valido' "$sandbox/status.out"; then
    pass "status valida el fallback <dir>/opencode.jsonc"
  else
    fail "status no validó el fallback <dir>/opencode.jsonc"
  fi

  state_sha_after="$(sha256sum "$state" | cut -d' ' -f1)"
  state_mtime_after="$(stat -c '%y' "$state")"
  assert_equal "status legacy no reescribe el state file" \
    "$state_sha_before" "$state_sha_after"
  assert_equal "status legacy no cambia el mtime del state file" \
    "$state_mtime_before" "$state_mtime_after"
  assert_equal "status legacy no inyecta config_file" "" \
    "$(manifest_opencode_value "$state" config_file)"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_update_and_repair_sync_opencode_paths() {
  echo ""
  echo "--- test_update_and_repair_sync_opencode_paths"

  local sandbox home fixture_repo state route_a route_b route_c
  local install_rc=0 update_rc=0 repair_rc=0 status_update_rc=0 status_repair_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-update-repair.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  route_a="$sandbox/route-a"
  route_b="$sandbox/route-b"
  route_c="$sandbox/route-c"
  state="$home/.forge-state.json"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$route_a" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install inicial para update/repair termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  run_isolated "$home" PATH="$home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key \
    OPENCODE_CONFIG_DIR="$route_b" bash "$fixture_repo/install.sh" update \
    > "$sandbox/update.out" 2>&1 || update_rc=$?
  assert_equal "update con nueva ruta termina correctamente" "0" "$update_rc"
  assert_equal "update sincroniza el manifest con el nuevo dir" \
    "$route_b" "$(manifest_opencode_value "$state" dir)"
  assert_equal "update sincroniza el manifest con el nuevo config_file" \
    "$route_b/opencode.jsonc" "$(manifest_opencode_value "$state" config_file)"

  run_isolated "$home" bash "$fixture_repo/install.sh" status \
    > "$sandbox/status-after-update.out" 2>&1 || status_update_rc=$?
  assert_equal "status valida el overlay reinstalado por update" "0" "$status_update_rc"
  assert_contains "status diagnostica la ruta reinstalada por update" \
    "OpenCode overlay ($route_b)" "$sandbox/status-after-update.out"

  run_isolated "$home" PATH="$home/fakebin:$PATH" OPENAI_API_KEY=test-openai-key \
    OPENCODE_CONFIG_DIR="$route_c" bash "$fixture_repo/install.sh" repair \
    > "$sandbox/repair.out" 2>&1 || repair_rc=$?
  assert_equal "repair con nueva ruta termina correctamente" "0" "$repair_rc"
  assert_equal "repair sincroniza el manifest con el nuevo dir" \
    "$route_c" "$(manifest_opencode_value "$state" dir)"
  assert_equal "repair sincroniza el manifest con el nuevo config_file" \
    "$route_c/opencode.jsonc" "$(manifest_opencode_value "$state" config_file)"

  run_isolated "$home" bash "$fixture_repo/install.sh" status \
    > "$sandbox/status-after-repair.out" 2>&1 || status_repair_rc=$?
  assert_equal "status valida el overlay reinstalado por repair" "0" "$status_repair_rc"
  assert_contains "status diagnostica la ruta reinstalada por repair" \
    "OpenCode overlay ($route_c)" "$sandbox/status-after-repair.out"
  assert_equal "update/repair conservan state_schema 3" "3" "$(jq -r '.state_schema' "$state")"

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
test_overlay_installer_does_not_consume_caller_stdin
test_install_does_not_consume_caller_stdin
test_status_doctor_healthy_overlay
test_status_doctor_do_not_write
test_status_doctor_report_each_opencode_break
test_manifest_records_default_opencode_paths
test_manifest_records_custom_opencode_dir
test_manifest_records_external_opencode_config
test_status_and_doctor_warn_on_route_divergence
test_status_and_doctor_do_not_warn_without_route_divergence
test_launcher_uses_manifest_paths
test_launcher_enforces_the_v2_isolation
test_pinned_binary_lives_in_the_isolated_prefix
test_uninstall_removes_registered_overlay
test_manifest_records_opencode_paths_for_both_target
test_legacy_manifest_without_config_file
test_update_and_repair_sync_opencode_paths

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
