---
description: "Drives the full PR-creation flow for the current branch: version bump, changelog refresh, PR description regeneration and gh PR creation. Use when the user asks to create or open a pull request ('crea la PR', 'abre el pull request', 'create the PR', 'open the pull request', 'create the MR', 'abre el merge request'). Requires gh on PATH, an origin remote, and a non-protected current branch."
agent: orchestrator
---

You are running the `/create-pr` command. You orchestrate the full release flow for the current
branch: version bump, changelog refresh, release commit, PR description regeneration and `gh` PR
creation. Every script invocation and git lookup here is performed directly via `bash` — this
flow is FULLY DETERMINISTIC and script-driven; you never improvise with raw `gh pr create` or
REST API calls, and you never push to the remote at any point.

## Argument

`$ARGUMENTS` is an optional base branch override, `<base>` (the PR's target branch). Default:
`master`.

## Preconditions

Before starting, verify via `bash`:
(a) `gh` is on PATH and authenticated (`gh auth status`);
(b) the repo has an `origin` remote (`git remote get-url origin`);
(c) the current branch (`git rev-parse --abbrev-ref HEAD`) is not `master`/`main`/`dev`.

If any precondition fails, report it to the user in Spanish and stop. Do not attempt any of the
steps below.

## Flow

Execute this sequence in order, fully automatic — no manual version input from the user.

### Step 1 — Compute the version bump

Run via `bash`:
```
$(git rev-parse --show-toplevel)/tools/release/bump-version.sh --base <base>
```
Capture its single stdout line of the form
`BUMP=<none|patch|minor>  CURRENT=<x.y.z>  NEXT=<x.y.z>  FEATS=<n>  FIXES=<n>  OTHERS=<n>`.
Parse `BUMP` and `NEXT` from that line — you will need both in Step 2.

The script has already edited `install.sh` to set `FORGE_VERSION="<NEXT>"` unless `BUMP=none` (in
which case `install.sh` was not edited). In EVERY case (including `BUMP=none`) the script may also
have re-synced `.claude-plugin/plugin.json` to `FORGE_VERSION`; that file must always travel in the
same commit, or the CI version-sync check fails on `master`.

If the script exits 2 (precondition failure: not a git repo, `install.sh` missing, malformed
version, invalid base) or 3 (`install.sh` edit failed), report the failure to the user in Spanish
and stop.

### Step 2 — Refresh `[Unreleased]` and create the release commit

Run via `bash`:
```
cd "$(git rev-parse --show-toplevel)/tools/release" && bash update-changelog.sh --branch <base>
```
(resolve `<base>` to the actual base branch value determined for this flow, not the literal
placeholder). Do NOT invoke the update-changelog command for this step — its `$ARGUMENTS`
expansion is not a real shell variable inside a dispatched subagent's script block and resolves
incorrectly (often empty), which makes the underlying script exit 2 for a missing `--branch
<base>`. Call the script directly. The script classifies the branch commits (feat/feature →
Added, fix → Fixed, refactor/perf/docs → Changed, chore/build/ci/other → omitted) and PREPENDS an
`### Added/Changed/Fixed` block under `## [Unreleased]` in place, without touching existing
entries. The section is NOT renamed here — after the PR merges and the tag is created, CI
`auto-tag` closes it as `[v<NEXT>] - YYYY-MM-DD` and pushes the closure commit to `master`.

If the script exits 2 (bad arguments or base ref does not exist), report the failure to the user
in Spanish and stop.

Then run via `bash`:
```
$(git rev-parse --show-toplevel)/tools/release/commit-release.sh <BUMP> <NEXT>
```
(pass the `BUMP` and `NEXT` values parsed in Step 1). The script stages the correct file set and
creates the commit `chore(release): bump version to v<NEXT>`:
- **`BUMP=patch` or `BUMP=minor`**: stages `install.sh`, `CHANGELOG.md` AND
  `.claude-plugin/plugin.json` (and nothing else).
- **`BUMP=none`**: stages BOTH `CHANGELOG.md` AND `.claude-plugin/plugin.json` (and nothing else;
  staging an unmodified `plugin.json` is a harmless no-op). `.claude-plugin/plugin.json` must
  always travel in the commit or the CI version-sync check fails on `master`.

Handle `commit-release.sh`'s exit code explicitly:
- **Exit 0**: the release commit was created. Continue to Step 3.
- **Exit 3** (nothing staged — e.g. no user-facing commits and `plugin.json` already in sync):
  there is no release commit to make. Skip straight to Step 3.
- **Exit 2** (bad args / missing required file) or **exit 4** (`git commit` failed): report the
  failure to the user in Spanish and stop.

### Step 3 — Regenerate and write `PR-DESCRIPTION.md`

Invoke the `/pr-description` command (command chaining), passing `<base>` as its argument, to
regenerate the PR description from the now-updated history (the release/changelog commit from
Step 2 is included in the diff range). `/pr-description` never writes files itself — it returns
the Markdown body VERBATIM to its caller.

Write that returned output VERBATIM to `PR-DESCRIPTION.md` at the repo root via `bash` (e.g.
using a heredoc, so no paraphrasing or reformatting occurs). `PR-DESCRIPTION.md` is a working
artifact and must NEVER be committed:
- Before (or right after) the write, ensure the repo's `.gitignore` contains the line
  `PR-DESCRIPTION.md`. Check first via `bash`:
  `grep -q '^PR-DESCRIPTION\.md$' $(git rev-parse --show-toplevel)/.gitignore` — only append the
  line (create the file if missing) when that check fails, so the operation stays idempotent (in
  this repo the line is already present, so this is a no-op here, but the check must still run so
  the same flow works unmodified in other repos).
- If `git ls-files --error-unmatch PR-DESCRIPTION.md` shows it is tracked, run via `bash`
  `git rm --cached PR-DESCRIPTION.md` so the ignore rule takes effect, and include that deletion
  in the next commit you make.

### Step 4 — Create the PR

Run via `bash`:
```
$(git rev-parse --show-toplevel)/tools/release/create-pr.sh --base <base>
```

### Step 5 — Handle `create-pr.sh`'s exit code

- **Exit 0**: the PR was created or updated successfully. Report the result (PR URL if printed) to
  the user in Spanish and stop. This is the successful end of the flow.
- **Exit 3** (`PR-DESCRIPTION.md` is stale relative to `HEAD` — the stamp's `head=<SHA>` does not
  match the current `HEAD`): re-invoke `/pr-description` with `<base>`, rewrite
  `PR-DESCRIPTION.md` verbatim with its output following the same procedure as Step 3, then retry
  Step 4 exactly once. If the retry also exits non-zero, report the failure to the user in Spanish
  and stop — do not retry a second time.
- **Exit 2** (precondition failed: no `gh` on PATH, no remote, protected branch, or
  `PR-DESCRIPTION.md` missing): report the precondition failure to the user in Spanish and stop.
- **Exit 4** (`gh pr create`/`gh pr edit` failed) or **exit 5** (could not parse title or body from
  `PR-DESCRIPTION.md`): report the failure to the user in Spanish and stop.

## Hard rules

- **Never push.** The user pushes manually after the PR is opened. The release commit travels
  with the PR; once it merges into `master`, CI `auto-tag` creates and pushes the tag, then closes
  `[Unreleased]` as `[v<NEXT>] - YYYY-MM-DD` and pushes that follow-up commit to `master`.
- Never call the update-changelog command from this flow — always call the `update-changelog.sh`
  script under `tools/release/` directly via `bash` (see Step 2).
- Never improvise PR creation with raw `gh pr create`/`gh pr edit`/REST calls — always go through
  `tools/release/create-pr.sh`.
