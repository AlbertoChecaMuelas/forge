#!/usr/bin/env python3
"""tests/forge_v2_safety_harness.py — harness of the isolated V2 safety acceptance.

Two roles live in this file:

  supervisor
      Runs OUTSIDE any namespace. It does NOT create a namespace of its own
      and it does NOT sweep the process table of the host: it launches the
      suite through the SINGLE authorized containment entry
      (tools/verification/forge-contained-run.sh), which establishes a
      rootless user namespace with a private PID namespace and a private
      ``/proc``, accredits the boundary BY INVOCATION, closes the contained
      environment with a bounded budget and records everything in a receipt.
      The guarantee "no own survivor" is the CLOSURE of that namespace, not
      a sweep: the kernel destroys it when its PID 1 exits.

  suite
      Runs INSIDE the private PID namespace. It re-accredits the containment
      from the inside BEFORE calling any sensitive production function, then
      runs the acceptance cases over exclusively synthetic resources.

The harness never executes the external entrypoints and never runs the
external ``dbtool.py``: the only production code it reaches is imported by
path (``open-code/lib/plugin-sync.py`` and the external
``lib/cutover_safety.py``).

Usage:
    python3 tests/forge_v2_safety_harness.py --role supervisor ...
    python3 tests/forge_v2_safety_harness.py --role suite ...
"""

import argparse
import contextlib
import errno
import hashlib
import importlib.util
import inspect
import io
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback

BATCH_ROOT = os.environ.get("FORGE_V2_BATCH_ROOT", "/tmp/opencode/forge-v2-safety")
"""Base of the batch artefacts (synthetic root, default report path).

The default is a DEDICATED root of this test bank. It is deliberately NOT the
evidence directory of any batch: a run must never overwrite the evidence of a
previous batch (that happened when the default pointed at
/tmp/opencode/forge-v2-followups/, whose safety-results.json and
safety-results.md belong to the batch that produced them). A caller that owns
a batch root exports FORGE_V2_BATCH_ROOT; only then the synthetic root and the
default report path move under it.
"""
# The canonical source of the real component is versioned IN this repository
# (tools/cutover/forge-v2/), so the default resolution follows the checkout
# and works in a clean clone and in CI. The external copy of the laboratory
# (/home/espinilleitor/forge-v2-cutover-20261024) is a frozen historical
# backup, NOT an active source: it is never consulted by default. A caller
# that wants another tree states it explicitly (FORGE_V2_EXTERNAL_ROOT, which
# the supervisor forwards as --external-root); that override is NOT needed in
# CI.
CHECKOUT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EXTERNAL_ROOT = os.path.join(CHECKOUT_ROOT, "tools", "cutover", "forge-v2")
PLUGIN_SYNC_REL = "open-code/lib/plugin-sync.py"
CUTOVER_SAFETY_REL = "lib/cutover_safety.py"
CANONICAL_COMPONENT_REL = os.path.join("tools", "cutover", "forge-v2", CUTOVER_SAFETY_REL)
"""The canonical, versioned copy of the component INSIDE this repository.

It is the single copy the checkout may contain: any other copy of the
implementation inside the checkout would be a duplicated implementation. It is
independent of the tree the bench is pointed at (FORGE_V2_EXTERNAL_ROOT), which
only decides WHICH copy is loaded and exercised.
"""

CANONICAL_COMPONENT_FILES = (
    os.path.join("tools", "cutover", "forge-v2", CUTOVER_SAFETY_REL),
    os.path.join("tools", "cutover", "forge-v2", "lib", "dbtool.py"),
    os.path.join("tools", "cutover", "forge-v2", "cutover.sh"),
    os.path.join("tools", "cutover", "forge-v2", "ROLLBACK.sh"),
    PLUGIN_SYNC_REL,
)
"""The COMPLETE set of the implementation files whose uniqueness the bank
certifies, relative to the root of the checkout.

The set is NOT the set of the files that the bench loads: it is the set of
the EXECUTABLE SURFACE of the two versioned components that this repository
versions.

  * ``lib/cutover_safety.py``  the implementation that the bench loads and
    exercises.
  * ``lib/dbtool.py``          the database tool of the SAME versioned
    component. It is a prohibited entrypoint (the bench never executes it
    and never imports it), but a second copy of it inside the checkout would
    be a second database tool with access to the real database.
  * ``cutover.sh``             the cutover entrypoint: a second copy would be
    a second way to perform the cutover.
  * ``ROLLBACK.sh``            the rollback entrypoint: a second copy would be
    a second way to roll the cutover back.
  * ``open-code/lib/plugin-sync.py``  the implementation that the bench loads
    and exercises on the other side.

The DOCUMENTATION of the component (README.md, CUTOVER-NOTES.md,
FOLLOWUPS.md, REMEDIATION-REPORT.md) is deliberately OUTSIDE the set: a
document is never loaded nor executed, so a second copy of it does not
create a second implementation and does not weaken any guarantee of this
bank. Adding it would state a property that nothing behind it supports.
"""

CHECKOUT_SCAN_EXCLUDED_DIRS = (".git", "node_modules", "__pycache__")
"""The trees that are NOT part of the checkout for the purposes of the
uniqueness: the objects of the git, the installed dependencies and the
bytecode caches. They are generated, they are not versioned and a copy of
the implementation inside them is not a second implementation of the
component."""

KIND_DYNAMIC = "dinamica"
KIND_SIMULATION = "simulacion"
KIND_INSPECTION = "inspeccion"

AUXILIARY_CONTROL_IDS = ("INSP-6", "INSP-7", "INSP-8")
"""The CONTROLS OF THE CONTROLS, counted APART from the bank.

They exercise the criteria of the provenance (INSP-2) and of the uniqueness
(INSP-3) against cases that MUST fail: an external copy has to be rejected,
the legitimate copy has to be accepted and a planted duplicate has to be
detected. A criterion that cannot be red certifies nothing, so these
controls are part of the acceptance.

They are NOT cases of the bank: the census of the bank keeps its own count
(52) and these three are counted apart, with their own verdict. Their
verdict is nevertheless HARD: a red auxiliary control fails the run.
"""

EXTERNAL_ENTRYPOINT_TOKENS = ("cutover.sh", "ROLLBACK.sh", "dbtool")

CONTAINMENT_ENTRY_REL = os.path.join("tools", "verification", "forge-contained-run.sh")
CONTAINMENT_RECEIPT_DIR = os.environ.get("FORGE_CONTAINMENT_RECEIPT_DIR", "").strip()
"""The directory of receipts that the inner containment invocation uses.

It is NOT a path of a machine: the consumer may DECLARE it (and then the
declaration is the one that is used) and, when it does not, the harness
derives a directory of ITS OWN invocation (the "receipts" directory of the
run root). The entry creates the directory when it does not exist, so the
evidence of this bank always lands in a place that belongs to the run that
produced it and never in a directory of a machine that may not exist."""

CONTAINMENT_GUARD_REL = os.path.join("tools", "verification", "require-v2-containment.sh")
"""The helper of admission of the containment.

It is the SAME helper that the entries of tools/ already use
(tools/ci/v2-safety.sh, tools/verification/prepare-sandbox.py and
tools/verification/forge-v2-followups.sh): ONE criterion of admission for the
whole chain, not one per layer. The roles of this harness call it as a
process, so the runner, the supervisor and the suite refuse to start when the
invocation was not launched by the standard containment entry.
"""

ADMISSION_DENIED_RC = 78
"""RC of a refused admission.

It is the RC of tools/verification/require-v2-containment.sh: the same code
means the same thing in every layer of the chain (the invocation was NOT
launched by the standard containment entry, so nothing was executed).
"""

# Authorization barrier: the suite refuses to call any sensitive function
# until the supervisor has accredited the containment AND has an operational
# watchdog, and says so on this channel.
AUTH_TOKEN = "AUTH"

# Fault-injection switches, for the exclusive use of this test harness. They
# never touch production code and are inert unless explicitly exported.
FAULT_NO_PIDFD = "FORGE_V2_TEST_NO_PIDFD"
FAULT_HANG_SUITE = "FORGE_V2_TEST_HANG_SUITE"

# The RC contracted for the INNER scenario of this invocation. It is declared
# by the runner of the scenarios (the component that knows the contract of
# each scenario) and it travels to the containment entry, which records it in
# its receipt: the verdict of the entry and the verdict of this supervisor
# can therefore never disagree about what the scenario was expected to
# return. The literal NONE declares that the scenario is expected NOT to
# produce an RC, because the bounded close has to ELIMINATE it.
EXPECTED_SCENARIO_RC_ENV = "FORGE_V2_EXPECTED_SCENARIO_RC"
CONTAINED_EXPECTED_SCENARIO_RC_ENV = "FORGE_CONTAINED_RUN_EXPECTED_SCENARIO_RC"

# The domain of the SIGNALS of this platform (Linux): the real signals are
# 1..64 (SIGRTMAX is 64) and the shell publishes a termination by the signal
# N as the exit status 128+N. The domain is declared here, and NOT derived
# from the value being normalised, so that an invalid state can never be
# reinterpreted as a valid signal.
MAX_SIGNAL = 64

# The ROOT of the procfs that the OBSERVATIONS of this harness read.
#
# It is "/proc" in every real invocation: this harness only runs inside the
# accredited frontier, whose /proc is the PRIVATE one. It is a CONSTANT and
# not an argument, so that no observation can ever be pointed at the procfs
# of the host.
#
# The seam exists for ONE reason: an observation that CANNOT be performed has
# to be REPRODUCIBLE. The difference between "the process does not exist"
# (a CONFIRMED absence) and "the state of the process could not be read" (an
# IMPOSSIBLE observation) is invisible in a healthy machine, and a property
# that cannot be falsified is not a property. The observations are therefore
# exercised over a SYNTHETIC tree (tests/forge_v2_contract_probe.py).
PROC_ROOT = "/proc"


def proc_path(*parts):
    """The path of an entry of the procfs that the observations read."""
    return os.path.join(PROC_ROOT, *parts)


# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# provenance and uniqueness of the versioned component
#
# These two functions are the CRITERIA of the inspection of the bank and
# they are deliberately PURE: they take the paths they check and they return
# a verdict. They do not read the process table, they do not spawn anything
# and they do not touch any resource outside the paths they are given, so
# they can be exercised (and MUTATED) over synthetic trees.
# ---------------------------------------------------------------------------
def verify_module_provenance(repo_root, loaded_path, canonical_rel_path):
    """HARD provenance of a module against the versioned canonical file.

    Returns ``(ok, detail)``. The verdict is a FAILURE when the module that
    the bench loaded is NOT the file that the repository versions: an
    external tree, a copy in a temporary directory or a link that leaves the
    checkout are all REJECTED, and the detail says which one.

    THE REFERENCE IS AN INDEPENDENT FACT. ``canonical_rel_path`` is the path
    of the versioned file RELATIVE to the root of the checkout, and it has to
    be one of the declared canonical files (CANONICAL_COMPONENT_FILES). The
    reference is NEVER derived from the module that was loaded: a criterion
    that compared the loaded module with the path it was loaded FROM would be
    satisfied by itself and would certify nothing. That was the defect of
    the control INSP-2, and the declaration of the reference is what makes
    the tautology impossible here.

    The verdict is the conjunction of FIVE properties, and every one of them
    is about the identity of the loaded module with the versioned file:

      * the REFERENCE IS DECLARED: the reference is one of the canonical
        files of the checkout, so it cannot be an arbitrary path.
      * the REFERENCE IS A REGULAR FILE: it is not a symbolic link, so it
        cannot point at an external tree.
      * the LOADED MODULE IS A REGULAR FILE.
      * the IDENTITY OF THE PATH: the resolved path of the loaded module is
        the resolved path of the reference. A copy, even a byte exact one,
        has another path. Together with the previous property, this says
        that the loaded module IS the versioned file and not a look-alike.
      * the IDENTITY OF THE CONTENT: the sha256 of the loaded module is the
        sha256 of the reference, which protects against a replacement
        between the load and the check.
    """
    checks = []

    def check(name, ok, value):
        checks.append((name, bool(ok), value))
        return bool(ok)

    repo_abs = os.path.abspath(repo_root)
    loaded_abs = os.path.abspath(loaded_path) if loaded_path else ""
    loaded_real = os.path.realpath(loaded_abs) if loaded_abs else ""
    canonical_abs = os.path.join(repo_abs, canonical_rel_path)
    canonical_real = os.path.realpath(canonical_abs)

    reference_declared = canonical_rel_path in CANONICAL_COMPONENT_FILES
    check(
        "referencia_declarada",
        reference_declared,
        canonical_rel_path,
    )

    canonical_is_regular = os.path.isfile(canonical_abs) and not os.path.islink(canonical_abs)
    check(
        "canonica_es_fichero_regular_del_checkout",
        canonical_is_regular,
        canonical_abs,
    )

    loaded_is_regular = bool(loaded_abs) and os.path.isfile(loaded_abs)
    check("modulo_cargado_es_fichero_regular", loaded_is_regular, loaded_abs)

    path_identity = bool(loaded_real) and loaded_real == canonical_real
    check(
        "identidad_de_ruta",
        path_identity,
        "cargado=%s canonica=%s" % (loaded_real, canonical_real),
    )

    content_identity = False
    if loaded_is_regular and canonical_is_regular:
        try:
            content_identity = sha256_file(loaded_abs) == sha256_file(canonical_abs)
        except OSError:
            content_identity = False
    check("identidad_de_contenido", content_identity, "sha256 identico")

    ok = all(item[1] for item in checks)
    detail = "; ".join(
        "%s=%s (%s)" % (name, "OK" if good else "FALLO", value) for name, good, value in checks
    )
    return ok, detail


def find_component_duplicates(repo_root, canonical_rel_paths):
    """The copies of the versioned component that exist inside the checkout.

    Returns a list with one entry per canonical file::

        {"canonical": <absolute path>,
         "name_copies": [<paths>],
         "content_copies": [<paths>]}

    TWO criteria, because one of them is not enough:

      * the NAME: a second file of the checkout with the same name is a
        second copy of the implementation, and it is the one that a loader
        would pick by name.
      * the CONTENT: a copy with ANOTHER name is still a copy of the
        implementation. It is found by the size (an exact copy has the same
        size) followed by the digest, so the scan does not read the whole
        tree.

    The canonical file is never a copy of itself. A symbolic link that
    points at the canonical file IS a copy: it is a second path to the
    implementation, and the criterion of the uniqueness is about the FILES
    of the checkout, not about the inodes they resolve to.
    """
    root = os.path.abspath(repo_root)
    all_files = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [name for name in dirs if name not in CHECKOUT_SCAN_EXCLUDED_DIRS]
        for name in names:
            candidate = os.path.join(base, name)
            if os.path.isfile(candidate):
                all_files.append(candidate)

    results = []
    for rel in canonical_rel_paths:
        canonical_abs = os.path.join(root, rel)
        name_copies = []
        content_copies = []
        size = None
        digest = None
        if os.path.isfile(canonical_abs):
            try:
                size = os.stat(canonical_abs).st_size
                digest = sha256_file(canonical_abs)
            except OSError:
                size = None
                digest = None
        base_name = os.path.basename(canonical_abs)
        canonical_norm = os.path.normpath(canonical_abs)
        for candidate in all_files:
            if os.path.normpath(candidate) == canonical_norm:
                continue
            if os.path.basename(candidate) == base_name:
                name_copies.append(candidate)
            if size is None or digest is None:
                continue
            try:
                if os.stat(candidate).st_size != size:
                    continue
            except OSError:
                continue
            try:
                if sha256_file(candidate) == digest:
                    content_copies.append(candidate)
            except OSError:
                continue
        results.append(
            {
                "canonical": canonical_abs,
                "name_copies": sorted(name_copies),
                "content_copies": sorted(content_copies),
            }
        )
    return results


def fingerprint(path, hash_content=True):
    """Content fingerprint of a file that must not change (hash/size/mtime).

    ``hash_content`` is disabled for the real OpenCode database: its bytes are
    never read, only its metadata is stat'ed.
    """
    try:
        meta = os.stat(path)
    except OSError as exc:
        return {"exists": False, "error": str(exc)}
    result = {
        "exists": True,
        "size": meta.st_size,
        "mtime_ns": meta.st_mtime_ns,
        "ino": meta.st_ino,
        "dev": meta.st_dev,
    }
    if hash_content:
        result["sha256"] = sha256_file(path)
    else:
        result["sha256"] = "no-leido (solo metadatos)"
    return result


def read_proc_children(pid):
    try:
        with open(proc_path("%d" % pid, "task", "%d" % pid, "children"), "r", encoding="ascii") as stream:
            return [int(item) for item in stream.read().split()]
    except OSError:
        return []


def cmdline_of(pid):
    try:
        with open(proc_path("%s" % pid, "cmdline"), "rb") as stream:
            return stream.read().decode("utf-8", "replace")
    except OSError:
        return ""


def process_present(pid):
    """True while the /proc entry of the process still exists (zombie included)."""
    return os.path.isdir(proc_path("%d" % pid))


def process_ancestors(pid):
    """The chain of ancestors of a process, read from its own /proc entries.

    The scaffolding of the scenario (the shells that launched the batch) is
    alive BY CONSTRUCTION while the batch runs: it is not a leftover of the
    product, and it must not be counted as one. The resources that the batch
    itself created are NOT ancestors of the observer, so they are still
    observed: a launcher that survived its own closure is detected.
    """
    ancestors = set()
    current = int(pid)
    for _ in range(64):
        try:
            with open(proc_path("%d" % current, "stat"), "r", encoding="ascii") as stream:
                raw = stream.read()
            fields = raw[raw.rfind(")") + 2 :].split()
            parent = int(fields[1])
        except (OSError, ValueError, IndexError):
            break
        if parent <= 1 or parent in ancestors:
            break
        ancestors.add(parent)
        current = parent
    return ancestors


def observe_batch_cleanup(root, own_pid):
    """Observe, over the PRIVATE /proc of this namespace, whether any process
    of the batch survived.

    The criterion is the one of the case CLEAN-1: a live process of the batch
    that is neither the PID 1 of the namespace nor the observer itself is a
    leftover of the product, and the result is FAIL. The scaffolding that
    launched the batch is excluded as well (see ``process_ancestors``): it is
    alive by construction and it is not a leftover.

    The observation only sees the processes whose command line mentions the
    synthetic root of THIS batch, so it can never see a process of the host:
    the /proc it reads is the private one of the accredited frontier (both
    roles of this harness refuse to start without that accreditation).

    Returns (value, survivors) with value in PASS / FAIL / UNKNOWN:
      PASS     the observation was performed and it found NO leftover;
      FAIL     the observation was performed and it found a leftover;
      UNKNOWN  the observation could NOT be performed (no evidence at all).
    An empty observation is a legitimate PASS: the criterion is the ABSENCE
    of leftovers, not the presence of work, and a batch that never started
    has nothing to clean up.
    """
    excluded = set([1, int(own_pid)])
    excluded.update(process_ancestors(own_pid))
    survivors = []
    unobservable = 0
    unobservable_detail = ""
    try:
        entries = os.listdir(PROC_ROOT)
    except OSError as exc:
        return "UNKNOWN", ["no se pudo enumerar el /proc privado: %s" % exc]
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid in excluded:
            continue
        state, _pgrp, detail = observe_pid_state(pid)
        if state == PID_UNOBSERVABLE:
            # The state of the process could NOT be observed: it is neither a
            # leftover nor an absence. The observation is INCOMPLETE and it
            # is never published as a clean cleanup.
            unobservable += 1
            unobservable_detail = detail
            continue
        if state != PID_ALIVE:
            continue
        if root and root in cmdline_of(pid):
            survivors.append(pid)
    if unobservable:
        return "UNKNOWN", [
            "no se pudo observar el estado de %d proceso(s) del /proc privado%s"
            % (unobservable, (": " + unobservable_detail) if unobservable_detail else "")
        ]
    return ("PASS" if not survivors else "FAIL"), survivors


# The states of a PID, as the observation of this harness can tell them
# apart.
#
#   ALIVE         the process exists and it is not a zombie;
#   DEAD          the process is a zombie: dead, only not reaped yet;
#   ABSENT        the CONFIRMED absence: the /proc entry does not exist;
#   UNOBSERVABLE  the observation was IMPOSSIBLE: the read FAILED.
#
# The difference between ABSENT and UNOBSERVABLE is the whole point: an
# error of reading is NOT an absence, and an absence that was not observed
# is not an absence.
PID_ALIVE = "ALIVE"
PID_DEAD = "DEAD"
PID_ABSENT = "ABSENT"
PID_UNOBSERVABLE = "UNOBSERVABLE"


def read_proc_stat(pid):
    """The fields of the stat of a PID, read ONCE from its own entry.

    Returns (fields, error):
      fields the tokens that follow the last ')' of the line, or None;
      error  None when the read succeeded, "ABSENT" when the entry does not
             exist (the CONFIRMED absence), or the diagnosis of an
             IMPOSSIBLE observation.
    """
    path = proc_path("%d" % pid, "stat")
    try:
        with open(path, "r", encoding="ascii") as stream:
            raw = stream.read()
    except FileNotFoundError:
        # The kernel says that the entry does not exist: it is a FACT about
        # the process, not an error of the observation.
        return None, "ABSENT"
    except OSError as exc:
        # The read FAILED (a permission, an I/O error): the state of the
        # process could NOT be observed. It is NOT an absence.
        return None, "%s: %s" % (path, exc)
    fields = raw[raw.rfind(")") + 2 :].split()
    if len(fields) < 3:
        # A stat that cannot be parsed is NOT a dead process: it is an
        # observation that could not be made.
        return None, "%s: stat ilegible" % path
    return fields, None


def observe_pid_state(pid):
    """The state of a PID and its process group, read ONCE.

    Returns (state, pgrp, detail):
      state  ALIVE | DEAD | ABSENT | UNOBSERVABLE;
      pgrp   the process group, or None when it could not be read;
      detail the diagnosis of an impossible observation.
    """
    fields, error = read_proc_stat(pid)
    if error == "ABSENT":
        return PID_ABSENT, None, ""
    if error is not None:
        return PID_UNOBSERVABLE, None, error
    try:
        pgrp = int(fields[2])
    except (ValueError, IndexError) as exc:  # pragma: no cover - defensivo
        return PID_UNOBSERVABLE, None, "stat ilegible: %s" % exc
    if fields[0] == "Z":
        return PID_DEAD, pgrp, ""
    return PID_ALIVE, pgrp, ""


def process_group_of(pid):
    """The process group of a process, read from its own /proc entry.

    Returns None when the entry cannot be read (the process is gone or it
    is not observable): an unknown group is never guessed as 0.
    """
    fields, error = read_proc_stat(pid)
    if error is not None:
        return None
    try:
        return int(fields[2])
    except (ValueError, IndexError):
        return None


def innermost_nspid(pid):
    """The PID of a process in the INNERMOST namespace it belongs to.

    The kernel publishes the chain of PIDs of a process in the "NSpid" line
    of its status: the last one is the PID it has in the innermost
    namespace, which is the one that identifies the init of a private
    namespace (its PID there is 1).

    Returns None when the line cannot be read: an unidentified process is
    never assumed to be the init, nor assumed not to be it.
    """
    try:
        with open(proc_path("%d" % pid, "status"), "r", encoding="ascii", errors="replace") as stream:
            for line in stream:
                if line.startswith("NSpid:"):
                    parts = line.split()[1:]
                    if not parts:
                        return None
                    return int(parts[-1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def observe_containment_aftermath(private_ns, own_pgid):
    """Observe, over the PRIVATE /proc, the state of the contained environment.

    The absence of survivors of the private namespace, the absence of members
    of the own process group and the absence of the init of the namespace are
    NOT constants: they are the RESULT of an observation. A value that could
    not be observed is NOT_VERIFIABLE, and it is never published as a
    verified absence: an absence that was not observed is not an absence.

    The observation reads the private /proc of the frontier in which this
    supervisor runs (both roles of this harness refuse to start without that
    accreditation), so it can never see a process of the host.

    Arguments:
      private_ns  the identity of the private namespace of the contained run
                  ("pid:[N]"), as the receipt declares it;
      own_pgid    the process group that the batch created for its own
                  launcher, as it was OBSERVED when the launcher was spawned.

    Returns a dictionary with:
      state        "COMPLETE" or "INCOMPLETE";
      survivors    the live processes of the private namespace ([] | None);
      members      the live members of the own process group ([] | None);
      init_alive   True | False | None (None: not observable);
      init_gone    True | False | None (None: not observable);
      init_pid     the outer PID of the init of the namespace (None);
      detail       the diagnosis of the observation.
    """
    result = {
        "state": "INCOMPLETE",
        "survivors": None,
        "members": None,
        "init_alive": None,
        "init_gone": None,
        "init_pid": None,
        "detail": "",
    }
    if not private_ns or not re.match(r"^pid:\[[0-9]+\]$", str(private_ns)):
        result["detail"] = (
            "la identidad del namespace privado no es utilizable: %r" % (private_ns,)
        )
        return result

    excluded = set([1, os.getpid()])
    excluded.update(process_ancestors(os.getpid()))

    try:
        entries = os.listdir(PROC_ROOT)
    except OSError as exc:
        result["detail"] = "no se pudo enumerar el /proc privado: %s" % exc
        return result

    survivors = []
    members = []
    unreadable = 0
    unreadable_detail = ""
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid in excluded:
            continue
        try:
            namespace = os.readlink(proc_path("%d" % pid, "ns", "pid"))
        except OSError:
            if not os.path.isdir(proc_path("%d" % pid)):
                # It exited WHILE the observation was running: it is gone.
                continue
            unreadable += 1
            unreadable_detail = "no se pudo leer el namespace de %d" % pid
            continue
        state, pgrp, detail = observe_pid_state(pid)
        if state == PID_UNOBSERVABLE:
            # The state of the process could NOT be observed: it is neither a
            # survivor nor an absence. The observation of the aftermath is
            # INCOMPLETE, the absence is NOT verified and the init is NOT
            # declared gone.
            unreadable += 1
            unreadable_detail = detail
            continue
        alive = state == PID_ALIVE
        if namespace == private_ns and alive:
            survivors.append(pid)
        if own_pgid and pgrp == own_pgid and alive:
            members.append(pid)

    result["survivors"] = sorted(survivors)
    result["members"] = sorted(members) if own_pgid else None

    if not own_pgid:
        # The process group of the batch was NOT observed: the absence of
        # its members is NOT observable and it is never published as a
        # verified absence.
        result["state"] = "INCOMPLETE"
        result["detail"] = "el grupo de procesos propio no es observable"
        result["init_alive"] = None
        result["init_gone"] = None
        return result

    init_pid = None
    unidentified = 0
    for pid in survivors:
        innermost = innermost_nspid(pid)
        if innermost is None:
            unidentified += 1
            continue
        if innermost == 1:
            init_pid = pid
            break
    result["init_pid"] = init_pid

    if init_pid is not None:
        result["init_alive"] = True
        result["init_gone"] = False
    elif unidentified == 0:
        # No live process of the namespace carries the inner PID 1: the init
        # was OBSERVED to be gone.
        result["init_alive"] = False
        result["init_gone"] = True
    else:
        result["detail"] = (
            "no se pudo determinar el PID interior de %d proceso(s) del namespace privado"
            % unidentified
        )
        result["init_alive"] = None
        result["init_gone"] = None
        return result

    if unreadable:
        result["state"] = "INCOMPLETE"
        result["detail"] = (
            "%d proceso(s) del /proc privado no se pudieron observar%s"
            % (unreadable, (": " + unreadable_detail) if unreadable_detail else "")
        )
        result["init_alive"] = None
        result["init_gone"] = None
        return result

    result["state"] = "COMPLETE"
    if not result["detail"]:
        result["detail"] = (
            "observacion completa sobre el /proc privado: namespace=%s grupo=%s"
            % (private_ns, own_pgid)
        )
    return result


def declare_product_cleanup(result_file, root, own_pid):
    """Declares the result of the cleanup of the PRODUCT.

    The declaration is made over the PRIVATE /proc of the containment: the
    suite role only runs inside the accredited frontier, so it can only see
    the processes of the batch and never a process of the host.

    The criterion is the same one of the case CLEAN-1: a live process of the
    batch that is neither the PID 1 of the namespace nor the suite itself is
    a leftover of the product, and the result is FAIL.

    The marker is written BEFORE the defensive cleanup of the containment
    (the entry removes its own context afterwards), exactly as the contract
    of the entry requires.

    Returns the declared value and the list of survivors.
    """
    value, survivors = observe_batch_cleanup(root, own_pid)
    if result_file:
        try:
            with open(result_file, "w", encoding="utf-8") as handle:
                handle.write(value + "\n")
        except OSError as exc:
            print("FALLO: la suite no pudo declarar la limpieza del producto: %s" % exc)
            return "UNKNOWN", survivors
    return value, survivors


def write_product_cleanup_marker(path, value):
    """Publish the declaration of the cleanup of the product in the marker of
    the entry.

    Only the component that OBSERVED the cleanup writes this marker, and it
    writes it BEFORE the defensive cleanup of the entry. A value that could
    not be observed is published as UNKNOWN: the entry maps it to "not
    observed" and the acceptance of that invocation can never be positive.
    A PASS is never invented here.

    Returns True when the marker was published.
    """
    if not path:
        print("FALLO: no hay marcador de limpieza del producto que publicar.")
        return False
    if value not in ("PASS", "FAIL", "UNKNOWN"):
        value = "UNKNOWN"
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(value + "\n")
        return True
    except OSError as exc:
        print(
            "FALLO: no se pudo publicar la declaracion de limpieza del producto en %s: %s"
            % (path, exc)
        )
        return False


def require_admission(scope):
    """Require the accreditation of the containment of THIS invocation.

    The criterion is the one of tools/verification/require-v2-containment.sh:
    the SINGLE helper that the entries of tools/ already use. It is called as
    a process so there is one criterion of admission in the whole chain and
    not one per layer.

    The accreditation of the inner role_suite() is NOT a substitute for this
    one: it protects that role only, and it does not authorize the runner,
    the supervisor, the preparation, the controls nor the cleanup.

    Returns (ok, detail).
    """
    guard = os.path.join(CHECKOUT_ROOT, CONTAINMENT_GUARD_REL)
    if not os.path.isfile(guard):
        return False, "no existe el helper de admision: %s" % guard
    try:
        completed = subprocess.run(
            ["/bin/bash", guard],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, "el helper de admision no pudo ejecutarse: %s" % exc
    output = (completed.stdout or b"").decode("utf-8", "replace").strip()
    if completed.returncode != 0:
        return False, "admision denegada (rc=%d): %s" % (
            completed.returncode,
            output or "sin detalle",
        )
    return True, output or "admision acreditada"


def pid_alive(pid):
    """True only for a LIVE process: a zombie is dead, only not reaped yet.

    A reading that FAILED is not a death: the observation of that PID was
    IMPOSSIBLE, and a caller that publishes an ABSENCE has to know it. The
    function keeps its boolean shape for the callers that only need to know
    whether the process is running; the callers that certify an absence use
    ``observe_pid_state``, which tells the CONFIRMED absence and the
    IMPOSSIBLE observation apart.
    """
    state, _pgrp, _detail = observe_pid_state(pid)
    return state == PID_ALIVE


def wait_process_gone(pid, timeout=5.0):
    """Wait (bounded) until the /proc entry of the process disappears."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not process_present(pid):
            return True
        time.sleep(0.05)
    return not process_present(pid)


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def child_env(root, extra=None):
    """Allowlisted environment for every synthetic child."""
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": os.path.join(root, "home"),
        "TMPDIR": os.path.join(root, "tmp"),
        "LANG": "C",
        "LC_ALL": "C",
        # No Python child of this batch may write bytecode. Some of them
        # import the production modules BY PATH (the fuse driver loads
        # plugin-sync.py), and the import machinery would otherwise drop a
        # __pycache__ next to the source: inside the Git working tree and
        # inside the read-only external tree.
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    if extra:
        env.update(extra)
    return env


class _StderrCapture(object):
    """Captures writes done through ``sys.stderr.buffer``."""

    def __init__(self):
        self.buffer = io.BytesIO()

    @property
    def text(self):
        return self.buffer.getvalue().decode("utf-8", "replace")

    def write(self, _text):
        return None

    def flush(self):
        return None


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------
class Report(object):
    """The census of the bank and the census of its AUXILIARY controls.

    There are TWO censuses and they are NOT interchangeable:

      * the MAIN census (``self.cases``) is the bank itself. Its count is
        the contract of the bank (52) and every consumer reads it from
        ``summary``.
      * the AUXILIARY census (``self.auxiliary``) holds the CONTROLS OF
        THE CONTROLS (INSP-6, INSP-7 and INSP-8). They are counted APART,
        with their own total, their own count of failures and their own
        verdict, and they are published in their own section
        (``auxiliary_controls``).

    Mixing them would silently change the count of the bank (it would
    become 55) and it would make the auxiliary controls disappear into the
    aggregate: a consumer that only reads ``summary`` would not see that
    they are red. Keeping them apart is what makes them auditable, and
    their verdict is HARD: a red auxiliary control makes the run fail even
    though the main census is green.
    """

    def __init__(self):
        self.cases = []
        self.auxiliary = []
        self.containment = {}
        self.libraries = []
        self.cleanup = {}
        self.notes = []

    def record(self, case_id, kind, ok, detail):
        status = "PASS" if ok else "FAIL"
        self.cases.append(
            {"id": case_id, "kind": kind, "status": status, "detail": detail}
        )
        print("[%s] %s %s :: %s" % (case_id, status, kind, detail), flush=True)
        return ok

    def record_auxiliary(self, case_id, kind, ok, detail):
        """Record an AUXILIARY control: the controls of the controls.

        It is NOT part of the main census: the count of the bank does not
        change because of it. It has its own count and its own verdict,
        and a failure of one of them is a failure of the run.
        """
        status = "PASS" if ok else "FAIL"
        self.auxiliary.append(
            {"id": case_id, "kind": kind, "status": status, "detail": detail}
        )
        print("[aux] %s %s %s :: %s" % (case_id, status, kind, detail), flush=True)
        return ok

    def note(self, text):
        self.notes.append(text)
        print("[nota] %s" % text, flush=True)

    @property
    def failed(self):
        return sum(1 for case in self.cases if case["status"] != "PASS")

    @property
    def auxiliary_failed(self):
        """The auxiliary controls that are NOT green."""
        return sum(1 for case in self.auxiliary if case["status"] != "PASS")

    @property
    def auxiliary_ok(self):
        """The verdict of the auxiliary controls: 'PASS' only if all of them
        were recorded and all of them are green.

        It is a VERDICT and not a count: a control that was never recorded
        is a MISSING control, and a missing control is not a green one.
        """
        return self.auxiliary_summary()["verdict"] == "PASS"

    def counts(self):
        counts = {KIND_DYNAMIC: 0, KIND_SIMULATION: 0, KIND_INSPECTION: 0}
        for case in self.cases:
            counts[case["kind"]] = counts.get(case["kind"], 0) + 1
        return counts

    def auxiliary_summary(self):
        """The census of the auxiliary controls, with its own verdict.

        The verdict is a VERDICT and not a derived number:

          * 'PASS'          every declared control was recorded and every
                            one of them is green;
          * 'FAIL'          a recorded control is red, or the census is
                            incomplete (a control that was not recorded is
                            NOT a green one);
          * 'NOT_EXERCITED' no control was recorded at all: the run aborted
                            BEFORE the inspection, so the controls were
                            never reached. It is NOT a green verdict: the
                            run that reports it did not exercise them.

        Only 'PASS' is an acceptance.
        """
        recorded = [case["id"] for case in self.auxiliary]
        complete = sorted(recorded) == sorted(AUXILIARY_CONTROL_IDS)
        failed = self.auxiliary_failed
        if not self.auxiliary:
            verdict = "NOT_EXERCITED"
        elif complete and not failed:
            verdict = "PASS"
        else:
            verdict = "FAIL"
        return {
            "ids": list(AUXILIARY_CONTROL_IDS),
            "total": len(self.auxiliary),
            "passed": len(self.auxiliary) - failed,
            "failed": failed,
            "complete": complete,
            "verdict": verdict,
        }

    def write(self, path, extra=None):
        payload = {
            "batch": "forge-v2-followups Step 2.2",
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "cases": self.cases,
            "auxiliary_controls": {
                "ids": list(AUXILIARY_CONTROL_IDS),
                "cases": self.auxiliary,
                "summary": self.auxiliary_summary(),
            },
            "containment": self.containment,
            "libraries": self.libraries,
            "cleanup": self.cleanup,
            "notes": self.notes,
            "summary": {
                "total": len(self.cases),
                "passed": len(self.cases) - self.failed,
                "failed": self.failed,
                "by_kind": self.counts(),
            },
        }
        if extra:
            payload.update(extra)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
        os.replace(tmp, path)


# ---------------------------------------------------------------------------
# containment accreditation (performed from inside the private namespace)
# ---------------------------------------------------------------------------
def accredit_containment(env):
    checks = []
    failures = []

    def check(name, ok, value):
        checks.append({"check": name, "ok": bool(ok), "value": value})
        if not ok:
            failures.append("%s=%s" % (name, value))
        return bool(ok)

    raw = ""
    try:
        with open("/proc/1/stat", "r", encoding="ascii") as stream:
            raw = stream.read()
        # The first field of /proc/<pid>/stat is the pid; the comm field may
        # contain spaces, so it is never split blindly.
        pid1 = raw.split()[0]
    except (OSError, IndexError):
        pid1 = "<ilegible>"
    check("pid_interno_1", pid1 == "1", pid1)

    try:
        ns_pid = os.readlink("/proc/self/ns/pid")
    except OSError:
        ns_pid = "<ilegible>"
    host_ns_pid = env.get("FORGE_V2_HOST_PIDNS", "")
    check("ns_pid_privada", bool(host_ns_pid) and ns_pid != host_ns_pid, ns_pid)

    try:
        ns_user = os.readlink("/proc/self/ns/user")
    except OSError:
        ns_user = "<ilegible>"
    host_ns_user = env.get("FORGE_V2_HOST_USERNS", "")
    check("ns_user_privada", bool(host_ns_user) and ns_user != host_ns_user, ns_user)

    try:
        ns_mnt = os.readlink("/proc/self/ns/mnt")
    except OSError:
        ns_mnt = "<ilegible>"
    host_ns_mnt = env.get("FORGE_V2_HOST_MNTNS", "")
    check("ns_mnt_privada", bool(host_ns_mnt) and ns_mnt != host_ns_mnt, ns_mnt)

    proc_mounted = False
    hidepid = False
    try:
        with open("/proc/self/mountinfo", "r", encoding="utf-8", errors="replace") as stream:
            content = stream.read()
        proc_mounted = " - proc proc " in content
        hidepid = bool(re.search(r"(^|[,\s])hidepid=[1-9]", content))
    except OSError:
        pass
    check("proc_montado_privado", proc_mounted, "si" if proc_mounted else "no")
    check("proc_sin_hidepid", not hidepid, "si" if not hidepid else "si")

    uid = os.getuid()
    check("uid_mapeado_root", uid == 0, uid)

    pidfd_ok = hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")
    check("pidfd_disponible", pidfd_ok, "si" if pidfd_ok else "no")

    summary = "pid_interno=%s ns_pid=%s ns_user=%s ns_mnt=%s uid=%d proc_privado=%s pidfd=%s" % (
        pid1,
        ns_pid,
        ns_user,
        ns_mnt,
        uid,
        "si" if proc_mounted else "no",
        "si" if pidfd_ok else "no",
    )
    return {
        "ok": not failures,
        "reason": ", ".join(failures) if failures else "",
        "checks": checks,
        "summary": summary,
        "pid_interno": pid1,
        "ns_pid": ns_pid,
        "ns_user": ns_user,
        "ns_mnt": ns_mnt,
        "uid_mapeado": uid,
        "host_ns_pid": host_ns_pid,
        "host_ns_user": host_ns_user,
        "host_ns_mnt": host_ns_mnt,
    }


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
FIXTURE_WRITER = '''#!/usr/bin/env python3
"""Synthetic SQLite writer: keeps the WAL open and drives explicit transactions."""
import json
import sqlite3
import sys

path = sys.argv[1]
conn = sqlite3.connect(path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY, v TEXT)")
conn.commit()
sys.stdout.write("READY\\n")
sys.stdout.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    command = json.loads(line)
    op = command.get("op")
    if op == "insert":
        conn.execute("INSERT INTO t(k, v) VALUES (?, ?)", (command["k"], command["v"]))
    elif op == "commit":
        conn.commit()
    elif op == "rollback":
        conn.rollback()
    elif op == "close":
        conn.commit()
        conn.close()
        break
    sys.stdout.write("OK\\n")
    sys.stdout.flush()
'''

FIXTURE_FD_HOLDER = '''#!/usr/bin/env python3
"""Synthetic holder: keeps one file descriptor open on argv[1]."""
import os
import sys
import time

fd = os.open(sys.argv[1], os.O_RDONLY)
sys.stdout.write("READY\\n")
sys.stdout.flush()
while True:
    time.sleep(3600)
'''

FIXTURE_IGNORE_TERM = '''#!/usr/bin/env python3
"""Synthetic child that survives SIGTERM: the handler records the delivery."""
import signal
import sys
import time

marker = sys.argv[1]


def on_term(signum, frame):
    with open(marker, "a", encoding="utf-8") as handle:
        handle.write("TERM\\n")


signal.signal(signal.SIGTERM, on_term)
sys.stdout.write("READY\\n")
sys.stdout.flush()
while True:
    time.sleep(3600)
'''

FIXTURE_LEADER = '''#!/usr/bin/env python3
"""Synthetic group leader: leaves a descendant behind and exits early."""
import subprocess
import sys
import time

subprocess.Popen([sys.executable, "-c", "import time; time.sleep(3600)"])
sys.stdout.write("READY\\n")
sys.stdout.flush()
time.sleep(0.2)
'''

FIXTURE_FUSE_DRIVER = '''#!/usr/bin/env python3
"""Driver of the REAL deadline fuse: it must end the process with os._exit(124)."""
import importlib.util
import sys
import threading
import time

plugin_sync_path = sys.argv[1]
child_pid = int(sys.argv[2])
private_root = sys.argv[3]

spec = importlib.util.spec_from_file_location("plugin_sync_under_test", plugin_sync_path)
plugin_sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plugin_sync)

with plugin_sync.RUNTIME_OWNED_GROUPS_LOCK:
    plugin_sync.RUNTIME_OWNED_GROUPS.add(child_pid)

runtime_state = {"private_root": private_root}
runtime_state_lock = threading.Lock()
cancel = threading.Event()
plugin_sync._runtime_deadline_fuse(
    time.monotonic(), cancel, runtime_state, runtime_state_lock
)
sys.stderr.write("fuse returned without exiting\\n")
sys.exit(99)
'''


def write_fixtures(root):
    fixtures = os.path.join(root, "fixtures")
    os.makedirs(fixtures, mode=0o700, exist_ok=True)
    written = {}
    for name, body in (
        ("writer.py", FIXTURE_WRITER),
        ("fd_holder.py", FIXTURE_FD_HOLDER),
        ("ignore_term.py", FIXTURE_IGNORE_TERM),
        ("leader.py", FIXTURE_LEADER),
        ("fuse_driver.py", FIXTURE_FUSE_DRIVER),
    ):
        path = os.path.join(fixtures, name)
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(body)
        os.chmod(path, 0o700)
        written[name] = path
    return written


# ---------------------------------------------------------------------------
# suite: the acceptance cases
# ---------------------------------------------------------------------------
class Suite(object):
    def __init__(self, report, root, repo_root, external_root, real_db):
        self.report = report
        self.root = root
        self.repo_root = repo_root
        self.external_root = external_root
        self.db_dir = os.path.join(root, "db")
        self.private_dir = os.path.join(root, "private")
        self.scan_dir = os.path.join(root, "scan")
        self.fixtures_dir = os.path.join(root, "fixtures")
        self.children = []
        self.real_db = real_db
        self.real_db_before = fingerprint(real_db, hash_content=False) if real_db else {"exists": False}
        self.plugin_sync = None
        self.cutover_safety = None

    # -- utilities ---------------------------------------------------------
    def spawn(self, argv, env=None, session=False):
        proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env if env is not None else child_env(self.root),
            cwd=self.root,
            start_new_session=session,
        )
        self.children.append(proc)
        return proc

    def spawn_ready(self, argv, env=None, session=False):
        proc = self.spawn(argv, env=env, session=session)
        line = proc.stdout.readline().decode("utf-8", "replace").strip()
        if line != "READY":
            err = proc.stderr.read().decode("utf-8", "replace")[-400:]
            raise RuntimeError("fixture did not report READY (%r) stderr=%s" % (line, err))
        return proc

    def spawn_sleeper(self, argv, env=None, session=False):
        """Synthetic child that only sleeps: it never prints READY."""
        proc = self.spawn(argv, env=env, session=session)
        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                raise RuntimeError("el hijo sintetico termino antes de tiempo")
            time.sleep(0.05)
        return proc

    def assert_synthetic(self, path):
        real = os.path.realpath(path)
        root = os.path.realpath(self.root)
        if real != root and not real.startswith(root + os.sep):
            raise AssertionError("ruta no sintetica: %s" % path)
        return real

    def reap_orphans(self):
        """Reap zombies so the /proc inventory of the namespace stays clean."""
        for proc in self.children:
            try:
                proc.poll()
            except Exception:
                pass
        for _ in range(200):
            try:
                pid, _status = os.waitpid(-1, os.WNOHANG)
            except (ChildProcessError, OSError):
                break
            if pid <= 0:
                break

    def cleanup_children(self):
        for proc in self.children:
            try:
                if proc.poll() is None:
                    proc.kill()
            except OSError:
                pass
        for proc in self.children:
            try:
                proc.wait(timeout=5)
            except Exception:
                pass
        for _ in range(200):
            try:
                pid, _status = os.waitpid(-1, os.WNOHANG)
            except (ChildProcessError, OSError):
                break
            if pid <= 0:
                break

    # -- SNAP --------------------------------------------------------------
    def case_snapshot(self):
        """Coherent snapshot over a WAL database with an own writer."""
        plugin_sync = self.plugin_sync
        db = os.path.join(self.db_dir, "opencode.db")
        self.assert_synthetic(db)
        private = {}
        for tag in ("a", "b", "c", "d"):
            private[tag] = os.path.join(self.private_dir, "snapshot-%s.db" % tag)
            self.assert_synthetic(private[tag])

        writer = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "writer.py"), db]
        )

        def command(payload):
            writer.stdin.write((json.dumps(payload) + "\n").encode("utf-8"))
            writer.stdin.flush()
            ack = writer.stdout.readline().decode("utf-8", "replace").strip()
            if ack != "OK":
                raise RuntimeError("writer ack inesperado: %r" % ack)

        deadline = time.monotonic() + 60.0

        def snapshot(target):
            self.assert_synthetic(target)
            return plugin_sync._snapshot_database(db, target, deadline)

        def rows_of(path):
            import sqlite3

            conn = sqlite3.connect("file:" + path + "?mode=ro", uri=True)
            try:
                quick = conn.execute("PRAGMA quick_check").fetchone()[0]
                count = conn.execute("SELECT count(*) FROM t").fetchone()[0]
                keys = [row[0] for row in conn.execute("SELECT k FROM t ORDER BY k")]
            finally:
                conn.close()
            return quick, count, keys

        command({"op": "insert", "k": 1, "v": "pendiente"})
        origin_before = fingerprint(db)
        wal_before = fingerprint(db + "-wal")
        shm_before = fingerprint(db + "-shm")
        snapshot_a = snapshot(private["a"])
        # The companions of the DESTINATION are inspected BEFORE any reader
        # opens it: the backup connection closes cleanly, so the destination
        # must not leave a -wal/-shm behind.
        spurious = [s for s in ("-wal", "-shm") if os.path.exists(snapshot_a + s)]
        header = b""
        try:
            with open(snapshot_a, "rb") as stream:
                header = stream.read(20)
        except OSError:
            header = b""
        journal_mode = "WAL" if header[18:20] == b"\x02\x02" else "rollback"
        quick_a, count_a, _keys_a = rows_of(snapshot_a)
        origin_after = fingerprint(db)
        wal_after = fingerprint(db + "-wal")
        shm_after = fingerprint(db + "-shm")

        ok = True
        detail = []
        if quick_a != "ok":
            ok = False
            detail.append("quick_check=%s" % quick_a)
        else:
            detail.append("quick_check=ok")
        if count_a != 0:
            ok = False
            detail.append("filas_no_confirmadas_visibles=%d (esperado 0)" % count_a)
        else:
            detail.append("sin_lectura_sucia=ok")
        if origin_before != origin_after:
            ok = False
            detail.append("origen_modificado=%s" % json.dumps(origin_after, sort_keys=True))
        else:
            detail.append("origen_intacto=ok")
        if not wal_before.get("exists") or not wal_after.get("exists"):
            ok = False
            detail.append("wal_del_origen_ausente")
        elif wal_after["size"] < wal_before["size"]:
            ok = False
            detail.append("wal_del_origen_truncado")
        else:
            detail.append("wal_del_origen_intacto=ok")
        if not shm_before.get("exists") or not shm_after.get("exists"):
            ok = False
            detail.append("shm_del_origen_ausente")
        else:
            detail.append("shm_del_origen_intacto=ok")
        if spurious:
            ok = False
            detail.append("destino_con_companeros_espurios=%s" % spurious)
        else:
            detail.append("destino_sin_wal_shm_tras_el_snapshots=ok")
        import stat as statmod

        dest_mode = statmod.S_IMODE(os.stat(snapshot_a).st_mode)
        if dest_mode != 0o600:
            ok = False
            detail.append("modo_del_destino=%s (esperado 0600)" % oct(dest_mode))
        else:
            detail.append("modo_del_destino=0600")
        detail.append("modo_journal_del_destino=%s" % journal_mode)
        self.report.record("SNAP-1", KIND_DYNAMIC, ok, "; ".join(detail))

        command({"op": "commit"})
        snapshot_b = snapshot(private["b"])
        quick_b, count_b, keys_b = rows_of(snapshot_b)
        ok = quick_b == "ok" and count_b == 1 and keys_b == [1]
        self.report.record(
            "SNAP-2",
            KIND_DYNAMIC,
            ok,
            "quick_check=%s filas=%d claves=%s (esperado ok/1/[1])" % (quick_b, count_b, keys_b),
        )

        command({"op": "insert", "k": 2, "v": "a"})
        command({"op": "insert", "k": 3, "v": "b"})
        snapshot_c = snapshot(private["c"])
        quick_c, count_c, keys_c = rows_of(snapshot_c)
        ok = quick_c == "ok" and count_c == 1 and keys_c == [1]
        self.report.record(
            "SNAP-3",
            KIND_DYNAMIC,
            ok,
            "quick_check=%s filas=%d claves=%s (esperado ok/1/[1]; la transaccion abierta no se ve)"
            % (quick_c, count_c, keys_c),
        )

        command({"op": "commit"})
        snapshot_d = snapshot(private["d"])
        quick_d, count_d, keys_d = rows_of(snapshot_d)
        ok = quick_d == "ok" and count_d == 3 and keys_d == [1, 2, 3]
        self.report.record(
            "SNAP-4",
            KIND_DYNAMIC,
            ok,
            "quick_check=%s filas=%d claves=%s (esperado ok/3/[1,2,3])" % (quick_d, count_d, keys_d),
        )

        import sqlite3

        conn = sqlite3.connect(snapshot_d)
        conn.execute("INSERT INTO t(k, v) VALUES (99, 'copia')")
        conn.commit()
        conn.close()
        quick_src, count_src, _keys_src = rows_of(db)
        origin_final = fingerprint(db)
        ok = count_src == 3 and quick_src == "ok" and origin_final == origin_before
        self.report.record(
            "SNAP-5",
            KIND_DYNAMIC,
            ok,
            "origen_filas=%d quick_check=%s origen_intacto=%s (la escritura del destino no alcanza al origen)"
            % (count_src, quick_src, "si" if origin_final == origin_before else "no"),
        )

        try:
            plugin_sync._snapshot_database(db, db, time.monotonic() + 60.0)
            refused = False
            message = "no refusado"
        except plugin_sync.PluginSyncError as exc:
            refused = True
            message = str(exc)
        self.report.record(
            "SNAP-6",
            KIND_DYNAMIC,
            refused,
            "source==private rechazado=%s mensaje=%s" % ("si" if refused else "no", message),
        )

        # Observation: the destination inherits the journal mode of the source.
        # The companions a later reader recreates keep the 0600 mode of the
        # main file, so there is no permission leak in the private root.
        import stat as statmod

        modes = {}
        for suffix in ("", "-wal", "-shm"):
            path = snapshot_a + suffix
            if os.path.exists(path):
                modes[suffix or "main"] = oct(statmod.S_IMODE(os.stat(path).st_mode))
        self.report.note(
            "destino_snapshot: modo=%s permisos=%s (el destino hereda el modo WAL del origen)"
            % (journal_mode, json.dumps(modes, sort_keys=True))
        )

        # A source in rollback-journal mode must not gain any -wal/-shm.
        plain_db = os.path.join(self.db_dir, "journal.db")
        self.assert_synthetic(plain_db)
        import sqlite3

        conn = sqlite3.connect(plain_db)
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        plain_before = fingerprint(plain_db)
        plain_dest = os.path.join(self.private_dir, "journal-snapshot.db")
        plugin_sync._snapshot_database(plain_db, plain_dest, time.monotonic() + 60.0)
        plain_after = fingerprint(plain_db)
        spurious_plain = [
            suffix
            for suffix in ("-wal", "-shm")
            if os.path.exists(plain_db + suffix)
        ]
        ok = plain_before == plain_after and not spurious_plain
        self.report.record(
            "SNAP-7",
            KIND_DYNAMIC,
            ok,
            "origen_sin_wal_sin_shm: origen_intacto=%s compañeros_espurios=%s"
            % (
                "si" if plain_before == plain_after else "no",
                spurious_plain or "ninguno",
            ),
        )

        # A missing source creates an empty private database (0600).
        import stat as statmod

        missing_source = os.path.join(self.db_dir, "no-existe.db")
        empty_dest = os.path.join(self.private_dir, "vacia.db")
        created = plugin_sync._snapshot_database_command(
            missing_source, empty_dest, time.monotonic() + 60.0
        )
        empty_mode = statmod.S_IMODE(os.stat(created).st_mode) if os.path.exists(created) else None
        ok = (
            os.path.realpath(created) == os.path.realpath(empty_dest)
            and os.path.exists(created)
            and empty_mode == 0o600
        )
        self.report.record(
            "SNAP-8",
            KIND_DYNAMIC,
            ok,
            "origen_inexistente -> destino_creado=%s modo=%s (esperado 0600)"
            % (created, oct(empty_mode) if empty_mode is not None else "-"),
        )

        # The in-memory source is returned untouched.
        memory = plugin_sync._snapshot_database(":memory:", ":memory:", time.monotonic() + 60.0)
        self.report.record(
            "SNAP-9",
            KIND_DYNAMIC,
            memory == ":memory:",
            "fuente_en_memoria=%r (esperado ':memory:')" % memory,
        )

        try:
            writer.stdin.write(b'{"op":"close"}\n')
            writer.stdin.flush()
            writer.wait(timeout=10)
        except Exception:
            pass

    # -- DEAD --------------------------------------------------------------
    def case_deadline(self):
        """Deadline budget and the exit code contract."""
        plugin_sync = self.plugin_sync
        ok = True
        detail = []

        remaining = plugin_sync._deadline_check(time.monotonic() + 30.0)
        if not (24.0 <= remaining <= 25.0):
            ok = False
            detail.append("presupuesto=%s (esperado ~25)" % remaining)
        else:
            detail.append("presupuesto_ok=%.3f" % remaining)

        raised = False
        try:
            plugin_sync._deadline_check(time.monotonic() + 5.0)
        except plugin_sync.RuntimeDeadline:
            raised = True
        if not raised:
            ok = False
            detail.append("limite_no_elevado")
        else:
            detail.append("limite_elevado=RuntimeDeadline")
        self.report.record("DEAD-1", KIND_DYNAMIC, ok, "; ".join(detail))

        db = os.path.join(self.db_dir, "deadline.db")
        self.assert_synthetic(db)
        import sqlite3

        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        raised = False
        detail = []
        try:
            plugin_sync._snapshot_database(
                db, os.path.join(self.private_dir, "deadline-out.db"), time.monotonic()
            )
        except plugin_sync.RuntimeDeadline:
            raised = True
        except plugin_sync.PluginSyncError as exc:
            detail.append("error_inesperado=%s" % exc)
        if not raised:
            ok = False
            detail.append("snapshot_no_respeto_el_presupuesto")
        else:
            detail.append("snapshot_presupuesto=RuntimeDeadline")
        self.report.record("DEAD-2", KIND_DYNAMIC, ok, "; ".join(detail))

        # The CLI maps the expired budget to RC 124. The production budget
        # constant is shortened (the mapping itself is not modified).
        original_budget = plugin_sync.RUNTIME_MAX_SECONDS
        plugin_sync.RUNTIME_MAX_SECONDS = 0.5
        stdout_buffer = io.StringIO()
        stderr_buffer = _StderrCapture()
        try:
            with contextlib.redirect_stdout(stdout_buffer):
                with contextlib.redirect_stderr(stderr_buffer):
                    rc = plugin_sync.cmd_snapshot_db(
                        type(
                            "Args",
                            (),
                            {
                                "source": db,
                                "destination": os.path.join(self.private_dir, "cli-out.db"),
                            },
                        )()
                    )
        finally:
            plugin_sync.RUNTIME_MAX_SECONDS = original_budget
        stderr_text = stderr_buffer.text.strip()
        ok = rc == 124 and "deadline" in stderr_text.lower()
        self.report.record(
            "DEAD-3",
            KIND_DYNAMIC,
            ok,
            "rc=%d (esperado 124) stderr=%r stdout=%r" % (rc, stderr_text[:160], stdout_buffer.getvalue().strip()),
        )

        cli_source = os.path.join(self.db_dir, "cli.db")
        cli_dest = os.path.join(self.private_dir, "cli-real.db")
        conn = sqlite3.connect(cli_source)
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        proc = subprocess.run(
            [
                sys.executable,
                os.path.join(self.repo_root, PLUGIN_SYNC_REL),
                "snapshot-db",
                "--source",
                cli_source,
                "--destination",
                cli_dest,
            ],
            env=child_env(self.root),
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=90,
        )
        ok = (
            proc.returncode == 0
            and proc.stdout.decode().strip() == os.path.realpath(cli_dest)
        )
        self.report.record(
            "DEAD-4",
            KIND_DYNAMIC,
            ok,
            "rc=%d stdout=%r stderr=%r"
            % (
                proc.returncode,
                proc.stdout.decode().strip(),
                proc.stderr.decode().strip()[-120:],
            ),
        )

        proc = subprocess.run(
            [
                sys.executable,
                os.path.join(self.repo_root, PLUGIN_SYNC_REL),
                "snapshot-db",
                "--source",
                "relative.db",
                "--destination",
                cli_dest,
            ],
            env=child_env(self.root),
            cwd=self.root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=90,
        )
        self.report.record(
            "DEAD-5",
            KIND_DYNAMIC,
            proc.returncode == 1,
            "rc=%d (esperado 1) stderr=%r"
            % (proc.returncode, proc.stderr.decode().strip()[-160:]),
        )

    # -- FUSE --------------------------------------------------------------
    def case_fuse(self):
        """The os._exit of the deadline fuse stays isolated."""
        child = self.spawn_sleeper(
            [sys.executable, "-c", "import time; time.sleep(3600)"], session=True
        )
        private_root = os.path.join(self.root, "fuse-private")
        os.makedirs(private_root, mode=0o700, exist_ok=True)
        with open(os.path.join(private_root, "marker"), "w", encoding="utf-8") as stream:
            stream.write("sintetico\n")

        driver = subprocess.Popen(
            [
                sys.executable,
                os.path.join(self.fixtures_dir, "fuse_driver.py"),
                os.path.join(self.repo_root, PLUGIN_SYNC_REL),
                str(child.pid),
                private_root,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=child_env(self.root),
            cwd=self.root,
        )
        self.children.append(driver)
        _out, err = driver.communicate(timeout=60)
        rc = driver.returncode
        child.wait(timeout=10)
        child_alive = child.poll() is None
        root_gone = not os.path.exists(private_root)

        # The driver is the process that TRIGGERS the fuse. Once
        # communicate() returns it has already terminated: the fuse ends it
        # with os._exit(124). Its real state is computed here, never assumed.
        driver_alive = driver.poll() is None
        detail = [
            "rc_fusible=%d (esperado 124 por os._exit)" % rc,
            "hijillo_sigue_vivo=%s" % ("si" if child_alive else "no"),
            "raiz_privada_eliminada=%s" % ("si" if root_gone else "no"),
            "proceso_que_dispara_sigue_vivo=%s" % ("si" if driver_alive else "no"),
        ]
        if driver_alive:
            detail.append(
                "el proceso que dispara SIGUE VIVO (inesperado: el fusible deberia haberlo terminado)"
            )
        elif rc == 124:
            detail.append(
                "el proceso que dispara termino por os._exit(124): el os._exit no se propaga al harness"
            )
        else:
            detail.append(
                "el proceso que dispara termino con rc=%d (sin os._exit(124))" % rc
            )
        if rc != 124:
            detail.append("stderr=%r" % err.decode("utf-8", "replace")[-200:])
        self.report.record(
            "DEAD-6", KIND_DYNAMIC, rc == 124 and not child_alive and root_gone, "; ".join(detail)
        )

        # This case exercises the INNER harness process management: after the
        # driver's os._exit, the harness can still create a synthetic child of
        # its own and terminate it. It does NOT observe the EXTERNAL watchdog:
        # that watchdog is a pidfd held by the supervisor, which lives OUTSIDE
        # the private PID namespace, so it is not observable from here (the
        # supervisor PID is not visible in the namespace /proc, and the
        # authorization channel is closed by design right after the barrier is
        # released). The external watchdog is credited by the supervisor
        # itself, in the report evidence: the keys "cleanup.watchdog_operational"
        # and "cleanup.watchdog_detail", plus the "watchdog" entry of
        # "supervisor.steps" (the supervisor section itself carries no watchdog
        # keys; only authorization, role, started_at and steps).
        probe = self.spawn_sleeper(
            [sys.executable, "-c", "import time; time.sleep(3600)"], session=True
        )
        probe.kill()
        probe.wait(timeout=10)
        probe_gone = probe.poll() is not None
        self.report.record(
            "DEAD-7",
            KIND_DYNAMIC,
            probe_gone,
            "gestion de procesos INTERNA del harness tras el os._exit del driver: "
            "crea y termina su propio hijo sintetico (hijo terminado=%s); "
            "NO comprueba el watchdog externo (pidfd del supervisor, fuera del namespace)"
            % probe_gone,
        )

    # -- PIDFD -------------------------------------------------------------
    def case_pidfd(self):
        """pidfd stop of own children, bounded escalation and rejection."""
        safety = self.cutover_safety
        try:
            safety.check_pidfd_support()
            detail = "pidfd=disponible"
            ok = True
        except Exception as exc:
            detail = "pidfd=NO_DISPONIBLE %s" % exc
            ok = False
        self.report.record("PIDFD-1", KIND_DYNAMIC, ok, detail)

        child = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        registration = safety.register_server_child(child.pid, os.getpid(), sys.executable)
        if registration is None:
            self.report.record(
                "PIDFD-2",
                KIND_DYNAMIC,
                False,
                "register_server_child devolvio None (identidad no verificable)",
            )
        else:
            # The production routine reports, on its own stdout, WHICH
            # delivery ended the child ("... exited after pidfd SIGTERM" /
            # "... after pidfd SIGKILL"). Capturing that report is what proves
            # the signal was delivered THROUGH THE VERIFIED HANDLE and not by
            # any other route.
            stop_report = io.StringIO()
            with contextlib.redirect_stdout(stop_report):
                rc = safety.pidfd_stop_registered_server(
                    child.pid,
                    registration["start_ticks"],
                    registration["exe_normalized"],
                    registration["exe_dev_inode"],
                    registration["parent"],
                )
            stop_output = stop_report.getvalue()
            child.wait(timeout=10)
            status = child.returncode
            # The child is a 3600 s sleeper: it cannot finish by itself, so a
            # negative return code proves it was terminated by a signal. The
            # production routine always delivers SIGTERM through the verified
            # pidfd and escalates to SIGKILL through the SAME handle when the
            # child does not honour SIGTERM, which is what happens to a child
            # of the namespace init in some runners. The property under test
            # is the EFFECTIVE DELIVERY THROUGH THE HANDLE, not the concrete
            # signal number, so the observed signal is recorded and either one
            # is accepted. The escalation to SIGKILL through the same handle
            # stays pinned by PIDFD-3, whose fixture ignores SIGTERM on purpose.
            delivered = (
                "after pidfd SIGTERM" in stop_output or "after pidfd SIGKILL" in stop_output
            )
            signal_name = {
                -signal.SIGTERM: "SIGTERM",
                -signal.SIGKILL: "SIGKILL",
            }.get(status, "otra senal")
            ok = rc == 0 and status < 0 and delivered
            self.report.record(
                "PIDFD-2",
                KIND_DYNAMIC,
                ok,
                "rc=%d (esperado 0) senal_observada=%s (%s) (esperado: terminacion por senal; "
                "-15 = SIGTERM por el handle, -9 = escalado por SIGKILL por el MISMO handle) "
                "entrega_por_handle=%s exe=%s inode=%s"
                % (
                    rc,
                    status,
                    signal_name,
                    delivered,
                    registration["exe_normalized"],
                    registration["exe_dev_inode"],
                ),
            )

        marker = os.path.join(self.root, "term-marker")
        child = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), marker]
        )
        registration = safety.register_server_child(child.pid, os.getpid(), sys.executable)
        started = time.monotonic()
        rc = safety.pidfd_stop_registered_server(
            child.pid,
            registration["start_ticks"],
            registration["exe_normalized"],
            registration["exe_dev_inode"],
            registration["parent"],
        )
        elapsed = time.monotonic() - started
        child.wait(timeout=10)
        status = child.returncode
        delivered = os.path.exists(marker)
        ok = rc == 0 and status == -signal.SIGKILL and delivered and 10.0 <= elapsed <= 15.0
        self.report.record(
            "PIDFD-3",
            KIND_DYNAMIC,
            ok,
            "rc=%d senal=%s (esperado -9) term_entregado=%s escalado_en=%.2fs (presupuesto 15s)"
            % (rc, status, delivered, elapsed),
        )

        child = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        rc = safety.pidfd_stop_registered_server(
            child.pid, "999999999", "/bin/false", "0:0", str(os.getpid())
        )
        alive = child.poll() is None
        self.report.record(
            "PIDFD-4",
            KIND_DYNAMIC,
            rc == 3 and alive,
            "identidad_incorrecta rc=%d (esperado 3) proceso_vivo=%s (esperado si: no se senala)"
            % (rc, alive),
        )

        own = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        foreign = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        own_reg = safety.register_server_child(own.pid, os.getpid(), sys.executable)
        rc = safety.pidfd_stop_registered_server(
            foreign.pid,
            own_reg["start_ticks"],
            own_reg["exe_normalized"],
            own_reg["exe_dev_inode"],
            own_reg["parent"],
        )
        foreign_alive = foreign.poll() is None
        own_alive = own.poll() is None
        self.report.record(
            "PIDFD-5",
            KIND_DYNAMIC,
            rc == 3 and foreign_alive and own_alive,
            "ajeno rc=%d vivo=%s (esperado 3/si) y el propio intacto=%s"
            % (rc, foreign_alive, own_alive),
        )

        gone = self.spawn_sleeper([sys.executable, "-c", "import time; time.sleep(3600)"])
        gone.kill()
        gone.wait(timeout=10)
        rc = safety.pidfd_stop_registered_server(gone.pid, "1", "/bin/true", "0:0", str(os.getpid()))
        self.report.record(
            "PIDFD-6",
            KIND_DYNAMIC,
            rc == 0,
            "proceso_ya_salido rc=%d (esperado 0, sin senal)" % rc,
        )

    # -- HOLD --------------------------------------------------------------
    def case_holders(self):
        """Classification of DB/WAL/SHM holders, deleted paths and exe."""
        self.reap_orphans()
        safety = self.cutover_safety
        db = os.path.join(self.db_dir, "holders.db")
        self.assert_synthetic(db)
        import sqlite3

        conn = sqlite3.connect(db)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db + "-wal"])
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db + "-shm"])
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db])
        time.sleep(0.3)

        registration = {
            "valid": "0",
            "pid": "0",
            "start": "0",
            "exe": "/nonexistent",
            "dev_inode": "0:0",
            "shell_pid": str(os.getpid()),
        }

        def scan(tag, sequence, target_db):
            directory = os.path.join(self.scan_dir, tag)
            os.makedirs(directory, mode=0o700, exist_ok=True)
            return safety.scan_cutover_proc_inventory(
                target_db,
                "sintetico",
                sequence,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                registration,
            )

        def read(path):
            with open(path, "r", encoding="utf-8") as stream:
                return stream.read()

        result = scan("main", 1, db)
        holders = read(result["holders_file"])
        blockers = read(result["blockers_file"])
        opencode_processes = read(result["opencode_processes_file"])

        # The holder record is "destino_original=<destinos> ambito_destino=...";
        # several destinations are joined with "; ".
        destinations = set()
        for chunk in re.findall(r"destino_original=(.*?)\s+ambito_destino=", holders):
            for item in chunk.split("; "):
                destinations.add(item.strip())
        has_db = db in destinations
        has_wal = (db + "-wal") in destinations
        has_shm = (db + "-shm") in destinations
        blocker_pids = set(re.findall(r"^pid=(\d+)", blockers, re.MULTILINE))
        ok = (
            result["complete"]
            and result["holder_count"] >= 3
            and has_db
            and has_wal
            and has_shm
            and result["blocker_count"] >= 3
        )
        self.report.record(
            "HOLD-1",
            KIND_DYNAMIC,
            ok,
            "completo=%s holders=%d blockers=%d db=%s wal=%s shm=%s"
            % (
                result["complete"],
                result["holder_count"],
                result["blocker_count"],
                has_db,
                has_wal,
                has_shm,
            ),
        )

        # The holder of this fixture is this suite's OWN interpreter, so the
        # executable the scanner records is the interpreter of the CURRENT
        # runtime, wherever it is installed. The expectation is therefore
        # derived from the runtime itself (the production normalisation only
        # strips the " (deleted)" suffix), NEVER from a hardcoded path of a
        # developer's machine: the case must behave the same in a clean
        # runner, where the interpreter lives in another prefix.
        expected_exes = set()
        for candidate in (sys.executable, os.path.realpath(sys.executable)):
            if candidate.endswith(" (deleted)"):
                candidate = candidate[:-10]
            expected_exes.add(candidate)
        holder_exes = set(re.findall(r"exe_normalizado=(\S+)", holders))
        exe_matches = bool(holder_exes & expected_exes)
        ok = (
            opencode_processes.strip() == ""
            and "propiedad=ajeno_o_no_atribuible" in holders
            and exe_matches
        )
        self.report.record(
            "HOLD-2",
            KIND_DYNAMIC,
            ok,
            "procesos_opencode=%r | ejecutable_distinto=ajeno_o_no_atribuible:%s | "
            "ejecutable_del_holder=%s (esperado uno de %s)"
            % (
                opencode_processes.strip()[:60],
                "propiedad=ajeno_o_no_atribuible" in holders,
                sorted(holder_exes),
                sorted(expected_exes),
            ),
        )

        ghost = os.path.join(self.db_dir, "ghost.db")
        with open(ghost, "wb") as stream:
            stream.write(b"sintetico")
        self.spawn_ready([sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), ghost])
        time.sleep(0.3)
        os.unlink(ghost)
        time.sleep(0.3)
        ghost_result = scan("deleted", 2, ghost)
        ghost_holders = read(ghost_result["holders_file"])
        ok = ghost_result["holder_count"] >= 1 and "(deleted)" in ghost_holders
        self.report.record(
            "HOLD-3",
            KIND_DYNAMIC,
            ok,
            "holders=%d destino_deleted_presente=%s registro=%r"
            % (ghost_result["holder_count"], "(deleted)" in ghost_holders, ghost_holders.strip()[:160]),
        )

        bin_dir = os.path.join(self.fixtures_dir, "bin")
        os.makedirs(bin_dir, mode=0o700, exist_ok=True)
        gone_bin = os.path.join(bin_dir, "opencode")
        shutil.copy2(os.path.realpath(sys.executable), gone_bin)
        os.chmod(gone_bin, 0o700)
        self.spawn_ready(
            [gone_bin, os.path.join(self.fixtures_dir, "fd_holder.py"), db],
            env=child_env(self.root, {"OPENCODE_DB": db}),
        )
        time.sleep(0.3)
        os.unlink(gone_bin)
        time.sleep(0.3)
        deleted_result = scan("exe-deleted", 3, db)
        deleted_processes = read(deleted_result["opencode_processes_file"])
        ok = (
            "exe_deleted=si" in deleted_processes
            and "exe_original=%s (deleted)" % gone_bin in deleted_processes
            and "objetivo_cutover=si" in deleted_processes
        )
        self.report.record(
            "HOLD-4",
            KIND_DYNAMIC,
            ok,
            "procesos_opencode=%r" % deleted_processes.strip()[:220],
        )

        own_dir = os.path.join(bin_dir, "own")
        os.makedirs(own_dir, mode=0o700, exist_ok=True)
        own_exe = os.path.join(own_dir, "opencode")
        shutil.copy2(os.path.realpath(sys.executable), own_exe)
        os.chmod(own_exe, 0o700)
        own_child = self.spawn_ready(
            [own_exe, os.path.join(self.fixtures_dir, "fd_holder.py"), db],
            env=child_env(self.root, {"OPENCODE_DB": db}),
        )
        time.sleep(0.3)
        own_reg = safety.register_server_child(own_child.pid, os.getpid(), own_exe)
        if own_reg is None:
            self.report.record(
                "HOLD-5",
                KIND_DYNAMIC,
                False,
                "register_server_child devolvio None para el servidor propio",
            )
        else:
            own_registration = {
                "valid": "1",
                "pid": str(own_child.pid),
                "start": own_reg["start_ticks"],
                "exe": own_reg["exe_normalized"],
                "dev_inode": own_reg["exe_dev_inode"],
                "shell_pid": str(os.getpid()),
            }
            directory = os.path.join(self.scan_dir, "own")
            os.makedirs(directory, mode=0o700, exist_ok=True)
            own_result = safety.scan_cutover_proc_inventory(
                db,
                "sintetico",
                4,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                own_registration,
            )
            own_holders = read(own_result["holders_file"])
            own_blockers = read(own_result["blockers_file"])
            own_processes = read(own_result["opencode_processes_file"])
            own_blocker_pids = set(re.findall(r"^pid=(\d+)", own_blockers, re.MULTILINE))
            ok = (
                "propiedad=servidor_propio_verificado" in own_holders
                and str(own_child.pid) not in own_blocker_pids
                and "objetivo_cutover=si" in own_processes
            )
            self.report.record(
                "HOLD-5",
                KIND_DYNAMIC,
                ok,
                "servidor_propio_verificado=%s bloqueantes=%d (servidor_propio_en_bloqueantes=%s) objetivo_cutover_si=%s ambito_sandbox=%s"
                % (
                    "propiedad=servidor_propio_verificado" in own_holders,
                    own_result["blocker_count"],
                    str(own_child.pid) in own_blocker_pids,
                    "objetivo_cutover=si" in own_processes,
                    "SANDBOX" in own_processes,
                ),
            )

        rollback = safety.check_rollback_db_holders(db, "fase-sintetica", str(os.getpid()))
        ok = (
            rollback["complete"]
            and rollback["found_holder"]
            and any("no se señaliza" in item for item in rollback["holder_messages"])
        )
        self.report.record(
            "HOLD-6",
            KIND_DYNAMIC,
            ok,
            "completo=%s holders=%s mensajes=%r"
            % (
                rollback["complete"],
                rollback["found_holder"],
                rollback["holder_messages"][:1],
            ),
        )

        free_db = os.path.join(self.db_dir, "libre.db")
        conn2 = sqlite3.connect(free_db)
        conn2.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn2.commit()
        conn2.close()
        rollback_free = safety.check_rollback_db_holders(free_db, "fase-sintetica", str(os.getpid()))
        ok = rollback_free["complete"] and not rollback_free["found_holder"]
        self.report.record(
            "HOLD-7",
            KIND_DYNAMIC,
            ok,
            "completo=%s holders=%s (esperado sin holders)"
            % (rollback_free["complete"], rollback_free["found_holder"]),
        )

        # OBS-1: regression guard for D1. The classifier must match the
        # rollback-journal companion "<db>-journal" as well: a process that
        # holds only that descriptor IS a holder of the target database.
        journal_db = os.path.join(self.db_dir, "journal.db")
        conn3 = sqlite3.connect(journal_db)
        conn3.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn3.commit()
        conn3.close()
        journal_file = journal_db + "-journal"
        with open(journal_file, "wb") as stream:
            stream.write(b"sintetico")
        journal_holder = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), journal_file]
        )
        time.sleep(0.3)
        journal_result = scan("journal", 5, journal_db)
        journal_holders = read(journal_result["holders_file"])
        journal_blockers = read(journal_result["blockers_file"])
        detected = journal_file in journal_holders
        blocker_pids = set(re.findall(r"^pid=(\d+)", journal_blockers, re.MULTILINE))
        is_blocker = str(journal_holder.pid) in blocker_pids
        ok = detected and journal_result["holder_count"] >= 1 and is_blocker
        self.report.record(
            "OBS-1",
            KIND_DYNAMIC,
            ok,
            "regresion D1: el compañero <db>-journal SE clasifica como holder "
            "(holders=%d detectado=%s bloqueante=%s) — conjunto comparado db/-wal/-shm/-journal"
            % (journal_result["holder_count"], detected, is_blocker),
        )

    # -- SIM ---------------------------------------------------------------
    def case_simulations(self):
        """Deterministic simulations of the branches that cannot be reproduced
        safely and deterministically on this host."""
        safety = self.cutover_safety
        db = os.path.join(self.db_dir, "sim.db")
        import sqlite3

        conn = sqlite3.connect(db)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS t(k INTEGER PRIMARY KEY)")
        conn.commit()
        conn.close()
        holder = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "fd_holder.py"), db]
        )
        time.sleep(0.3)

        base_registration = {
            "valid": "0",
            "pid": "0",
            "start": "0",
            "exe": "/nonexistent",
            "dev_inode": "0:0",
            "shell_pid": str(os.getpid()),
        }

        def fresh_sim(name):
            return load_module(name, os.path.join(self.external_root, CUTOVER_SAFETY_REL))

        # --- SIM-1: unreadable descriptor directory -----------------------
        sim = fresh_sim("cutover_safety_sim_perm")
        real_os = sim.os

        class OsProxy(object):
            """Forwards everything to os but denies access to /proc/<pid>/fd."""

            def __init__(self, target, denied_pid):
                self._target = target
                self._denied = "/proc/%d/fd" % denied_pid

            def access(self, path, mode, **kwargs):
                if str(path).startswith(self._denied):
                    return False
                return self._target.access(path, mode, **kwargs)

            def __getattr__(self, name):
                return getattr(self._target, name)

        sim.os = OsProxy(real_os, holder.pid)
        directory = os.path.join(self.scan_dir, "sim-perm")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            perm_result = sim.scan_cutover_proc_inventory(
                db,
                "sintetico",
                10,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                base_registration,
            )
            with open(perm_result["errors_file"], "r", encoding="utf-8") as stream:
                perm_errors = stream.read()
        finally:
            sim.os = real_os
        ok = perm_result["complete"] is False and "descriptores fd inaccesibles" in perm_errors
        self.report.record(
            "SIM-1",
            KIND_SIMULATION,
            ok,
            "inyectado=os.access niega /proc/%d/fd -> completo=%s errores=%r"
            % (holder.pid, perm_result["complete"], perm_errors.strip()[:160]),
        )

        # --- SIM-2: a process that disappeared during the inventory -------
        sim2 = fresh_sim("cutover_safety_sim_ghost")
        real_glob = sim2.glob.glob
        ghost_pid = 999999

        def ghost_glob(pattern, *args, **kwargs):
            entries = real_glob(pattern, *args, **kwargs)
            if pattern == "/proc/[0-9]*":
                return list(entries) + ["/proc/%d" % ghost_pid]
            return entries

        sim2.glob.glob = ghost_glob
        directory = os.path.join(self.scan_dir, "sim-ghost")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            ghost_result = sim2.scan_cutover_proc_inventory(
                db,
                "sintetico",
                11,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                base_registration,
            )
            with open(ghost_result["errors_file"], "r", encoding="utf-8") as stream:
                ghost_errors = stream.read()
        finally:
            sim2.glob.glob = real_glob
        ok = (
            ghost_result["complete"] is False
            and "proceso desaparecio durante el inventario" in ghost_errors
        )
        self.report.record(
            "SIM-2",
            KIND_SIMULATION,
            ok,
            "inyectado=/proc/%d inexistente en el inventario -> completo=%s errores=%r"
            % (ghost_pid, ghost_result["complete"], ghost_errors.strip()[:160]),
        )

        # --- SIM-3: PID reuse detected between the two observations -------
        sim3 = fresh_sim("cutover_safety_sim_reuse")
        real_ticks = sim3._proc_start_ticks
        seen = {}

        def shifting_ticks(pid):
            value = real_ticks(pid)
            seen[pid] = seen.get(pid, 0) + 1
            if str(pid) == str(holder.pid) and seen[pid] >= 2 and value is not None:
                return str(int(value) + 1)
            return value

        sim3._proc_start_ticks = shifting_ticks
        directory = os.path.join(self.scan_dir, "sim-reuse")
        os.makedirs(directory, mode=0o700, exist_ok=True)
        try:
            reuse_result = sim3.scan_cutover_proc_inventory(
                db,
                "sintetico",
                12,
                directory,
                os.path.join(self.db_dir, "production.db"),
                os.path.join(self.root, "cutover-home"),
                os.path.join(self.root, "process-home"),
                str(os.getpid()),
                self.root,
                base_registration,
            )
            with open(reuse_result["errors_file"], "r", encoding="utf-8") as stream:
                reuse_errors = stream.read()
        finally:
            sim3._proc_start_ticks = real_ticks
        ok = (
            reuse_result["complete"] is False
            and "PID reutilizado durante el inventario" in reuse_errors
        )
        self.report.record(
            "SIM-3",
            KIND_SIMULATION,
            ok,
            "inyectado=inicio_ticks distinto en la segunda observacion -> completo=%s errores=%r"
            % (reuse_result["complete"], reuse_errors.strip()[:160]),
        )

        # --- SIM-4: same guard on the rollback classification --------------
        sim4 = fresh_sim("cutover_safety_sim_reuse_rb")
        real_ticks4 = sim4._proc_start_ticks
        seen4 = {}

        def shifting_ticks4(pid):
            value = real_ticks4(pid)
            seen4[pid] = seen4.get(pid, 0) + 1
            if str(pid) == str(holder.pid) and seen4[pid] >= 2 and value is not None:
                return str(int(value) + 1)
            return value

        sim4._proc_start_ticks = shifting_ticks4
        try:
            rollback_sim = sim4.check_rollback_db_holders(db, "fase-sintetica", str(os.getpid()))
        finally:
            sim4._proc_start_ticks = real_ticks4
        ok = (
            rollback_sim["complete"] is False
            and any("PID reutilizado" in item for item in rollback_sim["issue_messages"])
        )
        self.report.record(
            "SIM-4",
            KIND_SIMULATION,
            ok,
            "inyectado=inicio_ticks distinto en la segunda observacion (rollback) -> completo=%s avisos=%r"
            % (rollback_sim["complete"], rollback_sim["issue_messages"][:1]),
        )

    # -- GRP ---------------------------------------------------------------
    def case_groups(self):
        """Current contract of the group cleanup (no killpg redesign)."""
        plugin_sync = self.plugin_sync
        marker = os.path.join(self.root, "group-term-marker")
        descendant = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "leader.py")], session=True
        )
        descendant.wait(timeout=10)
        time.sleep(0.5)
        members = plugin_sync._process_group_pids(descendant.pid)
        started = time.monotonic()
        result = plugin_sync._terminate_process_groups([descendant], time.monotonic() + 10.0)
        elapsed = time.monotonic() - started
        remaining = plugin_sync._process_group_pids(descendant.pid)
        ok = (
            descendant.returncode == 0
            and len(members) == 1
            and result is True
            and not remaining
        )
        self.report.record(
            "GRP-1",
            KIND_DYNAMIC,
            ok,
            "lider_salida_temprana=%s descendientes_vivos_antes=%d resultado=%s supervivientes=%d elapsed=%.2fs"
            % (descendant.returncode, len(members), result, len(remaining), elapsed),
        )

        child = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), marker],
            session=True,
        )
        started = time.monotonic()
        result = plugin_sync._terminate_process_groups([child], time.monotonic() + 10.0)
        elapsed = time.monotonic() - started
        members = plugin_sync._process_group_pids(child.pid)
        delivered = os.path.exists(marker)
        control_marker = marker + ".control"
        control = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), control_marker],
            session=True,
        )
        control.kill()
        control.wait(timeout=10)
        # After the D2 fix the escalation is observable through the wait
        # status: the member that survived SIGTERM really died by SIGKILL.
        status = child.returncode
        ok = (
            result is True
            and not members
            and delivered
            and elapsed >= 0.4
            and status == -signal.SIGKILL
        )
        self.report.record(
            "GRP-2",
            KIND_DYNAMIC,
            ok,
            "resultado=%s supervivientes=%d term_entregado=%s elapsed=%.2fs (ventana TERM 0.5s) "
            "returncode=%s (esperado %d: escalado a SIGKILL)"
            % (result, len(members), delivered, elapsed, status, -signal.SIGKILL),
        )

        empty = self.spawn_sleeper(
            [sys.executable, "-c", "import time; time.sleep(3600)"], session=True
        )
        empty.kill()
        empty.wait(timeout=10)
        result = plugin_sync._terminate_process_groups([empty], time.monotonic() + 5.0)
        self.report.record(
            "GRP-3",
            KIND_DYNAMIC,
            result is True,
            "grupo_vacio resultado=%s (esperado True sin senalar)" % result,
        )

        # OBS-2: regression guard for D2. The production group reaper must
        # preserve the exit status of the direct children it is given, so the
        # caller can tell a signal death (-9) from a clean exit (0).
        status_child = self.spawn_ready(
            [sys.executable, os.path.join(self.fixtures_dir, "ignore_term.py"), marker + ".obs"],
            session=True,
        )
        plugin_sync._terminate_process_groups([status_child], time.monotonic() + 10.0)
        observed_status = status_child.returncode
        ok = observed_status == -signal.SIGKILL
        self.report.record(
            "OBS-2",
            KIND_DYNAMIC,
            ok,
            "regresion D2: tras _terminate_process_groups el returncode del hijo vale %s "
            "(esperado %d: la muerte por SIGKILL se refleja en Popen.returncode, no 0)"
            % (observed_status, -signal.SIGKILL),
        )

    # -- DBPATH ------------------------------------------------------------
    def case_database_path(self):
        """_runtime_database_path over a synthetic pinned CLI."""
        plugin_sync = self.plugin_sync
        bin_dir = os.path.join(self.fixtures_dir, "bin")
        os.makedirs(bin_dir, mode=0o700, exist_ok=True)
        target_db = os.path.join(self.db_dir, "resolved.db")
        with open(target_db, "wb") as stream:
            stream.write(b"sintetico")

        def make_fake(name, body):
            path = os.path.join(bin_dir, name)
            with open(path, "w", encoding="utf-8") as stream:
                stream.write(body)
            os.chmod(path, 0o700)
            return path

        ok_fake = make_fake(
            "fake-ok",
            "#!/bin/sh\nprintf '%%s\\n' '%s'\n" % target_db,
        )
        ambiguous_fake = make_fake(
            "fake-ambiguous",
            "#!/bin/sh\nprintf '%%s\\n%%s\\n' '%s' '%s'\n" % (target_db, target_db),
        )
        relative_fake = make_fake("fake-relative", "#!/bin/sh\nprintf 'relative.db\\n'\n")
        fail_fake = make_fake("fake-fail", "#!/bin/sh\nprintf 'boom\\n' >&2\nexit 3\n")
        hang_fake = make_fake("fake-hang", "#!/bin/sh\nsleep 300\n")

        owned = []
        resolved = plugin_sync._runtime_database_path(
            ok_fake, "", self.root, time.monotonic() + 30.0, owned
        )
        ok = resolved == os.path.realpath(target_db) and len(owned) == 1
        self.report.record(
            "DBPATH-1",
            KIND_DYNAMIC,
            ok,
            "ruta_resuelta=%s (esperado %s) procesos_propios=%d"
            % (resolved, os.path.realpath(target_db), len(owned)),
        )

        for case_id, binary, expected in (
            ("DBPATH-2", ambiguous_fake, "ambiguous"),
            ("DBPATH-3", relative_fake, "unsupported"),
            ("DBPATH-4", fail_fake, "RC=3"),
        ):
            message = ""
            failed = False
            try:
                plugin_sync._runtime_database_path(
                    binary, "", self.root, time.monotonic() + 30.0, []
                )
            except plugin_sync.PluginSyncError as exc:
                failed = True
                message = str(exc)
            self.report.record(
                case_id,
                KIND_DYNAMIC,
                failed and expected in message,
                "rechazado=%s mensaje=%r (esperado %r)" % (failed, message[:180], expected),
            )

        # Timeout: the owned session must be terminated by the deadline.
        before = set(
            entry
            for entry in os.listdir("/proc")
            if entry.isdigit() and hang_fake in cmdline_of(entry)
        )
        raised = False
        message = ""
        timeout_owned = []
        try:
            plugin_sync._runtime_database_path(
                hang_fake, "", self.root, time.monotonic() + 6.0, timeout_owned
            )
        except plugin_sync.RuntimeDeadline as exc:
            raised = True
            message = str(exc)
        except plugin_sync.PluginSyncError as exc:
            message = "PluginSyncError=%s" % exc
        time.sleep(0.5)
        after = set(
            entry
            for entry in os.listdir("/proc")
            if entry.isdigit() and hang_fake in cmdline_of(entry)
        )
        # After the D2 fix the terminated session reports its signal death.
        timeout_status = timeout_owned[0].returncode if timeout_owned else None
        status_ok = timeout_status is not None and timeout_status < 0
        ok = raised and not after and not (before - after) and status_ok
        self.report.record(
            "DBPATH-5",
            KIND_DYNAMIC,
            ok,
            "presupuesto_agotado=%s mensaje=%r antes=%d despues=%d returncode=%s (esperado <0: "
            "muerte por senal) — la sesion propia queda terminada"
            % (raised, message[:120], len(before), len(after), timeout_status),
        )

    # -- CLEAN -------------------------------------------------------------
    def real_db_open_descriptors(self):
        """Open descriptors of the batch pointing at the real database.

        Inside the private PID namespace only the processes of the batch are
        visible, so any hit means that THIS batch opened the real database.
        """
        found = []
        if not self.real_db:
            return found
        targets = (self.real_db, self.real_db + "-wal", self.real_db + "-shm")
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            fd_dir = os.path.join("/proc", entry, "fd")
            try:
                names = os.listdir(fd_dir)
            except OSError:
                continue
            for name in names:
                try:
                    link = os.readlink(os.path.join(fd_dir, name))
                except OSError:
                    continue
                if link in targets:
                    found.append((entry, name, link))
        return found

    def case_cleanup(self):
        """No synthetic process or resource of the batch survives.

        The criterion is the one of ``observe_batch_cleanup()``: a live
        process of the batch that is neither the init of the private
        namespace, nor the observer itself, nor one of its ancestors is a
        leftover of the PRODUCT.

        The init of the private namespace is the scaffolding that launched
        this suite (it is its PARENT and its exit is what tears the namespace
        down), so it is alive BY CONSTRUCTION while the batch runs: counting
        it would report the scaffolding as a survivor of the product. The
        criterion is NOT weakened: every other process of the batch is still
        looked for, over the PRIVATE /proc of the accredited frontier.
        """
        value, survivors = observe_batch_cleanup(self.root, os.getpid())
        self.report.record(
            "CLEAN-1",
            KIND_DYNAMIC,
            value == "PASS",
            "supervivientes_propios=%s (esperado []) observacion=%s "
            "(el init del namespace privado y los antepasados del observador son "
            "andamiaje vivo por construccion: no son un resto del producto)" % (survivors, value),
        )
        # The real database must never be OPENED by this batch. Its mtime
        # cannot be used as evidence: the live OpenCode session of the user
        # writes to it continuously. The reliable invariants are the inode
        # identity and the absence of any open descriptor of the batch.
        after = fingerprint(self.real_db, hash_content=False) if self.real_db else {"exists": False}
        open_fds = self.real_db_open_descriptors()
        inode_stable = (
            self.real_db_before.get("ino") == after.get("ino")
            and self.real_db_before.get("dev") == after.get("dev")
        )
        ok = not open_fds and inode_stable
        self.report.record(
            "CLEAN-2",
            KIND_DYNAMIC,
            ok,
            "la db real nunca se abre: descriptores_abiertos_del_lote=%s (esperado []) "
            "identidad_estable=%s ino=%s size=%s mtime_antes=%s mtime_despues=%s "
            "(el mtime no sirve como evidencia: la sesion viva del usuario escribe en ella; "
            "solo metadatos, sin leer contenido)"
            % (
                open_fds,
                inode_stable,
                after.get("ino"),
                after.get("size"),
                self.real_db_before.get("mtime_ns"),
                after.get("mtime_ns"),
            ),
        )

    # -- INSP --------------------------------------------------------------
    def case_inspection(self):
        plugin_sync_path = os.path.join(self.repo_root, PLUGIN_SYNC_REL)
        safety_path = os.path.join(self.external_root, CUTOVER_SAFETY_REL)
        ok = os.path.isfile(plugin_sync_path) and os.path.isfile(safety_path)
        self.report.record(
            "INSP-1",
            KIND_INSPECTION,
            ok,
            "plugin_sync=%s sha256=%s | cutover_safety=%s sha256=%s"
            % (
                plugin_sync_path,
                sha256_file(plugin_sync_path) if os.path.isfile(plugin_sync_path) else "-",
                safety_path,
                sha256_file(safety_path) if os.path.isfile(safety_path) else "-",
            ),
        )

        # ------------------------------------------------------------------
        # INSP-2: the PROVENANCE of the modules that the bench really loaded,
        # as a HARD failure.
        #
        # The reference is the file that the REPOSITORY versions, never the
        # path the module was loaded from: a comparison against the latter is
        # satisfied by itself and certifies nothing. That was the defect of
        # this control: it compared the loaded module with the very path it
        # had been loaded from, so it could never be red.
        #
        # A module loaded from another tree (FORGE_V2_EXTERNAL_ROOT pointed
        # somewhere else) or from a copy is therefore a FAILURE of the bank,
        # not an informative note.
        # ------------------------------------------------------------------
        loaded = []
        for name, module, canonical_rel in (
            ("plugin-sync", self.plugin_sync, PLUGIN_SYNC_REL),
            ("cutover-safety", self.cutover_safety, CANONICAL_COMPONENT_REL),
        ):
            canonical_abs = os.path.join(self.repo_root, canonical_rel)
            loaded_file = getattr(module, "__file__", "") or ""
            ok, detail = verify_module_provenance(
                self.repo_root, loaded_file, canonical_rel
            )
            loaded.append(
                {
                    "name": name,
                    "path": loaded_file,
                    "expected": canonical_abs,
                    "matches": ok,
                    "sha256": sha256_file(loaded_file) if os.path.isfile(loaded_file) else "-",
                    "detail": detail,
                }
            )
        self.report.libraries = loaded
        ok = all(item["matches"] for item in loaded)
        self.report.record(
            "INSP-2",
            KIND_INSPECTION,
            ok,
            "procedencia_dura=%s | %s"
            % (
                "OK" if ok else "FALLO",
                " | ".join(
                    "%s: cargado=%s canonico=%s :: %s"
                    % (item["name"], item["path"], item["expected"], item["detail"])
                    for item in loaded
                ),
            ),
        )

        # ------------------------------------------------------------------
        # INSP-3: the UNIQUENESS of the COMPLETE versioned component inside
        # the checkout, as a HARD failure.
        #
        # The set is CANONICAL_COMPONENT_FILES: every implementation file of
        # the two versioned components (cutover_safety.py, dbtool.py,
        # cutover.sh, ROLLBACK.sh and plugin-sync.py), not only the exact
        # name cutover_safety.py. The canonical paths are derived from the
        # REPOSITORY, never from the component that was selected to run.
        # ------------------------------------------------------------------
        duplicates = find_component_duplicates(self.repo_root, CANONICAL_COMPONENT_FILES)
        unique_ok = all(
            not entry["name_copies"] and not entry["content_copies"] for entry in duplicates
        )
        self.report.record(
            "INSP-3",
            KIND_INSPECTION,
            unique_ok,
            "unicidad_en_el_checkout=%s ficheros=%d | %s"
            % (
                "OK" if unique_ok else "FALLO",
                len(duplicates),
                " | ".join(
                    "%s: Copies_por_nombre=%s copias_por_contenido=%s"
                    % (
                        os.path.relpath(entry["canonical"], self.repo_root),
                        entry["name_copies"],
                        entry["content_copies"],
                    )
                    for entry in duplicates
                ),
            ),
        )

        executed = []
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            cmdline = cmdline_of(entry)
            for token in EXTERNAL_ENTRYPOINT_TOKENS:
                if token in cmdline:
                    executed.append((entry, token))
        self.report.record(
            "INSP-4",
            KIND_INSPECTION,
            not executed,
            "entrypoints_externos_o_dbtool_en_ejecucion=%s (esperado [])" % (executed,),
        )

        expected = {
            "plugin_sync": [
                "_runtime_deadline_fuse",
                "_runtime_database_path",
                "_snapshot_database",
                "_terminate_process_groups",
                "_process_group_pids",
            ],
            "cutover_safety": [
                "check_pidfd_support",
                "pidfd_stop_registered_server",
                "register_server_child",
                "scan_cutover_proc_inventory",
                "check_rollback_db_holders",
            ],
        }
        modules = {"plugin_sync": self.plugin_sync, "cutover_safety": self.cutover_safety}
        missing = []
        signatures = []
        for key, names in expected.items():
            module = modules[key]
            for name in names:
                function = getattr(module, name, None)
                if function is None or not callable(function):
                    missing.append("%s.%s" % (key, name))
                else:
                    signatures.append("%s.%s%s" % (key, name, inspect.signature(function)))
        self.report.record(
            "INSP-5",
            KIND_INSPECTION,
            not missing,
            "funciones=%s | firmas=%s"
            % ("todas presentes" if not missing else missing, "; ".join(signatures)),
        )

        # ------------------------------------------------------------------
        # INSP-6, INSP-7 and INSP-8: the CONTROLS OF THE CONTROLS.
        #
        # A control that cannot be red certifies nothing, and a check that
        # is never exercised against a case that must fail is a check that
        # might well be satisfied by itself. These three cases close both
        # gaps:
        #
        #   INSP-6  a COPY of the component, placed in a TEMPORARY directory,
        #           is REJECTED by the criterion of the provenance. The copy
        #           is never loaded over the personal installation: it is
        #           written under the synthetic root of the batch and it is
        #           only a PATH that is submitted to the criterion.
        #   INSP-7  the LEGITIMATE copy, the one that the repository versions,
        #           is ACCEPTED by the very same criterion. Without this
        #           case, INSP-6 would also be satisfied by a criterion that
        #           rejects everything.
        #   INSP-8  a tree with a PLANTED duplicate is DETECTED by the
        #           criterion of the uniqueness. The tree is synthetic and it
        #           lives under the synthetic root of the batch: the checkout
        #           is never modified.
        # ------------------------------------------------------------------
        controls = self.case_provenance_controls()
        recorded = []
        for case_id, ok, detail in controls:
            # They are recorded as AUXILIARY controls: they are counted
            # apart from the bank and they have their own verdict. They are
            # NOT cases of the bank: adding them to the main census would
            # silently change the contract of the bank (52 -> 55) and it
            # would bury their verdict inside the aggregate.
            self.report.record_auxiliary(case_id, KIND_INSPECTION, ok, detail)
            recorded.append(case_id)
        missing = [
            case_id for case_id in AUXILIARY_CONTROL_IDS if case_id not in recorded
        ]
        unexpected = [case_id for case_id in recorded if case_id not in AUXILIARY_CONTROL_IDS]
        if missing or unexpected:
            # A control that was not recorded is NOT a green control: the
            # census of the auxiliary controls has to be EXACTLY the declared
            # one. The verdict of the census (Report.auxiliary_summary) is
            # what turns this into a failure of the run.
            self.report.note(
                "censo auxiliar incompleto: ausentes=%r inesperados=%r (declarados=%r)"
                % (missing, unexpected, list(AUXILIARY_CONTROL_IDS))
            )

    def case_provenance_controls(self):
        """The controls of the provenance and of the uniqueness.

        They are exercised over SYNTHETIC trees under the synthetic root of
        the batch. Nothing outside that root is written, and the personal
        installation of OpenCode is never touched: the copy that has to be
        rejected is a copy in a temporary directory, and it is submitted to
        the criterion as a PATH (it is never loaded, so no external code is
        ever executed).

        Returns a list of (case_id, ok, detail).
        """
        results = []
        workspace = os.path.join(self.root, "provenance-controls")
        canonical_abs = os.path.join(self.repo_root, CANONICAL_COMPONENT_REL)

        def private_dir(path):
            """Create a directory tree whose EVERY level is private."""
            path = os.path.abspath(path)
            missing = []
            current = path
            while current and not os.path.isdir(current):
                missing.append(current)
                parent = os.path.dirname(current)
                if parent == current:
                    break
                current = parent
            for level in reversed(missing):
                os.mkdir(level, 0o700)
            return path

        # -- INSP-6: an EXTERNAL copy must be REJECTED ---------------------
        external_root = private_dir(os.path.join(workspace, "external-copy"))
        external_copy = os.path.join(external_root, CUTOVER_SAFETY_REL)
        private_dir(os.path.dirname(external_copy))
        shutil.copyfile(canonical_abs, external_copy)
        external_ok, external_detail = verify_module_provenance(
            self.repo_root, external_copy, CANONICAL_COMPONENT_REL
        )
        results.append(
            (
                "INSP-6",
                not external_ok,
                "copia_externa_en_temporal=RECHAZADA=%s ruta=%s :: %s"
                % (not external_ok, external_copy, external_detail),
            )
        )

        # -- INSP-7: the LEGITIMATE copy must be ACCEPTED -------------------
        legitimate_ok, legitimate_detail = verify_module_provenance(
            self.repo_root, canonical_abs, CANONICAL_COMPONENT_REL
        )
        results.append(
            (
                "INSP-7",
                legitimate_ok,
                "copia_legitima_del_componente_versionado=ACEPTADA=%s ruta=%s :: %s"
                % (legitimate_ok, canonical_abs, legitimate_detail),
            )
        )

        # -- INSP-8: a PLANTED duplicate must be DETECTED -------------------
        synthetic_root = os.path.join(workspace, "synthetic-checkout")
        synthetic_canonical = os.path.join(
            synthetic_root, os.path.join("tools", "cutover", "forge-v2", CUTOVER_SAFETY_REL)
        )
        private_dir(os.path.dirname(synthetic_canonical))
        shutil.copyfile(canonical_abs, synthetic_canonical)
        planted = os.path.join(synthetic_root, "otro", "cutover_safety.py")
        private_dir(os.path.dirname(planted))
        shutil.copyfile(canonical_abs, planted)
        planted_entries = find_component_duplicates(
            synthetic_root, [os.path.join("tools", "cutover", "forge-v2", CUTOVER_SAFETY_REL)]
        )
        planted_found = bool(planted_entries) and bool(
            planted_entries[0]["name_copies"] or planted_entries[0]["content_copies"]
        )
        results.append(
            (
                "INSP-8",
                planted_found,
                "duplicado_plantado=DETECTADO=%s copia_plantada=%s :: %s"
                % (
                    planted_found,
                    planted,
                    planted_entries[0] if planted_entries else "sin entradas",
                ),
            )
        )
        return results

    # -- driver ------------------------------------------------------------
    def run(self):
        cases = [
            self.case_snapshot,
            self.case_deadline,
            self.case_database_path,
            self.case_fuse,
            self.case_pidfd,
            self.case_holders,
            self.case_simulations,
            self.case_groups,
        ]
        for function in cases:
            try:
                function()
            except Exception:
                self.report.record(
                    "ERROR-" + function.__name__.upper(),
                    KIND_DYNAMIC,
                    False,
                    "excepcion: %s" % traceback.format_exc().strip().splitlines()[-1],
                )
        # The synthetic children are terminated BEFORE the cleanup evidence is
        # taken: "no process of the batch survives" is asserted on a state in
        # which the batch has already released its own resources.
        self.cleanup_children()
        for function in (self.case_cleanup, self.case_inspection):
            try:
                function()
            except Exception:
                self.report.record(
                    "ERROR-" + function.__name__.upper(),
                    KIND_DYNAMIC,
                    False,
                    "excepcion: %s" % traceback.format_exc().strip().splitlines()[-1],
                )


# ---------------------------------------------------------------------------
# role: suite (inside the private namespace)
# ---------------------------------------------------------------------------
def _role_suite_body(args, report, root):
    """The execution of the suite role, once its admission was accredited.

    It returns (rc, suite). The suite is None when the role aborted before
    creating it: the synthetic root then belongs to the supervisor and not to
    this role, and it is the supervisor that removes it.
    """
    # This suite loads the production modules BY PATH (load_module), so the
    # import machinery would otherwise write a __pycache__ next to the source:
    # inside the Git working tree (open-code/lib/) and inside the read-only
    # external tree (lib/). The import is NOT disabled: the real modules are
    # loaded and their real functions are exercised. Only the WRITING of
    # bytecode is suppressed, and this flag makes the guarantee intrinsic to
    # the process instead of depending on the inherited environment.
    sys.dont_write_bytecode = True
    try:
        os.makedirs(root, mode=0o700, exist_ok=True)
    except OSError:
        pass
    containment = accredit_containment(os.environ)
    report.containment = containment
    if not containment["ok"]:
        report.record(
            "PRE-1",
            KIND_DYNAMIC,
            False,
            "BLOCKED: contencion no acreditada (%s)" % containment["reason"],
        )
        print("BLOCKED: la contencion no pudo acreditarse: %s" % containment["reason"])
        return 3, None
    report.record(
        "PRE-1",
        KIND_DYNAMIC,
        True,
        "contencion acreditada: %s" % containment["summary"],
    )

    # Fault injection (test harness only): spawn a synthetic child and hang,
    # so the supervisor has to terminate the namespace init AND its
    # descendants through its cleanup chain.
    #
    # The synthetic hang IGNORES SIGTERM on purpose: the bounded close of the
    # containment escalates to SIGKILL, and that is the hard termination the
    # scenario has to exercise.
    if os.environ.get(FAULT_HANG_SUITE) == "1":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        child = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(3600)"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(
            "[inyeccion] hijo sintetico creado (pid interno %d); la suite se cuelga a proposito"
            % child.pid,
            flush=True,
        )
        while True:
            time.sleep(3600)

    # Authorization barrier: no sensitive function is called until the
    # supervisor has accredited the containment and has an operational
    # watchdog. An unreleased barrier aborts the suite with a non zero RC.
    granted, reason = await_authorization(args.auth_fd)
    containment["authorization"] = {"granted": granted, "reason": reason}
    if not granted:
        report.record("PRE-2", KIND_DYNAMIC, False, "BLOCKED: %s" % reason)
        print("BLOCKED: la barra de autorizacion no se libero: %s" % reason)
        return 4, None
    report.record(
        "PRE-2",
        KIND_DYNAMIC,
        True,
        "autorizacion del supervisor concedida: %s" % reason,
    )

    suite = Suite(report, root, args.repo_root, args.external_root, args.real_db)
    try:
        for name in ("db", "private", "scan", "home", "tmp"):
            os.makedirs(os.path.join(root, name), mode=0o700, exist_ok=True)
        write_fixtures(root)
        suite.plugin_sync = load_module(
            "plugin_sync_under_test", os.path.join(args.repo_root, PLUGIN_SYNC_REL)
        )
        suite.cutover_safety = load_module(
            "cutover_safety_under_test",
            os.path.join(args.external_root, CUTOVER_SAFETY_REL),
        )
        suite.run()
    except Exception:
        report.record(
            "ERROR-SUITE",
            KIND_DYNAMIC,
            False,
            "excepcion: %s" % traceback.format_exc().strip().splitlines()[-1],
        )
    # The auxiliary controls (the controls of the controls) are HARD: a red
    # one, or a missing one, fails the run even when the main census of the
    # bank is green. They are counted apart, but they are NOT optional.
    if not report.auxiliary_ok:
        print(
            "FALLO: los controles auxiliares de la procedencia y de la unicidad no son "
            "verdes: %r" % (report.auxiliary_summary(),),
            flush=True,
        )
        return 1, suite
    return (1 if report.failed else 0), suite


def role_suite(args):
    report = Report()
    root = args.root

    # -------------------------------------------------------------------------
    # ADMISSION. The suite is a consumer of the product: it may not create a
    # single file of the batch, nor read a single /proc entry, unless the
    # containment of THIS invocation is accredited. The accreditation of the
    # role_suite() itself (the check of the namespace, further below) is NOT
    # a substitute: it protects this role only and it does not authorize the
    # runner, the supervisor, the preparation, the controls nor the cleanup.
    # -------------------------------------------------------------------------
    admitted, admission_detail = require_admission("suite")
    if not admitted:
        print(
            "BLOCKED: la admision de la contencion no fue acreditada para el rol suite: %s"
            % admission_detail
        )
        print(
            "Accion: invoque la cadena completa mediante "
            "tools/verification/forge-contained-run.sh con --receipt-dir "
            "<directorio de recibos nuevo, o el que declare la invocacion>, un "
            "--scenario-timeout/--close-timeout revisado y la orden completa tras --."
        )
        return ADMISSION_DENIED_RC
    report.note("admision de contencion acreditada (suite): %s" % admission_detail)

    suite = None
    report_write_error = None
    rc = 3
    try:
        rc, suite = _role_suite_body(args, report, root)
    finally:
        if suite is not None:
            suite.cleanup_children()
        # The result of the cleanup of the PRODUCT is declared HERE, over the
        # PRIVATE /proc of the containment and BEFORE the defensive cleanup
        # of the entry: a consumer may not presume it and the closure of the
        # harness does not turn a failure of the product into a success.
        #
        # The declaration is made on EVERY path of this role, including the
        # aborts: an environment that is abandoned still has to declare its
        # own cleanup. When the process is KILLED (the hang scenario) the
        # declaration cannot be made at all and the result stays UNKNOWN: the
        # entry then refuses to certify that invocation.
        declared_cleanup, declared_survivors = declare_product_cleanup(
            os.environ.get("FORGE_PRODUCT_CLEANUP_RESULT_FILE", ""),
            root,
            os.getpid(),
        )
        # It is NOT recorded as an extra case: the declaration is written in
        # the marker of the entry and its evidence reaches the supervisor
        # through the receipt (PRODUCT_CLEANUP_RESULT). The census of cases
        # of the report stays the one that the scenarios expect.
        print(
            "[limpieza] producto=%s supervivientes_propios=%s (declarado sobre el /proc "
            "privado, antes de la limpieza defensiva)"
            % (declared_cleanup, declared_survivors),
            flush=True,
        )
        try:
            report.write(args.report_path)
        except OSError as exc:
            # The evidence must never be lost silently.
            report_write_error = "la suite no pudo escribir su parte del informe en %s: %s" % (
                args.report_path,
                exc,
            )
            print("FALLO: %s" % report_write_error)
        if suite is not None:
            shutil.rmtree(root, ignore_errors=True)
    counts = report.counts()
    auxiliary = report.auxiliary_summary()
    print(
        "[resumen] casos=%d fallidos=%d dinamicas=%d simulaciones=%d inspecciones=%d "
        "auxiliares=%d aux_fallidos=%d aux_veredicto=%s"
        % (
            len(report.cases),
            report.failed,
            counts[KIND_DYNAMIC],
            counts[KIND_SIMULATION],
            counts[KIND_INSPECTION],
            auxiliary["total"],
            auxiliary["failed"],
            auxiliary["verdict"],
        ),
        flush=True,
    )
    if report_write_error:
        return 9
    return rc


# ---------------------------------------------------------------------------
# role: supervisor (outside any namespace)
# ---------------------------------------------------------------------------
AMBIGUOUS_RECEIPT_KEY = "__AMBIGUOUS__"
"""Marker of an ambiguous receipt.

A receipt that declares the same field twice is ambiguous: the value that a
consumer would read depends on the order of the lines, so the receipt cannot
certify anything and the caller MUST reject it.
"""


def read_receipt(path):
    """The fields of the receipt of a contained run, as a dictionary.

    An absent, empty or unreadable receipt is an EMPTY dictionary: the
    evidence is missing and the caller must treat it as such. It is never
    completed with a default that would read as a PASS.

    A receipt that repeats a field is AMBIGUOUS: it is returned with the
    marker ``AMBIGUOUS_RECEIPT_KEY`` so the caller rejects it explicitly
    instead of reading the first occurrence as if it were the only one.
    """
    fields = {}
    ambiguous = False
    if not path:
        return fields
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as stream:
            for line in stream:
                line = line.rstrip("\n")
                if not line or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                if not key:
                    continue
                if key in fields:
                    ambiguous = True
                    continue
                fields[key] = value
    except OSError:
        return {}
    if ambiguous:
        fields[AMBIGUOUS_RECEIPT_KEY] = "YES"
    return fields


def exit_code_of(value):
    """The exit code of a scenario, as the supervisor reports it.

    A scenario that was killed by a signal is reported with the NEGATIVE
    number of that signal (the convention of the shell and of the subprocess
    module): a scenario killed by SIGKILL is -9, never 137.

    The conversion accepts BOTH forms of the SAME fact: the raw status that
    the shell observed (137) and the already normalised one (-9). Before
    this correction the negative form was rejected as "not a number" and
    the conversion returned None for it, so a receipt that carried -9 was
    read as an ABSENT exit code. An absent exit code and a termination by
    SIGKILL are different facts, and only the first one was accepted.

    The TWO representations are told apart BEFORE any normalisation, and
    each one is validated against ITS OWN domain:

      * the NEGATIVE form "-N" is the already normalised signal form: N is
        the number of the signal, so N has to be a REAL signal of this
        platform (1..MAX_SIGNAL). A negative form whose magnitude is
        outside that domain is NOT a signal: the shell NEVER publishes a
        negative status, so "-137" is a CONTRADICTION and not "the signal
        9". It is rejected, never reinterpreted;
      * the POSITIVE form is an exit status (0..127) or the "128+N" of the
        shell for a termination by the signal N (129..128+MAX_SIGNAL).
        The value 128 is RESERVED (it is neither an exit status nor
        128+N, because a signal 0 does not exist) and everything above
        128+MAX_SIGNAL names a signal that does not exist.

    An ABSENT or an INVALID value is NOT an exit code: it returns None, so
    the caller REJECTS the evidence instead of reading a missing value as a
    mismatch that happens to satisfy a loose comparison (in Python,
    ``None != 0`` is true).
    """
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    negative = text.startswith("-")
    digits = text[1:] if negative else text
    if not digits or not digits.isascii() or not digits.isdigit():
        return None
    number = int(text)
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


def termination_state_of(code):
    """The OBSERVED termination state of a scenario, kept apart from its RC.

    The state is a DIFFERENT fact from the exit code and it is published
    apart: a timeout of the scenario and a termination by SIGKILL are two
    observations, and neither one substitutes the other.

    Returns one of:
      "EXITED:<rc>"      the scenario returned on its own with that code;
      "SIGNALLED:<n>"    the scenario was terminated by the signal <n>
                         (SIGKILL is "SIGNALLED:9");
      "UNOBSERVABLE"     there is no valid exit code to observe.
    """
    if code is None:
        return "UNOBSERVABLE"
    if code < 0:
        return "SIGNALLED:%d" % (-code)
    return "EXITED:%d" % code


def await_authorization(auth_fd):
    """Block until the supervisor releases the authorization barrier.

    The barrier is released ONLY when the supervisor has accredited the
    containment and has an operational watchdog (a pidfd on the namespace
    init). Any other outcome reaches the suite as EOF on the channel, and the
    suite aborts before calling a single sensitive function.

    Returns ``(granted, reason)``.
    """
    if auth_fd is None or auth_fd < 0:
        return False, "the suite was started without an authorization channel"
    try:
        duplicate = os.dup(auth_fd)
    except OSError as exc:
        return False, "the authorization channel is not usable: %s" % exc
    try:
        with os.fdopen(duplicate, "rb", buffering=0) as stream:
            line = stream.readline()
    except OSError as exc:
        return False, "the authorization channel could not be read: %s" % exc
    token = line.decode("utf-8", "replace").strip()
    if token != AUTH_TOKEN:
        return False, (
            "the authorization token %r was not received; the supervisor closed "
            "the channel without releasing the barrier" % token
        )
    return True, token


def resolve_report_path(path):
    """Normalise the report path ONCE, so the supervisor and the suite always
    share the very same absolute file.

    A relative path is resolved against the batch evidence root, NEVER
    against the working directory: the suite runs with its own cwd (the
    batch root, which the supervisor deletes afterwards) and the supervisor
    runs wherever the operator invoked it, possibly inside the Git working
    tree. Resolving against a fixed base keeps both actors on one file and
    leaves no stray artefact in the repository.
    """
    expanded = os.path.expanduser(path)
    if os.path.isabs(expanded):
        return os.path.normpath(expanded)
    return os.path.normpath(os.path.join(BATCH_ROOT, expanded))


def proc_identity(pid):
    """Identity of a process owned by the batch (never of a host process)."""
    identity = {"pid": pid}
    try:
        identity["exe"] = os.readlink("/proc/%d/exe" % pid)
        meta = os.stat("/proc/%d/exe" % pid)
        identity["exe_dev_inode"] = "%d:%d" % (meta.st_dev, meta.st_ino)
    except OSError:
        identity["exe"] = "<ilegible>"
        identity["exe_dev_inode"] = "<ilegible>"
    for name in ("pid", "user", "mnt"):
        try:
            identity["ns_" + name] = os.readlink("/proc/%d/ns/%s" % (pid, name))
        except OSError:
            identity["ns_" + name] = "<ilegible>"
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii") as stream:
            raw = stream.read()
        fields = raw[raw.rfind(")") + 2 :].split()
        identity["pgrp"] = int(fields[2])
        identity["session"] = int(fields[3])
        identity["start_time_ticks"] = fields[19]
    except (OSError, ValueError, IndexError):
        pass
    try:
        with open("/proc/%d/status" % pid, "r", encoding="ascii") as stream:
            for line in stream:
                if line.startswith("Uid:"):
                    identity["uid_host"] = int(line.split()[1])
                    break
    except OSError:
        pass
    return identity


# ---------------------------------------------------------------------------
# role: supervisor (outside any namespace)
#
# The supervisor does NOT create a namespace of its own and it does NOT
# sweep the process table of the host: the containment is the single
# authorized entry (tools/verification/forge-contained-run.sh) and the
# guarantee "no own survivor" is the CLOSURE of that namespace, recorded in
# its receipt.
# ---------------------------------------------------------------------------
def role_supervisor(args):
    evidence = {
        "role": "supervisor",
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "steps": [],
    }

    def step(name, ok, detail):
        evidence["steps"].append({"step": name, "ok": bool(ok), "detail": detail})
        print("[supervisor] %s %s :: %s" % (name, "OK" if ok else "FAIL", detail), flush=True)
        return ok

    # ---------------------------------------------------------------------------
    # ADMISSION. The supervisor is the OUTER consumer of the bank: it reads the
    # /proc of this namespace, it creates the synthetic root and it launches the
    # suite. It may do NONE of that unless the containment of THIS invocation
    # is accredited.
    #
    # The accreditation that the suite performs for ITSELF (and the one that
    # the inner entry performs for the suite) does not authorize the
    # supervisor, the runner or the preparation: they are all consumers of
    # the same chain and all of them need the outer accreditation.
    # ---------------------------------------------------------------------------
    admitted, admission_detail = require_admission("supervisor")
    if not admitted:
        step("admision", False, admission_detail)
        print(
            "BLOCKED: la admision de la contencion no fue acreditada para el rol supervisor: %s"
            % admission_detail
        )
        print(
            "Accion: invoque la cadena completa mediante "
            "tools/verification/forge-contained-run.sh con --receipt-dir "
            "<directorio de recibos nuevo, o el que declare la invocacion>, un "
            "--scenario-timeout/--close-timeout revisado y la orden completa tras --."
        )
        return ADMISSION_DENIED_RC
    step("admision", True, admission_detail)

    plugin_sync_path = os.path.join(args.repo_root, PLUGIN_SYNC_REL)
    safety_path = os.path.join(args.external_root, CUTOVER_SAFETY_REL)
    if not os.path.isfile(plugin_sync_path):
        step("componentes", False, "falta %s" % plugin_sync_path)
        print("BLOCKED: falta el componente requerido %s" % plugin_sync_path)
        return 2
    if not os.path.isfile(safety_path):
        step("componentes", False, "falta %s" % safety_path)
        print("BLOCKED: falta el componente requerido %s" % safety_path)
        return 2
    step(
        "componentes",
        True,
        "plugin_sync=%s sha256=%s | cutover_safety=%s sha256=%s"
        % (plugin_sync_path, sha256_file(plugin_sync_path), safety_path, sha256_file(safety_path)),
    )

    # ---------------------------------------------------------------------------
    # The containment is the SINGLE authorized entry of this bank.
    #
    # The supervisor does NOT create a namespace of its own, it does NOT keep
    # an external watchdog and it does NOT sweep the process table of the
    # host: the entry establishes a private PID namespace with a private
    # /proc, accredits the boundary BY INVOCATION, closes the contained
    # environment with a bounded budget and records everything in a receipt.
    #
    # The guarantee "no own survivor" is therefore NOT a sweep: it is the
    # CLOSURE of the namespace, which the kernel performs when its PID 1
    # exits, and the receipt of the run.
    # ---------------------------------------------------------------------------
    containment_entry = os.path.join(CHECKOUT_ROOT, "tools", "verification", "forge-contained-run.sh")
    if not os.path.isfile(containment_entry):
        step(
            "contencion",
            False,
            "no existe la entrada de contencion: %s" % containment_entry,
        )
        print("BLOCKED: la entrada de contencion no esta disponible; no se llama a ninguna funcion sensible")
        return 3
    step("contencion", True, "entrada unica de contencion: %s" % containment_entry)

    root = os.path.join(BATCH_ROOT, "safety-run-%d" % os.getpid())
    shutil.rmtree(root, ignore_errors=True)
    for name in ("", "home", "tmp", "db", "private", "scan", "fixtures"):
        os.makedirs(os.path.join(root, name), mode=0o700, exist_ok=True)
    os.chmod(root, 0o700)

    host_ns_pid = os.readlink("/proc/self/ns/pid")
    host_ns_user = os.readlink("/proc/self/ns/user")
    host_ns_mnt = os.readlink("/proc/self/ns/mnt")

    # The report path is normalised ONCE here: the suite receives the very
    # same absolute file that the supervisor reads back and completes.
    report_path = resolve_report_path(args.report_path)
    os.makedirs(os.path.dirname(report_path) or ".", exist_ok=True)

    # The environment the suite needs travels as POSITIONAL ARGUMENTS and is
    # exported by the wrapper: the containment rebuilds the environment with
    # env -i and inherits nothing.
    hang_flag = "1" if os.environ.get(FAULT_HANG_SUITE) == "1" else ""
    wrapper_script = (
        'export FORGE_V2_HOST_PIDNS="$1" FORGE_V2_HOST_USERNS="$2" '
        'FORGE_V2_HOST_MNTNS="$3" FORGE_V2_REAL_DB="$4" '
        'FORGE_V2_TEST_HANG_SUITE="$5" PYTHONDONTWRITEBYTECODE=1; '
        "shift 5; exec \"$@\""
    )
    receipt_pointer = os.path.join(root, "receipt-pointer.txt")
    # The budget of the contained scenario is expressed in WHOLE SECONDS: the
    # containment entry only accepts an integer number of seconds and it
    # refuses (fail-closed, with its usage message) any other format. The
    # supervisor's own --timeout is a float, so it is normalised HERE, at the
    # only site that builds the order: the floor never exceeds the declared
    # budget and the floor of 1 keeps the value inside the accepted range.
    scenario_timeout_seconds = max(1, int(args.timeout))
    # The RC contracted for the inner scenario, declared by the runner of the
    # scenarios. It is validated HERE (fail-closed): a malformed declaration
    # is never guessed and never defaults to a value that could certify a
    # mismatch as a match.
    expected_scenario_rc = os.environ.get(EXPECTED_SCENARIO_RC_ENV, "").strip()
    if not expected_scenario_rc:
        expected_scenario_rc = "0"
    if expected_scenario_rc != "NONE" and not expected_scenario_rc.isdigit():
        step(
            "expectativa",
            False,
            "declaracion de RC esperado invalida: %r (debe ser un entero no negativo o NONE)"
            % expected_scenario_rc,
        )
        print(
            "BLOCKED: el RC esperado del escenario no es valido (%r); no se lanza la suite"
            % expected_scenario_rc
        )
        return 2
    # The directory of receipts of the INNER invocation.
    #
    # It is NOT a path of a machine: the consumer may DECLARE one and, when
    # it does not, the harness creates a directory of ITS OWN invocation.
    #
    # It is deliberately a SIBLING of the run root and NOT a child of it:
    # the run root of the supervisor and the run root of the suite are
    # named with the PID of each role, and the PIDs of two roles CAN
    # coincide (each role lives in its own PID namespace, where the
    # numbering restarts). If the receipts lived inside the run root, the
    # cleanup of the suite could remove the receipt of the supervisor and
    # the evidence of the invocation would vanish with it.
    if CONTAINMENT_RECEIPT_DIR:
        containment_receipt_dir = CONTAINMENT_RECEIPT_DIR
    else:
        containment_receipt_dir = tempfile.mkdtemp(
            prefix="receipts-supervisor-", dir=BATCH_ROOT
        )
    command = [
        "/bin/bash",
        containment_entry,
        "--receipt-dir",
        containment_receipt_dir,
        "--receipt-out",
        receipt_pointer,
        "--scenario-timeout",
        str(scenario_timeout_seconds),
        "--close-timeout",
        "5",
        "--",
        "/bin/sh",
        "-c",
        wrapper_script,
        "forge-v2-suite",
        host_ns_pid,
        host_ns_user,
        host_ns_mnt,
        args.real_db,
        hang_flag,
        sys.executable,
        os.path.abspath(__file__),
        "--role",
        "suite",
        "--root",
        root,
        "--repo-root",
        args.repo_root,
        "--external-root",
        args.external_root,
        "--report-path",
        report_path,
        "--real-db",
        args.real_db,
        "--auth-fd",
        "0",
    ]

    # The authorization channel: the suite blocks on it until the supervisor
    # has verified the accreditation of the containment.
    auth_read, auth_write = os.pipe()
    # The expectation of THIS scenario travels to the containment entry, which
    # records it in its receipt: the verdict of the entry and the verdict of
    # this supervisor are then computed against the SAME declaration.
    entry_env = dict(os.environ)
    entry_env[CONTAINED_EXPECTED_SCENARIO_RC_ENV] = expected_scenario_rc
    launcher = subprocess.Popen(
        command,
        stdin=auth_read,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        cwd=root,
        start_new_session=True,
        env=entry_env,
    )
    os.close(auth_read)

    # The process group that the batch created for its own launcher is
    # OBSERVED here, while the launcher is alive: the absence of the members
    # of that group is a later observation, and an observation needs a
    # subject that was observed too.
    #
    # The launcher is spawned with start_new_session=True, so it is a
    # session leader and its process group is its own PID. The observed
    # value is preferred and the construction is the fallback.
    launcher_pgid = launcher.pid
    launcher_pgid_source = "session-leader (start_new_session=True)"
    pgid_deadline = time.monotonic() + 2.0
    while time.monotonic() < pgid_deadline:
        observed_pgid = process_group_of(launcher.pid)
        if observed_pgid is None:
            break
        if observed_pgid == launcher.pid:
            launcher_pgid = observed_pgid
            launcher_pgid_source = "observado en /proc/%d/stat" % launcher.pid
            break
        time.sleep(0.02)

    def pump():
        while True:
            line = launcher.stdout.readline()
            if not line:
                break
            sys.stdout.write(line.decode("utf-8", "replace"))
            sys.stdout.flush()

    pump_thread = threading.Thread(target=pump, daemon=True)
    pump_thread.start()

    # ---------------------------------------------------------------------------
    # The accreditation of the boundary is read from the receipt directory of
    # THIS invocation: it is a file of the batch, never the process table of
    # the host.
    # ---------------------------------------------------------------------------
    receipt_path = ""
    accreditation_ok = False
    accreditation_detail = ""
    deadline = time.monotonic() + 60.0
    while time.monotonic() < deadline:
        if os.path.isfile(receipt_pointer):
            try:
                with open(receipt_pointer, "r", encoding="utf-8") as stream:
                    receipt_path = stream.read().strip()
            except OSError:
                receipt_path = ""
        if receipt_path:
            status_file = os.path.join(os.path.dirname(receipt_path), "accreditation.status")
            status = ""
            try:
                with open(status_file, "r", encoding="ascii") as stream:
                    status = stream.read().strip()
            except OSError:
                status = ""
            if status == "PASS":
                accreditation_ok = True
                accreditation_detail = "acreditacion por invocacion en %s" % status_file
                break
            if status == "FAILED":
                accreditation_detail = "la contencion no accredito su frontera (%s)" % status_file
                break
        if launcher.poll() is not None:
            break
        time.sleep(0.02)
    step(
        "contencion",
        accreditation_ok,
        accreditation_detail or "la contencion no publico su acreditacion a tiempo",
    )

    # The bounded close of the contained environment is the mechanism of the
    # entry (timeout --kill-after + unshare --kill-child). The fault
    # injection disarms the AUTHORIZATION, exactly as the retired pidfd
    # watchdog did: the barrier stays closed and the suite aborts.
    watchdog_ok = False
    if os.environ.get(FAULT_NO_PIDFD) == "1":
        watchdog_detail = (
            "inyeccion de fallo (%s=1): el cierre acotado de la contencion no se "
            "considera operativo y la barra de autorizacion no se libera" % FAULT_NO_PIDFD
        )
    else:
        watchdog_ok = True
        watchdog_detail = (
            "cierre acotado operativo: la entrada de contencion aplica "
            "timeout --kill-after y unshare --kill-child sobre el init del namespace"
        )
    step("watchdog", watchdog_ok, watchdog_detail)

    # The barrier is released ONLY when the containment accredited its
    # boundary AND its bounded close is considered operational. Otherwise the
    # channel is closed and the suite aborts before any sensitive call.
    containment_ok = bool(accreditation_ok)
    authorized = False
    auth_reason = ""
    if watchdog_ok and containment_ok:
        try:
            os.write(auth_write, (AUTH_TOKEN + "\n").encode("utf-8"))
            authorized = True
            auth_reason = (
                "autorizacion concedida: contencion acreditada por invocacion y "
                "cierre acotado operativo"
            )
        except OSError as exc:
            auth_reason = "no se pudo escribir la autorizacion: %s" % exc
    else:
        auth_reason = "la barra de autorizacion NO se libera: %s" % (
            "cierre acotado no operativo"
            if not watchdog_ok
            else "contencion no acreditada"
        )
    try:
        os.close(auth_write)
    except OSError:
        pass
    step("barrera", authorized, auth_reason)
    evidence["authorization"] = {"granted": authorized, "reason": auth_reason}

    started = time.monotonic()
    timed_out = False
    while True:
        if launcher.poll() is not None:
            break
        if time.monotonic() - started > args.timeout + 120:
            timed_out = True
            break
        time.sleep(0.05)

    # The launcher is waited for BEFORE the cleanup chain, so the chain never
    # signals a process that is on its way out.
    try:
        launcher.wait(timeout=120)
    except subprocess.TimeoutExpired:
        timed_out = True
    if launcher.poll() is None:
        # The only own resource that may still be alive is the launcher this
        # supervisor created: it is terminated THROUGH ITS IDENTITY, never by
        # name and never by a sweep of the host.
        launcher_identity = proc_identity(launcher.pid)
        launcher.kill()
        try:
            launcher.wait(timeout=30)
        except subprocess.TimeoutExpired:
            pass
        cleanup_actions = [
            "el lanzador no termino solo: se termino por su identidad (%s)" % launcher_identity
        ]
    else:
        cleanup_actions = [
            "el cierre lo aplico la entrada de contencion (timeout --kill-after + "
            "unshare --kill-child); el lanzador fue esperado y recogido"
        ]
    step(
        "limpieza_ejecucion",
        True,
        "cadena de limpieza aplicada: %s" % ("; ".join(cleanup_actions) or "sin acciones"),
    )
    pump_thread.join(timeout=10)
    launcher_rc = launcher.returncode

    # The receipt of the run is the evidence: the accreditation of the
    # boundary, the RC of the scenario, the result of the cleanup of the
    # product and the result of the closure.
    #
    # The field of the containment evidence was RENAMED to
    # CONTAINMENT_EVIDENCE_CERTIFIABLE and it has NO alias: the legacy key
    # "CERTIFIABLE" belongs to the previous contract and a receipt that
    # carries it is NOT evidence of this one.
    receipt = read_receipt(receipt_path)
    scenario_status = receipt.get("SCENARIO_STATUS", "NOT_CERTIFIABLE")
    closure = receipt.get("CLOSURE", "UNCONFIRMED")
    completeness = receipt.get("RECEIPT_COMPLETENESS", "INCOMPLETE")
    receipt_accreditation = receipt.get("ACCREDITATION", "FAILED")
    containment_evidence_certifiable = receipt.get("CONTAINMENT_EVIDENCE_CERTIFIABLE", "NO")
    positive_acceptance = receipt.get("POSITIVE_ACCEPTANCE", "NO")
    # The RC contracted for THIS scenario. The DECLARATION of the runner is
    # the authority; the receipt has to carry the very same declaration, so
    # a receipt produced against a different expectation is rejected instead
    # of being read as a mismatch of the scenario.
    receipt_expected_scenario_rc = receipt.get("EXPECTED_SCENARIO_RC", "")
    expected_scenario_rc = expected_scenario_rc
    product_cleanup = receipt.get("PRODUCT_CLEANUP_RESULT", "UNKNOWN")
    product_cleanup_observed = receipt.get(
        "PRODUCT_CLEANUP_OBSERVED_BEFORE_DEFENSIVE_CLEANUP", "NO"
    )
    legacy_certifiable = "CERTIFIABLE" in receipt
    ambiguous_receipt = receipt.get(AMBIGUOUS_RECEIPT_KEY) == "YES"
    launcher_wait_completed = receipt.get("LAUNCHER_WAIT_COMPLETED", "NO")
    # The CLOSURE has THREE independent links and all of them are required:
    # the outer wait over the direct `unshare` child, its RC 0 and the
    # OBSERVED effective termination of the private PID 1. A signal that was
    # merely SENT is not an observed termination, and a launcher that was
    # waited for but returned a non-zero RC did not close cleanly. A receipt
    # that carries "the signal was sent, and then it ended" does NOT certify
    # the closure.
    launcher_rc = receipt.get("LAUNCHER_RC", "")
    pid1_completion_observed = receipt.get("PID1_COMPLETION_OBSERVED", "")
    private_ns = receipt.get("PID_NAMESPACE", "") or None
    # The RAW exit code of the suite (the value that the shell observed) and
    # the NORMALISED one (the convention of the signals) are two different
    # facts and both of them are published: the normalised one is what the
    # contract compares, and the raw one is the evidence it came from.
    suite_rc_raw = receipt.get("SCENARIO_RC", "")
    suite_rc = exit_code_of(suite_rc_raw)
    # The OBSERVED termination state is a third fact, apart from the exit
    # code: a timeout of the scenario and a termination by SIGKILL are two
    # observations and neither one substitutes the other.
    suite_termination_state = termination_state_of(suite_rc)
    suite_termination_observable = suite_rc is not None
    # The exit status that THIS supervisor observed for the launcher is kept
    # apart from the LAUNCHER_RC that the receipt declares: the first one is
    # the observation, the second one is the link of the contract.
    launcher_observed_returncode = launcher.returncode
    if scenario_status == "TIMEOUT":
        timed_out = True

    # The receipt must be the one of THIS invocation: the pointer published by
    # the entry (--receipt-out), never a receipt found by enumerating the
    # directory of receipts. Its identity has to match the directory that
    # contains it.
    receipt_identity_ok = bool(
        receipt_path
        and receipt.get("IDENTIFIER", "")
        and receipt.get("IDENTIFIER", "") == os.path.basename(os.path.dirname(receipt_path))
        and receipt.get("RECEIPT_PATH", "") == receipt_path
    )
    step(
        "recibo",
        receipt_identity_ok and not ambiguous_receipt,
        "recibo=%s identidad=%s ambiguo=%s" % (receipt_path or "<ausente>", receipt_identity_ok, ambiguous_receipt),
    )

    # The semantics of the contract are verified HERE, not taken on trust:
    #
    #   * the evidence of the CONTAINMENT certifies that the boundary was
    #     accredited and that the contained environment was waited for. It
    #     does NOT imply that the scenario succeeded nor that the product
    #     cleaned up.
    #   * the POSITIVE ACCEPTANCE requires, in addition, the expected RC of
    #     the scenario and PRODUCT_CLEANUP_RESULT=PASS observed BEFORE the
    #     defensive cleanup. A consumer that certifies "zero survivors"
    #     cannot accept the containment evidence alone.
    scenario_rc_matches_expected = (
        expected_scenario_rc != ""
        and expected_scenario_rc != "NONE"
        and receipt_expected_scenario_rc == expected_scenario_rc
        and receipt.get("SCENARIO_RC", "") == expected_scenario_rc
    )
    product_cleanup_ok = product_cleanup == "PASS" and product_cleanup_observed == "YES"
    containment_evidence_ok = (
        not legacy_certifiable
        and not ambiguous_receipt
        and receipt_identity_ok
        and receipt_accreditation == "PASS"
        and completeness == "COMPLETE"
        and closure == "CONFIRMED"
        and launcher_wait_completed == "YES"
        and launcher_rc == "0"
        and pid1_completion_observed == "PASS"
        and containment_evidence_certifiable == "YES"
    )
    positive_acceptance_ok = (
        containment_evidence_ok
        and scenario_rc_matches_expected
        and product_cleanup_ok
        and positive_acceptance == "YES"
    )
    # ---------------------------------------------------------------------------
    # The verdict of THIS supervisor about its OWN cleanup (the CONTAINMENT)
    # is INDEPENDENT from the verdict about the PRODUCT (the positive
    # acceptance). The two results are kept apart on purpose:
    #
    #   * the closure of the arnes never turns a failure of the product into
    #     a success: the positive acceptance above still requires the product's
    #     cleanup to have been OBSERVED as PASS;
    #   * a scenario that injects a fault (whose product cleanup may be
    #     impossible to observe, because the process that had to declare it is
    #     killed by the bounded close) does NOT make the closure of the
    #     containment unaccredited: the facts that accredit it are the
    #     receipt's accreditation, its completeness and its confirmed closure,
    #     the absence of survivors of the private namespace, the absence of
    #     members of the own process group and the removal of the synthetic
    #     root.
    #
    # The verdict of the entry (CONTAINMENT_EVIDENCE_CERTIFIABLE) additionally
    # requires the DEFENSIVE cleanup of the inner entry, which cannot run when
    # the bounded close has to eliminate the scenario: that is a property of
    # the inner invocation, not of the closure of this one.
    # ---------------------------------------------------------------------------

    step(
        "suite",
        suite_rc == 0 and not timed_out,
        "rc=%s estado=%s timeout=%s" % (suite_rc, scenario_status, timed_out),
    )

    # ---------------------------------------------------------------------------
    # The declaration of the cleanup of the PRODUCT of THIS invocation.
    #
    # The supervisor is the outermost process of the batch in this namespace:
    # the launcher it created has already been waited for and reaped, and the
    # product itself ran in the INNER namespace, where the suite declared its
    # own cleanup over the inner private /proc and that declaration reached
    # the receipt of the inner invocation.
    #
    # The declaration combines two INDEPENDENT observations:
    #   * the OUTER one: over the private /proc of THIS namespace, no live
    #     process of the batch survives (the criterion of the case CLEAN-1);
    #   * the INNER one: the receipt of the inner invocation declares the
    #     cleanup of the product as PASS and observed before its defensive
    #     cleanup.
    #
    # If any of them cannot be observed the result is UNKNOWN. It is NEVER
    # turned into a PASS because the harness closed correctly: the closure of
    # the arnes and the cleanup of the product are two independent results,
    # and an invocation whose product cleanup could not be observed can never
    # be a positive acceptance.
    # ---------------------------------------------------------------------------
    outer_cleanup_value, outer_cleanup_survivors = observe_batch_cleanup(root, os.getpid())
    if product_cleanup == "FAIL" or outer_cleanup_value == "FAIL":
        declared_product_cleanup = "FAIL"
    elif product_cleanup != "PASS" or outer_cleanup_value != "PASS":
        declared_product_cleanup = "UNKNOWN"
    else:
        declared_product_cleanup = "PASS"
    marker_published = write_product_cleanup_marker(
        os.environ.get("FORGE_PRODUCT_CLEANUP_RESULT_FILE", ""),
        declared_product_cleanup,
    )
    if not marker_published:
        declared_product_cleanup = "UNKNOWN"
    # The very same declaration is published in the evidence of the scenario,
    # so a caller that chains several scenarios can AGGREGATE the
    # declarations instead of assuming a single one.
    try:
        with open(
            os.path.join(os.path.dirname(report_path), "product-cleanup.result"),
            "w",
            encoding="utf-8",
        ) as stream:
            stream.write(declared_product_cleanup + "\n")
    except OSError as exc:
        print("no se pudo publicar la declaracion en la evidencia: %s" % exc)
    step(
        "limpieza_producto",
        declared_product_cleanup == "PASS",
        "declarada=%s observacion_exterior=%s supervivientes_exteriores=%s "
        "recibo_interior=%s marcador_publicado=%s"
        % (
            declared_product_cleanup,
            outer_cleanup_value,
            outer_cleanup_survivors,
            product_cleanup,
            marker_published,
        ),
    )

    # There is NO sweep of the host: the absence of survivors of the private
    # namespace is a CONSEQUENCE of the closure of that namespace (the kernel
    # tears it down when its PID 1 exits), and the absence of members of the
    # own process group is a consequence of the launcher having been waited
    # for and reaped.
    #
    # That consequence is OBSERVED, never declared: the survivors, the
    # members and the init of the namespace are read from the PRIVATE /proc
    # of this frontier, after the launcher was waited for and reaped. A
    # value that could not be observed is NOT_VERIFIABLE and it is never
    # published as a verified absence.
    aftermath = observe_containment_aftermath(private_ns, launcher_pgid)
    survivors = aftermath["survivors"]
    members = aftermath["members"]
    init_alive = aftermath["init_alive"]
    init_gone = aftermath["init_gone"]
    aftermath_state = aftermath["state"]
    survivors_absence_verified = (
        True if aftermath_state == "COMPLETE" and survivors == [] else
        (False if survivors else None)
    )
    members_absence_verified = (
        True if aftermath_state == "COMPLETE" and members == [] else
        (False if members else None)
    )
    init_absence_verified = (
        True if aftermath_state == "COMPLETE" and init_gone is True else
        (False if init_alive else None)
    )
    root_present = os.path.exists(root)
    if root_present:
        shutil.rmtree(root, ignore_errors=True)
        root_present = os.path.exists(root)
    # A consumer that certifies "zero own survivors" cannot accept the
    # evidence of the containment alone: it also checks the expected RC of
    # the scenario and PRODUCT_CLEANUP_RESULT=PASS observed before the
    # defensive cleanup. The result of the PRODUCT stays a verdict of its
    # own: the correct closure of the harness never turns a failure of the
    # product into a success.
    #
    # The verdict of THIS supervisor about its own cleanup is the CONTAINMENT
    # verdict (containment_ok), which is independent from the verdict about
    # the product (positive_acceptance_ok). Both are published in the report.
    #
    # The verdict of the CLOSURE is conditioned on ALL of its independent
    # links, and not only on the declaration that the closure happened:
    #
    #   * LAUNCHER_WAIT_COMPLETED=YES  the launcher was waited for;
    #   * LAUNCHER_RC=0                it returned a clean status;
    #   * PID1_COMPLETION_OBSERVED=PASS the effective termination of the
    #                                    private PID 1 was OBSERVED;
    #   * CLOSURE=CONFIRMED            the receipt declares the closure.
    #
    # A receipt that declares the closure but that does not carry the other
    # three links does NOT certify a closure: the declaration alone is not
    # the evidence.
    #
    # The verdict of the CONTAINMENT is ALSO conditioned on the OBSERVED
    # absence of the leftovers of the batch, and not only on the links of the
    # receipt:
    #
    #   * aftermath_observation_state=COMPLETE the observation of the
    #                                    aftermath over the private /proc was
    #                                    COMPLETE (a partial observation does
    #                                    not certify anything);
    #   * survivors_absence_verified=True  the absence of survivors of the
    #                                    private namespace was VERIFIED;
    #   * members_absence_verified=True   the absence of members of the own
    #                                    process group was VERIFIED;
    #   * init_absence_verified=True       the disappearance of the private
    #                                    PID 1 was VERIFIED.
    #
    # The three flags are EXPLICITLY TRUE: they distinguish "the absence was
    # VERIFIED" from "the absence was DISPROVED" and from "the absence could
    # NOT be observed" (None). A verdict that accepted a None (or that
    # ignored the state of the observation) certified a containment whose
    # zero-survivors claim had never been observed.
    closure_links_ok = (
        launcher_wait_completed == "YES"
        and launcher_rc == "0"
        and pid1_completion_observed == "PASS"
        and closure == "CONFIRMED"
    )
    absence_verified_ok = (
        aftermath_state == "COMPLETE"
        and survivors_absence_verified is True
        and members_absence_verified is True
        and init_absence_verified is True
    )
    containment_ok = (
        closure_links_ok
        and receipt_accreditation == "PASS"
        and completeness == "COMPLETE"
        and receipt_identity_ok
        and not ambiguous_receipt
        and not root_present
        and absence_verified_ok
    )
    cleanup_ok = containment_ok
    step(
        "limpieza",
        cleanup_ok,
        "cierre=%s enlaces_del_cierre=%s acreditacion=%s completitud=%s "
        "evidencia_certificable=%s contencion_acreditada=%s aceptacion_positiva=%s "
        "(declarada=%s verificada=%s) rc_escenario=%s (crudo=%s) estado_terminacion=%s "
        "rc_esperado=%s limpieza_del_producto=%s supervivientes_en_el_ns=%s "
        "miembros_del_grupo=%s observacion=%s init_vivo=%s init_desaparecido=%s "
        "raiz_privada_presente=%s ausencias_verificadas=%s "
        "(el namespace privado se cierra con su PID 1: "
        "no hay barrido del host; la contencion acreditada y la aceptacion positiva "
        "son dos resultados independientes)"
        % (
            closure,
            closure_links_ok,
            receipt_accreditation,
            completeness,
            containment_evidence_certifiable,
            containment_ok,
            positive_acceptance_ok,
            positive_acceptance,
            positive_acceptance_ok,
            suite_rc,
            suite_rc_raw,
            suite_termination_state,
            expected_scenario_rc,
            product_cleanup,
            survivors,
            members,
            aftermath_state,
            init_alive,
            init_gone,
            root_present,
            absence_verified_ok,
        ),
    )

    report = {}
    if os.path.isfile(report_path):
        try:
            with open(report_path, "r", encoding="utf-8") as stream:
                report = json.load(stream)
        except (OSError, ValueError):
            report = {}
    report["cleanup"] = {
        "supervisor_pid": os.getpid(),
        "launcher_host_pid": launcher.pid,
        "namespace_init_host_pid": None,
        "private_pid_namespace": private_ns,
        "host_pid_namespace": host_ns_pid,
        "suite_returncode": suite_rc,
        "suite_returncode_raw": suite_rc_raw,
        "suite_termination_state": suite_termination_state,
        "suite_termination_observable": suite_termination_observable,
        "launcher_returncode": launcher_rc,
        "launcher_observed_returncode": launcher_observed_returncode,
        "launcher_process_group": launcher_pgid,
        "launcher_process_group_source": launcher_pgid_source,
        "timed_out": timed_out,
        "watchdog_operational": watchdog_ok,
        "watchdog_detail": watchdog_detail,
        "authorization_granted": authorized,
        "authorization_reason": auth_reason,
        "cleanup_actions": cleanup_actions,
        "namespace_init_alive_after": init_alive,
        "namespace_init_gone_after": init_gone,
        "namespace_init_observed_pid": aftermath["init_pid"],
        "survivors_in_private_namespace": survivors,
        "members_of_own_process_group": members,
        # The state of the OBSERVATION of the aftermath. An absence that was
        # not observed is not a verified absence: the three flags below say
        # whether each absence was VERIFIED, was DISPROVED or is simply NOT
        # VERIFIABLE.
        "aftermath_observation_state": aftermath_state,
        "aftermath_observation_detail": aftermath["detail"],
        "survivors_absence_verified": survivors_absence_verified,
        "members_absence_verified": members_absence_verified,
        "init_absence_verified": init_absence_verified,
        "absence_verified_ok": absence_verified_ok,
        "closure_links_ok": closure_links_ok,
        "synthetic_root": root,
        "synthetic_root_present_after": root_present,
        # "ok" is the verdict of THIS supervisor about its OWN cleanup (the
        # containment). The verdict about the product is published apart, in
        # "product_cleanup_declared" and "positive_acceptance_verified": the
        # two results are independent and neither one hides the other.
        "ok": cleanup_ok,
        "containment_ok": containment_ok,
        "positive_acceptance_verified": positive_acceptance_ok,
        "expected_scenario_rc": expected_scenario_rc,
        "receipt_path": receipt_path,
        "receipt_scenario_status": scenario_status,
        "receipt_closure": closure,
        "receipt_completeness": completeness,
        "receipt_containment_evidence_certifiable": containment_evidence_certifiable,
        "receipt_positive_acceptance": positive_acceptance,
        "receipt_positive_acceptance_verified": positive_acceptance_ok,
        "receipt_expected_scenario_rc": expected_scenario_rc,
        "receipt_scenario_rc_matches_expected": scenario_rc_matches_expected,
        "receipt_product_cleanup": product_cleanup,
        "receipt_product_cleanup_observed_before_defensive_cleanup": (
            product_cleanup_observed
        ),
        "receipt_legacy_certifiable_key_present": legacy_certifiable,
        "receipt_containment_evidence_ok": containment_evidence_ok,
        "receipt_ambiguous": ambiguous_receipt,
        "receipt_identity_ok": receipt_identity_ok,
        "receipt_launcher_wait_completed": launcher_wait_completed,
        "product_cleanup_declared": declared_product_cleanup,
        "product_cleanup_declared_outer_observation": outer_cleanup_value,
        "product_cleanup_declared_outer_survivors": outer_cleanup_survivors,
        "product_cleanup_declared_inner_receipt": product_cleanup,
        "product_cleanup_marker_published": marker_published,
        "resources": [
            {
                "id": "watchdog-supervisor",
                "type": "external-watchdog-supervisor",
                "pid": os.getpid(),
                "root_path": root,
                "cleanup_method": "espera del lanzador y verificacion exterior; no senala nada del host; termina al salir tras escribir el informe",
                "exits_after_report": True,
            },
            {
                "id": "pid-namespace-launcher",
                "type": "containment-entry-launcher",
                "root_path": root,
                "cleanup_method": "reaped by wait() after the contained environment was closed",
                "verified_absent_after_cleanup": launcher.poll() is not None,
            },
            {
                "id": "namespace-init-suite",
                "type": "own-synthetic-suite",
                "root_path": root,
                "cleanup_method": "cadena de cierre propia de la entrada de contencion: el namespace PID privado se destruye con su init y el lanzador se recoge con wait(); nunca depende del codigo probado",
                "verified_absent_after_cleanup": init_gone,
            },
            {
                "id": "synthetic-root",
                "type": "temporary-private-directory",
                "path": root,
                "cleanup_method": "shutil.rmtree on the exact batch-created 0700 path",
                "verified_absent_after_cleanup": not root_present,
            },
        ],
    }
    report["supervisor"] = evidence
    report_write_error = None
    try:
        with open(report_path, "w", encoding="utf-8") as stream:
            json.dump(report, stream, indent=2, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
    except OSError as exc:
        report_write_error = "no se pudo completar el informe en %s: %s" % (report_path, exc)
        print("FALLO: %s" % report_write_error)
        # Best effort: leave a minimal, explicit record of the incident so
        # the missing evidence is never silently invisible.
        try:
            with open(report_path + ".error", "w", encoding="utf-8") as stream:
                json.dump(
                    {
                        "batch": "forge-v2-followups Step 2.2",
                        "error": report_write_error,
                        "supervisor": evidence,
                        "cleanup": report.get("cleanup", {}),
                    },
                    stream,
                    indent=2,
                    ensure_ascii=False,
                    sort_keys=True,
                )
                stream.write("\n")
        except OSError:
            pass

    if report_write_error:
        print(
            "BLOCKED: el informe no se ha podido completar; la evidencia de no-supervivientes "
            "no queda disponible"
        )
        return 8
    if not watchdog_ok:
        print(
            "BLOCKED: el cierre acotado no se considero operativo (%s); la barra de autorizacion "
            "no se libero y la suite aborta con RC no cero (timeout=%s, suite_rc=%s)"
            % (watchdog_detail, timed_out, suite_rc)
        )
        return 6
    if not authorized:
        print(
            "BLOCKED: la barra de autorizacion no se libero: %s (timeout=%s)" % (auth_reason, timed_out)
        )
        return 7
    if not cleanup_ok:
        print("BLOCKED: la limpieza no pudo acreditarse; quedan recursos propios")
        return 4
    if timed_out:
        print("FALLO: la suite supero el presupuesto de tiempo")
        return 5
    return suite_rc


# ---------------------------------------------------------------------------
def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", required=True, choices=["supervisor", "suite"])
    parser.add_argument("--repo-root", default=os.getcwd())
    parser.add_argument("--external-root", default=DEFAULT_EXTERNAL_ROOT)
    parser.add_argument("--root", default="")
    parser.add_argument("--report-path", default=os.path.join(BATCH_ROOT, "safety-results.json"))
    parser.add_argument(
        "--auth-fd",
        type=int,
        default=-1,
        help="file descriptor of the authorization channel; the suite refuses to "
        "run any sensitive case until the supervisor releases it",
    )
    parser.add_argument("--real-db", default="")
    parser.add_argument("--timeout", type=float, default=300.0)
    args = parser.parse_args(argv)
    if args.role == "supervisor":
        return role_supervisor(args)
    return role_suite(args)


if __name__ == "__main__":
    sys.exit(main())
