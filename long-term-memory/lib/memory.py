#!/usr/bin/env python3
"""Long-term memory — reference implementation over PostgreSQL.

Why PostgreSQL and not a memory library: an install must be possible with no platform API and
no heavyweight dependency. This client is a plain fact store with substring recall (ILIKE) —
it does NOT call mem0 and does no semantic/vector search. It works with psycopg2 if present,
and falls back to the `psql` CLI. Semantic recall is the intended upgrade path, not a feature
of this component: if you adopt it, point it at the same PostgreSQL instance and keep the
per-agent namespace convention.

Storage shape (created on demand, per namespace row — no cross-namespace visibility):

    cofa_facts(id bigserial, namespace text, fact text, created_at timestamptz)

Exit codes
  0  ok
  2  usage / unusable config
  3  database unreachable
  4  operation failed
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

EXIT_OK, EXIT_USAGE, EXIT_DB_UNREACHABLE, EXIT_OP_FAILED = 0, 2, 3, 4
TABLE = "cofa_facts"

DDL = f"""CREATE TABLE IF NOT EXISTS {TABLE} (
    id BIGSERIAL PRIMARY KEY,
    namespace TEXT NOT NULL,
    fact TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS {TABLE}_namespace_idx ON {TABLE} (namespace);"""


# --------------------------------------------------------------------------- config
def load_config(path: str) -> dict:
    text = Path(path).read_text()
    try:
        import yaml

        return yaml.safe_load(text) or {}
    except ImportError:
        # Narrow fallback: flat scalars plus one nested map (pg:), which is the documented shape.
        root, parent = {}, None
        for raw in text.splitlines():
            line = raw.split(" #")[0].rstrip()
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("-"):
                continue
            indent = len(line) - len(line.lstrip())
            key, _, value = stripped.partition(":")
            value = value.strip().strip('"').strip("'")
            if indent == 0:
                if value:
                    root[key] = value
                    parent = None
                else:
                    root[key] = {}
                    parent = root[key]
            elif parent is not None:
                if value:
                    parent[key] = value
                else:
                    parent[key] = {}
                    parent = parent[key]
        return root


def pg_params(cfg: dict) -> dict:
    pg = cfg.get("pg") or {}
    missing = [k for k in ("host", "database") if not pg.get(k) or "<" in str(pg.get(k))]
    if missing:
        raise ValueError(f"config pg.{'/pg.'.join(missing)} is missing or still a placeholder")
    return {
        "host": str(pg["host"]),
        "port": str(pg.get("port") or 5432),
        "dbname": str(pg["database"]),
        "user": str(pg.get("username") or ""),
        "password": str(pg.get("password") or ""),
    }


# --------------------------------------------------------------------------- backends
class Database:
    def __init__(self, params: dict):
        self.params = params
        self.backend = "psycopg2" if _has_psycopg2() else ("psql" if _which("psql") else None)
        if self.backend is None:
            print(
                "REQUIREDCHECK psycopg2-or-psql: long-term-memory needs either the psycopg2 Python "
                "package or the `psql` client to reach its PostgreSQL database.",
                file=sys.stderr,
            )
            raise SystemExit(EXIT_USAGE)

    def run(self, sql: str, params: tuple = (), *, fetch: bool = False, many: bool = False):
        if self.backend == "psycopg2":
            import psycopg2

            conn_kwargs = {"host": self.params["host"], "port": self.params["port"],
                           "dbname": self.params["dbname"]}
            if self.params["user"]:
                conn_kwargs["user"] = self.params["user"]
            if self.params["password"]:
                conn_kwargs["password"] = self.params["password"]
            try:
                with psycopg2.connect(connect_timeout=8, **conn_kwargs) as conn:
                    with conn.cursor() as cur:
                        cur.execute(sql, params)
                        return cur.fetchall() if fetch else None
            except psycopg2.OperationalError as exc:
                raise DatabaseUnreachable(str(exc).strip().splitlines()[0]) from exc
            except psycopg2.Error as exc:
                raise OperationFailed(str(exc).strip().splitlines()[0]) from exc

        # psql fallback: no Python driver required.
        env = dict(os.environ)
        if self.params["password"]:
            env["PGPASSWORD"] = self.params["password"]
        base = ["psql", "-h", self.params["host"], "-p", self.params["port"],
                "-d", self.params["dbname"], "-v", "ON_ERROR_STOP=1", "-At", "-q"]
        if self.params["user"]:
            base += ["-U", self.params["user"]]
        statements = [sql] if not many else [s for s in sql.split(";") if s.strip()]
        quoted = sql
        for i, value in enumerate(params, start=1):
            quoted = quoted.replace(f"%s", "'" + str(value).replace("'", "''") + "'", 1)
        proc = subprocess.run(base + ["-c", quoted], capture_output=True, text=True, env=env, timeout=30)
        if proc.returncode != 0:
            # An unreachable server makes psql print SEVERAL lines, and the LAST one carries none of the
            # keywords we can match ("Is the server running on that host and accepting TCP/IP connections?")
            # — the cause is on the FIRST line. Classify on the whole stderr, but report the first line.
            # Reading only the last line made this path raise BAD-RESPONSE (4) where the contract says
            # TRANSPORT (3), so the two client backends disagreed on the same input.
            full = (proc.stderr or "").strip()
            lines = full.splitlines()
            msg = lines[0] if lines else f"psql exit {proc.returncode}"
            if any(s in full for s in ("could not connect", "Connection refused", "could not translate host",
                                       "no such host", "timeout expired", "connection to server")):
                raise DatabaseUnreachable(msg)
            raise OperationFailed(msg)
        return [tuple(line.split("|")) for line in proc.stdout.strip().splitlines()] if fetch else None


class DatabaseUnreachable(RuntimeError):
    pass


class OperationFailed(RuntimeError):
    pass


def _has_psycopg2() -> bool:
    try:
        import psycopg2  # noqa: F401
    except ImportError:
        return False
    return True


def _which(binary: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / binary
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


# --------------------------------------------------------------------------- operations
def op_init(db: Database) -> None:
    db.run(DDL, many=True)


def op_write(db: Database, namespace: str, fact: str) -> None:
    db.run(f"INSERT INTO {TABLE} (namespace, fact) VALUES (%s, %s)", (namespace, fact))


def op_read(db: Database, namespace: str, query: str):
    # The search string is DATA, not a pattern. Without escaping, a query containing `_` or `%`
    # acts as a LIKE wildcard: searching the literal "a_b" would also return "axb".
    literal = query.replace("!", "!!").replace("%", "!%").replace("_", "!_")
    return db.run(
        f"SELECT fact FROM {TABLE} WHERE namespace = %s AND fact ILIKE %s ESCAPE '!' ORDER BY id DESC",
        (namespace, f"%{literal}%"), fetch=True,
    ) or []


def op_count(db: Database, namespace: str) -> int:
    rows = db.run(f"SELECT count(*) FROM {TABLE} WHERE namespace = %s", (namespace,), fetch=True)
    return int(rows[0][0]) if rows else 0


def op_drop_namespace(db: Database, namespace: str) -> None:
    db.run(f"DELETE FROM {TABLE} WHERE namespace = %s", (namespace,))


# --------------------------------------------------------------------------- cli
def _db(args) -> Database:
    try:
        return Database(pg_params(load_config(args.config)))
    except (OSError, ValueError) as exc:
        print(f"USAGE: {exc}", file=sys.stderr)
        raise SystemExit(EXIT_USAGE)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="memory.py", description="COFA long-term memory client")
    parser.add_argument("--config", default=str(
        Path(os.environ.get("COFA_CONFIG_DIR", Path.home() / ".config" / "cofa"))
        / "long-term-memory" / "config.yaml"))
    parser.add_argument("--namespace", default=None, help="override the namespace in the config")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="create the facts table if absent")
    p_write = sub.add_parser("write", help="store one fact")
    p_write.add_argument("fact")
    p_read = sub.add_parser("read", help="read facts matching a substring")
    p_read.add_argument("query")
    sub.add_parser("count", help="count facts in the namespace")
    p_drop = sub.add_parser("drop-namespace", help="delete this namespace's facts (cleanup)")
    p_drop.add_argument("namespace")

    args = parser.parse_args(argv)

    if args.cmd == "drop-namespace":
        db = _db(args)
        op_drop_namespace(db, args.namespace)
        print(f"DROPPED {args.namespace}")
        return EXIT_OK

    namespace = args.namespace
    if not namespace:
        try:
            namespace = str(load_config(args.config).get("namespace") or "")
        except OSError as exc:
            print(f"USAGE: {exc}", file=sys.stderr)
            return EXIT_USAGE
    if not namespace or "<" in namespace:
        print("USAGE: no usable namespace (set `namespace:` in the config or pass --namespace)",
              file=sys.stderr)
        return EXIT_USAGE

    try:
        db = _db(args)
        if args.cmd == "init":
            op_init(db)
            print(f"READY table={TABLE} namespace={namespace}")
        elif args.cmd == "write":
            op_init(db)
            op_write(db, namespace, args.fact)
            print(f"WROTE namespace={namespace} bytes={len(args.fact)}")
        elif args.cmd == "read":
            rows = op_read(db, namespace, args.query)
            print(json.dumps([r[0] for r in rows]))
        elif args.cmd == "count":
            print(op_count(db, namespace))
    except DatabaseUnreachable as exc:
        print(f"UNREACHABLE: {exc}", file=sys.stderr)
        return EXIT_DB_UNREACHABLE
    except OperationFailed as exc:
        print(f"OP-FAILED: {exc}", file=sys.stderr)
        return EXIT_OP_FAILED
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
