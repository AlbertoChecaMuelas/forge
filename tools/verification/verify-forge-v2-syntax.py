#!/usr/bin/env python3
"""Parse touched Python and embedded Python without executing any source."""

from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from pathlib import Path


SHELL_RELATIVE_PATHS = (
    "tools/verification/forge-v2-followups.sh",
    "install.sh",
    "open-code/forge-opencode.sh",
    "tests/forge_guard_plugin_unit.sh",
    "tests/forge_v2_safety.sh",
    "tests/forge_v2_safety_scenarios.sh",
)

EXTERNAL_SHELL_PATHS = ("cutover.sh", "ROLLBACK.sh")
EXPECTED_SHELL_BLOCK_COUNTS = {
    "forge-v2-followups.sh": (0, 10),
    "install.sh": (3, 1),
    "forge-opencode.sh": (1, 0),
    "forge_guard_plugin_unit.sh": (0, 0),
    "forge_v2_safety.sh": (0, 1),
    "forge_v2_safety_scenarios.sh": (2, 2),
    "cutover.sh": (7, 5),
    "ROLLBACK.sh": (5, 0),
}
REQUIRED_REPO_PYTHON = (
    "open-code/lib/plugin-sync.py",
    "tests/forge_v2_safety_harness.py",
    "tools/verification/prepare-sandbox.py",
    "tools/verification/verify-forge-v2-syntax.py",
)
REQUIRED_EXTERNAL_PYTHON = ("lib/dbtool.py", "lib/cutover_safety.py")

PYTHON_C_COMMAND = re.compile(r"\bpython(?:3)?\s+-c\s+(['\"])" )
HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2")
PYTHON_CMD = re.compile(r"\bpython(?:3)?(?:\s|$)")


def parse_source(source: str, label: str, catalog: list[dict[str, object]]) -> None:
    try:
        ast.parse(source, filename=label)
    except SyntaxError as exc:
        raise RuntimeError(f"ast.parse failed for {label}:{exc.lineno}:{exc.offset}: {exc.msg}") from exc
    catalog.append({"kind": "python-source", "source": label, "status": "PASS"})


def shell_quote_value(text: str, start: int, quote: str) -> tuple[str, int]:
    """Read one shell-quoted argument and preserve its Python source text."""
    chars: list[str] = []
    index = start + 1
    while index < len(text):
        char = text[index]
        if char == quote:
            return "".join(chars), index + 1
        if quote == '"' and char == "\\" and index + 1 < len(text):
            following = text[index + 1]
            if following in ('"', "\\", "$", "`", "\n"):
                chars.append(following)
                index += 2
                continue
        if quote == "'" and char == "\\" and index + 1 < len(text) and text[index + 1] == "'":
            # A shell single quote is normally closed/reopened to include a
            # literal quote.  Treat that canonical sequence as one character.
            chars.append("'")
            index += 2
            continue
        chars.append(char)
        index += 1
    raise RuntimeError("unterminated shell quote after python -c")


def dynamic_cfg_check_expressions(shell_text: str) -> list[str]:
    return re.findall(r"\bcfg_check\s+'([^']+)'", shell_text)


def parse_inline_python(shell_text: str, path: Path, catalog: list[dict[str, object]]) -> int:
    count = 0
    for match in PYTHON_C_COMMAND.finditer(shell_text):
        line_start = shell_text.rfind("\n", 0, match.start()) + 1
        line_prefix = shell_text[line_start:match.start()]
        if line_prefix.lstrip().startswith("#"):
            continue
        code, _end = shell_quote_value(shell_text, match.start(0) + match.group(0).rfind(match.group(1)), match.group(1))
        line = shell_text.count("\n", 0, match.start()) + 1
        if "$" not in code:
            parse_source(code, f"{path}:line-{line}:python-c", catalog)
            count += 1
            continue

        # cutover.sh deliberately parameterizes one Python expression through
        # cfg_check($1). Parse each actual expression expanded by its shell
        # call sites instead of pretending the unexpanded template is executable.
        if "$1" not in code or "cfg_check" not in line_prefix:
            raise RuntimeError(f"unresolved shell expansion in embedded Python at {path}:{line}")
        expressions = dynamic_cfg_check_expressions(shell_text)
        if not expressions:
            raise RuntimeError(f"parameterized cfg_check has no identifiable callers in {path}:{line}")
        for ordinal, expression in enumerate(expressions, start=1):
            expanded = code.replace("$1", expression)
            parse_source(expanded, f"{path}:line-{line}:cfg_check-call-{ordinal}", catalog)
            count += 1
    return count


def parse_python_heredocs(shell_text: str, path: Path, catalog: list[dict[str, object]]) -> int:
    lines = shell_text.splitlines(keepends=True)
    count = 0
    cursor = 0
    while cursor < len(lines):
        opener_line = lines[cursor]
        match = HEREDOC.search(opener_line)
        if not match or not PYTHON_CMD.search(opener_line[:match.start()]):
            cursor += 1
            continue
        delimiter = match.group(3)
        strip_tabs = match.group(1) == "-"
        body: list[str] = []
        start_line = cursor + 2
        cursor += 1
        found_terminator = False
        while cursor < len(lines):
            raw_line = lines[cursor]
            candidate = raw_line.rstrip("\r\n")
            if strip_tabs:
                candidate = candidate.lstrip("\t")
            if candidate == delimiter:
                found_terminator = True
                break
            body.append(raw_line)
            cursor += 1
        if not found_terminator:
            raise RuntimeError(f"Python heredoc {delimiter!r} opened at {path}:{start_line - 1} is unterminated")
        parse_source("".join(body), f"{path}:lines-{start_line}-{cursor}:python-heredoc", catalog)
        count += 1
        cursor += 1
    return count


def run_git(repo: Path, *args: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--external-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    repo = args.repo_root.resolve(strict=True)
    external = args.external_root.resolve(strict=True)
    catalog: list[dict[str, object]] = []

    changed = set(run_git(repo, "diff", "--name-only", "--diff-filter=ACMRT", "HEAD"))
    changed.update(run_git(repo, "ls-files", "--others", "--exclude-standard"))
    repo_python_paths = set(REQUIRED_REPO_PYTHON)
    repo_python_paths.update(path for path in changed if path.endswith(".py"))
    for relative in sorted(repo_python_paths):
        path = repo / relative
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"required/touched repository Python source is missing or symlinked: {path}")
        parse_source(path.read_text(encoding="utf-8"), str(path), catalog)

    for relative in REQUIRED_EXTERNAL_PYTHON:
        path = external / relative
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"required external Python source is missing or symlinked: {path}")
        parse_source(path.read_text(encoding="utf-8"), str(path), catalog)

    shell_paths = [repo / relative for relative in SHELL_RELATIVE_PATHS]
    shell_paths.extend(external / relative for relative in EXTERNAL_SHELL_PATHS)
    for path in shell_paths:
        if not path.is_file() or path.is_symlink():
            raise RuntimeError(f"required shell source is missing or symlinked: {path}")
        source = path.read_text(encoding="utf-8")
        inline_count = parse_inline_python(source, path, catalog)
        heredoc_count = parse_python_heredocs(source, path, catalog)
        expected_counts = EXPECTED_SHELL_BLOCK_COUNTS.get(path.name)
        if expected_counts is None:
            raise RuntimeError(f"no reviewed Python-block inventory for required shell: {path}")
        if (inline_count, heredoc_count) != expected_counts:
            raise RuntimeError(
                f"Python block inventory changed for {path}: found inline/heredoc="
                f"{inline_count}/{heredoc_count}, expected {expected_counts[0]}/{expected_counts[1]}"
            )
        if inline_count + heredoc_count == 0 and path.name in {"cutover.sh", "install.sh", "forge-v2-followups.sh", "forge_v2_safety.sh", "forge_v2_safety_scenarios.sh"}:
            raise RuntimeError(f"no executable Python block was identified in required source: {path}")
        catalog.append(
            {
                "kind": "shell-python-inventory",
                "source": str(path),
                "inline_python_blocks": inline_count,
                "heredoc_python_blocks": heredoc_count,
                "status": "PASS",
            }
        )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps({"status": "PASS", "parsed_units": len(catalog), "catalog": catalog}, indent=2, sort_keys=True)
        + "\n",
        encoding="utf-8",
    )
    args.output.chmod(0o600)
    print(f"PASS: ast.parse completado; unidades={len(catalog)}; catálogo={args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.CalledProcessError, UnicodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
