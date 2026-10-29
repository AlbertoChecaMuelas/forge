#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/execute_plan_command_only_unit.sh — Fixture of the selective
# distribution mode of the overlay installer:
#
#   bash open-code/install-opencode.sh --command-only execute-plan
#
# The fixture runs the REAL installer with a throw-away HOME and XDG
# directories. It proves that:
#
#   - the valid invocation changes ONLY open-code/commands/execute-plan.md,
#     byte for byte, with the permissions of the destination preserved;
#   - every other entry of the tree is untouched (path, mode, size, mtime
#     and content hash);
#   - the rejected invocations (wrong name, path, extra argument, missing
#     name, symbolic-link destination, missing destination) fail with a non
#     zero code and leave the tree IDENTICAL;
#   - the COMPLETE argument vector is validated BEFORE any effect: an
#     invalid invocation never prompts for credentials, never runs the
#     generator of the agents and never invokes npm;
#   - the physical destination is validated resolving the symbolic links of
#     ALL its ancestors, and a symbolic ancestor is rejected BEFORE the
#     temporary file is created;
#   - no API key is requested, the pinned binary installer is never invoked
#     and the Forge prefix is never created.
#
# The installer under test is a COPY of the repository: the full installer
# GENERATES the agent files of the repository, so a test that reached that
# point would modify the repository of the user. The repository is never
# written by this suite, not even when the installer is broken.
#
# The real installation (~/.config/opencode-forge) is never written: the
# suite takes a fingerprint of it before and after and compares them.
#
# Compatible with bash 3.2+.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"

INSTALLER="$FORGE_ROOT/open-code/install-opencode.sh"
COMMAND_SOURCE="$FORGE_ROOT/open-code/commands/execute-plan.md"

# Optional mutation applied to the COPY of the installer inside the sandbox.
FORGE_TEST_INSTALLER_MUTATION="${FORGE_TEST_INSTALLER_MUTATION:-}"

FAIL=0
PASS=0

TMPDIR_BASE="$FORGE_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

WORKDIR=""
REAL_OVERLAY="${FORGE_TEST_REAL_HOME:-$HOME}/.config/opencode-forge"

cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
  rm -rf "$TMPDIR_BASE"/command-only-$$-* 2>/dev/null || true
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

run_test() {
  local name="$1"
  echo "--- $name"
  "$name"
}

# ---------------------------------------------------------------------------
# Tree fingerprints.
#
# snapshot_tree <root> <out> — one line per regular file and symbolic link:
#   F <path> <mode> <size> <mtime> <sha256>
#   L <path> <mode> <link-target>
# snapshot_dirs <root> <out> — the set of directories.
# ---------------------------------------------------------------------------
snapshot_tree() {
  local root="$1" out="$2"
  (
    cd "$root" || exit 1
    find . -mindepth 1 \( -type f -o -type l \) -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' path; do
          mode="$(stat -c '%a' "$path")"
          if [ -L "$path" ]; then
            printf 'L %s %s %s\n' "$path" "$mode" "$(readlink "$path")"
          else
            printf 'F %s %s %s %s %s\n' \
              "$path" "$mode" "$(stat -c '%s' "$path")" \
              "$(stat -c '%y' "$path")" "$(sha256sum "$path" | cut -d' ' -f1)"
          fi
        done
  ) > "$out"
}

snapshot_dirs() {
  local root="$1" out="$2"
  (
    cd "$root" || exit 1
    find . -mindepth 1 -type d -printf '%p\n' | LC_ALL=C sort
  ) > "$out"
}

# snapshot_shallow <root> <out> — the first level only, without recursion and
# without content hashing. The real overlay holds a node_modules tree that
# must not be walked: the deep fingerprint is limited to the commands
# directory, which is the only thing the installer may touch.
snapshot_shallow() {
  local root="$1" out="$2"
  (
    cd "$root" || exit 1
    find . -maxdepth 1 -mindepth 1 -printf '%y %m %s %T@ %p\n' | LC_ALL=C sort
  ) > "$out"
}

# tree_without <snapshot> <relative-path> — the fingerprint minus one entry.
tree_without() {
  awk -v target="$2" '$2 != target' "$1"
}

# ---------------------------------------------------------------------------
# Sandbox: a fake Forge overlay inside a throw-away HOME, plus a disposable
# COPY of the repository that provides the installer under test.
# ---------------------------------------------------------------------------

# make_repo_fixture <destination>
#
# The full installer GENERATES the agent files of the repository it belongs
# to. If the argument validation were broken, the full installer would run
# and it would write into the repository of the user. The installer under
# test is therefore always a COPY inside the sandbox, and the generator
# writes (if ever) into that copy.
make_repo_fixture() {
  local destination="$1"

  mkdir -p "$destination"
  cp -a "$FORGE_ROOT/open-code" "$destination/open-code"
  cp -a "$FORGE_ROOT/shared" "$destination/shared"
  printf '%s' "$destination"
}

make_sandbox() {
  local sandbox="$1"
  local home="$sandbox/home"
  mkdir -p "$home/.config/opencode-forge/commands" \
    "$home/.config/opencode-forge/agents" \
    "$home/.cache" \
    "$home/.local/share" \
    "$home/.local/state"

  printf -- 'stale execute-plan content\n' \
    > "$home/.config/opencode-forge/commands/execute-plan.md"
  chmod 0644 "$home/.config/opencode-forge/commands/execute-plan.md"
  printf -- 'stale review content\n' \
    > "$home/.config/opencode-forge/commands/review.md"
  printf -- 'stale agent content\n' \
    > "$home/.config/opencode-forge/agents/orchestrator.md"
  printf -- '{ "stale": true }\n' \
    > "$home/.config/opencode-forge/opencode.jsonc"

  # The disposable copy of the repository: the installer under test and the
  # generator of the agents write (if ever) HERE, never in the repository.
  SANDBOX_HOME="$home"
  SANDBOX_REPO="$sandbox/repo"
  SANDBOX_INSTALLER="$SANDBOX_REPO/open-code/install-opencode.sh"
  SANDBOX_COMMAND_SOURCE="$SANDBOX_REPO/open-code/commands/execute-plan.md"
  make_repo_fixture "$SANDBOX_REPO" > /dev/null

  # The fingerprint of the files that the generator of the agents writes.
  snapshot_tree "$SANDBOX_REPO/open-code/agents" "$sandbox/agents.before.txt"

  if ! apply_installer_mutation "$SANDBOX_INSTALLER" "$FORGE_TEST_INSTALLER_MUTATION"; then
    echo "  FAIL: the mutation '$FORGE_TEST_INSTALLER_MUTATION' could not be applied" >&2
    exit 1
  fi

  # A fake npm that records any invocation: the selective mode must never
  # reach the installer of the pinned binary.
  mkdir -p "$sandbox/fakebin"
  cat > "$sandbox/fakebin/npm" <<EOF
#!/usr/bin/env sh
printf 'npm was invoked: %s\n' "\$*" > "$sandbox/npm-was-invoked"
exit 0
EOF
  chmod +x "$sandbox/fakebin/npm"
}

# ---------------------------------------------------------------------------
# apply_installer_mutation <installer copy> <mutation>
#
# The mutation is applied to the COPY inside the sandbox: the repository is
# never modified.
#
# drop-command-only-position-check: the restricted mode accepts an argument
# vector whose FIRST argument is not the flag itself.
#
# drop-command-only-count-check: the restricted mode accepts an argument
# vector with a number of arguments that is not the documented one.
#
# drop-full-args-check: the full installer accepts arguments.
#
# drop-unknown-option-check: the full installer accepts an unknown option.
#
# drop-symbolic-ancestor-check: the destination is not validated against a
# symbolic ancestor (neither by the resolution of the path nor by the
# inspection of its components: the two clauses overlap, so a single
# mutation has to break both of them).
# ---------------------------------------------------------------------------
apply_installer_mutation() {
  local installer="$1" mutation="$2"
  case "$mutation" in
    "") return 0 ;;
    drop-command-only-position-check)
      python3 - "$installer" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = '  if [[ "${1-}" != "--command-only" ]]; then\n'
mutated = '  if false; then\n'
if text.count(anchor) != 1:
    sys.stderr.write("mutation anchor not found in the installer copy\n")
    raise SystemExit(2)
text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-command-only-count-check)
      python3 - "$installer" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = '  if (($# != 2)); then\n'
mutated = '  if false; then\n'
if text.count(anchor) != 1:
    sys.stderr.write("mutation anchor not found in the installer copy\n")
    raise SystemExit(2)
text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-restricted-argument-checks)
      python3 - "$installer" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

# BOTH clauses of the validation of the restricted mode are disabled: the
# flag must be the first argument AND the vector must have the documented
# length. The two clauses overlap, so a single mutation has to break both of
# them to make the validation observable.
pairs = (
    (
        '  if [[ "${1-}" != "--command-only" ]]; then\n',
        '  if false; then\n',
    ),
    (
        '  if (($# != 2)); then\n',
        '  if false; then\n',
    ),
)
for anchor, mutated in pairs:
    if text.count(anchor) != 1:
        sys.stderr.write("mutation anchor not found in the installer copy\n")
        raise SystemExit(2)
    text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-full-args-check)
      python3 - "$installer" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = 'if (($# != 0)); then\n'
mutated = 'if false; then\n'
if text.count(anchor) != 1:
    sys.stderr.write("mutation anchor not found in the installer copy\n")
    raise SystemExit(2)
text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-unknown-option-check)
      python3 - "$installer" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = '    --*)\n      command_only_error "unrecognized installer option \'$installer_arg\'"\n      ;;\n'
mutated = '    --*)\n      ;;\n'
if text.count(anchor) != 1:
    sys.stderr.write("mutation anchor not found in the installer copy\n")
    raise SystemExit(2)
text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-symbolic-ancestor-check)
      python3 - "$installer" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

pairs = (
    (
        '    if os.path.realpath(supplied) != path:\n',
        '    if False:\n',
    ),
    (
        '        if os.path.islink(current):\n'
        '            fail("destination path or one of its ancestors is a symbolic link")\n',
        '        if False:\n'
        '            fail("destination path or one of its ancestors is a symbolic link")\n',
    ),
)
for anchor, mutated in pairs:
    if text.count(anchor) != 1:
        sys.stderr.write("mutation anchor not found in the installer copy\n")
        raise SystemExit(2)
    text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    *)
      echo "unknown mutation: $mutation" >&2
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# The PTY probe: the installer only prompts for credentials when its stdin
# is a TERMINAL. A rejection that happens BEFORE the prompt is therefore
# observed with a terminal attached: if the installer blocked on the prompt,
# the probe would have to kill it, and that is a failure, not a timeout.
#
# The probe writes the merged output of the run and two markers:
#   PTY_RC=<code>          the exit code of the installer
#   PTY_TIMED_OUT=YES|NO  YES when the installer had to be killed
# ---------------------------------------------------------------------------
write_pty_probe() {
  local probe="$1"
  cat > "$probe" <<'PTY_EOF'
#!/usr/bin/env python3
"""Run a command with a TERMINAL as stdin and report whether it terminated.

The probe never reads the terminal: the installer is expected to reject the
invocation BEFORE it prompts, so a run that blocks is a failure that the
probe reports as PTY_TIMED_OUT=YES.
"""
import os
import pty
import subprocess
import sys

argv = sys.argv[1:]
if not argv:
    sys.stderr.write("usage: pty_probe.py <command> [args...]\n")
    raise SystemExit(64)

master, slave = pty.openpty()
proc = None
timed_out = False
try:
    proc = subprocess.Popen(
        argv, stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    os.close(slave)
    slave = None
    try:
        output, _ = proc.communicate(timeout=30)
    except subprocess.TimeoutExpired:
        timed_out = True
        proc.kill()
        output, _ = proc.communicate()
finally:
    if slave is not None:
        os.close(slave)
    os.close(master)

sys.stdout.buffer.write(output)
sys.stdout.flush()
sys.stderr.write(
    "\nPTY_RC=%s\nPTY_TIMED_OUT=%s\n" % (proc.returncode, "YES" if timed_out else "NO")
)
raise SystemExit(124 if timed_out else 0)
PTY_EOF
  chmod +x "$probe"
}

# ---------------------------------------------------------------------------
# run_install <sandbox> [args...] — runs the installer against the sandbox.
# ---------------------------------------------------------------------------
run_install() {
  local sandbox="$1"
  shift
  local home="$sandbox/home"
  env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    FORGE_OPENCODE_BIN_DIR="$home/.local/share/forge/opencode-v2" \
    PATH="$sandbox/fakebin:$PATH" \
    bash "$SANDBOX_INSTALLER" "$@" \
    > "$sandbox/stdout.txt" 2> "$sandbox/stderr.txt"
}

# run_install_with_terminal <sandbox> [args...]
#
# The same invocation with a TERMINAL as stdin, so the credential prompt
# would be VISIBLE (and would block) if the installer reached it.
run_install_with_terminal() {
  local sandbox="$1"
  shift
  local home="$sandbox/home"
  env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    FORGE_OPENCODE_BIN_DIR="$home/.local/share/forge/opencode-v2" \
    PATH="$sandbox/fakebin:$PATH" \
    "$WORKDIR/pty_probe.py" \
    bash "$SANDBOX_INSTALLER" "$@" \
    > "$sandbox/pty.out" 2> "$sandbox/pty.err" || true
}

# assert_no_key_signals <sandbox> <label>
assert_no_key_signals() {
  local sandbox="$1" label="$2"
  local signal
  local -a signals=(
    'api key'
    'api-key'
    'apikey'
    'provider'
    'npm install'
    '@opencode/cli'
    'openai_api_key'
    'anthropic'
    'authentication'
    'autentic'
  )
  local found=no
  for signal in "${signals[@]}"; do
    if grep -qiF "$signal" "$sandbox/stdout.txt" "$sandbox/stderr.txt" 2>/dev/null; then
      echo "      signal found: $signal"
      found=yes
    fi
  done
  if [ "$found" = no ]; then
    pass "$label: no API key or provider signal in the output"
  else
    fail "$label: the output asks for an API key or mentions a provider"
  fi
}

assert_no_prefix() {
  local sandbox="$1" label="$2"
  if [ ! -e "$sandbox/home/.local/share/forge" ]; then
    pass "$label: the Forge prefix was not created"
  else
    fail "$label: the Forge prefix was created"
  fi
}

assert_no_npm() {
  local sandbox="$1" label="$2"
  if [ ! -e "$sandbox/npm-was-invoked" ]; then
    pass "$label: the pinned binary installer was never invoked"
  else
    fail "$label: the pinned binary installer was invoked"
  fi
}

# assert_no_credential_prompt <sandbox> <label>
#
# The run with a TERMINAL attached is the observable one: the installer only
# prompts for credentials when its stdin is a terminal, so a prompt that
# never appears there never appeared at all. A run that had to be killed
# means the installer BLOCKED on the prompt.
assert_no_credential_prompt() {
  local sandbox="$1" label="$2"
  local found=no

  if grep -qF "PTY_TIMED_OUT=YES" "$sandbox/pty.err"; then
    fail "$label: the installer BLOCKED on the credential prompt"
    return
  fi
  if grep -qF "PTY_TIMED_OUT=NO" "$sandbox/pty.err"; then
    pass "$label: the installer terminated without blocking on a prompt"
  else
    fail "$label: the terminal probe did not complete"
    return
  fi

  local signal
  for signal in 'Deseas configurar API keys' 'API key' 'Opcion:' 'Opción:'; do
    if grep -qiF "$signal" "$sandbox/pty.out" 2>/dev/null; then
      echo "      prompt signal found: $signal"
      found=yes
    fi
  done
  if [ "$found" = no ]; then
    pass "$label: no credential prompt with a terminal attached"
  else
    fail "$label: the installer prompted for credentials"
  fi
}

# assert_generator_not_run <sandbox> <label>
#
# The generator of the agents writes the agent files of the repository. Its
# execution is observed through the fingerprint of those files inside the
# disposable copy of the repository.
assert_generator_not_run() {
  local sandbox="$1" label="$2"

  snapshot_tree "$SANDBOX_REPO/open-code/agents" "$sandbox/agents.after.txt"
  if diff -u "$sandbox/agents.before.txt" "$sandbox/agents.after.txt" \
    > "$sandbox/agents.diff" 2>&1; then
    pass "$label: the generator of the agents never ran"
  else
    fail "$label: the generator of the agents ran"
    sed -n '1,20p' "$sandbox/agents.diff" | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

test_valid_invocation_updates_only_the_allowed_command() {
  local sandbox="$WORKDIR/valid"
  make_sandbox "$sandbox"
  local home="$SANDBOX_HOME"
  local dest="$home/.config/opencode-forge/commands/execute-plan.md"
  local rel="./.config/opencode-forge/commands/execute-plan.md"

  snapshot_tree "$home" "$sandbox/before.txt"
  snapshot_dirs "$home" "$sandbox/before.dirs"

  local rc=0
  run_install "$sandbox" --command-only execute-plan || rc=$?

  snapshot_tree "$home" "$sandbox/after.txt"
  snapshot_dirs "$home" "$sandbox/after.dirs"

  if [ "$rc" -eq 0 ]; then
    pass "valid: rc 0"
  else
    fail "valid: expected rc 0, got $rc"
    sed -n '1,10p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if cmp -s "$COMMAND_SOURCE" "$SANDBOX_COMMAND_SOURCE"; then
    pass "valid: the copy of the command source is faithful to the repository"
  else
    fail "valid: the copy of the command source differs from the repository"
  fi

  if cmp -s "$SANDBOX_COMMAND_SOURCE" "$dest"; then
    pass "valid: the destination is byte identical to the source (cmp)"
  else
    fail "valid: the destination differs from the source"
  fi

  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    pass "valid: the destination is still a regular file"
  else
    fail "valid: the destination is not a regular file"
  fi

  if [ "$(stat -c '%a' "$dest")" = "644" ]; then
    pass "valid: the permissions of the destination are preserved"
  else
    fail "valid: the permissions changed ($(stat -c '%a' "$dest"))"
  fi

  if diff -u <(tree_without "$sandbox/before.txt" "$rel") \
    <(tree_without "$sandbox/after.txt" "$rel") > "$sandbox/others.diff" 2>&1; then
    pass "valid: every other file is untouched (path, mode, size, mtime, hash)"
  else
    fail "valid: some other file changed"
    sed -n '1,20p' "$sandbox/others.diff" | sed 's/^/      /' >&2
  fi

  if diff -u "$sandbox/before.dirs" "$sandbox/after.dirs" > "$sandbox/dirs.diff" 2>&1; then
    pass "valid: no directory was added or removed"
  else
    fail "valid: the directory set changed"
    sed -n '1,20p' "$sandbox/dirs.diff" | sed 's/^/      /' >&2
  fi

  local leftovers
  leftovers="$(find "$home/.config/opencode-forge/commands" -name '.execute-plan.md.tmp.*' -print)"
  if [ -z "$leftovers" ]; then
    pass "valid: no temporary file was left behind"
  else
    fail "valid: a temporary file survived the run: $leftovers"
  fi

  assert_no_npm "$sandbox" "valid"
  assert_no_prefix "$sandbox" "valid"
  assert_no_key_signals "$sandbox" "valid"
}

# assert_rejected <label> <expected-message> [args...]
assert_rejected() {
  local label="$1" message="$2"
  shift 2
  local sandbox="$WORKDIR/rejected-$label"
  make_sandbox "$sandbox"
  local home="$SANDBOX_HOME"

  # The terminal run comes FIRST: if the installer blocked on the prompt it
  # would be killed here, and its effects (if any) would be inside the
  # compared window below.
  run_install_with_terminal "$sandbox" "$@"

  snapshot_tree "$home" "$sandbox/before.txt"
  snapshot_dirs "$home" "$sandbox/before.dirs"

  local rc=0
  run_install "$sandbox" "$@" || rc=$?

  snapshot_tree "$home" "$sandbox/after.txt"
  snapshot_dirs "$home" "$sandbox/after.dirs"

  if [ "$rc" -ne 0 ]; then
    pass "$label: rc != 0 (got $rc)"
  else
    fail "$label: expected rc != 0, got 0"
  fi

  if grep -qF "$message" "$sandbox/stderr.txt"; then
    pass "$label: the diagnostic explains the rejection"
  else
    fail "$label: the diagnostic does not explain the rejection"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if diff -u "$sandbox/before.txt" "$sandbox/after.txt" > "$sandbox/tree.diff" 2>&1; then
    pass "$label: the tree is identical before and after"
  else
    fail "$label: the tree changed"
    sed -n '1,20p' "$sandbox/tree.diff" | sed 's/^/      /' >&2
  fi

  if diff -u "$sandbox/before.dirs" "$sandbox/after.dirs" > "$sandbox/dirs.diff" 2>&1; then
    pass "$label: the directory set is identical before and after"
  else
    fail "$label: the directory set changed"
  fi

  assert_no_npm "$sandbox" "$label"
  assert_no_prefix "$sandbox" "$label"
  assert_no_key_signals "$sandbox" "$label"
  assert_no_credential_prompt "$sandbox" "$label"
  assert_generator_not_run "$sandbox" "$label"
}

test_rejected_unsupported_command_name() {
  assert_rejected "unsupported-name" "only 'execute-plan' is allowed" \
    --command-only review
}

# ---------------------------------------------------------------------------
# The COMPLETE argument vector is validated BEFORE any effect. An argument
# in front of the flag is not the documented form of the restricted mode,
# and it must be rejected like the rest: no prompt, no generator, no npm.
# ---------------------------------------------------------------------------
test_rejected_argument_before_the_flag() {
  assert_rejected "extra-before-flag" \
    "usage: bash open-code/install-opencode.sh --command-only execute-plan" \
    extra --command-only execute-plan
}

# ---------------------------------------------------------------------------
# The flag is the FIRST argument of the restricted mode. A vector with the
# flag in another position is rejected too.
# ---------------------------------------------------------------------------
test_rejected_flag_not_first() {
  assert_rejected "flag-not-first" \
    "usage: bash open-code/install-opencode.sh --command-only execute-plan" \
    execute-plan --command-only
}

# ---------------------------------------------------------------------------
# The FULL installer accepts NO argument at all.
# ---------------------------------------------------------------------------
test_rejected_trailing_argument() {
  assert_rejected "trailing-argument" \
    "unexpected arguments; the full installer accepts no arguments" \
    execute-plan extra
}

# ---------------------------------------------------------------------------
# An unknown option is rejected before any effect too.
# ---------------------------------------------------------------------------
test_rejected_unknown_option() {
  assert_rejected "unknown-option" \
    "unrecognized installer option '--forge-unknown-option'" \
    --forge-unknown-option
}

# ---------------------------------------------------------------------------
# The physical destination is validated resolving the symbolic links of ALL
# its ancestors, and the rejection happens BEFORE the temporary file is
# created: no temporary, and the destination keeps its content.
# ---------------------------------------------------------------------------
test_rejected_symbolic_ancestor_destination() {
  local sandbox="$WORKDIR/symbolic-ancestor"
  make_sandbox "$sandbox"
  local home="$SANDBOX_HOME"

  # The overlay itself is a symbolic link: the destination is under a
  # symbolic ancestor, so the physical path of the destination is NOT the
  # path the installer was given.
  local real_overlay="$sandbox/real-overlay"
  mkdir -p "$real_overlay/commands"
  printf -- 'stale execute-plan content\n' \
    > "$real_overlay/commands/execute-plan.md"
  chmod 0644 "$real_overlay/commands/execute-plan.md"
  rm -rf "$home/.config/opencode-forge"
  ln -s "$real_overlay" "$home/.config/opencode-forge"

  run_install_with_terminal "$sandbox" --command-only execute-plan

  local rc=0
  run_install "$sandbox" --command-only execute-plan || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "symbolic-ancestor: rc != 0 (got $rc)"
  else
    fail "symbolic-ancestor: expected rc != 0, got 0"
    sed -n '1,10p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if grep -qF "must be physical and contain no symbolic-link ancestors" \
    "$sandbox/stderr.txt"; then
    pass "symbolic-ancestor: the diagnostic explains the rejection"
  else
    fail "symbolic-ancestor: the diagnostic does not explain the rejection"
    sed -n '1,10p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ "$(cat "$real_overlay/commands/execute-plan.md")" = "stale execute-plan content" ]; then
    pass "symbolic-ancestor: the content of the destination is intact"
  else
    fail "symbolic-ancestor: the content of the destination was modified"
  fi

  local leftovers
  leftovers="$(find "$real_overlay/commands" -name '.execute-plan.md.tmp.*' -print)"
  if [ -z "$leftovers" ]; then
    pass "symbolic-ancestor: no temporary file was created"
  else
    fail "symbolic-ancestor: a temporary file was created: $leftovers"
  fi

  assert_no_npm "$sandbox" "symbolic-ancestor"
  assert_no_prefix "$sandbox" "symbolic-ancestor"
  assert_no_key_signals "$sandbox" "symbolic-ancestor"
  assert_no_credential_prompt "$sandbox" "symbolic-ancestor"
  assert_generator_not_run "$sandbox" "symbolic-ancestor"
}

# ---------------------------------------------------------------------------
# The commands directory itself is a symbolic link: it is an ancestor of the
# destination, and it is rejected before the temporary file is created.
# ---------------------------------------------------------------------------
test_rejected_symbolic_commands_directory() {
  local sandbox="$WORKDIR/symbolic-commands"
  make_sandbox "$sandbox"
  local home="$SANDBOX_HOME"

  local real_commands="$sandbox/real-commands"
  mkdir -p "$real_commands"
  printf -- 'stale execute-plan content\n' \
    > "$real_commands/execute-plan.md"
  chmod 0644 "$real_commands/execute-plan.md"
  rm -rf "$home/.config/opencode-forge/commands"
  ln -s "$real_commands" "$home/.config/opencode-forge/commands"

  local rc=0
  run_install "$sandbox" --command-only execute-plan || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "symbolic-commands: rc != 0 (got $rc)"
  else
    fail "symbolic-commands: expected rc != 0, got 0"
    sed -n '1,10p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if grep -qF "must be physical and contain no symbolic-link ancestors" \
    "$sandbox/stderr.txt"; then
    pass "symbolic-commands: the diagnostic explains the rejection"
  else
    fail "symbolic-commands: the diagnostic does not explain the rejection"
    sed -n '1,10p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ "$(cat "$real_commands/execute-plan.md")" = "stale execute-plan content" ]; then
    pass "symbolic-commands: the content of the destination is intact"
  else
    fail "symbolic-commands: the content of the destination was modified"
  fi

  local leftovers
  leftovers="$(find "$real_commands" -name '.execute-plan.md.tmp.*' -print)"
  if [ -z "$leftovers" ]; then
    pass "symbolic-commands: no temporary file was created"
  else
    fail "symbolic-commands: a temporary file was created: $leftovers"
  fi

  assert_no_npm "$sandbox" "symbolic-commands"
  assert_no_prefix "$sandbox" "symbolic-commands"
}

test_rejected_command_path() {
  assert_rejected "relative-path" "only 'execute-plan' is allowed" \
    --command-only ../commands/execute-plan.md
  assert_rejected "absolute-path" "only 'execute-plan' is allowed" \
    --command-only /tmp/opencode/execute-plan.md
  assert_rejected "path-with-subdir" "only 'execute-plan' is allowed" \
    --command-only commands/execute-plan
}

test_rejected_extra_argument() {
  assert_rejected "extra-argument" "usage: bash open-code/install-opencode.sh --command-only execute-plan" \
    --command-only execute-plan extra
}

test_rejected_missing_name() {
  assert_rejected "missing-name" "usage: bash open-code/install-opencode.sh --command-only execute-plan" \
    --command-only
}

test_rejected_invalid_option() {
  assert_rejected "invalid-option" "invalid command-only option" \
    --command-onlyexecute-plan
}

test_rejected_symbolic_link_destination() {
  local sandbox="$WORKDIR/symlink-destination"
  make_sandbox "$sandbox"
  local home="$SANDBOX_HOME"
  local dest="$home/.config/opencode-forge/commands/execute-plan.md"
  local target="$home/.config/opencode-forge/commands/review.md"

  rm -f "$dest"
  ln -s "$target" "$dest"

  snapshot_tree "$home" "$sandbox/before.txt"
  snapshot_dirs "$home" "$sandbox/before.dirs"

  local rc=0
  run_install "$sandbox" --command-only execute-plan || rc=$?

  snapshot_tree "$home" "$sandbox/after.txt"
  snapshot_dirs "$home" "$sandbox/after.dirs"

  if [ "$rc" -ne 0 ]; then
    pass "symlink-destination: rc != 0 (got $rc)"
  else
    fail "symlink-destination: expected rc != 0, got 0"
  fi

  if grep -qF "refusing to replace symbolic-link destination" "$sandbox/stderr.txt"; then
    pass "symlink-destination: the diagnostic explains the rejection"
  else
    fail "symlink-destination: the diagnostic does not explain the rejection"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$target" ]; then
    pass "symlink-destination: the symbolic link was not followed nor replaced"
  else
    fail "symlink-destination: the symbolic link was replaced"
  fi

  if diff -u "$sandbox/before.txt" "$sandbox/after.txt" > "$sandbox/tree.diff" 2>&1; then
    pass "symlink-destination: the tree is identical before and after"
  else
    fail "symlink-destination: the tree changed"
    sed -n '1,20p' "$sandbox/tree.diff" | sed 's/^/      /' >&2
  fi

  assert_no_npm "$sandbox" "symlink-destination"
  assert_no_prefix "$sandbox" "symlink-destination"
  assert_no_key_signals "$sandbox" "symlink-destination"
}

test_rejected_missing_destination() {
  local sandbox="$WORKDIR/missing-destination"
  make_sandbox "$sandbox"
  local home="$SANDBOX_HOME"
  rm -f "$home/.config/opencode-forge/commands/execute-plan.md"

  snapshot_tree "$home" "$sandbox/before.txt"

  local rc=0
  run_install "$sandbox" --command-only execute-plan || rc=$?

  snapshot_tree "$home" "$sandbox/after.txt"

  if [ "$rc" -ne 0 ]; then
    pass "missing-destination: rc != 0 (got $rc)"
  else
    fail "missing-destination: expected rc != 0, got 0"
  fi

  if grep -qF "command destination must already exist as a regular file" "$sandbox/stderr.txt"; then
    pass "missing-destination: the diagnostic is explicit"
  else
    fail "missing-destination: the diagnostic is not explicit"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ ! -e "$home/.config/opencode-forge/commands/execute-plan.md" ]; then
    pass "missing-destination: the destination was not created"
  else
    fail "missing-destination: the destination was created"
  fi

  if diff -u "$sandbox/before.txt" "$sandbox/after.txt" > "$sandbox/tree.diff" 2>&1; then
    pass "missing-destination: the tree is identical before and after"
  else
    fail "missing-destination: the tree changed"
  fi

  assert_no_npm "$sandbox" "missing-destination"
  assert_no_prefix "$sandbox" "missing-destination"
}

test_rejected_missing_overlay_directory() {
  local sandbox="$WORKDIR/missing-overlay"
  make_sandbox "$sandbox"
  local home="$SANDBOX_HOME"
  rm -rf "$home/.config/opencode-forge/commands"

  snapshot_tree "$home" "$sandbox/before.txt"

  local rc=0
  run_install "$sandbox" --command-only execute-plan || rc=$?

  snapshot_tree "$home" "$sandbox/after.txt"

  if [ "$rc" -ne 0 ]; then
    pass "missing-overlay: rc != 0 (got $rc)"
  else
    fail "missing-overlay: expected rc != 0, got 0"
  fi

  if grep -qF "the existing Forge overlay and commands directory are required" "$sandbox/stderr.txt"; then
    pass "missing-overlay: the diagnostic is explicit"
  else
    fail "missing-overlay: the diagnostic is not explicit"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if diff -u "$sandbox/before.txt" "$sandbox/after.txt" > "$sandbox/tree.diff" 2>&1; then
    pass "missing-overlay: the tree is identical before and after"
  else
    fail "missing-overlay: the tree changed"
  fi

  assert_no_npm "$sandbox" "missing-overlay"
  assert_no_prefix "$sandbox" "missing-overlay"
}

test_real_installation_is_untouched() {
  if [ ! -d "$REAL_OVERLAY" ]; then
    echo "  SKIP: no real overlay to compare (${REAL_OVERLAY})"
    return
  fi
  if cmp -s "$WORKDIR/real-overlay.before.txt" "$WORKDIR/real-overlay.after.txt" \
    && cmp -s "$WORKDIR/real-commands.before.txt" "$WORKDIR/real-commands.after.txt"; then
    pass "safety: the real overlay is untouched by the suite"
  else
    fail "safety: the real overlay changed during the suite"
    diff -u "$WORKDIR/real-overlay.before.txt" "$WORKDIR/real-overlay.after.txt" \
      | sed 's/^/      /' >&2 || true
    diff -u "$WORKDIR/real-commands.before.txt" "$WORKDIR/real-commands.after.txt" \
      | sed 's/^/      /' >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

echo "=== execute_plan_command_only_unit.sh ==="

WORKDIR="$(mktemp -d "$TMPDIR_BASE/command-only-$$-XXXXXX")"
write_pty_probe "$WORKDIR/pty_probe.py"

if [ -d "$REAL_OVERLAY" ]; then
  snapshot_shallow "$REAL_OVERLAY" "$WORKDIR/real-overlay.before.txt"
  if [ -d "$REAL_OVERLAY/commands" ]; then
    snapshot_tree "$REAL_OVERLAY/commands" "$WORKDIR/real-commands.before.txt"
  fi
fi

# ---------------------------------------------------------------------------
# Sensitivity of the argument validation and of the physical destination:
# each broken rule must make this suite FAIL, and the failure must be
# attributed to the EXPECTED case.
#
# The mutation is applied to the COPY of the installer inside the sandbox of
# the mutated run: the repository is never modified.
# ---------------------------------------------------------------------------
test_the_suite_detects_each_broken_rule() {
  local suite="$FORGE_ROOT/tests/execute_plan_command_only_unit.sh"
  local mutation expected output rc

  for mutation in \
    drop-command-only-position-check \
    drop-command-only-count-check \
    drop-restricted-argument-checks \
    drop-full-args-check \
    drop-unknown-option-check \
    drop-symbolic-ancestor-check; do
    case "$mutation" in
      drop-command-only-position-check)
        expected="FAIL: flag-not-first: the diagnostic does not explain the rejection"
        ;;
      drop-command-only-count-check)
        expected="FAIL: extra-argument: expected rc != 0, got 0"
        ;;
      drop-restricted-argument-checks)
        expected="FAIL: extra-before-flag: the diagnostic does not explain the rejection"
        ;;
      drop-full-args-check)
        expected="FAIL: trailing-argument: the pinned binary installer was invoked"
        ;;
      drop-unknown-option-check)
        expected="FAIL: unknown-option: the diagnostic does not explain the rejection"
        ;;
      drop-symbolic-ancestor-check)
        expected="FAIL: symbolic-ancestor: the content of the destination was modified"
        ;;
    esac

    rc=0
    output="$(FORGE_TEST_INSTALLER_MUTATION="$mutation" bash "$suite" </dev/null 2>&1)" || rc=$?

    if [ "$rc" -ne 0 ]; then
      pass "sensitivity: the mutation '$mutation' makes the suite FAIL (rc=$rc)"
    else
      fail "sensitivity: the mutation '$mutation' did NOT make the suite FAIL"
      printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi

    if printf '%s\n' "$output" | grep -qF "$expected"; then
      pass "sensitivity: the failure of '$mutation' is ATTRIBUTED to its own case"
    else
      fail "sensitivity: the failure of '$mutation' is NOT attributed to its own case"
      printf '%s\n' "$output" | grep -F "FAIL:" | sed 's/^/      /' >&2 || true
    fi
  done
}

run_test test_valid_invocation_updates_only_the_allowed_command
run_test test_rejected_unsupported_command_name
run_test test_rejected_command_path
run_test test_rejected_extra_argument
run_test test_rejected_missing_name
run_test test_rejected_invalid_option
run_test test_rejected_argument_before_the_flag
run_test test_rejected_flag_not_first
run_test test_rejected_trailing_argument
run_test test_rejected_unknown_option
run_test test_rejected_symbolic_link_destination
run_test test_rejected_symbolic_ancestor_destination
run_test test_rejected_symbolic_commands_directory
run_test test_rejected_missing_destination
run_test test_rejected_missing_overlay_directory

# The sensitivity of the argument validation and of the physical destination
# is measured by running THIS suite against an installer whose rules are
# broken. It is skipped when the suite itself runs with a mutation, so the
# recursion stays bounded.
if [ -z "$FORGE_TEST_INSTALLER_MUTATION" ]; then
  run_test test_the_suite_detects_each_broken_rule
fi

if [ -d "$REAL_OVERLAY" ]; then
  snapshot_shallow "$REAL_OVERLAY" "$WORKDIR/real-overlay.after.txt"
  if [ -d "$REAL_OVERLAY/commands" ]; then
    snapshot_tree "$REAL_OVERLAY/commands" "$WORKDIR/real-commands.after.txt"
  fi
fi
run_test test_real_installation_is_untouched

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
