---
description: "Drives the full PR-creation flow for the current branch: version bump, changelog refresh, PR description regeneration and gh PR creation. Use when the user asks to create or open a pull request ('crea la PR', 'abre el pull request', 'create the PR', 'open the pull request', 'create the MR', 'abre el merge request'). Requires gh on PATH, an origin remote, and a non-protected current branch."
argument-hint: "[base-branch]"
---

# Create PR — orchestrated release flow

Preconditions (if any fails, report it to the user and stop):
(a) `gh` is on PATH and authenticated; (b) the repo has an `origin` remote; (c) the current branch is not `master`/`main`/`dev`.

Execute this sequence in order, fully automatic — no manual version input from the user. `<base>` is the PR's target branch (`$1`, default `master`).

1. Delegate to `applier` the execution of `$(git rev-parse --show-toplevel)/tools/release/bump-version.sh --base <base>` and capture its single stdout line of the form `BUMP=<none|patch|minor>  CURRENT=<x.y.z>  NEXT=<x.y.z>  FEATS=<n>  FIXES=<n>  OTHERS=<n>`. Parse `BUMP` and `NEXT` from that line. The script has already edited `install.sh` to set `FORGE_VERSION="<NEXT>"` unless `BUMP=none` (in which case `install.sh` was not edited). In EVERY case (including `BUMP=none`) the script may also have re-synced `.claude-plugin/plugin.json` to `FORGE_VERSION`; that file must always travel in the same commit, or the CI version-sync check fails on `master`.
2. Refresh `[Unreleased]` and create the release commit deterministically:
   - Invoke `/update-changelog --branch <base>`. In branch-scoped mode this delegates to `tools/release/update-changelog.sh`, which classifies the branch commits (feat/feature → Added, fix → Fixed, refactor/perf/docs → Changed, chore/build/ci/other → omitted) and PREPENDS an `### Added/Changed/Fixed` block under `## [Unreleased]` in place, without touching existing entries. The section is NOT renamed here — after the PR merges and the tag is created, CI `auto-tag` closes it as `[v<NEXT>] - YYYY-MM-DD` and pushes the closure commit to `master`.
   - Delegate to `applier` the execution of `$(git rev-parse --show-toplevel)/tools/release/commit-release.sh <BUMP> <NEXT>` (pass the `BUMP` and `NEXT` values parsed in step 1). The script stages the correct file set and creates the commit `chore(release): bump version to v<NEXT>`:
     - **`BUMP=patch` or `BUMP=minor`**: stages `install.sh`, `CHANGELOG.md` AND `.claude-plugin/plugin.json` (and nothing else).
     - **`BUMP=none`**: stages BOTH `CHANGELOG.md` AND `.claude-plugin/plugin.json` (and nothing else; staging an unmodified `plugin.json` is a harmless no-op). `.claude-plugin/plugin.json` must always travel in the commit or the CI version-sync check fails on `master`.
   - If `commit-release.sh` exits 3 (nothing staged — e.g. no user-facing commits and `plugin.json` already in sync), there is no release commit to make; skip straight to step 3.
3. Invoke `/pr-description` to regenerate `PR-DESCRIPTION.md` from the now-updated history (the release/changelog commit is included in the diff range). After the skill returns its output, delegate to `applier` a literal write of that output verbatim to `PR-DESCRIPTION.md` at the repo root. Do not paraphrase or reformat. `PR-DESCRIPTION.md` is a working artifact and must NEVER be committed: before (or right after) the write, ensure the target repo's `.gitignore` contains the line `PR-DESCRIPTION.md` (create the file or append the line if missing; idempotent — do not duplicate it), and if `git ls-files --error-unmatch PR-DESCRIPTION.md` shows it is tracked, delegate to `applier` a `git rm --cached PR-DESCRIPTION.md` so the ignore rule takes effect (include that deletion in the next commit).
4. Delegate to `applier` the execution of `$(git rev-parse --show-toplevel)/tools/release/create-pr.sh` instead of improvising with raw `gh pr create` or REST API calls.
5. If `create-pr.sh` exits with code 3 (stamp stale relative to HEAD): re-invoke `/pr-description`, delegate the literal re-write of `PR-DESCRIPTION.md` to `applier`, and re-delegate `create-pr.sh` to `applier`.

Never push: the user pushes manually after the PR is opened. The release commit travels with the PR; once it merges into `master`, CI `auto-tag` creates and pushes the tag, then closes `[Unreleased]` as `[v<NEXT>] - YYYY-MM-DD` and pushes that follow-up commit to `master`.
