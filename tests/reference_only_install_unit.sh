#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/reference_only_install_unit.sh — Fixture of the selective REFERENCE
# distribution mode of the Claude installer:
#
#   bash install.sh install --target=claude --reference-only execute-plan/escalation-codes
#
# The fixture runs the REAL installer against a throw-away HOME and a
# disposable COPY of the repository (the repository itself is never modified).
# It proves that:
#
#   - the valid invocation creates ONLY the link declared in
#     shared/components/commands.json, inside the REGISTERED Claude target;
#   - the ONLY state records that change are the ones of that link: the
#     relative list and the object list of the Claude target, and the global
#     absolute aggregate. The OpenCode entry, the components, the settings,
#     the RTK block, the version, the dates and the unknown metadata of the
#     user stay SEMANTICALLY identical;
#   - every other entry of the tree is untouched (path, mode, size, mtime and
#     content hash) and no directory appears or disappears;
#   - every rejected invocation fails with a non-zero code and writes NOTHING;
#   - the second run changes nothing at all (byte and mtime of the state);
#   - a controlled failure of the atomic publication leaves the state
#     RESTORED and the created link removed;
#   - the resulting state is still a valid, readable schema-3 state;
#   - the installer of the OpenCode binary, the RTK installer, the
#     authentication and the API key setup are NEVER reached.
#
# The real installation (~/.claude, ~/.config/opencode-forge and
# ~/.forge-state.json) is never written: the suite fingerprints it before and
# after and compares the fingerprints.
#
# Compatible with bash 3.2+.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"

REF_ID="execute-plan/escalation-codes"
REF_SRC_REL="shared/reference/escalation-codes.md"
REF_DEST_REL="skills/execute-plan/reference/escalation-codes.md"

# Optional mutation applied to the COPY of the production installer inside the
# sandbox. It exists so the sensitivity of this suite can be proven without
# touching the repository: the repository copy is the only thing mutated.
FORGE_TEST_INSTALL_MUTATION="${FORGE_TEST_INSTALL_MUTATION:-}"

FAIL=0
PASS=0

WORKDIR=""
TMPDIR_BASE="/tmp/opencode"
REAL_HOME="${FORGE_TEST_REAL_HOME:-$HOME}"
REAL_STATE="$REAL_HOME/.forge-state.json"
REAL_CLAUDE_REF="$REAL_HOME/.claude/skills/execute-plan/reference"
REAL_OVERLAY="$REAL_HOME/.config/opencode-forge"

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
# Tree and state fingerprints.
#
# snapshot_tree <root> <out> [excluded-relative-path...]
# One line per regular file and symbolic link:
#   F <path> <mode> <size> <mtime> <sha256>
#   L <path> <mode> <link-target>
# The excluded paths are given RELATIVE to <root> and are skipped.
# ---------------------------------------------------------------------------
snapshot_tree() {
  local root="$1" out="$2"
  shift 2
  local -a excludes=("$@")
  (
    cd "$root" || exit 1
    find . -mindepth 1 \( -type f -o -type l \) -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' path; do
          skip=no
          for ex in "${excludes[@]}"; do
            [ "$path" = "$ex" ] && skip=yes
          done
          [ "$skip" = yes ] && continue
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

# ---------------------------------------------------------------------------
# The disposable copy of the repository under test.
#
# The copy is what makes the mutation check possible without touching the
# repository, and it is also where the forbidden installers are stubbed: the
# stub RECORDS the invocation instead of installing anything, so the assertion
# "the OpenCode installer was never reached" is an observation, not an
# inference.
# ---------------------------------------------------------------------------
make_repo_fixture() {
  local dest="$1" item
  mkdir -p "$dest"
  cp "$FORGE_ROOT/install.sh" "$dest/install.sh"
  for item in lib open-code shared agents skills rtk; do
    cp -R "$FORGE_ROOT/$item" "$dest/"
  done

  cat > "$dest/open-code/install-opencode.sh" <<EOF
#!/usr/bin/env bash
printf 'opencode-installer-invoked %s\n' "\$*" >> "$dest/opencode-installer-invoked"
exit 0
EOF
  chmod +x "$dest/open-code/install-opencode.sh"

  cat > "$dest/open-code/uninstall-opencode.sh" <<EOF
#!/usr/bin/env bash
printf 'opencode-uninstaller-invoked %s\n' "\$*" >> "$dest/opencode-uninstaller-invoked"
exit 0
EOF
  chmod +x "$dest/open-code/uninstall-opencode.sh"

  cat > "$dest/rtk/install-rtk.sh" <<EOF
#!/usr/bin/env bash
printf 'rtk-installer-invoked %s\n' "\$*" >> "$dest/rtk-installer-invoked"
exit 0
EOF
  chmod +x "$dest/rtk/install-rtk.sh"

  apply_install_mutation "$dest/install.sh" "$FORGE_TEST_INSTALL_MUTATION"

  printf '%s\n' "$dest"
}

# apply_install_mutation <install.sh copy> <mutation>
#
# drop-foreign-state: the publication of the state drops every field that is
# not one of the four it knows about. The foreign metadata of the user (the
# OpenCode entry, the settings, the RTK block, the dates and the unknown
# fields) is therefore LOST, which is exactly the regression this suite must
# detect.
apply_install_mutation() {
  local install_sh="$1" mutation="$2"
  case "$mutation" in
    "") return 0 ;;
    drop-foreign-state)
      python3 - "$install_sh" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = "        | .symlinks = (if (.symlinks | index($absolute)) == null then .symlinks + [$absolute] else .symlinks end)\n"
mutated = anchor + "        | {version, state_schema, targets, symlinks, targets_manifest}\n"
if anchor not in text:
    sys.stderr.write("mutation anchor not found in the installer copy\n")
    raise SystemExit(2)
text = text.replace(anchor, mutated, 1)
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text)
PY
      ;;
    drop-opencode-entry)
      python3 - "$install_sh" <<'PY'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()

anchor = (
    "          else . end\n"
    "        )\n"
    "        | .symlinks = (if (.symlinks | index($absolute)) == null then .symlinks + [$absolute] else .symlinks end)\n"
)
mutated = (
    "          else empty end\n"
    "        )\n"
    "        | .symlinks = (if (.symlinks | index($absolute)) == null then .symlinks + [$absolute] else .symlinks end)\n"
)
if anchor not in text:
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
# The state fixture: a MIXED Claude/OpenCode installation with extra metadata.
# ---------------------------------------------------------------------------
write_state_fixture() {
  local home="$1"
  local claude="$home/.claude"
  local overlay="$home/.config/opencode-forge"
  local prefix="$home/.local/share/forge/opencode-v2/node_modules/.bin/opencode"

  jq -n \
    --arg claude "$claude" \
    --arg overlay "$overlay" \
    --arg prefix "$prefix" \
    '{
      version: "0.8.2",
      installed_at: "2026-10-01T09:00:00Z",
      state_schema: 3,
      targets: ["claude", "opencode"],
      symlinks: [
        ($claude + "/agents/senior.md"),
        ($claude + "/skills/execute-plan/SKILL.md"),
        ($claude + "/skills/execute-plan/reference/batch-algorithm.md"),
        ($claude + "/skills/execute-plan/reference/review-template.md")
      ],
      targets_manifest: [
        {
          name: "claude",
          dir: $claude,
          symlinks: [
            "agents/senior.md",
            "skills/execute-plan/SKILL.md",
            "skills/execute-plan/reference/batch-algorithm.md",
            "skills/execute-plan/reference/review-template.md"
          ],
          symlinks_objects: [
            {src: "agents/senior.md", dest: "agents/senior.md"},
            {src: "skills/execute-plan/SKILL.md", dest: "skills/execute-plan/SKILL.md"},
            {src: "skills/execute-plan/reference/batch-algorithm.md", dest: "skills/execute-plan/reference/batch-algorithm.md"},
            {src: "skills/execute-plan/reference/review-template.md", dest: "skills/execute-plan/reference/review-template.md"}
          ],
          components: ["agents", "commands", "statusline"],
          settings_merged: true,
          settings_backup: null
        },
        {
          name: "opencode",
          dir: $overlay,
          config_file: ($overlay + "/opencode.jsonc"),
          binary: $prefix,
          symlinks: [],
          symlinks_objects: [],
          components: [],
          settings_merged: false,
          settings_backup: null
        }
      ],
      settings: {
        managed_paths: {},
        overlay_backup: {claude: {}},
        settings_json_backup: {claude: ($claude + "/settings.json.pre-forge")}
      },
      rtk: {
        pinned_version: "0.43.0",
        detected_version: null,
        installed_by_us: false,
        install_failed: false,
        version_mismatch: false
      },
      custom_metadata: {owner: "platform-team", ticket: "FORGE-1234", keep: ["a", "b"]},
      unknown_future_field: {nested: {deep: [1, 2, 3]}}
    }' > "$home/.forge-state.json"
}

# ---------------------------------------------------------------------------
# The sandbox: a throw-away HOME with a pre-existing Claude installation.
# ---------------------------------------------------------------------------
make_sandbox() {
  local sandbox="$1"
  local home="$sandbox/home"
  local repo="$sandbox/repo"

  mkdir -p "$home/.claude/skills/execute-plan/reference" \
    "$home/.claude/agents" \
    "$home/.config/opencode-forge" \
    "$home/.cache" \
    "$home/.local/share" \
    "$home/.local/state" \
    "$sandbox/fakebin"

  repo="$(make_repo_fixture "$repo")"

  # The pre-existing installation: the links of the target and a settings file
  # that the mode must not touch.
  ln -s "$repo/agents/senior.md" "$home/.claude/agents/senior.md"
  ln -s "$repo/skills/execute-plan/SKILL.md" "$home/.claude/skills/execute-plan/SKILL.md"
  ln -s "$repo/skills/execute-plan/reference/batch-algorithm.md" \
    "$home/.claude/skills/execute-plan/reference/batch-algorithm.md"
  ln -s "$repo/skills/execute-plan/reference/review-template.md" \
    "$home/.claude/skills/execute-plan/reference/review-template.md"
  printf '{"model":"fixture"}\n' > "$home/.claude/settings.json"
  printf '{}\n' > "$home/.config/opencode-forge/opencode.jsonc"

  write_state_fixture "$home"

  # A fake npm: the pinned binary installer must never be reached.
  cat > "$sandbox/fakebin/npm" <<EOF
#!/usr/bin/env sh
printf 'npm was invoked: %s\n' "\$*" > "$sandbox/npm-was-invoked"
exit 0
EOF
  chmod +x "$sandbox/fakebin/npm"

  printf '%s\n' "$home"
}

# run_reference_only <sandbox> [args...]
#
# The installer runs with a throw-away HOME and throw-away XDG directories.
# The stdout and the stderr of the run are kept apart.
run_reference_only() {
  local sandbox="$1"
  shift
  local home="$sandbox/home"
  (
    cd "$sandbox" || exit 1
    env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
      -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY -u MINIMAX_API_KEY \
      HOME="$home" \
      XDG_CONFIG_HOME="$home/.config" \
      XDG_CACHE_HOME="$home/.cache" \
      XDG_DATA_HOME="$home/.local/share" \
      XDG_STATE_HOME="$home/.local/state" \
      PATH="$sandbox/fakebin:$PATH" \
      bash "$sandbox/repo/install.sh" install "$@"
  ) > "$sandbox/stdout.txt" 2> "$sandbox/stderr.txt"
}

# assert_no_key_signals <sandbox> <label>
assert_no_key_signals() {
  local sandbox="$1" label="$2"
  local signal found=no
  local -a signals=(
    'api key'
    'api-key'
    'apikey'
    'API_KEY'
    'provider'
    'npm install'
    '@opencode/cli'
    'anthropic'
    'authentication'
    'autentic'
    'OPENAI_API_KEY'
  )
  for signal in "${signals[@]}"; do
    if grep -qiF "$signal" "$sandbox/stdout.txt" "$sandbox/stderr.txt" 2>/dev/null; then
      echo "      signal found: $signal"
      found=yes
    fi
  done
  if [ "$found" = no ]; then
    pass "$label: no API key, provider or authentication signal in the output"
  else
    fail "$label: the output asks for an API key or mentions a provider"
  fi
}

# assert_no_installer_reached <sandbox> <label>
assert_no_installer_reached() {
  local sandbox="$1" label="$2"
  local marker
  for marker in \
      "$sandbox/repo/opencode-installer-invoked" \
      "$sandbox/repo/opencode-uninstaller-invoked" \
      "$sandbox/repo/rtk-installer-invoked" \
      "$sandbox/npm-was-invoked"; do
    if [ -e "$marker" ]; then
      fail "$label: an installer was reached: $marker"
      return
    fi
  done
  pass "$label: no OpenCode installer, no RTK installer and no npm invocation"
}

# assert_state_valid <state> <label>
#
# The same validation the production mode applies, plus the schema and the
# readability of the document.
assert_state_valid() {
  local state="$1" label="$2"
  if jq empty "$state" >/dev/null 2>&1; then
    pass "$label: the state is readable JSON"
  else
    fail "$label: the state is not readable JSON"
    return
  fi
  if jq -e '.state_schema == 3' "$state" >/dev/null 2>&1; then
    pass "$label: the state keeps the schema 3"
  else
    fail "$label: the state lost the schema 3"
  fi
  if jq -e '
      type == "object" and
      .state_schema == 3 and
      (.targets | type == "array" and ([.[] | select(. == "claude")] | length) == 1) and
      (.targets_manifest | type == "array") and
      ([.targets_manifest[] | select(.name == "claude")] | length) == 1 and
      (.symlinks | type == "array" and all(.[]; type == "string")) and
      ([.targets_manifest[] | select(.name == "claude")][0] |
        (.dir | type == "string" and startswith("/") and length > 1) and
        (.components | type == "array" and index("commands") != null) and
        (.symlinks | type == "array" and all(.[]; type == "string")) and
        (.symlinks_objects | type == "array" and
          all(.[]; type == "object" and (.src | type == "string") and (.dest | type == "string")))
      )
    ' "$state" >/dev/null 2>&1; then
    pass "$label: the state satisfies the schema-3 contract of the mode"
  else
    fail "$label: the state does not satisfy the schema-3 contract of the mode"
  fi
}

# ---------------------------------------------------------------------------
# Case (a): the valid invocation in a MIXED state with extra metadata.
# ---------------------------------------------------------------------------
test_valid_invocation_creates_only_the_declared_reference() {
  local sandbox="$WORKDIR/valid"
  local home claude link abs_link
  home="$(make_sandbox "$sandbox")"
  claude="$home/.claude"
  link="$claude/$REF_DEST_REL"
  abs_link="$link"

  local state="$home/.forge-state.json"
  jq -S . "$state" > "$sandbox/state.before.json"
  jq -S '[.targets_manifest[] | select(.name == "opencode")]' "$state" \
    > "$sandbox/opencode.before.json"
  jq -S '{custom_metadata, unknown_future_field, settings, rtk, version, installed_at}' "$state" \
    > "$sandbox/foreign.before.json"

  local rc=0
  run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "valid: rc 0"
  else
    fail "valid: expected rc 0, got $rc"
    sed -n '1,10p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  if [ -L "$link" ]; then
    pass "valid: the reference is a symbolic link"
  else
    fail "valid: the reference is not a symbolic link"
  fi

  if [ "$(readlink "$link" 2>/dev/null || true)" = "$sandbox/repo/$REF_SRC_REL" ]; then
    pass "valid: the link points to the declared source ($REF_SRC_REL)"
  else
    fail "valid: the link does not point to the declared source"
  fi

  if [ -f "$link" ] && cmp -s "$sandbox/repo/$REF_SRC_REL" "$link"; then
    pass "valid: the link resolves to the real reference content"
  else
    fail "valid: the link does not resolve to the real reference content"
  fi

  # Only the records of that link may change.
  if jq -e --arg dest "$REF_DEST_REL" --arg abs "$abs_link" '
      ([.targets_manifest[] | select(.name == "claude")][0].symlinks | index($dest)) != null and
      ([.targets_manifest[] | select(.name == "claude")][0].symlinks_objects |
        map(select(.dest == $dest and .src == "shared/reference/escalation-codes.md")) | length) == 1 and
      (.symlinks | index($abs)) != null
    ' "$state" >/dev/null 2>&1; then
    pass "valid: the state records the link in the three allowed places"
  else
    fail "valid: the state does not record the link in the three allowed places"
  fi

  # The OpenCode entry is semantically identical.
  jq -S '[.targets_manifest[] | select(.name == "opencode")]' "$state" \
    > "$sandbox/opencode.after.json"
  if cmp -s "$sandbox/opencode.before.json" "$sandbox/opencode.after.json"; then
    pass "valid: the OpenCode entry of the state is semantically identical"
  else
    fail "valid: the OpenCode entry of the state changed"
    diff -u "$sandbox/opencode.before.json" "$sandbox/opencode.after.json" \
      | sed 's/^/      /' >&2 || true
  fi

  # The foreign metadata is semantically identical.
  jq -S '{custom_metadata, unknown_future_field, settings, rtk, version, installed_at}' "$state" \
    > "$sandbox/foreign.after.json"
  if cmp -s "$sandbox/foreign.before.json" "$sandbox/foreign.after.json"; then
    pass "valid: the unknown fields, the settings, the RTK block, the version and the dates are identical"
  else
    fail "valid: the unknown fields, the settings, the RTK block, the version or the dates changed"
    diff -u "$sandbox/foreign.before.json" "$sandbox/foreign.after.json" \
      | sed 's/^/      /' >&2 || true
  fi

  # The components of the Claude target are preserved.
  if jq -e '[.targets_manifest[] | select(.name == "claude")][0].components == ["agents","commands","statusline"]' \
    "$state" >/dev/null 2>&1; then
    pass "valid: the components of the Claude target are preserved"
  else
    fail "valid: the components of the Claude target changed"
  fi

  assert_no_installer_reached "$sandbox" "valid"
  assert_no_key_signals "$sandbox" "valid"

  if [ ! -e "$home/.local/share/forge" ]; then
    pass "valid: the pinned OpenCode prefix was not created"
  else
    fail "valid: the pinned OpenCode prefix was created"
  fi

  if [ "$(cat "$home/.claude/settings.json" 2>/dev/null || true)" = '{"model":"fixture"}' ]; then
    pass "valid: the settings of the target were not touched"
  else
    fail "valid: the settings of the target changed"
  fi

  assert_state_valid "$state" "valid"
}

# ---------------------------------------------------------------------------
# Case (b): nothing changes outside the allowed list.
# ---------------------------------------------------------------------------
test_nothing_changes_outside_the_allowed_list() {
  local sandbox="$WORKDIR/inventory"
  local home state
  home="$(make_sandbox "$sandbox")"
  state="$home/.forge-state.json"

  # The state file is compared separately (semantically): it is the one file
  # the mode is allowed to rewrite.
  snapshot_tree "$home" "$sandbox/before.txt" "./.forge-state.json"
  snapshot_dirs "$home" "$sandbox/before.dirs"
  jq -S . "$state" > "$sandbox/state.before.json"

  local rc=0
  run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "inventory: expected rc 0, got $rc"
    return
  fi
  pass "inventory: rc 0"

  snapshot_tree "$home" "$sandbox/after.txt" "./.forge-state.json" \
    "./.claude/$REF_DEST_REL"
  snapshot_dirs "$home" "$sandbox/after.dirs"

  # The tree: only the new link may appear.
  if diff -u "$sandbox/before.txt" "$sandbox/after.txt" > "$sandbox/tree.diff" 2>&1; then
    pass "inventory: no file or link of the tree changed besides the new one"
  else
    fail "inventory: some other entry of the tree changed"
    sed -n '1,20p' "$sandbox/tree.diff" | sed 's/^/      /' >&2
  fi

  if diff -u "$sandbox/before.dirs" "$sandbox/after.dirs" > "$sandbox/dirs.diff" 2>&1; then
    pass "inventory: no directory appeared or disappeared"
  else
    fail "inventory: the set of directories changed"
    sed -n '1,20p' "$sandbox/dirs.diff" | sed 's/^/      /' >&2
  fi

  # The state: removing the three allowed records must give the state that
  # was there before, key for key and value for value.
  local abs_link="$home/.claude/$REF_DEST_REL"
  jq -S --arg dest "$REF_DEST_REL" --arg abs "$abs_link" '
      .symlinks = (.symlinks | map(select(. != $abs))) |
      .targets_manifest = (.targets_manifest | map(
        if .name == "claude" then
          .symlinks = (.symlinks | map(select(. != $dest))) |
          .symlinks_objects = (.symlinks_objects | map(select(.dest != $dest)))
        else . end))
    ' "$state" > "$sandbox/state.minus-allowed.json"

  if cmp -s "$sandbox/state.before.json" "$sandbox/state.minus-allowed.json"; then
    pass "inventory: the state minus the allowed records is the previous state, key for key"
  else
    fail "inventory: the state changed outside the allowed records"
    diff -u "$sandbox/state.before.json" "$sandbox/state.minus-allowed.json" \
      | sed 's/^/      /' >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# Case (c): the second run changes nothing.
# ---------------------------------------------------------------------------
test_second_run_is_idempotent() {
  local sandbox="$WORKDIR/idempotent"
  local home state
  home="$(make_sandbox "$sandbox")"
  state="$home/.forge-state.json"

  local rc=0
  run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "idempotent: the first run failed (rc=$rc)"
    return
  fi

  local state_hash state_mtime
  state_hash="$(sha256sum "$state" | cut -d' ' -f1)"
  state_mtime="$(stat -c '%y' "$state")"
  snapshot_tree "$home" "$sandbox/after-first.txt"

  rc=0
  run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "idempotent: the second run exits 0"
  else
    fail "idempotent: the second run exited $rc"
  fi

  if [ "$(sha256sum "$state" | cut -d' ' -f1)" = "$state_hash" ]; then
    pass "idempotent: the state is byte identical after the second run"
  else
    fail "idempotent: the state changed in the second run"
  fi

  if [ "$(stat -c '%y' "$state")" = "$state_mtime" ]; then
    pass "idempotent: the state was not even rewritten (mtime unchanged)"
  else
    fail "idempotent: the state was rewritten in the second run"
  fi

  snapshot_tree "$home" "$sandbox/after-second.txt"
  if cmp -s "$sandbox/after-first.txt" "$sandbox/after-second.txt"; then
    pass "idempotent: no file of the tree changed in the second run"
  else
    fail "idempotent: some file of the tree changed in the second run"
    diff -u "$sandbox/after-first.txt" "$sandbox/after-second.txt" \
      | sed 's/^/      /' >&2 || true
  fi

  if grep -qF "reference already installed and registered" "$sandbox/stdout.txt"; then
    pass "idempotent: the second run reports that the reference is already installed"
  else
    fail "idempotent: the second run does not report the installed reference"
  fi
}

# ---------------------------------------------------------------------------
# Case (d): every rejected invocation fails and writes NOTHING.
# ---------------------------------------------------------------------------
# assert_rejected <label> <expected-diagnostic> [args...]
assert_rejected() {
  local label="$1" message="$2"
  shift 2
  local sandbox="$WORKDIR/rejected-$label"
  local home state
  home="$(make_sandbox "$sandbox")"
  state="$home/.forge-state.json"

  snapshot_tree "$home" "$sandbox/before.txt"
  snapshot_dirs "$home" "$sandbox/before.dirs"

  local rc=0
  run_reference_only "$sandbox" "$@" || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "$label: rc != 0 (got $rc)"
  else
    fail "$label: expected rc != 0, got 0"
  fi

  if grep -qF -- "$message" "$sandbox/stderr.txt"; then
    pass "$label: the diagnostic explains the rejection"
  else
    fail "$label: the diagnostic does not explain the rejection"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi

  snapshot_tree "$home" "$sandbox/after.txt"
  snapshot_dirs "$home" "$sandbox/after.dirs"

  if cmp -s "$sandbox/before.txt" "$sandbox/after.txt"; then
    pass "$label: nothing was written (tree, state and mtimes identical)"
  else
    fail "$label: something was written"
    diff -u "$sandbox/before.txt" "$sandbox/after.txt" | sed 's/^/      /' >&2 || true
  fi

  if cmp -s "$sandbox/before.dirs" "$sandbox/after.dirs"; then
    pass "$label: no directory appeared"
  else
    fail "$label: a directory appeared"
  fi

  if [ ! -e "$home/.claude/$REF_DEST_REL" ]; then
    pass "$label: the reference was not created"
  else
    fail "$label: the reference was created"
  fi

  assert_no_installer_reached "$sandbox" "$label"
  assert_no_key_signals "$sandbox" "$label"
}

test_rejected_inputs() {
  assert_rejected "unknown-reference" \
    "referencia --reference-only no permitida" \
    --target=claude --reference-only "execute-plan/does-not-exist"

  assert_rejected "path-shaped-reference" \
    "referencia --reference-only no permitida" \
    --target=claude --reference-only "shared/reference/escalation-codes.md"

  assert_rejected "parent-relative-reference" \
    "referencia --reference-only no permitida" \
    --target=claude --reference-only "../execute-plan/escalation-codes"

  assert_rejected "absolute-reference" \
    "referencia --reference-only no permitida" \
    --target=claude --reference-only "/etc/escalation-codes"

  assert_rejected "wrong-target-opencode" \
    "argumento no permitido con --reference-only" \
    --target=opencode --reference-only "$REF_ID"

  assert_rejected "wrong-target-both" \
    "argumento no permitido con --reference-only" \
    --target=both --reference-only "$REF_ID"

  assert_rejected "extra-argument" \
    "argumento no permitido con --reference-only" \
    --target=claude --reference-only "$REF_ID" extra

  assert_rejected "missing-reference-value" \
    "--reference-only requiere exactamente un identificador de referencia" \
    --target=claude --reference-only

  assert_rejected "duplicated-reference-flag" \
    "--reference-only requiere exactamente un identificador de referencia" \
    --target=claude --reference-only "$REF_ID" --reference-only "$REF_ID"

  assert_rejected "missing-target" \
    "use --target=claude --reference-only execute-plan/escalation-codes" \
    --reference-only "$REF_ID"
}

# The destination occupied by a foreign element is a conflict, not a repair.
test_rejected_destination_conflicts() {
  # A regular file at the destination.
  local sandbox="$WORKDIR/conflict-file"
  local home
  home="$(make_sandbox "$sandbox")"
  printf 'not a link\n' > "$home/.claude/$REF_DEST_REL"

  local rc=0
  run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "conflict-file: rc != 0 (got $rc)"
  else
    fail "conflict-file: expected rc != 0, got 0"
  fi
  if grep -qF "destino de referencia ocupado por un elemento ajeno" "$sandbox/stderr.txt"; then
    pass "conflict-file: the diagnostic explains the conflict"
  else
    fail "conflict-file: the diagnostic does not explain the conflict"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi
  if [ -f "$home/.claude/$REF_DEST_REL" ] && [ ! -L "$home/.claude/$REF_DEST_REL" ]; then
    pass "conflict-file: the foreign element was neither replaced nor followed"
  else
    fail "conflict-file: the foreign element was replaced"
  fi
  if jq -e --arg dest "$REF_DEST_REL" \
      '[.targets_manifest[] | select(.name == "claude")][0].symlinks | index($dest) == null' \
      "$home/.forge-state.json" >/dev/null 2>&1; then
    pass "conflict-file: the state was not modified"
  else
    fail "conflict-file: the state was modified"
  fi

  # A link that points somewhere else.
  sandbox="$WORKDIR/conflict-link"
  home="$(make_sandbox "$sandbox")"
  ln -s "$sandbox/repo/skills/execute-plan/SKILL.md" "$home/.claude/$REF_DEST_REL"

  rc=0
  run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "conflict-link: rc != 0 (got $rc)"
  else
    fail "conflict-link: expected rc != 0, got 0"
  fi
  if grep -qF "enlace inesperado en el destino de la referencia" "$sandbox/stderr.txt"; then
    pass "conflict-link: the diagnostic explains the conflict"
  else
    fail "conflict-link: the diagnostic does not explain the conflict"
    sed -n '1,5p' "$sandbox/stderr.txt" | sed 's/^/      /' >&2
  fi
  if [ "$(readlink "$home/.claude/$REF_DEST_REL" 2>/dev/null || true)" = "$sandbox/repo/skills/execute-plan/SKILL.md" ]; then
    pass "conflict-link: the unexpected link was neither replaced nor followed"
  else
    fail "conflict-link: the unexpected link was replaced"
  fi
}

# ---------------------------------------------------------------------------
# Case (e): a controlled failure of the atomic publication.
# ---------------------------------------------------------------------------
make_failing_mv() {
  local sandbox="$1" mode="$2"
  local real_mv
  real_mv="$(command -v mv)"
  cat > "$sandbox/fakebin/mv" <<EOF
#!/usr/bin/env sh
# Fake mv: the atomic publication of the state fails in a controlled way.
#
#   plain   — the publication fails and the state is left untouched.
#   corrupt — the publication replaces the state and then fails, so the
#             installer must restore the original bytes.
mode="$mode"
real_mv="$real_mv"
src=""
dest=""
for arg in "\$@"; do
  case "\$arg" in
    -*) continue ;;
  esac
  if [ -z "\$src" ]; then src="\$arg"; else dest="\$arg"; fi
done
case "\$dest" in
  *.forge-state.json)
    if [ "\$mode" = "corrupt" ]; then
      cp -p "\$src" "\$dest" || exit 1
    fi
    printf 'fake-mv: refusing to publish %s\n' "\$dest" >&2
    exit 1
    ;;
esac
exec "\$real_mv" "\$@"
EOF
  chmod +x "$sandbox/fakebin/mv"
}

test_controlled_failure_at_state_publication() {
  local mode
  for mode in plain corrupt; do
    local sandbox="$WORKDIR/publish-failure-$mode"
    local home state
    home="$(make_sandbox "$sandbox")"
    state="$home/.forge-state.json"
    make_failing_mv "$sandbox" "$mode"

    local state_hash
    state_hash="$(sha256sum "$state" | cut -d' ' -f1)"

    local rc=0
    run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?

    if [ "$rc" -ne 0 ]; then
      pass "publish-failure-$mode: rc != 0 (got $rc)"
    else
      fail "publish-failure-$mode: expected rc != 0, got 0"
    fi

    if [ "$(sha256sum "$state" | cut -d' ' -f1)" = "$state_hash" ]; then
      pass "publish-failure-$mode: the state is restored byte for byte"
    else
      fail "publish-failure-$mode: the state was not restored"
    fi

    if [ ! -e "$home/.claude/$REF_DEST_REL" ]; then
      pass "publish-failure-$mode: the created link was removed"
    else
      fail "publish-failure-$mode: the created link survived"
    fi

    local leftovers
    leftovers="$(find "$home" -maxdepth 1 \
      \( -name '.forge-state.json.reference-only.*' -o -name '.forge-state.json.reference-backup.*' \) \
      -print)"
    if [ -z "$leftovers" ]; then
      pass "publish-failure-$mode: no temporary state file was left behind"
    else
      fail "publish-failure-$mode: a temporary state file survived: $leftovers"
    fi
  done
}

# ---------------------------------------------------------------------------
# Case (f): the resulting state is still valid.
# ---------------------------------------------------------------------------
test_resulting_state_is_valid() {
  local sandbox="$WORKDIR/valid-state"
  local home state
  home="$(make_sandbox "$sandbox")"
  state="$home/.forge-state.json"

  local rc=0
  run_reference_only "$sandbox" --target=claude --reference-only "$REF_ID" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "valid-state: the run failed (rc=$rc)"
    return
  fi

  assert_state_valid "$state" "valid-state"

  if jq -e --arg dest "$REF_DEST_REL" '
      ([.targets_manifest[] | select(.name == "claude")][0].symlinks_objects |
        map(select(.dest == $dest)) | length) == 1
    ' "$state" >/dev/null 2>&1; then
    pass "valid-state: exactly one object record describes the reference"
  else
    fail "valid-state: the object records of the reference are ambiguous"
  fi

  if [ "$(jq -r '.targets_manifest | length' "$state")" = "2" ]; then
    pass "valid-state: both targets of the mixed state survive"
  else
    fail "valid-state: the mixed state lost a target"
  fi
}

# ---------------------------------------------------------------------------
# Safety: the real installation is never written by this suite.
# ---------------------------------------------------------------------------
test_real_installation_is_untouched() {
  if [ -f "$WORKDIR/real-state.before" ] && [ -f "$WORKDIR/real-state.after" ]; then
    if cmp -s "$WORKDIR/real-state.before" "$WORKDIR/real-state.after"; then
      pass "safety: the real state file is untouched by the suite"
    else
      fail "safety: the real state file changed during the suite"
    fi
  fi

  if [ -f "$WORKDIR/real-ref.before" ] && [ -f "$WORKDIR/real-ref.after" ]; then
    if cmp -s "$WORKDIR/real-ref.before" "$WORKDIR/real-ref.after"; then
      pass "safety: the references installed for the real Claude target are untouched"
    else
      fail "safety: the references of the real Claude target changed during the suite"
      diff -u "$WORKDIR/real-ref.before" "$WORKDIR/real-ref.after" \
        | sed 's/^/      /' >&2 || true
    fi
  fi

  if [ -f "$WORKDIR/real-overlay.before" ] && [ -f "$WORKDIR/real-overlay.after" ]; then
    if cmp -s "$WORKDIR/real-overlay.before" "$WORKDIR/real-overlay.after"; then
      pass "safety: the real OpenCode overlay is untouched by the suite"
    else
      fail "safety: the real OpenCode overlay changed during the suite"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------
echo "=== reference_only_install_unit.sh ==="

mkdir -p "$TMPDIR_BASE"
WORKDIR="$(mktemp -d "$TMPDIR_BASE/forge-reference-only.$$-XXXXXX")"

# Fingerprint of the real installation, before anything runs.
if [ -f "$REAL_STATE" ]; then
  sha256sum "$REAL_STATE" > "$WORKDIR/real-state.before"
fi
if [ -d "$REAL_CLAUDE_REF" ]; then
  ( cd "$REAL_CLAUDE_REF" && find . -mindepth 1 -maxdepth 1 -printf '%y %p %l\n' | LC_ALL=C sort ) \
    > "$WORKDIR/real-ref.before"
fi
if [ -d "$REAL_OVERLAY" ]; then
  ( cd "$REAL_OVERLAY" && find . -maxdepth 1 -mindepth 1 -printf '%y %m %p\n' | LC_ALL=C sort ) \
    > "$WORKDIR/real-overlay.before"
fi

run_test test_valid_invocation_creates_only_the_declared_reference
run_test test_nothing_changes_outside_the_allowed_list
run_test test_second_run_is_idempotent
run_test test_rejected_inputs
run_test test_rejected_destination_conflicts
run_test test_controlled_failure_at_state_publication
run_test test_resulting_state_is_valid

# Fingerprint of the real installation, after everything ran.
if [ -f "$REAL_STATE" ]; then
  sha256sum "$REAL_STATE" > "$WORKDIR/real-state.after"
fi
if [ -d "$REAL_CLAUDE_REF" ]; then
  ( cd "$REAL_CLAUDE_REF" && find . -mindepth 1 -maxdepth 1 -printf '%y %p %l\n' | LC_ALL=C sort ) \
    > "$WORKDIR/real-ref.after"
fi
if [ -d "$REAL_OVERLAY" ]; then
  ( cd "$REAL_OVERLAY" && find . -maxdepth 1 -mindepth 1 -printf '%y %m %p\n' | LC_ALL=C sort ) \
    > "$WORKDIR/real-overlay.after"
fi

run_test test_real_installation_is_untouched

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
