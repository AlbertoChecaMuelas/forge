---
description: "Ad-hoc post-change audit: fills the forge review template and dispatches a fresh review subagent (model opus) over a commit range, branch vs base, or the working tree. Use when the user says 'review', 'audit', 'before merging', 'security review' or asks to assess an existing change."
argument-hint: "[base-ref] [head-ref]"
---

You orchestrate an ad-hoc review. The review prompt is NOT resident: it lives in the template
`skills/execute-plan/reference/review-template.md`, a sibling skill of this one. Resolve it
relative to wherever this skill was loaded from: legacy install →
`~/.claude/skills/execute-plan/reference/review-template.md`; plugin install →
`<plugin-root>/skills/execute-plan/reference/review-template.md` (the execute-plan skill
directory next to this skill's directory).

## Flow

1. Resolve the audit range:
   - `$1` and `$2` given → `BASE_SHA=$(git rev-parse $1)`, `HEAD_SHA=$(git rev-parse $2)`.
   - Only `$1` given → `BASE_SHA=$(git rev-parse $1)`, `HEAD_SHA=$(git rev-parse HEAD)`.
   - No arguments → `BASE_SHA=$(git merge-base master HEAD)` (fall back to `main` if `master`
     does not exist), `HEAD_SHA=$(git rev-parse HEAD)`. If BASE equals HEAD and the working
     tree is dirty, audit the working tree instead: scope = `git diff` + `git diff --staged`.
2. Read the review template and substitute the placeholders:
   - `{BASE_SHA}` / `{HEAD_SHA}` → the resolved SHAs.
   - `{PLAN_STEP}` → `ad-hoc audit (no plan)` unless the user names a plan/phase.
   - `{SCOPE}` → the user's focus if given (e.g. "security"), else `full diff of the range`.
3. Dispatch a FRESH subagent whose entire prompt is the filled template, with `model: opus`.
   Do not paraphrase or trim the template.
4. Relay the subagent's review body to the user verbatim. The last line will be one of
   `OK_PHASE:` / `FINDINGS_PHASE:` / `BLOCKED_REVIEW:` (see
   `shared/reference/escalation-codes.md`): findings route to tech (impl), senior (design)
   or tester (coverage) — only if the user wants to address them.
5. If the dispatch itself fails (infrastructure error, no return code): report
   `Fallo de infraestructura del subagente review: <error>` and stop. Do not retry, do not
   re-route.
