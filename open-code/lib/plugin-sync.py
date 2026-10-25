#!/usr/bin/env python3
"""Derive the installed OpenCode plugin overlay from the `plugins` field of
opencode.jsonc.

The set of plugins installed into the overlay is never hardcoded: it is read
from the config declaration itself. That keeps the overlay and the config
from drifting apart — a plugin declared in the config but missing on disk
disables its feature *silently* (OpenCode does not report the failure), so the
installer must never be able to reach that state.

OpenCode 2 layout (this tool is V2-only):

  * the config field is `plugins` (the V1 `plugin` field is gone),
  * a declared local plugin is a PACKAGE DIRECTORY (OpenCode 2 refuses a
    declared plugin path that is a file: "configured plugin path must be a
    directory"), so the declared tree is copied/verified/removed recursively.

Modes:

  sync    Copy every declared local plugin package from the overlay source
          into the directory that holds the installed config, prune the Forge
          plugins that are no longer declared, purge the OpenCode 1 leftovers
          and then verify the result.
  verify  Check that every declared local plugin package exists next to the
          config, file by file.
  remove  Delete every declared local plugin package (used by the uninstaller).
          With --source-root, the Forge-owned packages the source overlay
          holds are deleted too, even when the installed config is already
          gone. The Forge-owned containers of the removed trees are deleted
          as well, but only while they are empty: whatever the user placed
           inside them survives and blocks the removal of the overlay
           directory.
  runtime-copy  Materialize a selected installed overlay/config for an
                isolated runtime plugin-enumeration probe.
  snapshot-db   Create a coherent SQLite copy through a read-only source handle.
  runtime-list  Supervise a private ephemeral service and poll OpenCode's real
                `plugin list` output until it is exact or the bounded budget
                expires.

"Local" means a `./`-relative path inside the overlay (e.g.
`./plugin-packages/forge-guard`). Absolute paths and npm package specifiers
are not overlay files: they are managed outside the overlay and are never
copied.

Exit codes: sync/verify/remove/runtime-copy use 0 = ok and 1 = error; snapshot-db
uses 124 if its 35-second copy budget expires.
runtime-list additionally uses 124 for its shared runtime budget, and 130/143
after cleanup for SIGINT/SIGTERM.
"""

import argparse
import base64
import ipaddress
import json
import os
import re
import shutil
import sqlite3
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import quote

# OpenCode 1 leftovers that must not survive the migration. In OpenCode 1 the
# Forge plugins were plain `.js` files inside the overlay `plugins/` folder;
# in OpenCode 2 they are package directories under `plugin-packages/`. Every
# `plugins/forge-*.js` file is therefore a Forge-owned V1 artefact and is
# removed on sync. The pattern is used instead of a hardcoded list so a new
# V1 plugin cannot survive the migration either.
V1_RESIDUAL_DIR = "plugins"
V1_RESIDUAL_PREFIX = "forge-"
V1_RESIDUAL_SUFFIX = ".js"

# The V1 plugin runtime metadata that OpenCode 1 generated inside the
# overlay. It is only removed when it is recognisable as managed (the
# directory really is the @opencode-ai/plugin package and the overlay
# package.json declares it); unrelated user dependencies are never touched.
V1_METADATA_PACKAGE = "@opencode-ai/plugin"

# Suffixes that mark a plugin entry as a local file rather than a package
# directory. A local-looking entry that is not `./`-relative is an error: it
# cannot be mapped to an overlay source and would be silently skipped.
LOCAL_FILE_SUFFIXES = (".js", ".mjs", ".cjs")


class PluginSyncError(Exception):
    """Fatal error with a user-facing diagnostic."""


class RuntimeDeadline(Exception):
    """The bounded runtime enumeration budget expired."""


class RuntimeInterrupted(Exception):
    """The supervisor received a termination signal."""

    def __init__(self, signum):
        super().__init__(f"interrupted by signal {signum}")
        self.signum = signum


def strip_jsonc(text):
    """Remove `//` and `/* */` comments and trailing commas from a JSONC text.

    String-aware: markers inside string literals are preserved.
    """
    out = []
    i = 0
    n = len(text)
    in_string = False

    while i < n:
        ch = text[i]

        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue

        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue

        if ch == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue

        if ch == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue

        if ch in "}]":
            # Drop a trailing comma left before this closer.
            j = len(out) - 1
            while j >= 0 and out[j] in " \t\r\n":
                j -= 1
            if j >= 0 and out[j] == ",":
                del out[j]

        out.append(ch)
        i += 1

    return "".join(out)


def parse_config(path):
    """Parse a JSONC config file and return it as a dict."""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError as exc:
        raise PluginSyncError(f"cannot read config {path}: {exc}")

    try:
        data = json.loads(strip_jsonc(raw))
    except json.JSONDecodeError as exc:
        raise PluginSyncError(f"cannot parse JSONC config {path}: {exc}")

    if not isinstance(data, dict):
        raise PluginSyncError(f"config {path} is not a JSON object")

    return data


def plugin_entries(data):
    """Return the declared plugin entries as a list of strings.

    OpenCode 2 accepts either a string (`"pkg"`) or an object
    (`{"package": "pkg", "options": {...}}`). Both are reduced to the package
    specifier, which is what identifies the plugin.
    """
    plugins = data.get("plugins", [])
    if isinstance(plugins, str):
        plugins = [plugins]
    if not isinstance(plugins, list):
        raise PluginSyncError("'plugins' must be an array of strings or objects")
    entries = []
    for entry in plugins:
        if isinstance(entry, str):
            entries.append(entry)
        elif isinstance(entry, dict) and isinstance(entry.get("package"), str):
            entries.append(entry["package"])
        else:
            raise PluginSyncError(f"'plugins' entries must be strings or objects with a 'package', got {entry!r}")
    return entries


def local_entries(entries):
    """Split declared entries into overlay-relative paths and external ones.

    Overlay-relative paths are returned without the `./` prefix. Anything
    that is not `./`-relative is external: absolute paths and npm package
    specifiers are not overlay files and are never copied.
    """
    local = []
    external = []

    for entry in entries:
        if entry.startswith("./"):
            local.append(entry[2:])
        elif entry.startswith("../"):
            raise PluginSyncError(
                f"declared plugin {entry!r} points outside the overlay root; "
                "only './'-relative overlay plugins can be installed"
            )
        elif entry.startswith("/"):
            external.append(entry)
        elif entry.endswith(LOCAL_FILE_SUFFIXES):
            raise PluginSyncError(
                f"declared plugin {entry!r} looks like a local file but is not "
                "a './'-relative overlay path; it cannot be installed"
            )
        else:
            external.append(entry)

    return local, external


def safe_join(root, rel):
    """Join `rel` under `root`, refusing to escape the root.

    `..` segments, absolute paths and symlinks pointing outside the root are
    rejected: the overlay must never be written outside its own directory.
    """
    if not rel or rel in (".", "/"):
        raise PluginSyncError(f"invalid plugin path: {rel!r}")
    if os.path.isabs(rel):
        raise PluginSyncError(f"plugin path must be relative: {rel!r}")
    parts = [part for part in rel.replace(os.sep, "/").split("/") if part not in ("", ".")]
    if any(part == ".." for part in parts):
        raise PluginSyncError(f"plugin path escapes the overlay root: {rel!r}")

    root_abs = os.path.abspath(root)
    target = os.path.abspath(os.path.join(root_abs, *parts))
    if target != root_abs and not target.startswith(root_abs + os.sep):
        raise PluginSyncError(f"plugin path escapes the overlay root: {rel!r}")
    return target


def _link_target(path):
    """Return the resolved target of a symlink, or None when it is not one."""
    if not os.path.islink(path):
        return None
    return os.path.realpath(path)


def _assert_inside(root, path, what):
    """Fail when `path` resolves outside `root` (symlink escape)."""
    root_abs = os.path.abspath(root)
    resolved = os.path.realpath(path)
    if resolved != root_abs and not resolved.startswith(root_abs + os.sep):
        raise PluginSyncError(f"{what} escapes the plugin package directory: {path}")


def copy_tree(src, dst):
    """Copy the `src` directory over `dst`, recursively.

    The destination is replaced as an exact tree: stale files that are not in
    the source are removed. Symlinks are copied as symlinks only when they
    stay inside the source package.
    """
    if not os.path.isdir(src):
        raise PluginSyncError(f"declared plugin has no source directory: {src}")

    parent = os.path.dirname(dst)
    if parent:
        os.makedirs(parent, exist_ok=True)

    if os.path.islink(dst):
        os.unlink(dst)
    elif os.path.isdir(dst):
        shutil.rmtree(dst)
    elif os.path.exists(dst):
        raise PluginSyncError(f"plugin destination is not a directory: {dst}")

    shutil.copytree(src, dst, symlinks=True, dirs_exist_ok=False)


def tree_files(root):
    """Return the sorted relative paths of every regular file under `root`."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            found.append(os.path.relpath(full, root))
    return found


def verify_tree(src, dst):
    """Return the list of missing/mismatching files of `dst` against `src`."""
    problems = []
    if not os.path.isdir(dst):
        return [(os.path.basename(dst.rstrip(os.sep)), "the package directory is missing")]

    for rel in tree_files(src):
        source = os.path.join(src, rel)
        target = os.path.join(dst, rel)
        if os.path.islink(target):
            target_resolved = _link_target(target)
            if target_resolved is None:
                problems.append((rel, "the installed file is a broken symlink"))
                continue
            if not os.path.isfile(target_resolved):
                problems.append((rel, "the installed file is a broken symlink"))
                continue
            if not _same_bytes(source, target_resolved):
                problems.append((rel, "the installed content differs from the source"))
            continue
        if not os.path.isfile(target):
            problems.append((rel, "the file is missing on disk"))
            continue
        if not _same_bytes(source, target):
            problems.append((rel, "the installed content differs from the source"))

    return problems


def _same_bytes(a, b):
    try:
        if os.path.getsize(a) != os.path.getsize(b):
            return False
        with open(a, "rb") as fa, open(b, "rb") as fb:
            while True:
                chunk_a = fa.read(65536)
                chunk_b = fb.read(65536)
                if chunk_a != chunk_b:
                    return False
                if not chunk_a:
                    return True
    except OSError:
        return False


def remove_tree(path):
    """Remove a file or directory tree, returning True when something went."""
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
        return True
    if os.path.isdir(path):
        shutil.rmtree(path)
        return True
    return False


def purge_v1_residuals(target_root):
    """Delete the OpenCode 1 Forge plugin leftovers from the overlay.

    The two V1 `.js` plugins are Forge-owned and are always removed. The V1
    `@opencode-ai/plugin` runtime metadata is only removed when it is
    recognisable as managed (the directory really holds that package and the
    overlay `package.json` declares it), so unrelated user dependencies are
    never touched.
    """
    removed = []

    plugins_dir = safe_join(target_root, V1_RESIDUAL_DIR)
    if os.path.isdir(plugins_dir):
        for name in sorted(os.listdir(plugins_dir)):
            if not name.startswith(V1_RESIDUAL_PREFIX) or not name.endswith(V1_RESIDUAL_SUFFIX):
                continue
            path = os.path.join(plugins_dir, name)
            if os.path.islink(path) or os.path.isfile(path):
                if remove_tree(path):
                    removed.append("%s/%s" % (V1_RESIDUAL_DIR, name))

    # Drop the V1 plugins directory when the removal left it empty.
    if os.path.isdir(plugins_dir) and not os.listdir(plugins_dir):
        os.rmdir(plugins_dir)
        removed.append("%s/" % V1_RESIDUAL_DIR)

    metadata = os.path.join(target_root, "node_modules", *V1_METADATA_PACKAGE.split("/"))
    if os.path.isdir(metadata) and _is_managed_v1_metadata(target_root, metadata):
        remove_tree(metadata)
        removed.append("node_modules/%s" % V1_METADATA_PACKAGE)

    return removed


def _is_managed_v1_metadata(target_root, metadata):
    """True when the V1 plugin runtime metadata is recognisable as managed."""
    package_json = os.path.join(metadata, "package.json")
    try:
        with open(package_json, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return False

    if data.get("name") != V1_METADATA_PACKAGE:
        return False

    # The overlay package.json must declare it as a dependency: that is what
    # makes the directory ours to remove.
    overlay_package = os.path.join(target_root, "package.json")
    try:
        with open(overlay_package, encoding="utf-8") as fh:
            overlay = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return False

    for section in ("dependencies", "devDependencies"):
        deps = overlay.get(section) or {}
        if isinstance(deps, dict) and V1_METADATA_PACKAGE in deps:
            return True

    return False


def prune_empty_parents(base, rel_paths):
    """Remove the container directories of the removed trees when they are empty.

    Forge owns the containers it creates (`plugin-packages/`, `node_modules/`),
    but the user may have dropped something of their own inside them: a
    container is only removed when it is EMPTY, and the walk stops at the
    first ancestor that still holds something. The overlay root itself is
    never touched here — the uninstaller owns that decision.

    Returns the relative paths of the containers that were removed.
    """
    candidates = set()

    for rel in rel_paths:
        rel = rel.rstrip("/")
        parent = os.path.dirname(rel)
        while parent and parent not in (".", "..", "/"):
            candidates.add(parent)
            parent = os.path.dirname(parent)

    removed = []

    # Deepest first: a parent is only considered once its own children are
    # gone, so an ancestor that still holds something is never removed.
    for rel in sorted(candidates, key=lambda item: (item.count(os.sep), item), reverse=True):
        path = safe_join(base, rel)
        if os.path.islink(path) or not os.path.isdir(path):
            continue
        try:
            os.rmdir(path)
        except OSError:
            # Not empty: the user put something there and it is not ours.
            continue
        removed.append(rel + "/")

    return removed


def source_plugin_packages(source_root):
    """Return the relative paths of the plugin packages the source overlay holds.

    These are the Forge-owned packages. The uninstaller uses them to remove
    the copy that lives in the installed overlay even when the installed
    config is already gone (or unreadable): a Forge artefact must never
    survive the uninstall.
    """
    packages = []

    src_plugins = os.path.join(os.path.abspath(source_root), "plugin-packages")
    if not os.path.isdir(src_plugins):
        return packages

    for name in sorted(os.listdir(src_plugins)):
        path = os.path.join(src_plugins, name)
        if os.path.islink(path) or not os.path.isdir(path):
            continue
        packages.append(os.path.join("plugin-packages", name))

    return packages


def prune_stale(source_root, target_root, declared):
    """Remove overlay plugin packages that are no longer declared.

    Only packages that have a counterpart in the overlay source are pruned,
    so unrelated directories placed by the user in the overlay are kept.
    """
    pruned = []
    src_plugins = os.path.join(source_root, "plugin-packages")
    dst_plugins = os.path.join(target_root, "plugin-packages")

    if not os.path.isdir(src_plugins) or not os.path.isdir(dst_plugins):
        return pruned

    declared_paths = set(declared)

    for name in sorted(os.listdir(dst_plugins)):
        rel = os.path.join("plugin-packages", name)
        if rel in declared_paths:
            continue
        src = os.path.join(src_plugins, name)
        dst = os.path.join(dst_plugins, name)
        if os.path.isdir(src) and os.path.exists(dst):
            remove_tree(dst)
            pruned.append(rel)

    return pruned


def cmd_sync(args):
    data = parse_config(args.config)
    entries = plugin_entries(data)
    local, external = local_entries(entries)

    source_root = os.path.abspath(args.source_root)
    target_root = os.path.abspath(args.target_root)

    installed = []
    for rel in local:
        src = safe_join(source_root, rel)
        dst = safe_join(target_root, rel)
        if not os.path.isdir(src):
            raise PluginSyncError(
                f"declared plugin '{rel}' has no source package in the overlay: {src}"
            )
        copy_tree(src, dst)
        installed.append(rel)

    pruned = prune_stale(source_root, target_root, local)

    for rel in pruned:
        print(f"[forge-opencode] removed stale plugin (not declared): {rel}")

    purged = purge_v1_residuals(target_root)
    for rel in purged:
        print(f"[forge-opencode] removed OpenCode 1 leftover: {rel}")

    if installed:
        print(f"[forge-opencode] plugins installed: {', '.join(installed)}")
    else:
        print("[forge-opencode] plugins installed: (none declared)")

    for entry in external:
        print(f"[forge-opencode] plugin '{entry}' is external, not copied by the overlay")

    return 0


def cmd_verify(args):
    data = parse_config(args.config)
    entries = plugin_entries(data)
    local, _ = local_entries(entries)

    base = os.path.dirname(os.path.abspath(args.config))
    missing = []

    for rel in local:
        path = safe_join(base, rel)
        source = os.path.join(os.path.dirname(os.path.abspath(args.config)), rel)
        # The installed overlay is verified against the source overlay when
        # it is reachable; otherwise only the presence of the package is
        # checked.
        problems = []
        if not os.path.isdir(path):
            problems = [(rel, "the package directory is missing")]
        else:
            src_dir = os.path.join(os.path.abspath(args.source_root), rel) if args.source_root else None
            if src_dir and os.path.isdir(src_dir):
                problems = [(f"{rel}/{item}", why) for item, why in verify_tree(src_dir, path)]
        for item, why in problems:
            missing.append((item, why))

    if missing:
        for item, why in missing:
            print(
                f"[forge-opencode] ERROR: config declares plugin '{item}' "
                f"but {why}",
                file=sys.stderr,
            )
        return 1

    print(f"[forge-opencode] verified {len(local)} declared plugin(s) on disk")
    return 0


def cmd_remove(args):
    base = os.path.dirname(os.path.abspath(args.config))

    local = []
    if os.path.isfile(args.config):
        try:
            data = parse_config(args.config)
            entries = plugin_entries(data)
            local, _ = local_entries(entries)
        except PluginSyncError as exc:
            print(
                f"[forge-opencode] WARN: cannot derive plugins from {args.config}: {exc}",
                file=sys.stderr,
            )

    # The Forge-owned packages are also derived from the source overlay: the
    # installed config can be gone while the copy of the package is still on
    # disk, and a Forge artefact must never survive the uninstall.
    managed = list(local)
    if args.source_root:
        for rel in source_plugin_packages(args.source_root):
            if rel not in managed:
                managed.append(rel)

    removed = []

    for rel in managed:
        path = safe_join(base, rel)
        if os.path.lexists(path) and remove_tree(path):
            print(f"[forge-opencode] removed plugin: {rel}")
            removed.append(rel)

    for rel in purge_v1_residuals(base):
        print(f"[forge-opencode] removed OpenCode 1 leftover: {rel}")
        removed.append(rel)

    # The containers of the removed trees are Forge-owned, but only while they
    # are empty: whatever the user put inside them survives untouched and the
    # uninstaller reports it instead of deleting it.
    for rel in prune_empty_parents(base, managed + removed):
        print(f"[forge-opencode] removed empty container: {rel}")

    return 0


RUNTIME_MAX_SECONDS = 35.0
RUNTIME_CLEANUP_RESERVE_SECONDS = 5.0
RUNTIME_FUSE_CLEANUP_RESERVE_SECONDS = 2.0
RUNTIME_ATTEMPT_SECONDS = 2.0
RUNTIME_POLL_SECONDS = 0.250
RUNTIME_OWNED_GROUPS = set()
RUNTIME_OWNED_GROUPS_LOCK = threading.Lock()


def _spawn_runtime_process(*popen_args, **popen_kwargs):
    """Atomically track each private session so the hard-deadline fuse can reap it."""
    popen_kwargs["start_new_session"] = True
    with RUNTIME_OWNED_GROUPS_LOCK:
        process = subprocess.Popen(*popen_args, **popen_kwargs)
        RUNTIME_OWNED_GROUPS.add(process.pid)
    return process


def _untrack_empty_runtime_groups(groups):
    with RUNTIME_OWNED_GROUPS_LOCK:
        for pgid in groups:
            if not _process_group_pids(pgid):
                RUNTIME_OWNED_GROUPS.discard(pgid)


def _runtime_deadline_fuse(deadline, cancel, runtime_state, runtime_state_lock):
    # Leave a final slice for killing owned sessions and unlinking the DB copy
    # before enforcing the hard total deadline with os._exit.
    remaining = max(0.0, deadline - RUNTIME_FUSE_CLEANUP_RESERVE_SECONDS - time.monotonic())
    if cancel.wait(remaining):
        return
    with RUNTIME_OWNED_GROUPS_LOCK:
        groups = tuple(RUNTIME_OWNED_GROUPS)
    for pgid in groups:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except (ProcessLookupError, OSError):
            pass
    with runtime_state_lock:
        private_root = runtime_state.get("private_root", "")
    if private_root:
        try:
            shutil.rmtree(private_root)
        except FileNotFoundError:
            pass
        except OSError as exc:
            try:
                os.write(
                    2,
                    ("forge-opencode: deadline fuse could not remove private runtime root: " + str(exc) + "\n").encode(
                        "utf-8", errors="replace"
                    ),
                )
            except OSError:
                pass
    try:
        os.write(2, b"forge-opencode: hard 35-second runtime deadline reached; owned sessions killed\n")
    finally:
        os._exit(124)


def _start_runtime_deadline_fuse(deadline, runtime_state, runtime_state_lock):
    cancel = threading.Event()
    thread = threading.Thread(
        target=_runtime_deadline_fuse,
        args=(deadline, cancel, runtime_state, runtime_state_lock),
        daemon=True,
    )
    thread.start()
    return cancel


def _deadline_check(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= RUNTIME_CLEANUP_RESERVE_SECONDS:
        raise RuntimeDeadline("plugin runtime enumeration exhausted its single 35-second total deadline")
    return remaining - RUNTIME_CLEANUP_RESERVE_SECONDS


def _runtime_database_path(binary, database_override, source_cwd, deadline, owned_processes):
    """Ask the pinned CLI to resolve OPENCODE_DB under the original XDG env."""
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": os.environ.get("HOME", str(Path.home())),
        "OPENCODE_DISABLE_AUTOUPDATE": "1",
        "OPENCODE_DISABLE_MODELS_FETCH": "1",
        "OPENCODE_DISABLE_CHANNEL_DB": "1",
    }
    for name in ("XDG_DATA_HOME",):
        if name in os.environ:
            env[name] = os.environ[name]
    selected = database_override or os.environ.get("OPENCODE_DB")
    if selected:
        env["OPENCODE_DB"] = selected
    process = _spawn_runtime_process(
        [binary, "debug", "paths", "db"],
        cwd=source_cwd,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    owned_processes.append(process)
    try:
        stdout, stderr = process.communicate(timeout=_deadline_check(deadline))
    except subprocess.TimeoutExpired as exc:
        _terminate_process_groups([process], deadline)
        raise RuntimeDeadline("pinned OpenCode DB path resolution exceeded the shared deadline") from exc
    _untrack_empty_runtime_groups([process.pid])
    if process.returncode != 0:
        detail = stderr.decode("utf-8", errors="replace")[-500:]
        raise PluginSyncError(f"pinned OpenCode could not resolve its DB path (RC={process.returncode}): {detail}")
    lines = [line.strip() for line in stdout.decode("utf-8", errors="replace").splitlines() if line.strip()]
    if len(lines) != 1:
        raise PluginSyncError("pinned OpenCode debug paths db returned an ambiguous destination")
    destination = lines[0]
    if destination == ":memory:":
        return destination
    if destination.startswith("file:") or not os.path.isabs(destination):
        raise PluginSyncError(f"unsupported or unresolved OpenCode DB destination: {destination!r}")
    return os.path.realpath(destination)


def _snapshot_database(source_database, private_database, deadline):
    """Create a coherent private SQLite snapshot through a read-only source handle."""
    if source_database == ":memory:":
        return ":memory:"
    source_path = os.path.realpath(source_database)
    private_path = os.path.realpath(private_database)
    if source_path == private_path or _within(source_path, private_path) or _within(private_path, source_path):
        raise PluginSyncError("source and private runtime DB paths are not isolated")
    os.makedirs(os.path.dirname(private_path), mode=0o700, exist_ok=True)
    uri = "file:" + quote(source_path, safe="/") + "?mode=ro"
    source = target = None
    try:
        timeout = max(0.001, _deadline_check(deadline))
        source = sqlite3.connect(uri, uri=True, timeout=timeout)
        source.execute("PRAGMA query_only=ON")
        target = sqlite3.connect(private_path, timeout=timeout)

        def progress(_status, _remaining, _total):
            _deadline_check(deadline)

        source.backup(target, pages=512, progress=progress, sleep=0.01)
        target.commit()
    except RuntimeDeadline:
        raise
    except (OSError, sqlite3.Error, ValueError) as exc:
        raise PluginSyncError(f"cannot prepare private read-only-source SQLite snapshot: {exc}") from exc
    finally:
        if target is not None:
            target.close()
        if source is not None:
            source.close()
    try:
        os.chmod(private_path, 0o600)
    except OSError as exc:
        raise PluginSyncError(f"cannot make private runtime DB mode 0600: {exc}") from exc
    return private_path


def _validate_private_database(database):
    """Accept only an explicitly named DB inside install.sh's private root."""
    if database == ":memory:":
        return database
    try:
        path = Path(database).resolve(strict=True)
        metadata = path.stat()
    except OSError as exc:
        raise PluginSyncError(f"cannot inspect explicitly private runtime DB: {exc}") from exc
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.getuid():
        raise PluginSyncError("explicitly private runtime DB must be a regular file owned by the current user")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise PluginSyncError("explicitly private runtime DB must not be accessible by group or other users")

    private_root_found = False
    for parent in path.parents:
        if not parent.name.startswith("forge-opencode-plugin-diagnostic."):
            continue
        try:
            root_metadata = parent.stat()
        except OSError:
            continue
        if (
            stat.S_ISDIR(root_metadata.st_mode)
            and root_metadata.st_uid == os.getuid()
            and (stat.S_IMODE(root_metadata.st_mode) & 0o077) == 0
        ):
            private_root_found = True
            break
    if not private_root_found:
        raise PluginSyncError("explicitly private runtime DB is outside a verified mode-0700 diagnostic root")
    return str(path)


def _snapshot_database_command(source_database, private_database, deadline):
    if source_database == ":memory:":
        return ":memory:"
    source_path = os.path.realpath(source_database)
    if not os.path.lexists(source_path):
        os.makedirs(os.path.dirname(os.path.abspath(private_database)), mode=0o700, exist_ok=True)
        try:
            fd = os.open(private_database, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as exc:
            raise PluginSyncError(f"cannot create empty private runtime DB: {exc}") from exc
        os.close(fd)
        return os.path.realpath(private_database)
    if not os.path.isfile(source_path):
        raise PluginSyncError("source runtime DB exists but is not a regular file")
    return _snapshot_database(source_path, private_database, deadline)


def cmd_snapshot_db(args):
    deadline = time.monotonic() + RUNTIME_MAX_SECONDS
    if args.source != ":memory:" and not os.path.isabs(args.source):
        raise PluginSyncError("snapshot source must be an absolute resolved DB path or :memory:")
    try:
        private_database = _snapshot_database_command(args.source, os.path.abspath(args.destination), deadline)
    except RuntimeDeadline as exc:
        _emit_stderr(str(exc))
        return 124
    print(private_database)
    return 0


def _runtime_temp_parent(source_database, snapshot_database=True):
    """Choose a private-temp filesystem with room for the SQLite snapshot."""
    candidates = [tempfile.gettempdir(), "/var/tmp"]
    required = 0
    if snapshot_database and source_database != ":memory:":
        source_path = os.path.realpath(source_database)
        try:
            required = os.path.getsize(source_path)
            for suffix in ("-wal", "-shm"):
                try:
                    required += os.path.getsize(source_path + suffix)
                except FileNotFoundError:
                    pass
        except OSError as exc:
            raise PluginSyncError(f"cannot size source DB before selecting private temporary storage: {exc}") from exc
        required += max(64 * 1024 * 1024, required // 20)

    seen = set()
    for candidate in candidates:
        candidate = os.path.realpath(candidate)
        if candidate in seen:
            continue
        seen.add(candidate)
        if not os.path.isdir(candidate) or not os.access(candidate, os.W_OK | os.X_OK):
            continue
        try:
            free = shutil.disk_usage(candidate).free
        except OSError:
            continue
        if free >= required:
            return candidate
    raise PluginSyncError(
        f"no writable private temporary filesystem has enough free space for the coherent DB snapshot ({required} bytes required)"
    )


def _within(root, path):
    try:
        return os.path.commonpath((os.path.realpath(root), os.path.realpath(path))) == os.path.realpath(root)
    except (OSError, ValueError):
        return False


def _copy_overlay_entry(source, destination, source_root, deadline, ancestors=()):
    """Copy one entry without retaining symlinks or permitting source escapes."""
    _deadline_check(deadline)
    source = Path(source)
    destination = Path(destination)
    try:
        metadata = source.lstat()
    except OSError as exc:
        raise PluginSyncError(f"cannot inspect overlay entry {source}: {exc}") from exc

    if stat.S_ISLNK(metadata.st_mode):
        resolved = source.resolve(strict=True)
        if not _within(source_root, resolved):
            raise PluginSyncError(f"overlay symlink escapes the installed overlay: {source}")
        return _copy_overlay_entry(resolved, destination, source_root, deadline, ancestors)

    if stat.S_ISDIR(metadata.st_mode):
        resolved = source.resolve(strict=True)
        if not _within(source_root, resolved):
            raise PluginSyncError(f"overlay directory escapes the installed overlay: {source}")
        resolved_string = str(resolved)
        if resolved_string in ancestors:
            raise PluginSyncError(f"overlay contains a directory cycle at {source}")
        destination.mkdir(mode=0o700, parents=True, exist_ok=True)
        next_ancestors = ancestors + (resolved_string,)
        try:
            entries = sorted(source.iterdir(), key=lambda entry: entry.name)
        except OSError as exc:
            raise PluginSyncError(f"cannot enumerate overlay directory {source}: {exc}") from exc
        for entry in entries:
            # Never inherit the service configuration or records. OpenCode
            # creates a fresh password/configuration and XDG registration.
            if source == Path(source_root) and (
                entry.name == "service.json"
                or (entry.name.startswith("service-") and entry.name.endswith(".json"))
            ):
                continue
            _copy_overlay_entry(entry, destination / entry.name, source_root, deadline, next_ancestors)
        return

    if not stat.S_ISREG(metadata.st_mode):
        raise PluginSyncError(f"unsupported non-regular overlay entry: {source}")

    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        with source.open("rb") as src, destination.open("xb") as dst:
            while True:
                _deadline_check(deadline)
                chunk = src.read(1024 * 1024)
                if not chunk:
                    break
                dst.write(chunk)
        source_mode = stat.S_IMODE(source.stat().st_mode) & 0o777
        destination.chmod(source_mode & 0o755 | 0o600)
    except RuntimeDeadline:
        raise
    except OSError as exc:
        raise PluginSyncError(f"cannot materialize overlay file {source}: {exc}") from exc


def _rewrite_isolated_paths(value, source_root, destination_root):
    """Rebase absolute paths inside the overlay; reject external local paths."""
    if isinstance(value, list):
        return [_rewrite_isolated_paths(item, source_root, destination_root) for item in value]
    if isinstance(value, dict):
        return {
            key: _rewrite_isolated_paths(item, source_root, destination_root)
            for key, item in value.items()
        }
    if not isinstance(value, str) or not os.path.isabs(value):
        return value
    source_root = os.path.realpath(source_root)
    candidate = os.path.normpath(value)
    if _within(source_root, candidate):
        relative = os.path.relpath(candidate, source_root)
        return destination_root if relative == "." else os.path.join(destination_root, relative)
    raise PluginSyncError(f"absolute config reference cannot be isolated safely: {value}")


def prepare_runtime_overlay(config_dir, config_file, destination, deadline=None):
    """Materialize the selected installed overlay/config into a private tree.

    Plugin declarations and options are retained. MCP/provider declarations
    are removed so this bounded inventory probe cannot launch integrations or
    authenticate with external providers. Relative paths keep their layout.
    """
    if deadline is None:
        deadline = time.monotonic() + RUNTIME_MAX_SECONDS
    source_root = os.path.realpath(config_dir)
    source_config = os.path.realpath(config_file)
    if not os.path.isdir(source_root):
        raise PluginSyncError(f"installed overlay is not a directory: {config_dir}")
    if os.path.islink(config_file) or not os.path.isfile(config_file):
        raise PluginSyncError(f"selected config is not a regular file: {config_file}")
    if not _within(source_root, source_config):
        raise PluginSyncError("selected config is outside the installed overlay; relative references cannot be isolated")

    data = parse_config(source_config)
    entries = plugin_entries(data)
    local, external = local_entries(entries)
    if external:
        raise PluginSyncError(
            "plugin declarations outside the installed overlay cannot be isolated safely: "
            + ", ".join(external)
        )
    for rel in local:
        package = safe_join(source_root, rel)
        if not os.path.isdir(package):
            raise PluginSyncError(f"declared installed plugin package is missing: {rel}")
        _assert_inside(source_root, package, "declared plugin")

    destination = os.path.abspath(destination)
    if os.path.lexists(destination):
        raise PluginSyncError(f"private overlay destination already exists: {destination}")
    os.makedirs(os.path.dirname(destination), mode=0o700, exist_ok=True)
    _copy_overlay_entry(Path(source_root), Path(destination), source_root, deadline)

    relative_config = os.path.relpath(source_config, source_root)
    private_config = os.path.join(destination, relative_config)
    copied_data = parse_config(private_config)
    copied_data = _rewrite_isolated_paths(copied_data, source_root, destination)
    copied_data.pop("mcp", None)
    copied_data.pop("providers", None)
    copied_data.pop("provider", None)
    # Preserve the OpenCode 2 plugin field and each string/object (including
    # options) exactly as parsed; no package metadata is used to enumerate.
    with open(private_config, "w", encoding="utf-8") as fh:
        json.dump(copied_data, fh, ensure_ascii=False, indent=2)
        fh.write("\n")
    os.chmod(private_config, 0o600)

    private_roots = []
    for rel in local:
        private_roots.append(os.path.realpath(safe_join(destination, rel)))
    return {
        "config_dir": destination,
        "config_file": private_config,
        "plugin_roots": private_roots,
        "declared_plugins": entries,
    }


def _read_service_registration(path):
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(value, dict):
        return None
    return value


def _process_group_pids(pgid):
    found = []
    proc = Path("/proc")
    if not proc.is_dir():
        return found
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            raw = (entry / "stat").read_text(encoding="ascii")
            fields = raw[raw.rfind(")") + 2 :].split()
            state = fields[0]
            process_group = int(fields[2])
        except (OSError, ValueError, IndexError):
            continue
        if process_group == pgid and state != "Z":
            found.append(int(entry.name))
    return found


def _reap_group_children(pgid):
    while True:
        try:
            pid, _status = os.waitpid(-pgid, os.WNOHANG)
        except (ChildProcessError, OSError):
            return
        if pid <= 0:
            return


def _enable_child_subreaper():
    # On Linux this lets the supervisor reap descendants if a child exits
    # before its own children. Other platforms still get process-group cleanup.
    if sys.platform.startswith("linux"):
        try:
            import ctypes

            ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)
        except Exception:
            pass


def _terminate_process_groups(processes, deadline):
    """Escalate every owned session together under the caller's one deadline."""
    unique = {process.pid: process for process in processes if process is not None}
    groups = sorted(unique)
    signal_ok = True

    # All children here were launched with start_new_session=True, so their
    # process groups are private to this supervisor. Signal every group before
    # waiting for any one of them; no per-group grace windows accumulate.
    for pgid in groups:
        if not _process_group_pids(pgid):
            continue
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError:
            signal_ok = False

    term_end = min(deadline, time.monotonic() + 0.5)
    while time.monotonic() < term_end:
        for pgid in groups:
            _reap_group_children(pgid)
        if not any(_process_group_pids(pgid) for pgid in groups):
            break
        time.sleep(min(0.05, max(0.0, term_end - time.monotonic())))

    survivors = [pgid for pgid in groups if _process_group_pids(pgid)]
    for pgid in survivors:
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError:
            signal_ok = False

    while time.monotonic() < deadline:
        for pgid in groups:
            _reap_group_children(pgid)
        for process in unique.values():
            try:
                process.poll()
            except Exception:
                pass
        if not any(_process_group_pids(pgid) for pgid in groups):
            break
        time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))

    for pgid in groups:
        _reap_group_children(pgid)
    for process in unique.values():
        try:
            process.wait(timeout=0)
        except (subprocess.TimeoutExpired, ChildProcessError):
            pass
    _untrack_empty_runtime_groups(groups)
    return signal_ok and not any(_process_group_pids(pgid) for pgid in groups)


def _remove_tree_with_deadline(path, deadline):
    """Run recursive deletion in an owned session so it cannot overrun cleanup."""
    if not path or not os.path.lexists(path):
        return True
    if time.monotonic() >= deadline:
        return False
    cleaner = _spawn_runtime_process(
        [sys.executable, "-c", "import shutil,sys; shutil.rmtree(sys.argv[1])", path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        cleaner.wait(timeout=max(0.0, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        _terminate_process_groups([cleaner], deadline)
        return False
    _untrack_empty_runtime_groups([cleaner.pid])
    return cleaner.returncode == 0 and not os.path.lexists(path)


def _listener_owned_by(pid, port):
    """Verify that the registered process owns a loopback TCP listener."""
    try:
        fd_targets = set()
        for descriptor in (Path("/proc") / str(pid) / "fd").iterdir():
            try:
                target = os.readlink(descriptor)
            except OSError:
                continue
            match = re.fullmatch(r"socket:\[(\d+)\]", target)
            if match:
                fd_targets.add(match.group(1))
        with open("/proc/net/tcp", encoding="ascii") as fh:
            next(fh, None)
            for line in fh:
                fields = line.split()
                if len(fields) < 10 or fields[3] != "0A":
                    continue
                address_hex, port_hex = fields[1].split(":")
                address = str(ipaddress.IPv4Address(bytes.fromhex(address_hex)[::-1]))
                if address == "127.0.0.1" and int(port_hex, 16) == port and fields[9] in fd_targets:
                    return True
    except (OSError, ValueError, IndexError):
        return False
    return False


def _authenticated_health(registration, timeout=1.0):
    url = registration.get("url")
    password = registration.get("password")
    if not isinstance(url, str) or not isinstance(password, str) or not password:
        return False
    token = base64.b64encode(("opencode:" + password).encode("utf-8")).decode("ascii")
    request = urllib.request.Request(
        url.rstrip("/") + "/api/info",
        headers={"Authorization": "Basic " + token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                return False
            info = json.loads(response.read(1024 * 1024).decode("utf-8"))
    except (OSError, ValueError, urllib.error.URLError):
        return False
    return (
        isinstance(info, dict)
        and info.get("pid") == registration.get("pid")
        and info.get("version") == registration.get("version")
        and url.rstrip("/") in info.get("urls", [])
    )


def _table_state(output, plugin_roots):
    """Return (pending|valid|invalid, reason) for the real CLI output."""
    text = output.decode("utf-8", errors="replace")
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if not lines or lines == ["No plugins found"]:
        return "pending", "empty plugin inventory"
    header_indexes = [index for index, line in enumerate(lines) if line.split() == ["ID", "VERSION", "SOURCE"]]
    if not header_indexes:
        return "invalid", "plugin list returned a non-empty output without the expected table header"
    if len(header_indexes) != 1 or header_indexes[0] != 0:
        return "invalid", "plugin list returned an invalid or repeated table header"
    rows = lines[1:]
    if not rows:
        return "pending", "plugin list table has no rows yet"
    if len(rows) != 1:
        return "invalid", f"plugin list returned {len(rows)} rows; exactly one is required"
    fields = rows[0].split(None, 2)
    if len(fields) != 3:
        return "invalid", "plugin list returned a malformed row"
    plugin_id, version, source = fields
    if plugin_id != "forge-guard":
        return "invalid", f"plugin list returned unexpected plugin ID {plugin_id!r}"
    if version != "local":
        return "invalid", f"forge-guard has unexpected source classification {version!r}"
    source_path = os.path.realpath(source)
    if not any(_within(root, source_path) and os.path.isfile(source_path) for root in plugin_roots):
        return "invalid", "forge-guard source is not a file in a copied package declared by the installed config"
    if not any(os.path.basename(root) == "forge-guard" and _within(root, source_path) for root in plugin_roots):
        return "invalid", "forge-guard source does not resolve inside the copied forge-guard package"
    return "valid", "exactly forge-guard"


def _server_plugin_load_error(log_path):
    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                lowered = line.lower()
                if "plugin" in lowered and (
                    "level=error" in lowered
                    or "failed to load" in lowered
                    or "plugin load failed" in lowered
                    or "error loading" in lowered
                ):
                    return line.strip()
    except OSError:
        pass
    return ""


def _owned_detached_servers(temp_root, binary):
    """Find only detached OpenCode servers carrying this invocation's XDG. """
    found = []
    proc = Path("/proc")
    if not proc.is_dir():
        return found
    expected_executable = os.path.realpath(binary)
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            executable = os.path.realpath(os.readlink(entry / "exe"))
            environment = (entry / "environ").read_bytes().split(b"\0")
            command = (entry / "cmdline").read_bytes().decode("utf-8", errors="replace")
        except OSError:
            continue
        has_private_state = any(
            item == ("XDG_STATE_HOME=" + str(Path(temp_root) / "state")).encode()
            for item in environment
        )
        if executable == expected_executable and has_private_state and "serve" in command:
            found.append(pid)
    return found


def _unregistered_private_servers(temp_root, binary, known_pids):
    """Report matching processes not launched/tracked directly; never adopt them."""
    return [pid for pid in _owned_detached_servers(temp_root, binary) if pid not in known_pids]


def _emit_stderr(message, original=b""):
    sys.stderr.buffer.write(("forge-opencode: " + message + "\n").encode("utf-8", errors="replace"))
    if original:
        sys.stderr.buffer.write(original)
        if not original.endswith(b"\n"):
            sys.stderr.buffer.write(b"\n")
    sys.stderr.buffer.flush()


def cmd_runtime_copy(args):
    destination = os.path.abspath(args.destination)
    result = prepare_runtime_overlay(args.config_dir, args.config, destination)
    print(json.dumps(result, ensure_ascii=False))
    return 0


def cmd_runtime_list(args):
    cli_args = list(args.cli_args)
    if cli_args and cli_args[0] == "--":
        cli_args.pop(0)
    if cli_args[:2] != ["plugin", "list"]:
        _emit_stderr("runtime-list only supervises the OpenCode plugin list command")
        return 1
    if not os.path.isabs(args.binary) or not os.path.isfile(args.binary) or not os.access(args.binary, os.X_OK):
        _emit_stderr("the resolved OpenCode binary is not an executable absolute path")
        return 1

    source_cwd = os.getcwd()
    initial = time.monotonic()
    deadline = initial + RUNTIME_MAX_SECONDS
    temp_root = ""
    runtime_state = {"private_root": ""}
    runtime_state_lock = threading.Lock()
    server = None
    clients = []
    resolver_processes = []
    server_stdout = None
    server_stderr = None
    accepted_output = None
    failure = ""
    failure_stderr = b""
    result_rc = 1
    interrupted_signal = None
    deadline_fuse = None

    def request_interrupt(signum, _frame):
        nonlocal interrupted_signal
        interrupted_signal = signum

    previous_handlers = {}
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, request_interrupt)

    _enable_child_subreaper()
    try:
        try:
            deadline_fuse = _start_runtime_deadline_fuse(deadline, runtime_state, runtime_state_lock)
        except (RuntimeError, OSError) as exc:
            raise PluginSyncError(f"cannot install hard-deadline supervision: {exc}") from exc
        source_database = _runtime_database_path(
            args.binary, args.database, source_cwd, deadline, resolver_processes
        )
        _deadline_check(deadline)
        temp_parent = _runtime_temp_parent(source_database, snapshot_database=not args.database_private)
        with runtime_state_lock:
            temp_root = tempfile.mkdtemp(prefix="forge-opencode-plugin-list-", dir=temp_parent)
            runtime_state["private_root"] = temp_root
            os.chmod(temp_root, 0o700)
        root = Path(temp_root)
        home = root / "home"
        xdg_config = root / "xdg-config"
        xdg_data = root / "data"
        xdg_state = root / "state"
        xdg_cache = root / "cache"
        tmp = root / "tmp"
        for directory in (home, xdg_config, xdg_data, xdg_state, xdg_cache, tmp):
            _deadline_check(deadline)
            directory.mkdir(mode=0o700)
        if args.database_private:
            private_database = _validate_private_database(source_database)
        else:
            private_database = _snapshot_database(
                source_database, xdg_data / "opencode" / "opencode.db", deadline
            )
        private_overlay = root / "overlay"
        copied = prepare_runtime_overlay(args.config_dir, args.config, private_overlay, deadline)
        if interrupted_signal is not None:
            raise RuntimeInterrupted(interrupted_signal)
        matching_roots = [
            path for path in copied["plugin_roots"] if os.path.basename(path) == "forge-guard"
        ]
        if not matching_roots:
            raise PluginSyncError("installed config does not declare a copyable local forge-guard package")

        # Keep only non-secret runtime controls. In particular, do not inherit
        # a shared-server URL/password, service env map, auth tokens, MCP or
        # provider credentials. OPENCODE_DB is either a fresh private snapshot
        # from a read-only source connection or an explicitly validated
        # install.sh snapshot; it is never the original user DB.
        runtime_env = {
            "HOME": str(home),
            "XDG_CONFIG_HOME": str(xdg_config),
            "XDG_DATA_HOME": str(xdg_data),
            "XDG_STATE_HOME": str(xdg_state),
            "XDG_CACHE_HOME": str(xdg_cache),
            "OPENCODE_CONFIG_DIR": copied["config_dir"],
            "OPENCODE_CONFIG": copied["config_file"],
            "OPENCODE_DB": private_database,
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_MODELS_FETCH": "1",
            "OPENCODE_DISABLE_CHANNEL_DB": "1",
            "OPENCODE_DISABLE_FILEWATCHER": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE": "1",
            "OPENCODE_DISABLE_CLAUDE_CODE_SKILLS": "1",
            "OPENCODE_CONFIG_PROJECT_DISABLE": "1",
            "TMPDIR": str(tmp),
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        }

        service_config = Path(copied["config_dir"]) / "service.json"
        with service_config.open("w", encoding="utf-8") as fh:
            json.dump(
                {"disabled": False, "hostname": "127.0.0.1", "remote": False, "env": {}},
                fh,
                indent=2,
            )
            fh.write("\n")
        service_config.chmod(0o600)

        registry_dir = xdg_state / "opencode"
        server_stdout_path = root / "server.stdout"
        server_stderr_path = root / "server.stderr"
        server_stdout = server_stdout_path.open("wb")
        server_stderr = server_stderr_path.open("wb")
        server = _spawn_runtime_process(
            [args.binary, "serve", "--service", "--hostname", "127.0.0.1", "--port", "0", "--print-logs"],
            cwd=source_cwd,
            env=runtime_env,
            stdin=subprocess.DEVNULL,
            stdout=server_stdout,
            stderr=server_stderr,
        )

        registration = None
        while time.monotonic() < deadline - RUNTIME_CLEANUP_RESERVE_SECONDS:
            _deadline_check(deadline)
            if interrupted_signal is not None:
                raise RuntimeInterrupted(interrupted_signal)
            if server.poll() is not None:
                raise PluginSyncError(f"private OpenCode server exited with RC={server.returncode}")
            registry_files = sorted(registry_dir.glob("service*.json")) if registry_dir.is_dir() else []
            if len(registry_files) > 1:
                raise PluginSyncError("private XDG state contains multiple service registrations")
            registration = _read_service_registration(registry_files[0]) if registry_files else None
            if registration is not None:
                if registration.get("pid") != server.pid:
                    raise PluginSyncError("private service registry PID does not match the owned server child")
                if registration.get("version") == "" or not isinstance(registration.get("version"), str):
                    raise PluginSyncError("private service registry has no runtime version")
                url = registration.get("url", "")
                from urllib.parse import urlsplit

                parsed = urlsplit(url)
                if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port:
                    raise PluginSyncError("private service registry is not a loopback ephemeral listener")
                if not _listener_owned_by(server.pid, parsed.port):
                    registration = None
                elif _authenticated_health(registration, timeout=min(1.0, max(0.1, _deadline_check(deadline)))):
                    break
                else:
                    registration = None
            if interrupted_signal is not None:
                raise RuntimeInterrupted(interrupted_signal)
            time.sleep(min(0.05, max(0.0, _deadline_check(deadline))))
        else:
            raise RuntimeDeadline("private service did not register and pass authenticated health before the shared deadline")
        if registration is None:
            raise RuntimeDeadline("private service did not become healthy before the shared deadline")

        while time.monotonic() < deadline - RUNTIME_CLEANUP_RESERVE_SECONDS:
            _deadline_check(deadline)
            if interrupted_signal is not None:
                raise RuntimeInterrupted(interrupted_signal)
            if server.poll() is not None:
                raise PluginSyncError(f"private OpenCode server exited with RC={server.returncode}")
            if not _listener_owned_by(server.pid, urlsplit(registration["url"]).port):
                raise PluginSyncError("private OpenCode service stopped owning its registered listener")
            if not _authenticated_health(registration, timeout=min(1.0, max(0.1, _deadline_check(deadline)))):
                raise PluginSyncError("private OpenCode service stopped responding to authenticated health")
            load_error = _server_plugin_load_error(server_stderr_path)
            if load_error:
                raise PluginSyncError("private runtime reported a plugin load error: " + load_error)

            remaining = _deadline_check(deadline)
            attempt_timeout = min(RUNTIME_ATTEMPT_SECONDS, remaining)
            if attempt_timeout <= 0:
                break
            client_stdout = tempfile.TemporaryFile()
            client_stderr = tempfile.TemporaryFile()
            client = _spawn_runtime_process(
                [args.binary, *cli_args],
                cwd=source_cwd,
                env=runtime_env,
                stdin=subprocess.DEVNULL,
                stdout=client_stdout,
                stderr=client_stderr,
            )
            clients.append((client, client_stdout, client_stderr))
            try:
                client.wait(timeout=attempt_timeout)
                _untrack_empty_runtime_groups([client.pid])
            except subprocess.TimeoutExpired:
                _terminate_process_groups([client], deadline)
                if time.monotonic() >= deadline - RUNTIME_CLEANUP_RESERVE_SECONDS:
                    raise RuntimeDeadline("plugin list exhausted the shared 35-second deadline")
                raise PluginSyncError("runtime plugin list attempt exceeded its 2-second timeout")
            client_stdout.seek(0)
            output = client_stdout.read()
            client_stderr.seek(0)
            client_error = client_stderr.read()
            if client.returncode != 0:
                failure_stderr = client_error
                raise PluginSyncError(f"runtime plugin list exited with RC={client.returncode}")
            state, reason = _table_state(output, copied["plugin_roots"])
            if state == "valid":
                accepted_output = output
                result_rc = 0
                break
            if state == "invalid":
                failure_stderr = client_error
                raise PluginSyncError(reason)
            time.sleep(min(RUNTIME_POLL_SECONDS, max(0.0, _deadline_check(deadline))))
        else:
            raise RuntimeDeadline("exact forge-guard inventory was not ready before the shared deadline")

    except RuntimeInterrupted as exc:
        interrupted_signal = exc.signum
        result_rc = 130 if exc.signum == signal.SIGINT else 143
        failure = "interrupted; cleaning private server and clients"
    except RuntimeDeadline as exc:
        result_rc = 124
        failure = str(exc)
    except (PluginSyncError, OSError, ValueError, subprocess.SubprocessError) as exc:
        result_rc = 1
        failure = str(exc)
    finally:
        # A signal can arrive during a blocking child wait. Preserve its
        # conventional shell status after all owned groups have been cleaned.
        if interrupted_signal is not None:
            result_rc = 130 if interrupted_signal == signal.SIGINT else 143
            if not failure:
                failure = "interrupted; cleaning private server and clients"
        cleanup_ok = True
        owned_processes = resolver_processes + [client for client, _stdout, _stderr in clients]
        if server is not None:
            owned_processes.append(server)
        cleanup_ok = _terminate_process_groups(owned_processes, deadline) and cleanup_ok
        known_pids = {process.pid for process in owned_processes}
        if temp_root:
            try:
                unregistered = _unregistered_private_servers(temp_root, args.binary, known_pids)
            except OSError:
                unregistered = ["<inventario no disponible>"]
            if unregistered:
                cleanup_ok = False
                detail = "private runtime left process(es) without directly demonstrated ownership: " + ",".join(map(str, unregistered))
                failure = f"{failure}; {detail}" if failure else detail
        for _client, stdout_file, stderr_file in clients:
            try:
                stdout_file.close()
                stderr_file.close()
            except OSError:
                cleanup_ok = False
        for stream in (server_stdout, server_stderr):
            if stream is not None:
                try:
                    stream.close()
                except OSError:
                    cleanup_ok = False
        if temp_root:
            try:
                removed = _remove_tree_with_deadline(temp_root, deadline)
            except OSError:
                removed = False
            if not removed:
                cleanup_ok = False
                detail = "cannot remove private runtime directory before the shared 35-second deadline"
                failure = f"{failure}; {detail}" if failure else detail
            else:
                with runtime_state_lock:
                    if runtime_state.get("private_root") == temp_root:
                        runtime_state["private_root"] = ""
        if interrupted_signal is not None:
            result_rc = 130 if interrupted_signal == signal.SIGINT else 143
            if not failure:
                failure = "interrupted; cleaning private server and clients"
        if not cleanup_ok:
            if result_rc not in (124, 130, 143):
                result_rc = 1
            cleanup_detail = "one or more owned processes or private files could not be cleaned"
            if failure:
                failure = f"{failure}; cleanup also failed: {cleanup_detail}"
            else:
                failure = cleanup_detail
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

    if failure:
        _emit_stderr(failure, failure_stderr)
    if result_rc == 0 and accepted_output is not None:
        sys.stdout.buffer.write(accepted_output)
        sys.stdout.buffer.flush()
    if deadline_fuse is not None:
        deadline_fuse.set()
    return result_rc


def main(argv):
    parser = argparse.ArgumentParser(
        prog="plugin-sync.py",
        description="Derive the OpenCode plugin overlay from opencode.jsonc.",
    )
    sub = parser.add_subparsers(dest="mode", required=True)

    sync = sub.add_parser("sync", help="install the declared plugins into the overlay")
    sync.add_argument("--config", required=True, help="source config (JSONC)")
    sync.add_argument("--source-root", required=True, help="overlay source root")
    sync.add_argument("--target-root", required=True, help="installed config directory")
    sync.set_defaults(func=cmd_sync)

    verify = sub.add_parser("verify", help="check declared plugins exist on disk")
    verify.add_argument("--config", required=True, help="installed config (JSONC)")
    verify.add_argument("--source-root", default="", help="overlay source root (optional)")
    verify.set_defaults(func=cmd_verify)

    remove = sub.add_parser("remove", help="remove the declared plugins")
    remove.add_argument("--config", required=True, help="installed config (JSONC)")
    remove.add_argument(
        "--source-root",
        default="",
        help="overlay source root (optional): the Forge-owned packages it holds are removed too",
    )
    remove.set_defaults(func=cmd_remove)

    runtime_copy = sub.add_parser(
        "runtime-copy",
        help="materialize an installed overlay for an isolated runtime inventory probe",
    )
    runtime_copy.add_argument("--config-dir", required=True, help="selected installed overlay directory")
    runtime_copy.add_argument("--config", required=True, help="selected installed OpenCode config")
    runtime_copy.add_argument("--destination", required=True, help="new private overlay destination")
    runtime_copy.set_defaults(func=cmd_runtime_copy)

    snapshot_db = sub.add_parser(
        "snapshot-db",
        help="create a coherent SQLite snapshot through a read-only source handle",
    )
    snapshot_db.add_argument("--source", required=True, help="resolved source DB path or :memory:")
    snapshot_db.add_argument("--destination", required=True, help="private snapshot destination")
    snapshot_db.set_defaults(func=cmd_snapshot_db)

    runtime_list = sub.add_parser(
        "runtime-list",
        help="supervise a private service and poll the real pinned plugin list command",
    )
    runtime_list.add_argument("--binary", required=True, help="resolved absolute OpenCode executable")
    runtime_list.add_argument("--config-dir", required=True, help="effective installed overlay directory")
    runtime_list.add_argument("--config", required=True, help="effective installed OpenCode config")
    runtime_list.add_argument(
        "--database",
        default="",
        help="override OPENCODE_DB; the pinned binary resolves it before private XDG setup",
    )
    runtime_list.add_argument(
        "--database-private",
        action="store_true",
        help="explicitly reuse OPENCODE_DB as an already-private diagnostic snapshot without copying it again",
    )
    runtime_list.add_argument("cli_args", nargs=argparse.REMAINDER, help="original OpenCode CLI arguments")
    runtime_list.set_defaults(func=cmd_runtime_list)

    args = parser.parse_args(argv)

    try:
        return args.func(args)
    except PluginSyncError as exc:
        print(f"[forge-opencode] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
