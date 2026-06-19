#!/usr/bin/env bash
# Compact status line for subagent sessions: model + tokens used.
# JSON input contract matches shared/statusline.sh (subset of fields).

set -euo pipefail

export LC_NUMERIC=C

input=$(cat)

# Colors (minimal palette — subagent output, not main session)
CYAN='\033[36m'
MAGENTA='\033[35m'
GRAY='\033[90m'
DIM='\033[2m'
RED='\033[31m'
YELLOW='\033[33m'
GREEN='\033[32m'
RESET='\033[0m'

# Parse fields
model=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
tok_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
tok_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')

# Agent prefix (only when field is present and non-null)
prefix=""
if [ -n "$agent_name" ] && [ "$agent_name" != "null" ]; then
  prefix="${DIM}[${agent_name}]${RESET} "
fi

# Model segment
model_part="${MAGENTA}${model}${RESET}"

# Token segment: show in/out when available
tokens_part=""
if [ -n "$tok_in" ] && [ "$tok_in" != "null" ] && \
   [ -n "$tok_out" ] && [ "$tok_out" != "null" ]; then
  tokens_part="${GRAY}in:${RESET}${CYAN}${tok_in}${RESET} ${GRAY}out:${RESET}${CYAN}${tok_out}${RESET}"
fi

# Context usage segment: percentage + window size when available
ctx_part=""
if [ -n "$used" ] && [ "$used" != "null" ]; then
  used_int=$(printf '%.0f' "$used")
  if [ "$used_int" -ge 90 ]; then pct_color="$RED"
  elif [ "$used_int" -ge 70 ]; then pct_color="$YELLOW"
  else pct_color="$GREEN"; fi
  ctx_part="${GRAY}ctx:${RESET}${pct_color}${used_int}%${RESET}"
  if [ -n "$ctx_size" ] && [ "$ctx_size" != "null" ]; then
    ctx_k=$(( ctx_size / 1000 ))
    ctx_part="${ctx_part}${GRAY}/${ctx_k}k${RESET}"
  fi
fi

# Assemble single line
line="${prefix}${model_part}"
[ -n "$tokens_part" ] && line="${line} ${DIM}|${RESET} ${tokens_part}"
[ -n "$ctx_part" ]    && line="${line} ${DIM}|${RESET} ${ctx_part}"

printf '%b\n' "$line"
