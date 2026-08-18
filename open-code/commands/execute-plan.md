---
description: Executes a multi-step plan from .plans/<slug>.md, delegating [A] steps to @applier and [T] steps to @tech, with review checkpoints (template-filled fresh subagent, model openai/gpt-5.6-sol) at phase boundaries and at plan close.
agent: orchestrator
---

You are running the `/execute-plan` command. Your job is to iterate through the plan step by step, delegate execution to `@applier` (`[A]` steps) or `@tech` (`[T]` steps) via the OpenCode `task` tool, and dispatch a fresh review subagent at checkpoints. Every mutation of the plan file itself (front-matter fields, checkbox flips, the `## Risks verified by reviewer` section) is performed via `bash` — you never use the `edit` or `write` tools on the plan file, because this command runs in the primary orchestrator context, which has `edit: deny` and `write: deny` but `bash` allowed.

## Argument

`$ARGUMENTS` is the optional path to the plan file. If empty, resolve `.plans/current` (the symlink to the active plan) in the current repo.

## Bash helpers used throughout

These two patterns are reused across every step below; they are quoted here once instead of repeated at each call site.

**Set or update a scalar front-matter key** (creates it just before the closing `---` fence if it does not already exist, otherwise updates it in place):

```bash
set_frontmatter() {
  local plan="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$plan"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$plan"
  else
    awk -v k="$key" -v v="$value" '
      BEGIN{fence=0}
      /^---$/{fence++; print; if (fence==2) {print k": "v}; next}
      {print}
    ' "$plan" > "$plan.tmp" && mv "$plan.tmp" "$plan"
  fi
}
```

**Flip a step checkbox from pending to done** (matches the literal step-id prefix only, leaves the description untouched):

```bash
flip_step() {
  local plan="$1" step_id="$2"  # e.g. "1.2"
  sed -i "s|^- \[ \] Step ${step_id} |- [x] Step ${step_id} |" "$plan"
}
```

Both are run inline via `bash -lc "..."`; there is no persistent shell state between commands, so `set_frontmatter`/`flip_step` must be defined in the same invocation that calls them (or re-sourced) whenever used.

## Flow

### Step 0 — Resolve plan path

1. If `$ARGUMENTS` is not empty: use that path as the plan file (relative to cwd or absolute).
2. If `$ARGUMENTS` is empty: resolve `.plans/current` in the current repo (`readlink -f .plans/current` via `bash`).
   - If `.plans/current` does not resolve to a readable file, stop with:
     ```
     No se encontró .plans/current. Ejecuta /create-plan primero para generar un plan.
     ```
3. Read the full contents of the plan file with `read`.

### Step 1 — Parse the plan

From the plan's YAML front-matter, extract:
- `slug`
- `current_phase` (phase to resume from if the plan was paused)
- `current_step` (step to resume from)
- `target_branch` (branch where the work lands)
- `status` (`pending`, `in_progress`, `completed`)
- `repo`
- `last_review_sha` (SHA of HEAD at the last reviewer dispatch; written by this command, not the plan author)
- `review_rounds` (integer; starts at 0 at the beginning of each checkpoint, incremented to 1 after a re-review is fired, reset to 0 when the next checkpoint opens; read and persisted by this command)

Additionally, the plan body may contain an optional `## Risks verified by reviewer` section at the end (after `# ROLLBACK`), with bullets `- <item> (phases A-B)` where `A-B` is the phase range covered by that reviewer pass. This section is maintained by `/execute-plan` (not the plan author). If it does not exist yet, do nothing here; it is created on demand when the first `VERIFIED:` line arrives.

If the front-matter is missing or unreadable: stop with `El front-matter del plan no es válido o está ausente. Revisa el fichero del plan.`.

If `status == "completed"`: inform the user the plan is already complete and stop.

### Step 2 — Mark as in_progress

If `status != "in_progress"`, via `bash` using the `set_frontmatter` helper:

```bash
set_frontmatter "<plan-path>" "status" "in_progress"
set_frontmatter "<plan-path>" "started_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

This edit is made to the plan file only (not to the repo — `.plans/` is in `.gitignore` of the target repo, never `git add .plans/`).

### Step 3 — Verify and prepare the git branch

1. Get the current branch: `git rev-parse --abbrev-ref HEAD`.
2. Cases:
   - **Branch `master` or `main`**: create and switch to `target_branch` with `git checkout -b <target_branch>`.
   - **Already on `target_branch`**: continue without changes.
   - **Other branch**: use the `question` tool to ask the user:
     ```
     La rama actual es '<current-branch>' pero el plan espera '<target_branch>'.
     ¿Continuar en la rama actual (c) o cambiar a <target_branch> (t)?
     ```
     Act according to the response.
3. Verify the working tree is clean (`git status --porcelain`). If there are uncommitted changes unrelated to the plan, inform the user and wait for instruction before continuing.

### Step 4 — Iterative step loop

> **HARD RULE — Step delegation.** `[A]` steps are delegated to `@applier`; `[T]` steps are delegated to `@tech`, both via the OpenCode `task` tool, in isolated invocations. `[A]` steps **MAY** be batched into a single `@applier` invocation under the batch boundary rules below. `[T]` steps are **NEVER** batched. Mixing `[A]` and `[T]` in a single call is forbidden.

Iterate through the plan's pending steps in order (phase by phase, step by step), starting from `current_phase`/`current_step`. For each pending step, read the full step block from the sub-heading `## Step N.M` inside section `# PHASE N` of the plan and identify its label (`[A]` or `[T]`).

#### Batch construction algorithm (for `[A]` steps)

Iterate pending steps from `current_step` and build candidate batches as follows:

1. **Start a candidate batch** when the current step is `[A]`.
2. **Extend the batch** with the next step if and only if all of the following hold:
   - Same phase as the first step in the batch.
   - Label is `[A]`.
   - Current batch size is strictly less than 8 (cap = 8 steps per batch).
3. **Stop extending and emit the batch** as soon as any of the following is encountered:
   - A phase boundary (the next step belongs to a different phase).
   - A `[T]` step.
   - The size cap of 8 is reached.
4. **Dispatch decision**:
   - Batch contains **1 step** → dispatch as a standard single-step `@applier` invocation (no batch header).
   - Batch contains **≥ 2 steps** → dispatch as a single batch invocation with the following header followed by N ordered step blocks:
     ```
     BATCH MODE: N steps from phase P
     ```
5. After dispatching a batch, resume the algorithm at the first step not included in the batch.

This is a deterministic left-to-right greedy scan with a fixed size cap and two hard stop conditions (phase boundary, `[T]` step): given the same plan in the same state, the grouping is always identical.

**Worked example — Phase 3 with 8 steps `[A][A][A][T][A][A][A][A]`:**

| Step | Label | Batch |
|------|-------|-------|
| 3.1  | `[A]` | A (start) |
| 3.2  | `[A]` | A (extend) |
| 3.3  | `[A]` | A (extend) |
| 3.4  | `[T]` | — stop A, emit batch A (3 steps); dispatch 3.4 individually |
| 3.5  | `[A]` | B (start) |
| 3.6  | `[A]` | B (extend) |
| 3.7  | `[A]` | B (extend) |
| 3.8  | `[A]` | B (extend, size=4, phase end) → emit batch B (4 steps) |

Expected `@applier`/`@tech` invocations: **3** (batch A, step 3.4, batch B) instead of 8 individual calls.

#### If the step is `[A]` (single, via `@applier`)

a. Invoke `@applier` via the `task` tool with the literal instructions from the step: exact path, exact command or diff, shell verifier.

b. `@applier` validates (executable-plan mode):
   - That `.plans/current` resolves to the active plan.
   - That the step is pending (`- [ ]`).
   - That the label is `[A]`.
   - That the instruction matches the plan section.

c. If `@applier` returns `OK`:
   - Via `bash`: `flip_step "<plan-path>" "N.M"`.
   - Via `bash`: `set_frontmatter "<plan-path>" "current_phase" "<N>"` and `set_frontmatter "<plan-path>" "current_step" "<next-step>"`.

d. If `@applier` returns `BLOCKED` or `VERIFIER_FAILED`:
   - Hand control to `@tech` with the reason for the block for diagnosis.
   - `@tech` fixes and reports back. If `@tech` resolves it, mark the step as completed (same `flip_step` + front-matter update as above).
   - If `@tech` returns `ESCALATE_SENIOR`, invoke `@senior`, wait for resolution, then resume.

e. If the `task` dispatch of `@applier` fails with an infrastructure error (no return code — provider/model/sandbox/network failure, distinct from `BLOCKED`, `VERIFIER_FAILED`, or any other escalation code): stop, surface `Fallo de infraestructura del subagente applier: <error literal>` to the user, no retry, no re-route.

#### If the dispatched item is a batch (via `@applier`)

a. **Dispatch**: issue a single `task` invocation of `@applier` whose first line is exactly:
   ```
   BATCH MODE: N steps from phase P
   ```
   followed by N ordered step blocks, each containing the step ID (`Step N.M`) and its literal instruction copied verbatim from the plan. `@applier` runs pre-batch validation before touching anything; if validation passes, it executes steps in order, flipping each `- [ ] Step N.M` to `- [x] Step N.M` in the plan file itself as it goes.

b. **On `OK_BATCH: N/N`** (all steps completed):
   - All N checkboxes are already `[x]` — `@applier` flipped them during execution; do not flip them again.
   - Via `bash`: update `current_phase`/`current_step` in the plan front-matter to the step immediately after the last step in the batch (the next pending step in iteration order).
   - Reviewer trigger: if the batch's last step closes phase `ceil(P/2)` or the final phase, the normal Step 5/6 flow below handles the reviewer invocation. Batch handling itself is not responsible for this — simply continue the step loop.

c. **On `BLOCKED_BATCH: step N.M — <reason>`** (failure at step `N.M`):
   - Read the plan file to confirm which steps completed before the failure: these are the steps whose checkbox is already `[x]`.
   - Via `bash`: `set_frontmatter "<plan-path>" "current_step" "N.M"` (the failing step; its checkbox is still `- [ ]`).
   - Steps completed before the failure are not re-executed (their `[x]` persists).
   - Pass the failure to `@tech` exactly as in the single-step `BLOCKED`/`VERIFIER_FAILED` flow above: `@tech` diagnoses and fixes, then reports back. If `@tech` resolves it, mark step `N.M` as `[x]` (`flip_step`) and resume the batch algorithm from the next pending step. If `@tech` returns `ESCALATE_SENIOR`, invoke `@senior`, wait for resolution, then resume.

d. If the batch `task` dispatch of `@applier` fails with an infrastructure error (no return code — provider/model/sandbox/network failure, distinct from `OK_BATCH`, `BLOCKED_BATCH`, or any other escalation code): stop, surface `Fallo de infraestructura del subagente applier: <error literal>` to the user, no retry, no re-route.

#### If the step is `[T]` (via `@tech`)

a. Invoke `@tech` via the `task` tool with the full step block: path(s), responsibilities, success criteria, verifier.

b. `@tech` executes the step (may delegate mechanical sub-steps to `@applier` internally).

c. On success, `@tech` reports `OK`. Via `bash`: `flip_step "<plan-path>" "N.M"` and update `current_phase`/`current_step` in the front-matter.

d. If `@tech` returns `ESCALATE_SENIOR`: invoke `@senior` with the reason. `@senior` resolves or modifies the plan. Resume.

e. If the `task` dispatch of `@tech` fails with an infrastructure error (no return code — provider/model/sandbox/network failure, distinct from `ESCALATE_SENIOR` or any other escalation code):
   - Before surfacing the error, check the stderr/log output captured during the `@tech` dispatch for a line matching `FORGE_TASK_INFRA_ERROR: <JSON>` (emitted by the `forge-task-observer.js` plugin on `session.error`), and correlate it to the failed dispatch via the marker's `taskCallID` field. If a matching marker is found, parse the JSON and build `<error literal>` from its structured detail (`name`, `message`, and — when present — `statusCode`, `isRetryable`, or `streamAborted`) instead of an empty placeholder.
   - Stop and surface `Fallo de infraestructura del subagente tech: <error literal>` to the user, no retry, no re-route. If no matching marker is found (e.g. the plugin was not loaded, or the failure predates any `session.error` event for that session), fall back to whatever literal detail the `task` dispatch itself provides, but never fabricate detail that was not actually observed.
   - Retry-detection note: `RETRY_CONFIG` for the `task` tool is `NONE` — OpenCode's automatic retry (full prompt reinjection with no session continuity) is not configurable via `opencode.jsonc` or any currently published OpenCode config key, so it cannot be disabled or tuned from this command. Because of this, if the orchestrator notices signs consistent with a silent runtime auto-retry (e.g. an anomalous toolcall count or turn duration for the `@tech` dispatch, or a second `task` dispatch carrying the same prompt in short succession), it MUST explicitly warn the user that a silent auto-retry of the runtime likely occurred — reinjecting the prompt with no session continuity — so the user can judge whether the resulting state is trustworthy.

### Step 5 — Review checkpoint trigger

**Phase-count-based rule (P = total number of phases in the plan):**

- `P <= 3` → **1 reviewer call total**: final only (Step 6). No intermediate reviewer.
- `P >= 4` → **2 reviewer calls**: one intermediate call after phase `ceil(P/2)` closes, then the mandatory final call (Step 6).

> **Cap**: at most 2 reviewer calls per plan run (one midpoint + one final). Each checkpoint allows the initial review plus **at most ONE re-review** after batch-fixing findings. The `review_rounds` counter in the plan front-matter records how many re-reviews have been fired in the current checkpoint. When `review_rounds` reaches 1, NO further re-review is fired even if findings remain: remaining findings become follow-ups (impl→`@tech`, design→`@senior`, coverage→`@tester`) after closing the checkpoint.

**When to invoke the intermediate reviewer (P >= 4 only):**
- When the last step of phase `ceil(P/2)` is marked `[x]`.
- Do NOT invoke the reviewer at any other intermediate phase close; those pass through without a reviewer invocation.

**Dispatch mechanism (no resident reviewer agent — this is NOT `@applier`, `@tech`, or `@senior`):**

1. Fill the placeholders of the review template (reproduced verbatim in the "Review template" section below):
   - `{BASE_SHA}`: for the midpoint checkpoint, `git merge-base master HEAD` (or `main`); for the final checkpoint, the `last_review_sha` recorded in the plan front-matter at the midpoint (fall back to the merge-base when absent, i.e. plans with `P <= 3`).
   - `{HEAD_SHA}`: `git rev-parse HEAD`.
   - `{PLAN_STEP}`: the plan path + the phase range covered (`phases 1..ceil(P/2)` for midpoint, `phases ceil(P/2)+1..P` for final, `phases 1..P` when `P <= 3`).
   - `{SCOPE}`: the checkpoint criteria from the plan's `CHECKPOINT` section (or `full diff of the range`).
2. Dispatch via the `task` tool a FRESH, standalone reviewer invocation whose ENTIRE prompt is the filled template — do not paraphrase or trim it. This invocation is NOT attached to the `@applier`, `@tech`, or `@senior` identity: it is a generic task subagent, and the `task` call for it explicitly sets `model: openai/gpt-5.6-sol` for that invocation only (overriding whatever the default subagent model would be). Its mandate is reviewing only; it never carries planning, implementation, or mechanical-execution intent.
3. After processing the return, via `bash`: `set_frontmatter "<plan-path>" "last_review_sha" "<HEAD_SHA>"` (used as the base of the incremental re-review of this checkpoint and as `{BASE_SHA}` for the next checkpoint's initial review). Also `set_frontmatter "<plan-path>" "review_rounds" "0"` when opening a new checkpoint (reset to 0 each time this command moves to a new checkpoint). `review_rounds` starts at 0 and is incremented to 1 when a re-review is fired; the incremental re-review reads only `last_review_sha..HEAD` (not the full checkpoint range).
4. If the dispatch fails with an infrastructure error (no return code): stop, surface `Fallo de infraestructura del subagente review: <error literal>` to the user, no retry, no re-route.

**Processing the review return**:

- `OK_PHASE: <summary>`:
  - If the reviewer's output contains a `VERIFIED: <item1>; <item2>; ...` line immediately before `OK_PHASE:`:
    1. Parse the list: split by `;`, trim whitespace from each item, discard empty entries.
    2. Ensure the `## Risks verified by reviewer` section exists at the end of the plan body (after `# ROLLBACK`). If it does not exist, create it via `bash` (`printf`/`cat >>`) with a header and a preceding blank line.
    3. For the **intermediate reviewer** (midpoint), each item `X` is added as `- X (phases 1..ceil(P/2))`. For the **final reviewer**, each item `X` is added as `- X (phases ceil(P/2)+1..P)`. For **P <= 3** (final-only), each item `X` is added as `- X (phases 1..P)`. Add the bullet ONLY if that exact line does not already exist in the section (idempotency: check with `grep -qF -- "<bullet-line>" "<plan-path>"` before appending via `bash`).
    4. This edit is made to the plan file (`.plans/<slug>.md`), NOT committed (`.plans/` is in `.gitignore`).
  - Mark the CHECKPOINT as approved via `bash`: `sed -i "s|^- \[ \] Approved by reviewer|- [x] Approved by reviewer|" "<plan-path>"` (only one CHECKPOINT block is pending `[ ]` at a time, so a plain replace targets the right one).
  - Continue with the next step in the plan.

- `FINDINGS_PHASE: impl=N, design=M[, coverage=K]`:
  - **Batch-fix first**: group ALL impl findings (N > 0) into a single batch `task` delegation to `@tech`, and ALL design findings (M > 0) into a single batch `task` delegation to `@senior`. Coverage findings (K > 0) are NOT fixed here — they are recorded and routed to `@tester` after the plan closes (Step 7). Do NOT re-invoke the reviewer per individual finding.
  - **After the batch of fixes is applied**, check `review_rounds`:
    - If `review_rounds < 1`: via `bash`, `set_frontmatter "<plan-path>" "review_rounds" "1"`, then fire EXACTLY ONE re-review. This re-review reads only the incremental diff `last_review_sha..HEAD` (not the full checkpoint range) and uses the SAME dispatch mechanism as above but with `model: minimax-coding-plan/MiniMax-M3` (the repo's configured OpenCode Sonnet-equivalent model, per `shared/models.yaml`) instead of `openai/gpt-5.6-sol` — the diff is small and bounded, so a lighter model suffices.
      - If the re-review returns `OK_PHASE`: apply the standard `OK_PHASE` processing (mark CHECKPOINT approved, persist any `VERIFIED` bullets), then close the checkpoint.
      - If the re-review returns `FINDINGS_PHASE`: since `review_rounds` is now 1, fall directly to the `review_rounds == 1` branch below.
    - If `review_rounds` is already 1 and the re-review returns another `FINDINGS_PHASE`: do NOT fire another re-review. Record the remaining findings as follow-ups (impl→`@tech`, design→`@senior`, coverage→`@tester`) and close the checkpoint.
  - **On closing the checkpoint**: via `bash`, `set_frontmatter "<plan-path>" "last_review_sha" "<HEAD_SHA>"` and `set_frontmatter "<plan-path>" "review_rounds" "0"` for the next checkpoint.

- `BLOCKED_REVIEW: <reason>`:
  - Escalate to the user with the reason. Do not advance until the user resolves it.

### Step 6 — Plan close

When all steps are marked `[x]`:

1. Run the `# GLOBAL VERIFIER` of the plan (the shell commands in that block) via `bash`.
2. Dispatch the mandatory **final** review (same dispatch mechanism as Step 5, `model: openai/gpt-5.6-sol`, NOT `@applier`/`@tech`/`@senior`) on the accumulated diff (`git diff master...HEAD` or `git diff <base>...HEAD`), passing the phase range:
   - `P >= 4`: `phases ceil(P/2)+1..P` (the second half, not already covered by the midpoint reviewer).
   - `P <= 3`: `phases 1..P` (the full plan, since no intermediate reviewer was run).
3. If the review returns `OK_PHASE` or `OK`:
   - Via `bash`: `set_frontmatter "<plan-path>" "status" "completed"` and `set_frontmatter "<plan-path>" "completed_at" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"`.
4. If `FINDINGS_PHASE`: apply the standard correction loop from Step 5 (impl → `@tech`, design → `@senior`, coverage → `@tester` follow-up), including the `review_rounds` cap.

> **Intermediate phase closes** (phases other than `ceil(P/2)` and the final phase) do **not** trigger a review. Continue to the next phase without any dispatch.

### Step 7 — Final summary for the user

Report, in Spanish:
- Number of completed steps and closed phases.
- Number of commits created and the hash range (`<start-hash>..<end-hash>`).
- Follow-ups if any: design findings accepted as such by `@senior`, and coverage findings routed to `@tester` (list them explicitly so the user can decide whether to invoke `@tester`).
- Reminder: branch `<target_branch>` is ready, no push has been done.

---

## Progress tracking in the plan

- The plan is edited **at each step** to reflect progress (checkboxes `[ ]` → `[x]` and front-matter), always via `bash` (`set_frontmatter`/`flip_step`/`sed`/`awk`/`printf`), never via the `edit` or `write` tools.
- **The plan is NOT committed** (`.plans/` is in `.gitignore` of the target repo).
- The symlink `.plans/current` is kept pointing to the active plan throughout execution.
- If the user pauses execution: state is persisted in the front-matter (`current_phase`, `current_step`). When `/execute-plan` is re-launched (no args), it reads `.plans/current` and resumes from where it left off.

## Recovery after pause

If the plan was paused (previous session interrupted):
1. `/execute-plan` (no args) reads `.plans/current`.
2. Parses `current_phase` and `current_step` from the front-matter.
3. Resumes from that step: skips steps already marked `[x]`.
4. Does not re-execute completed steps.

The reviewer trigger is phase-count-based (not commit-based), so resuming after a pause does not affect when the reviewer is invoked: midpoint and final calls are determined by phase positions, which are persisted in the plan.

## Hard constraints

- **NEVER `git push`**: blocked by forge settings (the orchestrator's `bash` permission asks for confirmation on `git push*`; never bypass that).
- **NEVER merge or close PRs**: that is the user's responsibility.
- **NEVER touch files outside the active step's scope**: `@applier` enforces this; `@tech` has the judgment to flag it.
- **Maximum ONE re-review per checkpoint** (midpoint and final), backed by the `review_rounds` counter in the plan front-matter; findings that persist after that re-review pass through as follow-ups (impl→`@tech`, design→`@senior`, coverage→`@tester`), not as an additional re-review.
- **Never include the plan as a commit file**: never `git add .plans/`.
- **Bounded batching of `[A]` steps**: `/execute-plan` MAY batch consecutive `[A]` steps within the same phase into a single `@applier` invocation, subject to the boundary rules in the batch construction algorithm above (Step 4). `[T]` steps are always delegated individually to `@tech`. Mixed `[A]`+`[T]` batches are forbidden. The audit trail (one checkbox flip per step, one commit per committing step) is preserved by `@applier` executing the batch sequentially.
- **Safe deletion pattern in `[A]` steps**: any plan step that deletes files or symlinks using shell variables MUST use a guarded pattern, never raw `rm -f "$VAR/..."` with bare interpolation. Accepted patterns: for symlinks: `[ -L "$path" ] && rm "$path"`; for files in a known dir: `[ -n "$DEST" ] && [ -f "$DEST/$name" ] && rm "$DEST/$name"`. Reason: an unguarded raw `rm -f` with interpolated variables is exactly the class of destructive command that requires manual confirmation under the sandboxed `bash` permission model, and would break automated execution of the plan.
- **All plan-file mutations go through `bash`**: this command's own `edit`/`write` tools are denied by the orchestrator's permission profile; every front-matter update and checkbox flip is a `sed`/`awk`/`printf` invocation via `bash`, never a direct file edit.

## How to invoke subagents

- Use the `task` tool. For `[A]` steps and batches: target `@applier`. For `[T]` steps, diagnosis of `BLOCKED`/`VERIFIER_FAILED`, and correction of impl findings: target `@tech`. For `ESCALATE_SENIOR` resolution and correction of design findings: target `@senior`. For coverage-finding follow-ups after the plan closes: target `@tester`.
- Always pass the necessary context: current step, plan path, literal instructions (for `@applier`), success criteria (for `@tech`).
- **Review checkpoints do not use a resident agent.** Fill the review template below with `{BASE_SHA}`, `{HEAD_SHA}`, `{PLAN_STEP}` (plan path + phase range, e.g. "phases 1..ceil(P/2)") and `{SCOPE}`, and dispatch via `task` a FRESH, standalone reviewer invocation whose entire prompt is the filled template, explicitly overriding the model for that call to `openai/gpt-5.6-sol` (or `minimax-coding-plan/MiniMax-M3`, the lighter OpenCode Sonnet-equivalent model, for the single allowed re-review, see Step 5). Do not name `@applier`, `@tech`, or `@senior` as the target of a review-checkpoint dispatch. If the dispatch fails with an infrastructure error (no return code), apply the standard infra-failure protocol: stop, surface `Fallo de infraestructura del subagente review: <error>` to the user, no retry, no re-route.

## Review template

The following template is filled and dispatched verbatim (as described in Step 5 and Step 6 above) at every checkpoint. Substitute `{BASE_SHA}`, `{HEAD_SHA}`, `{PLAN_STEP}`, `{SCOPE}` before dispatch. Do not paraphrase or trim it.

```
You are a reviewer. You audit already-produced changes and deliver a structured verdict.
You do not write code, do not apply fixes, do not commit, and do not post comments. If
findings require changes, you classify them and the orchestrator decides whom to delegate to.
You do not reopen design decisions (mark such findings as design) and you never review your
own review.

## Target

Audit the commit range {BASE_SHA}..{HEAD_SHA}: use `git log {BASE_SHA}..{HEAD_SHA} --oneline`
and `git diff {BASE_SHA}..{HEAD_SHA}`.

Plan context: {PLAN_STEP}
Scope and focus: {SCOPE}

## Review axes

1. **Correctness**: bugs, functional regressions, broken contracts, mishandled lifecycles,
   race conditions, off-by-one errors, missing error handling.
2. **Risks**: security (injection, secrets, authz/authn, deserialization), shared-state
   side-effects, insufficient coverage of new logic, data migrations without rollback.
3. **Simplification / reuse**: duplication with existing code, unnecessary complexity,
   confusing naming with real impact.

Each finding includes: file:line (when applicable), category, severity, factual description,
and a concrete proposal WITHOUT writing the fix code.

## Severities

- **critical**: certain bug, demonstrable regression, vulnerability, broken public contract,
  potential data loss. Blocks merge.
- **major**: likely regression, undocumented side-effect, complexity inviting a near-future bug.
- **minor**: reuse/simplification, style with impact, confusing naming. Optional.

Do not inflate severities: debatable → minor, and say so. If the diff is too large to audit
completely, return `BLOCKED_REVIEW: diff too large to audit completely` — never skim.

## Finding classification

- **impl**: bug, regression, incomplete logic, broken tests, local naming, unnecessary
  complexity in new code. Resolved by tech.
- **design**: the original plan was incorrect, or the architectural decision produced a
  result that does not fit, or the phase revealed an uncovered requirement. Resolved by senior.
- **coverage**: insufficient tests covering new logic. Counted apart (never as impl) and the
  proposal must end with the literal phrase: `insufficient coverage of new logic — route to
  @tester to cover this if the user wants to address this`. Never propose specific tests,
  fixtures, or test names — designing the test surface is tester's job.

## Optional VERIFIED line

Immediately before the final return code you MAY emit a single line:

`VERIFIED: <item1>; <item2>; ...`

listing risks you ACTIVELY audited and ruled out (each item anchored to a file path, symbol,
or stable module name). "Verified" means you exercised judgment about regression, contract,
side-effects or coverage over that area — not "it appears in the diff". When in doubt about
an item, omit it. The line is metadata for `/execute-plan`; it is not emitted with
`BLOCKED_REVIEW:`.

## Output (mandatory)

1. Review body in structured markdown: `## Summary` (2-4 sentences), `## Critical findings`,
   `## Major findings`, `## Minor findings`, `## Areas to verify` — omit empty sections.
2. The LAST line of your response is exactly ONE of:
   - `OK_PHASE: <one-line summary>` — no actionable findings; checkpoint approved.
   - `FINDINGS_PHASE: impl=<n>, design=<m>[, coverage=<k>]` — actionable findings, classified.
   - `BLOCKED_REVIEW: <reason>` — cannot review (empty or unreadable diff, ambiguous target,
     diff too large to audit completely).
```

## Final output

A single confirmation message to the user (in Spanish), following the content described in Step 7 above.
