#!/usr/bin/env bash
# lib/catalog.sh — Catalogue of symlinks managed by forge
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
set -euo pipefail

# Guard against double-loading
if [ -n "${_FORGE_CATALOG_LOADED:-}" ]; then
  return 0
fi
_FORGE_CATALOG_LOADED=1

# forge_symlink_catalog
# Emits one line per managed symlink in the format:
#   <src_relative_to_FORGE_ROOT><TAB><dest_relative_to_target_dir>
# OpenCode targets are NOT covered here: open-code/ deploys via
# install-opencode.sh (the former "opencode" arm was dead code).
forge_symlink_catalog() {
  # Derive FORGE_ROOT from the location of this script if not already set
  local _root="${FORGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local _manifest _src _dest
  for _manifest in "$_root"/shared/components/*.json; do
    # Emit entries from both "symlinks" and "target_root_files" arrays
    while IFS=$'\t' read -r _src _dest; do
      if [ ! -f "$_root/$_src" ]; then
        echo "[forge] ERROR: manifest '$_manifest' references missing source: $_src" >&2
        return 1
      fi
      printf '%s\t%s\n' "$_src" "$_dest"
    done < <(jq -r '(.symlinks + .target_root_files) // [] | .[] | "\(.src)\t\(.dest)"' "$_manifest")
  done
}

# forge_components_list
# Prints the name of each component (one per line, alphabetically sorted)
# by iterating shared/components/*.json and stripping the .json extension.
forge_components_list() {
  local _root="${FORGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local _manifest
  for _manifest in "$_root"/shared/components/*.json; do
    basename "$_manifest" .json
  done
}

# forge_components_default_list
# Like forge_components_list but only components installed by default:
# those whose manifest lacks "default": false (absent field means default).
# Opt-in components (e.g. core, the plugin companion) are excluded — they
# are only reachable via an explicit --only=<name>.
forge_components_default_list() {
  local _root="${FORGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local _manifest
  for _manifest in "$_root"/shared/components/*.json; do
    # NOTE: jq's // operator treats false as empty, so (.default // true)
    # would wrongly resolve to true for "default": false — test explicitly.
    if ! jq -e '.default == false' "$_manifest" >/dev/null 2>&1; then
      basename "$_manifest" .json
    fi
  done
}

# forge_components_conflict <a> <b>
# Returns 0 when components <a> and <b> declare a mutual exclusion via the
# optional "conflicts_with" manifest field (checked symmetrically), 1 otherwise.
# A component never conflicts with itself (idempotent re-install).
forge_components_conflict() {
  local _a="$1"
  local _b="$2"
  if [ "$_a" = "$_b" ]; then
    return 1
  fi
  local _root="${FORGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local _ma="$_root/shared/components/${_a}.json"
  local _mb="$_root/shared/components/${_b}.json"
  if [ -f "$_ma" ] && jq -e --arg o "$_b" '(.conflicts_with // []) | index($o) != null' "$_ma" >/dev/null 2>&1; then
    return 0
  fi
  if [ -f "$_mb" ] && jq -e --arg o "$_a" '(.conflicts_with // []) | index($o) != null' "$_mb" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# forge_component_symlinks <name>
# Validates that <name>.json exists under shared/components/, then emits
# its symlink entries as <src><TAB><dest> lines (from .symlinks[] and
# .target_root_files[] if non-empty) — same format as forge_symlink_catalog.
# Exits non-zero with an error message on unknown component.
forge_component_symlinks() {
  local _name="${1:-}"
  if [ -z "$_name" ]; then
    echo "[forge] ERROR: forge_component_symlinks requires a component name" >&2
    return 1
  fi
  local _root="${FORGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  local _manifest="$_root/shared/components/${_name}.json"
  if [ ! -f "$_manifest" ]; then
    echo "[forge] ERROR: unknown component '${_name}' (no manifest at shared/components/${_name}.json)" >&2
    return 1
  fi
  local _src _dest
  while IFS=$'\t' read -r _src _dest; do
    printf '%s\t%s\n' "$_src" "$_dest"
  done < <(jq -r '(.symlinks + (if .target_root_files | length > 0 then .target_root_files else [] end)) | .[] | "\(.src)\t\(.dest)"' "$_manifest")
}
