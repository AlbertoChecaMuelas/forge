#!/usr/bin/env python3
"""dbtool.py -- helper de base de datos del cutover OpenCode 1.19.4 -> V2 2.1.4.

Este modulo concentra TODO el trabajo sobre el fichero SQLite. El script de
shell no escribe SQL: lo pide a esta herramienta, que trabaja siempre con la
API de backup de SQLite (nunca con `cp`) y con Foreign Keys activadas, para
que el estado final sea determinista y verificable.

Subcomandos
-----------
  snapshot  --src SRC --dst DST [--json OUT]
      Copia consistente de SRC en DST usando sqlite3.Connection.backup().
      NUNCA `cp`: un `cp` de un fichero con -wal/-shm activos produce una base
      inconsistente.

  diff      --a A --b B [--json OUT]
      Diff empirico entre dos bases: listado de tablas y recuento de filas por
      tabla. Sirve para distinguir "lo que creo V2" de "lo preexistente de v1".

  reset     --db DB [--json OUT]
      Reseteo quirurgico del estado de migracion V1->V2 (solo filas de tablas
      propiedad de V2 + el marcador kv['migration.v1-v2']). NO toca ninguna tabla
      de v1. Escribe un informe JSON con los recuentos antes/despues.

  counts    --db DB [--json OUT] [--table T ...]
      Recuento de filas por tabla (de todas, o de las indicadas).

  check     --db DB [--json OUT]
      quick_check + marcador + recuentos V1/V2 + cobertura de IDs V1 en session_v2.

Referencia de propiedad de las tablas (derivada del codigo de OpenCode 2.1.4,
packages/core/src/database/):

  Tablas de v1 que el reset NO puede tocar (son la fuente de la migracion):
    session, message, part, todo, session_share, credential, account,
    account_state, control_account, permission, project, project_directory,
    workspace, migration (journal de esquema)

  Tablas/estructuras que creo o poseyo V2 (el reset las vacia):
    session_v2          -- creada por la migracion de esquema m38
                           (20260804233008_loose_psylocke)
    session_message     -- tabla de v1 REHECHA por m38: su FK apunta a
                           session_v2(id), no a session(id)
    event               -- V2 es su dueno: m36 (reset_v2_session_state) la
                           vacia y la migracion de sesiones la vacia en su
                           fase "Clearing old events"
    event_sequence      -- la escribe la migracion de sesiones (un aggregate_id
                           por sesion migrada)
    kv['migration.v1-v2'] -- marcador de estado de la migracion

  Tablas de V2 que ya estan vacias y se vacian por cascada al borrar
  session_v2 (se vacian igualmente, por si acaso):
    instruction_blob, instruction_entry, instruction_state, session_pending,
    session_inbox

  Tablas que existen en ambos y NO se tocan porque no las crea la migracion
  de sesiones:
    worktree, kv (salvo el marcador)
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys

MARKER_KEY = "migration.v1-v2"

# Tablas cuyo contenido el reset NO puede tocar: son la fuente de la
# migracion (session, message, part...) o simplemente datos que la migracion
# de sesiones no escribe (worktree). El reset debe dejar EXACTAMENTE el mismo
# numero de filas en todas ellas.
V1_PRESERVE = (
    "account",
    "account_state",
    "control_account",
    "credential",
    "message",
    "migration",
    "part",
    "permission",
    "project",
    "project_directory",
    "session",
    "session_share",
    "todo",
    "workspace",
    "worktree",
)

# Estructuras de V2: el reset las deja vacias.
V2_CLEAR = (
    "event",
    "event_sequence",
    "session_message",
    "session_v2",
)

# Tablas de V2 que cuelgan de session_v2 por FK ON DELETE CASCADE.
V2_CASCADE = (
    "instruction_blob",
    "instruction_entry",
    "instruction_state",
    "session_inbox",
    "session_pending",
)


class ToolError(RuntimeError):
    pass


def open_ro(path: str) -> sqlite3.Connection:
    uri = "file:" + os.path.abspath(path).replace("?", "%3f").replace("#", "%23") + "?mode=ro"
    return sqlite3.connect(uri, uri=True, timeout=60)


def begin_read(con: sqlite3.Connection) -> None:
    """Pin subsequent diagnostic reads to one SQLite snapshot."""
    con.execute("BEGIN")


def quick_check_connection(con: sqlite3.Connection) -> str:
    rows = con.execute("PRAGMA quick_check").fetchall()
    return "; ".join(str(r[0]) for r in rows)


def session_coverage(con: sqlite3.Connection) -> dict:
    """Compare V1 session IDs with V2 IDs; native V2-only rows are allowed."""
    if not table_exists(con, "session") or not table_exists(con, "session_v2"):
        return {"v1_missing_in_v2": None, "v2_only": None}
    missing = con.execute(
        "SELECT COUNT(*) FROM session AS v1 "
        "WHERE NOT EXISTS (SELECT 1 FROM session_v2 AS v2 WHERE v2.id = v1.id)"
    ).fetchone()[0]
    v2_only = con.execute(
        "SELECT COUNT(*) FROM session_v2 AS v2 "
        "WHERE NOT EXISTS (SELECT 1 FROM session AS v1 WHERE v1.id = v2.id)"
    ).fetchone()[0]
    return {"v1_missing_in_v2": missing, "v2_only": v2_only}


def open_rw(path: str) -> sqlite3.Connection:
    con = sqlite3.connect(path, timeout=60, isolation_level=None)
    con.execute("PRAGMA foreign_keys = ON")
    con.execute("PRAGMA busy_timeout = 60000")
    return con


def user_tables(con: sqlite3.Connection) -> list[str]:
    rows = con.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).fetchall()
    return [r[0] for r in rows]


def table_exists(con: sqlite3.Connection, name: str) -> bool:
    row = con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone()
    return row is not None


def counts(con: sqlite3.Connection, tables=None) -> dict[str, int]:
    names = tables if tables is not None else user_tables(con)
    out: dict[str, int] = {}
    for name in names:
        if not table_exists(con, name):
            continue
        try:
            out[name] = con.execute('SELECT COUNT(*) FROM "%s"' % name).fetchone()[0]
        except sqlite3.Error as exc:  # pragma: no cover - defensive
            raise ToolError("no se pudo contar %s: %s" % (name, exc)) from exc
    return out


def quick_check(path: str) -> str:
    con = open_ro(path)
    try:
        rows = con.execute("PRAGMA quick_check").fetchall()
    finally:
        con.close()
    return "; ".join(str(r[0]) for r in rows)


def marker(con: sqlite3.Connection):
    if not table_exists(con, "kv"):
        return None
    row = con.execute("SELECT value FROM kv WHERE key=?", (MARKER_KEY,)).fetchone()
    return row[0] if row else None


def cmd_snapshot(args) -> int:
    src = os.path.abspath(args.src)
    dst = os.path.abspath(args.dst)
    if not os.path.isfile(src):
        raise ToolError("la base de origen no existe: %s" % src)
    if os.path.exists(dst):
        os.unlink(dst)
    for suffix in ("-wal", "-shm"):
        side = dst + suffix
        if os.path.exists(side):
            os.unlink(side)
    # La fuente se abre EN SOLO LECTURA: el snapshot no puede modificar la base
    # que esta copiando. Con una conexion de escritura, el cierre de la misma
    # haria un checkpoint del WAL y borraria el -wal/-shm del origen, es decir,
    # el cutover modificaria la base productiva al "copiarla".
    scon = open_ro(src)
    try:
        # Connection.backup() supplies the consistent source snapshot itself.
        dcon = sqlite3.connect(dst, timeout=120)
        try:
            scon.backup(dcon, pages=4096)
            dcon.commit()
        finally:
            dcon.close()
    finally:
        scon.close()
    check = quick_check(dst)
    if check != "ok":
        raise ToolError("quick_check del snapshot no es ok: %s" % check)
    con = open_ro(dst)
    try:
        begin_read(con)
        info = {
            "src": src,
            "dst": dst,
            "size_bytes": os.path.getsize(dst),
            "quick_check": check,
            "tables": user_tables(con),
            "counts": counts(con),
            "marker": marker(con),
        }
    finally:
        con.close()
    emit(args, info)
    return 0


def columns(con: sqlite3.Connection, table: str) -> list[str]:
    try:
        return [r[1] for r in con.execute('PRAGMA table_info("%s")' % table)]
    except sqlite3.Error:
        return []


def foreign_keys(con: sqlite3.Connection, table: str) -> list[str]:
    try:
        rows = con.execute('PRAGMA foreign_key_list("%s")' % table).fetchall()
    except sqlite3.Error:
        return []
    return sorted("%s(%s)->%s" % (r[3], r[4], r[2]) for r in rows)


def schema_of(con: sqlite3.Connection) -> dict:
    out = {}
    for table in user_tables(con):
        out[table] = {"columns": columns(con, table), "foreign_keys": foreign_keys(con, table)}
    return out


def cmd_diff(args) -> int:
    a = open_ro(args.a)
    b = open_ro(args.b)
    try:
        begin_read(a)
        begin_read(b)
        ta = user_tables(a)
        tb = user_tables(b)
        ca = counts(a)
        cb = counts(b)
        sa = schema_of(a)
        sb = schema_of(b)
        ma = marker(a)
        mb = marker(b)
    finally:
        a.close()
        b.close()
    only_a = sorted(set(ta) - set(tb))
    only_b = sorted(set(tb) - set(ta))
    shared = sorted(set(ta) & set(tb))
    differing = [t for t in shared if ca.get(t) != cb.get(t)]
    same = [t for t in shared if ca.get(t) == cb.get(t)]
    schema_diff = {}
    for t in shared:
        entry = {}
        if sa[t]["columns"] != sb[t]["columns"]:
            entry["columns"] = {"a": sa[t]["columns"], "b": sb[t]["columns"]}
        if sa[t]["foreign_keys"] != sb[t]["foreign_keys"]:
            entry["foreign_keys"] = {"a": sa[t]["foreign_keys"], "b": sb[t]["foreign_keys"]}
        if entry:
            schema_diff[t] = entry
    info = {
        "a": os.path.abspath(args.a),
        "b": os.path.abspath(args.b),
        "marker_a": ma,
        "marker_b": mb,
        "tables_only_in_a": only_a,
        "tables_only_in_b": only_b,
        "row_counts": {
            t: {"a": ca.get(t), "b": cb.get(t), "delta": (cb.get(t, 0) or 0) - (ca.get(t, 0) or 0)}
            for t in shared
        },
        "tables_with_different_row_counts": differing,
        "tables_with_identical_row_counts": same,
        "schema_differences": schema_diff,
    }
    emit(args, info)
    return 0


def cmd_counts(args) -> int:
    con = open_ro(args.db)
    try:
        begin_read(con)
        info = {
            "db": os.path.abspath(args.db),
            "counts": counts(con, args.table or None),
            "marker": marker(con),
        }
    finally:
        con.close()
    emit(args, info)
    return 0


def cmd_check(args) -> int:
    path = os.path.abspath(args.db)
    con = open_ro(path)
    try:
        begin_read(con)
        tables = user_tables(con)
        coverage = session_coverage(con)
        info = {
            "db": path,
            "size_bytes": os.path.getsize(path),
            "quick_check": quick_check_connection(con),
            "marker": marker(con),
            "v1_session_count": counts(con, ["session"]).get("session"),
            "v2_session_count": counts(con, ["session_v2"]).get("session_v2"),
            **coverage,
            "tables": tables,
        }
    finally:
        con.close()
    emit(args, info)
    return 0


def check_v2_shape(con: sqlite3.Connection) -> list[str]:
    """Comprueba que la base tiene la forma que el reset da por supuesta.

    El reset solo es valido sobre una base a la que la migracion de esquema de
    OpenCode 2 ya se le aplico (m38). Eso se reconoce por dos huellas:

      - `session_message` es la tabla RECONSTRUIDA por m38: su clave foranea
        apunta a `session_v2(id)`. La de v1 apuntaba a `session(id)`.
      - `event` tiene la columna `created`, que m38 anade con ALTER TABLE.

    Sin esas dos huellas la base no es la que se ha analizado y el reset no se
    aplica: se devuelve el motivo y el script aborta.
    """
    problems = []
    if not table_exists(con, "session_v2"):
        problems.append("no existe la tabla session_v2")
    fks = foreign_keys(con, "session_message")
    if not any("session_v2" in fk for fk in fks):
        problems.append(
            "session_message no tiene la FK a session_v2 (la tabla de v1 no fue reconstruida por V2): %s" % fks
        )
    if "created" not in columns(con, "event"):
        problems.append("la tabla event no tiene la columna 'created' (m38 no se aplico)")
    return problems


def cmd_reset(args) -> int:
    path = os.path.abspath(args.db)
    con = open_rw(path)
    try:
        tables = user_tables(con)
        missing = [t for t in ("session", "session_v2", "session_message", "kv") if t not in tables]
        if missing:
            raise ToolError(
                "la base no tiene la forma esperada (faltan %s); el reset no se aplica" % ", ".join(missing)
            )
        shape_problems = check_v2_shape(con)
        if shape_problems:
            raise ToolError(
                "la base no cumple las precondiciones del reset: %s" % "; ".join(shape_problems)
            )

        before = counts(con)
        before_marker = marker(con)

        # Precondiciones: si la base no esta en el estado "v1 + intento
        # interrumpido", el reset no es el operador correcto.
        if before_marker is None:
            raise ToolError(
                "no existe el marcador %r: la base no arrastra un intento de migracion; "
                "no hay nada que resetear" % MARKER_KEY
            )
        try:
            parsed = json.loads(before_marker)
        except (TypeError, ValueError) as exc:
            raise ToolError("el marcador %r no es JSON: %r" % (MARKER_KEY, before_marker)) from exc
        if not isinstance(parsed, dict) or "phase" not in parsed:
            raise ToolError("el marcador %r no tiene la forma esperada: %r" % (MARKER_KEY, before_marker))

        con.execute("BEGIN IMMEDIATE")
        try:
            # 1) El log de eventos: V2 es su dueno. Se vacia antes que
            #    event_sequence porque event.aggregate_id -> event_sequence con
            #    ON DELETE CASCADE.
            if table_exists(con, "event"):
                con.execute("DELETE FROM event")
            # 2) Los contadores por agregado: los escribe la migracion.
            if table_exists(con, "event_sequence"):
                con.execute("DELETE FROM event_sequence")
            # 3) Las filas de sesion migradas. La FK de session_message,
            #    instruction_*, session_pending y session_inbox apunta a
            #    session_v2, asi que el borrado las arrastra; los borrados
            #    explicitos siguientes garantizan el mismo resultado aunque el
            #    PRAGMA foreign_keys este off en otra conexion.
            if table_exists(con, "session_v2"):
                con.execute("DELETE FROM session_v2")
            for name in ("session_message",) + V2_CASCADE:
                if table_exists(con, name):
                    con.execute('DELETE FROM "%s"' % name)
            # 4) El marcador. Se BORRA la fila (no se actualiza): la migracion
            #    de V2 hace INSERT (no upsert) del marcador cuando no lo
            #    encuentra, asi que una fila preexistente con la misma clave
            #    haria fallar el UNIQUE y la migracion moriria.
            con.execute("DELETE FROM kv WHERE key=?", (MARKER_KEY,))
            con.execute("COMMIT")
        except Exception:
            con.execute("ROLLBACK")
            raise

        after = counts(con)
        after_marker = marker(con)
    finally:
        con.close()

    preserved = {t: before.get(t) for t in V1_PRESERVE if t in tables}
    preserved_after = {t: after.get(t) for t in V1_PRESERVE if t in tables}
    mismatched = {t: (preserved[t], preserved_after[t]) for t in preserved if preserved[t] != preserved_after[t]}
    still_full = {t: after.get(t) for t in V2_CLEAR if after.get(t)}

    check = quick_check(path)
    info = {
        "db": path,
        "quick_check": check,
        "marker_before": before_marker,
        "marker_after": after_marker,
        "counts_before": before,
        "counts_after": after,
        "v1_tables_preserved": preserved,
        "v1_tables_preserved_after": preserved_after,
        "v1_tables_mismatched": mismatched,
        "v2_tables_still_populated": still_full,
    }
    emit(args, info)

    problems = []
    if check != "ok":
        problems.append("quick_check no es ok: %s" % check)
    if mismatched:
        problems.append("tablas de v1 con recuento distinto: %s" % json.dumps(mismatched))
    if still_full:
        problems.append("estructuras de V2 que siguen pobladas: %s" % json.dumps(still_full))
    if after_marker is not None:
        problems.append("el marcador de migracion sigue presente: %r" % after_marker)
    if problems:
        for problem in problems:
            print("[dbtool] ERROR: %s" % problem, file=sys.stderr)
        return 1
    return 0


def emit(args, info) -> None:
    if getattr(args, "json", None):
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(info, handle, indent=2, sort_keys=True)
            handle.write("\n")
    print(json.dumps(info, indent=2, sort_keys=True))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="helper de DB del cutover OpenCode v2")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("snapshot", help="copia consistente con la API de backup de SQLite")
    p.add_argument("--src", required=True)
    p.add_argument("--dst", required=True)
    p.add_argument("--json")
    p.set_defaults(func=cmd_snapshot)

    p = sub.add_parser("diff", help="diff de tablas y recuentos entre dos bases")
    p.add_argument("--a", required=True)
    p.add_argument("--b", required=True)
    p.add_argument("--json")
    p.set_defaults(func=cmd_diff)

    p = sub.add_parser("counts", help="recuento de filas por tabla")
    p.add_argument("--db", required=True)
    p.add_argument("--table", action="append")
    p.add_argument("--json")
    p.set_defaults(func=cmd_counts)

    p = sub.add_parser("check", help="quick_check + marcador + numero de sesiones")
    p.add_argument("--db", required=True)
    p.add_argument("--json")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("reset", help="reseteo quirurgico del estado de migracion V2")
    p.add_argument("--db", required=True)
    p.add_argument("--json")
    p.set_defaults(func=cmd_reset)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ToolError as exc:
        print("[dbtool] ERROR: %s" % exc, file=sys.stderr)
        return 2
    except sqlite3.Error as exc:
        print("[dbtool] ERROR sqlite: %s" % exc, file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
