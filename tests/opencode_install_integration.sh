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

  # The containment closes every contained scenario: the kernel tears the
  # private PID namespace down when its PID 1 exits, so no process of a
  # fixture can outlive the run that created it. There is no observer to stop
  # and no registry to sweep.
  #
  # What the suite DOES owe is the evidence: when a contained run could not
  # be certified, the sandbox and the receipts are KEPT and their location is
  # reported, because a failed closure must never look like a clean run.
  if [ -s "${FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE:-}" ]; then
    FORGE_CONTAINMENT_FAILED_RECEIPTS="$(cat "$FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE")"
    echo "  FAIL  hay corridas contenidas que no se pudieron certificar; sus recibos se conservan:" >&2
    printf '%s\n' "$FORGE_CONTAINMENT_FAILED_RECEIPTS" | sed 's/^/        /' >&2
    echo "        el sandbox de la suite se conserva en $TEST_TMP_ROOT" >&2
    rc=1
  else
    if [ -n "${TMP_TEST_HOME:-}" ]; then
      rm -rf "$TMP_TEST_HOME"
    fi
    if [ -n "${TEST_TMP_ROOT:-}" ]; then
      rm -rf "$TEST_TMP_ROOT"
    fi
  fi

  # The leak guard: the suite must never create the real pinned prefix and
  # must never modify the real user files. The prefix is compared with the
  # state BEFORE the run: on a machine where OpenCode is really installed the
  # prefix preexists and that is NOT a failure, but a creation or a deletion
  # would be.
  if ! forge_assert_no_forge_prefix "$PROTECTED_SNAPSHOT"; then
    rc=1
  fi
  if ! forge_assert_protected_unchanged "$PROTECTED_SNAPSHOT"; then
    rc=1
  fi

  exit $rc
}

mkdir -p "$TEST_TMP_ROOT"
# The receipts of the contained runs that could NOT be certified are
# recorded here: they are the evidence of a failure and they are never
# deleted to make the suite look clean.
FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE="$TEST_TMP_ROOT/failed-receipts.txt"
: > "$FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE"
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

  local fixture_repo uninstaller installed_config overlay_root plugin_packages_dir
  local manifest pinned_binary install_rc=0 launch_rc=0
  fixture_repo="$(create_repo_fixture "$tmp_home/repo")"
  uninstaller="$fixture_repo/open-code/uninstall-opencode.sh"
  installed_config="$tmp_home/.config/opencode-forge/opencode.jsonc"
  overlay_root="$tmp_home/.config/opencode-forge"
  plugin_packages_dir="$overlay_root/plugin-packages"
  manifest="$tmp_home/.forge-state.json"
  pinned_binary="$tmp_home/.local/share/forge/opencode-v2/node_modules/.bin/opencode"

  # The launcher reads the Forge manifest, so the fixture installs the way the
  # user does: the ROOT installer runs the overlay installer and then writes
  # the manifest that records the pinned binary and the config file of the
  # opencode target. Running the overlay installer alone leaves no manifest
  # behind, and the launcher is then expected to fail closed (that is a
  # different contract, covered by its own case).
  install_opencode_fixture "$tmp_home" "$fixture_repo" > "$tmp_home/install.out" 2>&1 || install_rc=$?
  if [ "$install_rc" -ne 0 ]; then
    fail "la instalacion de referencia del overlay aislado fallo (rc=$install_rc)"
    sed -n '1,20p' "$tmp_home/install.out" | sed 's/^/      /' >&2
    TMP_TEST_HOME=""
    rm -rf "$tmp_home"
    return
  fi

  # The manifest is the ONLY authority of the launcher: it must exist, be
  # valid JSON and record the effective paths of the opencode target.
  if [ -f "$manifest" ] && jq empty "$manifest" >/dev/null 2>&1; then
    pass "el instalador deja el manifiesto de Forge en el HOME aislado"
  else
    fail "el instalador no dejo un manifiesto de Forge valido ($manifest)"
  fi
  assert_equal "el manifiesto registra el directorio efectivo del overlay" \
    "$overlay_root" "$(manifest_opencode_value "$manifest" dir)"
  assert_equal "el manifiesto registra el config_file del target opencode" \
    "$installed_config" "$(manifest_opencode_value "$manifest" config_file)"
  assert_equal "el manifiesto registra el binario pinado del prefijo aislado" \
    "$pinned_binary" "$(manifest_opencode_value "$manifest" binary)"

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

  # The launcher runs the PINNED binary recorded in the manifest, never the
  # `opencode` of the PATH. The decoy below is the ONLY `opencode` in the
  # PATH and it must never run: a launcher that falls back to the generic
  # binary would resurrect the OpenCode V1 of the machine.
  mkdir -p "$tmp_home/fakebin"
  cat > "$tmp_home/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
printf 'PATH-DECOY-OPENCODE\n'
EOF
  chmod +x "$tmp_home/fakebin/opencode"

  # The pinned binary is replaced by a fake that reports what the launcher
  # passed to it: the config it resolved and the token loaded from
  # ~/.opencode-tokens through env.sh.
  #
  # The replacement happens on the EXECUTABLE of the package: the entry of
  # `.bin` must keep resolving to it, or the launcher would refuse to run it
  # (the accreditation of the pinned package).
  cat > "$tmp_home/.local/share/forge/opencode-v2/node_modules/@opencode/cli/bin/opencode" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "${OPENAI_API_KEY:-missing}"
printf 'ARGV=%s\n' "$*"
printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-}"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}"
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "${OPENCODE_CONFIG:-}" ]; then
  printf '%s\n' '--- CONFIG ---'
  cat "${OPENCODE_CONFIG}"
fi
EOF
  chmod +x "$tmp_home/.local/share/forge/opencode-v2/node_modules/@opencode/cli/bin/opencode"

  run_isolated "$tmp_home" PATH="$tmp_home/fakebin:$PATH" "$tmp_home/.local/bin/forge-opencode" \
    debug config > "$tmp_home/debug-config.out" 2> "$tmp_home/debug-config.err" || launch_rc=$?
  if [ "$launch_rc" -ne 0 ]; then
    fail "el launcher no pudo ejecutar el binario pinado del manifiesto (rc=$launch_rc)"
    sed -n '1,10p' "$tmp_home/debug-config.err" | sed 's/^/      /' >&2
  fi

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

  # The generic binary of the PATH is never executed: the launcher only runs
  # the pinned build of the Forge prefix.
  if grep -qF 'PATH-DECOY-OPENCODE' "$tmp_home/debug-config.out"; then
    fail "el launcher ejecuto el opencode del PATH en vez del binario pinado"
  else
    pass "el launcher no ejecuta el opencode del PATH: solo el binario pinado del manifiesto"
  fi

  printf 'OPENAI_API_KEY=file-token\n' > "$tmp_home/.opencode-tokens"

  launch_rc=0
  run_isolated "$tmp_home" PATH="$tmp_home/fakebin:$PATH" "$tmp_home/.local/bin/forge-opencode" \
    > "$tmp_home/launcher-env.out" 2> "$tmp_home/launcher-env.err" || launch_rc=$?
  if [ "$launch_rc" -ne 0 ]; then
    fail "el launcher sin subcomando no pudo ejecutar el binario pinado (rc=$launch_rc)"
    sed -n '1,10p' "$tmp_home/launcher-env.err" | sed 's/^/      /' >&2
  fi

  if grep -q '^file-token$' "$tmp_home/launcher-env.out"; then
    pass "launcher loads OPENAI_API_KEY from ~/.opencode-tokens via env.sh"
  else
    fail "launcher did not load OPENAI_API_KEY from ~/.opencode-tokens"
  fi

  if grep -qF 'PATH-DECOY-OPENCODE' "$tmp_home/launcher-env.out"; then
    fail "el launcher ejecuto el opencode del PATH en vez del binario pinado"
  else
    pass "el launcher no ejecuta el opencode del PATH al arrancar la UI"
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

  # shellcheck disable=SC2016  # literal: es el SCRIPT del bash interno; $1 debe expandirlo ese shell, no el actual
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

  # shellcheck disable=SC2016  # literal: es el SCRIPT del bash interno; $1 debe expandirlo ese shell, no el actual
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

# make_env_sentinel <dir> <label>
# Creates a directory that LOOKS like something the ambient environment could
# point at (an OpenCode overlay or a pinned binary prefix) and fills it with
# sentinel files.
#
# The uninstaller must never touch these paths: the state file is the only
# authority, so a divergent OPENCODE_CONFIG_DIR / OPENCODE_CONFIG /
# FORGE_OPENCODE_BIN_DIR must be ignored, not honoured.
make_env_sentinel() {
  local dir="$1"
  local label="$2"

  mkdir -p "$dir/node_modules/.bin"
  printf '%s\n' "$label" > "$dir/marker.txt"
  printf '{}\n' > "$dir/opencode.jsonc"
  printf '#!/usr/bin/env sh\n' > "$dir/node_modules/.bin/opencode"
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

# ---------------------------------------------------------------------------
# The contract of the diagnostics with a runtime that cannot be exercised.
#
# `install.sh status` and `install.sh doctor` run an OPERATIONAL probe: the
# installed launcher is exercised against a private copy of the installation
# and a private service, and the real plugin list is enumerated. The pinned
# binary of the sandbox is a stand-in that answers only --version and auth
# (its `serve --service` is refused), so the probe cannot run and reports
# UNAVAILABLE|plugin-runtime|<cause>.
#
# UNAVAILABLE is a REQUIRED check that did not pass, so the general health is
# NOT green and both diagnostics exit 1. That is the product contract and it
# is NOT relaxed here: what changes is the EXPECTATION of a test whose
# runtime cannot be exercised. The operational guarantee with a real CLI
# 2.1.4 belongs to the separate real-runtime scenario.
#
# The contract asserted with the fake is therefore DEGRADATION:
#
#   1. status and doctor exit 1 (not 0),
#   2. the general state is explicitly DEGRADATED and never "OK",
#   3. the degradation is attributable to the plugin-runtime inventory probe
#      and shows an identifiable cause,
#   4. the STATIC overlay checks keep passing (a passing static check is not
#      general health),
#   5. no successful enumeration is ever simulated.
#
# The rendered diagnostics do not carry the internal family id, so the
# attribution to `plugin-runtime` is bound to the rendered message by a
# static check of the production source of the fixture.
# ---------------------------------------------------------------------------

# The message of the plugin-runtime family, as the production code emits it.
PLUGIN_RUNTIME_MESSAGE_PREFIX="plugin list no ejecutada:"
# The binding between that message and the internal family id.
PLUGIN_RUNTIME_FAMILY_BINDING="UNAVAILABLE|plugin-runtime|plugin list no ejecutada:"

# assert_status_degraded <label> <status_out>
# The degradation contract of `status`.
assert_status_degraded() {
  local label="$1"
  local out="$2"

  if grep -qF "Estado general: OK" "$out" 2>/dev/null; then
    fail "$label: status declara 'Estado general: OK' con un runtime no operable"
  else
    pass "$label: status NO declara 'Estado general: OK' con un runtime no operable"
  fi

  if grep -qF "Estado general: DEGRADADO" "$out" 2>/dev/null; then
    pass "$label: status declara 'Estado general: DEGRADADO' de forma explicita"
  else
    fail "$label: status no declara 'Estado general: DEGRADADO'"
  fi

  if grep -qE "$PLUGIN_RUNTIME_MESSAGE_PREFIX.+" "$out" 2>/dev/null; then
    pass "$label: status identifica el sondeo de inventario de plugins como no ejecutable"
  else
    fail "$label: status no identifica el sondeo de inventario de plugins"
  fi

  if grep -qE "$PLUGIN_RUNTIME_MESSAGE_PREFIX.+.*(OPENCODE_DB|binario pinado|aislamiento)" "$out" 2>/dev/null; then
    pass "$label: status muestra una causa identificable del sondeo de inventario"
  else
    fail "$label: status no muestra una causa identificable del sondeo de inventario"
  fi
}

# assert_doctor_degraded <label> <doctor_out>
# The degradation contract of `doctor`.
assert_doctor_degraded() {
  local label="$1"
  local out="$2"

  if grep -qE "FAIL[[:space:]]+UNAVAILABLE: $PLUGIN_RUNTIME_MESSAGE_PREFIX" "$out" 2>/dev/null; then
    pass "$label: doctor reporta el sondeo de inventario como FAIL UNAVAILABLE"
  else
    fail "$label: doctor no reporta el sondeo de inventario como FAIL UNAVAILABLE"
  fi

  if grep -qE "Resumen: FAILs=0" "$out" 2>/dev/null; then
    fail "$label: doctor declara 'Resumen: FAILs=0' con un runtime no operable"
  else
    pass "$label: doctor NO declara 'Resumen: FAILs=0' con un runtime no operable"
  fi
}

# assert_plugin_runtime_family_binding <label> <repo_root>
# The rendered message must belong to the `plugin-runtime` family of the
# production code: the rendered diagnostics do not carry the family id, so the
# attribution is bound to the source that emits it.
assert_plugin_runtime_family_binding() {
  local label="$1"
  local repo="$2"

  if grep -qF "$PLUGIN_RUNTIME_FAMILY_BINDING" "$repo/install.sh" 2>/dev/null; then
    pass "$label: el mensaje de degradacion renderizado pertenece a la familia plugin-runtime"
  else
    fail "$label: el mensaje de degradacion renderizado no esta ligado a la familia plugin-runtime"
  fi
}

# assert_no_simulated_enumeration <label> <file> [file...]
# A fake runtime must never simulate a successful enumeration.
assert_no_simulated_enumeration() {
  local label="$1"
  shift

  if grep -qF "plugin list: enumer" "$@" 2>/dev/null; then
    fail "$label: se simulo una enumeracion runtime exitosa"
  else
    pass "$label: no se simula ninguna enumeracion runtime exitosa"
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

  # The fake runtime cannot exercise the operational plugin inventory probe,
  # so the general health is NOT green: the contract is the explicit
  # degradation, never a healthy result.
  assert_equal "status sale 1 con el fake: el runtime pinado no es operable" "1" "$status_rc"
  assert_status_degraded "status" "$sandbox/status.out"

  if grep -q "OpenCode overlay (" "$sandbox/status.out"; then
    pass "status muestra la sección del overlay OpenCode"
  else
    fail "status no mostró la sección del overlay OpenCode"
  fi

  assert_equal "doctor sale 1 con el fake: el runtime pinado no es operable" "1" "$doctor_rc"

  if grep -q "OpenCode overlay (" "$sandbox/doctor.out"; then
    pass "doctor muestra la sección del overlay OpenCode"
  else
    fail "doctor no mostró la sección del overlay OpenCode"
  fi

  assert_doctor_degraded "doctor" "$sandbox/doctor.out"

  # The static overlay checks keep passing, but a passing static check is NOT
  # general health: it must not turn into "Estado general: OK".
  if grep -qF "opencode.jsonc: JSONC valido" "$sandbox/status.out"; then
    pass "status mantiene las comprobaciones estaticas del overlay superadas"
  else
    fail "status dejó de superar las comprobaciones estaticas del overlay"
  fi

  assert_plugin_runtime_family_binding "status/doctor" "$SD_REPO"
  assert_no_simulated_enumeration "status/doctor" "$sandbox/status.out" "$sandbox/doctor.out"

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

  # The read-only nature of the diagnostics is what this case asserts; the
  # exit code is 1 because the fake runtime cannot exercise the operational
  # probe (the contract of the degradation, not of the health).
  if [ "$status_rc" -eq 1 ] && [ "$doctor_rc" -eq 1 ]; then
    pass "status/doctor salen 1 con el fake (runtime no operable)"
  else
    fail "status/doctor deberían salir 1 con el fake (status=$status_rc doctor=$doctor_rc)"
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
  assert_equal "status sale 1 con el overlay por defecto (fake sin runtime operable)" "1" "$status_rc"
  assert_status_degraded "status" "$sandbox/status.out"
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

  assert_equal "status sale 1 con la variable alternativa exportada (fake sin runtime operable)" \
    "1" "$status_aligned_rc"
  assert_equal "status sale 1 sin la variable alternativa exportada (fake sin runtime operable)" \
    "1" "$status_unset_rc"
  assert_status_degraded "status con la variable alternativa" "$sandbox/status-aligned.out"
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
  assert_equal "status sale 1 validando la config externa registrada (fake sin runtime operable)" \
    "1" "$status_rc"
  assert_status_degraded "status con la config externa" "$sandbox/status.out"

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
  assert_equal "status sale 1 aunque OPENCODE_CONFIG_DIR contradiga el manifest (fake sin runtime operable)" \
    "1" "$status_rc"
  assert_status_degraded "status con OPENCODE_CONFIG_DIR divergente" "$sandbox/status-dir.out"
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
  assert_equal "status sale 1 aunque OPENCODE_CONFIG contradiga el manifest (fake sin runtime operable)" \
    "1" "$status_rc"
  assert_status_degraded "status con OPENCODE_CONFIG divergente" "$sandbox/status-config.out"
  assert_contains "status WARN de config menciona la ruta del entorno" \
    "OPENCODE_CONFIG apunta a $other_dir/opencode.jsonc" "$sandbox/status-config.out"
  assert_contains "status WARN de config menciona la config registrada" \
    "la config instalada está en $alt_dir/opencode.jsonc" "$sandbox/status-config.out"
  assert_contains "status WARN de config incluye un hint accionable" \
    "desexporta OPENCODE_CONFIG" "$sandbox/status-config.out"

  run_isolated "$home" OPENCODE_CONFIG_DIR="$other_dir" \
    bash "$fixture_repo/install.sh" doctor > "$sandbox/doctor.out" 2>&1 || doctor_rc=$?
  assert_equal "doctor sale 1 con una ruta divergente (fake sin runtime operable)" "1" "$doctor_rc"
  assert_doctor_degraded "doctor con ruta divergente" "$sandbox/doctor.out"
  assert_contains "doctor WARN de divergencia menciona la ruta del entorno" \
    "OPENCODE_CONFIG_DIR apunta a $other_dir" "$sandbox/doctor.out"
  assert_contains "doctor WARN de divergencia menciona la ruta registrada" \
    "el overlay está instalado en $alt_dir" "$sandbox/doctor.out"
  assert_contains "doctor WARN de divergencia incluye HINT" \
    "HINT  desexporta OPENCODE_CONFIG_DIR" "$sandbox/doctor.out"

  # The divergence is a WARN, but the fake runtime adds the UNAVAILABLE
  # failures of the operational probe: the summary must show BOTH, and never
  # FAILs=0 (that would be a false healthy claim).
  if grep -qE 'Resumen: FAILs=[1-9][0-9]*[[:space:]]+WARNs=[1-9][0-9]*' "$sandbox/doctor.out"; then
    pass "doctor resume FAILs>0 y al menos un WARN con la ruta divergente"
  else
    fail "doctor no resume FAILs>0 con WARNs positivos en la ruta divergente"
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

  assert_equal "status sin variables exportadas sale 1 (fake sin runtime operable)" "1" "$status_unset_rc"
  assert_equal "doctor sin variables exportadas sale 1 (fake sin runtime operable)" "1" "$doctor_unset_rc"
  assert_equal "status con entorno alineado sale 1 (fake sin runtime operable)" "1" "$status_aligned_rc"
  assert_equal "doctor con entorno alineado sale 1 (fake sin runtime operable)" "1" "$doctor_aligned_rc"

  assert_status_degraded "status sin variables exportadas" "$sandbox/status-unset.out"
  assert_doctor_degraded "doctor sin variables exportadas" "$sandbox/doctor-unset.out"
  assert_status_degraded "status con entorno alineado" "$sandbox/status-aligned.out"
  assert_doctor_degraded "doctor con entorno alineado" "$sandbox/doctor-aligned.out"

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

  local sandbox home fixture_repo alt_dir other_dir other_bin_dir uninstall_rc=0
  local other_bin_before registered_prefix
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/paths-uninstall.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  other_dir="$sandbox/environment-overlay"
  other_bin_dir="$sandbox/environment-binary-prefix"
  registered_prefix="$home/.local/share/forge/opencode-v2"

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

  # The divergent binary prefix (B) holds a real OpenCode-shaped layout and a
  # marker: it must survive the uninstall untouched, byte a byte.
  make_env_sentinel "$other_bin_dir" "divergent-binary-prefix"
  other_bin_before="$(snapshot_tree "$other_bin_dir")"

  uninstall_rc=0
  run_isolated "$home" OPENCODE_CONFIG_DIR="$other_dir" OPENCODE_CONFIG="$other_dir/opencode.jsonc" \
    FORGE_OPENCODE_BIN_DIR="$other_bin_dir" \
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

  if [ ! -e "$alt_dir/opencode.jsonc" ]; then
    pass "uninstall borra el config file registrado"
  else
    fail "uninstall no borró el config file registrado ($alt_dir/opencode.jsonc)"
  fi

  # The state, not the environment, decides which binary prefix is removed.
  if [ ! -e "$registered_prefix" ]; then
    pass "uninstall borra el prefijo binario registrado"
  else
    fail "uninstall no borró el prefijo binario registrado ($registered_prefix)"
  fi

  if [ ! -e "$registered_prefix/node_modules/.bin/opencode" ]; then
    pass "uninstall borra el binario pinado registrado"
  else
    fail "uninstall no borró el binario pinado registrado"
  fi

  assert_equal "uninstall no toca el prefijo binario divergente del entorno" \
    "$other_bin_before" "$(snapshot_tree "$other_bin_dir")"

  if [ -f "$other_bin_dir/marker.txt" ]; then
    pass "uninstall conserva el marcador del prefijo binario divergente"
  else
    fail "uninstall borró el marcador del prefijo binario divergente"
  fi

  if [ -e "$other_bin_dir/node_modules/.bin/opencode" ]; then
    pass "uninstall conserva el binario del prefijo divergente"
  else
    fail "uninstall borró el binario del prefijo divergente"
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

# ---------------------------------------------------------------------------
# Uninstall: the state file is the only source of truth.
#
# The uninstall used to resolve the binary prefix from the ENVIRONMENT
# (FORGE_OPENCODE_BIN_DIR) and `rm -rf` it: with a divergent variable it
# deleted an unrelated directory (with the user's content) and left the real
# binary installed. These cases pin the state-authoritative contract:
#
#   * the recorded `dir`, `config_file` and `binary` are the only paths that
#     may be touched, whatever the environment says;
#   * an incomplete or malformed record fails closed: nothing is removed and
#     the state survives for a safe retry;
#   * without a valid state the uninstall is an informed no-op.
# ---------------------------------------------------------------------------

test_second_uninstall_without_state_is_informed_noop() {
  echo ""
  echo "--- test_second_uninstall_without_state_is_informed_noop"

  local sandbox home fixture_repo state alt_dir env_dir env_bin
  local install_rc=0 first_rc=0 second_rc=0
  local env_dir_before env_bin_before
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/uninstall-second.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  state="$home/.forge-state.json"
  env_dir="$sandbox/environment-overlay"
  env_bin="$sandbox/environment-binary-prefix"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para la segunda desinstalación termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  first_rc=0
  run_isolated "$home" bash "$fixture_repo/install.sh" uninstall \
    > "$sandbox/uninstall-first.out" 2>&1 || first_rc=$?
  assert_equal "la primera desinstalación sale 0" "0" "$first_rc"

  if [ ! -f "$state" ]; then
    pass "la primera desinstalación borra el state file"
  else
    fail "la primera desinstalación no borró el state file"
  fi

  # Sentinels: the environment points at paths that do NOT belong to Forge.
  # A second uninstall has nothing to do, so it must not even look at them.
  make_env_sentinel "$env_dir" "environment-overlay"
  make_env_sentinel "$env_bin" "environment-binary-prefix"
  env_dir_before="$(snapshot_tree "$env_dir")"
  env_bin_before="$(snapshot_tree "$env_bin")"

  second_rc=0
  run_isolated "$home" OPENCODE_CONFIG_DIR="$env_dir" OPENCODE_CONFIG="$env_dir/opencode.jsonc" \
    FORGE_OPENCODE_BIN_DIR="$env_bin" \
    bash "$fixture_repo/install.sh" uninstall > "$sandbox/uninstall-second.out" 2>&1 || second_rc=$?

  assert_equal "la segunda desinstalación (sin state) sale 0" "0" "$second_rc"
  assert_contains "la segunda desinstalación informa de que no hay state" \
    "nada que desinstalar (state file no encontrado)" "$sandbox/uninstall-second.out"
  assert_contains "la segunda desinstalación declara que no inspeccionó ninguna ruta" \
    "no se ha inspeccionado ni modificado ninguna ruta" "$sandbox/uninstall-second.out"

  # The sentinels must be intact byte a byte: nothing was inspected, nothing
  # was created, nothing was removed.
  assert_equal "la segunda desinstalación no toca el overlay del entorno" \
    "$env_dir_before" "$(snapshot_tree "$env_dir")"
  assert_equal "la segunda desinstalación no toca el prefijo binario del entorno" \
    "$env_bin_before" "$(snapshot_tree "$env_bin")"

  if [ -f "$env_dir/marker.txt" ] && [ -f "$env_bin/marker.txt" ]; then
    pass "la segunda desinstalación conserva los marcadores ambientales"
  else
    fail "la segunda desinstalación borró los marcadores ambientales"
  fi

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_uninstall_with_user_residue_does_not_report_todo_ok() {
  echo ""
  echo "--- test_uninstall_with_user_residue_does_not_report_todo_ok"

  local sandbox home fixture_repo alt_dir residue uninstall_rc=0
  local residue_sha_before residue_sha_after
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/uninstall-residue.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || uninstall_rc=$?
  assert_equal "install de referencia para los restos del usuario termina correctamente" "0" "$uninstall_rc"

  if [ "$uninstall_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  # Files the user put in the overlay: Forge does not own them and must not
  # delete them.
  printf 'notas del usuario\n' > "$alt_dir/notas-del-usuario.md"
  mkdir -p "$alt_dir/agents"
  printf 'agente del usuario\n' > "$alt_dir/agents/mi-agente.md"
  residue="$alt_dir/notas-del-usuario.md"
  residue_sha_before="$(sha256sum "$residue" | cut -d' ' -f1 || true)"

  uninstall_rc=0
  run_isolated "$home" bash "$fixture_repo/install.sh" uninstall \
    > "$sandbox/uninstall.out" 2>&1 || uninstall_rc=$?
  assert_equal "uninstall con restos del usuario sale 0" "0" "$uninstall_rc"

  if [ -f "$residue" ] && [ -f "$alt_dir/agents/mi-agente.md" ]; then
    pass "uninstall preserva los ficheros del usuario"
  else
    fail "uninstall borró ficheros del usuario"
  fi

  residue_sha_after="$(sha256sum "$residue" | cut -d' ' -f1 || true)"
  assert_equal "uninstall no modifica el contenido del fichero del usuario" \
    "$residue_sha_before" "$residue_sha_after"

  assert_contains "el resumen avisa de los ficheros del usuario conservados" \
    "OpenCode conserva ficheros del usuario" "$sandbox/uninstall.out"
  assert_contains "el resumen lista las notas del usuario conservadas" \
    "notas-del-usuario.md" "$sandbox/uninstall.out"
  assert_contains "el resumen lista el agente del usuario conservado" \
    "mi-agente.md" "$sandbox/uninstall.out"
  assert_not_contains "el resumen no dice 'Todo OK' con restos del usuario" \
    "Todo OK" "$sandbox/uninstall.out"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_uninstall_without_binary_in_state_fails_closed() {
  echo ""
  echo "--- test_uninstall_without_binary_in_state_fails_closed"

  local sandbox home fixture_repo state alt_dir env_bin install_rc=0 uninstall_rc=0
  local state_sha_before state_sha_after
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/uninstall-no-binary.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  state="$home/.forge-state.json"
  env_bin="$sandbox/environment-binary-prefix"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia sin 'binary' termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  # A legacy state without the 'binary' field cannot be migrated reliably:
  # guessing its prefix could delete an unrelated installation.
  jq '(.targets_manifest[] | select(.name == "opencode")) |= del(.binary)' \
    "$state" > "$sandbox/state.no-binary.json"
  mv "$sandbox/state.no-binary.json" "$state"
  assert_equal "el manifest sin 'binary' no registra el campo binary" "" \
    "$(manifest_opencode_value "$state" binary)"

  make_env_sentinel "$env_bin" "environment-binary-prefix"
  state_sha_before="$(sha256sum "$state" | cut -d' ' -f1 || true)"

  uninstall_rc=0
  run_isolated "$home" FORGE_OPENCODE_BIN_DIR="$env_bin" \
    bash "$fixture_repo/install.sh" uninstall > "$sandbox/uninstall.out" 2>&1 || uninstall_rc=$?

  assert_equal "uninstall con state sin 'binary' falla cerrado con exit 1" "1" "$uninstall_rc"
  assert_contains "el diagnóstico explica que falta el campo 'binary'" \
    "no registra el campo 'binary'" "$sandbox/uninstall.out"
  assert_contains "el diagnóstico recuerda que el state se conserva" \
    "el state se conserva para un reintento seguro" "$sandbox/uninstall.out"

  if [ -x "$home/.local/share/forge/opencode-v2/node_modules/.bin/opencode" ]; then
    pass "uninstall fail-closed no borra el prefijo binario registrado"
  else
    fail "uninstall fail-closed borró el prefijo binario registrado"
  fi

  if [ -f "$alt_dir/opencode.jsonc" ] && [ -f "$alt_dir/agents/senior.md" ]; then
    pass "uninstall fail-closed no borra el overlay registrado"
  else
    fail "uninstall fail-closed borró el overlay registrado"
  fi

  if [ -f "$env_bin/marker.txt" ]; then
    pass "uninstall fail-closed no recurre al prefijo binario del entorno"
  else
    fail "uninstall fail-closed recurró al prefijo binario del entorno"
  fi

  if [ -f "$state" ]; then
    pass "uninstall fail-closed conserva el state file"
  else
    fail "uninstall fail-closed borró el state file"
  fi

  state_sha_after="$(sha256sum "$state" | cut -d' ' -f1 || true)"
  assert_equal "uninstall fail-closed no reescribe el state file" \
    "$state_sha_before" "$state_sha_after"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_uninstall_with_malformed_binary_fails_closed() {
  echo ""
  echo "--- test_uninstall_with_malformed_binary_fails_closed"

  local sandbox home fixture_repo state alt_dir env_bin install_rc=0 uninstall_rc=0
  local state_sha_before state_sha_after bad_binary expected_message variant=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/uninstall-bad-binary.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  state="$home/.forge-state.json"
  env_bin="$sandbox/environment-binary-prefix"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia con 'binary' malformado termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  make_env_sentinel "$env_bin" "environment-binary-prefix"

  # Every malformed value fails closed: nothing is removed and the state
  # survives. The value is never taken from the environment.
  while IFS='|' read -r bad_binary expected_message; do
    [ -n "$bad_binary" ] || continue
    variant=$(( variant + 1 ))

    jq --arg binary "$bad_binary" \
      '(.targets_manifest[] | select(.name == "opencode")).binary = $binary' \
      "$state" > "$sandbox/state.bad-binary.json"
    mv "$sandbox/state.bad-binary.json" "$state"
    state_sha_before="$(sha256sum "$state" | cut -d' ' -f1 || true)"

    uninstall_rc=0
    run_isolated "$home" FORGE_OPENCODE_BIN_DIR="$env_bin" \
      bash "$fixture_repo/install.sh" uninstall \
      > "$sandbox/uninstall-$variant.out" 2>&1 || uninstall_rc=$?

    assert_equal "uninstall con 'binary' malformado ($bad_binary) falla cerrado con exit 1" \
      "1" "$uninstall_rc"
    assert_contains "el diagnóstico explica el 'binary' malformado ($bad_binary)" \
      "$expected_message" "$sandbox/uninstall-$variant.out"
    assert_contains "el diagnóstico recuerda que el state se conserva ($bad_binary)" \
      "el state se conserva para un reintento seguro" "$sandbox/uninstall-$variant.out"

    if [ -x "$home/.local/share/forge/opencode-v2/node_modules/.bin/opencode" ]; then
      pass "uninstall fail-closed no borra el prefijo binario registrado ($bad_binary)"
    else
      fail "uninstall fail-closed borró el prefijo binario registrado ($bad_binary)"
    fi

    if [ -f "$alt_dir/opencode.jsonc" ] && [ -f "$alt_dir/agents/senior.md" ]; then
      pass "uninstall fail-closed no borra el overlay registrado ($bad_binary)"
    else
      fail "uninstall fail-closed borró el overlay registrado ($bad_binary)"
    fi

    if [ -f "$env_bin/marker.txt" ]; then
      pass "uninstall fail-closed no recurre al prefijo binario del entorno ($bad_binary)"
    else
      fail "uninstall fail-closed recurró al prefijo binario del entorno ($bad_binary)"
    fi

    if [ -f "$state" ]; then
      pass "uninstall fail-closed conserva el state file ($bad_binary)"
    else
      fail "uninstall fail-closed borró el state file ($bad_binary)"
    fi

    state_sha_after="$(sha256sum "$state" | cut -d' ' -f1 || true)"
    assert_equal "uninstall fail-closed no reescribe el state file ($bad_binary)" \
      "$state_sha_before" "$state_sha_after"
  done <<EOF
/opt/opencode/bin/opencode|no termina en /node_modules/.bin/opencode
relative/node_modules/.bin/opencode|no es una ruta absoluta
/node_modules/.bin/opencode|no permite obtener un prefijo binario seguro
EOF

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

test_uninstall_failure_preserves_state() {
  echo ""
  echo "--- test_uninstall_failure_preserves_state"

  local sandbox home fixture_repo state alt_dir install_rc=0 uninstall_rc=0
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/uninstall-failure.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  alt_dir="$sandbox/registered-overlay"
  state="$home/.forge-state.json"

  install_opencode_fixture "$home" "$fixture_repo" OPENCODE_CONFIG_DIR="$alt_dir" \
    > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para el fallo del desinstalador termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  # A real failure of the uninstaller: the disposable checkout gets a
  # uninstaller that always fails.
  cat > "$fixture_repo/open-code/uninstall-opencode.sh" <<'STUB_EOF'
#!/usr/bin/env bash
echo "[forge-opencode] ERROR: fallo simulado del desinstalador" >&2
exit 7
STUB_EOF

  uninstall_rc=0
  run_isolated "$home" bash "$fixture_repo/install.sh" uninstall \
    > "$sandbox/uninstall.out" 2>&1 || uninstall_rc=$?

  if [ "$uninstall_rc" -ne 0 ]; then
    pass "uninstall propaga el fallo del desinstalador con exit distinto de cero ($uninstall_rc)"
  else
    fail "uninstall enmascaró el fallo del desinstalador (exit 0)"
  fi

  assert_contains "el diagnóstico explica que el desinstalador falló" \
    "el desinstalador de OpenCode falló" "$sandbox/uninstall.out"

  if [ -f "$state" ]; then
    pass "uninstall fallido conserva el state file para un reintento seguro"
  else
    fail "uninstall fallido borró el state file"
  fi

  if [ -f "$alt_dir/opencode.jsonc" ]; then
    pass "uninstall fallido conserva el overlay registrado"
  else
    fail "uninstall fallido borró el overlay registrado"
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

# ---------------------------------------------------------------------------
# The launcher fails CLOSED when the Forge manifest is missing or invalid.
#
# The manifest is the only authority of the launcher: without it the pinned
# binary is unknown, so the launcher must refuse to run instead of falling
# back to the generic `opencode` of the PATH (which may be the OpenCode V1
# that an Omarchy upgrade reinstalls).
#
# The fixture installs the overlay the way the user does (the root installer
# writes the manifest), so the failure observed here is caused by the state
# of the manifest and by nothing else.
# ---------------------------------------------------------------------------
test_launcher_fails_closed_without_a_valid_manifest() {
  echo ""
  echo "--- test_launcher_fails_closed_without_a_valid_manifest"

  local sandbox home fixture_repo launcher install_rc=0 launch_rc=0
  local manifest pinned_binary
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/manifest-fail-closed.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  manifest="$home/.forge-state.json"
  launcher="$home/.local/bin/forge-opencode"
  pinned_binary="$home/.local/share/forge/opencode-v2/node_modules/.bin/opencode"

  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para el cierre fail-closed termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  # The decoy in the PATH is the only `opencode` reachable by name: if the
  # launcher ever falls back to it, the marker appears in the output.
  cat > "$home/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
printf 'PATH-DECOY-OPENCODE\n'
EOF
  chmod +x "$home/fakebin/opencode"

  # --- 1. the manifest is missing ------------------------------------------
  rm -f "$manifest"
  launch_rc=0
  run_isolated "$home" PATH="$home/fakebin:$PATH" "$launcher" \
    > "$sandbox/missing.out" 2> "$sandbox/missing.err" || launch_rc=$?
  assert_equal "sin manifiesto el launcher sale con codigo 1" "1" "$launch_rc"
  assert_contains "sin manifiesto el launcher explica que falta el manifiesto" \
    "falta el manifiesto de Forge" "$sandbox/missing.err"
  assert_contains "sin manifiesto el launcher dice como se arregla" \
    "reinstala el overlay" "$sandbox/missing.err"
  if grep -qF 'PATH-DECOY-OPENCODE' "$sandbox/missing.out"; then
    fail "sin manifiesto el launcher ejecuto el opencode del PATH"
  else
    pass "sin manifiesto el launcher no ejecuta el opencode del PATH"
  fi

  # --- 2. the manifest is invalid -----------------------------------------
  printf '%s\n' '{ this is not json' > "$manifest"
  launch_rc=0
  run_isolated "$home" PATH="$home/fakebin:$PATH" "$launcher" \
    > "$sandbox/invalid.out" 2> "$sandbox/invalid.err" || launch_rc=$?
  assert_equal "con manifiesto invalido el launcher sale con codigo 1" "1" "$launch_rc"
  assert_contains "con manifiesto invalido el launcher explica la causa" \
    "manifiesto de Forge invalido o incompleto" "$sandbox/invalid.err"
  if grep -qF 'PATH-DECOY-OPENCODE' "$sandbox/invalid.out"; then
    fail "con manifiesto invalido el launcher ejecuto el opencode del PATH"
  else
    pass "con manifiesto invalido el launcher no ejecuta el opencode del PATH"
  fi

  # --- 3. the manifest has no opencode target ------------------------------
  jq -n '{targets_manifest: []}' > "$manifest"
  launch_rc=0
  run_isolated "$home" PATH="$home/fakebin:$PATH" "$launcher" \
    > "$sandbox/no-target.out" 2> "$sandbox/no-target.err" || launch_rc=$?
  assert_equal "sin target opencode el launcher sale con codigo 1" "1" "$launch_rc"
  assert_contains "sin target opencode el launcher explica la causa" \
    "manifiesto de Forge invalido o incompleto" "$sandbox/no-target.err"

  # --- 4. the recorded binary is not absolute ------------------------------
  jq --arg binary "opencode" \
    '.targets_manifest = [{name:"opencode",dir:"/tmp/x",config_file:"/tmp/x/opencode.jsonc",binary:$binary}]' \
    "$manifest" > "$manifest.relative"
  mv "$manifest.relative" "$manifest"
  launch_rc=0
  run_isolated "$home" PATH="$home/fakebin:$PATH" "$launcher" \
    > "$sandbox/relative.out" 2> "$sandbox/relative.err" || launch_rc=$?
  assert_equal "con binario relativo el launcher sale con codigo 1" "1" "$launch_rc"
  assert_contains "con binario relativo el launcher explica la causa" \
    "no es absoluta" "$sandbox/relative.err"
  if grep -qF 'PATH-DECOY-OPENCODE' "$sandbox/relative.out"; then
    fail "con binario relativo el launcher ejecuto el opencode del PATH"
  else
    pass "con binario relativo el launcher no ejecuta el opencode del PATH"
  fi

  # --- 5. the recorded binary does not exist -------------------------------
  jq --arg binary "$pinned_binary.missing" \
    '.targets_manifest = [{name:"opencode",dir:"/tmp/x",config_file:"/tmp/x/opencode.jsonc",binary:$binary}]' \
    "$manifest" > "$manifest.missing"
  mv "$manifest.missing" "$manifest"
  launch_rc=0
  run_isolated "$home" PATH="$home/fakebin:$PATH" "$launcher" \
    > "$sandbox/missing-bin.out" 2> "$sandbox/missing-bin.err" || launch_rc=$?
  assert_equal "con binario inexistente el launcher sale con codigo 1" "1" "$launch_rc"
  # The launcher EXITS before it executes anything, so the rejection happens
  # in the accreditation of the pinned package: that is the gate that comes
  # first, and its diagnostic is the one the operator reads.
  assert_contains "con binario inexistente el launcher explica la causa" \
    "no se pudo acreditar el paquete OpenCode 2.1.4" "$sandbox/missing-bin.err"

  # --- 6. the manifest is back: the launcher works again -------------------
  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/reinstall.out" 2>&1 || install_rc=$?
  assert_equal "reinstalar restituye el manifiesto" "0" "$install_rc"
  launch_rc=0
  run_isolated "$home" PATH="$home/fakebin:$PATH" "$launcher" debug config \
    > "$sandbox/restored.out" 2> "$sandbox/restored.err" || launch_rc=$?
  assert_equal "con el manifesto restaurado el launcher sale 0" "0" "$launch_rc"
  assert_contains "con el manifesto restaurado el launcher usa el binario pinado" \
    "OPENCODE_CONFIG_DIR=$home/.config/opencode-forge" "$sandbox/restored.out"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

# write_network_free_launcher <sandbox>
#
# Writes a COPY of the launcher of Forge in <sandbox>/launcher, with a COPY
# of the helper of the runtime in which the TWO operations of network are
# replaced by CONTROLLED DOUBLES:
#
#   * the ownership of the loopback listener of the private service;
#   * the authenticated health of that service.
#
# The battery of the suites does NOT use the network: not even the loopback
# interface. The COPY is the one that the sandbox uses, so the repository is
# never modified, and the rest of the launcher (the routing, the manifest,
# the environment and the supervision) is exercised exactly as it is.
#
# It prints the path of the launcher of la copia.
write_network_free_launcher() {
  local sandbox="$1"
  local launcher_dir="$sandbox/launcher"
  rm -rf "$launcher_dir"
  mkdir -p "$launcher_dir/lib" || return 1
  cp "$FORGE_ROOT/open-code/forge-opencode.sh" "$launcher_dir/forge-opencode" || return 1
  chmod +x "$launcher_dir/forge-opencode"
  if [ -f "$FORGE_ROOT/open-code/env.sh" ]; then
    cp "$FORGE_ROOT/open-code/env.sh" "$launcher_dir/env.sh" || return 1
  fi
  cp "$FORGE_ROOT/open-code/lib/plugin-sync.py" "$launcher_dir/lib/plugin-sync.py" || return 1

  python3 - "$launcher_dir/lib/plugin-sync.py" <<'NETWORK_FREE_DOUBLES_EOF'
import re
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    source = handle.read()

LISTENER_DOUBLE = '''def _listener_owned_by(pid, port):
    """DOUBLE DE PRUEBA (sin red): el servicio privado simulado no abre socket.

    La pertenencia del listener se declara cumplida sin consultar
    /proc/net: la bateria de las suites NO usa la red, ni el loopback.
    """
    return True


'''

HEALTH_DOUBLE = '''def _authenticated_health(registration, timeout=1.0):
    """DOUBLE DE PRUEBA (sin red): la salud del servicio se comprueba contra
    el propio registro, sin ninguna peticion HTTP."""
    url = registration.get("url")
    password = registration.get("password")
    pid = registration.get("pid")
    version = registration.get("version")
    if not isinstance(url, str) or not url:
        return False
    if not isinstance(password, str) or not password:
        return False
    if not isinstance(pid, int) or not isinstance(version, str):
        return False
    return True


'''


def replace_function(text, name, replacement):
    pattern = re.compile(r"^def %s\(.*?(?=^def |\Z)" % re.escape(name), re.M | re.S)
    match = pattern.search(text)
    if not match:
        raise SystemExit("la copia del ayudante no define %s" % name)
    return text[:match.start()] + replacement + text[match.end():]


source = replace_function(source, "_listener_owned_by", LISTENER_DOUBLE)
source = replace_function(source, "_authenticated_health", HEALTH_DOUBLE)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(source)
NETWORK_FREE_DOUBLES_EOF
  [ $? -eq 0 ] || return 1
  printf '%s\n' "$launcher_dir/forge-opencode"
}

# ---------------------------------------------------------------------------
# The private service the Forge supervisor expects, emulated by a fake CLI.
#
# The fake is NOT a runtime: it registers a private service in the XDG state
# directory it is given and it resolves the service registration of ITS OWN
# XDG state directory for `mcp list`.
#
# Every invocation is recorded with the environment that decides the routing,
# so the fixture can prove WHICH service the effective path resolved and
# WHICH state directory it consulted.
#
# THE FIXTURE USES NO NETWORK AT ALL: the private service is SIMULATED (it
# opens no socket) and the two operations of network of the runtime helper
# are replaced by controlled doubles in the copy of that helper that the
# sandbox uses. Nothing outside the sandbox is written.
# ---------------------------------------------------------------------------
write_fake_private_service() {
  local binary="$1" log="$2" identities="$3"

  cat > "$binary" <<'FAKE_PY'
#!/usr/bin/env python3
"""Fake OpenCode CLI for the Forge launcher fixture (private service).

The private service of this fixture is SIMULATED: it opens NO socket. The
battery of the suites does not use the network at all, not even the loopback
interface.
"""
import json
import os
import pathlib
import sys
import time

LOG_PATH = "__FORGE_FAKE_LOG__"
IDENTITY_PATH = "__FORGE_FAKE_IDENTITIES__"
VERSION = "2.1.4"
ENV_KEYS = (
    "HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "TMPDIR",
    "OPENCODE_DB",
    "OPENCODE_CONFIG_DIR",
    "OPENCODE_CONFIG",
)


def record(argv, extra=None):
    entry = {"argv": argv, "env": {key: os.environ.get(key, "") for key in ENV_KEYS}}
    if extra:
        entry.update(extra)
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry) + "\n")
        handle.flush()


def start_ticks(pid):
    """The starttime (field 22) of /proc/<pid>/stat, or "" when unreadable.

    Only the OWN processes of the fixture are read: the fake itself and its
    own parent, the private supervisor that spawned it. No other process is
    inspected and no cmdline is ever read.
    """
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii", errors="replace") as stream:
            data = stream.read()
    except OSError:
        return ""
    tail = data.rsplit(")", 1)[-1].split()
    if len(tail) < 20:
        return ""
    return tail[19]


def record_identity_of(pid, ticks):
    """Append an ALREADY KNOWN identity ("<pid> <starttime>") of an own process.

    The identity is used as it is: it comes from a record that the process
    itself wrote, and NOT from the live process behind the number. A number
    that was recycled would otherwise be recorded with the identity of the
    foreign process that occupies it now, and that foreign process would
    later be signalled as if it were ours.
    """
    if not IDENTITY_PATH:
        return
    if not ticks:
        return
    with open(IDENTITY_PATH, "a", encoding="ascii") as handle:
        handle.write("%d %s\n" % (pid, ticks))
        handle.flush()


def record_identity(pid):
    """Append the "<pid> <starttime>" identity of an OWN process."""
    ticks = start_ticks(pid)
    if not ticks:
        return
    record_identity_of(pid, ticks)


def registry_files():
    state = os.environ.get("XDG_STATE_HOME", "")
    directory = pathlib.Path(state) / "opencode"
    if not directory.is_dir():
        return []
    return sorted(directory.glob("service*.json"))


def serve():
    """The private service of the fixture, SIMULATED (no red).

    The service opens NO socket: it publishes the registration that the
    supervisor expects (with the shape of a loopback URL) and it stays alive
    while the supervisor uses it.

    The two operations of network of the runtime helper (the ownership of the
    loopback listener and the authenticated health of the service) are
    replaced by controlled doubles in the COPY of that helper that the
    sandbox uses. The battery of the suites does not use the network.
    """
    url = "http://127.0.0.1:%d" % (40000 + (os.getpid() % 20000))
    password = "forge-fixture-password"
    directory = pathlib.Path(os.environ.get("XDG_STATE_HOME", "")) / "opencode"
    directory.mkdir(parents=True, exist_ok=True)
    registration = {
        "pid": os.getpid(),
        # The starttime travels with the pid: a consumer that reads this
        # registry can tell the service apart from whatever process
        # occupies that number later.
        "starttime": start_ticks(os.getpid()),
        "version": VERSION,
        "url": url,
        "password": password,
    }
    (directory / ("service-%d.json" % os.getpid())).write_text(
        json.dumps(registration), encoding="utf-8"
    )
    # The number of sockets that this process has open: it MUST be zero. It
    # is the proof, observed by the process itself, that the fixture does
    # not use the network. It is published in the log of the invocations
    # (the state directory of the service is removed when the runtime
    # finishes, the log is not).
    sockets = 0
    try:
        for descriptor in pathlib.Path("/proc/self/fd").iterdir():
            try:
                target = os.readlink(descriptor)
            except OSError:
                continue
            if target.startswith("socket:"):
                sockets += 1
    except OSError:
        sockets = -1
    record(["serve"], {"sockets": sockets})
    # The service stays alive while the supervisor uses it.
    while True:
        time.sleep(0.05)


def main():
    argv = sys.argv[1:]
    record(argv)

    # The identity of this process and of its parent (the private supervisor
    # that spawned it) is recorded, so the fixture can check afterwards that
    # the processes it created are gone WITHOUT sweeping the process table.
    record_identity(os.getpid())
    record_identity(os.getppid())

    if argv[:3] == ["debug", "paths", "db"]:
        sys.stdout.write(
            os.path.join(os.environ.get("XDG_DATA_HOME", ""), "opencode", "opencode.db") + "\n"
        )
        return 0

    if argv[:1] == ["serve"]:
        serve()
        return 0

    if argv[:2] == ["mcp", "list"]:
        files = registry_files()
        record(argv, {"registry": [str(item) for item in files]})
        if not files:
            sys.stdout.write("RESOLVED_SERVICE=none\n")
            return 1
        try:
            registration = json.loads(files[0].read_text(encoding="utf-8"))
        except (OSError, ValueError):
            sys.stdout.write("RESOLVED_SERVICE=invalid\n")
            return 1
        # The identity registered by the private supervisor is recorded too:
        # it is an OWN process of the fixture (the private server it owns).
        registered_pid = registration.get("pid")
        registered_ticks = registration.get("starttime")
        if isinstance(registered_pid, int) and registered_ticks:
            # The identity comes from the REGISTRY (the file the service
            # itself wrote), never from the live process behind that number.
            record_identity_of(registered_pid, registered_ticks)
        sys.stdout.write("RESOLVED_SERVICE=%s\n" % registration.get("url", ""))
        sys.stdout.write("RESOLVED_REGISTRY=%s\n" % files[0])
        return 0

    sys.stdout.write("ARGV=%s\n" % " ".join(argv))
    return 0


if __name__ == "__main__":
    sys.exit(main())
FAKE_PY

  sed -i "s|__FORGE_FAKE_LOG__|$log|" "$binary"
  sed -i "s|__FORGE_FAKE_IDENTITIES__|$identities|" "$binary"
  chmod +x "$binary"
}

# test_launcher_isolates_mcp_list_from_the_shared_service
#
# `mcp list` resolves the SHARED service by default in OpenCode 2.1.4, so the
# launcher routes it to the private supervisor: a disposable loopback service
# with its own service registration, its own HOME/XDG and its own database.
#
# The fixture proves that with the routing and the environment of every
# invocation of the fake runtime:
#
#   * the CLI is invoked with `mcp list` by the supervisor, never with
#     `--standalone` (that leaf does not declare it);
#   * the only service started is the private one: an ephemeral loopback
#     listener started by the supervisor;
#   * the state directory consulted by `mcp list` is the PRIVATE one, never
#     the shared one, so the shared resolver is never reached;
#   * the database used is the private snapshot, never the original one;
#   * the registration of the shared service is not even read: it is left
#     untouched and its URL is never the one resolved;
#   * no process of the fixture survives.
test_launcher_isolates_mcp_list_from_the_shared_service() {
  echo ""
  echo "--- test_launcher_isolates_mcp_list_from_the_shared_service"

  local sandbox home fixture_repo launcher install_rc=0 launch_rc=0
  local pinned_binary log_file decoy_registry decoy_before decoy_after
  local db resolved resolved_registry mcp_line state_of_mcp db_of_mcp
  local sockets_count
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/mcp-isolation.XXXXXX")"
  home="$sandbox/home"
  TMP_TEST_HOME="$home"
  mkdir -p "$home" "$sandbox/tmp"
  fixture_repo="$(create_repo_fixture "$sandbox/repo")"
  create_fake_opencode "$home"
  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para el aislamiento de mcp termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    sed -n '1,20p' "$sandbox/install.out" | sed 's/^/      /' >&2
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  # The launcher of this fixture is a COPY with the two operations of
  # network of the runtime helper replaced by controlled doubles: the
  # battery of the suites does not use the network, not even the loopback
  # interface. The repository is never modified.
  launcher="$(write_network_free_launcher "$sandbox")" || {
    fail "no se pudo preparar la copia del launcher sin red"
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  }
  pinned_binary="$home/.local/share/forge/opencode-v2/node_modules/.bin/opencode"
  # The ACCREDITED layout: the entry of `.bin` is a LINK to the executable of
  # the package @opencode/cli. The fixture replaces the EXECUTABLE of the
  # package (never the link), so the accreditation of the launcher stays
  # intact: a `sed -i` on the link would replace the link itself.
  package_binary="$home/.local/share/forge/opencode-v2/node_modules/@opencode/cli/bin/opencode"
  log_file="$sandbox/fake-calls.log"

  # The identities of the processes this fixture creates. The fake runtime
  # appends its own identity (and the one of the supervisor that spawned
  # it) to this file; nothing else is ever recorded.
  #
  # The registry is a DIAGNOSTIC record and NOT a certificate of descendants:
  # it is written INSIDE the containment (where the namespace it belongs to
  # is known) and it is only used to terminate those identities there.
  own_identities="$sandbox/own-identities.txt"
  : > "$own_identities"

  # The decoy of the shared service: a registration in the SHARED state
  # directory of the sandbox, pointing at a port where nothing listens. If the
  # effective path consulted the shared resolver, this registration would be
  # the one resolved.
  mkdir -p "$home/.local/state/opencode"
  decoy_registry="$home/.local/state/opencode/service-decoy.json"
  printf '%s\n' '{"pid":424242,"version":"2.1.4","url":"http://127.0.0.1:1","password":"decoy"}' \
    > "$decoy_registry"
  decoy_before="$(sha256sum "$decoy_registry" | cut -d' ' -f1)"

  # The generic binary of the PATH: the only `opencode` reachable by name.
  cat > "$home/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
printf 'PATH-DECOY-OPENCODE\n'
EOF
  chmod +x "$home/fakebin/opencode"

  # The pinned binary is replaced by the fake that emulates the private
  # service and records every invocation. The replacement happens on the
  # EXECUTABLE of the package, so the entry of `.bin` keeps pointing to it.
  write_fake_private_service "$package_binary" "$log_file" "$own_identities"

  if [ ! -L "$pinned_binary" ] \
    || [ "$(readlink "$pinned_binary")" != "../@opencode/cli/bin/opencode" ]; then
    fail "el fixture de mcp conserva el enlace acreditado de .bin"
  else
    pass "el fixture de mcp conserva el enlace acreditado de .bin"
  fi

  # The database of the sandbox: a valid but empty SQLite file. The real
  # database of the user is never opened, never read and never copied.
  db="$home/.local/share/opencode/opencode.db"
  mkdir -p "$(dirname "$db")"
  if ! python3 -c '
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA user_version = 0")
connection.commit()
connection.close()
' "$db" 2>/dev/null; then
    fail "no se pudo crear la base de datos aislada del fixture de mcp"
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  launch_rc=0

  # The observer records the identity of every descendant of this test while
  # the fixture runs, so the survivor check below does not depend on the
  # command line of the processes it looks for.
  #
  # Its availability is MANDATORY: an observer that does not work would
  # leave an empty inventory, and an empty inventory reads as "zero
  # survivors". When the observer cannot prove it is running, the fixture
  # FAILS instead of certifying anything.
  # The launcher runs INSIDE the containment. The supervisor of the launcher
  # and the private service it starts are processes that never pass through
  # any registry of the suite, and the containment covers them without
  # touching their code: the kernel tears the private PID namespace down
  # when its PID 1 exits, so nothing of the fixture can outlive the run.
  forge_make_toolchain "$home/fakebin"
  forge_isolated_env_with_registry "$home" "$own_identities" \
    PATH="$home/fakebin:$PATH" TMPDIR="$sandbox/tmp" \
    "$launcher" mcp list > "$sandbox/mcp.out" 2> "$sandbox/mcp.err" || launch_rc=$?
  assert_equal "mcp list sale 0 con el servicio privado" "0" "$launch_rc"

  # The receipt of the contained run is the evidence of this fixture: the
  # boundary was accredited by invocation, the closure was confirmed and the
  # cleanup of the product was observed BEFORE the defensive cleanup.
  contained_receipt="$FORGE_CONTAINMENT_LAST_RECEIPT"
  if [ -z "$contained_receipt" ] || [ ! -s "$contained_receipt" ]; then
    fail "la corrida contenida no dejo recibo: no hay evidencia de cierre"
  elif ! forge_receipt_containment_evidence "$contained_receipt"; then
    fail "el recibo de la corrida contenida no certifica la frontera ni el cierre"
    forge_receipt_summary "$contained_receipt" >&2 || true
  else
    pass "la corrida contenida acredita la frontera y el cierre (recibo: $contained_receipt)"
  fi

  # The result of the PRODUCT is a verdict of its own: the certification of
  # the boundary does not convert it into a PASS, and the consumer does not
  # presume it. Whatever it is, the POSITIVE ACCEPTANCE that the receipt
  # declares must AGREE with it: a receipt that declares a positive
  # acceptance while its own product result contradicts it is contradictory
  # evidence.
  product_result="$(forge_receipt_product_cleanup "$contained_receipt")"
  declared_acceptance="$(forge_receipt_read "$contained_receipt" POSITIVE_ACCEPTANCE 2>/dev/null || printf 'NO')"
  if { [ "$product_result" = "PASS" ] && [ "$declared_acceptance" = "YES" ]; } \
    || { [ "$product_result" != "PASS" ] && [ "$declared_acceptance" != "YES" ]; }; then
    pass "la aceptacion positiva del recibo es coherente con la limpieza del producto (producto=$product_result aceptacion=$declared_acceptance)"
  else
    fail "la aceptacion positiva del recibo ($declared_acceptance) NO es coherente con la limpieza del producto ($product_result)"
  fi

  if [ "$launch_rc" -ne 0 ]; then
    sed -n '1,20p' "$sandbox/mcp.err" | sed 's/^/      /' >&2
  fi

  resolved="$(sed -n 's/^RESOLVED_SERVICE=//p' "$sandbox/mcp.out" | head -n 1)"
  resolved_registry="$(sed -n 's/^RESOLVED_REGISTRY=//p' "$sandbox/mcp.out" | head -n 1)"

  # Every invocation of the fake runtime, with the environment that decides
  # the routing.
  if [ -f "$log_file" ]; then
    python3 - "$log_file" > "$sandbox/invocations.txt" <<'INVOCATIONS_PY'
import json
import sys

for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    entry = json.loads(line)
    env = entry.get("env", {})
    print("ARGV=%s" % " ".join(entry.get("argv", [])))
    print("  HOME=%s" % env.get("HOME", ""))
    print("  STATE=%s" % env.get("XDG_STATE_HOME", ""))
    print("  DB=%s" % env.get("OPENCODE_DB", ""))
    print("  CONFIG=%s" % env.get("OPENCODE_CONFIG_DIR", ""))
INVOCATIONS_PY
  else
    : > "$sandbox/invocations.txt"
  fi

  # The private service is the one that is started: a private service
  # SIMULADA (it opens no socket), started by the supervisor and not by the
  # launcher.
  if grep -qF 'ARGV=serve --service --hostname 127.0.0.1 --port 0 --print-logs' \
    "$sandbox/invocations.txt"; then
    pass "mcp list arranca el servicio privado SIMULADO (sin red)"
  else
    fail "mcp list no arranco el servicio privado esperado"
    sed -n '1,40p' "$sandbox/invocations.txt" | sed 's/^/      /' >&2
  fi

  # The service did NOT open any socket: the battery of the suites does not
  # use the network, not even the loopback interface. The count is observed
  # by the service itself and published in the log of the invocations.
  local sockets_count
  sockets_count="$(python3 - "$log_file" <<'SOCKETS_EOF'
import json
import sys

count = ""
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            entry = json.loads(line)
            if entry.get("argv") == ["serve"] and "sockets" in entry:
                count = str(entry["sockets"])
except (OSError, ValueError):
    pass
print(count)
SOCKETS_EOF
)"
  if [ "$sockets_count" = "0" ]; then
    pass "el servicio privado simulado NO abrio ningun socket: la bateria no usa la red"
  else
    fail "el servicio privado simulado publico '$sockets_count' sockets (se esperaba 0): la bateria no debe usar la red"
  fi

  # The leaf `mcp list` does not declare --standalone: the launcher must not
  # inject it.
  if grep -qF 'ARGV=mcp list --standalone' "$sandbox/invocations.txt"; then
    fail "mcp list recibio --standalone: esa hoja no lo admite"
  else
    pass "mcp list no recibe --standalone (esa hoja no lo admite)"
  fi

  mcp_line="$(grep -A4 '^ARGV=mcp list$' "$sandbox/invocations.txt" | head -n 5)"
  state_of_mcp="$(printf '%s\n' "$mcp_line" | sed -n 's/^  STATE=//p' | head -n 1)"
  db_of_mcp="$(printf '%s\n' "$mcp_line" | sed -n 's/^  DB=//p' | head -n 1)"

  # The state directory consulted is the PRIVATE one: the shared resolver is
  # never reached.
  case "$state_of_mcp" in
    "$sandbox/tmp/"*)
      pass "mcp list consulta el estado PRIVADO del servicio ($state_of_mcp)"
      ;;
    *)
      fail "mcp list no consulto el estado privado del servicio (estado='$state_of_mcp')"
      ;;
  esac

  if grep -qF "STATE=$home/" "$sandbox/invocations.txt"; then
    fail "alguna invocacion consulto el estado compartido del sandbox"
  else
    pass "ninguna invocacion consulta el estado compartido del sandbox"
  fi

  # The database used is the private snapshot, never the original one.
  case "$db_of_mcp" in
    "$sandbox/tmp/"*)
      pass "mcp list usa la instantanea PRIVADA de la base de datos"
      ;;
    *)
      fail "mcp list no uso la instantanea privada de la base de datos (db='$db_of_mcp')"
      ;;
  esac

  # The service resolved is the private one, never the shared registration.
  if [ -n "$resolved" ] && [ "$resolved" != "http://127.0.0.1:1" ]; then
    pass "mcp list resuelve el servicio privado ($resolved)"
  else
    fail "mcp list resolvio el servicio compartido o ninguno (resuelto='$resolved')"
  fi

  case "$resolved_registry" in
    "$home/"*)
      fail "mcp list resolvio el registro del servicio compartido ($resolved_registry)"
      ;;
    "$sandbox/tmp/"*)
      pass "el registro resuelto por mcp list pertenece al servicio privado"
      ;;
    *)
      fail "el registro resuelto por mcp list no es privado ($resolved_registry)"
      ;;
  esac

  decoy_after="$(sha256sum "$decoy_registry" | cut -d' ' -f1)"
  assert_equal "el registro del servicio compartido no se toca" "$decoy_before" "$decoy_after"

  if grep -qF 'PATH-DECOY-OPENCODE' "$sandbox/mcp.out" "$sandbox/mcp.err"; then
    fail "mcp list ejecuto el opencode del PATH"
  else
    pass "mcp list no ejecuta el opencode del PATH"
  fi

  # No process of the fixture survives.
  #
  # The guarantee is NO LONGER an inventory of the host: it is the CLOSURE of
  # the containment, accredited by the receipt of the run. The scenario
  # terminated the private service by its IDENTITY (inside the namespace,
  # where that identity is valid) and then observed the PRIVATE /proc of the
  # containment: any process still alive there is a leftover of the product.
  #
  # The two results are kept SEPARATED: the result of the product (did it
  # clean up?) and the defensive result of the containment (was the boundary
  # accredited and the closure confirmed?). A correct closure NEVER converts
  # a failure of the product into a PASS.
  local product_result="UNKNOWN"
  if [ -n "$contained_receipt" ] && [ -s "$contained_receipt" ]; then
    product_result="$(forge_receipt_product_cleanup "$contained_receipt")"
  fi
  case "$product_result" in
    PASS)
      pass "no queda ningun proceso propio del fixture de mcp dentro de la contencion"
      ;;
    FAIL)
      fail "quedan procesos propios del fixture de mcp dentro de la contencion"
      ;;
    *)
      fail "la limpieza del producto NO se pudo observar (resultado: $product_result): el chequeo de supervivientes seria vacuo"
      ;;
  esac

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

# test_containment_controls
#
# The evidence of this suite is only worth something if the machinery that
# produces it is proven to work. This test proves the properties the
# CONTAINMENT of tools/verification/forge-contained-run.sh must have, and it
# proves them with the SAME sensitivity the retired observer had:
#
#   1. the BOUNDARY is accredited BY INVOCATION and the CLOSURE is
#      CONFIRMED: the contained environment is waited for;
#   2. a descendant that survives its parent (a REPARENTED process, the very
#      case the observer had to poll for) is VISIBLE over the private /proc
#      of the containment, so the cleanup of the product is declared FAIL;
#   3. the defensive cleanup of the harness NEVER converts that failure into
#      a PASS: the product result and the defensive result are separate;
#   4. the EVIDENCE is rejected when it is absent, partial, illegible or
#      contradictory: there is no "PASS by absence".
test_containment_controls() {
  echo ""
  echo "--- test_containment_controls"

  local sandbox chain_dir chain_level4 detected=no
  local receipt product_result rc=0 saved_failed saved_scope
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/containment-controls.XXXXXX")"
  chain_dir="$sandbox/chain"
  mkdir -p "$chain_dir"

  # The chain reproduces the shape that broke the observer: level2 exits and
  # level3 is REPARENTED, and level4 is created by level3 AFTER the
  # reparenting. The containment does not need to follow it: the observation
  # over the private /proc sees it and the kernel tears the namespace down.
  cat > "$chain_dir/level1.sh" <<'CHAIN_L1_EOF'
#!/bin/sh
# level1 owns level2 and stays alive until it is terminated.
printf '%s %s\n' "$$" "$(sed -e 's/.*) //' /proc/$$/stat | awk '{ print $20 }')" \
  >> "$CHAIN_DIR/identities.txt"
echo "$$" > "$CHAIN_DIR/level1.pid"
sh "$CHAIN_DIR/level2.sh" &
exec sleep 30
CHAIN_L1_EOF
  cat > "$chain_dir/level2.sh" <<'CHAIN_L2_EOF'
#!/bin/sh
# level2 creates level3 and exits after a short delay: level3 stays alive
# and is reparented.
printf '%s %s\n' "$$" "$(sed -e 's/.*) //' /proc/$$/stat | awk '{ print $20 }')" \
  >> "$CHAIN_DIR/identities.txt"
echo "$$" > "$CHAIN_DIR/level2.pid"
sh "$CHAIN_DIR/level3.sh" &
sleep 0.5
exit 0
CHAIN_L2_EOF
  cat > "$chain_dir/level3.sh" <<'CHAIN_L3_EOF'
#!/bin/sh
# level3 waits until its parent exited, creates level4 and stays alive.
printf '%s %s\n' "$$" "$(sed -e 's/.*) //' /proc/$$/stat | awk '{ print $20 }')" \
  >> "$CHAIN_DIR/identities.txt"
echo "$$" > "$CHAIN_DIR/level3.pid"
sleep 1
sh "$CHAIN_DIR/level4.sh" &
exec sleep 30
CHAIN_L3_EOF
  cat > "$chain_dir/level4.sh" <<'CHAIN_L4_EOF'
#!/bin/sh
# level4 is the deepest level: it only exists if level3 created it after the
# reparenting.
printf '%s %s\n' "$$" "$(sed -e 's/.*) //' /proc/$$/stat | awk '{ print $20 }')" \
  >> "$CHAIN_DIR/identities.txt"
echo "$$" > "$CHAIN_DIR/level4.pid"
exec sleep 30
CHAIN_L4_EOF
  chmod +x "$chain_dir/level1.sh" "$chain_dir/level2.sh" \
    "$chain_dir/level3.sh" "$chain_dir/level4.sh"

  # The scenario of the control: it creates the chain, waits for its deepest
  # level and returns. The chain is NOT terminated by the scenario: the
  # containment has to close it.
  cat > "$sandbox/chain-launcher.sh" <<CHAIN_LAUNCHER_EOF
#!/bin/sh
CHAIN_DIR='$chain_dir'
export CHAIN_DIR
sh "\$CHAIN_DIR/level1.sh" &
waited=0
while [ "\$waited" -lt 300 ]; do
  [ -s "\$CHAIN_DIR/level4.pid" ] && break
  sleep 0.05
  waited=\$((waited + 1))
done
exit 0
CHAIN_LAUNCHER_EOF
  chmod +x "$sandbox/chain-launcher.sh"

  local scenario
  scenario="$(forge_contained_scenario "$sandbox/home")" || {
    fail "no se pudo preparar el escenario contenido del control"
    rm -rf "$sandbox"
    return
  }

  # This control EXPECTS a product cleanup that is not a PASS: the chain
  # survives on purpose. Its receipt is therefore not registered as an
  # incident of the suite.
  #
  # The declaration of this invocation is NOT APPLICABLE for the cleanup of
  # the PRODUCT: the scenario injects a fault on purpose and the product of
  # the repository is not what survives. The verdict itself (FAIL) stays in
  # the receipt of the run and in the collector: nothing is hidden, the
  # verdict simply does not describe the cleanup of the product.
  saved_failed="${FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE:-}"
  saved_scope="${FORGE_CONTAINED_RUN_DECLARATION_SCOPE:-}"
  saved_declarations="${FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE:-}"
  FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE=""
  export FORGE_CONTAINED_RUN_DECLARATION_SCOPE="NOT_APPLICABLE"
  # The declaration of this control is NOT published to the collector of the
  # consumer: a FAIL under a NOT_APPLICABLE scope is CONTRADICTORY evidence
  # and the aggregate preserves the failure instead of skipping it (a scope
  # must never hide a failure of the product). The verdict stays in the
  # receipt of the run, which is where this control reads it.
  unset FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE
  forge_contained_run "$scenario" "$sandbox/chain-launcher.sh" || rc=$?
  FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE="$saved_failed"
  export FORGE_CONTAINED_RUN_DECLARATION_SCOPE="$saved_scope"
  if [ -n "$saved_declarations" ]; then
    export FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE="$saved_declarations"
  fi
  rm -f "$scenario"

  receipt="$FORGE_CONTAINMENT_LAST_RECEIPT"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la corrida contenida del control no dejo recibo: no hay evidencia de frontera ni de cierre"
    rm -rf "$sandbox"
    return
  fi

  # This control certifies the BOUNDARY AND THE CLOSURE of the contained
  # run, not the acceptance: the product of the control does NOT clean up
  # (the chain survives on purpose), so the POSITIVE ACCEPTANCE does not
  # exist and the consumer must reject it. Certifying the closure is not
  # the same as certifying the acceptance.
  if forge_receipt_containment_evidence "$receipt"; then
    pass "el control acredita la frontera y el cierre de la corrida contenida"
  else
    fail "el control NO puede acreditar la frontera ni el cierre de la corrida contenida"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || printf 'NO')" != "YES" ]; then
    pass "el control NO tiene aceptacion positiva: un producto que no limpio no se certifica"
  else
    fail "el control declara aceptacion positiva con un producto que no limpio"
  fi

  # The chain reached its deepest level: the scenario observed it, so the
  # control really exercised the reparenting.
  if [ -s "$chain_dir/level4.pid" ]; then
    chain_level4="$(cat "$chain_dir/level4.pid")"
    detected=yes
  fi
  if [ "$detected" = yes ] && grep -q "^$chain_level4 " "$chain_dir/identities.txt" 2>/dev/null; then
    pass "el control exercita la cadena reparentada (el descendiente de segundo nivel existe)"
  else
    fail "el control NO exercito la cadena reparentada: la sensibilidad del chequeo no esta probada"
  fi

  # The product cleanup of the control: the chain was NOT terminated by the
  # scenario, so the observation over the private /proc MUST report FAIL.
  # This is the sensitivity the retired observer had to provide: a
  # descendant that survives its parent has to be visible.
  product_result="$(forge_receipt_product_cleanup "$receipt")"
  if [ "$product_result" = "FAIL" ]; then
    pass "el descendiente que sobrevive a su padre se ve en el /proc privado: la limpieza del producto se declara FAIL"
  else
    fail "el descendiente que sobrevive a su padre NO se ve (resultado: $product_result): el chequeo de supervivientes seria vacuo"
  fi

  # --- the evidence is rejected when it is absent or contradictory ---------
  if forge_receipt_require "$sandbox/absent-receipt.txt" >/dev/null 2>&1; then
    fail "un recibo AUSENTE se acepto como evidencia: no puede haber PASS por ausencia"
  else
    pass "un recibo AUSENTE se rechaza: no hay PASS por ausencia"
  fi

  : > "$sandbox/empty-receipt.txt"
  if forge_receipt_require "$sandbox/empty-receipt.txt" >/dev/null 2>&1; then
    fail "un recibo VACIO se acepto como evidencia"
  else
    pass "un recibo VACIO se rechaza"
  fi

  # A receipt whose accreditation was revoked is contradictory evidence.
  sed 's/^ACCREDITATION=PASS$/ACCREDITATION=FAILED/' "$receipt" > "$sandbox/revoked-receipt.txt"
  if forge_receipt_require "$sandbox/revoked-receipt.txt" >/dev/null 2>&1; then
    fail "un recibo con la acreditacion revocada se acepto"
  else
    pass "un recibo con la acreditacion revocada se rechaza"
  fi

  # A receipt whose closure was not confirmed is contradictory evidence too.
  sed 's/^CLOSURE=CONFIRMED$/CLOSURE=UNCONFIRMED/' "$receipt" > "$sandbox/unclosed-receipt.txt"
  if forge_receipt_require "$sandbox/unclosed-receipt.txt" >/dev/null 2>&1; then
    fail "un recibo con el cierre sin confirmar se acepto"
  else
    pass "un recibo con el cierre sin confirmar se rechaza"
  fi

  # The CLOSURE has THREE independent links. A receipt that declares the
  # closure as CONFIRMED but does not carry the OBSERVED effective
  # termination of the private PID 1 is contradictory evidence: the signal
  # that was sent is not an observed termination.
  sed 's/^PID1_COMPLETION_OBSERVED=PASS$/PID1_COMPLETION_OBSERVED=NO/' \
    "$receipt" > "$sandbox/unobserved-pid1-receipt.txt"
  if forge_receipt_require "$sandbox/unobserved-pid1-receipt.txt" >/dev/null 2>&1; then
    fail "un recibo sin la terminacion observada del PID 1 se acepto"
  else
    pass "un recibo sin la terminacion observada del PID 1 se rechaza"
  fi

  # The same for the RC of the launcher: a launcher that was waited for but
  # returned a non-zero RC did not close cleanly.
  sed 's/^LAUNCHER_RC=0$/LAUNCHER_RC=1/' "$receipt" > "$sandbox/failed-launcher-receipt.txt"
  if forge_receipt_require "$sandbox/failed-launcher-receipt.txt" >/dev/null 2>&1; then
    fail "un recibo con el RC del launcher distinto de cero se acepto"
  else
    pass "un recibo con el RC del launcher distinto de cero se rechaza"
  fi

  # A receipt that declares the product cleanup as NOT observed is not
  # certifiable: UNKNOWN is never a PASS.
  sed 's/^PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=YES$/PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=NO/' \
    "$receipt" > "$sandbox/unobserved-receipt.txt"
  if [ "$(forge_receipt_product_cleanup "$sandbox/unobserved-receipt.txt")" = "UNKNOWN" ]; then
    pass "una limpieza del producto NO observada es UNKNOWN y nunca un PASS"
  else
    fail "una limpieza del producto NO observada se leyo como un PASS"
  fi

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

  # The accredited package lives INSIDE the sandbox prefix. The REAL prefix
  # of the machine must not be touched by this install: its state is
  # captured before the install and compared after it.
  local real_prefix_package
  real_prefix_package="$FORGE_TEST_REAL_HOME/.local/share/forge/opencode-v2/node_modules/@opencode/cli/package.json"
  local real_prefix_state_before
  if [ -f "$real_prefix_package" ]; then
    real_prefix_state_before="present:$(sha256sum "$real_prefix_package" | cut -d' ' -f1)"
  else
    real_prefix_state_before="absent"
  fi

  install_opencode_fixture "$home" "$fixture_repo" > "$sandbox/install.out" 2>&1 || install_rc=$?
  assert_equal "install de referencia para el binario pinado termina correctamente" "0" "$install_rc"

  if [ "$install_rc" -ne 0 ]; then
    TMP_TEST_HOME=""
    rm -rf "$sandbox"
    return
  fi

  local real_prefix_state_after
  if [ -f "$real_prefix_package" ]; then
    real_prefix_state_after="present:$(sha256sum "$real_prefix_package" | cut -d' ' -f1)"
  else
    real_prefix_state_after="absent"
  fi
  assert_equal "el install no toca el paquete del prefijo REAL de OpenCode" \
    "$real_prefix_state_before" "$real_prefix_state_after"

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

  # The ACCREDITED layout: the entry of `.bin` is a LINK that resolves to the
  # executable of the package @opencode/cli, and the package.json of that
  # package accredits the pinned identity and version. The launcher refuses
  # to run anything else, so the installation must produce exactly this.
  local package_dir expected_package_binary package_name package_version
  package_dir="$expected_prefix/node_modules/@opencode/cli"
  expected_package_binary="$package_dir/bin/opencode"

  if [ -L "$expected_binary" ] \
    && [ "$(readlink "$expected_binary")" = "../@opencode/cli/bin/opencode" ]; then
    pass "el binario pinado es el enlace acreditado de .bin"
  else
    fail "el binario pinado no es el enlace acreditado de .bin"
  fi

  if [ -x "$expected_package_binary" ]; then
    pass "el paquete @opencode/cli instala su ejecutable en bin/"
  else
    fail "el paquete @opencode/cli no instala su ejecutable en bin/"
  fi

  package_name="$(jq -r '.name // ""' "$package_dir/package.json" 2>/dev/null || true)"
  package_version="$(jq -r '.version // ""' "$package_dir/package.json" 2>/dev/null || true)"
  assert_equal "el paquete instalado se identifica como @opencode/cli" \
    "@opencode/cli" "$package_name"
  assert_equal "el paquete instalado declara la version fijada" \
    "2.1.4" "$package_version"

  local reported_version
  reported_version="$("$expected_binary" --version 2>/dev/null | tr -d ' \n' || true)"
  assert_equal "el binario pinado reporta la version fijada" \
    "opencodev2.1.4" "$reported_version"

  if [ ! -e "$expected_prefix/node_modules/@opencode/cli" ]; then
    fail "el paquete acreditado no se instala en el prefijo aislado"
  else
    pass "el paquete acreditado se instala en el prefijo aislado"
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
  assert_equal "manifest opencode de target=both registra el binario pinado" \
    "$home/.local/share/forge/opencode-v2/node_modules/.bin/opencode" \
    "$(manifest_opencode_value "$state" binary)"
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
  state_sha_before="$(sha256sum "$state" | cut -d' ' -f1 || true)"
  state_mtime_before="$(stat -c '%y' "$state")"

  run_isolated "$home" OPENCODE_CONFIG="$other_config" \
    bash "$fixture_repo/install.sh" status > "$sandbox/status.out" 2>&1 || status_rc=$?
  assert_equal "status sale 1 con manifest legacy sin config_file (fake sin runtime operable)" \
    "1" "$status_rc"
  assert_status_degraded "status legacy" "$sandbox/status.out"
  assert_contains "status usa el fallback de config del overlay registrado" \
    "OpenCode overlay ($default_dir)" "$sandbox/status.out"
  assert_no_route_warning "status legacy no inventa un WARN de config" "$sandbox/status.out"

  if grep -qF 'opencode.jsonc: JSONC valido' "$sandbox/status.out"; then
    pass "status valida el fallback <dir>/opencode.jsonc"
  else
    fail "status no validó el fallback <dir>/opencode.jsonc"
  fi

  state_sha_after="$(sha256sum "$state" | cut -d' ' -f1 || true)"
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
  assert_equal "status sale 1 validando el overlay reinstalado por update (fake sin runtime operable)" \
    "1" "$status_update_rc"
  assert_status_degraded "status tras update" "$sandbox/status-after-update.out"
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
  assert_equal "status sale 1 validando el overlay reinstalado por repair (fake sin runtime operable)" \
    "1" "$status_repair_rc"
  assert_status_degraded "status tras repair" "$sandbox/status-after-repair.out"
  assert_contains "status diagnostica la ruta reinstalada por repair" \
    "OpenCode overlay ($route_c)" "$sandbox/status-after-repair.out"
  assert_equal "update/repair conservan state_schema 3" "3" "$(jq -r '.state_schema' "$state")"

  TMP_TEST_HOME=""
  rm -rf "$sandbox"
}

# degraded_contract_violations <status_out> <doctor_out> <repo_root>
# Prints one line per violated rule of the degradation contract. An empty
# output means the contract holds. It never touches the suite counters, so it
# can be used as a control over the contract itself.
degraded_contract_violations() {
  local status_out="$1" doctor_out="$2" repo="$3"

  if grep -qF "Estado general: OK" "$status_out" 2>/dev/null; then
    echo "status declara salud general (Estado general: OK) con un runtime no operable"
  fi
  if ! grep -qF "Estado general: DEGRADADO" "$status_out" 2>/dev/null; then
    echo "status no declara la degradacion de forma explicita (Estado general: DEGRADADO ausente)"
  fi
  if ! grep -qE "$PLUGIN_RUNTIME_MESSAGE_PREFIX.+" "$status_out" 2>/dev/null; then
    echo "status no identifica el sondeo de inventario de plugins como no ejecutable"
  fi
  if ! grep -qE "$PLUGIN_RUNTIME_MESSAGE_PREFIX.+.*(OPENCODE_DB|binario pinado|aislamiento)" \
      "$status_out" 2>/dev/null; then
    echo "status no muestra una causa identificable del sondeo de inventario"
  fi
  if ! grep -qE "FAIL[[:space:]]+UNAVAILABLE: $PLUGIN_RUNTIME_MESSAGE_PREFIX" "$doctor_out" 2>/dev/null; then
    echo "doctor no reporta el sondeo de inventario como FAIL UNAVAILABLE"
  fi
  if grep -qE "Resumen: FAILs=0" "$doctor_out" 2>/dev/null; then
    echo "doctor declara FAILs=0 con un runtime no operable"
  fi
  if grep -qF "plugin list: enumer" "$status_out" "$doctor_out" 2>/dev/null; then
    echo "se simulo una enumeracion runtime exitosa"
  fi
  if ! grep -qF "opencode.jsonc: JSONC valido" "$status_out" 2>/dev/null; then
    echo "las comprobaciones estaticas del overlay dejaron de superarse"
  fi
  if ! grep -qF "$PLUGIN_RUNTIME_FAMILY_BINDING" "$repo/install.sh" 2>/dev/null; then
    echo "el mensaje renderizado no esta ligado a la familia plugin-runtime"
  fi

  return 0
}

# The contract of the degradation must be able to REJECT a false healthy
# output: a contract that accepts anything would be worthless. This control
# runs WITHOUT any runtime, over synthetic diagnostics.
test_degradation_contract_is_not_vacuous() {
  echo ""
  echo "--- test_degradation_contract_is_not_vacuous"

  local sandbox repo
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/contract-control.XXXXXX")"
  repo="$(mktemp -d "$TEST_TMP_ROOT/contract-control-repo.XXXXXX")"
  create_repo_fixture "$repo" >/dev/null

  # A synthetic HEALTHY output: the contract must reject it.
  cat > "$sandbox/status-healthy.out" <<'EOF'
    OK       opencode.jsonc: JSONC valido
    OK       plugin list: enumeración runtime exacta de forge-guard
  Estado general: OK
EOF
  cat > "$sandbox/doctor-healthy.out" <<'EOF'
  PASS  opencode.jsonc: JSONC valido
  Resumen: FAILs=0  WARNs=0
EOF

  local violations
  violations="$(degraded_contract_violations "$sandbox/status-healthy.out" \
    "$sandbox/doctor-healthy.out" "$repo" | grep -c . || true)"
  if [ "$violations" -gt 0 ]; then
    pass "el contrato de degradacion rechaza una salida sana falsa (control negativo, sin runtime)"
  else
    fail "el contrato de degradacion acepta una salida sana falsa (control negativo, sin runtime)"
  fi

  # The real degraded shape must be ACCEPTED by the very same contract.
  cat > "$sandbox/status-degraded.out" <<'EOF'
    OK       opencode.jsonc: JSONC valido
    UNAVAILABLE plugin list no ejecutada: el binario pinado no pudo resolver OPENCODE_DB antes del aislamiento
      → bash install.sh install --target=opencode
  Estado general: DEGRADADO (ver detalles arriba)
EOF
  cat > "$sandbox/doctor-degraded.out" <<'EOF'
  PASS  opencode.jsonc: JSONC valido
  FAIL  UNAVAILABLE: plugin list no ejecutada: el binario pinado no pudo resolver OPENCODE_DB antes del aislamiento
  HINT  bash install.sh install --target=opencode
  Resumen: FAILs=3  WARNs=1
EOF

  violations="$(degraded_contract_violations "$sandbox/status-degraded.out" \
    "$sandbox/doctor-degraded.out" "$repo" | grep -c . || true)"
  if [ "$violations" -eq 0 ]; then
    pass "el contrato de degradacion acepta la forma degradada real (control positivo, sin runtime)"
  else
    fail "el contrato de degradacion rechaza la forma degradada real:"
    degraded_contract_violations "$sandbox/status-degraded.out" \
      "$sandbox/doctor-degraded.out" "$repo" | sed 's/^/    /' >&2
  fi

  rm -rf "$sandbox" "$repo"
}

# The environmental contract of the real OpenCode prefix, exercised on
# SYNTHETIC homes so the real installation of this machine is never touched,
# modified nor deleted (only its metadata is read, by the suite's own
# fingerprint):
#
#   * clean runner: the prefix does not exist before and the suite does not
#     create it,
#   * machine with a previous installation: the prefix exists before and
#     stays untouched. The preexistence is NOT a failure and it does not mask
#     a real mutation.
test_forge_prefix_environment_contracts() {
  echo ""
  echo "--- test_forge_prefix_environment_contracts"

  local sandbox
  sandbox="$(mktemp -d "$TEST_TMP_ROOT/prefix-contract.XXXXXX")"

  # --- clean runner: the prefix does not exist -------------------------
  local clean_home="$sandbox/clean-home"
  mkdir -p "$clean_home"
  local clean_before clean_output clean_rc=0
  clean_before="$(forge_protected_snapshot "$clean_home")"
  mkdir -p "$clean_home/.local/share"
  clean_output="$(forge_assert_no_forge_prefix "$clean_before" "$clean_home" 2>&1)" || clean_rc=$?
  if [ "$clean_rc" -eq 0 ]; then
    pass "runner limpio: el prefijo real de OpenCode no se crea"
  else
    fail "runner limpio: el prefijo real de OpenCode se crearia o no se pudo comprobar: $clean_output"
  fi

  # Negative control: if the prefix appeared, the guard must catch it.
  mkdir -p "$clean_home/.local/share/forge/opencode-v2"
  clean_rc=0
  clean_output="$(forge_assert_no_forge_prefix "$clean_before" "$clean_home" 2>&1)" || clean_rc=$?
  if [ "$clean_rc" -ne 0 ] && printf '%s' "$clean_output" | grep -q "la suite instalo el prefijo real"; then
    pass "runner limpio: el guard detecta la creacion del prefijo real (control negativo)"
  else
    fail "runner limpio: el guard no detecta la creacion del prefijo real: $clean_output"
  fi

  # --- machine with a previous installation -----------------------------
  local prior_home="$sandbox/prior-home"
  mkdir -p "$prior_home/.local/share/forge/opencode-v2"
  printf 'preexisting\n' > "$prior_home/.local/share/forge/opencode-v2/marker"
  local prior_before prior_output prior_rc=0
  prior_before="$(forge_protected_snapshot "$prior_home")"
  prior_output="$(forge_assert_no_forge_prefix "$prior_before" "$prior_home" 2>&1)" || prior_rc=$?
  if [ "$prior_rc" -eq 0 ]; then
    pass "instalacion preexistente: la preexistencia NO se reporta como fallo de la suite"
  else
    fail "instalacion preexistente: la preexistencia se reporta como fallo: $prior_output"
  fi

  # And the preexistence must not mask a real mutation of the real tree.
  printf 'mutated\n' > "$prior_home/.local/share/forge/opencode-v2/marker"
  local mutation_rc=0
  forge_assert_protected_unchanged "$prior_before" "$prior_home" >/dev/null 2>&1 || mutation_rc=$?
  if [ "$mutation_rc" -ne 0 ]; then
    pass "instalacion preexistente: una mutacion real si se detecta (la preexistencia no la tapa)"
  else
    fail "instalacion preexistente: una mutacion real NO se detecta"
  fi

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
test_launcher_fails_closed_without_a_valid_manifest
test_launcher_isolates_mcp_list_from_the_shared_service
test_containment_controls
test_pinned_binary_lives_in_the_isolated_prefix
test_uninstall_removes_registered_overlay
test_second_uninstall_without_state_is_informed_noop
test_uninstall_with_user_residue_does_not_report_todo_ok
test_uninstall_without_binary_in_state_fails_closed
test_uninstall_with_malformed_binary_fails_closed
test_uninstall_failure_preserves_state
test_manifest_records_opencode_paths_for_both_target
test_legacy_manifest_without_config_file
test_update_and_repair_sync_opencode_paths
test_degradation_contract_is_not_vacuous
test_forge_prefix_environment_contracts

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
