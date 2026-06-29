# QUICK-REFERENCE — forge

---

## Slash commands

| Comando           | Cuando usarlo                              | Que produce                              |
|-------------------|--------------------------------------------|------------------------------------------|
| `/pr-description`    | Antes de abrir una PR                      | Descripcion estructurada lista para pegar|
| `/create-plan`       | Tarea multi-paso o multi-fichero           | `.plans/<slug>.md` + symlink `current`   |
| `/execute-plan`      | Plan creado, listo para ejecutar           | Commits por paso + `PR-DESCRIPTION.md`  |
| `/update-changelog`  | Antes de taggear o cerrar una iteracion    | Seccion `[Unreleased]` actualizada en `CHANGELOG.md` |
| `/cost-report`       | Tras una sesion intensa o auditoria de coste | Desglose por modelo (% coste, tokens, top sessions). `--session <id>` para filtrar a una sesion. |
| `/review`            | Auditoria post-cambio ad-hoc               | Veredicto estructurado (plantilla + subagente Opus) |
| `/create-pr`         | Crear la PR de la rama actual              | Bump de version + changelog + descripcion + PR via gh |
| `/sync-readme`       | Tras editar README.md o README.es.md       | Ambos README sincronizados (EN canonico ↔ ES)           |

---

## Instalación como plugin + core (recomendada)

```
claude                                            # abre una sesión con claude
/plugin marketplace add <url-del-repo-github>
/plugin install forge@forge
```

El plugin cubre agentes, skills y hooks. Despues, desde un clon del repo, completa con el componente `core` (CLAUDE-shared.md + defaults de settings + ficheros de soporte) y el binario RTK:

```bash
bash install.sh install --only=core,statusline   # target por defecto: ~/.claude y ~/.forge/.claude
bash install.sh rtk install && source ~/.zshrc
```

> El plugin se gestiona por instancia: para tenerlo tambien en otras instancias, repite los comandos `/plugin` desde esa sesion.

| Gestion del plugin | Comando |
|---|---|
| Inspeccionar que carga el plugin (agentes, skills, hooks y su coste) | `claude plugin details forge` |
| Desinstalar el plugin | `/plugin uninstall forge@forge` |
| Desinstalar el companion (core/statusline + RTK) | `bash install.sh uninstall` |

> Con el plugin activo NO instales por legacy `agents`, `commands`, `cost-report` (duplicados) ni `branch-guard`/`rtk-hook` (hooks ejecutados dos veces). El instalador bloquea `core` junto a `agents`/`commands`/`cost-report`.

---

## Instalación selectiva (legacy)

| Caso de uso | Comando |
|---|---|
| Instalación completa (defecto, 8 componentes) | `bash install.sh install` |
| Companion del plugin + statusline (Vía A) | `bash install.sh install --only=core,statusline` |
| Solo statusline | `bash install.sh install --only=statusline` |
| Solo pipeline de agentes y comandos | `bash install.sh install --only=agents,commands` |
| Solo cost-report y statusline | `bash install.sh install --only=cost-report,statusline` |
| Quitar un componente sin tocar el resto | `bash install.sh uninstall --component=<nombre>` |
| Desinstalación completa (incluye RTK; `--keep-rtk` lo conserva) | `bash install.sh uninstall` |
| Desinstalación + borrar backups y `.pre-forge` | `bash install.sh uninstall --purge` |
| Ver ayuda del instalador | `bash install.sh --help` |

Componentes válidos para `--only=` (cualquier combinación separada por comas): `agents`, `commands`, `statusline`, `branch-guard`, `rtk-hook`, `cost-report`, `cost-report-skill`, `session-start`, `core` — `core` es excluyente con `agents`/`commands`/`cost-report`.

---

## Agentes

| @agente       | Modelo         | Cuando invocarlo                                      |
|---------------|----------------|-------------------------------------------------------|
| @senior       | Opus 4.7       | Diseno, opciones, planificacion, cambio multi-fichero |
| @tech         | Sonnet 4.6     | Implementar algo ya decidido o con plan en mano       |
| @applier      | Haiku 4.5      | Paso mecanico 100% especificado (diff, commit, gh op) |
| @tester       | Sonnet 4.6     | Analizar gaps de cobertura, plan de testing           |

> El statusline muestra `[⬡ orch]` cuando el hook `session-start` corrio en la sesion actual. Si reabres la misma sesion al dia siguiente el badge sigue activo; si abres una sesion nueva, reaparece en cuanto se dispara el primer evento (`startup`, `clear`, `compact` o `resume`). Si nunca aparece, comprueba con `bash install.sh status`.

---

## Flujo tipico

1. El usuario describe la tarea en la sesion principal (orchestrator).
2. Si la rama actual es `master`, `main` o `dev` y la peticion implica commit, orchestrator delega primero a applier la creacion de una rama `feat|fix|chore|refactor|docs/<slug>` antes de cualquier cambio.
3. Orchestrator clasifica y anuncia la delegacion en una linea.
4. Si la peticion requiere analisis previo (verbos "audita", "revisa", "evalua" o hibridos "audita y actualiza"), orchestrator delega a senior para que decida que cambiar antes de actuar.
5. Si la peticion es multi-paso o de alcance amplio (varios ficheros, "feature", "implementa", lista de acciones), orchestrator delega a senior con la instruccion de producir contenido para /create-plan.
6. Senior/tech/reviewer/tester recibe la tarea y la ejecuta.
7. Si applier recibe un `BLOCKED`, tech lo asume.
8. Si tech detecta una decision de diseno no cubierta, devuelve `ESCALATE_SENIOR`.
9. Si senior emite `REQUIRES_PLAN`, orchestrator invoca `/create-plan` (no salta a tech).
10. Reviewer emite veredicto; si hay hallazgos, tech o senior los resuelven.

---

## Flujo con plan

1. `/create-plan <objetivo>` — orchestrator invoca a senior.
2. Senior entrevista al usuario (max 5 preguntas) si falta informacion.
3. Senior produce el plan con pasos `[T]`/`[A]`; comando escribe `.plans/<slug>.md`.
4. *(Opcional pero recomendado)* `/clear` — limpia el ruido de la conversacion de planificacion; el fichero `.plans/current` no se ve afectado y la doctrina se re-inyecta limpia.
5. `/execute-plan` — itera paso a paso; `[A]` → applier, `[T]` → tech.
6. Checkpoints de review: fase intermedia (si P >= 4) y cierre del plan (plantilla + subagente Opus).
7. Al finalizar todos los pasos: review final + genera `PR-DESCRIPTION.md`.

---

## OpenCode

Instalar o actualizar OpenCode en el entorno local:

```bash
bash open-code/install-opencode.sh
```

> El instalador incluye un asistente interactivo que solicita las claves API y las escribe automáticamente en `~/.opencode-tokens`.

---

## Cambiar modelo o proveedor por subagente en OpenCode

Hay dos mandos independientes; ambos deben estar sincronizados.

**Mando 1 — `shared/models.yaml`**

Edita el valor `opencode:` del rol deseado con el formato `<proveedor>/<model-id>` y regenera los ficheros de configuración:

```bash
bash shared/scripts/generate-agents.sh --target=opencode
```

**Mando 2 — `open-code/opencode.jsonc`**

Declara el proveedor una sola vez (endpoint base + `"apiKey": "{env:<VARIABLE>}"`). Las credenciales las carga `open-code/env.sh` mediante `load_forge_token <VARIABLE>` leyendo el fichero `~/.opencode-tokens`.

**Asignación actual (ejemplo)**

| Rol                               | Modelo asignado                    |
|-----------------------------------|------------------------------------|
| senior, tech, tester, orchestrator | `minimax/MiniMax-M3[1m]`          |
| applier                           | `minimax/MiniMax-M2.5-highspeed`   |

> **Configuración por defecto — MiniMax:** la asignación inicial usa MiniMax como proveedor. Si no modificas `shared/models.yaml`, lo único que necesitas es definir `MINIMAX_API_KEY` en `~/.opencode-tokens`. El instalador puede escribir esta clave automáticamente; también puedes añadirla a mano (formato `MINIMAX_API_KEY=<tu-clave>`).

**Caso A — Ya tienes una clave de OpenAI (GPT) o de Anthropic (Claude API)**

Los proveedores `openai` y `anthropic` ya están declarados en `open-code/opencode.jsonc` y sus cargadores ya están en `open-code/env.sh`. Para estos dos casos NO tocas el Mando 2 ni `env.sh`: solo (1) eliges el modelo en `shared/models.yaml`, (2) dejas la clave en `~/.opencode-tokens` y (3) regeneras.

1. Configura tu clave en `~/.opencode-tokens` (una por línea, formato `CLAVE=valor`). El instalador puede escribir este fichero automáticamente; la edición manual es un método alternativo:

   ```
   OPENAI_API_KEY=sk-...           # para GPT
   ANTHROPIC_API_KEY=sk-ant-...    # para Claude vía API
   ```

2. Asigna el modelo a cada rol en `shared/models.yaml` (campo `opencode:`, formato `<proveedor>/<model-id>`). Ejemplos de `model-id`:
   - OpenAI: `openai/gpt-4.1`, `openai/gpt-4o`, `openai/o3`.
   - Anthropic: `anthropic/claude-sonnet-4`, `anthropic/claude-opus-4`.

3. Regenera:

   ```bash
   bash shared/scripts/generate-agents.sh --target=opencode
   ```

> Nota sobre la "suscripción" de Claude: `ANTHROPIC_API_KEY` factura por token vía API y NO es lo mismo que una suscripción Claude Pro/Max. Si quieres usar tu suscripción, autentícate con `opencode auth login` (flujo OAuth) en vez de la clave; en ese caso no usas `~/.opencode-tokens` ni el Mando 2.

**Caso B — Quieres añadir un proveedor nuevo compatible con OpenAI**

Solo en este caso declaras un bloque nuevo en `open-code/opencode.jsonc` (como `minimax`): `"npm": "@ai-sdk/openai-compatible"`, `baseURL`, `apiKey` y la lista explícita de `models`. Añade además el `load_forge_token <VARIABLE>` correspondiente en `open-code/env.sh` y luego regenera con el comando del Caso A.

---

## Codigos de retorno

| Codigo               | Lo emite  | Que hace orchestrator                                  |
|----------------------|-----------|--------------------------------------------------------|
| `BLOCKED`            | applier   | Re-evalua; tipicamente sube a tech                     |
| `VERIFIER_FAILED`    | applier   | Pasa a tech para diagnostico                           |
| `ESCALATE_SENIOR`    | tech      | Invoca senior con la razon como contexto               |
| `BLOCKED_TECH`       | tech      | Redirige al agente nombrado en la razon (tipicamente tester) |
| `FINDINGS`           | review    | Tech para impl, senior para design (fuera de plan)     |
| `FINDINGS_PHASE`     | review    | impl=N → tech; design=M → senior; en plan: batch→1 delegacion cada uno; luego 1 re-review incremental (Sonnet), tope review_rounds |
| `VERIFIED`           | review    | Metadata de fase: marca riesgos auditados activamente  |
| `BLOCKED_REVIEW`     | review    | Pide clarificacion al usuario                          |
| `OK_PHASE`           | review    | Marca checkpoint; continua `/execute-plan`             |
| `TESTING_PLAN`       | tester    | Delega a tech con el plan                              |
| `ESCALATE_SENIOR`    | tester    | Invoca senior con la razon                             |
| `BLOCKED_TESTER`     | tester    | Pide clarificacion al usuario                          |
| `REQUIRES_PLAN`      | senior    | Invoca `/create-plan` con el contenido analitico       |
| `BLOCKED_SENIOR`     | senior    | Pide clarificacion al usuario                          |

> Detalle completo: `shared/reference/escalation-codes.md`.
