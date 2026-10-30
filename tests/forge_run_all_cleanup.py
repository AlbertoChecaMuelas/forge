#!/usr/bin/env python3
"""tests/forge_run_all_cleanup.py — the DECLARATION of the cleanup of the
PRODUCT of the battery of the suites (tests/run-all.sh).

The containment entry (tools/verification/forge-contained-run.sh) demands ONE
declaration of the cleanup of the product, observed BEFORE its defensive
cleanup, and it refuses to certify an invocation whose declaration is absent,
malformed or unknown. A battery of dozens of suites does not produce that
declaration by itself: this helper is what produces it, and it does it in the
only way that can be defended:

  * `probe` observes, over the PRIVATE /proc of the containment, whether any
    process that the suites launched is still alive. The criterion is the one
    of the case CLEAN-1 of the V2 bank: a live process of the batch that is
    neither the PID 1 of the namespace nor the observer itself nor one of its
    ancestors is a LEFTOVER of the product. An EMPTY set is a legitimate PASS
    (a suite that launched nothing has nothing to clean up); a non-empty set
    is a FAIL; and an observation that could NOT be performed is an UNKNOWN
    that is reported literally, never as a PASS. A process that was
    ENUMERATED and could not be OBSERVED (its stat could not be read) makes
    the observation INCOMPLETE: it is an UNKNOWN, never an empty set. Only a
    CONFIRMED absence (the entry of the process is NOT there) is a
    disappearance: an ERROR of observation (a permission error, for
    instance) is NOT an absence and it also makes the observation INCOMPLETE.

  * `aggregate` reduces a set of per-scenario declarations to ONE value, with
    the WORST CASE winning: FAIL > UNKNOWN > PASS. A declaration that is
    missing, malformed or unreadable is an UNKNOWN, never a PASS. The
    aggregate NEVER masks a FAIL: that is the property that the sensitivity
    battery of this lot proves with a mutant. The SCOPE of a declaration
    ("does this declaration describe the cleanup of the PRODUCT?") is
    validated JOINTLY with its verdict: a scope that contradicts its verdict
    is contradictory evidence (an UNKNOWN, never a PASS) and a FAILURE is
    never dropped because of its scope. A MALFORMED scope never improves a
    FAILURE either: the failure is preserved and the contradiction is
    diagnosed.

The helper NEVER reads the command line of any process (only its own /proc
entry), it NEVER enumerates the /proc of the host (the /proc it reads is the
private one of the containment, and the caller only invokes it after the
admission check of the containment has accredited that namespace), and it
NEVER signals anything.

Usage:
    forge_run_all_cleanup.py probe
    forge_run_all_cleanup.py aggregate <declarations-file>
    forge_run_all_cleanup.py worst <verdict> [<verdict>...]

`probe` prints, on its standard output, the verdict on the FIRST line and the
PIDs of the leftovers on the following lines. `aggregate` reads a TSV file
whose lines are "<scenario>\\t<VERDICT>" (a third column is allowed and
ignored) and prints the aggregate verdict.
"""

import os
import sys

PASS = "PASS"
FAIL = "FAIL"
UNKNOWN = "UNKNOWN"

# The order of the WORST CASE. A FAIL is always fatal, an UNKNOWN is always
# worse than a PASS, and a PASS is only reached when EVERY declaration is a
# PASS.
SEVERITY = {PASS: 0, UNKNOWN: 1, FAIL: 2}

# A declaration that does not apply (a scenario that was NOT EXECUTED, so it
# launched nothing and it has nothing to clean up) is NOT an observation: it
# is skipped and it does not take part in the aggregate. It is NOT the same
# thing as an UNKNOWN: an UNKNOWN is an observation that could not be made.
NOT_APPLICABLE = "NOT_APPLICABLE"

# The STATE of the /proc ENTRY of a process.
#
#   ABSENT       the entry is NOT there: the absence is CONFIRMED. The
#                process disappeared while it was being read.
#   PRESENT      the entry is there.
#   UNOBSERVABLE the state of the entry could NOT be read (a permission
#                error, a transient failure of the read). It is NOT an
#                absence: the process may well be alive and unreadable.
#
# The distinction is the whole point: an ERROR OF OBSERVATION is not an
# ABSENCE. `os.path.exists()` collapses the two (it answers False for a
# PermissionError as well), and a process that could not be observed would
# then be published as a process that disappeared.
ABSENT = "ABSENT"
PRESENT = "PRESENT"
UNOBSERVABLE = "UNOBSERVABLE"


def stat_fields(pid):
    """The fields of /proc/<pid>/stat that this helper needs.

    Only the state, the parental relation and the starttime are read. The
    command line of the process is NEVER read: the helper must not be able to
    observe anything of the processes it does not own.
    """
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii") as stream:
            raw = stream.read()
    except (OSError, ValueError):
        return None
    try:
        # The comm field may contain spaces and parentheses, so the fields
        # AFTER the last ')' are the ones that count.
        fields = raw[raw.rfind(")") + 2:].split()
        return {
            "state": fields[0],
            "ppid": int(fields[1]),
            "ticks": fields[19],
        }
    except (IndexError, ValueError):
        return None


def ancestors(pid):
    """The chain of ancestors of a process, read from its own /proc entries.

    The scaffolding that launched the batch (the shells of the harness) is
    alive BY CONSTRUCTION while the batch runs: it is not a leftover of the
    product, and it must not be counted as one. The resources that the batch
    itself created are NOT ancestors of the observer, so they are still
    observed.
    """
    seen = set()
    current = int(pid)
    for _ in range(64):
        info = stat_fields(current)
        if info is None:
            break
        parent = info["ppid"]
        if parent <= 1 or parent in seen:
            break
        seen.add(parent)
        current = parent
    return seen


def accredited_namespace():
    """The PID namespace this observation is accredited for, or None.

    The helper NEVER enumerates the /proc of the host. It only observes when
    the caller declares the namespace of the accredited containment AND this
    process really is in it (and the PID 1 of that namespace is visible in
    the same namespace). Without that accreditation the observation is
    refused and it is reported as an UNKNOWN, never as a PASS.
    """
    declared = os.environ.get("FORGE_CONTAINED_RUN_PID_NAMESPACE", "")
    if not declared:
        return None
    try:
        self_namespace = os.readlink("/proc/self/ns/pid")
        init_namespace = os.readlink("/proc/1/ns/pid")
    except OSError:
        return None
    if self_namespace != declared or init_namespace != declared:
        return None
    return declared


def entry_state(pid, proc_root="/proc"):
    """The state of the /proc ENTRY of a process: ABSENT, PRESENT or UNOBSERVABLE.

    It is the discriminator between a process that DISAPPEARED while it was
    being read and a process whose entry could NOT be READ: the first one
    left no entry behind (a CONFIRMED absence), the second one is still
    there and could not be observed (an ERROR OF OBSERVATION, which is NOT
    an absence).

    The absence is confirmed ONLY by a FileNotFoundError. Any OTHER error
    (a permission error, for instance) leaves the state of the entry
    UNKNOWN, and an unknown state is never published as an absence.
    """
    try:
        os.stat(os.path.join(proc_root, str(pid)))
    except FileNotFoundError:
        return ABSENT
    except OSError:
        return UNOBSERVABLE
    return PRESENT


def observe_entries(entries, excluded, stat_reader=None, entry_reader=None):
    """The leftovers and the processes that could not be observed.

    `entries` is the list of the names of the /proc entries that were
    enumerated. A process whose stat could not be read is a leftover of the
    observation only when its entry still EXISTS: an entry that is gone
    belongs to a process that disappeared while it was being read, and that
    is not an incomplete observation. An entry whose state could NOT be
    read (an error of observation) is NOT a disappearance either: it makes
    the observation INCOMPLETE.
    """
    if stat_reader is None:
        stat_reader = stat_fields
    if entry_reader is None:
        entry_reader = entry_state
    leftovers = []
    unobservable = []
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid in excluded:
            continue
        info = stat_reader(pid)
        if info is None:
            # Only a CONFIRMED absence is a disappearance. An error of
            # observation is an UNOBSERVABLE process: the observation is
            # incomplete and it is reported as such.
            if entry_reader(pid) == ABSENT:
                continue
            unobservable.append(pid)
            continue
        if info["state"] == "Z":
            # A zombie is not a live process: it is a corpse waiting to be
            # reaped, and it consumes nothing.
            continue
        leftovers.append(pid)
    return leftovers, unobservable


def observe_batch_cleanup():
    """Observe the cleanup of the PRODUCT over the private /proc.

    Returns (verdict, leftovers). The verdict is PASS when the observation
    was performed and it found NO leftover, FAIL when it found some, and
    UNKNOWN when the observation could NOT be performed (which is reported
    literally and is NEVER a PASS).
    """
    own_pid = os.getpid()

    # The /proc of the containment is a procfs of the PRIVATE namespace: the
    # PID 1 of the namespace is visible and it is the init of the batch. If it
    # is not visible, or if this process is not in the accredited namespace,
    # this is NOT the private /proc of a containment and the observation is
    # refused (an UNKNOWN), never a PASS.
    if accredited_namespace() is None:
        return UNKNOWN, []
    if stat_fields(1) is None:
        return UNKNOWN, []

    excluded = set([1, own_pid])
    excluded.update(ancestors(own_pid))

    try:
        entries = os.listdir("/proc")
    except OSError:
        return UNKNOWN, []

    leftovers, unobservable = observe_entries(entries, excluded)
    if unobservable:
        # The observation could NOT be completed: it is an UNKNOWN, never a
        # PASS.
        return UNKNOWN, []
    leftovers.sort()
    return (PASS if not leftovers else FAIL), leftovers


def worst_case(declarations):
    """The WORST CASE of a set of declarations.

    `declarations` is an iterable of verdict strings. A verdict that is not
    one of PASS/FAIL/UNKNOWN is an UNKNOWN (a malformed declaration is never
    a PASS). A NOT_APPLICABLE declaration is skipped: it is not an
    observation. An EMPTY set is an UNKNOWN: nothing was observed, and
    nothing observed is never a PASS. A set whose declarations are ALL not
    applicable is a NOT_APPLICABLE: there was nothing to observe.
    """
    result = PASS
    seen = False
    applicable = False
    for value in declarations:
        seen = True
        if value == NOT_APPLICABLE:
            continue
        applicable = True
        if value not in SEVERITY:
            value = UNKNOWN
        if SEVERITY[value] > SEVERITY[result]:
            result = value
    if not seen:
        return UNKNOWN
    if not applicable:
        return NOT_APPLICABLE
    return result


def read_declarations(path):
    """The verdicts of a TSV file of declarations.

    Every line is "<scenario>\\t<VERDICT>[\\t<SCOPE>]". The SCOPE says
    whether the declaration describes the cleanup of the PRODUCT: "PRODUCT"
    (it does) or "NOT_APPLICABLE" (it does not, because the scenario never
    exercised the product). The scope is OPTIONAL: a line without a scope
    column DERIVES it from its verdict, so the two-column form keeps its
    meaning (a NOT_APPLICABLE verdict means "there was nothing to observe"
    and any other verdict means "the product was exercised").

    The scope and the verdict are validated JOINTLY, because a scope that
    CONTRADICTS its verdict is evidence that cannot be trusted:

      * (PRODUCT, PASS|FAIL|UNKNOWN): the verdict IS the declaration;
      * (PRODUCT, NOT_APPLICABLE): CONTRADICTION -> UNKNOWN. The product ran
        and the declaration says there was nothing to observe: the evidence
        disagrees with itself and it is never a PASS;
      * (NOT_APPLICABLE, NOT_APPLICABLE): skipped, there was nothing to
        observe;
      * (NOT_APPLICABLE, PASS|UNKNOWN): skipped, the declaration does not
        describe the cleanup of the product;
      * (NOT_APPLICABLE, FAIL): the FAILURE is PRESERVED. A declaration that
        reports a failure can NEVER be dropped because its scope claims that
        it does not describe the product: that is exactly the way a real
        failure of the product could be hidden;
      * a scope that is neither one nor the other: the evidence CONTRADICTS
        itself, and it is reported as such. The verdict is PRESERVED when it
        is a FAILURE: a malformed scope can NEVER improve the aggregate of a
        failure (the aggregate only WORSENS), and the diagnostic of the
        contradiction is published;
      * a verdict that is not a verdict: UNKNOWN.

    The aggregate can therefore only WORSEN: no scope and no verdict can turn
    a FAIL into a PASS, a contradiction can never be laundered into a PASS
    and a MALFORMED scope can never soften a FAIL into an UNKNOWN.

    A file that cannot be read, or a line that does not carry a verdict, is an
    UNKNOWN: the aggregate must never reach a PASS over evidence it could not
    read.
    """
    verdicts = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as stream:
            lines = stream.read().splitlines()
    except OSError:
        return [UNKNOWN]
    for line in lines:
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) < 2:
            verdicts.append(UNKNOWN)
            continue
        verdict = fields[1].strip()
        if len(fields) > 2:
            scope = fields[2].strip()
        else:
            # The scope is derived from the verdict: the two-column form
            # says "the product was exercised" unless the verdict says
            # there was nothing to observe.
            scope = NOT_APPLICABLE if verdict == NOT_APPLICABLE else "PRODUCT"
        if scope not in ("PRODUCT", NOT_APPLICABLE):
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
                    "veredicto es FAIL; el fallo se preserva\n" % scope)
                verdicts.append(FAIL)
                continue
            sys.stderr.write(
                "declaracion contradictoria: el alcance '%s' no es valido\n" % scope)
            verdicts.append(UNKNOWN)
            continue
        if scope == "PRODUCT":
            if verdict == NOT_APPLICABLE:
                # The product ran and the declaration says there was nothing
                # to observe: the evidence contradicts itself.
                verdicts.append(UNKNOWN)
                continue
            if verdict not in SEVERITY:
                verdict = UNKNOWN
            verdicts.append(verdict)
            continue
        # scope == NOT_APPLICABLE
        if verdict == NOT_APPLICABLE:
            verdicts.append(NOT_APPLICABLE)
            continue
        if verdict == FAIL:
            # A FAILURE is never dropped: the scope cannot hide it.
            verdicts.append(FAIL)
            continue
        if verdict not in SEVERITY:
            verdicts.append(UNKNOWN)
            continue
        # (NOT_APPLICABLE, PASS|UNKNOWN): the declaration does not describe
        # the cleanup of the product and it does not report a failure.
        verdicts.append(NOT_APPLICABLE)
    return verdicts


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("uso: %s probe | aggregate <declarations-file>\n" % argv[0])
        return 64
    command = argv[1]

    if command == "probe":
        verdict, leftovers = observe_batch_cleanup()
        sys.stdout.write("%s\n" % verdict)
        for pid in leftovers:
            sys.stdout.write("%d\n" % pid)
        sys.stdout.flush()
        return 0

    if command == "aggregate":
        if len(argv) != 3:
            sys.stderr.write("uso: %s aggregate <declarations-file>\n" % argv[0])
            return 64
        verdicts = read_declarations(argv[2])
        sys.stdout.write("%s\n" % worst_case(verdicts))
        sys.stdout.flush()
        return 0

    if command == "worst":
        if len(argv) < 3:
            sys.stderr.write("uso: %s worst <verdict> [<verdict>...]\n" % argv[0])
            return 64
        sys.stdout.write("%s\n" % worst_case(argv[2:]))
        sys.stdout.flush()
        return 0

    sys.stderr.write("comando desconocido: %s\n" % command)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
