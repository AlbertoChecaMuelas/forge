#!/usr/bin/env bash
# tests/run-all.sh — Run all test suites in the forge test directory.
# Compatible with bash 3.2+. No associative arrays, no mapfile.
#
# Usage:
#   bash tests/run-all.sh
#   FORGE_TEST_FILTER=rtk bash tests/run-all.sh   # only tests whose basename contains "rtk"
#
# Exit code: 0 if all tests pass, 1 if any fail.
set -euo pipefail

# ---------------------------------------------------------------------------
# Locate repo root from this script's location
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # REPO_ROOT available to sourced test files if needed
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Collect test files in deterministic (sorted) order.
# Patterns: tests/*_unit.sh, tests/*_integration.sh
# Non-standard files that don't match these patterns are listed explicitly.
#
# The execute-plan contract suites follow the standard pattern and are
# therefore collected here:
#   tests/execute_plan_helpers_unit.sh      — self-check of the front-matter
#                                              helpers extracted from both
#                                              variants
#   tests/execute_plan_parity_unit.sh       — semantic parity between the
#                                              Claude and OpenCode variants
#                                              and installable references
#   tests/execute_plan_command_only_unit.sh — selective distribution of the
#                                              execute-plan command
#
# The suites of this lot follow the standard pattern too and are therefore
# collected here:
#   tests/reference_only_install_unit.sh    — selective distribution of a
#                                              single declared reference
#                                              (--reference-only) and the
#                                              preservation of the foreign
#                                              state
#   tests/launcher_relative_path_unit.sh     — routing of the root invocation
#                                              of the launcher when its first
#                                              argument is a project directory
#   tests/forge_contained_run_unit.sh        — the acceptance contract of the
#                                              containment entry
#                                              (tools/verification/
#                                              forge-contained-run.sh)
#
# The SENSITIVITY of that battery is a separate suite that is NOT collected
# by default, because it runs the whole battery once per mutant:
#
#   tests/forge_contained_run_sensitivity.sh — mutates COPIES (never the
#                                              repository) of the entry and of
#                                              the consumer and proves that the
#                                              battery FAILS on every broken
#                                              property of the acceptance
#                                              contract.
#
# It is run on demand, during the qualification of the containment:
#   bash tests/forge_contained_run_sensitivity.sh
#
# ISOLATED suites
# ---------------
#
# A suite can be ISOLATED from the default battery. An isolated suite is NOT
# executed and it is NOT counted as passed, but it STAYS in the count of the
# battery and the reason is printed, so the count of the summary is always the
# real one.
#
# The only isolated suite today is the real runtime integration:
#
#   tests/opencode_real_runtime_integration.sh — needs the GLOBAL installation
#       of @opencode/cli (or FORGE_TEST_REAL_OPENCODE_BIN) and the real
#       integration is NOT APPROVED: it stays BLOCKED until its whole chain is
#       accredited. Without a runtime it would fail by design ("a missing
#       runtime is a failure of the suite, never a green skip"), and running
#       it is not authorised, so it is isolated instead of being executed or
#       being counted as a pass.
# ---------------------------------------------------------------------------
EXTRA_TESTS="$SCRIPT_DIR/test-install-summary.sh"
ISOLATED_TESTS="$SCRIPT_DIR/opencode_real_runtime_integration.sh"

is_isolated() {
  local candidate="$1"
  local isolated
  for isolated in $ISOLATED_TESTS; do
    [ "$candidate" = "$isolated" ] && return 0
  done
  return 1
}

collect_tests() {
  # Use find and sort for bash 3.2+ compatibility (no glob expansion ordering)
  find "$SCRIPT_DIR" -maxdepth 1 \( -name '*_unit.sh' -o -name '*_integration.sh' \) \
    | sort

  # Explicit extras (non-standard naming)
  local f
  for f in $EXTRA_TESTS; do
    if [ -f "$f" ]; then
      echo "$f"
    fi
  done
}

# ---------------------------------------------------------------------------
# Apply FORGE_TEST_FILTER if set
# ---------------------------------------------------------------------------
FILTER="${FORGE_TEST_FILTER:-}"

filtered_tests() {
  local f
  while IFS= read -r f; do
    local base
    base="$(basename "$f")"
    if [ -z "$FILTER" ] || [ "${base#*"${FILTER}"}" != "$base" ]; then
      echo "$f"
    fi
  done
}

# ---------------------------------------------------------------------------
# The DECLARATION of the cleanup of the PRODUCT of this battery.
#
# The containment entry (tools/verification/forge-contained-run.sh) demands
# ONE declaration of the cleanup of the product, observed BEFORE its
# defensive cleanup, and it refuses to certify an invocation whose
# declaration is absent or unknown. A battery of dozens of suites does not
# produce that declaration by itself, and neither the closing of the harness
# nor the count of the suites can substitute it: this block produces it.
#
# The declaration is per SCENARIO (per suite) and it is aggregated with the
# WORST CASE (FAIL > UNKNOWN > PASS). The observation is made over the
# PRIVATE /proc of the containment and it uses the criterion of the case
# CLEAN-1 of the V2 bank: a live process of the batch that is neither the
# PID 1 of the namespace nor the observer nor one of its ancestors is a
# leftover of the product.
#
#   * an EMPTY set of leftovers is a legitimate PASS (a suite that launched
#     nothing has nothing to clean up);
#   * a non-empty set is a FAIL;
#   * an observation that could NOT be performed is an UNKNOWN that is
#     reported literally, and the aggregate reflects it. An UNKNOWN is
#     NEVER turned into a PASS.
#
# NOTHING of this block runs outside an accredited containment: the /proc of
# the host is NEVER enumerated. The trigger is the marker of the entry, and
# the observation only happens after the admission check of the containment
# has accredited the namespace.
# ---------------------------------------------------------------------------
CLEANUP_HELPER="$SCRIPT_DIR/forge_run_all_cleanup.py"
CLEANUP_MARKER="${FORGE_PRODUCT_CLEANUP_RESULT_FILE:-}"
CLEANUP_ADMISSION="$REPO_ROOT/tools/verification/require-v2-containment.sh"
CLEANUP_STATE="NOT_APPLICABLE"
CLEANUP_WORKDIR=""
CLEANUP_AGGREGATE=""
CLEANUP_SUITE_INDEX=0

# cleanup_probe <destination>
#
# Observes the cleanup over the private /proc and writes the verdict on the
# FIRST line and the PIDs of the leftovers on the following lines. It NEVER
# fails: an observation that could not be performed is an UNKNOWN, not an
# error of the battery.
cleanup_probe() {
  local destination="$1"
  if ! python3 "$CLEANUP_HELPER" probe > "$destination" 2>/dev/null; then
    printf 'UNKNOWN\n' > "$destination"
  fi
  if [ ! -s "$destination" ]; then
    printf 'UNKNOWN\n' > "$destination"
  fi
}

# cleanup_start
#
# Prepares the observation. It only proceeds when this battery IS the
# scenario of an entry (the marker is present) AND the admission check of
# the containment proves that this process runs in the accredited PID
# namespace with its private /proc.
cleanup_start() {
  [ -n "$CLEANUP_MARKER" ] || return 0
  [ -f "$CLEANUP_HELPER" ] || { CLEANUP_STATE="UNOBSERVABLE"; return 0; }
  [ -f "$CLEANUP_ADMISSION" ] || { CLEANUP_STATE="UNOBSERVABLE"; return 0; }

  CLEANUP_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/forge-run-all-cleanup.XXXXXX" 2>/dev/null)" || CLEANUP_WORKDIR=""
  if [ -z "$CLEANUP_WORKDIR" ] || [ ! -d "$CLEANUP_WORKDIR" ]; then
    CLEANUP_WORKDIR=""
    CLEANUP_STATE="UNOBSERVABLE"
    return 0
  fi

  if ! bash "$CLEANUP_ADMISSION" >/dev/null 2>"$CLEANUP_WORKDIR/admission.log"; then
    # The observation would read the /proc of the HOST: it is refused.
    CLEANUP_STATE="UNOBSERVABLE"
    return 0
  fi

  CLEANUP_STATE="OBSERVING"
  : > "$CLEANUP_WORKDIR/values.tsv"
  return 0
}

# cleanup_record_suite <name> <exit-code>
#
# Records the value of ONE suite: the worst case of its own observation over
# the private /proc and of the declarations that the contained runs of the
# suite published (they observe the leftovers INSIDE the containment of the
# suite, before the kernel tears that namespace down).
cleanup_record_suite() {
  local name="$1" rc="$2"
  local after="$CLEANUP_WORKDIR/probe-after.txt"
  local before="$CLEANUP_WORKDIR/probe-before.txt"
  local declarations="$CLEANUP_WORKDIR/declarations-$CLEANUP_SUITE_INDEX.tsv"
  local verdict observed nested value new_leftovers

  verdict="$(sed -n '1p' "$after" 2>/dev/null | tr -d '[:space:]')"
  case "$verdict" in PASS|FAIL|UNKNOWN) : ;; *) verdict=UNKNOWN ;; esac

  new_leftovers=""
  if [ "$verdict" != "UNKNOWN" ]; then
    new_leftovers="$(sed -n '2,$p' "$after" 2>/dev/null | grep -vxF -f "$before" 2>/dev/null || true)"
  fi
  if [ "$verdict" = "UNKNOWN" ]; then
    observed="UNKNOWN"
  elif [ -n "$new_leftovers" ]; then
    observed="FAIL"
  else
    observed="PASS"
  fi

  nested="NOT_APPLICABLE"
  if [ -s "$declarations" ]; then
    nested="$(python3 "$CLEANUP_HELPER" aggregate "$declarations" 2>/dev/null | sed -n '1p' | tr -d '[:space:]')"
    case "$nested" in PASS|FAIL|UNKNOWN|NOT_APPLICABLE) : ;; *) nested=UNKNOWN ;; esac
  fi
  # A suite that ran NO contained scenario has no declaration from the
  # inside: it is NOT APPLICABLE, and it is not an UNKNOWN (it launched
  # nothing inside a containment, so there was nothing to observe there).

  value="$(python3 "$CLEANUP_HELPER" worst "$observed" "$nested" 2>/dev/null | sed -n '1p' | tr -d '[:space:]')"
  case "$value" in PASS|FAIL|UNKNOWN|NOT_APPLICABLE) : ;; *) value=UNKNOWN ;; esac

  printf '%s\t%s\n' "$name" "$value" >> "$CLEANUP_WORKDIR/values.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$value" "$observed" "$nested" "$rc" >> "$CLEANUP_WORKDIR/table.tsv"
  return 0
}

# cleanup_finalize
#
# Aggregates the per-scenario values with the worst case and publishes the
# declaration:
#
#   * PASS  -> the marker carries PASS;
#   * FAIL  -> the marker carries FAIL;
#   * UNKNOWN -> the marker is NOT written: an unobserved cleanup is not
#     observed, and the entry turns that into a refusal to certify.
cleanup_finalize() {
  local aggregate values
  values="$CLEANUP_WORKDIR/values.tsv"
  aggregate="$(python3 "$CLEANUP_HELPER" aggregate "$values" 2>/dev/null | sed -n '1p' | tr -d '[:space:]')"
  case "$aggregate" in PASS|FAIL|UNKNOWN) : ;; *) aggregate=UNKNOWN ;; esac
  CLEANUP_AGGREGATE="$aggregate"

  echo ""
  echo "============================================================"
  echo " Limpieza del producto por escenario (agregado: $aggregate)"
  echo "============================================================"
  if [ -f "$CLEANUP_WORKDIR/table.tsv" ]; then
    while IFS= read -r row; do
      printf ' %s\n' "$row"
    done < "$CLEANUP_WORKDIR/table.tsv"
  fi

  # The durable evidence of this declaration: it lives next to the receipt of
  # the run, NOT inside the context that the entry removes.
  local receipt run_dir
  receipt="${FORGE_CONTAINED_RUN_RECEIPT:-}"
  run_dir=""
  [ -n "$receipt" ] && run_dir="$(dirname "$receipt")"
  if [ -n "$run_dir" ] && [ -d "$run_dir" ] && [ -f "$CLEANUP_WORKDIR/table.tsv" ]; then
    {
      printf 'AGGREGATE=%s\n' "$aggregate"
      printf 'CRITERION=CLEAN-1 (conjunto vacio=PASS, restos=FAIL, no observado=UNKNOWN)\n'
      printf 'SUITE\tVALUE\tOBSERVED\tDECLARED_INSIDE\tRC\n'
      cat "$CLEANUP_WORKDIR/table.tsv"
    } > "$run_dir/run-all-cleanup.tsv" 2>/dev/null || true
  fi

  case "$aggregate" in
    PASS|FAIL)
      printf '%s\n' "$aggregate" > "$CLEANUP_MARKER" 2>/dev/null || true
      ;;
    *)
      # An UNKNOWN is not observed: the marker is left absent on purpose.
      rm -f "$CLEANUP_MARKER" 2>/dev/null || true
      ;;
  esac
  return 0
}

TESTS="$(collect_tests | filtered_tests)"

# The declaration of the cleanup of the PRODUCT is prepared BEFORE anything
# else: even a battery that runs NO suite has to declare what it observed
# (and what it did NOT observe).
cleanup_start

if [ -z "$TESTS" ]; then
  if [ -n "$FILTER" ]; then
    echo "No test files match filter: '$FILTER'"
  else
    echo "No test files found in $SCRIPT_DIR"
  fi
  if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
    cleanup_finalize
  elif [ -n "$CLEANUP_MARKER" ]; then
    CLEANUP_AGGREGATE="UNKNOWN"
    rm -f "$CLEANUP_MARKER" 2>/dev/null || true
  fi
  exit 0
fi


# ---------------------------------------------------------------------------
# Run each test
# ---------------------------------------------------------------------------
TOTAL=0
EXECUTED=0
PASSED=0
FAILED=0
ISOLATED=0
SUITE_START=$SECONDS

while IFS= read -r test_file; do
  base="$(basename "$test_file")"
  echo ""
  echo "=== $base ==="

  # An isolated suite is neither executed nor counted as a pass: it stays in
  # the count of the battery and the reason is printed.
  if is_isolated "$test_file"; then
    TOTAL=$(( TOTAL + 1 ))
    ISOLATED=$(( ISOLATED + 1 ))
    echo "ISOLATED  $base  (suite bloqueada y no aprobada: no se ejecuta)"
    if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
      # An ISOLATED suite is NOT EXECUTED: it launched nothing, so it has
      # nothing to clean up. Its declaration is NOT APPLICABLE and it does
      # not take part in the aggregate (the same criterion that the V2 bank
      # applies to a scenario whose product never executed).
      printf '%s\tNOT_APPLICABLE\n' "$base" >> "$CLEANUP_WORKDIR/values.tsv"
      printf '%s\tNOT_APPLICABLE\tNOT_APPLICABLE\tNOT_APPLICABLE\tNOT_EXECUTED\n' \
        "$base" >> "$CLEANUP_WORKDIR/table.tsv"
    fi
    continue
  fi

  CLEANUP_SUITE_INDEX=$(( CLEANUP_SUITE_INDEX + 1 ))

  if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
    cleanup_probe "$CLEANUP_WORKDIR/probe-before.txt"
    : > "$CLEANUP_WORKDIR/declarations-$CLEANUP_SUITE_INDEX.tsv"
  fi

  test_start=$SECONDS
  set +e
  # Each suite gets its own stdin: the loop below feeds the suite list through
  # the heredoc, and a suite that reads stdin would otherwise swallow a line
  # of that list — the suite would be skipped and never counted as run.
  #
  # The contained runs of the suite publish their own declaration of the
  # cleanup of the product in the file that FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE
  # names: they observe the leftovers INSIDE their own containment, before
  # the kernel tears that namespace down.
  if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
    FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE="$CLEANUP_WORKDIR/declarations-$CLEANUP_SUITE_INDEX.tsv" \
      bash "$test_file" </dev/null
  else
    bash "$test_file" </dev/null
  fi
  exit_code=$?
  set -e
  elapsed=$(( SECONDS - test_start ))

  if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
    cleanup_probe "$CLEANUP_WORKDIR/probe-after.txt"
    cleanup_record_suite "$base" "$exit_code"
  fi

  TOTAL=$(( TOTAL + 1 ))
  EXECUTED=$(( EXECUTED + 1 ))
  if [ "$exit_code" -eq 0 ]; then
    PASSED=$(( PASSED + 1 ))
    echo "PASS  $base  (${elapsed}s)"
  else
    FAILED=$(( FAILED + 1 ))
    echo "FAIL  $base  (${elapsed}s, exit=$exit_code)"
  fi
done <<EOF
$TESTS
EOF

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total_elapsed=$(( SECONDS - SUITE_START ))
echo ""
echo "============================================================"
echo " Tests run:  $TOTAL"
echo " Executed:   $EXECUTED"
echo " Passed:     $PASSED"
echo " Isolated:   $ISOLATED"
echo " Failed:     $FAILED"
echo " Duration:   ${total_elapsed}s"
echo "============================================================"

# The declaration of the cleanup of the PRODUCT of this battery is published
# BEFORE the exit: it is measured over the private /proc and it is written
# before the defensive cleanup of the containment.
if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
  cleanup_finalize
elif [ -n "$CLEANUP_MARKER" ]; then
  # The observation could NOT be performed: the declaration is UNKNOWN and
  # the marker is left absent. An unknown cleanup is never a PASS.
  CLEANUP_AGGREGATE="UNKNOWN"
  echo ""
  echo " Limpieza del producto: UNKNOWN (no se pudo observar: $CLEANUP_STATE)"
  rm -f "$CLEANUP_MARKER" 2>/dev/null || true
fi

# Sweep tests/.tmp: suites clean their own artifacts on exit, but aborted or
# killed runs can leave residue behind, and a directory-based plugin install
# copies the whole working tree — stale fixtures once accumulated 285 MB here.
rm -rf "$SCRIPT_DIR/.tmp"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
