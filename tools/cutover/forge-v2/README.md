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
- `FOLLOWUPS.md` — referencia operacional única para los cierres documentales
  de los follow-ups 2 (SQLite) y 4 (PID histórico); no autoriza intervenciones.
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

## Job `v2-safety`: puerta de `release`, no puerta de merge

El nombre estable del check del workflow es **`v2-safety`**. En el workflow
versionado, `release` declara `needs: [test, v2-safety]` sin una condición que
omita esa dependencia: si el banco falla, `release` no continúa. Esta
dependencia interna del workflow no configura la protección de ramas. Un banco
verde no significa que `v2-safety` sea un check requerido para fusionar PR.

### Alcance y límites del banco

El banco busca incoherencias internas: contrasta el inventario y recuento de
casos con los escenarios y contratos del runner; re-deriva los códigos de
salida a partir de los resultados y su evidencia; y comprueba el teardown y la
ausencia de supervivientes mediante la observación de `/proc`. También verifica
la procedencia y unicidad del componente que consume desde la ruta versionada
canónica, y que la ejecución se haga dentro de la contención acreditada.

Estos controles no detectan una modificación coordinada del producto y de sus
expectativas: producto y banco viven en el mismo repositorio, por lo que un
cambio consistente en ambos es indistinguible para el banco de un cambio real
del producto. No se promete validación externa, un pin independiente de hashes
ni un meta-test general que valide el propio banco. Los hashes documentales que
aparecen más abajo no constituyen ese pin ni una validación independiente de
cada ejecución.

La [síntesis normativa versionada del contrato de contención](../../verification/V2-CONTAINMENT-CONTRACT.md)
recoge la afirmación defendible, las afirmaciones retiradas, el alcance de esta
puerta y el requisito adversarial aún no satisfecho.

### Protección de ramas: acción del administrador pendiente

La lectura del estado de protección disponible registra que el único contexto
required observado es `test`; `v2-safety` **no** es required,
`enforce_admins=false`, `allow_force_pushes=true` y no hay rulesets. Por esas
excepciones, ni siquiera el required `test` es una puerta dura. Así, `v2-safety`
bloquea el job `release` por su dependencia `needs`, pero no bloquea los merges.

**Acción pendiente del usuario administrador:** hacer que `v2-safety` sea
required y revisar las excepciones actuales de protección de ramas:
`enforce_admins=false`, `allow_force_pushes=true`, sin rulesets. El único
contexto required observado es `test`; incluso esa puerta no es dura bajo esas
excepciones. No se ha ejecutado ningún cambio administrativo ni se marca esta
acción como realizada.

El workflow ejecuta el banco a través de
`tools/verification/forge-contained-run.sh`, que acredita la contención antes
de invocar `tools/ci/v2-safety.sh`. Las órdenes siguientes son la invocación
interior del banco, no una vía de ejecución independiente: el banco rechaza
arrancar fuera de una contención acreditada.

```bash
bash tools/ci/v2-safety.sh --all --artifacts-dir "$RUNNER_TEMP/v2-safety-evidence"
```

Para acreditar capacidades sin lanzar los escenarios, usa `--preflight-only`
dentro de la misma contención:

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
de 15 s y recuperación final de hasta 15 s). El límite del wrapper es, por
tanto, `420 + 50 = 470 s`: los 300 s internos están dentro del guard y no se
suman de nuevo. `no-pidfd` espera rechazar inmediatamente (0 s), pero si falla
su contrato también queda limitado por el guard de 420 s y los mismos 50 s de
limpieza: 470 s. `no-pidfd-hang` espera timeout de 20 s más hasta 1 s de
detección (21 s), pero su límite de fallo del wrapper también es `420 + 50 =
470 s`.

Después de volver del wrapper, la interfaz de escenarios comprueba cada segundo
si queda algún proceso propio cuyo cmdline contiene `--report-path $REPORT`.
Esta espera adicional está limitada por el mismo `SCENARIO_GUARD` de 420 s; si
un proceso sigue vivo al agotarlo, el escenario falla con RC 14. Por ello el
límite efectivo por escenario es `470 + 420 = 890 s`, no 470 s. La política
existente continúa tras un fallo contractual solo si el teardown y su evidencia
están completos; ante teardown incompleto o no acreditado se detiene la
secuencia. Si un proceso sigue vivo al agotar los 420 s, el escenario falla con
RC 14 antes de completar esa evidencia y el loop se detiene; si el teardown
queda acreditado, la secuencia puede continuar. Para cubrir ambos caminos sin
reducir los límites individuales, el presupuesto secuencial suma los tres
límites efectivos: `890 + 890 + 890 = 2670 s`.

El workflow reserva hasta **3240 s para la fase de escenarios**, incluidos
preflight, agregación y los controles auxiliares adicionales de
procedencia/unicidad (INSP-6/7/8); estos controles no alteran el recuento de
casos principal ni se añaden fuera de ese límite. Se añaden 60 s de gracia para
cierre exterior: `3240 + 60 = 3300 s` (**55 minutos**). El job `v2-safety` tiene
un timeout de **75 minutos (4500 s)**, como declara `timeout-minutes: 75` en el
workflow; los **1200 s (20 minutos)** restantes son margen para
checkout/preparación, finalización del recibo, clasificación y publicación del
artefacto, incluida la carga siempre ejecutada. No se reducen los plazos
individuales ni se añaden reintentos; un guard vencido sigue siendo fallo,
incluso si su limpieza quedó acreditada.

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

#### Runs de contenidos anteriores (contexto histórico; no acreditan `e31ded6`)

Los siguientes runs son de contenidos anteriores y conservan los presupuestos
vigentes en el momento de cada ejecución. No se mezclan con las tres ejecuciones
del contenido final descritas más abajo.

| Run | Evento / SHA de cabecera | Timeout entonces | `v2-safety` | Margen frente al timeout histórico (660 s) | Tiempos de escenarios (`normal` / `no-pidfd` / `no-pidfd-hang`) |
| ---: | --- | ---: | ---: | ---: | ---: |
| `40399577224` | push / `2c9af458` | 660 s (11 min) | 140 s | 520 s | 113 / 0 / 20 s |
| `40403682427` | push / `c86b915` | 660 s (11 min) | 140 s | 520 s | 112 / 0 / 21 s |
| `40404048071` | push / `848ba08` | 660 s (11 min) | 139 s | 521 s | 112 / 0 / 21 s |
| `40404257145` | pull_request #54 / `848ba08` | 660 s (11 min) | 139 s | 521 s | 112 / 0 / 21 s |

Los runs `40409247443` (push) y `40409253630` (pull_request) pertenecen a otro
contenido anterior, SHA de cabecera
`41f6593f036436c9542f3db00127a83180d76443`, y se ejecutaron con timeout de
2100 s (35 min). El job de GitHub duró 139 s en ambos; el entrypoint registró
134 s y 133 s. Su margen medido frente al presupuesto calculado entonces
(3090 s, cálculo histórico ya sustituido) fue 2951 s; no se presentan como
ejecuciones del timeout actual.

| Run | Evento / SHA de cabecera | Timeout entonces | `v2-safety` job / entrypoint | Margen frente al timeout de ese run | Margen frente al presupuesto histórico entonces (3090 s) | Escenarios (s) |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| `40409247443` | push / `41f6593` | 2100 s (35 min) | 139 / 134 s | 1961 s | 2951 s | 112 / 1 / 20 |
| `40409253630` | pull_request / `41f6593` | 2100 s (35 min) | 139 / 133 s | 1961 s | 2951 s | 112 / 0 / 20 |

En estas tandas anteriores, los preflights obtuvieron 8/8 checks; los contratos
fueron `normal` supervisor/suite `0/0`, `no-pidfd` `6/4` y `no-pidfd-hang`
`6/-9`, con ejecutores públicos en RC 0. Los verdicts acreditan teardown y
ausencia de supervivientes. Las matrices históricas con fuentes se conservan en
`/tmp/opencode/v2-safety-ci-runner-provenance/hosted-four-runs-20261026-848ba08/hosted-matrix.md`
y
`/tmp/opencode/v2-safety-ci-runner-provenance/hosted-40399577224-20261026-2c9af45/hosted-matrix.md`.

El preflight negativo previo se ejecutó en un proceso desechable con seccomp:
un filtro heredado solo por ese proceso y sus descendientes denegó `unshare`
con `EPERM`. Sin `sudo` ni cambios globales, el entrypoint terminó con RC 2,
`preflight.json` registró RC 1 y la causa `unshare: ... Operación no permitida`;
no se lanzó la sonda ni quedaron hijos en la sesión restringida. Evidencia:
`/tmp/opencode/v2-safety-ci-runner-provenance/hosted-four-runs-20261026-848ba08/local-verifications/preflight-negative-seccomp/`.

La suite local previa se ejecutó con
`FORGE_TEST_REAL_OPENCODE_BIN=/home/espinilleitor/.local/share/forge/opencode-v2/node_modules/.bin/opencode`:
`bash tests/run-all.sh` terminó RC 0, con 28/28 suites y 1100 checks/aserciones
aprobados, 0 fallidos. La invocación global literal de ShellCheck,
`find . -name "*.sh" -not -path "./.git/*" | xargs shellcheck --severity=warning`,
terminó RC 0, sin salida.

#### Tres ejecuciones del contenido final `e31ded6` (presupuesto vigente)

Los tres runs independientes tienen SHA de cabecera
`e31ded635e8968c01a671837d0cbcabec85540e9`, y tanto `test` como `v2-safety`
terminaron `success` (RC 0). En esa revisión histórica, el timeout configurado
en los tres era **55 min (3300 s)** y el presupuesto calculado entonces era
**3090 s**; esos valores no son el presupuesto actual del workflow. En los runs de PR,
GitHub evaluó el merge ref sintético `a3c436cf2f28f0fd49d8406899d3663d2a42ce18`
registrado por el artefacto, manteniendo `e31ded6` como SHA de cabecera.

| Run | Evento / SHA de cabecera (checkout ejecutado) | Jobs `test` / `v2-safety` | Job GitHub / entrypoint | Margen frente al presupuesto histórico entonces (3090 s) | Escenarios (`normal` / `no-pidfd` / `no-pidfd-hang`) | Artefacto vivo |
| ---: | --- | --- | ---: | ---: | ---: | --- |
| [`40411954977`](https://github.com/AlbertoChecaMuelas/forge/actions/runs/40411954977) | push / `e31ded6` (`e31ded6`) | success / success | 142 / 135 s | 2948 s | 112 / 1 / 20 s | `12693193733`, `v2-safety-evidence-40411954977-1` |
| [`40411962790`](https://github.com/AlbertoChecaMuelas/forge/actions/runs/40411962790) | pull_request / `e31ded6` (`a3c436c`) | success / success | 140 / 133 s | 2950 s | 112 / 0 / 20 s | `12693397483`, `v2-safety-evidence-40411962790-1` |
| [`40412340417`](https://github.com/AlbertoChecaMuelas/forge/actions/runs/40412340417) | pull_request / `e31ded6` (`a3c436c`) | success / success | 145 / 135 s | 2945 s | 113 / 0 / 20 s | `12693148986`, `v2-safety-evidence-40412340417-1` |

En cada ejecución, el preflight funcional obtuvo **8/8** checks: namespaces
rootless privados, `/proc` privado visible y pidfd probado sobre hijo propio;
`SIGTERM` escaló a `SIGKILL` por el mismo pidfd, el hijo terminó con RC `-9` y
fue recogido. Los tres escenarios acreditaron `normal` supervisor/suite `0/0`
con autorización, `no-pidfd` `6/4` con autorización denegada y rechazo
inmediato, y `no-pidfd-hang` `6/-9` con timeout real. Cada ejecutor público
devolvió RC 0. `DEAD-6` quedó aislado dentro del caso `normal`. El teardown de
cada escenario confirma init eliminado, cero supervivientes de namespace/grupo,
identidades propias ausentes, raíz sintética eliminada y `teardown_ok=true`.

Los artefactos de los tres runs incluyen `preflight.json`, `job-summary.json`,
`scenario-results.json`, los tres `verdict.json`, los tres
`supervisor.stdout.tsv` y `timeout-calculation.txt`. Descarga completa y matriz
final con fuente por celda:
`/tmp/opencode/v2-safety-ci-followups/phase-2/final-content/` y
`/tmp/opencode/v2-safety-ci-followups/phase-2/final-matrix.md`.

El workflow declara `release.needs: [test, v2-safety]` sin condición que salte
esa dependencia; en estos runs `release` quedó `skipped` por evento/rama, sin
publicación. Separadamente, la protección de merge de `master` exige actualmente
solo `test`; queda pendiente que el administrador registre `v2-safety` como
check requerido. Esa acción no se considera activa por esta acreditación.

### Cierres operacionales documentales

El índice canónico remite a [FOLLOWUPS.md](FOLLOWUPS.md), referencia operacional
única para las disposiciones y límites de los follow-ups 2 (SQLite) y 4 (PID
histórico). `CUTOVER-NOTES.md` y `REMEDIATION-REPORT.md` conservan su contexto
histórico; no son instrucciones de intervención actuales. Los cierres
documentales no autorizan tocar bases, credenciales, configuración, wrapper ni
guard, y no deben confundirse con las nuevas evidencias de CI hospedada.

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
