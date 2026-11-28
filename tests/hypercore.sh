#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cfg=${1:?Provide an isolated pg_config}
bin=$("$cfg" --bindir)
lib=$("$cfg" --libdir)
tmp=$(mktemp -d /tmp/pgis-hypercore.XXXXXX)
cleanup() {
    rc=$?
    if ((rc)); then tail -60 "$tmp/server.log" >&2 || true; fi
    "$bin/pg_ctl" -D "$tmp/data" -m fast stop >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
}
trap cleanup EXIT
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
CREATE TABLE public.telemetry(ts timestamptz NOT NULL, device integer, reading integer, payload text);
SELECT create_hypertable('public.telemetry','ts',chunk_time_interval=>interval '1 day');
ALTER TABLE public.telemetry SET (timescaledb.enable_columnstore=true,timescaledb.orderby='ts');
INSERT INTO public.telemetry SELECT '2026-01-01 UTC'::timestamptz+i*interval '2 seconds',i,i,md5(i::text)
  FROM generate_series(1,40000) i;
SELECT compress_chunk(c) FROM show_chunks('public.telemetry') c;
ANALYZE public.telemetry;
SQL
same "$(sql -c "SELECT count(*) FROM index_steward.timescale_storage('public.telemetry') WHERE storage='columnstore'")" 1
same "$(sql -c "SELECT index_steward.hypercore_settings('public.telemetry')->>'orderby'")" ts
point='SELECT payload FROM public.telemetry WHERE device=20123'
range='SELECT sum(reading) FROM public.telemetry WHERE reading BETWEEN 20010 AND 20025'
point_before=$(sql -c "$point")
range_before=$(sql -c "$range")
sql -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $point" > "$tmp/point-before.json"
sql -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $range" > "$tmp/range-before.json"
printf 'Verified columnstore baseline on %s\n' "$("$cfg" --version)"
