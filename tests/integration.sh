#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pg_config=${1:?Pass the pg_config of an isolated server}
pgbin=$("$pg_config" --bindir)
pglib=$("$pg_config" --libdir)
[[ $(id -u) != 0 ]] || { echo 'Run as an unprivileged user.' >&2; exit 1; }
tmp=$(mktemp -d /tmp/pgis.XXXXXX)
mkdir "$tmp/socket"
cleanup() {
    "$pgbin/pg_ctl" -D "$tmp/data" -m immediate stop >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT
"$pgbin/initdb" --no-locale --auth=trust -D "$tmp/data" >/dev/null
cat >> "$tmp/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$tmp/socket'
shared_preload_libraries = 'pg_stat_statements'
fsync = off
timezone = 'UTC'
EOF
bash "$root/install.sh" --configure-only --no-service --pg-config "$pg_config" --data-dir "$tmp/data"
bash "$root/install.sh" --configure-only --no-service --pg-config "$pg_config" --data-dir "$tmp/data"
test "$(grep -c '^# BEGIN PG INDEX STEWARD$' "$tmp/data/postgresql.conf")" -eq 1
"$pgbin/pg_ctl" -D "$tmp/data" -l "$tmp/server.log" -w start >/dev/null || { cat "$tmp/server.log"; exit 1; }
export PGHOST="$tmp/socket" PGDATABASE=postgres
unset PGPORT PGUSER PGOPTIONS PGPASSWORD PGSSLMODE PGSSLCERT PGSSLKEY PGSERVICE || true
psql() { "$pgbin/psql" -X -v ON_ERROR_STOP=1 "$@"; }
sql() { psql -Atq -c "$1"; }
worker() { python3 "$root/bin/pg-index-steward" --libpq "$pglib/libpq.so.5" --once "$@"; }
same() { [[ $1 == "$2" ]] || { printf 'expected %s, got %s\n' "$2" "$1" >&2; exit 1; }; }

psql -q <<'SQL'
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pg_index_steward VERSION '0.1.0';
ALTER EXTENSION pg_index_steward UPDATE;
CREATE TABLE public.devices(id int, realm int, label text);
INSERT INTO public.devices SELECT x, x % 31, repeat('x',140) FROM generate_series(1,35000) x;
ANALYZE public.devices;
CREATE INDEX existing_index ON public.devices(realm);
CREATE TABLE public.other(id int primary key);
SQL
same "$(sql "SELECT auto_create||','||maintenance_window||','||auto_drop_existing||','||auto_drop_managed FROM index_steward.settings()")" 'true,23:00-06:00,false,true'
same "$(sql "SELECT index_steward.candidates('SELECT * FROM public.devices WHERE id=42')->0->>'table'")" devices
same "$(sql "SELECT index_steward.candidates('SELECT * FROM devices WHERE id=1; SELECT 1')")" '[]'

sql 'SELECT count(*) FROM public.devices WHERE id=-1' >/dev/null
worker --observe-only
# Generate natural statements with deterministic counts, then lower only the
# advisory threshold for this isolated fixture to remove CPU-speed dependence.
for ((i=0;i<55;i++)); do printf 'SELECT count(*) FROM public.devices WHERE id=%s;\n' "$((i * -1))"; done | psql -Atq >/dev/null
python3 - "$root/bin/pg-index-steward" "$pglib/libpq.so.5" <<'PY'
import runpy, sys
stub = runpy.run_path(sys.argv[1])
stub['main'].__globals__['MIN_TOTAL_MS'] = 0
sys.argv = [sys.argv[1], '--libpq', sys.argv[2], '--once', '--observe-only']
raise SystemExit(stub['main']())
PY
same "$(sql "SELECT count(*) FROM index_steward.jobs WHERE action='create' AND target='public.devices'::regclass AND detail->'keys'='[\"id\"]'::jsonb")" 1
if [[ $(sql "SELECT to_regprocedure('index_steward.hypo_reset()') IS NOT NULL") == t ]]; then
    same "$(sql "SELECT detail->'plan_evidence'->>'uses_candidate' FROM index_steward.jobs WHERE action='create'")" true
    same "$(sql "SELECT count(*) FROM pg_extension WHERE extname='hypopg'")" 0
    same "$(sql "SELECT count(*) FROM pg_class WHERE relname LIKE 'pgis_%'")" 0
fi
inside=$(date -u -d '1 hour ago' +%H:%M)-$(date -u -d '1 hour' +%H:%M)
outside=$(date -u -d '3 hours ago' +%H:%M)-$(date -u -d '2 hours ago' +%H:%M)
setting() { sql "ALTER SYSTEM SET pg_index_steward.$1 = '$2'"; }
reload() { sql 'SELECT pg_reload_conf()' >/dev/null; sleep 0.3; }
setting maintenance_window "$outside"
reload
worker
same "$(sql 'SELECT count(*) FROM index_steward.managed_indexes')" 0
setting maintenance_window "$inside"
setting auto_create off
reload
worker
same "$(sql 'SELECT count(*) FROM index_steward.managed_indexes')" 0
setting auto_create on
reload
sql "UPDATE index_steward.policy SET min_free_bytes=9223372036854775807" >/dev/null
worker
same "$(sql "SELECT count(*) FROM index_steward.jobs WHERE state='queued' AND reason='disk_headroom' AND next_attempt_at>clock_timestamp()")" 1
sql "UPDATE index_steward.policy SET min_free_bytes=0; UPDATE index_steward.jobs SET next_attempt_at=clock_timestamp()-interval '1 second' WHERE reason='disk_headroom'" >/dev/null
worker
same "$(sql 'SELECT count(*) FROM index_steward.managed_indexes WHERE retired_at IS NULL')" 1
same "$(sql "SELECT count(*) FROM index_steward.verdicts WHERE state='observing'")" 1

worker --observe-only
sql "UPDATE index_steward.index_usage SET idle_since=clock_timestamp()-interval '61 days'"
setting auto_drop_managed off
reload
worker
same "$(sql "SELECT count(*) FROM index_steward.jobs WHERE action='drop' AND state='queued'")" 2
setting auto_drop_managed on
reload
worker
same "$(sql 'SELECT count(*) FROM index_steward.managed_indexes WHERE retired_at IS NOT NULL')" 1
same "$(sql "SELECT to_regclass('public.existing_index')::text")" existing_index
setting auto_drop_existing on
reload
if [[ $(sql "SELECT EXISTS(SELECT FROM pg_attribute WHERE attrelid='index_steward.policy'::regclass AND attname='replica_services')") == t ]]; then
    sql "UPDATE index_steward.policy SET replica_services=ARRAY['pgis_unconfigured_replica']" >/dev/null
    worker
    same "$(sql "SELECT to_regclass('public.existing_index')::text")" existing_index
    same "$(sql "SELECT reason FROM index_steward.jobs WHERE action='drop' AND state='queued'")" replica_usage_unverified
    sql "UPDATE index_steward.policy SET replica_services='{}'; UPDATE index_steward.jobs SET next_attempt_at='-infinity' WHERE state='queued'" >/dev/null
fi
worker
same "$(sql "SELECT to_regclass('public.existing_index') IS NULL")" t
same "$(sql "SELECT count(*) FROM index_steward.jobs WHERE action='drop' AND state='done' AND detail ? 'ddl'")" 2
same "$(sql "SELECT to_regclass('public.other_pkey') IS NOT NULL")" t
if [[ $(sql "SELECT to_regprocedure('index_steward.approve_rollback(bigint)') IS NOT NULL") == t ]]; then
    sql "UPDATE index_steward.jobs SET state='queued' WHERE action='create'; UPDATE index_steward.policy SET min_free_bytes=0" >/dev/null
    worker
    sql "UPDATE index_steward.verdicts SET state='regression_review'; SELECT index_steward.approve_rollback(job_id) FROM index_steward.verdicts" >/dev/null
    worker
    same "$(sql "SELECT count(*) FROM index_steward.verdicts WHERE state='rolled_back'")" 1
    same "$(sql 'SELECT paused FROM index_steward.policy')" t
fi
grep -q 'PG Index Steward .*"reason":"disk_headroom"' "$tmp/server.log"
grep -q 'PG Index Steward .*"event":"done"' "$tmp/server.log"
if [[ $(sql "SELECT to_regprocedure('index_steward.queue_partition_index(regclass,name[])') IS NOT NULL") == t ]]; then
    psql -q <<'SQL'
UPDATE index_steward.policy SET paused=false, daily_limit=25;
CREATE TABLE public.events (id int, day int) PARTITION BY RANGE(day);
CREATE TABLE public.events_a PARTITION OF public.events FOR VALUES FROM (0) TO (10);
CREATE TABLE public.events_b PARTITION OF public.events FOR VALUES FROM (10) TO (20);
SELECT index_steward.queue_partition_index('public.events', ARRAY['id']::name[]);
SQL
    worker
    same "$(sql "SELECT indisvalid FROM pg_index WHERE indrelid='public.events'::regclass")" f
    for _ in {1..5}; do worker; done
    same "$(sql "SELECT indisvalid FROM pg_index WHERE indrelid='public.events'::regclass")" t
    same "$(sql "SELECT state FROM index_steward.jobs WHERE target='public.events'::regclass")" done
fi
printf 'Integration passed: %s\n' "$("$pg_config" --version)"
