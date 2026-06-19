# Behavior probes (manual pre-merge gate)

These probes invoke **real models** through the `claude` CLI to confirm that each
pipeline agent still emits its expected escalation/return token. They are a
**manual gate**: they are intentionally NOT part of `run-all.sh` or CI, because
they are non-deterministic (a live model call) and require network + an API key.

## Why they exist

`tests/protocol_unit.sh` (Group 8) statically guarantees that every protocol
token is present in the right files. That is a string-presence guarantee, not a
*behavioral* one. The probes here close the remaining gap: they check that, given
a representative prompt, the agent actually decides to emit the token. Run them
before merging changes that could alter agent behavior.

## Probes

| Probe | Agent | Asserts |
|-------|-------|---------|
| `test_senior_requires_plan.sh`        | senior   | `REQUIRES_PLAN` on a multi-file + breaking change with no plan |
| `test_senior_blocks_mandate.sh`       | senior   | `BLOCKED_SENIOR` on a product/policy decision beyond mandate |
| `test_tester_blocks_no_framework.sh`  | tester   | `BLOCKED_TESTER` when no framework / ambiguous scope |
| `test_applier_*.sh`                   | applier  | `BLOCKED:` / `OK:` (existing) |
| `test_tech_escalate.sh`               | tech     | `ESCALATE_SENIOR` (existing) |
| `test_reviewer_findings.sh`           | reviewer | `FINDINGS_PHASE` (existing) |

(Existing probe filenames may differ; the runner discovers every `test_*.sh` in
this directory.)

## How to run

```bash
bash tests/prompts/run-prompt-tests.sh
```

## When to run

Before merging changes to any of:

- `shared/CLAUDE-orchestrator.md`
- any `agents/*.md` or `open-code/agents/*.md`
- `shared/CLAUDE-shared.md`
- `skills/execute-plan/reference/review-template.md`

## Requirements

- `ANTHROPIC_API_KEY` exported in the environment.
- The `claude` CLI on `PATH`.
