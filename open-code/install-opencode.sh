#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode-forge}"
CONFIG_FILE="${OPENCODE_CONFIG:-$CONFIG_DIR/opencode.jsonc}"
AGENTS_DIR="$CONFIG_DIR/agents"
PLUGINS_DIR="$CONFIG_DIR/plugins"
AGENTS_MD_PATH="$CONFIG_DIR/AGENTS.md"
AUTH_FILE="$HOME/.local/share/opencode/auth.json"
LAUNCHER_DIR="$HOME/.local/bin"
LAUNCHER_PATH="$LAUNCHER_DIR/forge-opencode"

check_auth_file() {
  if [ ! -f "$AUTH_FILE" ]; then
    return 1
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object" and ([keys[]] | length > 0)' "$AUTH_FILE" >/dev/null 2>&1
    return $?
  fi

  python3 - "$AUTH_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)

if not isinstance(data, dict) or not data:
    raise SystemExit(1)
PY
}

check_auth_command_output() {
  local auth_output

  auth_output="$(opencode auth list 2>/dev/null || true)"
  printf '%s\n' "$auth_output" | grep -qE '● |[1-9][0-9]* credentials'
}

if ! command -v opencode >/dev/null 2>&1; then
  echo "[forge-opencode] ERROR: opencode binary not found in PATH" >&2
  exit 1
fi

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

printf '¿Deseas configurar API keys ahora? (s/N) '
read -r configure_keys || true
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

      printf '¿Deseas añadir otra key? (s/N) '
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

mkdir -p "$AGENTS_DIR" "$PLUGINS_DIR" "$LAUNCHER_DIR"

for role in applier senior tech tester orchestrator; do
  ln -sfn "$REPO_ROOT/open-code/agents/${role}.md" "$AGENTS_DIR/${role}.md"
done

ln -sfn "$REPO_ROOT/open-code/plugins/forge-guard.js" "$PLUGINS_DIR/forge-guard.js"
ln -sfn "$REPO_ROOT/open-code/AGENTS.md" "$AGENTS_MD_PATH"

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

chmod +x "$REPO_ROOT/open-code/forge-opencode.sh"
ln -sfn "$REPO_ROOT/open-code/forge-opencode.sh" "$LAUNCHER_PATH"

if [ -f "$REPO_ROOT/open-code/env.sh" ]; then
  # shellcheck disable=SC1091
  . "$REPO_ROOT/open-code/env.sh"
fi

if [ -n "${OPENAI_API_KEY:-}" ] || [ -n "${ANTHROPIC_API_KEY:-}" ] || [ -n "${MINIMAX_API_KEY:-}" ]; then
  echo "[forge-opencode] auth detected from environment or env.sh"
elif check_auth_command_output || check_auth_file; then
  echo "[forge-opencode] auth detected from opencode credentials"
else
  echo "[forge-opencode] ERROR: no usable OpenCode auth found" >&2
  echo "[forge-opencode]   -> run 'opencode auth login' or export OPENAI_API_KEY/ANTHROPIC_API_KEY" >&2
  exit 1
fi

echo "[forge-opencode] installed overlay in ${CONFIG_DIR/#$HOME/\~}"
echo "[forge-opencode] launcher available at ${LAUNCHER_PATH/#$HOME/\~}"
