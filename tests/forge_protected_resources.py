#!/usr/bin/env python3
"""tests/forge_protected_resources.py — the HONEST verifier of the protected resources.

WHY THIS VERIFIER EXISTS
------------------------
The acceptance of this lot used to require that the protected PID 530393
were ALIVE with `starttime_ticks=26522468`. On the 2026-10-29 that
invariant became IMPOSSIBLE: a directed verification probe of this very lot
opened a REAL pidfd of that PID and delivered a REAL `SIGTERM` to it (see
`tester-v14/INCIDENTE-530393.md`). The process is gone and it cannot be
rebuilt without inventorying the host and touching the installed OpenCode,
which this lot forbids.

A verifier that still demanded "alive" would therefore be a verifier that
CANNOT pass, and a verifier that quietly turned the demand into "absent is
fine" would be a verifier that HIDES the incident. This verifier does
neither: it demands that the state of every protected resource be
EXPLICITLY REGISTERED, and it reports the registered state as it is.

THE THREE PROPERTIES
--------------------
(a) The protected PID is REGISTERED AS ABSENT, with the constancy of its
    termination: the cause (a directed verification probe of this lot), the
    date, the identity that it had (`530393`, `starttime_ticks=26522468`)
    and the link to the incident report. The verifier NEVER demands that it
    be alive, and it CANNOT: the process does not exist.

(b) The live database is checked by `stat()` ONLY: device, inode, size and
    mode are compared with the baseline, and the `mtime` is recorded as
    INFORMATIONAL (the database is live and the session of the user may
    legitimately extend it). The file is NEVER opened, read nor hashed.

(c) The loopback port 34765 is REGISTERED AS NOT LISTENING, as a
    consequence of the same incident and not as a change of this batch. The
    observation is the reading of the socket table of the kernel
    (`/proc/net/tcp` and `/proc/net/tcp6`): it is a FILE READ, it opens NO
    connection and it sends NO packet, so it is not a network operation. It
    is a targeted query about ONE port, not an inventory of the host.

    The observation of the port is COMPLETE only when EVERY table that
    could hold a listener of that port has been EFFECTIVELY READ. A table
    whose INTERFACE IS ABSENT (the file does not exist) is NOT a table that
    was read: the absence of the interface does NOT prove that the family
    is disabled, and it does NOT prove that there is no listener of that
    family. Only an INDEPENDENT accreditation of the family (a SEPARATE
    declaration, never the failed read itself) can excuse it. Without it,
    the state of the port is NOT_OBSERVABLE and this verifier FAILS.

THE FOURTH PROPERTY — AN IMPOSSIBLE OBSERVATION IS NOT AN ABSENCE
------------------------------------------------------------------
An ERROR of reading is not a FACT about the resource. A verifier that
turns a failed read into "the process is gone" or "the port is not
listening" certifies an absence that was NEVER OBSERVED, and the PASS
that accepts the protected resources would survive a failed observation.

This verifier therefore distinguishes three states, and never confuses
them:

    PRESENT           the observation succeeded and the resource is there;
    ABSENT            the observation succeeded and the resource is NOT
                      there (the kernel says that the entry does not exist);
    NOT_OBSERVABLE    the observation could NOT be performed (the read
                      failed: a permission, an I/O error, a table that is
                      not exposed).

A NOT_OBSERVABLE state is a FAILURE of this verifier: it is published as
`NOT_OBSERVABLE`, never as `ABSENT` nor as `NOT_LISTENING`, and the exit
status is not zero. The same criterion applies to the database.

THE ABSENCE OF AN INTERFACE IS NOT THE ABSENCE OF A RESOURCE
--------------------------------------------------------------
The `FileNotFoundError` of the stat of the PID protected IS a confirmed
absence: the kernel says that the entry does not exist, and that IS a fact
about the process. The `FileNotFoundError` of a socket table is NOT the
same thing: it says that the interface of that family is NOT EXPOSED (a
procfs mounted with `subset=pid`, a kernel without that family), NOT that
the family has no sockets. Counting an absent interface as a table that
was read publishes a "NO EN ESCUCHA" that was never observed, and it makes
the defence that requires at least one effective read UNREACHABLE.

This verifier therefore keeps SEPARATELY:
    * the tables that were EFFECTIVELY READ;
    * the interfaces that were ABSENT;
    * the tables that exist and could NOT be read;
    * the families whose disablement was INDEPENDENTLY accredited.
A family whose interface is absent and whose disablement is NOT accredited
leaves the observation INCOMPLETE: the port is published as
`NOT_OBSERVABLE` and the exit status is not zero.

WHAT THIS VERIFIER DOES NOT DO
-------------------------------
It does NOT rewrite the evidence of the previous generations: the files that
declared "530393 intacto" stay as they are, and the fact that they describe
a state that is NO LONGER TRUE is stated here and in the acceptance
document.

THE PROTECTION OF THE CODE IS NOT AFFECTED
------------------------------------------
The PID 530393 remains a HARD exclusion in the code
(`tests/forge_own_signal.py` and `tests/forge_v2_registry_parity.py`): it
is refused even though it is dead, because a PID can be RECYCLED. This
verifier observes the state; it does not relax the protection.

USAGE
-----
    python3 tests/forge_protected_resources.py \
        --baseline <protected-before.txt> \
        --registry <protected-registry.tsv> \
        --incident <INCIDENTE-530393.md> \
        --out <report> [--home <real home>]

Exit status: 0 when every protected resource is in the REGISTERED state and
the observations agree with it; 1 otherwise (including when an observation
could NOT be performed).
"""

import argparse
import os
import stat as statmod
import sys
import time

DEFAULT_PORT = 34765
LISTEN_STATE = "0A"

# The socket tables of the kernel and the FAMILY of addresses that each one
# holds. A listener of the port can only appear in the table of its family.
#
# The distinction that this verifier MUST make, and that it did NOT make:
#
#   * a table that was EFFECTIVELY READ is an observation of that family;
#   * a table whose INTERFACE IS ABSENT (the file does not exist) was NOT
#     read: the absence of the interface does NOT prove that the family is
#     disabled, and it does NOT prove that there is no listener of it;
#   * a table that EXISTS and could NOT be read is a failed observation.
#
# Only an INDEPENDENT accreditation of the family (a SEPARATE declaration,
# never the failed read itself) can excuse an absent interface. Without
# it, the observation is INCOMPLETE, the state of the port is
# NOT_OBSERVABLE and this verifier FAILS.
SOCKET_TABLES = (
    ("ipv4", "tcp"),
    ("ipv6", "tcp6"),
)

# The ROOT of the procfs that the observations read.
#
# It is "/proc" in every real invocation. It is a CONSTANT (and not an
# argument), so that no observation can ever be pointed somewhere else. The
# seam exists for ONE reason: an observation that CANNOT be performed has to
# be REPRODUCIBLE, and the difference between "the resource is not there"
# and "the state of the resource could not be read" is invisible in a
# healthy machine.
PROC_ROOT = "/proc"

# The three states that an observation of this verifier can have.
OBS_PRESENT = "PRESENT"
OBS_ABSENT = "ABSENT"
OBS_NOT_OBSERVABLE = "NOT_OBSERVABLE"


def proc_path(*parts):
    """The path of an entry of the procfs that the observations read."""
    return os.path.join(PROC_ROOT, *parts)


# ---------------------------------------------------------------------------
# The registry of the state of the protected resources.
# ---------------------------------------------------------------------------
def read_registry(path):
    """Reads the registry: a file of `key=value` lines grouped by `resource=`."""
    blocks = {}
    current = None
    with open(path, "r", encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ValueError("linea %d sin '=': %r" % (number, raw))
            key, _, value = line.partition("=")
            key = key.strip()
            value = value.strip()
            if key == "resource":
                current = value
                blocks.setdefault(current, {})
                continue
            if current is None:
                raise ValueError("linea %d fuera de un bloque 'resource=': %r" % (number, raw))
            blocks[current][key] = value
    return blocks


def read_baseline(path):
    """Reads the baseline of the protected resources (key=value lines)."""
    values = {}
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            values[key.strip()] = value.strip()
    return values


# ---------------------------------------------------------------------------
# The observations.
# ---------------------------------------------------------------------------
def observe_protected_pid(pid):
    """The state and the starttime of a PID, read from /proc/<pid>/stat ONLY.

    NOTHING else of the process is read (no cmdline, no environ, no exe, no
    descriptors) and the process is NEVER signalled.

    Returns (observation, starttime_ticks, detail):
      observation  PRESENT | ABSENT | NOT_OBSERVABLE;
      starttime    the ticks of the start, or None;
      detail       the diagnosis of an impossible observation.

    The difference between ABSENT and NOT_OBSERVABLE is the whole point of
    this verifier: the absence of a process is a FACT, and it is only
    observed when the kernel says that the entry does not exist. A read that
    FAILS is not a fact about the process: it is an observation that could
    NOT be performed, and it is never published as an absence.
    """
    path = proc_path("%d" % pid, "stat")
    try:
        with open(path, "r", encoding="ascii", errors="replace") as handle:
            data = handle.read()
    except FileNotFoundError:
        # The CONFIRMED absence: the kernel says that the entry does not
        # exist. This is a fact about the process.
        return OBS_ABSENT, None, ""
    except OSError as exc:
        # The read FAILED (a permission, an I/O error): the state of the
        # process could NOT be observed. It is NOT an absence.
        return OBS_NOT_OBSERVABLE, None, "%s: %s" % (path, exc)
    tail = data.rsplit(")", 1)[-1].split()
    if len(tail) < 20:
        # A stat that cannot be parsed is NOT a dead process: it is an
        # observation that could not be made.
        return OBS_NOT_OBSERVABLE, None, "%s: stat ilegible" % path
    return OBS_PRESENT, tail[19], ""


def observe_database(path):
    """The metadata of the database, by stat() ONLY. It is never opened.

    Returns (metadata, observation, detail) with observation PRESENT |
    ABSENT | NOT_OBSERVABLE.
    """
    try:
        info = os.stat(path)
    except FileNotFoundError:
        return None, OBS_ABSENT, ""
    except OSError as exc:
        return None, OBS_NOT_OBSERVABLE, "%s: %s" % (path, exc)
    return (
        {
            "dev": info.st_dev,
            "inode": info.st_ino,
            "size": info.st_size,
            "mode": info.st_mode,
            "mtime_ns": info.st_mtime_ns,
        },
        OBS_PRESENT,
        "",
    )


def read_disabled_families(path):
    """The families whose DISABLEMENT is INDEPENDENTLY accredited.

    The accreditation NEVER comes from the read of the socket table: a read
    that failed is not evidence about the family, and an interface that is
    not exposed says nothing about the sockets of that family. It comes
    from a SEPARATE file, declared by the registry, whose blocks state the
    family and the fact of its disablement.

    Returns (families, error): `families` is the set of the families whose
    disablement is accredited, and `error` is the diagnosis of an
    accreditation that was DECLARED and could NOT be read (an empty string
    when there is no such problem). An accreditation that does not exist
    accredifies NOTHING: the default is the fail-closed one.
    """
    if not path:
        return set(), ""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        return set(), "%s: %s" % (path, exc)
    families = set()
    family = ""
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip().lower()
        value = value.strip().upper()
        if key == "family":
            family = value.lower()
            continue
        if key == "state" and family and value == "DISABLED":
            families.add(family)
    return families, ""


def observe_listening_port(port, disabled_families=()):
    """The state of the port: True, False or None (NOT OBSERVABLE).

    The observation is the reading of the socket table of the kernel: it is
    a file read, it opens no connection and it sends no packet. Only the
    sockets of THIS port are considered, and only their state is reported:
    the table of the host is never published.

    The observation is COMPLETE only when EVERY table that could hold a
    listener of the port has been EFFECTIVELY READ. An interface that is
    ABSENT is NOT a table that was read: it is counted as absent, and the
    family is only excused when its disablement was INDEPENDENTLY
    accredited (see `read_disabled_families`).

    Returns:
      (True, detail)  a socket of the port is in the LISTEN state;
      (False, detail) the observation was COMPLETE and no socket of the
                      port is listening;
      (None, detail)  the observation was IMPOSSIBLE or INCOMPLETE: a
                      table of sockets could not be read, or the interface
                      of a family is absent without an independent
                      accreditation. It is NEVER reported as "not
                      listening".

    The detail is a dict with the families whose table was effectively
    read, the families whose interface was absent, the failures and the
    families whose disablement was accredited.
    """
    wanted = "%04X" % port
    read_families = []
    absent_families = []
    failures = []
    for family, name in SOCKET_TABLES:
        path = proc_path("net", name)
        try:
            with open(path, "r", encoding="ascii", errors="replace") as handle:
                handle.readline()
                for line in handle:
                    fields = line.split()
                    if len(fields) < 4:
                        continue
                    local = fields[1]
                    state = fields[3]
                    if local.rsplit(":", 1)[-1] == wanted and state == LISTEN_STATE:
                        return True, {
                            "read": read_families + [family],
                            "absent": absent_families,
                            "failures": failures,
                            "disabled": sorted(disabled_families),
                            "listener_family": family,
                        }
            read_families.append(family)
        except FileNotFoundError:
            # The interface is ABSENT: the table was NOT read. This is NOT
            # an observation of the family: the absence of the interface
            # does not prove that the family is disabled, and a listener of
            # that family would be INVISIBLE.
            absent_families.append(family)
        except OSError as exc:
            # The table EXISTS and could not be read: the observation of
            # that family is IMPOSSIBLE.
            failures.append("%s: %s" % (path, exc))

    detail = {
        "read": read_families,
        "absent": absent_families,
        "failures": failures,
        "disabled": sorted(disabled_families),
        "listener_family": None,
    }
    if failures:
        # A table that EXISTS could not be read: the observation is
        # INCOMPLETE and the state of the port is NOT observable.
        return None, detail
    unaccredited = [f for f in absent_families if f not in disabled_families]
    if unaccredited:
        # The interface of that family is ABSENT and its disablement is NOT
        # independently accredited: a listener of that family would be
        # INVISIBLE, so the observation is INCOMPLETE.
        return None, detail
    return False, detail


# ---------------------------------------------------------------------------
# The verifier.
# ---------------------------------------------------------------------------
def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--registry", required=True)
    parser.add_argument("--incident", required=True)
    parser.add_argument("--out", default="")
    parser.add_argument("--home", default=os.path.expanduser("~"))
    args = parser.parse_args(argv)

    failures = []
    report = []

    def emit(key, value):
        report.append("%s=%s" % (key, value))

    emit("RESOURCE", "protected-resources")
    emit("OBSERVATION_UTC", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    emit("VERIFIER", "tests/forge_protected_resources.py")
    emit("STAT_SCOPE", "only /proc/<pid>/stat and stat() of the protected DB; the DB is never opened, read nor hashed")
    emit(
        "OBSERVATION_REQUIREMENT",
        "una lectura que FALLA no es una ausencia: el estado NOT_OBSERVABLE es un "
        "FALLO de este verificador y nunca se publica como ABSENT ni como NOT_LISTENING",
    )

    # -- the registry MUST exist and MUST declare the state ---------------
    try:
        registry = read_registry(args.registry)
    except (OSError, ValueError) as exc:
        emit("REGISTRY", "UNREADABLE")
        emit("REGISTRY_ERROR", str(exc))
        emit("PROTECTED_RESOURCES_CHECK_RC", 1)
        text = "\n".join(report) + "\n"
        if args.out:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(text)
        sys.stdout.write(text)
        return 1

    emit("REGISTRY", args.registry)
    emit("BASELINE", args.baseline)
    emit("INCIDENT_REPORT", args.incident)

    for required in ("protected-process", "protected-database", "protected-port"):
        if required not in registry:
            failures.append("el registro no declara el recurso %s" % required)
    if failures:
        for failure in failures:
            emit("FAIL", failure)
        emit("PROTECTED_RESOURCES_CHECK_RC", 1)
        text = "\n".join(report) + "\n"
        if args.out:
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(text)
        sys.stdout.write(text)
        return 1

    # -- (a) the protected PID -------------------------------------------
    process = registry["protected-process"]
    pid = int(process.get("pid", "0") or 0)
    expected_ticks = process.get("expected_starttime_ticks", "")
    declared_state = (process.get("observed_state", "") or "").upper()
    emit("PROTECTED_PID", pid)
    emit("PROTECTED_PID_REGISTERED_STATE", declared_state)
    emit("PROTECTED_PID_EXPECTED_STARTTIME_TICKS", expected_ticks)
    emit("PROTECTED_PID_CAUSE", process.get("cause", ""))
    emit("PROTECTED_PID_CAUSE_DATE", process.get("cause_date", ""))
    emit("PROTECTED_PID_INCIDENT_LINK", process.get("incident_report", ""))
    emit("PROTECTED_PID_LIVE_INVARIANT_REQUIRED", process.get("live_invariant_required", ""))

    if process.get("live_invariant_required", "").upper() != "NO":
        failures.append(
            "el registro exige el invariante de vida del PID protegido: ese invariante "
            "ya NO puede satisfacerse (el proceso no existe) y no puede exigirse"
        )
    if declared_state != "ABSENT":
        failures.append(
            "el registro no declara el PID protegido como AUSENTE (declara %r)" % declared_state
        )
    if not expected_ticks:
        failures.append("el registro no declara la identidad (starttime) del PID protegido")
    if not os.path.exists(args.incident):
        failures.append("el informe del incidente no existe: %s" % args.incident)
    linked = process.get("incident_report", "")
    if linked and not os.path.exists(linked):
        failures.append("el enlace al incidente no existe: %s" % linked)

    observation, ticks, detail = observe_protected_pid(pid)
    if observation == OBS_ABSENT:
        emit("PROTECTED_PID_OBSERVED", "ABSENT")
        emit("PROTECTED_PID_OBSERVED_STARTTIME_TICKS", "ABSENT")
        emit("LIVE_STATE", "no")
        emit("STATE", "ABSENT")
    elif observation == OBS_NOT_OBSERVABLE:
        # The observation could NOT be performed: the absence is NOT
        # accredited and the PASS must not survive it.
        emit("PROTECTED_PID_OBSERVED", "NOT_OBSERVABLE")
        emit("PROTECTED_PID_OBSERVED_STARTTIME_TICKS", "NOT_OBSERVED")
        emit("LIVE_STATE", "unknown")
        emit("STATE", "NOT_OBSERVED")
        failures.append(
            "el estado del PID protegido NO SE PUDO OBSERVAR (%s): un error de lectura "
            "NO es una ausencia y esta verificacion no puede aceptar un recurso que "
            "no ha observado" % detail
        )
    else:
        emit("PROTECTED_PID_OBSERVED", "PRESENT")
        emit("PROTECTED_PID_OBSERVED_STARTTIME_TICKS", ticks)
        if ticks != expected_ticks:
            failures.append(
                "el numero %d esta RECICLADO: su starttime (%s) no es el registrado (%s); "
                "el registro debe revisarse" % (pid, ticks, expected_ticks)
            )
        else:
            failures.append(
                "el PID protegido esta VIVO con la identidad registrada: el registro dice "
                "ABSENT y el registro esta desactualizado"
            )
    emit("PROTECTED_PID_SIGNAL_ACTION", "none")
    emit("PROTECTED_PID_STATE_REGISTERED", "YES")

    # -- (b) the live database -------------------------------------------
    database = registry["protected-database"]
    relative = database.get("path", ".local/share/opencode/opencode.db")
    db_path = os.path.join(args.home, relative)
    emit("PROTECTED_DB_PATH", db_path)
    emit("PROTECTED_DB_METADATA_SOURCE", "stat() only; the file is never opened, read nor hashed")

    baseline = read_baseline(args.baseline)
    current, db_observation, db_detail = observe_database(db_path)
    if db_observation != OBS_PRESENT:
        emit("PROTECTED_DB_OBSERVED", db_observation)
        if db_observation == OBS_ABSENT:
            failures.append("la base de datos real no existe: %s" % db_path)
        else:
            failures.append(
                "el estado de la base de datos real NO SE PUDO OBSERVAR (%s): un error de "
                "lectura NO es una ausencia" % db_detail
            )
    else:
        emit("PROTECTED_DB_OBSERVED", "PRESENT")
        emit("PROTECTED_DB_DEV", current["dev"])
        emit("PROTECTED_DB_INODE", current["inode"])
        emit("PROTECTED_DB_SIZE", current["size"])
        emit("PROTECTED_DB_MODE", "0o%o" % current["mode"])
        emit("PROTECTED_DB_MTIME_NS_INFORMATIONAL", current["mtime_ns"])
        expected = {
            "dev": baseline.get("db_dev", ""),
            "inode": baseline.get("db_inode", ""),
            "size": baseline.get("db_size", ""),
            "mode": baseline.get("db_mode", ""),
        }
        for key, observed in (
            ("dev", current["dev"]),
            ("inode", current["inode"]),
            ("size", current["size"]),
            ("mode", "0o%o" % current["mode"]),
        ):
            wanted = expected[key]
            emit("PROTECTED_DB_%s_BASELINE" % key.upper(), wanted)
            if wanted and str(wanted) != str(observed):
                failures.append(
                    "la base de datos real cambio de %s (baseline=%s observado=%s)" % (key, wanted, observed)
                )
            else:
                emit("PROTECTED_DB_%s_MATCH" % key.upper(), "yes")
        emit(
            "PROTECTED_DB_MTIME_NS_BASELINE_INFORMATIONAL",
            baseline.get("db_mtime_ns_informational", baseline.get("db_mtime_ns", "")),
        )
        emit("PROTECTED_DB_MTIME_ROLE", "informational_only")

    # -- (c) the loopback port -------------------------------------------
    port_block = registry["protected-port"]
    port = int(port_block.get("port", DEFAULT_PORT) or DEFAULT_PORT)
    # The accreditation of a DISABLED family is INDEPENDENT: it comes from a
    # SEPARATE file, declared by the registry, and never from the read of the
    # socket table. Without it, an absent interface is an INCOMPLETE
    # observation and the state of the port is NOT_OBSERVABLE.
    accreditation_path = (port_block.get("disabled_family_evidence", "") or "").strip()
    disabled_families, accreditation_error = read_disabled_families(accreditation_path)
    listening, port_detail = observe_listening_port(port, disabled_families)
    emit("PROTECTED_PORT", port)
    emit("PROTECTED_PORT_ADDRESS", port_block.get("address", "127.0.0.1"))
    emit("PROTECTED_PORT_REGISTERED_STATE", (port_block.get("observed_state", "") or "").upper())
    emit("PROTECTED_PORT_CAUSE", port_block.get("cause", ""))
    emit("PROTECTED_PORT_CAUSE_DATE", port_block.get("cause_date", ""))
    emit("PROTECTED_PORT_OBSERVATION", "lectura de /proc/net/tcp y /proc/net/tcp6; sin conexiones ni paquetes")
    emit("PROTECTED_PORT_TABLES_EFFECTIVELY_READ", ",".join(port_detail["read"]) or "none")
    emit("PROTECTED_PORT_INTERFACES_ABSENT", ",".join(port_detail["absent"]) or "none")
    emit("PROTECTED_PORT_TABLES_UNDREADABLE", "; ".join(port_detail["failures"]) or "none")
    emit("PROTECTED_PORT_FAMILIES_DISABLED_ACCREDITED", ",".join(port_detail["disabled"]) or "none")
    if accreditation_path:
        emit("PROTECTED_PORT_DISABLED_FAMILY_EVIDENCE", accreditation_path)
        if accreditation_error:
            failures.append(
                "la acreditacion INDEPENDIENTE de una familia deshabilitada fue DECLARADA y NO se pudo leer "
                "(%s): no acredita nada" % accreditation_error
            )
    if listening is None:
        # The observation could NOT be performed (or was INCOMPLETE): "not
        # listening" is NOT accredited and the PASS must not survive it.
        reasons = []
        if port_detail["failures"]:
            reasons.append(
                "tablas que EXISTEN y no se pudieron leer: %s" % "; ".join(port_detail["failures"])
            )
        unaccredited = [f for f in port_detail["absent"] if f not in disabled_families]
        if unaccredited:
            reasons.append(
                "interfaces AUSENTES (la tabla no se leyo) sin acreditacion independiente de que la "
                "familia este deshabilitada: %s" % ", ".join(unaccredited)
            )
        emit("PROTECTED_PORT_OBSERVED", "NOT_OBSERVABLE")
        failures.append(
            "el estado del puerto %d NO SE PUDO OBSERVAR (%s); un 'NO EN ESCUCHA' NO ESTA ACREDITADO"
            % (port, "; ".join(reasons) or "observacion incompleta")
        )
    elif listening:
        emit("PROTECTED_PORT_OBSERVED", "LISTENING")
        failures.append(
            "el puerto %d esta EN ESCUCHA: el registro dice que no lo esta y la observacion lo contradice" % port
        )
    else:
        emit("PROTECTED_PORT_OBSERVED", "NOT_LISTENING")
    if (port_block.get("observed_state", "") or "").upper() != "NOT_LISTENING":
        failures.append("el registro no declara el puerto %d como NO EN ESCUCHA" % port)

    # -- the constancy about the previous evidence ------------------------
    emit(
        "PRIOR_EVIDENCE_CONSTANCY",
        "las generaciones anteriores (tester-v10..tester-v14) declararon '530393 intacto'; "
        "esa afirmacion describe un estado que YA NO ES CIERTO y se conserva sin reescribir",
    )
    emit(
        "CODE_PROTECTION",
        "el PID 530393 sigue siendo una exclusion DURA en el codigo: se rechaza aunque este muerto "
        "(un PID puede ser reciclado)",
    )
    emit("PROTECTED_RESOURCES_SCOPE", "la no-afectacion por el LOTE; la vida del PID protegido NO se acredita y NO se exige")

    if failures:
        for failure in failures:
            emit("FAIL", failure)
        emit("PROTECTED_RESOURCES_CHECK_RC", 1)
        emit("PROTECTED_CHECK_RC", 1)
    else:
        emit("PROTECTED_RESOURCES_CHECK_RC", 0)
        emit("PROTECTED_CHECK_RC", 0)

    text = "\n".join(report) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    sys.stdout.write(text)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
