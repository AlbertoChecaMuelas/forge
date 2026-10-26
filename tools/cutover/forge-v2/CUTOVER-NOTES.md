# Cutover de OpenCode 1.19.4 a OpenCode 2.1.4 — estado, decisiones y procedimiento

> **DOCUMENTO HISTÓRICO; NO OPERATIVO.** Este informe conserva contexto y resultados históricos. Los comandos, rutas y procedimientos que aparecen no son instrucciones autorizadas ni se deben ejecutar contra ninguna instalación, base de datos, respaldo, credencial o proceso. Para cualquier consumo activo, use exclusivamente el componente del checkout y sus verificadores estáticos permitidos.


> Procedimiento histórico del cutover, corregido con las verificaciones de
> remediación del 2026-10-24. Los conteos son observaciones fechadas, no
> constantes. El checklist de aceptación es de lectura/verificación: no inicia
> migraciones ni sustituye una autorización operativa.

- [Estado actual](#estado-actual)
- [Decisiones D1 y D2](#decisiones-d1-y-d2)
- [Archivos y rutas reales](#archivos-y-rutas-reales)
- [Cómo ejecutar el cutover](#cómo-ejecutar-el-cutover)
- [Qué hace el script, paso a paso](#qué-hace-el-script-paso-a-paso)
- [El reset del estado de migración (el punto delicado)](#el-reset-del-estado-de-migración-el-punto-delicado)
- [Cómo se dispara la migración y cómo se consulta](#cómo-se-dispara-la-migración-y-cómo-se-consulta)
- [Checklist de verificación posterior](#checklist-de-verificación-posterior)
- [Qué hacer si falla](#qué-hacer-si-falla)
- [Reversión](#reversión)
- [Limitaciones conocidas](#limitaciones-conocidas)

---

## Estado actual

| Item | Valor |
|------|-------|
| Repo durante el cutover histórico | `[RUTA PERSONAL REDACTADA]`, rama `master`, commit `12680a2` (no describe la rama/working tree actual) |
| Contrato del repo | Ya es OpenCode 2: `@opencode/cli@2.1.4`, config en dialecto V2, plugin `plugin-packages/forge-guard` |
| Plan de remediación vigente | `[RUTA PERSONAL REDACTADA]` (no editar durante Step 3.1) |
| Runbook | `open-code/MIGRATION-V2.md` |
| Launcher fuente / instalador | `open-code/forge-opencode.sh` / `install.sh` en la raíz del repo |
| Overlay / config / manifest | `[RUTA PERSONAL REDACTADA]` / `[RUTA PERSONAL REDACTADA]` / `[RUTA PERSONAL REDACTADA]` |
| Launcher y binario instalados | `[RUTA PERSONAL REDACTADA]` / `[RUTA PERSONAL REDACTADA]` |
| Scripts del cutover (externos al repo) | `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/{cutover.sh,ROLLBACK.sh,lib/dbtool.py}` |
| Backup verificado | `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/` |
| Base original consultada en el informe histórico | `[RUTA PERSONAL REDACTADA]` — 2,315,714,560 bytes en las ventanas fechadas del informe; los servicios preexistentes escribían en ella |
| Última lectura aislada anotada aquí | Copia sandbox: 881 `session`, 887 `session_v2`, 0 IDs V1 ausentes, 6 V2-only, `quick_check=ok` (2026-10-24T22:03:41Z–22:03:43Z) |

> **Cobertura permanente:** `v1_missing_in_v2 == 0`, calculado por anti-join de
> IDs entre `session` y `session_v2`. `v2_only` se informa, pero sesiones
> nativas V2 adicionales no son un fallo. Los totales cambian y nunca son
> constantes futuras.

### Recuentos fechados, no expectativas permanentes

| Fecha/hora UTC | Fuente/ámbito | `session` | `session_v2` | Lectura |
|---|---|---:|---:|---|
| 2026-10-24 (ventana de observación anterior; la hora UTC no quedó en los artefactos disponibles) | Recuento histórico citado en el documento anterior | 881 | 884 | Observación puntual; no es un requisito futuro |
| 2026-10-24T20:29:17Z–20:30:48Z | Snapshot e informe histórico de cutover | 881 | 881 tras la migración según el informe | Observación de ese cutover, no constante |
| 2026-10-24T22:03:41Z–22:03:43Z | Copia completada del sandbox; SQLite `mode=ro`, `query_only`, `BEGIN` | 881 | 887 | `v1_missing_in_v2=0`, `v2_only=6`, `quick_check=ok` |

La última fila pertenece a la copia sandbox, no debe presentarse como una
medición en vivo de producción. Sesiones V2 nativas explican que el total V2
pueda superar el total V1; cobertura completa se decide por IDs ausentes.

### El intento de migración interrumpido (estado histórico de 2026-10-24)

La base productiva arrastra un intento de migración v1→v2 **interrumpido** del
2026-10-24 15:25:

```
kv['migration.v1-v2'] = {"phase":"sessions","cursor":"[IDENTIFICADOR DE SESIÓN REDACTADO]"}
session_v2 = 97 filas (de 880 sesiones v1)
```

Es decir: la migración de sesiones empezó, copió 97 sesiones y se paró a
mitad. El esquema de V2 **ya está aplicado** (tablas `session_v2`,
`session_message` recreada, `kv`, `instruction_*`, `session_pending`,
`session_inbox`, `worktree`; y `event` con la columna `created` añadida), pero
los datos están a medias.

**Un OpenCode 2 arrancado contra esa base NO la termina de forma limpia:**
retoma desde el cursor y las 97 sesiones ya migradas se quedan con los valores
viejos (los de las 15:25) mientras las demás se resuelven de nuevo, con lo que
las sesiones migradas quedan con un `project_id`/`directory` potencialmente
inconsistente respecto a las demás.

Por eso el cutover **no** puede consistir en "arrancar OpenCode 2 y ya está":
hay que resetear antes el estado de migración (ver
[el reset](#el-reset-del-estado-de-migración-el-punto-delicado)).

### Estado del backup

| Artefacto | Qué es |
|-----------|--------|
| `MANIFEST.tsv` / `MANIFEST-FILES.tsv` | Inventario con sha256 de todo lo respaldado |
| `opencode.db` | Copia consistente de la base (API de backup de SQLite), `quick_check=ok`, con el intento interrumpido |
| `opencode.db.migrated` | La misma base **ya migrada** por V2: `session_v2=878`, marcador `{"phase":"completed"}`. Sirve de **referencia** para saber qué escribe la migración |
| `home/` | `[RUTA PERSONAL REDACTADA]`, `[RUTA PERSONAL REDACTADA]`, `[RUTA PERSONAL REDACTADA]`, `[RUTA PERSONAL REDACTADA]`, `[RUTA PERSONAL REDACTADA]`, `auth.json` |
| `omarchy/` | Los tres ficheros de Omarchy que se respaldaron (por si acaso) |

`opencode.db.migrated` **no está respaldado en `MANIFEST.tsv`** (se generó
después, durante el ensayo). El cutover lo usa solo como **referencia de
lectura** para el diff del paso 3; no depende de él para el resultado.

---

## Decisiones D1 y D2

### D1 — Migrar los datos (no empezar de cero)

La decisión histórica fue migrar las sesiones y credenciales de OpenCode 1 a
las tablas de OpenCode 2. El recuento de 880 sesiones, 28 892 mensajes y
131 143 partes pertenece a la observación de 2026-10-24 15:25 local descrita
arriba; no es un total actual ni una constante.

Consecuencia asumida: **una base migrada no es retrocompatible**. Reinstalar
OpenCode 1 no deshace la migración; una restauración exigiría el backup
completo y autorización independiente.

### D2 — No tocar Omarchy

Forge instala su propio build pinado en un prefix propio
(`[RUTA PERSONAL REDACTADA]`) y lo invoca **por ruta absoluta**. El
wrapper de Omarchy (`[RUTA PERSONAL REDACTADA]`, el `opencode` del PATH) **no se
toca**: una actualización de Omarchy puede reinstalar OpenCode 1 en el PATH, y
eso no afecta a Forge porque Forge nunca usa ese binario.

La intención es no modificar nada bajo `[RUTA PERSONAL REDACTADA]`. La evidencia
histórica disponible se limita a una huella de metadatos hasta profundidad 3
y checksums de tres ficheros Omarchy respaldados; no es una comprobación
exhaustiva del contenido de todo el árbol.

---

## Archivos y rutas reales

Los utilitarios de cutover **no están en el repositorio**. En esta máquina,
los ficheros reales son:

```text
[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/cutover.sh
[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/ROLLBACK.sh
[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/lib/dbtool.py
[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/CUTOVER-NOTES.md  # este documento
[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/REMEDIATION-REPORT.md
```

Los scripts y notas de sandbox restantes también viven bajo ese directorio
externo. Las fuentes de producto en el repo son `install.sh` (raíz) y
`open-code/forge-opencode.sh`; `open-code/install-opencode.sh` es el helper de
instalación del overlay, no el instalador de usuario.

---

## Cómo ejecutar el cutover

### Requisitos previos

1. **Cerrar la sesión de OpenCode 1.19.4** que tiene la base abierta. Es
   imprescindible: el preflight escanea `/proc` y aborta si la base objetivo
   tiene holders. No cierres procesos ajenos; si no es posible identificar los
   destinos o leer `/proc`, el inventario queda NO EXHAUSTIVO y el script falla
   de forma cerrada.
3. El repo debe estar limpio y en `master`:
   ```bash
   git -C [RUTA PERSONAL REDACTADA] status --porcelain
   git -C [RUTA PERSONAL REDACTADA] rev-parse --abbrev-ref HEAD
   ```

### Comando

```bash
cd [RUTA PERSONAL REDACTADA]
bash [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/cutover.sh
```

Ese es el path externo observado en esta máquina; no forma parte del repo. La
ejecución del cutover inicia la migración y requiere autorización operativa
independiente. No es parte del checklist de aceptación ni se ejecutó durante
esta remediación.

Sin variables de entorno, el script usa:

| Variable | Por defecto |
|----------|-------------|
| `CUTOVER_HOME` | `$HOME` |
| `CUTOVER_BACKUP_DIR` | `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` |
| `CUTOVER_REPO_ROOT` | la raíz del repo desde la que se invoca el script |
| `CUTOVER_DB` | `[RUTA PERSONAL REDACTADA]` |
| `CUTOVER_PRODUCTION_DB` | `[RUTA PERSONAL REDACTADA]` del home del usuario según `getent passwd` (independiente de `CUTOVER_HOME`); referencia para distinguir producción de sandbox |
| `CUTOVER_EXPECTED_BRANCH` | `master` |
| `CUTOVER_EXPECTED_COMMIT` | el commit actual (no se fija) |
| `CUTOVER_EXPECTED_VERSION` | `2.1.4` |
| `CUTOVER_MIGRATION_TIMEOUT` | `3600` segundos |
| `CUTOVER_VERIFY_BACKUP_HASH` | `1` (verifica el sha256 de la copia del backup) |

Todas las rutas se pueden mover: es lo que permite ensayar en sandbox.

### Código de salida

| Código | Significado |
|--------|-------------|
| `0` | El script terminó con éxito en las comprobaciones que implementa; no acredita la enumeración runtime exacta del guard ni la corroboración funcional del hook |
| `1` | Fallo. El informe dice el paso, la salida literal y qué hacer |

El informe queda en `<backup>/CUTOVER-REPORT.md` **también cuando falla**.

---

## Qué hace el script, paso a paso

Todos los pasos son **fail-fast**: si uno falla, el script escribe el informe y
sale con código 1 **sin reparar a medias**. Si la visibilidad de procesos es
incompleta, no declara el inventario exhaustivo ni detiene procesos.

### 1. PREFLIGHT

1. **1.1a — Inventario exhaustivo y ningún escritor.** Se recorren los procesos
   visibles en `/proc` y se busca
   cualquiera que tenga un descriptor abierto sobre la base, su `-wal` o su
   `-shm`. ` (deleted)` se normaliza solo para comparar el nombre, conservando
   la ruta original, PID e inicio. El alcance se clasifica por destinos
   accesibles, no solo por nombre del ejecutable. Si un PID desaparece o
   `/proc`, `fd` o `environ` no son legibles, el inventario se marca NO
   EXHAUSTIVO y se aborta; no se declara ausencia de escritores. Si hay holder,
   aborta sin detenerlo.
1. **1.1b — Procesos `opencode` vivos.** Se listan y se clasifican. Un proceso
   `opencode` que opera sobre **otra** base (por ejemplo el servicio de V2 de
   una sesión de pruebas) se tolera, pero queda registrado por destino en el
   informe. Un destino accesible hacia la base objetivo aborta.
   Caso detectado en la evidencia de remediación (observación del 2026-10-24,
   hora UTC del muestreo no conservada): PID [PID REDACTADO], inicio `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` ticks,
   exe `[RUTA DE LABORATORIO REDACTADA]@opencode/cli/bin/opencode.exe (deleted)`;
   sus FDs apuntaban a DB/WAL/SHM bajo `[RUTA DE LABORATORIO REDACTADA]`, no a
   producción. El proceso preexistente no se detuvo. El inventario corregido
   compara el exe normalizado, conserva el original y clasifica por destino.
1. **1.2 — Backup verificado.** El directorio de backup existe, `MANIFEST.tsv`
   tiene fila para la base, el **tamaño** coincide con el manifest y (por
   defecto) el **sha256** también.
2. **1.3 — Espacio en disco.** En el directorio de backup y en el directorio de
   datos debe haber `tamaño de la base + 512 MB`.
3. **1.4 — Repo.** El script conserva el preflight de rama `master`, working
   tree limpio y commit esperado. Ese era el estado del cutover histórico; la
   rama de remediación actual (`fix/fix-v2-launcher-verifiers`) no es un estado
   desde el que se autorice ejecutar el cutover.
4. **1.5 — Base productiva.** `quick_check = ok`.
5. **1.6 — Huella de lo que no se debe tocar.** Se calcula la huella de
   `[RUTA PERSONAL REDACTADA]` y de `[RUTA PERSONAL REDACTADA]` para compararla al final.
   La huella de Omarchy es de metadatos hasta profundidad 3, no de contenido
   exhaustivo.

### 2. SNAPSHOT FRESCO DE LA BASE PRODUCTIVA

```python
sqlite3.connect(src, ...).backup(dst)   # NUNCA `cp`
```

Se escribe en `<backup>/opencode.db.precutover` y se verifica `quick_check=ok`.

Dos detalles importantes:

- **Nunca `cp`**: copiar a pelo una base con `-wal`/`-shm` vivos produce una
  base inconsistente.
- **La fuente se abre en solo lectura.** Esto evita que la herramienta haga
  escrituras/checkpoint al origen al crear el snapshot. No garantiza que
  servicios ajenos no escriban concurrentemente en la base productiva; la
  evidencia de no acceso se limita a las ventanas, procesos y FDs registrados
  en `REMEDIATION-REPORT.md`.

Del snapshot se conserva el conjunto de IDs V1 que debe cubrir la migración.
El criterio permanente es el anti-join `v1_missing_in_v2 == 0`, no la igualdad
de recuentos: pueden existir sesiones nativas V2 adicionales. Se informan
`session`, `session_v2`, `v1_missing_in_v2` y `v2_only`; los recuentos no son
constantes futuras.

### 3. RESET DEL ESTADO DE MIGRACIÓN (quirúrgico)

Ver [la sección dedicada](#el-reset-del-estado-de-migración-el-punto-delicado).

### 4. REEMPLAZO DE LA BASE PRODUCTIVA

- La base original se **aparta** (rename) a
  `<backup>/opencode.db.precutover-original`, junto con su `-wal` y su `-shm`
  (pertenecen a la base sustituida, no a la nueva).
- El snapshot reseteado se coloca en su sitio.
- Se verifica `quick_check=ok` **ya en su sitio**, que no queda marcador de
  migración y que el conjunto de IDs V1 se conserva.

### 5. INSTALACIÓN DEL OVERLAY V2

```bash
printf 'n\n' | env -u OPENCODE_CONFIG_DIR -u OPENCODE_CONFIG \
    OPENCODE_DB=<base de sondeo> \
    bash install.sh install --target=opencode
```

Se neutralizan `OPENCODE_CONFIG_DIR` y `OPENCODE_CONFIG` para que el overlay
vaya a su sitio por defecto (`[RUTA PERSONAL REDACTADA]`), no a donde apunte
el entorno.

**Desviación deliberada respecto al enunciado:** se añade
`OPENCODE_DB=<base de sondeo>`. El instalador valida las credenciales con
`opencode auth list --standalone`, y eso **arranca un servidor de OpenCode 2**:
si esa sonda abriera la base productiva, la migración se dispararía en el paso
5 y no en el paso 6 (que es donde debe ocurrir y donde se documenta). Con la
base de sondeo, la sonda valida lo mismo (las credenciales salen de
`[RUTA PERSONAL REDACTADA]`) sin tocar la base productiva.

> Nota: `[RUTA PERSONAL REDACTADA]` solo trae `MINIMAX_API_KEY`. Si algún día trae
> `OPENAI_API_KEY`, el instalador ni siquiera hace la sonda. Con el estado
> actual, la sonda sí se hace — y por eso importa aislarla.

Se verifica después: el prefix del binario pinado existe, el binario responde
`2.1.4`, la config del overlay está en dialecto V2 (`plugins` como array de
rutas de directorio, `providers` presente, sin `small_model`), el paquete
`plugin-packages/forge-guard/` está instalado y el manifest
`[RUTA PERSONAL REDACTADA]` registra `dir`, `config_file` y `binary`.

### 6. MIGRACIÓN

Ver [la sección dedicada](#cómo-se-dispara-la-migración-y-cómo-se-consulta).

### 7. VERIFICACIÓN

Las comprobaciones estáticas/DB que implementa el script fallan con código 1
si no pasan. La afirmación histórica de que la enumeración exacta de plugins
quedaba bloqueada por OpenCode 2.1.4 está **REFUTADA** por la evidencia runtime
posterior; véase la [nota complementaria de seguridad y estado](#nota-complementaria-2026-10-25).

| # | Comprobación |
|---|--------------|
| 7.1 | La versión de OpenCode 2 es `2.1.4` |
| 7.2 | El marcador de migración dice `completed` |
| 7.3 | Anti-join de IDs: `v1_missing_in_v2 == 0`; los conteos de `session`/`session_v2` y `v2_only` son informativos |
| 7.4 | `quick_check` de la base es `ok` |
| 7.5 | `auth list --standalone --format json` contiene `openai` |
| 7.6 | `auth list --standalone --format json` contiene `minimax-coding-plan` |
| 7.7 | `plugins` es un array de rutas de directorio |
| 7.8 | `providers` está declarado |
| 7.9 | No queda `small_model` (dialecto V1) |
| 7.10 | `plugin-packages/forge-guard/` está instalado, con su `package.json` |
| 7.11 | El plugin referenciado por la config es un directorio resoluble con entrypoint |
| 7.12 | `[RUTA PERSONAL REDACTADA]` está presente |
| 7.13 | El manifest registra `binary` |
| 7.14 | La huella limitada de metadatos de `[RUTA PERSONAL REDACTADA]` hasta profundidad 3 coincide (no equivale a comparar exhaustivamente su contenido) |
| 7.15 | `[RUTA PERSONAL REDACTADA]` tiene la **misma** huella que en el preflight |
| 7.16 | Enumeración runtime exacta de `forge-guard` | La CLI real debe producir exactamente una fila local `forge-guard` desde un backend efímero aislado; `GET /api/plugin` se registra como superficie/contrato observado por separado |

La tabla original de 7.16 describía el resultado de la ejecución histórica
fría, después refutada por la observación caliente. El supervisor corregido
normaliza ambas condiciones: copia el overlay/config efectivo sin registros de
servicio, arranca `serve --service --hostname 127.0.0.1 --port 0`, verifica el
registro y la salud autenticada y sondea el `plugin list` real hasta una fila
exacta (cada llamada ≤2 s, 250 ms entre llamadas, presupuesto 30 s/35 s con
limpieza). Una salida vacía no se acepta. El endpoint `/api/plugin` observado
con `data=[]` no se sustituye ni se fuerza a coincidir; la evidencia no
establece que las superficies sean necesariamente independientes.

### 8. INFORME

`<backup>/CUTOVER-REPORT.md`: conserva el informe histórico del cutover. Los
informes de remediación añaden correcciones en una nota separada; no se
reescribe el informe histórico ni se vuelcan payloads/secretos de auth o
sesiones.

---

## El reset del estado de migración (el punto delicado)

### Cómo se determinó empíricamente qué es de V2

**1. Diff contra una base v1 prístina.** Se generó una base nueva con el
OpenCode 1.19.4 real (`opencode auth list` contra un `HOME` y un `OPENCODE_DB`
temporales) y se comparó su esquema con el de la base productiva:

| Solo en la base v1 prístina | Solo en la base del cutover (creado por V2) |
|----------------------------|--------------------------------------------|
| `data_migration`, `session_context_epoch`, `session_input` | `instruction_blob`, `instruction_entry`, `instruction_state`, `kv`, `session_inbox`, `session_pending`, `session_v2`, `worktree` |

`data_migration`, `session_context_epoch` y `session_input` son tablas de v1
que **V2 dropea** (m38 `loose_psylocke`), así que ya no están.

**2. Diff contra la base ya migrada** (`opencode.db.migrated`): el script lo
recalcula en cada ejecución y lo deja en el informe. Cambian de recuento
`project` (+3), `session_message` (+2 511 en el sandbox de 150 sesiones) y
`session_v2` (+53).

**3. El código de OpenCode 2.1.4**, que es la prueba definitiva:

| Estructura | Por qué es de V2 |
|------------|------------------|
| `session_v2` | La crea la migración de esquema m38 (`[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]_loose_psylocke`) |
| `session_message` | m38 ** dropea la de v1 y la recrea**: su FK pasa de `session(id)` a `session_v2(id)`. Las columnas coinciden; la FK es la prueba |
| `event` | V2 es su dueño: m36 (`reset_v2_session_state`) la vacía, y la migración de sesiones la vacía en su fase *"Clearing old events"* |
| `event_sequence` | La escribe la migración de sesiones (un `aggregate_id` por sesión migrada) |
| `kv['migration.v1-v2']` | El marcador de estado de la migración |

Los informes históricos contienen una discrepancia que no debe ocultarse ni
convertirse en una constante. En el cutover archivado, generado
`2026-10-24T20:30:48Z`, la tabla SQLite registra `event` [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]→[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] (delta
−4410) y `event_sequence` 881→878 (delta −3), pero la prosa del mismo informe
afirma incorrectamente que ambos recuentos eran iguales. Otra observación
citada en el material previo informa `event_sequence` 881→978; la diferencia
aritmética de ese par es +97. Ese par contradice la fila histórica 881→878 y no
se dispone de una hora UTC más precisa para esa observación en los artefactos
retenidos. Consultas de solo lectura a las copias SQLite del snapshot
`opencode.db.precutover-original` y de referencia `opencode.db.migrated`
confirmaron [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]→[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y 881→878 (`quick_check=ok`). Se conserva la
discrepancia entre fuentes, sin forzar una conciliación ni deducir pérdida de
sesiones a partir de eventos. El generador actual presenta valores medidos y
deltas calculados por ejecución.

### Qué hace el reset

```sql
BEGIN IMMEDIATE;
  DELETE FROM event;            -- log de eventos: V2 es su dueño
  DELETE FROM event_sequence;   -- cascada sobre event
  DELETE FROM session_v2;       -- cascada sobre session_message,
                                 --   instruction_*, session_pending, session_inbox
  DELETE FROM session_message;  -- explícito (por si las FK no estuvieran activas)
  DELETE FROM instruction_entry; DELETE FROM instruction_state;
  DELETE FROM session_pending;  DELETE FROM session_inbox;
  DELETE FROM kv WHERE key = 'migration.v1-v2';   -- se BORRA la fila
COMMIT;
```

**El marcador se borra, no se actualiza.** Es un detalle que no es
cosmetico: la migración de V2 hace `INSERT` (no *upsert*) del marcador cuando
no lo encuentra. Si la fila existiera con `phase = 'sessions'` y sin cursor,
la migración migraría solo las sesiones con `id < cursor` y las de `id >=
cursor` no se migrarían nunca. Si la fila existiera con `phase = 'completed'`,
la migración no haría nada.

### Por qué el reset es reversible

- **No toca ninguna tabla de v1.** `session`, `message`, `part`, `todo`,
  `session_share`, `credential`, `account`, `account_state`, `control_account`,
  `permission`, `project`, `project_directory`, `workspace` y el journal de
  esquema `migration` conservan **exactamente** su número de filas. Eso se
  comprueba antes y después del reset, y el script aborta si no cuadra.
- **Lo que borra se regenera.** `session_v2`, `session_message` y
  `event_sequence` los reconstruye la propia migración a partir de `session`,
  `message` y `part`, que son la fuente de verdad y siguen intactos.
- **La migración es idempotente por sesión.** Usa `INSERT OR IGNORE` para
  `session_v2`, borra las `session_message` de la sesión antes de reinsertar y
  hace *upsert* de `event_sequence`. Volver a ejecutarla sobre una base ya
  migrada produce el mismo resultado.
- **Todo queda respaldado.** La base original (con el intento interrumpido) se
  aparta entera a `<backup>/opencode.db.precutover-original`.

### Precondiciones que comprueba el reset

El reset **se niega a aplicarse** si la base no tiene la forma que se ha
analizado. Comprueba:

1. Que existen `session`, `session_v2`, `session_message` y `kv`.
2. Que `session_message` tiene la FK a `session_v2` (o sea: es la tabla
   reconstruida por V2, no la de v1).
3. Que `event` tiene la columna `created` (o sea: m38 ya se aplicó).
4. Que **existe** el marcador `migration.v1-v2` y es JSON con `phase`. Si no
   existe, la base no arrastra un intento de migración y no hay nada que
   resetear: el script aborta en vez de tocar una base inesperada.

### Verificación del reset

- `quick_check = ok`.
- El marcador ha desaparecido.
- Las tablas de v1 tienen **exactamente** el mismo número de filas que antes.
- Las estructuras de V2 están **vacías**.

---

## Cómo se dispara la migración y cómo se consulta

### Qué la dispara

**El arranque del servidor de OpenCode 2.** No hay ningún comando de
"migrar". La capa `V1Migration` (`packages/core/src/database/v1-migration.bun.ts`)
está montada en las rutas del servidor (`packages/server/src/routes.ts`) y al
arrancar bifurca `run()`:

```ts
export const layer = Layer.effectDiscard(
  Effect.gen(function* () {
    runtimeState = { status: "running", progress: { label: "Clearing old events" } }
    yield* run().pipe(/* forkScoped, startImmediately */)
  }),
)
```

Y `run()` hace, con el marcador ausente:

1. `INSERT OR IGNORE` del proyecto global.
2. Como **no existe** el marcador: borra **todos** los eventos (`DELETE FROM
   event` en lotes de 1000) e inserta el marcador `{phase:'sessions'}`.
3. Recorre **todas** las filas de `session` (de la más nueva a la más vieja,
   `ORDER BY id DESC`), copiándolas a `session_v2` y reconstruyendo sus
   `session_message`.
4. Pone el marcador a `{phase:'completed'}`.

### Qué ejecuta exactamente el script

```bash
setsid env HOME=... XDG_*=... \
  OPENCODE_PASSWORD=<contraseña> OPENCODE_SERVER_PASSWORD=<contraseña> \
  OPENCODE_DB=<base productiva> \
  OPENCODE_CONFIG_DIR=[RUTA PERSONAL REDACTADA] \
  OPENCODE_CONFIG=[RUTA PERSONAL REDACTADA] \
  OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
  OPENCODE_DISABLE_CHANNEL_DB=1 OPENCODE_CONFIG_PROJECT_DISABLE=1 \
  OPENCODE_DISABLE_FILEWATCHER=1 \
  <prefix>/node_modules/.bin/opencode serve --hostname 127.0.0.1 --port <libre> --print-logs
```

**Histórico, anterior a la remediación:** el servidor privado (no el de fondo
compartido) tenía una contraseña para consultar el endpoint de estado. La
revisión estática de aquella versión mostró que `stop_server` también invocaba
`kill_writers_on_db CUTOVER_DB`, que enviaba TERM/KILL a todos los procesos con
FDs hacia la DB y podía afectar un holder ajeno aparecido tras el preflight.
Ese camino se eliminó; el límite y el estado vigente constan en la [nota
complementaria de seguridad y estado](#nota-complementaria-2026-10-25). El
script externo sigue sin ejecutarse en esta remediación.

### Cómo se consulta el estado

```bash
curl -u opencode:<contraseña> \
  http://127.0.0.1:<puerto>/api/experimental/migration/v1
```

Respuestas posibles:

```json
{"status":"required"}
{"status":"running","progress":{"label":"Migrating sessions","numerator":190,"denominator":878}}
{"status":"completed"}
{"status":"error","error":"..."}
```

El script sondea ese endpoint hasta que dice `completed` (o `error`, que es
fallo) y después comprueba el marcador `{"phase":"completed"}`, integridad y
cobertura por IDs: `v1_missing_in_v2 == 0`. Informa recuentos y `v2_only`;
ninguna igualdad de recuentos se exige de forma permanente.

### Cuánto tarda

| Escenario | Tiempo |
|-----------|--------|
| Ensayo sandbox histórico, con 878 sesiones en la copia del backup (28 892 mensajes, 131 143 partes) | **1 min 38 s** de cutover completo; medición histórica, no estimación garantizada |

---

## Checklist de verificación posterior

Comprobaciones de lectura posteriores, sin iniciar ni reintentar una
migración. Comprueba el inventario de plugins mediante el launcher corregido:

```bash
cd [RUTA PERSONAL REDACTADA]
# 1. Diagnóstico estático y probes aislados de auth/session/plugins
bash install.sh status
bash install.sh doctor

# 2. Versión fijada
[RUTA PERSONAL REDACTADA] --version

# 3. Enumeración runtime real, aislada y exacta
[RUTA PERSONAL REDACTADA] plugin list

# 4. Log: buscar el evento de carga (no demuestra por sí solo el comportamiento del hook)
grep -F 'loading plugin' [RUTA PERSONAL REDACTADA] | grep -F 'forge-guard/index.js'
```

Resultado esperado: salida de `plugin list` producida por OpenCode 2.1.4 con
una sola fila local `forge-guard`, RC 0, tanto si no había servicio previo como
si había un servicio caliente. `No plugins found`, una fila adicional, timeout
o RC no cero no superan la enumeración. La tabla no se sintetiza desde el
config ni desde `package.json`.

La conclusión histórica “2.1.4 no enumera plugins locales” queda **refutada**.
El síntoma real dependía del estado/contexto del servicio: con servicio frío,
el CLI podía devolver `No plugins found`; después de cargar el overlay, la
misma CLI enumeraba `forge-guard`. El launcher evita la carrera en vez de
esperar un servicio compartido: clona en privado el overlay/config efectivos,
preserva declaraciones/opciones y rutas relativas, omite registros de servicio,
usa XDG state privado, inicia `serve --service --hostname 127.0.0.1 --port 0`,
verifica registro/PID/listener y health autenticado y sondea el CLI real cada
250 ms (cada intento ≤2 s; 30 s para preparación/arranque/sondeo, 35 s total
con limpieza). Solo publica la salida completa del intento exacto después de
limpiar; no inicia backend para `plugin list --help` ni inyecta `--standalone`.

`GET /api/plugin` fue observado con HTTP 200 y `data=[]` incluso después de que
`plugin list` enumeró el guard. Su descripción documentada es el estado de
plugins habilitados del servidor; no se fuerza su salida ni se infiere que los
inventarios CLI/API sean necesariamente independientes. El log `loading
plugin ... forge-guard/index.js` corrobora actividad del cargador, no sustituye
la tabla CLI ni una prueba funcional del hook. La corroboración funcional nueva
del hook sigue siendo independiente; la evidencia histórica de denegación de
commit no se presenta como una prueba nueva.

`status` y `doctor` realizan probes de auth/sesiones y una sonda runtime
separada de plugins. Esta copia usa la config y los paquetes instalados que
selecciona el manifest (no el checkout), preserva declaraciones/opciones y
rutas relativas, excluye MCP/proveedores, y usa una DB privada coherente
copiada desde una conexión SQLite `mode=ro`. El launcher instalado produce la
misma enumeración real. `OK` significa lista exacta; aislamiento/dependencias
no preparables es `UNAVAILABLE`; ejecución vacía/errónea/conjunto incorrecto es
`INVALID`/`MISMATCH`. Los dos estados no superados fuerzan RC 1. Los payloads de
auth/sesiones no se muestran; no se repara ni migra producción.

La cobertura de DB puede revisarse aparte con SQL equivalente en una conexión
`mode=ro`, `PRAGMA query_only=ON` y transacción `BEGIN`: el anti-join de IDs V1
ausentes en `session_v2` debe ser cero; informar ambos totales y `v2_only`.
Los conteos son observaciones con timestamp. No se recomienda como checklist
abrir `auth list`/`session list` directamente sobre producción, pues esos
comandos del CLI pueden iniciar runtime.

---

## Si una comprobación falla

Detén el procedimiento en el paso fallido y conserva el informe. No edites
manualmente el marcador, no borres/reescribas tablas ni bases, no copies la DB
activa con `cp`, no ejecutes otro cutover y no cierres procesos ajenos. Si el
preflight informa inventario NO EXHAUSTIVO, no se puede concluir que no haya
holders; la comprobación debe repetirse solo cuando `/proc` sea legible y el
inventario estable.

Si el marcador no es `completed` o `v1_missing_in_v2` no es cero, recopila la
salida saneada y el estado de solo lectura para una decisión operativa
independiente. No se recomienda rollback como remediación automática. Si la
enumeración runtime queda `UNAVAILABLE`, `INVALID` o `MISMATCH`, conserva la
evidencia y no declares saludable el overlay; no relajes el criterio ni repitas
la migración.

---

## Reversión

La herramienta de restauración existe en
`[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/ROLLBACK.sh`. La reversión es
una operación separada que requiere decisión y autorización explícitas; no es
la remediación recomendada para el bloqueo de enumeración ni para una
comprobación diagnóstica en rojo. Este documento no autoriza su ejecución.

Qué hace:

1. Revisa los holders y el inventario de procesos; aborta si `/proc` no permite
   declarar el inventario exhaustivo o si algún proceso apunta a la base.
2. Restaura la base original desde `<backup>/opencode.db.precutover-original`
   (con su `-wal`/`-shm`), y aparta la base migrada a
   `<backup>/opencode.db.postcutover-v2`. Si ese original no existe, usa la
   copia del backup (`<backup>/opencode.db`).
3. Verifica `quick_check=ok` y que el marcador vuelve al estado v1.
4. Elimina el overlay V2 (`[RUTA PERSONAL REDACTADA]`), el launcher
   (`[RUTA PERSONAL REDACTADA]`) y el prefix del binario pinado
   (`[RUTA PERSONAL REDACTADA]`).
5. Restaura `[RUTA PERSONAL REDACTADA]` y `[RUTA PERSONAL REDACTADA]` desde el backup.
6. Restaura `[RUTA PERSONAL REDACTADA]` (la config global de OpenCode 1) si el backup
   la trae.
7. **No modifica Omarchy.** El check histórico sobre Omarchy solo cubrió
   metadatos hasta profundidad 3 y tres ficheros respaldados, no todo el
   contenido.

Verificado en sandbox, a escala real: tras la reversión, la base vuelve a
tener el mismo número de sesiones v1, `session_v2` con las 97 filas del
intento interrumpido y el marcador `{"phase":"sessions","cursor":"[IDENTIFICADOR DE SESIÓN REDACTADO]"}`.

---

## Limitaciones conocidas

- **Una base migrada no es compatible con OpenCode 1.** Cualquier restauración
  es una operación separada y requiere respaldo completo y autorización.
- **El `-wal`/`-shm` de la base original se aparta al backup**, no se reinstala
  junto a la base restaurada: son los de una base que ya no está en producción.
  La reversión los restaura junto a la base original.
- **HISTÓRICO Y REFUTADO — enumeración del plugin local.** En las ejecuciones
  frías previas, `plugin list` (con o sin `--builtin`) y `GET /api/plugin`
  pudieron devolver inventario vacío con RC/HTTP satisfactorios aunque el
  runtime registrase la carga del guard. Una lista vacía no prueba ausencia ni
  salud. La evidencia runtime posterior obtuvo la fila exacta `forge-guard`;
  esto no corrobora la función del hook, cuya corroboración funcional nueva no
  se ejecutó. Véase la [nota complementaria de seguridad y estado](#nota-complementaria-2026-10-25).
- **El primer arranque de OpenCode 2 dispara la migración.** Cualquier
  comando de V2 que abra la base productiva (`auth list`, `serve`, un `run`)
  la dispara. Por eso el orden es: reset → sustitución → overlay → migración.
- **La cobertura no es igualdad de recuentos.** El criterio es
  `v1_missing_in_v2 == 0`; `v2_only` se informa y puede ser positivo por
  sesiones nativas V2. La igualdad de recuentos solo puede anotarse como una
  observación inmediatamente posterior al cutover.
- **El inventario de procesos falla cerrado.** Normaliza el sufijo literal
  ` (deleted)` para clasificar exe, conserva la ruta original/PID/inicio y
  clasifica por destinos DB accesibles. Desapariciones o permisos inaccesibles
  significan inventario NO EXHAUSTIVO y aborto, sin cerrar procesos.
- **HISTÓRICO — riesgo del camino anterior de limpieza.** La versión anterior
  de `cutover.sh` podía enviar TERM/KILL a procesos descubiertos por sus FDs;
  ese camino indiscriminado se eliminó. El estado actual y sus límites están
  en la [nota complementaria de seguridad y estado](#nota-complementaria-2026-10-25).

## Nota complementaria (2026-10-25)

- El camino de señalización indiscriminada fue eliminado. Solo se permite
  terminar el servidor propio, registrado como hijo directo y verificado por
  inicio/identidad de ejecutable, mediante `pidfd`.
- Holders ajenos o no atribuibles, y cualquier inventario incompleto, provocan
  fallo sin señalizarlos. Las sondas no confieren propiedad sobre procesos
  desprendidos; quedan sin adoptar y causan aborto si no son atribuibles.
- La mitigación de `cutover.sh` y `ROLLBACK.sh` se comprobó exclusivamente
  mediante análisis estático: no hubo validación operativa de esos scripts ni
  se excluye la existencia de accesos concurrentes entre comprobaciones.
- El cutover ya está **completado**. Esta corrección no autoriza repetirlo ni
  ejecutar `ROLLBACK.sh`.
- Un aborto posterior a una modificación puede dejar cambios parciales. No hay
  rollback ni recuperación automática; el informe se escribe después de la
  limpieza intentada y registra los holders no detenidos y los errores.

## Addendum — follow-ups de seguridad y alcance de aceptación (2026-10-25)

Este cierre documenta pruebas acotadas de funciones reutilizables y una
corroboración directa del hook. **No es una aceptación integral del cutover.**
Las funciones reales compartidas se probaron contra SQLite y procesos
sintéticos; no se reimplementaron. Antes de las pruebas sensibles se acreditó
un namespace PID privado rootless, `/proc` privado y un watchdog exterior con
limpieza independiente. No se ejecutaron ni se hizo `source` de
`cutover.sh`/`ROLLBACK.sh`, no se ejecutó `dbtool.py`, y no se hizo migración,
reset ni restauración.

| Follow-up | Requisito → resultado | Límite / estado |
|---|---|---|
| **#1 — snapshot, deadline y fusible** | Validación dinámica de funciones reales compartidas de `open-code/lib/plugin-sync.py` sobre DB SQLite y procesos sintéticos. El banco completo terminó con 52 casos: 43 dinámicos, 4 simulados, 5 inspecciones, 0 fallos, RC 0. | Ya existía antes de este lote una prueba puntual dinámica del fusible: RC 124, backend propio terminado y raíz privada eliminada. El objetivo adicional de este follow-up era cobertura automatizada y repetible, no afirmar que faltaba toda evidencia dinámica. Las rutas de fallo provocadas por `FORGE_V2_TEST_NO_PIDFD` y `FORGE_V2_TEST_HANG_SUITE` no pertenecen a la ejecución verde estándar. |
| **#2 — pidfd y clasificación de holders** | Validación de las funciones reales compartidas (incluida la nueva biblioteca externa) con procesos/ficheros sintéticos: pidfd, verificación de identidad, DB/WAL/SHM/`-journal`, rutas `deleted` y comportamiento de grupos. La ejecución separa las pruebas dinámicas de las 4 simulaciones de condición del SO y las 5 inspecciones. | No se probó señalización de procesos del host ni reutilización real de PID; permisos, desaparición y reutilización se inyectaron en simulación. Funciones aceptadas no equivalen a operación del entrypoint completo. |
| **#3 — limpieza de grupo y descendientes** | Riesgo residual **aceptado y documentado**. Se conserva `killpg` y el contrato existente; `GRP-1` probó dinámicamente un caso de líder que sale temprano dejando un descendiente propio, y el grupo quedó vacío. | pidfd identifica un proceso, no conserva por sí mismo el contrato de limpieza de grupos/descendientes. El caso del líder temprano no prueba todos los ordenamientos ni carreras; queda un residuo teórico de reutilización de PID/PGID. Retirar `killpg` exige otro plan con diseño de seguimiento de descendientes o contención equivalente; no se sustituye mecánicamente por pidfd. |
| **#4 — política forge-guard** | Se cargó el paquete real y se llamó directamente su `execute.before` con contexto simulado. Suite adaptada: 18/18 PASS en cinco ejecuciones; cero push intentados, cero commits en ramas protegidas y tres commits solo en `feature`. | Corroboración directa del hook con contexto simulado; **despacho extremo a extremo de OpenCode no probado**. No hubo sesiones/conversaciones reales ni una orden de shell despachada por OpenCode. La política del guard no se cambió. |
| **#5 — PID [PID REDACTADO]** | La intervención operacional separada de Step 4.2 **se llevó a cabo** mediante inspección de solo lectura. Se verificó identidad con pidfd abierto, UID 1000, `inicio_ticks=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, exe `[RUTA DE LABORATORIO REDACTADA]@opencode/cli/bin/opencode.exe (deleted)`, cmdline `opencode serve --hostname 127.0.0.1 --port [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] --print-logs` y FDs DB/WAL/SHM del laboratorio (todos `(deleted)`); no se observaron descendientes ni TTY y hubo cero conexiones establecidas. | **Resultado terminal: BLOQUEO** porque no se acreditó la residualidad: `/proc/<pid>/fd` fue inaccesible por EACCES para tres procesos no-zombie de UID 1000: PID [PID REDACTADO] (`systemd --user`, padre del objetivo), 863 (`(sd-pam)`) y 1169 (`fusermount3`). No pueden descartarse referencias previas. No se envió ninguna señal; PID [PID REDACTADO] sigue vivo e intacto. Evidencia: [`[RUTA DE LABORATORIO REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-intervention.md`]([RUTA DE LABORATORIO REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-intervention.md). Es una intervención operacional distinta de la cobertura sintética, no forma parte del GLOBAL VERIFIER y no se ejecutó desde ninguna herramienta de tests. |

### Qué significan los resultados

Los 52 casos de `safety-results.md` distinguen **43 dinámicos** (funciones
reales y recursos propios bajo contención), **4 simulaciones** (condiciones del
SO inyectadas, no señales reales ni PID reutilizado) y **5 inspecciones**
(identidad, firmas y ejecución de entrypoints). El namespace PID rootless y el
watchdog exterior estaban listos antes de las llamadas sensibles. Los
interruptores `FORGE_V2_TEST_NO_PIDFD` y `FORGE_V2_TEST_HANG_SUITE` permiten
ejercitar fallos de barrera/limpieza, pero no se activan en la ejecución verde
estándar; su alcance no se presenta como regresión cubierta por esa ejecución.

La prueba dinámica anterior del fusible está registrada en el informe de
remediación: RC 124 a los 33,420 ms, backend propio terminado y raíz privada
`/var/tmp/forge-opencode-plugin-list-05shwufm` eliminada. La cobertura nueva
automatiza y amplía esos chequeos; no borra ni minimiza esa evidencia previa.

La aceptación de funciones no acredita un cutover extremo a extremo: no
demuestra migración, reset, restauración ni operación completa de
`cutover.sh`/`ROLLBACK.sh` (no ejecutados). Tampoco demuestra despacho real del
hook. Los scripts completos y `dbtool.py` permanecen sin ejecutar/importar/
source.

### Identidad y huellas

“No declarada” significa que el componente no publica versión propia; no se
deduce una versión a partir del producto objetivo. El manifiesto final
`[RUTA DE LABORATORIO REDACTADA]` es la referencia para
las huellas finales externas, incluidos estos documentos; no se incrusta una
huella final de este mismo archivo.

| Componente (ruta) | Versión propia declarada | Inicial → final SHA-256 |
|---|---|---|
| `cutover.sh` — `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/cutover.sh` | No declarada; target OpenCode 2.1.4 | `6b1e7d6ee464d122e3d9380080fc474ad383e46a253a2e0aebfb927400e1f681` → `824897d990db781199c5bad26c186b7a2665c9ad167ef9482a44946780a5b613` |
| `ROLLBACK.sh` — `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/ROLLBACK.sh` | No declarada; referencias a OpenCode 1.19.4/2.1.4 no son versión del script | `691829305d19a4988ff8a0d02ffcb9705900745ab20c68b01b5d5d0ed2e5075d` → `f91e7787ce7690fc0d5ec70aaafa5c051acb3b379006214c0e870e84474f8f85` |
| `CUTOVER-NOTES.md` (este archivo) | No declarada | `a2d44ecea943c463e3e8ee06451d18c62e44281b76c650b76c075e88e83f5574` → manifiesto externo final |
| `lib/dbtool.py` — `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/lib/dbtool.py` | No declarada; docstring refiere al flujo 1.19.4→2.1.4 | `d15cc6aea6289683b9df7add7fcb82f27ba3eaddcb8368a563f1be8a98ab0db0` → sin cambios |
| `REMEDIATION-REPORT.md` — `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/REMEDIATION-REPORT.md` | No declarada; observaciones sobre OpenCode 2.1.4 | `db2db86220741ff347342554bcff859e3e2031d6bf717bba9b354b99baccca65` → manifiesto externo final |
| Nueva `lib/cutover_safety.py` — `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/lib/cutover_safety.py` | No declarada | ausente → `1e93447968a4f3ddb4395022260c89d643aa696c95edd003f853e79db4378454` |
| `open-code/lib/plugin-sync.py` | No declarada (V2-only no es semver) | `70966cf5fac50faea615d882ff2c2e326729b5df883fe14507a84c72af415e9e` → `7760fd6a143fa906d6bf5b85df1ea8715cf8d04de83be440cea75e04e4cac8b5` |
| `tests/forge_guard_plugin_unit.sh` | No declarada | `a60d8c2d6ff1b75e5fd26b8139b0abb405c77125f3ecf3d2a9c5bc1b9a8e86d4` → `72481782f412a77afe4eb091342bcfa7ba0254e9bc2cd1b57ea09a1e7379f3d8` |
| Nuevos `tests/forge_v2_safety.sh`, `tests/forge_v2_safety_harness.py` | No declarada | ausentes → `cbbbe39953c1af23935f6315a3a75908b6f24e28fc4d060739163afb3a2da4b9`, `862aee41ec88e5be92203d0bfdcd1a11a8e3aa66e2c90eef98215c4a988e5d92` |
| Paquete `open-code/plugin-packages/forge-guard/{package.json,index.js}` | `forge-guard` 1.0.0 | `package.json` `1a19e5f2dbf7c4580aaa3c128b347e314a9e0002d9a28e2236b32823b5ff0220`; `index.js` `e1d2eb0dad24c0d0f8660f0e7d58297de67a9a23d341cc47be2ea3a83e5c007a` (sin cambios) |

Para el mapa completo de requisitos, resultados, límites y evidencias, véase
`[RUTA DE LABORATORIO REDACTADA]`; para el contenido final de
los componentes externos, ejecutar `sha256sum -c` sobre el manifiesto desde la
raíz externa.
