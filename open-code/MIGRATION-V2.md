# OpenCode 2 migration runbook

This runbook describes how Forge moved from OpenCode 1.19.4 to
`@opencode/cli@2.1.4`, and how to run, verify and revert that migration
without this repository.

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
| Pinned prefix (Forge-owned) | `~/.local/share/forge/opencode-v2` (`$FORGE_OPENCODE_BIN_DIR` to override) |
| Pinned binary | `<prefix>/node_modules/.bin/opencode` |
| Launcher | `~/.local/bin/forge-opencode` |
| Overlay | `~/.config/opencode-forge/` (`$OPENCODE_CONFIG_DIR` to override) |
| Config | `<overlay>/opencode.jsonc` (`$OPENCODE_CONFIG` to override) |
| Database | `OPENCODE_DB` (defaults to the OpenCode data directory) |

Rules that the migration must not break:

- **Forge never uses the OpenCode binary in `PATH`.** `forge-opencode` runs the
  pinned build by absolute path, so an Omarchy upgrade that reinstalls
  OpenCode 1 in `PATH` cannot change what Forge runs.
- **Nothing under `~/.local/share/omarchy/` is modified.** The Omarchy
  wrapper is left exactly as it is.
- **The launcher always requests a private server (`--standalone`).** OpenCode
  2 shares a background server by default; the private server is what keeps
  the Forge overlay isolated. The flag is inserted right after the subcommand,
  which is where the OpenCode 2 CLI accepts it; the leaf subcommands that do
  not offer it (`plugin`, `mcp`, `debug`, `service`) run inside the CLI
  process and never attach to the shared server, so the launcher omits it for
  them.
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

The diagnostic (`bash install.sh status` / `bash install.sh doctor`) reports a
mismatch when the pinned build is missing or is not exactly `2.1.4`, and the
repair is always `bash install.sh install --target=opencode`.

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
for name in opencode.db opencode.db-wal opencode.db-shm; do
  src="$RUN/home/.local/share/opencode/$name"
  [ ! -e "$src" ] || cp -a "$src" "$TRIAL/$name"
done

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

The migration endpoint must report `completed` before the productive cutover
is allowed to start.

## Cutover

1. Stop OpenCode (`pkill -TERM -x opencode`).
2. Install the overlay with the pinned build: `bash install.sh install --target=opencode`.
3. Apply D1 to the productive database: with `migrate`, start a private
   OpenCode 2 server against the productive `OPENCODE_DB` and wait for
   `/api/experimental/migration/v1` to report `completed`; with `fresh`,
   remove the OpenCode 1 database files and let OpenCode 2 create a new one.
4. Verify the credentials with `forge-opencode auth list --format json` and
   the sessions with `forge-opencode session list`.

## Acceptance checks

```bash
bash install.sh status
bash install.sh doctor
forge-opencode --version          # must print 2.1.4
forge-opencode plugin list        # must list forge-guard and nothing else
forge-opencode models             # must list the three models used by Forge
forge-opencode auth list --format json
```

`status` and `doctor` are read-only: the auth probe runs with an isolated
`OPENCODE_DB`, so a diagnostic never migrates the productive data.

## Rollback

The rollback restores the **complete** backup and only then restores the
OpenCode 1 wrapper. Running OpenCode 1 against a database that OpenCode 2
already migrated is **not a rollback** and is not supported.

```bash
set -euo pipefail
HOME=/home/espinilleitor
RUN="$(readlink -f "$HOME/.local/state/forge/opencode-v2-migration/current")"

pkill -TERM -x opencode 2>/dev/null || true
sleep 2

rm -f -- "$HOME/.local/bin/opencode" "$HOME/.local/bin/forge-opencode"
rm -rf -- \
  "$HOME/.config/opencode" \
  "$HOME/.config/opencode-forge" \
  "$HOME/.local/share/opencode" \
  "$HOME/.local/state/opencode" \
  "$HOME/.local/share/forge/opencode-v2"
rm -f -- "$HOME/.opencode-tokens" "$HOME/.forge-state.json"

for rel in \
  .local/bin/opencode \
  .local/bin/forge-opencode \
  .config/opencode \
  .config/opencode-forge \
  .local/share/opencode \
  .local/state/opencode \
  .opencode-tokens \
  .forge-state.json; do
  src="$RUN/home/$rel"
  dst="$HOME/$rel"
  if [ -e "$src" ] || [ -L "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
done

opencode --version                # must print 1.19.4
```

Keep the backup until several real sessions have worked with OpenCode 2.

## Risks and known limits

- **An Omarchy update can reinstall OpenCode 1 in `PATH`.** Forge does not
  use that binary, so the overlay keeps working; only the plain `opencode`
  command of the shell changes behaviour.
- **Warp is temporarily unavailable.** The Warp plugin depends on the
  OpenCode 1 plugin runtime; it is restored when a OpenCode 2 compatible
  release exists.
- **A migrated database is not backwards compatible.** Reinstalling OpenCode
  1 does not restore the previous state: the backup is the only way back.
- **The plugin list is derived from the config.** A plugin declared in
  `opencode.jsonc` but missing on disk disables its feature silently, so the
  installer verifies the whole plugin tree and fails when something is
  missing.
