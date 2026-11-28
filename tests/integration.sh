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
version=$(sed -nE "s/^default_version = '([^']+)'$/\1/p" "$root/pg_index_steward.control")
same "$(sql "SELECT extversion FROM pg_extension WHERE extname='pg_index_steward'")" "$version"
sql 'CREATE DATABASE steward_fresh_install' >/dev/null
PGDATABASE=steward_fresh_install sql 'CREATE EXTENSION pg_stat_statements; CREATE EXTENSION pg_index_steward' >/dev/null
same "$(PGDATABASE=steward_fresh_install sql "SELECT extversion FROM pg_extension WHERE extname='pg_index_steward'")" "$version"
sql 'CREATE DATABASE steward_upgrade_30' >/dev/null
PGDATABASE=steward_upgrade_30 psql -q <<'SQL'
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pg_index_steward VERSION '3.0.0';
CREATE TABLE public.legacy_events(ts int);
UPDATE index_steward.policy SET rollout_percent=70;
INSERT INTO index_steward.jobs(action,target,signature,detail,state,reason)
VALUES ('create','public.legacy_events'::regclass,'retained','{}','queued','55P03');
ALTER EXTENSION pg_index_steward UPDATE;
CREATE ROLE steward_reporter LOGIN;
GRANT USAGE ON SCHEMA index_steward TO steward_reporter;
GRANT EXECUTE ON FUNCTION index_steward.maintenance_report(integer) TO steward_reporter;
SQL
same "$(PGDATABASE=steward_upgrade_30 sql "SELECT rollout_percent FROM index_steward.policy")" 70
same "$(PGDATABASE=steward_upgrade_30 sql "SELECT state||':'||reason FROM index_steward.jobs WHERE signature='retained'")" queued:55P03
same "$(PGDATABASE=steward_upgrade_30 sql "SELECT has_table_privilege('steward_reporter','index_steward.jobs','SELECT')")" f
PGDATABASE=steward_upgrade_30 PGUSER=steward_reporter worker --report --days 7 | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]["report"]; assert r["days"] == 7 and r["jobs"]["pending"] == 1 and r["blockers"][0]["reason"] == "55P03"'
same "$(sql "SELECT auto_create||','||maintenance_window||','||auto_drop_existing||','||auto_drop_managed FROM index_steward.settings()")" 'true,23:00-06:00,false,true'
same "$(sql "SELECT index_steward.candidates('SELECT * FROM public.devices WHERE id=42')->0->>'table'")" devices
same "$(sql "SELECT index_steward.candidates('SELECT * FROM devices WHERE id=1; SELECT 1')")" '[]'
if [[ $(sql "SELECT to_regclass('index_steward.plan_samples') IS NOT NULL") == t ]]; then
    psql -q <<'SQL'
INSERT INTO index_steward.plan_samples(table_oid,label,statement,parameters)
VALUES ('public.devices'::regclass,'point','SELECT * FROM public.devices WHERE id=$1',ARRAY['42']);
SQL
fi

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
if [[ $(sql "SELECT to_regclass('index_steward.relation_hotspots') IS NOT NULL") == t ]]; then
    same "$(sql "SELECT count(*) FROM index_steward.relation_hotspots WHERE schema_name='public' AND table_name='devices' AND calls>=55")" 1
    same "$(sql "SELECT count(*) FROM index_steward.relation_hotspots WHERE table_name='devices' AND planning_ms IS NULL")" 1
fi
if [[ $(sql "SELECT to_regprocedure('index_steward.hypo_reset()') IS NOT NULL") == t ]]; then
    same "$(sql "SELECT detail->'plan_evidence'->>'uses_candidate' FROM index_steward.jobs WHERE action='create'")" true
    same "$(sql "SELECT count(*) FROM pg_extension WHERE extname='hypopg'")" 0
    same "$(sql "SELECT count(*) FROM pg_class WHERE relname LIKE 'pgis_%'")" 0
    if [[ $(sql "SELECT to_regclass('index_steward.plan_samples') IS NOT NULL") == t ]]; then
        same "$(sql "SELECT count(*) FROM index_steward.jobs CROSS JOIN LATERAL jsonb_array_elements(detail->'plan_evidence'->'registered_samples') e WHERE e->>'uses_candidate'='true' AND (e->>'estimated_bytes')::bigint>0")" 2
    fi
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
if [[ $(sql "SELECT to_regclass('index_steward.latency_samples') IS NOT NULL") == t ]]; then
    python3 - "$root/bin/pg-index-steward" "$pglib/libpq.so.5" <<'PY'
import runpy, sys
steward = runpy.run_path(sys.argv[1])
db = steward['Database'](sys.argv[2], '')
try:
    original = db.one('SELECT baseline->0 AS sample FROM index_steward.verdicts')['sample']
    cutoff = db.one('SELECT extract(epoch FROM indexed_at) AS cutoff FROM index_steward.verdicts')['cutoff']
    steward['measure'](db, [{**original, 'sampled_epoch': cutoff, 'period_seconds': 60}], {})
    assert db.one('SELECT observations FROM index_steward.verdicts')['observations'] == []
    for step in range(1, 4):
        period = original['period_seconds'] * 2.5
        steward['measure'](db, [{**original, 'calls': 50, 'elapsed': original['elapsed'] / 10,
                                 'sampled_epoch': cutoff + step * period + 1, 'period_seconds': period}], {})
    verdict = db.one('SELECT state, comparison FROM index_steward.verdicts')
    assert verdict['state'] == 'improved' and verdict['comparison'][0]['calls'] == 150, verdict
finally:
    db.close()
PY
fi

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
if [[ $(sql "SELECT to_regclass('index_steward.retention_policy') IS NOT NULL") == t ]]; then
    sql "UPDATE index_steward.policy SET primary_epoch='00000000'" >/dev/null
    worker
    grep -q 'PG Index Steward .*"reason":"failover_grace"' "$tmp/server.log"
    same "$(sql "SELECT count(*) FROM index_steward.index_usage WHERE idle_since<now()-interval '1 minute'")" 0
    sql "UPDATE index_steward.policy SET primary_epoch_at='-infinity'; UPDATE index_steward.index_usage SET idle_since=now()-interval '61 days'" >/dev/null
    sql "SELECT index_steward.protect_index('public.existing_index')" >/dev/null
    worker
    same "$(sql "SELECT reason FROM index_steward.jobs WHERE action='drop' AND state='queued'")" retention_policy
    sql "DELETE FROM index_steward.retention_policy; UPDATE index_steward.jobs SET next_attempt_at='-infinity' WHERE state='queued'" >/dev/null
fi
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
if [[ $(sql "SELECT to_regprocedure('index_steward.status()') IS NOT NULL") == t ]]; then
    psql -q <<'SQL'
CREATE ROLE metrics_reader LOGIN;
GRANT USAGE ON SCHEMA index_steward TO metrics_reader;
GRANT EXECUTE ON FUNCTION index_steward.status() TO metrics_reader;
SQL
    PGUSER=metrics_reader worker --status | grep -q '"version"'
    PGUSER=metrics_reader worker --metrics | grep -q '^pg_index_steward_jobs{'
    same "$(sql "SELECT has_table_privilege('metrics_reader','index_steward.jobs','SELECT')")" f
fi
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
    if [[ $(sql "SELECT to_regprocedure('index_steward.retry_job(bigint)') IS NOT NULL") == t ]]; then
        sql "UPDATE index_steward.jobs SET state='running' WHERE target='public.events'::regclass" >/dev/null
        worker
        same "$(sql "SELECT reason FROM index_steward.jobs WHERE target='public.events'::regclass")" interrupted_partition_step
        sql "UPDATE index_steward.jobs SET next_attempt_at='-infinity' WHERE target='public.events'::regclass" >/dev/null
    fi
    for _ in {1..5}; do worker; done
    same "$(sql "SELECT indisvalid FROM pg_index WHERE indrelid='public.events'::regclass")" t
    same "$(sql "SELECT state FROM index_steward.jobs WHERE target='public.events'::regclass")" done
    if [[ $(sql "SELECT to_regclass('index_steward.partition_index_progress') IS NOT NULL") == t ]]; then
        same "$(sql "SELECT attached_indexes||'/'||partitions FROM index_steward.partition_index_progress WHERE parent_oid='public.events'::regclass")" 2/2
    fi
fi
psql -q <<'SQL'
UPDATE index_steward.policy SET ddl_per_cycle=10,daily_limit=100;
CREATE TABLE public.multi_events(ts int,device int) PARTITION BY RANGE(ts);
CREATE TABLE public.multi_month PARTITION OF public.multi_events FOR VALUES FROM (0) TO (100) PARTITION BY RANGE(ts);
CREATE TABLE public.multi_day PARTITION OF public.multi_month FOR VALUES FROM (0) TO (50);
CREATE INDEX multi_day_existing ON public.multi_day(device);
SELECT index_steward.queue_partition_index('public.multi_events', ARRAY['device']::name[]);
SQL
for _ in {1..5}; do worker; done
same "$(sql "SELECT indisvalid FROM pg_index WHERE indrelid='public.multi_events'::regclass")" t
same "$(sql "SELECT count(*) FROM pg_inherits WHERE inhrelid='public.multi_day_existing'::regclass")" 1
sql "CREATE TABLE public.multi_new PARTITION OF public.multi_month FOR VALUES FROM (50) TO (100)" >/dev/null
same "$(sql "SELECT count(*) FROM pg_index WHERE indrelid='public.multi_new'::regclass AND indisvalid")" 1
sql "ALTER TABLE public.multi_month DETACH PARTITION public.multi_day; UPDATE index_steward.policy SET ddl_per_cycle=1,daily_limit=25" >/dev/null
same "$(sql "SELECT indisvalid FROM pg_index WHERE indrelid='public.multi_events'::regclass")" t
if [[ $(sql "SELECT to_regprocedure('index_steward.retry_job(bigint)') IS NOT NULL") == t ]]; then
    sql "INSERT INTO index_steward.jobs (action,target,signature,detail,state,attempts,retry_streak)
         VALUES('create','public.other'::regclass,'retry-check','{}','failed',12,12)" >/dev/null
    same "$(sql "SELECT index_steward.retry_job(id) FROM index_steward.jobs WHERE signature='retry-check'")" t
    same "$(sql "SELECT state||':'||attempts||':'||retry_streak FROM index_steward.jobs WHERE signature='retry-check'")" queued:12:0
    grep -q 'PG Index Steward .*"reason":"manual_retry"' "$tmp/server.log"
    sql "DELETE FROM index_steward.jobs WHERE signature='retry-check'" >/dev/null
    psql -q <<'SQL'
CREATE TABLE public.backlog (LIKE public.devices);
INSERT INTO public.backlog SELECT * FROM public.devices;
ANALYZE public.backlog;
INSERT INTO index_steward.jobs (action,target,signature,detail) VALUES
  ('create','public.backlog'::regclass,'large-first',
   '{"schema":"public","table":"backlog","keys":["id"],"score":99999,"index":"pgis_large_first","samples":[]}'),
  ('create','public.devices'::regclass,'eligible-second',
   '{"schema":"public","table":"devices","keys":["id"],"score":999,"index":"pgis_eligible_second","samples":[]}');
UPDATE index_steward.policy SET allowed_tables=ARRAY['"public"."devices"'];
SQL
    worker
    same "$(sql "SELECT state||':'||reason FROM index_steward.jobs WHERE signature='large-first'")" queued:outside_allowlist
    same "$(sql "SELECT state FROM index_steward.jobs WHERE signature='eligible-second'")" done
    sql "UPDATE index_steward.policy SET allowed_tables=NULL;
         UPDATE index_steward.jobs SET next_attempt_at='-infinity' WHERE signature='large-first'" >/dev/null
    worker
    same "$(sql "SELECT state FROM index_steward.jobs WHERE signature='large-first'")" done
fi
if [[ $(sql "SELECT to_regclass('index_steward.table_health') IS NOT NULL") == t ]]; then
    psql -q <<'SQL'
CREATE TABLE public.needs_stats(id int);
ALTER TABLE public.needs_stats SET (autovacuum_enabled=false);
INSERT INTO public.needs_stats SELECT generate_series(1,3000);
SQL
    for _ in {1..30}; do
        [[ $(sql "SELECT analyze_candidate FROM index_steward.table_health WHERE relname='needs_stats'") == t ]] && break
        sleep .2
    done
    sql 'UPDATE index_steward.policy SET auto_analyze=true' >/dev/null
    for _ in {1..6}; do
        worker
        [[ $(sql "SELECT state FROM index_steward.jobs WHERE action='analyze' AND target='public.needs_stats'::regclass ORDER BY id DESC LIMIT 1") == done ]] && break
    done
    same "$(sql "SELECT state FROM index_steward.jobs WHERE action='analyze' AND target='public.needs_stats'::regclass ORDER BY id DESC LIMIT 1")" done
fi
if [[ $(sql "SELECT to_regprocedure('index_steward.alerts()') IS NOT NULL") == t ]]; then
    sql "SELECT index_steward.set_paused(true)" >/dev/null
    same "$(sql 'SELECT paused FROM index_steward.policy')" t
    psql -q <<'SQL'
INSERT INTO index_steward.jobs(action,target,signature,detail,state,reason)
VALUES ('create','public.devices'::regclass,'alert-fixture','{}','failed','fixture');
GRANT EXECUTE ON FUNCTION index_steward.alerts() TO metrics_reader;
SQL
    worker --observe-only
    PGUSER=metrics_reader worker --alerts | grep '"kind": "failed"' >/dev/null
    grep -q 'PG Index Steward .*"event":"alert"' "$tmp/server.log"
    sql "SELECT index_steward.set_paused(false)" >/dev/null
    same "$(sql 'SELECT paused FROM index_steward.policy')" f
fi
printf 'Integration passed: %s\n' "$("$pg_config" --version)"
