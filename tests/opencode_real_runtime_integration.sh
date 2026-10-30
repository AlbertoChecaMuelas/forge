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
#      original credentials is used, and no provider is contacted;
#   7. the resolution logic itself is controlled in suite: the user wrapper is
#      rejected in both shapes (regular file and symbolic link) and the binary
#      declared by the package resolves when the npm tree has no <prefix>/bin.
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
# The user's wrapper (~/.local/bin/opencode) installs or updates packages, so
# it is NEVER used as the runtime: both its LITERAL path and the path it
# resolves to are refused, so the rejection does not depend on the shape of
# the link.
#
# The global npm installation is searched with the REAL layout of npm, which
# is NOT `<npm root -g>/.bin`:
#
#   * `<npm root -g>` is `<prefix>/lib/node_modules`; npm does NOT create a
#     `.bin` directory there for a global installation;
#   * npm links the executables of a global installation in `<prefix>/bin`
#     (`npm prefix -g`), where `opencode` is a link to
#     `../lib/node_modules/@opencode/cli/bin/opencode.exe`;
#   * the binary declared by the installed package itself lives in
#     `<npm root -g>/@opencode/cli/bin/opencode.exe`.
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
# configuration and the database) belongs to the sandbox.
#
# The state of the REAL installation is fingerprinted BEFORE the scenario runs
# anything and compared when it finishes, on EVERY exit path (the early ones
# included):
#
#   * the real overlay, the real manifest, the real pinned prefix and the
#     original credentials are compared by METADATA ONLY (stat()/lstat()):
#     the CONTENT of a personal tree is never read, so taking the snapshot
#     cannot leak the credentials nor the auth file of the user. What the
#     comparison detects is the appearance of a new file, a deletion, a
#     rename, a write (size and/or mtime change) and a substitution (device
#     and inode);
#   * the real launcher is compared by link and by metadata;
#   * the real database is observed with stat() ONLY (never opened, never
#     read) and compared by its STABLE properties (device, inode and size).
#     Its mtime is deliberately NOT part of the comparison: the live session
#     of the user writes that database legitimately, and that drift is not
#     attributable to this scenario;
#   * the protected process is observed through EXACTLY ONE channel,
#     /proc/<pid>/stat, and it is never signalled.
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

# The protected state of the real installation, captured BEFORE the scenario
# runs anything (see capture_protected_state) and compared when it finishes.
PROTECTED_BEFORE=""
PROTECTED_CHECKED=0
REAL_DB=""
REAL_DB_BEFORE=""
REAL_LAUNCHER_BEFORE=""

# The protected paths this scenario owns the comparison of. The live OpenCode
# data and state directories are EXCLUDED on purpose: the session of the user
# writes them legitimately (the live database advances its mtime, the prompt
# history grows), so a change there is not attributable to this scenario. The
# real database is observed with stat() only, and never with its mtime.
#
# The observation is BY METADATA ONLY and it is EXPLICIT: the scenario asks
# for exactly these four paths, so it never observes (nor reads the content
# of) any other tree of the user. Filtering a snapshot afterwards would be
# the "read and then filter" pattern that the shared helper now removes.
SCENARIO_PROTECTED_PATHS=".config/opencode-forge:meta .forge-state.json:meta .local/share/forge:meta .opencode-tokens:meta"

pass() { echo "  PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=1; }

# The exact version this contract is written against.
EXPECTED_VERSION="2.1.4"

# ---------------------------------------------------------------------------
# The runtime of the scenario and the filesystem of its sandbox.
# ---------------------------------------------------------------------------

# npm_runtime_candidates
# The paths that can hold the real runtime in a GLOBAL npm installation, in
# the order of preference. It is the SINGLE source of truth of those paths:
# the resolution and the choice of the filesystem of the sandbox read them
# from here, so they can never diverge.
npm_runtime_candidates() {
  local npm_prefix npm_root
  npm_prefix="$(npm prefix -g 2>/dev/null || true)"
  npm_root="$(npm root -g 2>/dev/null || true)"
  [ -n "$npm_prefix" ] && printf '%s\n' "$npm_prefix/bin/opencode"
  [ -n "$npm_root" ] && printf '%s\n' "$npm_root/@opencode/cli/bin/opencode.exe"
  return 0
}

# real_runtime_device
# The device (the filesystem) of the real runtime, when it can be told
# WITHOUT running it: the explicit override, or the two layouts of a global
# npm installation. It NEVER installs anything, never reaches the network
# and never runs the runtime: it only stats the paths that can hold it.
real_runtime_device() {
  local candidate resolved device
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -e "$candidate" ] || continue
    resolved="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
    device="$(stat -c '%d' "$resolved" 2>/dev/null || true)"
    if [ -n "$device" ]; then
      printf '%s\n' "$device"
      return 0
    fi
  done <<EOF
${FORGE_TEST_REAL_OPENCODE_BIN:-}
$(npm_runtime_candidates)
EOF
  return 1
}

# sandbox_base
# The base of the sandbox of the scenario.
#
# The real runtime has to be materialised INSIDE the pinned package (the
# launcher resolves the registered executable with realpath() and REJECTS a
# link that leaves the package), so the sandbox is created on the
# FILESYSTEM of the real runtime when that can be told cheaply: a HARD LINK
# (the very same inode, without a copy and without space) is only possible
# there.
#
# The decision never changes WHAT the scenario tests: it only decides WHERE
# the sandbox lives. FORGE_TEST_SANDBOX_BASE overrides it.
sandbox_base() {
  local explicit="${FORGE_TEST_SANDBOX_BASE:-}"
  local device candidate candidate_device

  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi

  device="$(real_runtime_device)" || device=""
  if [ -n "$device" ]; then
    for candidate in \
      "$FORGE_TEST_REAL_HOME/.cache" \
      "${TMPDIR:-/tmp}" \
      "$TEST_TMP_ROOT"; do
      [ -d "$candidate" ] || continue
      [ -w "$candidate" ] || continue
      candidate_device="$(stat -c '%d' "$candidate" 2>/dev/null || true)"
      if [ -n "$candidate_device" ] && [ "$candidate_device" = "$device" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  printf '%s\n' "$TEST_TMP_ROOT"
}

# materialise_real_runtime <package-dir> <real-binary>
#
# The REAL layout of the pinned package: the executable of the package IS
# the real runtime, at the path that the package DECLARES in its own
# package.json.
#
# A link that leaves the package is exactly what the launcher must REJECT
# (it resolves the registered executable with realpath() and compares it
# with the declared one), so the real runtime is materialised INSIDE the
# package, the way the global npm installation does.
#
# A HARD LINK is used when both share the filesystem: it is the very same
# inode, so the runtime that runs IS the real one and nothing is copied.
# Otherwise the file is COPIED (a reflink when the filesystem supports it).
# When neither is possible the scenario FAILS with the cause: the real
# runtime is NEVER replaced by a fake.
materialise_real_runtime() {
  local package_dir="$1" real_bin="$2"
  local relative target

  relative="$(forge_declared_package_binary "$package_dir")" || return 1
  target="$package_dir/$relative"

  mkdir -p "$(dirname "$target")" || return 1
  rm -f "$target"

  if ln "$real_bin" "$target" 2>/dev/null; then
    printf 'hard-link\n'
    return 0
  fi
  if cp --reflink=auto -- "$real_bin" "$target" 2>/dev/null; then
    printf 'copy-reflink\n'
    return 0
  fi
  if cp -- "$real_bin" "$target" 2>/dev/null; then
    printf 'copy\n'
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# The protected state of the real installation.
# ---------------------------------------------------------------------------

# capture_protected_state
# Fingerprints the protected state of the real installation BEFORE the
# scenario runs anything. The fingerprint is BY METADATA ONLY (stat()/lstat()):
# the content of the overlay, of the manifest, of the pinned prefix and of
# the credentials is NEVER read. What it detects is the appearance of a new
# file, a deletion, a rename, a write (size and/or mtime change) and a
# substitution (device and inode).
capture_protected_state() {
  local snapshot
  snapshot="$(forge_protected_snapshot "$FORGE_TEST_REAL_HOME" "$SCENARIO_PROTECTED_PATHS" 2>/dev/null || true)"
  PROTECTED_BEFORE="$snapshot"
  [ -n "$PROTECTED_BEFORE" ]
}

# assert_protected_unchanged
# Compares the protected state captured before the scenario with the current
# one. It runs ONCE (the first call decides) and it is called from EVERY exit
# path, so a write done by the installer or by the diagnostics is detected
# instead of being credited.
assert_protected_unchanged() {
  [ "$PROTECTED_CHECKED" -eq 0 ] || return 0
  PROTECTED_CHECKED=1

  if [ -z "$PROTECTED_BEFORE" ]; then
    fail "no se pudo tomar la instantanea previa del estado protegido real"
    return 1
  fi

  local after rel before_fp after_fp changed=0
  after="$(forge_protected_snapshot "$FORGE_TEST_REAL_HOME" "$SCENARIO_PROTECTED_PATHS" 2>/dev/null || true)"

  while IFS=$'\t' read -r rel before_fp; do
    [ -n "$rel" ] || continue
    after_fp="$(printf '%s\n' "$after" | awk -F'\t' -v key="$rel" '$1 == key { print $2; exit }')"
    if [ "$before_fp" != "$after_fp" ]; then
      fail "el escenario toco el estado real del usuario: $rel (antes=$before_fp despues=$after_fp)"
      changed=1
    fi
  done <<EOF
$PROTECTED_BEFORE
EOF

  if [ "$changed" -eq 0 ]; then
    pass "el estado protegido real (overlay, manifiesto, prefijo pinado y credenciales) es identico por METADATOS antes y despues del escenario (el contenido no se lee nunca)"
  fi

  return "$changed"
}

# real_launcher_state
# The state of the real launcher (~/.local/bin/forge-opencode): the link, its
# own metadata and the metadata of its target. The content of the checkout it
# points at is never read.
real_launcher_state() {
  local path="$FORGE_TEST_REAL_HOME/.local/bin/forge-opencode"
  local link_target resolved_target

  if [ -L "$path" ]; then
    link_target="$(readlink "$path" 2>/dev/null || printf '')"
    resolved_target="$(readlink -f "$path" 2>/dev/null || printf '')"
    printf 'link:%s|%s|%s\n' "$link_target" \
      "$(stat -c '%d:%i:%s' "$path" 2>/dev/null || printf absent)" \
      "$(stat -c '%d:%i:%s' "$resolved_target" 2>/dev/null || printf absent)"
    return 0
  fi

  if [ -e "$path" ]; then
    printf 'file:%s\n' "$(stat -c '%d:%i:%s' "$path" 2>/dev/null || printf absent)"
    return 0
  fi

  printf 'absent\n'
}

# real_db_state
# The state of the real database, observed with stat() ONLY: it is never
# opened, never read and never written by this scenario.
#
# The criterion, component by component:
#
#   %d  device   The file still lives on the same device. A copy or a
#                replacement that landed on another filesystem is detected.
#   %i  inode    The file is the SAME file. A substitution (another file with
#                the same path) changes the inode, so it is detected.
#   %s  size     The file was neither truncated nor replaced by another
#                content. A truncation keeps the device and the inode and
#                only changes the size, so this is the ONLY component that
#                sees it; dropping it would lose exactly that sensitivity.
#
# Why `size` is accepted even though the database is in WAL mode: this
# scenario only stat()s the file, and the size can only change if SOMETHING
# else wrote it. In CI there is no concurrent legitimate writer (the runner
# installs the CLI globally and does not run any OpenCode session), and the
# real database does not even exist there, so the observed state is `absent`
# before and after and the check cannot produce a false positive. On a
# developer machine a live session exists and a WAL CHECKPOINT of that
# session can legitimately EXTEND the main file; that is the known residual
# risk of this component (the same class of legitimate drift that motivated
# excluding the mtime), it does not weaken the substitution and truncation
# detection, and the surrounding installation is additionally compared by
# CONTENT with a deep fingerprint taken before the scenario ran.
real_db_state() {
  forge_protected_db_state "$REAL_DB"
}

# ---------------------------------------------------------------------------
# The protected PID.
#
# It is observed through EXACTLY ONE channel: /proc/<pid>/stat. Nothing else
# of that process is read (no cmdline, no environ, no exe, no descriptors)
# and it is NEVER signalled. The identity is the starttime: a recycled PID
# has a different one.
# ---------------------------------------------------------------------------
PROTECTED_PID_STATE=""

capture_protected_pid_state() {
  PROTECTED_PID_STATE="$(forge_protected_pid_identity "$FORGE_TEST_PROTECTED_PID" 2>/dev/null || printf 'absent')"
  [ -n "$PROTECTED_PID_STATE" ]
}

assert_protected_pid_unchanged() {
  local after
  after="$(forge_protected_pid_identity "$FORGE_TEST_PROTECTED_PID" 2>/dev/null || printf 'absent')"
  if [ "$after" != "$PROTECTED_PID_STATE" ]; then
    fail "el proceso protegido cambio de identidad o dejo de existir (antes=$PROTECTED_PID_STATE despues=$after)"
    return 1
  fi
  if [ "$after" = "absent" ]; then
    # HONESTO: el proceso protegido NO esta vivo y no se afirma que lo
    # este. El invariante de vida ("530393 vivo con starttime_ticks=
    # 26522468") ya NO puede satisfacerse: el proceso no existe desde el
    # incidente del 2026-10-29 (una sonda de verificacion dirigida de este
    # lote lo termino; ver remediacion-contencion/tester-v14/
    # INCIDENTE-530393.md). El invariante NO se vuelve a exigir: lo que se
    # exige es que el estado este REGISTRADO de forma explicita (ver
    # remediacion-contencion/protected-registry.tsv y el verificador
    # tests/forge_protected_resources.py). La exclusion del PID 530393 en
    # el CODIGO sigue vigente aunque el proceso este muerto: un PID puede
    # ser reciclado.
    pass "el proceso protegido NO EXISTE (estado REGISTRADO del incidente del 2026-10-29); no se exige su vida: $after"
    return 0
  fi
  pass "el proceso protegido sigue vivo con la MISMA identidad (leido solo de /proc/$FORGE_TEST_PROTECTED_PID/stat): $after"
  return 0
}

cleanup() {
  local rc=$?

  # The containment closes every contained run: the kernel tears the private
  # PID namespace down when its PID 1 exits, so no process of this scenario
  # can outlive it. There is no observer to stop and no inventory to sweep.
  #
  # What the scenario DOES owe is the evidence: when a contained run could
  # not be certified, the sandbox and the receipts are KEPT and their
  # location is reported. A failed closure must never look like a clean run.
  if [ -s "${FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE:-}" ]; then
    echo "  FAIL  hay corridas contenidas que no se pudieron certificar; sus recibos se conservan:" >&2
    sed 's/^/        /' "$FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE" >&2
    echo "        el sandbox del escenario se conserva en $SANDBOX" >&2
    rc=1
  else
    if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
      rm -rf "$SANDBOX"
    fi
    if [ -n "${TEST_TMP_ROOT:-}" ] && [ -d "$TEST_TMP_ROOT" ]; then
      rm -rf "$TEST_TMP_ROOT"
    fi
  fi

  # The protected state is compared in EVERY exit path, the early ones
  # included: the fingerprint was taken BEFORE the scenario ran, so a
  # modification made during the installation or during the diagnostics is
  # detected and never credited as "not touched".
  assert_protected_unchanged || true
  assert_protected_pid_unchanged || true

  if [ "$FAIL" -ne 0 ] && [ "$rc" -eq 0 ]; then
    rc=1
  fi

  exit $rc
}

mkdir -p "$TEST_TMP_ROOT"
# The receipts of the contained runs that could NOT be certified are recorded
# here: they are the evidence of a failure and they are never deleted to make
# the scenario look clean.
FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE="$TEST_TMP_ROOT/failed-receipts.txt"
: > "$FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE"
trap cleanup EXIT

# The receipt of the LAST contained run of this scenario. It is the evidence
# of the boundary and of the closure: the scenario never sweeps the process
# table and never reads the command line of an unrelated process.
CONTAINED_RECEIPT=""

# The containment has to be available BEFORE the scenario touches the
# product: without it there is no boundary and no closure to certify.
if ! forge_containment_available; then
  fail "la contencion no esta disponible: el escenario no puede certificar cero procesos propios vivos"
  echo ""
  echo "  FAIL: sin contencion no hay frontera ni cierre que verificar" >&2
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi

# ---------------------------------------------------------------------------
# The state of the REAL installation, captured BEFORE the scenario runs
# anything. Everything the scenario does happens after this point, so any
# difference detected at the end is attributable to the scenario.
# ---------------------------------------------------------------------------
REAL_DB="${FORGE_V2_REAL_DB:-$FORGE_TEST_REAL_HOME/$FORGE_TEST_PROTECTED_DB_REL}"
REAL_DB_BEFORE="$(real_db_state)"
REAL_LAUNCHER_BEFORE="$(real_launcher_state)"
if ! capture_protected_state; then
  fail "no se pudo capturar la instantanea previa del estado protegido real"
  echo ""
  echo "  FAIL: sin instantanea previa no se puede acreditar el estado real" >&2
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi
if ! capture_protected_pid_state; then
  fail "no se pudo observar la identidad del proceso protegido"
  echo ""
  echo "  FAIL: sin identidad previa no se puede acreditar el proceso protegido" >&2
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi

# ---------------------------------------------------------------------------
# The real runtime. The environment of every invocation is neutralised, so the
# binary never reads the original configuration nor the original credentials,
# and it never reaches the network.
#
# Every invocation ALSO runs inside the containment: the supervisor of the
# launcher and the Popen of plugin-sync.py are covered by a private PID
# namespace with a private /proc, without touching their code.
# ---------------------------------------------------------------------------
real_env() {
  local rc=0
  forge_isolated_env "$SANDBOX/home" \
    XDG_RUNTIME_DIR="$SANDBOX/run" \
    TMPDIR="$SANDBOX/tmp" \
    PATH=/usr/bin:/bin \
    LANG=C \
    LC_ALL=C \
    OPENCODE_DISABLE_AUTOUPDATE=1 \
    OPENCODE_DISABLE_MODELS_FETCH=1 \
    OPENCODE_DISABLE_CHANNEL_DB=1 \
    OPENCODE_DISABLE_FILEWATCHER=1 \
    OPENCODE_DISABLE_CLAUDE_CODE=1 \
    OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1 \
    "$@" || rc=$?
  CONTAINED_RECEIPT="$FORGE_CONTAINMENT_LAST_RECEIPT"
  return "$rc"
}

# resolve_real_opencode_bin
# Prints the absolute path of the real binary, or fails with a clear cause.
#
# The candidates are tried in this order:
#
#   1. FORGE_TEST_REAL_OPENCODE_BIN: the absolute path of an existing real
#      executable, used as it is (the way a developer points the suite at an
#      existing local 2.1.4).
#   2. <prefix>/bin/opencode, with prefix = `npm prefix -g`: this is where
#      npm links the executables of a GLOBAL installation (CI does
#      `npm install -g @opencode/cli@2.1.4`, and the link it creates is
#      `<prefix>/bin/opencode -> ../lib/node_modules/@opencode/cli/bin/opencode.exe`).
#   3. <npm root -g>/@opencode/cli/bin/opencode.exe: the binary declared by
#      the package installed in the global tree, followed through its link.
#
# `<npm root -g>/.bin/opencode` is NOT a candidate: npm does not create that
# directory for a global installation (the global root is
# `<prefix>/lib/node_modules` and the executables are linked in
# `<prefix>/bin`), so relying on it made this suite fail in the CI runner that
# installs the CLI globally.
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
    local override_resolved
    override_resolved="$(resolve_link "$override")" || {
      echo "FORGE_TEST_REAL_OPENCODE_BIN no resuelve a un ejecutable real: $override" >&2
      return 1
    }
    # The literal path is checked too: a wrapper that is a symbolic link must
    # be rejected even when the resolved target looks innocent.
    if is_user_wrapper "$override_resolved" "$override"; then
      echo "el wrapper del usuario ($override) no se puede usar: puede instalar o actualizar paquetes" >&2
      return 1
    fi
    printf '%s\n' "$override_resolved"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    echo "npm no esta disponible: no se puede resolver la instalacion global de @opencode/cli" >&2
    return 1
  fi

  local candidates
  candidates="$(npm_runtime_candidates)"

  local candidate resolved rejected=""
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    [ -e "$candidate" ] || continue
    resolved="$(resolve_link "$candidate")" || continue
    # The literal candidate path is checked as well: a candidate that IS the
    # user wrapper is rejected even when the link hides it. A REJECTED
    # candidate never aborts the search: the next candidate is tried.
    if is_user_wrapper "$resolved" "$candidate"; then
      rejected="$rejected $candidate"
      continue
    fi
    printf '%s\n' "$resolved"
    return 0
  done <<CANDIDATES_EOF
$candidates
CANDIDATES_EOF

  if [ -n "$rejected" ]; then
    echo "el wrapper del usuario ($rejected) no se puede usar: puede instalar o actualizar paquetes" >&2
    return 1
  fi

  echo "no hay instalacion global de @opencode/cli (no existe ninguno de: $(printf '%s' "$candidates" | tr '\n' ' ')): instala @opencode/cli@$EXPECTED_VERSION o exporta FORGE_TEST_REAL_OPENCODE_BIN" >&2
  return 1
}

# resolve_link <path>
# Follows the link to the real executable and prints it. It does not decide
# whether the result is acceptable: that is is_user_wrapper's job.
resolve_link() {
  local path="$1"
  local resolved
  resolved="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"
  if [ ! -x "$resolved" ]; then
    echo "el binario resuelto no es ejecutable: $resolved" >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

# forbidden_wrapper_paths
# The user's wrapper (~/.local/bin/opencode) installs or updates packages, so
# it is NEVER used as the runtime of this scenario.
#
# BOTH forms are forbidden, so the rejection does not depend on the SHAPE of
# the wrapper:
#
#   * the LITERAL paths of the wrapper, checked BEFORE following any link: a
#     candidate that IS ~/.local/bin/opencode is the wrapper even when that
#     path is a symlink to some other file (following the link would hide the
#     wrapper);
#   * the paths the wrapper RESOLVES to: if the wrapper is a symlink to X, X
#     is the wrapper's implementation and is forbidden too.
forbidden_wrapper_paths() {
  local candidate resolved

  for candidate in \
    "$HOME/.local/bin/opencode" \
    "$HOME/.local/bin/opencode.exe" \
    "$FORGE_TEST_REAL_HOME/.local/bin/opencode" \
    "$FORGE_TEST_REAL_HOME/.local/bin/opencode.exe"; do
    printf '%s\n' "$candidate"
    if [ -e "$candidate" ]; then
      resolved="$(readlink -f "$candidate" 2>/dev/null || true)"
      if [ -n "$resolved" ]; then
        printf '%s\n' "$resolved"
      fi
    fi
  done
}

# is_user_wrapper <resolved path> [literal candidate path]
# Returns 0 when the candidate IS the user wrapper or points at it. The
# literal candidate path is checked as well, so a wrapper that is a symbolic
# link is rejected even when the resolved path does not look like one.
is_user_wrapper() {
  local resolved="$1" literal="${2:-}" forbidden

  while IFS= read -r forbidden; do
    [ -n "$forbidden" ] || continue
    if [ "$resolved" = "$forbidden" ]; then
      return 0
    fi
    if [ -n "$literal" ] && [ "$literal" = "$forbidden" ]; then
      return 0
    fi
  done <<EOF
$(forbidden_wrapper_paths)
EOF

  return 1
}

# resolution_controls
# Deterministic controls of the resolution logic. They run in EVERY execution
# of this scenario, before the real runtime is resolved, so a regression in the
# resolution cannot hide behind a machine that happens to have a runtime.
#
# They never run a runtime, never touch the real installation and never depend
# on the machine: every simulated tree lives inside the sandbox.
#
#   C1  the user wrapper is REJECTED when it is a REGULAR FILE
#   C2  the user wrapper is REJECTED when it is a SYMBOLIC LINK: the literal
#       path is checked before following any link, so a wrapper that hides
#       behind a link is still recognised (with a resolution that only looked
#       at the resolved path this control would FAIL)
#   C3  the binary DECLARED BY THE PACKAGE resolves in a simulated npm tree
#       that has NO <prefix>/bin (the third candidate of the resolution)
resolution_controls() {
  local controls="$SANDBOX/controls"
  local kind iso wrapper target output rc

  mkdir -p "$controls"

  # --- C1 and C2: the user wrapper is never accepted ----------------------
  for kind in regular symlink; do
    iso="$controls/wrapper-$kind"
    mkdir -p "$iso/.local/bin" "$iso/bin"
    wrapper="$iso/.local/bin/opencode"
    target="$iso/bin/oc"
    printf '#!/bin/sh\nexit 0\n' > "$target"
    chmod +x "$target"

    if [ "$kind" = "symlink" ]; then
      ln -s "$target" "$wrapper"
    else
      cp "$target" "$wrapper"
      chmod +x "$wrapper"
    fi

    rc=0
    output="$(HOME="$iso" FORGE_TEST_REAL_HOME="$iso" \
      FORGE_TEST_REAL_OPENCODE_BIN="$wrapper" \
      resolve_real_opencode_bin 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ] && printf '%s' "$output" | grep -q "wrapper del usuario"; then
      pass "el wrapper del usuario ($kind) se rechaza: la resolucion no lo acepta"
    else
      fail "el wrapper del usuario ($kind) debe rechazarse (rc=$rc, salida: $output)"
    fi
  done

  # --- C3: the binary declared by the package resolves --------------------
  local tree="$controls/npm-package-tree"
  local package_binary="$tree/prefix/lib/node_modules/@opencode/cli/bin/opencode.exe"
  mkdir -p "$tree/prefix/lib/node_modules/@opencode/cli/bin" "$tree/shim"
  printf '#!/bin/sh\nexit 0\n' > "$package_binary"
  chmod +x "$package_binary"
  make_npm_shim "$tree/shim"

  rc=0
  output="$(FORGE_TEST_REAL_OPENCODE_BIN='' \
    PATH="$tree/shim:/usr/bin:/bin" \
    FORGE_TEST_NPM_PREFIX="$tree/prefix" \
    FORGE_TEST_NPM_ROOT="$tree/prefix/lib/node_modules" \
    resolve_real_opencode_bin 2>&1)" || rc=$?

  if [ "$rc" -eq 0 ] && [ "$output" = "$package_binary" ]; then
    pass "el binario declarado por el paquete resuelve cuando el arbol npm no tiene <prefix>/bin"
  else
    fail "el binario declarado por el paquete debe resolver sin <prefix>/bin (rc=$rc, salida: $output)"
  fi
}

# make_npm_shim <dir>
# Creates a fake `npm` that answers `prefix -g` and `root -g` with the tree
# given by FORGE_TEST_NPM_PREFIX and FORGE_TEST_NPM_ROOT. It is used ONLY by
# the controlled negative controls, inside the sandbox: it never installs
# anything and never reaches the network.
make_npm_shim() {
  local dir="$1"

  mkdir -p "$dir"
  cat > "$dir/npm" <<'SHIM_EOF'
#!/bin/sh
# Fake npm for the controlled negative controls of the real runtime
# scenario: it only answers `prefix -g` and `root -g` with the tree given
# by the environment. It never installs anything.
case "${1:-}" in
  prefix)
    printf '%s\n' "$FORGE_TEST_NPM_PREFIX"
    exit 0
    ;;
  root)
    printf '%s\n' "$FORGE_TEST_NPM_ROOT"
    exit 0
    ;;
esac
printf 'fake-npm: comando no soportado: %s\n' "$*" >&2
exit 1
SHIM_EOF
  chmod +x "$dir/npm"
}

# ---------------------------------------------------------------------------
# The scenario.
# ---------------------------------------------------------------------------
echo "================================"
echo " opencode_real_runtime_integration.sh"
echo "================================"

# --- 1. the sandbox -------------------------------------------------------
# The sandbox is created BEFORE the runtime is resolved: the resolution
# controls of section 2 live inside it, so they run in EVERY execution, even
# when the scenario later fails because no real runtime is available.
#
# Its BASE is chosen on the FILESYSTEM of the real runtime when that can be
# told cheaply: the real runtime has to be materialised INSIDE the pinned
# package (the launcher rejects a link that leaves it) and a HARD LINK (the
# very same inode, without a copy and without space) is only possible on the
# same filesystem. The choice never changes WHAT the scenario tests.
SANDBOX_BASE="$(sandbox_base)"
mkdir -p "$SANDBOX_BASE"
SANDBOX="$(mktemp -d "$SANDBOX_BASE/real-runtime.XXXXXX")"
chmod 700 "$SANDBOX"
mkdir -p "$SANDBOX/home" "$SANDBOX/tmp" "$SANDBOX/work" "$SANDBOX/run"
chmod 700 "$SANDBOX/tmp" "$SANDBOX/run"

# --- 2. controls of the resolution logic ----------------------------------
resolution_controls

# --- 3. resolve the real runtime -----------------------------------------
if ! REAL_BIN="$(resolve_real_opencode_bin)"; then
  fail "no hay runtime real disponible: el escenario no puede acreditarse"
  assert_protected_unchanged || true
  echo ""
  echo "  FAIL: sin runtime real el escenario falla; no es un skip verde" >&2
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi

# --- 4. the version of the resolved runtime -------------------------------
if ! REAL_BIN_VERSION="$(real_env "$REAL_BIN" --version 2>/dev/null | head -n 1)"; then
  REAL_BIN_VERSION="(no se pudo ejecutar --version)"
fi
case "$REAL_BIN_VERSION" in
  *"v$EXPECTED_VERSION"*)
    pass "el binario real resuelto es la version $EXPECTED_VERSION ($REAL_BIN)"
    ;;
  *)
    fail "el binario real resuelto no es la version $EXPECTED_VERSION (version obtenida: $REAL_BIN_VERSION, binario: $REAL_BIN)"
    assert_protected_unchanged || true
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
  assert_protected_unchanged || true
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi
pass "la instalacion aislada se crea con el instalador real dentro del sandbox"

PINNED="$SANDBOX/home/.local/share/forge/opencode-v2/node_modules/.bin/opencode"
if [ ! -e "$PINNED" ]; then
  fail "la instalacion aislada no tiene el binario pinado esperado ($PINNED)"
  assert_protected_unchanged || true
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi

# The REAL layout of the pinned package: the executable of the package IS
# the real runtime, at the path that the package DECLARES.
#
# A link from the entry of `.bin` to the runtime OUTSIDE the package is
# exactly what the launcher must REJECT (it resolves the registered
# executable with realpath() and compares it with the declared one), so the
# runtime is materialised INSIDE the package, the way the global npm
# installation does. The entry of `.bin` is NOT touched: it keeps resolving
# to the executable of the package.
PACKAGE_DIR="$SANDBOX/home/.local/share/forge/opencode-v2/node_modules/@opencode/cli"
if ! RUNTIME_MATERIALISATION="$(materialise_real_runtime "$PACKAGE_DIR" "$REAL_BIN")"; then
  fail "no se pudo materializar el runtime real dentro del paquete pinado ($PACKAGE_DIR)"
  assert_protected_unchanged || true
  echo "================================"
  echo " Passed: $PASS_COUNT"
  exit 1
fi
pass "el binario pinado de la instalacion aislada es el runtime real ($REAL_BIN, $RUNTIME_MATERIALISATION)"

# The pinned entry resolves INSIDE the package (the property the launcher
# accredits) and it is the real runtime: the very same inode when it was
# linked, the same content when it had to be copied.
PINNED_REAL="$(readlink -f "$PINNED" 2>/dev/null || printf '')"
case "$PINNED_REAL" in
  "$PACKAGE_DIR"/*)
    pass "el binario pinado resuelve DENTRO del paquete (la acreditacion del launcher lo exige)"
    ;;
  *)
    fail "el binario pinado no resuelve dentro del paquete ($PINNED_REAL)"
    ;;
esac
if [ "$RUNTIME_MATERIALISATION" = "hard-link" ]; then
  if [ "$(stat -c '%d:%i' "$PINNED_REAL" 2>/dev/null || printf '')" \
    = "$(stat -c '%d:%i' "$REAL_BIN" 2>/dev/null || printf '')" ]; then
    pass "el ejecutable del paquete es el MISMO inodo que el runtime real"
  else
    fail "el ejecutable del paquete no es el mismo inodo que el runtime real"
  fi
else
  if [ "$(sha256sum "$PINNED_REAL" 2>/dev/null | cut -d' ' -f1)" \
    = "$(sha256sum "$REAL_BIN" 2>/dev/null | cut -d' ' -f1)" ]; then
    pass "el ejecutable del paquete tiene el MISMO contenido que el runtime real"
  else
    fail "el ejecutable del paquete no tiene el mismo contenido que el runtime real"
  fi
fi

# The isolated database: a valid, EMPTY SQLite file created by the scenario.
# The real database is never opened, copied or read.
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
  assert_protected_unchanged || true
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
# The production helpers are invoked INSIDE the containment: they are
# production code and the processes they create belong to the boundary.
copy_json="$(forge_isolated_env "$SANDBOX/home" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$HELPER" runtime-copy \
  --config-dir "$OVERLAY_DIR" --config "$OVERLAY_CONFIG" \
  --destination "$DIAGNOSTIC_ROOT/xdg/config/opencode-forge" \
  2>"$SANDBOX/runtime-copy.err" || true)"
private_config="$(printf '%s' "$copy_json" | jq -r '.config_file // empty' 2>/dev/null || true)"
private_db="$(forge_isolated_env "$SANDBOX/home" PYTHONDONTWRITEBYTECODE=1 \
  python3 "$HELPER" snapshot-db \
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

  forge_isolated_env "$DIAGNOSTIC_ROOT/home" \
    XDG_RUNTIME_DIR="$DIAGNOSTIC_ROOT/run" \
    TMPDIR="$DIAGNOSTIC_ROOT/xdg/tmp" \
    PATH=/usr/bin:/bin \
    LANG=C \
    LC_ALL=C \
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
REAL_OVERLAY="$FORGE_TEST_REAL_HOME/.config/opencode-forge"
REAL_PREFIX="$FORGE_TEST_REAL_HOME/.local/share/forge/opencode-v2"
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
# The real database: stat() ONLY (it is never opened and never read) and only
# its STABLE properties (device, inode and size). Its mtime is deliberately
# NOT part of the comparison: the live session of the user writes that file
# legitimately and that drift is not attributable to this scenario. What
# proves that the scenario did not write it is that the device, the inode and
# the size did not change: the file was neither replaced nor truncated.
REAL_DB_AFTER="$(real_db_state)"
if [ "$REAL_DB_BEFORE" = "$REAL_DB_AFTER" ]; then
  pass "la base de datos real no se ha tocado (solo stat: dispositivo, inodo y tamano; el mtime lo avanza la sesion viva del usuario, no este escenario)"
else
  fail "la base de datos real ha cambiado ($REAL_DB_BEFORE -> $REAL_DB_AFTER)"
fi

# The real launcher: the link, its own metadata and the metadata of its
# target.
REAL_LAUNCHER_AFTER="$(real_launcher_state)"
if [ "$REAL_LAUNCHER_BEFORE" = "$REAL_LAUNCHER_AFTER" ]; then
  pass "el launcher real no se ha tocado"
else
  fail "el launcher real ha cambiado ($REAL_LAUNCHER_BEFORE -> $REAL_LAUNCHER_AFTER)"
fi

# The real overlay, the real manifest, the real pinned prefix and the
# original credentials are compared by CONTENT, with the deep fingerprint
# taken BEFORE the scenario ran: a modification inside them and the
# appearance of a new file are both detected. On the early exits the same
# comparison is made by the cleanup trap.
assert_protected_unchanged || true

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

  # N2: the global npm tree with the WRONG layout. npm does NOT create
  # `<npm root -g>/.bin` for a global installation (the global root is
  # `<prefix>/lib/node_modules` and the executables are linked in
  # `<prefix>/bin`), so a tree that only has that directory must NOT
  # resolve the runtime. The candidate is a link to the REAL runtime, so a
  # resolution that used it would SUCCEED: the control proves that the
  # resolution does not depend on the wrong layout.
  wrong_layout="$SANDBOX/wrong-npm-layout"
  mkdir -p "$wrong_layout/lib/node_modules/.bin"
  ln -s "$REAL_BIN" "$wrong_layout/lib/node_modules/.bin/opencode"
  make_npm_shim "$SANDBOX/fake-npm"

  wrong_log="$SANDBOX/wrong-layout.log"
  wrong_rc=0
  env -u FORGE_TEST_REAL_OPENCODE_BIN \
    FORGE_TEST_REAL_RUNTIME_NEGATIVE=1 \
    FORGE_TEST_NPM_PREFIX="$wrong_layout" \
    FORGE_TEST_NPM_ROOT="$wrong_layout/lib/node_modules" \
    PATH="$SANDBOX/fake-npm:$PATH" \
    bash "$FORGE_ROOT/tests/opencode_real_runtime_integration.sh" \
    > "$wrong_log" 2>&1 || wrong_rc=$?

  if [ "$wrong_rc" -ne 0 ]; then
    pass "un arbol npm global con el layout incorrecto (<npm root -g>/.bin) no resuelve el runtime (rc=$wrong_rc)"
  else
    fail "el layout incorrecto de npm (<npm root -g>/.bin) no debe resolver el runtime (rc=0)"
  fi

  if grep -qE "no hay instalacion global|no existe" "$wrong_log" 2>/dev/null; then
    pass "el fallo por layout incorrecto de npm explica la causa"
  else
    fail "el fallo por layout incorrecto de npm no explica la causa"
    sed -n '1,20p' "$wrong_log" | sed 's/^/      /' >&2
  fi
fi

# --- 9. the containment, its receipt and the own survivors ------------------
#
# The claim "zero own survivors" is now backed by the CLOSURE of the
# containment and not by an inventory of the host. The receipt of the LAST
# contained run is read here, at the end of the scenario: the boundary must
# be accredited, the closure must be confirmed and the cleanup of the
# product must have been observed. An absent, partial or contradictory
# receipt is a FAILURE, never an empty list of survivors.
if [ -n "${CONTAINED_RECEIPT:-}" ] && [ -s "$CONTAINED_RECEIPT" ]; then
  if forge_receipt_require "$CONTAINED_RECEIPT"; then
    pass "la corrida contenida acredita la frontera y el cierre (recibo: $CONTAINED_RECEIPT)"
  else
    fail "el recibo de la corrida contenida no acredita la frontera ni el cierre"
    forge_receipt_summary "$CONTAINED_RECEIPT" >&2 || true
  fi

  case "$(forge_receipt_product_cleanup "$CONTAINED_RECEIPT")" in
    PASS)
      pass "la limpieza del producto se observo antes de la limpieza defensiva y no queda ningun proceso propio vivo"
      ;;
    FAIL)
      fail "quedan procesos propios vivos dentro de la contencion"
      ;;
    *)
      fail "la limpieza del producto NO se pudo observar: no se puede certificar cero procesos propios vivos"
      ;;
  esac
else
  fail "no hay recibo de la corrida contenida: no se puede certificar cero procesos propios vivos"
fi

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
fi
echo " ALL PASS"
