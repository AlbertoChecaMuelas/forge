#!/usr/bin/env bash
# install.sh — forge installer
# Compatible with bash 3.2+. Uses only indexed arrays (no associative arrays).
set -euo pipefail

# ---------------------------------------------------------------------------
# Core constants
# ---------------------------------------------------------------------------
FORGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
FORGE_VERSION="0.7.5"
FORGE_STATE_FILE="$HOME/.forge-state.json"
FORGE_OPENCODE_DIR_DEFAULT="$HOME/.config/opencode-forge"
# ---------------------------------------------------------------------------
# Effective OpenCode overlay paths.
#
# These MUST mirror open-code/install-opencode.sh exactly, because the overlay
# installer is a child process that inherits this very environment:
#   CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode-forge}"
#   CONFIG_FILE="${OPENCODE_CONFIG:-$CONFIG_DIR/opencode.jsonc}"
#
# The root installer resolves them here so the manifest records where the
# overlay really landed. Recording the default unconditionally would make the
# manifest point at a directory the overlay was never installed into, and
# `status`/`doctor` would then diagnose the wrong location.
# ---------------------------------------------------------------------------
FORGE_OPENCODE_DIR="${OPENCODE_CONFIG_DIR:-$FORGE_OPENCODE_DIR_DEFAULT}"
FORGE_OPENCODE_CONFIG="${OPENCODE_CONFIG:-$FORGE_OPENCODE_DIR/opencode.jsonc}"
FORGE_OPENCODE_INSTALLER="$FORGE_ROOT/open-code/install-opencode.sh"
FORGE_OPENCODE_UNINSTALLER="$FORGE_ROOT/open-code/uninstall-opencode.sh"

# --- summary accumulator ---
_FORGE_WARN_COUNT=0
_FORGE_ERR_COUNT=0

# --- RTK block tracker (the rtk.tracked block prints at most once per run) ---
_FORGE_RTK_TRACKED_PRINTED=0

forge_warn() {
  local msg="${1:-}"
  local hint="${2:-}"
  echo "[forge] WARN: $msg" >&2
  [ -n "$hint" ] && echo "[forge]   → $hint" >&2
  eval "_FORGE_WARN_MSG_${_FORGE_WARN_COUNT}=\$msg"
  eval "_FORGE_WARN_HINT_${_FORGE_WARN_COUNT}=\$hint"
  _FORGE_WARN_COUNT=$(( _FORGE_WARN_COUNT + 1 ))
}

forge_err() {
  local msg="${1:-}"
  local hint="${2:-}"
  echo "[forge] ERROR: $msg" >&2
  [ -n "$hint" ] && echo "[forge]   → $hint" >&2
  eval "_FORGE_ERR_MSG_${_FORGE_ERR_COUNT}=\$msg"
  eval "_FORGE_ERR_HINT_${_FORGE_ERR_COUNT}=\$hint"
  _FORGE_ERR_COUNT=$(( _FORGE_ERR_COUNT + 1 ))
}

_forge_reset_summary() {
  _FORGE_WARN_COUNT=0
  _FORGE_ERR_COUNT=0
}

_forge_summarize_rtk() {
  # Gate: only emit RTK warnings when rtk-hook is a recorded component OR
  # rtk.tracked=true is set in state (Path A tracking via rtk install).
  if [ ! -f "${FORGE_STATE_FILE:-}" ]; then
    return 0
  fi
  local _has_rtk_hook
  _has_rtk_hook="$(jq -r '[.targets_manifest[]?.components[]? | select(. == "rtk-hook")] | length' "$FORGE_STATE_FILE" 2>/dev/null || echo "0")"
  local _rtk_tracked
  _rtk_tracked="$(jq -r '.rtk.tracked // false' "$FORGE_STATE_FILE" 2>/dev/null || echo "false")"
  if [ "${_has_rtk_hook:-0}" = "0" ] && [ "$_rtk_tracked" != "true" ]; then
    return 0
  fi

  # Determine pinned version: prefer rtk/VERSION (single source of truth), fall back to state.
  local pinned=""
  if [ -f "$FORGE_ROOT/rtk/VERSION" ]; then
    pinned="$(cat "$FORGE_ROOT/rtk/VERSION" 2>/dev/null || true)"
  fi
  if [ -z "$pinned" ] && [ -f "${FORGE_STATE_FILE:-}" ]; then
    pinned=$(jq -r '.rtk.pinned_version // empty' "$FORGE_STATE_FILE" 2>/dev/null || true)
  fi
  [ -z "$pinned" ] && pinned="${RTK_PINNED_VERSION:-0.43.0}"

  # Live probe (state file is stale after the rtk-hook component migration: cmd_install no
  # longer calls forge_rtk_decide, so detected_version is always null in the state file).
  # Prefer forge_rtk_detect/forge_rtk_compare from lib/rtk.sh when available.
  local detected="absent"
  if command -v forge_rtk_detect >/dev/null 2>&1; then
    detected="$(forge_rtk_detect)"
  elif command -v rtk >/dev/null 2>&1; then
    local _v_out
    _v_out="$(rtk --version 2>&1 || true)"
    if printf '%s\n' "$_v_out" | grep -qE '^rtk[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+'; then
      detected="$(printf '%s\n' "$_v_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    else
      detected="collision"
    fi
  fi

  case "$detected" in
    absent)
      echo "WARN|RTK no instalado (instalación automática no disponible)|bash install.sh rtk install"
      return 0
      ;;
    collision)
      echo "WARN|RTK: colisión con otro binario 'rtk' en PATH (probable Rust Type Kit)|Desinstala el otro binario o ajusta PATH; luego: bash install.sh rtk install"
      return 0
      ;;
    installed:*)
      # RTK binary is at ~/.forge/bin/rtk but not on PATH — corrective WARN.
      echo "WARN|RTK instalado pero ~/.forge/bin no está en PATH → source ~/.zshrc o reinstala|bash install.sh rtk install"
      return 0
      ;;
    shadowed:*)
      local _shadow_winner _shadow_ver _forge_ver
      _shadow_winner="$(printf '%s\n' "$detected" | cut -d: -f2)"
      _shadow_ver="$(printf '%s\n' "$detected" | cut -d: -f3)"
      _forge_ver="$(printf '%s\n' "$detected" | cut -d: -f4)"
      echo "WARN|RTK ${_shadow_ver} instalado vía Homebrew sombrea al de forge (${_forge_ver})|Para solucionar:"
      echo "WARN|  1. brew uninstall rtk|"
      echo "WARN|  2. bash install.sh rtk install|"
      echo "WARN|  3. source ~/.zshrc (o abre un terminal nuevo)|"
      return 0
      ;;
  esac

  # detected is a semver — compare against pin
  local cmp="eq"
  if command -v forge_rtk_compare >/dev/null 2>&1; then
    cmp="$(forge_rtk_compare "$detected" "$pinned")"
  else
    if [ "$detected" != "$pinned" ]; then
      local _lower
      _lower="$(printf '%s\n%s\n' "$detected" "$pinned" | sort -V | head -1)"
      if [ "$_lower" = "$detected" ]; then cmp="lt"; else cmp="gt"; fi
    fi
  fi

  case "$cmp" in
    eq) : ;;  # all good, no warning
    lt) echo "WARN|RTK $detected desactualizado (pin $pinned)|bash install.sh rtk install" ;;
    gt) echo "WARN|RTK $detected > pin $pinned (versión no certificada)|bash install.sh rtk install" ;;
  esac
}
forge_print_summary() {
  local label="${1:-operación}"
  local GREEN='\033[32m'
  local YELLOW='\033[33m'
  local RED='\033[31m'
  local RESET='\033[0m'
  local rtk_lines has_rtk_warn=0 total_warn total_err i msg hint

  printf '\n=== Resumen: %s ===\n' "$label"

  rtk_lines=$(_forge_summarize_rtk 2>/dev/null)
  [ -n "$rtk_lines" ] && has_rtk_warn=1

  total_warn=$(( _FORGE_WARN_COUNT + has_rtk_warn ))
  total_err=$_FORGE_ERR_COUNT

  if [ "$total_err" -eq 0 ] && [ "$total_warn" -eq 0 ]; then
    printf '%sTodo OK.%s\n' "$GREEN" "$RESET" # SC2059: variables as args, not in format
    printf '\n'
    return 0
  fi

  if [ "$total_err" -gt 0 ]; then
    printf "${RED}Errores (%d):${RESET}\n" "$total_err"
    i=0
    while [ "$i" -lt "$_FORGE_ERR_COUNT" ]; do
      eval "msg=\${_FORGE_ERR_MSG_${i}}"
      eval "hint=\${_FORGE_ERR_HINT_${i}}"
      printf '  • %s\n' "$msg"
      [ -n "$hint" ] && printf '    → %s\n' "$hint"
      i=$(( i + 1 ))
    done
  fi

  if [ "$total_warn" -gt 0 ]; then
    printf "${YELLOW}Avisos (%d):${RESET}\n" "$total_warn"
    i=0
    while [ "$i" -lt "$_FORGE_WARN_COUNT" ]; do
      eval "msg=\${_FORGE_WARN_MSG_${i}}"
      eval "hint=\${_FORGE_WARN_HINT_${i}}"
      printf '  • %s\n' "$msg"
      [ -n "$hint" ] && printf '    → %s\n' "$hint"
      i=$(( i + 1 ))
    done
    if [ "$has_rtk_warn" -eq 1 ]; then
      while IFS='|' read -r _type rtk_msg rtk_hint; do # _type field read but not used
        printf '  • %s\n' "$rtk_msg"
        [ -n "$rtk_hint" ] && printf '    → %s\n' "$rtk_hint"
      done <<EOF
$rtk_lines
EOF
    fi
  fi

  printf '\n'
}
# --- end summary accumulator ---

# ---------------------------------------------------------------------------
# Load libs (tolerant: lib/rtk.sh may not exist yet in early phases)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$FORGE_ROOT/lib/symlink.sh"
# shellcheck source=/dev/null
source "$FORGE_ROOT/lib/json-merge.sh"
# shellcheck source=/dev/null
source "$FORGE_ROOT/lib/catalog.sh"
_rtk_lib="$FORGE_ROOT/lib/rtk.sh"
# shellcheck source=/dev/null  # path is constructed at runtime
[ -f "$_rtk_lib" ] && source "$_rtk_lib"
unset _rtk_lib

# ---------------------------------------------------------------------------
# Banner (green, only for install and update)
# ---------------------------------------------------------------------------
forge_banner() {
  printf '\033[32m'
  printf '░█▀▀░█▀█░█▀▄░█▀▀░█▀▀\n'
  printf '░█▀░░█░█░█▀▄░█░▄░█▀▀\n'
  printf '░▀░░░▀▀▀░▀░▀░▀▀░░▀▀▀\n'
  printf '\033[0m'
  printf '\n  forge v%s\n\n' "$FORGE_VERSION"
}

# ---------------------------------------------------------------------------
# Usage / help
# ---------------------------------------------------------------------------
forge_usage() {
  cat <<EOF
forge v${FORGE_VERSION} — installer for forge / Claude Code devtools

Usage:
  bash install.sh <subcommand> [options]

Subcommands:
  install      Install symlinks, merge settings and (optionally) RTK
  update       git pull + repair + (optionally) update RTK
  status       Show current install state
  uninstall    Remove symlinks, restore original settings and remove pinned RTK
  repair       Re-create broken symlinks and re-apply settings merge
  doctor       Diagnose environment (read-only)
  version      Imprime la versión y sale
  rtk install  Install/upgrade RTK to pinned version
  rtk uninstall Remove RTK if installed by forge

Options (install):
  --target=claude|opencode|both Target directory (default: claude)
  --only=<comp>[,<comp>...]     Install only the listed components
                                (core, the plugin companion, is opt-in only)
  --show-cost                   Muestra línea de coste por sesión en la statusline (por defecto oculta)

Options (uninstall):
  --component=<name>            Remove a single component, leave the rest intact
  --keep-rtk                    Full uninstall: keep the pinned RTK binary + PATH snippet
  --purge                       Also delete *.forge-bak-* backups and settings.json.pre-forge

Other:
  -h, --help                    Show this help

EOF
}

# ---------------------------------------------------------------------------
# Resolve targets
# Returns space-separated list of absolute paths in FORGE_TARGETS (global)
# Sets FORGE_TARGET_NAMES (parallel: "claude")
# ---------------------------------------------------------------------------
# We use two indexed arrays: _target_paths and _target_names
# Caller reads FORGE_TARGETS_COUNT, FORGE_TARGET_PATH_N, FORGE_TARGET_NAME_N
# (indexed by 0..N-1) to avoid subshell issues with bash 3.2.

_forge_targets_count=0
_forge_target_path_0=""
_forge_target_name_0=""
_forge_target_path_1=""
_forge_target_name_1=""

forge_resolve_targets() {
  local target_arg="${1:-claude}"
  _forge_targets_count=0

  local claude_dir="$HOME/.claude"
  # The OpenCode target resolves to the directory the overlay installer will
  # really use (OPENCODE_CONFIG_DIR with its default), not to the default
  # unconditionally: the manifest records this path.
  local opencode_dir="$FORGE_OPENCODE_DIR"

  case "$target_arg" in
    claude)
      mkdir -p "$claude_dir"
      _forge_targets_count=1
      _forge_target_path_0="$claude_dir"
      _forge_target_name_0="claude"
      ;;
    opencode)
      mkdir -p "$opencode_dir"
      _forge_targets_count=1
      _forge_target_path_0="$opencode_dir"
      _forge_target_name_0="opencode"
      ;;
    both)
      mkdir -p "$claude_dir" "$opencode_dir"
      _forge_targets_count=2
      _forge_target_path_0="$claude_dir"
      _forge_target_name_0="claude"
      _forge_target_path_1="$opencode_dir"
      _forge_target_name_1="opencode"
      ;;
    *)
      echo "[forge] ERROR: --target debe ser claude, opencode o both (got: $target_arg)" >&2
      return 1
      ;;
  esac
}

forge_state_has_opencode_target() {
  if [ ! -f "$FORGE_STATE_FILE" ]; then
    return 1
  fi

  jq -e '[(.targets_manifest // [])[]?.name] | index("opencode") != null' "$FORGE_STATE_FILE" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Recorded OpenCode overlay paths (the manifest is the source of truth)
# ---------------------------------------------------------------------------
# The state file records where the overlay installer really deployed the
# overlay: `dir` (the directory holding agents/, commands/ and AGENTS.md) and
# `config_file` (the JSONC config, which may live outside `dir` when
# OPENCODE_CONFIG points elsewhere).
#
# These helpers read that record. They fall back to the effective paths only
# when the state file carries no opencode entry (a legacy state, or no
# installation at all): in that case there is nothing better to go on.
#
# _forge_state_opencode_dir — prints the recorded directory
# _forge_state_opencode_config — prints the recorded config file
_forge_state_opencode_dir() {
  local _dir=""

  if [ -f "$FORGE_STATE_FILE" ] && jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    _dir="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.dir // empty)' \
      "$FORGE_STATE_FILE" 2>/dev/null || true)"
  fi

  if [ -n "$_dir" ]; then
    printf '%s\n' "$_dir"
    return 0
  fi
  printf '%s\n' "$FORGE_OPENCODE_DIR"
}

_forge_state_opencode_config() {
  local _cfg=""

  if [ -f "$FORGE_STATE_FILE" ] && jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    _cfg="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.config_file // empty)' \
      "$FORGE_STATE_FILE" 2>/dev/null || true)"
  fi

  if [ -n "$_cfg" ]; then
    printf '%s\n' "$_cfg"
    return 0
  fi
  printf '%s\n' "$(_forge_state_opencode_dir)/opencode.jsonc"
}

# _forge_state_sync_opencode_paths
# Records where the overlay installer just deployed the overlay. Used after a
# (re)install performed by `update`/`repair`: the manifest must keep pointing
# at the directory that really holds the overlay, otherwise `status`/`doctor`
# would diagnose a location the overlay no longer occupies.
_forge_state_sync_opencode_paths() {
  if [ ! -f "$FORGE_STATE_FILE" ] || ! jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    return 0
  fi

  local _tmp
  _tmp="$(mktemp)"
  jq \
    --arg dir "$FORGE_OPENCODE_DIR" \
    --arg config_file "$FORGE_OPENCODE_CONFIG" \
    '
    .targets_manifest = (
      (.targets_manifest // [])
      | map(if .name == "opencode" then .dir = $dir | .config_file = $config_file else . end)
    )
    ' "$FORGE_STATE_FILE" > "$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 0; }

  if jq empty "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$FORGE_STATE_FILE"
  else
    rm -f "$_tmp"
  fi
  return 0
}

forge_run_opencode_installer() {
  if [ ! -f "$FORGE_OPENCODE_INSTALLER" ]; then
    echo "[forge] ERROR: OpenCode target requested but installer is missing: $FORGE_OPENCODE_INSTALLER" >&2
    echo "[forge]   → completa la overlay OpenCode o usa --target=claude" >&2
    return 1
  fi

  bash "$FORGE_OPENCODE_INSTALLER"
}

forge_run_opencode_uninstaller() {
  if [ ! -f "$FORGE_OPENCODE_UNINSTALLER" ]; then
    echo "[forge] WARN: OpenCode uninstall script missing: $FORGE_OPENCODE_UNINSTALLER" >&2
    echo "[forge]   → elimina manualmente ~/.config/opencode-forge y ~/.local/bin/forge-opencode si existen" >&2
    return 0
  fi

  # The uninstaller resolves its paths from the environment, so the recorded
  # location is exported for it: uninstalling must remove what was installed,
  # not what an ambient variable happens to point at right now.
  OPENCODE_CONFIG_DIR="$(_forge_state_opencode_dir)" \
  OPENCODE_CONFIG="$(_forge_state_opencode_config)" \
    bash "$FORGE_OPENCODE_UNINSTALLER"
}

forge_drop_target_from_state() {
  local target_name="$1"
  local tmp_state

  if [ ! -f "$FORGE_STATE_FILE" ] || ! jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    return 0
  fi

  tmp_state="$(mktemp)"
  jq --arg tgt "$target_name" '
    .targets_manifest = [.targets_manifest[] | select(.name != $tgt)] |
    .targets = ((.targets // []) | map(select(. != $tgt))) |
    .symlinks = ([.targets_manifest[].symlinks[]?] | unique) |
    if .settings then
      .settings.overlay_backup = ((.settings.overlay_backup // {}) | with_entries(select(.key != $tgt))) |
      .settings.settings_json_backup = ((.settings.settings_json_backup // {}) | with_entries(select(.key != $tgt)))
    else
      .
    end
  ' "$FORGE_STATE_FILE" > "$tmp_state"

  if jq empty "$tmp_state" 2>/dev/null; then
    if [ "$(jq -r '.targets_manifest | length' "$tmp_state")" = "0" ]; then
      rm -f "$FORGE_STATE_FILE" "$tmp_state"
    else
      mv "$tmp_state" "$FORGE_STATE_FILE"
    fi
  else
    rm -f "$tmp_state"
  fi
}

forge_write_opencode_only_state() {
  local installed_at="$1"
  local tmp_state base_file base_installed_at

  tmp_state="$(mktemp)"
  base_file="$FORGE_STATE_FILE"
  base_installed_at="$installed_at"

  if [ ! -f "$base_file" ] || ! jq empty "$base_file" 2>/dev/null; then
    base_file="$(mktemp)"
    jq -n '{
      version: "",
      installed_at: "",
      state_schema: 3,
      targets: [],
      symlinks: [],
      targets_manifest: [],
      settings: {managed_paths: {}, overlay_backup: {}, settings_json_backup: {}},
      rtk: {pinned_version: "0.43.0", detected_version: null, installed_by_us: false, install_failed: false, version_mismatch: false}
    }' > "$base_file"
  else
    base_installed_at="$(jq -r '.installed_at // empty' "$base_file" 2>/dev/null || true)"
    [ -z "$base_installed_at" ] && base_installed_at="$installed_at"
  fi

  jq \
    --arg version "$FORGE_VERSION" \
    --arg installed_at "$base_installed_at" \
    --arg dir "$FORGE_OPENCODE_DIR" \
    --arg config_file "$FORGE_OPENCODE_CONFIG" \
    '
    .version = $version |
    .installed_at = $installed_at |
    .state_schema = 3 |
    .targets = (((.targets // []) + ["opencode"]) | unique) |
    .targets_manifest = ((.targets_manifest // []) | map(select(.name != "opencode")) + [{
      name: "opencode",
      dir: $dir,
      config_file: $config_file,
      symlinks: [],
      symlinks_objects: [],
      components: [],
      settings_merged: false,
      settings_backup: null
    }]) |
    .symlinks = ([.targets_manifest[].symlinks[]?] | unique) |
    .settings = (.settings // {managed_paths: {}, overlay_backup: {}, settings_json_backup: {}}) |
    .rtk = (.rtk // {pinned_version: "0.43.0", detected_version: null, installed_by_us: false, install_failed: false, version_mismatch: false})
    ' "$base_file" > "$tmp_state"

  jq empty "$tmp_state" || {
    rm -f "$tmp_state"
    [ "$base_file" != "$FORGE_STATE_FILE" ] && rm -f "$base_file"
    echo "[forge] ERROR: state file inválido, no se escribió" >&2
    return 1
  }

  mv "$tmp_state" "$FORGE_STATE_FILE"
  [ "$base_file" != "$FORGE_STATE_FILE" ] && rm -f "$base_file"
  echo "[forge] state guardado: $FORGE_STATE_FILE"
}

# Helper: get target path by index
forge_target_path() {
  local idx="$1"
  case "$idx" in
    0) echo "$_forge_target_path_0" ;;
    1) echo "$_forge_target_path_1" ;;
    *) echo "" ;;
  esac
}

# Helper: get target name by index
forge_target_name() {
  local idx="$1"
  case "$idx" in
    0) echo "$_forge_target_name_0" ;;
    1) echo "$_forge_target_name_1" ;;
    *) echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Subcommand stubs (implemented progressively per phase)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# _forge_state_migrate — Silently migrate state v1 → v2 → v3
# v1→v2: adds state_schema:2 and targets_manifest if absent or schema < 2.
# v2→v3: adds components (safe default: all 6) and symlinks_objects to each
#         targets_manifest entry if missing; bumps state_schema to 3.
# Accepts an optional $1 path to override $FORGE_STATE_FILE (for testing).
# Idempotent: no-op if state_schema already == 3.
# SC2120: $1 is intentionally optional — all normal call sites omit it;
#         tests pass a temp path directly to avoid touching the real state.
# shellcheck disable=SC2120
_forge_state_migrate() {
  local _state_file="${1:-$FORGE_STATE_FILE}"

  if [ ! -f "$_state_file" ]; then
    return 0
  fi
  if ! jq empty "$_state_file" 2>/dev/null; then
    return 0
  fi

  local schema
  schema="$(jq -r '.state_schema // 0' "$_state_file")"

  # Already at v3 — nothing to do
  if [ "$schema" -ge 3 ] 2>/dev/null; then
    return 0
  fi

  # ---------------------------------------------------------------------------
  # v1 → v2 migration (state_schema 0 or 1 → 2)
  # Handles state_schema 1: builds targets_manifest from legacy targets array.
  # ---------------------------------------------------------------------------
  if [ "$schema" -lt 2 ] 2>/dev/null; then
    # Build targets_manifest from existing targets + symlinks
    local targets_count
    targets_count="$(jq -r '.targets // [] | length' "$_state_file")"

    # Start building manifest using jq
    local manifest_json="[]"
    local t=0
    while [ "$t" -lt "$targets_count" ]; do
      local tgt_name tgt_dir
      tgt_name="$(jq -r --argjson i "$t" '.targets[$i]' "$_state_file")"
      case "$tgt_name" in
        claude)   tgt_dir="$HOME/.claude" ;;
        opencode) tgt_dir="$FORGE_OPENCODE_DIR" ;;
        *)        tgt_dir="$HOME/.claude" ;;
      esac

      # Filter absolute symlinks that start with tgt_dir, convert to relative paths
      local rel_symlinks_json
      rel_symlinks_json="$(jq -c \
        --arg prefix "$tgt_dir/" \
        '[.symlinks // [] | .[] | select(startswith($prefix)) | ltrimstr($prefix)]' \
        "$_state_file")"

      local pre_forge_path="${tgt_dir}/settings.json.pre-forge"
      local manifest_entry
      if [ -f "$pre_forge_path" ]; then
        manifest_entry="$(jq -n \
          --arg name "$tgt_name" \
          --arg dir "$tgt_dir" \
          --argjson symlinks "$rel_symlinks_json" \
          --arg settings_backup "$pre_forge_path" \
          '{name: $name, dir: $dir, symlinks: $symlinks, settings_merged: true, settings_backup: $settings_backup}')"
      else
        manifest_entry="$(jq -n \
          --arg name "$tgt_name" \
          --arg dir "$tgt_dir" \
          --argjson symlinks "$rel_symlinks_json" \
          '{name: $name, dir: $dir, symlinks: $symlinks, settings_merged: true, settings_backup: null}')"
      fi

      manifest_json="$(printf '%s' "$manifest_json" | jq --argjson entry "$manifest_entry" '. + [$entry]')"

      t=$((t + 1))
    done

    # Write v2 state atomically
    local mig_tmp_v2
    mig_tmp_v2="$(mktemp)"
    jq \
      --argjson manifest "$manifest_json" \
      '. + {state_schema: 2, targets_manifest: $manifest}' \
      "$_state_file" > "$mig_tmp_v2"
    if jq empty "$mig_tmp_v2" 2>/dev/null; then
      mv "$mig_tmp_v2" "$_state_file"
    else
      rm -f "$mig_tmp_v2"
      return 0
    fi
  fi

  # ---------------------------------------------------------------------------
  # v2 → v3 migration (schema is now 2, or was already 2 on entry)
  # For each targets_manifest entry:
  #   - if components is missing/empty → set to full default list
  #   - if symlinks_objects is missing → derive from flat symlinks array
  # Bump state_schema to 3.
  # ---------------------------------------------------------------------------
  # LOCKSTEP: this list is the snapshot of the default component set at the v3 schema.
  # When adding or removing a default component (i.e. a manifest without "default": false),
  # update this list here as well.
  # Do NOT derive it from forge_components_default_list(): a migration must be deterministic
  # with respect to its own schema, not to the current catalogue.
  # The same snapshot is reproduced in _forge_state_view (the read-only view
  # used by `status` and `doctor`): keep both in sync.
  local _default_components='["agents","commands","statusline","branch-guard","rtk-hook","cost-report","cost-report-skill"]'

  local mig_tmp_v3
  mig_tmp_v3="$(mktemp)"
  jq \
    --argjson default_components "$_default_components" \
    '
    .state_schema = 3 |
    .targets_manifest = [
      .targets_manifest[]? |
      # Add components if missing or empty
      if (.components == null or .components == [])
      then .components = $default_components
      else .
      end |
      # Add symlinks_objects if missing; derive from flat symlinks (dest only)
      if (.symlinks_objects == null)
      then .symlinks_objects = [
        .symlinks[]? |
        if type == "string"
        then {"src": "", "dest": .}
        else .
        end
      ]
      else .
      end
    ]
    ' \
    "$_state_file" > "$mig_tmp_v3"
  if jq empty "$mig_tmp_v3" 2>/dev/null; then
    mv "$mig_tmp_v3" "$_state_file"
  else
    rm -f "$mig_tmp_v3"
  fi
}

# ---------------------------------------------------------------------------
# Read-only diagnostic view of the install state
# ---------------------------------------------------------------------------
# _forge_state_view — prints a normalized view of the state file on stdout.
#
# This is the reading counterpart of _forge_state_migrate: it applies the same
# v1 -> v2 -> v3 normalization, but entirely in memory (jq + pipes). It never
# writes the state file, never creates a temporary file and never mutates the
# filesystem, so `status` and `doctor` stay strictly read-only.
#
# Differences with the on-disk migration:
#   * The historical "components" fallback is applied to Claude only. An
#     OpenCode target keeps `components: []` and its real `dir`, so the Claude
#     component catalogue is never projected onto the OpenCode overlay.
#   * Every manifest entry carries `components_fallback`, so the callers can
#     reproduce the historical warning without re-deriving the list.
#
# Exit codes: 0 = view printed, 1 = state file missing or not valid JSON.
# SC2120: $1 is intentionally optional — the diagnostics always read the real
#         state file; the parameter only mirrors _forge_state_migrate.
# shellcheck disable=SC2120
_forge_state_view() {
  local _state_file="${1:-$FORGE_STATE_FILE}"

  if [ ! -f "$_state_file" ]; then
    return 1
  fi
  if ! jq empty "$_state_file" 2>/dev/null; then
    return 1
  fi

  local _schema
  _schema="$(jq -r '.state_schema // 0' "$_state_file" 2>/dev/null || echo 0)"
  case "$_schema" in
    ''|*[!0-9]*) _schema=0 ;;
  esac

  local _claude_dir="$HOME/.claude"
  # Legacy (pre-v2) states carry no directory for their targets, so the
  # effective overlay directory is the only usable guess: it is the directory
  # the overlay installer would have used in this very environment.
  local _opencode_dir="$FORGE_OPENCODE_DIR"

  # Legacy (pre-v2) manifests point at the .pre-forge snapshot when it exists.
  # The probe is a read: the view never creates nor removes that file.
  local _claude_backup="null" _opencode_backup="null"
  if [ -f "${_claude_dir}/settings.json.pre-forge" ]; then
    _claude_backup="$(jq -Rn --arg p "${_claude_dir}/settings.json.pre-forge" '$p')"
  fi
  if [ -f "${_opencode_dir}/settings.json.pre-forge" ]; then
    _opencode_backup="$(jq -Rn --arg p "${_opencode_dir}/settings.json.pre-forge" '$p')"
  fi

  # Default component list of a *current* catalogue (used when a v3 state
  # records no components for Claude: the historical live fallback).
  local _live_defaults
  _live_defaults="$(forge_components_default_list 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || echo '[]')"

  # LOCKSTEP: `migrate_defaults` below reproduces the v3 schema snapshot of
  # _forge_state_migrate (which persists it). A legacy state must be read
  # exactly like the migration would have written it, so both lists have to
  # stay in sync.

  jq \
    --argjson schema "$_schema" \
    --arg claude_dir "$_claude_dir" \
    --arg opencode_dir "$_opencode_dir" \
    --argjson claude_backup "$_claude_backup" \
    --argjson opencode_backup "$_opencode_backup" \
    --argjson migrate_defaults '["agents","commands","statusline","branch-guard","rtk-hook","cost-report","cost-report-skill"]' \
    --argjson live_defaults "$_live_defaults" \
    '
    # Legacy (pre-v2) manifest: derived from the flat `targets` + `symlinks`.
    def derive_manifest:
      . as $root
      | [ ($root.targets // [])[]
          | . as $name
          | (if $name == "opencode" then $opencode_dir else $claude_dir end) as $dir
          | {
              name: $name,
              dir: $dir,
              symlinks: [ ($root.symlinks // [])[] | select(startswith($dir + "/")) | ltrimstr($dir + "/") ],
              symlinks_objects: [],
              components: [],
              components_fallback: false,
              settings_merged: true,
              settings_backup: (if $name == "opencode" then $opencode_backup else $claude_backup end)
            }
        ];

    (if $schema < 2 then .targets_manifest = derive_manifest else . end)
    | .state_schema = 3
    | .targets_manifest = [
        .targets_manifest[]?
        | .components = (if .components == null then [] else .components end)
        | .symlinks = (if .symlinks == null then [] else .symlinks end)
        | .symlinks_objects = (
            if .symlinks_objects == null
            then [ (.symlinks // [])[] | if type == "string" then {"src": "", "dest": .} else . end ]
            else .symlinks_objects
            end
          )
        # The historical fallback only ever applied to Claude. A legacy
        # OpenCode target keeps an empty component list: it has no Claude
        # components at all.
        | .components_fallback = (
            (.name == "claude")
            and ((.components | length) == 0)
            and ($schema >= 3)
          )
        | (if (.name == "claude") and ((.components | length) == 0)
           then .components = (if $schema < 3 then $migrate_defaults else $live_defaults end)
           else . end
          )
      ]
    | .rtk = (.rtk // {})
    ' "$_state_file"
}

# _forge_state_query — run a jq query against the current diagnostic view.
_forge_state_query() {
  jq -r "$@" <<< "$_FORGE_STATE_VIEW"
}

# ---------------------------------------------------------------------------
# OpenCode overlay diagnostics (read-only, shared by `status` and `doctor`)
# ---------------------------------------------------------------------------
# The OpenCode overlay has its own contract: it is not a set of Claude
# symlinks. It is a set of regular-file copies, one JSONC config, the plugins
# declared by that config and one global launcher. The inventory is derived
# from the real sources (open-code/agents/*.md, open-code/commands/*.md and
# the `plugin` field of the *installed* config), so the check follows whatever
# the OpenCode installer produces instead of a duplicated hardcoded list.
#
# _forge_opencode_diagnostics <tgt_dir>
#
# Emits one record per line:
#   STATUS|FAMILY|MESSAGE|HINT
# STATUS is one of: OK, MISSING, MISMATCH, INVALID, UNEXPECTED, INVENTORY ERROR
#
# A broken inventory (missing source directory, unreadable helper) is reported
# as INVENTORY ERROR and blocks only its own family: the installed artifacts
# are never declared missing just because the inventory could not be built.
_FORGE_OPENCODE_FAILURES=0
_FORGE_OPENCODE_CONFIG_JSON=""
_FORGE_OPENCODE_CONFIG_READY=0

# _forge_files_equal <a> <b> — true when both files hold the same bytes.
_forge_files_equal() {
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  else
    diff -q "$1" "$2" >/dev/null 2>&1
  fi
}

# _forge_opencode_check_collection <label> <src_dir> <dst_dir> <hint>
# Compares the installed copies of a family (agents, commands) with the source
# files: same set, regular files (never symlinks) and identical bytes.
_forge_opencode_check_collection() {
  local _label="$1" _src_dir="$2" _dst_dir="$3" _hint="$4"
  local _name _src _dst _src_count=0

  if [ ! -d "$_src_dir" ]; then
    printf 'INVENTORY ERROR|%s|no se pudo inventariar el origen %s: el directorio no existe|el checkout de forge esta incompleto: revisa open-code/ en el repositorio\n' "$_label" "$_src_dir"
    return 0
  fi

  for _src in "$_src_dir"/*.md; do
    [ -f "$_src" ] || continue
    _src_count=$((_src_count + 1))
    _name="$(basename "$_src")"
    _dst="$_dst_dir/$_name"
    if [ -L "$_dst" ]; then
      printf 'INVALID|%s|%s/%s: es un symlink, se espera un fichero regular|%s\n' "$_label" "$_label" "$_name" "$_hint"
    elif [ ! -e "$_dst" ]; then
      printf 'MISSING|%s|%s/%s: ausente en el directorio instalado|%s\n' "$_label" "$_label" "$_name" "$_hint"
    elif [ ! -f "$_dst" ]; then
      printf 'INVALID|%s|%s/%s: no es un fichero regular|%s\n' "$_label" "$_label" "$_name" "$_hint"
    elif ! _forge_files_equal "$_src" "$_dst"; then
      printf 'MISMATCH|%s|%s/%s: el contenido difiere del origen|%s\n' "$_label" "$_label" "$_name" "$_hint"
    else
      printf 'OK|%s|%s/%s: copia regular identica al origen|\n' "$_label" "$_label" "$_name"
    fi
  done

  if [ "$_src_count" -eq 0 ]; then
    printf 'INVENTORY ERROR|%s|no se pudo inventariar el origen %s: no contiene ficheros .md|el checkout de forge esta incompleto: revisa open-code/ en el repositorio\n' "$_label" "$_src_dir"
    return 0
  fi

  if [ -d "$_dst_dir" ]; then
    for _dst in "$_dst_dir"/*.md; do
      [ -f "$_dst" ] || continue
      _name="$(basename "$_dst")"
      if [ ! -f "$_src_dir/$_name" ]; then
        printf 'UNEXPECTED|%s|%s/%s: presente en el directorio instalado y no declarado en el origen|%s\n' "$_label" "$_label" "$_name" "$_hint"
      fi
    done
  fi
}

# _forge_opencode_check_agents_md <tgt_dir> <hint>
_forge_opencode_check_agents_md() {
  local _tgt_dir="$1" _hint="$2"
  local _src="$FORGE_ROOT/open-code/AGENTS.md"
  local _dst="$_tgt_dir/AGENTS.md"

  if [ ! -f "$_src" ]; then
    printf 'INVENTORY ERROR|agents-md|no se pudo inventariar el origen %s: el fichero no existe|el checkout de forge esta incompleto: revisa open-code/ en el repositorio\n' "$_src"
    return 0
  fi
  if [ -L "$_dst" ]; then
    printf 'INVALID|agents-md|AGENTS.md: es un symlink, se espera un fichero regular|%s\n' "$_hint"
  elif [ ! -e "$_dst" ]; then
    printf 'MISSING|agents-md|AGENTS.md: ausente en el directorio instalado|%s\n' "$_hint"
  elif [ ! -f "$_dst" ]; then
    printf 'INVALID|agents-md|AGENTS.md: no es un fichero regular|%s\n' "$_hint"
  elif ! _forge_files_equal "$_src" "$_dst"; then
    printf 'MISMATCH|agents-md|AGENTS.md: el contenido difiere del origen|%s\n' "$_hint"
  else
    printf 'OK|agents-md|AGENTS.md: copia regular identica al origen|\n'
  fi
}

# _forge_opencode_parse_config <helper> <config>
# Prints {"ok":true,"config":{...}} or {"ok":false,"error":"..."} on stdout.
# The canonical JSONC parser of the overlay helper is reused, so the installed
# config is validated exactly like the installer validates it.
# PYTHONDONTWRITEBYTECODE + sys.dont_write_bytecode keep the diagnostics
# strictly read-only: importing the helper must not drop a __pycache__ into
# the checkout.
_forge_opencode_parse_config() {
  PYTHONDONTWRITEBYTECODE=1 python3 -c '
import importlib.util
import json
import sys

sys.dont_write_bytecode = True
helper, config = sys.argv[1], sys.argv[2]
try:
    spec = importlib.util.spec_from_file_location("forge_plugin_sync", helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    data = module.parse_config(config)
except Exception as exc:
    print(json.dumps({"ok": False, "error": str(exc)}))
    sys.exit(1)
print(json.dumps({"ok": True, "config": data}))
' "$1" "$2" 2>/dev/null
}

# _forge_opencode_check_config <tgt_dir> <config_file> <hint>
# Validates the installed opencode.jsonc and publishes the parsed config so
# the plugin family can use the `plugin` declaration of the *installed* file.
# The config file is passed in (and not derived from the target directory)
# because OPENCODE_CONFIG may place it outside the overlay directory.
_forge_opencode_check_config() {
  local _tgt_dir="$1" _hint="$3"
  local _cfg="$2"
  local _helper="$FORGE_ROOT/open-code/lib/plugin-sync.py"

  _FORGE_OPENCODE_CONFIG_JSON=""
  _FORGE_OPENCODE_CONFIG_READY=0

  if [ -L "$_cfg" ]; then
    printf 'INVALID|config|opencode.jsonc: es un symlink, se espera un fichero regular|%s\n' "$_hint"
    return 0
  fi
  if [ ! -e "$_cfg" ]; then
    printf 'MISSING|config|opencode.jsonc: ausente en el directorio instalado|%s\n' "$_hint"
    return 0
  fi
  if [ ! -f "$_cfg" ]; then
    printf 'INVALID|config|opencode.jsonc: no es un fichero regular|%s\n' "$_hint"
    return 0
  fi
  if [ ! -f "$_helper" ]; then
    printf 'INVENTORY ERROR|config|no se pudo verificar la config: falta el helper %s|el checkout de forge esta incompleto: revisa open-code/ en el repositorio\n' "$_helper"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'INVENTORY ERROR|config|no se pudo verificar la config: python3 no esta en PATH|instala python3 para validar la config del overlay\n'
    return 0
  fi

  local _parsed _rc=0
  _parsed="$(_forge_opencode_parse_config "$_helper" "$_cfg")" || _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "$_parsed" ]; then
    local _err
    _err="$(printf '%s' "$_parsed" | jq -r '.error // empty' 2>/dev/null || true)"
    [ -z "$_err" ] && _err="no se pudo parsear el JSONC"
    _err="${_err//|/ }"
    printf 'INVALID|config|opencode.jsonc: JSONC invalido (%s)|%s\n' "$_err" "$_hint"
    return 0
  fi

  local _expected_agents_md="$_tgt_dir/AGENTS.md"
  if [ -d "$_tgt_dir" ]; then
    _expected_agents_md="$(cd "$_tgt_dir" && pwd)/AGENTS.md"
  fi

  local _instructions
  _instructions="$(printf '%s' "$_parsed" | jq -c '[.config.instructions // [] | (if type == "array" then .[] elif type == "string" then . else empty end) | select(type == "string")]' 2>/dev/null || echo '[]')"
  if printf '%s' "$_instructions" | jq -e --arg p "$_expected_agents_md" 'index($p) != null' >/dev/null 2>&1; then
    printf 'OK|config|opencode.jsonc: JSONC valido, instructions apunta al fichero de instrucciones del overlay|\n'
  else
    printf 'MISMATCH|config|opencode.jsonc: instructions no apunta al fichero de instrucciones del overlay|%s\n' "$_hint"
  fi

  _FORGE_OPENCODE_CONFIG_JSON="$_parsed"
  _FORGE_OPENCODE_CONFIG_READY=1
}

# _forge_opencode_check_plugins <tgt_dir> <config_file> <hint>
# The plugin set is never hardcoded: it is the `plugin` field of the installed
# config, and its presence on disk is decided by plugin-sync.py verify.
_forge_opencode_check_plugins() {
  local _tgt_dir="$1" _hint="$3"
  local _helper="$FORGE_ROOT/open-code/lib/plugin-sync.py"
  local _cfg="$2"

  # The declaration lives in the installed config: when the config cannot be
  # read, the root cause is already reported by the config family, so the
  # plugin family is skipped instead of emitting false positives.
  if [ "$_FORGE_OPENCODE_CONFIG_READY" -ne 1 ]; then
    return 0
  fi
  if [ ! -f "$_helper" ]; then
    printf 'INVENTORY ERROR|plugins|no se pudieron verificar los plugins: falta el helper %s|el checkout de forge esta incompleto: revisa open-code/ en el repositorio\n' "$_helper"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    printf 'INVENTORY ERROR|plugins|no se pudieron verificar los plugins: python3 no esta en PATH|instala python3 para validar los plugins del overlay\n'
    return 0
  fi

  local _declared
  _declared="$(printf '%s' "$_FORGE_OPENCODE_CONFIG_JSON" | jq -r '[.config.plugin // [] | (if type == "array" then .[] elif type == "string" then . else empty end) | select(type == "string") | select(startswith("./")) | ltrimstr("./")] | .[]' 2>/dev/null || echo '')"

  if [ -z "$_declared" ]; then
    printf 'OK|plugins|opencode.jsonc no declara plugins locales|\n'
    return 0
  fi

  local _out _rc=0
  _out="$(PYTHONDONTWRITEBYTECODE=1 python3 "$_helper" verify --config "$_cfg" 2>&1)" || _rc=$?

  local _missing=""
  if [ "$_rc" -ne 0 ]; then
    _missing="$(printf '%s\n' "$_out" | sed -n "s/.*config declares plugin '\([^']*\)' but .* is missing on disk.*/\1/p")"
    if [ -z "$_missing" ]; then
      local _detail
      _detail="$(printf '%s\n' "$_out" | tr '\n' ' ' | tr -s ' ')"
      _detail="${_detail//|/ }"
      printf 'INVENTORY ERROR|plugins|no se pudieron verificar los plugins declarados (%s)|%s\n' "$_detail" "$_hint"
      return 0
    fi
  fi

  local _rel _is_missing
  while IFS= read -r _rel; do
    [ -z "$_rel" ] && continue
    _is_missing=0
    if printf '%s\n' "$_missing" | grep -qxF "$_rel"; then
      _is_missing=1
    fi
    if [ "$_is_missing" -eq 1 ]; then
      printf 'MISSING|plugins|%s: declarado por opencode.jsonc y ausente en disco|%s\n' "$_rel" "$_hint"
    else
      printf 'OK|plugins|%s: declarado por opencode.jsonc y presente en disco|\n' "$_rel"
    fi
  done < <(printf '%s\n' "$_declared")
}

# _forge_opencode_check_launcher <hint>
# The launcher is the only global artifact of the overlay: it must be a
# symlink to the launcher script of this checkout.
_forge_opencode_check_launcher() {
  local _hint="$1"
  local _launcher="$HOME/.local/bin/forge-opencode"
  local _expected="$FORGE_ROOT/open-code/forge-opencode.sh"

  if [ -L "$_launcher" ]; then
    local _target _resolved
    _target="$(readlink "$_launcher")"
    case "$_target" in
      /*) _resolved="$_target" ;;
      *)  _resolved="$(dirname "$_launcher")/$_target" ;;
    esac
    if [ "$_resolved" = "$_expected" ]; then
      printf 'OK|launcher|forge-opencode: symlink a %s|\n' "$_expected"
    else
      printf 'MISMATCH|launcher|forge-opencode: el launcher apunta a %s y se esperaba %s|%s\n' "$_resolved" "$_expected" "$_hint"
    fi
  elif [ -e "$_launcher" ]; then
    printf 'INVALID|launcher|forge-opencode: el launcher no es un symlink|%s\n' "$_hint"
  else
    printf 'MISSING|launcher|forge-opencode: launcher ausente en ~/.local/bin/forge-opencode|%s\n' "$_hint"
  fi
}

# _forge_opencode_diagnostics <tgt_dir> <config_file>
_forge_opencode_diagnostics() {
  local _tgt_dir="$1"
  local _cfg="$2"
  local _hint="bash install.sh install --target=opencode"

  _forge_opencode_check_collection "agents" "$FORGE_ROOT/open-code/agents" "$_tgt_dir/agents" "$_hint"
  _forge_opencode_check_collection "commands" "$FORGE_ROOT/open-code/commands" "$_tgt_dir/commands" "$_hint"
  _forge_opencode_check_agents_md "$_tgt_dir" "$_hint"
  _forge_opencode_check_config "$_tgt_dir" "$_cfg" "$_hint"
  _forge_opencode_check_plugins "$_tgt_dir" "$_cfg" "$_hint"
  _forge_opencode_check_launcher "$_hint"
}

# _forge_opencode_render <mode> <tgt_dir> <config_file>
# mode: status | doctor. Prints the records and sets _FORGE_OPENCODE_FAILURES
# to the number of non-OK records.
_forge_opencode_render() {
  local _mode="$1" _tgt_dir="$2" _cfg="$3"
  local _records _st _fam _msg _hint _col

  _FORGE_OPENCODE_FAILURES=0
  _records="$(_forge_opencode_diagnostics "$_tgt_dir" "$_cfg")"

  while IFS='|' read -r _st _fam _msg _hint; do
    [ -z "$_st" ] && continue
    # Status column: 9 characters wide, like the rest of the status table.
    _col="$(printf '%-9s' "$_st")"
    [ "${#_st}" -ge 9 ] && _col="${_col} "
    if [ "$_st" = "OK" ]; then
      case "$_mode" in
        doctor) printf '  PASS  %s\n' "$_msg" ;;
        *)      printf '    %s%s\n' "$_col" "$_msg" ;;
      esac
    else
      _FORGE_OPENCODE_FAILURES=$((_FORGE_OPENCODE_FAILURES + 1))
      case "$_mode" in
        doctor)
          # The status token is kept in the doctor output: a broken artifact
          # (MISSING/MISMATCH/INVALID/UNEXPECTED) and a broken inventory
          # (INVENTORY ERROR) must stay distinguishable there too.
          printf '  FAIL  %s: %s\n' "$_st" "$_msg" >&2
          [ -n "$_hint" ] && printf '  HINT  %s\n' "$_hint"
          ;;
        *)
          printf '    %s%s\n' "$_col" "$_msg"
          [ -n "$_hint" ] && printf '      → %s\n' "$_hint"
          ;;
      esac
    fi
  done < <(printf '%s\n' "$_records")
}

# ---------------------------------------------------------------------------
# Environment vs manifest divergence (OpenCode overlay)
# ---------------------------------------------------------------------------
# The manifest is the source of truth for the location of the overlay: it is
# written by the very run that deployed the files, so it knows exactly where
# the overlay landed. The environment is ambient: it can change between the
# install and the check, or point at a different overlay instance.
#
# Therefore `status`/`doctor` NEVER follow the environment to decide where to
# look — they always diagnose the recorded location. But the divergence is
# not silently ignored either: the launcher and opencode itself resolve the
# config through the environment, so an environment pointing elsewhere means
# the user would run opencode without the forge overlay. It is reported as an
# actionable warning and not as a failure: the installed artifacts are
# healthy in the recorded location, so the installation itself is not
# degraded and the exit code keeps meaning "is the installation healthy?".
#
# _forge_opencode_env_divergence <installed_dir> <installed_config>
# Prints one "MESSAGE|HINT" record per detected divergence; nothing when the
# environment does not contradict the manifest. An unset variable never
# contradicts anything: only an explicitly exported path can diverge.
#
# <installed_config> is the config file as recorded in the manifest. An empty
# value means "not recorded" (a legacy state): the comparison is then skipped
# instead of guessing, because a guessed contradiction would be a false alarm.
_forge_opencode_env_divergence() {
  local _inst_dir="$1" _inst_config="$2"
  local _msg _hint

  [ -n "$_inst_dir" ] || return 0

  if [ -n "${OPENCODE_CONFIG_DIR:-}" ] && [ "$OPENCODE_CONFIG_DIR" != "$_inst_dir" ]; then
    _msg="opencode: OPENCODE_CONFIG_DIR apunta a $OPENCODE_CONFIG_DIR pero el overlay está instalado en $_inst_dir"
    _hint="desexporta OPENCODE_CONFIG_DIR o reinstala el overlay en esa ruta: bash install.sh install --target=opencode"
    printf '%s|%s\n' "${_msg//|/ }" "${_hint//|/ }"
  fi

  if [ -n "${OPENCODE_CONFIG:-}" ] && [ -n "$_inst_config" ] && [ "$OPENCODE_CONFIG" != "$_inst_config" ]; then
    _msg="opencode: OPENCODE_CONFIG apunta a $OPENCODE_CONFIG pero la config instalada está en $_inst_config"
    _hint="desexporta OPENCODE_CONFIG o reinstala el overlay en esa ruta: bash install.sh install --target=opencode"
    printf '%s|%s\n' "${_msg//|/ }" "${_hint//|/ }"
  fi

  return 0
}

# _forge_status_rtk_block <tgt_name> <tgt_dir> <has_rtk_hook> <tracked_global>
# Prints the RTK diagnostic block of a target. The block is shown when the
# target records the rtk-hook component, or once per run when rtk.tracked is
# true (Path A tracking: `bash install.sh rtk install`).
_forge_status_rtk_block() {
  local _tgt_name="$1" _tgt_dir="$2" _has_rtk_hook="$3" _tracked_global="$4"

  # Determine whether to print the RTK block for this target iteration.
  # When activated via rtk.tracked (not rtk-hook), print at most once per run.
  local _print_rtk_block=0
  if [ "$_has_rtk_hook" -eq 1 ]; then
    _print_rtk_block=1
  elif [ "$_tracked_global" = "true" ] && [ "$_FORGE_RTK_TRACKED_PRINTED" -eq 0 ]; then
    _print_rtk_block=1
  fi

  if [ "$_print_rtk_block" -ne 1 ]; then
    return 0
  fi

  [ "$_has_rtk_hook" -eq 0 ] && _FORGE_RTK_TRACKED_PRINTED=1
  echo "  RTK ($_tgt_name):"
  local rtk_pinned rtk_detected
  # Pinned: prefer rtk/VERSION (single source of truth), fall back to state.
  if [ -f "$FORGE_ROOT/rtk/VERSION" ]; then
    rtk_pinned="$(cat "$FORGE_ROOT/rtk/VERSION" 2>/dev/null || true)"
  fi
  [ -z "${rtk_pinned:-}" ] && rtk_pinned="$(_forge_state_query '.rtk.pinned_version // "?"')"

  # Detected: live probe — state file is stale post rtk-hook migration.
  rtk_detected="no detectado"
  if command -v forge_rtk_detect >/dev/null 2>&1; then
    local _det
    _det="$(forge_rtk_detect)"
    local _rtk_installed_nodepath=0
    case "$_det" in
      absent)    rtk_detected="no detectado" ;;
      collision) rtk_detected="colisión (binario rtk no reconocido)" ;;
      installed:*)
        # On-disk at ~/.forge/bin but not on PATH — extract version for comparison.
        local _st_ondisk_ver
        _st_ondisk_ver="$(printf '%s\n' "$_det" | cut -d: -f2)"
        rtk_detected="$_st_ondisk_ver"
        _rtk_installed_nodepath=1
        ;;
      shadowed:*)
        local _st_shadow_winner _st_shadow_ver _st_forge_ver
        _st_shadow_winner="$(printf '%s\n' "$_det" | cut -d: -f2)"
        _st_shadow_ver="$(printf '%s\n' "$_det" | cut -d: -f3)"
        _st_forge_ver="$(printf '%s\n' "$_det" | cut -d: -f4)"
        rtk_detected="sombra — ${_st_shadow_ver} en ${_st_shadow_winner} sombrea al de forge (${_st_forge_ver})"
        ;;
      *)         rtk_detected="$_det" ;;
    esac
  elif command -v rtk >/dev/null 2>&1; then
    local _rtk_installed_nodepath=0
    local _rtk_v_out _rtk_ver
    _rtk_v_out="$(rtk --version 2>&1 || true)"
    if printf '%s\n' "$_rtk_v_out" | grep -qE '^rtk[[:space:]]+[0-9]+\.[0-9]+\.[0-9]+'; then
      _rtk_ver="$(printf '%s\n' "$_rtk_v_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      rtk_detected="$_rtk_ver"
    else
      rtk_detected="colisión (binario rtk no reconocido)"
    fi
  else
    local _rtk_installed_nodepath=0
  fi

  echo "    Pinned       : $rtk_pinned"
  if [ "${_rtk_installed_nodepath:-0}" -eq 1 ]; then
    echo "    Detectado    : $rtk_detected (instalado pero ~/.forge/bin no está en PATH)"
    echo "    WARN: RTK instalado pero ~/.forge/bin no está en PATH → source ~/.zshrc o reinstala"
  else
    echo "    Detectado    : $rtk_detected"
  fi
  # Recipe for shadowed case
  case "$rtk_detected" in
    sombra\ —*)
      echo "    WARN: RTK instalado vía Homebrew sombrea al de forge."
      echo "    Para solucionar:"
      echo "      1. brew uninstall rtk"
      echo "      2. bash install.sh rtk install"
      echo "      3. source ~/.zshrc (o abre un terminal nuevo)"
      ;;
  esac
  # Warn if detected version is behind the pin
  # Skip non-semver status strings; for installed:* the version part was already extracted.
  if [ "$rtk_detected" != "no detectado" ] && [ "$rtk_detected" != "colisión (binario rtk no reconocido)" ] && case "$rtk_detected" in sombra\ —*) false ;; *) true ;; esac; then
    local _rtk_cmp="eq"
    if command -v forge_rtk_compare >/dev/null 2>&1; then
      _rtk_cmp="$(forge_rtk_compare "$rtk_detected" "$rtk_pinned")"
    elif [ "$rtk_detected" != "$rtk_pinned" ]; then
      local _rtk_lower
      _rtk_lower="$(printf '%s\n%s\n' "$rtk_detected" "$rtk_pinned" | sort -V | head -1)"
      if [ "$_rtk_lower" = "$rtk_detected" ]; then _rtk_cmp="lt"; else _rtk_cmp="gt"; fi
    fi
    case "$_rtk_cmp" in
      lt) echo "    WARN: RTK $rtk_detected desactualizado (pin $rtk_pinned) — bash install.sh rtk install" ;;
      gt) echo "    WARN: RTK $rtk_detected > pin $rtk_pinned (versión no certificada)" ;;
    esac
  fi
  echo ""
}

cmd_status() {
  # ---------------------------------------------------------------------------
  # cmd_status — readable status table; exit 0 if healthy, exit 1 if issues
  # Target-aware: every target is diagnosed against its own contract.
  #   claude   — component-scoped symlinks, settings.json, CLAUDE.md refs, RTK
  #   opencode — overlay copies, config, declared plugins and global launcher
  # Component-scoped (claude): reports only installed components (recorded in
  # state). Falls back to full component list for pre-v3 state entries lacking
  # components field.
  # Read-only: never modifies anything, not even a legacy state file.
  # ---------------------------------------------------------------------------
  forge_banner

  if [ ! -f "$FORGE_STATE_FILE" ]; then
    echo "[forge] no instalado (state file no encontrado: $FORGE_STATE_FILE)"
    return 0
  fi

  # The diagnostic view normalizes legacy schemas in memory: unlike the
  # on-disk migration, it never rewrites the state file.
  if ! _FORGE_STATE_VIEW="$(_forge_state_view)"; then
    echo "[forge] ERROR: state file inválido (JSON corrupto): $FORGE_STATE_FILE" >&2
    return 1
  fi

  local version installed_at
  version="$(_forge_state_query '.version // "?"')"
  installed_at="$(_forge_state_query '.installed_at // "?"')"
  local updated_at
  updated_at="$(_forge_state_query '.updated_at // ""')"

  echo ""
  echo "  forge — estado de instalación"
  echo "  ───────────────────────────────────────"
  echo "  Versión  : $version"
  echo "  Instalado: $installed_at"
  [ -n "$updated_at" ] && echo "  Actualiz.: $updated_at"

  # Targets
  local targets_str
  targets_str="$(_forge_state_query '.targets // [] | join(", ")')"
  echo "  Targets  : ${targets_str:-ninguno}"
  echo ""

  local any_fail=0

  local manifest_count
  manifest_count="$(_forge_state_query '.targets_manifest // [] | length')"

  if [ "$manifest_count" -eq 0 ]; then
    echo "  (sin targets registrados en targets_manifest)"
    echo ""
  fi

  # Read rtk.tracked once — used by the RTK gate inside the per-target loop.
  # When activated via rtk.tracked (not rtk-hook), the RTK block prints at most once.
  local _rtk_tracked_global
  _rtk_tracked_global="$(_forge_state_query '.rtk.tracked // false')"
  _FORGE_RTK_TRACKED_PRINTED=0

  # --- Per-target status (dispatch by target contract) ---
  local t=0
  # shellcheck disable=SC2016  # jq filters are single-quoted on purpose: $i belongs to jq
  while [ "$t" -lt "$manifest_count" ]; do
    local tgt_name tgt_dir
    tgt_name="$(_forge_state_query --argjson i "$t" '.targets_manifest[$i].name // "?"')"
    tgt_dir="$(_forge_state_query --argjson i "$t" '.targets_manifest[$i].dir // ""')"

    echo "  Target: $tgt_name ($tgt_dir)"

    case "$tgt_name" in
      claude)
        # The Claude contract (component-scoped symlinks, settings.json,
        # CLAUDE.md refs and RTK) is evaluated inline below, unchanged.
        ;;
      opencode)
        # The overlay location comes from the manifest (the source of truth):
        # the config may live outside the overlay directory when
        # OPENCODE_CONFIG points elsewhere.
        local _oc_cfg _oc_cfg_recorded _oc_msg _oc_hint
        _oc_cfg_recorded="$(_forge_state_query --argjson i "$t" '.targets_manifest[$i].config_file // empty')"
        _oc_cfg="$_oc_cfg_recorded"
        [ -n "$_oc_cfg" ] || _oc_cfg="$tgt_dir/opencode.jsonc"
        echo "  OpenCode overlay ($tgt_dir):"
        _forge_opencode_render status "$tgt_dir" "$_oc_cfg"
        if [ "$_FORGE_OPENCODE_FAILURES" -gt 0 ]; then
          any_fail=1
        fi
        # The environment never decides where to look, but a divergence is
        # reported: it would make the launcher load a different config.
        while IFS='|' read -r _oc_msg _oc_hint; do
          [ -z "$_oc_msg" ] && continue
          printf '    %-9s%s\n' "WARN" "$_oc_msg"
          [ -n "$_oc_hint" ] && printf '      → %s\n' "$_oc_hint"
        done < <(_forge_opencode_env_divergence "$tgt_dir" "$_oc_cfg_recorded")
        # The overlay has no Claude components, so the RTK block can only be
        # shown here for the global rtk.tracked case (at most once per run).
        _forge_status_rtk_block "$tgt_name" "$tgt_dir" 0 "$_rtk_tracked_global"
        echo ""
        t=$((t + 1))
        continue
        ;;
      *)
        echo "  TARGET NO SOPORTADO: $tgt_name — el diagnóstico por target solo admite 'claude' y 'opencode'" >&2
        any_fail=1
        echo ""
        t=$((t + 1))
        continue
        ;;
    esac

    # --- Claude target: component-scoped checks ---

    # Determine components to report. The diagnostic view already applied the
    # historical fallback for Claude; `components_fallback` tells us whether
    # the warning has to be reproduced.
    local _comp_fallback
    _comp_fallback="$(_forge_state_query --argjson i "$t" '.targets_manifest[$i].components_fallback // false')"

    local _ci=0
    local _STATUS_COMP_COUNT=0
    if [ "$_comp_fallback" = "true" ]; then
      echo "  WARN: no hay campo 'components' en state para $tgt_name — mostrando lista por defecto" >&2
    fi
    while IFS= read -r _sc_comp; do
      eval "_STATUS_COMP_${t}_${_STATUS_COMP_COUNT}=\$_sc_comp"
      _STATUS_COMP_COUNT=$((_STATUS_COMP_COUNT + 1))
    done < <(_forge_state_query --argjson i "$t" '.targets_manifest[$i].components[]')

    local _comp_list_str=""
    local _cx=0
    while [ "$_cx" -lt "$_STATUS_COMP_COUNT" ]; do
      local _cx_name
      eval "_cx_name=\${_STATUS_COMP_${t}_${_cx}}"
      _comp_list_str="$_comp_list_str $_cx_name"
      _cx=$((_cx + 1))
    done
    echo "  Componentes: $(echo "$_comp_list_str" | xargs)"

    # --- Symlinks por componente ---
    echo "  Symlinks:"
    _ci=0
    while [ "$_ci" -lt "$_STATUS_COMP_COUNT" ]; do
      local _comp
      eval "_comp=\${_STATUS_COMP_${t}_${_ci}}"

      local src_rel dest_rel
      while IFS="	" read -r src_rel dest_rel; do
        local dest_abs="${tgt_dir}/${dest_rel}"
        local short_dest="${dest_abs/#$HOME/\~}"
        if [ ! -e "$dest_abs" ] && [ ! -L "$dest_abs" ]; then
          echo "    BROKEN   [$_comp] $short_dest"
          any_fail=1
        elif [ -L "$dest_abs" ]; then
          local lnk_target
          lnk_target="$(readlink "$dest_abs")"
          if [ "${lnk_target#"$FORGE_ROOT"}" != "$lnk_target" ]; then
            echo "    OK       [$_comp] $short_dest"
          else
            echo "    MISMATCH [$_comp] $short_dest -> $lnk_target"
            any_fail=1
          fi
        else
          echo "    MISMATCH [$_comp] $short_dest (no es symlink)"
          any_fail=1
        fi
      done < <(forge_component_symlinks "$_comp" 2>/dev/null || true)

      _ci=$((_ci + 1))
    done
    echo ""

    # --- Settings por componente ---
    local target_settings="$tgt_dir/settings.json"
    local pre_forge="${target_settings}.pre-forge"

    echo "  Settings ($tgt_name):"

    # Validate settings.json itself first
    if [ ! -f "$target_settings" ]; then
      echo "    MISSING  settings.json ($target_settings)"
      any_fail=1
    elif ! jq empty "$target_settings" 2>/dev/null; then
      echo "    INVALID  settings.json (JSON corrupto)"
      any_fail=1
    else
      local pre_status="presente"
      [ ! -f "$pre_forge" ] && pre_status="ausente (no restaurable)"
      echo "    OK       settings.json | .pre-forge: $pre_status"

      # Per-component managed key check
      _ci=0
      while [ "$_ci" -lt "$_STATUS_COMP_COUNT" ]; do
        local _scomp
        eval "_scomp=\${_STATUS_COMP_${t}_${_ci}}"

        local _manifest_path="$FORGE_ROOT/shared/components/${_scomp}.json"
        if [ ! -f "$_manifest_path" ]; then
          _ci=$((_ci + 1))
          continue
        fi

        local _sk
        _sk="$(jq -r '.settings_key // empty' "$_manifest_path")"

        if [ -n "$_sk" ] && [ "$_sk" != "null" ]; then
          # Derive the top-level jq key to check presence.
          # For "statusLine" → .statusLine
          # For "hooks.PreToolUse.branch-guard-entry" → .hooks
          # For "hooks.PreToolUse.rtk-entry" → .hooks
          local _top_key
          _top_key="${_sk%%.*}"
          # Strip bracket notation if present (e.g. "hooks[x]" → "hooks")
          _top_key="${_top_key%%\[*}"
          if jq -e --arg k "$_top_key" 'has($k)' "$target_settings" >/dev/null 2>&1; then
            echo "    OK       [$_scomp] managed key '$_top_key' presente"
          else
            echo "    MISSING  [$_scomp] managed key '$_top_key' ausente en settings.json"
            any_fail=1
          fi
        fi

        _ci=$((_ci + 1))
      done
    fi
    echo ""

    # --- claude_md_ref por componente ---
    local _shown_claude_md=0
    _ci=0
    while [ "$_ci" -lt "$_STATUS_COMP_COUNT" ]; do
      local _mcomp
      eval "_mcomp=\${_STATUS_COMP_${t}_${_ci}}"
      local _mpath="$FORGE_ROOT/shared/components/${_mcomp}.json"
      if [ -f "$_mpath" ]; then
        local _ref
        _ref="$(jq -r '.claude_md_ref // empty' "$_mpath")"
        if [ -n "$_ref" ]; then
          if [ "$_shown_claude_md" -eq 0 ]; then
            echo "  CLAUDE.md refs ($tgt_name):"
            _shown_claude_md=1
          fi
          local _claude_md_file="$tgt_dir/CLAUDE.md"
          if [ -f "$_claude_md_file" ] && grep -qF "$_ref" "$_claude_md_file" 2>/dev/null; then
            echo "    OK       [$_mcomp] $_ref en CLAUDE.md"
          else
            echo "    MISSING  [$_mcomp] $_ref ausente en CLAUDE.md"
            any_fail=1
          fi
        fi
      fi
      _ci=$((_ci + 1))
    done
    [ "$_shown_claude_md" -eq 1 ] && echo ""

    # --- RTK info (if rtk-hook is a recorded component OR rtk.tracked=true) ---
    local _has_rtk_hook=0
    _ci=0
    while [ "$_ci" -lt "$_STATUS_COMP_COUNT" ]; do
      local _rtk_comp
      eval "_rtk_comp=\${_STATUS_COMP_${t}_${_ci}}"
      if [ "$_rtk_comp" = "rtk-hook" ]; then
        _has_rtk_hook=1
        break
      fi
      _ci=$((_ci + 1))
    done

    _forge_status_rtk_block "$tgt_name" "$tgt_dir" "$_has_rtk_hook" "$_rtk_tracked_global"

    t=$((t + 1))
  done

  if [ "$any_fail" -eq 0 ]; then
    echo "  Estado general: OK"
  else
    echo "  Estado general: DEGRADADO (ver detalles arriba)" >&2
  fi
  echo ""

  return $any_fail
}

cmd_update() {
  # ---------------------------------------------------------------------------
  # cmd_update — git pull + component-scoped update
  # Component-scoped: only refreshes components recorded in state for each target.
  # Falls back to full component list for pre-v3 state entries lacking components field.
  # ---------------------------------------------------------------------------
  local show_cost=0
  for arg in "$@"; do
    case "$arg" in
      --show-cost)  show_cost=1 ;;
      *) ;;
    esac
  done

  forge_banner

  # Try git pull if this is a git repo with a remote
  if git -C "$FORGE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    local has_remote=0
    git -C "$FORGE_ROOT" remote 2>/dev/null | grep -q . && has_remote=1
    if [ "$has_remote" -eq 1 ]; then
      echo "[forge] git pull --ff-only ..."
      git -C "$FORGE_ROOT" pull --ff-only || echo "[forge] WARNING: git pull falló (modo local-only)"
    else
      echo "[forge] INFO: sin remote configurado, omitiendo git pull (modo local-only)"
    fi
  else
    echo "[forge] INFO: $FORGE_ROOT no es un repo git, omitiendo pull"
  fi

  # --- Component-scoped update (same pattern as cmd_repair) ---
  if [ ! -f "$FORGE_STATE_FILE" ]; then
    echo "[forge] WARN: state file no encontrado, no hay nada que actualizar" >&2
  else
    if ! jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
      echo "[forge] ERROR: state file inválido" >&2
      return 1
    fi

    _forge_state_migrate

    local upd_manifest_count
    upd_manifest_count="$(jq -r '.targets_manifest // [] | length' "$FORGE_STATE_FILE")"

    if [ "$upd_manifest_count" -gt 0 ]; then
      echo "[forge] actualizando targets (component-scoped)..."

      local upd_t=0
      while [ "$upd_t" -lt "$upd_manifest_count" ]; do
        local upd_tgt_name upd_tgt_dir
        upd_tgt_name="$(jq -r --argjson i "$upd_t" '.targets_manifest[$i].name' "$FORGE_STATE_FILE")"
        upd_tgt_dir="$(jq -r --argjson i "$upd_t" '.targets_manifest[$i].dir' "$FORGE_STATE_FILE")"

        echo "[forge] actualizando target: $upd_tgt_name ($upd_tgt_dir)"

        # Read recorded components for this target. If the field is missing or empty
        # (pre-v3 state that was not migrated yet), fall back to the full component list.
        local _upd_components_count
        _upd_components_count="$(jq -r --argjson i "$upd_t" \
          '.targets_manifest[$i].components // [] | length' "$FORGE_STATE_FILE")"

        # Build indexed pseudo-array of component names (bash 3.2 compatible)
        local _uc_count=0
        if [ "$_upd_components_count" -eq 0 ]; then
          # Fallback: use full component list
          echo "[forge] WARN: no hay campo 'components' en state para $upd_tgt_name — usando lista por defecto" >&2
          while IFS= read -r _uc_comp; do
            eval "_UPDCOMP_${upd_t}_${_uc_count}=\$_uc_comp"
            _uc_count=$((_uc_count + 1))
          done < <(forge_components_default_list)
        else
          while IFS= read -r _uc_comp; do
            eval "_UPDCOMP_${upd_t}_${_uc_count}=\$_uc_comp"
            _uc_count=$((_uc_count + 1))
          done < <(jq -r --argjson i "$upd_t" '.targets_manifest[$i].components[]' "$FORGE_STATE_FILE")
        fi
        eval "_UPDCOMP_COUNT_${upd_t}=\$_uc_count"

        # Selective cleanup: remove artifacts only for the recorded components before redrawing
        local _upd_comp_args=""
        local _ucc=0
        while [ "$_ucc" -lt "$_uc_count" ]; do
          local _ucc_name
          eval "_ucc_name=\${_UPDCOMP_${upd_t}_${_ucc}}"
          _upd_comp_args="$_upd_comp_args $_ucc_name"
          _ucc=$((_ucc + 1))
        done
        # shellcheck disable=SC2086  # word-split intentional: _upd_comp_args is space-delimited
        _forge_clean_target "$upd_tgt_dir" $_upd_comp_args

        if [ "$upd_tgt_name" = "opencode" ]; then
          forge_run_opencode_installer || return 1
          # The overlay was just (re)deployed: the manifest must point at the
          # directory that really holds it now.
          _forge_state_sync_opencode_paths
          upd_t=$((upd_t + 1))
          continue
        fi

        # Re-install symlinks and target_root_files for each recorded component
        local _ui=0
        while [ "$_ui" -lt "$_uc_count" ]; do
          local _ucomp
          eval "_ucomp=\${_UPDCOMP_${upd_t}_${_ui}}"

          echo "[forge] [$_ucomp] re-instalando symlinks para target: $upd_tgt_name"

          local src_rel dest_rel src_abs dest_abs
          while IFS="	" read -r src_rel dest_rel; do
            src_abs="$FORGE_ROOT/$src_rel"
            dest_abs="$upd_tgt_dir/$dest_rel"
            forge_symlink "$src_abs" "$dest_abs"
          done < <(forge_component_symlinks "$_ucomp" 2>/dev/null || true)

          # Append claude_md_ref if the component manifest specifies one
          local _upd_claude_md_ref
          _upd_claude_md_ref="$(jq -r '.claude_md_ref // empty' \
            "$FORGE_ROOT/shared/components/${_ucomp}.json" 2>/dev/null || true)"
          if [ -n "$_upd_claude_md_ref" ]; then
            _forge_install_claude_md "$upd_tgt_dir"
          fi

          _ui=$((_ui + 1))
        done

        # Re-apply settings merge per recorded component
        echo "[forge] re-aplicando settings merge para target: $upd_tgt_name (per-component)"
        local upd_target_settings="$upd_tgt_dir/settings.json"

        # Ensure settings.json exists and is valid
        mkdir -p "$upd_tgt_dir"
        if [ ! -f "$upd_target_settings" ]; then
          local tmp_upd_s
          tmp_upd_s="$(mktemp)"
          printf '{}' > "$tmp_upd_s"
          mv "$tmp_upd_s" "$upd_target_settings"
          echo "[settings] created $upd_target_settings (was missing)"
        fi
        if ! jq empty "$upd_target_settings" 2>/dev/null; then
          if [ -f "${upd_target_settings}.pre-forge" ]; then
            cp "${upd_target_settings}.pre-forge" "$upd_target_settings"
            echo "[settings] WARN: settings.json corrupto, restaurado desde .pre-forge"
          else
            echo "[settings] ERROR: settings.json corrupto y no hay .pre-forge" >&2
            upd_t=$((upd_t + 1))
            continue
          fi
        fi

        local _usi=0
        while [ "$_usi" -lt "$_uc_count" ]; do
          local _uscomp
          eval "_uscomp=\${_UPDCOMP_${upd_t}_${_usi}}"
          echo "[forge] [$_uscomp] merging settings into $upd_target_settings"
          forge_merge_component_settings "$_uscomp" "$upd_target_settings" "--target-dir=$upd_tgt_dir"
          _usi=$((_usi + 1))
        done

        upd_t=$((upd_t + 1))
      done
    fi
  fi

  # --- Sentinel file .forge-show-cost ---
  # Apply to each registered non-opencode target from state.
  if [ -f "$FORGE_STATE_FILE" ] && jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    local sc_manifest_count sc_t
    sc_manifest_count="$(jq -r '.targets_manifest // [] | length' "$FORGE_STATE_FILE")"
    sc_t=0
    while [ "$sc_t" -lt "$sc_manifest_count" ]; do
      local sc_name sc_dir
      sc_name="$(jq -r --argjson i "$sc_t" '.targets_manifest[$i].name' "$FORGE_STATE_FILE")"
      sc_dir="$(jq -r --argjson i "$sc_t" '.targets_manifest[$i].dir' "$FORGE_STATE_FILE")"
      if [ "$sc_name" = "opencode" ]; then
        sc_t=$((sc_t + 1))
        continue
      fi
      local sentinel="${sc_dir}/.forge-show-cost"
      if [ "$show_cost" = "1" ]; then
        touch "$sentinel"
        echo "[forge] statusline coste de sesión activado (${sentinel/#$HOME/\~})"
      else
        rm -f "$sentinel"
        echo "[forge] statusline coste de sesión desactivado (pasa --show-cost para activarlo)"
      fi
      sc_t=$((sc_t + 1))
    done
  fi

  # Update state: add updated_at timestamp
  if [ -f "$FORGE_STATE_FILE" ] && jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    _forge_state_migrate
    local upd_tmp upd_at
    upd_tmp="$(mktemp)"
    upd_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq --arg upd "$upd_at" '. + {updated_at: $upd}' "$FORGE_STATE_FILE" > "$upd_tmp"
    # shellcheck disable=SC2015  # intentional: A && B || C used for atomic write-or-cleanup
    jq empty "$upd_tmp" && mv "$upd_tmp" "$FORGE_STATE_FILE" || rm -f "$upd_tmp"
    echo "[forge] state actualizado (updated_at: $upd_at)"
  fi

  forge_print_summary "update"
}

# _forge_strip_claude_md_ref <component_name> <tgt_dir>
# Removes the component's claude_md_ref line from <tgt_dir>/CLAUDE.md.
# If CLAUDE.md is itself an forge-owned symlink the symlink is removed instead
# of being materialised as a regular file by the grep+mv rewrite.
_forge_strip_claude_md_ref() {
  local _scr_component="$1"
  local _scr_tgt_dir="$2"

  local _scr_ref
  _scr_ref="$(jq -r '.claude_md_ref // empty' \
    "$FORGE_ROOT/shared/components/${_scr_component}.json" 2>/dev/null || true)"
  [ -n "$_scr_ref" ] || return 0

  local _scr_claude_md="$_scr_tgt_dir/CLAUDE.md"

  if [ -L "$_scr_claude_md" ]; then
    local _scr_link_target
    _scr_link_target="$(readlink "$_scr_claude_md" 2>/dev/null || true)"
    case "$_scr_link_target" in
      "$FORGE_ROOT"/*)
        rm "$_scr_claude_md"
        echo "[uninstall] [$_scr_component] removed CLAUDE.md symlink: ${_scr_claude_md/#$HOME/\~}"
        ;;
    esac
    return 0
  fi

  if [ -f "$_scr_claude_md" ] && grep -qF "$_scr_ref" "$_scr_claude_md"; then
    local _scr_tmp
    _scr_tmp="$(mktemp)"
    grep -vF "$_scr_ref" "$_scr_claude_md" > "$_scr_tmp" || true
    mv "$_scr_tmp" "$_scr_claude_md"
    echo "[uninstall] [$_scr_component] removed '$_scr_ref' from ${_scr_claude_md/#$HOME/\~}"
  fi
}

# _forge_sweep_empty_dirs <tgt_dir>
# Removes directories left empty after symlink removal: skills/<name>/ (and
# their reference/ subdirs), skills/, tools/release/, tools/, agents/, rules/.
# Only genuinely empty directories are removed — anything still holding user
# files is left untouched.
_forge_sweep_empty_dirs() {
  local _swp_tgt_dir="$1"
  if [ -z "$_swp_tgt_dir" ] || [ ! -d "$_swp_tgt_dir" ]; then
    return 0
  fi

  local _skill_subdir
  for _skill_subdir in "$_swp_tgt_dir"/skills/*/; do
    [ -d "$_skill_subdir" ] || continue
    local _ref_dir="${_skill_subdir}reference"
    if [ -d "$_ref_dir" ] && [ -z "$(ls -A "$_ref_dir" 2>/dev/null)" ]; then
      rmdir "$_ref_dir"
      echo "[clean] removed empty directory: ${_ref_dir/#$HOME/\~}"
    fi
    if [ -z "$(ls -A "$_skill_subdir" 2>/dev/null)" ]; then
      local _skill_subdir_trim="${_skill_subdir%/}"
      rmdir "$_skill_subdir_trim"
      echo "[clean] removed empty directory: ${_skill_subdir_trim/#$HOME/\~}"
    fi
  done

  local _swp_dir
  for _swp_dir in "$_swp_tgt_dir/skills" "$_swp_tgt_dir/tools/release" "$_swp_tgt_dir/tools" "$_swp_tgt_dir/agents" "$_swp_tgt_dir/rules"; do
    if [ -d "$_swp_dir" ] && [ -z "$(ls -A "$_swp_dir" 2>/dev/null)" ]; then
      rmdir "$_swp_dir"
      echo "[clean] removed empty directory: ${_swp_dir/#$HOME/\~}"
    fi
  done
}

# _forge_sanitize_restored_settings <settings_file> <removing_rtk:0|1>
# After a .pre-forge restore (or inverse overlay) the recovered user settings
# can reference artifacts this uninstall just removed. Drops, with a warning:
#   - hook entries whose command invokes rtk, when the rtk binary is being
#     removed — or, for bare "rtk ..." invocations, when no rtk resolves on PATH
#   - statusLine / subagentStatusLine whose command points at a missing *.sh
# The original content remains available in settings.json.pre-forge.
# Atomic and idempotent; a clean settings file passes through unchanged.
_forge_sanitize_restored_settings() {
  local _san_file="$1"
  local _san_removing_rtk="${2:-0}"

  [ -f "$_san_file" ] || return 0
  jq empty "$_san_file" 2>/dev/null || return 0

  local _san_rtk_resolvable=0
  if command -v rtk >/dev/null 2>&1; then
    _san_rtk_resolvable=1
  fi

  # Shared jq predicates for rtk-invoking hook entries
  local _san_defs
  # shellcheck disable=SC2016  # single-quoted jq program: $ is jq syntax, not shell
  _san_defs='
    def is_rtk_cmd: ((.command // "") | test("(^|[^[:alnum:]_./-])rtk([[:space:]]|$)"))
      or ((.command // "") | test("/\\.forge/bin/rtk"));
    def is_abs_rtk: (.command // "") | test("/\\.forge/bin/rtk");
    def drop_hook: is_rtk_cmd and (($removing == 1) or (($resolvable == 0) and (is_abs_rtk | not)));
  '

  # 1. Hook entries that invoke a dead rtk
  local _san_dropped
  _san_dropped="$(jq -r \
    --argjson removing "$_san_removing_rtk" \
    --argjson resolvable "$_san_rtk_resolvable" \
    "$_san_defs"'
    [ .hooks? // {} | to_entries[] | (.value | if type == "array" then . else [] end)[]
      | (.hooks? // [])[] | select(drop_hook) | .command ] | .[]
    ' "$_san_file" 2>/dev/null || true)"

  if [ -n "$_san_dropped" ]; then
    local _san_tmp
    _san_tmp="$(mktemp)"
    jq \
      --argjson removing "$_san_removing_rtk" \
      --argjson resolvable "$_san_rtk_resolvable" \
      "$_san_defs"'
      if .hooks then
        .hooks |= with_entries(
          if (.value | type) == "array" then
            .value |= (map(if (.hooks? // null) != null then (.hooks |= map(select(drop_hook | not))) else . end)
                       | map(select(((.hooks? // null) == null) or ((.hooks | length) > 0))))
          else . end
        )
        | .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0))
        | (if (.hooks | length) == 0 then del(.hooks) else . end)
      else . end
      ' "$_san_file" > "$_san_tmp" 2>/dev/null || { rm -f "$_san_tmp"; return 0; }
    if jq empty "$_san_tmp" 2>/dev/null; then
      mv "$_san_tmp" "$_san_file"
      local _san_cmd_line
      while IFS= read -r _san_cmd_line; do
        [ -n "$_san_cmd_line" ] || continue
        echo "[settings] WARN: hook rtk no funcional eliminado de ${_san_file/#$HOME/\~}: '$_san_cmd_line' (original en .pre-forge)"
      done <<EOF
$_san_dropped
EOF
    else
      rm -f "$_san_tmp"
    fi
  fi

  # 2. statusLine / subagentStatusLine pointing at a script that no longer exists
  local _san_key _san_cmd _san_script _san_tok
  for _san_key in statusLine subagentStatusLine; do
    _san_cmd="$(jq -r --arg k "$_san_key" \
      '.[$k] // empty | if type == "object" and .type == "command" then .command // empty else empty end' \
      "$_san_file" 2>/dev/null || true)"
    [ -n "$_san_cmd" ] || continue

    # First whitespace-separated token ending in .sh; expand leading ~ and $HOME
    _san_script=""
    for _san_tok in $_san_cmd; do
      case "$_san_tok" in
        *.sh) _san_script="$_san_tok"; break ;;
      esac
    done
    [ -n "$_san_script" ] || continue
    # shellcheck disable=SC2088  # literal tilde match is intentional: the token comes from JSON, unexpanded
    case "$_san_script" in
      "~/"*) _san_script="$HOME/${_san_script#"~/"}" ;;
    esac
    _san_script="${_san_script//\$HOME/$HOME}"
    # Only act on absolute paths we can actually verify
    case "$_san_script" in
      /*) ;;
      *) continue ;;
    esac

    if [ ! -e "$_san_script" ]; then
      local _san_tmp2
      _san_tmp2="$(mktemp)"
      jq --arg k "$_san_key" 'del(.[$k])' "$_san_file" > "$_san_tmp2" 2>/dev/null || { rm -f "$_san_tmp2"; continue; }
      if jq empty "$_san_tmp2" 2>/dev/null; then
        mv "$_san_tmp2" "$_san_file"
        echo "[settings] WARN: ${_san_key} apuntaba a un script inexistente (${_san_script/#$HOME/\~}); entrada eliminada (original en .pre-forge)"
      else
        rm -f "$_san_tmp2"
      fi
    fi
  done

  return 0
}

cmd_uninstall() {
  # ---------------------------------------------------------------------------
  # cmd_uninstall — restore backups, remove symlinks, delete state
  # Flags: --purge (delete *.forge-bak-* files and settings.json.pre-forge)
  #        --component=<name> (selective: remove only this component)
  #        --keep-rtk (full uninstall only: keep the pinned RTK binary + PATH)
  # Idempotent: safe to run when nothing is installed.
  # ---------------------------------------------------------------------------
  forge_banner

  local purge=0
  local component_name=""
  local keep_rtk=0
  for arg in "$@"; do
    case "$arg" in
      --purge)         purge=1 ;;
      --component=*)   component_name="${arg#--component=}" ;;
      --keep-rtk)      keep_rtk=1 ;;
      *) ;;
    esac
  done

  if [ ! -f "$FORGE_STATE_FILE" ]; then
    echo "[forge] nada que desinstalar (state file no encontrado)"
    return 0
  fi

  if ! jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    echo "[forge] ERROR: state file inválido; desinstalación manual requerida" >&2
    return 1
  fi

  _forge_state_migrate

  # ---------------------------------------------------------------------------
  # --component=<name> validation (step 7.1)
  # When the flag is present:
  #   1. Validate <name> is a known component (in forge_components_list).
  #   2. Validate <name> is recorded in the target's state components array.
  # When the flag is absent: fall through to the full-uninstall path unchanged.
  # ---------------------------------------------------------------------------
  if [ -n "$component_name" ]; then
    # 1. Validate against catalog
    local _cu_found=0
    while IFS= read -r _known; do
      if [ "$component_name" = "$_known" ]; then
        _cu_found=1
        break
      fi
    done < <(forge_components_list)
    if [ "$_cu_found" -eq 0 ]; then
      echo "[forge] ERROR: componente desconocido: '$component_name'" >&2
      echo "[forge]   → componentes válidos: $(forge_components_list | tr '\n' ',' | sed 's/,$//')" >&2
      return 1
    fi

    # 2. Validate component is recorded in at least one target's state
    local _cu_in_state
    _cu_in_state="$(jq -r --arg comp "$component_name" \
      '[.targets_manifest[]?.components[]? | select(. == $comp)] | length' \
      "$FORGE_STATE_FILE" 2>/dev/null || echo "0")"
    if [ "$_cu_in_state" = "0" ] || [ -z "$_cu_in_state" ]; then
      echo "[forge] ERROR: el componente '$component_name' no está instalado en ningún target" >&2
      echo "[forge]   → componentes instalados: $(jq -r '[.targets_manifest[]?.components[]?] | unique | .[]' "$FORGE_STATE_FILE" 2>/dev/null | tr '\n' ',' | sed 's/,$//')" >&2
      return 1
    fi

    # Validated — proceed with selective removal for each target that has this component.
    echo "[forge] desinstalación selectiva: componente '$component_name'"

    local _su_manifest_count
    _su_manifest_count="$(jq -r '.targets_manifest // [] | length' "$FORGE_STATE_FILE")"

    # Build a snapshot of (name, dir) tuples BEFORE the loop so that deleting a target
    # from targets_manifest during iteration (which shifts array indices) does not corrupt
    # the remaining iterations. The snapshot indices are stable throughout the loop.
    local _su_snap_i=0
    while [ "$_su_snap_i" -lt "$_su_manifest_count" ]; do
      eval "_su_snap_name_${_su_snap_i}=\"$(jq -r --argjson i "$_su_snap_i" '.targets_manifest[$i].name' "$FORGE_STATE_FILE")\""
      eval "_su_snap_dir_${_su_snap_i}=\"$(jq -r --argjson i "$_su_snap_i" '.targets_manifest[$i].dir' "$FORGE_STATE_FILE")\""
      _su_snap_i=$((_su_snap_i + 1))
    done

    local _su_t=0
    while [ "$_su_t" -lt "$_su_manifest_count" ]; do
      local _su_tgt_name _su_tgt_dir
      eval "_su_tgt_name=\"\$_su_snap_name_${_su_t}\""
      eval "_su_tgt_dir=\"\$_su_snap_dir_${_su_t}\""

      # Check if this component is in this target's components list (re-read live state by name,
      # not by index, so we are immune to index shifts caused by earlier deletions).
      local _su_has_comp
      _su_has_comp="$(jq -r --arg tgt "$_su_tgt_name" --arg comp "$component_name" \
        '(.targets_manifest[] | select(.name == $tgt)) | .components // [] | map(select(. == $comp)) | length' \
        "$FORGE_STATE_FILE" 2>/dev/null || echo "0")"

      if [ "${_su_has_comp:-0}" = "0" ]; then
        _su_t=$((_su_t + 1))
        continue
      fi

      echo "[forge] [$component_name] procesando target: $_su_tgt_name ($_su_tgt_dir)"

      # 1. Remove component symlinks via selective cleanup
      _forge_clean_target "$_su_tgt_dir" "$component_name"

      # 2. Remove target-root files (e.g. CLAUDE-shared.md for 'agents')
      local _su_trf_count
      _su_trf_count="$(jq -r '.target_root_files | length' \
        "$FORGE_ROOT/shared/components/${component_name}.json" 2>/dev/null || echo "0")"

      local _su_trf_i=0
      while [ "$_su_trf_i" -lt "$_su_trf_count" ]; do
        local _su_trf_dest
        _su_trf_dest="$(jq -r ".target_root_files[$_su_trf_i].dest" \
          "$FORGE_ROOT/shared/components/${component_name}.json" 2>/dev/null)"
        if [ -n "$_su_trf_dest" ] && [ "$_su_trf_dest" != "null" ]; then
          local _su_trf_path="$_su_tgt_dir/$_su_trf_dest"
          if [ -L "$_su_trf_path" ]; then
            rm "$_su_trf_path"
            echo "[uninstall] [$component_name] removed target-root symlink: ${_su_trf_path/#$HOME/\~}"
          elif [ -n "$_su_tgt_dir" ] && [ -f "$_su_trf_path" ]; then
            rm "$_su_trf_path"
            echo "[uninstall] [$component_name] removed target-root file: ${_su_trf_path/#$HOME/\~}"
          fi
        fi
        _su_trf_i=$((_su_trf_i + 1))
      done

      # 3. Remove settings fragment via forge_unmerge_component_settings
      local _su_target_settings="$_su_tgt_dir/settings.json"
      if [ -f "$_su_target_settings" ]; then
        forge_unmerge_component_settings "$component_name" "$_su_target_settings"
      fi

      # 4. Strip claude_md_ref line from CLAUDE.md if present
      _forge_strip_claude_md_ref "$component_name" "$_su_tgt_dir"

      # 5. Update state: remove component_name from this target's components array
      #    and re-sync the legacy flat symlinks array from the updated symlinks_objects.
      #    Use name-based lookup (not index-based) so index shifts from earlier deletions
      #    in this loop do not affect the result.
      local _su_remaining_components
      _su_remaining_components="$(jq -c --arg tgt "$_su_tgt_name" --arg comp "$component_name" \
        '(.targets_manifest[] | select(.name == $tgt)).components // [] | map(select(. != $comp))' \
        "$FORGE_STATE_FILE" 2>/dev/null || echo "[]")"

      local _su_remaining_count
      _su_remaining_count="$(printf '%s' "$_su_remaining_components" | jq 'length')"

      if [ "${_su_remaining_count:-0}" = "0" ]; then
        # All components removed from this target: clean up remaining artifacts.
        # No .pre-forge restore needed — unmerge already reversed managed keys.
        echo "[forge] [$component_name] sin componentes restantes en target '$_su_tgt_name' — eliminando target del state"

        # Remove entire target from targets_manifest and targets array
        local _su_tmp_state
        _su_tmp_state="$(mktemp)"
        jq --arg tgt "$_su_tgt_name" \
          '.targets_manifest = [.targets_manifest[] | select(.name != $tgt)] |
           .targets = (.targets // [] | map(select(. != $tgt))) |
           .symlinks = ([.targets_manifest[].symlinks[]?] | unique)' \
          "$FORGE_STATE_FILE" > "$_su_tmp_state"
        if jq empty "$_su_tmp_state" 2>/dev/null; then
          mv "$_su_tmp_state" "$FORGE_STATE_FILE"
          echo "[forge] target '$_su_tgt_name' eliminado del state"
        else
          rm -f "$_su_tmp_state"
          echo "[forge] ERROR: state file inválido tras eliminar target, no se escribió" >&2
        fi

        # If no targets remain, remove the state file entirely
        local _su_remaining_targets
        _su_remaining_targets="$(jq -r '.targets_manifest // [] | length' "$FORGE_STATE_FILE" 2>/dev/null || echo "0")"
        if [ "${_su_remaining_targets:-0}" = "0" ]; then
          rm -f "$FORGE_STATE_FILE"
          echo "[forge] state file eliminado (instalación vacía)"
        fi
      else
        # Remove the component from components and re-sync symlinks_objects and flat symlinks.
        # For symlinks_objects: remove entries whose dest belongs to this component.
        local _su_comp_dests
        _su_comp_dests="$(jq -c '[.symlinks[].dest, .target_root_files[].dest]' \
          "$FORGE_ROOT/shared/components/${component_name}.json" 2>/dev/null || echo "[]")"

        local _su_tmp_state
        _su_tmp_state="$(mktemp)"
        jq \
          --arg tgt "$_su_tgt_name" \
          --argjson remaining_comps "$_su_remaining_components" \
          --argjson rm_dests "$_su_comp_dests" \
          '
          ((.targets_manifest[] | select(.name == $tgt)).symlinks_objects) as $cur_objs |
          ($cur_objs // [] | map(select(.dest as $d | $rm_dests | map(select(. == $d)) | length == 0))) as $new_objs |
          ($new_objs | [.[].dest]) as $new_flat |
          (.targets_manifest | map(if .name == $tgt then
            .components = $remaining_comps |
            .symlinks_objects = $new_objs |
            .symlinks = $new_flat
          else . end)) as $new_manifest |
          .targets_manifest = $new_manifest |
          .symlinks = ([.targets_manifest[].symlinks[]?] | unique)
          ' \
          "$FORGE_STATE_FILE" > "$_su_tmp_state"
        if jq empty "$_su_tmp_state" 2>/dev/null; then
          mv "$_su_tmp_state" "$FORGE_STATE_FILE"
          echo "[forge] [$component_name] state actualizado para target '$_su_tgt_name'"
        else
          rm -f "$_su_tmp_state"
          echo "[forge] ERROR: state file inválido tras actualizar componentes, no se escribió" >&2
        fi
      fi

      _su_t=$((_su_t + 1))
    done

    forge_print_summary "uninstall --component=$component_name"
    return 0
  fi

  # --- Remove symlinks ---
  # State stores dests relative to each target dir (install joins
  # "$tgt_dir/$dest_rel" at link time), so resolve them per target here.
  # Absolute entries pass through unchanged for older state files.
  local _rs_t_count
  _rs_t_count="$(jq -r '.targets_manifest // [] | length' "$FORGE_STATE_FILE")"
  local _rs_t=0
  while [ "$_rs_t" -lt "$_rs_t_count" ]; do
    local _rs_tgt_dir
    _rs_tgt_dir="$(jq -r --argjson i "$_rs_t" '.targets_manifest[$i].dir // empty' "$FORGE_STATE_FILE")"
    local _rs_dest
    while IFS= read -r _rs_dest; do
      [ -z "$_rs_dest" ] && continue
      case "$_rs_dest" in
        /*) forge_unlink "$_rs_dest" ;;
        *)
          if [ -n "$_rs_tgt_dir" ]; then
            forge_unlink "$_rs_tgt_dir/$_rs_dest"
          else
            echo "[forge] WARNING: symlink relativo sin dir de target, omitido: $_rs_dest" >&2
          fi
          ;;
      esac
    done < <(jq -r --argjson i "$_rs_t" '.targets_manifest[$i].symlinks // [] | .[]' "$FORGE_STATE_FILE")
    _rs_t=$((_rs_t + 1))
  done

  # --- Strip claude_md_ref lines and sweep leftover empty dirs per target ---
  # The selective path does this per component; the full path must do the same
  # for every component recorded in state (otherwise @CLAUDE-shared.md dangles
  # in the user's CLAUDE.md after a full uninstall).
  local _fu_t_count
  _fu_t_count="$(jq -r '.targets_manifest // [] | length' "$FORGE_STATE_FILE" 2>/dev/null || echo "0")"
  local _fu_t=0
  while [ "$_fu_t" -lt "$_fu_t_count" ]; do
    local _fu_tgt_dir
    _fu_tgt_dir="$(jq -r --argjson i "$_fu_t" '.targets_manifest[$i].dir' "$FORGE_STATE_FILE")"
    if [ -n "$_fu_tgt_dir" ] && [ "$_fu_tgt_dir" != "null" ]; then
      local _fu_comp
      while IFS= read -r _fu_comp; do
        [ -z "$_fu_comp" ] && continue
        _forge_strip_claude_md_ref "$_fu_comp" "$_fu_tgt_dir"
      done < <(jq -r --argjson i "$_fu_t" '.targets_manifest[$i].components // [] | .[]' "$FORGE_STATE_FILE")
      _forge_sweep_empty_dirs "$_fu_tgt_dir"
    fi
    _fu_t=$((_fu_t + 1))
  done

  # --- Remove the pinned RTK binary (default) ---
  # The binary lives in forge's private dir (~/.forge); a full uninstall
  # removes it together with its PATH snippet unless --keep-rtk is given.
  local _fu_removing_rtk=0
  if [ "$keep_rtk" -eq 1 ]; then
    if [ -e "$HOME/.forge/bin/rtk" ]; then
      echo "[rtk] RTK pineado conservado (--keep-rtk): ~/.forge/bin/rtk"
    fi
  elif [ -e "$HOME/.forge/bin/rtk" ] || [ -L "$HOME/.forge/bin/rtk" ]; then
    _fu_removing_rtk=1
    if command -v forge_rtk_remove_binary >/dev/null 2>&1; then
      forge_rtk_remove_binary
      forge_rtk_strip_path_snippet
    else
      rm -f "$HOME/.forge/bin/rtk"
      rmdir "$HOME/.forge/bin" "$HOME/.forge" 2>/dev/null || true
      echo "[rtk] RTK eliminado: ~/.forge/bin/rtk"
    fi
    echo "[rtk] RTK pineado eliminado (usa --keep-rtk para conservarlo)"
  fi

  if forge_state_has_opencode_target; then
    forge_run_opencode_uninstaller
  fi

  # --- Restore settings ---
  # Iterate over targets that have a settings backup registered
  local settings_targets
  settings_targets="$(jq -r '.settings.settings_json_backup // {} | keys[]' "$FORGE_STATE_FILE" 2>/dev/null || true)"

  for tgt_name in $settings_targets; do
    local tgt_dir
    case "$tgt_name" in
      claude)   tgt_dir="$HOME/.claude" ;;
      opencode) tgt_dir="$(_forge_state_opencode_dir)" ;;
      *)        tgt_dir="$HOME/.claude" ;;
    esac
    local sfile="$tgt_dir/settings.json"
    local pre_forge="${sfile}.pre-forge"

    if [ -f "$pre_forge" ]; then
      # Atomic restore: copy to tmp, validate, then rename
      local restore_tmp
      restore_tmp="$(mktemp)"
      cp "$pre_forge" "$restore_tmp"
      if jq empty "$restore_tmp" 2>/dev/null; then
        mv "$restore_tmp" "$sfile"
        echo "[settings] [$tgt_name] restaurado desde .pre-forge"
        _forge_sanitize_restored_settings "$sfile" "$_fu_removing_rtk"
      else
        rm -f "$restore_tmp"
        echo "[settings] ERROR [$tgt_name]: .pre-forge corrupto, no se restauró" >&2
      fi
    else
      # Fallback: apply overlay_backup (inverse overlay — restore managed keys to pre-install values)
      local overlay_json
      overlay_json="$(jq -c --arg n "$tgt_name" '.settings.overlay_backup[$n] // null' "$FORGE_STATE_FILE" 2>/dev/null || echo "null")"

      if [ "$overlay_json" != "null" ] && [ -n "$overlay_json" ]; then
        echo "[settings] WARN [$tgt_name]: no hay .pre-forge, aplicando overlay inverso desde state"
        if [ -f "$sfile" ] && jq empty "$sfile" 2>/dev/null; then
          local managed_paths_json
          managed_paths_json="$(jq -c '.settings.managed_paths // []' "$FORGE_STATE_FILE")"
          local ov_tmp
          ov_tmp="$(mktemp)"
          # For each managed path, restore the value from overlay_backup (or delete if null)
          # We use jq reduce over managed_paths array
          jq --argjson overlay "$overlay_json" \
             --argjson paths "$managed_paths_json" \
             'reduce $paths[] as $p (
                .;
                ($overlay | getpath($p | split(".") | map(select(. != "")))) as $v |
                if $v == null then delpaths([[$p | split(".") | map(select(. != ""))[]]]) else setpath($p | split(".") | map(select(. != "")); $v) end
             )' "$sfile" > "$ov_tmp"
          if jq empty "$ov_tmp" 2>/dev/null; then
            mv "$ov_tmp" "$sfile"
            echo "[settings] [$tgt_name] overlay inverso aplicado"
            _forge_sanitize_restored_settings "$sfile" "$_fu_removing_rtk"
          else
            rm -f "$ov_tmp"
            echo "[settings] ERROR [$tgt_name]: overlay inverso generó JSON inválido" >&2
          fi
        else
          echo "[settings] WARN [$tgt_name]: settings.json no existe o es inválido, no se puede restaurar overlay"
        fi
      else
        echo "[settings] WARN [$tgt_name]: sin .pre-forge ni overlay_backup, settings.json no restaurado"
      fi
    fi

    # Purge *.forge-bak-* and the .pre-forge baseline if --purge
    if [ "$purge" -eq 1 ] && [ -d "$tgt_dir" ]; then
      find "$tgt_dir" -name '*.forge-bak-*' -maxdepth 1 -exec rm -f {} \; 2>/dev/null || true
      rm -f "$pre_forge"
      echo "[settings] [$tgt_name] backups *.forge-bak-* y .pre-forge eliminados (--purge)"
    fi
  done

  # --- Remove state file ---
  rm -f "$FORGE_STATE_FILE"
  echo "[forge] state file eliminado"
  forge_print_summary "uninstall"
}

cmd_repair() {
  # ---------------------------------------------------------------------------
  # cmd_repair — re-create broken/missing symlinks and re-apply settings merge
  # Idempotent. Reads state to know which targets were installed.
  # Component-scoped: only refreshes components recorded in state for each target.
  # Falls back to full component list for pre-v3 state entries lacking components field.
  # ---------------------------------------------------------------------------
  forge_banner

  if [ ! -f "$FORGE_STATE_FILE" ]; then
    echo "[forge] WARN: state file no encontrado, no hay nada que reparar" >&2
    return 0
  fi

  _forge_state_migrate

  if ! jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
    echo "[forge] ERROR: state file inválido" >&2
    return 1
  fi

  # Read registered targets from state (targets_manifest is guaranteed by _forge_state_migrate)
  local manifest_count
  manifest_count="$(jq -r '.targets_manifest // [] | length' "$FORGE_STATE_FILE")"

  if [ "$manifest_count" -eq 0 ]; then
    echo "[forge] WARN: sin targets registrados en state"
    return 0
  fi

  echo "[forge] reparando targets (component-scoped)..."

  local t=0
  while [ "$t" -lt "$manifest_count" ]; do
    local tgt_name tgt_dir
    tgt_name="$(jq -r --argjson i "$t" '.targets_manifest[$i].name' "$FORGE_STATE_FILE")"
    tgt_dir="$(jq -r --argjson i "$t" '.targets_manifest[$i].dir' "$FORGE_STATE_FILE")"

    echo "[forge] reparando target: $tgt_name ($tgt_dir)"

    # Read recorded components for this target. If the field is missing or empty
    # (pre-v3 state that was not migrated yet), fall back to the full component list.
    local _repair_components_json
    _repair_components_json="$(jq -r --argjson i "$t" \
      '.targets_manifest[$i].components // [] | length' "$FORGE_STATE_FILE")"

    # Build indexed pseudo-array of component names (bash 3.2 compatible)
    local _rc_count=0
    if [ "$_repair_components_json" -eq 0 ]; then
      # Fallback: use full component list
      echo "[forge] WARN: no hay campo 'components' en state para $tgt_name — usando lista por defecto" >&2
      while IFS= read -r _rc_comp; do
        eval "_REPCOMP_${t}_${_rc_count}=\$_rc_comp"
        _rc_count=$((_rc_count + 1))
      done < <(forge_components_default_list)
    else
      while IFS= read -r _rc_comp; do
        eval "_REPCOMP_${t}_${_rc_count}=\$_rc_comp"
        _rc_count=$((_rc_count + 1))
      done < <(jq -r --argjson i "$t" '.targets_manifest[$i].components[]' "$FORGE_STATE_FILE")
    fi
    eval "_REPCOMP_COUNT_${t}=\$_rc_count"

    # Selective cleanup: remove artifacts only for the recorded components before redrawing
    local _comp_args=""
    local _cc=0
    while [ "$_cc" -lt "$_rc_count" ]; do
      local _cc_name
      eval "_cc_name=\${_REPCOMP_${t}_${_cc}}"
      _comp_args="$_comp_args $_cc_name"
      _cc=$((_cc + 1))
    done
    # shellcheck disable=SC2086  # word-split intentional: _comp_args is space-delimited
    _forge_clean_target "$tgt_dir" $_comp_args

    if [ "$tgt_name" = "opencode" ]; then
      forge_run_opencode_installer || return 1
      # The overlay was just (re)deployed: the manifest must point at the
      # directory that really holds it now.
      _forge_state_sync_opencode_paths
      t=$((t + 1))
      continue
    fi

    # Re-install symlinks and target_root_files for each recorded component
    local _ci=0
    while [ "$_ci" -lt "$_rc_count" ]; do
      local _comp
      eval "_comp=\${_REPCOMP_${t}_${_ci}}"

      echo "[forge] [$_comp] re-instalando symlinks para target: $tgt_name"

      local src_rel dest_rel src_abs dest_abs
      while IFS="	" read -r src_rel dest_rel; do
        src_abs="$FORGE_ROOT/$src_rel"
        dest_abs="$tgt_dir/$dest_rel"
        forge_symlink "$src_abs" "$dest_abs"
      done < <(forge_component_symlinks "$_comp" 2>/dev/null || true)

      # Append claude_md_ref if the component manifest specifies one
      local _claude_md_ref
      _claude_md_ref="$(jq -r '.claude_md_ref // empty' \
        "$FORGE_ROOT/shared/components/${_comp}.json" 2>/dev/null || true)"
      if [ -n "$_claude_md_ref" ]; then
        _forge_install_claude_md "$tgt_dir"
      fi

      _ci=$((_ci + 1))
    done

    # Re-apply settings merge per recorded component
    echo "[forge] re-aplicando settings merge para target: $tgt_name (per-component)"
    local target_settings="$tgt_dir/settings.json"

    # Ensure settings.json exists and is valid
    mkdir -p "$tgt_dir"
    if [ ! -f "$target_settings" ]; then
      local tmp_repair_s
      tmp_repair_s="$(mktemp)"
      printf '{}' > "$tmp_repair_s"
      mv "$tmp_repair_s" "$target_settings"
      echo "[settings] created $target_settings (was missing)"
    fi
    if ! jq empty "$target_settings" 2>/dev/null; then
      if [ -f "${target_settings}.pre-forge" ]; then
        cp "${target_settings}.pre-forge" "$target_settings"
        echo "[settings] WARN: settings.json corrupto, restaurado desde .pre-forge"
      else
        echo "[settings] ERROR: settings.json corrupto y no hay .pre-forge" >&2
        t=$((t + 1))
        continue
      fi
    fi

    local _si=0
    while [ "$_si" -lt "$_rc_count" ]; do
      local _scomp
      eval "_scomp=\${_REPCOMP_${t}_${_si}}"
      echo "[forge] [$_scomp] merging settings into $target_settings"
      forge_merge_component_settings "$_scomp" "$target_settings" "--target-dir=$tgt_dir"
      _si=$((_si + 1))
    done

    t=$((t + 1))
  done

  forge_print_summary "repair"
}

cmd_doctor() {
  # ---------------------------------------------------------------------------
  # cmd_doctor — comprehensive read-only diagnostic
  # Prints PASS/WARN/FAIL per check. Exit 0 if no FAILs, exit 1 otherwise.
  # ---------------------------------------------------------------------------
  forge_banner

  local fail_count=0
  local warn_count=0

  _doc_pass() { echo "  PASS  $1"; }
  _doc_warn() { echo "  WARN  $1"; warn_count=$((warn_count + 1)); }
  _doc_fail() { echo "  FAIL  $1" >&2; fail_count=$((fail_count + 1)); }

  echo ""
  echo "  forge — diagnóstico de entorno"
  echo "  ─────────────────────────────────────────"

  # 1. Bash version
  local bash_major="${BASH_VERSINFO[0]:-0}"
  local bash_minor="${BASH_VERSINFO[1]:-0}"
  if [ "$bash_major" -gt 4 ] || { [ "$bash_major" -eq 4 ] && [ "$bash_minor" -ge 0 ]; }; then
    _doc_pass "bash $bash_major.$bash_minor (4+ recomendado, OK)"
  elif [ "$bash_major" -ge 3 ] && [ "$bash_minor" -ge 2 ]; then
    _doc_warn "bash $bash_major.$bash_minor (funcional mínimo; 4+ recomendado)"
    echo "  HINT  brew install bash  (luego añade el nuevo bash al PATH antes que /bin/bash)"
  else
    _doc_fail "bash $bash_major.$bash_minor (demasiado antigua, se requiere 3.2+)"
  fi

  # 2. jq disponible
  if command -v jq >/dev/null 2>&1; then
    local jq_ver
    jq_ver="$(jq --version 2>/dev/null || echo "?")"
    _doc_pass "jq instalado ($jq_ver)"
  else
    _doc_fail "jq NO encontrado en PATH (requerido)"
  fi

  # 3. ~/.claude existe
  if [ -d "$HOME/.claude" ]; then
    # shellcheck disable=SC2088  # tilde is display text, not a path to expand
    _doc_pass "~/.claude existe"
  else
    # shellcheck disable=SC2088  # tilde is display text, not a path to expand
    _doc_warn "~/.claude no existe (se crea en install)"
  fi

  # 5. State file + per-target, per-component checks
  # Component-scoped: only checks components recorded in state for each target.
  # Falls back to full component list for pre-v3 state entries lacking components field.
  # Initialized here so a missing or corrupt state file cannot leave them
  # unbound (the RTK gate below reads them).
  local _doc_rtk_hook_present=0
  local _doc_rtk_tracked="false"
  if [ ! -f "$FORGE_STATE_FILE" ]; then
    _doc_warn "state file no encontrado ($FORGE_STATE_FILE) — no instalado"
  elif ! _FORGE_STATE_VIEW="$(_forge_state_view)"; then
    _doc_fail "state file corrupto: $FORGE_STATE_FILE"
  else
    _doc_pass "state file válido"

    local _doc_manifest_count
    _doc_manifest_count="$(_forge_state_query '.targets_manifest // [] | length')"

    _doc_rtk_tracked="$(_forge_state_query '.rtk.tracked // false')"
    local _dt=0
    # shellcheck disable=SC2016  # jq filters are single-quoted on purpose: $i belongs to jq
    while [ "$_dt" -lt "$_doc_manifest_count" ]; do
      local _dtgt_name _dtgt_dir
      _dtgt_name="$(_forge_state_query --argjson i "$_dt" '.targets_manifest[$i].name // "?"')"
      _dtgt_dir="$(_forge_state_query --argjson i "$_dt" '.targets_manifest[$i].dir // ""')"

      echo ""
      echo "  Target: $_dtgt_name ($_dtgt_dir)"

      case "$_dtgt_name" in
        claude)
          # The Claude contract (component-scoped symlinks, settings.json and
          # CLAUDE.md refs) is evaluated inline below, unchanged.
          ;;
        opencode)
          # Same contract as `status`: the manifest decides where to look and
          # the environment only produces a warning when it contradicts it.
          local _doc_cfg _doc_cfg_recorded _doc_msg _doc_hint
          _doc_cfg_recorded="$(_forge_state_query --argjson i "$_dt" '.targets_manifest[$i].config_file // empty')"
          _doc_cfg="$_doc_cfg_recorded"
          [ -n "$_doc_cfg" ] || _doc_cfg="$_dtgt_dir/opencode.jsonc"
          echo "  OpenCode overlay ($_dtgt_dir):"
          _forge_opencode_render doctor "$_dtgt_dir" "$_doc_cfg"
          fail_count=$((fail_count + _FORGE_OPENCODE_FAILURES))
          while IFS='|' read -r _doc_msg _doc_hint; do
            [ -z "$_doc_msg" ] && continue
            _doc_warn "$_doc_msg"
            [ -n "$_doc_hint" ] && echo "  HINT  $_doc_hint"
          done < <(_forge_opencode_env_divergence "$_dtgt_dir" "$_doc_cfg_recorded")
          _dt=$((_dt + 1))
          continue
          ;;
        *)
          _doc_fail "target no soportado: $_dtgt_name (el diagnóstico por target solo admite 'claude' y 'opencode')"
          _dt=$((_dt + 1))
          continue
          ;;
      esac

      # Determine components to check. The diagnostic view already applied the
      # historical fallback for Claude; `components_fallback` tells us whether
      # the warning has to be reproduced.
      local _doc_comp_fallback
      _doc_comp_fallback="$(_forge_state_query --argjson i "$_dt" '.targets_manifest[$i].components_fallback // false')"

      local _doc_ci=0
      local _DOC_COMP_COUNT=0
      if [ "$_doc_comp_fallback" = "true" ]; then
        _doc_warn "no hay campo 'components' en state para $_dtgt_name — verificando lista por defecto"
      fi
      while IFS= read -r _dsc_comp; do
        eval "_DOC_COMP_${_dt}_${_DOC_COMP_COUNT}=\$_dsc_comp"
        _DOC_COMP_COUNT=$((_DOC_COMP_COUNT + 1))
      done < <(_forge_state_query --argjson i "$_dt" '.targets_manifest[$i].components[]')

      # 5a. Symlinks per component
      echo "  Symlinks [$_dtgt_name]:"
      _doc_ci=0
      while [ "$_doc_ci" -lt "$_DOC_COMP_COUNT" ]; do
        local _dcomp
        eval "_dcomp=\${_DOC_COMP_${_dt}_${_doc_ci}}"

        local _dsrc_rel _ddest_rel
        while IFS="	" read -r _dsrc_rel _ddest_rel; do
          local _ddest_abs="${_dtgt_dir}/${_ddest_rel}"
          local _dshort="${_ddest_abs/#$HOME/\~}"
          if [ ! -e "$_ddest_abs" ] && [ ! -L "$_ddest_abs" ]; then
            _doc_fail "symlink BROKEN [$_dcomp]: $_dshort"
          elif [ -L "$_ddest_abs" ]; then
            local _dlnk_target
            _dlnk_target="$(readlink "$_ddest_abs")"
            if [ "${_dlnk_target#"$FORGE_ROOT"}" != "$_dlnk_target" ]; then
              _doc_pass "symlink OK [$_dcomp]: $_dshort"
            else
              _doc_fail "symlink MISMATCH [$_dcomp]: $_dshort -> $_dlnk_target"
            fi
          else
            _doc_fail "symlink MISMATCH [$_dcomp]: $_dshort (no es symlink)"
          fi
        done < <(forge_component_symlinks "$_dcomp" 2>/dev/null || true)

        # Track whether rtk-hook is a recorded component in any target
        if [ "$_dcomp" = "rtk-hook" ]; then
          _doc_rtk_hook_present=1
        fi

        _doc_ci=$((_doc_ci + 1))
      done

      # 6. settings.json per target
      local _dsfile="${_dtgt_dir}/settings.json"
      local _dpre_forge="${_dsfile}.pre-forge"
      echo "  Settings [$_dtgt_name]:"
      if [ ! -f "$_dsfile" ]; then
        _doc_warn "[$_dtgt_name] settings.json no existe"
      elif ! jq empty "$_dsfile" 2>/dev/null; then
        _doc_fail "[$_dtgt_name] settings.json INVÁLIDO (JSON corrupto)"
      else
        _doc_pass "[$_dtgt_name] settings.json válido"

        # Per-component managed key checks
        _doc_ci=0
        while [ "$_doc_ci" -lt "$_DOC_COMP_COUNT" ]; do
          local _dscomp
          eval "_dscomp=\${_DOC_COMP_${_dt}_${_doc_ci}}"

          local _dmanifest_path="$FORGE_ROOT/shared/components/${_dscomp}.json"
          if [ -f "$_dmanifest_path" ]; then
            local _dsk
            _dsk="$(jq -r '.settings_key // empty' "$_dmanifest_path")"
            if [ -n "$_dsk" ] && [ "$_dsk" != "null" ]; then
              local _dtop_key
              _dtop_key="${_dsk%%.*}"
              _dtop_key="${_dtop_key%%\[*}"
              if jq -e --arg k "$_dtop_key" 'has($k)' "$_dsfile" >/dev/null 2>&1; then
                _doc_pass "[$_dscomp] managed key '$_dtop_key' presente en settings.json"
              else
                _doc_fail "[$_dscomp] managed key '$_dtop_key' ausente en settings.json"
              fi
            fi
          fi

          _doc_ci=$((_doc_ci + 1))
        done
      fi
      if [ -f "$_dpre_forge" ]; then
        _doc_pass "[$_dtgt_name] .pre-forge presente (restore disponible)"
      else
        _doc_warn "[$_dtgt_name] .pre-forge ausente (no se puede hacer restore limpio)"
      fi

      # 6b. claude_md_ref per component
      _doc_ci=0
      while [ "$_doc_ci" -lt "$_DOC_COMP_COUNT" ]; do
        local _drefcomp
        eval "_drefcomp=\${_DOC_COMP_${_dt}_${_doc_ci}}"
        local _drmanifest="$FORGE_ROOT/shared/components/${_drefcomp}.json"
        if [ -f "$_drmanifest" ]; then
          local _dref
          _dref="$(jq -r '.claude_md_ref // empty' "$_drmanifest")"
          if [ -n "$_dref" ]; then
            local _dclaude_md="${_dtgt_dir}/CLAUDE.md"
            if [ -f "$_dclaude_md" ] && grep -qF "$_dref" "$_dclaude_md" 2>/dev/null; then
              _doc_pass "[$_drefcomp] $_dref presente en CLAUDE.md"
            else
              _doc_fail "[$_drefcomp] $_dref ausente en CLAUDE.md"
            fi
          fi
        fi
        _doc_ci=$((_doc_ci + 1))
      done

      _dt=$((_dt + 1))
    done
  fi

  # 7. RTK checks — if rtk-hook is a recorded component in any target OR rtk.tracked=true
  if [ "$_doc_rtk_hook_present" -eq 1 ] || [ "${_doc_rtk_tracked:-false}" = "true" ]; then
    echo ""
    echo "  RTK (rtk-hook instalado):"
    if command -v rtk >/dev/null 2>&1; then
      local rtk_v_out
      rtk_v_out="$(rtk --version 2>&1 || true)"
      if printf '%s' "$rtk_v_out" | grep -qE '^rtk +[0-9]+\.[0-9]+\.[0-9]+'; then
        local rtk_ver
        rtk_ver="$(printf '%s' "$rtk_v_out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        local pinned
        pinned="$(cat "$FORGE_ROOT/rtk/VERSION" 2>/dev/null || echo "0.43.0")"
        if [ "$rtk_ver" = "$pinned" ]; then
          _doc_pass "RTK $rtk_ver (== pin $pinned)"
        else
          _doc_warn "RTK $rtk_ver (pin es $pinned — usa 'bash install.sh rtk install' para actualizar)"
        fi
      else
        _doc_fail "RTK binario encontrado pero versión no reconocida (posible colisión con Rust Type Kit)"
      fi
      local rtk_path
      rtk_path="$(command -v rtk)"
      _doc_pass "rtk path: $rtk_path"
    else
      _doc_warn "rtk no encontrado en PATH (no instalado o no en PATH)"
    fi
  fi

  # 8. PATH contains ~/.forge/bin (RTK tarball install location)
  if [ -f "$HOME/.forge/bin/rtk" ]; then
    case ":$PATH:" in
      *":$HOME/.forge/bin:"*)
        ;;
      *)
        # shellcheck disable=SC2088  # tilde is display text, not a path to expand
        _doc_warn "$HOME/.forge/bin no está en PATH — añade $HOME/.forge/bin a tu PATH en ~/.zshrc o ~/.bashrc"
        ;;
    esac
  fi

  echo ""
  echo "  Resumen: FAILs=$fail_count  WARNs=$warn_count"
  echo ""

  if [ "$fail_count" -gt 0 ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# cmd_install — Fase 3 + Fase 4 implementation
# ---------------------------------------------------------------------------

# _forge_clean_target <tgt_dir> [<comp1> <comp2> ...]
# With no component args: legacy "clean all" — removes all symlinks pointing
# to FORGE_ROOT and all *.forge-bak-* files from agents/, commands/ and
# root of tgt_dir. Preserves the existing full-uninstall path.
# With component args: for each named component, derives its symlink
# destinations from forge_component_symlinks <name> (manifest-driven) and
# removes ONLY those files/symlinks from tgt_dir. Leaves all other
# symlinks intact.
_forge_clean_target() {
  local tgt_dir="$1"
  shift
  local cleaned=0

  if [ "$#" -eq 0 ]; then
    # ---------------------------------------------------------------------------
    # Legacy path: no components specified — clean everything we own
    # ---------------------------------------------------------------------------
    local scan_dir
    for scan_dir in "$tgt_dir/agents" "$tgt_dir/commands" "$tgt_dir/skills" "$tgt_dir"; do
      [ -d "$scan_dir" ] || continue
      # Remove symlinks pointing to FORGE_ROOT
      while IFS= read -r -d '' f; do
        local lnk_target
        lnk_target="$(readlink "$f")"
        case "$lnk_target" in
          "$FORGE_ROOT"/*) ;;  # owned by forge — proceed to remove
          *) continue ;;          # not owned, skip
        esac
        [ -L "$f" ] && rm "$f"
        echo "[clean] removed stale symlink: ${f/#$HOME/\~}"
        cleaned=$((cleaned + 1))
      done < <(find "$scan_dir" -maxdepth 1 -type l -print0 2>/dev/null)
      # Remove .forge-bak-* files
      while IFS= read -r -d '' f; do
        rm -f "$f"
        echo "[clean] removed backup: ${f/#$HOME/\~}"
        cleaned=$((cleaned + 1))
      done < <(find "$scan_dir" -maxdepth 1 -name '*.forge-bak-*' -print0 2>/dev/null)
    done
    # Dedicated pass for skills/<name>/ subdirectories (one level deeper than skills/).
    # The loop above with scan_dir="$tgt_dir/skills" only catches direct children of
    # skills/; skill symlinks live at skills/<name>/SKILL.md and
    # skills/<name>/reference/*.md, so we need an explicit per-subdirectory scan.
    local _skill_subdir
    for _skill_subdir in "$tgt_dir"/skills/*/; do
      [ -d "$_skill_subdir" ] || continue
      while IFS= read -r -d '' f; do
        local lnk_target
        lnk_target="$(readlink "$f")"
        case "$lnk_target" in
          "$FORGE_ROOT"/*) ;;  # owned by forge — proceed to remove
          *) continue ;;          # not owned, skip
        esac
        [ -L "$f" ] && rm "$f"
        echo "[clean] removed stale symlink: ${f/#$HOME/\~}"
        cleaned=$((cleaned + 1))
      done < <(find "$_skill_subdir" -maxdepth 1 -type l -print0 2>/dev/null)
    done
  else
    # ---------------------------------------------------------------------------
    # Component-scoped path: remove only the files belonging to each named component
    # ---------------------------------------------------------------------------
    local _comp
    for _comp in "$@"; do
      local _src _dest
      while IFS="	" read -r _src _dest; do
        local _path="$tgt_dir/$_dest"
        if [ -L "$_path" ]; then
          rm "$_path"
          echo "[clean] [$_comp] removed symlink: ${_path/#$HOME/\~}"
          cleaned=$((cleaned + 1))
        elif [ -n "$tgt_dir" ] && [ -f "$_path" ]; then
          rm "$_path"
          echo "[clean] [$_comp] removed file: ${_path/#$HOME/\~}"
          cleaned=$((cleaned + 1))
        fi
      done < <(forge_component_symlinks "$_comp" 2>/dev/null || true)
    done
    # Remove directories left empty after component symlink removal (skills,
    # tools, agents, rules). Directories still holding user files are untouched.
    _forge_sweep_empty_dirs "$tgt_dir"
  fi

  echo "[clean] target $tgt_dir: $cleaned files cleaned"
}

# _forge_install_claude_md <tgt_dir>
# Ensures CLAUDE-shared.md is referenced from CLAUDE.md in the target.
# Appends @CLAUDE-shared.md to existing CLAUDE.md if not already there.
_forge_install_claude_md() {
  local tgt_dir="$1"
  local claude_md="$tgt_dir/CLAUDE.md"

  # Claude target may have user content — append @CLAUDE-shared.md if missing
  if [ ! -f "$claude_md" ]; then
    printf '@CLAUDE-shared.md\n' > "$claude_md"
    echo "[claude-md] created $claude_md with @CLAUDE-shared.md"
  elif ! grep -qF '@CLAUDE-shared.md' "$claude_md"; then
    printf '\n@CLAUDE-shared.md\n' >> "$claude_md"
    echo "[claude-md] appended @CLAUDE-shared.md to $claude_md"
  else
    echo "[claude-md] $claude_md already includes @CLAUDE-shared.md"
  fi
}

cmd_install() {
  # Parse flags
  local target_arg="both"
  local show_cost=0
  local only_csv=""

  for arg in "$@"; do
    case "$arg" in
      --target=*)    target_arg="${arg#--target=}" ;;
      --show-cost)   show_cost=1 ;;
      --only=*)      only_csv="${arg#--only=}" ;;
      *) echo "[forge] WARNING: flag desconocido ignorado: $arg" >&2 ;;
    esac
  done

  # ---------------------------------------------------------------------------
  # Build SELECTED_COMPONENTS (bash 3.2-compatible indexed array via eval)
  # ---------------------------------------------------------------------------
  local _selected_count=0

  if [ -z "$only_csv" ]; then
    # No --only flag: select all default components from the catalog
    # (manifests with "default": false — e.g. core, the plugin companion —
    # are opt-in only via --only=<name>)
    while IFS= read -r _comp; do
      eval "_SELCOMP_${_selected_count}=\$_comp"
      _selected_count=$((_selected_count + 1))
    done < <(forge_components_default_list)
  else
    # Parse CSV and validate each name
    local _full_list_valid=1
    # Split on commas (bash 3.2 compatible via IFS substitution)
    local _old_IFS="$IFS"
    IFS=','
    # shellcheck disable=SC2086  # word splitting is intentional here to split CSV
    set -- $only_csv
    IFS="$_old_IFS"
    for _item in "$@"; do
      # Trim leading/trailing whitespace from each item
      _item="${_item#"${_item%%[! ]*}"}"
      _item="${_item%"${_item##*[! ]}"}"
      if [ -z "$_item" ]; then
        continue
      fi
      # Validate against components catalog
      local _found=0
      while IFS= read -r _known; do
        if [ "$_item" = "$_known" ]; then
          _found=1
          break
        fi
      done < <(forge_components_list)
      if [ "$_found" -eq 0 ]; then
        echo "[forge] ERROR: componente desconocido: '$_item'" >&2
        echo "[forge]   → componentes válidos: $(forge_components_list | tr '\n' ',' | sed 's/,$//')" >&2
        _full_list_valid=0
      else
        eval "_SELCOMP_${_selected_count}=\$_item"
        _selected_count=$((_selected_count + 1))
      fi
    done
    if [ "$_full_list_valid" -eq 0 ]; then
      exit 1
    fi
  fi

  # Restore $@ to original args for any downstream users (safe: nothing below uses $@)

  # ---------------------------------------------------------------------------
  # Mutual-exclusion validation: a selected component must not conflict with
  # another selected component nor with one already installed (state).
  # core ⟷ agents/commands/cost-report overlap on CLAUDE-shared.md, managed
  # settings paths and support-file symlinks (manifest field "conflicts_with").
  # ---------------------------------------------------------------------------
  local _cf_i=0
  while [ "$_cf_i" -lt "$_selected_count" ]; do
    local _cf_a
    eval "_cf_a=\${_SELCOMP_${_cf_i}}"

    # selected × selected
    local _cf_j=$((_cf_i + 1))
    while [ "$_cf_j" -lt "$_selected_count" ]; do
      local _cf_b
      eval "_cf_b=\${_SELCOMP_${_cf_j}}"
      if forge_components_conflict "$_cf_a" "$_cf_b"; then
        echo "[forge] ERROR: componentes excluyentes seleccionados: '$_cf_a' y '$_cf_b'" >&2
        echo "[forge]   → ambos gestionan CLAUDE-shared.md/settings/archivos de soporte; elige solo uno" >&2
        exit 1
      fi
      _cf_j=$((_cf_j + 1))
    done

    # selected × installed (state)
    if [ -f "$FORGE_STATE_FILE" ] && jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
      local _cf_installed
      while IFS= read -r _cf_installed; do
        [ -z "$_cf_installed" ] && continue
        if forge_components_conflict "$_cf_a" "$_cf_installed"; then
          echo "[forge] ERROR: '$_cf_a' es excluyente con el componente ya instalado '$_cf_installed'" >&2
          echo "[forge]   → desinstala primero: bash install.sh uninstall --component=$_cf_installed" >&2
          exit 1
        fi
      done < <(jq -r '[.targets_manifest[]?.components[]?] | unique | .[]' "$FORGE_STATE_FILE" 2>/dev/null)
    fi

    _cf_i=$((_cf_i + 1))
  done

  # Warn if 'commands' selected but 'agents' not selected
  local _has_commands=0 _has_agents=0
  local _sc_idx=0
  while [ "$_sc_idx" -lt "$_selected_count" ]; do
    local _sc_name
    eval "_sc_name=\${_SELCOMP_${_sc_idx}}"
    case "$_sc_name" in
      commands) _has_commands=1 ;;
      agents)   _has_agents=1 ;;
    esac
    _sc_idx=$((_sc_idx + 1))
  done
  if [ "$_has_commands" -eq 1 ] && [ "$_has_agents" -eq 0 ]; then
    echo "[forge] WARN: 'commands' seleccionado sin 'agents' — los comandos requieren agentes para funcionar correctamente" >&2
  fi

  forge_banner

  # Resolve targets
  forge_resolve_targets "$target_arg"

  echo "[forge] targets: $_forge_targets_count"

  # Timestamp for state
  local installed_at
  installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$target_arg" = "opencode" ]; then
    forge_run_opencode_installer || return 1
    forge_write_opencode_only_state "$installed_at" || return 1
    forge_print_summary "install"
    return 0
  fi

  # Accumulate symlinks created (indexed array)
  local symlink_count=0
  # We'll build a JSON array string
  local symlinks_json="["

  # targets_manifest: array of objects, one per target
  local targets_manifest_json="["

  # Symlink lists per target
  local i=0
  while [ "$i" -lt "$_forge_targets_count" ]; do
    local tgt
    tgt="$(forge_target_path "$i")"
    local tgt_name
    tgt_name="$(forge_target_name "$i")"

    echo "[forge] installing symlinks for target: $tgt_name ($tgt)"
    # Build component args for selective cleanup
    local _clean_args _ci
    _clean_args=""
    _ci=0
    while [ "$_ci" -lt "$_selected_count" ]; do
      local _cname
      eval "_cname=\${_SELCOMP_${_ci}}"
      _clean_args="$_clean_args $_cname"
      _ci=$((_ci + 1))
    done
    # shellcheck disable=SC2086  # word-split is intentional: _clean_args is a space-delimited list
    _forge_clean_target "$tgt" $_clean_args

    # ---------------------------------------------------------------------------
    # One-shot legacy cleanup: remove stale commands/*.md symlinks that were
    # created in pre-skills releases (when commands were in commands/, not skills/).
    # Only removes entries that are forge-managed symlinks (pointing into
    # FORGE_ROOT); silently skips absent or non-forge entries. Idempotent.
    # ---------------------------------------------------------------------------
    local _lc_path _lc_target
    for _lc_path in \
        "${tgt}/commands/cost-report.md" \
        "${tgt}/commands/create-plan.md" \
        "${tgt}/commands/execute-plan.md" \
        "${tgt}/commands/pr-description.md" \
        "${tgt}/commands/update-changelog.md"; do
      if [ -L "$_lc_path" ]; then
        _lc_target="$(readlink "$_lc_path")"
        case "$_lc_target" in
          "$FORGE_ROOT"/*)
            rm "$_lc_path"
            echo "[clean] removed legacy commands symlink: ${_lc_path/#$HOME/\~}"
            ;;
        esac
      fi
    done

    # Build relative symlinks list for this target's manifest entry
    local target_rel_symlinks_json="["
    local target_rel_symlinks_objects_json="["
    local target_rel_symlink_count=0

    # Iterate per-component over SELECTED_COMPONENTS (manifest-driven)
    local _comp_i=0
    while [ "$_comp_i" -lt "$_selected_count" ]; do
      local _comp_name
      eval "_comp_name=\${_SELCOMP_${_comp_i}}"

      # Skip opencode targets for all components (no catalog entries apply)
      if [ "$tgt_name" = "opencode" ]; then
        _comp_i=$((_comp_i + 1))
        continue
      fi

      echo "[forge] [$_comp_name] installing symlinks for target: $tgt_name"

      # Install symlinks and target_root_files (forge_component_symlinks emits both)
      local src_rel dest_rel src_abs dest_abs
      while IFS="	" read -r src_rel dest_rel; do
        src_abs="$FORGE_ROOT/$src_rel"
        dest_abs="$tgt/$dest_rel"
        forge_symlink "$src_abs" "$dest_abs"
        [ "$symlink_count" -gt 0 ] && symlinks_json="$symlinks_json,"
        symlinks_json="$symlinks_json\"$dest_abs\""
        symlink_count=$((symlink_count + 1))
        # Accumulate relative symlinks for manifest (legacy flat string array)
        [ "$target_rel_symlink_count" -gt 0 ] && target_rel_symlinks_json="$target_rel_symlinks_json,"
        target_rel_symlinks_json="$target_rel_symlinks_json\"$dest_rel\""
        # Accumulate object-shaped symlinks for manifest (v3: {src, dest})
        [ "$target_rel_symlink_count" -gt 0 ] && target_rel_symlinks_objects_json="$target_rel_symlinks_objects_json,"
        target_rel_symlinks_objects_json="$target_rel_symlinks_objects_json{\"src\":\"$src_rel\",\"dest\":\"$dest_rel\"}"
        target_rel_symlink_count=$((target_rel_symlink_count + 1))
      done < <(forge_component_symlinks "$_comp_name" 2>/dev/null || true)

      # Append claude_md_ref to CLAUDE.md if the component manifest specifies one
      local _claude_md_ref
      _claude_md_ref="$(jq -r '.claude_md_ref // empty' "$FORGE_ROOT/shared/components/${_comp_name}.json" 2>/dev/null || true)"
      if [ -n "$_claude_md_ref" ]; then
        _forge_install_claude_md "$tgt"
      fi

      _comp_i=$((_comp_i + 1))
    done

    target_rel_symlinks_json="$target_rel_symlinks_json]"
    target_rel_symlinks_objects_json="$target_rel_symlinks_objects_json]"

    # Determine settings_backup path for this target (will be finalized after settings merge)
    # Store relative symlinks per target name for manifest construction after settings merge
    # Use eval-based pseudo-map (bash 3.2 compatible)
    eval "_TARGET_MANIFEST_SYMLINKS_${tgt_name}=\$target_rel_symlinks_json"
    eval "_TARGET_MANIFEST_SYMLINKS_OBJECTS_${tgt_name}=\$target_rel_symlinks_objects_json"
    eval "_TARGET_MANIFEST_DIR_${tgt_name}=\$tgt"

    i=$((i + 1))
  done

  symlinks_json="$symlinks_json]"

  # --- Sentinel file .forge-show-cost ---
  # Crea el fichero si --show-cost; lo elimina si no.
  # opencode does not use the statusline sentinel — skip it.
  local sc=0
  while [ "$sc" -lt "$_forge_targets_count" ]; do
    local sc_tgt sc_name
    sc_tgt="$(forge_target_path "$sc")"
    sc_name="$(forge_target_name "$sc")"
    if [ "$sc_name" = "opencode" ]; then
      sc=$((sc + 1))
      continue
    fi
    local sentinel="${sc_tgt}/.forge-show-cost"
    if [ "$show_cost" = "1" ]; then
      touch "$sentinel"
      echo "[forge] statusline coste de sesión activado (${sentinel/#$HOME/\~})"
    else
      rm -f "$sentinel"
      echo "[forge] statusline coste de sesión desactivado (pasa --show-cost para activarlo)"
    fi
    sc=$((sc + 1))
  done

  # Determine targets array JSON for state
  local targets_json="["
  local j=0
  while [ "$j" -lt "$_forge_targets_count" ]; do
    local tname
    tname="$(forge_target_name "$j")"
    [ "$j" -gt 0 ] && targets_json="$targets_json,"
    targets_json="$targets_json\"$tname\""
    j=$((j + 1))
  done
  targets_json="$targets_json]"

  # --- Per-component settings merge ---
  # opencode does not use settings.json — skip for that target.
  # RTK gating: rtk-hook's hook entry is installed via forge_merge_component_settings
  # when rtk-hook is in SELECTED_COMPONENTS; forge_rtk_decide is no longer called.
  local k=0
  while [ "$k" -lt "$_forge_targets_count" ]; do
    local tgt
    tgt="$(forge_target_path "$k")"
    local tgt_name
    tgt_name="$(forge_target_name "$k")"

    if [ "$tgt_name" = "opencode" ]; then
      echo "[forge] skipping settings merge for target: $tgt_name (not applicable)"
      k=$((k + 1))
      continue
    fi

    local target_settings="$tgt/settings.json"

    # Ensure settings.json exists (create {} if absent) and is valid
    mkdir -p "$tgt"
    if [ ! -f "$target_settings" ]; then
      local tmp_empty_s
      tmp_empty_s="$(mktemp)"
      printf '{}' > "$tmp_empty_s"
      mv "$tmp_empty_s" "$target_settings"
      echo "[settings] created $target_settings (was missing)"
    fi
    if ! jq empty "$target_settings" 2>/dev/null; then
      if [ -f "${target_settings}.pre-forge" ]; then
        cp "${target_settings}.pre-forge" "$target_settings"
        echo "[settings] WARN: settings.json corrupto, restaurado desde .pre-forge"
      else
        echo "[settings] ERROR: settings.json corrupto y no hay .pre-forge" >&2
        exit 1
      fi
    fi

    # shellcheck disable=SC2034  # used indirectly via eval below
    local overlay_backup="{}"
    # Persist overlay_backup for state recording
    eval "_OVERLAY_BACKUP_${tgt_name}=\$overlay_backup"

    # Create .pre-forge backup if it doesn't exist yet
    if [ ! -f "${target_settings}.pre-forge" ]; then
      cp "$target_settings" "${target_settings}.pre-forge"
      echo "[settings] backup created: ${target_settings}.pre-forge"
    fi

    echo "[forge] merging settings for target: $tgt_name (per-component)"

    # Iterate selected components and merge each one's settings fragment
    local _ks=0
    while [ "$_ks" -lt "$_selected_count" ]; do
      local _kcomp
      eval "_kcomp=\${_SELCOMP_${_ks}}"
      echo "[forge] [$_kcomp] merging settings into $target_settings"
      forge_merge_component_settings "$_kcomp" "$target_settings" "--target-dir=$tgt"
      _ks=$((_ks + 1))
    done

    # Validate result
    if ! jq empty "$target_settings" 2>/dev/null; then
      echo "[settings] ERROR: settings.json inválido tras merge, restaurando desde .pre-forge" >&2
      if [ -f "${target_settings}.pre-forge" ]; then
        cp "${target_settings}.pre-forge" "$target_settings"
        echo "[settings] restaurado desde .pre-forge" >&2
      fi
    fi

    k=$((k + 1))
  done

  # --- RTK state vars (initialized to empty; rtk-hook hook is installed via component loop above) ---
  _RTK_INSTALLED_BY_US=""
  _RTK_DETECTED_VERSION=""
  _RTK_INSTALL_FAILED=""
  _RTK_VERSION_MISMATCH=""

  # Check if rtk-hook was in SELECTED_COMPONENTS (for informational logging only)
  local _rtk_hook_selected=0
  local _rks=0
  while [ "$_rks" -lt "$_selected_count" ]; do
    local _rk_comp
    eval "_rk_comp=\${_SELCOMP_${_rks}}"
    if [ "$_rk_comp" = "rtk-hook" ]; then
      _rtk_hook_selected=1
      break
    fi
    _rks=$((_rks + 1))
  done

  if [ "$_rtk_hook_selected" -eq 1 ]; then
    echo "[forge] rtk-hook selected: hook entry installed via component settings merge"
  else
    echo "[forge] rtk-hook not selected: skipping RTK hook entry"
  fi

  # --- Write state file ---
  # Build settings section JSON
  # For each target, include overlay_backup and backup path
  local settings_section="{}"

  settings_section="$(jq -n '{"managed_paths": {}, "overlay_backup": {}, "settings_json_backup": {}}')"

  local m=0
  while [ "$m" -lt "$_forge_targets_count" ]; do
    local tgt
    tgt="$(forge_target_path "$m")"
    local tgt_name
    tgt_name="$(forge_target_name "$m")"

    # Retrieve overlay backup stored by forge_install_settings
    # IMPORTANT: do NOT use ${VAR:-{}} in eval — the {} confuses bash brace expansion.
    # Instead retrieve the raw value and default to empty, then check below.
    local overlay_val
    eval "overlay_val=\${_OVERLAY_BACKUP_${tgt_name}:-}"

    # Default to empty JSON object if unset or empty
    if [ -z "$overlay_val" ]; then
      overlay_val="{}"
    fi

    # Ensure overlay_val is valid JSON (restore to {} if somehow corrupt)
    if ! printf '%s' "$overlay_val" | jq empty 2>/dev/null; then
      overlay_val="{}"
    fi

    local pre_forge_path="${tgt}/settings.json.pre-forge"
    local backup_path=""
    [ -f "$pre_forge_path" ] && backup_path="$pre_forge_path"

    # Bug 1 fix (state): if the state file already has overlay_backup for this target
    # (i.e. this is a re-install), preserve the original overlay — do NOT overwrite it.
    # The existing overlay reflects the true PRE-install values from the very first run.
    local existing_overlay="null"
    if [ -f "$FORGE_STATE_FILE" ]; then
      existing_overlay="$(jq -c --arg n "$tgt_name" '.settings.overlay_backup[$n] // null' "$FORGE_STATE_FILE" 2>/dev/null || echo "null")"
    fi

    local final_overlay
    if [ "$existing_overlay" != "null" ] && [ -n "$existing_overlay" ]; then
      final_overlay="$existing_overlay"
    else
      final_overlay="$overlay_val"
    fi

    settings_section="$(echo "$settings_section" | jq \
      --arg name "$tgt_name" \
      --argjson overlay "$final_overlay" \
      --arg bak "$backup_path" \
      '.overlay_backup[$name] = $overlay | .settings_json_backup[$name] = $bak')"

    # Build targets_manifest entry for this target
    local manifest_symlinks_objects_json manifest_dir settings_merged_bool settings_backup_val
    eval "manifest_symlinks_objects_json=\${_TARGET_MANIFEST_SYMLINKS_OBJECTS_${tgt_name}:-[]}"
    eval "manifest_dir=\${_TARGET_MANIFEST_DIR_${tgt_name}:-}"
    settings_merged_bool="true"
    # The OpenCode overlay records the config file it really wrote: it may
    # live outside the overlay directory (OPENCODE_CONFIG). The Claude
    # target has no such field.
    local manifest_config_file=""
    if [ "$tgt_name" = "opencode" ]; then
      manifest_config_file="$FORGE_OPENCODE_CONFIG"
    fi
    local pre_forge_check="${tgt}/settings.json.pre-forge"
    if [ -f "$pre_forge_check" ]; then
      settings_backup_val="$pre_forge_check"
    else
      settings_backup_val=""
    fi

    # Build components JSON array for this target from SELECTED_COMPONENTS (this run only)
    local new_components_json="["
    local _comp_idx=0
    while [ "$_comp_idx" -lt "$_selected_count" ]; do
      local _comp_name_s
      eval "_comp_name_s=\${_SELCOMP_${_comp_idx}}"
      [ "$_comp_idx" -gt 0 ] && new_components_json="$new_components_json,"
      new_components_json="$new_components_json\"$_comp_name_s\""
      _comp_idx=$((_comp_idx + 1))
    done
    new_components_json="$new_components_json]"

    # Union new components with any previously-recorded components for this target.
    # Also union the per-target symlinks/symlinks_objects so sequential partial installs
    # accumulate (e.g. --only=statusline then --only=agents → both recorded).
    local existing_components_json="[]"
    local existing_symlinks_objects_json="[]"
    if [ -f "$FORGE_STATE_FILE" ]; then
      existing_components_json="$(jq -c --arg n "$tgt_name" \
        '(.targets_manifest // []) | map(select(.name == $n)) | .[0].components // []' \
        "$FORGE_STATE_FILE" 2>/dev/null || echo "[]")"
      existing_symlinks_objects_json="$(jq -c --arg n "$tgt_name" \
        '(.targets_manifest // []) | map(select(.name == $n)) | .[0].symlinks_objects // []' \
        "$FORGE_STATE_FILE" 2>/dev/null || echo "[]")"
    fi

    # Compute unioned components (sorted, unique)
    local target_components_json
    target_components_json="$(jq -n \
      --argjson existing "$existing_components_json" \
      --argjson new_comps "$new_components_json" \
      '($existing + $new_comps) | unique | sort')"

    # Compute unioned symlinks_objects (union by dest to avoid duplicates; new entries win for src).
    # New entries are prepended so that unique_by(.dest) keeps the new (real) src over any
    # stale empty-src entry that may have been migrated from v2 state.
    local unioned_symlinks_objects_json
    unioned_symlinks_objects_json="$(jq -n \
      --argjson existing "$existing_symlinks_objects_json" \
      --argjson new_objs "$manifest_symlinks_objects_json" \
      '($new_objs + $existing) | unique_by(.dest)')"

    # Re-sync legacy flat symlinks array from the unioned symlinks_objects (decision #9)
    local unioned_symlinks_flat_json
    unioned_symlinks_flat_json="$(printf '%s' "$unioned_symlinks_objects_json" | jq '[.[].dest]')"

    local manifest_entry
    if [ -n "$settings_backup_val" ]; then
      manifest_entry="$(jq -n \
        --arg name "$tgt_name" \
        --arg dir "$manifest_dir" \
        --arg config_file "$manifest_config_file" \
        --argjson symlinks "$unioned_symlinks_flat_json" \
        --argjson symlinks_objects "$unioned_symlinks_objects_json" \
        --argjson components "$target_components_json" \
        --argjson settings_merged "$settings_merged_bool" \
        --arg settings_backup "$settings_backup_val" \
        '{name: $name, dir: $dir, symlinks: $symlinks, symlinks_objects: $symlinks_objects, "components": $components, settings_merged: $settings_merged, settings_backup: $settings_backup}
         + (if $config_file == "" then {} else {config_file: $config_file} end)')"
    else
      manifest_entry="$(jq -n \
        --arg name "$tgt_name" \
        --arg dir "$manifest_dir" \
        --arg config_file "$manifest_config_file" \
        --argjson symlinks "$unioned_symlinks_flat_json" \
        --argjson symlinks_objects "$unioned_symlinks_objects_json" \
        --argjson components "$target_components_json" \
        --argjson settings_merged "$settings_merged_bool" \
        '{name: $name, dir: $dir, symlinks: $symlinks, symlinks_objects: $symlinks_objects, "components": $components, settings_merged: $settings_merged, settings_backup: null}
         + (if $config_file == "" then {} else {config_file: $config_file} end)')"
    fi

    [ "$m" -gt 0 ] && targets_manifest_json="$targets_manifest_json,"
    targets_manifest_json="$targets_manifest_json$manifest_entry"

    m=$((m + 1))
  done

  targets_manifest_json="$targets_manifest_json]"

  # Write state file atomically
  local tmp_state
  tmp_state="$(mktemp)"
  # If state exists, preserve installed_at from first install
  local final_installed_at="$installed_at"
  if [ -f "$FORGE_STATE_FILE" ]; then
    local existing_at
    existing_at="$(jq -r '.installed_at // empty' "$FORGE_STATE_FILE" 2>/dev/null || true)"
    if [ -n "$existing_at" ]; then
      # Preserve original installed_at — idempotence: don't update timestamp on re-install
      final_installed_at="$existing_at"
    fi
  fi

  # Build RTK state section
  local pinned_version
  pinned_version="$(cat "$FORGE_ROOT/rtk/VERSION" 2>/dev/null || echo "0.43.0")"

  local rtk_installed_by_us_json="false"
  [ "${_RTK_INSTALLED_BY_US:-}" = "true" ] && rtk_installed_by_us_json="true"

  local rtk_install_failed_json="false"
  [ "${_RTK_INSTALL_FAILED:-}" = "1" ] && rtk_install_failed_json="true"

  local rtk_version_mismatch_json="false"
  [ "${_RTK_VERSION_MISMATCH:-}" = "1" ] && rtk_version_mismatch_json="true"

  local rtk_detected_json="null"
  [ -n "${_RTK_DETECTED_VERSION:-}" ] && rtk_detected_json="\"$_RTK_DETECTED_VERSION\""

  local rtk_section
  rtk_section="$(jq -n \
    --arg pinned "$pinned_version" \
    --argjson detected "$rtk_detected_json" \
    --argjson installed_by_us "$rtk_installed_by_us_json" \
    --argjson install_failed "$rtk_install_failed_json" \
    --argjson version_mismatch "$rtk_version_mismatch_json" \
    '{
      pinned_version: $pinned,
      detected_version: $detected,
      installed_by_us: $installed_by_us,
      install_failed: $install_failed,
      version_mismatch: $version_mismatch
    }')"

  jq -n \
    --arg version "$FORGE_VERSION" \
    --arg installed_at "$final_installed_at" \
    --argjson targets "$targets_json" \
    --argjson symlinks "$symlinks_json" \
    --argjson settings "$settings_section" \
    --argjson rtk "$rtk_section" \
    --argjson targets_manifest "$targets_manifest_json" \
    '{
      version: $version,
      installed_at: $installed_at,
      state_schema: 3,
      targets: $targets,
      symlinks: $symlinks,
      targets_manifest: $targets_manifest,
      settings: $settings,
      rtk: $rtk
    }' > "$tmp_state"

  jq empty "$tmp_state" || {
    rm -f "$tmp_state"
    echo "[forge] ERROR: state file inválido, no se escribió" >&2
    return 1
  }
  mv "$tmp_state" "$FORGE_STATE_FILE"
  echo "[forge] state guardado: $FORGE_STATE_FILE"

  case "$target_arg" in
    opencode|both)
      if ! forge_run_opencode_installer; then
        forge_drop_target_from_state opencode
        forge_warn \
          "OpenCode overlay failed; the claude target was installed successfully" \
          "check errors above and re-run: bash install.sh --target=opencode"
        forge_print_summary "install"
        return 1
      fi
      ;;
  esac

  forge_print_summary "install"
}

# ---------------------------------------------------------------------------
# Entry point — parse subcommand and dispatch
# ---------------------------------------------------------------------------
main() {
  local subcmd="${1:-}"

  case "$subcmd" in
    install)
      shift
      cmd_install "$@"
      ;;
    update)
      shift
      cmd_update "$@"
      ;;
    status)
      cmd_status
      ;;
    uninstall)
      shift
      cmd_uninstall "$@"
      ;;
    repair)
      cmd_repair
      ;;
    doctor)
      cmd_doctor
      ;;
    rtk)
      shift
      local rtk_sub="${1:-}"
      case "$rtk_sub" in
        install)
          if command -v forge_rtk_decide >/dev/null 2>&1; then
            forge_rtk_decide
          else
            echo "[forge] ERROR: lib/rtk.sh no disponible" >&2
            exit 1
          fi
          # Persist rtk.tracked=true only when install succeeded (no failure or mismatch).
          if [ "${_RTK_INSTALL_FAILED:-}" != "1" ] && [ "${_RTK_VERSION_MISMATCH:-}" != "1" ]; then
            if [ -f "$FORGE_STATE_FILE" ] && jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
              local _rtk_track_tmp
              _rtk_track_tmp="$(mktemp)"
              jq '.rtk.tracked = true' "$FORGE_STATE_FILE" > "$_rtk_track_tmp"
              # shellcheck disable=SC2015  # intentional A && B || C for atomic write-or-cleanup
              jq empty "$_rtk_track_tmp" && mv "$_rtk_track_tmp" "$FORGE_STATE_FILE" || rm -f "$_rtk_track_tmp"
              echo "[rtk] tracking activado (rtk.tracked=true en state)"
            else
              echo "[rtk] tracking no activado: no hay instalación de forge registrada — ejecuta 'bash install.sh --only=core,statusline' y después repite 'bash install.sh rtk install'"
            fi
          else
            echo "[rtk] tracking no activado (instalación RTK fallida o rechazada)"
          fi
          ;;
        uninstall)
          local rtk_uninstall="$FORGE_ROOT/rtk/uninstall-rtk.sh"
          if [ -f "$rtk_uninstall" ]; then
            bash "$rtk_uninstall"
          else
            echo "[forge] ERROR: rtk/uninstall-rtk.sh no encontrado" >&2
            exit 1
          fi
          # Clear rtk.tracked so update/doctor/status stop engaging the RTK gate.
          if [ -f "$FORGE_STATE_FILE" ] && jq empty "$FORGE_STATE_FILE" 2>/dev/null; then
            local _rtk_untrack_tmp
            _rtk_untrack_tmp="$(mktemp)"
            jq 'if .rtk then .rtk = (.rtk | del(.tracked)) else . end' "$FORGE_STATE_FILE" > "$_rtk_untrack_tmp"
            # shellcheck disable=SC2015  # intentional A && B || C for atomic write-or-cleanup
            jq empty "$_rtk_untrack_tmp" && mv "$_rtk_untrack_tmp" "$FORGE_STATE_FILE" || rm -f "$_rtk_untrack_tmp"
            echo "[rtk] tracking desactivado (rtk.tracked eliminado de state)"
          fi
          ;;
        "")
          echo "Uso: bash install.sh rtk install|uninstall"
          exit 0
          ;;
        *)
          echo "[forge] ERROR: rtk subcomando desconocido: $rtk_sub (usa: install, uninstall)" >&2
          exit 1
          ;;
      esac
      ;;
    version|--version|-v)
      echo "forge v${FORGE_VERSION}"
      exit 0
      ;;
    -h|--help|"")
      forge_usage
      exit 0
      ;;
    *)
      echo "[forge] ERROR: subcomando desconocido: $subcmd" >&2
      echo "Usa: bash install.sh --help" >&2
      exit 1
      ;;
  esac
}

# Guard: only call main when executed directly, not when sourced (e.g. for testing).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
