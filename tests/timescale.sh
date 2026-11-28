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
CREATE EXTENSION pg_index_steward VERSION '2.1.0';
CREATE TABLE public.gps(recorded_at timestamptz NOT NULL, device_id int NOT NULL, payload text);
SELECT create_hypertable('public.gps','recorded_at',chunk_time_interval=>interval '1 day');
INSERT INTO public.gps SELECT '2026-01-01 UTC'::timestamptz + i*interval '30 seconds',
    i%1000,repeat('a',200) FROM generate_series(0,9999) i;
ANALYZE public.gps;
UPDATE index_steward.policy SET min_free_bytes=0;
SELECT index_steward.queue_timescale_index('public.gps',ARRAY['device_id','recorded_at']::name[]);
SQL
same "$(sql -c "SELECT extversion FROM pg_extension WHERE extname='pg_index_steward'")" 2.1.0
if worker 2>"$tmp/version.err"; then
    echo 'Expected runner to reject the unupgraded extension' >&2; exit 1
fi
grep -q '(55000)' "$tmp/version.err"
same "$(sql -c "SELECT state||':'||attempts FROM index_steward.jobs WHERE id=1")" queued:0
sql -c 'ALTER EXTENSION pg_index_steward UPDATE'
worker
same "$(sql -c "SELECT min_free_bytes FROM index_steward.policy")" 0
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

sql <<'SQL'
CREATE TABLE public.metrics(ts timestamptz NOT NULL, device int NOT NULL, payload text);
SELECT create_hypertable('public.metrics','ts',chunk_time_interval=>interval '1 day',create_default_indexes=>false);
INSERT INTO public.metrics SELECT '2026-01-01 UTC'::timestamptz+i*interval '1 second', i%10000,repeat('b',500)
  FROM generate_series(0,49999) i;
ANALYZE public.metrics;
SELECT pg_sleep(0.06), count(*) FROM public.metrics WHERE device=42 AND ts >= '2026-01-01 UTC';
SQL
worker
sql <<'SQL'
SELECT 'SELECT pg_sleep(0.06), count(*) FROM public.metrics WHERE device=42 AND ts >= ''2026-01-01 UTC'';' FROM generate_series(1,20) \gexec
SQL
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE detail->>'table'='metrics' AND detail @> '{\"advisory\":true,\"method\":\"btree\",\"source\":\"workload\"}'")" 1
same "$(sql -c "SELECT detail->>'workload_queries' FROM index_steward.jobs WHERE detail->>'table'='metrics' AND detail->>'source'='workload'")" 1
sql -c "SELECT index_steward.queue_timescale_index('public.metrics',ARRAY['device','ts']::name[]);"
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE detail->>'table'='metrics' AND state='done' AND detail->>'method'='btree'")" 1
same "$(sql -c "SELECT count(*) FROM index_steward.verdicts v JOIN index_steward.jobs j ON j.id=v.job_id WHERE j.detail->>'table'='metrics' AND jsonb_array_length(v.baseline)=1 AND v.indexed_at IS NOT NULL")" 1
sql -c "SELECT index_steward.queue_timescale_index('public.metrics',ARRAY['ts']::name[],'brin');"
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE detail->>'table'='metrics' AND state='done' AND detail->>'method'='brin' AND detail->'coverage'->>'indexed'='1'")" 1
same "$(sql -c "SELECT count(*) FROM public.metrics WHERE device=42 AND ts >= '2026-01-01 UTC'")" 5

sql <<'SQL'
UPDATE index_steward.policy SET ddl_timeout_seconds=30,timescale_build_mib_per_second=1;
DELETE FROM index_steward.timescale_build_history WHERE table_oid='public.metrics'::regclass;
SELECT index_steward.queue_timescale_index('public.metrics',ARRAY['payload']::name[]);
SELECT index_steward.queue_timescale_index('public.gps',ARRAY['recorded_at','device_id']::name[]);
SQL
worker
same "$(sql -c "SELECT reason FROM index_steward.jobs WHERE detail->>'table'='metrics' AND detail->'keys'='[\"payload\"]'")" timescale_budget_policy
same "$(sql -c "SELECT state FROM index_steward.jobs WHERE detail->'keys'='[\"recorded_at\",\"device_id\"]'")" done
same "$(sql -c "SELECT detail->'build_estimate'->>'source' FROM index_steward.jobs WHERE detail->'keys'='[\"recorded_at\",\"device_id\"]'")" history
sql -c "UPDATE index_steward.policy SET ddl_timeout_seconds=1800; UPDATE index_steward.jobs SET next_attempt_at=now() WHERE reason='timescale_budget_policy';"
worker
same "$(sql -c "SELECT state FROM index_steward.jobs WHERE detail->>'table'='metrics' AND detail->'keys'='[\"payload\"]'")" done

sql <<'SQL'
CREATE TABLE public.compressed_metrics(ts timestamptz NOT NULL, device int, val int);
SELECT create_hypertable('public.compressed_metrics','ts',chunk_time_interval=>interval '1 day');
INSERT INTO public.compressed_metrics SELECT '2026-01-01 UTC'::timestamptz+i*interval '10 seconds', i%100, i
  FROM generate_series(0,9999) i;
ALTER TABLE public.compressed_metrics SET (timescaledb.compress,timescaledb.compress_segmentby='device');
SELECT compress_chunk(chunk) FROM (SELECT show_chunks('public.compressed_metrics') AS chunk LIMIT 1) q;
SELECT index_steward.queue_timescale_index('public.compressed_metrics',ARRAY['val']::name[]);
SQL
worker
same "$(sql -c "SELECT reason||':'||(detail->'storage'->>'compressed_chunks') FROM index_steward.jobs WHERE detail->>'table'='compressed_metrics'")" timescale_compression_policy:1
sql -c "UPDATE index_steward.policy SET timescale_legacy_compression=true; UPDATE index_steward.jobs SET next_attempt_at=now() WHERE reason='timescale_compression_policy';"
worker
same "$(sql -c "SELECT state||':'||(detail->'coverage'->>'indexed') FROM index_steward.jobs WHERE detail->>'table'='compressed_metrics'")" done:2
same "$(sql -c "SELECT count(*) FROM public.compressed_metrics WHERE val IN (42,9000)")" 2

sql -c "INSERT INTO public.gps VALUES ('2026-01-08 UTC',42,'new'); UPDATE index_steward.timescale_usage SET observed_at=now()-interval '2 minutes'"
worker --observe-only
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE detail->>'table'='gps' AND state='done' AND detail->'coverage'->>'indexed'='5'")" 4
sql -c "SELECT drop_chunks('public.gps',older_than=>'2026-01-02 UTC'::timestamptz); UPDATE index_steward.timescale_usage SET observed_at=now()-interval '2 minutes'"
worker --observe-only
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE detail->>'table'='gps' AND state='done' AND detail->'coverage'->>'indexed'='4'")" 4
job=$(sql -c "SELECT id FROM index_steward.jobs WHERE detail->>'table'='gps' AND detail->'keys'='[\"recorded_at\",\"device_id\"]'")
oid=$(sql -c "SELECT detail->'owned_index'->>'oid' FROM index_steward.jobs WHERE id=$job")
sql -c "SELECT index_steward.protect_index($oid::regclass); UPDATE index_steward.timescale_usage SET observed_at=now()-interval '2 minutes',idle_since=now()-interval '61 days' WHERE build_job=$job;"
worker
same "$(sql -c "SELECT count(*) FROM pg_index WHERE indexrelid=$oid")" 1
sql -c "DELETE FROM index_steward.retention_policy WHERE index_oid=$oid; UPDATE index_steward.timescale_usage SET observed_at=now()-interval '2 minutes' WHERE build_job=$job;"
worker
same "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE action='drop' AND target=$oid")" done:idle
same "$(sql -c "SELECT count(*) FROM pg_index WHERE indexrelid=$oid")" 0

sql <<'SQL'
UPDATE index_steward.policy SET ddl_per_cycle=3,daily_limit=100;
DO $fixture$ BEGIN
  FOR i IN 1..12 LOOP
    EXECUTE format('CREATE SCHEMA s%s',i);
    EXECUTE format('CREATE TABLE s%s.sample(ts timestamptz NOT NULL, device int)',i);
    PERFORM create_hypertable(format('s%s.sample',i)::regclass,'ts');
    EXECUTE format('INSERT INTO s%s.sample VALUES (now(),1)',i);
    PERFORM index_steward.queue_timescale_index(format('s%s.sample',i)::regclass,ARRAY['device']::name[]);
  END LOOP;
END $fixture$;
UPDATE index_steward.jobs SET created_at=now()-interval '3 days' WHERE detail->>'schema'='s12';
UPDATE index_steward.jobs SET detail=detail||'{"score":9999999}' WHERE detail->>'schema'='s11';
SQL
worker
same "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE detail->>'table'='sample' AND state='done'")" 3
same "$(sql -c "SELECT state FROM index_steward.jobs WHERE detail->>'schema'='s12'")" done
for _ in {1..3}; do worker; done
same "$(sql -c "SELECT count(*) FROM index_steward.queue_status(0,500) WHERE table_name='sample' AND state='done' AND chunks=indexed_chunks")" 12
worker --queue --page-size 2 | grep '"queue"' >/dev/null
sql -c "UPDATE index_steward.verdicts SET state='regression_review' WHERE job_id IN (SELECT id FROM index_steward.jobs WHERE detail->>'table'='metrics'); SELECT index_steward.approve_rollback(job_id) FROM index_steward.verdicts WHERE state='regression_review'"
worker
same "$(sql -c "SELECT state FROM index_steward.verdicts WHERE job_id IN (SELECT id FROM index_steward.jobs WHERE detail->>'table'='metrics')")" rolled_back
same "$(sql -c 'SELECT paused FROM index_steward.policy')" t
printf 'TimescaleDB chunk coverage and index adoption verified on %s\n' "$("$cfg" --version)"
