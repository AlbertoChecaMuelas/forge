#!/usr/bin/env sh
# forge-opencode — launcher for the Forge OpenCode overlay (OpenCode 2).
#
# Contract:
#   * the overlay location comes from the Forge manifest (the state file),
#     falling back to the environment and then to the default location;
#   * the OpenCode binary is the Forge-managed PINNED build, invoked by
#     ABSOLUTE path (never through the system PATH), so an Omarchy upgrade
#     that reinstalls OpenCode 1 cannot change what Forge runs;
#   * `--standalone` is ALWAYS passed: OpenCode 2 shares a background server
#     by default and that would break the isolation Forge relies on;
#   * `--server` / `--server=<url>` is REJECTED explicitly before OpenCode
#     runs, because attaching to a shared server is exactly what the
#     isolation forbids;
#   * every other argument is forwarded in order and the exit code of
#     OpenCode is preserved.
set -eu

resolve_path() {
  target="$1"

  while [ -L "$target" ]; do
    link_target=$(readlink "$target")
    case "$link_target" in
      /*) target="$link_target" ;;
      *)
        target_dir=$(CDPATH='' cd -- "$(dirname "$target")" && pwd)
        target="$target_dir/$link_target"
        ;;
    esac
  done

  printf '%s\n' "$target"
}

SCRIPT_PATH=$(resolve_path "$0")
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$SCRIPT_PATH")" && pwd)

if [ -f "$SCRIPT_DIR/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/env.sh"
fi

# The overlay location is the one recorded in the forge state file: that is
# where the overlay installer really put the files. The environment is only a
# fallback (a manual overlay, or an installation that predates the manifest).
#
# The values explicitly exported by the user are captured first: only an
# explicit export can contradict the manifest. An unset variable just means
# "use the default", and the default is not a contradiction.
forge_env_dir="${OPENCODE_CONFIG_DIR:-}"
forge_env_config="${OPENCODE_CONFIG:-}"

: "${OPENCODE_CONFIG_DIR:=$HOME/.config/opencode-forge}"
: "${OPENCODE_CONFIG:=$OPENCODE_CONFIG_DIR/opencode.jsonc}"

# The manifest wins over the environment: the launcher must load the very
# config that the overlay installer wrote, otherwise opencode would start
# without the forge overlay. An environment pointing elsewhere is reported
# instead of being silently obeyed.
forge_state_file="$HOME/.forge-state.json"
forge_binary=""

if [ -f "$forge_state_file" ] && command -v jq >/dev/null 2>&1; then
  recorded_dir="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.dir // empty)' "$forge_state_file" 2>/dev/null || true)"
  recorded_config="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.config_file // empty)' "$forge_state_file" 2>/dev/null || true)"
  recorded_binary="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.binary // empty)' "$forge_state_file" 2>/dev/null || true)"

  if [ -n "$recorded_dir" ]; then
    if [ -n "$forge_env_dir" ] && [ "$forge_env_dir" != "$recorded_dir" ]; then
      printf 'forge: OPENCODE_CONFIG_DIR=%s no coincide con el overlay instalado en %s; se usa el instalado\n' \
        "$forge_env_dir" "$recorded_dir" >&2
    fi
    OPENCODE_CONFIG_DIR="$recorded_dir"

    if [ -n "$recorded_config" ]; then
      if [ -n "$forge_env_config" ] && [ "$forge_env_config" != "$recorded_config" ]; then
        printf 'forge: OPENCODE_CONFIG=%s no coincide con la config instalada en %s; se usa la instalada\n' \
          "$forge_env_config" "$recorded_config" >&2
      fi
      OPENCODE_CONFIG="$recorded_config"
    elif [ "$(dirname "$OPENCODE_CONFIG")" != "$recorded_dir" ]; then
      # Legacy state without a recorded config file: the environment is only
      # kept when it points inside the installed overlay directory.
      OPENCODE_CONFIG="$recorded_dir/opencode.jsonc"
    fi
  fi

  if [ -n "$recorded_binary" ]; then
    forge_binary="$recorded_binary"
  fi
fi

export OPENCODE_CONFIG_DIR
export OPENCODE_CONFIG

# Binary resolution, in order of precedence:
#   1. FORGE_OPENCODE_BIN  — explicit override (used by the test suite).
#   2. the pinned binary recorded in the manifest.
#   3. `opencode` from the PATH — legacy overlay installed before Forge
#      managed its own pinned build.
forge_bin="${FORGE_OPENCODE_BIN:-}"
if [ -z "$forge_bin" ]; then
  forge_bin="$forge_binary"
fi
if [ -z "$forge_bin" ]; then
  forge_bin="opencode"
fi

# A shared server would break the isolation this launcher guarantees, so the
# flag is rejected instead of being forwarded.
for forge_arg in "$@"; do
  case "$forge_arg" in
    --server|--server=*)
      printf 'forge: ERROR: --server no se admite (OpenCode 2 comparte servidor por defecto y romperia el aislamiento)\n' >&2
      printf 'forge: forge-opencode siempre arranca con --standalone (servidor privado).\n' >&2
      exit 2
      ;;
  esac
done

if [ "$forge_bin" = "opencode" ]; then
  if ! command -v opencode >/dev/null 2>&1; then
    printf 'forge: ERROR: no se encontro el binario de OpenCode (instala el overlay con: bash install.sh install --target=opencode)\n' >&2
    exit 1
  fi
elif [ ! -x "$forge_bin" ]; then
  printf 'forge: ERROR: el binario pinado de OpenCode no es ejecutable: %s\n' "$forge_bin" >&2
  printf 'forge: reinstala el overlay con: bash install.sh install --target=opencode\n' >&2
  exit 1
fi

# `--standalone` asks OpenCode 2 for a private server instead of the shared
# background service. The CLI only accepts it AFTER the subcommand, and a few
# leaf subcommands do not offer it at all (they print their help and do
# nothing when it is present): `plugin`, `mcp`, `debug` and `service`. Those
# commands run inside the CLI process and never attach to the shared server,
# so the launcher does not add the flag for them.
forge_sub="${1:-}"
case "$forge_sub" in
  plugin|mcp|debug|service)
    # No flag: these leaf subcommands do not offer it.
    ;;
  *)
    if [ -z "$forge_sub" ] || [ "${forge_sub#-}" != "$forge_sub" ]; then
      # No subcommand (interactive session) or only flags: the flag goes first.
      set -- --standalone "$@"
    else
      # Subcommand: the flag goes right after it.
      forge_sub_name="$forge_sub"
      shift
      set -- "$forge_sub_name" --standalone "$@"
    fi
    ;;
esac

exec "$forge_bin" "$@"
