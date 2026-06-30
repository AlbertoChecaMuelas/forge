#!/usr/bin/env bash
# shared/cost-report.sh
# Cost breakdown report by model family, top sessions, and anomaly detection.
#
# Usage:
#   cost-report.sh [--since YYYY-MM-DD] [--until YYYY-MM-DD]
#                  [--project <substring>] [--format text|json] [-h|--help]

set -u
export LC_ALL=C

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
since=""
until=""
project_filter=""
session_filter=""
format="text"

while [ $# -gt 0 ]; do
  case "$1" in
    --since)
      since="${2:-}"
      shift 2
      ;;
    --since=*)
      since="${1#--since=}"
      shift
      ;;
    --until)
      until="${2:-}"
      shift 2
      ;;
    --until=*)
      until="${1#--until=}"
      shift
      ;;
    --project)
      project_filter="${2:-}"
      shift 2
      ;;
    --project=*)
      project_filter="${1#--project=}"
      shift
      ;;
    --session)
      session_filter="${2:-}"
      shift 2
      ;;
    --session=*)
      session_filter="${1#--session=}"
      shift
      ;;
    --format)
      format="${2:-text}"
      shift 2
      ;;
    --format=*)
      format="${1#--format=}"
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: cost-report.sh [OPTIONS]

Options:
  --since YYYY-MM-DD    Start date (inclusive). Default: all history.
  --until YYYY-MM-DD    End date (inclusive). Default: today.
  --project <substring> Filter .jsonl paths containing this substring.
  --session <id-or-name>  Filter to a single session by sessionId substring or aiTitle substring (case-insensitive).
  --format text|json    Output format (default: text).
  -h, --help            Show this help and exit.

Examples:
  # Text report for current month
  cost-report.sh --since 2026-06-01

  # JSON output for a specific project
  cost-report.sh --project my-project --format json

  # Narrow window in JSON
  cost-report.sh --since 2026-05-01 --until 2026-05-31 --format json
EOF
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Discovery: collect .jsonl files
# ---------------------------------------------------------------------------
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# Build file list into a temp file (bash 3.2 compatible, no mapfile)
_tmplist=$(mktemp)
trap 'rm -f "$_tmplist"' EXIT

if [ -n "$project_filter" ]; then
  find "$PROJECTS_DIR" -name '*.jsonl' -type f | grep -F "$project_filter" > "$_tmplist"
else
  find "$PROJECTS_DIR" -name '*.jsonl' -type f > "$_tmplist"
fi

# If no files found, output empty result
if [ ! -s "$_tmplist" ]; then
  if [ "$format" = "json" ]; then
    jq -n \
      --arg since "$since" \
      --arg until "$until" \
      --arg session "$session_filter" \
      '{window:{since:$since,until:$until},by_model:[],top_sessions:[],anomalies:[]}'
  else
    echo "Cost Report"
    echo "Window: ${since:-<all>} -> ${until:-<today>}"
    echo "No data found."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Aggregation via jq
# ---------------------------------------------------------------------------
xargs cat < "$_tmplist" 2>/dev/null \
  | jq -nrR \
      --arg since "$since" \
      --arg until "$until" \
      --arg fmt "$format" \
      --arg session "$session_filter" \
'
# Tarifas USD por millón de tokens: [input, output, cache_5m, cache_1h, cache_read]
{
  "claude-opus-4-8":              [5, 25, 6.25, 10, 0.5],
  "claude-fable-5":               [10, 50, 12.5, 20, 1],   # tentative API ID
  "claude-mythos-5":              [10, 50, 12.5, 20, 1],   # tentative API ID
  "claude-opus-4-7":              [5, 25, 6.25, 10, 0.5],
  "claude-opus-4-6":              [5, 25, 6.25, 10, 0.5],
  "claude-opus-4-5":              [5, 25, 6.25, 10, 0.5],
  "claude-opus-4-1":              [15, 75, 18.75, 30, 1.5],
  "claude-opus-4-1-20250805":     [15, 75, 18.75, 30, 1.5],
  "claude-opus-4":                [15, 75, 18.75, 30, 1.5],
  "claude-opus-4-20250514":       [15, 75, 18.75, 30, 1.5],
  "claude-sonnet-5":              [2, 4, 2.5, 4, 0.2],   # until 2026-08-31; from 2026-09-01: [3, 6, 3.75, 6, 0.3]
  "claude-sonnet-4-6":            [3, 15, 3.75, 6, 0.3],
  "claude-sonnet-4-5":            [3, 15, 3.75, 6, 0.3],
  "claude-sonnet-4":              [3, 15, 3.75, 6, 0.3],
  "claude-haiku-4-5":             [1, 5, 1.25, 2, 0.1],
  "claude-haiku-4-5-20251001":    [1, 5, 1.25, 2, 0.1],
  "claude-haiku-3-5":             [0.8, 4, 1, 1.6, 0.08]
} as $T

# Parse all lines, skip malformed — collect ALL record types
| [ inputs | fromjson? ] as $all

# Build sessionId -> aiTitle lookup from ai-title records
| ($all | map(select(.type == "ai-title")) | map({key: .sessionId, value: .aiTitle}) | from_entries) as $titles

# Derive assistant rows with usage data
| ($all | map(select(.type == "assistant" and (.message.usage // null) != null)))

# Map to row objects
| map(
    (.message.model // "") as $m
    | (.message.usage // {}) as $u
    | ((.timestamp // "")[0:10]) as $day
    | ($T[$m] // [3,15,3.75,6,0.3]) as $p
    | (if ($u.cache_creation | type) == "object"
        then [($u.cache_creation.ephemeral_5m_input_tokens // 0), ($u.cache_creation.ephemeral_1h_input_tokens // 0)]
        else [($u.cache_creation_input_tokens // 0), 0]
       end) as $cw
    | {
        model: $m,
        day: $day,
        session_id: (.sessionId // ""),
        calls: 1,
        input_tokens:    ($u.input_tokens // 0),
        output_tokens:   ($u.output_tokens // 0),
        cache_read:      ($u.cache_read_input_tokens // 0),
        cache_creation:  ($cw[0] + $cw[1]),
        cost_usd: ((
          ($u.input_tokens // 0) * $p[0]
          + ($u.output_tokens // 0) * $p[1]
          + $cw[0] * $p[2]
          + $cw[1] * $p[3]
          + ($u.cache_read_input_tokens // 0) * $p[4]
        ) / 1000000)
      }
  )

# Apply date window filter and optional session filter
| map(
    select(
      ($since == "" or .day >= $since) and
      ($until == "" or .day <= $until) and
      ($session == "" or
       ((.session_id | ascii_downcase) | contains($session | ascii_downcase)) or
       (($titles[.session_id] // "") | ascii_downcase | contains($session | ascii_downcase)))
    )
  )

# Build aggregations
| . as $rows

# by_model: group by family, sum metrics
| (
    $rows
    | group_by(
        if (.model | test("opus")) then "opus"
        elif (.model | test("sonnet")) then "sonnet"
        elif (.model | test("haiku")) then "haiku"
        else "unknown"
        end
      )
    | map(
        (.[0].model | if test("opus") then "opus" elif test("sonnet") then "sonnet" elif test("haiku") then "haiku" else "unknown" end) as $family
        | {
            model_family: $family,
            agent_group: (
              if $family == "opus"   then "senior/reviewer/orchestrator"
              elif $family == "sonnet" then "tech/tester"
              elif $family == "haiku"  then "applier"
              else "unknown"
              end
            ),
            calls:           (map(.calls) | add // 0),
            input_tokens:    (map(.input_tokens) | add // 0),
            output_tokens:   (map(.output_tokens) | add // 0),
            cache_read:      (map(.cache_read) | add // 0),
            cache_creation:  (map(.cache_creation) | add // 0),
            cost_usd:        (map(.cost_usd) | add // 0)
          }
      )
  ) as $by_model_raw

# Inject pct_cost into each by_model entry
| (($by_model_raw | map(.cost_usd) | add // 0) as $total_cost
   | $by_model_raw | map(. + {
       pct_cost: (if $total_cost == 0 then 0 else (.cost_usd / $total_cost * 100) end)
     })
  ) as $by_model

# top_sessions: top 5 by cost
| (
    $rows
    | group_by(.session_id)
    | map({
        session_id: .[0].session_id,
        ai_title:   ($titles[.[0].session_id] // ""),
        calls:    (map(.calls) | add // 0),
        cost_usd: (map(.cost_usd) | add // 0)
      })
    | sort_by(-.cost_usd)
    | .[0:5]
  ) as $top_sessions

# anomalies
| (
    ($by_model | map(select(.model_family == "opus") | .calls) | add // 0) as $opus_calls
    | ($rows | map(.calls) | add // 0) as $total_calls
    | [
        (if $total_calls > 50 and ($opus_calls / ($total_calls | if . == 0 then 1 else . end)) > 0.40
         then {
                code: "opus_ratio_high",
                message: "Opus usage ratio high (>40% of total calls)",
                value: ($opus_calls / ($total_calls | if . == 0 then 1 else . end))
              }
         else empty
         end),
        (if $opus_calls > 100
         then {
                code: "opus_volume_high",
                message: "Opus call volume high (>100 calls)",
                value: $opus_calls
              }
         else empty
         end)
      ]
  ) as $anomalies

# Output
| if $fmt == "json" then
    {
      window: { since: $since, until: $until },
      by_model: $by_model,
      top_sessions: $top_sessions,
      anomalies: $anomalies
    }
  else
    # Text output
    (
      "=== Cost Report ===",
      ("Window : " + (if $since == "" then "<all>" else $since end) + " → " + (if $until == "" then "<today>" else $until end)),
      "",
      "By Model Family",
      "---------------",
      (["Model", "Calls", "Token In", "Token Out", "% Cost", "Estimated Cost"]
        | @tsv),
      ($by_model[]
        | [.model_family, (.calls|tostring), (.input_tokens|tostring), (.output_tokens|tostring), ((.pct_cost | . * 10 | round / 10 | tostring) + "%"), ("$" + (.cost_usd | . * 10000 | round / 10000 | tostring))]
        | @tsv),
      "",
      "Top Sessions (by cost)",
      "----------------------",
      (["Session ID", "Title", "Calls", "Estimated Cost"] | @tsv),
      ($top_sessions[]
        | [.session_id, (.ai_title | if . == "" then "(no title)" else .[0:40] end), (.calls|tostring), (.cost_usd | . * 10000 | round / 10000 | tostring)]
        | @tsv),
      "",
      "Anomalies",
      "---------",
      (if ($anomalies | length) == 0
       then "No anomalies detected."
       else ($anomalies[] | "[\(.code)] \(.message) (value: \(.value))")
       end)
    )
    | .
  end
'
