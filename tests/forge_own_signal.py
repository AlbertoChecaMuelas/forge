#!/usr/bin/env python3
"""tests/forge_own_signal.py — a signal bound to an IDENTITY and to nothing else.

The program receives the identity of a process (its PID and its starttime)
and delivers a signal to THAT process and to nobody else.

The identity ALONE is NOT enough to signal a process: knowing a PID and its
starttime is not a proof of ownership, and a recycled number with a matching
starttime is not even an identity. The signal is therefore bound to THREE
conditions, and ALL of them must hold BEFORE anything is signalled:

  1. THE PROTECTED PID IS REFUSED. The PID that the plan protects is never
     signalled, not even when its identity matches: the refusal happens
     BEFORE anything of that process is read. The exclusion of that PID is
     IMMUTABLE: the environment variable can only ADD exclusions to it, it
     can never REPLACE it, and it is applied to the DESTINATION and to the
     OWNER: a protected PID is never read, not even as the owner of the
     containment.

  2. THE NAMESPACE IS ACCREDITED. The namespace of the containment is the
     one that the entry published in the environment
     (FORGE_CONTAINED_RUN_PID_NAMESPACE). The signaler MUST be inside it
     and the target MUST be inside it too. Without that variable there is no
     accredited containment and NOTHING is signalled.

  3. THE PROVENANCE IS VERIFIABLE. The caller declares the identity of the
     OWNER (the process that owns the containment and the registry of
     identities) and the target MUST descend from that owner. The starttime
     of the owner is verified and the chain of ancestors of the target is
     read until the owner is found.

The verification of the IDENTITY (the starttime) is an ADDITIONAL condition,
never a proof of ownership: it is checked after the three conditions above,
and it can only REFUSE.

TWO mechanisms are possible and the one that was really used is always
reported, so the evidence never claims a guarantee it did not have:

  * pidfd — the signal is delivered THROUGH a pidfd. A pidfd refers to the
    PROCESS and not to the number, so a PID that is recycled from that
    moment on can never become the target. The starttime is verified again
    after the pidfd is opened, which closes the window between the
    verification and the open. This is the STRONG mechanism.

  * starttime-recheck-only — the pidfd is not available (the kernel does not
    offer it) or it could not be opened for a reason that is not "the
    process is gone". The signal then goes to the NUMBER and the ONLY
    guarantee available is a re-verification of the starttime made
    IMMEDIATELY BEFORE the signal. That re-verification closes the window
    between the first check and the signal, but it does NOT close the window
    between the re-verification and the kill itself: the number can still be
    recycled inside that window. This mechanism is WEAKER than the pidfd one
    and it never claims to be the pidfd one.

The re-verification is performed in BOTH cases of the fallback, including
the case in which the pidfd could not be opened: continuing to the signal
without re-checking the identity would be a window in which the identity
could have changed.

Exit status:
  0  the signal was delivered to that identity.
  2  the process is gone (there is no such PID).
  3  the identity does NOT match: the PID was recycled. NOTHING is signalled.
  4  the signal could not be delivered (bad arguments or an error).
  5  the signal was REFUSED: the protected PID, an unaccredited
     containment, a target outside the namespace or an identity that is not
     own. NOTHING is signalled.

The mechanism (or the reason of the refusal) is printed on the standard
output; the diagnostics go to the standard error.
"""

import errno
import os
import signal
import sys

EXIT_OK = 0
EXIT_GONE = 2
EXIT_MISMATCH = 3
EXIT_ERROR = 4
EXIT_REFUSED = 5

MECHANISM_PIDFD = "pidfd"
MECHANISM_RECHECK_ONLY = "starttime-recheck-only"

# The PID that the plan protects. It is NEVER signalled and it is NEVER
# read: the refusal happens before anything of that process is touched.
#
# The exclusion of THIS pid is IMMUTABLE. The variable of the environment
# (FORGE_TEST_PROTECTED_PID) can only ADD exclusions to it: it can never
# SUBSTITUTE it. A substitution would turn the protection into a fiction:
# with another value in the variable, a target of 530393 would be signalled
# and the owner of the containment could be the protected process itself.
DEFAULT_PROTECTED_PID = "530393"

# The variable that ADDS exclusions to the immutable one.
PROTECTED_PID_VARIABLE = "FORGE_TEST_PROTECTED_PID"

# The namespace that the entry published when it accredited the boundary.
NAMESPACE_VARIABLE = "FORGE_CONTAINED_RUN_PID_NAMESPACE"


def ticks_of(target):
    """The starttime (field 22) of /proc/<target>/stat, or None.

    The comm field (field 2) may contain spaces and parentheses, so the
    fields AFTER the last ')' are used: the starttime is the twentieth of
    them.
    """
    try:
        with open("/proc/%d/stat" % target, "r", encoding="ascii", errors="replace") as handle:
            data = handle.read()
    except OSError:
        return None
    tail = data.rsplit(")", 1)[-1].split()
    if len(tail) < 20:
        return None
    return tail[19]


def state_of(target):
    """The state field of /proc/<target>/stat, or None."""
    try:
        with open("/proc/%d/stat" % target, "r", encoding="ascii", errors="replace") as handle:
            data = handle.read()
    except OSError:
        return None
    tail = data.rsplit(")", 1)[-1].split()
    if not tail:
        return None
    return tail[0]


def parent_of(target):
    """The parental relation of /proc/<target>/stat, or None."""
    try:
        with open("/proc/%d/stat" % target, "r", encoding="ascii", errors="replace") as handle:
            data = handle.read()
    except OSError:
        return None
    tail = data.rsplit(")", 1)[-1].split()
    if len(tail) < 2:
        return None
    try:
        return int(tail[1])
    except ValueError:
        return None


def namespace_of(target):
    """The PID namespace of /proc/<target>/ns/pid, or None."""
    try:
        return os.readlink("/proc/%d/ns/pid" % target)
    except OSError:
        return None


def ancestors_of(target):
    """The chain of ancestors of <target>, or None when it cannot be read.

    The chain starts with the direct parent. It is read from the OWN /proc
    entries of the target: it is never a discovery of the processes of the
    host, and it only walks upwards from a process that was already named.

    A PROTECTED ancestor is never read: the walk stops there and the
    provenance is reported as NOT verifiable. The refusal of the protected
    PID is not limited to the DESTINATION of the signal: an access to it is
    an access all the same.
    """
    chain = []
    current = target
    excluded = protected_pids()
    for _ in range(64):
        if str(current) in excluded:
            # The ancestor is protected: it is NOT read and the provenance
            # is NOT verifiable.
            return None
        parent = parent_of(current)
        if parent is None:
            # The chain could NOT be read: the provenance is not verifiable.
            return None
        if parent <= 1:
            return chain
        chain.append(parent)
        current = parent
    return chain


def pidfd_available():
    """True when the kernel offers both halves of the pidfd mechanism."""
    return hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")


def protected_pids():
    """Every PID that is excluded, ALWAYS including the protected one.

    The exclusion of DEFAULT_PROTECTED_PID is IMMUTABLE: the variable of
    the environment can only ADD exclusions to it, never SUBSTITUTE it.
    The value of the variable is a list of PIDs separated by spaces or
    commas; every one of them that is numeric is an additional exclusion.
    """
    pids = {DEFAULT_PROTECTED_PID}
    raw = os.environ.get(PROTECTED_PID_VARIABLE, "") or ""
    for part in raw.replace(",", " ").replace(";", " ").split():
        if part.isdigit():
            pids.add(part)
    return pids


def refuse(reason):
    """Refuse the signal: NOTHING is signalled."""
    sys.stdout.write("refused-%s\n" % reason)
    sys.stdout.flush()
    return EXIT_REFUSED


def main(argv):
    if len(argv) != 6:
        sys.stderr.write(
            "uso: forge_own_signal.py <pid> <starttime> <senal> "
            "<owner-pid> <owner-starttime>\n"
        )
        return EXIT_ERROR

    try:
        pid = int(argv[1])
    except ValueError:
        sys.stderr.write("pid no numerico: %s\n" % argv[1])
        return EXIT_ERROR
    expected = argv[2]
    name = argv[3].upper()
    try:
        owner_pid = int(argv[4])
    except ValueError:
        sys.stderr.write("pid del propietario no numerico: %s\n" % argv[4])
        return EXIT_ERROR
    owner_expected = argv[5]

    signum = getattr(signal, "SIG" + name, None)
    if signum is None:
        sys.stderr.write("senal desconocida: %s\n" % name)
        return EXIT_ERROR

    # 1. The PROTECTED PID is refused BEFORE anything is read: the refusal
    #    does not even look at the process. The exclusion is IMMUTABLE for
    #    the PID of the plan and it is applied to the DESTINATION and to the
    #    OWNER: a protected PID is never read, not even as the owner of the
    #    containment, and the variable of the environment can only ADD
    #    exclusions to it.
    excluded = protected_pids()
    if str(pid) in excluded:
        sys.stderr.write("el PID %s esta protegido: no se senala\n" % pid)
        return refuse("protected-pid")
    if str(owner_pid) in excluded:
        sys.stderr.write(
            "el PID %s esta protegido: no se senala ni se lee\n" % owner_pid
        )
        return refuse("protected-owner")

    # 2. The NAMESPACE of the containment must be ACCREDITED, and both the
    #    signaler and the target must be inside it.
    namespace = os.environ.get(NAMESPACE_VARIABLE, "")
    if not namespace:
        sys.stderr.write(
            "no hay contencion acreditada (%s ausente): no se senala\n" % NAMESPACE_VARIABLE
        )
        return refuse("not-accredited")
    own_namespace = namespace_of(os.getpid())
    if own_namespace != namespace:
        sys.stderr.write(
            "el namespace del senalizador (%s) no es el namespace acreditado (%s): no se senala\n"
            % (own_namespace, namespace)
        )
        return refuse("not-contained")
    target_namespace = namespace_of(pid)
    if target_namespace is None:
        sys.stderr.write("no se pudo leer el namespace del objetivo: no se senala\n")
        return refuse("unverifiable")
    if target_namespace != namespace:
        sys.stderr.write(
            "el objetivo (%s) esta en otro namespace (%s): no se senala\n" % (pid, target_namespace)
        )
        return refuse("not-contained")

    # 3. The PROVENANCE of the identity must be verifiable: the owner must
    #    be alive with the declared identity and the target must descend
    #    from it.
    owner_ticks = ticks_of(owner_pid)
    if owner_ticks is None:
        sys.stderr.write("el propietario (%s) no existe: no se senala\n" % owner_pid)
        return refuse("not-own")
    if owner_ticks != owner_expected:
        sys.stderr.write(
            "la identidad del propietario (%s) no es la declarada: no se senala\n" % owner_pid
        )
        return refuse("not-own")
    chain = ancestors_of(pid)
    if chain is None:
        sys.stderr.write("no se pudo verificar la procedencia del objetivo: no se senala\n")
        return refuse("unverifiable")
    if owner_pid not in chain:
        sys.stderr.write(
            "el objetivo (%s) NO desciende del propietario (%s): no se senala\n" % (pid, owner_pid)
        )
        return refuse("not-own")

    # 4. The IDENTITY: an ADDITIONAL condition, never a proof of ownership.
    current = ticks_of(pid)
    if current is None:
        sys.stdout.write("gone\n")
        return EXIT_GONE
    if current != expected:
        sys.stdout.write("identity-mismatch\n")
        return EXIT_MISMATCH

    if pidfd_available():
        try:
            handle = os.pidfd_open(pid, 0)
        except OSError as exc:
            if exc.errno == errno.ESRCH:
                # The process is gone: there is nothing to signal.
                sys.stdout.write("gone\n")
                return EXIT_GONE
            # The pidfd could NOT be opened for a reason that is NOT "the
            # process is gone". The guarantee of the pidfd is therefore NOT
            # available and the signal falls back to the number. The
            # identity is re-verified below, immediately before the signal.
            handle = None
        else:
            again = ticks_of(pid)
            if again is None:
                os.close(handle)
                sys.stdout.write("gone\n")
                return EXIT_GONE
            if again != expected:
                os.close(handle)
                sys.stdout.write("identity-mismatch\n")
                return EXIT_MISMATCH
            try:
                signal.pidfd_send_signal(handle, signum)
            except ProcessLookupError:
                os.close(handle)
                sys.stdout.write("gone\n")
                return EXIT_GONE
            except OSError:
                os.close(handle)
                sys.stdout.write("error\n")
                return EXIT_ERROR
            os.close(handle)
            sys.stdout.write(MECHANISM_PIDFD + "\n")
            return EXIT_OK

    # FALLBACK: the signal is delivered to the NUMBER, so the only guarantee
    # available is a re-verification of the identity made IMMEDIATELY BEFORE
    # the signal. That re-verification closes the window between the first
    # check and the signal, but NOT the window between the re-verification
    # and the kill itself: the number can still be recycled inside that
    # window. The guarantee of the pidfd (the signal reaches the PROCESS and
    # not the number) is NOT available here and this mechanism never claims
    # it.
    again = ticks_of(pid)
    if again is None:
        sys.stdout.write("gone\n")
        return EXIT_GONE
    if again != expected:
        # The identity changed: the number belongs to somebody else now and
        # NOTHING is signalled.
        sys.stdout.write("identity-mismatch\n")
        return EXIT_MISMATCH
    try:
        os.kill(pid, signum)
    except ProcessLookupError:
        sys.stdout.write("gone\n")
        return EXIT_GONE
    except OSError:
        sys.stdout.write("error\n")
        return EXIT_ERROR
    sys.stdout.write(MECHANISM_RECHECK_ONLY + "\n")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
