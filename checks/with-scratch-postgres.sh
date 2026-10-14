#!/usr/bin/env bash
# checks/with-scratch-postgres.sh <command ...> — run a command against a THROWAWAY PostgreSQL, then destroy it.
#   Provisions: initdb into a scratch dir, trust auth, unix socket only (no TCP listener), one database.
#   Exports the interface verify-all.sh documents: COFA_TEST_PG_HOST/PORT/DATABASE/USER/PASSWORD.
#   Never touches any other database: it cannot even reach one, it only knows its own socket.
#   usage:   checks/with-scratch-postgres.sh checks/verify-all.sh --require-all
# Needs PostgreSQL SERVER binaries (initdb, pg_ctl, createdb). Refuses to run as root (initdb does too).
set -u
PGCTL="$(command -v pg_ctl 2>/dev/null || ls /usr/lib/postgresql/*/bin/pg_ctl /opt/homebrew/opt/postgresql*/bin/pg_ctl /usr/local/opt/postgresql*/bin/pg_ctl 2>/dev/null | sort -V | tail -1)"
PGBIN="${PGBIN:-$(dirname "${PGCTL:-/nonexistent/pg_ctl}")}"
[ -x "$PGBIN/initdb" ] && [ -x "$PGBIN/pg_ctl" ] || { echo "with-scratch-postgres: PostgreSQL server binaries not found (set PGBIN to the directory holding initdb)" >&2; exit 2; }
[ "$(id -u)" -ne 0 ] || { echo "with-scratch-postgres: refusing to run as root (initdb refuses too)" >&2; exit 2; }
[ $# -gt 0 ] || { echo "usage: $0 <command ...>" >&2; exit 2; }
# a SHORT path on purpose: a unix socket path is limited to ~104 bytes and macOS TMPDIR is long
D="$(mktemp -d /tmp/cofa-pg.XXXXXX)"; PORT="${COFA_SCRATCH_PGPORT:-55432}"
cleanup() { "$PGBIN/pg_ctl" -D "$D/data" -m immediate stop >/dev/null 2>&1; rm -rf "$D"; }
trap cleanup EXIT
"$PGBIN/initdb" -D "$D/data" -A trust -U cofa >"$D/initdb.log" 2>&1 || { tail -5 "$D/initdb.log" >&2; exit 2; }
"$PGBIN/pg_ctl" -D "$D/data" -o "-p $PORT -k $D -c listen_addresses=''" -l "$D/server.log" -w start >/dev/null 2>&1 \
  || { echo "with-scratch-postgres: server did not start (port $PORT busy? set COFA_SCRATCH_PGPORT)" >&2; tail -5 "$D/server.log" >&2; exit 2; }
"$PGBIN/createdb" -h "$D" -p "$PORT" -U cofa cofa_verify || exit 2
export COFA_TEST_PG_HOST="$D" COFA_TEST_PG_PORT="$PORT" COFA_TEST_PG_DATABASE=cofa_verify COFA_TEST_PG_USER=cofa COFA_TEST_PG_PASSWORD=""
"$@"
