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
#
# Since the provenance of the loaded module is a HARD control (INSP-2 of the
# harness), an override that points at another tree now makes the suite RED:
# the override is still honoured (the suite runs and it exercises that tree)
# but the invocation is not an acceptance. A green run requires the canonical
# versioned component.
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

# ---------------------------------------------------------------------------
# ADMISSION. This suite is a consumer of the product: it computes the hashes
# of the components, it creates the evidence directory, it generates the
# artefacts and it starts the supervisor. NONE of that may happen unless the
# containment of THIS invocation is accredited by the standard entry
# (tools/verification/forge-contained-run.sh).
#
# The accreditation that the inner role_suite() performs for itself does NOT
# authorize this suite: it protects that role only, and it says nothing about
# the runner, the supervisor, the preparation, the controls nor the cleanup.
# ---------------------------------------------------------------------------
CONTAINMENT_GUARD="$REPO_ROOT/tools/verification/require-v2-containment.sh"
if [ ! -f "$CONTAINMENT_GUARD" ]; then
  echo "BLOCKED: no existe el helper de admision de contencion: $CONTAINMENT_GUARD" >&2
  exit 78
fi
if ! bash "$CONTAINMENT_GUARD"; then
  echo "BLOCKED: el banco V2 no se ejecuta sin acreditacion previa de forge-contained-run.sh." >&2
  exit 78
fi

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

# ---------------------------------------------------------------------------
# The declaration of the cleanup of the product of THIS invocation.
#
# The supervisor publishes it in the marker of the entry, observed over the
# PRIVATE /proc of the containment and BEFORE the defensive cleanup of the
# entry. This suite has to DECLARE it: a missing declaration is a contract
# violation, and a declaration that is not a PASS means that the cleanup of
# the product was not observed as clean (FAIL) or could not be observed at
# all (UNKNOWN), so this invocation cannot be a positive acceptance.
# ---------------------------------------------------------------------------
PRODUCT_CLEANUP_FILE="${FORGE_PRODUCT_CLEANUP_RESULT_FILE:-}"
PRODUCT_CLEANUP_DECLARED="ABSENT"
if [ -n "$PRODUCT_CLEANUP_FILE" ] && [ -f "$PRODUCT_CLEANUP_FILE" ]; then
  PRODUCT_CLEANUP_DECLARED="$(sed -n '1p' "$PRODUCT_CLEANUP_FILE" 2>/dev/null | tr -d '[:space:]')"
fi
if [ "$PRODUCT_CLEANUP_DECLARED" != "PASS" ]; then
  echo "" >&2
  echo "  FAIL: la suite no declaro una limpieza del producto aceptable (declaracion='$PRODUCT_CLEANUP_DECLARED', marcador='$PRODUCT_CLEANUP_FILE')" >&2
  echo "  La limpieza del producto se observa sobre el /proc privado de la contencion y antes de la limpieza defensiva de la entrada: un valor distinto de PASS (FAIL o UNKNOWN) impide la aceptacion positiva de esta invocacion." >&2
  exit 10
fi
echo "  limpieza del producto declarada: $PRODUCT_CLEANUP_DECLARED"

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
# The three absences of the batch have to be EXPLICITLY VERIFIED, and the
# observation of the aftermath has to be COMPLETE.
#
# A truthiness check is NOT enough: it accepts a None, and a None is the
# value of an absence that could NOT be observed. An absence that was not
# observed is NOT an absence, so accepting it would certify a containment
# whose "zero survivors" claim had never been observed. The same criterion
# is applied by the harness (the verdict of its own cleanup) and by the
# runner of the scenarios: the correction is UNIFORM across the entries.
if cleanup.get("aftermath_observation_state") != "COMPLETE":
    problems.append(
        "la observacion del aftermath no es COMPLETE: %r" % cleanup.get("aftermath_observation_state")
    )
if cleanup.get("survivors_absence_verified") is not True:
    problems.append(
        "la ausencia de supervivientes no consta como VERIFICADA: %r"
        % cleanup.get("survivors_absence_verified")
    )
if cleanup.get("members_absence_verified") is not True:
    problems.append(
        "la ausencia de miembros del grupo propio no consta como VERIFICADA: %r"
        % cleanup.get("members_absence_verified")
    )
if cleanup.get("init_absence_verified") is not True:
    problems.append(
        "la ausencia del init del namespace no consta como VERIFICADA: %r"
        % cleanup.get("init_absence_verified")
    )
if cleanup.get("survivors_in_private_namespace") != []:
    problems.append("quedan supervivientes en el namespace privado")
if cleanup.get("members_of_own_process_group") != []:
    problems.append("quedan miembros del grupo propio del lote")
if cleanup.get("namespace_init_alive_after") is not False:
    problems.append("el init del namespace sigue vivo (o no se pudo observar)")
if cleanup.get("synthetic_root_present_after") is not False:
    problems.append("la raiz sintetica sigue presente (o no se pudo observar)")
if cleanup.get("watchdog_operational") is not True:
    problems.append("el watchdog no consta como operativo")
if cleanup.get("authorization_granted") is not True:
    problems.append("la autorizacion no consta como concedida")
if report.get("summary", {}).get("failed"):
    problems.append("hay casos fallidos en el informe")

# ---------------------------------------------------------------------------
# The AUXILIARY controls (the controls of the controls of the provenance and
# of the uniqueness) are counted APART from the bank, with their own
# verdict, but they are HARD: this entry does NOT accept a report whose
# auxiliary census is absent, incomplete or red.
#
# An absent section is NOT a green skip: it is the evidence of a control
# that was not exercised, and a control that was not exercised certifies
# nothing. The same criterion is applied by the runner of the scenarios.
# ---------------------------------------------------------------------------
AUXILIARY_IDS = ["INSP-6", "INSP-7", "INSP-8"]
auxiliary = report.get("auxiliary_controls")
if not isinstance(auxiliary, dict):
    problems.append("falta la seccion 'auxiliary_controls'")
else:
    auxiliary_cases = auxiliary.get("cases")
    if not isinstance(auxiliary_cases, list):
        problems.append("la seccion 'auxiliary_controls' no publica su censo de casos")
        auxiliary_cases = []
    auxiliary_summary = auxiliary.get("summary")
    if not isinstance(auxiliary_summary, dict):
        problems.append("la seccion 'auxiliary_controls' no publica su resumen")
        auxiliary_summary = {}
    if sorted(auxiliary.get("ids") or []) != AUXILIARY_IDS:
        problems.append(
            "el censo auxiliar no declara exactamente %r: %r" % (AUXILIARY_IDS, auxiliary.get("ids"))
        )
    recorded = sorted(
        case.get("id") for case in auxiliary_cases if isinstance(case, dict)
    )
    if recorded != AUXILIARY_IDS:
        problems.append(
            "el censo auxiliar no registra exactamente %r: %r" % (AUXILIARY_IDS, recorded)
        )
    for case in auxiliary_cases:
        if not isinstance(case, dict):
            continue
        if case.get("status") != "PASS":
            problems.append("control auxiliar en rojo: %s" % case.get("id"))
    if auxiliary_summary.get("total") != len(AUXILIARY_IDS):
        problems.append(
            "el recuento auxiliar no es el declarado: %r (esperado %d)"
            % (auxiliary_summary.get("total"), len(AUXILIARY_IDS))
        )
    if auxiliary_summary.get("passed") != len(AUXILIARY_IDS):
        problems.append(
            "el recuento de auxiliares verdes no es el declarado: %r (esperado %d)"
            % (auxiliary_summary.get("passed"), len(AUXILIARY_IDS))
        )
    if auxiliary_summary.get("failed") != 0:
        problems.append("hay controles auxiliares fallidos: %r" % auxiliary_summary.get("failed"))
    if auxiliary_summary.get("complete") is not True:
        problems.append(
            "el censo auxiliar no consta como COMPLETO: %r" % auxiliary_summary.get("complete")
        )
    if auxiliary_summary.get("verdict") != "PASS":
        problems.append(
            "el veredicto de los controles auxiliares no es PASS: %r"
            % auxiliary_summary.get("verdict")
        )
# The main census of the bank is NOT polluted by the auxiliary controls:
# they are counted apart, so a control that is counted twice would hide
# the real count of the bank.
bank_case_ids = [
    case.get("id") for case in (report.get("cases") or []) if isinstance(case, dict)
]
polluted = [cid for cid in bank_case_ids if cid in AUXILIARY_IDS]
if polluted:
    problems.append(
        "los controles auxiliares estan contados dentro del banco: %r" % (polluted,)
    )

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
