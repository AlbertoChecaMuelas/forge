---
description: "Updates the [Unreleased] section of CHANGELOG.md. Branch-scoped mode (--branch <base>) runs the deterministic tools/release/update-changelog.sh script directly via bash — no subagent. Classic mode (empty argument) and release mode (a semver argument) scan git log <last-tag>..HEAD and dispatch a fresh subagent (model minimax-coding-plan/MiniMax-M2.5-highspeed) to classify commits and rewrite the section."
agent: orchestrator
---

You are running the `/update-changelog` command. You update the `[Unreleased]` section of
`CHANGELOG.md`. You never classify commits or rewrite the changelog yourself in classic/release
mode — that is delegated to a fresh subagent. In branch-scoped mode you never read or classify
commits yourself either — that is fully delegated to a deterministic script. Every git lookup
here is performed via `bash`; you never use `edit` or `write` directly in this command.

## Argument

`$ARGUMENTS` selects the invocation mode:

- **`--branch <base>`** (e.g. `--branch master`): branch-scoped mode. FULLY DETERMINISTIC —
  delegated to a script. Go to Step A.
- **Empty**: classic mode. Scan `git log <last-tag>..HEAD` and rewrite the `[Unreleased]` section
  entirely. Go to Step B.
- **A semver** (`$ARGUMENTS` matches `X.Y.Z`, e.g. `1.2.0`): release mode. Scan
  `git log <last-tag>..HEAD` and rewrite the section as `[1.2.0] - <today's date>`. Go to Step B.

Parse `$ARGUMENTS` first: if it starts with `--branch `, use branch-scoped mode. Otherwise, if it
matches a semver `X.Y.Z`, use release mode. Otherwise, if empty, use classic mode.

## Step A — Branch-scoped mode (deterministic, script-driven)

When `$ARGUMENTS` starts with `--branch `, run the deterministic script via `bash` and report its
output. Do NOT read, classify, or rewrite the changelog yourself; do not dispatch a subagent for
this mode.

Run via `bash`:
```
$(git rev-parse --show-toplevel)/tools/release/update-changelog.sh --branch "<base>"
```
where `<base>` is the value after `--branch ` in `$ARGUMENTS`.

The script:
- Validates `<base>` exists (prints `update-changelog: base '<base>' does not exist` and exits 2
  if not).
- Scans `git log <base>..HEAD --no-merges`, classifies by conventional prefix (feat/feature →
  Added, fix → Fixed, refactor/perf/docs → Changed, chore/build/ci/style/test/other → omitted),
  strips the prefix to form each bullet, and PREPENDS an `### Added/Changed/Fixed` block
  immediately under `## [Unreleased]` without touching any existing content.
- Exits 0 without modifying the file when there are no new commits or no user-facing commits.

Relay the script's stdout line to the user verbatim, then stop. Do not modify `CHANGELOG.md` by
hand in this mode. If the script exits non-zero, relay its stderr line to the user and stop.

## Step B — Classic / release mode: dispatch the subagent

Fill the prompt template below, substituting before dispatch:
- `{MODE}` → `classic` or `release`.
- `{ARGUMENTS}` → the raw `$ARGUMENTS` value (the semver in release mode, or the literal text
  `(none — classic mode)` when empty).

Dispatch a FRESH subagent via the `task` tool whose entire prompt is the filled template,
explicitly overriding the model for that call to `minimax-coding-plan/MiniMax-M2.5-highspeed`. Do
not paraphrase or trim the template.

Relay the subagent's final report line to the user verbatim.

## Prompt template (classic / release mode)

The following template is filled and dispatched verbatim (Step B). Substitute `{MODE}` and
`{ARGUMENTS}` before dispatch. Do not paraphrase or trim it.

```
CRITICAL FORMAT INSTRUCTION: Do not include preambles, explanations, or introductory text before
acting. Your first action must be to run the necessary command.

You are updating the `[Unreleased]` section of `CHANGELOG.md`. Mode: {MODE}. Argument: {ARGUMENTS}.

## Step 1 — Determine the lower bound

Run via `bash`: `git describe --tags --abbrev=0 2>/dev/null || echo ""`

## Step 2 — Get commits

If Step 1 returned a tag, run via `bash`:
`git log <tag>..HEAD --oneline 2>/dev/null || git log --oneline`
(substitute `<tag>` with the tag returned by Step 1).

If Step 1 returned nothing (repo with no tags), use all commits, run via `bash`:
`git log --oneline`

## Step 3 — Read the current CHANGELOG.md

Resolve the repo root via `bash`: `git rev-parse --show-toplevel`. Then read
`<repo-root>/CHANGELOG.md` with `read`. If it does not exist, treat the current content as
`# Changelog`.

## Step 4 — Behavior if there are no new commits

If the list of commits from Step 2 is empty, report
`No hay commits nuevos desde el tag <tag>. CHANGELOG no modificado.` Then stop. Do not modify the
file.

## Commit classification rules

Classify each commit by its conventional prefix:

**Added:** `feat:` / `feat(...):` / `feature:` / `feature(...):`

**Fixed:** `fix:` / `fix(...):`

**Changed:**
- `refactor:` / `refactor(...):`
- `perf:` / `perf(...):`
- `docs:` / `docs(...):`
- `chore:` / `chore(...):` — only if relevant to the end user (e.g. dependency updates, visible
  configuration changes); omit purely internal CI or invisible maintenance changes
- `build:` / `ci:` — only if it affects the user's workflow; omit internal ones
- Commits with `BREAKING CHANGE` in the body → special note under **Changed**:
  `- BREAKING: <description>`

**Commits without a conventional prefix:** include under the most appropriate category based on
the message.

## Writing rules

- Each bullet describes the change from the user's perspective, not the internal code.
- One concise sentence per bullet. Avoid unnecessary technical verbs.
- Do not include the commit hash or conventional prefix in the bullet.
- Only include subsections that have entries. Do not add empty sections.

## Step 5 — Build the new section

Build the block using this exact format:

<!-- LITERAL TEMPLATE — keep in Spanish, do not translate -->
```
## [Unreleased]

### Added
- <descripción concisa orientada al usuario>

### Changed
- <descripción concisa orientada al usuario>

### Fixed
- <descripción concisa orientada al usuario>
```

If the mode is `release` (`{ARGUMENTS}` is a version number, e.g. `1.2.0`), the heading is
instead:
```
## [1.2.0] - YYYY-MM-DD
```
where `YYYY-MM-DD` is today's date in ISO 8601 format, obtained via `bash`: `date +%F`.

Only include subsections that have entries.

## Step 6 — Update CHANGELOG.md

- **If an `[Unreleased]` section already exists:** replace it entirely with the new section built
  in Step 5. Do not duplicate the section.
- **If `[Unreleased]` does not exist:** insert the new section immediately after the main title
  (`# Changelog` or equivalent), before any other versioned section.

Write the updated file with `write`.

## Step 7 — Close

Your final response must be only one line:

- **Classic mode**: `CHANGELOG.md actualizado con N entradas bajo [Unreleased]. Revisa antes de
  commitear.`
- **Release mode**: `CHANGELOG.md actualizado con N entradas bajo [X.Y.Z]. Revisa antes de
  commitear.`

where N is the total number of bullets added across all subsections.
```
