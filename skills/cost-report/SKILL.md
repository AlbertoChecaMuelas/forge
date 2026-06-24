---
name: cost-report
description: Break down Claude session cost by subagent (model proxy). Shows cost per model family (opus/sonnet/haiku), top sessions, and anomaly flags.
model: claude-haiku-4-5
allowed-tools: Bash(bash $HOME/.claude/cost-report.sh *)
disable-model-invocation: true
context: fork
---

This command breaks down Claude session costs by model family, using the model as a proxy for the subagent that generated the usage. In this pipeline, each model maps to a distinct agent role: `opus` corresponds to `senior` and `reviewer` (high-reasoning tasks), `sonnet` corresponds to `tech` and `tester` (implementation and analysis), and `haiku` corresponds to `applier` (mechanical, low-latency tasks). By reading model-level spend you can identify which stage of the pipeline is driving cost, detect imbalances (e.g. too many `opus` calls for trivial work), and prioritise routing or prompt optimisations.

## Invocation

```bash
bash $HOME/.claude/cost-report.sh ${ARGS:-}
```

Supported flags:
- `--since YYYY-MM-DD` — include only sessions starting on or after this date (default: all history)
- `--until YYYY-MM-DD` — include only sessions ending on or before this date (default: today)
- `--project <substring>` — filter to projects whose path contains this substring
- `--session <id-or-name>` — filter to a single session by sessionId substring (UUID/prefix) or aiTitle substring (case-insensitive)
- `--format text|json` — output format (default: `text`)
- `-h|--help` — show usage and exit

## How to read the output

**By-model table** (`by_model` in JSON, top table in text):

| Column | Meaning |
|---|---|
| `model_family` | One of `opus`, `sonnet`, `haiku`, or `unknown` |
| `agent_group` | Pipeline role(s) that use this model family |
| `calls` | Number of assistant turns attributed to this family |
| `input_tokens` | Total input tokens (includes cache reads and cache creation) |
| `output_tokens` | Total output tokens |
| `cost_usd` | Estimated cost in USD using the tariff table from `shared/total-usage.sh` |

**Top sessions** (`top_sessions` in JSON, second block in text):

Lists the 5 most expensive sessions in the selected window, identified by session ID, total cost, and call count. Useful for spotting runaway sessions or unexpectedly large plan executions.

**Anomaly flags** (`anomalies` in JSON, bottom block in text):

- `opus_ratio_high` — fired when `opus_calls / total_calls > 0.40` AND `total_calls > 50`. Indicates that more than 40% of all pipeline turns are handled by the most expensive model. Review whether senior or reviewer are being invoked unnecessarily.
- `opus_volume_high` — fired when `opus_calls > 100` in the selected window regardless of ratio. Indicates absolute volume above the expected baseline for a healthy pipeline.

If no anomalies are detected, the block prints `No anomalies detected.`

## Examples

```
/cost-report
```
Produces a text report for all history, showing cost breakdown by model family, top 5 sessions, and any anomaly flags.

```
/cost-report --since 2026-05-01 --format json
```
Emits a JSON object `{window, by_model, top_sessions, anomalies}` for the window starting 2026-05-01. Suitable for piping into `jq` or downstream scripts for programmatic analysis.

```
/cost-report --session 481ee2c2
```
Filters the report to the single session whose ID starts with `481ee2c2`. The value may also be a fragment of the human-readable title (e.g. `--session "filtro-cost-report"`) — matching is case-insensitive against both sessionId and aiTitle.
