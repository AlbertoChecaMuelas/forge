# Síntesis normativa del contrato de contención V2

## Afirmación defendible

Las ejecuciones nuevas autorizadas, iniciadas por la entrada confiable y
vinculadas a un cierre exterior confirmado, no dejan procesos supervivientes
pertenecientes a sus namespaces PID contenidos. Esta afirmación no equivale a
aislamiento completo de filesystem o red ni ofrece garantía retrospectiva sobre
ejecuciones históricas.

## Afirmaciones retiradas

No se afirma que:

1. FD 8 autentique la entrada o la procedencia de la invocación.
2. Observar declaraciones de procesos demuestre la ausencia universal de
   procesos supervivientes.
3. La limpieza defensiva demuestre que el producto limpió correctamente sus
   propios procesos.
4. Las ejecuciones históricas hayan quedado saneadas.

## Contrato de la puerta

La puerta comprueba **coherencia**, no es una autoridad independiente de
certificación. Sólo es evidencia aceptable una ejecución iniciada por la entrada
confiable y vinculada a su cierre exterior confirmado. Un `PASS` directo del
consumidor no certifica contención.

La frontera PID/proc se acredita **en cada invocación** antes de ejecutar el
escenario. No requiere un `capability.txt` preexistente ni otro artefacto global.
Los recibos se escriben bajo el directorio `--receipt-dir` indicado por el
consumidor; si se omite, la entrada crea un directorio único y privado bajo
`${TMPDIR:-/tmp}`.

## Requisito adversarial no satisfecho

Impedir invocaciones del host deliberadamente falsificadas por el mismo usuario
requiere otra frontera de confianza. La puerta actual no satisface ese
requisito.
