# Disposición operacional de follow-ups

Este documento es la **referencia operacional única** para las disposiciones
documentales de los follow-ups 2 (SQLite) y 4 (PID histórico). Se accede a él
desde el índice canónico `README.md`. `CUTOVER-NOTES.md` y
`REMEDIATION-REPORT.md` conservan el contexto y los resultados de su época; no
son runbooks actuales ni se reescriben aquí como hechos presentes.

Estos cierres documentales no autorizan operaciones sobre bases de datos,
credenciales, configuración instalada, wrapper ni guard. Los resultados
históricos descritos en los informes no son evidencia de las ejecuciones nuevas
de CI; la acreditación hospedada de CI está documentada por separado en el
índice y sus artefactos.

## Follow-up 2 — observación de tamaño SQLite

**Disposición:** se conserva la comprobación `size` existente de SQLite, sin
cambiar su lógica. En `cutover.sh`, el control del backup en `preflight/1.2`
compara el tamaño en bytes de `$BACKUP_DB` obtenido con `stat` con el valor
`size` de `MANIFEST.tsv`; la comprobación de hash existente es separada.

El tamaño observado de una base SQLite activa es **semivolátil**. Un checkpoint
puede cambiar el tamaño del fichero y producir un falso positivo al atribuir ese
cambio a la actividad investigada. A la inversa, tamaño estable no demuestra
que no hubiera escrituras que conservaron el mismo tamaño. La comprobación
conservada del backup solo acredita que su tamaño coincide con el manifest en
esa comparación concreta; no es una garantía indefinida de estabilidad ni
prueba de inmutabilidad.

**Reapertura:** reconsiderar este follow-up únicamente ante fallos locales
reproducibles que puedan atribuirse a checkpoints. Una variación aislada de
tamaño, por sí sola, no satisface ese criterio. No se cambia la comprobación ni
se accede a una base original como parte de este cierre documental.

## Follow-up 4 — PID 530393 histórico

**Disposición:** el PID `530393` queda registrado como referencia operacional
histórica y este follow-up se cierra en este trabajo por ausencia de
autorización para intervenir. Durante el trabajo local debe permanecer vivo e
intacto. No se le enviarán señales. El número de PID por sí solo no es identidad
suficiente, ni este cierre declara seguro mantener ese proceso indefinidamente.

**Reapertura:** cualquier futura parada o investigación invasiva requiere una
autorización nueva y un criterio operacional explícito antes de actuar. El
cierre presente no contiene instrucciones para realizar esa intervención ni
autoriza reanudar la anterior investigación.

La evidencia de solo lectura de fase 1 registró
`starttime_ticks=26522468`; la comprobación documental de fase 3 compara ese
valor con el campo correspondiente de `/proc/530393/stat`, sin abrir pidfd,
inspeccionar argumentos ni enviar señales. Esta comparación no convierte el
número de PID en identidad permanente ni amplía la autorización.
