#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cfg=${1:?Pass pg_config}
bin=$("$cfg" --bindir)
lib=$("$cfg" --libdir)
mode=${2:-native}
preload=pg_stat_statements,pg_index_steward
if [[ $mode != native ]]; then preload=timescaledb,$preload; fi
tmp=$(mktemp -d /tmp/pgis-ha.XXXXXX)
primary="$tmp/primary"
standby="$tmp/standby"
cleanup() {
    "$bin/pg_ctl" -D "$standby" -m fast stop >/dev/null 2>&1 || true
    "$bin/pg_ctl" -D "$primary" -m fast stop >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT
unset PGPORT PGUSER PGSERVICE PGOPTIONS PGHOSTADDR PGREQUIRESSL PGSSLMODE PGPASSFILE PGDATABASE
export PGDATABASE=postgres
export PGHOST="$tmp/main-sock"
mkdir "$PGHOST" "$tmp/standby-sock"
"$bin/initdb" -A trust -D "$primary" >/dev/null
cat >> "$primary/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$PGHOST'
shared_preload_libraries = '$preload'
timescaledb.telemetry_level = 'off'
timezone = 'UTC'
pg_index_steward.maintenance_window = '$(date -u -d "1 hour ago" +%H:%M)-$(date -u -d "1 hour" +%H:%M)'
EOF
"$bin/pg_ctl" -D "$primary" -l "$tmp/primary.log" -w start >/dev/null
sql() { "$bin/psql" -X -v ON_ERROR_STOP=1 -Atq "$@"; }
cycle() { python3 "$root/bin/pg-index-steward" --libpq "$lib/libpq.so.5" --once "$@"; }
check() { if [[ $1 != "$2" ]]; then printf 'expected %s, got %s\n' "$2" "$1" >&2; exit 1; fi; }
sql <<'SQL'
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pg_index_steward VERSION '1.0.0';
INSERT INTO index_steward.jobs(action,target,signature,detail) VALUES('create','pg_class'::regclass,'upgrade-fixture','{}');
ALTER EXTENSION pg_index_steward UPDATE;
CREATE TABLE public.mixed(id int, payload text);
INSERT INTO public.mixed SELECT i,repeat('a',200) FROM generate_series(1,30000) AS i;
ANALYZE public.mixed;
UPDATE index_steward.policy SET min_free_bytes=0;
SQL
check "$(sql -c "SELECT count(*) FROM index_steward.jobs WHERE signature='upgrade-fixture'")" 1
sql -c "DELETE FROM index_steward.jobs WHERE signature='upgrade-fixture'"
if [[ $mode == timescale ]]; then
    sql <<'SQL'
CREATE EXTENSION timescaledb;
CREATE TABLE public.events(ts timestamptz NOT NULL, device int);
SELECT create_hypertable('public.events','ts',chunk_time_interval=>interval '1 day');
INSERT INTO public.events SELECT '2026-01-01 UTC'::timestamptz+i*interval '30 seconds', i%100
  FROM generate_series(1,10000) i;
SQL
fi
if [[ $mode == hypercore ]]; then
    sql <<'SQL'
CREATE EXTENSION timescaledb;
CREATE TABLE public.telemetry(ts timestamptz NOT NULL, device int, reading int);
SELECT create_hypertable('public.telemetry','ts',chunk_time_interval=>interval '1 day');
ALTER TABLE public.telemetry SET (timescaledb.enable_columnstore=true,timescaledb.orderby='ts');
INSERT INTO public.telemetry SELECT '2026-01-01 UTC'::timestamptz+i*interval '60 seconds',i%100,i
  FROM generate_series(1,3000) i;
SELECT compress_chunk(c) FROM show_chunks('public.telemetry') c;
UPDATE index_steward.policy SET hypercore_changes=true;
SELECT index_steward.queue_hypercore_sparse('public.telemetry','device','reading');
SQL
    cycle
    sql -c "SELECT index_steward.queue_hypercore_rebuild('public.telemetry')"
    cycle
    check "$(sql -c "SELECT jsonb_array_length(detail->'completed_chunks') FROM index_steward.jobs WHERE detail->>'step'='rebuild'")" 1
fi
cycle --observe-only
if [[ $mode == native ]]; then sql <<'SQL'
INSERT INTO index_steward.jobs(action,target,signature,detail)
VALUES('create','public.mixed'::regclass,'promote-fixture',
       '{"schema":"public","table":"mixed","keys":["id"],"index":"pgis_mixed_ha","samples":[]}');
SQL
fi
"$bin/pg_basebackup" -D "$standby" -Xs -R -c fast -d "application_name=steward_reader"
cat >> "$standby/postgresql.conf" <<EOF
unix_socket_directories = '$tmp/standby-sock'
EOF
"$bin/pg_ctl" -D "$standby" -l "$tmp/standby.log" -w start >/dev/null
old_socket=$PGHOST
export PGHOST="$tmp/standby-sock"
check "$(sql -c 'SELECT pg_is_in_recovery()')" t
if [[ $mode == hypercore ]]; then
    cycle
    check "$(sql -c "SELECT state FROM index_steward.jobs WHERE detail->>'step'='rebuild'")" queued
    "$bin/pg_ctl" -D "$primary" -m immediate -w stop >/dev/null
    "$bin/pg_ctl" -D "$standby" -w promote >/dev/null
    cycle
    check "$(sql -c "SELECT jsonb_array_length(detail->'completed_chunks') FROM index_steward.jobs WHERE detail->>'step'='rebuild'")" 1
    sql -c "UPDATE index_steward.policy SET primary_epoch_at=now()-interval '301 seconds'"
    for _ in {1..3}; do cycle; done
    check "$(sql -c "SELECT state||':'||jsonb_array_length(detail->'completed_chunks') FROM index_steward.jobs WHERE detail->>'step'='rebuild'")" done:3
    check "$(sql -c 'SELECT count(*) FROM public.telemetry')" 3000
    grep -q 'PG Index Steward .*"reason":"hypercore_rebuild_complete"' "$tmp/standby.log"
    printf 'Resumed a columnstore maintenance job on the promoted standby\n'
    exit 0
fi
if [[ $mode == timescale ]]; then
    export PGHOST="$old_socket"
    for _ in {1..100}; do
        [[ $(sql -c "SELECT EXISTS(SELECT FROM pg_stat_replication WHERE state='streaming' AND replay_lsn IS NOT NULL)") == t ]] && break
        sleep .1
    done
    check "$(sql -c "SELECT EXISTS(SELECT FROM pg_stat_replication WHERE state='streaming' AND replay_lsn IS NOT NULL)")" t
    if [[ $(sql -c "SELECT count(*) FROM information_schema.columns WHERE table_schema='index_steward' AND table_name='policy' AND column_name='timescale_replica_retirement'") == 1 ]]; then
        cat > "$tmp/services.conf" <<EOF
[steward_reader]
host=$tmp/standby-sock
dbname=postgres
EOF
        export PGSERVICEFILE="$tmp/services.conf"
        retire_job=$(sql -c "SELECT index_steward.queue_timescale_index('public.events',ARRAY['device']::name[])")
        cycle
        check "$(sql -c "SELECT state FROM index_steward.jobs WHERE id=$retire_job")" done
        retiring=$(sql -c "SELECT detail->'owned_index'->>'oid' FROM index_steward.jobs WHERE id=$retire_job")
        lsn=$(sql -c 'SELECT pg_current_wal_flush_lsn()')
        for _ in {1..100}; do
            [[ $(PGHOST="$tmp/standby-sock" sql -c "SELECT pg_last_wal_replay_lsn()>='$lsn'::pg_lsn") == t ]] && break
            sleep .1
        done
        check "$(PGHOST="$tmp/standby-sock" sql -c "SELECT pg_last_wal_replay_lsn()>='$lsn'::pg_lsn")" t
        sql -c "UPDATE index_steward.policy SET timescale_replica_retirement=true,replica_services=ARRAY['steward_reader']"
        cycle --observe-only
        check "$(sql -c "SELECT count(*) FROM index_steward.replica_usage WHERE service='steward_reader' AND index_oid=$retiring")" 1
        sql -c "UPDATE index_steward.timescale_usage SET observed_at=now()-interval '2 minutes',idle_since=now()-interval '61 days' WHERE build_job=$retire_job;
                UPDATE index_steward.replica_usage SET idle_since=now()-interval '61 days' WHERE service='steward_reader'"
        PGHOST="$tmp/standby-sock" sql -c "SET enable_seqscan=off; SELECT count(*) FROM public.events WHERE device=1" >/dev/null
        sleep 1.1
        cycle
        check "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE action='drop' AND target=$retiring")" queued:replica_usage_unverified
        sql -c "UPDATE index_steward.replica_usage SET idle_since=now()-interval '61 days' WHERE service='steward_reader';
                UPDATE index_steward.jobs SET next_attempt_at=now() WHERE action='drop' AND target=$retiring"
        cycle
        check "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE action='drop' AND target=$retiring")" done:idle
        sql -c "UPDATE index_steward.policy SET timescale_replica_retirement=false,replica_services='{}'"
    fi
    job=$(sql -c "SELECT index_steward.queue_timescale_index('public.events',ARRAY['device','ts']::name[])")
    chunk=$(sql -c "SELECT show_chunks('public.events') LIMIT 1")
    coproc locker { sql; }
    pid=$locker_PID
    exec {lock_input}>&"${locker[1]}" {lock_output}<&"${locker[0]}"
    printf '%s\n' 'BEGIN;' "LOCK $chunk IN SHARE UPDATE EXCLUSIVE MODE;" "SELECT 'locked';" >&"$lock_input"
    read -r -t 10 -u "$lock_output" locked
    check "$locked" locked
    cycle
    check "$(sql -c "SELECT reason FROM index_steward.jobs WHERE id=$job")" 55P03
    printf '%s\n' 'ROLLBACK;' '\q' >&"$lock_input"
    wait "$pid"
    sql -c "UPDATE index_steward.jobs SET next_attempt_at=now() WHERE id=$job"
    wal=$(sql -c 'SELECT pg_current_wal_flush_lsn()')
    export PGHOST="$tmp/standby-sock"
    for _ in {1..100}; do
        [[ $(sql -c "SELECT pg_last_wal_replay_lsn()>='$wal'::pg_lsn") == t ]] && break
        sleep .1
    done
    check "$(sql -c "SELECT pg_last_wal_replay_lsn()>='$wal'::pg_lsn")" t
    cycle
    check "$(sql -c "SELECT state||':'||attempts FROM index_steward.jobs WHERE id=$job")" queued:1
    "$bin/pg_ctl" -D "$primary" -m immediate -w stop >/dev/null
    "$bin/pg_ctl" -D "$standby" -w promote >/dev/null
    cycle
    check "$(sql -c "SELECT state||':'||attempts FROM index_steward.jobs WHERE id=$job")" queued:1
    grep -q 'PG Index Steward .*"reason":"failover_grace"' "$tmp/standby.log"
    sql -c "UPDATE index_steward.policy SET primary_epoch_at=now()-interval '301 seconds'"
    cycle
    check "$(sql -c "SELECT reason FROM index_steward.jobs WHERE id=$job")" timescale_rebuild
    cycle
    check "$(sql -c "SELECT state||':'||(detail->'coverage'->>'indexed') FROM index_steward.jobs WHERE id=$job")" done:4
    grep -q 'PG Index Steward .*"event":"timescale_reconciled".*"reason":"timeline_changed"' "$tmp/standby.log"
    printf 'Replayed and rebuilt a partial hypertable index after fenced promotion\n'
    exit 0
fi
cycle
check "$(sql -c "SELECT state FROM index_steward.jobs WHERE signature='promote-fixture'")" queued
# Simulate a fenced former primary. The extension does not fence hosts.
"$bin/pg_ctl" -D "$primary" -m immediate -w stop >/dev/null
test ! -S "$old_socket/.s.PGSQL.5432" || ! PGHOST="$old_socket" "$bin/pg_isready" >/dev/null
"$bin/pg_ctl" -D "$standby" -w promote >/dev/null
check "$(sql -c 'SELECT pg_is_in_recovery()')" f
cycle
check "$(sql -c "SELECT state FROM index_steward.jobs WHERE signature='promote-fixture'")" queued
grep -q 'PG Index Steward .*"event":"primary_epoch_changed"' "$tmp/standby.log"
grep -q 'PG Index Steward .*"reason":"failover_grace"' "$tmp/standby.log"
# Advance just the persisted grace timestamp in this disposable test cluster.
sql -c "UPDATE index_steward.policy SET primary_epoch_at=now()-interval '301 seconds'"
cycle
check "$(sql -c "SELECT state||':'||attempts FROM index_steward.jobs WHERE signature='promote-fixture'")" done:1
check "$(sql -c "SELECT indisvalid FROM pg_index WHERE indexrelid='public.pgis_mixed_ha'::regclass")" t
cat > "$tmp/mixed.sql" <<'EOF'
\set id random(1, 30000)
SELECT payload FROM public.mixed WHERE id = :id;
UPDATE public.mixed SET payload = repeat('b',200) WHERE id = :id;
EOF
"$bin/pgbench" -n -c 2 -j 2 -T 5 -f "$tmp/mixed.sql" > "$tmp/bench.log" &
workload=$!
for _ in {1..4}; do cycle; sleep 1; done
wait "$workload"
check "$(sql -c "SELECT count(*) FROM index_steward.attempts a JOIN index_steward.jobs j ON j.id=a.job_id WHERE j.signature='promote-fixture'")" 1
printf 'Upgrade, fenced failover, and concurrent read/write smoke test passed\n'
