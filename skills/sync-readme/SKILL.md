---
description: "Synchronise README.md (English, canonical) and README.es.md (Spanish) after editing either one. Use when the user asks to sync, translate or propagate README changes ('sincroniza los README', 'actualiza el readme en español', 'sync the readmes')."
argument-hint: "[en|es]"
---

# Sync README — keep both language versions aligned

`README.md` (English) is the **canonical** version — it is the one AI agents read by
default. `README.es.md` is its Spanish mirror. Whenever one is edited, this skill
propagates the change to the other.

## Flow

1. Determine the source of truth for this sync:
   - `$1` given (`en` or `es`) → that language is the source.
   - No argument → run `git diff --stat HEAD -- README.md README.es.md` (plus
     `git status --porcelain` for uncommitted edits). The file with changes is the
     source. If BOTH changed, ask the user which one wins before touching anything.
2. Read the source file and the target file in full.
3. Propagate the change section by section (headings are the unit of work):
   - Translate prose naturally — no literal word-by-word translation.
   - Code blocks, commands, flags, paths and identifiers stay **identical** in both
     languages; only comments inside code blocks are translated.
   - Tables keep the same number of rows and columns; only cell text is translated.
   - Keep the language-switcher line at the top of each file
     (`**English** | [Español](README.es.md)` / `[English](README.md) | **Español**`)
     and the canonical-version note under it.
4. Structural parity is mandatory: both files must end up with the same number of
   headings per level (`#`, `##`, `###`, `####`), the same number of fenced code
   blocks and the same number of tables. `tests/readme_sync_unit.sh` asserts this —
   run it after syncing:

   ```
   bash tests/readme_sync_unit.sh
   ```

5. Report which sections were propagated and the parity test result.
