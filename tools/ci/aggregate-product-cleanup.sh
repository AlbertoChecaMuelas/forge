#!/usr/bin/env bash
# Aggregate only the declarations published by each scenario. Missing,
# malformed, or unreadable declarations are UNKNOWN, never PASS.
#
# The declaration of a scenario governs the aggregate ONLY when the PRODUCT
# executed in that scenario. A scenario that injects a fault never runs the
# product: the authorization barrier is not released (no-pidfd) or the
# bounded close eliminates the scenario (no-pidfd-hang). In those scenarios
# there is no product that could leave a leftover, so their declaration does
# not describe the leftovers of the product and it is NOT APPLICABLE: an
# UNKNOWN there is the expected consequence of the injected fault, not a
# defect of the cleanup.
#
# A FAIL is always fatal, in EVERY scenario: a leftover that was observed
# anywhere invalidates the whole invocation.
#
# A report proves product execution only when its authorization state and
# recorded cases agree. A missing, malformed, or contradictory report is
# UNKNOWN, never evidence that the product did not execute.
set -euo pipefail

if (($# != 2)) || [[ -z $1 || -z $2 ]]; then
  printf 'Usage: %s <artifacts-dir> <result-file>\n' "$0" >&2
  exit 64
fi

artifacts_dir=$1
result_file=$2
aggregate=PASS
product_executed_anywhere=NO

product_execution_state() {
  local report=$1
  if [[ ! -f $report || -L $report ]]; then
    printf 'UNKNOWN\n'
    return 0
  fi
  python3 - "$report" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as stream:
        report = json.load(stream)
except (OSError, ValueError):
    print("UNKNOWN")
    raise SystemExit(0)

if not isinstance(report, dict):
    print("UNKNOWN")
    raise SystemExit(0)

cleanup = report.get("cleanup")
if not isinstance(cleanup, dict):
    print("UNKNOWN")
    raise SystemExit(0)

authorized = cleanup.get("authorization_granted")
cases = report.get("cases")
if cases is None:
    # The contained timeout scenario is eliminated before the suite can
    # publish its case list. Its report still records the authorization
    # barrier and the expected timeout. Do not infer non-execution from a
    # report that merely omits cases or has a partial cleanup section.
    #
    # The RC of the eliminated suite is OBSERVABLE in this architecture: the
    # bounded close of the containment entry escalates to SIGKILL and the
    # suite is killed with it, so its returncode is -9 (the convention of the
    # shell). "None" (an RC that could not be observed at all) belongs to the
    # previous architecture and is still accepted. Both of them mean ONE
    # thing here: the suite was ELIMINATED and it never executed the
    # product.
    eliminated = (
        authorized is False
        and cleanup.get("timed_out") is True
        and cleanup.get("suite_returncode") in (None, -9)
        and cleanup.get("expected_scenario_rc") == "NONE"
    )
    print("NO" if eliminated else "UNKNOWN")
    raise SystemExit(0)
if not isinstance(cases, list):
    print("UNKNOWN")
    raise SystemExit(0)

ids = []
for case in cases:
    if not isinstance(case, dict) or not isinstance(case.get("id"), str):
        print("UNKNOWN")
        raise SystemExit(0)
    ids.append(case["id"])

sensitive = any(case_id not in ("PRE-1", "PRE-2") for case_id in ids)
if authorized is True and sensitive:
    print("YES")
elif authorized is False and not sensitive:
    print("NO")
else:
    # Authorization without a sensitive case, or a sensitive case without
    # authorization, is contradictory/incomplete evidence.
    print("UNKNOWN")
PY
}

for scenario in normal no-pidfd no-pidfd-hang; do
  declaration_file="$artifacts_dir/scenarios/$scenario/product-cleanup.result"
  report_file="$artifacts_dir/scenarios/$scenario/safety-results.json"
  declaration=UNKNOWN
  if [[ -f $declaration_file && ! -L $declaration_file ]]; then
    mapfile -t lines <"$declaration_file"
    if ((${#lines[@]} == 1)) && [[ ${lines[0]} == PASS || ${lines[0]} == FAIL ]]; then
      declaration=${lines[0]}
    fi
  fi

  # A leftover observed in ANY scenario is fatal for the whole invocation.
  if [[ $declaration == FAIL ]]; then
    aggregate=FAIL
    continue
  fi

  execution_state=$(product_execution_state "$report_file") || execution_state=UNKNOWN
  case $execution_state in
    NO)
      # The authorization barrier proves the product did not execute. Its
      # cleanup declaration is not applicable to this scenario.
      continue
      ;;
    YES)
      product_executed_anywhere=YES
      if [[ $declaration != PASS ]]; then
        [[ $aggregate == FAIL ]] || aggregate=UNKNOWN
      fi
      ;;
    UNKNOWN)
      # Do not interpret missing or contradictory execution evidence as
      # proof that this scenario has no bearing on product cleanup.
      [[ $aggregate == FAIL ]] || aggregate=UNKNOWN
      ;;
    *)
      [[ $aggregate == FAIL ]] || aggregate=UNKNOWN
      ;;
  esac
done

if [[ $aggregate != FAIL && $product_executed_anywhere == NO ]]; then
  # The product never executed in any scenario: there is nothing observed
  # about its cleanup, and that is UNKNOWN, never PASS.
  aggregate=UNKNOWN
fi

temporary="$result_file.tmp.$$"
if ! (umask 077; printf '%s\n' "$aggregate" >"$temporary") || \
  ! mv -f -- "$temporary" "$result_file"; then
  rm -f -- "$temporary"
  printf 'Could not publish the aggregate product-cleanup result.\n' >&2
  exit 1
fi

printf '%s\n' "$aggregate"
