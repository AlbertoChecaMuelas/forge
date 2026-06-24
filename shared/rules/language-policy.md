---
paths:
  - "**/*.md"
  - "**/*.json"
  - "**/*.sh"
  - "**/*.ts"
  - "**/*.py"
---

When any agent (senior, tech, applier, reviewer, tester) produces text intended to be inserted into a project file — whether as a plan, an actionable decision, an edit diff, or a finding pasted verbatim into the repo — the language of that text MUST match the dominant language of the destination file.

- Before emitting the content, the agent reads (or asks the orchestrator/main to read) the destination file and identifies its dominant language (English vs Spanish).
- If the destination file is English, the inserted text is written in English even if the user spoke Spanish.
- If the destination file is Spanish, the inserted text is written in Spanish even if the inter-agent protocol is in English.
- This rule overrides the "respond to the user in Spanish" rule for the specific case of text that will live inside a file. The natural-language reply to the user (announcements, summaries, justifications) remains in Spanish; only the payload destined for the file follows the file's language.
- Mixing languages within a single file (e.g. inserting a Spanish paragraph into an otherwise English file) is a violation of this rule.
