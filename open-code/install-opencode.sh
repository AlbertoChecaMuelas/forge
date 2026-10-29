#!/usr/bin/env bash
# install-opencode.sh — installs the Forge OpenCode 2 overlay.
#
# What it does:
#   1. installs the PINNED OpenCode build (@opencode/cli@2.1.4) into an
#      ISOLATED Forge-owned prefix (never globally, never through Omarchy),
#   2. copies the generated agents, the commands and AGENTS.md into the
#      overlay directory,
#   3. installs the declared plugin packages (OpenCode 2 plugin layout),
#   4. writes the installed opencode.jsonc and verifies the plugin tree,
#   5. links the `forge-opencode` launcher,
#   6. validates the stored auth entries with the OpenCode 2 JSON contract.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode-forge}"
CONFIG_FILE="${OPENCODE_CONFIG:-$CONFIG_DIR/opencode.jsonc}"
# Relative paths inside the config (e.g. "./plugin-packages/forge-guard")
# resolve against the directory that holds the config file, so that is where
# the overlay files must land.
CONFIG_ROOT_DIR="$(dirname "$CONFIG_FILE")"
AGENTS_DIR="$CONFIG_DIR/agents"
COMMANDS_DIR="$CONFIG_DIR/commands"
AGENTS_MD_PATH="$CONFIG_DIR/AGENTS.md"
LAUNCHER_DIR="$HOME/.local/bin"
LAUNCHER_PATH="$LAUNCHER_DIR/forge-opencode"

# The pinned OpenCode build lives in a Forge-owned, isolated prefix: Forge
# never depends on the OpenCode binary that happens to be in the PATH (an
# Omarchy upgrade may reinstall OpenCode 1 there) and never touches the
# system installation.
OPENCODE_VERSION="2.1.4"
OPENCODE_PACKAGE="@opencode/cli@${OPENCODE_VERSION}"
FORGE_BIN_DIR="${FORGE_OPENCODE_BIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/forge/opencode-v2}"
FORGE_BIN="$FORGE_BIN_DIR/node_modules/.bin/opencode"

# This narrow mode must exit before the full installer can prompt for keys,
# install the pinned binary, or write any other part of the overlay.
command_only_error() {
  printf '[forge-opencode] ERROR: %s\n' "$1" >&2
  exit 1
}

install_command_only() {
  if (($# != 1)); then
    command_only_error 'usage: bash open-code/install-opencode.sh --command-only execute-plan'
  fi
  if [[ "$1" != "execute-plan" ]]; then
    command_only_error "unsupported command '$1'; only 'execute-plan' is allowed"
  fi

  local source="$REPO_ROOT/open-code/commands/execute-plan.md"
  local destination="$COMMANDS_DIR/execute-plan.md"
  local temporary

  if [[ ! -d "$CONFIG_DIR" || ! -d "$COMMANDS_DIR" ]]; then
    command_only_error "the existing Forge overlay and commands directory are required: $COMMANDS_DIR"
  fi
  if ! python3 - "$CONFIG_DIR" "$COMMANDS_DIR" <<'PY'
import os
import sys


def fail(message):
    raise ValueError(message)


config_dir, commands_dir = sys.argv[1:]
normalized = [os.path.abspath(path) for path in (config_dir, commands_dir)]
if os.path.dirname(normalized[1]) != normalized[0] or os.path.basename(normalized[1]) != "commands":
    fail("commands directory is not the expected child of the Forge overlay")

for supplied, path in zip((config_dir, commands_dir), normalized[:2]):
    if os.path.realpath(supplied) != path:
        fail("destination path or one of its ancestors resolves through a symbolic link")
    current = os.path.sep
    for component in path.split(os.path.sep):
        if not component:
            continue
        current = os.path.join(current, component)
        if os.path.islink(current):
            fail("destination path or one of its ancestors is a symbolic link")
    if not os.path.isdir(path):
        fail("destination path is not an existing directory")
PY
  then
    command_only_error 'the complete Forge overlay destination path must be physical and contain no symbolic-link ancestors'
  fi
  if [[ ! -f "$source" || -L "$source" ]]; then
    command_only_error "command source is missing or not a regular file: $source"
  fi
  if [[ -L "$destination" ]]; then
    command_only_error "refusing to replace symbolic-link destination: $destination"
  fi
  if [[ ! -f "$destination" ]]; then
    command_only_error "command destination must already exist as a regular file: $destination"
  fi

  if ! temporary=$(mktemp "$COMMANDS_DIR/.execute-plan.md.tmp.XXXXXX"); then
    command_only_error "could not create a temporary file in $COMMANDS_DIR"
  fi
  if ! cp -- "$source" "$temporary"; then
    rm -f -- "$temporary" || true
    command_only_error "could not copy command source to temporary file: $source"
  fi
  if ! chmod --reference="$destination" "$temporary"; then
    rm -f -- "$temporary" || true
    command_only_error "could not preserve destination permissions: $destination"
  fi
  if ! mv -fT -- "$temporary" "$destination"; then
    rm -f -- "$temporary" || true
    command_only_error "could not atomically replace command destination: $destination"
  fi

  printf '[forge-opencode] updated execute-plan command in %s (permissions preserved)\n' "$COMMANDS_DIR"
}

# Parse the complete argument vector before the full installer can prompt,
# generate files, invoke npm, or write to the overlay. The full installer has
# no positional arguments; its only supported option is the exact, narrow
# command-only form.
command_only_requested=no
for installer_arg in "$@"; do
  case "$installer_arg" in
    --command-only) command_only_requested=yes ;;
    --command-only*)
      command_only_error 'invalid command-only option; use --command-only execute-plan'
      ;;
    --*)
      command_only_error "unrecognized installer option '$installer_arg'"
      ;;
  esac
done

if [ "$command_only_requested" = yes ]; then
  if [[ "${1-}" != "--command-only" ]]; then
    command_only_error 'usage: bash open-code/install-opencode.sh --command-only execute-plan'
  fi
  if (($# != 2)); then
    command_only_error 'usage: bash open-code/install-opencode.sh --command-only execute-plan'
  fi
  install_command_only "$2"
  exit 0
fi

if (($# != 0)); then
  command_only_error 'unexpected arguments; the full installer accepts no arguments'
fi

# check_auth_list validates the stored auth entries with the OpenCode 2 JSON
# contract: `auth list --standalone --format json` must print a JSON array
# with at least one entry.
check_auth_list() {
  local auth_output

  auth_output="$("$FORGE_BIN" auth list --standalone --format json 2>/dev/null || true)"

  printf '%s' "$auth_output" | python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    raise SystemExit(1)
if not isinstance(data, list):
    raise SystemExit(1)
raise SystemExit(0 if len(data) > 0 else 1)
'
}

install_pinned_opencode() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "[forge-opencode] ERROR: npm no esta en PATH; hace falta para instalar $OPENCODE_PACKAGE" >&2
    return 1
  fi

  mkdir -p "$FORGE_BIN_DIR"
  echo "[forge-opencode] instalando $OPENCODE_PACKAGE en ${FORGE_BIN_DIR/#$HOME/\~}"
  npm install --prefix "$FORGE_BIN_DIR" "$OPENCODE_PACKAGE" >/dev/null

  if [ ! -x "$FORGE_BIN" ]; then
    echo "[forge-opencode] ERROR: el binario pinado no aparece en $FORGE_BIN" >&2
    return 1
  fi

  local installed_version
  installed_version="$("$FORGE_BIN" --version 2>/dev/null | tr -d ' \n' || true)"
  if [ "$installed_version" != "opencodev${OPENCODE_VERSION}" ]; then
    echo "[forge-opencode] ERROR: version inesperada del binario pinado: ${installed_version:-desconocida} (se esperaba $OPENCODE_VERSION)" >&2
    return 1
  fi
}

# ----- API key setup (interactive, optional) -----

TOKENS_FILE="$HOME/.opencode-tokens"

write_token() {
  local key="$1"
  local value="$2"

  if [ ! -f "$TOKENS_FILE" ]; then
    install -m 600 /dev/null "$TOKENS_FILE"
  fi

  if grep -q "^${key}=" "$TOKENS_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$TOKENS_FILE"
  else
    printf '%s=%s\n' "$key" "$value" >> "$TOKENS_FILE"
  fi
}

# Only prompt when stdin is a terminal. With a pipe or a heredoc the read
# does not fail, it swallows a line of whatever the caller piped in, so the
# installer would silently eat the input of whoever invoked it.
configure_keys=""
if [ -t 0 ]; then
  printf '¿Deseas configurar API keys ahora? (s/N) '
  read -r configure_keys || true
fi
configure_keys="${configure_keys:-N}"

case "$configure_keys" in
  s|S|y|Y|yes|Yes|YES)
    while true; do
      echo ""
      echo "¿Qué API key deseas añadir?"
      echo "1) MINIMAX_API_KEY"
      echo "2) OPENAI_API_KEY"
      echo "3) ANTHROPIC_API_KEY"
      printf "Opción: "
      read -r key_choice || true

      case "$key_choice" in
        1) selected_key="MINIMAX_API_KEY" ;;
        2) selected_key="OPENAI_API_KEY" ;;
        3) selected_key="ANTHROPIC_API_KEY" ;;
        *)
          echo "Opción no válida, saliendo del configurador de keys."
          break
          ;;
      esac

      printf "Introduce el valor de %s: " "$selected_key"
      read -rs key_value || true
      echo ""

      if [ -n "$key_value" ]; then
        write_token "$selected_key" "$key_value"
        echo "Key guardada."
      else
        echo "Valor vacío, key no guardada."
      fi

      printf "¿Deseas añadir otra key? (s/N) "
      read -r add_another || true
      add_another="${add_another:-N}"

      case "$add_another" in
        s|S|y|Y|yes|Yes|YES) ;;
        *) break ;;
      esac
    done
    ;;
esac

# ----- end API key setup -----

bash "$REPO_ROOT/shared/scripts/generate-agents.sh" --target=opencode

install_pinned_opencode

mkdir -p "$AGENTS_DIR" "$COMMANDS_DIR" "$LAUNCHER_DIR"

for role in applier senior tech tester orchestrator; do
  dest="$AGENTS_DIR/${role}.md"
  [ -L "$dest" ] && rm "$dest"
  cp "$REPO_ROOT/open-code/agents/${role}.md" "$dest"
done

for cmd in create-plan execute-plan review create-pr pr-description update-changelog; do
  dest="$COMMANDS_DIR/${cmd}.md"
  [ -L "$dest" ] && rm "$dest"
  cp "$REPO_ROOT/open-code/commands/${cmd}.md" "$dest"
done

# Plugins are derived from the `plugins` field of the source config instead of
# being hardcoded here: a plugin declared in the config but missing on disk
# disables its feature silently, so the list is never duplicated. OpenCode 2
# plugin packages are directories, so the whole tree is installed.
python3 "$SCRIPT_DIR/lib/plugin-sync.py" sync \
  --config "$REPO_ROOT/open-code/opencode.jsonc" \
  --source-root "$REPO_ROOT/open-code" \
  --target-root "$CONFIG_ROOT_DIR"

[ -L "$AGENTS_MD_PATH" ] && rm "$AGENTS_MD_PATH"
cp "$REPO_ROOT/open-code/AGENTS.md" "$AGENTS_MD_PATH"

mkdir -p "$(dirname "$CONFIG_FILE")"

python3 - "$REPO_ROOT/open-code/opencode.jsonc" "$CONFIG_FILE" "$AGENTS_MD_PATH" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
agents_md = pathlib.Path(sys.argv[3]).resolve()

content = src.read_text(encoding="utf-8")
content = content.replace("__FORGE_OPENCODE_AGENTS_MD__", str(agents_md))
dst.write_text(content, encoding="utf-8")
PY

# The installed config must never reference a plugin that is not on disk:
# OpenCode does not report the failure, so the overlay would be silently
# incomplete. Verify the installed config against the installed files.
python3 "$SCRIPT_DIR/lib/plugin-sync.py" verify \
  --config "$CONFIG_FILE" \
  --source-root "$REPO_ROOT/open-code"

chmod +x "$REPO_ROOT/open-code/forge-opencode.sh"
# Launcher stays a symlink: it runs in the user shell and exec's opencode before any
# sandboxed session exists, so it never triggers the external-directory prompt; the
# symlink is required so resolve_path() can locate env.sh in the repo and load API keys.
ln -sfn "$REPO_ROOT/open-code/forge-opencode.sh" "$LAUNCHER_PATH"

if [ -f "$REPO_ROOT/open-code/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$REPO_ROOT/open-code/env.sh"
fi

if [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[forge-opencode] auth detected from environment or env.sh"
elif check_auth_list; then
  echo "[forge-opencode] auth detected from the Forge-pinned OpenCode 2 auth list"
else
  echo "[forge-opencode] ERROR: no usable OpenCode auth found" >&2
  echo "[forge-opencode]   -> run 'forge-opencode auth login' or export OPENAI_API_KEY/ANTHROPIC_API_KEY" >&2
  exit 1
fi

echo "[forge-opencode] installed overlay in ${CONFIG_DIR/#$HOME/\~}"
echo "[forge-opencode] pinned binary: ${FORGE_BIN/#$HOME/\~} ($OPENCODE_PACKAGE)"
echo "[forge-opencode] launcher available at ${LAUNCHER_PATH/#$HOME/\~}"
