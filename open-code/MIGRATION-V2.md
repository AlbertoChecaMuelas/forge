# OpenCode 2 migration runbook

This runbook describes how Forge moved from OpenCode 1.19.4 to
`@opencode/cli@2.1.4`, and how to verify the resulting installation. The
cutover scripts are external to this repository; no migration is run by the
acceptance checklist below.

- [Pinned version and isolation](#pinned-version-and-isolation)
- [What changed in the repository](#what-changed-in-the-repository)
- [Decision D1 — migrate the data or start fresh](#decision-d1--migrate-the-data-or-start-fresh)
- [Decision D2 — who owns the OpenCode binary](#decision-d2--who-owns-the-opencode-binary)
- [Backup](#backup)
- [Trial on a copy](#trial-on-a-copy)
- [Cutover](#cutover)
- [Acceptance checks](#acceptance-checks)
- [Rollback](#rollback)
- [Risks and known limits](#risks-and-known-limits)

## Pinned version and isolation

| Item | Value |
|------|-------|
| Pinned package | `@opencode/cli@2.1.4` |
| Pinned prefix (Forge-owned) | `~/.local/share/forge/opencode-v2` (`$FORGE_OPENCODE_BIN_DIR` can override it) |
| Pinned executable entry point | `~/.local/share/forge/opencode-v2/node_modules/.bin/opencode` |
| User launcher | `~/.local/bin/forge-opencode` |
| Launcher source in this repository | `open-code/forge-opencode.sh` |
| Installer in this repository | `install.sh` at the repository root (there is no `open-code/install.sh`) |
| Overlay | `~/.config/opencode-forge/` (`$OPENCODE_CONFIG_DIR` can override it) |
| Overlay config | `~/.config/opencode-forge/opencode.jsonc` (`$OPENCODE_CONFIG` can override it) |
| Forge manifest | `~/.forge-state.json` |
| Database | `OPENCODE_DB` (defaults to the OpenCode data directory) |
| External cutover directory (this machine) | `/home/espinilleitor/forge-v2-cutover-20261024/` (`cutover.sh`, `ROLLBACK.sh`, `lib/dbtool.py`, notes) |

Rules that the migration must not break:

- **Forge never uses the OpenCode binary in `PATH`.** `forge-opencode` runs the
  pinned build by absolute path, so an Omarchy upgrade that reinstalls
  OpenCode 1 in `PATH` cannot change what Forge runs.
- **Forge does not intentionally modify `~/.local/share/omarchy/`.** The
  historical check covered tree metadata only through depth 3 and checksums of
  three backed-up files; it was not an exhaustive content comparison.
- **The launcher isolates server-capable invocations.** OpenCode 2.1.4 accepts
  `--standalone` at the root or after specific supported command leaves; the
  launcher follows that per-command grammar. It does not inject the flag into
  `plugin`, `mcp`, `debug`, `service`, `serve`, `acp`, `pair`, `upgrade` or
  `uninstall`.
- **`--server` and `--server=<url>` are rejected** by the launcher before
  OpenCode starts: attaching to a shared server is exactly what the isolation
  forbids.
- **The launcher never sets `OPENCODE_DB`.** Exporting it before calling
  `forge-opencode` is the supported way to run against a copy of the data.

## What changed in the repository

| Area | OpenCode 1 | OpenCode 2 |
|------|-------------|------------|
| Config | `plugin`, `provider`, `permission`, `small_model`, `autoupdate` | `plugins`, `providers`, `permissions`, `mcp.servers`, `update: "disable"` |
| Agent frontmatter | `name:` + `permission:` map | no `name`; `permissions:` is an ordered ruleset of `{action, resource, effect}` (the last matching rule wins) |
| Tools | `bash`, `task` | `shell`, `subagent` (writes use the `edit` action) |
| Models | `provider/model` | `provider/model#variant` (the reasoning effort is a declared variant) |
| Plugins | `plugins/<name>.js` files | package directories, e.g. `./plugin-packages/forge-guard` |
| Credentials | `opencode auth list` (human output) | `opencode auth list --standalone --format json` |

The branch guard was ported to the OpenCode 2 plugin API: the module exports a
default definition with an `id` and a `setup(context)` function, registers the
veto with `ctx.tool.hook("execute.before", ...)`, inspects the `shell` tool and
its `input.command`, and runs every Git command with the session directory
(`ctx.location.directory`) as the working directory.

**Historical conclusion, later refuted:** an early cold-service observation
was summarized as “OpenCode 2.1.4 cannot enumerate local plugins.” That was too
broad. The same 2.1.4 runtime returned `No plugins found` while its managed
service was cold, but returned a single local `forge-guard` row after that
service had loaded the overlay plugin. The server registration identifies the
responding process, URL, and PID; the runtime log records `loading plugin` and
the copied `forge-guard/index.js` entry point. The evidence therefore points to
service context/readiness, not an inherent 2.1.4 prohibition. It does not
establish that `plugin list` and `GET /api/plugin` are necessarily independent
inventories: the latter continued to return `data=[]` under its documented
enabled-server-plugin/status contract.

`forge-opencode plugin list` now takes a deterministic path in both cold and
warm environments. It materializes the effective installed overlay/config
(including plugin declarations/options and relative package layout) into a
mode-0700 temporary tree, omits inherited service records, and launches an
exclusive `serve --service --hostname 127.0.0.1 --port 0` backend with private
XDG state and authenticated health/PID/listener checks. It polls the pinned
runtime's actual `plugin list` output every 250 ms (each call at most 2 s; 30 s
startup/enumeration budget, 35 s including cleanup). Empty startup results are
not published. The complete CLI output is returned unchanged only when the
runtime reports exactly one local `forge-guard` row from the copied package;
extra/malformed rows, CLI errors, timeout, or cleanup errors fail closed. No
`--standalone` is injected or accepted by this CLI leaf, and help does not
start a backend. No list is synthesized from configuration or package
metadata. MCP/provider declarations are excluded from this inventory probe so
it does not start external integrations.

An earlier runtime `loading plugin` log is useful corroboration of loader
activity, not a replacement for the CLI inventory or a functional hook test.
A new functional hook corroboration was **not run**; historical denied-commit
evidence remains separate.

The OpenCode 1 task-infrastructure observer was **removed**: OpenCode 2
propagates the failure of a `subagent` call to the parent session on its own,
so a parallel observer would duplicate (or distort) that contract. Do not
reintroduce it.

`@warp-dot-dev/opencode-warp` was **removed** from the global configuration:
it depends on the OpenCode 1 plugin runtime (`@opencode-ai/plugin`) and
cannot run on OpenCode 2. The previous configuration is kept in the backup, so
it can be restored when the plugin is OpenCode 2 compatible again.

## Decision D1 — migrate the data or start fresh

| Option | What it does | When to choose it |
|--------|--------------|-------------------|
| `migrate` (recommended) | Imports the OpenCode 1 credentials and sessions into the OpenCode 2 tables | The historical sessions must stay reachable |
| `fresh` | Removes the OpenCode 1 database and credentials; OpenCode 2 starts from an empty state | The historical sessions are not needed |

A migration of the database is **not reversible by reinstalling OpenCode 1**:
running OpenCode 1 against a migrated (or fresh) OpenCode 2 database is not a
rollback. The only rollback is restoring the complete backup.

With `fresh`, the user has to authenticate OpenAI/MiniMax again when they are
not provided through environment variables.

## Decision D2 — who owns the OpenCode binary

| Option | What it does | When to choose it |
|--------|--------------|-------------------|
| `forge-pinned-prefix` (current default) | Forge installs `@opencode/cli@2.1.4` in its own isolated prefix and runs it by absolute path | **Always.** The OpenCode build that Omarchy manages in `PATH` is left untouched |
| `operator-managed` | The operator installs the V2 build in `PATH` by hand and Forge only records it | Only when the OpenCode build must be shared with other tools |

The original plan assumed that the Omarchy wrapper would be regenerated with
`omarchy npx install @opencode/cli@2.1.4 opencode`. **That was changed**: the
user decided that Forge must not touch the Omarchy installation, because an
Omarchy update would silently reinstall OpenCode 1 and break Forge. Forge
therefore owns its pinned build in an isolated prefix and never reads the
`PATH` binary.

The installer is the repository-root `install.sh`. Its `status` and `doctor`
commands perform static checks and isolated operational probes of `auth list`,
`session list`, and a separate runtime plugin enumeration. The plugin probe
copies the config and declared local packages from the installation selected
by the manifest (not the checkout), keeps plugin options/relative paths,
omits MCP/providers, uses a private coherent DB snapshot, and invokes the
installed launcher. A safe-preparation failure is `UNAVAILABLE`; an executed
but empty, incorrect, timed-out, or failed enumeration is `MISMATCH`/`INVALID`;
only an exact runtime row is `OK`. Either non-OK state prevents an overall
healthy result. The auth/session probe details and payloads remain sanitized.
Diagnostics do not install, repair, sync, update, or migrate production state.
Installing/updating the overlay is a separate, explicit operation, not a
diagnostic repair action.

## Backup

Back up **everything** before touching the machine. The OpenCode 1 data lives
in several places and a partial backup is not a rollback:

```text
~/.local/bin/opencode            # the OpenCode 1 wrapper (Omarchy)
~/.local/bin/forge-opencode       # the Forge launcher
~/.config/opencode                # the global OpenCode configuration
~/.config/opencode-forge          # the Forge overlay
~/.local/share/opencode           # the database and the data directory
~/.local/state/opencode           # the state directory
~/.opencode-tokens                # the Forge token file
~/.forge-state.json               # the Forge manifest
```

The backup must be taken with OpenCode stopped, and it must include the
`opencode.db`, `opencode.db-wal` and `opencode.db-shm` files together.

## Trial on a copy

The trial never touches the productive database: `OPENCODE_DB` points at the
copy.

```bash
set -euo pipefail
HOME=/home/espinilleitor
RUN="$HOME/.local/state/forge/opencode-v2-migration/current"
TRIAL="$RUN/trial"

mkdir -p "$TRIAL/config"
python3 - "$HOME/.local/share/opencode/opencode.db" "$TRIAL/opencode.db" <<'PY'
import pathlib, sqlite3, sys
source = pathlib.Path(sys.argv[1]).resolve()
target = pathlib.Path(sys.argv[2])
src = sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)
dst = sqlite3.connect(target)
try:
    src.backup(dst)
finally:
    dst.close()
    src.close()
PY

cat > "$TRIAL/config/opencode.jsonc" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "update": "disable"
}
JSON

OPENCODE_DB="$TRIAL/opencode.db" \
OPENCODE_CONFIG_DIR="$TRIAL/config" \
OPENCODE_CONFIG="$TRIAL/config/opencode.jsonc" \
  npx --yes --package '@opencode/cli@2.1.4' -- opencode serve --hostname 127.0.0.1 --port 4097
```

Then, against that private server:

```bash
npx --yes --package '@opencode/cli@2.1.4' -- opencode auth list --server http://127.0.0.1:4097 --format json
curl -fsS http://127.0.0.1:4097/api/experimental/migration/v1
```

This trial is isolated to `$TRIAL/opencode.db`; do not substitute the
production path. The source is copied with SQLite's backup API from a
read-only connection, not by copying a live main/WAL/SHM set with `cp`.
The migration endpoint must report `completed` before a separately authorized
productive cutover is considered.

## Cutover

The cutover utilities for this machine are external to the repository:
`/home/espinilleitor/forge-v2-cutover-20261024/cutover.sh`,
`/home/espinilleitor/forge-v2-cutover-20261024/lib/dbtool.py`, and
`/home/espinilleitor/forge-v2-cutover-20261024/CUTOVER-NOTES.md`. The script
performs a `/proc` inventory and fails closed if process details are
inaccessible. Static inspection also shows a cleanup helper that sends TERM
and then KILL to processes holding the configured DB, including a post-
preflight cleanup path; do not assume it can only affect its own child. This
is a material operational risk to review before any separately authorized
execution. This documentation update did not run the cutover or initiate a
migration, and no process was stopped.

## Acceptance checks

```bash
bash install.sh status
bash install.sh doctor
~/.local/bin/forge-opencode --version
~/.local/bin/forge-opencode plugin list
```

`plugin list` must print the real runtime table with exactly one local
`forge-guard` row in cold and warm contexts; `No plugins found`, extra rows, or
nonzero status is failure. A cold first request can be empty while the
server-side config location/plugin loader is still initializing. The launcher
therefore uses its own ephemeral backend and bounded repeated CLI queries,
never a shared service or a synthetic list. `GET /api/plugin` has separately
been observed as HTTP 200 with `data=[]`; its OpenAPI wording is enabled server
plugins/current status. That observation is not forced to match or stand in for
the CLI list, and does not prove the inventories are necessarily independent.

`status`/`doctor` run the runtime plugin probe on a private copy of the selected
installed overlay/config and a private DB snapshot. MCP/provider declarations
are omitted; this checks plugin enumeration, not full configuration or
integrations. A source/dependency that cannot be safely isolated is
`UNAVAILABLE`; an executed empty/wrong/error result is a failure; only the exact
CLI row is `OK`. Diagnostics also probe auth/session separately and suppress
their payloads. They remain read-only and do not repair or migrate production.
The historical cold-service conclusion is retained above as a refuted
diagnosis. The functional hook corroboration remains a separate, unrun check.

For a read-only database coverage check after migration, use a coherent SQLite
read transaction and compare IDs, not table totals:

```python
import pathlib, sqlite3
db = (pathlib.Path.home() / ".local/share/opencode/opencode.db").resolve()
c = sqlite3.connect(db.as_uri() + "?mode=ro", uri=True)
try:
    c.execute("PRAGMA query_only=ON")
    c.execute("BEGIN")
    print("quick_check:", c.execute("PRAGMA quick_check").fetchone()[0])
    print("marker:", c.execute("SELECT value FROM kv WHERE key='migration.v1-v2'").fetchone()[0])
    print("session:", c.execute("SELECT COUNT(*) FROM session").fetchone()[0])
    print("session_v2:", c.execute("SELECT COUNT(*) FROM session_v2").fetchone()[0])
    missing = c.execute("""SELECT COUNT(*) FROM session AS s
        WHERE NOT EXISTS (SELECT 1 FROM session_v2 AS v WHERE v.id=s.id)""").fetchone()[0]
    v2_only = c.execute("""SELECT COUNT(*) FROM session_v2 AS v
        WHERE NOT EXISTS (SELECT 1 FROM session AS s WHERE s.id=v.id)""").fetchone()[0]
    print("v1_missing_in_v2:", missing)
    print("v2_only:", v2_only)
finally:
    c.close()
```

The permanent coverage criterion is `v1_missing_in_v2 == 0`. Report both
measured counts and `v2_only`, but do not fail because V2 has additional native
sessions. Equality of counts is only a documented observation immediately
after a cutover, never a continuing acceptance requirement.

## Rollback

Restoring OpenCode 1 requires restoring the complete pre-migration backup;
reinstalling its binary against a V2-migrated database is unsupported. This is
not a recommended remediation for plugin enumeration or its startup-readiness
race. A restoration
is a separate, explicitly authorized operation. The machine-specific utility
is `/home/espinilleitor/forge-v2-cutover-20261024/ROLLBACK.sh`; inspect its
preflight and the external `CUTOVER-NOTES.md` before any such decision. No
rollback or restoration was performed for this documentation update.

## Risks and known limits

- **An Omarchy update can reinstall OpenCode 1 in `PATH`.** Forge does not
  use that binary, so the overlay keeps working; only the plain `opencode`
  command of the shell changes behaviour.
- The historical Omarchy check was a metadata fingerprint through depth 3,
  plus checksums for three backed-up files. It was not an exhaustive content
  fingerprint and does not prove every Omarchy file was unchanged.
- **Warp is temporarily unavailable.** The Warp plugin depends on the
  OpenCode 1 plugin runtime; it is restored when a OpenCode 2 compatible
  release exists.
- **A migrated database is not backwards compatible.** Reinstalling OpenCode
  1 does not restore the previous state; any restoration requires a separately
  authorized operation using the complete backup.
- **Plugin enumeration depends on server context during startup.** A plain cold
  managed-service request was observed empty and a later request after plugin
  loading listed `forge-guard`. The launcher now removes that race by using a
  fresh private service per `plugin list` and polling only the real CLI with
  bounded timeouts. `/api/plugin` has separately returned `data=[]`; no
  necessary independence between CLI/API inventories is inferred. Static
  package presence and load logs are not substitutes for runtime enumeration
  or functional hook corroboration.
- **Session counts are dated observations, not constants.** The earlier
  `session=881` / `session_v2=884` observation is retained as a 2026-10-24
  observation; its exact UTC time is not preserved in the available evidence.
  At `2026-10-24T22:03:41Z`–`22:03:43Z`, a read-only coherent query of the
  completed sandbox copy measured `session=881`, `session_v2=887`,
  `v1_missing_in_v2=0`, `v2_only=6`, `quick_check=ok`. The permanent criterion
  is `v1_missing_in_v2 == 0`; V2-only sessions are allowed.
- **Historical event counts conflict.** The archived cutover report was
  generated at `2026-10-24T20:30:48Z`; its table records `event` 15489→11079
  (−4410) and `event_sequence` 881→878 (−3), while its prose incorrectly says
  the counts are equal. A separate pair cited in the earlier material,
  `event_sequence` 881→978, has arithmetic delta +97 and conflicts with the
  archived row. Retained SQLite copies confirm 881→878 for that particular
  snapshot/reference. These are measurements of different retained evidence;
  no session-loss conclusion follows from event-table counts.

## Safety follow-ups — evidence and limits (2026-10-25)

This is a bounded acceptance of reusable functions and a direct guard-hook
check, not an end-to-end migration acceptance. The follow-up harnesses use the
real shared implementations from `open-code/lib/plugin-sync.py` and the
external `lib/cutover_safety.py` against synthetic SQLite files and
batch-owned processes. They do not reimplement the production algorithms.
Process tests ran only after rootless private PID-namespace containment was
proved and an outside watchdog was ready. No complete cutover/rollback entry
point, migration, reset, restoration, real OpenCode session, provider request,
or pre-existing process was used by this automated acceptance. Separately, the
Step 4.2 operational intervention for PID 530393 was carried out in read-only
inspection and ended blocked; it is not synthetic coverage, part of the GLOBAL
VERIFIER, or an execution from a test tool.

| Follow-up | Requirement and result | Limits / remaining action |
|---|---|---|
| **#1 — shared snapshot/deadline/fuse functions** | Validated dynamically against synthetic resources through the actual shared functions. The automated suite reports 52 cases: 43 dynamic, 4 simulated, 5 inspected, 0 failures, RC 0; the snapshot checks transactional consistency and isolation, and the deadline/fuse checks include the isolated `os._exit(124)` path. | This does not execute the migration or any complete entrypoint. A focused dynamic fuse proof already existed before this batch: RC 124, owned backend terminated, private root removed. The new objective was repeatable automated coverage, not a claim that no dynamic evidence existed. `FORGE_V2_TEST_NO_PIDFD` and `FORGE_V2_TEST_HANG_SUITE` exercise failure/barrier-cleanup paths only when explicitly injected; they are not part of the standard green run. |
| **#2 — shared pidfd/holder/group safety functions** | Validated dynamically, with real shared functions and synthetic processes/files; deterministic OS-condition cases are separately reported as simulation, and source/function identity is inspected separately. Coverage includes pidfd identity rejection and bounded stop, DB/WAL/SHM/`-journal` and deleted-path holder classification, and the existing process-group cleanup behavior. | Simulations of permission denial, disappearance, and PID reuse are not real host signal/PID-reuse tests. No pre-existing process was signalled. This is function-level evidence, not an operational cutover test. |
| **#3 — process-group cleanup contract** | Residual risk explicitly accepted and documented; `killpg` and the group/descendant cleanup contract remain in place. `GRP-1` dynamically exercised one early-leader-exit case: the leader exited while one owned descendant remained, and the tested group was emptied. | A pidfd identifies one process; by itself it does **not** preserve cleanup of a process group and its descendants. The early-leader case is bounded evidence, not proof of every descendant/race arrangement. A theoretical PID/PGID reuse window remains. Removing `killpg` requires a separate design/plan for descendant tracking or equivalent containment; it is not a mechanical pidfd substitution. |
| **#4 — forge-guard** | The real guard package and its `execute.before` callback were directly corroborated with a simulated context. The adapted suite passed 18/18 checks in five runs; 0 pushes were attempted, no protected-branch commits were created, and the three commits were confined to `feature`. | **Direct hook corroboration with simulated context; OpenCode end-to-end dispatch not tested.** No real OpenCode session/conversation or tool dispatch occurred; this does not establish the effect of the hook on a real shell execution. Guard policy was not changed. |
| **#5 — PID 530393** | The separate Step 4.2 operational intervention was carried out. Identity was verified with an open pidfd, UID 1000, `inicio_ticks=26522468`, exe `/tmp/opencode/cutover-lab/xdg/data/forge/opencode-v2/node_modules/@opencode/cli/bin/opencode.exe (deleted)`, cmdline `opencode serve --hostname 127.0.0.1 --port 34765 --print-logs`, and DB/WAL/SHM FDs under the lab (all `(deleted)`); no descendants or TTY were observed and there were no established connections. | **Terminal result: BLOCKED** because residuality was not accredited. `/proc/<pid>/fd` was inaccessible with EACCES for three non-zombie UID-1000 processes: PID 860 (`systemd --user`, parent of the target), 863 (`(sd-pam)`), and 1169 (`fusermount3`). Their prior references therefore could not be ruled out. No signal was sent; PID 530393 remains alive and intact. Evidence: [`/tmp/opencode/forge-v2-followups/pid-530393-intervention.md`](/tmp/opencode/forge-v2-followups/pid-530393-intervention.md). This operational intervention is separate from synthetic coverage, is not part of the GLOBAL VERIFIER, and was not run from a test tool. |

The safety result distinguishes **dynamic tests** (real functions/resources in
the private namespace), **simulations** (injected OS conditions, not real
signals or PID reuse), and **inspections** (identity, signatures, and absence
of complete-entrypoint execution). The automated acceptance of functions
does not establish an end-to-end cutover: migration, reset, restoration, and
the complete operation of `cutover.sh` / `ROLLBACK.sh` were not executed.

### Component identity and fingerprints

Versions below are the versions declared by the component itself; target
OpenCode versions are not script/library versions. A component without a
declared version is identified by its content hash. Initial external hashes
are from the independent Step 1.1 backup. The final hashes of all six external
components, including the edited notes and report, are in the external
evidence manifest `/tmp/opencode/forge-v2-followups/external-after.sha256`;
that manifest is authoritative and is not embedded into itself.

| Component and path | Declared version | Initial → final SHA-256 |
|---|---|---|
| External `cutover.sh` — `/home/espinilleitor/forge-v2-cutover-20261024/cutover.sh` | Not declared (its `CUTOVER_EXPECTED_VERSION` targets OpenCode 2.1.4) | `6b1e7d6ee464d122e3d9380080fc474ad383e46a253a2e0aebfb927400e1f681` → `824897d990db781199c5bad26c186b7a2665c9ad167ef9482a44946780a5b613` |
| External `ROLLBACK.sh` — `/home/espinilleitor/forge-v2-cutover-20261024/ROLLBACK.sh` | Not declared (mentions OpenCode 1.19.4 / 2.1.4) | `691829305d19a4988ff8a0d02ffcb9705900745ab20c68b01b5d5d0ed2e5075d` → `f91e7787ce7690fc0d5ec70aaafa5c051acb3b379006214c0e870e84474f8f85` |
| External `CUTOVER-NOTES.md` — `/home/espinilleitor/forge-v2-cutover-20261024/CUTOVER-NOTES.md` | Not declared; OpenCode 2.1.4 is a compatibility target | Initial and final hashes: see `/tmp/opencode/forge-v2-followups-checkpoint/external.sha256` and `/tmp/opencode/forge-v2-followups/external-after.sha256` |
| External `lib/dbtool.py` — `/home/espinilleitor/forge-v2-cutover-20261024/lib/dbtool.py` | Not declared; its docstring describes the 1.19.4 → 2.1.4 flow | `d15cc6aea6289683b9df7add7fcb82f27ba3eaddcb8368a563f1be8a98ab0db0` → unchanged |
| External `REMEDIATION-REPORT.md` — `/home/espinilleitor/forge-v2-cutover-20261024/REMEDIATION-REPORT.md` | Not declared; OpenCode 2.1.4 is an observation | Initial and final hashes: see `/tmp/opencode/forge-v2-followups-checkpoint/external.sha256` and `/tmp/opencode/forge-v2-followups/external-after.sha256` |
| New external `lib/cutover_safety.py` — `/home/espinilleitor/forge-v2-cutover-20261024/lib/cutover_safety.py` | Not declared | absent → `1e93447968a4f3ddb4395022260c89d643aa696c95edd003f853e79db4378454` |
| Repo `open-code/lib/plugin-sync.py` | Not declared (V2-only, not a semantic version) | `70966cf5fac50faea615d882ff2c2e326729b5df883fe14507a84c72af415e9e` → `7760fd6a143fa906d6bf5b85df1ea8715cf8d04de83be440cea75e04e4cac8b5` |
| Repo `tests/forge_guard_plugin_unit.sh` | Not declared | `a60d8c2d6ff1b75e5fd26b8139b0abb405c77125f3ecf3d2a9c5bc1b9a8e86d4` → `318cac66866a14d81ae796000c17a05b0e2c9d4aca5422443203b50d70f5a7d5` |
| New repo `tests/forge_v2_safety.sh` | Not declared | absent → `cbbbe39953c1af23935f6315a3a75908b6f24e28fc4d060739163afb3a2da4b9` |
| New repo `tests/forge_v2_safety_harness.py` | Not declared | absent → `451cfce0b85ea9653e67588d5cc906d6b1ec96d1c824d4941eeab024742ca718` |
| Guard package `open-code/plugin-packages/forge-guard/package.json` / `index.js` | `forge-guard` 1.0.0 | `package.json` `1a19e5f2dbf7c4580aaa3c128b347e314a9e0002d9a28e2236b32823b5ff0220`; `index.js` `e1d2eb0dad24c0d0f8660f0e7d58297de67a9a23d341cc47be2ea3a83e5c007a` (unchanged from inventory) |
| Runtime target `@opencode/cli` | 2.1.4 (declared package target; not a changed component) | Not fingerprinted as part of the follow-up component manifest |

The detailed requirements/results/limits and the complete initial-to-final
fingerprint map are also recorded in
`/tmp/opencode/forge-v2-followups/acceptance.md`. The final hashes for the
edited external documents are deliberately referenced from the external
manifest rather than asserted inside those documents.

## Coverage-closure batch — dispositions and evidence (2026-10-25)

This is a new status entry for the coverage-closure batch; it does not replace
or revise the historical conclusions above. The Step 3.2 GLOBAL VERIFIER
acceptance is complete with RC 0; its actual timings and evidence are recorded
below and in the linked evidence documents.

### Follow-up — corte exterior y limpieza previa del supervisor

El verificador registra por ejecución la identidad del launcher/suite interior
asociada a la ruta única del informe. Ante corte exterior, interrupción o error,
congela primero el grupo exterior propio, termina y espera la ausencia en `/proc`
del launcher y la suite de su sesión propia, y solo entonces retira al supervisor;
el resumen excepcional conserva ambos grupos, start ticks y estados de ausencia.
El contrato de `killpg` se conserva sin rediseñar B. El guard exterior por defecto
es 600 s: queda después del timeout interno normal de 300 s, que empieza una vez
terminada la preparación/autorización, y deja margen documentado para preparación
y limpieza acotadas. La prueba de corte forzada (guard 8 s, RC global 1 esperado)
y la verificación autónoma por defecto (RC 0) constan en
[`exceptional-cleanup.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/exceptional-cleanup.md)
y `runs/20261025T164452.668671570-2072645/`.

### A — negative safety scenarios

The delivered `tests/forge_v2_safety_scenarios.sh` contract adds sequential
`normal`, `no-pidfd`, and `no-pidfd-hang` scenarios. The autonomous verifier
integrates both negative scenarios into each successful run: `no-pidfd` must
prove authorization was denied before any sensitive case, while
`no-pidfd-hang` must prove a real timeout and cleanup of its own init and
synthetic descendant with pidfd disabled. Its injection occurs before the
authorization barrier, so that scenario proves cleanup, not authorization
denial. Expected incremental cost was two additional isolated starts and about
20 seconds of timeout, plus preparation and cleanup. The final measured run
used three starts total (one normal plus two additional): `no-pidfd` took
0.620 s and `no-pidfd-hang` took 20.550 s, including preparation and cleanup.
The timeout was 20.001 s and combined negative-path cost was 21.170 s. These
are observed costs, not new cost thresholds.

### POSIX launcher contract

`forge-opencode` is declared `#!/usr/bin/env sh` and must remain POSIX (no arrays or `+=`), because `sh` is `dash` on supported systems; `shellcheck -s sh` is the static guard for this contract.

### Guard temporal de la interfaz y RC 13/14/15

La supervisión temporal de la interfaz permanece activa durante la ejecución
completa, con lecturas y esperas acotadas por su propio plazo. El guard de la
interfaz es 420 s por defecto (`FORGE_V2_SCENARIO_GUARD`) y el guard exterior del GLOBAL VERIFIER
es 600 s por defecto (`FORGE_V2_OUTER_SCENARIO_GUARD`, nunca por debajo de 600 s); ambos plazos son
independientes para que el exterior no corte la limpieza de la interfaz.
**RC 13** indica guard exterior contradictorio; **RC 14** indica guard de interfaz vencido con
limpieza acreditada y **RC 15** indica vencimiento con limpieza incompleta. Los tres son fallos duros globales, no se
reinterpretan como éxitos ni como RC de supervisor/suite. Estos RC por capa se
leen exclusivamente de `verdict.json` (`supervisor_rc`, `suite_rc`) y
`safety-results.json` (`cleanup.suite_returncode`).

En el camino de vencimiento, el GLOBAL VERIFIER valida de forma independiente
`guard-expiry.json` y `guard-verdict.json`: legibilidad, `survivors == []`, RC
del ejecutor concordante, PIDs/grupos propios registrados ausentes en `/proc`
y plazo respetado. La prueba negativa explícita con guard de interfaz de 5 s y
guard exterior de 600 s produjo RC del ejecutor 14 y RC global **1** (fallo
duro requerido), con la evidencia conservada en
`runs/20261025T171005.295367971-2088071/`. La ejecución autónoma satisfactoria
posterior terminó RC **0** y acreditó los RC ejecutor/supervisor/suite
`0/0/0`, `0/6/4` y `0/6/-9` para `normal`, `no-pidfd` y `no-pidfd-hang`, respectivamente; véase
`runs/20261025T171021.598466224-2088493/summary.md` y su `acceptance.md`.

La prueba histórica de corte `runs/20261025T164706.784704034-2077577/` usó el script pre-split:
allí `FORGE_V2_SCENARIO_GUARD=8` se interpretó como exterior y no acredita el código entregado.
Tras el split, el camino excepcional se verifica mediante
`FORGE_V2_OUTER_SCENARIO_GUARD` por encima del guard de interfaz y el manejador `TERM` del GLOBAL
VERIFIER; la señal dirigida no se presenta como expiración natural del timer. Los tres casos de
fallo de limpieza y sus límites de espera están documentados en
[`exceptional-cleanup.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/exceptional-cleanup.md).

### B — process-group cleanup

The existing `killpg` cleanup contract is retained. It can clean the owned
process group, including descendants, even after the group leader exits; the
group identifier cannot be reused while that original group still exists. A
real residual race remains after the entire group disappears. The evidence
does not demonstrate an exploit or a reproducible defect, and the residual
race remains accepted under the existing policy. Checking the leader's start
identity does not remove the TOCTOU window; requiring the leader to remain
alive would break a covered early-leader-exit case. Genealogical pidfd tracking
or cgroups would be redesigns outside this batch. Neither implementation nor
acceptance policy was changed.

### C — PID 530393 and blocked intervention

The test OpenCode server remains alive and intact temporarily; it is neither
reported as cleaned nor made a permanent acceptance by this entry. The latest
historical intervention evidence did not show established connections or
references from this server to the productive database, but that dated result
is not a guarantee of its current harmlessness. The required stop criterion
remains blocked because permissions prevented completing the reference check
for three other processes; this does not establish that those processes use
the files. Repeating device/inode checks, or switching to `/proc/*/maps` or
`fanotify`, cannot retrospectively reveal inaccessible open descriptors, so
the global investigation is not repeated. No process was signalled. Stopping
it later requires explicit authorization of a revised criterion, revalidation,
and a pidfd-directed signal, outside this plan. Killing `systemd --user` is
ruled out; a normal future restart may retire the server but will not be
induced, and logging out alone does not guarantee that result.

See [the A/B/C disposition and evidence limits](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/disposition-b-c.md)
and [the dated PID status](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/pid-530393-status.md).

### Step 3.2 — GLOBAL VERIFIER acceptance and measured cost

The autonomous verifier completed with **RC 0** on 2026-10-25, using new run
evidence at
`/tmp/opencode/forge-v2-coverage-closure-20261025/runs/20261025T161944.999989623-2054585/`.
The normal route passed all 52 safety cases (43 dynamic, 4 simulated, 5
inspection) with supervisor/suite/executor RC `0/0/0` and 16/16 semantic
checks. `no-pidfd` passed 19/19 semantic checks with RCs supervisor/suite/
executor `6/4/0`, proving explicit authorization denial before sensitive
cases and immediate cleanup. `no-pidfd-hang` passed 19/19 checks with RCs
`6/-9/0`, a real 20.001 s timeout, one synthetic child, and verified cleanup
without pidfd. Its injection precedes the authorization barrier; it does not
claim authorization denial. The forge-guard suite also passed 18/18 checks.

| Route | Preparation (s) | Execution (s) | Timeout (s) | Cleanup (s) | Total (s) | Namespace starts |
|---|---:|---:|---:|---:|---:|---:|
| Normal | 0.048 | 98.762 | 0 | 0.390 | 99.200 | 1 |
| `no-pidfd` | 0.064 | 0.206 | 0 | 0.350 | 0.620 | 1 |
| `no-pidfd-hang` | 0.053 | 0.143 | 20.001 | 0.353 | 20.550 | 1 |
| Negative routes combined (additional cost) | 0.117 | 0.349 | 20.001 | 0.703 | 21.170 | 2 |

The expectation of two additional isolated starts and approximately 20 seconds
of timeout was met. No threshold is inferred from this single measurement.
Detailed acceptance, resource state, and isolation evidence are in
[`acceptance.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/acceptance.md),
[`cost.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/cost.md),
[`resources-final.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/resources-final.md),
and [`isolation.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/isolation.md).
The tester-owned bytecode fix is preserved separately in
[`safety-results-bytecode-fix.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/safety-results-bytecode-fix.md)
and its latest test report in
[`safety-results-latest.json`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/safety-results-latest.json);
the historical previous-lot evidence was restored byte-for-byte and audited
against its checkpoint.
The PID 530393 remained alive with the same start ticks and listener; no signal
or intervention occurred. The original database was accessed only by `stat()`
for this phase; a concurrent mtime change is recorded without attributing it
to this verifier.

### Final post-split verification after re-review

The final launcher closes a race in the RC 13 path: the process created under
`setsid --fork --wait` publishes its PID and waits for a bounded registration
handshake before executing the scenario interface. The parent validates the
process start ticks, PGID, and SID, then releases it. Thus, an immediate
contradictory-guard exit cannot precede group registration; absent supervisor
logs are handled without aborting sequential evidence collection. This does
not change the approved `killpg` contract.

The final RC 0 GLOBAL VERIFIER run is
`runs/20261025T180255.395291197-2123545/`, with interface/exterior guards
420/600 s. The executor returned `0/0/0`; the supervisor/suite RC pairs were
`0/0`, `6/4`, and `6/-9` for `normal`, `no-pidfd`, and `no-pidfd-hang`. Normal
passed 52/52 cases and 16/16 semantic checks; the negative scenarios passed
19/19 each; forge-guard passed 18/18. The groups recorded in
`own-process-groups.tsv` have no live members. The measured totals were
99.260 s normal, 0.620 s `no-pidfd`, and 20.660 s `no-pidfd-hang`.

The final negative probes are deliberately separate from that successful
acceptance: RC 13 from equal 600/600 guards is a hard-failure probe (all three
outer groups were registered and empty; no scenario reached its supervisor),
RC 14 from a 5 s interface guard was independently validated with zero
survivors, and RC 15 detected three survivors before forced recovery to zero
live resources. Each has the expected nonzero GLOBAL VERIFIER RC 1. Three
post-split `TERM` probes exercised outer identity revalidation failure,
`SIGSTOP` failure, and a forced false inner-absence result; all three ended
with launcher, suite, supervisor, and owned groups absent. `TERM` was sent to
the GLOBAL VERIFIER process started by each probe; this is not represented as
natural timer expiry. Exact run paths, identities, budgets, and the RC 15
probe-mode note are in
[`exceptional-cleanup.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/exceptional-cleanup.md)
and [`acceptance.md`](/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/acceptance.md).

The initial historical component/measurement tables above were not rewritten;
the post-split run is an appended status update, not a replacement for those
dated observations. The Step 1.1 direct-read deviation remains recorded and
was not repeated; the original DB was accessed only with `stat()` during these
follow-ups. PID 530393 remained alive with the checkpoint identity and local
listener and received no signal.

### Coverage-closure component fingerprints

These hashes identify the files at this documentation step; the two
unchanged-worktree references are retained as-is. Hashes of the six external
files are checked against the immutable batch checkpoint, not recopied here.
The final hash of this document is recorded in the external batch manifest
`/tmp/opencode/forge-v2-coverage-closure-20261025/evidence/fingerprints.sha256`
so the document does not embed a self-referential digest.

| Component | SHA-256 |
|---|---|
| `tests/forge_v2_safety_harness.py` | `d8b58d47771173edac6a2ec38c47d22b165fa20aada3a790498f53a3e1ec852b` |
| `tests/forge_v2_safety_scenarios.sh` | `301fbf40816e3bbbb36597adc8ddbd3c5505b1f873f970ef878193705b0272c1` |
| `tools/verification/forge-v2-followups.sh` | `f193308b9cfd5d8ad44d5b74352623f38b7120c3d9769289aa1dacf336f6477f` |
| `open-code/forge-opencode.sh` | `c33860443e5b0ec8191329d8735bb1009b6eca24c35e68906441cf752990b752` |
| `tools/verification/verify-forge-v2-syntax.py` | `ee316af286a368dd556c89bcc70ed391238feab5791f8a928a124f5591f9839b` |
| `open-code/MIGRATION-V2.md` | Final hash: véase el manifiesto externo de esta entrega; no se inserta aquí. |
| `open-code/lib/plugin-sync.py` (unchanged) | `7760fd6a143fa906d6bf5b85df1ea8715cf8d04de83be440cea75e04e4cac8b5` |
| `tests/forge_guard_plugin_unit.sh` (unchanged) | `318cac66866a14d81ae796000c17a05b0e2c9d4aca5422443203b50d70f5a7d5` |

## Runtime health contracts and real-runtime integration (2026-10-25)

Health has two distinct acceptance contracts; static checks alone never stand
in for runtime health:

- **Runtime unavailable or not exercisable** (the fake runtime used by the
  ordinary tests): `status` and `doctor` return RC 1 and report
  `Estado general: DEGRADADO`; they identify `plugin-runtime` with its cause.
  Other healthy static checks may still pass, but they do not make the overall
  result healthy. `UNAVAILABLE` remains a health-blocking result; the product
  contract was not relaxed.
- **Real OpenCode CLI 2.1.4**: the real-runtime integration scenario requires
  `status` RC 0 with `Estado general: OK`, `doctor` RC 0 with `FAILs=0`, and
  the exact runtime inventory containing one `forge-guard` entry. Its
  row must be `ID=forge-guard`, `VERSION=local`, and `SOURCE` must end in
  `plugin-packages/forge-guard/index.js` within the scenario's isolated copy.
  The header is exactly `ID VERSION SOURCE`. This is real runtime enumeration,
  not a result inferred from static package files.

`tests/run-all.sh` is the effective suite entry point and discovers
`tests/*_integration.sh`, including
`tests/opencode_real_runtime_integration.sh`. That scenario is mandatory: its
failure propagates as a nonzero suite result; a missing runtime is an explicit
failure, never a green skip. In CI, install the required CLI globally with
`npm install -g @opencode/cli@2.1.4`; the scenario resolves and uses that real
binary. It does not require Forge's pinned prefix to be installed.

For local execution, optionally set `FORGE_TEST_REAL_OPENCODE_BIN` to the
absolute path of an existing executable for real OpenCode CLI 2.1.4, for
example:

```sh
FORGE_TEST_REAL_OPENCODE_BIN="$HOME/.local/share/forge/opencode-v2/node_modules/.bin/opencode" \
  tests/opencode_real_runtime_integration.sh
```

Without the override, resolution uses the global npm installation. The
scenario never uses the `~/.local/bin/opencode` user wrapper; it rejects a
resolved binary that points there. If neither source provides the required
runtime, it reports the cause and fails. It does not install tools, change the
local OpenCode version, or alter the local installation. Do not uninstall or
remove the user's real OpenCode installation to obtain a green test result.

The test compares the `forge-`-prefixed state before and after execution so a
pre-existing environmental entry is not mistaken for a write by the test:
absent → absent passes; absent → present fails; present → absent fails; and
present → present passes only when its fingerprint shows no mutation. This
comparison avoids the false environmental failure without hiding new entries,
deletions, or changes to pre-existing state.

The isolated real CLI scenario also has harness-specific requirements. It sets
its own `XDG_RUNTIME_DIR`, which the real CLI needs to register its private
service, and uses a controlled `PATH` rather than inheriting the caller's PATH
(which may contain the user wrapper). These are test-isolation requirements,
not changes to the product runtime contract.

### Provisional performance debt

On the real installation, each diagnostic costs about 16 seconds and a real
scenario about 32 seconds, plus isolation setup and cleanup. These are observed
costs, not product thresholds. The mitigation in this batch is to reuse each
captured `status` and `doctor` output in the suite rather than invoke the same
diagnostic repeatedly. There is no result cache and no relaxation of product
checks. Any future optimization requires measurement and must retain fresh
runtime enumeration, isolation, and cleanup.
