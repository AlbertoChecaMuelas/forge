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
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"
PLUGIN_SOURCE_DIR="$FORGE_ROOT/open-code/plugin-packages/forge-guard"
FAIL=0
PASS=0
WORK_DIR=""

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

cleanup() {
  if [ -n "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

# prepare_plugin_sandbox
# Copies the real plugin package into a disposable directory and adds the
# minimal `@opencode/plugin` stub the module needs to be importable.
prepare_plugin_sandbox() {
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-unit.XXXXXX")"

  mkdir -p "$WORK_DIR/plugin-packages"
  cp -R "$PLUGIN_SOURCE_DIR" "$WORK_DIR/plugin-packages/forge-guard"

  mkdir -p "$WORK_DIR/node_modules/@opencode/plugin"
  cat > "$WORK_DIR/node_modules/@opencode/plugin/package.json" <<'EOF'
{
  "name": "@opencode/plugin",
  "version": "2.1.4",
  "type": "module",
  "main": "./index.js"
}
EOF
  cat > "$WORK_DIR/node_modules/@opencode/plugin/index.js" <<'EOF'
export const Plugin = { define: (definition) => definition }
EOF

  cat > "$WORK_DIR/check.mjs" <<'EOF'
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

# run_guard_case <case> <repo_dir>
# Runs one case of the Node harness. The captured output is stored in
# CASE_OUTPUT so the caller can inspect the warnings of the plugin.
CASE_OUTPUT=""
run_guard_case() {
  local case_name="$1" repo_dir="$2"

  CASE_OUTPUT="$(TEST_CASE="$case_name" TEST_REPO_DIR="$repo_dir" \
    TEST_PLUGIN_ROOT="$WORK_DIR" \
    node "$WORK_DIR/check.mjs" 2>&1)" && return 0

  return 1
}

# make_repo <dir> <branch>
make_repo() {
  local dir="$1" branch="$2"

  git init -q -b "$branch" "$dir" >/dev/null 2>&1
  git -C "$dir" config user.email "test@forge.local"
  git -C "$dir" config user.name "Forge Test"
  git -C "$dir" commit -q --allow-empty -m "base" >/dev/null 2>&1
}

test_plugin_follows_the_v2_contract() {
  local tmp_repo
  tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
  make_repo "$tmp_repo" master

  if run_guard_case contract "$tmp_repo"; then
    pass "forge-guard exports a default definition with id and setup(ctx)"
  else
    fail "forge-guard does not follow the OpenCode 2 plugin contract: $CASE_OUTPUT"
  fi

  rm -rf "$tmp_repo"
}

test_plugin_blocks_commit_on_protected_branch() {
  local branch
  for branch in master main dev; do
    local tmp_repo
    tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
    make_repo "$tmp_repo" "$branch"

    if run_guard_case block "$tmp_repo"; then
      pass "forge-guard blocks git commit on the protected branch ${branch}"
    else
      fail "forge-guard did not block git commit on ${branch}: $CASE_OUTPUT"
    fi

    rm -rf "$tmp_repo"
  done
}

test_plugin_disable_kill_switch() {
  local tmp_repo
  tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
  make_repo "$tmp_repo" master

  if run_guard_case kill-switch "$tmp_repo"; then
    pass "FORGE_BRANCH_GUARD_DISABLE disables the plugin veto"
  else
    fail "FORGE_BRANCH_GUARD_DISABLE did not disable the plugin veto: $CASE_OUTPUT"
  fi

  rm -rf "$tmp_repo"
}

test_plugin_pass_through_on_non_protected_branch() {
  local tmp_repo
  tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
  make_repo "$tmp_repo" feature

  if run_guard_case passthrough "$tmp_repo"; then
    pass "forge-guard allows git commit on non-protected branch"
  else
    fail "forge-guard blocked git commit on non-protected branch: $CASE_OUTPUT"
  fi

  rm -rf "$tmp_repo"
}

test_plugin_ignores_non_commit_commands() {
  local tmp_repo
  tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
  make_repo "$tmp_repo" master

  if run_guard_case pipe-is-not-a-commit "$tmp_repo"; then
    pass "forge-guard does not confuse 'git log | grep commit' with a commit"
  else
    fail "forge-guard confused 'git log | grep commit' with a commit: $CASE_OUTPUT"
  fi

  rm -rf "$tmp_repo"
}

test_plugin_ignores_other_tools() {
  local tmp_repo
  tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
  make_repo "$tmp_repo" master

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

  rm -rf "$tmp_repo"
}

test_plugin_uses_the_session_directory() {
  local protected_repo feature_repo
  protected_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
  feature_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"
  make_repo "$protected_repo" master
  make_repo "$feature_repo" feature

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

  rm -rf "$protected_repo" "$feature_repo"
}

test_plugin_warns_on_merged_branch() {
  local tmp_remote tmp_repo
  tmp_remote="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-remote.XXXXXX")"
  tmp_repo="$(mktemp -d "${TMPDIR:-/tmp}/forge-guard-repo.XXXXXX")"

  git init -q --bare "$tmp_remote" >/dev/null 2>&1
  git init -q -b feature "$tmp_repo" >/dev/null 2>&1
  git -C "$tmp_repo" config user.email "test@forge.local"
  git -C "$tmp_repo" config user.name "Forge Test"
  git -C "$tmp_repo" remote add origin "file://$tmp_remote"
  git -C "$tmp_repo" commit -q --allow-empty -m "feature work" >/dev/null 2>&1

  # Push feature to origin/main so origin/main contains the feature HEAD
  git -C "$tmp_repo" push -q origin feature:main >/dev/null 2>&1
  git -C "$tmp_repo" fetch -q origin >/dev/null 2>&1
  # Set refs/remotes/origin/HEAD so defaultBranch() resolves to "main"
  git -C "$tmp_repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1

  if run_guard_case merged-warning "$tmp_repo" \
    && printf '%s\n' "$CASE_OUTPUT" | grep -q 'branch-guard'; then
    pass "forge-guard emits warning when current branch is already merged"
  else
    fail "forge-guard did not emit merged-branch warning: $CASE_OUTPUT"
  fi

  rm -rf "$tmp_repo" "$tmp_remote"
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

echo ""
echo "================================"
echo " Passed: $PASS"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
