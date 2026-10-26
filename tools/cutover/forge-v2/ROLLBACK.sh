#!/usr/bin/env bash
# ROLLBACK.sh -- revierte el cutover de OpenCode 1.19.4 a OpenCode 2.1.4.
#
# Procedimiento manual que intenta restaurar el estado previo al cutover:
# cualquier holder de la DB bloquea y un error puede dejar cambios parciales;
# no hay señales, rollback automatico ni recuperacion automatica.
#   1. restaura la base de datos original (sin migrar) desde el backup,
#   2. retira el overlay V2 y el binario pinado,
#   3. restaura el manifest de Forge y ~/.opencode-tokens desde el backup,
#   4. restaura la configuracion global de OpenCode 1 si el backup la trae.
#
# NO toca Omarchy en ningun momento: la instalacion de Omarchy no se modifica
# con el cutover, asi que tampoco se modifica con la reversion.
#
# Uso (produccion):
#   bash open-code/cutover-v2/ROLLBACK.sh
#
# Uso (sandbox): las mismas variables de entorno que cutover.sh.
#   HOME=... CUTOVER_BACKUP_DIR=... CUTOVER_REPO_ROOT=... CUTOVER_DB=... \
#     bash open-code/cutover-v2/ROLLBACK.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBTOOL="$SCRIPT_DIR/lib/dbtool.py"
SAFETY_LIB="$SCRIPT_DIR/lib/cutover_safety.py"
if [ ! -f "$SAFETY_LIB" ]; then
  printf '[rollback] ERROR: falta la biblioteca de seguridad requerida: %s\n' "$SAFETY_LIB" >&2
  exit 1
fi

CUTOVER_HOME="${CUTOVER_HOME:-$HOME}"
CUTOVER_BACKUP_DIR="${CUTOVER_BACKUP_DIR:-$HOME/forge-v2-backup-20261024-203342}"
CUTOVER_REPO_ROOT="${CUTOVER_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
CUTOVER_DB="${CUTOVER_DB:-${OPENCODE_DB:-$CUTOVER_HOME/.local/share/opencode/opencode.db}}"

export HOME="$CUTOVER_HOME"

BACKUP_HOME="$CUTOVER_BACKUP_DIR/home"
ORIGINAL_MOVED="$CUTOVER_BACKUP_DIR/opencode.db.precutover-original"
BACKUP_DB="$CUTOVER_BACKUP_DIR/opencode.db"
WORKDIR="$CUTOVER_BACKUP_DIR/.cutover-work"

OVERLAY_DIR="${OPENCODE_CONFIG_DIR:-$CUTOVER_HOME/.config/opencode-forge}"
FORGE_BIN_DIR="${FORGE_OPENCODE_BIN_DIR:-${XDG_DATA_HOME:-$CUTOVER_HOME/.local/share}/forge/opencode-v2}"
STATE_FILE="$CUTOVER_HOME/.forge-state.json"
TOKENS_FILE="$CUTOVER_HOME/.opencode-tokens"
OMARCHY_DIR="$CUTOVER_HOME/.local/share/omarchy"
LAUNCHER="$CUTOVER_HOME/.local/bin/forge-opencode"

mkdir -p "$WORKDIR"
LOG_FILE="$WORKDIR/rollback.log"
: >"$LOG_FILE"

say() { printf '[rollback] %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
die() {
  say "ERROR: $1"
  exit 1
}

json_get() {
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$1" "$2"
}
json_lines() {
  python3 -c 'import json,sys;print("\n".join(str(x) for x in json.load(open(sys.argv[1]))[sys.argv[2]]))' "$1" "$2"
}

check_db_holders() {
  local phase="$1" state_file log_messages complete found_holder message
  state_file="$WORKDIR/rollback-inventory-${phase//[^A-Za-z0-9_.-]/_}.json"
  python3 "$SAFETY_LIB" scan-rollback "$CUTOVER_DB" "$phase" "$$" "$state_file" \
    || die "$phase: inventario no disponible" "no se pudo completar el inventario de /proc; no se restaura ni se retira el overlay/binario"
  log_messages="$(json_lines "$state_file" log_messages)"
  complete="$(json_get "$state_file" complete)"
  found_holder="$(json_get "$state_file" found_holder)"
  while IFS= read -r message; do
    [ -n "$message" ] && say "$message"
  done <<<"$log_messages"
  [ "$complete" = "True" ] \
    || die "$phase: inventario no exhaustivo" "el inventario de /proc no es exhaustivo; no se restaura ni se retira el overlay/binario"
  [ "$found_holder" = "False" ] \
    || die "$phase: holder encontrado" "hay un proceso con DB/WAL/SHM o OPENCODE_DB hacia el destino; no se detiene ningún proceso"
  say "OK: inventario exhaustivo de todos los ejecutables, sin holders; no se señalizaron procesos (fase=$phase)"
}

say "HOME=$CUTOVER_HOME"
say "DB=$CUTOVER_DB"
say "BACKUP=$CUTOVER_BACKUP_DIR"

# ---------------------------------------------------------------------------
# 0. Preflight: cualquier holder de DB/WAL/SHM bloquea, sea cual sea el exe
# ---------------------------------------------------------------------------
check_db_holders preflight
check_db_holders before-first-restore

# ---------------------------------------------------------------------------
# 1. Restaurar la base de datos original
# ---------------------------------------------------------------------------
if [ -f "$ORIGINAL_MOVED" ]; then
  say "restaurando la base original desde $ORIGINAL_MOVED"
  # La base migrada (y sus -wal/-shm) se apartan: son el estado V2.
  if [ -f "$CUTOVER_DB" ]; then
    mv -- "$CUTOVER_DB" "$CUTOVER_BACKUP_DIR/opencode.db.postcutover-v2" \
      || die "no se pudo apartar la base migrada"
  fi
  for suffix in -wal -shm; do
    [ -e "$CUTOVER_DB$suffix" ] && mv -- "$CUTOVER_DB$suffix" "$CUTOVER_BACKUP_DIR/opencode.db.postcutover-v2$suffix"
  done
  mv -- "$ORIGINAL_MOVED" "$CUTOVER_DB" || die "no se pudo restaurar la base original"
  for suffix in -wal -shm; do
    if [ -e "$ORIGINAL_MOVED$suffix" ]; then
      mv -- "$ORIGINAL_MOVED$suffix" "$CUTOVER_DB$suffix" || die "no se pudo restaurar $CUTOVER_DB$suffix"
    fi
  done
  say "OK: base original restaurada"
elif [ -f "$BACKUP_DB" ]; then
  say "restaurando la base desde la copia del backup $BACKUP_DB"
  [ -f "$CUTOVER_DB" ] && mv -- "$CUTOVER_DB" "$CUTOVER_BACKUP_DIR/opencode.db.postcutover-v2"
  for suffix in -wal -shm; do
    [ -e "$CUTOVER_DB$suffix" ] && mv -- "$CUTOVER_DB$suffix" "$CUTOVER_BACKUP_DIR/opencode.db.postcutover-v2$suffix"
  done
  cp -- "$BACKUP_DB" "$CUTOVER_DB" || die "no se pudo copiar la base del backup"
  say "OK: base restaurada desde la copia del backup"
else
  die "no hay ninguna base que restaurar: ni $ORIGINAL_MOVED ni $BACKUP_DB"
fi

qc="$(python3 "$DBTOOL" check --db "$CUTOVER_DB" --json "$WORKDIR/rollback-db.json" >/dev/null 2>&1 && \
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["quick_check"])' "$WORKDIR/rollback-db.json" || echo ERROR)"
[ "$qc" = "ok" ] || die "quick_check de la base restaurada: $qc"
marker="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["marker"])' "$WORKDIR/rollback-db.json")"
sessions="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["v1_session_count"])' "$WORKDIR/rollback-db.json")"
say "OK: quick_check=ok, sesiones v1=$sessions, marcador=$marker"

# ---------------------------------------------------------------------------
# 2. Retirar el overlay V2 y el binario pinado
# ---------------------------------------------------------------------------
check_db_holders before-overlay-and-binary-removal
say "retirando el overlay V2"
[ -e "$LAUNCHER" ] && rm -f -- "$LAUNCHER" && say "  launcher eliminado: $LAUNCHER"
[ -d "$OVERLAY_DIR" ] && rm -rf -- "$OVERLAY_DIR" && say "  overlay eliminado: $OVERLAY_DIR"
[ -d "$FORGE_BIN_DIR" ] && rm -rf -- "$FORGE_BIN_DIR" && say "  prefix del binario pinado eliminado: $FORGE_BIN_DIR"

# ---------------------------------------------------------------------------
# 3. Restaurar el manifest de Forge y ~/.opencode-tokens
# ---------------------------------------------------------------------------
if [ -f "$BACKUP_HOME/.forge-state.json" ]; then
  cp -a -- "$BACKUP_HOME/.forge-state.json" "$STATE_FILE" || die "no se pudo restaurar $STATE_FILE"
  say "OK: manifest de Forge restaurado desde el backup"
else
  rm -f -- "$STATE_FILE"
  say "AVISO: el backup no traia manifest de Forge; se ha eliminado $STATE_FILE"
fi

if [ -f "$BACKUP_HOME/.opencode-tokens" ]; then
  cp -a -- "$BACKUP_HOME/.opencode-tokens" "$TOKENS_FILE" || die "no se pudo restaurar $TOKENS_FILE"
  say "OK: ~/.opencode-tokens restaurado desde el backup"
fi

# ---------------------------------------------------------------------------
# 4. Restaurar la configuracion global de OpenCode 1
# ---------------------------------------------------------------------------
if [ -d "$BACKUP_HOME/.config/opencode" ]; then
  mkdir -p "$CUTOVER_HOME/.config"
  rm -rf -- "$CUTOVER_HOME/.config/opencode"
  cp -a -- "$BACKUP_HOME/.config/opencode" "$CUTOVER_HOME/.config/opencode" || die "no se pudo restaurar ~/.config/opencode"
  say "OK: ~/.config/opencode (config global de OpenCode 1) restaurada desde el backup"
fi

# ---------------------------------------------------------------------------
# 5. Omarchy intacto
# ---------------------------------------------------------------------------
if [ -d "$OMARCHY_DIR" ]; then
  say "OK: ~/.local/share/omarchy sigue presente (el cutover nunca lo toco)"
else
  say "AVISO: ~/.local/share/omarchy no existe"
fi

say "REVERSION COMPLETA"
say "Comprueba el estado con: opencode --version  (debe decir 1.19.4)"
exit 0
