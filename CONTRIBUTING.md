# Contributing

## Shell linting

All shell files must pass `shellcheck`. Disable directives (`# shellcheck disable=...`) must include an inline comment explaining the reason.

## Documentation languages

`README.md` (English) is the canonical README — AI agents and tooling read that one. `README.es.md` is its Spanish mirror for human readers. Any change to one must be propagated to the other (use the `/sync-readme` skill); `tests/readme_sync_unit.sh` fails CI when their structure diverges.
