# Componente Forge V2 cutover — fuente canónica

La ruta canónica versionada es `tools/cutover/forge-v2/` dentro de este
checkout. Todo consumidor del repositorio debe resolver los ficheros desde el
checkout, nunca desde una ruta de laboratorio o una instalación local.

El directorio externo
`/home/espinilleitor/forge-v2-cutover-20261024/` queda como **respaldo
histórico congelado**: no se actualizará desde allí ni se considera una fuente
activa. `reports/` y `sandbox/` de ese respaldo no forman parte de esta
distribución y no se importaron. La única fuente activa declarada es la copia
versionada en este repositorio.

## Inventario

- `cutover.sh` — entrypoint de cutover; copia derivada del original externo,
  con cambios documentados; no es byte-idéntica.
- `ROLLBACK.sh` — entrypoint de reversión; conservado byte a byte del original.
- `lib/cutover_safety.py` — primitivas de seguridad compartidas; conservado
  byte a byte del original.
- `lib/dbtool.py` — herramienta SQLite del cutover; conservada byte a byte del
  original.
- `CUTOVER-NOTES.md` — notas históricas con redacciones y advertencia de no
  ejecución.
- `REMEDIATION-REPORT.md` — informe histórico con redacciones y advertencia de
  no ejecución.
- `README.md` — este índice y contrato de uso del componente versionado.

El hash del original externo y el de la copia derivada de `cutover.sh`, así como
los hashes conservados de los otros tres ficheros de implementación, se
registran abajo y en `/tmp/opencode/v2-safety-ci-runner-provenance/`.

## Límites y seguridad

Este directorio preserva un artefacto histórico; no constituye soporte ni
autorización para operar sobre una instalación personal, sus bases de datos,
respaldos, credenciales, configuración o procesos. Los scripts mantienen su
comportamiento y valores predeterminados originales, incluidos destinos bajo
`HOME` y una ubicación predeterminada de respaldo, que pueden ser operacionales
y destructivos.

**No ejecutar `cutover.sh`, `ROLLBACK.sh` ni `lib/dbtool.py` como verificación.**
No hacerles `source`, importarlos, ejecutarlos desde pruebas, ni conectarlos a
recursos instalados. Su presencia versionada no autoriza ejecución automática.
Las comprobaciones estáticas permitidas para esta importación son `bash -n`
para los dos shell y `ast.parse` sobre el texto de los dos Python, sin
importarlos ni generar bytecode. Los informes históricos son contexto, no
runbooks activos; contienen una advertencia explícita de no ejecución.

No se añadieron estos ficheros a suites de integración, a
`tests/run-all.sh` ni a `tools/verification/`. Cualquier bench consumidor debe
resolver las primitivas permitidas desde este checkout y respetar sus propios
límites de seguridad.

## Job bloqueante `v2-safety`

El nombre estable del check requerido es **`v2-safety`**. Es una puerta
bloqueante del workflow: `release` solo puede continuar cuando tanto `test`
como `v2-safety` terminan correctamente. Para bloquear también los merges, la
protección de la rama debe registrar `v2-safety` como check requerido; este
cambio no modifica ni presupone activa esa política.

Desde la raíz de un checkout, la invocación completa y reproducible es:

```bash
bash tools/ci/v2-safety.sh --all --artifacts-dir "$RUNNER_TEMP/v2-safety-evidence"
```

Para acreditar capacidades sin lanzar los escenarios:

```bash
bash tools/ci/v2-safety.sh --preflight-only --artifacts-dir RUTA_NUEVA
```

La ruta de artefactos debe ser nueva; un directorio existente se rechaza sin
sobrescribirlo. Las rutas relativas se resuelven desde la raíz del checkout,
obtenida desde la ubicación del entrypoint. El entrypoint invoca
explícitamente una vez cada escenario, en orden (`normal`, `no-pidfd`,
`no-pidfd-hang`), mediante la interfaz existente
`tests/forge_v2_safety_scenarios.sh`; el componente se pasa desde
`tools/cutover/forge-v2/`. No depende del descubrimiento de `tests/run-all.sh`
ni requiere la copia externa congelada.

El preflight realiza la operación real
`unshare --user --map-root-user --pid --fork --mount-proc`, verifica que los
namespaces PID, user y mount sean privados, que `/proc` esté montado y muestre
el PID 1 del namespace, y que el Python seleccionado pueda abrir un pidfd,
enviar `SIGTERM` a un hijo propio por ese descriptor y esperar hasta un segundo.
Si el hijo sigue vivo, escala a `SIGKILL` por el mismo pidfd, con espera acotada,
y recoge al hijo. El check funcional exige que la terminación haya sido por una
señal (`return_code < 0`) enviada por pidfd y que el hijo esté recogido; el
informe registra señales intentadas, señal que terminó al hijo y su RC real.
Una falta de capacidad o permiso falla con causa en `preflight.json` y en los
logs; no hay fallback que omita aislamiento o permita un resultado verde,
`sudo`, relajación global ni skip. La limpieza conservadora no convierte un
fallo de la operación pidfd en éxito. La evidencia incluye versiones, SHA del
checkout, estado funcional, RC y tiempos; cada escenario tiene su propio
directorio con resultado semántico y verificación de teardown. El resumen está
en `job-summary.json` y los resultados agregados en `scenario-results.json`.
Si `unshare` no está disponible, el entrypoint crea igualmente ambos archivos
de salida del preflight y emite `preflight.json` estructurado con `ok: false`,
RC 127 y una causa explícita que indica que no se encontró `unshare`; no se
lanza la sonda ni se intenta degradar el aislamiento.

### Observación de la sonda pidfd en kernels distintos (2026-10-26)

En el run hospedado `40395931248` sobre `ubuntu-22.04`, todos los checks
anteriores al wait funcional pasaron, incluido `pidfd_child_is_own_live_child`
para el PID 2 del namespace. La espera de cinco segundos tras enviar
`SIGTERM` por pidfd expiró; la limpieza existente envió `SIGKILL` por el mismo
handle y recogió al hijo con `return_code=-9`. En una ejecución local anterior,
la misma sonda terminó con `return_code=-15` tras `SIGTERM`. La diferencia
observada justifica el margen corto seguido de escalada descrito arriba; no
debilita el requisito de señal real por pidfd, terminación y recogida.

La sonda es PID 1 de su namespace PID. Se consideró la semántica especial de
señales de un init de namespace como posible explicación, pero no se verificó
que sea la causa del resultado distinto entre esos kernels; por tanto, el
informe registra la diferencia observada (`-15` local frente a `-9` hospedado)
y no afirma un mecanismo causal específico.

### Presupuesto del job

El presupuesto cubre los límites efectivos, no solo los tiempos observados o
los caminos esperados. En `normal`, el supervisor conserva su timeout interno
de 300 s y el escenario su guard exterior de 420 s para toda la ejecución; si
vence el guard, la limpieza puede consumir hasta 50 s (20 s de gracia, espera
de 15 s y recuperación final de hasta 15 s). El límite efectivo es, por tanto,
`420 + 50 = 470 s`: los 300 s internos están dentro del guard y no se suman de
nuevo. `no-pidfd` espera rechazar inmediatamente (0 s), pero si falla su
contrato también queda limitado por el guard de 420 s y los mismos 50 s de
limpieza: 470 s. `no-pidfd-hang` espera timeout de 20 s más hasta 1 s de
detección (21 s), pero su límite de fallo efectivo también es 420 + 50 = 470 s.

La política de secuencia es continuar después de un fallo contractual solo si
el teardown y su evidencia están completos; ante teardown incompleto o no
acreditado se detiene la secuencia. Así que el peor caso alcanzable incluye los
tres escenarios: `470 + 470 + 470 = 1410 s`. Se añaden 60 s de preparación y
preflight, 60 s para agregación/cierre de evidencias y 300 s para publicar el
artefacto: `1410 + 60 + 60 + 300 = 1830 s`. El job `v2-safety` tiene un timeout
de **35 minutos (2100 s)**, con 270 s de margen adicional y cobertura también
para la publicación posterior al paso. El cálculo del entrypoint y esta sección
coinciden con el `timeout-minutes: 35` del workflow. No se reducen los plazos
originales ni se añaden reintentos; un guard vencido sigue siendo fallo, incluso
si su limpieza quedó acreditada.

### Códigos de salida de los escenarios

El runner existente devuelve cero únicamente si el escenario y su evidencia
cumplen su contrato. Los RC internos que deben quedar acreditados son:

| Escenario | Supervisor | Suite | Resultado esperado |
| --- | ---: | ---: | --- |
| `normal` | 0 | 0 | Autorización concedida, sin timeout |
| `no-pidfd` | 6 | 4 | Watchdog no operativo, autorización denegada, sin timeout |
| `no-pidfd-hang` | 6 | -9 | Timeout real y suite terminada por la limpieza |

El caso `DEAD-6` conserva `os._exit(124)` dentro de su hijo aislado. El
entrypoint comprueba los RC y la evidencia de autorización, timeout, limpieza,
ausencia de supervivientes y eliminación de la raíz sintética; un RC no cero,
evidencia incompleta o teardown no acreditado hace fallar el job.

### Acreditación hospedada y preflight negativo (2026-10-26)

La acreditación hospedada consta de cuatro ejecuciones independientes, cada una
con run ID y artefacto propio no expirado. En todas, `test` y `v2-safety`
concluyeron `success` (RC 0); en esas ejecuciones el timeout configurado era
660 s (11 min), valor histórico sustituido por el presupuesto actualizado de
35 minutos detallado en «Presupuesto del job».

| Run | Evento / SHA de cabecera | `v2-safety` | Margen frente a 660 s | Tiempos de escenarios (`normal` / `no-pidfd` / `no-pidfd-hang`) |
| ---: | --- | ---: | ---: | ---: |
| `40399577224` | push / `2c9af458` | 140 s | 520 s | 113 / 0 / 20 s |
| `40403682427` | push / `c86b915` | 140 s | 520 s | 112 / 0 / 21 s |
| `40404048071` | push / `848ba08` | 139 s | 521 s | 112 / 0 / 21 s |
| `40404257145` | pull_request #54 / `848ba08` | 139 s | 521 s | 112 / 0 / 21 s |

El run de pull request evaluó el merge ref sintético
`2add2c018b7013fad5172a0c7ef1f1872fb329cd`; el SHA de cabecera de la PR es
`848ba08b1dcd7ecccd7839039b7854d33001dd99`. Los cuatro artefactos contienen
`preflight.json`, `job-summary.json`, `scenario-results.json`, los tres
`verdict.json`, los tres `supervisor.stdout.tsv` y `timeout-calculation.txt`.
La matriz de aislamiento, estabilidad y puerta efectiva, con las fuentes de
cada celda y los metadatos/logs de las ejecuciones, está en
`/tmp/opencode/v2-safety-ci-runner-provenance/hosted-four-runs-20261026-848ba08/hosted-matrix.md`.

En los cuatro runs, el preflight funcional obtuvo 8/8 checks correctos,
incluidos namespace PID y `/proc` privados y una señal pidfd observada sobre un
hijo propio; `SIGTERM` escaló a `SIGKILL`, el hijo terminó con RC `-9` y fue
recogido. Los contratos fueron `normal` supervisor/suite `0/0` con autorización
concedida, `no-pidfd` `6/4` con denegación y `no-pidfd-hang` `6/-9` con timeout
real; cada RC del ejecutor fue 0. El teardown confirmó init eliminado, cero
supervivientes en el namespace y en el grupo propio, raíz sintética eliminada y
recursos propios ausentes o recogidos. En el caso `normal`, `DEAD-6` acredita
`os._exit(124)` dentro del hijo aislado.

También se verificó el rechazo negativo del preflight existente en un proceso
desechable con seccomp: un filtro heredado solo por ese proceso y sus
descendientes denegó `unshare` con `EPERM`. Sin `sudo` ni cambios globales, el
entrypoint terminó con RC 2; `preflight.json` registró RC 1 y la causa
`unshare: ... Operación no permitida`. No se lanzó la sonda y no quedaron
procesos hijos en la sesión restringida. La implementación del filtro y sus
evidencias están bajo
`/tmp/opencode/v2-safety-ci-runner-provenance/hosted-four-runs-20261026-848ba08/local-verifications/preflight-negative-seccomp/`.

La suite local se ejecutó con
`FORGE_TEST_REAL_OPENCODE_BIN=/home/espinilleitor/.local/share/forge/opencode-v2/node_modules/.bin/opencode`:
`bash tests/run-all.sh` terminó RC 0, con 28/28 suites y 1100 checks/aserciones
aprobados, 0 fallidos (106 s). El override usa el runtime real local y la suite
no contacta proveedores. La invocación global literal de ShellCheck,
`find . -name "*.sh" -not -path "./.git/*" | xargs shellcheck --severity=warning`,
terminó RC 0, sin salida.

El workflow declara `release.needs: [test, v2-safety]` y no tiene una condición
que salte esa dependencia; los cuatro jobs `release` quedaron `skipped` por
evento/rama, sin publicación. Separadamente, la protección de merge de `master`
exige actualmente solo `test`; queda pendiente que el administrador registre
`v2-safety` como check requerido. Esa acción no se considera activa por esta
acreditación.

## Procedencia de `cutover.sh` — excepción autorizada (2026-10-26)

La copia versionada `tools/cutover/forge-v2/cutover.sh` es una **copia derivada
con cambios documentados, no byte-idéntica**. El usuario autorizó esta excepción
el 2026-10-26 para retirar cinco variables sin lecturas que impedían pasar la
puerta global existente de ShellCheck (`--severity=warning`). Se retiraron solo
sus declaraciones y escrituras; no se cambió otra lógica.

| Artefacto | SHA-256 | Estado |
|---|---|---|
| Original externo `/home/espinilleitor/forge-v2-cutover-20261024/cutover.sh` | `824897d990db781199c5bad26c186b7a2665c9ad167ef9482a44946780a5b613` | Original sin modificar |
| Copia versionada derivada `tools/cutover/forge-v2/cutover.sh` | `d5249b6d406823c90314aad9599ec444afac0de7077a2f91367be678ca9f11b4` | Derivada; divergencia exacta abajo |
| `tools/cutover/forge-v2/ROLLBACK.sh` | `f91e7787ce7690fc0d5ec70aaafa5c051acb3b379006214c0e870e84474f8f85` | Byte-idéntico al original |
| `tools/cutover/forge-v2/lib/cutover_safety.py` | `1e93447968a4f3ddb4395022260c89d643aa696c95edd003f853e79db4378454` | Byte-idéntico al original |
| `tools/cutover/forge-v2/lib/dbtool.py` | `d15cc6aea6289683b9df7add7fcb82f27ba3eaddcb8368a563f1be8a98ab0db0` | Byte-idéntico al original |

El original externo no se modificó. El diff unificado completo, también
conservado como `cutover-derived.diff` en el directorio de evidencia indicado,
es:

```diff
--- bad47dd4:tools/cutover/forge-v2/cutover.sh
+++ derived:tools/cutover/forge-v2/cutover.sh
@@ -98,7 +98,6 @@
 PROC_INVENTORY_COMPLETE=1
 PROC_INVENTORY_ERRORS_FILE="$WORKDIR/proc-inventory-errors.txt"
 PROC_SCAN_SEQUENCE=0
-PROC_SCAN_DIR=""
 PROC_DB_HOLDERS_FILE=""
 PROC_DB_BLOCKERS_FILE=""
 PROC_OPENCODE_PROCESSES_FILE=""
@@ -106,12 +105,8 @@
 SERVE_PID=""
 SERVE_START_TICKS=""
 SERVE_LAUNCH_EXE_ORIGINAL=""
-SERVE_LAUNCH_EXE_NORMALIZED=""
-SERVE_LAUNCH_EXE_DEV_INODE=""
 SERVE_EXE_NORMALIZED=""
 SERVE_EXE_DEV_INODE=""
-SERVE_EXPECTED_EXE=""
-SERVE_EXPECTED_DEV_INODE=""
 SERVE_REG_VALID=0
 SERVER_STOP_DONE=0
 SERVER_STOP_STATUS=0
@@ -277,7 +272,6 @@
   tag="${tag//[^A-Za-z0-9_.-]/_}"
   scan_dir="$WORKDIR/proc-inventory-${PROC_SCAN_SEQUENCE}-${tag}"
   mkdir -m 700 -- "$scan_dir" || return 2
-  PROC_SCAN_DIR="$scan_dir"
   PROC_INVENTORY_ERRORS_FILE="$scan_dir/inventory-errors.txt"
   PROC_DB_HOLDERS_FILE="$scan_dir/db-holders.txt"
   PROC_DB_BLOCKERS_FILE="$scan_dir/db-blockers.txt"
@@ -375,10 +369,6 @@
   fi
   SERVE_START_TICKS="$(json_get "$state_file" "d['start_ticks']")"
   SERVE_LAUNCH_EXE_ORIGINAL="$(json_get "$state_file" "d['launch_exe_original']")"
-  SERVE_LAUNCH_EXE_NORMALIZED="$(json_get "$state_file" "d['launch_exe_normalized']")"
-  SERVE_LAUNCH_EXE_DEV_INODE="$(json_get "$state_file" "d['launch_exe_dev_inode']")"
-  SERVE_EXPECTED_EXE="$(json_get "$state_file" "d['expected_exe']")"
-  SERVE_EXPECTED_DEV_INODE="$(json_get "$state_file" "d['expected_dev_inode']")"
   SERVE_EXE_NORMALIZED="$(json_get "$state_file" "d['exe_normalized']")"
   SERVE_EXE_DEV_INODE="$(json_get "$state_file" "d['exe_dev_inode']")"
   parent="$(json_get "$state_file" "d['parent']")"
```

| Variable | Declaración original | Escritura original | Eliminación y ubicación en el diff | Resultado en la copia derivada |
|---|---|---|---|---|
| `PROC_SCAN_DIR` | L101: `PROC_SCAN_DIR=""` | L280: `  PROC_SCAN_DIR="$scan_dir"` | Declaración: `@@ -98,7 +98,6 @@`; escritura: `@@ -277,7 +272,6 @@` | Ambas ausentes; no se añadió asignación sustituta |
| `SERVE_LAUNCH_EXE_NORMALIZED` | L109: `SERVE_LAUNCH_EXE_NORMALIZED=""` | L378: `  SERVE_LAUNCH_EXE_NORMALIZED="$(json_get "$state_file" "d['launch_exe_normalized']")"` | Declaración: `@@ -106,12 +105,8 @@`; escritura: `@@ -375,10 +369,6 @@` | Ambas ausentes; no se añadió asignación sustituta |
| `SERVE_LAUNCH_EXE_DEV_INODE` | L110: `SERVE_LAUNCH_EXE_DEV_INODE=""` | L379: `  SERVE_LAUNCH_EXE_DEV_INODE="$(json_get "$state_file" "d['launch_exe_dev_inode']")"` | Declaración: `@@ -106,12 +105,8 @@`; escritura: `@@ -375,10 +369,6 @@` | Ambas ausentes; no se añadió asignación sustituta |
| `SERVE_EXPECTED_EXE` | L113: `SERVE_EXPECTED_EXE=""` | L380: `  SERVE_EXPECTED_EXE="$(json_get "$state_file" "d['expected_exe']")"` | Declaración: `@@ -106,12 +105,8 @@`; escritura: `@@ -375,10 +369,6 @@` | Ambas ausentes; no se añadió asignación sustituta |
| `SERVE_EXPECTED_DEV_INODE` | L114: `SERVE_EXPECTED_DEV_INODE=""` | L381: `  SERVE_EXPECTED_DEV_INODE="$(json_get "$state_file" "d['expected_dev_inode']")"` | Declaración: `@@ -106,12 +105,8 @@`; escritura: `@@ -375,10 +369,6 @@` | Ambas ausentes; no se añadió asignación sustituta |

La comprobación estática antes de editar encontró solo esas diez apariciones,
todas declaraciones o escrituras, sin usos directos ni indirectos por
`eval`/`export`/`set` ni en subshells. `PROC_SCAN_DIR` se escribía desde
`scan_dir`, una asignación simple basada en `WORKDIR` y contadores. Las cuatro
escrituras restantes invocaban `json_get`, cuya implementación solo abre el
JSON de estado para lectura y evalúa expresiones de búsqueda constantes para
imprimir campos; no muta archivos ni recursos. Se eliminaron las escrituras y
las inicializaciones muertas. El motivo es adaptar código muerto que también
estaba en el original a la puerta global de ShellCheck; no se añadieron
exclusiones ni supresiones y se mantuvo `--severity=warning`.
