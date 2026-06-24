#!/usr/bin/env bash
# rtk/uninstall-rtk.sh — Remove RTK if it was installed by forge.
# Usage: bash rtk/uninstall-rtk.sh
#   or via: bash install.sh rtk uninstall
#
# Removes ~/.forge/bin/rtk when state records installed_by_us=true.
# If the binary is already absent, the operation is treated as a no-op (idempotent).
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORGE_STATE_FILE="${HOME}/.forge-state.json"

# shellcheck disable=SC1091
source "$FORGE_ROOT/lib/rtk.sh"

echo "[rtk] checking if RTK was installed by forge..."

# Read state
if [ ! -f "$FORGE_STATE_FILE" ]; then
  echo "[rtk] no state file encontrado ($FORGE_STATE_FILE); nada que desinstalar"
  exit 0
fi

if ! jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
  echo "[rtk] ERROR: state file inválido" >&2
  exit 1
fi

installed_by_us="$(jq -r '.rtk.installed_by_us // false' "$FORGE_STATE_FILE")"

if [ "$installed_by_us" != "true" ]; then
  echo "[rtk] RTK no fue instalado por forge (installed_by_us=false); se mantiene"
  exit 0
fi

# RTK was installed by us — remove the binary from ~/.forge/bin/
forge_rtk_remove_binary

# Update state
tmp="$(mktemp)"
jq '.rtk.installed_by_us = false | .rtk.detected_version = null' "$FORGE_STATE_FILE" > "$tmp"
# shellcheck disable=SC2015  # intentional: A && B || C used for atomic write-or-cleanup
jq empty "$tmp" && mv "$tmp" "$FORGE_STATE_FILE" || rm -f "$tmp"
echo "[rtk] state actualizado"

# Remove PATH snippet marker block (# >>> forge rtk path >>>) from shell profiles.
forge_rtk_strip_path_snippet
