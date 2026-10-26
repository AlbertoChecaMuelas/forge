#!/usr/bin/env python3
"""tests/forge_v2_safety_harness.py — harness of the isolated V2 safety acceptance.

Two roles live in this file:

  supervisor
      Runs OUTSIDE any namespace. It establishes and accredits the
      containment (rootless user namespace + private PID namespace + private
      ``/proc``), launches the suite inside it, keeps an EXTERNAL watchdog
      (pidfd on the namespace init) able to tear the whole namespace down,
      verifies afterwards that no process of the batch survived, and writes the
      machine readable evidence.

  suite
      Runs INSIDE the private PID namespace (it is PID 1 there). It
      re-accredits the containment from the inside BEFORE calling any
      sensitive production function, then runs the acceptance cases over
      exclusively synthetic resources.

The harness never executes the external entrypoints and never runs the
external ``dbtool.py``: the only production code it reaches is imported by
path (``open-code/lib/plugin-sync.py`` and the external
``lib/cutover_safety.py``).

Usage:
    python3 tests/forge_v2_safety_harness.py --role supervisor ...
    python3 tests/forge_v2_safety_harness.py --role suite ...
"""

import argparse
import contextlib
import errno
import hashlib
import importlib.util
import inspect
import io
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback

BATCH_ROOT = os.environ.get("FORGE_V2_BATCH_ROOT", "/tmp/opencode/forge-v2-safety")
"""Base of the batch artefacts (synthetic root, default report path).

The default is a DEDICATED root of this test bank. It is deliberately NOT the
evidence directory of any batch: a run must never overwrite the evidence of a
previous batch (that happened when the default pointed at
/tmp/opencode/forge-v2-followups/, whose safety-results.json and
safety-results.md belong to the batch that produced them). A caller that owns
a batch root exports FORGE_V2_BATCH_ROOT; only then the synthetic root and the
default report path move under it.
"""
DEFAULT_EXTERNAL_ROOT = "/home/espinilleitor/forge-v2-cutover-20261024"
PLUGIN_SYNC_REL = "open-code/lib/plugin-sync.py"
CUTOVER_SAFETY_REL = "lib/cutover_safety.py"

KIND_DYNAMIC = "dinamica"
KIND_SIMULATION = "simulacion"
KIND_INSPECTION = "inspeccion"

EXTERNAL_ENTRYPOINT_TOKENS = ("cutover.sh", "ROLLBACK.sh", "dbtool")

# Authorization barrier: the suite refuses to call any sensitive function
# until the supervisor has accredited the containment AND has an operational
# watchdog, and says so on this channel.
AUTH_TOKEN = "AUTH"

# Fault-injection switches, for the exclusive use of this test harness. They
# never touch production code and are inert unless explicitly exported.
FAULT_NO_PIDFD = "FORGE_V2_TEST_NO_PIDFD"
FAULT_HANG_SUITE = "FORGE_V2_TEST_HANG_SUITE"


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fingerprint(path, hash_content=True):
    """Content fingerprint of a file that must not change (hash/size/mtime).

    ``hash_content`` is disabled for the real OpenCode database: its bytes are
    never read, only its metadata is stat'ed.
    """
    try:
        meta = os.stat(path)
    except OSError as exc:
        return {"exists": False, "error": str(exc)}
    result = {
        "exists": True,
        "size": meta.st_size,
        "mtime_ns": meta.st_mtime_ns,
        "ino": meta.st_ino,
        "dev": meta.st_dev,
    }
    if hash_content:
        result["sha256"] = sha256_file(path)
    else:
        result["sha256"] = "no-leido (solo metadatos)"
    return result


def read_proc_children(pid):
    try:
        with open("/proc/%d/task/%d/children" % (pid, pid), "r", encoding="ascii") as stream:
            return [int(item) for item in stream.read().split()]
    except OSError:
        return []


def cmdline_of(pid):
    try:
        with open("/proc/%s/cmdline" % pid, "rb") as stream:
            return stream.read().decode("utf-8", "replace")
    except OSError:
        return ""


def process_present(pid):
    """True while the /proc entry of the process still exists (zombie included)."""
    return os.path.isdir("/proc/%d" % pid)


def pid_alive(pid):
    """True only for a LIVE process: a zombie is dead, only not reaped yet."""
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii") as stream:
            raw = stream.read()
        fields = raw[raw.rfind(")") + 2 :].split()
        return fields[0] != "Z"
    except (OSError, ValueError, IndexError):
        return False


def wait_process_gone(pid, timeout=5.0):
    """Wait (bounded) until the /proc entry of the process disappears."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_present(pid):
            return True
        time.sleep(0.05)
    return not process_present(pid)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def child_env(root, extra=None):
    """Allowlisted environment for every synthetic child."""
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.path.join(root, "home"),
        "TMPDIR": os.path.join(root, "tmp"),
        "LANG": "C",
        "LC_ALL": "C",
        # No Python child of this batch may write bytecode. Some of them
        # import the production modules BY PATH (the fuse driver loads
        # plugin-sync.py), and the import machinery would otherwise drop a
        # __pycache__ next to the source: inside the Git working tree and
        # inside the read-only external tree.
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    if extra:
        env.update(extra)
    return env


class _StderrCapture(object):
    """Captures writes done through ``sys.stderr.buffer``."""

    def __init__(self):
        self.buffer = io.BytesIO()

    @property
    def text(self):
        return self.buffer.getvalue().decode("utf-8", "replace")

    def write(self, _text):
        return None

    def flush(self):
        return None


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
class Report(object):
    def __init__(self):
        self.cases = []
        self.containment = {}
        self.libraries = []
        self.cleanup = {}
        self.notes = []

    def record(self, case_id, kind, ok, detail):
        status = "PASS" if ok else "FAIL"
        self.cases.append(
            {"id": case_id, "kind": kind, "status": status, "detail": detail}
        )
        print("[%s] %s %s :: %s" % (case_id, status, kind, detail), flush=True)
        return ok

    def note(self, text):
        self.notes.append(text)
        print("[nota] %s" % text, flush=True)

    @property
    def failed(self):
        return sum(1 for case in self.cases if case["status"] != "PASS")

    def counts(self):
        counts = {KIND_DYNAMIC: 0, KIND_SIMULATION: 0, KIND_INSPECTION: 0}
        for case in self.cases:
            counts[case["kind"]] = counts.get(case["kind"], 0) + 1
        return counts

    def write(self, path, extra=None):
        payload = {
            "batch": "forge-v2-followups Step 2.2",
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "cases": self.cases,
            "containment": self.containment,
            "libraries": self.libraries,
            "cleanup": self.cleanup,
            "notes": self.notes,
            "summary": {
                "total": len(self.cases),
                "passed": len(self.cases) - self.failed,
                "failed": self.failed,
                "by_kind": self.counts(),
            },
        }
        if extra:
            payload.update(extra)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
        os.replace(tmp, path)


# ---------------------------------------------------------------------------
# containment accreditation (performed from inside the private namespace)
# ---------------------------------------------------------------------------
def accredit_containment(env):
    checks = []
    failures = []

    def check(name, ok, value):
        checks.append({"check": name, "ok": bool(ok), "value": value})
        if not ok:
            failures.append("%s=%s" % (name, value))
        return bool(ok)

    raw = ""
    try:
        with open("/proc/1/stat", "r", encoding="ascii") as stream:
            raw = stream.read()
        # The first field of /proc/<pid>/stat is the pid; the comm field may
        # contain spaces, so it is never split blindly.
        pid1 = raw.split()[0]
    except (OSError, IndexError):
        pid1 = "<ilegible>"
    check("pid_interno_1", pid1 == "1", pid1)

    try:
        ns_pid = os.readlink("/proc/self/ns/pid")
    except OSError:
        ns_pid = "<ilegible>"
    host_ns_pid = env.get("FORGE_V2_HOST_PIDNS", "")
    check("ns_pid_privada", bool(host_ns_pid) and ns_pid != host_ns_pid, ns_pid)

    try:
        ns_user = os.readlink("/proc/self/ns/user")
    except OSError:
        ns_user = "<ilegible>"
    host_ns_user = env.get("FORGE_V2_HOST_USERNS", "")
    check("ns_user_privada", bool(host_ns_user) and ns_user != host_ns_user, ns_user)

    try:
        ns_mnt = os.readlink("/proc/self/ns/mnt")
    except OSError:
        ns_mnt = "<ilegible>"
    host_ns_mnt = env.get("FORGE_V2_HOST_MNTNS", "")
    check("ns_mnt_privada", bool(host_ns_mnt) and ns_mnt != host_ns_mnt, ns_mnt)

    proc_mounted = False
    hidepid = False
    try:
        with open("/proc/self/mountinfo", "r", encoding="utf-8", errors="replace") as stream:
            content = stream.read()
        proc_mounted = " - proc proc " in content
        hidepid = bool(re.search(r"(^|[,\s])hidepid=[1-9]", content))
    except OSError:
        pass
    check("proc_montado_privado", proc_mounted, "si" if proc_mounted else "no")
    check("proc_sin_hidepid", not hidepid, "si" if not hidepid else "si")

    uid = os.getuid()
    check("uid_mapeado_root", uid == 0, uid)

    pidfd_ok = hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")
    check("pidfd_disponible", pidfd_ok, "si" if pidfd_ok else "no")

    summary = "pid_interno=%s ns_pid=%s ns_user=%s ns_mnt=%s uid=%d proc_privado=%s pidfd=%s" % (
        pid1,
        ns_pid,
        ns_user,
        ns_mnt,
        uid,
        "si" if proc_mounted else "no",
        "si" if pidfd_ok else "no",
    )
    return {
        "ok": not failures,
        "reason": ", ".join(failures) if failures else "",
        "checks": checks,
        "summary": summary,
        "pid_interno": pid1,
        "ns_pid": ns_pid,
        "ns_user": ns_user,
        "ns_mnt": ns_mnt,
        "uid_mapeado": uid,
        "host_ns_pid": host_ns_pid,
        "host_ns_user": host_ns_user,
        "host_ns_mnt": host_ns_mnt,
    }


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
FIXTURE_WRITER = '''#!/usr/bin/env python3
"""Synthetic SQLite writer: keeps the WAL open and drives explicit transactions."""
import json
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY, v TEXT)")
conn.commit()
sys.stdout.write("READY\\n")
sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    command = json.loads(line)
    op = command.get("op")
    if op == "insert":
        conn.execute("INSERT INTO t(k, v) VALUES (?, ?)", (command["k"], command["v"]))
    elif op == "commit":
        conn.commit()
    elif op == "rollback":
        conn.rollback()
    elif op == "close":
        conn.commit()
        conn.close()
        break
    sys.stdout.write("OK\\n")
    sys.stdout.flush()
'''

FIXTURE_FD_HOLDER = '''#!/usr/bin/env python3
"""Synthetic holder: keeps one file descriptor open on argv[1]."""
import os
import sys
import time

fd = os.open(sys.argv[1], os.O_RDONLY)
sys.stdout.write("READY\\n")
sys.stdout.flush()
while True:
    time.sleep(3600)
'''

FIXTURE_IGNORE_TERM = '''#!/usr/bin/env python3
"""Synthetic child that survives SIGTERM: the handler records the delivery."""
import signal
import sys
import time

marker = sys.argv[1]


def on_term(signum, frame):
    with open(marker, "a", encoding="utf-8") as handle:
        handle.write("TERM\\n")


signal.signal(signal.SIGTERM, on_term)
sys.stdout.write("READY\\n")
sys.stdout.flush()
while True:
    time.sleep(3600)
'''

FIXTURE_LEADER = '''#!/usr/bin/env python3
"""Synthetic group leader: leaves a descendant behind and exits early."""
import subprocess
import sys
import time

subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3600)"])
sys.stdout.write("READY\\n")
sys.stdout.flush()
time.sleep(0.2)
'''

FIXTURE_FUSE_DRIVER = '''#!/usr/bin/env python3
"""Driver of the REAL deadline fuse: it must end the process with os._exit(124)."""
import importlib.util
import sys
import threading
import time

plugin_sync_path = sys.argv[1]
child_pid = int(sys.argv[2])
private_root = sys.argv[3]

spec = importlib.util.spec_from_file_location("plugin_sync_under_test", plugin_sync_path)
plugin_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin_sync)

with plugin_sync.RUNTIME_OWNED_GROUPS_LOCK:
    plugin_sync.RUNTIME_OWNED_GROUPS.add(child_pid)

runtime_state = {"private_root": private_root}
runtime_state_lock = threading.Lock()
cancel = threading.Event()
plugin_sync._runtime_deadline_fuse(
    time.monotonic(), cancel, runtime_state, runtime_state_lock
)
sys.stderr.write("fuse returned without exiting\\n")
sys.exit(99)
'''


def write_fixtures(root):
    fixtures = os.path.join(root, "fixtures")
    os.makedirs(fixtures, mode=0o700, exist_ok=True)
    written = {}
    for name, body in (
        ("writer.py", FIXTURE_WRITER),
        ("fd_holder.py", FIXTURE_FD_HOLDER),
        ("ignore_term.py", FIXTURE_IGNORE_TERM),
        ("leader.py", FIXTURE_LEADER),
        ("fuse_driver.py", FIXTURE_FUSE_DRIVER),
    ):
        path = os.path.join(fixtures, name)
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(body)
        os.chmod(path, 0o700)
        written[name] = path
    return written


# ---------------------------------------------------------------------------
# suite: the acceptance cases
# ---------------------------------------------------------------------------
class Suite(object):
    def __init__(self, report, root, repo_root, external_root, real_db):
        self.report = report
        self.root = root
        self.repo_root = repo_root
        self.external_root = external_root
        self.db_dir = os.path.join(root, "db")
        self.private_dir = os.path.join(root, "private")
        self.scan_dir = os.path.join(root, "scan")
        self.fixtures_dir = os.path.join(root, "fixtures")
        self.children = []
        self.real_db = real_db
        self.real_db_before = fingerprint(real_db, hash_content=False) if real_db else {"exists": False}
        self.plugin_sync = None
        self.cutover_safety = None

    # -- utilities ---------------------------------------------------------
    def spawn(self, argv, env=None, session=False):
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env if env is not None else child_env(self.root),
            cwd=self.root,
            start_new_session=session,
        )
        self.children.append(proc)
        return proc

    def spawn_ready(self, argv, env=None, session=False):
        proc = self.spawn(argv, env=env, session=session)
        line = proc.stdout.readline().decode("utf-8", "replace").strip()
        if line != "READY":
            err = proc.stderr.read().decode("utf-8", "replace")[-400:]
            raise RuntimeError("fixture did not report READY (%r) stderr=%s" % (line, err))
        return proc

    def spawn_sleeper(self, argv, env=None, session=False):
        """Synthetic child that only sleeps: it never prints READY."""
        proc = self.spawn(argv, env=env, session=session)
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError("el hijo sintetico termino antes de tiempo")
            time.sleep(0.05)
        return proc

    def assert_synthetic(self, path):
        real = os.path.realpath(path)
        root = os.path.realpath(self.root)
        if real != root and not real.startswith(root + os.sep):
            raise AssertionError("ruta no sintetica: %s" % path)
        return real

    def reap_orphans(self):
        """Reap zombies so the /proc inventory of the namespace stays clean."""
        for proc in self.children:
            try:
                proc.poll()
            except Exception:
                pass
        for _ in range(200):
            try:
                pid, _status = os.waitpid(-1, os.WNOHANG)
            except (ChildProcessError, OSError):
                break
            if pid <= 0:
                break

    def cleanup_children(self):
        for proc in self.children:
            try:
                if proc.poll() is None:
                    proc.kill()
            except OSError:
                pass
        for proc in self.children:
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
        for _ in range(200):
            try:
                pid, _status = os.waitpid(-1, os.WNOHANG)
            except (ChildProcessError, OSError):
                break
            if pid <= 0:
                break

    # -- SNAP --------------------------------------------------------------
    def case_snapshot(self):
        """Coherent snapshot over a WAL database with an own writer."""
        plugin_sync = self.plugin_sync
        db = os.path.join(self.db_dir, "opencode.db")
        self.assert_synthetic(db)
        private = {}
        for tag in ("a", "b", "c", "d"):
            private[tag] = os.path.join(self.private_dir, "snapshot-%s.db" % tag)
            self.assert_synthetic(private[tag])

        writer = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "writer.py"), db]
        )

        def command(payload):
            writer.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
            writer.stdin.flush()
            ack = writer.stdout.readline().decode("utf-8", "replace").strip()
            if ack != "OK":
                raise RuntimeError("writer ack inesperado: %r" % ack)

        deadline = time.monotonic() + 60.0

        def snapshot(target):
            self.assert_synthetic(target)
            return plugin_sync._snapshot_database(db, target, deadline)

        def rows_of(path):
            import sqlite3

            conn = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
            try:
                quick = conn.execute("PRAGMA quick_check").fetchone()[0]
                count = conn.execute("SELECT count(*) FROM t").fetchone()[0]
                keys = [row[0] for row in conn.execute("SELECT k FROM t ORDER BY k")]
            finally:
                conn.close()
            return quick, count, keys

        command({"op": "insert", "k": 1, "v": "pendiente"})
        origin_before = fingerprint(db)
        wal_before = fingerprint(db + "-wal")
        shm_before = fingerprint(db + "-shm")
        snapshot_a = snapshot(private["a"])
        # The companions of the DESTINATION are inspected BEFORE any reader
        # opens it: the backup connection closes cleanly, so the destination
        # must not leave a -wal/-shm behind.
        spurious = [s for s in ("-wal", "-shm") if os.path.exists(snapshot_a + s)]
        header = b""
        try:
            with open(snapshot_a, "rb") as stream:
                header = stream.read(20)
        except OSError:
            header = b""
        journal_mode = "WAL" if header[18:20] == b"\x02\x02" else "rollback"
        quick_a, count_a, _keys_a = rows_of(snapshot_a)
        origin_after = fingerprint(db)
        wal_after = fingerprint(db + "-wal")
        shm_after = fingerprint(db + "-shm")

        ok = True
        detail = []
        if quick_a != "ok":
            ok = False
            detail.append("quick_check=%s" % quick_a)
        else:
            detail.append("quick_check=ok")
        if count_a != 0:
            ok = False
            detail.append("filas_no_confirmadas_visibles=%d (esperado 0)" % count_a)
        else:
            detail.append("sin_lectura_sucia=ok")
        if origin_before != origin_after:
            ok = False
            detail.append("origen_modificado=%s" % json.dumps(origin_after, sort_keys=True))
        else:
            detail.append("origen_intacto=ok")
        if not wal_before.get("exists") or not wal_after.get("exists"):
            ok = False
            detail.append("wal_del_origen_ausente")
        elif wal_after["size"] < wal_before["size"]:
            ok = False
            detail.append("wal_del_origen_truncado")
        else:
            detail.append("wal_del_origen_intacto=ok")
        if not shm_before.get("exists") or not shm_after.get("exists"):
            ok = False
            detail.append("shm_del_origen_ausente")
        else:
            detail.append("shm_del_origen_intacto=ok")
        if spurious:
            ok = False
            detail.append("destino_con_companeros_espurios=%s" % spurious)
        else:
            detail.append("destino_sin_wal_shm_tras_el_snapshots=ok")
        import stat as statmod

        dest_mode = statmod.S_IMODE(os.stat(snapshot_a).st_mode)
        if dest_mode != 0o600:
            ok = False
            detail.append("modo_del_destino=%s (esperado 0600)" % oct(dest_mode))
        else:
            detail.append("modo_del_destino=0600")
        detail.append("modo_journal_del_destino=%s" % journal_mode)
        self.report.record("SNAP-1", KIND_DYNAMIC, ok, "; ".join(detail))

        command({"op": "commit"})
        snapshot_b = snapshot(private["b"])
        quick_b, count_b, keys_b = rows_of(snapshot_b)
        ok = quick_b == "ok" and count_b == 1 and keys_b == [1]
        self.report.record(
            "SNAP-2",
            KIND_DYNAMIC,
            ok,
            "quick_check=%s filas=%d claves=%s (esperado ok/1/[1])" % (quick_b, count_b, keys_b),
        )

        command({"op": "insert", "k": 2, "v": "a"})
        command({"op": "insert", "k": 3, "v": "b"})
        snapshot_c = snapshot(private["c"])
        quick_c, count_c, keys_c = rows_of(snapshot_c)
        ok = quick_c == "ok" and count_c == 1 and keys_c == [1]
        self.report.record(
            "SNAP-3",
            KIND_DYNAMIC,
            ok,
            "quick_check=%s filas=%d claves=%s (esperado ok/1/[1]; la transaccion abierta no se ve)"
            % (quick_c, count_c, keys_c),
        )

        command({"op": "commit"})
        snapshot_d = snapshot(private["d"])
        quick_d, count_d, keys_d = rows_of(snapshot_d)
        ok = quick_d == "ok" and count_d == 3 and keys_d == [1, 2, 3]
        self.report.record(
            "SNAP-4",
            KIND_DYNAMIC,
            ok,
            "quick_check=%s filas=%d claves=%s (esperado ok/3/[1,2,3])" % (quick_d, count_d, keys_d),
        )

        import sqlite3

        conn = sqlite3.connect(snapshot_d)
        conn.execute("INSERT INTO t(k, v) VALUES (99, 'copia')")
        conn.commit()
        conn.close()
        quick_src, count_src, _keys_src = rows_of(db)
        origin_final = fingerprint(db)
        ok = count_src == 3 and quick_src == "ok" and origin_final == origin_before
        self.report.record(
            "SNAP-5",
            KIND_DYNAMIC,
            ok,
            "origen_filas=%d quick_check=%s origen_intacto=%s (la escritura del destino no alcanza al origen)"
            % (count_src, quick_src, "si" if origin_final == origin_before else "no"),
        )

        try:
            plugin_sync._snapshot_database(db, db, time.monotonic() + 60.0)
            refused = False
            message = "no refusado"
        except plugin_sync.PluginSyncError as exc:
            refused = True
            message = str(exc)
        self.report.record(
            "SNAP-6",
            KIND_DYNAMIC,
            refused,
            "source==private rechazado=%s mensaje=%s" % ("si" if refused else "no", message),
        )

        # Observation: the destination inherits the journal mode of the source.
        # The companions a later reader recreates keep the 0600 mode of the
        # main file, so there is no permission leak in the private root.
        import stat as statmod

        modes = {}
        for suffix in ("", "-wal", "-shm"):
            path = snapshot_a + suffix
            if os.path.exists(path):
                modes[suffix or "main"] = oct(statmod.S_IMODE(os.stat(path).st_mode))
        self.report.note(
            "destino_snapshot: modo=%s permisos=%s (el destino hereda el modo WAL del origen)"
            % (journal_mode, json.dumps(modes, sort_keys=True))
        )

        # A source in rollback-journal mode must not gain any -wal/-shm.
        plain_db = os.path.join(self.db_dir, "journal.db")
        self.assert_synthetic(plain_db)
        import sqlite3

        conn = sqlite3.connect(plain_db)
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        plain_before = fingerprint(plain_db)
        plain_dest = os.path.join(self.private_dir, "journal-snapshot.db")
        plugin_sync._snapshot_database(plain_db, plain_dest, time.monotonic() + 60.0)
        plain_after = fingerprint(plain_db)
        spurious_plain = [
            suffix
            for suffix in ("-wal", "-shm")
            if os.path.exists(plain_db + suffix)
        ]
        ok = plain_before == plain_after and not spurious_plain
        self.report.record(
            "SNAP-7",
            KIND_DYNAMIC,
            ok,
            "origen_sin_wal_sin_shm: origen_intacto=%s compañeros_espurios=%s"
            % (
                "si" if plain_before == plain_after else "no",
                spurious_plain or "ninguno",
            ),
        )

        # A missing source creates an empty private database (0600).
        import stat as statmod

        missing_source = os.path.join(self.db_dir, "no-existe.db")
        empty_dest = os.path.join(self.private_dir, "vacia.db")
        created = plugin_sync._snapshot_database_command(
            missing_source, empty_dest, time.monotonic() + 60.0
        )
        empty_mode = statmod.S_IMODE(os.stat(created).st_mode) if os.path.exists(created) else None
        ok = (
            os.path.realpath(created) == os.path.realpath(empty_dest)
            and os.path.exists(created)
            and empty_mode == 0o600
        )
        self.report.record(
            "SNAP-8",
            KIND_DYNAMIC,
            ok,
            "origen_inexistente -> destino_creado=%s modo=%s (esperado 0600)"
            % (created, oct(empty_mode) if empty_mode is not None else "-"),
        )

        # The in-memory source is returned untouched.
        memory = plugin_sync._snapshot_database(":memory:", ":memory:", time.monotonic() + 60.0)
        self.report.record(
            "SNAP-9",
            KIND_DYNAMIC,
            memory == ":memory:",
            "fuente_en_memoria=%r (esperado ':memory:')" % memory,
        )

        try:
            writer.stdin.write(b'{"op":"close"}\n')
            writer.stdin.flush()
            writer.wait(timeout=10)
        except Exception:
            pass

    # -- DEAD --------------------------------------------------------------
    def case_deadline(self):
        """Deadline budget and the exit code contract."""
        plugin_sync = self.plugin_sync
        ok = True
        detail = []

        remaining = plugin_sync._deadline_check(time.monotonic() + 30.0)
        if not (24.0 <= remaining <= 25.0):
            ok = False
            detail.append("presupuesto=%s (esperado ~25)" % remaining)
        else:
            detail.append("presupuesto_ok=%.3f" % remaining)

        raised = False
        try:
            plugin_sync._deadline_check(time.monotonic() + 5.0)
        except plugin_sync.RuntimeDeadline:
            raised = True
        if not raised:
            ok = False
            detail.append("limite_no_elevado")
        else:
            detail.append("limite_elevado=RuntimeDeadline")
        self.report.record("DEAD-1", KIND_DYNAMIC, ok, "; ".join(detail))

        db = os.path.join(self.db_dir, "deadline.db")
        self.assert_synthetic(db)
        import sqlite3

        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        raised = False
        detail = []
        try:
            plugin_sync._snapshot_database(
                db, os.path.join(self.private_dir, "deadline-out.db"), time.monotonic()
            )
        except plugin_sync.RuntimeDeadline:
            raised = True
        except plugin_sync.PluginSyncError as exc:
            detail.append("error_inesperado=%s" % exc)
        if not raised:
            ok = False
            detail.append("snapshot_no_respeto_el_presupuesto")
        else:
            detail.append("snapshot_presupuesto=RuntimeDeadline")
        self.report.record("DEAD-2", KIND_DYNAMIC, ok, "; ".join(detail))

        # The CLI maps the expired budget to RC 124. The production budget
        # constant is shortened (the mapping itself is not modified).
        original_budget = plugin_sync.RUNTIME_MAX_SECONDS
        plugin_sync.RUNTIME_MAX_SECONDS = 0.5
        stdout_buffer = io.StringIO()
        stderr_buffer = _StderrCapture()
        try:
            with contextlib.redirect_stdout(stdout_buffer):
                with contextlib.redirect_stderr(stderr_buffer):
                    rc = plugin_sync.cmd_snapshot_db(
                        type(
                            "Args",
                            (),
                            {
                                "source": db,
                                "destination": os.path.join(self.private_dir, "cli-out.db"),
                            },
                        )()
                    )
        finally:
            plugin_sync.RUNTIME_MAX_SECONDS = original_budget
        stderr_text = stderr_buffer.text.strip()
        ok = rc == 124 and "deadline" in stderr_text.lower()
        self.report.record(
            "DEAD-3",
            KIND_DYNAMIC,
            ok,
            "rc=%d (esperado 124) stderr=%r stdout=%r" % (rc, stderr_text[:160], stdout_buffer.getvalue().strip()),
        )

        cli_source = os.path.join(self.db_dir, "cli.db")
        cli_dest = os.path.join(self.private_dir, "cli-real.db")
        conn = sqlite3.connect(cli_source)
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        proc = subprocess.run(
            [
                sys.executable,
                os.path.join(self.repo_root, PLUGIN_SYNC_REL),
                "snapshot-db",
                "--source",
                cli_source,
                "--destination",
                cli_dest,
            ],
            env=child_env(self.root),
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=90,
        )
        ok = (
            proc.returncode == 0
            and proc.stdout.decode().strip() == os.path.realpath(cli_dest)
        )
        self.report.record(
            "DEAD-4",
            KIND_DYNAMIC,
            ok,
            "rc=%d stdout=%r stderr=%r"
            % (
                proc.returncode,
                proc.stdout.decode().strip(),
                proc.stderr.decode().strip()[-120:],
            ),
        )

        proc = subprocess.run(
            [
                sys.executable,
                os.path.join(self.repo_root, PLUGIN_SYNC_REL),
                "snapshot-db",
                "--source",
                "relative.db",
                "--destination",
                cli_dest,
            ],
            env=child_env(self.root),
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=90,
        )
        self.report.record(
            "DEAD-5",
            KIND_DYNAMIC,
            proc.returncode == 1,
            "rc=%d (esperado 1) stderr=%r"
            % (proc.returncode, proc.stderr.decode().strip()[-160:]),
        )

    # -- FUSE --------------------------------------------------------------
    def case_fuse(self):
        """The os._exit of the deadline fuse stays isolated."""
        child = self.spawn_sleeper(
            [sys.executable, "-c", "import time; time.sleep(3600)"], session=True
        )
        private_root = os.path.join(self.root, "fuse-private")
        os.makedirs(private_root, mode=0o700, exist_ok=True)
        with open(os.path.join(private_root, "marker"), "w", encoding="utf-8") as stream:
            stream.write("sintetico\n")

        driver = subprocess.Popen(
            [
                sys.executable,
                os.path.join(self.fixtures_dir, "fuse_driver.py"),
                os.path.join(self.repo_root, PLUGIN_SYNC_REL),
                str(child.pid),
                private_root,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_env(self.root),
            cwd=self.root,
        )
        self.children.append(driver)
        _out, err = driver.communicate(timeout=60)
        rc = driver.returncode
        child.wait(timeout=10)
        child_alive = child.poll() is None
        root_gone = not os.path.exists(private_root)

        # The driver is the process that TRIGGERS the fuse. Once
        # communicate() returns it has already terminated: the fuse ends it
        # with os._exit(124). Its real state is computed here, never assumed.
        driver_alive = driver.poll() is None
        detail = [
            "rc_fusible=%d (esperado 124 por os._exit)" % rc,
            "hijillo_sigue_vivo=%s" % ("si" if child_alive else "no"),
            "raiz_privada_eliminada=%s" % ("si" if root_gone else "no"),
            "proceso_que_dispara_sigue_vivo=%s" % ("si" if driver_alive else "no"),
        ]
        if driver_alive:
            detail.append(
                "el proceso que dispara SIGUE VIVO (inesperado: el fusible deberia haberlo terminado)"
            )
        elif rc == 124:
            detail.append(
                "el proceso que dispara termino por os._exit(124): el os._exit no se propaga al harness"
            )
        else:
            detail.append(
                "el proceso que dispara termino con rc=%d (sin os._exit(124))" % rc
            )
        if rc != 124:
            detail.append("stderr=%r" % err.decode("utf-8", "replace")[-200:])
        self.report.record(
            "DEAD-6", KIND_DYNAMIC, rc == 124 and not child_alive and root_gone, "; ".join(detail)
        )

        # This case exercises the INNER harness process management: after the
        # driver's os._exit, the harness can still create a synthetic child of
        # its own and terminate it. It does NOT observe the EXTERNAL watchdog:
        # that watchdog is a pidfd held by the supervisor, which lives OUTSIDE
        # the private PID namespace, so it is not observable from here (the
        # supervisor PID is not visible in the namespace /proc, and the
        # authorization channel is closed by design right after the barrier is
        # released). The external watchdog is credited by the supervisor
        # itself, in the report evidence: the keys "cleanup.watchdog_operational"
        # and "cleanup.watchdog_detail", plus the "watchdog" entry of
        # "supervisor.steps" (the supervisor section itself carries no watchdog
        # keys; only authorization, role, started_at and steps).
        probe = self.spawn_sleeper(
            [sys.executable, "-c", "import time; time.sleep(3600)"], session=True
        )
        probe.kill()
        probe.wait(timeout=10)
        probe_gone = probe.poll() is not None
        self.report.record(
            "DEAD-7",
            KIND_DYNAMIC,
            probe_gone,
            "gestion de procesos INTERNA del harness tras el os._exit del driver: "
            "crea y termina su propio hijo sintetico (hijo terminado=%s); "
            "NO comprueba el watchdog externo (pidfd del supervisor, fuera del namespace)"
            % probe_gone,
        )

    # -- PIDFD -------------------------------------------------------------
    def case_pidfd(self):
        """pidfd stop of own children, bounded escalation and rejection."""
        safety = self.cutover_safety
        try:
            safety.check_pidfd_support()
            detail = "pidfd=disponible"
            ok = True
        except Exception as exc:
            detail = "pidfd=NO_DISPONIBLE %s" % exc
            ok = False
        self.report.record("PIDFD-1", KIND_DYNAMIC, ok, detail)

        child = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        registration = safety.register_server_child(child.pid, os.getpid(), sys.executable)
        if registration is None:
            self.report.record(
                "PIDFD-2",
                KIND_DYNAMIC,
                False,
                "register_server_child devolvio None (identidad no verificable)",
            )
        else:
            rc = safety.pidfd_stop_registered_server(
                child.pid,
                registration["start_ticks"],
                registration["exe_normalized"],
                registration["exe_dev_inode"],
                registration["parent"],
            )
            child.wait(timeout=10)
            status = child.returncode
            ok = rc == 0 and status == -signal.SIGTERM
            self.report.record(
                "PIDFD-2",
                KIND_DYNAMIC,
                ok,
                "rc=%d (esperado 0) senal_observada=%s (esperado -15) exe=%s inode=%s"
                % (
                    rc,
                    status,
                    registration["exe_normalized"],
                    registration["exe_dev_inode"],
                ),
            )

        marker = os.path.join(self.root, "term-marker")
        child = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), marker]
        )
        registration = safety.register_server_child(child.pid, os.getpid(), sys.executable)
        started = time.monotonic()
        rc = safety.pidfd_stop_registered_server(
            child.pid,
            registration["start_ticks"],
            registration["exe_normalized"],
            registration["exe_dev_inode"],
            registration["parent"],
        )
        elapsed = time.monotonic() - started
        child.wait(timeout=10)
        status = child.returncode
        delivered = os.path.exists(marker)
        ok = rc == 0 and status == -signal.SIGKILL and delivered and 10.0 <= elapsed <= 15.0
        self.report.record(
            "PIDFD-3",
            KIND_DYNAMIC,
            ok,
            "rc=%d senal=%s (esperado -9) term_entregado=%s escalado_en=%.2fs (presupuesto 15s)"
            % (rc, status, delivered, elapsed),
        )

        child = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        rc = safety.pidfd_stop_registered_server(
            child.pid, "999999999", "/bin/false", "0:0", str(os.getpid())
        )
        alive = child.poll() is None
        self.report.record(
            "PIDFD-4",
            KIND_DYNAMIC,
            rc == 3 and alive,
            "identidad_incorrecta rc=%d (esperado 3) proceso_vivo=%s (esperado si: no se senala)"
            % (rc, alive),
        )

        own = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        foreign = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        own_reg = safety.register_server_child(own.pid, os.getpid(), sys.executable)
        rc = safety.pidfd_stop_registered_server(
            foreign.pid,
            own_reg["start_ticks"],
            own_reg["exe_normalized"],
            own_reg["exe_dev_inode"],
            own_reg["parent"],
        )
        foreign_alive = foreign.poll() is None
        own_alive = own.poll() is None
        self.report.record(
            "PIDFD-5",
            KIND_DYNAMIC,
            rc == 3 and foreign_alive and own_alive,
            "ajeno rc=%d vivo=%s (esperado 3/si) y el propio intacto=%s"
            % (rc, foreign_alive, own_alive),
        )

        gone = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        gone.kill()
        gone.wait(timeout=10)
        rc = safety.pidfd_stop_registered_server(gone.pid, "1", "/bin/true", "0:0", str(os.getpid()))
        self.report.record(
            "PIDFD-6",
            KIND_DYNAMIC,
            rc == 0,
            "proceso_ya_salido rc=%d (esperado 0, sin senal)" % rc,
        )

    # -- HOLD --------------------------------------------------------------
    def case_holders(self):
        """Classification of DB/WAL/SHM holders, deleted paths and exe."""
        self.reap_orphans()
        safety = self.cutover_safety
        db = os.path.join(self.db_dir, "holders.db")
        self.assert_synthetic(db)
        import sqlite3

        conn = sqlite3.connect(db)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db + "-wal"])
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db + "-shm"])
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db])
        time.sleep(0.3)

        registration = {
            "valid": "0",
            "pid": "0",
            "start": "0",
            "exe": "/nonexistent",
            "dev_inode": "0:0",
            "shell_pid": str(os.getpid()),
        }

        def scan(tag, sequence, target_db):
            directory = os.path.join(self.scan_dir, tag)
            os.makedirs(directory, mode=0o700, exist_ok=True)
            return safety.scan_cutover_proc_inventory(
                target_db,
                "sintetico",
                sequence,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                registration,
            )

        def read(path):
            with open(path, "r", encoding="utf-8") as stream:
                return stream.read()

        result = scan("main", 1, db)
        holders = read(result["holders_file"])
        blockers = read(result["blockers_file"])
        opencode_processes = read(result["opencode_processes_file"])

        # The holder record is "destino_original=<destinos> ambito_destino=...";
        # several destinations are joined with "; ".
        destinations = set()
        for chunk in re.findall(r"destino_original=(.*?)\s+ambito_destino=", holders):
            for item in chunk.split("; "):
                destinations.add(item.strip())
        has_db = db in destinations
        has_wal = (db + "-wal") in destinations
        has_shm = (db + "-shm") in destinations
        blocker_pids = set(re.findall(r"^pid=(\d+)", blockers, re.MULTILINE))
        ok = (
            result["complete"]
            and result["holder_count"] >= 3
            and has_db
            and has_wal
            and has_shm
            and result["blocker_count"] >= 3
        )
        self.report.record(
            "HOLD-1",
            KIND_DYNAMIC,
            ok,
            "completo=%s holders=%d blockers=%d db=%s wal=%s shm=%s"
            % (
                result["complete"],
                result["holder_count"],
                result["blocker_count"],
                has_db,
                has_wal,
                has_shm,
            ),
        )

        ok = (
            opencode_processes.strip() == ""
            and "propiedad=ajeno_o_no_atribuible" in holders
            and "exe_normalizado=/usr/bin/python" in holders
        )
        self.report.record(
            "HOLD-2",
            KIND_DYNAMIC,
            ok,
            "procesos_opencode=%r | ejecutable_distinto=ajeno_o_no_atribuible:%s"
            % (
                opencode_processes.strip()[:60],
                "propiedad=ajeno_o_no_atribuible" in holders,
            ),
        )

        ghost = os.path.join(self.db_dir, "ghost.db")
        with open(ghost, "wb") as stream:
            stream.write(b"sintetico")
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), ghost])
        time.sleep(0.3)
        os.unlink(ghost)
        time.sleep(0.3)
        ghost_result = scan("deleted", 2, ghost)
        ghost_holders = read(ghost_result["holders_file"])
        ok = ghost_result["holder_count"] >= 1 and "(deleted)" in ghost_holders
        self.report.record(
            "HOLD-3",
            KIND_DYNAMIC,
            ok,
            "holders=%d destino_deleted_presente=%s registro=%r"
            % (ghost_result["holder_count"], "(deleted)" in ghost_holders, ghost_holders.strip()[:160]),
        )

        bin_dir = os.path.join(self.fixtures_dir, "bin")
        os.makedirs(bin_dir, mode=0o700, exist_ok=True)
        gone_bin = os.path.join(bin_dir, "opencode")
        shutil.copy2(os.path.realpath(sys.executable), gone_bin)
        os.chmod(gone_bin, 0o700)
        self.spawn_ready(
            [gone_bin, os.path.join(self.fixtures_dir, "fd_holder.py"), db],
            env=child_env(self.root, {"OPENCODE_DB": db}),
        )
        time.sleep(0.3)
        os.unlink(gone_bin)
        time.sleep(0.3)
        deleted_result = scan("exe-deleted", 3, db)
        deleted_processes = read(deleted_result["opencode_processes_file"])
        ok = (
            "exe_deleted=si" in deleted_processes
            and "exe_original=%s (deleted)" % gone_bin in deleted_processes
            and "objetivo_cutover=si" in deleted_processes
        )
        self.report.record(
            "HOLD-4",
            KIND_DYNAMIC,
            ok,
            "procesos_opencode=%r" % deleted_processes.strip()[:220],
        )

        own_dir = os.path.join(bin_dir, "own")
        os.makedirs(own_dir, mode=0o700, exist_ok=True)
        own_exe = os.path.join(own_dir, "opencode")
        shutil.copy2(os.path.realpath(sys.executable), own_exe)
        os.chmod(own_exe, 0o700)
        own_child = self.spawn_ready(
            [own_exe, os.path.join(self.fixtures_dir, "fd_holder.py"), db],
            env=child_env(self.root, {"OPENCODE_DB": db}),
        )
        time.sleep(0.3)
        own_reg = safety.register_server_child(own_child.pid, os.getpid(), own_exe)
        if own_reg is None:
            self.report.record(
                "HOLD-5",
                KIND_DYNAMIC,
                False,
                "register_server_child devolvio None para el servidor propio",
            )
        else:
            own_registration = {
                "valid": "1",
                "pid": str(own_child.pid),
                "start": own_reg["start_ticks"],
                "exe": own_reg["exe_normalized"],
                "dev_inode": own_reg["exe_dev_inode"],
                "shell_pid": str(os.getpid()),
            }
            directory = os.path.join(self.scan_dir, "own")
            os.makedirs(directory, mode=0o700, exist_ok=True)
            own_result = safety.scan_cutover_proc_inventory(
                db,
                "sintetico",
                4,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                own_registration,
            )
            own_holders = read(own_result["holders_file"])
            own_blockers = read(own_result["blockers_file"])
            own_processes = read(own_result["opencode_processes_file"])
            own_blocker_pids = set(re.findall(r"^pid=(\d+)", own_blockers, re.MULTILINE))
            ok = (
                "propiedad=servidor_propio_verificado" in own_holders
                and str(own_child.pid) not in own_blocker_pids
                and "objetivo_cutover=si" in own_processes
            )
            self.report.record(
                "HOLD-5",
                KIND_DYNAMIC,
                ok,
                "servidor_propio_verificado=%s bloqueantes=%d (servidor_propio_en_bloqueantes=%s) objetivo_cutover_si=%s ambito_sandbox=%s"
                % (
                    "propiedad=servidor_propio_verificado" in own_holders,
                    own_result["blocker_count"],
                    str(own_child.pid) in own_blocker_pids,
                    "objetivo_cutover=si" in own_processes,
                    "SANDBOX" in own_processes,
                ),
            )

        rollback = safety.check_rollback_db_holders(db, "fase-sintetica", str(os.getpid()))
        ok = (
            rollback["complete"]
            and rollback["found_holder"]
            and any("no se señaliza" in item for item in rollback["holder_messages"])
        )
        self.report.record(
            "HOLD-6",
            KIND_DYNAMIC,
            ok,
            "completo=%s holders=%s mensajes=%r"
            % (
                rollback["complete"],
                rollback["found_holder"],
                rollback["holder_messages"][:1],
            ),
        )

        free_db = os.path.join(self.db_dir, "libre.db")
        conn2 = sqlite3.connect(free_db)
        conn2.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn2.commit()
        conn2.close()
        rollback_free = safety.check_rollback_db_holders(free_db, "fase-sintetica", str(os.getpid()))
        ok = rollback_free["complete"] and not rollback_free["found_holder"]
        self.report.record(
            "HOLD-7",
            KIND_DYNAMIC,
            ok,
            "completo=%s holders=%s (esperado sin holders)"
            % (rollback_free["complete"], rollback_free["found_holder"]),
        )

        # OBS-1: regression guard for D1. The classifier must match the
        # rollback-journal companion "<db>-journal" as well: a process that
        # holds only that descriptor IS a holder of the target database.
        journal_db = os.path.join(self.db_dir, "journal.db")
        conn3 = sqlite3.connect(journal_db)
        conn3.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn3.commit()
        conn3.close()
        journal_file = journal_db + "-journal"
        with open(journal_file, "wb") as stream:
            stream.write(b"sintetico")
        journal_holder = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), journal_file]
        )
        time.sleep(0.3)
        journal_result = scan("journal", 5, journal_db)
        journal_holders = read(journal_result["holders_file"])
        journal_blockers = read(journal_result["blockers_file"])
        detected = journal_file in journal_holders
        blocker_pids = set(re.findall(r"^pid=(\d+)", journal_blockers, re.MULTILINE))
        is_blocker = str(journal_holder.pid) in blocker_pids
        ok = detected and journal_result["holder_count"] >= 1 and is_blocker
        self.report.record(
            "OBS-1",
            KIND_DYNAMIC,
            ok,
            "regresion D1: el compañero <db>-journal SE clasifica como holder "
            "(holders=%d detectado=%s bloqueante=%s) — conjunto comparado db/-wal/-shm/-journal"
            % (journal_result["holder_count"], detected, is_blocker),
        )

    # -- SIM ---------------------------------------------------------------
    def case_simulations(self):
        """Deterministic simulations of the branches that cannot be reproduced
        safely and deterministically on this host."""
        safety = self.cutover_safety
        db = os.path.join(self.db_dir, "sim.db")
        import sqlite3

        conn = sqlite3.connect(db)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        holder = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db]
        )
        time.sleep(0.3)

        base_registration = {
            "valid": "0",
            "pid": "0",
            "start": "0",
            "exe": "/nonexistent",
            "dev_inode": "0:0",
            "shell_pid": str(os.getpid()),
        }

        def fresh_sim(name):
            return load_module(name, os.path.join(self.external_root, CUTOVER_SAFETY_REL))

        # --- SIM-1: unreadable descriptor directory -----------------------
        sim = fresh_sim("cutover_safety_sim_perm")
        real_os = sim.os

        class OsProxy(object):
            """Forwards everything to os but denies access to /proc/<pid>/fd."""

            def __init__(self, target, denied_pid):
                self._target = target
                self._denied = "/proc/%d/fd" % denied_pid

            def access(self, path, mode, **kwargs):
                if str(path).startswith(self._denied):
                    return False
                return self._target.access(path, mode, **kwargs)

            def __getattr__(self, name):
                return getattr(self._target, name)

        sim.os = OsProxy(real_os, holder.pid)
        directory = os.path.join(self.scan_dir, "sim-perm")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            perm_result = sim.scan_cutover_proc_inventory(
                db,
                "sintetico",
                10,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                base_registration,
            )
            with open(perm_result["errors_file"], "r", encoding="utf-8") as stream:
                perm_errors = stream.read()
        finally:
            sim.os = real_os
        ok = perm_result["complete"] is False and "descriptores fd inaccesibles" in perm_errors
        self.report.record(
            "SIM-1",
            KIND_SIMULATION,
            ok,
            "inyectado=os.access niega /proc/%d/fd -> completo=%s errores=%r"
            % (holder.pid, perm_result["complete"], perm_errors.strip()[:160]),
        )

        # --- SIM-2: a process that disappeared during the inventory -------
        sim2 = fresh_sim("cutover_safety_sim_ghost")
        real_glob = sim2.glob.glob
        ghost_pid = 999999

        def ghost_glob(pattern, *args, **kwargs):
            entries = real_glob(pattern, *args, **kwargs)
            if pattern == "/proc/[0-9]*":
                return list(entries) + ["/proc/%d" % ghost_pid]
            return entries

        sim2.glob.glob = ghost_glob
        directory = os.path.join(self.scan_dir, "sim-ghost")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            ghost_result = sim2.scan_cutover_proc_inventory(
                db,
                "sintetico",
                11,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                base_registration,
            )
            with open(ghost_result["errors_file"], "r", encoding="utf-8") as stream:
                ghost_errors = stream.read()
        finally:
            sim2.glob.glob = real_glob
        ok = (
            ghost_result["complete"] is False
            and "proceso desaparecio durante el inventario" in ghost_errors
        )
        self.report.record(
            "SIM-2",
            KIND_SIMULATION,
            ok,
            "inyectado=/proc/%d inexistente en el inventario -> completo=%s errores=%r"
            % (ghost_pid, ghost_result["complete"], ghost_errors.strip()[:160]),
        )

        # --- SIM-3: PID reuse detected between the two observations -------
        sim3 = fresh_sim("cutover_safety_sim_reuse")
        real_ticks = sim3._proc_start_ticks
        seen = {}

        def shifting_ticks(pid):
            value = real_ticks(pid)
            seen[pid] = seen.get(pid, 0) + 1
            if str(pid) == str(holder.pid) and seen[pid] >= 2 and value is not None:
                return str(int(value) + 1)
            return value

        sim3._proc_start_ticks = shifting_ticks
        directory = os.path.join(self.scan_dir, "sim-reuse")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            reuse_result = sim3.scan_cutover_proc_inventory(
                db,
                "sintetico",
                12,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                base_registration,
            )
            with open(reuse_result["errors_file"], "r", encoding="utf-8") as stream:
                reuse_errors = stream.read()
        finally:
            sim3._proc_start_ticks = real_ticks
        ok = (
            reuse_result["complete"] is False
            and "PID reutilizado durante el inventario" in reuse_errors
        )
        self.report.record(
            "SIM-3",
            KIND_SIMULATION,
            ok,
            "inyectado=inicio_ticks distinto en la segunda observacion -> completo=%s errores=%r"
            % (reuse_result["complete"], reuse_errors.strip()[:160]),
        )

        # --- SIM-4: same guard on the rollback classification --------------
        sim4 = fresh_sim("cutover_safety_sim_reuse_rb")
        real_ticks4 = sim4._proc_start_ticks
        seen4 = {}

        def shifting_ticks4(pid):
            value = real_ticks4(pid)
            seen4[pid] = seen4.get(pid, 0) + 1
            if str(pid) == str(holder.pid) and seen4[pid] >= 2 and value is not None:
                return str(int(value) + 1)
            return value

        sim4._proc_start_ticks = shifting_ticks4
        try:
            rollback_sim = sim4.check_rollback_db_holders(db, "fase-sintetica", str(os.getpid()))
        finally:
            sim4._proc_start_ticks = real_ticks4
        ok = (
            rollback_sim["complete"] is False
            and any("PID reutilizado" in item for item in rollback_sim["issue_messages"])
        )
        self.report.record(
            "SIM-4",
            KIND_SIMULATION,
            ok,
            "inyectado=inicio_ticks distinto en la segunda observacion (rollback) -> completo=%s avisos=%r"
            % (rollback_sim["complete"], rollback_sim["issue_messages"][:1]),
        )

    # -- GRP ---------------------------------------------------------------
    def case_groups(self):
        """Current contract of the group cleanup (no killpg redesign)."""
        plugin_sync = self.plugin_sync
        marker = os.path.join(self.root, "group-term-marker")
        descendant = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "leader.py")], session=True
        )
        descendant.wait(timeout=10)
        time.sleep(0.5)
        members = plugin_sync._process_group_pids(descendant.pid)
        started = time.monotonic()
        result = plugin_sync._terminate_process_groups([descendant], time.monotonic() + 10.0)
        elapsed = time.monotonic() - started
        remaining = plugin_sync._process_group_pids(descendant.pid)
        ok = (
            descendant.returncode == 0
            and len(members) == 1
            and result is True
            and not remaining
        )
        self.report.record(
            "GRP-1",
            KIND_DYNAMIC,
            ok,
            "lider_salida_temprana=%s descendientes_vivos_antes=%d resultado=%s supervivientes=%d elapsed=%.2fs"
            % (descendant.returncode, len(members), result, len(remaining), elapsed),
        )

        child = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), marker],
            session=True,
        )
        started = time.monotonic()
        result = plugin_sync._terminate_process_groups([child], time.monotonic() + 10.0)
        elapsed = time.monotonic() - started
        members = plugin_sync._process_group_pids(child.pid)
        delivered = os.path.exists(marker)
        control_marker = marker + ".control"
        control = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), control_marker],
            session=True,
        )
        control.kill()
        control.wait(timeout=10)
        # After the D2 fix the escalation is observable through the wait
        # status: the member that survived SIGTERM really died by SIGKILL.
        status = child.returncode
        ok = (
            result is True
            and not members
            and delivered
            and elapsed >= 0.4
            and status == -signal.SIGKILL
        )
        self.report.record(
            "GRP-2",
            KIND_DYNAMIC,
            ok,
            "resultado=%s supervivientes=%d term_entregado=%s elapsed=%.2fs (ventana TERM 0.5s) "
            "returncode=%s (esperado %d: escalado a SIGKILL)"
            % (result, len(members), delivered, elapsed, status, -signal.SIGKILL),
        )

        empty = self.spawn_sleeper(
            [sys.executable, "-c", "import time; time.sleep(3600)"], session=True
        )
        empty.kill()
        empty.wait(timeout=10)
        result = plugin_sync._terminate_process_groups([empty], time.monotonic() + 5.0)
        self.report.record(
            "GRP-3",
            KIND_DYNAMIC,
            result is True,
            "grupo_vacio resultado=%s (esperado True sin senalar)" % result,
        )

        # OBS-2: regression guard for D2. The production group reaper must
        # preserve the exit status of the direct children it is given, so the
        # caller can tell a signal death (-9) from a clean exit (0).
        status_child = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), marker + ".obs"],
            session=True,
        )
        plugin_sync._terminate_process_groups([status_child], time.monotonic() + 10.0)
        observed_status = status_child.returncode
        ok = observed_status == -signal.SIGKILL
        self.report.record(
            "OBS-2",
            KIND_DYNAMIC,
            ok,
            "regresion D2: tras _terminate_process_groups el returncode del hijo vale %s "
            "(esperado %d: la muerte por SIGKILL se refleja en Popen.returncode, no 0)"
            % (observed_status, -signal.SIGKILL),
        )

    # -- DBPATH ------------------------------------------------------------
    def case_database_path(self):
        """_runtime_database_path over a synthetic pinned CLI."""
        plugin_sync = self.plugin_sync
        bin_dir = os.path.join(self.fixtures_dir, "bin")
        os.makedirs(bin_dir, mode=0o700, exist_ok=True)
        target_db = os.path.join(self.db_dir, "resolved.db")
        with open(target_db, "wb") as stream:
            stream.write(b"sintetico")

        def make_fake(name, body):
            path = os.path.join(bin_dir, name)
            with open(path, "w", encoding="utf-8") as stream:
                stream.write(body)
            os.chmod(path, 0o700)
            return path

        ok_fake = make_fake(
            "fake-ok",
            "#!/bin/sh\nprintf '%%s\\n' '%s'\n" % target_db,
        )
        ambiguous_fake = make_fake(
            "fake-ambiguous",
            "#!/bin/sh\nprintf '%%s\\n%%s\\n' '%s' '%s'\n" % (target_db, target_db),
        )
        relative_fake = make_fake("fake-relative", "#!/bin/sh\nprintf 'relative.db\\n'\n")
        fail_fake = make_fake("fake-fail", "#!/bin/sh\nprintf 'boom\\n' >&2\nexit 3\n")
        hang_fake = make_fake("fake-hang", "#!/bin/sh\nsleep 300\n")

        owned = []
        resolved = plugin_sync._runtime_database_path(
            ok_fake, "", self.root, time.monotonic() + 30.0, owned
        )
        ok = resolved == os.path.realpath(target_db) and len(owned) == 1
        self.report.record(
            "DBPATH-1",
            KIND_DYNAMIC,
            ok,
            "ruta_resuelta=%s (esperado %s) procesos_propios=%d"
            % (resolved, os.path.realpath(target_db), len(owned)),
        )

        for case_id, binary, expected in (
            ("DBPATH-2", ambiguous_fake, "ambiguous"),
            ("DBPATH-3", relative_fake, "unsupported"),
            ("DBPATH-4", fail_fake, "RC=3"),
        ):
            message = ""
            failed = False
            try:
                plugin_sync._runtime_database_path(
                    binary, "", self.root, time.monotonic() + 30.0, []
                )
            except plugin_sync.PluginSyncError as exc:
                failed = True
                message = str(exc)
            self.report.record(
                case_id,
                KIND_DYNAMIC,
                failed and expected in message,
                "rechazado=%s mensaje=%r (esperado %r)" % (failed, message[:180], expected),
            )

        # Timeout: the owned session must be terminated by the deadline.
        before = set(
            entry
            for entry in os.listdir("/proc")
            if entry.isdigit() and hang_fake in cmdline_of(entry)
        )
        raised = False
        message = ""
        timeout_owned = []
        try:
            plugin_sync._runtime_database_path(
                hang_fake, "", self.root, time.monotonic() + 6.0, timeout_owned
            )
        except plugin_sync.RuntimeDeadline as exc:
            raised = True
            message = str(exc)
        except plugin_sync.PluginSyncError as exc:
            message = "PluginSyncError=%s" % exc
        time.sleep(0.5)
        after = set(
            entry
            for entry in os.listdir("/proc")
            if entry.isdigit() and hang_fake in cmdline_of(entry)
        )
        # After the D2 fix the terminated session reports its signal death.
        timeout_status = timeout_owned[0].returncode if timeout_owned else None
        status_ok = timeout_status is not None and timeout_status < 0
        ok = raised and not after and not (before - after) and status_ok
        self.report.record(
            "DBPATH-5",
            KIND_DYNAMIC,
            ok,
            "presupuesto_agotado=%s mensaje=%r antes=%d despues=%d returncode=%s (esperado <0: "
            "muerte por senal) — la sesion propia queda terminada"
            % (raised, message[:120], len(before), len(after), timeout_status),
        )

    # -- CLEAN -------------------------------------------------------------
    def real_db_open_descriptors(self):
        """Open descriptors of the batch pointing at the real database.

        Inside the private PID namespace only the processes of the batch are
        visible, so any hit means that THIS batch opened the real database.
        """
        found = []
        if not self.real_db:
            return found
        targets = (self.real_db, self.real_db + "-wal", self.real_db + "-shm")
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            fd_dir = os.path.join("/proc", entry, "fd")
            try:
                names = os.listdir(fd_dir)
            except OSError:
                continue
            for name in names:
                try:
                    link = os.readlink(os.path.join(fd_dir, name))
                except OSError:
                    continue
                if link in targets:
                    found.append((entry, name, link))
        return found

    def case_cleanup(self):
        """No synthetic process or resource of the batch survives."""
        survivors = []
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            pid = int(entry)
            if pid == os.getpid():
                continue
            if self.root in cmdline_of(pid):
                survivors.append(pid)
        self.report.record(
            "CLEAN-1",
            KIND_DYNAMIC,
            not survivors,
            "supervivientes_propios=%s (esperado [])" % (survivors,),
        )
        # The real database must never be OPENED by this batch. Its mtime
        # cannot be used as evidence: the live OpenCode session of the user
        # writes to it continuously. The reliable invariants are the inode
        # identity and the absence of any open descriptor of the batch.
        after = fingerprint(self.real_db, hash_content=False) if self.real_db else {"exists": False}
        open_fds = self.real_db_open_descriptors()
        inode_stable = (
            self.real_db_before.get("ino") == after.get("ino")
            and self.real_db_before.get("dev") == after.get("dev")
        )
        ok = not open_fds and inode_stable
        self.report.record(
            "CLEAN-2",
            KIND_DYNAMIC,
            ok,
            "la db real nunca se abre: descriptores_abiertos_del_lote=%s (esperado []) "
            "identidad_estable=%s ino=%s size=%s mtime_antes=%s mtime_despues=%s "
            "(el mtime no sirve como evidencia: la sesion viva del usuario escribe en ella; "
            "solo metadatos, sin leer contenido)"
            % (
                open_fds,
                inode_stable,
                after.get("ino"),
                after.get("size"),
                self.real_db_before.get("mtime_ns"),
                after.get("mtime_ns"),
            ),
        )

    # -- INSP --------------------------------------------------------------
    def case_inspection(self):
        plugin_sync_path = os.path.join(self.repo_root, PLUGIN_SYNC_REL)
        safety_path = os.path.join(self.external_root, CUTOVER_SAFETY_REL)
        ok = os.path.isfile(plugin_sync_path) and os.path.isfile(safety_path)
        self.report.record(
            "INSP-1",
            KIND_INSPECTION,
            ok,
            "plugin_sync=%s sha256=%s | cutover_safety=%s sha256=%s"
            % (
                plugin_sync_path,
                sha256_file(plugin_sync_path) if os.path.isfile(plugin_sync_path) else "-",
                safety_path,
                sha256_file(safety_path) if os.path.isfile(safety_path) else "-",
            ),
        )

        loaded = []
        for name, module, expected in (
            ("plugin-sync", self.plugin_sync, plugin_sync_path),
            ("cutover-safety", self.cutover_safety, safety_path),
        ):
            actual = os.path.realpath(module.__file__)
            loaded.append(
                {
                    "name": name,
                    "path": actual,
                    "expected": os.path.realpath(expected),
                    "matches": actual == os.path.realpath(expected),
                    "sha256": sha256_file(actual),
                }
            )
        self.report.libraries = loaded
        ok = all(item["matches"] for item in loaded)
        self.report.record(
            "INSP-2",
            KIND_INSPECTION,
            ok,
            "bibliotecas_cargadas=%s"
            % "; ".join("%s@%s" % (item["name"], item["path"]) for item in loaded),
        )

        copies = []
        for base, dirs, files in os.walk(self.repo_root):
            dirs[:] = [name for name in dirs if name not in (".git", "node_modules")]
            for name in files:
                if name == "cutover_safety.py":
                    copies.append(os.path.join(base, name))
        self.report.record(
            "INSP-3",
            KIND_INSPECTION,
            not copies,
            "copias_de_cutover_safety_en_el_repo=%s (esperado [])" % (copies,),
        )

        executed = []
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            cmdline = cmdline_of(entry)
            for token in EXTERNAL_ENTRYPOINT_TOKENS:
                if token in cmdline:
                    executed.append((entry, token))
        self.report.record(
            "INSP-4",
            KIND_INSPECTION,
            not executed,
            "entrypoints_externos_o_dbtool_en_ejecucion=%s (esperado [])" % (executed,),
        )

        expected = {
            "plugin_sync": [
                "_runtime_deadline_fuse",
                "_runtime_database_path",
                "_snapshot_database",
                "_terminate_process_groups",
                "_process_group_pids",
            ],
            "cutover_safety": [
                "check_pidfd_support",
                "pidfd_stop_registered_server",
                "register_server_child",
                "scan_cutover_proc_inventory",
                "check_rollback_db_holders",
            ],
        }
        modules = {"plugin_sync": self.plugin_sync, "cutover_safety": self.cutover_safety}
        missing = []
        signatures = []
        for key, names in expected.items():
            module = modules[key]
            for name in names:
                function = getattr(module, name, None)
                if function is None or not callable(function):
                    missing.append("%s.%s" % (key, name))
                else:
                    signatures.append("%s.%s%s" % (key, name, inspect.signature(function)))
        self.report.record(
            "INSP-5",
            KIND_INSPECTION,
            not missing,
            "funciones=%s | firmas=%s"
            % ("todas presentes" if not missing else missing, "; ".join(signatures)),
        )

    # -- driver ------------------------------------------------------------
    def run(self):
        cases = [
            self.case_snapshot,
            self.case_deadline,
            self.case_database_path,
            self.case_fuse,
            self.case_pidfd,
            self.case_holders,
            self.case_simulations,
            self.case_groups,
        ]
        for function in cases:
            try:
                function()
            except Exception:
                self.report.record(
                    "ERROR-" + function.__name__.upper(),
                    KIND_DYNAMIC,
                    False,
                    "excepcion: %s" % traceback.format_exc().strip().splitlines()[-1],
                )
        # The synthetic children are terminated BEFORE the cleanup evidence is
        # taken: "no process of the batch survives" is asserted on a state in
        # which the batch has already released its own resources.
        self.cleanup_children()
        for function in (self.case_cleanup, self.case_inspection):
            try:
                function()
            except Exception:
                self.report.record(
                    "ERROR-" + function.__name__.upper(),
                    KIND_DYNAMIC,
                    False,
                    "excepcion: %s" % traceback.format_exc().strip().splitlines()[-1],
                )


# ---------------------------------------------------------------------------
# role: suite (inside the private namespace)
# ---------------------------------------------------------------------------
def role_suite(args):
    report = Report()
    root = args.root
    # This suite loads the production modules BY PATH (load_module), so the
    # import machinery would otherwise write a __pycache__ next to the source:
    # inside the Git working tree (open-code/lib/) and inside the read-only
    # external tree (lib/). The import is NOT disabled: the real modules are
    # loaded and their real functions are exercised. Only the WRITING of
    # bytecode is suppressed, and this flag makes the guarantee intrinsic to
    # the process instead of depending on the inherited environment.
    sys.dont_write_bytecode = True
    try:
        os.makedirs(root, mode=0o700, exist_ok=True)
    except OSError:
        pass
    containment = accredit_containment(os.environ)
    report.containment = containment
    if not containment["ok"]:
        report.record(
            "PRE-1",
            KIND_DYNAMIC,
            False,
            "BLOCKED: contencion no acreditada (%s)" % containment["reason"],
        )
        report.write(args.report_path)
        print("BLOCKED: la contencion no pudo acreditarse: %s" % containment["reason"])
        return 3
    report.record(
        "PRE-1",
        KIND_DYNAMIC,
        True,
        "contencion acreditada: %s" % containment["summary"],
    )

    # Fault injection (test harness only): spawn a synthetic child and hang,
    # so the supervisor has to terminate the namespace init AND its
    # descendants through its cleanup chain.
    if os.environ.get(FAULT_HANG_SUITE) == "1":
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(3600)"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(
            "[inyeccion] hijo sintetico creado (pid interno %d); la suite se cuelga a proposito"
            % child.pid,
            flush=True,
        )
        while True:
            time.sleep(3600)

    # Authorization barrier: no sensitive function is called until the
    # supervisor has accredited the containment and has an operational
    # watchdog. An unreleased barrier aborts the suite with a non zero RC.
    granted, reason = await_authorization(args.auth_fd)
    containment["authorization"] = {"granted": granted, "reason": reason}
    if not granted:
        report.record("PRE-2", KIND_DYNAMIC, False, "BLOCKED: %s" % reason)
        report.write(args.report_path)
        print("BLOCKED: la barra de autorizacion no se libero: %s" % reason)
        return 4
    report.record(
        "PRE-2",
        KIND_DYNAMIC,
        True,
        "autorizacion del supervisor concedida: %s" % reason,
    )

    suite = Suite(report, root, args.repo_root, args.external_root, args.real_db)
    report_write_error = None
    try:
        for name in ("db", "private", "scan", "home", "tmp"):
            os.makedirs(os.path.join(root, name), mode=0o700, exist_ok=True)
        write_fixtures(root)
        suite.plugin_sync = load_module(
            "plugin_sync_under_test", os.path.join(args.repo_root, PLUGIN_SYNC_REL)
        )
        suite.cutover_safety = load_module(
            "cutover_safety_under_test",
            os.path.join(args.external_root, CUTOVER_SAFETY_REL),
        )
        suite.run()
    except Exception:
        report.record(
            "ERROR-SUITE",
            KIND_DYNAMIC,
            False,
            "excepcion: %s" % traceback.format_exc().strip().splitlines()[-1],
        )
    finally:
        suite.cleanup_children()
        try:
            report.write(args.report_path)
        except OSError as exc:
            # The evidence must never be lost silently.
            report_write_error = "la suite no pudo escribir su parte del informe en %s: %s" % (
                args.report_path,
                exc,
            )
            print("FALLO: %s" % report_write_error)
        shutil.rmtree(root, ignore_errors=True)
    counts = report.counts()
    print(
        "[resumen] casos=%d fallidos=%d dinamicas=%d simulaciones=%d inspecciones=%d"
        % (
            len(report.cases),
            report.failed,
            counts[KIND_DYNAMIC],
            counts[KIND_SIMULATION],
            counts[KIND_INSPECTION],
        ),
        flush=True,
    )
    if report_write_error:
        return 9
    return 1 if report.failed else 0


# ---------------------------------------------------------------------------
# role: supervisor (outside any namespace)
# ---------------------------------------------------------------------------
def verify_no_survivors(private_ns):
    """Live (non zombie) processes that still belong to the private namespace."""
    survivors = []
    if not private_ns:
        return survivors
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            if os.readlink("/proc/%s/ns/pid" % entry) != private_ns:
                continue
            with open("/proc/%s/stat" % entry, "r", encoding="ascii") as stream:
                raw = stream.read()
            fields = raw[raw.rfind(")") + 2 :].split()
            if fields[0] == "Z":
                # A zombie is dead, only not reaped yet: it is not a survivor.
                continue
            survivors.append(int(entry))
        except (OSError, ValueError, IndexError):
            continue
    return survivors


def group_members(pgid):
    members = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % entry, "r", encoding="ascii") as stream:
                raw = stream.read()
            fields = raw[raw.rfind(")") + 2 :].split()
            if int(fields[2]) == pgid and fields[0] != "Z":
                members.append(int(entry))
        except (OSError, ValueError, IndexError):
            continue
    return members


def await_authorization(auth_fd):
    """Block until the supervisor releases the authorization barrier.

    The barrier is released ONLY when the supervisor has accredited the
    containment and has an operational watchdog (a pidfd on the namespace
    init). Any other outcome reaches the suite as EOF on the channel, and the
    suite aborts before calling a single sensitive function.

    Returns ``(granted, reason)``.
    """
    if auth_fd is None or auth_fd < 0:
        return False, "the suite was started without an authorization channel"
    try:
        duplicate = os.dup(auth_fd)
    except OSError as exc:
        return False, "the authorization channel is not usable: %s" % exc
    try:
        with os.fdopen(duplicate, "rb", buffering=0) as stream:
            line = stream.readline()
    except OSError as exc:
        return False, "the authorization channel could not be read: %s" % exc
    token = line.decode("utf-8", "replace").strip()
    if token != AUTH_TOKEN:
        return False, (
            "the authorization token %r was not received; the supervisor closed "
            "the channel without releasing the barrier" % token
        )
    return True, token


def terminate_batch_resources(
    init_pid, init_ticks, private_ns, pidfd, launcher_pid, launcher_ticks
):
    """Terminate the private namespace and every descendant of the batch.

    The chain never depends on the tested code:

      1. the stable handle (pidfd) on the namespace init; killing the init
         tears the whole private PID namespace down,
      2. a verified kill of the namespace init (namespace + start ticks must
         still match, so a recycled PID is never signalled),
      3. as a last resort, the batch's own process group, whose members are
         the launcher and the init with all its descendants.

    Every step is identity-checked first: no signal is ever sent to a
    process the batch cannot attribute.
    """
    actions = []

    if pidfd is not None:
        try:
            signal.pidfd_send_signal(pidfd, signal.SIGKILL)
            actions.append("pidfd SIGKILL sobre el init del namespace")
        except OSError as exc:
            if exc.errno == errno.ESRCH:
                actions.append("pidfd: el init ya habia terminado (ESRCH)")
            else:
                actions.append("pidfd SIGKILL: %s" % exc)

    if init_pid and init_ticks:
        verified = False
        try:
            with open("/proc/%d/stat" % init_pid, "r", encoding="ascii") as stream:
                raw = stream.read()
            fields = raw[raw.rfind(")") + 2 :].split()
            verified = (
                fields[19] == init_ticks
                and private_ns is not None
                and os.readlink("/proc/%d/ns/pid" % init_pid) == private_ns
            )
        except (OSError, ValueError, IndexError):
            verified = False
        if verified:
            try:
                os.kill(init_pid, signal.SIGKILL)
                actions.append("kill verificado del init (namespace + inicio coinciden)")
            except OSError as exc:
                actions.append("kill verificado del init: %s" % exc)
        else:
            actions.append("kill del init omitido (identidad no verificada o ya exit)")

    if launcher_pid and launcher_ticks:
        if not pid_alive(launcher_pid):
            actions.append("el lanzador ya habia terminado por su cuenta (no se senala)")
        else:
            verified = False
            pgrp = None
            try:
                with open("/proc/%d/stat" % launcher_pid, "r", encoding="ascii") as stream:
                    raw = stream.read()
                fields = raw[raw.rfind(")") + 2 :].split()
                verified = fields[19] == launcher_ticks
                pgrp = int(fields[2])
            except (OSError, ValueError, IndexError):
                verified = False
            if verified and pgrp == launcher_pid:
                try:
                    os.killpg(pgrp, signal.SIGKILL)
                    actions.append("killpg verificado del grupo propio del lote (%d)" % pgrp)
                except OSError as exc:
                    actions.append("killpg verificado: %s" % exc)
            else:
                actions.append("killpg no aplicable (identidad no verificada)")

    return actions


def resolve_report_path(path):
    """Normalise the report path ONCE, so the supervisor and the suite always
    share the very same absolute file.

    A relative path is resolved against the batch evidence root, NEVER
    against the working directory: the suite runs with its own cwd (the
    batch root, which the supervisor deletes afterwards) and the supervisor
    runs wherever the operator invoked it, possibly inside the Git working
    tree. Resolving against a fixed base keeps both actors on one file and
    leaves no stray artefact in the repository.
    """
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        return os.path.normpath(expanded)
    return os.path.normpath(os.path.join(BATCH_ROOT, expanded))


def proc_identity(pid):
    """Identity of a process owned by the batch (never of a host process)."""
    identity = {"pid": pid}
    try:
        identity["exe"] = os.readlink("/proc/%d/exe" % pid)
        meta = os.stat("/proc/%d/exe" % pid)
        identity["exe_dev_inode"] = "%d:%d" % (meta.st_dev, meta.st_ino)
    except OSError:
        identity["exe"] = "<ilegible>"
        identity["exe_dev_inode"] = "<ilegible>"
    for name in ("pid", "user", "mnt"):
        try:
            identity["ns_" + name] = os.readlink("/proc/%d/ns/%s" % (pid, name))
        except OSError:
            identity["ns_" + name] = "<ilegible>"
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii") as stream:
            raw = stream.read()
        fields = raw[raw.rfind(")") + 2 :].split()
        identity["pgrp"] = int(fields[2])
        identity["session"] = int(fields[3])
        identity["start_time_ticks"] = fields[19]
    except (OSError, ValueError, IndexError):
        pass
    try:
        with open("/proc/%d/status" % pid, "r", encoding="ascii") as stream:
            for line in stream:
                if line.startswith("Uid:"):
                    identity["uid_host"] = int(line.split()[1])
                    break
    except OSError:
        pass
    return identity


def role_supervisor(args):
    evidence = {
        "role": "supervisor",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "steps": [],
    }

    def step(name, ok, detail):
        evidence["steps"].append({"step": name, "ok": bool(ok), "detail": detail})
        print("[supervisor] %s %s :: %s" % (name, "OK" if ok else "FAIL", detail), flush=True)
        return ok

    plugin_sync_path = os.path.join(args.repo_root, PLUGIN_SYNC_REL)
    safety_path = os.path.join(args.external_root, CUTOVER_SAFETY_REL)
    if not os.path.isfile(plugin_sync_path):
        step("componentes", False, "falta %s" % plugin_sync_path)
        print("BLOCKED: falta el componente requerido %s" % plugin_sync_path)
        return 2
    if not os.path.isfile(safety_path):
        step("componentes", False, "falta %s" % safety_path)
        print("BLOCKED: falta el componente requerido %s" % safety_path)
        return 2
    step(
        "componentes",
        True,
        "plugin_sync=%s sha256=%s | cutover_safety=%s sha256=%s"
        % (plugin_sync_path, sha256_file(plugin_sync_path), safety_path, sha256_file(safety_path)),
    )

    try:
        probe = subprocess.run(
            ["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc", "/bin/true"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
        )
        probe_rc = probe.returncode
        probe_err = probe.stderr.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError) as exc:
        probe_rc = -1
        probe_err = "%s: %s" % (type(exc).__name__, exc)
    if probe_rc != 0:
        step(
            "contencion",
            False,
            "unshare --user --map-root-user --pid --fork --mount-proc rc=%d stderr=%r"
            % (probe_rc, probe_err),
        )
        print("BLOCKED: no se pudo establecer la contencion; no se llama a ninguna funcion sensible")
        return 3
    step("contencion", True, "unshare rootless + PID privado disponible (rc=0)")

    root = os.path.join(BATCH_ROOT, "safety-run-%d" % os.getpid())
    shutil.rmtree(root, ignore_errors=True)
    for name in ("", "home", "tmp", "db", "private", "scan", "fixtures"):
        os.makedirs(os.path.join(root, name), mode=0o700, exist_ok=True)
    os.chmod(root, 0o700)

    host_ns_pid = os.readlink("/proc/self/ns/pid")
    host_ns_user = os.readlink("/proc/self/ns/user")
    host_ns_mnt = os.readlink("/proc/self/ns/mnt")

    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.path.join(root, "home"),
        "TMPDIR": os.path.join(root, "tmp"),
        "LANG": "C",
        "LC_ALL": "C",
        "FORGE_V2_HOST_PIDNS": host_ns_pid,
        "FORGE_V2_HOST_USERNS": host_ns_user,
        "FORGE_V2_HOST_MNTNS": host_ns_mnt,
        "FORGE_V2_REAL_DB": args.real_db,
        # The suite imports the production modules BY PATH, so it must not be
        # able to write bytecode next to them: that would create a
        # __pycache__ inside the Git working tree (open-code/lib/) and inside
        # the read-only external tree (lib/). The import itself is NOT
        # disabled: the real functions are still loaded and exercised.
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    # The environment allowlist stays tight: only the two known fault
    # injection switches of this harness travel to the suite, and only when
    # they are explicitly exported.
    for name in (FAULT_NO_PIDFD, FAULT_HANG_SUITE):
        value = os.environ.get(name)
        if value:
            env[name] = value

    # The report path is normalised ONCE here: the suite receives the very
    # same absolute file that the supervisor reads back and completes.
    report_path = resolve_report_path(args.report_path)
    os.makedirs(os.path.dirname(report_path) or ".", exist_ok=True)
    command = [
        "unshare",
        "--user",
        "--map-root-user",
        "--pid",
        "--fork",
        "--mount-proc",
        sys.executable,
        os.path.abspath(__file__),
        "--role",
        "suite",
        "--root",
        root,
        "--repo-root",
        args.repo_root,
        "--external-root",
        args.external_root,
        "--report-path",
        report_path,
        "--real-db",
        args.real_db,
        "--auth-fd",
        "0",
    ]

    # The authorization channel: the suite blocks on it until the supervisor
    # has accredited the containment AND armed an operational watchdog.
    auth_read, auth_write = os.pipe()
    launcher = subprocess.Popen(
        command,
        stdin=auth_read,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        cwd=root,
        start_new_session=True,
    )
    os.close(auth_read)

    init_pid = None
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline and init_pid is None:
        children = read_proc_children(launcher.pid)
        if children:
            init_pid = children[0]
            break
        if launcher.poll() is not None:
            break
        time.sleep(0.02)
    if init_pid is None:
        try:
            os.close(auth_write)
        except OSError:
            pass
        launcher.kill()
        launcher.wait(timeout=30)
        step("contencion", False, "no se pudo localizar el init del namespace PID")
        print("BLOCKED: no se pudo acreditar el namespace PID privado")
        shutil.rmtree(root, ignore_errors=True)
        return 3
    launcher_identity = proc_identity(launcher.pid)
    step(
        "contencion",
        True,
        "launcher(host)=%d init_del_namespace(host)=%d pgrp=%d"
        % (launcher.pid, init_pid, launcher.pid),
    )

    private_ns = None
    try:
        private_ns = os.readlink("/proc/%d/ns/pid" % init_pid)
    except OSError:
        private_ns = None
    step(
        "contencion",
        private_ns is not None and private_ns != host_ns_pid,
        "ns_pid_privada=%s ns_pid_anfitrion=%s" % (private_ns, host_ns_pid),
    )

    # The watchdog is an EFFECTIVE precondition: it is armed and proven
    # before the barrier is released, and any failure leaves the barrier
    # closed (the suite aborts with a non zero RC).
    pidfd = None
    watchdog_ok = False
    watchdog_detail = ""
    if os.environ.get(FAULT_NO_PIDFD) == "1":
        watchdog_detail = (
            "inyeccion de fallo (%s=1): el watchdog pidfd no se arma" % FAULT_NO_PIDFD
        )
    elif not (hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")):
        # The interpreter does not expose the pidfd API at all (Python < 3.9
        # or a build without it). That is a missing CAPABILITY, not an
        # exception: it takes the very same route as an inoperative
        # watchdog (closed barrier, explicit BLOCK, non zero RC).
        watchdog_detail = (
            "el interprete no expone la API de pidfd (os.pidfd_open / "
            "signal.pidfd_send_signal): el watchdog no puede armarse"
        )
    else:
        try:
            pidfd = os.pidfd_open(init_pid, 0)
            # Signal 0 proves the handle can carry a signal without
            # delivering anything.
            signal.pidfd_send_signal(pidfd, 0)
            watchdog_ok = True
            watchdog_detail = (
                "pidfd operativo sobre el init del namespace (pid=%d); "
                "el handle puede portar senales" % init_pid
            )
        except (OSError, ValueError, AttributeError) as exc:
            pidfd = None
            watchdog_detail = "no se pudo armar el watchdog pidfd sobre el init: %s" % exc
    step("watchdog", watchdog_ok, watchdog_detail)

    poller = select.poll()
    if pidfd is not None:
        poller.register(pidfd, select.POLLIN)

    def pump():
        while True:
            line = launcher.stdout.readline()
            if not line:
                break
            sys.stdout.write(line.decode("utf-8", "replace"))
            sys.stdout.flush()

    pump_thread = threading.Thread(target=pump, daemon=True)
    pump_thread.start()

    # The identity of the namespace init is taken once it has exec'ed the
    # suite: before that it is still the forked copy of the launcher.
    init_identity = None
    identity_deadline = time.monotonic() + 15.0
    while time.monotonic() < identity_deadline:
        candidate = proc_identity(init_pid)
        if candidate.get("exe") != "/usr/bin/unshare":
            init_identity = candidate
            break
        if launcher.poll() is not None:
            break
        time.sleep(0.05)
    if init_identity is None:
        init_identity = proc_identity(init_pid)
    step(
        "identidad",
        True,
        "init_del_namespace exe=%s dev:inode=%s ns_pid=%s uid=%s"
        % (
            init_identity.get("exe"),
            init_identity.get("exe_dev_inode"),
            init_identity.get("ns_pid"),
            init_identity.get("uid_host"),
        ),
    )

    # The barrier is released ONLY when the containment is accredited and the
    # watchdog is operational. Otherwise the channel is closed and the suite
    # aborts before any sensitive call.
    containment_ok = bool(private_ns) and private_ns != host_ns_pid
    authorized = False
    auth_reason = ""
    if watchdog_ok and containment_ok:
        try:
            os.write(auth_write, (AUTH_TOKEN + "\n").encode("utf-8"))
            authorized = True
            auth_reason = (
                "autorizacion concedida: contencion acreditada (ns=%s) y watchdog pidfd operativo"
                % private_ns
            )
        except OSError as exc:
            auth_reason = "no se pudo escribir la autorizacion: %s" % exc
    else:
        auth_reason = "la barra de autorizacion NO se libera: %s" % (
            "watchdog no operativo"
            if not watchdog_ok
            else "contencion no acreditada (ns=%s)" % private_ns
        )
    try:
        os.close(auth_write)
    except OSError:
        pass
    step("barrera", authorized, auth_reason)
    evidence["authorization"] = {"granted": authorized, "reason": auth_reason}

    started = time.monotonic()
    timed_out = False
    while True:
        if launcher.poll() is not None:
            break
        if time.monotonic() - started > args.timeout:
            timed_out = True
            break
        try:
            if pidfd is not None and poller.poll(200):
                break
        except OSError:
            pass
        time.sleep(0.05)

    if not timed_out:
        # The launcher reaps the suite and exits on its own. It is waited
        # for BEFORE the cleanup chain, so the chain never signals a process
        # that is on its way out and the exit status of the suite is read
        # from the launcher, not from a signal.
        try:
            launcher.wait(timeout=30)
        except subprocess.TimeoutExpired:
            timed_out = True

    # Independent cleanup of the resources created by this batch. It never
    # depends on the tested code, and it works with or without a pidfd.
    cleanup_actions = terminate_batch_resources(
        init_pid,
        init_identity.get("start_time_ticks") if init_identity else None,
        private_ns,
        pidfd,
        launcher.pid,
        launcher_identity.get("start_time_ticks") if launcher_identity else None,
    )
    step(
        "limpieza_ejecucion",
        True,
        "cadena de limpieza aplicada: %s" % ("; ".join(cleanup_actions) or "sin acciones"),
    )
    try:
        launcher.wait(timeout=60)
    except subprocess.TimeoutExpired:
        launcher.kill()
        launcher.wait(timeout=30)
    pump_thread.join(timeout=10)
    suite_rc = launcher.returncode

    if pidfd is not None:
        try:
            os.close(pidfd)
        except OSError:
            pass

    step(
        "suite",
        suite_rc == 0 and not timed_out,
        "rc=%d timeout=%s" % (suite_rc, timed_out),
    )

    init_alive = pid_alive(init_pid)
    init_gone = wait_process_gone(init_pid)
    survivors = verify_no_survivors(private_ns)
    members = group_members(launcher.pid)
    root_present = os.path.exists(root)
    if root_present:
        shutil.rmtree(root, ignore_errors=True)
        root_present = os.path.exists(root)
    cleanup_ok = (not init_alive) and not survivors and not members and not root_present
    step(
        "limpieza",
        cleanup_ok,
        "init_vivo=%s init_desaparecido=%s supervivientes_en_el_ns=%s miembros_del_grupo=%s "
        "raiz_privada_presente=%s"
        % (init_alive, init_gone, survivors, members, root_present),
    )

    report = {}
    if os.path.isfile(report_path):
        try:
            with open(report_path, "r", encoding="utf-8") as stream:
                report = json.load(stream)
        except (OSError, ValueError):
            report = {}
    report["cleanup"] = {
        "supervisor_pid": os.getpid(),
        "launcher_host_pid": launcher.pid,
        "namespace_init_host_pid": init_pid,
        "private_pid_namespace": private_ns,
        "host_pid_namespace": host_ns_pid,
        "suite_returncode": suite_rc,
        "timed_out": timed_out,
        "watchdog_operational": watchdog_ok,
        "watchdog_detail": watchdog_detail,
        "authorization_granted": authorized,
        "authorization_reason": auth_reason,
        "cleanup_actions": cleanup_actions,
        "namespace_init_alive_after": init_alive,
        "namespace_init_gone_after": init_gone,
        "survivors_in_private_namespace": survivors,
        "members_of_own_process_group": members,
        "synthetic_root": root,
        "synthetic_root_present_after": root_present,
        "ok": cleanup_ok,
        "resources": [
            {
                "id": "watchdog-supervisor",
                "type": "external-watchdog-supervisor",
                "pid": os.getpid(),
                "root_path": root,
                "cleanup_method": "espera del lanzador y verificacion exterior; no senala nada del host; termina al salir tras escribir el informe",
                "exits_after_report": True,
            },
            {
                "id": "pid-namespace-launcher",
                "type": "pid-namespace-launcher",
                "root_path": root,
                "cleanup_method": "reaped by wait() after the namespace init exited",
                "identity": launcher_identity,
                "verified_absent_after_cleanup": not pid_alive(launcher.pid),
            },
            {
                "id": "namespace-init-suite",
                "type": "own-synthetic-suite",
                "root_path": root,
                "cleanup_method": "cadena de limpieza propia del supervisor: pidfd SIGKILL, kill verificado del init (ns+inicio) y, como ultimo recurso, killpg verificado del grupo propio; nunca depende del codigo probado",
                "identity": init_identity,
                "verified_absent_after_cleanup": not init_alive,
            },
            {
                "id": "synthetic-root",
                "type": "temporary-private-directory",
                "path": root,
                "cleanup_method": "shutil.rmtree on the exact batch-created 0700 path",
                "verified_absent_after_cleanup": not root_present,
            },
        ],
    }
    report["supervisor"] = evidence
    report_write_error = None
    try:
        with open(report_path, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
    except OSError as exc:
        report_write_error = "no se pudo completar el informe en %s: %s" % (report_path, exc)
        print("FALLO: %s" % report_write_error)
        # Best effort: leave a minimal, explicit record of the incident so
        # the missing evidence is never silently invisible.
        try:
            with open(report_path + ".error", "w", encoding="utf-8") as stream:
                json.dump(
                    {
                        "batch": "forge-v2-followups Step 2.2",
                        "error": report_write_error,
                        "supervisor": evidence,
                        "cleanup": report.get("cleanup", {}),
                    },
                    stream,
                    indent=2,
                    ensure_ascii=False,
                    sort_keys=True,
                )
                stream.write("\n")
        except OSError:
            pass

    if report_write_error:
        print(
            "BLOCKED: el informe no se ha podido completar; la evidencia de no-supervivientes "
            "no queda disponible"
        )
        return 8
    if not watchdog_ok:
        print(
            "BLOCKED: el watchdog no quedo operativo (%s); la barra de autorizacion no se libero "
            "y la suite aborta con RC no cero (timeout=%s, suite_rc=%s)"
            % (watchdog_detail, timed_out, suite_rc)
        )
        return 6
    if not authorized:
        print(
            "BLOCKED: la barra de autorizacion no se libero: %s (timeout=%s)" % (auth_reason, timed_out)
        )
        return 7
    if not cleanup_ok:
        print("BLOCKED: la limpieza no pudo acreditarse; quedan recursos propios")
        return 4
    if timed_out:
        print("FALLO: la suite supero el presupuesto de tiempo")
        return 5
    return suite_rc


# ---------------------------------------------------------------------------
def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", required=True, choices=["supervisor", "suite"])
    parser.add_argument("--repo-root", default=os.getcwd())
    parser.add_argument("--external-root", default=DEFAULT_EXTERNAL_ROOT)
    parser.add_argument("--root", default="")
    parser.add_argument("--report-path", default=os.path.join(BATCH_ROOT, "safety-results.json"))
    parser.add_argument(
        "--auth-fd",
        type=int,
        default=-1,
        help="file descriptor of the authorization channel; the suite refuses to "
        "run any sensitive case until the supervisor releases it",
    )
    parser.add_argument("--real-db", default="")
    parser.add_argument("--timeout", type=float, default=300.0)
    args = parser.parse_args(argv)
    if args.role == "supervisor":
        return role_supervisor(args)
    return role_suite(args)


if __name__ == "__main__":
    sys.exit(main())
