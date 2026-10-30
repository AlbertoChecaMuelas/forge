#!/usr/bin/env sh
# forge-opencode — launcher for the Forge OpenCode overlay (OpenCode 2).
#
# Contract:
#   * the overlay location and pinned binary come from a valid Forge manifest;
#     missing or invalid state fails closed instead of selecting another CLI;
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

if [ ! -f "$forge_state_file" ]; then
  printf 'forge: ERROR: falta el manifiesto de Forge (%s); no se ejecutara ningun OpenCode sin pin\n' \
    "$forge_state_file" >&2
  printf 'forge: reinstala el overlay con: bash install.sh install --target=opencode\n' >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  printf 'forge: ERROR: python3 es necesario para validar el manifiesto de Forge; no se ejecutara un OpenCode sin pin\n' >&2
  exit 1
fi

forge_manifest_field() {
  python3 - "$forge_state_file" "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as manifest_file:
        state = json.load(manifest_file)
    entries = state.get("targets_manifest") if isinstance(state, dict) else None
    if not isinstance(entries, list):
        raise ValueError("missing targets_manifest array")
    matches = [entry for entry in entries if isinstance(entry, dict) and entry.get("name") == "opencode"]
    if len(matches) != 1:
        raise ValueError("expected exactly one opencode target")
    entry = matches[0]
    field = sys.argv[2]
    value = entry.get(field, "")
    if field in ("dir", "binary") and (not isinstance(value, str) or not value):
        raise ValueError("missing required " + field)
    if field == "config_file" and value is None:
        value = ""
    if not isinstance(value, str) or "\n" in value or "\r" in value:
        raise ValueError("invalid " + field)
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)

print(value)
PY
}

if ! recorded_dir="$(forge_manifest_field dir 2>/dev/null)" \
  || ! recorded_config="$(forge_manifest_field config_file 2>/dev/null)" \
  || ! recorded_binary="$(forge_manifest_field binary 2>/dev/null)"; then
  printf 'forge: ERROR: manifiesto de Forge invalido o incompleto (%s); se requiere el binario pinado del target opencode\n' \
    "$forge_state_file" >&2
  printf 'forge: reinstala el overlay con: bash install.sh install --target=opencode\n' >&2
  exit 1
fi

case "$recorded_dir" in
  /*) ;;
  *)
    printf 'forge: ERROR: la ruta del overlay en el manifiesto no es absoluta: %s\n' \
      "$recorded_dir" >&2
    exit 1
    ;;
esac

case "$recorded_binary" in
  /*) forge_binary="$recorded_binary" ;;
  *)
    printf 'forge: ERROR: la ruta del binario pinado en el manifiesto no es absoluta: %s\n' \
      "$recorded_binary" >&2
    exit 1
    ;;
esac

# The manifest's absolute path is not sufficient proof of a pinned install:
# require npm's .bin entry, its package-owned target as declared by that
# package's own metadata, and the exact package identity/version installed
# under the prefix inferred from that entry.
forge_validate_pinned_binary() {
  python3 - "$1" "2.1.4" <<'PY'
import json
import os
import sys


def fail(message):
    raise ValueError(message)


try:
    binary = os.path.abspath(sys.argv[1])
    version = sys.argv[2]
    binary_name = os.path.basename(binary)
    bin_directory = os.path.dirname(binary)
    node_modules_directory = os.path.dirname(bin_directory)
    if (
        os.path.basename(bin_directory) != ".bin"
        or os.path.basename(node_modules_directory) != "node_modules"
        or not binary_name
    ):
        fail("binary is not under the expected <prefix>/node_modules/.bin/<executable> layout")

    prefix = os.path.dirname(node_modules_directory)
    if not prefix or not os.path.isdir(prefix):
        fail("the registered Forge binary prefix is missing or invalid")

    real_prefix = os.path.realpath(prefix)
    package_dir = os.path.join(node_modules_directory, "@opencode", "cli")
    real_package_dir = os.path.realpath(package_dir)
    real_binary = os.path.realpath(binary)

    def is_within(path, directory):
        try:
            return os.path.commonpath((directory, path)) == directory
        except ValueError:
            return False

    if not is_within(real_package_dir, real_prefix):
        fail("the @opencode/cli package resolves outside the registered prefix")
    if not is_within(real_binary, real_package_dir):
        fail("the registered executable resolves outside the @opencode/cli package")

    def reject_duplicate_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail("the installed package metadata has ambiguous duplicate keys")
            result[key] = value
        return result

    def reject_non_json_constant(constant):
        fail("the installed package metadata contains invalid JSON constant " + constant)

    package_json = os.path.join(real_package_dir, "package.json")
    with open(package_json, encoding="utf-8") as package_file:
        package = json.load(
            package_file,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_non_json_constant,
        )
    if not isinstance(package, dict):
        fail("the installed package metadata is invalid")
    if package.get("name") != "@opencode/cli" or package.get("version") != version:
        fail("installed package identity/version is not @opencode/cli@" + version)

    bin_entries = package.get("bin")
    if not isinstance(bin_entries, dict) or binary_name not in bin_entries:
        fail("the installed package does not declare a bin entry named " + repr(binary_name))
    declared_bin = bin_entries[binary_name]
    if not isinstance(declared_bin, str) or not declared_bin:
        fail("the package bin entry for " + repr(binary_name) + " is invalid")
    if os.path.isabs(declared_bin):
        fail("the package bin entry for " + repr(binary_name) + " must be relative")

    resolved_declared_bin = os.path.realpath(os.path.join(real_package_dir, declared_bin))
    if not is_within(resolved_declared_bin, real_package_dir):
        fail("the package bin entry for " + repr(binary_name) + " resolves outside the package")
    if not os.path.isfile(resolved_declared_bin) or not os.access(resolved_declared_bin, os.X_OK):
        fail("the package bin entry for " + repr(binary_name) + " is missing or not executable")
    if real_binary != resolved_declared_bin:
        fail("the registered executable does not resolve to the package-declared bin entry for " + repr(binary_name))
    if not os.path.isfile(real_binary) or not os.access(real_binary, os.X_OK):
        fail("the registered package executable is missing or not executable")
except (OSError, TypeError, ValueError, json.JSONDecodeError) as error:
    print("forge: ERROR: pinned package accreditation failed: " + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
}

if ! forge_validate_pinned_binary "$forge_binary"; then
  printf 'forge: ERROR: no se pudo acreditar el paquete OpenCode 2.1.4 bajo el prefijo registrado; no se ejecutara el binario\n' >&2
  exit 1
fi

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

export OPENCODE_CONFIG_DIR
export OPENCODE_CONFIG

# Only the absolute binary recorded by the Forge state manifest is eligible.
forge_bin="$forge_binary"

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

if [ ! -x "$forge_bin" ]; then
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
    *)
      # Known CLI subcommands take precedence over a same-named directory.
      # OpenCode's root command also accepts an existing project directory
      # positionally, including relative paths without ./ or ../ prefixes.
      case "$forge_sub" in
        acp|api|debug|mcp|models|mini|pair|plugin|reload|run|serve|service|stats|uninstall|update|upgrade)
          ;;
        *)
          if [ -d "$forge_sub" ]; then
            set -- --standalone "$@"
          fi
          ;;
      esac
      ;;
  esac
fi

# OpenCode 2.1.4's list leaves resolve the shared service by default. Give
# `plugin list` and `mcp list` their own disposable loopback service and private
# service registration; neither leaf accepts an injected --standalone flag.
# Help paths remain ordinary CLI help and never start a backend.
forge_private_list_help=no
case "${1:-}/${2:-}" in
  plugin/list|mcp/list)
    forge_before_end=yes
    for forge_arg in "$@"; do
      [ "$forge_before_end" = yes ] || break
      if [ "$forge_arg" = "--" ]; then
        forge_before_end=no
        continue
      fi
      case "$forge_arg" in
        --help|-h) forge_private_list_help=yes ;;
      esac
    done
    ;;
esac

if { [ "${1:-}" = plugin ] || [ "${1:-}" = mcp ]; } \
  && { [ "${2:-}" = list ] || { [ "${1:-}" = plugin ] && { [ "${2:-}" = --help ] || [ "${2:-}" = -h ]; }; }; }; then
  if [ "$forge_private_list_help" = yes ] || [ "${2:-}" != list ]; then
    exec "$forge_bin" "$@"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf 'forge: ERROR: python3 es necesario para aislar y supervisar la enumeracion runtime\n' >&2
    exit 1
  fi

  forge_runtime_bin="$forge_bin"
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
