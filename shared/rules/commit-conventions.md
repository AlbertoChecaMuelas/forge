---
paths:
  - "CHANGELOG.md"
  - "install.sh"
---

# Commit conventions for changelog and version files

These conventions apply when committing changes to `CHANGELOG.md` or `install.sh` as part of the MR release workflow.

## Changelog-only commit (`BUMP=none`)

When the MR contains only chore/docs/refactor commits (no features or fixes), `bump-version.sh` returns `BUMP=none` and does not edit `install.sh`. If `/update-changelog` produces new content, commit `CHANGELOG.md` alone with:

```
docs(changelog): update [Unreleased] for upcoming MR
```

Do not stage `install.sh` in this commit.

## Release commit (`BUMP=patch` or `BUMP=minor`)

When the MR contains at least one feature or fix, `bump-version.sh` returns `BUMP=patch` or `BUMP=minor` and edits `install.sh` to set `FORGE_VERSION="<NEXT>"`. After `/update-changelog` refreshes `CHANGELOG.md`, commit **both** files together with:

```
chore(release): bump version to <NEXT>
```

Replace `<NEXT>` with the actual version string (e.g. `0.17.0`). Stage both `install.sh` and `CHANGELOG.md` — and nothing else — in this single commit.

## Notes

- These commit messages are literal: do not paraphrase, abbreviate, or add a body.
- The `[Unreleased]` section is NOT renamed in either commit — CI `auto-tag` closes it as `[v<NEXT>] - YYYY-MM-DD` after the MR merges and the tag is created.
- Neither commit is a generic "update changelog" message; the specific prefix (`docs` vs `chore`) is load-bearing for the release pipeline.
