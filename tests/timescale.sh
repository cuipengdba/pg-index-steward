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
printf 'TimescaleDB chunk coverage and index adoption verified on %s\n' "$("$cfg" --version)"
