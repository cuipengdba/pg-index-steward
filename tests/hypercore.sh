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
INSERT INTO public.telemetry SELECT '2026-01-01 UTC'::timestamptz+i*interval '0.5 seconds',i,i,md5(i::text)
  FROM generate_series(1,160000) i;
SELECT compress_chunk(c) FROM show_chunks('public.telemetry') c;
ANALYZE public.telemetry;
SQL
same "$(sql -c "SELECT count(*) FROM index_steward.timescale_storage('public.telemetry') WHERE storage='columnstore'")" 1
same "$(sql -c "SELECT index_steward.hypercore_settings('public.telemetry')->>'orderby'")" ts
point="SELECT device FROM public.telemetry WHERE payload=md5('20123')"
range='SELECT sum(reading) FROM public.telemetry WHERE reading BETWEEN 20010 AND 20025'
point_before=$(sql -c "$point")
range_before=$(sql -c "$range")
benchmark() {
    python3 - "$root/bin/pg-index-steward" "$lib/libpq.so.5" "$point" "$range" <<'PY'
import json
import runpy
import sys

db = runpy.run_path(sys.argv[1])['Database'](sys.argv[2], '')
try:
    for query in sys.argv[3:]:
        durations = []
        for trial in range(110):
            result = json.loads(db.execute('EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' + query)[0])[0]
            if trial >= 10:
                durations.append(result['Execution Time'])
        print(sorted(durations)[94])
finally:
    db.close()
PY
}
benchmark > "$tmp/before-p95"
sql -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $point" > "$tmp/point-before.json"
sql -c "EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) $range" > "$tmp/range-before.json"
sql -c "UPDATE index_steward.policy SET hypercore_changes=true,min_free_bytes=0; SELECT index_steward.queue_hypercore_sparse('public.telemetry','payload','reading')"
worker
same "$(sql -c "SELECT state||':'||reason FROM index_steward.jobs WHERE id=1")" done:hypercore_sparse_applied
sql -c "SELECT decompress_chunk(c) FROM show_chunks('public.telemetry') c"
sql -c "SELECT compress_chunk(c) FROM show_chunks('public.telemetry') c"
same "$(sql -c "$point")" "$point_before"
same "$(sql -c "$range")" "$range_before"
sql -c "SELECT s.index FROM timescaledb_information.chunk_columnstore_settings s WHERE hypertable='public.telemetry'::regclass" | grep -q 'bloom'
sql -c "SELECT s.index FROM timescaledb_information.chunk_columnstore_settings s WHERE hypertable='public.telemetry'::regclass" | grep -q 'minmax'
point_plan=$(sql -c "EXPLAIN (ANALYZE, BUFFERS) $point")
range_plan=$(sql -c "EXPLAIN (ANALYZE, BUFFERS) $range")
[[ $point_plan == *bloom1_contains* && $range_plan == *_ts_meta_v2_max_reading* ]]
benchmark > "$tmp/after-p95"
python3 - "$tmp/before-p95" "$tmp/after-p95" <<'PY'
import pathlib
import sys

before, after = (list(map(float, pathlib.Path(path).read_text().split())) for path in sys.argv[1:])
for label, baseline, measured in zip(('Bloom', 'minmax'), before, after):
    print(f'{label} execution P95: {baseline:.3f} ms -> {measured:.3f} ms ({1-measured/baseline:.1%} lower)')
assert all(measured <= baseline * .8 for baseline, measured in zip(before, after))
PY
printf 'Verified columnstore baseline on %s\n' "$("$cfg" --version)"
