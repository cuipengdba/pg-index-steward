#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cfg=${1:?Provide an isolated pg_config}
version=${2:?Provide the installed TimescaleDB version}
experimental=${3:-OFF}
bin=$("$cfg" --bindir)
lib=$("$cfg" --libdir)
tmp=$(mktemp -d /tmp/pgis-tsmatrix.XXXXXX)
trap 'rc=$?; if ((rc)); then tail -80 "$tmp/server.log" >&2 || true; fi; "$bin/pg_ctl" -D "$tmp/data" -m fast stop >/dev/null 2>&1 || true; rm -rf -- "$tmp"' EXIT
"$bin/initdb" -A trust --no-locale -D "$tmp/data" >/dev/null
mkdir "$tmp/socket"
cat >> "$tmp/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$tmp/socket'
shared_preload_libraries = 'timescaledb,pg_stat_statements,pg_index_steward'
timescaledb.telemetry_level = 'off'
timezone = 'UTC'
pg_index_steward.maintenance_window = '$(date -u -d "1 hour ago" +%H:%M)-$(date -u -d "1 hour" +%H:%M)'
EOF
"$bin/pg_ctl" -D "$tmp/data" -l "$tmp/server.log" -w start >/dev/null
unset PGPORT PGUSER PGSERVICE PGOPTIONS PGHOSTADDR
export PGHOST="$tmp/socket" PGDATABASE=postgres
sql() { "$bin/psql" -X -v ON_ERROR_STOP=1 -Atq "$@"; }
worker() { python3 "$root/bin/pg-index-steward" --libpq "$lib/libpq.so.5" --once "$@"; }
same() { [[ $1 == "$2" ]] || { printf 'expected %s, got %s\n' "$2" "$1" >&2; exit 1; }; }
sql <<'SQL'
CREATE EXTENSION timescaledb;
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pg_index_steward;
CREATE TABLE public.matrix_events(ts timestamptz NOT NULL, device integer NOT NULL, reading integer NOT NULL, payload text);
SELECT create_hypertable('public.matrix_events','ts',chunk_time_interval=>interval '1 day');
INSERT INTO public.matrix_events SELECT '2026-01-01 UTC'::timestamptz + i*interval '30 seconds',
    i%1000,i,repeat('a',200) FROM generate_series(0,9999) i;
ANALYZE public.matrix_events;
UPDATE index_steward.policy SET min_free_bytes=0,ddl_per_cycle=2;
SQL
same "$(sql -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb'")" "$version"
if [[ $experimental == ON ]]; then
    sql -c "UPDATE index_steward.policy SET timescale_experimental=true"
fi
query="SELECT * FROM public.matrix_events WHERE device=42 AND ts>='2026-01-01' AND ts<'2026-01-02' ORDER BY ts"
before=$(sql -c "$query")
sql <<'SQL'
SELECT index_steward.queue_timescale_index('public.matrix_events',ARRAY['device','ts']::name[]);
SELECT index_steward.queue_timescale_index('public.matrix_events',ARRAY['reading']::name[],'brin');
SQL
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE state='done' AND detail->'coverage' @> '{\"chunks\":4,\"indexed\":4}'")" 2
same "$(sql -c "SELECT string_agg(a.amname,',' ORDER BY a.amname) FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_am a ON a.oid=c.relam WHERE left(c.relname,6)='pgist_' AND i.indrelid='public.matrix_events'::regclass AND i.indisvalid")" brin,btree
plan=$(sql -c "EXPLAIN $query")
[[ $plan == *pgist_* ]]
same "$(sql -c "$query")" "$before"
sql -c "SELECT index_steward.queue_timescale_index('public.matrix_events',ARRAY['device','reading']::name[])"
chunk=$(sql -c "SELECT show_chunks('public.matrix_events') LIMIT 1")
coproc locker { sql; }
lock_pid=$locker_PID
exec {lock_input}>&"${locker[1]}" {lock_output}<&"${locker[0]}"
printf '%s\n' 'BEGIN;' "LOCK $chunk IN SHARE UPDATE EXCLUSIVE MODE;" "SELECT 'locked';" >&"$lock_input"
read -r -t 10 -u "$lock_output" locked
same "$locked" locked
worker
same "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE id=3")" queued:55P03
printf '%s\n' 'ROLLBACK;' '\q' >&"$lock_input"
wait "$lock_pid"
sleep 1.1
worker
same "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE id=3")" queued:timescale_rebuild
worker
same "$(sql -c "SELECT state||':'||(detail->'coverage'->>'indexed') FROM index_steward.jobs WHERE id=3")" done:4
if [[ $version == 2.32.1 ]]; then
    sql -c "ALTER TABLE public.matrix_events SET (timescaledb.enable_columnstore=true,timescaledb.segmentby='device',timescaledb.orderby='ts');"
    sql -c "SELECT compress_chunk(chunk) FROM (SELECT show_chunks('public.matrix_events') AS chunk LIMIT 1) s"
    same "$(sql -c "SELECT string_agg(storage||':'||n,',' ORDER BY storage) FROM (SELECT storage,count(*) n FROM index_steward.timescale_storage('public.matrix_events') GROUP BY storage) s")" columnstore:1,rowstore:3
    same "$(sql -c "$query")" "$before"
fi
printf 'Verified B-tree and BRIN on %s with TimescaleDB %s\n' "$("$cfg" --version)" "$version"
