#!/usr/bin/env bash
# Runs every migration and the Phase 0 test suite against a throw-away
# local PostgreSQL 16 cluster (with a minimal Supabase auth stub).
# Usage: scripts/db-test.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)}"
WORK="$(mktemp -d)"
PORT="${PGPORT_TEST:-54329}"
RUN_AS=""
if [ "$(id -u)" = "0" ]; then RUN_AS="runuser -u postgres --"; chown postgres "$WORK"; fi

cleanup() { $RUN_AS "$PGBIN/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$WORK"; }
trap cleanup EXIT

$RUN_AS "$PGBIN/initdb" -D "$WORK/data" -U postgres --auth=trust >/dev/null
$RUN_AS "$PGBIN/pg_ctl" -D "$WORK/data" -o "-p $PORT -k $WORK -c listen_addresses=''" -l "$WORK/log" start >/dev/null

PSQL=(psql -X -q -h "$WORK" -p "$PORT" -U postgres -v ON_ERROR_STOP=1)
"${PSQL[@]}" -d postgres -c "create database ola_test" >/dev/null
"${PSQL[@]}" -d ola_test -f "$ROOT/supabase/tests/00_supabase_stub.sql" >/dev/null
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "migrate  $(basename "$f")"
  "${PSQL[@]}" -d ola_test -f "$f" >/dev/null
done
if [ -f "$ROOT/supabase/seed.sql" ]; then
  echo "seed     seed.sql"
  "${PSQL[@]}" -d ola_test -f "$ROOT/supabase/seed.sql" >/dev/null
fi
for t in "$ROOT"/supabase/tests/*.test.sql; do
  echo "test     $(basename "$t")"
  "${PSQL[@]}" -d ola_test -f "$t" 2>&1 >/dev/null | sed -e 's/^psql:[^ ]* NOTICE:  /  /'
done
