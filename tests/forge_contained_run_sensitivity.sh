#!/usr/bin/env bash
# tests/forge_contained_run_sensitivity.sh — the SENSITIVITY of the battery
# of the containment.
#
# Every property of the acceptance contract has a way of being FALSE, and a
# battery that cannot detect a FALSE property certifies nothing. This harness
# MUTATES a COPY of the entry or of the consumer — NEVER the repository — and
# proves that the battery FAILS on every mutation.
#
# The mutants:
#
#   M1  accreditation-ignored  the accreditation of the interior FAILS and
#                               the guard that stops the scenario is removed:
#                               an UNACCREDITED frontier that runs the
#                               scenario anyway.
#   M2  accepts-anything       the consumer of the evidence accepts an
#                               absent, partial or corrupt receipt: BOTH
#                               gates (the evidence of the containment and
#                               the positive acceptance) are neutralised.
#   M3  no-wait                the launcher is never waited for: the closure
#                               is DECLARED without the contained environment
#                               having terminated.
#   M4  product-as-pass        the consumer converts a FAILURE of the product
#                               into a PASS because the defensive cleanup of
#                               the containment succeeded: the check of the
#                               consumer, the check of the gate and the
#                               cross-check of POSITIVE_ACCEPTANCE are all
#                               neutralised.
#   M5  no-mount-proc          the private /proc is not established: the
#                               frontier cannot be accredited and nothing can
#                               be certified.
#   M6  duplicate-after        a SECOND definition of forge_isolated_env is
#                               appended AT THE END of the helper: the dead
#                               one (the one that runs the command on the
#                               host) wins, every scenario leaves the
#                               containment and the suite stays green. This
#                               is the FAIL-OPEN TRAP of the helper.
#   M7  duplicate-before       the SAME second definition is inserted BEFORE
#                               the live one: the behaviour is still correct
#                               (the last definition still wins), so ONLY the
#                               statistical part of the check can detect it.
#                               It proves that the detector does not rely on
#                               the behaviour to find the duplication.
#   M8  aggregate-masks-fail   the AGGREGATE of the declarations of the
#                               cleanup of the product IGNORES a FAIL: a
#                               battery that could certify a product that did
#                               NOT clean up.
#   M9  closure-without-observation
#                               the CLOSURE is certified when the launcher was
#                               waited for and returned 0, WITHOUT observing
#                               the effective termination of the private
#                               PID 1: the certification "the signal was sent
#                               and then it ended" is reintroduced.
#   M10 signal-as-closure      a signal that was SENT certifies the closure
#                               on its own: the interruption is taken as the
#                               proof of the termination of PID 1.
#   M11 receipt-leak-on-stdout  the entry publishes the path of the receipt on
#                               the standard output of the consumer: the
#                               streams are no longer the ones of the scenario.
#   M12 no-fd9-publication      without `--receipt-out` the entry does not
#                               publish the path of the receipt on the
#                               dedicated descriptor 9.
#   M13 reader-ignores-pid1    the READER of the evidence does not require the
#                               observed termination of PID 1.
#   M14 reader-ignores-rc      the READER of the evidence does not require the
#                               RC 0 of the launcher.
#   H5  parental-check-off     the VERIFICATION of the parental relation of
#                               the registry of the V2 bank is annulled: a
#                               recycled PID would enter the registry and the
#                               teardown of the bank would destroy the
#                               process group of somebody else.
#
#   M18 no-pidfd-contract-none
#                               the contract of the V2 bank declares the RC
#                               of the ELIMINATED suite as NOT APPLICABLE
#                               again.
#   M19 launcher-not-recoverable
#                               the status of the launcher that could NOT be
#                               recovered is LAUNDERED into a clean zero: the
#                               entry certifies a closure whose launcher
#                               nobody observed the state of.
#   M26 invalid-state-as-signal
#                               the normalisation of the exit code
#                               REINTERPRETS an invalid state as a valid
#                               signal: "-137" becomes the signal 9 and
#                               "999" becomes the signal 871.
#   M27 verdict-without-observation
#                               the verdict of the cleanup of the harness
#                               stops requiring the OBSERVED absence: the
#                               state of the observation of the aftermath
#                               and the three verifications are dropped.
#   M28 stable-accepts-unobserved
#                               the STABLE entry goes back to the truthiness
#                               check of the absences: a None (an absence
#                               that could NOT be observed) is accepted.
#   M29 impossible-read-as-absence
#                               the observation of a PID turns a FAILED
#                               read into an ABSENCE: the process is
#                               declared gone, the aftermath is COMPLETE
#                               and the three absences are published as
#                               VERIFIED.
#   M30 protected-read-as-absence
#                               the verifier of the PROTECTED RESOURCES
#                               turns a FAILED read into an absence: it
#                               declares ABSENT and NOT_LISTENING and it
#                               passes with an observation that was never
#                               made.
#   M31 absent-interface-as-read
#                               the verifier of the PROTECTED RESOURCES
#                               counts a socket table whose INTERFACE IS
#                               ABSENT as a table that was READ: with both
#                               tables absent it publishes "NO EN ESCUCHA"
#                               and it exits with 0 WITHOUT having read a
#                               single table.
#   M32 network-reach-overclaimed
#                               the COMMENT that describes the effective
#                               restriction of the network claims that
#                               EVERY interpreter of the battery inherits
#                               it. It is FALSE: the restriction reaches
#                               the interpreters that load the wrapper or
#                               the `sitecustomize` of its directory, and
#                               a NESTED contained entry rebuilds the PATH
#                               of its scenario and does not inherit it.
#
# A failed mutant must NOT prevent the exterior cleanup: the harness still
# removes its own artefacts, the contained environment of the mutant still
# terminates and the receipt of the failed run is PRESERVED.
#
# The harness is NOT collected by tests/run-all.sh on purpose: it runs the
# whole battery once per mutant. It is run on demand, during the
# qualification of the containment.
#
# Compatible with bash 3.2+.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FORGE_ROOT="$(pwd)"
# The ROOT of the fixtures of THIS run.
#
# It is NOT a fixed path of a machine: it is derived from the temporary
# directory of the caller. The directory is CREATED here: `mktemp -d` does
# not create its parent and a harness that assumes one fails on a machine
# (or on a CI runner) that does not have it.
TMPDIR_BASE="${FORGE_TEST_TMP_ROOT:-${TMPDIR:-/tmp}}"
mkdir -p "$TMPDIR_BASE" 2>/dev/null || true
WORKDIR="$(mktemp -d "$TMPDIR_BASE/forge-contained-sensitivity.XXXXXX")" || exit 1
# The ROOT of the receipts of the contained runs: a directory of THIS run,
# derived from the PID of the harness, so that two harnesses never share it.
RECEIPT_ROOT="$TMPDIR_BASE/forge-contained-sensitivity-receipts.$$"
# The root of the receipts is DECLARED to the pieces that have to publish
# theirs (the runner of the detector), so that no one of them has to know a
# path of a machine.
export FORGE_TEST_RECEIPT_ROOT="$RECEIPT_ROOT"
ENTRY="${FORGE_TEST_ENTRY:-$FORGE_ROOT/tools/verification/forge-contained-run.sh}"
ISOLATION="$FORGE_ROOT/tests/isolation.sh"
AGGREGATE="$FORGE_ROOT/tests/forge_run_all_cleanup.py"
CI_VERIFIER="$FORGE_ROOT/tools/ci/v2-safety.sh"
V2_SCENARIOS="$FORGE_ROOT/tests/forge_v2_safety_scenarios.sh"
V2_REGISTRY_DETECTOR="$FORGE_ROOT/tests/forge_v2_registry_parity.py"
ADMISSION_GUARD="$FORGE_ROOT/tools/verification/require-v2-containment.sh"
V2_HARNESS="$FORGE_ROOT/tests/forge_v2_safety_harness.py"
V2_STABLE="$FORGE_ROOT/tests/forge_v2_safety.sh"
V2_CONTRACT_PROBE="$FORGE_ROOT/tests/forge_v2_contract_probe.py"
BRANCH_GUARD="$FORGE_ROOT/shared/branch-guard.sh"
BRANCH_GUARD_DETECTOR="$FORGE_ROOT/tests/branch_guard_throttle_isolation.sh"

# The RUNNER of the detector of the registry of the V2 bank.
#
# The detector LOADS the program of the guard and it CREATES processes:
# neither may happen outside the frontier, so the detector REQUIRES an
# accredited boundary and every EXTERNAL invocation of it goes through the
# containment entry. The runner publishes the verdict of the detector (its
# own RC) and not the RC of the entry: the RC of the entry is the RC of the
# CONTAINMENT and not the verdict of the battery of the detector.
REGISTRY_RUNNER="$WORKDIR/run-registry-detector.sh"

FAIL=0
PASS=0

# The MODE of the harness.
#
# "full" (the default) runs the control, every mutant and the self-tests.
# "self-test" runs ONLY the self-tests of the harness: it exists so that a
# COPY of the harness with a defect in its own logic can be executed
# cheaply, and that copy MUST fail.
SENSITIVITY_MODE="${FORGE_SENSITIVITY_MODE:-full}"

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

# The mutation is applied to a COPY. The copy of the entry and the copy of
# the consumer live together with the helper of the signal, because the
# consumer derives the path of that helper from its own directory.
#
# The entry under test can be OVERRIDDEN with FORGE_TEST_ENTRY, so that the
# qualification of a CANDIDATE FIX (a copy OUTSIDE the repository) can be run
# without touching the repository. The default is the production entry.
prepare_copies() {
  local directory="$1"
  mkdir -p "$directory" || return 1
  cp "$ENTRY" "$directory/entry.sh" || return 1
  cp "$ISOLATION" "$directory/isolation.sh" || return 1
  cp "$FORGE_ROOT/tests/forge_own_signal.py" "$directory/forge_own_signal.py" || return 1
  cp "$AGGREGATE" "$directory/forge_run_all_cleanup.py" || return 1
  cp "$CI_VERIFIER" "$directory/v2-safety.sh" || return 1
  cp "$FORGE_ROOT/tests/forge_shell_defs.py" "$directory/forge_shell_defs.py" || return 1
  cp "$FORGE_ROOT/tests/forge_network_free.py" "$directory/forge_network_free.py" || return 1
  # El detector del registro del banco V2: la bateria comprueba que EXIGE
  # una frontera acreditada, y el mutante D3 lo mide sobre una COPIA.
  cp "$V2_REGISTRY_DETECTOR" "$directory/forge_v2_registry_parity.py" || return 1
  # The suite of la instalacion: the scanner de la red la escanea, y el
  # mutante N7 la vuelve a abrir un socket.
  cp "$FORGE_ROOT/tests/opencode_install_integration.sh" \
    "$directory/opencode_install_integration.sh" || return 1
  # La suite de la instalacion (la que instalaba la trampa EXIT que leia un
  # 'local' de la funcion que la instalaba): el mutante G9 la devuelve a ese
  # estado y la bateria tiene que detectarlo.
  cp "$FORGE_ROOT/tests/install_integration.sh" \
    "$directory/install_integration.sh" || return 1
  # The gate of admission (the kernel handle of the invoking namespace),
  # the harness and the runner of the V2 bank and the probe of its
  # contract: they are the pieces that the new checks measure.
  cp "$ADMISSION_GUARD" "$directory/require-v2-containment.sh" || return 1
  cp "$V2_HARNESS" "$directory/forge_v2_safety_harness.py" || return 1
  cp "$V2_SCENARIOS" "$directory/forge_v2_safety_scenarios.sh" || return 1
  cp "$V2_CONTRACT_PROBE" "$directory/forge_v2_contract_probe.py" || return 1
  # The STABLE entry of the V2 bank: it is the consumer that validates the
  # report of the harness, and the criterion of the ausencia verificada is
  # UNIFORM across the entries, so it is mutated like any other piece.
  cp "$V2_STABLE" "$directory/forge_v2_safety.sh" || return 1
  # The verifier of the PROTECTED RESOURCES: it is the consumer that
  # declares the state of the protected resources, and the criterion of the
  # observation (an impossible observation is NOT an absence) is UNIFORM
  # with the one of the harness, so it is mutated like any other piece.
  cp "$FORGE_ROOT/tests/forge_protected_resources.py" \
    "$directory/forge_protected_resources.py" || return 1
  return 0
}

# The RUNNER of the detector of the registry of the V2 bank.
#
# The detector REQUIRES an accredited boundary (it loads the program of the
# guard and it creates processes), so every EXTERNAL invocation of it goes
# through the containment entry. The RC that this runner publishes is the
# verdict of the DETECTOR (it is written by the detector itself in its own
# result file) and not the RC of the entry: the RC of the entry is the RC
# of the CONTAINMENT and not the verdict of the battery of the detector.
write_registry_runner() {
  cat > "$REGISTRY_RUNNER" <<'REGISTRY_RUNNER_EOF'
#!/usr/bin/env bash
# usage: run-registry-detector.sh <scenarios> <detector> <identities> <result>
set -u
scenarios="$1"
detector="$2"
identities="$3"
result="$4"
entry="${FORGE_TEST_ENTRY:?}"
# The root of the receipts is DECLARED by the caller: it is a directory of
# THIS invocation and not a path of a machine. The fallback (a directory
# unique to this process, under the temporary directory of the caller) keeps
# the runner usable on its own.
receipt_root="${FORGE_TEST_RECEIPT_ROOT:-${TMPDIR:-/tmp}/forge-contained-sensitivity-receipts-$$}"
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/forge-registry-run.XXXXXX")" || exit 70

bash "$entry" \
  --receipt-dir "$receipt_root" \
  --receipt-out "$run_dir/pointer.txt" \
  --scenario-timeout 120 --close-timeout 10 -- \
  python3 "$detector" \
    --scenarios "$scenarios" \
    --identities "$identities" \
    --result-file "$result"
entry_rc=$?
printf 'REGISTRY_ENTRY_RC=%s\n' "$entry_rc"
if [ -s "$run_dir/pointer.txt" ]; then
  IFS= read -r receipt < "$run_dir/pointer.txt"
  printf 'REGISTRY_RECEIPT=%s\n' "$receipt"
fi
rc=1
if [ -s "$result" ]; then
  IFS= read -r rc < "$result" || rc=1
fi
exit "$rc"
REGISTRY_RUNNER_EOF
  chmod +x "$REGISTRY_RUNNER" || return 1
  return 0
}

# failing_tests <log>
# Prints the name of every test of the battery that failed.
failing_tests() {
  awk '/^--- / { name = substr($0, 5) } /^  FAIL: / { print name }' "$1" | sort -u
}

# The BASELINE of the control: the checks that ALREADY fail against the
# unmutated code.
#
# A mutant is only SENSITIVE if it breaks a check that the CONTROL keeps
# green. When the control itself has a failure that is NOT caused by a
# mutation (a defect of the production code, for instance), the mutant would
# "fail the battery" for the wrong reason and the sensitivity of the battery
# would be credited to a cause that has nothing to do with the mutation. The
# comparison is therefore made against the baseline of the control, not
# against "the battery returned a non-zero RC".
#
# The baseline is a LIST OF NAMES, one per line: the names are stored and
# they are queried in the SAME format. A baseline that is stored as a list
# separated by spaces and queried as a list separated by newlines does not
# recognise ANY of its own failures, and every mutant that breaks a check
# that the control already breaks is credited as sensitive.
CONTROL_FAILING=""

# control_baseline <log>
#
# Computes the BASELINE of the control: the checks that ALREADY fail against
# the unmutated code. The names are stored AND they are queried in the SAME
# format (one name per line).
control_baseline() {
  local log="$1"
  CONTROL_FAILING="$(failing_tests "$log")"
}

control_fails() {
  local wanted="$1" name
  while IFS= read -r name; do
    [ "$name" = "$wanted" ] && return 0
  done <<EOF
$CONTROL_FAILING
EOF
  return 1
}

# run_battery <entry> <isolation> <log>
# Runs the whole battery against the given copies and returns its RC.
run_battery() {
  local entry="$1" isolation="$2" log="$3"
  local aggregate verifier battery
  aggregate="$(dirname "$entry")/forge_run_all_cleanup.py"
  verifier="$(dirname "$entry")/v2-safety.sh"
  # The SOURCE of the battery can be pointed at a COPY: the criterion of the
  # REACH of the restriction of the network is a criterion about the comment
  # that declares it, and the mutant M32 measures it against a copy that
  # carries the former claim.
  battery="${FORGE_TEST_BATTERY_SOURCE:-$FORGE_ROOT/tests/forge_contained_run_unit.sh}"
  FORGE_TEST_ENTRY="$entry" FORGE_TEST_ISOLATION="$isolation" \
    FORGE_TEST_CLEANUP_AGGREGATE="$aggregate" \
    FORGE_TEST_CLEANUP_PROBE="$aggregate" \
    FORGE_TEST_V2_CI_VERIFIER="$verifier" \
    FORGE_TEST_SHELL_DEFS_SCANNER="$(dirname "$entry")/forge_shell_defs.py" \
    FORGE_TEST_NETWORK_SCANNER="$(dirname "$entry")/forge_network_free.py" \
    FORGE_TEST_ADMISSION_GUARD="$(dirname "$entry")/require-v2-containment.sh" \
    FORGE_TEST_V2_HARNESS="$(dirname "$entry")/forge_v2_safety_harness.py" \
    FORGE_TEST_V2_RUNNER="$(dirname "$entry")/forge_v2_safety_scenarios.sh" \
    FORGE_TEST_V2_STABLE="$(dirname "$entry")/forge_v2_safety.sh" \
    FORGE_TEST_V2_CONTRACT_PROBE="$(dirname "$entry")/forge_v2_contract_probe.py" \
    FORGE_TEST_V2_REGISTRY_DETECTOR="$(dirname "$entry")/forge_v2_registry_parity.py" \
    FORGE_TEST_PROTECTED_RESOURCES="$(dirname "$entry")/forge_protected_resources.py" \
    FORGE_TEST_BATTERY_SOURCE="$battery" \
    bash "$FORGE_ROOT/tests/forge_contained_run_unit.sh" >"$log" 2>&1
}

# classify_external_failure <log> <expected-pattern>
#
# 0 -> the failure of the detector is ATTRIBUTED to the expected check: the
#      mutant broke EXACTLY the property it was supposed to break;
# 1 -> the failure is NOT attributable: it is an error of the infrastructure
#      (the detector could not even load the code under test) or a failure
#      of a different check;
# 2 -> the detector did not fail at all.
#
# The distinction matters: a detector that cannot load the mutated code
# fails for a reason that has NOTHING to do with the mutation, and crediting
# that as sensitivity would certify a battery that detects nothing.
EXTERNAL_INFRA_PATTERNS='no se pudo leer el runner de escenarios|no contiene el programa del guard|no se cargo: refresh_registry|no define refresh_registry|no define children_of|Traceback (most recent call last)'

classify_external_failure() {
  local log="$1" pattern="$2"
  [ -s "$log" ] || return 2
  if grep -qE "$EXTERNAL_INFRA_PATTERNS" "$log" 2>/dev/null; then
    return 1
  fi
  if grep -qF "$pattern" "$log" 2>/dev/null; then
    return 0
  fi
  return 1
}

# check_external_battery <label> <log> <control-log> <expected-pattern>
#                       --control <command...> --mutant <command...>
#
# Runs an EXTERNAL battery (the detector of the registry of the V2 bank)
# against a mutated copy and proves that it FAILS **for the right reason**.
#
#   * the CONTROL of the SAME detector is run FIRST, against the unmutated
#     code: a detector that is not green against the unmutated code proves
#     nothing, and the failure of the mutant could be its own defect;
#   * the failure of the mutant must be ATTRIBUTED to the expected check: an
#     error of the infrastructure is NOT sensitivity.
check_external_battery() {
  local label="$1" log="$2" control_log="$3" pattern="$4"
  shift 4
  local control_cmd=() mutant_cmd=() section=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --control) section=control ;;
      --mutant) section=mutant ;;
      *)
        if [ "$section" = control ]; then
          control_cmd+=("$1")
        else
          mutant_cmd+=("$1")
        fi
        ;;
    esac
    shift
  done

  local rc=0
  "${control_cmd[@]}" > "$control_log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "el control del detector de $label es VERDE: la sensibilidad se mide contra una base que pasa (rc=0)"
  else
    fail "el control del detector de $label YA FALLA (rc=$rc): la sensibilidad del mutante no se puede atribuir"
    sed -n '1,20p' "$control_log" | sed 's/^/      /' >&2
    return
  fi

  rc=0
  "${mutant_cmd[@]}" > "$log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "el mutante $label hace FALLAR su bateria (rc=$rc)"
  else
    fail "el mutante $label NO hace fallar su bateria: la bateria no detecta esa ruptura"
    return
  fi

  local verdict=0
  classify_external_failure "$log" "$pattern" || verdict=$?
  if [ "$verdict" -eq 0 ]; then
    pass "el fallo del mutante $label se ATRIBUYE a la comprobacion parental (no a un error de infraestructura)"
  else
    fail "el fallo del mutante $label NO se atribuye a la comprobacion parental: es un error de infraestructura o un fallo distinto"
    printf '      (diagnostico del detector: %s)\n' \
      "$(grep -h 'FAIL:' "$log" 2>/dev/null | head -n 3 | tr '\n' ' ')" >&2
  fi
  printf '      (bateria del mutante %s: %s)\n' "$label" \
    "$(grep -h 'FAIL:' "$log" 2>/dev/null | head -n 3 | tr '\n' ' ')"
}

# survivor_probe <entry> <label>
#
# Runs the entry (the mutant or the production one) with a scenario that keeps
# a heartbeat inside the frontier and checks TWO things:
#
#   * the contained environment really TERMINATED: the heartbeat froze. A
#     contained environment that is still alive would be a survivor of this
#     lot, and the rule is that no own process survives.
#   * the receipt of the run is still there: the evidence of a failed run is
#     NEVER deleted.
survivor_probe() {
  local entry="$1" label="$2"
  local probe="$WORKDIR/probe-$label"
  mkdir -p "$probe"

  cat > "$probe/heartbeat.sh" <<'HEARTBEAT_EOF'
#!/bin/sh
printf 'READY\n' > "$2"
while true; do
  printf 'x' >> "$1"
  sleep 0.05
done
HEARTBEAT_EOF
  chmod +x "$probe/heartbeat.sh"

  local rc=0
  bash "$entry" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$probe/pointer.txt" \
    --scenario-timeout 6 \
    --close-timeout 2 \
    -- /bin/sh "$probe/heartbeat.sh" "$probe/hb.txt" "$probe/ready.txt" \
    >"$probe/out.txt" 2>"$probe/err.txt" || rc=$?

  # The heartbeat must FREEZE: the contained environment must be gone.
  # First the heartbeat must APPEAR: a contained environment that never
  # started has nothing that could survive, and that is a different (and
  # legitimate) outcome of a mutant that fails closed.
  local appeared=NO waited=0
  while [ "$waited" -lt 60 ]; do
    if [ -s "$probe/hb.txt" ]; then
      appeared=YES
      break
    fi
    sleep 0.25
    waited=$((waited + 1))
  done

  if [ "$appeared" = "NO" ]; then
    pass "el mutante $label no arranco el entorno contenido: no hay nada que pueda sobrevivir"
  else
    local previous="" current frozen=NO
    waited=0
    while [ "$waited" -lt 120 ]; do
      current="$(wc -c < "$probe/hb.txt" 2>/dev/null || printf '0')"
      if [ -n "$previous" ] && [ "$current" = "$previous" ]; then
        frozen=YES
        break
      fi
      previous="$current"
      sleep 0.5
      waited=$((waited + 1))
    done
    if [ "$frozen" = "YES" ]; then
      pass "el mutante $label no dejo el entorno contenido vivo: el latido se congelo"
    else
      fail "el mutante $label dejo el entorno contenido VIVO: el latido sigue creciendo"
    fi
  fi

  # The receipt of the run survives: the evidence of a failed run is kept.
  local receipt=""
  [ -s "$probe/pointer.txt" ] && IFS= read -r receipt < "$probe/pointer.txt"
  if [ -n "$receipt" ] && [ -s "$receipt" ]; then
    pass "el mutante $label conservo el recibo de su corrida ($receipt)"
  else
    fail "el mutante $label no conservo el recibo de su corrida"
  fi
  printf '  (rc de la sonda del mutante %s: %s)\n' "$label" "$rc"
}

# check_mutant <label> <entry> <isolation> <expected-test> [expected-test...]
#
# Runs the battery against the mutated copies and proves that it FAILED, and
# that it failed in the test that covers the broken property.
check_mutant() {
  local label="$1" entry="$2" isolation="$3"
  shift 3
  local expected=("$@")
  local log="$WORKDIR/battery-$label.log"
  local rc=0

  run_battery "$entry" "$isolation" "$log" || rc=$?

  if [ "$rc" -ne 0 ]; then
    pass "el mutante $label hace FALLAR la bateria (rc=$rc)"
  else
    fail "el mutante $label NO hace fallar la bateria: la bateria no detecta esa ruptura"
  fi

  local detected="" name
  for wanted in "${expected[@]}"; do
    # The check that covers the broken property must FAIL in the mutant AND
    # must be GREEN in the control: otherwise the mutant is not sensitive to
    # the property it breaks.
    if control_fails "$wanted"; then
      continue
    fi
    while IFS= read -r name; do
      if [ "$name" = "$wanted" ]; then
        detected="$name"
        break
      fi
    done <<EOF
$(failing_tests "$log")
EOF
    [ -n "$detected" ] && break
  done
  if [ -n "$detected" ]; then
    pass "el mutante $label fallo en la comprobacion que cubre la propiedad rota ($detected)"
  else
    fail "el mutante $label fallo, pero NO en la comprobacion esperada (esperadas: ${expected[*]})"
    printf '      pruebas que fallaron: %s\n' "$(failing_tests "$log" | tr '\n' ' ')" >&2
    if [ -n "$CONTROL_FAILING" ]; then
      printf '      el control ya fallaba en: %s\n' \
        "$(printf '%s' "$CONTROL_FAILING" | tr '\n' ' ')" >&2
    fi
  fi
  printf '      (pruebas que fallaron en el mutante %s: %s)\n' \
    "$label" "$(failing_tests "$log" | tr '\n' ' ')"

  # The receipt of the failed battery runs is preserved: the evidence of a
  # failed run is never deleted. The paths are the ones that the battery
  # itself published: the receipt root is never enumerated and it is NOT a
  # path of a machine. The pattern is the NAMING CONVENTION of the entry
  # (a "run-*" directory with a "receipt.txt" inside), so the root is
  # derived from the real output of the run.
  local preserved=YES checked=0 receipt
  while IFS= read -r receipt; do
    [ -n "$receipt" ] || continue
    checked=$((checked + 1))
    [ -s "$receipt" ] || preserved=NO
  done <<EOF
$(grep -hoE '(^|[[:space:]])/[^[:space:]]*/run-[^[:space:]]*/receipt\.txt' "$log" 2>/dev/null \
  | sed -E 's/^[[:space:]]+//' | sort -u)
EOF
  if [ "$preserved" = "YES" ]; then
    pass "el mutante $label preservo los recibos de sus corridas fallidas ($checked comprobados)"
  else
    fail "el mutante $label borro un recibo de una corrida fallida"
  fi
}

echo "================================"
echo " forge_contained_run_sensitivity.sh"
echo "================================"

# ---------------------------------------------------------------------------
# The SELF-TESTS of the harness.
#
# The harness is the instrument that MEASURES the sensitivity: a defect in
# its own logic would certify a battery that detects nothing. Its logic is
# therefore proven with the same rigour: a COPY of the harness with the
# defect is executed (in the mode "self-test") and it MUST fail.
# ---------------------------------------------------------------------------
self_test_external_attribution() {
  local work="$WORKDIR/self-test-attribution"
  mkdir -p "$work"
  cat > "$work/detector-roto.sh" <<'ROTO_EOF'
#!/bin/sh
printf '  FAIL: el runner de escenarios no contiene el programa del guard (refresh_registry)\n'
exit 1
ROTO_EOF
  cat > "$work/detector-verde.sh" <<'VERDE_EOF'
#!/bin/sh
printf '  PASS: el registro RECHAZA un PID cuya relacion parental NO es el supervisor\n'
exit 0
VERDE_EOF
  cat > "$work/detector-parental.sh" <<'PARENTAL_EOF'
#!/bin/sh
printf '  FAIL: el registro ADMITE un PID cuya relacion parental NO es el supervisor\n'
exit 1
PARENTAL_EOF
  chmod +x "$work"/detector-*.sh

  local saved_pass="$PASS" saved_fail="$FAIL"

  # A mutant whose failure is an ERROR OF THE INFRASTRUCTURE must NOT be
  # credited as sensitive.
  #
  # The verdict of the inner call is read BEFORE the counters of the harness
  # are restored: restoring them must not erase the verdict of the
  # auto-prueba.
  PASS=0
  FAIL=0
  check_external_battery "SELF-TEST" "$work/roto.log" "$work/control.log" \
    "el registro ADMITE un PID cuya relacion parental NO es el supervisor" \
    --control "$work/detector-verde.sh" --mutant "$work/detector-roto.sh"
  local refused="$FAIL"

  # A mutant that breaks EXACTLY the parental check IS attributed.
  PASS=0
  FAIL=0
  check_external_battery "SELF-TEST" "$work/parental.log" "$work/control.log" \
    "el registro ADMITE un PID cuya relacion parental NO es el supervisor" \
    --control "$work/detector-verde.sh" --mutant "$work/detector-parental.sh"
  local attributed="$FAIL"

  # The counters of the harness are restored ONCE, con los dos veredictos ya
  # leidos: restaurarlos entre medias borraria el veredicto de la primera
  # comprobacion.
  PASS="$saved_pass"
  FAIL="$saved_fail"
  if [ "$refused" -ne 0 ]; then
    pass "el arnes NO atribuye a la comprobacion parental un fallo que es un error de infraestructura"
  else
    fail "el arnes atribuyo a la comprobacion parental un fallo que es un error de infraestructura"
  fi

  if [ "$attributed" -eq 0 ]; then
    pass "el arnes atribuye a la comprobacion parental el fallo del mutante que la rompe"
  else
    fail "el arnes NO atribuyo a la comprobacion parental el fallo del mutante que la rompe"
  fi
}

self_test_control_baseline() {
  local work="$WORKDIR/self-test-baseline"
  mkdir -p "$work"
  # The baseline has MORE THAN ONE failing check on purpose: a baseline that
  # is stored as a list separated by spaces and queried as a list separated
  # by newlines does not recognise ANY of its own failures, and that is only
  # visible with more than one name.
  cat > "$work/baseline.log" <<'BASELINE_EOF'
--- test_a_que_ya_fallaba
  FAIL: este check ya fallaba contra el codigo sin mutar
--- test_b_que_ya_fallaba
  FAIL: este check tambien fallaba contra el codigo sin mutar
--- test_otro_check
  PASS: este check pasa
BASELINE_EOF
  local saved="$CONTROL_FAILING"
  control_baseline "$work/baseline.log"
  if control_fails "test_a_que_ya_fallaba" && control_fails "test_b_que_ya_fallaba"; then
    pass "la linea base del control reconoce TODOS los checks que ya fallaban"
  else
    fail "la linea base del control NO reconoce los checks que ya fallaban: un mutante que rompe un check que el control ya rompia contaria como sensible"
  fi
  if control_fails "test_otro_check"; then
    fail "la linea base del control reconoce un check que el control mantiene VERDE"
  else
    pass "la linea base del control NO reconoce un check que el control mantiene VERDE"
  fi
  CONTROL_FAILING="$saved"
}

run_self_tests() {
  echo "--- auto-prueba: la atribucion de la sensibilidad"
  self_test_external_attribution
  echo "--- auto-prueba: la linea base del control"
  self_test_control_baseline
}

if [ "$SENSITIVITY_MODE" = "self-test" ]; then
  run_self_tests
  echo ""
  echo "================================"
  echo " Passed: $PASS"
  if [ "$FAIL" -ne 0 ]; then
    echo " FAIL: some tests failed" >&2
    exit 1
  fi
  echo " ALL PASS"
  exit 0
fi


# ---------------------------------------------------------------------------
# CONTROL: the battery PASSES against the production copies. A battery that
# fails on the unmutated code certifies nothing.
# ---------------------------------------------------------------------------
echo "--- control: la bateria pasa contra las copias sin mutar"
control_dir="$WORKDIR/control"
prepare_copies "$control_dir" || exit 1
control_log="$WORKDIR/battery-control.log"
control_rc=0
run_battery "$control_dir/entry.sh" "$control_dir/isolation.sh" "$control_log" || control_rc=$?
control_baseline "$control_log"
if [ "$control_rc" -eq 0 ]; then
  pass "la bateria pasa contra la entrada y el consumidor sin mutar (rc=0)"
else
  fail "la bateria falla contra la entrada y el consumidor SIN mutar (rc=$control_rc)"
  sed -n '1,40p' "$control_log" >&2
  printf '      pruebas que fallaron en el control: %s\n' \
    "$(failing_tests "$control_log" | tr '\n' ' ')" >&2
  printf '      (el control marca la BASELINE: un mutante solo es SENSIBLE si rompe una comprobacion que el control mantiene VERDE)\n' >&2
fi

# ---------------------------------------------------------------------------
# The control of the EXTERNAL detector.
#
# The detector of the registry of the V2 bank (tests/forge_v2_registry_parity.py)
# is a battery of its own, and the mutants of the H5 vector are measured
# against it. A detector that is NOT green against the unmutated code proves
# nothing, and the failure of a mutant could be its own defect instead of
# the effect of the mutation. The general control therefore INCLUDES it.
#
# The detector is run with the identities file of its own processes, so that
# the harness can verify that it does not leave any process of its own
# alive.
# ---------------------------------------------------------------------------
echo "--- control: el detector externo del registro del banco V2 pasa sin mutar"
write_registry_runner || exit 1
control_registry_log="$WORKDIR/battery-control-registry.log"
control_registry_identities="$WORKDIR/control-registry-identities.txt"
control_registry_result="$WORKDIR/control-registry-result.txt"
: > "$control_registry_identities"
: > "$control_registry_result"
control_registry_rc=0
FORGE_TEST_ENTRY="$ENTRY" \
  "$REGISTRY_RUNNER" "$V2_SCENARIOS" "$V2_REGISTRY_DETECTOR" \
    "$control_registry_identities" "$control_registry_result" \
    > "$control_registry_log" 2>&1 || control_registry_rc=$?
if [ "$control_registry_rc" -eq 0 ]; then
  pass "el detector externo del registro del banco V2 pasa contra el codigo sin mutar (rc=0)"
else
  fail "el detector externo del registro del banco V2 YA FALLA sin mutar (rc=$control_registry_rc)"
  sed -n '1,30p' "$control_registry_log" | sed 's/^/      /' >&2
fi

# The detector runs INSIDE the accredited boundary: the verdict of its own
# battery is published in its result file and the RC of the entry is the RC
# of the CONTAINMENT. The closure of that containment is what certifies
# that the detector left NO process of its own alive: the PIDs that the
# detector publishes are LOCAL to its namespace and they say NOTHING about
# the host, so they are NEVER compared with the /proc of the host.
registry_receipt=""
if grep -q '^REGISTRY_RECEIPT=' "$control_registry_log" 2>/dev/null; then
  registry_receipt="$(sed -n 's/^REGISTRY_RECEIPT=//p' "$control_registry_log" | head -n 1)"
fi
if [ -n "$registry_receipt" ] && [ -s "$registry_receipt" ] \
  && grep -qx 'CLOSURE=CONFIRMED' "$registry_receipt" \
  && grep -qx 'PID1_COMPLETION_OBSERVED=PASS' "$registry_receipt"; then
  pass "el detector externo se ejecuto DENTRO de la frontera acreditada y su cierre fue confirmado"
else
  fail "el detector externo no se ejecuto dentro de una frontera acreditada con cierre confirmado"
  sed -n '1,10p' "$control_registry_log" | sed 's/^/      /' >&2
fi

# ---------------------------------------------------------------------------
# M1: an unaccredited frontier that runs the scenario anyway.
# ---------------------------------------------------------------------------
echo "--- M1: frontera no acreditada que ejecuta el escenario"
m1="$WORKDIR/m1"
prepare_copies "$m1" || exit 1
python3 - "$m1/entry.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
pairs = [
    ('[ "$pid1_stat" != 1 ]', '[ "$pid1_stat" != 1 ] || [ 1 = 1 ]'),
    ('if [ "$accreditation_reason" != PASS ]; then', 'if false; then'),
]
for old, new in pairs:
    if old not in source:
        sys.stderr.write("M1: ancla no encontrada: %r\n" % old)
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M1: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M1" "$m1/entry.sh" "$m1/isolation.sh" \
    "test_an_unaccredited_boundary_does_not_execute_the_scenario"
  survivor_probe "$m1/entry.sh" "M1"
fi

# ---------------------------------------------------------------------------
# M2: a consumer that accepts an absent or corrupt receipt.
#
# The consumer has TWO gates: the evidence of the containment and the
# positive acceptance. The mutation neutralises BOTH of them, because a
# consumer that accepts everything is exactly the property that must break.
# ---------------------------------------------------------------------------
echo "--- M2: consumidor que acepta un recibo ausente o corrupto"
m2="$WORKDIR/m2"
prepare_copies "$m2" || exit 1
python3 - "$m2/isolation.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
pairs = [
    (
        'forge_receipt_containment_evidence() {\n  local receipt="$1" field value\n',
        'forge_receipt_containment_evidence() {\n  return 0\n}\n\n'
        'forge_receipt_containment_evidence_real() {\n  local receipt="$1" field value\n',
    ),
    (
        'forge_receipt_positive_acceptance() {\n'
        '  local receipt="$1" scenario_rc expected_rc declared value\n',
        'forge_receipt_positive_acceptance() {\n  return 0\n}\n\n'
        'forge_receipt_positive_acceptance_real() {\n'
        '  local receipt="$1" scenario_rc expected_rc declared value\n',
    ),
]
for old, new in pairs:
    if old not in source:
        sys.stderr.write("M2: ancla no encontrada: %r\n" % old)
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M2: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M2" "$m2/entry.sh" "$m2/isolation.sh" \
    "test_the_reader_rejects_untrustworthy_evidence" \
    "test_the_reader_rejects_contradictory_evidence" \
    "test_an_unaccredited_boundary_does_not_execute_the_scenario"
  survivor_probe "$m2/entry.sh" "M2"
fi

# ---------------------------------------------------------------------------
# M3: a closure declared without waiting for the contained environment.
# ---------------------------------------------------------------------------
echo "--- M3: cierre no confirmado declarado como cerrado"
m3="$WORKDIR/m3"
prepare_copies "$m3" || exit 1
python3 - "$m3/entry.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = '    wait "$runner_pid"'
new = '    :'
if old not in source:
    sys.stderr.write("M3: ancla no encontrada\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M3: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M3" "$m3/entry.sh" "$m3/isolation.sh" \
    "test_a_normal_exit_is_certifiable" \
    "test_an_interruption_closes_the_contained_environment" \
    "test_a_timeout_closes_the_contained_environment" \
    "test_the_boundary_and_the_closure_are_accredited"
  survivor_probe "$m3/entry.sh" "M3"
fi

# ---------------------------------------------------------------------------
# M4: the defensive cleanup turns a failure of the PRODUCT into a PASS.
#
# The result of the product is enforced in THREE places: the check of the
# consumer, the check of the gate of the positive acceptance and the
# CROSS-CHECK of the flag POSITIVE_ACCEPTANCE that the receipt declares. The
# mutation neutralises all three, so the consumer accepts a receipt whose
# product did NOT clean up.
# ---------------------------------------------------------------------------
echo "--- M4: la limpieza defensiva convierte un fallo del producto en PASS"
m4="$WORKDIR/m4"
prepare_copies "$m4" || exit 1
python3 - "$m4/isolation.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
pairs = [
    ('  if [ "$product_result" != "PASS" ]; then', '  if false; then'),
    ('  if [ "$value" != "PASS" ]; then', '  if false; then'),
    ('  if [ "$declared" != "YES" ]; then', '  if false; then'),
]
for old, new in pairs:
    if old not in source:
        sys.stderr.write("M4: ancla no encontrada: %r\n" % old)
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M4: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M4" "$m4/entry.sh" "$m4/isolation.sh" \
    "test_the_product_result_is_separated_from_the_defensive_one" \
    "test_a_detached_descendant_does_not_survive_the_closure"
  survivor_probe "$m4/entry.sh" "M4"
fi

# ---------------------------------------------------------------------------
# M5: the private /proc is not established.
# ---------------------------------------------------------------------------
echo "--- M5: el /proc privado no se establece"
m5="$WORKDIR/m5"
prepare_copies "$m5" || exit 1
python3 - "$m5/entry.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = '--map-root-user --pid --fork --kill-child=KILL --mount-proc'
new = '--map-root-user --pid --fork --kill-child=KILL'
if old not in source:
    sys.stderr.write("M5: ancla no encontrada\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M5: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M5" "$m5/entry.sh" "$m5/isolation.sh" \
    "test_a_normal_exit_is_certifiable" \
    "test_the_boundary_and_the_closure_are_accredited" \
    "test_the_frontier_is_private_and_the_host_is_not_inspected"
  survivor_probe "$m5/entry.sh" "M5"
fi

# ---------------------------------------------------------------------------
# M6: a SECOND definition of forge_isolated_env appended at the END of the
#      helper: the dead one (the one that runs the command on the host) wins
#      and every scenario leaves the containment. The suite would still be
#      green without the check that detects the duplication.
# ---------------------------------------------------------------------------
echo "--- M6: segunda definicion de forge_isolated_env al final del helper"
m6="$WORKDIR/m6"
prepare_copies "$m6" || exit 1
python3 - "$m6/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

DEAD = r'''
# forge_isolated_env <home> <command> [args...] (DEFINICION MUERTA)
forge_isolated_env() {
  local home="$1"
  shift

  mkdir -p "$home/.config" "$home/.cache" \
    "$home/.local/share" "$home/.local/state"

  env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    FORGE_OPENCODE_BIN_DIR="$home/.local/share/forge/opencode-v2" \
    "$@"
}
'''

if "forge_isolated_env() {" not in source:
    sys.stderr.write("M6: ancla no encontrada\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source + DEAD)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M6: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M6" "$m6/entry.sh" "$m6/isolation.sh" \
    "test_the_isolation_helper_has_a_single_definition_of_the_entry"
  survivor_probe "$m6/entry.sh" "M6"
fi

# ---------------------------------------------------------------------------
# M7: the SAME second definition, but inserted BEFORE the live one: the
#      behaviour is still correct and ONLY the statistical part of the check
#      can detect the duplication.
# ---------------------------------------------------------------------------
echo "--- M7: segunda definicion de forge_isolated_env antes de la viva"
m7="$WORKDIR/m7"
prepare_copies "$m7" || exit 1
python3 - "$m7/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

DEAD = r'''# forge_isolated_env <home> <command> [args...] (DEFINICION MUERTA)
forge_isolated_env() {
  local home="$1"
  shift

  mkdir -p "$home/.config" "$home/.cache" \
    "$home/.local/share" "$home/.local/state"

  env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_CACHE_HOME="$home/.cache" \
    XDG_DATA_HOME="$home/.local/share" \
    XDG_STATE_HOME="$home/.local/state" \
    FORGE_OPENCODE_BIN_DIR="$home/.local/share/forge/opencode-v2" \
    "$@"
}

'''

ANCHOR = 'forge_isolated_env() {\n  local home="$1"\n  shift\n  [ "$#" -gt 0 ] || return 1\n'

if source.count(ANCHOR) != 1:
    sys.stderr.write("M7: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(ANCHOR, DEAD + ANCHOR, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M7: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M7" "$m7/entry.sh" "$m7/isolation.sh" \
    "test_the_isolation_helper_has_a_single_definition_of_the_entry"
  survivor_probe "$m7/entry.sh" "M7"
fi

# ---------------------------------------------------------------------------
# M8: an aggregate that MASKS a failed declaration of the cleanup.
#
# The declaration of the cleanup of the product that the battery of the
# suites publishes is the WORST CASE of the declarations of its scenarios.
# The mutation IGNORES a FAIL, so the aggregate of {PASS, FAIL} is a PASS:
# a product that did NOT clean up would be certified as clean.
# ---------------------------------------------------------------------------
echo "--- M8: el agregado maquilla un FAIL en PASS"
m8="$WORKDIR/m8"
prepare_copies "$m8" || exit 1
python3 - "$m8/forge_run_all_cleanup.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        if SEVERITY[value] > SEVERITY[result]:
            result = value"""

NEW = """        # MUTATION: a FAIL is ignored: the aggregate masks a failure of the
        # product and certifies a product that did NOT clean up.
        if SEVERITY[value] > SEVERITY[result] and value != "FAIL":
            result = value"""

if source.count(OLD) != 1:
    sys.stderr.write("M8: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M8: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M8" "$m8/entry.sh" "$m8/isolation.sh" \
    "test_the_aggregate_never_masks_a_failed_declaration"
fi

# ---------------------------------------------------------------------------
# M9: the CLOSURE is certified WITHOUT observing the effective termination
#     of the private PID 1.
#
# This is the certification "the signal was sent and then it ended": the
# launcher was waited for and returned 0, but nobody OBSERVED that PID 1
# completed its exit path. The battery must FAIL: an unobserved termination
# cannot certify a closure, and the context of an unconfirmed closure must be
# preserved.
# ---------------------------------------------------------------------------
echo "--- M9: el cierre se certifica sin observar la terminacion del PID 1"
m9="$WORKDIR/m9"
prepare_copies "$m9" || exit 1
python3 - "$m9/entry.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = 'if [[ $runner_waited == YES && $runner_rc == 0 && $pid1_completion == PASS ]]; then'
new = ('# MUTATION: la certificacion "se envio la senal y luego termino" vuelve:\n'
       'if [[ $runner_waited == YES && $runner_rc == 0 ]]; then')
if source.count(old) != 1:
    sys.stderr.write("M9: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M9: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M9" "$m9/entry.sh" "$m9/isolation.sh" \
    "test_an_unconfirmed_closure_is_not_certified_and_preserves_the_context"
  survivor_probe "$m9/entry.sh" "M9"
fi

# ---------------------------------------------------------------------------
# M10: a signal that was SENT certifies the closure on its own.
#
# The interruption is taken as the proof of the termination of PID 1: the
# closure is CONFIRMED even when the termination was never observed. The
# battery must FAIL.
# ---------------------------------------------------------------------------
echo "--- M10: una senal enviada certifica el cierre por si sola"
m10="$WORKDIR/m10"
prepare_copies "$m10" || exit 1
python3 - "$m10/entry.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = 'if [[ $runner_waited == YES && $runner_rc == 0 && $pid1_completion == PASS ]]; then'
new = ('# MUTATION: la senal enviada se toma por la observacion de la terminacion.\n'
       'if [[ $runner_waited == YES && $runner_rc == 0 ]] \\\n'
       '  || { [[ $interruption != NONE ]] && [[ $runner_waited == YES ]]; }; then')
if source.count(old) != 1:
    sys.stderr.write("M10: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M10: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M10" "$m10/entry.sh" "$m10/isolation.sh" \
    "test_an_unconfirmed_closure_is_not_certified_and_preserves_the_context"
  survivor_probe "$m10/entry.sh" "M10"
fi

# ---------------------------------------------------------------------------
# M11: the entry leaks its own diagnosis on the standard output of the
#      consumer: the streams are no longer the ones of the scenario.
#
# The entry keeps the streams of the consumer in the descriptors 3 and 4
# (it routes its OWN diagnostics to its own evidence files), so a leak that
# has to REACH the consumer is written to the descriptor 3. A leak written
# to the plain stdout of the entry would land in the infrastructure evidence
# and would not be observable by anybody: the mutant has to break the
# property that it claims to break.
# ---------------------------------------------------------------------------
echo "--- M11: la entrada filtra el diagnóstico de la ruta del recibo por stdout"
m11="$WORKDIR/m11"
prepare_copies "$m11" || exit 1
python3 - "$m11/entry.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = """  if ! printf '%s\\n' "$receipt_file" >&9; then
    printf 'Cannot publish the receipt path on descriptor 9\\n' >&2
    exit 73
  fi"""
new = """  # MUTATION: la ruta del recibo se anuncia por el stdout del CONSUMIDOR
  # (el descriptor 3 es su stdout: la entrada lo guardo antes de redirigir
  # su propia salida a su evidencia).
  printf 'Receipt: %s\\n' "$receipt_file" >&3
  if ! printf '%s\\n' "$receipt_file" >&9; then
    printf 'Cannot publish the receipt path on descriptor 9\\n' >&2
    exit 73
  fi"""
if source.count(old) != 1:
    sys.stderr.write("M11: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M11: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M11" "$m11/entry.sh" "$m11/isolation.sh" \
    "test_the_streams_are_the_scenario_ones_with_and_without_the_receipt_out"
fi

# ---------------------------------------------------------------------------
# M12: without `--receipt-out` the entry does not publish the path of the
#      receipt on the dedicated descriptor 9.
# ---------------------------------------------------------------------------
echo "--- M12: sin --receipt-out la ruta del recibo no se publica por el descriptor 9"
m12="$WORKDIR/m12"
prepare_copies "$m12" || exit 1
python3 - "$m12/entry.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = """  if ! printf '%s\\n' "$receipt_file" >&9; then
    printf 'Cannot publish the receipt path on descriptor 9\\n' >&2
    exit 73
  fi"""
new = """  # MUTATION: el descriptor dedicado no publica la ruta del recibo.
  :"""
if source.count(old) != 1:
    sys.stderr.write("M12: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M12: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M12" "$m12/entry.sh" "$m12/isolation.sh" \
    "test_the_streams_are_the_scenario_ones_with_and_without_the_receipt_out"
fi

# ---------------------------------------------------------------------------
# M13: the READER of the evidence does not require the OBSERVED termination
#      of the private PID 1.
# ---------------------------------------------------------------------------
echo "--- M13: el lector no exige la terminacion observada del PID 1"
m13="$WORKDIR/m13"
prepare_copies "$m13" || exit 1
python3 - "$m13/isolation.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = """    LAUNCHER_RC PID1_COMPLETION_OBSERVED; do"""
new = """    LAUNCHER_RC; do"""
if source.count(old) != 1:
    sys.stderr.write("M13: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M13: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M13" "$m13/entry.sh" "$m13/isolation.sh" \
    "test_the_reader_rejects_contradictory_evidence"
fi

# ---------------------------------------------------------------------------
# M14: the READER of the evidence does not require the RC 0 of the launcher.
# ---------------------------------------------------------------------------
echo "--- M14: el lector no exige el RC 0 del lanzador"
m14="$WORKDIR/m14"
prepare_copies "$m14" || exit 1
python3 - "$m14/isolation.sh" <<'PATCH_EOF'
import sys
path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = """    LAUNCHER_RC PID1_COMPLETION_OBSERVED; do"""
new = """    PID1_COMPLETION_OBSERVED; do"""
if source.count(old) != 1:
    sys.stderr.write("M14: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M14: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M14" "$m14/entry.sh" "$m14/isolation.sh" \
    "test_the_reader_rejects_contradictory_evidence"
fi

# ---------------------------------------------------------------------------
# The EQUIVALENTS of the HISTORIC vectors m1-m5.
#
# The historic harness (tests/own_process_harness_unit.sh and
# tests/forge_own_watch.py) was retired with the observer: the mutation
# script of that lot (/tmp/opencode/forge-contracts-v2/mutation-check-r3.sh)
# is INVALIDATED because it inspected the processes of the host, and none of
# its results are reused.
#
# The matrix of the incident is nevertheless covered: every historic vector
# is either reauthorized here as an EQUIVALENT vector against the CURRENT
# architecture, or declared NOT APPLICABLE with its reason. The equivalence
# is documented in the acceptance report of this lot:
#
#   m1 -> H1  IDENTITY BEFORE THE SIGNAL. The property still exists: the
#              fallback without a pidfd re-verifies the starttime
#              IMMEDIATELY BEFORE the signal (tests/forge_own_signal.py).
#   m2 -> N/A  OWNERSHIP OF THE DESCENDANTS. The mechanism that owned the
#              property was retired: there is no tree observer, no adoption
#              and no parental relation anywhere. The guarantee it backed is
#              now structural (the private PID namespace).
#   m3 -> H2  INTEGRITY OF THE REGISTRY. The property still exists:
#              forge_own_identities_check rejects an absent, empty, malformed
#              or contradictory registry (tests/isolation.sh).
#   m4 -> H3  COMPLETENESS OF THE SURVIVOR REPORT. The property still
#              exists: the survivors of the scenario are counted and the
#              cleanup of the product is declared FAIL when there are some.
#   m5 -> H4  IDENTITY OF THE RECORDED PROCESSES. The property still exists
#              in the current carrier: the observer of the private /proc
#              records every identity as "<pid> <starttime>", never a bare
#              number.
#
# H5 is NOT a re-authorisation of a historic vector: it is the detector of
# the PARENTAL relation of the registry of the V2 bank, a property that the
# historic matrix never covered and that had NO detector at all.
# ---------------------------------------------------------------------------
echo "--- H1: la identidad no se re-verifica antes de la senal (equivalente de m1)"

h1="$WORKDIR/h1"
prepare_copies "$h1" || exit 1
python3 - "$h1/forge_own_signal.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    again = ticks_of(pid)
    if again is None:
        sys.stdout.write("gone\\n")
        return EXIT_GONE
    if again != expected:
        # The identity changed: the number belongs to somebody else now and
        # NOTHING is signalled.
        sys.stdout.write("identity-mismatch\\n")
        return EXIT_MISMATCH
    try:
        os.kill(pid, signum)"""

NEW = """    # MUTATION: the identity is NOT re-verified before the fallback signal.
    try:
        os.kill(pid, signum)"""

if source.count(OLD) != 1:
    sys.stderr.write("H1: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "H1: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "H1" "$h1/entry.sh" "$h1/isolation.sh" \
    "test_signal_is_bound_to_the_identity"
  survivor_probe "$h1/entry.sh" "H1"
fi

echo "--- H2: un registro de identidades ausente o vacio se acepta (equivalente de m3)"

h2="$WORKDIR/h2"
prepare_copies "$h2" || exit 1
python3 - "$h2/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

ABSENT_OLD = """  if [ ! -f "$file" ]; then
    printf 'el registro de identidades propias no existe (%s): su ausencia es un ERROR, no la prueba de que no quede nada vivo\\n' \\
      "$file" >&2
    return 1
  fi"""

ABSENT_NEW = """  # MUTATION: an absent registry is accepted: the survivor check becomes vacuous.
  if [ ! -f "$file" ]; then
    printf '0\\n'
    return 0
  fi"""

EMPTY_OLD = """  if [ "$first" = 1 ]; then
    printf 'el registro de identidades propias esta vacio (%s): un registro vacio no prueba nada\\n' "$file" >&2
    return 1
  fi"""

EMPTY_NEW = """  if [ "$first" = 1 ]; then
    # MUTATION: an empty registry is accepted: it proves nothing.
    printf '0\\n'
    return 0
  fi"""

for old, new in ((ABSENT_OLD, ABSENT_NEW), (EMPTY_OLD, EMPTY_NEW)):
    if source.count(old) != 1:
        sys.stderr.write("H2: ancla no encontrada o ambigua: %r\n" % old)
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "H2: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "H2" "$h2/entry.sh" "$h2/isolation.sh" \
    "test_the_registry_rejects_absent_and_corrupted_evidence"
  survivor_probe "$h2/entry.sh" "H2"
fi

echo "--- H3: la limpieza nunca reporta los supervivientes (equivalente de m4)"

h3="$WORKDIR/h3"
prepare_copies "$h3" || exit 1
python3 - "$h3/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    printf '%s\\n' 'leftovers=0'
    printf '%s\\n' 'while IFS= read -r leftover; do'
    printf '%s\\n' '  [ -n "$leftover" ] || continue'
    printf '%s\\n' '  leftovers=$((leftovers + 1))'
    printf '%s\\n' 'done < "$leftovers_file"'"""

NEW = """    printf '%s\\n' 'leftovers=0'
    printf '%s\\n' 'while IFS= read -r leftover; do'
    printf '%s\\n' '  [ -n "$leftover" ] || continue'
    printf '%s\\n' '  # MUTATION: the survivors are never reported.'
    printf '%s\\n' 'done < "$leftovers_file"'"""

if source.count(OLD) != 1:
    sys.stderr.write("H3: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "H3: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "H3" "$h3/entry.sh" "$h3/isolation.sh" \
    "test_a_detached_descendant_does_not_survive_the_closure" \
    "test_the_product_result_is_separated_from_the_defensive_one"
  survivor_probe "$h3/entry.sh" "H3"
fi

echo "--- H4: la identidad se registra por numero solo (equivalente de m5)"

h4="$WORKDIR/h4"
prepare_copies "$h4" || exit 1
python3 - "$h4/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """  [ "$state" = "Z" ] && continue
  [ -n "$ticks" ] || continue
  printf '%s %s\\n' "$pid" "$ticks"
done"""

NEW = """  [ "$state" = "Z" ] && continue
  [ -n "$ticks" ] || continue
  # MUTATION: the identity is registered by NUMBER only: it does not belong
  # to a process any more.
  printf '%s\\n' "$pid"
done"""

if source.count(OLD) != 1:
    sys.stderr.write("H4: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "H4: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "H4" "$h4/entry.sh" "$h4/isolation.sh" \
    "test_the_recorded_identities_carry_their_starttime"
  survivor_probe "$h4/entry.sh" "H4"
fi

# ---------------------------------------------------------------------------
# H5: the VERIFICATION of the parental relation of the registry of the V2
#     bank is annulled.
#
# The registry of the bank (tests/forge_v2_safety_scenarios.sh) locates the
# children of the supervisor through the `children` file that the kernel
# publishes for it, and it VERIFIES their parental relation before admitting
# them. Without that verification a RECYCLED PID would enter the registry and
# the teardown of the bank would destroy the process group of somebody else's
# process.
#
# The corresponding battery is the detector of that property
# (tests/forge_v2_registry_parity.py): it loads the guard program FROM THE
# SOURCE of the mutated copy and it proves that the registry admits a PID
# whose parental relation is NOT the supervisor.
# ---------------------------------------------------------------------------
echo "--- H5: la verificacion parental del registro del banco V2 se anula"

h5="$WORKDIR/h5"
mkdir -p "$h5" || exit 1
cp "$V2_SCENARIOS" "$h5/forge_v2_safety_scenarios.sh" || exit 1
python3 - "$h5/forge_v2_safety_scenarios.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = '        if info["ppid"] == supervisor_pid:'
NEW = '        if True:  # MUTATION: la verificacion parental se anula'

if source.count(OLD) != 1:
    sys.stderr.write("H5: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "H5: no se pudo aplicar la mutacion a la copia"
else
  # The detector REQUIRES an accredited boundary: the invocation goes
  # through the containment entry and the verdict that is measured is the
  # verdict of the DETECTOR, not the RC of the entry.
  h5_control_log="$WORKDIR/battery-h5-control.log"
  h5_mutant_log="$WORKDIR/battery-h5.log"
  h5_control_result="$WORKDIR/h5-control-result.txt"
  h5_mutant_result="$WORKDIR/h5-mutant-result.txt"
  : > "$h5_control_result"
  : > "$h5_mutant_result"
  check_external_battery "H5" "$h5_mutant_log" "$h5_control_log" \
    "el registro ADMITE un PID cuya relacion parental NO es el supervisor" \
    --control env FORGE_TEST_ENTRY="$ENTRY" \
      "$REGISTRY_RUNNER" "$V2_SCENARIOS" "$V2_REGISTRY_DETECTOR" \
        "$WORKDIR/h5-control-identities.txt" "$h5_control_result" \
    --mutant env FORGE_TEST_ENTRY="$ENTRY" \
      "$REGISTRY_RUNNER" "$h5/forge_v2_safety_scenarios.sh" "$V2_REGISTRY_DETECTOR" \
        "$WORKDIR/h5-mutant-identities.txt" "$h5_mutant_result"
fi

# ---------------------------------------------------------------------------
# M15: the bridge of the INTERRUPTION lives INSIDE the namespace again.
#
# The bridge is the scaffolding that relays the interruption request to the
# bounded `timeout`. While it lived inside the frontier it was a live process
# of the namespace that the observation of the cleanup (the criterion of the
# case CLEAN-1) counted as a leftover of the PRODUCT. The bridge now lives
# OUTSIDE the namespace (the entry registers the request and the PID 1 reads
# it), so the infrastructure of the harness is not inside the frontier.
#
# The battery must FAIL: a bridge inside the frontier is infrastructure of
# the harness that the observation of the cleanup would count as a leftover
# of the product.
# ---------------------------------------------------------------------------
echo "--- M15: el puente de la interrupcion vuelve a vivir dentro del namespace"
m15="$WORKDIR/m15"
prepare_copies "$m15" || exit 1
python3 - "$m15/entry.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = "timeout_pid=$!"

NEW = """timeout_pid=$!
  # MUTATION: el puente de reenvio de la interrupcion VUELVE a vivir dentro
  # del namespace: un subshell y su `sleep` son infraestructura del arnes
  # dentro de la frontera.
  (
    while [ ! -f "$run_dir/interruption.request" ]; do
      /usr/bin/sleep 0.05
    done
    kill -TERM "$timeout_pid" 2>/dev/null || true
  ) &"""

if source.count(OLD) != 1:
    sys.stderr.write("M15: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M15: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M15" "$m15/entry.sh" "$m15/isolation.sh" \
    "test_the_harness_infrastructure_is_not_inside_the_frontier" \
    "test_the_clean_1_excludes_the_harness_by_ancestry_and_still_detects_a_leftover"
  survivor_probe "$m15/entry.sh" "M15"
fi

# ---------------------------------------------------------------------------
# M16: a CLEAN-1 that CONTOURS the harness.
#
# The exclusion of the scaffolding of the harness (the `timeout` that bounds
# the scenario) is done BY ANCESTRY. A CLEAN-1 that contoured it (for
# instance, excluding every child of the PID 1 of the namespace, which is
# where a bridge inside the frontier would live) would also hide the
# descendants that the PRODUCT leaves behind: an orphan is reparented to the
# PID 1 of the namespace. The battery must FAIL: the exclusion of the
# scaffolding must never become a hole.
# ---------------------------------------------------------------------------
echo "--- M16: una CLEAN-1 que contorna el andamiaje del arnes"
m16="$WORKDIR/m16"
prepare_copies "$m16" || exit 1
python3 - "$m16/forge_run_all_cleanup.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        if info["state"] == "Z":
            # A zombie is not a live process: it is a corpse waiting to be
            # reaped, and it consumes nothing.
            continue"""

NEW = """        # MUTATION: la CLEAN-1 se CONTORNA: los hijos del PID 1 del namespace
        # (donde vive un puente interno del arnes) dejan de contar como
        # restos, y con ellos los descendientes que el producto deja vivos.
        if info["ppid"] == 1:
            continue
        if info["state"] == "Z":
            # A zombie is not a live process: it is a corpse waiting to be
            # reaped, and it consumes nothing.
            continue"""

if OLD not in source:
    sys.stderr.write("M16: ancla no encontrada\n")
    sys.exit(3)
# La PRIMERA aparicion del ancla es la real: el bloque de la mutacion esta
# mas abajo en el fichero y contiene el mismo texto como literal.
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M16: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M16" "$m16/entry.sh" "$m16/isolation.sh" \
    "test_the_clean_1_excludes_the_harness_by_ancestry_and_still_detects_a_leftover"
fi

# ---------------------------------------------------------------------------
# M17: the READER ignores the OBSERVATION of the interruption by the PID 1.
#
# The receipt declares INTERRUPTION_FORWARDING. A receipt that declares an
# interruption and does not prove that the PID 1 of the namespace observed
# it is CONTRADICTORY evidence. A reader that ignores that field would
# certify a closure on the strength of a signal that nobody observed being
# applied.
# ---------------------------------------------------------------------------
echo "--- M17: el lector ignora la observacion de la interrupcion por el PID 1"
m17="$WORKDIR/m17"
prepare_copies "$m17" || exit 1
python3 - "$m17/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = '  if [ "$cause" != "NONE" ] && [ "$forwarding" != "OBSERVED_BY_PID1" ]; then'
NEW = '  if false; then  # MUTATION: el lector ignora la observacion de la interrupcion'

if source.count(OLD) != 1:
    sys.stderr.write("M17: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M17: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M17" "$m17/entry.sh" "$m17/isolation.sh" \
    "test_the_reader_rejects_contradictory_evidence"
fi

# ---------------------------------------------------------------------------
# M18: the contract of the bank declares the RC of the eliminated suite as
#      NOT APPLICABLE again.
#
# The suite of the scenario `no-pidfd-hang` is eliminated by the bounded close
# of the containment entry and its RC IS observable (-9: terminated by
# SIGKILL). "None" would certify the mere absence of an RC, and it is
# UNSATISFIABLE in this architecture. The battery must FAIL.
# ---------------------------------------------------------------------------
echo "--- M18: el contrato del banco vuelve a declarar el RC de la suite eliminada como no aplicable"
m18="$WORKDIR/m18"
prepare_copies "$m18" || exit 1
python3 - "$m18/v2-safety.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = '"no-pidfd-hang": {"supervisor": 6, "suite": -9,'
NEW = '"no-pidfd-hang": {"supervisor": 6, "suite": None,'

if source.count(OLD) != 1:
    sys.stderr.write("M18: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M18: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M18" "$m18/entry.sh" "$m18/isolation.sh" \
    "test_the_bank_contract_of_the_eliminated_scenario_expects_the_sigkill"
fi

# ---------------------------------------------------------------------------
# M19: the status of the launcher that could NOT be recovered is LAUNDERED
#      into a clean zero.
#
# The `trap` of the outer shell interrupts the `wait` of the launcher and
# bash returns 128+signal, which is NOT the status of the launcher. The
# entry recovers the real status with a SECOND `wait`; when that second
# `wait` yields 127 the status is NOT RECOVERABLE and the entry must record
# LAUNCHER_RC=NOT_RECOVERABLE / LAUNCHER_WAIT_COMPLETED=NO and fail closed.
#
# This mutation reintroduces the OLD behaviour: an unknown status is treated
# as a clean 0, so the closure is CONFIRMED and the evidence is CERTIFIABLE
# on the strength of a launcher whose state nobody observed. The battery must
# FAIL: the branch of the non-recoverable status must be SENSITIVE.
#
# The mutation ALSO forces the branch to be reached (the recovery of the
# interrupted wait) and simulates the 127 of the second `wait`, so that the
# property is exercised on every run of the battery and not only on a race.
# The `wait` itself is kept, so the launcher is reaped and the contained
# environment does NOT survive.
# ---------------------------------------------------------------------------
echo "--- M19: el estado NO recuperable del lanzador se lava como un cero limpio"
m19="$WORKDIR/m19"
prepare_copies "$m19" || exit 1
python3 - "$m19/entry.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

FORCE_BRANCH_OLD = "      if [[ -z $runner_details ]]; then\n"
FORCE_BRANCH_NEW = "      if true; then  # MUTATION: se alcanza la rama de recuperacion\n"

FORCE_127_OLD = '        wait "$runner_pid" 2>/dev/null || runner_rc=$?\n'
FORCE_127_NEW = (
    '        wait "$runner_pid" 2>/dev/null || runner_rc=$?\n'
    '        runner_rc=127  # MUTATION: el estado del lanzador NO es recuperable\n'
)

LAUNDER_OLD = """        if [[ $runner_rc == 127 ]]; then
          runner_rc=NOT_RECOVERABLE
          runner_waited=NO
        else
          runner_waited=YES
        fi"""

LAUNDER_NEW = """        # MUTATION: el estado NO recuperable se LAVA como un cero limpio:
        # la entrada certifica un cierre cuyo lanzador nadie observo.
        runner_rc=0
        runner_waited=YES"""

for old, new in (
    (FORCE_BRANCH_OLD, FORCE_BRANCH_NEW),
    (FORCE_127_OLD, FORCE_127_NEW),
    (LAUNDER_OLD, LAUNDER_NEW),
):
    if source.count(old) != 1:
        sys.stderr.write("M19: ancla no encontrada o ambigua: %r\n" % old)
        sys.exit(3)
    source = source.replace(old, new, 1)

open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M19: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M19" "$m19/entry.sh" "$m19/isolation.sh" \
    "test_an_unrecoverable_launcher_status_is_not_certified"
  survivor_probe "$m19/entry.sh" "M19"
fi


# ---------------------------------------------------------------------------
# The NEW mutants: one per finding of the audit B.
#
#   N1  the aggregate DROPS a failure whose scope says that the declaration
#       does not describe the product: a real failure of the product can be
#       hidden and the aggregate IMPROVES.
#   N2  the scenario takes an INCOMPLETE observation for a complete one: an
#       inventory that was not obtained is read as an empty inventory.
#   N3  the PROTECTED pid is not refused: neither by the helper of the
#       signal nor by the terminator of the containment.
#   N4  the detector of the registry does NOT terminate its own descendants:
#       the grandchild of the supervisor is left orphaned.
#   N5  the arnes attributes to the parental check a failure that is an
#       ERROR OF THE INFRASTRUCTURE.
#   N6  the scanner of the definitions decides with the quoting state AFTER
#       the line: a real definition is omitted and a fictitious one counted.
#   N7  the battery of the suites opens a TCP socket in the loopback: the
#       battery uses the network.
#   N8  the baseline of the control is stored in one format and queried in
#       another: the failures of the control are not recognised.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# N1: the aggregate DROPS a failure whose scope says that the declaration
#     does not describe the product.
# ---------------------------------------------------------------------------
echo "--- N1: el agregado descarta un FAIL con alcance NOT_APPLICABLE"
n1="$WORKDIR/n1"
prepare_copies "$n1" || exit 1
python3 - "$n1/forge_run_all_cleanup.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        if verdict == FAIL:
            # A FAILURE is never dropped: the scope cannot hide it.
            verdicts.append(FAIL)
            continue"""

NEW = """        if verdict == FAIL:
            # MUTATION: la falla se descarta por el alcance: un fallo real
            # del producto queda oculto y el agregado mejora.
            verdicts.append(NOT_APPLICABLE)
            continue"""

if source.count(OLD) != 1:
    sys.stderr.write("N1: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N1: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "N1" "$n1/entry.sh" "$n1/isolation.sh" \
    "test_the_aggregate_never_masks_a_failed_declaration"
fi

# ---------------------------------------------------------------------------
# N2: the scenario takes an INCOMPLETE observation for a complete one.
# ---------------------------------------------------------------------------
echo "--- N2: una observacion incompleta se toma por completa"
n2="$WORKDIR/n2"
prepare_copies "$n2" || exit 1
python3 - "$n2/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    printf '%s\\n' '  else'
    printf '%s\\n' '    observation=INCOMPLETE'
    printf '%s\\n' '  fi'"""

NEW = """    printf '%s\\n' '  else'
    printf '%s\\n' '    # MUTATION: una observacion incompleta se toma por completa.'
    printf '%s\\n' '    observation=COMPLETE'
    printf '%s\\n' '  fi'"""

if source.count(OLD) != 1:
    sys.stderr.write("N2: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N2: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "N2" "$n2/entry.sh" "$n2/isolation.sh" \
    "test_the_cleanup_declaration_requires_a_satisfactory_observation"
fi

# ---------------------------------------------------------------------------
# N3: the PROTECTED pid is not refused.
# ---------------------------------------------------------------------------
echo "--- N3: el PID protegido no se rechaza"
n3="$WORKDIR/n3"
prepare_copies "$n3" || exit 1
python3 - "$n3/forge_own_signal.py" "$n3/isolation.sh" <<'PATCH_EOF'
import sys

signal_path, isolation_path = sys.argv[1], sys.argv[2]

SIGNAL_OLD = """    excluded = protected_pids()
    if str(pid) in excluded:
        sys.stderr.write("el PID %s esta protegido: no se senala\\n" % pid)
        return refuse("protected-pid")"""

SIGNAL_NEW = """    excluded = protected_pids()
    # MUTATION: el PID protegido no se rechaza: la identidad sola autoriza
    # la senal."""

ISOLATION_OLD = """    [ "$pid" = "$protected_pid" ] && continue
    current=$(identity_ticks "$pid") || continue
    [ "$current" = "$ticks" ] || continue
    descends_from_owner "$pid" || continue"""

ISOLATION_NEW = """    # MUTATION: el PID protegido no se rechaza en el terminador.
    current=$(identity_ticks "$pid") || continue
    [ "$current" = "$ticks" ] || continue
    descends_from_owner "$pid" || continue"""

for path, old, new in (
    (signal_path, SIGNAL_OLD, SIGNAL_NEW),
    (isolation_path, ISOLATION_OLD, ISOLATION_NEW),
):
    source = open(path, encoding="utf-8").read()
    if source.count(old) != 1:
        sys.stderr.write("N3: ancla no encontrada o ambigua en %s\n" % path)
        sys.exit(3)
    open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N3: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "N3" "$n3/entry.sh" "$n3/isolation.sh" \
    "test_signal_is_bound_to_the_identity" \
    "test_the_killer_refuses_the_protected_pid_and_the_non_own"
fi

# ---------------------------------------------------------------------------
# N4: the detector of the registry does NOT terminate its own descendants.
# ---------------------------------------------------------------------------
echo "--- N4: el detector del registro no termina a sus propios descendientes"
n4="$WORKDIR/n4"
mkdir -p "$n4" || exit 1
cp "$V2_REGISTRY_DETECTOR" "$n4/forge_v2_registry_parity.py" || exit 1
python3 - "$n4/forge_v2_registry_parity.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        if supervisor_group is not None:
            terminate_process_group(supervisor_group)"""

NEW = """        # MUTATION: solo se termina el supervisor: el nieto queda huerfano
        # hasta terminar su espera.
        if supervisor_group is not None:
            try:
                os.kill(supervisor.pid, signal.SIGKILL)
            except OSError:
                pass"""

if source.count(OLD) != 1:
    sys.stderr.write("N4: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N4: no se pudo aplicar la mutacion a la copia"
else
  n4_identities="$WORKDIR/n4-identities.txt"
  n4_result="$WORKDIR/n4-result.txt"
  : > "$n4_identities"
  : > "$n4_result"
  n4_rc=0
  FORGE_TEST_ENTRY="$ENTRY" \
    "$REGISTRY_RUNNER" "$V2_SCENARIOS" "$n4/forge_v2_registry_parity.py" \
      "$n4_identities" "$n4_result" >"$WORKDIR/battery-n4.log" 2>&1 || n4_rc=$?
  if [ "$n4_rc" -ne 0 ]; then
    pass "el mutante N4 hace FALLAR el detector (rc=$n4_rc)"
  else
    fail "el mutante N4 NO hace fallar el detector: el detector no verifica la terminacion de sus procesos"
  fi
  if grep -qF "quedan procesos PROPIOS vivos" "$WORKDIR/battery-n4.log" 2>/dev/null; then
    pass "el fallo del mutante N4 es la terminacion de sus procesos propios"
  else
    fail "el fallo del mutante N4 no es la terminacion de sus procesos propios"
  fi
  # El mutante DEJA un superviviente por diseño: ese es el defecto que
  # comprueba. El superviviente vive DENTRO del namespace contenido, asi
  # que lo termina el CIERRE de ese namespace (el recibo lo declara) y NO
  # un barrido del host: los PIDs que el detector publica son LOCALES a su
  # namespace y no dicen NADA sobre el host.
  n4_receipt=""
  if grep -q '^REGISTRY_RECEIPT=' "$WORKDIR/battery-n4.log" 2>/dev/null; then
    n4_receipt="$(sed -n 's/^REGISTRY_RECEIPT=//p' "$WORKDIR/battery-n4.log" | head -n 1)"
  fi
  if [ -n "$n4_receipt" ] && [ -s "$n4_receipt" ] \
    && grep -qx 'CLOSURE=CONFIRMED' "$n4_receipt"; then
    pass "el namespace contenido del mutante N4 se cerro y termino a su superviviente (rc del cierre: CONFIRMED)"
  else
    fail "el namespace contenido del mutante N4 no certifica el cierre: su superviviente podria quedar vivo"
  fi
fi

# ---------------------------------------------------------------------------
# N5: the arnes attributes to the parental check a failure that is an ERROR
#     OF THE INFRASTRUCTURE.
#
# The mutation is applied to a COPY of the arnes itself and the copy is
# executed in the mode "self-test": its own self-test MUST fail.
# ---------------------------------------------------------------------------
echo "--- N5: el arnes atribuye un error de infraestructura a la comprobacion parental"
n5="$WORKDIR/n5"
mkdir -p "$n5" || exit 1
cp "$FORGE_ROOT/tests/forge_contained_run_sensitivity.sh" "$n5/harness.sh" || exit 1
python3 - "$n5/harness.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """  local verdict=0
  classify_external_failure "$log" "$pattern" || verdict=$?
  if [ "$verdict" -eq 0 ]; then
    pass "el fallo del mutante $label se ATRIBUYE a la comprobacion parental (no a un error de infraestructura)"
  else
    fail "el fallo del mutante $label NO se atribuye a la comprobacion parental: es un error de infraestructura o un fallo distinto"
    printf '      (diagnostico del detector: %s)\\n' \\
      "$(grep -h 'FAIL:' "$log" 2>/dev/null | head -n 3 | tr '\\n' ' ')" >&2
  fi"""

NEW = """  # MUTATION: se acepta CUALQUIER fallo: un error de infraestructura
  # cuenta como sensibilidad.
  pass "el fallo del mutante $label se atribuye a la comprobacion parental\""""

if OLD not in source:
    sys.stderr.write("N5: ancla no encontrada\n")
    sys.exit(3)
# La PRIMERA aparicion del ancla es la de la FUNCION: el bloque de esta
# mutacion esta mas abajo en el fichero y contiene el mismo texto como
# literal. Se sustituye la primera, que es la que manda.
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N5: no se pudo aplicar la mutacion a la copia"
else
  n5_rc=0
  FORGE_SENSITIVITY_MODE=self-test bash "$n5/harness.sh" \
    >"$WORKDIR/battery-n5.log" 2>&1 || n5_rc=$?
  if [ "$n5_rc" -ne 0 ]; then
    pass "el mutante N5 hace FALLAR la auto-prueba del arnes (rc=$n5_rc)"
  else
    fail "el mutante N5 NO hace fallar la auto-prueba del arnes: el arnes no distingue un error de infraestructura"
  fi
  printf '      (auto-prueba del mutante N5: %s)\n' \
    "$(grep -h 'FAIL:' "$WORKDIR/battery-n5.log" 2>/dev/null | head -n 2 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# N6: the scanner of the definitions decides with the quoting state AFTER
#     the line.
# ---------------------------------------------------------------------------
echo "--- N6: el escaner de definiciones decide por el contexto del FINAL de la linea"
n6="$WORKDIR/n6"
prepare_copies "$n6" || exit 1
python3 - "$n6/forge_shell_defs.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        context = state.quote
        opened = []
        _scan_line(line, state, opened)
        if context == "none":"""

NEW = """        opened = []
        _scan_line(line, state, opened)
        if state.quote == "none":"""

if source.count(OLD) != 1:
    sys.stderr.write("N6: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N6: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "N6" "$n6/entry.sh" "$n6/isolation.sh" \
    "test_the_definition_scanner_decides_by_the_lexical_context"
fi

# ---------------------------------------------------------------------------
# N7: the battery of the suites opens a TCP socket in the loopback.
#
# The mutacion se aplica a una COPIA de la suite de la instalacion (que el
# escaner de la red escanea). La copia NUNCA se ejecuta: el defecto es
# ESTATICO y la deteccion es estatica.
# ---------------------------------------------------------------------------
echo "--- N7: la bateria abre un socket TCP en el loopback"
n7="$WORKDIR/n7"
prepare_copies "$n7" || exit 1
python3 - "$n7/opencode_install_integration.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    url = "http://127.0.0.1:%d" % (40000 + (os.getpid() % 20000))"""

# The text of the mutation is built by pieces ON PURPOSE: the scanner de la
# red escanea ALSO this file, and a literal that spelled the primitives
# would be a false positive (the scanner would accuse the arnes de usar la
# red). The MUTATED copy spells them, and that is the one that must be
# accused.
NEW = (
    "    # MUTATION: el fixture vuelve a abrir un socket TCP en el loopback.\n"
    "    import " + "socket as _socket\n"
    "    _listener = _socket." + "socket(_socket.AF_INET, _socket.SOCK_STREAM)\n"
    "    _listener.bind((\"127.0.0.1\", 0))\n"
    "    _listener.listen(16)\n"
    "    url = \"http://127.0.0.1:%d\" % _listener.getsockname()[1]"
)

if source.count(OLD) != 1:
    sys.stderr.write("N7: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N7: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "N7" "$n7/entry.sh" "$n7/isolation.sh" \
    "test_the_battery_of_the_suites_uses_no_network"
fi

# ---------------------------------------------------------------------------
# N8: the baseline of the control is stored in one format and queried in
#     another.
# ---------------------------------------------------------------------------
echo "--- N8: la linea base del control se guarda en un formato y se consulta en otro"
n8="$WORKDIR/n8"
mkdir -p "$n8" || exit 1
cp "$FORGE_ROOT/tests/forge_contained_run_sensitivity.sh" "$n8/harness.sh" || exit 1
python3 - "$n8/harness.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD_BASELINE = """control_baseline() {
  local log="$1"
  CONTROL_FAILING="$(failing_tests "$log")"
}"""

NEW_BASELINE = """control_baseline() {
  local log="$1"
  CONTROL_FAILING="$(failing_tests "$log" | tr '\\n' ' ')"
}"""

OLD_FUNCTION = """control_fails() {
  local wanted="$1" name
  while IFS= read -r name; do
    [ "$name" = "$wanted" ] && return 0
  done <<EOF
$CONTROL_FAILING
EOF
  return 1
}"""

NEW_FUNCTION = """control_fails() {
  local wanted="$1"
  case "
$CONTROL_FAILING
" in
    *"
$wanted
"*) return 0 ;;
  esac
  return 1
}"""

for old, new in ((OLD_BASELINE, NEW_BASELINE), (OLD_FUNCTION, NEW_FUNCTION)):
    if old not in source:
        sys.stderr.write("N8: ancla no encontrada: %r\\n" % old)
        sys.exit(3)
    # La PRIMERA aparicion del ancla es la real (las funciones estan antes
    # que este bloque, que contiene el mismo texto como literal).
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "N8: no se pudo aplicar la mutacion a la copia"
else
  n8_rc=0
  FORGE_SENSITIVITY_MODE=self-test bash "$n8/harness.sh" \
    >"$WORKDIR/battery-n8.log" 2>&1 || n8_rc=$?
  if [ "$n8_rc" -ne 0 ]; then
    pass "el mutante N8 hace FALLAR la auto-prueba del arnes (rc=$n8_rc)"
  else
    fail "el mutante N8 NO hace fallar la auto-prueba del arnes: el arnes no reconoce los fallos del control"
  fi
  printf '      (auto-prueba del mutante N8: %s)\n' \
    "$(grep -h 'FAIL:' "$WORKDIR/battery-n8.log" 2>/dev/null | head -n 2 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# M20: the conversion of the exit code rejects the NEGATIVE form again.
#
# The conversion is the SOURCE of the evidence: a receipt that carries -9
# was read as an ABSENT exit code, and an absent exit code satisfies a
# loose comparison (`None != 0` is true in Python). The mutant restores the
# old conversion and the battery has to notice it.
# ---------------------------------------------------------------------------
echo "--- M20: la conversion del RC vuelve a rechazar la forma negativa"
m20="$WORKDIR/m20"
prepare_copies "$m20" || exit 1
python3 - "$m20/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    text = str(value).strip()
    if not text:
        return None
    negative = text.startswith("-")
    digits = text[1:] if negative else text
    if not digits or not digits.isascii() or not digits.isdigit():
        return None
"""

NEW = """    text = str(value or "").strip()
    if not text.isdigit():
        return None
"""

if source.count(OLD) != 1:
    sys.stderr.write("M20: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M20: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M20" "$m20/entry.sh" "$m20/isolation.sh" \
    "test_the_exit_code_of_the_eliminated_scenario_is_the_observed_signal"
  survivor_probe "$m20/entry.sh" "M20"
fi

# ---------------------------------------------------------------------------
# M21: the runner declares an OBSERVED exit code that is not the observed
#      one (-9): the contract of the eliminated scenario is falsified.
# ---------------------------------------------------------------------------
echo "--- M21: el runner declara un RC observado que no es el observado"
m21="$WORKDIR/m21"
prepare_copies "$m21" || exit 1
python3 - "$m21/forge_v2_safety_scenarios.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = "    EXPECTED_SUITE_OBSERVED_RC=-9\n"
NEW = "    EXPECTED_SUITE_OBSERVED_RC=-15\n"

if source.count(OLD) != 1:
    sys.stderr.write("M21: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M21: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M21" "$m21/entry.sh" "$m21/isolation.sh" \
    "test_the_exit_code_of_the_eliminated_scenario_is_the_observed_signal"
  survivor_probe "$m21/entry.sh" "M21"
fi

# ---------------------------------------------------------------------------
# M22: the runner goes back to the LOOSE comparison of the exit code of the
#      suite: an absent exit code satisfies it.
# ---------------------------------------------------------------------------
echo "--- M22: el runner vuelve a aceptar un RC distinto de cero"
m22="$WORKDIR/m22"
prepare_copies "$m22" || exit 1
python3 - "$m22/forge_v2_safety_scenarios.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = "    suite_rc is not None and suite_rc == expected_suite_observed_rc,\n"
NEW = "    suite_rc != 0,\n"

if source.count(OLD) != 1:
    sys.stderr.write("M22: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M22: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M22" "$m22/entry.sh" "$m22/isolation.sh" \
    "test_the_exit_code_of_the_eliminated_scenario_is_the_observed_signal"
fi

# ---------------------------------------------------------------------------
# M23: the verdict of the closure stops requiring the RC 0 of the launcher:
#       a receipt that declares the closure WITHOUT that link certifies it.
# ---------------------------------------------------------------------------
echo "--- M23: el veredicto del cierre deja de exigir el RC 0 del lanzador"
m23="$WORKDIR/m23"
prepare_copies "$m23" || exit 1
python3 - "$m23/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        launcher_wait_completed == "YES"
        and launcher_rc == "0"
        and pid1_completion_observed == "PASS"
        and closure == "CONFIRMED"
"""
NEW = """        launcher_wait_completed == "YES"
        and pid1_completion_observed == "PASS"
        and closure == "CONFIRMED"
"""

if source.count(OLD) != 1:
    sys.stderr.write("M23: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M23: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M23" "$m23/entry.sh" "$m23/isolation.sh" \
    "test_the_closure_verdict_requires_every_link_and_observes_the_absence"
  survivor_probe "$m23/entry.sh" "M23"
fi

# ---------------------------------------------------------------------------
# M24: the absence of the survivors, of the members of the own process group
#       and of the init is published AGAIN as favourable constants.
# ---------------------------------------------------------------------------
echo "--- M24: la ausencia se vuelve a publicar como constante favorable"
m24="$WORKDIR/m24"
prepare_copies "$m24" || exit 1
python3 - "$m24/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    survivors = aftermath["survivors"]
    members = aftermath["members"]
    init_alive = aftermath["init_alive"]
    init_gone = aftermath["init_gone"]
"""
NEW = """    survivors = []
    members = []
    init_alive = False
    init_gone = True
"""

if source.count(OLD) != 1:
    sys.stderr.write("M24: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M24: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M24" "$m24/entry.sh" "$m24/isolation.sh" \
    "test_the_closure_verdict_requires_every_link_and_observes_the_absence"
  survivor_probe "$m24/entry.sh" "M24"
fi

# ---------------------------------------------------------------------------
# M25: the gate of admission does NOT require the kernel handle of the
#       invoking namespace: a planted receipt passes.
#
# The ANCHOR of this mutant follows the CURRENT text of the gate: the gate
# was rewritten (by another actor of this lot) into a COHERENCE check that
# compares the namespace of the checker with the one that FD 8 refers to,
# and that no longer reads an "outer" namespace. The MEANING of the mutant
# is UNCHANGED: the read of the kernel handle stops being fail-closed and
# falls back to an identity that the gate accepts, so a planted receipt
# passes the admission without the handle.
# ---------------------------------------------------------------------------
echo "--- M25: la puerta de admision no exige el handle del kernel"
m25="$WORKDIR/m25"
prepare_copies "$m25" || exit 1
python3 - "$m25/require-v2-containment.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """invoker_pid_namespace=$(/usr/bin/readlink "/proc/$PPID/fd/$INVOKER_PID_NAMESPACE_FD" 2>/dev/null) \\
  || fail 'no se puede leer la referencia PID de FD 8 en el invocador directo.'
"""
NEW = """invoker_pid_namespace=$(/usr/bin/readlink "/proc/$PPID/fd/$INVOKER_PID_NAMESPACE_FD" 2>/dev/null) \\
  || invoker_pid_namespace="pid:[9999999999]"
"""

if source.count(OLD) != 1:
    sys.stderr.write("M25: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M25: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M25" "$m25/entry.sh" "$m25/isolation.sh" \
    "test_the_admission_requires_the_kernel_handle_of_the_invoker"
  survivor_probe "$m25/entry.sh" "M25"
fi

# ---------------------------------------------------------------------------
# B1: the detector of the throttle of the branch guard against the OLD
#     implementation of the guard (the dead chain of hashes).
#
# The detector is a battery of its own (it is NOT collected by run-all,
# because it reproduces a REPORTED defect of the product), so its
# sensitivity is measured here: the control has to be GREEN and the mutant
# has to be RED.
# ---------------------------------------------------------------------------
echo "--- B1: el detector del throttle falla con la implementacion antigua del guard"
b1="$WORKDIR/b1"
mkdir -p "$b1" || exit 1
cp "$BRANCH_GUARD" "$b1/branch-guard-old.sh" || exit 1
python3 - "$b1/branch-guard-old.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """repo_hash=""
if command -v shasum >/dev/null 2>&1; then
  hash_output=$(printf '%s' "$repo_root" | shasum -a 1 2>/dev/null) || hash_output=""
  repo_hash=${hash_output%% *}
  case "$repo_hash" in
    ''|*[![:xdigit:]]*) repo_hash="" ;;
  esac
fi

if [ -z "$repo_hash" ] && command -v md5sum >/dev/null 2>&1; then
  hash_output=$(printf '%s' "$repo_root" | md5sum 2>/dev/null) || hash_output=""
  repo_hash=${hash_output%% *}
  case "$repo_hash" in
    ''|*[![:xdigit:]]*) repo_hash="" ;;
  esac
fi
"""

NEW = """repo_hash=$(printf '%s' "$repo_root" | shasum -a 1 2>/dev/null | cut -d' ' -f1 || printf '%s' "$repo_root" | md5sum 2>/dev/null | cut -d' ' -f1 || printf '%s' "$repo_root" | tr '/' '_' | tr -d ' ')
"""

if source.count(OLD) != 1:
    sys.stderr.write("B1: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "B1: no se pudo aplicar la mutacion a la copia"
else
  b1_control_rc=0
  FORGE_BRANCH_GUARD_PATH="$BRANCH_GUARD" \
    bash "$BRANCH_GUARD_DETECTOR" >"$WORKDIR/b1-control.log" 2>&1 || b1_control_rc=$?
  if [ "$b1_control_rc" -eq 0 ]; then
    pass "el control del detector del throttle es VERDE con el guard actual (rc=0)"
  else
    fail "el control del detector del throttle YA FALLA con el guard actual (rc=$b1_control_rc)"
    sed -n '1,20p' "$WORKDIR/b1-control.log" | sed 's/^/      /' >&2
  fi

  b1_rc=0
  FORGE_BRANCH_GUARD_PATH="$b1/branch-guard-old.sh" \
    bash "$BRANCH_GUARD_DETECTOR" >"$WORKDIR/b1-mutant.log" 2>&1 || b1_rc=$?
  if [ "$b1_rc" -ne 0 ]; then
    pass "el mutante B1 hace FALLAR el detector del throttle (rc=$b1_rc)"
  else
    fail "el mutante B1 NO hace fallar el detector del throttle: el defecto no seria reproducible"
  fi
  if grep -qF "el segundo repositorio mergeado NO recibio SU PROPIA advertencia" \
    "$WORKDIR/b1-mutant.log" 2>/dev/null; then
    pass "el fallo del mutante B1 se ATRIBUYE al throttle compartido entre repositorios"
  else
    fail "el fallo del mutante B1 NO se atribuye al throttle compartido entre repositorios"
    sed -n '1,20p' "$WORKDIR/b1-mutant.log" | sed 's/^/      /' >&2
  fi
fi

# ---------------------------------------------------------------------------
# B2: the guard ERRORS (no usable hasher) and the detector reads the error
#     as a warning: two errors used to be "ALL PASS".
# ---------------------------------------------------------------------------
echo "--- B2: el detector del throttle confunde un ERROR del guard con una advertencia"
b2="$WORKDIR/b2"
mkdir -p "$b2" || exit 1
cp "$BRANCH_GUARD" "$b2/branch-guard-no-hasher.sh" || exit 1
python3 - "$b2/branch-guard-no-hasher.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

pairs = [
    ("if command -v shasum >/dev/null 2>&1; then",
     "if command -v shasum-NUNCA-EXISTE >/dev/null 2>&1; then"),
    ('if [ -z "$repo_hash" ] && command -v md5sum >/dev/null 2>&1; then',
     'if [ -z "$repo_hash" ] && command -v md5sum-NUNCA-EXISTE >/dev/null 2>&1; then'),
]
for old, new in pairs:
    if source.count(old) != 1:
        sys.stderr.write("B2: ancla no encontrada o ambigua: %r\\n" % old)
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "B2: no se pudo aplicar la mutacion a la copia"
else
  b2_rc=0
  FORGE_BRANCH_GUARD_PATH="$b2/branch-guard-no-hasher.sh" \
    bash "$BRANCH_GUARD_DETECTOR" >"$WORKDIR/b2-mutant.log" 2>&1 || b2_rc=$?
  if [ "$b2_rc" -ne 0 ]; then
    pass "el mutante B2 hace FALLAR el detector del throttle (rc=$b2_rc)"
  else
    fail "el mutante B2 NO hace fallar el detector del throttle: dos ERRORES se leerian como dos advertencias"
  fi
  if grep -qF "el guard emitio un ERROR en vez de la advertencia" \
    "$WORKDIR/b2-mutant.log" 2>/dev/null; then
    pass "el fallo del mutante B2 se ATRIBUYE a la confusion entre un ERROR y una advertencia"
  else
    fail "el fallo del mutante B2 NO se atribuye a la confusion entre un ERROR y una advertencia"
    sed -n '1,20p' "$WORKDIR/b2-mutant.log" | sed 's/^/      /' >&2
  fi
fi

# ---------------------------------------------------------------------------
# The mutants of the RE-REVIEW round (R1-R6): the four ways of approving
# nothing that the closing review found.
#
#   R1  the observer certifies an inventory that it did NOT obtain: the
#       root of the observation is not required to be observable.
#   R2  the observer certifies an EMPTY inventory when its enumeration
#       produced NOTHING: a glob that does not match says nothing.
#   R3  the official observer publishes an ERROR OF OBSERVATION as a
#       CONFIRMED absence: a process that could not be read is published
#       as a process that disappeared.
#   R4  the official observer DISCARDS a process whose state could not be
#       read: the observation is published as a complete one.
#   R5  the reader of the receipt accepts the FIRST occurrence of a
#       duplicated field: contradictory evidence is selected silently.
#   R6  the validation of the scope comes BEFORE the preservation of the
#       FAIL: a failure with a malformed scope IMPROVES the aggregate.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# R1: the observer does not require the root to be OBSERVABLE.
# ---------------------------------------------------------------------------
echo "--- R1: el observador certifica un inventario que no obtuvo"
r1="$WORKDIR/r1"
prepare_copies "$r1" || exit 1
python3 - "$r1/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """if [ ! -d "$proc_root" ]; then
  printf 'forge-containment-observer: la raiz observada NO es observable (%s)\\n' \\
    "$proc_root" >&2
  exit 3
fi
root_stat=""
while IFS= read -r chunk; do
  root_stat="$chunk"
done 2>/dev/null < "$proc_root/stat"
if [ -z "$root_stat" ]; then
  printf 'forge-containment-observer: el stat de la raiz observada NO se pudo leer (%s)\\n' \\
    "$proc_root" >&2
  exit 3
fi"""

NEW = """# MUTATION: la raiz observada no se exige que sea observable: un inventario
# que nunca se obtuvo se certifica como un inventario vacio."""

if source.count(OLD) != 1:
    sys.stderr.write("R1: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "R1: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "R1" "$r1/entry.sh" "$r1/isolation.sh" \
    "test_the_observer_requires_an_observable_root"
fi

# ---------------------------------------------------------------------------
# R2: the observer does not require its enumeration to PRODUCE entries.
# ---------------------------------------------------------------------------
echo "--- R2: el observador certifica un inventario vacio sin enumerar nada"
r2="$WORKDIR/r2"
prepare_copies "$r2" || exit 1
python3 - "$r2/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """if [ "$enumerated" -eq 0 ]; then
  printf 'forge-containment-observer: la enumeracion de la raiz observada NO produjo entradas (%s)\\n' \\
    "$proc_root" >&2
  exit 3
fi"""

NEW = """# MUTATION: una enumeracion que no produce entradas no es una observacion
# incompleta: el inventario vacio se certifica."""

if source.count(OLD) != 1:
    sys.stderr.write("R2: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "R2: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "R2" "$r2/entry.sh" "$r2/isolation.sh" \
    "test_the_observer_requires_an_observable_root"
fi

# ---------------------------------------------------------------------------
# R3: the official observer publishes an ERROR OF OBSERVATION as a
#     CONFIRMED absence.
# ---------------------------------------------------------------------------
echo "--- R3: el observador oficial publica un error de observacion como una ausencia"
r3="$WORKDIR/r3"
prepare_copies "$r3" || exit 1
python3 - "$r3/forge_run_all_cleanup.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    except OSError:
        return UNOBSERVABLE"""

NEW = """    except OSError:
        # MUTATION: un error de observacion (un permiso, por ejemplo) se
        # publica como una AUSENCIA CONFIRMADA: el proceso que nadie pudo
        # observar se da por desaparecido.
        return ABSENT"""

if source.count(OLD) != 1:
    sys.stderr.write("R3: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "R3: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "R3" "$r3/entry.sh" "$r3/isolation.sh" \
    "test_the_absence_of_a_process_is_confirmed_and_never_inferred"
fi

# ---------------------------------------------------------------------------
# R4: the official observer DISCARDS a process whose state could not be
#     read.
# ---------------------------------------------------------------------------
echo "--- R4: el observador oficial descarta el proceso que no se pudo observar"
r4="$WORKDIR/r4"
prepare_copies "$r4" || exit 1
python3 - "$r4/forge_run_all_cleanup.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """            if entry_reader(pid) == ABSENT:
                continue
            unobservable.append(pid)"""

NEW = """            # MUTATION: un estado que no se pudo leer se descarta como si
            # fuera una AUSENCIA CONFIRMADA: la observacion se publica como
            # completa.
            if entry_reader(pid) == ABSENT or entry_reader(pid) == UNOBSERVABLE:
                continue
            unobservable.append(pid)"""

if source.count(OLD) != 1:
    sys.stderr.write("R4: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "R4: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "R4" "$r4/entry.sh" "$r4/isolation.sh" \
    "test_the_absence_of_a_process_is_confirmed_and_never_inferred"
fi

# ---------------------------------------------------------------------------
# R5: the reader of the receipt accepts the FIRST occurrence of a
#     duplicated field.
# ---------------------------------------------------------------------------
echo "--- R5: el lector del recibo elige en silencio la primera declaracion de un campo duplicado"
r5="$WORKDIR/r5"
prepare_copies "$r5" || exit 1
python3 - "$r5/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD_GATE = """  if ! forge_receipt_fields_are_unique "$receipt"; then
    return 1
  fi"""

NEW_GATE = """  # MUTATION: la unicidad de los campos del recibo no se exige."""

OLD_READ = """  if [ "$occurrences" -gt 1 ]; then
    printf 'el recibo declara el campo %s MAS DE UNA VEZ (%s): la evidencia es contradictoria\\n' \\
      "$key" "$receipt" >&2
    return 1
  fi"""

NEW_READ = """  # MUTATION: un campo declarado mas de una vez se lee por su PRIMERA
  # aparicion: la evidencia contradictoria se selecciona en silencio."""

for old, new in ((OLD_GATE, NEW_GATE), (OLD_READ, NEW_READ)):
    if source.count(old) != 1:
        sys.stderr.write("R5: ancla no encontrada o ambigua: %r\\n" % old)
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "R5: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "R5" "$r5/entry.sh" "$r5/isolation.sh" \
    "test_a_receipt_with_a_duplicated_field_is_rejected"
fi

# ---------------------------------------------------------------------------
# R6: the validation of the scope comes BEFORE the preservation of the FAIL.
# ---------------------------------------------------------------------------
echo "--- R6: la validacion del alcance precede a la preservacion del FAIL"
r6="$WORKDIR/r6"
prepare_copies "$r6" || exit 1
python3 - "$r6/forge_run_all_cleanup.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        if scope not in ("PRODUCT", NOT_APPLICABLE):
            # A scope that is neither one nor the other is contradictory
            # evidence: it is an UNKNOWN, never a PASS.
            #
            # A FAILURE, however, is NEVER softened by a malformed scope:
            # the aggregate only WORSENS, and a scope that cannot be
            # understood must not be the way a real failure of the product
            # gets improved into an UNKNOWN. The contradiction is still
            # DIAGNOSED: it is published on the standard error, where it can
            # be seen.
            if verdict == FAIL:
                sys.stderr.write(
                    "declaracion contradictoria: el alcance '%s' no es valido y el "
                    "veredicto es FAIL; el fallo se preserva\\n" % scope)
                verdicts.append(FAIL)
                continue
            sys.stderr.write(
                "declaracion contradictoria: el alcance '%s' no es valido\\n" % scope)
            verdicts.append(UNKNOWN)
            continue"""

NEW = """        if scope not in ("PRODUCT", NOT_APPLICABLE):
            # MUTATION: la validacion del alcance precede a la preservacion
            # del FAIL: un fallo real con un alcance mal formado MEJORA el
            # agregado a UNKNOWN.
            verdicts.append(UNKNOWN)
            continue"""

if source.count(OLD) != 1:
    sys.stderr.write("R6: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "R6: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "R6" "$r6/entry.sh" "$r6/isolation.sh" \
    "test_the_aggregate_never_improves_a_failure_with_a_malformed_scope"
fi

# ---------------------------------------------------------------------------
# The mutants of the RE-REVIEW of the closing round (D1-D5): the five
# defects that the closing review found in the harness of the tests.
#
#   D1  the exclusion of the PROTECTED pid is SUBSTITUTED by the variable of
#       the environment: the protection of the pid of the plan becomes a
#       fiction and the pid is signalled.
#   D2  the protection of the cleanup does NOT cover a PARTIAL creation: a
#       failure of the second creation leaves the first one alive.
#   D3  the detector of the registry does NOT require an accredited
#       boundary: it loads the program of the guard and it creates
#       processes outside the frontier.
#   D4  the scanner of the definitions does not recognise the WHOLE
#       delimiter of a heredoc, it confuses a here-STRING with a here-DOC
#       and it removes the spaces of a `<<-`.
#   D5  the scanner of the network does not recognise the IMPORTS, the
#       ALIASES and the ENTRIES of the network.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# D1: the exclusion of the protected pid is SUBSTITUTED.
# ---------------------------------------------------------------------------
echo "--- D1: la exclusion del PID protegido se sustituye por la variable"
d1="$WORKDIR/d1"
prepare_copies "$d1" || exit 1
python3 - "$d1/forge_own_signal.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    pids = {DEFAULT_PROTECTED_PID}
    raw = os.environ.get(PROTECTED_PID_VARIABLE, "") or ""
    for part in raw.replace(",", " ").replace(";", " ").split():
        if part.isdigit():
            pids.add(part)
    return pids"""

NEW = """    # MUTATION: la exclusion del PID protegido es SUSTITUIDA por el valor de
    # la variable: con otro valor, el PID del plan deja de estar protegido.
    raw = os.environ.get(PROTECTED_PID_VARIABLE, "") or ""
    return {part for part in raw.replace(",", " ").split() if part.isdigit()}"""

if source.count(OLD) != 1:
    sys.stderr.write("D1: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "D1: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "D1" "$d1/entry.sh" "$d1/isolation.sh" \
    "test_the_protected_pid_is_refused_whatever_the_environment_declares"
fi

# ---------------------------------------------------------------------------
# D2: the protection of the cleanup does NOT cover a partial creation.
#
# The detector is a battery of its own: the mutation is measured against
# it, through the accredited boundary, and the verdict that is compared is
# the verdict of the DETECTOR.
# ---------------------------------------------------------------------------
echo "--- D2: la proteccion de la limpieza no cubre una creacion parcial"
d2="$WORKDIR/d2"
mkdir -p "$d2" || exit 1
cp "$V2_REGISTRY_DETECTOR" "$d2/forge_v2_registry_parity.py" || exit 1
python3 - "$d2/forge_v2_registry_parity.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    finally:
        # The identities of EVERY process that this check creates are"""

NEW = """    finally:
        if supervisor is None or foreign is None:
            # MUTATION: la proteccion de la limpieza solo cubre una creacion
            # COMPLETA: una creacion parcial deja vivo el proceso que ya se
            # habia creado.
            raise
        # The identities of EVERY process that this check creates are"""

if source.count(OLD) != 1:
    sys.stderr.write("D2: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "D2: no se pudo aplicar la mutacion a la copia"
else
  d2_control_result="$WORKDIR/d2-control-result.txt"
  d2_mutant_result="$WORKDIR/d2-mutant-result.txt"
  : > "$d2_control_result"
  : > "$d2_mutant_result"
  check_external_battery "D2" "$WORKDIR/battery-d2.log" "$WORKDIR/battery-d2-control.log" \
    "la proteccion de la limpieza debe empezar en la PRIMERA creacion" \
    --control env FORGE_TEST_ENTRY="$ENTRY" \
      "$REGISTRY_RUNNER" "$V2_SCENARIOS" "$V2_REGISTRY_DETECTOR" \
        "$WORKDIR/d2-control-identities.txt" "$d2_control_result" \
    --mutant env FORGE_TEST_ENTRY="$ENTRY" \
      "$REGISTRY_RUNNER" "$V2_SCENARIOS" "$d2/forge_v2_registry_parity.py" \
        "$WORKDIR/d2-mutant-identities.txt" "$d2_mutant_result"
fi

# ---------------------------------------------------------------------------
# D3: the detector of the registry does NOT require an accredited boundary.
# ---------------------------------------------------------------------------
echo "--- D3: el detector del registro no exige una frontera acreditada"
d3="$WORKDIR/d3"
prepare_copies "$d3" || exit 1
python3 - "$d3/forge_v2_registry_parity.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    boundary, problem = accredited_boundary()
    if boundary is None:"""

NEW = """    boundary, problem = accredited_boundary()
    if False:  # MUTATION: la frontera acreditada no se exige"""

if source.count(OLD) != 1:
    sys.stderr.write("D3: ancla no encontrada o ambigua\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "D3: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "D3" "$d3/entry.sh" "$d3/isolation.sh" \
    "test_the_registry_detector_requires_an_accredited_boundary"
fi

# ---------------------------------------------------------------------------
# D4: the scanner of the definitions does not recognise the whole delimiter
#     of a heredoc, it confuses a here-STRING with a here-DOC and it
#     removes the SPACES of a `<<-`.
# ---------------------------------------------------------------------------
echo "--- D4: el escaner de definiciones no reconoce el heredoc completo"
d4="$WORKDIR/d4"
prepare_copies "$d4" || exit 1
python3 - "$d4/forge_shell_defs.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

REGEX_OLD = """HEREDOC = re.compile(
    r"<<(-?)[ \\t]*(?:'([^']*)'|\\"([^\\"]*)\\"|([A-Za-z_][A-Za-z0-9_-]*))"
)"""

REGEX_NEW = """# MUTATION: el delimitador se TRUNCA: `<<'END-DATA'` abre un heredoc cuyo
# delimitador es `END` y no `END-DATA`.
HEREDOC = re.compile(r"<<-?[ \\t]*(?:'|\\")?([A-Za-z_][A-Za-z0-9_]*)(?:'|\\")?")"""

STRING_OLD = """            if line[position:position + 3] == "<<<":
                # A here-STRING (`<<<WORD`) opens NOTHING: the word that
                # follows is DATA, not the delimiter of a heredoc. Treating
                # it as a heredoc swallows the rest of the file.
                position += 3
                continue
"""

STRING_NEW = """            # MUTATION: una here-STRING se trata como un here-DOC.
"""

GROUPS_OLD = """                delimiter = match.group(2)
                if delimiter is None:
                    delimiter = match.group(3)
                if delimiter is None:
                    delimiter = match.group(4)
                if delimiter:
                    heredocs.append((delimiter, match.group(1) == "-"))"""

GROUPS_NEW = """                # MUTATION: el delimitador se toma del grupo truncado.
                delimiter = match.group(1)
                if delimiter:
                    heredocs.append((delimiter, line[position:].startswith("<<-")))"""

TABS_OLD = """            if strip_tabs:
                # `<<-` removes TABULATORS and NOTHING else: a terminator
                # that is preceded by SPACES is NOT the terminator, and the
                # body of the heredoc goes on.
                probe = probe.lstrip("\\t")"""

TABS_NEW = """            if strip_tabs:
                # MUTATION: se eliminan tambien los ESPACIOS: un terminador
                # precedido por espacios termina el heredoc.
                probe = probe.strip()"""

for old, new in (
    (REGEX_OLD, REGEX_NEW),
    (STRING_OLD, STRING_NEW),
    (GROUPS_OLD, GROUPS_NEW),
    (TABS_OLD, TABS_NEW),
):
    if source.count(old) != 1:
        sys.stderr.write("D4: ancla no encontrada o ambigua\n")
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "D4: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "D4" "$d4/entry.sh" "$d4/isolation.sh" \
    "test_the_definition_scanner_recognises_the_whole_heredoc_delimiter"
fi

# ---------------------------------------------------------------------------
# D5: the scanner of the network does not recognise the IMPORTS, the
#     ALIASES and the ENTRIES of the network.
# ---------------------------------------------------------------------------
echo "--- D5: el escaner de la red no reconoce las importaciones ni los alias"
d5="$WORKDIR/d5"
prepare_copies "$d5" || exit 1
python3 - "$d5/forge_network_free.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

IMPORT_OLD = """                if alias.name in NETWORK_MODULES:
                    hit(node)
                    modules.add(alias.asname or alias.name.split(".")[0])"""

IMPORT_NEW = """                if False:
                    # MUTATION: la IMPORTACION de un modulo de la red no se
                    # reconoce, ni el ALIAS con el que se importa.
                    hit(node)
                    modules.add(alias.asname or alias.name.split(".")[0])"""

FROM_OLD = """            if module in NETWORK_MODULES:
                hit(node)
                for alias in node.names:
                    functions.add(alias.asname or alias.name)"""

FROM_NEW = """            if False:
                # MUTATION: la importacion de un NOMBRE de la red no se
                # reconoce: la llamada de ese nombre no se ve.
                hit(node)
                for alias in node.names:
                    functions.add(alias.asname or alias.name)"""

for old, new in ((IMPORT_OLD, IMPORT_NEW), (FROM_OLD, FROM_NEW)):
    if source.count(old) != 1:
        sys.stderr.write("D5: ancla no encontrada o ambigua\n")
        sys.exit(3)
    source = source.replace(old, new, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "D5: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "D5" "$d5/entry.sh" "$d5/isolation.sh" \
    "test_the_network_scanner_recognises_the_imports_and_the_aliases"
fi

# ---------------------------------------------------------------------------
# M26: the normalisation of the exit code reinterprets an INVALID state as
#       a valid signal.
#
# The conversion took the magnitude of the value and subtracted 128 from it
# BEFORE validating anything, so "-137" became the signal 9 and "999"
# became the signal 871. The mutation restores that behaviour: an invalid
# state is published as a valid termination.
# ---------------------------------------------------------------------------
echo "--- M26: la normalizacion del RC reinterpreta un estado invalido como una senal"
m26="$WORKDIR/m26"
prepare_copies "$m26" || exit 1
python3 - "$m26/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    number = int(text)
    if negative:
        # The NORMALISED form: the scenario was terminated by the signal N.
        # The domain of the signal is validated BEFORE anything else: a
        # magnitude outside it is an INVALID state, not another signal.
        if number == 0 or -number > MAX_SIGNAL:
            return None
        return number
    # The POSITIVE form: an exit status, or the 128+N of the shell.
    if number < 128:
        return number
    if number == 128:
        # RESERVED: it is not an exit status and it is not 128+N.
        return None
    signal = number - 128
    if signal > MAX_SIGNAL:
        # It would name a signal that does not exist.
        return None
    return -signal
"""

NEW = """    number = int(text)
    magnitude = abs(number)
    if magnitude > 128:
        return -(magnitude - 128)
    return number
"""

if source.count(OLD) != 1:
    sys.stderr.write("M26: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M26: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M26" "$m26/entry.sh" "$m26/isolation.sh" \
    "test_the_exit_code_of_the_eliminated_scenario_is_the_observed_signal"
  survivor_probe "$m26/entry.sh" "M26"
fi

# ---------------------------------------------------------------------------
# M27: the verdict of the cleanup of the harness stops requiring the
#       OBSERVED absence.
#
# The verdict was conditioned on the links of the receipt and on the
# removal of the synthetic root, but NOT on the state of the observation
# of the aftermath nor on the three verifications of the absence: a
# containment whose "zero survivors" claim had never been observed was
# certified. The mutation removes that requirement.
# ---------------------------------------------------------------------------
echo "--- M27: el veredicto de la limpieza deja de exigir la ausencia observada"
m27="$WORKDIR/m27"
prepare_copies "$m27" || exit 1
python3 - "$m27/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """        and not root_present
        and absence_verified_ok
    )"""

NEW = """        and not root_present
    )"""

if source.count(OLD) != 1:
    sys.stderr.write("M27: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M27: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M27" "$m27/entry.sh" "$m27/isolation.sh" \
    "test_the_cleanup_verdict_requires_the_verified_absence_in_both_entries"
  survivor_probe "$m27/entry.sh" "M27"
fi

# ---------------------------------------------------------------------------
# M28: the STABLE entry goes back to the truthiness check of the absences.
#
# The runner of the scenarios already required the EXPLICIT verification
# of the three absences, but the stable entry checked them with a
# truthiness test: a None (an absence that could NOT be observed) was
# accepted as an absence. The mutation restores that criterion.
# ---------------------------------------------------------------------------
echo "--- M28: la entrada estable vuelve a aceptar una ausencia no observada"
m28="$WORKDIR/m28"
prepare_copies "$m28" || exit 1
python3 - "$m28/forge_v2_safety.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """if cleanup.get("aftermath_observation_state") != "COMPLETE":
    problems.append(
        "la observacion del aftermath no es COMPLETE: %r" % cleanup.get("aftermath_observation_state")
    )
if cleanup.get("survivors_absence_verified") is not True:
    problems.append(
        "la ausencia de supervivientes no consta como VERIFICADA: %r"
        % cleanup.get("survivors_absence_verified")
    )
if cleanup.get("members_absence_verified") is not True:
    problems.append(
        "la ausencia de miembros del grupo propio no consta como VERIFICADA: %r"
        % cleanup.get("members_absence_verified")
    )
if cleanup.get("init_absence_verified") is not True:
    problems.append(
        "la ausencia del init del namespace no consta como VERIFICADA: %r"
        % cleanup.get("init_absence_verified")
    )
if cleanup.get("survivors_in_private_namespace") != []:
    problems.append("quedan supervivientes en el namespace privado")
if cleanup.get("members_of_own_process_group") != []:
    problems.append("quedan miembros del grupo propio del lote")
if cleanup.get("namespace_init_alive_after") is not False:
    problems.append("el init del namespace sigue vivo (o no se pudo observar)")
if cleanup.get("synthetic_root_present_after") is not False:
    problems.append("la raiz sintetica sigue presente (o no se pudo observar)")
"""

NEW = """if cleanup.get("survivors_in_private_namespace"):
    problems.append("quedan supervivientes en el namespace privado")
if cleanup.get("members_of_own_process_group"):
    problems.append("quedan miembros del grupo propio del lote")
if cleanup.get("namespace_init_alive_after"):
    problems.append("el init del namespace sigue vivo")
if cleanup.get("synthetic_root_present_after"):
    problems.append("la raiz sintetica sigue presente")
"""

if source.count(OLD) != 1:
    sys.stderr.write("M28: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M28: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M28" "$m28/entry.sh" "$m28/isolation.sh" \
    "test_the_cleanup_verdict_requires_the_verified_absence_in_both_entries"
  survivor_probe "$m28/entry.sh" "M28"
fi

# ---------------------------------------------------------------------------
# M29: the observation of a PID turns a FAILED read into an ABSENCE.
#
# The read of the stat of a process failed: a permission, an I/O error. The
# mutation restores the behaviour that published that failure as an
# absence: the process was declared gone, the observation of the aftermath
# was COMPLETE, the init was declared disappeared and the three absences
# were published as VERIFIED.
# ---------------------------------------------------------------------------
echo "--- M29: una lectura imposible se publica como una AUSENCIA"
m29="$WORKDIR/m29"
prepare_copies "$m29" || exit 1
python3 - "$m29/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    except FileNotFoundError:
        # The kernel says that the entry does not exist: it is a FACT about
        # the process, not an error of the observation.
        return None, "ABSENT"
    except OSError as exc:
        # The read FAILED (a permission, an I/O error): the state of the
        # process could NOT be observed. It is NOT an absence.
        return None, "%s: %s" % (path, exc)
"""

NEW = """    except OSError:
        return None, "ABSENT"
"""

if source.count(OLD) != 1:
    sys.stderr.write("M29: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M29: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M29" "$m29/entry.sh" "$m29/isolation.sh" \
    "test_the_observations_distinguish_an_absent_resource_from_an_impossible_one"
  survivor_probe "$m29/entry.sh" "M29"
fi

# ---------------------------------------------------------------------------
# M30: the verifier of the PROTECTED RESOURCES turns a FAILED read into an
#       absence.
#
# The read of the stat of the protected PID failed, or the socket tables
# could not be read. The mutation restores the behaviour that published
# those failures as "ABSENT" and "NOT_LISTENING": the verifier passed with
# an observation that had never been made.
#
# The anchors are los del CODIGO CORREGIDO (la generacion v18): la lectura
# IMPOSIBLE de una tabla se ignora y la defensa que la convertia en
# "NOT_OBSERVABLE" desaparece. El mutante sigue siendo el mismo defecto:
# una observacion IMPOSIBLE publicada como una AUSENCIA.
# ---------------------------------------------------------------------------
echo "--- M30: el verificador de los recursos protegidos publica una lectura fallida como una AUSENCIA"
m30="$WORKDIR/m30"
prepare_copies "$m30" || exit 1
python3 - "$m30/forge_protected_resources.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD_PID = """    except FileNotFoundError:
        # The CONFIRMED absence: the kernel says that the entry does not
        # exist. This is a fact about the process.
        return OBS_ABSENT, None, ""
    except OSError as exc:
        # The read FAILED (a permission, an I/O error): the state of the
        # process could NOT be observed. It is NOT an absence.
        return OBS_NOT_OBSERVABLE, None, "%s: %s" % (path, exc)
"""

NEW_PID = """    except OSError:
        return OBS_ABSENT, None, ""
"""

OLD_PORT = """        except OSError as exc:
            # The table EXISTS and could not be read: the observation of
            # that family is IMPOSSIBLE.
            failures.append("%s: %s" % (path, exc))
"""

NEW_PORT = """        except OSError:
            # MUTANTE M30: la lectura IMPOSIBLE de la tabla se IGNORA.
            pass
"""

OLD_FAILURES = """    if failures:
        # A table that EXISTS could not be read: the observation is
        # INCOMPLETE and the state of the port is NOT observable.
        return None, detail
"""

NEW_FAILURES = ""

if source.count(OLD_PID) != 1 or source.count(OLD_PORT) != 1 \
    or source.count(OLD_FAILURES) != 1:
    sys.stderr.write("M30: ancla no encontrada o ambigua\\n")
    sys.exit(3)
source = (
    source.replace(OLD_PID, NEW_PID, 1)
    .replace(OLD_PORT, NEW_PORT, 1)
    .replace(OLD_FAILURES, NEW_FAILURES, 1)
)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M30: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M30" "$m30/entry.sh" "$m30/isolation.sh" \
    "test_the_observations_distinguish_an_absent_resource_from_an_impossible_one"
  survivor_probe "$m30/entry.sh" "M30"
fi

# ---------------------------------------------------------------------------
# M31: the verifier of the PROTECTED RESOURCES counts an ABSENT interface as
#       a table that was READ.
#
# The defect: a socket table whose interface is ABSENT (the file does not
# exist: a procfs mounted with subset=pid, a kernel without that family) was
# counted as a table that had been read. With BOTH tables absent, the
# defence that requires at least one effective read was UNREACHABLE, the
# verifier published "NO EN ESCUCHA" and it exited with 0 WITHOUT having
# read a single table. The mutation restores that behaviour.
# ---------------------------------------------------------------------------
echo "--- M31: el verificador de los recursos protegidos cuenta una interface AUSENTE como una tabla LEIDA"
m31="$WORKDIR/m31"
prepare_copies "$m31" || exit 1
python3 - "$m31/forge_protected_resources.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD_ABSENT = """        except FileNotFoundError:
            # The interface is ABSENT: the table was NOT read. This is NOT
            # an observation of the family: the absence of the interface
            # does not prove that the family is disabled, and a listener of
            # that family would be INVISIBLE.
            absent_families.append(family)
"""

NEW_ABSENT = """        except FileNotFoundError:
            # MUTANTE M31: la interface AUSENTE se cuenta como una tabla
            # que se ha LEIDO.
            read_families.append(family)
"""

OLD_GUARD = """    unaccredited = [f for f in absent_families if f not in disabled_families]
    if unaccredited:
"""

NEW_GUARD = """    unaccredited = []
    if unaccredited:
"""

if source.count(OLD_ABSENT) != 1 or source.count(OLD_GUARD) != 1:
    sys.stderr.write("M31: ancla no encontrada o ambigua\\n")
    sys.exit(3)
source = source.replace(OLD_ABSENT, NEW_ABSENT, 1).replace(OLD_GUARD, NEW_GUARD, 1)
open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M31: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "M31" "$m31/entry.sh" "$m31/isolation.sh" \
    "test_an_absent_socket_table_is_not_an_observation_of_the_port"
  survivor_probe "$m31/entry.sh" "M31"
fi

# ---------------------------------------------------------------------------
# M32: the COMMENT of the effective restriction of the network claims that
#       EVERY interpreter of the battery inherits it.
#
# The claim is FALSE: the restriction reaches the interpreters that LOAD the
# wrapper or the `sitecustomize` of its directory, and nothing else. An
# interpreter invoked by an ABSOLUTE path does not load it, and a NESTED
# contained entry rebuilds the environment of its scenario with `env -i` and
# with the PATH that it DECLARES, so it does not inherit it either. The
# mutation restores the claim, and the check that measures the REACH of the
# restriction must DETECT it.
# ---------------------------------------------------------------------------
echo "--- M32: el comentario de la restriccion de la red afirma que TODO interprete de la bateria la hereda"
m32="$WORKDIR/m32"
prepare_copies "$m32" || exit 1
cp "$FORGE_ROOT/tests/forge_contained_run_unit.sh" \
  "$m32/forge_contained_run_unit.sh" || exit 1
python3 - "$m32/forge_contained_run_unit.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """# knows how to write it and how to VERIFY that it is effective) and it is
# installed at the FRONT of the PATH of this battery.
#
# Its reach is EXACTLY the interpreters that LOAD the wrapper or the
# `sitecustomize` of that directory: the wrapper exports the PYTHONPATH of
# the directory and the `sitecustomize` installs the restriction in the
# interpreter that starts with it. An interpreter invoked by an ABSOLUTE
# path does NOT load it (the PYTHONPATH that the wrapper exports does not
# reach it), and a NESTED contained entry does NOT inherit it either: the
# entry rebuilds the environment of its scenario with `env -i` and with the
# PATH that it DECLARES, so the nested entry reaches the restriction only
# when its declared PATH contains the directory of the restriction.
"""

NEW = """# knows how to write it and how to VERIFY that it is effective) and it is
# installed in the path of this battery, so that EVERY interpreter that
# this battery spawns inherits it.
"""

if source.count(OLD) != 1:
    sys.stderr.write("M32: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "M32: no se pudo aplicar la mutacion a la copia"
else
  FORGE_TEST_BATTERY_SOURCE="$m32/forge_contained_run_unit.sh" \
    check_mutant "M32" "$m32/entry.sh" "$m32/isolation.sh" \
      "test_the_network_restriction_states_the_interpreters_that_it_reaches"
  survivor_probe "$m32/entry.sh" "M32"
fi

# ---------------------------------------------------------------------------
# The G VECTOR: the corrections that make the battery work on ANY machine.
#
# The G mutants restore, on COPIES, the defects that the corrections of this
# lot removed: the precondition of a GLOBAL artefact of capacity, the
# dependence on a fixed root of receipts of a machine, the substitution of
# the RC of the child by the 124 of the wrapper and the EXIT trap that reads
# a 'local' of the function that installed it.
#
# The copies live OUTSIDE the repository: the repository is never modified.
# ---------------------------------------------------------------------------
echo "--- G1: el arnes vuelve a exigir un artefacto global de capacidad"
g1="$WORKDIR/g1"
prepare_copies "$g1" || exit 1
python3 - "$g1/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """  if [ ! -d "$FORGE_CONTAINMENT_RECEIPT_DIR" ]; then
    (umask 077 && mkdir -p -- "$FORGE_CONTAINMENT_RECEIPT_DIR") 2>/dev/null || {"""

NEW = """  if [ ! -f "/tmp/opencode/forge-contracts-v2/remediacion-contencion/capability.txt" ]; then
    printf 'no hay evidencia de capacidad de la contencion\\n' >&2
    return 1
  fi
  if [ ! -d "$FORGE_CONTAINMENT_RECEIPT_DIR" ]; then
    (umask 077 && mkdir -p -- "$FORGE_CONTAINMENT_RECEIPT_DIR") 2>/dev/null || {"""

if source.count(OLD) != 1:
    sys.stderr.write("G1: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G1: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G1" "$g1/entry.sh" "$g1/isolation.sh" \
    "test_the_isolation_helper_does_not_name_a_path_of_a_machine" \
    "test_a_consumer_cannot_run_outside_the_containment" \
    "test_the_accreditation_is_by_invocation"
  survivor_probe "$g1/entry.sh" "G1"
fi

# ---------------------------------------------------------------------------
echo "--- G2: el arnes deja de crear su propia raiz de recibos"
g2="$WORKDIR/g2"
prepare_copies "$g2" || exit 1
python3 - "$g2/isolation.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """  if [ ! -d "$FORGE_CONTAINMENT_RECEIPT_DIR" ]; then
    (umask 077 && mkdir -p -- "$FORGE_CONTAINMENT_RECEIPT_DIR") 2>/dev/null || {
      printf 'no se puede usar el directorio de recibos (%s)\\n' \\
        "$FORGE_CONTAINMENT_RECEIPT_DIR" >&2
      return 1
    }
  fi"""

NEW = """  if [ ! -d "$FORGE_CONTAINMENT_RECEIPT_DIR" ]; then
    printf 'no se puede usar el directorio de recibos (%s)\\n' \\
      "$FORGE_CONTAINMENT_RECEIPT_DIR" >&2
    return 1
  fi"""

if source.count(OLD) != 1:
    sys.stderr.write("G2: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G2: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G2" "$g2/entry.sh" "$g2/isolation.sh" \
    "test_a_consumer_cannot_run_outside_the_containment"
  survivor_probe "$g2/entry.sh" "G2"
fi

# ---------------------------------------------------------------------------
echo "--- G3: la entrada vuelve a exigir una raiz de recibos fija"
g3="$WORKDIR/g3"
prepare_copies "$g3" || exit 1
python3 - "$g3/entry.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = 'valid_seconds "${scenario_timeout:-}" 3600 || { usage; exit 64; }'
NEW = (
    '[[ $receipt_root == "/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs" ]]'
    ' || { usage; exit 64; }\n'
    + OLD
)

if source.count(OLD) != 1:
    sys.stderr.write("G3: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G3: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G3" "$g3/entry.sh" "$g3/isolation.sh" \
    "test_a_normal_exit_is_certifiable" \
    "test_the_boundary_and_the_closure_are_accredited"
  # The mutante rechaza la raiz de recibos ANTES de empezar: no hay entorno
  # contenido que pueda sobrevivir y no hay recibo que conservar (la sonda de
  # supervivientes no aplica a un mutante que falla cerrado en la interfaz).
fi

# ---------------------------------------------------------------------------
echo "--- G4: la puerta de admision vuelve a exigir una raiz fija"
g4="$WORKDIR/g4"
prepare_copies "$g4" || exit 1
python3 - "$g4/require-v2-containment.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """case "$receipt" in
  /*/run-*/receipt.txt) ;;"""

NEW = """case "$receipt" in
  "/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs"/run-*/receipt.txt) ;;"""

if source.count(OLD) != 1:
    sys.stderr.write("G4: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G4: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G4" "$g4/entry.sh" "$g4/isolation.sh" \
    "test_the_admission_requires_the_kernel_handle_of_the_invoker"
  survivor_probe "$g4/entry.sh" "G4"
fi

# ---------------------------------------------------------------------------
echo "--- G5: el detector del registro vuelve a exigir una raiz fija"
g5="$WORKDIR/g5"
mkdir -p "$g5" || exit 1
cp "$V2_REGISTRY_DETECTOR" "$g5/forge_v2_registry_parity.py" || exit 1
python3 - "$g5/forge_v2_registry_parity.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    if (
        not receipt.startswith("/")
        or not receipt.endswith("/receipt.txt")
        or not os.path.basename(receipt_dir).startswith(RECEIPT_RUN_DIR_PREFIX)
    ):
        return None, "la ruta del recibo no pertenece a una invocacion autorizada\""""

NEW = """    if (
        not receipt.startswith(
            "/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs/run-"
        )
        or not receipt.endswith("/receipt.txt")
    ):
        return None, "la ruta del recibo no pertenece a una invocacion autorizada\""""

if source.count(OLD) != 1:
    sys.stderr.write("G5: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G5: no se pudo aplicar la mutacion a la copia"
else
  g5_control_result="$WORKDIR/g5-control-result.txt"
  g5_mutant_result="$WORKDIR/g5-mutant-result.txt"
  : > "$g5_control_result"
  : > "$g5_mutant_result"
  check_external_battery "G5" "$WORKDIR/battery-g5.log" "$WORKDIR/battery-g5-control.log" \
    "the boundary is not accredited" \
    --control env FORGE_TEST_ENTRY="$ENTRY" \
      "$REGISTRY_RUNNER" "$V2_SCENARIOS" "$V2_REGISTRY_DETECTOR" \
        "$WORKDIR/g5-control-identities.txt" "$g5_control_result" \
    --mutant env FORGE_TEST_ENTRY="$ENTRY" \
      "$REGISTRY_RUNNER" "$V2_SCENARIOS" "$g5/forge_v2_registry_parity.py" \
        "$WORKDIR/g5-mutant-identities.txt" "$g5_mutant_result"
fi

# ---------------------------------------------------------------------------
echo "--- G6: el arnes del banco vuelve a citar una ruta fija de una maquina"
g6="$WORKDIR/g6"
prepare_copies "$g6" || exit 1
python3 - "$g6/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

pairs = [
    (
        'CONTAINMENT_RECEIPT_DIR = os.environ.get("FORGE_CONTAINMENT_RECEIPT_DIR", "").strip()',
        'CONTAINMENT_RECEIPT_DIR = '
        '"/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs"',
    ),
    (
        '"<directorio de recibos nuevo, o el que declare la invocacion>, un "',
        '"/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs, un "',
    ),
]
for old, new in pairs:
    if source.count(old) < 1:
        sys.stderr.write("G6: ancla no encontrada: %r\\n" % old)
        sys.exit(3)
    source = source.replace(old, new)

open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G6: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G6" "$g6/entry.sh" "$g6/isolation.sh" \
    "test_the_exit_code_of_the_eliminated_scenario_is_the_observed_signal" \
    "test_the_closure_verdict_requires_every_link_and_observes_the_absence"
  survivor_probe "$g6/entry.sh" "G6"
fi

# ---------------------------------------------------------------------------
echo "--- G7: el 124 del envoltorio sustituye el RC real del hijo"
g7="$WORKDIR/g7"
prepare_copies "$g7" || exit 1
python3 - "$g7/entry.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """elif /usr/bin/grep -Fq 'sending signal TERM' "$timeout_log" 2>/dev/null; then
  scenario_status=TIMEOUT
  wrapper_rc=124"""

NEW = """elif /usr/bin/grep -Fq 'sending signal TERM' "$timeout_log" 2>/dev/null; then
  scenario_status=TIMEOUT
  scenario_rc=124
  wrapper_rc=124"""

if source.count(OLD) != 1:
    sys.stderr.write("G7: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G7: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G7" "$g7/entry.sh" "$g7/isolation.sh" \
    "test_the_sigkill_is_published_as_minus_nine_and_the_wrapper_124_does_not_substitute_it" \
    "test_a_scenario_that_ignores_term_is_closed_by_kill_and_observed"
  survivor_probe "$g7/entry.sh" "G7"
fi

# ---------------------------------------------------------------------------
echo "--- G8: la conversion del RC acepta el 124 del envoltorio como un -9"
g8="$WORKDIR/g8"
prepare_copies "$g8" || exit 1
python3 - "$g8/forge_v2_safety_harness.py" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = """    # The POSITIVE form: an exit status, or the 128+N of the shell.
    if number < 128:
        return number"""

NEW = """    # The POSITIVE form: an exit status, or the 128+N of the shell.
    if number < 128:
        return -9 if number == 124 else number"""

if source.count(OLD) != 1:
    sys.stderr.write("G8: ancla no encontrada o ambigua\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW, 1))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G8: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G8" "$g8/entry.sh" "$g8/isolation.sh" \
    "test_the_sigkill_is_published_as_minus_nine_and_the_wrapper_124_does_not_substitute_it"
  survivor_probe "$g8/entry.sh" "G8"
fi

# ---------------------------------------------------------------------------
echo "--- G9: una trampa EXIT vuelve a leer un 'local' de su funcion"
g9="$WORKDIR/g9"
prepare_copies "$g9" || exit 1
python3 - "$g9/install_integration.sh" <<'PATCH_EOF'
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()

OLD = 'install_exit_cleanup "$TMPHOME"'
NEW = "trap 'rm -rf \"$TMPHOME\"' EXIT"

if source.count(OLD) < 1:
    sys.stderr.write("G9: ancla no encontrada\\n")
    sys.exit(3)
open(path, "w", encoding="utf-8").write(source.replace(OLD, NEW))
PATCH_EOF
if [ $? -ne 0 ]; then
  fail "G9: no se pudo aplicar la mutacion a la copia"
else
  check_mutant "G9" "$g9/entry.sh" "$g9/isolation.sh" \
    "test_no_exit_trap_of_the_suites_reads_a_variable_out_of_scope"
  survivor_probe "$g9/entry.sh" "G9"
fi

# ---------------------------------------------------------------------------
# The self-tests of the arnes itself: the instrument that measures the
# sensitivity is proven with the same rigour.
# ---------------------------------------------------------------------------
run_self_tests

# ---------------------------------------------------------------------------
# The exterior cleanup of the harness still runs after the failed mutants.
# ---------------------------------------------------------------------------
probe_dir="$WORKDIR/exterior-cleanup"
mkdir -p "$probe_dir"
: > "$probe_dir/artefact.txt"
rm -rf "$probe_dir/artefact.txt"
if [ ! -e "$probe_dir/artefact.txt" ]; then
  pass "la limpieza exterior del arnes se ejecuta DESPUES de los mutantes fallidos"
else
  fail "la limpieza exterior del arnes no se ejecuto"
fi

echo ""
echo "================================"
echo " Passed: $PASS"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
fi
echo " ALL PASS"
