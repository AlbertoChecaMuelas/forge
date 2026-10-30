#!/usr/bin/env python3
"""Create only synthetic, private inputs for the V2 follow-up verifier.

This deliberately does not clone the installed overlay, runtime, database,
configuration, authentication material, or any user state.  Existing legacy
sandbox data is left untouched; the dedicated Step 4.1 subtree is only
created/reused after checking ownership and that no process owned by this user
is actively using the sandbox path.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path


TEMP_ROOT = Path(os.environ.get("TMPDIR") or "/tmp")
BASE = Path(os.environ.get("FORGE_V2_REMEDIATION_ROOT") or (TEMP_ROOT / "forge-v2-remediation"))
SANDBOX_ROOT = BASE / "sandbox"
SYNTHETIC_ROOT = SANDBOX_ROOT / "step-4.1-synthetic"
EXPECTED_UID = os.getuid()
DIRECTORIES = ("home", "config", "data", "state", "cache")
MARKER_NAME = ".forge-v2-followups-synthetic.json"


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"prepare-sandbox: {message}")


def check_owned_private_directory(path: Path, *, may_create: bool = False) -> None:
    if path.is_symlink():
        fail(f"refusing symlink directory: {path}")
    if not path.exists():
        if not may_create:
            fail(f"required directory is absent: {path}")
        path.mkdir(mode=0o700)
    info = path.stat(follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode):
        fail(f"not a directory: {path}")
    if info.st_uid != EXPECTED_UID:
        fail(f"directory is not owned by uid {EXPECTED_UID}: {path}")
    if stat.S_IMODE(info.st_mode) != 0o700:
        fail(f"directory must be mode 0700; refusing to chmod existing path: {path}")


def check_temp_parent(path: Path) -> None:
    path = path.parent
    if path.is_symlink():
        fail(f"refusing symlink temporary parent: {path}")
    info = path.stat(follow_symlinks=False)
    private_owned = info.st_uid == EXPECTED_UID and stat.S_IMODE(info.st_mode) & 0o077 == 0
    sticky = bool(info.st_mode & stat.S_ISVTX)
    if not stat.S_ISDIR(info.st_mode) or not (private_owned or sticky):
        fail(f"temporary parent must be user-private or sticky: {path}")


def process_references_to_sandbox() -> list[dict[str, object]]:
    """Return current-UID processes whose cwd/exe/argv references BASE."""
    matches: list[dict[str, object]] = []
    needle = os.fsencode(str(BASE))
    proc_root = Path("/proc")
    for entry in proc_root.iterdir():
        if not entry.name.isdecimal():
            continue
        pid = int(entry.name)
        try:
            status_text = (entry / "status").read_text(encoding="ascii", errors="replace")
            uid_line = next(line for line in status_text.splitlines() if line.startswith("Uid:"))
            uid = int(uid_line.split()[1])
            if uid != EXPECTED_UID:
                continue
            argv = (entry / "cmdline").read_bytes()
            exe = os.fsencode(os.readlink(entry / "exe"))
            cwd = os.fsencode(os.readlink(entry / "cwd"))
        except (FileNotFoundError, PermissionError, ProcessLookupError, StopIteration):
            # A process can exit while /proc is sampled.  No identity was
            # acquired and no action is taken against it.
            continue
        if needle in argv or exe.startswith(needle + b"/") or cwd == needle or cwd.startswith(needle + b"/"):
            matches.append({"pid": pid, "exe": os.fsdecode(exe), "cwd": os.fsdecode(cwd)})
    return matches


def ensure_synthetic_file(path: Path, content: bytes, mode: int = 0o600) -> None:
    if path.is_symlink():
        fail(f"refusing symlink file: {path}")
    if path.exists():
        info = path.stat(follow_symlinks=False)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != EXPECTED_UID:
            fail(f"refusing to reuse non-regular or foreign-owned file: {path}")
        if path.read_bytes() != content:
            fail(f"existing synthetic file differs; refusing to overwrite: {path}")
        if stat.S_IMODE(info.st_mode) != mode:
            fail(f"existing synthetic file has unexpected permissions: {path}")
        return
    path.write_bytes(content)
    path.chmod(mode)


def ensure_tree_is_private_and_plain(root: Path) -> None:
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        info = current_path.stat(follow_symlinks=False)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != EXPECTED_UID:
            fail(f"unexpected directory type or owner in synthetic tree: {current_path}")
        if stat.S_IMODE(info.st_mode) != 0o700:
            fail(f"synthetic directory must remain mode 0700: {current_path}")
        for name in directories + files:
            child = current_path / name
            if child.is_symlink():
                fail(f"symlink is forbidden in synthetic tree: {child}")
            child_info = child.stat(follow_symlinks=False)
            if child_info.st_uid != EXPECTED_UID:
                fail(f"foreign-owned path in synthetic tree: {child}")


def main() -> int:
    containment_guard = Path(__file__).with_name("require-v2-containment.sh")
    guarded = subprocess.run(["/bin/bash", str(containment_guard)], check=False)
    if guarded.returncode != 0:
        fail("preparador excluido: no se ejecuta sin la puerta de contencion acreditada")

    if len(sys.argv) != 1:
        fail("usage: prepare-sandbox.py")

    check_temp_parent(BASE)
    for path in (BASE, SANDBOX_ROOT):
        check_owned_private_directory(path)

    active = process_references_to_sandbox()
    if active:
        fail("sandbox is in use by current-UID process(es); no cleanup attempted: " + json.dumps(active))

    if SYNTHETIC_ROOT.exists() or SYNTHETIC_ROOT.is_symlink():
        check_owned_private_directory(SYNTHETIC_ROOT)
        marker_path = SYNTHETIC_ROOT / MARKER_NAME
        if marker_path.is_symlink() or not marker_path.is_file():
            fail(f"existing Step 4.1 tree has no trusted ownership marker: {SYNTHETIC_ROOT}")
        marker = json.loads(marker_path.read_text(encoding="utf-8"))
        if marker.get("batch") != "forge-v2-followups-Step-4.1" or marker.get("uid") != EXPECTED_UID:
            fail(f"existing Step 4.1 tree marker does not match this owner/batch: {marker_path}")
        ensure_tree_is_private_and_plain(SYNTHETIC_ROOT)
    else:
        SYNTHETIC_ROOT.mkdir(mode=0o700)

    for name in DIRECTORIES:
        check_owned_private_directory(SYNTHETIC_ROOT / name, may_create=True)

    synthetic_config = SYNTHETIC_ROOT / "config" / "opencode-forge"
    if not synthetic_config.exists():
        synthetic_config.mkdir(mode=0o700)
    check_owned_private_directory(synthetic_config)

    marker = {
        "batch": "forge-v2-followups-Step-4.1",
        "uid": EXPECTED_UID,
        "sandbox": str(SYNTHETIC_ROOT),
        "directories": list(DIRECTORIES),
        "resources": "synthetic-only",
        "database_created": False,
        "database_copied": False,
        "credentials_copied": False,
        "installed_configuration_copied": False,
        "runtime_launched": False,
        "external_entrypoints_executed": False,
    }
    state = {"schema_version": 1, "targets": [], "targets_manifest": []}
    config = {"$schema": "https://opencode.ai/config.json", "plugin": []}
    files = {
        SYNTHETIC_ROOT / MARKER_NAME: json.dumps(marker, sort_keys=True, indent=2).encode() + b"\n",
        SYNTHETIC_ROOT / "home" / ".forge-state.json": json.dumps(state, sort_keys=True, indent=2).encode() + b"\n",
        synthetic_config / "opencode.jsonc": json.dumps(config, sort_keys=True, indent=2).encode() + b"\n",
    }
    for path, content in files.items():
        ensure_synthetic_file(path, content)

    ensure_tree_is_private_and_plain(SYNTHETIC_ROOT)
    forbidden_names = {
        "auth.json",
        ".opencode-tokens",
        "opencode.db",
        "opencode.db-wal",
        "opencode.db-shm",
        "opencode.db-journal",
    }
    present_forbidden = [str(path) for path in SYNTHETIC_ROOT.rglob("*") if path.name in forbidden_names]
    if present_forbidden:
        fail("synthetic tree contains forbidden credential/database material: " + ", ".join(present_forbidden))

    evidence = {
        "status": "prepared-synthetic-only",
        "base": str(BASE),
        "sandbox": str(SYNTHETIC_ROOT),
        "uid": EXPECTED_UID,
        "owner_checked_before_reuse": True,
        "active_processes_referencing_sandbox": active,
        "active_process_check_passed": not active,
        "private_directories": [str(SYNTHETIC_ROOT / name) for name in DIRECTORIES],
        "synthetic_files": [str(path) for path in files],
        "database_created_or_copied": False,
        "credentials_copied": False,
        "installed_configuration_copied": False,
        "runtime_launched": False,
        "external_entrypoints_executed": False,
        "forbidden_database_or_credential_files": [],
        "legacy_sandbox_preserved_without_cleanup": True,
    }
    print(json.dumps(evidence, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
