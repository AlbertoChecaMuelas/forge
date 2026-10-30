# OpenCode Cost Parity

Verdict: LIMITED

- Data sources:
  - `forge-opencode stats --models --days 1` for native per-model usage and cost totals
  - `forge-opencode session export [flags] [<session>]` for per-session model, token, cache, and delegated subtask metadata
- Resolve these commands through the Forge entry point to the pinned OpenCode 2.1.4 runtime (or invoke that pinned executable directly); never use a generic `opencode` from `PATH`, which could select OpenCode 1. The native OpenCode 2.1.4 command syntax for export is `opencode session export [flags] [<session>]`.
- Scope: OpenCode has a native stats path for OpenCode sessions, so Forge can report OpenCode usage without inventing extra telemetry.
- Limitation: this is not RTK-compatible request telemetry and does not provide Claude-side proxy parity.
- Contract: keep Claude Code cost reporting unchanged; for OpenCode, document and use the native stats/export path above.
