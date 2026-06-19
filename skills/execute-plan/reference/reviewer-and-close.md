### Step 5 — Reviewer trigger

**Phase-count-based rule (P = total number of phases in the plan):**

- `P <= 3` → **1 reviewer call total**: final only (Step 6). No intermediate reviewer.
- `P >= 4` → **2 reviewer calls**: one intermediate call after phase `ceil(P/2)` closes, then the mandatory final call (Step 6).

> **Cap**: at most 2 reviewer calls per plan run (one midpoint + one final). Each checkpoint allows the initial review plus **at most ONE re-review** after batch-fixing findings. The `review_rounds` counter in the plan front-matter records how many re-reviews have been fired in the current checkpoint. When `review_rounds` reaches 1, NO further re-review is fired even if findings remain: remaining findings become follow-ups (impl→tech, design→senior) after closing the checkpoint.

**When to invoke the intermediate reviewer (P >= 4 only):**
- When the last step of phase `ceil(P/2)` is marked `[x]`.
- Do NOT invoke reviewer at any other intermediate phase close; those pass through without a reviewer invocation.

**Dispatch mechanism (no resident reviewer agent):**

1. Read `reference/review-template.md` and substitute the placeholders:
   - `{BASE_SHA}`: for the midpoint checkpoint, `git merge-base master HEAD` (or `main`); for the final checkpoint, the `last_review_sha` recorded in the plan front-matter at the midpoint (fall back to the merge-base when absent, i.e. plans with `P <= 3`).
   - `{HEAD_SHA}`: `git rev-parse HEAD`.
   - `{PLAN_STEP}`: the plan path + the phase range covered (`phases 1..ceil(P/2)` for midpoint, `phases ceil(P/2)+1..P` for final, `phases 1..P` when `P <= 3`).
   - `{SCOPE}`: the checkpoint criteria from the plan's CHECKPOINT section (or `full diff of the range`).
2. Dispatch a FRESH generic subagent whose ENTIRE prompt is the filled template, with `model: opus`. Do not paraphrase or trim the template. Never use the built-in `Skill(skill="review")` — it audits GitHub PRs and does not implement the `OK_PHASE`/`FINDINGS_PHASE` protocol.
3. After processing the return, record `last_review_sha: <HEAD_SHA>` in the plan front-matter (used as the base of the incremental re-review of this checkpoint and as `{BASE_SHA}` for the next checkpoint's initial review). Also persist `review_rounds: 0` in the front-matter when opening a new checkpoint (reset to 0 each time the orchestrator moves to a new checkpoint). `review_rounds` starts at 0 and is incremented to 1 when a re-review is fired; the incremental re-review reads only `last_review_sha..HEAD` (not the full checkpoint range).
4. If the dispatch fails with an infrastructure error (no return code): stop, surface `Fallo de infraestructura del subagente review: <error literal>` to the user, no retry, no re-route.

**Processing the review return**:

- `OK_PHASE: <summary>`:
  - If the reviewer's output contains a `VERIFIED: <item1>; <item2>; ...` line immediately before `OK_PHASE:`:
    1. Parse the list: split by `;`, trim whitespace from each item, discard empty entries.
    2. Ensure the `## Risks verified by reviewer` section exists at the end of the plan body (after `# ROLLBACK`). If it does not exist, create it with a header and a preceding blank line.
    3. For the **intermediate reviewer** (midpoint), each item `X` is added as `- X (phases 1..ceil(P/2))`.
       For the **final reviewer**, each item `X` is added as `- X (phases ceil(P/2)+1..P)`.
       For **P <= 3** (final-only), each item `X` is added as `- X (phases 1..P)`.
       Add the bullet ONLY if that exact line does not already exist in the section (exact idempotency).
    4. This edit is made to the plan file (`.plans/<slug>.md`), NOT committed (`.plans/` is in `.gitignore`).
  - Mark the CHECKPOINT as approved: replace `- [ ] Approved by reviewer` with `- [x] Approved by reviewer`.
  - Continue with the next step in the plan.

- `FINDINGS_PHASE: impl=N, design=M`:
  - **Batch-fix first**: group ALL impl findings (N > 0) into a single batch delegation to tech, and ALL design findings (M > 0) into a single batch delegation to senior. Do NOT re-invoke the reviewer per individual finding.
  - **After the batch of fixes is applied**, check `review_rounds`:
    - If `review_rounds < 1`: increment `review_rounds` to 1, persist it in the plan front-matter, and fire EXACTLY ONE re-review. This re-review reads only the incremental diff `last_review_sha..HEAD` (not the full checkpoint range) and uses **Sonnet** (not Opus) — the diff is small and bounded.
      - If the re-review returns `OK_PHASE`: apply the standard `OK_PHASE` processing (mark CHECKPOINT approved, persist any VERIFIED bullets), then close the checkpoint.
      - If the re-review returns `FINDINGS_PHASE`: since `review_rounds` is now 1, fall directly to the `review_rounds == 1` branch below.
    - If `review_rounds` is already 1 and the re-review returns another `FINDINGS_PHASE`: do NOT fire another re-review. Record the remaining findings as follow-ups (impl→tech, design→senior) and close the checkpoint.
  - **On closing the checkpoint**: update `last_review_sha` to `HEAD` and reset `review_rounds` to 0 in the plan front-matter for the next checkpoint.

- `BLOCKED_REVIEW: <reason>`:
  - Escalate to the user with the reason. Do not advance until the user resolves it.

### Step 6 — Plan close

When all steps are marked `[x]`:

1. Run the `# GLOBAL VERIFIER` of the plan (the shell commands in the block).
2. Dispatch the mandatory **final** review (same template mechanism) on the accumulated diff (`git diff master...HEAD` or `git diff <base>...HEAD`), passing the phase range:
   - `P >= 4`: `phases ceil(P/2)+1..P` (the second half, not already covered by the midpoint reviewer).
   - `P <= 3`: `phases 1..P` (the full plan, since no intermediate reviewer was run).
3. If the review returns `OK_PHASE` or `OK`:
   - Update the front-matter: `status: completed`, add `completed_at: <ISO-timestamp>`.
4. If `FINDINGS_PHASE`: apply the standard correction loop (impl → tech, design → senior).

> **Intermediate phase closes** (phases other than `ceil(P/2)` and the final phase) do **not** trigger a review. Continue to the next phase without any dispatch.
