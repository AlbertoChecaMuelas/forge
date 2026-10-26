# Informe de remediación — evidencia inicial y cierre (Step 1.2)

> **DOCUMENTO HISTÓRICO; NO OPERATIVO.** Este informe conserva contexto y resultados históricos. Los comandos, rutas y procedimientos que aparecen no son instrucciones autorizadas ni se deben ejecutar contra ninguna instalación, base de datos, respaldo, credencial o proceso. Para cualquier consumo activo, use exclusivamente el componente del checkout y sus verificadores estáticos permitidos.


- Ventana de evidencia: 2026-10-24, UTC `20:48:51Z`–`21:04:19Z`.
- Estado final: **OK — aislamiento empírico demostrado; Step 1.2 puede cerrarse.** El bloqueo inicial queda supersedido por el addendum final.
- Este archivo está en el directorio externo `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/`; no pertenece al repositorio.

## Sandbox privado

Raíz: `[RUTA DE LABORATORIO REDACTADA]` (raíz y directorios privados). Árbol relevante:

```text
sandbox/                         0700
├── home/                        0700
│   ├── .forge-state.json        0600 (manifest copiado y rebasado)
│   └── .opencode-tokens         0600 (copia; contenido no mostrado)
├── config/                      0700
│   └── opencode-forge/          0700 (overlay V2 copiado; ficheros normales 0600, ejecutables 0700)
│       ├── opencode.jsonc       0600 (instructions rebasada)
│       └── plugin-packages/forge-guard/
├── data/                        0700
│   ├── opencode/
│   │   ├── auth.json            0600 (copia; contenido no mostrado)
│   │   └── opencode.db          0600 (SQLite backup consistente)
│   └── forge/opencode-v2/       0700 (copia completa del binario pinado 2.1.4)
├── state/                       0700
└── cache/                       0700
```

Se asociaron a `HOME=$R/home`, `XDG_CONFIG_HOME=$R/config`, `XDG_DATA_HOME=$R/data`, `XDG_STATE_HOME=$R/state` y `XDG_CACHE_HOME=$R/cache`. Se verificaron los cinco directorios y sus modos. Los symlinks del overlay y del prefix clonado son relativos y resuelven dentro de sus respectivos árboles; el binario configurado en el manifest también es la copia sandbox, ejecutable, y su package metadata indica `2.1.4`. El directorio global V1 `[RUTA PERSONAL REDACTADA]` no se copió: la configuración aislada seleccionada es el overlay V2 explícito; `config/` no contiene el directorio global `opencode`.

### Rutas efectivas y resolución

Revisión estática inicial (los resultados de la ejecución aislada posterior están en el addendum):

- El manifest original registra overlay `[RUTA PERSONAL REDACTADA]`, configuración en esa carpeta y binario pinado `[RUTA PERSONAL REDACTADA]`.
- El launcher `open-code/forge-opencode.sh` obtiene el manifest desde `[RUTA PERSONAL REDACTADA]`; si existe entrada `opencode`, fuerza `OPENCODE_CONFIG_DIR`, `OPENCODE_CONFIG` y binario a los valores guardados allí (salvo override explícito `FORGE_OPENCODE_BIN`). Por tanto solo cambiar `XDG_CONFIG_HOME` no basta. En la **copia** del manifest, `dir`, `config_file` y `binary` apuntan al sandbox. El `instructions` absoluto de la copia de `opencode.jsonc` también apunta a `sandbox/config/opencode-forge/AGENTS.md`. El manifest y configuración originales no se modificaron.
- `install.sh` raíz fija el manifest en `[RUTA PERSONAL REDACTADA]`; el overlay usa `OPENCODE_CONFIG_DIR`/`OPENCODE_CONFIG` o `[RUTA PERSONAL REDACTADA]`; el prefix pinado deriva de `FORGE_OPENCODE_BIN_DIR` o `${XDG_DATA_HOME:-[RUTA PERSONAL REDACTADA]}/forge/opencode-v2`. El overlay installer real es `open-code/install-opencode.sh`; instala el launcher global en `[RUTA PERSONAL REDACTADA]`. El destino de runtime DB/auth esperado bajo el entorno aislado es `$XDG_DATA_HOME/opencode/`.
- El path solicitado `open-code/install.sh` **no existe** en este checkout. Se consultaron estáticamente el `install.sh` raíz y `open-code/install-opencode.sh` como scripts reales. No se ejecutaron.
- El manifest en sandbox señala al prefix clonado `[RUTA DE LABORATORIO REDACTADA]`, no al instalado. En la prueba final `OPENCODE_DB` se pasó solamente al proceso hijo y apuntó a la copia del sandbox; no estaba definida en el proceso padre.

## Base de datos: copia coherente y consultas de solo lectura

La fuente `[RUTA PERSONAL REDACTADA]` tenía WAL/SHM vivos (main `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes, `-wal` `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, `-shm` `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`). No se copió el fichero principal con `cp`. `prepare-sandbox.py` abrió exactamente `file:[RUTA PERSONAL REDACTADA]?mode=ro` (`sqlite3.connect(..., uri=True)`) y usó `Connection.backup()` hacia el destino del sandbox. Después cerró la conexión destino y verificó el snapshot mediante una conexión `mode=ro`.

Consultas aplicadas a la **copia** en una lectura coherente:

```sql
PRAGMA quick_check;
SELECT value FROM kv WHERE key='migration.v1-v2';
SELECT count(*) FROM session;
SELECT count(*) FROM session_v2;
SELECT count(*) FROM session AS s
LEFT JOIN session_v2 AS v ON v.id=s.id WHERE v.id IS NULL;
SELECT count(*) FROM session_v2 AS v
LEFT JOIN session AS s ON s.id=v.id WHERE s.id IS NULL;
```

Resultados: `quick_check=ok`; marcador exacto `{"phase":"completed"}`; `session=881`; `session_v2=887`; IDs V1 ausentes de V2 `0`; V2-only `6`. Los recuentos describen este snapshot y no se imponen como constantes futuras.

## Configuración, credenciales y servidores

Se copiaron overlay V2, credenciales necesarias (`.opencode-tokens` y `data/opencode/auth.json`) y manifest; las copias privadas tienen modo `0600` y los directorios `0700`. No se mostraron contenidos ni secretos. Solo se reescribieron referencias absolutas de las copias: rutas del manifest y la ruta de `instructions` en `opencode.jsonc`. La configuración original copiada conserva MCP Playwright (`npx`) y Ollama (`127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`). Para la prueba empírica se usó temporalmente una segunda copia de configuración en el sandbox sin el bloque MCP; no se hicieron solicitudes a proveedores. El manifest de sandbox se restauró al `opencode.jsonc` original al finalizar.

En la captura inicial no se lanzó OpenCode; el addendum registra la prueba sandbox posterior. No se ejecutaron Omarchy, instaladores, cutover ni rollback. Los procesos preexistentes que mantienen la DB productiva abierta no se consideraron parte de la prueba y no se tocaron. **Aclaración temporal (2026-10-25):** esto describe esa prueba, no la intervención operacional separada de Step 4.2. Para esta última sí se inspeccionaron procesos preexistentes en solo lectura; no se envió ninguna señal.

## Procesos preexistentes observados

Captura `ps` (inicio local como informa `ps`, zona local `+0200`); no se cerraron ni alteraron:

| PID | Inicio local | Cmdline resumida | FDs observados |
|---:|---|---|---|
| [PID REDACTADO] | 2026-10-24 21:36:14 | `[RUTA DE LABORATORIO REDACTADA] serve --hostname 127.0.0.1 --port [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] --print-logs` | DB/WAL/SHM sandbox con sufijo `(deleted)` |
| [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] | 2026-10-24 22:31:10 | `[RUTA PERSONAL REDACTADA] --standalone` | no se observaron FDs de DB en este PID |
| [PID REDACTADO] | 2026-10-24 22:31:10 | `[RUTA PERSONAL REDACTADA]@opencode/cli/bin/opencode.exe serve --stdio --port 0` | DB/WAL/SHM productivos |
| [PID REDACTADO] | 2026-10-24 22:32:28 | `[RUTA PERSONAL REDACTADA]@opencode/cli/bin/opencode.exe serve --service` | DB/WAL/SHM productivos |

Los procesos son evidencia observada, no fueron lanzados por esta remediación. Estos procesos eran preexistentes de la sesión de trabajo, no hijos del CLI sandbox; se conservaron intactos. La prueba final demuestra que los PID nuevos solo abrieron la copia y escucharon en loopback.

## Huellas SHA-256

Huellas calculadas de originales y copias identificadas por el backup de auditoría. Para cada fila, original y backup dieron la misma huella; no se imprimió contenido:

| Artefacto | SHA-256 |
|---|---|
| Wrapper original `[RUTA PERSONAL REDACTADA]` | `b240efa9d6020bdc513bbf48e46b6d312493d2c408f7d070555e993feea0a89b` |
| Credencial original `[RUTA PERSONAL REDACTADA]` | `[HUELLA DE CREDENCIAL REDACTADA]` |
| Credencial original `[RUTA PERSONAL REDACTADA]` | `[HUELLA DE CREDENCIAL REDACTADA]` |
| Omarchy `bin/omarchy-npx-install` | `c3f562ff7482a2ab5eee15a50a36496b8e0307e105410010ee4b43ed62bb0b7e` |
| Omarchy `bin/omarchy-remove-preinstalls` | `bfa59bec96e5ccc7f1a91ca42e6f0ba9fb45506d3ba18a9590bd04c8171cc40d` |
| Omarchy `install/packaging/npx.sh` | `7b1c1d7b9b42f18e3454b5522c60b5b7d14143a6c8344b0f60c3e16d59085de8` |

El informe histórico conserva la huella de metadatos del árbol Omarchy `603e2ec175ef3f9aa05bcdf08e258fd570144d5e5e3b6fac89b20bc1d9de96f4`; su alcance era metadatos hasta profundidad 3, no una huella exhaustiva del contenido. Las huellas de archivos anteriores son comprobación de los ficheros respaldados, no amplían ese alcance.

## Comandos ejecutados y códigos de salida

Los comandos no mostraron secretos. Se anotan los verificadores relevantes y su RC:

| Comando / comprobación | RC |
|---|---:|
| `git branch --show-current` (`fix/fix-v2-launcher-verifiers`) y `git status --porcelain` (vacío) | 0 |
| `sha256sum -c [RUTA DE LABORATORIO REDACTADA]` | 0 |
| `test -f open-code/install.sh` (archivo ausente) | 1 |
| `python3 [RUTA DE LABORATORIO REDACTADA]` — primer intento, falló antes del backup DB porque aún no se había creado `data/opencode/` (no llegó a leer DB) | 1 |
| `rm -rf -- [RUTA DE LABORATORIO REDACTADA]` — solo el sandbox parcial creado por ese intento; la ruta se había comprobado ausente antes; backups preservados | 0 |
| `python3 [RUTA DE LABORATORIO REDACTADA]` — tras crear primero `data/opencode/`; copias y backup SQLite terminados | 0 |
| `for d in home config data state cache; do test -d "$R/$d"; done` y verificación Python de modos/manifest/config/credenciales | 0 |
| Consultas SQLite `mode=ro` sobre snapshot (integridad, marcador y cobertura) | 0 |
| `ps -p [PID REDACTADO] -o pid=,lstart=,args=` y lectura de FD por `/proc/<pid>/fd` | 0 |
| `sha256sum` de wrapper, credenciales y tres ficheros Omarchy originales y respaldados | 0 |
| `test ! -e [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/REMEDIATION-REPORT.md` antes de crear el informe | 0 |

El addendum registra los comandos runtime sandbox y sus RC. La rama y el working tree del repo permanecen sin cambios por este paso.


## Addendum — prueba empírica y cierre del bloqueo (2026-10-24)

**Resultado: OK.** Se demuestra aislamiento del CLI y backend sandbox respecto de la DB original. Este addendum supersede el estado de bloqueo de la captura inicial; no avanza ni modifica el plan.

### Prueba aceptada

A las `2026-10-24T21:03:48Z` se ejecutó `python3 [RUTA DE LABORATORIO REDACTADA]` (RC **0**, finalizado `21:03:57Z`). El controlador lanzó el launcher real mediante:

```text
env -i HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_CONFIG_HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_DATA_HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_STATE_HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_CACHE_HOME=[RUTA DE LABORATORIO REDACTADA] \
  OPENCODE_DB=[RUTA DE LABORATORIO REDACTADA] \
  OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
  OPENCODE_DISABLE_CHANNEL_DB=1 OPENCODE_CONFIG_PROJECT_DISABLE=1 \
  OPENCODE_DISABLE_FILEWATCHER=1 TERM=xterm-256color PATH=/usr/bin:/bin \
  /usr/bin/bash [RUTA PERSONAL REDACTADA]
```

`OPENCODE_DB` estaba únicamente en el `env` del proceso hijo (`parent_opencode_db_set=false`); no se exportó al shell. El launcher, al no recibir subcomando, añadió `--standalone` delante. La copia temporal de config usada durante esta inspección solo quitó el servidor MCP para impedir que `npx` iniciase o accediese a red; el manifest sandbox se restauró a `sandbox/config/opencode-forge/opencode.jsonc`. No se introdujo prompt ni conversación.

### Descriptores, servidor y DB original

El CLI permaneció vivo durante la inspección. `/proc/<PID>/fd`, lectura global de nuevos procesos y `ss` dieron:

| PID propio | Cmdline/exe | Descriptores DB al inspeccionar |
|---:|---|---|
| [PID REDACTADO] | copia sandbox `.../node_modules/.bin/opencode --standalone` | ninguno |
| [PID REDACTADO] | copia sandbox `.../node_modules/@opencode/cli/bin/opencode.exe serve --stdio --port 0` | `[RUTA DE LABORATORIO REDACTADA]`, `-shm`, `-wal` |

No se encontró descriptor de ninguno de estos PID ni de ningún proceso nuevo sobre `[RUTA PERSONAL REDACTADA]`, `-wal` o `-shm`. Los únicos FDs productivos observados siguieron perteneciendo a los procesos preexistentes ya inventariados; no se señalizaron. El backend propio escuchó solo en `127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` (PID [PID REDACTADO]); las conexiones observadas fueron loopback. No hubo conexión de red externa de los PID propios.

La DB original antes y después: tamaño `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes; mtime UTC `2026-10-24T21:03:29.766835Z` (`mtime_ns=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`) en ambos extremos. Los valores fueron idénticos. En la copia sandbox, antes y después: `quick_check=ok`, marcador exacto `{"phase":"completed"}`, `session=881`, `session_v2=887`, IDs V1 ausentes `0`. No hubo indicio de inicio de migración en PTY ni en líneas nuevas del log (`migration_signal_in_pty_output=false`, `migration_signal_in_new_log_lines=false`).

### PID propios limpiados

- Pruebas `serve` que abortaron antes de abrir DB: PID [PID REDACTADO] y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]; cada proceso salió con RC 1 y no dejó servicio.
- Sondeos interactivos iniciales: PID [PID REDACTADO]; y PID [PID REDACTADO]/[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]. Se cerraron solo esos procesos.
- Inspección final previa: PID [PID REDACTADO]/[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]; se cerraron solo esos procesos.
- Prueba aceptada: PID [PID REDACTADO]/[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]; SIGTERM al grupo propio y al proceso sandbox separado. El launcher acabó con RC 130 por la señal intencional; el verificador aceptó limpieza. Ningún PID propio quedó vivo y no queda proceso cuyo ejecutable esté bajo el prefix sandbox.

Los PID productivos preexistentes (incluidos [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]) no fueron señalizados ni alterados.

### Rutas absolutas que Step 2.1 debe contemplar

No hubo ruta productiva forzada en la prueba porque se rebasó el manifest **de la copia** y se clonó el binario. La resolución que puede forzar rutas absolutas sigue siendo:

- `open-code/forge-opencode.sh:61`: `forge_state_file="[RUTA PERSONAL REDACTADA]"`. Respeta `HOME`; se neutralizó con `HOME=[RUTA DE LABORATORIO REDACTADA]`.
- Líneas 64–91: el manifest gana a `OPENCODE_CONFIG_DIR`/`OPENCODE_CONFIG` y fija config/binario. El manifest instalado contiene `[RUTA PERSONAL REDACTADA]`, `[RUTA PERSONAL REDACTADA]` y `[RUTA PERSONAL REDACTADA]`. **Solo en la copia** se sustituyeron por `[RUTA DE LABORATORIO REDACTADA]`, su `opencode.jsonc` y `[RUTA DE LABORATORIO REDACTADA]`. `OPENCODE_CONFIG_DIR`/`OPENCODE_CONFIG` por sí solos no neutralizan un manifest con valores registrados.
- DB: el launcher no fijó ruta absoluta de producción; `OPENCODE_DB` por proceso apuntó a `[RUTA DE LABORATORIO REDACTADA]`. XDG data/state/cache y HOME también apuntaron al sandbox.
- Prueba de flag que queda para Step 2.1: llamar `serve --hostname 127.0.0.1 --port <port> --print-logs` produce args `serve --standalone ...`; OpenCode 2.1.4 devuelve RC 1 (`Unrecognized flag: --standalone in command opencode serve`). Si se antepone explícitamente `--standalone`, el launcher duplica el flag y vuelve a fallar. El modo interactivo sin subcomando sí antepone el flag global correctamente y permitió esta prueba privada. Step 2.1 debe corregir la gramática/colocación de flags; no se modificó el launcher en Step 1.2.

### Comandos y códigos de salida de la comprobación

Todos los tiempos son UTC; los códigos de los controladores incluyen el RC del subproceso:

| UTC | Comando exacto | RC | Resultado |
|---|---|---:|---|
| 20:56:44–20:56:45 | `python3 [RUTA DE LABORATORIO REDACTADA]` | 2 (CLI hijo 1) | `serve` recibió `--standalone` en posición no admitida; no abrió DB ni dejó proceso. |
| 20:57:33–20:57:34 | `python3 [RUTA DE LABORATORIO REDACTADA]` (probe con `--standalone` explícito antes de `serve`) | 2 (CLI hijo 1) | El launcher duplicó el flag; no abrió DB ni dejó proceso. |
| 20:58:49–20:59:20 | `python3 [RUTA DE LABORATORIO REDACTADA]` | 2 | El primer verificador exigía encontrar el FD sandbox en el PID cliente; el proceso se limpió. Evidencia de que el config/log/plugin cargados eran sandbox. No se usó como verificación final. |
| 21:01:04–21:01:05 | `python3 [RUTA DE LABORATORIO REDACTADA]` | 2 | El verificador intermedio también exigía un FD sandbox en su instantánea; el CLI/backend sandbox fueron limpiados. No observó FD productivo nuevo. |
| 21:03:48–21:03:57 | `python3 [RUTA DE LABORATORIO REDACTADA]` | **0** | Prueba aceptada: FD de copia en PID [PID REDACTADO], ninguno productivo, listener loopback, mtime/tamaño fuente idénticos, marcador e integridad conservados; sin PID propio superviviente. |
| 21:05:38Z (verificación final del informe) | `test -s [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/REMEDIATION-REPORT.md && test -r [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/REMEDIATION-REPORT.md` | 0 | Informe existente, no vacío y legible. |

La prueba demuestra que el CLI sandbox no alcanza la base original. Las huellas saneadas de wrapper, credenciales y Omarchy siguen registradas arriba; no se añadieron contenidos secretos. No se editó el plan, no se hicieron commits y el working tree permanece intacto.


## Step 2.1 — Corrección de flags del launcher (2026-10-24)

**Resultado: OK.** Se modificó únicamente `open-code/forge-opencode.sh` en el repositorio. No se cambió la resolución de manifest/config/binario, no se tocó el plan y no se hicieron commits ni push.

### Fuente de gramática y regla aplicada

Se consultó el binario pinado exacto `[RUTA PERSONAL REDACTADA]`: versión `opencode v2.1.4`, SHA-256 `ca9b3ee262e33bb4e7aa0e1230dc61086a474c8c8016b980081d0719712fd2e7`. Las consultas `--help` del raíz y todas las hojas indicadas en la matriz dieron RC 0. `--standalone` figura en el raíz y en estas hojas: `auth list/login/logout/export/import/switch`, `session list/delete/export/import`, y las órdenes raíz `api/models/run/stats/mini/reload`. No figura en `auth`/`session` como grupo, ni en hojas de `plugin`, `mcp`, `debug` o `service`, ni en `acp`, `pair`, `serve`, `upgrade` o `uninstall`.

La resolución implementada es una tabla por rutas de comando verificadas, no una inserción universal por profundidad:

- `auth <hoja> --standalone` y `session <hoja> --standalone`: el flag va después de la hoja. Si llega explícitamente entre el grupo y la hoja (`auth --standalone list`, `session --standalone list`), se normaliza después de la hoja.
- `api|models|run|stats|mini|reload --standalone`: se inserta después del comando raíz.
- Sin subcomando/solo opciones raíz, se conserva el flag raíz para el arranque interactivo y opciones globales.
- No se inyecta en las rutas que la ayuda no declara. Si el usuario ya pasó `--standalone`, no se añade otro.
- La inspección de `--server` se detiene ante `--`; un `--server` posterior al separador es argumento literal. El flag real `--server` sigue rechazándose con RC 2 antes de ejecutar OpenCode.
- Se mantiene `"$@"` al reconstruir argumentos: se verificó un header con espacios y el argumento con espacios posterior a `--` como un único argumento.

### Matriz de órdenes revisadas

Los RC de esta tabla corresponden al launcher real invocado con `bash`, `HOME`/XDG y `OPENCODE_DB` limitados al sandbox. Ayuda de hojas se ejecutó a través del launcher salvo donde se indica consulta directa del binario pinado. Cada RC se capturó por `subprocess`/captura directa, sin tubería que oculte el resultado.

| Orden probada | Posición esperada/observada | RC y resultado |
|---|---|---:|
| `--version`; `--help` | flag raíz antes de la opción raíz | 0 cada una; versión 2.1.4 y ayuda raíz |
| Sin argumentos (PTY) | `--standalone` raíz | Se mantuvo vivo; visto `/tmp/.../.bin/opencode --standalone`; SIGTERM intencional, RC 130; backend abrió únicamente la DB sandbox |
| `auth list --format json` | después de `auth list` | 0; JSON válido, top-level `list` |
| `session list` | después de `session list` | 0 |
| `auth list/login/logout/export/import/switch --help` | después de la hoja | 0 cada una |
| `session list/delete/export/import --help` | después de la hoja | 0 cada una |
| `auth list --standalone --help`; `auth --standalone list --help`; `session --standalone list --help` | mantener en hoja; mover el flag explícito mal ubicado | 0 cada una; argumentos registrados por el binario como `auth list --standalone ...` / `session list --standalone ...`, sin duplicación |
| `plugin list` | ninguno | 0 con servicio sandbox aislado; salida de 17 bytes. Primer intento con puerto por defecto [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]: RC 1 por conflicto de bind con un servicio preexistente; reintentado usando puerto sandbox privado [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y detenido con `service stop` sandbox (RC 0) |
| `plugin list/add/check/update/remove --help` | ninguno | 0 cada una |
| `mcp list/add/auth/logout --help` | ninguno | 0 cada una |
| `debug agents/config/heap-dump/paths --help` | ninguno | 0 cada una |
| `service start/restart/status/stop/get/set/unset --help` | ninguno | 0 cada una; `service stop` ejecutado sobre el puerto privado sandbox, RC 0 |
| `api/models/run/stats/mini/reload --help` | después del comando raíz | 0 cada una |
| `acp/pair/serve/upgrade/uninstall --help` | ninguno | 0 cada una |
| `api GET /openapi.json` | después de `api` | 0; JSON OpenAPI válido, 124 rutas ([IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] bytes) |
| `api GET /api/info --header 'X-Forge-Quoting: value with spaces'` | después de `api` | 0; JSON válido, argumento de header conservado con espacios |
| `serve --help` | ninguno | 0 |
| `serve --hostname 127.0.0.1 --port [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` | ninguno; `serve` implementa su propio servidor | Listener inspeccionado en `127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, PID [PID REDACTADO], FDs DB solo en sandbox; SIGTERM intencional, RC 130 |
| `run --help -- 'message with spaces --standalone'` | después de `run`; preservar `--` y cola literal | 0; log confirma cola como un argumento, sin alteración |
| `api --server=http://127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] --help` | no aplica; rechazo del launcher | 2, sin ejecutar CLI/conectar |
| `run --help -- --server` | `--server` literal después de `--` | 0 |

La consulta directa del binario pinado cubrió además todas las filas de subcomandos de la tabla; todas sus ayudas tuvieron RC 0. Se verificó que solo los comandos listados como compatibles declaran el flag en su sección `FLAGS`, no por coincidencia con el texto informativo `--print-logs`.

### Comprobación aislada, exit codes y observaciones

Entorno hijo usado en las llamadas operativas:

```text
env -i HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_CONFIG_HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_DATA_HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_STATE_HOME=[RUTA DE LABORATORIO REDACTADA] \
  XDG_CACHE_HOME=[RUTA DE LABORATORIO REDACTADA] \
  OPENCODE_DB=[RUTA DE LABORATORIO REDACTADA] \
  OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1 \
  OPENCODE_DISABLE_CHANNEL_DB=1 OPENCODE_CONFIG_PROJECT_DISABLE=1 \
  OPENCODE_DISABLE_FILEWATCHER=1 NO_COLOR=1 TERM=xterm-256color \
  PATH=/usr/bin:/bin /usr/bin/bash [RUTA PERSONAL REDACTADA] <argumentos de la matriz>
```

`OPENCODE_DB` fue una variable del proceso hijo, no se exportó al shell. Para no iniciar MCP externo, el manifest **del sandbox** apuntó temporalmente a una copia de config sin el bloque MCP; se restauró el manifest y se eliminó esa config temporal. Solo en el archivo `service.json` sandbox se asignó temporalmente el puerto [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] al probar `plugin list`, ya que el puerto predeterminado [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] estaba ocupado por un proceso preexistente; se restauró después. No se ejecutó el binario instalado como runtime: las ayudas directas del pin fueron solo consultas `--help`/`--version`. No hubo prompts ni peticiones a modelos.

Tiempos y códigos relevantes:

| UTC | Comando | RC |
|---|---|---:|
| 21:11:13–21:11:42 | Primera matriz, antes de fijar puerto privado sandbox; incluyó `plugin list` (error de bind en [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]) y `api GET /global/health` (RC 0 pero devolvió HTML, no API JSON) | 3 controlador / plugin `1` / API `0` |
| 21:12:53–21:12:55 | `plugin list` aislado con puerto sandbox [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y luego `service stop` sandbox | 0 / 0 |
| 21:13:49–21:13:58 | Matriz completa final, incluido `auth list --format json`, `session list`, `plugin list`, ayudas por hoja y `serve` loopback | RC 0 para las órdenes normales excepto la ruta API exploratoria `/api/global/health` (RC 1); servidor RC 130 por SIGTERM intencional |
| 21:13:56.736Z | `api GET /api/global/health --header 'X-Forge-Quoting: value with spaces'` | 1, HTTP 404; ruta exploratoria corregida |
| 21:14:13.673Z | `api GET /openapi.json` | 0, JSON válido |
| 21:14:43–21:14:44 | `api GET /api/info --header 'X-Forge-Quoting: value with spaces'` | 0, JSON válido |
| 21:15:01–21:15:10 | Launcher sin argumentos en PTY, inspección y SIGTERM intencional | 130 |
| 21:15:18Z | Prueba de rechazo de `--server` y literal posterior a `--` | 2 y 0 |
| 21:15Z | Ayudas del binario instalado pinado: todas las rutas de la matriz | 0 cada una; versión 2.1.4 |
| Verificación final | `bash -n open-code/forge-opencode.sh && sh -n open-code/forge-opencode.sh && git diff --check` | 0 |

Hubo dos sondeos API exploratorios no aceptados: `GET /global/health` dio RC 0 pero la respuesta fue HTML; `GET /api/global/health` dio 404. Se usaron para localizar la ruta real y no se reportan como comprobación API exitosa; la ruta válida verificada fue `/api/info` (y `/openapi.json`).

### No acceso a DB original y limpieza

En la matriz final (21:13:49–21:13:58), DB original antes/después: tamaño `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes y mtime UTC `2026-10-24T21:13:25.735632Z` (`mtime_ns=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`) idénticos. También fueron idénticos en las ventanas del API `/api/info` (21:14:43–21:14:44), PTY (21:15:01–21:15:10) y prueba `--server` (21:15:18; tamaño igual y mtime `2026-10-24T21:15:18.278553Z` antes/después). Las inspecciones `/proc` de la matriz y de los procesos de servidor/PTY no encontraron descriptores a `[RUTA PERSONAL REDACTADA]`, `-wal` ni `-shm`; los backends inspeccionados abrieron la copia `[RUTA DE LABORATORIO REDACTADA]`. La copia terminó con `quick_check=ok`, marcador `{"phase":"completed"}`, `session=881`, `session_v2=887`, `v1_missing_in_v2=0`.

La base activa original puede recibir escrituras legítimas de procesos ajenos: después de las ventanas de verificación, un `stat` independiente a las 21:16:54Z encontró el mismo tamaño y un mtime posterior `2026-10-24T21:16:27.309281Z`. Por eso no se atribuye igualdad de mtime a todo el intervalo de pared; las comparaciones por ventana y la ausencia de FDs de nuestros PID son la evidencia pertinente. Los procesos preexistentes no se señalizaron ni alteraron.

Se limpiaron los PID propios [PID REDACTADO] (servidor loopback) y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] (interactivo/backend) con SIGTERM; no quedan ejecutables del prefix sandbox vivos. `service stop` cerró el servicio privado utilizado por `plugin list`. Manifest y `service.json` del sandbox quedaron restaurados; se borró el config temporal. El verificador resumido está en `[RUTA DE LABORATORIO REDACTADA]` (sin payloads de auth/session ni secretos).

El árbol Git quedó en la rama `fix/fix-v2-launcher-verifiers`, con solo `open-code/forge-opencode.sh` modificado; no se escribieron tests/fixtures, no se editó `.plans/current` y no se hicieron commits. El informe es externo al repo.

## Step 2.2 — Enumeración del guard: resultado histórico inicial (2026-10-24; refutado después)

**Resultado de aquella ventana: BLOCKED; conclusión general posteriormente refutada.** En esas ejecuciones frías el paquete local del guard se resolvió y el runtime registró su carga, mientras `plugin list` y `/api/plugin` devolvieron inventario vacío con RC/HTTP satisfactorios. La observación fría era válida, pero no demostraba que 2.1.4 nunca pudiera enumerar locales: una repetición posterior con el servicio del overlay caliente listó `forge-guard`. La corrección de contexto/readiness y la nueva verificación están en el addendum “Reapertura Step 2.2 / aceptación Step 3.2”. No se fabricó un listado desde la config ni se trató el vacío como salud.

### Contexto aislado y resolución del paquete

Pruebas del 2026-10-24 entre `21:21:06Z` y `21:26:27Z`, siempre con el binario sandbox de OpenCode `2.1.4`, `HOME=[RUTA DE LABORATORIO REDACTADA]`, `OPENCODE_DB=[RUTA DE LABORATORIO REDACTADA]`, XDG bajo el sandbox y manifest copiado apuntando a:

- overlay: `[RUTA DE LABORATORIO REDACTADA]`;
- config: `.../config/opencode-forge/opencode.jsonc`;
- binario: `.../data/forge/opencode-v2/node_modules/.bin/opencode`.

La config declaró exactamente `"plugins": ["./plugin-packages/forge-guard"]`; el paquete y `index.js` existían junto a la config. Con `cwd` en HOME, proyecto desechable y overlay, los registros de runtime resolvieron el plugin como `[RUTA DE LABORATORIO REDACTADA]`. Es resolución relativa al directorio de config/overlay, no al `cwd`; el log del servidor de `21:26:26.539Z` dice `loading plugin` y muestra ese `id`/`entrypoint`. También se probó una config sandbox temporal con ruta absoluta: la respuesta de enumeración siguió vacía. Por tanto, la discrepancia no se explica por una ruta relativa rota ni por el manifest apuntando fuera del sandbox.

### Enumeración observada en 2.1.4

La orden real del launcher, con el servicio fijado a un puerto loopback privado del sandbox, devolvió:

```text
$ forge-opencode plugin list
No plugins found
RC=0
```

`forge-opencode plugin list --builtin` también devolvió literalmente `No plugins found` (RC 0). `plugin list --help` (RC 0) describe la orden como `List plugins` y su flag `--builtin` como `Include built-in server plugins`.

El OpenAPI servido por el mismo runtime 2.1.4 describe `GET /api/plugin` como `Retrieve enabled server plugins and their current status`; su parámetro opcional `location` es un objeto con `directory`. Con la forma correcta `?location[directory]=[RUTA DE LABORATORIO REDACTADA]`, el endpoint respondió HTTP 200 con ubicación `[RUTA DE LABORATORIO REDACTADA]` y `data=[]` (representación saneada: `{"location":{"directory":"…/sandbox/project"},"data":[]}`). Las consultas de contexto a HOME, proyecto y overlay, y el control con ruta absoluta, también dieron lista vacía. El esquema OpenAPI modela `Plugin.Info.source` como capaz de distinguir `local` y proporcionar `path`, pero no documenta que el listado sea un reflejo exhaustivo de las declaraciones `plugins` del archivo de config; en la ejecución medida no incluyó el paquete local aunque el log del servidor sí registró su carga. La evidencia distingue el plugin de config local del inventario/estado que exponen `plugin list` y `/api/plugin`; no demuestra que el flag de builtin o un RC 0 equivalgan a enumeración del guard.

La conclusión de ese momento —que el requisito no podía satisfacerse con 2.1.4— queda **refutada por la evidencia frío/caliente posterior**. La diferencia no se explica por `cwd` ni por inventar datos: con backend privado ya poblado, la CLI real sí enumeró el plugin local. El nuevo supervisor homogéneo elimina la dependencia del servicio compartido; véase el addendum para el procedimiento y la aceptación actual.

### Hook, DB y limpieza

La corroboración funcional nueva del hook queda **no ejecutada**. No se abrió una conversación/sesión nueva para invocar la herramienta `shell` que activa el hook, y un `git` llamado directamente desde el shell externo no sería prueba del hook real. La denegación histórica del commit en `master` permanece como evidencia histórica separada; no se presenta como corroboración nueva.

En cada ventana de runtime registrada, el tamaño/mtime de la DB original fue idéntico antes y después; los procesos sandbox propios no tuvieron FDs hacia la DB original. En la última ventana: `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes y mtime `2026-10-24T21:26:16.963482Z` antes y después. Los `stat` posteriores, ya fuera de las ventanas de prueba, observaron el mismo tamaño y mtime sucesivos `2026-10-24T21:27:40.859951Z` y `2026-10-24T21:27:55.501684Z`. La inspección `/proc` encontró FDs productivos en los servidores preexistentes PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` y `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, no en procesos sandbox propios. No se atribuyen esos cambios posteriores a las pruebas; los servicios preexistentes no se tocaron. La copia sandbox conservó marcador `{"phase":"completed"}` y `quick_check=ok`.

Se detuvieron únicamente los servicios privados propios y no quedó ejecutable del prefix sandbox vivo. Se eliminaron solo los artefactos creados por esta investigación: `sandbox/project/` y `sandbox/config/opencode-forge/opencode-step-2-2.json`; se restauraron byte por byte config, manifest y `service.json` sandbox. Verificadores finales: AST de `open-code/lib/plugin-sync.py` (0), `bash -n open-code/forge-opencode.sh` (0), `git diff --check` (0). En el repo permanece únicamente el cambio previo de Step 2.1 en `open-code/forge-opencode.sh`; este paso no agregó cambios de producto, tests ni fixtures. No se editó el plan ni se hicieron commits/push.

### Ampliación solicitada — contrato CLI/API y rutas locales (2026-10-24)

Esta comprobación amplía la evidencia de Step 2.2 sin modificar el resultado BLOCKED. Se consultó el ejecutable pinado del manifest sandbox (`opencode v2.1.4`) y se repitió el listado/API en el servicio loopback privado, con HOME/XDG/DB del sandbox y una config sandbox temporal sin MCP. El manifiesto, config y `service.json` se restauraron byte por byte; se eliminó el temporal. No se ejecutaron `plugin add/check/update/remove` como operaciones: solo sus ayudas; no se instalaron paquetes ni se consultaron registros remotos.

#### Ayuda completa de `plugin list`

`<binario-sandbox> plugin list --help` devolvió RC 0 y este stdout completo; stderr vacío:

```text
DESCRIPTION
  List plugins

USAGE
  opencode plugin list [flags]

FLAGS
  --builtin    Include built-in server plugins

GLOBAL FLAGS
  --help, -h                                                          Show help information
  --version, -v                                                       Show version information
  --wizard                                                            Start wizard mode for a command
  --completions <bash|zsh|fish|sh>                                    Print shell completion script (choices: bash, zsh, fish, sh)
  --log-level <all|trace|debug|info|warn|warning|error|fatal|none>    Sets the minimum log level (choices: all, trace, debug, info, warn, warning, error, fatal, none)
  --print-logs                                                        Print logs to stderr (server logs require --standalone)
```

`plugin list --builtin --help` también dio RC 0, con exactamente el mismo stdout. El grupo `plugin --help` lista solamente `list`, `add`, `check`, `update` y `remove`. No hay flag de lista para ruta local, directorio, config, proyecto o source. Los contratos textuales relevantes de las ayudas de subcomandos son: `add`: “Install a plugin and add it to the global configuration”; su argumento `package` es “npm registry or Git package specifier”. `check`: “Check package plugins for updates”. `update`: “Update package plugins”. `remove`: “Remove a plugin from global configuration”. No se probaron acciones mutantes ni comandos que contactaran registros.

#### Tabla de evidencia CLI

Todas las ejecuciones siguientes usaron el launcher contra el binario 2.1.4 del manifest sandbox; stdout/stderr son literales. Para las variantes desconocidas, el stdout fue idéntico al bloque de ayuda completa anterior y se incluye su stderr literal en la fila.

| Comando | RC | Salida literal |
|---|---:|---|
| `forge-opencode plugin list` | 0 | stdout: `No plugins found\n`; stderr vacío |
| `forge-opencode plugin list --builtin` | 0 | stdout: `No plugins found\n`; stderr vacío |
| `forge-opencode plugin list --local` | 1 | stdout: bloque de ayuda completa arriba; stderr: `\nERROR\n  Unrecognized flag: --local in command opencode plugin list\n` |
| `forge-opencode plugin list --dir [RUTA DE LABORATORIO REDACTADA]` | 1 | stdout: bloque de ayuda completa arriba; stderr: `\nERROR\n  Unrecognized flag: --dir in command opencode plugin list\n` |
| `forge-opencode plugin list --config [RUTA DE LABORATORIO REDACTADA]` | 1 | stdout: bloque de ayuda completa arriba; stderr: `\nERROR\n  Unrecognized flag: --config in command opencode plugin list\n` |
| `forge-opencode plugin list --path [RUTA DE LABORATORIO REDACTADA]` | 1 | stdout: bloque de ayuda completa arriba; stderr: `\nERROR\n  Unrecognized flag: --path in command opencode plugin list\n` |
| `forge-opencode plugin list --project [RUTA DE LABORATORIO REDACTADA]` | 1 | stdout: bloque de ayuda completa arriba; stderr: `\nERROR\n  Unrecognized flag: --project in command opencode plugin list\n` |
| `forge-opencode plugin list --source local` | 1 | stdout: bloque de ayuda completa arriba; stderr: `\nERROR\n  Unrecognized flag: --source in command opencode plugin list\n` |

Las seis últimas fueron sondas de flags no documentados, no opciones encontradas en la ayuda. Ninguna produjo una enumeración. No existe una ayuda de flag independiente para `--builtin`; su explicación está íntegra en la ayuda mostrada.

#### Rutas de API de 2.1.4 relacionadas

Se descargó `/openapi.json` del servidor sandbox real (HTTP 200; [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] bytes) y se filtraron operaciones por ruta, resumen, tags y descripción. La query `location` está declarada como objeto `deepObject` (`location[directory]`). Superficie relevante:

| Método y ruta | Contrato publicado en OpenAPI 2.1.4 | ¿Enumera plugins locales cargados? |
|---|---|---|
| `GET /api/plugin` | “List plugins”; “Retrieve enabled server plugins and their current status”; responde `data: Plugin.Info[]` | Es la única ruta de lista/estado. La fuente puede modelar `local`, pero en runtime devolvió `data=[]` pese al log de carga. |
| `POST /api/plugin/check` | “Check one or all package plugins for available updates.” | No; comprobación de actualizaciones de paquetes. No se invocó. |
| `POST /api/plugin/update` | “Update package plugins concurrently…” | No; actualización, potencialmente mutante/remota. No se invocó. |
| `GET /api/config` | “Return configuration documents and discovery sources…”; devuelve `Config.Entry[]` | No; documentos/configuración, no estado de módulos cargados. No se usó para fabricar un inventario. |
| `POST /api/location/reload` | Reconstruye ubicaciones cargadas al recargar configuración | No; recarga configuración, no consulta inventario. No se invocó. |
| `PATCH /api/experimental/config` | Modifica campos soportados en la config global | No; mutación de configuración, no consulta. No se invocó. |
| `POST /api/rpc/{rpcID}/{method}` | “Call a plugin RPC” ya registrado | No; despacho a un RPC conocido, no listado. |
| `GET /api/event` | Eventos nativos y de plugin RPC | No; suscripción a eventos, no listado. |
| `GET /api/model` | Lista modelos; la descripción advierte que el snapshot puede preceder la resolución inicial de plugins | No; inventario de modelos. |

En el esquema publicado, `Config.InfoEncoded.plugins` acepta un array de strings o entradas `{package, options?}`; el tipo no lleva un discriminador “local/npm”. En cambio, el esquema de respuesta `Plugin.Source` sí discrimina `builtin`, `package` (con `target`), `local` (con `path`) y `sdk`. Esto permite distinguir fuentes en un registro `Plugin.Info` cuando el runtime entrega el registro. La ayuda de `plugin add/check/update` separa explícitamente la gestión de paquetes npm/Git y configuración global. Para la declaración local de Forge, el mecanismo observado es el cargador de config por ubicación: `./plugin-packages/forge-guard` se resuelve junto al config del overlay y el servidor registra el módulo local al arrancar esa ubicación. No apareció otra operación OpenAPI que enumere los plugins locales cargados.

#### Reconsulta correcta de `/api/plugin` y carga local

En la ventana `21:30:07Z`–`21:30:23Z`, con el proyecto desechable ya eliminado, se consultaron ubicaciones existentes (no el path inexistente del proyecto eliminado):

| Solicitud | HTTP | Respuesta saneada real |
|---|---:|---|
| `GET /api/plugin` | 200 | `{"data":[],"location":{"directory":"…/sandbox/home"}}` |
| `GET /api/plugin?location[directory]=…/sandbox/home` | 200 | `{"data":[],"location":{"directory":"…/sandbox/home"}}` |
| `GET /api/plugin?location[directory]=…/sandbox/config/opencode-forge` | 200 | `{"data":[],"location":{"directory":"…/sandbox/config/opencode-forge"}}` |

El CLI en esa misma ventana volvió a dar RC 0 y stdout literal `No plugins found\n`. El log del servidor, en `2026-10-24T21:30:21.960Z`, registró:

```text
timestamp=2026-10-24T21:30:21.960Z level=INFO run=36ac39de msg="loading plugin" id=[RUTA DE LABORATORIO REDACTADA] entrypoint=file://[RUTA DE LABORATORIO REDACTADA] http.span=74 role=server
```

Un sondeo separado apuntó a `location[directory]` del proyecto desechable después de haberlo eliminado y recibió HTTP 404 `LocationNotFoundError`; se excluye de la evidencia de enumeración. Las ubicaciones existentes de la tabla devolvieron HTTP 200 y lista vacía.

**Conclusión de esa ampliación fría (posteriormente refutada):** la pista era válida en cuanto a que el CLI `plugin` gestiona paquetes npm/Git/globales y `--builtin` es su única opción de lista. Sin embargo, el OpenAPI 2.1.4 también declara que `Plugin.Info` puede tener fuente `local`; por ello no se atribuye el vacío simplemente a una prohibición contractual. La observación decisiva de aquella ventana fue que la API devolvió vacío aunque el cargador registró la ruta local. La ausencia observada bajo ese contexto no probaba imposibilidad de enumeración: el backend caliente posterior sí produjo la fila CLI. La corroboración funcional nueva del hook sigue “no ejecutada”; su evidencia histórica permanece separada.

La ventana API tuvo tamaño/mtime de DB original idénticos antes y después (`[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes; mtime UTC `2026-10-24T21:30:07.881271Z`); ningún proceso propio tuvo FDs hacia DB productiva y no quedó proceso sandbox vivo. Config, manifest y servicio sandbox se restauraron; el config temporal de esta ampliación se eliminó.

En la comprobación final posterior a la ampliación, `stat` observó `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes y mtime `2026-10-24T21:32:08.877066Z`; el tamaño siguió igual y el mtime avanzó fuera de la ventana aislada. La inspección simultánea volvió a encontrar los FDs en los servidores preexistentes `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` y `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, sin procesos sandbox propios vivos. Por ello queda verificada la igualdad tamaño/mtime dentro de cada ventana de ejecución aislada, pero no se afirma que el mtime productivo permaneciera globalmente fijo mientras esos servicios preexistentes seguían activos.

Última verificación tras cerrar el informe: DB original `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes, mtime `2026-10-24T21:32:47.280367Z`; `/proc` vuelve a atribuir sus FDs a los mismos servidores preexistentes `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` y `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`. No hubo procesos sandbox propios. El avance de mtime es externo a las ventanas aisladas y queda documentado, no se afirma conservación global de mtime durante la actividad de esos servicios.

## Step 2.3 — Sondeos operativos aislados en `status` y `doctor` (resultado pre-corrección, 2026-10-24)

### Cambio y criterio de salud

El ejecutable de este checkout es `install.sh` en la raíz; no existe `open-code/install.sh`. El cambio se hizo en el script real y comparte el diagnóstico del overlay OpenCode de `status` y `doctor`.

Además de las verificaciones estáticas, ambos comandos ejecutan `auth list --format json` y `session list --format json` mediante el launcher instalado. Cada ejecución prepara un directorio temporal privado, HOME propio, config vacía, manifest mínimo, XDG config/data/state/cache separados y DB privada. La DB fuente (la indicada por `OPENCODE_DB` o la predeterminada) se abre en modo solo lectura y se copia mediante SQLite a la DB del sondeo; el launcher nunca recibe la ruta de la DB fuente. Se ejecuta con entorno limpio (`env -i`) y opciones que desactivan auto-update, fetch de modelos, channel DB y file watcher. Si no se puede preparar el aislamiento o la copia, el resultado es `UNAVAILABLE` y el comando no intenta recurrir a producción.

Un sondeo operativo solo pasa con RC 0 y stdout no vacío que contenga un array JSON válido; salida vacía, JSON inválido/no-array o RC distinto de cero cuentan como fallo. Un array `[]` es una respuesta válida del comando (en la prueba positiva, sesiones devolvió cero elementos); la restricción de lista no vacía aplica a la enumeración del guard, que permanece `UNAVAILABLE`. Solo se muestra el número de elementos; payload y stderr completos (posibles datos de usuario) se omiten. `status`/`doctor` no instalan, sincronizan, reparan ni actualizan paquetes, y no escriben configuración o la DB original.

En esta instantánea previa al supervisor, la enumeración runtime de `forge-guard` se informó como `UNAVAILABLE` a partir de la observación fría entonces disponible. Ese diagnóstico también queda supersedido por la prueba posterior: presencia en disco y logs nunca sustituyen la enumeración, pero la CLI real con backend privado listo sí ofrece la fila exacta. Véase el addendum para la clasificación actual de `status`/`doctor`.

### Prueba positiva — launcher corregido y overlay del sandbox

Se ejecutaron `bash install.sh status` y `bash install.sh doctor` con HOME/XDG/config/manifest/DB del sandbox existente y symlink al launcher corregido de la rama. Resultados:

| Comando | RC | Comprobaciones operativas | Salud general |
|---|---:|---|---|
| `status` | 1 | `auth list --format json`: array JSON válido, 2 elementos; `session list --format json`: array JSON válido, 0 elementos | `DEGRADADO`; el inventario runtime del plugin sigue `UNAVAILABLE` por Step 2.2 |
| `doctor` | 1 | Mismas dos comprobaciones operativas superadas | `FAILs=1 WARNs=2`; el único FAIL es el inventario del plugin no disponible |

Los contenidos de auth/sesiones no se imprimieron. La config, manifest y DB del sandbox permanecieron idénticos durante las ejecuciones; se restauró byte por byte el manifest temporal, y se eliminaron el symlink y temporales propios. En la ventana positiva la DB original permaneció en 2.315.714.560 bytes con mtime `2026-10-24T21:40:13.330420Z` antes y después; no se detectó FD productivo de procesos propios.

### Reproducción negativa — launcher original del respaldo

Para la prueba negativa se extrajo `[RUTA DE LABORATORIO REDACTADA]` en un directorio privado nuevo, separado del sandbox positivo: `[RUTA DE LABORATORIO REDACTADA]`. El tar tenía SHA-256 `92c26cf90345e0fde7cba94b8b5b59f346e9f7f8ed8a88462e67dd17e8727af6`; el launcher extraído `open-code/forge-opencode.sh`, SHA-256 `1ecfe1edd0634479c65163eddf62ea3a3650b7948859f9f93754c626192f9280`, se usó sin editarlo y sin sobrescribir el launcher de la rama. El sandbox usó un binario OpenCode 2.1.4 privado, manifest/HOME/XDG y SQLite privadas. La reproducción directa del launcher del respaldo mostró RC 1 en ambos comandos y stderr literal saneado:

```text
forge-opencode auth list --format json
ERROR
  Unrecognized flag: --standalone in command opencode auth

forge-opencode session list --format json
ERROR
  Unrecognized flag: --standalone in command opencode session
```

Al ejecutar el `install.sh` actualizado contra ese sandbox, los dos comandos de diagnóstico reportaron el fallo operativo real (no solo el mismatch estático del launcher):

```text
status RC=1
INVALID  auth list --format json fallo: el launcher rechazo --standalone (RC=1)
INVALID  session list --format json fallo: el launcher rechazo --standalone (RC=1)
Estado general: DEGRADADO (ver detalles arriba)

doctor RC=1
FAIL  INVALID: auth list --format json fallo: el launcher rechazo --standalone (RC=1)
FAIL  INVALID: session list --format json fallo: el launcher rechazo --standalone (RC=1)
Resumen: FAILs=5  WARNs=2
```

Los otros FAILs del `doctor` de esta prueba incluyen el inventario `UNAVAILABLE` de Step 2.2 y diferencias estáticas esperables del sandbox nuevo que apunta deliberadamente al launcher extraído. Las dos líneas `INVALID` anteriores confirman por separado el rechazo operativo de auth y sesiones. Tras status/doctor, los hashes del manifest, config, DB sandbox, launcher extraído y binario fueron idénticos; ambos grupos de procesos terminaron y no quedó proceso de sondeo vivo. En esa ventana la DB original conservó tamaño `2.315.714.560` y mtime `2026-10-24T21:42:13.637295Z` antes y después.

Como corroboración directa posterior, los dos comandos del launcher antiguo volvieron a dar los errores `Unrecognized flag` y RC 1 usando únicamente la DB sandbox de 8.192 bytes, que no cambió. Entre los snapshots de DB original de esa corroboración, servicios OpenCode preexistentes ajenos a la prueba actualizaron su mtime de `2026-10-24T21:42:13.637295Z` a `2026-10-24T21:43:24.321042Z`; el tamaño siguió en `2.315.714.560` bytes. La inspección de `/proc` atribuyó los FDs productivos a los procesos preexistentes PID [PID REDACTADO] (`opencode serve --stdio`) y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] (`opencode serve --service`), no a procesos de sondeo. No se detuvieron ni modificaron esos servicios; por ello no se atribuye ese avance de mtime a los diagnósticos aislados.

En una inspección final posterior (2026-10-24T21:44:32.356833Z), la DB original seguía en `2.315.714.560` bytes, pero esos mismos servicios preexistentes habían vuelto a avanzar el mtime. `/proc` confirmó que solo PID [PID REDACTADO] y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] mantenían FDs hacia la DB/WAL/SHM original; no quedó ningún proceso de los sondeos. Por la actividad continua de esos servicios no es correcto afirmar que el mtime productivo permaneció globalmente fijo; sí permaneció idéntico dentro de las ventanas acotadas de `status`/`doctor`, cuyos procesos solo recibieron la DB aislada.

Verificadores: `bash -n install.sh` y `git diff --check` pasaron en aquella instantánea. El directorio privado de reproducción, la extracción del respaldo y los artefactos temporales propios se eliminaron tras guardar esa evidencia. Step 2.3 quedó implementado en aquella instantánea; la frase sobre salud general bloqueada describe solo el estado pre-supervisor y queda supersedida por el addendum final. No se editaron el plan ni los tests, no se modificó `plugin-packages/forge-guard`, y no se hicieron commits ni push.

## Step 2.4 — Inventario de procesos y cobertura de IDs (2026-10-24)

### Respaldo externo y diff previo

Antes de editar, verifiqué SHA-256 `d5afd72d934a3da7c8c37ce7630355b01df12a64d1c0a664389423606f9c2a9b` de `external-cutover.tar` y lo extraje en el directorio privado nuevo `[RUTA DE LABORATORIO REDACTADA]` (modo 0700). Los cuatro ficheros extraídos (`cutover.sh`, `lib/dbtool.py`, `ROLLBACK.sh`, `CUTOVER-NOTES.md`) coincidían byte por byte con los originales al empezar. El diff unificado contra ese estado previo se conserva en `[RUTA DE LABORATORIO REDACTADA]` (modo 0600; 712 líneas).

Resumen del diff: `cutover.sh` +269/−81 líneas; `lib/dbtool.py` +29/−2; `ROLLBACK.sh` +116/−16. `CUTOVER-NOTES.md` no se modificó.

### Cambios

- **`cutover.sh`:** el clasificador de `/proc/PID/exe` quita solo el sufijo terminal literal ` (deleted)` para comparar el basename, pero conserva y registra `exe_original`, `exe_normalizado`, `exe_deleted`, PID e `inicio_ticks` (campo 22 de `/proc/PID/stat`). Los destinos de DB de los FDs y `OPENCODE_DB` se conservan en la fila y determinan `ambito` (`PRODUCCION`, `SANDBOX` u otra base); la clasificación no depende de la ruta/nombre del binario. Se compara la DB objetivo con la ruta productiva de referencia configurable (`CUTOVER_PRODUCTION_DB`, por defecto el home de passwd del usuario). El escaneo registra holders aunque el ejecutable no sea OpenCode.
- El inventario detecta `/proc` ilegible, `hidepid`, FDs/environ inaccesibles, PID desaparecido y reutilización durante el escaneo. Ante cualquiera de esos casos emite **`INVENTARIO DE /proc NO EXHAUSTIVO`**, conserva motivos en el informe y aborta antes de afirmar que no hay procesos. El código de escaneo no envía señales ni detiene procesos.
- La comprobación permanente de cobertura usa el anti-join `v1_missing_in_v2`; falla si no es `0` o no se pudo medir. Informa ambos recuentos y `v2_only`, que no causa fallo. La igualdad de recuentos solo se imprime como observación inmediatamente posterior a migración (6.5); no es el criterio permanente. Siguen presentes el control del marcador completado, `quick_check` y las comprobaciones de conservación de tablas V1/reset.
- La salida generada en 3.1 para `event` y `event_sequence` toma `a`, `b` y `delta` del JSON medido y calcula/imprime cada diferencia. Quité la afirmación estática de igualdad y no fijé cifras en el generador.
- **`lib/dbtool.py`:** las lecturas de `diff`, `counts` y `check` usan fuente SQLite `mode=ro` y una transacción de lectura coherente. `check` añade `v1_missing_in_v2` y `v2_only`; `quick_check` de `check` comparte esa misma conexión/transacción. El snapshot sigue usando la API de backup sobre fuente de solo lectura. No se cambió el cuerpo SQL/transaccional de `reset`.
- **`ROLLBACK.sh`:** lo modifiqué porque su verificación también omitía un `opencode.exe (deleted)` al comparar el basename y silenciaba datos `/proc` inaccesibles. Normaliza el sufijo para clasificar exe y destinos FD, conserva exe original/PID/inicio en errores, contempla `OPENCODE_DB` y aborta antes de restaurar si el inventario queda incompleto. No detiene procesos.

### Validación estática y consultas SQLite de solo lectura

Verificadores ejecutados:

| Verificador | RC |
|---|---:|
| `bash -n [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/cutover.sh` | 0 |
| `bash -n [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/ROLLBACK.sh` | 0 |
| `ast.parse` de `lib/dbtool.py` | 0 |
| `git diff --check` del repo | 0 |

La revisión estática confirma que `PROC_INVENTORY_COMPLETE=0` llega al `die` de preflight/rollback antes de declarar ausencia de escritores/restaurar; `v1_missing_in_v2 != 0` aborta en 6.5 o cuenta como fallo en 7.2, mientras que `v2_only` solo aparece en el diagnóstico. Los errores `ToolError`/SQLite de `dbtool.py` conservan RC 2/3 y las invocaciones del helper en `cutover.sh` propagan el error mediante `|| die`. No se importó ni ejecutó `dbtool.py`.

Las consultas equivalentes se hicieron únicamente sobre copias/snapshots con URI `mode=ro`, `PRAGMA query_only=ON` y `BEGIN`; no se consultó ni tocó la DB productiva. Resultados relevantes:

- Copia completada del sandbox: `quick_check=ok`, marcador `{"phase":"completed"}`, `session=881`, `session_v2=887`, `v1_missing_in_v2=0`, `v2_only=6`. La diferencia de recuentos es crecimiento V2 legítimo y la cobertura V1 permanece completa.
- Snapshots retenidos de cutover, `opencode.db.precutover-original` frente a `opencode.db.migrated`: `event` [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]→[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] (delta −4410); `event_sequence` 881→878 (delta −3), ambos `quick_check=ok`.

Para Step 3.1 queda anotada una discrepancia histórica que no se codificó como constante: el requisito de documentación cita `event_sequence` 881/978 (delta aritmético +97) y pide señalar que su fila histórica es inconsistente consigo misma, mientras que los artefactos SQLite retenidos consultados aquí miden 881/878 (delta −3) y el informe archivado también contiene prosa que afirma igualdad. Step 3.1 deberá preservar el histórico y reconciliar explícitamente esas fuentes; no se deduce pérdida de sesiones ni se inventan datos. El generador corregido presentará los valores del JSON de diff que mida en cada ejecución.

Como evidencia del caso concreto, la inspección de solo lectura de `/proc` observó PID [PID REDACTADO] con `inicio_ticks=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, exe original `[RUTA DE LABORATORIO REDACTADA]@opencode/cli/bin/opencode.exe (deleted)` y FDs a `...[RUTA PERSONAL REDACTADA] (deleted)` y sus WAL/SHM bajo `[RUTA DE LABORATORIO REDACTADA]`. El código ahora lo reconoce al comparar `opencode.exe` tras quitar el sufijo solo para clasificarlo, conserva la ruta original en la fila y clasifica su destino por la ruta sandbox. No se ejecutó el inventario para probarlo dinámicamente.

No se ejecutaron, importaron ni hicieron `source` de `cutover.sh`, `ROLLBACK.sh` o `dbtool.py`; no se iniciaron ni cerraron procesos y no se escribieron fixtures. El repo no recibió cambios de Step 2.4; sus únicos cambios visibles siguen siendo los de Steps 2.1 y 2.3. No hubo commits ni push.

## Rectificación complementaria — Step 3.1 (2026-10-24T22:07:53Z)

Esta nota complementa y rectifica afirmaciones del material histórico sin
reescribirlo. El `CUTOVER-REPORT.md` archivado en
`[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/CUTOVER-REPORT.md` no se
modificó; su SHA-256 al redactar esta nota era
`09947e8d2228ad36ca33fa90c40e973f5f6804c2f15f5bcbfead51fa5d14d331`.

### Correcciones y límites de evidencia

- **Rutas reales:** launcher fuente `open-code/forge-opencode.sh`; instalador
  raíz `install.sh`; overlay/config
  `[RUTA PERSONAL REDACTADA]`; launcher de usuario
  `[RUTA PERSONAL REDACTADA]`; binario pinado
  `[RUTA PERSONAL REDACTADA]`; manifest `[RUTA PERSONAL REDACTADA]`. Los
  scripts externos del cutover viven bajo
  `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/`; no hay scripts de cutover
  en el árbol del repo.
- **PID [PID REDACTADO]:** la primera clasificación por basename omitió este proceso
  residual sandbox porque `/proc/PID/exe` terminaba en el literal
  ` (deleted)`. La observación conservada del 2026-10-24 registra
  `inicio_ticks=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, exe original
  `[RUTA DE LABORATORIO REDACTADA]@opencode/cli/bin/opencode.exe (deleted)`
  y FDs de DB/WAL/SHM bajo `[RUTA DE LABORATORIO REDACTADA]`, también con
  ` (deleted)`. Es un destino sandbox, no producción. La hora UTC exacta de esa
  lectura de `/proc` no quedó en el registro. PID [PID REDACTADO] era preexistente y no
  se detuvo. La lógica corregida elimina el sufijo terminal solo para comparar,
  conserva ruta original/PID/inicio y clasifica por destino accesible. Si un
  proceso desaparece o `/proc`/FDs/environ no son legibles, el inventario es
  NO EXHAUSTIVO y el preflight falla cerrado.
  - **Plugins y guard (observación fría histórica, supersedida):** distinguir
   (1) evidencia histórica del guard, (2) enumeración runtime actual y (3)
   corroboración funcional nueva. La prueba histórica de denegación de commit
   en `master` permanece separada; no equivale a una prueba actual. En aquella
   ventana fría el log registró `loading plugin .../forge-guard/index.js`,
   mientras `plugin list` y `plugin list --builtin` dieron `No plugins found`
   con RC 0 y `GET /api/plugin` devolvió `data=[]`. Esas observaciones son
   válidas para ese contexto, pero no prueban imposibilidad general: el backend
   caliente posterior y el supervisor descrito en el addendum sí produjeron la
   fila CLI local exacta. La API se conserva como contrato observado separado.
   La corroboración funcional nueva del hook **no se ejecutó**.
- **`status`/`doctor`:** el `install.sh` raíz efectúa probes reales de
  `auth list` y `session list` en HOME/XDG/config/manifest/DB privados; la DB
  fuente se copia desde lectura SQLite solo lectura y no se entrega al
  launcher. Los payloads se omiten. En la prueba positiva del 2026-10-24,
  ambas operaciones obtuvieron arrays válidos (auth: 2; sesiones: 0), pero
  `status` y `doctor` retornaron RC 1 porque el guard quedó `UNAVAILABLE`;
  no se informa salud general. La prueba negativa con el launcher respaldado
  hizo que ambos comandos retornaran RC 1 al rechazar `--standalone` en
  `auth`/`session`. Estos son probes acotados, no una prueba de migración.
- **Cobertura:** se conserva como observación histórica el par
  `session=881` / `session_v2=884`, fechado el 2026-10-24 en el documento previo;
  la evidencia disponible no conserva hora UTC para esa ventana. No son
  constantes. La lectura de solo lectura repetida para esta rectificación
  ocurrió entre `2026-10-24T22:03:41Z` y `2026-10-24T22:03:43Z`, sobre la copia
  completada del sandbox con `PRAGMA query_only=ON`, `BEGIN` y URI `mode=ro`:
  `quick_check=ok`, marcador `{"phase":"completed"}`, `session=881`,
  `session_v2=887`, `v1_missing_in_v2=0`, `v2_only=6`. El criterio permanente
  es `v1_missing_in_v2 == 0`; `v2_only` se informa y puede crecer por sesiones
  nativas V2. La igualdad de recuentos solo es una observación inmediatamente
  posterior a un cutover.
- **Eventos:** el par citado para `event`, `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]→[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, tiene diferencia
  aritmética `−4410`. El par citado para `event_sequence`, `881→978`, tiene
  diferencia aritmética `+97`. La hora UTC exacta de la observación 881→978 no
  quedó retenida. El informe histórico del cutover generado a
  `2026-10-24T20:30:48Z` contiene en su tabla `event_sequence` 881→878 (delta
  `−3`) y también una prosa que afirma igualdad; esa prosa contradice su propia
  tabla. Las consultas de solo lectura sobre copias SQLite retenidas confirmaron
  `event` [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]→[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] (`−4410`) y `event_sequence` 881→878 (`−3`) para esos
  artefactos concretos. Se mantienen visibles ambas fuentes; no se fuerza una
  reconciliación ni se infiere pérdida de sesiones a partir de recuentos de
  eventos. El generador externo actualizado imprime valores medidos y deltas
  calculados en cada ejecución.
- **Omarchy:** la huella histórica del árbol cubrió metadatos hasta profundidad
  3; además se calcularon hashes de tres ficheros respaldados. No fue una
  comparación exhaustiva del contenido del árbol y no debe describirse como
  tal.

### Registro de esta actualización documental

Comandos y resultados saneados de Step 3.1:

| UTC | Comando/comprobación | RC | Resultado |
|---|---|---:|---|
| `2026-10-24T22:03:41Z`–`22:03:43Z` | Python SQLite inline sobre la copia sandbox: URI `mode=ro`, `PRAGMA query_only=ON`, `BEGIN`, `quick_check`, marcador, conteos y anti-joins | 0 | `session=881`, `session_v2=887`, ausentes `0`, V2-only `6`, marcador completed; sin payloads de usuario |
| `2026-10-24T22:07:53Z` | `git diff --check` | 0 | Sin errores de whitespace (se repetirá al cierre de Step 3.1) |
| `2026-10-24T22:10:37Z` | `git diff --check` | 0 | Verificación final de whitespace en los cambios del repo |
| `2026-10-24T22:10:37Z` | `git branch --show-current; git status --short` | 0 | Rama `fix/fix-v2-launcher-verifiers`; cambios repo `install.sh`, `open-code/forge-opencode.sh` (Steps 2.1/2.3) y `open-code/MIGRATION-V2.md` (Step 3.1) |
| `2026-10-24T22:10:37Z` | `sha256sum [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/CUTOVER-REPORT.md` | 0 | Histórico intacto; hash coincide con el registrado arriba |
| `2026-10-24T22:12:02Z` | `git diff --check` | 0 | Verificación final, sin errores |
| `2026-10-24T22:12:02Z` | Búsqueda `rg` del prefijo de ruta retirado en los tres documentos | 1 | Sin coincidencias (RC 1 esperado; no se conservan referencias operativas a la ruta inexistente) |
| `2026-10-24T22:12:02Z` | `sha256sum [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/CUTOVER-REPORT.md` | 0 | Mismo SHA-256; no se sobrescribió el informe histórico |
| 2026-10-24 | Revisión textual de rutas, comandos, criterios, conteos, guard e inventario en los tres documentos | 0 | No se ejecutaron comandos de runtime ni operaciones de migración |

No se creó ni limpió ningún PID propio durante Step 3.1 (edición/revisión de
documentación únicamente). Los PIDs propios que sí se limpiaron en las pruebas
previas siguen enumerados con sus RC en los apartados anteriores de Steps 1.2,
2.1 y 2.2. PID [PID REDACTADO] y los servicios productivos preexistentes no se tocaron.

El archivo `CUTOVER-NOTES.md` se compara para el diff Step 3.1 con el original
extraído de `external-cutover.tar` (SHA-256 del archivo: `eb69b14e22ed1ddd28579e690312eb6e061d3aef4a83986b00267b78ceeaba18`), en
`[RUTA DE LABORATORIO REDACTADA]`. Su diff
unificado se guarda en
`[RUTA DE LABORATORIO REDACTADA]`
(609 líneas, +213/−168). El diff de Step 2.4 ya existente se conserva en
`[RUTA DE LABORATORIO REDACTADA]`
(SHA-256 `ebf35d47c0be7262f087382010e7cdc857ba274097d0d6b19ae28064e8d7b438`).
`REMEDIATION-REPORT.md` no estaba incluido en `external-cutover.tar` (se creó
después); su base pre-Step-3.1 se conserva en
`[RUTA DE LABORATORIO REDACTADA]`. El diff de esta sección está
en `diff-REMEDIATION-REPORT-step-3-1.patch` junto al snapshot. No se sobrescribe
el respaldo ni el informe histórico del cutover. Los informes no
incluyen secretos, payloads de auth/sesiones ni contenido de usuario.

No se ejecutaron, importaron ni hicieron `source` de `cutover.sh`,
`ROLLBACK.sh` o `dbtool.py`; no se ejecutó una migración, no se cerraron
procesos, no se modificó el plan y no hubo commit ni push.

### Ampliación de revisión estática — 2026-10-24T22:09:51Z

Al contrastar la descripción del ciclo de vida con el código externo,
`grep -n 'kill_writers_on_db\|stop_server' [RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/cutover.sh`
(RC 0) mostró que el preflight
de `/proc` no envía señales, pero el helper separado `kill_writers_on_db`
envía TERM y después KILL a cualquier PID cuyos FDs coincidan con el path DB
que recibe. `stop_server` lo invoca para `CUTOVER_DB` en limpieza/trap y hay
otra invocación al final del flujo; no está acotado a los procesos creados por
el script. Esto puede afectar un proceso externo que abra la DB tras el
preflight. El informe de Step 2.4 describía correctamente el escaneo como
estático/no señalizador, pero la formulación resumida de la respuesta de
implementación (“no detiene procesos”) no describe el script completo. Se
corrige aquí y en los runbooks: no se presenta ese comportamiento como seguro,
y cualquier ejecución futura requiere revisar/resolver esa ruta de señales.
No se editó el script en Step 3.1, no se ejecutó ninguna de sus rutas, y ningún
proceso recibió señal durante esta revisión.

## Step 3.2 — aceptación e invariantes, snapshot pre-corrección (2026-10-24T22:14:42Z–22:24:00Z)

**Resultado histórico antes de la corrección de contexto: BLOQUEADO; el plan no se podía cerrar como completado en esa ventana.** No se
editó el plan, no se hicieron commits ni push. La enumeración exacta de
`forge-guard` continúa sin prueba; el aislamiento de datos sí se demostró.

### Aislamiento y ejecución del GLOBAL VERIFIER literal

Antes del bloque se verificó que `home`, `config`, `data`, `state` y `cache`
existían bajo `[RUTA DE LABORATORIO REDACTADA]`, todos con modo
`0700`. El manifest sandbox apuntaba a overlay/config y binario bajo esa misma
raíz; las copias iniciales de `.opencode-tokens` y `data/opencode/auth.json`
tenían modo `0600`, y `OPENCODE_DB`/XDG usados por el CLI apuntaban a la DB de la
copia. La fuente de DB del preflight se había copiado mediante SQLite desde una
conexión `mode=ro`; los diagnósticos de `status`/`doctor` también abren su fuente
con `mode=ro` y la copian a un directorio temporal privado.

Se ejecutó el bloque GLOBAL VERIFIER sin cambiar sus comandos. RC global **1**.
Pasaron rama, `git diff --check`, los cuatro `bash -n`, `ast.parse`, sumas de los
respaldos, directorios sandbox, `--version`, `auth list`, validación JSON,
`session list` y `test -s` de sesiones. Se detuvo en la orden del bloque que
invoca `plugin list` (línea 206 del plan), antes de `grep` o de `status` y
`doctor`: el servicio gestionado intentó usar el puerto ocupado por el servicio
preexistente PID [PID REDACTADO]. Salida literal relevante:

```text
Error: Server process exited with code 1
Error: Managed service port [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] on 127.0.0.1 is already in use by another process. Configure another port with `opencode service set port <port>` and start the service again.
```

En esa ejecución `plugin-list.txt` quedó vacío y la orden `plugin list` tuvo
RC 1; los `grep` no se alcanzaron. Para evaluar el criterio semántico sin tocar
el servicio preexistente, se repitió la enumeración con un puerto distinto
([IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]) configurado solo en la copia sandbox: `plugin list` devolvió RC **0** y
la salida literal **`No plugins found`**. Sobre esa salida, `grep -q forge-guard`
dio RC **1**, y la condición completa del verificador que aborta al encontrar
`No plugins found` dio RC **1**. Por tanto, la enumeración actual sigue
**BLOQUEADA**, no aprobada por el RC 0 del comando.

La modificación temporal del `service.json` sandbox se restauró byte por byte
(SHA-256 previo y posterior iguales). El servicio sandbox que inició la
repetición fue PID [PID REDACTADO], identificado por su ejecutable bajo el sandbox y su
listener exclusivo en `127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; se le envió TERM y terminó. El puerto
[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] quedó libre; el listener preexistente en [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] siguió siendo PID [PID REDACTADO]
y no se tocó.

La evidencia anterior sobre `GET /api/plugin` se conserva: el endpoint explica
que retorna plugins de servidor habilitados/estado actual, pero respondió
`data=[]` incluso cuando el log registró la carga del plugin local. `plugin
list` solo ofreció `--builtin`; no es una enumeración exacta de plugins locales.
La prueba histórica que bloqueó un commit en `master` sigue siendo evidencia
histórica separada. No se abrió una sesión nueva para invocar el hook: la
corroboración funcional nueva sigue **no ejecutada**.

### Matriz de criterios del GLOBAL VERIFIER

Cada criterio se ejecutó individualmente además del bloque global. RC se refiere
al comando/condición indicado; payloads de auth y sesiones no se conservaron en
este informe.

| Criterio | RC | Veredicto / observación inspeccionada |
|---|---:|---|
| Rama `fix/fix-v2-launcher-verifiers` | 0 | Pasa |
| `git diff --check` | 0 | Pasa |
| `bash -n open-code/forge-opencode.sh` | 0 | Pasa |
| `bash -n install.sh` | 0 | Pasa |
| `bash -n .../cutover.sh` | 0 | Pasa; análisis sintáctico, no ejecución |
| `bash -n .../ROLLBACK.sh` | 0 | Pasa; análisis sintáctico, no ejecución |
| AST de `plugin-sync.py` y `dbtool.py` | 0 | Pasa; `ast.parse`, no importación/ejecución |
| `sha256sum -c .../SHA256SUMS` | 0 | Pasa para ambos respaldos |
| Cinco directorios del sandbox | 0 | Pasa antes de la limpieza |
| Launcher `--version` | 0 | Pasa; stdout literal `opencode v2.1.4` |
| `auth list --format json` | 0 | Pasa; JSON válido, sin imprimir payload |
| `python3 -m json.tool auth-list.json` | 0 | Pasa |
| `session list` | 0 | Pasa; salida no vacía; payload/títulos omitidos |
| `test -s session-list.txt` | 0 | Pasa |
| `plugin list` en el bloque literal | 1 | Bloqueado por puerto [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] ocupado por PID preexistente [PID REDACTADO]; archivo de salida vacío |
| `plugin list` en repetición sandbox/puerto [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] | 0 | El contenido fue `No plugins found`; no pasa enumeración |
| `grep -q forge-guard` sobre la salida controlada | 1 | Bloqueado; el guard no aparece |
| Condición completa `No plugins found` → `exit 1` | 1 | Bloqueado como se esperaba; no se enmascaró el vacío |
| `sandbox_run install.sh status` con el HOME original copiado | 1 | No saludable; además del guard, ese sandbox conservaba entradas Claude incompletas y no tenía `[RUTA PERSONAL REDACTADA]`; no se acepta como prueba aislada del guard |
| `sandbox_run install.sh doctor` con el HOME original copiado | 1 | Mismo límite de preparación anterior; además de `UNAVAILABLE`, encontró enlaces Claude rotos y launcher ausente |
| `status` con HOME privado preparado solo para OpenCode | 1 | No saludable, esperado por guard `UNAVAILABLE`; ver salida literal debajo |
| `doctor` con HOME privado preparado solo para OpenCode | 1 | `FAILs=1`; el único FAIL es guard `UNAVAILABLE`; auth/sesiones pasan |
| Informe externo no vacío | 0 | Pasa |
| GLOBAL VERIFIER completo | **1** | No pasa; se detuvo en `plugin list` por el conflicto del puerto, y la repetición controlada confirmó la lista vacía |

La repetición preparada de los diagnósticos aisló el efecto del guard. Salida
literal saneada:

```text
OK       plugin-packages/forge-guard: declarado por opencode.jsonc y presente en disco
UNAVAILABLE OpenCode 2.1.4 no permite verificar la enumeracion del plugin local (bloqueo documentado en Step 2.2)
OK       auth list --format json operativo: array JSON valido (2 elementos; contenido omitido)
OK       session list --format json operativo: array JSON valido (0 elementos; contenido omitido)
Estado general: DEGRADADO (ver detalles arriba)
```

`status` RC **1**; `doctor` RC **1**, `FAIL  UNAVAILABLE: OpenCode 2.1.4 no permite verificar la enumeracion del plugin local (bloqueo documentado en Step 2.2)` y `Resumen: FAILs=1  WARNs=1`. No se declararon saludables. La prueba negativa ya registrada en Step 2.3 continúa mostrando el launcher del respaldo rechazando `--standalone` (RC 1) para `auth` y `session`; la prueba positiva del launcher corregido obtiene arrays válidos (auth 2, sesiones 0), pero ambos diagnósticos retornan RC 1 por el guard. No se hizo autenticación interactiva ni solicitudes a proveedores.

### SQLite de la copia, credenciales y modelos

La siguiente inspección se hizo sobre la copia antes de eliminar el sandbox,
usando `sqlite3.connect(path.as_uri() + '?mode=ro', uri=True)`,
`PRAGMA query_only=ON` y `BEGIN`; no se seleccionaron valores de credenciales,
mensajes ni partes:

```sql
PRAGMA quick_check;
SELECT value FROM kv WHERE key='migration.v1-v2';
SELECT count(*) FROM session;
SELECT count(*) FROM session_v2;
SELECT count(*) FROM session AS s
LEFT JOIN session_v2 AS v ON v.id=s.id WHERE v.id IS NULL;
SELECT count(*) FROM session_v2 AS v
LEFT JOIN session AS s ON s.id=v.id WHERE s.id IS NULL;
SELECT count(*) FROM message;
SELECT count(*) FROM part;
SELECT count(*) FROM session_v2 WHERE model LIKE ?;
```

Parámetros del último SQL, evaluados por separado: `MiniMax-M3.1-Flash`,
`gpt-6-luna`, `gpt-6.1-sol`. Resultados: `quick_check=ok`; marcador exacto
`{"phase":"completed"}`; `session=881`; `session_v2=887`;
`v1_missing_in_v2=0`; `v2_only=6`; `message=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; `part=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`. Las
coincidencias directas del campo `session_v2.model` fueron 3, 1 y 3,
respectivamente. `v2_only` es informativo; no se impone igualdad de conteos.
Las tablas inspeccionadas fueron `account`, `account_state`, `control_account`,
`credential`, `event`, `event_sequence`, `instruction_blob`,
`instruction_entry`, `instruction_state`, `kv`, `message`, `part`, `permission`,
`project`, `project_directory`, `session`, `session_inbox`, `session_message`,
`session_pending`, `session_share`, `session_v2`, `todo`, `workspace` y
`worktree`.

La lista local `auth list` identificó estos ID/método; no se imprimieron ni
registraron secretos:

| ID | Método |
|---|---|
| `minimax-cn` | `env` |
| `minimax` | `env` |
| `minimax-cn-coding-plan` | `env` |
| `minimax-coding-plan` | `key`, `env` |
| `openai` | `oauth` |

### Huellas, DB activa y diferencias contra respaldos

Las huellas de originales coinciden exactamente con el preflight de Step 1.2:

| Artefacto original | SHA-256 actual | Resultado |
|---|---|---|
| `[RUTA PERSONAL REDACTADA]` | `b240efa9d6020bdc513bbf48e46b6d312493d2c408f7d070555e993feea0a89b` | Igual |
| `[RUTA PERSONAL REDACTADA]` | `[HUELLA DE CREDENCIAL REDACTADA]` | Igual |
| `[RUTA PERSONAL REDACTADA]` | `[HUELLA DE CREDENCIAL REDACTADA]` | Igual |
| Omarchy `bin/omarchy-npx-install` | `c3f562ff7482a2ab5eee15a50a36496b8e0307e105410010ee4b43ed62bb0b7e` | Igual |
| Omarchy `bin/omarchy-remove-preinstalls` | `bfa59bec96e5ccc7f1a91ca42e6f0ba9fb45506d3ba18a9590bd04c8171cc40d` | Igual |
| Omarchy `install/packaging/npx.sh` | `7b1c1d7b9b42f18e3454b5522c60b5b7d14143a6c8344b0f60c3e16d59085de8` | Igual |

No se exigió hash de la DB viva. En la captura final previa a limpieza, la DB
activa medía `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes; WAL `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes; SHM `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes. La
actividad/mtime de la DB viva puede avanzar legítimamente. `/proc` atribuyó los
descriptores productivos observados a los servicios preexistentes PID [PID REDACTADO] y
[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]; no hubo un proceso de la aceptación con FD a la DB productiva. La
garantía de esta prueba proviene de rutas XDG/HOME/`OPENCODE_DB` sandbox y
conexiones fuente de solo lectura, no de un hash fijo de SQLite activa.

Se extrajeron ambos respaldos únicamente a directorios nuevos modo `0700`, sin
sobrescribir originales:

- `external-cutover.tar` → `[RUTA DE LABORATORIO REDACTADA]`;
  diff modo `0600` en `diff-external.patch`.
- `repo-HEAD.tar` → `[RUTA DE LABORATORIO REDACTADA]`;
  diff modo `0600` en `diff-repo.patch`.

Los cambios externos comparados contra el respaldo fueron `cutover.sh`
+269/−81, `lib/dbtool.py` +29/−2, `ROLLBACK.sh` +116/−16 y `CUTOVER-NOTES.md`
+213/−168; corresponden a las correcciones ya descritas en Steps 2.4/3.1. La
comparación del repo confirmó únicamente `install.sh`,
`open-code/forge-opencode.sh` y `open-code/MIGRATION-V2.md`. No surgió un hallazgo
nuevo que requiriera ampliar o corregir este alcance. Se conserva la advertencia
estática ya registrada: `cutover.sh` contiene una ruta separada de señales a
holders de DB; no se ejecutaron cutover ni rollback.

### Procesos y limpieza

Se ejecutaron `pgrep -a -f forge-v2-remediation` (RC 1, sin procesos propios) y
`pgrep -a -f opencode`: solo aparecieron PID [PID REDACTADO], [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO], [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO],
preexistentes y no señalizados. El PID propio de esta aceptación fue [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y
se terminó con TERM tras verificar ejecutable sandbox y listener exclusivo
[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]. También se comprobó que no quedaba proceso con entorno o ejecutable bajo
el sandbox. El proceso Playwright MCP PID [PID REDACTADO] tenía HOME/XDG originales y
no pertenecía a la prueba; no se tocó.

Tras guardar esta evidencia saneada se eliminó íntegramente
`[RUTA DE LABORATORIO REDACTADA]`. Esto retiró las copias privadas
`.opencode-tokens`, `auth.json`, `service.json` (con contraseña del servicio),
los listados brutos de auth/sesiones y la copia de DB. Se conservaron
`repo-HEAD.tar`, `external-cutover.tar`, `SHA256SUMS` y las dos extracciones
privadas de código/diffs; `sha256sum -c` volvió a dar RC 0. Para repetir las
comprobaciones primero habrá que recrear el sandbox —los secretos privados se
volverán a copiar desde los originales y deberán volver a eliminarse al final—:

```bash
test ! -e [RUTA DE LABORATORIO REDACTADA]
python3 [RUTA DE LABORATORIO REDACTADA]
```

El helper rechaza sobrescribir un sandbox existente, crea de nuevo los cinco
directorios privados, clona overlay/binario, copia las credenciales a modo
`0600` y respalda la DB mediante conexión SQLite fuente `mode=ro`; después
verifica marcador, `quick_check` y cobertura. Antes de repetir aceptación hay
que volver a revisar el manifest/rutas y resolver el conflicto del puerto sin
interactuar con servicios preexistentes.

### Veredicto de aceptación

- **Demostrados:** sintaxis/AST/diff check; integridad de respaldos; aislamiento
  del snapshot y de los sondeos; marcador completado, `quick_check=ok`, cobertura
  completa de IDs V1; modelos y credenciales por ID/método; hashes de wrapper,
  credenciales originales y tres controles Omarchy sin cambios; diffs acotados;
  ningún proceso propio superviviente; copias privadas eliminadas; sin commit ni
  push.
- **BLOQUEADO:** enumeración runtime exacta de una lista que contenga solo
  `forge-guard`; OpenCode 2.1.4 devuelve `No plugins found` y `/api/plugin`
  `data=[]` aunque el log registra la carga. La corroboración funcional nueva
  del hook no se ejecutó. El GLOBAL VERIFIER literal también retorna RC 1 por
  el puerto preexistente ocupado; el reintento sandbox confirmó el bloqueo
  semántico, no lo resolvió.
- **Cierre:** la aceptación obligatoria no está completa y el plan **NO puede
  cerrarse como completado**. Step 3.2 permanece abierto; no se editó el plan.

## Nota histórica de soporte — repetición de Step 3.2 antes del supervisor (2026-10-24T22:26:16Z–22:32:10Z; supersedida)

Esta nota complementa el resultado anterior. El sandbox eliminado al terminar
la ejecución previa se recreó porque lo necesita el orquestador/revisor; queda
preservado y **no se limpió al terminar esta repetición**.

### Recreación e invariantes

Se confirmó que `[RUTA DE LABORATORIO REDACTADA]` no existía y se
ejecutó literalmente:

```bash
python3 [RUTA DE LABORATORIO REDACTADA]
```

RC 0. El helper usó la fuente SQLite con `mode=ro` y `Connection.backup()`; su
salida verificó marcador `completed`, `quick_check=ok`, `session=881`,
`session_v2=887`, `v1_missing_in_v2=0`. El sandbox y `home`, `config`, `data`,
`state`, `cache` tienen modo `0700`; `.opencode-tokens`, `auth.json` y la copia
de la DB tienen modo `0600`. La copia consistente de la DB permanece en
`data/opencode/opencode.db`.

Las copias privadas de credenciales siguen presentes intencionadamente para la
revisión final: `home/.opencode-tokens` (142 bytes) y `data/opencode/auth.json`
(2352 bytes), ambas modo `0600`. No se imprimieron secretos. El listado local
volvió a mostrar ID/método `minimax-cn/env`, `minimax/env`,
`minimax-cn-coding-plan/env`, `minimax-coding-plan/key` y `env`, y
`openai/oauth`. La comprobación read-only posterior dio de nuevo
`quick_check=ok`, marcador `{"phase":"completed"}`, cobertura V1 ausente `0`,
`v2_only=6`; los modelos siguen presentes en `session_v2.model`:
`MiniMax-M3.1-Flash` (3), `gpt-6-luna` (1), `gpt-6.1-sol` (3).

La DB original conservó tamaño **[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] bytes** antes y después. Su mtime
avanzó mientras los servicios ajenos seguían activos; no se calculó ni exigió
hash fijo. La única fuente DB entregada a verificadores/probes fue la copia
sandbox. Los hashes actuales de wrapper, credenciales originales y tres
ficheros controlados de Omarchy volvieron a coincidir con los valores de
preflight de Step 1.2 ya tabulados arriba.

### Puerto aislado y GLOBAL VERIFIER

Se confirmó que el puerto por defecto [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] pertenecía al servicio preexistente
PID [PID REDACTADO]. No se tocó. Para evitarlo, se eligió el puerto privado [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y se
configuró exclusivamente en `sandbox/config/opencode-forge/service.json`; el
manifest, overlay, binario y todos los XDG/Home del proceso seguían bajo el
sandbox. La configuración temporal de HOME usada para comprobar
`status`/`doctor` se restauró byte por byte; el manifest canónico volvió a
contener los targets originales `claude` y `opencode`, sin symlink de launcher
temporal.

Se ejecutó el GLOBAL VERIFIER literal desde el repo, además de una repetición
literal con el servicio privado ya iniciado y un manifest temporal OpenCode-only
para aislar los diagnósticos. Resultado reproducible por estado del servicio:

| Ejecución | RC | Línea de parada / evidencia |
|---|---:|---|
| GLOBAL inicial, servicio frío | 1 | El xtrace termina en `grep -q 'forge-guard'` (línea 207 del plan). Una repetición individual fría dio RC 0 y salida literal `No plugins found`; el `grep` dio RC 1 y la rama de salida por lista vacía RC 1. |
| GLOBAL con servicio privado caliente | 1 | Pasó los dos chequeos de plugin y se detuvo en `sandbox_run bash install.sh status` (línea 209 del plan), con `Estado general: DEGRADADO`. |

El estado **no es estable entre arranque frío y servicio caliente**. La lista
individual caliente dio RC 0 y enumeró una única fila:

```text
ID           VERSION  SOURCE
forge-guard  local    [RUTA DE LABORATORIO REDACTADA]
```

Sobre esa salida caliente, `grep -q forge-guard` dio RC 0 y la condición de
`No plugins found` no se activó. En cambio, la consulta fría independiente
devolvió `No plugins found`, `grep -q forge-guard` RC 1 y la condición de
rechazo RC 1. La salida de `GET /api/plugin` en el servidor caliente fue JSON
válido con `data=[]` (RC 0). Por tanto, la repetición **no confirma una matriz
determinista**: la CLI enumera `forge-guard` cuando el servicio está caliente,
pero no al arrancar en frío; la API de inventario sigue vacía.

Con HOME sandbox OpenCode-only y launcher corregido mediante symlink temporal,
`status` RC 1 mostró `DEGRADADO`, `auth list` válido (2 elementos), `session
list` válido (0) y guard `UNAVAILABLE`. `doctor` RC 1 mostró `FAILs=1 WARNs=1`;
su único FAIL fue la enumeración `UNAVAILABLE`. El GLOBAL caliente no llegó a
`doctor` por el RC 1 de `status`; `doctor` se ejecutó aparte. Esto reproduce los
diagnósticos no saludables, pero revela que el inventario estático de
`status`/`doctor` no refleja la enumeración caliente de la CLI. No se modificó
producción para ocultar esa discrepancia.

### Matriz individual repetida

| Criterio | RC | Veredicto inspeccionado |
|---|---:|---|
| Rama correcta, `git diff --check` | 0 | Pasa |
| Sintaxis de launcher, `install.sh`, `cutover.sh`, `ROLLBACK.sh` | 0 cada uno | Pasa |
| AST de `plugin-sync.py` y `dbtool.py` | 0 | Pasa sin ejecutar/importar |
| `sha256sum -c SHA256SUMS` | 0 | Ambos respaldos íntegros |
| Cinco directorios sandbox | 0 | Pasa; modos privados confirmados |
| Launcher `--version` | 0 | `opencode v2.1.4` |
| `auth list` y parseo JSON | 0 cada uno | Pasa; payload no divulgado |
| `session list` y `test -s` | 0 cada uno | Pasa; títulos no divulgados |
| `plugin list` frío / `grep forge-guard` | 0 / 1 | Comando válido, inventario vacío; criterio no pasa |
| `plugin list` caliente / `grep forge-guard` | 0 / 0 | Lista solo `forge-guard`; discrepante con API `data=[]` y arranque frío |
| `status` preparado | 1 | `DEGRADADO`; guard `UNAVAILABLE`, probes operativos pasan |
| `doctor` preparado | 1 | `FAILs=1`; único FAIL guard `UNAVAILABLE` |
| Informe no vacío | 0 | Pasa |
| GLOBAL frío / GLOBAL caliente | 1 / 1 | Se detienen respectivamente en grep y status; ninguno termina con RC 0 |

### Procesos, sandbox preservado y veredicto de esta repetición

Los procesos propios de servicio sandbox PID [PID REDACTADO] y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] se terminaron
con TERM tras verificar ejecutable bajo la copia y listener exclusivo en el
puerto privado. No queda proceso con entorno o ejecutable dentro del sandbox;
`pgrep -a -f forge-v2-remediation` no encontró procesos propios. `pgrep -a -f
opencode` solo muestra los preexistentes [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO], [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO], [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] y [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]; no
se tocaron. PID [PID REDACTADO] conserva el listener [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]. El puerto privado [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]
quedó libre; se conserva su configuración sandbox para facilitar la revisión.

El sandbox y las copias privadas de credenciales quedan **preservados para el
orquestador y el revisor**. La limpieza se difiere hasta después de la revisión
final; después habrá que eliminar `.opencode-tokens`, `auth.json` y las demás
copias privadas. Los archivos `repo-HEAD.tar`, `external-cutover.tar` y
`SHA256SUMS` siguen íntegros. Rama y working tree del repo permanecen como
antes; el plan no cambió y no hubo commit ni push.

**Veredicto de esa repetición pre-corrección:** el sandbox era recreable y el tamaño
de la DB original se conserva, pero **no reproduce una matriz estable**: los
resultados de plugin list dependen de arranque frío/caliente y contradicen
`/api/plugin` y el `UNAVAILABLE` fijo de `status`/`doctor`. Ambos GLOBAL
VERIFIER terminan RC 1. Se mantiene el plan sin cerrar como completado hasta
que el revisor resuelva esta discrepancia y acepte la enumeración exigida.

## Addendum — implementación y aceptación de enumeración runtime (2026-10-24T22:42Z–23:03Z)

Este addendum supersede las conclusiones operativas anteriores sobre el bloqueo
de enumeración; conserva aquellas observaciones como evidencia histórica de un
backend frío. No se editó el plan, no hubo commit ni push.

### Mecanismo implementado

`forge-opencode plugin list` ahora materializa la config y los paquetes de la
instalación efectiva en un árbol temporal privado, no consulta el servicio
compartido y no construye una lista desde config ni metadatos de paquetes. El
supervisor en `open-code/lib/plugin-sync.py` crea HOME/XDG y registro de
servicio privados, inicia `serve --service --hostname 127.0.0.1 --port 0`,
verifica PID, listener loopback y `/api/info` autenticado, y consulta el
comando CLI real repetidamente. Espera 250 ms entre sondeos, limita cada intento
CLI a 2 s, reserva 30 s para preparación/arranque/sondeo y un máximo total de
35 s para limpieza. Solo publica la salida original cuando tiene una única fila
local `forge-guard` cuyo `SOURCE` pertenece al paquete copiado y declarado;
vacío, filas adicionales, error, timeout o fallo de limpieza no se aceptan.
No se inyecta `--standalone`; los caminos `plugin list --help`/`-h` no arrancan
backend. MCP y proveedores se excluyen de esta sonda de inventario.

`status` y `doctor` ejecutan esa sonda contra la config/paquetes instalados
seleccionados por el manifest y una copia privada coherente de DB, separada de
sus probes `auth`/`session`. Un fallo de preparación segura se comunica como
`UNAVAILABLE`; una ejecución vacía, incorrecta o errónea es `INVALID` o
`MISMATCH`; solo la fila exacta es `OK`. No se hicieron reparaciones ni
migraciones de estado productivo.

El ensayo frío/caliente explica la conclusión histórica: un servicio 2.1.4
frío devolvió `No plugins found` al principio, pero la CLI real devolvió luego
`forge-guard` una vez cargado el plugin por el servidor. En el endpoint
`GET /api/plugin` se volvió a observar HTTP 200 con `data=[]`. La descripción
documentada del endpoint es el estado de plugins habilitados del servidor;
este resultado se informa separadamente y no se fuerza a coincidir con CLI ni
demuestra que ambos inventarios sean necesariamente independientes. El log
`loading plugin` es corroboración de actividad del loader, no una prueba del
hook. La nueva corroboración funcional del hook sigue **no ejecutada**.

### Repeticiones, errores y señales

- Tres invocaciones consecutivas frías de `forge-opencode plugin list` dieron
  RC 0 en **5207, 5226 y 5214 ms**, cada una con exactamente el encabezado y
  una fila local `forge-guard`.
- En una repetición directa con servidor aislado caliente, los dos primeros
  intentos CLI devolvieron `No plugins found` con RC 0; el tercero devolvió la
  fila exacta. `/api/plugin` respondió HTTP 200 con lista `data` de longitud 0.
  El log del mismo servidor incluyó `loading plugin` para el entrypoint privado.
- Con el contexto caliente preexistente, el launcher inició de todos modos su
  propio servicio privado y devolvió la fila exacta (RC 0, 5144 ms). Dos
  invocaciones simultáneas crearon raíces, PIDs y puertos efímeros distintos;
  ambas devolvieron solo la fila exacta (RC 0).
- Backend no disponible (`FORGE_OPENCODE_BIN=/bin/false`): RC 1, diagnóstico de
  salida del backend y eliminación del árbol privado. El launcher del respaldo
  histórico, probado en el sandbox aislado, sigue fallando `auth list` y
  `session list` con RC 1 y `Unrecognized flag: --standalone`.
- Se corrigió también la propagación de señales del launcher. El supervisor
  corre en una sesión separada; ante señal al grupo del launcher, el shell
  reenvía la señal y espera su limpieza antes de salir. SIGINT terminó en RC
  **130** (3746 ms) y SIGTERM en RC **143** (4028 ms); en ambos casos se borró la
  raíz privada y no quedaron procesos con ese entorno/ruta. El PID **[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]**
  siguió siendo dueño del listener preexistente `127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; no se señaló
  ni modificó.

### GLOBAL VERIFIER literal y matriz final

Tras preparar únicamente el manifest temporal OpenCode-only y el symlink
temporal de launcher dentro del HOME sandbox, se ejecutó sin alterar comandos
el bloque GLOBAL VERIFIER literal del plan. Resultado: **RC 0**. Después de
incorporar este addendum se volvió a ejecutar el mismo bloque literal; volvió a
terminar con **RC 0**, stderr vacío, y `status`/`doctor` saludables. Salida de
plugin inspeccionada:

```text
ID           VERSION  SOURCE
forge-guard  local    <raíz temporal privada>/overlay/plugin-packages/forge-guard/index.js
```

El path concreto era efímero y se eliminó al salir. `status` terminó RC 0 con
`Estado general: OK`; `doctor` terminó RC 0 con `FAILs=0 WARNs=1`. La matriz
individual repetida después de la corrección de señales fue:

| Criterio | RC | Tiempo | Inspección |
|---|---:|---:|---|
| Rama correcta | 0 | 4 ms | `fix/fix-v2-launcher-verifiers` |
| `git diff --check` | 0 | 7 ms | Sin errores de whitespace |
| Sintaxis launcher / `install.sh` / cutover / rollback | 0 cada uno | 3–7 ms | `bash -n`, sin ejecutar cutover/rollback |
| AST `plugin-sync.py` y `dbtool.py` | 0 | 43 ms | `ast.parse`, sin importar/ejecutar |
| `sha256sum -c backup/SHA256SUMS` | 0 | 12 ms | Respaldos válidos |
| Directorios privados sandbox | 0 | 3 ms | Cinco directorios requeridos presentes |
| Launcher `--version` | 0 | 103 ms | `opencode v2.1.4` |
| `auth list --format json` / parseo JSON | 0 cada uno | 1937/51 ms | JSON válido; payload omitido |
| `session list` / salida no vacía | 0 cada uno | 533/1 ms | Payload omitido |
| `plugin list` | 0 | 5028 ms | Exactamente una fila local `forge-guard` |
| `grep -q forge-guard` / rechazo de `No plugins found` | 0 cada uno | 2/3 ms | Ambos criterios pasan sobre la salida inspeccionada |
| `install.sh status` | 0 | [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] ms | Enumeración `OK`; estado general `OK` |
| `install.sh doctor` | 0 | [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] ms | `FAILs=0 WARNs=1`; enumeración `PASS` |
| Informe externo no vacío | 0 | 1 ms | Pasa |
| GLOBAL VERIFIER literal | **0** | [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] ms en la última repetición | Completó hasta `test -s REMEDIATION-REPORT.md`; stderr vacío |

La comprobación de DB se repitió solo sobre
`[RUTA DE LABORATORIO REDACTADA]`, con
SQLite `mode=ro`, `query_only=ON` y transacción de lectura: `quick_check=ok`,
marcador `{"phase":"completed"}`, `session=881`, `session_v2=887`,
`v1_missing_in_v2=0`, `v2_only=6`, `message=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, `part=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`. Los recuentos
agregados por subcadena de `session_v2.model` fueron 3 para
`MiniMax-M3.1-Flash`, 1 para `gpt-6-luna` y 3 para `gpt-6.1-sol`. El listado de
auth expuso solo IDs/métodos ya tabulados; no se hizo login ni petición a
proveedores. El tamaño observado de la DB original y de la copia sandbox fue
`[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes; no se usa un hash de DB viva como garantía.

Los seis hashes de wrapper, credenciales originales y controles Omarchy
volvieron a coincidir con preflight de Step 1.2. Manifest temporal restaurado
byte por byte y symlink temporal eliminado. No quedaron raíces `forge-opencode-*`
ni registros de servicio privados en acceptance; la copia sandbox y sus
credenciales privadas quedan preservadas para revisión final, sin exponer
contenido. La comparación externa se hizo extrayendo el respaldo en un
directorio privado nuevo; CUTOVER-NOTES difiere y REMEDIATION-REPORT es el
informe externo actualizado. El plan permanece intacto; no hubo commit ni push.

### Veredicto actualizado

Step 2.2 queda **demostrado para la interfaz CLI real** en el contrato
observado; la hipótesis histórica de imposibilidad de enumeración se refuta por
las salidas reales posteriores al arranque. Step 3.2 y el GLOBAL VERIFIER pasan
con RC 0 en el sandbox aislado. La aceptación funcional del hook no se incluye
ni se afirma. Las conclusiones históricas de los apartados anteriores quedan
conservadas como registros de las ejecuciones frías/pre-corrección; este
addendum contiene el resultado actual. No se editó el plan ni se marcó su
estado.

## Corrección de Step 3.2 — aceptación autónoma con sandbox fiel (2026-10-25)

### Rectificación del RC anterior

La conclusión de RC 0 del addendum precedente **no es evidencia válida del
GLOBAL VERIFIER completo**: en aquellas ejecuciones se sustituyó temporalmente
el manifest por uno OpenCode-only y se omitió el launcher instalado y el target
Claude. Eso impedía reproducir la instalación y el resultado no verificaba el
contrato completo de `status`/`doctor`. El orquestador ejecutó luego el bloque
literal como script autónomo (con `set -e` efectivo) y observó RC 1 al llegar a
`install.sh status`: launcher sandbox ausente y enlaces del target Claude
rotos. Se retiran, por tanto, los resultados de ese manifest reducido como
aceptación; el RC que sigue procede de la nueva ejecución con ambos targets y
la forma de instalación reproducida.

### Preparación del sandbox y contrato del launcher

Se completó `[RUTA DE LABORATORIO REDACTADA]` conservando la copia
privada existente. El manifest completo conserva los targets `claude` y
`opencode`; `claude.dir` se dirige a `sandbox[RUTA PERSONAL REDACTADA]`, y `opencode.dir`,
`config_file` y `binary` apuntan respectivamente a `sandbox/config`, su
`opencode.jsonc` y el prefijo/binario clonado. `XDG_DATA_HOME` y la DB son los
del sandbox. La DB clonada tiene modo `0600`, la original y la copia miden
`[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` bytes.

Se recrearon **28 symlinks declarados por el manifest** y el symlink adicional
real `skills/omarchy`; los 29 resuelven. Sus destinos son los mismos absolutos
de la instalación (`[RUTA PERSONAL REDACTADA]` y el target
instalado de Omarchy); no se escribió en ninguno de ellos. Se copiaron a la
zona privada `settings.json`, `settings.json.pre-forge` y `CLAUDE.md`, cada uno
con modo `0600`; directorios `home/.claude` y superiores privados `0700`.
Revalidación de `status`/`doctor` confirmó el manifest con los dos targets y
cero links rotos.

No se instaló una copia regular en `home/.local/bin/forge-opencode`: el
contrato implementado por `install.sh` exige que ese path sea un symlink exacto
a `$FORGE_ROOT/open-code/forge-opencode.sh` y clasifica una copia regular como
`INVALID`. La instalación real es precisamente ese symlink. El sandbox replica
el mismo destino y el fichero es ejecutable. El script no fija HOME, overlay,
prefijo ni DB productivos en su contenido: resuelve overlay/config/binario del
manifest privado y datos/DB desde HOME/XDG privados, por lo que el enlace
compartido al código fuente es de solo lectura y no dirige estado mutable a
producción. Forzar una copia distinta habría hecho fallar el propio diagnóstico
de launcher, no habría sido una reproducción fiel.

El procedimiento `[RUTA DE LABORATORIO REDACTADA]` fue
actualizado para construir esta forma en una recreación nueva y dispone de
`--complete-existing`, que completa idempotentemente un sandbox existente sin
reemplazarlo. La ejecución de ese modo y la revalidación posterior pasaron; el
procedimiento copia solo los ficheros Claude necesarios, conserva los targets
absolutos de los links y falla cerrado ante rutas fuente no previstas o
conflictos existentes.

### GLOBAL VERIFIER autónomo y matriz

Se ejecutó el bloque literal como un proceso Bash hijo independiente con el
`set -euo pipefail` del propio bloque; no se llamó desde `if`, función
condicional ni wrapper que pudiera desactivar `errexit`. No se reescribió ni
redujo el manifest para la ejecución. El script completó hasta
`test -s REMEDIATION-REPORT.md`: **RC REAL 0**, **38.012 ms**, stderr vacío. Tras
actualizar este addendum se repitió autónomamente y volvió a completar con
**RC 0 en 37.530 ms**, también con stderr vacío. La última repetición guardó el
bloque literal en `sandbox/acceptance-3.2/global-verifier-file-run/global-verifier.sh`
y lo ejecutó con `bash <fichero>` fuera de cualquier condicional: **RC=0**,
**39.532 ms**, stderr vacío.
La tabla CLI completa inspeccionada fue:

```text
ID           VERSION  SOURCE
forge-guard  local    /tmp/forge-opencode-plugin-list-<id>/overlay/plugin-packages/forge-guard/index.js
```

`status` incluyó los targets `claude` y `opencode`, RC 0 y `Estado general:
OK`. `doctor` incluyó ambos targets, RC 0, `FAILs=0 WARNs=0`. La matriz
individual posterior, con el mismo sandbox fiel, fue:

| Criterio | RC | Tiempo | Resultado inspeccionado |
|---|---:|---:|---|
| Rama `fix/fix-v2-launcher-verifiers` | 0 | 6 ms | Coincide |
| `git diff --check` | 0 | 5 ms | Sin errores |
| `bash -n` launcher / `install.sh` / cutover / rollback | 0 cada uno | 3–8 ms | Solo análisis sintáctico |
| AST `plugin-sync.py`, `dbtool.py`, `prepare-sandbox.py` | 0 | 47 ms | `ast.parse`; no importados ni ejecutados |
| `sha256sum -c backup/SHA256SUMS` | 0 | 8 ms | Respaldos íntegros |
| Directorios privados sandbox | 0 | 3 ms | Los cinco existen |
| Consistencia de manifest/launcher sandbox | 0 | 31 ms | Ambos targets; launcher ejecutable y symlink correcto |
| Launcher `--version` | 0 | 100 ms | `opencode v2.1.4` |
| `auth list --format json` / JSON válido | 0 cada uno | 1868/57 ms | JSON válido; payload omitido |
| `session list` / salida no vacía | 0 cada uno | 521/1 ms | Pasa; payload omitido |
| `plugin list` / tabla exacta | 0 cada uno | 4946/27 ms | Encabezado y solo fila local `forge-guard` |
| Rechazo de `No plugins found` | 0 | 4 ms | El texto no aparece |
| `install.sh status` | 0 | [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] ms | Targets Claude/OpenCode presentes; estado `OK` |
| `install.sh doctor` | 0 | [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] ms | `FAILs=0 WARNs=0` |
| Informe externo no vacío | 0 | 1 ms | Pasa |
| GLOBAL VERIFIER literal autónomo | **0** | **[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] ms (última repetición desde fichero)** | Terminó; stderr vacío |

### Concurrencia, puerto, señal y negativo histórico

- Dos enumeraciones concurrentes completaron en **5177 ms**. Registros
  privados distintos: PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` / puerto `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` y PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` / puerto
  `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; ambos comandos dieron RC 0, stderr vacío y la fila exacta. Las dos
  raíces temporales se eliminaron.
- Antes y después de la concurrencia e interrupciones,
  `127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` siguió perteneciendo a PID preexistente `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`. No se le
  envió señal ni se alteró su configuración. El servidor de cada enumeración
  usó su propio puerto efímero asignado mediante `--port 0`.
- Envío de señal al grupo del launcher durante servicio activo: SIGINT devolvió
  RC **130** en **3569 ms** y SIGTERM RC **143** en **3533 ms**. Cada raíz
  privada se eliminó, no quedó proceso con su entorno/ruta y ambos tiempos
  quedaron dentro del límite de 35 s.
- Launcher antiguo extraído del respaldo: `auth list --format json` y `session
  list` devolvieron RC **1**. Errores literales: `auth` —
  `Unrecognized flag: --standalone in command opencode auth`; `session` —
  `Unrecognized flag: --standalone in command opencode session`. Se usaron
  HOME/XDG/DB sandbox y no se creó registro de servicio.

### Invariantes y veredicto corregido

Al terminar: DB original **[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] B**, DB sandbox **[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] B**; manifest
completo conservado, DB sandbox `quick_check=ok`, marcador `completed`,
`v1_missing_in_v2=0`; cero raíces privadas de plugin-list supervivientes. Los
únicos servidores OpenCode observados fueron los preexistentes PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` y
`[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; este último retiene [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]. No se modificaron DB original, Omarchy,
wrapper, credenciales originales ni configuración instalada. No se editó el
plan, no se escribieron tests/fixtures y no hubo commit ni push.

Con esta corrección el **GLOBAL VERIFIER real pasa: RC 0**. Los resultados del
manifest OpenCode-only del addendum anterior quedan explícitamente invalidados
como aceptación. La corroboración funcional nueva del hook continúa sin
ejecutarse y no se afirma aquí.

## Lote final de revisión — snapshot privado, deadline y propiedad (2026-10-25)

### Cambios de `plugin-sync.py` (hallazgos 1–3)

- La ruta de origen se consulta al binario pinado mediante `opencode debug paths
  db` **antes** de crear/cambiar el HOME/XDG runtime. Comprobación con el binario
  2.1.4 copiado y entorno sandbox: `OPENCODE_DB=relative.db` resolvió a
  `[RUTA DE LABORATORIO REDACTADA]`;
  `OPENCODE_DB=:memory:` devolvió literalmente `:memory:`; sin variable resolvió
  al `.../data/opencode/opencode.db` por defecto. El destino relativo ya no se
  interpreta respecto del cwd y `:memory:` no se convierte en fichero.
- Para DB de fichero, el snapshot usa URI SQLite `mode=ro`, `PRAGMA query_only`
  y `Connection.backup()` a una DB distinta dentro del root privado (modo
  `0600`). El runtime entrega al servidor únicamente esa ruta privada. Para
  `:memory:` el runtime mantiene ese destino especial. Un fallo de lectura,
  espacio, copia o resolución aborta antes de arrancar backend.
- El supervisor mantiene un solo deadline monotónico de **35 s** desde la
  resolución hasta limpieza. Preparación y sondeos dejan reserva de limpieza;
  todos los grupos propios reciben TERM juntos, comparten la espera, y los
  supervivientes reciben KILL juntos. La eliminación recursiva ocurre en un
  helper supervisado. Un fusible del deadline final termina los grupos propios
  restantes y retorna RC 124; ya no hay comprobación meramente retrospectiva
  después de exceder 35 s.
- En este host `/tmp` es tmpfs y al primer snapshot solo quedaban **1.8 GiB**,
  menos que la DB de **2,315,714,560 B**. La primera prueba falló cerrada antes
  de iniciar backend con `database or disk is full` (RC 1); no tocó producción.
  Se añadió selección de almacenamiento temporal privado por espacio libre:
  usa TMPDIR cuando cabe el snapshot y, si no, `/var/tmp` con modo privado.
  Con el entorno literal sin `TMPDIR`, el supervisor eligió `/var/tmp`, limpió
  el root y obtuvo la fila exacta. No se dejó copia persistente en `/home`.

### Evidencia runtime en sandbox

Todas las pruebas usaron HOME/XDG/config sandbox, puerto aleatorio loopback y
DB de origen sandbox; ninguna usó la DB productiva como fuente.

| Criterio | Evidencia y RC | Duración / limpieza |
|---|---|---|
| Snapshot coherente | Durante backup, PID supervisor `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, FD `3`, flags `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` (`O_RDONLY`); no apareció la DB productiva en sus FDs | `plugin list` RC 0, **7,674 ms** |
| DB backend privada | PID backend `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, puerto `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; `OPENCODE_DB` apuntaba a su propia `root/data/opencode/opencode.db`, 3 FDs privados y cero FDs hacia fuente/producción | RC 0, **8,031 ms**, raíz y PID limpiados |
| Ruta relativa real | Dos servidores concurrentes con `OPENCODE_DB=opencode.db`: PIDs `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; puertos `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; ambos env DB privados y cero FDs de fuente/productivos; fila exacta en ambos | RC 0 cada uno; **9,180 ms** total; ambas raíces retiradas |
| Destino `:memory:` | Backend PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, puerto `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, conservó `OPENCODE_DB=:memory:` y no creó fichero `:memory:` | RC 0, **3,950 ms**, raíz retirada |
| Caso de fallo y cleanup | Config seleccionada inexistente; RC 1 con diagnóstico explícito, cero raíces/servidores supervivientes | **5,607 ms**, dentro de 35 s |
| Almacenamiento por defecto sin TMPDIR | Snapshot/CLI usaron `/var/tmp` tras detectar espacio insuficiente en `/tmp`; fila única exacta, stderr vacío | RC 0, **7,422 ms**, root retirado |
| `status` sandbox | `Estado general: OK`, sondeo runtime exacto, stderr vacío | RC 0, **17,891 ms** |
| `doctor` sandbox | `FAILs=0 WARNs=0`, sondeo runtime exacto, stderr vacío | RC 0, **17,692 ms** |
| `SIGINT` durante backend | RC 130; servicio PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, puerto `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; diagnóstico de cleanup; cero procesos/root supervivientes | **6,622 ms** total, **2,452 ms** tras señal |
| `SIGTERM` durante backend | RC 143; servicio PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, puerto `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; diagnóstico de cleanup; cero procesos/root supervivientes | **6,410 ms** total, **2,484 ms** tras señal |

El puerto preexistente `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` se verificó antes/después de concurrencia y
señales: `127.0.0.1:[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` siguió en PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`; no se le señalizó.
Todas las tablas CLI inspeccionadas contenían el encabezado y exactamente una
fila local `forge-guard`, sin `No plugins found`.

### Scripts externos: decisión de propiedad y cambios estáticos

Antes de editar se copiaron `cutover.sh`, `ROLLBACK.sh`, `CUTOVER-NOTES.md` y
`REMEDIATION-REPORT.md` a
`[RUTA DE LABORATORIO REDACTADA]`; `SHA256SUMS`
verificó las copias. Los cuatro ficheros externos eran idénticos al
`review-snapshot/round0/external/` al iniciar este lote; el diff de esta pasada
contiene solo los cambios descritos aquí.

- `cutover.sh`: eliminado por completo `kill_writers_on_db`. Inventario
  parametrizado por DB y evidencia numerada independiente por comprobación;
  busca DB/WAL/SHM para cualquier ejecutable, conserva path original (incluido
  ` (deleted)`), PID/inicio/exe normalizado/dev-inode y separa holders bloqueantes.
  Checks obligatorios antes del reemplazo, antes/después del instalador sobre
  `install-probe.db`, antes de STEP 6, antes/después de parar el servidor y
  después de `auth list`/antes del veredicto. Holder no atribuible o inventario
  incompleto aborta sin señal.
- Registro STEP 6: `$!` queda registrado inmediatamente; registra inicio,
  identidad inicial, PPID, ruta/exe esperado y dev-inode. Solo autoriza
  señalización si el mismo proceso sigue siendo hijo directo y alcanza el
  ejecutable esperado dentro del plazo acotado. El manejador EXIT ya está
  instalado antes del arranque.
- `stop_server()` es idempotente, inspecciona holders antes/después, y solo
  señaliza el propio servidor con `pidfd_open`/`pidfd_send_signal`: verifica
  inicio/exe/dev-inode/PPID después de abrir pidfd; TERM hasta 15 s y KILL
  condicionado por revalidación y por el mismo pidfd. No hay fallback por PID,
  `kill -0` ni grupo. Python/kernel pidfd se comprueba en preflight antes de
  reemplazar DB. Salidas/traps se unificaron: no hay rollback/restauración
  automática, se conserva el error original y el informe definitivo se escribe
  tras limpieza, incorporando errores/holders sin detener.
- `ROLLBACK.sh`: el inventario de FDs DB/WAL/SHM se hace antes del filtro de
  nombre del ejecutable; cualquier holder bloquea, además del check
  `OPENCODE_DB` para OpenCode. La función se repite justo antes de la primera
  restauración y antes de retirar overlay/binario. Mantiene **cero señales**.
- `CUTOVER-NOTES.md`: las afirmaciones de enumeración bloqueada se marcaron
  HISTÓRICAS Y REFUTADAS y se enlazaron a la nota complementaria fechada.
  Conserva el histórico de riesgo anterior y documenta el camino pidfd, el
  fallo sin señal ante holders no atribuibles/inventarios incompletos, los
  límites estáticos, el cutover ya completado y la posibilidad de cambios
  parciales sin recuperación automática.

Validación externa **solo estática**, como exige la decisión: `bash -n` de
ambos scripts, AST de cada bloque Python añadido (helper pidfd y preflight),
revisión de todos los caminos de arranque/señal/trap/informe y diffs contra
backup pre-lote/round0. No se ejecutó, importó ni hizo `source` de
`cutover.sh`, `ROLLBACK.sh` o `dbtool.py`; no se autoriza su ejecución futura.

### GLOBAL VERIFIER literal autónomo

Se guardó sin editar el contenido literal del bloque del plan en
`[RUTA DE LABORATORIO REDACTADA]` (SHA-256
`c6eb04a7f00175f8c2761b376764481ef734b5c7caa2a4cb4fcdb10bae3a4e0f`) y se
ejecutó como proceso Bash autónomo: `time -p bash
[RUTA DE LABORATORIO REDACTADA]`. No se usó `if`,
función ni wrapper condicional para decidir/ocultar el resultado. **RC real: 0**;
tiempo real medido por Bash: **44.53 s**. El deadline de 35 s aplica a cada
enumeración runtime privada, no al verificador completo, que incluye status y
doctor.

| Criterio del verificador | Resultado observado |
|---|---|
| Rama exigida `fix/fix-v2-launcher-verifiers` | PASS |
| `git diff --check` | PASS |
| `bash -n` launcher, `install.sh`, `cutover.sh`, `ROLLBACK.sh` | PASS |
| AST Python `plugin-sync.py` y `dbtool.py` (parse solamente) | PASS |
| SHA-256 de `repo-HEAD.tar` y `external-cutover.tar` | Ambas sumas coinciden |
| HOME/config/data/state/cache sandbox | Todos los directorios presentes |
| `forge-opencode.sh --version` | `opencode v2.1.4` |
| `auth list --format json` y parseo JSON | PASS; array válido de 2 elementos, contenido no impreso |
| `session list` | RC 0; fichero no vacío |
| `plugin list` | RC 0; tabla exacta: encabezado `ID VERSION SOURCE` y única fila local `forge-guard`; sin `No plugins found` |
| `install.sh status` | RC 0; `Estado general: OK`; comprobaciones de overlay/launcher/auth/sesiones/plugin/RTK OK |
| `install.sh doctor` | RC 0; `Resumen: FAILs=0 WARNs=0`; comprobaciones del overlay, launcher, auth/sesiones/plugin y RTK PASS |
| Informe externo existente | PASS |

La salida sandbox de autenticación no se copió a la conversación/informe y se
mantuvo solo en el sandbox privado. GLOBAL VERIFIER completado; no queda una
ejecución pendiente.

### Invariantes de cierre

DB productiva `[RUTA PERSONAL REDACTADA]` observada
en **2,315,714,560 B** antes y después; puerto `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` preservado.
Scratch creado para las pruebas eliminado; cero raíces runtime privadas
supervivientes. Procesos OpenCode preexistentes al cierre: PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, PID
`[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` (titular del puerto `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`) y PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`. Este último ya existía
antes del lote (inicio observado `2026-10-24 21:36:14`, PPID `860`), ejecuta
`opencode serve` desde `[RUTA DE LABORATORIO REDACTADA]` y conserva descriptores al
conjunto DB del lab (`opencode.db`, `-wal` y `-shm`, todos marcados
`(deleted)`); no apunta ni tiene FDs hacia la DB productiva. Es ajeno y no se
señalizó ni cerró. Sin cambios a Omarchy, wrapper, credenciales ni configuración
instalada; sin commits/push, sin tests/fixtures y sin repetición/rollback de
migración.

## Lote final de hallazgos menores (segunda ronda)

### Correcciones y evidencia

1. **Fusible y limpieza de la raíz privada.** El deadline fuse comparte ahora
   estado sincronizado con el supervisor, mata primero los grupos propios,
   intenta `shutil.rmtree(private_root)` y solo entonces ejecuta `os._exit(124)`.
   Reserva 2 s del presupuesto único para esa limpieza. Prueba real del fusible:
   se pausó por ptrace únicamente el hilo principal del supervisor sandbox
   (PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`), dejando activo su hilo de deadline; RC **124** a los
   **33,420 ms**, backend propio `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]` terminado, raíz
   `/var/tmp/forge-opencode-plugin-list-05shwufm` eliminada y cero procesos con
   esa ruta/entorno.
2. **Una sola copia SQLite y snapshot reutilizable.** `plugin-sync.py` ofrece
   `snapshot-db`; los dos bloques SQLite inline de `install.sh` se sustituyeron
   por ese modo. El supervisor acepta `--database-private` solo para un fichero
   mode `0600`, propiedad del usuario y dentro de una raíz
   `forge-opencode-plugin-diagnostic.*` mode `0700`; si está presente, resuelve
   `OPENCODE_DB` con el binario pinado pero no vuelve a copiarlo ni a reservar
   espacio para una segunda DB. `forge-opencode.sh` pasa el indicador privado
   únicamente para la sonda de instalación. `status` sandbox observado durante
   la sonda: root `/var/tmp/forge-opencode-plugin-diagnostic.0nrvjqve`, backend
   PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, una DB mode `0600` de **2,315,714,560 B**, exactamente una DB
   bajo el root y cero DB bajo el root runtime anidado; `OPENCODE_DB` del
   backend apuntó al único snapshot exterior. RC **0**, **14,349 ms**, guard
   exacto, stderr vacío y root eliminado al terminar.
3. **Presupuesto pidfd de `cutover.sh`.** Sin ejecutar el script: el bloque
   calcula un único deadline de **15 s**; asigna el 80% al sondeo TERM y usa
   solo el tiempo restante tras SIGKILL para confirmar salida. `bash -n` y
   `ast.parse` del heredoc verifican sintaxis; validación exclusivamente
   estática como está restringido.
4. **Ayuda/opciones y parámetro muerto.** Se conserva `--database` por
   compatibilidad, con help que lo describe como override de `OPENCODE_DB`
   resuelto por el binario pinado antes de XDG privado. Se documenta
   `--database-private` y se eliminó `reserve_cleanup` de `_deadline_check`;
   todas las llamadas usan el presupuesto/reserva real. La ayuda de ambos
   modos se inspeccionó.
5. **RC 124 dominante.** Si falla limpieza, el resultado permanece 124 (igual
   que 130/143); el fallo adicional se añade al diagnóstico. Comprobación
   dirigida del handler `cmd_runtime_list`: `RuntimeDeadline` controlado más
   limpieza forzada a fallar produjo RC **124** y el mensaje
   `cleanup also failed: one or more owned processes or private files could
   not be cleaned`.
6. **Anchor de notas.** El encabezado pasó a `Nota complementaria (2026-10-25)`;
   comprobación del slug: `nota-complementaria-2026-10-25`. Los **4** enlaces a
   la sección (incluido el enlace del pasaje histórico) coinciden con ese slug.
7. **Proceso preexistente en el informe.** Se corrigió el invariante final:
   registra PID `[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, iniciado `2026-10-24 21:36:14` (PPID `860`),
   `opencode serve` de `[RUTA DE LABORATORIO REDACTADA]`; sus FDs de DB son el
   conjunto `opencode.db`, `-wal` y `-shm`, todos `(deleted)`, sin FD hacia la
   DB productiva. Se observó vivo tras el lote; no se señaló ni cerró.

### Pico de espacio y límites

El pre-check de `install.sh` mide DB fuente + WAL + SHM, añade
`max(64 MiB, 5%)` para el snapshot y 32 MiB de metadata; es la cota de **una**
copia privada, no de dos. Para la copia sandbox observada: fuente
2,315,714,560 B, sidecars 32,768 B, estimación snapshot con margen
2,431,534,694 B, umbral total **2,465,089,126 B**. `/tmp` ofrecía
1,919,197,184 B (insuficiente) y `/var/tmp` 1,863,241,445,376 B; se eligió
`/var/tmp`. La observación del proceso confirmó una sola copia de tamaño real,
ninguna copia en el root runtime anidado y eliminación normal del root.

La prueba del deadline fuse usó DB sandbox (`XDG_DATA_HOME` bajo
`[RUTA DE LABORATORIO REDACTADA]`), no la base original. El caso de
RC 124+fallo de limpieza fue una comprobación dirigida del handler para forzar
ese estado excepcional; no se dejó ningún proceso ni artefacto de prueba.

### Verificación final

GLOBAL VERIFIER literal autónomo después de este lote: se ejecutó directamente
como `time -p bash [RUTA DE LABORATORIO REDACTADA]`,
fuera de cualquier `if`/wrapper condicional. **RC real: 0; real: 37.88 s**.
Matriz observada:

| Criterio | Resultado |
|---|---|
| Rama esperada y `git diff --check` | PASS |
| `bash -n` launcher, `install.sh`, `cutover.sh`, `ROLLBACK.sh` | PASS |
| `ast.parse` `plugin-sync.py` y `dbtool.py` | PASS; parsing, sin ejecutar dbtool |
| SHA-256 de los dos respaldos del verificador | Ambas sumas coinciden |
| HOME/config/data/state/cache sandbox | Todos presentes |
| Versión | `opencode v2.1.4` |
| Auth JSON | PASS; array JSON válido de 2 elementos, contenido no expuesto |
| Session list | RC 0; salida no vacía |
| Plugin list runtime real | RC 0; tabla exacta con solo `forge-guard`; sin `No plugins found` |
| `install.sh status` | RC 0; `Estado general: OK` y probe exacto |
| `install.sh doctor` | RC 0; `FAILs=0 WARNs=0` y probe exacto |
| Informe de remediación | Presente |

`cutover.sh`, `ROLLBACK.sh` y `dbtool.py` permanecen sin ejecutar/importar/
source. La validación de los scripts externos fue únicamente `bash -n`, AST y
revisión estática.

## Limpieza final de copias privadas (Step 3.2)

Se retiraron del sandbox, tras comprobar que cada destino era una ruta regular
no symlink, canónica y contenida en
`[RUTA DE LABORATORIO REDACTADA]`:

- `sandbox/data/opencode/auth.json` (2352 B), la copia privada de credenciales.
- `sandbox/data/opencode/opencode.db` ([IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] B) y sus sidecars
  `opencode.db-wal` (0 B) y `opencode.db-shm` ([IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] B).
- `sandbox[RUTA PERSONAL REDACTADA]` (142 B), copia privada adicional de tokens.
- `sandbox/auth-list.json` (1092 B) y los stdout brutos de autenticación bajo
  `sandbox/acceptance-3.2/`: `auth_json.stdout` y `auth_list.stdout` de las
  matrices ordinaria, `faithful-matrix`, `final-matrix` y `global-final/matrix`,
  más `auth.stdout` de `negative-old-launcher` y
  `negative-old-launcher-final` (**10** salidas en total). No se eliminaron
  credenciales originales ni los diagnósticos stderr/RC.

Inventario posterior: no quedan `auth.json`, `.opencode-tokens`,
`auth-list.json`, `opencode.db` ni sidecars DB en el árbol de remediación; no
hay ficheros DB de más de 2 GB. La búsqueda de raíces
`forge-opencode-plugin-list-*` en el sandbox y en `/var/tmp` no encontró
ninguna; no quedaron snapshots runtime en `/tmp` o `/var/tmp`. El sandbox se
conserva como evidencia, pero está intencionadamente incompleto y ya no sirve
para repetir probes autenticados o de DB.

Se conservaron `backup/` (incluidos `repo-HEAD.tar`, `external-cutover.tar` y
`SHA256SUMS`), `review-snapshot/`, los cuatro JSON saneados
`isolation-evidence*.json`/`step-2-1-*.json`, `external-step-2-4.diff`,
`external-orig-step-2-4.*`, `prepare-sandbox.py`, todos los
`verify-isolation*.py`, `global-verifier.*`, `verifier*.out/err` y los demás
ficheros externos. No se siguieron ni borraron symlinks.

Para recrear el sandbox cuando se necesite repetir validaciones: las fuentes
originales `[RUTA PERSONAL REDACTADA]`,
`[RUTA PERSONAL REDACTADA]` y
`[RUTA PERSONAL REDACTADA]` deben seguir presentes.
El `prepare-sandbox.py` conservado vuelve a copiar ambas credenciales al
sandbox con permisos privados y reconstruye la DB usando SQLite backup desde
una conexión de solo lectura. Como el script rechaza sobrescribir un sandbox
existente, primero hay que renombrar o retirar conscientemente el sandbox
incompleto y luego ejecutar:

```bash
python3 [RUTA DE LABORATORIO REDACTADA]
```

No usar `--complete-existing` para recuperar secretos/DB: esa opción solo
completa la forma del sandbox existente y no repone esos ficheros.

## Addendum — aceptación de follow-ups de seguridad (2026-10-25)

Este addendum registra aceptación acotada de funciones compartidas y
corroboración directa del hook. No extiende ni reinterpreta la aceptación
histórica del cutover. La cobertura de seguridad utilizó las implementaciones
reales de `open-code/lib/plugin-sync.py` y
`[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/lib/cutover_safety.py` con DB,
archivos y procesos sintéticos; no copias/reimplementaciones del algoritmo.
Las pruebas sensibles quedaron contenidas en namespace PID privado rootless,
con `/proc` privado y watchdog exterior independiente.

| Follow-up | Requisito → resultado | Límite / estado |
|---|---|---|
| **#1 — snapshot/deadline/fusible** | Las funciones reales compartidas se validaron sobre recursos sintéticos. La suite automatizada final registra 52 casos (43 dinámicos, 4 simulaciones, 5 inspecciones), 0 fallos y RC 0; incluye aislamiento de fusible `os._exit(124)`, deadline y snapshots SQLite. | Antes de este lote ya había una prueba puntual dinámica del fusible: RC 124, backend propio terminado y raíz privada eliminada a los 33,420 ms. El aporte de este follow-up fue cobertura automatizada/repetible, no afirmar ausencia total de evidencia dinámica previa. Los interruptores de fallo del harness `FORGE_V2_TEST_NO_PIDFD` y `FORGE_V2_TEST_HANG_SUITE` no se activan en la ejecución verde estándar. |
| **#2 — pidfd/clasificación de holders** | Prueba de las funciones reales compartidas con procesos y ficheros propios: identidad pidfd, rechazo sin señal ante identidad incorrecta, parada acotada, clasificación de DB/WAL/SHM/`-journal`, rutas `deleted` y holders. Se distinguen ejecución dinámica, simulación e inspección. | Las condiciones simuladas de permiso, desaparición y PID reutilizado no son pruebas reales de señales/reutilización del host. No hubo señalización de procesos preexistentes. La aceptación es de funciones, no de entrypoints completos. |
| **#3 — grupos y descendientes** | Riesgo residual **aceptado**. Se conserva `killpg` y el contrato de grupo. `GRP-1` probó dinámicamente el caso concreto en que el líder sale temprano dejando un descendiente propio; el grupo sintético se limpió. | Un pidfd identifica un proceso individual y no mantiene por sí solo el contrato de limpieza de grupos/descendientes. El caso de líder temprano no cubre todas las carreras/estructuras de descendientes; persiste un residuo teórico de reutilización de PID/PGID. Para quitar `killpg` hace falta otro plan (seguimiento de descendientes o contención equivalente), no una sustitución mecánica por pidfd. |
| **#4 — hook de forge-guard** | Se cargó el paquete de producción real y se capturó directamente `execute.before` con contexto simulado. Suite adaptada: 18 PASS / 0 FAIL en cinco ejecuciones; 0 push intentados, 0 commits en ramas protegidas, 3 commits únicamente en `feature`; `origin` vacío se comprobó explícitamente. | «Corroboración directa del hook con contexto simulado; despacho extremo a extremo no probado». No hay sesiones OpenCode reales ni despacho real de una orden de shell. No se alteró la política del guard. |
| **#5 — PID [PID REDACTADO]** | La intervención operacional independiente del Step 4.2 **se llevó a cabo** en solo lectura. La identidad quedó verificada con pidfd abierto, UID 1000, `inicio_ticks=[IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]`, exe `[RUTA DE LABORATORIO REDACTADA]@opencode/cli/bin/opencode.exe (deleted)`, cmdline `opencode serve --hostname 127.0.0.1 --port [IDENTIFICADOR NUMÉRICO LOCAL REDACTADO] --print-logs` y FDs DB/WAL/SHM del laboratorio (todos `(deleted)`); no se observaron descendientes ni TTY y hubo cero conexiones establecidas. | **Resultado terminal: BLOQUEO** porque la residualidad no quedó acreditada: `/proc/<pid>/fd` era inaccesible por EACCES para tres procesos no-zombie de UID 1000: PID [PID REDACTADO] (`systemd --user`, padre del objetivo), 863 (`(sd-pam)`) y 1169 (`fusermount3`). No pudieron descartarse referencias previas. No se envió ninguna señal; PID [PID REDACTADO] sigue vivo e intacto. Evidencia: [`[RUTA DE LABORATORIO REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-intervention.md`]([RUTA DE LABORATORIO REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-intervention.md). Esta intervención no es cobertura sintética, no forma parte del GLOBAL VERIFIER y no se ejecutó desde ninguna herramienta de tests. Se corrige aquí la afirmación anterior de que el lote no inspeccionó procesos preexistentes: sí hubo inspección de solo lectura, sin señales. |

### Interpretación y límites

`safety-results.md` distingue los 43 casos dinámicos (funciones y recursos
sintéticos bajo contención), los 4 casos simulados (condiciones inyectadas,
no una señal real o reutilización de PID) y las 5 inspecciones. La suite no
declara verde una ausencia de contención: la barrera solo autoriza casos
sensibles después de acreditar el namespace/watchdog. Los interruptores
`FORGE_V2_TEST_NO_PIDFD` / `FORGE_V2_TEST_HANG_SUITE` son ejecuciones explícitas
de fallo y no parte de la ruta verde estándar; su resultado no se exagera como
protección automática frente a regresiones sin ejecutar esos casos.

La prueba previa puntual del fusible está en el historial de este informe:
RC 124, backend propio terminado, raíz privada removida y cero procesos con esa
ruta/entorno. Las nuevas pruebas automatizan el escenario y amplían cobertura;
no anulan la evidencia histórica ni atribuyen a la prueba anterior la cobertura
de la suite nueva.

La aceptación de funciones no acredita cutover de extremo a extremo: no se
ejecutaron migración, reset, restauración, `cutover.sh`, `ROLLBACK.sh` ni la
operación completa de sus entrypoints. `dbtool.py` tampoco fue ejecutado. El
hook no se probó mediante sesión real de OpenCode. La intervención PID [PID REDACTADO]
queda fuera de los tests; su comprobación operacional actual se llevó a cabo y
terminó bloqueada por residualidad no acreditada, sin señales y con el proceso
intacto. Véase `[RUTA DE LABORATORIO REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]-intervention.md`.

### Huellas, versiones y rutas

Las versiones de abajo son versiones propias declaradas, cuando existen. Los
targets OpenCode (2.1.4, o referencias históricas a 1.19.4) no son versiones de
scripts o bibliotecas. Las huellas finales de los seis externos se calculan
después de cerrar estas notas y este informe y se enumeran en
`[RUTA DE LABORATORIO REDACTADA]`; ese manifiesto
externo es la referencia y no incluye su propia huella.

| Componente | Versión declarada | SHA-256 inicial → final |
|---|---|---|
| `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/cutover.sh` | No declarada (target OpenCode 2.1.4) | `6b1e7d6ee464d122e3d9380080fc474ad383e46a253a2e0aebfb927400e1f681` → `824897d990db781199c5bad26c186b7a2665c9ad167ef9482a44946780a5b613` |
| `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/ROLLBACK.sh` | No declarada | `691829305d19a4988ff8a0d02ffcb9705900745ab20c68b01b5d5d0ed2e5075d` → `f91e7787ce7690fc0d5ec70aaafa5c051acb3b379006214c0e870e84474f8f85` |
| `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/CUTOVER-NOTES.md` | No declarada | `a2d44ecea943c463e3e8ee06451d18c62e44281b76c650b76c075e88e83f5574` → manifiesto externo final |
| `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/lib/dbtool.py` | No declarada | `d15cc6aea6289683b9df7add7fcb82f27ba3eaddcb8368a563f1be8a98ab0db0` → sin cambios |
| Este informe, `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/REMEDIATION-REPORT.md` | No declarada | `db2db86220741ff347342554bcff859e3e2031d6bf717bba9b354b99baccca65` → manifiesto externo final |
| Nueva biblioteca `[RUTA PERSONAL REDACTADA][IDENTIFICADOR NUMÉRICO LOCAL REDACTADO]/lib/cutover_safety.py` | No declarada | ausente → `1e93447968a4f3ddb4395022260c89d643aa696c95edd003f853e79db4378454` |
| Repo `open-code/lib/plugin-sync.py` | No declarada (V2-only no es una versión semántica) | `70966cf5fac50faea615d882ff2c2e326729b5df883fe14507a84c72af415e9e` → `7760fd6a143fa906d6bf5b85df1ea8715cf8d04de83be440cea75e04e4cac8b5` |
| Repo `tests/forge_guard_plugin_unit.sh` | No declarada | `a60d8c2d6ff1b75e5fd26b8139b0abb405c77125f3ecf3d2a9c5bc1b9a8e86d4` → `72481782f412a77afe4eb091342bcfa7ba0254e9bc2cd1b57ea09a1e7379f3d8` |
| Nuevos `tests/forge_v2_safety.sh`, `tests/forge_v2_safety_harness.py` | No declarada | ausentes → `cbbbe39953c1af23935f6315a3a75908b6f24e28fc4d060739163afb3a2da4b9`, `862aee41ec88e5be92203d0bfdcd1a11a8e3aa66e2c90eef98215c4a988e5d92` |
| `open-code/plugin-packages/forge-guard/{package.json,index.js}` | `forge-guard` 1.0.0 | `package.json` `1a19e5f2dbf7c4580aaa3c128b347e314a9e0002d9a28e2236b32823b5ff0220`; `index.js` `e1d2eb0dad24c0d0f8660f0e7d58297de67a9a23d341cc47be2ea3a83e5c007a` (sin cambios) |

El resumen integral, con correspondencia requisito→resultado→límite y
referencias a las evidencias, está en
`[RUTA DE LABORATORIO REDACTADA]`. Las huellas finales externas
se verifican con `sha256sum -c` desde la raíz externa; no se copian al cuerpo
del documento como si este pudiera verificar su propio hash.
