#!/usr/bin/env python3
"""tests/forge_v2_registry_parity.py — the DETECTOR of the PARENTAL relation
of the identity registry of the V2 safety bank.

The registry of the bank (`tests/forge_v2_safety_scenarios.sh`, the guard
wrapper of the supervisor) locates the children of the supervisor through the
`children` file that the kernel publishes for it, and it VERIFIES their
parental relation before admitting them:

    if info["ppid"] == supervisor_pid:
        registry["children"][pid] = {...}

That verification is the barrier that keeps a RECYCLED PID out of the
registry: without it, a PID that the kernel reused between the reading of the
children file and the reading of the stat would be admitted as "our child",
and the teardown of the bank would tear down the process group of somebody
else's process.

This detector proves that the property is REAL and that it is DETECTABLE: it
loads the guard program FROM THE SOURCE of the scenario runner (it never
imports the prohibited entrypoints and it never runs a scenario of the bank)
and it exercises its own admission rule with two kinds of evidence:

  1. INJECTED. The `children_of` and `stat_fields` helpers of the guard are
     replaced by deterministic doubles: the children file announces a PID
     whose parental relation is NOT the supervisor. The registry MUST NOT
     admit it. This is the check that a mutant which neutralises the
     parental verification makes FAIL.

  2. REAL. A real supervisor with a real child is used: the child MUST be
     admitted (the verification does not break the normal path) and a real
     process that is NOT a child of the supervisor MUST NOT be admitted.

The scenario runner under test can be OVERRIDDEN with the environment
variable FORGE_TEST_V2_SCENARIOS, so that the sensitivity harness can point
this detector at a MUTATED COPY that lives OUTSIDE the repository. The
repository itself is never modified by a mutation.

The detector reads the /proc of the processes it creates itself and it never
enumerates the /proc of the host, never reads the command line of anything
and never signals anything that it did not create.

THE BOUNDARY IS ACCREDITED BEFORE ANYTHING ELSE
------------------------------------------------

This detector LOADS a program (the guard of the runner) and it CREATES
processes. Neither may happen outside the frontier: the guard of the runner
is code of the bank and the processes that this detector creates are
resources of the bank. So the FIRST thing that `main()` does is to PROVE
that this process runs inside an ACCREDITED boundary: the namespace that the
entry published, the PID 1 of that namespace, the receipt of the
invocation and its accreditation. When the boundary is not accredited
NOTHING is executed and NO process is created, and the detector says so.

EVERY process that the detector creates is TERMINATED before it returns, and
the end is WAITED FOR and then VERIFIED: the supervisor leads its own process
group, the group is terminated as a whole (the grandchild that the
supervisor spawns belongs to it) and the detector checks that the group has
no members left. The identities of the processes it created are published in
the file that FORGE_REGISTRY_PARITY_IDENTITIES names, BEFORE the cleanup, so
that an external verifier can check that none of them survived.

Usage: python3 tests/forge_v2_registry_parity.py [--scenarios <runner>]
"""

import contextlib
import io
import os
import signal
import subprocess
import sys
import time

PASSED = 0
FAILED = 0

# The PID that the plan protects. It is never signalled and it is never
# read: the exclusion is IMMUTABLE and it is applied to the processes that
# this detector creates.
DEFAULT_PROTECTED_PID = "530393"

# The boundary of the containment, as the entry publishes it.
NAMESPACE_VARIABLE = "FORGE_CONTAINED_RUN_PID_NAMESPACE"
RECEIPT_VARIABLE = "FORGE_CONTAINED_RUN_RECEIPT"
RUN_ID_VARIABLE = "FORGE_CONTAINED_RUN_ID"
ACCREDITATION_VARIABLE = "FORGE_CONTAINED_RUN_ACCREDITATION_FILE"

# The root of the receipts is NOT a path of a machine.
#
# The detector runs INSIDE the containment of the invocation that published
# its receipt, and that receipt is the one the entry published in the "run-*"
# directory that it created. The criterion is therefore STRUCTURAL: the
# receipt of an invocation is an ABSOLUTE path whose last component is
# "receipt.txt" and whose parent directory is one of those "run-*" ones.
#
# A consumer MAY declare the root explicitly (FORGE_CONTAINED_RECEIPT_ROOT);
# when it does, the declared root is ALSO required. The declaration is
# optional on purpose: the detector has to work on any machine, including a
# CI runner where no directory of a previous qualification exists.
RECEIPT_ROOT = os.environ.get("FORGE_CONTAINED_RECEIPT_ROOT", "").rstrip("/")
RECEIPT_RUN_DIR_PREFIX = "run-"

# The RC of a detector that does NOT run because the boundary is not
# accredited: the same code that the gate of admission uses.
EXIT_NOT_ACREDITED = 78


def readlink(path):
    """The target of a symbolic link, or None."""
    try:
        return os.readlink(path)
    except OSError:
        return None


def accredited_boundary():
    """The proof that this process runs inside an ACCREDITED boundary.

    It returns (namespace, None) when the boundary is accredited and
    (None, reason) when it is not. NOTHING is executed and NO process is
    created before this proof succeeds.
    """
    namespace = os.environ.get(NAMESPACE_VARIABLE, "")
    if not namespace:
        return None, "no hay frontera acreditada (%s ausente)" % NAMESPACE_VARIABLE

    own = readlink("/proc/self/ns/pid")
    if own is None:
        return None, "no se pudo leer el namespace PID propio"
    if own != namespace:
        return None, (
            "el namespace PID propio (%s) no es el namespace acreditado (%s)"
            % (own, namespace)
        )
    if readlink("/proc/1/ns/pid") != namespace:
        return None, "el PID 1 del namespace no es el namespace acreditado"

    receipt = os.environ.get(RECEIPT_VARIABLE, "")
    run_id = os.environ.get(RUN_ID_VARIABLE, "")
    if not receipt or not run_id:
        return None, "falta el recibo o el identificador de la invocacion"
    # The receipt of THIS invocation: an absolute path, published by the
    # entry in the "run-*" directory that it created. The root is derived
    # from the receipt itself, so the criterion does not depend on a path of
    # a machine (a declared root, when there is one, is ALSO required).
    receipt_dir = os.path.dirname(receipt)
    if (
        not receipt.startswith("/")
        or not receipt.endswith("/receipt.txt")
        or not os.path.basename(receipt_dir).startswith(RECEIPT_RUN_DIR_PREFIX)
    ):
        return None, "la ruta del recibo no pertenece a una invocacion autorizada"
    if RECEIPT_ROOT and not receipt.startswith(RECEIPT_ROOT + "/" + RECEIPT_RUN_DIR_PREFIX):
        return None, "la ruta del recibo no pertenece a una invocacion autorizada"
    if os.path.basename(receipt_dir) != run_id:
        return None, "el identificador del recibo no coincide con el directorio"
    if not os.path.isfile(receipt):
        return None, "el recibo de la invocacion no existe"

    accreditation = os.environ.get(ACCREDITATION_VARIABLE, "")
    if not accreditation or not os.path.isfile(accreditation):
        return None, "falta la acreditacion de la invocacion"
    try:
        with open(accreditation, "r", encoding="ascii", errors="replace") as handle:
            state = handle.read().strip()
    except OSError:
        return None, "la acreditacion de la invocacion no se pudo leer"
    if state != "PASS":
        return None, "la frontera de esta invocacion NO esta acreditada (%s)" % state

    return namespace, None


def terminate_own(processes):
    """Terminate, BY THEIR IDENTITY, the processes that this check created.

    It is the SAFETY NET of the cleanup: a check whose cleanup failed must
    not leave its own processes alive. The protected PID is never among
    them: the exclusion is immutable and it is applied here too.
    """
    for process in processes:
        pid = getattr(process, "pid", None)
        if pid is None or str(pid) == DEFAULT_PROTECTED_PID:
            continue
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            process.wait(timeout=5)
        except Exception:  # pragma: no cover - the cleanup of our own children
            pass


def pass_(message):
    global PASSED
    PASSED += 1
    print("  PASS: %s" % message)


def fail(message):
    global FAILED
    FAILED += 1
    print("  FAIL: %s" % message, file=sys.stderr)


def ticks_of(pid):
    """The starttime of /proc/<pid>/stat, or None."""
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii", errors="replace") as handle:
            data = handle.read()
    except OSError:
        return None
    tail = data.rsplit(")", 1)[-1].split()
    if len(tail) < 20:
        return None
    return tail[19]


def state_of(pid):
    """The state field of /proc/<pid>/stat, or None."""
    try:
        with open("/proc/%d/stat" % pid, "r", encoding="ascii", errors="replace") as handle:
            data = handle.read()
    except OSError:
        return None
    tail = data.rsplit(")", 1)[-1].split()
    if not tail:
        return None
    return tail[0]


def identity_alive(pid, ticks):
    """True when the process with that identity is still ALIVE.

    A number that was recycled is NOT that process any more, and a zombie is
    a corpse that consumes nothing: neither of them is a survivor.
    """
    current = ticks_of(pid)
    if current is None:
        return False
    if current != ticks:
        return False
    return state_of(pid) != "Z"


def own_children(pid):
    """The direct children of <pid>, from the file the kernel publishes.

    It is used ONLY on the processes that this detector created itself: it
    is not a discovery mechanism and it never enumerates the /proc of the
    host.
    """
    try:
        with open("/proc/%d/task/%d/children" % (pid, pid), "r", encoding="ascii") as handle:
            data = handle.read()
    except OSError:
        return []
    children = []
    for part in data.split():
        if part.isdigit():
            children.append(int(part))
    return children


def own_tree(pid):
    """<pid> and every descendant of it, as a list of PIDs."""
    found = []
    pending = [pid]
    while pending:
        current = pending.pop(0)
        if current in found:
            continue
        found.append(current)
        pending.extend(own_children(current))
    return found


def publish_identity(pid, path):
    """Publish the identity of an OWN process, so that a verifier can check
    afterwards that it is gone. The publication happens BEFORE the cleanup:
    a cleanup that fails must not hide the processes it failed to terminate.
    """
    if not path:
        return
    ticks = ticks_of(pid)
    if ticks is None:
        return
    try:
        with open(path, "a", encoding="ascii") as handle:
            handle.write("%d %s\n" % (pid, ticks))
            handle.flush()
    except OSError:
        pass


def group_has_members(pgid):
    """True when the process group still has at least one member."""
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def terminate_process_group(pgid, timeout=10.0):
    """Terminate EVERY member of a process group and wait for its end.

    The group is the unit of termination ON PURPOSE: the descendants that
    are NOT the direct child of this process (the grandchild that the
    supervisor spawns) belong to the group too, and a cleanup that only
    killed the direct children would leave them alive.

    Returns True when the group has NO members left.
    """
    if pgid is None or pgid <= 1:
        return True
    for signame, budget in (("TERM", timeout), ("KILL", 2.0)):
        try:
            os.killpg(pgid, getattr(signal, "SIG" + signame))
        except (ProcessLookupError, PermissionError, OSError):
            break
        deadline = time.monotonic() + budget
        while time.monotonic() < deadline:
            if not group_has_members(pgid):
                return True
            time.sleep(0.05)
    return not group_has_members(pgid)


def extract_guard_program(path):
    """The Python source of the guard program of the scenario runner.

    The guard program is the heredoc that the runner feeds to the interpreter
    of the wrapper. It is extracted BY TEXT: the file is never executed and
    nothing of it is imported.
    """
    try:
        with open(path, "r", encoding="utf-8") as stream:
            lines = stream.read().splitlines()
    except OSError as exc:
        return None, "no se pudo leer el runner de escenarios (%s): %s" % (path, exc)

    blocks = []
    index = 0
    while index < len(lines):
        if "<<'PY'" in lines[index]:
            start = index + 1
            end = start
            while end < len(lines) and lines[end].rstrip() != "PY":
                end += 1
            if end < len(lines):
                blocks.append("\n".join(lines[start:end]))
                index = end + 1
                continue
        index += 1

    for block in blocks:
        if "def refresh_registry" in block and "def children_of" in block:
            return block, None
    return None, "el runner de escenarios no contiene el programa del guard (refresh_registry)"


def load_guard_namespace(program):
    """Load the guard program in a namespace and return it.

    The program is executed with a harmless command (`/bin/true`), so it
    finishes immediately and it never launches a scenario of the bank. The
    SystemExit it raises at the end is expected and it is caught here.
    """
    environment = dict(os.environ)
    environment["FORGE_V2_SCENARIO_GUARD"] = "5"
    environment.pop("FORGE_GUARD_IDENTITY", None)
    environment.pop("FORGE_GUARD_EVIDENCE", None)

    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(environment)
    namespace = {"__name__": "__forge_v2_registry_parity__"}
    saved_argv = list(sys.argv)
    sys.argv = ["forge-v2-guard", "/bin/true"]
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            try:
                exec(compile(program, "<forge-v2-guard>", "exec"), namespace)  # noqa: S102
            except SystemExit:
                pass
    finally:
        os.environ.clear()
        os.environ.update(saved)
        sys.argv = saved_argv
    return namespace


def check_injected_admission(namespace, path):
    """A PID whose parental relation is NOT the supervisor is NOT admitted."""
    if "refresh_registry" not in namespace:
        fail("el programa del guard no define refresh_registry (%s)" % path)
        return
    if "children_of" not in namespace or "stat_fields" not in namespace:
        fail("el programa del guard no define children_of/stat_fields (%s)" % path)
        return

    supervisor_pid = 4242
    foreign_pid = 9999
    namespace["supervisor_pid"] = supervisor_pid
    namespace["registry"] = {
        "supervisor": {"pid": supervisor_pid, "ticks": "111", "pgrp": supervisor_pid},
        "children": {},
    }
    namespace["last_refresh"] = [0.0]

    # The children file of the kernel announces a PID whose parental relation
    # is NOT the supervisor: that is the recycled PID of the incident.
    namespace["children_of"] = lambda pid: [foreign_pid]

    def fake_stat_fields(pid):
        if pid == foreign_pid:
            return {
                "state": "S",
                "ppid": 7777,
                "pgrp": 9999,
                "session": 9999,
                "ticks": "12345",
            }
        return {
            "state": "S",
            "ppid": supervisor_pid,
            "pgrp": supervisor_pid,
            "session": supervisor_pid,
            "ticks": "111",
        }

    namespace["stat_fields"] = fake_stat_fields
    namespace["refresh_registry"]()

    children = namespace["registry"]["children"]
    if foreign_pid in children:
        fail(
            "el registro ADMITE un PID cuya relacion parental NO es el supervisor (%s): "
            "un PID reciclado entraria en el registro y el teardown del banco "
            "destruiria el grupo de procesos de otro" % foreign_pid
        )
    else:
        pass_("el registro RECHAZA un PID cuya relacion parental NO es el supervisor")

    # The control: a PID whose parental relation IS the supervisor IS
    # admitted. A verification that rejected everything would be as wrong as
    # a verification that accepted everything.
    namespace["registry"] = {
        "supervisor": {"pid": supervisor_pid, "ticks": "111", "pgrp": supervisor_pid},
        "children": {},
    }
    namespace["last_refresh"] = [0.0]
    namespace["children_of"] = lambda pid: [foreign_pid]
    namespace["stat_fields"] = fake_stat_fields
    namespace["refresh_registry"]()
    # The control uses a second PID whose parental relation IS the supervisor.
    own_pid = 8888
    namespace["children_of"] = lambda pid: [own_pid]

    def fake_stat_fields_own(pid):
        if pid == own_pid:
            return {
                "state": "S",
                "ppid": supervisor_pid,
                "pgrp": own_pid,
                "session": own_pid,
                "ticks": "22222",
            }
        return fake_stat_fields(pid)

    namespace["stat_fields"] = fake_stat_fields_own
    namespace["last_refresh"] = [0.0]
    namespace["refresh_registry"]()
    if own_pid in namespace["registry"]["children"]:
        pass_("el registro ADMITE un hijo real del supervisor: la verificacion no rompe la via normal")
    else:
        fail("el registro NO admite un hijo real del supervisor: la verificacion es demasiado estricta")


def check_real_admission(namespace, path, real_children_of, real_stat_fields):
    """With REAL processes, a real child is admitted and a foreign one is not."""
    if "refresh_registry" not in namespace:
        fail("el programa del guard no define refresh_registry (%s)" % path)
        return

    # The REAL helpers of the guard are restored: this check does not inject
    # anything, it observes the kernel.
    if real_children_of is None or real_stat_fields is None:
        fail("el programa del guard no define children_of/stat_fields (%s)" % path)
        return
    namespace["children_of"] = real_children_of
    namespace["stat_fields"] = real_stat_fields

    check_real_processes(namespace)


def check_real_processes(namespace, spawn=None):
    """The check with REAL processes, and the cleanup that protects them.

    The protection of the cleanup is established from the FIRST creation.
    The resources are declared BEFORE the first creation and the whole
    creation is INSIDE the protected block: a failure of a LATER creation
    (the second one, for instance) must not escape the protection and leave
    the processes that were already created alive until their own waits end.
    """
    if spawn is None:
        spawn = subprocess.Popen

    # The supervisor leads its OWN process group (start_new_session): the
    # group is what the cleanup terminates, and it covers the descendants
    # that are NOT the direct child of this process.
    supervisor = None
    foreign = None
    supervisor_group = None
    identities_path = identities_file_path(sys.argv)
    try:
        supervisor = spawn(
            [
                sys.executable,
                "-c",
                "import subprocess, sys, time\n"
                "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])\n"
                "time.sleep(30)\n",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            supervisor_group = os.getpgid(supervisor.pid)
        except OSError:
            # start_new_session makes the group of the supervisor its own
            # PID: the fallback is the number itself.
            supervisor_group = supervisor.pid
        foreign = spawn(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # The child of the supervisor is published by the kernel a moment
        # after the supervisor starts it.
        deadline = time.monotonic() + 10.0
        real_children = []
        while time.monotonic() < deadline:
            namespace["supervisor_pid"] = supervisor.pid
            namespace["registry"] = {
                "supervisor": {"pid": supervisor.pid, "ticks": None, "pgrp": None},
                "children": {},
            }
            namespace["last_refresh"] = [0.0]
            namespace["refresh_registry"]()
            real_children = list(namespace["registry"]["children"].keys())
            if real_children:
                break
            time.sleep(0.1)

        if not real_children:
            fail("no se localizo ningun hijo real del supervisor: la comprobacion no es concluyente")
            return
        pass_(
            "el registro localiza el hijo real del supervisor por el archivo children del kernel (%s)"
            % real_children
        )

        if foreign.pid in namespace["registry"]["children"]:
            fail(
                "el registro ADMITE un proceso que NO es hijo del supervisor (%s): "
                "el teardown del banco podria destruir el grupo de procesos de otro" % foreign.pid
            )
        else:
            pass_("el registro NO admite un proceso que no es hijo del supervisor")
    finally:
        # The identities of EVERY process that this check creates are
        # collected and published BEFORE the cleanup: a cleanup that fails
        # must not hide the processes that it failed to terminate. The tree
        # is read from the kernel's own children files, of the processes
        # that this check created (never from a global enumeration).
        #
        # The resources are handled ONE BY ONE: a creation that failed
        # leaves a resource that does not exist, and a cleanup that assumes
        # that every resource exists is a cleanup that does not run.
        created = []
        if supervisor is not None:
            created.extend(own_tree(supervisor.pid))
        if foreign is not None:
            created.append(foreign.pid)
        published = []
        for pid in created:
            ticks = ticks_of(pid)
            if ticks is None:
                continue
            published.append((pid, ticks))
            publish_identity(pid, identities_path)

        # EVERY process that this check created is terminated BEFORE the
        # check returns: the supervisor, the child it spawned and the
        # grandchild that the child spawned. Sending a signal is not the
        # same as confirming the end, so the end is WAITED FOR and then
        # VERIFIED.
        if supervisor_group is not None:
            terminate_process_group(supervisor_group)
        if supervisor is not None:
            try:
                supervisor.wait(timeout=10)
            except Exception:  # pragma: no cover - the cleanup of our own children
                pass
        if foreign is not None:
            try:
                foreign.kill()
                foreign.wait(timeout=10)
            except Exception:  # pragma: no cover - the cleanup of our own children
                pass

        # The VERIFICATION of the end: the processes of this check must be
        # GONE. A descendant that outlives the check would be a survivor of
        # this lot.
        survivors = [
            "%s(%s)" % (pid, ticks)
            for pid, ticks in published
            if identity_alive(pid, ticks)
        ]
        if survivors:
            fail(
                "quedan procesos PROPIOS vivos despues de la comprobacion: %s: "
                "la comprobacion debe terminar TODOS sus procesos antes de volver" % ", ".join(survivors)
            )
        else:
            pass_(
                "la comprobacion termino TODOS sus procesos propios (%s)" % ", ".join(
                    "%s" % pid for pid, _ticks in published
                )
            )


def check_partial_creation_is_cleaned_up(namespace):
    """A creation that FAILS must not leave ANY process of this check alive.

    The protection of the cleanup is established from the FIRST creation: a
    failure of a LATER creation must not escape that protection and leave
    the processes that were already created alive until their own waits end.
    """
    created = []
    real_popen = subprocess.Popen

    def failing_popen(argv, **kwargs):
        if created:
            # The SECOND creation FAILS and it creates NOTHING: a real
            # `Popen` that fails does not leave a process behind (it
            # reaps its own child when the execution fails).
            raise OSError("simulacion: fallo de la segunda creacion")
        process = real_popen(argv, **kwargs)
        created.append(process)
        return process

    raised = False
    try:
        check_real_processes(namespace, spawn=failing_popen)
    except OSError:
        raised = True

    if not raised:
        fail(
            "la creacion que falla no produjo el error inyectado: "
            "la comprobacion de la creacion parcial no es concluyente"
        )
        return

    survivors = []
    for process in created:
        ticks = ticks_of(process.pid)
        if ticks is None:
            continue
        if identity_alive(process.pid, ticks):
            survivors.append("%s(%s)" % (process.pid, ticks))
    if survivors:
        fail(
            "quedan procesos PROPIOS vivos tras una creacion que falla: %s: "
            "la proteccion de la limpieza debe empezar en la PRIMERA creacion"
            % ", ".join(survivors)
        )
        terminate_own(created)
    else:
        pass_(
            "la proteccion de la limpieza cubre una creacion que falla: "
            "no queda ningun proceso propio vivo"
        )


def scenarios_path(argv):
    """The runner under test: the argument wins over the variable."""
    for index, argument in enumerate(argv):
        if argument == "--scenarios" and index + 1 < len(argv):
            return argv[index + 1]
        if argument.startswith("--scenarios="):
            return argument.split("=", 1)[1]
    return os.environ.get(
        "FORGE_TEST_V2_SCENARIOS",
        os.path.join(
            os.path.dirname(os.path.abspath(__file__)),
            "forge_v2_safety_scenarios.sh",
        ),
    )


def result_file_path(argv):
    """The file where the RC of the detector is published, or None.

    The RC of the detector is the verdict of its battery. When it runs
    INSIDE the boundary, the RC of the entry is the RC of the CONTAINMENT
    and not the verdict of the detector: the verdict is published in this
    file so that the consumer of the detector reads the verdict and not the
    wrapper.
    """
    for index, argument in enumerate(argv):
        if argument == "--result-file" and index + 1 < len(argv):
            return argv[index + 1]
        if argument.startswith("--result-file="):
            return argument.split("=", 1)[1]
    return None


def identities_file_path(argv):
    """The file where the identities of the own processes are published.

    The argument wins over the variable: the environment of the scenario is
    rebuilt by the entry (`env -i`) and the variable does not cross that
    boundary.
    """
    for index, argument in enumerate(argv):
        if argument == "--identities" and index + 1 < len(argv):
            return argv[index + 1]
        if argument.startswith("--identities="):
            return argument.split("=", 1)[1]
    return os.environ.get("FORGE_REGISTRY_PARITY_IDENTITIES", "")


def publish_result(path, code):
    """Publish the RC of the detector in <path>."""
    if not path:
        return
    try:
        with open(path, "w", encoding="ascii") as handle:
            handle.write("%d\n" % code)
            handle.flush()
    except OSError:
        pass


def main():
    path = scenarios_path(sys.argv)
    result_file = result_file_path(sys.argv)
    code = run(path)
    publish_result(result_file, code)
    return code


def run(path):
    print("================================")
    print(" forge_v2_registry_parity.py")
    print("================================")
    print(" runner bajo prueba: %s" % path)

    # THE BOUNDARY IS ACCREDITED BEFORE ANYTHING ELSE. The detector loads
    # the program of the guard and it creates processes: neither may happen
    # outside the frontier. When the boundary is not accredited NOTHING is
    # executed and NO process is created.
    boundary, problem = accredited_boundary()
    if boundary is None:
        sys.stderr.write(
            "forge_v2_registry_parity: la frontera NO esta acreditada: %s: "
            "no se ejecuta el programa del guard y no se crea ningun proceso\n"
            % problem
        )
        print("")
        print(" Passed: %s" % PASSED)
        print(" FAIL: the boundary is not accredited", file=sys.stderr)
        return EXIT_NOT_ACREDITED

    program, problem = extract_guard_program(path)
    if program is None:
        fail(problem)
        print("")
        print(" Passed: %s" % PASSED)
        print(" FAIL: some tests failed", file=sys.stderr)
        return 1
    pass_("el programa del guard se extrajo del runner de escenarios (%s)" % path)

    namespace = load_guard_namespace(program)
    if "refresh_registry" not in namespace:
        fail("el programa del guard no se cargo: refresh_registry no esta definida")
        print("")
        print(" Passed: %s" % PASSED)
        print(" FAIL: some tests failed", file=sys.stderr)
        return 1

    # The REAL helpers of the guard are captured BEFORE any injection: the
    # check with real processes restores them.
    real_children_of = namespace.get("children_of")
    real_stat_fields = namespace.get("stat_fields")

    check_injected_admission(namespace, path)
    check_real_admission(namespace, path, real_children_of, real_stat_fields)
    check_partial_creation_is_cleaned_up(namespace)

    print("")
    print("================================")
    print(" Passed: %s" % PASSED)
    if FAILED:
        print(" FAIL: some tests failed", file=sys.stderr)
        return 1
    print(" ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
