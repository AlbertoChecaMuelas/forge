#!/usr/bin/env bash
# uninstall-opencode.sh — removes the Forge OpenCode 2 overlay.
#
# It is idempotent: removing an overlay that is not installed succeeds
# silently. Everything it removes is either a Forge-owned artefact (the
# generated agents, the commands, AGENTS.md, the installed config, the plugin
# packages and the pinned OpenCode build) or an OpenCode 1 leftover that the
# migration must not leave behind. Files that Forge does not own are never
# touched.
#
# The containers Forge created (agents/, commands/, plugin-packages/) are
# removed as well, but only when they end up empty: a container that still
# holds something of the user's is kept and reported.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_LAUNCHER="$SCRIPT_DIR/forge-opencode.sh"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode-forge}"
CONFIG_FILE="${OPENCODE_CONFIG:-$CONFIG_DIR/opencode.jsonc}"
AGENTS_DIR="$CONFIG_DIR/agents"
COMMANDS_DIR="$CONFIG_DIR/commands"
LAUNCHER_PATH="$HOME/.local/bin/forge-opencode"
FORGE_BIN_DIR="${FORGE_OPENCODE_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/forge/opencode-v2}"

for role in applier senior tech tester orchestrator; do
  rm -f "$AGENTS_DIR/${role}.md"
done

for cmd in create-plan execute-plan review create-pr pr-description update-changelog; do
  rm -f "$COMMANDS_DIR/${cmd}.md"
done

# Plugins are derived from the installed config, never hardcoded: the
# uninstaller must remove exactly what the installer put in place (the whole
# package tree) plus the OpenCode 1 leftovers. The source root tells the
# helper which packages are Forge-owned, so they are removed too when the
# installed config is already gone (the uninstall is idempotent).
python3 "$SCRIPT_DIR/lib/plugin-sync.py" remove \
  --config "$CONFIG_FILE" \
  --source-root "$SCRIPT_DIR"

rm -f "$CONFIG_FILE"
rm -f "$CONFIG_DIR/AGENTS.md"

if [ -L "$LAUNCHER_PATH" ]; then
  launcher_target="$(readlink "$LAUNCHER_PATH")"
  case "$launcher_target" in
    */open-code/forge-opencode.sh)
      rm -f "$LAUNCHER_PATH"
      ;;
  esac
elif [ -f "$LAUNCHER_PATH" ] && cmp -s "$REPO_LAUNCHER" "$LAUNCHER_PATH"; then
  rm -f "$LAUNCHER_PATH"
fi

# The pinned OpenCode build is Forge-owned: it lives in an isolated Forge
# prefix and is removed with the overlay. The system installation (whatever
# Omarchy or the user installed) is never touched.
if [ -d "$FORGE_BIN_DIR" ]; then
  rm -rf "$FORGE_BIN_DIR"
  echo "[forge-opencode] removed pinned binary prefix: ${FORGE_BIN_DIR/#$HOME/\~}"
fi

# Containers are removed only when they are EMPTY. The overlay may hold files
# that the user put there and those are never touched (V2 contract): a
# container that still holds something is kept, and the uninstaller says so
# explicitly instead of announcing a removal that did not happen.
forge_remove_empty_dir() {
  local dir="$1"

  [ -d "$dir" ] || return 0
  if rmdir "$dir" 2>/dev/null; then
    return 0
  fi
  return 1
}

# forge_list_residue <dir> — print the entries that survive under <dir>.
forge_list_residue() {
  local dir="$1"
  local entry

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '  - %s\n' "${entry#"$dir/"}"
  done < <(find "$dir" -mindepth 1 2>/dev/null | sort)
}

forge_remove_empty_dir "$AGENTS_DIR" || true
forge_remove_empty_dir "$COMMANDS_DIR" || true

if forge_remove_empty_dir "$CONFIG_DIR"; then
  echo "[forge-opencode] uninstall completed for ${CONFIG_DIR/#$HOME/\~}"
else
  echo "[forge-opencode] WARN: no se ha podido borrar el overlay ${CONFIG_DIR/#$HOME/\~}: conserva estos ficheros tuyos" >&2
  forge_list_residue "$CONFIG_DIR" >&2
  echo "[forge-opencode]   → forge no borra ficheros ajenos: revisa y borra ${CONFIG_DIR/#$HOME/\~} manualmente cuando ya no lo necesites" >&2
fi
