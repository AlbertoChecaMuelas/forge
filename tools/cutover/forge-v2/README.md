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

- `cutover.sh` — entrypoint de cutover; conservado byte a byte del original.
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

Los SHA-256 de origen y copia de los cuatro ficheros de implementación se
registran en las evidencias locales de fase 1 bajo
`/tmp/opencode/v2-safety-ci-followups/phase-1/`.

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
enviar `SIGTERM` a un hijo propio por ese descriptor y recogerlo. Una falta de
capacidad o permiso falla con causa en `preflight.json` y en los logs; no hay
fallback, sudo, relajación global de seguridad ni skip verde. La evidencia
incluye versiones, SHA del checkout, estado funcional, RC y tiempos; cada
escenario tiene su propio directorio con resultado semántico y verificación de
teardown. El resumen está en `job-summary.json` y los resultados agregados en
`scenario-results.json`.

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
