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

## Acreditación del ejecutable OpenCode fijado

El launcher resuelve el ejecutable esperado desde la entrada `bin` del
`package.json` instalado de `@opencode/cli`, usando como clave el nombre del
ejecutable registrado en `node_modules/.bin`. Resuelve esa ruta relativa dentro
del paquete y compara su REALPATH con el REALPATH del ejecutable registrado;
no debe asumir un nombre bajo `bin/` ni sustituir el dato declarado por el
paquete por una ruta codificada.

Esto es necesario porque el paquete real `@opencode/cli@2.1.4` declara
`opencode: ./bin/opencode.exe`, aunque el enlace registrado se llame
`node_modules/.bin/opencode`. Un fixture que sólo cree `bin/opencode` sin
extensión no reproduce ese layout y puede ocultar un fallo del launcher. Los
fixtures de acreditación deben cubrir el layout declarado, y las declaraciones
ausentes, ambiguas, inválidas o fuera del paquete deben rechazarse sin fallback.

## Soporte del runner

El job `test` está fijado **temporalmente** a `ubuntu-22.04`: Ubuntu 24.04 aplica
la política AppArmor `kernel.apparmor_restrict_unprivileged_userns=1`, que
bloquea los user namespaces sin privilegios requeridos por la contención. El
contrato también requiere montaje privado de `/proc` y `pidfd_open`/
`pidfd_send_signal`. Canonical mantiene Ubuntu 22.04 hasta mayo de 2027, pero la
retirada de runners de GitHub tiene un calendario independiente; fijar la
familia de imagen no congela el kernel ni los paquetes.

La salida del pin es migrar a un runner Ubuntu 24.04 con autorización AppArmor
específica para `unshare`, validando namespaces anidados y el banco completo, o
usar un runner propio efímero. Sustituir la contención queda como último
recurso por el coste de recertificación. Revisar por primera vez antes del
30 de noviembre de 2026; adelantar la revisión si hay un brownout o un anuncio
de retirada con menos de 60 días.
