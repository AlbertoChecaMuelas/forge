---
description: Updates the [Unreleased] section of CHANGELOG.md. Branch-scoped mode (--branch <base>) is delegated to the deterministic tools/release/update-changelog.sh script; classic/release modes scan git log <last-tag>..HEAD and rewrite the section.
argument-hint: "[version | --branch <base>]"
model: claude-haiku-4-5
allowed-tools: Bash(git describe *) Bash(git log *) Bash(git tag *) Bash(git rev-parse *) Bash($HOME/.claude/tools/release/update-changelog.sh *) Read Write
context: fork
agent: Explore
---

CRITICAL FORMAT INSTRUCTION: Do not include preambles, explanations, or introductory text before acting. Your first action must be to run the necessary command.

Updates the `[Unreleased]` section of CHANGELOG.md. The invocation mode is selected from `$ARGUMENTS`:

- **`--branch <base>`** (e.g. `--branch master`): branch-scoped mode. This mode is FULLY DETERMINISTIC and is delegated to a script — see Step A. Do NOT classify commits yourself in this mode.
- **Empty**: classic mode. Scan `git log <last-tag>..HEAD` and rewrite the `[Unreleased]` section entirely (Steps B onward).
- **Version** (`$ARGUMENTS` matches a semver such as `1.2.0`): release mode. Scan `git log <last-tag>..HEAD` and rewrite the section as `[1.2.0] - <today's date>` (Steps B onward).

## Invocation mode

$ARGUMENTS

(Parse `$ARGUMENTS`: if it starts with `--branch `, use branch-scoped mode → Step A. Otherwise, if it looks like a semver `X.Y.Z`, use release mode. Otherwise, if empty, use classic Unreleased mode.)

## Step A — Branch-scoped mode (deterministic, script-driven)

When `$ARGUMENTS` starts with `--branch `, run the deterministic script and report its output. Do NOT read, classify, or rewrite the changelog yourself.

!`$HOME/.claude/tools/release/update-changelog.sh --branch "${ARGUMENTS#--branch }"`

The script:
- Validates `<base>` exists (prints `update-changelog: base '<base>' does not exist` and exits 2 if not).
- Scans `git log <base>..HEAD --no-merges`, classifies by conventional prefix (feat/feature → Added, fix → Fixed, refactor/perf/docs → Changed, chore/build/ci/style/test/other → omitted), strips the prefix to form each bullet, and PREPENDS an `### Added/Changed/Fixed` block immediately under `## [Unreleased]` without touching any existing content.
- Exits 0 without modifying the file when there are no new commits or no user-facing commits.

Report the script's stdout line to the user verbatim, then stop. Do not modify CHANGELOG.md by hand in this mode.

## Step B — Classic / release mode: determine the lower bound

Get the latest tag:

!`git describe --tags --abbrev=0 2>/dev/null || echo ""`

## Step C — Get commits

If Step B returned a tag:

!`git log $(git describe --tags --abbrev=0 2>/dev/null)..HEAD --oneline 2>/dev/null || git log --oneline`

If it returned nothing (repo with no tags), use all commits:

!`git log --oneline`

## Step D — Read the current CHANGELOG.md

!`cat CHANGELOG.md 2>/dev/null || echo "# Changelog"`

---

## Commit classification rules (classic / release mode)

Classify each commit by its conventional prefix:

**Added:** `feat:` / `feat(...):` / `feature:` / `feature(...):`

**Fixed:** `fix:` / `fix(...):`

**Changed:**
- `refactor:` / `refactor(...):`
- `perf:` / `perf(...):`
- `docs:` / `docs(...):`
- `chore:` / `chore(...):` — only if relevant to the end user (e.g. dependency updates, visible configuration changes); omit purely internal CI or invisible maintenance changes
- `build:` / `ci:` — only if it affects the user's workflow; omit internal ones
- Commits with `BREAKING CHANGE` in the body → special note under **Changed**: `- BREAKING: <description>`

**Commits without a conventional prefix:** include under the most appropriate category based on the message.

## Writing rules

- Each bullet describes the change from the user's perspective, not the internal code.
- One concise sentence per bullet. Avoid unnecessary technical verbs.
- Do not include the commit hash or conventional prefix in the bullet.
- Only include subsections that have entries. Do not add empty sections.

## Step E — Behavior if there are no new commits

If the list of commits from Step C is empty, inform the user `No hay commits nuevos desde el tag <tag>. CHANGELOG no modificado.` Then stop. Do not modify the file.

## Step F — Build the new section

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

If `$ARGUMENTS` was a version number (e.g. `1.2.0`), the heading is:
```
## [1.2.0] - YYYY-MM-DD
```
where `YYYY-MM-DD` is today's date in ISO 8601 format.

Only include subsections that have entries.

## Step G — Update CHANGELOG.md

- **If an `[Unreleased]` section already exists:** replace it entirely with the new section built in Step F. Do not duplicate the section.
- **If `[Unreleased]` does not exist:** insert the new section immediately after the main title (`# Changelog` or equivalent), before any other versioned section.

Write the updated file.

## Step H — Close

In your response to the user, write only:

- **Classic mode**: `CHANGELOG.md actualizado con N entradas bajo [Unreleased]. Revisa antes de commitear.`
- **Release mode**: `CHANGELOG.md actualizado con N entradas bajo [X.Y.Z]. Revisa antes de commitear.`

where N is the total number of bullets added across all subsections.
