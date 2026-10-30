---
description: Executes a multi-step plan from .plans/<slug>.md, delegating [A] steps to applier and [T] steps to tech, with a review checkpoint (template-filled subagent, model opus) at the midpoint phase and at plan close (max 2 per plan).
argument-hint: "[path-to-plan.md]"
disable-model-invocation: true
---

You are the orchestrator of the `/execute-plan` skill. Your job is to iterate through the plan step by step, delegate execution to the correct agent based on the `[A]`/`[T]` label, and dispatch the review subagent at checkpoints.

## Argument

`$ARGUMENTS` is the optional path to the plan file. If empty, use `.plans/current` (symlink to the active plan).

---

## Bash helpers used throughout

These two patterns are reused across every step below; they are quoted here once instead of repeated at each call site.

**Set or update a scalar front-matter key** (creates it just before the closing `---` fence if it does not already exist, otherwise updates it in place; recognizes plain and quoted YAML keys, rejects invalid front-matter, detects already-published concurrent changes, and replaces the file only after validating the result):

```bash
set_frontmatter() {
  if [ "$#" -ne 3 ]; then
    printf '%s\n' 'set_frontmatter: expected <plan> <key> <value>' >&2
    return 2
  fi
  python3 - "$1" "$2" "$3" <<'PY'
import json
import os
import re
import stat
import sys
import tempfile


def fail(message):
    raise ValueError(message)


def split_lines(data):
    if not data:
        return []
    chunks = data.split(b"\n")
    lines = [chunk + b"\n" for chunk in chunks[:-1]]
    if chunks[-1]:
        lines.append(chunks[-1])
    return lines


def line_content(line):
    if line.endswith(b"\n"):
        line = line[:-1]
        if line.endswith(b"\r"):
            line = line[:-1]
    return line


def frontmatter(lines):
    if not lines or line_content(lines[0]) != b"---":
        fail("line 1 is not an opening --- front-matter fence")
    for index in range(1, len(lines)):
        if line_content(lines[index]) == b"---":
            return index
    fail("no closing --- front-matter fence")


def yaml_key(text):
    if re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*", text):
        return text.encode("utf-8")
    return json.dumps(text, ensure_ascii=False).encode("utf-8")


def yaml_value(text):
    plain = bool(text) and text == text.strip()
    plain = plain and not any(ord(char) < 0x20 or ord(char) == 0x7f for char in text)
    plain = plain and text[0] not in "-?:,[]{}#&*!|>'\"%@`"
    plain = plain and ": " not in text and " #" not in text and not text.endswith(":")
    if plain:
        return text.encode("utf-8")
    return json.dumps(text, ensure_ascii=False).encode("utf-8")


def fence_lines(lines):
    return [line for line in lines if line_content(line) == b"---"]


def has_key(line, prefixes):
    return line_content(line).lstrip(b" \t").startswith(prefixes)


def main():
    plan, key, value = sys.argv[1:]
    if not os.path.isfile(plan):
        fail(f"plan is not a regular file: {plan}")
    if "\n" in key or "\r" in key or not key:
        fail("key must be a non-empty single-line scalar")
    if "\n" in value or "\r" in value:
        fail("value must be a single-line scalar")

    with open(plan, "rb") as source:
        source_stat = os.fstat(source.fileno())
        original = source.read()
    before = split_lines(original)
    closing = frontmatter(before)
    body = b"".join(before[closing + 1 :])

    raw_key = key.encode("utf-8")
    quoted_key = json.dumps(key, ensure_ascii=False).encode("utf-8")
    single_quoted_key = b"'" + key.replace("'", "''").encode("utf-8") + b"'"
    prefixes = (raw_key + b":", quoted_key + b":", single_quoted_key + b":")
    matches = [
        index
        for index in range(1, closing)
        if has_key(before[index], prefixes)
    ]

    rendered = yaml_key(key) + b": " + yaml_value(value)
    updated = list(before)
    if matches:
        for index in matches:
            old_line = before[index]
            old_content = line_content(old_line)
            indentation = old_content[: len(old_content) - len(old_content.lstrip(b" \t"))]
            ending = (
                b"\r\n"
                if old_line.endswith(b"\r\n")
                else b"\n"
                if old_line.endswith(b"\n")
                else b""
            )
            updated[index] = indentation + rendered + ending
    else:
        if before[closing].endswith(b"\r\n"):
            ending = b"\r\n"
        elif before[closing].endswith(b"\n"):
            ending = b"\n"
        elif before[0].endswith(b"\r\n"):
            ending = b"\r\n"
        else:
            ending = b"\n"
        updated.insert(closing, rendered + ending)

    result = b"".join(updated)
    directory = os.path.dirname(os.path.abspath(plan))
    temp_path = None
    try:
        mode = stat.S_IMODE(os.stat(plan).st_mode)
        fd, temp_path = tempfile.mkstemp(prefix=".set_frontmatter.", dir=directory)
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as temporary:
            temporary.write(result)
            temporary.flush()
            os.fsync(temporary.fileno())

        with open(temp_path, "rb") as temporary:
            validated = temporary.read()
        after = split_lines(validated)
        after_closing = frontmatter(after)
        after_matches = [
            index
            for index in range(1, after_closing)
            if has_key(after[index], prefixes)
        ]
        expected_matches = len(matches) if matches else 1
        if line_content(after[0]) != b"---":
            fail("validation failed: opening fence changed")
        if len(fence_lines(after)) != len(fence_lines(before)):
            fail("validation failed: fence count changed")
        if b"".join(after[after_closing + 1 :]) != body:
            fail("validation failed: document body changed")
        if len(after_matches) != expected_matches or any(
            line_content(after[index]).lstrip(b" \t") != rendered for index in after_matches
        ):
            fail("validation failed: key is not correctly set inside front-matter")
        if after[after_closing] != before[closing]:
            fail("validation failed: closing fence changed")

        # Optimistic concurrency guard: abort if the original path no longer
        # names the inode and bytes read above. This check is not atomic with
        # os.replace; a writer can still race in the small interval after it.
        with open(plan, "rb") as current:
            current_stat = os.fstat(current.fileno())
            current_data = current.read()
        if (current_stat.st_dev, current_stat.st_ino) != (source_stat.st_dev, source_stat.st_ino) \
            or current_data != original:
            fail("plan changed since it was read; refusing to overwrite concurrent updates")

        os.replace(temp_path, plan)
        temp_path = None
    finally:
        if temp_path is not None:
            try:
                os.unlink(temp_path)
            except FileNotFoundError:
                pass


try:
    main()
except Exception as error:
    print(f"set_frontmatter: {error}", file=sys.stderr)
    sys.exit(1)
PY
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

The pre-publication inode/content check is optimistic rather than a lock: it aborts when a concurrent change is observed, but a writer can still race in the small interval between that check and `os.replace()`.

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
1. Use the `set_frontmatter` Bash helper below to set `status: in_progress` and add `started_at: <ISO-timestamp>`.
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

- The plan is edited **at each step** to reflect progress (checkboxes `[ ]` → `[x]` and front-matter), using `flip_step` and `set_frontmatter` via the `Bash` tool. Never edit or write the plan directly.
- **The plan is NOT committed** (`.plans/` is in `.gitignore` of the target repo).
- The symlink `.plans/current` is kept pointing to the active plan throughout execution.
- If the user pauses execution: state is persisted in the front-matter (`current_phase`, `current_step`). When `/execute-plan` is re-launched (no args), it reads `.plans/current` and resumes from where it left off.

---

## Hard constraints

- **NEVER `git push`**: blocked by forge settings.
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
