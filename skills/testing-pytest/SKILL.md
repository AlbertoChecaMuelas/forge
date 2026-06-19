---
name: testing-pytest
description: Python pytest + pytest-cov testing cookbook — operative guide for tester
disable-model-invocation: true
---

## Python (pytest + pytest-cov)

Detection signals: any of `pytest.ini`, `pyproject.toml` (with `[tool.pytest.ini_options]` or `pytest` in `[project.optional-dependencies]`/`[dependency-groups]`), `setup.cfg` (with `[tool:pytest]`), or `tox.ini` (with `[pytest]`); AND a `tests/`, `test/`, or `__tests__/` directory at repo root or under the package.

**ROLE**: tester owns the full red-green loop — writing tests, executing them, and interpreting results. Tester runs pytest commands directly and iterates until the suite is green and coverage meets the target.

### Package name detection (resolve `<package>` before running commands)

Before running the commands below, the tester resolves the `<package>` placeholder by inspecting, in this order:

1. `pyproject.toml` → `[project].name` (PEP 621).
2. `pyproject.toml` → `[tool.poetry].name` (Poetry).
3. `setup.cfg` → `[metadata] name = ...`.
4. `setup.py` → `name="..."` argument to `setup(...)`.

Normalize the resolved name to its import form: lowercase, replace `-` with `_`. Confirm the resulting directory exists as `src/<package>/` or `<package>/` at repo root. If none of the four sources yields a name, or the resolved name has no matching directory, emit `BLOCKED_TESTER: Python package name not detectable — add [project] name to pyproject.toml`.

### Prerequisites

`pytest-cov` (coverage) and `pytest-xdist` (parallelism) must be declared as dev dependencies. If absent in `pyproject.toml`/`setup.cfg`/`requirements*.txt`, emit `BLOCKED_TESTER: pytest-cov or pytest-xdist missing — add to dev dependencies before planning`.

### Commands tester runs directly

Tester executes these commands as part of the red-green loop. Run the scoped command while iterating on a single area, then the full suite before declaring done.

- **Fast feedback during TDD (single test or file)**:
  ```
  pytest -v -x tests/<path>/test_<name>.py
  ```
  Use `-x` to stop at the first failure and focus attention. Drop `-x` once the file is fully green.

- **Filter by name expression**:
  ```
  pytest -v -k "<expr>"
  ```
  Example: `pytest -v -k "user_service or test_returns_404"` — runs only tests whose name matches the expression. Useful for iterating on a single behaviour without running unrelated tests.

- **Scoped run with coverage (single area)**:
  ```
  pytest -v --cov=<package> --cov-report=term-missing -n auto tests/<path>/
  ```
  Examples of the scoped target:
  - `tests/services/` — every test under a directory
  - `tests/services/test_user_service.py` — single test file
  - `tests/services/test_user_service.py::TestUserService::test_returns_404` — single test method

- **Full suite (project-wide, run before declaring done)**:
  ```
  pytest -v --cov=<package> --cov-report=term-missing --cov-report=xml:reports/coverage.xml --junitxml=reports/result.xml -n auto
  ```

### Interpreting a failing assertion

When pytest reports a failing test, read the output in three layers:

1. **FAILED line** — identifies the exact test node (`file::class::method`). This tells you *where* to look.
2. **AssertionError / exception block** — shows *what* was wrong: expected vs actual values, unexpected exception type, missing mock call, etc.
3. **Short test summary info** — at the end of the run, `FAILED N` lines summarise all failures. Use these when multiple tests fail: fix the most fundamental one first (a setup/fixture error typically cascades into many failures).

Common failure patterns:
- `AssertionError: assert <actual> == <expected>` — the unit's return value differs; inspect the implementation or revise the test expectation if the spec changed.
- `AttributeError` / `ImportError` inside a test — a missing fixture, mock, or import; add or fix the relevant setup.
- `ERRORS` (not `FAILED`) — collection errors (syntax, import failure in the test file itself); fix these before looking at assertion failures.
- Coverage drop below target — `--cov-report=term-missing` prints uncovered lines per file; add tests for the listed lines.

### Fixture and mock conventions

Fixtures live in `tests/conftest.py` (shared) or alongside the test file (`conftest.py` in the same directory). Tester writes and runs fixtures directly:

```python
# tests/conftest.py
import pytest

@pytest.fixture
def user_repo(mocker):
    return mocker.MagicMock()
```

For external dependencies (DB, HTTP, filesystem), use `pytest-mock` (`mocker` fixture) or `unittest.mock.patch`:

```python
def test_creates_user(user_repo, mocker):
    mocker.patch("myapp.services.user_service.send_welcome_email")
    svc = UserService(repo=user_repo)
    svc.create(name="Alice")
    user_repo.save.assert_called_once()
```

If `pytest-mock` is missing, emit `BLOCKED_TESTER: pytest-mock missing — add to dev dependencies before writing mock-based tests` and do NOT modify build config files (`pyproject.toml`, `setup.cfg`, `requirements*.txt`). Do not write brittle `unittest.mock` boilerplate inline as a workaround.

### Reports directory

The full-suite command writes to `reports/coverage.xml` and `reports/result.xml`. This directory is build output and must be gitignored. Delegate to applier: ensure `reports/` is listed in `.gitignore` (create the entry if missing, one-shot command: `grep -qxF 'reports/' .gitignore || echo 'reports/' >> .gitignore`).

### Coverage target

90% line coverage.

### BLOCKED_TESTER conditions specific to Python

- `BLOCKED_TESTER: Python package name not detectable — add [project] name to pyproject.toml`
- `BLOCKED_TESTER: pytest-cov or pytest-xdist missing — add to dev dependencies before planning`
- `BLOCKED_TESTER: tests directory not found — create tests/ before planning`
- `BLOCKED_TESTER: pytest-mock missing — add to dev dependencies before writing mock-based tests`

### Do NOT

- Do not hardcode a package name; always resolve `<package>` from project metadata.
- Do not run `--cov` without an explicit `--cov=<package>` target (coverage of "everything imported" inflates the denominator).
- Do not commit `reports/` artifacts; flag the `.gitignore` step instead.
- Do not mix `-v` with `-q` or add `-s` (captured stdout is intentional in CI-style runs; `-s` is only for interactive debug sessions).
