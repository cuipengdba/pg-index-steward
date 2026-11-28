#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cfg=${1:?Pass pg_config}
bin=$("$cfg" --bindir)
lib=$("$cfg" --libdir)
tmp=$(mktemp -d /tmp/pgis-recovery.XXXXXX)
trap '"$bin/pg_ctl" -D "$tmp/data" -m fast stop >/dev/null 2>&1 || true; rm -rf -- "$tmp"' EXIT
"$bin/initdb" -A trust -D "$tmp/data" >/dev/null
mkdir "$tmp/socket"
cat >> "$tmp/data/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '$tmp/socket'
shared_preload_libraries = 'pg_stat_statements,pg_index_steward'
timezone = 'UTC'
pg_index_steward.maintenance_window = '$(date -u -d "1 hour ago" +%H:%M)-$(date -u -d "1 hour" +%H:%M)'
EOF
"$bin/pg_ctl" -D "$tmp/data" -l "$tmp/log" -w start >/dev/null
export PGHOST="$tmp/socket" PGDATABASE=postgres
unset PGPORT PGUSER PGSERVICE PGOPTIONS
psql() { "$bin/psql" -X -v ON_ERROR_STOP=1 -Atq "$@"; }
psql <<'SQL'
CREATE EXTENSION pg_stat_statements;
CREATE EXTENSION pg_index_steward;
CREATE TABLE public.retry_target(id int, fill text);
INSERT INTO public.retry_target SELECT id,repeat('a',200) FROM generate_series(1,30000) AS id;
ANALYZE public.retry_target;
INSERT INTO index_steward.jobs(action,target,signature,detail)
VALUES('create','public.retry_target'::regclass,'lock-fixture',
       '{"schema":"public","table":"retry_target","keys":["id"],"index":"pgis_retry_target","samples":[]}');
UPDATE index_steward.policy SET min_free_bytes=0;
SQL
PGAPPNAME=steward_recovery_fixture psql -c 'BEGIN; LOCK TABLE public.retry_target IN SHARE UPDATE EXCLUSIVE MODE; SELECT pg_sleep(60)' &
holder=$!
for _ in {1..60}; do
    [[ $(psql -c "SELECT count(*) FROM pg_locks WHERE relation='public.retry_target'::regclass AND granted AND mode='ShareUpdateExclusiveLock'") == 1 ]] && break
    sleep .1
done
python3 "$root/bin/pg-index-steward" --libpq "$lib/libpq.so.5" --once
[[ $(psql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE signature='lock-fixture'") == queued:55P03 ]]
psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='steward_recovery_fixture'" >/dev/null
wait "$holder" || true
sleep 1.1
python3 "$root/bin/pg-index-steward" --libpq "$lib/libpq.so.5" --once
[[ $(psql -c "SELECT state||':'||attempts FROM index_steward.jobs WHERE signature='lock-fixture'") == done:2 ]]
[[ $(psql -c "SELECT indisvalid FROM pg_index WHERE indexrelid='public.pgis_retry_target'::regclass") == t ]]
grep -q 'PG Index Steward .*"reason":"55P03"' "$tmp/log"
grep -q 'PG Index Steward .*"event":"blocker_cleared".*"reason":"55P03"' "$tmp/log"
