#!/usr/bin/env bash
# ~/.claude/total-usage.sh
# Agrega coste/tokens lifetime desde ~/.claude/projects/**/*.jsonl.
#
# Salida (modo short, por defecto):
#   total_usd \t today_usd \t days_count \t sessions_count \t total_tokens [\t session_usd]
#
# Modos / flags:
#   short    (default)  — TSV de una línea (consumido por statusline.sh)
#   refresh             — fuerza recálculo ignorando el cache
#   --session <id>      — añade el coste acumulado de la sesión <id> (6º campo)

set -u
export LC_ALL=C

PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
CACHE_TTL="${CLAUDE_USAGE_TTL:-30}"  # segundos

MODE="short"
SESSION_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    refresh|short) MODE="$1"; shift ;;
    --session) SESSION_ID="${2:-}"; shift 2 ;;
    --session=*) SESSION_ID="${1#--session=}"; shift ;;
    *) shift ;;
  esac
done

# El cache se separa por sessionId para no mezclar respuestas
if [ -n "$SESSION_ID" ]; then
  CACHE_FILE="${CLAUDE_USAGE_CACHE:-$HOME/.claude/.usage-stats-${SESSION_ID}.cache}"
else
  CACHE_FILE="${CLAUDE_USAGE_CACHE:-$HOME/.claude/.usage-stats.cache}"
fi

today_date=$(date +%Y-%m-%d)

need_refresh=1
if [ "$MODE" != "refresh" ] && [ -f "$CACHE_FILE" ]; then
  now=$(date +%s)
  mtime=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
  age=$(( now - mtime ))
  if [ "$age" -lt "$CACHE_TTL" ]; then
    need_refresh=0
  fi
fi

compute() {
  find "$PROJECTS_DIR" -name '*.jsonl' -type f -exec cat {} + 2>/dev/null \
    | jq -nrR --arg today "$today_date" --arg sid "$SESSION_ID" '
      # Tarifas USD por millón de tokens: [input, output, cache_5m, cache_1h, cache_read]
      {
        "claude-opus-4-7":              [5, 25, 6.25, 10, 0.5],
        "claude-opus-4-7-20260416":     [5, 25, 6.25, 10, 0.5],
        "claude-opus-4-6":              [5, 25, 6.25, 10, 0.5],
        "claude-opus-4-6-20260205":     [5, 25, 6.25, 10, 0.5],
        "claude-opus-4-5":              [5, 25, 6.25, 10, 0.5],
        "claude-opus-4-5-20251101":     [5, 25, 6.25, 10, 0.5],
        "claude-opus-4-1":              [15, 75, 18.75, 30, 1.5],
        "claude-opus-4-1-20250805":     [15, 75, 18.75, 30, 1.5],
        "claude-opus-4":                [15, 75, 18.75, 30, 1.5],
        "claude-opus-4-20250514":       [15, 75, 18.75, 30, 1.5],
        "claude-sonnet-5":              [2, 4, 2.5, 4, 0.2],   # until 2026-08-31; from 2026-09-01: [3, 6, 3.75, 6, 0.3]
        "claude-sonnet-4-6":            [3, 15, 3.75, 6, 0.3],
        "claude-sonnet-4-5":            [3, 15, 3.75, 6, 0.3],
        "claude-sonnet-4-5-20250929":   [3, 15, 3.75, 6, 0.3],
        "claude-sonnet-4":              [3, 15, 3.75, 6, 0.3],
        "claude-sonnet-4-20250514":     [3, 15, 3.75, 6, 0.3],
        "claude-haiku-4-5":             [1, 5, 1.25, 2, 0.1],
        "claude-haiku-4-5-20251001":    [1, 5, 1.25, 2, 0.1],
        "claude-haiku-3-5":             [0.8, 4, 1, 1.6, 0.08],
        "claude-3-5-haiku-20241022":    [0.8, 4, 1, 1.6, 0.08]
      } as $T
      | [ inputs | fromjson? | select(.type == "assistant" and (.message.usage // null) != null) ]
      | map(
          (.message.model // "") as $m
          | (.message.usage // {}) as $u
          | ($T[$m] // [3,15,3.75,6,0.3]) as $p
          | (if ($u.cache_creation | type) == "object"
              then [($u.cache_creation.ephemeral_5m_input_tokens // 0), ($u.cache_creation.ephemeral_1h_input_tokens // 0)]
              else [($u.cache_creation_input_tokens // 0), 0]
             end) as $cw
          | {
              day: ((.timestamp // "")[0:10]),
              session: (.sessionId // ""),
              tokens: (
                ($u.input_tokens // 0)
                + ($u.output_tokens // 0)
                + $cw[0] + $cw[1]
                + ($u.cache_read_input_tokens // 0)
              ),
              cost: ((
                ($u.input_tokens // 0) * $p[0]
                + ($u.output_tokens // 0) * $p[1]
                + $cw[0] * $p[2]
                + $cw[1] * $p[3]
                + ($u.cache_read_input_tokens // 0) * $p[4]
              ) / 1000000)
            }
        ) as $rows
      | [
          ($rows | map(.cost) | add // 0),
          ($rows | map(select(.day == $today) | .cost) | add // 0),
          ($rows | map(.day) | unique | map(select(length > 0)) | length),
          ($rows | map(.session) | unique | map(select(length > 0)) | length),
          ($rows | map(.tokens) | add // 0),
          (if $sid == "" then 0 else ($rows | map(select(.session == $sid) | .cost) | add // 0) end)
        ]
      | @tsv
    '
}

if [ "$need_refresh" = "1" ]; then
  compute > "${CACHE_FILE}.tmp" 2>/dev/null && mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
fi

if [ ! -s "$CACHE_FILE" ]; then
  printf "0\t0\t0\t0\t0\t0\n"
  exit 0
fi

cat "$CACHE_FILE"
