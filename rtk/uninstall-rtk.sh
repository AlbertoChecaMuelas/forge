#!/usr/bin/env bash
# rtk/uninstall-rtk.sh — Remove RTK if it was installed by forge.
# Usage: bash rtk/uninstall-rtk.sh
#   or via: bash install.sh rtk uninstall
#
# Removes ~/.forge/bin/rtk when state records installed_by_us=true.
# If the binary is already absent, the operation is treated as a no-op (idempotent).
set -euo pipefail

ARSENAL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARSENAL_STATE_FILE="${HOME}/.forge-state.json"

# shellcheck disable=SC1091
source "$ARSENAL_ROOT/lib/rtk.sh"

echo "[rtk] checking if RTK was installed by forge..."

# Read state
if [ ! -f "$ARSENAL_STATE_FILE" ]; then
  echo "[rtk] no state file encontrado ($ARSENAL_STATE_FILE); nada que desinstalar"
  exit 0
fi

if ! jq empty "$ARSENAL_STATE_FILE" 2>/dev/null; then
  echo "[rtk] ERROR: state file inválido" >&2
  exit 1
fi

installed_by_us="$(jq -r '.rtk.installed_by_us // false' "$ARSENAL_STATE_FILE")"

if [ "$installed_by_us" != "true" ]; then
  echo "[rtk] RTK no fue instalado por forge (installed_by_us=false); se mantiene"
  exit 0
fi

# RTK was installed by us — remove the binary from ~/.forge/bin/
forge_rtk_remove_binary

# Update state
tmp="$(mktemp)"
jq '.rtk.installed_by_us = false | .rtk.detected_version = null' "$ARSENAL_STATE_FILE" > "$tmp"
# shellcheck disable=SC2015  # intentional: A && B || C used for atomic write-or-cleanup
jq empty "$tmp" && mv "$tmp" "$ARSENAL_STATE_FILE" || rm -f "$tmp"
echo "[rtk] state actualizado"

# Remove PATH snippet marker block from shell profiles.
# forge_rtk_strip_path_snippet handles both the current marker (# >>> forge rtk path >>>)
# and the legacy atenea-arsenal marker for backward-compat with old installs.
forge_rtk_strip_path_snippet
