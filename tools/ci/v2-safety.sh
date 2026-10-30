#!/usr/bin/env bash
# Reproducible entrypoint for the required Forge V2 safety scenarios.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
SCENARIO_RUNNER="$REPO_ROOT/tests/forge_v2_safety_scenarios.sh"
COMPONENT_ROOT="$REPO_ROOT/tools/cutover/forge-v2"

if ! bash "$REPO_ROOT/tools/verification/require-v2-containment.sh"; then
  echo "FALLO: el banco V2 no se ejecuta sin acreditacion previa de forge-contained-run.sh." >&2
  exit 78
fi

usage() {
  cat >&2 <<'EOF'
Uso:
  bash tools/ci/v2-safety.sh --all --artifacts-dir RUTA_NUEVA
  bash tools/ci/v2-safety.sh --preflight-only --artifacts-dir RUTA_NUEVA

Las rutas relativas de evidencia se resuelven desde la raíz del checkout.
EOF
}

mode=""
artifacts_arg=""
while (($#)); do
  case "$1" in
    --all|--preflight-only)
      if [[ -n "$mode" ]]; then
        echo "FALLO: indica exactamente un modo." >&2
        usage
        exit 1
      fi
      mode="$1"
      shift
      ;;
    --artifacts-dir)
      if [[ -n "$artifacts_arg" ]] || (($# < 2)) || [[ -z "$2" ]]; then
        echo "FALLO: --artifacts-dir requiere una ruta y solo puede indicarse una vez." >&2
        usage
        exit 1
      fi
      artifacts_arg="$2"
      shift 2
      ;;
    *)
      echo "FALLO: argumento no válido: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$mode" || -z "$artifacts_arg" ]]; then
  echo "FALLO: se requiere un modo y --artifacts-dir." >&2
  usage
  exit 1
fi

if [[ "$artifacts_arg" == /* ]]; then
  artifacts_path="$artifacts_arg"
else
  artifacts_path="$REPO_ROOT/$artifacts_arg"
fi

if [[ -e "$artifacts_path" || -L "$artifacts_path" ]]; then
  echo "FALLO: el directorio de evidencia debe ser nuevo; ya existe: $artifacts_arg" >&2
  exit 1
fi

artifacts_parent="$(dirname -- "$artifacts_path")"
artifacts_name="$(basename -- "$artifacts_path")"
if ! mkdir -p -- "$artifacts_parent" || ! mkdir -m 700 -- "$artifacts_parent/$artifacts_name"; then
  echo "FALLO: no se pudo crear en exclusiva el directorio de evidencia nuevo." >&2
  exit 1
fi
ARTIFACTS_DIR="$(cd -- "$artifacts_parent/$artifacts_name" && pwd -P)"
mkdir -m 700 -- "$ARTIFACTS_DIR/scenarios" "$ARTIFACTS_DIR/logs" "$ARTIFACTS_DIR/controls"

PYTHON_BIN="$(command -v python3 2>/dev/null || true)"
UNSHARE_BIN="$(command -v unshare 2>/dev/null || true)"
GIT_SHA="$(git -C "$REPO_ROOT" rev-parse --verify HEAD 2>/dev/null || printf 'unavailable')"
PYTHON_VERSION="$(python3 --version 2>&1 || printf 'unavailable')"
UNSHARE_VERSION="$(unshare --version 2>&1 | head -n 1 || printf 'unavailable')"
START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SECONDS=0
JOB_STATE="running"
PRECHECK_STATE="not-run"

cat >"$ARTIFACTS_DIR/timeout-calculation.txt" <<'EOF'
Presupuesto conservador para la secuencia completa (sin reducir los guards):
  normal: timeout interno del supervisor 300 s; guard exterior de escenario
    420 s para la ejecucion completa; hasta 50 s de cleanup del guard
    (gracia 20 s + waits de 15 s + 15 s de recuperacion). Limite del wrapper:
    420 + 50 = 470 s.
  no-pidfd: contrato esperado 0 s, pero el limite efectivo de fallo sigue siendo
    guard 420 s + hasta 50 s de cleanup = 470 s del wrapper.
  no-pidfd-hang: timeout interno esperado 20 s + hasta 1 s de deteccion = 21 s,
    pero su limite de fallo del wrapper tambien es 420 s + hasta 50 s de
    cleanup = 470 s.
  tras volver del wrapper, la interfaz espera hasta 420 s adicionales por
    procesos propios con --report-path. Si alguno sigue vivo al agotar la espera,
    el escenario falla con RC 14. Limite efectivo por escenario: 470 + 420 = 890 s.
  el timeout interno de 300 s de normal y los timeouts internos de cada escenario
    estan dentro del guard de 420 s; no se suman otra vez a ese guard.
  la secuencia conserva su politica: continua tras un fallo contractual solo
    con teardown y evidencia completos; un teardown incompleto detiene el loop.
    El limite secuencial que cubre ambos caminos es 890 + 890 + 890 = 2670 s.
    Si el proceso aun vive al agotar la espera, el escenario falla con RC 14 y
    sin teardown acreditado, asi que el loop se detiene; si el teardown queda
    acreditado, la secuencia puede continuar y se contabiliza el siguiente
    limite completo.
  preparacion/preflight: 60 s; agregacion y cierre de evidencias: 60 s;
    publicacion de artefactos: 300 s.
  presupuesto calculado: 2670 + 60 + 60 + 300 = 3090 s.
  presupuesto configurado de escenario+cierre: 3240 s de escenario + 60 s de
    gracia de cierre = 3300 s (55 minutos).
  timeout del job del workflow: 75 minutos (4500 s), con 1200 s (20 minutos)
    de margen sobre el presupuesto de escenario+cierre. El timeout del job
    tambien cubre checkout/preparacion y la publicacion de evidencias.

La secuencia continua tras un fallo contractual solo si el teardown y su
evidencia estan completos; se detiene ante teardown incompleto o no acreditado.
Un guard vencido conserva su RC de fallo y nunca se interpreta como exito.
EOF

cat >"$ARTIFACTS_DIR/run.txt" <<EOF
Forge V2 safety CI entrypoint
started_utc=$START_UTC
checkout_sha=$GIT_SHA
bash_version=$BASH_VERSION
python_version=$PYTHON_VERSION
unshare_version=$UNSHARE_VERSION
mode=$mode
expected_job_timeout_seconds=4500
expected_scenario_and_close_seconds=3300
job_margin_seconds=1200
EOF

finalize() {
  local exit_status="$1"
  local finished_utc elapsed
  finished_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  elapsed="$SECONDS"
  if [[ -n "$PYTHON_BIN" ]]; then
    "$PYTHON_BIN" - "$ARTIFACTS_DIR" "$mode" "$JOB_STATE" "$PRECHECK_STATE" \
      "$exit_status" "$START_UTC" "$finished_utc" "$elapsed" "$GIT_SHA" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
mode, state, preflight, rc, started, finished, elapsed, sha = sys.argv[2:]
results_path = root / "scenario-results.json"
try:
    scenarios = json.loads(results_path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    scenarios = []
summary = {
    "mode": mode,
    "status": state,
    "exit_code": int(rc),
    "preflight": preflight,
    "checkout_sha": sha,
    "started_utc": started,
    "finished_utc": finished,
    "elapsed_seconds": int(elapsed),
    "timeout_calculation": "timeout-calculation.txt",
    "scenarios": scenarios,
}
temporary = root / "job-summary.json.tmp"
temporary.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(root / "job-summary.json")
PY
  else
    printf 'status=%s\nexit_code=%s\npreflight=%s\n' \
      "$JOB_STATE" "$exit_status" "$PRECHECK_STATE" >"$ARTIFACTS_DIR/job-summary.txt"
  fi
}

if [[ -n "$PYTHON_BIN" ]]; then
  printf '[]\n' >"$ARTIFACTS_DIR/scenario-results.json"
fi

if [[ "$GIT_SHA" == unavailable ]]; then
  JOB_STATE="checkout-sha-unavailable"
  finalize 2
  exit 2
fi
if [[ -z "$PYTHON_BIN" ]]; then
  JOB_STATE="python3-unavailable"
  printf 'FALLO: python3 no está disponible; no se puede ejecutar el bench ni el preflight.\n' \
    >"$ARTIFACTS_DIR/preflight.log"
  PRECHECK_STATE="failed-python3-unavailable"
  finalize 2
  exit 2
fi

preflight_started="$(date +%s)"
if [[ ! -x "$UNSHARE_BIN" ]]; then
  PRECHECK_STATE="failed-unshare-unavailable"
  : >"$ARTIFACTS_DIR/preflight.stdout"
  printf 'FALLO: no se encontró unshare ejecutable; no se intenta degradar el aislamiento.\n' \
    >"$ARTIFACTS_DIR/preflight.stderr"
  preflight_rc=127
else
  parent_pidns="$(readlink /proc/self/ns/pid 2>/dev/null || printf unavailable)"
  parent_mntns="$(readlink /proc/self/ns/mnt 2>/dev/null || printf unavailable)"
  parent_userns="$(readlink /proc/self/ns/user 2>/dev/null || printf unavailable)"
  parent_uid="$(id -u)"
  set +e
  "$UNSHARE_BIN" --user --map-root-user --pid --fork --mount-proc \
    env V2_PARENT_PIDNS="$parent_pidns" V2_PARENT_MNTNS="$parent_mntns" \
      V2_PARENT_USERNS="$parent_userns" V2_PARENT_UID="$parent_uid" \
      "$PYTHON_BIN" - "$ARTIFACTS_DIR/preflight-probe.json" >"$ARTIFACTS_DIR/preflight.stdout" \
      2>"$ARTIFACTS_DIR/preflight.stderr" <<'PY'
import json
import os
import pathlib
import signal
import subprocess
import sys

destination = pathlib.Path(sys.argv[1])
result = {"ok": False, "checks": [], "pidfd_child": {}}
child = None
pidfd = None
child_start = None
pidfd_signals_sent = []
child_termination_signal = None


def add_check(name, ok, detail):
    result["checks"].append({"name": name, "ok": bool(ok), "detail": str(detail)})
    if not ok:
        raise RuntimeError(name + ": " + str(detail))


def proc_stat(pid):
    raw = pathlib.Path("/proc") .joinpath(str(pid), "stat").read_text(encoding="ascii")
    fields = raw[raw.rfind(")") + 2 :].split()
    return {"state": fields[0], "ppid": int(fields[1]), "start_ticks": fields[19]}


try:
    current_pidns = os.readlink("/proc/self/ns/pid")
    current_mntns = os.readlink("/proc/self/ns/mnt")
    current_userns = os.readlink("/proc/self/ns/user")
    add_check(
        "rootless_user_namespace",
        current_userns != os.environ.get("V2_PARENT_USERNS")
        and os.geteuid() == 0
        and os.getuid() == 0,
        "uid_map=" + pathlib.Path("/proc/self/uid_map").read_text(encoding="ascii").strip(),
    )
    uid_map = pathlib.Path("/proc/self/uid_map").read_text(encoding="ascii").split()
    expected_uid = os.environ.get("V2_PARENT_UID", "")
    add_check(
        "single_uid_mapping",
        len(uid_map) == 3 and uid_map[0] == "0" and uid_map[1] == expected_uid and uid_map[2] == "1",
        "uid_map mapping is " + " ".join(uid_map),
    )
    add_check(
        "private_pid_namespace",
        current_pidns != os.environ.get("V2_PARENT_PIDNS") and os.getpid() == 1,
        "pid_namespace=" + current_pidns + "; namespace_pid=" + str(os.getpid()),
    )
    add_check(
        "private_mount_namespace",
        current_mntns != os.environ.get("V2_PARENT_MNTNS"),
        "mount_namespace=" + current_mntns,
    )

    mount_proc_found = False
    for line in pathlib.Path("/proc/self/mountinfo").read_text(encoding="ascii").splitlines():
        fields = line.split()
        if "-" not in fields:
            continue
        separator = fields.index("-")
        if len(fields) > separator + 1 and fields[4] == "/proc" and fields[separator + 1] == "proc":
            mount_proc_found = True
            break
    own_stat = proc_stat("self")
    init_stat = proc_stat(1)
    add_check(
        "private_proc_mounted_and_visible",
        mount_proc_found
        and init_stat["ppid"] == own_stat["ppid"]
        and pathlib.Path("/proc/1").exists()
        and os.getpid() == 1,
        "mountinfo contains a proc mount at /proc; /proc/1 is visible as namespace PID 1",
    )

    pidfd_open = getattr(os, "pidfd_open", None)
    pidfd_send_signal = getattr(signal, "pidfd_send_signal", None)
    add_check(
        "pidfd_api_available",
        callable(pidfd_open) and callable(pidfd_send_signal),
        "os.pidfd_open and signal.pidfd_send_signal are required",
    )

    child = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(60)"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    child_info = proc_stat(child.pid)
    child_start = child_info["start_ticks"]
    child_is_own = child_info["ppid"] == os.getpid() and child_info["state"] != "Z"
    add_check("pidfd_child_is_own_live_child", child_is_own, "pid=" + str(child.pid))
    pidfd = pidfd_open(child.pid, 0)
    pidfd_send_signal(pidfd, signal.SIGTERM)
    pidfd_signals_sent.append("SIGTERM via pidfd")
    try:
        child_rc = child.wait(timeout=1)
        child_termination_signal = "SIGTERM via pidfd"
    except subprocess.TimeoutExpired:
        pidfd_send_signal(pidfd, signal.SIGKILL)
        pidfd_signals_sent.append("SIGKILL via pidfd")
        child_rc = child.wait(timeout=5)
        child_termination_signal = "SIGKILL via pidfd"
    child_collected = child.poll() is not None
    result["pidfd_child"] = {
        "pid": child.pid,
        "start_ticks": child_start,
        "signals_sent": pidfd_signals_sent,
        "termination_signal": child_termination_signal,
        "return_code": child_rc,
        "collected": child_collected,
    }
    add_check(
        "pidfd_signal_and_wait_functional",
        child_rc < 0
        and child_collected
        and child_termination_signal in ("SIGTERM via pidfd", "SIGKILL via pidfd")
        and pidfd_signals_sent[0] == "SIGTERM via pidfd",
        "child terminated by " + str(child_termination_signal)
        + " with return code " + str(child_rc)
        + "; signals sent via pidfd: " + ", ".join(pidfd_signals_sent)
        + "; child collected=" + str(child_collected),
    )
    result["capabilities"] = {
        "pid_namespace": current_pidns,
        "mount_namespace": current_mntns,
        "user_namespace": current_userns,
        "proc_mount": "private proc mounted and visible",
        "pidfd": "opened on own child; SIGTERM via handle, bounded wait, SIGKILL via same handle if needed, then child waited",
    }
    result["ok"] = True
except BaseException as exc:
    result["failure"] = type(exc).__name__ + ": " + str(exc)
finally:
    if child is not None and child.poll() is None:
        try:
            if pidfd is not None:
                signal.pidfd_send_signal(pidfd, signal.SIGKILL)
                pidfd_signals_sent.append("SIGKILL via pidfd (cleanup)")
                if child_termination_signal is None:
                    child_termination_signal = "SIGKILL via pidfd (cleanup)"
            else:
                current = proc_stat(child.pid)
                if current["ppid"] == os.getpid() and current["start_ticks"] == child_start:
                    os.kill(child.pid, signal.SIGKILL)
                    pidfd_signals_sent.append("SIGKILL via verified PID (cleanup only)")
                    if child_termination_signal is None:
                        child_termination_signal = "SIGKILL via verified PID (cleanup only)"
            child.wait(timeout=5)
        except BaseException as exc:
            result["ok"] = False
            result["cleanup_failure"] = type(exc).__name__ + ": " + str(exc)
    if child is not None:
        result.setdefault("pidfd_child", {}).update(
            {
                "pid": child.pid,
                "start_ticks": child_start,
                "signals_sent": pidfd_signals_sent,
                "termination_signal": child_termination_signal,
                "collected": child.poll() is not None,
                "return_code": child.poll(),
            }
        )
        if child.poll() is None:
            result["ok"] = False
            result["cleanup_failure"] = "own pidfd probe child was not collected"
    if pidfd is not None:
        os.close(pidfd)
    destination.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")

sys.exit(0 if result["ok"] else 1)
PY
  preflight_rc=$?
  set -e
fi
preflight_finished="$(date +%s)"
preflight_elapsed=$((preflight_finished - preflight_started))

if [[ -f "$ARTIFACTS_DIR/preflight-probe.json" ]]; then
  probe_status="functional-probe-recorded"
else
  probe_status="probe-did-not-run"
fi

if ! "$PYTHON_BIN" - "$ARTIFACTS_DIR" "$preflight_rc" "$probe_status" "$preflight_elapsed" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
rc = int(sys.argv[2])
probe_status = sys.argv[3]
elapsed = int(sys.argv[4])
probe = None
probe_path = root / "preflight-probe.json"
if probe_path.is_file():
    try:
        probe = json.loads(probe_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        probe = {"ok": False, "failure": "functional probe evidence unreadable: " + str(exc)}
stderr = (root / "preflight.stderr").read_text(encoding="utf-8", errors="replace")
stdout = (root / "preflight.stdout").read_text(encoding="utf-8", errors="replace")
ok = rc == 0 and probe is not None and probe.get("ok") is True
if ok:
    cause = None
elif probe and probe.get("failure"):
    cause = probe["failure"]
elif stderr.strip():
    cause = stderr.strip()[-2000:]
else:
    cause = "unshare functional isolation command failed with RC " + str(rc)
payload = {
    "ok": ok,
    "return_code": rc,
    "elapsed_seconds": elapsed,
    "probe_status": probe_status,
    "isolation_command": ["unshare", "--user", "--map-root-user", "--pid", "--fork", "--mount-proc"],
    "checks": probe.get("checks", []) if probe else [],
    "capabilities": probe.get("capabilities", {}) if probe else {},
    "pidfd_child": probe.get("pidfd_child", {}) if probe else {},
    "failure": cause,
    "stdout": stdout[-2000:],
    "stderr": stderr[-2000:],
}
(root / "preflight.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
sys.exit(0 if ok else 1)
PY
then
  PRECHECK_STATE="failed"
  JOB_STATE="preflight-failed"
  echo "FALLO: preflight funcional no acreditado; consulta preflight.json y preflight.stderr." >&2
  finalize 2
  exit 2
fi

PRECHECK_STATE="passed-functional"
if [[ "$mode" == "--preflight-only" ]]; then
  JOB_STATE="preflight-passed"
  finalize 0
  exit 0
fi

if [[ ! -f "$SCENARIO_RUNNER" || ! -f "$COMPONENT_ROOT/lib/cutover_safety.py" ]]; then
  JOB_STATE="scenario-runner-or-component-missing"
  echo "FALLO: falta el runner de escenarios o el componente canónico del checkout." >&2
  finalize 3
  exit 3
fi

base_scenarios=(normal no-pidfd no-pidfd-hang)
if ! scenario_inventory_json="$("$PYTHON_BIN" - "$SCENARIO_RUNNER" "${base_scenarios[@]}" \
  2>"$ARTIFACTS_DIR/scenario-inventory.stderr" <<'PY'
import json
import pathlib
import re
import sys

runner = pathlib.Path(sys.argv[1])
ci_scenarios = sys.argv[2:]
lines = runner.read_text(encoding="utf-8").splitlines()
case_header = re.compile(r'^\s*case\s+"\$SCENARIO"\s+in\s*$')
clause = re.compile(r'^\s*(.*?)\)\s*(?:;;)?\s*(?:#.*)?$')
valid_name = re.compile(r'^[a-z][a-z0-9-]*$')

case_starts = [index for index, line in enumerate(lines) if case_header.match(line)]
problems = []
if len(case_starts) < 2:
    problems.append("runner debe declarar tanto el despacho como el contrato de escenarios")


def labels_at(start):
    labels = []
    ended = False
    for line in lines[start + 1:]:
        if re.match(r'^\s*esac\s*$', line):
            ended = True
            break
        match = clause.match(line)
        if not match:
            continue
        pattern = match.group(1).strip()
        if pattern == "*":
            continue
        for name in pattern.split("|"):
            if not valid_name.fullmatch(name):
                problems.append("etiqueta no reconocida en runner: " + repr(name))
            labels.append(name)
    if not ended:
        problems.append("case de escenarios sin esac de cierre")
    return labels


runner_scenarios = labels_at(case_starts[0]) if case_starts else []
runner_contracts = labels_at(case_starts[1]) if len(case_starts) > 1 else []


def duplicates(values):
    seen = set()
    repeated = []
    for value in values:
        if value in seen and value not in repeated:
            repeated.append(value)
        seen.add(value)
    return repeated


runner_duplicates = duplicates(runner_scenarios)
contract_duplicates = duplicates(runner_contracts)
ci_duplicates = duplicates(ci_scenarios)
if runner_duplicates:
    problems.append("duplicados en el despacho del runner: " + ", ".join(runner_duplicates))
if contract_duplicates:
    problems.append("duplicados en el contrato del runner: " + ", ".join(contract_duplicates))
if ci_duplicates:
    problems.append("duplicados en el bucle base de CI: " + ", ".join(ci_duplicates))

unrecognized = [name for name in runner_scenarios if name not in runner_contracts]
if unrecognized:
    problems.append("escenarios aceptados sin contrato reconocido en el runner: " + ", ".join(unrecognized))
unrecognized_ci = [name for name in ci_scenarios if name not in runner_scenarios]
if unrecognized_ci:
    problems.append("escenarios del bucle CI no reconocidos por el runner: " + ", ".join(unrecognized_ci))
missing_ci = [name for name in runner_scenarios if name not in ci_scenarios]
if missing_ci:
    problems.append("escenarios soportados ausentes del bucle CI: " + ", ".join(missing_ci))
missing_dispatch = [name for name in runner_contracts if name not in runner_scenarios]
if missing_dispatch:
    problems.append("escenarios con contrato no admitidos por el despacho: " + ", ".join(missing_dispatch))

if problems:
    print("Inventario de escenarios inválido; no se ejecutó el banco:", file=sys.stderr)
    for problem in problems:
        print("  - " + problem, file=sys.stderr)
    print("  runner (despacho): " + ", ".join(runner_scenarios), file=sys.stderr)
    print("  runner (contratos): " + ", ".join(runner_contracts), file=sys.stderr)
    print("  CI (escenarios base): " + ", ".join(ci_scenarios), file=sys.stderr)
    raise SystemExit(1)

print(json.dumps({"runner_supported": runner_scenarios, "ci_base": ci_scenarios}, sort_keys=True))
PY
)"; then
  JOB_STATE="scenario-inventory-invalid"
  echo "FALLO BLOQUEANTE: el inventario de escenarios no coincide; corrige el runner o el bucle base de CI antes de ejecutar el banco." >&2
  cat "$ARTIFACTS_DIR/scenario-inventory.stderr" >&2
  finalize 3
  exit 3
fi
printf '%s\n' "$scenario_inventory_json" >"$ARTIFACTS_DIR/scenario-inventory.json"

scenario_failure=0
control_safe_to_run=1
for scenario in "${base_scenarios[@]}"; do
  scenario_dir="$ARTIFACTS_DIR/scenarios/$scenario"
  scenario_log="$ARTIFACTS_DIR/logs/$scenario.log"
  scenario_started="$(date +%s)"
  set +e
  env \
    -u FORGE_V2_REAL_DB \
    -u FORGE_V2_HANG_TIMEOUT \
    -u FORGE_V2_SCENARIO_GUARD \
    -u FORGE_V2_SCENARIO_GRACE \
    -u FORGE_V2_OUTER_SCENARIO_GUARD \
    -u FORGE_V2_TEST_GUARD_CLEANUP_FAIL \
    -u FORGE_V2_TEST_NO_PIDFD \
    -u FORGE_V2_TEST_HANG_SUITE \
    FORGE_V2_EXTERNAL_ROOT="$COMPONENT_ROOT" \
    bash "$SCENARIO_RUNNER" "$scenario" "$scenario_dir" >"$scenario_log" 2>&1
  scenario_rc=$?
  set -e
  scenario_finished="$(date +%s)"
  scenario_elapsed=$((scenario_finished - scenario_started))

  set +e
  "$PYTHON_BIN" - "$scenario" "$scenario_dir" "$scenario_rc" "$scenario_elapsed" <<'PY'
import json
import pathlib
import sys

scenario, directory, runner_rc, elapsed = sys.argv[1:]
runner_rc = int(runner_rc)
root = pathlib.Path(directory)
expected = {
    "normal": {"supervisor": 0, "suite": 0, "authorization": True, "watchdog": True, "timed_out": False},
    "no-pidfd": {"supervisor": 6, "suite": 4, "authorization": False, "watchdog": False, "timed_out": False},
    # The suite of this scenario is ELIMINATED by the bounded close of the
    # containment entry: it hangs on purpose and it IGNORES the TERM of the
    # close, so the close escalates to SIGKILL and kills the whole group.
    #
    # Its RC is therefore OBSERVABLE and it is -9 (the convention of the
    # shell: a process terminated by SIGKILL is -9, never 137). That value is
    # the POSITIVE evidence of the contract of this scenario: without pidfd,
    # the close applied by the ENTRY killed the group, and the init of the
    # namespace and the group itself end up terminated and verified.
    #
    # "None" (an RC that does not apply) would certify NOTHING: it is
    # satisfied by the mere ABSENCE of an RC, and in this architecture it is
    # UNSATISFIABLE, because the entry always records a numeric SCENARIO_RC.
    # The guarantee itself is checked apart: the real timeout, the init of
    # the namespace gone, the group without members, no survivors and the
    # teardown acreditado.
    "no-pidfd-hang": {"supervisor": 6, "suite": -9, "authorization": False, "watchdog": False, "timed_out": True},
}[scenario]
problems = []
verdict = None
report = None
if runner_rc != 0:
    problems.append("scenario runner returned RC " + str(runner_rc))
try:
    verdict = json.loads((root / "verdict.json").read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    problems.append("scenario verdict missing or unreadable: " + str(exc))
try:
    report = json.loads((root / "safety-results.json").read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    problems.append("bench report missing or unreadable: " + str(exc))

teardown_checks = {
    "scenario_work_removed": not (root / "work").exists(),
}
cleanup = (report or {}).get("cleanup") or {}
teardown_checks.update(
    {
        "cleanup_ok": cleanup.get("ok") is True,
        "no_private_namespace_survivors": cleanup.get("survivors_in_private_namespace") == [],
        "no_own_process_group_members": cleanup.get("members_of_own_process_group") == [],
        "namespace_init_gone": cleanup.get("namespace_init_alive_after") is False
        and cleanup.get("namespace_init_gone_after") is True,
        "synthetic_root_removed": cleanup.get("synthetic_root_present_after") is False,
    }
)
teardown_names = {
    "sin supervivientes en el namespace privado",
    "sin miembros del grupo propio del lote",
    "init del namespace eliminado",
    "raiz sintetica eliminada",
    "ninguna identidad propia registrada sigue viva en /proc",
    "ningun proceso vivo pertenece al namespace privado del lote",
}
verdict_checks = {item.get("name"): item.get("ok") for item in (verdict or {}).get("checks", [])}
for name in teardown_names:
    teardown_checks["bench_verdict: " + name] = verdict_checks.get(name) is True
teardown_ok = all(teardown_checks.values())
if not teardown_ok:
    problems.append("teardown incomplete or unaccredited: " + repr(teardown_checks))

contract = {"supervisor_rc": None, "suite_rc": None, "authorization_granted": None,
            "watchdog_operational": None, "timed_out": None, "dead6_isolated": None}
if verdict is not None:
    contract["supervisor_rc"] = verdict.get("supervisor_rc")
    contract["suite_rc"] = verdict.get("suite_rc")
if report is not None:
    contract["authorization_granted"] = cleanup.get("authorization_granted")
    contract["watchdog_operational"] = cleanup.get("watchdog_operational")
    contract["timed_out"] = cleanup.get("timed_out")
    if scenario == "normal":
        dead6 = next((case for case in report.get("cases", []) if case.get("id") == "DEAD-6"), None)
        contract["dead6_isolated"] = bool(dead6 and dead6.get("status") == "PASS"
                                          and "rc_fusible=124" in dead6.get("detail", "")
                                          and "proceso_que_dispara SIGUE VIVO" not in dead6.get("detail", ""))

contract_ok = (
    contract["supervisor_rc"] == expected["supervisor"]
    and contract["suite_rc"] == expected["suite"]
    and contract["authorization_granted"] is expected["authorization"]
    and contract["watchdog_operational"] is expected["watchdog"]
    and contract["timed_out"] is expected["timed_out"]
    and (scenario != "normal" or contract["dead6_isolated"] is True)
)
if not contract_ok:
    problems.append("scenario contract mismatch: expected=" + repr(expected) + " observed=" + repr(contract))
if verdict is None or verdict.get("ok") is not True or verdict.get("exit_code") != 0:
    problems.append("existing scenario semantic verdict is not successful")

payload = {
    "scenario": scenario,
    "runner_rc": runner_rc,
    "elapsed_seconds": int(elapsed),
    "ok": not problems,
    "teardown_ok": teardown_ok,
    "teardown": teardown_checks,
    "contract": contract,
    "expected": expected,
    "bench_timings": (verdict or {}).get("timings", {}),
    "problems": problems,
    "evidence": {
        "bench_verdict": "verdict.json",
        "bench_report": "safety-results.json",
        "runner_stdout_stderr": "../../logs/" + scenario + ".log",
    },
}
(root / "entrypoint-verification.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
print(json.dumps(payload, sort_keys=True))
sys.exit(0 if not problems else 1)
PY
  verify_rc=$?
  set -e

  if ! "$PYTHON_BIN" - "$ARTIFACTS_DIR/scenario-results.json" "$scenario" \
    "$scenario_rc" "$scenario_elapsed" <<'PY'
import json
import pathlib
import sys

results_path = pathlib.Path(sys.argv[1])
scenario, runner_rc, elapsed = sys.argv[2:]
root = results_path.parent
directory = root / "scenarios" / scenario
try:
    verification = json.loads((directory / "entrypoint-verification.json").read_text(encoding="utf-8"))
except (OSError, ValueError) as exc:
    verification = {"ok": False, "teardown_ok": False, "problems": [str(exc)]}
try:
    results = json.loads(results_path.read_text(encoding="utf-8"))
except (OSError, ValueError):
    results = []
results.append(
    {
        "scenario": scenario,
        "runner_rc": int(runner_rc),
        "elapsed_seconds": int(elapsed),
        "ok": verification.get("ok") is True,
        "teardown_ok": verification.get("teardown_ok") is True,
        "evidence_dir": "scenarios/" + scenario,
        "log": "logs/" + scenario + ".log",
        "contract": verification.get("contract", {}),
        "bench_timings": verification.get("bench_timings", {}),
        "problems": verification.get("problems", []),
    }
)
temporary = results_path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(results_path)
PY
  then
    scenario_failure=1
  fi

  if ((verify_rc != 0)); then
    scenario_failure=1
  fi
  if [[ ! -f "$scenario_dir/entrypoint-verification.json" ]] || \
    ! "$PYTHON_BIN" - "$scenario_dir/entrypoint-verification.json" <<'PY'
import json
import pathlib
import sys

try:
    evidence = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
except (OSError, ValueError):
    raise SystemExit(1)
raise SystemExit(0 if evidence.get("teardown_ok") is True else 1)
PY
  then
    echo "FALLO: teardown incompleto o evidencia insuficiente en $scenario; se detiene la secuencia." >&2
    scenario_failure=1
    control_safe_to_run=0
    break
  fi
done

control_failure=0
run_guard_control() {
  local variant="$1"
  local expected_rc="$2"
  local inject_cleanup_failure="$3"
  local scenario="no-pidfd-hang"
  local control_dir="$ARTIFACTS_DIR/controls/$variant"
  local control_log="$ARTIFACTS_DIR/logs/$variant.log"
  local control_runner_rc verify_rc

  if [[ -e "$control_dir" || -L "$control_dir" ]]; then
    echo "FALLO: la evidencia del control ya existe: $control_dir" >&2
    return 1
  fi

  echo "=== control $variant: escenario=$scenario guard=15s inyeccion=$inject_cleanup_failure ==="
  set +e
  if [[ "$inject_cleanup_failure" == 1 ]]; then
    env \
      -u FORGE_V2_REAL_DB \
      -u FORGE_V2_HANG_TIMEOUT \
      -u FORGE_V2_SCENARIO_GUARD \
      -u FORGE_V2_SCENARIO_GRACE \
      -u FORGE_V2_OUTER_SCENARIO_GUARD \
      -u FORGE_V2_TEST_GUARD_CLEANUP_FAIL \
      -u FORGE_V2_TEST_NO_PIDFD \
      -u FORGE_V2_TEST_HANG_SUITE \
      FORGE_V2_EXTERNAL_ROOT="$COMPONENT_ROOT" \
      FORGE_V2_SCENARIO_GUARD=15 \
      FORGE_V2_OUTER_SCENARIO_GUARD=600 \
      FORGE_V2_TEST_GUARD_CLEANUP_FAIL=1 \
      bash "$SCENARIO_RUNNER" "$scenario" "$control_dir" >"$control_log" 2>&1
  else
    env \
      -u FORGE_V2_REAL_DB \
      -u FORGE_V2_HANG_TIMEOUT \
      -u FORGE_V2_SCENARIO_GUARD \
      -u FORGE_V2_SCENARIO_GRACE \
      -u FORGE_V2_OUTER_SCENARIO_GUARD \
      -u FORGE_V2_TEST_GUARD_CLEANUP_FAIL \
      -u FORGE_V2_TEST_NO_PIDFD \
      -u FORGE_V2_TEST_HANG_SUITE \
      FORGE_V2_EXTERNAL_ROOT="$COMPONENT_ROOT" \
      FORGE_V2_SCENARIO_GUARD=15 \
      FORGE_V2_OUTER_SCENARIO_GUARD=600 \
      bash "$SCENARIO_RUNNER" "$scenario" "$control_dir" >"$control_log" 2>&1
  fi
  control_runner_rc=$?
  set -e

  set +e
  "$PYTHON_BIN" - "$control_dir" "$variant" "$scenario" "$control_runner_rc" \
    "$expected_rc" "$inject_cleanup_failure" <<'PY'
import json
import pathlib
import sys

directory, variant, scenario, runner_rc, expected_rc, injected = sys.argv[1:]
root = pathlib.Path(directory)
runner_rc = int(runner_rc)
expected_rc = int(expected_rc)
expected_injection = injected == "1"
problems = []


def load(name):
    try:
        value = json.loads((root / name).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


expiry = load("guard-expiry.json")
verdict = load("guard-verdict.json")
if runner_rc != expected_rc:
    problems.append("RC observado del runner=%d; esperado=%d" % (runner_rc, expected_rc))
if expiry is None:
    problems.append("falta guard-expiry.json legible")
if verdict is None:
    problems.append("falta guard-verdict.json legible")

observed_wrapper_rc = (verdict or {}).get("wrapper_rc")
survivors = (expiry or {}).get("survivors")
forced_recovery = (expiry or {}).get("forced_recovery") or []
observed_injection = (expiry or {}).get("fault_injection")
if (expiry or {}).get("expired") is not True:
    problems.append("la evidencia no acredita vencimiento del guard")
if observed_wrapper_rc != expected_rc:
    problems.append("RC re-derivado del guard=%r; esperado=%d" % (observed_wrapper_rc, expected_rc))
if observed_injection is not expected_injection:
    problems.append("fault_injection=%r; esperado=%r" % (observed_injection, expected_injection))
if not isinstance(survivors, list):
    problems.append("la evidencia de supervivientes no es una lista")
elif expected_rc == 14 and survivors:
    problems.append("RC 14 requiere limpieza acreditada sin supervivientes")
elif expected_rc == 15 and not survivors:
    problems.append("RC 15 requiere supervivientes detectados antes de la recuperación")

if expected_rc == 14 and (verdict or {}).get("ok") is not True:
    problems.append("el control RC 14 no acredita la limpieza completa")
if expected_rc == 15 and (verdict or {}).get("ok") is not False:
    problems.append("el control RC 15 no registra el fallo de limpieza incompleta")
if expected_rc == 15 and not any("recuperacion forzada completa" in item for item in forced_recovery):
    problems.append("la recuperación obligatoria no acredita cero recursos propios vivos")
if any("RECOVERY INCOMPLETA" in item for item in forced_recovery):
    problems.append("la recuperación obligatoria dejó recursos propios vivos")
if (root / "work").exists():
    problems.append("permanece el directorio de trabajo del control")

payload = {
    "variant": variant,
    "scenario": scenario,
    "runner_rc": runner_rc,
    "expected_rc": expected_rc,
    "observed_guard_rc": observed_wrapper_rc,
    "fault_injection": observed_injection,
    "survivors_detected": survivors,
    "forced_recovery": forced_recovery,
    "ok": not problems,
    "problems": problems,
    "evidence": {"guard_expiry": "guard-expiry.json", "guard_verdict": "guard-verdict.json"},
}
(root / "control-verification.json").write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
print(json.dumps(payload, sort_keys=True))
raise SystemExit(0 if not problems else 1)
PY
  verify_rc=$?
  set -e
  if ((verify_rc != 0)); then
    echo "FALLO: $variant no satisfizo el contrato RC $expected_rc; consulta $control_dir/control-verification.json." >&2
    return 1
  fi
  return 0
}

if ((control_safe_to_run == 0)); then
  echo "FALLO: se omiten los controles del guard porque un escenario base dejó teardown sin acreditar." >&2
  control_failure=1
else
  run_guard_control guard-rc14-cleanup-complete 14 0 || control_failure=1
  run_guard_control guard-rc15-cleanup-incomplete 15 1 || control_failure=1
fi

if [[ -z "${FORGE_PRODUCT_CLEANUP_RESULT_FILE:-}" ]]; then
  JOB_STATE="product-cleanup-result-unavailable"
  echo "FALLO: falta la ruta de resultado de limpieza del producto para el recibo de contencion." >&2
  finalize 4
  exit 4
fi

if ! product_cleanup_aggregate="$(bash "$SCRIPT_DIR/aggregate-product-cleanup.sh" \
  "$ARTIFACTS_DIR" "$FORGE_PRODUCT_CLEANUP_RESULT_FILE")"; then
  JOB_STATE="product-cleanup-aggregation-unavailable"
  echo "FALLO: no se pudo agregar la limpieza declarada por escenario." >&2
  finalize 4
  exit 4
fi

case $product_cleanup_aggregate in
  FAIL)
    JOB_STATE="product-cleanup-failed"
    echo "FALLO: al menos un escenario declaro FAIL para la limpieza del producto." >&2
    finalize 4
    exit 4
    ;;
  UNKNOWN)
    # Preserve RC 0 only for the scenario contract itself. The containment
    # entry sees UNKNOWN and converts that RC 0 into RC 70 (not accepted).
    if ((scenario_failure == 0 && control_failure == 0)); then
      JOB_STATE="product-cleanup-unknown"
      echo "INDETERMINADO: falta una declaracion valida de limpieza en algun escenario." >&2
      finalize 0
      exit 0
    fi
    ;;
  PASS)
    ;;
  *)
    JOB_STATE="product-cleanup-aggregation-invalid"
    echo "FALLO: resultado agregado de limpieza no valido: $product_cleanup_aggregate" >&2
    finalize 4
    exit 4
    ;;
esac

if ((scenario_failure != 0 || control_failure != 0)); then
  JOB_STATE="scenario-control-or-evidence-failed"
  echo "FALLO: uno o más escenarios/controles no cumplieron su contrato; consulta scenario-results.json y controls/." >&2
  finalize 3
  exit 3
fi

JOB_STATE="all-scenarios-passed"
finalize 0
exit 0
