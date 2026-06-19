#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_FILE="$SCRIPT_DIR/CLAUDE-orchestrator.md"
stdin_payload=""
if [ -t 0 ]; then
  : # no stdin
else
  stdin_payload="$(cat)"
fi
source_val="startup"
if [ -n "$stdin_payload" ] && command -v jq >/dev/null 2>&1; then
  parsed="$(printf '%s' "$stdin_payload" | jq -r '.source // "startup"' 2>/dev/null)" \
    && [ -n "$parsed" ] && source_val="$parsed"
fi
case "$source_val" in
  startup|clear|compact|resume) ;;
  *) exit 0 ;;
esac
[ -f "$ORCH_FILE" ] || exit 0
cat "$ORCH_FILE"
if [ -n "$stdin_payload" ] && command -v jq >/dev/null 2>&1; then
  _sid="$(printf '%s' "$stdin_payload" | jq -r '.session_id // ""' 2>/dev/null)"
  [ -n "$_sid" ] && printf '%s' "$_sid" > "$HOME/.claude/.arsenal-orchestrator-active" 2>/dev/null || true
fi
exit 0
