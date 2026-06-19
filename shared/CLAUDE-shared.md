# CLAUDE-shared (forge)

<!-- Shared instructions distributed by forge. Do not edit directly: this file is a symlink to the repo. -->

## Executable plans and MRs

- `/create-plan` writes `.plans/<slug>.md` + symlink `.plans/current` (`.plans/` is gitignored). `/execute-plan` iterates: `[A]` → applier, `[T]` → tech; reviewer checkpoints capped at 2 per plan (midpoint when P >= 4, final at close; detail in the skills).
- `FINDINGS_PHASE` (reviewer checkpoint with findings): orchestrator applies batch-fix — ALL impl findings in one single tech delegation, ALL design findings in one single senior delegation. After fixes, fire EXACTLY ONE incremental re-review (`last_review_sha..HEAD`, model Sonnet), gated by `review_rounds` in the plan front-matter (integer, starts at 0 per checkpoint, max 1). If `review_rounds` is already 1, skip re-review and record remaining findings as follow-ups. Coverage findings go to tester after the plan completes.
- User asks to create a PR ("crea la MR", "abre el merge request") → invoke `/create-pr`: it drives the full release flow (version bump, changelog, PR description, `create-pr.sh`).
- Never push (deny in settings); the user pushes manually.

RTK pinned v0.42.4 by forge (`rtk gain` shows savings).

Always respond to the user in Spanish. Internal reasoning and inter-agent protocol tokens are in English.
