# Forge

[English](README.md) | **Español**

> El README en inglés es la versión canónica (es la que leen los agentes de IA por defecto). Mantén ambos idiomas sincronizados con la skill `/sync-readme`.

Toolkit para Claude Code que distribuye agentes, comandos y configuración compartida como plugin de Claude Code o vía symlinks. Instala un pipeline multiagente (orquestador → senior/tester → tech → applier, más despacho de revisión por plantilla), slash commands reutilizables y un RTK pineado en cualquier repositorio que use Claude Code.

## Índice

- [Visión general](#visión-general)
- [Qué incluye](#qué-incluye)
- [Instalación](#instalación)
  - [Requisitos](#requisitos)
  - [Elige tu vía](#elige-tu-vía)
  - [Vía A — Plugin + core](#vía-a--plugin--core-recomendada)
  - [Vía B — Instalación legacy](#vía-b--instalación-legacy-symlinks-vía-installsh)
  - [Instalación selectiva de componentes](#instalación-selectiva-de-componentes)
  - [Flags de instalación](#flags-de-instalación)
  - [Desinstalación](#desinstalación)
  - [RTK](#rtk)
- [Componentes](#componentes)
- [Uso](#uso)
  - [Statusline](#statusline)
  - [Informe de costes](#informe-de-costes)
  - [Pipeline de agentes](#pipeline-de-agentes)
  - [Flujo dirigido por plan](#flujo-dirigido-por-plan)
- [Configuración y seguridad](#configuración-y-seguridad)
  - [Branch guard](#branch-guard)
  - [Inyección de la doctrina del orquestador](#inyección-de-la-doctrina-del-orquestador)
- [Target OpenCode](#target-opencode)
  - [Instalación](#instalación-1)
  - [Requisitos](#requisitos-1)
  - [Estructura de `open-code/`](#estructura-de-open-code)
- [Estructura del proyecto](#estructura-del-proyecto)
- [Proceso de release](#proceso-de-release)
- [Contribuir](#contribuir)

## Visión general

Forge centraliza la configuración que hace productivo a Claude Code en muchos repositorios: un conjunto curado de subagentes con límites de rol estrictos, slash commands que orquestan cambios multi-paso, una statusline con telemetría de coste y tokens, y un proxy RTK pineado que reduce el consumo de tokens en las operaciones de desarrollo.

Todo se entrega mediante symlinks desde este repositorio hacia `~/.claude/`, de modo que actualizar es un simple `git pull`.

## Qué incluye

| Tipo    | Nombre           | Descripción                                                                  |
|---------|------------------|------------------------------------------------------------------------------|
| Agente  | senior           | Análisis, opciones con trade-offs, planes `[T]`/`[A]`. No escribe código. Opus. |
| Agente  | tech             | Implementación: escribe código, edita ficheros, ejecuta comandos. Sonnet.    |
| Agente  | applier          | Ejecuta pasos mecánicos literales: diffs, commits, operaciones gh. Haiku.    |
| Skill   | /review          | Auditoría post-cambio: rellena la plantilla de revisión y despacha un subagente Opus nuevo. |
| Agente  | tester           | Dueño de todos los ficheros de test; escribe y ejecuta tests, analiza huecos de cobertura, produce `TESTING_PLAN`. Escala bugs de producción a tech. Sonnet. |
| Comando | /pr-description  | Genera una descripción de PR estructurada a partir de commits y diffs.       |
| Comando | /create-plan     | Guía a senior por una entrevista y persiste un plan ejecutable en `.plans/<slug>.md`. |
| Comando | /execute-plan    | Itera el plan, delegando pasos `[A]` a applier y `[T]` a tech, con checkpoints. |
| Comando | `/cost-report`    | Desglosa el coste de sesión de Claude por familia de modelo (opus/sonnet/haiku) como proxy del gasto por subagente; marca anomalías. |
| Compartido | CLAUDE-shared.md | Instrucciones del pipeline distribuidas a cada repo vía symlink.          |
| Compartido | statusline.sh    | Statusline de Claude Code con coste, tokens y sesión activa.              |
| Compartido | total-usage.sh   | Totales de uso históricos con precios oficiales por tipo de token.        |
| Compartido | `cost-report.sh`  | Script de respaldo de `/cost-report`: desglose de coste por modelo, top de sesiones y flags de anomalía. |

## Instalación

### Requisitos

bash 3.2+, git, jq, Claude Code.

### Elige tu vía

Forge se instala de dos formas. Ambas son **funcionalmente equivalentes** una vez completas — mismos agentes, skills, hooks, defaults de settings y ahorro de RTK — y se diferencian en cómo se entregan y actualizan las piezas:

| Artefacto | Vía A — Plugin + core | Vía B — Legacy (symlinks) |
|---|---|---|
| Agentes (senior, tech, applier, tester) | plugin (autodescubiertos) | componente `agents` |
| Skills (`/create-plan`, `/execute-plan`, `/review`, `/create-pr`, `/cost-report`, ...) | plugin (autodescubiertas) | componentes `commands` + `cost-report` + `cost-report-skill` |
| Hooks PreToolUse (proxy RTK + branch guard) | plugin (`hooks/hooks.json`) | componentes `rtk-hook` + `branch-guard` |
| `CLAUDE-shared.md` + ref `@CLAUDE-shared.md` en `~/.claude/CLAUDE.md` | **componente `core`** | componente `agents` |
| Defaults de `settings.json` (`model: sonnet`, `env`, permisos) | **componente `core`** | componente `agents` |
| Ficheros de soporte de skills (`tools/release/{bump-version,create-pr}.sh`, `cost-report.sh`) | **componente `core`** | componentes `commands` + `cost-report` |
| Statusline (scripts + claves `statusLine`/`subagentStatusLine`) | componente `statusline` (opcional) | componente `statusline` |
| Binario RTK (`~/.forge/bin/rtk`) | `bash install.sh rtk install` | `bash install.sh rtk install` |
| Actualizaciones | `/plugin` → update, más `git pull` para los symlinks de core | `bash install.sh update` |

**Racional de coste — por qué `core` no es opcional en la práctica.** El plugin solo carga los agentes, skills y hooks, pero los tres mecanismos que de verdad recortan la factura viven en `core` + el binario RTK:

1. **`CLAUDE-shared.md`** es el firewall que obliga a tu sesión principal a delegar en el pipeline (senior/tech/applier) en vez de hacer ella misma las ediciones, greps y tests con el modelo caro de la sesión.
2. **`model: sonnet` + los alias de modelos en `env`** mantienen la sesión principal en Sonnet por defecto, de modo que el trabajo pesado ocurre en los niveles más baratos que asigna el pipeline.
3. **El binario RTK** alimenta el hook proxy PreToolUse que trae el plugin. Sin el binario, el hook es un no-op silencioso y pierdes el 60–90 % de ahorro en el output de comandos (git, ls, tests...). El hook invoca `~/.forge/bin/rtk`, que solo proporciona `bash install.sh rtk install`.

### Vía A — Plugin + core (recomendada)

Paso 1 — instala el plugin (agentes + skills + hooks):

```
/plugin marketplace add <url-del-repo>     # registra el marketplace 'forge'
/plugin install forge@forge                # instala el plugin
```

Paso 2 — desde un clon de este repositorio, instala las piezas companion que un plugin no puede entregar:

```
bash install.sh install --only=core,statusline # CLAUDE-shared.md + defaults de settings + ficheros de soporte + statusline
bash install.sh rtk install                    # binario RTK pineado + snippet de PATH + activa el seguimiento RTK
source ~/.zshrc                                # o abre un terminal nuevo
```

`rtk install` debe ejecutarse **después** de la instalación con `--only=core,statusline`: persiste el flag `rtk.tracked` en el state file existente y deliberadamente no crea uno nuevo. Una vez activado el flag, `update`/`doctor`/`status` verificarán la versión de RTK en la Vía A sin necesidad del componente `rtk-hook`.

El target por defecto es `~/.claude/`. Pasa `--target=claude` para ser explícito. El plugin en sí se gestiona por instancia de Claude Code: ejecuta los mismos comandos `/plugin` desde la instancia donde quieras activarlo.

Para actualizar: los bumps del plugin llegan con el marketplace (`/plugin` → update); la `version` del plugin se mantiene en lockstep con `FORGE_VERSION` mediante `tools/release/bump-version.sh` y se verifica en CI. Los symlinks de `core` se actualizan con un simple `git pull` del clon (o `bash install.sh update`).

La gestión diaria del plugin se hace con la CLI `claude plugin` (o el menú `/plugin` dentro de la sesión). En particular, `claude plugin details forge` es la forma más rápida de inspeccionar qué carga realmente el plugin — agentes, skills y hooks, con el coste en contexto de sus descriptions:

```
claude plugin details forge
```

**No mezcles las vías.** Con el plugin activo, no instales nunca por legacy los componentes `agents`, `commands` o `cost-report` (agentes y skills duplicados) ni `branch-guard`/`rtk-hook` (los hooks PreToolUse se ejecutarían **dos veces**: una desde el `hooks/hooks.json` del plugin y otra desde `settings.json`). El instalador fuerza el primer grupo mecánicamente — `core` es excluyente con `agents`/`commands`/`cost-report` — pero no puede ver los hooks del plugin, así que la regla de `branch-guard`/`rtk-hook` es solo documental: respétala.

### Vía B — Instalación legacy (symlinks vía install.sh)

Ejecuta el instalador desde la raíz del repositorio. Cada subcomando es idempotente y seguro de re-ejecutar.

| Comando | Qué hace |
|---------|----------|
| `bash install.sh install` | Instala los 8 componentes por defecto en `~/.claude/`. |
| `bash install.sh install --target=claude` | Instala solo en `~/.claude/`. |
| `bash install.sh install --show-cost` | Instala y activa el coste monetario más estadísticas históricas en la statusline. |
| `bash install.sh install --only=agents,commands` | Instala solo los componentes `agents` y `commands`. |
| `bash install.sh install --only=statusline` | Instala solo el componente `statusline`. |
| `bash install.sh status` | Informa de qué symlinks están en su sitio por target (acotado a componentes). |
| `bash install.sh doctor` | Ejecuta diagnósticos solo sobre los componentes instalados: valida integridad de symlinks, presencia de RTK y salud de configuración. |
| `bash install.sh update` | Ejecuta `git pull` y repara symlinks, actuando solo sobre los componentes registrados en el state. |
| `bash install.sh repair` | Recrea symlinks rotos o ausentes de los componentes instalados, sin hacer pull. |
| `bash install.sh version` | Imprime `FORGE_VERSION`. |
| `bash install.sh uninstall` | Elimina todos los symlinks que creó el instalador. Preserva los ficheros del usuario. |
| `bash install.sh uninstall --component=statusline` | Elimina solo el componente `statusline`, dejando intactos los demás. |
| `bash install.sh rtk install` | Instala explícitamente el proxy RTK pineado. |
| `bash install.sh rtk uninstall` | Elimina el proxy RTK pineado. |
| `bash install.sh --help` | Imprime el bloque de uso del instalador (subcomandos, opciones, banner de versión). También se acepta `-h` y se muestra sin subcomando. |

### Instalación selectiva de componentes

Por defecto, `install` despliega los 8 componentes por defecto (`core`, el companion del plugin, es solo opt-in). Usa `--only=<lista>` para instalar solo un subconjunto de componentes, o `--component=<nombre>` con `uninstall` para eliminar un único componente sin tocar el resto.

`--only=` acepta cualquier subconjunto separado por comas de los nueve componentes descritos en [Componentes](#componentes) — `agents`, `commands`, `statusline`, `branch-guard`, `rtk-hook`, `cost-report`, `cost-report-skill`, `session-start`, `core` — sujeto a la regla de exclusividad de `core` de más abajo. La tabla muestra recetas comunes, no las únicas combinaciones válidas.

| Receta | Comando |
|---|---|
| Companion del plugin + statusline (Vía A) | `bash install.sh install --only=core,statusline` |
| Mínima (solo statusline) | `bash install.sh install --only=statusline` |
| Solo pipeline de agentes | `bash install.sh install --only=agents,commands` |
| Solo tooling de coste | `bash install.sh install --only=cost-report,cost-report-skill,statusline` |
| Todo excepto branch guard | `bash install.sh install --only=agents,commands,statusline,rtk-hook,cost-report,cost-report-skill` |
| Eliminar un componente | `bash install.sh uninstall --component=<nombre>` |

**Nota sobre `commands` sin `agents`**: instalar `commands` sin `agents` está permitido, pero los slash commands dependen del pipeline de agentes para funcionar correctamente. El instalador emite un aviso si seleccionas `commands` sin `agents`.

**Nota sobre `core`**: `core` es excluyente con `agents`, `commands` y `cost-report` — poseen los mismos ficheros y rutas de settings. El instalador rechaza cualquier combinación entre ellos, tanto dentro de la misma lista `--only` como contra componentes ya registrados como instalados (desinstala antes el componente en conflicto).

**Nota sobre `rtk-hook`**: `--only=rtk-hook` instala solo la entrada del hook en settings. NO instala el binario `rtk`; instálalo con `bash install.sh rtk install`.

Los subcomandos `update`, `repair`, `status` y `doctor` están acotados a componentes: actúan solo sobre los componentes registrados como instalados en el state file. Si instalaste un subconjunto, esos comandos operan solo sobre ese subconjunto (cambio de comportamiento de v0.14.0).

### Flags de instalación

| Flag | Descripción |
|------|-------------|
| `--target=claude` | Instala solo el target de Claude Code. |
| `--target=opencode` | Instala solo la overlay aislada de OpenCode. |
| `--target=both` | Instala el target de Claude Code y la overlay de OpenCode. |
| `--only=<componente>[,<componente>...]` | Instala solo los componentes indicados. Sin flag = instala los 8 por defecto (retrocompatible). |
| `--show-cost` | Activa el coste monetario de la sesión actual y las estadísticas históricas en la statusline. |

### Desinstalación

Cada vía de instalación se desinstala con su propia herramienta.

**Vía A (Plugin + core)** — dos pasos, espejo de la instalación:

```
/plugin uninstall forge@forge             # agentes + skills + hooks (también desde el menú /plugin)
```

```
bash install.sh uninstall                 # symlinks de core/statusline, defaults de settings y el RTK pineado
```

**Vía B (Legacy)** — un único comando elimina todo lo que creó el instalador:

```
bash install.sh uninstall
```

Flags que acepta `install.sh uninstall`:

| Flag | Descripción |
|------|-------------|
| `--component=<nombre>` | Elimina un único componente del target, dejando intactos los demás. Sin este flag, la desinstalación completa lo elimina todo. |
| `--keep-rtk` | Solo desinstalación completa: conserva el binario RTK pineado y su snippet de PATH. Sin él, la desinstalación completa elimina `~/.forge/bin/rtk`, el bloque de PATH de tus profiles y el directorio `~/.forge/` si queda vacío. |
| `--purge` | Elimina también los backups `*.forge-bak-*` **y** `settings.json.pre-forge`. Sin él, ambos se conservan. |

Una desinstalación completa deja `~/.claude/` limpio de verdad: quita la línea `@CLAUDE-shared.md` de `CLAUDE.md` (preservando tu propio contenido), barre los directorios vacíos `skills/`, `tools/`, `agents/` y `rules/`, elimina el RTK pineado por defecto y **sanea los settings restaurados**: las entradas de hooks que invocan un `rtk` que ya no resuelve, y las entradas `statusLine`/`subagentStatusLine` que apuntan a scripts que la propia desinstalación acaba de borrar, se eliminan con un aviso. Los originales intactos quedan en `settings.json.pre-forge`.

### RTK

`bash install.sh rtk install` instala el binario del proxy RTK pineado en `~/.forge/bin/rtk`. Si tiene éxito también **inyecta un bloque de PATH marcado** en cada profile de shell que ya exista en disco (`~/.zshrc`, `~/.bashrc`, `~/.zprofile`, `~/.bash_profile`). El bloque antepone `~/.forge/bin` al `PATH` para que el `rtk` pineado por forge tenga precedencia sobre cualquier otra instalación. La inyección es idempotente: re-ejecutar el instalador nunca duplica el bloque.

**Requisito post-instalación**: el cambio de PATH solo surte efecto en sesiones de shell nuevas. Tras instalar, abre un terminal nuevo o ejecuta:

```
source ~/.zshrc
```

Hasta que lo hagas, `rtk` no resolverá en los terminales que ya estaban abiertos cuando corrió el instalador.

**Desinstalación**: `bash install.sh rtk uninstall` elimina el binario, quita el bloque de PATH de los cuatro profiles automáticamente y elimina el flag `rtk.tracked` del state file, de modo que `status`/`doctor`/`update` dejan de verificar la versión de RTK (se reactiva con `bash install.sh rtk install`; el script directo `bash rtk/uninstall-rtk.sh` elimina binario y bloque de PATH pero no toca el flag). Una desinstalación **completa** `bash install.sh uninstall` también elimina el RTK pineado por defecto — pasa `--keep-rtk` para conservarlo.

#### Migrar desde un RTK instalado con Homebrew

Si instalaste `rtk` previamente vía Homebrew, sigue estos pasos para cambiar a la versión pineada de forge:

1. Confirma que Homebrew lo tiene: `brew list rtk`
2. Elimina la copia de Homebrew: `brew uninstall rtk`
3. Instala la versión pineada de forge: `bash install.sh rtk install`
4. Aplica el cambio de PATH: `source ~/.zshrc` (o abre un terminal nuevo)

> **Aviso**: entre los pasos 2 y 4, `rtk` no resolverá en ningún terminal abierto. Cierra todos los terminales que dependían de la copia de Homebrew antes de continuar, o asume un breve hueco de disponibilidad.

## Componentes

El instalador se articula en torno a nueve componentes discretos. Cada componente se define en un manifiesto bajo `shared/components/` y puede instalarse de forma independiente.

| Componente | Qué instala | ¿Por defecto? |
|-----------|-------------|---------------|
| `agents` | Pipeline de agentes (senior, tech, applier, tester) + `CLAUDE-shared.md` + defaults de settings | sí |
| `commands` | Slash commands (`create-plan`, `execute-plan`, `pr-description`, `update-changelog`, `review`, `create-pr`, `sync-readme`, `plan-format`), skills de testing por framework (`testing-angular`, `testing-spring-boot`, `testing-pytest`) + herramientas de release | sí |
| `statusline` | Statusline de Claude Code (`statusline.sh`), `total-usage.sh`, `subagent-statusline.sh` + las claves de settings `statusLine`/`subagentStatusLine` | sí |
| `branch-guard` | Hook PreToolUse `branch-guard.sh` que bloquea commits en ramas protegidas | sí |
| `rtk-hook` | Entrada del hook proxy RTK en `settings.json` (el binario `rtk` se instala por separado con `bash install.sh rtk install`) | sí |
| `cost-report` | Slash command `/cost-report` + script de respaldo `cost-report.sh` | sí |
| `cost-report-skill` | Symlink `~/.claude/skills/cost-report/SKILL.md` que hace que `/cost-report` sea descubrible como skill de Claude Code | sí |
| `session-start` | Hook `SessionStart` que inyecta el prompt del orquestador (`CLAUDE-orchestrator.md`) en la sesión principal en los eventos `startup` y `clear`; incluye `session-start.sh` y copia `CLAUDE-orchestrator.md` al directorio Claude del proyecto | sí |
| `core` | Companion del plugin: `CLAUDE-shared.md` + `@ref`, defaults de settings (`model`, `env`, permisos) y ficheros de soporte de skills (`tools/release/{bump-version,create-pr}.sh`, `cost-report.sh`) — todo lo que el plugin de Claude Code no puede entregar por sí mismo | **no** — opt-in; la Vía A usa `--only=core,statusline` |

**Retrocompatibilidad**: sin flag `--only` = instalación completa de los 8 componentes por defecto. Las invocaciones existentes siguen funcionando sin cambios; `core` nunca se instala por defecto porque entra en conflicto con `agents`/`commands`/`cost-report`.

## Uso

### Statusline

`shared/statusline.sh` se instala como symlink en `~/.claude/statusline.sh` y proporciona la statusline de Claude Code con información de la sesión.

**Comportamiento por defecto** (sin `--show-cost`):

La statusline muestra dos líneas:
- Línea 1: directorio, rama git, velocidad (+adds/-dels), modelo, barra de contexto, límites de uso.
- Línea 2: `[ session ]` — nombre de la sesión y tokens de entrada/salida.

**Con `--show-cost`** (flag de instalación):

Añade dos elementos extra:
- **Coste monetario de la sesión**: importe USD/EUR acumulado en la sesión actual.
- **Línea lifetime** (tercera línea): coste histórico total, tokens acumulados, días activos, sesiones, coste de hoy y media diaria.

Para activarlo, instala con el flag:

| Comando | Qué hace |
|---------|----------|
| `bash install.sh install --show-cost` | Instala con el coste y las estadísticas históricas visibles en la statusline. |

El tipo de cambio USD → EUR se cachea 24 h en `~/.claude/.eur-rate` y se refresca en segundo plano.

### Informe de costes

`/cost-report` es un slash command respaldado por `shared/cost-report.sh` que parsea los logs de sesión de Claude Code y produce un desglose de coste estructurado.

**Qué produce**:
- **Desglose por modelo**: una tabla con columnas Model, Calls, Token In, Token Out, % Cost, Estimated Cost — una fila por familia de modelo (Opus, Sonnet, Haiku).
- **Tabla Top Sessions**: lista las sesiones más caras con ID de sesión y título.

**Flags clave**:

| Flag | Descripción |
|------|-------------|
| `--since` | Filtra sesiones a partir de una fecha (p. ej. `--since=2026-01-01`). |
| `--until` | Filtra sesiones hasta una fecha. |
| `--project` | Restringe a un proyecto concreto. |
| `--session <id-o-nombre>` | Filtra a una única sesión por substring del sessionId o del aiTitle. |

**Cuándo ejecutarlo**: tras una sesión intensiva, al auditar gasto, o al investigar una anomalía de coste.

**Cómo leerlo**: `% Cost` muestra la cuota de cada familia de modelo sobre el coste total del periodo seleccionado — útil para detectar sesiones Opus-intensivas donde senior o el subagente de review corrieron más de lo esperado. El flag `--session` acepta un prefijo de UUID o cualquier fragmento del título legible de la sesión.

Para instalar cost-report standalone (sin el pipeline de agentes completo), usa la receta de [Instalación selectiva de componentes](#instalación-selectiva-de-componentes): `bash install.sh install --only=cost-report,cost-report-skill,statusline`.

### Pipeline de agentes

La sesión principal actúa como orquestador: enruta las peticiones al agente adecuado según una puerta de 5 comprobaciones. No ejecuta herramientas con efectos secundarios; solo invoca subagentes vía la herramienta Task.

- Peticiones conversacionales → las responde el propio orquestador.
- Tareas mecánicas completamente especificadas → applier.
- Implementación con un plan en mano → tech.
- Análisis de huecos de testing → tester.
- Auditoría post-cambio → `/review` (subagente con plantilla, Opus).
- Decisiones de diseño y planificación multi-fichero → senior.

```
User
  |
  v
orchestrator -- routes by description --> senior (Opus)    -- plan -->  tech (Sonnet)
                                          tester (Sonnet)                      |
                                                                               v
                                          /review (template, Opus)       applier (Haiku)
```

Escalado hacia arriba vía códigos de retorno: `BLOCKED` (applier → tech), `ESCALATE_SENIOR` (tech → senior), `FINDINGS` (review → tech o senior).

### Flujo dirigido por plan

Usa este flujo cuando la tarea es multi-paso, toca varios ficheros o necesita planificación previa.

1. `/create-plan [descripción]` — invoca a senior, que produce un plan numerado con pasos `[T]`/`[A]`. El comando persiste el plan en `.plans/<slug>.md` y crea el symlink `.plans/current`. El directorio `.plans/` se añade a `.gitignore` automáticamente.
2. `/execute-plan` — lee `.plans/current` e itera paso a paso: los pasos `[A]` van a applier, los `[T]` a tech. El reviewer se invoca como máximo dos veces por plan: una vez en la fase intermedia (planes con P ≥ 4 fases) y otra al cierre. Al completar todos los pasos, se genera `PR-DESCRIPTION.md` vía `/pr-description`.

Si la sesión se interrumpe, `/execute-plan` retoma desde el último paso registrado en el front-matter del plan.

> **Tip**: tras que `/create-plan` produzca el plan y antes de ejecutar `/execute-plan`, hacer un `/clear` es opcional pero recomendable en planes largos. Elimina del contexto la conversación de planificación (la entrevista de senior, el debate de trade-offs, los borradores intermedios), de modo que `/execute-plan` arranca con un contexto limpio y la doctrina del orquestador se re-inyecta en fresco. El fichero de plan en disco no se ve afectado por `/clear`.

## Configuración y seguridad

### Branch guard

El repo incluye un hook PreToolUse de Claude Code en `shared/branch-guard.sh` que BLOQUEA commits en ramas protegidas (`master`, `main`, `dev`). Cuando el hook detecta una invocación `Bash` cuyo comando contiene `git commit` Y la rama actual es uno de los nombres protegidos, sale con código `2` y Claude Code rechaza la llamada a la herramienta.

Es una última línea de defensa mecánica, independiente del LLM. Existen además dos capas aguas arriba (la regla de triaje 2.5 en el prompt del orquestador, y un branch guard pre-commit en el prompt del agente applier) — el hook solo salta si ambas capas LLM fallan.

**Resumen de comportamiento**:
- `git commit` en `master`/`main`/`dev` → bloqueado (exit 2), stderr explica el motivo.
- `git commit` en cualquier rama feature → permitido.
- Operaciones git que no son commit (`status`, `log`, `diff`, `checkout -b`, `branch`) → nunca bloqueadas.
- HEAD detached o sin git disponible → aviso en stderr, no bloquea (fail-open).
- JSON de PreToolUse malformado → aviso en stderr, no bloquea (fail-open).

**Kill-switch**: define `FORGE_BRANCH_GUARD_DISABLE=1` en el entorno para saltarte el hook por completo (pensado para overrides de emergencia; documenta el motivo si lo usas).

**Instalación**: registra `shared/branch-guard.sh` como hook PreToolUse en tus settings de Claude Code (mira el snippet de `settings.json` del proyecto, si existe, o la documentación de hooks de Claude Code).

### Inyección de la doctrina del orquestador

Forge inyecta la doctrina del orquestador (`CLAUDE-orchestrator.md`) en la sesión principal de Claude Code mediante un hook `SessionStart`. Este es el mecanismo que hace que Claude se comporte como orquestador — enrutando las peticiones al agente adecuado, respetando los límites de rol y usando el protocolo de escalado — en lugar de actuar como un asistente genérico.

**Cómo funciona**: cuando arranca una sesión (o se reanuda, o se compacta el contexto), `session-start.sh` ejecuta y vuelca el contenido de `CLAUDE-orchestrator.md` a stdout. Claude Code añade ese output al contexto de la sesión una sola vez. El prompt caching de Claude hace que las llamadas a la API posteriores lean esos tokens desde caché a coste mínimo — la inyección solo paga precio completo en la primera llamada tras cada evento de inyección.

**Por qué los subagentes no cargan la doctrina**: antes de v0.20.0, la doctrina del orquestador vivía en `CLAUDE-shared.md`, que se carga en todas las sesiones — incluyendo cada subagente. Eso significaba que tech, applier, tester y senior recibían en su contexto las reglas de enrutamiento y la tabla de escalado del orquestador, a pesar de no necesitarlos nunca.

```
Antes de v0.20.0 — doctrina en CLAUDE-shared.md:
  main session (orchestrator) → CLAUDE-shared.md → orchestrator doctrine  ✓
  subagente tech               → CLAUDE-shared.md → orchestrator doctrine  ✗ (innecesario)
  subagente applier            → CLAUDE-shared.md → orchestrator doctrine  ✗ (innecesario)
  subagente tester             → CLAUDE-shared.md → orchestrator doctrine  ✗ (innecesario)

Después de v0.20.0 — doctrina inyectada vía hook SessionStart:
  main session (orchestrator) → hook SessionStart → orchestrator doctrine  ✓
  subagente tech               → (nada)                                    ✓
  subagente applier            → (nada)                                    ✓
  subagente tester             → (nada)                                    ✓
```

El hook `SessionStart` solo se dispara para la sesión principal, no para los subagentes. Extraer la doctrina a un fichero inyectado por hook significa que los subagentes ya no cargan tokens que nunca usan.

**Badge en la statusline**: la statusline muestra `[⬡ orch]` en la línea 1 cuando el hook disparó en la sesión actual (rastreado por session ID). El badge desaparece al abrir una sesión nueva donde el hook todavía no ha corrido, y reaparece en cuanto se dispara el primer evento (`startup`, `clear`, `compact` o `resume`). Si el badge nunca aparece, comprueba que el componente `session-start` está instalado (`bash install.sh status`) y que el hook está registrado en `settings.json`.

**Supervivencia tras compaction**: el hook se dispara en los eventos `startup`, `clear`, `compact` y `resume`. Si Claude Code compacta el contexto a mitad de sesión (eliminando los turnos de conversación más antiguos), la doctrina se re-inyecta automáticamente para que el protocolo del orquestador siga activo el resto de la sesión.

## Target OpenCode

Forge soporta [OpenCode](https://opencode.ai) desde este mismo repositorio. OpenCode no es un fork separado: es una overlay generada en `open-code/` e instalable mediante `--target=opencode` o `--target=both`.

`open-code/agents/` es un **artefacto generado**: nunca edites esos ficheros a mano. Edita las fuentes compartidas (`shared/agents/*.body.md`, `shared/scripts/opencode-frontmatter/*.yaml`, `open-code/agents-src/`) y ejecuta `bash shared/scripts/generate-agents.sh`. El CI falla en caso de drift (`tests/opencode_generation_unit.sh`).

### Instalación

| Comando | Qué hace |
|---------|----------|
| `bash install.sh install --target=opencode` | Instala solo la overlay aislada de OpenCode. |
| `bash install.sh install --target=both` | Instala el target de Claude Code y luego la overlay de OpenCode. |
| `bash open-code/install-opencode.sh` | Reinstala solo la overlay de OpenCode. |
| `bash open-code/uninstall-opencode.sh` | Elimina solo la overlay de OpenCode. |

**Qué hace el instalador**:

1. Requiere `opencode` en `PATH`.
2. Solicita de forma interactiva al usuario que configure las claves API del proveedor y las escribe en `~/.opencode-tokens`.
3. Regenera los 5 agentes OpenCode.
4. Instala una overlay aislada en `~/.config/opencode-forge/` en vez de tocar la configuración global del usuario.
5. Symlinka los agentes generados, `AGENTS.md` y `plugins/forge-guard.js` dentro de esa overlay aislada.
6. Copia `open-code/opencode.jsonc` a la overlay aislada y reescribe la ruta de instrucciones de `AGENTS.md`.
7. Instala un launcher independiente en `~/.local/bin/forge-opencode` que exporta `OPENCODE_CONFIG_DIR` y `OPENCODE_CONFIG` antes de invocar el binario real `opencode`.
8. Verifica que existan credenciales de OpenCode o autenticación por tokens vía `open-code/env.sh`.

El instalador es idempotente y no modifica `~/.config/opencode/`, `.bashrc`, `.zshrc` ni `config.fish`.

### Requisitos

- OpenCode instalado ([https://opencode.ai](https://opencode.ai)).
- `jq` (se instala automáticamente con `brew` si no está disponible; requiere Homebrew).
- `python3` como fallback si no se puede instalar `jq`.
- Una clave API de proveedor. MiniMax es el proveedor por defecto y requiere que `MINIMAX_API_KEY` esté definida. El instalador solicitará que la introduzcas y puede escribirla en `~/.opencode-tokens`.

### Estructura de `open-code/`

```
open-code/
  agents/                     Agentes OpenCode generados
  agents-src/orchestrator.body.md
  plugins/forge-guard.js     Plugin de branch guard para OpenCode
  AGENTS.md                  Instrucciones OpenCode compartidas mínimas
  opencode.jsonc             Plantilla de configuración del proveedor
  env.sh                     Loader POSIX de tokens; carga credenciales de ~/.opencode-tokens
  forge-opencode.sh          Wrapper que exporta rutas aisladas de config
  install-opencode.sh        Instala la overlay aislada de OpenCode
  uninstall-opencode.sh      Elimina la overlay aislada de OpenCode
  SPIKE-RESULTS.md           Hallazgos de delegación/plugin/config/coste
  COST-PARITY.md             Contrato de reporting de coste en OpenCode
```

## Estructura del proyecto

```
forge/
  agents/          Definiciones de subagentes (senior, tech, applier, tester)
  skills/          Slash commands (12 subdirs: create-plan, execute-plan, review, create-pr, …)
  hooks/           Hooks PreToolUse (branch-guard.sh, rtk-hook)
  tools/           Scripts de release
  .claude-plugin/  Manifiesto del plugin (plugin.json) para el marketplace de Claude Code
  open-code/       Overlay OpenCode: agents/, agents-src/, plugins/, AGENTS.md e instalador aislado
  shared/          Ficheros distribuidos a cada target (CLAUDE-shared.md, statusline, settings)
  lib/             Scripts internos del instalador (catalog, symlink, json-merge, rtk)
  rtk/             Instalador y desinstalador del RTK pineado
  tests/           Tests de integración y unitarios del instalador (bash)
  install.sh       Punto de entrada del instalador
  CHANGELOG.md     Historial de versiones
```

## Proceso de release

Este repo usa una única fuente de verdad para las versiones: `FORGE_VERSION` en `install.sh`. El manifiesto del plugin `.claude-plugin/plugin.json` se mantiene en lockstep mediante `tools/release/bump-version.sh` y se verifica en CI — el commit de release debe llevar siempre juntos `install.sh`, `CHANGELOG.md` **y** `.claude-plugin/plugin.json` (la skill `/create-pr` stagea los tres).

El flujo de release es:

1. Abre una rama feature y sube `FORGE_VERSION` al nuevo `X.Y.Z` (vía `/create-pr` o `tools/release/bump-version.sh`, que también sincroniza `.claude-plugin/plugin.json`). Incluye el bump en un commit que también refresque la sección `## [Unreleased]` de `CHANGELOG.md` (usa la skill `/update-changelog` para redactar las notas de release).
2. Mergea la rama en `master` mediante pull request en GitHub.
3. En cada push a `master`, el job de GitHub Actions `auto-tag` ejecuta `tools/release/auto-tag.sh`. El script:
   - Parsea `FORGE_VERSION` de `install.sh`.
   - Comprueba si `vX.Y.Z` ya existe en local o en `origin`. Si existe, el job es un no-op.
   - Si no, crea un tag anotado `vX.Y.Z` sobre el commit de merge con mensaje `Release vX.Y.Z` y lo pushea a `origin`.
4. El tag pusheado es el marcador canónico de release. Los consumidores downstream se fijan a tags, nunca a SHAs de `master`.

### Prerrequisitos

El job de CI usa el `GITHUB_TOKEN` integrado (inyectado automáticamente por GitHub Actions en cada pipeline) para autenticar el push. No se requiere ningún token creado a mano. Eso sí, el acceso de push de Git para job tokens debe estar habilitado en los ajustes del repositorio.

### Garantías de idempotencia

- Ejecutar `auto-tag.sh` contra un `FORGE_VERSION` cuyo tag ya existe es un no-op seguro.
- El script nunca mueve un tag existente.
- El script nunca crea tags ligeros; cada tag es anotado con el mensaje `Release vX.Y.Z`.

### Dry-run local

| Comando | Qué hace |
|---------|----------|
| `bash tools/release/auto-tag.sh --dry-run` | Parsea `FORGE_VERSION`, decide si el tag se crearía, y sale sin contactar con `origin`. |

## Contribuir

Las directrices para contribuidores (incluida la política de linting de shell) viven en [`CONTRIBUTING.md`](CONTRIBUTING.md).
