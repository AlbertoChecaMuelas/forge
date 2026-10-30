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
#   tests/opencode_real_runtime_integration.sh — it needs a REAL OpenCode
#       2.1.4 runtime. The battery NEVER installs anything, so it cannot
#       provide one, and a machine without the global installation of
#       @opencode/cli has none: without a runtime the scenario FAILS BY
#       DESIGN ("a missing runtime is a failure of the suite, never a green
#       skip"), so it must not run by default.
#
#       The isolation is LIFTED when a runtime is AVAILABLE, and the battery
#       never guesses: the runtime is either DECLARED explicitly
#       (FORGE_TEST_REAL_OPENCODE_BIN) or the global installation of
#       @opencode/cli is present (the CI installs it with
#       `npm install -g @opencode/cli@2.1.4`). The suite is then EXECUTED and
#       its result COUNTS: a failure of the real integration propagates to
#       the battery.
#
#         FORGE_TEST_REAL_OPENCODE_BIN="$(npm prefix -g)/bin/opencode" \
#           bash tests/run-all.sh
#
#       Without a runtime the suite stays isolated, with the reason printed,
#       and the count of the summary stays the real one.
#
#       The reason is not a decoration: an ISOLATED suite that does not say
#       WHY looks exactly like a preparation that went wrong. The reason is
#       published with a STABLE code (so a program can tell the causes
#       apart) and with a detail that names WHAT was searched and WHY it was
#       not found (so a person can act on it):
#
#         ISOLATED  <suite>  (...)  motivo=<CODE>: <detail>
#
#       The codes of the resolution of the runtime are:
#
#         RUNTIME_DECLARED                           the runtime is DECLARED
#         GLOBAL_INSTALLATION_FOUND                  the global installation is there
#         NO_DECLARATION_AND_NO_NPM                  npm is not available at all
#         NO_DECLARATION_AND_NO_GLOBAL_INSTALL       nothing of the global tree exists
#         NO_DECLARATION_AND_GLOBAL_NOT_EXECUTABLE   the global tree is there but is not executable
#
#       and the code of a suite that the runner isolates BY DECLARATION is:
#
#         DECLARED_ISOLATED_BY_THE_RUNNER
# ---------------------------------------------------------------------------
EXTRA_TESTS="$SCRIPT_DIR/test-install-summary.sh"
ISOLATED_TESTS="$SCRIPT_DIR/opencode_real_runtime_integration.sh"

# The REASON of the last resolution of the runtime and the reason of the last
# isolation. They are published by the probe and read by the loop that prints
# the isolated suites.
REAL_RUNTIME_REASON_CODE=""
REAL_RUNTIME_REASON_DETAIL=""
ISOLATION_REASON_CODE=""
ISOLATION_REASON_DETAIL=""

# real_runtime_probe
#
# Resolves the runtime the same way the scenario does and publishes WHY it is
# not there. It NEVER installs anything and never reaches the network: it only
# stats the paths of the global installation.
#
# The runtime of the real integration is AVAILABLE when it is DECLARED
# explicitly (FORGE_TEST_REAL_OPENCODE_BIN) or when the global installation
# of @opencode/cli is present: those are the two sources that the scenario
# itself resolves, so the battery and the scenario can never disagree about
# whether there is a runtime.
real_runtime_probe() {
  local prefix root candidate candidates="" searched="" not_executable=""

  REAL_RUNTIME_REASON_CODE=""
  REAL_RUNTIME_REASON_DETAIL=""

  if [ -n "${FORGE_TEST_REAL_OPENCODE_BIN:-}" ]; then
    REAL_RUNTIME_REASON_CODE="RUNTIME_DECLARED"
    REAL_RUNTIME_REASON_DETAIL="la declaracion explicita FORGE_TEST_REAL_OPENCODE_BIN=$FORGE_TEST_REAL_OPENCODE_BIN esta presente"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    REAL_RUNTIME_REASON_CODE="NO_DECLARATION_AND_NO_NPM"
    REAL_RUNTIME_REASON_DETAIL="la declaracion explicita FORGE_TEST_REAL_OPENCODE_BIN esta ausente y npm no esta disponible, de modo que la instalacion global de @opencode/cli no se puede ni buscar"
    return 1
  fi

  prefix="$(npm prefix -g 2>/dev/null || true)"
  root="$(npm root -g 2>/dev/null || true)"
  [ -n "$prefix" ] && candidates="$candidates$prefix/bin/opencode
"
  [ -n "$root" ] && candidates="$candidates$root/@opencode/cli/bin/opencode.exe
"

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate" ]; then
      REAL_RUNTIME_REASON_CODE="GLOBAL_INSTALLATION_FOUND"
      REAL_RUNTIME_REASON_DETAIL="la instalacion global de @opencode/cli esta presente en $candidate"
      return 0
    fi
    if [ -e "$candidate" ]; then
      not_executable="$not_executable; $candidate (existe pero no es ejecutable)"
    else
      searched="$searched; $candidate (no existe)"
    fi
  done <<CANDIDATES_EOF
$candidates
CANDIDATES_EOF

  not_executable="${not_executable#; }"
  searched="${searched#; }"

  if [ -n "$not_executable" ]; then
    REAL_RUNTIME_REASON_CODE="NO_DECLARATION_AND_GLOBAL_NOT_EXECUTABLE"
    REAL_RUNTIME_REASON_DETAIL="la declaracion explicita FORGE_TEST_REAL_OPENCODE_BIN esta ausente y la instalacion global de @opencode/cli no aporta ningun ejecutable utilizable: $not_executable"
    return 1
  fi

  REAL_RUNTIME_REASON_CODE="NO_DECLARATION_AND_NO_GLOBAL_INSTALL"
  REAL_RUNTIME_REASON_DETAIL="la declaracion explicita FORGE_TEST_REAL_OPENCODE_BIN esta ausente y no hay instalacion global de @opencode/cli (se busco: $searched)"
  return 1
}

# real_runtime_available
#
# The resolution of the runtime, reduced to its verdict. The CAUSE is
# published by the probe that this function drives.
real_runtime_available() {
  real_runtime_probe
}

# is_isolated <suite>
#
# The real runtime integration is EXECUTED when a runtime is available and
# ISOLATED otherwise: it is not executed, it is not counted as a pass and
# the reason is printed.
#
# The reason of an isolation is ALWAYS published: a suite that the runner
# isolates by declaration says so, and a suite that is isolated because its
# runtime is missing says WHICH runtime was searched and WHY it was not found.
is_isolated() {
  local candidate="$1"
  local isolated

  ISOLATION_REASON_CODE=""
  ISOLATION_REASON_DETAIL=""

  if [ "$candidate" = "$SCRIPT_DIR/opencode_real_runtime_integration.sh" ]; then
    if real_runtime_available; then
      return 1
    fi
    ISOLATION_REASON_CODE="$REAL_RUNTIME_REASON_CODE"
    ISOLATION_REASON_DETAIL="$REAL_RUNTIME_REASON_DETAIL"
    return 0
  fi

  for isolated in $ISOLATED_TESTS; do
    if [ "$candidate" = "$isolated" ]; then
      ISOLATION_REASON_CODE="DECLARED_ISOLATED_BY_THE_RUNNER"
      ISOLATION_REASON_DETAIL="el runner declara esta suite como aislada en ISOLATED_TESTS"
      return 0
    fi
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
# The DECLARATIONS of the checks that do not apply. A suite that ran and
# DECLARED some checks is NOT the same as a suite that ran everything: the
# aggregate publishes the count and the reason codes so a consumer of the
# summary can tell "the suite passed with N declarations" from "everything
# ran".
DECLARED=0
DECLARED_SUITES=0
SUITE_START=$SECONDS

# The log of every suite: it is what the declarations are read from. It
# lives OUTSIDE the repository and it is deleted at the end.
#
# The battery also runs in environments with a MINIMAL PATH (the acceptance
# of the isolation in tests/install_integration.sh): there `mktemp` may not
# exist, so the logs fall back to flat files of the temporary directory and
# the declarations are published from there.
SUITE_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/forge-run-all-logs.XXXXXX" 2>/dev/null || true)"
if [ -n "$SUITE_LOG_DIR" ] && [ -d "$SUITE_LOG_DIR" ]; then
  SUITE_LOG_ROOT="$SUITE_LOG_DIR"
else
  SUITE_LOG_DIR=""
  SUITE_LOG_ROOT="${TMPDIR:-/tmp}"
fi
DECLARATION_TABLE="$SUITE_LOG_ROOT/forge-run-all-declarations.$$.tsv"
: > "$DECLARATION_TABLE"

while IFS= read -r test_file; do
  base="$(basename "$test_file")"
  echo ""
  echo "=== $base ==="

  # An isolated suite is neither executed nor counted as a pass: it stays in
  # the count of the battery and the reason is printed.
  #
  # The reason is part of the line and it is not a decoration: it names the
  # CAUSE with a stable code (a program can tell the causes apart) and with a
  # detail that says WHAT was searched and WHY it was not found (a person can
  # act on it). An isolated suite without a reason is indistinguishable from a
  # preparation that went wrong.
  if is_isolated "$test_file"; then
    TOTAL=$(( TOTAL + 1 ))
    ISOLATED=$(( ISOLATED + 1 ))
    echo "ISOLATED  $base  (suite aislada: no se ejecuta y no se cuenta como aprobada)  motivo=$ISOLATION_REASON_CODE: $ISOLATION_REASON_DETAIL"
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

  # The standard output of the suite is ALSO captured: the declarations of
  # the checks that do not apply are published there, and the exit code
  # alone cannot tell a suite that ran everything from a suite that ran with
  # declarations.
  #
  # `tee` is used when it exists (the output is streamed AND captured) and
  # the capture is a plain redirection when it does not (the battery also
  # runs with a minimal PATH, where `tee` is not installed).
  suite_log="$SUITE_LOG_ROOT/forge-run-all-suite.$$-$base.log"

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
  if command -v tee >/dev/null 2>&1; then
    if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
      FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE="$CLEANUP_WORKDIR/declarations-$CLEANUP_SUITE_INDEX.tsv" \
        bash "$test_file" </dev/null | tee "$suite_log"
    else
      bash "$test_file" </dev/null | tee "$suite_log"
    fi
    exit_code=${PIPESTATUS[0]}
  else
    if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
      FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE="$CLEANUP_WORKDIR/declarations-$CLEANUP_SUITE_INDEX.tsv" \
        bash "$test_file" </dev/null > "$suite_log"
    else
      bash "$test_file" </dev/null > "$suite_log"
    fi
    exit_code=$?
    if command -v cat >/dev/null 2>&1; then
      cat "$suite_log"
    fi
  fi
  set -e
  elapsed=$(( SECONDS - test_start ))

  # The declarations of this suite: the checks that do NOT apply. They are
  # neither passed nor failed: they are published with their reason code so
  # that the aggregate can be read by a program.
  suite_declared=0
  suite_codes=""
  while IFS= read -r declaration; do
    [ -n "$declaration" ] || continue
    suite_declared=$(( suite_declared + 1 ))
    declaration_code="$(printf '%s\n' "$declaration" | sed -n 's/.*motivo=\([A-Z0-9_]*\).*/\1/p')"
    [ -n "$declaration_code" ] || declaration_code="UNKNOWN"
    declaration_detail="$(printf '%s\n' "$declaration" | sed -n 's/.*motivo=[A-Z0-9_]*: //p')"
    suite_codes="$suite_codes $declaration_code"
    echo "DECLARED  $base  (no aplicable: no se cuenta como aprobada)  motivo=$declaration_code: $declaration_detail"
  done < <(grep -E '^[[:space:]]*DECLARA[[:space:]]' "$suite_log" 2>/dev/null || true)

  if [ "$suite_declared" -gt 0 ]; then
    DECLARED=$(( DECLARED + suite_declared ))
    DECLARED_SUITES=$(( DECLARED_SUITES + 1 ))
    printf '%s\t%s\t%s\n' "$base" "$suite_declared" "${suite_codes# }" >> "$DECLARATION_TABLE"
  fi

  # The log of the suite has served its purpose: it is build output and it
  # does not stay in the temporary space of the battery.
  rm -f "$suite_log"

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
echo " Declared:   $DECLARED  (checks no aplicables: no se cuentan como aprobados; suites con declaraciones: $DECLARED_SUITES)"
echo " Failed:     $FAILED"
echo " Duration:   ${total_elapsed}s"
echo "============================================================"

# The declarations, per suite and with their reason codes. A consumer of
# this summary can tell a battery that ran EVERYTHING from a battery that
# ran with declarations: the count and the codes are here, not only the
# exit code.
if [ -s "$DECLARATION_TABLE" ]; then
  echo ""
  echo " Declarations by suite (check no aplicable, no aprobado):"
  while IFS=$'\t' read -r declared_suite declared_count declared_codes; do
    [ -n "$declared_suite" ] || continue
    printf '  %s  %s  %s\n' "$declared_suite" "$declared_count" "$declared_codes"
  done < "$DECLARATION_TABLE"
fi

# The declaration of the cleanup of the PRODUCT of this battery is published
# BEFORE the exit: it is measured over the private /proc and it is written
# before the defensive cleanup of the containment.
if [ "$CLEANUP_STATE" = "OBSERVING" ]; then
  cleanup_finalize
elif [ -n "$CLEANUP_MARKER" ]; then
  # The observation could NOT be performed: the declaration is UNKNOWN and
  # the marker is left absent. An unknown cleanup is never a PASS.
  # shellcheck disable=SC2034  # estado documentado del agregado (no se lee)
  CLEANUP_AGGREGATE="UNKNOWN"
  echo ""
  echo " Limpieza del producto: UNKNOWN (no se pudo observar: $CLEANUP_STATE)"
  rm -f "$CLEANUP_MARKER" 2>/dev/null || true
fi

# Sweep tests/.tmp: suites clean their own artifacts on exit, but aborted or
# killed runs can leave residue behind, and a directory-based plugin install
# copies the whole working tree — stale fixtures once accumulated 285 MB here.
rm -rf "$SCRIPT_DIR/.tmp"

# The log of every suite is build output: it lives outside the repository
# and it is deleted with the rest of the temporary evidence.
rm -f "$DECLARATION_TABLE"
if [ -n "$SUITE_LOG_DIR" ]; then
  rm -rf "$SUITE_LOG_DIR"
fi

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
