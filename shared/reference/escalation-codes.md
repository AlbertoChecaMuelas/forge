# Escalation codes — single source of truth

Every return code of the agent pipeline, defined once. Each agent file lists
ONLY the codes it emits (one line per code); the orchestrator contract in
`shared/CLAUDE-shared.md` keeps a compact routing table. The detail lives here.

| Code | Emitter | Meaning | Consumer → action |
|---|---|---|---|
| `OK: <summary>` | applier, tech | Step/task completed and verified. | Orchestrator → continue to the next step. |
| `BLOCKED: <reason>` | applier | Instruction not literal/unambiguous, plan validation failed, or protected-branch guard fired. Nothing was written. | Orchestrator → re-evaluate; typically the step goes to tech as `[T]`. Tech (when it delegated) → takes the step itself, never retries applier. |
| `VERIFIER_FAILED: <output>` | applier | Step executed but its declared verifier failed. Applier never attempts the fix. | Tech → diagnoses and fixes; re-delegates to applier only if the fix is still mechanical. |
| `OK_BATCH: N/N` | applier | All N batch steps completed; plan checkboxes flipped by applier. | Orchestrator → treat as N sequential `OK:`. |
| `BLOCKED_BATCH: step N.M — <reason>` | applier | Batch stopped at step N.M (pre-batch validation, branch guard, verifier failure, or judgment needed). Earlier steps keep `[x]`; nothing after N.M ran. | Orchestrator → route the N.M failure to tech. |
| `BLOCKED: step is [A] ...` (and other tech rejects) | tech | Task outside tech's role (fully specified `[A]` step, audit, coverage analysis). | Orchestrator → route to the agent the reason names (applier, reviewer, tester). |
| `ESCALATE_SENIOR: <reason>` | tech, tester | A design decision is missing (tech), or testability requires architectural change (tester). | Orchestrator → invoke senior with the reason as context. |
| `BLOCKED_TECH: <reason>` | tech | Task out of tech's domain (e.g. test-writing requests). | Orchestrator → route to the agent named in the reason (typically tester). |
| `TESTING_PLAN: <summary>` | tester | Testing loop closed (tests written/run, coverage checked). | Orchestrator → return control to the user or resume `/execute-plan`; no further delegation to tech. |
| `ESCALATE_TECH: <diagnosis>` | tester | A test failure whose root cause is a bug in production code. Must include file + approximate line + expected vs observed. | Orchestrator → delegate the literal diagnosis to tech; tech fixes production code only and returns `OK:`; orchestrator re-delegates to tester for the suite re-run. |
| `BLOCKED_TESTER: <reason>` | tester | Missing info (ambiguous scope, framework not detected, module not found). | Orchestrator → ask the user. |
| `FINDINGS: <c> critical, <m> major, <n> minor[, coverage=<k>]` | reviewer | Standard audit produced actionable findings. Coverage findings are counted apart, never as impl. | Orchestrator → tech (implementation findings) / senior (design findings); `coverage=k>0` → tester, only if the user wants to address them. |
| `OK_PHASE: <summary>` | reviewer | Phase checkpoint approved (only during `/execute-plan`). | Orchestrator → continue the plan. |
| `FINDINGS_PHASE: impl=<n>, design=<m>[, coverage=<k>]` | reviewer | Phase checkpoint with findings. | Orchestrator → batch-fix: ALL impl findings in one single tech delegation, ALL design findings in one single senior delegation. After fixes, fire EXACTLY ONE incremental re-review (`last_review_sha..HEAD`, model Sonnet), gated by `review_rounds` (max 1 per checkpoint). If `review_rounds` is already 1, skip re-review and record remaining findings as follow-ups. Coverage → tester after the plan completes (do not interrupt the run). |
| `BLOCKED_REVIEW: <reason>` | reviewer | Cannot review (empty diff, no base, ambiguous target, unreadable plan) or the request is outside the audit role. | Orchestrator → ask the user for clarification. |
| `VERIFIED: <item1>; <item2>; ...` | reviewer | Optional metadata line immediately before `OK_PHASE:`/`FINDINGS_PHASE:`: risks actively audited and ruled out. | `/mr-description` → removes them from the risk list for the human reviewer. |
| `REQUIRES_PLAN: <summary>` | senior | A scope-gate trigger fired; a delimited research summary block precedes this line. | Orchestrator → apply the Post-senior gate: invoke `/create-plan` with the captured block; never delegate to tech directly. |
| `BLOCKED_SENIOR: <reason>` | senior | Mandate exceeded (product/policy decision) or info still missing after the 5-question interview. | Orchestrator → ask the user with the reason. |

## Non-code signals

- Senior "actionable decision" (no `REQUIRES_PLAN:`): orchestrator delegates to the agent senior names, with the exact text of the change.
- Senior trailing note `> Test coverage: the user requested tests — route to @tester after this plan completes.`: orchestrator delegates to tester once `/execute-plan` finishes, never mid-plan.
- Reviewer never escalates upward: when it lacks information it asks the user.
- Infrastructure failures (no return code at all: provider/model/sandbox/network errors) are NOT escalation codes. The orchestrator stops, surfaces the raw error to the user (`Fallo de infraestructura del subagente <nombre>: ...`) and waits. No retries, no re-routing.
