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

Los límites de las rutas esperadas son aproximadamente 99 s para `normal`, 0 s
para el rechazo inmediato `no-pidfd` y 21 s para `no-pidfd-hang` (timeout de
20 s más detección). Su suma es 120 s; con hasta 50 s reservados para la cadena
de limpieza y 60 s de preparación, el presupuesto de una ejecución normal es
230 s. Para preservar también el guard de escenario ya existente (420 s) y sus
esperas de limpieza (20 s de gracia y hasta dos esperas de 15 s), el peor caso
secuencial con un guard vencido queda acotado conservadoramente por
`99 + 0 + 420 + 50 + 60 = 629 s`. El timeout operativo se redondea hacia arriba
a **11 minutos (660 s)**. No se reducen los plazos originales ni se añaden
reintentos; un guard vencido sigue siendo fallo, incluso si su limpieza quedó
acreditada.

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

El workflow se ejecutó tres veces como intentos independientes del run
`40399577224`, siempre sobre el SHA
`2c9af458045387080d192f21a24ba36ecac1af7f`, con conclusión global `success`.
Los jobs `v2-safety` y `test` finalizaron correctamente en cada intento; el
timeout configurado para `v2-safety` es 660 s (11 min).

| Intento | `v2-safety` | `test` | margen real del job de 660 s | tiempos de escenarios (`normal` / `no-pidfd` / `no-pidfd-hang`) |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 140 s | 129 s | 520 s | 112 / 0 / 21 s |
| 2 | 145 s | 119 s | 515 s | 113 / 0 / 20 s |
| 3 | 140 s | 109 s | 520 s | 113 / 0 / 20 s |

En los tres intentos, los logs registran los contratos internos esperados y RC
del ejecutor 0: `normal` supervisor/suite `0/0` con autorización concedida;
`no-pidfd` `6/4` con autorización denegada; `no-pidfd-hang` `6/-9` con timeout
real. Los resúmenes de cada escenario acreditan init de namespace eliminado,
ningún superviviente en el namespace, ningún miembro del grupo propio y raíz
sintética eliminada. En el intento 3, el artefacto acredita además el preflight
funcional con 8/8 checks, incluyendo namespace PID privado, `/proc` privado y
señal pidfd funcional sobre un hijo propio, recogido con RC `-9` tras escalada.
Los escenarios solo aparecen después de superar el preflight estricto; para los
intentos 1 y 2 se conservan los logs de job, no el JSON por check del preflight.

GitHub eliminó los artefactos de los intentos 1 y 2 al re-ejecutar el run. Los
logs aún conservan sus resúmenes JSON por escenario, pero los artefactos
primarios recuperables (`preflight.json`, `job-summary.json`,
`scenario-results.json`, veredictos y `supervisor.stdout.tsv`) corresponden al
intento 3. La matriz consolidada, sus fuentes por intento y esta limitación
están en `/tmp/opencode/v2-safety-ci-runner-provenance/hosted-40399577224-20261026-2c9af45/hosted-matrix.md`.

También se verificó el rechazo negativo del preflight existente en un proceso
desechable con seccomp: un filtro heredado solo por ese proceso y sus
descendientes denegó `unshare` con `EPERM`. Sin `sudo` ni cambios globales, el
entrypoint terminó con RC 2; `preflight.json` registró RC 1 y la causa
`unshare: ... Operación no permitida`. No se lanzó la sonda y no quedaron
procesos hijos en la sesión restringida. La implementación del filtro y sus
evidencias están bajo
`/tmp/opencode/v2-safety-ci-runner-provenance/hosted-40399577224-20261026-2c9af45/preflight-negative-seccomp/`.

La suite local heredada se ejecutó con el override documentado
`FORGE_TEST_REAL_OPENCODE_BIN` apuntando al binario local real `opencode v2.1.4`:
`bash tests/run-all.sh` terminó RC 0, con 28/28 suites aprobadas en 109 s. La
salida de los 28 resúmenes de suite suma 1100 checks/aserciones aprobadas y 0
fallidas (sin contar el footer global, que cuenta suites). La integración de
runtime real usa un sandbox y declara explícitamente que no contacta
proveedores. El ShellCheck global heredado mantuvo
`--severity=warning` y terminó RC 0, sin salida.

El workflow declara `release.needs: [test, v2-safety]`; la protección de merge
separada aún requiere que el administrador registre `v2-safety` como check
obligatorio. Esa política administrativa no se considera activa por esta
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
