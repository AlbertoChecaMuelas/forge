---
name: plan-format
description: Arsenal plan format spec — preload reference for tech and applier subagents
disable-model-invocation: true
---
## Plan format

Senior must produce the plan in the following format. This format is what `/execute-plan` parses to iterate through the steps.

### YAML front-matter (first lines of the file)

```yaml
---
slug: <slug>
status: pending
current_phase: 1
current_step: 1
target_branch: feat/<slug>   # or fix/<slug> depending on the type of change
created_at: <YYYY-MM-DD>
repo: <name of the repo root directory>
---
```

### Section ## General objective

Brief description (2-5 sentences) of what is achieved upon completing the plan.

### Section ## Closed decisions (do not reopen)

List of design decisions already made that tech/applier must NOT question or reopen during execution.

### Section ## Current state (parseable)

Checkboxes per phase and per step. **This block is what /execute-plan parses to know what is pending.** Exact format:

```
### Phase N — <title>
- [ ] Step N.1 [A] — <short description>
- [ ] Step N.2 [T] — <short description>
```

Labels:
- `[A]` (applier): fully specifiable mechanical step, no micro-decisions.
- `[T]` (tech): step requiring code judgment, local decisions, or debugging.

Reviewer CHECKPOINTs — placement rule:

- **`P <= 3` phases**: emit exactly **1** CHECKPOINT block, placed after the last phase (final only).
- **`P >= 4` phases**: emit exactly **2** CHECKPOINT blocks — one after phase `ceil(P/2)` (midpoint), one after the last phase (final).
- Do NOT emit a CHECKPOINT after any other intermediate phase; `/execute-plan` will not invoke reviewer there and the checkbox would remain permanently un-ticked.

Format for each block:
```
### CHECKPOINT PHASE N — Reviewer
- [ ] Approved by reviewer
```

Where `N` is the phase number (either `ceil(P/2)` for the midpoint block, or `P` for the final block). The literal `- [ ] Approved by reviewer` line must be preserved exactly — `/execute-plan` does a string-replace on it.

### Sections # PHASE N — <title>

One section per phase. Each step within the phase has its own sub-heading `## Step N.M`:

```
# PHASE N — <title>

## Step N.1 [A] — <short title>
...

## Step N.2 [T] — <short title>
...
```

**For [A] steps**:
- Exact path of the affected file or resources.
- Literal command or exact unified diff to apply.
- Shell verifier (command that exits with code 0 if OK).

**For [T] steps**:
- Path(s) of files to create or modify.
- Responsibilities: what tech must do in this step.
- Success criteria: what indicates the step is correctly done.
- Verifier (can be a test, a lint, or "manual verification").

### Zero-context executor rule

Plans are executed by an agent WITHOUT access to this conversation: the step text is its only context. A plan that needs the conversation to be understood is invalid.

- Every `[A]` step carries the literal and complete code/diff/command (applied verbatim), exact paths, and a verification command with its expected result.
- Every `[T]` step describes responsibilities and success criteria that are self-contained (no references to "what we discussed").

Forbidden anti-patterns (placeholders) — any of these invalidates the plan:

| Anti-pattern | Example | Correction |
|---|---|---|
| Pending markers | `TBD`, `TODO`, `???` | Close the decision before emitting the plan. |
| Relative references | "similar to step N", "same as above" | Repeat the literal content in each step. |
| Quality without code | "add proper error handling" | Include the exact code that implements it. |
| Unresolved paths | `<your-module>/file.ts`, `src/.../x.ts` | Exact path, verified against the repo. |
| Non-executable verifier | "check it works" | Shell command + expected result. |

### Senior self-review checklist (mandatory before emitting)

1. **Spec coverage**: every requirement of the research summary maps to >=1 step.
2. **Placeholder scan**: `grep -nE "TBD|TODO|similar (a|to)|as appropriate|\?\?\?"` over the plan body returns nothing.
3. **Path consistency**: every referenced path exists in the repo or is created by an earlier step.
4. **Verifier presence**: every `[A]` step has an executable verifier + expected result; every `[T]` step has success criteria + verifier.
5. **Label sanity**: no `[A]` step requires choosing between options; when in doubt, relabel as `[T]`.

A plan that fails any item is not emitted: fix it and re-run the checklist.

### Explicit CHECKPOINT sections

Include exactly **1 or 2** CHECKPOINT sections per plan — never one per phase, never every 3 commits:

- **`P <= 3` phases**: 1 section, at the close of the final phase.
- **`P >= 4` phases**: 2 sections — one at the close of phase `ceil(P/2)` (midpoint), one at the close of the final phase.

Do NOT place a CHECKPOINT after intermediate phases that are not the midpoint; `/execute-plan` will not invoke reviewer there and the checkbox would remain permanently un-ticked.

Each CHECKPOINT section contains:
- What to review (specific criteria for the just-closed phase).
- Suggested invocation command for the reviewer.
- Indication of whether it is blocking.

### Mandatory final sections

```
# GLOBAL VERIFIER
<shell commands that verify the complete final state of the plan>

# ROLLBACK
<instructions for reverting if the plan is abandoned midway>
```
