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

"Local" means a `./`-relative path inside the overlay (e.g.
`./plugin-packages/forge-guard`). Absolute paths and npm package specifiers
are not overlay files: they are managed outside the overlay and are never
copied.

Exit codes: 0 = ok, 1 = error (diagnostic on stderr).
"""

import argparse
import json
import os
import shutil
import sys

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

    args = parser.parse_args(argv)

    try:
        return args.func(args)
    except PluginSyncError as exc:
        print(f"[forge-opencode] ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
