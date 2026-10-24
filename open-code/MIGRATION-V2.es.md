# Runbook de migración a OpenCode 2

Este runbook describe cómo pasó Forge de OpenCode 1.19.4 a
`@opencode/cli@2.1.4`, y cómo ejecutar, verificar y revertir esa migración
sin este repositorio.

- [Versión fijada y aislamiento](#versión-fijada-y-aislamiento)
- [Qué cambió en el repositorio](#qué-cambió-en-el-repositorio)
- [Decisión D1 — migrar los datos o empezar de cero](#decisión-d1--migrar-los-datos-o-empezar-de-cero)
- [Decisión D2 — quién es dueño del binario de OpenCode](#decisión-d2--quién-es-dueño-del-binario-de-opencode)
- [Backup](#backup)
- [Ensayo sobre una copia](#ensayo-sobre-una-copia)
- [Cutover](#cutover)
- [Comprobaciones de aceptación](#comprobaciones-de-aceptación)
- [Rollback](#rollback)
- [Riesgos y límites conocidos](#riesgos-y-límites-conocidos)

## Versión fijada y aislamiento

| Elemento | Valor |
|----------|-------|
| Paquete fijado | `@opencode/cli@2.1.4` |
| Prefijo fijado (propiedad de Forge) | `~/.local/share/forge/opencode-v2` (se puede cambiar con `$FORGE_OPENCODE_BIN_DIR`) |
| Binario fijado | `<prefijo>/node_modules/.bin/opencode` |
| Launcher | `~/.local/bin/forge-opencode` |
| Overlay | `~/.config/opencode-forge/` (se puede cambiar con `$OPENCODE_CONFIG_DIR`) |
| Config | `<overlay>/opencode.jsonc` (se puede cambiar con `$OPENCODE_CONFIG`) |
| Base de datos | `OPENCODE_DB` (por defecto, el directorio de datos de OpenCode) |

Reglas que la migración no puede romper:

- **Forge nunca usa el binario de OpenCode del `PATH`.** `forge-opencode`
  ejecuta el build fijado por ruta absoluta, de modo que una actualización de
  Omarchy que reinstale OpenCode 1 en el `PATH` no puede cambiar lo que Forge
  ejecuta.
- **No se modifica nada bajo `~/.local/share/omarchy/`.** El wrapper de
  Omarchy se deja exactamente como está.
- **El launcher siempre pide un servidor privado (`--standalone`).** OpenCode 2
  comparte un servidor en segundo plano por defecto; el servidor privado es lo
  que mantiene aislado el overlay de Forge. El flag se inserta justo después
  del subcomando, que es donde lo acepta el CLI de OpenCode 2; los subcomandos
  hoja que no lo ofrecen (`plugin`, `mcp`, `debug`, `service`) se ejecutan
  dentro del propio proceso del CLI y nunca se conectan al servidor
  compartido, así que el launcher se lo omite.
- **`--server` y `--server=<url>` se rechazan** en el launcher antes de
  arrancar OpenCode: conectarse a un servidor compartido es exactamente lo que
  el aislamiento prohíbe.
- **El launcher nunca fija `OPENCODE_DB`.** Exportarla antes de llamar a
  `forge-opencode` es la forma soportada de trabajar contra una copia de los
  datos.

## Qué cambió en el repositorio

| Área | OpenCode 1 | OpenCode 2 |
|------|-------------|------------|
| Config | `plugin`, `provider`, `permission`, `small_model`, `autoupdate` | `plugins`, `providers`, `permissions`, `mcp.servers`, `update: "disable"` |
| Frontmatter de agente | `name:` + mapa `permission:` | sin `name`; `permissions:` es un ruleset ordenado de `{action, resource, effect}` (gana la última coincidencia) |
| Herramientas | `bash`, `task` | `shell`, `subagent` (las escrituras usan la acción `edit`) |
| Modelos | `provider/model` | `provider/model#variant` (el esfuerzo de razonamiento es una variante declarada) |
| Plugins | ficheros `plugins/<nombre>.js` | directorios de paquete, p. ej. `./plugin-packages/forge-guard` |
| Credenciales | `opencode auth list` (salida humana) | `opencode auth list --standalone --format json` |

El branch guard se portó a la API de plugins de OpenCode 2: el módulo exporta
una definición por defecto con `id` y una función `setup(context)`, registra
el veto con `ctx.tool.hook("execute.before", ...)`, inspecciona la herramienta
`shell` y su `input.command`, y ejecuta cada comando de Git con el directorio
de la sesión (`ctx.location.directory`) como directorio de trabajo.

El observador de fallos de infraestructura de `task` de OpenCode 1 se
**eliminó**: OpenCode 2 propaga por sí mismo el fallo de una llamada
`subagent` a la sesión padre, de modo que un observador paralelo solo
duplicaría (o deformaría) ese contrato. No debe reintroducirse.

`@warp-dot-dev/opencode-warp` se **retiró** de la configuración global:
depende del runtime de plugins de OpenCode 1 (`@opencode-ai/plugin`) y no
puede funcionar en OpenCode 2. La configuración anterior se conserva en el
backup, así que se puede restaurar cuando el plugin sea compatible con
OpenCode 2.

## Decisión D1 — migrar los datos o empezar de cero

| Opción | Qué hace | Cuándo elegirla |
|--------|-----------|------------------|
| `migrate` (recomendada) | Importa las credenciales y las sesiones de OpenCode 1 a las tablas de OpenCode 2 | Las sesiones históricas deben seguir siendo accesibles |
| `fresh` | Elimina la base de datos y las credenciales de OpenCode 1; OpenCode 2 empieza de cero | Las sesiones históricas no hacen falta |

Una migración de la base de datos **no es reversible reinstalando OpenCode 1**:
ejecutar OpenCode 1 contra una base migrada (o nueva) de OpenCode 2 no
constituye un rollback. El único rollback es restaurar el backup completo.

Con `fresh`, el usuario tiene que autenticar de nuevo OpenAI/MiniMax cuando no
vengan por variables de entorno.

## Decisión D2 — quién es dueño del binario de OpenCode

| Opción | Qué hace | Cuándo elegirla |
|--------|-----------|------------------|
| `forge-pinned-prefix` (valor actual por defecto) | Forge instala `@opencode/cli@2.1.4` en su propio prefijo aislado y lo ejecuta por ruta absoluta | **Siempre.** El build de OpenCode que gestiona Omarchy en el `PATH` no se toca |
| `operator-managed` | El operador instala a mano el build V2 en el `PATH` y Forge solo lo registra | Solo cuando el build de OpenCode deba compartirse con otras herramientas |

El plan original asumía que el wrapper de Omarchy se regeneraría con
`omarchy npx install @opencode/cli@2.1.4 opencode`. **Eso se cambió**: el
usuario decidió que Forge no debe tocar la instalación de Omarchy, porque una
actualización de Omarchy reinstalaría OpenCode 1 en silencio y rompería
Forge. Por eso Forge es dueño de su build fijado en un prefijo aislado y nunca
lee el binario del `PATH`.

El diagnóstico (`bash install.sh status` / `bash install.sh doctor`) informa
del desajuste cuando el build fijado falta o no es exactamente `2.1.4`, y la
reparación es siempre `bash install.sh install --target=opencode`.

## Backup

Haz backup de **todo** antes de tocar la máquina. Los datos de OpenCode 1
viven en varios sitios y un backup parcial no es un rollback:

```text
~/.local/bin/opencode            # el wrapper de OpenCode 1 (Omarchy)
~/.local/bin/forge-opencode       # el launcher de Forge
~/.config/opencode                # la configuración global de OpenCode
~/.config/opencode-forge          # el overlay de Forge
~/.local/share/opencode           # la base de datos y el directorio de datos
~/.local/state/opencode           # el directorio de estado
~/.opencode-tokens                # el fichero de tokens de Forge
~/.forge-state.json               # el manifest de Forge
```

El backup debe hacerse con OpenCode parado y debe incluir juntos
`opencode.db`, `opencode.db-wal` y `opencode.db-shm`.

## Ensayo sobre una copia

El ensayo nunca toca la base de datos productiva: `OPENCODE_DB` apunta a la
copia.

```bash
set -euo pipefail
HOME=/home/espinilleitor
RUN="$HOME/.local/state/forge/opencode-v2-migration/current"
TRIAL="$RUN/trial"

mkdir -p "$TRIAL/config"
for name in opencode.db opencode.db-wal opencode.db-shm; do
  src="$RUN/home/.local/share/opencode/$name"
  [ ! -e "$src" ] || cp -a "$src" "$TRIAL/$name"
done

cat > "$TRIAL/config/opencode.jsonc" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "update": "disable"
}
JSON

OPENCODE_DB="$TRIAL/opencode.db" \
OPENCODE_CONFIG_DIR="$TRIAL/config" \
OPENCODE_CONFIG="$TRIAL/config/opencode.jsonc" \
  npx --yes --package '@opencode/cli@2.1.4' -- opencode serve --hostname 127.0.0.1 --port 4097
```

Después, contra ese servidor privado:

```bash
npx --yes --package '@opencode/cli@2.1.4' -- opencode auth list --server http://127.0.0.1:4097 --format json
curl -fsS http://127.0.0.1:4097/api/experimental/migration/v1
```

El endpoint de migración debe informar `completed` antes de permitir el
cutover productivo.

## Cutover

1. Para OpenCode (`pkill -TERM -x opencode`).
2. Instala el overlay con el build fijado: `bash install.sh install --target=opencode`.
3. Aplica D1 sobre la base de datos productiva: con `migrate`, arranca un
   servidor privado de OpenCode 2 contra el `OPENCODE_DB` productivo y espera
   a que `/api/experimental/migration/v1` informe `completed`; con `fresh`,
   elimina los ficheros de base de datos de OpenCode 1 y deja que OpenCode 2
   cree una nueva.
4. Verifica las credenciales con `forge-opencode auth list --format json` y
   las sesiones con `forge-opencode session list`.

## Comprobaciones de aceptación

```bash
bash install.sh status
bash install.sh doctor
forge-opencode --version          # debe imprimir 2.1.4
forge-opencode plugin list        # debe listar forge-guard y nada mas
forge-opencode models             # debe listar los tres modelos que usa Forge
forge-opencode auth list --format json
```

`status` y `doctor` son de solo lectura: la sonda de autenticación se ejecuta
con un `OPENCODE_DB` aislado, así que un diagnóstico nunca migra los datos
productivos.

## Rollback

El rollback restaura el backup **completo** y solo después restaura el
wrapper de OpenCode 1. Ejecutar OpenCode 1 contra una base de datos que
OpenCode 2 ya migró **no es un rollback** y no está soportado.

```bash
set -euo pipefail
HOME=/home/espinilleitor
RUN="$(readlink -f "$HOME/.local/state/forge/opencode-v2-migration/current")"

pkill -TERM -x opencode 2>/dev/null || true
sleep 2

rm -f -- "$HOME/.local/bin/opencode" "$HOME/.local/bin/forge-opencode"
rm -rf -- \
  "$HOME/.config/opencode" \
  "$HOME/.config/opencode-forge" \
  "$HOME/.local/share/opencode" \
  "$HOME/.local/state/opencode" \
  "$HOME/.local/share/forge/opencode-v2"
rm -f -- "$HOME/.opencode-tokens" "$HOME/.forge-state.json"

for rel in \
  .local/bin/opencode \
  .local/bin/forge-opencode \
  .config/opencode \
  .config/opencode-forge \
  .local/share/opencode \
  .local/state/opencode \
  .opencode-tokens \
  .forge-state.json; do
  src="$RUN/home/$rel"
  dst="$HOME/$rel"
  if [ -e "$src" ] || [ -L "$src" ]; then
    mkdir -p "$(dirname "$dst")"
    cp -a "$src" "$dst"
  fi
done

opencode --version                # debe imprimir 1.19.4
```

Conserva el backup hasta que varias sesiones reales hayan funcionado con
OpenCode 2.

## Riesgos y límites conocidos

- **Una actualización de Omarchy puede reinstalar OpenCode 1 en el `PATH`.**
  Forge no usa ese binario, así que el overlay sigue funcionando; solo
  cambia el comportamiento del comando `opencode` de la shell.
- **Warp queda temporalmente indisponible.** El plugin de Warp depende del
  runtime de plugins de OpenCode 1; se recupera cuando exista una versión
  compatible con OpenCode 2.
- **Una base de datos migrada no es retrocompatible.** Reinstalar OpenCode 1
  no restaura el estado anterior: el backup es la única vuelta atrás.
- **La lista de plugins se deriva de la config.** Un plugin declarado en
  `opencode.jsonc` pero ausente en disco desactiva su función en silencio,
  así que el instalador verifica todo el árbol de plugins y falla si falta
  algo.
