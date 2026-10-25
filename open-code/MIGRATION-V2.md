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
