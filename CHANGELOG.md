# Forge — Changelog

## [Unreleased]

## [0.23.0] - 2026-06-18

### Added
- release scripts: `update-changelog.sh` and `commit-release.sh` automate changelog and version management in the release flow, classifying commits by conventional prefix and creating deterministic release commits.

### Changed
- `mr-description` skill: refactored to invoke `mr-stamp.sh` for deterministic stamp and checkbox generation, with corrected absolute path and manifest registration.
- `update-changelog` and `create-mr` skills: rewired to invoke release scripts (`update-changelog.sh` and `commit-release.sh`) instead of manual applier operations.

### Fixed
- `install`: register `update-changelog.sh` and `commit-release.sh` in the install catalog so they are available during release flow.
- `rtk` version detection: isolate HOME environment in tests to prevent false positives from on-disk fallback when RTK is not on PATH.
- `update-changelog.sh`: fixed grep option-parsing bug (incorrect handling of flags caused exit code 2) and added blank-line spacing between subsections.
- Test suite: migrate `release_skill_unit.sh` to invoke release scripts in throwaway git repos, ensuring stable file-list extraction in UC5/UC6 contract tests.
- Documentation: aligned skill docs and resolved stash merge conflicts in QUICK-REFERENCE.md.

## [0.22.0] - 2026-06-18

### Added
- `session-start.sh` now uses `session_id` instead of timestamp in the `[⬡ orch]` badge, correctly indicating whether the orchestrator hook ran in the current session (survives multi-day sessions).
- `statusline.sh` compares stored `session_id` with current session `session_id` for badge display.
- New README section "Orchestrator doctrine injection" with before/after visuals and explanation of efficiency vs subagents, plus badge survival across compaction.
- `/clear` tip added to README workflow between `/create-plan` and `/execute-plan`.
- QUICK-REFERENCE updates: badge notation, `/clear` workflow tip, component count correction (8 components), `session-start` and `cost-report-skill` added to `--only=` list, `REQUIRES_PLAN` and `BLOCKED_TECH` escalation codes added to reference table, `/cost-report` skill documented in table.

## [0.21.0] - 2026-06-18

### Added
- `session-start.sh` re-injects the orchestrator doctrine on `compact` and `resume` events, preventing doctrine loss after context compaction mid-session.
- `statusline.sh` shows a `[⬡ orch]` badge on line 1 when `~/.claude/.arsenal-orchestrator-active` is present, giving visual confirmation that the orchestrator doctrine was injected.

## [0.20.2] - 2026-06-18

### Changed
- Plan step labels renamed from `[S]` (Sonnet) and `[H]` (Haiku) to `[T]` (Tech) and `[A]` (Applier) to reflect agent roles instead of internal model names; glosses removed from label definitions across agents and skills.

### Added
- Test coverage for behavior probes: added BLOCKED_TESTER and BLOCKED_SENIOR escalation probe tests.
- Test coverage for orchestrator behavior: added REQUIRES_PLAN probe to detect orchestrator escalation paths.
- Tests for Group 8 escalation-codes emitter/file cross-check in protocol_unit.sh verifying protocol alignment.
- Tests for open-code orchestrator: regenerated after VERIFIED routing row verification to remove dead ok var.
- Documentation: added tests/prompts/README.md to improve behavior probe discoverability.

## [0.20.1] - 2026-06-17

### Added
- Test coverage for execute-plan review_rounds: 12 new tests covering front-matter and SKILL.md review_rounds, batch-fix delegation, single re-review cap per checkpoint, incremental range (last_review_sha..HEAD), Sonnet model for re-review, and review_rounds reset on checkpoint close.

### Changed
- README.md: corrected 9 discrepancies in documentation reflecting actual role boundaries, test domain ownership, agent count, and project structure updates.
- execute-plan documentation: clarified reviewer follow-up indicators and fall-through to review_rounds==1 condition.
- execute-plan tables in CLAUDE-orchestrator.md and QUICK-REFERENCE.md: aligned with batch-fix plus incremental single re-review per checkpoint (review_rounds counter).

### Fixed
- execute-plan: replaced unlimited re-review loop with batch-fix plus one incremental re-review (last_review_sha..HEAD, Sonnet model) per checkpoint, backed by review_rounds counter in plan front-matter.
- execute-plan: added happy-path OK_PHASE branch in FINDINGS_PHASE block.
- OpenCode orchestrator agent regenerated to reflect review_rounds doctrine.

## [0.20.0] - 2026-06-17

### Added
- `json-merge` hooks support: `SessionStart` merge/unmerge branches for idempotent hook composition.
- `session-start` component: injects the orchestrator prompt (`CLAUDE-orchestrator.md`) into the main session via a `SessionStart` hook; orchestrator-only content split out of `CLAUDE-shared.md`.

### Changed
- Orchestrator-only content extracted from `CLAUDE-shared.md` into dedicated `CLAUDE-orchestrator.md` with `@ref` include support.
- `CLAUDE-shared.md` references updated to point to `CLAUDE-orchestrator.md` for orchestrator-specific content.
- TRIAGE source in agent documentation repointed to `CLAUDE-orchestrator.md` after orchestrator content split.

### Fixed
- `session-start`: fixed stdin multi-line parsing — stdin read loop replaced with `cat` capture so jq receives well-formed JSON regardless of format.
- `CLAUDE-shared.md` comment references updated post-split to reflect new orchestrator-only file.
- README.md and README.es.md: updated component counts (7→8 default, 8→9 total) and added session-start to --only= list.
- Catalog tests: updated full-list count to 9 components after session-start addition.

## [0.19.5] - 2026-06-17


### Fixed
- `install`: create cost-report SKILL.md symlink even when core is installed by extracting it into a new cost-report-skill component that is not in core's conflicts_with list.
- `install`: correct post-review framing — cost-report-skill is now a default component, not a Path A core dependency.
- `components`: remove spurious conflicts_with between cost-report and cost-report-skill.

### Changed
- README and README.es.md: Add cost-report-skill to the Components table, update component counts (6→7 default, 7→8 total), extend the --only= list, and update component recipes.

### Fixed
- `cost-report`: el symlink `~/.claude/skills/cost-report/SKILL.md` se extrae a un nuevo componente `cost-report-skill` (incluido por defecto), de modo que el skill `/cost-report` se instala en el install por defecto y puede convivir con el componente `core` sin reintroducir el conflicto `core ↔ cost-report` sobre el resto de artefactos. (En Path A el skill lo sigue entregando el plugin auto-descubierto.)

## [0.19.4] - 2026-06-16

### Changed
- Update demo video and poster.

### Fixed
- Senior subagent could not write staging files to `.plans/` without triggering a permission prompt; `Bash(.plans/*)` is now allowed.

## [0.19.3] - 2026-06-13

### Added
- Test coverage for RTK version detection with HOME isolation edge case handling.

### Changed
- RTK version detection test fixtures updated to 0.42.4.
- Bump pinned RTK version from `0.42.3` to `0.42.4` (security-hardening patch).

## [0.19.2] - 2026-06-12

### Added
- Test coverage for create-plan senior-staging flow with protocol_unit assertions (6 gaps added).

### Fixed
- create-plan: ensure `.plans/` directory exists in Step 0 before senior staging write operations.
- create-plan: align Step 8 N/M sourcing to STAGED line wording for consistency.
- create-plan: fix slug-derivation gap and pin STAGED parse contract in SKILL.md.
- create-plan: rewrite SKILL.md and constraints.md to align with senior-staging model.
- create-plan: regenerate senior.md artefacts with staging-write allowlist.
- create-plan: add senior staging-write allowlist to senior.body.md for proper authorization.

## [0.19.1] - 2026-06-11

### Added
- RTK tracking for Path A: `bash install.sh rtk install` persists `rtk.tracked: true` in the state file on success (only when a state file already exists); `update`, `status` and `doctor` engage the RTK version check via this flag without requiring the `rtk-hook` component; `bash install.sh rtk uninstall` clears the flag.
- `arsenal_rtk_detect` on-disk fallback sentinel `installed:<version>`: when the RTK binary is present at `~/.arsenal/bin/rtk` but not on `PATH`, all three consumers (`_arsenal_summarize_rtk`, `cmd_status`, `arsenal_rtk_decide`) now map it to a corrective "installed but not on PATH" state instead of treating it as `absent`.

### Changed
- README and QUICK-REFERENCE: `atenea` command used consistently in install step 1 across all documentation.
- README: `<video>` tag replaced with a clickable thumbnail linking to the video for better accessibility.
- The core companion recipe now recommends the default `both` target (`~/.claude/` and `~/.atenea/.claude/`), and the docs clarify that the plugin itself is managed per Claude Code instance.
- README restructured around two complete installation paths (Plugin + core vs Legacy) with an artifact×path matrix, do-not-mix rules and the cost rationale for `core`.
- `--purge` on uninstall now also deletes `settings.json.pre-arsenal` (in addition to `*.arsenal-bak-*`).
- Docs drop the bare `--only=core` recipe; Path A is uniformly `--only=core,statusline` with explicit `rtk install`-after ordering.
- README and QUICK-REFERENCE now list the seven valid `--only=` component names (linking to the components table); dead `RTK.md` references replaced with `bash install.sh rtk install`.

### Fixed
- Full uninstall aborted with `dest must be absolute path` when symlink destinations were stored relative to each target directory — the "Remove symlinks" loop now resolves them per target before calling `arsenal_unlink`; absolute legacy entries pass through unchanged.
- `arsenal_rtk_adjust_via_tarball` now injects the PATH snippet on the idempotent "already at pinned version" early-return path, not only on a fresh install.

## [0.19.0] - 2026-06-11

### Added
- `core` component (plugin companion): CLAUDE-shared.md + `@ref`, settings defaults (`model`, `env`, permissions) and skill support files (`tools/release/*.sh`, `cost-report.sh`); opt-in only (`--only=core`), mutually exclusive with `agents`/`commands`/`cost-report` (enforced at install time, both within `--only` and against installed state).
- `--keep-rtk` uninstall flag: full uninstall now removes the pinned RTK binary, PATH snippet and empty `~/.arsenal/` by default; the flag preserves them.
- `subagentStatusLine` managed by the `statusline` component (merged only-if-absent on install, removed on uninstall) — previously the script shipped but the settings key was orphaned.
- Spanish README (`README.es.md`) with language links; English `README.md` remains the canonical version read by AI agents. `/sync-readme` skill keeps both in sync, with a structural-parity unit test.
- Contract test `tests/release_skill_unit.sh` guarding the create-mr staging contract.

### Changed
- The core companion recipe now recommends the default `both` target (`~/.claude/` and `~/.atenea/.claude/`), and the docs clarify that the plugin itself is managed per Claude Code instance.
- README restructured around two complete installation paths (Plugin + core vs Legacy) with an artifact×path matrix, do-not-mix rules and the cost rationale for `core`.
- `--purge` on uninstall now also deletes `settings.json.pre-arsenal` (in addition to `*.arsenal-bak-*`).

### Fixed
- `MR-DESCRIPTION.md` is no longer tracked by the repo: it was committed before its `.gitignore` entry existed, so the ignore rule never applied. The create-mr flow now guarantees the gitignore entry and untracks the file in any repo it runs on, and CI fails if it ever gets tracked again.
- Release commits now carry `.claude-plugin/plugin.json` together with `install.sh`/`CHANGELOG.md` (create-mr skill contract) — CI no longer fails post-merge on plugin version divergence (regression of the 0.18.0 release).
- Full uninstall now strips the `@CLAUDE-shared.md` line from `CLAUDE.md` (previously only the selective path did), removes the atenea `CLAUDE.md` symlink instead of materialising it, and sweeps empty `skills/`, `tools/`, `agents/` and `rules/` directories.
- Full uninstall sanitizes the restored settings: hook entries invoking an `rtk` that no longer resolves and `statusLine`/`subagentStatusLine` entries pointing at removed scripts are dropped with a warning (originals preserved in `.pre-arsenal`).

## [0.18.0] - 2026-06-11

### Added
- OpenCode testing coverage: added Group 2 test assertions verifying RTK branch rewrite (rtkRewrite) integration path.
- OpenCode plugin JS atenea-guard with branch guard and proxy RTK functionality.
- Plugin distribution model for Claude Code with marketplace-integrated components.
- OpenCode overlay completely generated (auto-refresh) and manual triage sync removed.
- Plan-format skill: executor rule without external context and placeholder gate.
- Models aliases and unified settings command with invisible cost savings.
- Comprehensive prompt behavior tests for reviewer, applier, and tech agents with opt-in wrapper support.
- Test infrastructure: headless agent invocation helper from repo test suite.

### Changed
- Reviewer agent refactored: from resident agent to on-demand template dispatch.
- Auto-routing descriptions simplified with minimal triage (no dedicated router agent).
- CLAUDE-shared.md trimmed to <8 KB with MR flow migrated to create-mr skill.
- Dead token-mapping table (ES↔EN protocol) removed from tech agent documentation.
- Agent role boundaries consolidated into compact table with anti-rationalization notes.
- Escalation codes sourced from single shared reference across all agents.

### Fixed
- Real cleanup of tests/.tmp with subshell bug fix and run-all sweep (tests now pass).
- Checkpoint-9 findings from final review resolved.
- Checkpoint-5 findings from mid-plan reviewer resolved.

## [0.17.1] - 2026-06-10

### Fixed
- OpenCode orchestrator synchronized with updated tester contract (return codes and failure handling).
- Testing skill descriptions aligned with operative-guide pattern for consistency.
- Agent and skill reviewer findings addressed across phases 1-3 to resolve inconsistencies.

### Changed
- Tester agent rewritten as test-domain owner with direct write and execution authority.
- Testing skills (pytest, Angular, Spring Boot) migrated to operative tester cookbook pattern.
- Tester return codes and failing-tests triage rule updated to reflect new domain ownership.
- Tester frontmatter regenerated from YAML sources to align with operative patterns.
- Tester YAML frontmatter sources updated with write tool declarations.
- Testing-Spring-Boot skill converted to READ mode delegation pattern for consistency.
- Tech agent expanded with test-domain reject signal and ESCALATE_TECH flow for failed test scenarios.

## [0.17.0] - 2026-06-09

### Added
- Plan-format skill: executor rule without external context and placeholder gate.
- Models aliases and unified settings command with invisible cost savings.
- Comprehensive prompt behavior tests for reviewer, applier, and tech agents with opt-in wrapper support.
- Test infrastructure: headless agent invocation helper from repo test suite.

### Changed
- Reviewer agent refactored: from resident agent to on-demand template dispatch.
- Auto-routing descriptions simplified with minimal triage (no dedicated router agent).
- CLAUDE-shared.md trimmed to <8 KB with MR flow migrated to create-mr skill.
- Dead token-mapping table (ES↔EN protocol) removed from tech agent documentation.
- Agent role boundaries consolidated into compact table with anti-rationalization notes.
- Escalation codes sourced from single shared reference across all agents.

### Fixed
- Real cleanup of tests/.tmp with subshell bug fix and run-all sweep (tests now pass).
- Checkpoint-9 findings from final review resolved.
- Checkpoint-5 findings from mid-plan reviewer resolved.

## [0.16.1] - 2026-06-08

### Fixed
- Tester agent aligned with updated orchestrator contract.
- Test utilities properly initialized in tester subprocess.

## [0.16.0] - 2026-06-08

### Added
- Tester agent: dedicated testing-domain verifier with plan-only execution model.
- Testing skill recipes for pytest, Angular (Jest), and Spring Boot (JUnit).

### Changed
- Orchestrator triage logic simplified with plan-vs-execute boundary.

## [0.15.0] - 2026-06-07

### Added
- Agent routing via triage: orchestrator auto-dispatch to reviewer, applier, or tester roles.
- Reviewer agent: detect risks and anti-patterns in code changes.
- Applier agent: implement code changes from specifications.

### Changed
- Orchestrator role boundaries clarified with triage gates.
- Agent communication protocol updated for multi-agent coordination.

## [0.14.1] - 2026-06-06

### Fixed
- Agent state persistence on edge cases.

## [0.14.0] - 2026-06-06

### Added
- Orchestrator agent: coordinate workflow routing across specialized agents.

### Changed
- Skill dispatch mechanism updated for agent-based architecture.

## [0.13.0] - 2026-06-05

### Added
- Skills framework: modular command handlers with state management.

### Changed
- Command architecture refactored to skills pattern.

## [0.12.0] - 2026-06-04

### Added
- Cost reporting system for LLM token usage.

### Changed
- Metrics collection improved with model-aware pricing.

## [0.11.0] - 2026-06-03

### Added
- Statusline formatting with cost tracking.

### Changed
- CLI output layout updated for better visibility.

## [0.10.1] - 2026-06-02

### Fixed
- SemVer parsing alignment.

## [0.10.0] - 2026-06-01

### Added
- Version management with semantic versioning.

## [0.9.3] - 2026-05-31

### Fixed
- Dependency resolution in install flow.

## [0.9.2] - 2026-05-30

### Fixed
- Cache validation on fresh installs.

## [0.9.1] - 2026-05-29

### Fixed
- Plugin integration and load order.

## [0.8.1] - 2026-05-28

### Fixed
- MR creation flow validation.

## [0.4.0] - 2026-05-20

### Added
- Tester agent with plan-only testing/coverage analysis (90% target).

### Fixed
- Orchestrator firewall: trivial tasks always delegate to applier.

## [0.1.1] - 2026-05-10

### Fixed
- Technical debt cleanup.

## [0.1.0] - 2026-05-01

### Added
- Initial release with core arsenal functionality.
