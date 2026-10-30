#!/usr/bin/env python3
"""tests/forge_process_observer.py — the OBSERVER of an EFFECTIVE execution.

The observer runs a command and reports, with evidence that does not depend
on what the command PRINTS:

  * the executable that was REALLY invoked (the resolved path of the image
    that the kernel loaded, read from /proc/<pid>/exe at the moment of the
    exec, plus the argv that was executed);
  * every file the invocation OPENED (the paths handed to open/openat/
    openat2), so the absence of a database opening can be OBSERVED instead
    of inferred from the files that survived;
  * every socket and every connect() of the invocation, so the absence of
    network activity can be OBSERVED instead of assumed;
  * the namespaces of the observation itself (network, mount, pid), so the
    limits of the containment can be stated with evidence.

The observation is INCOMPLETE when it could not cover the whole invocation:
the report says so explicitly ("complete": false) and the consumer treats an
incomplete observation as a FAILURE, never as an absence.

The observer NEVER opens, reads or hashes any database: it only reads the
/proc entries of the processes it started itself.

Usage:
    python3 forge_process_observer.py <report.json> <command> [args...]

The exit code of the observed command is propagated (the report is written
before the exit). Nothing is ever written to the standard output: the
standard output of the observed command belongs to the observed command.
"""

import ctypes
import json
import os
import signal
import sys

PTRACE_TRACEME = 0
PTRACE_CONT = 7
PTRACE_SYSCALL = 24
PTRACE_GETREGS = 12
PTRACE_SETOPTIONS = 0x4200
PTRACE_GETEVENTMSG = 0x4201

PTRACE_O_TRACESYSGOOD = 0x00000001
PTRACE_O_TRACEFORK = 0x00000002
PTRACE_O_TRACEVFORK = 0x00000004
PTRACE_O_TRACECLONE = 0x00000008
PTRACE_O_TRACEEXEC = 0x00000010

PTRACE_EVENT_FORK = 1
PTRACE_EVENT_VFORK = 2
PTRACE_EVENT_CLONE = 3
PTRACE_EVENT_EXEC = 4

WALL = 0x40000000

# The number of recorded paths is bounded, but the COUNT of the observed
# events is not: the report says when the list was truncated, because a
# truncated list is an incomplete observation.
MAX_PATHS = 20000


def _machine():
    try:
        return os.uname().machine
    except Exception:  # pragma: no cover - defensive
        return "unknown"


class X86_64Regs(ctypes.Structure):
    _fields_ = [
        ("r15", ctypes.c_ulonglong), ("r14", ctypes.c_ulonglong),
        ("r13", ctypes.c_ulonglong), ("r12", ctypes.c_ulonglong),
        ("rbp", ctypes.c_ulonglong), ("rbx", ctypes.c_ulonglong),
        ("r11", ctypes.c_ulonglong), ("r10", ctypes.c_ulonglong),
        ("r9", ctypes.c_ulonglong), ("r8", ctypes.c_ulonglong),
        ("rax", ctypes.c_ulonglong), ("rcx", ctypes.c_ulonglong),
        ("rdx", ctypes.c_ulonglong), ("rsi", ctypes.c_ulonglong),
        ("rdi", ctypes.c_ulonglong), ("orig_rax", ctypes.c_ulonglong),
        ("rip", ctypes.c_ulonglong), ("cs", ctypes.c_ulonglong),
        ("eflags", ctypes.c_ulonglong), ("rsp", ctypes.c_ulonglong),
        ("ss", ctypes.c_ulonglong), ("fs_base", ctypes.c_ulonglong),
        ("gs_base", ctypes.c_ulonglong), ("ds", ctypes.c_ulonglong),
        ("es", ctypes.c_ulonglong), ("fs", ctypes.c_ulonglong),
        ("gs", ctypes.c_ulonglong),
    ]


class AArch64Regs(ctypes.Structure):
    _fields_ = [
        ("regs", ctypes.c_ulonglong * 31),
        ("sp", ctypes.c_ulonglong),
        ("pc", ctypes.c_ulonglong),
        ("pstate", ctypes.c_ulonglong),
    ]


class Observer:
    def __init__(self):
        self.machine = _machine()
        if self.machine == "x86_64":
            self.nr_execve = 59
            self.nr_open = 2
            self.nr_openat = 257
            self.nr_openat2 = 437
            self.nr_socket = 41
            self.nr_connect = 42
            self.regs_type = X86_64Regs
        elif self.machine == "aarch64":
            self.nr_execve = 221
            self.nr_open = 2
            self.nr_openat = 56
            self.nr_openat2 = 437
            self.nr_socket = 198
            self.nr_connect = 203
            self.regs_type = AArch64Regs
        else:
            raise SystemExit("arquitectura no soportada por el observador: " + self.machine)

        self.errors = []
        self.execs = []
        self.opens = []
        self.sockets = []
        self.connects = []
        self.opened_total = 0
        self.truncated = False
        self.complete = False
        self.exit_code = None
        self.main_pid = None
        self.traced = {}
        self.options_set = set()
        self.exec_recorded = set()
        self.in_syscall = {}
        self.skipped = {}

    # -- ptrace helpers ----------------------------------------------------
    def ptrace(self, request, pid, address=0, data=0, benign_esrch=False):
        result = self.libc.ptrace(
            ctypes.c_uint(request),
            ctypes.c_uint(pid),
            ctypes.c_void_p(address),
            ctypes.c_void_p(data),
        )
        if result == -1:
            errno = ctypes.get_errno()
            # ESRCH on a RESUME means that the tracee is already gone: it is
            # the normal end of a race with its own exit, not a failure of
            # the observation.
            if errno == 3 and benign_esrch:
                return result
            self.errors.append("ptrace(%d, %d) fallo: errno=%d" % (request, pid, errno))
        return result

    def get_regs(self, pid):
        """The registers of the tracee, or None when it is already gone.

        A tracee can die WHILE it is stopped (the threads of a process are
        killed when the group leader calls exit_group): reading its
        registers then fails with ESRCH. That event belongs to a process
        that was dying, so it is counted as SKIPPED and it is not an error
        of the observation.
        """
        regs = self.regs_type()
        result = self.libc.ptrace(
            ctypes.c_uint(PTRACE_GETREGS),
            ctypes.c_uint(pid),
            ctypes.c_void_p(0),
            ctypes.cast(ctypes.byref(regs), ctypes.c_void_p),
        )
        if result == -1:
            errno = ctypes.get_errno()
            if errno == 3:
                self.skipped[pid] = self.skipped.get(pid, 0) + 1
                return None
            self.errors.append("ptrace(%d, %d) fallo: errno=%d" % (PTRACE_GETREGS, pid, errno))
            return None
        return regs

    def syscall_number(self, regs):
        if self.machine == "x86_64":
            return regs.orig_rax
        return regs.regs[8]

    def syscall_args(self, regs):
        if self.machine == "x86_64":
            return [regs.rdi, regs.rsi, regs.rdx]
        return [regs.regs[0], regs.regs[1], regs.regs[2]]

    def read_remote_bytes(self, pid, address, length=1024):
        """The raw bytes of the memory of the tracee.

        A PATH is read as a NUL terminated string, but a SOCKADDR is NOT: it
        is a binary structure whose first bytes can be zero (the high byte
        of the port), so reading it as a string would truncate it and the
        event would be lost.
        """
        if not address:
            return b""
        buffer = ctypes.create_string_buffer(length)
        try:
            count = self.libc.process_vm_readv(
                ctypes.c_int(pid),
                ctypes.byref(self._iovec(ctypes.cast(buffer, ctypes.c_void_p), length)),
                ctypes.c_ulong(1),
                ctypes.byref(self._iovec(ctypes.c_void_p(address), length)),
                ctypes.c_ulong(1),
                ctypes.c_ulong(0),
            )
        except Exception:
            count = -1
        if count <= 0:
            return b""
        return buffer.raw[:count]

    def read_remote(self, pid, address, length=1024):
        data = self.read_remote_bytes(pid, address, length)
        end = data.find(b"\x00")
        if end >= 0:
            data = data[:end]
        try:
            return data.decode("utf-8", "replace")
        except Exception:
            return ""

    @staticmethod
    def _iovec(base, length):
        class _iovec(ctypes.Structure):
            _fields_ = [("iov_base", ctypes.c_void_p), ("iov_len", ctypes.c_size_t)]

        return _iovec(base, length)

    # -- evidence ----------------------------------------------------------
    def record_exec(self, pid):
        try:
            exe = os.readlink("/proc/%d/exe" % pid)
        except OSError:
            exe = "<ilegible>"
        argv = []
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as handle:
                raw = handle.read()
            argv = [part.decode("utf-8", "replace") for part in raw.split(b"\x00") if part]
        except OSError:
            argv = []
        self.execs.append({"pid": pid, "exe": exe, "argv": argv})

    def record_open(self, path):
        self.opened_total += 1
        if len(self.opens) < MAX_PATHS:
            self.opens.append(path)
        else:
            self.truncated = True

    def record_socket(self, pid, family):
        self.sockets.append({"pid": pid, "family": family})

    def record_connect(self, pid, family, address):
        self.connects.append({"pid": pid, "family": family, "address": address})

    @staticmethod
    def family_name(value):
        return {1: "AF_UNIX", 2: "AF_INET", 10: "AF_INET6", 16: "AF_NETLINK"}.get(value, "AF_%d" % value)

    def decode_sockaddr(self, raw):
        if len(raw) < 2:
            return ""
        family = raw[0] | (raw[1] << 8)
        # The port of a sockaddr is in NETWORK byte order (big endian).
        if family == 2 and len(raw) >= 8:
            port = (raw[2] << 8) | raw[3]
            host = ".".join(str(byte) for byte in raw[4:8])
            return "%s:%d" % (host, port)
        if family == 10 and len(raw) >= 24:
            port = (raw[2] << 8) | raw[3]
            host = ":".join(
                "%02x%02x" % (raw[8 + 2 * index], raw[9 + 2 * index]) for index in range(8)
            )
            return "[%s]:%d" % (host, port)
        return ""
    # -- the observation ----------------------------------------------------
    def run(self, command):
        self.libc = ctypes.CDLL("libc.so.6", use_errno=True)

        pid = os.fork()
        if pid == 0:
            try:
                self.libc.ptrace(PTRACE_TRACEME, 0, None, None)
            except Exception:
                pass
            try:
                os.execvp(command[0], command)
            except OSError:
                os._exit(127)
            os._exit(127)

        options = (
            PTRACE_O_TRACESYSGOOD | PTRACE_O_TRACEFORK | PTRACE_O_TRACEVFORK |
            PTRACE_O_TRACECLONE | PTRACE_O_TRACEEXEC
        )
        self.traced[pid] = True
        self.in_syscall[pid] = False
        self.main_pid = pid

        while True:
            try:
                waited, status = os.waitpid(-1, WALL)
            except ChildProcessError:
                break
            if waited == 0:
                break

            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                self.traced.pop(waited, None)
                self.options_set.discard(waited)
                if waited == pid:
                    if os.WIFEXITED(status):
                        self.exit_code = os.WEXITSTATUS(status)
                    else:
                        self.exit_code = -os.WTERMSIG(status)
                if not self.traced:
                    break
                continue

            stop_signal = os.WSTOPSIG(status)
            event = (status >> 16) & 0xFF

            if waited not in self.options_set:
                self.ptrace(PTRACE_SETOPTIONS, waited, 0, options)
                self.options_set.add(waited)

            # The FIRST stop of the MAIN process is the stop of its own exec:
            # the image is already loaded, so the executable it really runs
            # is observable right here. The children are only recorded when
            # they exec (a fork without an exec does not change the image).
            if waited == self.main_pid and waited not in self.exec_recorded:
                self.exec_recorded.add(waited)
                self.record_exec(waited)

            if event == PTRACE_EVENT_EXEC:
                self.record_exec(waited)
                self.ptrace(PTRACE_SYSCALL, waited, 0, 0, benign_esrch=True)
                continue

            if event in (PTRACE_EVENT_FORK, PTRACE_EVENT_VFORK, PTRACE_EVENT_CLONE):
                message = ctypes.c_ulonglong(0)
                self.ptrace(PTRACE_GETEVENTMSG, waited, 0, ctypes.cast(ctypes.byref(message), ctypes.c_void_p).value)
                child = message.value
                if child:
                    self.traced[child] = True
                    self.in_syscall[child] = False
                self.ptrace(PTRACE_CONT, waited, 0, 0, benign_esrch=True)
                continue

            if stop_signal == (signal.SIGTRAP | 0x80):
                if not self.in_syscall.get(waited, False):
                    self.in_syscall[waited] = True
                    self.handle_syscall(waited)
                else:
                    self.in_syscall[waited] = False
                self.ptrace(PTRACE_SYSCALL, waited, 0, 0, benign_esrch=True)
                continue

            # Any other stop (the SIGSTOP of a new child, a signal delivered
            # to the tracee) is resumed without being delivered.
            self.ptrace(PTRACE_SYSCALL, waited, 0, 0, benign_esrch=True)

        self.complete = (
            self.exit_code is not None
            and not self.errors
            and not self.truncated
            # An observation that did not see the image of the MAIN process
            # did not observe the execution at all (for example when the
            # trace was refused): it is INCOMPLETE, never an absence.
            and self.effective_execution() is not None
            # An event of the MAIN process that could not be read is a lost
            # event of the process whose behaviour is being accredited: the
            # observation is INCOMPLETE. The events of the processes that
            # were dying (the threads that exit_group kills) are counted and
            # published, but they do not make the observation incomplete.
            and self.skipped.get(self.main_pid, 0) == 0
        )
        return self.exit_code

    def handle_syscall(self, pid):
        regs = self.get_regs(pid)
        if regs is None:
            # The tracee was already gone: the event belongs to a process
            # that was dying and it is counted as SKIPPED.
            return
        number = self.syscall_number(regs)
        arguments = self.syscall_args(regs)
        if number in (self.nr_openat, self.nr_openat2):
            self.record_open(self.read_remote(pid, arguments[1]))
        elif number == self.nr_open:
            self.record_open(self.read_remote(pid, arguments[0]))
        elif number == self.nr_socket:
            self.record_socket(pid, self.family_name(arguments[0]))
        elif number == self.nr_connect:
            raw = self.read_remote_bytes(pid, arguments[1], 128)
            if len(raw) >= 2:
                family = raw[0] | (raw[1] << 8)
                self.record_connect(pid, self.family_name(family), self.decode_sockaddr(raw))
            else:
                self.record_connect(pid, "UNKNOWN", "")

    # -- the report ---------------------------------------------------------
    def namespace(self, kind):
        try:
            return os.readlink("/proc/self/ns/" + kind)
        except OSError:
            return "UNKNOWN"

    def effective_execution(self):
        """The executable that the MAIN process really ran.

        It is the LAST image the main process loaded: the kernel replaced
        its own image with it, so it is the executable that produced the
        observed behaviour. The path is the RESOLVED one (the kernel
        resolved every link) and the argv is the one that was executed.
        """
        for entry in reversed(self.execs):
            if entry["pid"] == self.main_pid:
                return entry
        return None

    def report(self):
        skipped_main = self.skipped.get(self.main_pid, 0)
        return {
            "observer": {
                "pid": os.getpid(),
                "machine": self.machine,
                "net_namespace": self.namespace("net"),
                "mount_namespace": self.namespace("mnt"),
                "pid_namespace": self.namespace("pid"),
            },
            "main_pid": self.main_pid,
            "effective": self.effective_execution(),
            "exit_code": self.exit_code,
            "complete": self.complete,
            "errors": self.errors,
            "truncated": self.truncated,
            "skipped_events": sum(self.skipped.values()),
            "skipped_main_events": skipped_main,
            "execs": self.execs,
            "opens": self.opens,
            "opened_total": self.opened_total,
            "sockets": self.sockets,
            "connects": self.connects,
        }


def database_paths(paths):
    """The opened paths that look like a DATABASE.

    The pattern is the one of the OpenCode database (opencode.db and its
    WAL companions) plus the usual extensions of a SQLite file.
    """
    found = []
    for path in paths:
        base = os.path.basename(path)
        if base.startswith("opencode.db") or base.endswith((".db", ".sqlite", ".sqlite3")):
            found.append(path)
    return found


def is_loopback(address):
    return address.startswith("127.") or address.startswith("[::1]") or address.startswith("0.0.0.0")


def facts(report, home=""):
    """The facts of an observation, as KEY=VALUE lines for the shell."""
    lines = []
    lines.append("complete=%s" % ("true" if report.get("complete") else "false"))
    lines.append("exit_code=%s" % report.get("exit_code"))
    effective = report.get("effective") or {}
    lines.append("effective_exe=%s" % effective.get("exe", ""))
    argv = effective.get("argv") or []
    lines.append("effective_argv0=%s" % (argv[0] if argv else ""))
    lines.append("net_namespace=%s" % report["observer"]["net_namespace"])
    lines.append("opened_total=%s" % report.get("opened_total"))

    databases = database_paths(report.get("opens") or [])
    lines.append("db_opens=%d" % len(databases))
    for path in databases[:10]:
        lines.append("db_open_path=%s" % path)

    outbound = [
        entry for entry in (report.get("connects") or [])
        if entry.get("family") in ("AF_INET", "AF_INET6") and not is_loopback(entry.get("address", ""))
    ]
    every = [
        entry for entry in (report.get("connects") or [])
        if entry.get("family") in ("AF_INET", "AF_INET6")
    ]
    inet_sockets = [
        entry for entry in (report.get("sockets") or [])
        if entry.get("family") in ("AF_INET", "AF_INET6")
    ]
    lines.append("sockets_inet=%d" % len(inet_sockets))
    lines.append("connects=%d" % len(every))
    lines.append("outbound_connects=%d" % len(outbound))
    for entry in outbound[:10]:
        lines.append("outbound_connect=%s" % entry.get("address", ""))
    for entry in every[:10]:
        lines.append("connect=%s" % entry.get("address", ""))

    outside = []
    if home:
        prefix = os.path.abspath(home).rstrip("/") + "/"
        for path in report.get("opens") or []:
            if path.startswith("/") and not path.startswith(prefix):
                outside.append(path)
    lines.append("opens_outside_home=%d" % len(outside))
    for path in outside[:10]:
        lines.append("open_outside_home=%s" % path)

    errors = report.get("errors") or []
    lines.append("errors=%d" % len(errors))
    for error in errors[:5]:
        lines.append("error=%s" % error)
    lines.append("skipped_events=%s" % report.get("skipped_events", 0))
    lines.append("skipped_main_events=%s" % report.get("skipped_main_events", 0))
    return "\n".join(lines)


def main(argv):
    if len(argv) >= 3 and argv[1] == "--facts":
        report_path = argv[2]
        home = argv[3] if len(argv) > 3 else ""
        try:
            with open(report_path, encoding="utf-8") as handle:
                report = json.load(handle)
        except (OSError, ValueError) as error:
            sys.stderr.write("el informe del observador no se puede leer: %s\n" % error)
            return 70
        sys.stdout.write(facts(report, home) + "\n")
        return 0

    if len(argv) < 3:
        sys.stderr.write("uso: forge_process_observer.py <report.json> <comando> [args...]\n")
        return 2

    report_path = argv[1]
    command = argv[2:]

    observer = Observer()
    try:
        exit_code = observer.run(command)
    except SystemExit:
        raise
    except Exception as error:  # pragma: no cover - defensive
        observer.errors.append("el observador fallo: %r" % (error,))
        exit_code = 127

    try:
        with open(report_path, "w", encoding="utf-8") as handle:
            json.dump(observer.report(), handle, indent=2)
            handle.write("\n")
    except OSError as error:
        sys.stderr.write("el observador no pudo escribir su informe: %s\n" % error)
        return 70

    if exit_code is None:
        return 70
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv))
