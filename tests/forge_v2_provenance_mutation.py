#!/usr/bin/env python3
"""tests/forge_v2_provenance_mutation.py — sensitivity of the CRITERIA of
provenance and of uniqueness of the versioned component.

The bank of V2 certifies TWO properties that the harness of the bank states
in its inspection (INSP-2 and INSP-3):

  * the PROVENANCE of the module that the bench loaded: it has to BE the
    file that the repository versions, and an external path or a copy has to
    be a FAILURE, not an informative note;
  * the UNIQUENESS of the versioned component inside the checkout: exactly
    one copy of every implementation file of the component, and that copy is
    the canonical one.

A criterion that cannot be red certifies nothing. This suite proves that
the criteria of the bank CAN be red, and it does it the only honest way: it
MUTATES COPIES of the harness (never the repository) and observes that the
expected control goes red.

WHAT IT DOES
------------

1. It EXTRACTS the criterion of the harness from its TEXT, with the abstract
   syntax tree. It never imports the harness: the import of a module runs
   its top level, and this suite does not want that. The extraction is
   restricted to the pure functions of the criterion and to the constants
   they use.

2. It builds a SYNTHETIC checkout under a temporary directory, with the
   canonical layout of the versioned component, with a byte exact copy of
   the component OUTSIDE of it and with three planted duplicates inside it.

3. It runs the CONTROLS over the pristine criterion: all of them have to be
   GREEN.

4. It applies every MUTATION to a COPY of the harness written OUTSIDE the
   repository, and it observes that the EXPECTED control goes RED on the
   mutant while it was GREEN on the pristine. The attribution is clean: the
   suite states, for every mutation, which control changed and which ones
   did not.

The repository is NEVER modified: the mutated copies are written under the
temporary directory of the suite and they are removed with it.

Usage:
  python3 tests/forge_v2_provenance_mutation.py

Environment:
  FORGE_V2_PROVENANCE_WORKDIR    parent of the temporary directory of the
                                  suite (default: the temporary directory of
                                  the process).
  FORGE_V2_PROVENANCE_EVIDENCE   file of the evidence (JSON). Default:
                                  <workdir>/forge-v2-provenance-evidence.json

Exit codes:
  0  every control is green on the pristine criterion and every mutation is
     detected by its expected control
  1  a control is red on the pristine criterion, or a mutation was NOT
     detected by its expected control
  2  the harness could not be read or the criterion could not be extracted
"""

import ast
import hashlib
import json
import os
import shutil
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HARNESS_PATH = os.path.join(REPO_ROOT, "tests", "forge_v2_safety_harness.py")

WANTED_FUNCTIONS = (
    "sha256_file",
    "verify_module_provenance",
    "find_component_duplicates",
)
WANTED_CONSTANTS = (
    "PLUGIN_SYNC_REL",
    "CUTOVER_SAFETY_REL",
    "CANONICAL_COMPONENT_REL",
    "CANONICAL_COMPONENT_FILES",
    "CHECKOUT_SCAN_EXCLUDED_DIRS",
)

# The layout of the synthetic checkout: the same relative paths that the
# repository versions, so that the declared reference of the criterion
# exists in it.
FIXTURE_LAYOUT = (
    ("tools/cutover/forge-v2/lib/cutover_safety.py", "cutover_safety"),
    ("tools/cutover/forge-v2/lib/dbtool.py", "dbtool"),
    ("tools/cutover/forge-v2/cutover.sh", "cutover"),
    ("tools/cutover/forge-v2/ROLLBACK.sh", "rollback"),
    ("open-code/lib/plugin-sync.py", "plugin_sync"),
)

SAFETY_REL = "tools/cutover/forge-v2/lib/cutover_safety.py"
PLUGIN_REL = "open-code/lib/plugin-sync.py"

# The planted duplicates of the synthetic checkout.
PLANTED_SAME_NAME = "otro/cutover_safety.py"
PLANTED_RENAMED = "otro/renamed_component.py"
PLANTED_PLUGIN = "otro/plugin-sync.py"


# ---------------------------------------------------------------------------
# The extraction of the criterion.
# ---------------------------------------------------------------------------
def extract_criterion(source_text, label):
    """The namespace with the criterion of the harness, from its TEXT.

    The harness is never imported: only the pure functions of the criterion
    and the constants they use are compiled, and they are executed in a
    namespace of their own. The top level of the harness is never run.
    """
    tree = ast.parse(source_text, filename=label)
    body = []
    found = set()
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name in WANTED_FUNCTIONS:
            body.append(node)
            found.add(node.name)
        elif isinstance(node, ast.Assign):
            names = [target.id for target in node.targets if isinstance(target, ast.Name)]
            if any(name in WANTED_CONSTANTS for name in names):
                body.append(node)
                found.update(name for name in names if name in WANTED_CONSTANTS)
    missing = [
        name for name in tuple(WANTED_FUNCTIONS) + tuple(WANTED_CONSTANTS) if name not in found
    ]
    if missing:
        raise RuntimeError("el arnes no expone el criterio: faltan %r" % (missing,))
    module = ast.Module(body=body, type_ignores=[])
    ast.fix_missing_locations(module)
    namespace = {"os": os, "hashlib": hashlib, "__name__": "forge_v2_harness_criterion"}
    exec(compile(module, label, "exec"), namespace)
    # The source itself travels with the criterion: the wiring control has
    # to read the text of the harness that it is checking, and the text of
    # a MUTANT is not the text of the repository.
    namespace["__source__"] = source_text
    return namespace


def case_inspection_source(source_text):
    """The source of the ``case_inspection`` of the harness."""
    tree = ast.parse(source_text)
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "case_inspection":
            return ast.get_source_segment(source_text, node) or ""
    return ""


# ---------------------------------------------------------------------------
# The fixture.
# ---------------------------------------------------------------------------
class Fixture(object):
    """The synthetic checkout of the suite."""

    def __init__(self, root):
        self.root = root
        self.checkout = os.path.join(root, "checkout")
        self.external = os.path.join(root, "external", "lib", "cutover_safety.py")
        self.planted_same_name = None
        self.planted_renamed = None
        self.planted_plugin = None
        self._build()

    def _write(self, rel, content):
        path = os.path.join(self.checkout, rel)
        directory = os.path.dirname(path)
        if not os.path.isdir(directory):
            os.makedirs(directory, 0o700)
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(content)
        return path

    def _build(self):
        contents = {}
        for rel, marker in FIXTURE_LAYOUT:
            body = "# fixture sintetico: %s\n%s\n" % (rel, marker * 64)
            contents[rel] = body
            self._write(rel, body)
        # The byte exact copy of the component, OUTSIDE the checkout.
        external_dir = os.path.dirname(self.external)
        if not os.path.isdir(external_dir):
            os.makedirs(external_dir, 0o700)
        with open(self.external, "w", encoding="utf-8") as stream:
            stream.write(contents[SAFETY_REL])
        # The planted duplicates INSIDE the checkout.
        self.planted_same_name = self._write(PLANTED_SAME_NAME, contents[SAFETY_REL])
        self.planted_renamed = self._write(PLANTED_RENAMED, contents[SAFETY_REL])
        self.planted_plugin = self._write(PLANTED_PLUGIN, contents[PLUGIN_REL])

    def canonical(self, rel):
        return os.path.join(self.checkout, rel)


def entry_for(namespace, entries, rel):
    """The entry of the canonical file ``rel`` inside the result of the scan."""
    for entry in entries:
        if entry["canonical"].replace(os.sep, "/").endswith(rel):
            return entry
    return None


# ---------------------------------------------------------------------------
# The controls. Every one of them is a property that the criterion has to
# satisfy, and every one of them has a way of being FALSE.
# ---------------------------------------------------------------------------
def control_accept(namespace, fixture):
    """The legitimate copy of the versioned component IS accepted."""
    ok, detail = namespace["verify_module_provenance"](
        fixture.checkout, fixture.canonical(SAFETY_REL), SAFETY_REL
    )
    return ok, detail


def control_reject(namespace, fixture):
    """A byte exact copy OUTSIDE the checkout is REJECTED."""
    ok, detail = namespace["verify_module_provenance"](
        fixture.checkout, fixture.external, SAFETY_REL
    )
    return (not ok), detail


def control_declared(namespace, fixture):
    """A reference that is NOT one of the declared canonical files is rejected.

    The reference of this control is an EXISTING file of the checkout (the
    planted renamed copy), so that the ONLY thing that can reject it is the
    declaration of the reference: a criterion that accepted any regular file
    would let a caller point the bench at an arbitrary implementation.
    """
    ok, detail = namespace["verify_module_provenance"](
        fixture.checkout, fixture.planted_renamed, PLANTED_RENAMED
    )
    return (not ok), detail


def control_duplicate_name(namespace, fixture):
    """A copy with the SAME NAME is detected."""
    entries = namespace["find_component_duplicates"](fixture.checkout, (SAFETY_REL,))
    entry = entry_for(namespace, entries, SAFETY_REL)
    found = bool(entry) and fixture.planted_same_name in entry["name_copies"]
    return found, "name_copies=%r" % (entry["name_copies"] if entry else None,)


def control_duplicate_content(namespace, fixture):
    """A copy with ANOTHER NAME and the same content is detected."""
    entries = namespace["find_component_duplicates"](fixture.checkout, (SAFETY_REL,))
    entry = entry_for(namespace, entries, SAFETY_REL)
    found = bool(entry) and fixture.planted_renamed in entry["content_copies"]
    return found, "content_copies=%r" % (entry["content_copies"] if entry else None,)


def control_duplicate_plugin(namespace, fixture):
    """A copy of plugin-sync.py is detected: the set covers BOTH components."""
    declared = namespace["CANONICAL_COMPONENT_FILES"]
    entries = namespace["find_component_duplicates"](fixture.checkout, declared)
    entry = entry_for(namespace, entries, PLUGIN_REL)
    found = bool(entry) and (
        fixture.planted_plugin in entry["name_copies"]
        or fixture.planted_plugin in entry["content_copies"]
    )
    return found, "declarado=%r entrada=%r" % (list(declared), entry)


def control_real_checkout(namespace, fixture):
    """The REAL checkout accepts its canonical file and has no duplicate."""
    canonical = os.path.join(REPO_ROOT, namespace["CANONICAL_COMPONENT_REL"])
    ok, detail = namespace["verify_module_provenance"](
        REPO_ROOT, canonical, namespace["CANONICAL_COMPONENT_REL"]
    )
    entries = namespace["find_component_duplicates"](
        REPO_ROOT, namespace["CANONICAL_COMPONENT_FILES"]
    )
    duplicates = [
        (entry["canonical"], entry["name_copies"], entry["content_copies"])
        for entry in entries
        if entry["name_copies"] or entry["content_copies"]
    ]
    return (ok and not duplicates), "procedencia=%s duplicados=%r" % (ok, duplicates)


def control_wiring(namespace, fixture):
    """The criterion is really WIRED in the inspection of the bank.

    A criterion that nothing calls certifies nothing, and a criterion that
    is called with the tree the bench was pointed at is the tautology again.
    """
    source = namespace["__source__"]
    inspection = case_inspection_source(source)
    problems = []
    if "verify_module_provenance" not in inspection:
        problems.append("la inspeccion no llama a verify_module_provenance")
    if "find_component_duplicates" not in inspection:
        problems.append("la inspeccion no llama a find_component_duplicates")
    if "CANONICAL_COMPONENT_FILES" not in inspection:
        problems.append("la inspeccion no usa el conjunto completo del componente")
    tree = ast.parse(source)
    calls = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if not isinstance(node.func, ast.Name):
            continue
        if node.func.id != "verify_module_provenance":
            continue
        calls.append(node)
    if not calls:
        problems.append("no hay ninguna llamada a verify_module_provenance")
    for call in calls:
        for argument in call.args:
            segment = ast.get_source_segment(source, argument) or ""
            if "external_root" in segment:
                problems.append(
                    "una llamada usa el arbol externo como referencia: %r" % segment
                )
        if len(call.args) >= 3:
            reference = call.args[2]
            # The reference has to be a NAME: the loop variable that the
            # inspection binds to the declared constants. An EXPRESSION
            # built from the loaded module (or from the tree the bench was
            # pointed at) would be the tautology.
            if not isinstance(reference, ast.Name):
                problems.append(
                    "la referencia de una llamada no es un nombre: %r"
                    % (ast.get_source_segment(source, reference),)
                )
    for constant in ("PLUGIN_SYNC_REL", "CANONICAL_COMPONENT_REL"):
        if constant not in inspection:
            problems.append("la inspeccion no declara la referencia %s" % constant)
    return (not problems), "problemas=%r" % (problems,)


CONTROLS = (
    ("C-ACCEPT", control_accept),
    ("C-REJECT", control_reject),
    ("C-DECLARED", control_declared),
    ("C-DUP-NAME", control_duplicate_name),
    ("C-DUP-CONTENT", control_duplicate_content),
    ("C-DUP-PLUGIN", control_duplicate_plugin),
    ("C-REAL", control_real_checkout),
    ("C-WIRING", control_wiring),
)


# ---------------------------------------------------------------------------
# The mutations. Each one is a textual change of the harness, and each one
# has to be DETECTED by one control and by one control only.
# ---------------------------------------------------------------------------
MUTATIONS = (
    (
        "M1",
        "el veredicto de la procedencia es siempre verde (la procedencia deja de ser un fallo)",
        "    ok = all(item[1] for item in checks)\n    detail = \"; \".join(",
        "    ok = True\n    detail = \"; \".join(",
        "C-REJECT",
    ),
    (
        "M2",
        "la referencia de la procedencia se deriva del modulo cargado (la tautologia)",
        "    canonical_abs = os.path.join(repo_abs, canonical_rel_path)\n",
        "    canonical_abs = loaded_abs\n",
        "C-REJECT",
    ),
    (
        "M3",
        "la identidad de ruta de la procedencia se declara siempre cierta",
        "    path_identity = bool(loaded_real) and loaded_real == canonical_real\n",
        "    path_identity = True\n",
        "C-REJECT",
    ),
    (
        "M4",
        "la unicidad ignora el componente de plugin-sync",
        "CANONICAL_COMPONENT_FILES = (\n"
        '    os.path.join("tools", "cutover", "forge-v2", CUTOVER_SAFETY_REL),\n'
        '    os.path.join("tools", "cutover", "forge-v2", "lib", "dbtool.py"),\n'
        '    os.path.join("tools", "cutover", "forge-v2", "cutover.sh"),\n'
        '    os.path.join("tools", "cutover", "forge-v2", "ROLLBACK.sh"),\n'
        "    PLUGIN_SYNC_REL,\n"
        ")\n",
        "CANONICAL_COMPONENT_FILES = (\n"
        '    os.path.join("tools", "cutover", "forge-v2", CUTOVER_SAFETY_REL),\n'
        ")\n",
        "C-DUP-PLUGIN",
    ),
    (
        "M5",
        "la unicidad ignora las copias por contenido (una copia renombrada no se detecta)",
        "                if sha256_file(candidate) == digest:\n",
        "                if sha256_file(candidate) == digest and False:\n",
        "C-DUP-CONTENT",
    ),
    (
        "M6",
        "la unicidad ignora las copias por nombre (una copia con el mismo nombre no se detecta)",
        "            if os.path.basename(candidate) == base_name:\n",
        "            if os.path.basename(candidate) == base_name and False:\n",
        "C-DUP-NAME",
    ),
    (
        "M7",
        "la procedencia acepta una referencia que no esta declarada",
        "    reference_declared = canonical_rel_path in CANONICAL_COMPONENT_FILES\n",
        "    reference_declared = True\n",
        "C-DECLARED",
    ),
)


def apply_mutation(source_text, old, new, label):
    """The source with the mutation applied, or an error when it is ambiguous."""
    occurrences = source_text.count(old)
    if occurrences != 1:
        raise RuntimeError(
            "la mutacion %s no es unívoca: %d apariciones de %r" % (label, occurrences, old[:60])
        )
    return source_text.replace(old, new, 1)


# ---------------------------------------------------------------------------
def main():
    workdir_parent = os.environ.get("FORGE_V2_PROVENANCE_WORKDIR") or tempfile.gettempdir()
    evidence_path = os.environ.get("FORGE_V2_PROVENANCE_EVIDENCE") or os.path.join(
        workdir_parent, "forge-v2-provenance-evidence.json"
    )
    work = tempfile.mkdtemp(prefix="forge-v2-provenance-", dir=workdir_parent)
    evidence = {
        "harness": HARNESS_PATH,
        "workdir": work,
        "controls": [],
        "mutations": [],
        "problems": [],
    }
    try:
        with open(HARNESS_PATH, "r", encoding="utf-8") as stream:
            harness_source = stream.read()
        fixture = Fixture(work)

        try:
            pristine = extract_criterion(harness_source, HARNESS_PATH)
        except (SyntaxError, RuntimeError) as exc:
            evidence["problems"].append("el criterio no se pudo extraer: %s" % exc)
            write_evidence(evidence_path, evidence)
            print("FALLO: el criterio del arnes no se pudo extraer: %s" % exc)
            return 2

        # -- the controls over the pristine criterion ----------------------
        pristine_state = {}
        for name, function in CONTROLS:
            try:
                ok, detail = function(pristine, fixture)
            except Exception as exc:  # noqa: BLE001 - the suite reports it
                ok, detail = False, "excepcion: %s" % exc
            pristine_state[name] = ok
            evidence["controls"].append(
                {"control": name, "mutant": None, "ok": bool(ok), "detail": str(detail)}
            )
            print("[%s] %s :: %s" % (name, "PASS" if ok else "FAIL", detail))
            if not ok:
                evidence["problems"].append("control rojo sobre el criterio intacto: %s" % name)

        # -- the mutations --------------------------------------------------
        for mutation_id, description, old, new, expected in MUTATIONS:
            record = {
                "mutation": mutation_id,
                "description": description,
                "expected_control": expected,
                "detected": False,
                "changed": [],
                "unchanged": [],
                "copy": None,
            }
            try:
                mutated_source = apply_mutation(harness_source, old, new, mutation_id)
            except RuntimeError as exc:
                record["detail"] = str(exc)
                evidence["mutations"].append(record)
                evidence["problems"].append("mutacion %s no aplicable: %s" % (mutation_id, exc))
                print("[%s] FAIL :: la mutacion no es aplicable: %s" % (mutation_id, exc))
                continue
            # The mutated copy is written OUTSIDE the repository and it is
            # the file that is parsed: the repository is never modified.
            copy_dir = os.path.join(work, "mutants", mutation_id, "tests")
            if not os.path.isdir(copy_dir):
                os.makedirs(copy_dir, 0o700)
            copy_path = os.path.join(copy_dir, "forge_v2_safety_harness.py")
            with open(copy_path, "w", encoding="utf-8") as stream:
                stream.write(mutated_source)
            record["copy"] = copy_path
            try:
                mutant = extract_criterion(mutated_source, copy_path)
            except (SyntaxError, RuntimeError) as exc:
                record["detail"] = "el mutante no se pudo extraer: %s" % exc
                evidence["mutations"].append(record)
                evidence["problems"].append("mutacion %s ilegible: %s" % (mutation_id, exc))
                print("[%s] FAIL :: %s" % (mutation_id, record["detail"]))
                continue
            mutant_state = {}
            for name, function in CONTROLS:
                try:
                    ok, detail = function(mutant, fixture)
                except Exception as exc:  # noqa: BLE001 - the suite reports it
                    ok, detail = False, "excepcion: %s" % exc
                mutant_state[name] = bool(ok)
                evidence["controls"].append(
                    {"control": name, "mutant": mutation_id, "ok": bool(ok), "detail": str(detail)}
                )
                if bool(ok) != pristine_state[name]:
                    record["changed"].append(name)
                else:
                    record["unchanged"].append(name)
            detected = pristine_state.get(expected, False) and not mutant_state.get(expected, True)
            record["detected"] = detected
            record["detail"] = "control_esperado=%s verde_intacto=%s rojo_mutante=%s" % (
                expected,
                pristine_state.get(expected),
                not mutant_state.get(expected, True),
            )
            evidence["mutations"].append(record)
            if not detected:
                evidence["problems"].append(
                    "la mutacion %s NO fue detectada por su control esperado (%s)" % (mutation_id, expected)
                )
            print(
                "[%s] %s :: %s | cambio=%r"
                % (
                    mutation_id,
                    "DETECTADA" if detected else "NO DETECTADA",
                    description,
                    record["changed"],
                )
            )
    finally:
        shutil.rmtree(work, ignore_errors=True)
        evidence["workdir_removed"] = not os.path.isdir(work)

    write_evidence(evidence_path, evidence)
    if evidence["problems"]:
        print("")
        print("FALLO: %d problema(s):" % len(evidence["problems"]))
        for problem in evidence["problems"]:
            print("  - %s" % problem)
        print("evidencia: %s" % evidence_path)
        return 1
    print("")
    print(
        "PASS: %d controles verdes y %d mutaciones detectadas (evidencia: %s)"
        % (len(CONTROLS), len(MUTATIONS), evidence_path)
    )
    return 0


def write_evidence(path, evidence):
    directory = os.path.dirname(os.path.abspath(path))
    if directory and not os.path.isdir(directory):
        os.makedirs(directory, 0o700)
    with open(path, "w", encoding="utf-8") as stream:
        json.dump(evidence, stream, indent=2, sort_keys=True, ensure_ascii=False)
        stream.write("\n")


if __name__ == "__main__":
    sys.exit(main())
