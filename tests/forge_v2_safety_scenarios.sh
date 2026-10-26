#!/usr/bin/env bash
# tests/forge_v2_safety_scenarios.sh — executable scenario interface of the
# V2 safety acceptance bank (delivery of @tester for the plan
# `v2-coverage-closure`, Step 2.1).
#
# It closes the coverage debt of the previous batch: the fault injection
# switches FORGE_V2_TEST_NO_PIDFD and FORGE_V2_TEST_HANG_SUITE were the ONLY
# exercise of the authorization barrier and of the cleanup chain, and they did
# NOT belong to the standard green run. From now on every scenario below is
# executable, deterministic and semantically checked, so the autonomous
# verifier can chain them sequentially in every successful run.
#
# Usage:
#   bash tests/forge_v2_safety_scenarios.sh <scenario> <evidence-dir>
#
# Scenarios:
#   normal         the standard acceptance route (no fault injection)
#   no-pidfd       the watchdog pidfd is NOT armed (watchdog FAIL)
#   no-pidfd-hang  no pidfd AND the suite hangs on purpose before the barrier
#
# The scenarios are INDEPENDENT: each one gets its own report, its own log and
# its own semantic verdict. The evidence directory must NOT exist yet, so a
# reused or recycled directory is a hard error (never a silent overwrite).
#
# Exit codes of THIS runner (the verdict of the scenario):
#   0   the scenario behaved exactly as contracted
#   10  an unexpected layer RC (supervisor and/or suite)
#   11  a semantic check failed (wrong behaviour, own survivor, ...)
#   12  evidence missing or incomplete
#   13  a precondition or component is missing
#   14  THIS INTERFACE'S temporal guard expired and the cleanup of every own
#       resource was ACCREDITED (no survivor). It is a HARD FAILURE, never a
#       green run: the scenario did not complete.
#   15  THIS INTERFACE'S temporal guard expired and the cleanup was
#       INCOMPLETE (some own resource survived). Harder failure than 14.
#
# Environment:
#   FORGE_V2_EXTERNAL_ROOT   default: the canonical component versioned in
#                             this checkout (tools/cutover/forge-v2/). The
#                             external copy of the laboratory is a frozen
#                             historical backup and is NEVER consulted by
#                             default; this override is only for a developer
#                             that wants another tree and is NOT needed in CI.
#   FORGE_V2_REAL_DB         default $HOME/.local/share/opencode/opencode.db
#                             (the real DB is only stat()'ed, never opened)
#   FORGE_V2_HANG_TIMEOUT    default 20 (supervisor --timeout of the hang
#                             scenario, in seconds)
#   FORGE_V2_SCENARIO_GUARD  default 420. THE GUARD OF THIS INTERFACE. It
#                             bounds the WHOLE execution of a scenario (the
#                             reads of the supervisor AND the final wait).
#                             Its expiry is a HARD FAILURE (14 with an
#                             accredited cleanup, 15 with an incomplete one),
#                             not a mere hang detector.
#   FORGE_V2_SCENARIO_GRACE  default 20 (seconds granted to the supervisor to
#                             finish its own cleanup chain after this guard
#                             expires)
#   FORGE_V2_OUTER_SCENARIO_GUARD
#                             the OUTER guard of the autonomous verifier. It
#                             is NOT consumed by this interface; it is only
#                             read to CHECK the ordering below. If it is not
#                             strictly greater than FORGE_V2_SCENARIO_GUARD,
#                             this interface refuses to run (RC 13): the
#                             outer guard would kill the batch before this
#                             interface could apply its own cleanup.
#
# Ordering of the three deadlines (they must never contradict each other):
#
#   outer guard of the verifier (FORGE_V2_OUTER_SCENARIO_GUARD, >= 600 s)
#       > guard of this interface (FORGE_V2_SCENARIO_GUARD, default 420 s)
#           > internal timeout of the supervisor (300 s by default; 20 s in
#               the no-pidfd-hang scenario)
#
# So in every scenario the SUPERVISOR is the one that applies its own
# cleanup, and the guard of this interface is only the last net. The same
# order applies to the cleanup grace (20 s), which stays below the outer
# guard.
#
# The runner never signals a pre-existing process, never touches the real
# database beyond a stat(), never executes the external entrypoints and never
# leaves a process of its own behind.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HARNESS="$SCRIPT_DIR/forge_v2_safety_harness.py"

# The real component is consumed from the CANONICAL source versioned in this
# repository (tools/cutover/forge-v2/), resolved RELATIVE TO THE CHECKOUT, so
# the scenarios work in a clean clone and in CI. The external copy of the
# laboratory (/home/espinilleitor/forge-v2-cutover-20261024) is a frozen
# historical backup, not an active source: it is never consulted by default.
EXTERNAL_ROOT="${FORGE_V2_EXTERNAL_ROOT:-$REPO_ROOT/tools/cutover/forge-v2}"
REAL_DB="${FORGE_V2_REAL_DB:-$HOME/.local/share/opencode/opencode.db}"
HANG_TIMEOUT="${FORGE_V2_HANG_TIMEOUT:-20}"
# The temporal guard of THIS interface. It must stay ABOVE the supervisor's
# own internal timeout (300 s by default in the harness), so that in every
# scenario the supervisor is the one that applies its own cleanup, and this
# guard is only the last net. It must also stay BELOW the outer guard of the
# autonomous verifier (600 s), so the three deadlines never contradict each
# other:  outer verifier (600 s) > this guard (420 s) > supervisor internal (300 s).
SCENARIO_GUARD="${FORGE_V2_SCENARIO_GUARD:-420}"
# Grace given to the supervisor to finish its own cleanup chain after the
# guard expired and the batch group has been torn down.
SCENARIO_GRACE="${FORGE_V2_SCENARIO_GRACE:-20}"
# The outer guard of the autonomous verifier is NOT consumed here: it is only
# read to CHECK that the three deadlines stay ordered. If the outer guard were
# not strictly greater than this interface's guard, the outer one would kill
# the batch before this interface could apply its own cleanup.
if [ -n "${FORGE_V2_OUTER_SCENARIO_GUARD:-}" ]; then
  OUTER_GUARD="$FORGE_V2_OUTER_SCENARIO_GUARD"
  if ! [ "$OUTER_GUARD" -gt "$SCENARIO_GUARD" ] 2>/dev/null; then
    echo "FALLO: el guard exterior ($OUTER_GUARD s) debe ser ESTRICTAMENTE mayor que el guard de la interfaz ($SCENARIO_GUARD s); si no, el exterior mataria el lote antes de que esta interfaz limpiara" >&2
    exit 13
  fi
  echo "plazos: guard exterior=${OUTER_GUARD}s > guard de la interfaz=${SCENARIO_GUARD}s > timeout interno del supervisor=300s (${HANG_TIMEOUT}s en no-pidfd-hang)"
fi

SCENARIO="${1:-}"
EVIDENCE_DIR="${2:-}"

usage() {
  echo "uso: bash tests/forge_v2_safety_scenarios.sh <normal|no-pidfd|no-pidfd-hang> <evidence-dir>" >&2
}

if [ -z "$SCENARIO" ] || [ -z "$EVIDENCE_DIR" ]; then
  usage
  exit 13
fi

case "$SCENARIO" in
  normal|no-pidfd|no-pidfd-hang) ;;
  *)
    echo "escenario desconocido: $SCENARIO" >&2
    usage
    exit 13
    ;;
esac

if [ ! -f "$HARNESS" ]; then
  echo "FALLO: harness ausente: $HARNESS" >&2
  exit 13
fi

if [ ! -f "$REPO_ROOT/open-code/lib/plugin-sync.py" ]; then
  echo "FALLO: componente requerido ausente: open-code/lib/plugin-sync.py" >&2
  exit 13
fi

if [ ! -f "$EXTERNAL_ROOT/lib/cutover_safety.py" ]; then
  echo "FALLO: componente requerido ausente: $EXTERNAL_ROOT/lib/cutover_safety.py" >&2
  exit 13
fi

# Independent, new evidence: the directory must not exist yet.
if [ -e "$EVIDENCE_DIR" ]; then
  echo "FALLO: el directorio de evidencia ya existe (se reutilizaria evidencia previa): $EVIDENCE_DIR" >&2
  exit 12
fi
mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"
EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd)"

WORK="$EVIDENCE_DIR/work"
mkdir -p "$WORK"
chmod 700 "$WORK"

REPORT="$EVIDENCE_DIR/safety-results.json"
STDOUT_TSV="$EVIDENCE_DIR/supervisor.stdout.tsv"
STDERR_LOG="$EVIDENCE_DIR/supervisor.stderr"

# ---------------------------------------------------------------------------
# The scenario run. The supervisor runs OUTSIDE any namespace and writes the
# report; its stdout is captured line by line with a monotonic timestamp, so
# the relative order and the real elapsed time of every event are preserved.
# ---------------------------------------------------------------------------
run_supervisor() {
  local -a args=(
    python3 "$HARNESS"
    --role supervisor
    --repo-root "$REPO_ROOT"
    --external-root "$EXTERNAL_ROOT"
    --report-path "$REPORT"
    --real-db "$REAL_DB"
  )

  case "$SCENARIO" in
    no-pidfd|no-pidfd-hang)
      export FORGE_V2_TEST_NO_PIDFD=1
      ;;
  esac

  case "$SCENARIO" in
    no-pidfd-hang)
      export FORGE_V2_TEST_HANG_SUITE=1
      args+=(--timeout "$HANG_TIMEOUT")
      ;;
  esac

  # The synthetic root of the batch lives under the scenario work dir, never
  # under the root of the previous batch.
  export FORGE_V2_BATCH_ROOT="$WORK"
  # Where the wrapper writes the evidence of an expired guard.
  export FORGE_GUARD_EVIDENCE="$EVIDENCE_DIR/guard-expiry.json"
  export FORGE_V2_SCENARIO_GRACE="$SCENARIO_GRACE"

  set +e
  python3 -u - "${args[@]}" > "$STDOUT_TSV" 2> "$STDERR_LOG" <<'PY'
import json
import os
import select
import signal
import subprocess
import sys
import time

# Exit codes of this wrapper:
#   0..9   the RC of the supervisor, passed through unchanged
#   14     the temporal guard expired AND the cleanup of our own resources
#          was accredited (no survivor)
#   15     the temporal guard expired AND some own resource survived
# The supervisor never returns 14 or 15, so the two layers are never mixed.
EXIT_GUARD_EXPIRED = 14
EXIT_GUARD_CLEANUP_INCOMPLETE = 15
GUARD_DEFAULT = 420.0
GRACE_DEFAULT = 20.0

command = sys.argv[1:]
if not command:
    sys.stderr.write("wrapper: no command\n")
    sys.exit(2)

guard = float(os.environ.get("FORGE_V2_SCENARIO_GUARD", str(GUARD_DEFAULT)))
grace = float(os.environ.get("FORGE_V2_SCENARIO_GRACE", str(GRACE_DEFAULT)))
evidence_path = os.environ.get("FORGE_GUARD_EVIDENCE", "")

start = time.monotonic()
deadline = start + guard
proc = subprocess.Popen(command, stdout=subprocess.PIPE)
supervisor_pid = proc.pid
fd = proc.stdout.fileno()

# Identity registry. Processes are identified by (pid, start ticks) and by
# their process group: NEVER by name and never by an indiscriminate sweep.
registry = {"supervisor": {"pid": supervisor_pid, "ticks": None, "pgrp": None}, "children": {}}
last_refresh = [0.0]


def stat_fields(pid):
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii") as stream:
            raw = stream.read()
    except (OSError, ValueError):
        return None
    try:
        fields = raw[raw.rfind(")") + 2:].split()
        return {
            "state": fields[0],
            "ppid": int(fields[1]),
            "pgrp": int(fields[2]),
            "session": int(fields[3]),
            "ticks": fields[19],
        }
    except (IndexError, ValueError):
        return None


def alive(pid, ticks=None):
    info = stat_fields(pid)
    if info is None or info["state"] == "Z":
        return False
    return ticks is None or info["ticks"] == ticks


def group_members(pgid):
    members = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return members
    for entry in entries:
        if not entry.isdigit():
            continue
        info = stat_fields(int(entry))
        if info and info["state"] != "Z" and info["pgrp"] == pgid:
            members.append(int(entry))
    return members


def refresh_registry():
    """Record the identity of the supervisor and of what it spawned.

    The children are located by their PARENT relation to the supervisor whose
    own identity (pid + start ticks) was captured when it was launched. No
    name matching and no sweeping of unrelated processes.
    """
    now = time.monotonic()
    if now - last_refresh[0] < 0.5:
        return
    last_refresh[0] = now
    sup = stat_fields(supervisor_pid)
    if sup is not None:
        registry["supervisor"]["ticks"] = sup["ticks"]
        registry["supervisor"]["pgrp"] = sup["pgrp"]
    try:
        entries = os.listdir("/proc")
    except OSError:
        return
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        info = stat_fields(pid)
        if info is None or info["state"] == "Z":
            continue
        if info["ppid"] == supervisor_pid:
            registry["children"][pid] = {
                "pid": pid,
                "pgrp": info["pgrp"],
                "session": info["session"],
                "ticks": info["ticks"],
            }


def emit(text):
    sys.stdout.write("%.6f\t%s" % (time.monotonic(), text))
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# The whole execution is bounded by the guard: both the reads (the supervisor
# can block waiting for the authorization token) and the final wait are
# deadline aware.
# ---------------------------------------------------------------------------
buf = b""
expired = False
child_rc = None
while True:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        expired = True
        break
    refresh_registry()
    try:
        ready, _, _ = select.select([fd], [], [], min(remaining, 0.25))
    except (OSError, ValueError):
        break
    if not ready:
        continue
    try:
        chunk = os.read(fd, 65536)
    except OSError:
        chunk = b""
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        line, _, buf = buf.partition(b"\n")
        emit(line.decode("utf-8", "replace") + "\n")

refresh_registry()

if not expired:
    remaining = deadline - time.monotonic()
    try:
        child_rc = proc.wait(timeout=max(0.0, remaining))
    except subprocess.TimeoutExpired:
        expired = True

if not expired:
    end = time.monotonic()
    sys.stderr.write(
        "WRAPPER_MONO_START=%.6f\nWRAPPER_MONO_END=%.6f\nWRAPPER_CHILD_RC=%d\n"
        "WRAPPER_GUARD_EXPIRED=0\nWRAPPER_SURVIVORS=0\n"
        % (start, end, child_rc)
    )
    sys.exit(child_rc if child_rc is not None else 3)

# ---------------------------------------------------------------------------
# The guard expired: bounded exit and cleanup of EVERY own resource, by
# identity. The cleanup does not depend on the code under test.
# ---------------------------------------------------------------------------
actions = []
refresh_registry()
sup_pgrp = registry["supervisor"]["pgrp"]

# Fault injection of THIS interface (test only): it makes the cleanup
# deliberately incomplete so the "guard expired with survivors" branch can be
# exercised safely. The resources it leaves are ONLY the ones this interface
# launched, they are removed by the mandatory recovery pass below, and no
# foreign process is ever touched.
INJECT_INCOMPLETE_CLEANUP = os.environ.get("FORGE_V2_TEST_GUARD_CLEANUP_FAIL") == "1"


def kill_child_groups():
    """Tear down the groups of the processes the supervisor spawned."""
    done = []
    for pid, child in sorted(registry["children"].items()):
        pgid = child["pgrp"]
        if not pgid or pgid <= 1:
            continue
        if sup_pgrp is not None and pgid == sup_pgrp:
            # That group also contains this wrapper: it is never signalled.
            done.append("grupo %d compartido con el wrapper: no se señala (kill por pid)" % pgid)
            continue
        members = group_members(pgid)
        if not members:
            continue
        try:
            os.killpg(pgid, signal.SIGKILL)
            done.append("killpg SIGKILL del grupo propio pgid=%d (miembros: %s)" % (pgid, members))
        except OSError as exc:
            done.append("killpg pgid=%d omitido: %s" % (pgid, exc))
    return done


def kill_supervisor():
    """Kill the supervisor by identity only (its group is the wrapper's)."""
    done = []
    if proc.poll() is not None:
        return done
    sup = stat_fields(supervisor_pid)
    expected = registry["supervisor"]["ticks"]
    if sup is not None and (expected is None or sup["ticks"] == expected):
        try:
            os.kill(supervisor_pid, signal.SIGKILL)
            done.append("kill SIGKILL del supervisor verificado pid=%d" % supervisor_pid)
        except OSError as exc:
            done.append("kill del supervisor omitido: %s" % exc)
    else:
        done.append("el supervisor ya no existe o su identidad no coincide: no se señala")
    return done


if INJECT_INCOMPLETE_CLEANUP:
    actions.append(
        "inyeccion de fallo (FORGE_V2_TEST_GUARD_CLEANUP_FAIL=1): la limpieza se omite a proposito"
    )
else:
    # 1) The processes the supervisor spawned run in their own session (the
    #    launcher uses start_new_session). Killing THEIR group tears down the
    #    namespace init, and the kernel takes the rest of the namespace with it.
    actions.extend(kill_child_groups())

    # 2) Grace: the supervisor notices the death of the namespace init and
    #    applies its own cleanup chain (it also writes its report).
    grace_deadline = time.monotonic() + grace
    while time.monotonic() < grace_deadline:
        if proc.poll() is not None:
            break
        time.sleep(0.1)
    child_rc = proc.poll()

    # 3) The supervisor itself, by identity only. Its process group is the
    #    wrapper's group, so it is NEVER killed by group.
    if proc.poll() is None:
        actions.extend(kill_supervisor())
        try:
            child_rc = proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            child_rc = None
            actions.append("el supervisor no terminó tras el kill")

# 4) Detection of the survivors, by identity.
survivors = []
for pid, child in sorted(registry["children"].items()):
    if alive(pid, child["ticks"]):
        survivors.append({"kind": "child", "pid": pid, "pgrp": child["pgrp"]})
    pgid = child["pgrp"]
    if pgid and pgid > 1 and (sup_pgrp is None or pgid != sup_pgrp) and group_members(pgid):
        survivors.append({"kind": "group", "pgid": pgid, "members": group_members(pgid)})
if alive(supervisor_pid, registry["supervisor"]["ticks"]):
    survivors.append({"kind": "supervisor", "pid": supervisor_pid})

# 5) Mandatory recovery: the exercise of the incomplete-cleanup branch must
#    never leave a process of its own alive in the host. This pass runs
#    ALWAYS (also in the injected case) and is recorded apart from the
#    actions of the cleanup that was supposed to happen.
forced_recovery = []
if survivors:
    forced_recovery.extend(kill_child_groups())
    if proc.poll() is None:
        forced_recovery.extend(kill_supervisor())
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            forced_recovery.append("el supervisor no terminó tras el kill de recuperación")
    still = []
    for pid, child in sorted(registry["children"].items()):
        if alive(pid, child["ticks"]):
            still.append({"kind": "child", "pid": pid})
        pgid = child["pgrp"]
        if pgid and pgid > 1 and (sup_pgrp is None or pgid != sup_pgrp) and group_members(pgid):
            still.append({"kind": "group", "pgid": pgid})
    if alive(supervisor_pid, registry["supervisor"]["ticks"]):
        still.append({"kind": "supervisor", "pid": supervisor_pid})
    if still:
        forced_recovery.append("RECOVERY INCOMPLETA: %r" % (still,))
    else:
        forced_recovery.append("recuperacion forzada completa: 0 recursos propios vivos")

end = time.monotonic()
evidence = {
    "guard_seconds": guard,
    "grace_seconds": grace,
    "elapsed_seconds": round(end - start, 3),
    "expired": True,
    "child_rc": child_rc,
    "registry": registry,
    "cleanup_actions": actions,
    "survivors": survivors,
    "forced_recovery": forced_recovery,
    "fault_injection": INJECT_INCOMPLETE_CLEANUP,
}
if evidence_path:
    try:
        with open(evidence_path, "w", encoding="utf-8") as stream:
            json.dump(evidence, stream, indent=2, sort_keys=True)
            stream.write("\n")
    except OSError as exc:
        sys.stderr.write("no se pudo escribir la evidencia del guard: %s\n" % exc)
for line in actions:
    sys.stderr.write("GUARD %s\n" % line)
sys.stderr.write(
    "WRAPPER_MONO_START=%.6f\nWRAPPER_MONO_END=%.6f\nWRAPPER_CHILD_RC=%d\n"
    "WRAPPER_GUARD_EXPIRED=1\nWRAPPER_SURVIVORS=%d\n"
    % (start, end, child_rc if child_rc is not None else -1, len(survivors))
)
sys.exit(EXIT_GUARD_CLEANUP_INCOMPLETE if survivors else EXIT_GUARD_EXPIRED)
PY
  SUPERVISOR_RC=$?
  set -e
}

echo "=== escenario: $SCENARIO ==="
echo "evidencia: $EVIDENCE_DIR"

T_START="$(python3 -c 'import time;print("%.6f"%time.monotonic())')"
run_supervisor
T_END="$(python3 -c 'import time;print("%.6f"%time.monotonic())')"

echo "supervisor RC: $SUPERVISOR_RC"

# A scenario must never leave a process of its own behind. Any process still
# carrying this scenario's report path is waited for (never signalled): the
# supervisor completes by itself.
LEFTOVER_WAIT=0
while [ "$LEFTOVER_WAIT" -lt "$SCENARIO_GUARD" ]; do
  if ! pgrep -f -- "--report-path $REPORT" >/dev/null 2>&1; then
    break
  fi
  sleep 1
  LEFTOVER_WAIT=$((LEFTOVER_WAIT + 1))
done
if pgrep -f -- "--report-path $REPORT" >/dev/null 2>&1; then
  echo "FALLO: queda un proceso propio del escenario tras ${LEFTOVER_WAIT}s" >&2
  exit 14
fi

# ---------------------------------------------------------------------------
# The temporal guard expired. The scenario did NOT complete: there is no
# semantic verdict to issue. What is checked here is the OTHER half of the
# contract of an expired guard: a bounded exit and an ACCREDITED cleanup of
# every own resource, verified independently of the wrapper.
# ---------------------------------------------------------------------------
if [ "$SUPERVISOR_RC" -eq 14 ] || [ "$SUPERVISOR_RC" -eq 15 ]; then
  echo "guard de vivacidad VENCIDO: el escenario no completo su plazo (plazo ${SCENARIO_GUARD}s)"
  set +e
  python3 - "$EVIDENCE_DIR" "$SUPERVISOR_RC" "$SCENARIO_GUARD" "$T_START" "$T_END" <<'PY'
import json
import os
import pathlib
import sys

evidence_dir = pathlib.Path(sys.argv[1])
wrapper_rc = int(sys.argv[2])
guard = float(sys.argv[3])
t_start = float(sys.argv[4])
t_end = float(sys.argv[5])

problems = []
path = evidence_dir / "guard-expiry.json"
evidence = None
if not path.is_file():
    problems.append("falta la evidencia del guard vencido (%s)" % path)
else:
    try:
        evidence = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        problems.append("evidencia del guard ilegible: %s" % exc)


def stat_fields(pid):
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii") as stream:
            raw = stream.read()
    except (OSError, ValueError):
        return None
    try:
        fields = raw[raw.rfind(")") + 2:].split()
        return {"state": fields[0], "pgrp": int(fields[2]), "ticks": fields[19]}
    except (IndexError, ValueError):
        return None


def alive(pid, ticks=None):
    info = stat_fields(pid)
    if info is None or info["state"] == "Z":
        return False
    return ticks is None or info["ticks"] == ticks


def group_members(pgid):
    members = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return members
    for entry in entries:
        if not entry.isdigit():
            continue
        info = stat_fields(int(entry))
        if info and info["state"] != "Z" and info["pgrp"] == pgid:
            members.append(int(entry))
    return members


if evidence is not None:
    if evidence.get("expired") is not True:
        problems.append("la evidencia no declara la expiracion del guard")
    # The survivors DETECTED at verdict time are the criterion: the cleanup
    # was incomplete if any own resource survived that moment. The state NOW
    # is checked separately (a forced recovery may have removed them after the
    # detection, but that does not make the cleanup complete).
    detected = evidence.get("survivors") or []
    if detected:
        problems.append(
            "la limpieza quedo incompleta: %d recurso(s) propio(s) sobrevivieron al vencimiento: %r"
            % (len(detected), detected)
        )
    elapsed = evidence.get("elapsed_seconds")
    if elapsed is None or elapsed > guard + 30:
        problems.append("el plazo del guard no fue acotado (elapsed=%r guard=%r)" % (elapsed, guard))
    # Independent verification of the cleanup, by identity.
    registry = evidence.get("registry") or {}
    supervisor = registry.get("supervisor") or {}
    sup_pid = supervisor.get("pid")
    if sup_pid and alive(sup_pid, supervisor.get("ticks")):
        problems.append("el supervisor sigue vivo: pid=%s" % sup_pid)
    for pid, child in sorted((registry.get("children") or {}).items()):
        if alive(int(pid), child.get("ticks")):
            problems.append("un proceso propio sigue vivo: pid=%s" % pid)
        pgid = child.get("pgrp")
        if pgid and pgid > 1 and group_members(pgid):
            problems.append("quedan miembros del grupo propio %s: %r" % (pgid, group_members(pgid)))

result = {
    "guard_expired": True,
    "wrapper_rc": wrapper_rc,
    "guard_seconds": guard,
    "wall_seconds": round(t_end - t_start, 3),
    "elapsed_seconds": (evidence or {}).get("elapsed_seconds"),
    "child_rc": (evidence or {}).get("child_rc"),
    "cleanup_actions": (evidence or {}).get("cleanup_actions", []),
    "survivors": (evidence or {}).get("survivors", []),
    "forced_recovery": (evidence or {}).get("forced_recovery", []),
    "fault_injection": (evidence or {}).get("fault_injection", False),
    "problems": problems,
    "ok": not problems,
}
out = evidence_dir / "guard-verdict.json"
out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

for line in result["cleanup_actions"]:
    print("  ACCION: %s" % line)
for line in result["forced_recovery"]:
    print("  RECUPERACION: %s" % line)
print(
    "  guard vencido: plazo=%ss transcurrido=%ss rc_hijo=%s supervivientes_detectados=%d problemas=%d"
    % (
        result["guard_seconds"],
        result["elapsed_seconds"],
        result["child_rc"],
        len(result["survivors"]),
        len(problems),
    )
)
for problem in problems:
    print("  FAIL: %s" % problem)
sys.exit(0 if not problems else 1)
PY
  GUARD_RC=$?
  set -e
  rm -rf "$WORK"
  if [ "$GUARD_RC" -eq 0 ]; then
    echo "veredicto del guard: vencido con limpieza acreditada (0 supervivientes)"
    exit 14
  fi
  echo "veredicto del guard: vencido con limpieza INCOMPLETA" >&2
  exit 15
fi

# The work dir holds only the transient synthetic root of the batch, which the
# supervisor removes; anything left would be a residue of this scenario.
rm -rf "$WORK"

# ---------------------------------------------------------------------------
# Semantic verdict of the scenario.
# ---------------------------------------------------------------------------
set +e
python3 - \
  "$SCENARIO" "$EVIDENCE_DIR" "$SUPERVISOR_RC" "$HANG_TIMEOUT" "$T_START" "$T_END" \
  <<'PY'
import json
import os
import pathlib
import sys

scenario, evidence_dir, supervisor_rc, hang_timeout, t_start, t_end = sys.argv[1:7]
evidence_dir = pathlib.Path(evidence_dir)
supervisor_rc = int(supervisor_rc)
hang_timeout = float(hang_timeout)
t_start = float(t_start)
t_end = float(t_end)

checks = []


def check(name, ok, detail):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)})
    return bool(ok)


def load_report():
    path = evidence_dir / "safety-results.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


report = load_report()
stdout_lines = []
tsv = evidence_dir / "supervisor.stdout.tsv"
if tsv.is_file():
    for raw in tsv.read_text(encoding="utf-8", errors="replace").splitlines():
        stamp, _, text = raw.partition("\t")
        try:
            stdout_lines.append((float(stamp), text))
        except ValueError:
            stdout_lines.append((None, raw))
stderr_text = ""
stderr_path = evidence_dir / "supervisor.stderr"
if stderr_path.is_file():
    stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace")

mono_start = None
mono_end = None
for raw in stderr_text.splitlines():
    if raw.startswith("WRAPPER_MONO_START="):
        mono_start = float(raw.split("=", 1)[1])
    elif raw.startswith("WRAPPER_MONO_END="):
        mono_end = float(raw.split("=", 1)[1])

# Timestamped events of interest.
def first_stamp(needle):
    for stamp, text in stdout_lines:
        if needle in text:
            return stamp
    return None


def stamps_of(needle):
    return [stamp for stamp, text in stdout_lines if needle in text and stamp is not None]


injection_stamps = stamps_of("[inyeccion] hijo sintetico creado")
launcher_stamps = stamps_of("launcher(host)=")
cleanup_stamps = stamps_of("[supervisor] limpieza OK")

starts_namespace = len(launcher_stamps)
children_injected = len(injection_stamps)

# ---------------------------------------------------------------------------
# Evidence completeness (all scenarios).
# ---------------------------------------------------------------------------
if not check(
    "informe presente y legible",
    report is not None,
    "safety-results.json presente y parseable" if report else "safety-results.json ausente o ilegible",
):
    verdict = {
        "scenario": scenario,
        "ok": False,
        "exit_code": 12,
        "supervisor_rc": supervisor_rc,
        "suite_rc": None,
        "checks": checks,
    }
    (evidence_dir / "verdict.json").write_text(
        json.dumps(verdict, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    sys.exit(12)

cleanup = report.get("cleanup") or {}
supervisor_section = report.get("supervisor") or {}
summary = report.get("summary") or {}
cases = report.get("cases") or []
suite_rc = cleanup.get("suite_returncode")

# The layers are distinguished: the supervisor RC comes from the process, the
# suite RC from the report written by the supervisor after reading it back.
expected_supervisor_rc = {"normal": 0, "no-pidfd": 6, "no-pidfd-hang": 6}[scenario]
expected_suite_rc = {"normal": 0, "no-pidfd": 4, "no-pidfd-hang": None}[scenario]

check(
    "RC de la capa supervisor",
    supervisor_rc == expected_supervisor_rc,
    "rc=%d (esperado %d)" % (supervisor_rc, expected_supervisor_rc),
)
if expected_suite_rc is not None:
    check(
        "RC de la capa suite",
        suite_rc == expected_suite_rc,
        "cleanup.suite_returncode=%r (esperado %d)" % (suite_rc, expected_suite_rc),
    )

# ---------------------------------------------------------------------------
# Cleanup and no survivors (all scenarios). The supervisor's own verdict is
# not enough: the identities it registered are re-checked against /proc.
# ---------------------------------------------------------------------------
check(
    "limpieza acreditada por el supervisor",
    cleanup.get("ok") is True,
    "cleanup.ok=%r" % cleanup.get("ok"),
)
check(
    "sin supervivientes en el namespace privado",
    cleanup.get("survivors_in_private_namespace") == [],
    "survivors_in_private_namespace=%r" % cleanup.get("survivors_in_private_namespace"),
)
check(
    "sin miembros del grupo propio del lote",
    cleanup.get("members_of_own_process_group") == [],
    "members_of_own_process_group=%r" % cleanup.get("members_of_own_process_group"),
)
check(
    "init del namespace eliminado",
    cleanup.get("namespace_init_alive_after") is False
    and cleanup.get("namespace_init_gone_after") is True,
    "alive_after=%r gone_after=%r"
    % (cleanup.get("namespace_init_alive_after"), cleanup.get("namespace_init_gone_after")),
)
check(
    "raiz sintetica eliminada",
    cleanup.get("synthetic_root_present_after") is False,
    "synthetic_root_present_after=%r" % cleanup.get("synthetic_root_present_after"),
)

survivor_ids = []
for item in cleanup.get("resources") or []:
    pid = item.get("pid")
    if pid is None:
        continue
    identity = item.get("identity") or {}
    proc = pathlib.Path("/proc") / str(pid)
    alive = False
    try:
        raw = (proc / "stat").read_text(encoding="ascii")
        fields = raw[raw.rfind(")") + 1 :].split()
        expected_ticks = identity.get("start_time_ticks")
        alive = expected_ticks is None or len(fields) <= 19 or fields[19] == str(expected_ticks)
    except (OSError, ValueError, IndexError):
        alive = False
    if alive:
        survivor_ids.append("%s(pid=%s)" % (item.get("id", "?"), pid))
check(
    "ninguna identidad propia registrada sigue viva en /proc",
    not survivor_ids,
    "supervivientes=%r" % (survivor_ids or []),
)

private_ns = cleanup.get("private_pid_namespace")
ns_survivors = []
if private_ns:
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
                continue
            ns_survivors.append(int(entry))
        except (OSError, ValueError, IndexError):
            continue
check(
    "ningun proceso vivo pertenece al namespace privado del lote",
    not ns_survivors,
    "ns_survivors=%r" % (ns_survivors or []),
)

# ---------------------------------------------------------------------------
# Scenario semantics.
# ---------------------------------------------------------------------------
case_ids = [case.get("id") for case in cases]
case_by_id = {case.get("id"): case for case in cases}
stdout_text = "\n".join(text for _, text in stdout_lines)

if scenario == "normal":
    check(
        "watchdog pidfd operativo",
        cleanup.get("watchdog_operational") is True,
        "cleanup.watchdog_operational=%r" % cleanup.get("watchdog_operational"),
    )
    check(
        "autorizacion concedida",
        cleanup.get("authorization_granted") is True,
        "cleanup.authorization_granted=%r" % cleanup.get("authorization_granted"),
    )
    check(
        "sin timeout",
        cleanup.get("timed_out") is False,
        "cleanup.timed_out=%r" % cleanup.get("timed_out"),
    )
    check(
        "todos los casos sensibles se ejecutaron y pasaron",
        summary.get("total") == 52 and summary.get("failed") == 0 and summary.get("passed") == 52,
        "summary=%r" % summary,
    )
    check(
        "hubo ejecucion sensible (no solo PRE-*)",
        len([cid for cid in case_ids if cid not in ("PRE-1", "PRE-2")]) >= 50,
        "casos=%d no-PRE=%d" % (len(case_ids), len([c for c in case_ids if c not in ("PRE-1", "PRE-2")])),
    )
    check(
        "la suite resumen su ejecucion",
        "[resumen]" in stdout_text,
        "resumen presente en la salida del supervisor",
    )

elif scenario == "no-pidfd":
    check(
        "watchdog NO operativo (inyeccion de fallo)",
        cleanup.get("watchdog_operational") is False,
        "cleanup.watchdog_operational=%r" % cleanup.get("watchdog_operational"),
    )
    check(
        "autorizacion DENEGADA",
        cleanup.get("authorization_granted") is False,
        "cleanup.authorization_granted=%r" % cleanup.get("authorization_granted"),
    )
    check(
        "sin timeout (el rechazo es inmediato, no un bloqueo)",
        cleanup.get("timed_out") is False,
        "cleanup.timed_out=%r" % cleanup.get("timed_out"),
    )
    check(
        "el informe solo contiene los casos previos a la barrera",
        set(case_ids) == {"PRE-1", "PRE-2"},
        "casos=%r" % (case_ids or []),
    )
    pre2 = case_by_id.get("PRE-2") or {}
    check(
        "PRE-2 falla con BLOCKED explicito",
        pre2.get("status") == "FAIL" and "BLOCKED" in (pre2.get("detail") or ""),
        "PRE-2=%r" % pre2,
    )
    check(
        "ningun caso sensible se ejecuto",
        not [cid for cid in case_ids if cid not in ("PRE-1", "PRE-2")],
        "casos=%r" % (case_ids or []),
    )
    check(
        "la suite no llego a ejecutar casos (sin resumen)",
        "[resumen]" not in stdout_text,
        "resumen ausente en la salida del supervisor",
    )
    check(
        "no se inyecto el bloqueo en este escenario",
        not injection_stamps,
        "lineas de inyeccion=%d" % len(injection_stamps),
    )
    check(
        "el supervisor registro el rechazo del watchdog y de la barrera",
        "watchdog FAIL" in stdout_text and "barrera FAIL" in stdout_text and "BLOCKED:" in stdout_text,
        "traza del supervisor con watchdog FAIL / barrera FAIL / BLOCKED",
    )

elif scenario == "no-pidfd-hang":
    check(
        "watchdog NO operativo (inyeccion de fallo)",
        cleanup.get("watchdog_operational") is False,
        "cleanup.watchdog_operational=%r" % cleanup.get("watchdog_operational"),
    )
    check(
        "TIMEOUT real confirmado",
        cleanup.get("timed_out") is True,
        "cleanup.timed_out=%r" % cleanup.get("timed_out"),
    )
    check(
        "la suite NO termino con exito (la cadena de limpieza la elimino)",
        suite_rc is not None and suite_rc != 0,
        "cleanup.suite_returncode=%r" % suite_rc,
    )
    check(
        "ningun caso sensible se ejecuto (la suite se colgo antes de la barrera)",
        not cases,
        "casos=%r" % (case_ids or []),
    )
    check(
        "el hijo sintetico se creo antes de vencer el plazo",
        len(injection_stamps) == 1,
        "eventos de inyeccion=%d" % len(injection_stamps),
    )
    if injection_stamps and cleanup_stamps:
        elapsed = cleanup_stamps[0] - injection_stamps[0]
        check(
            "el hijo existio durante el presupuesto completo antes de la limpieza",
            elapsed >= hang_timeout - 1.0,
            "inyeccion->limpieza=%.3fs (presupuesto=%ss, tolerancia=1s)" % (elapsed, hang_timeout),
        )
    else:
        check(
            "el hijo existio durante el presupuesto completo antes de la limpieza",
            False,
            "no se pudieron obtener las marcas de inyeccion y de limpieza",
        )
    actions = " | ".join(cleanup.get("cleanup_actions") or [])
    check(
        "la limpieza exterior funciono SIN pidfd",
        "kill verificado del init" in actions and "killpg verificado" in actions,
        "cleanup_actions=%r" % actions,
    )
    check(
        "la cadena no uso el pidfd (deshabilitado a proposito)",
        "pidfd SIGKILL" not in actions,
        "cleanup_actions=%r" % actions,
    )
    check(
        "el descendiente sintetico murio con el namespace",
        cleanup.get("survivors_in_private_namespace") == []
        and cleanup.get("members_of_own_process_group") == [],
        "survivors=%r members=%r"
        % (
            cleanup.get("survivors_in_private_namespace"),
            cleanup.get("members_of_own_process_group"),
        ),
    )
    check(
        "el supervisor registro el timeout en su traza",
        "timeout=True" in stdout_text,
        "traza del supervisor con timeout=True",
    )

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
timings = {
    "monotonic_wall_total_s": round(t_end - t_start, 3),
    "monotonic_wrapper_total_s": (
        round(mono_end - mono_start, 3) if mono_start is not None and mono_end is not None else None
    ),
    "monotonic_to_first_line_s": (
        round(stdout_lines[0][0] - mono_start, 3)
        if stdout_lines and stdout_lines[0][0] is not None and mono_start is not None
        else None
    ),
    "hang_timeout_s": hang_timeout,
    "arranques_namespace": starts_namespace,
    "hijos_inyectados": children_injected,
}

failed = [item for item in checks if not item["ok"]]
if failed:
    exit_code = 12 if any(item["name"].startswith("informe") for item in failed) else 11
else:
    exit_code = 0

verdict = {
    "scenario": scenario,
    "ok": not failed,
    "exit_code": exit_code,
    "supervisor_rc": supervisor_rc,
    "suite_rc": suite_rc,
    "expected_supervisor_rc": expected_supervisor_rc,
    "expected_suite_rc": expected_suite_rc,
    "checks_total": len(checks),
    "checks_failed": len(failed),
    "checks": checks,
    "timings": timings,
    "case_ids": case_ids,
}
(evidence_dir / "verdict.json").write_text(
    json.dumps(verdict, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)

lines = []
lines.append("# Veredicto del escenario `%s`" % scenario)
lines.append("")
lines.append("- Escenario: `%s`" % scenario)
lines.append("- RC supervisor: **%d** (esperado %d)" % (supervisor_rc, expected_supervisor_rc))
lines.append(
    "- RC suite: **%s** (esperado %s)"
    % (suite_rc, expected_suite_rc if expected_suite_rc is not None else "no aplica (eliminada por la cadena)")
)
lines.append("- Comprobaciones: %d, fallidas: %d" % (len(checks), len(failed)))
lines.append("- Veredicto: **%s** (exit %d)" % ("OK" if not failed else "FALLO", exit_code))
lines.append("")
lines.append("## Tiempos monotónicos y arranques")
lines.append("")
for key, value in sorted(timings.items()):
    lines.append("- `%s`: %s" % (key, value))
lines.append("")
lines.append("## Comprobaciones semánticas")
lines.append("")
for item in checks:
    lines.append("- %s `%s` — %s" % ("PASS" if item["ok"] else "FAIL", item["name"], item["detail"]))
lines.append("")
(evidence_dir / "verdict.md").write_text("\n".join(lines), encoding="utf-8")

for item in checks:
    print("  %s: %s — %s" % ("PASS" if item["ok"] else "FAIL", item["name"], item["detail"]))
print(
    "escenario %s: supervisor_rc=%s suite_rc=%s comprobaciones=%d fallidas=%d exit=%d"
    % (scenario, supervisor_rc, suite_rc, len(checks), len(failed), exit_code)
)

sys.exit(exit_code)
PY
VERDICT_RC=$?
set -e

echo "veredicto: $EVIDENCE_DIR/verdict.json y $EVIDENCE_DIR/verdict.md"
exit "$VERDICT_RC"
