#!/usr/bin/env sh
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
if [ -f "$forge_state_file" ] && command -v jq >/dev/null 2>&1; then
  recorded_dir="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.dir // empty)' "$forge_state_file" 2>/dev/null || true)"
  recorded_config="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.config_file // empty)' "$forge_state_file" 2>/dev/null || true)"

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
fi

export OPENCODE_CONFIG_DIR
export OPENCODE_CONFIG

exec opencode "$@"
