#!/usr/bin/env bash
# cutover.sh -- cutover de OpenCode 1.19.4 a OpenCode 2.1.4 (Forge).
#
# Fail-fast. Cada paso verifica su resultado antes de pasar al siguiente. Un
# aborto devuelve codigo distinto de cero y conserva el informe/evidencia; no
# ejecuta rollback ni recuperacion automatica. Si el fallo ocurre despues de
# un reemplazo, los cambios parciales anteriores pueden permanecer.
#
# Uso (produccion):
#   bash open-code/cutover-v2/cutover.sh
#
# Uso (sandbox): todas las rutas se parametrizan por entorno.
#   HOME=/tmp/... CUTOVER_BACKUP_DIR=... CUTOVER_REPO_ROOT=... CUTOVER_DB=... \
#     bash open-code/cutover-v2/cutover.sh
#
# Variables de entorno (con valor por defecto: la maquina real):
#   CUTOVER_HOME            HOME efectivo (por defecto: $HOME)
#   CUTOVER_BACKUP_DIR      directorio de backup (por defecto: el backup verificado)
#   CUTOVER_REPO_ROOT       raiz del repo forge (por defecto: el checkout actual)
#   CUTOVER_DB              base de datos productiva (por defecto: $HOME/.local/share/opencode/opencode.db)
#   CUTOVER_PRODUCTION_DB   ruta de referencia para clasificar destino productivo frente a sandbox
#   CUTOVER_EXPECTED_BRANCH rama esperada del repo (por defecto: master)
#   CUTOVER_EXPECTED_COMMIT commit esperado del repo (por defecto: el actual)
#   CUTOVER_EXPECTED_VERSION version de OpenCode 2 esperada (por defecto: 2.1.4)
#   CUTOVER_MIGRATION_TIMEOUT segundos de espera para la migracion (por defecto: 3600)
#   CUTOVER_SKIP_INSTALL=1  no reinstala el overlay (solo para pruebas)
#   CUTOVER_SKIP_MIGRATION=1 no dispara la migracion (solo para pruebas)

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBTOOL="$SCRIPT_DIR/lib/dbtool.py"
SAFETY_LIB="$SCRIPT_DIR/lib/cutover_safety.py"
if [ ! -f "$SAFETY_LIB" ]; then
  printf '[cutover] ERROR: falta la biblioteca de seguridad requerida: %s\n' "$SAFETY_LIB" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parametrizacion
# ---------------------------------------------------------------------------
PROCESS_HOME="${HOME:-}"
if command -v getent >/dev/null 2>&1 && command -v id >/dev/null 2>&1; then
  account_home="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6 | head -1 || true)"
  [ -n "$account_home" ] && PROCESS_HOME="$account_home"
fi
CUTOVER_HOME="${CUTOVER_HOME:-$HOME}"
[ -n "$PROCESS_HOME" ] || PROCESS_HOME="$CUTOVER_HOME"
CUTOVER_BACKUP_DIR="${CUTOVER_BACKUP_DIR:-$HOME/forge-v2-backup-20261024-203342}"
CUTOVER_REPO_ROOT="${CUTOVER_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CUTOVER_DB="${CUTOVER_DB:-${OPENCODE_DB:-$CUTOVER_HOME/.local/share/opencode/opencode.db}}"
CUTOVER_PRODUCTION_DB="${CUTOVER_PRODUCTION_DB:-$PROCESS_HOME/.local/share/opencode/opencode.db}"
CUTOVER_EXPECTED_BRANCH="${CUTOVER_EXPECTED_BRANCH:-master}"
CUTOVER_EXPECTED_COMMIT="${CUTOVER_EXPECTED_COMMIT:-}"
CUTOVER_EXPECTED_VERSION="${CUTOVER_EXPECTED_VERSION:-2.1.4}"
CUTOVER_MIGRATION_TIMEOUT="${CUTOVER_MIGRATION_TIMEOUT:-3600}"
CUTOVER_SKIP_INSTALL="${CUTOVER_SKIP_INSTALL:-0}"
CUTOVER_SKIP_MIGRATION="${CUTOVER_SKIP_MIGRATION:-0}"

export HOME="$CUTOVER_HOME"

DB_DIR="$(dirname "$CUTOVER_DB")"
BACKUP_DB="$CUTOVER_BACKUP_DIR/opencode.db"
BACKUP_DB_MIGRATED="$CUTOVER_BACKUP_DIR/opencode.db.migrated"
BACKUP_MANIFEST="$CUTOVER_BACKUP_DIR/MANIFEST.tsv"
SNAPSHOT="$CUTOVER_BACKUP_DIR/opencode.db.precutover"
ORIGINAL_MOVED="$CUTOVER_BACKUP_DIR/opencode.db.precutover-original"
REPORT="$CUTOVER_BACKUP_DIR/CUTOVER-REPORT.md"
WORKDIR="$CUTOVER_BACKUP_DIR/.cutover-work"

OVERLAY_DIR="${OPENCODE_CONFIG_DIR:-$CUTOVER_HOME/.config/opencode-forge}"
OVERLAY_CONFIG="${OPENCODE_CONFIG:-$OVERLAY_DIR/opencode.jsonc}"
FORGE_BIN_DIR="${FORGE_OPENCODE_BIN_DIR:-${XDG_DATA_HOME:-$CUTOVER_HOME/.local/share}/forge/opencode-v2}"
FORGE_BIN="$FORGE_BIN_DIR/node_modules/.bin/opencode"
STATE_FILE="$CUTOVER_HOME/.forge-state.json"
TOKENS_FILE="$CUTOVER_HOME/.opencode-tokens"
OMARCHY_DIR="$CUTOVER_HOME/.local/share/omarchy"

# ---------------------------------------------------------------------------
# Instrumentacion
# ---------------------------------------------------------------------------
STEP_NO=0
STEP_NAME=""
RUN_START="$(date +%s)"
FAILED_STEP=""
FAILED_LINE=""
LOG_FILE="$WORKDIR/cutover.log"
REPORT_BODY="$WORKDIR/report-body.md"

# Valores que pueden no existir si se salta un paso; se inicializan para que
# `set -u` no rompa la verificacion final.
bin_version=""
m_dir=""
m_cfg=""
m_bin=""
launcher_version=""

PROC_INVENTORY_COMPLETE=1
PROC_INVENTORY_ERRORS_FILE="$WORKDIR/proc-inventory-errors.txt"
PROC_SCAN_SEQUENCE=0
PROC_DB_HOLDERS_FILE=""
PROC_DB_BLOCKERS_FILE=""
PROC_OPENCODE_PROCESSES_FILE=""
PROC_OPENCODE_WRITERS_FILE=""
SERVE_PID=""
SERVE_START_TICKS=""
SERVE_LAUNCH_EXE_ORIGINAL=""
SERVE_EXE_NORMALIZED=""
SERVE_EXE_DEV_INODE=""
SERVE_REG_VALID=0
SERVER_STOP_DONE=0
SERVER_STOP_STATUS=0
FINALIZER_DONE=0

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_s() { date +%s; }

say() { printf '[cutover] %s\n' "$*" | tee -a "$LOG_FILE" >&2; }

step() {
  STEP_NO=$((STEP_NO + 1))
  STEP_NAME="$1"
  say "=============================================================="
  say "STEP $STEP_NO: $STEP_NAME"
  say "=============================================================="
  printf '\n## STEP %s — %s\n\n' "$STEP_NAME" "$(ts)" >>"$REPORT_BODY"
}

# Registra una linea de salida literal en el informe.
lit() { printf '```\n%s\n```\n\n' "$*" >>"$REPORT_BODY"; }
# Registra el contenido de un fichero como bloque literal en el informe.
lit_file() { printf '```\n' >>"$REPORT_BODY"; cat "$1" >>"$REPORT_BODY"; printf '```\n\n' >>"$REPORT_BODY"; }
note() { printf '%s\n\n' "$*" >>"$REPORT_BODY"; }

die() {
  FAILED_STEP="${STEP_NO:-0}:${STEP_NAME:-preflight}"
  FAILED_LINE="$1"
  say "ERROR en $FAILED_STEP: $2"
  printf '\n**FALLO en el paso %s**\n\n```\n%s\n```\n\n' "$FAILED_STEP" "$2" >>"$REPORT_BODY"
  exit 1
}

# json_get <fichero.json> <expresion python sobre d>
# El ambito de eval incluye el modulo json para poder serializar.
json_get() {
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(eval(sys.argv[2],{"d":d,"json":json}))' "$1" "$2"
}

# json_lines <fichero.json> <expresion python sobre d>  -> un elemento por linea
json_lines() {
  python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));v=eval(sys.argv[2],{"d":d,"json":json});print("\n".join(str(x) for x in v))' "$1" "$2"
}

write_report() {
  local verdict="${1:-DESCONOCIDO}"
  local end_ts
  end_ts="$(ts)"
  {
    printf '# Informe de cutover OpenCode 1.19.4 -> V2 %s\n\n' "$CUTOVER_EXPECTED_VERSION"
    printf -- '- **Generado**: %s\n' "$end_ts"
    printf -- '- **Veredicto**: **%s**\n' "$verdict"
    printf -- '- **HOME efectivo**: `%s`\n' "$CUTOVER_HOME"
    printf -- '- **Base de datos**: `%s`\n' "$CUTOVER_DB"
    printf -- '- **Directorio de backup**: `%s`\n' "$CUTOVER_BACKUP_DIR"
    printf -- '- **Repo**: `%s`\n' "$CUTOVER_REPO_ROOT"
    printf -- '- **Duración**: %s s\n' "$(( $(now_s) - RUN_START ))"
    if [ -n "$FAILED_STEP" ]; then
      printf -- '- **Paso fallido**: `%s` (%s)\n' "$FAILED_STEP" "$FAILED_LINE"
    fi
    printf '\n'
    cat "$REPORT_BODY"
  } >"$REPORT.tmp"
  mv "$REPORT.tmp" "$REPORT"
  say "informe escrito en $REPORT"
}

finalize_exit() {
  local rc="$1" line="$2" cleanup_rc=0 verdict
  [ "$FINALIZER_DONE" = "1" ] && exit "$rc"
  FINALIZER_DONE=1
  trap - EXIT ERR
  trap '' INT TERM
  set +e

  if [ "$SERVER_STOP_DONE" = "1" ]; then
    cleanup_rc="$SERVER_STOP_STATUS"
  elif [ -n "${SERVE_PID:-}" ]; then
    stop_server
    cleanup_rc=$?
  fi
  if [ "$rc" -eq 0 ] && [ "$cleanup_rc" -ne 0 ]; then
    rc=1
    FAILED_STEP="${STEP_NO:-0}:${STEP_NAME:-finalizacion}"
    FAILED_LINE="limpieza final del servidor/holders no demostrada"
    printf '\n**FALLO de limpieza final**\n\n' >>"$REPORT_BODY"
  fi
  if [ "$rc" -ne 0 ] && [ -z "$FAILED_STEP" ]; then
    FAILED_STEP="${STEP_NO:-0}:${STEP_NAME:-?}"
    FAILED_LINE="linea ${line:-?} (rc=$rc)"
    say "ERROR no controlado en $FAILED_STEP (rc=$rc)"
    printf '\n**FALLO no controlado**: `%s`\n\n' "$FAILED_LINE" >>"$REPORT_BODY"
  fi
  if [ "$cleanup_rc" -ne 0 ]; then
    printf '\n**Limpieza final incompleta**: holders ajenos/no atribuibles o inventario no exhaustivo; no fueron señalados.\n\n' >>"$REPORT_BODY"
  fi
  note "Un aborto no ejecuta rollback ni recuperación automática. Si ocurrió después de modificar datos, esos cambios parciales permanecen para revisión; este finalizador no restaura archivos ni repite la migración."
  if [ "$rc" -eq 0 ]; then verdict="OK — cutover completado y verificado"; else verdict="FALLO — sin rollback automático"; fi
  if ! write_report "$verdict"; then
    say "ERROR: no se pudo escribir el informe final despues de la limpieza"
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}

trap 'finalize_exit "$?" "$LINENO"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$WORKDIR"
: >"$LOG_FILE"
: >"$REPORT_BODY"
: >"$PROC_INVENTORY_ERRORS_FILE"

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "falta el comando '$1' en el PATH"
}

# ---------------------------------------------------------------------------
# STEP 1 — PREFLIGHT
# ---------------------------------------------------------------------------
step "PREFLIGHT"

need_cmd python3
need_cmd git
need_cmd jq
check_pidfd_support

say "HOME=$CUTOVER_HOME"
say "DB=$CUTOVER_DB"
say "BACKUP=$CUTOVER_BACKUP_DIR"
say "REPO=$CUTOVER_REPO_ROOT"

# --- 1.1 No hay ningun escritor ------------------------------------------------
# Dos comprobaciones INDEPENDIENTES:
#   (a) fd check: se recorren TODOS los procesos y se busca cualquiera que tenga
#       un descriptor abierto sobre la base, su -wal o su -shm. Esta es la
#       garantia real de "no hay escritor", y no depende de como se llame el
#       ejecutable: un opencode lanzado a traves de un wrapper, de npx o de un
#       symlink tambien se detecta.
#   (b) process check: ningun proceso opencode vivo opera sobre ESTA base o
#       sobre ESTE HOME. Un proceso opencode con otra base (por ejemplo el
#       servicio V2 de una sesion de pruebas) se tolera, pero queda registrado en
#       el informe para que la decision sea auditable.
check_pidfd_support() {
  python3 "$SAFETY_LIB" pidfd-support \
    || die "preflight/pidfd" "Python/kernel no ofrecen pidfd_open y pidfd_send_signal; no se modifica ningún dato sin señalización segura"
}

pidfd_stop_registered_server() {
  python3 "$SAFETY_LIB" pidfd-stop "$SERVE_PID" "$SERVE_START_TICKS" \
    "$SERVE_EXE_NORMALIZED" "$SERVE_EXE_DEV_INODE" "$$"
}

# Procfs classification and identity validation are shared with the isolated bank.
scan_proc_inventory() {
  local target_db="$1" tag="$2" scan_dir state_file

  PROC_SCAN_SEQUENCE=$((PROC_SCAN_SEQUENCE + 1))
  tag="${tag//[^A-Za-z0-9_.-]/_}"
  scan_dir="$WORKDIR/proc-inventory-${PROC_SCAN_SEQUENCE}-${tag}"
  mkdir -m 700 -- "$scan_dir" || return 2
  PROC_INVENTORY_ERRORS_FILE="$scan_dir/inventory-errors.txt"
  PROC_DB_HOLDERS_FILE="$scan_dir/db-holders.txt"
  PROC_DB_BLOCKERS_FILE="$scan_dir/db-blockers.txt"
  PROC_OPENCODE_PROCESSES_FILE="$scan_dir/opencode-processes.txt"
  PROC_OPENCODE_WRITERS_FILE="$scan_dir/opencode-target-writers.txt"
  state_file="$scan_dir/scan-state.json"

  python3 "$SAFETY_LIB" scan-cutover \
    --target-db "$target_db" --tag "$tag" --sequence "$PROC_SCAN_SEQUENCE" \
    --scan-dir "$scan_dir" --production-db "$CUTOVER_PRODUCTION_DB" \
    --cutover-home "$CUTOVER_HOME" --process-home "$PROCESS_HOME" \
    --shell-pid "$$" --cwd "$PWD" --registration-valid "$SERVE_REG_VALID" \
    --serve-pid "$SERVE_PID" --serve-start "$SERVE_START_TICKS" \
    --serve-exe "$SERVE_EXE_NORMALIZED" --serve-dev-inode "$SERVE_EXE_DEV_INODE" \
    --state-file "$state_file" || return $?
  case "$(json_get "$state_file" "d['complete']")" in
    True|true|1) PROC_INVENTORY_COMPLETE=1 ;;
    *) PROC_INVENTORY_COMPLETE=0 ;;
  esac
}

check_db_holders() {
  local database="$1" label="$2"
  if ! scan_proc_inventory "$database" "$label"; then
    say "ERROR: no se pudo crear el inventario independiente para $label"
    note "Comprobación \`$label\` de \`$database\`: inventario no disponible; se aborta sin señales."
    return 1
  fi
  note "Comprobación independiente \`$label\` para \`$database\` (no sobrescribe preflight): holders e identidad original."
  lit_file "$PROC_DB_HOLDERS_FILE"
  if [ "$PROC_INVENTORY_COMPLETE" != "1" ]; then
    say "ERROR: inventario no exhaustivo en $label; no se declara ausencia de holders"
    note "Errores del inventario \`$label\`:"
    lit_file "$PROC_INVENTORY_ERRORS_FILE"
    return 1
  fi
  if [ -s "$PROC_DB_BLOCKERS_FILE" ]; then
    say "ERROR: holders ajenos/no atribuibles en $label; no se enviaron señales"
    note "Bloqueos conservados sin señalizar en \`$label\`:"
    lit_file "$PROC_DB_BLOCKERS_FILE"
    return 1
  fi
  say "OK: $label sin holders ajenos/no atribuibles; inventario exhaustivo"
  return 0
}

require_db_clear() {
  local database="$1" label="$2" step_label="$3"
  check_db_holders "$database" "$label" \
    || die "$step_label" "hay holders ajenos/no atribuibles o el inventario de /proc no es exhaustivo para $database; aborta sin señalizar procesos"
}

stop_server() {
  local failed=0 signal_rc=0 wait_rc=0
  if [ "$SERVER_STOP_DONE" = "1" ]; then return "$SERVER_STOP_STATUS"; fi
  SERVER_STOP_DONE=1
  SERVER_STOP_STATUS=1
  say "comprobando holders antes de parar el servidor registrado"
  if ! check_db_holders "$CUTOVER_DB" server-stop-before; then failed=1; fi

  if [ -n "$SERVE_PID" ]; then
    if [ "$SERVE_REG_VALID" = "1" ]; then
      if pidfd_stop_registered_server >"$WORKDIR/server-stop-pidfd.txt" 2>&1; then
        say "señalización pidfd del servidor registrado completada"
        if wait "$SERVE_PID"; then wait_rc=0; else wait_rc=$?; fi
        say "hijo directo recolectado (wait rc=$wait_rc)"
        SERVE_PID=""
      else
        signal_rc=$?
        say "ERROR: pidfd no demostró la identidad/terminación (rc=$signal_rc); no se intentó otra señal"
        note "Resultado pidfd del servidor (sin fallback por PID/grupo):"
        lit_file "$WORKDIR/server-stop-pidfd.txt"
        failed=1
      fi
    else
      say "ERROR: registro/identidad del servidor incompleto; queda sin señalar por falta de propiedad demostrada"
      note "Servidor $SERVE_PID sin señalizar: no se completó su registro de propiedad e identidad."
      failed=1
    fi
  fi

  say "comprobando holders después de parar el servidor"
  if ! check_db_holders "$CUTOVER_DB" server-stop-after; then failed=1; fi
  SERVER_STOP_STATUS="$failed"
  return "$failed"
}

register_server_child() {
  local pid="$1" state_file="$WORKDIR/server-registration.json" parent
  SERVE_PID="$pid"
  SERVE_REG_VALID=0
  SERVE_START_TICKS=""
  if ! python3 "$SAFETY_LIB" register-server "$pid" "$$" "$FORGE_BIN" "$state_file"; then
    return 1
  fi
  SERVE_START_TICKS="$(json_get "$state_file" "d['start_ticks']")"
  SERVE_LAUNCH_EXE_ORIGINAL="$(json_get "$state_file" "d['launch_exe_original']")"
  SERVE_EXE_NORMALIZED="$(json_get "$state_file" "d['exe_normalized']")"
  SERVE_EXE_DEV_INODE="$(json_get "$state_file" "d['exe_dev_inode']")"
  parent="$(json_get "$state_file" "d['parent']")"
  SERVE_REG_VALID=1
  say "servidor registrado: pid=$SERVE_PID inicio_ticks=$SERVE_START_TICKS exe_lanzamiento=$SERVE_LAUNCH_EXE_ORIGINAL exe_normalizado=$SERVE_EXE_NORMALIZED dev_inode=$SERVE_EXE_DEV_INODE parent=$parent"
}

say "--- 1.1 inventario de procesos y destinos DB accesibles"
scan_proc_inventory "$CUTOVER_DB" preflight
say "--- 1.1a procesos con la base objetivo abierta (cualquier ejecutable)"
if [ -s "$PROC_DB_HOLDERS_FILE" ]; then
  say "procesos con la base abierta:"
  while IFS= read -r line; do say "  $line"; done <"$PROC_DB_HOLDERS_FILE"
else
  say "  (ninguno)"
fi
note "Procesos con un descriptor abierto sobre la base configurada en CUTOVER_DB (cualquier ejecutable):"
lit_file "$PROC_DB_HOLDERS_FILE"
if [ "$PROC_INVENTORY_COMPLETE" != "1" ]; then
  say "ERROR: INVENTARIO DE /proc NO EXHAUSTIVO; no se declara ausencia de procesos con la base abierta"
  note "El inventario de procesos quedó **NO EXHAUSTIVO** porque algún PID desapareció o hubo información/permisos inaccesibles. Se aborta sin detener procesos ni declarar ausencia de escritores."
  note "Errores observados durante el inventario:"
  lit_file "$PROC_INVENTORY_ERRORS_FILE"
  die "preflight/1.1" "inventario de procesos no exhaustivo; revisa los motivos en el informe y repite cuando /proc sea legible y estable"
fi
if [ -s "$PROC_DB_BLOCKERS_FILE" ]; then
  note "Bloqueos no atribuibles al cutover (no se enviaron señales):"
  lit_file "$PROC_DB_BLOCKERS_FILE"
  die "preflight/1.1a" "hay $(wc -l <"$PROC_DB_BLOCKERS_FILE") holder(s) ajenos/no atribuibles. Aborta sin señalarlos; cierra el acceso y vuelve a ejecutar el script."
fi
say "OK: ningún proceso tiene la base objetivo abierta y el inventario fue exhaustivo"

say "--- 1.1b procesos opencode vivos"
if [ -s "$PROC_OPENCODE_PROCESSES_FILE" ]; then
  say "procesos opencode detectados:"
  while IFS= read -r line; do say "  $line"; done <"$PROC_OPENCODE_PROCESSES_FILE"
else
  say "  (ninguno)"
fi
note "Procesos \`opencode\` vivos durante el preflight:"
lit_file "$PROC_OPENCODE_PROCESSES_FILE"
found_writer="$(wc -l <"$PROC_OPENCODE_WRITERS_FILE")"
found_other="$(wc -l <"$PROC_OPENCODE_PROCESSES_FILE")"
found_other=$((found_other - found_writer))
if [ "$found_writer" -gt 0 ]; then
  die "preflight/1.1b" "hay $found_writer proceso/s OpenCode que mantiene/n descriptores o configuración hacia CUTOVER_DB. Aborta sin detener procesos."
fi
say "OK: ningún proceso OpenCode apunta a CUTOVER_DB ($found_other proceso(s) con otro destino accesible, tolerados; clasificados por destino DB, no por ruta del ejecutable)"

# --- 1.2 Backup verificado -----------------------------------------------------
say "--- 1.2 backup verificado"
[ -d "$CUTOVER_BACKUP_DIR" ] || die "preflight/1.2" "no existe el directorio de backup: $CUTOVER_BACKUP_DIR"
[ -f "$BACKUP_MANIFEST" ] || die "preflight/1.2" "no existe $BACKUP_MANIFEST"
[ -f "$BACKUP_DB" ] || die "preflight/1.2" "no existe la copia de la base en el backup: $BACKUP_DB"
[ -f "$BACKUP_DB_MIGRATED" ] || die "preflight/1.2" "no existe la referencia migrada en el backup: $BACKUP_DB_MIGRATED"

manifest_db_row="$(awk -F'\t' '$1 ~ /opencode\.db$/ {print; exit}' "$BACKUP_MANIFEST")"
[ -n "$manifest_db_row" ] || die "preflight/1.2" "MANIFEST.tsv no tiene ninguna fila para la base de datos"
manifest_sha="$(printf '%s' "$manifest_db_row" | cut -f4)"
manifest_size="$(printf '%s' "$manifest_db_row" | cut -f3)"
say "MANIFEST: sha256=$manifest_sha size=$manifest_size"
actual_size="$(stat -L -c '%s' "$BACKUP_DB")"
if [ "$actual_size" != "$manifest_size" ]; then
  die "preflight/1.2" "el tamano de $BACKUP_DB ($actual_size) no coincide con MANIFEST.tsv ($manifest_size). El backup no es el verificado."
fi
say "OK: tamano de la copia del backup coincide con MANIFEST.tsv"

if [ "${CUTOVER_VERIFY_BACKUP_HASH:-1}" = "1" ]; then
  say "verificando sha256 de la copia del backup (puede tardar)..."
  actual_sha="$(sha256sum "$BACKUP_DB" | cut -d' ' -f1)"
  if [ "$actual_sha" != "$manifest_sha" ]; then
    die "preflight/1.2" "el sha256 de $BACKUP_DB ($actual_sha) no coincide con MANIFEST.tsv ($manifest_sha). El backup esta corrupto."
  fi
  say "OK: sha256 de la copia del backup coincide con MANIFEST.tsv"
else
  say "AVISO: verificacion de sha256 del backup omitida (CUTOVER_VERIFY_BACKUP_HASH=0)"
fi

# --- 1.3 Espacio en disco ------------------------------------------------------
say "--- 1.3 espacio en disco"
db_bytes="$(stat -L -c '%s' "$CUTOVER_DB")"
need_bytes=$((db_bytes + 512 * 1024 * 1024))
avail_backup="$(df -B1 --output=avail "$CUTOVER_BACKUP_DIR" | tail -1 | tr -d ' ')"
avail_db="$(df -B1 --output=avail "$DB_DIR" | tail -1 | tr -d ' ')"
say "base=$db_bytes bytes; disponible backup=$avail_backup; disponible datos=$avail_db; necesario=$need_bytes"
[ "$avail_backup" -ge "$need_bytes" ] || die "preflight/1.3" "espacio insuficiente en $CUTOVER_BACKUP_DIR: hay $avail_backup bytes, hacen falta $need_bytes"
[ "$avail_db" -ge "$need_bytes" ] || die "preflight/1.3" "espacio insuficiente en $DB_DIR: hay $avail_db bytes, hacen faltan $need_bytes"
note "Espacio en disco verificado: la base ocupa \`$db_bytes\` bytes; el backup tiene \`$avail_backup\` bytes libres y el directorio de datos \`$avail_db\`."

# --- 1.4 Repo limpio y en la rama correcta -------------------------------------
say "--- 1.4 repo"
[ -d "$CUTOVER_REPO_ROOT/.git" ] || die "preflight/1.4" "$CUTOVER_REPO_ROOT no es un checkout git"
repo_branch="$(git -C "$CUTOVER_REPO_ROOT" rev-parse --abbrev-ref HEAD)"
repo_commit="$(git -C "$CUTOVER_REPO_ROOT" rev-parse HEAD)"
repo_dirty="$(git -C "$CUTOVER_REPO_ROOT" status --porcelain --untracked-files=no)"
say "rama=$repo_branch commit=$repo_commit"
if [ "$repo_branch" != "$CUTOVER_EXPECTED_BRANCH" ]; then
  die "preflight/1.4" "el repo esta en la rama '$repo_branch' y se esperaba '$CUTOVER_EXPECTED_BRANCH'"
fi
if [ -n "$repo_dirty" ]; then
  die "preflight/1.4" "el repo tiene cambios sin commitear:
$repo_dirty"
fi
if [ -n "$CUTOVER_EXPECTED_COMMIT" ] && [ "$repo_commit" != "$CUTOVER_EXPECTED_COMMIT" ]; then
  die "preflight/1.4" "el repo esta en $repo_commit y se esperaba $CUTOVER_EXPECTED_COMMIT"
fi
say "OK: repo limpio en $repo_branch @ ${repo_commit:0:12}"
note "Repo verificado: rama \`$repo_branch\`, commit \`$repo_commit\`, working tree limpio."

# --- 1.5 La base productiva existe y esta sana ---------------------------------
say "--- 1.5 base productiva"
[ -f "$CUTOVER_DB" ] || die "preflight/1.5" "no existe la base de datos productiva: $CUTOVER_DB"
python3 "$DBTOOL" check --db "$CUTOVER_DB" --json "$WORKDIR/preflight-db.json" >/dev/null \
  || die "preflight/1.5" "no se pudo inspeccionar la base de datos productiva"
qc="$(json_get "$WORKDIR/preflight-db.json" "d['quick_check']")"
[ "$qc" = "ok" ] || die "preflight/1.5" "quick_check de la base productiva: $qc"
say "OK: quick_check=ok"
note "Base productiva verificada: \`quick_check=ok\`, marcador de migracion \`$(json_get "$WORKDIR/preflight-db.json" "d['marker']")\`."

# --- 1.6 Estado de lo que NO se debe tocar --------------------------------------
say "--- 1.6 omarchy y tokens"
omarchy_state=""
if [ -d "$OMARCHY_DIR" ]; then
  omarchy_state="$(find "$OMARCHY_DIR" -maxdepth 3 -printf '%y %s %T@ %p\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
fi
tokens_state=""
if [ -f "$TOKENS_FILE" ]; then
  tokens_state="$(sha256sum "$TOKENS_FILE" | cut -d' ' -f1)"
fi
say "omarchy=$omarchy_state tokens=$tokens_state"
note "Huella de lo que el cutover no debe tocar: \`~/.local/share/omarchy\` = \`${omarchy_state:-<no existe>}\`, \`~/.opencode-tokens\` = \`${tokens_state:-<no existe>}\`."

# --- 1.7 Utilidades del overlay ------------------------------------------------
say "--- 1.7 overlay previo"
if [ -e "$OVERLAY_DIR" ] || [ -e "$FORGE_BIN_DIR" ]; then
  say "AVISO: ya existe un overlay/prefix previo; el instalador lo sobrescribira"
  note "Ya existia un overlay en \`$OVERLAY_DIR\` y/o un prefix en \`$FORGE_BIN_DIR\`. El instalador los sobrescribe."
fi

say "PREFLIGHT OK"

# ---------------------------------------------------------------------------
# STEP 2 — SNAPSHOT FRESCO DE LA BASE PRODUCTIVA
# ---------------------------------------------------------------------------
step "SNAPSHOT FRESCO DE LA BASE PRODUCTIVA"

say "snapshot de $CUTOVER_DB -> $SNAPSHOT (API de backup de SQLite, nunca cp)"
python3 "$DBTOOL" snapshot --src "$CUTOVER_DB" --dst "$SNAPSHOT" --json "$WORKDIR/snapshot.json" >/dev/null \
  || die "snapshot" "el snapshot con la API de backup de SQLite fallo (ver $WORKDIR/snapshot.json)"

snap_qc="$(json_get "$WORKDIR/snapshot.json" "d['quick_check']")"
[ "$snap_qc" = "ok" ] || die "snapshot" "quick_check del snapshot: $snap_qc"

EXPECTED_SESSIONS="$(json_get "$WORKDIR/snapshot.json" "d['counts']['session']")"
SNAP_MARKER="$(json_get "$WORKDIR/snapshot.json" "d['marker']")"
say "OK: snapshot quick_check=ok, sesiones v1=$EXPECTED_SESSIONS, marcador=$SNAP_MARKER"
note "Snapshot fresco: \`quick_check=ok\`, **$EXPECTED_SESSIONS** sesiones v1 como baseline de IDs que deben quedar cubiertos en \`session_v2\`; sesiones nativas V2 pueden aumentar legítimamente el total de V2. Marcador de migracion: \`$SNAP_MARKER\`."
note "El snapshot se hizo con \`sqlite3.Connection.backup()\`, nunca con \`cp\`: un \`cp\` de una base con \`-wal\`/\`-shm\` vivos produce una base inconsistente."

# ---------------------------------------------------------------------------
# STEP 3 — RESET DEL ESTADO DE MIGRACION
# ---------------------------------------------------------------------------
step "RESET DEL ESTADO DE MIGRACION (quirurgico)"

say "--- 3.1 diff empirico: snapshot (v1 + intento interrumpido) vs opencode.db.migrated (v1 + migracion completa)"
python3 "$DBTOOL" diff --a "$SNAPSHOT" --b "$BACKUP_DB_MIGRATED" --json "$WORKDIR/migration-diff.json" >/dev/null \
  || die "reset/3.1" "no se pudo calcular el diff entre el snapshot y la referencia migrada"

python3 - "$WORKDIR/migration-diff.json" >"$WORKDIR/diff-table.txt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rc = d["row_counts"]
print("Marcador de migracion en el snapshot   :", d["marker_a"])
print("Marcador de migracion en la referencia :", d["marker_b"])
print("")
print("%-24s %16s %14s %8s  %s" % ("tabla", "v1+interrumpido", "v1+migrado", "delta", ""))
for t in sorted(rc):
    a, b, delta = rc[t]["a"], rc[t]["b"], rc[t]["delta"]
    mark = "cambia" if delta != 0 else ""
    print("%-24s %16s %14s %8s  %s" % (t, a, b, ("%+d" % delta), mark))
print("")
print("Tablas cuyo recuento cambia: " + ", ".join(d["tables_with_different_row_counts"]))
print("Tablas cuyo recuento NO cambia: " + ", ".join(d["tables_with_identical_row_counts"]))
print("")
print("Aviso: estos recuentos son las mediciones de las dos bases comparadas; no")
print("  implican igualdad, ni permiten por sí solos deducir pérdida de datos.")
for t in ("event", "event_sequence"):
    if t in rc:
        a, b, delta = rc[t]["a"], rc[t]["b"], rc[t]["delta"]
        print("  %s medido: snapshot=%s, referencia=%s, diferencia calculada=%+d" % (t, a, b, delta))
    else:
        print("  %s: sin medición en ambas bases comparadas" % t)
print("")
if d["schema_differences"]:
    print("Diferencias de esquema:")
    print(json.dumps(d["schema_differences"], indent=2, sort_keys=True))
else:
    print("Esquema IDENTICO en las dos bases: el intento interrumpido ya habia aplicado")
    print("el DDL de V2 (m38), por eso el diff de esquema no aporta nada y el reset")
    print("se apoya en la forma (FK de session_message a session_v2, columna 'created'")
    print("de event) comprobada antes de aplicar.")
PY
while IFS= read -r line; do say "  $line"; done <"$WORKDIR/diff-table.txt"

note "Diff empirico entre el snapshot (v1 + intento interrumpido) y \`opencode.db.migrated\` (v1 + migracion completa de V2). Las tablas cuyo recuento de filas cambia son exactamente las que escribe la migracion de sesiones:"
lit_file "$WORKDIR/diff-table.txt"
note "El reset que se aplica a continuación está acotado a las estructuras que creó o posee V2:"
note "- \`session_v2\` — creada por la migracion de esquema m38 (\`20260804233008_loose_psylocke\`)."
note "- \`session_message\` — tabla de v1 **RECONSTRUIDA** por m38: su clave foranea apunta a \`session_v2(id)\`, no a \`session(id)\`."
note "- \`event\` — V2 es su dueno: m36 (\`reset_v2_session_state\`) la vacia y la migracion de sesiones la vacia en su fase \"Clearing old events\"."
note "- \`event_sequence\` — la escribe la migracion de sesiones (un \`aggregate_id\` por sesion migrada)."
note "- \`kv['migration.v1-v2']\` — el marcador: se **borra la fila**, no se actualiza."
note "Y nada mas: \`session\`, \`message\`, \`part\`, \`todo\`, \`session_share\`, \`credential\`, \`project\`, \`project_directory\`, \`workspace\`, \`migration\` y demas tablas de v1 conservan exactamente su numero de filas, y eso se comprueba despues del reset."

say "--- 3.2 reseteo"
python3 "$DBTOOL" reset --db "$SNAPSHOT" --json "$WORKDIR/reset.json" >/dev/null \
  || die "reset/3.2" "el reseteo quirurgico fallo o la verificacion posterior no cuadra (ver $WORKDIR/reset.json)"

say "--- 3.3 verificacion del reset"
reset_qc="$(json_get "$WORKDIR/reset.json" "d['quick_check']")"
[ "$reset_qc" = "ok" ] || die "reset/3.3" "quick_check tras el reset: $reset_qc"
reset_marker="$(json_get "$WORKDIR/reset.json" "d['marker_after']")"
[ "$reset_marker" = "None" ] || die "reset/3.3" "el marcador de migracion sigue presente tras el reset: $reset_marker"
mismatch="$(json_get "$WORKDIR/reset.json" "d['v1_tables_mismatched']")"
[ "$mismatch" = "{}" ] || die "reset/3.3" "el reset alteró el recuento de tablas de v1: $mismatch"
still="$(json_get "$WORKDIR/reset.json" "d['v2_tables_still_populated']")"
[ "$still" = "{}" ] || die "reset/3.3" "las estructuras de V2 siguen pobladas tras el reset: $still"

say "OK: reset verificado (v1 intacto, V2 vacio, sin marcador)"
note "Reset verificado: las tablas de v1 conservan **exactamente** su numero de filas, las estructuras de V2 quedan vacias y el marcador \`kv['migration.v1-v2']\` ha desaparecido (se **borra la fila**, no se actualiza: la migracion de V2 hace \`INSERT\` — no upsert — del marcador cuando no lo encuentra, y una fila preexistente con la misma clave haria fallar el \`UNIQUE\`)."
note "Recuento de filas antes del reset:"
lit "$(json_get "$WORKDIR/reset.json" "json.dumps(d['counts_before'], indent=2, sort_keys=True)")"
note "Recuento de filas despues del reset:"
lit "$(json_get "$WORKDIR/reset.json" "json.dumps(d['counts_after'], indent=2, sort_keys=True)")"

# ---------------------------------------------------------------------------
# STEP 4 — REEMPLAZO DE LA BASE PRODUCTIVA
# ---------------------------------------------------------------------------
step "REEMPLAZO DE LA BASE PRODUCTIVA"

say "--- 4.1 apartado de la base original"
require_db_clear "$CUTOVER_DB" step4-before-replace "reemplazo/4.1-holders"
mv -- "$CUTOVER_DB" "$ORIGINAL_MOVED" \
  || die "reemplazo/4.1" "no se pudo apartar la base original a $ORIGINAL_MOVED"
for suffix in -wal -shm; do
  if [ -e "$CUTOVER_DB$suffix" ]; then
    mv -- "$CUTOVER_DB$suffix" "$ORIGINAL_MOVED$suffix" \
      || die "reemplazo/4.1" "no se pudo apartar $CUTOVER_DB$suffix al backup"
    say "apartado: $CUTOVER_DB$suffix -> $ORIGINAL_MOVED$suffix"
  fi
done
say "OK: original apartado a $ORIGINAL_MOVED"

say "--- 4.2 colocacion del snapshot reseteado"
mv -- "$SNAPSHOT" "$CUTOVER_DB" \
  || die "reemplazo/4.2" "no se pudo colocar el snapshot reseteado en $CUTOVER_DB"

say "--- 4.3 verificacion en su sitio"
python3 "$DBTOOL" check --db "$CUTOVER_DB" --json "$WORKDIR/replaced-db.json" >/dev/null \
  || die "reemplazo/4.3" "no se pudo inspeccionar la base ya colocada"
rep_qc="$(json_get "$WORKDIR/replaced-db.json" "d['quick_check']")"
[ "$rep_qc" = "ok" ] || die "reemplazo/4.3" "quick_check de la base ya colocada: $rep_qc"
rep_sessions="$(json_get "$WORKDIR/replaced-db.json" "d['v1_session_count']")"
[ "$rep_sessions" = "$EXPECTED_SESSIONS" ] \
  || die "reemplazo/4.3" "la base colocada tiene $rep_sessions sesiones v1 y el snapshot tenia $EXPECTED_SESSIONS"
rep_marker="$(json_get "$WORKDIR/replaced-db.json" "d['marker']")"
[ "$rep_marker" = "None" ] || die "reemplazo/4.3" "la base colocada todavia tiene marcador de migracion: $rep_marker"
say "OK: base colocada, quick_check=ok, $rep_sessions sesiones v1, sin marcador"
note "Base replaced: la original se aparto a \`$ORIGINAL_MOVED\` (junto con su \`-wal\`/\`-shm\`, que pertenecen a la base sustituida) y en su sitio quedo el snapshot reseteado, con \`quick_check=ok\`, **$rep_sessions** sesiones v1 y sin marcador de migracion."

# ---------------------------------------------------------------------------
# STEP 5 — INSTALACION DEL OVERLAY V2
# ---------------------------------------------------------------------------
step "INSTALACION DEL OVERLAY V2"

if [ "$CUTOVER_SKIP_INSTALL" = "1" ]; then
  say "AVISO: instalacion omitida (CUTOVER_SKIP_INSTALL=1)"
  note "Instalacion del overlay **omitida** (\`CUTOVER_SKIP_INSTALL=1\`)."
else
  say "--- 5.1 instalador del overlay, con el entorno neutralizado"
  require_db_clear "$WORKDIR/install-probe.db" install-probe-before "overlay/5.1-probe-before"
  say "    printf 'n\n' | env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \\"
  say "        OPENCODE_DB=<probe> bash install.sh install --target=opencode"
  say "    OPENCODE_DB apunta a una base de sondeo: el instalador valida las"
  say "    credenciales con 'auth list --standalone', que arranca un servidor de"
  say "    OpenCode 2; si esa sonda abriera la base productiva, la migracion"
  say "    se dispararia aqui y no en el paso 6 (que es donde debe ocurrir)."
  install_log="$WORKDIR/install.log"
  set +e
  (
    cd "$CUTOVER_REPO_ROOT" &&
    printf 'n\n' | env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
      OPENCODE_DB="$WORKDIR/install-probe.db" \
      bash install.sh install --target=opencode
  ) >"$install_log" 2>&1
  install_rc=$?
  set -e
  say "install.sh terminó con rc=$install_rc"
  tail -40 "$install_log" | while IFS= read -r line; do say "  | $line"; done
  require_db_clear "$WORKDIR/install-probe.db" install-probe-after "overlay/5.1-probe-after"
  [ "$install_rc" = "0" ] || die "overlay/5.1" "el instalador del overlay fallo con rc=$install_rc (ver $install_log)"
  note "Salida del instalador (rc=$install_rc):"
  lit_file "$install_log"
fi

say "--- 5.2 verificacion del overlay"
[ -d "$FORGE_BIN_DIR" ] || die "overlay/5.2" "no existe el prefix del binario pinado: $FORGE_BIN_DIR"
[ -x "$FORGE_BIN" ] || die "overlay/5.2" "no existe el binario pinado: $FORGE_BIN"
[ -f "$OVERLAY_CONFIG" ] || die "overlay/5.2" "no existe la config del overlay: $OVERLAY_CONFIG"
[ -d "$OVERLAY_DIR/plugin-packages/forge-guard" ] || die "overlay/5.2" "no se instalo el plugin V2 en $OVERLAY_DIR/plugin-packages/forge-guard"
[ -f "$STATE_FILE" ] || die "overlay/5.2" "no existe el manifest de Forge: $STATE_FILE"

bin_version="$("$FORGE_BIN" --version 2>/dev/null | tr -d ' \n' | sed 's/^opencodev//')"
[ "$bin_version" = "$CUTOVER_EXPECTED_VERSION" ] \
  || die "overlay/5.2" "el binario pinado declara la version '$bin_version' y se esperaba '$CUTOVER_EXPECTED_VERSION'"
say "OK: binario pinado $FORGE_BIN ($bin_version), overlay en $OVERLAY_DIR"

m_dir="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.dir // empty)' "$STATE_FILE")"
m_cfg="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.config_file // empty)' "$STATE_FILE")"
m_bin="$(jq -r '[.targets_manifest[]? | select(.name == "opencode")][0] | (.binary // empty)' "$STATE_FILE")"
[ -n "$m_dir" ] || die "overlay/5.2" "el manifest no registra 'dir' para el target opencode"
[ -n "$m_cfg" ] || die "overlay/5.2" "el manifest no registra 'config_file' para el target opencode"
[ -n "$m_bin" ] || die "overlay/5.2" "el manifest no registra 'binary' para el target opencode"
say "OK: manifest dir=$m_dir config_file=$m_cfg binary=$m_bin"
note "Overlay V2 instalado: binario pinado \`$FORGE_BIN\` (\`$bin_version\`), config \`$OVERLAY_CONFIG\`, plugin \`$OVERLAY_DIR/plugin-packages/forge-guard/\`. El manifest \`$STATE_FILE\` registra \`dir=$m_dir\`, \`config_file=$m_cfg\`, \`binary=$m_bin\`."

# El dialecto de la config: V2 usa 'plugins' (array de directorios), 'providers'
# y no tiene 'small_model'.
python3 - "$OVERLAY_CONFIG" <<'PY' || die "overlay/5.3" "la config del overlay no esta en dialecto V2"
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
raw = re.sub(r"^\s*//.*$", "", raw, flags=re.M)
raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
cfg = json.loads(raw)
plugins = cfg.get("plugins")
assert isinstance(plugins, list), "plugins no es un array"
assert plugins, "plugins esta vacio"
for p in plugins:
    assert isinstance(p, str), "plugins contiene un elemento que no es una ruta"
assert "providers" in cfg, "falta 'providers'"
assert "small_model" not in cfg, "la config V1 todavia declara 'small_model'"
print("plugins=%s providers=%s small_model=ausente" % (plugins, list(cfg.get("providers", {}))))
PY
say "OK: config del overlay en dialecto V2"

# ---------------------------------------------------------------------------
# STEP 6 — MIGRACION
# ---------------------------------------------------------------------------
step "MIGRACION DE LOS DATOS (OpenCode 2)"

if [ "$CUTOVER_SKIP_MIGRATION" = "1" ]; then
  say "AVISO: migracion omitida (CUTOVER_SKIP_MIGRATION=1)"
  note "Migracion **omitida** (\`CUTOVER_SKIP_MIGRATION=1\`)."
else
  say "--- 6.1 invocacion que dispara la migracion"
  say "La migracion v1->v2 la dispara el arranque del servidor de OpenCode 2:"
  say "  el binario arranca -> la capa V1Migration (packages/core/src/database/v1-migration.bun.ts)"
  say "  bifurca run() -> como no existe el marcador kv['migration.v1-v2'], la migracion"
  say "  empieza de cero: borra el log de eventos, inserta el marcador {phase:'sessions'}"
  say "  y recorre TODAS las filas de 'session' (session -> session_v2 + session_message)."
  say "  El estado se consulta en GET /api/experimental/migration/v1 (Basic auth: opencode:<password>)."
  note "**Que dispara la migracion**: el arranque del servidor de OpenCode 2. La capa \`V1Migration\` (\`packages/core/src/database/v1-migration.bun.ts\`) bifurca \`run()\` al arrancar el servidor; como el reset ha borrado el marcador \`kv['migration.v1-v2']\`, \`run()\` empieza de cero y recorre todas las sesiones. El estado se consulta en \`GET /api/experimental/migration/v1\`."

  require_db_clear "$CUTOVER_DB" step6-before-server "migracion/6.2-holders"
  SERVER_PASSWORD="cutover-$$-$(date +%s)"
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  SERVE_LOG="$WORKDIR/serve.log"
  SERVE_PID=""
  SERVE_START_TICKS=""
  SERVE_REG_VALID=0
  SERVER_STOP_DONE=0
  SERVER_STOP_STATUS=0
  say "puerto=$PORT"

  say "--- 6.2 arranque del servidor privado de OpenCode 2"
  (
    cd "$WORKDIR"
    export HOME="$CUTOVER_HOME"
    export XDG_DATA_HOME="${XDG_DATA_HOME:-$CUTOVER_HOME/.local/share}"
    export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$CUTOVER_HOME/.config}"
    export XDG_STATE_HOME="${XDG_STATE_HOME:-$CUTOVER_HOME/.local/state}"
    export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$CUTOVER_HOME/.cache}"
    export OPENCODE_PASSWORD="$SERVER_PASSWORD"
    export OPENCODE_SERVER_PASSWORD="$SERVER_PASSWORD"
    export OPENCODE_DB="$CUTOVER_DB"
    export OPENCODE_CONFIG_DIR="$OVERLAY_DIR"
    export OPENCODE_CONFIG="$OVERLAY_CONFIG"
    export OPENCODE_DISABLE_AUTOUPDATE=1
    export OPENCODE_DISABLE_MODELS_FETCH=1
    export OPENCODE_DISABLE_CHANNEL_DB=1
    export OPENCODE_CONFIG_PROJECT_DISABLE=1
    export OPENCODE_DISABLE_FILEWATCHER=1
    exec "$FORGE_BIN" serve --hostname 127.0.0.1 --port "$PORT" --print-logs
  ) >"$SERVE_LOG" 2>&1 &
  SERVE_PID=$!
  register_server_child "$SERVE_PID" \
    || die "migracion/6.2-registro" "el hijo del servidor desapareció, dejó de ser hijo directo o no alcanzó la identidad de FORGE_BIN; queda sin señales por falta de propiedad demostrada"
  say "servidor V2 registrado (pid=$SERVE_PID), log en $SERVE_LOG"

  say "--- 6.3 espera del estado de migracion"
  migration_status="$(python3 - "$PORT" "$SERVER_PASSWORD" "$CUTOVER_MIGRATION_TIMEOUT" <<'PY'
import base64, json, sys, time, urllib.request, urllib.error

port, password, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
base = "http://127.0.0.1:%s" % port
token = base64.b64encode(("opencode:" + password).encode()).decode()
deadline = time.time() + timeout
last = "sin contacto"
while time.time() < deadline:
    try:
        req = urllib.request.Request(base + "/api/experimental/migration/v1")
        req.add_header("Authorization", "Basic " + token)
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode()
        print(body)
        data = json.loads(body)
        if data.get("status") in ("completed", "error"):
            sys.exit(0)
        last = body
    except urllib.error.HTTPError as exc:
        last = "HTTPError %s %s" % (exc.code, exc.read().decode()[:200])
    except Exception as exc:
        last = repr(exc)
    time.sleep(2)
print("TIMEOUT esperando la migracion; ultimo estado: %s" % last)
sys.exit(1)
PY
)" && migration_rc=0 || migration_rc=$?

  say "estado de migracion: $migration_status"
  note "Estado de la migracion (literal, de \`GET /api/experimental/migration/v1\`):"
  lit "$migration_status"

  [ "$migration_rc" = "0" ] || {
    stop_server || note "La parada/verificación de holders también falló; no se señalizaron holders ajenos/no atribuibles."
    die "migracion/6.3" "la migracion no termino correctamente (rc=$migration_rc). Log del servidor: $SERVE_LOG"
  }
  echo "$migration_status" | grep -q '"status"[[:space:]]*:[[:space:]]*"completed"' \
    || { stop_server || note "La parada/verificación de holders también falló; no se señalizaron holders ajenos/no atribuibles."; die "migracion/6.3" "la migracion no reporta 'completed': $migration_status"; }

  say "--- 6.4 parada del servidor"
  stop_server \
    || die "migracion/6.4" "no se demostró la parada segura del servidor propio o quedaron holders ajenos/no atribuibles; no se enviaron señales a esos procesos"
  say "OK: migracion completada"

  say "--- 6.5 estado en la base"
  python3 "$DBTOOL" check --db "$CUTOVER_DB" --json "$WORKDIR/migrated-db.json" >/dev/null \
    || die "migracion/6.5" "no se pudo inspeccionar la base tras la migracion"
  mig_marker="$(json_get "$WORKDIR/migrated-db.json" "d['marker']")"
  mig_v1="$(json_get "$WORKDIR/migrated-db.json" "d['v1_session_count']")"
  mig_v2="$(json_get "$WORKDIR/migrated-db.json" "d['v2_session_count']")"
  mig_missing="$(json_get "$WORKDIR/migrated-db.json" "d['v1_missing_in_v2']")"
  mig_v2_only="$(json_get "$WORKDIR/migrated-db.json" "d['v2_only']")"
  if [ "$mig_v1" = "$mig_v2" ]; then mig_counts_equal="si"; else mig_counts_equal="no"; fi
  say "marcador=$mig_marker session_v1=$mig_v1 session_v2=$mig_v2 v1_missing_in_v2=$mig_missing v2_only=$mig_v2_only igualdad_recuentos=$mig_counts_equal (observacion inmediata)"
  [ "$mig_missing" = "0" ] \
    || die "migracion/6.5" "la migracion deja $mig_missing ID(s) de session V1 ausentes en session_v2"
  note "Observación inmediatamente posterior a la migración: session V1=$mig_v1, session_v2=$mig_v2, igualdad de recuentos=$mig_counts_equal, IDs V1 ausentes en V2=$mig_missing, V2-only=$mig_v2_only. La igualdad es solo una observación; el criterio es cobertura completa de IDs V1 y v2_only no falla. Marcador: \`$mig_marker\`."
fi

# ---------------------------------------------------------------------------
# STEP 7 — VERIFICACION
# ---------------------------------------------------------------------------
step "VERIFICACION"

failures=0
verify() {
  local what="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "1" ]; then
    say "OK   | $what${detail:+ | $detail}"
    note "- OK — $what${detail:+ (\`$detail\`)}"
  else
    say "FALLO| $what${detail:+ | $detail}"
    note "- **FALLO** — $what${detail:+ (\`$detail\`)}"
    failures=$((failures + 1))
  fi
}

say "--- 7.1 version de OpenCode 2"
launcher="$CUTOVER_HOME/.local/bin/forge-opencode"
if [ -x "$launcher" ]; then
  launcher_version="$(OPENCODE_DB="$CUTOVER_DB" "$launcher" --version 2>/dev/null | tr -d ' \n' | sed 's/^opencodev//' || true)"
fi
if [ -z "$launcher_version" ]; then
  # El launcher puede no aceptar --standalone antes de --version; el binario
  # pinado es la referencia real de la version.
  launcher_version="$bin_version"
fi
[ "$launcher_version" = "$CUTOVER_EXPECTED_VERSION" ] \
  && verify "version de OpenCode 2" 1 "$launcher_version" \
  || verify "version de OpenCode 2" 0 "obtenida '$launcher_version', esperada '$CUTOVER_EXPECTED_VERSION'"

say "--- 7.2 estado de la migracion"
python3 "$DBTOOL" check --db "$CUTOVER_DB" --json "$WORKDIR/verify-db.json" >/dev/null \
  || die "verificacion/7.2" "no se pudo inspeccionar la base"
v_marker="$(json_get "$WORKDIR/verify-db.json" "d['marker']")"
v_v1="$(json_get "$WORKDIR/verify-db.json" "d['v1_session_count']")"
v_v2="$(json_get "$WORKDIR/verify-db.json" "d['v2_session_count']")"
v_v1_missing_in_v2="$(json_get "$WORKDIR/verify-db.json" "d['v1_missing_in_v2']")"
v2_only="$(json_get "$WORKDIR/verify-db.json" "d['v2_only']")"
v_qc="$(json_get "$WORKDIR/verify-db.json" "d['quick_check']")"
case "$v_marker" in *'"completed"'*) verify "migracion v1->v2" 1 "$v_marker" ;; *) verify "migracion v1->v2" 0 "marcador=$v_marker" ;; esac
if [ "$v_v1_missing_in_v2" = "0" ]; then
  verify "IDs de session V1 cubiertos en session_v2" 1 "session=$v_v1 session_v2=$v_v2 v1_missing_in_v2=0 v2_only=$v2_only"
else
  verify "IDs de session V1 cubiertos en session_v2" 0 "session=$v_v1 session_v2=$v_v2 v1_missing_in_v2=$v_v1_missing_in_v2 v2_only=$v2_only"
fi
[ "$v_qc" = "ok" ] && verify "quick_check de la base" 1 "ok" || verify "quick_check de la base" 0 "$v_qc"

say "--- 7.3 credenciales"
auth_json="$(cd "$WORKDIR" && OPENCODE_DB="$CUTOVER_DB" OPENCODE_CONFIG_DIR="$OVERLAY_DIR" OPENCODE_CONFIG="$OVERLAY_CONFIG" \
  OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_CHANNEL_DB=1 \
  "$FORGE_BIN" auth list --standalone --format json 2>"$WORKDIR/auth.err" || true)"
printf '%s' "$auth_json" >"$WORKDIR/auth.json"
say "auth list (stdout): $(printf '%s' "$auth_json" | tr -d '\n' | cut -c1-400)"
require_db_clear "$CUTOVER_DB" after-auth-list "verificacion/7.3-holders"
for provider in openai minimax-coding-plan; do
  if printf '%s' "$auth_json" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if any(i.get("id")==sys.argv[1] for i in d) else 1)' "$provider" 2>/dev/null; then
    verify "credencial '$provider'" 1 "presente en auth list --standalone --format json"
  else
    verify "credencial '$provider'" 0 "no aparece en auth list --standalone --format json"
  fi
done

say "--- 7.4 overlay en dialecto V2"
cfg_json="$(python3 - "$OVERLAY_CONFIG" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
raw = re.sub(r"^\s*//.*$", "", raw, flags=re.M)
raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
cfg = json.loads(raw)
out = {
    "plugins": cfg.get("plugins"),
    "plugins_are_dirs": [isinstance(p, str) for p in (cfg.get("plugins") or [])],
    "has_providers": "providers" in cfg,
    "provider_names": sorted((cfg.get("providers") or {}).keys()),
    "has_small_model": "small_model" in cfg,
}
print(json.dumps(out))
PY
)"
say "config: $cfg_json"
cfg_check() { printf '%s' "$cfg_json" | python3 -c "import json,sys;d=json.load(sys.stdin);sys.exit(0 if $1 else 1)"; }
if cfg_check 'isinstance(d["plugins"],list) and d["plugins"] and all(d["plugins_are_dirs"])'; then
  verify "plugins como array de rutas de directorio" 1 "$cfg_json"
else
  verify "plugins como array de rutas de directorio" 0 "$cfg_json"
fi
if cfg_check 'd["has_providers"]'; then
  verify "providers declarados" 1 "$cfg_json"
else
  verify "providers declarados" 0 "$cfg_json"
fi
if cfg_check 'not d["has_small_model"]'; then
  verify "sin 'small_model' (dialecto V1)" 1 "ausente"
else
  verify "sin 'small_model' (dialecto V1)" 0 "presente"
fi

say "--- 7.5 plugin V2 instalado"
[ -d "$OVERLAY_DIR/plugin-packages/forge-guard" ] \
  && verify "plugin-packages/forge-guard instalado" 1 "$OVERLAY_DIR/plugin-packages/forge-guard" \
  || verify "plugin-packages/forge-guard instalado" 0 "falta $OVERLAY_DIR/plugin-packages/forge-guard"
[ -f "$OVERLAY_DIR/plugin-packages/forge-guard/package.json" ] \
  && verify "plugin-packages/forge-guard/package.json" 1 "presente" \
  || verify "plugin-packages/forge-guard/package.json" 0 "falta"

say "--- 7.6 prefix del binario pinado"
[ -d "$FORGE_BIN_DIR" ] && verify "prefix del binario pinado" 1 "$FORGE_BIN_DIR" || verify "prefix del binario pinado" 0 "falta $FORGE_BIN_DIR"

say "--- 7.7 manifest con 'binary'"
[ -n "$m_bin" ] && verify "manifest con 'binary'" 1 "$m_bin" || verify "manifest con 'binary'" 0 "el manifest no registra 'binary'"

say "--- 7.8 Omarchy y tokens intactos"
omarchy_after=""
if [ -d "$OMARCHY_DIR" ]; then
  omarchy_after="$(find "$OMARCHY_DIR" -maxdepth 3 -printf '%y %s %T@ %p\n' 2>/dev/null | sort | sha256sum | cut -d' ' -f1)"
fi
tokens_after=""
if [ -f "$TOKENS_FILE" ]; then
  tokens_after="$(sha256sum "$TOKENS_FILE" | cut -d' ' -f1)"
fi
# shellcheck disable=SC2088  # los "~" son texto literal del informe, no rutas
[ "$omarchy_after" = "$omarchy_state" ] \
  && verify "~/.local/share/omarchy intacto" 1 "${omarchy_after:-<no existe>}" \
  || verify "~/.local/share/omarchy intacto" 0 "cambio de ${omarchy_state:-<no existe>} a ${omarchy_after:-<no existe>}"
# shellcheck disable=SC2088
[ "$tokens_after" = "$tokens_state" ] \
  && verify "~/.opencode-tokens intacto" 1 "${tokens_after:-<no existe>}" \
  || verify "~/.opencode-tokens intacto" 0 "cambio de ${tokens_state:-<no existe>} a ${tokens_after:-<no existe>}"

say "--- 7.9 el plugin V2 es un paquete valido y la config lo referencia"
# No se usa `opencode plugin list`: ese comando se engancha al servidor de
# fondo (no acepta --standalone) y dejaria un proceso opencode vivo sobre la
# base recien migrada. Se verifica el paquete y su referencia en la config.
plugin_rc=0
python3 - "$OVERLAY_CONFIG" "$OVERLAY_DIR" <<'PY' || plugin_rc=$?
import json, os, re, sys
config_path = sys.argv[1]
raw = open(config_path, encoding="utf-8").read()
raw = re.sub(r"^\s*//.*$", "", raw, flags=re.M)
raw = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
cfg = json.loads(raw)
plugins = cfg.get("plugins") or []
assert plugins, "la config no declara plugins"
root = os.path.dirname(os.path.abspath(config_path))
for entry in plugins:
    path = entry if os.path.isabs(entry) else os.path.join(root, entry)
    assert os.path.isdir(path), "el plugin %r no es un directorio: %s" % (entry, path)
    manifest = os.path.join(path, "package.json")
    assert os.path.isfile(manifest), "el plugin %r no tiene package.json" % entry
    pkg = json.load(open(manifest, encoding="utf-8"))
    main = pkg.get("main") or "index.js"
    assert os.path.isfile(os.path.join(path, main)), "el entrypoint %s no existe" % main
PY
if [ "$plugin_rc" = "0" ]; then
  verify "plugin V2 referenciado y resoluble" 1 "$OVERLAY_DIR/plugin-packages/forge-guard"
else
  verify "plugin V2 referenciado y resoluble" 0 "la config no resuelve a un paquete de plugin en disco"
fi
say "plugin V2 verificado"

note "Credenciales (literal de \`auth list --standalone --format json\`):"
lit "$auth_json"

require_db_clear "$CUTOVER_DB" before-final-verdict "verificacion/veredicto-holders"
if [ "$failures" -ne 0 ]; then
  note ""
  note "**$failures verificacion(es) fallaron.**"
  die "verificacion" "hay $failures verificacion(es) en rojo. La base ya esta migrada y el overlay instalado; consulta el informe y usa ROLLBACK.sh si hace falta volver atras."
fi

say "VERIFICACION OK"

# ---------------------------------------------------------------------------
# STEP 8 — INFORME
# ---------------------------------------------------------------------------
step "INFORME"

cat <<EOF

## Resumen

- Sesiones medidas tras la migración: **$v_v1** en \`session\`, **$v_v2** en \`session_v2\`; IDs V1 ausentes en V2: **$v_v1_missing_in_v2**; V2-only: **$v2_only**.
- Marcador de migracion: \`$v_marker\`.
- Overlay V2 instalado en \`$OVERLAY_DIR\` con el binario pinado \`$FORGE_BIN\` ($CUTOVER_EXPECTED_VERSION).
- La base original (sin migrar, con el intento interrumpido) esta en \`$ORIGINAL_MOVED\`, junto con su \`-wal\`/\`-shm\`.
- Omarchy y \`~/.opencode-tokens\` intactos.

## Como volver atras

\`\`\`bash
bash $SCRIPT_DIR/ROLLBACK.sh
\`\`\`
EOF

say "cutover completado"
exit 0
