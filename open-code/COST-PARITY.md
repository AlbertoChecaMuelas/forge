# OpenCode Cost Parity

Verdict: LIMITED

- Data sources:
  - `opencode stats --models --days 1` for native per-model usage and cost totals
  - `opencode export <session-id>` for per-session model, token, cache, and delegated subtask metadata
- Scope: OpenCode has a native stats path for OpenCode sessions, so Forge can report OpenCode usage without inventing extra telemetry.
- Limitation: this is not RTK-compatible request telemetry and does not provide Claude-side proxy parity.
- Contract: keep Claude Code cost reporting unchanged; for OpenCode, document and use the native stats/export path above.
