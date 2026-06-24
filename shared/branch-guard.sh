#!/usr/bin/env bash
# branch-guard.sh — Dual branch-guard mechanism.
# Runs as a PreToolUse hook:
#  1. BLOCKs git commit on protected branches (master/main/dev) — exit 2.
#  2. Warns when HEAD is already merged in origin/default — exit 0.
# See README.md § "Branch guard" for the full description.
set -u

# ---------------------------------------------------------------------------
# Read PreToolUse JSON payload from stdin (fail-open on any parse error)
# ---------------------------------------------------------------------------
stdin_payload=""
if read -r -t 2 stdin_payload 2>/dev/null; then
  : # read first line; for multi-line JSON concatenate remainder
  remainder=""
  while IFS= read -r -t 0.1 line 2>/dev/null; do
    remainder="${remainder}${line}"
  done
  stdin_payload="${stdin_payload}${remainder}"
fi

# ---------------------------------------------------------------------------
# Kill-switch: if set, exit immediately (no checks at all)
# ---------------------------------------------------------------------------
if [ -n "${FORGE_BRANCH_GUARD_DISABLE:-}" ]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Fast-path: skip commit-guard entirely for non-git commands
# ---------------------------------------------------------------------------
_skip_commit_guard=""
if ! printf '%s' "$stdin_payload" | grep -q '"command"[^"]*git'; then
  _skip_commit_guard=1
fi

if [ -z "${_skip_commit_guard:-}" ]; then
# ---------------------------------------------------------------------------
# Extract tool name and command from JSON payload
# ---------------------------------------------------------------------------
tool_name=""
tool_command=""

if [ -n "$stdin_payload" ]; then
  if command -v jq >/dev/null 2>&1; then
    # Use jq — handle both payload schemas defensively
    parsed_tool=$(printf '%s' "$stdin_payload" | jq -r '
      if .tool_name then .tool_name
      elif .tool then .tool
      else ""
      end
    ' 2>/dev/null) && tool_name="$parsed_tool"

    parsed_cmd=$(printf '%s' "$stdin_payload" | jq -r '
      if .tool_input.command then .tool_input.command
      elif .input.command then .input.command
      else ""
      end
    ' 2>/dev/null) && tool_command="$parsed_cmd"
  else
    # Grep-based fallback (no jq available)
    tool_name=$(printf '%s' "$stdin_payload" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if [ -z "$tool_name" ]; then
      tool_name=$(printf '%s' "$stdin_payload" | grep -o '"tool"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tool"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    tool_command=$(printf '%s' "$stdin_payload" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  fi
else
  # No stdin or read timed out — could be a non-streaming hook invocation; fail-open
  printf '[branch-guard] WARN: empty or unreadable stdin; skipping protected-branch check\n' >&2
  exit 0
fi

# Guard against completely malformed payload (neither schema produced a tool name)
if [ -z "$tool_name" ] && [ -n "$stdin_payload" ]; then
  printf '[branch-guard] WARN: cannot parse tool name from stdin payload; skipping protected-branch check\n' >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Filter: only inspect Bash tool calls
# ---------------------------------------------------------------------------
if [ "$tool_name" != "Bash" ]; then
  # Not a Bash call — skip commit guard, fall through to already-merged warning below
  tool_command=""
fi

# ---------------------------------------------------------------------------
# Commit guard: block git commit on protected branches
# ---------------------------------------------------------------------------
if [ -n "$tool_command" ] && printf '%s' "$tool_command" | grep -qE '(^|[[:space:]])git[[:space:]]+([^[:space:]]+[[:space:]])*commit([[:space:]]|-|$)'; then
  current_branch_commit=$(git symbolic-ref --short HEAD 2>/dev/null) || true
  if [ -z "$current_branch_commit" ]; then
    printf '[branch-guard] WARN: cannot determine branch (detached HEAD or no repo); skipping protected-branch check\n' >&2
    exit 0
  fi
  case "$current_branch_commit" in
    master|main|dev)
      printf '[branch-guard] BLOCKED: commit attempt on protected branch '\''%s'\''. Create a feature branch first (branch guard).\n' \
        "$current_branch_commit" >&2
      exit 2
      ;;
  esac
fi

fi # end _skip_commit_guard

# ---------------------------------------------------------------------------
# Already-merged warning (preserved original logic)
# ---------------------------------------------------------------------------

# Resolver repo root; si falla (no es un repo git), salir silenciosamente
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Resolver default branch
default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || true)
if [ -z "$default_branch" ]; then
  default_branch=$(git config init.defaultBranch 2>/dev/null || true)
fi
if [ -z "$default_branch" ]; then
  default_branch="master"
fi

# Obtener rama actual; si detached HEAD, salir silenciosamente
current_branch=$(git symbolic-ref --short HEAD 2>/dev/null) || exit 0

# Si estamos en el default branch, no hay nada que advertir
if [ "$current_branch" = "$default_branch" ]; then
  exit 0
fi

# Verificar que origin/<default> existe; si no, salir silenciosamente
if ! git rev-parse --verify "origin/$default_branch" >/dev/null 2>&1; then
  exit 0
fi

# Calcular hash del repo para el touchfile de throttle
repo_hash=$(printf '%s' "$repo_root" | shasum -a 1 2>/dev/null | cut -d' ' -f1 || printf '%s' "$repo_root" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$repo_root" | tr '/' '_' | tr -d ' ')

# Touchfile path: una advertencia por sesión/repo
touchfile="${TMPDIR:-/tmp}/forge-branch-guard/${repo_hash}.shown"

# Si ya se mostró en esta sesión, salir silenciosamente
if [ -f "$touchfile" ]; then
  exit 0
fi

# Comprobar si la rama actual ya está mergeada en origin/<default>
if git merge-base --is-ancestor HEAD "origin/$default_branch" 2>/dev/null; then
  # Crear directorio y touchfile para throttle
  mkdir -p "${TMPDIR:-/tmp}/forge-branch-guard"
  touch "$touchfile"

  # Emitir el mensaje (con color si stderr es TTY, texto plano si no)
  if [ -t 2 ]; then
    printf '\033[0;33m[branch-guard] La rama '\''%s'\'' ya está mergeada en origin/%s. Considera cambiar de rama antes de seguir trabajando.\033[0m\n' \
      "$current_branch" "$default_branch" >&2
  else
    printf '[branch-guard] La rama '\''%s'\'' ya está mergeada en origin/%s. Considera cambiar de rama antes de seguir trabajando.\n' \
      "$current_branch" "$default_branch" >&2
  fi
fi

exit 0
