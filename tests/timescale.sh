#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cfg=${1:?Pass pg_config for an isolated TimescaleDB installation}
bin=$("$cfg" --bindir)
lib=$("$cfg" --libdir)
tmp=$(mktemp -d /tmp/pgis-ts.XXXXXX)
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
CREATE TABLE public.gps(recorded_at timestamptz NOT NULL, device_id int NOT NULL, payload text);
SELECT create_hypertable('public.gps','recorded_at',chunk_time_interval=>interval '1 day');
INSERT INTO public.gps SELECT '2026-01-01 UTC'::timestamptz + i*interval '30 seconds',
    i%1000,repeat('a',200) FROM generate_series(0,9999) i;
ANALYZE public.gps;
UPDATE index_steward.policy SET min_free_bytes=0;
SELECT index_steward.queue_timescale_index('public.gps',ARRAY['device_id','recorded_at']::name[]);
SQL
worker
same "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE detail->>'table'='gps'")" done:timescale_complete
same "$(sql -c "SELECT detail->'coverage'->>'indexed' FROM index_steward.jobs WHERE detail->>'table'='gps'")" 4
same "$(sql -c "SELECT indisvalid FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid WHERE i.indrelid='public.gps'::regclass AND left(c.relname,6)='pgist_'")" t
sql -c "EXPLAIN SELECT * FROM public.gps WHERE device_id=42 AND recorded_at>='2026-01-01' AND recorded_at<'2026-01-02'" | grep 'pgist_' >/dev/null
same "$(sql -c "SELECT count(*) FROM public.gps WHERE device_id=42 AND recorded_at>='2026-01-01' AND recorded_at<'2026-01-02'")" 3
grep -q 'PG Index Steward .*"reason":"timescale_complete"' "$tmp/server.log"

# Block the root before TimescaleDB can write any catalog changes.
sql <<'SQL'
UPDATE index_steward.policy SET retry_limit=1;
SELECT index_steward.queue_timescale_index('public.gps',ARRAY['payload','recorded_at']::name[]);
SQL
coproc locker { sql; }
lock_pid=$locker_PID
exec {lock_input}>&"${locker[1]}" {lock_output}<&"${locker[0]}"
printf '%s\n' 'BEGIN;' 'LOCK public.gps IN SHARE UPDATE EXCLUSIVE MODE;' "SELECT 'locked';" >&"$lock_input"
read -r -t 10 -u "$lock_output" locked
same "$locked" locked
worker
same "$(sql -c "SELECT state||':'||reason||':'||(next_attempt_at>now()) FROM index_steward.jobs WHERE detail->'keys'->>0='payload'")" queued:55P03:true
same "$(sql -c "SELECT count(*) FROM index_steward.alerts() WHERE kind='retry_threshold' AND reason='55P03'")" 1
worker
worker
same "$(grep -c 'PG Index Steward .*"event":"alert".*"reason":"retry_threshold"' "$tmp/server.log")" 1
printf '%s\n' 'ROLLBACK;' '\q' >&"$lock_input"
wait "$lock_pid"
sql -c "UPDATE index_steward.jobs SET next_attempt_at=now() WHERE detail->'keys'->>0='payload'"
worker
same "$(sql -c "SELECT state||':'||attempts FROM index_steward.jobs WHERE detail->'keys'->>0='payload'")" done:2

sql -c "SELECT index_steward.queue_timescale_index('public.gps',ARRAY['device_id','payload']::name[])"
chunk=$(sql -c "SELECT show_chunks('public.gps') LIMIT 1")
coproc chunk_locker { sql; }
lock_pid=$chunk_locker_PID
exec {lock_input}>&"${chunk_locker[1]}" {lock_output}<&"${chunk_locker[0]}"
printf '%s\n' 'BEGIN;' "LOCK $chunk IN SHARE UPDATE EXCLUSIVE MODE;" "SELECT 'locked';" >&"$lock_input"
read -r -t 10 -u "$lock_output" locked
same "$locked" locked
worker
same "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE detail->'keys'= '[\"device_id\",\"payload\"]'")" queued:55P03
same "$(sql -c "SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN index_steward.jobs j ON c.relname=j.detail->>'index' AND i.indrelid=j.target WHERE j.reason='55P03'")" f
printf '%s\n' 'ROLLBACK;' '\q' >&"$lock_input"
wait "$lock_pid"
# Simulate a new runner finding the interrupted job's durable intent.
sql -c "UPDATE index_steward.jobs SET state='running' WHERE reason='55P03' AND state='queued'"
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE reason='timescale_worker_interrupted'")" 1
sql -c "UPDATE index_steward.jobs SET next_attempt_at=now() WHERE reason='timescale_worker_interrupted'"
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE state='queued' AND reason='timescale_rebuild'")" 1
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE state='done' AND detail->'coverage'->>'indexed'='4'")" 3
grep -q 'PG Index Steward .*"reason":"timescale_rebuild"' "$tmp/server.log"
printf 'TimescaleDB chunk coverage and index adoption verified on %s\n' "$("$cfg" --version)"
