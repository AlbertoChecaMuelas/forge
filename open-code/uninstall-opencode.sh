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
# The root installer passes every path explicitly from the Forge state file:
#
#   --config-dir <overlay directory>
#   --config-file <installed config file>
#   --bin-dir <pinned binary prefix>
#
# Those arguments always win over the environment. The legacy no-argument
# mode remains available for the low-level standalone helper and still honours
# OPENCODE_CONFIG_DIR / OPENCODE_CONFIG / FORGE_OPENCODE_BIN_DIR; the
# state-authoritative `install.sh uninstall` path never uses that fallback.
#
# The containers Forge created (agents/, commands/, plugin-packages/) are
# removed as well, but only when they end up empty: a container that still
# holds something of the user's is kept and reported.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_LAUNCHER="$SCRIPT_DIR/forge-opencode.sh"
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode-forge}"
CONFIG_FILE="${OPENCODE_CONFIG:-$CONFIG_DIR/opencode.jsonc}"
FORGE_BIN_DIR="${FORGE_OPENCODE_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/forge/opencode-v2}"
RESIDUE_STATUS_FILE=""
CONFIG_DIR_SET=0
CONFIG_FILE_SET=0

forge_uninstall_usage() {
  cat <<EOF
Usage: uninstall-opencode.sh [options]

Options:
  --config-dir <path>    Overlay directory to remove
  --config-file <path>   Installed config file to remove
  --bin-dir <path>       Pinned OpenCode binary prefix to remove
  --status-file <path>   Write surviving user files to this status file
  -h, --help             Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config-dir)
      [ "$#" -ge 2 ] || { echo "[forge-opencode] ERROR: --config-dir requiere una ruta" >&2; forge_uninstall_usage >&2; exit 2; }
      CONFIG_DIR="$2"
      CONFIG_DIR_SET=1
      shift 2
      ;;
    --config-dir=*)
      CONFIG_DIR="${1#--config-dir=}"
      CONFIG_DIR_SET=1
      shift
      ;;
    --config-file)
      [ "$#" -ge 2 ] || { echo "[forge-opencode] ERROR: --config-file requiere una ruta" >&2; forge_uninstall_usage >&2; exit 2; }
      CONFIG_FILE="$2"
      CONFIG_FILE_SET=1
      shift 2
      ;;
    --config-file=*)
      CONFIG_FILE="${1#--config-file=}"
      CONFIG_FILE_SET=1
      shift
      ;;
    --bin-dir)
      [ "$#" -ge 2 ] || { echo "[forge-opencode] ERROR: --bin-dir requiere una ruta" >&2; forge_uninstall_usage >&2; exit 2; }
      FORGE_BIN_DIR="$2"
      shift 2
      ;;
    --bin-dir=*)
      FORGE_BIN_DIR="${1#--bin-dir=}"
      shift
      ;;
    --status-file)
      [ "$#" -ge 2 ] || { echo "[forge-opencode] ERROR: --status-file requiere una ruta" >&2; forge_uninstall_usage >&2; exit 2; }
      RESIDUE_STATUS_FILE="$2"
      shift 2
      ;;
    --status-file=*)
      RESIDUE_STATUS_FILE="${1#--status-file=}"
      shift
      ;;
    -h|--help)
      forge_uninstall_usage
      exit 0
      ;;
    *)
      echo "[forge-opencode] ERROR: opción desconocida: $1" >&2
      forge_uninstall_usage >&2
      exit 2
      ;;
  esac
done

if [ "$CONFIG_DIR_SET" -eq 1 ] && [ "$CONFIG_FILE_SET" -eq 0 ]; then
  CONFIG_FILE="$CONFIG_DIR/opencode.jsonc"
fi

AGENTS_DIR="$CONFIG_DIR/agents"
COMMANDS_DIR="$CONFIG_DIR/commands"
LAUNCHER_PATH="$HOME/.local/bin/forge-opencode"

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
# Omarchy or the user installed) is never touched. The prefix must have been
# supplied explicitly and must be a safe absolute path; an absent or invalid
# value fails closed instead of guessing a directory to delete.
case "$FORGE_BIN_DIR" in
  /*)
    if [ "$FORGE_BIN_DIR" != "/" ]; then
      if [ -d "$FORGE_BIN_DIR" ]; then
        rm -rf "$FORGE_BIN_DIR"
        echo "[forge-opencode] removed pinned binary prefix: ${FORGE_BIN_DIR/#$HOME/\~}"
      fi
    else
      echo "[forge-opencode] WARN: prefijo binario no seguro; no se ha borrado ningún prefijo" >&2
    fi
    ;;
  "")
    echo "[forge-opencode] WARN: no se ha indicado un prefijo binario; no se ha borrado ningún prefijo" >&2
    ;;
  *)
    echo "[forge-opencode] WARN: el prefijo binario no es una ruta absoluta; no se ha borrado ningún prefijo" >&2
    ;;
esac

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

# forge_residue_entries <dir> — print the entries that survive under <dir>.
forge_residue_entries() {
  local dir="$1"

  find "$dir" -mindepth 1 2>/dev/null | sort
}

# forge_list_residue <dir> — print the entries that survive under <dir>.
forge_list_residue() {
  local dir="$1"
  local entry

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '  - %s\n' "${entry#"$dir/"}"
  done < <(forge_residue_entries "$dir")
}

forge_remove_empty_dir "$AGENTS_DIR" || true
forge_remove_empty_dir "$COMMANDS_DIR" || true

if forge_remove_empty_dir "$CONFIG_DIR"; then
  echo "[forge-opencode] uninstall completed for ${CONFIG_DIR/#$HOME/\~}"
else
  echo "[forge-opencode] WARN: no se ha podido borrar el overlay ${CONFIG_DIR/#$HOME/\~}: conserva estos ficheros tuyos" >&2
  forge_list_residue "$CONFIG_DIR" >&2
  echo "[forge-opencode]   → forge no borra ficheros ajenos: revisa y borra ${CONFIG_DIR/#$HOME/\~} manualmente cuando ya no lo necesites" >&2

  # The root installer uses this status file to make its final summary
  # honest: user files survived, so the summary must not say "Todo OK".
  if [ -n "$RESIDUE_STATUS_FILE" ]; then
    {
      printf 'dir=%s\n' "$CONFIG_DIR"
      while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        printf 'file=%s\n' "${entry#"$CONFIG_DIR/"}"
      done < <(forge_residue_entries "$CONFIG_DIR")
    } > "$RESIDUE_STATUS_FILE" || {
      echo "[forge-opencode] ERROR: no se ha podido registrar los restos del overlay" >&2
      exit 1
    }
  fi
fi
