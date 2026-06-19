---
description: Generates a multi-step executable plan in .plans/<slug>.md for the current repo, ready to launch with /execute-plan.
argument-hint: "[brief description of the objective]"
---

You are the orchestrator of the `/create-plan` skill. Your job is to collect the user's objective, coordinate with `senior` to produce the plan, and persist it in `.plans/<slug>.md` of the current repo.

## Argument

`$ARGUMENTS` is the optional prompt from the user. It may be empty, brief, or extensive.

`$ARGUMENTS` may also contain a research summary block produced by senior in a prior pass. Detection rule: `$ARGUMENTS` contains a research summary if and only if it contains the literal line `--- BEGIN RESEARCH SUMMARY ---` AND the literal line `--- END RESEARCH SUMMARY ---` (in that order). If both delimiters are present, this skill is operating in pass-2 mode (see Step 1). If neither delimiter is present, this skill is operating in pass-1 mode.

## Flow

### Step 0 — Validate environment

1. Determine the project directory: `pwd` or the current working directory of the session.
2. Verify it is a git repo: `git rev-parse --git-dir`. If it fails, stop with:
   ```
   BLOCKED: the current directory is not a git repo. /create-plan requires a git repo (the plan is referenced with commits).
   ```
3. Do not continue without a valid git repo.
4. Ensure the plans directory exists: `mkdir -p .plans/`. This must run before any senior invocation because in pass-2 mode senior writes the staging file (`.plans/.staging-<slug>.md`) during Step 1 — the directory must already exist at that point.

### Step 1 — Invoke senior

#### Detecting pass-2 mode

If `$ARGUMENTS` contains both the `--- BEGIN RESEARCH SUMMARY ---` and `--- END RESEARCH SUMMARY ---` delimiters (in that order), this is **pass-2 mode**. Pass the entire `$ARGUMENTS` (including the delimited block) verbatim to senior. Senior's instruction in this mode is:

> "You are operating in pass 2 of the two-pass plan flow. The research summary you produced in pass 1 is in `$ARGUMENTS` between the `--- BEGIN RESEARCH SUMMARY ---` and `--- END RESEARCH SUMMARY ---` delimiters. Produce the formatted plan now, in one shot, using ONLY that summary as input; do not re-read the repo. The plan must follow the `## Plan format` section of this skill literally (see `reference/plan-format.md`). Then WRITE the plan yourself to `.plans/.staging-<slug>.md` via a single quoted-heredoc Bash call and return ONLY the line `STAGED: <absolute-path> — slug=<slug>, phases=N, steps=M`. Do not return the plan body."

Continue to Step 2 with the staging file that senior wrote. The plan body never enters this skill's context — only the `STAGED:` line, from which you read `<absolute-path>`, `<slug>`, `N` (phases) and `M` (steps).

#### Pass-1 mode (fallback)

If the research-summary delimiters are NOT present in `$ARGUMENTS`, this is **pass-1 mode**. Launch the `senior` subagent with the following context:

- The text of `$ARGUMENTS` (may be empty).
- The current repo (result of `git rev-parse --show-toplevel`).
- The current branch (result of `git rev-parse --abbrev-ref HEAD`).
- Explicit instruction: **evaluate whether it has enough information to produce an actionable plan** and, if so, generate it directly. If information is missing, interview the user with at most 5 questions.

Criteria that senior uses to evaluate whether it has enough information:
- Knows the objective of the change (what is achieved when done).
- Knows the areas or files to be touched (at least at directory level).
- Knows the closed constraints (decisions that are not reopened).
- Knows the success criterion (how to verify it is done).

When senior returns a research summary in pass-1 mode (its output contains the `--- BEGIN RESEARCH SUMMARY ---` and `--- END RESEARCH SUMMARY ---` delimiters), the skill does NOT continue to Step 2. It stops and surfaces to main: "Research summary captured. Re-invoke `/create-plan` with the summary as `$ARGUMENTS` to produce the formatted plan." This is a safety net — the normal flow is main capturing and re-invoking automatically.

**Capturing senior's output**: in pass-2 mode the plan body is NEVER relayed through this skill. Senior writes the formatted plan directly to `.plans/.staging-<slug>.md` (a single quoted-heredoc Bash call in its own turn) and returns ONLY the line `STAGED: <absolute-path> — slug=<slug>, phases=N, steps=M`. The orchestrator parses that line for the staging path, the slug, and the N/M counts; it never reads or re-emits the plan body. There is no `PLAN_CONTENT` variable — the file on disk is the single source of truth and is promoted in Step 6 without re-serialization. In pass-1 mode, senior's output is the research summary — it is NOT written to `.plans/`; it is surfaced to main for re-invocation.

**STAGED line parse contract**: extract fields as follows — `path` is everything between `STAGED: ` and the first ` — `; then split the remainder on `, ` to obtain `key=value` pairs: `slug=<slug>`, `phases=N`, `steps=M`. The `slug` field from this parse is the authoritative slug for all subsequent steps. Example: given `STAGED: /repo/.plans/.staging-my-feature.md — slug=my-feature, phases=3, steps=12`, `path=/repo/.plans/.staging-my-feature.md`, `slug=my-feature`, `phases=3`, `steps=12`.

If senior returns `BLOCKED_SENIOR: <reason>`, stop and communicate to the user what information is missing.

### Step 1.5 — Placeholder gate (pass-2 only, on disk)

`<staging-file>` throughout this step (and Steps 2→3→6) is always `.plans/.staging-<slug>.md`, where `<slug>` is the value from the `STAGED:` line's `slug=` field (see parse contract above). This path remains stable from Step 1.5 through Step 6; the only case where the staging file is renamed before Step 6 is Step 3's `(n) new slug` branch, which renames it to `.plans/.staging-<new-slug>.md` before proceeding.

Scan the staging file senior wrote (`<absolute-path>` from the `STAGED:` line) for placeholders forbidden by the zero-context executor rule (`reference/plan-format.md`). This is a token-free on-disk grep — the plan body is never loaded into context:

```bash
grep -nE "TBD|TODO|similar (a|to)|as appropriate|\?\?\?" "<staging-file>"
```

- If the grep matches: do NOT promote. Return to senior ONCE with ONLY the matching line numbers and the literal instruction: "The staging plan violates the zero-context executor rule (matching lines: <lines>). Fix every placeholder IN PLACE in `<staging-file>` via Bash and return a fresh `STAGED:` line." Re-run this on-disk grep against the rewritten staging file.
- If it still matches after that single retry: stop with `BLOCKED: plan contains placeholders after senior retry` and surface the matching lines to the user. Do not load or re-emit the plan body.

After the gate passes, verify front-matter sanity on disk: `head -1 "<staging-file>" | grep -q '^---$'`. If it fails, stop with `BLOCKED: staging plan missing YAML front-matter`.

### Step 2 — Read slug from STAGED line

The slug is taken verbatim from the `slug=<slug>` field in the `STAGED:` line parsed in Step 1 (see STAGED line parse contract). Senior is the deriver of record. The skill does NOT re-derive the slug from any title or other source.

At this point `<slug>` is set, and `<staging-file>` is `.plans/.staging-<slug>.md` (confirmed to exist and pass the gate in Step 1.5).

### Step 3 — Duplicate slug gate

Check whether `.plans/<slug>.md` exists in the current repo.

**If it does NOT exist**: continue to step 4.

**If it exists**: ask the user ONE option:
```
El plan .plans/<slug>.md ya existe. Elige:
  (a) append  — añadir al final como sub-plan con timestamp
  (o) overwrite — sobrescribir (se crea backup <slug>.md.bak-<epoch>)
  (n) new slug — usar un slug diferente (te pido el nuevo)
```
Behavior based on response:
- `a`: continue; when writing (Step 6), append to the end of the file under `## Sub-plan: <ISO-timestamp>`.
- `o`: before writing, rename the existing file to `<slug>.md.bak-<epoch>`.
- `n`: ask the user for the new slug, then rename the existing staging file before proceeding:
  ```bash
  mv .plans/.staging-<senior-slug>.md .plans/.staging-<new-slug>.md
  ```
  Update `<slug>` to `<new-slug>` (and `<staging-file>` accordingly) for all subsequent steps, then return to step 3 with the new value.

### Step 4 — Ensure .plans/ directory

Already guaranteed by Step 0 (`mkdir -p .plans/` runs during environment validation, before senior's staging write in Step 1). Nothing to do here.

### Step 5 — Add .plans/ to the target repo's .gitignore

If the target repo has no `.gitignore`, create it with the line `.plans/`. If it already exists but `.plans/` does not appear in it, append the line `.plans/` at the end. Idempotent action: if it is already there, do not duplicate it.

### Step 6 — Promote the plan

The plan body is already on disk in the staging file `<staging-file>` (`.plans/.staging-<slug>.md`) that senior wrote, and it has passed the on-disk placeholder + front-matter gates (Step 1.5). Promotion is a token-free file operation — the orchestrator NEVER loads, re-types, or delegates the plan body. Run the branch matching the mode resolved in Step 3, from the repo root:

- **create** (slug did not exist):
  ```bash
  mv .plans/.staging-<slug>.md .plans/<slug>.md
  ```
- **overwrite** (Step 3 answer `o`): back up the existing file, then promote:
  ```bash
  mv .plans/<slug>.md ".plans/<slug>.md.bak-$(date +%s)" && mv .plans/.staging-<slug>.md .plans/<slug>.md
  ```
- **append** (Step 3 answer `a`): append the staging content under a timestamped sub-plan heading, then remove the staging file:
  ```bash
  printf '\n## Sub-plan: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> .plans/<slug>.md && cat .plans/.staging-<slug>.md >> .plans/<slug>.md && rm .plans/.staging-<slug>.md
  ```

Rules:
- No applier delegation and no orchestrator heredoc: the file is moved/appended as bytes already written by its author. There is zero plan-content re-emission.
- Verifier after promotion (any mode): `test -f .plans/<slug>.md && head -1 .plans/<slug>.md | grep -q '^---$'`.
- If any `mv`/`cat`/`printf` fails (e.g. the staging file is missing): stop with `BLOCKED: staging file <staging-file> missing or promotion failed`; do not attempt to reconstruct the plan body.

### Step 7 — Create/update .plans/current symlink

Run from the target repo:
```bash
cd <repo-root> && ln -sfn <slug>.md .plans/current
```
The symlink is relative (points to `<slug>.md`, not to the absolute path).

### Step 8 — Confirm to the user

Report with a single line:
```
Plan creado: .plans/<slug>.md (N fases, M pasos). Lanzar con /execute-plan.
```
Where N and M are taken from the `STAGED:` line returned by senior (`phases=N, steps=M` fields).

## References

The following reference files define the format and constraints that senior must follow when producing the plan. Read them when producing or validating the formatted plan.

- `reference/plan-format.md` — Full specification of the YAML front-matter, section headings, step labels (`[A]`/`[T]`), CHECKPOINT placement rules, and mandatory final sections (`# GLOBAL VERIFIER`, `# ROLLBACK`) that senior must emit.
- `reference/constraints.md` — Immutable constraints for this skill: no commits, no push, idempotency rules, senior staging-write + token-free on-disk promotion, and the two-pass senior contract.

## Final output

A single confirmation line:

```
Plan creado: .plans/<slug>.md (N fases, M pasos). Lanzar con /execute-plan.
```
