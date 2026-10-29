#!/usr/bin/env python3
"""tests/forge_shell_defs.py — the REAL function definitions of a shell file.

A shell file can hold text that LOOKS like a function definition and is NOT
one:

  * the body of a HEREDOC is a generated script (the killer and the observer
    of the containment are written that way), not code of the file;
  * the text inside a QUOTED STRING is data (a mock injected into a child
    shell), not code of the file.

Counting those as definitions produces false positives, so the scanner tracks
the quoting and the pending heredocs and reports only the definitions that
exist in the scope of the file.

The scanner is deliberately STATIC: it never executes the shell file, it
never imports anything and it never touches a process of the host.

Usage:
  python3 tests/forge_shell_defs.py duplicates <file>
      Prints "<name>: <line>, <line>" for every name defined MORE THAN ONCE
      in <file>. RC 1 when there is at least one, RC 0 otherwise.

  python3 tests/forge_shell_defs.py count <file-or-dir> <name>
      Prints "<file>:<line>" for every definition of <name> under
      <file-or-dir> (recursive when it is a directory). RC 0 always.
"""

import os
import re
import sys

# A definition is a NAME at the beginning of a line, optionally introduced by
# "function", optionally followed by "()" and followed by "{". The variants
# are the only ones that bash accepts:
#
#   name() {          name () {          function name {          function name() {
DEFINITION = re.compile(
    r"^[ \t]*(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:\([ \t]*\))?[ \t]*\{"
)

# The header of a heredoc: <<WORD, <<-WORD, <<'WORD', <<"WORD".
#
# The delimiter is the COMPLETE word: `<<'END-DATA'` opens a heredoc whose
# delimiter is `END-DATA` and NOT `END`. A truncated delimiter swallows the
# rest of the file (every definition after it disappears) and it reports
# results that are wrong.
#
# The `-` of `<<-` is IMMEDIATE (there is no space between `<<` and `-`),
# and it means that the TABULATORS are removed from the body and from the
# terminator. The spaces are NOT removed: a terminator preceded by spaces
# is NOT the terminator.
HEREDOC = re.compile(
    r"<<(-?)[ \t]*(?:'([^']*)'|\"([^\"]*)\"|([A-Za-z_][A-Za-z0-9_-]*))"
)


class _State:
    """The quoting state of the scanner. It survives the end of a line."""

    def __init__(self):
        self.quote = "none"  # "none", "single" or "double"


def _scan_line(line, state, heredocs):
    """Advance the quoting state over one line of code.

    The delimiters of the heredocs opened by THIS line are appended to
    <heredocs>. Only the ones that are opened OUTSIDE a quoted string count:
    a "<<WORD" inside a string is data.
    """
    position = 0
    length = len(line)
    while position < length:
        char = line[position]
        if state.quote == "single":
            if char == "'":
                state.quote = "none"
            position += 1
            continue
        if state.quote == "double":
            if char == "\\" and position + 1 < length:
                position += 2
                continue
            if char == '"':
                state.quote = "none"
            position += 1
            continue
        # Not inside a quoted string.
        if char == "\\" and position + 1 < length:
            position += 2
            continue
        if char == "'":
            state.quote = "single"
            position += 1
            continue
        if char == '"':
            state.quote = "double"
            position += 1
            continue
        if char == "#" and (position == 0 or line[position - 1] in " \t"):
            break  # the rest of the line is a comment
        if char == "<" and line[position:position + 2] == "<<":
            if line[position:position + 3] == "<<<":
                # A here-STRING (`<<<WORD`) opens NOTHING: the word that
                # follows is DATA, not the delimiter of a heredoc. Treating
                # it as a heredoc swallows the rest of the file.
                position += 3
                continue
            match = HEREDOC.match(line[position:])
            if match:
                delimiter = match.group(2)
                if delimiter is None:
                    delimiter = match.group(3)
                if delimiter is None:
                    delimiter = match.group(4)
                if delimiter:
                    heredocs.append((delimiter, match.group(1) == "-"))
                position += match.end()
                continue
        position += 1
    return state


def scan_definitions(path):
    """The REAL definitions of <path>: a list of (name, line number).

    The name is the one of the function and the line number is 1-based and
    points at the line of the definition itself.

    Whether a line is CODE or DATA is decided by the LEXICAL CONTEXT AT THE
    START of the line, never by the context at its end. A line that OPENS a
    multi-line string is still code (a real definition that opens one was
    omitted when the state AFTER the line was used), and a line that CLOSES
    a string is still data (a fictitious definition inside a string was
    counted when the state AFTER the line was used).
    """
    definitions = []
    pending = []  # the heredocs whose body has not been read yet
    state = _State()
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.readlines()

    index = 0
    while index < len(lines):
        line = lines[index]
        index += 1

        if pending:
            delimiter, strip_tabs = pending[0]
            probe = line.rstrip("\n")
            if strip_tabs:
                # `<<-` removes TABULATORS and NOTHING else: a terminator
                # that is preceded by SPACES is NOT the terminator, and the
                # body of the heredoc goes on.
                probe = probe.lstrip("\t")
            if probe == delimiter:
                pending.pop(0)
            continue  # the body of a heredoc is not code of this file

        # The context at the START of the line decides whether the line is
        # code: a line that begins inside a quoted string is DATA, whatever
        # it does with the string at its end.
        context = state.quote
        opened = []
        _scan_line(line, state, opened)
        if context == "none":
            match = DEFINITION.match(line)
            if match:
                definitions.append((match.group(1), index))
        pending.extend(opened)
    return definitions


def _shell_files(root):
    """Every shell file under <root>, in a deterministic order."""
    if os.path.isfile(root):
        return [root]
    found = []
    for directory, subdirectories, names in os.walk(root):
        subdirectories[:] = sorted(
            name
            for name in subdirectories
            if not name.startswith(".") and name != "node_modules"
        )
        for name in sorted(names):
            if name.endswith(".sh"):
                found.append(os.path.join(directory, name))
    return sorted(found)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(
            "uso: forge_shell_defs.py duplicates <file>\n"
            "     forge_shell_defs.py count <file-or-dir> <name>\n"
        )
        return 64

    command = argv[1]
    target = argv[2]

    if command == "duplicates":
        if not os.path.isfile(target):
            sys.stderr.write("el fichero no existe: %s\n" % target)
            return 64
        definitions = scan_definitions(target)
        names = {}
        for name, line in definitions:
            names.setdefault(name, []).append(line)
        repeated = sorted(name for name in names if len(names[name]) > 1)
        for name in repeated:
            lines = ", ".join(str(line) for line in names[name])
            print("%s: %s" % (name, lines))
        return 1 if repeated else 0

    if command == "count":
        if len(argv) < 4:
            sys.stderr.write("falta el nombre de la funcion\n")
            return 64
        wanted = argv[3]
        for path in _shell_files(target):
            for name, line in scan_definitions(path):
                if name == wanted:
                    print("%s:%d" % (path, line))
        return 0

    sys.stderr.write("comando desconocido: %s\n" % command)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
