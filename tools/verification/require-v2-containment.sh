#!/usr/bin/env bash
# PID-namespace coherence check for V2 consumers, not an independent authority
# for containment. FD 8 comparison proves neither invocation provenance nor
# which side is outside/inside the intended boundary. The trusted launch chain
# and confirmed outer close establish provenance; see the normative summary in
# tools/verification/V2-CONTAINMENT-CONTRACT.md.
set -u

readonly RECEIPT_ROOT='/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs'
readonly EXPECTED_RECEIPT_ROOT="$RECEIPT_ROOT"
readonly INVOKER_PID_NAMESPACE_FD=8

fail() {
  printf 'BLOCKED: %s\n' "$1" >&2
  printf '%s\n' \
    'Accion: use la cadena controlada mediante tools/verification/forge-contained-run.sh,' \
    'con --receipt-dir /tmp/opencode/forge-contracts-v2/remediacion-contencion/runs,' \
    'un --scenario-timeout/--close-timeout revisado y la orden completa tras --. Esta puerta solo comprueba coherencia de namespaces; FD 8 no autentica procedencia ni direccion de frontera.' >&2
  exit 78
}

receipt_field_is_unique() {
  local field=$1
  /usr/bin/awk -v field="$field" '
    index($0, "=") {
      separator = index($0, "=")
      if (substr($0, 1, separator - 1) == field) count++
    }
    END { exit count == 1 ? 0 : 1 }
  ' "$receipt"
}

receipt_field_matches() {
  local field=$1 expected=$2
  receipt_field_is_unique "$field" \
    && /usr/bin/grep -Fqx -- "$field=$expected" "$receipt"
}

receipt=${FORGE_CONTAINED_RUN_RECEIPT:-}
run_id=${FORGE_CONTAINED_RUN_ID:-}
accreditation_file=${FORGE_CONTAINED_RUN_ACCREDITATION_FILE:-}
pid_namespace=${FORGE_CONTAINED_RUN_PID_NAMESPACE:-}
mount_namespace=${FORGE_CONTAINED_RUN_MOUNT_NAMESPACE:-}
product_cleanup_file=${FORGE_PRODUCT_CLEANUP_RESULT_FILE:-}

case "$receipt" in
  "$EXPECTED_RECEIPT_ROOT"/run-*/receipt.txt) ;;
  *) fail 'falta un recibo en la ruta fijada por el contrato.' ;;
esac

run_dir=${receipt%/receipt.txt}
[[ -n $run_id && $run_id == "${run_dir##*/}" ]] || fail 'el identificador del recibo no coincide.'
[[ $accreditation_file == "$run_dir/accreditation.status" ]] || fail 'la ruta de acreditacion no corresponde al directorio del recibo declarado.'
[[ $product_cleanup_file == "$run_dir/product-cleanup.result" ]] || fail 'la ruta del resultado de limpieza no corresponde al directorio del recibo declarado.'
[[ -f $receipt && ! -L $receipt ]] || fail 'el recibo inicial no existe o no es un fichero regular.'
[[ -f $accreditation_file && ! -L $accreditation_file ]] || fail 'la acreditacion de esta invocacion no existe.'
[[ $(<"$accreditation_file") == PASS ]] || fail 'el estado declarado de acreditacion PID/proc no es PASS.'

receipt_field_matches IDENTIFIER "$run_id" \
  || fail 'IDENTIFIER del recibo no es unico o no coincide con el identificador declarado.'
receipt_field_matches RECEIPT_PATH "$receipt" \
  || fail 'RECEIPT_PATH no es unico o no coincide con la ruta declarada.'
[[ $pid_namespace =~ ^pid:\[[0-9]+\]$ ]] || fail 'identidad del namespace PID ausente o invalida.'
[[ $mount_namespace =~ ^mnt:\[[0-9]+\]$ ]] || fail 'identidad del namespace mount ausente o invalida.'

current_pid_namespace=$(/usr/bin/readlink /proc/self/ns/pid 2>/dev/null) || fail 'no se puede leer el namespace PID actual.'
# In the controlled launch chain, the direct invoker retains FD 8 across its
# subprocess call. Read its kernel PID-namespace reference (not an env claim).
# This establishes only inequality with the checker’s namespace below; it does
# not authenticate this invocation’s provenance or the boundary’s direction.
invoker_pid_namespace=$(/usr/bin/readlink "/proc/$PPID/fd/$INVOKER_PID_NAMESPACE_FD" 2>/dev/null) \
  || fail 'no se puede leer la referencia PID de FD 8 en el invocador directo.'
init_pid_namespace=$(/usr/bin/readlink /proc/1/ns/pid 2>/dev/null) || fail 'no se puede leer el namespace PID de PID 1.'
current_mount_namespace=$(/usr/bin/readlink /proc/self/ns/mnt 2>/dev/null) || fail 'no se puede leer el namespace mount actual.'
[[ $invoker_pid_namespace =~ ^pid:\[[0-9]+\]$ ]] \
  || fail 'el descriptor heredado no referencia un namespace PID del kernel.'
[[ $current_pid_namespace != "$invoker_pid_namespace" ]] \
  || fail 'el namespace PID del comprobador es igual al referido por FD 8 en el invocador directo; se exige desigualdad.'
[[ $current_pid_namespace == "$pid_namespace" && $init_pid_namespace == "$pid_namespace" ]] \
  || fail 'el namespace PID actual y el de PID 1 no coinciden con PID_NAMESPACE declarado.'
[[ $current_mount_namespace == "$mount_namespace" ]] || fail 'el namespace mount actual no coincide con MOUNT_NAMESPACE declarado.'
[[ $(/usr/bin/awk '{ print $1; exit }' /proc/1/stat 2>/dev/null) == 1 ]] \
  || fail 'PID 1 no es visible en el /proc actual.'
[[ $(/usr/bin/stat -f -c '%T' /proc 2>/dev/null) == proc ]] || fail '/proc no es procfs.'
/usr/bin/awk '$5 == "/proc" { for (i=6; i<=NF; i++) if ($i == "-") { if ($(i+1) == "proc") found=1; break } } END { exit !found }' \
  /proc/self/mountinfo 2>/dev/null || fail '/proc no esta montado en el namespace actual.'

printf 'V2 PID namespace coherence PASS: run=%s; el namespace del comprobador difiere del referido por FD 8 en su invocador directo; esto no acredita procedencia ni direccion de frontera. Verifique la cadena controlada y el cierre exterior confirmado.\n' "$run_id" >&2
