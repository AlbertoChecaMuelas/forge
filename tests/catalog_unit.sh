#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/catalog_unit.sh — Unit tests for lib/catalog.sh
# Compatible with bash 3.2+. Uses only indexed arrays.
set -euo pipefail

cd "$(dirname "$0")/.."
ARSENAL_ROOT="$(pwd)"
source lib/catalog.sh

# Test harness
FAIL=0
PASS=0
TMPDIR_BASE="$ARSENAL_ROOT/tests/.tmp"
mkdir -p "$TMPDIR_BASE"

# Cleanup all temp dirs on exit
# Pattern-based cleanup: the make_* helpers run inside command substitutions
# (subshells), so accumulating paths in a parent-shell variable never works
# (the list stays empty and nothing was removed — tests/.tmp grew unbounded).
# The mktemp template embeds $$ (parent PID even inside subshells), so this
# glob removes exactly this run's artifacts.
cleanup() {
  rm -rf "$TMPDIR_BASE"/catalog-$$-* 2>/dev/null || true
}
trap cleanup EXIT

make_tmp() {
  local dir
  dir="$(mktemp -d "$TMPDIR_BASE/catalog-$$-XXXX")"
  echo "$dir"
}

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

fail() {
  echo "  FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

run_test() {
  local name="$1"
  echo "--- $name"
  "$name"
}

# =============================================================================
# Test cases
# =============================================================================

# T1 — Formato: cada línea del output tiene exactamente 2 campos separados por TAB
test_format_two_tab_fields() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_symlink_catalog)
  local bad
  bad=$(echo "$output" | awk -F'\t' 'NF!=2{print NR": "NF" fields"}')
  if [ -z "$bad" ]; then
    pass "format: every line has exactly 2 tab-separated fields"
  else
    fail "Lines with wrong field count: $bad"
  fi
}

# T2 — Todos los ficheros fuente existen
test_sources_exist() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_symlink_catalog)
  local all_ok=1
  while IFS=$'\t' read -r src _; do
    if [ ! -f "$ARSENAL_ROOT/$src" ]; then
      fail "Source not found: $ARSENAL_ROOT/$src"
      all_ok=0
    fi
  done <<< "$output"
  if [ "$all_ok" -eq 1 ]; then
    pass "sources_exist: all source files exist relative to ARSENAL_ROOT"
  fi
}

# T3 — Sin destinos duplicados
# Mutually-exclusive components (core vs commands/cost-report/agents) may map
# the SAME src to the same dest — that is legitimate. The real invariant is
# that no dest is claimed by two DIFFERENT sources.
test_no_duplicate_destinations() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_symlink_catalog | sort -u)
  local dups
  dups=$(echo "$output" | awk -F'\t' '{print $2}' | sort | uniq -d)
  if [ -z "$dups" ]; then
    pass "no_duplicate_destinations: no destination claimed by two different sources"
  else
    fail "Duplicate destinations with different sources: $dups"
  fi
}

# T4 — Al menos 1 entrada: el catálogo no está vacío
test_catalog_not_empty() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_symlink_catalog)
  local count
  count=$(echo "$output" | wc -l | tr -d ' ')
  if [ "$count" -ge 1 ]; then
    pass "catalog_not_empty: catalog has $count entries"
  else
    fail "Catalog is empty"
  fi
}

# T5 — forge_components_list returns exactly 9 known components, sorted
test_components_list_nine_known() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_components_list | sort)
  local count
  count=$(echo "$output" | wc -l | tr -d ' ')
  assert_eq "components_list: exactly 9 components" "9" "$count"

  local expected
  expected="$(printf '%s\n' agents branch-guard commands core cost-report cost-report-skill rtk-hook session-start statusline)"
  assert_eq "components_list: exact names match" "$expected" "$output"

  # Each name must correspond to an existing shared/components/<name>.json
  local all_ok=1
  while IFS= read -r name; do
    if [ ! -f "$ARSENAL_ROOT/shared/components/${name}.json" ]; then
      fail "components_list: manifest missing for component: $name"
      all_ok=0
    fi
  done <<< "$output"
  if [ "$all_ok" -eq 1 ]; then
    pass "components_list: every component has a manifest JSON"
  fi
}

# T5b — forge_components_default_list excludes opt-in components (core)
test_components_default_list_excludes_core() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_components_default_list | sort)
  local expected
  expected="$(printf '%s\n' agents branch-guard commands cost-report cost-report-skill rtk-hook session-start statusline)"
  assert_eq "components_default_list: the 8 default components, core excluded" "$expected" "$output"
}

# T5c — forge_components_conflict reflects core's conflicts_with (symmetric)
test_components_conflict_core() {
  if forge_components_conflict core agents && forge_components_conflict agents core; then
    pass "components_conflict: core ⟷ agents conflict in both directions"
  else
    fail "components_conflict: core ⟷ agents conflict not detected symmetrically"
  fi
  if forge_components_conflict core core; then
    fail "components_conflict: core must not conflict with itself"
  else
    pass "components_conflict: core does not conflict with itself"
  fi
  if forge_components_conflict core statusline; then
    fail "components_conflict: core must not conflict with statusline"
  else
    pass "components_conflict: core does not conflict with statusline"
  fi
}

# T6 — forge_component_symlinks for a known component emits src<TAB>dest lines
test_component_symlinks_known_format() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_component_symlinks agents)

  # Every line must have exactly 2 tab-separated fields
  local bad
  bad=$(echo "$output" | awk -F'\t' 'NF!=2{print NR": "NF" fields"}')
  if [ -z "$bad" ]; then
    pass "component_symlinks: every line has exactly 2 tab-separated fields"
  else
    fail "component_symlinks: lines with wrong field count: $bad"
  fi

  # Every src path must exist under ARSENAL_ROOT
  local all_ok=1
  while IFS=$'\t' read -r src _; do
    if [ ! -f "$ARSENAL_ROOT/$src" ]; then
      fail "component_symlinks: src not found: $ARSENAL_ROOT/$src"
      all_ok=0
    fi
  done <<< "$output"
  if [ "$all_ok" -eq 1 ]; then
    pass "component_symlinks: all src paths exist under ARSENAL_ROOT"
  fi
}

# T7 — forge_component_symlinks for unknown component exits non-zero
test_component_symlinks_unknown_exits_nonzero() {
  local result=0
  ARSENAL_ROOT="$ARSENAL_ROOT" forge_component_symlinks no-such-component >/dev/null 2>&1 || result=$?
  if [ "$result" -ne 0 ]; then
    pass "component_symlinks: exits non-zero for unknown component"
  else
    fail "component_symlinks: should exit non-zero for unknown component"
  fi
}

# T8 — forge_component_symlinks commands includes reference file entries
test_component_symlinks_commands_has_reference_entries() {
  local output
  output=$(ARSENAL_ROOT="$ARSENAL_ROOT" forge_component_symlinks commands)

  # Verify each reference dest path is present in the output
  for ref_dest in \
    "skills/create-plan/reference/plan-format.md" \
    "skills/create-plan/reference/constraints.md" \
    "skills/execute-plan/reference/batch-algorithm.md" \
    "skills/execute-plan/reference/reviewer-and-close.md" \
    "skills/plan-format/SKILL.md"; do
    if printf '%s\n' "$output" | grep -qF "$ref_dest"; then
      pass "commands component includes reference entry: $ref_dest"
    else
      fail "commands component missing reference entry: $ref_dest"
    fi
  done

  # commands.json has exactly 21 symlink entries (no target_root_files)
  local count
  count=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
  assert_eq "commands component has exactly 13 entries" "13" "$count"
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== catalog_unit.sh ==="

run_test test_format_two_tab_fields
run_test test_sources_exist
run_test test_no_duplicate_destinations
run_test test_catalog_not_empty
run_test test_components_list_nine_known
run_test test_components_default_list_excludes_core
run_test test_components_conflict_core
run_test test_component_symlinks_known_format
run_test test_component_symlinks_unknown_exits_nonzero
run_test test_component_symlinks_commands_has_reference_entries

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
