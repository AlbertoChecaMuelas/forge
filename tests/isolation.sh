#!/usr/bin/env bash
# tests/isolation.sh — shared helpers for the Forge test suites.
#
# Sourced by the suites that invoke the Forge installers. It is NOT a test
# suite on its own (the name does not match the `*_unit.sh` / `*_integration.sh`
# patterns collected by tests/run-all.sh).
#
# It provides four things:
#
#   1. forge_isolated_env — runs a command with the real user environment
#      neutralised AND inside the containment: HOME, the XDG directories and
#      the Forge-owned OpenCode prefix are redirected into the sandbox, the
#      OpenCode config overrides are removed, and the whole scenario runs in
#      a private PID namespace with a private /proc. Without this isolation
#      the installer resolves the pinned OpenCode prefix from the ambient
#      XDG_DATA_HOME and installs @opencode/cli@2.1.4 in the REAL
#      `~/.local/share/forge/opencode-v2`.
#
#   2. forge_protected_snapshot / forge_assert_protected_unchanged — a
#      fingerprint of the real user files that the suites must never touch,
#      taken before the suite runs and compared when it finishes. The
#      fingerprint is BY METADATA ONLY (stat()/lstat()): the CONTENT of a
#      personal tree is never read, so taking the snapshot cannot leak the
#      credentials, the prompt history or the auth file of the user. It also
#      covers the two protected resources: the identity of the protected PID
#      (read from /proc/<pid>/stat only) and the identity of the live
#      database (stat() only).
#
#   3. forge_make_toolchain — a fake npm/opencode toolchain so the suites
#      never download anything and never run a real installation.
#
#   4. The containment helpers (forge_contained_run / forge_receipt_*): the
#      single entry that runs a scenario inside a private PID namespace, the
#      reader of its receipt and the gate that rejects an absent, partial,
#      illegible or contradictory evidence. The observer of the own tree, the
#      subreaper, the registry of identities and the polling of survivors are
#      GONE: the kernel closes the namespace and the receipt accredits it.
#
# Compatible with bash 3.2+.

# ---------------------------------------------------------------------------
# The real user home. It is captured when the helper is sourced, BEFORE any
# test runs: the suites themselves execute with the real HOME, so the
# fingerprint must be taken against it.
# ---------------------------------------------------------------------------
FORGE_TEST_REAL_HOME="${FORGE_TEST_REAL_HOME:-$HOME}"

# ---------------------------------------------------------------------------
# The protected PID. It is observed through EXACTLY ONE channel: the file
# /proc/<pid>/stat. Nothing else of that process is read (no cmdline, no
# environ, no exe, no descriptors) and it is NEVER signalled.
#
# The expected starttime is the identity of the process: a recycled PID has a
# different one, so an identity that changes is a violation.
# ---------------------------------------------------------------------------
FORGE_TEST_PROTECTED_PID="${FORGE_TEST_PROTECTED_PID:-530393}"
FORGE_TEST_PROTECTED_PID_STARTTIME="${FORGE_TEST_PROTECTED_PID_STARTTIME:-26522468}"

# ---------------------------------------------------------------------------
# Real user paths that must stay untouched, with the observation policy.
#
# THE OBSERVATION IS BY METADATA ONLY (lstat()/stat()). The CONTENT of a
# personal tree is NEVER read.
#
# Why: the previous fingerprint HASHED THE CONTENT of these trees, so taking
# the snapshot READ the credentials (~/.opencode-tokens), the OpenCode auth
# file (~/.local/share/opencode/auth.json), the prompt history, the whole
# overlay of the user and the Omarchy tree. Filtering the result afterwards
# did not undo those reads: the read had already happened, and a consumer
# that only kept four lines of the result still had caused a full content
# read of trees it was not authorised to observe. A snapshot that observes
# metadata only can never leak the content of a protected tree.
#
# The policies:
#
#   meta   — a recursive MANIFEST OF METADATA: type, relative path, mode,
#            size and mtime of every entry, plus the target of every
#            symlink. It detects the appearance of a new file, a deletion, a
#            rename, a write (size and/or mtime change) and a substitution
#            (device and inode). It NEVER opens a file.
#   names  — the first level only, by name and by type: no size, no mtime,
#            no inode. It is used for the trees that the live session of the
#            user writes legitimately (the OpenCode data and state
#            directories), whose content changes on its own; it detects the
#            appearance and the disappearance of an entry and nothing else.
#
# The set is EXPLICIT and each entry is justified:
#
#   .config/opencode-forge   the overlay installed by Forge: it must not be
#                             modified by a suite.
#   .forge-state.json        the manifest of the installed state.
#   .local/share/opencode    the live data of OpenCode: the session of the
#   .local/state/opencode    user writes it, so it is observed by name only.
#   .opencode-tokens         the credentials of the user: METADATA ONLY. Its
#                             content is never read, never hashed and never
#                             printed.
#   .local/share/omarchy     the Omarchy tree: it must not be touched.
#   .local/share/forge       the prefix that owns the pinned OpenCode build:
#                             it must never be created (nor deleted) by a
#                             test run.
# ---------------------------------------------------------------------------
FORGE_TEST_PROTECTED_PATHS="
.config/opencode-forge:meta
.forge-state.json:meta
.local/share/opencode:names
.local/state/opencode:names
.opencode-tokens:meta
.local/share/omarchy:meta
.local/share/forge:meta
"

# The path of the live database, relative to the observed base. It is NEVER
# opened, read nor hashed: only stat() is used on it.
FORGE_TEST_PROTECTED_DB_REL=".local/share/opencode/opencode.db"

# forge_protected_db_identity [base]
# The identity (device and inode) of the live database, by stat() ONLY.
# The size is deliberately NOT part of the identity of the general snapshot:
# the database is LIVE and a legitimate WAL CHECKPOINT of the session of the
# user can extend the main file. The strict comparison of device, inode AND
# size lives in forge_protected_db_state, which the real-runtime scenario
# takes in a short window.
forge_protected_db_identity() {
  local base="${1:-$FORGE_TEST_REAL_HOME}" path
  path="$base/$FORGE_TEST_PROTECTED_DB_REL"
  stat -c 'dev:%d:inode:%i' "$path" 2>/dev/null || printf 'absent\n'
}

# forge_protected_db_state [path]
# The state of the live database, by stat() ONLY: device, inode and size.
# The file is never opened, never read and never hashed.
forge_protected_db_state() {
  local path="${1:-$FORGE_TEST_REAL_HOME/$FORGE_TEST_PROTECTED_DB_REL}"
  stat -c 'dev:%d:inode:%i:size:%s' "$path" 2>/dev/null || printf 'absent\n'
}

# forge_protected_pid_identity [pid] [expected-starttime]
# The identity of the protected PID, read from /proc/<pid>/stat ONLY.
# It prints "pid:<pid>:state:<state>:starttime:<ticks>" and fails when the
# process does not exist, when its stat cannot be read or when its starttime
# is not the expected one (a recycled PID).
forge_protected_pid_identity() {
  local pid="${1:-$FORGE_TEST_PROTECTED_PID}" expected="${2:-}" info state ticks
  info="$(forge_identity_state_starttime "$pid")" || return 1
  [ -n "$info" ] || return 1
  state="${info%% *}"
  ticks="${info##* }"
  [ -n "$ticks" ] || return 1
  printf 'pid:%s:state:%s:starttime:%s\n' "$pid" "$state" "$ticks"
  if [ -n "$expected" ] && [ "$ticks" != "$expected" ]; then
    return 1
  fi
  return 0
}

# forge_protected_snapshot [base] [paths-spec]
# Fingerprint of every protected path of the observed base. One line per
# path: "<relative path>\t<fingerprint>".
#
# The optional second argument restricts the observation to an EXPLICIT set
# of "<relative path>:<policy>" entries. It exists so that a scenario that
# only owns four paths observes THOSE FOUR PATHS, instead of observing
# everything and filtering the result afterwards: filtering afterwards is
# exactly the "read and then filter" pattern that this helper exists to
# remove.
#
# Two extra lines are always appended:
#
#   __protected_pid__         the identity of the protected PID (starttime).
#                             It is the check that the protected process is
#                             still the same one. When the process does NOT
#                             exist the line records "absent": that is the
#                             REGISTERED state since the incident of the
#                             2026-10-29 (a directed verification probe of
#                             this lot terminated it; see
#                             remediacion-contencion/tester-v14/
#                             INCIDENTE-530393.md) and it is NOT a failure
#                             of the suite: what the acceptance demands is
#                             that the state be REGISTERED (see
#                             remediacion-contencion/protected-registry.tsv
#                             and tests/forge_protected_resources.py), not
#                             that the process be alive. The exclusion of
#                             the PID in the CODE is unaffected: a PID can
#                             be recycled.
#   __protected_db_identity__ the device and the inode of the live database.
#
# NOTHING of the observed trees is opened: the implementation only calls
# lstat()/stat() and readlink() on the entries.
forge_protected_snapshot() {
  local base="${1:-$FORGE_TEST_REAL_HOME}"
  local spec="${2:-$FORGE_TEST_PROTECTED_PATHS}"

  python3 - "$base" "$spec" <<'PY'
import hashlib
import os
import stat as statmod
import sys

base = os.path.abspath(sys.argv[1])
spec = sys.argv[2]


def kind_of(mode):
    if statmod.S_ISLNK(mode):
        return "L"
    if statmod.S_ISDIR(mode):
        return "D"
    if statmod.S_ISREG(mode):
        return "F"
    return "O"


def link_target(path):
    try:
        return os.readlink(path)
    except OSError:
        return "unreadable"


def entries(directory, deep):
    """The entries of a directory, by METADATA ONLY.

    Nothing is opened: only lstat() and readlink() are used. The result is
    sorted, so the manifest does not depend on the order of the filesystem.
    """
    try:
        with os.scandir(directory) as scan:
            ordered = sorted(scan, key=lambda entry: entry.name)
    except OSError:
        return
    for entry in ordered:
        try:
            info = entry.stat(follow_symlinks=False)
        except OSError:
            continue
        target = link_target(entry.path) if entry.is_symlink() else None
        yield entry.name, info, target
        if deep and entry.is_dir(follow_symlinks=False):
            for item in entries(entry.path, deep):
                yield (entry.name + "/" + item[0], item[1], item[2])


def meta_line(rel, info, target):
    """One line of the METADATA manifest of an entry."""
    kind = kind_of(info.st_mode)
    mode = statmod.S_IMODE(info.st_mode)
    if kind == "L":
        return "L\t%s\t%s" % (rel, target)
    if kind == "D":
        return "D\t%s\t%o\t%d" % (rel, mode, info.st_mtime_ns)
    if kind == "F":
        return "F\t%s\t%o\t%d\t%d" % (rel, mode, info.st_size, info.st_mtime_ns)
    return "O\t%s\t%o\t%d" % (rel, mode, info.st_mtime_ns)


def names_line(rel, info, target):
    """One line of the NAME manifest of an entry: type and name only."""
    return "%s\t%s" % (kind_of(info.st_mode), rel)


def fingerprint(path, policy):
    try:
        info = os.lstat(path)
    except OSError:
        return "absent"
    if statmod.S_ISLNK(info.st_mode):
        return "link:%s:%d:%d" % (link_target(path), info.st_dev, info.st_ino)
    if statmod.S_ISDIR(info.st_mode):
        deep = policy != "names"
        digest = hashlib.sha256()
        count = 0
        for rel, child, target in entries(path, deep):
            line = meta_line(rel, child, target) if deep else names_line(rel, child, target)
            digest.update((line + "\n").encode("utf-8", "replace"))
            count += 1
        return "tree:%d:%s" % (count, digest.hexdigest())
    if statmod.S_ISREG(info.st_mode):
        return "file:%d:%d:%o:%d:%d" % (
            info.st_dev,
            info.st_ino,
            statmod.S_IMODE(info.st_mode),
            info.st_size,
            info.st_mtime_ns,
        )
    return "other:%d:%d:%o" % (info.st_dev, info.st_ino, statmod.S_IMODE(info.st_mode))


for entry in spec.split():
    rel, _, policy = entry.partition(":")
    path = os.path.join(base, rel)
    sys.stdout.write("%s\t%s\n" % (rel, fingerprint(path, policy)))
PY

  printf '__protected_pid__\t%s\n' \
    "$(forge_protected_pid_identity "$FORGE_TEST_PROTECTED_PID" 2>/dev/null || printf 'absent')"
  printf '__protected_db_identity__\t%s\n' "$(forge_protected_db_identity "$base")"
}

# forge_assert_protected_unchanged <before-snapshot> [base] [paths-spec]
# Compares the protected paths with the snapshot taken before the suite ran.
# Returns 0 when nothing changed, 1 (with an explicit diagnostic) otherwise.
#
# The comparison covers the protected paths AND the two protected resources:
# the identity of the protected PID and the identity of the live database.
forge_assert_protected_unchanged() {
  local before="$1" base="${2:-$FORGE_TEST_REAL_HOME}" spec="${3:-}"
  local after rel before_fp after_fp

  if [ -n "$spec" ]; then
    after="$(forge_protected_snapshot "$base" "$spec")"
  else
    after="$(forge_protected_snapshot "$base")"
  fi

  if [ "$before" = "$after" ]; then
    return 0
  fi

  while IFS=$'\t' read -r rel before_fp; do
    [ -n "$rel" ] || continue
    after_fp="$(printf '%s\n' "$after" | awk -F'\t' -v key="$rel" '$1 == key { print $2; exit }')"
    if [ "$before_fp" != "$after_fp" ]; then
      case "$rel" in
        __protected_pid__)
          printf '  FAIL  el proceso protegido cambio de identidad: %s (antes=%s despues=%s)\n' \
            "$rel" "$before_fp" "$after_fp" >&2
          ;;
        __protected_db_identity__)
          printf '  FAIL  la base de datos real cambio de identidad: %s (antes=%s despues=%s)\n' \
            "$rel" "$before_fp" "$after_fp" >&2
          ;;
        *)
          printf '  FAIL  la suite toco un fichero real del usuario: %s (antes=%s despues=%s)\n' \
            "$rel" "$before_fp" "$after_fp" >&2
          ;;
      esac
    fi
  done <<EOF
$(printf '%s\n' "$before")
EOF

  return 1
}

# forge_assert_no_forge_prefix <before-snapshot> [base]
# The pinned OpenCode prefix of the real user must never be CREATED by a test
# run, and it must never be DELETED either.
#
# The mere PREEXISTENCE of the prefix is NOT a failure: on a machine where
# OpenCode is really installed (the cutover V2 installation) the prefix exists
# before the suite starts, and the suite must leave it untouched. It is the
# state BEFORE the run that decides, and that state comes from the snapshot
# taken before any test ran:
#
#   absent  -> absent   : the suite did not create it (clean runner)
#   absent  -> present  : FAIL, the suite created the real prefix
#   present -> absent   : FAIL, the suite deleted the real installation
#   present -> present  : the preexistence is not a failure; MUTATIONS of the
#                         preexisting tree are detected separately by the deep
#                         fingerprint of .local/share/forge (see
#                         forge_assert_protected_unchanged), so the
#                         preexistence never masks a write.
#
# Without a before-snapshot the state before the run is unknowable, so the
# check reports that instead of guessing: a prefix that exists can neither be
# credited nor blamed.
forge_assert_no_forge_prefix() {
  local before="${1:-}" base="${2:-$FORGE_TEST_REAL_HOME}"
  local prefix="$base/.local/share/forge"

  if [ -z "$before" ]; then
    printf '  FAIL  no se paso la instantanea previa del prefijo real de OpenCode: no se puede distinguir preexistencia de creacion\n' >&2
    return 1
  fi

  local before_fp after_fp
  before_fp="$(printf '%s\n' "$before" | awk -F'\t' '$1 == ".local/share/forge" { print $2; exit }')"
  after_fp="$(forge_protected_snapshot "$base" | awk -F'\t' '$1 == ".local/share/forge" { print $2; exit }')"

  if [ -z "$before_fp" ] || [ -z "$after_fp" ]; then
    printf '  FAIL  no se pudo leer la huella del prefijo real de OpenCode (%s)\n' "$prefix" >&2
    return 1
  fi

  if [ "$before_fp" = "absent" ] && [ "$after_fp" = "absent" ]; then
    printf '  PASS  el prefijo real de OpenCode no existe y la suite no lo creo\n'
    return 0
  fi

  if [ "$before_fp" = "absent" ]; then
    printf '  FAIL  la suite instalo el prefijo real de OpenCode: %s\n' "$prefix" >&2
    return 1
  fi

  if [ "$after_fp" = "absent" ]; then
    printf '  FAIL  la suite borro el prefijo real de OpenCode: %s\n' "$prefix" >&2
    return 1
  fi

  # It existed before the run and still exists. The preexistence itself is
  # not a failure; the deep fingerprint of the protected paths proves that
  # nothing inside it changed.
  printf '  PASS  el prefijo real de OpenCode ya existia antes de la suite y sigue presente e intacto (la huella profunda comprueba que no cambio)\n'
  return 0
}

# forge_make_toolchain <dir>
# Creates the fake toolchain used by the suites:
#
#   npm      — materialises the pinned OpenCode build layout instead of
#              downloading @opencode/cli@2.1.4. The suite never touches the
#              network and never installs anything.
#   opencode — a stand-in for the OpenCode CLI that reports the pinned
#              version and the OpenCode 2 auth JSON contract, and that
#              REFUSES every command needing a real runtime (database path
#              resolution, serving, plugin/session enumeration).
#
# The fake is deliberately NOT a runtime: the operational probes of
# `install.sh status`/`doctor` enumerate the installed plugins with a real
# runtime, so with this fake they can only degrade, and the suites assert
# that explicit degradation. Nothing here may simulate a successful
# enumeration; the operational guarantee with a real CLI 2.1.4 is covered by
# the separate real-runtime scenario.
#
# Existing files are never overwritten: a suite may replace the fake
# `opencode` with a specialised one.
forge_make_toolchain() {
  local dir="$1"

  mkdir -p "$dir"

  if [ ! -e "$dir/npm" ]; then
    cat > "$dir/npm" <<'NPM_EOF'
#!/usr/bin/env sh
# Fake npm for the Forge test suites.
#
# `npm install --prefix <dir> <package>` materialises the layout the Forge
# installer expects from the pinned build:
#
#   <dir>/node_modules/@opencode/cli/package.json   (@opencode/cli@2.1.4)
#   <dir>/node_modules/@opencode/cli/bin/opencode   (the pinned executable)
#   <dir>/node_modules/.bin/opencode -> ../@opencode/cli/bin/opencode
#
# The layout is the ACCREDITED one: the launcher refuses to run a pinned
# binary that does not follow it (the entry of `.bin` must resolve to the
# executable of the package, and the package.json must accredit the pinned
# identity and version).
#
# Nothing is downloaded and nothing is installed outside the sandbox.
set -eu

prefix=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)
      prefix="${2:-}"
      shift 2
      ;;
    --prefix=*)
      prefix="${1#--prefix=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

if [ -z "$prefix" ]; then
  printf 'fake-npm: --prefix is required\n' >&2
  exit 1
fi

package_dir="$prefix/node_modules/@opencode/cli"
mkdir -p "$package_dir/bin" "$prefix/node_modules/.bin"

cat > "$package_dir/package.json" <<'PACKAGE_EOF'
{
  "name": "@opencode/cli",
  "version": "2.1.4",
  "bin": {
    "opencode": "bin/opencode"
  }
}
PACKAGE_EOF

cat > "$package_dir/bin/opencode" <<'OPENCODE_EOF'
#!/usr/bin/env sh
# Fake pinned OpenCode build used by the Forge test suites.
#
# It is NOT a runtime and it never pretends to be one:
#
#   * it answers only the two contracts the installer needs at install time
#     (the pinned version and the OpenCode 2 auth JSON),
#   * every command that needs a REAL runtime (resolving the database path,
#     serving, enumerating plugins or sessions) is REFUSED explicitly with a
#     non-zero status and a recognisable message,
#   * any other command echoes its arguments, which is what the launcher
#     contract tests observe.
#
# The operational probes of `install.sh status`/`doctor` need a real runtime,
# so with this fake they MUST degrade. The suites assert that explicit
# degradation, never a healthy result: no successful enumeration can ever be
# simulated here. The operational guarantee with a real CLI 2.1.4 belongs to
# the separate real-runtime scenario.
case "${1:-}" in
  --version)
    printf 'opencodev2.1.4\n'
    exit 0
    ;;
  auth)
    printf '[{"id":"openai","name":"openai","type":"api"}]\n'
    exit 0
    ;;
  debug)
    if [ "${2:-}" = "paths" ] && [ "${3:-}" = "db" ]; then
      printf 'fake-opencode: "debug paths db" requiere un runtime real\n' >&2
      exit 3
    fi
    ;;
  serve)
    printf 'fake-opencode: "serve" requiere un runtime real\n' >&2
    exit 3
    ;;
  plugin|session)
    printf 'fake-opencode: "%s" requiere un runtime real\n' "${1:-}" >&2
    exit 3
    ;;
esac
printf 'ARGV=%s\n' "$*"
printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-}"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}"
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "${OPENCODE_CONFIG:-}" ]; then
  printf '%s\n' '--- CONFIG ---'
  cat "${OPENCODE_CONFIG}"
fi
exit 0
OPENCODE_EOF

chmod +x "$package_dir/bin/opencode"
ln -sfn ../@opencode/cli/bin/opencode "$prefix/node_modules/.bin/opencode"
exit 0
NPM_EOF
    chmod +x "$dir/npm"
  fi

  if [ ! -e "$dir/opencode" ]; then
    cat > "$dir/opencode" <<'OPENCODE_EOF'
#!/usr/bin/env sh
# Fake OpenCode CLI used by the Forge test suites.
#
# It is NOT a runtime and it never pretends to be one:
#
#   * it answers only the two contracts the installer needs at install time
#     (the pinned version and the OpenCode 2 auth JSON),
#   * every command that needs a REAL runtime (resolving the database path,
#     serving, enumerating plugins or sessions) is REFUSED explicitly with a
#     non-zero status and a recognisable message,
#   * any other command echoes its arguments, which is what the launcher
#     contract tests observe.
#
# The operational probes of `install.sh status`/`doctor` need a real runtime,
# so with this fake they MUST degrade. The suites assert that explicit
# degradation, never a healthy result: no successful enumeration can ever be
# simulated here. The operational guarantee with a real CLI 2.1.4 belongs to
# the separate real-runtime scenario.
case "${1:-}" in
  --version)
    printf 'opencodev2.1.4\n'
    exit 0
    ;;
  auth)
    printf '[{"id":"openai","name":"openai","type":"api"}]\n'
    exit 0
    ;;
  debug)
    if [ "${2:-}" = "paths" ] && [ "${3:-}" = "db" ]; then
      printf 'fake-opencode: "debug paths db" requiere un runtime real\n' >&2
      exit 3
    fi
    ;;
  serve)
    printf 'fake-opencode: "serve" requiere un runtime real\n' >&2
    exit 3
    ;;
  plugin|session)
    printf 'fake-opencode: "%s" requiere un runtime real\n' "${1:-}" >&2
    exit 3
    ;;
esac
printf 'ARGV=%s\n' "$*"
printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-}"
printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}"
if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "${OPENCODE_CONFIG:-}" ]; then
  printf '%s\n' '--- CONFIG ---'
  cat "${OPENCODE_CONFIG}"
fi
exit 0
OPENCODE_EOF
    chmod +x "$dir/opencode"
  fi
}

# ---------------------------------------------------------------------------
# The own-process machinery is GONE.
#
# It was: a background observer of the own tree (it walked the descendants on
# every poll, published a heartbeat and wrote an inventory), a subreaper that
# adopted orphans, a registry of identities and a helper that registered a
# process at birth. Together they pretended to guarantee "zero own
# survivors".
#
# That guarantee was FALSE in three ways, and no new discovery mechanism can
# repair it:
#
#   * an INVENTORY is a snapshot of unknown age: it can be empty, partial or
#     stale, and an empty inventory reads as "zero survivors";
#   * a process that was never registered is invisible to any inventory, so
#     the absence of a match proves nothing about it;
#   * the observer polls, so a process created and orphaned between two polls
#     can escape the accounting entirely.
#
# What replaces it is NOT another supervisor: it is the CONTAINMENT of the
# kernel (a private PID namespace with a private /proc) plus the accreditation
# of its boundary and its closure, both recorded in a receipt that the
# consumer must read.
#
# The processes that a suite creates inside the containment are closed by the
# kernel when the PID 1 of the namespace exits: the namespace does not
# survive its init, so nothing inside it can outlive the run. The identity
# helpers of the host are therefore not needed to terminate them, and the
# signalling bound to an identity (a pidfd) is not needed either.
#
# The only enumeration of processes this lot performs is the one made INSIDE
# the frontier, over the PRIVATE /proc of the containment, by the scenario
# that declares the result of the cleanup of the product. It never sees the
# host and it never reads the command line of anything.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The containment: the ONLY authorized entry for a scenario that touches the
# product.
#
# tools/verification/forge-contained-run.sh establishes a private PID
# namespace with a private /proc, accredits the boundary BY INVOCATION
# before the scenario runs, waits for the termination of the contained
# environment and records everything in a receipt.
#
# A consumer MUST read that receipt and reject it when it is absent, partial,
# illegible or contradictory. There is no fallback to the host and there is no
# other way to run a scenario.
# ---------------------------------------------------------------------------
FORGE_OWN_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORGE_OWN_SIGNAL_PY="$FORGE_OWN_HELPERS_DIR/forge_own_signal.py"
FORGE_CONTAINMENT_ENTRY="$FORGE_OWN_HELPERS_DIR/../tools/verification/forge-contained-run.sh"

# The ROOT of the receipts of the contained runs.
#
# It is NOT a fixed path of a machine. It is derived from THIS invocation
# (the PID of the shell and the temporary directory of the caller), so that:
#
#   * the suites run in PARALLEL: two runs never share a root;
#   * the suites run on a machine (or on a CI runner) where no directory of a
#     previous qualification exists: a harness that demanded one would only
#     prove that it runs on the machine that produced it.
#
# A consumer may DECLARE the root explicitly (FORGE_CONTAINMENT_RECEIPT_DIR):
# the declared root wins and it is used verbatim.
FORGE_CONTAINMENT_RECEIPT_DIR="${FORGE_CONTAINMENT_RECEIPT_DIR:-${TMPDIR:-/tmp}/forge-contained-receipts-$$}"

# There is NO global artefact of "capacity" of the containment.
#
# The accreditation of the boundary is BY INVOCATION: the entry accredits its
# own interior inside its private namespace, on every run, and the receipt of
# THAT run is the evidence (ACCREDITATION, ACCREDITATION_REASON,
# CONTAINMENT_EVIDENCE_CERTIFIABLE). A precondition that demanded a file
# produced by a previous qualification would not measure the containment: it
# would measure the presence of a file on a concrete machine, and it would
# refuse to run anywhere else for a reason that has nothing to do with the
# boundary.

FORGE_CONTAINMENT_SCENARIO_TIMEOUT="${FORGE_CONTAINMENT_SCENARIO_TIMEOUT:-300}"
FORGE_CONTAINMENT_CLOSE_TIMEOUT="${FORGE_CONTAINMENT_CLOSE_TIMEOUT:-10}"

# The file that receives the path of the receipt of the run. A consumer that
# needs the evidence sets it BEFORE the call: the variable is inherited by
# the subshell of a command substitution, so it survives `out="$(...)"`.
FORGE_CONTAINMENT_RECEIPT_OUT="${FORGE_CONTAINMENT_RECEIPT_OUT:-}"

# The receipt of the LAST contained run of THIS shell. It is only meaningful
# when forge_contained_run was called in this shell (not in a subshell). It is
# a PUBLIC value of this helper: the suites read it.
# shellcheck disable=SC2034
FORGE_CONTAINMENT_LAST_RECEIPT=""

# The file that records the receipts of the contained runs that could NOT be
# certified. It is a FILE and not a variable because the contained runs are
# usually launched from a subshell (a command substitution): a variable would
# not survive it, and the evidence of a failed run must never be lost.
FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE="${FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE:-}"

# sh_quote <value>
# Prints the value as a single-quoted shell word.
sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# ---------------------------------------------------------------------------
# Identities: a signal bound to an IDENTITY and to nothing else.
#
# The observer is gone, but this part survives because it is NOT a discovery
# mechanism: it never looks for processes, it only acts on identities that
# are ALREADY KNOWN (the ones a process of the fixture registered at
# creation, or the ones a service wrote in its own registration).
#
# It is used INSIDE the containment, where the PIDs of the namespace are the
# ones the identities refer to. A PID of a namespace is meaningless outside
# it: signalling it from the host would hit an unrelated process. That is
# why the termination of a leftover is a job of the CONTAINED scenario and
# never of the suite.
#
# The registry of identities is a DIAGNOSTIC record, not a certificate of
# descendants:
#
#   * its first line identifies the NAMESPACE it belongs to and every other
#     line holds EXACTLY two positive decimal integers ("PID starttime");
#   * an ABSENT, CORRUPTED or UNREADABLE registry is an ERROR: it never
#     means "the process is gone";
#   * only an unequivocal absence, or an identity that no longer matches,
#     accredits that an identity stopped living;
#   * it NEVER certifies that no descendant survived. Only the closure of the
#     containment certifies that.
# ---------------------------------------------------------------------------

# forge_identity_state_starttime <pid>
# Prints "<state> <starttime>" of /proc/<pid>/stat, or nothing when the
# process does not exist or its stat cannot be read.
#
# The comm field (field 2) may contain spaces and parentheses, so the fields
# AFTER the last ')' are used: the state is the first of them and the
# starttime (field 22 of the whole line) the twentieth.
forge_identity_state_starttime() {
  local pid="$1" stat_line rest
  [ -n "$pid" ] || return 1
  [ -r "/proc/$pid/stat" ] || return 1
  stat_line="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
  rest="${stat_line##*)}"
  [ -n "$rest" ] || return 1
  printf '%s\n' "$rest" | awk 'NF >= 20 { print $1, $20 }'
}

# forge_identity_of <pid>
# Prints "<pid> <starttime>" for a live (non zombie) process. Nothing is
# printed for a process that does not exist or that is already a zombie.
forge_identity_of() {
  local pid="$1" info state ticks
  info="$(forge_identity_state_starttime "$pid")" || return 1
  [ -n "$info" ] || return 1
  state="${info%% *}"
  ticks="${info##* }"
  [ "$state" != "Z" ] || return 1
  printf '%s %s\n' "$pid" "$ticks"
}

# forge_identity_matches <pid> <starttime>
# Succeeds when the process <pid> exists, is not a zombie and its starttime
# is EXACTLY <starttime>: the identity recorded is the identity that is
# alive. A recycled PID never matches.
forge_identity_matches() {
  local pid="$1" ticks="$2" live
  [ -n "$pid" ] || return 1
  [ -n "$ticks" ] || return 1
  live="$(forge_identity_of "$pid")" || return 1
  [ "$live" = "$pid $ticks" ]
}

# forge_signal_own_identity <pid> <starttime> <signal-name> \
#                           <owner-pid> <owner-starttime>
#
# Sends <signal-name> to the process identified by (<pid>, <starttime>) and
# to NOBODY else.
#
# The identity is verified BEFORE the signal and, when the kernel offers it,
# the signal is delivered THROUGH a pidfd: a pidfd refers to the PROCESS, not
# to the number, so a PID that is recycled from that moment on can never
# become the target. Without a pidfd the signal falls back to the number and
# the ONLY guarantee available is a RE-VERIFICATION of the starttime made
# IMMEDIATELY BEFORE the signal; that mechanism is WEAKER and it never
# claims to be the pidfd one.
#
# The identity ALONE does not authorise a signal. The helper ALSO requires
# the OWNER of the containment (its pid and its starttime): the helper
# refuses to signal anything that does not descend from that owner, it
# refuses to signal outside the accredited namespace of the containment and
# it refuses the protected PID outright.
#
# Exit status:
#   0  the signal was delivered to that identity.
#   2  the process is gone (there is no such PID).
#   3  the identity does NOT match: the PID was recycled. NOTHING is
#      signalled.
#   4  the signal could not be delivered (bad arguments or an error).
#   5  the signal was REFUSED (not own, not contained, or protected).
forge_signal_own_identity() {
  local pid="$1" ticks="$2" signame="${3:-TERM}" owner="${4:-}" owner_ticks="${5:-}"
  python3 "$FORGE_OWN_SIGNAL_PY" "$pid" "$ticks" "$signame" "$owner" "$owner_ticks"
}

# forge_own_identities_check <file> [expected-namespace]
#
# Verifies that a registry of identities can be TRUSTED as a diagnostic
# record. It FAILS when:
#
#   * the file does not exist or cannot be read: an ABSENT registry is NOT an
#     empty registry and never means "there was nothing to clean";
#   * the first line does not identify a NAMESPACE;
#   * the namespace is not the expected one (contradictory evidence);
#   * some identity line is not exactly two positive decimal integers
#     (corrupted evidence).
#
# It prints the number of identities when it succeeds.
forge_own_identities_check() {
  local file="$1" expected="${2:-}" line count=0 first=1
  if [ ! -f "$file" ]; then
    printf 'el registro de identidades propias no existe (%s): su ausencia es un ERROR, no la prueba de que no quede nada vivo\n' \
      "$file" >&2
    return 1
  fi
  if [ ! -r "$file" ]; then
    printf 'el registro de identidades propias no se puede leer (%s): es un ERROR\n' "$file" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" = 1 ]; then
      first=0
      case "$line" in
        "NAMESPACE "*)
          if [ -n "$expected" ] && [ "$line" != "NAMESPACE $expected" ]; then
            printf 'el registro de identidades propias pertenece a otro namespace (%s): evidencia contradictoria\n' \
              "$file" >&2
            return 1
          fi
          continue
          ;;
        *)
          printf 'el registro de identidades propias no identifica su namespace (%s)\n' "$file" >&2
          return 1
          ;;
      esac
    fi
    [ -n "$line" ] || continue
    if ! printf '%s\n' "$line" | grep -Eq '^[1-9][0-9]* [1-9][0-9]*$'; then
      printf 'el registro de identidades propias tiene una linea mal formada (%s): %s\n' "$file" "$line" >&2
      return 1
    fi
    count=$(( count + 1 ))
  done < "$file"
  if [ "$first" = 1 ]; then
    printf 'el registro de identidades propias esta vacio (%s): un registro vacio no prueba nada\n' "$file" >&2
    return 1
  fi
  printf '%s\n' "$count"
  return 0
}

# forge_shell_defs_duplicates <scanner> <file>
#
# Runs the scanner of the REAL definitions of a shell file and reports what
# it found. The exit status is the VERDICT of the scan, and it is NEVER
# confused with the output:
#
#   0  the scanner worked and there are NO duplicates;
#   1  the scanner worked and there ARE duplicates (they are printed);
#   2  the scanner FAILED (it could not do its work).
#
# The third status exists because an EMPTY output of a scanner that failed is
# NOT "no duplicates": it is the absence of evidence, and it must never be
# reported as the absence of duplicates. The duplicates are printed on the
# standard output; the diagnostics of the scanner go to its standard error.
forge_shell_defs_duplicates() {
  local scanner="$1" file="$2" output rc=0
  [ -n "$scanner" ] || return 2
  [ -n "$file" ] || return 2
  # The duplicates of the scanner are printed on its standard output and its
  # diagnostics go to its standard error: they are NOT mixed, because the
  # output is what says that the scan worked.
  output="$(python3 "$scanner" duplicates "$file")" || rc=$?
  case "$rc" in
    0)
      if [ -z "$output" ]; then
        return 0
      fi
      printf '%s\n' "$output" >&2
      return 2
      ;;
    1)
      if [ -n "$output" ]; then
        printf '%s\n' "$output"
        return 1
      fi
      return 2
      ;;
    *)
      return 2
      ;;
  esac
}

# forge_kill_own_identities <identities-file> [signal-name] \
#                            <owner-pid> <owner-starttime>
#
# Signals ONLY the identities recorded in <identities-file>. For every line
# the identity is verified and the signal is delivered as described in
# forge_signal_own_identity, so a PID whose starttime does not match the
# recorded one is SKIPPED and never signalled.
#
# The OWNER of the containment is required: the helper only signals the
# identities that DESCEND from it, and it refuses to signal anything that is
# not own.
#
# One line per identity is printed:
#   signal <pid> <starttime> <SIGNAL> <mechanism>
#   skip   <pid> <starttime> <reason>
forge_kill_own_identities() {
  local file="$1" signame="${2:-TERM}" owner="${3:-}" owner_ticks="${4:-}"
  local pid ticks out rc
  [ -f "$file" ] || return 0
  if [ -z "$owner" ] || [ -z "$owner_ticks" ]; then
    printf 'skip %s sin propietario: el origen de la identidad no es verificable\n' "$file" >&2
    return 0
  fi
  while read -r pid ticks; do
    [ -n "${pid:-}" ] || continue
    case "$pid" in NAMESPACE) continue ;; esac
    [ -n "${ticks:-}" ] || continue
    # The shell that runs the scenario is the HARNESS, never a resource of
    # the fixture: this helper never signals it.
    [ "$pid" = "$$" ] && continue
    rc=0
    out="$(forge_signal_own_identity "$pid" "$ticks" "$signame" "$owner" "$owner_ticks" 2>/dev/null)" || rc=$?
    case "$rc" in
      0) printf 'signal %s %s %s %s\n' "$pid" "$ticks" "$signame" "$out" ;;
      2) printf 'skip %s %s already-gone\n' "$pid" "$ticks" ;;
      3) printf 'skip %s %s identity-mismatch\n' "$pid" "$ticks" ;;
      5) printf 'skip %s %s refused-not-own\n' "$pid" "$ticks" ;;
      *) printf 'skip %s %s error\n' "$pid" "$ticks" ;;
    esac
  done < "$file"
  return 0
}

# forge_containment_available
#
# Succeeds only when the entry is present and the root of the receipts of
# THIS invocation can be used. It NEVER degrades to the host and it NEVER
# runs the scenario outside the containment.
#
# The accreditation of the boundary is BY INVOCATION and it is NOT a
# precondition of this helper: the entry certifies its own interior on every
# run and the receipt of that run is the evidence. This helper therefore
# demands NO artefact produced by a previous qualification: such a demand
# would only prove that the machine is the one that produced it.
forge_containment_available() {
  if [ ! -f "$FORGE_CONTAINMENT_ENTRY" ]; then
    printf 'la entrada de contencion no existe (%s)\n' "$FORGE_CONTAINMENT_ENTRY" >&2
    return 1
  fi
  if [ ! -d "$FORGE_CONTAINMENT_RECEIPT_DIR" ]; then
    (umask 077 && mkdir -p -- "$FORGE_CONTAINMENT_RECEIPT_DIR") 2>/dev/null || {
      printf 'no se puede usar el directorio de recibos (%s)\n' \
        "$FORGE_CONTAINMENT_RECEIPT_DIR" >&2
      return 1
    }
  fi
  return 0
}

# forge_write_containment_killer <dir>
#
# Writes <dir>/forge-containment-killer.sh: the helper that TERMINATES the
# processes of an identity registry, INSIDE the containment.
#
# It exists because a PID of a PID namespace is meaningless outside it: the
# termination of a leftover has to happen where the identity is valid. Every
# signal is bound to the identity: the starttime is verified immediately
# before the signal, so a recycled PID is never signalled, and the escalation
# is bounded (TERM, then KILL, with a capped wait).
#
# The identity ALONE does not authorise a signal. The helper ALSO requires:
#
#   * the NAMESPACE of the registry to be the namespace of this process: a
#     registry of another namespace is evidence that does not belong here and
#     NOTHING is signalled;
#   * the OWNER of the containment (its pid and its starttime, declared by
#     the scenario): the target MUST descend from it, so that only the
#     processes that are own are signalled;
#   * the PROTECTED PID is refused outright, whatever its identity is.
#
# It reads /proc/<pid>/stat of the OWN processes only (the ones the registry
# holds) and never the command line of anything.
forge_write_containment_killer() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  cat > "$dir/forge-containment-killer.sh" <<'CONTAINMENT_KILLER_EOF'
#!/bin/sh
# Terminates the own processes of an identity registry, inside the
# containment. Usage: forge-containment-killer.sh <identities-file> [signal]
#                                          [owner-pid] [owner-starttime]
#
# The PID 1 of the namespace and the caller are never signalled: they are
# the harness, never a resource of the fixture.
registry="$1"
signame="${2:-TERM}"
owner_pid="${3:-}"
owner_ticks="${4:-}"
protected_pid="${FORGE_TEST_PROTECTED_PID:-530393}"
[ -f "$registry" ] || exit 0

identity_ticks() {
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done < "/proc/$1/stat" 2>/dev/null
  [ -n "$line" ] || return 1
  rest=${line##*)}
  [ -n "$rest" ] || return 1
  set -f
  set -- $rest
  set +f
  [ "$#" -ge 20 ] || return 1
  printf '%s\n' "${20}"
}

parent_of() {
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done < "/proc/$1/stat" 2>/dev/null
  [ -n "$line" ] || return 1
  rest=${line##*)}
  [ -n "$rest" ] || return 1
  set -f
  set -- $rest
  set +f
  [ "$#" -ge 2 ] || return 1
  printf '%s\n' "$2"
}

# The provenance of the identity: the target MUST descend from the owner of
# the containment. The chain is read from the OWN /proc entries of the
# target; it never discovers processes.
descends_from_owner() {
  current="$1"
  hops=0
  while [ "$current" -gt 1 ] && [ "$hops" -lt 64 ]; do
    parent="$(parent_of "$current")" || return 1
    [ "$parent" = "$owner_pid" ] && return 0
    current="$parent"
    hops=$((hops + 1))
  done
  return 1
}

# The NAMESPACE of the registry must be the one of this process: a registry
# that belongs to another namespace is not evidence that belongs here.
registry_namespace=""
while IFS= read -r entry; do
  case "$entry" in
    "NAMESPACE "*) registry_namespace=${entry#NAMESPACE } ;;
    *) break ;;
  esac
done < "$registry"
own_namespace="$(readlink /proc/self/ns/pid 2>/dev/null || printf 'UNKNOWN')"
[ -n "$registry_namespace" ] || exit 0
[ "$registry_namespace" = "$own_namespace" ] || exit 0

# The owner must be alive with the identity that the scenario declared.
[ -n "$owner_pid" ] || exit 0
[ -n "$owner_ticks" ] || exit 0
current_owner="$(identity_ticks "$owner_pid")" || exit 0
[ "$current_owner" = "$owner_ticks" ] || exit 0

signal_registry() {
  wanted="$1"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in NAMESPACE*) continue ;; esac
    pid=${entry%% *}
    ticks=${entry##* }
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$ticks" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$$" ] && continue
    # The protected PID is NEVER signalled, whatever its identity says.
    [ "$pid" = "$protected_pid" ] && continue
    current=$(identity_ticks "$pid") || continue
    [ "$current" = "$ticks" ] || continue
    descends_from_owner "$pid" || continue
    kill -s "$wanted" "$pid" 2>/dev/null || true
  done < "$registry"
}

alive_registry() {
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in NAMESPACE*) continue ;; esac
    pid=${entry%% *}
    ticks=${entry##* }
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$ticks" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "1" ] && continue
    [ "$pid" = "$$" ] && continue
    [ "$pid" = "$protected_pid" ] && continue
    current=$(identity_ticks "$pid") || continue
    [ "$current" = "$ticks" ] || continue
    printf '%s %s\n' "$pid" "$ticks"
  done < "$registry"
}

signal_registry TERM
waited=0
while [ "$waited" -lt 100 ]; do
  [ -z "$(alive_registry)" ] && break
  sleep 0.05
  waited=$((waited + 1))
done
if [ -n "$(alive_registry)" ]; then
  signal_registry KILL
  waited=0
  while [ "$waited" -lt 40 ]; do
    [ -z "$(alive_registry)" ] && break
    sleep 0.05
    waited=$((waited + 1))
  done
fi
alive_registry
CONTAINMENT_KILLER_EOF
  chmod +x "$dir/forge-containment-killer.sh"
  return 0
}

# forge_write_containment_observer <dir>
#
# Writes <dir>/forge-containment-observer.sh: the helper that lists the LIVE
# processes of the PRIVATE /proc of the containment.
#
# It is the ONLY enumeration of processes of this lot and it happens INSIDE
# the frontier, where the /proc is private: it can only see the processes of
# the contained scenario, never a process of the host. It reads the stat of
# the processes (never their command line) and it prints one
# "<pid> <starttime>" line per live process, excluding the PID 1 of the
# namespace, itself, the PIDs the caller excludes and the ANCESTORS of the
# observer.
#
# THE HARNESS IS NOT THE PRODUCT. The scaffolding that the containment entry
# created around the scenario (the scenario itself, the `timeout` that bounds
# it and the PID 1 of the namespace) is alive BY CONSTRUCTION while the
# scenario runs, so it is NOT a leftover of the product. It is excluded BY
# ANCESTRY: the chain of ancestors of this observer is computed from its own
# /proc entries, exactly as the official CLEAN-1 observer of the battery
# (tests/forge_run_all_cleanup.py) does. It is NEVER excluded by NAME: an
# exception by name would be a hole through which a real leftover could hide,
# and the descendants that the product leaves behind (a reparented one, for
# instance) are NOT ancestors and are still counted.
#
# It uses shell builtins ONLY: a helper that spawned a process would see its
# own children in the listing and would report them as leftovers.
#
# The exit status is part of its contract:
#
#   0  the observation was COMPLETE: the root was OBSERVABLE, its
#      enumeration PRODUCED entries and every enumerated process was observed;
#   3  the observation was INCOMPLETE: the root or its enumeration could NOT
#      be observed (the root does not exist, its own stat could not be read,
#      the enumeration produced nothing) or at least one enumerated process
#      could NOT be observed (an error of the reading, not a process that
#      disappeared while it was being read).
#
# An empty listing with the status 0 is an empty inventory. An empty
# listing that was NOT obtained is not: the caller MUST refuse to read it as
# "there was nothing alive". The observer NEVER certifies an inventory that
# it did not obtain: a root that cannot be enumerated is an INCOMPLETE
# observation, NOT an empty one.
forge_write_containment_observer() {
  local dir="$1"
  [ -n "$dir" ] || return 1
  mkdir -p "$dir" || return 1
  cat > "$dir/forge-containment-observer.sh" <<'CONTAINMENT_OBSERVER_EOF'
#!/bin/sh
# Lists the live processes of the PRIVATE /proc of this containment.
# Usage: forge-containment-observer.sh [pid-to-exclude...]
#
# It never reads the cmdline of anything, it never leaves the namespace and
# it never spawns a process (a spawned helper would appear in the listing).
# The globbing of /proc is needed, so the glob is disabled only around the
# word splitting of the fields of the stat, which are never patterns.
self=$$
excluded_pids="$*"
unobservable=0
# The root of the procfs that this observer reads. It is the PRIVATE /proc of
# the containment and it can only be another one when the variable is set
# EXPLICITLY, which the entry never does (the environment of the scenario is
# rebuilt from scratch): the seam exists so that the behaviour of the
# observer can be proven with a synthetic tree of processes.
proc_root="${FORGE_CONTAINMENT_OBSERVER_PROC_ROOT:-/proc}"

# The ROOT of the observation must be OBSERVABLE, and that has to be proved
# with POSITIVE evidence, never with the absence of leftovers.
#
# A root that does not exist, that is not a directory or whose own `stat`
# cannot be read is NOT an empty inventory: it is an observation that could
# NOT be made. The same is true of an enumeration that produced NOTHING: a
# glob that does not match a single entry says nothing about the processes
# that are alive. In both cases the observation is INCOMPLETE and the caller
# MUST know it.
if [ ! -d "$proc_root" ]; then
  printf 'forge-containment-observer: la raiz observada NO es observable (%s)\n' \
    "$proc_root" >&2
  exit 3
fi
root_stat=""
while IFS= read -r chunk; do
  root_stat="$chunk"
done 2>/dev/null < "$proc_root/stat"
if [ -z "$root_stat" ]; then
  printf 'forge-containment-observer: el stat de la raiz observada NO se pudo leer (%s)\n' \
    "$proc_root" >&2
  exit 3
fi

# The parental relation of a process, read from its OWN /proc entry. No
# subprocess is spawned: a helper that forked would see its own child in the
# listing and would report it as a leftover.
PPID_OF=""
read_ppid() {
  PPID_OF=""
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done 2>/dev/null < "$proc_root/$1/stat"
  [ -n "$line" ] || return 1
  rest=${line##*)}
  set -f
  set -- $rest
  set +f
  [ "$#" -ge 2 ] || return 1
  PPID_OF=$2
  return 0
}

# The ANCESTORS of this observer are the scaffolding of the harness (the
# scenario, the `timeout` that bounds it and the PID 1 of the namespace).
# They are excluded BY ANCESTRY and never by name.
ancestor=""
if read_ppid "$self"; then
  ancestor=$PPID_OF
fi
hops=0
while [ -n "$ancestor" ] && [ "$ancestor" -gt 1 ] && [ "$hops" -lt 64 ]; do
  excluded_pids="$excluded_pids $ancestor"
  next=""
  if read_ppid "$ancestor"; then
    next=$PPID_OF
  fi
  ancestor=$next
  hops=$((hops + 1))
done

enumerated=0
for entry in "$proc_root"/[0-9]*; do
  [ -d "$entry" ] || continue
  enumerated=$((enumerated + 1))
  pid=${entry##*/}
  [ "$pid" = "1" ] && continue
  [ "$pid" = "$self" ] && continue
  skip=no
  for excluded in $excluded_pids; do
    [ "$excluded" = "$pid" ] && skip=yes
  done
  [ "$skip" = no ] || continue
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done 2>/dev/null < "$entry/stat"
  if [ -z "$line" ]; then
    # The stat could NOT be read. The process may have DISAPPEARED while it
    # was being read (its entry is gone) or the reading may have FAILED (an
    # error that prevents observing it). The two are NOT the same: the
    # second one makes the observation INCOMPLETE and it is reported as
    # such. A process that was ENUMERATED and could not be OBSERVED is
    # never counted as absent.
    [ -d "$entry" ] && unobservable=$((unobservable + 1))
    continue
  fi
  rest=${line##*)}
  if [ -z "$rest" ]; then
    [ -d "$entry" ] && unobservable=$((unobservable + 1))
    continue
  fi
  set -f
  set -- $rest
  set +f
  if [ "$#" -lt 20 ]; then
    [ -d "$entry" ] && unobservable=$((unobservable + 1))
    continue
  fi
  state=$1
  ticks=${20}
  [ "$state" = "Z" ] && continue
  [ -n "$ticks" ] || continue
  printf '%s %s\n' "$pid" "$ticks"
done

# The observation is INCOMPLETE when the ENUMERATION itself produced
# nothing: an inventory that was not obtained is never an empty inventory.
if [ "$enumerated" -eq 0 ]; then
  printf 'forge-containment-observer: la enumeracion de la raiz observada NO produjo entradas (%s)\n' \
    "$proc_root" >&2
  exit 3
fi

# The observation is INCOMPLETE when a process that was enumerated could not
# be observed. The caller MUST know it: an empty listing that was not
# obtained is not an empty inventory.
if [ "$unobservable" -gt 0 ]; then
  printf 'forge-containment-observer: %s procesos enumerados NO se pudieron observar\n' \
    "$unobservable" >&2
  exit 3
fi
exit 0
CONTAINMENT_OBSERVER_EOF
  chmod +x "$dir/forge-containment-observer.sh"
  return 0
}

# forge_contained_run <scenario-script> [args...]
#
# Runs <scenario-script> inside the containment and returns the RC of the
# entry (0 only when the scenario succeeded AND the closure was confirmed).
#
# The scenario script is executed by the PID 1 of the namespace with:
#
#   * a temporary HOME / XDG_* / TMPDIR (the context of the containment);
#   * FORGE_PRODUCT_CLEANUP_RESULT_FILE pointing at the marker where the
#     scenario declares the result of the cleanup of the PRODUCT;
#   * "$1" = the path of the observer of the private /proc;
#   * "$2"... = the command the scenario has to run.
#
# The receipt of the run is written to $FORGE_CONTAINMENT_RECEIPT_OUT when
# that variable is set, and it is ALWAYS verified here: an absent, partial,
# illegible or contradictory receipt FAILS the call. There is no "PASS by
# absence" and the RC of the scenario is never replaced by the RC of the
# defensive cleanup.
forge_contained_run() {
  local script="$1"
  shift
  [ -n "$script" ] || return 1
  [ -f "$script" ] || {
    printf 'el escenario contenido no existe (%s)\n' "$script" >&2
    return 1
  }

  forge_containment_available || return 70

  local workdir observer killer
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/forge-contained.XXXXXX")" || return 70
  forge_write_containment_observer "$workdir" || {
    rm -rf "$workdir"
    return 70
  }
  forge_write_containment_killer "$workdir" || {
    rm -rf "$workdir"
    return 70
  }
  observer="$workdir/forge-containment-observer.sh"
  killer="$workdir/forge-containment-killer.sh"

  local receipt_out="${FORGE_CONTAINMENT_RECEIPT_OUT:-}"
  if [ -z "$receipt_out" ]; then
    receipt_out="$workdir/receipt.txt"
  fi
  rm -f "$receipt_out"

  local rc=0
  # The stderr of the ENTRY IS the stderr of the SCENARIO: the entry reserves
  # its standard output and its standard error EXCLUSIVELY for the scenario
  # and publishes its own diagnosis in the fields of the receipt
  # (CONTAINMENT_EVIDENCE_CERTIFIABLE and POSITIVE_ACCEPTANCE), never on the
  # streams that the consumer captures.
  #
  # There is NO filter here, and there is NO capture to a temporary file:
  # forwarding the stderr verbatim is the NORMAL behaviour, and any diagnostic
  # that the entry ever wrote on its stderr would show up here, where it can
  # be seen, instead of being hidden by a mitigation. (The mitigation that
  # filtered the diagnostic of the entry was removed when the entry was fixed
  # at the root.)
  bash "$FORGE_CONTAINMENT_ENTRY" \
    --receipt-dir "$FORGE_CONTAINMENT_RECEIPT_DIR" \
    --receipt-out "$receipt_out" \
    --scenario-timeout "$FORGE_CONTAINMENT_SCENARIO_TIMEOUT" \
    --close-timeout "$FORGE_CONTAINMENT_CLOSE_TIMEOUT" \
    -- /bin/sh "$script" "$observer" "$killer" "$@" || rc=$?

  # The published file holds the PATH of the receipt, not the receipt itself.
  local receipt_path=""
  if [ -s "$receipt_out" ]; then
    IFS= read -r receipt_path < "$receipt_out" || receipt_path=""
  fi
  if [ -z "$receipt_path" ] || [ ! -s "$receipt_path" ]; then
    printf 'la contencion no publico ningun recibo utilizable (%s)\n' "$receipt_out" >&2
    rm -rf "$workdir"
    [ "$rc" -ne 0 ] && return "$rc"
    return 70
  fi
  # shellcheck disable=SC2034  # valor PUBLICO de este helper: las suites lo leen
  FORGE_CONTAINMENT_LAST_RECEIPT="$receipt_path"

  # The EVIDENCE OF THE CONTAINMENT is the first gate: an absent, partial,
  # illegible or contradictory receipt is rejected. There is no "PASS by
  # absence" and there is no inference from a missing field.
  if ! forge_receipt_containment_evidence "$receipt_path"; then
    printf 'la evidencia de la contencion no es certificable (%s)\n' "$receipt_path" >&2
    forge_receipt_summary "$receipt_path" >&2 || true
    forge_contained_note_failed_receipt "$receipt_path"
    rm -rf "$workdir"
    [ "$rc" -ne 0 ] && return "$rc"
    return 70
  fi

  # The result of the PRODUCT is a verdict of its own: the defensive cleanup
  # of the containment NEVER converts a failure of the product into a PASS.
  local product_result scenario_rc expected_rc
  product_result="$(forge_receipt_product_cleanup "$receipt_path")"
  if [ "$product_result" != "PASS" ]; then
    printf 'la limpieza del producto NO esta acreditada (%s)\n' "$product_result" >&2
    forge_receipt_summary "$receipt_path" >&2 || true
    forge_contained_note_failed_receipt "$receipt_path"
    rm -rf "$workdir"
    [ "$rc" -ne 0 ] && return "$rc"
    return 70
  fi

  # The RC of the scenario is compared with the EXPECTED one. A scenario that
  # ended with another RC keeps ITS OWN RC: the acceptance is not positive,
  # but the verdict of the scenario is not replaced by anything.
  scenario_rc="$(forge_receipt_read "$receipt_path" SCENARIO_RC 2>/dev/null || printf 'NOT_AVAILABLE')"
  expected_rc="$(forge_receipt_read "$receipt_path" EXPECTED_SCENARIO_RC 2>/dev/null || printf 'NOT_AVAILABLE')"
  if [ "$scenario_rc" != "$expected_rc" ]; then
    printf 'el RC del escenario (%s) no es el RC esperado (%s): no hay aceptacion positiva\n' \
      "$scenario_rc" "$expected_rc" >&2
    forge_receipt_summary "$receipt_path" >&2 || true
    rm -rf "$workdir"
    [ "$rc" -ne 0 ] && return "$rc"
    return 70
  fi

  # The last gate is the POSITIVE ACCEPTANCE, and it CROSS-CHECKS the flag
  # that the receipt declares: the consumer does not take it on trust.
  if ! forge_receipt_positive_acceptance "$receipt_path"; then
    printf 'la aceptacion positiva NO esta acreditada (%s)\n' "$receipt_path" >&2
    forge_receipt_summary "$receipt_path" >&2 || true
    forge_contained_note_failed_receipt "$receipt_path"
    rm -rf "$workdir"
    [ "$rc" -ne 0 ] && return "$rc"
    return 70
  fi

  rm -rf "$workdir"
  return "$rc"
}

# forge_contained_note_failed_receipt <receipt-path>
#
# Records the receipt of a contained run that could not be certified. The
# evidence of a failed run is NEVER deleted: it is the only way to explain
# what happened.
forge_contained_note_failed_receipt() {
  local receipt="$1"
  [ -n "${FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE:-}" ] || return 0
  printf '%s\n' "$receipt" >> "$FORGE_CONTAINMENT_FAILED_RECEIPTS_FILE" 2>/dev/null || true
  return 0
}

# forge_contained_receipt_path [pointer-file]
#
# Prints the path of the receipt of the contained run whose pointer was
# published in <pointer-file> (default: $FORGE_CONTAINMENT_RECEIPT_OUT).
# It FAILS when the pointer is absent, empty or does not point to a receipt.
forge_contained_receipt_path() {
  local pointer="${1:-${FORGE_CONTAINMENT_RECEIPT_OUT:-}}" path=""
  [ -n "$pointer" ] || return 1
  [ -s "$pointer" ] || return 1
  IFS= read -r path < "$pointer" || path=""
  [ -n "$path" ] || return 1
  [ -s "$path" ] || return 1
  printf '%s\n' "$path"
  return 0
}

# forge_receipt_fields_are_unique <receipt>
#
# The UNIQUENESS of the fields is part of the validity of a receipt. A
# receipt that declares the SAME key twice carries CONTRADICTORY evidence:
# two declarations of the same fact that do not agree (or that agree, in
# which case one of them is redundant) can NOT be read by selecting the
# first one SILENTLY: the reader would be choosing which declaration counts.
#
# The gate is fail-closed: a duplicated field REJECTS the receipt, it is
# never repaired, never ignored and never resolved in favour of the first
# occurrence.
forge_receipt_fields_are_unique() {
  local receipt="$1" duplicates
  [ -f "$receipt" ] || return 1
  [ -r "$receipt" ] || return 1
  duplicates="$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      position = index($0, "=")
      key = substr($0, 1, position - 1)
      if (key in seen) { print key }
      seen[key] = 1
    }
  ' "$receipt" 2>/dev/null)" || duplicates=""
  if [ -n "$duplicates" ]; then
    printf 'el recibo declara campos DUPLICADOS (%s): la evidencia es contradictoria (%s)\n' \
      "$(printf '%s\n' "$duplicates" | tr '\n' ' ')" "$receipt" >&2
    return 1
  fi
  return 0
}

# forge_receipt_read <receipt> <key>
#
# Prints the value of <key> in the receipt. It FAILS when the receipt does
# not exist, cannot be read, has no such key, holds an empty value or
# DECLARES THAT KEY MORE THAN ONCE.
#
# The last case is the one that a naive reader gets wrong: it accepts the
# FIRST occurrence and stops reading, so a receipt that carries a second,
# CONTRADICTORY declaration of the same field is accepted on the strength of
# the first one. The duplicated declaration is REJECTED here instead.
forge_receipt_read() {
  local receipt="$1" key="$2" value occurrences
  if [ ! -f "$receipt" ]; then
    printf 'el recibo no existe (%s)\n' "$receipt" >&2
    return 1
  fi
  if [ ! -r "$receipt" ]; then
    printf 'el recibo no se puede leer (%s)\n' "$receipt" >&2
    return 1
  fi
  occurrences="$(awk -v key="$key" '
    index($0, key "=") == 1 { count++ }
    END { print count + 0 }
  ' "$receipt" 2>/dev/null)" || occurrences=""
  case "$occurrences" in
    '' | *[!0-9]*) occurrences=0 ;;
  esac
  if [ "$occurrences" -gt 1 ]; then
    printf 'el recibo declara el campo %s MAS DE UNA VEZ (%s): la evidencia es contradictoria\n' \
      "$key" "$receipt" >&2
    return 1
  fi
  value="$(awk -v key="$key" '
    index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
  ' "$receipt" 2>/dev/null)" || value=""
  if [ -z "$value" ]; then
    printf 'el recibo no contiene el campo %s (%s)\n' "$key" "$receipt" >&2
    return 1
  fi
  printf '%s\n' "$value"
  return 0
}

# The COMPLETE set of fields that a receipt must carry. A partial receipt is
# rejected: it cannot prove anything.
#
# CONTAINMENT_EVIDENCE_CERTIFIABLE is the RENAMED field: it certifies that
# the evidence of the CONTAINMENT is certifiable (the boundary was
# accredited and the contained environment was waited for). It does NOT
# imply that the scenario succeeded nor that the product cleaned up.
#
# EXPECTED_SCENARIO_RC and POSITIVE_ACCEPTANCE complete the contract: the
# positive acceptance requires, in addition, the expected RC of the scenario
# and PRODUCT_CLEANUP_RESULT=PASS observed before the defensive cleanup.
FORGE_RECEIPT_REQUIRED_FIELDS="
IDENTIFIER
RECEIPT_PATH
STARTED_UTC
ENDED_UTC
SCENARIO_ORDER_LITERAL
SCENARIO_TIMEOUT_SECONDS
CLOSURE_BUDGET_SECONDS
HOME_TEMP
XDG_CONFIG_HOME_TEMP
XDG_DATA_HOME_TEMP
XDG_CACHE_HOME_TEMP
XDG_STATE_HOME_TEMP
TMPDIR_TEMP
PID_NAMESPACE
MOUNT_NAMESPACE
PID1_INTERIOR
NSPID
PROCFS_TYPE
PROC_MOUNT_PRIVATE
ACCREDITATION
ACCREDITATION_REASON
SCENARIO_STATUS
SCENARIO_RC
INTERRUPTION_CAUSE
INTERRUPTION_FORWARDING
PRODUCT_CLEANUP_RESULT
PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP
DEFENSIVE_CLEANUP
EXPECTED_SCENARIO_RC
EXPECTED_TERMINATION
LAUNCHER_RC
LAUNCHER_WAIT_COMPLETED
PID1_COMPLETION_OBSERVED
CLOSURE
RECEIPT_COMPLETENESS
CONTAINMENT_EVIDENCE_CERTIFIABLE
POSITIVE_ACCEPTANCE
WRAPPER_EXIT_CODE
"

# The LEGACY key of the field that was renamed. There is NO alias: a receipt
# that carries it is evidence of the PREVIOUS contract and is not accepted.
FORGE_RECEIPT_LEGACY_CERTIFIABLE_KEY="CERTIFIABLE"

# forge_receipt_has_legacy_certifiable <receipt>
# Succeeds when the receipt carries the legacy key "CERTIFIABLE=". The key
# was renamed and it has no alias, so such a receipt belongs to the previous
# contract and a consumer of the current one must not accept it.
forge_receipt_has_legacy_certifiable() {
  local receipt="$1"
  [ -f "$receipt" ] || return 1
  [ -r "$receipt" ] || return 1
  grep -q "^${FORGE_RECEIPT_LEGACY_CERTIFIABLE_KEY}=" "$receipt" 2>/dev/null
}

# forge_receipt_containment_evidence <receipt>
#
# The gate of the EVIDENCE OF THE CONTAINMENT. It succeeds when the receipt
# certifies that:
#
#   * the boundary was accredited BY INVOCATION (ACCREDITATION=PASS),
#   * the launcher was reaped (LAUNCHER_WAIT_COMPLETED=YES),
#   * the launcher returned 0 (LAUNCHER_RC=0),
#   * the effective termination of the private PID 1 was OBSERVED
#     (PID1_COMPLETION_OBSERVED=PASS),
#   * the receipt is complete (RECEIPT_COMPLETENESS=COMPLETE),
#   * the contained environment was waited for (CLOSURE=CONFIRMED),
#   * the evidence of the containment is certifiable
#     (CONTAINMENT_EVIDENCE_CERTIFIABLE=YES).
#
# The three links of the closure are SEPARATE and ALL of them are required: a
# signal that was SENT is not an observed termination, and a launcher that was
# waited for but returned a non-zero RC did not close cleanly. A receipt that
# only carries "the signal was sent, and then it ended" does NOT certify the
# closure.
#
# It does NOT certify that the scenario succeeded nor that the product
# cleaned up: those are the POSITIVE ACCEPTANCE (see below).
#
# An absent, partial, illegible or contradictory receipt FAILS. There is no
# inference from a missing field and no "PASS by absence".
#
# The receipt is validated BEFORE any of its fields is believed: a receipt
# that declares a field more than once is CONTRADICTORY evidence and it is
# rejected as a whole, because a reader that accepted the first declaration
# would be choosing which statement counts.
forge_receipt_containment_evidence() {
  local receipt="$1" field value
  [ -f "$receipt" ] || return 1
  [ -r "$receipt" ] || return 1

  if ! forge_receipt_fields_are_unique "$receipt"; then
    return 1
  fi

  if forge_receipt_has_legacy_certifiable "$receipt"; then
    printf 'el recibo lleva la clave legacy %s= (contrato anterior): no se acepta como evidencia del contrato vigente\n' \
      "$FORGE_RECEIPT_LEGACY_CERTIFIABLE_KEY" >&2
    return 1
  fi

  for field in $FORGE_RECEIPT_REQUIRED_FIELDS; do
    forge_receipt_read "$receipt" "$field" >/dev/null 2>&1 || return 1
  done
  for field in ACCREDITATION RECEIPT_COMPLETENESS CLOSURE \
    CONTAINMENT_EVIDENCE_CERTIFIABLE LAUNCHER_WAIT_COMPLETED \
    LAUNCHER_RC PID1_COMPLETION_OBSERVED; do
    value="$(forge_receipt_read "$receipt" "$field")" || return 1
    case "$field:$value" in
      ACCREDITATION:PASS|RECEIPT_COMPLETENESS:COMPLETE|CLOSURE:CONFIRMED|\
CONTAINMENT_EVIDENCE_CERTIFIABLE:YES|LAUNCHER_WAIT_COMPLETED:YES|\
LAUNCHER_RC:0|PID1_COMPLETION_OBSERVED:PASS) ;;
      *)
        printf 'el recibo no certifica (%s=%s en %s)\n' "$field" "$value" "$receipt" >&2
        return 1
        ;;
    esac
  done

  # The INTERRUPTION, when there was one, must have been OBSERVED by the PID 1
  # of the namespace. The entry publishes the request OUTSIDE the frontier and
  # the PID 1 reads it and relays it to the bounded `timeout`; the receipt
  # records that observation in INTERRUPTION_FORWARDING. A receipt that
  # declares an interruption and does not prove that observation is
  # CONTRADICTORY evidence: it would be certifying a closure on the strength
  # of a signal that nobody observed being applied.
  local cause forwarding
  cause="$(forge_receipt_read "$receipt" INTERRUPTION_CAUSE 2>/dev/null || printf 'NONE')"
  forwarding="$(forge_receipt_read "$receipt" INTERRUPTION_FORWARDING 2>/dev/null || printf 'NOT_REQUESTED')"
  if [ "$cause" != "NONE" ] && [ "$forwarding" != "OBSERVED_BY_PID1" ]; then
    printf 'el recibo declara una interrupcion (%s) sin que el PID 1 la observara (%s)\n' \
      "$cause" "$forwarding" >&2
    return 1
  fi
  return 0
}

# forge_receipt_positive_acceptance <receipt>
#
# The gate of the POSITIVE ACCEPTANCE. It requires, in addition to the
# evidence of the containment:
#
#   * SCENARIO_RC == EXPECTED_SCENARIO_RC  (the scenario ended as expected),
#   * PRODUCT_CLEANUP_RESULT=PASS,
#   * PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=YES  (the result of
#     the product was observed BEFORE the defensive cleanup),
#   * POSITIVE_ACCEPTANCE=YES  (the receipt declares the same thing).
#
# The last check is a CROSS-CHECK: the consumer verifies the semantics of the
# receipt by itself and does not take the flag on trust. A receipt that
# declares POSITIVE_ACCEPTANCE=YES while its own fields contradict it is
# CONTRADICTORY evidence and is rejected.
forge_receipt_positive_acceptance() {
  local receipt="$1" scenario_rc expected_rc declared value

  forge_receipt_containment_evidence "$receipt" || return 1

  scenario_rc="$(forge_receipt_read "$receipt" SCENARIO_RC 2>/dev/null)" || return 1
  expected_rc="$(forge_receipt_read "$receipt" EXPECTED_SCENARIO_RC 2>/dev/null)" || return 1
  if [ "$scenario_rc" != "$expected_rc" ]; then
    printf 'el RC del escenario (%s) no es el RC esperado (%s): no hay aceptacion positiva\n' \
      "$scenario_rc" "$expected_rc" >&2
    return 1
  fi

  value="$(forge_receipt_product_cleanup "$receipt")"
  if [ "$value" != "PASS" ]; then
    printf 'la limpieza del producto no esta acreditada (%s): no hay aceptacion positiva\n' \
      "$value" >&2
    return 1
  fi

  declared="$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null)" || return 1
  if [ "$declared" != "YES" ]; then
    printf 'el recibo no declara aceptacion positiva (POSITIVE_ACCEPTANCE=%s)\n' "$declared" >&2
    return 1
  fi
  return 0
}

# forge_receipt_require <receipt>
#
# The single gate a consumer uses to accept the evidence of a contained run.
#
# It is the POSITIVE ACCEPTANCE gate: a consumer that certifies "cero
# procesos propios supervivientes" CANNOT accept
# CONTAINMENT_EVIDENCE_CERTIFIABLE=YES on its own. It must also check the
# expected RC of the scenario and PRODUCT_CLEANUP_RESULT=PASS observed before
# the defensive cleanup, because the containment closing correctly does NOT
# turn a failure of the product into a success.
#
# An absent, partial, illegible or contradictory receipt FAILS. There is no
# inference from a missing field and no "PASS by absence".
forge_receipt_require() {
  forge_receipt_positive_acceptance "$1"
}

# forge_receipt_product_cleanup <receipt>
#
# Prints PASS, FAIL or UNKNOWN: the result of the cleanup of the PRODUCT,
# observed BEFORE the defensive cleanup of the containment. UNKNOWN means
# "not observed" and is NEVER a PASS.
forge_receipt_product_cleanup() {
  local receipt="$1" value observed
  value="$(forge_receipt_read "$receipt" PRODUCT_CLEANUP_RESULT 2>/dev/null)" || value="UNKNOWN"
  observed="$(forge_receipt_read "$receipt" PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP 2>/dev/null)" || observed="NO"
  case "$value" in
    PASS|FAIL) : ;;
    *) value="UNKNOWN" ;;
  esac
  [ "$observed" = "YES" ] || value="UNKNOWN"
  printf '%s\n' "$value"
}

# forge_receipt_summary <receipt>
#
# Prints a summary that keeps the result of the PRODUCT and the DEFENSIVE
# result of the containment SEPARATED: a correct closure of the harness never
# converts a failure of the product into a PASS.
forge_receipt_summary() {
  local receipt="$1"
  printf 'recibo: %s\n' "$receipt"
  printf '  producto (limpieza observada antes de la defensiva): %s\n' \
    "$(forge_receipt_product_cleanup "$receipt")"
  printf '  contencion: acreditacion=%s cierre=%s completitud=%s evidencia_certificable=%s\n' \
    "$(forge_receipt_read "$receipt" ACCREDITATION 2>/dev/null || printf 'DESCONOCIDA')" \
    "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || printf 'DESCONOCIDO')" \
    "$(forge_receipt_read "$receipt" RECEIPT_COMPLETENESS 2>/dev/null || printf 'DESCONOCIDA')" \
    "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || printf 'DESCONOCIDO')"
  printf '  aceptacion positiva: declarada=%s rc=%s esperado=%s\n' \
    "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || printf 'DESCONOCIDA')" \
    "$(forge_receipt_read "$receipt" SCENARIO_RC 2>/dev/null || printf 'DESCONOCIDO')" \
    "$(forge_receipt_read "$receipt" EXPECTED_SCENARIO_RC 2>/dev/null || printf 'DESCONOCIDO')"
}

# forge_contained_scenario <home> [identities-registry]
#
# Writes the scenario script that runs a command inside the containment and
# declares the result of the cleanup of the PRODUCT.
#
# The declaration is made over the PRIVATE /proc of the containment: when the
# command returns, any live process that is not the scenario itself is a
# leftover of the product, and the marker records FAIL. The marker is written
# BEFORE the defensive cleanup of the containment, exactly as the contract of
# the entry requires.
#
# When an identities registry is given, the scenario TERMINATES the
# processes it holds before the observation, and it does it INSIDE the
# containment: a PID of a namespace is meaningless outside it. Every signal
# is bound to the identity, so a recycled PID is never signalled.
forge_contained_scenario() {
  local home="$1" registry="${2:-}"
  [ -n "$home" ] || return 1

  local script
  script="$(mktemp "${TMPDIR:-/tmp}/forge-contained-scenario.XXXXXX")" || return 1

  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# Generated by tests/isolation.sh. It runs the command inside the'
    printf '%s\n' '# containment and declares the cleanup of the product over the'
    printf '%s\n' '# PRIVATE /proc of the containment.'
    printf '%s\n' 'observer="$1"'
    printf '%s\n' 'killer="$2"'
    printf '%s\n' 'shift 2'
    if [ -n "$registry" ]; then
      printf '%s\n' 'registry="$1"'
      printf '%s\n' 'shift'
      printf '%s\n' '# The registry identifies the namespace it belongs to: an identity of'
      printf '%s\n' '# a namespace is meaningless outside it.'
      printf '%s\n' 'echo "NAMESPACE $(readlink /proc/self/ns/pid 2>/dev/null || echo UNKNOWN)" > "$registry"'
    else
      printf '%s\n' 'registry=""'
    fi
    printf '%s\n' 'rc=0'
    printf '%s\n' 'env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \'
    printf '  HOME=%s \\\n' "$(sh_quote "$home")"
    printf '  XDG_CONFIG_HOME=%s \\\n' "$(sh_quote "$home/.config")"
    printf '  XDG_CACHE_HOME=%s \\\n' "$(sh_quote "$home/.cache")"
    printf '  XDG_DATA_HOME=%s \\\n' "$(sh_quote "$home/.local/share")"
    printf '  XDG_STATE_HOME=%s \\\n' "$(sh_quote "$home/.local/state")"
    printf '  FORGE_OPENCODE_BIN_DIR=%s \\\n' "$(sh_quote "$home/.local/share/forge/opencode-v2")"
    printf '%s\n' '  "$@" || rc=$?'
    printf '%s\n' 'if [ -n "$registry" ] && [ -f "$killer" ]; then'
    # The OWNER of the containment is the scenario itself: the killer only
    # signals the identities that DESCEND from it, and it verifies the
    # identity of that owner before it signals anything.
    printf '%s\n' '  owner_ticks="$(sed -e "s/.*) //" "/proc/$$/stat" 2>/dev/null | awk "{ print \$20 }")"'
    printf '%s\n' '  /bin/sh "$killer" "$registry" TERM "$$" "$owner_ticks" >/dev/null 2>&1 || true'
    printf '%s\n' 'fi'
    printf '%s\n' 'leftovers_file="${TMPDIR:-/tmp}/forge-containment-leftovers.$$"'
    printf '%s\n' ': > "$leftovers_file"'
    # The observation of the cleanup is SATISFACTORY or it is NOTHING: a
    # missing observer, an observer that fails and an observer that could
    # not observe every process it enumerated all mean the SAME thing: the
    # inventory was NOT obtained. An inventory that was not obtained is
    # NEVER an empty inventory, and it is never a PASS.
    printf '%s\n' 'observation=NOT_OBSERVED'
    printf '%s\n' 'if [ -f "$observer" ]; then'
    printf '%s\n' '  observer_rc=0'
    printf '%s\n' '  /bin/sh "$observer" "$$" > "$leftovers_file" 2>"$leftovers_file.err" || observer_rc=$?'
    printf '%s\n' '  if [ "$observer_rc" -eq 0 ]; then'
    printf '%s\n' '    observation=COMPLETE'
    printf '%s\n' '  else'
    printf '%s\n' '    observation=INCOMPLETE'
    printf '%s\n' '  fi'
    printf '%s\n' 'else'
    printf '%s\n' '  observation=MISSING'
    printf '%s\n' 'fi'
    printf '%s\n' 'leftovers=0'
    printf '%s\n' 'while IFS= read -r leftover; do'
    printf '%s\n' '  [ -n "$leftover" ] || continue'
    printf '%s\n' '  leftovers=$((leftovers + 1))'
    printf '%s\n' 'done < "$leftovers_file"'
    printf '%s\n' 'rm -f "$leftovers_file" "$leftovers_file.err"'
    printf '%s\n' 'if [ -n "${FORGE_PRODUCT_CLEANUP_RESULT_FILE:-}" ]; then'
    printf '%s\n' '  if [ "$observation" != COMPLETE ]; then'
    printf '%s\n' '    echo UNKNOWN > "$FORGE_PRODUCT_CLEANUP_RESULT_FILE"'
    printf '%s\n' '  elif [ "$leftovers" -eq 0 ]; then'
    printf '%s\n' '    echo PASS > "$FORGE_PRODUCT_CLEANUP_RESULT_FILE"'
    printf '%s\n' '  else'
    printf '%s\n' '    echo FAIL > "$FORGE_PRODUCT_CLEANUP_RESULT_FILE"'
    printf '%s\n' '  fi'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit "$rc"'
  } > "$script"

  chmod +x "$script"
  printf '%s\n' "$script"
  return 0
}

# forge_isolated_env <home> <command> [args...]
#
# Runs a command with the real user environment neutralised AND inside the
# containment:
#
#   * HOME points to the sandbox,
#   * XDG_CONFIG_HOME / XDG_CACHE_HOME / XDG_DATA_HOME / XDG_STATE_HOME point
#     inside the sandbox,
#   * FORGE_OPENCODE_BIN_DIR points inside the sandbox, so the pinned
#     OpenCode prefix can never be installed in the real
#     ~/.local/share/forge/opencode-v2,
#   * OPENCODE_CONFIG_DIR / OPENCODE_CONFIG are removed, because the overlay
#     installer gives them precedence over HOME,
#   * the whole scenario runs inside a private PID namespace with a private
#     /proc, so the processes the product creates (the supervisor of the
#     launcher, the Popen of plugin-sync.py) are contained WITHOUT touching
#     their code.
#
# The stdout and the stderr of the command are the stdout and the stderr of
# this function: the entry publishes its receipt in a file, never in the
# standard output, so a captured output is never polluted.
forge_isolated_env() {
  local home="$1"
  shift
  [ "$#" -gt 0 ] || return 1

  mkdir -p "$home/.config" "$home/.cache" \
    "$home/.local/share" "$home/.local/state" || return 1

  local script
  script="$(forge_contained_scenario "$home")" || return 1

  local rc=0
  forge_contained_run "$script" "$@" || rc=$?
  rm -f "$script"
  return "$rc"
}

# forge_isolated_env_with_registry <home> <identities-registry> <command> [args...]
#
# Exactly like forge_isolated_env, but the scenario TERMINATES the processes
# whose identity the registry holds before it declares the cleanup of the
# product. The termination happens INSIDE the containment, because a PID of
# a namespace is meaningless outside it.
forge_isolated_env_with_registry() {
  local home="$1" registry="$2"
  shift 2
  [ "$#" -gt 0 ] || return 1
  [ -n "$registry" ] || return 1

  mkdir -p "$home/.config" "$home/.cache" \
    "$home/.local/share" "$home/.local/state" || return 1

  local script
  script="$(forge_contained_scenario "$home" "$registry")" || return 1

  local rc=0
  forge_contained_run "$script" "$registry" "$@" || rc=$?
  rm -f "$script"
  return "$rc"
}
