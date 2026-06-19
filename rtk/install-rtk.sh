#!/usr/bin/env bash
# rtk/install-rtk.sh — Thin wrapper to run the RTK decision tree standalone.
# Usage: bash rtk/install-rtk.sh
#   or via: bash install.sh rtk install
#
# Loads lib/rtk.sh and calls forge_rtk_decide.
# Writes RTK state fields to ~/.forge-state.json when possible.
set -euo pipefail

ARSENAL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARSENAL_STATE_FILE="${HOME}/.forge-state.json"

# Load required libs
# shellcheck disable=SC1091
source "$ARSENAL_ROOT/lib/json-merge.sh"
# shellcheck disable=SC1091
source "$ARSENAL_ROOT/lib/rtk.sh"

echo "[rtk] running RTK decision tree (standalone)"
forge_rtk_decide || true

# On success path: inject PATH snippet and print hint (idempotent — safe to call even
# if forge_rtk_adjust_via_tarball already called the helper internally).
if [ "${_RTK_INSTALLED_BY_US:-}" = "true" ]; then
  _forge_rtk_inject_path_snippet
  echo "[rtk] source ~/.zshrc (o abre un terminal nuevo) para que 'rtk' esté disponible en PATH."
fi

# Persist RTK state into state file if it exists (or create a minimal one)
pinned="$(cat "$ARSENAL_ROOT/rtk/VERSION" 2>/dev/null || echo "0.42.4")"

_write_rtk_state() {
  local installed_by_us="${_RTK_INSTALLED_BY_US:-false}"
  local detected_version="${_RTK_DETECTED_VERSION:-}"
  local install_failed="${_RTK_INSTALL_FAILED:-}"
  local version_mismatch="${_RTK_VERSION_MISMATCH:-}"

  # Convert shell vars to JSON booleans/nulls
  local installed_by_us_json="false"
  [ "$installed_by_us" = "true" ] && installed_by_us_json="true"

  local install_failed_json="false"
  [ "$install_failed" = "1" ] && install_failed_json="true"

  local version_mismatch_json="false"
  [ "$version_mismatch" = "1" ] && version_mismatch_json="true"

  local detected_json="null"
  [ -n "$detected_version" ] && detected_json="\"$detected_version\""

  local rtk_section
  rtk_section="$(jq -n \
    --arg pinned "$pinned" \
    --argjson detected "$detected_json" \
    --argjson installed_by_us "$installed_by_us_json" \
    --argjson install_failed "$install_failed_json" \
    --argjson version_mismatch "$version_mismatch_json" \
    '{
      pinned_version: $pinned,
      detected_version: $detected,
      installed_by_us: $installed_by_us,
      install_failed: $install_failed,
      version_mismatch: $version_mismatch
    }')"

  if [ -f "$ARSENAL_STATE_FILE" ]; then
    # Update existing state file
    local tmp
    tmp="$(mktemp)"
    jq --argjson rtk "$rtk_section" '.rtk = $rtk' "$ARSENAL_STATE_FILE" > "$tmp"
    # shellcheck disable=SC2015  # intentional: A && B || C used for atomic write-or-cleanup
    jq empty "$tmp" && mv "$tmp" "$ARSENAL_STATE_FILE" || rm -f "$tmp"
    echo "[rtk] state actualizado: $ARSENAL_STATE_FILE"
  else
    echo "[rtk] state file no encontrado ($ARSENAL_STATE_FILE); state RTK no persistido"
  fi
}

_write_rtk_state
