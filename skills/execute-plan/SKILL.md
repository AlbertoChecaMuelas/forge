---
description: Executes a multi-step plan from .plans/<slug>.md, delegating [A] steps to applier and [T] steps to tech, with a review checkpoint (template-filled subagent, model opus) at the midpoint phase and at plan close (max 2 per plan).
argument-hint: "[path-to-plan.md]"
disable-model-invocation: true
---

You are the orchestrator of the `/execute-plan` skill. Your job is to iterate through the plan step by step, delegate execution to the correct agent based on the `[A]`/`[T]` label, and dispatch the review subagent at checkpoints.

## Argument

`$ARGUMENTS` is the optional path to the plan file. If empty, use `.plans/current` (symlink to the active plan).

---

## Flow

### Step 0 — Resolve plan path

1. If `$ARGUMENTS` is not empty: use that path as the plan file (relative to cwd or absolute).
2. If `$ARGUMENTS` is empty: resolve `.plans/current` in the current repo.
   - If `.plans/current` does not resolve to a readable file: stop with:
     ```
     No se encontró .plans/current. Ejecuta /create-plan primero para generar un plan.
     ```
3. Read the full contents of the plan file.

### Step 1 — Parse the plan

From the plan's YAML front-matter, extract:
- `slug`
- `current_phase` (phase to resume from if the plan was paused)
- `current_step` (step to resume from)
- `target_branch` (branch where the work lands)
- `status` (`pending`, `in_progress`, `completed`)
- `repo`
- `last_review_sha` (SHA of HEAD at the last reviewer dispatch; written by the orchestrator, not the plan author)
- `review_rounds` (integer; starts at 0 at the beginning of each checkpoint, incremented by 1 after each re-review; reset to 0 when the next checkpoint begins; read and persisted by the orchestrator)

Additionally, the plan body may contain an optional `## Risks verified by reviewer` section at the end, with bullets `- <item> (phases A-B)` where A-B is the phase range covered by that reviewer pass. This section is maintained by `/execute-plan` (not the plan author). If it does not exist, do nothing; it will be created on-demand when the first `VERIFIED:` arrives.

If the front-matter is missing or unreadable: stop with `El front-matter del plan no es válido o está ausente. Revisa el fichero del plan.`.

If `status == "completed"`: inform the user that the plan is already complete and stop.

### Step 2 — Mark as in_progress

If `status != "in_progress"`:
1. Update the front-matter: `status: in_progress`, add `started_at: <ISO-timestamp>`.
2. This edit is made to the plan file (not to the repo, since `.plans/` is in `.gitignore`).

### Step 3 — Verify and prepare the git branch

1. Get the current branch: `git rev-parse --abbrev-ref HEAD`.
2. Cases:
   - **Branch `master` or `main`**: create and switch to `target_branch` with `git checkout -b <target_branch>`.
   - **Already on `target_branch`**: continue without changes.
   - **Other branch**: ask the user:
     ```
     La rama actual es '<current-branch>' pero el plan espera '<target_branch>'.
     ¿Continuar en la rama actual (c) o cambiar a <target_branch> (t)?
     ```
     Act according to the response.
3. Verify the working tree is clean (`git status --porcelain`). If there are uncommitted changes unrelated to the plan, inform the user and wait for instruction.

### Step 4 — Iterative step loop

See `reference/batch-algorithm.md` for the full batch construction algorithm, `[A]`/`[T]` dispatch rules, and batch error-handling flows.

### Step 5 — Review checkpoint trigger

See `reference/reviewer-and-close.md` for the phase-count-based checkpoint rule, the template-dispatch mechanism (`reference/review-template.md`, model opus), and processing of `OK_PHASE` / `FINDINGS_PHASE` / `BLOCKED_REVIEW` returns.

### Step 6 — Plan close

See `reference/reviewer-and-close.md` for the mandatory final review dispatch, global verifier execution, and front-matter completion.

### Step 7 — Final summary for the user

Report:
- Number of completed steps and closed phases.
- Number of commits created and the hash range (`<start-hash>..<end-hash>`).
- Follow-ups if any (design findings accepted as such by senior).
- Reminder: branch `<target_branch>` is ready, no push has been done.

---

## Progress tracking in the plan

- The plan is edited **at each step** to reflect progress (checkboxes `[ ]` → `[x]` and front-matter).
- **The plan is NOT committed** (`.plans/` is in `.gitignore` of the target repo).
- The symlink `.plans/current` is kept pointing to the active plan throughout execution.
- If the user pauses execution: state is persisted in the front-matter (`current_phase`, `current_step`). When `/execute-plan` is re-launched (no args), it reads `.plans/current` and resumes from where it left off.

---

## Hard constraints

- **NEVER `git push`**: blocked by arsenal settings.
- **NEVER merge or close PRs**: that is the user's responsibility.
- **NEVER touch files outside the active step's scope**: applier enforces this; tech has the judgment to flag it.
- **Máximo UNA re-review por checkpoint (midpoint y final), respaldada por el contador `review_rounds` en el front-matter del plan; los hallazgos que persistan tras esa re-review pasan como follow-up (impl→tech, design→senior), no como re-review adicional.**
- **Do not include the plan as a commit file**: never `git add .plans/`.
- **Bounded batching of `[A]` steps**: `/execute-plan` MAY batch consecutive `[A]` steps within the same phase into a single `applier` invocation, subject to the boundary rules in `reference/batch-algorithm.md`. `[T]` steps are always delegated individually to `tech`. Mixed `[A]`+`[T]` batches are forbidden. The audit trail (one checkbox flip per step, one commit per committing step) is preserved by `applier` executing the batch sequentially.
- **Safe deletion pattern in `[A]` steps**: any plan step that deletes files or symlinks using shell variables MUST use a guarded pattern, never raw `rm -f "$VAR/..."` with bare interpolation. Accepted patterns: for symlinks: `[ -L "$path" ] && rm "$path"`; for files in a known dir: `[ -n "$DEST" ] && [ -f "$DEST/$name" ] && rm "$DEST/$name"`. Reason: Claude Code's permissions hook flags raw `rm -f` with interpolated variables and forces manual approval, breaking automated execution.

---

## Recovery after pause

If the plan was paused (previous session interrupted):
1. `/execute-plan` (no args) reads `.plans/current`.
2. Parses `current_phase` and `current_step` from the front-matter.
3. Resumes from that step: skips steps already marked `[x]`.
4. Does not re-execute completed steps.

The reviewer trigger is phase-count-based (not commit-based), so resuming after a pause does not affect when reviewer is invoked: midpoint and final calls are determined by phase positions, which are persisted in the plan.

---

## How to invoke subagents

- Use the `Task` tool with the appropriate `subagent_type` (`applier`, `tech`, `senior`).
- Always pass the necessary context: current step, plan path, literal instructions (for applier), success criteria (for tech).
- **Review checkpoints do not use a resident agent.** Read `reference/review-template.md`, substitute `{BASE_SHA}`, `{HEAD_SHA}`, `{PLAN_STEP}` (plan path + phase range, e.g. "phases 1..ceil(P/2)") and `{SCOPE}`, and dispatch a FRESH generic subagent whose entire prompt is the filled template, with `model: opus`. If the dispatch fails with an infrastructure error (no return code), apply the standard infra-failure protocol: stop, surface `Fallo de infraestructura del subagente review: <error>` to the user, no retry, no re-route.

---

## References

The following reference files contain the full algorithm and protocol details. Read them when executing the corresponding steps.

- `reference/batch-algorithm.md` — Full batch construction algorithm for Step 4: `[A]`/`[T]` dispatch rules, size cap, phase boundaries, `OK_BATCH` / `BLOCKED_BATCH` handling.
- `reference/reviewer-and-close.md` — Review checkpoint rules for Steps 5 and 6: phase-count-based dispatch, `OK_PHASE` / `FINDINGS_PHASE` / `BLOCKED_REVIEW` processing, `VERIFIED:` bullet persistence, and plan-close flow.
- `reference/review-template.md` — The review prompt with `{BASE_SHA}` / `{HEAD_SHA}` / `{PLAN_STEP}` / `{SCOPE}` placeholders, dispatched as a fresh subagent at each checkpoint.
