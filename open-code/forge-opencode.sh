#!/usr/bin/env sh
# forge-opencode — launcher for the Forge OpenCode overlay (OpenCode 2).
#
# Contract:
#   * the overlay location comes from the Forge manifest (the state file),
#     falling back to the environment and then to the default location;
#   * the OpenCode binary is the Forge-managed PINNED build, invoked by
#     ABSOLUTE path (never through the system PATH), so an Omarchy upgrade
#     that reinstalls OpenCode 1 cannot change what Forge runs;
#   * `--standalone` is passed only at positions declared by the pinned CLI;
#     commands without that flag are left unchanged;
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
# flag is rejected instead of being forwarded. Stop at `--`: later arguments
# belong to the command being launched, not to the OpenCode CLI.
forge_has_standalone=no
for forge_arg in "$@"; do
  if [ "$forge_arg" = "--" ]; then
    break
  fi
  case "$forge_arg" in
    --server|--server=*)
      printf 'forge: ERROR: --server no se admite (OpenCode 2 comparte servidor por defecto y romperia el aislamiento)\n' >&2
      printf 'forge: forge-opencode no permite adjuntar a servidores compartidos.\n' >&2
      exit 2
      ;;
    --standalone)
      forge_has_standalone=yes
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

# OpenCode 2.1.4 declares --standalone on specific command leaves, not at a
# universal position. Keep this routing explicit to that grammar: auth/session
# leaves accept it after the leaf name; these root commands accept it after
# their command name. Other commands (including serve, plugin, mcp, debug and
# service) do not declare it and must receive no injected flag.
forge_sub="${1:-}"
forge_leaf="${2:-}"
if [ "$forge_has_standalone" = yes ]; then
  case "$forge_sub/$forge_leaf" in
    auth/--standalone)
      forge_leaf="${3:-}"
      case "$forge_leaf" in
        list|login|logout|export|import|switch)
          shift 3
          set -- auth "$forge_leaf" --standalone "$@"
          ;;
      esac
      ;;
    session/--standalone)
      forge_leaf="${3:-}"
      case "$forge_leaf" in
        list|delete|export|import)
          shift 3
          set -- session "$forge_leaf" --standalone "$@"
          ;;
      esac
      ;;
  esac
fi

if [ "$forge_has_standalone" != yes ]; then
  forge_sub="${1:-}"
  forge_leaf="${2:-}"
  case "$forge_sub" in
    auth)
      case "$forge_leaf" in
        list|login|logout|export|import|switch)
          shift 2
          set -- "$forge_sub" "$forge_leaf" --standalone "$@"
          ;;
      esac
      ;;
    session)
      case "$forge_leaf" in
        list|delete|export|import)
          shift 2
          set -- "$forge_sub" "$forge_leaf" --standalone "$@"
          ;;
      esac
      ;;
    api|models|mini|reload|run|stats)
      shift
      set -- "$forge_sub" --standalone "$@"
      ;;
    '')
      # No subcommand: start the interactive UI with the root-level flag.
      set -- --standalone "$@"
      ;;
    -*)
      # Root-level options only (for example --help/--version) use the root
      # grammar. Preserve their order after the standalone option.
      set -- --standalone "$@"
      ;;
  esac
fi

# OpenCode 2.1.4's `plugin list` can race the managed server's loading of
# config-declared local plugins. Give this command its own disposable service
# and have the Python supervisor poll the real CLI output until it is exact.
# Help paths remain ordinary CLI help and never start a backend.
forge_plugin_help=no
case "${1:-}/${2:-}" in
  plugin/--help|plugin/-h|plugin/list)
    forge_before_end=yes
    for forge_arg in "$@"; do
      [ "$forge_before_end" = yes ] || break
      if [ "$forge_arg" = "--" ]; then
        forge_before_end=no
        continue
      fi
      case "$forge_arg" in
        --help|-h) forge_plugin_help=yes ;;
      esac
    done
    ;;
esac

if [ "${1:-}" = plugin ] && { [ "${2:-}" = list ] || [ "${2:-}" = --help ] || [ "${2:-}" = -h ]; }; then
  if [ "$forge_plugin_help" = yes ] || [ "${2:-}" != list ]; then
    exec "$forge_bin" "$@"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'forge: ERROR: python3 es necesario para aislar y supervisar la enumeracion runtime de plugins\n' >&2
    exit 1
  fi

  forge_runtime_bin="$forge_bin"
  if [ "$forge_runtime_bin" = opencode ]; then
    forge_runtime_bin="$(command -v opencode)"
  fi
  case "$forge_runtime_bin" in
    /*) ;;
    *) forge_runtime_bin="$(CDPATH='' cd -- "$(dirname "$forge_runtime_bin")" && pwd -P)/$(basename "$forge_runtime_bin")" ;;
  esac

  # Detach the supervisor from the caller's process group. Terminals and
  # service managers commonly signal the whole foreground group; if the
  # supervisor shared it, the shell could die before it waited for the
  # supervisor's cleanup and would expose RC=-SIGTERM instead of 143.
  forge_runtime_pid=
  # This handler is invoked indirectly by the INT/TERM traps below.
  # shellcheck disable=SC2329
  forge_runtime_handle_signal() {
    forge_signal="$1"
    trap - INT TERM
    if [ -n "$forge_runtime_pid" ]; then
      kill -s "$forge_signal" "$forge_runtime_pid" 2>/dev/null || true
      set +e
      wait "$forge_runtime_pid"
      set -e
    fi
    case "$forge_signal" in
      INT) exit 130 ;;
      TERM) exit 143 ;;
    esac
  }
  trap 'forge_runtime_handle_signal INT' INT
  trap 'forge_runtime_handle_signal TERM' TERM

  forge_runtime_launch() {
    python3 -c 'import os, sys; os.setsid(); os.execvp("python3", ["python3", *sys.argv[1:]])' \
      "$SCRIPT_DIR/lib/plugin-sync.py" runtime-list \
      --binary "$forge_runtime_bin" \
      --config-dir "$OPENCODE_CONFIG_DIR" \
      --config "$OPENCODE_CONFIG" \
      "$@" &
    forge_runtime_pid=$!
  }

  set +e
  if [ "${FORGE_OPENCODE_PRIVATE_DB:-}" = "1" ]; then
    forge_runtime_launch --database-private -- "$@"
  else
    forge_runtime_launch -- "$@"
  fi
  wait "$forge_runtime_pid"
  forge_runtime_rc=$?
  trap - INT TERM
  set -e
  exit "$forge_runtime_rc"
fi

exec "$forge_bin" "$@"
