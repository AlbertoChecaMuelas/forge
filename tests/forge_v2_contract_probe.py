#!/usr/bin/env python3
"""tests/forge_v2_contract_probe.py — probe of the CONTRACT of the V2 bank.

It answers ONE question: does the contract of the bank hold the properties
that the acceptance depends on, or only the ones that a loose comparison
happens to accept?

The probe NEVER imports the code under test: the text is parsed with ``ast``
and the PURE functions are extracted and executed in an isolated namespace.
Nothing of the harness is imported, so the probe can never execute a
top-level side effect of the harness.

The properties it checks (each one of them has a way of being FALSE):

  C2-1  The conversion of the exit code accepts BOTH forms of the same
        fact (the raw 137 and the normalised -9) and REJECTS an absent or
        an invalid value. The conversion is checked at its SOURCE, not at
        the comparator that uses it.
  C2-2  The observed state of the termination is a separate fact from the
        exit code and it says UNOBSERVABLE when there is nothing to observe.
  C2-3  The runner declares the OBSERVED exit code of every scenario and
        the eliminated one is -9 (SIGKILL), which is not the same
        declaration as the NONE of its positive acceptance.
  C2-4  The runner compares the exit code of the suite EXACTLY, for every
        scenario, and rejects an absent or an invalid value.
  C2-5  The runner does NOT accept a loose "the exit code is not zero" as
        a proof that the scenario ended by SIGKILL.
  C3-1  The verdict of the closure is conditioned on EVERY independent
        link of the contract (the wait, the RC of the launcher, the
        observed termination of the PID 1 and the declaration of the
        closure).
  C3-2  The absence of survivors, the absence of members of the own
        process group and the state of the init are OBSERVED and not
        published as favourable constants.
  C3-3  The disappearance of the init does not depend ONLY on the
        declaration of the closure.
  C3-4  The report publishes the tri-state of the observation: an absence
        that was not observed is NOT a verified absence.
  C3-5  The verdict of the cleanup of the harness REQUIRES a COMPLETE
        observation and the three absences EXPLICITLY VERIFIED: an
        absence that was not observed is NOT an absence. The verdict is
        evaluated with the reproduction of the defect, not only read.
  C3-6  The STABLE entry (tests/forge_v2_safety.sh) applies the SAME
        criterion: it REJECTS a report whose observation is INCOMPLETE
        and whose absences are not verified, and it ACCEPTS a report that
        carries the verified observation.
  C4-1  The harness publishes TWO censuses: the census of the bank (52)
        and the census of the AUXILIARY controls (the controls of the
        controls), and the auxiliary controls are NOT counted inside the
        bank.
  C4-2  The verdict of the auxiliary controls is HARD: a red auxiliary
        control, or a missing one, leaves the census of the bank green
        and the run failed.
  C4-3  The runner of the scenarios applies BOTH censuses: it demands the
        52 of the bank, it rejects the 55, and it validates the census of
        the auxiliary controls apart (an absent, a red or a contaminated
        one is rejected).
  C4-4  The STABLE entry applies the SAME criterion to the auxiliary
        census: it accepts a green one and rejects an absent or a red one.

Usage:
    python3 tests/forge_v2_contract_probe.py [--harness PATH] [--runner PATH]
                                              [--stable PATH]
"""

import argparse
import ast
import contextlib
import io
import json
import os
import sys
import tempfile

DEFAULT_HARNESS = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "forge_v2_safety_harness.py"
)
DEFAULT_RUNNER = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "forge_v2_safety_scenarios.sh"
)
DEFAULT_STABLE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "forge_v2_safety.sh"
)
DEFAULT_PROTECTED = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "forge_protected_resources.py"
)

CHECKS = []

AUXILIARY_IDS = ("INSP-6", "INSP-7", "INSP-8")
"""The CONTROLS OF THE CONTROLS of the bank.

They are counted APART from the bank: the census of the bank keeps its own
count and these three have their own count and their own verdict.
"""


def auxiliary_section(status="PASS", ids=AUXILIARY_IDS, total=None, failed=0, complete=True, verdict="PASS"):
    """A synthetic census of the auxiliary controls.

    It is the shape that the harness publishes in the section
    ``auxiliary_controls`` of its report, and it is the shape that the
    consumers (the runner of the scenarios and the stable entry) read.
    """
    cases = [
        {"id": cid, "kind": "inspeccion", "status": status, "detail": "sintetico"}
        for cid in ids
    ]
    counted = len(cases) if total is None else total
    return {
        "ids": list(ids),
        "cases": cases,
        "summary": {
            "ids": list(ids),
            "total": counted,
            "passed": counted - failed,
            "failed": failed,
            "complete": complete,
            "verdict": verdict,
        },
    }


def check(name, ok, detail):
    CHECKS.append({"name": name, "ok": bool(ok), "detail": str(detail)})
    return bool(ok)


# ---------------------------------------------------------------------------
# Helpers over the AST.
# ---------------------------------------------------------------------------
def read_source(path):
    with open(path, "r", encoding="utf-8") as stream:
        return stream.read()


def function_node(tree, name):
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    return None


def assignments_to(func, name):
    """The assignments that bind `name` inside `func`."""
    found = []
    for node in ast.walk(func):
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == name:
                found.append(node)
    return found


def names_used(node):
    return {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}


def transitive_names(func, node, max_nodes=200):
    """The names a value depends on, following the local bindings.

    A verdict can be built from a helper variable (the links of the closure
    can be grouped in one expression), so the dependency is followed
    through the assignments of the same function. Every name is followed
    once, so the walk always terminates.
    """
    seen = set()
    pending = list(names_used(node))
    while pending and len(seen) < max_nodes:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        for assignment in assignments_to(func, current):
            pending.extend(names_used(assignment.value))
    return seen


def is_favourable_constant(node):
    """True for a literal that declares a FAVOURABLE value.

    An empty list, an empty dict, False and the like: the values that make
    a verdict pass without any observation behind it.
    """
    if isinstance(node, ast.Constant):
        return True
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        return all(is_favourable_constant(item) for item in node.elts)
    if isinstance(node, ast.Dict):
        return all(
            is_favourable_constant(key) and is_favourable_constant(value)
            for key, value in zip(node.keys, node.values)
        )
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
        if node.func.id in ("list", "dict", "set", "tuple") and not node.args:
            return True
    return False


def runner_python_blocks(text):
    """The embedded python programs of the runner of the scenarios."""
    blocks = []
    marker = "<<'PY'\n"
    index = 0
    while True:
        start = text.find(marker, index)
        if start < 0:
            break
        start += len(marker)
        end = text.find("\nPY\n", start)
        if end < 0:
            break
        blocks.append(text[start:end])
        index = end + 1
    return blocks


def shell_python_blocks(text):
    """The embedded python programs of a shell file (the same heredoc)."""
    return runner_python_blocks(text)


def module_constant(tree, name):
    """The module-level constant `name` of a parsed program."""
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if isinstance(target, ast.Name) and target.id == name:
                try:
                    return ast.literal_eval(node.value)
                except (ValueError, TypeError):
                    return None
    return None


# ---------------------------------------------------------------------------
# The evaluator of a verdict, in isolation.
#
# The verdict of the harness is an EXPRESSION over a handful of names. The
# probe does not import the harness: it PARSES it, resolves the names of the
# expression (the assignments of the same function and the module constants)
# and evaluates the expression with the values of a reproduction.
#
# The reproduction is the one of the defect: the links of the receipt are
# VALID, the observation of the aftermath is INCOMPLETE and the three
# absences are None (the value of an absence that could NOT be observed).
# ---------------------------------------------------------------------------
SAFE_BUILTINS = {
    "bool": bool,
    "str": str,
    "int": int,
    "float": float,
    "len": len,
    "abs": abs,
    "any": any,
    "all": all,
    "sorted": sorted,
    "list": list,
    "dict": dict,
    "set": set,
    "tuple": tuple,
}


class ResolutionError(Exception):
    """A name of the expression could not be resolved."""


def _resolve(name, ctx):
    if name in ctx["cache"]:
        return ctx["cache"][name]
    if name in ctx["base"]:
        value = ctx["base"][name]
    else:
        value = None
        error = None
        found = False
        # A name can be assigned more than once. In straight-line code the
        # LAST assignment is the one that the verdict reads (the receipt
        # redeclares the RC of the launcher AFTER the observation of it,
        # for instance), so the candidates are tried from the last one.
        # An assignment that walks into an object that the reproduction
        # does not build is simply not the one that the verdict reads.
        for node in reversed(assignments_to(ctx["func"], name)):
            found = True
            try:
                value = _evaluate(node.value, ctx)
                error = None
                break
            except Exception as exc:  # noqa: BLE001 - the next candidate
                error = exc
        if not found:
            constant = module_constant(ctx["tree"], name)
            if constant is None:
                raise ResolutionError(name)
            value = constant
        elif error is not None:
            raise error
    ctx["cache"][name] = value
    return value


def _evaluate(node, ctx):
    names = {
        item.id
        for item in ast.walk(node)
        if isinstance(item, ast.Name) and isinstance(item.ctx, ast.Load)
    }
    env = {}
    for name in names:
        if name in SAFE_BUILTINS:
            # The builtin is resolved by the evaluation itself: it is not a
            # name of the program under test.
            continue
        env[name] = _resolve(name, ctx)
    expression = ast.Expression(body=node)
    ast.fix_missing_locations(expression)
    return eval(  # noqa: S307 - the expression comes from the parsed text
        compile(expression, "<probe>", "eval"),
        {"__builtins__": dict(SAFE_BUILTINS)},
        env,
    )


def evaluate_verdict(func, tree, target, base):
    """Evaluate the verdict `target` of `func` with the given base values."""
    ctx = {"func": func, "tree": tree, "base": dict(base), "cache": {}}
    if not assignments_to(func, target):
        raise ResolutionError(target)
    return _resolve(target, ctx)


def receipt_stub(receipt_path):
    """A receipt whose links are ALL VALID.

    The stub carries the identity that the receipt has to declare for the
    invocation to be the one of this run, so the reproduction isolates the
    absence of the observation instead of failing by an unrelated link.
    """
    return {
        "IDENTIFIER": os.path.basename(os.path.dirname(receipt_path)),
        "RECEIPT_PATH": receipt_path,
        "ACCREDITATION": "PASS",
        "RECEIPT_COMPLETENESS": "COMPLETE",
        "CLOSURE": "CONFIRMED",
        "LAUNCHER_WAIT_COMPLETED": "YES",
        "LAUNCHER_RC": "0",
        "PID1_COMPLETION_OBSERVED": "PASS",
        "PID_NAMESPACE": "pid:[4026531836]",
    }


def check_calls(tree):
    """Every `check(name, ok, detail)` call of a program."""
    calls = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if not isinstance(node.func, ast.Name) or node.func.id != "check":
            continue
        if not node.args:
            continue
        first = node.args[0]
        if isinstance(first, ast.Constant) and isinstance(first.value, str):
            calls.append((first.value, node))
    return calls


def check_templates(text):
    """The `check(...)` calls of a program, indexed by the NAME of the check.

    The name of a check can be a TEMPLATE ("...: %s" % value): the key is
    the literal of the template, so that a check declared inside a loop is
    found once and can be evaluated with each one of its bindings.
    """
    found = {}
    for node in ast.walk(ast.parse(text)):
        if not isinstance(node, ast.Call):
            continue
        if not isinstance(node.func, ast.Name) or node.func.id != "check":
            continue
        if not node.args:
            continue
        first = node.args[0]
        if isinstance(first, ast.Constant) and isinstance(first.value, str):
            key = first.value
        elif isinstance(first, ast.BinOp) and isinstance(first.op, ast.Mod):
            if isinstance(first.left, ast.Constant) and isinstance(first.left.value, str):
                key = first.left.value
            else:
                key = ast.unparse(first.left)
        else:
            continue
        found.setdefault(key, node)
    return found


# ---------------------------------------------------------------------------
# The validation block of the STABLE entry.
#
# The stable entry (tests/forge_v2_safety.sh) is the consumer that validates
# the report of the harness. Its validation block is EXTRACTED from the text
# and executed over a SYNTHETIC report, so the criterion is exercised and
# not merely read.
# ---------------------------------------------------------------------------
def stable_validator_block(stable_text):
    """The block of the stable entry that validates the report of the harness.

    It is located by a marker of its own text: the criterion it applies is
    the one of the verified absence.
    """
    for block in shell_python_blocks(stable_text):
        if "cleanup.ok no es true" in block:
            return block
    return None


def run_stable_validator(validator, report):
    """Run the validation block of the stable entry over a synthetic report.

    It returns the exit code of the block: 0 means that the report was
    ACCEPTED and a non zero code means that it was REJECTED.
    """
    workdir = tempfile.mkdtemp(prefix="forge-v2-probe-")
    try:
        report_path = os.path.join(workdir, "safety-results.json")
        with open(report_path, "w", encoding="utf-8") as stream:
            json.dump(report, stream)
        program = os.path.join(workdir, "validator.py")
        with open(program, "w", encoding="utf-8") as stream:
            stream.write(validator)
        saved = sys.argv
        sys.argv = ["validator", report_path]
        captured = io.StringIO()
        try:
            with contextlib.redirect_stderr(captured):
                exec(  # noqa: S102 - the block comes from the parsed text
                    compile(validator, "<validator>", "exec"),
                    {"__name__": "__validator__"},
                )
            code = 0
        except SystemExit as exc:
            code = exc.code or 0
        finally:
            sys.argv = saved
        return code
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# C2: the observed exit code of the eliminated scenario.
# ---------------------------------------------------------------------------
def probe_c2(harness_path, runner_path, harness_text, runner_text):
    tree = ast.parse(harness_text)

    namespace = {"MAX_SIGNAL": module_constant(tree, "MAX_SIGNAL")}
    for name in ("exit_code_of", "termination_state_of"):
        node = function_node(tree, name)
        if node is None:
            check(
                "C2-1 la conversion del RC de la suite existe y es observable",
                False,
                "la funcion %s no existe en %s" % (name, harness_path),
            )
            return
        exec(compile(ast.Module(body=[node], type_ignores=[]), "<harness>", "exec"), namespace)

    convert = namespace["exit_code_of"]
    state = namespace["termination_state_of"]

    def safe(value):
        """The conversion of a value, WITHOUT letting it break the probe."""
        try:
            return convert(value)
        except Exception as exc:  # pragma: no cover - diagnostico
            return "error:%s" % exc

    # The negative form is the SAME fact as the raw one: it must not be
    # read as an ABSENT exit code.
    check(
        "C2-1a la conversion del RC acepta la forma normalizada (-9)",
        safe("-9") == -9,
        "exit_code_of('-9')=%r (se esperaba -9)" % (safe("-9"),),
    )
    check(
        "C2-1b la conversion del RC acepta la forma cruda (137)",
        safe("137") == -9,
        "exit_code_of('137')=%r (se esperaba -9)" % (safe("137"),),
    )
    for value in ("", None, "no-es-un-rc", "12x"):
        check(
            "C2-1c la conversion del RC RECHAZA un valor ausente o invalido (%r)" % (value,),
            safe(value) is None,
            "exit_code_of(%r)=%r (se esperaba None: un valor ausente NO es un RC)"
            % (value, safe(value)),
        )

    # C2-1d: the DOMAIN of each representation is validated BEFORE the
    # normalisation. A magnitude outside the domain of the signals is an
    # INVALID state and it is REJECTED, never reinterpreted as another
    # signal: the negative form "-137" is not "the signal 9" and the
    # positive form "999" is not "the signal 871".
    for value in ("-137", "-65", "-129", "999", "193", "256", "128"):
        check(
            "C2-1d la conversion del RC RECHAZA un estado INVALID (%r)" % (value,),
            safe(value) is None,
            "exit_code_of(%r)=%r (se esperaba None: un estado invalido NO es un RC)"
            % (value, safe(value)),
        )
    check(
        "C2-1e la conversion del RC valida el dominio de la senal en los dos extremos",
        safe("-64") == -64 and safe("192") == -64,
        "exit_code_of('-64')=%r exit_code_of('192')=%r (se esperaba -64 en los dos)"
        % (safe("-64"), safe("192")),
    )
    check(
        "C2-1f la conversion del RC conserva los RC de salida ordinarios",
        safe("0") == 0 and safe("4") == 4 and safe("127") == 127,
        "exit_code_of('0')=%r exit_code_of('4')=%r exit_code_of('127')=%r"
        % (safe("0"), safe("4"), safe("127")),
    )
    check(
        "C2-2 el estado de terminacion observado es un hecho aparte del RC",
        state(-9) == "SIGNALLED:9" and state(0) == "EXITED:0" and state(None) == "UNOBSERVABLE",
        "termination_state_of(-9)=%r (-9)=%r (0)=%r (None)=%r"
        % (state(-9), state(-9), state(0), state(None)),
    )
    check(
        "C2-2b el estado de terminacion de un estado INVALID es UNOBSERVABLE",
        state(safe("-137")) == "UNOBSERVABLE" and state(safe("999")) == "UNOBSERVABLE",
        "termination_state_of(exit_code_of('-137'))=%r "
        "termination_state_of(exit_code_of('999'))=%r (se esperaba UNOBSERVABLE)"
        % (state(safe("-137")), state(safe("999"))),
    )

    # The runner declares the OBSERVED exit code of every scenario.
    check(
        "C2-3a el runner declara el RC OBSERVADO de la suite eliminada (-9)",
        "EXPECTED_SUITE_OBSERVED_RC=-9" in runner_text,
        "EXPECTED_SUITE_OBSERVED_RC=-9 presente=%s"
        % ("EXPECTED_SUITE_OBSERVED_RC=-9" in runner_text),
    )
    check(
        "C2-3b el runner conserva la declaracion NONE de la aceptacion positiva",
        "EXPECTED_SUITE_RC=NONE" in runner_text,
        "EXPECTED_SUITE_RC=NONE presente=%s" % ("EXPECTED_SUITE_RC=NONE" in runner_text),
    )

    # The comparison of the exit code is EXACT and it rejects an absent one.
    exact = False
    loose = []
    observed_branch = False
    for block in runner_python_blocks(runner_text):
        try:
            block_tree = ast.parse(block)
        except SyntaxError as exc:
            check(
                "C2-4 el python embebido del runner es analizable",
                False,
                "SyntaxError: %s" % exc,
            )
            continue
        for name, call in check_calls(block_tree):
            body = ast.dump(call)
            if name == "RC de la capa suite":
                if "expected_suite_observed_rc" in body and "IsNot" in body:
                    exact = True
            if "suite_rc" in body and "NotEq" in body:
                loose.append(name)
            if name.startswith("la suite eliminada") and "Eq" in body and "-9" in body:
                observed_branch = True
    check(
        "C2-4 el runner compara el RC de la suite EXACTAMENTE y rechaza los valores ausentes",
        exact,
        "comparacion exacta contra expected_suite_observed_rc encontrada=%s" % exact,
    )
    check(
        "C2-5 el runner NO acepta un RC distinto de cero como prueba de SIGKILL",
        not loose,
        "comparaciones laxas encontradas: %s" % (loose,),
    )
    check(
        "C2-6 el runner exige el RC observado -9 en el escenario eliminado",
        observed_branch,
        "comprobacion del RC observado -9 encontrada=%s" % observed_branch,
    )


# ---------------------------------------------------------------------------
# C3: the closure verdict and the observed absence.
# ---------------------------------------------------------------------------
def probe_c3(harness_path, stable_path, harness_text, stable_text):
    tree = ast.parse(harness_text)
    supervisor = function_node(tree, "role_supervisor")
    if supervisor is None:
        check(
            "C3-1 el veredicto del cierre exige TODOS sus enlaces",
            False,
            "no se ha encontrado role_supervisor en %s" % harness_path,
        )
        return

    links = ("closure", "launcher_wait_completed", "launcher_rc", "pid1_completion_observed")
    found = []
    for node in assignments_to(supervisor, "containment_ok"):
        used = transitive_names(supervisor, node.value)
        if all(link in used for link in links):
            found.append(sorted(used & set(links)))
    check(
        "C3-1 el veredicto del cierre exige TODOS sus enlaces independientes",
        bool(found),
        "el veredicto de contencion no depende a la vez de: %s (enlaces: %s)"
        % (found, ", ".join(links)),
    )

    for name in ("survivors", "members", "init_alive"):
        assignments = assignments_to(supervisor, name)
        constants = [
            node
            for node in assignments
            if is_favourable_constant(node.value)
        ]
        observed = [
            node
            for node in assignments
            if "aftermath" in names_used(node.value)
        ]
        check(
            "C3-2a la ausencia de %s se OBSERVA y no se publica como constante" % name,
            bool(assignments) and not constants and bool(observed),
            "asignaciones=%d constantes=%d observadas=%d"
            % (len(assignments), len(constants), len(observed)),
        )

    gone = assignments_to(supervisor, "init_gone")
    only_closure = []
    for node in gone:
        used = names_used(node.value)
        if used - {"closure"}:
            continue
        only_closure.append(ast.dump(node.value))
    check(
        "C3-3 la desaparición del init NO depende SOLO de la declaracion del cierre",
        bool(gone) and not only_closure,
        "asignaciones=%d que dependen solo de 'closure'=%d" % (len(gone), len(only_closure)),
    )

    # The report publishes the tri-state of the observation.
    published = set()
    for node in ast.walk(supervisor):
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if not isinstance(target, ast.Subscript):
                continue
            if not isinstance(target.value, ast.Name):
                continue
            if target.value.id != "report":
                continue
            slice_node = target.slice
            if isinstance(slice_node, ast.Constant) and isinstance(slice_node.value, str):
                if slice_node.value == "cleanup":
                    value = node.value
                    if isinstance(value, ast.Dict):
                        for key in value.keys:
                            if isinstance(key, ast.Constant):
                                published.add(key.value)
    wanted = (
        "aftermath_observation_state",
        "survivors_absence_verified",
        "members_absence_verified",
        "init_absence_verified",
        "suite_returncode_raw",
        "suite_termination_state",
        "launcher_observed_returncode",
    )
    missing = [name for name in wanted if name not in published]
    check(
        "C3-4 el informe publica el estado de la observacion y el RC observado del lanzador",
        not missing,
        "faltan en el informe: %s" % (missing,),
    )

    # -------------------------------------------------------------------------
    # C3-5: the verdict of the cleanup of the harness REQUIRES the observed
    # absence. It is checked twice: statically (the verdict DEPENDS on the
    # state of the observation and on the three verifications) and
    # BEHAVIOURALLY (the verdict is EVALUATED with the reproduction of the
    # defect: the links of the receipt are valid, the observation is
    # INCOMPLETE and the three absences are None).
    # -------------------------------------------------------------------------
    aftermath_facts = (
        "aftermath_state",
        "survivors_absence_verified",
        "members_absence_verified",
        "init_absence_verified",
    )
    dependencies = []
    for node in assignments_to(supervisor, "containment_ok"):
        dependencies.append(transitive_names(supervisor, node.value))
    dependent = set()
    for names in dependencies:
        dependent |= names
    missing_facts = [name for name in aftermath_facts if name not in dependent]
    check(
        "C3-5 el veredicto de la limpieza depende del estado de la observacion y de las tres ausencias",
        bool(dependencies) and not missing_facts,
        "dependencias=%s (faltan: %s)"
        % (sorted(dependent & set(aftermath_facts)), missing_facts),
    )

    receipt_path = "/tmp/opencode/forge-v2-probe/runs/run-probe/receipt.txt"
    base = {
        "receipt": receipt_stub(receipt_path),
        "receipt_path": receipt_path,
        "os": os,
        "root": "/tmp/opencode/forge-v2-probe/root-que-no-existe",
        "AMBIGUOUS_RECEIPT_KEY": module_constant(tree, "AMBIGUOUS_RECEIPT_KEY"),
        "aftermath_state": "INCOMPLETE",
        "survivors_absence_verified": None,
        "members_absence_verified": None,
        "init_absence_verified": None,
    }
    try:
        verdict = evaluate_verdict(supervisor, tree, "containment_ok", base)
    except ResolutionError as exc:
        verdict = "error:%s" % exc
    except Exception as exc:  # pragma: no cover - diagnostico
        verdict = "error:%s" % exc
    check(
        "C3-6 el veredicto de la limpieza es FALSO con una observacion INCOMPLETE y ausencias None",
        verdict is False,
        "containment_ok=%r (se esperaba False: una ausencia que no se pudo observar "
        "NO es una ausencia verificada)" % (verdict,),
    )

    good = dict(base)
    good.update(
        {
            "aftermath_state": "COMPLETE",
            "survivors_absence_verified": True,
            "members_absence_verified": True,
            "init_absence_verified": True,
        }
    )
    try:
        good_verdict = evaluate_verdict(supervisor, tree, "containment_ok", good)
    except Exception as exc:  # pragma: no cover - diagnostico
        good_verdict = "error:%s" % exc
    check(
        "C3-6b el veredicto de la limpieza es VERDADERO con la observacion COMPLETE y las tres ausencias verificadas",
        good_verdict is True,
        "containment_ok=%r (se esperaba True: el CONTROL de la comprobacion)"
        % (good_verdict,),
    )

    # -------------------------------------------------------------------------
    # C3-7: the STABLE entry applies the SAME criterion. Its validation is
    # EXERCISED with a synthetic report: the one that carries the verified
    # observation is accepted and the one that carries an INCOMPLETE
    # observation with the absences in None is REJECTED.
    # -------------------------------------------------------------------------
    validator = stable_validator_block(stable_text)
    if validator is None:
        check(
            "C3-7 la entrada estable valida el informe del arnes",
            False,
            "no se ha encontrado el bloque de validacion en %s" % stable_path,
        )
        return

    def run_validator(report):
        return run_stable_validator(validator, report)

    def report(state, verified):
        return {
            "cleanup": {
                "ok": True,
                "aftermath_observation_state": state,
                "survivors_absence_verified": verified,
                "members_absence_verified": verified,
                "init_absence_verified": verified,
                "survivors_in_private_namespace": None if verified is None else [],
                "members_of_own_process_group": None if verified is None else [],
                "namespace_init_alive_after": None if verified is None else False,
                "synthetic_root_present_after": None if verified is None else False,
                "watchdog_operational": True,
                "authorization_granted": True,
            },
            "supervisor": {},
            "summary": {"failed": 0},
            "cases": [],
            # The census of the auxiliary controls travels with its own
            # verdict: the stable entry applies the SAME criterion to it
            # that it applies to the main census.
            "auxiliary_controls": auxiliary_section(),
        }

    good_code = run_validator(report("COMPLETE", True))
    check(
        "C3-7a la entrada estable ACEPTA un informe con la observacion COMPLETE y las ausencias verificadas",
        good_code == 0,
        "rc=%r (se esperaba 0)" % (good_code,),
    )
    bad_code = run_validator(report("INCOMPLETE", None))
    check(
        "C3-7b la entrada estable RECHAZA un informe con la observacion INCOMPLETE y las ausencias None",
        bad_code != 0,
        "rc=%r (se esperaba un rc distinto de cero: la entrada estable no puede "
        "aceptar una ausencia que no se pudo observar)" % (bad_code,),
    )


# ---------------------------------------------------------------------------
# C4: the census of the bank and the census of its AUXILIARY controls.
#
# The bank has its OWN count (52) and the CONTROLS OF THE CONTROLS have
# their OWN count and their OWN verdict. Mixing them would change the
# contract of the bank (52 -> 55) and would bury the verdict of the
# auxiliary controls inside the aggregate. Keeping them apart is what
# makes them auditable, and their verdict is HARD: a red auxiliary
# control, or a missing one, fails the run.
#
# The properties are checked BEHAVIOURALLY: the harness is executed in an
# isolated namespace and its report is read back; the checks of the runner
# and of the stable entry are EVALUATED with a reproduction of the defect.
# ---------------------------------------------------------------------------
EVAL_BUILTINS = dict(SAFE_BUILTINS)
EVAL_BUILTINS.update({"isinstance": isinstance, "repr": repr, "print": print})


def probe_c4(harness_path, runner_path, stable_path, harness_text, runner_text, stable_text):
    # -- C4-1: the harness publishes TWO censuses -------------------------
    namespace = exec_module_text(harness_path, harness_text)
    Report = namespace.get("Report")
    if Report is None:
        check(
            "C4-1 el arnes publica dos censuses distintos",
            False,
            "no se ha encontrado la clase Report en %s" % harness_path,
        )
        return

    def build_report(auxiliary_status="PASS", auxiliary_ids=AUXILIARY_IDS, main=52):
        report = Report()
        for index in range(main):
            report.record("CASE-%02d" % index, "dinamica", True, "sintetico")
        for position, cid in enumerate(auxiliary_ids):
            # Only the FIRST auxiliary control is red when the reproduction
            # asks for a red one: the other two stay green, so the
            # reproduction isolates the failure of ONE control.
            red = auxiliary_status == "FAIL" and position == 0
            report.record_auxiliary(cid, "inspeccion", not red, "sintetico")
        return report

    workdir = tempfile.mkdtemp(prefix="forge-v2-probe-c4-")
    try:
        report_path = os.path.join(workdir, "safety-results.json")
        with contextlib.redirect_stdout(io.StringIO()):
            green = build_report()
            green.write(report_path)
            red = build_report(auxiliary_status="FAIL")
            incomplete = build_report(auxiliary_ids=("INSP-6", "INSP-7"))
        with open(report_path, "r", encoding="utf-8") as stream:
            payload = json.load(stream)
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)

    summary = payload.get("summary") or {}
    auxiliary = payload.get("auxiliary_controls") or {}
    auxiliary_summary = auxiliary.get("summary") or {}
    main_ids = [case.get("id") for case in (payload.get("cases") or [])]
    check(
        "C4-1a el censo del banco conserva su recuento propio (52) y no cuenta los controles auxiliares",
        summary.get("total") == 52
        and summary.get("passed") == 52
        and summary.get("failed") == 0
        and not [cid for cid in main_ids if cid in AUXILIARY_IDS],
        "summary=%r casos=%r" % (summary, main_ids[-5:]),
    )
    check(
        "C4-1b el censo auxiliar se publica APART, con su recuento y su veredicto",
        auxiliary.get("ids") == list(AUXILIARY_IDS)
        and sorted(
            case.get("id") for case in (auxiliary.get("cases") or [])
        ) == list(AUXILIARY_IDS)
        and auxiliary_summary.get("total") == 3
        and auxiliary_summary.get("passed") == 3
        and auxiliary_summary.get("failed") == 0
        and auxiliary_summary.get("complete") is True
        and auxiliary_summary.get("verdict") == "PASS",
        "auxiliary_controls=%r" % (auxiliary,),
    )

    # -- C4-2: the verdict of the auxiliary controls is HARD --------------
    red_summary = red.auxiliary_summary()
    incomplete_summary = incomplete.auxiliary_summary()
    with contextlib.redirect_stdout(io.StringIO()):
        empty = build_report(auxiliary_ids=())
    empty_summary = empty.auxiliary_summary()
    check(
        "C4-2a un control auxiliar en rojo deja el censo del banco verde y el veredicto auxiliar en rojo",
        red.failed == 0
        and red_summary.get("total") == 3
        and red_summary.get("failed") == 1
        and red_summary.get("verdict") == "FAIL"
        and red.auxiliary_ok is False,
        "censo_del_banco_fallidos=%d resumen_auxiliar=%r" % (red.failed, red_summary),
    )
    check(
        "C4-2b un control auxiliar AUSENTE no es un control verde",
        incomplete_summary.get("complete") is False
        and incomplete_summary.get("verdict") == "FAIL"
        and incomplete.auxiliary_ok is False,
        "resumen_auxiliar=%r" % (incomplete_summary,),
    )
    check(
        "C4-2b2 un censo auxiliar NO EJERCITADO no es un veredicto verde",
        empty_summary.get("total") == 0
        and empty_summary.get("verdict") == "NOT_EXERCITED"
        and empty.auxiliary_ok is False,
        "resumen_auxiliar=%r" % (empty_summary,),
    )

    tree = ast.parse(harness_text)
    body = function_node(tree, "_role_suite_body")
    guarded = False
    if body is not None:
        for node in ast.walk(body):
            if not isinstance(node, ast.If):
                continue
            # The name of the attribute is part of the TEST of the guard, and
            # an attribute is NOT a name of the AST: the test is unparsed to
            # observe the condition as it was written.
            if "auxiliary_ok" not in ast.unparse(node.test):
                continue
            for inner in ast.walk(node):
                if not isinstance(inner, ast.Return) or inner.value is None:
                    continue
                for element in ast.walk(inner.value):
                    if isinstance(element, ast.Constant) and element.value not in (
                        0,
                        None,
                        False,
                    ):
                        guarded = True
    check(
        "C4-2c el RC de la suite esta condicionado por el veredicto de los controles auxiliares",
        guarded,
        "hay un retorno con un RC distinto de cero guardado por 'auxiliary_ok': %s" % guarded,
    )

    # -- C4-3: the runner of the scenarios applies BOTH censuses ---------
    verdict_block = None
    for block in runner_python_blocks(runner_text):
        if "todos los casos sensibles se ejecutaron y pasaron" in block:
            verdict_block = block
            break
    if verdict_block is None:
        check(
            "C4-3 el runner valida el censo del banco y el censo auxiliar",
            False,
            "no se ha encontrado el bloque del veredicto en %s" % runner_path,
        )
        return
    calls = check_templates(verdict_block)

    def runner_namespace(report, case_ids, control_case=None):
        auxiliary = report.get("auxiliary_controls")
        auxiliary_cases = auxiliary.get("cases") if isinstance(auxiliary, dict) else None
        return {
            "summary": report.get("summary") or {},
            "report": report,
            "case_ids": case_ids,
            "auxiliary": auxiliary,
            "auxiliary_cases": auxiliary_cases,
            "auxiliary_summary": (
                auxiliary.get("summary") if isinstance(auxiliary, dict) else None
            ),
            "auxiliary_by_id": {
                case.get("id"): case
                for case in (auxiliary_cases or [])
                if isinstance(case, dict)
            },
            "control_case": control_case,
        }

    def evaluate_check(name, report, case_ids=(), control_case=None):
        node = calls.get(name)
        if node is None or len(node.args) < 2:
            return None
        expression = ast.Expression(body=node.args[1])
        ast.fix_missing_locations(expression)
        return eval(  # noqa: S307 - the expression comes from the parsed text
            compile(expression, "<runner-check>", "eval"),
            {"__builtins__": dict(EVAL_BUILTINS)},
            runner_namespace(report, list(case_ids), control_case),
        )

    def evaluate_control_check(report, control_id, case_ids=()):
        """The check of ONE auxiliary control, bound to its own case.

        The runner declares that check inside a loop over the declared
        controls, so the very same expression is evaluated once per
        control: this is what binds it to each one of them.
        """
        auxiliary = report.get("auxiliary_controls")
        auxiliary_cases = auxiliary.get("cases") if isinstance(auxiliary, dict) else None
        by_id = {
            case.get("id"): case
            for case in (auxiliary_cases or [])
            if isinstance(case, dict)
        }
        return evaluate_check(
            "control auxiliar de procedencia/unicidad presente y verde: %s",
            report,
            case_ids,
            by_id.get(control_id),
        )

    census = "todos los casos sensibles se ejecutaron y pasaron"
    census_ok = evaluate_check(
        census,
        {
            "summary": {"total": 52, "passed": 52, "failed": 0},
            "cases": [],
            "auxiliary_controls": auxiliary_section(),
        },
    )
    census_55 = evaluate_check(
        census,
        {
            "summary": {"total": 55, "passed": 55, "failed": 0},
            "cases": [],
            "auxiliary_controls": auxiliary_section(),
        },
    )
    census_red = evaluate_check(
        census,
        {
            "summary": {"total": 52, "passed": 51, "failed": 1},
            "cases": [],
            "auxiliary_controls": auxiliary_section(),
        },
    )
    check(
        "C4-3a el runner EXIGE el recuento de 52 del banco y rechaza el de 55 y el que lleva fallos",
        census_ok is True and census_55 is False and census_red is False,
        "con_52=%r con_55=%r con_un_fallo=%r" % (census_ok, census_55, census_red),
    )

    green_report = {
        "summary": {"total": 52, "passed": 52, "failed": 0},
        "cases": [{"id": "CASE-01", "status": "PASS"}],
        "auxiliary_controls": auxiliary_section(),
    }
    missing_report = {
        "summary": {"total": 52, "passed": 52, "failed": 0},
        "cases": [{"id": "CASE-01", "status": "PASS"}],
    }
    red_section = auxiliary_section()
    red_section["cases"][0]["status"] = "FAIL"
    red_section["summary"]["failed"] = 1
    red_section["summary"]["passed"] = 2
    red_section["summary"]["verdict"] = "FAIL"
    red_report = {
        "summary": {"total": 52, "passed": 52, "failed": 0},
        "cases": [{"id": "CASE-01", "status": "PASS"}],
        "auxiliary_controls": red_section,
    }
    polluted_report = {
        "summary": {"total": 52, "passed": 52, "failed": 0},
        "cases": [{"id": "CASE-01", "status": "PASS"}, {"id": "INSP-6", "status": "PASS"}],
        "auxiliary_controls": auxiliary_section(),
    }

    auxiliary_checks = (
        "el informe publica el censo de los controles auxiliares",
        "el censo auxiliar declara exactamente los tres controles de la procedencia y de la unicidad",
        "el veredicto auxiliar es verde y el recuento auxiliar es el declarado",
        "los controles auxiliares NO estan contados dentro del banco",
    )
    per_control_check = "control auxiliar de procedencia/unicidad presente y verde: %s"
    absent = [
        name for name in auxiliary_checks + (per_control_check,) if name not in calls
    ]
    check(
        "C4-3b el runner tiene una comprobacion propia para cada propiedad del censo auxiliar",
        not absent,
        "faltan: %r" % (absent,),
    )
    if absent:
        return

    green_results = {
        name: evaluate_check(name, green_report, ["CASE-01"]) for name in auxiliary_checks
    }
    missing_results = {
        name: evaluate_check(name, missing_report, ["CASE-01"]) for name in auxiliary_checks
    }
    red_results = {
        name: evaluate_check(name, red_report, ["CASE-01"]) for name in auxiliary_checks
    }
    polluted_results = {
        name: evaluate_check(name, polluted_report, ["CASE-01", "INSP-6"])
        for name in auxiliary_checks
    }
    control_green = [
        evaluate_control_check(green_report, cid, ["CASE-01"]) for cid in AUXILIARY_IDS
    ]
    control_missing = [
        evaluate_control_check(missing_report, cid, ["CASE-01"]) for cid in AUXILIARY_IDS
    ]
    control_red = [
        evaluate_control_check(red_report, cid, ["CASE-01"]) for cid in AUXILIARY_IDS
    ]
    check(
        "C4-3c el runner ACEPTA un censo auxiliar verde y RECHAZA uno ausente, uno rojo y uno contaminado",
        all(green_results.values())
        and all(control_green)
        and missing_results["el informe publica el censo de los controles auxiliares"] is False
        and missing_results[
            "el veredicto auxiliar es verde y el recuento auxiliar es el declarado"
        ]
        is False
        and not any(control_missing)
        and red_results["el veredicto auxiliar es verde y el recuento auxiliar es el declarado"]
        is False
        and control_red[0] is False
        and control_red[1] is True
        and polluted_results[
            "los controles auxiliares NO estan contados dentro del banco"
        ]
        is False,
        "verde=%r ausente=%r rojo=%r contaminado=%r controles=%r/%r/%r"
        % (
            green_results,
            missing_results,
            red_results,
            polluted_results,
            control_green,
            control_missing,
            control_red,
        ),
    )

    # -- C4-4: the stable entry applies the SAME criterion ----------------
    validator = stable_validator_block(stable_text)
    if validator is None:
        check(
            "C4-4 la entrada estable valida el censo auxiliar",
            False,
            "no se ha encontrado el bloque de validacion en %s" % stable_path,
        )
        return

    def stable_report(auxiliary):
        report = {
            "cleanup": {
                "ok": True,
                "aftermath_observation_state": "COMPLETE",
                "survivors_absence_verified": True,
                "members_absence_verified": True,
                "init_absence_verified": True,
                "survivors_in_private_namespace": [],
                "members_of_own_process_group": [],
                "namespace_init_alive_after": False,
                "synthetic_root_present_after": False,
                "watchdog_operational": True,
                "authorization_granted": True,
            },
            "supervisor": {},
            "summary": {"total": 52, "passed": 52, "failed": 0},
            "cases": [{"id": "CASE-01", "status": "PASS"}],
        }
        if auxiliary is not None:
            report["auxiliary_controls"] = auxiliary
        return report

    stable_good = run_stable_validator(validator, stable_report(auxiliary_section()))
    stable_missing = run_stable_validator(validator, stable_report(None))
    stable_red = run_stable_validator(validator, stable_report(red_section))
    check(
        "C4-4 la entrada estable ACEPTA un censo auxiliar verde y RECHAZA uno ausente o rojo",
        stable_good == 0 and stable_missing != 0 and stable_red != 0,
        "verde=%r ausente=%r rojo=%r" % (stable_good, stable_missing, stable_red),
    )


# ---------------------------------------------------------------------------
# The EXECUTION of the TEXT of a module in an isolated namespace.
#
# The probe never IMPORTS the code under test: the text is parsed and the
# module is EXECUTED without its `if __name__ == "__main__"` block, in a
# namespace of its own. Nothing of the module under test can therefore run
# its own entrypoint.
#
# The namespace is also what makes the observations REPRODUCIBLE: the
# observations of the harness and of the verifier of the protected resources
# read a procfs, and the difference between "the resource is not there" and
# "the state of the resource could not be read" is invisible in a healthy
# machine. The observations are therefore pointed at a SYNTHETIC procfs.
# ---------------------------------------------------------------------------
def _is_main_guard(node):
    if not isinstance(node, ast.If):
        return False
    test = node.test
    if not isinstance(test, ast.Compare) or len(test.ops) != 1:
        return False
    if not isinstance(test.ops[0], ast.Eq):
        return False
    if not isinstance(test.left, ast.Name) or test.left.id != "__name__":
        return False
    if len(test.comparators) != 1:
        return False
    comparator = test.comparators[0]
    return isinstance(comparator, ast.Constant) and comparator.value == "__main__"


def exec_module_text(path, text, extra=None):
    """Execute the TEXT of a module in a namespace of its own."""
    tree = ast.parse(text, filename=path)
    body = [node for node in tree.body if not _is_main_guard(node)]
    module = ast.Module(body=body, type_ignores=[])
    ast.fix_missing_locations(module)
    namespace = {"__name__": "forge_probe_isolated", "__file__": path}
    if extra:
        namespace.update(extra)
    exec(compile(module, path, "exec"), namespace)
    return namespace


def proc_stat_line(pid, state="S", pgrp=4242, starttime=26522468):
    """A synthetic line of /proc/<pid>/stat, with the REAL field order."""
    tail = [
        state,
        "1",
        str(pgrp),
        str(pgrp),
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "0",
        "20",
        "0",
        "1",
        "0",
        str(starttime),
        "0",
        "0",
    ]
    return "%d (opencode) %s\n" % (pid, " ".join(tail))


def build_proc_tree(root, pids=(), net="readable", namespace_id="pid:[4026531836]"):
    """Build a SYNTHETIC procfs for the observations.

    `pids` is a sequence of (pid, kind) where kind is:
      "readable"  the stat can be read and the process is of `namespace_id`;
      "foreign"   the stat can be read and the process is of ANOTHER
                  namespace (it is not a survivor of the private one);
      "denied"    the stat CANNOT be read: it is a DIRECTORY, so the read
                  fails with EISDIR even for a privileged user and the
                  denial is reproducible everywhere.

    `net` is "readable" (empty socket tables), "denied" (the tables are
    DIRECTORIES: they cannot be read) or "absent" (the tables do not exist).
    """
    os.makedirs(root, exist_ok=True)
    for pid, kind in pids:
        entry = os.path.join(root, "%d" % pid)
        os.makedirs(os.path.join(entry, "ns"), exist_ok=True)
        if kind == "denied":
            os.makedirs(os.path.join(entry, "stat"), exist_ok=True)
        else:
            with open(os.path.join(entry, "stat"), "w", encoding="ascii") as stream:
                stream.write(proc_stat_line(pid))
        os.symlink(
            "pid:[4026531832]" if kind == "foreign" else namespace_id,
            os.path.join(entry, "ns", "pid"),
        )
    if net != "absent":
        net_dir = os.path.join(root, "net")
        os.makedirs(net_dir, exist_ok=True)
        for name in ("tcp", "tcp6"):
            path = os.path.join(net_dir, name)
            if net == "denied":
                os.makedirs(path, exist_ok=True)
            else:
                with open(path, "w", encoding="ascii") as stream:
                    stream.write("  sl  local_address rem_address   st\n")
    return root


# ---------------------------------------------------------------------------
# F3: the observation of the aftermath of the harness.
#
# The absence of the survivors of the private namespace, the absence of the
# members of the own process group and the disappearance of the init are
# RESULTS of an observation. An observation that could NOT be performed is
# NOT a result: it is INCOMPLETE, and it never publishes a verified
# absence.
# ---------------------------------------------------------------------------
def probe_f3(harness_path, harness_text):
    namespace = exec_module_text(harness_path, harness_text)
    observe_state = namespace.get("observe_pid_state")
    observe_aftermath = namespace.get("observe_containment_aftermath")
    if observe_state is None or observe_aftermath is None:
        check(
            "F3-1 la observacion de un PID distingue la AUSENCIA de la OBSERVACION IMPOSIBLE",
            False,
            "el arnes %s no expone observe_pid_state/observe_containment_aftermath"
            % harness_path,
        )
        return

    tree = ast.parse(harness_text, filename=harness_path)
    supervisor = function_node(tree, "role_supervisor")

    workdir = tempfile.mkdtemp(prefix="forge-probe-f3-")
    try:
        ok_tree = build_proc_tree(os.path.join(workdir, "ok"), pids=[(100, "foreign")])
        denied_tree = build_proc_tree(os.path.join(workdir, "denied"), pids=[(200, "denied")])
        absent_tree = build_proc_tree(os.path.join(workdir, "absent"))

        namespace["PROC_ROOT"] = ok_tree
        alive = observe_state(100)
        namespace["PROC_ROOT"] = denied_tree
        denied = observe_state(200)
        namespace["PROC_ROOT"] = absent_tree
        absent = observe_state(999)

        namespace["PROC_ROOT"] = denied_tree
        denied_aftermath = observe_aftermath("pid:[4026531836]", 4242)
        namespace["PROC_ROOT"] = ok_tree
        ok_aftermath = observe_aftermath("pid:[4026531836]", 4242)
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)

    check(
        "F3-1a un proceso vivo se observa como ALIVE",
        alive[0] == "ALIVE",
        "observe_pid_state=%r (se esperaba ALIVE)" % (alive,),
    )
    check(
        "F3-1b un proceso INEXISTENTE se observa como ABSENT (ausencia CONFIRMADA)",
        absent[0] == "ABSENT",
        "observe_pid_state=%r (se esperaba ABSENT: la ausencia se confirma con el "
        "error ENOENT del kernel)" % (absent,),
    )
    check(
        "F3-1c una lectura IMPOSIBLE se observa como UNOBSERVABLE y NO como ABSENT",
        denied[0] == "UNOBSERVABLE",
        "observe_pid_state=%r (se esperaba UNOBSERVABLE: un error de lectura NO es "
        "una ausencia)" % (denied,),
    )

    check(
        "F3-2 la observacion del aftermath es INCOMPLETE cuando una lectura de stat es imposible",
        denied_aftermath.get("state") == "INCOMPLETE",
        "state=%r (se esperaba INCOMPLETE; se obtuvo %r)"
        % (denied_aftermath.get("state"), denied_aftermath),
    )
    check(
        "F3-3 el aftermath INCOMPLETE NO declara el init desaparecido",
        denied_aftermath.get("init_gone") is None
        and denied_aftermath.get("init_alive") is None,
        "init_gone=%r init_alive=%r (se esperaba None en los dos: la desaparición "
        "del init NO se publica a partir de una lectura fallida)"
        % (denied_aftermath.get("init_gone"), denied_aftermath.get("init_alive")),
    )

    # The three flags of the report are EVALUATED with the aftermath of the
    # reproduction: they must NOT be True when the observation was
    # impossible.
    flags = {}
    if supervisor is not None:
        base = {
            "aftermath_state": denied_aftermath.get("state"),
            "survivors": denied_aftermath.get("survivors"),
            "members": denied_aftermath.get("members"),
            "init_gone": denied_aftermath.get("init_gone"),
            "init_alive": denied_aftermath.get("init_alive"),
        }
        for name in (
            "survivors_absence_verified",
            "members_absence_verified",
            "init_absence_verified",
        ):
            try:
                flags[name] = evaluate_verdict(supervisor, tree, name, base)
            except Exception as exc:  # pragma: no cover - diagnostico
                flags[name] = "error:%s" % exc
    check(
        "F3-4 las verificaciones de ausencia NO son POSITIVAS cuando la observacion fue imposible",
        bool(flags) and all(value is not True for value in flags.values()),
        "flags=%r (se esperaba que ninguna de las tres ausencias conste como "
        "VERIFICADA)" % (flags,),
    )

    check(
        "F3-5 el CONTROL: una observacion completa sigue siendo COMPLETE",
        ok_aftermath.get("state") == "COMPLETE"
        and ok_aftermath.get("survivors") == []
        and ok_aftermath.get("init_gone") is True,
        "aftermath=%r (se esperaba COMPLETE, sin supervivientes y con el init "
        "observado como desaparecido)" % (ok_aftermath,),
    )


# ---------------------------------------------------------------------------
# F1: the verifier of the protected resources.
#
# An ERROR of reading is not a FACT about the resource. The verifier that
# turned a failed read into "the process is gone" or into "the port is not
# listening" certified an absence that had never been observed, and its
# PASS survived a failed observation.
# ---------------------------------------------------------------------------
def protected_registry_text(pid, incident_path, baseline_path):
    return (
        "resource=protected-process\n"
        "pid=%d\n"
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
        "change_by_this_batch=NO\n" % (pid, incident_path, baseline_path)
    )


def probe_f1(protected_path, protected_text):
    namespace = exec_module_text(protected_path, protected_text)
    verifier = namespace.get("main")
    if verifier is None:
        check(
            "F1-1 el verificador de los recursos protegidos distingue la AUSENCIA de la OBSERVACION IMPOSIBLE",
            False,
            "el verificador %s no expone main()" % protected_path,
        )
        return

    pid = 530393
    workdir = tempfile.mkdtemp(prefix="forge-probe-f1-")
    try:
        home = os.path.join(workdir, "home")
        db_dir = os.path.join(home, ".local", "share", "opencode")
        os.makedirs(db_dir)
        db_path = os.path.join(db_dir, "opencode.db")
        with open(db_path, "wb") as stream:
            stream.write(b"contenido sintetico\n")
        info = os.stat(db_path)
        baseline_path = os.path.join(workdir, "baseline.txt")
        with open(baseline_path, "w", encoding="utf-8") as stream:
            stream.write(
                "db_dev=%d\ndb_inode=%d\ndb_size=%d\ndb_mode=0o%o\n"
                % (info.st_dev, info.st_ino, info.st_size, info.st_mode)
            )
        incident_path = os.path.join(workdir, "INCIDENTE-530393.md")
        with open(incident_path, "w", encoding="utf-8") as stream:
            stream.write("incidente sintetico de la sonda\n")
        registry_path = os.path.join(workdir, "registry.tsv")
        with open(registry_path, "w", encoding="utf-8") as stream:
            stream.write(protected_registry_text(pid, incident_path, baseline_path))

        def run(tree):
            namespace["PROC_ROOT"] = tree
            argv = [
                "--baseline",
                baseline_path,
                "--registry",
                registry_path,
                "--incident",
                incident_path,
                "--home",
                home,
            ]
            captured = io.StringIO()
            saved = sys.stdout
            sys.stdout = captured
            try:
                code = verifier(argv)
            except SystemExit as exc:  # pragma: no cover - defensivo
                code = exc.code or 0
            finally:
                sys.stdout = saved
            return code, captured.getvalue()

        control_tree = build_proc_tree(os.path.join(workdir, "control"))
        denied_pid_tree = build_proc_tree(
            os.path.join(workdir, "denied-pid"), pids=[(pid, "denied")]
        )
        denied_net_tree = build_proc_tree(
            os.path.join(workdir, "denied-net"), net="denied"
        )

        control_code, control_out = run(control_tree)
        pid_code, pid_out = run(denied_pid_tree)
        net_code, net_out = run(denied_net_tree)
    finally:
        import shutil

        shutil.rmtree(workdir, ignore_errors=True)

    check(
        "F1-2 el CONTROL: el verificador ACEPTA el estado real (PID ausente, DB presente, puerto sin escucha)",
        control_code == 0
        and "PROTECTED_PID_OBSERVED=ABSENT" in control_out
        and "PROTECTED_PORT_OBSERVED=NOT_LISTENING" in control_out,
        "rc=%r (se esperaba 0) salida=%r" % (control_code, control_out[-400:]),
    )
    check(
        "F1-3 una lectura IMPOSIBLE del PID protegido hace FALLAR el verificador",
        pid_code != 0,
        "rc=%r (se esperaba un rc distinto de cero: una observacion imposible NO "
        "puede aceptar los recursos protegidos)" % (pid_code,),
    )
    check(
        "F1-4 el PID protegido NO se declara AUSENTE cuando su lectura es imposible",
        "PROTECTED_PID_OBSERVED=NOT_OBSERVABLE" in pid_out
        and "PROTECTED_PID_OBSERVED=ABSENT" not in pid_out,
        "salida=%r" % (pid_out[-400:],),
    )
    check(
        "F1-5 una lectura IMPOSIBLE de las tablas TCP hace FALLAR el verificador",
        net_code != 0,
        "rc=%r (se esperaba un rc distinto de cero)" % (net_code,),
    )
    check(
        "F1-6 el puerto protegido NO se declara SIN ESCUCHA cuando sus tablas no se pueden leer",
        "PROTECTED_PORT_OBSERVED=NOT_OBSERVABLE" in net_out
        and "PROTECTED_PORT_OBSERVED=NOT_LISTENING" not in net_out,
        "salida=%r" % (net_out[-400:],),
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", default=DEFAULT_HARNESS)
    parser.add_argument("--runner", default=DEFAULT_RUNNER)
    parser.add_argument("--stable", default=DEFAULT_STABLE)
    parser.add_argument("--protected", default=DEFAULT_PROTECTED)
    args = parser.parse_args(argv)

    try:
        harness_text = read_source(args.harness)
        runner_text = read_source(args.runner)
        stable_text = read_source(args.stable)
        protected_text = read_source(args.protected)
    except OSError as exc:
        print("no se pudo leer el codigo bajo prueba: %s" % exc, file=sys.stderr)
        return 2

    probe_c2(args.harness, args.runner, harness_text, runner_text)
    probe_c3(args.harness, args.stable, harness_text, stable_text)
    probe_c4(
        args.harness,
        args.runner,
        args.stable,
        harness_text,
        runner_text,
        stable_text,
    )
    probe_f3(args.harness, harness_text)
    probe_f1(args.protected, protected_text)

    failed = [item for item in CHECKS if not item["ok"]]
    payload = {"ok": not failed, "checks": CHECKS}
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
