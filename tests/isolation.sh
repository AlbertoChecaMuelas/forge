#!/usr/bin/env bash
# tests/isolation.sh — shared helpers for the Forge test suites.
#
# Sourced by the suites that invoke the Forge installers. It is NOT a test
# suite on its own (the name does not match the `*_unit.sh` / `*_integration.sh`
# patterns collected by tests/run-all.sh).
#
# It provides three things:
#
#   1. forge_isolated_env — runs a command with the real user environment
#      neutralised. HOME, the XDG directories and the Forge-owned OpenCode
#      prefix are redirected into the sandbox and the OpenCode config
#      overrides are removed. Without this isolation the installer resolves
#      the pinned OpenCode prefix from the ambient XDG_DATA_HOME and installs
#      @opencode/cli@2.1.4 in the REAL `~/.local/share/forge/opencode-v2`.
#
#   2. forge_protected_snapshot / forge_assert_protected_unchanged — a
#      fingerprint of the real user files that the suites must never touch,
#      taken before the suite runs and compared when it finishes.
#
#   3. forge_make_toolchain — a fake npm/opencode toolchain so the suites
#      never download anything and never run a real installation.
#
# Compatible with bash 3.2+.

# ---------------------------------------------------------------------------
# The real user home. It is captured when the helper is sourced, BEFORE any
# test runs: the suites themselves execute with the real HOME, so the
# fingerprint must be taken against it.
# ---------------------------------------------------------------------------
FORGE_TEST_REAL_HOME="${FORGE_TEST_REAL_HOME:-$HOME}"

# ---------------------------------------------------------------------------
# Real user paths that must stay untouched, with the fingerprint policy:
#
#   deep    — the whole tree is hashed (names, sizes and content hashes).
#   shallow — only the first level is hashed. The OpenCode data directory
#             holds a live database that the running session writes to, so a
#             deep hash would report a false positive.
#   file    — a single regular file, hashed by content.
#
# `~/.local/share/forge` is the prefix that owns the pinned OpenCode build:
# it must never be created by a test run.
# ---------------------------------------------------------------------------
FORGE_TEST_PROTECTED_PATHS="
.config/opencode-forge:deep
.forge-state.json:file
.local/share/opencode:shallow
.local/state/opencode:shallow
.opencode-tokens:file
.local/share/omarchy:deep
.local/share/forge:deep
"

# Maximum size of a file whose CONTENT is hashed. Bigger files (the OpenCode
# database) only contribute their size, so a live database does not turn the
# fingerprint into a false positive.
FORGE_TEST_HASH_MAX_BYTES=1048576

# forge_protected_snapshot [base]
# Fingerprint of every protected path of the real user home. One line per
# path: "<relative path>\t<fingerprint>".
forge_protected_snapshot() {
  local base="${1:-$FORGE_TEST_REAL_HOME}"

  python3 - "$base" "$FORGE_TEST_PROTECTED_PATHS" "$FORGE_TEST_HASH_MAX_BYTES" <<'PY'
import hashlib
import os
import sys

base = sys.argv[1]
spec = sys.argv[2]
max_bytes = int(sys.argv[3])


# The SQLite companions of the live OpenCode database change while the
# session runs (the WAL grows, the shared memory index is rewritten): their
# content must never take part in the fingerprint.
LIVE_FILE_PREFIXES = ("opencode.db",)


def file_fingerprint(path, name):
    if any(name.startswith(prefix) for prefix in LIVE_FILE_PREFIXES):
        return "live"
    try:
        size = os.path.getsize(path)
    except OSError:
        return "unreadable"
    if size > max_bytes:
        # Volatile file: neither its size nor its content may take part in
        # the fingerprint, or the guard would report a false positive.
        return "big"
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError:
        return "unreadable"
    return "sha256:%s" % digest.hexdigest()


def tree_fingerprint(root, deep):
    digest = hashlib.sha256()
    if deep:
        walker = os.walk(root)
    else:
        walker = [(root, [], os.listdir(root))]
    for dirpath, dirnames, filenames in walker:
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            if os.path.islink(full):
                digest.update(("L\t%s\t%s\n" % (rel, os.readlink(full))).encode())
            else:
                digest.update(("F\t%s\t%s\n" % (rel, file_fingerprint(full, name))).encode())
        for name in sorted(dirnames):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root)
            kind = "L" if os.path.islink(full) else "D"
            digest.update(("%s\t%s\n" % (kind, rel)).encode())
    return "tree:%s" % digest.hexdigest()


def fingerprint(path, policy):
    if os.path.islink(path):
        return "link:%s" % os.readlink(path)
    if os.path.isfile(path):
        return file_fingerprint(path, os.path.basename(path))
    if os.path.isdir(path):
        return tree_fingerprint(path, policy == "deep")
    return "absent"


for entry in spec.split():
    rel, _, policy = entry.partition(":")
    path = os.path.join(base, rel)
    sys.stdout.write("%s\t%s\n" % (rel, fingerprint(path, policy)))
PY
}

# forge_assert_protected_unchanged <before-snapshot> [base]
# Compares the protected paths with the snapshot taken before the suite ran.
# Returns 0 when nothing changed, 1 (with an explicit diagnostic) otherwise.
forge_assert_protected_unchanged() {
  local before="$1" base="${2:-$FORGE_TEST_REAL_HOME}" after rel before_fp after_fp

  after="$(forge_protected_snapshot "$base")"

  if [ "$before" = "$after" ]; then
    return 0
  fi

  while IFS=$'\t' read -r rel before_fp; do
    [ -n "$rel" ] || continue
    after_fp="$(printf '%s\n' "$after" | awk -F'\t' -v key="$rel" '$1 == key { print $2; exit }')"
    if [ "$before_fp" != "$after_fp" ]; then
      printf '  FAIL  la suite toco un fichero real del usuario: %s (antes=%s despues=%s)\n' \
        "$rel" "$before_fp" "$after_fp" >&2
    fi
  done <<EOF
$(printf '%s\n' "$before")
EOF

  return 1
}

# forge_assert_no_forge_prefix [base]
# The pinned OpenCode prefix of the real user must never be created by a
# test run. It is the exact directory where the leak happened.
forge_assert_no_forge_prefix() {
  local base="${1:-$FORGE_TEST_REAL_HOME}"
  local prefix="$base/.local/share/forge"

  if [ -e "$prefix" ]; then
    printf '  FAIL  la suite instalo el prefijo real de OpenCode: %s\n' "$prefix" >&2
    return 1
  fi

  return 0
}

# forge_isolated_env <home> <command> [args...]
# Runs a command with the real user environment neutralised:
#
#   * HOME points to the sandbox,
#   * XDG_CONFIG_HOME / XDG_CACHE_HOME / XDG_DATA_HOME / XDG_STATE_HOME point
#     inside the sandbox,
#   * FORGE_OPENCODE_BIN_DIR points inside the sandbox, so the pinned
#     @opencode/cli@2.1.4 build can never be installed in the real
#     ~/.local/share/forge/opencode-v2,
#   * OPENCODE_CONFIG_DIR / OPENCODE_CONFIG are removed, because the overlay
#     installer gives them precedence over HOME.
forge_isolated_env() {
  local home="$1"
  shift

  mkdir -p "$home/.config" "$home/.cache" \
    "$home/.local/share" "$home/.local/state"

  env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    FORGE_OPENCODE_BIN_DIR="$home/.local/share/forge/opencode-v2" \
    "$@"
}

# forge_make_toolchain <dir>
# Creates the fake toolchain used by the suites:
#
#   npm      — materialises the pinned OpenCode build layout instead of
#              downloading @opencode/cli@2.1.4. The suite never touches the
#              network and never installs anything.
#   opencode — a stand-in for the OpenCode CLI that reports the pinned
#              version and the OpenCode 2 auth JSON contract.
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
#   <dir>/node_modules/.bin/opencode
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

mkdir -p "$prefix/node_modules/.bin"

cat > "$prefix/node_modules/.bin/opencode" <<'OPENCODE_EOF'
#!/usr/bin/env sh
# Fake pinned OpenCode build used by the Forge test suites.
case "${1:-}" in
  --version)
    printf 'opencodev2.1.4\n'
    ;;
  auth)
    printf '[{"id":"openai","name":"openai","type":"api"}]\n'
    ;;
  *)
    printf 'ARGV=%s\n' "$*"
    printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-}"
    printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}"
    if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "${OPENCODE_CONFIG:-}" ]; then
      printf '%s\n' '--- CONFIG ---'
      cat "${OPENCODE_CONFIG}"
    fi
    ;;
esac
OPENCODE_EOF

chmod +x "$prefix/node_modules/.bin/opencode"
exit 0
NPM_EOF
    chmod +x "$dir/npm"
  fi

  if [ ! -e "$dir/opencode" ]; then
    cat > "$dir/opencode" <<'OPENCODE_EOF'
#!/usr/bin/env sh
# Fake OpenCode CLI used by the Forge test suites.
case "${1:-}" in
  --version)
    printf 'opencodev2.1.4\n'
    ;;
  auth)
    printf '[{"id":"openai","name":"openai","type":"api"}]\n'
    ;;
  *)
    printf 'ARGV=%s\n' "$*"
    printf 'OPENCODE_CONFIG_DIR=%s\n' "${OPENCODE_CONFIG_DIR:-}"
    printf 'OPENCODE_CONFIG=%s\n' "${OPENCODE_CONFIG:-}"
    if [ -n "${OPENCODE_CONFIG:-}" ] && [ -f "${OPENCODE_CONFIG:-}" ]; then
      printf '%s\n' '--- CONFIG ---'
      cat "${OPENCODE_CONFIG}"
    fi
    ;;
esac
OPENCODE_EOF
    chmod +x "$dir/opencode"
  fi
}
