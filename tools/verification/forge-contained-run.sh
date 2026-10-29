#!/usr/bin/env bash

# Single supported entry point for bounded scenarios in a private PID namespace.
# Keep the outer launcher intentionally small: unshare -> PID 1 shell. The
# scenario timeout runs inside PID 1 so no timeout process can kill unshare
# before unshare has waited for PID 1.

readonly RECEIPT_ROOT='/tmp/opencode/forge-contracts-v2/remediacion-contencion/runs'
readonly UN_SHARE='/usr/bin/unshare'
readonly SETSID='/usr/bin/setsid'
readonly TIMEOUT='/usr/bin/timeout'
readonly ENV_BIN='/usr/bin/env'

# Bash cannot reset a signal disposition that was SIG_IGN when it started.
# Re-exec through GNU env so the entry process starts again with defaults for
# precisely the signals for which it installs handlers below. env and the
# re-executed Bash retain this PID; the PID marker prevents a re-exec loop.
if [[ ${FORGE_CONTAINED_RUN_SIGNAL_DEFAULTED_PID:-} != "$BASHPID" ]]; then
  exec "$ENV_BIN" \
    --default-signal=INT \
    --default-signal=TERM \
    --default-signal=HUP \
    "FORGE_CONTAINED_RUN_SIGNAL_DEFAULTED_PID=$BASHPID" \
    "$BASH" "$0" "$@"
  printf 'Cannot reset managed signal dispositions before startup\n' >&2
  exit 69
fi
unset FORGE_CONTAINED_RUN_SIGNAL_DEFAULTED_PID

usage() {
  printf '%s\n' \
    'Usage: bash tools/verification/forge-contained-run.sh --receipt-dir /tmp/opencode/forge-contracts-v2/remediacion-contencion/runs [--receipt-out <file>] --scenario-timeout <1..3600> --close-timeout <1..60> -- <command> [args...]' >&2
}

valid_seconds() {
  [[ $1 =~ ^[1-9][0-9]{0,3}$ ]] && (( 10#$1 <= $2 ))
}

receipt_root=''
receipt_out=''
scenario_timeout=''
close_timeout=''
declare -a scenario_argv=()

while (($#)); do
  case $1 in
    --receipt-dir)
      (($# >= 2)) || { usage; exit 64; }
      [[ -z $receipt_root ]] || { usage; exit 64; }
      receipt_root=$2
      shift 2
      ;;
    --receipt-out)
      (($# >= 2)) || { usage; exit 64; }
      [[ -z $receipt_out ]] || { usage; exit 64; }
      receipt_out=$2
      shift 2
      ;;
    --scenario-timeout)
      (($# >= 2)) || { usage; exit 64; }
      [[ -z $scenario_timeout ]] || { usage; exit 64; }
      scenario_timeout=$2
      shift 2
      ;;
    --close-timeout)
      (($# >= 2)) || { usage; exit 64; }
      [[ -z $close_timeout ]] || { usage; exit 64; }
      close_timeout=$2
      shift 2
      ;;
    --)
      shift
      scenario_argv=("$@")
      break
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[[ $receipt_root == "$RECEIPT_ROOT" ]] || { usage; exit 64; }
valid_seconds "${scenario_timeout:-}" 3600 || { usage; exit 64; }
valid_seconds "${close_timeout:-}" 60 || { usage; exit 64; }
((${#scenario_argv[@]} > 0)) || { usage; exit 64; }

# The expected RC of the contained scenario is a property of THIS invocation,
# not a global constant of the entry: an invocation that must succeed expects
# 0, and an invocation that injects a fault expects the RC contracted for
# that fault. The literal NONE declares that the scenario is expected NOT to
# produce an RC at all, because the bounded close has to ELIMINATE it (the
# scenario hangs on purpose). The expectation travels in the environment of
# the invocation and is recorded in the receipt, so the verdict of the entry
# and the verdict of its consumer can never disagree about it.
# An absent variable keeps the default: an invocation that must succeed.
expected_scenario_rc=${FORGE_CONTAINED_RUN_EXPECTED_SCENARIO_RC-0}
case "$expected_scenario_rc" in
  NONE) ;;
  ''|*[!0-9]*) usage; exit 64 ;;
esac

# The PATH of the scenario.
#
# The entry NEVER inherits the PATH of the caller: that PATH can expose the
# global runtime of the host (and the global installation lives in a
# directory of the personal HOME), which this remediation does not authorise.
# The scenario therefore gets the standard, deterministic PATH.
#
# A caller whose scenario needs a runtime that is NOT in the standard PATH (a
# language runtime, for example) DECLARES it explicitly with
# FORGE_CONTAINED_RUN_SCENARIO_PATH. The declaration is explicit, it is
# recorded in the receipt and it never widens the environment of the scenario
# beyond its PATH.
scenario_path=${FORGE_CONTAINED_RUN_SCENARIO_PATH:-/usr/bin:/bin}
if [ -z "$scenario_path" ] || printf '%s' "$scenario_path" | grep -q '[[:space:]]'; then
  printf 'The declared PATH of the scenario is invalid (it must not be empty nor contain blanks)\n' >&2
  exit 64
fi

for required_tool in \
  "$UN_SHARE" "$SETSID" "$TIMEOUT" "$ENV_BIN" /usr/bin/mktemp /usr/bin/date /usr/bin/grep \
  /usr/bin/mv /usr/bin/readlink /usr/bin/awk /usr/bin/stat /usr/bin/rm \
  /usr/bin/sleep /bin/mkdir /bin/cat /bin/sh; do
  [[ -x $required_tool ]] || {
    printf 'Required standard tool unavailable: %s\n' "$required_tool" >&2
    exit 69
  }
done

# Keep a kernel-backed reference to the PID namespace of the invoking side.
# The admission helper uses this inherited namespace FD (not a caller-supplied
# string or receipt field) to reject execution that remained in the outer
# namespace. FD 8 is deliberately preserved across unshare/env -i to the
# contained scenario; the inner script closes only its private FDs 5 and 9.
if ! exec 8</proc/self/ns/pid; then
  printf 'Cannot retain the invoking PID namespace as an admission reference\n' >&2
  exit 69
fi

umask 077
if ! mkdir -p -- "$receipt_root"; then
  printf 'Cannot create receipt root: %s\n' "$receipt_root" >&2
  exit 73
fi

started_at=$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') || exit 70
run_dir=$(/usr/bin/mktemp -d -- "$receipt_root/run-${started_at//[-:]/}-$$-XXXXXXXX") || {
  printf 'Cannot allocate a unique receipt directory under %s\n' "$receipt_root" >&2
  exit 73
}
run_id=${run_dir##*/}
receipt_file=$run_dir/receipt.txt
timeout_log=$run_dir/timeout.stderr
context_root=$run_dir/context
infrastructure_stdout=$run_dir/infrastructure.stdout
infrastructure_stderr=$run_dir/infrastructure.stderr

# Preserve the consumer's stream descriptors before routing every later
# diagnostic from the entry/containment machinery into this invocation's own
# evidence. The scenario receives only the saved descriptors 3 and 4.
if ! : > "$infrastructure_stdout" || ! : > "$infrastructure_stderr"; then
  printf 'Cannot create infrastructure diagnostic evidence under %s\n' "$run_dir" >&2
  exit 73
fi
exec 3>&1 4>&2
exec >>"$infrastructure_stdout" 2>>"$infrastructure_stderr"

# The receipt path is published BEFORE any contained work starts, so a
# consumer never has to guess which run directory belongs to its invocation
# (and never has to enumerate the receipt root looking for it).
if [[ -n $receipt_out ]]; then
  if ! printf '%s\n' "$receipt_file" > "$receipt_out"; then
    printf 'Cannot publish the receipt path to %s\n' "$receipt_out" >&2
    exit 73
  fi
else
  # FD 9 is the dedicated receipt-path channel when --receipt-out is omitted.
  # Do not borrow stdout/stderr: both belong exclusively to the scenario.
  if ! { : >&9; } 2>/dev/null; then
    printf 'Without --receipt-out, the caller must open descriptor 9 for the receipt path\n' >&2
    exit 73
  fi
  if ! printf '%s\n' "$receipt_file" >&9; then
    printf 'Cannot publish the receipt path on descriptor 9\n' >&2
    exit 73
  fi
fi

redact_order() {
  local arg safe quoted secret_next=0 key
  local -a rendered=()
  shopt -s nocasematch
  for arg in "${scenario_argv[@]}"; do
    if ((secret_next)); then
      safe='[REDACTED]'
      secret_next=0
    elif [[ $arg =~ ^(--?(password|passwd|token|secret|credential|api[-_]?key|access[-_]?key|client[-_]?secret|private[-_]?key|authorization|auth))$ ]]; then
      safe=$arg
      secret_next=1
    elif [[ $arg =~ ^(--?[a-z0-9_-]*(password|passwd|token|secret|credential|api[-_]?key|access[-_]?key|client[-_]?secret|private[-_]?key|authorization|auth)[a-z0-9_-]*)(=|:).*$ ]]; then
      key=${BASH_REMATCH[1]}
      safe="$key=[REDACTED]"
    elif [[ $arg =~ (Bearer[[:space:]]+|Basic[[:space:]]+|sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{12,}|AKIA[0-9A-Z]{16}|-----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY-----) ]]; then
      safe='[REDACTED]'
    elif [[ $arg =~ (password|passwd|token|secret|credential|api[-_]?key|access[-_]?key|client[-_]?secret|private[-_]?key|authorization)[[:space:]]*[:=] ]]; then
      safe='[REDACTED]'
    else
      safe=$arg
    fi
    printf -v quoted '%q' "$safe"
    rendered+=("$quoted")
  done
  shopt -u nocasematch
  local IFS=' '
  printf '%s' "${rendered[*]}"
}

scenario_order=$(redact_order)
home_dir=$context_root/home
xdg_config_dir=$context_root/xdg-config
xdg_data_dir=$context_root/xdg-data
xdg_cache_dir=$context_root/xdg-cache
xdg_state_dir=$context_root/xdg-state
tmp_dir=$context_root/tmp

interruption='NONE'
runner_pid=''
runner_waited='NO'
waiting_for_runner='NO'
wait_interrupted='NO'
runner_starttime=''
signal_forwarded='NOT_REQUESTED'
pid1_completion='NO'
runner_rc='NOT_STARTED'
scenario_rc='NOT_AVAILABLE'
scenario_status='NOT_STARTED'
accreditation='FAILED'
accreditation_reason='NO_INTERIOR_ATTESTATION'
pid_namespace='UNKNOWN'
mount_namespace='UNKNOWN'
inner_pid='UNKNOWN'
nspid='UNKNOWN'
procfs_type='UNKNOWN'
proc_mount='UNKNOWN'
product_cleanup='UNKNOWN'
product_cleanup_observed='NO'
# The SCOPE of the declaration of this invocation: PRODUCT (the default) or
# NOT_APPLICABLE (the scenario did not exercise the product). It is declared
# by the scenario and it is refined below when the boundary was not
# accredited (then the scenario never started and the product never ran).
case ${FORGE_CONTAINED_RUN_DECLARATION_SCOPE:-PRODUCT} in
  PRODUCT|NOT_APPLICABLE) declaration_scope=${FORGE_CONTAINED_RUN_DECLARATION_SCOPE:-PRODUCT} ;;
  *) declaration_scope='INVALID' ;;
esac
declaration_collector_publication='NOT_REQUESTED'
defensive_cleanup='UNKNOWN'
context_removed_by='NONE'
context_present_after='UNKNOWN'
closure='UNCONFIRMED'
receipt_completeness='INCOMPLETE'
containment_evidence_certifiable='NO'
# expected_scenario_rc was declared (and validated) with the arguments of
# this invocation: it is the RC contracted for THIS scenario, not a global 0.
positive_acceptance='NO'
wrapper_rc=70
ended_at='PENDING'

write_receipt() {
  local destination=$receipt_file
  local temporary=$run_dir/.receipt-write-$$
  /bin/cat > "$temporary" <<EOF
IDENTIFIER=$run_id
RECEIPT_PATH=$receipt_file
STARTED_UTC=$started_at
ENDED_UTC=$ended_at
SCENARIO_ORDER_LITERAL=$scenario_order
SCENARIO_PATH=$scenario_path
INFRASTRUCTURE_STDOUT=$infrastructure_stdout
INFRASTRUCTURE_STDERR=$infrastructure_stderr
SCENARIO_TIMEOUT_SECONDS=${scenario_timeout}s
CLOSURE_BUDGET_SECONDS=${close_timeout}s
HOME_TEMP=$home_dir
XDG_CONFIG_HOME_TEMP=$xdg_config_dir
XDG_DATA_HOME_TEMP=$xdg_data_dir
XDG_CACHE_HOME_TEMP=$xdg_cache_dir
XDG_STATE_HOME_TEMP=$xdg_state_dir
TMPDIR_TEMP=$tmp_dir
PID_NAMESPACE=$pid_namespace
MOUNT_NAMESPACE=$mount_namespace
PID1_INTERIOR=$inner_pid
NSPID=$nspid
PROCFS_TYPE=$procfs_type
PROC_MOUNT_PRIVATE=$proc_mount
ACCREDITATION=$accreditation
ACCREDITATION_REASON=$accreditation_reason
SCENARIO_STATUS=$scenario_status
SCENARIO_RC=$scenario_rc
INTERRUPTION_CAUSE=$interruption
INTERRUPTION_FORWARDING=$signal_forwarded
PRODUCT_CLEANUP_RESULT=$product_cleanup
PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP=$product_cleanup_observed
DECLARATION_SCOPE=$declaration_scope
DECLARATION_COLLECTOR_PUBLICATION=$declaration_collector_publication
DEFENSIVE_CLEANUP=$defensive_cleanup
DEFENSIVE_CLEANUP_REMOVED_BY=$context_removed_by
CONTEXT_PRESENT_AFTER=$context_present_after
EXPECTED_SCENARIO_RC=$expected_scenario_rc
EXPECTED_TERMINATION=PID1 exits; kernel tears down its PID namespace; unshare waits for PID1; outer wait reaps unshare
LAUNCHER_RC=$runner_rc
LAUNCHER_WAIT_COMPLETED=$runner_waited
PID1_COMPLETION_OBSERVED=$pid1_completion
CLOSURE=$closure
RECEIPT_COMPLETENESS=$receipt_completeness
CONTAINMENT_EVIDENCE_CERTIFIABLE=$containment_evidence_certifiable
POSITIVE_ACCEPTANCE=$positive_acceptance
WRAPPER_EXIT_CODE=$wrapper_rc
EOF
  if [[ -s $temporary ]] && /usr/bin/mv -f -- "$temporary" "$destination"; then
    return 0
  fi
  return 1
}

# Keep a durable, explicitly incomplete receipt before starting any contained work.
if ! write_receipt; then
  printf 'Cannot initialize receipt: %s\n' "$receipt_file" >&2
  exit 73
fi

on_signal() {
  local signal_name=$1
  if [[ $interruption == NONE ]]; then
    interruption=$signal_name
  fi
  # Record the request outside the PID namespace. The main wait loop wakes
  # PID 1 through this invocation's private launcher process group; unshare
  # ignores the signal and PID 1 handles it. No relay process exists inside
  # the namespace for CLEAN-1 to mistake for product residue.
  if [[ -n $run_dir ]]; then
    printf '%s\n' "$interruption" > "$run_dir/interruption.request" 2>/dev/null || true
  fi
  if [[ $waiting_for_runner == YES ]]; then
    wait_interrupted=YES
  fi
  if [[ -n $runner_pid ]] && declare -F forward_interruption >/dev/null 2>&1; then
    forward_interruption
  fi
}
trap 'on_signal SIGINT' INT
trap 'on_signal SIGTERM' TERM
trap 'on_signal SIGHUP' HUP

runner_process_details() {
  local pid=$1
  /usr/bin/awk '
    {
      raw=$0
      sub(/^.*\) /, "", raw)
      count=split(raw, fields, /[[:space:]]+/)
      if (count < 20) exit 1
      printf "%s %s %s\n", fields[1], fields[3], fields[20]
      exit
    }
  ' "/proc/$pid/stat" 2>/dev/null
}

forward_interruption() {
  local details state process_group starttime attempt
  [[ $interruption != NONE && $signal_forwarded != OBSERVED_BY_PID1 && $signal_forwarded != REQUEST_SENT ]] || return 0
  [[ -n $runner_pid && $runner_starttime =~ ^[0-9]+$ ]] || return 0

  # PID 1 writes readiness only after installing its handlers. The short
  # bounded wait avoids delivering the wake-up before the inner reader exists;
  # an earlier request is read directly from the file when PID 1 starts.
  for ((attempt = 0; attempt < 100; attempt++)); do
    if [[ -f $run_dir/pid1.signal-ready ]]; then
      details=$(runner_process_details "$runner_pid") || return 0
      read -r state process_group starttime <<< "$details"
      [[ $process_group == "$runner_pid" && $starttime == "$runner_starttime" && $state != Z ]] || return 0
      if kill -s "$interruption" -- "-$runner_pid" 2>/dev/null; then
        signal_forwarded='REQUEST_SENT'
      fi
      return 0
    fi
    details=$(runner_process_details "$runner_pid") || return 0
    read -r state process_group starttime <<< "$details"
    [[ $process_group == "$runner_pid" && $starttime == "$runner_starttime" && $state != Z ]] || return 0
    /usr/bin/sleep 0.01
  done
}

INNER_SCRIPT=$(/bin/cat <<'INNER'
set -f
exec 9>&-
exec 5<&-
if ! exec 5<&0; then
  exit 70
fi
run_dir=$1
shift
run_id=${run_dir##*/}
receipt_file=$run_dir/receipt.txt
context_root=$run_dir/context
write_status() {
  printf '%s\n' "$2" > "$run_dir/$1"
}
finish_pid1() {
  write_status pid1.completion.status PASS || exit 70
  # The outer wrapper certifies only an unshare wait whose child returned this
  # clean completion status. Scenario status is carried separately in files.
  exit 0
}

interruption=NONE
timeout_pid=''
wait_interrupted=NO
handle_signal() {
  requested_signal=$1
  if [ -f "$run_dir/interruption.request" ]; then
    IFS= read -r requested_signal < "$run_dir/interruption.request" || requested_signal=$1
  fi
  case $requested_signal in
    SIGINT|SIGTERM|SIGHUP) : ;;
    *) requested_signal=$1 ;;
  esac
  if [ "$interruption" = NONE ]; then interruption=$requested_signal; fi
  write_status pid1.interruption.status "$interruption" 2>/dev/null || true
  if [ -n "$timeout_pid" ]; then
    # PID 1 relays the request to its direct timeout child. GNU timeout runs
    # with --foreground (no separate process group) and waits for its scenario.
    kill -TERM "$timeout_pid" 2>/dev/null || true
  fi
  wait_interrupted=YES
}
trap 'handle_signal SIGINT' INT
trap 'handle_signal SIGTERM' TERM
trap 'handle_signal SIGHUP' HUP
write_status pid1.signal-ready PASS || exit 70
if [ -f "$run_dir/interruption.request" ]; then
  handle_signal SIGTERM
fi

pid_namespace=$(/usr/bin/readlink /proc/self/ns/pid 2>/dev/null) || pid_namespace=UNKNOWN
pid1_namespace=$(/usr/bin/readlink /proc/1/ns/pid 2>/dev/null) || pid1_namespace=UNKNOWN
mount_namespace=$(/usr/bin/readlink /proc/self/ns/mnt 2>/dev/null) || mount_namespace=UNKNOWN
nspid=UNKNOWN
while IFS= read -r status_line; do
  case $status_line in
    NSpid:*) nspid=${status_line#NSpid:}; nspid=${nspid#"${nspid%%[![:space:]]*}"} ;;
  esac
done < /proc/self/status
pid1_nspid=UNKNOWN
while IFS= read -r status_line; do
  case $status_line in
    NSpid:*) pid1_nspid=${status_line#NSpid:}; pid1_nspid=${pid1_nspid#"${pid1_nspid%%[![:space:]]*}"} ;;
  esac
done < /proc/1/status
pid1_stat=$(/usr/bin/awk '{ print $1; exit }' /proc/1/stat 2>/dev/null) || pid1_stat=UNKNOWN
procfs_type=$(/usr/bin/stat -f -c '%T' /proc 2>/dev/null) || procfs_type=UNKNOWN
if /usr/bin/awk '$5 == "/proc" { for (i=6; i<=NF; i++) if ($i == "-") { if ($(i+1) == "proc") found=1; break } } END { exit !found }' /proc/self/mountinfo 2>/dev/null; then
  proc_mount=YES
else
  proc_mount=NO
fi

accreditation_reason=PASS
if [ "$$" != 1 ] || [ "$pid1_stat" != 1 ] || [ "$pid1_namespace" != "$pid_namespace" ]; then
  accreditation_reason=PID_BOUNDARY_MISMATCH
elif [ "$nspid" != 1 ] || [ "$pid1_nspid" != 1 ]; then
  accreditation_reason=NSPID_MISMATCH
elif [ "$procfs_type" != proc ] || [ "$proc_mount" != YES ]; then
  accreditation_reason=PROCFS_MISSING_OR_WRONG
elif [ "$mount_namespace" = UNKNOWN ]; then
  accreditation_reason=MOUNT_NAMESPACE_UNREADABLE
fi

{
  printf 'PID_NAMESPACE=%s\n' "$pid_namespace"
  printf 'MOUNT_NAMESPACE=%s\n' "$mount_namespace"
  printf 'PID1_INTERIOR=%s\n' "$$"
  printf 'NSPID=%s\n' "$nspid"
  printf 'PROCFS_TYPE=%s\n' "$procfs_type"
  printf 'PROC_MOUNT_PRIVATE=%s\n' "$proc_mount"
} > "$run_dir/accreditation.details" 2>/dev/null || exit 70

if [ "$accreditation_reason" != PASS ]; then
  write_status accreditation.status FAILED || exit 70
  write_status accreditation.reason "$accreditation_reason" || exit 70
  finish_pid1
fi
write_status accreditation.status PASS || exit 70
write_status accreditation.reason PASS || exit 70

if ! /bin/mkdir -p -- "$context_root/home" "$context_root/xdg-config" "$context_root/xdg-data" "$context_root/xdg-cache" "$context_root/xdg-state" "$context_root/tmp"; then
  write_status setup.status FAILED || exit 73
  finish_pid1
fi
write_status setup.status PASS || exit 70

if [ "$interruption" != NONE ]; then finish_pid1; fi

/usr/bin/timeout --foreground --verbose --signal=TERM \
  --kill-after="${FORGE_CONTAINED_CLOSE_TIMEOUT:-1}s" \
  "${FORGE_CONTAINED_SCENARIO_TIMEOUT:-1}s" \
  /bin/sh -c 'exec "$@" >&3 2>&4 3>&- 4>&- 5<&-' forge-contained-scenario \
  /usr/bin/env -i \
  PATH="${FORGE_CONTAINED_SCENARIO_PATH:-/usr/bin:/bin}" \
  LC_ALL=C TZ=UTC \
  HOME="$context_root/home" \
  XDG_CONFIG_HOME="$context_root/xdg-config" \
  XDG_DATA_HOME="$context_root/xdg-data" \
  XDG_CACHE_HOME="$context_root/xdg-cache" \
  XDG_STATE_HOME="$context_root/xdg-state" \
  TMPDIR="$context_root/tmp" \
  FORGE_PRODUCT_CLEANUP_RESULT_FILE="$run_dir/product-cleanup.result" \
  FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE="${FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE:-}" \
  FORGE_CONTAINED_RUN_DECLARATION_SCOPE="${FORGE_CONTAINED_RUN_DECLARATION_SCOPE:-PRODUCT}" \
  FORGE_CONTAINED_RUN_ID="$run_id" \
  FORGE_CONTAINED_RUN_RECEIPT="$receipt_file" \
  FORGE_CONTAINED_RUN_ACCREDITATION_FILE="$run_dir/accreditation.status" \
  FORGE_CONTAINED_RUN_PID_NAMESPACE="$pid_namespace" \
  FORGE_CONTAINED_RUN_MOUNT_NAMESPACE="$mount_namespace" \
  "$@" <&5 2> "$run_dir/timeout.stderr" &
timeout_pid=$!
if [ "$interruption" != NONE ]; then
  kill -TERM "$timeout_pid" 2>/dev/null || true
fi
while :; do
  wait "$timeout_pid"
  scenario_rc=$?
  if [ "$wait_interrupted" = YES ]; then
    wait_interrupted=NO
    continue
  fi
  break
done
timeout_pid=''
write_status scenario.rc "$scenario_rc" || exit 70

product_state=UNKNOWN
if [ -f "$run_dir/product-cleanup.result" ]; then
  product_state=$(/usr/bin/awk 'NR == 1 { value=$0 } NR > 1 { invalid=1 } END { if (NR == 1 && !invalid && (value == "PASS" || value == "FAIL")) print value; else exit 1 }' "$run_dir/product-cleanup.result" 2>/dev/null) || product_state=UNKNOWN
fi
if [ "$product_state" = PASS ] || [ "$product_state" = FAIL ]; then
  {
    printf 'RESULT=%s\n' "$product_state"
    printf 'OBSERVED_BEFORE_DEFENSIVE_CLEANUP=YES\n'
  } > "$run_dir/product-cleanup.observed" 2>/dev/null || product_state=UNKNOWN
else
  {
    printf 'RESULT=UNKNOWN\n'
    printf 'OBSERVED_BEFORE_DEFENSIVE_CLEANUP=NO\n'
  } > "$run_dir/product-cleanup.observed" 2>/dev/null || true
fi

# The context is intentionally left for the outer wrapper. It may delete it
# only after a confirmed wait on unshare (which itself waited for PID 1 and
# kernel teardown of the namespace).
finish_pid1
INNER
)

# The bounded timeout is a child of PID 1, not a wrapper around unshare.
# Therefore timeout cannot kill the process responsible for waiting on PID 1.
  # The environment of the INNER is REBUILT with `env -i`: nothing of the
  # environment of the caller leaks into the scenario. The only declaration
  # metadata that crosses that boundary is the OPT-IN collector path and the
  # normalized declaration scope. They support nested contained invocations;
  # they are not an authenticated channel against scenario code.
  declare -a inner_env=(
    "PATH=/usr/bin:/bin"
    "LC_ALL=C"
    "TZ=UTC"
    "FORGE_CONTAINED_SCENARIO_PATH=$scenario_path"
  )
  if [[ -n ${FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE:-} ]]; then
    inner_env+=("FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE=$FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE")
  fi
  # Scope is explicit data too: nested contained invocations must receive the
  # caller's declared scope across both `env -i` boundaries. Invalid values
  # are propagated as INVALID so a child cannot silently normalize them.
  inner_env+=("FORGE_CONTAINED_RUN_DECLARATION_SCOPE=$declaration_scope")
# Save stdin before starting an asynchronous runner: POSIX shells otherwise
# give background commands /dev/null on descriptor 0. `/proc/self/fd/0` being
# readable only describes the referenced object; fdinfo flags reveal whether
# this descriptor was actually opened O_RDONLY or O_RDWR. O_WRONLY and O_PATH
# are not valid input sources, so they use the documented EOF fallback.
stdin_flags=''
if [[ -r /proc/self/fdinfo/0 ]] && exec 7</proc/self/fdinfo/0; then
  while IFS=$' \t' read -r -u 7 flag_name flag_value _; do
    if [[ $flag_name == flags: ]]; then
      stdin_flags=$flag_value
      break
    fi
  done
  exec 7<&-
fi
stdin_readable=NO
if [[ $stdin_flags =~ ^[0-7]+$ ]]; then
  stdin_mode=$((8#$stdin_flags & 3))
  if ((stdin_mode == 0 || stdin_mode == 2)); then
    stdin_readable=YES
  fi
fi
if [[ $stdin_readable == YES ]]; then
  if ! exec 5<&0; then
    exec 5</dev/null || exit 73
  fi
else
  exec 5</dev/null || exit 73
fi

# Do not let Bash's monitor mode put the launcher in a background job group:
# a scenario reading from a controlling PTY would receive SIGTTIN. With job
# control disabled, setsid is not already a process-group leader, so it
# creates a session whose process group is the direct child's PID and execs
# unshare without forking. Its inherited FD 0 still refers to the caller's PTY;
# GNU timeout uses --foreground so it does not move the scenario to a second
# background process group. The group and starttime are checked against the
# known direct child before any signal is sent.
  set +m
  "$ENV_BIN" -i --ignore-signal=INT --ignore-signal=TERM --ignore-signal=HUP "${inner_env[@]}" \
    FORGE_CONTAINED_SCENARIO_TIMEOUT="${scenario_timeout}" \
    FORGE_CONTAINED_CLOSE_TIMEOUT="${close_timeout}" \
    "$SETSID" "$UN_SHARE" --user --map-root-user --pid --fork --kill-child=KILL --mount-proc \
    /usr/bin/env --default-signal=INT --default-signal=TERM --default-signal=HUP \
    /bin/sh -c "$INNER_SCRIPT" forge-contained-run-inner "$run_dir" "${scenario_argv[@]}" \
    <&5 &
  runner_pid=$!
  set +m
  exec 5<&-
  runner_details=$(runner_process_details "$runner_pid") || runner_details=''
  if [[ -n $runner_details ]]; then
    read -r runner_state runner_pgrp runner_starttime <<< "$runner_details"
  fi
  if [[ $interruption != NONE ]]; then
    forward_interruption
  fi
  while :; do
    waiting_for_runner=YES
    wait "$runner_pid"
    runner_wait_rc=$?
    waiting_for_runner=NO
    if [[ $wait_interrupted == YES ]]; then
      wait_interrupted=NO
      runner_details=$(runner_process_details "$runner_pid") || runner_details=''
      if [[ -z $runner_details ]]; then
        # The launcher has exited: the interrupted wait's 128+signal value
        # is not its status. Retry the wait to obtain the real status. Bash
        # returns 127 if the child is no longer waitable; preserve that as an
        # unavailable status and fail closed rather than certifying it as 0.
        runner_rc=0
        wait "$runner_pid" 2>/dev/null || runner_rc=$?
        if [[ $runner_rc == 127 ]]; then
          runner_rc=NOT_RECOVERABLE
          runner_waited=NO
        else
          runner_waited=YES
        fi
        break
      fi
      read -r runner_state runner_pgrp runner_current_starttime <<< "$runner_details"
      if [[ $runner_pgrp == "$runner_pid" && $runner_current_starttime == "$runner_starttime" && $runner_state != Z ]]; then
        forward_interruption
      fi
      continue
    fi
    runner_rc=$runner_wait_rc
    runner_waited=YES
    break
  done

  if [[ $interruption != NONE ]]; then
    if [[ -f $run_dir/pid1.interruption.status ]]; then
      IFS= read -r pid1_interruption < "$run_dir/pid1.interruption.status" || pid1_interruption=''
      if [[ $pid1_interruption == "$interruption" ]]; then
        signal_forwarded='OBSERVED_BY_PID1'
      else
        signal_forwarded='UNCONFIRMED'
      fi
    else
      signal_forwarded='UNCONFIRMED'
    fi
  else
    signal_forwarded='NOT_REQUESTED'
  fi

# ---------------------------------------------------------------------------
# The defensive cleanup of the context of THIS run.
#
# The outer side removes the context only after confirming both the clean PID 1
# completion marker and the completed wait for the direct unshare child. If
# either link is missing, no deletion is safe to certify, so preserve context.
# ---------------------------------------------------------------------------
if [[ -f $run_dir/pid1.completion.status ]]; then
  IFS= read -r pid1_completion < "$run_dir/pid1.completion.status" || pid1_completion=NO
fi
if [[ $runner_waited == YES && $runner_rc == 0 && $pid1_completion == PASS ]]; then
  closure=CONFIRMED
else
  closure=UNCONFIRMED
fi
if [[ $closure == CONFIRMED ]]; then
  if [[ -e $context_root ]]; then
    if /usr/bin/rm -rf -- "$context_root" && [[ ! -e $context_root ]]; then
      context_removed_by='OUTER'
      defensive_cleanup=PASS
    else
      context_removed_by='NONE'
      defensive_cleanup=FAIL
    fi
  else
    context_removed_by='NOT_NEEDED'
    defensive_cleanup=PASS
  fi
  printf '%s\n' "$defensive_cleanup" > "$run_dir/defensive-cleanup.status" || defensive_cleanup=FAIL
else
  # Closure is not proven. Keep any remaining context and its evidence intact.
  context_removed_by='NONE'
  defensive_cleanup=UNKNOWN
fi
if [[ -e $context_root ]]; then
  context_present_after='YES'
else
  context_present_after='NO'
fi

if [[ -f $run_dir/accreditation.status ]]; then
  IFS= read -r accreditation < "$run_dir/accreditation.status" || accreditation=FAILED
fi
if [[ -f $run_dir/accreditation.reason ]]; then
  IFS= read -r accreditation_reason < "$run_dir/accreditation.reason" || accreditation_reason=NO_REASON_RECORDED
fi
if [[ -f $run_dir/accreditation.details ]]; then
  while IFS='=' read -r key value; do
    case $key in
      PID_NAMESPACE) [[ $value =~ ^pid:\[[0-9]+\]$ ]] && pid_namespace=$value ;;
      MOUNT_NAMESPACE) [[ $value =~ ^mnt:\[[0-9]+\]$ ]] && mount_namespace=$value ;;
      PID1_INTERIOR) [[ $value == 1 ]] && inner_pid=$value ;;
      NSPID) [[ $value == 1 ]] && nspid=$value ;;
      PROCFS_TYPE) [[ $value == proc ]] && procfs_type=$value ;;
      PROC_MOUNT_PRIVATE) [[ $value == YES ]] && proc_mount=$value ;;
    esac
  done < "$run_dir/accreditation.details"
fi

if [[ -f $run_dir/scenario.rc ]]; then
  IFS= read -r scenario_rc < "$run_dir/scenario.rc" || scenario_rc=NOT_AVAILABLE
fi
if [[ -f $run_dir/product-cleanup.observed ]]; then
  while IFS='=' read -r key value; do
    case $key in
      RESULT) [[ $value == PASS || $value == FAIL || $value == UNKNOWN ]] && product_cleanup=$value ;;
      OBSERVED_BEFORE_DEFENSIVE_CLEANUP) [[ $value == YES || $value == NO ]] && product_cleanup_observed=$value ;;
    esac
  done < "$run_dir/product-cleanup.observed"
fi
if [[ -f $run_dir/defensive-cleanup.status ]]; then
  # The verdict of the cleanup was already read together with the cleanup
  # itself (see the defensive cleanup of the context above): it is NOT read
  # again here, because the OUTER side may have removed a residue that the
  # inner could not remove, and that verdict must not be overwritten.
  :
fi

# ---------------------------------------------------------------------------
# The SCOPE of the declaration of THIS invocation.
#
# The declaration of a scenario describes the cleanup of the PRODUCT only
# when the scenario EXERCISED the product. A scenario that injects a fault
# on purpose (a negative control of the harness) does NOT describe the
# cleanup of the product: its verdict is NOT APPLICABLE for the product.
#
# The scope is DECLARED by the scenario (it is the only one that knows
# whether it exercised the product) and it is OPT-IN: the default is
# PRODUCT, so a scenario that says nothing is treated as a real run of the
# product and its verdict is aggregated.
#
# A run whose boundary was NOT accredited never started the scenario, so a
# valid scope becomes NOT_APPLICABLE. Contradictory scope evidence remains
# INVALID and must not be normalized into a valid declaration.
# ---------------------------------------------------------------------------
case ${FORGE_CONTAINED_RUN_DECLARATION_SCOPE:-PRODUCT} in
  PRODUCT|NOT_APPLICABLE) : ;;
  # A scope that is neither one nor the other is CONTRADICTORY evidence: it
  # is published as it is, so that the consumer that aggregates the
  # declarations sees the contradiction and treats it as an UNKNOWN. It is
  # never normalised into a scope that could hide a verdict.
  *) declaration_scope="INVALID" ;;
esac
if [[ $accreditation != PASS ]]; then
  # A valid declaration is not applicable if the scenario never started.
  # Contradictory input remains INVALID even on this path, so it cannot be
  # laundered into a valid non-applicable declaration.
  [[ $declaration_scope == INVALID ]] || declaration_scope="NOT_APPLICABLE"
fi

# ---------------------------------------------------------------------------
# The publication of the declaration of THIS invocation to the collector of
# the consumer.
#
# The collector is a FILE whose path travels in the environment: it is
# OPT-IN (without it nothing is published). The scenario can write to this
# shared path, so the collector is a trusted-data channel, not authentication.
# The line carries the verdict AND the scope for consumer aggregation.
#
# The publication happens AFTER the scenario and BEFORE the exit of the
# entry: the verdict describes the cleanup of the product as it was OBSERVED
# (before the defensive cleanup), never as it was enforced.
# ---------------------------------------------------------------------------
if [[ -n ${FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE:-} ]]; then
  if printf '%s\t%s\t%s\n' "$run_id" "$product_cleanup" "$declaration_scope" \
    >> "$FORGE_PRODUCT_CLEANUP_DECLARATIONS_FILE" 2>/dev/null; then
    declaration_collector_publication='PUBLISHED'
  else
    declaration_collector_publication='FAILED'
  fi
fi

if [[ $interruption != NONE ]]; then
  scenario_status=INTERRUPTED
  case $interruption in
    SIGINT) wrapper_rc=130 ;;
    SIGTERM) wrapper_rc=143 ;;
    SIGHUP) wrapper_rc=129 ;;
  esac
elif /usr/bin/grep -Fq 'sending signal TERM' "$timeout_log" 2>/dev/null; then
  scenario_status=TIMEOUT
  wrapper_rc=124
elif [[ $accreditation != PASS ]]; then
  scenario_status=NOT_STARTED
  wrapper_rc=70
elif [[ $scenario_rc =~ ^[0-9]+$ ]]; then
  if ((scenario_rc == 0)); then scenario_status=COMPLETED; else scenario_status=FAILED; fi
  wrapper_rc=$scenario_rc
elif [[ $runner_rc =~ ^[0-9]+$ ]] && ((runner_rc != 0)); then
  scenario_status=NOT_CERTIFIABLE
  wrapper_rc=$runner_rc
else
  scenario_status=NOT_CERTIFIABLE
  wrapper_rc=70
fi

if [[ $runner_waited != YES ]]; then
  closure=UNCONFIRMED
  wrapper_rc=70
fi
if [[ $accreditation != PASS && $scenario_status != NOT_STARTED ]]; then
  accreditation=FAILED
  scenario_status=NOT_STARTED
  [[ $wrapper_rc != 0 ]] || wrapper_rc=70
fi
if [[ $scenario_status == COMPLETED && $defensive_cleanup != PASS ]]; then
  wrapper_rc=70
fi
if [[ $interruption != NONE && $signal_forwarded != OBSERVED_BY_PID1 ]]; then
  wrapper_rc=70
fi

ended_at=$(/usr/bin/date -u '+%Y-%m-%dT%H:%M:%SZ') || ended_at=UNKNOWN
receipt_completeness=COMPLETE
[[ $started_at != '' && $ended_at != UNKNOWN && $runner_waited == YES ]] || receipt_completeness=INCOMPLETE
[[ $accreditation == PASS || $scenario_status == NOT_STARTED ]] || receipt_completeness=INCOMPLETE
[[ $scenario_status != NOT_CERTIFIABLE ]] || receipt_completeness=INCOMPLETE
[[ $closure == CONFIRMED ]] || receipt_completeness=INCOMPLETE
[[ $interruption == NONE || $signal_forwarded == OBSERVED_BY_PID1 ]] || receipt_completeness=INCOMPLETE
if [[ $receipt_completeness == COMPLETE && $closure == CONFIRMED && $accreditation == PASS && $scenario_status != NOT_CERTIFIABLE && $defensive_cleanup == PASS ]]; then
  containment_evidence_certifiable=YES
fi
if [[ $containment_evidence_certifiable == YES && $scenario_rc == "$expected_scenario_rc" && $product_cleanup == PASS && $product_cleanup_observed == YES ]]; then
  positive_acceptance=YES
elif [[ $wrapper_rc == 0 ]]; then
  # A zero scenario RC alone is not positive acceptance. In particular, do
  # not return success when the product-cleanup evidence is absent or failed.
  wrapper_rc=70
fi
if [[ $declaration_collector_publication == FAILED && $wrapper_rc == 0 ]]; then
  # An opted-in consumer requested this evidence channel. Do not return a
  # successful entry result when its declaration could not be published.
  wrapper_rc=70
fi

if ! write_receipt 2>/dev/null; then
  exit 70
fi

exit "$wrapper_rc"
