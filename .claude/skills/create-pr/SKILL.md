---
description: "Drives the full PR-creation flow for the current branch: version bump, changelog refresh, PR description regeneration and gh PR creation. Use when the user asks to create or open a pull request ('crea la PR', 'abre el pull request', 'create the PR', 'open the pull request', 'create the MR', 'abre el merge request'). Requires gh on PATH, an origin remote, and a non-protected current branch."
argument-hint: "[base-branch]"
---

# Create PR — orchestrated release flow

Preconditions (if any fails, report it to the user and stop):
(a) `gh` is on PATH and authenticated; (b) the repo has an `origin` remote; (c) the current branch is not `master`/`main`/`dev`.

Execute this sequence in order, fully automatic for the git-side operations — no manual version input from the user. `<base>` is the PR's target branch (`$1`, default `master`). In forge mode the flow has a deliberate handoff after a release commit is created locally: the agent MUST NOT push, and the PR creation step runs in a re-invoked `/create-pr` once the user has pushed the release commit themselves. This split keeps `tools/release/create-pr.sh` Precondition 5 (`origin/<rama>` == `HEAD`) honest and makes the flow resumable.

0. Detect forge mode. Run via `bash`:
   ```
   ROOT="$(git rev-parse --show-toplevel)"; if [ -f "$ROOT/tools/release/bump-version.sh" ] && grep -q '^FORGE_VERSION=' "$ROOT/install.sh" 2>/dev/null; then forge_mode=true; else forge_mode=false; fi
   ```
   This is the same forge-detection gate used internally by `/pr-description`. If `forge_mode=true`, follow "Forge mode" below — the full script-driven flow (steps 1-5), unchanged. If `forge_mode=false`, follow "Generic mode" below instead — the repo has no `tools/release/` scripts to drive a version bump, a changelog refresh or PR creation, so the flow falls back to `/pr-description` plus a direct, inline `gh pr create`/`gh pr edit`. Never mix the two branches.

### Forge mode (`forge_mode=true`)

1. Delegate to `applier` the execution of `$(git rev-parse --show-toplevel)/tools/release/bump-version.sh --base <base>` and capture its single stdout line of the form `BUMP=<none|patch|minor>  CURRENT=<x.y.z>  NEXT=<x.y.z>  FEATS=<n>  FIXES=<n>  OTHERS=<n>`. Parse `BUMP` and `NEXT` from that line. The script has already edited `install.sh` to set `FORGE_VERSION="<NEXT>"` unless `BUMP=none` (in which case `install.sh` was not edited). In EVERY case (including `BUMP=none`) the script may also have re-synced `.claude-plugin/plugin.json` to `FORGE_VERSION`; that file must always travel in the same commit, or the CI version-sync check fails on `master`.
2. Refresh `[Unreleased]` and create the release commit deterministically:
   - Delegate to `applier` the execution of `$(git rev-parse --show-toplevel)/tools/release/update-changelog.sh --branch <base>` (resolve `<base>` to the actual base branch value determined for this flow, not the literal placeholder). Do NOT invoke the `/update-changelog` skill for this step — its skill-runner `$ARGUMENTS` expansion is not a real shell variable inside the skill's script block and resolves incorrectly (often empty), which makes the underlying script exit 2 for a missing `--branch <base>`. The script classifies the branch commits and writes a stable desired state into `CHANGELOG.md` when the working tree still matches the `HEAD` baseline, becoming a no-op on re-run; a working tree diverging from both baseline and desired is rejected (exit 2) rather than silently overwritten. The section is NOT renamed here — after the PR merges and the tag is created, CI `auto-tag` closes it as `[v<NEXT>] - YYYY-MM-DD` and pushes the closure commit to `master`.
   - Delegate to `applier` the execution of `$(git rev-parse --show-toplevel)/tools/release/commit-release.sh <BUMP> <NEXT>` (pass the `BUMP` and `NEXT` values parsed in step 1). The script stages the correct file set and creates the commit `chore(release): bump version to v<NEXT>`:
     - **`BUMP=patch` or `BUMP=minor`**: stages `install.sh`, `CHANGELOG.md` AND `.claude-plugin/plugin.json` (and nothing else).
     - **`BUMP=none`**: stages BOTH `CHANGELOG.md` AND `.claude-plugin/plugin.json` (and nothing else; staging an unmodified `plugin.json` is a harmless no-op). `.claude-plugin/plugin.json` must always travel in the commit or the CI version-sync check fails on `master`.
   - Handle `commit-release.sh` exit codes:
     - **Exit 0**: a new release commit exists locally on `HEAD`. `origin/<rama>` and local `HEAD` have diverged, so the next steps (`/pr-description`, `create-pr.sh`) would fail Precondition 5. Stop this invocation. Report to the user in Spanish with the literal command they must run themselves: `git push origin <rama-actual>`. Then ask them to re-run `/create-pr <base>` after that push completes. This handoff is expected, not an error.
     - **Exit 3** (no release artifact has a staged change — e.g. no user-facing commits and `plugin.json` already in sync): there is no release commit to make and nothing new was added to `HEAD`. Skip straight to step 3.
     - **Exit 2** (bad args / missing required file / foreign staged content / version mismatch) or **Exit 4** (`git commit` failed): report the failure to the user in Spanish and stop.

   The re-invocation after `git push origin <rama-actual>` is safe and idempotent: the new release commit on the remote becomes the validated checkpoint, `bump-version.sh` and `update-changelog.sh` see an empty pending range, and `commit-release.sh` exits 3 again with no further commit. Step 3 and `create-pr.sh` then run normally against the now-published `HEAD`.
3. Invoke `/pr-description` to regenerate `PR-DESCRIPTION.md` from the now-updated history (the release/changelog commit is included in the diff range). After the skill returns its output, delegate to `applier` a literal write of that output verbatim to `PR-DESCRIPTION.md` at the repo root. Do not paraphrase or reformat. `PR-DESCRIPTION.md` is a working artifact and must NEVER be committed: before (or right after) the write, ensure the target repo's `.gitignore` contains the line `PR-DESCRIPTION.md` (create the file or append the line if missing; idempotent — do not duplicate it), and if `git ls-files --error-unmatch PR-DESCRIPTION.md` shows it is tracked, delegate to `applier` a `git rm --cached PR-DESCRIPTION.md` so the ignore rule takes effect (include that deletion in the next commit).
4. Delegate to `applier` the execution of `$(git rev-parse --show-toplevel)/tools/release/create-pr.sh` instead of improvising with raw `gh pr create` or REST API calls.
5. If `create-pr.sh` exits with code 3 (stamp stale relative to HEAD): re-invoke `/pr-description`, delegate the literal re-write of `PR-DESCRIPTION.md` to `applier`, and re-delegate `create-pr.sh` to `applier`.

Never push in forge mode either: the user must push the release commit BEFORE the PR can be opened, never "after the PR is opened". `tools/release/create-pr.sh` Precondition 5 requires `origin/<rama>` to be byte-identical to the local `HEAD` whose release it advertises, so the release commit must already be on the remote before `/create-pr` reaches `create-pr.sh`. The agent never runs `git push` on the user's behalf under any circumstance. The release commit travels with the PR; once it merges into `master`, CI `auto-tag` creates and pushes the tag, then closes `[Unreleased]` as `[v<NEXT>] - YYYY-MM-DD` and pushes that follow-up commit to `master`.

### Generic mode (`forge_mode=false`)

No `tools/release/` script is invoked in this mode — there is no version bump, no changelog refresh and no release commit. The flow only regenerates the PR description and creates/updates the PR directly.

G1. Invoke `/pr-description` to generate `PR-DESCRIPTION.md` from the current branch history (`/pr-description` already detects the same non-forge condition and omits the freshness stamp and the `## Tipo de cambio` block). After the skill returns its output, delegate to `applier` a literal write of that output verbatim to `PR-DESCRIPTION.md` at the repo root. Do not paraphrase or reformat. `PR-DESCRIPTION.md` is a working artifact and must NEVER be committed: before (or right after) the write, ensure the target repo's `.gitignore` contains the line `PR-DESCRIPTION.md` (create the file or append the line if missing; idempotent — do not duplicate it), and if `git ls-files --error-unmatch PR-DESCRIPTION.md` shows it is tracked, delegate to `applier` a `git rm --cached PR-DESCRIPTION.md` so the ignore rule takes effect (include that deletion in the next commit).
G2. Verify the branch is pushed to `origin`. Run via `bash`:
    ```
    CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
    REMOTE_SHA="$(git rev-parse "origin/${CURRENT_BRANCH}" 2>/dev/null || true)"
    LOCAL_SHA="$(git rev-parse HEAD)"
    ```
    If `REMOTE_SHA` is empty or differs from `LOCAL_SHA`, the branch has no matching tip on `origin`. Report this to the user in Spanish (e.g. "la rama '<branch>' no está pusheada a origin; ejecuta `git push origin <branch>` y vuelve a intentarlo") and STOP. Never push on the user's behalf.
G3. Create the PR inline. `tools/release/create-pr.sh` does not exist in this repo, so extract the title and body from `PR-DESCRIPTION.md` exactly as that script does in forge mode, and build the `gh` command directly (do not delegate this extraction to `applier`, it requires reading the file):
    - **Title**: the first non-empty line that is not a bare `---` separator.
    - **Body**: from the first `# ` heading to the end of the file, excluding the `<!-- forge:pr-description ... -->` stamp line if one is present (it should not be, in generic mode).

    If either extraction is empty, report the failure to the user in Spanish and stop. Otherwise run via `bash`:
    ```
    gh pr create --base "<base>" --head "$CURRENT_BRANCH" --title "$TITLE" --body "$BODY"
    ```
    - If it succeeds, report the result (PR URL) to the user in Spanish and stop. This is the successful end of the flow.
    - If it fails because a PR already exists for this branch (the output matches `already exists`/`already a pull request`), fall back to updating it instead:
      ```
      gh pr edit "$CURRENT_BRANCH" --title "$TITLE" --body "$BODY"
      ```
      Report the update to the user in Spanish and stop.
    - If it fails for any other reason, report the failure to the user in Spanish and stop.

Never push in generic mode either: the user pushes manually. Never improvise a `bump-version.sh`/`update-changelog.sh`/`commit-release.sh`/`create-pr.sh` call in this mode — none of those scripts exist in a non-forge repo; building `gh pr create`/`gh pr edit` inline (step G3) is the designed, official path here, not an improvisation.
