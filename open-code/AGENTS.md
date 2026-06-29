# Forge for OpenCode

- Always respond to the user in Spanish.
- The default primary agent is `orchestrator`.
- Worker roles are `@senior`, `@tech`, `@tester`, and `@applier`.
- Use `@agent` delegation for repo work instead of carrying the full routing doctrine in every worker.
- Keep user-facing coordination short and factual.
- Forge executable plans still live under `.plans/<slug>.md`, with `.plans/current` as the live pointer when the plan flow is active.
- Implementation findings should be batched and fixed together before asking for a re-review.
- If the user asks for a PR or MR, route through the repo's release/PR flow instead of improvising ad-hoc git steps.
- Never push on the user's behalf.
- Keep OpenCode cost reporting aligned with `open-code/COST-PARITY.md`.
- Use `question` only when one short clarification is required.
- Branch protection is enforced by `plugins/forge-guard.js`.
- The full orchestration, firewall, and routing doctrine intentionally lives in `open-code/agents-src/orchestrator.body.md` so worker agents do not pay that context cost.
