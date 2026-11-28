#!/usr/bin/env bash
set -euo pipefail
prefix=$(realpath -m "${1:?Pass an isolated PostgreSQL install prefix}")
pg_version=${2:-14.19}
ts_version=${3:-2.8.0}
experimental=${4:-OFF}
[[ ! -e $prefix/bin/pg_config ]] || { echo "Fixture prefix already exists: $prefix" >&2; exit 1; }
build=$(mktemp -d)
trap 'rm -rf -- "$build"' EXIT
cd "$build"
pg_archive=postgresql-$pg_version.tar.bz2
pg_url=https://ftp.postgresql.org/pub/source/v$pg_version/$pg_archive
curl -fsSL --retry 3 -o "$pg_archive" "$pg_url"
curl -fsSL --retry 3 -o "$pg_archive.sha256" "$pg_url.sha256"
sha256sum -c "$pg_archive.sha256"
tar xjf "$pg_archive"
curl -fsSL --retry 3 -o timescaledb.tar.gz "https://codeload.github.com/timescale/timescaledb/tar.gz/refs/tags/$ts_version"
tar xzf timescaledb.tar.gz
(
    cd "postgresql-$pg_version"
    ./configure --prefix="$prefix" --without-readline --without-icu --without-llvm
    make -s -j"${PGIS_BUILD_JOBS:-3}" world-bin
    make -s install-world-bin
)
cmake -S "timescaledb-$ts_version" -B ts-build -DPG_CONFIG="$prefix/bin/pg_config" \
    -DREGRESS_CHECKS=OFF -DWARNINGS_AS_ERRORS=OFF -DSEND_TELEMETRY_DEFAULT=OFF -DCMAKE_BUILD_TYPE=Release \
    -DUSE_OPENSSL=OFF -DEXPERIMENTAL="$experimental"
cmake --build ts-build --parallel "${PGIS_BUILD_JOBS:-3}"
cmake --install ts-build
