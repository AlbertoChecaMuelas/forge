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

: "${OPENCODE_CONFIG_DIR:=$HOME/.config/opencode-forge}"
: "${OPENCODE_CONFIG:=$OPENCODE_CONFIG_DIR/opencode.jsonc}"

export OPENCODE_CONFIG_DIR
export OPENCODE_CONFIG

exec opencode "$@"
