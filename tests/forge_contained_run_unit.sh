#!/usr/bin/env bash
# shellcheck disable=SC2329  # test functions invoked indirectly via run_test "$name"
# tests/forge_contained_run_unit.sh — the CONTAINMENT of
# tools/verification/forge-contained-run.sh, proved with REAL invocations.
#
# The containment replaced the observer of the own tree, and it has to carry
# the guarantees the observer pretended to offer. Each one of them has a way
# of being FALSE, and this suite proves that each one of them is DETECTED
# when it is false:
#
#   1. BOUNDARY. The boundary is accredited BY INVOCATION: the receipt of a
#      run reports the effective PID namespace, the NSpid of the PID 1, the
#      type of the procfs and the private mount of /proc. A run that did not
#      accredit its boundary does not execute the scenario.
#   2. CLOSURE. The contained environment is WAITED FOR and its termination is
#      OBSERVED: the closure is CONFIRMED only when the outer wait over the
#      direct `unshare` child COMPLETED, that child returned RC 0 and the
#      effective termination of the private PID 1 was OBSERVED. A signal that
#      was SENT is not an observed termination, and a closure that could not
#      be confirmed does NOT certify and CONSERVES the context. A descendant
#      that survives its parent (a REPARENTED process, the very case the
#      observer had to poll for) does not outlive the run.
#   3. PRODUCT vs DEFENSIVE. The result of the cleanup of the product is
#      observed BEFORE the defensive cleanup and it is a verdict of its own:
#      a leftover is reported as FAIL and the defensive cleanup NEVER
#      converts it into a PASS.
#   4. EVIDENCE. An absent, partial, illegible or contradictory receipt is
#      REJECTED: there is no "PASS by absence" and no inference from a
#      missing field. The field of the containment evidence is
#      CONTAINMENT_EVIDENCE_CERTIFIABLE and it has NO alias: the legacy key
#      "CERTIFIABLE" belongs to the previous contract and is not accepted.
#      A consumer that certifies "zero survivors" cannot accept the
#      containment evidence alone: it also checks the expected RC of the
#      scenario (EXPECTED_SCENARIO_RC) and PRODUCT_CLEANUP_RESULT=PASS
#      observed before the defensive cleanup, and it CROSS-CHECKS the flag
#      POSITIVE_ACCEPTANCE that the receipt declares.
#   5. IDENTITY. A signal is bound to an identity (PID + starttime) and to
#      nothing else: the fallback that does not use a pidfd re-verifies the
#      identity immediately before the signal and it never claims the
#      guarantee of the pidfd.
#   6. PROTECTED STATE. The snapshot of the real user files is BY METADATA
#      ONLY: the content of a protected tree (the credentials, the auth file,
#      the prompt history) is NEVER read. The probe uses a FIFO as the
#      credentials: opening it for reading would block, so a snapshot that
#      opened it would hang.
#   7. STREAMS. The stdout and the stderr that the consumer captures are
#      EXACTLY the ones of the scenario, BYTE BY BYTE, with and without
#      `--receipt-out`: the receipt path travels by its own file or by the
#      dedicated descriptor 9, never by the streams. The entry reserves its
#      standard output and its standard error for the scenario and publishes
#      its own diagnosis in the fields of the receipt. The consumer does not
#      filter anything, so a noise on those streams would be visible here
#      instead of hidden.
#
# The invocations are REAL but they are inert: they only create processes of
# their own inside their own namespace and they never touch a process of the
# host.
#
# Compatible with bash 3.2+.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FORGE_ROOT="$(pwd)"

# The entry and the helper under test can be OVERRIDDEN, so that the
# sensitivity harness can point this suite at a MUTATED COPY that lives
# OUTSIDE the repository. The repository itself is never modified by a
# mutation: the copies are made by the harness.
FORGE_TEST_ENTRY="${FORGE_TEST_ENTRY:-$FORGE_ROOT/tools/verification/forge-contained-run.sh}"
FORGE_TEST_ISOLATION="${FORGE_TEST_ISOLATION:-$FORGE_ROOT/tests/isolation.sh}"
# The aggregator of the declarations of the cleanup of the product can also
# be OVERRIDDEN, so that the sensitivity harness can point this suite at a
# MUTATED COPY that lives OUTSIDE the repository.
FORGE_TEST_CLEANUP_AGGREGATE="${FORGE_TEST_CLEANUP_AGGREGATE:-$FORGE_ROOT/tests/forge_run_all_cleanup.py}"
# The OFFICIAL observer of the cleanup of the product (the criterion of the
# case CLEAN-1 of the V2 bank). It is the same file as the aggregator, but it
# is overridable SEPARATELY so that the sensitivity harness can point the
# check of the criterion at a mutated copy of the observer.
FORGE_TEST_CLEANUP_PROBE="${FORGE_TEST_CLEANUP_PROBE:-$FORGE_ROOT/tests/forge_run_all_cleanup.py}"
# The CI verifier of the V2 bank (tools/ci/v2-safety.sh). It declares the
# EXPECTED contract of each scenario of the bank, so it is overridable to let
# the sensitivity harness point the check of that contract at a mutated copy.
FORGE_TEST_V2_CI_VERIFIER="${FORGE_TEST_V2_CI_VERIFIER:-$FORGE_ROOT/tools/ci/v2-safety.sh}"
# The scanner of the REAL definitions of a shell file can also be
# OVERRIDDEN, so that the sensitivity harness can point the checks that use
# it at a mutated copy.
FORGE_TEST_SHELL_DEFS_SCANNER="${FORGE_TEST_SHELL_DEFS_SCANNER:-$FORGE_ROOT/tests/forge_shell_defs.py}"
# The scanner of the primitives of the NETWORK of the suites. It is
# overridable for the same reason.
FORGE_TEST_NETWORK_SCANNER="${FORGE_TEST_NETWORK_SCANNER:-$FORGE_ROOT/tests/forge_network_free.py}"
# The gate of admission of the containment. It is overridable so that the
# SENSITIVITY harness can point the check of the kernel handle at a
# MUTATED COPY that lives OUTSIDE the repository.
FORGE_TEST_ADMISSION_GUARD="${FORGE_TEST_ADMISSION_GUARD:-$FORGE_ROOT/tools/verification/require-v2-containment.sh}"
# The harness of the V2 bank and the runner of its scenarios. They are
# overridable for the same reason: the contract of the bank is checked
# against COPIES when a mutant has to be measured.
FORGE_TEST_V2_HARNESS="${FORGE_TEST_V2_HARNESS:-$FORGE_ROOT/tests/forge_v2_safety_harness.py}"
FORGE_TEST_V2_RUNNER="${FORGE_TEST_V2_RUNNER:-$FORGE_ROOT/tests/forge_v2_safety_scenarios.sh}"
# The STABLE entry of the V2 bank (tests/forge_v2_safety.sh): the consumer
# that validates the report of the harness. It is overridable for the same
# reason: the criterion of the ausencia verificada is checked against a
# COPY when a mutant has to be measured.
FORGE_TEST_V2_STABLE="${FORGE_TEST_V2_STABLE:-$FORGE_ROOT/tests/forge_v2_safety.sh}"
# The probe of the contract of the V2 bank (the static and behavioural
# detector of the properties of C2 and C3).
FORGE_TEST_V2_CONTRACT_PROBE="${FORGE_TEST_V2_CONTRACT_PROBE:-$FORGE_ROOT/tests/forge_v2_contract_probe.py}"
# The DETECTOR of the parental relation of the registry of the V2 bank. It
# is overridable for the same reason: the sensitivity harness points it at
# a MUTATED COPY that lives OUTSIDE the repository.
FORGE_TEST_V2_REGISTRY_DETECTOR="${FORGE_TEST_V2_REGISTRY_DETECTOR:-$FORGE_ROOT/tests/forge_v2_registry_parity.py}"
# The verifier of the PROTECTED RESOURCES. It is overridable for the same
# reason: the criterion of the observation (an impossible observation is not
# an absence) is checked against a COPY when a mutant has to be measured.
FORGE_TEST_PROTECTED_RESOURCES="${FORGE_TEST_PROTECTED_RESOURCES:-$FORGE_ROOT/tests/forge_protected_resources.py}"
# The SOURCE of this very battery. It is overridable for the same reason: the
# criterion of the REACH of the restriction of the network is a criterion
# about the COMMENT that declares it, and the sensitivity harness measures it
# against a COPY that carries the former claim.
FORGE_TEST_BATTERY_SOURCE="${FORGE_TEST_BATTERY_SOURCE:-$FORGE_ROOT/tests/forge_contained_run_unit.sh}"

# The SCOPE of the declarations of the contained runs of THIS battery.
#
# This battery exercises the CONTAINMENT (the entry and the helper) with
# synthetic scenarios that it creates itself: the PRODUCT of the repository
# (the installers, the launcher, plugin-sync) does NOT run in any of them.
# The declarations of these contained runs therefore do NOT describe the
# cleanup of the product and they are NOT APPLICABLE for it: they are
# negative controls of the harness.
#
# The scope is declared HERE, for the WHOLE battery, because EVERY contained
# run of this file is a fixture of the harness. Their real verdicts stay in
# the receipts of the runs and in the collector of the consumer: nothing is
# hidden, the verdict simply does not describe the cleanup of the product.
export FORGE_CONTAINED_RUN_DECLARATION_SCOPE="NOT_APPLICABLE"

# The declarations of the contained runs of THIS battery are NOT published to
# the collector of the consumer.
#
# The reason is the JOINT validation of the scope and the verdict of a
# declaration (tests/forge_run_all_cleanup.py): a FAIL under a
# NOT_APPLICABLE scope is CONTRADICTORY evidence, and the aggregate refuses
# to launder it (it PRESERVES the failure, because a scope must never hide
# one). A negative control of the harness that publishes such a pair would
# therefore poison the aggregate of the PRODUCT with a failure that does not
# describe it.
#
# The verdicts of these runs are not hidden: they stay in the receipts of the
# runs, which is where this battery reads them, and the scope of the
# declaration stays NOT_APPLICABLE, which says exactly that they do not
# describe the cleanup of the product.
unset FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE

# shellcheck source=tests/isolation.sh
. "$FORGE_TEST_ISOLATION"

# The helpers of the isolation read the entry from this variable. It is
# pointed at the entry UNDER TEST right after the source, so a mutated copy
# is used by every helper and not only by the direct invocations.
FORGE_CONTAINMENT_ENTRY="$FORGE_TEST_ENTRY"

FAIL=0
PASS=0
TMPDIR_BASE="/tmp/opencode"
ENTRY="$FORGE_TEST_ENTRY"
RECEIPT_ROOT="/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs"

# The result of every check is ALSO written in this file. The checks run
# each one in a subshell (see run_test), so the counters of the shell are
# lost in the subshell: the file is what survives, and the summary at the
# end is computed from it.
RESULTS_FILE=""

cleanup() {
  # A mutated entry that does NOT wait for its launcher leaves the contained
  # environment running for a while. Before the artefacts of this suite are
  # removed, the heartbeats are given the chance to FREEZE: otherwise the
  # contained environment would recreate the files of the work directory after
  # its removal and the suite would leave residue behind.
  local heartbeat waited size previous
  for heartbeat in "$WORKDIR"/hb-*.txt; do
    [ -f "$heartbeat" ] || continue
    waited=0
    previous=""
    while [ "$waited" -lt 60 ]; do
      size="$(wc -c < "$heartbeat" 2>/dev/null || printf '0')"
      if [ "$size" = "$previous" ]; then
        break
      fi
      previous="$size"
      sleep 0.5
      waited=$((waited + 1))
    done
  done
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}

trap cleanup EXIT

pass() {
  echo "  PASS: $1"
  [ -n "$RESULTS_FILE" ] && printf 'PASS\n' >> "$RESULTS_FILE"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1" >&2
  [ -n "$RESULTS_FILE" ] && printf 'FAIL\n' >> "$RESULTS_FILE"
  FAIL=$((FAIL + 1))
}

run_test() {
  local name="$1"
  echo "--- $name"
  # Every check runs in its OWN SUBSHELL. A check that terminates in an
  # ABNORMAL way (a crash of the shell, a signal) is a FAILURE of that
  # check and it must NOT abort the battery: otherwise a single broken
  # mutant would hide the rest of the evidence and the sensitivity harness
  # could not attribute the failure to the check that covers the property.
  local rc=0
  ( "$name" ) || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "  FAIL: la comprobacion $name termino de forma ANORMAL (rc=$rc)" >&2
    [ -n "$RESULTS_FILE" ] && printf 'FAIL\n' >> "$RESULTS_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Helpers of the acceptance contract.
# ---------------------------------------------------------------------------

# write_heartbeat_scenario <path>
#
# Writes a scenario that announces that it is ready and then keeps a
# HEARTBEAT inside the containment. The heartbeat is the only way to observe
# from the OUTSIDE that the contained environment really terminated: it grows
# while the contained environment lives and it FREEZES when it dies. No
# process of the host is ever enumerated.
write_heartbeat_scenario() {
  local destination="$1"
  cat > "$destination" <<'HEARTBEAT_EOF'
#!/bin/sh
# $1 = heartbeat file, $2 = ready file
printf 'READY\n' > "$2"
while true; do
  printf 'x' >> "$1"
  sleep 0.05
done
HEARTBEAT_EOF
  chmod +x "$destination"
}
# write_detached_scenario <path>
#
# Writes a scenario that leaves a DETACHED descendant ALIVE inside the
# namespace: `setsid --fork` makes the writer the leader of a new session
# whose parent exits at once, so the descendant is reparented and nobody
# registers it anywhere. The scenario waits a little so that the descendant
# is demonstrably ALIVE inside the frontier before the frontier is closed.
write_detached_scenario() {
  local destination="$1"
  cat > "$destination" <<'DETACHED_EOF'
#!/bin/sh
# $1 = heartbeat file
setsid --fork /bin/sh -c 'while true; do printf "x" >> "$1"; sleep 0.05; done' sh "$1" >/dev/null 2>&1
sleep 1
exit 0
DETACHED_EOF
  chmod +x "$destination"
}

# write_term_ignoring_scenario <path>
#
# Writes a scenario that IGNORES the TERM of the bounded close: its trap for
# TERM is empty, so the TERM that `timeout` sends does not stop it and only
# the escalation to KILL (after the bounded grace) terminates it. It keeps a
# HEARTBEAT so that the exterior can observe that the contained environment
# really died instead of merely having been asked to.
write_term_ignoring_scenario() {
  local destination="$1"
  cat > "$destination" <<'TERM_EOF'
#!/bin/sh
# $1 = heartbeat file, $2 = ready file
trap '' TERM
printf 'READY\n' > "$2"
while true; do
  printf 'x' >> "$1"
  sleep 0.05
done
TERM_EOF
  chmod +x "$destination"
}

# pid1_completion_is_observed <receipt>
#
# The receipt DECLARES that the effective termination of the private PID 1 was
# observed (PID1_COMPLETION_OBSERVED=PASS). The declaration is verified
# against the ARTEFACT that PID 1 wrote when it completed its exit path: a
# receipt that asserts the observation without the marker is a FORGERY, and
# the certification of the closure would rest on a lie.
pid1_completion_is_observed() {
  local receipt="$1" run_dir marker marker_value=""
  [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ] || return 1
  run_dir="$(dirname "$(forge_receipt_read "$receipt" RECEIPT_PATH 2>/dev/null || printf '')")"
  [ -n "$run_dir" ] || return 1
  marker="$run_dir/pid1.completion.status"
  [ -f "$marker" ] || return 1
  IFS= read -r marker_value < "$marker" || return 1
  [ "$marker_value" = "PASS" ]
}

# write_marker_scenario <path>
#
# Writes a scenario that leaves a MARKER behind. The marker is the proof that
# the scenario really EXECUTED: it is used by the control that proves that an
# unaccredited frontier does not execute the scenario.
write_marker_scenario() {
  local destination="$1"
  cat > "$destination" <<'MARKER_EOF'
#!/bin/sh
# $1 = marker file
printf 'EJECUTADO\n' > "$1"
exit 0
MARKER_EOF
  chmod +x "$destination"
}

# write_namespace_probe_scenario <path>
#
# Writes a scenario that records, FROM INSIDE the frontier, the PID namespace
# of itself and the PID namespace of the PID 1 it sees. When the /proc of the
# containment is the PRIVATE one, both links point to the SAME namespace. When
# the /proc were the one of the host, the link of the PID 1 would not even be
# readable and the frontier would NOT be accredited. Only namespace LINKS are
# read: no process of the host is enumerated and no command line is read.
write_namespace_probe_scenario() {
  local destination="$1"
  cat > "$destination" <<'NAMESPACE_EOF'
#!/bin/sh
# $1 = report file
self_ns="$(readlink /proc/self/ns/pid 2>/dev/null || printf 'UNREADABLE')"
pid1_ns="$(readlink /proc/1/ns/pid 2>/dev/null || printf 'UNREADABLE')"
printf 'SELF=%s\nPID1=%s\n' "$self_ns" "$pid1_ns" > "$1"
exit 0
NAMESPACE_EOF
  chmod +x "$destination"
}

# heartbeat_size <file>
# Prints the size of the heartbeat, or 0 when it does not exist.
heartbeat_size() {
  if [ -f "$1" ]; then
    wc -c < "$1" 2>/dev/null || printf '0'
  else
    printf '0'
  fi
}

# heartbeat_is_frozen <file> [seconds]
# Succeeds when the heartbeat does not grow during the observation: the
# contained environment really terminated.
heartbeat_is_frozen() {
  local file="$1" seconds="${2:-2}" first second
  first="$(heartbeat_size "$file")"
  sleep "$seconds"
  second="$(heartbeat_size "$file")"
  [ "$first" = "$second" ]
}

# patch_entry_copy <source> <destination> <mode>
#
# Copies the entry OUTSIDE the repository and applies ONE mutation to the
# copy. The repository is never modified. The anchors are asserted: a
# mutation that does not find its anchor is an ERROR of the harness, never a
# silent no-op.
#
# The modes:
#
#   accreditation-fails   the accreditation of the interior FAILS (the guard
#                         that stops the scenario is INTACT): the control of
#                         "an unaccredited frontier does not execute".
#   accreditation-ignored the accreditation of the interior FAILS and the
#                         guard that stops the scenario is REMOVED: the
#                         scenario runs with an unaccredited frontier. This
#                         is the mutation of the contract.
#   no-wait              the launcher is never waited for: the closure is
#                         DECLARED without the contained environment having
#                         terminated.
#   no-mount-proc        the private /proc is not established.
#   no-pid1-completion   PID 1 never writes its final completion marker: the
#                         effective termination of the private PID 1 is NOT
#                         observed, so the closure CANNOT be confirmed and the
#                         context must be preserved.
#   launcher-not-recoverable
#                         the status of the launcher is NOT recoverable: the
#                         recovery branch of the interrupted wait is reached
#                         and the second `wait` yields 127 (bash's "the child
#                         is no longer waitable"). The entry must record
#                         LAUNCHER_RC=NOT_RECOVERABLE and
#                         LAUNCHER_WAIT_COMPLETED=NO, and it must NOT certify
#                         the evidence: the closure of a launcher whose
#                         status is unknown cannot be CONFIRMED. The `wait` is
#                         KEPT (the launcher is reaped, so the contained
#                         environment never survives this fixture).
patch_entry_copy() {
  local source="$1" destination="$2" mode="$3"
  cp "$source" "$destination" || return 1
  python3 - "$destination" "$mode" <<'PATCH_EOF'
import sys

path, mode = sys.argv[1], sys.argv[2]
source = open(path, encoding="utf-8").read()

ACCREDITATION_FAILS = (
    '[ "$pid1_stat" != 1 ]',
    '[ "$pid1_stat" != 1 ] || [ 1 = 1 ]',
)
ACCREDITATION_GUARD = (
    'if [ "$accreditation_reason" != PASS ]; then',
    'if false; then',
)
NO_WAIT = (
    '    wait "$runner_pid"',
    '    :',
)
NO_MOUNT_PROC = (
    '--map-root-user --pid --fork --kill-child=KILL --mount-proc',
    '--map-root-user --pid --fork --kill-child=KILL',
)
NO_PID1_COMPLETION = (
    '  write_status pid1.completion.status PASS || exit 70',
    '  :',
)
# The branch of the RECOVERY of the status of the launcher is reached and
# the second `wait` yields 127. The `wait` itself is kept, so the launcher
# is reaped and the contained environment does NOT survive this fixture.
LAUNCHER_NOT_RECOVERABLE = (
    (
        '      if [[ -z $runner_details ]]; then\n',
        '      if true; then  # PATCH: se alcanza la rama de recuperacion\n',
    ),
    (
        '        wait "$runner_pid" 2>/dev/null || runner_rc=$?\n',
        '        wait "$runner_pid" 2>/dev/null || runner_rc=$?\n'
        '        runner_rc=127  # PATCH: el estado del lanzador NO es recuperable\n',
    ),
)

PATCHES = {
    "accreditation-fails": [ACCREDITATION_FAILS],
    "accreditation-ignored": [ACCREDITATION_FAILS, ACCREDITATION_GUARD],
    "no-wait": [NO_WAIT],
    "no-mount-proc": [NO_MOUNT_PROC],
    "no-pid1-completion": [NO_PID1_COMPLETION],
    "launcher-not-recoverable": [LAUNCHER_NOT_RECOVERABLE],
}

if mode not in PATCHES:
    sys.stderr.write("modo de parche desconocido: %s\n" % mode)
    sys.exit(2)

# A mode may carry ONE pair (old, new) or a LIST of pairs. The list is
# needed by the modes that touch several anchors of the same branch.
for patch in PATCHES[mode]:
    pairs = patch if isinstance(patch[0], (list, tuple)) else [patch]
    for old, new in pairs:
        if old not in source:
            sys.stderr.write(
                "el parche %s no encuentra su ancla en %s: %r\n" % (mode, path, old)
            )
            sys.exit(3)
        source = source.replace(old, new, 1)

open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
}

# patch_isolation_copy <source> <destination> <mode>
#
# Copies the helper OUTSIDE the repository and applies ONE mutation to the
# copy:
#
#   accepts-anything  the consumer of the evidence accepts EVERY receipt,
#                     including an absent, partial or corrupt one.
#   product-as-pass   the consumer converts a FAILURE of the product into a
#                     PASS because the defensive cleanup of the containment
#                     succeeded.
patch_isolation_copy() {
  local source="$1" destination="$2" mode="$3"
  cp "$source" "$destination" || return 1
  python3 - "$destination" "$mode" <<'PATCH_EOF'
import sys

path, mode = sys.argv[1], sys.argv[2]
source = open(path, encoding="utf-8").read()

ACCEPTS_ANYTHING = (
    'forge_receipt_containment_evidence() {\n  local receipt="$1" field value\n',
    'forge_receipt_containment_evidence() {\n  return 0\n}\n\n'
    'forge_receipt_containment_evidence_real() {\n  local receipt="$1" field value\n',
)
PRODUCT_AS_PASS = (
    '  if [ "$product_result" != "PASS" ]; then',
    '  if false; then',
)

PATCHES = {
    "accepts-anything": [ACCEPTS_ANYTHING],
    "product-as-pass": [PRODUCT_AS_PASS],
}

if mode not in PATCHES:
    sys.stderr.write("modo de parche desconocido: %s\n" % mode)
    sys.exit(2)

for old, new in PATCHES[mode]:
    if old not in source:
        sys.stderr.write(
            "el parche %s no encuentra su ancla en %s: %r\n" % (mode, path, old)
        )
        sys.exit(3)
    source = source.replace(old, new, 1)

open(path, "w", encoding="utf-8").write(source)
PATCH_EOF
}

WORKDIR="$(mktemp -d "$TMPDIR_BASE/forge-contained-unit.XXXXXX")"
mkdir -p "$WORKDIR/home/.config" "$WORKDIR/home/.cache" \
  "$WORKDIR/home/.local/share" "$WORKDIR/home/.local/state" "$WORKDIR/tmp"
RESULTS_FILE="$WORKDIR/results.txt"
: > "$RESULTS_FILE"

# ---------------------------------------------------------------------------
# The EFFECTIVE RESTRICTION of the network.
#
# The static scanner proves that the CODE of the battery does not contain
# the primitives of the network. The absence of network is a property of
# the EXECUTION too, and this battery runs with the network RESTRICTED: the
# primitives are substituted by doubles that REFUSE and the resolution of
# names is disabled. The restriction is written by the scanner itself (it
# knows how to write it and how to VERIFY that it is effective) and it is
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
# ---------------------------------------------------------------------------
NETWORK_GUARD_DIR="$WORKDIR/network-guard"
NETWORK_GUARD_STATUS="NOT_INSTALLED"
if python3 "$FORGE_TEST_NETWORK_SCANNER" guard "$NETWORK_GUARD_DIR" \
  >"$WORKDIR/network-guard.log" 2>&1; then
  NETWORK_GUARD_STATUS="EFFECTIVE"
  PATH="$NETWORK_GUARD_DIR:$PATH"
  export PATH
else
  echo "  WARN: la restriccion de la red NO se pudo instalar" >&2
  sed -n '1,10p' "$WORKDIR/network-guard.log" | sed 's/^/      /' >&2
fi

# The scenarios of this suite run with a short budget: they are inert.
FORGE_CONTAINMENT_SCENARIO_TIMEOUT=20
FORGE_CONTAINMENT_CLOSE_TIMEOUT=3

# run_entry <scenario-timeout> <close-timeout> -- <command> [args...]
#
# Runs the entry directly and prints the path of the receipt it published.
# The pointer file is REMOVED before the call, so a stale pointer can never
# be read as the evidence of this invocation.
run_entry() {
  local scenario_timeout="$1" close_timeout="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  rm -f "$WORKDIR/pointer.txt"
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$WORKDIR/pointer.txt" \
    --scenario-timeout "$scenario_timeout" \
    --close-timeout "$close_timeout" \
    -- "$@" >"$WORKDIR/entry.out" 2>"$WORKDIR/entry.err"
  ENTRY_RC=$?
  ENTRY_RECEIPT=""
  if [ -s "$WORKDIR/pointer.txt" ]; then
    IFS= read -r ENTRY_RECEIPT < "$WORKDIR/pointer.txt" || ENTRY_RECEIPT=""
  fi
  return "$ENTRY_RC"
}

# ---------------------------------------------------------------------------
# 1. The boundary is accredited BY INVOCATION and the closure is CONFIRMED.
# ---------------------------------------------------------------------------
test_the_boundary_and_the_closure_are_accredited() {
  run_entry 20 3 -- /bin/sh -c 'echo INERT; ls /proc | grep -c "^[0-9]"'
  # A raw invocation of the entry does NOT declare the cleanup of the
  # product (nobody wrote the marker), so there is NO POSITIVE ACCEPTANCE
  # and the entry returns 70: the code of "not certifiable". An RC 0 of the
  # scenario is not an acceptance.
  if [ "$ENTRY_RC" -eq 70 ]; then
    pass "una corrida inerte sin marcador de limpieza del producto NO devuelve 0 (rc=70)"
  else
    fail "una corrida inerte sin marcador de limpieza del producto deberia devolver 70 (rc=$ENTRY_RC)"
    sed -n '1,20p' "$WORKDIR/entry.err" | sed 's/^/      /' >&2
    return
  fi

  if [ -z "$ENTRY_RECEIPT" ] || [ ! -s "$ENTRY_RECEIPT" ]; then
    fail "la entrada no publico ningun recibo: no hay evidencia de frontera ni de cierre"
    return
  fi
  pass "la entrada publica el recibo de la corrida ($ENTRY_RECEIPT)"

  # A raw invocation of the entry does NOT declare the cleanup of the
  # product: nobody wrote the marker. The evidence of the CONTAINMENT is
  # still certifiable (the boundary was accredited and the contained
  # environment was waited for), but the POSITIVE ACCEPTANCE is NOT: the
  # result of the product was never observed. That is exactly what the
  # contract says (an RC 0 of the scenario does not certify the cleanup of
  # the product on its own) and exactly what the renamed field expresses.
  if [ "$(forge_receipt_read "$ENTRY_RECEIPT" ACCREDITATION 2>/dev/null || true)" = "PASS" ] \
    && [ "$(forge_receipt_read "$ENTRY_RECEIPT" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ] \
    && [ "$(forge_receipt_read "$ENTRY_RECEIPT" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$ENTRY_RECEIPT" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$ENTRY_RECEIPT" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ] \
    && [ "$(forge_receipt_read "$ENTRY_RECEIPT" RECEIPT_COMPLETENESS 2>/dev/null || true)" = "COMPLETE" ]; then
    pass "el recibo acredita la acreditacion, los tres eslabones del cierre, la completitud y el cierre"
  else
    fail "el recibo no acredita la acreditacion, los tres eslabones del cierre, la completitud y el cierre"
    forge_receipt_summary "$ENTRY_RECEIPT" >&2 || true
  fi

  if [ "$(forge_receipt_read "$ENTRY_RECEIPT" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$ENTRY_RECEIPT" POSITIVE_ACCEPTANCE 2>/dev/null || true)" = "NO" ] \
    && [ "$(forge_receipt_product_cleanup "$ENTRY_RECEIPT")" = "UNKNOWN" ]; then
    pass "una corrida sin marcador de limpieza del producto: la contencion es certificable pero NO hay aceptacion positiva"
  else
    fail "una corrida sin marcador de limpieza del producto deberia ser certificable SIN aceptacion positiva"
    forge_receipt_summary "$ENTRY_RECEIPT" >&2 || true
  fi

  # The consumer REJECTS it: the gate requires the positive acceptance.
  if forge_receipt_require "$ENTRY_RECEIPT" >/dev/null 2>&1; then
    fail "el consumidor acepto una corrida sin limpieza del producto observada"
  else
    pass "el consumidor RECHAZA una corrida sin limpieza del producto observada"
  fi

  # The effective boundary: a private PID namespace, a PID 1 interior, a
  # NSpid of 1 and a private procfs.
  local pid_namespace nspid procfs private inner
  pid_namespace="$(forge_receipt_read "$ENTRY_RECEIPT" PID_NAMESPACE 2>/dev/null || true)"
  nspid="$(forge_receipt_read "$ENTRY_RECEIPT" NSPID 2>/dev/null || true)"
  procfs="$(forge_receipt_read "$ENTRY_RECEIPT" PROCFS_TYPE 2>/dev/null || true)"
  private="$(forge_receipt_read "$ENTRY_RECEIPT" PROC_MOUNT_PRIVATE 2>/dev/null || true)"
  inner="$(forge_receipt_read "$ENTRY_RECEIPT" PID1_INTERIOR 2>/dev/null || true)"
  case "$pid_namespace" in
    pid:\[*\]) pass "el recibo registra el namespace PID efectivo ($pid_namespace)" ;;
    *) fail "el recibo no registra un namespace PID efectivo (valor: $pid_namespace)" ;;
  esac
  if [ "$nspid" = "1" ] && [ "$inner" = "1" ]; then
    pass "el recibo registra el PID 1 interior con NSpid 1"
  else
    fail "el recibo no registra el PID 1 interior con NSpid 1 (inner=$inner nspid=$nspid)"
  fi
  if [ "$procfs" = "proc" ] && [ "$private" = "YES" ]; then
    pass "el recibo registra un procfs privado montado en /proc"
  else
    fail "el recibo no registra un procfs privado (tipo=$procfs privado=$private)"
  fi
}

# ---------------------------------------------------------------------------
# 2. A descendant that survives its parent does not outlive the run.
# ---------------------------------------------------------------------------
test_a_detached_descendant_does_not_outlive_the_run() {
  local marker="$WORKDIR/heartbeat.txt"
  : > "$marker"

  # The descendant is detached: its parent exits at once and it keeps
  # writing. It is never registered anywhere: the containment does not need
  # to know about it, because the kernel tears the namespace down when its
  # PID 1 exits.
  cat > "$WORKDIR/detached.sh" <<'DETACHED_EOF'
#!/bin/sh
# A descendant that outlives its parent and that nobody registered.
(
  while true; do
    printf 'x' >> "$1"
    sleep 0.05
  done
) &
exit 0
DETACHED_EOF
  chmod +x "$WORKDIR/detached.sh"

  local scenario
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  forge_contained_run "$scenario" /bin/sh "$WORKDIR/detached.sh" "$marker" >/dev/null 2>&1
  rm -f "$scenario"

  local size_first size_second
  size_first="$(wc -c < "$marker")"
  if [ "$size_first" -lt 1 ]; then
    fail "el descendiente desligado no escribio nada: el control no se ejercito"
    return
  fi
  pass "el descendiente desligado escribio dentro de la contencion (no estaba registrado en ninguna parte)"

  # The namespace is gone when the entry returns: the file cannot grow.
  sleep 1
  size_second="$(wc -c < "$marker")"
  if [ "$size_first" = "$size_second" ]; then
    pass "el descendiente desligado no sobrevive al cierre de la contencion"
  else
    fail "el descendiente desligado SIGUE VIVO tras el cierre de la contencion ($size_first -> $size_second)"
  fi
}

# ---------------------------------------------------------------------------
# 3. The result of the product is a verdict of its own.
# ---------------------------------------------------------------------------
test_the_product_result_is_separated_from_the_defensive_one() {
  local scenario
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }

  # A command that leaves a process behind: the product cleanup is FAIL.
  local rc=0
  forge_contained_run "$scenario" /bin/sh -c 'sleep 30 & exit 0' >/dev/null 2>&1 || rc=$?
  local receipt="$FORGE_CONTAINMENT_LAST_RECEIPT"
  if [ -n "$receipt" ] && [ -s "$receipt" ]; then
    if [ "$(forge_receipt_product_cleanup "$receipt")" = "FAIL" ]; then
      pass "un proceso que sobrevive al producto se declara FAIL en la limpieza del producto"
    else
      fail "un proceso que sobrevive al producto NO se declara FAIL (resultado: $(forge_receipt_product_cleanup "$receipt"))"
    fi
    if [ "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "YES" ] \
      && [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ]; then
      pass "la evidencia de la CONTENCION sigue certificable: el fallo del producto NO la invalida"
    else
      fail "la evidencia de la contencion no es certificable tras un fallo del producto"
      forge_receipt_summary "$receipt" >&2 || true
    fi
    if [ "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || true)" = "NO" ] \
      && ! forge_receipt_require "$receipt" >/dev/null 2>&1; then
      pass "no hay aceptacion positiva con un producto que no limpio: el consumidor RECHAZA la evidencia"
    else
      fail "el consumidor acepto un producto que no limpio como si hubiera aceptacion positiva"
      forge_receipt_summary "$receipt" >&2 || true
    fi
  else
    fail "no hay recibo de la corrida con un proceso superviviente"
  fi
  if [ "$rc" -ne 0 ]; then
    pass "una corrida cuyo producto no limpia bien NO devuelve un exito (rc=$rc)"
  else
    fail "una corrida cuyo producto no limpia bien devolvio 0"
  fi

  # A command that fails keeps its RC: the defensive cleanup does not
  # convert a failure of the product into a PASS.
  rc=0
  forge_contained_run "$scenario" /bin/sh -c 'exit 42' >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 42 ]; then
    pass "el RC del producto se conserva (42) y no lo convierte la limpieza defensiva"
  else
    fail "el RC del producto NO se conserva (rc=$rc)"
  fi
  rm -f "$scenario"
}

# ---------------------------------------------------------------------------
# 4. The timeout is bounded and the failure is visible.
# ---------------------------------------------------------------------------
test_the_timeout_is_bounded_and_visible() {
  run_entry 1 2 -- /bin/sh -c 'sleep 30'
  if [ "$ENTRY_RC" -eq 124 ]; then
    pass "un escenario que excede el presupuesto termina con RC 124"
  else
    fail "un escenario que excede el presupuesto deberia terminar con RC 124 (rc=$ENTRY_RC)"
  fi
  if [ -n "$ENTRY_RECEIPT" ] && [ -s "$ENTRY_RECEIPT" ]; then
    local status
    status="$(forge_receipt_read "$ENTRY_RECEIPT" SCENARIO_STATUS 2>/dev/null || true)"
    if [ "$status" = "TIMEOUT" ]; then
      pass "el recibo registra el estado TIMEOUT del escenario"
    else
      fail "el recibo no registra TIMEOUT (estado: $status)"
    fi
    local closure
    closure="$(forge_receipt_read "$ENTRY_RECEIPT" CLOSURE 2>/dev/null || true)"
    if [ "$closure" = "CONFIRMED" ] \
      && [ "$(forge_receipt_read "$ENTRY_RECEIPT" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
      && [ "$(forge_receipt_read "$ENTRY_RECEIPT" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ]; then
      pass "el cierre se confirma despues de un timeout: el entorno contenido se espero y su terminacion se observo"
    else
      fail "el cierre no se confirmo tras un timeout (cierre: $closure)"
    fi
  else
    fail "no hay recibo de la corrida que expiro"
  fi
}

# ---------------------------------------------------------------------------
# 5. The interface fails closed.
# ---------------------------------------------------------------------------
test_the_interface_fails_closed() {
  run_entry 0 3 -- /bin/true
  if [ "$ENTRY_RC" -eq 64 ]; then
    pass "un presupuesto invalido se rechaza con RC 64"
  else
    fail "un presupuesto invalido deberia rechazarse con RC 64 (rc=$ENTRY_RC)"
  fi

  run_entry 20 3
  if [ "$ENTRY_RC" -eq 64 ]; then
    pass "una invocacion sin orden se rechaza con RC 64"
  else
    fail "una invocacion sin orden deberia rechazarse con RC 64 (rc=$ENTRY_RC)"
  fi

  # A receipt directory that is not the authorized one is rejected: there is
  # no place to hide the evidence.
  rm -f "$WORKDIR/pointer.txt"
  bash "$ENTRY" --receipt-dir "$WORKDIR/elsewhere" --receipt-out "$WORKDIR/pointer.txt" \
    --scenario-timeout 20 --close-timeout 3 -- /bin/true >/dev/null 2>&1
  if [ "$?" -eq 64 ]; then
    pass "un directorio de recibos no autorizado se rechaza con RC 64"
  else
    fail "un directorio de recibos no autorizado deberia rechazarse con RC 64"
  fi
}

# ---------------------------------------------------------------------------
# 6. The reader of the evidence rejects what it cannot trust.
# ---------------------------------------------------------------------------
test_the_reader_rejects_untrustworthy_evidence() {
  if forge_receipt_require "$WORKDIR/absent.txt" >/dev/null 2>&1; then
    fail "un recibo ausente se acepto como evidencia"
  else
    pass "un recibo ausente se rechaza: no hay PASS por ausencia"
  fi

  : > "$WORKDIR/empty.txt"
  if forge_receipt_require "$WORKDIR/empty.txt" >/dev/null 2>&1; then
    fail "un recibo vacio se acepto como evidencia"
  else
    pass "un recibo vacio se rechaza"
  fi

  printf 'ACCREDITATION=PASS\n' > "$WORKDIR/partial.txt"
  if forge_receipt_require "$WORKDIR/partial.txt" >/dev/null 2>&1; then
    fail "un recibo parcial se acepto como evidencia"
  else
    pass "un recibo parcial se rechaza"
  fi

  printf 'ACCREDITATION=PASS\nRECEIPT_COMPLETENESS=COMPLETE\nCLOSURE=CONFIRMED\nCONTAINMENT_EVIDENCE_CERTIFIABLE=YES\n' \
    > "$WORKDIR/handmade.txt"
  if forge_receipt_require "$WORKDIR/handmade.txt" >/dev/null 2>&1; then
    fail "un receipt escrito a mano se acepto: la evidencia ausente no se puede fabricar"
  else
    pass "un recibo minimo sin la fila de terminacion no se acepta"
  fi

  # The reader of a single field fails when the field is absent.
  if forge_receipt_read "$WORKDIR/empty.txt" ACCREDITATION >/dev/null 2>&1; then
    fail "la lectura de un campo ausente devolvio un valor"
  else
    pass "la lectura de un campo ausente falla de forma visible"
  fi
}

# ---------------------------------------------------------------------------
# 7. The identity of the registry: absence and corruption are ERRORS.
# ---------------------------------------------------------------------------
test_the_registry_rejects_absent_and_corrupted_evidence() {
  if forge_own_identities_check "$WORKDIR/absent-registry.txt" >/dev/null 2>&1; then
    fail "un registro ausente se acepto: su ausencia es un ERROR, no la prueba de que no quede nada vivo"
  else
    pass "un registro ausente se rechaza como ERROR"
  fi

  : > "$WORKDIR/empty-registry.txt"
  if forge_own_identities_check "$WORKDIR/empty-registry.txt" >/dev/null 2>&1; then
    fail "un registro vacio se acepto"
  else
    pass "un registro vacio se rechaza como ERROR"
  fi

  printf '100 1000\n' > "$WORKDIR/no-namespace.txt"
  if forge_own_identities_check "$WORKDIR/no-namespace.txt" >/dev/null 2>&1; then
    fail "un registro sin namespace se acepto"
  else
    pass "un registro sin namespace se rechaza como ERROR"
  fi

  printf 'NAMESPACE pid:[1]\n esto-no-es-una-identidad\n' > "$WORKDIR/broken-registry.txt"
  if forge_own_identities_check "$WORKDIR/broken-registry.txt" >/dev/null 2>&1; then
    fail "un registro con una linea mal formada se acepto"
  else
    pass "un registro con una linea mal formada se rechaza como ERROR"
  fi

  printf 'NAMESPACE pid:[1]\n100 1000\n' > "$WORKDIR/good-registry.txt"
  local count
  count="$(forge_own_identities_check "$WORKDIR/good-registry.txt" 2>/dev/null || true)"
  if [ "$count" = "1" ]; then
    pass "un registro integro se acepta y se cuentan sus identidades"
  else
    fail "un registro integro no se acepto (count='$count')"
  fi

  if forge_own_identities_check "$WORKDIR/good-registry.txt" "pid:[999]" >/dev/null 2>&1; then
    fail "un registro de otro namespace se acepto: la evidencia contradictoria debe fallar"
  else
    pass "un registro de otro namespace se rechaza como evidencia contradictoria"
  fi
}

# ---------------------------------------------------------------------------
# 8. The signal is bound to an identity and to nothing else.
# ---------------------------------------------------------------------------
test_signal_is_bound_to_the_identity() {
  local out rc=0
  out="$(python3 - "$FORGE_OWN_SIGNAL_PY" <<'PY'
import errno
import importlib.util
import io
import os
import signal
import sys
import contextlib

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("forge_own_signal", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


NAMESPACE = "pid:[999999]"
OWNER_PID = 4242
OWNER_TICKS = "111"


def run(ticks_sequence, pidfd_error=None, pidfd=False, namespace=NAMESPACE,
        owner=OWNER_PID, owner_ticks=OWNER_TICKS, owner_live_ticks=None,
        ancestors=None, protected=None, target_namespace=NAMESPACE):
    """Runs the signalling with SIMULATED kernel operations."""
    state = {"index": 0, "kills": [], "pidfd_signals": []}
    values = list(ticks_sequence)

    def fake_ticks(target):
        if target == owner:
            return owner_live_ticks if owner_live_ticks is not None else owner_ticks
        if not values:
            return None
        value = values[min(state["index"], len(values) - 1)]
        state["index"] += 1
        return value

    def fake_namespace(target):
        if target == os.getpid():
            return namespace
        return target_namespace

    def fake_ancestors(_target):
        if ancestors is None:
            return [owner]
        return ancestors

    def fake_kill(pid, signum):
        state["kills"].append((pid, signum))

    def fake_killpg(pgid, signum):
        state["kills"].append((pgid, signum))

    def fake_raise_signal(signum):
        state["kills"].append((os.getpid(), signum))

    def fake_signal_kill(pid, signum):
        state["kills"].append((pid, signum))

    def fake_signal_killpg(pgid, signum):
        state["kills"].append((pgid, signum))

    def fake_pidfd_open(_pid, _flags):
        if pidfd_error is not None:
            raise OSError(pidfd_error, "simulated")
        # A REAL descriptor: the harness closes it, and closing a number that
        # is not a descriptor would fail for a reason of the simulation and
        # not of the harness.
        return os.open(os.devnull, os.O_RDONLY)

    def fake_pidfd_send_signal(handle, signum):
        state["pidfd_signals"].append((handle, signum))

    original_ticks = mod.ticks_of
    original_kill = os.kill
    original_killpg = os.killpg
    original_raise_signal = signal.raise_signal
    # `signal.kill` and `signal.killpg` do NOT exist in Python 3: the double
    # is installed ANYWAY, so that a mutation that reached for them finds a
    # double and never the kernel. The original is restored (or removed) at
    # the end.
    original_signal_kill = getattr(signal, "kill", None)
    original_signal_killpg = getattr(signal, "killpg", None)
    original_open = getattr(os, "pidfd_open", None)
    original_send = getattr(signal, "pidfd_send_signal", None)
    original_namespace = mod.namespace_of
    original_ancestors = mod.ancestors_of
    original_env = os.environ.get(mod.NAMESPACE_VARIABLE)
    original_protected = os.environ.get("FORGE_TEST_PROTECTED_PID")
    mod.ticks_of = fake_ticks
    mod.namespace_of = fake_namespace
    mod.ancestors_of = fake_ancestors
    # EVERY way of signalling is a double: not only os.kill and the pidfd
    # route, but also the group and the module-level variants. A mutation
    # that reached for any of them would find a double, never the kernel.
    os.kill = fake_kill
    os.killpg = fake_killpg
    signal.raise_signal = fake_raise_signal
    signal.kill = fake_signal_kill
    signal.killpg = fake_signal_killpg
    if namespace:
        os.environ[mod.NAMESPACE_VARIABLE] = namespace
    else:
        os.environ.pop(mod.NAMESPACE_VARIABLE, None)
    if protected is not None:
        os.environ["FORGE_TEST_PROTECTED_PID"] = protected
    else:
        os.environ.pop("FORGE_TEST_PROTECTED_PID", None)
    if pidfd:
        os.pidfd_open = fake_pidfd_open
        signal.pidfd_send_signal = fake_pidfd_send_signal
    else:
        if original_open is not None:
            del os.pidfd_open
        if original_send is not None:
            del signal.pidfd_send_signal

    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            code = mod.main([
                "forge_own_signal.py", "1234", "1000", "TERM",
                str(owner), owner_ticks,
            ])
    finally:
        mod.ticks_of = original_ticks
        mod.namespace_of = original_namespace
        mod.ancestors_of = original_ancestors
        os.kill = original_kill
        os.killpg = original_killpg
        signal.raise_signal = original_raise_signal
        if original_signal_kill is None:
            del signal.kill
        else:
            signal.kill = original_signal_kill
        if original_signal_killpg is None:
            del signal.killpg
        else:
            signal.killpg = original_signal_killpg
        if original_open is not None:
            os.pidfd_open = original_open
        if original_send is not None:
            signal.pidfd_send_signal = original_send
        if original_env is None:
            os.environ.pop(mod.NAMESPACE_VARIABLE, None)
        else:
            os.environ[mod.NAMESPACE_VARIABLE] = original_env
        if original_protected is None:
            os.environ.pop("FORGE_TEST_PROTECTED_PID", None)
        else:
            os.environ["FORGE_TEST_PROTECTED_PID"] = original_protected

    return code, buffer.getvalue().strip(), state


# 8a) The pidfd cannot be opened for a reason that is NOT "the process is
#     gone" AND the identity changes while that happens: NOTHING may be
#     signalled and the status must be "identity-mismatch" (3).
code, out, state = run(["1000", "2000"], pidfd_error=errno.EPERM, pidfd=True)
check(code == 3, "8a: se esperaba 3 (identity-mismatch) y se obtuvo %s" % code)
check(out == "identity-mismatch", "8a: se esperaba identity-mismatch y se obtuvo %r" % out)
check(not state["kills"], "8a: se señalo a un numero cuya identidad habia cambiado")
check(not state["pidfd_signals"], "8a: se señalo por pidfd sin verificar la identidad")

# 8b) The same failure of the pidfd, but the identity does NOT change: the
#     signal goes to the number and the mechanism reported must be the WEAK
#     one ("starttime-recheck-only"), never "pidfd".
code, out, state = run(["1000", "1000"], pidfd_error=errno.EPERM, pidfd=True)
check(code == 0, "8b: se esperaba 0 y se obtuvo %s" % code)
check(out == mod.MECHANISM_RECHECK_ONLY,
      "8b: el mecanismo debe ser la re-verificacion, no el pidfd (obtenido %r)" % out)
check(out != mod.MECHANISM_PIDFD, "8b: el fallback no puede atribuirse la garantia del pidfd")
check(len(state["kills"]) == 1, "8b: la senal no llego al numero")
check(not state["pidfd_signals"], "8b: no habia pidfd, no debe usarse")

# 8c) The kernel does not offer the pidfd at all AND the identity changes:
#     NOTHING may be signalled.
code, out, state = run(["1000", "2000"], pidfd=False)
check(code == 3, "8c: se esperaba 3 (identity-mismatch) y se obtuvo %s" % code)
check(not state["kills"], "8c: se señalo a un numero cuya identidad habia cambiado")

# 8d) The kernel does not offer the pidfd and the identity does not change:
#     the signal reaches the number and the mechanism is the weak one.
code, out, state = run(["1000", "1000"], pidfd=False)
check(code == 0, "8d: se esperaba 0 y se obtuvo %s" % code)
check(out == mod.MECHANISM_RECHECK_ONLY, "8d: mecanismo inesperado %r" % out)
check(len(state["kills"]) == 1, "8d: la senal no llego al numero")

# 8e) With the pidfd the signal goes THROUGH it and the mechanism says so.
code, out, state = run(["1000", "1000"], pidfd=True)
check(code == 0, "8e: se esperaba 0 y se obtuvo %s" % code)
check(out == mod.MECHANISM_PIDFD, "8e: mecanismo inesperado %r" % out)
check(len(state["pidfd_signals"]) == 1, "8e: la senal no fue por pidfd")
check(not state["kills"], "8e: con pidfd no se señalo por numero")

# 8f) The process is gone: nothing is signalled.
code, out, state = run([None], pidfd=True)
check(code == 2, "8f: se esperaba 2 (gone) y se obtuvo %s" % code)
check(not state["kills"], "8f: se señalo a un proceso inexistente")

# 8g) The identity does not match from the beginning: nothing is signalled.
code, out, state = run(["9999"], pidfd=True)
check(code == 3, "8g: se esperaba 3 (identity-mismatch) y se obtuvo %s" % code)
check(not state["kills"], "8g: se señalo a una identidad distinta")
check(not state["pidfd_signals"], "8g: se señalo por pidfd una identidad distinta")

# 8h) The PROTECTED PID is refused: NOT even a matching identity authorises
#     a signal.
code, out, state = run(["1000"], pidfd=True, protected="1234")
check(code == 5, "8h: se esperaba 5 (refused) y se obtuvo %s" % code)
check(out == "refused-protected-pid", "8h: motivo inesperado %r" % out)
check(not state["kills"], "8h: se señalo al PID protegido")
check(not state["pidfd_signals"], "8h: se señalo por pidfd al PID protegido")

# 8i) Without an ACCREDITED containment (the namespace that the entry
#     published is absent) NOTHING is signalled.
code, out, state = run(["1000"], pidfd=True, namespace="")
check(code == 5, "8i: se esperaba 5 (refused) y se obtuvo %s" % code)
check(out == "refused-not-accredited", "8i: motivo inesperado %r" % out)
check(not state["kills"], "8i: se señalo sin contencion acreditada")
check(not state["pidfd_signals"], "8i: se señalo por pidfd sin contencion acreditada")

# 8j) A target that is in ANOTHER namespace is refused: the signal never
#     leaves the accredited containment.
code, out, state = run(["1000"], pidfd=True, target_namespace="pid:[888888]")
check(code == 5, "8j: se esperaba 5 (refused) y se obtuvo %s" % code)
check(out == "refused-not-contained", "8j: motivo inesperado %r" % out)
check(not state["kills"], "8j: se señalo a un objetivo de otro namespace")
check(not state["pidfd_signals"], "8j: se señalo por pidfd a un objetivo de otro namespace")

# 8k) An identity that does NOT descend from the owner is refused: the
#     identity check alone is NOT a proof of ownership.
code, out, state = run(["1000"], pidfd=True, ancestors=[777, 888])
check(code == 5, "8k: se esperaba 5 (refused) y se obtuvo %s" % code)
check(out == "refused-not-own", "8k: motivo inesperado %r" % out)
check(not state["kills"], "8k: se señalo a una identidad que no es propia")
check(not state["pidfd_signals"], "8k: se señalo por pidfd a una identidad que no es propia")

# 8l) An owner whose identity does not match the declared one is refused.
code, out, state = run(["1000"], pidfd=True, owner_ticks="999", owner_live_ticks="111")
check(code == 5, "8l: se esperaba 5 (refused) y se obtuvo %s" % code)
check(out == "refused-not-own", "8l: motivo inesperado %r" % out)
check(not state["kills"], "8l: se señalo con un propietario que no es el declarado")

for message in failures:
    sys.stdout.write("FAIL %s\n" % message)
sys.exit(1 if failures else 0)
PY
)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "la senal esta vinculada a la identidad, al namespace acreditado y a la procedencia propia: el fallback re-verifica antes de senalar y no se atribuye la garantia del pidfd"
  else
    fail "la senal NO esta vinculada a la identidad en alguna de sus ramas"
    printf '%s\n' "$out" | sed -n '1,20p' | sed 's/^/      /' >&2
  fi
}
# ---------------------------------------------------------------------------
# 8.bis. The killer of the containment refuses the PROTECTED pid and the
#         identities that are not own.
#
# The identity alone does not authorise a signal: the killer verifies the
# namespace of the registry, the identity of the owner of the containment and
# the provenance of the target (it must descend from that owner), and it
# refuses the protected pid outright.
# ---------------------------------------------------------------------------
test_the_killer_refuses_the_protected_pid_and_the_non_own() {
  local helper_dir work pointer rc=0 receipt result
  helper_dir="$WORKDIR/killer-helpers"
  work="$WORKDIR/killer-work"
  mkdir -p "$helper_dir" "$work"
  forge_write_containment_killer "$helper_dir" || {
    fail "no se pudo preparar el ayudante de terminacion"
    return
  }

  cat > "$WORKDIR/killer-scenario.sh" <<'KILLER_SCENARIO_EOF'
#!/bin/sh
killer="$1"
work="$2"
mkdir -p "$work"
sleep 30 &
protected_pid=$!
sleep 30 &
normal_pid=$!
sleep 0.3
protected_ticks="$(sed -e 's/.*) //' "/proc/$protected_pid/stat" 2>/dev/null | awk '{ print $20 }')"
normal_ticks="$(sed -e 's/.*) //' "/proc/$normal_pid/stat" 2>/dev/null | awk '{ print $20 }')"
namespace="$(readlink /proc/self/ns/pid 2>/dev/null || printf 'UNKNOWN')"
owner_ticks="$(sed -e 's/.*) //' "/proc/$$/stat" 2>/dev/null | awk '{ print $20 }')"
registry="$work/registry.txt"
{
  printf 'NAMESPACE %s\n' "$namespace"
  printf '%s %s\n' "$protected_pid" "$protected_ticks"
  printf '%s %s\n' "$normal_pid" "$normal_ticks"
} > "$registry"
# The FIRST child is the protected one for this scenario.
FORGE_TEST_PROTECTED_PID="$protected_pid" \
  /bin/sh "$killer" "$registry" TERM "$$" "$owner_ticks" >/dev/null 2>&1
sleep 0.3
protected_alive=no
[ -r "/proc/$protected_pid/stat" ] && protected_alive=yes
normal_alive=no
[ -r "/proc/$normal_pid/stat" ] && normal_alive=yes
{
  printf 'PROTECTED_ALIVE=%s\n' "$protected_alive"
  printf 'NORMAL_ALIVE=%s\n' "$normal_alive"
} > "$work/result.txt"
# The scenario cleans up its own children.
kill -TERM "$protected_pid" 2>/dev/null || true
kill -TERM "$normal_pid" 2>/dev/null || true
if [ -n "${FORGE_PRODUCT_CLEANUP_RESULT_FILE:-}" ]; then
  printf 'PASS\n' > "$FORGE_PRODUCT_CLEANUP_RESULT_FILE"
fi
exit 0
KILLER_SCENARIO_EOF
  chmod +x "$WORKDIR/killer-scenario.sh"

  pointer="$WORKDIR/pointer-killer.txt"
  rm -f "$pointer"
  env FORGE_CONTAINED_RUN_SCENARIO_PATH="/usr/bin:/bin" \
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 30 \
      --close-timeout 3 \
      -- /bin/sh "$WORKDIR/killer-scenario.sh" \
         "$helper_dir/forge-containment-killer.sh" "$work" \
    >"$WORKDIR/out-killer.txt" 2>"$WORKDIR/err-killer.txt" || rc=$?

  receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la corrida contenida del escenario del killer no dejo recibo (rc=$rc)"
    return
  fi

  if [ ! -s "$work/result.txt" ]; then
    fail "el escenario del killer no publico su resultado"
    return
  fi

  result="$(sed -n 's/^PROTECTED_ALIVE=//p' "$work/result.txt" | head -n 1)"
  if [ "$result" = "yes" ]; then
    pass "el killer NO señalo al PID protegido: la identidad no autoriza una senal"
  else
    fail "el killer señalo al PID protegido (resultado='$result')"
  fi

  result="$(sed -n 's/^NORMAL_ALIVE=//p' "$work/result.txt" | head -n 1)"
  if [ "$result" = "no" ]; then
    pass "el killer SI termina las identidades propias del registro"
  else
    fail "el killer no termino una identidad propia del registro (resultado='$result')"
  fi
}

# ---------------------------------------------------------------------------
# 9. The consumers of the entry cannot run a scenario outside it.
# ---------------------------------------------------------------------------
test_a_consumer_cannot_run_outside_the_containment() {
  # Without the evidence of the capacity of this machine, the entry is not
  # available and the consumer fails: there is no fallback to the host.
  local saved_capability="${FORGE_CONTAINMENT_CAPABILITY_FILE}"
  FORGE_CONTAINMENT_CAPABILITY_FILE="$WORKDIR/no-capability.txt"
  if forge_containment_available; then
    fail "la contencion se declaro disponible sin evidencia de capacidad"
  else
    pass "sin evidencia de capacidad la contencion no esta disponible: no hay degradacion al host"
  fi
  FORGE_CONTAINMENT_CAPABILITY_FILE="$saved_capability"

  # A scenario that does not exist is refused before any work.
  local rc=0
  forge_contained_run "$WORKDIR/absent-scenario.sh" /bin/true >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    pass "un escenario inexistente se rechaza antes de ejecutar nada (rc=$rc)"
  else
    fail "un escenario inexistente no se rechazo"
  fi
}

# ---------------------------------------------------------------------------
# 10. The ACCEPTANCE CONTRACT of the entry, case by case.
#
# The cases are the six exits of the entry. Every one of them is executed
# INSIDE the frontier and leaves a receipt:
#
#   (a) normal exit      -> RC 0,   certifiable
#   (b) failure          -> the RC of the product is conserved
#   (c) interruption     -> RC 130/143, the contained environment is closed
#   (d) timeout          -> RC 124,  the contained environment is closed
#   (e) unaccredited     -> the scenario does NOT run
#   (f) detached child   -> it does not survive the closure
#
# The case (g) is not an exit of the entry but a property of its streams: the
# stderr that the consumer captures is exactly the stderr of the scenario.
#
# The result of the PRODUCT and the result of the HARNESS are kept apart in
# every case: a correct closure of the harness never converts a failure of
# the product into a PASS.
# ---------------------------------------------------------------------------

# (a) A normal exit is certifiable: the boundary was accredited, the closure
#     was confirmed and the cleanup of the product was OBSERVED before the
#     defensive cleanup.
test_a_normal_exit_is_certifiable() {
  local scenario rc=0
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  forge_contained_run "$scenario" /bin/true >/dev/null 2>&1 || rc=$?
  rm -f "$scenario"

  local receipt="$FORGE_CONTAINMENT_LAST_RECEIPT"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "no hay recibo de la corrida normal"
    return
  fi
  if [ "$rc" -eq 0 ]; then
    pass "una salida normal devuelve RC 0"
  else
    fail "una salida normal deberia devolver RC 0 (rc=$rc)"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$(forge_receipt_read "$receipt" SCENARIO_STATUS 2>/dev/null || true)" = "COMPLETED" ] \
    && [ "$(forge_receipt_read "$receipt" ACCREDITATION 2>/dev/null || true)" = "PASS" ] \
    && [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ] \
    && [ "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "YES" ]; then
    pass "el recibo de la salida normal es COMPLETO y su evidencia de contencion es certificable"
  else
    fail "el recibo de la salida normal no es completo ni su evidencia de contencion es certificable"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$(forge_receipt_product_cleanup "$receipt")" = "PASS" ]; then
    pass "la limpieza del producto fue OBSERVADA antes de la limpieza defensiva"
  else
    fail "la limpieza del producto no fue observada antes de la defensiva"
  fi
  if [ "$(forge_receipt_read "$receipt" EXPECTED_SCENARIO_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$receipt" SCENARIO_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || true)" = "YES" ] \
    && forge_receipt_require "$receipt" >/dev/null 2>&1; then
    pass "la salida normal tiene ACCEPTACION POSITIVA: RC esperado, RC observado y limpieza del producto"
  else
    fail "la salida normal deberia tener aceptacion positiva"
    forge_receipt_summary "$receipt" >&2 || true
  fi
}

# (g) The stderr that the CONSUMER captures is EXACTLY the stderr of the
#     scenario.
#
# The entry reserves its standard output and its standard error for the
# scenario: its own diagnosis travels in the FIELDS of the receipt
# (CONTAINMENT_EVIDENCE_CERTIFIABLE, POSITIVE_ACCEPTANCE) and never on the
# streams that the consumer captures. A consumer that captures the stderr must
# get the stderr of the scenario and NOTHING else.
#
# The check is EXPLICIT, not implicit: the captured stderr is compared, line
# by line, with the exact text the scenario wrote, and the ABSENCE of the
# diagnosis of the entry and of the fields of the receipt is verified
# separately. There is no filter in the consumer that could hide a noise: the
# consumer forwards the stderr of the entry verbatim.
test_the_captured_stderr_is_only_the_stderr_of_the_scenario() {
  local scenario rc=0
  local marker="SCENARIO_STDERR_ONLY_9f3c1a"
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }

  local err_file="$WORKDIR/captured-stderr.txt"
  local out_file="$WORKDIR/captured-stdout.txt"
  rm -f "$err_file" "$out_file"

  forge_contained_run "$scenario" /bin/sh -c \
    "printf '%s\\n' '$marker' >&2; printf 'SCENARIO_STDOUT_ONLY\\n'" \
    > "$out_file" 2> "$err_file" || rc=$?
  rm -f "$scenario"

  if [ "$rc" -ne 0 ]; then
    fail "la corrida de la comprobacion del stderr devolvio RC $rc"
    return
  fi

  # 1. The captured stderr is EXACTLY the stderr of the scenario.
  local captured expected="$marker"
  captured="$(cat "$err_file" 2>/dev/null || true)"
  if [ "$captured" = "$expected" ]; then
    pass "el stderr capturado es EXACTAMENTE el stderr del escenario"
  else
    fail "el stderr capturado NO es el stderr del escenario"
    printf '      esperado: [%s]\n' "$expected" >&2
    printf '      capturado: [%s]\n' "$captured" >&2
  fi

  # 2. No diagnosis of the entry and no field of the receipt leaks into the
  #    stderr that the consumer captures.
  local leaked="" token
  for token in CONTAINMENT_EVIDENCE_CERTIFIABLE POSITIVE_ACCEPTANCE \
    RECEIPT_PATH SCENARIO_ORDER_LITERAL IDENTIFIER SCENARIO_STATUS; do
    if grep -q "$token" "$err_file" 2>/dev/null; then
      leaked="$leaked $token"
    fi
  done
  if [ -z "$leaked" ]; then
    pass "el stderr capturado NO contiene diagnostico de la entrada ni campos del recibo"
  else
    fail "el stderr capturado contiene:$leaked"
  fi

  # 3. The stdout of the scenario is not polluted either.
  if grep -qx 'SCENARIO_STDOUT_ONLY' "$out_file" 2>/dev/null \
    && ! grep -q 'RECEIPT_PATH\|IDENTIFIER=' "$out_file" 2>/dev/null; then
    pass "el stdout capturado es el stdout del escenario y no el recibo"
  else
    fail "el stdout capturado esta contaminado"
    printf '      stdout capturado: [%s]\n' "$(cat "$out_file" 2>/dev/null || true)" >&2
  fi
}

# (b) A failure of the product keeps ITS OWN RC: the defensive cleanup of the
#     containment does not turn it into a success.
test_a_failure_keeps_its_own_rc() {
  local scenario rc=0
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  forge_contained_run "$scenario" /bin/sh -c 'exit 42' >/dev/null 2>&1 || rc=$?
  rm -f "$scenario"

  local receipt="$FORGE_CONTAINMENT_LAST_RECEIPT"
  if [ "$rc" -eq 42 ]; then
    pass "el RC del fallo del producto se conserva (42)"
  else
    fail "el RC del fallo del producto NO se conserva (rc=$rc)"
  fi
  if [ "$(forge_receipt_read "$receipt" SCENARIO_STATUS 2>/dev/null || true)" = "FAILED" ] \
    && [ "$(forge_receipt_read "$receipt" SCENARIO_RC 2>/dev/null || true)" = "42" ]; then
    pass "el recibo registra el estado FAILED y el RC 42 del escenario"
  else
    fail "el recibo no registra FAILED/42"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ]; then
    pass "el cierre del arnes se confirma aunque el producto falle"
  else
    fail "el cierre del arnes no se confirma tras un fallo del producto"
  fi
  if [ "$(forge_receipt_product_cleanup "$receipt")" = "PASS" ]; then
    pass "el fallo del ESCENARIO no se confunde con un fallo de la limpieza del producto"
  else
    fail "la limpieza del producto deberia ser PASS en un fallo de codigo del escenario"
  fi
  if [ "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$receipt" EXPECTED_SCENARIO_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || true)" = "NO" ]; then
    pass "un RC que no es el esperado NO da aceptacion positiva: la contencion sigue certificable"
  else
    fail "un RC que no es el esperado no deberia dar aceptacion positiva"
    forge_receipt_summary "$receipt" >&2 || true
  fi
}

# (c) An interruption of the outer process closes the contained environment.
#     The signal is sent to the DIRECT CHILD of this suite: no process of the
#     host is searched, named or signalled.
test_an_interruption_closes_the_contained_environment() {
  local signame expected_rc
  for signame in TERM INT HUP; do
    case "$signame" in
      TERM) expected_rc=143 ;;
      INT) expected_rc=130 ;;
      HUP) expected_rc=129 ;;
    esac

    local hb="$WORKDIR/hb-$signame.txt"
    local ready="$WORKDIR/ready-$signame.txt"
    local pointer="$WORKDIR/ptr-$signame.txt"
    rm -f "$hb" "$ready" "$pointer"
    write_heartbeat_scenario "$WORKDIR/heartbeat.sh"

    # JOB CONTROL is enabled for the launch: without it, a non-interactive
    # shell starts its asynchronous commands with SIGINT and SIGQUIT IGNORED,
    # and a signal that was ignored on entry cannot be trapped by the entry.
    #
    # NO auxiliary launcher is used any more. The entry restores the DEFAULT
    # disposition of INT, TERM and HUP BY ITSELF when it starts (it re-execs
    # through `env --default-signal=INT --default-signal=TERM
    # --default-signal=HUP`), so the interruption is delivered
    # DETERMINISTICALLY whatever the disposition the caller had. The launcher
    # that used to restore SIG_DFL here (a python wrapper that pre-empted the
    # fix) was removed when the entry was fixed at the root: the guarantee
    # belongs to the entry, not to the test.
    #
    # The signal is sent to the DIRECT CHILD of this suite: no process of the
    # host is searched, named or signalled.
    set -m
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 60 \
      --close-timeout 3 \
      -- /bin/sh "$WORKDIR/heartbeat.sh" "$hb" "$ready" \
      >"$WORKDIR/out-$signame.txt" 2>"$WORKDIR/err-$signame.txt" &
    local entry_pid=$!
    set +m

    local waited=0
    while [ ! -s "$ready" ] && [ "$waited" -lt 300 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    if [ ! -s "$ready" ]; then
      fail "el escenario de la interrupcion ($signame) no llego a announce que estaba listo"
      kill -KILL "$entry_pid" 2>/dev/null || true
      wait "$entry_pid" 2>/dev/null || true
      continue
    fi

    kill -"$signame" "$entry_pid" 2>/dev/null || true
    local rc=0
    wait "$entry_pid" || rc=$?

    if [ "$rc" -eq "$expected_rc" ]; then
      pass "una interrupcion $signame devuelve RC $expected_rc"
    else
      fail "una interrupcion $signame deberia devolver RC $expected_rc (rc=$rc)"
    fi

    local receipt=""
    [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
    if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
      fail "la interrupcion $signame no dejo recibo"
      continue
    fi
    if [ "$(forge_receipt_read "$receipt" SCENARIO_STATUS 2>/dev/null || true)" = "INTERRUPTED" ] \
      && [ "$(forge_receipt_read "$receipt" INTERRUPTION_CAUSE 2>/dev/null || true)" = "SIG$signame" ]; then
      pass "el recibo registra la interrupcion SIG$signame"
    else
      fail "el recibo no registra la interrupcion SIG$signame"
      forge_receipt_summary "$receipt" >&2 || true
    fi
    if [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ] \
      && [ "$(forge_receipt_read "$receipt" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "YES" ] \
      && [ "$(forge_receipt_read "$receipt" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
      && [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ]; then
      pass "el cierre se CONFIRMA despues de la interrupcion: el entorno contenido fue esperado"
    else
      fail "el cierre no se confirma tras la interrupcion"
      forge_receipt_summary "$receipt" >&2 || true
    fi
    if heartbeat_is_frozen "$hb" 2; then
      pass "el entorno contenido TERMINO DE VERDAD tras la interrupcion ($signame)"
    else
      fail "el entorno contenido SIGUE VIVO tras la interrupcion ($signame)"
    fi
  done
}

# (d) A timeout closes the contained environment and is visible.
test_a_timeout_closes_the_contained_environment() {
  local hb="$WORKDIR/hb-timeout.txt"
  local ready="$WORKDIR/ready-timeout.txt"
  local pointer="$WORKDIR/ptr-timeout.txt"
  rm -f "$hb" "$ready" "$pointer"
  write_heartbeat_scenario "$WORKDIR/heartbeat.sh"

  local rc=0
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$pointer" \
    --scenario-timeout 2 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/heartbeat.sh" "$hb" "$ready" \
    >"$WORKDIR/out-timeout.txt" 2>"$WORKDIR/err-timeout.txt" || rc=$?

  if [ "$rc" -eq 124 ]; then
    pass "un timeout devuelve RC 124"
  else
    fail "un timeout deberia devolver RC 124 (rc=$rc)"
  fi

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "el timeout no dejo recibo"
    return
  fi
  if [ "$(forge_receipt_read "$receipt" SCENARIO_STATUS 2>/dev/null || true)" = "TIMEOUT" ] \
    && [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ]; then
    pass "el recibo registra TIMEOUT con el cierre confirmado"
  else
    fail "el recibo no registra TIMEOUT con el cierre confirmado"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if heartbeat_is_frozen "$hb" 2; then
    pass "el entorno contenido TERMINO DE VERDAD tras el timeout"
  else
    fail "el entorno contenido SIGUE VIVO tras el timeout"
  fi
}

# (h) A closure that is NOT confirmed does NOT certify and CONSERVES the
#     context.
#
# The closure has THREE independent links: the outer wait over the direct
# `unshare` child, its RC 0 and the OBSERVED effective termination of the
# private PID 1. When one of them is missing the closure is UNCONFIRMED: the
# evidence is NOT certifiable and the context of the run is CONSERVED, because
# it is the evidence of a closure that could not be proven. Nothing is deleted
# to make a failed run look clean.
#
# The link that is broken here is the OBSERVATION of the termination of PID 1:
# the copy of the entry never writes the final marker of PID 1. The copy
# lives OUTSIDE the repository: the repository is never modified.
test_an_unconfirmed_closure_is_not_certified_and_preserves_the_context() {
  local copy="$WORKDIR/entry-without-pid1-completion.sh"
  if ! patch_entry_copy "$ENTRY" "$copy" "no-pid1-completion"; then
    fail "no se pudo preparar la copia sin la observacion de la terminacion del PID 1"
    return
  fi
  if cmp -s "$ENTRY" "$copy"; then
    fail "la copia sin la observacion de la terminacion del PID 1 es IDENTICA a la entrada: el parche no se aplico"
    return
  fi

  local pointer="$WORKDIR/ptr-unconfirmed.txt"
  rm -f "$pointer"
  local rc=0
  bash "$copy" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$pointer" \
    --scenario-timeout 20 \
    --close-timeout 3 \
    -- /bin/true \
    >"$WORKDIR/out-unconfirmed.txt" 2>"$WORKDIR/err-unconfirmed.txt" || rc=$?

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la corrida sin cierre confirmado no dejo recibo: la evidencia no puede faltar"
    return
  fi

  if [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "UNCONFIRMED" ]; then
    pass "sin la observacion de la terminacion del PID 1 el cierre NO se confirma"
  else
    fail "el cierre se confirmo SIN observar la terminacion efectiva del PID 1"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "NO" ]; then
    pass "el recibo registra PID1_COMPLETION_OBSERVED=NO cuando el marcador de PID 1 no existe"
  else
    fail "el recibo no registra PID1_COMPLETION_OBSERVED=NO"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if [ "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "NO" ] \
    && [ "$(forge_receipt_read "$receipt" RECEIPT_COMPLETENESS 2>/dev/null || true)" = "INCOMPLETE" ] \
    && [ "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || true)" = "NO" ]; then
    pass "un cierre NO confirmado NO certifica la evidencia de contencion ni la aceptacion positiva"
  else
    fail "un cierre NO confirmado certifico la evidencia de contencion"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if forge_receipt_containment_evidence "$receipt" >/dev/null 2>&1; then
    fail "el consumidor acepto un recibo con el cierre sin confirmar"
  else
    pass "el consumidor RECHAZA un recibo con el cierre sin confirmar"
  fi

  if [ "$rc" -ne 0 ]; then
    pass "una corrida con el cierre sin confirmar NO devuelve un exito (rc=$rc)"
  else
    fail "una corrida con el cierre sin confirmar devolvio 0"
  fi

  # The CONTEXT is CONSERVED: it is the evidence of a closure that could not
  # be proven and it is never deleted to make the run look clean.
  local home_temp context_present
  home_temp="$(forge_receipt_read "$receipt" HOME_TEMP 2>/dev/null || true)"
  context_present="$(forge_receipt_read "$receipt" CONTEXT_PRESENT_AFTER 2>/dev/null || true)"
  if [ "$context_present" = "YES" ] && [ -n "$home_temp" ] && [ -d "$home_temp" ]; then
    pass "un cierre NO confirmado CONSERVA el contexto de la corrida (no se borra para aparentar exito)"
  else
    fail "un cierre NO confirmado BORRO el contexto de la corrida (context_present_after=$context_present)"
  fi

  if [ "$(forge_receipt_read "$receipt" DEFENSIVE_CLEANUP 2>/dev/null || true)" = "UNKNOWN" ]; then
    pass "la limpieza defensiva es UNKNOWN cuando el cierre no esta confirmado"
  else
    fail "la limpieza defensiva no es UNKNOWN con el cierre sin confirmar"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  # The SAME copy, but INTERRUPTED: a signal that was SENT is not an
  # observed termination either. The closure of an interrupted run can only
  # be CONFIRMED when the effective termination of PID 1 was OBSERVED.
  local ipointer="$WORKDIR/ptr-unconfirmed-interrupted.txt"
  local iready="$WORKDIR/ready-unconfirmed-interrupted.txt"
  rm -f "$ipointer" "$iready"
  write_heartbeat_scenario "$WORKDIR/heartbeat.sh"

  set -m
  bash "$copy" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$ipointer" \
    --scenario-timeout 60 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/heartbeat.sh" "$WORKDIR/hb-unconfirmed-interrupted.txt" "$iready" \
    >"$WORKDIR/out-unconfirmed-interrupted.txt" 2>"$WORKDIR/err-unconfirmed-interrupted.txt" &
  local irc=0
  local ipid=$!
  set +m

  local iwaited=0
  while [ ! -s "$iready" ] && [ "$iwaited" -lt 300 ]; do
    sleep 0.05
    iwaited=$((iwaited + 1))
  done
  if [ ! -s "$iready" ]; then
    fail "el escenario de la interrupcion sin cierre confirmado no llego a announce que estaba listo"
    kill -KILL "$ipid" 2>/dev/null || true
    wait "$ipid" 2>/dev/null || true
    return
  fi

  kill -TERM "$ipid" 2>/dev/null || true
  wait "$ipid" || irc=$?

  local ireceipt=""
  [ -s "$ipointer" ] && IFS= read -r ireceipt < "$ipointer"
  if [ -z "$ireceipt" ] || [ ! -s "$ireceipt" ]; then
    fail "la interrupcion sin cierre confirmado no dejo recibo: la evidencia no puede faltar"
    return
  fi

  if [ "$(forge_receipt_read "$ireceipt" INTERRUPTION_CAUSE 2>/dev/null || true)" = "SIGTERM" ] \
    && [ "$(forge_receipt_read "$ireceipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "NO" ] \
    && [ "$(forge_receipt_read "$ireceipt" CLOSURE 2>/dev/null || true)" = "UNCONFIRMED" ]; then
    pass "una senal ENVIADA no certifica el cierre: la terminacion del PID 1 no quedo observada"
  else
    fail "una senal enviada certifico el cierre sin observar la terminacion del PID 1"
    forge_receipt_summary "$ireceipt" >&2 || true
  fi

  if [ "$(forge_receipt_read "$ireceipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "NO" ] \
    && [ "$(forge_receipt_read "$ireceipt" RECEIPT_COMPLETENESS 2>/dev/null || true)" = "INCOMPLETE" ]; then
    pass "una interrupcion con el cierre NO confirmado NO certifica la evidencia de contencion"
  else
    fail "una interrupcion con el cierre NO confirmado certifico la evidencia de contencion"
    forge_receipt_summary "$ireceipt" >&2 || true
  fi

  if [ "$irc" -ne 0 ]; then
    pass "una interrupcion con el cierre sin confirmar NO devuelve un exito (rc=$irc)"
  else
    fail "una interrupcion con el cierre sin confirmar devolvio 0"
  fi
}

# ---------------------------------------------------------------------------
# (i-bis) The status of the launcher is NOT RECOVERABLE.
#
# The `trap` of the outer shell interrupts the `wait` of the launcher and
# bash returns 128+signal, which is NOT the status of the launcher. The
# entry recovers the real status with a SECOND `wait`. When that second
# `wait` yields 127 (bash: "the child is no longer waitable") the status of
# the launcher is NOT RECOVERABLE, and the entry must NOT certify anything:
#
#   * LAUNCHER_RC=NOT_RECOVERABLE and LAUNCHER_WAIT_COMPLETED=NO,
#   * CLOSURE=UNCONFIRMED,
#   * RECEIPT_COMPLETENESS=INCOMPLETE,
#   * CONTAINMENT_EVIDENCE_CERTIFIABLE=NO and POSITIVE_ACCEPTANCE=NO,
#   * the receipt EXISTS (the evidence of a run that could not be closed is
#     never deleted) and the context is CONSERVED.
#
# The status of the launcher is UNKNOWN, so the closure cannot be CONFIRMED:
# certifying it would be certifying a termination that nobody observed.
#
# The fixture forces the branch of the recovery and the 127 of the second
# `wait` on a COPY of the entry (the repository is never modified). The
# `wait` itself is kept, so the launcher is reaped and the contained
# environment does NOT survive this fixture.
# ---------------------------------------------------------------------------
test_an_unrecoverable_launcher_status_is_not_certified() {
  local copy="$WORKDIR/entry-launcher-not-recoverable.sh"
  if ! patch_entry_copy "$ENTRY" "$copy" "launcher-not-recoverable"; then
    fail "no se pudo preparar la copia con el estado del lanzador no recuperable"
    return
  fi
  if cmp -s "$ENTRY" "$copy"; then
    fail "la copia con el estado no recuperable es IDENTICA a la entrada: el parche no se aplico"
    return
  fi

  local hb="$WORKDIR/hb-not-recoverable.txt"
  local ready="$WORKDIR/ready-not-recoverable.txt"
  local pointer="$WORKDIR/ptr-not-recoverable.txt"
  rm -f "$hb" "$ready" "$pointer"
  write_heartbeat_scenario "$WORKDIR/heartbeat.sh"

  set -m
  bash "$copy" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$pointer" \
    --scenario-timeout 60 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/heartbeat.sh" "$hb" "$ready" \
    >"$WORKDIR/out-not-recoverable.txt" 2>"$WORKDIR/err-not-recoverable.txt" &
  local entry_pid=$!
  set +m

  local waited=0
  while [ ! -s "$ready" ] && [ "$waited" -lt 300 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ ! -s "$ready" ]; then
    fail "el escenario del lanzador no recuperable no llego a announce que estaba listo"
    kill -KILL "$entry_pid" 2>/dev/null || true
    wait "$entry_pid" 2>/dev/null || true
    return
  fi

  kill -TERM "$entry_pid" 2>/dev/null || true
  local rc=0
  wait "$entry_pid" || rc=$?

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "el estado del lanzador no recuperable no dejo recibo: la evidencia no puede faltar"
    return
  fi
  pass "el estado del lanzador no recuperable deja recibo: la evidencia de una corrida no cerrada se conserva"

  if [ "$(forge_receipt_read "$receipt" LAUNCHER_RC 2>/dev/null || true)" = "NOT_RECOVERABLE" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "NO" ]; then
    pass "un estado del lanzador NO recuperable se registra como tal (LAUNCHER_RC=NOT_RECOVERABLE, LAUNCHER_WAIT_COMPLETED=NO)"
  else
    fail "el estado NO recuperable del lanzador no quedo registrado como tal"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "UNCONFIRMED" ]; then
    pass "un estado del lanzador NO recuperable deja el cierre UNCONFIRMED: no se certifica una terminacion no observada"
  else
    fail "un estado del lanzador NO recuperable CONFIRMO el cierre"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if [ "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "NO" ] \
    && [ "$(forge_receipt_read "$receipt" RECEIPT_COMPLETENESS 2>/dev/null || true)" = "INCOMPLETE" ] \
    && [ "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || true)" = "NO" ]; then
    pass "un estado del lanzador NO recuperable NO certifica la evidencia ni la aceptacion positiva"
  else
    fail "un estado del lanzador NO recuperable certifico la evidencia"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if forge_receipt_containment_evidence "$receipt" >/dev/null 2>&1; then
    fail "el consumidor acepto un recibo con el estado del lanzador no recuperable"
  else
    pass "el consumidor RECHAZA un recibo con el estado del lanzador no recuperable"
  fi

  if forge_receipt_positive_acceptance "$receipt" >/dev/null 2>&1; then
    fail "el consumidor acepto la aceptacion positiva de un recibo con el estado no recuperable"
  else
    pass "el consumidor RECHAZA la aceptacion positiva de un recibo con el estado no recuperable"
  fi

  if [ "$rc" -ne 0 ]; then
    pass "una corrida con el estado del lanzador no recuperable NO devuelve un exito (rc=$rc)"
  else
    fail "una corrida con el estado del lanzador no recuperable devolvio 0"
  fi

  # The CONTEXT is CONSERVED: a closure that could not be proven keeps its
  # evidence, it is never deleted to make the run look clean.
  local context_present
  context_present="$(forge_receipt_read "$receipt" CONTEXT_PRESENT_AFTER 2>/dev/null || true)"
  if [ "$context_present" = "YES" ]; then
    pass "un cierre NO confirmado CONSERVA el contexto de la corrida (no se borra para aparentar exito)"
  else
    fail "un cierre NO confirmado borro el contexto de la corrida (context_present_after=$context_present)"
  fi

  # The contained environment does NOT survive this fixture either.
  if heartbeat_is_frozen "$hb" 2; then
    pass "el entorno contenido TERMINO DE VERDAD con el estado del lanzador no recuperable"
  else
    fail "el entorno contenido SIGUE VIVO con el estado del lanzador no recuperable"
  fi
}

# (i) A scenario that IGNORES the TERM of the bounded close is terminated by
#     the escalation to KILL, and its closure is certified ONLY because the
#     effective termination of the private PID 1 was OBSERVED.
#
# The TERM that the bounded close sends is not enough to stop a scenario that
# ignores it: only the KILL of the escalation does. The scenario is dead, and
# the certification of the closure does NOT rest on the signal that was sent:
# it rests on the completed wait, on the RC 0 of the launcher and on the
# OBSERVED completion of PID 1.
test_a_scenario_that_ignores_term_is_closed_by_kill_and_observed() {
  local hb="$WORKDIR/hb-stubborn.txt"
  local ready="$WORKDIR/ready-stubborn.txt"
  local pointer="$WORKDIR/ptr-stubborn.txt"
  rm -f "$hb" "$ready" "$pointer"
  write_term_ignoring_scenario "$WORKDIR/stubborn.sh"

  local rc=0
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$pointer" \
    --scenario-timeout 3 \
    --close-timeout 1 \
    -- /bin/sh "$WORKDIR/stubborn.sh" "$hb" "$ready" \
    >"$WORKDIR/out-stubborn.txt" 2>"$WORKDIR/err-stubborn.txt" || rc=$?

  if [ "$rc" -eq 124 ]; then
    pass "un escenario que ignora el TERM termina con RC 124 (el timeout con su gracia)"
  else
    fail "un escenario que ignora el TERM deberia terminar con RC 124 (rc=$rc)"
  fi

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la corrida del escenario que ignora el TERM no dejo recibo"
    return
  fi

  if [ "$(forge_receipt_read "$receipt" SCENARIO_STATUS 2>/dev/null || true)" = "TIMEOUT" ] \
    && [ "$(forge_receipt_read "$receipt" SCENARIO_RC 2>/dev/null || true)" = "137" ]; then
    pass "el recibo registra la escalacion a KILL del escenario que ignoraba el TERM (RC 137)"
  else
    fail "el recibo no registra la escalacion a KILL del escenario que ignoraba el TERM"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if [ "$(forge_receipt_read "$receipt" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ] \
    && [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ]; then
    pass "el cierre se confirma tras la escalacion a KILL: espera, RC 0 y terminacion observada"
  else
    fail "el cierre no se confirma tras la escalacion a KILL"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if pid1_completion_is_observed "$receipt"; then
    pass "la terminacion efectiva del PID 1 quedo OBSERVADA (el marcador existe en el directorio de la corrida)"
  else
    fail "la terminacion del PID 1 NO quedo observada: el marcador no existe"
  fi

  if heartbeat_is_frozen "$hb" 2; then
    pass "el entorno contenido TERMINO DE VERDAD tras la escalacion a KILL"
  else
    fail "el entorno contenido SIGUE VIVO tras la escalacion a KILL"
  fi
}

# (j) An interruption by SIGINT or SIGTERM certifies the closure ONLY because
#     the effective termination of the private PID 1 was OBSERVED.
#
# The entry NEVER signals the process that it has to wait for: it publishes a
# REQUEST and the bridge contained relays it to PID 1. The signal that was
# SENT is not an observed termination, so the certification rests on the
# completed wait, on the RC 0 of the launcher and on the OBSERVED completion
# of PID 1.
test_an_interruption_is_certified_only_when_the_termination_was_observed() {
  local signame expected_rc
  for signame in INT TERM; do
    case "$signame" in
      INT) expected_rc=130 ;;
      TERM) expected_rc=143 ;;
    esac

    local hb="$WORKDIR/hb-observed-$signame.txt"
    local ready="$WORKDIR/ready-observed-$signame.txt"
    local pointer="$WORKDIR/ptr-observed-$signame.txt"
    rm -f "$hb" "$ready" "$pointer"
    write_heartbeat_scenario "$WORKDIR/heartbeat.sh"

    set -m
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 60 \
      --close-timeout 3 \
      -- /bin/sh "$WORKDIR/heartbeat.sh" "$hb" "$ready" \
      >"$WORKDIR/out-observed-$signame.txt" 2>"$WORKDIR/err-observed-$signame.txt" &
    local entry_pid=$!
    set +m

    local waited=0
    while [ ! -s "$ready" ] && [ "$waited" -lt 300 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
    if [ ! -s "$ready" ]; then
      fail "el escenario de la interrupcion observada ($signame) no llego a announce que estaba listo"
      kill -KILL "$entry_pid" 2>/dev/null || true
      wait "$entry_pid" 2>/dev/null || true
      continue
    fi

    kill -"$signame" "$entry_pid" 2>/dev/null || true
    local rc=0
    wait "$entry_pid" || rc=$?

    if [ "$rc" -eq "$expected_rc" ]; then
      pass "una interrupcion SIG$signame devuelve RC $expected_rc"
    else
      fail "una interrupcion SIG$signame deberia devolver RC $expected_rc (rc=$rc)"
    fi

    local receipt=""
    [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
    if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
      fail "la interrupcion SIG$signame no dejo recibo"
      continue
    fi

    if [ "$(forge_receipt_read "$receipt" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "YES" ] \
      && [ "$(forge_receipt_read "$receipt" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
      && [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ] \
      && [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ]; then
      pass "el cierre se confirma tras la interrupcion SIG$signame: espera, RC 0 y terminacion observada"
    else
      fail "el cierre no se confirma tras la interrupcion SIG$signame"
      forge_receipt_summary "$receipt" >&2 || true
    fi

    if pid1_completion_is_observed "$receipt"; then
      pass "la terminacion efectiva del PID 1 quedo OBSERVADA tras la interrupcion SIG$signame"
    else
      fail "la terminacion del PID 1 NO quedo observada tras la interrupcion SIG$signame"
    fi

    # The entry did NOT signal the process that it has to wait for: it
    # published a REQUEST OUTSIDE the frontier and the PID 1 of the
    # namespace read it and relayed it to the bounded `timeout`.
    local run_dir request
    run_dir="$(dirname "$receipt")"
    request="$run_dir/interruption.request"
    if [ -s "$request" ] && grep -qx "SIG$signame" "$request" 2>/dev/null; then
      pass "la interrupcion se publico como una SOLICITUD en el directorio de la corrida (no como una senal directa)"
    else
      fail "la interrupcion no publico la solicitud esperada en el directorio de la corrida"
    fi

    # The interruption was OBSERVED by the PID 1: the receipt declares it and
    # the artefact that the PID 1 wrote proves it.
    if [ "$(forge_receipt_read "$receipt" INTERRUPTION_FORWARDING 2>/dev/null || true)" = "OBSERVED_BY_PID1" ]; then
      pass "la interrupcion SIG$signame quedo OBSERVADA por el PID 1 (INTERRUPTION_FORWARDING=OBSERVED_BY_PID1)"
    else
      fail "la interrupcion SIG$signame deberia quedar OBSERVADA por el PID 1"
      forge_receipt_summary "$receipt" >&2 || true
    fi

    if heartbeat_is_frozen "$hb" 2; then
      pass "el entorno contenido TERMINO DE VERDAD tras la interrupcion SIG$signame"
    else
      fail "el entorno contenido SIGUE VIVO tras la interrupcion SIG$signame"
    fi
  done
}

# (k) The stdout and the stderr that the consumer captures are EXACTLY the
#     ones of the scenario, byte by byte, WITH and WITHOUT `--receipt-out`.
#
# The receipt path travels by its own file when `--receipt-out` is given and
# by the DEDICATED descriptor 9 when it is omitted. In BOTH modes the streams
# of the consumer carry nothing but the bytes of the scenario: the diagnostic
# "Receipt: ..." does not exist any more and the result of the certification
# lives in the fields of the receipt, never on the streams.
#
# The comparison is byte by byte (`cmp`), so a single extra byte of
# diagnosis on either stream is detected.
test_the_streams_are_the_scenario_ones_with_and_without_the_receipt_out() {
  local out_with="$WORKDIR/streams-with.out"
  local err_with="$WORKDIR/streams-with.err"
  local ptr_with="$WORKDIR/streams-with.ptr"
  local out_without="$WORKDIR/streams-without.out"
  local err_without="$WORKDIR/streams-without.err"
  local ptr_without="$WORKDIR/streams-without.ptr"
  local expected_out="$WORKDIR/streams-expected.out"
  local expected_err="$WORKDIR/streams-expected.err"
  rm -f "$out_with" "$err_with" "$ptr_with" \
    "$out_without" "$err_without" "$ptr_without"

  # The SAME scenario in both modes: its bytes are deterministic.
  cat > "$WORKDIR/streams-scenario.sh" <<'STREAMS_EOF'
#!/bin/sh
printf 'STDOUT_LINE_1\nSTDOUT_LINE_2\n'
printf 'STDERR_LINE_1\nSTDERR_LINE_2\n' >&2
exit 0
STREAMS_EOF
  chmod +x "$WORKDIR/streams-scenario.sh"
  printf 'STDOUT_LINE_1\nSTDOUT_LINE_2\n' > "$expected_out"
  printf 'STDERR_LINE_1\nSTDERR_LINE_2\n' > "$expected_err"

  local rc_with=0
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$ptr_with" \
    --scenario-timeout 20 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/streams-scenario.sh" \
    >"$out_with" 2>"$err_with" || rc_with=$?

  # WITHOUT `--receipt-out` the receipt path travels by the descriptor 9: the
  # stdout and the stderr are NOT used to announce it.
  local rc_without=0
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --scenario-timeout 20 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/streams-scenario.sh" \
    9>"$ptr_without" >"$out_without" 2>"$err_without" || rc_without=$?

  local receipt_with="" receipt_without=""
  [ -s "$ptr_with" ] && IFS= read -r receipt_with < "$ptr_with"
  [ -s "$ptr_without" ] && IFS= read -r receipt_without < "$ptr_without"
  if [ -n "$receipt_with" ] && [ -s "$receipt_with" ]; then
    pass "con --receipt-out la ruta del recibo se publica por su fichero"
  else
    fail "con --receipt-out no se publico ninguna ruta de recibo utilizable"
  fi
  if [ -n "$receipt_without" ] && [ -s "$receipt_without" ]; then
    pass "sin --receipt-out la ruta del recibo se publica por el descriptor 9"
  else
    fail "sin --receipt-out no se publico ninguna ruta de recibo utilizable por el descriptor 9"
  fi

  if cmp -s "$out_with" "$out_without"; then
    pass "el stdout capturado es IDENTICO byte a byte con y sin --receipt-out"
  else
    fail "el stdout capturado DIFIERE con y sin --receipt-out"
  fi
  if cmp -s "$err_with" "$err_without"; then
    pass "el stderr capturado es IDENTICO byte a byte con y sin --receipt-out"
  else
    fail "el stderr capturado DIFIERE con y sin --receipt-out"
  fi

  if cmp -s "$out_with" "$expected_out"; then
    pass "el stdout capturado es EXACTAMENTE el stdout del escenario"
  else
    fail "el stdout capturado NO es exactamente el stdout del escenario"
    printf '      capturado: [%s]\n' "$(cat "$out_with" 2>/dev/null || true)" >&2
  fi
  if cmp -s "$err_with" "$expected_err"; then
    pass "el stderr capturado es EXACTAMENTE el stderr del escenario"
  else
    fail "el stderr capturado NO es exactamente el stderr del escenario"
    printf '      capturado: [%s]\n' "$(cat "$err_with" 2>/dev/null || true)" >&2
  fi

  # No diagnostic of the entry leaks into the streams of the consumer.
  local leaked="" token
  for token in 'Receipt:' 'RECEIPT_PATH' 'IDENTIFIER=' 'CONTAINMENT_EVIDENCE_CERTIFIABLE' \
    'POSITIVE_ACCEPTANCE' 'PID1_COMPLETION_OBSERVED'; do
    if grep -qF "$token" "$out_with" "$err_with" 2>/dev/null; then
      leaked="$leaked $token"
    fi
  done
  if [ -z "$leaked" ]; then
    pass "ni stdout ni stderr filtran el diagnostico de la entrada (la fuga 'Receipt: ...' no existe)"
  else
    fail "los streams capturados filtran:$leaked"
  fi

  if [ "$rc_with" -eq "$rc_without" ]; then
    pass "el RC de la entrada NO depende del canal del recibo (rc=$rc_with en ambos modos)"
  else
    fail "el RC de la entrada depende del canal del recibo (con=$rc_with sin=$rc_without)"
  fi
}

# (e) An unaccredited frontier does NOT execute the scenario.
#
# The control uses a COPY of the entry whose accreditation of the interior
# FAILS (the guard that stops the scenario is intact). The copy lives OUTSIDE
# the repository: the repository is never modified.
test_an_unaccredited_boundary_does_not_execute_the_scenario() {
  local copy="$WORKDIR/entry-unaccredited.sh"
  if ! patch_entry_copy "$ENTRY" "$copy" "accreditation-fails"; then
    fail "no se pudo preparar la copia con la acreditacion rota"
    return
  fi
  if cmp -s "$ENTRY" "$copy"; then
    fail "la copia con la acreditacion rota es IDENTICA a la entrada: el parche no se aplico"
    return
  fi

  local marker="$WORKDIR/marker-unaccredited.txt"
  local pointer="$WORKDIR/ptr-unaccredited.txt"
  rm -f "$marker" "$pointer"
  write_marker_scenario "$WORKDIR/marker-scenario.sh"

  local rc=0
  bash "$copy" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$pointer" \
    --scenario-timeout 20 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/marker-scenario.sh" "$marker" \
    >"$WORKDIR/out-unaccredited.txt" 2>"$WORKDIR/err-unaccredited.txt" || rc=$?

  if [ ! -s "$marker" ]; then
    pass "una frontera NO acreditada NO ejecuta el escenario"
  else
    fail "una frontera NO acreditada EJECUTO el escenario: el marcador existe"
  fi
  if [ "$rc" -eq 70 ]; then
    pass "una frontera no acreditada devuelve RC 70"
  else
    fail "una frontera no acreditada deberia devolver RC 70 (rc=$rc)"
  fi

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la corrida no acreditada no dejo recibo: la evidencia no puede faltar"
    return
  fi
  if [ "$(forge_receipt_read "$receipt" ACCREDITATION 2>/dev/null || true)" = "FAILED" ] \
    && [ "$(forge_receipt_read "$receipt" SCENARIO_STATUS 2>/dev/null || true)" = "NOT_STARTED" ] \
    && [ "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "NO" ]; then
    pass "el recibo de la corrida no acreditada registra ACCREDITATION=FAILED, NOT_STARTED y evidencia de contencion NO certificable"
  else
    fail "el recibo de la corrida no acreditada no registra el estado correcto"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if forge_receipt_require "$receipt" >/dev/null 2>&1; then
    fail "la evidencia de una corrida no acreditada fue aceptada por el consumidor"
  else
    pass "el consumidor RECHAZA la evidencia de una corrida no acreditada"
  fi
}

# (f) A descendant that is detached and alive inside the namespace does not
#     survive the closure, and the DIFFERENCE between the product and the
#     harness is visible: the product FAILED (it left the descendant behind)
#     while the harness CLOSED CORRECTLY, and the consumer rejected it.
test_a_detached_descendant_does_not_survive_the_closure() {
  local hb="$WORKDIR/hb-detached.txt"
  rm -f "$hb"
  write_detached_scenario "$WORKDIR/detached.sh"

  local scenario rc=0
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  forge_contained_run "$scenario" /bin/sh "$WORKDIR/detached.sh" "$hb" >/dev/null 2>&1 || rc=$?
  rm -f "$scenario"

  local size
  size="$(heartbeat_size "$hb")"
  if [ "$size" -gt 1 ]; then
    pass "el descendiente desligado (setsid --fork) estuvo VIVO dentro de la frontera ($size bytes de latido)"
  else
    fail "el descendiente desligado no llego a escribir: el control no se ejercito ($size bytes)"
  fi

  local receipt="$FORGE_CONTAINMENT_LAST_RECEIPT"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "no hay recibo de la corrida con descendiente desligado"
    return
  fi
  if [ "$(forge_receipt_product_cleanup "$receipt")" = "FAIL" ] \
    && [ "$(forge_receipt_read "$receipt" PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP 2>/dev/null || true)" = "YES" ]; then
    pass "el PRODUCTO se declara FAIL: dejo vivo al descendiente (observado antes de la defensiva)"
  else
    fail "el PRODUCTO deberia declararse FAIL con el descendiente desligado"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ] \
    && [ "$(forge_receipt_read "$receipt" ACCREDITATION 2>/dev/null || true)" = "PASS" ]; then
    pass "el ARNES cierra CORRECTAMENTE aunque el producto falle"
  else
    fail "el ARNES deberia confirmar el cierre aunque el producto falle"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || true)" = "NO" ]; then
    pass "la evidencia de la contencion es certificable pero NO hay aceptacion positiva: el fallo del producto no se disimula"
  else
    fail "el descendiente desligado deberia dejar la contencion certificable SIN aceptacion positiva"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$rc" -ne 0 ]; then
    pass "el consumidor RECHAZA el fallo del producto: no lo convierte en PASS (rc=$rc)"
  else
    fail "el consumidor acepto el fallo del producto como si fuera un PASS (rc=$rc)"
  fi
  if heartbeat_is_frozen "$hb" 2; then
    pass "el descendiente desligado NO sobrevive al cierre de la contencion"
  else
    fail "el descendiente desligado SIGUE VIVO tras el cierre de la contencion"
  fi
}

# The frontier is PRIVATE: the /proc that the scenario sees is the one of its
# own PID namespace, never the one of the host. The check is made FROM
# INSIDE the frontier and it only reads namespace LINKS: no process of the
# host is enumerated and no command line is read.
test_the_frontier_is_private_and_the_host_is_not_inspected() {
  local report="$WORKDIR/namespace-report.txt"
  rm -f "$report"
  write_namespace_probe_scenario "$WORKDIR/namespace-probe.sh"

  # The scenario runs inside the containment AND declares the cleanup of the
  # product, so the run has a POSITIVE ACCEPTANCE and the entry returns 0.
  local scenario rc=0
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  forge_contained_run "$scenario" /bin/sh "$WORKDIR/namespace-probe.sh" "$report" \
    >/dev/null 2>&1 || rc=$?
  rm -f "$scenario"

  if [ "$rc" -ne 0 ]; then
    fail "la sonda de la frontera fallo (rc=$rc)"
    forge_receipt_summary "$FORGE_CONTAINMENT_LAST_RECEIPT" >&2 || true
    return
  fi
  if [ ! -s "$report" ]; then
    fail "la sonda de la frontera no dejo informe"
    return
  fi
  local self_ns pid1_ns
  self_ns="$(awk -F= '$1 == "SELF" { print $2; exit }' "$report")"
  pid1_ns="$(awk -F= '$1 == "PID1" { print $2; exit }' "$report")"
  case "$self_ns" in
    pid:\[*\]) : ;;
    *)
      fail "el /proc interior no es legible como namespace PID ($self_ns)"
      return
      ;;
  esac
  if [ "$self_ns" = "$pid1_ns" ]; then
    pass "el /proc interior es el PRIVADO de la frontera (PID 1 y el escenario comparten namespace: $self_ns)"
  else
    fail "el /proc interior NO es el de la frontera (self=$self_ns pid1=$pid1_ns): el host seria visible"
  fi

  local outer inner receipt=""
  outer="$(readlink /proc/self/ns/pid 2>/dev/null || printf 'UNKNOWN')"
  receipt="$FORGE_CONTAINMENT_LAST_RECEIPT"
  inner="$(forge_receipt_read "$receipt" PID_NAMESPACE 2>/dev/null || printf 'UNKNOWN')"
  if [ "$outer" != "$inner" ]; then
    pass "la frontera es un namespace PID DISTINTO del exterior ($outer -> $inner)"
  else
    fail "la frontera comparte el namespace PID del exterior ($inner)"
  fi
}

# The reader of the evidence rejects what it cannot trust, INCLUDING a
# receipt that is complete but CONTRADICTORY.
#
# The BASE receipt below is COMPLETE and SELF-CONSISTENT: it is ACCEPTED by
# the consumer. Every negative below is a CONTRADICTION of that base, not a
# mere absence of fields, so the test proves that the consumer detects the
# contradiction and not only the incompleteness.
test_the_reader_rejects_contradictory_evidence() {
  local receipt="$WORKDIR/contradictory.txt"

  printf '%s\n' \
    'IDENTIFIER=run-test' \
    'RECEIPT_PATH=/tmp/x' \
    'STARTED_UTC=2026-01-01T00:00:00Z' \
    'ENDED_UTC=2026-01-01T00:00:01Z' \
    'SCENARIO_ORDER_LITERAL=/bin/true' \
    'SCENARIO_TIMEOUT_SECONDS=20s' \
    'CLOSURE_BUDGET_SECONDS=3s' \
    'HOME_TEMP=/tmp/a' 'XDG_CONFIG_HOME_TEMP=/tmp/b' 'XDG_DATA_HOME_TEMP=/tmp/c' \
    'XDG_CACHE_HOME_TEMP=/tmp/d' 'XDG_STATE_HOME_TEMP=/tmp/e' 'TMPDIR_TEMP=/tmp/f' \
    'PID_NAMESPACE=pid:[1]' 'MOUNT_NAMESPACE=mnt:[1]' 'PID1_INTERIOR=1' 'NSPID=1' \
    'PROCFS_TYPE=proc' 'PROC_MOUNT_PRIVATE=YES' \
    'ACCREDITATION=PASS' 'ACCREDITATION_REASON=PASS' \
    'SCENARIO_STATUS=COMPLETED' 'SCENARIO_RC=0' 'INTERRUPTION_CAUSE=NONE' \
    'INTERRUPTION_FORWARDING=NOT_REQUESTED' \
    'PRODUCT_CLEANUP_RESULT=PASS' \
    'PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=YES' \
    'DEFENSIVE_CLEANUP=PASS' 'EXPECTED_SCENARIO_RC=0' 'EXPECTED_TERMINATION=x' \
    'LAUNCHER_RC=0' 'LAUNCHER_WAIT_COMPLETED=YES' 'PID1_COMPLETION_OBSERVED=PASS' \
    'CLOSURE=CONFIRMED' \
    'RECEIPT_COMPLETENESS=COMPLETE' 'CONTAINMENT_EVIDENCE_CERTIFIABLE=YES' \
    'POSITIVE_ACCEPTANCE=YES' 'WRAPPER_EXIT_CODE=0' > "$receipt"

  # The base is accepted: the negatives below are contradictions, not
  # absences.
  if forge_receipt_require "$receipt" >/dev/null 2>&1; then
    pass "un recibo completo y coherente se acepta: los negativos de abajo son CONTRADICCIONES"
  else
    fail "un recibo completo y coherente deberia aceptarse: los negativos de abajo no probarian nada"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  sed 's/^ACCREDITATION=PASS$/ACCREDITATION=FAILED/' "$receipt" > "$WORKDIR/unaccredited.txt"
  if forge_receipt_require "$WORKDIR/unaccredited.txt" >/dev/null 2>&1; then
    fail "un recibo CONTRADICTORIO (acreditacion FAILED y evidencia certificable YES) fue aceptado"
  else
    pass "un recibo contradictorio se rechaza: la evidencia no puede contradecirse"
  fi

  sed 's/^CLOSURE=CONFIRMED$/CLOSURE=UNCONFIRMED/' "$receipt" > "$WORKDIR/unconfirmed.txt"
  if forge_receipt_require "$WORKDIR/unconfirmed.txt" >/dev/null 2>&1; then
    fail "un recibo con CIERRE NO CONFIRMADO fue aceptado"
  else
    pass "un recibo con cierre no confirmado se rechaza"
  fi

  sed 's/^LAUNCHER_WAIT_COMPLETED=YES$/LAUNCHER_WAIT_COMPLETED=NO/' "$receipt" > "$WORKDIR/not-waited.txt"
  if forge_receipt_require "$WORKDIR/not-waited.txt" >/dev/null 2>&1; then
    fail "un recibo sin el EXPECTADO DEL LANZADOR fue aceptado"
  else
    pass "un recibo sin la espera del lanzador se rechaza"
  fi

  # The three links of the closure are INDEPENDENT: a receipt that declares
  # the closure as CONFIRMED but that does not carry the OBSERVED effective
  # termination of the private PID 1 is contradictory evidence. The signal
  # that was sent is NOT an observed termination.
  sed 's/^PID1_COMPLETION_OBSERVED=PASS$/PID1_COMPLETION_OBSERVED=NO/' \
    "$receipt" > "$WORKDIR/not-observed-pid1.txt"
  if forge_receipt_require "$WORKDIR/not-observed-pid1.txt" >/dev/null 2>&1; then
    fail "un recibo CONTRADICTORIO (cierre CONFIRMED sin la terminacion del PID 1 observada) fue aceptado"
  else
    pass "un recibo con la terminacion del PID 1 NO observada se rechaza"
  fi

  # The same for the RC of the launcher: a launcher that was waited for but
  # returned a non-zero RC did not close cleanly.
  sed 's/^LAUNCHER_RC=0$/LAUNCHER_RC=1/' "$receipt" > "$WORKDIR/failed-launcher.txt"
  if forge_receipt_require "$WORKDIR/failed-launcher.txt" >/dev/null 2>&1; then
    fail "un recibo CONTRADICTORIO (cierre CONFIRMED con un RC de lanzador distinto de cero) fue aceptado"
  else
    pass "un recibo con el RC del lanzador distinto de cero se rechaza"
  fi

  # The status of the launcher is NOT RECOVERABLE: the entry could not
  # recover it after the interrupted wait. It is NOT a zero and it is NOT a
  # "the launcher was waited for": the receipt that declares it is
  # CONTRADICTORY evidence and the consumer must reject it.
  sed -e 's/^LAUNCHER_RC=0$/LAUNCHER_RC=NOT_RECOVERABLE/' \
      -e 's/^LAUNCHER_WAIT_COMPLETED=YES$/LAUNCHER_WAIT_COMPLETED=NO/' \
      "$receipt" > "$WORKDIR/not-recoverable-launcher.txt"
  if forge_receipt_require "$WORKDIR/not-recoverable-launcher.txt" >/dev/null 2>&1; then
    fail "un recibo CONTRADICTORIO (estado del lanzador NO recuperable) fue aceptado"
  else
    pass "un recibo con el estado del lanzador NO recuperable se rechaza"
  fi
  if forge_receipt_containment_evidence "$WORKDIR/not-recoverable-launcher.txt" >/dev/null 2>&1; then
    fail "la evidencia de contencion acepto un estado del lanzador NO recuperable"
  else
    pass "la evidencia de contencion RECHAZA un estado del lanzador NO recuperable"
  fi

  sed 's/^PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=YES$/PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=NO/' \
    "$receipt" > "$WORKDIR/not-observed.txt"
  if [ "$(forge_receipt_product_cleanup "$WORKDIR/not-observed.txt")" = "PASS" ]; then
    fail "una limpieza del producto NO observada se leyo como PASS"
  else
    pass "una limpieza del producto NO observada se lee como UNKNOWN: nunca PASS"
  fi
  if forge_receipt_require "$WORKDIR/not-observed.txt" >/dev/null 2>&1; then
    fail "un recibo con la limpieza del producto NO observada fue aceptado"
  else
    pass "un recibo con la limpieza del producto NO observada se rechaza"
  fi

  # The receipt declares a POSITIVE ACCEPTANCE whose own fields contradict:
  # the RC of the scenario is not the RC esperado.
  sed 's/^SCENARIO_RC=0$/SCENARIO_RC=42/' "$receipt" > "$WORKDIR/wrong-rc.txt"
  if forge_receipt_require "$WORKDIR/wrong-rc.txt" >/dev/null 2>&1; then
    fail "un recibo que declara aceptacion positiva con un RC que no es el esperado fue aceptado"
  else
    pass "un recibo con POSITIVE_ACCEPTANCE=YES pero un RC que no es el esperado se rechaza"
  fi

  # The receipt does NOT declare the positive acceptance although everything
  # else is in order: the consumer does not presume it.
  sed 's/^POSITIVE_ACCEPTANCE=YES$/POSITIVE_ACCEPTANCE=NO/' "$receipt" > "$WORKDIR/no-positive.txt"
  if forge_receipt_require "$WORKDIR/no-positive.txt" >/dev/null 2>&1; then
    fail "un recibo sin aceptacion positiva fue aceptado"
  else
    pass "un recibo sin POSITIVE_ACCEPTANCE=YES se rechaza"
  fi

  # The receipt declares an INTERRUPTION that the PID 1 of the namespace did
  # NOT observe: the re-forwarding was only requested (or unconfirmed). That
  # is CONTRADICTORY evidence: the closure would rest on a signal that
  # nobody observed being applied.
  sed -e 's/^INTERRUPTION_CAUSE=NONE$/INTERRUPTION_CAUSE=SIGTERM/' \
      -e 's/^INTERRUPTION_FORWARDING=NOT_REQUESTED$/INTERRUPTION_FORWARDING=UNCONFIRMED/' \
      "$receipt" > "$WORKDIR/unobserved-interruption.txt"
  if forge_receipt_require "$WORKDIR/unobserved-interruption.txt" >/dev/null 2>&1; then
    fail "un recibo CONTRADICTORIO (interrupcion declarada sin que el PID 1 la observara) fue aceptado"
  else
    pass "un recibo con una interrupcion NO observada por el PID 1 se rechaza"
  fi

  # The same receipt, but with the interruption OBSERVED by the PID 1: it is
  # accepted, so the negative above is a contradiction and not a mere absence.
  sed -e 's/^INTERRUPTION_CAUSE=NONE$/INTERRUPTION_CAUSE=SIGTERM/' \
      -e 's/^INTERRUPTION_FORWARDING=NOT_REQUESTED$/INTERRUPTION_FORWARDING=OBSERVED_BY_PID1/' \
      "$receipt" > "$WORKDIR/observed-interruption.txt"
  if forge_receipt_require "$WORKDIR/observed-interruption.txt" >/dev/null 2>&1; then
    pass "un recibo con la interrupcion OBSERVADA por el PID 1 se acepta: el negativo anterior es una CONTRADICCION"
  else
    fail "un recibo con la interrupcion observada por el PID 1 deberia aceptarse"
    forge_receipt_summary "$WORKDIR/observed-interruption.txt" >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# 27.bis. A DUPLICATED field is CONTRADICTORY evidence.
#
# The reader of the receipt used to accept the FIRST occurrence of a field
# and to stop reading. A receipt that carried a SECOND, contradictory
# declaration of the same field was therefore accepted on the strength of
# the first one: appending "PRODUCT_CLEANUP_RESULT=FAIL" or
# "CLOSURE=NOT_CONFIRMED" to an accepted receipt did not change the
# verdict of the gate. That is exactly the rejection of contradictory
# evidence that the contract demands, and it was not there.
#
# The UNIQUENESS of the fields is part of the validity of a receipt: the
# duplicated declaration is REJECTED, it is never resolved in favour of the
# first occurrence.
# ---------------------------------------------------------------------------
test_a_receipt_with_a_duplicated_field_is_rejected() {
  local receipt="$WORKDIR/duplicated.txt"

  printf '%s\n' \
    'IDENTIFIER=run-test' \
    'RECEIPT_PATH=/tmp/x' \
    'STARTED_UTC=2026-01-01T00:00:00Z' \
    'ENDED_UTC=2026-01-01T00:00:01Z' \
    'SCENARIO_ORDER_LITERAL=/bin/true' \
    'SCENARIO_TIMEOUT_SECONDS=20s' \
    'CLOSURE_BUDGET_SECONDS=3s' \
    'HOME_TEMP=/tmp/a' 'XDG_CONFIG_HOME_TEMP=/tmp/b' 'XDG_DATA_HOME_TEMP=/tmp/c' \
    'XDG_CACHE_HOME_TEMP=/tmp/d' 'XDG_STATE_HOME_TEMP=/tmp/e' 'TMPDIR_TEMP=/tmp/f' \
    'PID_NAMESPACE=pid:[1]' 'MOUNT_NAMESPACE=mnt:[1]' 'PID1_INTERIOR=1' 'NSPID=1' \
    'PROCFS_TYPE=proc' 'PROC_MOUNT_PRIVATE=YES' \
    'ACCREDITATION=PASS' 'ACCREDITATION_REASON=PASS' \
    'SCENARIO_STATUS=COMPLETED' 'SCENARIO_RC=0' 'INTERRUPTION_CAUSE=NONE' \
    'INTERRUPTION_FORWARDING=NOT_REQUESTED' \
    'PRODUCT_CLEANUP_RESULT=PASS' \
    'PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=YES' \
    'DEFENSIVE_CLEANUP=PASS' 'EXPECTED_SCENARIO_RC=0' 'EXPECTED_TERMINATION=x' \
    'LAUNCHER_RC=0' 'LAUNCHER_WAIT_COMPLETED=YES' 'PID1_COMPLETION_OBSERVED=PASS' \
    'CLOSURE=CONFIRMED' \
    'RECEIPT_COMPLETENESS=COMPLETE' 'CONTAINMENT_EVIDENCE_CERTIFIABLE=YES' \
    'POSITIVE_ACCEPTANCE=YES' 'WRAPPER_EXIT_CODE=0' > "$receipt"

  # The base is accepted: the negatives below are CONTRADICTIONS, not
  # absences.
  if forge_receipt_require "$receipt" >/dev/null 2>&1; then
    pass "un recibo completo y coherente se acepta: los negativos de abajo son CONTRADICCIONES"
  else
    fail "un recibo completo y coherente deberia aceptarse: los negativos de abajo no probarian nada"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  # a) A SECOND declaration of the result of the cleanup of the product.
  cp "$receipt" "$WORKDIR/duplicated-product.txt"
  printf '%s\n' 'PRODUCT_CLEANUP_RESULT=FAIL' >> "$WORKDIR/duplicated-product.txt"
  if forge_receipt_require "$WORKDIR/duplicated-product.txt" >/dev/null 2>&1; then
    fail "un recibo que declara DOS VECES el resultado de la limpieza del producto fue aceptado"
  else
    pass "un recibo con un campo declarado mas de una vez se rechaza: la evidencia contradictoria no se lava"
  fi

  # b) A SECOND declaration of the closure.
  cp "$receipt" "$WORKDIR/duplicated-closure.txt"
  printf '%s\n' 'CLOSURE=NOT_CONFIRMED' >> "$WORKDIR/duplicated-closure.txt"
  if forge_receipt_require "$WORKDIR/duplicated-closure.txt" >/dev/null 2>&1; then
    fail "un recibo que declara DOS VECES el cierre fue aceptado"
  else
    pass "un recibo con el cierre declarado mas de una vez se rechaza"
  fi

  # c) The READER itself refuses the duplicated field: it does not select
  #    the first declaration in silence.
  if forge_receipt_read "$WORKDIR/duplicated-product.txt" PRODUCT_CLEANUP_RESULT \
    >/dev/null 2>&1; then
    fail "el lector eligio en silencio la primera declaracion de un campo duplicado"
  else
    pass "el lector NO elige en silencio la primera declaracion de un campo duplicado"
  fi

  # d) The result of the cleanup of the product is not a PASS either.
  if [ "$(forge_receipt_product_cleanup "$WORKDIR/duplicated-product.txt")" = "PASS" ]; then
    fail "una limpieza del producto con dos declaraciones contradictorias se leyo como PASS"
  else
    pass "una limpieza del producto con declaraciones contradictorias NO se lee como PASS"
  fi

  # e) The evidence of the CONTAINMENT is rejected as well (it is the first
  #    gate of the consumer).
  if forge_receipt_containment_evidence "$WORKDIR/duplicated-closure.txt" >/dev/null 2>&1; then
    fail "la evidencia de contencion acepto un recibo con un campo duplicado"
  else
    pass "la evidencia de contencion RECHAZA un recibo con un campo duplicado"
  fi
}

# The field was RENAMED and it has NO alias: a receipt of the previous
# contract (the legacy key "CERTIFIABLE") is evidence of another contract
# and a consumer of the current one must not accept it.
test_the_legacy_certifiable_key_is_not_an_alias() {
  local receipt="$WORKDIR/legacy.txt"

  printf '%s\n' \
    'IDENTIFIER=run-test' 'RECEIPT_PATH=/tmp/x' \
    'STARTED_UTC=2026-01-01T00:00:00Z' 'ENDED_UTC=2026-01-01T00:00:01Z' \
    'SCENARIO_ORDER_LITERAL=/bin/true' 'SCENARIO_TIMEOUT_SECONDS=20s' \
    'CLOSURE_BUDGET_SECONDS=3s' \
    'HOME_TEMP=/tmp/a' 'XDG_CONFIG_HOME_TEMP=/tmp/b' 'XDG_DATA_HOME_TEMP=/tmp/c' \
    'XDG_CACHE_HOME_TEMP=/tmp/d' 'XDG_STATE_HOME_TEMP=/tmp/e' 'TMPDIR_TEMP=/tmp/f' \
    'PID_NAMESPACE=pid:[1]' 'MOUNT_NAMESPACE=mnt:[1]' 'PID1_INTERIOR=1' 'NSPID=1' \
    'PROCFS_TYPE=proc' 'PROC_MOUNT_PRIVATE=YES' \
    'ACCREDITATION=PASS' 'ACCREDITATION_REASON=PASS' \
    'SCENARIO_STATUS=COMPLETED' 'SCENARIO_RC=0' 'INTERRUPTION_CAUSE=NONE' \
    'INTERRUPTION_FORWARDING=NOT_REQUESTED' \
    'PRODUCT_CLEANUP_RESULT=PASS' \
    'PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=YES' \
    'DEFENSIVE_CLEANUP=PASS' 'EXPECTED_SCENARIO_RC=0' 'EXPECTED_TERMINATION=x' \
    'LAUNCHER_RC=0' 'LAUNCHER_WAIT_COMPLETED=YES' 'PID1_COMPLETION_OBSERVED=PASS' \
    'CLOSURE=CONFIRMED' \
    'RECEIPT_COMPLETENESS=COMPLETE' 'CERTIFIABLE=YES' \
    'WRAPPER_EXIT_CODE=0' > "$receipt"

  if forge_receipt_require "$receipt" >/dev/null 2>&1; then
    fail "un recibo con la clave legacy CERTIFIABLE= fue aceptado: el campo renombrado no tiene alias"
  else
    pass "un recibo con la clave legacy CERTIFIABLE= se rechaza: el campo renombrado NO tiene alias"
  fi

  # A receipt with BOTH keys is contradictory as well: the consumer does not
  # pick the convenient one.
  printf '%s\n' 'CONTAINMENT_EVIDENCE_CERTIFIABLE=YES' >> "$receipt"
  if forge_receipt_require "$receipt" >/dev/null 2>&1; then
    fail "un recibo con la clave legacy Y la nueva fue aceptado"
  else
    pass "un recibo con la clave legacy Y la nueva se rechaza"
  fi
}

# The protected snapshot observes the personal trees BY METADATA ONLY: the
# CONTENT of a protected tree is never read.
#
# The probe uses a FIFO: opening a FIFO for reading BLOCKS until a writer
# appears, so a snapshot that opened the credentials would hang. The probe
# also puts a canary in a configuration file and checks that the canary never
# appears in the snapshot.
test_the_protected_snapshot_never_reads_the_content_of_a_personal_tree() {
  local sandbox="$WORKDIR/protected-home"
  local canary="canary-CONTENT-QUE-NO-DEBE-APARECER"
  mkdir -p "$sandbox/.config/opencode-forge" "$sandbox/.local/share/opencode" \
    "$sandbox/.local/share/forge" || {
    fail "no se pudo preparar el hogar de la sonda"
    return
  }

  printf '%s\n' "$canary" > "$sandbox/.config/opencode-forge/opencode.jsonc"
  # The credentials of the probe are a FIFO: reading them would block.
  if ! mkfifo "$sandbox/.opencode-tokens" 2>/dev/null; then
    fail "no se pudo crear el FIFO de la sonda"
    return
  fi

  local snapshot rc=0
  snapshot="$(timeout 20 bash -c '
    set -euo pipefail
    . "$1/tests/isolation.sh"
    forge_protected_snapshot "$2" ".opencode-tokens:meta .config/opencode-forge:meta .local/share/forge:meta"
  ' _ "$FORGE_ROOT" "$sandbox" 2>/dev/null)" || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "la instantanea del hogar de la sonda no termino (rc=$rc): un FIFO habria bloqueado una lectura de contenido"
    return
  fi
  pass "la instantanea del hogar de la sonda TERMINA sobre un FIFO de credenciales: no se abre ninguna credencial"

  if [ -z "$snapshot" ]; then
    fail "la instantanea del hogar de la sonda esta vacia"
    return
  fi
  if printf '%s\n' "$snapshot" | grep -q "$canary"; then
    fail "el contenido de un fichero personal aparecio en la instantanea"
  else
    pass "el contenido de un fichero personal NO aparece en la instantanea"
  fi

  # The observation is not vacuous: the metadata of the credentials IS
  # observed, and the appearance of a new file IS detected.
  if printf '%s\n' "$snapshot" | grep -q "^.opencode-tokens"; then
    pass "la instantanea observa los METADATOS de las credenciales (sin leer su contenido)"
  else
    fail "la instantanea no observa las credenciales: la comprobacion seria vacua"
  fi

  local before after
  before="$(forge_protected_snapshot "$sandbox" ".opencode-tokens:meta .config/opencode-forge:meta .local/share/forge:meta")"
  printf '%s\n' "$canary" > "$sandbox/.config/opencode-forge/otro.jsonc"
  after="$(forge_protected_snapshot "$sandbox" ".opencode-tokens:meta .config/opencode-forge:meta .local/share/forge:meta")"
  if [ "$before" != "$after" ]; then
    pass "la aparicion de un fichero nuevo en un arbol protegido SE DETECTA por metadatos"
  else
    fail "la aparicion de un fichero nuevo en un arbol protegido NO se detecta"
  fi

  # The identity of the protected PID and the identity of the live database
  # are part of the observation.
  local full
  full="$(forge_protected_snapshot "$sandbox")"
  if printf '%s\n' "$full" | grep -q "^__protected_pid__" \
    && printf '%s\n' "$full" | grep -q "^__protected_db_identity__"; then
    pass "la instantanea incluye la identidad del PID protegido y la de la base de datos"
  else
    fail "la instantanea no incluye la identidad del PID protegido ni la de la base de datos"
  fi
}

# ---------------------------------------------------------------------------
# 11. The helper of the isolation has ONE definition of the entry, and the
#     definition IN FORCE is the one that goes through the containment.
#
#     tests/isolation.sh used to carry TWO definitions of forge_isolated_env:
#     the one inherited from 3aa8095 (which runs the command OUTSIDE the
#     containment, directly on the host) and the one that goes through
#     forge_contained_run. In bash the LAST definition wins, so the old one
#     was dead code -- but it was a FAIL-OPEN TRAP: whoever reordered the two
#     would put every scenario back on the host, and the suite would still be
#     green, because the dead definition is a perfectly working one.
#
#     The check has TWO parts, and the SECOND one is not redundant:
#
#       a) the STATISTIC one: there is exactly ONE definition of
#          forge_isolated_env in the whole tree of the helper under test, and
#          it lives in the helper itself. A second definition is a FAILURE
#          whatever the order is and whatever the behaviour of the shell.
#          No name may be defined twice inside the helper either: the same
#          trap, for any other function.
#       b) the BEHAVIOURAL one: the definition in force routes the command
#          through the containment, and the command ends in a PID namespace
#          DIFFERENT from the outer one. It proves that the trap is not
#          armed NOW, and it is the part that a mere textual count cannot
#          give: the order of the definitions decides which one wins.
#
#     The tree that is scanned is the directory of the helper UNDER TEST, so
#     the sensitivity harness can point the battery at a mutated copy and
#     see the detector react.
# ---------------------------------------------------------------------------
test_the_isolation_helper_has_a_single_definition_of_the_entry() {
  local scanner="$FORGE_TEST_SHELL_DEFS_SCANNER"
  local isolation="$FORGE_TEST_ISOLATION"
  local tree
  tree="$(dirname "$isolation")"

  if [ ! -f "$scanner" ]; then
    fail "no se encuentra el escaner de definiciones ($scanner)"
    return
  fi

  # a) The STATISTIC part.
  #
  # The exit status of the scanner is part of its contract: 0 means "no
  # duplicates", 1 means "there are duplicates" (and it prints them) and 64
  # means "the scanner could not do its work". An empty output of a scanner
  # that FAILED is NOT "no duplicates": it is an error, and it is reported
  # as one.
  local definitions count scanner_rc=0
  definitions="$(python3 "$scanner" count "$tree" forge_isolated_env 2>"$WORKDIR/scanner-count.err")" || scanner_rc=$?
  if [ "$scanner_rc" -ne 0 ]; then
    fail "el escaner de definiciones fallo (rc=$scanner_rc): su salida no prueba nada"
    sed -n '1,10p' "$WORKDIR/scanner-count.err" | sed 's/^/      /' >&2
    return
  fi
  if [ -z "$definitions" ]; then
    fail "forge_isolated_env NO esta definida en ninguna parte de $tree"
    return
  fi
  count="$(printf '%s\n' "$definitions" | grep -c ':')"
  if [ "$count" -eq 1 ]; then
    pass "forge_isolated_env esta definida UNA SOLA VEZ en $tree ($definitions)"
  else
    fail "forge_isolated_env esta definida $count VECES: una definicion posterior pisa a la anterior y la contencion se pierde en silencio ($definitions)"
    printf '%s\n' "$definitions" | sed 's/^/      /' >&2
  fi

  local where
  where="$(printf '%s\n' "$definitions" | head -1 | sed 's/:[0-9]*$//')"
  if [ "$where" = "$isolation" ]; then
    pass "la definicion vive en el helper que se esta probando ($where)"
  else
    fail "la definicion de forge_isolated_env vive en $where y no en el helper que se esta probando ($isolation)"
  fi

  local duplicates duplicates_rc=0
  duplicates="$(forge_shell_defs_duplicates "$scanner" "$isolation" 2>"$WORKDIR/scanner-duplicates.err")" || duplicates_rc=$?
  case "$duplicates_rc" in
    0)
      pass "ninguna funcion esta definida mas de una vez en $isolation"
      ;;
    1)
      fail "hay funciones definidas mas de una vez en $isolation: $duplicates"
      printf '%s\n' "$duplicates" | sed 's/^/      /' >&2
      ;;
    *)
      # The scanner FAILED: an empty output is NOT "no duplicates". It is an
      # error of the scanner, and it is reported as one.
      fail "el escaner de definiciones fallo (rc=$duplicates_rc): su salida vacia NO prueba que no haya duplicados"
      sed -n '1,10p' "$WORKDIR/scanner-duplicates.err" | sed 's/^/      /' >&2
      ;;
  esac

  # b) The BEHAVIOURAL part: the definition IN FORCE is the contained one.
  local effective
  effective="$(declare -f forge_isolated_env 2>/dev/null)"
  if printf '%s\n' "$effective" | grep -q 'forge_contained_run'; then
    pass "la definicion EN VIGOR de forge_isolated_env encauza por la contencion"
  else
    fail "la definicion EN VIGOR de forge_isolated_env NO encauza por la contencion: el escenario se ejecutaria sobre el host"
    printf '%s\n' "$effective" | sed 's/^/      /' >&2
    return
  fi

  # The command ends INSIDE a private PID namespace: the namespace of the
  # scenario is NOT the one of the shell that called it.
  local outer inner rc=0
  outer="$(readlink /proc/self/ns/pid 2>/dev/null || printf 'UNREADABLE')"
  inner="$(forge_isolated_env "$WORKDIR/home" /bin/sh -c 'readlink /proc/self/ns/pid' 2>/dev/null)" || rc=$?
  inner="$(printf '%s\n' "$inner" | grep -o 'pid:\[[0-9]*\]' | head -1)"
  if [ -z "$inner" ]; then
    fail "el escenario no devolvio un namespace PID: no se puede comprobar la contencion (rc=$rc)"
    return
  fi
  if [ "$rc" -ne 0 ]; then
    fail "la corrida contenida no devolvio RC 0: la aceptacion positiva no esta acreditada (rc=$rc)"
  else
    pass "la corrida contenida devuelve RC 0: la aceptacion positiva esta acreditada"
  fi
  if [ "$inner" != "$outer" ]; then
    pass "el escenario termina DENTRO de la contencion (namespace $inner, distinto del exterior $outer)"
  else
    fail "el escenario termina FUERA de la contencion: comparte el namespace PID del exterior ($inner)"
  fi
}

# ---------------------------------------------------------------------------
# 21.bis. The scanner of the REAL definitions decides by the LEXICAL CONTEXT
#        AT THE START of the definition, and its failures are ERRORS.
#
# A shell file can hold text that LOOKS like a definition and is not one (the
# body of a string that spans several lines), and it can hold a REAL
# definition whose line OPENS a multi-line string. Deciding with the quoting
# state AFTER traversing the line got both cases wrong: a real definition was
# omitted and a fictitious one was counted.
#
# The consumer of the scanner must also distinguish "the scanner worked and
# there are no duplicates" from "the scanner failed": an empty output of a
# failed scanner is the ABSENCE of evidence, never the absence of duplicates.
# ---------------------------------------------------------------------------
test_the_definition_scanner_decides_by_the_lexical_context() {
  local scanner="$FORGE_TEST_SHELL_DEFS_SCANNER"
  if [ ! -f "$scanner" ]; then
    fail "no se encuentra el escaner de definiciones ($scanner)"
    return
  fi

  local fixture="$WORKDIR/lexer-fixture.sh"
  cat > "$fixture" <<'LEXER_EOF'
#!/bin/sh
# A REAL definition whose OWN line opens a multi-line string: the context at
# the START of the line is code, so the definition EXISTS.
real_one() { text="line one
line two"
}
# A FICTICIOUS definition inside a string that ENDS on its line: the context
# at the START of the line is a string, so the line is DATA.
data="some text
fictitious() {"
LEXER_EOF

  local found
  found="$(python3 "$scanner" count "$fixture" real_one 2>/dev/null)"
  if [ -n "$found" ]; then
    pass "el escaner cuenta una definicion real que abre una cadena multilinea ($found)"
  else
    fail "el escaner OMITE una definicion real que abre una cadena multilinea: el contexto se decidio al final de la linea"
  fi

  found="$(python3 "$scanner" count "$fixture" fictitious 2>/dev/null)"
  if [ -z "$found" ]; then
    pass "el escaner NO cuenta una definicion ficticia dentro de una cadena que termina en esa linea"
  else
    fail "el escaner CUENTA una definicion ficticia dentro de una cadena ($found): el contexto se decidio al final de la linea"
  fi

  # The consumer of the scanner: a failed scan is an ERROR, not "no
  # duplicates".
  local rc=0
  forge_shell_defs_duplicates "$scanner" "$fixture" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "el consumidor del escaner distingue el escaneo correcto sin duplicados (rc=0)"
  else
    fail "el consumidor del escaner no reconoce el escaneo correcto sin duplicados (rc=$rc)"
  fi

  rc=0
  forge_shell_defs_duplicates "$scanner" "$WORKDIR/no-existe.sh" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "el consumidor del escaner trata un escaneo fallido como ERROR y no como 'sin duplicados' (rc=2)"
  else
    fail "el consumidor del escaner trato un escaneo fallido como 'sin duplicados' (rc=$rc)"
  fi

  # A scanner that CRASHES is also an error, not an absence of duplicates.
  local broken="$WORKDIR/broken-scanner.py"
  printf 'def broken(\n' > "$broken"
  rc=0
  forge_shell_defs_duplicates "$broken" "$fixture" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 2 ]; then
    pass "el consumidor del escaner trata un escaner que revienta como ERROR y no como 'sin duplicados' (rc=2)"
  else
    fail "el consumidor del escaner trato un escaner que revienta como 'sin duplicados' (rc=$rc)"
  fi
}

# ---------------------------------------------------------------------------
# 21. The PATH of the scenario is the DECLARED one.
#
# The entry never inherits the PATH of the caller (that PATH can expose the
# global runtime of the host). A caller that needs a runtime which is not in
# the standard PATH declares it explicitly, the declaration reaches the
# scenario and it is recorded in the receipt.
# ---------------------------------------------------------------------------
test_the_declared_path_of_the_scenario_is_used() {
  local declared="/usr/bin:/bin"
  local probe="$WORKDIR/path-probe.txt"
  local pointer="$WORKDIR/pointer-path.txt"
  rm -f "$probe" "$pointer"

  local rc=0
  local scenario
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  # The scenario expects the observer and the killer of the private /proc as
  # its first two arguments: they are prepared here, exactly as the consumer
  # of the containment does.
  local helper_dir="$WORKDIR/path-helpers"
  mkdir -p "$helper_dir"
  if ! forge_write_containment_observer "$helper_dir" || ! forge_write_containment_killer "$helper_dir"; then
    fail "no se pudieron preparar los ayudantes del /proc privado"
    return
  fi
  env FORGE_CONTAINED_RUN_SCENARIO_PATH="$declared" \
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 20 \
      --close-timeout 3 \
      -- /bin/sh "$scenario" \
         "$helper_dir/forge-containment-observer.sh" \
         "$helper_dir/forge-containment-killer.sh" \
         /bin/sh -c "printf '%s\n' \"\$PATH\" > '$probe'" \
      >"$WORKDIR/out-path.txt" 2>"$WORKDIR/err-path.txt" || rc=$?
  rm -f "$scenario"

  if [ "$rc" -ne 0 ]; then
    fail "la corrida con el PATH declarado no devolvio RC 0 (rc=$rc)"
  else
    pass "la corrida con el PATH declarado devuelve RC 0"
  fi

  local observed=""
  [ -s "$probe" ] && IFS= read -r observed < "$probe"
  if [ "$observed" = "$declared" ]; then
    pass "el escenario ve EXACTAMENTE el PATH declarado ($observed)"
  else
    fail "el escenario NO ve el PATH declarado (obtenido: '$observed', declarado: '$declared')"
  fi

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -n "$receipt" ] && [ -s "$receipt" ]; then
    local recorded
    recorded="$(forge_receipt_read "$receipt" SCENARIO_PATH 2>/dev/null || printf 'ABSENT')"
    if [ "$recorded" = "$declared" ]; then
      pass "el recibo REGISTRA el PATH declarado del escenario ($recorded)"
    else
      fail "el recibo no registra el PATH declarado del escenario (registrado: '$recorded')"
    fi
  else
    fail "la corrida con el PATH declarado no dejo recibo"
  fi

  # A declaration with blanks is refused: the PATH reaches the escenario as
  # one assignment of the environment rebuilt with env -i.
  rc=0
  env FORGE_CONTAINED_RUN_SCENARIO_PATH="/usr/bin:/bin con espacio" \
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$WORKDIR/pointer-bad-path.txt" \
      --scenario-timeout 20 \
      --close-timeout 3 \
      -- /bin/true \
      >"$WORKDIR/out-bad-path.txt" 2>"$WORKDIR/err-bad-path.txt" || rc=$?
  if [ "$rc" -eq 64 ]; then
    pass "un PATH declarado con blancos se RECHAZA con RC 64 (no se ejecuta nada)"
  else
    fail "un PATH declarado con blancos deberia rechazarse con RC 64 (rc=$rc)"
  fi
}

# ---------------------------------------------------------------------------
# 22. An ELIMINATED scenario leaves no residue.
#
# The inner process removes the context when the scenario ends normally. When
# the scenario has to be eliminated (it hangs on purpose and the bounded
# close kills the whole contained environment), the inner is exactly the
# process that cannot do it. The OUTER side removes the residue then, and
# the removal is OBSERVED. The verdict of the product is NOT touched: a
# scenario that was eliminated never declared its own cleanup, so the
# positive acceptance stays NO.
# ---------------------------------------------------------------------------
test_an_eliminated_scenario_leaves_no_residue() {
  local pointer="$WORKDIR/pointer-eliminated.txt"
  rm -f "$pointer"

  # The scenario IGNORES the TERM of the bounded close, so the close has to
  # escalate to the KILL: the inner process dies with the whole namespace and
  # it cannot remove the context.
  local scenario="$WORKDIR/eliminated.sh"
  cat > "$scenario" <<'ELIMINATED_EOF'
#!/bin/sh
trap '' TERM
while true; do
  sleep 0.2
done
ELIMINATED_EOF
  chmod +x "$scenario"

  local rc=0
  env FORGE_CONTAINED_RUN_EXPECTED_SCENARIO_RC=NONE \
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 3 \
      --close-timeout 3 \
      -- /bin/sh "$scenario" \
      >"$WORKDIR/out-eliminated.txt" 2>"$WORKDIR/err-eliminated.txt" || rc=$?

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la corrida eliminada no dejo recibo: la evidencia no puede faltar"
    return
  fi

  local status
  status="$(forge_receipt_read "$receipt" SCENARIO_STATUS 2>/dev/null || printf 'ABSENT')"
  if [ "$status" = "TIMEOUT" ]; then
    pass "el escenario eliminado queda registrado como TIMEOUT"
  else
    fail "el escenario eliminado deberia quedar registrado como TIMEOUT (estado: $status)"
  fi

  local defensive removed_by present
  defensive="$(forge_receipt_read "$receipt" DEFENSIVE_CLEANUP 2>/dev/null || printf 'ABSENT')"
  removed_by="$(forge_receipt_read "$receipt" DEFENSIVE_CLEANUP_REMOVED_BY 2>/dev/null || printf 'ABSENT')"
  present="$(forge_receipt_read "$receipt" CONTEXT_PRESENT_AFTER 2>/dev/null || printf 'ABSENT')"
  if [ "$defensive" = "PASS" ] && [ "$present" = "NO" ]; then
    pass "la limpieza defensiva del contexto eliminado es PASS y el contexto NO esta presente"
  else
    fail "el contexto de un escenario eliminado deberia estar ausente (limpieza=$defensive presente=$present)"
    forge_receipt_summary "$receipt" >&2 || true
  fi
  if [ "$removed_by" = "OUTER" ]; then
    pass "el residuo lo retiro la parte EXTERIOR (el interior fue eliminado con el namespace)"
  else
    fail "el residuo del escenario eliminado deberia retirarlo la parte exterior (retirado por: $removed_by)"
  fi

  # The residue is really gone: the directory of the context does not exist.
  local run_dir
  run_dir="$(dirname "$receipt")"
  if [ ! -e "$run_dir/context" ]; then
    pass "no queda ningun contexto en el directorio de la corrida ($run_dir)"
  else
    fail "queda el contexto de la corrida eliminada: $run_dir/context"
  fi

  # The verdict of the PRODUCT is not touched by the cleanup of the harness.
  local product positive
  product="$(forge_receipt_read "$receipt" PRODUCT_CLEANUP_RESULT 2>/dev/null || printf 'ABSENT')"
  positive="$(forge_receipt_read "$receipt" POSITIVE_ACCEPTANCE 2>/dev/null || printf 'ABSENT')"
  if [ "$product" = "UNKNOWN" ] && [ "$positive" = "NO" ]; then
    pass "el PRODUCTO de un escenario eliminado queda sin acreditar (UNKNOWN) y NO hay aceptacion positiva"
  else
    fail "el PRODUCTO de un escenario eliminado deberia quedar sin acreditar y SIN aceptacion positiva (limpieza=$product aceptacion=$positive)"
  fi

  # The evidence of the CONTAINMENT is certifiable: the boundary was
  # accredited and the closure was confirmed, even though the product could
  # not be observed.
  local certifiable closure
  certifiable="$(forge_receipt_read "$receipt" CONTAINMENT_EVIDENCE_CERTIFIABLE 2>/dev/null || printf 'ABSENT')"
  closure="$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || printf 'ABSENT')"
  if [ "$certifiable" = "YES" ] && [ "$closure" = "CONFIRMED" ]; then
    pass "la evidencia de la CONTENCION de un escenario eliminado es certificable y el cierre esta confirmado"
  else
    fail "la evidencia de la contencion de un escenario eliminado deberia ser certificable (certificable=$certifiable cierre=$closure)"
    forge_receipt_summary "$receipt" >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# 23. The identities that the containment records are bound to their PROCESS.
#
# The auxiliary record of the containment is a DIAGNOSTIC record: every line
# of it is exactly "<pid> <starttime>", so the identity can never be a bare
# number that a recycled PID could take. This is the property of the historic
# vector m5 ("identidad de las raices"), carried by the observer of the
# private /proc of the current architecture.
# ---------------------------------------------------------------------------
test_the_recorded_identities_carry_their_starttime() {
  local observer_dir="$WORKDIR/observer"
  mkdir -p "$observer_dir"
  if ! forge_write_containment_observer "$observer_dir"; then
    fail "no se pudo preparar el observador del /proc privado"
    return
  fi
  local observer="$observer_dir/forge-containment-observer.sh"
  if [ ! -x "$observer" ]; then
    fail "el observador del /proc privado no es ejecutable"
    return
  fi

  local record="$WORKDIR/identity-record.txt"
  local expected="$WORKDIR/identity-expected.txt"
  rm -f "$record" "$expected"

  # The scenario runs the observer of the PRIVATE /proc and publishes its
  # record OUTSIDE the context, so the battery can read it. It also
  # publishes the identity of the process it leaves alive, read from its own
  # /proc entry: the record has to carry that very starttime.
  local scenario="$WORKDIR/identity-scenario.sh"
  cat > "$scenario" <<'IDENTITY_EOF'
#!/bin/sh
# $1 = observer, $2 = record, $3 = expected identity
observer="$1"
record="$2"
expected="$3"
sleep 20 &
child=$!
sleep 0.3
/bin/sh "$observer" "$$" > "$record" 2>/dev/null || true
ticks=$(sed 's/.*) //' "/proc/$child/stat" 2>/dev/null | awk '{ print $20 }')
printf '%s %s\n' "$child" "$ticks" > "$expected"
exit 0
IDENTITY_EOF
  chmod +x "$scenario"

  local rc=0
  run_entry 20 3 -- /bin/sh "$scenario" "$observer" "$record" "$expected" || rc=$?

  if [ ! -s "$record" ]; then
    fail "el observador del /proc privado no registro ninguna identidad: el control no se ejercito (rc=$rc)"
    return
  fi
  pass "el observador del /proc privado registro identidades dentro de la frontera"

  if [ ! -s "$expected" ]; then
    fail "el escenario no publico la identidad del proceso vivo: el control no se ejercito"
    return
  fi
  local want
  want="$(cat "$expected")"

  local line
  line="$(grep -F "$want" "$record" 2>/dev/null | head -1)"
  if [ -n "$line" ]; then
    pass "la identidad registrada lleva el starttime del proceso vivo ($line)"
  else
    fail "la identidad registrada NO lleva el starttime del proceso vivo (se esperaba '$want'; registro: $(tr '\n' ' ' < "$record"))"
  fi

  # EVERY line of the record is "<pid> <starttime>": an identity by number
  # alone is a corrupted record.
  local malformed=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if ! printf '%s\n' "$entry" | grep -Eq '^[1-9][0-9]* [1-9][0-9]*$'; then
      malformed=$((malformed + 1))
    fi
  done < "$record"
  if [ "$malformed" -eq 0 ]; then
    pass "TODAS las identidades registradas son '<pid> <starttime>' (ninguna es un numero suelto)"
  else
    fail "$malformed identidades registradas NO son '<pid> <starttime>': una identidad por numero suelto puede pertenecer a otro proceso"
  fi
}

# ---------------------------------------------------------------------------
# 25. The AGGREGATE of the declarations of the cleanup of the product never
# masks a failure.
#
# The battery of the suites publishes ONE declaration of the cleanup of the
# product: the WORST CASE of the declarations of its scenarios. An aggregate
# that could turn a FAIL into a PASS would certify a product that did NOT
# clean up, and that is exactly the defect this contract forbids.
#
# The aggregate is a property of its own: it is checked here with the REAL
# aggregator, and the sensitivity harness mutates a COPY of it to prove that
# this check detects an aggregate that masks a failure.
# ---------------------------------------------------------------------------
test_the_aggregate_never_masks_a_failed_declaration() {
  local aggregate="$FORGE_TEST_CLEANUP_AGGREGATE"
  if [ ! -f "$aggregate" ]; then
    fail "no se encuentra el agregador de la limpieza del producto ($aggregate)"
    return
  fi

  local declarations verdict
  declarations="$WORKDIR/aggregate-declarations.tsv"

  aggregate_verdict() {
    python3 "$aggregate" aggregate "$declarations" 2>/dev/null \
      | sed -n '1p' | tr -d '[:space:]'
  }

  # a) A FAIL among PASSes is the aggregate: a failure is NEVER masked.
  printf 'suite-a\tPASS\nsuite-b\tFAIL\nsuite-c\tPASS\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "FAIL" ]; then
    pass "un FAIL entre PASSes se agrega como FAIL: el agregado no maquilla un fallo"
  else
    fail "un FAIL entre PASSes se agrego como '$verdict': el agregado MAQUILLA un fallo del producto"
  fi

  # b) A single FAIL alone is the aggregate.
  printf 'suite-a\tFAIL\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "FAIL" ]; then
    pass "un unico FAIL se agrega como FAIL"
  else
    fail "un unico FAIL se agrego como '$verdict': el agregado MAQUILLA un fallo del producto"
  fi

  # c) An UNKNOWN among PASSes is an UNKNOWN: it is never a PASS.
  printf 'suite-a\tPASS\nsuite-b\tUNKNOWN\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "UNKNOWN" ]; then
    pass "un UNKNOWN entre PASSes se agrega como UNKNOWN: lo no observado nunca es un PASS"
  else
    fail "un UNKNOWN entre PASSes se agrego como '$verdict': lo que no se observo se declara limpio"
  fi

  # d) Every declaration is a PASS -> the aggregate is a PASS.
  printf 'suite-a\tPASS\nsuite-b\tPASS\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "PASS" ]; then
    pass "todas las declaraciones PASS se agregan como PASS"
  else
    fail "todas las declaraciones PASS se agregaron como '$verdict'"
  fi

  # e) A malformed declaration is an UNKNOWN, never a PASS.
  printf 'suite-a\tPASS\nsuite-b\testo-no-es-un-veredicto\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "UNKNOWN" ]; then
    pass "una declaracion malformada se agrega como UNKNOWN: no se inventa un PASS"
  else
    fail "una declaracion malformada se agrego como '$verdict'"
  fi

  # f) An EMPTY set of declarations is an UNKNOWN: nothing was observed.
  : > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "UNKNOWN" ]; then
    pass "un conjunto vacio de declaraciones se agrega como UNKNOWN: no se observo nada"
  else
    fail "un conjunto vacio de declaraciones se agrego como '$verdict'"
  fi

  # g) A declaration that does not apply (a scenario that was NOT EXECUTED)
  #    does not degrade a PASS into an UNKNOWN.
  printf 'suite-a\tPASS\nsuite-b\tNOT_APPLICABLE\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "PASS" ]; then
    pass "una declaracion NOT_APPLICABLE no degrada un PASS: un escenario no ejecutado no se cuenta"
  else
    fail "una declaracion NOT_APPLICABLE degrado el agregado a '$verdict'"
  fi

  # h) A FAIL whose SCOPE says that the declaration does not describe the
  #    product is NOT dropped: a failure can never be hidden by a scope.
  #    The aggregate is a FAIL.
  printf 'suite-a\tFAIL\tNOT_APPLICABLE\nsuite-b\tPASS\tNOT_APPLICABLE\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "FAIL" ]; then
    pass "un FAIL con alcance NOT_APPLICABLE NO se descarta: el fallo del producto no se puede ocultar con el alcance"
  else
    fail "un FAIL con alcance NOT_APPLICABLE se agrego como '$verdict': el alcance occulta un fallo real"
  fi

  # i) A CONTRADICTION is never a PASS: a PASS of the product together with
  #    a FAIL whose scope says the opposite is contradictory evidence.
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tFAIL\tNOT_APPLICABLE\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "FAIL" ]; then
    pass "un PASS de producto junto a un FAIL con alcance NOT_APPLICABLE se agrega como FAIL: la contradiccion nunca es un PASS"
  else
    fail "un PASS de producto junto a un FAIL con alcance NOT_APPLICABLE se agrego como '$verdict': la contradiccion se lavana en un PASS"
  fi

  # j) A verdict that contradicts its scope (the product ran and the
  #    declaration says there was nothing to observe) is an UNKNOWN, never a
  #    PASS.
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tNOT_APPLICABLE\tPRODUCT\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "UNKNOWN" ]; then
    pass "un veredicto NOT_APPLICABLE con alcance PRODUCT se agrega como UNKNOWN: la contradiccion nunca es un PASS"
  else
    fail "un veredicto NOT_APPLICABLE con alcance PRODUCT se agrego como '$verdict'"
  fi

  # k) The aggregate can ONLY WORSEN: adding a declaration never improves
  #    it. The severity is FAIL > UNKNOWN > PASS, and a NOT_APPLICABLE
  #    aggregate means "there was nothing to observe" (it is not a verdict
  #    that can be compared with a PASS).
  local worse base severity_before severity_after
  for worse in FAIL UNKNOWN NOT_APPLICABLE; do
    printf 'suite-a\tPASS\tPRODUCT\n' > "$declarations"
    base="$(aggregate_verdict)"
    printf 'suite-a\tPASS\tPRODUCT\nsuite-b\t%s\tPRODUCT\n' "$worse" > "$declarations"
    verdict="$(aggregate_verdict)"
    severity_before=0
    severity_after=0
    case "$base" in FAIL) severity_before=2 ;; UNKNOWN) severity_before=1 ;; PASS) severity_before=0 ;; *) severity_before=0 ;; esac
    case "$verdict" in FAIL) severity_after=2 ;; UNKNOWN) severity_after=1 ;; PASS) severity_after=0 ;; *) severity_after=0 ;; esac
    if [ "$severity_after" -ge "$severity_before" ]; then
      :
    else
      fail "anadir un veredicto '$worse' a un agregado '$base' lo MEJORo a '$verdict': el agregado solo puede empeorar"
      printf '      (agregado antes: %s, despues: %s)\n' "$base" "$verdict" >&2
    fi
  done
  pass "el agregado solo puede empeorar: anadir un veredicto nunca lo mejora"

  # l) A declaration with a CONTRADICTORY scope is an UNKNOWN: the evidence
  #    cannot be trusted, and it is never a PASS.
  printf 'suite-a\tPASS\tSCOPE_INVENTADO\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "UNKNOWN" ]; then
    pass "una declaracion con un alcance contradictorio se agrega como UNKNOWN"
  else
    fail "una declaracion con un alcance contradictorio se agrego como '$verdict'"
  fi
}

# ---------------------------------------------------------------------------
# 25.ter.bis. A MALFORMED scope NEVER improves a FAILURE.
#
# The validation of the scope used to come BEFORE the preservation of the
# failure: a declaration that reported a FAIL with a scope that is neither
# PRODUCT nor NOT_APPLICABLE was turned into an UNKNOWN, and the aggregate
# of the whole set IMPROVED from FAIL to UNKNOWN. The aggregate must only
# WORSEN: an explicit failure of the product is preserved even when the
# scope that accompanies it is malformed, and the contradiction is still
# DIAGNOSED.
# ---------------------------------------------------------------------------
test_the_aggregate_never_improves_a_failure_with_a_malformed_scope() {
  local aggregate="$FORGE_TEST_CLEANUP_AGGREGATE"
  if [ ! -f "$aggregate" ]; then
    fail "no se encuentra el agregador de la limpieza del producto ($aggregate)"
    return
  fi

  local declarations verdict
  declarations="$WORKDIR/aggregate-malformed-scope.tsv"

  aggregate_verdict() {
    python3 "$aggregate" aggregate "$declarations" 2>/dev/null \
      | sed -n '1p' | tr -d '[:space:]'
  }

  # a) A FAIL with a malformed scope is a FAIL: the aggregate does not
  #    improve because of a scope that cannot be understood.
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tFAIL\tSCOPE_INVENTADO\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "FAIL" ]; then
    pass "un FAIL con un alcance MALFORMADO se agrega como FAIL: el agregado nunca mejora un fallo"
  else
    fail "un FAIL con un alcance MALFORMADO se agrego como '$verdict': el agregado MEJORo un fallo real"
  fi

  # b) The SAME failure with a valid scope is a FAIL too: the malformed
  #    scope does not change the verdict of the failure.
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tFAIL\tPRODUCT\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "FAIL" ]; then
    pass "el mismo FAIL con un alcance VALIDO se agrega como FAIL: el alcance no cambia el veredicto del fallo"
  else
    fail "el mismo FAIL con un alcance VALIDO se agrego como '$verdict'"
  fi

  # c) An EMPTY scope with a FAIL is a FAIL as well.
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tFAIL\t\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  if [ "$verdict" = "FAIL" ]; then
    pass "un FAIL con un alcance VACIO se agrega como FAIL: el agregado nunca mejora un fallo"
  else
    fail "un FAIL con un alcance VACIO se agrego como '$verdict': el agregado MEJORo un fallo real"
  fi

  # d) The contradiction is DIAGNOSED: the diagnostic reaches the standard
  #    error, where it can be seen.
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tFAIL\tSCOPE_INVENTADO\n' > "$declarations"
  python3 "$aggregate" aggregate "$declarations" \
    >"$WORKDIR/aggregate-malformed.out" 2>"$WORKDIR/aggregate-malformed.err" || true
  if grep -q 'contradictoria' "$WORKDIR/aggregate-malformed.err"; then
    pass "el alcance contradictorio se DIAGNOSTICA en la salida de error"
  else
    fail "el alcance contradictorio NO se diagnostico: la evidencia contradictoria debe ser visible"
    sed -n '1,5p' "$WORKDIR/aggregate-malformed.err" | sed 's/^/      /' >&2
  fi

  # e) The aggregate of the malformed scope is NOT BETTER than the aggregate
  #    of the same failure with a valid scope.
  local severity_valid severity_malformed
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tFAIL\tPRODUCT\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  case "$verdict" in FAIL) severity_valid=2 ;; UNKNOWN) severity_valid=1 ;; *) severity_valid=0 ;; esac
  printf 'suite-a\tPASS\tPRODUCT\nsuite-b\tFAIL\tSCOPE_INVENTADO\n' > "$declarations"
  verdict="$(aggregate_verdict)"
  case "$verdict" in FAIL) severity_malformed=2 ;; UNKNOWN) severity_malformed=1 ;; *) severity_malformed=0 ;; esac
  if [ "$severity_malformed" -ge "$severity_valid" ]; then
    pass "un alcance MALFORMADO no empeora el veredicto de un FAIL (severidad $severity_malformed >= $severity_valid)"
  else
    fail "un alcance MALFORMADO MEJORo el veredicto de un FAIL (severidad $severity_malformed < $severity_valid)"
  fi
}

# ---------------------------------------------------------------------------
# 25.bis. The declaration of the cleanup of the PRODUCT requires a
#         SATISFACTORY observation.
#
# The scenario observes the private /proc of the containment with the
# observer. An inventory that was NOT obtained is NOT an empty inventory:
#
#   * an observer that is MISSING leaves the inventory empty without ever
#     having looked at anything;
#   * an observer that FAILS (it could not observe every process it
#     enumerated) leaves the inventory empty for the same reason;
#   * only a SUCCESSFUL observation can say that there was nothing alive.
#
# "No observed" is an UNKNOWN, and an UNKNOWN is never a PASS.
# ---------------------------------------------------------------------------
test_the_cleanup_declaration_requires_a_satisfactory_observation() {
  local scenario helper_dir pointer rc=0 receipt result
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }

  helper_dir="$WORKDIR/observation-helpers"
  mkdir -p "$helper_dir"
  forge_write_containment_killer "$helper_dir" || {
    fail "no se pudo preparar el ayudante de terminacion"
    return
  }

  # The observers of the four cases. They are STUBS on purpose: the case
  # under test is what the scenario does with the exit status of the
  # observer, not the listing of a real /proc.
  cat > "$helper_dir/observer-empty.sh" <<'OBS_EOF'
#!/bin/sh
exit 0
OBS_EOF
  cat > "$helper_dir/observer-leftover.sh" <<'OBS_EOF'
#!/bin/sh
printf '%s\n' "4242 999999"
exit 0
OBS_EOF
  cat > "$helper_dir/observer-incomplete.sh" <<'OBS_EOF'
#!/bin/sh
printf 'forge-containment-observer: 1 procesos enumerados NO se pudieron observar\n' >&2
exit 3
OBS_EOF
  chmod +x "$helper_dir/observer-empty.sh" "$helper_dir/observer-leftover.sh" \
    "$helper_dir/observer-incomplete.sh"

  run_case() {
    local observer="$1" label="$2"
    pointer="$WORKDIR/pointer-$label.txt"
    rm -f "$pointer"
    rc=0
    env FORGE_CONTAINED_RUN_SCENARIO_PATH="/usr/bin:/bin" \
      bash "$ENTRY" \
        --receipt-dir "$RECEIPT_ROOT" \
        --receipt-out "$pointer" \
        --scenario-timeout 20 \
        --close-timeout 3 \
        -- /bin/sh "$scenario" \
           "$observer" "$helper_dir/forge-containment-killer.sh" /bin/true \
      >"$WORKDIR/out-$label.txt" 2>"$WORKDIR/err-$label.txt" || rc=$?
    receipt=""
    [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
    if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
      printf 'NONE'
      return
    fi
    forge_receipt_read "$receipt" PRODUCT_CLEANUP_RESULT 2>/dev/null || printf 'NONE'
  }

  result="$(run_case "$helper_dir/no-existe.sh" missing)"
  if [ "$result" = "UNKNOWN" ]; then
    pass "un observador AUSENTE declara la limpieza del producto como NO OBSERVADA (UNKNOWN), nunca PASS"
  else
    fail "un observador AUSENTE produjo '$result': un inventario que no se obtuvo NO es un inventario vacio"
  fi

  result="$(run_case "$helper_dir/observer-incomplete.sh" incomplete)"
  if [ "$result" = "UNKNOWN" ]; then
    pass "un observador INCOMPLETO declara la limpieza del producto como NO OBSERVADA (UNKNOWN), nunca PASS"
  else
    fail "un observador INCOMPLETO produjo '$result': una observacion incompleta NO es un inventario vacio"
  fi

  result="$(run_case "$helper_dir/observer-leftover.sh" leftover)"
  if [ "$result" = "FAIL" ]; then
    pass "un observador que ve un resto declara la limpieza del producto como FAIL"
  else
    fail "un observador que ve un resto produjo '$result' (se esperaba FAIL)"
  fi

  result="$(run_case "$helper_dir/observer-empty.sh" empty)"
  if [ "$result" = "PASS" ]; then
    pass "un observador SATISFACTORIO que no ve nada declara la limpieza del producto como PASS"
  else
    fail "un observador satisfactorio que no ve nada produjo '$result' (se esperaba PASS)"
  fi

  rm -f "$scenario"
}

# ---------------------------------------------------------------------------
# 25.ter. The observer of the private /proc reports an INCOMPLETE
#          observation instead of an empty listing.
#
# A process that was ENUMERATED and whose stat could NOT be read is not an
# absent process: the observation is incomplete and the observer says so
# (its exit status is 3). A process whose entry is GONE disappeared while it
# was being read and it is legitimately absent.
#
# The observer is exercised with a SYNTHETIC tree of processes (the seam
# FORGE_CONTAINED_RUN_OBSERVER_PROC_ROOT), so that the case is
# deterministic. The containment never sets that variable: the observer
# always reads the PRIVATE /proc of the containment.
# ---------------------------------------------------------------------------
test_the_observer_reports_an_incomplete_observation() {
  local helper_dir observer root rc=0
  helper_dir="$WORKDIR/observer-helpers"
  mkdir -p "$helper_dir"
  forge_write_containment_observer "$helper_dir" || {
    fail "no se pudo preparar el observador del /proc privado"
    return
  }
  observer="$helper_dir/forge-containment-observer.sh"

  # a) A tree with a process whose stat CANNOT be read: it was enumerated
  #    and it could not be observed.
  root="$WORKDIR/fake-proc-incomplete"
  rm -rf "$root"
  python3 - "$root" <<'FAKE_PROC_EOF'
import os
import sys

root = sys.argv[1]
os.makedirs(os.path.join(root, "1"), exist_ok=True)
with open(os.path.join(root, "1", "stat"), "w", encoding="ascii") as handle:
    handle.write("x (y) " + " ".join(["1"] * 20) + "\n")
# The ROOT of the observation is a procfs: it publishes its own `stat`.
with open(os.path.join(root, "stat"), "w", encoding="ascii") as handle:
    handle.write("cpu  1 1 1\n")
# The stat of this process is a DIRECTORY: it cannot be read as a file.
os.makedirs(os.path.join(root, "100", "stat"), exist_ok=True)
FAKE_PROC_EOF
  FORGE_CONTAINMENT_OBSERVER_PROC_ROOT="$root" \
    /bin/sh "$observer" >"$WORKDIR/observer-incomplete.out" 2>"$WORKDIR/observer-incomplete.err" || rc=$?
  if [ "$rc" -eq 3 ]; then
    pass "el observador declara INCOMPLETA una observacion con un proceso enumerado que no se pudo observar (rc=3)"
  else
    fail "el observador NO declaro incompleta la observacion (rc=$rc): un proceso enumerado e inobservable no es un inventario vacio"
    sed -n '1,5p' "$WORKDIR/observer-incomplete.err" | sed 's/^/      /' >&2
  fi

  # b) A tree with a process whose stat CAN be read: the observation is
  #    complete and the listing names the process.
  root="$WORKDIR/fake-proc-complete"
  rm -rf "$root"
  python3 - "$root" <<'FAKE_PROC_EOF'
import os
import sys

root = sys.argv[1]
os.makedirs(os.path.join(root, "1"), exist_ok=True)
with open(os.path.join(root, "1", "stat"), "w", encoding="ascii") as handle:
    handle.write("x (y) " + " ".join(["1"] * 20) + "\n")
with open(os.path.join(root, "stat"), "w", encoding="ascii") as handle:
    handle.write("cpu  1 1 1\n")
os.makedirs(os.path.join(root, "200"), exist_ok=True)
with open(os.path.join(root, "200", "stat"), "w", encoding="ascii") as handle:
    handle.write("x (y) S 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 424242 " + "1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1" + "\n")
FAKE_PROC_EOF
  rc=0
  FORGE_CONTAINMENT_OBSERVER_PROC_ROOT="$root" \
    /bin/sh "$observer" >"$WORKDIR/observer-complete.out" 2>"$WORKDIR/observer-complete.err" || rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^200 424242$' "$WORKDIR/observer-complete.out"; then
    pass "el observador declara COMPLETA una observacion en la que todo se pudo observar"
  else
    fail "el observador no declaro completa una observacion completa (rc=$rc)"
    sed -n '1,5p' "$WORKDIR/observer-complete.out" | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# 25.quater. The observer REFUSES to certify an inventory that it did not
#           obtain.
#
# The observer used to certify an EMPTY inventory when the root it reads
# could not be enumerated at all: the glob did not match a single entry,
# every entry was skipped and the count of the unobservable processes stayed
# at zero, so the observer exited with 0 and printed NOTHING. The scenario
# read that exit status as a COMPLETE observation and published a PASS of
# the cleanup of the product over an inventory that had never been obtained.
#
# The observation must carry POSITIVE EVIDENCE of the observability of the
# root and of its enumeration:
#
#   * the root must EXIST and it must be a directory;
#   * the `stat` of the root must be READABLE (the root is a procfs that
#     publishes its own state);
#   * the enumeration must PRODUCE entries: a glob that matches nothing says
#     nothing about the processes that are alive.
#
# Any failure is an INCOMPLETE observation (exit status 3), NEVER an empty
# inventory. The last case of this check is END TO END: the REAL observer,
# with a root that cannot be enumerated, is the observer of a REAL contained
# scenario, and the declaration of the cleanup of the product must be
# UNKNOWN, never PASS.
# ---------------------------------------------------------------------------
test_the_observer_requires_an_observable_root() {
  local helper_dir observer root rc=0
  helper_dir="$WORKDIR/observer-root-helpers"
  mkdir -p "$helper_dir"
  forge_write_containment_observer "$helper_dir" || {
    fail "no se pudo preparar el observador del /proc privado"
    return
  }
  observer="$helper_dir/forge-containment-observer.sh"

  # a) A root that is NOT a directory (and whose own stat cannot be read):
  #    the observation is INCOMPLETE and the listing is EMPTY.
  rc=0
  FORGE_CONTAINMENT_OBSERVER_PROC_ROOT=/dev/null \
    /bin/sh "$observer" >"$WORKDIR/observer-root-devnull.out" \
    2>"$WORKDIR/observer-root-devnull.err" || rc=$?
  if [ "$rc" -eq 3 ] && [ ! -s "$WORKDIR/observer-root-devnull.out" ]; then
    pass "el observador NO certifica un inventario vacio cuando la raiz observada no es observable (rc=3, sin salida)"
  else
    fail "el observador certifico un inventario vacio con una raiz no observable (rc=$rc, salida: $(wc -c < "$WORKDIR/observer-root-devnull.out") bytes)"
    sed -n '1,5p' "$WORKDIR/observer-root-devnull.err" | sed 's/^/      /' >&2
  fi

  # b) A root whose own `stat` cannot be read: the observation is INCOMPLETE.
  root="$WORKDIR/fake-proc-no-stat"
  rm -rf "$root"
  mkdir -p "$root/1"
  printf 'x (y) %s\n' "$(printf '1 %.0s' {1..20})" > "$root/1/stat"
  rc=0
  FORGE_CONTAINMENT_OBSERVER_PROC_ROOT="$root" \
    /bin/sh "$observer" >"$WORKDIR/observer-root-nostat.out" \
    2>"$WORKDIR/observer-root-nostat.err" || rc=$?
  if [ "$rc" -eq 3 ] && [ ! -s "$WORKDIR/observer-root-nostat.out" ]; then
    pass "el observador NO certifica un inventario vacio cuando el stat de la raiz no se puede leer (rc=3, sin salida)"
  else
    fail "el observador certifico un inventario vacio con un stat de raiz ilegible (rc=$rc)"
    sed -n '1,5p' "$WORKDIR/observer-root-nostat.err" | sed 's/^/      /' >&2
  fi

  # c) A root whose enumeration produces NOTHING: the observation is
  #    INCOMPLETE (a glob that matches nothing does not certify an empty
  #    inventory).
  root="$WORKDIR/fake-proc-empty"
  rm -rf "$root"
  mkdir -p "$root"
  printf 'cpu  1 1 1\n' > "$root/stat"
  rc=0
  FORGE_CONTAINMENT_OBSERVER_PROC_ROOT="$root" \
    /bin/sh "$observer" >"$WORKDIR/observer-root-empty.out" \
    2>"$WORKDIR/observer-root-empty.err" || rc=$?
  if [ "$rc" -eq 3 ] && [ ! -s "$WORKDIR/observer-root-empty.out" ]; then
    pass "el observador NO certifica un inventario vacio cuando la enumeracion no produce entradas (rc=3, sin salida)"
  else
    fail "el observador certifico un inventario vacio con una enumeracion sin entradas (rc=$rc)"
    sed -n '1,5p' "$WORKDIR/observer-root-empty.err" | sed 's/^/      /' >&2
  fi

  # d) END TO END: the REAL observer with an unobservable root is the
  #    observer of a REAL contained scenario. The declaration of the cleanup
  #    of the product must be UNKNOWN, never PASS.
  local scenario pointer receipt result
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  forge_write_containment_killer "$helper_dir" || {
    fail "no se pudo preparar el ayudante de terminacion"
    return
  }
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' '# The REAL observer, but over a root that CANNOT be enumerated.'
    printf 'FORGE_CONTAINMENT_OBSERVER_PROC_ROOT=/dev/null\n'
    printf 'export FORGE_CONTAINMENT_OBSERVER_PROC_ROOT\n'
    printf 'exec /bin/sh %s "$@"\n' "$observer"
  } > "$helper_dir/observer-unobservable-root.sh"
  chmod +x "$helper_dir/observer-unobservable-root.sh"

  pointer="$WORKDIR/pointer-unobservable-root.txt"
  rm -f "$pointer"
  rc=0
  env FORGE_CONTAINED_RUN_SCENARIO_PATH="/usr/bin:/bin" \
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 20 \
      --close-timeout 3 \
      -- /bin/sh "$scenario" \
         "$helper_dir/observer-unobservable-root.sh" \
         "$helper_dir/forge-containment-killer.sh" /bin/true \
    >"$WORKDIR/out-unobservable-root.txt" 2>"$WORKDIR/err-unobservable-root.txt" || rc=$?
  receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  rm -f "$scenario"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la corrida contenida con una raiz no observable no publico recibo (rc=$rc)"
    return
  fi
  result="$(forge_receipt_read "$receipt" PRODUCT_CLEANUP_RESULT 2>/dev/null || printf 'NONE')"
  if [ "$result" = "UNKNOWN" ]; then
    pass "una raiz que no se puede enumerar NO declara PASS de la limpieza del producto: se declara UNKNOWN"
  else
    fail "una raiz que no se puede enumerar declaro '$result' de la limpieza del producto: un inventario que no se obtuvo NO es un inventario vacio"
    forge_receipt_summary "$receipt" >&2 || true
  fi
}

# ---------------------------------------------------------------------------
# 26. The STDIN of the caller reaches the scenario, and a CLOSED stdin falls
#     back EXPLICITLY to EOF.
#
# The entry launches its launcher ASYNCHRONOUSLY, and POSIX assigns /dev/null
# to the standard input of an asynchronous list before any explicit
# redirection: a scenario that reads its stdin (the authorization barrier of
# the V2 bank reads the token of the supervisor from the descriptor 0) would
# receive EOF and the whole chain would abort. The entry therefore saves the
# stdin of the caller in another descriptor BEFORE the launch and connects it
# EXPLICITLY to the bounded `timeout`.
#
# The contract has TWO halves and both are checked here:
#
#   * the STDIN IS INHERITED: the scenario receives the data of the caller;
#   * the fallback is EXPLICIT: when the caller has NO readable stdin, the
#     scenario receives an EOF IMMEDIATELY and its descriptor 0 is
#     /dev/null (an explicit, documented value), never a hang and never a
#     descriptor that belongs to somebody else.
# ---------------------------------------------------------------------------
test_the_scenario_inherits_the_stdin_of_the_caller() {
  local token="STDIN-HEREDADO-4f7c1a"
  local probe="$WORKDIR/stdin-inherited.txt"
  local pointer="$WORKDIR/ptr-stdin.txt"
  rm -f "$probe" "$pointer"

  cat > "$WORKDIR/stdin-inherited.sh" <<'STDIN_EOF'
#!/bin/sh
# Reads ONE line of its standard input and publishes it.
IFS= read -r line
printf '%s\n' "$line" > "$1"
STDIN_EOF
  chmod +x "$WORKDIR/stdin-inherited.sh"

  local rc=0
  printf '%s\n' "$token" | bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$pointer" \
    --scenario-timeout 20 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/stdin-inherited.sh" "$probe" \
    >"$WORKDIR/out-stdin.txt" 2>"$WORKDIR/err-stdin.txt" || rc=$?

  # A raw invocation does NOT declare the cleanup of the product, so the
  # entry returns 70 ("not certifiable"). The point of this check is NOT the
  # RC: it is that the scenario RAN and that it received the data.
  if [ "$rc" -eq 70 ]; then
    pass "una corrida sin marcador de limpieza del producto NO devuelve 0 (rc=70)"
  else
    fail "una corrida sin marcador de limpieza del producto deberia devolver 70 (rc=$rc)"
    sed -n '1,20p' "$WORKDIR/err-stdin.txt" | sed 's/^/      /' >&2
  fi

  if [ ! -s "$probe" ]; then
    fail "el escenario no publico la linea que leyo de su stdin: el control no se ejercito"
    return
  fi
  local observed=""
  IFS= read -r observed < "$probe" || observed=""
  if [ "$observed" = "$token" ]; then
    pass "el escenario RECIBIO el stdin del llamador ($observed)"
  else
    fail "el escenario NO recibio el stdin del llamador (obtenido: '$observed', esperado: '$token')"
  fi
}

test_a_closed_stdin_falls_back_explicitly_to_eof() {
  local probe="$WORKDIR/stdin-closed.txt"
  local pointer="$WORKDIR/ptr-stdin-closed.txt"
  rm -f "$probe" "$pointer" "$probe.fd0"

  cat > "$WORKDIR/stdin-eof.sh" <<'EOF_EOF'
#!/bin/sh
# Reads its standard input to the end and publishes what it got, plus the
# identity of its own descriptor 0.
data=""
IFS= read -r line || true
[ -n "$line" ] && data="$line"
printf 'DATA=[%s]\n' "$data" > "$1"
readlink /proc/self/fd/0 > "$1.fd0" 2>/dev/null || printf 'UNREADABLE\n' > "$1.fd0"
EOF_EOF
  chmod +x "$WORKDIR/stdin-eof.sh"

  # The caller has NO readable stdin: the descriptor 0 is CLOSED.
  local rc=0
  (
    exec 0<&-
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 20 \
      --close-timeout 3 \
      -- /bin/sh "$WORKDIR/stdin-eof.sh" "$probe" \
      >"$WORKDIR/out-stdin-closed.txt" 2>"$WORKDIR/err-stdin-closed.txt"
  ) || rc=$?

  if [ "$rc" -eq 70 ]; then
    pass "una corrida con el stdin CERRADO termina (no se cuelga) y devuelve 70 (rc=70)"
  else
    fail "una corrida con el stdin CERRADO deberia terminar con 70 (rc=$rc)"
    sed -n '1,20p' "$WORKDIR/err-stdin-closed.txt" | sed 's/^/      /' >&2
  fi

  if [ ! -s "$probe" ]; then
    fail "el escenario no publico su lectura con el stdin cerrado: el control no se ejercito"
    return
  fi
  pass "el escenario con el stdin CERRADO leyo hasta el EOF y publico su resultado"

  local data=""
  IFS= read -r data < "$probe" || data=""
  if [ "$data" = "DATA=[]" ]; then
    pass "el stdin CERRADO produce un EOF INMEDIATO y explicito (nada de datos)"
  else
    fail "el stdin CERRADO no produjo un EOF explicito (leido: '$data')"
  fi

  local fd0=""
  [ -s "$probe.fd0" ] && IFS= read -r fd0 < "$probe.fd0" || fd0=""
  if [ "$fd0" = "/dev/null" ]; then
    pass "el fallback del stdin cerrado es EXPLICITO: el descriptor 0 del escenario es /dev/null"
  else
    fail "el fallback del stdin cerrado deberia ser EXPLICITO (/dev/null) y no '$fd0'"
  fi
}

# ---------------------------------------------------------------------------
# 27. The INTERRUPTION is OBSERVED by the PID 1 of the namespace.
#
# The bridge of the interruption does NOT live inside the frontier any more:
# the entry registers the request OUTSIDE the namespace, validates the
# identity and the process group of its direct child and only then forwards
# the signal to the isolated group. The PID 1 reads the request and relays it
# to the bounded `timeout`.
#
# Three facts are checked here, and each one of them can be FALSE:
#
#   * the receipt declares INTERRUPTION_FORWARDING=OBSERVED_BY_PID1: the
#     interruption was OBSERVED by the PID 1 and not merely requested;
#   * the artefact that the PID 1 wrote when it read the request exists in
#     the directory of the run (OUTSIDE the context of the namespace, so the
#     request never crossed the frontier as a signal);
#   * the closure of the interrupted run is CONFIRMED (the launcher was
#     waited for, it returned 0 and the termination of the PID 1 was
#     observed).
# ---------------------------------------------------------------------------
test_the_interruption_is_observed_by_the_pid1() {
  local hb="$WORKDIR/hb-observed-pid1.txt"
  local ready="$WORKDIR/ready-observed-pid1.txt"
  local pointer="$WORKDIR/ptr-observed-pid1.txt"
  rm -f "$hb" "$ready" "$pointer"
  write_heartbeat_scenario "$WORKDIR/heartbeat.sh"

  set -m
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$pointer" \
    --scenario-timeout 60 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/heartbeat.sh" "$hb" "$ready" \
    >"$WORKDIR/out-observed-pid1.txt" 2>"$WORKDIR/err-observed-pid1.txt" &
  local entry_pid=$!
  set +m

  local waited=0
  while [ ! -s "$ready" ] && [ "$waited" -lt 300 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ ! -s "$ready" ]; then
    fail "el escenario de la interrupcion observada no llego a announce que estaba listo"
    kill -KILL "$entry_pid" 2>/dev/null || true
    wait "$entry_pid" 2>/dev/null || true
    return
  fi

  kill -TERM "$entry_pid" 2>/dev/null || true
  local rc=0
  wait "$entry_pid" || rc=$?

  if [ "$rc" -eq 143 ]; then
    pass "una interrupcion SIGTERM devuelve RC 143"
  else
    fail "una interrupcion SIGTERM deberia devolver RC 143 (rc=$rc)"
  fi

  local receipt=""
  [ -s "$pointer" ] && IFS= read -r receipt < "$pointer"
  if [ -z "$receipt" ] || [ ! -s "$receipt" ]; then
    fail "la interrupcion no dejo recibo: la evidencia no puede faltar"
    return
  fi

  local forwarding
  forwarding="$(forge_receipt_read "$receipt" INTERRUPTION_FORWARDING 2>/dev/null || printf 'ABSENT')"
  if [ "$forwarding" = "OBSERVED_BY_PID1" ]; then
    pass "el reenvio de la interrupcion queda OBSERVADO POR EL PID 1 (INTERRUPTION_FORWARDING=OBSERVED_BY_PID1)"
  else
    fail "el reenvio de la interrupcion deberia quedar OBSERVADO POR EL PID 1 (valor: $forwarding)"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  # The artefact of the observation: the PID 1 wrote it when it read the
  # request that the entry published OUTSIDE the namespace.
  local run_dir observed=''
  run_dir="$(dirname "$receipt")"
  if [ -s "$run_dir/pid1.interruption.status" ]; then
    IFS= read -r observed < "$run_dir/pid1.interruption.status" || observed=''
  fi
  if [ "$observed" = "SIGTERM" ]; then
    pass "el PID 1 dejo constancia de la interrupcion que leyo ($observed)"
  else
    fail "el PID 1 no dejo constancia de la interrupcion que leyo (valor: '$observed')"
  fi

  # The request itself was published OUTSIDE the frontier: it lives in the
  # directory of the run, never in the context of the namespace.
  if [ -s "$run_dir/interruption.request" ] \
    && [ ! -e "$run_dir/context/interruption.request" ]; then
    pass "la solicitud de la interrupcion se publico FUERA de la frontera"
  else
    fail "la solicitud de la interrupcion deberia publishedse FUERA de la frontera"
  fi

  # The closure of the interrupted run: the launcher was waited for, it
  # returned 0 and the effective termination of the PID 1 was observed.
  if [ "$(forge_receipt_read "$receipt" CLOSURE 2>/dev/null || true)" = "CONFIRMED" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_WAIT_COMPLETED 2>/dev/null || true)" = "YES" ] \
    && [ "$(forge_receipt_read "$receipt" LAUNCHER_RC 2>/dev/null || true)" = "0" ] \
    && [ "$(forge_receipt_read "$receipt" PID1_COMPLETION_OBSERVED 2>/dev/null || true)" = "PASS" ] \
    && [ "$(forge_receipt_read "$receipt" RECEIPT_COMPLETENESS 2>/dev/null || true)" = "COMPLETE" ]; then
    pass "el cierre de la interrupcion queda CONFIRMADO: espera, RC 0 y terminacion observada"
  else
    fail "el cierre de la interrupcion deberia quedar CONFIRMADO"
    forge_receipt_summary "$receipt" >&2 || true
  fi

  if heartbeat_is_frozen "$hb" 2; then
    pass "el entorno contenido TERMINO DE VERDAD tras la interrupcion"
  else
    fail "el entorno contenido SIGUE VIVO tras la interrupcion"
  fi
}

# ---------------------------------------------------------------------------
# 28. The infrastructure of the HARNESS does NOT live inside the frontier.
#
# The scaffolding that the entry creates around the scenario (the scenario
# itself, the `timeout` that bounds it and the PID 1 of the namespace) is
# alive BY CONSTRUCTION while the scenario runs: it is NOT a leftover of the
# product. The observation of the cleanup (the criterion of the case CLEAN-1)
# excludes it BY ANCESTRY.
#
# The check is made FROM INSIDE the frontier and it is INDEPENDENT of the
# official observer: it computes the chain of ancestors of the scenario by
# itself and it lists every OTHER live process of the private /proc. A
# process that is neither the PID 1 nor an ancestor of the scenario is
# INFRASTRUCTURE INSIDE THE FRONTIER (a bridge, a relay, a polling helper):
# the scenario of the product never creates one, so its presence is a defect
# of the arnés.
#
# It reads only namespace links and its own /proc entries: no process of the
# host is enumerated and no command line is read.
# ---------------------------------------------------------------------------
test_the_harness_infrastructure_is_not_inside_the_frontier() {
  local report="$WORKDIR/infrastructure-report.txt"
  rm -f "$report"

  cat > "$WORKDIR/infrastructure.sh" <<'INFRA_EOF'
#!/bin/sh
# Lists the processes of the PRIVATE /proc that are neither the PID 1 of the
# namespace nor an ANCESTOR of this scenario. Only shell builtins are used:
# a helper that spawned a process would see its own children in the listing.
report="$1"
self=$$

PPID_OF=""
read_ppid() {
  PPID_OF=""
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done < "/proc/$1/stat" 2>/dev/null
  [ -n "$line" ] || return 1
  rest=${line##*)}
  set -f
  set -- $rest
  set +f
  [ "$#" -ge 2 ] || return 1
  PPID_OF=$2
  return 0
}

excluded=" $self "
ancestor=""
if read_ppid "$self"; then
  ancestor=$PPID_OF
fi
hops=0
while [ -n "$ancestor" ] && [ "$ancestor" -gt 1 ] && [ "$hops" -lt 64 ]; do
  excluded="$excluded$ancestor "
  next=""
  if read_ppid "$ancestor"; then
    next=$PPID_OF
  fi
  ancestor=$next
  hops=$((hops + 1))
done

foreign=""
count=0
for entry in /proc/[0-9]*; do
  pid=${entry#/proc/}
  [ "$pid" = "1" ] && continue
  case "$excluded" in
    *" $pid "*) continue ;;
  esac
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done < "$entry/stat" 2>/dev/null
  [ -n "$line" ] || continue
  rest=${line##*)}
  set -f
  set -- $rest
  set +f
  [ "$#" -ge 2 ] || continue
  [ "$1" = "Z" ] && continue
  foreign="$foreign$pid "
  count=$((count + 1))
done

{
  printf 'ANCESTORS=%s\n' "$(printf '%s' "$excluded" | wc -w)"
  printf 'FOREIGN=%s\n' "$count"
  printf 'FOREIGN_LIST=%s\n' "$foreign"
} > "$report"
exit 0
INFRA_EOF
  chmod +x "$WORKDIR/infrastructure.sh"

  local rc=0
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$WORKDIR/ptr-infrastructure.txt" \
    --scenario-timeout 20 \
    --close-timeout 3 \
    -- /bin/sh "$WORKDIR/infrastructure.sh" "$report" \
    >"$WORKDIR/out-infrastructure.txt" 2>"$WORKDIR/err-infrastructure.txt" || rc=$?

  if [ ! -s "$report" ]; then
    fail "la sonda de la infraestructura no dejo informe (rc=$rc)"
    sed -n '1,20p' "$WORKDIR/err-infrastructure.txt" | sed 's/^/      /' >&2
    return
  fi
  pass "la sonda de la infraestructura se ejecuto DENTRO de la frontera"

  local ancestors foreign list
  ancestors="$(awk -F= '$1 == "ANCESTORS" { print $2; exit }' "$report")"
  foreign="$(awk -F= '$1 == "FOREIGN" { print $2; exit }' "$report")"
  list="$(awk -F= '$1 == "FOREIGN_LIST" { print $2; exit }' "$report")"

  # The scaffolding IS inside the frontier: the scenario and the `timeout`
  # that bounds it are its ancestors. They are excluded BY ANCESTRY.
  if [ "${ancestors:-0}" -ge 2 ]; then
    pass "el andamiaje del arnes esta DENTRO de la frontera y se excluye por ANTECASADO ($ancestors antepasados)"
  else
    fail "el andamiaje del arnes deberia estar dentro de la frontera ($ancestors antepasados)"
  fi

  if [ "${foreign:-1}" -eq 0 ]; then
    pass "NO hay infraestructura del arnes dentro de la frontera (ni puente, ni relevo, ni sonda)"
  else
    fail "hay $foreign procesos del arnes DENTRO de la frontera (PIDs: ${list:-desconocidos}): el andamiaje no es producto"
  fi
}

# ---------------------------------------------------------------------------
# 29.bis. The OFFICIAL observer of the cleanup reports an INCOMPLETE
#          observation instead of an empty inventory.
#
# A process that was ENUMERATED and could not be OBSERVED (its stat could
# not be read) is not an absent process: the observation is incomplete and
# it is an UNKNOWN. A process whose /proc entry is GONE disappeared while
# it was being read: that one is legitimately absent.
# ---------------------------------------------------------------------------
test_the_official_observer_reports_an_incomplete_observation() {
  local probe="$FORGE_TEST_CLEANUP_PROBE"
  if [ ! -f "$probe" ]; then
    fail "no se encuentra el observador oficial de la limpieza del producto ($probe)"
    return
  fi

  local out rc=0
  out="$(python3 - "$probe" <<'PY'
import importlib.util
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("forge_run_all_cleanup", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


LIVE = {"state": "S", "ppid": 1, "ticks": "12345"}
ZOMBIE = {"state": "Z", "ppid": 1, "ticks": "12346"}

readable = {"400": LIVE, "500": ZOMBIE}
existing = {"100"}


def fake_stat_fields(pid):
    return readable.get(str(pid))


def fake_entry_state(pid, proc_root="/proc"):
    # The state of the ENTRY: it exists (it could not be READ) or it is
    # GONE (the process disappeared while it was being read).
    if str(pid) in existing:
        return mod.PRESENT
    return mod.ABSENT


original_stat = mod.stat_fields
original_entry = mod.entry_state
mod.stat_fields = fake_stat_fields
mod.entry_state = fake_entry_state
try:
    # 100 was enumerated and its stat could NOT be read, and its entry still
    # exists: the observation is INCOMPLETE.
    leftovers, unobservable = mod.observe_entries(["100", "400", "500"], set())
    check(unobservable == [100], "un proceso enumerado que no se puede observar debe ser INCOMPLETO (%r)" % (unobservable,))
    check(leftovers == [400], "un proceso vivo enumerado es un resto (%r)" % (leftovers,))

    # 200 was enumerated, its stat could not be read and its entry is GONE:
    # it disappeared while it was being read and it is legitimately absent.
    existing.clear()
    leftovers, unobservable = mod.observe_entries(["200", "400"], set())
    check(unobservable == [], "un proceso que desaparecio no es una observacion incompleta (%r)" % (unobservable,))
    check(leftovers == [400], "el resto vivo sigue siendo un resto (%r)" % (leftovers,))
finally:
    mod.stat_fields = original_stat
    mod.entry_state = original_entry

for message in failures:
    sys.stdout.write("FAIL %s\n" % message)
sys.exit(1 if failures else 0)
PY
)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "el observador oficial distingue un proceso que desaparecio de un proceso que no se pudo observar"
  else
    fail "el observador oficial NO distingue un proceso que desaparecio de uno que no se pudo observar"
    printf '%s\n' "$out" | sed -n '1,10p' | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# 29.ter. An ABSENCE is CONFIRMED; an ERROR of observation is NOT an absence.
#
# The observer used to ask the existence of the entry with
# `os.path.exists()`, which answers False for a PermissionError as well as
# for an entry that is not there. A process that was ENUMERATED and whose
# stat could NOT be read was therefore discarded as a process that had
# disappeared, whenever the existence of its entry could not be confirmed
# either: the observation was published as a COMPLETE one (an empty
# inventory) over a process that nobody had observed.
#
# The three states are DISTINCT:
#
#   * ABSENT: the entry is NOT there (the process disappeared while it was
#     being read). It is the ONLY state that is a disappearance.
#   * PRESENT: the entry is there.
#   * UNOBSERVABLE: the state of the entry could NOT be read (a permission
#     error, a transient failure). It is an ERROR OF OBSERVATION and it
#     makes the observation INCOMPLETE, never an absence.
# ---------------------------------------------------------------------------
test_the_absence_of_a_process_is_confirmed_and_never_inferred() {
  local probe="$FORGE_TEST_CLEANUP_PROBE"
  if [ ! -f "$probe" ]; then
    fail "no se encuentra el observador oficial de la limpieza del producto ($probe)"
    return
  fi

  local out rc=0
  out="$(python3 - "$probe" <<'PY'
import importlib.util
import os
import shutil
import sys
import tempfile

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("forge_run_all_cleanup", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


root = tempfile.mkdtemp(prefix="forge-absence-")
try:
    # a) A CONFIRMED absence: the entry is not there at all.
    state = mod.entry_state(999999, proc_root=root)
    check(state == mod.ABSENT,
          "una entrada que no existe es una AUSENCIA CONFIRMADA (%r)" % (state,))

    # b) An ERROR OF OBSERVATION: the root is not a directory, so the state
    #    of the entry cannot be read. It is NOT an absence.
    not_a_root = os.path.join(root, "not-a-directory")
    with open(not_a_root, "w", encoding="ascii") as handle:
        handle.write("x\n")
    state = mod.entry_state(1234, proc_root=not_a_root)
    check(state == mod.UNOBSERVABLE,
          "un error de observacion NO es una ausencia (%r)" % (state,))
    check(state != mod.ABSENT,
          "un error de observacion se publico como una AUSENCIA (%r)" % (state,))

    # c) The same, with a REAL permission error: the entry is there and
    #    the traversal of its parent cannot be done, so its state cannot be
    #    read.
    if os.geteuid() != 0:
        locked = os.path.join(root, "locked")
        os.makedirs(locked, exist_ok=True)
        os.makedirs(os.path.join(locked, "4242"), exist_ok=True)
        os.chmod(locked, 0o000)
        state = mod.entry_state(4242, proc_root=locked)
        os.chmod(locked, 0o700)
        check(state == mod.UNOBSERVABLE,
              "una entrada que no se puede leer NO es una ausencia (%r)" % (state,))
        check(state != mod.ABSENT,
              "un error de permisos se publico como una AUSENCIA (%r)" % (state,))

    # d) observe_entries: an entry whose state could NOT be read is an
    #    UNOBSERVABLE process, NEVER a disappearance.
    LIVE = {"state": "S", "ppid": 1, "ticks": "12345"}

    def fake_stat_fields(pid):
        return LIVE if str(pid) == "400" else None

    def fake_entry_state(pid, proc_root="/proc"):
        if str(pid) == "100":
            return mod.UNOBSERVABLE
        return mod.ABSENT

    leftovers, unobservable = mod.observe_entries(
        ["100", "400"], set(), stat_reader=fake_stat_fields, entry_reader=fake_entry_state)
    check(unobservable == [100],
          "un proceso enumerado cuyo estado no se pudo leer es INCOMPLETO (%r)" % (unobservable,))
    check(leftovers == [400], "un proceso vivo enumerado es un resto (%r)" % (leftovers,))

    # e) observe_entries: a CONFIRMED absence is the only disappearance.
    def confirmed_absence(pid, proc_root="/proc"):
        return mod.ABSENT

    leftovers, unobservable = mod.observe_entries(
        ["100", "400"], set(), stat_reader=fake_stat_fields, entry_reader=confirmed_absence)
    check(unobservable == [],
          "una ausencia confirmada NO es una observacion incompleta (%r)" % (unobservable,))
    check(leftovers == [400], "el resto vivo sigue siendo un resto (%r)" % (leftovers,))
finally:
    shutil.rmtree(root, ignore_errors=True)

for message in failures:
    sys.stdout.write("FAIL %s\n" % message)
sys.exit(1 if failures else 0)
PY
)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "el observador oficial distingue la AUSENCIA CONFIRMADA del ERROR DE OBSERVACION"
  else
    fail "el observador oficial NO distingue la AUSENCIA CONFIRMADA del ERROR DE OBSERVACION"
    printf '%s\n' "$out" | sed -n '1,10p' | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# 31. The battery of the suites uses NO NETWORK.
#
# A fixture that opens a socket and listens on the loopback interface is
# activity of NETWORK, even when the address is 127.0.0.1: the prohibition
# of the network of this lot is not a prohibition of the traffic to the
# outside only.
#
# The check is STATIC on purpose: it scans the tree of the suites for the
# primitives of the network. The tree that is scanned is the tree of the
# helper under test, so that the sensitivity harness can point the battery
# at a mutated copy and see the detector react.
# ---------------------------------------------------------------------------
test_the_battery_of_the_suites_uses_no_network() {
  local scanner="$FORGE_TEST_NETWORK_SCANNER"
  if [ ! -f "$scanner" ]; then
    fail "no se encuentra el escaner de primitivas de red ($scanner)"
    return
  fi
  local tree
  tree="$(dirname "$FORGE_TEST_ISOLATION")"

  local hits rc=0
  hits="$(python3 "$scanner" "$tree" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "la bateria de las suites NO usa la red: ningun fichero del arbol abre un socket ni hace una peticion"
  else
    fail "la bateria de las suites USA la red: hay primitivas de red en el arbol de las suites"
    printf '%s\n' "$hits" | sed -n '1,10p' | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# 30. The CLEAN-1 excludes the harness BY ANCESTRY and STILL detects a real
#     leftover.
#
# The exclusion of the scaffolding must not become a HOLE: a descendant that
# the product leaves behind (reparented to the PID 1 of the namespace) is
# NOT an ancestor and MUST be detected. The check runs the OFFICIAL observer
# of the cleanup (tests/forge_run_all_cleanup.py) from INSIDE the frontier:
# it must report a leftover while the descendant lives and PASS once the
# descendant is gone.
# ---------------------------------------------------------------------------
test_the_clean_1_excludes_the_harness_by_ancestry_and_still_detects_a_leftover() {
  local probe="$FORGE_TEST_CLEANUP_PROBE"
  if [ ! -f "$probe" ]; then
    fail "no se encuentra el observador oficial de la limpieza del producto ($probe)"
    return
  fi

  local report="$WORKDIR/clean1-report.txt"
  local pidfile="$WORKDIR/clean1-leftover.pid"
  rm -f "$report" "$pidfile"

  cat > "$WORKDIR/clean1.sh" <<'CLEAN1_EOF'
#!/bin/sh
# $1 = observer of the cleanup, $2 = report, $3 = file of the descendant
observer="$1"
report="$2"
pidfile="$3"

# A descendant that outlives its parent and that nobody registered: the
# `setsid --fork` writer is reparented to the PID 1 of the namespace. It is
# a SINGLE process (`exec sleep`): a descendant with children would leave
# transient children in the namespace and the observation could be satisfied
# by one of them instead of by the descendant itself.
setsid --fork /bin/sh -c 'printf "%s\n" "$$" > "$1"; exec sleep 3600' \
  sh "$pidfile" >/dev/null 2>&1

# The official observer of the cleanup, WHILE the descendant is alive.
python3 "$observer" probe > "$report.first" 2>/dev/null || true

# The identity of the descendant is verified IMMEDIATELY BEFORE the signal.
pid=""
IFS= read -r pid < "$pidfile" 2>/dev/null || pid=""
ticks=""
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done < "/proc/$pid/stat" 2>/dev/null
  rest=${line##*)}
  set -f
  set -- $rest
  set +f
  [ "$#" -ge 20 ] && ticks=${20}
fi
again=""
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
  line=""
  while IFS= read -r chunk; do
    line="$chunk"
  done < "/proc/$pid/stat" 2>/dev/null
  rest=${line##*)}
  set -f
  set -- $rest
  set +f
  [ "$#" -ge 20 ] && again=${20}
fi
if [ -n "$ticks" ] && [ "$ticks" = "$again" ]; then
  kill -TERM "$pid" 2>/dev/null || true
fi

# The transient children of the descendant need a moment to disappear.
sleep 1

# The official observer of the cleanup, once the descendant is gone.
python3 "$observer" probe > "$report.second" 2>/dev/null || true

{
  printf 'LEFTOVER_PID=%s\n' "$pid"
  printf 'FIRST=%s\n' "$(sed -n '1p' "$report.first" 2>/dev/null)"
  printf 'FIRST_REST=%s\n' "$(sed -n '2,$p' "$report.first" 2>/dev/null | tr '\n' ' ')"
  printf 'SECOND=%s\n' "$(sed -n '1p' "$report.second" 2>/dev/null)"
} > "$report"
exit 0
CLEAN1_EOF
  chmod +x "$WORKDIR/clean1.sh"

  local rc=0
  bash "$ENTRY" \
    --receipt-dir "$RECEIPT_ROOT" \
    --receipt-out "$WORKDIR/ptr-clean1.txt" \
    --scenario-timeout 30 \
    --close-timeout 5 \
    -- /bin/sh "$WORKDIR/clean1.sh" "$probe" "$report" "$pidfile" \
    >"$WORKDIR/out-clean1.txt" 2>"$WORKDIR/err-clean1.txt" || rc=$?

  if [ ! -s "$report" ]; then
    fail "la sonda de la CLEAN-1 no dejo informe (rc=$rc)"
    sed -n '1,20p' "$WORKDIR/err-clean1.txt" | sed 's/^/      /' >&2
    return
  fi

  local leftover first first_rest second
  leftover="$(awk -F= '$1 == "LEFTOVER_PID" { print $2; exit }' "$report")"
  first="$(awk -F= '$1 == "FIRST" { print $2; exit }' "$report")"
  first_rest="$(awk -F= '$1 == "FIRST_REST" { print $2; exit }' "$report")"
  second="$(awk -F= '$1 == "SECOND" { print $2; exit }' "$report")"

  if [ -z "$leftover" ] || [ "$leftover" = " " ]; then
    fail "el descendiente desligado no publico su PID: el control no se ejercito"
    return
  fi
  pass "el descendiente desligado (reparented al PID 1) se creo dentro de la frontera (pid=$leftover)"

  if [ "$first" = "FAIL" ]; then
    pass "la CLEAN-1 DETECTA el descendiente que el producto dejo vivo (FAIL, PIDs: ${first_rest:-desconocidos})"
  else
    fail "la CLEAN-1 no detecto el descendiente que el producto dejo vivo (veredicto: '$first')"
  fi

  # The observation has to name THE DESCENDANT, not merely report a failure:
  # a leftover that the product leaves behind is reparented to the PID 1 of
  # the namespace, and a CLEAN-1 that "contours" the scaffolding (excluding
  # every child of the PID 1) would hide exactly that one. The assertion is
  # on the IDENTITY of the leftover, so the detector cannot be satisfied by
  # an unrelated transient process.
  case " $first_rest " in
    *" $leftover "*)
      pass "la CLEAN-1 nombra al descendiente dejo vivo (pid=$leftover): la exclusion del andamiaje no es un agujero"
      ;;
    *)
      fail "la CLEAN-1 no nombro al descendiente que el producto dejo vivo (pid=$leftover, lista: '${first_rest:-vacia}')"
      ;;
  esac

  if [ "$second" = "PASS" ]; then
    pass "la CLEAN-1 vuelve a PASS cuando el descendiente ya no vive: la exclusion del andamiaje NO es un agujero"
  else
    fail "la CLEAN-1 deberia volver a PASS sin el descendiente (veredicto: '$second')"
  fi
}

# ---------------------------------------------------------------------------
# 30. The contract of the bank for the scenario that is ELIMINATED.
#
# The scenario `no-pidfd-hang` hangs on purpose: without pidfd, the bounded
# close of the containment entry applies (TERM and then KILL) and the suite
# is ELIMINATED with it. Two DIFFERENT values are in play and they must not
# be confused:
#
#   * the DECLARED expectation of the runner (EXPECTED_SUITE_RC=NONE) says
#     that this invocation can never be a POSITIVE ACCEPTANCE: the process
#     that had to declare the cleanup of the product was eliminated with the
#     group. It is a statement about the ACCEPTANCE;
#   * the OBSERVED RC of the eliminated suite is -9 (the convention of the
#     shell: a process killed by SIGKILL is -9). It is a statement about the
#     TERMINATION, and it is the POSITIVE evidence of the contract of the
#     scenario: the close applied by the entry killed the group.
#
# The expectation of the CI verifier (tools/ci/v2-safety.sh) must therefore be
# -9 and NOT "None": "None" would certify the ABSENCE of an RC (which is not
# applicable, because the entry always records a numeric SCENARIO_RC) and it
# would not prove that the group was killed. The guarantee itself is checked
# apart: the real timeout, the init of the namespace gone, the group without
# members, no survivors and the teardown acreditado.
# ---------------------------------------------------------------------------
test_the_bank_contract_of_the_eliminated_scenario_expects_the_sigkill() {
  local verifier="$FORGE_TEST_V2_CI_VERIFIER"
  local runner="$FORGE_ROOT/tests/forge_v2_safety_scenarios.sh"
  if [ ! -f "$verifier" ]; then
    fail "no se encuentra el verificador del banco V2 ($verifier)"
    return
  fi
  if [ ! -f "$runner" ]; then
    fail "no se encuentra el runner de los escenarios del banco V2 ($runner)"
    return
  fi

  local line
  line="$(grep -E '"no-pidfd-hang": \{"supervisor"' "$verifier" 2>/dev/null | head -n 1)"
  if [ -z "$line" ]; then
    fail "el verificador del banco V2 no declara el contrato de 'no-pidfd-hang'"
    return
  fi
  pass "el verificador del banco V2 declara el contrato de 'no-pidfd-hang'"

  local expected
  expected="$(printf '%s\n' "$line" | sed -n 's/.*"suite": \([^,]*\),.*/\1/p')"
  if [ "$expected" = "-9" ]; then
    pass "el RC esperado de la suite eliminada es -9 (terminada por SIGKILL): el valor OBSERVADO es el correcto"
  else
    fail "el RC esperado de la suite eliminada deberia ser -9 (terminada por SIGKILL) y no '$expected'"
  fi

  # The expectation must NOT be "None": it would certify the absence of an RC
  # (which the entry never produces) instead of the termination by SIGKILL.
  case "$expected" in
    None|NONE|"")
      fail "el contrato de la suite eliminada no puede declarar 'None': el RC de la suite SI es observable"
      ;;
    *)
      pass "el contrato de la suite eliminada NO declara 'None': el RC eliminado es observable"
      ;;
  esac

  # The runner declares NONE for the POSITIVE ACCEPTANCE of that invocation:
  # the two meanings are different and the runner keeps its own declaration.
  if grep -A 3 '^  no-pidfd-hang)' "$runner" 2>/dev/null | grep -q 'EXPECTED_SUITE_RC=NONE'; then
    pass "el runner declara NONE para la ACEPTACION POSITIVA de la invocacion (significado distinto al del RC observado)"
  else
    fail "el runner deberia declarar EXPECTED_SUITE_RC=NONE para la invocacion eliminada"
  fi

  # The GUARANTEE of the scenario is checked apart, and it is checked in the
  # verifier (the teardown) and in the runner (the semantic verdict).
  local missing=""
  for needle in '"timed_out": True' 'namespace_init_gone_after' 'members_of_own_process_group' \
    'survivors_in_private_namespace' 'teardown_ok'; do
    grep -q "$needle" "$verifier" 2>/dev/null || missing="$missing [$needle]"
  done
  if [ -z "$missing" ]; then
    pass "el verificador comprueba la GARANTIA del escenario (timeout real, init eliminado, grupo sin miembros, sin supervivientes)"
  else
    fail "el verificador no comprueba:$missing"
  fi

  local missing_runner=""
  for needle in 'el init del namespace y su grupo de procesos quedaron terminados y verificados' \
    'la limpieza exterior funciono SIN pidfd'; do
    grep -q "$needle" "$runner" 2>/dev/null || missing_runner="$missing_runner [$needle]"
  done
  if [ -z "$missing_runner" ]; then
    pass "el runner comprueba que el cierre lo aplico la entrada y que el init y el grupo quedaron terminados"
  else
    fail "el runner no comprueba:$missing_runner"
  fi
}

# ---------------------------------------------------------------------------
# 41. The ADMISSION gate requires the KERNEL handle of the invoking
#     namespace.
#
# The gate does not trust the receipt: it reads the namespace of the
# INVOKER from a descriptor that only the KERNEL can provide (the descriptor
# 8 that the entry opens on /proc/self/ns/pid before its `unshare`) and it
# compares it with the namespace of the process. A receipt, a marker or a
# planted file cannot create that descriptor, so a planted evidence cannot
# pass the gate.
#
# The three cases are REAL invocations of the gate INSIDE the containment:
#
#   (a) the descriptor is inherited from the entry -> the gate ADMITS;
#   (b) the direct invoker has NO descriptor 8      -> the gate DENIES (78);
#   (c) the descriptor 8 points to the CURRENT namespace -> DENIES (78).
#
# The planted receipt of the cases is coherent on purpose: the identifier
# matches the directory, the path of the receipt matches, the accreditation
# is PASS and the namespace variables are the effective ones. The ONLY
# difference between the admitted case and the denied ones is the kernel
# handle.
# ---------------------------------------------------------------------------
test_the_admission_requires_the_kernel_handle_of_the_invoker() {
  local guard="$FORGE_TEST_ADMISSION_GUARD"
  if [ ! -f "$guard" ]; then
    fail "no se encuentra la puerta de admision ($guard)"
    return
  fi

  local probe="$WORKDIR/admission-probe.sh"
  cat > "$probe" <<'PROBE_EOF'
#!/bin/sh
# Runs the admission gate under three conditions and records its exit code.
# The planted receipt is coherent: the identifier matches the directory of
# the run, the path of the receipt matches, the accreditation is PASS and the
# namespace variables are the EFFECTIVE ones of this process.
set -u
guard="$1"
out="$2"
receipt_root=/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs
run_id="run-admission-fixture-$$"
run_dir="$receipt_root/$run_id"
mkdir -p "$run_dir" || exit 1
receipt="$run_dir/receipt.txt"
pid_ns="$(readlink /proc/self/ns/pid 2>/dev/null || echo UNKNOWN)"
mnt_ns="$(readlink /proc/self/ns/mnt 2>/dev/null || echo UNKNOWN)"
{
  printf 'IDENTIFIER=%s\n' "$run_id"
  printf 'RECEIPT_PATH=%s\n' "$receipt"
  printf 'ACCREDITATION=PASS\n'
  printf 'CLOSURE=CONFIRMED\n'
} > "$receipt" || exit 1
printf 'PASS\n' > "$run_dir/accreditation.status" || exit 1

run_gate() {
  FORGE_CONTAINED_RUN_RECEIPT="$receipt" \
  FORGE_CONTAINED_RUN_ID="$run_id" \
  FORGE_CONTAINED_RUN_ACCREDITATION_FILE="$run_dir/accreditation.status" \
  FORGE_CONTAINED_RUN_PID_NAMESPACE="$pid_ns" \
  FORGE_CONTAINED_RUN_MOUNT_NAMESPACE="$mnt_ns" \
  FORGE_PRODUCT_CLEANUP_RESULT_FILE="$run_dir/product-cleanup.result" \
  /bin/bash "$guard" >/dev/null 2>&1
  printf '%s=%s\n' "$1" "$?" >> "$out"
}

# (a) The descriptor that the entry opened is inherited and it references
#     the INVOKING namespace, which is NOT the current one.
run_gate positive

# (b) The direct invoker has NO descriptor 8: there is no kernel handle.
exec 8<&-
run_gate no_descriptor

# (c) The descriptor 8 references the CURRENT namespace: the process did
#     NOT cross a namespace boundary.
exec 8</proc/self/ns/pid
run_gate current_namespace

# The planted receipt is a fixture of this probe: it is removed with the
# evidence it belongs to.
rm -rf "$run_dir"
exit 0
PROBE_EOF
  chmod +x "$probe"

  local scenario out rc=0
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  out="$WORKDIR/admission-results.txt"
  rm -f "$out"
  forge_contained_run "$scenario" /bin/sh "$probe" "$guard" "$out" \
    >"$WORKDIR/admission.out" 2>"$WORKDIR/admission.err" || rc=$?
  rm -f "$scenario"

  if [ "$rc" -ne 0 ]; then
    fail "la corrida contenida de la puerta de admision no termino correctamente (rc=$rc)"
    sed -n '1,20p' "$WORKDIR/admission.err" | sed 's/^/      /' >&2
    return
  fi
  pass "la corrida contenida de la puerta de admision termino correctamente (rc=0)"

  if [ ! -s "$out" ]; then
    fail "la sonda de admision no produjo ningun resultado"
    return
  fi

  local value
  value="$(sed -n 's/^positive=//p' "$out" | head -1)"
  if [ "$value" = "0" ]; then
    pass "la puerta ADMITE la invocacion que conserva el handle del kernel (rc=0)"
  else
    fail "la puerta denego una invocacion con el handle del kernel (rc=$value)"
  fi

  value="$(sed -n 's/^no_descriptor=//p' "$out" | head -1)"
  if [ "$value" = "78" ]; then
    pass "la puerta RECHAZA (rc=78) un recibo plantado SIN el handle del kernel"
  else
    fail "la puerta NO rechazo un recibo plantado sin el handle del kernel (rc=$value; se esperaba 78)"
  fi

  value="$(sed -n 's/^current_namespace=//p' "$out" | head -1)"
  if [ "$value" = "78" ]; then
    pass "la puerta RECHAZA (rc=78) un handle 8 que apunta al namespace ACTUAL"
  else
    fail "la puerta NO rechazo un handle 8 que apunta al namespace actual (rc=$value; se esperaba 78)"
  fi
}

# ---------------------------------------------------------------------------
# 42. The exit code of the ELIMINATED scenario is the OBSERVED one (-9).
#
# The conversion of the exit code is exercised at its SOURCE (the function
# is extracted from the text of the harness and executed in an isolated
# namespace; the module is never imported) and the contract of the runner
# is checked with the probe of the contract.
# ---------------------------------------------------------------------------
test_the_exit_code_of_the_eliminated_scenario_is_the_observed_signal() {
  local harness="$FORGE_TEST_V2_HARNESS"
  local runner="$FORGE_TEST_V2_RUNNER"
  local probe="$FORGE_TEST_V2_CONTRACT_PROBE"
  if [ ! -f "$harness" ] || [ ! -f "$runner" ] || [ ! -f "$probe" ]; then
    fail "faltan las piezas del contrato del banco V2 (harness=$harness runner=$runner probe=$probe)"
    return
  fi

  local rc=0
  python3 "$probe" --harness "$harness" --runner "$runner" \
    >"$WORKDIR/contract-probe.json" 2>"$WORKDIR/contract-probe.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "el probe del contrato del banco V2 pasa contra el codigo sin mutar (rc=0)"
  else
    fail "el probe del contrato del banco V2 falla contra el codigo sin mutar (rc=$rc)"
    python3 - "$WORKDIR/contract-probe.json" <<'PY_EOF' 2>/dev/null || sed -n '1,20p' "$WORKDIR/contract-probe.err" >&2
import json, sys
payload = json.load(open(sys.argv[1]))
for item in payload.get("checks", []):
    if not item.get("ok"):
        print("      FAIL: %s | %s" % (item.get("name"), item.get("detail")))
PY_EOF
    return
  fi

  # The conversion itself, in ISOLATION: the negative form is the same
  # fact as the raw one, an absent value is NOT an exit code and an
  # INVALID state is NOT another signal.
  #
  # The domain of the signals is a constant of the harness, so it is
  # extracted WITH the function: the isolated execution reads the very
  # domain that the harness declares.
  local value
  value="$(python3 - "$harness" <<'PY_EOF'
import ast, pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(source)
namespace = {}
for node in tree.body:
    if not isinstance(node, ast.Assign):
        continue
    for target in node.targets:
        if isinstance(target, ast.Name) and target.id == "MAX_SIGNAL":
            namespace["MAX_SIGNAL"] = ast.literal_eval(node.value)
if "MAX_SIGNAL" not in namespace:
    print("MAX_SIGNAL=AUSENTE")
    raise SystemExit(0)
for node in tree.body:
    if isinstance(node, ast.FunctionDef) and node.name == "exit_code_of":
        exec(compile(ast.Module(body=[node], type_ignores=[]), "<harness>", "exec"), namespace)
convert = namespace["exit_code_of"]
print("%s|%s|%s|%s|%s|%s|%s" % (
    convert("-9"),
    convert("137"),
    convert(""),
    convert("no-es-un-rc"),
    convert("-137"),
    convert("999"),
    convert("143"),
))
PY_EOF
)"
  if [ "$value" = "-9|-9|None|None|None|None|-15" ]; then
    pass "la conversion del RC en aislamiento: -9 y 137 son el mismo hecho, un valor ausente o invalido NO es un RC y un estado INVALID no se reinterpreta como otra senal"
  else
    fail "la conversion del RC en aislamiento no cumple el contrato (obtenido: $value; se esperaba -9|-9|None|None|None|None|-15)"
  fi
}

# ---------------------------------------------------------------------------
# 43. The verdict of the closure requires EVERY link and the absence of the
#     survivors is OBSERVED, never published as a favourable constant.
#
# The observation is exercised INSIDE the containment, over the PRIVATE
# /proc of the frontier: the host is never enumerated.
# ---------------------------------------------------------------------------
test_the_closure_verdict_requires_every_link_and_observes_the_absence() {
  local harness="$FORGE_TEST_V2_HARNESS"
  local runner="$FORGE_TEST_V2_RUNNER"
  local probe="$FORGE_TEST_V2_CONTRACT_PROBE"
  if [ ! -f "$harness" ] || [ ! -f "$runner" ] || [ ! -f "$probe" ]; then
    fail "faltan las piezas del contrato del banco V2 (harness=$harness runner=$runner probe=$probe)"
    return
  fi

  local rc=0
  python3 "$probe" --harness "$harness" --runner "$runner" \
    >"$WORKDIR/contract-probe-closure.json" 2>"$WORKDIR/contract-probe-closure.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "el veredicto del cierre exige todos sus enlaces y la ausencia se observa (rc=0)"
  else
    fail "el veredicto del cierre NO exige todos sus enlaces o publica una ausencia sin observar (rc=$rc)"
    python3 - "$WORKDIR/contract-probe-closure.json" <<'PY_EOF' 2>/dev/null || sed -n '1,20p' "$WORKDIR/contract-probe-closure.err" >&2
import json, sys
payload = json.load(open(sys.argv[1]))
for item in payload.get("checks", []):
    if not item.get("ok"):
        print("      FAIL: %s | %s" % (item.get("name"), item.get("detail")))
PY_EOF
    return
  fi

  # The BEHAVIOUR of the observation, inside the containment: an absence
  # that cannot be observed is explicitly NOT VERIFIABLE and never
  # "verified".
  local behaviour="$WORKDIR/aftermath-probe.py"
  cat > "$behaviour" <<'PY_EOF'
import ast, json, os, pathlib, re, sys
source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(source)
wanted = (
    "proc_path",
    "read_proc_stat",
    "observe_pid_state",
    "observe_containment_aftermath",
    "process_group_of",
    "innermost_nspid",
    "pid_alive",
    "process_ancestors",
)
namespace = {"os": os, "re": re, "PROC_ROOT": "/proc"}
for node in tree.body:
    if isinstance(node, ast.Assign):
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id.startswith("PID_"):
                namespace[target.id] = ast.literal_eval(node.value)
    if isinstance(node, ast.FunctionDef) and node.name in wanted:
        exec(compile(ast.Module(body=[node], type_ignores=[]), "<harness>", "exec"), namespace)
observe = namespace["observe_containment_aftermath"]
payload = {
    # A namespace identity that does not exist: the absence is OBSERVED.
    "absent": observe("pid:[9999999999]", 1),
    # An unusable identity: the verdict is NOT VERIFIABLE, never "verified".
    "unusable": observe("UNKNOWN", 1),
    # An empty identity: the same.
    "empty": observe("", 1),
    # A group that cannot be observed: the absence of its members is not
    # verifiable either.
    "no_group": observe("pid:[9999999999]", None),
}
print(json.dumps(payload, sort_keys=True))
PY_EOF

  local scenario out rc2=0
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  out="$WORKDIR/aftermath-probe.out"
  rm -f "$out"
  forge_contained_run "$scenario" /usr/bin/python3 "$behaviour" "$harness" \
    >"$out" 2>"$WORKDIR/aftermath-probe.err" || rc2=$?
  rm -f "$scenario"

  if [ "$rc2" -ne 0 ] || [ ! -s "$out" ]; then
    fail "la sonda de la observacion no pudo ejecutarse dentro de la contencion (rc=$rc2)"
    sed -n '1,20p' "$WORKDIR/aftermath-probe.err" | sed 's/^/      /' >&2
    return
  fi

  local verdict
  verdict="$(python3 - "$out" <<'PY_EOF'
import json, sys
payload = json.loads(open(sys.argv[1]).read())
absent = payload["absent"]
unusable = payload["unusable"]
empty = payload["empty"]
no_group = payload["no_group"]
problems = []
if absent.get("state") != "COMPLETE":
    problems.append("la ausencia observada no es COMPLETE: %r" % absent.get("state"))
if absent.get("survivors") != []:
    problems.append("los supervivientes observados no son una lista vacia: %r" % absent.get("survivors"))
if absent.get("init_alive") is not False or absent.get("init_gone") is not True:
    problems.append("la desaparición del init no se observo: %r" % absent)
for name, value in (("unusable", unusable), ("empty", empty)):
    if value.get("state") != "INCOMPLETE":
        problems.append("una identidad inutilizable no es INCOMPLETE: %s=%r" % (name, value.get("state")))
    if value.get("survivors") is not None:
        problems.append("una identidad inutilizable publica supervivientes: %s=%r" % (name, value.get("survivors")))
    if value.get("init_alive") is not None or value.get("init_gone") is not None:
        problems.append("una identidad inutilizable publica el estado del init: %s=%r" % (name, value))
if no_group.get("state") != "INCOMPLETE":
    problems.append("un grupo no observable no es INCOMPLETE: %r" % no_group.get("state"))
if no_group.get("members") is not None:
    problems.append("un grupo no observable publica miembros: %r" % no_group.get("members"))
print("OK" if not problems else "; ".join(problems))
PY_EOF
)"
  if [ "$verdict" = "OK" ]; then
    pass "una ausencia que no se puede observar es NO VERIFICABLE y nunca se publica como verificada"
  else
    fail "la observacion no cumple el contrato de la ausencia verificable: $verdict"
  fi
}

# ---------------------------------------------------------------------------
# 43 bis. The verdict of the cleanup requires the OBSERVED absence, in BOTH
#      entries: the harness that PRODUCES the report and the STABLE entry
#      that CONSUMES it.
#
# The defect that this check closes: the verdict of the cleanup of the
# harness did not require the state of the observation nor the three
# verifications of the absence, and the stable entry checked the ABSENCES
# with a truthiness test that accepts a None (the value of an absence that
# could NOT be observed). The runner of the scenarios already required the
# EXPLICIT verifications, so the criterion was not uniform across the
# entries.
#
# The criterion is the same in the two entries:
#
#   * the observation of the aftermath has to be COMPLETE;
#   * the three absences have to be EXPLICITLY VERIFIED (True), never
#     merely absent from the list of leftovers.
#
# The check is BEHAVIOURAL: the verdict of the harness is EVALUATED with
# the reproduction of the defect (the links of the receipt are valid, the
# observation is INCOMPLETE and the three absences are None) and the
# validation of the stable entry is EXECUTED against the same evidence.
# ---------------------------------------------------------------------------
test_the_cleanup_verdict_requires_the_verified_absence_in_both_entries() {
  local harness="$FORGE_TEST_V2_HARNESS"
  local stable="$FORGE_TEST_V2_STABLE"
  local probe="$FORGE_TEST_V2_CONTRACT_PROBE"
  if [ ! -f "$harness" ] || [ ! -f "$stable" ] || [ ! -f "$probe" ]; then
    fail "faltan las piezas del contrato del banco V2 (harness=$harness stable=$stable probe=$probe)"
    return
  fi

  # (1) The PROBE: the static and behavioural detector of the properties of
  #     C2 and C3. It evaluates the verdict of the harness and executes the
  #     validation of the stable entry.
  local rc=0
  python3 "$probe" --harness "$harness" --stable "$stable" \
    >"$WORKDIR/contract-probe-absence.json" 2>"$WORKDIR/contract-probe-absence.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "el veredicto de la limpieza exige la ausencia VERIFICADA en las DOS entradas (rc=0)"
  else
    fail "el veredicto de la limpieza NO exige la ausencia VERIFICADA en las DOS entradas (rc=$rc)"
    python3 - "$WORKDIR/contract-probe-absence.json" <<'PY_EOF' 2>/dev/null || sed -n '1,20p' "$WORKDIR/contract-probe-absence.err" >&2
import json, sys
payload = json.load(open(sys.argv[1]))
for item in payload.get("checks", []):
    if not item.get("ok"):
        print("      FAIL: %s | %s" % (item.get("name"), item.get("detail")))
PY_EOF
    return
  fi

  # (2) The verdict of the harness, EVALUATED INDEPENDIENTLY with the
  #     reproduction of the defect. The evaluator is the one of the probe
  #     (it never imports the harness: it parses the text).
  local verdict
  verdict="$(python3 - "$probe" "$harness" <<'PY_EOF'
import ast
import importlib.util
import os
import sys

probe_path, harness_path = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("forge_v2_contract_probe", probe_path)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)

with open(harness_path, "r", encoding="utf-8") as stream:
    text = stream.read()
tree = ast.parse(text)
supervisor = probe.function_node(tree, "role_supervisor")
if supervisor is None:
    print("ERROR|no se ha encontrado role_supervisor")
    raise SystemExit(0)

receipt_path = "/tmp/opencode/forge-v2-battery/runs/run-battery/receipt.txt"
base = {
    "receipt": probe.receipt_stub(receipt_path),
    "receipt_path": receipt_path,
    "os": os,
    "root": "/tmp/opencode/forge-v2-battery/root-que-no-existe",
    "AMBIGUOUS_RECEIPT_KEY": probe.module_constant(tree, "AMBIGUOUS_RECEIPT_KEY"),
}

bad = dict(base)
bad.update({
    "aftermath_state": "INCOMPLETE",
    "survivors_absence_verified": None,
    "members_absence_verified": None,
    "init_absence_verified": None,
})
good = dict(base)
good.update({
    "aftermath_state": "COMPLETE",
    "survivors_absence_verified": True,
    "members_absence_verified": True,
    "init_absence_verified": True,
})


def verdict(values):
    try:
        return probe.evaluate_verdict(supervisor, tree, "containment_ok", values)
    except Exception as exc:
        return "error:%s" % exc


print("%r|%r" % (verdict(bad), verdict(good)))
PY_EOF
)"
  if [ "$verdict" = "False|True" ]; then
    pass "el veredicto de la limpieza es FALSO sin la ausencia verificada y VERDADERO con ella"
  else
    fail "el veredicto de la limpieza no cumple el contrato de la ausencia verificada (obtenido: $verdict; se esperaba False|True)"
  fi
}

# ---------------------------------------------------------------------------
# 43 ter. An observation that could NOT be performed is NOT an absence.
#
# The defect that this check closes: the observations of the harness and of
# the verifier of the protected resources turned a FAILED read into an
# ABSENCE ("the process is gone", "the port is not listening"). A
# verification that had observed nothing published a verified absence, the
# init was declared gone, and the PASS of the verifier of the protected
# resources survived an observation that was IMPOSSIBLE.
#
# The criterion:
#
#   * a process whose /proc entry does not exist is a CONFIRMED absence
#     (the kernel answers ENOENT);
#   * a process whose stat could NOT be read is an IMPOSSIBLE observation:
#     it propagates to INCOMPLETE, the init is NOT declared gone and no
#     absence is published as verified;
#   * the verifier of the protected resources FAILS when its observation
#     could not be performed: it declares NOT_OBSERVABLE, never ABSENT nor
#     NOT_LISTENING.
#
# The check is BEHAVIOURAL and INDEPENDENT of the probe: it extracts the
# code under test from its TEXT (it never imports it) and exercises it over
# a SYNTHETIC procfs, where a denied read is reproducible without denying a
# permission in the real machine.
# ---------------------------------------------------------------------------
test_the_observations_distinguish_an_absent_resource_from_an_impossible_one() {
  local harness="$FORGE_TEST_V2_HARNESS"
  local protected="$FORGE_TEST_PROTECTED_RESOURCES"
  local probe="$FORGE_TEST_V2_CONTRACT_PROBE"
  if [ ! -f "$harness" ] || [ ! -f "$protected" ] || [ ! -f "$probe" ]; then
    fail "faltan las piezas de la observacion (harness=$harness protected=$protected probe=$probe)"
    return
  fi

  # (1) The PROBE of the contract: it detects the two properties.
  local rc=0
  python3 "$probe" --harness "$harness" --protected "$protected" \
    >"$WORKDIR/contract-probe-observation.json" 2>"$WORKDIR/contract-probe-observation.err" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "la observacion imposible se distingue de la ausencia (rc=0)"
  else
    fail "una observacion IMPOSIBLE se publica como una AUSENCIA (rc=$rc)"
    python3 - "$WORKDIR/contract-probe-observation.json" <<'PY_EOF' 2>/dev/null || sed -n '1,20p' "$WORKDIR/contract-probe-observation.err" >&2
import json, sys
payload = json.load(open(sys.argv[1]))
for item in payload.get("checks", []):
    if not item.get("ok"):
        print("      FAIL: %s | %s" % (item.get("name"), item.get("detail")))
PY_EOF
    return
  fi

  # (2) The REPRODUCTION, INDEPENDENT of the probe.
  local behaviour="$WORKDIR/impossible-observation-probe.py"
  cat > "$behaviour" <<'PY_EOF'
import ast
import io
import os
import pathlib
import shutil
import sys
import tempfile

harness_path, protected_path = sys.argv[1], sys.argv[2]

REGISTRY = """resource=protected-process
pid=%d
expected_starttime_ticks=26522468
observed_state=ABSENT
cause=directed-verification-probe
cause_date=2026-10-29
incident_report=%s
live_invariant_required=NO

resource=protected-database
path=.local/share/opencode/opencode.db
metadata_source=stat() only
content_read=no
baseline=%s
compared_fields=dev,inode,size,mode
mtime_role=informational_only

resource=protected-port
port=34765
address=127.0.0.1
observed_state=NOT_LISTENING
cause=directed-verification-probe
cause_date=2026-10-29
observation_source=/proc/net/tcp y /proc/net/tcp6
change_by_this_batch=NO
"""


def load_module(path):
    """Execute the TEXT of a module (without its __main__ guard) in a
    namespace of its own. The module is NEVER imported."""
    source = pathlib.Path(path).read_text(encoding="utf-8")
    tree = ast.parse(source, filename=path)
    body = []
    for node in tree.body:
        if isinstance(node, ast.If):
            test = node.test
            if (
                isinstance(test, ast.Compare)
                and isinstance(test.left, ast.Name)
                and test.left.id == "__name__"
                and len(test.comparators) == 1
                and isinstance(test.comparators[0], ast.Constant)
                and test.comparators[0].value == "__main__"
            ):
                continue
        body.append(node)
    module = ast.Module(body=body, type_ignores=[])
    ast.fix_missing_locations(module)
    namespace = {"__name__": "forge_battery_isolated", "__file__": path}
    exec(compile(module, path, "exec"), namespace)
    return namespace


def stat_line(pid, pgrp=4242, starttime=26522468):
    tail = ["S", "1", str(pgrp), str(pgrp)] + ["0"] * 11
    tail += ["20", "0", "1", "0", str(starttime), "0", "0"]
    return "%d (opencode) %s\n" % (pid, " ".join(tail))


def build_tree(root, pids=(), net="readable"):
    """A SYNTHETIC procfs. A stat that is a DIRECTORY cannot be read: the
    denial is reproducible even for a privileged user."""
    os.makedirs(root, exist_ok=True)
    for pid, kind in pids:
        entry = os.path.join(root, "%d" % pid)
        os.makedirs(os.path.join(entry, "ns"), exist_ok=True)
        if kind == "denied":
            os.makedirs(os.path.join(entry, "stat"), exist_ok=True)
        else:
            pathlib.Path(entry, "stat").write_text(stat_line(pid), encoding="ascii")
        os.symlink(
            "pid:[4026531832]" if kind == "foreign" else "pid:[4026531836]",
            os.path.join(entry, "ns", "pid"),
        )
    if net != "absent":
        netdir = os.path.join(root, "net")
        os.makedirs(netdir, exist_ok=True)
        for name in ("tcp", "tcp6"):
            path = os.path.join(netdir, name)
            if net == "denied":
                os.makedirs(path, exist_ok=True)
            else:
                pathlib.Path(path).write_text(
                    "  sl  local_address rem_address   st\n", encoding="ascii"
                )
    return root


problems = []

harness = load_module(harness_path)
workdir = tempfile.mkdtemp(prefix="forge-battery-observation-")
try:
    observe = harness["observe_containment_aftermath"]
    state_of = harness["observe_pid_state"]

    harness["PROC_ROOT"] = build_tree(
        os.path.join(workdir, "denied"), pids=[(200, "denied")]
    )
    denied = observe("pid:[4026531836]", 4242)
    harness["PROC_ROOT"] = build_tree(
        os.path.join(workdir, "control"), pids=[(100, "foreign")]
    )
    control = observe("pid:[4026531836]", 4242)
    harness["PROC_ROOT"] = build_tree(os.path.join(workdir, "absent"))
    absent = state_of(999)

    if denied.get("state") != "INCOMPLETE":
        problems.append("el aftermath con una lectura imposible no es INCOMPLETE: %r" % (denied,))
    if denied.get("init_gone") is not None or denied.get("init_alive") is not None:
        problems.append(
            "el aftermath con una lectura imposible declara el estado del init: %r" % (denied,)
        )
    if absent[0] != "ABSENT":
        problems.append("un proceso inexistente no se observa como ABSENT: %r" % (absent,))
    if control.get("state") != "COMPLETE" or control.get("init_gone") is not True:
        problems.append("el CONTROL: una observacion completa no es COMPLETE: %r" % (control,))
finally:
    shutil.rmtree(workdir, ignore_errors=True)

verifier = load_module(protected_path)
workdir = tempfile.mkdtemp(prefix="forge-battery-protected-")
try:
    home = os.path.join(workdir, "home")
    dbdir = os.path.join(home, ".local", "share", "opencode")
    os.makedirs(dbdir)
    dbpath = os.path.join(dbdir, "opencode.db")
    pathlib.Path(dbpath).write_bytes(b"contenido sintetico\n")
    info = os.stat(dbpath)
    baseline = os.path.join(workdir, "baseline.txt")
    pathlib.Path(baseline).write_text(
        "db_dev=%d\ndb_inode=%d\ndb_size=%d\ndb_mode=0o%o\n"
        % (info.st_dev, info.st_ino, info.st_size, info.st_mode),
        encoding="utf-8",
    )
    incident = os.path.join(workdir, "INCIDENTE-530393.md")
    pathlib.Path(incident).write_text("incidente sintetico\n", encoding="utf-8")
    registry = os.path.join(workdir, "registry.tsv")
    pathlib.Path(registry).write_text(
        REGISTRY % (530393, incident, baseline), encoding="utf-8"
    )

    def run(proc_root):
        verifier["PROC_ROOT"] = proc_root
        captured = io.StringIO()
        saved = sys.stdout
        sys.stdout = captured
        try:
            code = verifier["main"](
                [
                    "--baseline",
                    baseline,
                    "--registry",
                    registry,
                    "--incident",
                    incident,
                    "--home",
                    home,
                ]
            )
        except SystemExit as exc:
            code = exc.code or 0
        finally:
            sys.stdout = saved
        return code, captured.getvalue()

    control_code, control_out = run(build_tree(os.path.join(workdir, "control")))
    denied_code, denied_out = run(
        build_tree(os.path.join(workdir, "denied-pid"), pids=[(530393, "denied")])
    )
    net_code, net_out = run(
        build_tree(os.path.join(workdir, "denied-net"), net="denied")
    )

    if control_code != 0:
        problems.append("el CONTROL del verificador no acepta el estado real: rc=%r" % (control_code,))
    if denied_code == 0:
        problems.append("el verificador ACEPTA los recursos con una lectura IMPOSIBLE: rc=0")
    if "PROTECTED_PID_OBSERVED=NOT_OBSERVABLE" not in denied_out:
        problems.append("el verificador no declara NOT_OBSERVABLE: %r" % (denied_out[-300:],))
    if "PROTECTED_PID_OBSERVED=ABSENT" in denied_out:
        problems.append("el verificador declara ABSENT con una lectura IMPOSIBLE: %r" % (denied_out[-300:],))
    if net_code == 0:
        problems.append("el verificador ACEPTA los recursos con las tablas TCP ILEGIBLES: rc=0")
    if "PROTECTED_PORT_OBSERVED=NOT_OBSERVABLE" not in net_out:
        problems.append("el verificador no declara el puerto NOT_OBSERVABLE: %r" % (net_out[-300:],))
finally:
    shutil.rmtree(workdir, ignore_errors=True)

print("OK" if not problems else "; ".join(problems))
sys.exit(0 if not problems else 1)
PY_EOF

  local out rc2=0
  out="$(python3 "$behaviour" "$harness" "$protected" 2>&1)" || rc2=$?
  if [ "$rc2" -ne 0 ]; then
    fail "la reproduccion de la observacion imposible no cumple el contrato (rc=$rc2): $out"
    return
  fi
  if [ "$out" = "OK" ]; then
    pass "una lectura IMPOSIBLE no se publica como una AUSENCIA (reproduccion independiente)"
  else
    fail "una lectura IMPOSIBLE se publica como una AUSENCIA: $out"
  fi
}

# ---------------------------------------------------------------------------
# 44. The PROTECTED PID is refused whatever the environment declares.
#
# The exclusion of the PID that the plan protects is IMMUTABLE: the
# variable of the environment can only ADD exclusions to it, never
# SUBSTITUTE it. A substitution turned the protection into a fiction: with
# another value in the variable, a target of 530393 was signalled.
#
# The exclusion is applied to the DESTINATION and to the OWNER, and it is
# applied BEFORE any access: a protected PID is never read, not even as the
# owner of the containment.
# ---------------------------------------------------------------------------
test_the_protected_pid_is_refused_whatever_the_environment_declares() {
  local out rc=0
  out="$(python3 - "$FORGE_OWN_SIGNAL_PY" <<'PY'
import importlib.util
import io
import os
import signal
import sys
import contextlib

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("forge_own_signal", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

PROTECTED = "530393"
failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


NAMESPACE = "pid:[999999]"
OWNER_PID = 4242
OWNER_TICKS = "111"


def run(target, owner, protected, ticks_sequence, ancestors=None):
    """Runs the signalling with SIMULATED kernel operations.

    Every access to a PID is RECORDED: the check proves that the protected
    PID is not even READ.
    """
    state = {"accessed": [], "kills": [], "pidfd_signals": []}
    values = list(ticks_sequence)

    def fake_ticks(candidate):
        state["accessed"].append(("ticks", candidate))
        if candidate == owner:
            return OWNER_TICKS
        if not values:
            return None
        value = values[min(len(state["accessed"]), len(values) - 1)]
        return value

    def fake_namespace(candidate):
        state["accessed"].append(("namespace", candidate))
        return NAMESPACE

    def fake_ancestors(candidate):
        state["accessed"].append(("ancestors", candidate))
        return [OWNER_PID] if ancestors is None else ancestors

    def fake_kill(pid, signum):
        state["kills"].append((pid, signum))

    def fake_killpg(pgid, signum):
        state["kills"].append((pgid, signum))

    def fake_raise_signal(signum):
        state["kills"].append((os.getpid(), signum))

    def fake_signal_kill(pid, signum):
        state["kills"].append((pid, signum))

    def fake_signal_killpg(pgid, signum):
        state["kills"].append((pgid, signum))

    def fake_pidfd_open(_pid, _flags):
        return os.open(os.devnull, os.O_RDONLY)

    def fake_pidfd_send_signal(handle, signum):
        state["pidfd_signals"].append((handle, signum))

    original_ticks = mod.ticks_of
    original_namespace = mod.namespace_of
    original_ancestors = mod.ancestors_of
    original_kill = os.kill
    original_killpg = os.killpg
    original_raise_signal = signal.raise_signal
    # `signal.kill` and `signal.killpg` do NOT exist in Python 3: the double
    # is installed ANYWAY, so that a mutation that reached for them finds a
    # double and never the kernel. The original is restored (or removed) at
    # the end.
    original_signal_kill = getattr(signal, "kill", None)
    original_signal_killpg = getattr(signal, "killpg", None)
    original_open = getattr(os, "pidfd_open", None)
    original_send = getattr(signal, "pidfd_send_signal", None)
    original_env = os.environ.get(mod.NAMESPACE_VARIABLE)
    original_protected = os.environ.get(mod.PROTECTED_PID_VARIABLE)
    mod.ticks_of = fake_ticks
    mod.namespace_of = fake_namespace
    mod.ancestors_of = fake_ancestors
    # EVERY way of signalling is a double: not only os.kill and the pidfd
    # route, but also the group and the module-level variants. A mutation
    # that reached for any of them would find a double, never the kernel.
    os.kill = fake_kill
    os.killpg = fake_killpg
    signal.raise_signal = fake_raise_signal
    signal.kill = fake_signal_kill
    signal.killpg = fake_signal_killpg
    os.pidfd_open = fake_pidfd_open
    signal.pidfd_send_signal = fake_pidfd_send_signal
    os.environ[mod.NAMESPACE_VARIABLE] = NAMESPACE
    os.environ[mod.PROTECTED_PID_VARIABLE] = protected

    buffer = io.StringIO()
    try:
        with contextlib.redirect_stdout(buffer):
            code = mod.main([
                "forge_own_signal.py", str(target), "1000", "TERM",
                str(owner), OWNER_TICKS,
            ])
    finally:
        mod.ticks_of = original_ticks
        mod.namespace_of = original_namespace
        mod.ancestors_of = original_ancestors
        os.kill = original_kill
        os.killpg = original_killpg
        signal.raise_signal = original_raise_signal
        if original_signal_kill is None:
            del signal.kill
        else:
            signal.kill = original_signal_kill
        if original_signal_killpg is None:
            del signal.killpg
        else:
            signal.killpg = original_signal_killpg
        if original_open is not None:
            os.pidfd_open = original_open
        if original_send is not None:
            signal.pidfd_send_signal = original_send
        if original_env is None:
            os.environ.pop(mod.NAMESPACE_VARIABLE, None)
        else:
            os.environ[mod.NAMESPACE_VARIABLE] = original_env
        if original_protected is None:
            os.environ.pop(mod.PROTECTED_PID_VARIABLE, None)
        else:
            os.environ[mod.PROTECTED_PID_VARIABLE] = original_protected

    return code, buffer.getvalue().strip(), state


# 44a) The variable of the environment points to ANOTHER PID: the PID of the
#      plan is STILL refused and NOTHING is accessed.
code, out, state = run(PROTECTED, OWNER_PID, "1234", ["1000", "1000"])
check(code == 5, "44a: se esperaba 5 (refused) y se obtuvo %s" % code)
check(out.startswith("refused-"), "44a: motivo inesperado %r" % out)
check(not state["kills"], "44a: se señalo al PID protegido")
check(not state["pidfd_signals"], "44a: se señalo por pidfd al PID protegido")
check(
    not [entry for entry in state["accessed"] if str(entry[1]) == PROTECTED],
    "44a: se ACCESO al PID protegido: %r" % (state["accessed"],),
)

# 44b) The variable of the environment declares the PID of the plan AND
#      another one: the PID of the plan is refused and the other one is
#      refused too (the variable ADDS exclusions).
code, out, state = run("1234", OWNER_PID, "%s 1234" % PROTECTED, ["1000", "1000"])
check(code == 5, "44b: se esperaba 5 (refused) y se obtuvo %s" % code)
check(not state["kills"], "44b: se señalo a un PID excluido por la variable")

# 44c) The OWNER is the protected PID: it is refused BEFORE any access.
code, out, state = run("9999", PROTECTED, "1234", ["1000", "1000"])
check(code == 5, "44c: se esperaba 5 (refused) y se obtuvo %s" % code)
check(out == "refused-protected-owner", "44c: motivo inesperado %r" % out)
check(not state["kills"], "44c: se señalo con un propietario protegido")
check(
    not [entry for entry in state["accessed"] if str(entry[1]) == PROTECTED],
    "44c: se ACCESO al PID protegido: %r" % (state["accessed"],),
)

# 44d) The exclusion of the PID of the plan does not depend on the
#      variable at all: with the variable absent, the PID is refused.
code, out, state = run(PROTECTED, OWNER_PID, "", ["1000", "1000"])
check(code == 5, "44d: se esperaba 5 (refused) y se obtuvo %s" % code)
check(
    not [entry for entry in state["accessed"] if str(entry[1]) == PROTECTED],
    "44d: se ACCESO al PID protegido: %r" % (state["accessed"],),
)

for message in failures:
    sys.stdout.write("FAIL %s\n" % message)
sys.exit(1 if failures else 0)
PY
)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    pass "el PID protegido se rechaza SIEMPRE: la variable del entorno solo ANADE exclusiones y ningun acceso ocurre"
  else
    fail "el PID protegido NO se rechaza de forma incondicional: la exclusion es sustituible o accesible"
    printf '%s\n' "$out" | sed -n '1,20p' | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# 45. The DETECTOR of the registry of the V2 bank REQUIRES an accredited
#      boundary.
#
# The detector loads the program of the guard and it creates processes:
# neither may happen outside the frontier. The detector says so and it does
# NOTHING when the boundary is not accredited.
# ---------------------------------------------------------------------------
test_the_registry_detector_requires_an_accredited_boundary() {
  local detector="$FORGE_TEST_V2_REGISTRY_DETECTOR"
  if [ ! -f "$detector" ]; then
    fail "no se encuentra el detector del registro del banco V2 ($detector)"
    return
  fi

  local out rc=0
  out="$(env -u FORGE_CONTAINED_RUN_PID_NAMESPACE \
    -u FORGE_CONTAINED_RUN_RECEIPT \
    -u FORGE_CONTAINED_RUN_ID \
    -u FORGE_CONTAINED_RUN_ACCREDITATION_FILE \
    python3 "$detector" 2>&1)" || rc=$?
  if [ "$rc" -eq 78 ]; then
    pass "el detector del registro RECHAZA correr sin frontera acreditada (rc=78)"
  else
    fail "el detector del registro NO exige una frontera acreditada (rc=$rc): ejecuto codigo y creo procesos sin frontera"
    printf '%s\n' "$out" | sed -n '1,20p' | sed 's/^/      /' >&2
    return
  fi

  if printf '%s' "$out" | grep -q "no se ejecuta el programa del guard y no se crea ningun proceso"; then
    pass "el detector del registro NO ejecuta el programa del guard ni crea procesos sin frontera"
  else
    fail "el detector del registro no declara que no ejecuta nada sin frontera"
    printf '%s\n' "$out" | sed -n '1,20p' | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# 46. The scanner of the definitions recognises the WHOLE delimiter of a
#     heredoc, tells a here-STRING from a here-DOC and removes only the
#     TABULATORS of a `<<-`.
# ---------------------------------------------------------------------------
test_the_definition_scanner_recognises_the_whole_heredoc_delimiter() {
  local scanner="$FORGE_TEST_SHELL_DEFS_SCANNER"
  if [ ! -f "$scanner" ]; then
    fail "no se encuentra el escaner de definiciones ($scanner)"
    return
  fi

  local found
  # 46a) `<<'END-DATA'` opens a heredoc whose delimiter is `END-DATA`: the
  #      definitions that follow it are CODE and they are counted.
  local fixture_a="$WORKDIR/heredoc-delimiter.sh"
  cat > "$fixture_a" <<'LEX_A_EOF'
#!/bin/sh
cat <<'END-DATA'
the body of the heredoc
END-DATA
dup() { :; }
dup() { :; }
LEX_A_EOF
  found="$(python3 "$scanner" count "$fixture_a" dup 2>/dev/null)"
  if [ "$(printf '%s\n' "$found" | grep -c .)" -eq 2 ]; then
    pass "el escaner reconoce el delimitador COMPLETO de un heredoc ('END-DATA' no es 'END') ($found)"
  else
    fail "el escaner NO reconoce el delimitador completo del heredoc: las definiciones posteriores desaparecen ($found)"
  fi

  # 46b) `<<<WORD` is a here-STRING: it opens NOTHING and the definitions
  #      that follow it are CODE and they are counted.
  local fixture_b="$WORKDIR/herestring.sh"
  cat > "$fixture_b" <<'LEX_B_EOF'
#!/bin/sh
value=<<<WORD
dup() { :; }
dup() { :; }
LEX_B_EOF
  found="$(python3 "$scanner" count "$fixture_b" dup 2>/dev/null)"
  if [ "$(printf '%s\n' "$found" | grep -c .)" -eq 2 ]; then
    pass "el escaner distingue una here-STRING de un here-DOC: las definiciones posteriores se cuentan ($found)"
  else
    fail "el escaner confunde una here-STRING con un here-DOC: las definiciones posteriores desaparecen ($found)"
  fi

  # 46c) `<<-` removes TABULATORS and nothing else: a terminator preceded
  #      by SPACES is NOT the terminator and the body goes on.
  #
  # The delimiter is written with a VARIABLE: the file of this battery is
  # read by the static verifiers, and a literal header of a heredoc inside
  # a string is a header of a heredoc for them.
  local tag="END"
  local fixture_c="$WORKDIR/heredoc-tabs.sh"
  cat > "$fixture_c" <<LEX_C_EOF
#!/bin/sh
cat <<-$tag
   $tag
dup() { :; }
dup() { :; }
LEX_C_EOF
  found="$(python3 "$scanner" count "$fixture_c" dup 2>/dev/null)"
  if [ -z "$found" ]; then
    pass "el escaner de '<<-' elimina SOLO tabuladores: un terminador precedido por espacios no termina el heredoc"
  else
    fail "el escaner de '<<-' acepto un terminador precedido por espacios y conto una definicion ficticia ($found)"
  fi

  # 46d) The CONTROL: a `<<-` whose terminator IS preceded by tabulators
  #      does end the heredoc and the definitions after it are counted.
  local fixture_d="$WORKDIR/heredoc-tabs-ok.sh"
  printf '#!/bin/sh\ncat <<-%s\n\t%s\ndup() { :; }\ndup() { :; }\n' \
    "$tag" "$tag" > "$fixture_d"
  found="$(python3 "$scanner" count "$fixture_d" dup 2>/dev/null)"
  if [ "$(printf '%s\n' "$found" | grep -c .)" -eq 2 ]; then
    pass "el escaner de '<<-' acepta el terminador precedido por tabuladores ($found)"
  else
    fail "el escaner de '<<-' NO acepta el terminador precedido por tabuladores ($found)"
  fi
}

# ---------------------------------------------------------------------------
# 47. The scanner of the network recognises the IMPORTS, the ALIASES and
#     the ENTRIES of the network, and the network is EFFECTIVELY restricted
#     during the execution of the battery.
# ---------------------------------------------------------------------------
test_the_network_scanner_recognises_the_imports_and_the_aliases() {
  local scanner="$FORGE_TEST_NETWORK_SCANNER"
  if [ ! -f "$scanner" ]; then
    fail "no se encuentra el escaner de primitivas de red ($scanner)"
    return
  fi

  # The fixture lives OUTSIDE the tree of the suites: a fixture with the
  # primitives of the network inside the tree would be accused by the scan
  # of the tree itself. Its text is assembled with VARIABLES for the same
  # reason: the file of this battery IS in the tree that the scan reads,
  # and the literal text of the primitives would make the scan accuse this
  # very file instead of the fixture.
  local fixture="$WORKDIR/network-fixture.py"
  local MOD="urllib.request"
  local ENTRY="urlopen"
  local REQ="requests"
  local VERB="request"
  {
    printf 'from %s import %s\n' "$MOD" "$ENTRY"
    printf 'import %s\n' "$REQ"
    printf 'import %s as %s\n' "$MOD" ur
    printf '\n'
    printf 'def fetch():\n'
    printf '    return %s("http://example.invalid/")\n' "$ENTRY"
    printf '\n'
    printf 'def other():\n'
    printf '    return %s.%s("GET", "http://example.invalid/")\n' "$REQ" "$VERB"
    printf '\n'
    printf 'def aliased():\n'
    printf '    return ur.%s("http://example.invalid/")\n' "$ENTRY"
  } > "$fixture"

  local out rc=0
  out="$(python3 "$scanner" "$fixture" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ]; then
    pass "el escaner de la red reconoce las IMPORTACIONES, los ALIAS y las ENTRADAS de la red"
  else
    fail "el escaner de la red NO reconoce las importaciones, los alias y las entradas de la red (rc=$rc)"
    printf '%s\n' "$out" | sed -n '1,10p' | sed 's/^/      /' >&2
  fi

  if printf '%s' "$out" | grep -q "from $MOD import $ENTRY" \
    && printf '%s' "$out" | grep -q "import $REQ" \
    && printf '%s' "$out" | grep -q "$ENTRY("; then
    pass "el escaner de la red acusa la importacion, el alias y la llamada de la red"
  else
    fail "el escaner de la red no acusa TODAS las formas de la red"
    printf '%s\n' "$out" | sed -n '1,10p' | sed 's/^/      /' >&2
  fi
}

# ---------------------------------------------------------------------------
# 48. The network is EFFECTIVELY restricted during the execution.
#
# The static scan proves a property of the SOURCE. The restriction proves a
# property of the EXECUTION: the primitives are UNAVAILABLE while the
# battery runs and the resolution of names is disabled. A restriction that
# only claimed to refuse would prove nothing: the attempts are REAL.
# ---------------------------------------------------------------------------
test_the_network_is_effectively_restricted_during_the_battery() {
  if [ "$NETWORK_GUARD_STATUS" != "EFFECTIVE" ]; then
    fail "la restriccion de la red NO esta instalada: la bateria se ejecuta sin una restriccion efectiva"
    return
  fi
  pass "la restriccion de la red esta instalada y verificada antes de ejecutar la bateria"

  local probe out rc=0
  # The interpreter is NOT broken by the restriction.
  out="$(python3 -c 'print("ok")' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "ok" ]; then
    pass "la restriccion de la red NO rompe el interprete"
  else
    fail "la restriccion de la red rompio el interprete (rc=$rc, salida='$out')"
  fi

  # The restriction is installed in the interpreters of THIS battery: the
  # module of la restriccion esta cargado en el interprete que la ejecuta.
  rc=0
  out="$(python3 -c 'import sys; print("forge_network_guard" in sys.modules)' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "True" ]; then
    pass "la restriccion de la red esta instalada en los interpretes de esta bateria"
  else
    fail "la restriccion de la red NO esta instalada en los interpretes de esta bateria (rc=$rc, salida='$out')"
  fi

  # The probes are assembled with VARIABLES: this file is in the tree that
  # the scan of the network reads, and the literal text of the primitives
  # would make the scan accuse this very file.
  local MOD="urllib.request"
  local ENTRY="urlopen"
  local SOCK="socket"
  local HTTPC="http.client"
  local probes
  probes="import $SOCK; $SOCK.$SOCK()
import $SOCK; $SOCK.getaddrinfo(\"example.invalid\", 80)
from $MOD import $ENTRY; $ENTRY(\"http://example.invalid/\")
import $HTTPC; $HTTPC.HTTPConnection(\"example.invalid\", 80)"
  while IFS= read -r probe; do
    [ -n "$probe" ] || continue
    rc=0
    out="$(python3 - 2>&1 <<PROBE_EOF
$probe
PROBE_EOF
)" || rc=$?
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "NetworkAccessDenied"; then
      pass "la restriccion EFECTIVA rechaza la primitiva de la red: $probe"
    else
      fail "la restriccion NO rechazo la primitiva de la red: $probe (rc=$rc)"
      printf '%s\n' "$out" | sed -n '1,5p' | sed 's/^/      /' >&2
    fi
  done <<PROBES_EOF
$probes
PROBES_EOF
}

# ---------------------------------------------------------------------------
# 45. An ABSENT socket table is NOT an observation of the port.
#
# The defect that this check closes: the verifier of the protected resources
# counted a table whose INTERFACE WAS ABSENT (the file does not exist) as a
# table that had been READ. With BOTH tables absent, the defence that
# requires at least one effective read was UNREACHABLE, the verifier
# published "NO EN ESCUCHA" and it exited with 0 WITHOUT having read a
# single table.
#
# The absence of an interface does NOT prove that the family is disabled and
# it does NOT prove that there is no listener of that family. Only an
# INDEPENDENT accreditation (a SEPARATE declaration, never the failed read
# itself) can excuse it, and without it the observation is INCOMPLETE: the
# state is published as NOT_OBSERVABLE and the exit status is not zero.
#
# The criterion, over a SYNTHETIC procfs (the verifier is NEVER imported
# and NEVER modified):
#
#   (a) both tables readable            -> a REAL observation (NOT_LISTENING);
#   (b) one readable, the other absent  -> an INCOMPLETE observation: FAIL;
#   (c) both absent                     -> NOT_OBSERVABLE: FAIL;
#   (d) both unreadable                 -> NOT_OBSERVABLE: FAIL;
#   (e) the PID does not exist          -> ABSENT (a CONFIRMED absence), and
#                                          no failure of its own.
#
# The absence of the stat of the PID protected is a REAL absence (the kernel
# answers ENOENT) and it is kept SEPARATELY from the absence of an
# interface: that is the difference between (e) and (c).
# ---------------------------------------------------------------------------
test_an_absent_socket_table_is_not_an_observation_of_the_port() {
  local protected="$FORGE_TEST_PROTECTED_RESOURCES"
  if [ ! -f "$protected" ]; then
    fail "no se encuentra el verificador de los recursos protegidos ($protected)"
    return
  fi

  local behaviour="$WORKDIR/absent-socket-table.py"
  cat > "$behaviour" <<'PY_EOF'
import ast
import io
import os
import pathlib
import shutil
import sys
import tempfile

verifier_path = sys.argv[1]

source = pathlib.Path(verifier_path).read_text(encoding="utf-8")
tree = ast.parse(source, filename=verifier_path)
body = []
for node in tree.body:
    if isinstance(node, ast.If):
        test = node.test
        if (
            isinstance(test, ast.Compare)
            and isinstance(test.left, ast.Name)
            and test.left.id == "__name__"
            and len(test.comparators) == 1
            and isinstance(test.comparators[0], ast.Constant)
            and test.comparators[0].value == "__main__"
        ):
            continue
    body.append(node)
module = ast.Module(body=body, type_ignores=[])
ast.fix_missing_locations(module)
namespace = {"__name__": "forge_battery_absent_table", "__file__": verifier_path}
exec(compile(module, verifier_path, "exec"), namespace)

problems = []
workdir = tempfile.mkdtemp(prefix="forge-battery-absent-table-")
try:
    home = os.path.join(workdir, "home")
    dbdir = os.path.join(home, ".local", "share", "opencode")
    os.makedirs(dbdir)
    dbpath = os.path.join(dbdir, "opencode.db")
    pathlib.Path(dbpath).write_bytes(b"contenido sintetico\n")
    info = os.stat(dbpath)
    baseline = os.path.join(workdir, "baseline.txt")
    pathlib.Path(baseline).write_text(
        "db_dev=%d\ndb_inode=%d\ndb_size=%d\ndb_mode=0o%o\n"
        % (info.st_dev, info.st_ino, info.st_size, info.st_mode),
        encoding="utf-8",
    )
    incident = os.path.join(workdir, "INCIDENTE-530393.md")
    pathlib.Path(incident).write_text("incidente sintetico\n", encoding="utf-8")

    def write_registry(path, extra=""):
        pathlib.Path(path).write_text(
            "resource=protected-process\n"
            "pid=530393\n"
            "expected_starttime_ticks=26522468\n"
            "observed_state=ABSENT\n"
            "cause=directed-verification-probe\n"
            "cause_date=2026-10-29\n"
            "incident_report=%s\n"
            "live_invariant_required=NO\n"
            "\n"
            "resource=protected-database\n"
            "path=.local/share/opencode/opencode.db\n"
            "metadata_source=stat() only\n"
            "content_read=no\n"
            "baseline=%s\n"
            "compared_fields=dev,inode,size,mode\n"
            "mtime_role=informational_only\n"
            "\n"
            "resource=protected-port\n"
            "port=34765\n"
            "address=127.0.0.1\n"
            "observed_state=NOT_LISTENING\n"
            "cause=directed-verification-probe\n"
            "cause_date=2026-10-29\n"
            "observation_source=/proc/net/tcp y /proc/net/tcp6\n"
            "change_by_this_batch=NO\n%s" % (incident, baseline, extra),
            encoding="utf-8",
        )

    registry = os.path.join(workdir, "registry.tsv")
    write_registry(registry)

    def build(root, net):
        """A SYNTHETIC procfs. A table that is a DIRECTORY cannot be read:
        the denial is reproducible even for a privileged user."""
        os.makedirs(root, exist_ok=True)
        if net == "absent":
            return root
        netdir = os.path.join(root, "net")
        os.makedirs(netdir, exist_ok=True)
        for name in ("tcp", "tcp6"):
            path = os.path.join(netdir, name)
            if net == "denied":
                os.makedirs(path, exist_ok=True)
            elif net == "one" and name == "tcp6":
                continue
            else:
                pathlib.Path(path).write_text(
                    "  sl  local_address rem_address   st\n", encoding="ascii"
                )
        return root

    def run(tree_root, registry_path=registry):
        namespace["PROC_ROOT"] = tree_root
        captured = io.StringIO()
        saved = sys.stdout
        sys.stdout = captured
        try:
            code = namespace["main"](
                [
                    "--baseline",
                    baseline,
                    "--registry",
                    registry_path,
                    "--incident",
                    incident,
                    "--home",
                    home,
                ]
            )
        except SystemExit as exc:
            code = exc.code or 0
        finally:
            sys.stdout = saved
        return code, captured.getvalue()

    # (a) AMBAS tablas legibles: la observacion es REAL.
    code, out = run(build(os.path.join(workdir, "a"), "readable"))
    if code != 0:
        problems.append("(a) el CONTROL no acepta el estado real: rc=%r" % (code,))
    if "PROTECTED_PORT_OBSERVED=NOT_LISTENING" not in out:
        problems.append("(a) el CONTROL no declara NOT_LISTENING: %r" % (out[-300:],))
    if "PROTECTED_PORT_TABLES_EFFECTIVELY_READ=ipv4,ipv6" not in out:
        problems.append("(a) el CONTROL no declara las tablas EFFECTIVAMENTE leidas")

    # (b) una legible y la otra ausente: la observacion es INCOMPLETA.
    code, out = run(build(os.path.join(workdir, "b"), "one"))
    if code == 0:
        problems.append("(b) el verificador ACEPTA una observacion INCOMPLETA: rc=0")
    if "PROTECTED_PORT_OBSERVED=NOT_OBSERVABLE" not in out:
        problems.append("(b) el verificador no declara NOT_OBSERVABLE: %r" % (out[-300:],))
    if "PROTECTED_PORT_OBSERVED=NOT_LISTENING" in out:
        problems.append("(b) el verificador declara NOT_LISTENING sin haber leido la tabla")
    if "PROTECTED_PORT_INTERFACES_ABSENT=ipv6" not in out:
        problems.append("(b) el verificador no declara la interface ausente")

    # (c) AMBAS ausentes: NOT_OBSERVABLE (no hay ninguna lectura).
    code, out = run(build(os.path.join(workdir, "c"), "absent"))
    if code == 0:
        problems.append("(c) el verificador ACEPTA las tablas ausentes: rc=0")
    if "PROTECTED_PORT_OBSERVED=NOT_OBSERVABLE" not in out:
        problems.append("(c) el verificador no declara NOT_OBSERVABLE: %r" % (out[-300:],))
    if "PROTECTED_PORT_OBSERVED=NOT_LISTENING" in out:
        problems.append("(c) el verificador declara NOT_LISTENING sin haber leido NINGUNA tabla")
    if "PROTECTED_PORT_INTERFACES_ABSENT=ipv4,ipv6" not in out:
        problems.append("(c) el verificador no declara las interfaces ausentes")

    # (d) las tablas DENEGADAS: NOT_OBSERVABLE.
    code, out = run(build(os.path.join(workdir, "d"), "denied"))
    if code == 0:
        problems.append("(d) el verificador ACEPTA las tablas denegadas: rc=0")
    if "PROTECTED_PORT_OBSERVED=NOT_OBSERVABLE" not in out:
        problems.append("(d) el verificador no declara NOT_OBSERVABLE: %r" % (out[-300:],))

    # (e) el PID INEXISTENTE: una AUSENCIA CONFIRMADA, sin fallo por ese motivo.
    if "PROTECTED_PID_OBSERVED=ABSENT" not in out:
        problems.append("(e) el verificador no declara el PID AUSENTE: %r" % (out[-300:],))
    if "PROTECTED_PID_OBSERVED=NOT_OBSERVABLE" in out:
        problems.append("(e) el verificador declara NOT_OBSERVABLE un PID inexistente")
    for line in out.splitlines():
        if line.startswith("FAIL=") and "PID protegido" in line:
            problems.append("(e) hay un FALLO por el PID protegido: %s" % line)

    # (f) la acreditacion INDEPENDIENTE de una familia deshabilitada: la
    #     interface ausente de esa familia queda excusada.
    evidence = os.path.join(workdir, "disabled-ipv6.txt")
    pathlib.Path(evidence).write_text(
        "family=ipv6\nstate=DISABLED\naccredited_by=sintetico\n", encoding="utf-8"
    )
    registry_accredited = os.path.join(workdir, "registry-accredited.tsv")
    write_registry(registry_accredited, extra="disabled_family_evidence=%s\n" % evidence)
    code, out = run(build(os.path.join(workdir, "f"), "one"), registry_accredited)
    if code != 0:
        problems.append(
            "(f) con la acreditacion INDEPENDIENTE el verificador falla: rc=%r" % (code,)
        )
    if "PROTECTED_PORT_FAMILIES_DISABLED_ACCREDITED=ipv6" not in out:
        problems.append("(f) el verificador no declara la familia acreditada")
finally:
    shutil.rmtree(workdir, ignore_errors=True)

print("OK" if not problems else "; ".join(problems))
sys.exit(0 if not problems else 1)
PY_EOF

  local out rc=0
  out="$(python3 "$behaviour" "$protected" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "una tabla de sockets AUSENTE se publica como una observacion del puerto: $out"
    return
  fi
  if [ "$out" = "OK" ]; then
    pass "una tabla de sockets AUSENTE NO se publica como una observacion del puerto"
  else
    fail "una tabla de sockets AUSENTE se publica como una observacion del puerto: $out"
  fi
}

# ---------------------------------------------------------------------------
# 46. The restriction of the network DECLARES the interpreters that it
#     reaches.
#
# The defect that this check closes: the comment that describes the
# restriction of the network affirmed that EVERY interpreter that the
# battery spawns inherits it. It is FALSE: the restriction reaches the
# interpreters that LOAD the wrapper or the `sitecustomize` of its
# directory, and nothing else. An interpreter invoked by an ABSOLUTE path
# does not load it, and a NESTED contained entry does not inherit it
# either: the entry rebuilds the environment of its scenario with `env -i`
# and with the PATH that it DECLARES.
#
# The criterion has TWO halves, and the second one is BEHAVIOURAL: the
# comment must not claim more than the execution delivers, and the
# execution must deliver exactly what the comment claims.
# ---------------------------------------------------------------------------
test_the_network_restriction_states_the_interpreters_that_it_reaches() {
  local source_file="$FORGE_TEST_BATTERY_SOURCE"
  if [ ! -f "$source_file" ]; then
    fail "no se encuentra el fuente de la bateria ($source_file)"
    return
  fi

  # The COMMENT that describes the effective restriction of the network.
  local block
  block="$(awk '
    /^# The EFFECTIVE RESTRICTION of the network\.$/ { inside = 1; next }
    inside && /^# ---------/ { exit }
    inside { print }
  ' "$source_file")"
  if [ -z "$block" ]; then
    fail "el fuente de la bateria no declara el comentario de la restriccion de la red"
    return
  fi

  # The claim that this check closes.
  if printf '%s\n' "$block" | grep -q "EVERY interpreter"; then
    fail "el comentario de la restriccion de la red sigue afirmando que TODO interprete de la bateria la hereda"
    return
  fi
  pass "el comentario de la restriccion de la red NO afirma que todo interprete de la bateria la hereda"

  local required
  for required in \
    "the interpreters that LOAD the wrapper or the" \
    "sitecustomize" \
    "ABSOLUTE" \
    "does NOT inherit it either" \
    "rebuilds the environment of its scenario"; do
    if printf '%s\n' "$block" | grep -qF "$required"; then
      pass "el comentario ACOTA el alcance de la restriccion de la red ($required)"
    else
      fail "el comentario NO acota el alcance de la restriccion de la red ($required)"
    fi
  done

  # (1) The interpreter that the PATH of the battery resolves DOES load the
  #     restriction: the wrapper exports the PYTHONPATH of its directory.
  local out rc=0
  out="$(python3 -c 'import sys; print("forge_network_guard" in sys.modules)' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "True" ]; then
    pass "el interprete que resuelve el PATH de la bateria CARGA la restriccion de la red"
  else
    fail "el interprete que resuelve el PATH de la bateria NO carga la restriccion de la red (rc=$rc, salida='$out')"
  fi

  # (2) The interpreter invoked by an ABSOLUTE path does NOT load it: the
  #     PYTHONPATH that the wrapper exports does not reach it.
  local real_python=""
  if [ -f "$NETWORK_GUARD_DIR/python3" ]; then
    real_python="$(sed -n 's/^exec \([^ ]*\) .*$/\1/p' "$NETWORK_GUARD_DIR/python3" | head -n 1)"
  fi
  if [ -z "$real_python" ] || [ ! -x "$real_python" ]; then
    fail "no se pudo determinar el interprete real que usa el wrapper ($NETWORK_GUARD_DIR/python3)"
    return
  fi
  rc=0
  out="$("$real_python" -c 'import sys; print("forge_network_guard" in sys.modules)' 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "False" ]; then
    pass "el interprete invocado por una RUTA ABSOLUTA NO carga la restriccion de la red"
  else
    fail "el interprete invocado por una RUTA ABSOLUTA carga la restriccion de la red (rc=$rc, salida='$out')"
  fi

  # (3) A NESTED contained entry REBUILDS the PATH of its scenario: the
  #     directory of the restriction is NOT inherited automatically.
  local scenario helper_dir probe pointer declared observed
  scenario="$(forge_contained_scenario "$WORKDIR/home")" || {
    fail "no se pudo preparar el escenario contenido"
    return
  }
  helper_dir="$WORKDIR/reach-helpers"
  mkdir -p "$helper_dir"
  if ! forge_write_containment_observer "$helper_dir" \
    || ! forge_write_containment_killer "$helper_dir"; then
    fail "no se pudieron preparar los ayudantes del /proc privado"
    rm -f "$scenario"
    return
  fi

  probe="$WORKDIR/reach-path.txt"
  pointer="$WORKDIR/reach-pointer.txt"
  rm -f "$probe" "$pointer"
  rc=0
  env FORGE_CONTAINED_RUN_SCENARIO_PATH="/usr/bin:/bin" \
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 20 \
      --close-timeout 3 \
      -- /bin/sh "$scenario" \
         "$helper_dir/forge-containment-observer.sh" \
         "$helper_dir/forge-containment-killer.sh" \
         /bin/sh -c "printf '%s\n' \"\$PATH\" > '$probe'" \
      >"$WORKDIR/reach-plain.out" 2>"$WORKDIR/reach-plain.err" || rc=$?

  observed=""
  [ -s "$probe" ] && IFS= read -r observed < "$probe"
  if [ "$observed" = "/usr/bin:/bin" ]; then
    pass "la entrada anidada RECONSTRUYE el PATH de su escenario ($observed)"
  else
    fail "la entrada anidada NO reconstruyo el PATH de su escenario (obtenido: '$observed', rc=$rc)"
  fi
  if printf '%s\n' "$observed" | grep -qF "$NETWORK_GUARD_DIR"; then
    fail "la entrada anidada heredo el directorio de la restriccion SIN declararlo"
  else
    pass "la entrada anidada NO heredo el directorio de la restriccion sin declararlo"
  fi

  # (4) ... and it DOES reach it when the PATH of the scenario DECLARES it.
  declared="$NETWORK_GUARD_DIR:/usr/bin:/bin"
  rm -f "$probe" "$pointer"
  rc=0
  env FORGE_CONTAINED_RUN_SCENARIO_PATH="$declared" \
    bash "$ENTRY" \
      --receipt-dir "$RECEIPT_ROOT" \
      --receipt-out "$pointer" \
      --scenario-timeout 20 \
      --close-timeout 3 \
      -- /bin/sh "$scenario" \
         "$helper_dir/forge-containment-observer.sh" \
         "$helper_dir/forge-containment-killer.sh" \
         /bin/sh -c "printf '%s\n' \"\$PATH\" > '$probe'" \
      >"$WORKDIR/reach-declared.out" 2>"$WORKDIR/reach-declared.err" || rc=$?

  observed=""
  [ -s "$probe" ] && IFS= read -r observed < "$probe"
  if printf '%s\n' "$observed" | grep -qF "$NETWORK_GUARD_DIR"; then
    pass "la entrada anidada alcanza el directorio de la restriccion CUANDO lo DECLARA"
  else
    fail "la entrada anidada NO alcanzo el directorio de la restriccion declarado (obtenido: '$observed', rc=$rc)"
  fi
  rm -f "$scenario"
}

echo "================================"
echo " forge_contained_run_unit.sh"
echo "================================"
run_test test_the_boundary_and_the_closure_are_accredited
run_test test_a_detached_descendant_does_not_outlive_the_run
run_test test_the_product_result_is_separated_from_the_defensive_one
run_test test_the_timeout_is_bounded_and_visible
run_test test_the_interface_fails_closed
run_test test_the_reader_rejects_untrustworthy_evidence
run_test test_the_registry_rejects_absent_and_corrupted_evidence
run_test test_signal_is_bound_to_the_identity
run_test test_the_killer_refuses_the_protected_pid_and_the_non_own
run_test test_a_consumer_cannot_run_outside_the_containment
run_test test_a_normal_exit_is_certifiable
run_test test_the_captured_stderr_is_only_the_stderr_of_the_scenario
run_test test_a_failure_keeps_its_own_rc
run_test test_an_interruption_closes_the_contained_environment
run_test test_a_timeout_closes_the_contained_environment
run_test test_an_unconfirmed_closure_is_not_certified_and_preserves_the_context
run_test test_an_unrecoverable_launcher_status_is_not_certified
run_test test_a_scenario_that_ignores_term_is_closed_by_kill_and_observed
run_test test_an_interruption_is_certified_only_when_the_termination_was_observed
run_test test_the_streams_are_the_scenario_ones_with_and_without_the_receipt_out
run_test test_an_unaccredited_boundary_does_not_execute_the_scenario
run_test test_a_detached_descendant_does_not_survive_the_closure
run_test test_the_frontier_is_private_and_the_host_is_not_inspected
run_test test_the_reader_rejects_contradictory_evidence
run_test test_a_receipt_with_a_duplicated_field_is_rejected
run_test test_the_legacy_certifiable_key_is_not_an_alias
run_test test_the_protected_snapshot_never_reads_the_content_of_a_personal_tree
run_test test_the_isolation_helper_has_a_single_definition_of_the_entry
run_test test_the_definition_scanner_decides_by_the_lexical_context
run_test test_the_declared_path_of_the_scenario_is_used
run_test test_an_eliminated_scenario_leaves_no_residue
run_test test_the_recorded_identities_carry_their_starttime
run_test test_the_aggregate_never_masks_a_failed_declaration
run_test test_the_aggregate_never_improves_a_failure_with_a_malformed_scope
run_test test_the_cleanup_declaration_requires_a_satisfactory_observation
run_test test_the_observer_reports_an_incomplete_observation
run_test test_the_observer_requires_an_observable_root
run_test test_the_scenario_inherits_the_stdin_of_the_caller
run_test test_a_closed_stdin_falls_back_explicitly_to_eof
run_test test_the_interruption_is_observed_by_the_pid1
run_test test_the_harness_infrastructure_is_not_inside_the_frontier
run_test test_the_clean_1_excludes_the_harness_by_ancestry_and_still_detects_a_leftover
run_test test_the_official_observer_reports_an_incomplete_observation
run_test test_the_absence_of_a_process_is_confirmed_and_never_inferred
run_test test_the_battery_of_the_suites_uses_no_network
run_test test_the_bank_contract_of_the_eliminated_scenario_expects_the_sigkill
run_test test_the_admission_requires_the_kernel_handle_of_the_invoker
run_test test_the_exit_code_of_the_eliminated_scenario_is_the_observed_signal
run_test test_the_closure_verdict_requires_every_link_and_observes_the_absence
run_test test_the_cleanup_verdict_requires_the_verified_absence_in_both_entries
run_test test_the_observations_distinguish_an_absent_resource_from_an_impossible_one
run_test test_the_protected_pid_is_refused_whatever_the_environment_declares
run_test test_the_registry_detector_requires_an_accredited_boundary
run_test test_the_definition_scanner_recognises_the_whole_heredoc_delimiter
run_test test_the_network_scanner_recognises_the_imports_and_the_aliases
run_test test_the_network_is_effectively_restricted_during_the_battery
run_test test_an_absent_socket_table_is_not_an_observation_of_the_port
run_test test_the_network_restriction_states_the_interpreters_that_it_reaches

echo ""
echo "================================"
# The summary is computed from the file of results: the checks run in
# subshells and their counters do not survive them.
PASS="$(awk '$1 == "PASS" { c++ } END { print c + 0 }' "$RESULTS_FILE")"
FAIL="$(awk '$1 == "FAIL" { c++ } END { print c + 0 }' "$RESULTS_FILE")"
echo " Passed: $PASS"
if [ "$FAIL" -ne 0 ]; then
  echo " FAIL: some tests failed" >&2
  exit 1
fi
echo " ALL PASS"
