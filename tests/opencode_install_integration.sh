#!/usr/bin/env bash
set -euo pipefail

FORGE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$FORGE_ROOT/open-code/install-opencode.sh"
UNINSTALLER="$FORGE_ROOT/open-code/uninstall-opencode.sh"

FAIL=0
PASS_COUNT=0
TMP_TEST_HOME=""

pass() { echo "  PASS  $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL  $1" >&2; FAIL=1; }

test_isolated_install_and_launcher() {
  echo ""
  echo "--- test_isolated_install_and_launcher"

  local tmp_home
  tmp_home="$(mktemp -d)"
  TMP_TEST_HOME="$tmp_home"
  trap 'rm -rf "${TMP_TEST_HOME:-}"' EXIT

  HOME="$tmp_home" OPENAI_API_KEY=test-openai-key bash "$INSTALLER" >/dev/null 2>&1

  if [ -L "$tmp_home/.config/opencode-forge/agents/orchestrator.md" ]; then
    pass "overlay isolated agent symlink created"
  else
    fail "overlay isolated agent symlink missing"
  fi

  if [ -f "$tmp_home/.config/opencode-forge/opencode.jsonc" ]; then
    pass "overlay config file created"
  else
    fail "overlay config file missing"
  fi

  if [ ! -e "$tmp_home/.config/opencode/opencode.jsonc" ]; then
    pass "global opencode config untouched"
  else
    fail "global opencode config was touched"
  fi

  HOME="$tmp_home" "$tmp_home/.local/bin/forge-opencode" debug config > "$tmp_home/debug-config.out"

  if grep -q 'opencode-forge/plugins/forge-guard.js' "$tmp_home/debug-config.out" && grep -q '"default_agent": "orchestrator"' "$tmp_home/debug-config.out"; then
    pass "launcher resolves through symlink and loads isolated config"
  else
    fail "launcher did not load isolated config through symlink"
  fi

  mkdir -p "$tmp_home/fakebin"
  printf 'OPENAI_API_KEY=file-token\n' > "$tmp_home/.opencode-tokens"
  cat > "$tmp_home/fakebin/opencode" <<'EOF'
#!/usr/bin/env sh
printf '%s\n' "${OPENAI_API_KEY:-missing}"
EOF
  chmod +x "$tmp_home/fakebin/opencode"

  HOME="$tmp_home" PATH="$tmp_home/fakebin:$PATH" "$tmp_home/.local/bin/forge-opencode" > "$tmp_home/launcher-env.out"

  if grep -q '^file-token$' "$tmp_home/launcher-env.out"; then
    pass "launcher loads OPENAI_API_KEY from ~/.opencode-tokens via env.sh"
  else
    fail "launcher did not load OPENAI_API_KEY from ~/.opencode-tokens"
  fi

  HOME="$tmp_home" bash "$UNINSTALLER" >/dev/null 2>&1

  if [ ! -e "$tmp_home/.config/opencode-forge/opencode.jsonc" ] && [ ! -e "$tmp_home/.local/bin/forge-opencode" ]; then
    pass "uninstall removes isolated overlay and launcher"
  else
    fail "uninstall did not remove isolated overlay and launcher"
  fi

  TMP_TEST_HOME=""
  trap - EXIT
  rm -rf "$tmp_home"
}

test_failed_install_does_not_persist_state() {
  echo ""
  echo "--- test_failed_install_does_not_persist_state"

  local tmp_home
  tmp_home="$(mktemp -d)"
  TMP_TEST_HOME="$tmp_home"
  trap 'rm -rf "${TMP_TEST_HOME:-}"' EXIT

  local exit_code=0
  HOME="$tmp_home" PATH="/usr/bin:/bin" bash "$FORGE_ROOT/install.sh" install --target=opencode >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "install --target=opencode fails cleanly when opencode is unavailable"
  else
    fail "install --target=opencode unexpectedly succeeded without opencode"
  fi

  if [ ! -e "$tmp_home/.forge-state.json" ]; then
    pass "failed OpenCode install does not persist forge state"
  else
    fail "failed OpenCode install persisted forge state"
  fi

  TMP_TEST_HOME=""
  trap - EXIT
  rm -rf "$tmp_home"
}

test_both_target_opencode_failure_leaves_claude_installed() {
  echo ""
  echo "--- test_both_target_opencode_failure_leaves_claude_installed"

  local tmp_home
  tmp_home="$(mktemp -d)"
  TMP_TEST_HOME="$tmp_home"
  trap 'rm -rf "${TMP_TEST_HOME:-}"' EXIT

  local exit_code=0
  HOME="$tmp_home" PATH="/usr/bin:/bin" bash "$FORGE_ROOT/install.sh" install --target=both >/dev/null 2>&1 || exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    pass "install --target=both fails non-zero when opencode is unavailable"
  else
    fail "install --target=both unexpectedly succeeded without opencode"
  fi

  # The claude target must be installed even though opencode failed
  if [ -L "$tmp_home/.claude/agents/senior.md" ]; then
    pass "install --target=both installs claude target before opencode failure"
  else
    fail "install --target=both did not install claude target before opencode failure"
  fi

  # State file must exist and record claude but not opencode (rollback of opencode target)
  if [ -f "$tmp_home/.forge-state.json" ]; then
    local has_claude has_opencode
    has_claude="$(jq -r '[.targets_manifest[]?.name] | index("claude") != null' "$tmp_home/.forge-state.json" 2>/dev/null || echo "false")"
    has_opencode="$(jq -r '[.targets_manifest[]?.name] | index("opencode") != null' "$tmp_home/.forge-state.json" 2>/dev/null || echo "true")"
    if [ "$has_claude" = "true" ] && [ "$has_opencode" = "false" ]; then
      pass "state records claude but not opencode after --target=both partial failure"
    else
      fail "state does not correctly reflect partial --target=both install (has_claude=$has_claude, has_opencode=$has_opencode)"
    fi
  else
    fail "state file missing after --target=both partial install"
  fi

  TMP_TEST_HOME=""
  trap - EXIT
  rm -rf "$tmp_home"
}

echo "================================"
echo " opencode_install_integration.sh"
echo "================================"

test_isolated_install_and_launcher
test_failed_install_does_not_persist_state
test_both_target_opencode_failure_leaves_claude_installed

echo ""
echo "================================"
echo " Passed: $PASS_COUNT"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
else
  echo " ALL PASS"
fi
