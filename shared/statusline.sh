#!/usr/bin/env bash
# Claude Code status line: cloud theme style + RGB gradient, dynamic emoji, cost, code velocity

# Force C locale for printf so decimal point works regardless of system locale
export LC_NUMERIC=C

input=$(cat)

# Colors
CYAN='\033[36m'
CYAN_BOLD='\033[1;36m'
GREEN='\033[32m'
GREEN_BOLD='\033[1;32m'
YELLOW='\033[33m'
RED='\033[31m'
MAGENTA='\033[35m'
BLUE='\033[94m'
ORANGE='\033[38;5;214m'
WHITE='\033[97m'
GRAY='\033[90m'
DIM='\033[2m'
BOLD='\033[1m'
RESET='\033[0m'

# Truecolor helper
rgb() { printf '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"; }

# Format milliseconds → compact human time (e.g. 1h2m, 12m, 45s)
fmt_ms() {
  local ms="${1:-0}"
  [ -z "$ms" ] || [ "$ms" = "null" ] && { printf ""; return; }
  local s=$(( ms / 1000 ))
  if [ "$s" -lt 60 ]; then printf "%ds" "$s"
  elif [ "$s" -lt 3600 ]; then printf "%dm%ds" $(( s / 60 )) $(( s % 60 ))
  else printf "%dh%dm" $(( s / 3600 )) $(( (s % 3600) / 60 ))
  fi
}

# Parse JSON fields
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
tok_in=$(echo "$input" | jq -r '.context_window.total_input_tokens // empty')
tok_out=$(echo "$input" | jq -r '.context_window.total_output_tokens // empty')
cache_read=$(echo "$input" | jq -r '.context_window.cache_read_tokens // .cost.cache_read_tokens // empty')
cache_create=$(echo "$input" | jq -r '.context_window.cache_creation_tokens // .cost.cache_creation_tokens // empty')
exceeds_200k=$(echo "$input" | jq -r '.exceeds_200k_tokens // empty')
cost=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
lines_add=$(echo "$input" | jq -r '.cost.total_lines_added // 0')
lines_del=$(echo "$input" | jq -r '.cost.total_lines_removed // 0')
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
five_h=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_d=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
style=$(echo "$input" | jq -r '.output_style.name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
vim_mode=$(echo "$input" | jq -r '.vim.mode // empty')
wt_name=$(echo "$input" | jq -r '.worktree.name // empty')
wt_branch=$(echo "$input" | jq -r '.worktree.branch // empty')
agent_name=$(echo "$input" | jq -r '.agent.name // empty')
session_name=$(echo "$input" | jq -r '.session_name // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# Git info (fallback to worktree.branch)
branch=""
git_dirty=0
git_ahead=0
git_behind=0
if [ -n "$cwd" ]; then
  branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    git_dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    counts=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null)
    if [ -n "$counts" ]; then
      git_behind=$(echo "$counts" | awk '{print $1}')
      git_ahead=$(echo "$counts" | awk '{print $2}')
    fi
  fi
fi
[ -z "$branch" ] && branch="$wt_branch"

# Git status suffix: ±N ↑N ↓N (sólo lo no-cero)
git_status_part=""
if [ "$git_dirty" -gt 0 ] 2>/dev/null; then
  git_status_part="${git_status_part} ${YELLOW}±${git_dirty}${RESET}"
fi
if [ "$git_ahead" -gt 0 ] 2>/dev/null; then
  git_status_part="${git_status_part} ${GREEN}↑${git_ahead}${RESET}"
fi
if [ "$git_behind" -gt 0 ] 2>/dev/null; then
  git_status_part="${git_status_part} ${RED}↓${git_behind}${RESET}"
fi

# Cloud theme: ☁  <basename_dir> [branch] ±N ↑N ↓N
dir_name=$(basename "$cwd")
cloud_part="${CYAN_BOLD}☁ ${RESET}${GREEN_BOLD} ${GREEN}${dir_name}${RESET}"
if [ -n "$branch" ]; then
  cloud_part="${cloud_part} ${GREEN_BOLD}[${CYAN}${branch}${GREEN_BOLD}]${RESET}${git_status_part}"
fi

# Context bar: RGB gradient, full blocks only
BAR_WIDTH=10

if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  filled=$(( (used_int * BAR_WIDTH + 50) / 100 ))
  bar=""
  for (( i=0; i<BAR_WIDTH; i++ )); do
    pos=$(( i * 100 / (BAR_WIDTH - 1) ))
    if [ "$pos" -le 50 ]; then
      r=$(( 0 + 220 * pos / 50 ))
      g=200
      b=$(( 80 - 80 * pos / 50 ))
    else
      adj=$(( pos - 50 ))
      r=220
      g=$(( 200 - 160 * adj / 50 ))
      b=$(( 0 + 20 * adj / 50 ))
    fi
    if [ "$i" -lt "$filled" ]; then
      bar="${bar}$(rgb $r $g $b)█"
    else
      bar="${bar}\033[38;2;60;60;60m░"
    fi
  done
  bar="${bar}${RESET}"

  if [ "$used_int" -ge 90 ]; then status_emoji="🚨"
  elif [ "$used_int" -ge 70 ]; then status_emoji="🔥"
  elif [ "$used_int" -ge 20 ]; then status_emoji="⚡"
  else status_emoji="🟢"; fi

  if [ "$used_int" -ge 90 ]; then pct_color="$RED"
  elif [ "$used_int" -ge 70 ]; then pct_color="$YELLOW"
  else pct_color="$GREEN"; fi

  ctx_part="${status_emoji} ${bar} ${pct_color}${used_int}%${RESET}"
  if [ -n "$ctx_size" ] && [ "$ctx_size" != "null" ]; then
    ctx_k=$(( ctx_size / 1000 ))
    if [ "$ctx_k" -ge 1000 ]; then
      ctx_m=$(( ctx_k / 1000 ))
      ctx_part="${ctx_part}${GRAY}/${ctx_m}M${RESET}"
    else
      ctx_part="${ctx_part}${GRAY}/${ctx_k}k${RESET}"
    fi
  fi
else
  ctx_part="🟢 \033[38;2;60;60;60m░░░░░░░░░░${RESET} --%"
fi

# 200k warning
warn_part=""
if [ "$exceeds_200k" = "true" ]; then
  warn_part="${RED}⚠ 200k+${RESET}"
fi

# Cache hit ratio: cache_read / (cache_read + cache_create)
cache_part=""
if [ -n "$cache_read" ] && [ "$cache_read" != "null" ] && \
   [ -n "$cache_create" ] && [ "$cache_create" != "null" ]; then
  cache_total=$(( cache_read + cache_create ))
  if [ "$cache_total" -gt 200 ] 2>/dev/null; then
    cache_pct=$(( cache_read * 100 / cache_total ))
    if [ "$cache_pct" -ge 70 ]; then cc="$GREEN"
    elif [ "$cache_pct" -ge 30 ]; then cc="$YELLOW"
    else cc="$RED"; fi
    cache_part="${GRAY}cache:${RESET}${cc}${cache_pct}%${RESET}"
  fi
fi

# Estadísticas agregadas (coste total/hoy, días, sesiones, tokens, coste sesión).
# Delegado en ~/.claude/total-usage.sh que cachea el resultado 30s.
stats_line=""
if [ -x "$HOME/.claude/total-usage.sh" ]; then
  if [ -n "$session_id" ]; then
    stats_line=$("$HOME/.claude/total-usage.sh" --session "$session_id" 2>/dev/null)
  else
    stats_line=$("$HOME/.claude/total-usage.sh" 2>/dev/null)
  fi
fi

cost_part=""
lifetime_line=""
if [ -n "$stats_line" ]; then
  IFS=$'\t' read -r total_usd today_usd days_count sessions_count total_tokens session_usd <<<"$stats_line"

  # Tipo de cambio USD->EUR cacheado (TTL 24h, refresco en background)
  RATE_CACHE="$HOME/.claude/.eur-rate"
  rate=""
  if [ -f "$RATE_CACHE" ]; then
    rate=$(head -1 "$RATE_CACHE" 2>/dev/null)
    rate_mtime=$(stat -f %m "$RATE_CACHE" 2>/dev/null || stat -c %Y "$RATE_CACHE" 2>/dev/null || echo 0)
    rate_age=$(( $(date +%s) - rate_mtime ))
    if [ "$rate_age" -gt 86400 ]; then
      # shellcheck disable=SC2015  # intentional: A && B || C for async atomic cache update
      ( curl -fsSL --max-time 3 "https://api.frankfurter.dev/v1/latest?from=USD&to=EUR" 2>/dev/null \
          | jq -r '.rates.EUR // empty' > "${RATE_CACHE}.tmp" 2>/dev/null \
          && [ -s "${RATE_CACHE}.tmp" ] && mv "${RATE_CACHE}.tmp" "$RATE_CACHE" \
          || rm -f "${RATE_CACHE}.tmp" ) </dev/null >/dev/null 2>&1 &
      disown 2>/dev/null
    fi
  else
    rate=$(curl -fsSL --max-time 2 "https://api.frankfurter.dev/v1/latest?from=USD&to=EUR" 2>/dev/null \
      | jq -r '.rates.EUR // empty')
    [ -n "$rate" ] && printf '%s\n' "$rate" > "$RATE_CACHE"
  fi

  # Formateo
  total_usd_fmt=$(awk -v u="$total_usd"   'BEGIN{printf "%.2f", u}')
  today_usd_fmt=$(awk -v u="$today_usd"   'BEGIN{printf "%.2f", u}')
  sess_usd_fmt=$(awk  -v u="${session_usd:-0}" 'BEGIN{printf "%.2f", u}')
  if [ -n "$rate" ]; then
    total_eur_fmt=$(awk -v u="$total_usd"   -v r="$rate" 'BEGIN{printf "%.2f", u*r}')
    today_eur_fmt=$(awk -v u="$today_usd"   -v r="$rate" 'BEGIN{printf "%.2f", u*r}')
    sess_eur_fmt=$(awk  -v u="${session_usd:-0}" -v r="$rate" 'BEGIN{printf "%.2f", u*r}')
    total_str="${total_usd_fmt}${ORANGE}\$${GRAY}/${RESET}${total_eur_fmt}${ORANGE}€"
    today_str="${today_usd_fmt}${ORANGE}\$${GRAY}/${RESET}${today_eur_fmt}${ORANGE}€"
    sess_str="${sess_usd_fmt}${YELLOW}\$${GRAY}/${RESET}${sess_eur_fmt}${YELLOW}€"
  else
    total_str="${total_usd_fmt}${ORANGE}\$"
    today_str="${today_usd_fmt}${ORANGE}\$"
    sess_str="${sess_usd_fmt}${YELLOW}\$"
  fi

  # Media diaria sobre días activos (los días sin uso no entran)
  if [ "${days_count:-0}" -gt 0 ] 2>/dev/null; then
    avg_usd_fmt=$(awk -v t="$total_usd" -v d="$days_count" 'BEGIN{printf "%.2f", t/d}')
    if [ -n "$rate" ]; then
      avg_eur_fmt=$(awk -v t="$total_usd" -v d="$days_count" -v r="$rate" 'BEGIN{printf "%.2f", (t/d)*r}')
      avg_str="${avg_usd_fmt}${YELLOW}\$${GRAY}/${RESET}${avg_eur_fmt}${YELLOW}€"
    else
      avg_str="${avg_usd_fmt}${YELLOW}\$"
    fi
  else
    avg_str="-"
  fi

  # Línea 2: coste real de la sesión (del .jsonl, no del proceso) + EUR
  # Si total-usage.sh no devolvió valor de sesión, caemos al cost que envía Claude Code.
  if [ -n "${session_usd:-}" ] && [ "${session_usd:-0}" != "0" ]; then
    cost_part="${YELLOW}${sess_str}${RESET}"
  fi

  # Total de tokens humanizado (B / M / k)
  tokens_str=""
  if [ -n "${total_tokens:-}" ] && [ "$total_tokens" != "0" ]; then
    tokens_str=$(awk -v t="$total_tokens" 'BEGIN{
      if (t>=1e9)      printf "%.2fB", t/1e9;
      else if (t>=1e6) printf "%.1fM", t/1e6;
      else if (t>=1e3) printf "%.1fk", t/1e3;
      else             printf "%d",    t
    }')
  fi

  # Componer línea 3
  lifetime_line="${GRAY}[total]${RESET} ${BOLD}${ORANGE}${total_str}${RESET}"
  [ -n "$tokens_str" ] && lifetime_line="${lifetime_line} ${GRAY}·${RESET} ${CYAN}${tokens_str}${GRAY}tok${RESET}"
  lifetime_line="${lifetime_line} ${GRAY}·${RESET} ${CYAN}${days_count}${GRAY}d${RESET}"
  lifetime_line="${lifetime_line} ${GRAY}·${RESET} ${CYAN}${sessions_count}${GRAY}s${RESET}"
  lifetime_line="${lifetime_line} ${DIM}|${RESET} ${GRAY}[hoy]${RESET} ${ORANGE}${today_str}${RESET}"
  lifetime_line="${lifetime_line} ${DIM}|${RESET} ${GRAY}[dia promedio]${RESET} ${YELLOW}${avg_str}${RESET}"
fi

# Fallback: si total-usage.sh no devolvió coste de sesión, usamos el del proceso
# que envía Claude Code (no incluye relanzamientos previos, pero es lo único que hay).
if [ -z "$cost_part" ]; then
  fallback_fmt=$(awk -v v="$cost" 'BEGIN{printf "%.4f", v}')
  cost_part="${YELLOW}${fallback_fmt}\$${RESET}"
fi

# Token breakdown
tokens_part=""
if [ -n "$tok_in" ] && [ -n "$tok_out" ] && [ "$tok_in" != "null" ] && [ "$tok_out" != "null" ]; then
  tokens_part="${GRAY}tokens${RESET} ${GRAY}in:${RESET}${CYAN}${tok_in}${RESET} ${GRAY}out:${RESET}${MAGENTA}${tok_out}${RESET}"
fi

# Rate limits (5h / 7d)
rate_part=""
if [ -n "$five_h" ] && [ "$five_h" != "null" ]; then
  rate_part="5h:$(printf '%.0f' "$five_h")%"
fi
if [ -n "$seven_d" ] && [ "$seven_d" != "null" ]; then
  [ -n "$rate_part" ] && rate_part="${rate_part} "
  rate_part="${rate_part}7d:$(printf '%.0f' "$seven_d")%"
fi
[ -n "$rate_part" ] && rate_part="${ORANGE}${rate_part}${RESET}"

# Code velocity
velocity="${GREEN}+${lines_add}${RESET} ${RED}-${lines_del}${RESET}"

# Purge indicator: session files older than 90 days across all projects
purge_part=""
if [ -n "$(find "$HOME/.claude/projects" -maxdepth 3 -name "session-*.md" -mtime +90 2>/dev/null | head -1)" ]; then
  purge_part="${ORANGE}🗑 purge${RESET}"
fi

# Orchestrator active indicator (only if hook fired in this session)
orch_part=""
if [ -f "$HOME/.claude/.arsenal-orchestrator-active" ] && [ -n "$session_id" ] && [ "$session_id" != "null" ]; then
  _orch_sid=$(cat "$HOME/.claude/.arsenal-orchestrator-active" 2>/dev/null)
  [ "$_orch_sid" = "$session_id" ] && orch_part="${CYAN}[⬡ orch]${RESET}"
fi

# Línea 1: ubicación + velocity + modelo + estado de contexto
line1="${cloud_part}"
line1="${line1} ${DIM}|${RESET} ${velocity}"
line1="${line1} ${DIM}|${RESET} ${MAGENTA}🤖 ${model}${RESET}"
if [ -n "$effort" ] && [ "$effort" != "null" ]; then
  line1="${line1} ${DIM}|${RESET} ${BLUE}effort:${effort}${RESET}"
fi
line1="${line1} ${DIM}|${RESET} ${ctx_part}"
[ -n "$warn_part" ] && line1="${line1} ${warn_part}"
[ -n "$rate_part" ] && line1="${line1} ${DIM}|${RESET} ${rate_part}"
[ -n "$purge_part" ] && line1="${line1} ${DIM}|${RESET} ${purge_part}"
[ -n "$orch_part" ] && line1="${line1} ${DIM}|${RESET} ${orch_part}"

# Fichero centinela para mostrar costes monetarios ($, €)
TARGET_DIR="$(dirname "$0")"
show_cost=0
[ -f "${TARGET_DIR}/.arsenal-show-cost" ] && show_cost=1

# Línea 2: métricas + extras
# session_name y tokens siempre visibles; cost_part solo si show_cost=1
line2="${WHITE}[ session ]${RESET}"
[ -n "$session_name" ] && [ "$session_name" != "null" ] && line2="${line2} ${WHITE}${session_name}${RESET}"
[ -n "$tokens_part" ] && line2="${line2} ${DIM}|${RESET} ${tokens_part}"
[ -n "$cache_part" ] && line2="${line2} ${DIM}|${RESET} ${cache_part}"
# Coste monetario solo si centinela activo
[ "$show_cost" -eq 1 ] && line2="${line2} ${DIM}|${RESET} ${cost_part}"
if [ -n "$style" ] && [ "$style" != "default" ] && [ "$style" != "null" ]; then
  line2="${line2} ${DIM}|${RESET} ${YELLOW}style:${style}${RESET}"
fi
if [ -n "$vim_mode" ] && [ "$vim_mode" != "null" ]; then
  line2="${line2} ${DIM}|${RESET} ${YELLOW}[${vim_mode}]${RESET}"
fi
if [ -n "$wt_name" ] && [ "$wt_name" != "null" ]; then
  line2="${line2} ${DIM}|${RESET} ${GREEN}worktree:${wt_name}${RESET}"
fi
if [ -n "$agent_name" ] && [ "$agent_name" != "null" ]; then
  line2="${line2} ${DIM}|${RESET} ${MAGENTA}agent:${agent_name}${RESET}"
fi
# Línea 3 (lifetime stats) solo si el fichero centinela .arsenal-show-cost está presente
if [ -n "$lifetime_line" ] && [ "$show_cost" -eq 1 ]; then
  printf '%b\n%b\n%b' "$line1" "$line2" "$lifetime_line"
else
  printf '%b\n%b' "$line1" "$line2"
fi
