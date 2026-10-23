#!/usr/bin/env python3
"""Derive the installed OpenCode plugin overlay from the `plugin` field of
opencode.jsonc.

The set of plugins installed into the overlay is never hardcoded: it is read
from the config declaration itself. That keeps the overlay and the config
from drifting apart — a plugin declared in the config but missing on disk
disables its feature *silently* (OpenCode does not report the failure), so the
installer must never be able to reach that state.

Modes:

  sync    Copy every declared local plugin from the overlay source into the
          directory that holds the installed config, prune the Forge plugins
          that are no longer declared, then verify the result.
  verify  Check that every declared local plugin exists next to the config.
  remove  Delete every declared local plugin (used by the uninstaller).

"Local" means a `./`-relative path inside the overlay (e.g.
`./plugins/forge-guard.js`). Absolute paths and npm package specifiers are
not overlay files: they are managed outside the overlay and are never copied.

Exit codes: 0 = ok, 1 = error (diagnostic on stderr).
"""

import argparse
import json
import os
import shutil
import sys

# Suffixes that mark a plugin entry as a local file rather than a package
# specifier. A local-looking entry that is not `./`-relative is an error: it
# cannot be mapped to an overlay source and would be silently skipped.
LOCAL_FILE_SUFFIXES = (".js", ".mjs", ".cjs")


class PluginSyncError(Exception):
    """Fatal error with a user-facing diagnostic."""


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
    """Return the declared plugin entries as a list of strings."""
    plugins = data.get("plugin", [])
    if isinstance(plugins, str):
        plugins = [plugins]
    if not isinstance(plugins, list):
        raise PluginSyncError("'plugin' must be an array of strings")
    for entry in plugins:
        if not isinstance(entry, str):
            raise PluginSyncError(f"'plugin' entries must be strings, got {entry!r}")
    return plugins


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


def copy_plugin(src, dst):
    """Copy `src` over `dst`, replacing any symlink or stale regular file."""
    parent = os.path.dirname(dst)
    if parent:
        os.makedirs(parent, exist_ok=True)

    if os.path.islink(dst) or os.path.isfile(dst):
        os.unlink(dst)
    elif os.path.exists(dst):
        raise PluginSyncError(f"plugin destination is not a regular file: {dst}")

    shutil.copyfile(src, dst)
    shutil.copymode(src, dst)


def prune_stale(source_root, target_root, declared):
    """Remove overlay plugins that live in the repo but are no longer declared.

    Only files that have a counterpart in the overlay source are pruned, so
    unrelated files placed by the user in the plugins directory are kept.
    """
    pruned = []
    src_plugins = os.path.join(source_root, "plugins")
    dst_plugins = os.path.join(target_root, "plugins")

    if not os.path.isdir(src_plugins) or not os.path.isdir(dst_plugins):
        return pruned

    declared_paths = set(declared)

    for name in sorted(os.listdir(dst_plugins)):
        rel = os.path.join("plugins", name)
        if rel in declared_paths:
            continue
        src = os.path.join(src_plugins, name)
        dst = os.path.join(dst_plugins, name)
        if os.path.isfile(src) and (os.path.isfile(dst) or os.path.islink(dst)):
            os.unlink(dst)
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
        src = os.path.join(source_root, rel)
        dst = os.path.join(target_root, rel)
        if not os.path.isfile(src):
            raise PluginSyncError(
                f"declared plugin '{rel}' has no source file in the overlay: {src}"
            )
        copy_plugin(src, dst)
        installed.append(rel)

    pruned = prune_stale(source_root, target_root, local)

    for rel in pruned:
        print(f"[forge-opencode] removed stale plugin (not declared): {rel}")

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
        path = os.path.join(base, rel)
        if not os.path.isfile(path):
            missing.append((rel, path))

    if missing:
        for rel, path in missing:
            print(
                f"[forge-opencode] ERROR: config declares plugin '{rel}' "
                f"but {path} is missing on disk",
                file=sys.stderr,
            )
        return 1

    print(f"[forge-opencode] verified {len(local)} declared plugin(s) on disk")
    return 0


def cmd_remove(args):
    if not os.path.isfile(args.config):
        return 0

    try:
        data = parse_config(args.config)
        entries = plugin_entries(data)
        local, _ = local_entries(entries)
    except PluginSyncError as exc:
        print(
            f"[forge-opencode] WARN: cannot derive plugins from {args.config}: {exc}",
            file=sys.stderr,
        )
        return 0

    base = os.path.dirname(os.path.abspath(args.config))
    for rel in local:
        path = os.path.join(base, rel)
        if os.path.islink(path) or os.path.isfile(path):
            os.unlink(path)
            print(f"[forge-opencode] removed plugin: {rel}")

    return 0


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
    verify.set_defaults(func=cmd_verify)

    remove = sub.add_parser("remove", help="remove the declared plugins")
    remove.add_argument("--config", required=True, help="installed config (JSONC)")
    remove.set_defaults(func=cmd_remove)

    args = parser.parse_args(argv)

    try:
        return args.func(args)
    except PluginSyncError as exc:
        print(f"[forge-opencode] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
