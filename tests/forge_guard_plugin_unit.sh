#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

FORGE_ROOT="$(pwd)"
PLUGIN_PATH="$FORGE_ROOT/open-code/plugins/forge-guard.js"
FAIL=0
PASS=0

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

run_node_check() {
  local repo_dir="$1"
  local mode="$2"

  TEST_REPO_DIR="$repo_dir" TEST_MODE="$mode" TEST_PLUGIN_PATH="$PLUGIN_PATH" node --input-type=module <<'NODE'
import { pathToFileURL } from "node:url"

const pluginModule = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const pluginFactory = pluginModule.default

if (process.env.TEST_MODE === "disable") {
  process.env.FORGE_BRANCH_GUARD_DISABLE = "1"
}

process.chdir(process.env.TEST_REPO_DIR)
const hooks = await pluginFactory()
const hook = hooks["tool.execute.before"]

if (process.env.TEST_MODE === "block") {
  let blocked = false
  try {
    await hook({ tool: "bash", command: "git commit -m test" }, {})
  } catch (error) {
    blocked = String(error.message || error).includes("BLOCKED")
  }
  if (!blocked) {
    throw new Error("expected protected-branch block")
  }
}

if (process.env.TEST_MODE === "disable") {
  await hook({ tool: "bash", command: "git commit -m test" }, {})
}

if (process.env.TEST_MODE === "passthrough") {
  let threw = false
  try {
    await hook({ tool: "bash", command: "git commit -m test" }, {})
  } catch (_e) {
    threw = true
  }
  if (threw) {
    throw new Error("expected passthrough on non-protected branch but was blocked")
  }
}
NODE
}

run_node_warn_check() {
  local repo_dir="$1"
  TEST_REPO_DIR="$repo_dir" TEST_PLUGIN_PATH="$PLUGIN_PATH" node --input-type=module <<'NODE'
import { pathToFileURL } from "node:url"

const pluginModule = await import(pathToFileURL(process.env.TEST_PLUGIN_PATH).href)
const pluginFactory = pluginModule.default

process.chdir(process.env.TEST_REPO_DIR)
const hooks = await pluginFactory()
const hook = hooks["tool.execute.before"]

await hook({ tool: "bash", command: "echo hello" }, {})
NODE
}

test_plugin_blocks_commit_on_protected_branch() {
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  git init -b main "$tmp_repo" >/dev/null 2>&1

  if run_node_check "$tmp_repo" block >/dev/null 2>&1; then
    pass "forge-guard blocks git commit on protected branches"
  else
    fail "forge-guard did not block git commit on protected branches"
  fi

  rm -rf "$tmp_repo"
}

test_plugin_disable_kill_switch() {
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  git init -b main "$tmp_repo" >/dev/null 2>&1

  if run_node_check "$tmp_repo" disable >/dev/null 2>&1; then
    pass "FORGE_BRANCH_GUARD_DISABLE disables the plugin veto"
  else
    fail "FORGE_BRANCH_GUARD_DISABLE did not disable the plugin veto"
  fi

  rm -rf "$tmp_repo"
}

test_plugin_pass_through_on_non_protected_branch() {
  local tmp_repo
  tmp_repo="$(mktemp -d)"
  git init -b feature "$tmp_repo" >/dev/null 2>&1

  if run_node_check "$tmp_repo" passthrough >/dev/null 2>&1; then
    pass "forge-guard allows git commit on non-protected branch"
  else
    fail "forge-guard blocked git commit on non-protected branch"
  fi

  rm -rf "$tmp_repo"
}

test_plugin_warns_on_merged_branch() {
  local tmp_remote tmp_repo
  tmp_remote="$(mktemp -d)"
  tmp_repo="$(mktemp -d)"

  git init --bare "$tmp_remote" >/dev/null 2>&1

  git init -b feature "$tmp_repo" >/dev/null 2>&1
  git -C "$tmp_repo" config user.email "test@forge.local"
  git -C "$tmp_repo" config user.name "Forge Test"
  git -C "$tmp_repo" remote add origin "file://$tmp_remote"
  git -C "$tmp_repo" commit --allow-empty -m "feature work" >/dev/null 2>&1

  # Push feature to origin/main so origin/main contains the feature HEAD
  git -C "$tmp_repo" push origin feature:main >/dev/null 2>&1
  git -C "$tmp_repo" fetch origin >/dev/null 2>&1
  # Set refs/remotes/origin/HEAD so defaultBranch() resolves to "main"
  git -C "$tmp_repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main >/dev/null 2>&1

  local warn_output
  warn_output="$(run_node_warn_check "$tmp_repo" 2>&1)"

  if printf '%s\n' "$warn_output" | grep -q 'branch-guard'; then
    pass "forge-guard emits warning when current branch is already merged"
  else
    fail "forge-guard did not emit merged-branch warning"
  fi

  rm -rf "$tmp_repo" "$tmp_remote"
}

echo "================================"
echo " forge_guard_plugin_unit.sh"
echo "================================"

test_plugin_blocks_commit_on_protected_branch
test_plugin_disable_kill_switch
test_plugin_pass_through_on_non_protected_branch
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
