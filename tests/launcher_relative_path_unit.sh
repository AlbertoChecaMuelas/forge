#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/launcher_relative_path_unit.sh — routing of the ROOT invocation of the
# Forge launcher when its first argument is a project DIRECTORY.
#
#   forge-opencode <project-directory>
#
# OpenCode 2 shares a background server by default, so the Forge launcher
# must ask for a private one (`--standalone`) on every root invocation that
# can reach the shared service. A project directory is one of those root
# invocations, and OpenCode accepts it positionally — INCLUDING the relative
# form without a `./` or `../` prefix.
#
# The suite runs the REAL launcher against a throw-away HOME and a fixture
# binary that records the arguments it receives, so the routing is observed
# and not inferred. It proves that:
#
#   - a project directory receives `--standalone` in EVERY shape: relative
#     without a prefix, `./`, `../`, absolute, `.` and `..`;
#   - an unknown argument that is NOT an existing directory is NOT
#     reinterpreted as a path: it receives no `--standalone` and the CLI
#     still rejects it;
#   - the known subcommands keep their precedence over a directory of the
#     same name, and `mcp --help` is not broken;
#   - the root options (`--help`, `--version`) keep working;
#   - the PINNED binary of the manifest is the one that runs: the decoy of
#     the PATH is never executed.
#
# The PINNED binary is not any executable: the launcher only accepts one
# that is ACCREDITED, so the fixture materialises the layout it demands:
#
#   <prefix>/node_modules/.bin/opencode            (the entry of the manifest)
#     -> <prefix>/node_modules/@opencode/cli/<the declared executable>
#   <prefix>/node_modules/@opencode/cli/package.json  (@opencode/cli@2.1.4)
#
# The layout is the REAL one. The real @opencode/cli@2.1.4 declares in its
# OWN package.json:
#
#   "bin": {"opencode": "./bin/opencode.exe", "opencode2": "./bin/opencode.exe"}
#
# and publishes the executable THERE. The fixture never decides where the
# executable lives: the package.json of the fixture DECLARES it and the
# fixture materialises it at the DECLARED path (read back from that
# package.json), exactly as the production resolves it.
#
# That is not a detail: a fixture that published a layout the real package
# never publishes stays GREEN against a launcher that compares the
# registered executable against a FIXED path (`bin/opencode`) instead of
# resolving it from the `bin` field of the package. Such a launcher runs
# the real installation of nobody, and the defect stays invisible. One
# case of this suite therefore publishes a package whose executable has a
# name of its own, and the SENSITIVITY of the suite is measured against a
# mutation that reintroduces the fixed path.
#
# The suite proves that the accreditation is a GATE, not a decoration:
#
#   - a binary OUTSIDE the prefix is REJECTED (rc 1) and it is NEVER
#     executed: the fixture records its own execution with a SENTINEL;
#   - an entry of `.bin` that resolves OUTSIDE the package is rejected and
#     never executed either;
#   - an entry of `.bin` that resolves INSIDE the package but NOT to the
#     executable that the package DECLARES is rejected and never executed;
#   - a package whose version is not the pinned one is rejected and never
#     executed;
#   - the executable is RESOLVED from the `bin` field of the package: a
#     package that declares an executable of its own is accredited and runs;
#   - a VALID package under a CUSTOM prefix is accepted and runs.
#
# The launcher is copied into the sandbox before it runs, so the optional
# mutation of the sensitivity check never touches the repository.
#
# Compatible with bash 3.2+.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"

# Source of the launcher under test. The copy inside the sandbox is what
# runs, so the mutation of the sensitivity check is confined to the sandbox.
LAUNCHER_SRC_DIR="${FORGE_TEST_LAUNCHER_DIR:-$FORGE_ROOT/open-code}"

# Optional mutation applied to the COPY of the launcher inside the sandbox.
FORGE_TEST_LAUNCHER_MUTATION="${FORGE_TEST_LAUNCHER_MUTATION:-}"

FAIL=0
PASS=0

WORKDIR=""
TMPDIR_BASE="/tmp/opencode"

cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  FAIL=$((FAIL + 1))
}

run_test() {
  local name="$1"
  echo "--- $name"
  "$name"
}

# ---------------------------------------------------------------------------
# The fixture binary: it records the arguments it receives and it emulates the
# ROOT grammar of the real CLI: a known subcommand, a root option or an
# existing directory are accepted; anything else is an unknown command and
# fails. The "unknown command" behaviour is what proves that the launcher
# did NOT reinterpret the argument as a path.
# ---------------------------------------------------------------------------
write_fixture_cli() {
  local path="$1"
  cat > "$path" <<'CLI_EOF'
#!/usr/bin/env sh
# Fake OpenCode CLI 2.1.4 used by the launcher routing fixture.
#
# It is NOT a runtime: it records the arguments it receives (that is the
# contract the launcher routing is observed through) and it emulates the root
# grammar of the real CLI.
printf 'ARGV=%s\n' "$*"
case "${1:-}" in
  acp|api|debug|mcp|models|mini|pair|plugin|reload|run|serve|service|stats|uninstall|update|upgrade|auth|session)
    exit 0
    ;;
  --help|-h|--version|-v)
    exit 0
    ;;
  -*)
    exit 0
    ;;
  "")
    exit 0
    ;;
esac
if [ -d "${1:-}" ]; then
  exit 0
fi
printf 'Unknown command: %s\n' "${1:-}" >&2
exit 1
CLI_EOF
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# The layout that the fixture publishes.
#
# The default is the layout of the REAL @opencode/cli@2.1.4: the executable
# is named `opencode.exe` and the package declares it in its `bin` field.
# The alternative is a name of the fixture's own: the suite must not depend
# on the name of the executable.
# ---------------------------------------------------------------------------
FIXTURE_DECLARED_BIN="./bin/opencode.exe"
FIXTURE_DECLARED_BIN_ALTERNATIVE="./bin/forge-oc-2.1.4"

# ---------------------------------------------------------------------------
# The ACCREDITED package: the launcher only accepts a pinned binary whose
# path follows the <prefix>/node_modules/.bin/opencode layout, that RESOLVES
# to the executable that the package.json of @opencode/cli@2.1.4 DECLARES
# under that prefix and that is accredited by that same package.json.
#
# write_accredited_package <prefix> [version] [declared-bin]
#
# The declared path is the ONLY place where the name of the executable
# appears: the package.json DECLARES it and the fixture materialises the
# executable at the DECLARED path, read back from that package.json. The
# entry of `.bin` is derived from the same declaration.
# ---------------------------------------------------------------------------
write_accredited_package() {
  local prefix="$1"
  local version="${2:-2.1.4}"
  local declared="${3:-$FIXTURE_DECLARED_BIN}"
  local package_dir="$prefix/node_modules/@opencode/cli"

  mkdir -p "$package_dir" "$prefix/node_modules/.bin"

  cat > "$package_dir/package.json" <<PACKAGE_EOF
{
  "name": "@opencode/cli",
  "version": "$version",
  "bin": {
    "opencode": "$declared"
  }
}
PACKAGE_EOF

  # The DECLARED path is read back from the package.json: the fixture
  # materialises what the package declares, never a name of its own.
  local declared_relative executable
  declared_relative="$(jq -r '.bin.opencode // empty' "$package_dir/package.json" 2>/dev/null || true)"
  if [ -z "$declared_relative" ]; then
    echo "  FAIL: el package.json del fixture no declara ningun ejecutable" >&2
    return 1
  fi
  declared_relative="${declared_relative#./}"

  executable="$package_dir/$declared_relative"
  mkdir -p "$(dirname "$executable")"
  write_fixture_cli "$executable"

  ln -sfn "../@opencode/cli/$declared_relative" "$prefix/node_modules/.bin/opencode"
}

# ---------------------------------------------------------------------------
# The manifest: the launcher reads the pinned binary from it, so the binary
# under test can be moved without touching the rest of the fixture.
# ---------------------------------------------------------------------------
write_manifest() {
  local home="$1" overlay="$2" binary="$3"

  jq -n \
    --arg dir "$overlay" \
    --arg config "$overlay/opencode.jsonc" \
    --arg binary "$binary" \
    '{
      version: "0.8.2",
      installed_at: "2026-10-01T09:00:00Z",
      state_schema: 3,
      targets: ["opencode"],
      symlinks: [],
      targets_manifest: [
        {
          name: "opencode",
          dir: $dir,
          config_file: $config,
          binary: $binary,
          symlinks: [],
          symlinks_objects: [],
          components: [],
          settings_merged: false,
          settings_backup: null
        }
      ],
      settings: {managed_paths: {}, overlay_backup: {}, settings_json_backup: {}},
      rtk: {pinned_version: "0.43.0", detected_version: null, installed_by_us: false, install_failed: false, version_mismatch: false}
    }' > "$home/.forge-state.json"
}

# ---------------------------------------------------------------------------
# The sandbox: a throw-away HOME with a valid manifest whose pinned binary is
# the fixture CLI, plus a decoy `opencode` in the PATH.
# ---------------------------------------------------------------------------
make_sandbox() {
  local sandbox="$1"
  local home="$sandbox/home"
  local bin_dir="$home/.local/share/forge/opencode-v2/node_modules/.bin"
  local overlay="$home/.config/opencode-forge"

  mkdir -p "$bin_dir" "$overlay" "$home/.cache" "$home/.local/state" \
    "$sandbox/launcher" "$sandbox/fakebin" "$sandbox/work"

  write_accredited_package "$home/.local/share/forge/opencode-v2"
  printf '{}\n' > "$overlay/opencode.jsonc"

  write_manifest "$home" "$overlay" "$bin_dir/opencode"

  # The launcher under test: a copy, so the mutation never touches the repo.
  cp "$LAUNCHER_SRC_DIR/forge-opencode.sh" "$sandbox/launcher/forge-opencode.sh"
  if [ -f "$LAUNCHER_SRC_DIR/env.sh" ]; then
    cp "$LAUNCHER_SRC_DIR/env.sh" "$sandbox/launcher/env.sh"
  fi
  apply_launcher_mutation "$sandbox/launcher/forge-opencode.sh" "$FORGE_TEST_LAUNCHER_MUTATION"

  # The decoy: the only `opencode` reachable by name. If the launcher ever
  # falls back to the PATH, the marker appears in the output.
  cat > "$sandbox/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
printf 'PATH-DECOY-OPENCODE\n'
exit 0
EOF
  chmod +x "$sandbox/fakebin/opencode"

  printf '%s\n' "$home"
}

# ---------------------------------------------------------------------------
# A binary OUTSIDE the accredited prefix: it records its own execution with a
# SENTINEL, so "the launcher never executed it" is an OBSERVED fact and not
# an inference.
# ---------------------------------------------------------------------------
write_external_binary() {
  local sandbox="$1"
  local external="$sandbox/external/opencode"

  mkdir -p "$sandbox/external"
  cat > "$external" <<EXTERNAL_EOF
#!/usr/bin/env sh
printf 'EXTERNAL-OPENCODE-EXECUTED\n' > "$sandbox/external-was-executed"
printf 'ARGV=%s\n' "\$*"
exit 0
EXTERNAL_EOF
  chmod +x "$external"
  printf '%s\n' "$external"
}

# ---------------------------------------------------------------------------
# A DECOY INSIDE the package: it lives under the @opencode/cli package but
# it is NOT the executable that the package DECLARES. The accreditation
# demands that the entry of `.bin` resolves to THAT executable, so the decoy
# is rejected. It records its own execution with a SENTINEL too.
# ---------------------------------------------------------------------------
write_decoy_in_package() {
  local sandbox="$1"
  local package_dir="$2"
  local decoy="$package_dir/decoy/impostor"

  mkdir -p "$package_dir/decoy"
  cat > "$decoy" <<DECOY_EOF
#!/usr/bin/env sh
printf 'DECOY-OPENCODE-EXECUTED\n' > "$sandbox/decoy-was-executed"
printf 'ARGV=%s\n' "\$*"
exit 0
DECOY_EOF
  chmod +x "$decoy"
  printf '%s\n' "$decoy"
}

# apply_launcher_mutation <launcher copy> <mutation>
#
# drop-relative-dir-standalone: the routing only recognises the ABSOLUTE
# directories, which is the defect this suite must detect: a relative
# directory without a prefix would reach the shared service.
#
# drop-package-accreditation: the launcher stops ACREDITING the pinned
# binary, so a binary outside the prefix would be executed.
#
# drop-resolution-checks: the launcher stops checking that the entry of
# `.bin` RESOLVES to the executable of the package (and that it stays under
# it), so an entry that escapes the package would be executed.
#
# drop-version-check: the launcher stops checking the identity and the
# version of the installed package, so a package that is not the pinned one
# would be executed.
#
# hardcode-declared-bin: the launcher stops RESOLVING the executable from the
# `bin` field that the package declares and compares the registered
# executable against a FIXED path (`bin/opencode`) again. This is the
# regression that the suite must never let pass: it is the defect that
# broke the real installation, whose @opencode/cli@2.1.4 declares
# `./bin/opencode.exe`.
apply_launcher_mutation() {
  local launcher="$1" mutation="$2"
  case "$mutation" in
    "") return 0 ;;
    drop-relative-dir-standalone)
      python3 - "$launcher" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = '          if [ -d "$forge_sub" ]; then\n'
mutated = '          if [ -d "$forge_sub" ] && { case "$forge_sub" in /*) true ;; *) false ;; esac; }; then\n'
if anchor not in text:
    sys.stderr.write("mutation anchor not found in the launcher copy\n")
    raise SystemExit(2)
text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-package-accreditation)
      python3 - "$launcher" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = 'if ! forge_validate_pinned_binary "$forge_binary"; then\n'
mutated = 'if false; then\n'
if text.count(anchor) != 1:
    sys.stderr.write("mutation anchor not found in the launcher copy\n")
    raise SystemExit(2)
text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-resolution-checks)
      python3 - "$launcher" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

# Both clauses of the RESOLUTION are disabled: the executable must stay
# under the package, and it must be the executable OF the package. The two
# clauses overlap, so a single mutation has to break both of them to make
# the resolution observable.
pairs = (
    (
        "    if not is_within(real_package_dir, real_prefix):\n",
        "    if False:\n",
    ),
    (
        "    if not is_within(real_binary, real_package_dir):\n",
        "    if False:\n",
    ),
    (
        "    if real_binary != resolved_declared_bin:\n",
        "    if False:\n",
    ),
)
for anchor, mutated in pairs:
    if text.count(anchor) != 1:
        sys.stderr.write("mutation anchor not found in the launcher copy\n")
        raise SystemExit(2)
    text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    hardcode-declared-bin)
      python3 - "$launcher" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

# The RESOLUTION from the `bin` field of the package is replaced by the
# FIXED path that the defective launcher used: the registered executable is
# compared against `<package>/bin/opencode` whatever the package declares.
# The existence check of the declared entry disappears with it, exactly as
# it did in the defective launcher: the comparison was made against a path
# that the real package never publishes.
pairs = (
    (
        """    bin_entries = package.get("bin")
    if not isinstance(bin_entries, dict) or binary_name not in bin_entries:
        fail("the installed package does not declare a bin entry named " + repr(binary_name))
    declared_bin = bin_entries[binary_name]
    if not isinstance(declared_bin, str) or not declared_bin:
        fail("the package bin entry for " + repr(binary_name) + " is invalid")
    if os.path.isabs(declared_bin):
        fail("the package bin entry for " + repr(binary_name) + " must be relative")

    resolved_declared_bin = os.path.realpath(os.path.join(real_package_dir, declared_bin))
""",
        """    resolved_declared_bin = os.path.realpath(os.path.join(real_package_dir, "bin", "opencode"))
""",
    ),
    (
        """    if not os.path.isfile(resolved_declared_bin) or not os.access(resolved_declared_bin, os.X_OK):
        fail("the package bin entry for " + repr(binary_name) + " is missing or not executable")
""",
        """    if False:
        fail("the package bin entry for " + repr(binary_name) + " is missing or not executable")
""",
    ),
)
for anchor, mutated in pairs:
    if text.count(anchor) != 1:
        sys.stderr.write("mutation anchor not found in the launcher copy\n")
        raise SystemExit(2)
    text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-version-check)
      python3 - "$launcher" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = 'if package.get("name") != "@opencode/cli" or package.get("version") != version:\n'
mutated = 'if False:\n'
if text.count(anchor) != 1:
    sys.stderr.write("mutation anchor not found in the launcher copy\n")
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

# run_launcher <sandbox> <cwd> [args...]
run_launcher() {
  local sandbox="$1" cwd="$2"
  shift 2
  local home="$sandbox/home"
  (
    cd "$cwd" || exit 1
    env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
      -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
      HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" \
      XDG_CACHE_HOME="$home/.cache" \
      XDG_DATA_HOME="$home/.local/share" \
      XDG_STATE_HOME="$home/.local/state" \
      PATH="$sandbox/fakebin:$PATH" \
      sh "$sandbox/launcher/forge-opencode.sh" "$@"
  ) > "$sandbox/stdout.txt" 2> "$sandbox/stderr.txt"
}

# assert_argv <label> <expected-argv> <sandbox>
assert_argv() {
  local label="$1" expected="$2" sandbox="$3"
  if grep -qF -- "ARGV=$expected" "$sandbox/stdout.txt"; then
    pass "$label: the CLI received ARGV=$expected"
  else
    fail "$label: the CLI did not receive ARGV=$expected"
    sed -n '1,5p' "$sandbox/stdout.txt" | sed 's/^/      /' >&2
  fi
}

# assert_no_standalone <label> <sandbox>
assert_no_standalone() {
  local label="$1" sandbox="$2"
  if grep -qF -- "ARGV=" "$sandbox/stdout.txt" \
    && ! grep -qF -- "--standalone" "$sandbox/stdout.txt"; then
    pass "$label: no --standalone was injected"
  else
    fail "$label: a --standalone was injected"
    sed -n '1,5p' "$sandbox/stdout.txt" | sed 's/^/      /' >&2
  fi
}

# assert_no_decoy <label> <sandbox>
assert_no_decoy() {
  local label="$1" sandbox="$2"
  if grep -qF "PATH-DECOY-OPENCODE" "$sandbox/stdout.txt" "$sandbox/stderr.txt" 2>/dev/null; then
    fail "$label: the launcher executed the decoy of the PATH"
  else
    pass "$label: the launcher executed the pinned binary of the manifest"
  fi
}

# ---------------------------------------------------------------------------
# Case (B1): a project directory receives --standalone in every shape.
# ---------------------------------------------------------------------------
test_project_directory_receives_standalone() {
  local sandbox="$WORKDIR/directories"
  local home
  home="$(make_sandbox "$sandbox")"

  # The directories of the fixture, in every shape.
  mkdir -p "$sandbox/work/open-code" \
    "$sandbox/work/absolute-dir" \
    "$sandbox/sibling"
  mkdir -p "$sandbox/work/mcp" "$sandbox/work/debug"

  # 1. relative without a prefix
  local rc=0
  run_launcher "$sandbox" "$sandbox/work" open-code || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "relative-no-prefix: rc 0"
  else
    fail "relative-no-prefix: expected rc 0, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi
  assert_argv "relative-no-prefix" "--standalone open-code" "$sandbox"

  # 2. ./ relative
  rc=0
  run_launcher "$sandbox" "$sandbox/work" ./open-code || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "dot-relative: rc 0"
  else
    fail "dot-relative: expected rc 0, got $rc"
  fi
  assert_argv "dot-relative" "--standalone ./open-code" "$sandbox"

  # 3. ../ relative
  rc=0
  run_launcher "$sandbox" "$sandbox/work" ../sibling || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "parent-relative: rc 0"
  else
    fail "parent-relative: expected rc 0, got $rc"
  fi
  assert_argv "parent-relative" "--standalone ../sibling" "$sandbox"

  # 4. absolute
  rc=0
  run_launcher "$sandbox" "$sandbox/work" "$sandbox/work/absolute-dir" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "absolute: rc 0"
  else
    fail "absolute: expected rc 0, got $rc"
  fi
  assert_argv "absolute" "--standalone $sandbox/work/absolute-dir" "$sandbox"

  # 5. the directory itself and its parent
  rc=0
  run_launcher "$sandbox" "$sandbox/work" . || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "current-dir: rc 0"
  else
    fail "current-dir: expected rc 0, got $rc"
  fi
  assert_argv "current-dir" "--standalone ." "$sandbox"

  rc=0
  run_launcher "$sandbox" "$sandbox/work" .. || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "parent-dir: rc 0"
  else
    fail "parent-dir: expected rc 0, got $rc"
  fi
  assert_argv "parent-dir" "--standalone .." "$sandbox"

  assert_no_decoy "relative-no-prefix" "$sandbox"
}

# ---------------------------------------------------------------------------
# Case (B2): an unknown argument that is not a directory keeps failing.
# ---------------------------------------------------------------------------
test_unknown_argument_is_not_reinterpreted_as_a_path() {
  local sandbox="$WORKDIR/unknown"
  local home
  home="$(make_sandbox "$sandbox")"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" frobnicate || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "unknown-subcommand: rc != 0 (got $rc)"
  else
    fail "unknown-subcommand: expected rc != 0, got 0"
  fi
  assert_no_standalone "unknown-subcommand" "$sandbox"
  if grep -qF "Unknown command: frobnicate" "$sandbox/stderr.txt"; then
    pass "unknown-subcommand: the CLI still rejects the argument"
  else
    fail "unknown-subcommand: the CLI did not reject the argument"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  rc=0
  run_launcher "$sandbox" "$sandbox/work" no-such-directory || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "unknown-path: rc != 0 (got $rc)"
  else
    fail "unknown-path: expected rc != 0, got 0"
  fi
  assert_no_standalone "unknown-path" "$sandbox"
  if grep -qF "Unknown command: no-such-directory" "$sandbox/stderr.txt"; then
    pass "unknown-path: the CLI still rejects the argument"
  else
    fail "unknown-path: the CLI did not reject the argument"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  assert_no_decoy "unknown-subcommand" "$sandbox"
}

# ---------------------------------------------------------------------------
# Case (B3): the known subcommands keep their precedence.
# ---------------------------------------------------------------------------
test_known_subcommands_keep_their_precedence() {
  local sandbox="$WORKDIR/precedence"
  local home
  home="$(make_sandbox "$sandbox")"
  mkdir -p "$sandbox/work/mcp" "$sandbox/work/debug"

  # A directory named like a known subcommand is still the subcommand.
  local rc=0
  run_launcher "$sandbox" "$sandbox/work" mcp || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "mcp-precedence: rc 0"
  else
    fail "mcp-precedence: expected rc 0, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi
  assert_argv "mcp-precedence" "mcp" "$sandbox"

  rc=0
  run_launcher "$sandbox" "$sandbox/work" debug || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "debug-precedence: rc 0"
  else
    fail "debug-precedence: expected rc 0, got $rc"
  fi
  assert_argv "debug-precedence" "debug" "$sandbox"

  # `mcp --help` is a help path: it is not a private list and it does not
  # receive an injected flag.
  rc=0
  run_launcher "$sandbox" "$sandbox/work" mcp --help || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "mcp-help: rc 0"
  else
    fail "mcp-help: expected rc 0, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi
  assert_argv "mcp-help" "mcp --help" "$sandbox"
  assert_no_standalone "mcp-help" "$sandbox"

  assert_no_decoy "mcp-precedence" "$sandbox"
}

# ---------------------------------------------------------------------------
# Case (B4): the root options are not broken.
# ---------------------------------------------------------------------------
test_root_options_are_not_broken() {
  local sandbox="$WORKDIR/root-options"
  local home
  home="$(make_sandbox "$sandbox")"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" --help || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "help: rc 0"
  else
    fail "help: expected rc 0, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi
  if grep -qF -- "--help" "$sandbox/stdout.txt"; then
    pass "help: the --help option is still forwarded"
  else
    fail "help: the --help option was not forwarded"
  fi

  rc=0
  run_launcher "$sandbox" "$sandbox/work" --version || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "version: rc 0"
  else
    fail "version: expected rc 0, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi
  if grep -qF -- "--version" "$sandbox/stdout.txt"; then
    pass "version: the --version option is still forwarded"
  else
    fail "version: the --version option was not forwarded"
  fi

  assert_no_decoy "help" "$sandbox"
}

# ---------------------------------------------------------------------------
# Case (B5): a pinned binary OUTSIDE the accredited prefix is rejected BEFORE
# it runs. The fixture of that binary records its own execution with a
# SENTINEL, so the suite observes that it never ran.
# ---------------------------------------------------------------------------
test_external_binary_is_rejected_without_execution() {
  local sandbox="$WORKDIR/external"
  local home
  home="$(make_sandbox "$sandbox")"
  local external
  external="$(write_external_binary "$sandbox")"

  write_manifest "$home" "$home/.config/opencode-forge" "$external"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" --help || rc=$?

  if [ "$rc" -eq 1 ]; then
    pass "external-binary: rc 1"
  else
    fail "external-binary: expected rc 1, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if grep -qF "no se pudo acreditar el paquete OpenCode 2.1.4" "$sandbox/stderr.txt"; then
    pass "external-binary: the diagnostic explains the rejection"
  else
    fail "external-binary: the diagnostic does not explain the rejection"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ ! -e "$sandbox/external-was-executed" ]; then
    pass "external-binary: the external binary was never executed"
  else
    fail "external-binary: the external binary was never executed"
  fi

  if ! grep -qF "ARGV=" "$sandbox/stdout.txt"; then
    pass "external-binary: the CLI never received any argument"
  else
    fail "external-binary: the CLI never received any argument"
    sed -n '1,5p' "$sandbox/stdout.txt" | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# Case (B6): the entry of `.bin` follows the LAYOUT but RESOLVES OUTSIDE the
# package. The accreditation demands that it resolves to the executable of
# @opencode/cli under the registered prefix, so it is rejected too.
# ---------------------------------------------------------------------------
test_escaping_bin_entry_is_rejected_without_execution() {
  local sandbox="$WORKDIR/escaping"
  local home
  home="$(make_sandbox "$sandbox")"
  local external prefix
  external="$(write_external_binary "$sandbox")"
  prefix="$home/.local/share/forge/opencode-v2"

  ln -sfn "$external" "$prefix/node_modules/.bin/opencode"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" --help || rc=$?

  if [ "$rc" -eq 1 ]; then
    pass "escaping-bin: rc 1"
  else
    fail "escaping-bin: expected rc 1, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if grep -qF "no se pudo acreditar el paquete OpenCode 2.1.4" "$sandbox/stderr.txt"; then
    pass "escaping-bin: the diagnostic explains the rejection"
  else
    fail "escaping-bin: the diagnostic does not explain the rejection"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ ! -e "$sandbox/external-was-executed" ]; then
    pass "escaping-bin: the external binary was never executed"
  else
    fail "escaping-bin: the external binary was never executed"
  fi

  if ! grep -qF "ARGV=" "$sandbox/stdout.txt"; then
    pass "escaping-bin: the CLI never received any argument"
  else
    fail "escaping-bin: the CLI never received any argument"
    sed -n '1,5p' "$sandbox/stdout.txt" | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# Case (B6b): the entry of `.bin` resolves INSIDE the package but NOT to the
# executable that the package DECLARES. Only the resolution to the declared
# bin entry rejects it, so this case is the one that pins that clause of the
# accreditation.
# ---------------------------------------------------------------------------
test_decoy_bin_entry_is_rejected_without_execution() {
  local sandbox="$WORKDIR/decoy"
  local home
  home="$(make_sandbox "$sandbox")"
  local prefix decoy
  prefix="$home/.local/share/forge/opencode-v2"
  decoy="$(write_decoy_in_package "$sandbox" "$prefix/node_modules/@opencode/cli")"

  ln -sfn ../@opencode/cli/decoy/impostor "$prefix/node_modules/.bin/opencode"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" --help || rc=$?

  if [ "$rc" -eq 1 ]; then
    pass "decoy-bin: rc 1"
  else
    fail "decoy-bin: expected rc 1, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if grep -qF "no se pudo acreditar el paquete OpenCode 2.1.4" "$sandbox/stderr.txt"; then
    pass "decoy-bin: the diagnostic explains the rejection"
  else
    fail "decoy-bin: the diagnostic does not explain the rejection"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ ! -e "$sandbox/decoy-was-executed" ]; then
    pass "decoy-bin: the decoy was never executed"
  else
    fail "decoy-bin: the decoy was never executed"
  fi

  if ! grep -qF "ARGV=" "$sandbox/stdout.txt"; then
    pass "decoy-bin: the CLI never received any argument"
  else
    fail "decoy-bin: the CLI never received any argument"
    sed -n '1,5p' "$sandbox/stdout.txt" | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# Case (B6c): the executable of the package is NOT the one that a FIXED
# path would suggest: the package declares an executable of its own and the
# launcher must RESOLVE it from that declaration.
#
# This is the case that pins the defect this suite exists to catch: a
# launcher that compares the registered executable against a hard-coded
# path (`bin/opencode`) accredits a package that the real @opencode/cli
# never publishes and rejects the real one, which declares
# `./bin/opencode.exe`. The failure of this case is the ATTRIBUTION that
# the sensitivity of the suite looks for.
# ---------------------------------------------------------------------------
test_executable_is_resolved_from_the_declared_bin() {
  local sandbox="$WORKDIR/declared-bin"
  local home
  home="$(make_sandbox "$sandbox")"
  local prefix
  prefix="$home/.local/share/forge/opencode-v2"

  # The package declares an executable with a name of its own.
  write_accredited_package "$prefix" "2.1.4" "$FIXTURE_DECLARED_BIN_ALTERNATIVE"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" --version || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "declared-bin: rc 0"
  else
    fail "declared-bin: the launcher resolved the executable declared by the package (rc=$rc)"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  assert_argv "declared-bin" "--standalone --version" "$sandbox"
  assert_no_decoy "declared-bin" "$sandbox"
}

# ---------------------------------------------------------------------------
# Case (B7): the layout and the resolution are right, but the installed
# package is NOT the pinned one: the package.json must accredit
# @opencode/cli@2.1.4.
# ---------------------------------------------------------------------------
test_wrong_package_version_is_rejected_without_execution() {
  local sandbox="$WORKDIR/wrong-version"
  local home
  home="$(make_sandbox "$sandbox")"
  local prefix
  prefix="$home/.local/share/forge/opencode-v2"

  write_accredited_package "$prefix" "2.1.3"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" --help || rc=$?

  if [ "$rc" -eq 1 ]; then
    pass "wrong-version: rc 1"
  else
    fail "wrong-version: expected rc 1, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if grep -qF "no se pudo acreditar el paquete OpenCode 2.1.4" "$sandbox/stderr.txt"; then
    pass "wrong-version: the diagnostic explains the rejection"
  else
    fail "wrong-version: the diagnostic does not explain the rejection"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if ! grep -qF "ARGV=" "$sandbox/stdout.txt"; then
    pass "wrong-version: the pinned binary was never executed"
  else
    fail "wrong-version: the pinned binary was never executed"
    sed -n '1,5p' "$sandbox/stdout.txt" | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# Case (B8): the accredited package under a CUSTOM prefix is accepted: the
# accreditation demands the LAYOUT, not a particular directory.
# ---------------------------------------------------------------------------
test_custom_prefix_is_accepted() {
  local sandbox="$WORKDIR/custom-prefix"
  local home
  home="$(make_sandbox "$sandbox")"
  local prefix="$sandbox/custom-prefix"

  write_accredited_package "$prefix"
  write_manifest "$home" "$home/.config/opencode-forge" \
    "$prefix/node_modules/.bin/opencode"

  local rc=0
  run_launcher "$sandbox" "$sandbox/work" mcp || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "custom-prefix: rc 0"
  else
    fail "custom-prefix: expected rc 0, got $rc"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  assert_argv "custom-prefix" "mcp" "$sandbox"
  assert_no_decoy "custom-prefix" "$sandbox"
}

# ---------------------------------------------------------------------------
# Sensitivity of the accreditation gate: each BROKEN accreditation must make
# this suite FAIL, and the failure must be attributed to the EXPECTED case.
#
# The mutation is applied to a COPY of the launcher inside the sandbox of the
# mutated run: the repository is never modified.
# ---------------------------------------------------------------------------
test_the_suite_detects_each_broken_accreditation() {
  local suite="$FORGE_ROOT/tests/launcher_relative_path_unit.sh"
  local mutation expected output rc

  for mutation in \
    drop-package-accreditation \
    drop-resolution-checks \
    drop-version-check \
    hardcode-declared-bin; do
    case "$mutation" in
      drop-package-accreditation)
        expected="FAIL: external-binary: the external binary was never executed"
        ;;
      drop-resolution-checks)
        expected="FAIL: decoy-bin: the decoy was never executed"
        ;;
      drop-version-check)
        expected="FAIL: wrong-version: the pinned binary was never executed"
        ;;
      hardcode-declared-bin)
        expected="FAIL: declared-bin: the launcher resolved the executable declared by the package"
        ;;
    esac

    rc=0
    output="$(FORGE_TEST_LAUNCHER_MUTATION="$mutation" bash "$suite" </dev/null 2>&1)" || rc=$?

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

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------
echo "=== launcher_relative_path_unit.sh ==="

mkdir -p "$TMPDIR_BASE"
WORKDIR="$(mktemp -d "$TMPDIR_BASE/forge-launcher-paths.$$-XXXXXX")"

# A mutation that CANNOT be applied would make the mutated run
# indistinguishable from the control, so the suite refuses to run: the
# mutation is validated ONCE, before any case executes.
if [ -n "$FORGE_TEST_LAUNCHER_MUTATION" ]; then
  mutation_scratch="$(mktemp -d "$TMPDIR_BASE/forge-launcher-mutation.$$-XXXXXX")"
  cp "$LAUNCHER_SRC_DIR/forge-opencode.sh" "$mutation_scratch/forge-opencode.sh"
  if ! apply_launcher_mutation "$mutation_scratch/forge-opencode.sh" \
    "$FORGE_TEST_LAUNCHER_MUTATION"; then
    echo "  FAIL: the mutation '$FORGE_TEST_LAUNCHER_MUTATION' could not be applied" >&2
    rm -rf "$mutation_scratch"
    exit 1
  fi
  rm -rf "$mutation_scratch"
fi

run_test test_project_directory_receives_standalone
run_test test_unknown_argument_is_not_reinterpreted_as_a_path
run_test test_known_subcommands_keep_their_precedence
run_test test_root_options_are_not_broken
run_test test_external_binary_is_rejected_without_execution
run_test test_escaping_bin_entry_is_rejected_without_execution
run_test test_decoy_bin_entry_is_rejected_without_execution
run_test test_executable_is_resolved_from_the_declared_bin
run_test test_wrong_package_version_is_rejected_without_execution
run_test test_custom_prefix_is_accepted

# The sensitivity of the accreditation gate is measured by running THIS suite
# against a launcher whose accreditation is broken. It is skipped when the
# suite itself runs with a mutation, so the recursion stays bounded.
if [ -z "$FORGE_TEST_LAUNCHER_MUTATION" ]; then
  run_test test_the_suite_detects_each_broken_accreditation
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
