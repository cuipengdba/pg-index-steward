#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=$(sed -nE "s/^default_version = '([^']+)'$/\1/p" "$root/pg_index_steward.control")
arch=${1:?Specify x86_64 or aarch64}
binary_root=${2:?Specify the directory containing pg14 through pg19 binaries}
out=${3:-$root/dist}
case "$arch" in x86_64|aarch64) ;; *) exit 2;; esac
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
name="pg-index-steward-$version-linux-$arch"
bundle="$stage/$name"
mkdir -p "$bundle/bin" "$bundle/sql" "$out"
install -m 0755 "$root/install.sh" "$bundle/"
install -m 0755 "$root/bin/pg-index-steward" "$bundle/bin/"
install -m 0644 "$root/pg_index_steward.control" "$root/README.md" "$root/LICENSE" "$bundle/"
if [[ -f $root/vendor/hypopg/LICENSE ]]; then
    install -m 0644 "$root/vendor/hypopg/LICENSE" "$bundle/LICENSE-HypoPG"
fi
install -m 0644 "$root"/sql/pg_index_steward--*.sql "$bundle/sql/"
for major in {14..19}; do
    mkdir -p "$bundle/payload/$arch/pg$major"
    install -m 0755 "$binary_root/pg$major/pg_index_steward.so" "$bundle/payload/$arch/pg$major/"
done
(cd "$bundle" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
tar -C "$stage" -czf "$out/$name.tar.gz" "$name"
