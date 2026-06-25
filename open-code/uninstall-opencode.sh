#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_LAUNCHER="$SCRIPT_DIR/forge-opencode.sh"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode-forge}"
AGENTS_DIR="$CONFIG_DIR/agents"
PLUGINS_DIR="$CONFIG_DIR/plugins"
LAUNCHER_PATH="$HOME/.local/bin/forge-opencode"

for role in applier senior tech tester orchestrator; do
  rm -f "$AGENTS_DIR/${role}.md"
done

rm -f "$PLUGINS_DIR/forge-guard.js"
rm -f "$CONFIG_DIR/opencode.jsonc"
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

rmdir "$AGENTS_DIR" 2>/dev/null || true
rmdir "$PLUGINS_DIR" 2>/dev/null || true
rmdir "$CONFIG_DIR" 2>/dev/null || true

echo "[forge-opencode] uninstall completed for ${CONFIG_DIR/#$HOME/\~}"
