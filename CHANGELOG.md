# Forge — Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.3.3] - 2026-07-01

### Fixed
- prohibir EnterPlanMode/ExitPlanMode built-in en favor de /create-plan


### Fixed
- delegar update-changelog directamente al script determinista


### Fixed
- release: `create-pr` no longer invokes the `/update-changelog` skill for its changelog step; it now delegates directly to the deterministic `tools/release/update-changelog.sh` script, avoiding a skill-runner `$ARGUMENTS` expansion failure that could leave the base branch empty and abort the changelog refresh

## [0.3.1] - 2026-06-29

### Fixed
- release: open auto-merge PR for CHANGELOG closure instead of direct push to bypass branch protection


## [0.3.0] - 2026-06-29

### Added
- add MiniMax as multi-provider per subagent
- add OpenCode multiplatform support

### Changed
- add GPT equivalent comments to models.yaml
- document provider swap cases for GPT and Claude API users


## [0.1.0] - 2026-06-24

### Added

**Multi-agent pipeline**
- `senior` agent: analysis and planning with trade-off options. Produces `[T]`/`[A]`-tagged plans. Does not write code. Runs on Opus.
- `tech` agent: implementation — writes code, edits files, runs commands. Runs on Sonnet.
- `applier` agent: executes literal mechanical steps (diffs, commits, gh ops). Runs on Haiku.
- `tester` agent: owns all test files, writes and runs tests, analyses coverage gaps, produces `TESTING_PLAN`. Escalates production bugs to tech. Runs on Sonnet.
- Orchestrator doctrine injected via `session-start` hook on every session and re-injected on `compact`/`resume` events to survive context compaction.

**Slash commands**
- `/create-plan`: drives senior through an interview and persists an executable plan in `.plans/<slug>.md`.
- `/execute-plan`: iterates the plan, delegating `[A]` steps to applier and `[T]` to tech, with review checkpoints.
- `/review`: post-change audit — fills the review template and dispatches a fresh Opus subagent.
- `/pr-description`: generates a structured PR description from commits and diffs.
- `/cost-report`: breaks down Claude session cost by model family (opus/sonnet/haiku) as a proxy for subagent spend; flags anomalies.

**Components**
- `core`: CLAUDE-shared.md, settings defaults (`model`, `env`, permissions) and skill support files. Plugin companion — opt-in only.
- `agents`: senior, tech, applier and tester agent definitions + commit-conventions rule.
- `commands`: `/create-plan`, `/execute-plan`, `/review`, `/pr-description` and release skills.
- `statusline`: Claude Code statusline with per-session cost, token count, model and orchestrator badge.
- `cost-report-skill`: `/cost-report` skill installed as a standalone default component.
- `rtk-hook`: RTK proxy hook that reduces token usage on developer git operations.
- `branch-guard`: pre-tool hook that blocks commits on protected branches (`master`/`main`/`dev`) and warns when the current branch is already merged into origin/default.
- `session-start`: injects the orchestrator doctrine into the main session via a `SessionStart` hook.

**Infrastructure**
- Two install paths: **Path A** (Claude Code plugin + `core` component) and **Path B** (full legacy symlink install via `install.sh`). Functionally equivalent once complete.
- RTK pinned version management: auto-detect, install, upgrade and downgrade to the pinned version in `~/.forge/bin/rtk`; PATH snippet injection into shell profiles.
- `FORGE_BRANCH_GUARD_DISABLE` environment variable to bypass the branch guard.
- Statusline orchestrator badge (`[⬡ orch]`) shows when orchestrator doctrine is active; survives multi-day sessions via `session_id` comparison.
- Comprehensive test suite: unit and integration tests for all components (`branch-guard`, `rtk`, `symlink`, `json-merge`, `settings`, `catalog`, `statusline`, `agents-generator`, `cost-report`, `session-start`, prompt behavior probes).
- Release tooling: `update-changelog.sh`, `bump-version.sh`, `commit-release.sh`, `create-pr.sh` and `mr-stamp.sh` automate the release flow.
- English and Spanish READMEs kept in sync via `/sync-readme` skill.
- OpenCode fork support with generated overlay agents and RTK proxy.
