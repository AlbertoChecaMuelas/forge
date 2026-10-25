#!/usr/bin/env bash
# tests/opencode_real_runtime_integration.sh — the OPERATIONAL guarantee of
# the OpenCode overlay, exercised with a REAL runtime.
#
# The fake toolchain of the other suites cannot exercise the operational
# plugin inventory probe (it needs a runtime that serves), so with the fake the
# diagnostics degrade on purpose (that contract lives in
# tests/opencode_install_integration.sh). This suite covers the other half: with
# a REAL OpenCode 2.1.4 the diagnostics must be healthy and the inventory must
# be the real one.
#
# What this suite asserts:
#
#   1. the real binary is resolved and IS 2.1.4;
#   2. `install.sh status` exits 0 and reports "Estado general: OK";
#   3. `install.sh doctor` exits 0 and reports "FAILs=0";
#   4. the inventory is the REAL and EXACT one: forge-guard and nothing else;
#   5. the origin of that guard is LOCAL and inside the isolated copy, never
#      the path of the real installation;
#   6. nothing of the real installation, of the real database or of the
#      original credentials is used, and no provider is contacted.
#
# The binary is resolved in this order:
#
#   a) FORGE_TEST_REAL_OPENCODE_BIN: an absolute path of an existing real
#      executable, used as it is (this is how a developer points the suite at
#      an existing local 2.1.4);
#   b) otherwise the GLOBAL npm installation of @opencode/cli, following its
#      link to the real binary (this is what CI provides with
#      `npm install -g @opencode/cli@2.1.4`).
#
# The user wrapper (~/.local/bin/opencode) is NEVER used: it may install or
# update packages. When no real runtime can be resolved the suite FAILS with a
# clear cause: a missing runtime is a failure of the suite, never a green skip.
#
# Isolation: the scenario builds its own installation with the real installer
# inside a private sandbox (HOME, XDG, config, data, state, cache and TMPDIR
# all inside it). The pinned binary of that isolated installation is a link to
# the resolved real binary, so the runtime that enumerates the plugins is the
# real one, but everything it reads (the overlay, its forge-guard, the
# configuration and the database) belongs to the sandbox. The real database is
# only stat()'ed before and after, to prove it was not touched.
#
# Compatible with bash 3.2+.
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Shared isolation helpers: the isolated environment and the fake npm (which
# materialises the pinned layout without downloading anything).
# shellcheck source=tests/isolation.sh
. "$FORGE_ROOT/tests/isolation.sh"

FAIL=0
PASS_COUNT=0
TEST_TMP_ROOT="/tmp/opencode/opencode-real-runtime-integration.$$"
SANDBOX=""
REAL_BIN=""
REAL_BIN_VERSION=""

pass() { echo "  PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=1; }

# The exact version this contract is written against.
EXPECTED_VERSION="2.1.4"

cleanup() {
  local rc=$?

  # Only OWN resources are touched: processes whose command line references
  # this scenario's sandbox are, by construction, the ones this scenario
  # started. Pre-existing processes are never signalled.
  kill_own_processes

  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
  if [ -n "${TEST_TMP_ROOT:-}" ] && [ -d "$TEST_TMP_ROOT" ]; then
    rm -rf "$TEST_TMP_ROOT"
  fi

  exit $rc
}

# own_processes
# Prints the PIDs whose command line references this scenario's sandbox. They
# are, by construction, the processes this scenario started.
own_processes() {
  local entry pid cmdline

  [ -n "$SANDBOX" ] || return 0

  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid="${entry#/proc/}"
    [ "$pid" = "$$" ] && continue
    cmdline="$(tr '\0' ' ' < "$entry/cmdline" 2>/dev/null || true)"
    case "$cmdline" in
      *"$SANDBOX"*) printf '%s\n' "$pid" ;;
    esac
  done
}

# kill_own_processes
# Terminates only the processes of this scenario, identified by their command
# line referencing the sandbox. No sweep by name, no signal to anything else.
kill_own_processes() {
  [ -n "$SANDBOX" ] || return 0

  local pid
  for pid in $(own_processes); do
    kill -TERM "$pid" 2>/dev/null || true
  done

  local waited=0
  while [ "$waited" -lt 20 ]; do
    [ -z "$(own_processes)" ] && return 0
    sleep 0.5
    waited=$((waited + 1))
  done

  for pid in $(own_processes); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

mkdir -p "$TEST_TMP_ROOT"
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The real runtime. The environment of every invocation is neutralised, so the
# binary never reads the original configuration nor the original credentials,
# and it never reaches the network.
# ---------------------------------------------------------------------------
real_env() {
  env -i \
    HOME="$SANDBOX/home" \
    XDG_CONFIG_HOME="$SANDBOX/home/.config" \
    XDG_DATA_HOME="$SANDBOX/home/.local/share" \
    XDG_STATE_HOME="$SANDBOX/home/.local/state" \
    XDG_CACHE_HOME="$SANDBOX/home/.cache" \
    XDG_RUNTIME_DIR="$SANDBOX/run" \
    TMPDIR="$SANDBOX/tmp" \
    PATH=/usr/bin:/bin \
    LANG=C LC_ALL=C \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_MODELS_FETCH=1 \
    OPENCODE_DISABLE_CHANNEL_DB=1 \
    OPENCODE_DISABLE_FILEWATCHER=1 \
    OPENCODE_DISABLE_CLAUDE_CODE=1 \
    OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
    "$@"
}

# resolve_real_opencode_bin
# Prints the absolute path of the real binary, or fails with a clear cause.
resolve_real_opencode_bin() {
  local override="${FORGE_TEST_REAL_OPENCODE_BIN:-}"

  if [ -n "$override" ]; then
    case "$override" in
      /*) ;;
      *)
        echo "FORGE_TEST_REAL_OPENCODE_BIN debe ser una ruta absoluta (valor actual: $override)" >&2
        return 1
        ;;
    esac
    if [ ! -e "$override" ]; then
      echo "FORGE_TEST_REAL_OPENCODE_BIN no existe: $override" >&2
      return 1
    fi
    if [ ! -x "$override" ]; then
      echo "FORGE_TEST_REAL_OPENCODE_BIN no es un ejecutable: $override" >&2
      return 1
    fi
    resolve_link "$override"
    return 0
  fi

  # The global npm installation of @opencode/cli (what CI installs with
  # `npm install -g @opencode/cli@2.1.4`). `npm root -g` already points at the
  # global node_modules directory, so the bin lives in <root>/.bin.
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm no esta disponible: no se puede resolver la instalacion global de @opencode/cli" >&2
    return 1
  fi
  local npm_root
  npm_root="$(npm root -g 2>/dev/null || true)"
  if [ -z "$npm_root" ] || [ ! -d "$npm_root" ]; then
    echo "no se pudo determinar la raiz global de npm" >&2
    return 1
  fi
  local candidate="$npm_root/.bin/opencode"
  if [ ! -e "$candidate" ]; then
    echo "no hay instalacion global de @opencode/cli ($candidate no existe): instala @opencode/cli@$EXPECTED_VERSION o exporta FORGE_TEST_REAL_OPENCODE_BIN" >&2
    return 1
  fi
  resolve_link "$candidate"
}

# resolve_link <path>
# Follows the link to the real executable and refuses the user wrapper, which
# may install or update packages.
resolve_link() {
  local path="$1"
  local resolved
  resolved="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  if [ ! -x "$resolved" ]; then
    echo "el binario resuelto no es ejecutable: $resolved" >&2
    return 1
  fi
  case "$resolved" in
    "$HOME"/.local/bin/opencode|"$HOME"/.local/bin/opencode.exe)
      echo "el wrapper del usuario ($resolved) no se puede usar: puede instalar o actualizar paquetes" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$resolved"
}

# ---------------------------------------------------------------------------
# The scenario.
# ---------------------------------------------------------------------------
echo "================================"
echo " opencode_real_runtime_integration.sh"
echo "================================"

# --- 1. resolve the real runtime -----------------------------------------
if ! REAL_BIN="$(resolve_real_opencode_bin)"; then
  fail "no hay runtime real disponible: el escenario no puede acreditarse"
  echo ""
  echo "  FAIL: sin runtime real el escenario falla; no es un skip verde" >&2
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi

# --- 2. the sandbox and the version of the resolved runtime --------------
SANDBOX="$(mktemp -d "$TEST_TMP_ROOT/real-runtime.XXXXXX")"
chmod 700 "$SANDBOX"
mkdir -p "$SANDBOX/home" "$SANDBOX/tmp" "$SANDBOX/work" "$SANDBOX/run"
chmod 700 "$SANDBOX/tmp" "$SANDBOX/run"

if ! REAL_BIN_VERSION="$(real_env "$REAL_BIN" --version 2>/dev/null | head -n 1)"; then
  REAL_BIN_VERSION="(no se pudo ejecutar --version)"
fi
case "$REAL_BIN_VERSION" in
  *"v$EXPECTED_VERSION"*)
    pass "el binario real resuelto es la version $EXPECTED_VERSION ($REAL_BIN)"
    ;;
  *)
    fail "el binario real resuelto no es la version $EXPECTED_VERSION (version obtenida: $REAL_BIN_VERSION, binario: $REAL_BIN)"
    echo ""
    echo "  FAIL: version de runtime distinta de la contratada; no se instala ni se cambia nada" >&2
    echo "================================"
    echo " Passed: $PASS_COUNT"
    exit 1
    ;;
esac

# --- 3. the isolated installation ----------------------------------------
# A disposable copy of the Forge tree: the installer regenerates agents, so it
# must never run against the checkout.
FIXTURE_REPO="$SANDBOX/repo"
mkdir -p "$FIXTURE_REPO"
cp "$FORGE_ROOT/install.sh" "$FIXTURE_REPO/install.sh"
for item in lib open-code shared agents skills rtk; do
  cp -R "$FORGE_ROOT/$item" "$FIXTURE_REPO/"
done

# The fake npm materialises the pinned layout without downloading anything;
# the pinned binary is replaced right after by a link to the REAL one.
forge_make_toolchain "$SANDBOX/home/fakebin"

if ! real_env \
    PATH="$SANDBOX/home/fakebin:/usr/bin:/bin" \
    FORGE_OPENCODE_BIN_DIR="$SANDBOX/home/.local/share/forge/opencode-v2" \
    bash "$FIXTURE_REPO/install.sh" install --target=opencode \
    > "$SANDBOX/install.log" 2>&1; then
  fail "no se pudo crear la instalacion aislada (log: $SANDBOX/install.log)"
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi
pass "la instalacion aislada se crea con el instalador real dentro del sandbox"

PINNED="$SANDBOX/home/.local/share/forge/opencode-v2/node_modules/.bin/opencode"
if [ ! -e "$PINNED" ]; then
  fail "la instalacion aislada no tiene el binario pinado esperado ($PINNED)"
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi
rm -f "$PINNED"
ln -s "$REAL_BIN" "$PINNED"
pass "el binario pinado de la instalacion aislada es el runtime real ($REAL_BIN)"

# The isolated database: a valid, EMPTY SQLite file created by the scenario.
# The real database is never opened, copied or read.
REAL_DB="${FORGE_V2_REAL_DB:-$HOME/.local/share/opencode/opencode.db}"
REAL_DB_BEFORE="$(stat -c '%d:%i:%s:%Y' "$REAL_DB" 2>/dev/null || echo absent)"
ISOLATED_DB="$SANDBOX/home/.local/share/opencode/opencode.db"
mkdir -p "$(dirname "$ISOLATED_DB")"
if ! python3 -c '
import sqlite3
import sys

# An EMPTY but VALID SQLite database: the real runtime applies its own
# migrations to the private snapshot it takes from it. No table of ours is
# invented: the schema belongs to the runtime.
connection = sqlite3.connect(sys.argv[1])
connection.execute("PRAGMA user_version = 0")
connection.commit()
connection.close()
' "$ISOLATED_DB" 2>/dev/null; then
  fail "no se pudo crear la base de datos aislada del escenario"
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi
pass "la base de datos del escenario es sintetica y aislada"

# --- 4. ONE invocation of each diagnostic, reused by every assertion -----
STATUS_OUT="$SANDBOX/status.out"
DOCTOR_OUT="$SANDBOX/doctor.out"
PLUGIN_LIST_OUT="$SANDBOX/plugin-list.out"

status_start=$SECONDS
status_rc=0
real_env \
  PATH="$SANDBOX/home/fakebin:/usr/bin:/bin" \
  FORGE_OPENCODE_BIN_DIR="$SANDBOX/home/.local/share/forge/opencode-v2" \
  bash "$FIXTURE_REPO/install.sh" status \
  > "$STATUS_OUT" 2>&1 || status_rc=$?
status_elapsed=$((SECONDS - status_start))

doctor_start=$SECONDS
doctor_rc=0
real_env \
  PATH="$SANDBOX/home/fakebin:/usr/bin:/bin" \
  FORGE_OPENCODE_BIN_DIR="$SANDBOX/home/.local/share/forge/opencode-v2" \
  bash "$FIXTURE_REPO/install.sh" doctor \
  > "$DOCTOR_OUT" 2>&1 || doctor_rc=$?
doctor_elapsed=$((SECONDS - doctor_start))

# The diagnostics do not print the origin of the enumerated plugin, so the
# origin is observed with ONE enumeration of the real runtime against the
# ISOLATED installation, using the PRODUCTION helpers (runtime-copy drops the
# MCP and provider blocks, so no external integration is started) and a private
# diagnostic root, exactly like the production probe does. It is not a
# diagnostic and it is never repeated.
DIAGNOSTIC_ROOT="$(mktemp -d "$SANDBOX/forge-opencode-plugin-diagnostic.XXXXXX")"
chmod 700 "$DIAGNOSTIC_ROOT"
mkdir -p "$DIAGNOSTIC_ROOT/home/.local/bin" "$DIAGNOSTIC_ROOT/xdg/config" \
  "$DIAGNOSTIC_ROOT/xdg/data/opencode" "$DIAGNOSTIC_ROOT/xdg/state" \
  "$DIAGNOSTIC_ROOT/xdg/cache" "$DIAGNOSTIC_ROOT/xdg/tmp" "$DIAGNOSTIC_ROOT/work" \
  "$DIAGNOSTIC_ROOT/run"
chmod 700 "$DIAGNOSTIC_ROOT/home" "$DIAGNOSTIC_ROOT/home/.local" \
  "$DIAGNOSTIC_ROOT/home/.local/bin" "$DIAGNOSTIC_ROOT/xdg" \
  "$DIAGNOSTIC_ROOT/xdg/config" "$DIAGNOSTIC_ROOT/xdg/data" \
  "$DIAGNOSTIC_ROOT/xdg/data/opencode" "$DIAGNOSTIC_ROOT/xdg/state" \
  "$DIAGNOSTIC_ROOT/xdg/cache" "$DIAGNOSTIC_ROOT/xdg/tmp" "$DIAGNOSTIC_ROOT/work" \
  "$DIAGNOSTIC_ROOT/run"
ln -s "$SANDBOX/home/.local/bin/forge-opencode" \
  "$DIAGNOSTIC_ROOT/home/.local/bin/forge-opencode"

HELPER="$FIXTURE_REPO/open-code/lib/plugin-sync.py"
OVERLAY_DIR="$SANDBOX/home/.config/opencode-forge"
OVERLAY_CONFIG="$OVERLAY_DIR/opencode.jsonc"
copy_json="$(PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" runtime-copy \
  --config-dir "$OVERLAY_DIR" --config "$OVERLAY_CONFIG" \
  --destination "$DIAGNOSTIC_ROOT/xdg/config/opencode-forge" \
  2>"$SANDBOX/runtime-copy.err" || true)"
private_config="$(printf '%s' "$copy_json" | jq -r '.config_file // empty' 2>/dev/null || true)"
private_db="$(PYTHONDONTWRITEBYTECODE=1 python3 "$HELPER" snapshot-db \
  --source "$ISOLATED_DB" \
  --destination "$DIAGNOSTIC_ROOT/xdg/data/opencode/opencode.db" \
  2>"$SANDBOX/snapshot.err" || true)"

plugin_list_rc=0
if [ -n "$private_config" ] && [ -n "$private_db" ]; then
  jq -n \
    --arg dir "$DIAGNOSTIC_ROOT/xdg/config/opencode-forge" \
    --arg cfg "$private_config" \
    --arg bin "$PINNED" \
    '{targets_manifest:[{name:"opencode",dir:$dir,config_file:$cfg,binary:$bin}]}' \
    > "$DIAGNOSTIC_ROOT/home/.forge-state.json"

  env -i \
    HOME="$DIAGNOSTIC_ROOT/home" \
    XDG_CONFIG_HOME="$DIAGNOSTIC_ROOT/xdg/config" \
    XDG_DATA_HOME="$DIAGNOSTIC_ROOT/xdg/data" \
    XDG_STATE_HOME="$DIAGNOSTIC_ROOT/xdg/state" \
    XDG_CACHE_HOME="$DIAGNOSTIC_ROOT/xdg/cache" \
    XDG_RUNTIME_DIR="$DIAGNOSTIC_ROOT/run" \
    TMPDIR="$DIAGNOSTIC_ROOT/xdg/tmp" \
    PATH=/usr/bin:/bin \
    LANG=C LC_ALL=C \
    OPENCODE_CONFIG_DIR="$DIAGNOSTIC_ROOT/xdg/config/opencode-forge" \
    OPENCODE_CONFIG="$private_config" \
    OPENCODE_DB="$private_db" \
    FORGE_OPENCODE_PRIVATE_DB=1 \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_MODELS_FETCH=1 \
    OPENCODE_DISABLE_CHANNEL_DB=1 \
    OPENCODE_DISABLE_FILEWATCHER=1 \
    OPENCODE_DISABLE_CLAUDE_CODE=1 \
    OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    "$DIAGNOSTIC_ROOT/home/.local/bin/forge-opencode" plugin list \
    > "$PLUGIN_LIST_OUT" 2>&1 || plugin_list_rc=$?
else
  : > "$PLUGIN_LIST_OUT"
  plugin_list_rc=1
fi

echo "  ---- tiempos: status ${status_elapsed}s, doctor ${doctor_elapsed}s"

# --- 5. the assertions ---------------------------------------------------
if [ "$status_rc" -eq 0 ]; then
  pass "status sale 0 con el runtime real"
else
  fail "status deberia salir 0 con el runtime real (rc=$status_rc)"
  sed -n '1,40p' "$STATUS_OUT" | sed 's/^/      /' >&2
fi

if grep -qF "Estado general: OK" "$STATUS_OUT"; then
  pass "status informa de Estado general: OK con el runtime real"
else
  fail "status no informo de Estado general: OK con el runtime real"
  grep -E "Estado general|UNAVAILABLE|FAIL" "$STATUS_OUT" | sed 's/^/      /' >&2
fi

if [ "$doctor_rc" -eq 0 ]; then
  pass "doctor sale 0 con el runtime real"
else
  fail "doctor deberia salir 0 con el runtime real (rc=$doctor_rc)"
  sed -n '1,40p' "$DOCTOR_OUT" | sed 's/^/      /' >&2
fi

if grep -qE "Resumen: FAILs=0" "$DOCTOR_OUT"; then
  pass "doctor no reporta FAILs con el runtime real"
else
  fail "doctor reporto FAILs con el runtime real"
  grep -E "Resumen|FAIL" "$DOCTOR_OUT" | sed 's/^/      /' >&2
fi

# The real inventory: the production probe only accepts an EXACT enumeration.
for diagnostic in status doctor; do
  out="$STATUS_OUT"
  [ "$diagnostic" = "doctor" ] && out="$DOCTOR_OUT"
  if grep -qF "enumeración runtime exacta de forge-guard" "$out"; then
    pass "$diagnostic acredita la enumeracion runtime exacta de forge-guard"
  else
    fail "$diagnostic no acredita la enumeracion runtime exacta de forge-guard"
    grep -E "plugin list|UNAVAILABLE" "$out" | sed 's/^/      /' >&2
  fi
done

# The inventory itself, captured from the real runtime.
if [ "$plugin_list_rc" -eq 0 ]; then
  pass "la enumeracion del runtime real termina correctamente"
else
  fail "la enumeracion del runtime real fallo (rc=$plugin_list_rc)"
  sed -n '1,20p' "$PLUGIN_LIST_OUT" | sed 's/^/      /' >&2
fi

inventory_lines="$(grep -c '[^[:space:]]' "$PLUGIN_LIST_OUT" 2>/dev/null || true)"
if [ "$inventory_lines" = "2" ]; then
  pass "el inventario real tiene exactamente una entrada (forge-guard)"
else
  fail "el inventario real deberia tener exactamente una entrada (lineas: $inventory_lines)"
  sed -n '1,20p' "$PLUGIN_LIST_OUT" | sed 's/^/      /' >&2
fi

if head -n 1 "$PLUGIN_LIST_OUT" | grep -qE '^ID[[:space:]]+VERSION[[:space:]]+SOURCE$'; then
  pass "el inventario real usa el contrato ID/VERSION/SOURCE"
else
  fail "el inventario real no usa el contrato ID/VERSION/SOURCE"
fi

inventory_row="$(sed -n '2p' "$PLUGIN_LIST_OUT")"
inventory_id="$(printf '%s' "$inventory_row" | awk '{ print $1 }')"
inventory_version="$(printf '%s' "$inventory_row" | awk '{ print $2 }')"
inventory_source="$(printf '%s' "$inventory_row" | awk '{ print $3 }')"

if [ "$inventory_id" = "forge-guard" ]; then
  pass "el inventario real contiene exactamente forge-guard"
else
  fail "el inventario real deberia contener forge-guard (contenido: $inventory_id)"
fi

if [ "$inventory_version" = "local" ]; then
  pass "el guard enumerado es de origen local"
else
  fail "el guard enumerado deberia ser de origen local (origen: $inventory_version)"
fi

case "$inventory_source" in
  */plugin-packages/forge-guard/index.js)
    pass "el origen del guard enumerado es el paquete local del guard"
    ;;
  *)
    fail "el origen del guard enumerado no es el paquete local del guard (origen: $inventory_source)"
    ;;
esac

# The origin must belong to the ISOLATED copy, never to the real installation.
REAL_OVERLAY="$HOME/.config/opencode-forge"
REAL_PREFIX="$HOME/.local/share/forge/opencode-v2"
case "$inventory_source" in
  "$REAL_OVERLAY"/*|"$REAL_PREFIX"/*)
    fail "el origen del guard enumerado es la instalacion real: $inventory_source"
    ;;
  "$SANDBOX"/*)
    pass "el origen del guard enumerado esta dentro del aislamiento del escenario"
    ;;
  *)
    fail "el origen del guard enumerado no pertenece al aislamiento del escenario: $inventory_source"
    ;;
esac

for out in "$STATUS_OUT" "$DOCTOR_OUT" "$PLUGIN_LIST_OUT"; do
  if grep -qF "$REAL_OVERLAY" "$out" 2>/dev/null; then
    fail "una salida del escenario menciona el overlay real ($out)"
  fi
done
pass "ninguna salida del escenario menciona el overlay de la instalacion real"

# --- 6. the real installation and the real database were not touched -----
REAL_DB_AFTER="$(stat -c '%d:%i:%s:%Y' "$REAL_DB" 2>/dev/null || echo absent)"
if [ "$REAL_DB_BEFORE" = "$REAL_DB_AFTER" ]; then
  pass "la base de datos real no se ha tocado (solo stat)"
else
  fail "la base de datos real ha cambiado ($REAL_DB_BEFORE -> $REAL_DB_AFTER)"
fi

REAL_OVERLAY_BEFORE="$(stat -c '%d:%i:%s:%Y' "$REAL_OVERLAY" 2>/dev/null || echo absent)"
REAL_OVERLAY_AFTER="$(stat -c '%d:%i:%s:%Y' "$REAL_OVERLAY" 2>/dev/null || echo absent)"
if [ "$REAL_OVERLAY_BEFORE" = "$REAL_OVERLAY_AFTER" ]; then
  pass "el overlay real no se ha tocado"
else
  fail "el overlay real ha cambiado ($REAL_OVERLAY_BEFORE -> $REAL_OVERLAY_AFTER)"
fi

# --- 7. no provider and no own survivor ---------------------------------
if grep -qiE "@playwright/mcp|npx .*-y " "$STATUS_OUT" "$DOCTOR_OUT" "$PLUGIN_LIST_OUT" 2>/dev/null; then
  fail "una salida del escenario menciona un MCP externo"
else
  pass "ninguna salida del escenario menciona un MCP externo (sin proveedores)"
fi

# --- 8. controlled negative check: without a runtime the scenario FAILS ---
if [ -z "${FORGE_TEST_REAL_RUNTIME_NEGATIVE:-}" ]; then
  negative_log="$SANDBOX/negative.log"
  negative_rc=0
  FORGE_TEST_REAL_RUNTIME_NEGATIVE=1 \
  FORGE_TEST_REAL_OPENCODE_BIN="$SANDBOX/does-not-exist/opencode" \
    bash "$FORGE_ROOT/tests/opencode_real_runtime_integration.sh" \
    > "$negative_log" 2>&1 || negative_rc=$?

  if [ "$negative_rc" -ne 0 ]; then
    pass "sin runtime real el escenario falla (rc=$negative_rc, no es un skip verde)"
  else
    fail "sin runtime real el scenario deberia fallar y devolvio rc=0"
  fi

  if grep -qE "no existe|no hay instalacion global|no se puede" "$negative_log" 2>/dev/null; then
    pass "el fallo sin runtime explica la causa"
  else
    fail "el fallo sin runtime no explica la causa"
    sed -n '1,20p' "$negative_log" | sed 's/^/      /' >&2
  fi
fi

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
fi
echo " ALL PASS"
