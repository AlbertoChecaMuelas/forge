#!/usr/bin/env bash
# tests/forge_v2_safety.sh — stable entry point of the isolated V2 safety
# acceptance (plan `v2-safety-followups`, Step 2.2).
#
# The suite is executed over EXCLUSIVELY synthetic resources:
#
#   * the containment is established and accredited BEFORE any sensitive
#     production function is called (rootless user namespace + private PID
#     namespace + private /proc, driven by an external watchdog with an
#     independent cleanup),
#   * the suite does not run a single sensitive case until the supervisor has
#     released an authorization barrier, which it only does once the
#     containment is accredited AND the watchdog is operational; if the
#     watchdog cannot be armed the suite aborts with a non zero RC,
#   * every SQLite database, WAL/SHM companion and child process is created
#     by the batch under its own private root,
#   * the real OpenCode database, any host process and the external
#     entrypoints (cutover.sh / ROLLBACK.sh) are never used as a target and
#     are never executed.
#
# An absent component, an unaccredited containment, an inoperative watchdog or
# a surviving resource is an explicit failure: the suite never converts a
# missing piece into a green skip.
#
# Usage:
#   bash tests/forge_v2_safety.sh
#   FORGE_V2_EXTERNAL_ROOT=/path/to/external bash tests/forge_v2_safety.sh
#   FORGE_V2_EVIDENCE_ROOT=/path/to/evidence bash tests/forge_v2_safety.sh
#
# The report is always written to $FORGE_V2_EVIDENCE_ROOT/safety-results.json
# (default /tmp/opencode/forge-v2-safety/safety-results.json); that very
# path is the one the harness generates, reads back and completes.
#
# The default evidence root is a DEDICATED root of this suite. It is
# deliberately NOT the evidence directory of any batch: this suite must never
# overwrite the evidence of a previous batch (that happened when the default
# pointed at /tmp/opencode/forge-v2-followups/, whose safety-results.json and
# safety-results.md belong to the batch that produced them). A caller that
# owns a batch root states it explicitly with FORGE_V2_EVIDENCE_ROOT (or
# FORGE_V2_BATCH_ROOT).
#
# Compatible with bash 3.2+.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HARNESS="$SCRIPT_DIR/forge_v2_safety_harness.py"

# The real component is consumed from the CANONICAL source versioned in this
# repository (tools/cutover/forge-v2/), resolved RELATIVE TO THE CHECKOUT, so
# the suite works in a clean clone and in CI. The external copy of the
# laboratory (/home/espinilleitor/forge-v2-cutover-20261024) is a frozen
# historical backup, not an active source: it is never consulted by default.
# FORGE_V2_EXTERNAL_ROOT stays as an explicit override for a developer that
# wants to point the suite at another tree; it is NOT needed in CI.
EXTERNAL_ROOT="${FORGE_V2_EXTERNAL_ROOT:-$REPO_ROOT/tools/cutover/forge-v2}"
PLUGIN_SYNC="$REPO_ROOT/open-code/lib/plugin-sync.py"
CUTOVER_SAFETY="$EXTERNAL_ROOT/lib/cutover_safety.py"

# The batch evidence root. A RELATIVE evidence root is resolved against
# this fixed base, never against the working directory: the suite must not
# leave stray artefacts inside the Git working tree. The harness applies the
# very same rule to --report-path (see resolve_report_path in
# tests/forge_v2_safety_harness.py).
#
# The DEFAULT is a dedicated root of this suite, NOT the evidence directory of
# any batch: this suite never writes into /tmp/opencode/forge-v2-followups/
# (the evidence of the batch that produced it) nor into any other batch root.
BATCH_ROOT="${FORGE_V2_BATCH_ROOT:-/tmp/opencode/forge-v2-safety}"
EVIDENCE_ROOT="${FORGE_V2_EVIDENCE_ROOT:-$BATCH_ROOT}"
case "$EVIDENCE_ROOT" in
  /*) ;;
  *) EVIDENCE_ROOT="$BATCH_ROOT/$EVIDENCE_ROOT" ;;
esac
# The harness must use the very same base for its transient synthetic root,
# so that nothing of this run is created outside the evidence root.
export FORGE_V2_BATCH_ROOT="$BATCH_ROOT"

FAIL=0

fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

info() {
  echo "  ---- $1"
}

# ---------------------------------------------------------------------------
# Required components. Their absence is an explicit failure, never a skip.
# ---------------------------------------------------------------------------
echo "=== forge_v2_safety ==="

if [ ! -f "$PLUGIN_SYNC" ]; then
  fail "componente requerido ausente: $PLUGIN_SYNC"
fi
if [ ! -f "$CUTOVER_SAFETY" ]; then
  fail "componente requerido ausente: $CUTOVER_SAFETY"
fi
if [ ! -f "$HARNESS" ]; then
  fail "harness ausente: $HARNESS"
fi
if [ "$FAIL" -ne 0 ]; then
  echo "BLOCKED: faltan componentes requeridos; no se ejecuta ninguna funcion sensible." >&2
  exit 2
fi

info "plugin-sync.py   $(sha256sum "$PLUGIN_SYNC" | cut -d' ' -f1)  $PLUGIN_SYNC"
info "cutover_safety.py $(sha256sum "$CUTOVER_SAFETY" | cut -d' ' -f1)  $CUTOVER_SAFETY"

mkdir -p "$EVIDENCE_ROOT"
chmod 700 "$EVIDENCE_ROOT" 2>/dev/null || true

# The report path is the one the harness generates, reads back and completes.
REPORT_PATH="$EVIDENCE_ROOT/safety-results.json"

# The real OpenCode database is never opened nor read: the suite only takes a
# stat() fingerprint of it, before and after the run, to prove it was not
# modified. It is never passed to any production function.
REAL_DB="${FORGE_V2_REAL_DB:-$HOME/.local/share/opencode/opencode.db}"

# ---------------------------------------------------------------------------
# The harness establishes the containment, releases the authorization barrier
# only when the watchdog is operational, runs the cases inside the private
# namespace and verifies afterwards that nothing of the batch survived.
# ---------------------------------------------------------------------------
set +e
python3 "$HARNESS" \
  --role supervisor \
  --repo-root "$REPO_ROOT" \
  --external-root "$EXTERNAL_ROOT" \
  --report-path "$REPORT_PATH" \
  --real-db "$REAL_DB"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo ""
  echo "  FAIL: la aceptacion de seguridad termino con RC=$RC (evidencia en $REPORT_PATH)"
  exit "$RC"
fi

# The announced report must really exist where it was promised AND it must be
# COMPLETE: the cleanup evidence and the supervisor trace are part of the
# contract, so a half written report is an explicit failure, not a green run.
if [ ! -f "$REPORT_PATH" ]; then
  echo ""
  echo "  FAIL: el harness no genero el informe prometido en $REPORT_PATH" >&2
  exit 9
fi

if ! python3 - "$REPORT_PATH" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as stream:
        report = json.load(stream)
except (OSError, ValueError) as exc:
    sys.stderr.write("el informe no es legible: %s\n" % exc)
    raise SystemExit(1)

problems = []
if "cleanup" not in report:
    problems.append("falta la seccion 'cleanup'")
if "supervisor" not in report:
    problems.append("falta la seccion 'supervisor'")
cleanup = report.get("cleanup") or {}
if cleanup.get("ok") is not True:
    problems.append("cleanup.ok no es true")
if cleanup.get("survivors_in_private_namespace"):
    problems.append("quedan supervivientes en el namespace privado")
if cleanup.get("members_of_own_process_group"):
    problems.append("quedan miembros del grupo propio del lote")
if cleanup.get("namespace_init_alive_after"):
    problems.append("el init del namespace sigue vivo")
if cleanup.get("synthetic_root_present_after"):
    problems.append("la raiz sintetica sigue presente")
if cleanup.get("watchdog_operational") is not True:
    problems.append("el watchdog no consta como operativo")
if cleanup.get("authorization_granted") is not True:
    problems.append("la autorizacion no consta como concedida")
if report.get("summary", {}).get("failed"):
    problems.append("hay casos fallidos en el informe")

if problems:
    sys.stderr.write("informe incompleto: %s\n" % "; ".join(problems))
    raise SystemExit(1)
PY
then
  echo ""
  echo "  FAIL: el informe de $REPORT_PATH no contiene la evidencia completa del contrato" >&2
  exit 9
fi

echo ""
echo "  PASS: aceptacion de seguridad aislada completada (evidencia en $REPORT_PATH)"
exit 0
