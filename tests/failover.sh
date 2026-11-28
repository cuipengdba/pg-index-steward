#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cfg=${1:?Pass pg_config}
bin=$("$cfg" --bindir)
lib=$("$cfg" --libdir)
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
shared_preload_libraries = 'pg_stat_statements,pg_index_steward'
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
cycle --observe-only
sql <<'SQL'
INSERT INTO index_steward.jobs(action,target,signature,detail)
VALUES('create','public.mixed'::regclass,'promote-fixture',
       '{"schema":"public","table":"mixed","keys":["id"],"index":"pgis_mixed_ha","samples":[]}');
SQL
"$bin/pg_basebackup" -D "$standby" -Xs -R -c fast
cat >> "$standby/postgresql.conf" <<EOF
unix_socket_directories = '$tmp/standby-sock'
EOF
"$bin/pg_ctl" -D "$standby" -l "$tmp/standby.log" -w start >/dev/null
old_socket=$PGHOST
export PGHOST="$tmp/standby-sock"
check "$(sql -c 'SELECT pg_is_in_recovery()')" t
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
