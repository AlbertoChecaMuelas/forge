#!/usr/bin/env bash
# tests/forge_guard_plugin_unit.sh — unit tests of the OpenCode 2 branch guard.
#
# The guard lives in open-code/plugin-packages/forge-guard/index.js and follows
# the OpenCode 2 plugin contract:
#
#   * the module exports a DEFAULT DEFINITION with an `id` and a `setup(ctx)`
#     function (OpenCode 1 exported a factory that returned the hooks),
#   * the veto is registered through `ctx.tool.hook("execute.before", ...)`,
#   * the OpenCode 2 tool is `shell` (OpenCode 1 called it `bash`) and its
#     command lives in `input.command`,
#   * every Git call runs in `ctx.location.directory`, never in the process
#     cwd of the OpenCode server.
#
# The plugin imports `@opencode/plugin` (provided by the OpenCode host
# runtime). The suite copies the real plugin package into a disposable
# directory next to a minimal stub of that runtime, so the module can be
# imported without installing anything and without shipping a copy of the
# runtime inside the repository.
#
# SAFETY ADAPTATION (forge-v2-followups, Step 3.1)
# -------------------------------------------------
# The suite is adapted, NOT disabled. Every assertion of the original suite is
# preserved, the real guard package is still the code under test (the only
# stub is the `@opencode/plugin` runtime package, exactly as before), and the
# guard policy is untouched. Only the disposable fixtures change, so that the
# suite can run without writing to a protected branch and without any remote
# write:
#
#   * NO `git push` is executed — not even to a local `file://` bare remote.
#     Every `git` in this suite, including the ones spawned by the plugin
#     itself, goes through a test shim that refuses `git push` with exit
#     status 97 and records the attempt in the operations log.
#   * NO commit is created while a protected branch (master/main/dev) is
#     selected. The guard decides from the branch name only
#     (`git symbolic-ref --short HEAD`), which resolves on an unborn branch,
#     so the protected-branch scenarios need no commit at all. The shim also
#     refuses `git commit` on a protected branch with exit status 96.
#   * The "already merged" scenario no longer pushes `feature:main` to a bare
#     remote. The very same observable state is produced locally with
#     `git update-ref refs/remotes/origin/main <sha>` plus
#     `git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main`,
#     which is exactly what `push` + `fetch` + `symbolic-ref` left behind
#     before. The bare remote is kept as a registered-but-empty `origin` and
#     the suite asserts afterwards that it received no refs and no objects.
#   * The strings that represent a forbidden operation ("git commit -m test")
#     are only passed to the captured `execute.before` callback as DATA; the
#     suite never executes them.
#
# Every git invocation (suite and plugin) is recorded in the operations log so
# the evidence can show the selected branch, the commits created, and that no
# push was attempted. The log layout is:
#
#   EVENT <TAB> SUBCOMMAND <TAB> DIRECTORY <TAB> BRANCH <TAB> ARGS
#
# The BRANCH is the FOURTH column (the THIRD one is the directory). The
# assertions that decide whether a commit happened on a protected branch read
# that FOURTH column, and two negative controls feed synthetic records to the
# very same predicate so the check can never degrade into a vacuous one.
#
# The log is printed at the end of the run and copied to $FORGE_GUARD_OPS_LOG
# when that variable points outside the disposable root.
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"
PLUGIN_SOURCE_DIR="$FORGE_ROOT/open-code/plugin-packages/forge-guard"
FAIL=0
PASS=0
SUITE_ROOT=""
OPS_LOG=""
REAL_GIT=""

# Disposable fixtures live under a dedicated temporary root, never inside the
# repository work tree.
TMP_BASE="${FORGE_GUARD_TMPDIR:-${TMPDIR:-/tmp}}"
case "$TMP_BASE" in
  "$FORGE_ROOT"|"$FORGE_ROOT"/*) TMP_BASE="/tmp" ;;
esac

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

cleanup() {
  if [ -n "$SUITE_ROOT" ] && [ -d "$SUITE_ROOT" ]; then
    rm -rf "$SUITE_ROOT"
  fi
}
trap cleanup EXIT

# prepare_plugin_sandbox
# Copies the real plugin package into a disposable directory, adds the
# minimal `@opencode/plugin` stub the module needs to be importable, and
# installs the `git` test shim that records every git operation and refuses
# the two operations the safety contract forbids.
prepare_plugin_sandbox() {
  SUITE_ROOT="$(mktemp -d "${TMP_BASE}/forge-guard-unit.XXXXXX")"
  mkdir -p "$SUITE_ROOT/repos" "$SUITE_ROOT/remotes" "$SUITE_ROOT/shim"

  if [ -n "${FORGE_GUARD_OPS_LOG:-}" ]; then
    OPS_LOG="$FORGE_GUARD_OPS_LOG"
  else
    OPS_LOG="$SUITE_ROOT/git-ops.log"
  fi
  : > "$OPS_LOG"

  # The real git binary must be resolved BEFORE the shim shadows the name.
  REAL_GIT="$(command -v git)"
  export FORGE_GUARD_REAL_GIT="$REAL_GIT"
  export FORGE_GUARD_OPS_LOG="$OPS_LOG"
  export PATH="$SUITE_ROOT/shim:$PATH"

  # git shim: records every invocation and refuses `git push` (any remote,
  # including local file:// ones) and `git commit` on a protected branch.
  cat > "$SUITE_ROOT/shim/git" <<'SHIM'
#!/usr/bin/env bash
# Test shim for `git`, generated by tests/forge_guard_plugin_unit.sh.
#
#  * it records every invocation (event, subcommand, directory, arguments);
#  * it refuses `git push` with exit status 97;
#  * it refuses `git commit` while master/main/dev is selected, status 96;
#  * everything else is forwarded verbatim to the real git binary.
#
# The shim does not alter the behaviour of the code under test: the guard
# plugin talks to the same git, only through this wrapper.
set -uo pipefail

REAL_GIT="${FORGE_GUARD_REAL_GIT:?FORGE_GUARD_REAL_GIT is not set}"
OPS_LOG="${FORGE_GUARD_OPS_LOG:?FORGE_GUARD_OPS_LOG is not set}"

orig_args=("$@")

dir="$(pwd -P 2>/dev/null || printf '%s' "$PWD")"
scan=("$@")
while [ "${#scan[@]}" -gt 0 ]; do
  case "${scan[0]}" in
    -C) dir="${scan[1]:-$dir}"; scan=("${scan[@]:2}") ;;
    -C*) dir="${scan[0]#-C}"; scan=("${scan[@]:1}") ;;
    *) scan=("${scan[@]:1}") ;;
  esac
done

sub=""
scan=("$@")
while [ "${#scan[@]}" -gt 0 ]; do
  case "${scan[0]}" in
    -C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)
      scan=("${scan[@]:2}") ;;
    -C*) scan=("${scan[@]:1}") ;;
    -*) scan=("${scan[@]:1}") ;;
    *) sub="${scan[0]}"; break ;;
  esac
done

args_text="$*"
branch="-"

if [ "$sub" = "push" ]; then
  printf 'PUSH_BLOCKED\tpush\t%s\t%s\t%s\n' "$dir" "$branch" "$args_text" >> "$OPS_LOG"
  echo "forge-guard test shim: refusing 'git push' (forbidden in this suite)" >&2
  exit 97
fi

if [ "$sub" = "commit" ]; then
  branch="$(cd "$dir" 2>/dev/null && "$REAL_GIT" symbolic-ref --short HEAD 2>/dev/null || true)"
  case "$branch" in
    master|main|dev)
      printf 'PROTECTED_COMMIT_BLOCKED\tcommit\t%s\t%s\t%s\n' \
        "$dir" "$branch" "$args_text" >> "$OPS_LOG"
      echo "forge-guard test shim: refusing 'git commit' on protected branch '$branch'" >&2
      exit 96
      ;;
  esac
fi

printf 'GIT\t%s\t%s\t%s\t%s\n' "$sub" "$dir" "$branch" "$args_text" >> "$OPS_LOG"
exec "$REAL_GIT" "${orig_args[@]}"
SHIM
  chmod +x "$SUITE_ROOT/shim/git"

  mkdir -p "$SUITE_ROOT/plugin-packages"
  cp -R "$PLUGIN_SOURCE_DIR" "$SUITE_ROOT/plugin-packages/forge-guard"

  mkdir -p "$SUITE_ROOT/node_modules/@opencode/plugin"
  cat > "$SUITE_ROOT/node_modules/@opencode/plugin/package.json" <<'EOF'
{
  "name": "@opencode/plugin",
  "version": "2.1.4",
  "type": "module",
  "main": "./index.js"
}
EOF
  cat > "$SUITE_ROOT/node_modules/@opencode/plugin/index.js" <<'EOF'
export const Plugin = { define: (definition) => definition }
EOF

  cat > "$SUITE_ROOT/check.mjs" <<'EOF'
import { pathToFileURL } from "node:url"

const pluginPath = `${process.env.TEST_PLUGIN_ROOT}/plugin-packages/forge-guard/index.js`
const pluginModule = await import(pathToFileURL(pluginPath).href)
const plugin = pluginModule.default

const testCase = process.env.TEST_CASE
const repoDir = process.env.TEST_REPO_DIR

function fail(message) {
  console.error(`FAIL: ${message}`)
  process.exit(1)
}

// makeHook registers the plugin against a fake OpenCode 2 context and
// returns the callback it registered.
async function makeHook(directory) {
  let hook = null
  const ctx = {
    location: { directory },
    tool: {
      hook: async (name, callback) => {
        if (name !== "execute.before") {
          throw new Error(`unexpected hook name: ${name}`)
        }
        hook = callback
        return { dispose: () => {} }
      },
    },
  }
  await plugin.setup(ctx)
  if (!hook) {
    throw new Error("the plugin did not register any hook")
  }
  return hook
}

async function callHook(hook, input) {
  try {
    await hook(input, {})
    return null
  } catch (error) {
    return error
  }
}

// The command below is DATA handed to the captured callback. The suite never
// executes it: the guard only has to decide whether it would be allowed.
const shellCommit = { tool: "shell", input: { command: "git commit -m test" } }

switch (testCase) {
  case "contract": {
    if (!plugin || typeof plugin !== "object") {
      fail("the default export is not a plugin definition")
    }
    if (plugin.id !== "forge-guard") {
      fail(`unstable plugin id: ${plugin.id}`)
    }
    if (typeof plugin.setup !== "function") {
      fail("the plugin definition has no setup(ctx) function")
    }
    // setup(ctx) must register the veto under "execute.before": the fake
    // context throws for any other hook name.
    await makeHook(repoDir)
    break
  }

  case "block": {
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, shellCommit)
    if (!error) {
      fail("the guard did not block a commit on a protected branch")
    }
    const message = String(error.message || error)
    if (!message.includes("BLOCKED") || !message.includes("branch-guard")) {
      fail(`the block message does not identify the branch guard: ${message}`)
    }
    const expectedBranch = process.env.TEST_EXPECT_BRANCH
    if (expectedBranch && !message.includes(`protected branch '${expectedBranch}'`)) {
      fail(`the block message does not name the protected branch ${expectedBranch}: ${message}`)
    }
    break
  }

  case "kill-switch": {
    process.env.FORGE_BRANCH_GUARD_DISABLE = "1"
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, shellCommit)
    if (error) {
      fail(`the kill switch did not disable the veto: ${error.message || error}`)
    }
    break
  }

  case "passthrough": {
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, shellCommit)
    if (error) {
      fail(`the guard blocked a commit on a feature branch: ${error.message || error}`)
    }
    break
  }

  case "pipe-is-not-a-commit": {
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, {
      tool: "shell",
      input: { command: "git log | grep commit" },
    })
    if (error) {
      fail(`"git log | grep commit" was treated as a commit: ${error.message || error}`)
    }
    break
  }

  case "ignore-bash-tool": {
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, {
      tool: "bash",
      input: { command: "git commit -m test" },
    })
    if (error) {
      fail(`the OpenCode 1 "bash" tool was not ignored: ${error.message || error}`)
    }
    break
  }

  case "ignore-edit-tool": {
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, {
      tool: "edit",
      input: { filePath: "README.md" },
    })
    if (error) {
      fail(`the "edit" tool was not ignored: ${error.message || error}`)
    }
    break
  }

  case "cwd-from-context": {
    // The process cwd is a repository on a protected branch, but the session
    // directory (ctx.location.directory) is a feature branch: the guard must
    // decide with the session directory, not with the process cwd.
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, shellCommit)
    if (error) {
      fail(`the guard used the process cwd instead of ctx.location.directory: ${error.message || error}`)
    }
    break
  }

  case "merged-warning": {
    const hook = await makeHook(repoDir)
    const error = await callHook(hook, { tool: "shell", input: { command: "echo hello" } })
    if (error) {
      fail(`the guard failed on a harmless command: ${error.message || error}`)
    }
    break
  }

  default:
    fail(`unknown test case: ${testCase}`)
}
EOF
}

# run_guard_case <case> <repo_dir> [expected_branch]
# Runs one case of the Node harness. The captured output is stored in
# CASE_OUTPUT so the caller can inspect the warnings of the plugin.
CASE_OUTPUT=""
run_guard_case() {
  local case_name="$1" repo_dir="$2" expected_branch="${3:-}"

  CASE_OUTPUT="$(TEST_CASE="$case_name" TEST_REPO_DIR="$repo_dir" \
    TEST_EXPECT_BRANCH="$expected_branch" \
    TEST_PLUGIN_ROOT="$SUITE_ROOT" \
    node "$SUITE_ROOT/check.mjs" 2>&1)" && return 0

  return 1
}

# make_protected_repo <dir> <branch>
# Creates a disposable repository whose selected branch is a protected one.
# NO commit is created: the guard only needs the branch name, and creating a
# commit on master/main/dev is exactly what this adaptation forbids. The
# branch stays unborn, so `git symbolic-ref --short HEAD` still resolves it.
make_protected_repo() {
  local dir="$1" branch="$2"

  git init -q -b "$branch" "$dir" >/dev/null 2>&1
  git -C "$dir" config user.email "test@forge.local"
  git -C "$dir" config user.name "Forge Test"

  if git -C "$dir" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
    echo "  ERROR: $dir already carries a commit on the protected branch $branch" >&2
    return 1
  fi
}

# make_feature_repo <dir> <branch>
# Creates a disposable repository on a NON protected branch with one commit.
# Commits are only ever created on disposable, unprotected branches.
make_feature_repo() {
  local dir="$1" branch="$2"

  case "$branch" in
    master|main|dev)
      echo "  ERROR: refusing to create a commit on the protected branch $branch" >&2
      return 1
      ;;
  esac

  git init -q -b "$branch" "$dir" >/dev/null 2>&1
  git -C "$dir" config user.email "test@forge.local"
  git -C "$dir" config user.name "Forge Test"
  git -C "$dir" commit -q --allow-empty -m "base" >/dev/null 2>&1
}

# make_merged_feature_repo <dir> <remote_dir>
# Reproduces "the current branch is already merged into the default branch"
# WITHOUT any push:
#   * the feature branch carries one commit (disposable, unprotected branch),
#   * the remote-tracking ref refs/remotes/origin/main points at that commit,
#   * refs/remotes/origin/HEAD resolves to refs/remotes/origin/main.
# That is exactly the state `push feature:main` + `fetch` + `symbolic-ref`
# produced before the adaptation. The bare remote is registered as `origin`
# and stays empty: nothing is ever pushed to it.
make_merged_feature_repo() {
  local dir="$1" remote="$2"

  git init -q --bare "$remote" >/dev/null 2>&1
  git init -q -b feature "$dir" >/dev/null 2>&1
  git -C "$dir" config user.email "test@forge.local"
  git -C "$dir" config user.name "Forge Test"
  git -C "$dir" remote add origin "file://$remote"
  git -C "$dir" commit -q --allow-empty -m "feature work" >/dev/null 2>&1

  local head
  head="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" update-ref refs/remotes/origin/main "$head"
  git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# Disposable repositories are created under the suite root so that the EXIT
# trap removes all of them at once.
new_repo_dir() {
  mktemp -d "$SUITE_ROOT/repos/repo.XXXXXX"
}

new_remote_dir() {
  mktemp -d "$SUITE_ROOT/remotes/remote.XXXXXX"
}

test_plugin_follows_the_v2_contract() {
  local tmp_repo
  tmp_repo="$(new_repo_dir)"
  make_protected_repo "$tmp_repo" master

  if run_guard_case contract "$tmp_repo"; then
    pass "forge-guard exports a default definition with id and setup(ctx)"
  else
    fail "forge-guard does not follow the OpenCode 2 plugin contract: $CASE_OUTPUT"
  fi
}

test_plugin_blocks_commit_on_protected_branch() {
  local branch
  for branch in master main dev; do
    local tmp_repo
    tmp_repo="$(new_repo_dir)"
    make_protected_repo "$tmp_repo" "$branch"

    if run_guard_case block "$tmp_repo" "$branch"; then
      pass "forge-guard blocks git commit on the protected branch ${branch}"
    else
      fail "forge-guard did not block git commit on ${branch}: $CASE_OUTPUT"
    fi
  done
}

test_plugin_disable_kill_switch() {
  local tmp_repo
  tmp_repo="$(new_repo_dir)"
  make_protected_repo "$tmp_repo" master

  if run_guard_case kill-switch "$tmp_repo"; then
    pass "FORGE_BRANCH_GUARD_DISABLE disables the plugin veto"
  else
    fail "FORGE_BRANCH_GUARD_DISABLE did not disable the plugin veto: $CASE_OUTPUT"
  fi
}

test_plugin_pass_through_on_non_protected_branch() {
  local tmp_repo
  tmp_repo="$(new_repo_dir)"
  make_feature_repo "$tmp_repo" feature

  if run_guard_case passthrough "$tmp_repo"; then
    pass "forge-guard allows git commit on non-protected branch"
  else
    fail "forge-guard blocked git commit on non-protected branch: $CASE_OUTPUT"
  fi
}

test_plugin_ignores_non_commit_commands() {
  local tmp_repo
  tmp_repo="$(new_repo_dir)"
  make_protected_repo "$tmp_repo" master

  if run_guard_case pipe-is-not-a-commit "$tmp_repo"; then
    pass "forge-guard does not confuse 'git log | grep commit' with a commit"
  else
    fail "forge-guard confused 'git log | grep commit' with a commit: $CASE_OUTPUT"
  fi
}

test_plugin_ignores_other_tools() {
  local tmp_repo
  tmp_repo="$(new_repo_dir)"
  make_protected_repo "$tmp_repo" master

  if run_guard_case ignore-bash-tool "$tmp_repo"; then
    pass "forge-guard ignores the OpenCode 1 'bash' tool"
  else
    fail "forge-guard did not ignore the OpenCode 1 'bash' tool: $CASE_OUTPUT"
  fi

  if run_guard_case ignore-edit-tool "$tmp_repo"; then
    pass "forge-guard ignores the 'edit' tool"
  else
    fail "forge-guard did not ignore the 'edit' tool: $CASE_OUTPUT"
  fi
}

test_plugin_uses_the_session_directory() {
  local protected_repo feature_repo
  protected_repo="$(new_repo_dir)"
  feature_repo="$(new_repo_dir)"
  make_protected_repo "$protected_repo" master
  make_feature_repo "$feature_repo" feature

  # The process cwd is the protected repository, the session directory is the
  # feature one: the guard must not block.
  local previous_pwd
  previous_pwd="$(pwd)"
  cd "$protected_repo"
  if run_guard_case cwd-from-context "$feature_repo"; then
    pass "forge-guard decides with ctx.location.directory, not with the process cwd"
  else
    fail "forge-guard used the process cwd instead of ctx.location.directory: $CASE_OUTPUT"
  fi
  cd "$previous_pwd"
}

test_plugin_warns_on_merged_branch() {
  local tmp_remote tmp_repo
  tmp_remote="$(new_remote_dir)"
  tmp_repo="$(new_repo_dir)"

  # No push: the merged state is built locally and the bare remote stays empty.
  make_merged_feature_repo "$tmp_repo" "$tmp_remote"

  if run_guard_case merged-warning "$tmp_repo" \
    && printf '%s\n' "$CASE_OUTPUT" | grep -q 'branch-guard' \
    && printf '%s\n' "$CASE_OUTPUT" | grep -q 'origin/main'; then
    pass "forge-guard emits warning when current branch is already merged"
  else
    fail "forge-guard did not emit merged-branch warning: $CASE_OUTPUT"
  fi

  # The registered remote must have received nothing at all.
  local remote_refs remote_objects
  remote_refs="$(git --git-dir="$tmp_remote" for-each-ref | wc -l | tr -d ' ')"
  remote_objects="$(find "$tmp_remote/objects" -type f | wc -l | tr -d ' ')"
  if [ "$remote_refs" = "0" ] && [ "$remote_objects" = "0" ]; then
    pass "the bare remote received no refs and no objects (no push happened)"
  else
    fail "the bare remote was written: refs=${remote_refs} objects=${remote_objects}"
  fi
}

# protected_commit_lines [log_file]
# Emits the recorded git commits whose BRANCH is a protected one.
#
# The operations log layout is:
#   EVENT <TAB> SUBCOMMAND <TAB> DIRECTORY <TAB> BRANCH <TAB> ARGS
# so the branch is the FOURTH field. The third one is the directory and must
# never be used to decide whether a commit happened on a protected branch.
protected_commit_lines() {
  local log="${1:-$OPS_LOG}"

  awk -F'\t' '$1 == "GIT" && $2 == "commit"' "$log" \
    | awk -F'\t' '$4 == "master" || $4 == "main" || $4 == "dev"'
}

# test_safety_invariants
# Post-conditions over the recorded git operations: no push was executed and
# no commit exists on any protected branch of the disposable repositories.
test_safety_invariants() {
  local push_lines blocked_lines
  push_lines="$(awk -F'\t' '($1 == "GIT" && $2 == "push") || $1 == "PUSH_BLOCKED"' "$OPS_LOG" | wc -l | tr -d ' ')"
  blocked_lines="$(awk -F'\t' '$1 == "PROTECTED_COMMIT_BLOCKED"' "$OPS_LOG" | wc -l | tr -d ' ')"

  if [ "$push_lines" -eq 0 ]; then
    pass "no git push was executed during the suite"
  else
    fail "a git push was executed during the suite:"
    awk -F'\t' '($1 == "GIT" && $2 == "push") || $1 == "PUSH_BLOCKED"' "$OPS_LOG"
  fi

  if [ "$blocked_lines" -eq 0 ]; then
    pass "no commit on a protected branch was attempted during the suite"
  else
    fail "a commit on a protected branch was attempted during the suite:"
    awk -F'\t' '$1 == "PROTECTED_COMMIT_BLOCKED"' "$OPS_LOG"
  fi

  # Independent check on the disposable repositories themselves: no protected
  # branch carries a commit.
  local offenders=""
  local repo branch
  for repo in "$SUITE_ROOT"/repos/*; do
    [ -d "$repo" ] || continue
    for branch in master main dev; do
      if git -C "$repo" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1; then
        offenders="$offenders $repo:$branch"
      fi
    done
  done
  if [ -z "$offenders" ]; then
    pass "no disposable repository carries a commit on master, main or dev"
  else
    fail "commits found on protected branches:$offenders"
  fi

  # Every commit recorded during the run must have been made on a branch that
  # is not protected. The branch is read from the FOURTH column of the
  # operations log (the third one is the directory).
  local commits_on_protected
  commits_on_protected="$(protected_commit_lines | wc -l | tr -d ' ')"
  if [ "$commits_on_protected" -eq 0 ]; then
    pass "every commit created by the suite was made on a non-protected branch"
  else
    fail "commits created on protected branches:"
    protected_commit_lines
  fi

  # Negative controls for the detector above: the very same predicate, fed
  # with synthetic records, MUST match a protected branch and MUST NOT match
  # a non protected one. Without them, the assertion could silently degrade
  # into a vacuous check that never inspects the branch column.
  local control_log="$SUITE_ROOT/control-git-ops.log"
  local control_hits

  printf 'GIT\tcommit\t/control/dir\tmaster\t-C /control/dir commit -m control\n' > "$control_log"
  control_hits="$(protected_commit_lines "$control_log" | wc -l | tr -d ' ')"
  if [ "$control_hits" -eq 1 ]; then
    pass "the protected-branch commit detector reads the branch column (positive control)"
  else
    fail "the protected-branch commit detector does not read the branch column: hits=$control_hits"
  fi

  printf 'GIT\tcommit\t/control/dir\tfeature\t-C /control/dir commit -m control\n' > "$control_log"
  control_hits="$(protected_commit_lines "$control_log" | wc -l | tr -d ' ')"
  if [ "$control_hits" -eq 0 ]; then
    pass "the protected-branch commit detector does not match a non-protected branch (negative control)"
  else
    fail "the protected-branch commit detector matches a non-protected branch: hits=$control_hits"
  fi
}

print_git_operations() {
  echo ""
  echo "--------------------------------"
  echo " Git operations recorded"
  echo "--------------------------------"
  echo "log file: $OPS_LOG"
  echo "total git invocations: $(awk -F'\t' '$1 == "GIT"' "$OPS_LOG" | wc -l | tr -d ' ')"
  echo "push invocations:       $(awk -F'\t' '($1 == "GIT" && $2 == "push") || $1 == "PUSH_BLOCKED"' "$OPS_LOG" | wc -l | tr -d ' ')"
  echo "commit invocations:     $(awk -F'\t' '$1 == "GIT" && $2 == "commit"' "$OPS_LOG" | wc -l | tr -d ' ')"
  echo "commits blocked on protected branches: $(awk -F'\t' '$1 == "PROTECTED_COMMIT_BLOCKED"' "$OPS_LOG" | wc -l | tr -d ' ')"
  echo "subcommands used: $(awk -F'\t' '$1 == "GIT" { print $2 }' "$OPS_LOG" | sort -u | tr '\n' ' ')"
  echo ""
  echo "event<TAB>subcommand<TAB>directory<TAB>branch<TAB>arguments"
  cat "$OPS_LOG"
  echo ""
}

echo "================================"
echo " forge_guard_plugin_unit.sh"
echo "================================"

prepare_plugin_sandbox

test_plugin_follows_the_v2_contract
test_plugin_blocks_commit_on_protected_branch
test_plugin_disable_kill_switch
test_plugin_pass_through_on_non_protected_branch
test_plugin_ignores_non_commit_commands
test_plugin_ignores_other_tools
test_plugin_uses_the_session_directory
test_plugin_warns_on_merged_branch
test_safety_invariants

print_git_operations

echo ""
echo "================================"
echo " Passed: $PASS"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
