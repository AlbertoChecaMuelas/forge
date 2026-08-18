---
description: Generates a multi-step executable plan in .plans/<slug>.md for the current repo, ready to launch with /execute-plan.
agent: orchestrator
---

You are running the `/create-plan` command. Your job is to collect the user's objective, coordinate with `@senior` (via the `task` tool) to produce the plan, and persist it in `.plans/<slug>.md` of the current repo. Every side effect (directory creation, git checks, greps, file promotion, symlinks) is performed via `bash` — you never use `edit` or `write` tools directly on the plan file.

## Argument

`$ARGUMENTS` is the optional prompt from the user. It may be empty, brief, or extensive.

`$ARGUMENTS` may also contain a research summary block produced by `@senior` in a prior turn (optionally followed by a trailing `REQUIRES_PLAN: <summary>` line — that line, if present, is part of the post-senior gate that triggered this command and should simply be passed through, it has no special meaning inside this command). Detection rule: `$ARGUMENTS` contains a research summary if and only if it contains the literal line `--- BEGIN RESEARCH SUMMARY ---` AND the literal line `--- END RESEARCH SUMMARY ---` (in that order). If both delimiters are present, this command is operating in pass-2 mode (see Step 1). If neither delimiter is present, this command is operating in pass-1 mode.

## Flow

### Step 0 — Validate environment

1. Determine the project directory: `pwd` or the current working directory of the session.
2. Verify it is a git repo: `git rev-parse --git-dir`. If it fails, stop with:
   ```
   BLOCKED: the current directory is not a git repo. /create-plan requires a git repo (the plan is referenced with commits).
   ```
3. Do not continue without a valid git repo.
4. Ensure the plans directory exists: `mkdir -p .plans/`. This must run before any `@senior` invocation because in pass-2 mode senior writes the staging file (`.plans/.staging-<slug>.md`) during Step 1 — the directory must already exist at that point.

### Step 1 — Invoke @senior

#### Detecting pass-2 mode

If `$ARGUMENTS` contains both the `--- BEGIN RESEARCH SUMMARY ---` and `--- END RESEARCH SUMMARY ---` delimiters (in that order), this is **pass-2 mode**. Pass the entire `$ARGUMENTS` (including the delimited block, and the trailing `REQUIRES_PLAN:` line if present) verbatim to `@senior` via the `task` tool. The instruction given to `@senior` in this mode is the following, sent in full:

> You are operating in pass 2 of the two-pass plan flow. The research summary produced in pass 1 is included below between the `--- BEGIN RESEARCH SUMMARY ---` and `--- END RESEARCH SUMMARY ---` delimiters. Produce the formatted plan now, in one shot, using ONLY that summary as input; do not re-read the repo.
>
> The plan MUST follow this format literally:
>
> ### YAML front-matter (first lines of the file)
>
> ```yaml
> ---
> slug: <slug>
> status: pending
> current_phase: 1
> current_step: 1
> target_branch: feat/<slug>   # or fix/<slug> depending on the type of change
> created_at: <YYYY-MM-DD>
> repo: <name of the repo root directory>
> ---
> ```
>
> ### Section `## General objective`
>
> Brief description (2-5 sentences) of what is achieved upon completing the plan.
>
> ### Section `## Closed decisions (do not reopen)`
>
> List of design decisions already made that tech/applier must NOT question or reopen during execution.
>
> ### Section `## Current state (parseable)`
>
> Checkboxes per phase and per step. This block is what `/execute-plan` parses to know what is pending. Exact format:
>
> ```
> ### Phase N — <title>
> - [ ] Step N.1 [A] — <short description>
> - [ ] Step N.2 [T] — <short description>
> ```
>
> Labels:
> - `[A]` (applier): fully specifiable mechanical step, no micro-decisions.
> - `[T]` (tech): step requiring code judgment, local decisions, or debugging.
>
> **Splitting large `[T]` steps**: any `[T]` step whose expected output is large or heavy-generation (e.g. writing a long new file from scratch, a broad multi-file rewrite, an extensive documentation section, or anything else likely to require a long, uninterrupted single turn) MUST be split into several smaller `[T]` sub-steps, each with a narrower and independently verifiable output (e.g. `Step N.2` generates section A, `Step N.3` generates section B, instead of one `Step N.2` generating everything). A single oversized `[T]` step run as one long turn increases the risk of an empty completion or an infrastructure failure with no continuity — this happened in practice on a `task` invocation that ran for 1h12m before failing after an unproductive auto-retry. Rule of thumb when drafting a `[T]` step: if its expected output alone could plausibly fill a long single turn, split it before emitting the plan.
>
> Reviewer CHECKPOINT placement rule:
> - `P <= 3` phases: emit exactly 1 CHECKPOINT block, placed after the last phase (final only).
> - `P >= 4` phases: emit exactly 2 CHECKPOINT blocks — one after phase `ceil(P/2)` (midpoint), one after the last phase (final).
> - Do NOT emit a CHECKPOINT after any other intermediate phase; `/execute-plan` will not invoke the reviewer there and the checkbox would remain permanently un-ticked.
>
> Format for each block:
> ```
> ### CHECKPOINT PHASE N — Reviewer
> - [ ] Approved by reviewer
> ```
> Where `N` is the phase number (either `ceil(P/2)` for the midpoint block, or `P` for the final block). The literal `- [ ] Approved by reviewer` line must be preserved exactly — `/execute-plan` does a string-replace on it.
>
> ### Sections `# PHASE N — <title>`
>
> One section per phase. Each step within the phase has its own sub-heading `## Step N.M`:
>
> ```
> # PHASE N — <title>
>
> ## Step N.1 [A] — <short title>
> ...
>
> ## Step N.2 [T] — <short title>
> ...
> ```
>
> For `[A]` steps: exact path of the affected file or resources; literal command or exact unified diff to apply; shell verifier (command that exits with code 0 if OK).
>
> For `[T]` steps: path(s) of files to create or modify; responsibilities (what tech must do); success criteria (what indicates the step is correctly done); verifier (can be a test, a lint, or "manual verification").
>
> ### Zero-context executor rule
>
> Plans are executed by an agent WITHOUT access to this conversation: the step text is its only context. A plan that needs the conversation to be understood is invalid.
> - Every `[A]` step carries the literal and complete code/diff/command (applied verbatim), exact paths, and a verification command with its expected result.
> - Every `[T]` step describes responsibilities and success criteria that are self-contained (no references to "what we discussed").
>
> Forbidden anti-patterns (placeholders) — any of these invalidates the plan: pending markers (`TBD`, `TODO`, `???`); relative references ("similar to step N", "same as above"); quality without code ("add proper error handling"); unresolved paths (`<your-module>/file.ts`, `src/.../x.ts`); non-executable verifier ("check it works"). Every path referenced must be exact and verified against the repo; every verifier must be a shell command with an expected result.
>
> ### Self-review checklist (mandatory before emitting)
>
> 1. Spec coverage: every requirement of the research summary maps to >=1 step.
> 2. Placeholder scan: `grep -nE "TBD|TODO|similar (a|to)|as appropriate|\?\?\?"` over the plan body returns nothing.
> 3. Path consistency: every referenced path exists in the repo or is created by an earlier step.
> 4. Verifier presence: every `[A]` step has an executable verifier + expected result; every `[T]` step has success criteria + verifier.
> 5. Label sanity: no `[A]` step requires choosing between options; when in doubt, relabel as `[T]`.
>
> A plan that fails any item is not emitted: fix it and re-run the checklist.
>
> ### Explicit CHECKPOINT sections
>
> Include exactly 1 or 2 CHECKPOINT sections per plan — never one per phase, never every 3 commits (see placement rule above). Each CHECKPOINT section contains: what to review (specific criteria for the just-closed phase); a suggested invocation for the reviewer; whether it is blocking.
>
> ### Mandatory final sections
>
> ```
> # GLOBAL VERIFIER
> <shell commands that verify the complete final state of the plan>
>
> # ROLLBACK
> <instructions for reverting if the plan is abandoned midway>
> ```
>
> ### Immutable constraints
>
> - Does not commit the plan: `.plans/` is in `.gitignore`; the plan is never tracked.
> - Does not push: the repo policy blocks it (`git push` requires confirmation/is denied).
> - You never ask more than 5 questions: if after 5 questions you still lack enough information, you would return `BLOCKED_SENIOR` — but in pass 2 you have the full research summary already, so this should not occur; if the summary is genuinely insufficient, return `BLOCKED_SENIOR: <reason>` instead of guessing.
> - If the repo is not git: this command already blocks before reaching you.
> - Idempotency of `.gitignore` is the orchestrator's responsibility (Step 5 below), not yours.
> - Plan content is written once by its author (you) and never re-serialized: you write the complete formatted plan directly to `.plans/.staging-<slug>.md` via a single `bash` quoted-heredoc call and return ONLY a `STAGED:` confirmation line. The orchestrator promotes that file on disk (`mv`/append) and runs all gates on disk; it never loads, re-types, or relays the plan body. Any re-emission of the plan body after your staging write is a contract violation.
> - Placeholder gate (on disk): the orchestrator will scan your staging file on disk (`grep -nE "TBD|TODO|similar (a|to)|as appropriate|\?\?\?" <staging-file>`) before promotion. If it matches, you will be asked ONCE to fix every placeholder IN PLACE in the staging file via `bash` and return a fresh `STAGED:` line. Get it right the first time.
>
> ### What you must do now
>
> Derive `<slug>` from the objective (short kebab-case identifier). Then WRITE the plan yourself to `.plans/.staging-<slug>.md` via a single quoted-heredoc `bash` call (e.g. `bash -lc "cat > .plans/.staging-<slug>.md <<'PLANEOF' ... PLANEOF"`) and return ONLY the line:
>
> `STAGED: <absolute-path> — slug=<slug>, phases=N, steps=M`
>
> Do not return the plan body in your final message.

Continue to Step 2 with the staging file that `@senior` wrote. The plan body never enters this command's context — only the `STAGED:` line, from which you read `<absolute-path>`, `<slug>`, `N` (phases) and `M` (steps).

#### Pass-1 mode (fallback)

If the research-summary delimiters are NOT present in `$ARGUMENTS`, this is **pass-1 mode**. Invoke `@senior` via the `task` tool with the following context:

- The text of `$ARGUMENTS` (may be empty).
- The current repo (result of `git rev-parse --show-toplevel`).
- The current branch (result of `git rev-parse --abbrev-ref HEAD`).
- Explicit instruction: evaluate whether it has enough information to produce an actionable plan and, if so, generate it directly. If information is missing, interview the user with at most 5 questions.

Criteria `@senior` uses to evaluate whether it has enough information:
- Knows the objective of the change (what is achieved when done).
- Knows the areas or files to be touched (at least at directory level).
- Knows the closed constraints (decisions that are not reopened).
- Knows the success criterion (how to verify it is done).

When `@senior` returns a research summary in pass-1 mode (its output contains the `--- BEGIN RESEARCH SUMMARY ---` and `--- END RESEARCH SUMMARY ---` delimiters, possibly followed by a `REQUIRES_PLAN:` line), this command does NOT continue to Step 2. It stops and surfaces to the orchestrator's user-facing summary: "Research summary captured. Re-invoke `/create-plan` with the summary as `$ARGUMENTS` to produce the formatted plan." This is a safety net — the normal flow is the calling context (e.g. the post-senior gate) capturing and re-invoking automatically.

**Capturing senior's output**: in pass-2 mode the plan body is NEVER relayed through this command. `@senior` writes the formatted plan directly to `.plans/.staging-<slug>.md` (a single quoted-heredoc `bash` call in its own turn) and returns ONLY the line `STAGED: <absolute-path> — slug=<slug>, phases=N, steps=M`. You parse that line for the staging path, the slug, and the N/M counts; you never read or re-emit the plan body. There is no `PLAN_CONTENT` variable — the file on disk is the single source of truth and is promoted in Step 6 without re-serialization. In pass-1 mode, `@senior`'s output is the research summary — it is NOT written to `.plans/`; it is surfaced to the user for re-invocation.

**STAGED line parse contract**: extract fields as follows — `path` is everything between `STAGED: ` and the first ` — `; then split the remainder on `, ` to obtain `key=value` pairs: `slug=<slug>`, `phases=N`, `steps=M`. The `slug` field from this parse is the authoritative slug for all subsequent steps. Example: given `STAGED: /repo/.plans/.staging-my-feature.md — slug=my-feature, phases=3, steps=12`, `path=/repo/.plans/.staging-my-feature.md`, `slug=my-feature`, `phases=3`, `steps=12`.

If `@senior` returns `BLOCKED_SENIOR: <reason>`, stop and communicate to the user what information is missing.

### Step 1.5 — Placeholder gate (pass-2 only, on disk)

`<staging-file>` throughout this step (and Steps 2→3→6) is always `.plans/.staging-<slug>.md`, where `<slug>` is the value from the `STAGED:` line's `slug=` field (see parse contract above). This path remains stable from Step 1.5 through Step 6; the only case where the staging file is renamed before Step 6 is Step 3's `(n) new slug` branch, which renames it to `.plans/.staging-<new-slug>.md` before proceeding.

Scan the staging file `@senior` wrote (`<absolute-path>` from the `STAGED:` line) for placeholders forbidden by the zero-context executor rule. This is a token-free on-disk grep — the plan body is never loaded into context:

```bash
grep -nE "TBD|TODO|similar (a|to)|as appropriate|\?\?\?" "<staging-file>"
```

- If the grep matches: do NOT promote. Return to `@senior` ONCE via `task`, with ONLY the matching line numbers and the literal instruction: "The staging plan violates the zero-context executor rule (matching lines: <lines>). Fix every placeholder IN PLACE in `<staging-file>` via `bash` and return a fresh `STAGED:` line." Re-run this on-disk grep against the rewritten staging file.
- If it still matches after that single retry: stop with `BLOCKED: plan contains placeholders after senior retry` and surface the matching lines to the user. Do not load or re-emit the plan body.

After the gate passes, verify front-matter sanity on disk: `head -1 "<staging-file>" | grep -q '^---$'`. If it fails, stop with `BLOCKED: staging plan missing YAML front-matter`.

### Step 2 — Read slug from STAGED line

The slug is taken verbatim from the `slug=<slug>` field in the `STAGED:` line parsed in Step 1 (see STAGED line parse contract). `@senior` is the deriver of record. This command does NOT re-derive the slug from any title or other source.

At this point `<slug>` is set, and `<staging-file>` is `.plans/.staging-<slug>.md` (confirmed to exist and pass the gate in Step 1.5).

### Step 3 — Duplicate slug gate

Check whether `.plans/<slug>.md` exists in the current repo (`bash`: `test -f .plans/<slug>.md`).

**If it does NOT exist**: continue to Step 4.

**If it exists**: use the `question` tool to ask the user to pick exactly one option, presenting:
```
El plan .plans/<slug>.md ya existe. Elige:
  (a) append    — añadir al final como sub-plan con timestamp
  (o) overwrite — sobrescribir (se crea backup <slug>.md.bak-<epoch>)
  (n) new slug  — usar un slug diferente (te pido el nuevo)
```
Behavior based on the answer:
- `a`: continue; when writing (Step 6), append to the end of the file under `## Sub-plan: <ISO-timestamp>`.
- `o`: before writing, rename the existing file to `<slug>.md.bak-<epoch>`.
- `n`: ask the user for the new slug (a second short `question` or free-text prompt), then rename the existing staging file before proceeding:
  ```bash
  mv .plans/.staging-<senior-slug>.md .plans/.staging-<new-slug>.md
  ```
  Update `<slug>` to `<new-slug>` (and `<staging-file>` accordingly) for all subsequent steps, then return to Step 3 with the new value.

### Step 4 — Ensure .plans/ directory

Already guaranteed by Step 0 (`mkdir -p .plans/` runs during environment validation, before `@senior`'s staging write in Step 1). Nothing to do here.

### Step 5 — Add .plans/ to the target repo's .gitignore

Run via `bash`:
```bash
if [ ! -f .gitignore ]; then
  printf '.plans/\n' > .gitignore
elif ! grep -q '^\.plans/$' .gitignore; then
  printf '.plans/\n' >> .gitignore
fi
```
If the target repo has no `.gitignore`, this creates it with the line `.plans/`. If it already exists but `.plans/` does not appear in it, this appends the line `.plans/` at the end. This is idempotent: if it is already there, it does not duplicate it.

### Step 6 — Promote the plan

The plan body is already on disk in the staging file `<staging-file>` (`.plans/.staging-<slug>.md`) that `@senior` wrote, and it has passed the on-disk placeholder + front-matter gates (Step 1.5). Promotion is a token-free file operation performed via `bash` — you NEVER load, re-type, or delegate the plan body. Run the branch matching the mode resolved in Step 3, from the repo root:

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
- No `@applier` delegation and no orchestrator heredoc: the file is moved/appended as bytes already written by its author (`@senior`). There is zero plan-content re-emission.
- Verifier after promotion (any mode): `test -f .plans/<slug>.md && head -1 .plans/<slug>.md | grep -q '^---$'`.
- If any `mv`/`cat`/`printf` fails (e.g. the staging file is missing): stop with `BLOCKED: staging file <staging-file> missing or promotion failed`; do not attempt to reconstruct the plan body.

### Step 7 — Create/update .plans/current symlink

Run from the target repo, via `bash`:
```bash
cd <repo-root> && ln -sfn <slug>.md .plans/current
```
The symlink is relative (points to `<slug>.md`, not to the absolute path).

### Step 8 — Confirm to the user

Report with a single line:
```
Plan creado: .plans/<slug>.md (N fases, M pasos). Lanzar con /execute-plan.
```
Where N and M are taken from the `STAGED:` line returned by `@senior` (`phases=N, steps=M` fields).

## Final output

A single confirmation line:

```
Plan creado: .plans/<slug>.md (N fases, M pasos). Lanzar con /execute-plan.
```
