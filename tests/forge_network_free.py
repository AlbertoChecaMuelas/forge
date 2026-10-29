#!/usr/bin/env python3
"""tests/forge_network_free.py — the scanner of the primitives of the NETWORK.

The battery of the suites must not use the network, NOT EVEN the loopback
interface: a fixture that opens a socket and listens on 127.0.0.1 performs
activity of network, and the prohibition of this lot is not a prohibition of
the traffic to the outside only.

This scanner looks for the primitives of the network in the tree of the
suites and prints every hit with its file and its line. It is STATIC: it
never executes anything and it never touches a process.

TWO recognitions, because a single one of them is not enough:

  * The PYTHON files are read with the ABSTRACT SYNTAX TREE. The scanner
    recognises the IMPORTS (the module and the form of the import), the
    ALIASES (`import urllib.request as ur`, `from urllib.request import
    urlopen as u`) and the ENTRIES of the network (the call of the module,
    of the alias and of the imported name). A scanner that only looked for
    the TEXT of the primitives missed `from urllib.request import urlopen`
    followed by `urlopen(...)` and `import requests` followed by
    `requests.request(...)`: both are real uses of the network and both
    were invisible.

  * The SHELL files are read with the patterns of the primitives: a shell
    suite can open a socket or make a request without any Python in it.

A comment line (the first non-blank character is a "#") is never a hit: a
comment that TALKS about the network does not use it.

It never scans ITSELF: the patterns that it looks for are, by definition, in
its own source, and a COPY of it (the one that the sensitivity harness
mutates) carries the same marker. A file that carries the marker is skipped.

THE EFFECTIVE RESTRICTION
-------------------------

The static scanner proves that the CODE of the battery does not contain the
primitives of the network. That is a property of the SOURCE, and a source
can be true while the EXECUTION is not: a primitive that arrives through a
dependency, through an alias that the scanner does not know or through a
helper that the scanner never read would pass the scan and use the network.

So the scanner ALSO knows how to WRITE a restriction that makes the network
UNAVAILABLE while the battery runs: the primitives are substituted by DOUBLES
that REFUSE and the resolution of names is disabled. The restriction is
installed by a `sitecustomize` of its own directory, and the directory also
carries a wrapper of the interpreter that puts it in the path of the
interpreter. The restriction is VERIFIED when it is written: the primitives
are attempted and their refusal is observed.

Usage:
  python3 tests/forge_network_free.py <file-or-dir> [...]
      Prints "<file>:<line>: <text>" for every primitive found.
      RC 1 when there is at least one, RC 0 otherwise.

  python3 tests/forge_network_free.py guard <directory>
      Writes the restriction of the network in <directory> and VERIFIES it.
      RC 0 when the restriction is effective, RC 1 otherwise.
"""

import ast
import os
import re
import subprocess
import sys

# The marker of this scanner. A file that carries it is a copy of the
# scanner and it is never scanned: the patterns that it looks for are, by
# definition, in its own source.
SCANNER_MARKER = "forge-network-free-scanner"

# The modules whose API IS the network.
NETWORK_MODULES = frozenset(
    {
        "socket",
        "ssl",
        "requests",
        "httpx",
        "urllib3",
        "ftplib",
        "smtplib",
        "telnetlib",
        "xmlrpc",
        "aiohttp",
        "websockets",
        "http.client",
        "http.server",
        "urllib.request",
        "urllib.error",
    }
)

# The packages whose submodules can be the network. `from urllib import
# request` binds a network module under a name of its own.
NETWORK_PACKAGES = frozenset({"urllib", "http"})

# The primitives of the network in a SHELL file. They are CODE, not prose.
SHELL_PATTERNS = [
    r"socket\.socket\s*\(",
    r"socket\.create_connection",
    r"socket\.socketpair",
    r"urllib\.request\.urlopen",
    r"urllib3",
    r"requests\.(get|post|put|delete)\(",
    r"httpx\.",
    r"(^|[^A-Za-z0-9_])http\.client\.",
    r"(^|[^A-Za-z0-9_])import\s+socket(\s|$)",
    r"(^|[^A-Za-z0-9_])from\s+socket\s+import",
    r"(^|[^A-Za-z0-9_])import\s+urllib\.request",
    r"(^|[^A-Za-z0-9_])import\s+http\.client",
    # The listeners of the network. The command is `nc` or `netcat` and it
    # is followed by its options: a loose `nc ... -l` matched prose (the
    # `nc` of `jsonc` followed by a `-l` of any word), and a scanner that
    # cries wolf is not a scanner.
    r"(^|[^A-Za-z0-9_.-])nc(\s+-[A-Za-z-]+)*\s+-l\b",
    r"(^|[^A-Za-z0-9_.-])netcat(\s+-[A-Za-z-]+)*\s+-l\b",
    r"(^|[^A-Za-z0-9_])curl\s+.*https?://",
    # The IMPORTS of the network, in ANY of their forms.
    r"(^|[^A-Za-z0-9_])import\s+requests(\s|$)",
    r"(^|[^A-Za-z0-9_])import\s+httpx(\s|$)",
    r"(^|[^A-Za-z0-9_])import\s+urllib(\.[A-Za-z_]+)*(\s|$)",
    r"(^|[^A-Za-z0-9_])from\s+urllib(\.[A-Za-z_]+)*\s+import",
    r"(^|[^A-Za-z0-9_])from\s+requests\s+import",
    r"(^|[^A-Za-z0-9_])from\s+httpx\s+import",
    r"(^|[^A-Za-z0-9_])from\s+http(\.[A-Za-z_]+)*\s+import",
    # The ENTRIES of the network, with or without the module in front.
    r"(^|[^A-Za-z0-9_])urlopen\s*\(",
    r"(^|[^A-Za-z0-9_])urlretrieve\s*\(",
    r"(^|[^A-Za-z0-9_])requests\.[A-Za-z_]+\s*\(",
    r"(^|[^A-Za-z0-9_])httpx\.[A-Za-z_]+\s*\(",
]

# The same primitives, applied to the text of a Python file when the
# ABSTRACT SYNTAX TREE cannot be built (a file that does not parse).
PYTHON_PATTERNS = [
    r"(^|[^A-Za-z0-9_])import\s+socket(\s|$)",
    r"(^|[^A-Za-z0-9_])from\s+socket\s+import",
    r"(^|[^A-Za-z0-9_])import\s+urllib(\.[A-Za-z_]+)*(\s|$)",
    r"(^|[^A-Za-z0-9_])from\s+urllib(\.[A-Za-z_]+)*\s+import",
    r"(^|[^A-Za-z0-9_])import\s+requests(\s|$)",
    r"(^|[^A-Za-z0-9_])from\s+requests\s+import",
    r"(^|[^A-Za-z0-9_])import\s+httpx(\s|$)",
    r"(^|[^A-Za-z0-9_])from\s+httpx\s+import",
    r"(^|[^A-Za-z0-9_])import\s+http(\.[A-Za-z_]+)*(\s|$)",
    r"(^|[^A-Za-z0-9_])from\s+http(\.[A-Za-z_]+)*\s+import",
    r"(^|[^A-Za-z0-9_])socket\.socket\s*\(",
    r"(^|[^A-Za-z0-9_])socket\.create_connection",
    r"(^|[^A-Za-z0-9_])socket\.socketpair",
    r"(^|[^A-Za-z0-9_])urlopen\s*\(",
    r"(^|[^A-Za-z0-9_])urlretrieve\s*\(",
    r"(^|[^A-Za-z0-9_])requests\.[A-Za-z_]+\s*\(",
    r"(^|[^A-Za-z0-9_])httpx\.[A-Za-z_]+\s*\(",
    r"(^|[^A-Za-z0-9_])http\.client\.",
]

SHELL_COMPILED = [re.compile(pattern) for pattern in SHELL_PATTERNS]
PYTHON_COMPILED = [re.compile(pattern) for pattern in PYTHON_PATTERNS]


def is_comment(line):
    """True when the line is a comment of the language."""
    stripped = line.strip()
    return stripped.startswith("#")


def regex_hits(text, compiled):
    """The hits of the TEXT against the patterns: a list of (line, text)."""
    hits = []
    for number, line in enumerate(text.splitlines(), start=1):
        if is_comment(line):
            continue
        for pattern in compiled:
            if pattern.search(line):
                hits.append((number, line.rstrip("\n")))
                break
    return hits


def dotted_name(node):
    """The dotted name of an attribute chain, or None when there is none."""
    parts = []
    current = node
    while isinstance(current, ast.Attribute):
        parts.append(current.attr)
        current = current.value
    if not isinstance(current, ast.Name):
        return None
    parts.append(current.id)
    return ".".join(reversed(parts))


def analyse_python(text):
    """The hits of a PYTHON file: the imports, the aliases and the entries.

    The analysis is static: the file is never imported and never executed.
    """
    try:
        tree = ast.parse(text)
    except SyntaxError:
        # The file does not parse: the TEXT is the only thing that can be
        # read, and the patterns of the primitives are applied to it.
        return regex_hits(text, PYTHON_COMPILED)

    lines = text.splitlines()
    hits = []
    modules = set()  # the local names bound to a network MODULE
    functions = set()  # the local names bound to a network FUNCTION

    def hit(node):
        number = getattr(node, "lineno", 0)
        content = lines[number - 1].strip() if 0 < number <= len(lines) else ""
        hits.append((number, content))

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in NETWORK_MODULES:
                    hit(node)
                    modules.add(alias.asname or alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module in NETWORK_MODULES:
                hit(node)
                for alias in node.names:
                    functions.add(alias.asname or alias.name)
            elif module in NETWORK_PACKAGES:
                for alias in node.names:
                    if "%s.%s" % (module, alias.name) in NETWORK_MODULES:
                        hit(node)
                        modules.add(alias.asname or alias.name)

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        if isinstance(function, ast.Name):
            if function.id in functions:
                hit(node)
            continue
        if not isinstance(function, ast.Attribute):
            continue
        chain = dotted_name(function)
        if chain is None:
            continue
        parts = chain.split(".")
        if parts[0] in modules:
            hit(node)
            continue
        for index in range(1, len(parts) + 1):
            if ".".join(parts[:index]) in NETWORK_MODULES:
                hit(node)
                break

    unique = []
    seen = set()
    for number, content in hits:
        key = (number, content)
        if key in seen:
            continue
        seen.add(key)
        unique.append((number, content))
    return unique


def scan_file(path):
    """The hits of one file: a list of (line number, text)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return []
    if SCANNER_MARKER in text:
        # It is the scanner itself or a copy of it: the patterns that it
        # looks for are, by definition, in its own source.
        return []
    if path.endswith(".py"):
        return analyse_python(text)
    return regex_hits(text, SHELL_COMPILED)


def candidate_files(root):
    """Every shell or python file under <root>, in a deterministic order."""
    if os.path.isfile(root):
        return [root]
    found = []
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = sorted(
            name for name in subdirectories if not name.startswith(".")
        )
        for name in sorted(names):
            if name.endswith(".sh") or name.endswith(".py"):
                found.append(os.path.join(directory, name))
    return sorted(found)


def scan(argv):
    """The scan of the roots: it prints every hit and returns the count."""
    own = os.path.realpath(__file__)
    hits = 0
    for root in argv:
        for path in candidate_files(root):
            if os.path.realpath(path) == own:
                continue
            for number, text in scan_file(path):
                print("%s:%d: %s" % (path, number, text.strip()))
                hits += 1
    return hits


# ---------------------------------------------------------------------------
# The EFFECTIVE RESTRICTION of the network.
#
# The primitives are substituted by DOUBLES that REFUSE and the resolution
# of names is disabled. The restriction is installed by a `sitecustomize` of
# its own directory: EVERY interpreter that has that directory in its path
# refuses the network, without changing anything else.
# ---------------------------------------------------------------------------
GUARD_SOURCE = '''\
"""The restriction of the NETWORK for the execution of the battery.

The battery must not use the network, NOT EVEN the loopback interface. The
static scanner proves that the CODE of the battery does not contain the
primitives of the network; this module makes those primitives UNAVAILABLE
while the battery runs, so that the absence of network is a property of the
EXECUTION and not only a declaration about the source.
"""

import http.client
import socket
import urllib.request


class NetworkAccessDenied(RuntimeError):
    """The use of the network is REFUSED by the restriction."""


def _denied(name):
    def double(*args, **kwargs):
        raise NetworkAccessDenied(
            "la red esta restringida durante la ejecucion de la bateria: %s" % name
        )

    double.__name__ = name
    return double


def install():
    """Substitute the primitives of the network by DOUBLES that refuse."""
    socket.socket = _denied("socket.socket")
    socket.create_connection = _denied("socket.create_connection")
    socket.socketpair = _denied("socket.socketpair")
    socket.getaddrinfo = _denied("socket.getaddrinfo")
    socket.gethostbyname = _denied("socket.gethostbyname")
    socket.gethostbyname_ex = _denied("socket.gethostbyname_ex")
    urllib.request.urlopen = _denied("urllib.request.urlopen")
    urllib.request.urlretrieve = _denied("urllib.request.urlretrieve")
    http.client.HTTPConnection = _denied("http.client.HTTPConnection")
    http.client.HTTPSConnection = _denied("http.client.HTTPSConnection")
'''

SITECUSTOMIZE_SOURCE = '''\
"""The automatic installation of the restriction of the network."""

try:
    import forge_network_guard
except Exception:
    pass
else:
    try:
        forge_network_guard.install()
    except Exception:
        pass
'''

WRAPPER_SOURCE = '''#!/bin/sh
# The wrapper of the interpreter with the restriction of the network
# installed. It runs the REAL interpreter: the restriction lives in the
# `sitecustomize` of this directory.
GUARD_DIR="__GUARD_DIR__"
if [ -n "${PYTHONPATH:-}" ]; then
  PYTHONPATH="$GUARD_DIR:$PYTHONPATH"
else
  PYTHONPATH="$GUARD_DIR"
fi
export PYTHONPATH
exec __REAL_PYTHON__ "$@"
'''

# The attempts that PROVE that the restriction is effective. Every one of
# them must be REFUSED.
GUARD_PROBES = (
    "import socket; socket.socket()",
    "import socket; socket.create_connection(('127.0.0.1', 9))",
    "import socket; socket.getaddrinfo('example.invalid', 80)",
    "import socket; socket.gethostbyname('example.invalid')",
    "from urllib.request import urlopen; urlopen('http://example.invalid/')",
    "import http.client; http.client.HTTPConnection('example.invalid', 80)",
)


def write_guard(directory, real_python):
    """Write the restriction of the network in <directory>."""
    os.makedirs(directory, exist_ok=True)
    files = {
        "forge_network_guard.py": GUARD_SOURCE,
        "sitecustomize.py": SITECUSTOMIZE_SOURCE,
        "python3": WRAPPER_SOURCE.replace(
            "__GUARD_DIR__", directory
        ).replace("__REAL_PYTHON__", real_python),
    }
    for name, content in files.items():
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        if name == "python3":
            os.chmod(path, 0o755)
    return directory


def verify_guard(directory, real_python):
    """Prove that the restriction REFUSES the primitives of the network.

    The proof is a REAL attempt: the primitive is called and its refusal is
    observed. A restriction that only claimed to refuse would pass nothing.
    """
    environment = dict(os.environ)
    existing = environment.get("PYTHONPATH")
    environment["PYTHONPATH"] = (
        "%s:%s" % (directory, existing) if existing else directory
    )
    refused = 0
    for probe in GUARD_PROBES:
        completed = subprocess.run(
            [real_python, "-c", probe],
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if completed.returncode == 0:
            sys.stderr.write(
                "la restriccion NO es efectiva: %s NO fue rechazada\n" % probe
            )
            return False
        message = completed.stderr.decode("utf-8", "replace")
        if "NetworkAccessDenied" not in message:
            sys.stderr.write(
                "la restriccion NO es efectiva: %s fallo por otra causa: %s\n"
                % (probe, message.strip().splitlines()[-1:] or [""])
            )
            return False
        refused += 1

    # The interpreter itself is NOT broken by the restriction: a program
    # that does not use the network still runs.
    completed = subprocess.run(
        [real_python, "-c", "print('ok')"],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if completed.returncode != 0:
        sys.stderr.write("la restriccion ROMPIO el interprete\n")
        return False
    if completed.stdout.decode("utf-8", "replace").strip() != "ok":
        sys.stderr.write("la restriccion altero la salida del interprete\n")
        return False
    print("NETWORK_GUARD=EFFECTIVE")
    print("NETWORK_GUARD_REFUSED=%d" % refused)
    print("NETWORK_GUARD_DIR=%s" % directory)
    return True


def main(argv):
    if len(argv) >= 3 and argv[1] == "guard":
        directory = argv[2]
        real_python = os.path.realpath(sys.executable)
        write_guard(directory, real_python)
        if not verify_guard(directory, real_python):
            return 1
        return 0
    if len(argv) < 2:
        sys.stderr.write("uso: forge_network_free.py <file-or-dir> [...]\n")
        sys.stderr.write("      forge_network_free.py guard <directory>\n")
        return 64
    hits = scan(argv[1:])
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
