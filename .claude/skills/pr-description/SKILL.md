---
description: Generates a structured description for a Pull Request from the commits and diffs of the current branch.
argument-hint: "[base-branch]"
model: claude-haiku-4-5
allowed-tools: Bash(git log *) Bash(git diff *) Bash(git rev-parse *) Bash(bash $(git rev-parse --show-toplevel)/tools/release/mr-stamp.sh *) Write
context: fork
---

CRITICAL FORMAT INSTRUCTION: Your complete response, from the first character to the last, must be only the filled-in template. No preamble, no "I understand", no "I will", no introductory text of any kind. Your first character must be the `t` of `tipo(scope):`.

Generate the Pull Request description from the git data shown below.
The base branch is `${1:-master}`.

## Current branch

!`git rev-parse --abbrev-ref HEAD`

## Pre-resolved stamp and change-type checkboxes (authoritative — copy verbatim)

!`bash $(git rev-parse --show-toplevel)/tools/release/mr-stamp.sh --base ${1:-master}`

## Included commits (subjects and bodies)

!`git log ${1:-master}..HEAD --pretty=format:"%h %s%n%b" --no-merges`

## Modified files (with statistics)

!`git diff ${1:-master}..HEAD --stat`

## Full list of changed files

!`git diff ${1:-master}..HEAD --name-only`

## Risks verified by reviewer (if any)

!`if [ -f .plans/current ]; then awk '/^## Risks verified by reviewer/{f=1;next} /^## /{f=0} f && /^- /{print}' .plans/current 2>/dev/null; fi`

---

Fill in EXACTLY this template in markdown. Do not add any text before or after the template. No preamble, no explanations. Only the filled-in template markdown.

The language of the entire description must be **Spanish**. Do not use English words or phrases.

---

### Strict rules before writing

**On the freshness stamp — MANDATORY:**
- The very last line of the output MUST be the stamp line exactly as emitted in the "Pre-resolved stamp and change-type checkboxes" context block above. Copy it verbatim — do not re-derive the SHA or timestamp by hand.
- This stamp lets downstream tooling (`tools/release/create-pr.sh`) detect when the description is stale relative to the current branch tip. Omitting it breaks the PR-creation pipeline.

**On figures and counts — CRITICAL:**
- **NEVER invent or estimate numbers** not directly present in the `git diff --stat` output.
- If you need to mention how many elements a file has (e.g. how many frameworks are in a constant), **do not do so** unless the number appears in the body of a commit. Describe without numbers: "the list of supported frameworks", not "19 frameworks".
- Inserted/deleted lines may only be cited **literally** from `git diff --stat`. If you calculate them manually you may be wrong — better not to cite the net delta.
- If you are going to mention that a file was directly modified, **verify it appears in `git diff --name-only`**. If it does not appear, do not assert it was edited; instead describe the impact in terms of data flow.

**On the introduction:**
- Count the real axes of change and use that exact number ("this branch introduces **three** axes…"). Do not say "two" if the document itself describes three or more.
- Each axis has its own sentence explaining why.

**On the Motivación / Contexto section:**
- This section answers the **why** of the PR, not the what. It must explain the problem, friction or opportunity that motivated the work, and the technical decision adopted to resolve it.
- **Required source**: the bodies of the commits (section "Included commits") and, secondarily, what is evidently inferable from the diff. If commit bodies provide no explicit reasons, **do not invent a motivation**: leave the section with a single neutral phrase derived from the commit subjects, or mark it as omitted (see next rule).
- **Omission permitted**: if commits are purely `chore:`, `style:` or trivial renames with no narrative context, **omit the entire section** (including the `## Motivación / Contexto` header). Do not fill it with generic text like "code quality is improved".
- Structure when applicable:
  - **Problema / contexto** (1-3 sentences): what prior situation motivated the change. No blame, no judgements; factual description.
  - **Decisión técnica** (1-3 sentences): what approach was adopted and, if evident from commits, why over alternatives. Do not speculate about alternatives not mentioned.
- Prohibited in this section:
  - Inventing tickets, Jira IDs or references to discussions not appearing in commits.
  - Justifying the change with invented metrics ("reduces load time by 30%") if not in the commits.
  - Repeating the change summary — this section is context, not inventory.

**On change types:**
Paste the `## Tipo de cambio` block exactly as it appears in the "Pre-resolved stamp and change-type checkboxes" context block above. Do not derive checkboxes from commit prefixes yourself — use the authoritative pre-resolved block verbatim.

**On the change summary:**
- Group by functional area. For each bullet: describe **what** changes and **why** (use commit bodies as source).
- Name the specific symbols affected (classes, methods, interfaces, constants) **only if they appear in the diff**.
- If there are fixes of different natures (e.g. UI vs networking vs compilation errors), put them in **separate sub-sections**, not mixed together.
- List **all** consumer files that appear in `git diff --name-only` for a change area, not only the most well-known ones.

**On the Tests section:**
- If there are changes in `*.spec.ts` files, add a **compact** "Tests" section: one or two sentences summarising which specs were updated and what new behaviour they cover. Do not list each file with its lines — that is noise for the reviewer.

**On the Documentación / Configuración section:**
- If there are `*.md`, `*.yaml`, `*.json` configuration files that are new or modified in `git diff --name-only`, mention them briefly. Do not copy their content.

**On the Impacto section:**
- 2-3 bullets of **observable** impact (UX, maintainability, technical debt, stability).
- Do not repeat technical details from the summary.
- Do not cite line or file counts unless they come directly from `git diff --stat`.

**On the Riesgos y áreas a revisar con atención section:**
- This section guides the reviewer towards the **critical zones of the diff**: where to look more carefully, what could break and what edge cases to mentally cover.
- **Required source**: the files listed in `git diff --name-only`, the functional areas identified in the summary and the commit bodies. **No generic risks** of the type "there could be performance problems" without a specific file or symbol to justify it.
- Each bullet must follow this structure: **[specific zone/file/symbol] — [risk type] — [what to verify].**
- Valid risk types (choose the one that applies, do not force one that does not fit):
  - **Regresión funcional**: the change touches code consumed by multiple sites (verifiable in `git diff --name-only`).
  - **Cambio de contrato**: an interface, DTO, model or public signature consumed by other modules is modified.
  - **Side-effects de estado**: changes in signals, observables, subjects or shared stores.
  - **Concurrencia / orden de inicialización**: if the commit mentions initialisation order, race conditions, or lifecycle changes.
  - **Migración de datos / esquema**: changes in mappers, DTOs, persistence.
  - **Cobertura insuficiente**: areas modified without accompanying tests in `git diff --name-only`.
  - **Configuración / DI**: changes in providers, modules, injection tokens.
- Inclusion rules:
  - Minimum 1 risk, maximum 5. If the PR is trivial (single-line change, literal rename), **omit the entire section**.
  - If no tests were modified but business logic was, mandatorily include a **cobertura insuficiente** risk pointing to the affected files.
  - If there are changes in `*.spec.ts` but the specs for the corresponding module were not updated, flag it.
  - Prioritise by **impact surface**: a change in a repository consumed by several use-cases is higher priority than an isolated fix in a leaf component.
- **Filtering by reviewer**: if the "Risks verified by reviewer" block in the context contains items, do NOT include as a risk any zone/file/symbol/concern whose meaning coincides with a VERIFIED item:
  - **Semantic (conceptual) match**: the risk and the verified item describe the same concern, even if the wording differs (capitalisation, spaces, punctuation, synonyms, word order, arrows `→` vs `->` vs `a`, abbreviations). Example: the item `coherencia flujo reviewer→execute-plan→pr-description` covers the risk `Coherencia flujo reviewer → execute-plan → pr-description`.
  - Match by **technical anchor**: the file or symbol of the risk is literally equal to the verified item, or the risk file is under the directory or module declared by the item (e.g. item `src/foo/` covers `src/foo/bar.ts` and `src/foo/baz/qux.ts`).
  - **When in doubt keep the risk**: if after evaluating semantic and anchor matches you cannot map the risk to a verified item with high confidence, include it.
- **Empty section after filtering**: if after applying the filtering no material risk remains, omit the entire section (including the `## Riesgos y áreas a revisar con atención` header).
- Prohibited in this section:
  - Risks without anchor to a file/symbol from the diff.
  - Repeating bullets from Impacto (Impacto = observable consequence; Riesgo = what could go wrong and where to look).
  - Inventing dependencies not appearing in `git diff --name-only`.

**On the title:**
- The PR title goes as plain text before the `---` separator, without a heading level (`#`).
- Conventional Commits format, maximum 72 characters: `tipo(scope): descripción en imperativo`.
- If the branch mixes several types, use the most representative one.

---

<!-- LITERAL TEMPLATE — keep in Spanish, do not translate -->

tipo(scope): descripción concisa en imperativo (máx 72 chars)

---

# Descripción

[Introducción: 3-5 frases. Enuncia TODOS los ejes de cambio con el número exacto ("esta rama introduce N ejes…"). Para cada eje explica el por qué, no solo el qué.]

## Motivación / Contexto *(omitir entera si los commits no aportan contexto narrativo)*

**Problema / contexto:** [1-3 frases factuales sobre la situación previa que motivó el cambio. Fuente: cuerpos de los commits.]

**Decisión técnica:** [1-3 frases sobre el enfoque adoptado. Solo menciona alternativas si aparecen en los commits.]

<!-- PASTE HERE the ## Tipo de cambio block verbatim from the "Pre-resolved stamp and change-type checkboxes" context block. Do not modify it. -->

---

## Resumen de cambios

### [Nombre del área funcional principal]

- [cambio concreto — qué y por qué]
- [cambio concreto — qué y por qué]

### [Siguiente área funcional]

- [cambio concreto — qué y por qué]

### Fixes de UI *(si procede)*

- [bug concreto corregido y su causa]

### Fixes de estabilidad y networking *(si procede)*

- [bug concreto corregido y su causa]

### Tests *(si hay cambios en specs)*

- [Una o dos frases: qué specs se actualizaron y qué comportamiento nuevo cubren.]

### Documentación / Configuración *(si hay ficheros .md u otros de config nuevos o modificados)*

- [ficheros afectados y descripción breve de su propósito]

## Impacto

- [Impacto observable 1: UX, mantenibilidad o deuda técnica — sin cifras inventadas]
- [Impacto observable 2]
- [Impacto observable 3 si procede]

## Riesgos y áreas a revisar con atención *(omitir entera si la PR es trivial)*

- **[zona/fichero/símbolo concreto]** — [tipo de riesgo: regresión funcional / cambio de contrato / side-effects de estado / concurrencia / migración de datos / cobertura insuficiente / configuración] — [qué verificar concretamente en la revisión].
- **[zona/fichero/símbolo concreto]** — [tipo de riesgo] — [qué verificar].
- **[zona/fichero/símbolo concreto]** — [tipo de riesgo] — [qué verificar].

<!-- PASTE HERE the stamp line verbatim from the "Pre-resolved stamp and change-type checkboxes" context block. It must be the very last line of the output. -->

---

FINAL REMINDER: the template ends with the `<!-- forge:pr-description ... -->` stamp on the last line. Copy the stamp line exactly as it appears in the "Pre-resolved stamp and change-type checkboxes" context block — do not substitute SHA or timestamp by hand. The stamp is MANDATORY and MUST be the very last line of your output — your last character must be the closing `>` of the HTML comment. Do not append any text after the stamp. The stamp is required even when sections (Riesgos, Motivación, etc.) are omitted. The output of this skill is saved as `PR-DESCRIPTION.md` at the repository root by the invoking skill (`create-pr`).
