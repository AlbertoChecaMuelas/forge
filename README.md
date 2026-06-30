# Forge

**English** | [Español](README.es.md)

> The English README is the canonical version (it is the one AI agents read by default). Keep both languages in sync with the `/sync-readme` skill.

Toolkit for Claude Code that distributes agents, commands and shared configuration as a Claude Code plugin or via symlinks. It installs a multi-agent pipeline (orchestrator → senior/tester → tech → applier, plus template-based review dispatch), reusable slash commands and a pinned RTK in any repository that uses Claude Code.

## Table of contents

- [Overview](#overview)
- [What's included](#whats-included)
- [Installation](#installation)
  - [Requirements](#requirements)
  - [Choose your path](#choose-your-path)
  - [Path A — Plugin + core](#path-a--plugin--core-recommended)
  - [Path B — Legacy install](#path-b--legacy-install-symlinks-via-installsh)
  - [Selective component install](#selective-component-install)
  - [Install flags](#install-flags)
  - [Uninstall](#uninstall)
  - [RTK](#rtk)
- [Components](#components)
- [Usage](#usage)
  - [Statusline](#statusline)
  - [Cost reporting](#cost-reporting)
  - [Agent pipeline](#agent-pipeline)
  - [Plan-driven workflow](#plan-driven-workflow)
- [Configuration and safety](#configuration-and-safety)
  - [Branch guard](#branch-guard)
  - [Orchestrator doctrine injection](#orchestrator-doctrine-injection)
- [OpenCode target](#opencode-target)
- [Project structure](#project-structure)
- [Release process](#release-process)
- [Contributing](#contributing)

## Overview

Forge centralises the configuration that makes Claude Code productive across many repositories: a curated set of subagents with strict role boundaries, slash commands that orchestrate multi-step changes, a statusline with cost and token telemetry, and a pinned RTK proxy that reduces token usage on developer operations.

Everything is delivered through symlinks from this repository to `~/.claude/`, so updates are a single `git pull` away.

## What's included

| Type    | Name             | Description                                                                  |
|---------|------------------|------------------------------------------------------------------------------|
| Agent   | senior           | Analysis, options with trade-offs, `[T]`/`[A]` plans. Does not write code. Opus. |
| Agent   | tech             | Implementation: writes code, edits files, runs commands. Sonnet.             |
| Agent   | applier          | Executes literal mechanical steps: diffs, commits, gh ops. Haiku.            |
| Skill   | /review          | Post-change audit: fills the review template and dispatches a fresh Opus subagent. |
| Agent   | tester           | Owns all test files; writes and runs tests, analyses coverage gaps, produces `TESTING_PLAN`. Escalates production bugs to tech. Sonnet. |
| Command | /pr-description  | Generates a structured PR description from commits and diffs.                |
| Command | /create-plan     | Drives senior through an interview and persists an executable plan in `.plans/<slug>.md`. |
| Command | /execute-plan    | Iterates the plan, delegating `[A]` steps to applier and `[T]` to tech, with checkpoints. |
| Command | `/cost-report`    | Break down Claude session cost by model family (opus/sonnet/haiku) as a proxy for subagent spend; flags anomalies. |
| Shared  | CLAUDE-shared.md | Pipeline instructions distributed to every repo via symlink.                 |
| Shared  | statusline.sh    | Claude Code statusline with cost, tokens and active session.                 |
| Shared  | total-usage.sh   | Lifetime usage totals with official per-token-type pricing.                  |
| Shared  | `cost-report.sh`  | Backing script for `/cost-report`: per-model cost breakdown, top sessions and anomaly flags. |

## Installation

### Requirements

bash 3.2+, git, jq, Claude Code.

### Choose your path

Forge installs two ways. Both are **functionally equivalent** once complete — same agents, skills, hooks, settings defaults and RTK savings — they differ in how the pieces are delivered and updated:

| Artifact | Path A — Plugin + core | Path B — Legacy (symlinks) |
|---|---|---|
| Agents (senior, tech, applier, tester) | plugin (auto-discovered) | `agents` component |
| Skills (`/create-plan`, `/execute-plan`, `/review`, `/create-mr`, `/cost-report`, ...) | plugin (auto-discovered) | `commands` + `cost-report` + `cost-report-skill` components |
| PreToolUse hooks (RTK proxy + branch guard) | plugin (`hooks/hooks.json`) | `rtk-hook` + `branch-guard` components |
| `CLAUDE-shared.md` + `@CLAUDE-shared.md` ref in `~/.claude/CLAUDE.md` | **`core` component** | `agents` component |
| `settings.json` defaults (`model: sonnet`, `env`, permissions) | **`core` component** | `agents` component |
| Skill support files (`tools/release/{bump-version,create-mr}.sh`, `cost-report.sh`) | **`core` component** | `commands` + `cost-report` components |
| Statusline (scripts + `statusLine`/`subagentStatusLine` keys) | `statusline` component (optional) | `statusline` component |
| RTK binary (`~/.forge/bin/rtk`) | `bash install.sh rtk install` | `bash install.sh rtk install` |
| Updates | `/plugin` → update, plus `git pull` for core symlinks | `bash install.sh update` |

**Cost rationale — why `core` is not optional in practice.** The plugin alone loads the agents, skills and hooks, but the three mechanisms that actually cut the bill live in `core` + the RTK binary:

1. **`CLAUDE-shared.md`** is the firewall that forces your main session to delegate to the pipeline (senior/tech/applier) instead of doing the edits, greps and tests itself with the expensive session model.
2. **`model: sonnet` + the `env` model aliases** keep the main session on Sonnet by default, so the heavy lifting happens on the cheaper tiers the pipeline assigns.
3. **The RTK binary** powers the PreToolUse proxy hook the plugin ships. Without the binary the hook is a silent no-op and you lose the 60–90 % savings on command output (git, ls, tests...). The hook invokes `~/.forge/bin/rtk`, which only `bash install.sh rtk install` provides.

### Path A — Plugin + core (recommended)

Step 1 — install the plugin (agents + skills + hooks):

```
claude                                            # open a session with claude
/plugin marketplace add <github-repo-url>         # register the 'forge' marketplace
/plugin install forge                             # install the plugin
```

Step 2 — from a clone of this repository, install the companion pieces a plugin cannot deliver:

```
bash install.sh install --only=core,statusline # CLAUDE-shared.md + settings defaults + support files + statusline
bash install.sh rtk install                    # pinned RTK binary + PATH snippet + activates RTK tracking
source ~/.zshrc                                # or open a new terminal
```

`rtk install` must run **after** the `--only=core,statusline` install: it persists the `rtk.tracked` flag into the existing state file and deliberately does not create one. Once the flag is set, `update`/`doctor`/`status` will verify the RTK version in Path A without the `rtk-hook` component.

The default target is `~/.claude/`. The plugin itself is managed per Claude Code instance: to enable it, run the same `/plugin` commands from the session where you want it active.

To update: plugin bumps arrive with the marketplace (`/plugin` → update); the plugin `version` is kept in lockstep with `FORGE_VERSION` by `tools/release/bump-version.sh` and checked in CI. The `core` symlinks update with a plain `git pull` of the clone (or `bash install.sh update`).

Day-to-day plugin management happens with the `claude plugin` CLI (or the `/plugin` menu in-session). In particular, `claude plugin details forge` is the quickest way to inspect what the plugin actually loads — agents, skills and hooks, with the context cost of their descriptions:

```
claude plugin details forge
```

**Do not mix the paths.** With the plugin enabled, never install the legacy `agents`, `commands` or `cost-report` components (duplicated agents and skills) nor `branch-guard`/`rtk-hook` (the PreToolUse hooks would run **twice**: once from the plugin's `hooks/hooks.json` and once from `settings.json`). The installer enforces the first group mechanically — `core` is mutually exclusive with `agents`/`commands`/`cost-report` — but it cannot see the plugin's hooks, so the `branch-guard`/`rtk-hook` rule is documentation-only: respect it.

### Path B — Legacy install (symlinks via install.sh)

Run the installer from the repository root. Each subcommand is idempotent and safe to re-run.

| Command | What it does |
|---------|--------------|
| `bash install.sh install` | Installs all 8 default components into `~/.claude/`. |
| `bash install.sh install --show-cost` | Installs and enables monetary cost plus lifetime stats in the statusline. |
| `bash install.sh install --only=agents,commands` | Installs only the `agents` and `commands` components. |
| `bash install.sh install --only=statusline` | Installs only the `statusline` component. |
| `bash install.sh status` | Reports which symlinks are in place per target (component-scoped). |
| `bash install.sh doctor` | Runs diagnostics on installed components only: validates symlink integrity, RTK presence and configuration health. |
| `bash install.sh update` | Runs `git pull` and repairs symlinks, acting only on components recorded in state. |
| `bash install.sh repair` | Recreates missing or broken symlinks for installed components, without pulling. |
| `bash install.sh version` | Prints `FORGE_VERSION`. |
| `bash install.sh uninstall` | Removes every symlink the installer created. Preserves user files. |
| `bash install.sh uninstall --component=statusline` | Removes only the `statusline` component, leaving all other components intact. |
| `bash install.sh rtk install` | Installs the pinned RTK proxy explicitly. |
| `bash install.sh rtk uninstall` | Removes the pinned RTK proxy. |
| `bash install.sh --help` | Prints the installer usage block (subcommands, options, version banner). Also accepted as `-h` and shown when no subcommand is provided. |

### Selective component install

By default, `install` deploys the 8 default components (`core`, the plugin companion, is opt-in only). Use `--only=<list>` to install only a subset of components, or `--component=<name>` with `uninstall` to remove a single component without touching the others.

`--only=` accepts any comma-separated subset of the nine components described in [Components](#components) — `agents`, `commands`, `statusline`, `branch-guard`, `rtk-hook`, `cost-report`, `cost-report-skill`, `session-start`, `core` — subject to the `core` exclusivity rule below. The table shows common recipes, not the only valid combinations.

| Recipe | Command |
|---|---|
| Plugin companion + statusline (Path A) | `bash install.sh install --only=core,statusline` |
| Minimal (statusline only) | `bash install.sh install --only=statusline` |
| Agent pipeline only | `bash install.sh install --only=agents,commands` |
| Cost tooling only | `bash install.sh install --only=cost-report,cost-report-skill,statusline` |
| Everything except branch guard | `bash install.sh install --only=agents,commands,statusline,rtk-hook,cost-report,cost-report-skill` |
| Remove one component | `bash install.sh uninstall --component=<name>` |

**Note on `commands` without `agents`**: installing `commands` without `agents` is allowed, but the slash commands depend on the agent pipeline to work correctly. The installer emits a warning if you select `commands` without `agents`.

**Note on `core`**: `core` is mutually exclusive with `agents`, `commands` and `cost-report` — they own the same files and settings paths. The installer rejects any combination of them, both in the same `--only` list and against components already recorded as installed (uninstall the conflicting component first).

**Note on `rtk-hook`**: `--only=rtk-hook` installs only the settings hook entry. It does NOT install the `rtk` binary; install it with `bash install.sh rtk install`.

The `update`, `repair`, `status`, and `doctor` subcommands are component-scoped: they act only on the components that are recorded as installed in the state file. If you installed a subset, those commands operate on that subset only (v0.14.0 behaviour change).

### Install flags

| Flag | Description |
|------|-------------|
| `--target=claude` | Installs only the Claude Code target. |
| `--target=opencode` | Installs only the isolated OpenCode overlay. |
| `--target=both` | Installs the Claude Code target plus the OpenCode overlay. |
| `--only=<component>[,<component>...]` | Install only the specified component(s). No flag = install all 8 (backward-compatible). |
| `--show-cost` | Enables monetary cost of the current session and lifetime statusline stats. |

### Uninstall

Each installation path uninstalls with its own tool.

**Path A (Plugin + core)** — two steps, mirroring the install:

```
/plugin uninstall forge                   # agents + skills + hooks (also available from the /plugin menu)
```

```
bash install.sh uninstall                 # core/statusline symlinks, settings defaults and the pinned RTK
```

**Path B (Legacy)** — a single command removes everything the installer created:

```
bash install.sh uninstall
```

Flags accepted by `install.sh uninstall`:

| Flag | Description |
|------|-------------|
| `--component=<name>` | Removes a single component from the target, leaving all others intact. Without this flag, full uninstall removes everything. |
| `--keep-rtk` | Full uninstall only: keep the pinned RTK binary and its PATH snippet. Without it, full uninstall removes `~/.forge/bin/rtk`, the PATH block in your shell profiles, and the `~/.forge/` directory if it ends up empty. |
| `--purge` | Also delete the `*.forge-bak-*` backups **and** `settings.json.pre-forge`. Without it, both are preserved. |

A full uninstall leaves `~/.claude/` genuinely clean: it strips the `@CLAUDE-shared.md` line from `CLAUDE.md` (preserving your own content), sweeps the empty `skills/`, `tools/`, `agents/` and `rules/` directories, removes the pinned RTK by default, and **sanitizes the restored settings**: hook entries that invoke an `rtk` that no longer resolves, and `statusLine`/`subagentStatusLine` entries pointing at scripts the uninstall just removed, are dropped with a warning. The untouched originals remain in `settings.json.pre-forge`.

### RTK

`bash install.sh rtk install` installs the pinned RTK proxy binary to `~/.forge/bin/rtk`. On success it also **injects a marked PATH block** into every shell profile that already exists on disk (`~/.zshrc`, `~/.bashrc`, `~/.zprofile`, `~/.bash_profile`). The block prepends `~/.forge/bin` to `PATH` so that the forge-pinned `rtk` takes precedence over any other installation. The injection is idempotent: re-running the installer never duplicates the block.

**Post-install requirement**: the PATH change takes effect only in new shell sessions. After installing, either open a new terminal or run:

```
source ~/.zshrc
```

Until you do, `rtk` will not resolve in terminals that were already open when the installer ran.

**Uninstall**: `bash install.sh rtk uninstall` removes the binary, strips the PATH block from all four profiles automatically and clears the `rtk.tracked` flag from the state file, so `status`/`doctor`/`update` stop checking the RTK version (re-activate with `bash install.sh rtk install`; the direct `bash rtk/uninstall-rtk.sh` script removes binary and PATH block but does not touch the flag). A **full** `bash install.sh uninstall` also removes the pinned RTK by default — pass `--keep-rtk` to preserve it.

#### Migrating from a Homebrew-installed RTK

If you previously installed `rtk` via Homebrew, follow these steps to switch to the forge-pinned version:

1. Confirm Homebrew has it: `brew list rtk`
2. Remove the Homebrew copy: `brew uninstall rtk`
3. Install the forge-pinned version: `bash install.sh rtk install`
4. Apply the PATH change: `source ~/.zshrc` (or open a new terminal)

> **Warning**: between steps 2 and 4, `rtk` will not resolve in any open terminal. Close all terminals that relied on the Homebrew copy before proceeding, or accept a brief gap in availability.

## Components

The installer is built around nine discrete components. Each component is defined by a manifest under `shared/components/` and can be installed independently.

| Component | What it installs | Default? |
|-----------|-----------------|----------|
| `agents` | Agent pipeline (senior, tech, applier, tester) + `CLAUDE-shared.md` + settings defaults | yes |
| `commands` | Slash commands (`create-plan`, `execute-plan`, `pr-description`, `update-changelog`, `review`, `create-mr`, `sync-readme`, `plan-format`), framework testing skills (`testing-angular`, `testing-spring-boot`, `testing-pytest`) + release tools | yes |
| `statusline` | Claude Code status line (`statusline.sh`), `total-usage.sh`, `subagent-statusline.sh` + the `statusLine`/`subagentStatusLine` settings keys | yes |
| `branch-guard` | `branch-guard.sh` PreToolUse hook that blocks commits on protected branches | yes |
| `rtk-hook` | RTK proxy hook entry in `settings.json` (the `rtk` binary is installed separately via `bash install.sh rtk install`) | yes |
| `cost-report` | `/cost-report` slash command + `cost-report.sh` backend script | yes |
| `cost-report-skill` | `~/.claude/skills/cost-report/SKILL.md` symlink that makes `/cost-report` discoverable as a Claude Code skill | yes |
| `session-start` | `SessionStart` hook that injects the orchestrator prompt (`CLAUDE-orchestrator.md`) into the main session on `startup` and `clear` events; ships `session-start.sh` and copies `CLAUDE-orchestrator.md` to the project Claude directory | yes |
| `core` | Plugin companion: `CLAUDE-shared.md` + `@ref`, settings defaults (`model`, `env`, permissions) and skill support files (`tools/release/{bump-version,create-mr}.sh`, `cost-report.sh`) — everything the Claude Code plugin cannot deliver itself | **no** — opt-in; Path A uses `--only=core,statusline` |

**Backward compatibility**: no `--only` flag = full install of the 8 default components. Existing invocations continue to work unchanged; `core` never installs by default because it conflicts with `agents`/`commands`/`cost-report`.

## Usage

### Statusline

`shared/statusline.sh` is installed as a symlink at `~/.claude/statusline.sh` and provides the Claude Code statusline with session information.

**Default behaviour** (without `--show-cost`):

The statusline shows two lines:
- Line 1: directory, git branch, velocity (+adds/-dels), model, context bar, rate limits.
- Line 2: `[ session ]` — session name and input/output tokens.

**With `--show-cost`** (install flag):

Adds two extra elements:
- **Session monetary cost**: USD/EUR amount accumulated in the current session.
- **Lifetime line** (third line): total historical cost, accumulated tokens, active days, sessions, today's cost and daily average.

To enable it, install with the flag:

| Command | What it does |
|---------|--------------|
| `bash install.sh install --show-cost` | Installs with cost and lifetime stats visible in the statusline. |

The USD → EUR exchange rate is cached for 24h in `~/.claude/.eur-rate` and refreshed in the background.

### Cost reporting

`/cost-report` is a slash command backed by `shared/cost-report.sh` that parses Claude Code session logs and produces a structured cost breakdown.

**What it produces**:
- **Per-model breakdown**: a table with columns Model, Calls, Token In, Token Out, % Cost, Estimated Cost — one row per model family (Opus, Sonnet, Haiku).
- **Top Sessions table**: lists the most expensive sessions with session ID and title.

**Key flags**:

| Flag | Description |
|------|-------------|
| `--since` | Filter sessions starting from a date (e.g. `--since=2026-01-01`). |
| `--until` | Filter sessions up to a date. |
| `--project` | Restrict to a specific project. |
| `--session <id-or-name>` | Filter to a single session by sessionId substring or aiTitle substring. |

**When to run**: after an intensive session, when auditing spend, or when investigating a cost anomaly.

**How to read it**: `% Cost` shows each model family's share of the total cost for the selected period — useful for spotting Opus-heavy sessions where senior or the review subagent ran more than expected. The `--session` flag accepts a UUID prefix or any fragment of the human-readable session title.

To install cost-report standalone (without the full agent pipeline), use the [Selective component install](#selective-component-install) recipe: `bash install.sh install --only=cost-report,cost-report-skill,statusline`.

### Agent pipeline

The main session acts as orchestrator: it routes requests to the right agent according to a 5-check firewall gate. It does not run tools with side-effects; it only invokes subagents via the Task tool.

- Conversational requests → answered by the orchestrator itself.
- Fully-specified mechanical tasks → applier.
- Implementation with a plan in hand → tech.
- Testing gap analysis → tester.
- Post-change audit → `/review` (template-filled subagent, Opus).
- Design decisions and multi-file planning → senior.

```
User
  |
  v
orchestrator -- routes by description --> senior (Opus)    -- plan -->  tech (Sonnet)
                                          tester (Sonnet)                      |
                                                                               v
                                          /review (template, Opus)       applier (Haiku)
```

Upward escalation via return codes: `BLOCKED` (applier → tech), `ESCALATE_SENIOR` (tech → senior), `FINDINGS` (review → tech or senior).

### Plan-driven workflow

Use this flow when the task is multi-step, touches several files or needs upfront planning.

1. `/create-plan [description]` — invokes senior, which produces a numbered plan with `[T]`/`[A]` steps. The command persists the plan in `.plans/<slug>.md` and creates the `.plans/current` symlink. The `.plans/` directory is added to `.gitignore` automatically.
2. `/execute-plan` — reads `.plans/current` and iterates step by step: `[A]` steps go to applier, `[T]` steps to tech. Reviewer is invoked at most twice per plan: once at the midpoint phase (plans with P ≥ 4 phases) and once at close. Once all steps complete, `PR-DESCRIPTION.md` is generated via `/pr-description`.

If the session is interrupted, `/execute-plan` resumes from the last step recorded in the plan's front-matter.

> **Tip**: after `/create-plan` produces the plan and before running `/execute-plan`, doing a `/clear` is optional but recommended for longer plans. It removes the planning conversation from context (senior's interview, trade-off discussion, intermediate drafts), so `/execute-plan` starts with a clean context window and the orchestrator doctrine is re-injected fresh. The plan file on disk is unaffected by `/clear`.

## Configuration and safety

### Branch guard

The repo ships a Claude Code PreToolUse hook at `shared/branch-guard.sh` that BLOCKS commits on protected branches (`master`, `main`, `dev`). When the hook detects a `Bash` invocation whose command contains `git commit` AND the current branch is one of the protected names, it exits with code `2` and Claude Code refuses the tool call.

This is a mechanical, LLM-independent last line of defence. Two upstream layers also exist (triage rule 2.5 in the orchestrator prompt, and a pre-commit branch guard in the applier agent prompt) — the hook fires only if both LLM layers fail.

**Behaviour summary**:
- `git commit` on `master`/`main`/`dev` → blocked (exit 2), stderr explains the reason.
- `git commit` on any feature branch → allowed.
- Non-commit git operations (`status`, `log`, `diff`, `checkout -b`, `branch`) → never blocked.
- Detached HEAD or no git available → warn on stderr, do not block (fail-open).
- Malformed PreToolUse JSON → warn on stderr, do not block (fail-open).

**Kill-switch**: set `FORGE_BRANCH_GUARD_DISABLE=1` in the environment to bypass the hook entirely (intended for emergency overrides; document the reason if you use it).

**Installation**: register `shared/branch-guard.sh` as a PreToolUse hook in your Claude Code settings (see the project's `settings.json` snippet, if present, or the Claude Code hooks documentation).

### Orchestrator doctrine injection

Forge injects the orchestrator doctrine (`CLAUDE-orchestrator.md`) into the main Claude Code session via a `SessionStart` hook. This is the mechanism that makes Claude behave as an orchestrator — routing requests to the right agent, respecting role boundaries and using the escalation protocol — rather than acting as a generic assistant.

**How it works**: when a session starts (or resumes, or the context is compacted), `session-start.sh` runs and outputs the full `CLAUDE-orchestrator.md` to stdout. Claude Code adds that output to the session context once. Claude Code's prompt caching then means subsequent API calls read those tokens from cache at minimal cost — the injection only pays full price on the first call after each injection event.

**Why subagents don't carry the doctrine**: before v0.20.0, the orchestrator doctrine lived in `CLAUDE-shared.md`, which is loaded for every session — including every subagent. That meant tech, applier, tester and senior all received the orchestrator's routing rules and escalation table in their context, despite never needing them.

```
Before v0.20.0 — doctrine in CLAUDE-shared.md:
  main session (orchestrator) → CLAUDE-shared.md → orchestrator doctrine  ✓
  subagent tech               → CLAUDE-shared.md → orchestrator doctrine  ✗ (unnecessary)
  subagent applier            → CLAUDE-shared.md → orchestrator doctrine  ✗ (unnecessary)
  subagent tester             → CLAUDE-shared.md → orchestrator doctrine  ✗ (unnecessary)

After v0.20.0 — doctrine injected via SessionStart hook:
  main session (orchestrator) → SessionStart hook → orchestrator doctrine  ✓
  subagent tech               → (nothing)                                  ✓
  subagent applier            → (nothing)                                  ✓
  subagent tester             → (nothing)                                  ✓
```

The `SessionStart` hook only fires for the main session, not for subagents. Extracting the doctrine into a hook-injected file means subagents no longer carry tokens they never use.

**Statusline badge**: the statusline shows `[⬡ orch]` on line 1 when the hook fired in the current session (tracked via session ID). The badge disappears when you open a new session where the hook has not yet run, and reappears as soon as the first `startup`, `clear`, `compact` or `resume` event fires. If the badge never appears, check that the `session-start` component is installed (`bash install.sh status`) and that the hook is wired in `settings.json`.

**Survival across compaction**: the hook fires on `startup`, `clear`, `compact` and `resume` events. If Claude Code compacts the context mid-session (removing early conversation turns), the doctrine is automatically re-injected so the orchestrator protocol remains active for the rest of the session.

## OpenCode target

Forge supports [OpenCode](https://opencode.ai) from the same repository. OpenCode is not a separate fork: it is an overlay generated into `open-code/` and installed through `--target=opencode` or `--target=both`.

`open-code/agents/` is a **generated artefact**: never edit those files by hand. Edit the shared sources (`shared/agents/*.body.md`, `shared/scripts/opencode-frontmatter/*.yaml`, `open-code/agents-src/`) and run `bash tools/opencode/generate-agents.sh`. CI fails on drift (`tests/opencode_generation_unit.sh`).

### Installation

| Command | What it does |
|---------|--------------|
| `bash install.sh install --target=opencode` | Installs only the isolated OpenCode overlay. |
| `bash install.sh install --target=both` | Installs the Claude Code target and then the OpenCode overlay. |
| `bash open-code/install-opencode.sh` | Re-installs only the OpenCode overlay. |
| `bash open-code/uninstall-opencode.sh` | Removes only the OpenCode overlay. |

**What the installer does**:

1. Requires `opencode` on `PATH`.
2. Regenerates the 5 OpenCode agents.
3. Installs an isolated overlay under `~/.config/opencode-forge/` instead of touching the user's global OpenCode config.
4. Symlinks the generated agents, `AGENTS.md`, and `plugins/forge-guard.js` into that isolated overlay.
5. Copies `open-code/opencode.jsonc` into the isolated overlay and rewrites the `AGENTS.md` instruction path.
6. Installs a separate launcher at `~/.local/bin/forge-opencode` that exports `OPENCODE_CONFIG_DIR` and `OPENCODE_CONFIG` before running the real `opencode` binary.
7. Verifies that either OpenCode credentials already exist or token-based auth is available via `open-code/env.sh`.

The installer is idempotent and does not modify `~/.config/opencode/`, `.bashrc`, `.zshrc`, or `config.fish`.

### Requirements

- OpenCode installed ([https://opencode.ai](https://opencode.ai)).
- `jq` (auto-installed via `brew` if unavailable; requires Homebrew).
- `python3` as a fallback if `jq` cannot be installed.

### Layout of `open-code/`

```
open-code/
  agents/                     Generated OpenCode agents
  agents-src/orchestrator.body.md
  plugins/forge-guard.js     Branch guard plugin for OpenCode
  AGENTS.md                  Minimal shared OpenCode instructions
  opencode.jsonc             Provider configuration template
  env.sh                     POSIX token loader
  forge-opencode.sh          Wrapper that exports isolated OpenCode config paths
  install-opencode.sh        Installs the isolated OpenCode overlay
  uninstall-opencode.sh      Removes the isolated OpenCode overlay
  SPIKE-RESULTS.md           Delegation/plugin/config-loading/cost findings
  COST-PARITY.md             OpenCode cost-reporting contract
```

## Project structure

```
forge/
  agents/          Subagent definitions (senior, tech, applier, tester)
  skills/          Slash commands (12 subdirs: create-plan, execute-plan, review, create-mr, …)
  hooks/           PreToolUse hooks (branch-guard.sh, rtk-hook)
  tools/           Release and OpenCode generator scripts
  .claude-plugin/  Plugin manifest (plugin.json) for the Claude Code marketplace
  open-code/       OpenCode overlay: agents/, agents-src/, plugins/, AGENTS.md and isolated installer
  shared/          Files distributed to every target (CLAUDE-shared.md, statusline, settings)
  lib/             Internal installer scripts (catalog, symlink, json-merge, rtk)
  rtk/             Pinned RTK installer and uninstaller
  tests/           Integration and unit tests for the installer (bash)
  install.sh       Installer entry point
  CHANGELOG.md     Version history
```

## Release process

This repo uses a single source of truth for versions: `FORGE_VERSION` in `install.sh`. The plugin manifest `.claude-plugin/plugin.json` is kept in lockstep by `tools/release/bump-version.sh` and verified in CI — the release commit must always carry `install.sh`, `CHANGELOG.md` **and** `.claude-plugin/plugin.json` together.

The release flow is **fully automated** and runs in two CI jobs:

### Step 1 — `release-prep` (prepares the bump PR)

Triggered by one of two events:

- **`workflow_dispatch`** (manual button in the Actions tab) — pick a `bump` value from the dropdown and run.
- **`schedule`** — weekly safety net, Mondays at 09:00 UTC. No-op if there is nothing to release.

Runs `tools/release/prep-release.sh`, which:

1. Computes the next version (see [Bump types](#bump-types) below).
2. **Idempotent no-op** if any of these is true:
   - Tag `v<NEXT>` already exists locally or on `origin`.
   - Branch `release/v<NEXT>-prep` already exists on `origin`.
   - `## [Unreleased]` in `CHANGELOG.md` is empty.
3. Otherwise, creates branch `release/v<NEXT>-prep` from `master`, edits `install.sh` (`FORGE_VERSION`), `.claude-plugin/plugin.json` (version), and `CHANGELOG.md` (closes `[Unreleased]` as `[<NEXT>] - <DATE>`, opens a new empty `[Unreleased]`).
4. Commits, pushes the branch, opens a PR against `master` titled `chore(release): v<NEXT>`, and enables **auto-merge (squash)**.

### Step 2 — `auto-tag` (creates the tag)

Triggered by every push to `master` (after the prep PR auto-merges, or on the initial feature merge).

Runs `tools/release/auto-tag.sh`, which:

1. Parses `FORGE_VERSION` from `install.sh`.
2. Checks whether `vX.Y.Z` already exists locally or on `origin`. If it does, the job is a no-op (idempotent).
3. Otherwise, creates an annotated tag `vX.Y.Z` on the merge commit with message `Release vX.Y.Z` and pushes it to `origin`.
4. If `## [Unreleased]` is non-empty, creates branch `release/vX.Y.Z-changelog`, commits the CHANGELOG closure, opens a PR with auto-merge. **This branch is normally unused** because `prep-release.sh` already closed `[Unreleased]` in Step 1 — it exists only as a safety net.

The pushed tag is the canonical release marker. Downstream consumers pin to tags, never to `master` SHAs.

### Bump types

The `bump` input to `release-prep` (and the `BUMP_TYPE` env var for the script) accepts:

| Value | Computed next version | When to use |
|-------|----------------------|-------------|
| `auto` *(default)* | `patch` if any `fix:` / `refactor:` / `perf:` commit since the last tag, `minor` if any `feat:` commit, no-op otherwise | Routine releases — pick this unless you have a reason not to |
| `patch` | `X.Y.(Z+1)` | Explicit patch bump regardless of commit history |
| `minor` | `X.(Y+1).0` | Explicit minor bump regardless of commit history |
| `major` | `(X+1).0.0` | **Explicit only.** Public API stable release, breaking change announcement. Never auto-derived. |

**Why `auto` never picks `major`:** bumping the major version is a deliberate, user-visible commitment (it resets the minor and patch to zero and signals a breaking change under semver). The `auto` mode is designed to be safe by default — if you want a major bump, you must choose it explicitly from the dropdown.

### Idempotency guarantees

- `prep-release.sh` exits 0 without side effects when the tag, branch, or `[Unreleased]` section already indicates a release is in progress or done.
- `auto-tag.sh` is a no-op when the tag already exists.
- Neither script ever moves an existing tag.
- `auto-tag.sh` never creates lightweight tags; every tag is annotated with `Release vX.Y.Z`.

### Prerequisites

- The `release-prep` and `auto-tag` jobs both need `contents: write` and `pull-requests: write` permissions on the `GITHUB_TOKEN`.
- In **repository Settings → Actions → General → Workflow permissions**, both **"Read and write permissions"** and **"Allow GitHub Actions to create and approve pull requests"** must be enabled (the latter is required for `gh pr create` to succeed).
- Without these, the workflows will fail with `GitHub Actions is not permitted to create or approve pull requests`.

### Known caveat: first PR from the bot

The first time the bot opens a PR via `prep-release.sh`, GitHub may mark the resulting CI run as **"Action required"** and wait for a maintainer to approve it. This is a platform-level security guardrail against indirect workflow triggers, not a bug. Workaround for that single run: push a trivial commit (e.g. empty commit) to the PR branch to re-trigger CI without the approval gate. Subsequent bot PRs run without intervention.

### Local dry-run

| Command | What it does |
|---------|--------------|
| `bash tools/release/auto-tag.sh --dry-run` | Parses `FORGE_VERSION`, decides whether the tag would be created, and exits without contacting `origin`. |
| `BUMP_TYPE=auto bash tools/release/prep-release.sh` | Runs the full prep flow against the local checkout (will push to `origin` if no idempotency check fires). |
| `BUMP_TYPE=major bash tools/release/prep-release.sh` | Same, with explicit major bump. |

## Contributing

Contributor-facing guidelines (including shell linting policy) live in [`CONTRIBUTING.md`](CONTRIBUTING.md).
