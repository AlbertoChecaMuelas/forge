#!/usr/bin/env bash
# Autonomous global verifier for forge-v2-followups Step 4.1.
set -euo pipefail
umask 077

REPO=/home/espinilleitor/repos/own/forge
EXTERNAL=/home/espinilleitor/forge-v2-cutover-20261024
PREVIOUS_EVIDENCE=/tmp/opencode/forge-v2-followups
BASE=/tmp/opencode/forge-v2-coverage-closure-20261025
RUNS="$BASE/runs"
BACKUP=/tmp/opencode/forge-v2-remediation/backup
CHECKPOINT=/tmp/opencode/forge-v2-followups-checkpoint/checkpoint.commit
EXTERNAL_BACKUP=/tmp/opencode/forge-v2-followups-checkpoint/external
SYNTHETIC=/tmp/opencode/forge-v2-remediation/sandbox/step-4.1-synthetic
CHECKPOINT_DIR="${FORGE_V2_CLOSURE_CHECKPOINT:-}"
FORGE_V2_EXTERNAL_ROOT="${FORGE_V2_EXTERNAL_ROOT:-$EXTERNAL}"
FORGE_V2_REAL_DB="${FORGE_V2_REAL_DB:-$HOME/.local/share/opencode/opencode.db}"
FORGE_V2_HANG_TIMEOUT="${FORGE_V2_HANG_TIMEOUT:-20}"
# The interface's own temporal guard (420s by default) and this verifier's
# outer watchdog are independent layers. The verifier must never shorten the
# interface's cleanup window; only the explicit guard-expiry probe overrides
# the interface guard to exercise its hard-failure path.
FORGE_V2_SCENARIO_GUARD="${FORGE_V2_SCENARIO_GUARD:-420}"
FORGE_V2_OUTER_SCENARIO_GUARD="${FORGE_V2_OUTER_SCENARIO_GUARD:-600}"
FORGE_V2_GUARD_EXPIRY_PROBE="${FORGE_V2_GUARD_EXPIRY_PROBE:-0}"
# Narrow opt-in branch probe for validating exceptional cleanup behavior.
FORGE_V2_CLEANUP_BRANCH_PROBE="${FORGE_V2_CLEANUP_BRANCH_PROBE:-}"
# The supervisor's internal timeout is 300s after preparation/authorization.
# Keep the outer liveness guard at 600s so it cannot pre-empt that timeout,
# with up to five extra minutes for bounded preparation and cleanup.
RESIDUAL_PID=530393
RESIDUAL_START_TICKS=26522468
RESIDUAL_BOOT_ID=3df94600-d3e9-4486-879b-452396bca532
RESIDUAL_UID=1000
RESIDUAL_EXE='/tmp/opencode/cutover-lab/xdg/data/forge/opencode-v2/node_modules/@opencode/cli/bin/opencode.exe (deleted)'
RESIDUAL_CMDLINE=(
  '/tmp/opencode/cutover-lab/xdg/data/forge/opencode-v2/node_modules/.bin/opencode'
  serve --hostname 127.0.0.1 --port 34765 --print-logs
)

test -d "$BASE"
test ! -L "$BASE"
test "$(stat -c '%u' "$BASE")" = "$(id -u)"
test "$(stat -c '%a' "$BASE")" = 700
test -d "$RUNS"
test ! -L "$RUNS"
test "$(stat -c '%u' "$RUNS")" = "$(id -u)"
test "$(stat -c '%a' "$RUNS")" = 700
RUN_ID="$(date -u +%Y%m%dT%H%M%S.%N)-$$"
RUN_DIR="$RUNS/$RUN_ID"
mkdir -m 700 "$RUN_DIR"
test "$(stat -c '%u' "$RUN_DIR")" = "$(id -u)"
test "$(stat -c '%a' "$RUN_DIR")" = 700
RUN_LOG="$RUN_DIR/forge-v2-followups-global.log"
SAFETY_LOG="$RUN_DIR/forge-v2-safety-scenarios.log"
GUARD_LOG="$RUN_DIR/forge-guard-step-4.1.log"
GUARD_OPS_LOG="$RUN_DIR/forge-guard-git-ops-step-4.1.log"
GUARD_SUMMARY="$RUN_DIR/forge-guard-summary.json"
SYNTAX_CATALOG="$RUN_DIR/forge-v2-syntax-catalog.json"
PREPARE_EVIDENCE="$RUN_DIR/prepare-sandbox-step-4.1.json"
SCENARIO_RC_FILE="$RUN_DIR/scenario-runner-rc.tsv"
SCENARIO_TIMINGS="$RUN_DIR/scenario-timings.tsv"
OWN_GROUP_LOG="$RUN_DIR/own-process-groups.tsv"
SCENARIO_SUMMARY="$RUN_DIR/summary.md"
EXCEPTIONAL_CLEANUP_LOG="$RUN_DIR/exceptional-cleanup.tsv"
ACTIVE_SCENARIO_PID=
ACTIVE_SCENARIO_LAUNCH_PID=
ACTIVE_SCENARIO_LAUNCH_START=
ACTIVE_SCENARIO_PGID=
ACTIVE_SCENARIO_SID=
ACTIVE_SCENARIO_START=
ACTIVE_SCENARIO_OUTER_START=
ACTIVE_SCENARIO_OUTER_REGISTERED=0
ACTIVE_SCENARIO_DIR=
ACTIVE_SCENARIO_REPORT=
ACTIVE_SCENARIO_INNER_PID=
ACTIVE_SCENARIO_SUITE_PID=
ACTIVE_SCENARIO_INNER_PGID=
ACTIVE_SCENARIO_INNER_SID=
ACTIVE_SCENARIO_INNER_START=
ACTIVE_SCENARIO_SUITE_START=
ACTIVE_SCENARIO_INNER_REGISTERED_AT=
ACTIVE_SCENARIO_SUPERVISOR_PID=
ACTIVE_SCENARIO_SUPERVISOR_START=
ACTIVE_SCENARIO_EXCEPTION_STATUS=not-applicable
SCENARIO_FAILURE=0
PID_FINAL_OK=0

mono_now() {
  local uptime rest
  read -r uptime rest < /proc/uptime || return 1
  printf '%s' "$uptime"
}

read_proc_fields() {
  local pid="$1" raw rest
  IFS= read -r raw 2>/dev/null <"/proc/$pid/stat" || return 1
  rest="${raw##*) }"
  read -r -a PROC_FIELDS <<< "$rest"
  ((${#PROC_FIELDS[@]} > 19))
}

check_residual_pid() {
  local phase="$1" evidence="$2" state start boot uid exe listen_inodes inode target fd
  local cmdline_joined expected_joined socket_found=0
  local -a current_cmdline=()
  if ! read_proc_fields "$RESIDUAL_PID"; then
    printf 'FAIL PID %s: /proc identity unavailable at %s\n' "$RESIDUAL_PID" "$phase"
    return 1
  fi
  state="${PROC_FIELDS[0]}"
  start="${PROC_FIELDS[19]}"
  boot="$(< /proc/sys/kernel/random/boot_id)" || return 1
  uid="$(awk '$1 == "Uid:" { print $2; exit }' "/proc/$RESIDUAL_PID/status")" || return 1
  exe="$(readlink "/proc/$RESIDUAL_PID/exe")" || return 1
  mapfile -d '' -t current_cmdline < "/proc/$RESIDUAL_PID/cmdline" || return 1
  cmdline_joined="$(IFS=$'\037'; printf '%s' "${current_cmdline[*]}")"
  expected_joined="$(IFS=$'\037'; printf '%s' "${RESIDUAL_CMDLINE[*]}")"
  if [[ "$state" == Z || "$state" == X || "$start" != "$RESIDUAL_START_TICKS" || "$boot" != "$RESIDUAL_BOOT_ID" || "$uid" != "$RESIDUAL_UID" || "$exe" != "$RESIDUAL_EXE" || "$cmdline_joined" != "$expected_joined" ]]; then
    printf 'FAIL PID %s: identidad/estado inesperado en %s (state=%s start=%s uid=%s exe=%q cmdline=%q)\n' \
      "$RESIDUAL_PID" "$phase" "$state" "$start" "$uid" "$exe" "$cmdline_joined"
    return 1
  fi
  listen_inodes="$(awk 'NR > 1 && $2 == "0100007F:87CD" && $4 == "0A" { print $10 }' /proc/net/tcp)" || return 1
  [[ -n "$listen_inodes" ]] || {
    printf 'FAIL PID %s: no LISTEN local 127.0.0.1:34765 en %s\n' "$RESIDUAL_PID" "$phase"
    return 1
  }
  for inode in $listen_inodes; do
    for fd in /proc/"$RESIDUAL_PID"/fd/*; do
      target="$(readlink "$fd")" || return 1
      if [[ "$target" == "socket:[$inode]" ]]; then
        socket_found=1
        break 2
      fi
    done
  done
  if ((socket_found == 0)); then
    printf 'FAIL PID %s: LISTEN 34765 no está vinculado a un FD del proceso en %s\n' "$RESIDUAL_PID" "$phase"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$RESIDUAL_PID" "$start" "$boot" "$uid" "$state" "$exe" "$cmdline_joined" > "$evidence"
  printf 'PASS PID %s: state=%s start_ticks=%s exe=%q socket=127.0.0.1:34765 (%s) en %s\n' \
    "$RESIDUAL_PID" "$state" "$start" "$exe" "$inode" "$phase"
}

group_members() {
  local wanted_pgid="$1" wanted_sid="$2" path pid raw rest
  local -a fields=()
  GROUP_MEMBERS=()
  for path in /proc/[0-9]*/stat; do
    [[ -r "$path" ]] || continue
    pid="${path#/proc/}"
    pid="${pid%/stat}"
    raw="$(<"$path")" 2>/dev/null || continue
    rest="${raw##*) }"
    read -r -a fields <<< "$rest"
    ((${#fields[@]} > 3)) || continue
    if [[ "${fields[2]}" == "$wanted_pgid" && "${fields[3]}" == "$wanted_sid" && "${fields[0]}" != Z && "${fields[0]}" != X ]]; then
      GROUP_MEMBERS+=("$pid")
    fi
  done
}


capture_inner_identity_from_log() {
  local line launcher init joined
  [[ -n "$ACTIVE_SCENARIO_DIR" && -s "$ACTIVE_SCENARIO_DIR/supervisor.stdout.tsv" ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" =~ launcher\(host\)=([0-9]+)[[:space:]]+init_del_namespace\(host\)=([0-9]+)[[:space:]]+pgrp=([0-9]+) ]]; then
      launcher="${BASH_REMATCH[1]}"
      init="${BASH_REMATCH[2]}"
      [[ "${BASH_REMATCH[3]}" == "$launcher" ]] || return 1
      ACTIVE_SCENARIO_INNER_PID="$launcher"
      ACTIVE_SCENARIO_INNER_PGID="$launcher"
      ACTIVE_SCENARIO_INNER_SID="$launcher"
      ACTIVE_SCENARIO_INNER_REGISTERED_AT="$(mono_now)"
      if read_proc_fields "$launcher" && [[ "${PROC_FIELDS[0]}" != Z && "${PROC_FIELDS[0]}" != X ]]; then
        [[ "${PROC_FIELDS[2]}" == "$launcher" && "${PROC_FIELDS[3]}" == "$launcher" ]] || return 1
        mapfile -d '' -t INNER_CMDLINE < "/proc/$launcher/cmdline" || return 1
        joined="$(IFS=$'\037'; printf '%s' "${INNER_CMDLINE[*]}")"
        [[ "$joined" == *"$ACTIVE_SCENARIO_REPORT"* && "$joined" == *"--role"* && "$joined" == *"suite"* ]] || return 1
        ACTIVE_SCENARIO_INNER_START="${PROC_FIELDS[19]}"
      fi
      if read_proc_fields "$init" && [[ "${PROC_FIELDS[0]}" != Z && "${PROC_FIELDS[0]}" != X ]]; then
        [[ "${PROC_FIELDS[2]}" == "$launcher" && "${PROC_FIELDS[3]}" == "$launcher" ]] || return 1
        ACTIVE_SCENARIO_SUITE_PID="$init"
        ACTIVE_SCENARIO_SUITE_START="${PROC_FIELDS[19]}"
      fi
      return 0
    fi
  done < "$ACTIVE_SCENARIO_DIR/supervisor.stdout.tsv"
  return 1
}

discover_inner_identities() {
  local identity_file
  identity_file="$RUN_DIR/$(basename "$ACTIVE_SCENARIO_DIR").outer-cleanup-identities.json"
  python3 - "$ACTIVE_SCENARIO_PID" "$ACTIVE_SCENARIO_REPORT" "$REPO/tests/forge_v2_safety_harness.py" "$identity_file" <<'PY'
import json
import os
import pathlib
import sys

root_pid, report_path, harness_path, output_path = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
processes = {}
for entry in os.listdir('/proc'):
    if not entry.isdigit():
        continue
    pid = int(entry)
    try:
        raw = pathlib.Path(f'/proc/{pid}/stat').read_text(encoding='ascii')
        fields = raw[raw.rfind(')') + 2:].split()
        argv = [part.decode('utf-8', 'replace') for part in pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0') if part]
        uid_line = next(line for line in pathlib.Path(f'/proc/{pid}/status').read_text().splitlines() if line.startswith('Uid:'))
        processes[pid] = {
            'pid': pid, 'state': fields[0], 'ppid': int(fields[1]), 'pgid': int(fields[2]),
            'sid': int(fields[3]), 'start_ticks': fields[19], 'argv': argv,
            'uid': int(uid_line.split()[1]), 'exe': os.readlink(f'/proc/{pid}/exe'),
        }
    except (OSError, ValueError, IndexError, StopIteration):
        continue
children = {}
for proc in processes.values():
    children.setdefault(proc['ppid'], []).append(proc['pid'])
descendants = set()
frontier = [root_pid]
while frontier:
    parent = frontier.pop()
    for child in children.get(parent, []):
        if child not in descendants:
            descendants.add(child)
            frontier.append(child)

def has_pair(argv, left, right):
    return any(argv[i:i + 2] == [left, right] for i in range(len(argv) - 1))

supervisors = []
for pid in descendants:
    proc = processes[pid]
    argv = proc['argv']
    if len(argv) > 1 and argv[1] == harness_path and has_pair(argv, '--role', 'supervisor') and has_pair(argv, '--report-path', report_path):
        supervisors.append(proc)
launchers = []
if len(supervisors) == 1:
    supervisor = supervisors[0]
    for pid in descendants:
        proc = processes[pid]
        argv = proc['argv']
        if (proc['ppid'] == supervisor['pid'] and proc['pid'] == proc['pgid'] == proc['sid']
                and report_path in argv and has_pair(argv, '--role', 'suite')):
            launchers.append(proc)
suites = []
if len(launchers) == 1:
    launcher = launchers[0]
    for pid in descendants:
        proc = processes[pid]
        argv = proc['argv']
        if (proc['ppid'] == launcher['pid'] and proc['pgid'] == launcher['pid'] and proc['sid'] == launcher['pid']
                and harness_path in argv and report_path in argv and has_pair(argv, '--role', 'suite')):
            suites.append(proc)
data = {
    'root': root_pid,
    'report_path': report_path,
    'supervisors': supervisors,
    'launchers': launchers,
    'suites': suites,
    'method': 'descendants of the registered scenario leader, matched by exact report path and harness argv',
}
path = pathlib.Path(output_path)
path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n', encoding='utf-8')
path.chmod(0o600)
if len(supervisors) > 1 or len(launchers) > 1:
    raise SystemExit(f'ambiguous owned identities: supervisors={len(supervisors)} launchers={len(launchers)}')
if supervisors:
    p = supervisors[0]
    print('supervisor\t%s\t%s\t%s\t%s' % (p['pid'], p['start_ticks'], p['pgid'], p['sid']))
if launchers:
    p = launchers[0]
    print('launcher\t%s\t%s\t%s\t%s' % (p['pid'], p['start_ticks'], p['pgid'], p['sid']))
if len(suites) == 1:
    p = suites[0]
    print('suite\t%s\t%s\t%s\t%s' % (p['pid'], p['start_ticks'], p['pgid'], p['sid']))
PY
}

process_identity_alive() {
  local pid="$1" expected_start="$2"
  [[ "$pid" =~ ^[0-9]+$ && "$expected_start" =~ ^[0-9]+$ ]] || return 1
  read_proc_fields "$pid" || return 1
  [[ "${PROC_FIELDS[19]}" == "$expected_start" && "${PROC_FIELDS[0]}" != Z && "${PROC_FIELDS[0]}" != X ]]
}

process_identity_present() {
  local pid="$1" expected_start="$2"
  [[ "$pid" =~ ^[0-9]+$ && "$expected_start" =~ ^[0-9]+$ ]] || return 1
  read_proc_fields "$pid" || return 1
  [[ "${PROC_FIELDS[19]}" == "$expected_start" ]]
}

validate_guard_expiry_evidence() {
  local scenario_dir="$1" runner_rc="$2"
  python3 - "$scenario_dir" "$runner_rc" "$FORGE_V2_SCENARIO_GUARD" <<'PY'
import json
import math
import os
import pathlib
import sys

scenario_dir = pathlib.Path(sys.argv[1])
runner_rc = int(sys.argv[2])
expected_guard = float(sys.argv[3])
expiry_path = scenario_dir / "guard-expiry.json"
verdict_path = scenario_dir / "guard-verdict.json"
result_path = scenario_dir / "guard-integration-verdict.json"
problems = []
checks = []


def check(name, ok, detail):
    checks.append({"name": name, "ok": bool(ok), "detail": str(detail)})
    if not ok:
        problems.append("%s: %s" % (name, detail))


def load_json(path, label):
    if path.is_symlink() or not path.is_file():
        check(label + " legible", False, "no es un fichero regular no enlazado")
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        check(label + " legible", False, repr(exc))
        return None
    check(label + " legible", isinstance(value, dict), "JSON objeto" if isinstance(value, dict) else "raíz JSON no es objeto")
    return value if isinstance(value, dict) else None


expiry = load_json(expiry_path, "guard-expiry.json")
verdict = load_json(verdict_path, "guard-verdict.json")
registered_pids = []
checked_groups = []
shared_groups = []

if expiry is not None:
    check("guard vencido", expiry.get("expired") is True, repr(expiry.get("expired")))
    survivors = expiry.get("survivors")
    if runner_rc == 14:
        check("guard-expiry RC 14 sin supervivientes", isinstance(survivors, list) and survivors == [], repr(survivors))
    else:
        kinds = {item.get("kind") for item in survivors if isinstance(item, dict)} if isinstance(survivors, list) else set()
        check("guard-expiry RC 15 registra los tres supervivientes inyectados",
              expiry.get("fault_injection") is True and len(survivors) == 3 and kinds == {"child", "group", "supervisor"},
              "survivors=%r kinds=%r" % (survivors, kinds))
        recovery = expiry.get("forced_recovery")
        recovered = isinstance(recovery, list) and any(
            "recuperacion forzada completa: 0 recursos propios vivos" in str(item) for item in recovery
        )
        check("guard-expiry RC 15 recuperación posterior completa", recovered, repr(recovery))
    elapsed = expiry.get("elapsed_seconds")
    evidence_guard = expiry.get("guard_seconds")
    valid_elapsed = isinstance(elapsed, (int, float)) and not isinstance(elapsed, bool) and math.isfinite(elapsed)
    valid_guard = isinstance(evidence_guard, (int, float)) and not isinstance(evidence_guard, bool) and math.isfinite(evidence_guard)
    check("plazo de guard registrado", valid_guard and abs(evidence_guard - expected_guard) <= 0.01, repr(evidence_guard))
    check("plazo de interfaz respetado", valid_elapsed and expected_guard - 0.05 <= elapsed <= expected_guard + 30, repr(elapsed))
    registry = expiry.get("registry")
    check("registro de identidades legible", isinstance(registry, dict), repr(type(registry).__name__))
    if isinstance(registry, dict):
        supervisor = registry.get("supervisor")
        children = registry.get("children")
        check("identidad del supervisor registrada", isinstance(supervisor, dict), repr(supervisor))
        check("registro de descendientes legible", isinstance(children, dict), repr(type(children).__name__))
        if isinstance(supervisor, dict):
            sup_pid = supervisor.get("pid")
            sup_ticks = supervisor.get("ticks")
            sup_pgrp = supervisor.get("pgrp")
            if isinstance(sup_pid, int) and sup_pid > 0 and isinstance(sup_ticks, str) and sup_ticks.isdigit():
                registered_pids.append((sup_pid, sup_ticks, "supervisor"))
            else:
                check("identidad del supervisor completa", False, repr(supervisor))
            check("grupo del supervisor registrado", isinstance(sup_pgrp, int) and sup_pgrp > 1, repr(sup_pgrp))
        else:
            sup_pgrp = None
        child_groups = set()
        if isinstance(children, dict):
            for key, child in sorted(children.items(), key=lambda item: str(item[0])):
                try:
                    pid = int(key)
                except (TypeError, ValueError):
                    check("PID hijo registrado", False, repr(key))
                    continue
                if not isinstance(child, dict) or child.get("pid") != pid:
                    check("identidad de hijo registrada", False, "%s: %r" % (pid, child))
                    continue
                ticks = child.get("ticks")
                pgrp = child.get("pgrp")
                if pid <= 0 or not isinstance(ticks, str) or not ticks.isdigit():
                    check("identidad de hijo completa", False, "%s: %r" % (pid, child))
                else:
                    registered_pids.append((pid, ticks, "hijo"))
                if isinstance(pgrp, int) and pgrp > 1:
                    child_groups.add(pgrp)
                else:
                    check("grupo de hijo registrado", False, "%s: %r" % (pid, pgrp))
        for pid, ticks, label in registered_pids:
            try:
                raw = pathlib.Path("/proc/%d/stat" % pid).read_text(encoding="ascii")
            except FileNotFoundError:
                check("PID %d ausente de /proc" % pid, True, "%s: PID ausente" % label)
                continue
            except OSError as exc:
                check("PID %d ausente de /proc" % pid, False, "%s: %s" % (label, exc))
                continue
            fields = raw[raw.rfind(")") + 2:].split()
            current_ticks = fields[19] if len(fields) > 19 else "unknown"
            current_state = fields[0] if fields else "unknown"
            identity_present = current_ticks == ticks and current_state not in ("Z", "X")
            check("PID %d identidad viva ausente de /proc" % pid, not identity_present,
                  "%s: state=%s start_ticks=%s esperado=%s" % (label, current_state, current_ticks, ticks))
        live_groups = {}
        try:
            proc_entries = os.listdir("/proc")
        except OSError as exc:
            proc_entries = []
            check("lectura acotada de /proc", False, repr(exc))
        for entry in proc_entries:
            if not entry.isdigit():
                continue
            try:
                raw = pathlib.Path("/proc/%s/stat" % entry).read_text(encoding="ascii")
                fields = raw[raw.rfind(")") + 2:].split()
                if len(fields) <= 3 or fields[0] in ("Z", "X"):
                    continue
                pgid = int(fields[2])
            except (OSError, ValueError, IndexError):
                continue
            live_groups.setdefault(pgid, []).append(int(entry))
        for pgid in sorted(child_groups):
            if pgid == sup_pgrp:
                shared_groups.append(pgid)
                continue
            members = live_groups.get(pgid, [])
            checked_groups.append(pgid)
            check("grupo propio %d ausente de /proc" % pgid, not members, repr(members))
        check("grupos hijos registrados comprobados", True,
              "vacíos=%s; grupo compartido con el wrapper (no señalizable)=%s" % (checked_groups, shared_groups))

if verdict is not None:
    check("guard-verdict declara vencimiento", verdict.get("guard_expired") is True, repr(verdict.get("guard_expired")))
    check("guard-verdict reconoce el RC real del ejecutor", verdict.get("wrapper_rc") == runner_rc,
          "wrapper_rc=%r runner_rc=%r" % (verdict.get("wrapper_rc"), runner_rc))
    check("guard-verdict RC coincide con el plazo configurado", isinstance(verdict.get("guard_seconds"), (int, float))
          and abs(verdict.get("guard_seconds") - expected_guard) <= 0.01, repr(verdict.get("guard_seconds")))
    survivors = verdict.get("survivors")
    problems_list = verdict.get("problems")
    if runner_rc == 14:
        check("guard-verdict RC 14 sin supervivientes", isinstance(survivors, list) and survivors == [], repr(survivors))
        check("guard-verdict RC 14 sin problemas", problems_list == [], repr(problems_list))
        check("guard-verdict RC 14 limpieza acreditada", verdict.get("ok") is True, repr(verdict.get("ok")))
    else:
        kinds = {item.get("kind") for item in survivors if isinstance(item, dict)} if isinstance(survivors, list) else set()
        check("guard-verdict RC 15 conserva los tres supervivientes detectados",
              isinstance(survivors, list) and len(survivors) == 3 and kinds == {"child", "group", "supervisor"},
              "survivors=%r kinds=%r" % (survivors, kinds))
        check("guard-verdict RC 15 registra limpieza incompleta", verdict.get("ok") is False
              and isinstance(problems_list, list) and bool(problems_list),
              "ok=%r problems=%r" % (verdict.get("ok"), problems_list))
    wall = verdict.get("wall_seconds")
    elapsed = verdict.get("elapsed_seconds")
    valid_wall = isinstance(wall, (int, float)) and not isinstance(wall, bool) and math.isfinite(wall)
    valid_elapsed = isinstance(elapsed, (int, float)) and not isinstance(elapsed, bool) and math.isfinite(elapsed)
    check("plazo global de la interfaz acotado", valid_wall and expected_guard - 0.05 <= wall <= expected_guard + 30, repr(wall))
    check("plazo interno de guard acotado", valid_elapsed and expected_guard - 0.05 <= elapsed <= expected_guard + 30, repr(elapsed))
    if expiry is not None:
        check("duraciones de ambas evidencias coherentes", valid_elapsed
              and isinstance(expiry.get("elapsed_seconds"), (int, float))
              and abs(elapsed - expiry["elapsed_seconds"]) <= 1.0,
              "guard-verdict=%r guard-expiry=%r" % (elapsed, expiry.get("elapsed_seconds")))

result = {
    "status": "PASS" if not problems else "FAIL",
    "runner_rc": runner_rc,
    "interface_guard_seconds": expected_guard,
    "hard_failure": runner_rc in (13, 14, 15),
    "guard_expiry": str(expiry_path),
    "guard_verdict": str(verdict_path),
    "registered_pids": [{"pid": pid, "start_ticks": ticks, "kind": label} for pid, ticks, label in registered_pids],
    "checked_process_groups": checked_groups,
    "shared_wrapper_process_groups": shared_groups,
    "checks": checks,
    "problems": problems,
}
try:
    result_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    result_path.chmod(0o600)
except OSError as exc:
    print("FAIL: no se pudo escribir guard-integration-verdict.json: %s" % exc, file=sys.stderr)
    raise SystemExit(1)
for item in checks:
    print("%s guard expiry: %s — %s" % ("PASS" if item["ok"] else "FAIL", item["name"], item["detail"]))
print("guard integration RC=%s status=%s evidencia=%s" % (runner_rc, result["status"], result_path))
raise SystemExit(0 if not problems else 1)
PY
}

cleanup_active_scenario() {
  local pid="$ACTIVE_SCENARIO_PID" launch_pid="$ACTIVE_SCENARIO_LAUNCH_PID"
  local pgid="$ACTIVE_SCENARIO_PGID" sid="$ACTIVE_SCENARIO_SID"
  local inner_pgid="$ACTIVE_SCENARIO_INNER_PGID" inner_sid="$ACTIVE_SCENARIO_INNER_SID"
  local own_group=0 registered_outer=0 inner_registered=0 inner_before='[]' inner_after='unknown'
  local outer_before='[]' outer_after='unknown' discovery_output='' key found_pid found_start found_pgid found_sid
  local stopped=0 inner_signalled=0 inner_dead=0 cleanup_rc=0 wait_deadline
  local launcher_gone=unknown suite_gone=unknown supervisor_gone=unknown
  local launcher_absent_before=unknown suite_absent_before=unknown inner_absent_before=0
  local outer_wait_budget=2 outer_member_count=0 outer_kill_sent=0
  [[ -n "$launch_pid" ]] || return 0
  ACTIVE_SCENARIO_EXCEPTION_STATUS=started

  # Keep the launch-time group registration separate from current /proc
  # accreditation. Failure to revalidate is reported, but cannot suppress
  # termination of a still-existing group whose identity this run registered.
  if [[ "$ACTIVE_SCENARIO_OUTER_REGISTERED" == 1 && -n "$pgid" && -n "$sid" \
      && "$pgid" == "$sid" && "$ACTIVE_SCENARIO_OUTER_START" =~ ^[0-9]+$ ]]; then
    registered_outer=1
  fi
  if ((registered_outer)) && read_proc_fields "$pgid" \
      && [[ "${PROC_FIELDS[19]}" == "$ACTIVE_SCENARIO_OUTER_START" && "${PROC_FIELDS[2]}" == "$pgid" && "${PROC_FIELDS[3]}" == "$sid" ]]; then
    own_group=1
  fi
  if [[ "$FORGE_V2_CLEANUP_BRANCH_PROBE" == outer-identity-unaccredited ]]; then
    own_group=0
    printf 'PRUEBA DIRIGIDA: se fuerza own_group=0; permanece registrada la identidad exterior %s/%s\n' "$pgid" "$sid"
  fi
  if ((registered_outer)); then
    if ((own_group == 0)); then
      printf 'FAIL limpieza exterior: acreditación /proc actual fallida para el grupo registrado %s/%s; se registra fallo, pero no se omite su terminación\n' "$pgid" "$sid"
      cleanup_rc=1
    fi
    group_members "$pgid" "$sid"
    outer_before="${GROUP_MEMBERS[*]}"
    [[ -n "$outer_before" ]] || outer_before='[]'
    if ((${#GROUP_MEMBERS[@]})); then
      if [[ "$FORGE_V2_CLEANUP_BRANCH_PROBE" == freeze-failed ]]; then
        printf 'PRUEBA DIRIGIDA: se fuerza el resultado fallido del SIGSTOP del grupo exterior registrado\n'
        cleanup_rc=1
      elif kill -STOP -- "-$pgid" 2>/dev/null; then
        stopped=1
        printf 'LIMPIEZA EXTERIOR: grupo propio %s/%s congelado por identidad registrada; miembros=%s\n' "$pgid" "$sid" "$outer_before"
      else
        printf 'FAIL limpieza exterior: no se pudo congelar el grupo propio %s antes de limpiar recursos interiores\n' "$pgid"
        cleanup_rc=1
      fi
    fi
  else
    printf 'FAIL limpieza exterior: no hay identidad exterior registrada utilizable (pid=%s launch_pid=%s pgid=%s sid=%s); no se señaliza un grupo no acreditado\n' "$pid" "$launch_pid" "$pgid" "$sid"
    cleanup_rc=1
  fi

  if ((registered_outer)); then
    capture_inner_identity_from_log || true
    if [[ -n "$ACTIVE_SCENARIO_DIR" && -n "$ACTIVE_SCENARIO_REPORT" ]]; then
      discovery_output="$(discover_inner_identities 2>"$RUN_DIR/$(basename "$ACTIVE_SCENARIO_DIR").outer-cleanup-discovery.stderr")" || cleanup_rc=1
      while IFS=$'\t' read -r key found_pid found_start found_pgid found_sid; do
        [[ -n "$key" ]] || continue
        if [[ "$key" == supervisor ]]; then
          ACTIVE_SCENARIO_SUPERVISOR_PID="$found_pid"
          ACTIVE_SCENARIO_SUPERVISOR_START="$found_start"
        elif [[ "$key" == launcher ]]; then
          if [[ -n "$ACTIVE_SCENARIO_INNER_PID" && "$ACTIVE_SCENARIO_INNER_PID" != "$found_pid" ]]; then
            printf 'FAIL limpieza exterior: launcher del log (%s) difiere del descendiente identificado (%s)\n' "$ACTIVE_SCENARIO_INNER_PID" "$found_pid"
            cleanup_rc=1
          else
            ACTIVE_SCENARIO_INNER_PID="$found_pid"
            ACTIVE_SCENARIO_INNER_START="$found_start"
            ACTIVE_SCENARIO_INNER_PGID="$found_pgid"
            ACTIVE_SCENARIO_INNER_SID="$found_sid"
            ACTIVE_SCENARIO_INNER_REGISTERED_AT="$(mono_now)"
          fi
        elif [[ "$key" == suite ]]; then
          ACTIVE_SCENARIO_SUITE_PID="$found_pid"
          ACTIVE_SCENARIO_SUITE_START="$found_start"
        fi
      done <<< "$discovery_output"
    fi
  fi

  if [[ -n "$inner_pgid" && -n "$inner_sid" && "$inner_pgid" == "$inner_sid" ]]; then
    inner_registered=1
  elif [[ -n "$ACTIVE_SCENARIO_INNER_PID" && -n "$ACTIVE_SCENARIO_INNER_PGID" && "$ACTIVE_SCENARIO_INNER_PGID" == "$ACTIVE_SCENARIO_INNER_SID" && -n "$ACTIVE_SCENARIO_INNER_REGISTERED_AT" ]]; then
    inner_pgid="$ACTIVE_SCENARIO_INNER_PGID"
    inner_sid="$ACTIVE_SCENARIO_INNER_SID"
    inner_registered=1
  fi

  if ((inner_registered)); then
    group_members "$inner_pgid" "$inner_sid"
    inner_before="${GROUP_MEMBERS[*]}"
    [[ -n "$inner_before" ]] || inner_before='[]'
    if ((${#GROUP_MEMBERS[@]})); then
      if [[ -n "$ACTIVE_SCENARIO_INNER_START" ]] && process_identity_alive "$ACTIVE_SCENARIO_INNER_PID" "$ACTIVE_SCENARIO_INNER_START"; then
        if ! read_proc_fields "$ACTIVE_SCENARIO_INNER_PID" || [[ "${PROC_FIELDS[2]}" != "$inner_pgid" || "${PROC_FIELDS[3]}" != "$inner_sid" ]]; then
          printf 'FAIL limpieza exterior: identidad del launcher cambió antes de señal; grupo %s no se señaliza\n' "$inner_pgid"
          cleanup_rc=1
        elif ! kill -KILL -- "-$inner_pgid" 2>/dev/null; then
          printf 'FAIL limpieza exterior: no se pudo terminar el grupo interior propio %s\n' "$inner_pgid"
          cleanup_rc=1
        else
          inner_signalled=1
          printf 'LIMPIEZA EXTERIOR: SIGKILL solo al grupo interior propio %s/%s, miembros=%s; launcher y suite terminados antes de retirar al supervisor\n' "$inner_pgid" "$inner_sid" "$inner_before"
        fi
      elif [[ -n "$ACTIVE_SCENARIO_INNER_REGISTERED_AT" ]]; then
        # The session was registered from this run's unique report/log. If its
        # leader has already exited, the still-existing group cannot have been
        # reused; retain the accepted killpg early-leader-exit contract.
        if ! kill -KILL -- "-$inner_pgid" 2>/dev/null; then
          printf 'FAIL limpieza exterior: no se pudo terminar el grupo interior registrado %s tras salir su líder\n' "$inner_pgid"
          cleanup_rc=1
        else
          inner_signalled=1
          printf 'LIMPIEZA EXTERIOR: SIGKILL al grupo interior registrado %s/%s tras salir el líder; el grupo original sigue existiendo y killpg conserva su contrato\n' "$inner_pgid" "$inner_sid"
        fi
      else
        printf 'FAIL limpieza exterior: grupo interior %s tiene miembros sin identidad registrada; no se señaliza\n' "$inner_pgid"
        cleanup_rc=1
      fi
      wait_deadline=$((SECONDS + 10))
      while ((SECONDS < wait_deadline)); do
        group_members "$inner_pgid" "$inner_sid"
        if ((${#GROUP_MEMBERS[@]} == 0)); then
          inner_dead=1
          break
        fi
        sleep 0.05
      done
    else
      inner_dead=1
    fi
    group_members "$inner_pgid" "$inner_sid"
    inner_after="${GROUP_MEMBERS[*]}"
    [[ -n "$inner_after" ]] || inner_after='[]'
    if ((inner_dead == 0)); then
      printf 'FAIL limpieza exterior: supervivientes interiores en grupo %s: %s\n' "$inner_pgid" "$inner_after"
      cleanup_rc=1
    fi
  else
    inner_dead=1
    printf 'LIMPIEZA EXTERIOR: no se registró launcher/suite; el grupo exterior está congelado y no puede iniciar recursos interiores nuevos\n'
  fi

  # Resume the outer group if it was frozen, then check whether the recorded
  # launcher/suite identities disappeared. Failure to prove absence is reported
  # but never suppresses termination of the registered outer group.
  if [[ "$FORGE_V2_CLEANUP_BRANCH_PROBE" == inner-absent-before-false ]] && ((stopped)); then
    inner_absent_before=0
    launcher_absent_before=false
    suite_absent_before=false
    printf 'PRUEBA DIRIGIDA: inner_absent_before=0; el grupo exterior se mantiene congelado para acreditar su terminación incondicional\n'
  else
    if ((stopped)); then
      kill -CONT -- "-$pgid" 2>/dev/null || cleanup_rc=1
    fi
    wait_deadline=$((SECONDS + 10))
    while ((SECONDS < wait_deadline)); do
      launcher_absent_before=true
      suite_absent_before=true
      if [[ -n "$ACTIVE_SCENARIO_INNER_PID" ]] && process_identity_present "$ACTIVE_SCENARIO_INNER_PID" "$ACTIVE_SCENARIO_INNER_START"; then
        launcher_absent_before=false
      fi
      if [[ -n "$ACTIVE_SCENARIO_SUITE_PID" ]] && process_identity_present "$ACTIVE_SCENARIO_SUITE_PID" "$ACTIVE_SCENARIO_SUITE_START"; then
        suite_absent_before=false
      fi
      local inner_group_empty=1
      if ((inner_registered)); then
        group_members "$inner_pgid" "$inner_sid"
        ((${#GROUP_MEMBERS[@]} == 0)) || inner_group_empty=0
      fi
      if [[ "$launcher_absent_before" == true && "$suite_absent_before" == true ]] && ((inner_group_empty)); then
        inner_absent_before=1
        break
      fi
      sleep 0.05
    done
  fi
  if ((inner_absent_before)); then
    printf 'PASS limpieza excepcional: launcher y suite con sus start ticks registrados ya no existen en /proc antes de terminar el grupo exterior\n'
  else
    printf 'FAIL limpieza excepcional: no se acreditó ausencia del launcher/suite antes de terminar el grupo exterior (launcher=%s suite=%s); el grupo exterior registrado sí se terminará\n' "$launcher_absent_before" "$suite_absent_before"
    cleanup_rc=1
  fi

  # Always remove the registered outer group after attempting interior
  # cleanup, including failed freeze, failed absence proof, and failed current
  # /proc accreditation. The corresponding failure remains non-zero.
  if ((registered_outer)); then
    group_members "$pgid" "$sid"
    outer_before="${GROUP_MEMBERS[*]}"
    [[ -n "$outer_before" ]] || outer_before='[]'
    outer_member_count=${#GROUP_MEMBERS[@]}
    if ((outer_member_count > 0)); then
      outer_wait_budget=$((2 + outer_member_count))
      ((outer_wait_budget <= 10)) || outer_wait_budget=10
      if kill -KILL -- "-$pgid" 2>/dev/null; then
        outer_kill_sent=1
        printf 'LIMPIEZA EXTERIOR: SIGKILL al grupo exterior registrado %s/%s tras el intento interior; miembros=%s; espera acotada=%ss\n' "$pgid" "$sid" "$outer_before" "$outer_wait_budget"
      else
        printf 'FAIL limpieza exterior: no se pudo terminar el grupo exterior registrado %s/%s\n' "$pgid" "$sid"
        cleanup_rc=1
      fi
    else
      printf 'LIMPIEZA EXTERIOR: el grupo exterior registrado %s/%s ya está vacío\n' "$pgid" "$sid"
    fi
  else
    outer_wait_budget=2
    printf 'FAIL limpieza exterior: no se puede señalizar grupo sin identidad registrada; no se bloqueará el wait\n'
    cleanup_rc=1
  fi

  # Bash has no timeout for wait on one child. Poll the registered identity
  # with a group-scaled budget first; call wait only after it is gone/zombie,
  # when wait returns immediately. Never wait without that proof.
  wait_deadline=$((SECONDS + outer_wait_budget))
  while [[ "$ACTIVE_SCENARIO_LAUNCH_START" =~ ^[0-9]+$ ]] \
      && process_identity_alive "$launch_pid" "$ACTIVE_SCENARIO_LAUNCH_START" \
      && ((SECONDS < wait_deadline)); do
    sleep 0.05
  done
  if [[ "$ACTIVE_SCENARIO_LAUNCH_START" =~ ^[0-9]+$ ]] && process_identity_alive "$launch_pid" "$ACTIVE_SCENARIO_LAUNCH_START"; then
    printf 'FAIL limpieza exterior: launcher PID %s sigue vivo tras %ss; se reitera SIGKILL, sin wait ilimitado\n' "$launch_pid" "$outer_wait_budget"
    if ((registered_outer)); then kill -KILL -- "-$pgid" 2>/dev/null || true; fi
    wait_deadline=$((SECONDS + 2))
    while process_identity_alive "$launch_pid" "$ACTIVE_SCENARIO_START" && ((SECONDS < wait_deadline)); do sleep 0.05; done
    cleanup_rc=1
  fi
  set +e
  if [[ "$ACTIVE_SCENARIO_LAUNCH_START" =~ ^[0-9]+$ ]] && ! process_identity_alive "$launch_pid" "$ACTIVE_SCENARIO_LAUNCH_START"; then
    wait "$launch_pid" 2>/dev/null
  else
    printf 'FAIL limpieza exterior: wait omitido para evitar bloqueo indefinido del hijo vivo PID %s\n' "$launch_pid"
    cleanup_rc=1
  fi
  set -e
  if [[ -n "$pgid" && -n "$sid" ]]; then
    group_members "$pgid" "$sid"
    outer_after="${GROUP_MEMBERS[*]}"
    [[ -n "$outer_after" ]] || outer_after='[]'
    if ((${#GROUP_MEMBERS[@]})); then
      printf 'FAIL limpieza exterior: procesos propios supervivientes en grupo %s: %s\n' "$pgid" "$outer_after"
      cleanup_rc=1
    fi
  fi
  if [[ -n "$ACTIVE_SCENARIO_INNER_PID" ]]; then
    if process_identity_alive "$ACTIVE_SCENARIO_INNER_PID" "$ACTIVE_SCENARIO_INNER_START"; then launcher_gone=false; else launcher_gone=true; fi
  fi
  if [[ -n "$ACTIVE_SCENARIO_SUITE_PID" ]]; then
    if process_identity_alive "$ACTIVE_SCENARIO_SUITE_PID" "$ACTIVE_SCENARIO_SUITE_START"; then suite_gone=false; else suite_gone=true; fi
  fi
  if [[ -n "$ACTIVE_SCENARIO_SUPERVISOR_PID" ]]; then
    if process_identity_alive "$ACTIVE_SCENARIO_SUPERVISOR_PID" "$ACTIVE_SCENARIO_SUPERVISOR_START"; then supervisor_gone=false; else supervisor_gone=true; fi
  fi
  if [[ "$launcher_gone" == false || "$suite_gone" == false || "$supervisor_gone" == false ]]; then
    printf 'FAIL limpieza exterior: identidad viva tras terminar el grupo: launcher=%s suite=%s supervisor=%s\n' "$launcher_gone" "$suite_gone" "$supervisor_gone"
    cleanup_rc=1
  fi

  if ((inner_dead && cleanup_rc == 0)); then
    ACTIVE_SCENARIO_EXCEPTION_STATUS=interior-terminado-y-ausente-antes-del-supervisor
  else
    ACTIVE_SCENARIO_EXCEPTION_STATUS=fallo-limpieza-interior-o-exterior
    cleanup_rc=1
  fi
  if [[ -n "$ACTIVE_SCENARIO_DIR" ]]; then
    printf '%s\t%s\t%s/%s\t%s/%s\t%s@%s\t%s\t%s\t%s@%s\t%s\t%s\t%s@%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(basename "$ACTIVE_SCENARIO_DIR")" "$FORGE_V2_OUTER_SCENARIO_GUARD" "$pgid" "$sid" \
      "${inner_pgid:-unknown}" "${inner_sid:-unknown}" "${ACTIVE_SCENARIO_INNER_PID:-unknown}" "${ACTIVE_SCENARIO_INNER_START:-unknown}" \
      "$launcher_absent_before" "$launcher_gone" "${ACTIVE_SCENARIO_SUITE_PID:-unknown}" "${ACTIVE_SCENARIO_SUITE_START:-unknown}" "$suite_absent_before" "$suite_gone" \
      "${ACTIVE_SCENARIO_SUPERVISOR_PID:-unknown}" "${ACTIVE_SCENARIO_SUPERVISOR_START:-unknown}" "$supervisor_gone" \
      "$inner_signalled" "$inner_after" "$outer_after" "$outer_kill_sent" "$outer_wait_budget" "$ACTIVE_SCENARIO_EXCEPTION_STATUS" >> "$EXCEPTIONAL_CLEANUP_LOG"
    printf 'EXCEPTIONAL_CLEANUP scenario=%s guard_s=%s outer_group=%s/%s inner_group=%s/%s launcher=%s@%s launcher_absent_before_supervisor=%s launcher_gone_final=%s suite=%s@%s suite_absent_before_supervisor=%s suite_gone_final=%s supervisor=%s@%s supervisor_gone_final=%s inner_signalled=%s inner_members_after=%s outer_members_after=%s outer_kill_sent=%s outer_wait_budget_s=%s status=%s\n' \
      "$(basename "$ACTIVE_SCENARIO_DIR")" "$FORGE_V2_OUTER_SCENARIO_GUARD" "$pgid" "$sid" "${inner_pgid:-unknown}" "${inner_sid:-unknown}" \
      "${ACTIVE_SCENARIO_INNER_PID:-unknown}" "${ACTIVE_SCENARIO_INNER_START:-unknown}" "$launcher_absent_before" "$launcher_gone" \
      "${ACTIVE_SCENARIO_SUITE_PID:-unknown}" "${ACTIVE_SCENARIO_SUITE_START:-unknown}" "$suite_absent_before" "$suite_gone" \
      "${ACTIVE_SCENARIO_SUPERVISOR_PID:-unknown}" "${ACTIVE_SCENARIO_SUPERVISOR_START:-unknown}" \
      "$supervisor_gone" "$inner_signalled" "$inner_after" "$outer_after" "$outer_kill_sent" "$outer_wait_budget" "$ACTIVE_SCENARIO_EXCEPTION_STATUS"
  fi
  ACTIVE_SCENARIO_PID=
  ACTIVE_SCENARIO_LAUNCH_PID=
  ACTIVE_SCENARIO_LAUNCH_START=
  ACTIVE_SCENARIO_PGID=
  ACTIVE_SCENARIO_SID=
  ACTIVE_SCENARIO_START=
  ACTIVE_SCENARIO_OUTER_START=
  ACTIVE_SCENARIO_OUTER_REGISTERED=0
  if ((cleanup_rc)); then return 1; fi
  return 0
}

run_scenario() {
  local scenario="$1" scenario_dir="$RUN_DIR/$1" scenario_log="$RUN_DIR/$1.runner.log"
  local identity_file="$RUN_DIR/$1.outer-session-pid" identity_ready_file="$RUN_DIR/$1.outer-session-registered"
  local start='' finish='' cleanup_start='' cleanup_end='' total_end='' rc=0 timed_out=0 launch_wait_deadline
  local wrapper_start wrapper_end cleanup_mark injection_mark timeout_elapsed cleanup_elapsed prep_elapsed total_elapsed execution_elapsed outer_cleanup_elapsed tail_cleanup_elapsed starts children delta normal_total
  local own_members='' scenario_pgid='' scenario_sid='' members_after='' cleanup_failed=0
  export FORGE_V2_EXTERNAL_ROOT FORGE_V2_REAL_DB FORGE_V2_HANG_TIMEOUT FORGE_V2_SCENARIO_GUARD
  export FORGE_V2_OUTER_SCENARIO_GUARD
  export FORGE_V2_BATCH_ROOT="$scenario_dir/work"
  export FORGE_V2_EVIDENCE_ROOT="$scenario_dir"
  ACTIVE_SCENARIO_LAUNCH_PID=
  ACTIVE_SCENARIO_LAUNCH_START=
  ACTIVE_SCENARIO_OUTER_START=
  ACTIVE_SCENARIO_OUTER_REGISTERED=0
  ACTIVE_SCENARIO_DIR="$scenario_dir"
  ACTIVE_SCENARIO_REPORT="$scenario_dir/safety-results.json"
  ACTIVE_SCENARIO_INNER_PID=
  ACTIVE_SCENARIO_SUITE_PID=
  ACTIVE_SCENARIO_INNER_PGID=
  ACTIVE_SCENARIO_INNER_SID=
  ACTIVE_SCENARIO_INNER_START=
  ACTIVE_SCENARIO_SUITE_START=
  ACTIVE_SCENARIO_INNER_REGISTERED_AT=
  ACTIVE_SCENARIO_SUPERVISOR_PID=
  ACTIVE_SCENARIO_SUPERVISOR_START=
  ACTIVE_SCENARIO_EXCEPTION_STATUS=not-applicable
  start="$(mono_now)"
  printf '=== Ejecutando interfaz literal: bash tests/forge_v2_safety_scenarios.sh %s %s ===\n' "$scenario" "$scenario_dir"
  # shellcheck disable=SC2016 # The single-quoted body is executed by child Bash; its expansions belong there.
  setsid --fork --wait bash -c '
    identity_file="$1"
    identity_ready_file="$2"
    shift 2
    printf "%s\n" "$$" > "$identity_file"
    # Do not enter the scenario until the parent has accredited this process
    # as the unique session/group leader. A bounded handshake also ensures a
    # failed accreditation cannot leave a child waiting indefinitely.
    ready_deadline=$((SECONDS + 4))
    while [[ ! -e "$identity_ready_file" ]] && ((SECONDS < ready_deadline)); do
      sleep 0.05
    done
    [[ -e "$identity_ready_file" ]] || exit 125
    exec "$@"
  ' forge-v2-scenario "$identity_file" "$identity_ready_file" bash tests/forge_v2_safety_scenarios.sh "$scenario" "$scenario_dir" > "$scenario_log" 2>&1 &
  ACTIVE_SCENARIO_LAUNCH_PID=$!
  if read_proc_fields "$ACTIVE_SCENARIO_LAUNCH_PID" && [[ "${PROC_FIELDS[0]}" != Z && "${PROC_FIELDS[0]}" != X ]]; then
    ACTIVE_SCENARIO_LAUNCH_START="${PROC_FIELDS[19]}"
  fi
  local identity_deadline=$((SECONDS + 5))
  while [[ ! -s "$identity_file" ]] && ((SECONDS < identity_deadline)); do
    sleep 0.05
  done
  if [[ -s "$identity_file" ]]; then
    IFS= read -r ACTIVE_SCENARIO_PID < "$identity_file"
  fi
  if read_proc_fields "$ACTIVE_SCENARIO_PID"; then
    ACTIVE_SCENARIO_START="${PROC_FIELDS[19]}"
    if [[ "$ACTIVE_SCENARIO_PID" == "${PROC_FIELDS[2]}" && "$ACTIVE_SCENARIO_PID" == "${PROC_FIELDS[3]}" ]]; then
      ACTIVE_SCENARIO_PGID="${PROC_FIELDS[2]}"
      ACTIVE_SCENARIO_SID="${PROC_FIELDS[3]}"
      ACTIVE_SCENARIO_OUTER_START="${PROC_FIELDS[19]}"
      ACTIVE_SCENARIO_OUTER_REGISTERED=1
    fi
    scenario_pgid="$ACTIVE_SCENARIO_PGID"
    scenario_sid="$ACTIVE_SCENARIO_SID"
  fi
  if [[ ! "$ACTIVE_SCENARIO_PID" =~ ^[0-9]+$ || ! "$ACTIVE_SCENARIO_PGID" =~ ^[0-9]+$ \
      || "$ACTIVE_SCENARIO_PGID" != "$ACTIVE_SCENARIO_PID" || "$ACTIVE_SCENARIO_SID" != "$ACTIVE_SCENARIO_PID" \
      || "$ACTIVE_SCENARIO_OUTER_REGISTERED" != 1 || ! "$ACTIVE_SCENARIO_START" =~ ^[0-9]+$ ]] \
       || ! read_proc_fields "$ACTIVE_SCENARIO_PID" \
       || [[ "${PROC_FIELDS[19]}" != "$ACTIVE_SCENARIO_START" || "${PROC_FIELDS[2]}" != "$ACTIVE_SCENARIO_PGID" || "${PROC_FIELDS[3]}" != "$ACTIVE_SCENARIO_SID" ]]; then
    printf 'FAIL: no se pudo acreditar identidad de grupo/sesión propia para %s; se esperará con plazo al launcher directo, sin señalizar grupos no registrados\n' "$scenario"
    printf '%s\tunknown\tunknown\tunknown\tunknown\n' "$scenario" >> "$OWN_GROUP_LOG"
    SCENARIO_FAILURE=1
    if [[ ! "$ACTIVE_SCENARIO_LAUNCH_START" =~ ^[0-9]+$ ]] && read_proc_fields "$ACTIVE_SCENARIO_LAUNCH_PID"; then
      ACTIVE_SCENARIO_LAUNCH_START="${PROC_FIELDS[19]}"
    fi
    launch_wait_deadline=$((SECONDS + 5))
    while [[ "$ACTIVE_SCENARIO_LAUNCH_START" =~ ^[0-9]+$ ]] \
        && process_identity_alive "$ACTIVE_SCENARIO_LAUNCH_PID" "$ACTIVE_SCENARIO_LAUNCH_START" \
        && ((SECONDS < launch_wait_deadline)); do
      sleep 0.05
    done
    if [[ "$ACTIVE_SCENARIO_LAUNCH_START" =~ ^[0-9]+$ ]] \
        && ! process_identity_alive "$ACTIVE_SCENARIO_LAUNCH_PID" "$ACTIVE_SCENARIO_LAUNCH_START"; then
      set +e
      wait "$ACTIVE_SCENARIO_LAUNCH_PID" 2>/dev/null
      rc=$?
      set -e
      finish="$(mono_now)"
      cleanup_start="$finish"
      cleanup_end="$finish"
      own_members='[]'
      members_after='[]'
      printf 'FAIL: launcher terminó con RC=%s tras fallar la acreditación de identidad; no se observó grupo propio señalizable\n' "$rc"
      if ((rc == 0)); then cleanup_failed=1; fi
    else
      rc=14
      timed_out=1
      cleanup_failed=1
      printf 'FAIL: launcher directo sigue vivo tras 5 s sin identidad de grupo; se evita wait ilimitado\n'
      if ((ACTIVE_SCENARIO_OUTER_REGISTERED)); then
        cleanup_start="$(mono_now)"
        cleanup_active_scenario || cleanup_failed=1
      elif [[ "$ACTIVE_SCENARIO_LAUNCH_START" =~ ^[0-9]+$ ]] \
          && process_identity_alive "$ACTIVE_SCENARIO_LAUNCH_PID" "$ACTIVE_SCENARIO_LAUNCH_START"; then
        kill -KILL "$ACTIVE_SCENARIO_LAUNCH_PID" 2>/dev/null || true
        launch_wait_deadline=$((SECONDS + 2))
        while process_identity_alive "$ACTIVE_SCENARIO_LAUNCH_PID" "$ACTIVE_SCENARIO_LAUNCH_START" \
            && ((SECONDS < launch_wait_deadline)); do sleep 0.05; done
      fi
      finish="$(mono_now)"
      cleanup_end="$finish"
    fi
  else
    : > "$identity_ready_file"
    capture_inner_identity_from_log || true
    local scenario_deadline=$((SECONDS + FORGE_V2_OUTER_SCENARIO_GUARD))
    while :; do
      capture_inner_identity_from_log || true
      if ! read_proc_fields "$ACTIVE_SCENARIO_PID" || [[ "${PROC_FIELDS[19]}" != "$ACTIVE_SCENARIO_START" || "${PROC_FIELDS[0]}" == Z || "${PROC_FIELDS[0]}" == X ]]; then
        break
      fi
      if ((SECONDS >= scenario_deadline)); then
        timed_out=1
        printf 'FAIL: guard exterior de vivacidad %ss para %s; se limpiará únicamente su sesión/grupo registrado\n' "$FORGE_V2_OUTER_SCENARIO_GUARD" "$scenario"
        break
      fi
      sleep 0.10
    done
    if ((timed_out == 0)); then
      set +e
      wait "$ACTIVE_SCENARIO_LAUNCH_PID"
      rc=$?
      set -e
      finish="$(mono_now)"
      cleanup_start="$finish"
    group_members "$scenario_pgid" "$scenario_sid"
    own_members="${GROUP_MEMBERS[*]}"
    [[ -n "$own_members" ]] || own_members='[]'
      if ((${#GROUP_MEMBERS[@]})); then
        printf 'FAIL: supervivientes del grupo propio tras %s: %s; se intenta limpieza exterior con identidad registrada\n' "$scenario" "$own_members"
        SCENARIO_FAILURE=1
        cleanup_active_scenario || cleanup_failed=1
      else
        ACTIVE_SCENARIO_PID=
        ACTIVE_SCENARIO_LAUNCH_PID=
        ACTIVE_SCENARIO_LAUNCH_START=
        ACTIVE_SCENARIO_PGID=
        ACTIVE_SCENARIO_SID=
        ACTIVE_SCENARIO_START=
        ACTIVE_SCENARIO_OUTER_START=
        ACTIVE_SCENARIO_OUTER_REGISTERED=0
      fi
      cleanup_end="$(mono_now)"
    else
      rc=14
      cleanup_start="$(mono_now)"
      group_members "$scenario_pgid" "$scenario_sid"
      own_members="${GROUP_MEMBERS[*]}"
      [[ -n "$own_members" ]] || own_members='[]'
      cleanup_active_scenario || cleanup_failed=1
      finish="$(mono_now)"
      cleanup_end="$finish"
    fi
    group_members "$scenario_pgid" "$scenario_sid"
    members_after="${GROUP_MEMBERS[*]}"
    [[ -n "$members_after" ]] || members_after='[]'
    printf '%s\t%s\t%s\t%s\t%s\n' "$scenario" "$scenario_pgid" "$scenario_sid" "$own_members" "$members_after" >> "$OWN_GROUP_LOG"
  fi
  if ((timed_out)); then
    rc=14
    SCENARIO_FAILURE=1
  fi
  if ((timed_out == 0)) && ((rc == 13 || rc == 14 || rc == 15)); then
    printf 'FAIL DURO: la interfaz de %s devolvió RC %s; RC 13/14/15 no son éxito y no se traducen a RC de supervisor/suite.\n' "$scenario" "$rc"
    if ((rc == 13)); then
      printf 'FAIL DURO RC 13: guard exterior contradictorio; se conserva el log de interfaz y no se confunde con RC de supervisor/suite.\n'
    elif validate_guard_expiry_evidence "$scenario_dir" "$rc"; then
      if ((rc == 15)); then
        printf 'PASS evidencia de RC 15: se detectaron supervivientes en el veredicto y la recuperación posterior los retiró; el RC global sigue siendo no-cero.\n'
      else
        printf 'PASS evidencia de guard vencido: runner RC=%s, limpieza independiente acreditada; el RC global sigue siendo no-cero.\n' "$rc"
      fi
    else
      printf 'FAIL evidencia de guard vencido: la comprobación independiente no pasó; RC global no-cero obligatorio.\n'
      SCENARIO_FAILURE=1
    fi
    SCENARIO_FAILURE=1
  fi
  printf '%s\t%s\t%s\n' "$scenario" "$rc" "$timed_out" >> "$SCENARIO_RC_FILE"
  if ((rc != 0)); then
    SCENARIO_FAILURE=1
  fi
  if ((cleanup_failed)); then
    SCENARIO_FAILURE=1
  fi
  if [[ -s "$RUN_DIR/$scenario/supervisor.stderr" ]]; then
    wrapper_start="$(sed -n 's/^WRAPPER_MONO_START=//p' "$RUN_DIR/$scenario/supervisor.stderr" | tail -n 1)"
    wrapper_end="$(sed -n 's/^WRAPPER_MONO_END=//p' "$RUN_DIR/$scenario/supervisor.stderr" | tail -n 1)"
  else
    wrapper_start=
    wrapper_end=
  fi
  cleanup_mark="$(awk -F '\t' '$2 ~ /\[supervisor\] limpieza OK/ { mark=$1 } END { if (mark != "") print mark }' "$RUN_DIR/$scenario/supervisor.stdout.tsv" 2>/dev/null || true)"
  injection_mark="$(awk -F '\t' '$2 ~ /\[inyeccion\] hijo sintetico creado/ { mark=$1 } END { if (mark != "") print mark }' "$RUN_DIR/$scenario/supervisor.stdout.tsv" 2>/dev/null || true)"
  prep_elapsed=0
  cleanup_elapsed=0
  timeout_elapsed=0
  total_end="${cleanup_end:-${finish:-$(mono_now)}}"
  total_elapsed="$(awk -v a="$start" -v b="$total_end" 'BEGIN { printf "%.3f", b-a }')"
  if [[ -n "$wrapper_start" ]]; then
    prep_elapsed="$(awk -v a="$start" -v b="$wrapper_start" 'BEGIN { d=b-a; if (d<0) d=0; printf "%.3f", d }')"
  fi
  if [[ "$scenario" == no-pidfd-hang && -n "$injection_mark" && -n "$cleanup_mark" ]]; then
    timeout_elapsed="$(awk -v a="$injection_mark" -v b="$cleanup_mark" 'BEGIN { d=b-a; if (d<0) d=0; printf "%.3f", d }')"
  fi
  if [[ -n "$wrapper_end" && -n "$cleanup_mark" ]]; then
    cleanup_elapsed="$(awk -v a="$cleanup_mark" -v b="$wrapper_end" 'BEGIN { d=b-a; if (d<0) d=0; printf "%.3f", d }')"
  fi
  if [[ -n "$wrapper_end" && -n "$finish" ]]; then
    tail_cleanup_elapsed="$(awk -v a="$wrapper_end" -v b="$finish" 'BEGIN { d=b-a; if (d<0) d=0; printf "%.3f", d }')"
    cleanup_elapsed="$(awk -v a="$cleanup_elapsed" -v b="$tail_cleanup_elapsed" 'BEGIN { printf "%.3f", a+b }')"
  else
    tail_cleanup_elapsed=0
  fi
  if [[ -n "$cleanup_start" && -n "$cleanup_end" ]]; then
    outer_cleanup_elapsed="$(awk -v a="$cleanup_start" -v b="$cleanup_end" 'BEGIN { d=b-a; if (d<0) d=0; printf "%.3f", d }')"
    cleanup_elapsed="$(awk -v a="$cleanup_elapsed" -v b="$outer_cleanup_elapsed" 'BEGIN { printf "%.3f", a+b }')"
  else
    outer_cleanup_elapsed=0
  fi
  execution_elapsed="$(awk -v total="$total_elapsed" -v prep="$prep_elapsed" -v timeout="$timeout_elapsed" -v cleanup="$cleanup_elapsed" 'BEGIN { d=total-prep-timeout-cleanup; if (d<0) d=0; printf "%.3f", d }')"
  starts='unknown'
  children='unknown'
  if [[ -s "$RUN_DIR/$scenario/verdict.json" ]]; then
    starts="$(sed -n 's/^[[:space:]]*"arranques_namespace":[[:space:]]*\([0-9][0-9]*\),.*/\1/p' "$RUN_DIR/$scenario/verdict.json" | head -n 1)"
    children="$(sed -n 's/^[[:space:]]*"hijos_inyectados":[[:space:]]*\([0-9][0-9]*\),.*/\1/p' "$RUN_DIR/$scenario/verdict.json" | head -n 1)"
    [[ -n "$starts" ]] || starts=unknown
    [[ -n "$children" ]] || children=unknown
  fi
  if [[ "$scenario" == normal ]]; then
    delta=0
  else
    normal_total="$(awk -F '\t' '$1 == "normal" { print $6; exit }' "$SCENARIO_TIMINGS")"
    if [[ -n "$normal_total" ]]; then
      delta="$(awk -v a="$total_elapsed" -v b="$normal_total" 'BEGIN { printf "%.3f", a-b }')"
    else
      delta=unknown
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$scenario" "$prep_elapsed" "$execution_elapsed" "$timeout_elapsed" "$cleanup_elapsed" "$total_elapsed" "$starts" "$children" "$delta" >> "$SCENARIO_TIMINGS"
  printf 'SCENARIO_RC scenario=%s runner_rc=%s interface_guard_s=%s outer_guard_s=%s outer_guard_fired=%s prep_s=%s execution_s=%s timeout_s=%s cleanup_s=%s total_s=%s starts=%s children=%s delta_vs_normal_s=%s\n' \
    "$scenario" "$rc" "$FORGE_V2_SCENARIO_GUARD" "$FORGE_V2_OUTER_SCENARIO_GUARD" "$timed_out" "$prep_elapsed" "$execution_elapsed" "$timeout_elapsed" "$cleanup_elapsed" "$total_elapsed" "$starts" "$children" "$delta"
  if [[ -f "$RUN_DIR/$scenario/verdict.json" ]]; then
    cat "$RUN_DIR/$scenario/verdict.json" >> "$SAFETY_LOG"
    printf '\n' >> "$SAFETY_LOG"
  fi
  printf '%s\n' '--- salida del ejecutor ---' >> "$SAFETY_LOG"
  if [[ -f "$scenario_log" ]]; then
    cat "$scenario_log" >> "$SAFETY_LOG"
  fi
  if ((cleanup_failed)); then
    printf 'FAIL escenario %s: limpieza exterior incompleta; RC=%s\n' "$scenario" "$rc"
    return 1
  fi
  # A nonzero runner RC remains a global failure, but subsequent scenarios
  # still run sequentially to preserve complete, independent evidence.
  printf 'SCENARIO_COMPLETION scenario=%s runner_rc=%s cleanup_failed=0 timed_out=%s\n' "$scenario" "$rc" "$timed_out"
  return 0
}

finish_verifier() {
  local rc=$? scenario rc_line
  trap - EXIT INT TERM
  set +e
  if [[ -n "$ACTIVE_SCENARIO_LAUNCH_PID" ]]; then
    cleanup_active_scenario || rc=1
  fi
  if check_residual_pid salida "$RUN_DIR/pid-530393-final.tsv"; then
    PID_FINAL_OK=1
  else
    PID_FINAL_OK=0
    rc=1
  fi
  {
    printf '# Resumen de ejecución GLOBAL VERIFIER\n\n'
    printf -- "- Run: \`%s\`\n- RC global: \`%s\`\n- PID 530393 final: \`%s\`\n" "$RUN_DIR" "$rc" "$([[ "$PID_FINAL_OK" == 1 ]] && echo vivo-identidad-y-servicio-verificados || echo fallo-de-verificacion)"
    printf -- "- Limpieza exterior: \`%s\`\n" "$([[ -z "$ACTIVE_SCENARIO_PID" ]] && echo sin-ejecucion-activa || echo fallo)"
    printf -- "- Guard de interfaz: \`%s\` s; guard exterior independiente del verificador: \`%s\` s.\n" "$FORGE_V2_SCENARIO_GUARD" "$FORGE_V2_OUTER_SCENARIO_GUARD"
    printf -- "- Semántica RC: interfaz RC 13 (plazos contradictorios), 14 (guard vencido con limpieza acreditada) y 15 (guard vencido con limpieza incompleta) son fallos duros; cualquier RC ejecutor distinto de 0 hace no-cero el RC global. No se reinterpretan como \`supervisor_rc\` ni \`suite_rc\`: esos RC por capa provienen de \`verdict.json\` y \`safety-results.json\` (\`cleanup.suite_returncode\`).\n"
    if [[ "$FORGE_V2_GUARD_EXPIRY_PROBE" == 1 ]]; then
      local probe_runner_rc probe_guard_status
      probe_runner_rc="$(awk -F '\t' '$1 == "no-pidfd-hang" { print $2; exit }' "$SCENARIO_RC_FILE")"
      probe_guard_status=ausente
      if [[ -s "$RUN_DIR/no-pidfd-hang/guard-integration-verdict.json" ]]; then
        if grep -Eq '"status"[[:space:]]*:[[:space:]]*"PASS"' "$RUN_DIR/no-pidfd-hang/guard-integration-verdict.json"; then
          probe_guard_status=PASS
        else
          probe_guard_status=FAIL
        fi
      fi
      printf -- "- Prueba negativa de guard vencido: escenario \`no-pidfd-hang\`, RC del ejecutor \`%s\`, validación independiente \`%s\`; el RC global no-cero es obligatorio y no equivale a un fallo inesperado de la ejecución autónoma satisfactoria.\n\n" "${probe_runner_rc:-ausente}" "$probe_guard_status"
    else
      printf '\n'
    fi
    printf '## Verificaciones globales/normal\n\n'
    if ! grep -E '^(PASS|N/A|FAIL)' "$RUN_LOG"; then
      printf -- 'Sin resultados globales adicionales registrados.\n'
    fi
    printf '\n'
    for scenario in normal no-pidfd no-pidfd-hang; do
      printf "## Escenario \`%s\`\n\n" "$scenario"
      rc_line='no ejecutado'
      if [[ -f "$SCENARIO_RC_FILE" ]]; then
        rc_line="$(awk -F '\t' -v s="$scenario" '$1 == s { print "RC=" $2; found=1 } END { if (!found) print "no ejecutado" }' "$SCENARIO_RC_FILE")"
      fi
      printf -- "- RC del ejecutor: \`%s\`\n" "$rc_line"
      if [[ -f "$RUN_DIR/$scenario/verdict.md" ]]; then
        printf '\n'
        cat "$RUN_DIR/$scenario/verdict.md"
      else
        printf -- '- Evidencia/verdict ausente.\n'
      fi
      if [[ -f "$RUN_DIR/$scenario/guard-integration-verdict.json" ]]; then
        printf '\nVerificación independiente de la evidencia de guard vencido:\n\n```json\n'
        cat "$RUN_DIR/$scenario/guard-integration-verdict.json"
        printf '```\n'
      fi
      if [[ -f "$RUN_DIR/$scenario/guard-expiry.json" || -f "$RUN_DIR/$scenario/guard-verdict.json" ]]; then
        printf "\nEvidencia original del guard vencido conservada bajo \`%s\`: " "$RUN_DIR/$scenario"
        for guard_file in guard-expiry.json guard-verdict.json; do
          [[ -s "$RUN_DIR/$scenario/$guard_file" ]] && printf "\`%s\` " "$guard_file"
        done
        printf '\n'
      fi
      if [[ "$scenario" == no-pidfd-hang ]]; then
        printf '\n**Límite semántico:** la inyección ocurrió antes de la barrera; no se atribuye rechazo de autorización, que no llegó a evaluarse.\n'
      fi
      printf '\n'
    done
    printf '## Capas, tiempos y limpieza\n\n'
    if [[ -f "$SCENARIO_TIMINGS" ]]; then
      printf '```tsv\n'
      cat "$SCENARIO_TIMINGS"
      printf '```\n\n'
    else
      printf -- 'No hay registros de tiempos de escenario.\n\n'
    fi
    printf 'Grupos propios creados en esta ejecución (miembros vivos antes/después de la limpieza exterior):\n\n```tsv\n'
    if [[ -f "$OWN_GROUP_LOG" ]]; then
      cat "$OWN_GROUP_LOG"
    fi
    printf '```\n\n'
    printf '## Limpieza excepcional de recursos interiores\n\n'
    printf 'En timeout exterior, interrupción o error, el grupo de escenario se congela por su identidad registrada; el launcher/suite de su sesión propia se termina y se espera su ausencia antes de retirar al supervisor. La tabla conserva PID + start ticks, sesiones y comprobación final de los miembros.\n\n```tsv\n'
    if [[ -f "$EXCEPTIONAL_CLEANUP_LOG" ]]; then
      cat "$EXCEPTIONAL_CLEANUP_LOG"
    else
      printf 'Sin rutas excepcionales activadas.\n'
    fi
    printf '```\n\n'
    printf -- "- Estado final PID: consulte \`pid-530393-final.tsv\`; sin señales ni relanzamiento.\n"
    printf -- "- Verificaciones normales/globales: consulte \`forge-v2-followups-global.log\`; evidencias por escenario bajo \`normal/\`, \`no-pidfd/\`, \`no-pidfd-hang/\`.\n"
  } > "$SCENARIO_SUMMARY" || rc=1
  printf '\nVERIFIER_FINAL_RC=%s\n' "$rc" >> "$RUN_LOG"
  cat "$RUN_LOG" >&3
  cat "$SAFETY_LOG" >&3
  cat "$GUARD_LOG" >&3
  cat "$SCENARIO_SUMMARY" >&3
  exit "$rc"
}

: > "$RUN_LOG"
: > "$SAFETY_LOG"
: > "$GUARD_LOG"
: > "$GUARD_OPS_LOG"
: > "$SCENARIO_RC_FILE"
: > "$OWN_GROUP_LOG"
printf 'scenario\touter_guard_s\touter_group\tinner_group\tlauncher_pid@start\tlauncher_absent_before_supervisor\tlauncher_gone_final\tsuite_pid@start\tsuite_absent_before_supervisor\tsuite_gone_final\tsupervisor_pid@start\tsupervisor_gone_final\tinner_signalled\tinner_members_after\touter_members_after\touter_kill_sent\touter_wait_budget_s\tstatus\n' > "$EXCEPTIONAL_CLEANUP_LOG"
  printf 'scenario\tpreparation_s\texecution_s\ttimeout_s\tcleanup_s\ttotal_s\tnamespace_starts\tinjected_children\tdelta_vs_normal_s\n' > "$SCENARIO_TIMINGS"
exec 3>&1
exec >"$RUN_LOG" 2>&1
trap finish_verifier EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$REPO"
printf '%s\n' '=== forge-v2-followups autonomous verifier ==='
test "$FORGE_V2_EXTERNAL_ROOT" = "$EXTERNAL"
test "$FORGE_V2_REAL_DB" = "$HOME/.local/share/opencode/opencode.db"
[[ "$FORGE_V2_HANG_TIMEOUT" =~ ^[1-9][0-9]*$ ]]
[[ "$FORGE_V2_SCENARIO_GUARD" =~ ^[1-9][0-9]*$ ]]
[[ "$FORGE_V2_OUTER_SCENARIO_GUARD" =~ ^[1-9][0-9]*$ ]]
((FORGE_V2_OUTER_SCENARIO_GUARD >= 600))
[[ "$FORGE_V2_GUARD_EXPIRY_PROBE" == 0 || "$FORGE_V2_GUARD_EXPIRY_PROBE" == 1 ]]
case "$FORGE_V2_CLEANUP_BRANCH_PROBE" in
  ''|outer-identity-unaccredited|freeze-failed|inner-absent-before-false) ;;
  *) printf 'FAIL: FORGE_V2_CLEANUP_BRANCH_PROBE no reconocido: %s\n' "$FORGE_V2_CLEANUP_BRANCH_PROBE"; exit 1 ;;
esac
if [[ "$FORGE_V2_GUARD_EXPIRY_PROBE" == 1 ]]; then
  ((FORGE_V2_SCENARIO_GUARD <= 30))
fi
printf 'Plazos independientes: interfaz=%ss; guard exterior=%ss.\n' "$FORGE_V2_SCENARIO_GUARD" "$FORGE_V2_OUTER_SCENARIO_GUARD"
if [[ "$FORGE_V2_GUARD_EXPIRY_PROBE" == 1 ]]; then
  printf '%s\n' 'Modo prueba negativa explícito: solo no-pidfd-hang; el RC 14/15 esperado sigue siendo fallo duro del verificador global.'
fi
printf 'Evidencia nueva de esta ejecución: %s\n' "$RUN_DIR"
if [[ -n "$CHECKPOINT_DIR" ]]; then
  test -d "$CHECKPOINT_DIR"
  test ! -L "$CHECKPOINT_DIR"
  test "$(cd "$CHECKPOINT_DIR" && pwd -P)" = "$BASE/checkpoint"
fi
test "$(git branch --show-current)" = fix/v2-safety-followups
test -s "$CHECKPOINT"
EXPECTED_CHECKPOINT=f0b5f568158cc189117ecd50ee2d79a5bf6e64c5
RECORDED_CHECKPOINT="$(cat "$CHECKPOINT")"
CURRENT_HEAD="$(git rev-parse HEAD)"
if [[ "$RECORDED_CHECKPOINT" != "$EXPECTED_CHECKPOINT" ]]; then
  if git merge-base --is-ancestor "$EXPECTED_CHECKPOINT" "$CURRENT_HEAD"; then
    EXPECTED_IS_ANCESTOR=yes
  else
    EXPECTED_IS_ANCESTOR=no
  fi
  printf 'FAIL: checkpoint registrado esperado %s, encontrado %s; HEAD actual %s; checkpoint esperado es ancestro: %s\n' \
    "$EXPECTED_CHECKPOINT" "$RECORDED_CHECKPOINT" "$CURRENT_HEAD" "$EXPECTED_IS_ANCESTOR"
  exit 1
fi
if git merge-base --is-ancestor "$EXPECTED_CHECKPOINT" "$CURRENT_HEAD"; then
  printf 'PASS: checkpoint esperado %s; HEAD actual %s; checkpoint es ancestro: sí; árbol deliberadamente no limpio.\n' \
    "$EXPECTED_CHECKPOINT" "$CURRENT_HEAD"
else
  printf 'FAIL: checkpoint esperado %s; HEAD actual %s; checkpoint es ancestro: no\n' \
    "$EXPECTED_CHECKPOINT" "$CURRENT_HEAD"
  exit 1
fi
test -s /tmp/opencode/forge-v2-followups-checkpoint/external.sha256
test -s /tmp/opencode/forge-v2-followups-checkpoint/approved.patch
test -s /tmp/opencode/forge-v2-remediation/backup/SHA256SUMS

if ! check_residual_pid preflight "$RUN_DIR/pid-530393-preflight.tsv"; then
  exit 1
fi

git diff --check
printf '%s\n' 'PASS: git diff --check'

bash -n open-code/forge-opencode.sh
bash -n install.sh
bash -n "$EXTERNAL/cutover.sh"
bash -n "$EXTERNAL/ROLLBACK.sh"
bash -n tests/forge_guard_plugin_unit.sh
bash -n tests/forge_v2_safety.sh
bash -n tests/forge_v2_safety_scenarios.sh
bash -n tools/verification/forge-v2-followups.sh
printf '%s\n' 'PASS: bash -n de launcher, install.sh, cutover.sh, ROLLBACK.sh, suites normal/escenarios y verificador.'

python3 tools/verification/verify-forge-v2-syntax.py \
  --repo-root "$REPO" \
  --external-root "$EXTERNAL" \
  --output "$SYNTAX_CATALOG"

sha256sum -c "$BACKUP/SHA256SUMS"
(
  cd "$EXTERNAL_BACKUP"
  sha256sum -c ../external.sha256
)
(
  cd "$EXTERNAL"
  sha256sum -c "$PREVIOUS_EVIDENCE/external-after.sha256"
)

if [[ -n "$CHECKPOINT_DIR" ]]; then
  test -d "$CHECKPOINT_DIR"
  test ! -L "$CHECKPOINT_DIR"
  test -s "$CHECKPOINT_DIR/manifest.md"
  test ! -L "$CHECKPOINT_DIR/manifest.md"
  test -s "$CHECKPOINT_DIR/pid-530393.json"
  test ! -L "$CHECKPOINT_DIR/pid-530393.json"
  test -s "$CHECKPOINT_DIR/integrity.sha256"
  test ! -L "$CHECKPOINT_DIR/integrity.sha256"
  (
    cd "$CHECKPOINT_DIR"
    sha256sum -c integrity.sha256 > "$RUN_DIR/checkpoint-integrity.txt"
  )
fi

python3 - "$PREVIOUS_EVIDENCE/external-after.sha256" "$CHECKPOINT_DIR" "$RUN_DIR/checkpoint-pid-validation.json" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1])
checkpoint_dir = sys.argv[2]
validation_path = pathlib.Path(sys.argv[3])
names = {line.split(None, 1)[1].lstrip("* ") for line in manifest.read_text().splitlines() if line.strip()}
expected = {
    "cutover.sh",
    "ROLLBACK.sh",
    "CUTOVER-NOTES.md",
    "lib/dbtool.py",
    "REMEDIATION-REPORT.md",
    "lib/cutover_safety.py",
}
missing = sorted(expected - names)
extra = sorted(names - expected)
if missing or extra:
    raise SystemExit(f"external manifest mismatch: missing={missing}, extra={extra}")
print("PASS: manifiesto externo contiene exactamente los seis componentes requeridos, incluida lib/cutover_safety.py")
validation = {"checkpoint_configured": bool(checkpoint_dir), "checkpoint_pid_match": None}
if checkpoint_dir:
    root = pathlib.Path(checkpoint_dir)
    pid_path = root / "pid-530393.json"
    if pid_path.is_symlink() or not pid_path.is_file():
        raise SystemExit("checkpoint PID identity is absent, symlinked, or not a regular file")
    checkpoint = json.loads(pid_path.read_text(encoding="utf-8"))
    identity = checkpoint.get("identity") or {}
    expected_cmdline = [
        "/tmp/opencode/cutover-lab/xdg/data/forge/opencode-v2/node_modules/.bin/opencode",
        "serve", "--hostname", "127.0.0.1", "--port", "34765", "--print-logs",
    ]
    expected_exe = "/tmp/opencode/cutover-lab/xdg/data/forge/opencode-v2/node_modules/@opencode/cli/bin/opencode.exe (deleted)"
    service = checkpoint.get("service_expected") or {}
    listen_rows = service.get("verified_listen_rows") or []
    expected_listen_row = any(
        row.get("table") == "/proc/net/tcp"
        and row.get("local") == "0100007F:87CD"
        and row.get("state") == "0A"
        and bool(row.get("inode"))
        for row in listen_rows
    )
    expected_state = checkpoint.get("state")
    if (
        identity.get("pid") != 530393
        or str(identity.get("start_ticks")) != "26522468"
        or identity.get("boot_id") != "3df94600-d3e9-4486-879b-452396bca532"
        or identity.get("uid") != [1000, 1000, 1000, 1000]
        or identity.get("executable") != expected_exe
        or identity.get("cmdline") != expected_cmdline
        or not isinstance(expected_state, str)
        or expected_state in ("Z", "X")
        or checkpoint.get("non_terminated") is not True
        or service.get("protocol") != "tcp"
        or service.get("bind") != "127.0.0.1"
        or service.get("port") != 34765
        or service.get("command") != expected_cmdline[1:]
        or not expected_listen_row
        or service.get("pid_fd_socket_matches_listen") is not True
    ):
        raise SystemExit("checkpoint PID/service identity does not match the documented residual server invariants")
    validation["checkpoint_pid_match"] = True
    validation["pid"] = identity["pid"]
    validation["start_ticks"] = str(identity["start_ticks"])
    validation["boot_id"] = identity["boot_id"]
    validation["executable"] = identity["executable"]
    validation["cmdline"] = identity["cmdline"]
    validation["service_expected"] = service
    print("PASS: checkpoint inmutable acredita PID 530393, identidad estable y servicio 127.0.0.1:34765")
validation_path.write_text(json.dumps(validation, indent=2, sort_keys=True) + "\n", encoding="utf-8")
validation_path.chmod(0o600)
PY

if [[ -n "$CHECKPOINT_DIR" ]]; then
  if ! check_residual_pid checkpoint-preflight "$RUN_DIR/pid-530393-checkpoint-preflight.tsv"; then
    exit 1
  fi
fi

python3 tools/verification/prepare-sandbox.py > "$PREPARE_EVIDENCE"
cat "$PREPARE_EVIDENCE"

for directory in home config data state cache; do
  test -d "$SYNTHETIC/$directory"
done
python3 - "$SYNTHETIC" <<'PY'
import json
import os
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
marker = json.loads((root / ".forge-v2-followups-synthetic.json").read_text())
assert marker["resources"] == "synthetic-only"
assert marker["database_created"] is False and marker["database_copied"] is False
assert marker["credentials_copied"] is False and marker["runtime_launched"] is False
for name in ("home", "config", "data", "state", "cache"):
    directory = root / name
    info = directory.stat(follow_symlinks=False)
    assert stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
    assert stat.S_IMODE(info.st_mode) == 0o700
for path in root.rglob("*"):
    assert not path.is_symlink(), f"symlink in synthetic tree: {path}"
    assert path.name not in {
        "auth.json", ".opencode-tokens", "opencode.db", "opencode.db-wal",
        "opencode.db-shm", "opencode.db-journal",
    }, f"credential/database artifact in synthetic tree: {path}"
print("PASS: sandbox 0700 privado; no contiene DB, credenciales ni symlinks")
PY

sha256sum -c "$BACKUP/SHA256SUMS"
for directory in home config data state cache; do
  test -d "$SYNTHETIC/$directory"
done

PINNED_BINARY=/home/espinilleitor/.local/share/forge/opencode-v2/node_modules/.bin/opencode
test -x "$PINNED_BINARY"
env -i \
  HOME="$SYNTHETIC/home" \
  XDG_CONFIG_HOME="$SYNTHETIC/config" \
  XDG_DATA_HOME="$SYNTHETIC/data" \
  XDG_STATE_HOME="$SYNTHETIC/state" \
  XDG_CACHE_HOME="$SYNTHETIC/cache" \
  PYTHONDONTWRITEBYTECODE=1 \
  PATH=/usr/bin:/bin \
  FORGE_OPENCODE_BIN="$PINNED_BINARY" \
  OPENCODE_DISABLE_AUTOUPDATE=1 \
  OPENCODE_DISABLE_MODELS_FETCH=1 \
  OPENCODE_DISABLE_CHANNEL_DB=1 \
  OPENCODE_DISABLE_FILEWATCHER=1 \
  bash open-code/forge-opencode.sh --version > "$RUN_DIR/synthetic-version.stdout" 2> "$RUN_DIR/synthetic-version.stderr"
python3 - "$RUN_DIR/synthetic-version.stdout" "$RUN_DIR/synthetic-version.stderr" <<'PY'
import pathlib
import sys

stdout = pathlib.Path(sys.argv[1]).read_text().strip()
stderr = pathlib.Path(sys.argv[2]).read_text()
if stdout != "opencode v2.1.4" or stderr:
    raise SystemExit(f"version mismatch: stdout={stdout!r}, stderr={stderr!r}")
print(f"PASS: launcher --version bajo HOME/XDG sintéticos: {stdout}")
PY

test -s "$EXTERNAL/REMEDIATION-REPORT.md"
printf '%s\n' 'PASS: informe externo de remediación no vacío.'

# The following old GLOBAL VERIFIER runtime checks intentionally require the
# removed real database/session state or original credentials. Do not substitute
# fake output: their previous isolated positive evidence is cited in acceptance.md.
printf '%s\n' 'N/A lote actual: auth list/JSON y session list no se ejecutan sin credenciales/DB; se conserva evidencia histórica en REMEDIATION-REPORT.md § GLOBAL VERIFIER autónomo y matriz (líneas 1184-1224 y 1479-1501).'
printf '%s\n' 'N/A lote actual: plugin list, install.sh status y doctor requieren runtime/overlay y diagnósticos con DB; no se conecta runtime a DB original ni se crea DB para migración. Evidencia positiva histórica: REMEDIATION-REPORT.md líneas 1184-1224 y 1479-1501.'

git status --porcelain=v1 --untracked-files=all > "$RUN_DIR/repo-status-before-suites.txt"
find /tmp -mindepth 1 -maxdepth 1 -type d -name 'forge-guard-unit.*' -printf '%f\n' | LC_ALL=C sort > "$RUN_DIR/guard-tmp-before.txt"
find "$RUN_DIR" -mindepth 1 -type d -name 'safety-run-*' -printf '%p\n' | LC_ALL=C sort > "$RUN_DIR/safety-roots-before.txt"
test ! -s "$RUN_DIR/safety-roots-before.txt"
python3 - "$REPO" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
residues = sorted(
    str(path.relative_to(root))
    for path in root.rglob("*")
    if path.name == "__pycache__" or path.suffix == ".pyc" or path.name.endswith(".tmp")
)
if residues:
    raise SystemExit("pre-existing generated Python/temp residue blocks verifier: " + ", ".join(residues))
print("PASS: preflight del repo sin cachés Python ni temporales.")
PY
export FORGE_GUARD_OPS_LOG="$GUARD_OPS_LOG"
export TMPDIR=/tmp
export PYTHONDONTWRITEBYTECODE=1
if [[ "$FORGE_V2_GUARD_EXPIRY_PROBE" == 1 ]]; then
  run_scenario no-pidfd-hang
  PROBE_RC="$(awk -F '\t' '$1 == "no-pidfd-hang" { print $2; exit }' "$SCENARIO_RC_FILE")"
  PROBE_GUARD_STATUS=ausente
  if [[ -s "$RUN_DIR/no-pidfd-hang/guard-integration-verdict.json" ]]; then
    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"PASS"' "$RUN_DIR/no-pidfd-hang/guard-integration-verdict.json"; then
      PROBE_GUARD_STATUS=PASS
    else
      PROBE_GUARD_STATUS=FAIL
    fi
  fi
  if [[ "$PROBE_RC" == 14 && "$PROBE_GUARD_STATUS" == PASS && "$SCENARIO_FAILURE" == 1 ]]; then
    printf 'PASS prueba negativa: ejecutor=no-pidfd-hang devolvió RC 14, guard-expiry y guard-verdict fueron acreditados; este RC del ejecutor mantiene el RC global distinto de cero.\n'
  else
    printf 'FAIL prueba negativa: ejecutor=%s, guard-verification=%s, scenario_failure=%s; no se acepta como integración probada.\n' \
      "${PROBE_RC:-ausente}" "$PROBE_GUARD_STATUS" "$SCENARIO_FAILURE"
    SCENARIO_FAILURE=1
  fi
  exit 1
fi
run_scenario normal
run_scenario no-pidfd
run_scenario no-pidfd-hang
if ((SCENARIO_FAILURE)); then
  printf '%s\n' 'FAIL: una o más invocaciones de escenario devolvieron RC distinto de 0 o dispararon el guard exterior.'
fi
bash tests/forge_guard_plugin_unit.sh > "$GUARD_LOG" 2>&1
if ((SCENARIO_FAILURE)); then
  exit 1
fi
if ! check_residual_pid salida-pre-resumen "$RUN_DIR/pid-530393-final.tsv"; then
  exit 1
fi

python3 - "$RUN_DIR/normal/safety-results.json" "$RUN_DIR/normal/verdict.json" "$GUARD_LOG" "$GUARD_OPS_LOG" "$GUARD_SUMMARY" "$RUN_DIR/pid-530393-preflight.tsv" "$RUN_DIR/pid-530393-final.tsv" "$RUN_DIR/checkpoint-pid-validation.json" "$RUN_DIR/no-pidfd/verdict.json" "$RUN_DIR/no-pidfd-hang/verdict.json" "$SCENARIO_RC_FILE" "$SCENARIO_TIMINGS" <<'PY'
import json
import csv
import os
import pathlib
import re
import stat
import sys

safety_path, normal_verdict_path, guard_log_path, operations_path, guard_summary_path = map(pathlib.Path, sys.argv[1:6])
pid_preflight_path, pid_final_path, checkpoint_validation_path, no_pidfd_verdict_path, hang_verdict_path = map(pathlib.Path, sys.argv[6:11])
safety_runner_rc_path = pathlib.Path(sys.argv[11])
scenario_timings_path = pathlib.Path(sys.argv[12])
run_root = normal_verdict_path.parent.parent
for scenario in ("normal", "no-pidfd", "no-pidfd-hang"):
    scenario_dir = run_root / scenario
    required_evidence = (
        "safety-results.json", "supervisor.stdout.tsv", "supervisor.stderr", "verdict.json", "verdict.md",
    )
    absent = [name for name in required_evidence if not (scenario_dir / name).is_file() or not (scenario_dir / name).stat().st_size]
    if absent:
        raise SystemExit(f"{scenario} scenario evidence absent/empty: {absent}")
safety = json.loads(safety_path.read_text(encoding="utf-8"))
normal_verdict = json.loads(normal_verdict_path.read_text(encoding="utf-8"))
no_pidfd_verdict = json.loads(no_pidfd_verdict_path.read_text(encoding="utf-8"))
hang_verdict = json.loads(hang_verdict_path.read_text(encoding="utf-8"))
guard_output = guard_log_path.read_text(encoding="utf-8")
operations = operations_path.read_text(encoding="utf-8").splitlines()

runner_rcs = {}
for raw in safety_runner_rc_path.read_text(encoding="utf-8").splitlines():
    fields = raw.split("\t")
    if len(fields) >= 3:
        runner_rcs[fields[0]] = int(fields[1])
if runner_rcs != {"normal": 0, "no-pidfd": 0, "no-pidfd-hang": 0}:
    raise SystemExit(f"scenario runner RCs incomplete or nonzero: {runner_rcs}")
timing_rows = list(csv.DictReader(scenario_timings_path.open(encoding="utf-8"), delimiter="\t"))
if [row.get("scenario") for row in timing_rows] != ["normal", "no-pidfd", "no-pidfd-hang"]:
    raise SystemExit(f"scenario timing records missing or out of order: {timing_rows!r}")
for row in timing_rows:
    for key in ("preparation_s", "execution_s", "timeout_s", "cleanup_s", "total_s", "delta_vs_normal_s"):
        try:
            value = float(row[key])
        except (KeyError, ValueError) as exc:
            raise SystemExit(f"missing/non-numeric {key} for {row.get('scenario')}: {row!r}") from exc
        # A delta may be negative: both intentional-negative routes are
        # shorter than the 99s normal route. Durations themselves cannot be.
        if key != "delta_vs_normal_s" and value < 0:
            raise SystemExit(f"negative {key} for {row.get('scenario')}: {row!r}")
    if int(row["namespace_starts"]) < 1:
        raise SystemExit(f"no namespace start registered for {row['scenario']}: {row!r}")
if float(timing_rows[2]["timeout_s"]) <= 0 or any(float(row["timeout_s"]) != 0 for row in timing_rows[:2]):
    raise SystemExit(f"timeout timing does not distinguish only the intentional hang case: {timing_rows!r}")
if [int(row["injected_children"]) for row in timing_rows] != [0, 0, 1]:
    raise SystemExit(f"actual injected-child counts differ from the scenario contract: {timing_rows!r}")

def validate_verdict(name, verdict, supervisor_rc, suite_rc):
    if verdict.get("scenario") != name or verdict.get("ok") is not True or verdict.get("exit_code") != 0:
        raise SystemExit(f"{name} scenario executor did not return a successful semantic verdict: {verdict}")
    if verdict.get("supervisor_rc") != supervisor_rc:
        raise SystemExit(f"{name} supervisor RC mismatch: {verdict.get('supervisor_rc')} != {supervisor_rc}")
    actual_suite = verdict.get("suite_rc")
    if suite_rc == "nonzero":
        if actual_suite in (None, 0):
            raise SystemExit(f"{name} suite RC must be nonzero, got {actual_suite!r}")
    elif actual_suite != suite_rc:
        raise SystemExit(f"{name} suite RC mismatch: {actual_suite!r} != {suite_rc!r}")
    checks = verdict.get("checks") or []
    if (
        not checks
        or verdict.get("checks_total") != len(checks)
        or verdict.get("checks_failed") != 0
        or any(item.get("ok") is not True or not item.get("name") or not item.get("detail") for item in checks)
    ):
        raise SystemExit(f"{name} semantic checks missing or failed: {checks!r}")
    timings = verdict.get("timings") or {}
    if not isinstance(timings.get("arranques_namespace"), int) or timings["arranques_namespace"] < 1:
        raise SystemExit(f"{name} does not record a real namespace start count: {timings!r}")
    if not isinstance(timings.get("monotonic_wall_total_s"), (int, float)) or timings["monotonic_wall_total_s"] <= 0:
        raise SystemExit(f"{name} does not record a positive monotonic scenario duration: {timings!r}")

validate_verdict("normal", normal_verdict, 0, 0)
validate_verdict("no-pidfd", no_pidfd_verdict, 6, 4)
validate_verdict("no-pidfd-hang", hang_verdict, 6, -9)

if not pid_preflight_path.is_file() or not pid_final_path.is_file():
    raise SystemExit("PID 530393 preflight/final identity evidence is absent")
pid_preflight = pid_preflight_path.read_text(encoding="utf-8").rstrip("\n").split("\t")
pid_final = pid_final_path.read_text(encoding="utf-8").rstrip("\n").split("\t")
if len(pid_preflight) != 7 or len(pid_final) != 7:
    raise SystemExit("PID 530393 identity evidence is incomplete")
for label, row in (("preflight", pid_preflight), ("final", pid_final)):
    if row[0] != "530393" or row[1] != "26522468" or row[2] != "3df94600-d3e9-4486-879b-452396bca532" or row[3] != "1000" or row[4] in ("Z", "X"):
        raise SystemExit(f"PID 530393 {label} stable identity/state mismatch: {row!r}")
if pid_preflight[1:4] + pid_preflight[5:7] != pid_final[1:4] + pid_final[5:7]:
    raise SystemExit("PID 530393 stable identity changed between preflight and final check")
checkpoint_validation = json.loads(checkpoint_validation_path.read_text(encoding="utf-8"))
if checkpoint_validation.get("checkpoint_configured") and checkpoint_validation.get("checkpoint_pid_match") is not True:
    raise SystemExit("configured closure checkpoint does not match PID 530393 stable identity")
if checkpoint_validation.get("checkpoint_configured"):
    checkpoint_cmdline = "\x1f".join(checkpoint_validation["cmdline"])
    if (
        checkpoint_validation.get("pid") != int(pid_final[0])
        or checkpoint_validation.get("start_ticks") != pid_final[1]
        or checkpoint_validation.get("boot_id") != pid_final[2]
        or checkpoint_validation.get("executable") != pid_final[5]
        or checkpoint_cmdline != pid_final[6]
    ):
        raise SystemExit("final PID 530393 identity does not match checkpoint/pid-530393.json")

containment = safety.get("containment") or {}
cleanup = safety.get("cleanup") or {}
summary = safety.get("summary") or {}
supervisor = safety.get("supervisor") or {}
checks = containment.get("checks") or []
required_checks = {
    "pid_interno_1", "ns_pid_privada", "ns_user_privada", "ns_mnt_privada",
    "proc_montado_privado", "proc_sin_hidepid", "uid_mapeado_root", "pidfd_disponible",
}
if containment.get("ok") is not True or containment.get("pid_interno") != "1":
    raise SystemExit("safety evidence lacks accredited PID namespace containment")
if containment.get("ns_pid") == containment.get("host_ns_pid"):
    raise SystemExit("safety evidence does not distinguish private/host PID namespace")
if {item.get("check") for item in checks if item.get("ok") is True} != required_checks:
    raise SystemExit("safety containment check inventory is incomplete or failed")
if cleanup.get("authorization_granted") is not True or supervisor.get("authorization", {}).get("granted") is not True:
    raise SystemExit("authorization barrier is not recorded as granted")
if cleanup.get("watchdog_operational") is not True or not cleanup.get("watchdog_detail"):
    raise SystemExit("watchdog is not recorded as operational")
if cleanup.get("ok") is not True or cleanup.get("suite_returncode") != 0 or cleanup.get("timed_out") is not False:
    raise SystemExit("supervisor cleanup/deadline contract did not pass")
if cleanup.get("survivors_in_private_namespace") or cleanup.get("members_of_own_process_group"):
    raise SystemExit("safety report records surviving process resources")
if cleanup.get("namespace_init_alive_after") is not False or cleanup.get("namespace_init_gone_after") is not True:
    raise SystemExit("private namespace init cleanup is not verified")
if cleanup.get("synthetic_root_present_after") is not False:
    raise SystemExit("synthetic safety root survived cleanup")
if summary.get("total") != 52 or summary.get("passed") != 52 or summary.get("failed") != 0:
    raise SystemExit(f"unexpected safety case summary: {summary}")
if cleanup.get("private_pid_namespace") is None:
    raise SystemExit("fresh safety report does not identify its private PID namespace")
if any(item.get("verified_absent_after_cleanup") is False for item in cleanup.get("resources", [])):
    raise SystemExit("fresh safety report contains a resource not verified absent")

def same_process_still_exists(pid, expected_start=None):
    proc = pathlib.Path("/proc") / str(pid)
    try:
        raw = (proc / "stat").read_text(encoding="ascii")
    except FileNotFoundError:
        return False
    fields = raw[raw.rfind(")") + 1 :].split()
    if expected_start is None:
        return True
    if len(fields) <= 19:
        raise SystemExit(f"cannot verify process start ticks for {pid}")
    return fields[19] == str(expected_start)

survivor_ids = []
for item in cleanup.get("resources", []):
    pid = item.get("pid")
    if pid is None:
        continue
    identity = item.get("identity") or {}
    if same_process_still_exists(pid, identity.get("start_time_ticks")):
        survivor_ids.append(item.get("id", str(pid)))
if survivor_ids:
    raise SystemExit("batch process identity still present after cleanup: " + ", ".join(survivor_ids))

passed_summaries = re.findall(r"(?m)^\s*Passed:\s*(\d+)\s*$", guard_output)
if len(passed_summaries) != 1:
    raise SystemExit(f"guard unit suite must report exactly one Passed: N summary; found {len(passed_summaries)}")
guard_passed = int(passed_summaries[0])
check_results = re.findall(r"(?m)^\s*(PASS|FAIL):[^\r\n]*$", guard_output)
guard_checks = len(check_results)
guard_failures = sum(result == "FAIL" for result in check_results)
if "FAIL:" in guard_output or guard_failures != 0:
    raise SystemExit("guard unit suite output contains a FAIL assertion")
if len(re.findall(r"(?m)^\s*ALL PASS\s*$", guard_output)) != 1:
    raise SystemExit("guard unit suite output must contain exactly one ALL PASS marker")
if not check_results:
    raise SystemExit("guard unit suite output contains no assertion result lines")
if guard_passed != guard_checks or any(result != "PASS" for result in check_results):
    raise SystemExit(
        f"guard unit suite count mismatch: Passed={guard_passed}, checks={guard_checks}, failures={guard_failures}"
    )
if not operations:
    raise SystemExit("guard git operations evidence is empty")
forbidden = [line for line in operations if line.startswith("PUSH_BLOCKED\t") or line.startswith("PROTECTED_COMMIT_BLOCKED\t")]
if forbidden:
    raise SystemExit("guard test attempted forbidden Git operation: " + repr(forbidden))
protected_commits = [
    line for line in operations
    if line.startswith("GIT\tcommit\t") and line.split("\t")[3] in {"master", "main", "dev"}
]
if protected_commits:
    raise SystemExit("guard test created a commit on a protected branch: " + repr(protected_commits))

guard_summary = {
    "checks": guard_checks,
    "failed": guard_failures,
    "passed": guard_passed,
    "status": "PASS",
}
guard_summary_path.write_text(json.dumps(guard_summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
guard_summary_path.chmod(0o600)
print("PASS semántico normal: contención PID/proc privada; watchdog pidfd operativo; autorización concedida.")
print(f"PASS semántico normal: {summary['passed']}/{summary['total']} casos; recursos reportados ausentes; sin procesos/raíces sintéticas supervivientes.")
print("PASS semántico no-pidfd: supervisor RC=6, suite RC=4, autorización denegada y ningún caso sensible (verdict del contrato).")
print("PASS semántico no-pidfd-hang: supervisor RC=6, suite RC=-9, timeout y limpieza sin atribuir rechazo de autorización (verdict del contrato).")
print("PASS PID residual: identidad estable intacta y LISTEN local 127.0.0.1:34765 antes/después; checkpoint comparado cuando se configuró.")
print(f"PASS semántico: forge-guard {guard_passed} PASS; sin push ni commits en ramas protegidas.")
PY

git status --porcelain=v1 --untracked-files=all > "$RUN_DIR/repo-status-after-suites.txt"
cmp "$RUN_DIR/repo-status-before-suites.txt" "$RUN_DIR/repo-status-after-suites.txt"
find /tmp -mindepth 1 -maxdepth 1 -type d -name 'forge-guard-unit.*' -printf '%f\n' | LC_ALL=C sort > "$RUN_DIR/guard-tmp-after.txt"
cmp "$RUN_DIR/guard-tmp-before.txt" "$RUN_DIR/guard-tmp-after.txt"
find "$RUN_DIR" -mindepth 1 -type d -name 'safety-run-*' -printf '%p\n' | LC_ALL=C sort > "$RUN_DIR/safety-roots-after.txt"
test ! -s "$RUN_DIR/safety-roots-after.txt"
python3 - "$REPO" "$RUN_DIR/repo-generated-residues.txt" <<'PY'
import pathlib
import sys
import os
import stat

root = pathlib.Path(sys.argv[1])
residue_path = pathlib.Path(sys.argv[2])
cache_dir = root / "open-code/lib/__pycache__"
if cache_dir.exists() or cache_dir.is_symlink():
    if cache_dir.is_symlink():
        raise SystemExit(f"refusing unexpected symlink cache path: {cache_dir}")
    directory_info = cache_dir.stat(follow_symlinks=False)
    if not stat.S_ISDIR(directory_info.st_mode) or directory_info.st_uid != os.getuid():
        raise SystemExit(f"refusing foreign/non-directory cache path: {cache_dir}")
    entries = list(cache_dir.iterdir())
    if len(entries) != 1:
        raise SystemExit(f"unexpected contents in generated cache directory: {entries!r}")
    bytecode = entries[0]
    if not bytecode.name.startswith("plugin-sync.") or bytecode.suffix != ".pyc" or bytecode.is_symlink():
        raise SystemExit(f"refusing unexpected generated cache file: {bytecode}")
    file_info = bytecode.stat(follow_symlinks=False)
    if not stat.S_ISREG(file_info.st_mode) or file_info.st_uid != os.getuid():
        raise SystemExit(f"refusing foreign/non-regular generated cache file: {bytecode}")
    bytecode.unlink()
    cache_dir.rmdir()
residues = sorted(
    str(path.relative_to(root))
    for path in root.rglob("*")
    if path.name == "__pycache__" or path.suffix == ".pyc" or path.name.endswith(".tmp")
)
residue_path.write_text("\n".join(residues) + ("\n" if residues else ""))
residue_path.chmod(0o600)
if residues:
    raise SystemExit("generated Python/temp residue remains in repository: " + ", ".join(residues))
print("PASS: sin __pycache__, .pyc ni temporales generados en el árbol del repo.")
PY
printf '%s\n' 'PASS: estado Git del repo sin residuos de suite; árboles temporales de safety/guard limpios.'

python3 - "$RUN_DIR/normal/safety-results.json" "$RUN_DIR/normal/verdict.json" "$RUN_DIR/forge-v2-followups-semantic.json" <<'PY'
import json
import pathlib
import sys

safety = json.loads(pathlib.Path(sys.argv[1]).read_text())
verdict = json.loads(pathlib.Path(sys.argv[2]).read_text())
cleanup = safety["cleanup"]
containment = safety["containment"]
result = {
    "status": "PASS",
    "containment": {
        "ok": containment["ok"],
        "private_pid_namespace": containment["ns_pid"],
        "host_pid_namespace": containment["host_ns_pid"],
        "private_proc": True,
    },
    "watchdog_operational": cleanup["watchdog_operational"],
    "authorization_granted": cleanup["authorization_granted"],
    "cleanup_ok": cleanup["ok"],
    "survivors_private_namespace": cleanup["survivors_in_private_namespace"],
    "survivors_process_group": cleanup["members_of_own_process_group"],
    "namespace_init_alive_after": cleanup["namespace_init_alive_after"],
    "synthetic_root_present_after": cleanup["synthetic_root_present_after"],
    "fresh_report_resources_verified_absent": all(
        item.get("verified_absent_after_cleanup") is not False for item in cleanup.get("resources", [])
    ),
    "scenario_verdict": {
        "scenario": verdict["scenario"],
        "exit_code": verdict["exit_code"],
        "checks_total": verdict["checks_total"],
        "checks_failed": verdict["checks_failed"],
    },
}
path = pathlib.Path(sys.argv[3])
path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
print(f"PASS: evidencia semántica guardada en {path}")
PY

python3 - "$RUN_DIR/acceptance.md" "$RUN_DIR/normal/verdict.json" "$RUN_DIR/no-pidfd/verdict.json" "$RUN_DIR/no-pidfd-hang/verdict.json" "$GUARD_SUMMARY" "$SCENARIO_TIMINGS" "$FORGE_V2_SCENARIO_GUARD" "$FORGE_V2_OUTER_SCENARIO_GUARD" <<'PY'
import json
import pathlib
import sys

output, normal_path, reject_path, hang_path, guard_path, timing_path = map(pathlib.Path, sys.argv[1:7])
interface_guard, outer_guard = sys.argv[7:9]
verdicts = [json.loads(path.read_text(encoding="utf-8")) for path in (normal_path, reject_path, hang_path)]
guard = json.loads(guard_path.read_text(encoding="utf-8"))
if any(item.get("ok") is not True or item.get("exit_code") != 0 for item in verdicts):
    raise SystemExit("refusing to record acceptance with an incomplete scenario verdict")
if [(item.get("supervisor_rc"), item.get("suite_rc")) for item in verdicts] != [(0, 0), (6, 4), (6, -9)]:
    if verdicts[2].get("suite_rc") in (None, 0) or [(item.get("supervisor_rc"), item.get("suite_rc")) for item in verdicts[:2]] != [(0, 0), (6, 4)]:
        raise SystemExit("scenario layer return codes differ from the delivered contract")
timings = timing_path.read_text(encoding="utf-8").rstrip()
lines = [
    "# Aceptación GLOBAL VERIFIER — evidencia por ejecución",
    "",
    "El verificador mantuvo su invocación autónoma y generó esta evidencia bajo una raíz nueva.",
    "La aceptación final del lote se completa en Step 3.2; este archivo es un registro de la ejecución.",
    "",
    f"Plazos independientes: guard de la interfaz {interface_guard} s; guard exterior del verificador {outer_guard} s (mínimo permitido: 600 s). El guard exterior no acorta la oportunidad de cleanup de la interfaz.",
    "Los RC de interfaz 14 (guard vencido con cleanup acreditado) y 15 (guard vencido con cleanup incompleto) son fallos duros; ninguno es verde ni se convierte en RC de supervisor/suite. Los RC de esas capas se leen de `verdict.json` (`supervisor_rc`, `suite_rc`) y `safety-results.json` (`cleanup.suite_returncode`).",
    "",
    "| Escenario | RC supervisor | RC suite | RC ejecutor | Comprobaciones semánticas |",
    "|---|---:|---:|---:|---|",
]
runner_rcs = {"normal": 0, "no-pidfd": 0, "no-pidfd-hang": 0}
for item in verdicts:
    checks = item.get("checks") or []
    if not checks or any(check.get("ok") is not True for check in checks):
        raise SystemExit(f"semantic evidence missing or failed: {item.get('scenario')}")
    runner = runner_rcs[item["scenario"]]
    suite_rc = item.get("suite_rc")
    lines.append(
        f"| `{item['scenario']}` | {item.get('supervisor_rc')} | {suite_rc} | {runner} | {len(checks)} PASS; verdict.json individual |"
    )
lines.extend([
    "",
    "El escenario `no-pidfd` acredita el rechazo antes de casos sensibles. `no-pidfd-hang` acredita timeout y limpieza externa sin pidfd; la inyección precede a la barrera y **no** se afirma que la autorización fuera evaluada.",
    "En esta ejecución normal no se produjo RC 14/15; la prueba negativa de guard vencido se conserva en su propia ejecución del verificador, cuyo RC global no-cero es esperado y no se mezcla con esta aceptación satisfactoria.",
    "",
    "## Tiempos monotónicos, arranques y diferencia frente a normal",
    "",
    "```tsv",
    timings,
    "```",
    "",
    f"forge-guard: {guard['passed']} PASS, {guard['failed']} FAIL.",
    "",
    "La identidad estable y el socket local del PID 530393 se verifican en preflight y salida; no se envían señales ni se relanza el proceso.",
])
output.write_text("\n".join(lines) + "\n", encoding="utf-8")
output.chmod(0o600)
print(f"PASS: resumen de aceptación por ejecución guardado en {output}")
PY

printf '%s\n' 'PASS: ejecución de GLOBAL VERIFIER completada; ruta normal y ambos escenarios negativos verificados semánticamente.'
printf 'Evidence: %s\n' "$RUN_DIR"
