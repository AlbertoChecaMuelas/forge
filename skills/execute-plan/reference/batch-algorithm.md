### Step 4 — Iterative step loop

> **HARD RULE — Step delegation.** `[A]` steps are delegated to `applier`; `[T]` steps are delegated to `tech` in isolated invocations. `[A]` steps **MAY** be batched into a single `applier` invocation under the batch boundary rules documented below. `[T]` steps are **NEVER** batched. Mixing `[A]` and `[T]` in a single call is forbidden.

#### Batch construction algorithm

Iterate pending steps from `current_step` and build candidate batches as follows:

1. **Start a candidate batch** when the current step is `[A]`.
2. **Extend the batch** with the next step if and only if all of the following hold:
   - Same phase as the first step in the batch.
   - Label is `[A]`.
   - Current batch size is strictly less than 8 (cap = 8 steps per batch).
3. **Stop extending and emit the batch** as soon as any of the following is encountered:
   - A phase boundary (the next step belongs to a different phase).
   - An `[T]` step.
   - The size cap of 8 is reached.
4. **Dispatch decision**:
   - Batch contains **1 step** → dispatch as a standard single-step `applier` invocation (no batch header, no change from today's behavior).
   - Batch contains **≥ 2 steps** → dispatch as a single batch invocation with the following header followed by N ordered step blocks:
     ```
     BATCH MODE: N steps from phase P
     ```
5. After dispatching a batch, resume the algorithm at the first step not included in the batch.

> **Why this is deterministic**: the algorithm is a left-to-right greedy scan with a fixed size cap and two hard stop conditions (phase boundary, `[T]` step). Given the same plan in the same state, the grouping is always identical.

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

Expected applier/tech invocations: **3** (batch A, step 3.4, batch B) instead of 8 individual calls.

Iterate through the plan's pending steps in order (phase by phase, step by step), starting from `current_phase.current_step`.

For each step:

1. Read the full step block from the sub-heading `## Step N.M` inside section `# PHASE N` of the plan.
2. Identify the label: `[A]` or `[T]`.

#### If the step is `[A]` (applier):

a. Invoke `applier` with the literal instructions from the step: exact path, exact command or diff, shell verifier.

b. Applier will validate (in its executable-plan mode):
   - That `.plans/current` resolves to the active plan.
   - That the step is pending (`- [ ]`).
   - That the label is `[A]`.
   - That the instruction matches the plan section.

c. If applier returns `OK`:
   - Edit the plan: replace `- [ ] Step N.M` with `- [x] Step N.M` (that line only).
   - Update `current_phase` and `current_step` in the plan front-matter.

d. If applier returns `BLOCKED` or `VERIFIER_FAILED`:
   - Hand control to tech with the reason for the block for diagnosis.
   - Tech fixes and reports back. If tech resolves it, mark the step as completed.
   - If tech returns `ESCALATE_SENIOR`, invoke senior, wait for resolution, then resume.

#### If the dispatched item is a batch (applier):

a. **Dispatch**: issue a single `Task` invocation of `applier` whose first line is exactly:
   ```
   BATCH MODE: N steps from phase P
   ```
   followed by N ordered step blocks, each containing the step ID (`Step N.M`) and its literal instruction copied verbatim from the plan. Applier runs pre-batch validation before touching anything; if validation passes, it executes steps in order, flipping each `- [ ] Step N.M` to `- [x] Step N.M` in the plan file as it goes.

b. **On `OK_BATCH: N/N`** (all steps completed):
   - All N checkboxes are already `[x]` — applier flipped them during execution; do not flip them again.
   - Update `current_phase` and `current_step` in the plan front-matter to the step immediately after the last step in the batch (i.e., the next pending step in iteration order).
   - Reviewer trigger: if the batch's last step closes phase `ceil(P/2)` or the final phase, the normal `/execute-plan` flow (Steps 5/6) handles the reviewer invocation. Batch handling itself is not responsible for this — simply continue the step loop; Steps 5/6 will detect the phase close and invoke reviewer at the right moment.

c. **On `BLOCKED_BATCH: step N.M — <reason>`** (failure at step `N.M`):
   - Read the plan file to confirm which steps completed before the failure: these are the steps whose checkbox is already `[x]`.
   - Update `current_step` in the plan front-matter to `N.M` (the failing step; its checkbox is still `- [ ]`).
   - Steps completed before the failure are not re-executed (their `[x]` persists).
   - Pass the failure to tech exactly as in the single-step `BLOCKED`/`VERIFIER_FAILED` flow (bullet d above): tech diagnoses and fixes, then reports back. If tech resolves it, mark step `N.M` as `[x]` and resume the batch algorithm from the next pending step. If tech returns `ESCALATE_SENIOR`, invoke senior, wait for resolution, then resume.

#### If the step is `[T]` (tech):

a. Invoke `tech` with the full step block: path(s), responsibilities, success criteria, verifier.

b. Tech executes the step (may delegate mechanical sub-steps to applier internally).

c. On success, tech reports `OK`. Mark the step checkbox as `[x]` and update `current_phase` and `current_step` in the plan front-matter.

d. If tech returns `ESCALATE_SENIOR`: invoke senior with the reason. Senior resolves or modifies the plan. Resume.
