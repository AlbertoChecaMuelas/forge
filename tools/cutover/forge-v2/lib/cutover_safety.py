#!/usr/bin/env python3
"""Shared, import-inert safety primitives for the cutover entrypoints.

Importing this module only defines functions.  Procfs inspection, pidfd use,
filesystem access, and signals happen only when an explicit function or CLI
action is called.
"""

import argparse
import glob
import json
import os
import re
import select
import signal
import sys
import time


_OPENCODE_EXES = {"opencode", "opencode.exe", "opencode2", "opencode-bun"}


def check_pidfd_support():
    """Raise if the host cannot open and signal a pidfd for this process."""
    assert hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")
    fd = os.pidfd_open(os.getpid())
    signal.pidfd_send_signal(fd, 0)
    os.close(fd)


def _process_stat(pid):
    try:
        with open("/proc/%d/stat" % int(pid), "r", encoding="ascii") as stream:
            raw = stream.read()
        fields = raw[raw.rfind(")") + 2 :].split()
        if len(fields) < 20:
            return None
        return {"parent": fields[1], "start": fields[19], "state": fields[0], "pgrp": fields[2]}
    except (OSError, ValueError, IndexError):
        return None


def _proc_start_ticks(pid):
    stat = _process_stat(pid)
    return stat["start"] if stat else None


def _proc_parent_pid(pid):
    try:
        with open("/proc/%d/status" % int(pid), "r", encoding="ascii") as stream:
            for line in stream:
                if line.startswith("PPid:"):
                    return line.split()[1]
    except (OSError, IndexError):
        pass
    return None


def _proc_executable_identity(pid):
    try:
        raw = os.readlink("/proc/%d/exe" % int(pid))
        normalized = raw[:-10] if raw.endswith(" (deleted)") else raw
        metadata = os.stat("/proc/%d/exe" % int(pid))
        return raw, normalized, "%d:%d" % (metadata.st_dev, metadata.st_ino)
    except OSError:
        return None


def register_server_child(pid, parent_pid, forge_bin):
    """Poll and verify the just-launched server child, returning its identity."""
    pid = int(pid)
    parent_pid = int(parent_pid)
    start_ticks = _proc_start_ticks(pid)
    if start_ticks is None:
        return None
    launch_identity = _proc_executable_identity(pid)
    if launch_identity is None:
        return None
    launch_raw, launch_normalized, launch_dev_inode = launch_identity

    expected_exe = os.path.realpath(forge_bin)
    try:
        metadata = os.stat(forge_bin)
    except OSError:
        return None
    expected_dev_inode = "%d:%d" % (metadata.st_dev, metadata.st_ino)
    if not expected_exe or not expected_dev_inode:
        return None

    attempt = 0
    while attempt < 100:
        observed_start = _proc_start_ticks(pid)
        if observed_start is None or observed_start != start_ticks:
            return None
        parent = _proc_parent_pid(pid)
        if parent is None or parent != str(parent_pid):
            return None
        identity = _proc_executable_identity(pid)
        if identity is None:
            return None
        _raw, normalized, dev_inode = identity
        if normalized == expected_exe and dev_inode == expected_dev_inode:
            return {
                "start_ticks": start_ticks,
                "launch_exe_original": launch_raw,
                "launch_exe_normalized": launch_normalized,
                "launch_exe_dev_inode": launch_dev_inode,
                "expected_exe": expected_exe,
                "expected_dev_inode": expected_dev_inode,
                "exe_normalized": normalized,
                "exe_dev_inode": dev_inode,
                "parent": parent,
            }
        attempt += 1
        time.sleep(0.05)
    return None


def pidfd_stop_registered_server(pid, expected_start, expected_exe, expected_dev_inode, expected_parent):
    """Stop one registered process using its verified pidfd and bounded grace."""
    pid = int(pid)
    expected_parent = int(expected_parent)

    def identity_matches():
        try:
            with open("/proc/%d/stat" % pid, "r", encoding="ascii") as stream:
                raw = stream.read()
            fields = raw[raw.rfind(")") + 2 :].split()
            if len(fields) < 20 or fields[1] != str(expected_parent) or fields[19] != expected_start:
                return False
            executable = os.readlink("/proc/%d/exe" % pid)
            if executable.endswith(" (deleted)"):
                executable = executable[:-10]
            metadata = os.stat("/proc/%d/exe" % pid)
            return executable == expected_exe and "%d:%d" % (metadata.st_dev, metadata.st_ino) == expected_dev_inode
        except (OSError, ValueError, IndexError):
            return False

    try:
        pidfd = os.pidfd_open(pid, 0)
    except ProcessLookupError:
        print("registered server already exited")
        return 0
    except (AttributeError, OSError) as exc:
        print("cannot open verified server pidfd: %s" % exc, file=sys.stderr)
        return 2

    try:
        poller = select.poll()
        poller.register(pidfd, select.POLLIN)
        if poller.poll(0):
            print("registered server already exited")
            return 0
        if not identity_matches():
            print("registered server identity changed after pidfd_open; no signal sent", file=sys.stderr)
            return 3
        stop_budget_seconds = 15.0
        stop_deadline = time.monotonic() + stop_budget_seconds
        term_deadline = stop_deadline - stop_budget_seconds * 0.2
        signal.pidfd_send_signal(pidfd, signal.SIGTERM)
        term_remaining = max(0.0, term_deadline - time.monotonic())
        if poller.poll(int(term_remaining * 1000)):
            print("registered server exited after pidfd SIGTERM")
            return 0
        if not identity_matches():
            print("registered server identity changed before escalation; no SIGKILL sent", file=sys.stderr)
            return 4
        if time.monotonic() >= stop_deadline:
            print("registered server stop budget expired before SIGKILL", file=sys.stderr)
            return 5
        signal.pidfd_send_signal(pidfd, signal.SIGKILL)
        kill_remaining = max(0.0, stop_deadline - time.monotonic())
        if poller.poll(int(kill_remaining * 1000)) or poller.poll(0):
            print("registered server exited after pidfd SIGKILL")
            return 0
        print("registered server remained alive after pidfd SIGKILL", file=sys.stderr)
        return 5
    finally:
        os.close(pidfd)


def _canonical_destination(path, cwd):
    if path.endswith(" (deleted)"):
        path = path[: -len(" (deleted)")]
    if not path.startswith("/"):
        path = os.path.join(cwd, path)
    return os.path.realpath(path)


def _db_destination_matches(destination, database, cwd):
    dest_path = _canonical_destination(destination, cwd)
    db_path = _canonical_destination(database, cwd)
    return dest_path in (db_path, db_path + "-wal", db_path + "-shm", db_path + "-journal")


def _is_opencode_exe(executable):
    normalized = executable[:-10] if executable.endswith(" (deleted)") else executable
    return os.path.basename(normalized) in _OPENCODE_EXES


def _is_sandbox_destination(destination, cutover_home, process_home, cwd):
    path = _canonical_destination(destination, cwd)
    if path.startswith(("/tmp/", "/var/tmp/", "/run/user/")):
        return True
    cutover = _canonical_destination(cutover_home, cwd)
    process = _canonical_destination(process_home, cwd)
    return cutover != process and path.startswith(cutover + "/")


def _registered_server_identity_matches(pid, start, exe_normalized, dev_inode, registration):
    if registration.get("valid") != "1":
        return False
    if str(pid) != registration.get("pid") or start != registration.get("start"):
        return False
    if exe_normalized != registration.get("exe") or dev_inode != registration.get("dev_inode"):
        return False
    current_start = _proc_start_ticks(pid)
    if current_start != registration.get("start"):
        return False
    current_parent = _proc_parent_pid(pid)
    if current_parent != registration.get("shell_pid"):
        return False
    identity = _proc_executable_identity(pid)
    return bool(identity and identity[1] == registration.get("exe") and identity[2] == registration.get("dev_inode"))


def scan_cutover_proc_inventory(
    target_db,
    tag,
    sequence,
    scan_dir,
    production_db,
    cutover_home,
    process_home,
    shell_pid,
    cwd,
    registration,
):
    """Classify target DB holders and OpenCode processes; never sends signals."""
    tag = re.sub(r"[^A-Za-z0-9_.-]", "_", tag)
    del tag  # The sanitized tag is part of the caller-created scan directory.
    del sequence  # The sequence is likewise allocated by the shell entrypoint.
    scan_dir = os.fspath(scan_dir)
    errors_path = os.path.join(scan_dir, "inventory-errors.txt")
    holders_path = os.path.join(scan_dir, "db-holders.txt")
    blockers_path = os.path.join(scan_dir, "db-blockers.txt")
    processes_path = os.path.join(scan_dir, "opencode-processes.txt")
    writers_path = os.path.join(scan_dir, "opencode-target-writers.txt")

    errors = []
    holders = []
    blockers = []
    opencode_processes = []
    opencode_writers = []
    complete = True

    def issue(pid, start, reason):
        nonlocal complete
        complete = False
        errors.append("pid=%s inicio_ticks=%s problema=%s" % (pid, start, reason))

    if not os.path.isdir("/proc") or not os.access("/proc", os.R_OK | os.X_OK):
        issue("<proc>", "<no disponible>", "/proc no es legible/recorrible")
    else:
        mountinfo = "/proc/self/mountinfo"
        if not os.access(mountinfo, os.R_OK):
            issue("<proc>", "<no disponible>", "mountinfo de /proc no es legible")
        else:
            try:
                with open(mountinfo, "r", encoding="utf-8", errors="replace") as stream:
                    if re.search(r"(^|[,\s])hidepid=[1-9]", stream.read()):
                        issue("<proc>", "<no disponible>", "montaje hidepid puede ocultar procesos")
            except OSError:
                issue("<proc>", "<no disponible>", "mountinfo de /proc no es legible")

        proc_entries = glob.glob("/proc/[0-9]*")
        if not proc_entries:
            issue("<proc>", "<no disponible>", "no se pudo enumerar /proc")
        else:
            for proc in proc_entries:
                pid = os.path.basename(proc)
                if pid == str(shell_pid):
                    continue
                if not os.path.isdir(proc):
                    issue(pid, "<no disponible>", "proceso desaparecio durante el inventario")
                    continue
                start_before = _proc_start_ticks(pid)
                if start_before is None:
                    issue(pid, "<no disponible>", "inicio del proceso inaccesible o proceso desaparecido")
                    start_before = "<no disponible>"
                try:
                    exe_raw = os.readlink(os.path.join(proc, "exe"))
                except OSError:
                    issue(pid, start_before, "exe inaccesible o proceso desaparecido")
                    exe_raw = "<inaccesible>"
                exe_normalized = exe_raw[:-10] if exe_raw.endswith(" (deleted)") else exe_raw
                exe_deleted = "si" if exe_raw.endswith(" (deleted)") else "no"
                try:
                    metadata = os.stat(os.path.join(proc, "exe"))
                    exe_dev_inode = "%d:%d" % (metadata.st_dev, metadata.st_ino)
                except OSError:
                    issue(pid, start_before, "identidad dispositivo/inodo de exe inaccesible")
                    exe_dev_inode = "<inaccesible>"
                is_opencode = _is_opencode_exe(exe_raw)

                fd_dir = os.path.join(proc, "fd")
                fd_destinations = []
                holder_destinations = []
                holder = False
                production_destination = False
                sandbox_destination = False
                target_writer = False
                if not os.path.isdir(fd_dir) or not os.access(fd_dir, os.R_OK | os.X_OK):
                    issue(pid, start_before, "descriptores fd inaccesibles")
                else:
                    try:
                        fd_entries = glob.glob(os.path.join(fd_dir, "*"))
                    except OSError:
                        fd_entries = []
                    for fd in fd_entries:
                        if not os.path.lexists(fd):
                            continue
                        try:
                            target = os.readlink(fd)
                        except OSError:
                            if os.path.lexists(fd):
                                issue(pid, start_before, "destino de descriptor inaccesible")
                            continue
                        normalized_target = _canonical_destination(target, cwd)
                        if _db_destination_matches(target, target_db, cwd):
                            holder = True
                            target_writer = True
                            holder_destinations.append(target)
                        if _db_destination_matches(target, production_db, cwd):
                            production_destination = True
                        if normalized_target.endswith(("/opencode.db", "/opencode.db-wal", "/opencode.db-shm")) or normalized_target in (
                            "opencode.db", "opencode.db-wal", "opencode.db-shm"
                        ):
                            fd_destinations.append(target)
                            if _is_sandbox_destination(target, cutover_home, process_home, cwd):
                                sandbox_destination = True
                        if _db_destination_matches(target, target_db, cwd) or _db_destination_matches(
                            target, production_db, cwd
                        ):
                            fd_destinations.append(target)
                            if _is_sandbox_destination(target, cutover_home, process_home, cwd):
                                sandbox_destination = True

                if is_opencode:
                    env_db = ""
                    environ_path = os.path.join(proc, "environ")
                    if os.access(environ_path, os.R_OK):
                        try:
                            with open(environ_path, "rb") as stream:
                                env_data = stream.read().decode("utf-8", errors="replace").replace("\x00", "\n")
                            for env_line in env_data.splitlines():
                                if env_line.startswith("OPENCODE_DB="):
                                    env_db = env_line[len("OPENCODE_DB=") :]
                                    break
                        except OSError:
                            issue(pid, start_before, "environ de OpenCode inaccesible")
                    else:
                        issue(pid, start_before, "environ de OpenCode no legible")
                    if env_db:
                        env_path = env_db
                        if not env_path.startswith("/"):
                            try:
                                proc_cwd = os.readlink(os.path.join(proc, "cwd"))
                                env_path = os.path.join(proc_cwd, env_path)
                            except OSError:
                                issue(pid, start_before, "cwd inaccesible al resolver OPENCODE_DB")
                        if _db_destination_matches(env_path, target_db, cwd):
                            target_writer = True
                            holder = True
                            holder_destinations.append("OPENCODE_DB=" + env_db)
                        if _db_destination_matches(env_path, production_db, cwd):
                            production_destination = True
                        if _is_sandbox_destination(env_path, cutover_home, process_home, cwd):
                            sandbox_destination = True
                        fd_destinations.append("OPENCODE_DB=" + env_db)
                        env_parent = env_path.rsplit("/", 1)[0] if "/" in env_path else ""
                        if not env_parent or not os.path.isdir(env_parent) or not os.access(env_parent, os.R_OK | os.X_OK):
                            issue(pid, start_before, "directorio destino de OPENCODE_DB inaccesible")

                    if production_destination:
                        scope = "PRODUCCION"
                    elif sandbox_destination:
                        scope = "SANDBOX"
                    elif fd_destinations:
                        scope = "OTRA_BASE_NO_PRODUCTIVA"
                    else:
                        scope = "SIN_DESTINO_DB_ACCESIBLE"
                    opencode_processes.append(
                        "pid=%s inicio_ticks=%s exe_original=%s exe_normalizado=%s exe_dev_inode=%s exe_deleted=%s OPENCODE_DB=%s destinos_db=%s ambito=%s objetivo_cutover=%s"
                        % (
                            pid,
                            start_before,
                            exe_raw,
                            exe_normalized,
                            exe_dev_inode,
                            exe_deleted,
                            env_db or "<sin definir>",
                            "; ".join(fd_destinations) or "<sin destino accesible>",
                            scope,
                            "si" if target_writer else "no",
                        )
                    )
                    if target_writer:
                        opencode_writers.append(pid)

                if holder:
                    if _db_destination_matches(target_db, production_db, cwd):
                        scope = "PRODUCCION"
                    elif _is_sandbox_destination(target_db, cutover_home, process_home, cwd):
                        scope = "SANDBOX"
                    else:
                        scope = "OBJETIVO_NO_PRODUCTIVO"
                    owner = "ajeno_o_no_atribuible"
                    if _registered_server_identity_matches(pid, start_before, exe_normalized, exe_dev_inode, registration):
                        owner = "servidor_propio_verificado"
                    holders.append(
                        "pid=%s inicio_ticks=%s exe_original=%s exe_normalizado=%s exe_dev_inode=%s destino_original=%s ambito_destino=%s propiedad=%s"
                        % (pid, start_before, exe_raw, exe_normalized, exe_dev_inode, "; ".join(holder_destinations), scope, owner)
                    )
                    if owner != "servidor_propio_verificado":
                        blockers.append(
                            "pid=%s inicio_ticks=%s exe_original=%s destino_original=%s propiedad=%s"
                            % (pid, start_before, exe_raw, "; ".join(holder_destinations), owner)
                        )

                start_after = _proc_start_ticks(pid)
                if start_after is None:
                    issue(pid, start_before, "proceso desaparecio antes de cerrar su registro")
                    continue
                if start_before != start_after:
                    issue(pid, start_before, "PID reutilizado durante el inventario (nuevo inicio=%s)" % start_after)

    for path, lines in (
        (errors_path, errors),
        (holders_path, holders),
        (blockers_path, blockers),
        (processes_path, opencode_processes),
        (writers_path, opencode_writers),
    ):
        with open(path, "w", encoding="utf-8") as stream:
            if lines:
                stream.write("\n".join(lines) + "\n")
    return {
        "complete": complete,
        "errors_file": errors_path,
        "holders_file": holders_path,
        "blockers_file": blockers_path,
        "opencode_processes_file": processes_path,
        "opencode_writers_file": writers_path,
        "holder_count": len(holders),
        "blocker_count": len(blockers),
    }


def check_rollback_db_holders(database, phase, own_pid, cwd=None):
    """Inventory rollback DB/WAL/SHM holders and OpenCode DB overrides only."""
    cwd = os.getcwd() if cwd is None else cwd
    complete = True
    found_holder = False
    issue_messages = []
    holder_messages = []
    log_messages = []

    def issue(pid, start, reason):
        nonlocal complete
        complete = False
        message = "INVENTARIO NO EXHAUSTIVO: pid=%s inicio_ticks=%s motivo=%s" % (pid, start, reason)
        issue_messages.append(message)
        log_messages.append(message)

    if not os.path.isdir("/proc") or not os.access("/proc", os.R_OK | os.X_OK):
        issue("<proc>", "<no disponible>", "/proc no es legible/recorrible")
    elif not os.access("/proc/self/mountinfo", os.R_OK):
        issue("<proc>", "<no disponible>", "mountinfo de /proc no es legible")
    else:
        try:
            with open("/proc/self/mountinfo", "r", encoding="utf-8", errors="replace") as stream:
                if re.search(r"(^|[,\s])hidepid=[1-9]", stream.read()):
                    issue("<proc>", "<no disponible>", "montaje hidepid puede ocultar procesos")
        except OSError:
            issue("<proc>", "<no disponible>", "mountinfo de /proc no es legible")
    proc_entries = glob.glob("/proc/[0-9]*")
    if complete and not proc_entries:
        issue("<proc>", "<no disponible>", "no se pudo enumerar /proc")

    for proc in proc_entries:
        pid = os.path.basename(proc)
        if pid == str(own_pid):
            continue
        if not os.path.isdir(proc):
            issue(pid, "<no disponible>", "proceso desaparecio durante el inventario")
            continue
        start_before = _proc_start_ticks(pid)
        if start_before is None:
            issue(pid, "<no disponible>", "inicio inaccesible o proceso desaparecido")
            start_before = "<no disponible>"
        try:
            exe_original = os.readlink(os.path.join(proc, "exe"))
        except OSError:
            issue(pid, start_before, "exe inaccesible o proceso desaparecido")
            exe_original = "<inaccesible>"
        exe = exe_original[:-10] if exe_original.endswith(" (deleted)") else exe_original
        base = os.path.basename(exe)

        fd_dir = os.path.join(proc, "fd")
        if not os.path.isdir(fd_dir) or not os.access(fd_dir, os.R_OK | os.X_OK):
            issue(pid, start_before, "descriptores fd inaccesibles")
        else:
            for fd in glob.glob(os.path.join(fd_dir, "*")):
                if not os.path.lexists(fd):
                    continue
                try:
                    target = os.readlink(fd)
                except OSError:
                    if os.path.lexists(fd):
                        issue(pid, start_before, "destino de descriptor inaccesible")
                    continue
                if _db_destination_matches(target, database, cwd):
                    message = (
                        "ERROR: holder pid=%s inicio_ticks=%s exe_original=%s destino_db_original=%s fase=%s; no se señaliza"
                        % (pid, start_before, exe_original, target, phase)
                    )
                    holder_messages.append(message)
                    log_messages.append(message)
                    found_holder = True

        if base not in _OPENCODE_EXES:
            start_after = _proc_start_ticks(pid)
            if start_after is None:
                issue(pid, start_before, "proceso desaparecio antes de cerrar su registro")
                continue
            if start_before != start_after:
                issue(pid, start_before, "PID reutilizado durante el inventario")
            continue

        environ_path = os.path.join(proc, "environ")
        if not os.access(environ_path, os.R_OK):
            issue(pid, start_before, "environ de OpenCode no legible")
            env_data = None
        else:
            try:
                with open(environ_path, "rb") as stream:
                    env_data = stream.read().decode("utf-8", errors="replace").replace("\x00", "\n")
            except OSError:
                issue(pid, start_before, "environ de OpenCode inaccesible")
                env_data = None
        env_db = ""
        if env_data is not None:
            for env_line in env_data.splitlines():
                if env_line.startswith("OPENCODE_DB="):
                    env_db = env_line[len("OPENCODE_DB=") :]
                    break
        if env_db:
            env_path = env_db
            if not env_path.startswith("/"):
                try:
                    proc_cwd = os.readlink(os.path.join(proc, "cwd"))
                    env_path = os.path.join(proc_cwd, env_path)
                except OSError:
                    issue(pid, start_before, "cwd inaccesible al resolver OPENCODE_DB")
                    env_path = env_db
            if _db_destination_matches(env_path, database, cwd):
                message = (
                    "ERROR: OpenCode holder pid=%s inicio_ticks=%s exe_original=%s OPENCODE_DB_original=%s fase=%s; no se señaliza"
                    % (pid, start_before, exe_original, env_db, phase)
                )
                holder_messages.append(message)
                log_messages.append(message)
                found_holder = True
            env_parent = env_path.rsplit("/", 1)[0] if "/" in env_path else ""
            if not env_parent or not os.path.isdir(env_parent) or not os.access(env_parent, os.R_OK | os.X_OK):
                issue(pid, start_before, "directorio destino de OPENCODE_DB inaccesible")

        start_after = _proc_start_ticks(pid)
        if start_after is None:
            issue(pid, start_before, "proceso desaparecio antes de cerrar su registro")
            continue
        if start_before != start_after:
            issue(pid, start_before, "PID reutilizado durante el inventario")

    return {
        "complete": complete,
        "found_holder": found_holder,
        "issue_messages": issue_messages,
        "holder_messages": holder_messages,
        "log_messages": log_messages,
    }


def _write_json(path, value):
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True)
        stream.write("\n")


def _cli():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("pidfd-support")

    stop = commands.add_parser("pidfd-stop")
    stop.add_argument("pid")
    stop.add_argument("expected_start")
    stop.add_argument("expected_exe")
    stop.add_argument("expected_dev_inode")
    stop.add_argument("expected_parent")

    register = commands.add_parser("register-server")
    register.add_argument("pid")
    register.add_argument("parent_pid")
    register.add_argument("forge_bin")
    register.add_argument("state_file")

    scan = commands.add_parser("scan-cutover")
    scan.add_argument("--target-db", required=True)
    scan.add_argument("--tag", required=True)
    scan.add_argument("--sequence", required=True, type=int)
    scan.add_argument("--scan-dir", required=True)
    scan.add_argument("--production-db", required=True)
    scan.add_argument("--cutover-home", required=True)
    scan.add_argument("--process-home", required=True)
    scan.add_argument("--shell-pid", required=True)
    scan.add_argument("--cwd", required=True)
    scan.add_argument("--registration-valid", required=True)
    scan.add_argument("--serve-pid", required=True)
    scan.add_argument("--serve-start", required=True)
    scan.add_argument("--serve-exe", required=True)
    scan.add_argument("--serve-dev-inode", required=True)
    scan.add_argument("--state-file", required=True)

    rollback = commands.add_parser("scan-rollback")
    rollback.add_argument("database")
    rollback.add_argument("phase")
    rollback.add_argument("own_pid")
    rollback.add_argument("state_file")

    args = parser.parse_args()
    if args.command == "pidfd-support":
        check_pidfd_support()
        return 0
    if args.command == "pidfd-stop":
        return pidfd_stop_registered_server(
            args.pid, args.expected_start, args.expected_exe, args.expected_dev_inode, args.expected_parent
        )
    if args.command == "register-server":
        result = register_server_child(args.pid, args.parent_pid, args.forge_bin)
        if result is None:
            return 1
        _write_json(args.state_file, result)
        return 0
    if args.command == "scan-cutover":
        registration = {
            "valid": args.registration_valid,
            "pid": args.serve_pid,
            "start": args.serve_start,
            "exe": args.serve_exe,
            "dev_inode": args.serve_dev_inode,
            "shell_pid": args.shell_pid,
        }
        result = scan_cutover_proc_inventory(
            args.target_db,
            args.tag,
            args.sequence,
            args.scan_dir,
            args.production_db,
            args.cutover_home,
            args.process_home,
            args.shell_pid,
            args.cwd,
            registration,
        )
        _write_json(args.state_file, result)
        return 0
    if args.command == "scan-rollback":
        result = check_rollback_db_holders(args.database, args.phase, args.own_pid)
        _write_json(args.state_file, result)
        return 0
    return 2


if __name__ == "__main__":
    raise SystemExit(_cli())
